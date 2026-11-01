import AppKit
import SwiftUI

/// The text of a card block with its spans, in Unicode scalar offsets of `text`.
struct BlockText: Equatable {
    var text: String
    var marks: [Range<Int>] = []  // the anchor (a thread section's tint; a change's own words)
    var changed: [Range<Int>] = []  // words that differ from the section above (green underline)
    var carets: [Int] = []  // where words were deleted, or the deletion point of a gone comment (green ‸)
}

extension BlockText {
    /// A context's text, its own words (`sel`) marked, and, with `carets`, its deletion point (`cut`), both kept inside
    /// the text: a card's section and a change's block alike.
    init(context ctx: AnchorContext, carets: Bool) {
        let count = CardContent.scalarCount(ctx.text)
        let marks = ctx.sel.compactMap { s -> Range<Int>? in
            guard s.count == 2 else { return nil }
            let a = min(max(s[0], 0), count), b = min(max(s[1], a), count)
            return a < b ? a..<b : nil
        }
        self.init(text: ctx.text, marks: marks, carets: carets ? ctx.cut.map { [min(max($0, 0), count)] } ?? [] : [])
    }
}

/// One block of a change on the Changes tab (UX.md §16).
struct Block: Equatable, Identifiable {
    enum Kind: Equatable {
        case text  // readable PDF text, serif
        case source  // fallback: the LaTeX quote, monospace
        case image  // a crop of a round's build PDF
        case plain  // secondary: nothing printed near a deletion
    }

    var id: String
    var label: String  // "R1 · before", "R2 · revised", as a thread section's (UX.md §3)
    var revised: Bool  // the student's side: a filled dot on the rail
    var kind: Kind
    var full: BlockText
    var short: BlockText? = nil  // when the text is longer than the window; "Show all" switches to full
    var crop: CropRequest? = nil
}

/// A crop of round `round`'s build PDF around `rects` on `page` (contract coordinates): the engine's `clip` when the
/// context has one, else the rects' union + 6 pt widened to the text.
struct CropRequest: Equatable, Hashable {
    var round: Int
    var pdf: String?
    var page: Int
    var rects: [[Double]]
    var textX: [Double]?
    var clip: [Double]? = nil
    var deletion = false  // the rects are a deletion point: drawn as a line across the crop with a caret
    var faint = false  // the box drawn faintly: a thread's later sections (UX.md §3)
    var look: CropLook = .paper  // a figure as printed, or a formula's or table's ink on the card (UX.md §4)
}

/// One section of a card's thread (UX.md §3): the text a round printed (or its crop), and the later rounds that changed
/// nothing as tags. What was said in its rounds is in the card's turns (`CardContent.turns`).
struct ThreadSection: Equatable, Identifiable {
    enum Kind: Equatable {
        case text  // readable PDF text, serif
        case source  // fallback: the LaTeX quote, monospace
        case image  // a crop of the round's build PDF
        case plain  // a line in words: nothing printed near a deletion
        case none  // no text: not found
    }

    var round: Int
    var rounds: [Int]  // the rounds it holds: its own, then those merged into it as tags
    var event: String  // "as commented", "revised", "deleted", "restored", "new image file", "no text found", …
    var page: Int?  // in the label when it differs from the card's
    var revised = false  // the student changed the text in this round: a filled dot on the rail
    /// A "moved" section whose words did not change: the student only moved the text (each of the shown round's
    /// attached changes a move or reading the same; in an earlier round, whose changes the state names but does not
    /// hold, no word differs from the text above). The card says "moved it", not "moved and revised it".
    var onlyMoved = false
    var gone = false  // the text around a deletion: never underlined, and the next section compares with the one above
    var tags: [String] = []  // "unchanged in R2 and R3", "moved to p.6 in R2", "moved to p.5"
    var edits: [String] = []  // the shown round's attached changes: "· 1 edit"
    var uncertain = false  // the shown round's place is a guess: "position uncertain"
    var kind: Kind
    var full: BlockText
    var short: BlockText? = nil  // when the text is longer than the window; "Show all" switches to full
    var strong = false  // the mark at full strength: the first section
    var crop: CropRequest? = nil

    var id: String { "r\(round)" }
}

enum CardContent {
    static let window = 480, side = 160, longSpan = 400

    /// One round of a comment as the thread reads it: an earlier round (history) or the shown one.
    private struct Record {
        var round: Int
        var state: String
        var page: Int?
        var context: AnchorContext?
        var changes: [String]
        var figures: [String]?  // those of `changes` that replaced a picture file (an earlier round's; nil: not known)
        var student: StudentNote?

        /// The attached changes but those only the student's note linked, outside the commented text (`elsewhere`):
        /// they do not revise its section, nor are their words marked in it (they are on the note's label).
        var own: [String] {
            let apart = Set(student?.elsewhere ?? [])
            return changes.filter { !apart.contains($0) }
        }
    }

    /// The sections of a card for round `n` (UX.md §3): one per round in which the student changed the text, by the
    /// engine's signals (the round's anchor state and attached changes), never by comparing the printed text; the
    /// others are tags on the section above. Each section's changed words are against the last section above it that
    /// shows text, not a deletion. `pdfs` maps rounds to their build PDFs, `textX` is the shown round's text extent per
    /// page, `figures` maps the shown round's changes that replaced a picture file to its name, `edits` its changes to
    /// their sentences as the round prints them (their own words marked).
    static func thread(_ c: Comment, round n: Int, pdfs: [Int: String] = [:], textX: [[Double]?] = [],
                       figures: [String: String] = [:], edits: [String: AnchorContext] = [:]) -> [ThreadSection] {
        let records = c.history.map {
            Record(round: $0.round, state: $0.anchorState, page: $0.context?.page ?? $0.page, context: $0.context,
                   changes: $0.changes ?? [], figures: $0.figures, student: $0.studentNote)
        } + [Record(round: n, state: c.anchorState, page: c.context?.page ?? c.page, context: c.context, changes: c.changes,
                    figures: c.changes.filter { figures[$0] != nil }, student: c.studentNote)]

        let look = CropLook.comment(env: c.env, kind: c.markKind, words: c.text)
        func crop(_ r: Record, _ rects: [[Double]], _ clip: [Double]?, faint: Bool) -> CropRequest? {
            guard let page = r.page, !rects.isEmpty else { return nil }
            return CropRequest(round: r.round, pdf: pdfs[r.round], page: page, rects: rects,
                               textX: page < textX.count ? textX[page] : nil, clip: clip, deletion: r.state == "gone",
                               faint: faint, look: look)
        }
        /// A note placed where the page prints nothing (a blank page): its area of the page.
        func emptyArea(_ r: Record) -> CropRequest? {
            guard let ctx = r.context, ctx.text.isEmpty, let p = ctx.rects.first, p.count == 4, p[0] == p[2],
                  p[1] == p[3] else { return nil }
            var req = crop(r, ctx.rects, [max(p[0] - 110, 0), max(p[1] - 60, 0), p[0] + 110, p[1] + 60], faint: false)
            req?.deletion = false
            req?.look = .paper  // an area of the page, as printed
            return req
        }
        func content(_ r: Record, first: Bool) -> (ThreadSection.Kind, BlockText, CropRequest?) {
            let now = r.round == n
            if r.state == "orphan" { return (.none, BlockText(text: ""), nil) }
            if let req = emptyArea(r) { return (.image, BlockText(text: ""), req) }
            if c.markKind == .box || r.context?.isImage == true {
                return (.image, BlockText(text: r.context?.text ?? ""),
                        crop(r, r.context?.rects ?? (now ? c.rects : []), r.context?.clip, faint: !first))
            }
            if let ctx = r.context, !ctx.text.isEmpty {
                return (.text, BlockText(context: ctx, carets: r.state == "gone"), nil)
            }
            if r.state == "gone" { return (.plain, BlockText(text: "Nothing is printed near the cut."), nil) }
            if now, let p = c.text, !p.isEmpty { return (.text, BlockText(text: p, marks: [0..<scalarCount(p)]), nil) }
            // the LaTeX quote: this round's, or the creation round's when no round came since
            if now, let q = c.newQuote, !q.isEmpty { return (.source, BlockText(text: q), nil) }
            if first, c.history.count == 1, let q = c.oldQuote, !q.isEmpty { return (.source, BlockText(text: q), nil) }
            return (.none, BlockText(text: ""), nil)
        }

        var out: [ThreadSection] = []
        var tags: [[(text: String, round: Int?)]] = []  // per section, joined into words at the end
        var sectionPage: Int?  // the page the last section's text was last seen on
        for (i, r) in records.enumerated() {
            if i == 0 {
                let (kind, full, req) = content(r, first: true)
                var event = c.carried ? "as commented" : c.markKind == .box || kind == .image ? "selected area"
                    : c.method == "line" && full.marks.isEmpty && c.markKind == .note ? "note placed near this text"
                    : "selected text"
                if emptyArea(r) != nil { event = "note on an empty area" }
                out.append(ThreadSection(round: r.round, rounds: [r.round], event: event, page: r.page, kind: kind,
                                         full: full, short: trim(full), strong: true, crop: req))
                tags.append([])
                sectionPage = r.page
                continue
            }
            let prev = records[i - 1]
            var event: String?  // nil: a tag on the section above
            var tag: (text: String, round: Int?)?
            if r.state == "orphan" {
                if prev.state != "orphan" { event = "no text found" } else { tag = ("still not found in", r.round) }
            } else if r.state == "gone" {
                if prev.state != "gone" {
                    event = "deleted"
                } else if !r.own.isEmpty {
                    event = "revised near the cut"
                } else {
                    tag = ("still deleted in", r.round)
                }
            } else if prev.state == "gone" {
                event = r.state == "moved" ? "restored" : "revised near the cut"  // typed in again (anchor._restored)
            } else if prev.state == "orphan" {
                event = r.state == "changed" ? "revised" : "found again"
            } else if r.state == "changed" || !r.own.isEmpty {
                // a picture file replaced under its name, with the change attached (an engine that does not name an
                // earlier round's: its anchor was left unchanged)
                let figure = r.figures.map { !Set($0).isDisjoint(with: r.own) } ?? (r.state != "changed")
                event = (c.markKind == .box || r.context?.isImage == true) && figure ? "new image file"
                    : r.state == "moved" ? "moved" : "revised"  // the words moved, with the edits around them
            } else if r.state == "moved" {
                tag = (r.page != nil && r.page != sectionPage ? "moved to p.\(r.page! + 1) in" : "moved in", r.round)
            } else {
                tag = ("unchanged in", r.round)
            }
            if let event {
                let (kind, full, req) = content(r, first: false)
                var s = ThreadSection(round: r.round, rounds: [r.round], event: event, page: r.page,
                                      revised: !["no text found", "found again", "moved"].contains(event),
                                      gone: r.state == "gone", kind: kind, full: full, crop: req)
                var own: [(text: String, round: Int?)] = []
                if r.state == "moved" && event != "restored" && event != "moved", let p = r.page {
                    own.append((p != sectionPage ? "moved to p.\(p + 1)" : "moved", nil))
                }
                if kind == .text, !s.gone, let base = out.last(where: { $0.kind == .text && !$0.gone }) {
                    let d = WordDiff.changes(from: base.full.text, to: full.text,
                                             oldFocus: base.full.marks.isEmpty ? nil : base.full.marks,
                                             newFocus: full.marks.isEmpty ? nil : full.marks)
                    s.full.changed = d.changed
                    s.full.carets = d.carets
                }
                if kind == .text, !s.gone, r.round == n {
                    // the shown round's attached edits are its changes wherever they are, also a sentence added
                    // before or after the commented one, which the comparison above leaves to the shown extent
                    let own = r.own.compactMap { edits[$0] }.filter { !$0.isImage }.flatMap { e in
                        WordDiff.carried(e.sel.compactMap { $0.count == 2 && $0[0] < $0[1] ? $0[0]..<$0[1] : nil },
                                         from: e.text, to: full.text)
                    }
                    s.full.changed = merged(s.full.changed + own)
                }
                if event == "moved" {
                    s.onlyMoved = (r.round != n || r.own.allSatisfy { edits[$0] == nil })
                        && s.full.changed.isEmpty && s.full.carets.isEmpty
                }
                s.short = trim(s.full)
                if r.round == n { s.edits = r.own }
                out.append(s)
                tags.append(own)
            } else if let tag {
                out[out.count - 1].rounds.append(r.round)
                tags[tags.count - 1].append(tag)
            }
            if r.page != nil { sectionPage = r.page }
        }
        for k in out.indices { out[k].tags = joined(tags[k]) }
        out[out.count - 1].uncertain = c.anchorState != "orphan" && (c.lowConfidence || c.page == nil)
        return out
    }

    /// The shown round's changes as `thread` marks them (`edits`): each change's sentences as the round prints them,
    /// its own words marked. Not a move, nor a change whose words read the same before and after: its words did not
    /// change, so marking them would say the student rewrote what was only moved.
    static func edits(_ changes: [Change]) -> [String: AnchorContext] {
        Dictionary(changes.compactMap { ch in
            ch.kind == "move" || collapsed(ch.oldText) == collapsed(ch.newText) ? nil : ch.context?.now.map { (ch.id, $0) }
        }, uniquingKeysWith: { a, _ in a })
    }

    /// Ranges sorted, with those that overlap or touch made one.
    private static func merged(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        for r in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, r.lowerBound <= last.upperBound {
                out[out.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else {
                out.append(r)
            }
        }
        return out
    }

    /// Tags of rounds in a row that read the same, in words: "unchanged in R2 and R3".
    private static func joined(_ tags: [(text: String, round: Int?)]) -> [String] {
        var out: [(text: String, rounds: [Int])] = []
        for t in tags {
            if let r = t.round, let last = out.last, last.text == t.text, !last.rounds.isEmpty {
                out[out.count - 1].rounds.append(r)
            } else {
                out.append((t.text, t.round.map { [$0] } ?? []))
            }
        }
        return out.map { t in
            guard !t.rounds.isEmpty else { return t.text }
            let names = t.rounds.map { "R\($0)" }
            return t.text + " " + (names.count == 1 ? names[0]
                                   : names.dropLast().joined(separator: ", ") + " and " + names.last!)
        }
    }

    static func scalarCount(_ s: String) -> Int { s.unicodeScalars.count }

    static func collapsed(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    // MARK: Trimming

    /// The text cut to the window around the marks (or the deletion point), or nil when it fits (UX.md §3 Length).
    /// Up to `window` characters show whole. Otherwise the focus with `side` characters each side, snapped out to
    /// word boundaries, with … at each cut. A focus longer than `longSpan` shows its first 240 and last 160
    /// characters joined by " … ". With no mark and no deletion point (a note's text), the focus runs from the start
    /// to the last changed word, so an underline never hides behind Show all.
    static func trim(_ t: BlockText, window: Int = CardContent.window, side: Int = CardContent.side) -> BlockText? {
        let s = Array(t.text.unicodeScalars)
        guard s.count > window else { return nil }
        var points = t.marks.flatMap { [$0.lowerBound, $0.upperBound] } + t.carets
        if points.isEmpty && !t.changed.isEmpty { points = [0] + t.changed.flatMap { [$0.lowerBound, $0.upperBound] } }
        let a = points.min() ?? 0, b = points.max() ?? 0
        func isSpace(_ i: Int) -> Bool { CharacterSet.whitespacesAndNewlines.contains(s[i]) }
        func snapLeft(_ i: Int) -> Int {
            var i = max(i, 0)
            while i > 0 && !isSpace(i - 1) { i -= 1 }
            return i
        }
        func snapRight(_ i: Int) -> Int {
            var i = min(i, s.count)
            while i < s.count && !isSpace(i) { i += 1 }
            return i
        }
        var pieces: [Range<Int>]
        if b - a > longSpan {
            pieces = [a..<snapRight(a + 240), snapLeft(b - 160)..<b]
        } else if points.isEmpty {
            pieces = [0..<snapRight(window)]
        } else {
            pieces = [snapLeft(a - side)..<snapRight(b + side)]
        }
        // A cut never falls inside a changed (underlined) run: the piece takes the whole run, out to the word around it
        // (BACKLOG O32: "varying the retrieval … B.3)" cut a rewritten clause in two, so the edit read as two).
        pieces = pieces.map { r in
            var lo = r.lowerBound, hi = r.upperBound
            for _ in 0..<4 {
                let (l0, h0) = (lo, hi)
                for c in t.changed {
                    if c.lowerBound < lo && lo < c.upperBound { lo = snapLeft(c.lowerBound) }
                    if c.lowerBound < hi && hi < c.upperBound { hi = snapRight(c.upperBound) }
                }
                if (lo, hi) == (l0, h0) { break }
            }
            return lo..<hi
        }
        if pieces.count == 2, pieces[0].upperBound >= pieces[1].lowerBound {  // the two met: one piece
            pieces = [pieces[0].lowerBound..<max(pieces[0].upperBound, pieces[1].upperBound)]
        }
        pieces = pieces.map { r in
            // drop the whitespace at the cut
            var lo = r.lowerBound, hi = r.upperBound
            while lo < hi && isSpace(lo) { lo += 1 }
            while hi > lo && isSpace(hi - 1) { hi -= 1 }
            return lo..<hi
        }
        var text = "", marks: [Range<Int>] = [], changed: [Range<Int>] = [], carets: [Int] = []
        var len = 0
        func append(_ str: String) {
            text += str
            len += str.unicodeScalars.count
        }
        for (k, r) in pieces.enumerated() {
            if k == 0 && r.lowerBound > 0 { append("… ") }
            if k > 0 { append(" … ") }
            let shift = len - r.lowerBound
            append(String(String.UnicodeScalarView(s[r])))
            func clip(_ x: Range<Int>) -> Range<Int>? {
                let lo = max(x.lowerBound, r.lowerBound), hi = min(x.upperBound, r.upperBound)
                return lo < hi ? (lo + shift)..<(hi + shift) : nil
            }
            marks += t.marks.compactMap(clip)
            changed += t.changed.compactMap(clip)
            carets += t.carets.filter { $0 >= r.lowerBound && $0 <= r.upperBound }.map { $0 + shift }
        }
        if let last = pieces.last, last.upperBound < s.count { append(" …") }
        return BlockText(text: text, marks: marks, changed: changed, carets: carets)
    }


    // MARK: Rendering

    /// Where words were removed: a small triangle between the words, its tip at the baseline, in `colour` (UX.md §3);
    /// the Changes tab's blocks draw the same one (§16).
    static func caret(_ colour: Color) -> AttributedString {
        var c = AttributedString("\u{2009}▲\u{2009}")
        c.foregroundColor = colour
        c.font = .system(size: 9)
        c.baselineOffset = -2.5
        return c
    }

    /// A section's text as an AttributedString (UX.md §3): the paper's words in a quieter colour, the marked words as a
    /// tint of the mark's colour whatever its kind (strong in the first section, faint later), so an underline always
    /// means an edit; changed words underlined in green and carets where words were removed, both only when
    /// `showChanges`.
    static func render(_ t: BlockText, color: MarkColor, strong: Bool, showChanges: Bool) -> AttributedString {
        let s = Array(t.text.unicodeScalars)
        var bounds = Set([0, s.count])
        for r in t.marks + (showChanges ? t.changed : []) { bounds.insert(r.lowerBound); bounds.insert(r.upperBound) }
        let carets = showChanges ? Set(t.carets) : []
        bounds.formUnion(carets)
        let cuts = bounds.filter { $0 >= 0 && $0 <= s.count }.sorted()
        let green = Color(nsColor: Palette.changedWords)
        let tint = Color(nsColor: color.tint(strong: strong))
        let quiet = Color(nsColor: Palette.paperText), label = Ink.label
        var out = AttributedString()
        for (i, a) in cuts.enumerated() {
            if carets.contains(a) { out += caret(green) }
            guard i + 1 < cuts.count else { break }
            let b = cuts[i + 1]
            guard a < b else { continue }
            var piece = AttributedString(String(String.UnicodeScalarView(s[a..<b])))
            let marked = t.marks.contains { $0.lowerBound <= a && b <= $0.upperBound }
            let isChanged = showChanges && t.changed.contains { $0.lowerBound <= a && b <= $0.upperBound }
            piece.foregroundColor = marked || isChanged ? label : quiet
            if marked { piece.backgroundColor = tint }
            if isChanged { piece.underlineStyle = Text.LineStyle(pattern: .solid, color: green) }
            out += piece
        }
        return out
    }
}

/// A note as its card's title (POLISH §2.3, §6 decision 6): the first sentence 15/20, Semibold, or Medium in Chinese or
/// Japanese, and the rest 13/19 Regular under it; when the first sentence is longer than about 80 Latin characters (40
/// CJK ones, which count twice) the whole note is one 14 pt Medium block, so a long note never becomes a big bold one.
struct NoteTitle: Equatable {
    enum Style: Equatable { case sentence, long }
    var first: String
    var rest: String
    var cjk: Bool
    var style: Style

    init(_ note: String) {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let chars = Array(text)
        let end = Self.sentenceEnd(chars, from: 0)  // the first sentence is chars[..<end]
        let firstText = String(chars[..<end]).trimmingCharacters(in: .whitespaces)
        cjk = firstText.contains(where: Self.isCJK)
        let weight = firstText.reduce(0) { $0 + (Self.isCJK($1) ? 2 : 1) }
        if weight > 80 {
            style = .long
            first = text
            rest = ""
        } else {
            style = .sentence
            first = firstText
            rest = String(chars[end...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Where the sentence that starts at `start` ends (exclusive): at 。！？, or at . ! ? before a space and a capital or a
    /// CJK character (not at "Fig. 1", "e.g. the"), closing quotes kept with it; or before a line break; or at the end.
    /// The title's first sentence, and an earlier round's bubble cut to whole sentences (`CardContent.clamped`).
    static func sentenceEnd(_ chars: [Character], from start: Int) -> Int {
        var i = start
        while i < chars.count {
            let c = chars[i]
            if c.isNewline { return i }
            if "。！？".contains(c) || ".!?".contains(c) {
                var j = i + 1
                while j < chars.count, "”’\"'）」』)".contains(chars[j]) { j += 1 }  // closing quotes stay with it
                if "。！？".contains(c) { return j }
                // a Latin sentence ends before a space and a capital or a CJK character: not at "Fig. 1", "e.g. the"
                if j < chars.count, chars[j].isWhitespace {
                    var k = j
                    while k < chars.count, chars[k].isWhitespace, !chars[k].isNewline { k += 1 }
                    if k == chars.count || chars[k].isNewline || chars[k].isUppercase || isCJK(chars[k]) { return j }
                }
            }
            i += 1
        }
        return chars.count
    }

    /// Chinese, Japanese or Korean script, or their punctuation.
    static func isCJK(_ c: Character) -> Bool {
        c.unicodeScalars.contains { s in
            let v = s.value
            return (0x3000...0x30FF).contains(v) || (0x3400...0x4DBF).contains(v) || (0x4E00...0x9FFF).contains(v)
                || (0xAC00...0xD7AF).contains(v) || (0xFF00...0xFFEF).contains(v)
        }
    }
}

/// The ⓘ of a card: what was on its footer (UX.md §2).
struct CardInfo: Equatable {
    var location: String?  // file:line of the shown round's anchor
    var method: String
    var changes: [String]  // attached in the shown round
    var newImages: [String]  // picture files those changes replaced
}

/// What a card shows, computed once per applied state (UX.md §10.3). Card views take only this and whether they are
/// expanded, so a state update or a selection change redraws only the cards whose model changed.
/// A tag on a card: its id, name and sign from the catalogue, and its help tag.
struct CardTag: Equatable {
    var id: String
    var name: String
    var sign: String?
    var help: String
}

/// A card's suggested tag: a dashed chip with why it is suggested.
struct CardSuggestion: Equatable {
    var id: String
    var name: String
    var sign: String?
    var reason: String
    var help: String
}

struct CardModel: Equatable, Identifiable {
    enum Tone: Equatable { case plain, attention, danger }

    let id: String
    var carried: Bool
    var status: Status
    /// The row's word: in To check the shown round's event, "revised" (also moved with edits), "moved" (only moved),
    /// "unchanged", "deleted", "revised in R2", "edit on p.6" (only an edit the student's note linked elsewhere),
    /// "position uncertain", "not found · re-anchor"; in For the student the status, "follow-up" or "new". It says what
    /// happened to the paper (design/ui-v2.2 CARD.md §3.4).
    var stateWord: String?
    var stateTone = Tone.plain
    var color: MarkColor
    var kind: MarkKind
    var page: Int?
    var note: String
    var title: NoteTitle
    var firstLine: String
    var quote: String?  // a compact row with an empty note shows the quote
    var thread: [ThreadSection]
    /// The thread read as a conversation (UX.md §3; design/ui-v2.2 CARD.md option C), what the card shows.
    var turns: [Turn]
    var fold: TurnFold?
    var labels: [String: AttributedString]  // turn id → its label; "fold" → the fold's line
    /// The shown round's edits its student's note alone linked outside the commented text (`elsewhere`), as the Changes
    /// tab has them: the card shows them under the note (CARD §3.7).
    var attachments: [ChangeModel] = []
    var rendered: [String: AttributedString]  // section id → text, and id + ".short"; id + ".fold": the first section's while folded
    var info: CardInfo
    var verdict: String?
    var verdictNote: String
    var accessibility: String
    /// The student wrote a note on it in the shown round (a `% R1-03 …` line): a sign on its row (UX.md §2).
    var studentNote: String?
    /// The card's follow-up field holds text not sent yet (UX.md §8); set by AppModel from the drafts, not the state.
    var unsent = false
    /// The shown round is open. In a closed one nothing is the advisor's move: To check and position uncertain are not
    /// vermilion (UX.md §2).
    var open: Bool
    /// The advisor's writing tags on it, named and signed from the catalogue (UX.md §24), and, while it has none, the
    /// first suggestion (a dashed chip, taken with one click).
    var tags: [CardTag] = []
    /// Listed by tag under this tag's header (UX.md §27): its row leaves out that tag's sign, which the header shows.
    var listedUnder: String?
    /// Listed by status under the To check header: its row leaves out the ○ the header shows (design/review-page
    /// BRIEF.md E7).
    var underToCheck = false
    var suggestion: CardSuggestion?
    /// A comment closed in the shown earlier round that can be reopened into the open round N (TAGS.md §9.2), and one
    /// reopened into the shown round from round k (its row's word, Undo Reopen).
    var reopenIn: Int?
    var revivedFrom: Int?

    /// `student`: the student's name as the paper's record has it; `changes`: the shown round's changes as the Changes
    /// tab has them, by id (the edits a note linked elsewhere are shown from them).
    init(_ c: Comment, round n: Int, pdfs: [Int: String], textX: [[Double]?], showChanges: Bool,
         figures: [String: String] = [:], edits: [String: AnchorContext] = [:], emailed: [Int: String] = [:],
         open: Bool = true, student: String = "", changes: [String: ChangeModel] = [:], catalog: TagCatalog? = nil,
         suggest: Bool = false, reopenIn: Int? = nil) {
        id = c.id
        self.open = open
        carried = c.carried
        status = Status(c)
        color = c.markColor
        kind = c.markKind
        page = c.page
        note = c.note
        title = NoteTitle(c.note)
        firstLine = c.note.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let q = CardContent.collapsed(c.text ?? c.context?.text ?? c.oldQuote ?? "")
        quote = c.note.isEmpty && !q.isEmpty ? "“" + q + "”" : nil
        thread = CardContent.thread(c, round: n, pdfs: pdfs, textX: textX, figures: figures, edits: edits)
        turns = CardContent.turns(c, sections: thread, round: n, student: student, emailed: emailed)
        fold = CardContent.fold(turns)
        var labels = Dictionary(turns.map { ($0.id, CardContent.label($0)) }, uniquingKeysWith: { a, _ in a })
        if let fold { labels["fold"] = CardContent.label(fold) }
        self.labels = labels
        let elsewhere = c.studentNote.map { $0.isEmpty ? [] : $0.elsewhere } ?? []
        attachments = elsewhere.compactMap { changes[$0] }
        let last = thread[thread.count - 1]
        if status == .new || status == .followUp {
            stateWord = status.word.lowercased()  // what final.pdf asks for
        } else if c.anchorState == "orphan" {
            stateWord = status == .notFound && open ? "not found · re-anchor" : "not found"
            stateTone = status == .notFound ? .danger : .plain
        } else if last.uncertain {
            stateWord = "position uncertain"
            stateTone = open ? .attention : .plain
        } else if last.round == n {
            // moved with edits: "revised", what happened to the words; only moved: "moved", as with nothing attached
            if last.event != "moved" {
                stateWord = last.event
            } else if !last.onlyMoved {
                stateWord = "revised"
            } else {
                stateWord = c.page.flatMap { $0 != c.history.last?.page ? "moved to p.\($0 + 1)" : nil } ?? "moved"
            }
        } else if !elsewhere.isEmpty {
            // only an edit the note linked elsewhere: "unchanged" would say the student did nothing (CARD §3.4)
            stateWord = attachments.first?.page.map { "edit on p.\($0 + 1)" } ?? "edited elsewhere"
        } else if c.anchorState == "moved", let p = c.page, p != c.history.last?.page {
            stateWord = "moved to p.\(p + 1)"
        } else {
            // the shown round changed nothing; a section after the first is a fix from an earlier round, not "unchanged"
            stateWord = thread.count == 1 ? (c.anchorState == "moved" ? "moved" : "unchanged")
                : "\(last.event != "moved" ? last.event : last.onlyMoved ? "moved" : "revised") in R\(last.round)"
        }
        revivedFrom = c.revived?.from
        // reopened into this round (TAGS.md §9.3): the row's one word for it, unless the comment is not found
        if revivedFrom != nil && status == .toCheck && stateTone == .plain { stateWord = "reopened" }
        self.reopenIn = reopenIn
        let cat = catalog ?? TagCatalog()
        tags = cat.sorted(c.tagIDs).map { id in
            let t = cat.tag(id)
            return CardTag(id: id, name: cat.name(id), sign: t?.sign,
                           help: t.map(TagText.help) ?? "A tag from another Mac’s list")
        }
        if suggest && c.tagIDs.isEmpty, let catalog,
           let s = TagSuggester.suggest(for: c, catalog: catalog).first, let t = catalog.tag(s.id) {
            suggestion = CardSuggestion(id: s.id, name: t.name, sign: t.sign, reason: s.reason, help: TagText.help(t))
        }
        var r: [String: AttributedString] = [:]
        for s in thread where s.kind == .text || s.kind == .source {
            r[s.id] = CardContent.render(s.full, color: c.markColor, strong: s.strong, showChanges: showChanges)
            if let short = s.short {
                r[s.id + ".short"] = CardContent.render(short, color: c.markColor, strong: s.strong, showChanges: showChanges)
            }
        }
        if fold != nil, let s = thread.first, s.kind == .text, let cut = CardContent.foldTrim(s.full) {
            r[s.id + ".fold"] = CardContent.render(cut, color: c.markColor, strong: s.strong, showChanges: showChanges)
        }
        rendered = r
        info = CardInfo(location: c.file.map { $0 + (c.line.map { ":\($0)" } ?? "") }, method: c.method,
                        changes: c.changes, newImages: c.changes.compactMap { figures[$0] })
        verdict = c.verdict
        verdictNote = c.verdictNote ?? ""
        studentNote = c.studentNote.flatMap { $0.isEmpty ? nil : $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let pageText = c.page.map { "page \($0 + 1)" } ?? "no page"
        let word = status.word(open: open).lowercased()  // "left open" in a closed round
        accessibility = [c.id, word, stateWord == word ? nil : stateWord, pageText]
            .compactMap { $0 }.joined(separator: ", ")
            + (c.note.isEmpty ? "" : ". Note: " + c.note)
            + (studentNote.map { $0.isEmpty ? ". The student pointed an edit to it" : ". Student’s note: " + $0 } ?? "")
    }
}
