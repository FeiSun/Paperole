import AppKit
import SwiftUI

/// The map from the keyboard (OVERVIEW-v2 §7 "地图的键盘导航"), as a pure function of what is followed: once the map has
/// the keys (a click in the overview), ← → move along a round (a section's neighbours, a page's, the comments
/// of the strip's round in their order on the page), ↑ ↓ to the round above or below (the same section by its key or
/// by the paragraphs it went to, the same page, or the comment followed through its rounds, the strip going with it);
/// Return opens Review there and Esc follows nothing. With nothing followed, a first arrow follows the strip round's
/// first section.
enum MapKeys {
    enum Key: Equatable { case left, right, up, down }

    struct Move: Equatable {
        var item: OverviewItem
        /// The strip's round when it moves without the item changing (a comment through its rounds).
        var strip: Int?
    }

    static func move(_ k: Key, from sel: OverviewItem?, data d: PaperOverview, strip: Int?) -> Move? {
        switch sel {
        case nil:
            guard let n = strip ?? MapRules.defaultStrip(d), let r = d.round(n) else { return nil }
            if r.hasSections, let first = r.spans?.first { return Move(item: .section(first.section, round: n)) }
            return Move(item: .round(n))
        case .section(let key, let n)?:
            switch k {
            case .left, .right: return sideways(k == .left ? -1 : 1, section: key, n, d)
            case .up, .down: return vertical(section: key, n, up: k == .up, d)
            }
        case .round(let n)?:
            switch k {
            case .up, .down: return d.round(n + (k == .up ? 1 : -1)).map { Move(item: .round($0.n)) }
            case .left, .right:
                guard let r = d.round(n), r.hasSections, let sp = k == .right ? r.spans?.first : r.spans?.last else { return nil }
                return Move(item: .section(sp.section, round: n))
            }
        case .tag?:
            return nil  // a tag is not on one place of the map: the arrows have nowhere to go
        case .page(let n, let p)?:
            switch k {
            case .left, .right:
                let q = p + (k == .left ? -1 : 1), pages = d.round(n)?.build?.pages ?? 0
                return q >= 0 && q < pages ? Move(item: .page(round: n, page: q)) : nil
            case .up, .down:
                var m = n
                repeat { m += k == .up ? 1 : -1 } while d.round(m).map { $0.failed || ($0.build?.pages ?? 0) == 0 } ?? false
                guard let r = d.round(m), let pages = r.build?.pages, pages > 0 else { return nil }
                return Move(item: .page(round: m, page: min(p, pages - 1)))
            }
        case .comment(let id)?:
            guard let c = d.comment(id) else { return nil }
            let s = c.shownRound(strip: strip) ?? 0
            switch k {
            case .left, .right:
                // the comments of the strip's round, in their order on its pages
                let here = d.comments.compactMap { x -> (String, Double)? in
                    guard let st = x.step(in: s) else { return nil }
                    return (x.id, st.state == "unplaced" ? 1e9 : st.pos ?? st.page.map(Double.init) ?? 1e9)
                }.sorted { $0.1 < $1.1 || ($0.1 == $1.1 && $0.0 < $1.0) }
                guard let i = here.firstIndex(where: { $0.0 == id }) else { return nil }
                let j = i + (k == .left ? -1 : 1)
                return here.indices.contains(j) ? Move(item: .comment(here[j].0), strip: s) : nil
            case .up, .down:
                // the comment through its rounds: the strip goes to the next round it has a page in
                let rounds = c.path.filter { st in st.page != nil && st.state != "unplaced" && d.round(st.round).map { !$0.failed } ?? false }
                    .map(\.round).sorted()
                let next = k == .up ? rounds.first { $0 > s } : rounds.last { $0 < s }
                return next.map { Move(item: .comment(id), strip: $0) }
            }
        }
    }

    private static func sideways(_ step: Int, section: String, _ n: Int, _ d: PaperOverview) -> Move? {
        guard let spans = d.round(n)?.spans, let i = spans.firstIndex(where: { $0.section == section }) else { return nil }
        let j = i + step
        return spans.indices.contains(j) ? Move(item: .section(spans[j].section, round: n)) : nil
    }

    /// The same section a round up or down: by its key, else where its paragraphs went (the band's other end, most
    /// paragraphs first), else the section at the same place; a round without sections is followed as a round.
    private static func vertical(section key: String, _ n: Int, up: Bool, _ d: PaperOverview) -> Move? {
        let m = n + (up ? 1 : -1)
        guard let r = d.round(m) else { return nil }
        guard r.hasSections, !r.failed, let spans = r.spans else { return Move(item: .round(m)) }
        if spans.contains(where: { $0.section == key }) { return Move(item: .section(key, round: m)) }
        let match = up ? (r.match ?? []).filter { $0.from == key && $0.to != nil }.map { ($0.to!, $0.kept ?? 0) }
            : (d.round(n)?.match ?? []).filter { $0.to == key && $0.from != nil }.map { ($0.from!, $0.kept ?? 0) }
        if let best = match.filter({ k in spans.contains { $0.section == k.0 } }).max(by: { $0.1 < $1.1 }) {
            return Move(item: .section(best.0, round: m))
        }
        guard let here = d.round(n)?.spans?.first(where: { $0.section == key }) else { return nil }
        let mid = (here.start + here.end) / 2
        let near = spans.min { abs(($0.start + $0.end) / 2 - mid) < abs(($1.start + $1.end) / 2 - mid) }
        return near.map { Move(item: .section($0.section, round: m)) }
    }
}

/// The map's sentences for VoiceOver (OVERVIEW-v2 §7 "VoiceOver（每行一句话）"): a round's row in one sentence, each
/// cell in one, and what a key moved to.
enum MapSpeech {
    /// "Round 4, Oct 16, open. 12 comments, none new. Tomás: 3 edited, 3 untouched, 6 waiting. You: ✓ 2 so far, 10 to
    /// check. Introduction 1, Materials and methods 4, …"
    static func row(_ d: PaperOverview, _ r: PaperOverview.Round, student: String) -> String {
        let state = r.failed ? "build failed" : r.isClosed ? "closed" : "open"
        var s = "Round \(r.n), " + [spoken(OverviewText.dates(r.created, r.isClosed ? r.closedAt : nil)), state]
            .filter { !$0.isEmpty }.joined(separator: ", ") + "."
        if r.failed { return s + " " + MapScene.waitWords(MapScene.waiting(d, r.n)) + "." }
        let c = r.comments ?? .init(), first = r.n == d.rounds.first?.n
        s += " \(count(c.present, "comment"))" + (c.present == 0 ? "." : first ? ", all new." : c.new == 0 ? ", none new." : ", \(c.new) new.")
        if !first {
            let resp = [c.edited > 0 ? "\(c.edited) edited" : nil, c.noteOnly > 0 ? "\(c.noteOnly) note only" : nil,
                        c.untouched > 0 ? "\(c.untouched) untouched" : nil, c.waiting > 0 ? "\(c.waiting) waiting" : nil].compactMap { $0 }
            if !resp.isEmpty { s += " \(student.isEmpty ? "The student" : student): " + resp.joined(separator: ", ") + "." }
            let you = !r.isClosed
                ? [c.resolved > 0 ? "\(c.resolved) resolved so far" : nil, c.followUp > 0 ? "\(c.followUp) followed up so far" : nil,
                   c.kept > 0 ? "\(c.kept) kept so far" : nil, c.toCheck > 0 ? "\(c.toCheck) to check" : nil]
                : [c.resolved > 0 ? "\(c.resolved) resolved" : nil, c.followUp > 0 ? "\(c.followUp) followed up" : nil,
                   c.kept > 0 ? "\(c.kept) kept as is" : nil, c.leftOpen > 0 ? "\(c.leftOpen) left open" : nil]
            let y = you.compactMap { $0 }
            if !y.isEmpty { s += " You: " + y.joined(separator: ", ") + "." }
        }
        let unplaced = r.unplaced ?? MapScene.unplacedCount(d, r.n)
        if unplaced > 0 { s += " \(unplaced) not placed." }
        if !r.hasSections {
            s += r.prose == "unavailable" || r.prose == "ok" ? " Sections unavailable for this round." : " Sections not known yet."
        } else {
            let cells = (r.spans ?? []).compactMap { sp -> String? in
                let n = r.heat?.first { $0.section == sp.section }?.present ?? 0
                return n > 0 ? "\(d.shortTitle(sp.section, sp.title)) \(n)" : nil
            }
            s += cells.isEmpty ? " No comments on any section." : " " + cells.joined(separator: ", ") + "."
        }
        return s
    }

    /// The rail's dates as said: "Sep 19 to 22", "Oct 16" (no arrows).
    static func spoken(_ dates: String) -> String {
        dates.replacingOccurrences(of: " → ", with: " to ").replacingOccurrences(of: " →", with: "")
    }

    /// "Materials and methods, Round 4: 4 comments, none new, 2 to check. Pages 2 to 3. 3 edits."
    static func cell(_ d: PaperOverview, _ key: String, _ n: Int) -> String {
        guard let r = d.round(n), let sp = r.spans?.first(where: { $0.section == key }) else { return "Round \(n)" }
        let h = r.heat?.first { $0.section == key }
        var s = "\(d.shortTitle(key, sp.title)), Round \(n): \(count(h?.present ?? 0, "comment"))"
        if let h, h.present > 0, n != d.rounds.first?.n { s += h.new == 0 ? ", none new" : ", \(h.new) new" }
        if !r.isClosed, let t = h?.toCheck, t > 0 { s += ", \(t) to check" }
        let p0 = Int(sp.start.rounded(.down)) + 1, p1 = max(p0, Int(sp.end.rounded(.up)))
        s += p0 == p1 ? ". Page \(p0)." : ". Pages \(p0) to \(p1)."
        if let h, h.changes > 0 { s += " \(count(h.changes, "edit"))." }
        return s
    }

    /// "Appendix A to E, Round 4: 1 comment, 1 to check. Pages 17 to 29. Folded."
    static func block(_ d: PaperOverview, _ kind: FoldKind, _ n: Int) -> String {
        guard let r = d.round(n), let range = MapFold.range(kind, r) else { return "Round \(n)" }
        let spans = (r.spans ?? [])[range.spans]
        let heat = Dictionary((r.heat ?? []).map { ($0.section, $0) }, uniquingKeysWith: { a, _ in a })
        let total = spans.reduce(0) { $0 + (heat[$1.section]?.present ?? 0) }
        let toCheck = r.isClosed ? 0 : spans.reduce(0) { $0 + (heat[$1.section]?.toCheck ?? 0) }
        let name = MapFold.label(kind, spans, short: false).replacingOccurrences(of: "–", with: " to ")
        let p0 = Int(range.start.rounded(.down)) + 1, p1 = max(p0, Int(range.end.rounded(.up)))
        return "\(name), Round \(n): \(count(total, "comment"))" + (toCheck > 0 ? ", \(toCheck) to check" : "")
            + (p0 == p1 ? ". Page \(p0)." : ". Pages \(p0) to \(p1).") + " Folded."
    }

    /// The map's controls outside its rows, where a click finds them (the code audit: VoiceOver reached none of them):
    /// the older rounds folded (a click shows them all), their Fold, and each part's Show or Fold under the page axis.
    struct Control: Equatable {
        var target: MapTarget
        var label: String
        var rect: CGRect
    }

    static func controls(_ s: MapScene) -> [Control] {
        func rect(_ t: MapTarget) -> CGRect? { s.hits.last { $0.target == t }?.rect }
        func words(_ t: MapText) -> String { t.text.hasSuffix(" · ") ? String(t.text.dropLast(3)) : t.text }
        var out: [Control] = []
        if let f = s.fold, let r = rect(.unfold) {
            out.append(Control(target: .unfold, label: said(f.title.text + ", " + words(f.text) + ". " + f.link.text), rect: r))
        }
        if s.foldLink != nil, let r = rect(.fold) { out.append(Control(target: .fold, label: "Fold the older rounds", rect: r)) }
        for a in s.axisParts {
            let t: MapTarget = a.shown ? .foldPart(a.kind) : .showPart(a.kind)
            guard let r = rect(t) else { continue }
            out.append(Control(target: t, label: (a.shown ? "Fold " : "Show ") + a.kind.name + ", " + said(words(a.text)), rect: r))
        }
        return out
    }

    /// The map's words as said: "pp. 17–29" as "pages 17 to 29", "Rounds 1–3" as "Rounds 1 to 3", " · " as a comma.
    static func said(_ s: String) -> String {
        s.replacingOccurrences(of: "pp. ", with: "pages ").replacingOccurrences(of: "p. ", with: "page ")
            .replacingOccurrences(of: "–", with: " to ").replacingOccurrences(of: " · ", with: ", ")
    }

    /// What the overview follows now, said after a key moved it.
    static func item(_ i: OverviewItem, _ d: PaperOverview, strip: Int?, student: String) -> String {
        switch i {
        case .section(let k, let n): return cell(d, k, n)
        case .round(let n): return d.round(n).map { row(d, $0, student: student) } ?? "Round \(n)"
        case .page(let n, let p):
            let cs = d.comments.filter { $0.step(in: n).map { $0.page == p && $0.state != "unplaced" } ?? false }.count
            return "Page \(p + 1) of Round \(n): \(count(cs, "comment"))."
        case .comment(let id):
            let n = d.comment(id)?.shownRound(strip: strip) ?? 0
            return MapHelp.lines(.comment(id, round: n), d, student: student).joined(separator: ". ")
        case .tag(let id):
            let n = d.comments.filter { id == TagCatalog.untagged ? $0.tags.isEmpty : $0.tags.contains(id) }.count
            return "Following \(TagCatalog.current.name(id)): \(count(n, "comment"))."
        }
    }
}

/// The view that has the map's keys: a click in the overview (`OverviewModel.takeKeys`) makes it the window's first
/// responder (it is in the key view loop too), so the sidebar's list no longer takes the arrows; the app's key monitor then routes ← → ↑ ↓ and
/// Return to the map (`AppModel.overviewKey`). It draws nothing and takes no click.
final class OverviewKeyView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
}

struct OverviewKeyTarget: NSViewRepresentable {
    let overview: OverviewModel

    func makeNSView(context: Context) -> OverviewKeyView {
        let v = OverviewKeyView()
        overview.keyView = v
        return v
    }

    func updateNSView(_ v: OverviewKeyView, context: Context) {
        if overview.keyView !== v { overview.keyView = v }
    }
}
