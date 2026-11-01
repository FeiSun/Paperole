import AppKit
import SwiftUI

/// What a row of the Changes tab shows (UX.md §16), computed once per applied state, as CardModel is for comments.
struct ChangeModel: Equatable, Identifiable {
    enum Kind: Equatable {
        case edited, added, deleted, moved, figure

        var word: String {
            switch self {
            case .edited: return "edited"
            case .added: return "added"
            case .deleted: return "deleted"
            case .moved: return "moved"
            case .figure: return "figure"
            }
        }

        /// The event of the round that made it, as a thread section's label says it (UX.md §3): "R3 · revised".
        var event: String {
            switch self {
            case .edited: return "revised"
            case .added: return "added"
            case .deleted: return "deleted"
            case .moved: return "moved"
            case .figure: return "new image file"
            }
        }

        var symbol: String {
            switch self {
            case .edited: return "pencil"
            case .added: return "plus"
            case .deleted: return "minus"
            case .moved: return "arrow.up.and.down"
            case .figure: return "photo"
            }
        }
    }

    struct Link: Equatable {
        let id: String
        let status: Status
        var color: MarkColor = .yellow  // the comment's mark colour: a linked change's bar
    }

    let id: String
    var kind: Kind
    var unrequested: Bool
    var checked: Bool
    var read: Bool  // not a move, and every paragraph it touches is marked read (UX.md §18)
    var place: String  // "§ Limitations", or "Table 2" in a table or figure; "not in the PDF"
    var about: String?  // what it is in words (an \input line, formatting), shown on the row and the expanded card
    var page: Int?
    var links: [Link]  // the comments it answers (attached)
    var asked: [Link]  // the comments written this round on it
    /// The comments whose student's note this round attached it ("% R1-03 …" next to it), with the note's words
    /// (CONTRACT amendment "Student notes").
    var notes: [Note] = []

    struct Note: Equatable {
        let id: String
        let text: String  // empty: a bare `% R1-03`
        var place: String? = nil
    }

    /// A student's note the engine did not use, within `IgnoredNote.reach` lines of the edit in its file (the engine's
    /// `note_warnings`): perhaps meant for this edit, so its card says so in one secondary line (BACKLOG O32).
    struct IgnoredNote: Equatable {
        static let reach = 3
        let line: String  // the comment line as the student wrote it, "% R2.08 same claim…"
        let place: String  // "sections/01_introduction.tex:19"
        let message: String  // why the engine did not use it
        let offset: Int  // its line less the edit's: below when positive

        /// "1 line above", "2 lines below", "on its line".
        var whereWords: String {
            offset == 0 ? "on its line" : count(abs(offset), "line") + (offset < 0 ? " above" : " below")
        }

        /// The note nearest the change in its file, within `reach` lines, or nil.
        static func nearest(_ ch: Change, _ warnings: [NoteWarning]) -> IgnoredNote? {
            guard let file = ch.file, let line = ch.line else { return nil }
            let near = warnings.compactMap { w -> (NoteWarning, Int)? in
                guard w.file == file, let l = w.line, abs(l - line) <= reach else { return nil }
                return (w, l - line)
            }
            guard let (w, d) = near.min(by: { (abs($0.1), $0.1) < (abs($1.1), $1.1) }) else { return nil }
            return IgnoredNote(line: (w.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines), place: w.place ?? file,
                               message: w.message, offset: d)
        }
    }

    /// An ignored note near the edit (`IgnoredNote.nearest`), said in one line on its card.
    var ignored: IgnoredNote? = nil
    /// The comments closed in earlier rounds whose sentence this edit changes (the engine's `near_closed`): what the
    /// student may have broken, with Reopen on the card (TAGS.md §9.7, core with the critique's fix).
    var nearClosed: [NearClosed] = []
    var excerpt: AttributedString  // the compact row's second line
    var blocks: [Block]
    var rendered: [String: AttributedString]  // block id → text, and id + ".short"
    var footer: String
    var accessibility: String

    /// `pdfs` maps round numbers to their build PDFs, `textX` is round `n`'s per-page text extent, `statuses` and
    /// `colors` the statuses and mark colours of this round's comments.
    init(_ ch: Change, round n: Int, pdfs: [Int: String], textX: [[Double]?], statuses: [String: Status],
         colors: [String: MarkColor] = [:], read: Bool = false, notes: [String: StudentNote] = [:],
         warnings: [NoteWarning] = []) {
        id = ch.id
        ignored = IgnoredNote.nearest(ch, warnings)
        nearClosed = ch.nearClosed ?? []
        let before = ch.context?.before, now = ch.context?.now
        if ch.figure != nil {
            kind = .figure
        } else {
            switch ch.kind {
            case "insert": kind = .added
            case "delete": kind = .deleted
            case "move": kind = .moved
            default: kind = .edited
            }
        }
        unrequested = ch.unrequested
        checked = ch.checked ?? false
        self.read = read
        page = ch.page
        place = ch.float ?? ch.section.map { "§ " + $0 } ?? (ch.page == nil ? "not in the PDF" : "")
        about = ch.about?.text
        links = ch.attachedTo.map { Link(id: $0, status: statuses[$0] ?? .toCheck, color: colors[$0] ?? .yellow) }
        asked = (ch.commentedBy ?? []).map { Link(id: $0, status: statuses[$0] ?? .new, color: colors[$0] ?? .yellow) }
        self.notes = (ch.studentNotes ?? []).map { id in
            Note(id: id, text: notes[id]?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                 place: notes[id]?.place(for: ch.id))  // the note's line next to this edit
        }
        let same = kind == .edited && Self.sameText(before, now)
        let diff = kind == .edited && !same ? Self.wordDiff(before, now, unmarked: ch.about == nil) : nil  // an
        // insert's or delete's sides are
        // different sentences: its own words (sel) and the point (cut) say it
        blocks = Self.blocks(ch, kind: kind, same: same, round: n, pdfs: pdfs, textX: textX, diff: diff)
        let ink = ch.unrequested ? Palette.unrequested : Palette.changedWords
        var r: [String: AttributedString] = [:]
        for b in blocks where b.kind == .text || b.kind == .source {
            let style: ChangeContent.Style = kind == .moved ? .moved : (b.id == "before" ? .removed : .added)
            r[b.id] = ChangeContent.render(b.full, style: style, ink: ink)
            if let s = b.short { r[b.id + ".short"] = ChangeContent.render(s, style: style, ink: ink) }
        }
        rendered = r
        // a row's changed words: the darker Light green, 4.5:1 on the panel and the column's window (design/review-page §2)
        let rowInk = ch.unrequested ? Palette.unrequested : Palette.rowChangedWords
        excerpt = ch.about.map(Self.excerpt) ?? diff.map { Self.excerpt($0, ink: rowInk) } ?? Self.excerpt(ch, kind: kind, same: same)
        footer = [ch.file.map { $0 + (ch.line.map { ":\($0)" } ?? "") }, ch.kind].compactMap { $0 }.joined(separator: " · ")
        let asking = (ch.commentedBy ?? []).isEmpty ? nil : "you asked in " + (ch.commentedBy ?? []).joined(separator: ", ")
        let noted = self.notes.map { "student’s note on \($0.id)" + ($0.text.isEmpty ? "" : ": " + $0.text) }
        let ignoredWords: String = ignored.map { ". An ignored student note \($0.whereWords): " + $0.line } ?? ""
        let summary: String = [ch.id, kind.word, unrequested ? "unasked edit" : "answers " + ch.attachedTo.joined(separator: ", "),
                               place.isEmpty ? nil : place, ch.page.map { "page \($0 + 1)" }, asking, checked ? "checked" : nil]
            .compactMap { $0 }.joined(separator: ", ")
        accessibility = summary + ". " + String(excerpt.characters) + noted.map { ". " + $0 }.joined() + ignoredWords
    }

    /// An unrequested change needs nothing more once it is checked, a comment of this round asks about it, or (not
    /// a move) its paragraphs are marked read.
    var handled: Bool { checked || !asked.isEmpty || read }

    /// Where two text sides differ, word by word (WordDiff), kept to the runs that touch the change's own words
    /// (`sel`, `cut`) when any does, else all: other edits in the same sentence are other changes, and a `sel` that
    /// took in the wrong words (an author list for a year) is not trusted alone. With no words of its own on either
    /// side (`unmarked` allowed: not a formatting or an \input change), only the runs at both sides' `cut`: words a
    /// macro prints that the source does not have (\answerTODO "[TODO]" → \answerYes "[Yes]").
    struct TextDiff {
        var before: BlockText
        var now: BlockText
        var pieces: [(String, DiffPart)]  // the kept runs with 3 words around them: whitespace before, and the token
        var cutStart = false, cutEnd = false
    }

    static func wordDiff(_ before: AnchorContext?, _ now: AnchorContext?, unmarked: Bool = false) -> TextDiff? {
        guard let b = before, let n = now, !b.isImage, !n.isImage else { return nil }
        // (with no words of its own on either side, the two sides may be different sentences: a formatting edit)
        let bare = b.sel.isEmpty && n.sel.isEmpty
        if bare && !(unmarked && b.cut != nil && n.cut != nil) { return nil }
        let d = WordDiff.hunks(b.text, n.text)
        guard !d.hunks.isEmpty else { return nil }
        func touches(_ r: Range<Int>, _ sel: [[Int]], _ cut: Int?) -> Bool {
            sel.contains { $0.count == 2 && (r.isEmpty ? $0[0] <= r.lowerBound && r.lowerBound <= $0[1]
                                                        : $0[0] < r.upperBound && r.lowerBound < $0[1]) }
                || cut.map { r.lowerBound - 2 <= $0 && $0 <= r.upperBound + 2 } == true
        }
        let own = d.hunks.filter { bare ? touches($0.old, [], b.cut) && touches($0.new, [], n.cut)
                                         : touches($0.old, b.sel, b.cut) || touches($0.new, n.sel, n.cut) }
        if bare && own.isEmpty { return nil }
        let kept = own.isEmpty ? d.hunks : own
        let before = BlockText(text: b.text, marks: kept.map(\.old).filter { !$0.isEmpty },
                               carets: kept.filter { $0.old.isEmpty }.map(\.old.lowerBound))
        let now = BlockText(text: n.text, marks: kept.map(\.new).filter { !$0.isEmpty },
                            carets: kept.filter { $0.new.isEmpty }.map(\.new.lowerBound))
        // the excerpt: from 3 unchanged words before the first kept run to 3 after the last
        let inRun = Set(kept.flatMap { Array($0.steps) })
        let first = kept[0].steps.lowerBound, last = kept[kept.count - 1].steps.upperBound
        var lo = first, hi = last, same = 0
        while lo > 0 && same < 3 { lo -= 1; if !inRun.contains(lo) { same += 1 } }
        same = 0
        while hi < d.steps.count && same < 3 { if !inRun.contains(hi) { same += 1 }; hi += 1 }
        let os = Array(b.text.unicodeScalars), ns = Array(n.text.unicodeScalars)
        func piece(_ s: [Unicode.Scalar], _ r: Range<Int>) -> (String, String) {  // a space when the source has one
            (r.lowerBound > 0 && s[r.lowerBound - 1].properties.isWhitespace ? " " : "",
             String(String.UnicodeScalarView(s[r])))
        }
        var pieces: [(String, DiffPart)] = []
        for k in lo..<hi {
            switch d.steps[k] {
            case let (_?, j?):
                let (g, t) = piece(ns, d.b[j].range)
                pieces.append((g, .same(t)))
            case let (i?, nil):
                let (g, t) = piece(os, d.a[i].range)
                pieces.append((g, .deleted(t)))
            case let (nil, j?):
                let (g, t) = piece(ns, d.b[j].range)
                pieces.append((g, .inserted(t)))
            default: break
            }
        }
        if let f = pieces.first { pieces[0] = ("", f.1) }
        return TextDiff(before: before, now: now, pieces: pieces, cutStart: lo > 0, cutEnd: hi < d.steps.count)
    }

    /// The compact row's line for a change the engine says in words (an \input line; formatting, in secondary).
    static func excerpt(_ about: ChangeAbout) -> AttributedString {
        var a = AttributedString(about.text)
        if about.kind == "formatting" { a.foregroundColor = Ink.secondary }
        return a
    }

    /// The compact row's line from a word diff: the old words struck through in grey, the new ones underlined in
    /// `ink` (slate teal for an edit no comment asked for, green for one that answers a comment).
    static func excerpt(_ d: TextDiff, ink: NSColor = Palette.changedWords) -> AttributedString {
        var out = AttributedString(d.cutStart ? "… " : "")
        for (gap, part) in d.pieces {
            out += AttributedString(gap)
            switch part {
            case .same(let t): out += AttributedString(t)
            case .deleted(let t): out += ChangeContent.struck(t)
            case .inserted(let t):
                var a = AttributedString(t)
                a.underlineStyle = Text.LineStyle(pattern: .solid, color: Color(nsColor: ink))
                out += a
            }
        }
        return out + AttributedString(d.cutEnd ? " …" : "")
    }

    /// Both sides print the same words (a formatting or source-only edit).
    private static func sameText(_ a: AnchorContext?, _ b: AnchorContext?) -> Bool {
        guard let a, let b, !a.isImage, !b.isImage, !a.text.isEmpty else { return false }
        return CardContent.collapsed(a.text) == CardContent.collapsed(b.text)
    }

    /// The change as a thread (UX.md §16, §3): "R1 · before" and "R2 · revised" ("added", "deleted", "moved", "new
    /// image file"), the page named only when it is not the change's; one section when a move or an edit reads the
    /// same.
    static func blocks(_ ch: Change, kind: Kind, same: Bool, round n: Int, pdfs: [Int: String],
                       textX: [[Double]?], diff: TextDiff? = nil) -> [Block] {
        let before = ch.context?.before, now = ch.context?.now
        func page(_ p: Int?) -> String { p.flatMap { $0 != ch.page ? " · p.\($0 + 1)" : nil } ?? "" }
        func block(_ id: String, _ label: String, _ revised: Bool, _ round: Int, _ ctx: AnchorContext,
                   point: Bool) -> Block {
            if ctx.isImage {
                let crop = ctx.page.map { p in
                    CropRequest(round: round, pdf: pdfs[round], page: p, rects: ctx.rects,
                                textX: round == n && p < textX.count ? textX[p] : nil, clip: ctx.clip, deletion: point,
                                look: CropLook.change(ch))
                }
                return Block(id: id, label: label, revised: revised, kind: .image, full: BlockText(text: ctx.text),
                             crop: crop)
            }
            let t = (id == "before" ? diff?.before : diff?.now) ?? BlockText(context: ctx, carets: true)
            return Block(id: id, label: label, revised: revised, kind: .text, full: t, short: CardContent.trim(t))
        }
        if let b = before, let c = now, kind == .moved || same, !b.isImage, !c.isImage,
           CardContent.collapsed(b.text) == CardContent.collapsed(c.text) {
            let from = b.page != c.page ? b.page.map { " from p.\($0 + 1)" } ?? "" : ""
            let label = kind == .moved ? "R\(n) · moved" + from : "R\(n) · same words in the PDF" + from
            let t = BlockText(text: c.text)
            return [Block(id: "merged", label: label, revised: false, kind: .text, full: t, short: CardContent.trim(t))]
        }
        var out: [Block] = []
        let said = ch.about != nil  // the card says what it is in words: no LaTeX source in its place
        if let b = before {
            out.append(block("before", "R\(n - 1) · before" + page(b.page), false, n - 1, b, point: kind == .added))
        } else if kind != .added, !ch.oldText.isEmpty, !said {
            let t = BlockText(text: ch.oldText)
            out.append(Block(id: "before", label: "R\(n - 1) · before, in the source", revised: false, kind: .source,
                             full: t, short: CardContent.trim(t)))
        }
        if let c = now {
            out.append(block("now", "R\(n) · " + kind.event + page(c.page), kind != .moved, n, c, point: kind == .deleted))
        } else if said {
        } else if kind == .deleted {
            out.append(Block(id: "now", label: "R\(n) · deleted", revised: true, kind: .plain,
                             full: BlockText(text: "Nothing is printed near it.")))
        } else if !ch.newText.isEmpty {
            let t = BlockText(text: ch.newText)
            out.append(Block(id: "now", label: "R\(n) · \(kind.event), in the source", revised: true, kind: .source,
                             full: t, short: CardContent.trim(t)))
        }
        return out
    }

    /// The compact row's second line: readable words from the PDFs (UX.md §16), the old ones struck through.
    static func excerpt(_ ch: Change, kind: Kind, same: Bool) -> AttributedString {
        func words(_ ctx: AnchorContext?) -> String? {
            guard let ctx else { return nil }
            if ctx.isImage { return ctx.text.isEmpty ? nil : CardContent.collapsed(ctx.text) }
            let s = Array(ctx.text.unicodeScalars)
            let parts = ctx.sel.compactMap { r -> String? in
                guard r.count == 2, r[0] >= 0, r[0] < r[1], r[1] <= s.count else { return nil }
                return String(String.UnicodeScalarView(s[r[0]..<r[1]]))
            }
            return parts.isEmpty ? nil : parts.joined(separator: " … ")
        }
        func short(_ s: String) -> String { s.count > 160 ? String(s.prefix(160)) + "…" : s }
        func old(_ s: String) -> AttributedString { ChangeContent.struck(short(s)) }
        func plain(_ s: String) -> AttributedString { AttributedString(short(s)) }
        let b = words(ch.context?.before), n = words(ch.context?.now)
        switch kind {
        case .figure:
            return plain("New image file: " + (ch.figure ?? ""))
        case .added:
            return plain(n ?? ch.newText)
        case .deleted:
            return old(b ?? ch.oldText)
        case .moved:
            return plain(n ?? b ?? ch.newText)
        case .edited:
            if same || (b == nil && n == nil && ch.context?.before != nil && ch.context?.now != nil) {
                var a = AttributedString("Same words in the PDF (formatting)")
                a.foregroundColor = Ink.secondary
                return a
            }
            let o = b ?? (n == nil ? ch.oldText : nil), w = n ?? (b == nil ? ch.newText : nil)
            var arrow = AttributedString(" → ")
            arrow.foregroundColor = Ink.secondary
            return (o.map(old) ?? AttributedString()) + (o != nil && w != nil ? arrow : AttributedString())
                + (w.map(plain) ?? AttributedString())
        }
    }
}

enum ChangeContent {
    enum Style { case removed, added, moved }

    /// Words a change took out: struck through in grey, as history is (design/ui-v2/PROPOSAL.md §3).
    static func struck(_ s: String) -> AttributedString {
        var a = AttributedString(s)
        a.strikethroughStyle = Text.LineStyle(pattern: .solid, color: Ink.secondary)
        a.foregroundColor = Ink.secondary
        return a
    }

    /// A change section's text, in the thread's style (UX.md §3, §16): the paper's words quieter; the change's own
    /// words struck through in grey before it (`removed`), underlined in `ink` after it (`added`: slate teal for an edit
    /// no comment asked for, green for one that answers a comment) with a small triangle where words were removed, or
    /// on a faint fill (`moved`).
    static func render(_ t: BlockText, style: Style, ink: NSColor = Palette.changedWords) -> AttributedString {
        let s = Array(t.text.unicodeScalars)
        let carets = style == .added ? Set(t.carets) : []  // before the change, a point inserted at is not drawn
        var bounds = Set([0, s.count])
        for r in t.marks { bounds.insert(r.lowerBound); bounds.insert(r.upperBound) }
        bounds.formUnion(carets)
        let cuts = bounds.filter { $0 >= 0 && $0 <= s.count }.sorted()
        let colour = Color(nsColor: ink)
        let quiet = Color(nsColor: Palette.paperText), label = Ink.label
        var out = AttributedString()
        for (i, a) in cuts.enumerated() {
            if carets.contains(a) { out += CardContent.caret(colour) }  // as on a card
            guard i + 1 < cuts.count else { break }
            let b = cuts[i + 1]
            guard a < b else { continue }
            let text = String(String.UnicodeScalarView(s[a..<b]))
            guard t.marks.contains(where: { $0.lowerBound <= a && b <= $0.upperBound }) else {
                var piece = AttributedString(text)
                piece.foregroundColor = quiet
                out += piece
                continue
            }
            switch style {
            case .removed:
                out += struck(text)
            case .added:
                var piece = AttributedString(text)
                piece.underlineStyle = Text.LineStyle(pattern: .solid, color: colour)
                piece.foregroundColor = label
                out += piece
            case .moved:
                var piece = AttributedString(text)
                piece.backgroundColor = Color(nsColor: Palette.chipFill)
                piece.foregroundColor = label
                out += piece
            }
        }
        return out
    }
}
