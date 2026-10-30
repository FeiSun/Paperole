import AppKit
import CoreGraphics

// Folding a long appendix (and a long References list) into one block on the paper map (design/overview/v3/VISUAL.md
// §5, option A, with the critique's fixes): what the parts of a round are, whether a paper folds them (decided once per
// paper, at the unfolded scale, so every row with an appendix folds or none does), the page scale that leaves, and how
// each row maps a place in pages to a place on the map. Pure functions, tested in MapFoldTests.

/// A part of a paper that folds into one block.
enum FoldKind: String, Hashable, CaseIterable, Comparable {
    case references, appendix

    static func < (a: FoldKind, b: FoldKind) -> Bool { a.order < b.order }
    private var order: Int { self == .references ? 0 : 1 }

    /// The block's width in pages (it is never narrower than its label on the paper map).
    var pages: Double { self == .appendix ? 2 : 1.5 }
    /// It folds only when longer than this, in pages.
    var longerThan: Double { self == .appendix ? 3 : 4 }
    /// "the appendix", "References", for the help tags and VoiceOver.
    var name: String { self == .appendix ? "the appendix" : "References" }
}

/// Where a part sits in one round: its spans (indices into the round's `spans`) and its extent in pages.
struct FoldRange: Equatable {
    var kind: FoldKind
    var spans: Range<Int>
    var start: Double
    var end: Double

    var length: Double { end - start }
    func contains(_ pos: Double) -> Bool { pos > start + 0.0001 && pos < end - 0.0001 }
}

enum MapFold {
    /// The headings of a reference list (its short name, case aside).
    static let referenceNames: Set<String> = ["references", "bibliography", "literature cited", "works cited", "reference list", "reference",
                                               "参考文献"]

    /// "A" from "A Survey transects" (a lettered first-level heading, as `\appendix` numbers them); nil otherwise.
    static func letter(_ title: String) -> String? {
        let parts = title.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, var lead = parts.first.map(String.init) else { return nil }
        if lead.hasSuffix(".") || lead.hasSuffix(":") { lead.removeLast() }
        guard lead.count == 1, let c = lead.first, c.isUppercase, c.isASCII else { return nil }
        return lead
    }

    /// A heading's words without a leading number ("7 References" → "references"), lower-cased; cheap (the map asks
    /// at every build).
    private static func bare(_ title: String) -> String {
        let t = title.lowercased().trimmingCharacters(in: .whitespaces)
        guard let sp = t.firstIndex(of: " "), t[..<sp].allSatisfy({ $0.isNumber || $0 == "." }) else { return t }
        return String(t[t.index(after: sp)...]).trimmingCharacters(in: .whitespaces)
    }

    static func isReferences(_ title: String) -> Bool { referenceNames.contains(bare(title)) }

    static func isAppendixTitle(_ title: String) -> Bool {
        let t = bare(title)
        return t.hasPrefix("appendix") || t.hasPrefix("appendices") || t.hasPrefix("supplementary")
    }

    /// Each span's part: the engine's when it sends one ("front", "body", "references", "appendix"), else worked out:
    /// References by its heading; the appendix as the lettered first-level sections (or one called Appendix) after
    /// References, or, in a paper without References, a run of them at the end that starts with A.
    static func parts(_ spans: [PaperOverview.Span]) -> [String] {
        if !spans.isEmpty, spans.allSatisfy({ $0.part != nil }) { return spans.map { $0.part ?? "body" } }
        var out = spans.map { $0.section == "front" ? "front" : "body" }
        let refs = spans.lastIndex { isReferences($0.title) }
        if let r = refs { out[r] = "references" }
        if let r = refs {
            for i in (r + 1)..<spans.count where letter(spans[i].title) != nil || isAppendixTitle(spans[i].title) { out[i] = "appendix" }
        } else if let a = spans.firstIndex(where: { letter($0.title) == "A" || isAppendixTitle($0.title) }) {
            var i = a
            while i < spans.count && (letter(spans[i].title) != nil || isAppendixTitle(spans[i].title)) { out[i] = "appendix"; i += 1 }
            if i < spans.count { for j in a..<i { out[j] = "body" } }  // not at the end: not an appendix
        }
        return out
    }

    /// The parts that could fold in a round: References (one span), and the appendix (its first run of spans).
    static func ranges(_ spans: [PaperOverview.Span]) -> [FoldRange] {
        let p = parts(spans)
        var out: [FoldRange] = []
        if let r = p.firstIndex(of: "references") {
            out.append(FoldRange(kind: .references, spans: r..<(r + 1), start: spans[r].start, end: spans[r].end))
        }
        if let a = p.firstIndex(of: "appendix") {
            var b = a
            while b + 1 < spans.count && p[b + 1] == "appendix" { b += 1 }
            out.append(FoldRange(kind: .appendix, spans: a..<(b + 1), start: spans[a].start, end: spans[b].end))
        }
        return out
    }

    /// A round's range of that kind.
    static func range(_ kind: FoldKind, _ r: PaperOverview.Round) -> FoldRange? {
        guard r.hasSections, !r.failed else { return nil }
        return ranges(r.spans ?? []).first { $0.kind == kind }
    }

    /// "Appendix A–E" ("Appendix A" for one letter, "Appendix" without letters), or "A–E" when short; "References" or
    /// "Refs".
    static func label(_ kind: FoldKind, _ spans: ArraySlice<PaperOverview.Span>, short: Bool) -> String {
        guard kind == .appendix else { return short ? "Refs" : "References" }
        let letters = spans.compactMap { letter($0.title) }
        let span = letters.isEmpty ? "" : letters.count == 1 || letters.first == letters.last ? letters[0] : letters[0] + "–" + letters.last!
        if short { return span.isEmpty ? "App." : span }
        return span.isEmpty ? "Appendix" : "Appendix " + span
    }

    /// The pages a range is printed on, from 1: "pp. 17–29", "p. 17".
    static func pages(_ r: FoldRange) -> String {
        let a = Int(r.start.rounded(.down)) + 1, b = max(a, Int(r.end.rounded(.up)))
        return a == b ? "p. \(a)" : "pp. \(a)–\(b)"
    }

    /// The parts an item lies in (a section of one, a page mostly in one, a comment in one in any round): following
    /// it shows them first (VISUAL §5.1 "自动展开").
    static func parts(of item: OverviewItem, _ d: PaperOverview) -> Set<FoldKind> {
        func at(_ n: Int, _ pos: Double) -> FoldKind? {
            d.round(n).flatMap { r in ranges(r.spans ?? []).first { $0.contains(pos) }?.kind }
        }
        switch item {
        case .section(let key, let n):
            guard let r = d.round(n), let spans = r.spans, let i = spans.firstIndex(where: { $0.section == key }) else { return [] }
            return Set(ranges(spans).filter { $0.spans.contains(i) }.map(\.kind))
        case .page(let n, let p):
            guard let r = d.round(n) else { return [] }
            return Set(ranges(r.spans ?? []).filter { min(Double(p + 1), $0.end) - max(Double(p), $0.start) > 0.5 }.map(\.kind))
        case .comment(let id):
            return Set(d.comment(id)?.path.compactMap { st in st.state == "unplaced" ? nil : st.pos.flatMap { at(st.round, $0) } } ?? [])
        case .round, .tag:
            return []
        }
    }
}

/// How one row maps a place in pages to a place on the map: the page scale `k` (pt per page) from `x0`, except that a
/// folded part takes a block of its own width, whatever its length.
struct PageMap: Equatable {
    struct Block: Equatable {
        var kind: FoldKind
        var start: Double
        var end: Double
        var width: CGFloat
    }

    var x0: CGFloat
    var k: CGFloat
    var blocks: [Block] = []

    func x(_ pos: Double) -> CGFloat {
        var x = x0, cur = 0.0
        for b in blocks {
            if pos <= b.start { return x + CGFloat(pos - cur) * k }
            x += CGFloat(b.start - cur) * k
            if pos <= b.end { return x + (b.end > b.start ? CGFloat((pos - b.start) / (b.end - b.start)) * b.width : 0) }
            x += b.width
            cur = b.end
        }
        return x + CGFloat(pos - cur) * k
    }

    func block(at pos: Double) -> Block? { blocks.first { pos > $0.start + 0.0001 && pos < $0.end - 0.0001 } }
}

/// What a paper folds on its map at a width (VISUAL §5.1–5.2): decided once for the paper, at the unfolded scale with
/// the round of the longest part, so every row that has the part folds it or none does. The appendix folds when it is
/// longer than three pages and its block (two pages wide, never narrower than its label) is at least a page narrower
/// than it; References the same way past four pages (a block of one and a half), decided once the appendix is.
struct FoldPlan: Equatable {
    /// The parts the rule folds, and of them those the viewer has not shown at their real length.
    var foldable: [FoldKind] = []
    var folded: [FoldKind] = []
    /// The page scale for the rest, pt per page.
    var k: CGFloat
    /// Each folded part's block width (the same in every row), and whether its label is the short one ("› A–E").
    var width: [FoldKind: CGFloat] = [:]
    var short = false

    /// `label(kind, short)`: the block's least width for its words (chevron, label, count).
    static func make(_ d: PaperOverview, mapWidth: CGFloat, maxPages: Double, enabled: Bool, shown: Set<FoldKind>,
                     label labelWidth: (FoldKind, Bool) -> CGFloat) -> FoldPlan {
        let k0 = mapWidth / CGFloat(max(maxPages, 1))
        var plan = FoldPlan(k: k0)
        guard enabled else { return plan }
        var widths: [String: CGFloat] = [:]  // each label's width, measured once (`solve` asks many times)
        func label(_ k: FoldKind, _ short: Bool) -> CGFloat {
            let key = k.rawValue + (short ? "|s" : "")
            if let w = widths[key] { return w }
            let w = labelWidth(k, short)
            widths[key] = w
            return w
        }
        let rounds = d.rounds.filter { $0.hasSections && !$0.failed }
        func longest(_ kind: FoldKind) -> Double { rounds.compactMap { MapFold.range(kind, $0)?.length }.max() ?? 0 }
        func scale(_ kinds: [FoldKind], short: Bool) -> CGFloat {
            solve(rounds, kinds: kinds, mapWidth: mapWidth, label: { label($0, short) })
        }
        var kinds: [FoldKind] = []
        // the appendix first, at the unfolded scale; then References at the scale the appendix leaves
        for kind in [FoldKind.appendix, .references] {
            let l = longest(kind)
            guard l > kind.longerThan else { continue }
            let k = kinds.isEmpty ? k0 : scale(kinds, short: false)
            let block = max(CGFloat(kind.pages) * k, label(kind, false))
            if block <= CGFloat(l - 1) * k { kinds.append(kind) }
        }
        guard !kinds.isEmpty else { return plan }
        plan.foldable = kinds.sorted()
        plan.folded = plan.foldable.filter { !shown.contains($0) }
        guard !plan.folded.isEmpty else { return plan }
        // the long label unless it costs more than three pages beyond the block's two (a narrow window)
        var k = scale(plan.folded, short: false)
        if plan.folded.contains(where: { label($0, false) > 5 * k }) {
            plan.short = true
            k = scale(plan.folded, short: true)
        }
        guard k > k0 else {  // folding gains nothing here, so the axis offers no Fold for it (a part shown keeps its Fold)
            plan.foldable.removeAll { !shown.contains($0) }
            plan.folded = []
            return plan
        }
        plan.k = k
        for kind in plan.folded { plan.width[kind] = max(CGFloat(kind.pages) * k, label(kind, plan.short)) }
        return plan
    }

    /// The largest page scale at which every row fits the map's width with these parts folded.
    static func solve(_ rounds: [PaperOverview.Round], kinds: [FoldKind], mapWidth: CGFloat, label: (FoldKind) -> CGFloat) -> CGFloat {
        let rows = rounds.map { r -> (Double, [FoldKind]) in
            let ranges = MapFold.ranges(r.spans ?? []).filter { kinds.contains($0.kind) }
            let pages = max(Double(r.build?.pages ?? 0), r.spans?.last?.end ?? 0)
            return (pages - ranges.reduce(0) { $0 + $1.length }, ranges.map(\.kind))
        }
        func width(_ k: CGFloat) -> CGFloat {
            rows.map { u, ks in CGFloat(u) * k + ks.reduce(0) { $0 + max(CGFloat($1.pages) * k, label($1)) } }.max() ?? 0
        }
        var lo: CGFloat = 0, hi = mapWidth
        for _ in 0..<48 {
            let mid = (lo + hi) / 2
            if width(mid) <= mapWidth { lo = mid } else { hi = mid }
        }
        return lo
    }

    /// A round's map of pages: its own folded parts' blocks, where they are in that round.
    func pageMap(_ r: PaperOverview.Round?, x0: CGFloat) -> PageMap {
        var m = PageMap(x0: x0, k: k)
        guard let r, !folded.isEmpty else { return m }
        for range in MapFold.ranges(r.spans ?? []) where folded.contains(range.kind) {
            m.blocks.append(.init(kind: range.kind, start: range.start, end: range.end, width: width[range.kind] ?? 0))
        }
        m.blocks.sort { $0.start < $1.start }
        return m
    }
}
