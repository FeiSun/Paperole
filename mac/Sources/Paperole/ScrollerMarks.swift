import AppKit

/// What the column beside the scroller marks (design/review-page/BRIEF.md §3; mac/UX.md §42), one item per comment,
/// edit or match. It shows what the page shows (design/pdf-reader/PLAN.md P1.6): in an open round the comments to check
/// and the unasked edits that wait (rings, with change marks off too: decision D2), with change marks shown the
/// student's edits (ticks); while Find has a query, only its matches.
struct ScrollerMark: Equatable {
    enum Kind: Int, Comparable {
        case toCheck, unasked, edit, find
        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    enum Target: Equatable, Hashable { case comment(String), change(String), find(Int) }

    var kind: Kind
    var fraction: Double  // 0 the paper's top, 1 its foot
    var target: Target
    var page: Int
    /// What VoiceOver says for it: its panel row's spoken form, or "Match 10 of 21".
    var label: String
    /// An unasked edit not handled yet (`ChangeModel.handled` false): a vermilion ring.
    var waits = false
    /// Drawn as a tick: every edit while change marks are shown; an unasked edit that waits with change marks off has
    /// its ring alone (D2).
    var tick = true
    /// The comment an edit answers (its first), for the window's folding (BRIEF §5.3).
    var answers: String?
}

/// The column's items and their layout (only the column observes them); laid when the items change or the view
/// resizes, never on a scroll.
@MainActor
final class ScrollerMarks {
    private(set) var items: [ScrollerMark] = []
    private(set) var layout = StripLayout.Layout()
    private(set) var height: CGFloat = 0
    private(set) var find = false

    /// New items or a new height: true when the layout changed.
    @discardableResult
    func set(_ items: [ScrollerMark], height: CGFloat, find: Bool) -> Bool {
        guard items != self.items || height != self.height || find != self.find else { return false }
        self.items = items
        self.height = height
        self.find = find
        layout = StripLayout.layout(items, height: height, find: find)
        return true
    }

    /// A place's share of the paper's height: the pages above it and its distance below its page's top (contract
    /// coordinates), over all the pages' heights; PDFKit's few points between pages are left out.
    nonisolated static func fraction(page: Int, top: Double, heights: [Double]) -> Double? {
        let total = heights.reduce(0, +)
        guard page >= 0, page < heights.count, total > 0 else { return nil }
        return min(max((heights[..<page].reduce(0, +) + min(max(top, 0), heights[page])) / total, 0), 1)
    }
}

/// Items to glyphs, groups and zones (BRIEF §3.3–3.5). Pure. Positions are down the column from its top (46 pt under
/// the PDF view's top), in points; across, from the column's axis (R − 35).
enum StripLayout {
    /// Rings closer than this join one capsule; any glyphs closer than this are one group; matches one run.
    static let join: CGFloat = 9
    /// Ticks closer than this are drawn as one.
    static let tickJoin: CGFloat = 3
    /// A zone reaches this far above and below its glyphs, cut halfway to the next group.
    static let reach: CGFloat = 10
    /// The column's width and where its axis is in it: R − 50 … R − 20, the axis at R − 35 (the find button's centre).
    static let width: CGFloat = 30
    static let axis: CGFloat = 15
    /// The column starts this far under the view's top (6 pt under the find button); a zone never goes higher than 2 pt
    /// above it (the button keeps its clicks), nor more than 4 pt past its foot.
    static let top: CGFloat = 46
    static let above: CGFloat = 2
    static let below: CGFloat = 4

    enum Shape: String { case ring, capsule, tick, unaskedTick, findTick, run }

    struct Glyph: Equatable {
        var shape: Shape
        var y: CGFloat  // its first member's
        var lo: CGFloat
        var hi: CGFloat
        var members: [Int]  // item indices, top to bottom
        var group = 0
        /// A stable name: its shape and first item, so a resize keeps its layer.
        var id: String
    }

    struct Group: Equatable {
        var glyphs: [Int]
        var members: [Int]  // item indices, top to bottom, each once
        var lo: CGFloat
        var hi: CGFloat
        var first: CGFloat  // the first member's y
        var zone: ClosedRange<CGFloat> = 0...0
    }

    struct Layout: Equatable {
        var ys: [CGFloat] = []  // each item's y
        var glyphs: [Glyph] = []
        var groups: [Group] = []

        /// The group whose zone holds `y`.
        func group(at y: CGFloat) -> Int? { groups.firstIndex { $0.zone.contains(y) } }
        /// The glyph a target is drawn in for the halo: its ring or capsule, else its tick.
        func glyph(of item: Int) -> Int? {
            glyphs.firstIndex { ($0.shape == .ring || $0.shape == .capsule) && $0.members.contains(item) }
                ?? glyphs.firstIndex { $0.members.contains(item) }
        }
    }

    static func layout(_ items: [ScrollerMark], height: CGFloat, find: Bool) -> Layout {
        var out = Layout()
        out.ys = items.map { CGFloat($0.fraction) * height }
        let ys = out.ys
        func chains(_ idx: [Int], gap: CGFloat) -> [[Int]] {
            var runs: [[Int]] = []
            for i in idx.sorted(by: { (ys[$0], $0) < (ys[$1], $1) }) {
                if let last = runs.last?.last, ys[i] - ys[last] < gap { runs[runs.count - 1].append(i) } else { runs.append([i]) }
            }
            return runs
        }
        func id(_ s: Shape, _ run: [Int]) -> String { s.rawValue + "|" + key(items[run[0]].target) }
        if find {
            for run in chains(Array(items.indices).filter { items[$0].kind == .find }, gap: join) {
                let a = ys[run[0]], b = ys[run[run.count - 1]]
                if run.count == 1 {
                    out.glyphs.append(Glyph(shape: .findTick, y: a, lo: a - 1, hi: a + 1, members: run, id: id(.findTick, run)))
                } else {
                    var lo = a, hi = b
                    if hi - lo < 6 { let m = (a + b) / 2; lo = m - 3; hi = m + 3 }  // at least 6 pt long
                    out.glyphs.append(Glyph(shape: .run, y: a, lo: lo, hi: hi, members: run, id: id(.run, run)))
                }
            }
        } else {
            let rings = items.indices.filter { items[$0].kind == .toCheck || items[$0].kind == .unasked && items[$0].waits }
            for run in chains(rings, gap: join) {
                let a = ys[run[0]], b = ys[run[run.count - 1]]
                if run.count == 1 {
                    out.glyphs.append(Glyph(shape: .ring, y: a, lo: a - 3.5, hi: a + 3.5, members: run, id: id(.ring, run)))
                } else {
                    // 3.5 pt past its first and last member, at least 11 pt long for two and 15 for more, about their middle
                    var lo = a - 3.5, hi = b + 3.5
                    let need: CGFloat = run.count == 2 ? 11 : 15
                    if hi - lo < need { let m = (a + b) / 2; lo = m - need / 2; hi = m + need / 2 }
                    out.glyphs.append(Glyph(shape: .capsule, y: a, lo: lo, hi: hi, members: run, id: id(.capsule, run)))
                }
            }
            let ticks = items.indices.filter { (items[$0].kind == .edit || items[$0].kind == .unasked) && items[$0].tick }
            for run in chains(ticks, gap: tickJoin) {
                let y = ys[run[0]]
                let s: Shape = run.contains { items[$0].kind == .edit } ? .tick : .unaskedTick  // the longer length
                out.glyphs.append(Glyph(shape: s, y: y, lo: y - 1, hi: y + 1, members: run, id: id(s, run)))
            }
        }
        // groups: the glyphs whose members chain less than 9 pt apart, of any kind
        var parent = Array(out.glyphs.indices)
        func root(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
        let points = out.glyphs.indices.flatMap { g in out.glyphs[g].members.map { (y: ys[$0], g: g) } }.sorted { ($0.y, $0.g) < ($1.y, $1.g) }
        for i in points.indices.dropFirst() where points[i].y - points[i - 1].y < join {
            parent[root(points[i].g)] = root(points[i - 1].g)
        }
        var byRoot: [Int: [Int]] = [:]
        for g in out.glyphs.indices { byRoot[root(g), default: []].append(g) }
        out.groups = byRoot.values.map { gs in
            var seen = Set<Int>()
            let members = gs.flatMap { out.glyphs[$0].members }.filter { seen.insert($0).inserted }.sorted { (ys[$0], $0) < (ys[$1], $1) }
            return Group(glyphs: gs.sorted(), members: members, lo: gs.map { out.glyphs[$0].lo }.min()!,
                         hi: gs.map { out.glyphs[$0].hi }.max()!, first: ys[members[0]])
        }
        .sorted { $0.lo < $1.lo }
        for k in out.groups.indices {
            var t = out.groups[k].lo - reach, b = out.groups[k].hi + reach
            t = k > 0 ? max(t, (out.groups[k - 1].hi + out.groups[k].lo) / 2) : max(t, -above)
            b = k + 1 < out.groups.count ? min(b, (out.groups[k].hi + out.groups[k + 1].lo) / 2) : min(b, height + below)
            out.groups[k].zone = t...max(t, b)
            for g in out.groups[k].glyphs { out.glyphs[g].group = k }
        }
        return out
    }

    static func key(_ t: ScrollerMark.Target) -> String {
        switch t {
        case .comment(let id): return "c:" + id
        case .change(let id): return "e:" + id
        case .find(let i): return "f:\(i)"
        }
    }

    /// A glyph's box, at rest or grown (BRIEF §3.3, §4.2), in the column's coordinates (y down, x from its left edge).
    /// `stroke`: a ring's or capsule's line width (0: filled).
    static func box(_ g: Glyph, grown: Bool) -> (rect: CGRect, stroke: CGFloat) {
        let ax = axis
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }
        switch g.shape {
        case .ring: return grown ? (r(ax - 5, g.y - 5, 10, 10), 1.75) : (r(ax - 3.5, g.y - 3.5, 7, 7), 1.5)
        case .capsule: return grown ? (r(ax - 5, g.lo - 1.5, 10, g.hi - g.lo + 3), 1.75) : (r(ax - 3.5, g.lo, 7, g.hi - g.lo), 1.5)
        // their right end at axis − 8, 2 pt clear of a halo's stroke; grown, at axis − 9.5, 2 pt clear of the grown halo
        case .tick: return grown ? (r(ax - 16.5, g.y - 1.5, 7, 3), 0) : (r(ax - 14, g.y - 1, 6, 2), 0)
        case .unaskedTick: return grown ? (r(ax - 14.5, g.y - 1.5, 5, 3), 0) : (r(ax - 12, g.y - 1, 4, 2), 0)
        case .findTick: return grown ? (r(ax - 4, g.y - 1.5, 8, 3), 0) : (r(ax - 3, g.y - 1, 6, 2), 0)
        case .run: return grown ? (r(ax - 1.5, g.lo, 3, g.hi - g.lo), 0) : (r(ax - 1, g.lo, 2, g.hi - g.lo), 0)
        }
    }

    /// The current match (Sage, over its run), and a grown run's tick at the match nearest the pointer.
    static func currentBox(y: CGFloat, grown: Bool) -> CGRect {
        grown ? CGRect(x: axis - 6, y: y - 2, width: 12, height: 4) : CGRect(x: axis - 5, y: y - 1.5, width: 10, height: 3)
    }
    static func nearBox(y: CGFloat) -> CGRect { CGRect(x: axis - 4, y: y - 1.5, width: 8, height: 3) }

    /// The halo's outer edge: 2.5 pt outside its glyph (a 1.5 pt stroke 1 pt clear of it).
    static func haloBox(_ g: Glyph, grown: Bool) -> CGRect { box(g, grown: grown).rect.insetBy(dx: -2.5, dy: -2.5) }
}

/// The column's inks (BRIEF §2): the same in Light and Dark, as the page is white in both, and each 3:1 or more on the
/// page, a band on it and both backdrops.
enum LaneInk {
    /// Waits on you: `Palette.toCheck`'s Light value.
    static let ring = NSColor(hex: 0xC04734)
    /// An edit: the Sage ramp's ink (`MapRole.ink`, Light).
    static let edit = NSColor(hex: 0x5E7F65)
    /// A find match: the find's grey, solid, one step darker (`Palette.findMark`).
    static let find = Palette.findMark
    /// Selected, and the current match: Sage's Light value.
    static let selected = NSColor(hex: Palette.sage.light)
}
