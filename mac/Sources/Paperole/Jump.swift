import AppKit
import SwiftUI

/// Jump (POLISH §3 row 12, §6): one panel, opened by the sidebar's "Jump to…" or ⌘K, that goes to a comment by its id,
/// your words or the words it is on, to another edit, a section, a round, or runs a command; the paper's own text is
/// not indexed (its paragraphs carry no words): the last row hands the query to the PDF's find. A faster way to places
/// the app already has, not a mode. The search is pure, so it is unit-tested.
enum Jump {
    enum Target: Equatable {
        case comment(String), edit(String), section(Int), round(Int), command(Command), find(String), page(Int)
    }

    /// The commands Jump offers: the toolbar's and the menus' (`AppModel.runJump`).
    enum Command: String, CaseIterable {
        case focus, finish, next, changeMarks, underline, comments, changes, newRound, summary, finalPDF, newPaper, addPaper
    }

    struct Row: Equatable {
        var target: Target
        var icon: String
        var lead = ""  // the comment's id, the section's number
        var title: String
        var detail = ""  // "on “…when boat traffic is low…”"
        var trailing = ""  // "p.4"; "shown" for the round shown
        var words: [String] = []  // the query's words: drawn Semibold where the title and detail have them
    }

    struct Group: Equatable {
        var title: String
        var rows: [Row]
    }

    struct CommentSource: Equatable {
        var id: String
        var status: Status
        var note: String
        var words: String  // the words the comment is on (this round's sentence, else its anchor's text)
        var said: String  // this round's follow-up or closing remark
        var page: Int?
        var overall = false  // on the whole paper: "overall" where the page goes
    }

    struct EditSource: Equatable {
        var id: String
        var kind: ChangeModel.Kind
        var place: String
        var excerpt: String
        var page: Int?
    }

    struct CommandSource: Equatable {
        var command: Command
        var title: String
        var icon: String
    }

    struct Sources {
        var comments: [CommentSource] = []  // in the list's order
        var edits: [EditSource] = []  // the edits no comment asked for, in the list's order
        var sections: [OutlineRow] = []
        var rounds: [RoundSummary] = []
        var shownRound: Int?
        var commands: [CommandSource] = []  // those that can act now
        var pages = 0  // the shown PDF's page count (0: none)
    }

    /// How many rows a group shows at most.
    static let limits = (comments: 8, edits: 5, sections: 6, commands: 8)

    /// The query's words, lower case.
    static func words(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func has(_ text: String, _ word: String) -> Bool {
        text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// Every word of the query is in one of the fields.
    static func matches(_ words: [String], _ fields: [String]) -> Bool {
        words.allSatisfy { w in fields.contains { has($0, w) } }
    }

    /// Up to `width` characters of `text` round the first of `words` in it, cut at word boundaries, with … at a cut.
    static func snippet(_ text: String, around words: [String], width: Int = 56) -> String {
        let t = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard t.count > width else { return t }
        let hit = words.compactMap { t.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }
            .min { $0.lowerBound < $1.lowerBound }
        let at = hit.map { t.distance(from: t.startIndex, to: $0.lowerBound) } ?? 0
        var start = max(0, min(at - width / 3, t.count - width)), end = min(t.count, start + width)
        let chars = Array(t)
        while start > 0, !chars[start - 1].isWhitespace { start -= 1 }
        while end < chars.count, !chars[end].isWhitespace { end += 1 }
        return (start > 0 ? "…" : "") + String(chars[start..<end]).trimmingCharacters(in: .whitespaces) + (end < chars.count ? "…" : "")
    }

    /// The page a query names (design/pdf-reader/PLAN.md P1.4): "p.12", "p 12", "p12" or "page 12", any case, as the
    /// index from 0, when the PDF has it.
    static func page(_ query: String, count: Int) -> Int? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let m = q.wholeMatch(of: #/(?:p\.?|page)\s*(\d{1,5})/#), let n = Int(m.1), n >= 1, n <= count else { return nil }
        return n - 1
    }

    /// The groups for a query, in this order: the page it names, Comments (as the list orders them), Unasked edits,
    /// Sections, Rounds, Commands, and with any query "In the paper", the PDF's find. With no query: the rounds and the
    /// commands.
    static func search(_ query: String, in s: Sources) -> [Group] {
        let ws = words(query)
        var groups: [Group] = []
        if let p = page(query, count: s.pages) {
            groups.append(Group(title: "Pages", rows: [Row(target: .page(p), icon: "doc", title: "Go to p.\(p + 1)",
                                                           trailing: "of \(s.pages)")]))
        }
        if !ws.isEmpty {
            let comments = s.comments.filter { matches(ws, [$0.id, $0.note, $0.words, $0.said]) }.prefix(limits.comments).map { c in
                let first = c.note.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                // where the words are, when the note does not have them all: the words it is on, or what you wrote
                let rest = ws.filter { !has(c.id, $0) && !has(first, $0) }
                var detail = ""
                if !rest.isEmpty {
                    if rest.contains(where: { has(c.words, $0) }) {
                        detail = "on “" + snippet(c.words, around: rest) + "”"
                    } else if rest.contains(where: { has(c.said, $0) }) {
                        detail = "you wrote “" + snippet(c.said, around: rest) + "”"
                    }
                }
                return Row(target: .comment(c.id), icon: c.status.icon, lead: c.id,
                           title: first.isEmpty ? "“" + snippet(c.words, around: ws) + "”" : first, detail: detail,
                           trailing: c.overall ? "overall" : c.page.map { "p.\($0 + 1)" } ?? "", words: ws)
            }
            if !comments.isEmpty { groups.append(Group(title: "Comments", rows: Array(comments))) }
            let edits = s.edits.filter { matches(ws, [$0.place, $0.kind.word, $0.excerpt]) }.prefix(limits.edits).map { e in
                Row(target: .edit(e.id), icon: e.kind.symbol, title: e.place,
                    detail: e.kind.word.capitalized + (e.excerpt.isEmpty ? "" : ": “" + snippet(e.excerpt, around: ws) + "”"),
                    trailing: e.page.map { "p.\($0 + 1)" } ?? "", words: ws)
            }
            if !edits.isEmpty { groups.append(Group(title: "Unasked edits", rows: Array(edits))) }  // the one noun (BRIEF §8)
            let sections = s.sections.filter { matches(ws, [$0.number ?? "", $0.name.isEmpty ? $0.title : $0.name]) }
                .prefix(limits.sections).map { r in
                    Row(target: .section(r.block), icon: "list.bullet.indent", lead: r.number ?? "",
                        title: r.name.isEmpty ? r.title : r.name, words: ws)
                }
            if !sections.isEmpty { groups.append(Group(title: "Sections", rows: Array(sections))) }
        }
        let rounds = s.rounds.filter { r in
            ws.isEmpty || matches(ws, ["Round \(r.n)", "R\(r.n)", RoundPicker.title(r)])
        }.map { r in
            Row(target: .round(r.n), icon: r.closed ? "lock" : "tray.full", title: RoundPicker.title(r),
                trailing: r.n == s.shownRound ? "shown" : "", words: ws)
        }
        if !rounds.isEmpty { groups.append(Group(title: "Rounds", rows: rounds)) }
        let commands = s.commands.filter { ws.isEmpty || matches(ws, [$0.title]) }.prefix(limits.commands).map { c in
            Row(target: .command(c.command), icon: c.icon, title: c.title, words: ws)
        }
        if !commands.isEmpty { groups.append(Group(title: "Commands", rows: Array(commands))) }
        let q = ws.joined(separator: " ")
        if !q.isEmpty {
            groups.append(Group(title: "In the paper", rows: [
                Row(target: .find(query.trimmingCharacters(in: .whitespacesAndNewlines)), icon: "magnifyingglass",
                    title: "Find “\(query.trimmingCharacters(in: .whitespacesAndNewlines))” in the paper")]))
        }
        return groups
    }

    /// A row's words, the query's words in it Semibold in the label colour (the mockup's marks).
    static func styled(_ text: String, _ words: [String], color: Color) -> AttributedString {
        var a = AttributedString(text)
        a.foregroundColor = color
        for w in words where !w.isEmpty {
            var from = a.startIndex
            while from < a.endIndex, let r = a[from...].range(of: w, options: [.caseInsensitive, .diacriticInsensitive]) {
                a[r].font = .system(size: 13, weight: .semibold)
                a[r].foregroundColor = Ink.label
                from = r.upperBound
            }
        }
        return a
    }
}

/// The Jump panel's state; only the panel observes it. The query is kept when it closes, so the next open starts from
/// it (selected, so typing replaces it) and "Find … in the paper" goes on to the next match.
@MainActor
final class JumpModel: ObservableObject {
    @Published private(set) var shown = false
    @Published private(set) var query = ""
    @Published private(set) var groups: [Jump.Group] = []
    @Published var highlighted = 0
    /// Counts the highlight's moves by ↑ and ↓ or a new query: the list scrolls to the highlighted row after each (not
    /// after a hover), so Return never goes to a row out of view.
    @Published private(set) var reveals = 0
    /// What there is to jump to, from the app's model when the panel opens or the query changes.
    var sources: () -> Jump.Sources = { Jump.Sources() }
    /// Where each row is, in the window's SwiftUI coordinates (--debug-script jumpclick); not published.
    var frames: [Int: CGRect] = [:]

    var rows: [Jump.Row] { groups.flatMap(\.rows) }

    func open() {
        groups = Jump.search(query, in: sources())
        highlighted = 0
        frames = [:]
        shown = true
    }

    func close() { if shown { shown = false } }

    func setQuery(_ q: String) {
        guard q != query else { return }
        query = q
        groups = Jump.search(q, in: sources())
        highlighted = 0
        reveals += 1
    }

    /// ↑ and ↓ in the field: the highlighted row, wrapping.
    func move(_ d: Int) {
        let n = rows.count
        guard n > 0 else { return }
        highlighted = ((highlighted + d) % n + n) % n
        reveals += 1
    }
}

/// Over the window while Jump is open: a click outside the panel closes it.
struct JumpOverlay: View {
    @ObservedObject var jump: JumpModel
    let model: AppModel

    var body: some View {
        if jump.shown {
            ZStack(alignment: .top) {
                Color.black.opacity(0.001).onTapGesture { model.closeJump() }
                JumpPanel(jump: jump, model: model).padding(.top, 44).padding(.horizontal, 16)
            }
        }
    }
}

/// The panel (mockup §11): the field, the groups, and what it searches; opaque with a hairline, radius 14 (POLISH
/// §2.4). ↑ and ↓ move the highlight and Return goes there; a click goes to the row clicked; Esc or a click outside
/// closes it. No key caps: the menus name ⌘K.
struct JumpPanel: View {
    @ObservedObject var jump: JumpModel
    let model: AppModel

    var body: some View {
        let groups = jump.groups
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 17, weight: .medium)).foregroundStyle(Ink.secondary)
                JumpQueryField(jump: jump, model: model)
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            Divider()
            if !groups.isEmpty {
                // ↑, ↓ and a new query bring the highlighted row into view, the least that shows it whole
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(groups.enumerated()), id: \.offset) { gi, g in
                                Text(g.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Ink.secondary)
                                    .padding(.horizontal, 10).padding(.top, 8).frame(height: 24, alignment: .bottom)
                                ForEach(Array(g.rows.enumerated()), id: \.offset) { ri, row in
                                    let i = groups[..<gi].reduce(0) { $0 + $1.rows.count } + ri
                                    JumpRowView(row: row, highlighted: i == jump.highlighted)
                                        .id(i)
                                        .onTapGesture { model.jumpTo(row.target) }
                                        .onHover { if $0 { jump.highlighted = i } }
                                        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { jump.frames[i] = $0 }
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.top, 2)
                        .padding(.bottom, 8)
                    }
                    .onChange(of: jump.reveals) { proxy.scrollTo(jump.highlighted) }
                }
                // as tall as its rows, at most 380 pt (a ScrollView takes all the height it is offered)
                .frame(height: min(380, CGFloat(groups.count) * 24 + CGFloat(jump.rows.count) * 36 + 10))
            } else {
                Text("Nothing matches “\(jump.query)”.").font(.system(size: 13)).foregroundStyle(Ink.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).frame(height: 44)
            }
            Divider()
            Text("Comment ids, your words, other edits, sections, rounds and commands")
                .font(.system(size: 11)).foregroundStyle(Ink.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 9)
        }
        .frame(maxWidth: 620)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: Palette.float)))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color(nsColor: Palette.floatLine), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.22), radius: 30, y: 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Jump")
    }
}

/// One row: its sign, the id or number, the words (the query's words Semibold), and the page on the right.
struct JumpRowView: View {
    let row: Jump.Row
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: row.icon).font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.secondary).frame(width: 16)
            if !row.lead.isEmpty {
                Text(Jump.styled(row.lead, row.words, color: Ink.label2))
                    .font(.system(size: 13, weight: .medium).monospacedDigit()).fixedSize()
            }
            (Text(Jump.styled(row.title, row.words, color: Ink.label))
                + Text(row.detail.isEmpty ? "" : "  ")
                + Text(Jump.styled(row.detail, row.words, color: Ink.secondary)))
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if !row.trailing.isEmpty {
                Text(row.trailing).font(.system(size: 11)).foregroundStyle(Ink.secondary).fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 8).fill(highlighted ? Color(nsColor: Palette.accentTint) : .clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// The query field: an AppKit field, so ↑, ↓, Return and Esc reach the panel (the field editor takes them from a
/// SwiftUI TextField). It has the cursor once shown, its text selected.
struct JumpQueryField: NSViewRepresentable {
    @ObservedObject var jump: JumpModel
    let model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator(jump: jump, model: model) }

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField(string: jump.query)
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = .systemFont(ofSize: 17)
        f.textColor = Palette.label
        f.placeholderString = "Jump to a comment, an edit, a section or a round"
        f.lineBreakMode = .byTruncatingTail
        f.cell?.usesSingleLineMode = true
        f.delegate = context.coordinator
        f.setAccessibilityLabel("Jump to")
        DispatchQueue.main.async { [weak f] in
            guard let f, let w = f.window else { return }
            w.makeFirstResponder(f)
            f.currentEditor()?.selectAll(nil)
        }
        return f
    }

    /// The query set from outside the field (a debug script): the field shows it.
    func updateNSView(_ f: NSTextField, context: Context) {
        if f.stringValue != jump.query { f.stringValue = jump.query }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let jump: JumpModel
        let model: AppModel
        init(jump: JumpModel, model: AppModel) { self.jump = jump; self.model = model }

        func controlTextDidChange(_ n: Notification) {
            guard let f = n.object as? NSTextField else { return }
            MainActor.assumeIsolated { jump.setQuery(f.stringValue) }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            MainActor.assumeIsolated {
                switch sel {
                case #selector(NSResponder.moveUp(_:)): jump.move(-1)
                case #selector(NSResponder.moveDown(_:)): jump.move(1)
                case #selector(NSResponder.insertNewline(_:)):
                    let rows = jump.rows
                    if jump.highlighted < rows.count { model.jumpTo(rows[jump.highlighted].target) }
                case #selector(NSResponder.cancelOperation(_:)): model.closeJump()
                default: return false
                }
                return true
            }
        }
    }
}
