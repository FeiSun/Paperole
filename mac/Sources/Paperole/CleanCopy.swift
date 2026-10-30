import Foundation

/// Clean Copy (design/pdf-reader/PLAN.md P1.2): Copy and ⌘C give a selection's words as one would quote them, its
/// lines joined into paragraphs, a word hyphenated at a line's end mended, the margin's line numbers and ligatures
/// left out. Pure (the tests); `PDFController.cleanText` gives it the selection's lines.
enum CleanCopy {
    /// One line of a selection: its words as PDFKit gives them, and its bounds in contract coordinates (x from the
    /// crop box's left, y down from its top).
    struct Line: Equatable {
        var text: String
        var page: Int
        var x0: Double, top: Double, x1: Double, bottom: Double
    }

    /// The lines' text. `rulers(page)`: the page's margin line numbers, [left, right], each [x0, y0, x1, y1] or nil
    /// (round.build.rulers): a line of digits within a ruler is left out, and digits at a line's start (end) as a word
    /// of their own when the line reaches into the left (right) ruler; a page without rulers keeps every digit. Lines
    /// join with a space, or nothing after a hyphen, dash or slash that ends a word; the hyphen goes when a lower-case
    /// word follows, the part before it is a plain word ("state-of-the-" keeps it) and `keepsHyphen(part, word)` does
    /// not say it is a compound's ("temperature-" "softened"; `keepsHyphen(_:_:text:isWord:)`). A new paragraph (a
    /// blank line) starts where `block(line)` changes (the engine's paragraphs, `block(of:…)`); between lines either of
    /// which has no block, where a line starts lower on the same page by more than 0.6 of a line's height, with the
    /// lines across each other. A line in another column or page goes on the same paragraph. `outside(line)`: a line
    /// above or below the page's text (a running head or foot, a footnote, `outside(_:paragraphs:headings:)`), left out
    /// when the selection has other lines (a paragraph copied across a page break).
    static func text(_ lines: [Line], rulers: (Int) -> [[Double]?]?, block: (Line) -> Int? = { _ in nil },
                     outside: (Line) -> Bool = { _ in false },
                     keepsHyphen: (String, String) -> Bool = { _, _ in false }) -> String {
        var out = "", last: (line: Line, block: Int?)?
        let inside = lines.filter { !outside($0) }
        for var l in inside.isEmpty ? lines : inside {
            l.text = clean(l.text)
            if let rs = rulers(l.page), rs.count == 2 {
                let left = rs[0].flatMap { $0.count == 4 ? $0 : nil }, right = rs[1].flatMap { $0.count == 4 ? $0 : nil }
                func within(_ r: [Double]?) -> Bool { r.map { l.x0 >= $0[0] - 1 && l.x1 <= $0[2] + 1 } ?? false }
                if (within(left) || within(right)) && l.text.allSatisfy({ $0.isNumber || $0 == " " }) { continue }
                if let left, l.x0 <= left[2] + 1, let r = l.text.firstMatch(of: #/^\d{1,5}(\s+|$)/#) { l.text.removeSubrange(r.range) }
                if let right, l.x1 >= right[0] - 1, let r = l.text.firstMatch(of: #/(^|\s+)\d{1,5}$/#) { l.text.removeSubrange(r.range) }
            }
            guard !l.text.isEmpty else { continue }
            let b = block(l)
            if let (a, ab) = last {
                let breaks: Bool
                if let ab, let b {
                    breaks = ab != b
                } else {
                    let gap = l.top - a.bottom, across = min(a.x1, l.x1) > max(a.x0, l.x0)
                    breaks = a.page == l.page && across && l.top >= a.top && gap > 0.6 * max(a.bottom - a.top, 1)
                }
                out = breaks ? out + "\n\n" + l.text : join(out, l.text, keepsHyphen: keepsHyphen)
            } else {
                out = l.text
            }
            last = (l, b)
        }
        return out
    }

    /// The paragraph, float or heading whose part holds a line's middle (`reading`'s paragraphs and headings), or nil.
    static func block(of l: Line, paragraphs: [Paragraph], headings: [Heading]) -> Int? {
        let x = (l.x0 + l.x1) / 2, y = (l.top + l.bottom) / 2
        let all = paragraphs.flatMap { p in p.parts.map { (p.block, $0) } } + headings.flatMap { h in h.parts.map { (h.block, $0) } }
        return all.first { $0.1.page == l.page && $0.1.valid && $0.1.rect[0] - 2 <= x && x <= $0.1.rect[2] + 2
            && $0.1.rect[1] - 2 <= y && y <= $0.1.rect[3] + 2 }?.0
    }

    /// Whether a line is in no paragraph, float or heading and lies above or below all of them on its page (the
    /// running head and foot, footnotes); false on a page without any.
    static func outside(_ l: Line, paragraphs: [Paragraph], headings: [Heading]) -> Bool {
        guard block(of: l, paragraphs: paragraphs, headings: headings) == nil else { return false }
        let on = (paragraphs.flatMap(\.parts) + headings.flatMap(\.parts)).filter { $0.page == l.page && $0.valid }
        guard let top = on.map({ $0.rect[1] }).min(), let foot = on.map({ $0.rect[3] }).max() else { return false }
        return l.bottom <= top + 1 || l.top >= foot - 1
    }

    /// A line's words: ligatures spelt out, soft hyphens gone, runs of white space one space, trimmed.
    static func clean(_ s: String) -> String {
        var t = s
        for (lig, letters) in [("ﬁ", "fi"), ("ﬂ", "fl"), ("ﬀ", "ff"), ("ﬃ", "ffi"), ("ﬄ", "ffl"), ("ﬅ", "st"), ("ﬆ", "st")] {
            t = t.replacingOccurrences(of: lig, with: letters)
        }
        t = t.replacingOccurrences(of: "\u{00AD}", with: "")
        return t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// `before` and the next line's words: "segmen-" and "tation" make "segmentation"; "the model –" and "which" keep
    /// their space.
    static func join(_ before: String, _ next: String, keepsHyphen: (String, String) -> Bool = { _, _ in false }) -> String {
        guard let end = before.last, "-–—/".contains(end) else { return before.isEmpty ? next : before + " " + next }
        if before.dropLast().last?.isWhitespace ?? true { return before + " " + next }  // a dash between words
        if end == "-" {
            let word = String((before.dropLast().split(separator: " ").last ?? "").drop { !$0.isLetter })  // "(segmen-"
            let plain = !word.isEmpty && word.allSatisfy(\.isLetter)
            let mend = plain && next.first?.isLowercase == true && !keepsHyphen(word, String(next.prefix { $0.isLetter }))
            return (mend ? String(before.dropLast()) : before) + next
        }
        return before + next
    }

    /// Whether "left-" at a line's end and "right" on the next are one compound, kept hyphenated, rather than a word TeX
    /// broke: the paper's own text (`text()`, read only when it is needed) has "left-right" elsewhere (yes) or
    /// "leftright" (no); else "leftright" is a word (no: "under-" "standing"); else both are words of four letters or
    /// more (yes: "self-" "attention"). `isWord`: the spelling dictionary.
    static func keepsHyphen(_ left: String, _ right: String, text: () -> String, isWord: (String) -> Bool) -> Bool {
        let t = text()
        if t.range(of: left + "-" + right, options: .caseInsensitive) != nil { return true }
        if t.range(of: left + right, options: .caseInsensitive) != nil { return false }
        if isWord(left + right) { return false }
        return left.count >= 4 && right.count >= 4 && isWord(left) && isWord(right)
    }
}
