import AppKit
import SwiftUI

/// One of a round's checks (design/pdf-reader/PLAN.md P1.5; the engine's read-only `checks`, `rN/checks.json`): a slip
/// every draft should avoid, stated as a fact, with where it is in the round's build PDF. Pages are 0-based, rects
/// contract coordinates (top-left), as the link table's. The decoding is lenient: a missing field takes its default; a
/// place without a page (missing, null, not a number) and a rect that is not four numbers are left out by themselves,
/// never costing the other places or checks.
struct Check: Decodable, Equatable {
    struct Place: Decodable, Equatable {
        var page: Int
        /// Empty: the page only.
        var rects: [[Double]]
        var text: String?

        init(page: Int, rects: [[Double]], text: String? = nil) {
            self.page = page
            self.rects = rects
            self.text = text
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            page = ((try? c.decodeIfPresent(Int.self, forKey: .page)) ?? nil) ?? -1  // -1: left out (`Check.places`)
            rects = (((try? c.decodeIfPresent([Rect].self, forKey: .rects)) ?? nil) ?? []).compactMap(\.rect)
            text = try c.decodeIfPresent(String.self, forKey: .text)
        }

        private enum CodingKeys: String, CodingKey { case page, rects, text }

        /// One rect as sent: nil when it is not four numbers.
        private struct Rect: Decodable {
            var rect: [Double]?
            init(from decoder: Decoder) throws {
                rect = (try? decoder.singleValueContainer().decode([Double].self)).flatMap { $0.count == 4 ? $0 : nil }
            }
        }
    }

    var code: String
    /// references, bibliography, consistency, typesetting or submission; another is kept under its own name.
    var group: String
    /// The row's words, a terse fact without the page: "Figure 3 · not referenced".
    var text: String
    /// What was found and where it came from, under the row's words.
    var detail: String?
    /// A sentence the advisor may send the student: Comment… starts with it.
    var note: String?
    /// In reading order, one per occurrence; empty for the PDF's metadata. The first is where a click goes first.
    var places: [Place]
    /// The same in every round while the slip is (the engine's: its code and words): what Mark as OK keeps.
    var key: String
    /// Marked OK by the advisor (the paper is fine there): listed apart, after the others, and not counted.
    var ok: Bool

    init(code: String, group: String, text: String, detail: String? = nil, note: String? = nil, places: [Place] = [],
         ok: Bool = false) {
        self.code = code
        self.group = group
        self.text = text
        self.detail = detail
        self.note = note
        self.places = places
        key = code + "|" + text
        self.ok = ok
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decodeIfPresent(String.self, forKey: .code) ?? ""
        group = try c.decodeIfPresent(String.self, forKey: .group) ?? "other"
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? code
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        places = (try c.decodeIfPresent([Place].self, forKey: .places) ?? []).filter { $0.page >= 0 }
        key = ((try? c.decodeIfPresent(String.self, forKey: .key)) ?? nil) ?? code + "|" + text
        ok = ((try? c.decodeIfPresent(Bool.self, forKey: .ok)) ?? nil) ?? false
    }

    private enum CodingKeys: String, CodingKey { case code, group, text, detail, note, places, key, ok }

    /// The row's trailing words: its places' pages in their order, each once, two at most ("p.7", "p.2, 5",
    /// "p.1, 3, …"); the help tag says when a second click goes on to another place.
    var trail: String? {
        var pages: [Int] = []
        for p in places where !pages.contains(p.page) { pages.append(p.page) }
        guard !pages.isEmpty else { return nil }
        return "p." + pages.prefix(2).map { String($0 + 1) }.joined(separator: ", ") + (pages.count > 2 ? ", …" : "")
    }

    /// The row's help tag: what a click does when it is not plain ("" for none).
    var help: String {
        if places.count > 1 { return "Click again for the next place." }
        if places.isEmpty { return "It has no place on the pages to go to." }
        return ""
    }

    /// Copy: the row's words and the detail.
    var copied: String { [text, detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n") }
}

/// The engine's `checks` reply (no state): `checks` null when the round's paragraphs cannot be found.
struct ChecksReply: Decodable {
    var round: Int?
    var checks: [Check]?
}

/// A row of the Checks tab: a line of words ("Checking…", "No problems found"), a group's title, or a check (its index
/// in the list).
struct ChecksItem: Identifiable, Equatable {
    enum Kind: Equatable { case message(String), group(String), check(Int), ok(Int) }
    var kind: Kind

    var id: String {
        switch kind {
        case .message(let m): return "m:" + m
        case .group(let g): return "g:" + g
        case .check(let i): return "c:\(i)"
        case .ok(let n): return "ok:\(n)"
        }
    }
}

/// The panel's Checks (UX.md §39), observed only by its tab and page: the shown round's checks, whether they are being
/// asked for, and the row last clicked with the place it went to.
@MainActor
final class ChecksModel: ObservableObject {
    enum Phase: Equatable {
        /// Off, not asked, or no checks (an error, an older engine, a round whose paragraphs cannot be found).
        case hidden
        case asking
        case ready
    }

    /// The groups in the order they are listed, with their titles.
    static let groups: [(id: String, title: String)] = [
        ("references", "References"), ("bibliography", "Bibliography"), ("consistency", "Consistency"),
        ("typesetting", "Typesetting"), ("submission", "Submission"),
    ]

    @Published private(set) var phase = Phase.hidden
    @Published private(set) var list: [Check] = []
    /// The row chosen last (a click, J or K), marked on the page.
    @Published private(set) var current: Int?
    /// The checks marked OK listed under their header (Show), else folded into it, as at first.
    @Published var showOK = false
    /// The row under the pointer (cleared when the tab is left: a hidden page's rows get no exit), told to its row's
    /// look only, so a move of the pointer redraws the two rows it leaves and enters, nothing else.
    private(set) var hovered: Int?
    private var looks: [Int: CheckLook] = [:]
    /// The shown round is open, the app not busy and no comment being re-anchored: Comment… can be offered (the rows'
    /// menus observe it).
    @Published var canComment = false
    /// The paper, round and created time the checks (or the question) are for, and that round's number.
    private(set) var key: String?
    private(set) var round: Int?
    /// The row clicked last and the place it went to: a second click goes to its next place.
    private(set) var cursor: (check: Int, place: Int)?

    func ask(_ key: String) {
        self.key = key
        round = nil
        list = []
        cursor = nil
        current = nil
        gap = nil
        unhover()
        looks = [:]
        phase = .asking
    }

    /// The reply for a round: nil hides the group. `pages`: the round's page count, when known; a place past it is left
    /// out.
    func show(_ checks: [Check]?, round: Int, key: String, pages: Int?) {
        guard let checks else { return clear() }
        self.key = key
        self.round = round
        cursor = nil
        current = nil
        gap = nil
        unhover()
        looks = [:]
        list = checks.map { c in
            var c = c
            if let pages, pages > 0 { c.places = c.places.filter { $0.page < pages } }
            return c
        }
        phase = .ready
    }

    func clear() {
        key = nil
        round = nil
        cursor = nil
        if current != nil { current = nil }
        gap = nil
        unhover()
        looks = [:]
        if !list.isEmpty { list = [] }
        if phase != .hidden { phase = .hidden }
    }

    /// The place a click on check `i` goes to: its first, or after a click on it, its next (cycling). nil: it has none.
    func step(_ i: Int) -> Int? {
        guard list.indices.contains(i), !list[i].places.isEmpty else { return nil }
        let p = cursor.map { $0.check == i ? ($0.place + 1) % list[i].places.count : 0 } ?? 0
        cursor = (i, p)
        current = i
        gap = nil
        return p
    }

    /// Row `i`'s look (its hover), made once per list.
    func look(_ i: Int) -> CheckLook {
        if let l = looks[i] { return l }
        let l = CheckLook()
        looks[i] = l
        return l
    }

    /// The pointer entered or left row `i`.
    func hover(_ i: Int, _ on: Bool) {
        if on {
            guard hovered != i else { return }
            unhover()
            hovered = i
            look(i).hovering = true
        } else if hovered == i {
            unhover()
        }
    }

    /// No row under the pointer (the tab left, the list replaced).
    func unhover() {
        if let h = hovered { looks[h]?.hovering = false }
        hovered = nil
    }

    /// Where the row chosen last was in `order` before Mark as OK folded it away: J and K go on from there.
    private(set) var gap: Int?

    /// Check `i` marked OK, or not, with any other of its key (the engine keeps the key).
    func setOK(_ i: Int, _ ok: Bool) {
        guard list.indices.contains(i), list[i].ok != ok else { return }
        if hovered == i { unhover() }  // the row leaves its group: its old view gets no exit from the pointer
        let before = order, k = list[i].key
        for j in list.indices where list[j].key == k { list[j].ok = ok }
        if let c = current, !order.contains(c) {
            gap = before.firstIndex(of: c)
            current = nil
            cursor = nil
        }
    }

    /// Check `i` chosen without a place to go to (the PDF's metadata).
    func select(_ i: Int) {
        guard list.indices.contains(i) else { return }
        cursor = nil
        current = i
        gap = nil
    }

    /// The place Comment… and Keep Open use: the one the row last went to when it has rects, else its first with rects.
    func menuPlace(_ i: Int) -> Check.Place? {
        guard list.indices.contains(i) else { return nil }
        let ps = list[i].places
        if let c = cursor, c.check == i, ps.indices.contains(c.place), !ps[c.place].rects.isEmpty { return ps[c.place] }
        return ps.first { !$0.rects.isEmpty }
    }

    /// The page's rows: "Checking…" while asked; "No problems found"; else a title per group with checks not marked OK,
    /// in the groups' order (an unknown group after them, under its own name), then its checks; then the header of
    /// those marked OK, and while shown, they in the engine's order.
    var items: [ChecksItem] {
        switch phase {
        case .hidden: return []
        case .asking: return [ChecksItem(kind: .message("Checking…"))]
        case .ready:
            guard !list.isEmpty else { return [ChecksItem(kind: .message("No problems found"))] }
            var order = Self.groups.map(\.id)
            for c in list where !order.contains(c.group) { order.append(c.group) }
            let open = order.flatMap { g -> [ChecksItem] in
                let ids = list.indices.filter { list[$0].group == g && !list[$0].ok }
                return ids.isEmpty ? [] : [ChecksItem(kind: .group(Self.title(g)))] + ids.map { ChecksItem(kind: .check($0)) }
            }
            let ok = okChecks
            return open + (ok.isEmpty ? [] : [ChecksItem(kind: .ok(ok.count))]
                           + (showOK ? ok.map { ChecksItem(kind: .check($0)) } : []))
        }
    }

    /// The checks marked OK, in the engine's order.
    var okChecks: [Int] { list.indices.filter { list[$0].ok } }

    /// The rows J and K go through, in the page's order: those listed (marked OK only while shown).
    var order: [Int] {
        items.compactMap { if case .check(let i) = $0.kind { return i } else { return nil } }
    }

    /// The groups with checks, in `items`' order: each title with its checks.
    var sections: [(title: String, checks: [Int])] {
        var out: [(title: String, checks: [Int])] = []
        for item in items {
            switch item.kind {
            case .group(let g): out.append((g, []))
            case .check(let i): if !out.isEmpty, !list[i].ok { out[out.count - 1].checks.append(i) }
            case .message, .ok: break
            }
        }
        return out
    }

    /// The page's sentence under the tabs.
    var sentence: String {
        switch phase {
        case .hidden: return "This round has no checks: it has no PDF, or its pages could not be read."
        case .asking: return "Checking…"
        case .ready:
            if list.isEmpty { return "No problems found in this round’s PDF." }
            if list.allSatisfy(\.ok) { return "Every check of this round’s PDF is marked OK." }
            return "Slips found in this round’s PDF. A click shows one on the page; nothing reaches the student unless "
                + "you comment."
        }
    }

    /// The tab's title: its count of checks not marked OK once the checks are in.
    var tabTitle: String {
        let n = list.filter { !$0.ok }.count
        return phase == .ready && n > 0 ? "Checks \(n)" : "Checks"
    }

    static func title(_ group: String) -> String {
        groups.first { $0.id == group }?.title ?? (group.prefix(1).uppercased() + group.dropFirst())
    }
}

/// A check's right-click menu item (`AppModel.checkMenu`): Mark as OK (or Not OK), Comment…, Keep Open, Copy.
struct CheckMenuItem: Identifiable, Equatable {
    enum Action: Equatable { case ok, comment, keepOpen, copy }
    var action: Action
    var title: String
    var enabled: Bool
    var id: String { title }
}

/// A check row's hover, observed by its row alone.
@MainActor
final class CheckLook: ObservableObject {
    @Published var hovering = false
}

/// The Checks tab's page (UX.md §39; PLAN P1.5), while Settings › Reading's Checks is on: a sentence, then per group its
/// title and a card of its rows, in the engine's order. A click on a row goes to its place, a second click to its next.
struct ChecksPage: View {
    @EnvironmentObject var model: AppModel

    var body: some View { ChecksList(checks: model.checks, model: model) }
}

private struct ChecksList: View {
    @ObservedObject var checks: ChecksModel
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Text(checks.sentence)
                .font(.system(size: 12.5))
                .foregroundStyle(Ink.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {  // every row built, so scrollTo finds any (a few dozen)
                        ForEach(checks.sections, id: \.title) { section in
                            ChecksGroup(checks: checks, model: model, title: section.title, rows: section.checks)
                        }
                        let ok = checks.okChecks
                        if !ok.isEmpty {
                            ChecksGroup(checks: checks, model: model, title: "Marked OK", rows: checks.showOK ? ok : [],
                                        count: ok.count, fold: { checks.showOK.toggle() })
                        }
                    }
                    .padding(.bottom, 16)
                }
                .onChange(of: checks.current) { _, i in if let i { proxy.scrollTo(i) } }  // J and K keep it in view
            }
        }
    }
}

/// A group's title (13 Semibold, its count after it) and a card of its rows, hairlines between them.
private struct ChecksGroup: View {
    @ObservedObject var checks: ChecksModel
    let model: AppModel
    let title: String
    let rows: [Int]
    /// The marked OK group: its count (its rows may be folded) and its Show / Hide.
    var count: Int?
    var fold: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(fold == nil ? Ink.label : Ink.secondary)
            Text("\(count ?? rows.count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(Ink.secondary)
            if let fold {
                Spacer(minLength: 4)
                Button(rows.isEmpty ? "Show" : "Hide", action: fold).buttonStyle(LinkStyle()).font(.system(size: 12))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 6)
        if !rows.isEmpty { card }
    }

    private var card: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element) { k, i in
                if i < checks.list.count {
                    CheckRow(check: checks.list[i], current: checks.current == i, rule: k > 0, look: checks.look(i),
                             hover: { checks.hover(i, $0) }, mark: { model.markCheckClicked(i) })
                        .id(i)
                        .onTapGesture { model.checkClicked(i) }
                        .contextMenu { CheckMenu(checks: checks, model: model, index: i) }
                }
            }
        }
        .background(Color(nsColor: Palette.card))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: Palette.cardLine), lineWidth: 1))
        .padding(.horizontal, 12)
    }
}

/// A check: its words (13, the label colour; one marked OK in the second) and its places' pages at the right in the
/// second colour, the detail under them (12, the second colour), whole; the row chosen last on the accent's tint, the
/// pointer's on the hover fill, with a check mark button before the pages: Mark as OK (or Not OK).
struct CheckRow: View {
    let check: Check
    var current = false
    var rule = false
    @ObservedObject var look = CheckLook()
    var hover: (Bool) -> Void = { _ in }
    var mark: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(check.text).font(.system(size: 13)).foregroundStyle(check.ok ? Ink.secondary : Ink.label)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button(action: mark) {  // laid out always, so the words never wrap again under the pointer
                    Image(systemName: check.ok ? "checkmark.circle.fill" : "checkmark.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(check.ok ? Ink.accentText : Ink.secondary)
                }
                .buttonStyle(.plain)
                .help(check.ok ? "Mark as Not OK" : "Mark as OK: the paper is fine here")
                .opacity(look.hovering ? 1 : 0)
                .allowsHitTesting(look.hovering)
                if let t = check.trail {
                    Text(t).font(.system(size: 11).monospacedDigit()).foregroundStyle(Ink.secondary).fixedSize()
                }
            }
            if let d = check.detail, !d.isEmpty {
                Text(d).font(.system(size: 12)).foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(current ? Color(nsColor: Palette.accentTint) : look.hovering ? Color(nsColor: Palette.hover) : .clear)
        .overlay(alignment: .top) {
            if rule { Rectangle().fill(Color(nsColor: Palette.rule)).frame(height: 1).padding(.leading, 12) }
        }
        .contentShape(Rectangle())
        .onHover(perform: hover)
        .help(check.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([check.text, check.trail, check.detail].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(current ? [.isButton, .isSelected] : .isButton)
        .accessibilityValue(check.ok ? "Marked OK" : "")
        .accessibilityAction(named: check.ok ? "Mark as Not OK" : "Mark as OK") { mark() }
    }
}

/// A check's right-click menu (`AppModel.checkMenu`), drawn again when Comment… becomes possible or not.
private struct CheckMenu: View {
    @ObservedObject var checks: ChecksModel
    let model: AppModel
    let index: Int

    var body: some View {
        let _ = checks.canComment
        ForEach(model.checkMenu(index)) { item in
            Button(item.title) { model.pickCheckMenu(index, item.action) }.disabled(!item.enabled)
        }
    }
}
