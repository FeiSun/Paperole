import CoreGraphics
import Foundation

/// Where the window is for the selected paper (OVERVIEW-v2 §5.1; FEATURES OV-6): its overview, the default when the
/// paper is clicked in the sidebar, or Review, the PDF and the comment panel as before.
enum Level: String, Equatable {
    case overview, review
}

/// What the overview follows (OVERVIEW-v2 §5.1): a section (its id in that round, and the round of the cell clicked),
/// a round, a page of a round (0-based), a comment, or a writing tag (TAGS.md §6.2, the fifth: a Topics row; its id,
/// or `TagCatalog.untagged` for Not tagged).
enum OverviewItem: Equatable, Hashable {
    case section(String, round: Int)
    case round(Int)
    case page(round: Int, page: Int)
    case comment(String)
    case tag(String)
}

/// The overview's own place, kept with each entry of the history: what it follows, the round the thumbnail strip
/// shows (nil: the latest), whether the older rounds are unfolded, the folded parts the viewer has shown (VISUAL v3
/// §5.1: Back and Forward keep them; the paper opens folded again from the sidebar), and how far it is scrolled.
struct OverviewPlace: Equatable {
    var selection: OverviewItem?
    var strip: Int?
    var unfold = false
    var shownParts: Set<FoldKind> = []
    var scroll: Double = 0
}

/// Where Review opens (OVERVIEW-v2 §5.1 "进审阅"): a round (nil: the latest), and in it a comment, a change (Back to
/// Review as it was left), a section (its heading's title in that round, as the overview's `spans` name it: the
/// engine's section ids are its own keys, not the paragraphs' blocks) or a page (0-based), the first of them that the
/// round has.
struct ReviewTarget: Equatable {
    var round: Int?
    var comment: String?
    var change: String?
    var section: String?
    var page: Int?
    /// Back or Forward to Review as it was left: the PDF put back there, the selection kept without moving it.
    var pdf: PDFPlace? = nil
}

/// Review as it was left: the round shown, the selection and the PDF's place, so Forward (or Back across papers) opens
/// it there again.
struct ReviewPlace: Equatable {
    var round: Int?
    var comment: String?
    var change: String?
    var tab: PanelTab = .comments
    var pdf: PDFPlace? = nil

    /// The same round, selection and tab, wherever the PDF is.
    func sameSelection(_ o: ReviewPlace) -> Bool { round == o.round && comment == o.comment && change == o.change && tab == o.tab }
}

/// A place in the PDF (design/pdf-reader/PLAN.md §5.1): the page (0-based), the point a third of the way down the view
/// (contract coordinates) and the paper's zoom (nil: Fit Width); `label` names it: "p.4 · 2.1 Data".
struct PDFPlace: Equatable {
    var page: Int
    var x: Double
    var y: Double
    var zoom: CGFloat?
    var label: String
}

/// One entry of the window's history: the paper, the level, and the place in each level; or a page of the hierarchy
/// (UX.md §22), no paper, with its scroll. `step`: a place in the PDF a jump left while in that paper's Review (PLAN
/// §5.1), which folds into the Review step when Review is left.
struct NavPlace: Equatable {
    var paper: String?
    var level: Level
    var overview = OverviewPlace()
    var review = ReviewPlace()
    var hub: HubPage?
    var hubScroll: Double = 0
    var step = false

    /// Review of the same paper: the two are steps of one visit.
    func sameReview(_ o: NavPlace) -> Bool { level == .review && o.level == .review && hub == nil && o.hub == nil && paper == o.paper }
}

/// The window's history (⌘[ and ⌘], the toolbar's ‹ ›): one stack across papers and levels, as the mockup's. A new
/// place (another paper, Review from the overview, All Rounds) is pushed; following something inside the overview is
/// not a place of its own (OVERVIEW-v2 mockup: `select` changes the place, `go` pushes it).
struct NavHistory: Equatable {
    static let limit = 64
    /// At most this many PDF steps a visit of Review (PLAN §5.3), the oldest going first.
    static let stepLimit = 20
    private(set) var back: [NavPlace] = []
    private(set) var forward: [NavPlace] = []
    /// The back steps the last fold took off, for `dropLast`.
    private var folded: [NavPlace] = []

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    /// The window leaves `current` for a new place: it can be gone back to, and the forward places are dropped.
    mutating func push(_ current: NavPlace) {
        if back.last != current { back.append(current) }
        if back.count > Self.limit { back.removeFirst(back.count - Self.limit) }
        forward = []
    }

    /// A jump in the PDF leaves `current` (Review, with its PDF place): a step of this visit, as a new place.
    mutating func pushStep(_ current: NavPlace) {
        var p = current
        p.step = true
        push(p)
        let run = back.reversed().prefix { $0.step && $0.sameReview(p) }.count
        if run > Self.stepLimit { back.remove(at: back.count - run) }
    }

    /// Review of `paper` is left (or shows another round): its PDF steps go, from the top of both stacks; the place
    /// pushed next, Review's, keeps the PDF place.
    mutating func fold(paper: String?) {
        folded = []
        while let p = back.last, p.step, p.level == .review, p.paper == paper { folded.insert(back.removeLast(), at: 0) }
        while let p = forward.last, p.step, p.level == .review, p.paper == paper { forward.removeLast() }
    }

    /// The place before, with `current` kept for Forward; nil at the start. Between two places of one Review, the one
    /// left is a step too.
    mutating func goBack(from current: NavPlace) -> NavPlace? {
        guard let p = back.popLast() else { return nil }
        forward.append(Self.marked(current, toward: p))
        return p
    }

    mutating func goForward(from current: NavPlace) -> NavPlace? {
        guard let p = forward.popLast() else { return nil }
        back.append(Self.marked(current, toward: p))
        return p
    }

    /// Only toward a step: two Review places of one paper that are not steps (a paper removed between them) are two
    /// visits, the one left kept whole.
    private static func marked(_ c: NavPlace, toward p: NavPlace) -> NavPlace {
        var c = c
        if p.step && c.sameReview(p) { c.step = true }
        return c
    }

    /// The last place pushed, taken back when it is the one given (a double click's first click undone), with the
    /// steps its fold took off: Review was never really left.
    mutating func dropLast(where match: (NavPlace) -> Bool) {
        guard let p = back.last, match(p) else { return }
        back.removeLast()
        back += folded
        folded = []
    }

    /// A paper left the list: its places go (a Back to it would open nothing).
    mutating func remove(paper: String) {
        func clean(_ s: [NavPlace]) -> [NavPlace] {
            s.filter { $0.paper != paper }.reduce(into: []) { out, p in if out.last != p { out.append(p) } }
        }
        back = clean(back)
        forward = clean(forward)
    }
}

/// Which jumps in the PDF record the place they leave (design/pdf-reader/PLAN.md §5.2). A look-up (a link, Contents,
/// Jump, Find's first match, a card's page number) records where it leaves; a run through comments or paragraphs
/// (cards, J/K, answers moving on, N) records one step, where your own reading left off, so Back skips the cards.
/// Neither records when the target is in view or less than a view away. Your own scrolling ends a run.
struct PDFSteps {
    /// `find`: Find's first match, a look-up that begins a run from where it leaves, so its next matches (Return,
    /// typing on) record no step of their own once it has one.
    enum Kind { case lookUp, run, find }

    /// Where the run under way began, and whether it has recorded its step; nil: no run.
    private(set) var run: (from: PDFPlace, recorded: Bool)?

    /// A jump of `kind` from `here`: the place to record, or nil. `near(p)`: the target is in view of place p, or less
    /// than a view away.
    mutating func jump(_ kind: Kind, from here: PDFPlace, near: (PDFPlace) -> Bool) -> PDFPlace? {
        switch kind {
        case .lookUp, .find:
            let at = near(here) ? nil : here
            run = kind == .find ? (here, at != nil) : nil
            return at
        case .run:
            let r = run ?? (here, false)
            run = r
            guard !r.recorded, !near(r.from) else { return nil }
            run?.recorded = true
            return r.from
        }
    }

    /// A scroll or a key of your own: the next run starts where it is.
    mutating func ownMove() { run = nil }

    /// Whether `target` lies in `visible` or less than its height above or below it (both in the document's points).
    static func isNear(_ target: CGRect, visible: CGRect) -> Bool {
        max(target.minY - visible.maxY, visible.minY - target.maxY, 0) < visible.height
    }

    /// The text line nearest a point (PDFKit page space), for Back's flash: the least vertical, then horizontal,
    /// distance, within 20 pt of its height; nil when no line is that near.
    static func line(at p: CGPoint, in lines: [CGRect]) -> CGRect? {
        func dy(_ r: CGRect) -> CGFloat { max(r.minY - p.y, p.y - r.maxY, 0) }
        func dx(_ r: CGRect) -> CGFloat { max(r.minX - p.x, p.x - r.maxX, 0) }
        return lines.filter { dy($0) <= 20 }.min { (dy($0), dx($0)) < (dy($1), dx($1)) }
    }
}
