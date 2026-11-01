import Foundation

// Reading in the PDF view (UX.md §18; CONTRACT amendment "Reading in the PDF view"): the paragraphs the advisor
// confirms as read, the bars beside the changed ones still unread, N / C / Shift-C, the sidebar's Contents and the
// status line's count. Pure logic over the state's `reading`; the PDF drawing is in PDFPane.swift.

/// `[page, [x0, y0, x1, y1]]` in contract coordinates.
struct PageRect: Decodable, Equatable {
    var page: Int
    var rect: [Double]

    init(page: Int, rect: [Double]) {
        self.page = page
        self.rect = rect
    }

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        page = try c.decode(Int.self)
        rect = try c.decode([Double].self)
    }

    var valid: Bool { rect.count == 4 }
}

/// A paragraph the advisor reads (a paragraph, list item, reference entry, formula, float or listing): its block,
/// the section or subsection heading above it (−1: the title and abstract), and where it is in the PDF, one rect per
/// column it is set in (a paragraph across a column or page break has two).
struct Paragraph: Decodable, Equatable {
    var block: Int
    var section: Int
    var parts: [PageRect]
}

/// A section or subsection heading, for the outline.
struct Heading: Decodable, Equatable {
    var block: Int
    var level: Int
    var title: String
    var parts: [PageRect] = []
}

/// Where the advisor reads, kept across rounds (design/pdf-reader/PLAN.md P1.1): the block at the view's third, which
/// of its parts and how far below that part's top the third is; the page and point too, for a round whose paragraphs
/// cannot be followed.
struct ReadingPlace: Equatable {
    var round: Int
    var block: Int?
    var part = 0
    var offset = 0.0
    var page: Int
    var x: Double
    var y: Double
}

/// The engine's `follow` (CONTRACT amendment "The same place across rounds").
struct FollowReply: Decodable {
    var block: Int?
    var exact: Bool
    var parts: [PageRect]
}

enum Reading {
    /// Bars are shown from round 2 on: in round 1 every paragraph is new, and finishing it marks them all read.
    static func tracked(round: Int?) -> Bool { (round ?? 0) >= 2 }

    /// N: the next unread paragraph in reading order (the order of `ps`: the engine gives them as printed, so a float
    /// set on a later page is read there), after `current` (the one last gone to, while it is in view), else from
    /// `top` (the first paragraph in view, or a heading's block) on; wrapping; nil when none is unread.
    static func next(after current: Int?, from top: Int?, in ps: [Paragraph], read: Set<Int>) -> Int? {
        let blocks = ps.map(\.block)
        guard !blocks.isEmpty else { return nil }
        // a block that is not a paragraph (a heading): from the first paragraph after it in the source
        func index(_ b: Int) -> Int? { blocks.firstIndex(of: b) ?? blocks.filter { $0 > b }.min().flatMap(blocks.firstIndex) }
        let start: Int
        if let c = current {
            start = blocks.firstIndex(of: c).map { $0 + 1 } ?? index(c) ?? 0
        } else if let t = top {
            start = index(t) ?? 0
        } else {
            start = 0
        }
        for k in 0..<blocks.count {
            let b = blocks[(start + k) % blocks.count]
            if !read.contains(b) { return b }
        }
        return nil
    }

    /// The blocks of a paragraph's section, for Shift-C: from its heading to the next heading at its level or above
    /// (subsections included); the title and abstract (section −1) run to the first heading.
    static func section(_ head: Int, headings: [Heading]) -> Range<Int> {
        let first = headings.map(\.block).min() ?? Int.max
        guard head >= 0, let h = headings.first(where: { $0.block == head }) else { return 0..<first }
        return head..<end(of: h, headings: headings)
    }

    /// Where heading h's section ends: the next heading at its level or above.
    static func end(of h: Heading, headings: [Heading]) -> Int {
        headings.filter { $0.block > h.block && $0.level <= h.level }.map(\.block).min() ?? Int.max
    }

    /// The paragraph a point of a page is in (C under a selection, the context menu): the one whose part holds it,
    /// 2 pt of slack; the smallest part when several do.
    static func paragraph(at page: Int, x: Double, y: Double, in ps: [Paragraph]) -> Int? {
        var best: (block: Int, area: Double)?
        for p in ps {
            for part in p.parts where part.page == page && part.valid {
                let r = part.rect
                guard r[0] - 2 <= x, x <= r[2] + 2, r[1] - 2 <= y, y <= r[3] + 2 else { continue }
                let area = (r[2] - r[0]) * (r[3] - r[1])
                if best.map({ area < $0.area }) ?? true { best = (p.block, area) }
            }
        }
        return best?.block
    }

    /// The block at a point of a page, for the Contents' current section: a paragraph's or heading's part holding `y`
    /// (and `x`, when several do), else the first below it on that page, else the last above it; on a page without
    /// any, the last block of an earlier page.
    static func block(page: Int, x: Double, y: Double, paragraphs: [Paragraph], headings: [Heading]) -> Int? {
        let all = paragraphs.flatMap { p in p.parts.map { (p.block, $0) } } + headings.flatMap { h in h.parts.map { (h.block, $0) } }
        let on = all.filter { $0.1.page == page && $0.1.valid }
        let holding = on.filter { $0.1.rect[1] <= y && y <= $0.1.rect[3] }
        if let hit = holding.first(where: { $0.1.rect[0] <= x && x <= $0.1.rect[2] }) ?? holding.first { return hit.0 }
        if let below = on.filter({ $0.1.rect[1] > y }).min(by: { $0.1.rect[1] < $1.1.rect[1] }) { return below.0 }
        if let above = on.max(by: { $0.1.rect[3] < $1.1.rect[3] }) { return above.0 }
        return all.filter { $0.1.page < page }.map(\.0).max()
    }

    /// The place being read in round `round`: the block at the point (`block(page:…)`), the part of it on the point's
    /// page and the point's distance below that part's top (0 above it).
    static func place(round: Int, page: Int, x: Double, y: Double, paragraphs: [Paragraph], headings: [Heading]) -> ReadingPlace {
        var out = ReadingPlace(round: round, page: page, x: x, y: y)
        guard let b = block(page: page, x: x, y: y, paragraphs: paragraphs, headings: headings) else { return out }
        let parts = (paragraphs.first { $0.block == b }?.parts ?? headings.first { $0.block == b }?.parts ?? []).filter(\.valid)
        out.block = b
        if let i = parts.firstIndex(where: { $0.page == page && $0.rect[1] <= y && y <= $0.rect[3] }) ?? parts.firstIndex(where: { $0.page == page }) {
            out.part = i
            out.offset = max(0, y - parts[i].rect[1])
        }
        return out
    }

    /// Where a place followed into another round goes: the same part of its block there (else its last), as far below
    /// that part's top (at most its height; its top when the block is a neighbour, not the same paragraph); without a
    /// block there, the same point of the same page (at most the last page). (page, x, y) in contract coordinates.
    static func followed(_ from: ReadingPlace, reply: FollowReply?, pages: Int) -> (page: Int, x: Double, y: Double)? {
        let parts = (reply?.parts ?? []).filter(\.valid)
        if reply?.block != nil, !parts.isEmpty {
            let p = parts[min(from.part, parts.count - 1)], r = p.rect
            return (p.page, (r[0] + r[2]) / 2, r[1] + (reply?.exact == true ? min(from.offset, r[3] - r[1]) : 0))
        }
        guard pages > 0 else { return nil }
        return (min(from.page, pages - 1), from.x, from.y)
    }

    /// The bar beside a part, in contract coordinates: 2 pt wide in the page margin, 3 pt from the text column (the
    /// page's text_x, else the part's own edge): left of the text for one column and the left column, right of it for
    /// the right column (`gap`: the page's column gap, nil for one column) and, on a one-column page, for a part that
    /// starts right of the text's middle or, set beside a wider part, ends at the text's right edge (a float wrapped
    /// in text on the right, whose paragraph has the left bar). A part set beside a wider one whose bar is on the same
    /// side (a float wrapped on the left) has its bar 4 pt further out, 2 pt clear of the other, so two blocks never
    /// look like one. `beside`: the parts of the page's other paragraphs, read or not, so a bar does not move when
    /// another is read. It never covers text or a margin ruler, which is outside text_x.
    /// `bold`: the paragraph Next (N) went to, whose bar is 1 pt wider, outwards (POLISH §3 row 3: no fill under it).
    static func bar(_ part: PageRect, textX: [Double]?, gap: Double?, beside others: [PageRect] = [],
                    bold: Bool = false) -> [Double] {
        let r = part.rect
        let tx = textX.flatMap { $0.count == 2 ? $0 : nil }
        func right(_ r: [Double], flush: Bool) -> Bool {
            if let gap { return r[0] >= gap - 3 }
            guard let tx else { return false }
            return r[0] > (tx[0] + tx[1]) / 2 || flush && r[2] >= tx[1] - 3 && r[0] > tx[0] + 3
        }
        // the parts this one is set beside: level with it (by more than 2 pt), across more than half of it, and this
        // one at most 90% as wide (a paragraph wrapped round a float; not an item next to a paragraph)
        let wider = others.filter { o in
            let q = o.rect
            return o.page == part.page && o.valid && q != r && min(q[3], r[3]) - max(q[1], r[1]) > 2
                && min(q[2], r[2]) - max(q[0], r[0]) > (r[2] - r[0]) / 2 && r[2] - r[0] <= 0.9 * (q[2] - q[0])
        }
        let onRight = right(r, flush: !wider.isEmpty)
        let out = wider.contains { right($0.rect, flush: false) == onRight } ? 4.0 : 0
        let wide = bold ? 1.0 : 0
        if onRight {
            let x = (tx?[1] ?? r[2]) + 3 + out
            return [x, r[1], x + 2 + wide, r[3]]
        }
        let x = (tx?[0] ?? r[0]) - 5 - out
        return [x - wide, r[1], x + 2, r[3]]
    }
}

/// One row of the sidebar's Contents (UX.md §18): a section or subsection, or the title and abstract.
struct OutlineRow: Equatable, Identifiable {
    var block: Int  // the heading, or 0 for the title and abstract
    var title: String
    var number: String? = nil  // "2.1", "A": the heading's number, shown in a column of its own
    var name: String = ""  // the title without its number
    var level: Int
    var range: Range<Int>
    var read: Int
    var count: Int
    var open: Int  // new, to check, not found or follow-up comments in it, its subsections included (help tag, VoiceOver)
    /// The open comments in its own text, from its heading to its first subheading: the number the row shows, so the
    /// column adds up to the paper's count (design/review-page/BRIEF.md E8, decision D4 (a)).
    var own = 0
    var changed: Bool  // it has bars: changed paragraphs still unread
    var tracked: Bool  // round 2 on: progress is shown

    var id: Int { block }
    var done: Bool { count > 0 && read == count }
}

enum Outline {
    /// The title and abstract first (when the paper has any before its first heading), then a row per section and
    /// subsection heading (References too). A row counts its whole section, deeper headings included. `comments` are
    /// the blocks of the open comments. `marks`: reading marks on (Settings); off, no row is tracked, so none has a dot
    /// or Mark Section Read.
    static func rows(_ r: ReadingInfo, read: Set<Int>, comments: [Int] = [], round: Int, marks: Bool = true) -> [OutlineRow] {
        let tracked = marks && Reading.tracked(round: round)
        let headings = r.headings.sorted { $0.block < $1.block }
        let numbers = Self.numbers(headings.map(\.title))
        func row(_ block: Int, _ title: String, _ level: Int, _ range: Range<Int>, _ number: String? = nil) -> OutlineRow {
            let ps = r.paragraphs.filter { range.contains($0.block) }
            let done = ps.filter { read.contains($0.block) }.count
            let name = number.map { String(title.dropFirst($0.count)).trimmingCharacters(in: .whitespaces) } ?? title
            // its own text: up to the next heading, which is its first subheading when it has one
            let own = range.lowerBound..<min(range.upperBound, headings.first { $0.block > block }?.block ?? range.upperBound)
            return OutlineRow(block: block, title: title, number: number, name: name, level: level, range: range,
                              read: done, count: ps.count, open: comments.filter(range.contains).count,
                              own: comments.filter(own.contains).count, changed: tracked && done < ps.count, tracked: tracked)
        }
        let first = headings.first?.block ?? Int.max
        var rows: [OutlineRow] = []
        if first > 0 && (r.paragraphs.contains { $0.block < first } || comments.contains { $0 < first }) {
            rows.append(row(0, "Title and abstract", 1, 0..<first))
        }
        for (h, n) in zip(headings, numbers) {
            rows.append(row(h.block, h.title, h.level, h.block..<Reading.end(of: h, headings: headings), n))
        }
        return rows
    }

    /// A heading's number as printed (compiled once: the strip's ruler asks for each section at every build of the map).
    private static let numbered = try! NSRegularExpression(pattern: #"^(\d+|[A-Z])(\.\d+)*\.?$"#)

    /// Each heading's number as printed before its title, or nil: "3", "2.1", "A.1", "4."; a single capital letter ("A
    /// Dataset Details") only in a run of appendices from A on (A, B, …, or A with an A.1), so "A Note on Noise"
    /// alone keeps its "A".
    static func numbers(_ titles: [String]) -> [String?] {
        func lead(_ t: String) -> String? {
            guard let sp = t.firstIndex(where: \.isWhitespace), sp > t.startIndex else { return nil }
            return String(t[..<sp])
        }
        let leads = titles.map { t in
            lead(t).flatMap { l in numbered.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)) != nil ? l : nil }
        }
        // the letters that start an appendix run: A, then B, C, … in order, or A with a numbered A.1
        var letters: Set<String> = []
        let single = leads.compactMap { $0 }.filter { $0.count == 1 && $0.first!.isUppercase }
        if single.first == "A" && (single.count > 1 && single[1] == "B" || leads.contains { $0?.hasPrefix("A.") == true }) {
            for (i, l) in single.enumerated() where l == String(UnicodeScalar(UInt8(65 + min(i, 25)))) { letters.insert(l) }
        }
        return leads.map { l in l.flatMap { $0.count == 1 && $0.first!.isUppercase && !letters.contains($0) ? nil : $0 } }
    }

    /// The row to highlight for a block: the deepest whose range holds it.
    static func current(_ rows: [OutlineRow], block: Int?) -> Int? {
        guard let block else { return nil }
        return rows.filter { $0.range.contains(block) }.max { $0.level < $1.level }?.block
    }

    /// The reading part of the status line under the PDF (POLISH §3 row 3): `footer`'s words, counting down, with
    /// Next and Mark Read while the open round has changed paragraphs to read; a closed round's line has no buttons.
    static func status(_ r: ReadingInfo, read: Set<Int>, round: Int, closed: Bool) -> ReadingLine {
        let text = footer(r, read: read, round: round, closed: closed)
        guard Reading.tracked(round: round) else { return ReadingLine(text: text, short: "Round 1") }
        let left = r.paragraphs.filter { !read.contains($0.block) }.count
        guard left > 0 else { return ReadingLine(text: text, short: "All read", done: true) }
        return ReadingLine(text: text, short: closed ? "\(left) left unread" : "\(left) to read", bar: true, actions: !closed)
    }

    /// The to-do, "12 changed paragraphs to read" (the other paragraphs count as read because finishing a round marks
    /// them read, not because they were read in this one); in a closed round what was left, which no key can change
    /// now; in round 1, what finishing it does.
    static func footer(_ r: ReadingInfo, read: Set<Int>, round: Int, closed: Bool) -> String {
        guard Reading.tracked(round: round) else {
            return closed ? "Finishing Round 1 marked every paragraph read" : "Round 1: finishing it marks every paragraph read"
        }
        let left = r.paragraphs.filter { !read.contains($0.block) }.count
        let some = left == 1 ? "1 changed paragraph" : "\(left) changed paragraphs"
        if closed {
            return left == 0 ? "All changed paragraphs were read in Round \(round)" : some + " left unread when Round \(round) closed"
        }
        return left == 0 ? "All changed paragraphs are read" : some + " to read"
    }
}

/// The reading count in the status line (POLISH §3 row 3): `short` where the line is narrow; `bar`: the olive bar
/// before it (changed paragraphs are left); `done`: a tick (all read); `actions`: Next and Mark Read (an open round with
/// paragraphs to read).
struct ReadingLine: Equatable {
    var text: String
    var short: String
    var bar = false
    var done = false
    var actions = false
}
