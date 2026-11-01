import AppKit
import CoreGraphics

// The paper map's layout (OVERVIEW-v2 §4, the mockup's `paperMapSVG`), as pure functions of the engine's overview and
// the overview's width: what is drawn where, and what a click there follows. `MapView` (OverviewMapView.swift) only
// draws a `MapScene` and asks it what is under the pointer, so the rules that keep every number readable are tested
// here (MapLayoutTests).

/// The map's text styles: the axis and the hover's names (11), the round's date, the bands' words and the readout's
/// second line (12), the readout and the round's name (13), the cells' numbers (13; an older round's regular) and
/// names (12), and the Sage lines and links; none under 11 pt (§19; UI v4's type scale, mac/UX.md §40.3).
enum MapFont: Equatable, Hashable, CaseIterable {
    case caption, small, smallRegular, body, bodyBold, number, numberRegular, name, label

    var size: CGFloat {
        switch self {
        case .caption: return 11  // §19: nothing under 11 (it was 10.5, the mockup's t10)
        case .small, .label: return 11
        case .smallRegular, .name: return 12
        case .body, .bodyBold, .number, .numberRegular: return 13
        }
    }

    var weight: NSFont.Weight {
        switch self {
        case .smallRegular, .name, .body, .numberRegular: return .regular
        case .bodyBold, .number, .label: return .semibold
        default: return .medium
        }
    }

    /// Its font, made once per style (the code audit: the scene build made a new NSFont for every ascent, descent and
    /// cap height it read).
    var nsFont: NSFont { Self.fonts[self]! }

    private static let fonts: [MapFont: NSFont] = Dictionary(uniqueKeysWithValues: allCases.map { f -> (MapFont, NSFont) in
        (f, f == .number || f == .numberRegular || f == .bodyBold || f == .body
            ? NSFont.monospacedDigitSystemFont(ofSize: f.size, weight: f.weight) : NSFont.systemFont(ofSize: f.size, weight: f.weight))
    })

    private static let lock = NSLock()
    nonisolated(unsafe) private static var widths: [String: CGFloat] = [:]

    /// The width of a line of text in this style (cached: the map measures the same words at every redraw).
    func width(_ s: String) -> CGFloat {
        let key = "\(size)|\(weight.rawValue)|" + s
        Self.lock.lock()
        defer { Self.lock.unlock() }
        if let w = Self.widths[key] { return w }
        let w = ceil((s as NSString).size(withAttributes: [.font: nsFont]).width * 10) / 10
        if Self.widths.count > 4000 { Self.widths.removeAll() }
        Self.widths[key] = w
        return w
    }

    var ascent: CGFloat { nsFont.ascender }
    var descent: CGFloat { -nsFont.descender }
}

/// The colours the map draws with (OVERVIEW-v2 §4.7, VISUAL v3 §3): one Sage green in three steps over a near-neutral
/// track for the counts (mac/UX.md §40.10; a warm stone before), the accent's Sage only for what is followed (`path`
/// where it is drawn over the cells), vermilion only for the marks of what is to check, red only for errors, the edits'
/// green only for the student's added words in a help tag. Each is resolved for the appearance by `MapInk`.
enum MapRole: Hashable {
    /// The cells: no comment (the track), then the paper's three steps; their number and name. UI v4: the one data-ink
    /// ramp (map cells, small maps, By section, Help pictures), with `ink` its darkest (bars, edit ticks).
    case track, s1, s2, s3, ink, number, name
    /// An older round's ramp: the steps at 65% over the page, mixed in advance, so its text never fades (UI v4).
    case otrack, os1, os2, os3
    /// Bands (one tone: whether a section moved, merged, split or was renamed is said by the band's shape and its
    /// label), the band of what is followed, the lens's hairlines and its wedge over a folded part.
    case band, bandSelected, fan, wedge
    /// The days with you and with the student (Turnaround, the board's timeline), the Today rule, a dark cell's keyline
    /// without comments, a thumbnail's page, and what closed in 1, 2 or 3+ rounds (UI v4, README §6).
    case you, stu, today, zeroline, thumb, c1, c2, c3
    case words, other, attention, danger, accent, accentText, accentTint
    case rule, label, label2, secondary, tertiary, content, card, neutral
    /// What is followed, drawn over the cells: a comment's path and the edits made for it, the outline of the section's
    /// cell and of the page followed, the table's cell holding the comment followed. The accent in Light Mode; lighter
    /// in Dark Mode, where the accent is within ΔE00 6 of the green s3 (mac/UX.md §40.10).
    case path
    /// A link drawn on the map (the axis's Show and Fold): the system's link colour, as every link in words
    /// (`LinkStyle`; the UI audit: in the Sage text colour they read as plain words, BACKLOG O32).
    case link
    /// The words of what steps back while something is followed: a colour, not an alpha, so a dimmed cell's name and
    /// number step back together and still read at 4.5:1 or more (the UI audit: its number fell to 1.9:1).
    case dimText

    /// The fill of a cell with this level (0: no comment).
    static func cell(_ level: Int) -> MapRole { [.track, .s1, .s2, .s3][max(0, min(3, level))] }
    /// A small map's cell: the same ramp (UI v4: one ramp).
    static func mini(_ level: Int) -> MapRole { cell(level) }
    /// An older round's cell.
    static func old(_ level: Int) -> MapRole { [.otrack, .os1, .os2, .os3][max(0, min(3, level))] }
}

/// What can be clicked on the map, and what it follows (`MapScene.item`).
enum MapTarget: Equatable, Hashable {
    case cell(String, round: Int)
    /// A band from round − 1's section `from` to this round's `to` (nil: removed or added).
    case band(from: String?, to: String?, round: Int)
    case round(Int)
    case unfold, fold
    case unplaced(Int)
    case edit(String, round: Int)
    case comment(String, round: Int)
    /// A folded part's block in a round (a click shows its sections), and the page axis's Show and Fold.
    case block(FoldKind, round: Int)
    case showPart(FoldKind)
    case foldPart(FoldKind)
}

/// A line of text on the map: where its baseline starts (`anchor` says which end or its middle sits at `x`), its
/// style, its colour, and the box it covers (from the font's ascender to its descender), for the collision rules.
struct MapText: Equatable {
    enum Anchor: Equatable { case start, middle, end }
    var text: String
    var x: CGFloat
    var baseline: CGFloat
    var anchor: Anchor = .start
    var font: MapFont
    var ink: MapRole
    var opacity: Double = 1
    /// A halo of this colour behind the letters (a structure label over a band, a number beside a path dot).
    var halo: MapRole?

    var width: CGFloat { font.width(text) }

    var rect: CGRect {
        let w = width
        let x0 = anchor == .start ? x : anchor == .middle ? x - w / 2 : x - w
        return CGRect(x: x0, y: baseline - font.ascent, width: w, height: font.ascent + font.descent)
    }

    /// The glyphs' own box: digits and capitals, without the font's room above and below (the numbers' rule).
    var inkRect: CGRect {
        let r = rect
        let cap = font.nsFont.capHeight
        return CGRect(x: r.minX, y: baseline - cap - 0.5, width: r.width, height: cap + 1)
    }
}

/// The map's geometry for the overview's width (OVERVIEW-v2 §2 high, the mockup's `geo`; UI v4, mac/UX.md §40.3): the
/// readout at the right in a fixed 168 pt (Comments, and You once a shown round has answers: by the data only, never
/// by what is followed, so the Sage line under it keeps its room); the "+n unplaced" caps after the rows when a round
/// has any; the map the rest, from 108 pt (the round's label) to 22 pt before the readout. One page scale for every
/// row: the paper's most pages.
struct MapGeometry: Equatable {
    static let mapX: CGFloat = 108
    static let lens: CGFloat = 30
    static let cell: CGFloat = 32
    static let rug: CGFloat = 8
    static let gap: CGFloat = 20
    static var row0: CGFloat { lens + 30 }
    static var pitch: CGFloat { cell + rug + gap }
    /// The selected round's box behind its label (BRIEF §8.3, the mockup's `.rsel`): 10 pt left of the label column.
    static let box = CGSize(width: 104, height: 44)

    var width: CGFloat
    var columns: Int
    var readoutWidth: CGFloat
    var capWidth: CGFloat
    var maxPages: Double
    /// pt per page: the map's width over the paper's most pages, or more when parts fold (`FoldPlan`).
    var k: CGFloat

    init(width: CGFloat, maxPages: Double, unplaced: Bool, you: Bool = false) {
        self.width = width
        columns = OverviewLayout.readoutColumns(you: you)
        readoutWidth = OverviewLayout.readoutWidth
        capWidth = unplaced ? 46 : 0
        self.maxPages = max(maxPages, 1)
        let right = width - OverviewLayout.readoutWidth - 22 - capWidth
        k = max(right - Self.mapX, 60) / CGFloat(self.maxPages)
    }

    var readoutX: CGFloat { width - readoutWidth }
    var mapRight: CGFloat { readoutX - 22 - capWidth }
    var mapWidth: CGFloat { max(mapRight - Self.mapX, 60) }
    /// The readout's columns' right edges (their figures are right-aligned): Comments, then You. Comments 48 pt ("128",
    /// "12 new"), so You has the room of all three answers with a two-digit count ("✓ 11 · ↩ 2 · – 1", 97 pt, in 108).
    var columnRight: [CGFloat] { columns == 2 ? [readoutX + 48, width] : [width] }
    var pageWidth: CGFloat { k }

    /// A place at the page scale, no part folded.
    func x(_ pos: Double) -> CGFloat { Self.mapX + CGFloat(pos) * k }
    func rowY(_ i: Int) -> CGFloat { Self.row0 + CGFloat(i) * Self.pitch }
}

/// The counts' three shades, chosen per paper (OVERVIEW-v2 §4.2, §8 decision 4; VISUAL v3 §4.1: three soft steps
/// instead of four): thirds of its own non-zero cell counts, so a paper of many short sections still shows a range and
/// a busy one does not saturate; the legend prints the ranges. Every counted cell says its number, so the shade only
/// says few, some or many.
enum MapShade {
    /// The upper bounds of the first two steps (the third is everything above): [1, 2] up to a count of 3.
    static func steps(_ counts: [Int]) -> [Int] {
        let v = counts.filter { $0 > 0 }.sorted()
        let top = v.last ?? 1
        if top <= 3 { return [1, 2] }
        func q(_ p: Double) -> Int { v[min(v.count - 1, Int((p * Double(v.count - 1)).rounded()))] }
        var t1 = q(1.0 / 3), t2 = max(t1 + 1, q(2.0 / 3))
        if t2 >= top {
            t2 = top - 1
            if t1 >= t2 { t1 = t2 - 1 }
        }
        return [max(1, t1), max(2, t2)]
    }

    /// 0 for no comment, else 1–3.
    static func level(_ n: Int, _ s: [Int]) -> Int { n <= 0 ? 0 : n <= s[0] ? 1 : n <= s[1] ? 2 : 3 }

    /// "1–3", "4–5", "6+".
    static func labels(_ s: [Int]) -> [String] {
        func r(_ a: Int, _ b: Int) -> String { a >= b ? "\(b)" : "\(a)–\(b)" }
        return [r(1, s[0]), r(s[0] + 1, s[1]), "\(s[1] + 1)+"]
    }

    /// The counts a paper's shades come from: every section's in every round, unfolded (folding never shades the
    /// body again).
    static func counts(_ d: PaperOverview) -> [Int] { d.rounds.flatMap { ($0.heat ?? []).map(\.present) } }
}

/// Where the page strip's thumbnails go (OVERVIEW-v2 §3.3; mac/UX.md §40.9): every page at one scale of its own size,
/// 72/792 (a US Letter page 72 pt high, an A4 or a landscape page in proportion), whatever the paper's or the round's
/// length, so every paper and every round has thumbnails of one size (the advisor's decision of 2026-11-01). While the
/// round's pages fit the width with 8 pt between them, one slot per page over the width, each thumbnail centred in its
/// slot; else slots of the thumbnail's width and 8 pt from the left, wider than the width: the strip and its ruler
/// scroll sideways. Pages lower than the paper's row (`row`) sit on the numbers' line. Content coordinates: a strip
/// scrolled by `offset` shows `offset`…`offset + width`.
struct StripGeometry: Equatable {
    var width: CGFloat
    var pages: Int
    /// The thumbnails' size (`thumbSize(page:)` of the round's first page).
    var thumb: CGSize = Self.letterThumb
    /// The paper's row of thumbnails (`PageStripView.rowHeight`), the same for each round, so the strip, its ruler and
    /// the map under it stay where they are whichever round the strip shows.
    var row: CGFloat = Self.height

    /// A Letter page's thumbnail height, and the room between thumbnails.
    static let height: CGFloat = 72
    static let gap: CGFloat = 8
    /// The scale from a page to its thumbnail: a Letter page (792 pt) to 72 pt.
    static let scale: CGFloat = 72 / 792
    static let letter = CGSize(width: 612, height: 792)
    static var letterThumb: CGSize { thumbSize(page: letter) }

    /// A page's thumbnail size: the page's own at `scale` (a Letter page's when it is not known).
    static func thumbSize(page: CGSize?) -> CGSize {
        guard let p = page, p.width > 0, p.height > 0 else { return thumbSize(page: letter) }
        return CGSize(width: p.width * scale, height: p.height * scale)
    }

    var thumbWidth: CGFloat { thumb.width }
    var thumbHeight: CGFloat { thumb.height }
    /// Every page with at least `gap` beside it at the width: the slots spread over it, no scrolling.
    var fits: Bool { CGFloat(max(pages, 1)) * (thumbWidth + Self.gap) <= width + 0.001 }
    var slot: CGFloat { fits ? width / CGFloat(max(pages, 1)) : thumbWidth + Self.gap }
    /// The strip's (and its ruler's) width: the width, or past it when it scrolls.
    var contentWidth: CGFloat { fits ? width : CGFloat(pages) * slot }
    var scrolls: Bool { contentWidth > width + 0.5 }
    /// The farthest the strip scrolls.
    var maxOffset: CGFloat { max(0, contentWidth - width) }
    /// The room over pages lower than the row, so they sit on the numbers' line.
    var top: CGFloat { max(0, row - thumbHeight) }
    func thumbX(_ page: Int) -> CGFloat { CGFloat(page) * slot + (slot - thumbWidth) / 2 }
    /// A place in page units on the strip.
    func x(_ pos: Double) -> CGFloat { CGFloat(pos) * slot }
    /// The page at `x` (content coordinates); nil past the pages.
    func page(at x: CGFloat) -> Int? {
        guard pages > 0, x >= 0, x < contentWidth else { return nil }
        return min(pages - 1, Int(x / slot))
    }
    /// The pages (in page units) seen at `offset`.
    func visible(offset: CGFloat) -> ClosedRange<Double> {
        let o = min(max(0, offset), maxOffset)
        return Double(o / slot)...min(Double(pages), Double((o + width) / slot))
    }
    /// The offset that shows the pages `lo`…`hi` (page units) from `offset`, moving as little as it can, 8 pt to spare,
    /// never past `lo`; nil when they are in view (or nothing scrolls).
    func reveal(_ lo: Double, _ hi: Double, from offset: CGFloat) -> CGFloat? {
        guard scrolls else { return offset > 0 ? 0 : nil }
        let o = min(max(0, offset), maxOffset)
        guard let t = OverviewModel.scrollToShow(top: Double(x(lo)), bottom: Double(x(hi)), offset: Double(o), height: Double(width),
                                                 margin: Double(Self.gap)) else { return nil }
        return min(max(0, CGFloat(t)), maxOffset)
    }
}

enum MapRules {
    /// Older rounds fold when the map would run past the window's bottom (OVERVIEW-v2 §4.1, §8 decision 12): `room` is
    /// the height from the map's top to the window's bottom less the legend. At least two fold, so the fold saves a
    /// row, and at least two stay (one of a three-round paper); a paper of fewer than three rounds never folds.
    static func folded(rounds n: Int, room: CGFloat) -> Int {
        guard n >= 3, room > 0 else { return 0 }
        if MapGeometry.row0 + CGFloat(n) * MapGeometry.pitch - MapGeometry.gap + 26 <= room { return 0 }
        let k = Int(((room - MapGeometry.row0 - 22 - 26) / MapGeometry.pitch).rounded(.down))
        return min(n - 1, max(2, n - max(2, k)))
    }

    /// The page that shows a paper best (FEATURES OV-3, the student's cards): the one with most comments and edits in
    /// the round, the first of equals; the first page when none has any. 0-based.
    static func keyPage(_ r: PaperOverview.Round?) -> Int {
        var best = 0, most = 0
        for p in (r?.pages ?? []).sorted(by: { $0.page < $1.page }) {
            let n = (p.comments ?? 0) + (p.changes ?? 0)
            if n > most { most = n; best = p.page }
        }
        return best
    }

    /// The round the strip shows by default: the latest that built (a failed round has no pages).
    static func defaultStrip(_ d: PaperOverview?) -> Int? {
        d?.rounds.last { !$0.failed && ($0.build?.pages ?? 0) > 0 }?.n ?? d?.latest?.n
    }

    /// A cell's count, its place and whether its name fits (the mockup's rule: "nothing covers a number"; VISUAL v3
    /// §4.1): with a name (`name`: its width, when it has one that fits) the count goes right, `pad` from the cell's
    /// edge (7 pt, or 4 in a narrow cell: `CellSpacing`); without one in the middle, else left or right, or beside a path
    /// dot (M = 9.5 pt from its centre), never under one. With no free place it stays where it was and the dot moves to
    /// the cell's lower edge (`nudge`).
    struct NumberPlace: Equatable {
        var x: CGFloat
        var anchor: MapText.Anchor
        var name: Bool
        var nudge: Bool
    }

    /// The room round a cell's name and count: 7 pt from each edge and 8 pt between them, or in a narrow cell 4 and 5
    /// (the advisor's review of 2026-10-20: a short name in a narrow cell is better than none).
    struct CellSpacing: Equatable {
        var pad: CGFloat
        var gap: CGFloat

        static let normal = CellSpacing(pad: 7, gap: 8)
        static let tight = CellSpacing(pad: 4, gap: 5)

        /// The room left for a name in a cell `w` wide holding a count `cw` wide (0: none).
        func room(_ w: CGFloat, count cw: CGFloat) -> CGFloat { w - 2 * pad - (cw > 0 ? gap + cw : 0) }
    }

    static func placeNumber(xa: CGFloat, xb: CGFloat, width cw: CGFloat, count n: Int, dots: [CGFloat], name nw: CGFloat? = nil,
                            spacing sp: CellSpacing = .normal) -> NumberPlace {
        let w = xb - xa, m: CGFloat = 9.5
        guard n > 0 else {
            let name = dots.isEmpty && nw.map { $0 <= sp.room(w, count: 0) } == true
            return NumberPlace(x: (xa + xb) / 2, anchor: .middle, name: name, nudge: false)
        }
        if dots.isEmpty, let nw, nw <= sp.room(w, count: cw) {
            return NumberPlace(x: xb - sp.pad, anchor: .end, name: true, nudge: false)
        }
        func span(_ x: CGFloat, _ a: MapText.Anchor) -> (CGFloat, CGFloat) {
            a == .end ? (x - cw, x) : a == .start ? (x, x + cw) : (x - cw / 2, x + cw / 2)
        }
        func hit(_ a: CGFloat, _ b: CGFloat) -> Bool { dots.contains { $0 > a - m && $0 < b + m } }
        var cands: [(CGFloat, MapText.Anchor)] = [((xa + xb) / 2, .middle)]
        if w >= 50 { cands += [(xb - 7, .end), (xa + 7, .start)] }
        for d in dots { cands += [(d - m - cw / 2 - 1, .middle), (d + m + cw / 2 + 1, .middle)] }
        for c in cands {
            let (a, b) = span(c.0, c.1)
            if a >= xa + 2 && b <= xb - 2 && !hit(a, b) { return NumberPlace(x: c.0, anchor: c.1, name: false, nudge: false) }
        }
        return NumberPlace(x: (xa + xb) / 2, anchor: .middle, name: false, nudge: true)
    }

    /// The fixed short forms of common section names (VISUAL §4.1), for a cell or the ruler too narrow for the whole.
    static let abbreviations: [String: String] = [
        "introduction": "Intro.", "discussion": "Disc.", "conclusion": "Concl.", "conclusions": "Concl.", "related work": "Related",
        "related works": "Related", "experiments": "Exp.", "evaluation": "Eval.", "preliminaries": "Prelim.", "limitations": "Limits",
        "acknowledgments": "Ack.", "acknowledgements": "Ack.", "acknowledgment": "Ack.", "acknowledgement": "Ack.",
        "ethics statement": "Ethics", "ethical considerations": "Ethics", "references": "Refs", "bibliography": "Refs",
        "materials and methods": "Methods",
    ]

    /// Small words a cut name does not end on, and that initials skip ("Results and…" is "Results…").
    static let minorWords: Set<String> = ["a", "an", "and", "as", "at", "by", "for", "from", "in", "of", "on", "or", "the", "to",
                                          "via", "vs", "vs.", "with", "&"]

    /// A section's name as it fits `room` (the advisor's review of 2026-10-20: "an abbreviation or the first characters
    /// is better than nothing", replacing VISUAL §4.1's whole-or-nothing): the first of `labels` that fits.
    static func label(_ s: String, _ font: MapFont, _ room: CGFloat, letter: String? = nil) -> String? {
        labels(s, letter: letter).first { font.width($0) <= room }
    }

    /// Every form of a name, longest first: whole ("Benchmark Construction"); its fixed short form ("Intro."); its first
    /// whole words and "…" ("Benchmark…", never ending on a small word); its first word cut, with "." (`cuts`: "Bench.",
    /// "Be."), the first word that is not a small word ("Proposed" in "The Proposed Method"); the initials of its words
    /// when it has three or more ("ASP"; two read as a word: "ES", "AS"); its first letter with "." ("B."), which reads
    /// as a short name where a lone capital reads as an appendix's letter or, as "I", the digit 1; its first letter
    /// alone, last of all (nothing only when not even one letter fits). A lettered appendix section's forms (`letter`,
    /// "C") are led by its letter, as the paper refers to it ("C Experimental Details", "C Exp."), and end on the letter.
    static func labels(_ s: String, letter: String? = nil) -> [String] {
        if let letter {
            return labels(s).filter { !isLetter($0) && $0.count > 0 }.map { letter + " " + $0 } + [letter]
        }
        var out = [s]
        let short = abbreviations[s.lowercased()]
        if let short { out.append(short) }
        let words = s.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return out }
        for k in stride(from: words.count - 1, through: 1, by: -1) {
            var head = Array(words[..<k])
            while head.count > 1, let last = head.last, minorWords.contains(last.lowercased()) { head.removeLast() }
            if head.count == 1, minorWords.contains(head[0].lowercased()) { break }
            out.append(head.joined(separator: " ").trimmingCharacters(in: .punctuationCharacters) + "…")
        }
        let content = words.map(bareWord).filter { !$0.isEmpty && !minorWords.contains($0.lowercased()) }
        let first = content.first ?? bareWord(words[0])
        // a hyphenated word is cut before its hyphen ("Pre-training": "Pre."), never inside it ("Pre-t.")
        let stem = first.split(separator: "-").first.map(String.init) ?? first
        var cut = cuts(stem)
        if let short {
            // a cut one letter short of the fixed form reads as a misspelling of it ("Intr." beside "Intro.")
            let b = bare(short)
            cut.removeAll { c in
                let x = bare(c)
                return x.count >= 3 && b.count == x.count + 1 && b.hasPrefix(x)
            }
        }
        out += cut
        let initials = content.compactMap(\.first).map { String($0).uppercased() }
        if initials.count >= 3 { out.append(initials.prefix(3).joined()) }
        if let c = stem.first {
            if !ideographic(stem) { out.append(String(c).uppercased() + ".") }
            out.append(String(c))
        }
        var seen: Set<String> = []
        return out.filter { seen.insert($0).inserted }
    }

    /// A word without the punctuation round it ("(a)" is "a", "Setup:" is "Setup").
    static func bareWord(_ w: String) -> String { w.trimmingCharacters(in: .punctuationCharacters) }

    /// Text in a script with no letters to cut at (Chinese, Japanese): a cut there ends with "…", not ".".
    static func ideographic(_ s: String) -> Bool { s.unicodeScalars.contains { $0.properties.isIdeographic } }

    /// A name that is one letter, with or without "." ("B", "B."): never shown alone by the ruler, where it reads as an
    /// appendix's letter.
    static func isLetter(_ t: String) -> Bool {
        let b = t.hasSuffix(".") ? String(t.dropLast()) : t
        return b.count == 1 && b.first?.isLetter == true
    }

    /// The first letters of a name's words that are not small words, two or three ("AI" for Abstract
    /// Interpretation): not one of its `labels` with fewer than three (two read as a word, "ES"), but the way out when
    /// every form that fits reads as another section's name.
    static func initials(_ s: String) -> String? {
        let content = s.split(separator: " ").map { bareWord(String($0)) }.filter { !$0.isEmpty && !minorWords.contains($0.lowercased()) }
        guard content.count >= 2 else { return nil }
        return content.prefix(3).compactMap(\.first).map { String($0).uppercased() }.joined()
    }

    /// A lone letter that reads as the digit 1 beside a count ("I", "l").
    static func readsAsDigit(_ t: String) -> Bool { t == "I" || t == "l" || t == "|" }

    /// A name without its "." or "…", lower-cased: what two names are compared by.
    static func bare(_ s: String) -> String { s.trimmingCharacters(in: CharacterSet(charactersIn: ".…")).lowercased() }

    /// Two names that read as the same: one starts with the other, without its "." or "…", case aside ("Abs." and
    /// "Abst.", "E" and "ES", "Results" and "Results…").
    static func clash(_ a: String, _ b: String) -> Bool {
        let x = bare(a), y = bare(b)
        return !x.isEmpty && !y.isEmpty && (x.hasPrefix(y) || y.hasPrefix(x))
    }

    /// A longer form of the same stem as `base` ("Bench." and "Benchmark…" of "Ben."; "Intro." of "Int."), which a
    /// wider cell may show for a section named `base` in its narrowest: it still reads as the same section down the
    /// rounds.
    static func extends(_ t: String, _ base: String) -> Bool {
        let x = bare(t), y = bare(base)
        return !y.isEmpty && x.count >= y.count && x.hasPrefix(y)
    }

    /// The longest of a section's `forms` (`labels`) that fits `room` in `font` and reads as its `base` name (the
    /// one it has in every round: its own, a longer form of its stem, its whole name or its fixed short form); without
    /// a base, or when none of those fits, the first that fits.
    static func pick(_ forms: [String], base: String?, _ font: MapFont, _ room: CGFloat, fixed: String? = nil,
                     avoid: [String] = []) -> String? {
        let fits = forms.filter { font.width($0) <= room }
        guard let base else { return fits.first }
        return fits.first { t in
            t == base || t == forms.first || t == fixed || extends(t, base) && !avoid.contains { clash(t, $0) }
        } ?? fits.first
    }

    /// A word cut ever shorter, each with ".": its first five letters at most (a longer cut reads as a misspelling,
    /// "Benchmar."), without the vowels it would end on ("Evalu" → "Eval."), never between two letters that make one
    /// sound ("Benc."; "Et." is still Ethics' shortest), never leaving off fewer than three letters (four of a word of
    /// eight or more: "Relat.", "Datas.", "Abstr." read as misspellings of the word), at least two letters, each once
    /// ("Benchmark": "Bench.", "Ben.", "Be."). Text without letters to cut at (Chinese) ends with "…".
    static func cuts(_ word: String) -> [String] {
        let letters = Array(word)
        guard letters.count > 2 else { return [] }
        if ideographic(word) {
            return stride(from: min(letters.count - 1, 4), through: 1, by: -1).map { String(letters[..<$0]) + "…" }
        }
        let left = letters.count >= 8 ? 4 : 3
        var out: [String] = []
        for n in stride(from: min(letters.count - left, 5), through: 2, by: -1) {
            // never inside "ch", "sh", "th", "ph", "gh", "wh", "ck", "qu" ("Benc." for Benchmark), but for two letters
            if n > 2, "cstpgw".contains(letters[n - 1].lowercased()) && letters[n].lowercased() == "h"
                || letters[n - 1].lowercased() == "c" && letters[n].lowercased() == "k"
                || letters[n - 1].lowercased() == "q" && letters[n].lowercased() == "u" { continue }
            var cut = Array(letters[..<n])
            while cut.count > 2, let c = cut.last, "aeiouAEIOU".contains(c) { cut.removeLast() }
            while cut.count > 1, let c = cut.last, !c.isLetter && !c.isNumber { cut.removeLast() }
            guard cut.count >= 2 else { continue }
            let t = String(cut) + "."
            if !out.contains(t) { out.append(t) }
        }
        return out
    }

    /// The longest start of `s` that fits `room` with an ellipsis (all of it when it fits); nil when fewer than three
    /// letters would show.
    static func fit(_ s: String, _ font: MapFont, _ room: CGFloat) -> String? {
        if font.width(s) <= room { return s }
        var chars = Array(s)
        while chars.count > 3 {
            chars.removeLast()
            let t = String(chars).trimmingCharacters(in: .whitespaces) + "…"
            if font.width(t) <= room { return t }
        }
        return nil
    }

    /// Parts joined by " · ", the last ones dropped until the line fits (the Sage line, §4.6), then cut.
    static func fitParts(_ parts: [String], _ font: MapFont, _ room: CGFloat) -> String {
        var out = parts.filter { !$0.isEmpty }
        while out.count > 1 && font.width(out.joined(separator: " · ")) > room { out.removeLast() }
        let t = out.joined(separator: " · ")
        return fit(t, font, room) ?? t
    }
}

/// How wide a row draws its sections (the advisor's review of 2026-10-20, replacing "a cell's width is its length"
/// and v2's room made for a count by its neighbours): in proportion to their length, so the map still shows where the
/// paper is long and where it is short and lines up with the strip through the lens, but never narrower than a floor
/// that holds a short name and its count ("Abc." and the paper's widest count, at most two digits, in the narrow
/// cell's spacing). The room comes from every section above the floor in proportion (`s` × its length, the same `s`
/// for the row), so the longest give the most, the row keeps its width and its ends, every section keeps its order
/// and a longer one is never drawn narrower than a shorter one. A folded part's block keeps the width the plan gave
/// it. A quiet segment (neighbouring empty sections, each under 24 pt at the page scale) is one unit of the scale, as
/// it is one track on the map: floored and scaled by its whole length, its sections sharing it by theirs. A row too
/// crowded for the floor everywhere (11 sections in 480 pt at 1280 pt) takes at most 90% of an equal share
/// as its floor, so it stays in proportion above it, but at least the room for its widest count alone when there is
/// that much.
enum MapScale {
    enum Kind: Equatable { case section, fixed }

    /// The most of an equal share the floor takes in a crowded row.
    static let share: CGFloat = 0.9

    /// The floor of a row whose `n` units of the scale (sections and quiet segments, not blocks) are `free` wide in all
    /// at the page scale: `desired`, else `share` of an equal share, but at least `count` (a count alone) while that is
    /// under 95% of one.
    static func floor(desired: CGFloat, count: CGFloat, free: CGFloat, sections n: Int) -> CGFloat {
        guard n > 0, free > 0 else { return 0 }
        let equal = free / CGFloat(n)
        return max(0, min(desired, max(share * equal, min(count, 0.95 * equal))))
    }

    /// The units of the scale: each section alone, a quiet segment's sections (`runs`, indices in order) together.
    static func units(count n: Int, runs: [[Int]]) -> [[Int]] {
        var out: [[Int]] = [], i = 0
        while i < n {
            if let run = runs.first(where: { $0.first == i }), !run.isEmpty {
                out.append(run)
                i = (run.last ?? i) + 1
            } else {
                out.append([i])
                i += 1
            }
        }
        return out
    }

    /// Each section's width drawn, for its width at the page scale `w` and its kind, every unit (a section, or a quiet
    /// segment's `runs` as one) at least `floor` wide (`floor(…)`; never more than 95% of an equal share, so the row
    /// can keep its width): the sum is unchanged.
    static func widths(_ w: [CGFloat], _ kinds: [Kind], runs: [[Int]] = [], floor: CGFloat) -> [CGFloat] {
        let w = w.map { max(0, $0) }
        let groups = units(count: w.count, runs: runs).filter { $0.allSatisfy { kinds[$0] == .section } }
        let u = groups.map { g in g.reduce(0) { $0 + w[$1] } }
        let free = u.reduce(0, +)
        guard !u.isEmpty, free > 0 else { return w }
        let m = min(floor, 0.95 * free / CGFloat(u.count))
        // the units under the floor at the scale s are the k shortest: find the k whose s keeps exactly them under it
        let order = u.indices.sorted { u[$0] < u[$1] }
        var rest = free, s: CGFloat = 1
        for k in 0...order.count {
            if k > 0 { rest -= u[order[k - 1]] }
            guard rest > 0 else { break }
            let t = (free - CGFloat(k) * m) / rest
            let below = k == 0 || t * u[order[k - 1]] <= m + 1e-9
            let above = k == order.count || t * u[order[k]] >= m - 1e-9
            if below && above {
                s = min(1, t)
                break
            }
        }
        var out = w
        for (g, len) in zip(groups, u) {
            let d = max(m, s * len)
            for i in g { out[i] = len > 0 ? d * w[i] / len : d / CGFloat(g.count) }
        }
        return out
    }
}

/// Where a row draws its places: each section from its drawn start to its drawn end (`MapScale`), and every place in
/// it (ticks, path dots, the bands' ends, the lens's lines, the page axis) at its proportion of the section's length.
struct RowScale: Equatable {
    /// (place at the page scale, place drawn), increasing.
    var breaks: [CGPoint] = []

    static let identity = RowScale()

    /// `cells`: each unit's start and end at the page scale, in order; `drawn`: its width as drawn (`MapScale.widths`).
    static func make(_ cells: [(CGFloat, CGFloat)], drawn: [CGFloat]) -> RowScale {
        let n = cells.count
        guard n > 0, drawn.count == n else { return .identity }
        guard (0..<n).contains(where: { abs(drawn[$0] - max(0, cells[$0].1 - cells[$0].0)) > 0.001 }) else { return .identity }
        var out = RowScale()
        var x = cells[0].0
        for i in 0..<n {
            if i > 0 { x += cells[i].0 - cells[i - 1].1 }  // a gap between two sections stays as it is
            out.breaks.append(CGPoint(x: cells[i].0, y: x))
            x += drawn[i]
            out.breaks.append(CGPoint(x: cells[i].1, y: x))
        }
        return out
    }

    func x(_ t: CGFloat) -> CGFloat {
        guard let first = breaks.first, let last = breaks.last else { return t }
        if t <= first.x { return t + (first.y - first.x) }
        if t >= last.x { return t + (last.y - last.x) }
        for k in 1..<breaks.count where t <= breaks[k].x {
            let a = breaks[k - 1], b = breaks[k]
            return b.x - a.x < 0.0001 ? b.y : a.y + (t - a.x) * (b.y - a.y) / (b.x - a.x)
        }
        return t
    }
}

/// Labels in the gaps between rows (moved, merged into …, renamed, split, removed, added): each where it collides with
/// nothing placed before it nor with a removed band's point (but its own), centred over its band, else beside it with
/// a short leader, else a little lower; a label of several words that fits nowhere tries its first word, and one that
/// fits nowhere is left out (`MapScene.build` then says the gap's changes in one label). Inside the map, never past the
/// unplaced caps.
struct LabelPlacer {
    var occupied: [CGRect] = []
    /// A removed band's point between two rounds: its base on the older row, its tip under the newer one.
    struct Point {
        var id: Int
        var left: CGFloat
        var right: CGFloat
        var base: CGFloat
        var tip: CGPoint

        /// The box crosses the triangle (where it is widest within the box's height).
        func crosses(_ b: CGRect) -> Bool {
            guard b.maxY > tip.y, b.minY < base, base > tip.y else { return false }
            let y = min(b.maxY, base), hw = (right - left) / 2 * (y - tip.y) / (base - tip.y)
            return b.minX < tip.x + hw && b.maxX > tip.x - hw
        }
    }
    var points: [Point] = []
    let minX: CGFloat
    let maxX: CGFloat

    init(geometry g: MapGeometry) {
        minX = MapGeometry.mapX + 2
        maxX = g.mapRight + 16
    }

    mutating func take(_ r: CGRect) { occupied.append(r) }

    func free(_ r: CGRect, own: Int? = nil) -> Bool {
        r.minX >= minX && r.maxX <= maxX && !occupied.contains { $0.insetBy(dx: -3, dy: 0).intersects(r) }
            && !points.contains { $0.id != own && $0.crosses(r.insetBy(dx: -2, dy: 0)) }
    }

    /// The text placed, and its leader (from, to) when it sits beside its band.
    struct Placed: Equatable {
        var text: MapText
        var leader: (CGPoint, CGPoint)?

        static func == (a: Placed, b: Placed) -> Bool {
            a.text == b.text && a.leader?.0 == b.leader?.0 && a.leader?.1 == b.leader?.1
        }
    }

    /// nil when nothing is free (never drawn where it clashes); `own`: the removed band's point the label is for.
    mutating func place(_ s: String, left l: CGFloat, right r: CGFloat, baseline ym: CGFloat, opacity: Double,
                        own: Int? = nil, shorten: Bool = true) -> Placed? {
        let font = MapFont.smallRegular, w = font.width(s) + 4, mx = (l + r) / 2  // 11 Regular (VISUAL §4.4)
        let top = ym - font.ascent, h = font.ascent + font.descent
        var cands: [(CGFloat, CGFloat)] = [(mx - w / 2, 0), (r + 9, 0), (l - 9 - w, 0), (mx - w / 2, -4), (r + 9, 4), (l - 9 - w, 4)]
        for step in 1...16 {
            let d = CGFloat(step) * 12
            cands += [(mx - w / 2 + d, 0), (mx - w / 2 - d, 0)]
        }
        for (x, dy) in cands {
            let box = CGRect(x: x, y: top + dy, width: w, height: h)
            guard free(box, own: own) else { continue }
            let y = ym - 4 + dy
            // beside its band: a short leader from the band's edge (from the edge of the band's pill when it sticks out
            // past the band), which crosses no other label or pill
            var lead: (CGPoint, CGPoint)?
            if box.minX > r {
                var a = r + 1
                while let o = occupied.first(where: { $0.minX <= a && $0.maxX >= a && $0.minY <= y && $0.maxY >= y }) { a = o.maxX + 1 }
                if a < box.minX - 4 { lead = (CGPoint(x: a, y: y), CGPoint(x: box.minX - 2, y: y)) }
            } else if box.maxX < l {
                var b = l - 1
                while let o = occupied.first(where: { $0.minX <= b && $0.maxX >= b && $0.minY <= y && $0.maxY >= y }) { b = o.minX - 1 }
                if b > box.maxX + 4 { lead = (CGPoint(x: box.maxX + 2, y: y), CGPoint(x: b, y: y)) }
            }
            let line = lead.map { CGRect(x: min($0.0.x, $0.1.x), y: y - 1, width: abs($0.1.x - $0.0.x), height: 2) }
            if let line, occupied.contains(where: { $0.intersects(line) }) { continue }
            take(box)
            if let line { take(line) }
            let t = MapText(text: s, x: x + 2, baseline: ym + dy, font: font, ink: .secondary, opacity: opacity, halo: .content)
            return Placed(text: t, leader: lead)
        }
        if shorten, let first = s.split(separator: " ").first, first.count < s.count {
            return place(String(first), left: l, right: r, baseline: ym, opacity: opacity, own: own)
        }
        return nil
    }

    /// One gap's labels: each placed (those of what is followed first); when one of those in full could not be, none
    /// of the gap's but one that says them all ("9 renamed", "2 moved · 1 renamed"), over all their bands, else none.
    /// A label that steps back (another section is followed) and finds no place is just left out.
    mutating func placeGap(_ labels: [MapScene.GapLabel]) -> [Placed] {
        let before = self
        var out: [Placed] = []
        var missing = false
        for g in labels.filter({ $0.opacity == 1 }) + labels.filter({ $0.opacity != 1 }) {
            if let p = place(g.text, left: g.left, right: g.right, baseline: g.baseline, opacity: g.opacity, own: g.own) {
                out.append(p)
            } else if g.opacity == 1 {
                missing = true
            }
        }
        guard missing, let first = labels.first else { return out }
        self = before
        let kinds = ["moved", "renamed", "merged", "split", "removed", "added"]
        let text = kinds.compactMap { k -> String? in
            let n = labels.filter { $0.kind == k }.count
            return n > 0 ? "\(n) \(k)" : nil
        }.joined(separator: " · ")
        let l = labels.map(\.left).min() ?? first.left, r = labels.map(\.right).max() ?? first.right
        let o = labels.map(\.opacity).max() ?? 1
        for t in [text, "\(labels.count) changed"] {
            if let p = place(t, left: l, right: r, baseline: first.baseline, opacity: o, shorten: false) { return [p] }
        }
        return []
    }
}

/// Everything the map draws, in drawing order, and what is under each place a click can land on.
struct MapScene {
    struct Cell: Equatable {
        var section: String
        var round: Int
        var rect: CGRect
        var level: Int
        var count: Int
        var number: MapText?
        var name: MapText?
        var dim = false
        var selected = false
        /// A folded part's block (VISUAL v3 §5): the sections in it, its count their total, its name the part's label.
        var fold: FoldKind?
        var sections: [String] = []
        /// Drawn as part of a quiet segment (`Row.quiet`), with no fill of its own.
        var quiet = false
        /// Its comments still to check (the open round only), and whether it is outlined in vermilion for them: not
        /// while nothing in the round is answered, when the round's ring says it once (UI v4, plan §5 R1).
        var toCheck = 0
        var outlined = false
    }

    struct Tick: Equatable {
        var id: String
        var round: Int
        var x: CGFloat
        var top: CGFloat
        var unrequested: Bool
        var toCheck: Bool
        var dim = false
        /// Made for the comment followed (§5.1): drawn stronger.
        var strong = false
    }

    struct Band: Equatable {
        var round: Int
        var from: String?
        var to: String?
        var kind: String
        var points: [CGPoint]
        var changed: Bool
        var selected = false
        var hollow = false
        var dim = false
        /// From a folded part's block to its block a round below.
        var fold: FoldKind?
    }

    /// Neighbouring sections without comments, each too narrow for a cell of its own (VISUAL §6.1): one quiet track,
    /// though a click and the keys still go section by section.
    struct Quiet: Equatable {
        var rect: CGRect
        var sections: [String]
        /// Its sections' names in the name ink, as far as they fit (`quietName`); none only when not a letter fits.
        var name: MapText?
        /// Every section in it is dimmed (another followed).
        var dim = false
    }

    /// A quiet segment's name in `room`: each section's name in an equal share, joined by " · " ("Rel. · Disc."; none
    /// a lone letter), else the first's and the number of the others ("Related +1"), else the first's as it fits.
    static func quietName(_ parts: [SectionName?], room: CGFloat) -> String? {
        guard let first = parts.first ?? nil else { return nil }
        let sep = " · ", f = MapFont.name
        if parts.count > 1 {
            let share = (room - CGFloat(parts.count - 1) * f.width(sep)) / CGFloat(parts.count)
            let each = parts.map { p in p?.fit(f, share).flatMap { MapRules.isLetter($0) ? nil : $0 } }
            if each.allSatisfy({ $0 != nil }) { return each.compactMap { $0 }.joined(separator: sep) }
            let more = " +\(parts.count - 1)"
            if let t = first.fit(f, room - f.width(more)), !MapRules.isLetter(t) { return t + more }
        }
        return first.fit(f, room)
    }

    struct Row: Equatable {
        var n: Int
        var y: CGFloat
        /// The open round's vermilion ring before its name while it has something to check, and its fill (the share
        /// answered); nil without one (UI v4: no rail).
        var ring: Double?
        /// "Round 2" over the day it came in ("Oct 28"); its return and its counts are in its help tag.
        var title: MapText
        var dates: MapText
        /// Every row but the top one: drawn from the older rounds' ramp, its text never faded (UI v4).
        var old = false
        var carried: MapText?
        var cells: [Cell] = []
        var quiet: [Quiet] = []
        var ticks: [Tick] = []
        /// Pages only (§5.5): the row's track, the gaps between its pages, its comment dots and its caption.
        var pages: CGRect?
        var pageLines: [CGFloat] = []
        var dots: [CGPoint] = []
        var caption: MapText?
        /// The build failed: a dashed outline and its words.
        var failed: CGRect?
        var failedText: MapText?
        var endcap: CGFloat?
        var endText: MapText?
        var unplaced: CGRect?
        var unplacedLevel = 0
        var unplacedText: MapText?
        var unplacedCaption: MapText?
        var readout: [MapText] = []
        var sage: MapText?
        var dim = false

    }

    struct PathPoint: Equatable {
        enum Glyph: Equatable { case written, carried, toCheck, resolved, kept, gone, unplaced, folded }
        var round: Int
        var at: CGPoint
        var glyph: Glyph
        var small = false
    }

    struct Path: Equatable {
        var comment: String
        var points: [PathPoint]
        var thin = false
    }

    struct Fold: Equatable {
        var rect: CGRect
        var title: MapText
        var text: MapText
        var link: MapText
    }

    /// A folded part on the page axis (VISUAL §5.1 with the critique's fix: the toggle has one home): folded, its
    /// pages under its block and Show; shown, a bracket under its pages with its name, its pages and Fold.
    struct AxisPart: Equatable {
        var kind: FoldKind
        var shown: Bool
        var text: MapText
        var link: MapText
        /// The bracket under the shown part: from, to, at.
        var bracket: [CGFloat] = []
        /// The chevron before a shown part's name (pointing down).
        var chevron: CGPoint?
    }

    struct Hit: Equatable {
        var target: MapTarget
        var rect: CGRect
        var polygon: [CGPoint]?
    }

    /// A structure label waiting for its place in a gap: its words, its kind (for the gap's one label when they do not
    /// all fit), its band's ends, its baseline, whether it steps back, and the removed band's point it is for.
    struct GapLabel {
        var text: String
        var kind: String
        var left: CGFloat
        var right: CGFloat
        var baseline: CGFloat
        var opacity: Double
        var own: Int?
    }

    var geometry: MapGeometry
    var height: CGFloat
    var steps: [Int]
    /// New with every scene built: the Canvas draws again only for a new scene (not while the pointer moves).
    var stamp = UUID()
    /// What the paper folds at this width, and each round's map of pages.
    var plan = FoldPlan(k: 1)
    var pageMaps: [Int: PageMap] = [:]
    /// The lens's makings (`Lens`): drawn for the strip's scroll offset by `lens(offset:)`, so the strip's scroll redraws
    /// the lens alone.
    var lensInput: Lens?
    var captions: [MapText] = []
    var sageCaption: MapText?
    var bands: [Band] = []
    var carriedPills: [(CGRect, MapText)] = []
    var rows: [Row] = []
    var fold: Fold?
    var pageBand: CGRect?
    var paths: [Path] = []
    var labels: [LabelPlacer.Placed] = []
    var axis: [MapText] = []
    var axisParts: [AxisPart] = []
    var foldLink: MapText?
    var hits: [Hit] = []
    /// The selected round's box behind its label (the strip's round, or the one previewed; UI v4, BRIEF §8.3): nil
    /// while its row is folded away. `PaperMapView` draws it under the Canvas and slides it to a new round;
    /// `boxFollowed`: the round is followed (the accent's tint and a Sage outline; a preview has neither).
    var box: CGRect?
    var boxFollowed = false
    /// The rounds folded under the shown ones.
    var folded: [Int] = []
    /// The rounds shown, top to bottom, and how each row places its points (`RowScale`): a comment's previewed path
    /// goes through the same places as a followed one.
    var shownRounds: [Int] = []
    var scales: [Int: RowScale] = [:]
    /// Each section's name as the map has it (`SectionName`), by `nameID`: the section ruler and the names over a
    /// hovered row read it with the same stem.
    var names: [String: SectionName] = [:]

    /// A section's names on the map: its forms (`MapRules.labels`), the one it has in its narrowest cell in any round
    /// (`base`: every cell shows it or a longer form of its stem; nil when nothing fits there) and its fixed short form.
    struct SectionName: Equatable {
        var forms: [String]
        var base: String?
        var fixed: String?
        /// The other sections' names (`base`, not a lone letter): a longer form that reads as one of them is not
        /// shown ("Ab." for Ablation as Sensitivity Probe, named "A." where the abstract is "Ab.").
        var avoid: [String] = []
        /// Every form that fits its narrowest cell is another section's name, case and "." aside: it has no short
        /// name, only its whole name or fixed short form where one fits (the UI audit of 2026-10-24: Abstract and
        /// Analysis were both "A." in one row).
        var nameless = false

        /// The longest form that fits `room` in `font` with the same stem (`MapRules.pick`); a nameless section's own.
        func fit(_ font: MapFont, _ room: CGFloat) -> String? {
            if nameless { return [forms.first, fixed].compactMap { $0 }.first { font.width($0) <= room } }
            return MapRules.pick(forms, base: base, font, room, fixed: fixed, avoid: avoid)
        }
    }

    /// A section's key and title, as one id (a section renamed between rounds has a name for each title).
    static func nameID(_ key: String, _ title: String) -> String { key + "\u{1}" + title }

    /// A place of round `n` on the map: through its map of pages, then its row's scale.
    func x(_ n: Int, _ pos: Double) -> CGFloat {
        let p = pageMaps[n]?.x(pos) ?? geometry.x(pos)
        return scales[n]?.x(p) ?? p
    }

    /// A comment's path as the hover previews it (OVERVIEW-v2 §5.1 "悬停一条意见，地图上用虚线预览它的路径", the mockup's
    /// `previewPath`): a point in each shown row it is in, where it is there (the unplaced cap when the round could not
    /// place it), oldest first, after a point on the fold for the rounds folded. No point moves for a count: the preview
    /// is gone with the pointer.
    func previewPoints(_ c: PaperOverview.Comment) -> [CGPoint] {
        var pts: [CGPoint] = []
        for st in c.path {
            guard let i = shownRounds.firstIndex(of: st.round), rows.indices.contains(i), rows[i].failed == nil else { continue }
            let yc = geometry.rowY(i) + MapGeometry.cell / 2
            if st.state == "unplaced" {
                if geometry.capWidth > 0 { pts.append(CGPoint(x: geometry.mapRight + 10 + (geometry.capWidth - 12) / 2, y: yc)) }
            } else if let pos = st.pos {
                pts.append(CGPoint(x: x(st.round, pos), y: yc))
            }
        }
        if let st = c.path.last(where: { folded.contains($0.round) }), let pos = st.pos ?? st.page.map(Double.init) {
            pts.insert(CGPoint(x: pageMaps[st.round]?.x(pos) ?? geometry.x(pos), y: geometry.rowY(shownRounds.count) + 11), at: 0)
        }
        return pts
    }

    /// The section names over round `n`'s row while the pointer is on it (the hover layer): each from its cell's start,
    /// with the map's stem (`names`), as far as the next name, as much of it as fits there (`MapRules.label`), so no
    /// two touch; one that a structure label, its leader or a "carried" pill is in the way of goes on a line of its own
    /// above. The cell's help tag still names it.
    func hoverNames(_ n: Int, _ d: PaperOverview) -> [MapText] {
        guard let row = rows.first(where: { $0.n == n }), !row.cells.isEmpty else { return [] }
        let leaders = labels.compactMap { l in l.leader.map { CGRect(x: min($0.0.x, $0.1.x), y: $0.0.y - 1, width: abs($0.1.x - $0.0.x), height: 2) } }
        let obstacles = labels.map(\.text.rect) + leaders + carriedPills.map(\.0)
        let font = MapFont.caption
        var out: [MapText] = []
        var end = -CGFloat.infinity, endAbove = -CGFloat.infinity
        for (j, c) in row.cells.enumerated() where c.fold == nil {
            let limit = j + 1 < row.cells.count ? row.cells[j + 1].rect.minX + 2 : c.rect.maxX + 60
            let title = d.sectionTitle(c.section, round: n) ?? c.section
            let name = names[Self.nameID(c.section, title)]
            func fit(_ room: CGFloat) -> String? {
                // a nameless section (its cells show only its own name) as much of its name as fits, as any other here
                if let name, name.nameless { return name.forms.first { font.width($0) <= room } }
                return name?.fit(font, room) ?? MapRules.label(d.shortTitle(c.section, title), font, room)
            }
            func clear(_ t: MapText) -> Bool { !obstacles.contains { $0.intersects(t.rect.insetBy(dx: -1.5, dy: -1)) } }
            let a = max(c.rect.minX + 2, end + 6)
            if let t = fit(limit - a - 4).map({ MapText(text: $0, x: a, baseline: row.y - 4, font: font, ink: .label, halo: .content) }),
               clear(t) {
                end = t.rect.maxX
                out.append(t)
                continue
            }
            // else on a line above
            let b = max(c.rect.minX + 2, endAbove + 6)
            if let t = fit(limit - b - 4).map({ MapText(text: $0, x: b, baseline: row.y - 24, font: font, ink: .label, halo: .content) }),
               clear(t) {
                endAbove = t.rect.maxX
                out.append(t)
            }
        }
        return out
    }

    /// The quiet segment a section is drawn in, in round `n`.
    func quiet(_ section: String, round n: Int) -> Quiet? {
        rows.first { $0.n == n }?.quiet.first { $0.sections.contains(section) }
    }

    /// The round whose row is at `y`, for the preview under the pointer: its band from 10 pt over its cells to 10 pt
    /// over the next row's (its label, its cells, its readout, its "carried" line); nil over the lens, the axis and the
    /// rounds folded away.
    func round(atY y: CGFloat) -> Int? {
        rows.first { y >= $0.y - 10 && y < $0.y - 10 + MapGeometry.pitch }?.n
    }

    /// Over the first row's band: the lens, between the strip's ruler and the rows (the pointer on its way to the
    /// strip's pages keeps the round previewed).
    func overLens(_ y: CGFloat) -> Bool { y < (rows.first?.y ?? MapGeometry.row0) - 10 }

    /// What a click at `p` lands on: the last hit drawn there (path dots and ticks over cells, cells over bands).
    func target(at p: CGPoint) -> MapTarget? {
        for h in hits.reversed() {
            if let poly = h.polygon {
                if h.rect.contains(p) && Self.inside(p, poly) { return h.target }
            } else if h.rect.contains(p) {
                return h.target
            }
        }
        return nil
    }

    static func inside(_ p: CGPoint, _ poly: [CGPoint]) -> Bool {
        var c = false
        var j = poly.count - 1
        for i in poly.indices {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y) && p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { c.toggle() }
            j = i
        }
        return c
    }
}

/// What the map needs besides the engine's overview: the overview's width, the rounds folded, the strip's round (and
/// the one previewed under the pointer), what is followed, the student's first name, the failed round's errors, whether the open round can be finished,
/// whether long parts fold (Settings) and which the viewer has shown, and whether the strip is shown.
struct MapInput {
    var data: PaperOverview
    var width: CGFloat
    var fold: Int = 0
    var unfold = false
    var strip: Int?
    /// The round previewed under the pointer (`OverviewModel.preview`): the box and the lens show it; the page axis
    /// keeps the strip's round (its parts' pages, Show and Fold, its numbers), so nothing under the map moves while the
    /// pointer does.
    var preview: Int?
    var selection: OverviewItem?
    var student = ""
    var buildErrors: String?
    var readyToFinish = false
    var foldParts = true
    var shownParts: Set<FoldKind> = []
    /// The page strip is shown over the map (not for a folder that is not there): the axis does not number the pages.
    var stripShown = true
    /// The thumbnails' size of the round the strip shows (`StripGeometry.thumbSize`), for the lens.
    var stripThumb = StripGeometry.letterThumb
}

extension MapScene {
    /// A row's unit on the map: a section, or a folded part's block (its first section's key, its sections).
    struct Unit {
        var key: String
        var start: Double
        var end: Double
        var fold: FoldKind?
        var sections: [String]
        var title: String
    }

    /// The units of a round with sections: each section, a folded part's sections as one block.
    static func units(_ r: PaperOverview.Round, folded: [FoldKind]) -> [Unit] {
        let spans = r.spans ?? []
        let ranges = MapFold.ranges(spans).filter { folded.contains($0.kind) }
        var out: [Unit] = []
        for (i, sp) in spans.enumerated() {
            if let f = ranges.first(where: { $0.spans.contains(i) }) {
                if i == f.spans.lowerBound {
                    out.append(Unit(key: sp.section, start: f.start, end: f.end, fold: f.kind, sections: spans[f.spans].map(\.section),
                                    title: MapFold.label(f.kind, spans[f.spans], short: false)))
                }
                continue
            }
            out.append(Unit(key: sp.section, start: sp.start, end: sp.end, fold: nil, sections: [sp.section], title: sp.title))
        }
        return out
    }

    /// A block's least width for its words: 7 pt, its label, its largest count over the rounds, 7 pt, and the cell's
    /// 1 pt in from each end.
    static func blockLabelWidth(_ d: PaperOverview, _ kind: FoldKind, short: Bool) -> CGFloat {
        var text: CGFloat = 0, most = 0
        for r in d.rounds where r.hasSections && !r.failed {
            let spans = r.spans ?? []
            guard let range = MapFold.ranges(spans).first(where: { $0.kind == kind }) else { continue }
            text = max(text, MapFont.name.width(MapFold.label(kind, spans[range.spans], short: short)))
            let heat = Dictionary((r.heat ?? []).map { ($0.section, $0.present) }, uniquingKeysWith: { a, _ in a })
            most = max(most, spans[range.spans].reduce(0) { $0 + (heat[$1.section] ?? 0) })
        }
        return 2 + 7 + text + (most > 0 ? 8 + MapFont.number.width("\(most)") + 1 : 0) + 7 + 1
    }

    /// The floors a row's sections are drawn at (`MapScale`), for the paper's largest count in a section: `label`, a
    /// short name ("Abc.") and that count (two digits at most) in a narrow cell's spacing, 1 pt in from each end, and
    /// half a point to spare; `count`,
    /// the count alone with 3 pt either side.
    static func floorWidths(most: Int) -> (label: CGFloat, count: CGFloat) {
        let cw = most > 0 ? MapFont.number.width("\(min(most, 99))") + 1 : 0
        let sp = MapRules.CellSpacing.tight
        return (2 + 2 * sp.pad + MapFont.name.width("Abc.") + (cw > 0 ? sp.gap + cw : 0) + 0.5, cw > 0 ? 2 + 6 + cw : 0)
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    static func build(_ input: MapInput) -> MapScene {
        let d = input.data
        let maxPages = Double(d.rounds.compactMap { $0.build?.pages }.max() ?? 1)
        let all = Array(d.rounds.reversed())
        let foldN = input.unfold ? 0 : min(input.fold, max(0, all.count - 1))
        let shown = Array(all.prefix(all.count - foldN)), folded = Array(all.suffix(foldN))
        let first = d.rounds.first?.n
        var g = MapGeometry(width: input.width, maxPages: maxPages,
                            unplaced: d.rounds.contains { ($0.unplaced ?? Self.unplacedCount(d, $0.n)) > 0 },
                            you: shown.contains { hasAnswers($0, first: $0.n == first) })
        // the parts the paper folds at this width (VISUAL §5), and the page scale they leave
        let plan = FoldPlan.make(d, mapWidth: g.mapWidth, maxPages: maxPages, enabled: input.foldParts, shown: input.shownParts,
                                 label: { blockLabelWidth(d, $0, short: $1) })
        g.k = plan.k
        var s = MapScene(geometry: g, height: 0, steps: MapShade.steps(MapShade.counts(d)))
        s.plan = plan
        s.folded = folded.map(\.n)
        let scope = Scope(input.selection, d)
        let held = d.round(input.strip ?? MapRules.defaultStrip(d) ?? 0)
        let strip = input.preview.flatMap(d.round) ?? held
        // each round's map of pages: its own folded parts' blocks; a row without sections takes the nearest round's
        let sectioned = d.rounds.filter { $0.hasSections && !$0.failed }
        for r in d.rounds {
            let ref = r.hasSections && !r.failed ? r : sectioned.min { abs($0.n - r.n) < abs($1.n - r.n) }
            s.pageMaps[r.n] = plan.pageMap(ref, x0: MapGeometry.mapX)
        }
        let maps = s.pageMaps
        func P(_ n: Int, _ pos: Double) -> CGFloat { maps[n]?.x(pos) ?? g.x(pos) }
        // each shown row's units: a block as wide as the plan made it, every section and quiet segment (VISUAL §6.1:
        // neighbouring empty sections each under 24 pt at the page scale, drawn as one track) at least the floor that
        // holds a short name and its count (`MapScale`)
        var rowUnits: [Int: [Unit]] = [:]
        var heats: [Int: [String: PaperOverview.Heat]] = [:]
        var scales: [Int: RowScale] = [:]
        for r in shown where r.hasSections && !r.failed {
            heats[r.n] = Dictionary((r.heat ?? []).map { ($0.section, $0) }, uniquingKeysWith: { a, _ in a })
            rowUnits[r.n] = units(r, folded: plan.folded)
        }
        func total(_ n: Int, _ u: Unit) -> Int { u.sections.reduce(0) { $0 + (heats[n]?[$1]?.present ?? 0) } }
        var quietRuns: [Int: [[Int]]] = [:]
        for (n, us) in rowUnits {
            var runs: [[Int]] = [], run: [Int] = []
            for (j, u) in us.enumerated() {
                let narrow = u.fold == nil && total(n, u) == 0 && P(n, u.end) - P(n, u.start) < 24
                let touching = run.last.map { abs(us[$0].end - u.start) < 0.01 } ?? true
                if narrow && touching { run.append(j) } else {
                    if run.count > 1 { runs.append(run) }
                    run = narrow ? [j] : []
                }
            }
            if run.count > 1 { runs.append(run) }
            quietRuns[n] = runs
        }
        let most = rowUnits.flatMap { n, us in us.filter { $0.fold == nil }.map { total(n, $0) } }.max() ?? 0
        let floor = Self.floorWidths(most: most)
        for (n, us) in rowUnits {
            let runs = quietRuns[n] ?? []
            let base = us.map { P(n, $0.end) - P(n, $0.start) }
            let kinds: [MapScale.Kind] = us.map { $0.fold != nil ? .fixed : .section }
            let free = us.indices.filter { kinds[$0] == .section }.reduce(0) { $0 + base[$1] }
            let pieces = MapScale.units(count: us.count, runs: runs).filter { $0.allSatisfy { kinds[$0] == .section } }.count
            let m = MapScale.floor(desired: floor.label, count: floor.count, free: free, sections: pieces)
            scales[n] = RowScale.make(us.map { (P(n, $0.start), P(n, $0.end)) }, drawn: MapScale.widths(base, kinds, runs: runs, floor: m))
        }
        func X(_ n: Int, _ pos: Double) -> CGFloat { scales[n]?.x(P(n, pos)) ?? P(n, pos) }
        s.scales = scales
        s.shownRounds = shown.map(\.n)
        // one name for a section in every row, cut to the narrowest room it has in any (beside its count), so it reads
        // the same down the rounds ("Bench." in each, not "Bench.", "Ben." and "Be."), a wider cell a longer form of
        // the same stem ("Bench." where "Ben." is the narrowest's: the UI audit of 2026-10-21); when not even a letter
        // fits the narrowest, each cell as much as fits it; and no cut name that reads as another section's while
        // another of its forms fits (`MapRules.clash`: "Abs." for the abstract, then "ASP", not "Abst.", for
        // Ablation as Sensitivity Probe), and never another's very name ("A." twice: its whole name only, where
        // it fits), the rows from the top, each from the left. A lettered appendix section's names lead with its
        // letter ("C Exp.").
        var letters: [Int: [String: String]] = [:]  // round → a lettered appendix section's key → its letter
        for r in shown where r.hasSections && !r.failed {
            let spans = r.spans ?? []
            for f in MapFold.ranges(spans) where f.kind == .appendix {
                for i in f.spans { if let l = MapFold.letter(spans[i].title) { letters[r.n, default: [:]][spans[i].section] = l } }
            }
        }
        var forms: [String: (forms: [String], fixed: String?)] = [:]
        func ladder(_ n: Int, _ u: Unit) -> (forms: [String], fixed: String?) {
            let id = nameID(u.key, u.title)
            if let f = forms[id] { return f }
            let short = d.shortTitle(u.key, u.title), letter = letters[n]?[u.key]
            let fixed = MapRules.abbreviations[short.lowercased()].map { a in letter.map { $0 + " " + a } ?? a }
            let f = (MapRules.labels(short, letter: letter), fixed)
            forms[id] = f
            return f
        }
        var nameRoom: [String: CGFloat] = [:]
        for (n, us) in rowUnits {
            let quiet = Set((quietRuns[n] ?? []).flatMap { $0 })
            for (j, u) in us.enumerated() where u.fold == nil && !quiet.contains(j) {
                let c = total(n, u), cw = c > 0 ? MapFont.number.width("\(c)") + 1 : 0
                let room = MapRules.CellSpacing.tight.room(X(n, u.end) - X(n, u.start) - 2, count: cw)
                nameRoom[u.key] = min(nameRoom[u.key] ?? room, room)
            }
        }
        var names: [String: String] = [:]
        var nameless: Set<String> = []
        var taken: [(key: String, name: String)] = []
        for r in shown {
            for u in rowUnits[r.n] ?? [] where u.fold == nil {
                let id = nameID(u.key, u.title)
                guard names[id] == nil, !nameless.contains(id), let room = nameRoom[u.key] else { continue }
                let f = ladder(r.n, u)
                let fits = f.forms.filter { MapFont.name.width($0) <= room }
                let own = Set([f.forms.first, f.fixed].compactMap { $0 })
                let others = taken.filter { $0.key != u.key }.map(\.name)
                func free(_ t: String) -> Bool { !others.contains { MapRules.clash(t, $0) } }
                // every form that fits reads as another's: its initials, when they fit and read as none
                let escape = MapRules.initials(d.shortTitle(u.key, u.title)).flatMap { t in
                    MapFont.name.width(t) <= room && free(t) && letters[r.n]?[u.key] == nil ? t : nil
                }
                // else the first that is not another's very name, case and "." aside ("A." beside the abstract's "Ab." as
                // before; the UI audit of 2026-10-24: Abstract and Analysis both "A."); none: no short name at all
                func same(_ t: String) -> Bool { others.contains { MapRules.bare($0) == MapRules.bare(t) } }
                guard let pick = fits.first(where: { t in own.contains(t) || free(t) }) ?? escape ?? fits.first(where: { !same($0) }) else {
                    if !fits.isEmpty { nameless.insert(id) }
                    continue
                }
                names[id] = pick
                taken.append((u.key, pick))
            }
        }
        for (n, us) in rowUnits {
            for u in us where u.fold == nil {
                var f = ladder(n, u)
                let id = nameID(u.key, u.title), base = names[id]
                // initials taken as a way out are one of its forms, before its letters
                if let b = base, !f.forms.contains(b) { f.forms.insert(b, at: f.forms.firstIndex(where: MapRules.isLetter) ?? f.forms.count) }
                let avoid = taken.filter { $0.key != u.key && !MapRules.isLetter($0.name) }.map(\.name)
                s.names[id] = SectionName(forms: f.forms, base: base, fixed: f.fixed, avoid: avoid, nameless: nameless.contains(id))
            }
        }
        /// Whether a unit's side joins its quiet neighbour (no gap there).
        func joined(_ n: Int, _ j: Int, left: Bool) -> Bool {
            (quietRuns[n] ?? []).contains { run in run.contains(j) && (left ? run.first != j : run.last != j) }
        }
        func unitIndex(_ n: Int, _ key: String?) -> Int? {
            guard let key else { return nil }
            return rowUnits[n]?.firstIndex { $0.sections.contains(key) }
        }

        // the row the lens and the page axis follow: the strip's round when it is shown with sections, else the top row
        // with sections (the code audit: a strip round folded or without sections fell back to the plain page scale,
        // which no row is drawn at since each row has its own). The lens follows the round previewed; the page axis the
        // strip's own (`held`), so its parts' pages, Show and Fold and its numbers stay put under a preview (§40.9)
        let shownNs = Set(shown.map(\.n))
        func axisRow(_ r: PaperOverview.Round?) -> PaperOverview.Round? {
            r.flatMap { r in r.hasSections && !r.failed && shownNs.contains(r.n) ? r : nil } ?? shown.first { $0.hasSections && !$0.failed }
        }
        let ar = axisRow(strip), hr = axisRow(held)
        func HX(_ pos: Double) -> CGFloat { hr.map { X($0.n, pos) } ?? g.x(pos) }

        // the lens: from the strip's pages (the round shown, at its thumbnails' slots) to the map's row; drawn for the
        // strip's scroll offset (`lens(offset:)`)
        if let sr = strip, let pages = sr.build?.pages, pages > 0, !sr.failed {
            let ranges = sr.hasSections ? MapFold.ranges(sr.spans ?? []).filter { plan.folded.contains($0.kind) } : []
            var lens = Lens(strip: StripGeometry(width: g.width, pages: pages, thumb: input.stripThumb), axis: ar?.n,
                            ranges: ranges.map { ($0.start, $0.end) })
            if sr.hasSections {
                lens.starts = (sr.spans ?? []).map(\.start).filter { st in
                    st > 0.001 && !ranges.contains(where: { $0.contains(st) || abs($0.start - st) < 0.001 })
                }
            }
            if sr.hasSections, case .section(let key)? = scope.kind, let sp = sr.spans?.first(where: { $0.section == key }),
               maps[sr.n]?.block(at: (sp.start + sp.end) / 2) == nil {
                lens.followed = (sp.start, sp.end)
            }
            if case .page(let n, let p)? = scope.kind, n == sr.n { lens.followed = (Double(p), Double(p + 1)) }
            s.lensInput = lens
        }

        // the readout's captions; over them, a Sage one names what the Sage lines count
        for (j, c) in ["Comments", "You"].prefix(g.columns).enumerated() {
            s.captions.append(MapText(text: c, x: g.columnRight[j], baseline: MapGeometry.lens + 20, anchor: .end, font: .smallRegular,
                                      ink: .secondary))
        }
        if let label = scope.caption(d) {
            s.sageCaption = MapText(text: MapRules.fitParts([label], .label, g.readoutWidth - 12), x: g.readoutX + 10,
                                    baseline: MapGeometry.lens + 4, font: .label, ink: .accentText, halo: .content)
        }

        // the comments followed: each one's dots in each shown row, before the numbers are placed beside them
        var dotsIn: [Int: [CGFloat]] = [:]  // round → x; a cell takes those inside it
        for id in scope.comments {
            guard let c = d.comment(id) else { continue }
            for st in c.path where st.state != "unplaced" {
                guard let pos = st.pos, shown.contains(where: { $0.n == st.round }) else { continue }
                dotsIn[st.round, default: []].append(X(st.round, pos))
            }
        }

        var placer = LabelPlacer(geometry: g)
        var nudges: Set<String> = []
        var gaps: [[GapLabel]] = []

        // the bands between shown rounds, matched by their paragraphs; a folded part's block to its block
        for i in 0..<max(0, shown.count - 1) {
            let nw = shown[i], od = shown[i + 1]
            guard nw.hasSections, od.hasSections, let match = nw.match, od.n == nw.n - 1 else { continue }
            let yb = g.rowY(i) + MapGeometry.cell, yt = g.rowY(i + 1)
            let ym = yb + MapGeometry.rug + MapGeometry.gap / 2 + 4
            var splitDone: Set<String> = []
            var pills: [(CGRect, MapText)] = []
            var labels: [GapLabel] = []
            defer {
                gaps.append(labels)
                // two bands into one section (a merge) put their pills side by side, never one over the other
                for (r, t) in Self.spreadPills(pills, minX: MapGeometry.mapX + 2, maxX: g.mapRight) {
                    s.carriedPills.append((r, t))
                    placer.take(r)
                }
            }
            let nu = rowUnits[nw.n] ?? [], ou = rowUnits[od.n] ?? []
            for kind in plan.folded {
                guard let b = nu.first(where: { $0.fold == kind }), let a = ou.first(where: { $0.fold == kind }) else { continue }
                let pts = [CGPoint(x: X(nw.n, b.start) + 1, y: yb), CGPoint(x: X(nw.n, b.end) - 1, y: yb),
                           CGPoint(x: X(od.n, a.end) - 1, y: yt), CGPoint(x: X(od.n, a.start) + 1, y: yt)]
                var band = Band(round: nw.n, from: a.key, to: b.key, kind: "same", points: pts, changed: false, fold: kind)
                band.dim = scope.isScoped || scope.isRound
                s.bands.append(band)
                s.hits.append(Hit(target: .block(kind, round: nw.n), rect: bounds(pts), polygon: pts))
            }
            for m in match {
                let ia = unitIndex(od.n, m.from), ib = unitIndex(nw.n, m.to)
                let ua = ia.map { ou[$0] }, ub = ib.map { nu[$0] }
                // inside folded parts on both sides: the blocks' band says it
                if ua?.fold != nil && ub?.fold != nil { continue }
                let a = m.from.flatMap { k in od.spans?.first { $0.section == k } }
                let b = m.to.flatMap { k in nw.spans?.first { $0.section == k } }
                let on = scope.followsSection(m.to) || scope.followsSection(m.from)
                let dimLabel = scope.isScoped && !on ? 0.35 : 1
                if let a, let b {
                    let la = a.end - a.start, lb = b.end - b.start
                    let changed = m.kind != "same" || (la > 0 && abs(lb / la - 1) > 0.2)
                    // a section in a folded part: the band goes to its block
                    let (b0, b1) = ub?.fold != nil ? (ub!.start, ub!.end) : (b.start, b.end)
                    let (a0, a1) = ua?.fold != nil ? (ua!.start, ua!.end) : (a.start, a.end)
                    let bs = X(nw.n, b0), be = X(nw.n, b1), as_ = X(od.n, a0), ae = X(od.n, a1)
                    // 1 pt in from each end, so neighbouring bands keep 2 pt apart; none where quiet neighbours join
                    func inset(_ u: CGFloat, _ v: CGFloat, _ n: Int, _ j: Int?, left: Bool) -> CGFloat {
                        if let j, joined(n, j, left: left) { return 0 }
                        return min(1, (v - u) / 4)
                    }
                    let pts = [CGPoint(x: bs + inset(bs, be, nw.n, ib, left: true), y: yb), CGPoint(x: be - inset(bs, be, nw.n, ib, left: false), y: yb),
                               CGPoint(x: ae - inset(as_, ae, od.n, ia, left: false), y: yt), CGPoint(x: as_ + inset(as_, ae, od.n, ia, left: true), y: yt)]
                    let carried = on ? carriedOn(d, od.n, nw.n, m.from, m.to) : 0
                    let carriers = scope.held.isEmpty ? !scope.isTag : scope.held.contains { id in
                        guard let c = d.comment(id), let so = c.step(in: od.n), let sn = c.step(in: nw.n) else { return false }
                        return so.section == m.from && sn.section == m.to
                    }
                    var band = Band(round: nw.n, from: m.from, to: m.to, kind: m.kind, points: pts, changed: changed)
                    band.selected = on && carried > 0
                    band.hollow = on && carried == 0
                    band.dim = (scope.isSection && !on) || scope.isRound || (scope.followsComments && !carriers)
                    s.bands.append(band)
                    s.hits.append(Hit(target: .band(from: m.from, to: m.to, round: nw.n), rect: bounds(pts), polygon: pts))
                    if on && carried > 0 {
                        let mx = (pts[0].x + pts[1].x + pts[2].x + pts[3].x) / 4
                        let t = MapText(text: "\(carried) carried", x: mx, baseline: ym - 1, anchor: .middle, font: .small, ink: .accentText)
                        let w = t.width + 14
                        pills.append((CGRect(x: mx - w / 2, y: ym - 13, width: w, height: 17), t))
                    }
                    guard ua?.fold == nil && ub?.fold == nil else { continue }  // what happened inside a folded part is its own
                    let l = min(as_, bs), r = max(ae, be)
                    switch m.kind {
                    case "merged":
                        labels.append(GapLabel(text: "merged into " + d.shortTitle(b.section, b.title), kind: "merged", left: l, right: r,
                                               baseline: ym, opacity: dimLabel))
                    case "moved", "renamed":
                        labels.append(GapLabel(text: m.kind, kind: m.kind, left: l, right: r, baseline: ym, opacity: dimLabel))
                    case "split":
                        if let f = m.from, !splitDone.contains(f) {
                            splitDone.insert(f)
                            let both = match.filter { $0.from == f && $0.kind == "split" }.compactMap { x in nw.spans?.first { $0.section == x.to } }
                            let rr = max(r, both.map { X(nw.n, $0.end) }.max() ?? r), ll = min(l, both.map { X(nw.n, $0.start) }.min() ?? l)
                            labels.append(GapLabel(text: "split", kind: "split", left: ll, right: rr, baseline: ym, opacity: dimLabel))
                        }
                    default: break
                    }
                } else if let a, m.to == nil {
                    // removed: nothing of it is left; the band ends in a point
                    let (a0, a1) = ua?.fold != nil ? (ua!.start, ua!.end) : (a.start, a.end)
                    let as_ = X(od.n, a0), ae = X(od.n, a1), mx = (as_ + ae) / 2
                    let pts = [CGPoint(x: as_ + 1, y: yt), CGPoint(x: ae - 1, y: yt), CGPoint(x: mx, y: yb + MapGeometry.rug + 2)]
                    var band = Band(round: nw.n, from: m.from, to: nil, kind: "removed", points: pts, changed: true)
                    band.hollow = on
                    band.dim = scope.isScoped && !on
                    s.bands.append(band)
                    s.hits.append(Hit(target: .band(from: m.from, to: nil, round: nw.n), rect: bounds(pts), polygon: pts))
                    guard ua?.fold == nil else { continue }
                    // its point: other labels keep off it, its own sits over it
                    let id = placer.points.count
                    placer.points.append(.init(id: id, left: as_, right: ae, base: yt, tip: pts[2]))
                    labels.append(GapLabel(text: "removed", kind: "removed", left: as_, right: ae, baseline: ym, opacity: dimLabel, own: id))
                } else if let b, m.from == nil, ub?.fold == nil {
                    labels.append(GapLabel(text: "added", kind: "added", left: X(nw.n, b.start), right: X(nw.n, b.end), baseline: ym,
                                           opacity: dimLabel))
                }
            }
        }

        // the rows
        var rowEnds: [Int: CGFloat] = [:]
        for r in shown where !r.failed { rowEnds[r.n] = X(r.n, Double(r.build?.pages ?? Int(maxPages))) }
        let mapEnd = rowEnds.values.max() ?? g.mapRight
        for (i, r) in shown.enumerated() {
            let y = g.rowY(i), cy = y + MapGeometry.cell / 2
            let open = !r.isClosed && !r.failed
            let old = i > 0
            // the round's name over the day it came in, older rounds' in secondary; the open round's ring while it has
            // something to check, filled by what is answered (UI v4: no rail, no dots)
            var row = Row(n: r.n, y: y, ring: open ? ringFill(r) : nil,
                          title: MapText(text: "Round \(r.n)", x: Self.labelX, baseline: y + 12.5, font: .bodyBold,
                                         ink: old ? .secondary : .label),
                          dates: MapText(text: shortDate(r.created) ?? "", x: Self.labelX, baseline: y + 28.5,
                                         font: .smallRegular, ink: .secondary))
            row.old = old
            row.dim = scope.round.map { $0 != r.n } ?? false
            if r.n == strip?.n {
                s.box = CGRect(x: -10, y: y - 6, width: MapGeometry.box.width, height: MapGeometry.box.height)
                s.boxFollowed = scope.round == r.n
            }
            if i < shown.count - 1 || !folded.isEmpty {
                let n = r.failed ? waiting(d, r.n) : (r.comments?.carried ?? 0)
                // between this round's box and the next's
                row.carried = MapText(text: "↑ \(n) carried", x: Self.labelX, baseline: y + MapGeometry.cell + 19, font: .smallRegular,
                                      ink: .secondary, opacity: scope.isScoped ? 0.5 : 1)
            }
            let railHit = CGRect(x: 0, y: y - 6, width: MapGeometry.box.width - 10, height: MapGeometry.box.height)
            s.hits.append(Hit(target: .round(r.n), rect: railHit))

            // the readout: the round's own numbers, never re-scoped (§4.6)
            row.readout = readout(d, r, first: r.n == first, geometry: g, y: y, ready: input.readyToFinish && open, old: old)
            if scope.isScoped {
                let parts = scope.sageParts(d, r)
                if !parts.isEmpty {
                    row.sage = MapText(text: MapRules.fitParts(parts, .label, g.readoutWidth - 12), x: g.readoutX + 10,
                                       baseline: y + MapGeometry.cell + 14, font: .label, ink: .accentText)
                }
            }
            s.hits.append(Hit(target: .round(r.n), rect: CGRect(x: g.readoutX - 8, y: y - 3, width: g.readoutWidth + 8,
                                                                 height: MapGeometry.cell + MapGeometry.rug + 8)))

            if r.failed {
                row.failed = CGRect(x: g.x(0) + 0.5, y: y + 0.5, width: g.mapWidth - 1, height: MapGeometry.cell - 1)
                let n = waiting(d, r.n)
                let why = input.buildErrors.map { " · " + $0 + "." } ?? "."
                let words = "⚠ Build failed" + why + " " + waitWords(n) + "."
                row.failedText = MapText(text: MapRules.fit(words, .body, g.mapWidth - 24) ?? "⚠ Build failed", x: g.x(0) + 12,
                                         baseline: cy + 4, font: .body, ink: .label)
                s.hits.append(Hit(target: .round(r.n), rect: row.failed!))
                s.rows.append(row)
                continue
            }
            let pages = Double(r.build?.pages ?? Int(maxPages))
            if !r.hasSections {
                // the sections are not known yet: pages only, with comment dots and edit ticks (§5.5)
                let xa = P(r.n, 0) + 1, xb = min(P(r.n, pages), g.mapRight) - 1
                row.pages = CGRect(x: xa, y: y, width: max(xb - xa, 1), height: MapGeometry.cell)
                row.pageLines = (1..<max(1, Int(pages))).map { P(r.n, Double($0)) }.filter { $0 < xb - 1 }
                for c in d.comments {
                    if let st = c.step(in: r.n), st.state != "unplaced", let pos = st.pos { row.dots.append(CGPoint(x: min(P(r.n, pos), xb - 3), y: cy)) }
                }
                let cap = r.prose == "unavailable" || (r.prose == "ok") ? "Sections unavailable for this round" : "Finding sections…"
                row.caption = MapText(text: cap, x: xa + 9, baseline: cy + 4, font: .small, ink: .secondary, halo: .track)
                s.hits.append(Hit(target: .round(r.n), rect: row.pages!))
            } else {
                let heat = heats[r.n] ?? [:]
                let us = rowUnits[r.n] ?? []
                let runs = quietRuns[r.n] ?? []
                var shownNames: [String] = []  // the row's names so far: no two alike
                for (j, u) in us.enumerated() {
                    let xa = X(r.n, u.start) + (joined(r.n, j, left: true) ? 0 : 1)
                    let xb = X(r.n, u.end) - (joined(r.n, j, left: false) ? 0 : 1), w = xb - xa
                    let n = total(r.n, u), lv = MapShade.level(n, s.steps)
                    var cell = Cell(section: u.key, round: r.n, rect: CGRect(x: xa, y: y, width: max(w, 1), height: MapGeometry.cell),
                                    level: lv, count: n)
                    cell.fold = u.fold
                    cell.sections = u.sections
                    cell.quiet = runs.contains { $0.contains(j) }
                    if open { cell.toCheck = u.sections.reduce(0) { $0 + (heat[$1]?.toCheck ?? 0) } }
                    // a block holding the section followed stands for it (the model shows the part first: a fallback)
                    cell.selected = u.sections.contains { scope.followsSection($0) }
                    if scope.isSection { cell.dim = !cell.selected }
                    if scope.followsComments { cell.dim = !u.sections.contains { scope.holds(d, $0, r.n) } }
                    // the path dots in the cell, and those of its neighbours near enough to touch its count
                    let dots = (dotsIn[r.n] ?? []).filter { $0 > xa - 12 && $0 < xb + 12 }
                    let numText = "\(n)"
                    let cw = MapFont.number.width(numText) + 1
                    // its name as it fits (`MapRules.label`), in the normal spacing when that fits it, else the narrow
                    // one; none in a quiet segment (a block: the part's label, on a pad over its stripes)
                    var name: String?
                    var spacing = MapRules.CellSpacing.normal
                    if let kind = u.fold {
                        let spans = r.spans ?? []
                        let range = MapFold.ranges(spans).first { $0.kind == kind }
                        name = range.map { MapFold.label(kind, spans[$0.spans], short: plan.short) }
                    } else if !cell.quiet {
                        let count: CGFloat = n > 0 ? cw : 0
                        // the section's one name, or a longer form of its stem where this cell has the room; where it has
                        // none (nothing fits its narrowest cell), this cell's own; a nameless one's whole name, where it fits
                        name = s.names[nameID(u.key, u.title)]?.fit(.name, MapRules.CellSpacing.tight.room(w, count: count))
                        // a lone "I" or "l" beside a count reads as the digit 1 (the UI audit: "I 3"): the count alone
                        if n > 0, let t = name, MapRules.readsAsDigit(t) { name = nil }
                        // a section without a name of its own (nothing fits its narrowest cell) takes the first form
                        // that fits here; never one a section before it in the row shows ("Re." for Related and
                        // References in a narrow window: the hover and the help tag name it)
                        if let t = name, shownNames.contains(where: { MapRules.bare($0) == MapRules.bare(t) }) { name = nil }
                        if let t = name, MapFont.name.width(t) > spacing.room(w, count: count) { spacing = .tight }
                    }
                    let place = MapRules.placeNumber(xa: xa, xb: xb, width: cw, count: n, dots: dots, name: name.map { MapFont.name.width($0) },
                                                     spacing: spacing)
                    if place.nudge { for x in dots { nudges.insert(Self.dotKey(r.n, x)) } }
                    // the open round's at full ink; an older round's numbers regular and its words in label2 (UI v4)
                    if n > 0 && w >= 12 {
                        cell.number = MapText(text: numText, x: place.x, baseline: cy + 4.6, anchor: place.anchor, font: old ? .numberRegular : .number,
                                              ink: old || u.fold != nil ? .label2 : .number,
                                              halo: !dots.isEmpty || place.nudge ? (old ? MapRole.old(lv) : MapRole.cell(lv)) : nil)
                    }
                    if place.name, let name {
                        shownNames.append(name)
                        cell.name = MapText(text: name, x: xa + spacing.pad, baseline: cy + 4.2, font: .name,
                                            ink: u.fold != nil ? .label2 : lv == 0 ? .secondary : old ? .label2 : lv >= 3 ? .label : .name)
                    }
                    row.cells.append(cell)
                    let target: MapTarget = u.fold.map { .block($0, round: r.n) } ?? .cell(u.key, round: r.n)
                    s.hits.append(Hit(target: target, rect: cell.rect.insetBy(dx: 0, dy: -2)))
                }
                for run in runs {
                    let a = row.cells[run.first!].rect, b = row.cells[run.last!].rect
                    var q = Quiet(rect: CGRect(x: a.minX, y: y, width: b.maxX - a.minX, height: MapGeometry.cell),
                                  sections: run.map { us[$0].key })
                    // named like a cell (the UI audit: a blank stretch read as a name missing): its sections' names
                    // ("Rel. · Disc."), else the first's and how many more ("Related +1"), else the first's as it fits
                    let parts = run.map { s.names[nameID(us[$0].key, us[$0].title)] }
                    if let t = Self.quietName(parts, room: MapRules.CellSpacing.tight.room(q.rect.width, count: 0)) {
                        q.name = MapText(text: t, x: q.rect.minX + MapRules.CellSpacing.tight.pad, baseline: cy + 4.2, font: .name, ink: .secondary)
                    }
                    q.dim = run.allSatisfy { row.cells[$0].dim }
                    row.quiet.append(q)
                }
                row.cells = keepNumbersApart(row.cells)
                // still to check, in the open round only: a vermilion outline on its cells (no chip: each cell prints
                // its count), left out while nothing in the round is answered, as the round's ring says it once (§5 R1;
                // by the answers, not the cells' counts: those hold the advisor's new comments too)
                let c = r.comments ?? .init()
                if c.resolved + c.followUp + c.kept > 0 {
                    for j in row.cells.indices where row.cells[j].toCheck > 0 { row.cells[j].outlined = true }
                }
            }
            // a shorter row ends with a cap and its page count
            let end = r.hasSections ? X(r.n, pages) : min(P(r.n, pages), g.mapRight)
            // a round of fewer pages that ends visibly earlier (a folded part can hide the difference, or make a row of
            // the most pages end earlier than one of fewer: no cap then, it would say the opposite)
            if pages < maxPages && end < mapEnd - 3 {
                let xe = end + 1.5
                row.endcap = xe
                let t = MapText(text: "\(Int(pages)) pp", x: xe + 6, baseline: cy + 4, font: .smallRegular, ink: .secondary)
                // beside the cap when it fits before the unplaced caps, else before the readout
                if t.rect.maxX <= (g.capWidth > 0 ? g.mapRight + 6 : g.readoutX - 8) { row.endText = t }
            }
            // comments the round could not place: in the row's count, in a cap after it, shaded by their count
            let unplaced = r.unplaced ?? unplacedCount(d, r.n)
            if unplaced > 0 {
                let x0 = g.mapRight + 10, w = g.capWidth - 12
                row.unplaced = CGRect(x: x0, y: y, width: w, height: MapGeometry.cell)
                row.unplacedLevel = MapShade.level(unplaced, s.steps)
                row.unplacedText = MapText(text: "+\(unplaced)", x: x0 + w / 2, baseline: cy + 4.4, anchor: .middle, font: .number, ink: .number)
                row.unplacedCaption = MapText(text: "unplaced", x: x0 + w / 2, baseline: y + MapGeometry.cell + 10, anchor: .middle,
                                              font: .smallRegular, ink: .secondary)
                placer.take(row.unplacedCaption!.rect)
                s.hits.append(Hit(target: .unplaced(r.n), rect: row.unplaced!))
            }
            // edits: a tick asked for, a short tick nobody asked for, with a vermilion ring while it is to check (UI v4)
            let left = r.hasSections ? X(r.n, 0) : P(r.n, 0), right = end
            for e in r.edits ?? [] {
                guard let pos = e.pos else { continue }
                let x = min(max(r.hasSections ? X(r.n, pos) : P(r.n, pos), left + 1), right - 1)
                var t = Tick(id: e.id, round: r.n, x: x, top: y + MapGeometry.cell, unrequested: e.unrequested, toCheck: e.toCheck)
                switch scope.kind {
                case .section(let key)?: t.dim = e.section != key
                case .comment(let id)?:
                    t.strong = e.attachedTo.contains(id)
                    t.dim = !t.strong
                case .page(let n, let p)?: t.dim = !(r.n == n && e.page == p)
                case .tag?:
                    t.strong = e.attachedTo.contains(where: scope.tagged.contains)
                    t.dim = !t.strong
                default: break
                }
                row.ticks.append(t)
                s.hits.append(Hit(target: .edit(e.id, round: r.n), rect: CGRect(x: x - 4, y: y + MapGeometry.cell + 1, width: 8,
                                                                                    height: MapGeometry.rug + 4)))
            }
            s.rows.append(row)
        }

        // folded older rounds
        if let lo = folded.last?.n, let hi = folded.first?.n {
            let y = g.rowY(shown.count)
            let written = folded.reduce(0) { $0 + ($1.comments?.new ?? 0) }, edits = folded.reduce(0) { $0 + ($1.edits?.count ?? 0) }
            let rect = CGRect(x: g.x(0), y: y, width: g.mapWidth, height: 22)
            let text = "\(count(folded.count, "older round")) folded: \(count(written, "comment")) written, \(count(edits, "edit"))"
            let t = MapText(text: text + " · ", x: g.x(0) + 10, baseline: y + 15, font: .smallRegular, ink: .secondary)
            let link = MapText(text: "Show all \(d.rounds.count) rounds", x: t.rect.maxX, baseline: y + 15, font: .label, ink: .link)
            s.fold = Fold(rect: rect, title: MapText(text: lo == hi ? "Round \(lo)" : "Rounds \(lo)–\(hi)", x: Self.labelX, baseline: y + 15,
                                                      font: .bodyBold, ink: .secondary),
                          text: t, link: link)
            s.hits.append(Hit(target: .unfold, rect: CGRect(x: 0, y: y - 2, width: g.mapRight, height: 26)))
        }

        // a page followed: its place in its round
        if case .page(let n, let p)? = scope.kind, let i = shown.firstIndex(where: { $0.n == n }) {
            let a = X(n, Double(p)), b = X(n, Double(p + 1))
            s.pageBand = CGRect(x: a + 0.5, y: g.rowY(i) - 4, width: max(b - a - 1, 2), height: MapGeometry.cell + 8)
        }

        // the comments followed: their paths through the rounds (no words on the map: the Sage lines say where)
        for id in scope.comments {
            guard let c = d.comment(id) else { continue }
            var pts: [PathPoint] = []
            let last = c.path.last
            for st in c.path {
                guard let i = shown.firstIndex(where: { $0.n == st.round }), !shown[i].failed else { continue }
                let yc = g.rowY(i) + MapGeometry.cell / 2
                let nudged = st.pos.map { nudges.contains(Self.dotKey(st.round, X(st.round, $0))) } ?? false
                let at: CGPoint
                if st.state == "unplaced" {
                    at = CGPoint(x: g.mapRight + 10 + (g.capWidth - 12) / 2, y: yc)
                } else if let pos = st.pos {
                    at = CGPoint(x: X(st.round, pos), y: yc + (nudged ? MapGeometry.cell / 2 + 1 : 0))
                } else { continue }
                let isLast = st.round == last?.round
                let glyph: PathPoint.Glyph
                if st.state == "unplaced" { glyph = .unplaced }
                else if st.state == "gone" { glyph = .gone }
                else if isLast && st.answer == "resolved" { glyph = .resolved }
                else if isLast && st.answer == "kept" { glyph = .kept }
                else if isLast && st.answer == "to_check" { glyph = .toCheck }
                else if st.round == c.createdRound { glyph = .written }
                else { glyph = .carried }
                pts.append(PathPoint(round: st.round, at: at, glyph: glyph, small: nudged || scope.isPage))
            }
            if let st = c.path.last(where: { s.folded.contains($0.round) }), let pos = st.pos ?? st.page.map(Double.init) {
                // the rounds folded: one dot on the fold, where the path starts
                pts.insert(PathPoint(round: st.round, at: CGPoint(x: P(st.round, pos), y: g.rowY(shown.count) + 11), glyph: .folded), at: 0)
            }
            guard !pts.isEmpty else { continue }
            s.paths.append(Path(comment: id, points: pts, thin: scope.isPage))
            for p in pts { s.hits.append(Hit(target: .comment(id, round: p.round), rect: CGRect(x: p.at.x - 8, y: p.at.y - 8, width: 16, height: 16))) }
        }

        // the structure labels, placed after the pills they must not cover, gap by gap (`LabelPlacer.placeGap`)
        for labels in gaps where !labels.isEmpty { s.labels += placer.placeGap(labels) }

        // the page axis: under each page its number, under a folded part its pages and Show; a shown part a bracket with
        // its name, its pages and Fold (the strip's own round, never one previewed, else the top row with sections, says
        // where). While the strip shows the pages, they are not numbered again here (UI v4): only the parts' pages, Show
        // and Fold.
        let yEnd = folded.isEmpty ? g.rowY(max(0, shown.count - 1)) + MapGeometry.cell + MapGeometry.rug : g.rowY(shown.count) + 22
        let ya = yEnd + 18
        let numbered = !(input.stripShown && held.map { !$0.failed && ($0.build?.pages ?? 0) > 0 } == true)
        if numbered {
            s.axis.append(MapText(text: "page", x: MapGeometry.mapX - 10, baseline: ya, anchor: .end, font: .caption, ink: .secondary))
        }
        // a part that row lacks (a latest round without its appendix) is said under the top row that has it (the code
        // audit: the older rows' blocks had neither Show nor Fold)
        let partRanges = plan.foldable.compactMap { kind in
            ((hr.map { [$0] } ?? []) + shown).lazy.compactMap { r in MapFold.range(kind, r).map { (f: $0, r: r) } }.first
        }
        var reserved: [CGRect] = []
        var hasBracket = false
        for (f, pr) in partRanges {
            let isFolded = plan.folded.contains(f.kind)
            let a = X(pr.n, f.start), b = X(pr.n, f.end)
            if isFolded {
                let t = MapText(text: MapFold.pages(f) + " · ", x: 0, baseline: ya, font: .caption, ink: .secondary)
                var link = MapText(text: "Show", x: 0, baseline: ya, font: .label, ink: .link)
                let w = t.width + link.width, x0 = max(MapGeometry.mapX, (a + b) / 2 - w / 2)
                var text = t
                text.x = x0
                link.x = x0 + t.width
                s.axisParts.append(AxisPart(kind: f.kind, shown: false, text: text, link: link))
                reserved.append(CGRect(x: x0 - 6, y: ya - 12, width: w + 12, height: 16))
                s.hits.append(Hit(target: .showPart(f.kind), rect: CGRect(x: x0 - 4, y: ya - 13, width: w + 8, height: 18)))
            } else {
                hasBracket = true
                let yb = ya + 15
                let name = MapFold.label(f.kind, (pr.spans ?? [])[f.spans], short: false)
                let t = MapText(text: name + " · " + MapFold.pages(f) + " · ", x: 0, baseline: yb + 4, font: .caption, ink: .secondary)
                var link = MapText(text: "Fold", x: 0, baseline: yb + 4, font: .label, ink: .link)
                let w = 12 + t.width + link.width
                let x0 = min(max(MapGeometry.mapX, (a + b) / 2 - w / 2), g.mapRight - w)
                var text = t
                text.x = x0 + 12
                link.x = text.x + t.width
                s.axisParts.append(AxisPart(kind: f.kind, shown: true, text: text, link: link, bracket: [a + 1, b - 1, yb - 4],
                                            chevron: CGPoint(x: x0 + 4, y: yb)))
                s.hits.append(Hit(target: .foldPart(f.kind), rect: CGRect(x: x0 - 4, y: yb - 9, width: w + 8, height: 18)))
            }
        }
        // every page's number while the narrowest page drawn (the row's scale makes some narrower) has 20 pt, else every
        // other one; never one within 3 pt of the last
        let axisPages = Int(hr.flatMap { $0.build?.pages } ?? Int(maxPages))
        let drawnPages = (1...max(1, axisPages)).compactMap { p -> CGFloat? in
            if let hr, s.pageMaps[hr.n]?.block(at: Double(p) - 0.5) != nil { return nil }
            return HX(Double(p)) - HX(Double(p - 1))
        }
        let every = min(g.pageWidth, drawnPages.min() ?? g.pageWidth) < 20 ? 2 : 1
        var lastNumber: CGRect?
        for p in 1...max(1, Int(maxPages)) where numbered && (p - 1) % every == 0 {
            let mid = Double(p) - 0.5
            if p <= axisPages, let hr, s.pageMaps[hr.n]?.block(at: mid) != nil { continue }  // under its block: its pages
            let t = MapText(text: "\(p)", x: p <= axisPages ? HX(mid) : g.x(mid), baseline: ya, anchor: .middle, font: .caption, ink: .secondary)
            guard t.rect.maxX <= g.mapRight + 12, !reserved.contains(where: { $0.intersects(t.rect) }) else { continue }
            if let l = lastNumber, t.rect.minX < l.maxX + 3 { continue }
            lastNumber = t.rect
            s.axis.append(t)
        }
        s.height = s.axis.isEmpty && s.axisParts.isEmpty ? yEnd + 8 : ya + 12 + (hasBracket ? 18 : 0)
        if input.unfold && input.fold > 0 {
            s.foldLink = MapText(text: "Fold", x: MapGeometry.mapX - 10, baseline: ya + 16, anchor: .end, font: .label, ink: .link)
            s.hits.append(Hit(target: .fold, rect: s.foldLink!.rect.insetBy(dx: -4, dy: -3)))
            s.height = max(s.height, ya + 28)
        }
        return s
    }

    /// A count wider than its cell (a very short section in a narrow window) may run over the cell's edge, but never
    /// over a neighbour's count or name: then it is left out, and the cell's help tag and VoiceOver still say it.
    static func keepNumbersApart(_ cells: [Cell]) -> [Cell] {
        var out = cells
        for i in out.indices {
            guard let t = out[i].number, t.inkRect.minX < out[i].rect.minX + 1 || t.inkRect.maxX > out[i].rect.maxX - 1 else { continue }
            let r = t.inkRect.insetBy(dx: -2, dy: 0)
            let clash = out.indices.contains { j in
                j != i && ((out[j].number.map { $0.inkRect.intersects(r) } ?? false) || (out[j].name.map { $0.rect.intersects(r) } ?? false))
            }
            if clash { out[i].number = nil }
        }
        return out
    }

    /// A path dot's place in a row, for the dots moved to their cell's lower edge.
    static func dotKey(_ n: Int, _ x: CGFloat) -> String { "\(n)@\(Int((x * 10).rounded()))" }

    /// The lens's makings: the strip's geometry for the round it shows, the row whose places it joins (nil: the plain
    /// page scale), the folded parts' ranges, the sections' starts besides them, the section or page followed (all in
    /// the round's page units).
    struct Lens {
        var strip: StripGeometry
        var axis: Int?
        var ranges: [(Double, Double)] = []
        var starts: [Double] = []
        var followed: (Double, Double)?
    }

    /// The lens as drawn with the strip scrolled by `offset` (UX.md §40.9): a hairline from each section's start on the
    /// strip to its place on the map (fewer where they crowd), the ends of the strip's part in view and each folded
    /// part's edges always; a faint wedge over a folded part; the wedge of the section or page followed. Its top edge
    /// at the pages' places in the strip's visible frame, clipped to it: nothing from a page scrolled out of view.
    func lens(offset: CGFloat) -> (fans: [[CGPoint]], wedges: [[CGPoint]], selected: [CGPoint]?) {
        guard let l = lensInput else { return ([], [], nil) }
        let g = l.strip, o = min(max(0, offset), g.maxOffset), seen = g.visible(offset: o)
        let lo = seen.lowerBound, hi = seen.upperBound
        func SX(_ pos: Double) -> CGFloat { min(g.width, max(0, g.x(pos) - o)) }
        func AX(_ pos: Double) -> CGFloat { l.axis.map { x($0, pos) } ?? geometry.x(pos) }
        func inView(_ pos: Double) -> Bool { pos >= lo - 0.001 && pos <= hi + 0.001 }
        var lines: [(pos: Double, must: Bool)] = [(lo, true), (hi, true)]
        for f in l.ranges { lines += [(f.0, true), (f.1, true)].filter { inView($0.0) } }
        lines += l.starts.filter(inView).map { ($0, false) }
        lines.sort { $0.pos < $1.pos }
        let musts = lines.filter(\.must)
        var kept: [Double] = []
        for ln in lines {
            if ln.must {
                if !kept.contains(where: { abs($0 - ln.pos) < 0.001 }) { kept.append(ln.pos) }
                continue
            }
            let sx = SX(ln.pos), mx = AX(ln.pos)
            let clear = (kept + musts.map(\.pos)).allSatisfy { p in abs(SX(p) - sx) >= 24 && abs(AX(p) - mx) >= 8 }
            if clear { kept.append(ln.pos) }
        }
        var fans: [[CGPoint]] = []
        for pos in kept.sorted() {
            let mx = AX(pos)
            fans.append([CGPoint(x: SX(pos), y: 0), CGPoint(x: mx, y: MapGeometry.lens), CGPoint(x: mx, y: MapGeometry.row0 - 12)])
        }
        /// A range's wedge over its part in view.
        func clipped(_ a: Double, _ b: Double) -> [CGPoint]? {
            let a = max(a, lo), b = min(b, hi)
            guard b > a + 0.001 else { return nil }
            return Self.wedge(SX(a), SX(b), AX(a), AX(b))
        }
        return (fans, l.ranges.compactMap { clipped($0.0, $0.1) }, l.followed.flatMap { clipped($0.0, $0.1) })
    }

    /// The lens with the strip at its start.
    var fans: [[CGPoint]] { lens(offset: 0).fans }
    var wedges: [[CGPoint]] { lens(offset: 0).wedges }
    var lensSelected: [CGPoint]? { lens(offset: 0).selected }

    private static func wedge(_ a: CGFloat, _ b: CGFloat, _ xa: CGFloat, _ xb: CGFloat) -> [CGPoint] {
        [CGPoint(x: a, y: 0), CGPoint(x: b, y: 0), CGPoint(x: xb, y: MapGeometry.lens), CGPoint(x: xb, y: MapGeometry.row0 - 12),
         CGPoint(x: xa, y: MapGeometry.row0 - 12), CGPoint(x: xa, y: MapGeometry.lens)]
    }

    static func bounds(_ pts: [CGPoint]) -> CGRect {
        let xs = pts.map(\.x), ys = pts.map(\.y)
        return CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0),
                      height: (ys.max() ?? 0) - (ys.min() ?? 0))
    }

    /// The "n carried" pills of one gap side by side: moved apart where two would touch (3 pt between), inside the map.
    static func spreadPills(_ pills: [(CGRect, MapText)], minX: CGFloat, maxX: CGFloat) -> [(CGRect, MapText)] {
        var out = pills.sorted { $0.0.midX < $1.0.midX }
        for i in out.indices.dropFirst() where out[i].0.minX < out[i - 1].0.maxX + 3 {
            out[i].0.origin.x = out[i - 1].0.maxX + 3
        }
        for i in out.indices.reversed() {
            let hi = i == out.count - 1 ? maxX : out[i + 1].0.minX - 3
            if out[i].0.maxX > hi { out[i].0.origin.x = hi - out[i].0.width }
            if out[i].0.minX < minX { out[i].0.origin.x = minX }
        }
        return out.map { r, t in
            var t = t
            t.x = r.midX
            return (r, t)
        }
    }

    /// "Limitations" from "5 Limitations"; the front matter is the abstract.
    static func shortName(_ title: String) -> String {
        title == "Title and abstract" ? "Abstract" : OverviewText.shortTitle(title)
    }

    static func unplacedCount(_ d: PaperOverview, _ n: Int) -> Int {
        d.comments.filter { $0.step(in: n)?.state == "unplaced" }.count
    }

    /// "1 comment waits for a PDF", "3 comments wait for a PDF"; without "comment": "1 waits for a PDF" (the UI
    /// audit: "1 comment wait").
    static func waitWords(_ n: Int, counted: Bool = true) -> String {
        if n == 0 { return (counted ? "No comment" : "None") + " waits for a PDF" }  // not "0 comments wait"
        return (counted ? count(n, "comment") : "\(n)") + (n == 1 ? " waits" : " wait") + " for a PDF"
    }

    /// The comments still open from the round before a failed one: they wait for a PDF.
    static func waiting(_ d: PaperOverview, _ n: Int) -> Int {
        guard let prev = d.rounds.last(where: { $0.n < n && !$0.failed }) else { return 0 }
        return prev.comments?.openAfter ?? 0
    }

    /// The comments carried from section `from` of round `od` into section `to` of round `nw` (a band's "n carried").
    static func carriedOn(_ d: PaperOverview, _ od: Int, _ nw: Int, _ from: String?, _ to: String?) -> Int {
        d.comments.filter { c in
            guard let a = c.step(in: od), let b = c.step(in: nw), a.state != "unplaced", b.state != "unplaced" else { return false }
            return a.section == from && b.section == to
        }.count
    }

    /// The round labels' left edge: after the open round's 11 pt ring (UI v4, the mockup's `.rlab`).
    static let labelX: CGFloat = 18

    /// The open round's ring fill: what is answered (comments with a verdict, unasked edits handled) over that and
    /// what is still to check, `PaperSummary.fill` (D1, the sidebar's and headers' ring) from the round's own counts,
    /// which an older engine's summary lacks; nil with nothing to check (the summary's 1.0: no ring then).
    static func ringFill(_ r: PaperOverview.Round) -> Double? {
        let c = r.comments ?? .init(), e = r.changes ?? .init()
        let toCheck = c.toCheck + e.toCheck
        guard toCheck > 0 else { return nil }
        let done = c.resolved + c.followUp + c.kept + max(0, e.unrequested - e.toCheck)
        return Double(done) / Double(done + toCheck)
    }

    /// A round with answers, for the readout's You column: anything resolved, followed up, kept or left open after
    /// Round 1.
    static func hasAnswers(_ r: PaperOverview.Round, first: Bool) -> Bool {
        guard !first, !r.failed, let c = r.comments else { return false }
        return c.resolved + c.followUp + c.kept + c.leftOpen > 0
    }

    /// The student's responses to the carried comments, in the response bar's words (UI v4, BRIEF §3): "11 revised",
    /// "1 explained", "2 unchanged", "1 not asked"; the ones not 0.
    static func responses(_ c: PaperOverview.Round.Comments) -> [String] {
        [(c.edited, "revised"), (c.noteOnly, "explained"), (c.untouched, "unchanged"), (c.waiting, "not asked")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
    }

    /// Your answers in a round: "✓ 11 · ↩ 2 · – 1" ("" without any).
    static func answers(_ c: PaperOverview.Round.Comments) -> String {
        [c.resolved > 0 ? "✓ \(c.resolved)" : nil, c.followUp > 0 ? "↩ \(c.followUp)" : nil,
         c.kept > 0 ? "\(Status.keptAsIs.glyph) \(c.kept)" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    /// The table's readout lines per column (§4.6): Comments (present, how many new); the student's responses (three
    /// columns only); your answers ("so far" while the round is open).
    static func readoutColumns(_ d: PaperOverview, _ r: PaperOverview.Round, first: Bool, columns: Int, ready: Bool) -> [(String, String)] {
        let c = r.comments ?? .init()
        let c1 = ("\(c.present)", c.present == 0 ? "" : first ? "all new" : "\(c.new) new")
        let resp = responses(c)
        let student: (String, String) = first ? ("first draft", "")
            : (resp.prefix(2).joined(separator: " · ").nonEmpty ?? "none", resp.dropFirst(2).joined(separator: " · "))
        var you = ("", "")
        // your answers: "none" only when the round had nothing to answer ("–" is Kept as is, as in Review: the UI
        // audit found "=" here and "–" there, and "–" also meaning nothing)
        let done = answers(c)
        if !first && !r.isClosed {
            you = (done.isEmpty ? (c.carried > 0 ? "none yet" : "none") : done + " so far", ready ? "ready to finish" : "")
        } else if !first {
            let left = c.leftOpen > 0 ? "\(c.leftOpen) left open" : ""
            you = done.isEmpty ? (left.nonEmpty ?? "none", "") : (done, left)
        }
        return columns == 3 ? [c1, student, you] : columns == 1 ? [c1] : [c1, you]
    }

    /// The map's readout lines (UI v4, plan §3 step 3): Comments, its count ("–" for none) over "N new" in a later
    /// round; with `you`, your answers ("–" for none; "so far" while open) over what was left open; "ready to finish"
    /// under the last column. The student's responses are in the round's help tag.
    static func readoutLines(_ r: PaperOverview.Round, first: Bool, you: Bool, ready: Bool) -> [[String]] {
        let c = r.comments ?? .init()
        let new = !first && c.new > 0 ? "\(c.new) new" : ""
        let count = c.present > 0 ? "\(c.present)" : "–"
        guard you else { return [[count, [new, ready ? "ready to finish" : ""].filter { !$0.isEmpty }.joined(separator: " · ")]] }
        let done = answers(c), left = c.leftOpen > 0 ? "\(c.leftOpen) left open" : ""
        var answered: [String]  // the forms to try, longest first
        var under = ""
        if first || r.failed {
            answered = ["–"]
        } else if !r.isClosed {
            answered = done.isEmpty ? ["–"] : [done + " so far", done]
            under = ready ? "ready to finish" : ""
        } else if done.isEmpty {
            answered = [left.nonEmpty ?? "–"]
        } else {
            answered = [done]
            under = left
        }
        return [[count, new], answered + [under]]
    }

    static func readout(_ d: PaperOverview, _ r: PaperOverview.Round, first: Bool, geometry g: MapGeometry, y: CGFloat,
                        ready: Bool, old: Bool = false) -> [MapText] {
        if r.failed {
            // cut to the readout's room as every line of it, in fewer words first (one column: "7 wait for a PDF")
            let room = g.readoutWidth - 6, n = waiting(d, r.n)
            let what = [waitWords(n), waitWords(n, counted: false)].first { MapFont.body.width($0) <= room }
                ?? MapRules.fit(waitWords(n, counted: false), .body, room) ?? "\(n)"
            let how = ["Show Log… in the toolbar", "Show Log…"].first { MapFont.smallRegular.width($0) <= room } ?? "Show Log…"
            return [MapText(text: what, x: g.width, baseline: y + 14, anchor: .end, font: .body, ink: .danger),
                    MapText(text: how, x: g.width, baseline: y + 29, anchor: .end, font: .smallRegular, ink: .secondary)]
        }
        let cols = readoutLines(r, first: first, you: g.columns == 2, ready: ready)
        // one line in the cell's middle; two, over each other
        let two = cols.contains { !($0.last ?? "").isEmpty }
        var out: [MapText] = []
        for (j, col) in cols.enumerated() {
            let x = g.columnRight[j]
            let room = (j == 0 ? g.columnRight[0] - g.readoutX : g.columnRight[1] - g.columnRight[0] - 8) - 2
            // the open round's count in the label colour, semibold; older rounds' and every "–" quieter (UI v4)
            let font: MapFont = j == 0 && !old ? .bodyBold : .body
            let forms = Array(col.dropLast())
            let text = forms.first { font.width($0) <= room } ?? MapRules.fit(forms.last ?? "", font, room) ?? forms.last ?? ""
            let ink: MapRole = text == "–" ? .tertiary : old ? .secondary : .label
            out.append(MapText(text: text, x: x, baseline: y + (two ? 14 : 20.5), anchor: .end, font: font, ink: ink))
            if let under = col.last, !under.isEmpty, col.count > 1 {
                out.append(MapText(text: MapRules.fit(under, .smallRegular, room) ?? under, x: x, baseline: y + 29, anchor: .end,
                                   font: .smallRegular, ink: .secondary))
            }
        }
        return out
    }
}

/// What the overview follows, as the map reads it (§5.1): a section's key, a round, a page of a round and its
/// comments, or one comment.
struct Scope {
    enum Kind: Equatable {
        case section(String)
        case round(Int)
        case page(Int, Int)
        case comment(String)
        case tag(String)
    }

    var kind: Kind?
    /// The comments whose paths are drawn: the one followed, or those on the page followed.
    var comments: [String] = []
    /// The comments with the tag followed (TAGS.md §6.2 with the critique's fix: their cells stay, the others step
    /// back; no paths and no outlines, so the map stays quiet; its numbers never change).
    var tagged: Set<String> = []
    /// The comments a cell must hold to stay at full strength: those followed, or those with the tag followed.
    var held: [String] { if case .tag? = kind { return Array(tagged) } else { return comments } }
    /// The round a section was followed in: its name there, as the toolbar's token says it.
    var sectionRound: Int?

    init(_ item: OverviewItem?, _ d: PaperOverview) {
        switch item {
        case .section(let key, let n)?:
            kind = .section(key)
            sectionRound = n
        case .round(let n)?: kind = .round(n)
        case .page(let n, let p)?:
            kind = .page(n, p)
            comments = d.comments.filter { $0.step(in: n)?.page == p && $0.step(in: n)?.state != "unplaced" }.map(\.id)
        case .comment(let id)?:
            kind = .comment(id)
            comments = [id]
        case .tag(let id)?:
            kind = .tag(id)
            tagged = Set(d.comments.filter { id == TagCatalog.untagged ? $0.tags.isEmpty : $0.tags.contains(id) }.map(\.id))
        case nil: kind = nil
        }
    }

    var isScoped: Bool { kind != nil && !isRound }
    var isSection: Bool { if case .section? = kind { return true } else { return false } }
    var isRound: Bool { if case .round? = kind { return true } else { return false } }
    var isPage: Bool { if case .page? = kind { return true } else { return false } }
    var followsComments: Bool {
        switch kind {
        case .comment?, .tag?: return true
        default: return isPage
        }
    }
    var isTag: Bool { if case .tag? = kind { return true } else { return false } }
    var round: Int? { if case .round(let n)? = kind { return n } else { return nil } }

    func followsSection(_ key: String?) -> Bool {
        if case .section(let k)? = kind { return key == k } else { return false }
    }

    /// The cell holds one of the comments followed.
    func holds(_ d: PaperOverview, _ section: String, _ n: Int) -> Bool {
        held.contains { d.comment($0)?.step(in: n).map { $0.section == section && $0.state != "unplaced" } ?? false }
    }

    func caption(_ d: PaperOverview) -> String? {
        switch kind {
        case .section(let k)?: return d.shortTitle(k, d.sectionTitle(k, round: sectionRound) ?? k) + " only"
        case .comment(let id)?: return id + " only"
        case .page(let n, let p)?: return "Page \(p + 1) of Round \(n): its comments"
        case .tag(let id)?: return TagCatalog.current.name(id) + " only"
        default: return nil
        }
    }

    /// The student's responses in the response bar's words (UI v4); the engine's keys are unchanged.
    static let responses = ["edited": "revised", "note_only": "explained", "untouched": "unchanged", "waiting": "not asked"]
    /// Kept as is: Review's sign (`Status.keptAsIs.glyph`), the student's final.pdf's too.
    static let keptSign = Status.keptAsIs.glyph
    static let answers = ["resolved": "✓ resolved", "kept": keptSign + " kept as is", "follow_up": "↩ followed up", "left_open": "left open",
                          "to_check": "○ to check"]

    /// The Sage line under a round's readout (§4.6): what the thing followed is in that round, most important first.
    func sageParts(_ d: PaperOverview, _ r: PaperOverview.Round) -> [String] {
        let first = r.n == d.rounds.first?.n
        switch kind {
        case .section(let key)?:
            guard r.hasSections else { return [] }
            guard r.spans?.contains(where: { $0.section == key }) == true else {
                if let m = r.match?.first(where: { $0.from == key && $0.to != key && $0.to != nil }), let to = m.to {
                    return ["merged into " + d.shortTitle(to, d.sectionTitle(to, round: r.n) ?? to)]
                }
                return [d.rounds.contains { $0.n > r.n && ($0.spans ?? []).contains { $0.section == key } } ? "not written yet" : "removed by then"]
            }
            let steps = d.comments.compactMap { c -> (PaperOverview.Comment, PaperOverview.Comment.Step)? in
                guard let st = c.step(in: r.n), st.section == key, st.state != "unplaced" else { return nil }
                return (c, st)
            }
            let carried = steps.filter { $0.0.createdRound != r.n }.map(\.1)
            var out = ["\(steps.count) here"]
            func n(_ xs: [PaperOverview.Comment.Step], _ f: (PaperOverview.Comment.Step) -> Bool) -> Int { xs.filter(f).count }
            if !first && !carried.isEmpty {
                let e = n(carried) { $0.response == "edited" }, no = n(carried) { $0.response == "note_only" },
                    u = n(carried) { $0.response == "untouched" }, w = n(carried) { $0.response == "waiting" }
                out.append([e > 0 ? "\(e) revised" : nil, no > 0 ? "\(no) explained" : nil, u > 0 ? "\(u) unchanged" : nil,
                            w > 0 ? "\(w) not asked" : nil].compactMap { $0 }.joined(separator: " · "))
                let a = { (w: String) in n(carried) { $0.answer == w } }
                if !r.isClosed {
                    out.append([a("resolved") > 0 ? "✓ \(a("resolved")) so far" : nil, a("to_check") > 0 ? "○ \(a("to_check"))" : nil]
                        .compactMap { $0 }.joined(separator: " · "))
                } else {
                    out.append([a("resolved") > 0 ? "✓ \(a("resolved"))" : nil, a("follow_up") > 0 ? "↩ \(a("follow_up"))" : nil,
                                a("kept") > 0 ? "\(Self.keptSign) \(a("kept"))" : nil, a("left_open") > 0 ? "\(a("left_open")) open" : nil]
                        .compactMap { $0 }.joined(separator: " · "))
                }
            }
            if let h = r.heat?.first(where: { $0.section == key }), (h.added ?? 0) + (h.deleted ?? 0) > 0 {
                out.append("+\(h.added ?? 0) −\(h.deleted ?? 0)")
            }
            return out.filter { !$0.isEmpty }
        case .page(let n, let p)?:
            let steps = comments.compactMap { d.comment($0)?.step(in: r.n) }
            if r.n == n {
                let edits = (r.edits ?? []).filter { $0.page == p }.count
                return ["p.\(p + 1): \(count(steps.count, "comment"))", count(edits, "edit")]
            }
            guard !steps.isEmpty else { return [] }
            let pages = Set(steps.filter { $0.state != "unplaced" }.compactMap(\.page)).sorted().map { String($0 + 1) }
            return ["\(steps.count) of them", pages.isEmpty ? "unplaced" : "p." + pages.joined(separator: ", ")]
        case .comment(let id)?:
            guard let c = d.comment(id), let st = c.step(in: r.n) else { return [] }
            let page = st.page.map { "p.\($0 + 1)" } ?? "no page"
            if c.createdRound == r.n { return ["written here, " + page] }
            let resp = st.response.flatMap { Self.responses[$0] } ?? ""
            let ans = st.answer.flatMap { Self.answers[$0] } ?? ""
            if st.state == "unplaced" { return ["not placed in this round", resp, ans].filter { !$0.isEmpty } }
            if st.state == "gone" { return [page + ": passage deleted", ans].filter { !$0.isEmpty } }
            let eds = (r.edits ?? []).filter { $0.attachedTo.contains(id) }
            let a = eds.reduce(0) { $0 + ($1.added ?? 0) }, del = eds.reduce(0) { $0 + ($1.deleted ?? 0) }
            return [page, resp + (eds.isEmpty ? "" : " (\(count(eds.count, "edit")))"), ans, a + del > 0 ? "+\(a) −\(del)" : ""]
                .filter { !$0.isEmpty }
        case .tag?:
            // the tag's comments in the round, each once: here, written here, and how the round answered them
            let steps = tagged.compactMap { id in d.comment(id).flatMap { c in c.step(in: r.n).map { (c, $0) } } }
            guard !steps.isEmpty else { return first || r.n == d.latest?.n ? ["none here"] : [] }
            let new = steps.filter { $0.0.createdRound == r.n }.count
            func a(_ w: String) -> Int { steps.filter { $0.1.answer == w }.count }
            var out = ["\(steps.count) here", new > 0 ? "\(new) new" : ""]
            if !r.isClosed {
                out.append([a("resolved") > 0 ? "✓ \(a("resolved")) so far" : nil, a("to_check") > 0 ? "○ \(a("to_check"))" : nil]
                    .compactMap { $0 }.joined(separator: " · "))
            } else {
                out.append([a("resolved") > 0 ? "✓ \(a("resolved"))" : nil, a("follow_up") > 0 ? "↩ \(a("follow_up"))" : nil,
                            a("kept") > 0 ? "\(Self.keptSign) \(a("kept"))" : nil, a("left_open") > 0 ? "\(a("left_open")) open" : nil]
                    .compactMap { $0 }.joined(separator: " · "))
            }
            return out.filter { !$0.isEmpty }
        default:
            return []
        }
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// A map target as what the overview follows (§5.1): a cell or a band its section in that round, a rail or a readout
/// its round, a path dot its comment; nil for what only shows a help tag or folds.
extension MapTarget {
    var item: OverviewItem? {
        switch self {
        case .cell(let k, let n): return .section(k, round: n)
        case .band(let from, let to, let n): return to.map { .section($0, round: n) } ?? from.map { .section($0, round: n - 1) }
        case .round(let n), .unplaced(let n): return .round(n)
        case .comment(let id, _): return .comment(id)
        case .unfold, .fold, .edit, .block, .showPart, .foldPart: return nil
        }
    }
}
