import AppKit
import Foundation

/// The selected paper's overview (OVERVIEW-v2): the engine's `overview` for it, how far that is, what the overview
/// follows, the round its thumbnail strip shows, the older rounds unfolded, and its scroll position, which Back and
/// All Rounds put back. The data is asked for when the overview is shown and the paper's state has changed since.
@MainActor
final class OverviewModel: ObservableObject {
    enum Status: Equatable {
        case idle, loading, loaded
        /// The engine has no `overview` yet (it answered "Unknown method"), or a fixture run without one: the overview
        /// shows what the paper's state says, and the map says it needs a newer engine.
        case unavailable
        case failed(String)
    }

    @Published private(set) var paper: String?
    @Published private(set) var data: PaperOverview?
    @Published private(set) var status: Status = .idle
    @Published var selection: OverviewItem?
    /// The round the thumbnail strip shows; nil: the latest.
    @Published var strip: Int?
    @Published var unfold = false
    /// The folded parts (the appendix, a long References list) shown at their real length (VISUAL v3 §5.1), and those
    /// the map folds now (written by the map, as `folded`): following something inside one shows it first.
    @Published var shownParts: Set<FoldKind> = []
    var foldedParts: [FoldKind] = []
    /// The paper map as a table (`MapTableView`), the viewer's choice (kept in the app's defaults; never by a test run).
    @Published var asTable = false
    /// What the pointer is over and the help tag: observed only by the hover layer, the tag and the panel's lines.
    let hover = OverviewHover()
    /// The view that has the map's keys (`OverviewKeyTarget`), and the rounds the map folds now (a key that moves into
    /// one unfolds them).
    weak var keyView: OverviewKeyView?
    var folded: [Int] = []
    /// The overview's width while it is shown, for its toolbar title's room (`OverviewToolbarTitle`).
    @Published var width: CGFloat = 0
    /// The state version (`AppModel.stateVersion`) the data was asked for at: a newer state asks again.
    private(set) var version = -1
    private var sequence = 0
    /// How long the last reply took, from the request to the data in the model (the debug hook `ovtext`).
    private(set) var loadMs: Double?
    private var begun: TimeInterval = 0
    /// The overview's scroll view while it is shown (`OverviewScrollProbe`), and the offset from its top to put back.
    weak var scrollView: NSScrollView? { didSet { if scrollView !== oldValue { applyPendingScroll() } } }
    private(set) var savedScroll: Double = 0
    private(set) var pendingScroll: Double?
    /// The map's top in the overview's scrolled content (`MapTopKey`), for `revealRow`.
    var mapTop: CGFloat = 0

    var place: OverviewPlace {
        OverviewPlace(selection: selection, strip: strip, unfold: unfold, shownParts: shownParts, scroll: liveScroll ?? savedScroll)
    }

    /// Another paper (or none): nothing loaded, nothing followed, scrolled to the top.
    func reset(for paper: String?) {
        if !whenLoaded.isEmpty { ran(false) }  // waited for the paper left
        self.paper = paper
        hover.leave()
        data = nil
        status = .idle
        selection = nil
        strip = nil
        unfold = false
        shownParts = []
        foldedParts = []
        version = -1
        savedScroll = 0
        pendingScroll = 0
        applyPendingScroll()
    }

    /// A place from the history: what was followed, the strip's round, the fold and the scroll, as left.
    func restore(_ p: OverviewPlace) {
        if selection != p.selection { selection = p.selection }
        if strip != p.strip { strip = p.strip }
        if unfold != p.unfold { unfold = p.unfold }
        if shownParts != p.shownParts { shownParts = p.shownParts }
        savedScroll = p.scroll
        pendingScroll = p.scroll
        applyPendingScroll()
    }

    /// The overview is left (for Review, or as a place in the history): its offset is kept for when it is shown again.
    func saveScroll() {
        if let y = liveScroll { savedScroll = y }
        pendingScroll = savedScroll
    }

    /// The map takes the keys (a click in the overview): the sidebar's list gives them up, as a click in a window's
    /// content takes them from its sidebar.
    func takeKeys() {
        guard let v = keyView, let w = v.window, w.firstResponder !== v else { return }
        w.makeFirstResponder(v)
    }

    /// The overview shown again (Back or All Rounds from Review, whose views gave the keys up): the map takes them when
    /// nobody has them, never from the sidebar's list.
    func takeKeysIfFree() {
        guard let v = keyView, let w = v.window, w.firstResponder === w || w.firstResponder == nil else { return }
        w.makeFirstResponder(v)
    }

    /// The map has the keys: ← → ↑ ↓ and Return move and open what it follows.
    var hasKeys: Bool { keyView.map { $0.window?.firstResponder === $0 } ?? false }

    // MARK: Loading

    private var whenLoaded: [(Bool) -> Void] = []

    /// Runs once the request on its way has its reply (true) or none comes (false).
    func afterLoad(_ f: @escaping (Bool) -> Void) { whenLoaded.append(f) }

    private func ran(_ ok: Bool) {
        let fs = whenLoaded
        whenLoaded = []
        for f in fs { f(ok) }
    }

    func begin(version: Int) -> Int {
        sequence += 1
        self.version = version
        begun = ProcessInfo.processInfo.systemUptime
        if status != .loading { status = .loading }
        return sequence
    }

    /// The data no longer says what the engine would (a round it had pending was filled in since): it is asked for
    /// again when the overview is next shown.
    func stale() { version = -1 }

    /// The reply to request `seq` for `paper`; an older request's or another paper's is dropped.
    func finish(_ seq: Int, paper: String?, _ result: Result<PaperOverview, Error>) {
        guard seq == sequence, paper == self.paper else { return }
        switch result {
        case .success(let d):
            loadMs = ((ProcessInfo.processInfo.systemUptime - begun) * 10_000).rounded() / 10
            data = d
            status = .loaded
            if let s = selection, !Self.valid(s, in: d) { selection = nil }
            if let n = strip, d.round(n) == nil { strip = nil }  // a round gone (Put Back): the latest that built
            ran(true)
        case .failure(let e):
            let message = e.localizedDescription
            status = Self.isUnknownMethod(message) ? .unavailable : .failed(message)
            ran(false)
        }
        applyPendingScroll()
    }

    /// No overview to ask for (a fixture run without one).
    func unavailable(_ seq: Int) {
        guard seq == sequence else { return }
        status = .unavailable
        ran(false)
    }

    /// The engine's reply to a method it does not have (rpc.py): "Unknown method 'overview'."
    nonisolated static func isUnknownMethod(_ message: String) -> Bool { message.hasPrefix("Unknown method") }

    nonisolated static func valid(_ s: OverviewItem, in d: PaperOverview) -> Bool {
        switch s {
        case .section(let id, let n): return d.round(n)?.spans?.contains { $0.section == id } ?? false
        case .round(let n): return d.round(n) != nil
        case .page(let n, let p): return d.round(n).map { p >= 0 && p < ($0.build?.pages ?? 0) } ?? false
        case .comment(let id): return d.comment(id) != nil
        case .tag(let id): return id == TagCatalog.untagged || d.comments.contains { $0.tags.contains(id) }
        }
    }

    // MARK: Scrolling

    /// Round `n`'s row of the map in view, with its chips above and its Sage line below, scrolled as little as needed:
    /// a key moved what the overview follows, or following something unfolded older rounds (review 2026-10-19: the
    /// followed row could be below the window). After the map is drawn again, which may have unfolded.
    func revealRow(_ n: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, !self.asTable, let sv = self.scrollView, sv.window != nil, let scene = self.hover.scene,
                  let i = scene.shownRounds.firstIndex(of: n) else { return }
            let y = Double(self.mapTop + scene.geometry.rowY(i))
            if let t = Self.scrollToShow(top: y - 16, bottom: y + 48, offset: Self.offset(sv), height: Self.visibleHeight(sv)) {
                Self.scroll(sv, to: t)
            }
        }
    }

    /// The height of the overview that is seen: its clip view less the part under the toolbar (its content insets).
    static func visibleHeight(_ sv: NSScrollView) -> Double {
        let i = sv.contentView.contentInsets
        return Double(sv.contentView.bounds.height - i.top - i.bottom)
    }

    /// The offset that shows `top`…`bottom` (content points from the top) with a margin, moving as little as it can
    /// and never past `top`; nil when it is in view.
    nonisolated static func scrollToShow(top: Double, bottom: Double, offset: Double, height: Double, margin: Double = 12) -> Double? {
        if top < offset { return max(0, top - margin) }
        if bottom > offset + height { return max(0, min(top - margin, bottom - height + margin)) }
        return nil
    }

    /// The offset from the top of the overview shown, or nil when it is not.
    var liveScroll: Double? {
        guard let sv = scrollView, sv.window != nil else { return nil }
        return Self.offset(sv)
    }

    /// Puts the pending offset back once the overview is long enough to have it (its data may still be coming), or at
    /// the last try as far as it goes.
    func applyPendingScroll(try n: Int = 0) {
        guard let y = pendingScroll, let sv = scrollView, sv.window != nil else { return }
        if Self.room(sv) >= y || n >= 8 {
            Self.scroll(sv, to: y)
            pendingScroll = nil
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 * Double(n + 1)) { [weak self] in
            self?.applyPendingScroll(try: n + 1)
        }
    }

    /// The clip view's origin at the top of its document (content insets included), flipped or not.
    private static func top(_ sv: NSScrollView) -> CGFloat {
        let clip = sv.contentView, b = clip.bounds, flipped = sv.documentView?.isFlipped ?? true
        return clip.constrainBoundsRect(NSRect(x: b.minX, y: flipped ? -1e7 : 1e7, width: b.width, height: b.height)).minY
    }

    static func offset(_ sv: NSScrollView) -> Double {
        let flipped = sv.documentView?.isFlipped ?? true, y = sv.contentView.bounds.minY, t = top(sv)
        return Double(flipped ? y - t : t - y)
    }

    /// How far the overview (or a page of the hierarchy) can scroll down, its content insets included.
    static func room(_ sv: NSScrollView) -> Double {
        let clip = sv.contentView, b = clip.bounds, flipped = sv.documentView?.isFlipped ?? true
        let bottom = clip.constrainBoundsRect(NSRect(x: b.minX, y: flipped ? 1e7 : -1e7, width: b.width, height: b.height)).minY
        return Double(abs(bottom - top(sv)))
    }

    static func scroll(_ sv: NSScrollView, to y: Double) {
        let clip = sv.contentView, b = clip.bounds, flipped = sv.documentView?.isFlipped ?? true, t = top(sv)
        let want = flipped ? t + CGFloat(y) : t - CGFloat(y)
        let origin = clip.constrainBoundsRect(NSRect(x: b.minX, y: want, width: b.width, height: b.height)).origin
        clip.scroll(to: origin)
        sv.reflectScrolledClipView(clip)
    }
}

/// The overview's words (OVERVIEW-v2 §3.3, FEATURES OV-1), in English as the rest of the app: no counts in the first
/// sentence (the readout has them), the student by their first name, no gendered pronoun (UX.md §12).
enum OverviewText {
    /// "Mei" from "Mei Lin"; the whole name when it has one word.
    static func firstName(_ student: String) -> String {
        student.split(separator: " ").first.map(String.init) ?? student
    }

    /// "Thu, Oct 16" from an engine time; nil if unreadable. With the formatters made once (`HubText.formatter`).
    static func day(_ iso: String?) -> String? {
        Hierarchy.date(iso).map { HubText.format($0, "EEE, MMM d") }
    }

    /// "Files last changed Oct 10" when the student's files (`received`) were last changed on another day than the
    /// round's import: every "came in" and rail date is the import's (`created`), as Your Move, the timeline and the
    /// Student page say it, so the files' own day is said only where it is named so (review 2026-10-19).
    static func filesChanged(_ r: PaperOverview.Round) -> String? {
        guard let rec = r.received, let a = shortDate(rec), a != shortDate(r.created) else { return nil }
        return "Files last changed " + a
    }

    /// "one", "two", "three", then "several": small counts read as words in a sentence that does not count.
    static func few(_ n: Int) -> String {
        let words = ["none", "one", "two", "three"]
        return words.indices.contains(n) ? words[n] : "several"
    }

    /// The first sentence about the latest round (FEATURES OV-1): when it came in, what the student did with the open
    /// passages and whether they changed what no comment asked for; for a closed or failed round, what is next.
    static func firstSentence(_ d: PaperOverview?, student: String, fallback rounds: [RoundSummary] = [], errors: String? = nil) -> String {
        let name = firstName(student).isEmpty ? "The student" : firstName(student)
        guard let r = d?.latest else {
            // without the engine's overview: the latest round from the state
            guard let l = rounds.last else { return "" }
            let when = day(l.created).map { " on " + $0 } ?? ""
            if l.closed { return "Round \(l.n) went back to \(name)\(day(l.closedAt).map { " on " + $0 } ?? ""); nothing to do until the next round comes in." }
            if l.status == "failed" { return "Round \(l.n) came in\(when) but did not build" + (errors.map { ": " + $0 } ?? "") + "." }
            return "Round \(l.n) came in\(when)."
        }
        let when = day(r.created).map { " on " + $0 } ?? ""
        if r.isClosed {
            return "Round \(r.n) went back to \(name)\(day(r.closedAt).map { " on " + $0 } ?? ""); nothing to do until the next round comes in."
        }
        if r.failed { return "Round \(r.n) came in\(when) but did not build" + (errors.map { ": " + $0 } ?? "") + "." }
        if r.n == 1 { return "Round 1 came in\(when): the first draft." }
        var s = "Round \(r.n) came in\(when)."
        let c = r.comments ?? .init()
        if c.carried > 0 {
            let edited: String
            switch c.edited {
            case 0: edited = "\(name) edited none of the open passages"
            case c.carried: edited = "\(name) edited every open passage"
            case let e where e * 2 > c.carried: edited = "\(name) edited most open passages"
            default: edited = "\(name) edited some open passages"
            }
            s += " " + edited
            if c.noteOnly > 0 { s += (c.edited == 0 ? " but explained " : " and explained ") + few(c.noteOnly) + (c.noteOnly == 1 ? " in a note" : " in notes") }
        }
        let unasked = unaskedSections(r, d)
        if !unasked.isEmpty {
            let place = unasked.count == 1 ? "part of " + unasked[0] : unasked.count == 2 ? "parts of \(unasked[0]) and \(unasked[1])" : "parts of several sections"
            s += c.carried > 0 ? ", and changed \(place) that no comment asked about." : " \(name) changed \(place) that no comment asked about."
        } else if c.carried > 0 {
            s += "."
        }
        return s
    }

    /// A failed build's errors in a few words: "2 errors in methods.tex", "3 errors"; nil without any.
    static func errors(_ es: [BuildError]) -> String? {
        guard !es.isEmpty else { return nil }
        let files = Set(es.compactMap(\.file).map { ($0 as NSString).lastPathComponent })
        return count(es.count, "error") + (files.count == 1 ? " in " + files.first! : "")
    }

    /// The sections where the round has edits no comment asked for (not moves), by their titles in that round.
    static func unaskedSections(_ r: PaperOverview.Round, _ d: PaperOverview?) -> [String] {
        var out: [String] = []
        for e in r.edits ?? [] where e.unrequested && !e.move {
            guard let s = e.section, let t = d?.sectionTitle(s, round: r.n) ?? r.spans?.first(where: { $0.section == s })?.title
            else { continue }
            let name = shortTitle(t)
            if !out.contains(name) { out.append(name) }
        }
        return out
    }

    /// "Limitations" from "5 Limitations", "Dataset Details" from "A Dataset Details": the title without its number,
    /// as the Contents split it (`Outline.numbers`).
    static func shortTitle(_ t: String) -> String {
        guard let n = Outline.numbers([t]).first ?? nil else { return t }
        return String(t.dropFirst(n.count)).trimmingCharacters(in: .whitespaces)
    }

    /// The facts at the right of the header (OVERVIEW-v2 mockup): "**28 comments** · 4 rounds since Sep 8" over
    /// "19 resolved · 2 kept · 7 open · 12 pp · 6,520 words"; what is not known is left out.
    struct Facts: Equatable {
        var comments: String?
        var rounds: String?
        var details: [String] = []
    }

    static func facts(_ d: PaperOverview?, rounds: [RoundSummary], pages: Int?) -> Facts {
        var f = Facts()
        let n = d?.rounds.count ?? rounds.count
        if n > 0 { f.rounds = count(n, "round") + (shortDate(d?.rounds.first?.created ?? rounds.first?.created).map { " since " + $0 } ?? "") }
        if let c = d?.threads?.comments { f.comments = count(c, "comment") }
        if let t = d?.threads {
            if let r = t.resolved { f.details.append("\(r) resolved") }
            if let k = t.kept { f.details.append("\(k) kept") }
            if let o = t.open { f.details.append("\(o) open") }
        }
        // the pages and words of the round the strip shows: the latest that built (a failed one has none)
        let built = d.flatMap { d in MapRules.defaultStrip(d).flatMap { d.round($0) } }.flatMap { $0.failed ? nil : $0 }
        if let p = built?.build?.pages ?? pages, p > 0 { f.details.append("\(p) pp") }
        if let w = built?.words?.body { f.details.append(grouped(w) + " words") }
        return f
    }

    static func grouped(_ n: Int) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        f.usesGroupingSeparator = true
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }

    /// The toolbar's token and the panel's title for what the overview follows.
    static func following(_ s: OverviewItem, _ d: PaperOverview?) -> String {
        switch s {
        case .section(let id, let n): return d?.sectionTitle(id, round: n) ?? "Section"
        case .round(let n): return "Round \(n)"
        case .page(let n, let p): return "p.\(p + 1) of Round \(n)"
        case .comment(let id): return id
        case .tag(let id): return TagCatalog.current.name(id)
        }
    }
}
