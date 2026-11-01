import AppKit
import PDFKit
import SwiftUI

/// Find in the paper (the advisor's request of 2026-10-26: revising, they need to find a word): a search field at the
/// end of Review's toolbar (Edit › Find in Paper…, ⌘F, puts the cursor in it). Typing searches the shown round's PDF
/// with PDFKit's find, any case and accents, on a queue of its own (`PaperSearcher`), so a long paper never holds up the
/// window. Every match is drawn in the find's neutral grey (`Palette.find`, no mark's colour), as the PDF view's
/// highlighted selections, unless a page has more than 25 (`FindRules.highlightsAll`: then only the current one): no
/// annotation, so the marks, a click on one and the reading bars are untouched. The current
/// match has the accent's outline, as a selected comment's mark (UX.md §5; the selection's own colour did not set it
/// apart: PDFKit draws it in its inactive grey while the field has the keys, and the system's selection colour follows
/// the Sage accent, a grey too), and is the PDF's selection, shown as a mark is (`PDFController.reveal`), so the
/// floating toolbar comments on it. "3 of 12" with ‹ › beside the field; Return and ⇧Return go on from it, wrapping; Esc
/// clears. Another round or paper keeps the query and finds it again there. Jump's "Find “boat” in the paper" and
/// Edit › Find Next / Previous in Paper (⌘G, ⇧⌘G) are this find too.

/// One match: its runs of characters in the pages' text (one, or one per page across a page break), as PDFKit's find
/// gave them, and its bounds on its first page (page space).
struct FindHit: Equatable, Sendable {
    struct Run: Equatable, Sendable {
        var page: Int
        var location: Int
        var length: Int
    }

    var runs: [Run]
    var bounds: CGRect = .zero
    var page: Int { runs.first?.page ?? 0 }
    var location: Int { runs.first?.location ?? 0 }
}

/// The find's rules, apart from PDFKit (the tests).
enum FindRules {
    /// A query worth searching for: anything but white space.
    static func searchable(_ q: String) -> Bool { !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The matches in the document's order: by page, then by where they begin in the page's text.
    static func ordered(_ hits: [FindHit]) -> [FindHit] {
        hits.enumerated().sorted { a, b in
            (a.element.page, a.element.location, a.offset) < (b.element.page, b.element.location, b.offset)
        }.map(\.element)
    }

    /// The match after `current` (before it, `previous`), wrapping.
    static func step(_ current: Int, count: Int, previous: Bool) -> Int {
        guard count > 0 else { return 0 }
        return (current % count + (previous ? count - 1 : 1)) % count
    }

    /// The first match at or after a place in the document's order (page, character), else the first: a query typed
    /// on stays on the match shown, or goes to the next one that still matches.
    static func start(_ hits: [FindHit], at place: (page: Int, location: Int)) -> Int? {
        guard !hits.isEmpty else { return nil }
        return hits.firstIndex { ($0.page, $0.location) >= (place.page, place.location) } ?? 0
    }

    /// The first match at or below a point of the view (`page`, and `y` in its page space, which grows upwards), from
    /// each match's page and top; with `previous` the one before it; wrapping.
    static func start(tops: [(page: Int, top: CGFloat)], page: Int, y: CGFloat, previous: Bool) -> Int? {
        guard !tops.isEmpty else { return nil }
        let i = tops.firstIndex { $0.page > page || $0.page == page && $0.top <= y + 1 } ?? 0
        return previous ? (i + tops.count - 1) % tops.count : i
    }

    /// Whether every match is highlighted: only while no page has more than `perPage` of them (and there are at most
    /// `total`). PDFKit spends about 1 ms on each highlight in view whenever it draws or is handed them, so one letter
    /// typed (some 250 matches a page, 7,900 in 32 pages) held the window up for 100 to 600 ms at a time (measured
    /// 2026-10-26); with more, only the current match is shown, with its outline.
    static let perPage = 25
    static let total = 1500
    static func highlightsAll(_ hits: [FindHit]) -> Bool {
        guard hits.count <= total else { return false }
        var pages: [Int: Int] = [:]
        for h in hits { pages[h.page, default: 0] += 1 }
        return (pages.values.max() ?? 0) <= perPage
    }

    /// Beside the field: "3 of 12", "12 matches" before one is shown, "No matches"; nothing while the first search of a
    /// query runs.
    static func counter(count: Int?, index: Int?) -> String {
        guard let count else { return "" }
        if count == 0 { return "No matches" }
        if let index, index < count { return "\(index + 1) of \(count)" }
        return count == 1 ? "1 match" : "\(count) matches"
    }
}

/// PDFKit's find on a queue of its own, in a document of its own made from the shown PDF's bytes: the same text, so its
/// ranges and bounds are the shown document's, while the shown one is drawn and marked on the main thread. A search
/// starts once the one before it has ended, and is skipped when a newer one was asked for meanwhile (typing on).
final class PaperSearcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Paperole.find", qos: .userInitiated)
    private let lock = NSLock()
    private var latest = 0  // the newest search asked for; under `lock`
    private var doc: (key: String, doc: PDFDocument)?  // only on `queue`

    /// The query's matches in the PDF whose bytes are `data` (`key` names them: the document is kept for the next
    /// search), in PDFKit's order; nil when a newer search was asked for before this one started.
    func search(_ q: String, in data: Data, key: String, generation: Int) async -> [FindHit]? {
        lock.withLock { latest = max(latest, generation) }
        return await withCheckedContinuation { cont in
            queue.async {
                guard self.lock.withLock({ self.latest == generation }) else { return cont.resume(returning: nil) }
                cont.resume(returning: self.find(q, data, key))
            }
        }
    }

    /// Searches asked for up to `generation` that have not started are skipped (the query cleared).
    func skip(through generation: Int) { lock.withLock { latest = max(latest, generation + 1) } }

    private func find(_ q: String, _ data: Data, _ key: String) -> [FindHit] {
        if doc?.key != key { doc = PDFDocument(data: data).map { (key, $0) } }
        guard let d = doc?.doc else { return [] }
        return d.findString(q, withOptions: [.caseInsensitive, .diacriticInsensitive]).compactMap { sel in
            let runs = sel.pages.flatMap { page -> [FindHit.Run] in
                let i = d.index(for: page)
                return (0..<sel.numberOfTextRanges(on: page)).map {
                    let r = sel.range(at: $0, on: page)
                    return FindHit.Run(page: i, location: r.location, length: r.length)
                }
            }
            guard !runs.isEmpty, let first = sel.pages.first else { return nil }
            return FindHit(runs: runs, bounds: sel.bounds(for: first))
        }
    }
}

/// The find's state, observed by the toolbar's field and its counter only (typing redraws nothing else).
@MainActor
final class PaperFind: ObservableObject {
    /// The field's text.
    @Published private(set) var query = ""
    /// The matches in the shown PDF; nil before the query's first search is in (or with no query).
    @Published private(set) var count: Int?
    /// The current match, from 0; nil before one is shown (a new round, a paper) or once the query is cleared.
    @Published private(set) var index: Int?

    /// The find bar is out over the PDF (FindBar): ⌘F or its button opens it, Esc or its × closes it; a query set from
    /// outside (Jump, a debug script) opens it too.
    @Published private(set) var open = false

    var counter: String { FindRules.counter(count: count, index: index) }

    weak var controller: PDFController?
    /// The find bar's field, for ⌘F.
    weak var field: NSSearchField?

    private let searcher = PaperSearcher()
    private var hits: [FindHit] = []
    /// The matches as selections in the shown document, in `hits`' order and the find's colour: laid a slice at a
    /// time (`lay`), as reading a page's text in the shown document for the first time costs some 15 ms, and only when
    /// they are not too many to highlight (`FindRules.highlightsAll`); the current one at once.
    private var matches: [PDFSelection?] = []
    private var laid = 0
    private var generation = 0
    private var searching = false
    /// What to do once the search is in: show the first match from the place being read, or go on.
    private var wanted: Go?
    /// What the first match is for Back (PLAN §5.2): a look-up whose next matches go with it, or nil (Jump's find
    /// opened Review, a window step already).
    private var firstStep: PDFSteps.Kind? = .find
    private var pause: Timer?
    /// The current match's outline: a view over the PDF (`OutlineView`), so no page is redrawn.
    private var ring: OutlineView?

    enum Go { case first, start, next, previous }

    /// Each match's page and bounds there (page space), for the markers beside the scroller.
    var hitPlaces: [(page: Int, bounds: CGRect)] { hits.map { ($0.page, $0.bounds) } }

    /// A click on a match's marker beside the scroller: that match, as Find's first one (a step of Back that its next
    /// matches go on from, PLAN §5.2).
    func goTo(_ i: Int) { show(i, step: .find) }

    private var view: ReviewPDFView? { controller?.view }

    /// The field's text changed: searched for after a pause in typing (0.15 s); then the match shown, while it is on
    /// screen, or the next that still matches, else the first at or below the top of the view, becomes the current one.
    func type(_ q: String) {
        guard q != query else { return }
        if !q.isEmpty && !open { open = true }
        firstStep = .find
        set(q, delay: 0.15)
    }

    /// Jump's "Find “boat” in the paper": the query in the field and searched at once; the same query again goes on to
    /// the next match. `fromStart` (the PDF's menu, "Find “β” in Paper"): its first match in the paper, its first use.
    /// `step`: what the move is for Back; nil when it opened Review.
    func find(_ q: String, fromStart: Bool = false, step: PDFSteps.Kind? = .find) {
        if !open { open = true }
        firstStep = step
        if q == query, count != nil, !searching {
            if fromStart && !hits.isEmpty { return show(0, step: step) }
            return go(.next, step: step == nil ? nil : .run)
        }
        set(q, delay: 0)
        if fromStart, FindRules.searchable(q) { wanted = .start }
    }

    /// Return or ›, ⇧Return or ‹ (⌘G, ⇧⌘G): the match after the current one (before it), wrapping; with none shown
    /// yet (another round), the first at or below the top of the view (the one before it). Asked for while the search
    /// runs, once it is in.
    func step(previous: Bool) {
        guard FindRules.searchable(query) else { return }
        if searching || count == nil {
            wanted = previous ? .previous : .next
            if !searching { search(delay: 0) }
            return
        }
        go(previous ? .previous : .next)
    }

    /// Esc, the field's ⊗, or the field emptied: no query, no highlights; the current match, while it is still the
    /// selection, is deselected.
    func clear() {
        query = ""
        dropMatches()
    }

    /// Before another PDF is shown: the highlights and the outline, which are the old document's, go before it does,
    /// with the match's selection while it is still the PDF's.
    func documentWillChange() {
        if index.map(stillSelected) == true { controller?.clearSelection() }
        view?.highlightedSelections = nil
        ring?.removeFromSuperview()
        ring = nil
    }

    /// Another PDF is shown (a round, a paper, a build again): its matches are found again, and none is shown until
    /// Return (the PDF opens where it opens: a comment, the last place).
    func documentChanged() {
        pause?.invalidate()
        generation += 1
        searching = false
        hits = []
        matches = []
        laid = 0
        if index != nil { index = nil }
        view?.highlightedSelections = nil
        placeRing()
        controller?.updateStrip()
        guard FindRules.searchable(query) else { return }
        if count != nil { count = nil }
        wanted = nil
        search(delay: 0)
    }

    /// ⌘F or the bar's button: the bar out, the cursor in its field, its text selected, so typing replaces it.
    func focusField() {
        if !open { open = true }
        guard let f = field, let w = f.window else {  // the bar just opened: once its field is in the window
            DispatchQueue.main.async { [weak self] in
                guard let self, let f = self.field, let w = f.window else { return }
                w.makeFirstResponder(f)
                f.currentEditor()?.selectAll(nil)
            }
            return
        }
        w.makeFirstResponder(f)
        f.currentEditor()?.selectAll(nil)
    }

    /// Esc in the field or the bar's ×: no query, the bar back to its button, the keys back to the PDF.
    func close() {
        clear()
        leaveField()
        if open { open = false }
    }

    /// Esc in the field: the keys go back to the PDF.
    func leaveField() {
        guard let v = view, let w = v.window, !(controller?.reviewHidden ?? false) else { return }
        w.makeFirstResponder(v)
    }

    // MARK: Searching

    private func set(_ q: String, delay: TimeInterval) {
        query = q
        guard FindRules.searchable(q) else { return dropMatches() }  // only white space: nothing to find
        wanted = .first
        search(delay: delay)
    }

    /// No search runs or waits, and the matches go: their highlights, and the current one while it is still selected.
    private func dropMatches() {
        let selected = index.map(stillSelected) ?? false
        pause?.invalidate()
        generation += 1
        searcher.skip(through: generation)
        searching = false
        wanted = nil
        hits = []
        matches = []
        laid = 0
        if count != nil { count = nil }
        if index != nil { index = nil }
        view?.highlightedSelections = nil
        placeRing()
        if selected { controller?.clearSelection() }
        controller?.updateStrip()
    }

    private func search(delay: TimeInterval) {
        pause?.invalidate()
        generation += 1
        let g = generation, q = query
        guard let data = controller?.loadedData, let key = controller?.documentKey else { return }
        searching = true
        let run = { [weak self] in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let found = await self.searcher.search(q, in: data, key: key, generation: g)
                guard let found, g == self.generation, self.controller?.documentKey == key else { return }
                self.found(found, generation: g)
            }
        }
        if delay > 0 {
            pause = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in MainActor.assumeIsolated { run() } }
        } else {
            run()
        }
    }

    private func found(_ new: [FindHit], generation g: Int) {
        searching = false
        guard let v = view, v.document != nil else { return }
        // where a query typed on starts: the match shown, while it is on screen
        let from = index.flatMap { i in i < hits.count && onScreen(i) ? (hits[i].page, hits[i].location) : nil }
        hits = FindRules.ordered(new)
        controller?.updateStrip()
        matches = Array(repeating: nil, count: hits.count)
        laid = 0
        count = hits.count
        index = nil
        v.highlightedSelections = nil
        placeRing()
        let w = wanted
        wanted = nil
        guard !hits.isEmpty else {
            if w != nil { announce("“\(query)” is not in the paper") }
            return
        }
        // the first match is a look-up, a step of Back; typing on from a match shown, and Return, go on with it
        switch w {
        case .first: show(from.flatMap { FindRules.start(hits, at: $0) } ?? fromTop(previous: false),
                          step: from == nil || firstStep == nil ? firstStep : .run)
        case .start: show(0, step: firstStep)
        case .next: show(fromTop(previous: false))
        case .previous: show(fromTop(previous: true))
        case nil: break
        }
        if FindRules.highlightsAll(hits) { lay(g) } else { laid = hits.count }  // too many: the current one alone
    }

    /// Lays the matches' highlights, about 12 ms of work at a time with the window's events between, so a long paper's
    /// first find never holds up a scroll or a key.
    private func lay(_ g: Int) {
        guard g == generation, let v = view, let doc = v.document else { return }
        let start = ProcessInfo.processInfo.systemUptime
        while laid < hits.count && ProcessInfo.processInfo.systemUptime - start < 0.012 {
            if matches[laid] == nil { matches[laid] = selection(hits[laid], in: doc) }
            laid += 1
        }
        let all = matches.compactMap { $0 }
        v.highlightedSelections = all.isEmpty ? nil : all
        if laid < hits.count { DispatchQueue.main.async { [weak self] in self?.lay(g) } }
    }

    private func go(_ g: Go, step: PDFSteps.Kind? = .run) {
        guard !hits.isEmpty else { return announce("“\(query)” is not in the paper") }
        if let i = index, i < hits.count {
            show(FindRules.step(i, count: hits.count, previous: g == .previous), step: step)
        } else {
            show(fromTop(previous: g == .previous), step: step)
        }
    }

    /// The match as a selection in the shown document, in the find's colour; nil when its text is not there.
    private func selection(_ h: FindHit, in doc: PDFDocument) -> PDFSelection? {
        var out: PDFSelection?
        for r in h.runs {
            guard r.page >= 0, r.page < doc.pageCount, let page = doc.page(at: r.page), r.location >= 0, r.length > 0,
                  r.location + r.length <= page.numberOfCharacters,
                  let s = page.selection(for: NSRange(location: r.location, length: r.length)) else { return nil }
            if let o = out { o.add(s) } else { out = s }
        }
        out?.color = Palette.find
        return out
    }

    /// The first match at or below the top of the view (the one before it), wrapping.
    private func fromTop(previous: Bool) -> Int? {
        guard let v = view, let doc = v.document else { return nil }
        let top = CGPoint(x: v.bounds.midX, y: v.bounds.maxY - 1)
        let topPage = v.page(for: top, nearest: true)
        let ti = topPage.map { doc.index(for: $0) } ?? 0, ty = topPage.map { v.convert(top, to: $0).y } ?? .infinity
        return FindRules.start(tops: hits.map { ($0.page, $0.bounds.maxY) }, page: ti, y: ty, previous: previous)
    }

    /// The match becomes the current one, with its outline, and the PDF's selection, and is shown as a mark is:
    /// scrolled to a third of the way down when it is off screen, then flashed. The floating toolbar comes back once the
    /// scroll has settled (as for Jump's find, UX.md §7). `step`: what the move is for Back (PLAN §5.2).
    private func show(_ i: Int?, step: PDFSteps.Kind? = .run) {
        guard let i, i < hits.count, let c = controller, let v = view, let doc = v.document else { return }
        if matches[i] == nil { matches[i] = selection(hits[i], in: doc) }
        guard let sel = matches[i]?.copy() as? PDFSelection, let page = sel.pages.first else { return }
        index = i
        placeRing()
        c.updateLaneHalo()  // the column's Sage tick follows the current match
        v.setCurrentSelection(sel, animate: false)
        let cb = page.bounds(for: .cropBox)
        let lines = sel.selectionsByLine().map { $0.bounds(for: page) }.filter { !$0.isEmpty }
        c.reveal(page: doc.index(for: page), rects: (lines.isEmpty ? [sel.bounds(for: page)] : lines)
            .map { Geometry.contractRect($0, cropBox: cb) }, step: step)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak c] in
            if c?.model?.hasPDFSelection == true { c?.showToolbar() }
        }
        announce(counter)
    }

    /// Lays the current match's outline again (a new match, a zoom, Focus), as a selected comment's (SelectionOutline,
    /// UX.md §5); none without a current match. It stays when a click elsewhere clears the selection: Return goes on from
    /// it.
    func placeRing() {
        guard let i = index, i < matches.count, let sel = matches[i], let page = sel.pages.first, let v = view else {
            ring?.removeFromSuperview()
            ring = nil
            return
        }
        let lines = sel.selectionsByLine().map { $0.bounds(for: page) }.filter { !$0.isEmpty }
        let o = ring ?? OutlineView(width: 2)
        if !o.place(SelectionOutline.boxes(lines: lines.isEmpty ? [sel.bounds(for: page)] : lines, label: nil), on: page, in: v) {
            o.removeFromSuperview()
        }
        ring = o
    }

    /// The current match is the PDF's selection: the floating toolbar is its Comment button alone (BRIEF E5).
    var currentIsSelection: Bool { index.map(stillSelected) ?? false }

    /// The line match `i` is in (PDFKit's line selection at it), cut so the match stays in view: the column's window
    /// (BRIEF §5.2).
    func matchLine(_ i: Int) -> LaneMatchLine {
        guard i < hits.count, i < matches.count, let doc = view?.document else { return LaneMatchLine() }
        if matches[i] == nil { matches[i] = selection(hits[i], in: doc) }
        guard let sel = matches[i], let page = sel.pages.first, let word = sel.string, !word.isEmpty else { return LaneMatchLine() }
        let b = sel.bounds(for: page)
        guard let line = page.selectionForLine(at: CGPoint(x: b.minX + 0.5, y: b.midY)), let text = line.string,
              line.numberOfTextRanges(on: page) > 0, sel.numberOfTextRanges(on: page) > 0 else { return LaneMatchLine(match: word) }
        let ns = text as NSString, at = sel.range(at: 0, on: page).location - line.range(at: 0, on: page).location
        let len = sel.range(at: 0, on: page).length
        guard at >= 0, at + len <= ns.length else { return LaneMatchLine(match: word) }
        func clean(_ s: String) -> String { s.replacingOccurrences(of: "\n", with: " ") }
        let joined = clean(ns.substring(to: at)) + clean(ns.substring(with: NSRange(location: at, length: len)))
        let start = joined.index(joined.startIndex, offsetBy: clean(ns.substring(to: at)).count)
        var after = clean(ns.substring(from: at + len))
        while after.last?.isWhitespace == true { after.removeLast() }  // the line's end, never the space after the match
        let full = joined + after
        return LaneMatchLine.cut(full, match: start..<full.index(start, offsetBy: joined.distance(from: start, to: joined.endIndex)))
    }

    /// Whether the match is still the PDF's selection (a click elsewhere has not replaced it).
    private func stillSelected(_ i: Int) -> Bool {
        guard let v = view, let doc = v.document, let cur = v.currentSelection, i < hits.count, let page = cur.pages.first,
              doc.index(for: page) == hits[i].page else { return false }
        return hits[i].bounds.insetBy(dx: -1, dy: -1).contains(cur.bounds(for: page))
    }

    private func onScreen(_ i: Int) -> Bool {
        guard let v = view, let doc = v.document, i < hits.count, let page = doc.page(at: hits[i].page) else { return false }
        return v.bounds.intersects(v.convert(hits[i].bounds, from: page))
    }

    private func announce(_ text: String) {
        guard !text.isEmpty, let w = view?.window else { return }
        NSAccessibility.post(element: w, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    // MARK: Tests and --debug-script

    /// The highlighted matches as drawn: their number, and whether each is in the shown document.
    var highlighted: (count: Int, inShownDocument: Bool) {
        let h = view?.highlightedSelections ?? []
        let doc = view?.document
        return (h.count, h.allSatisfy { $0.pages.allSatisfy { $0.document === doc } })
    }

    /// Whether the current match's outline is over the PDF.
    var ringShown: Bool { ring?.superview != nil && ring?.superview === view?.documentView }

    /// Whether a search runs or waits for a pause in typing, or its highlights are still being laid.
    var isSearching: Bool { searching || laid < hits.count }
}

/// The find, over the PDF's top right corner (the advisor's request of 2026-10-29: in the toolbar it sat far from the
/// page it searches): a small round button while closed; open, a bar with the search field, "3 of 12", ‹ › and ×.
/// It keeps its width whatever it shows, so nothing moves as a query is typed or cleared. Only a round with a PDF has
/// one (PaperView).
struct FindBar: View {
    @ObservedObject var find: PaperFind

    static let fieldWidth: CGFloat = 190
    static let counterWidth: CGFloat = 64

    var body: some View {
        Group {
            if find.open {
                // a fade alone with Reduce Motion (BRIEF E11)
                bar.transition(Motion.reduced ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
            } else {
                button.transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: find.open)
    }

    private var button: some View {
        Button { find.focusField() } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Ink.secondary)
                .frame(width: 30, height: 30)
                .background(Color(nsColor: .windowBackgroundColor), in: Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Find in Paper (⌘F)")
        .accessibilityLabel("Find in Paper")
    }

    private var bar: some View {
        let on = !find.query.isEmpty
        return HStack(spacing: 6) {
            FindField(find: find)
                .frame(width: Self.fieldWidth)
            Text(find.counter)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Ink.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: Self.counterWidth, alignment: .center)
                .accessibilityHidden(!on)
            Button { find.step(previous: true) } label: { Image(systemName: "chevron.up") }
                .help("Previous match (⇧Return in the field, ⇧⌘G)")
                .accessibilityLabel("Previous match")
                .disabled((find.count ?? 0) == 0)
            Button { find.step(previous: false) } label: { Image(systemName: "chevron.down") }
                .help("Next match (Return in the field, ⌘G)")
                .accessibilityLabel("Next match")
                .disabled((find.count ?? 0) == 0)
            Button { find.close() } label: { Image(systemName: "xmark") }
                .help("Close (Esc)")
                .accessibilityLabel("Close Find")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        // solid, not a material: over the white page a material went a muddy grey in dark mode
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.14), radius: 6, y: 2)
    }
}

/// The search field: an AppKit field, so Return, ⇧Return and Esc reach the find (the field editor takes them from a
/// SwiftUI field).
struct FindField: NSViewRepresentable {
    @ObservedObject var find: PaperFind

    func makeCoordinator() -> Coordinator { Coordinator(find: find) }

    func makeNSView(context: Context) -> NSSearchField {
        let f = NSSearchField()
        f.placeholderString = "Find in Paper"
        f.sendsSearchStringImmediately = true
        f.sendsWholeSearchString = false
        f.cell?.usesSingleLineMode = true
        f.lineBreakMode = .byTruncatingTail
        f.delegate = context.coordinator
        f.target = context.coordinator
        f.action = #selector(Coordinator.searched(_:))
        f.setAccessibilityLabel("Find in Paper")
        find.field = f
        return f
    }

    /// The query set from outside the field (Jump, a clear, a debug script): the field shows it.
    func updateNSView(_ f: NSSearchField, context: Context) {
        if f.stringValue != find.query { f.stringValue = find.query }
        if find.field !== f { find.field = f }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let find: PaperFind
        init(find: PaperFind) { self.find = find }

        func controlTextDidChange(_ n: Notification) {
            guard let f = n.object as? NSTextField else { return }
            MainActor.assumeIsolated { changed(f.stringValue) }
        }

        /// The field's action: typing, and its ⊗ (which empties it without a text change).
        @objc func searched(_ sender: NSSearchField) {
            MainActor.assumeIsolated { changed(sender.stringValue) }
        }

        @MainActor private func changed(_ text: String) {
            if text.isEmpty { if !find.query.isEmpty { find.clear() } } else { find.type(text) }
        }

        /// ⇧Return reaches the field as Return does (insertNewline:); the event says which.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            MainActor.assumeIsolated { command(sel, shift: NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false) }
        }

        /// Return goes to the next match and ⇧Return to the one before; Esc clears the find, closes the bar and gives
        /// the keys back to the PDF.
        @MainActor func command(_ sel: Selector, shift: Bool) -> Bool {
            switch sel {
            case #selector(NSResponder.insertNewline(_:)):
                find.step(previous: shift)
            case #selector(NSResponder.cancelOperation(_:)):
                find.close()
            default: return false
            }
            return true
        }
    }
}

/// Edit › Find in Paper… (⌘F), Find Next in Paper (⌘G) and Find Previous in Paper (⇧⌘G), in Review: they observe the
/// find, which the window does not.
struct FindCommands: View {
    @ObservedObject var model: AppModel
    @ObservedObject var find: PaperFind

    var body: some View {
        let review = model.level == .review && model.round?.build.pdf != nil
        Button("Find in Paper…") { find.focusField() }.keyboardShortcut("f")
            .disabled(!review)
        Button("Find Next in Paper") { model.findInPaper() }.keyboardShortcut("g")
            .disabled(find.query.isEmpty || !review)
        Button("Find Previous in Paper") { model.findInPaper(previous: true) }.keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(find.query.isEmpty || !review)
    }
}
