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
    /// Marked OK by the advisor (the paper is fine there): never sent, or once sent closed as no change needed.
    var ok: Bool
    /// The item's id, "A2-03" (engine/CONTRACT.md amendment "Checks to the student"): nil from an engine before check
    /// items, whose checks show without ids.
    var id: String?
    /// "new", "still" (found again), "fixed" (no longer found: closed by Paperole), or nil (not checked this round, or
    /// an engine before check items, read as new).
    var state: String?
    /// It went to the student in an earlier round.
    var carried: Bool
    /// The student's `% A2-03 …` of this round, and the advisor's follow-up words.
    var studentNote: StudentNote?
    var advisorNote: String?
    /// Its earlier rounds, oldest first.
    var history: [Record]

    /// One earlier round of a check item.
    struct Record: Decodable, Equatable {
        var round: Int
        var state: String?
        var studentNote: StudentNote?
        var advisorNote: String?
    }

    init(code: String, group: String, text: String, detail: String? = nil, note: String? = nil, places: [Place] = [],
         ok: Bool = false, id: String? = nil, state: String? = nil, carried: Bool = false,
         studentNote: StudentNote? = nil, advisorNote: String? = nil, history: [Record] = []) {
        self.code = code
        self.group = group
        self.text = text
        self.detail = detail
        self.note = note
        self.places = places
        key = code + "|" + text
        self.ok = ok
        self.id = id
        self.state = state
        self.carried = carried
        self.studentNote = studentNote
        self.advisorNote = advisorNote
        self.history = history
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
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? nil
        state = (try? c.decodeIfPresent(String.self, forKey: .state)) ?? nil
        carried = ((try? c.decodeIfPresent(Bool.self, forKey: .carried)) ?? nil) ?? false
        studentNote = (try? c.decodeIfPresent(StudentNote.self, forKey: .studentNote)) ?? nil
        advisorNote = ((try? c.decodeIfPresent(String.self, forKey: .advisorNote)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
        history = ((try? c.decodeIfPresent([Record].self, forKey: .history)) ?? nil) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case code, group, text, detail, note, places, key, ok, id, state, carried, studentNote, advisorNote, history
    }

    /// No longer found: Paperole closed it.
    var fixed: Bool { state == "fixed" }
    /// Closed this round: fixed, or marked OK.
    var closed: Bool { fixed || ok }
    /// Found again and answered by the student this round: the advisor's move (To check), while the round is open.
    var answered: Bool { carried && !closed && studentNote != nil }

    /// Its status as a comment's would read: new (+), still open (○), fixed (✓), marked OK (–).
    var status: Status { ok ? .keptAsIs : fixed ? .resolved : carried ? .toCheck : .new }

    /// The row's word after the id.
    var stateWord: String { ok ? "marked OK" : fixed ? "fixed" : carried ? "still found" : "new" }

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

/// The engine's `check_items` reply (no state): the round's check items, synced with its checks while it is open.
struct CheckItemsReply: Decodable {
    var round: Int?
    var items: [Check]?
}

/// A row of the Checks tab: a line of words ("Checking…", "No problems found"), a group's header (as the Comments
/// tab's: To check, For the student, Closed this round, with its count), a kind's title inside For the student
/// (References…), or a check (its index in the list).
struct ChecksItem: Identifiable, Equatable {
    enum Kind: Equatable { case message(String), group(ChecksModel.Group, Int), kind(String), check(Int) }
    var kind: Kind

    var id: String {
        switch kind {
        case .message(let m): return "m:" + m
        case .group(let g, _): return "g:" + g.rawValue
        case .kind(let k): return "k:" + k
        case .check(let i): return "c:\(i)"
        }
    }
}

/// The panel's Checks (UX.md §39), observed only by its tab and page: the shown round's checks, whether they are being
/// asked for, and the row last clicked with the place it went to.
@MainActor
final class ChecksModel: ObservableObject {
    /// Per-rule choices in Settings; an empty disabled set keeps the existing behaviour.
    static let writingRules: [(code: String, title: String, group: String, help: String)] = [
        ("short_last_line", "Short last lines", "typesetting", "A paragraph ending in one word or symbol."),
        ("paragraph_break", "Single-line paragraph breaks", "typesetting", "One paragraph line left across a page or column break."),
        ("heading_break", "Hanging headings", "typesetting", "A heading with fewer than two following lines before a break."),
        ("split_phrase", "Split references and units", "typesetting", "Figure 3 or 10 GB split across lines."),
        ("draft_marker", "Draft markers", "submission", "TODO, TBD, [Ref], [??] and [citation needed] left in the PDF."),
        ("sentence_start", "Sentence openings", "typesetting", "A sentence starting with inline math or a numeric citation.")
    ]

    /// The tab's groups, as the Comments tab's (UX.md §39, design/checks-ui): the checks the student answered (the
    /// advisor's move), those that go out, and those closed this round (fixed by the student, or marked OK).
    enum Group: String, Equatable {
        case toCheck, forStudent, closed

        var title: String {
            switch self {
            case .toCheck: return "To check"
            case .forStudent: return "For the student"
            case .closed: return "Closed this round"
            }
        }
    }

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
    /// Closed this round listed under its header (Show), else folded into it, as at first; For the student shown
    /// until hidden.
    @Published var showClosed = false
    @Published var showStudent = true
    /// The round shown is open: an answered check is To check (the advisor's move); in a closed round it is one of
    /// those that went out.
    @Published var roundOpen = false
    /// The look-ups still running, said under the sentence ("Looking up references on Google Scholar · 12 of 34");
    /// nil when none run.
    @Published var progress: String?
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
        // the same round built again (the look-ups' results came): the row chosen stays chosen, by its id
        let keep = self.key == key ? current.flatMap { list.indices.contains($0) ? list[$0].id : nil } : nil
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
        if let keep { current = list.firstIndex { $0.id == keep } }
        phase = .ready
        version += 1
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
        version += 1
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
        version += 1
    }

    /// Check `i`'s follow-up words as the engine keeps them (nil: none).
    func setAdvisorNote(_ i: Int, _ text: String?) {
        guard list.indices.contains(i), list[i].advisorNote != text else { return }
        list[i].advisorNote = text
    }

    /// Bumped whenever the checks or their marks change (a new list, Mark as OK): the PDF's marks follow it.
    private(set) var version = 0

    /// Check `id`'s index ("A2-03").
    func index(of id: String) -> Int? { list.firstIndex { $0.id == id } }

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

    /// Check `i`'s group.
    func group(_ i: Int) -> Group {
        let c = list[i]
        return c.closed ? .closed : roundOpen && c.answered ? .toCheck : .forStudent
    }

    /// Each group's checks, in the engine's order (For the student by kind, in the kinds' order, an unknown kind after
    /// them).
    func members(_ g: Group) -> [Int] {
        let ids = list.indices.filter { group($0) == g }
        guard g == .forStudent else { return ids }
        return kinds.flatMap { k in ids.filter { list[$0].group == k } }
    }

    /// The kinds present, in their order (an unknown one after them, under its own name).
    private var kinds: [String] {
        var order = Self.groups.map(\.id)
        for c in list where !order.contains(c.group) { order.append(c.group) }
        return order
    }

    /// The page's rows: "Checking…" while asked; "No problems found"; else the groups with checks, each its header and,
    /// unless folded, its checks (For the student under its kinds' titles); Closed this round folded until shown.
    var items: [ChecksItem] {
        switch phase {
        case .hidden: return []
        case .asking: return [ChecksItem(kind: .message("Checking…"))]
        case .ready:
            guard !list.isEmpty else { return [ChecksItem(kind: .message("No problems found"))] }
            var out: [ChecksItem] = []
            for g in [Group.toCheck, .forStudent, .closed] {
                let ids = members(g)
                guard !ids.isEmpty else { continue }
                out.append(ChecksItem(kind: .group(g, ids.count)))
                guard g == .closed ? showClosed : g == .forStudent ? showStudent : true else { continue }
                var last: String?
                for i in ids {
                    if g == .forStudent && list[i].group != last {
                        last = list[i].group
                        out.append(ChecksItem(kind: .kind(Self.title(list[i].group))))
                    }
                    out.append(ChecksItem(kind: .check(i)))
                }
            }
            return out
        }
    }

    /// The rows J and K go through, in the page's order: those listed (a folded group's not).
    var order: [Int] {
        items.compactMap { if case .check(let i) = $0.kind { return i } else { return nil } }
    }

    /// What goes to the student with the round (not closed), and how many of the round's checks are marked OK.
    var sent: Int { list.filter { !$0.closed }.count }
    var markedOK: Int { list.filter(\.ok).count }

    /// Closed this round's quieter words: "4 fixed · 1 marked OK".
    var closedWords: String {
        let f = list.filter(\.fixed).count, k = markedOK
        return [f > 0 ? "\(f) fixed" : nil, k > 0 ? "\(k) marked OK" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    /// The page's sentence under the tabs.
    var sentence: String {
        switch phase {
        case .hidden: return "This round has no checks: it has no PDF, or its pages could not be read."
        case .asking: return "Checking…"
        case .ready:
            if list.isEmpty { return roundOpen ? "No problems found in this round’s PDF." : "No checks went out with this round." }
            if !roundOpen { return "Found by Paperole." }
            if sent == 0 { return "Nothing goes to the student: every check is fixed or marked OK." }
            return "Found by Paperole. They go to the student with your comments."
        }
    }

    /// The tab's title, as the Comments tab's: the checks to check (the student answered them) in an open round.
    var tabTitle: String {
        let n = phase == .ready && roundOpen ? members(.toCheck).count : 0
        return n > 0 ? "Checks \(n)" : "Checks"
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

/// The Checks tab's page (UX.md §39; design/checks-ui), while Settings › Reading's Checks is on: a sentence, then the
/// groups as the Comments tab's (their headers, 44 pt rows with a slate bar, the selected check's card raised). A click
/// on a row selects it and goes to its place, a second click to its next.
struct ChecksPage: View {
    @EnvironmentObject var model: AppModel

    var body: some View { ChecksList(checks: model.checks, model: model) }
}

/// The groups' headers' pointer states, one per group, kept while the page lives.
@MainActor
private final class ChecksHeads: ObservableObject {
    let toCheck = HeaderState(), forStudent = HeaderState(), closed = HeaderState()

    func state(_ g: ChecksModel.Group) -> HeaderState {
        switch g {
        case .toCheck: return toCheck
        case .forStudent: return forStudent
        case .closed: return closed
        }
    }
}

private struct ChecksList: View {
    @ObservedObject var checks: ChecksModel
    let model: AppModel
    @StateObject private var heads = ChecksHeads()

    var body: some View {
        VStack(spacing: 0) {
            Text(checks.sentence + (checks.progress.map { "\n" + $0 } ?? ""))
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
                        ForEach(checks.items) { item in row(item) }
                    }
                    .padding(.bottom, 16)
                }
                .onChange(of: checks.current) { _, i in if let i { proxy.scrollTo(i) } }  // J and K keep it in view
            }
        }
    }

    @ViewBuilder private func row(_ item: ChecksItem) -> some View {
        switch item.kind {
        case .message:
            EmptyView()  // the sentence says it
        case .group(let g, let n):
            header(g, n)
        case .kind(let k):
            Text(k).font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.secondary)
                .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                .padding(.leading, SectionHeader.lead)
                .accessibilityAddTraits(.isHeader)
        case .check(let i):
            if i < checks.list.count {
                Group {
                    if checks.current == i {
                        CheckCard(check: checks.list[i], round: checks.round ?? 0, open: checks.roundOpen,
                                  toCheck: checks.group(i) == .toCheck, student: model.state?.paper.student ?? "",
                                  actions: CheckCardActions(model: model, index: i))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    } else if checks.list[i].closed {
                        CheckClosedLine(check: checks.list[i], look: checks.look(i), hover: { checks.hover(i, $0) })
                            .padding(.horizontal, 10)
                            .onTapGesture { model.checkClicked(i) }
                    } else {
                        CheckLine(check: checks.list[i], open: checks.roundOpen, underToCheck: checks.group(i) == .toCheck,
                                  look: checks.look(i), hover: { checks.hover(i, $0) }, mark: { model.markCheckClicked(i) })
                            .padding(.horizontal, 10)
                            .onTapGesture { model.checkClicked(i) }
                    }
                }
                .id(i)
                .contextMenu { CheckMenu(checks: checks, model: model, index: i) }
            }
        }
    }

    /// A group's header, the Comments tab's (`SectionHeader`): For the student and Closed this round fold with Show /
    /// Hide; To check never does.
    private func header(_ g: ChecksModel.Group, _ n: Int) -> some View {
        let fold: (() -> Void)? = switch g {
        case .toCheck: nil
        case .forStudent: { checks.showStudent.toggle() }
        case .closed: { checks.showClosed.toggle() }
        }
        let shown = g == .closed ? checks.showClosed : g == .forStudent ? checks.showStudent : true
        let sub: String = switch g {
        case .toCheck: "the student answered"
        case .forStudent: checks.roundOpen ? "goes in the Round \(checks.round ?? 0) final.pdf"
            : "in the Round \(checks.round ?? 0) final.pdf"
        case .closed: checks.closedWords
        }
        let glyph: HeaderGlyph = switch g {
        case .toCheck: .toCheck(open: checks.roundOpen)
        case .forStudent: .student
        case .closed: .closed
        }
        let state = heads.state(g)
        return SectionHeader(text: g.title, sub: sub, count: n, glyph: glyph, button: fold == nil ? nil : shown ? "Hide" : "Show",
                             action: fold, state: state)
            .frame(height: 34)
            .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: Palette.rule)).frame(height: 1) }
            .contentShape(Rectangle())
            .onHover { state.hovering = fold != nil && $0 }
            .onTapGesture { fold?() }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A check's 3 pt bar in Paperole's slate, where a comment's row has its mark's colour.
private struct CheckBar: View {
    let faded: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5).fill(Color(nsColor: Palette.checkBar)).frame(width: 3)
            .opacity(faded ? 0.45 : 1).padding(.leading, 6)
    }
}

/// A check not selected, as a comment's row (`CompactRow`): 44 pt, the slate bar, its id and its word, the student's
/// note sign, its pages; its words under them. Under the pointer, a check mark button before the pages: Mark as OK
/// (or Not OK).
struct CheckLine: View {
    let check: Check
    var open = true
    var underToCheck = false
    @ObservedObject var look = CheckLook()
    var hover: (Bool) -> Void = { _ in }
    var mark: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 7) {
                if let id = check.id {
                    Chip(id: id, status: check.status, compact: true, open: open, sign: !underToCheck)
                    Text(check.stateWord).font(.system(size: 12)).foregroundStyle(Ink.secondary)
                }
                if check.studentNote != nil { StudentNoteSign() }
                Spacer(minLength: 4)
                if open && !check.fixed {
                    Button(action: mark) {  // laid out always, so nothing moves under the pointer
                        Image(systemName: check.ok ? "checkmark.circle.fill" : "checkmark.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(check.ok ? Ink.accentText : Ink.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(check.ok ? "Mark as Not OK" : "Mark as OK: the paper is fine here")
                    .opacity(look.hovering ? 1 : 0)
                    .allowsHitTesting(look.hovering)
                }
                if let t = check.trail {
                    Text(t).font(.system(size: 11)).monospacedDigit().foregroundStyle(Ink.secondary).fixedSize()
                }
            }
            .frame(height: 18)
            Text(check.text).font(.system(size: 13)).foregroundStyle(check.closed ? Ink.secondary : Ink.label)
                .lineLimit(1).truncationMode(.tail)
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44, alignment: .leading)
        .overlay(alignment: .leading) { CheckBar(faded: check.closed).padding(.vertical, 10) }
        .background(RoundedRectangle(cornerRadius: 6).fill(look.hovering ? Color(nsColor: Palette.hover) : .clear))
        .contentShape(Rectangle())
        .onHover(perform: hover)
        .help(check.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([check.id, check.id == nil ? nil : check.stateWord, check.text, check.trail]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(check.ok ? "Marked OK" : "")
        .accessibilityAction(named: check.ok ? "Mark as Not OK" : "Mark as OK") { mark() }
    }
}

/// A check closed this round, as a comment's `ClosedLine`: one 30 pt line, its sign and id, "fixed" or "marked OK"
/// and its words.
struct CheckClosedLine: View {
    let check: Check
    @ObservedObject var look = CheckLook()
    var hover: (Bool) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 8) {
            if let id = check.id { Chip(id: id, status: check.status, compact: true) }
            Text(check.stateWord + " · " + check.text)
                .font(.system(size: 12)).foregroundStyle(Ink.secondary).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .leading)
        .overlay(alignment: .leading) { CheckBar(faded: true).padding(.vertical, 8) }
        .background(RoundedRectangle(cornerRadius: 6).fill(look.hovering ? Color(nsColor: Palette.hover) : .clear))
        .contentShape(Rectangle())
        .onHover(perform: hover)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([check.id, check.stateWord, check.text].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
    }
}

/// What a check's card does (`AppModel`): Mark as OK or Not OK, My Comment… (a new check) or Follow up… (one that
/// went out before), and its pages.
@MainActor
struct CheckCardActions {
    let model: AppModel
    let index: Int

    func mark() { model.markCheckClicked(index) }
    func comment() { model.pickCheckMenu(index, .comment) }
    func followUp(_ text: String) { model.followUpCheck(index, text) }
    func go() { model.checkClicked(index) }
}

/// The selected check, raised as the selected comment's card (`ExpandedCard`): its chip and state, its kind, its pages;
/// its finding as the title and the sentence the student reads under it; the place as printed; from its second round
/// its thread (found, the student's answers, your follow-ups, found again); what happens to it; and in an open round
/// the answer row.
struct CheckCard: View {
    let check: Check
    let round: Int
    let open: Bool
    let toCheck: Bool
    let student: String
    let actions: CheckCardActions
    @State private var following = false
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Text(check.text).font(.system(size: 15, weight: .semibold)).lineSpacing(2.5)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 10)
                .textSelection(.enabled)
            if let n = check.note, !n.isEmpty {
                Text(n).font(CardType.words).foregroundStyle(Ink.label2).lineSpacing(CardType.wordsSpacing)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 2)
            }
            if let d = check.detail, !d.isEmpty, (check.note ?? "").isEmpty {  // the note says it for the student
                Text(d).font(.system(size: 12)).foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            }
            if let t = check.places.first?.text, !t.isEmpty, !check.text.contains(t) {  // not said twice
                Text(t).font(CardType.paper).lineSpacing(CardType.paperSpacing).foregroundStyle(Ink.label2)
                    .lineLimit(4).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) { Rectangle().fill(Color(nsColor: Palette.rule)).frame(width: 2) }
                    .padding(.top, 8)
            }
            if check.carried { thread.padding(.top, 12) }
            if let why {
                HStack(spacing: 6) {
                    Image(systemName: check.closed ? "checkmark.circle" : "envelope").font(.system(size: 11))
                    Text(why)
                }
                .font(.system(size: 12)).foregroundStyle(Ink.secondary).padding(.top, 10)
            }
            if open && check.id != nil && !check.fixed { answers.padding(.top, 12) }
        }
        .fixedSize(horizontal: false, vertical: true)
        .modifier(RaisedCard())
        .foregroundStyle(Ink.label)
        .onChange(of: check.id) { following = false; draft = "" }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let id = check.id {
                // the vermilion ring only for the advisor's move (the student answered); a check found again that the
                // student did not answer is still open, in the neutral look
                Chip(id: id, status: toCheck ? .toCheck : check.status, open: toCheck ? open : false)
                Text(word).font(.system(size: 12, weight: toCheck ? .medium : .regular))
                    .foregroundStyle(toCheck ? Ink.label : Ink.secondary)
            }
            Spacer(minLength: 4)
            if let t = check.trail {
                Button(t, action: actions.go).buttonStyle(.plain).monospacedDigit()
                    .help(check.places.count > 1 ? "Show its places in turn in the PDF" : "Show it in the PDF")
            }
        }
        .frame(height: 20)
    }

    /// The card's status word, as a comment's.
    private var word: String {
        if toCheck { return "To check" }
        if check.ok { return "Marked OK" }
        if check.fixed { return "Fixed" }
        return check.carried ? "Still found" : "New"
    }

    /// What happens to it, in one quiet line, when its group's header does not say it already.
    private var why: String? {
        if check.ok { return check.carried ? "Closed as no change needed" : "Marked OK: not sent" }
        if check.fixed { return "No longer found in Round \(round): closed by Paperole" }
        if toCheck { return "Goes out again unless you mark it OK" }
        return nil
    }

    /// Its rounds, as a card's turns: found, then each later round's answer, follow-up and finding.
    private var thread: some View {
        let first = check.id.flatMap { Int($0.dropFirst().split(separator: "-").first ?? "") }
        var turns: [(label: String, words: String?, place: String?)] = []
        if let first { turns.append(("R\(first) · found by Paperole", nil, nil)) }
        func add(_ k: Int, _ state: String?, _ note: StudentNote?, _ mine: String?) {
            if let note, !note.text.isEmpty {
                turns.append(("R\(k) · \(student.isEmpty ? "the student" : student) answered", note.text,
                              note.file.map { f in note.line.map { "\(f):\($0)" } ?? f }))
            }
            if let mine, !mine.isEmpty { turns.append(("R\(k) · you followed up", mine, nil)) }
            if state == "still" { turns.append(("R\(k) · still found", nil, nil)) }
            if state == "fixed" { turns.append(("R\(k) · no longer found", nil, nil)) }
        }
        for r in check.history where r.round != first { add(r.round, r.state, r.studentNote, r.advisorNote) }
        add(round, check.state, check.studentNote, check.advisorNote)
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(turns.enumerated()), id: \.offset) { _, t in
                VStack(alignment: .leading, spacing: 4) {
                    Text(t.label).font(CardType.label).foregroundStyle(Ink.secondary)
                    if let w = t.words {
                        WordsBubble(text: w, place: t.place.map { Turn.Place(short: ($0 as NSString).lastPathComponent, full: $0) })
                    }
                }
            }
        }
    }

    @ViewBuilder private var answers: some View {
        if following {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $draft).font(CardType.words).frame(minHeight: 54)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: Palette.bubble)))
                AnswerRow {
                    Button("Send") { actions.followUp(draft); following = false }
                        .buttonStyle(AnswerButtonStyle(style: .default))
                        .disabled(AppModel.trimmed(draft).isEmpty)
                    Button("Cancel") { following = false }.buttonStyle(AnswerButtonStyle(style: .plain))
                }
            }
        } else {
            AnswerRow {
                Button { actions.mark() } label: {
                    Label(check.ok ? "Mark as Not OK" : "Mark as OK", systemImage: check.ok ? "arrow.uturn.backward" : "checkmark.circle")
                }
                .buttonStyle(AnswerButtonStyle(style: .plain))
                if !check.closed {
                    if check.carried {
                        Button("Follow Up…") { draft = check.advisorNote ?? ""; following = true }
                            .buttonStyle(AnswerButtonStyle(style: .plain))
                    } else {
                        Button("My Comment…", action: actions.comment).buttonStyle(AnswerButtonStyle(style: .plain))
                            .help("Write it as your own comment: the check is then marked OK")
                    }
                }
            }
        }
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
