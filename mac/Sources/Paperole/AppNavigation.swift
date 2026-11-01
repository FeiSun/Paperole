import AppKit

/// What Jump goes to that only Review shows: from the overview, Jump opens Review first (UX.md §21).
extension Jump.Target {
    var inReview: Bool {
        switch self {
        case .command(let c): return ![.newPaper, .addPaper, .newRound, .finalPDF].contains(c)
        default: return true
        }
    }
}

/// The window's navigation (UX.md §21; OVERVIEW-v2 §5.1, FEATURES OV-6): a paper's overview when it is clicked, Review
/// on a double click, Continue Round N or a double click in the overview (at that round, section, page or comment),
/// the round menu's All Rounds back to the overview, and one history across papers and levels (⌘[ ⌘]) whose entries
/// keep the overview's selection, strip round and scroll and Review's round and selection.
extension AppModel {
    // MARK: Places

    /// Review as it is now: the round shown, its selection and, while it is shown, the PDF's place.
    var reviewPlace: ReviewPlace {
        var r = ReviewPlace(round: round?.n, tab: tab, pdf: level == .review ? pdf.currentPlace() : nil)
        switch selection {
        case .comment(let id)?: r.comment = id
        case .change(let id)?: r.change = id
        case nil: break
        }
        return r
    }

    /// Where the window is, for the history.
    var place: NavPlace {
        NavPlace(paper: selectedPath, level: level, overview: overview.place, review: reviewPlace, hub: hub,
                 hubScroll: hub == nil ? 0 : hubModel.liveScroll ?? hubModel.scrolls[hub!] ?? 0)
    }

    /// Review left: its PDF steps fold into the place pushed, which keeps the PDF's place (PLAN §5.1).
    private func push() {
        guard selectedPath != nil || hub != nil else { return }
        if level == .review && hub == nil { navHistory.fold(paper: selectedPath) }
        navHistory.push(place)
    }

    /// A jump in the PDF leaves `at` (`PDFController.willJump`): a step of the window's history while in this Review.
    func recordPDFStep(_ at: PDFPlace) {
        guard selectedPath != nil, hub == nil, level == .review else { return }
        var p = place
        p.review.pdf = at
        navHistory.pushStep(p)
    }

    /// "p.4 · 2.1 Data": a place's page (0-based) and the Contents' section there; the page alone without Contents.
    func placeLabel(page: Int, x: Double, y: Double) -> String {
        let p = "p.\(page + 1)"
        let rows = reading.contents.rows
        guard let r = state?.reading,
              let b = Outline.current(rows, block: Reading.block(page: page, x: x, y: y, paragraphs: r.paragraphs, headings: r.headings)),
              let row = rows.first(where: { $0.block == b }) else { return p }
        return p + " · " + row.title
    }

    /// The PDF place Back (Forward) goes to while it is a step in the PDF, for the chip, the help tags and the page's menu.
    var backStep: PDFPlace? { navHistory.back.last.flatMap { $0.step ? $0.review.pdf : nil } }
    var forwardStep: PDFPlace? { navHistory.forward.last.flatMap { $0.step ? $0.review.pdf : nil } }

    /// A mouse's side buttons, anywhere in the review's window: back (button 3) and forward (4), as ‹ and ›.
    func sideButton(_ event: NSEvent) -> Bool {
        guard [3, 4].contains(event.buttonNumber), let w = event.window, Self.isReviewWindow(w), w.attachedSheet == nil
        else { return false }
        if event.buttonNumber == 3 { goBack() } else { goForward() }
        return true
    }

    // MARK: Going somewhere

    /// The sidebar: a click on a paper shows its overview; a double click (`level: .review`) Review. The paper's own
    /// row again changes only the level.
    func openPaper(_ path: String?, level l: Level = .overview) {
        guard let path else { return }
        if path == selectedPath && hub == nil {
            if l == .review { openReview() } else { showAllRounds() }
            return
        }
        if waitsForNote() {  // a new comment's note stays with its paper; the list shows this one selected again
            DispatchQueue.main.async { self.objectWillChange.send() }
            return
        }
        push()
        pendingReview = nil
        setHub(nil)
        if l == .review { setLevel(.review) }  // first, so the new paper's overview is not asked for
        selectPaper(path)
        setLevel(l)
    }

    /// A page of the hierarchy (UX.md §22): the sidebar's All Students, Your Move or a student, a Profile or a Back.
    /// The paper shown is left as for another paper (its editor saved, a note being written keeps it).
    func openHub(_ page: HubPage) {
        guard hub != page else { return }
        if selectedPath != nil && waitsForNote() {
            DispatchQueue.main.async { self.objectWillChange.send() }
            return
        }
        push()
        showHub(page, scroll: nil)
    }

    private func showHub(_ page: HubPage, scroll: Double?) {
        pendingReview = nil
        pendingFinish = nil
        if selectedPath != nil { selectPaper(nil) }
        guard selectedPath == nil else { return }
        setHub(page)
        hubModel.show(scroll: scroll)
        loadHub()
    }

    /// Your Move's button (FEATURES OV-8: it goes straight into Review): Continue, Show Log… (Review shows the log), or
    /// Finish Round N…, whose sheet opens once the paper's state is in.
    func moveAction(_ item: MoveItem) {
        openPaper(item.paper.path, level: .review)
        if item.status == .ready, selectedPath == item.paper.path { pendingFinish = item.paper.path }
    }

    /// A student page card's New Round… (UI v4): the paper selected first (its overview), then Start Round as from
    /// its toolbar.
    func startRound(_ path: String) {
        openPaper(path)
        guard selectedPath == path else { return }
        startRound()
    }

    /// Review at a position (OVERVIEW-v2 §5.1 "进审阅"): a double click on a cell, page, comment or round, the
    /// overview panel's Open in Review, the toolbar's Continue Round N (the latest round). From the overview, its
    /// place is pushed first, so Back returns to it as it was.
    func openReview(_ t: ReviewTarget = ReviewTarget()) {
        guard selectedPath != nil, !waitsForNote() else { return }
        if level != .review { push() }
        setLevel(.review)
        reveal(t)
    }

    /// Review as it was left, from the overview (Jump to something only Review shows).
    func enterReview() {
        guard selectedPath != nil, level != .review, !waitsForNote() else { return }
        push()
        setLevel(.review)
    }

    /// The round menu's All Rounds: this paper's overview, following what it followed, scrolled as it was.
    func showAllRounds() {
        guard selectedPath != nil, level != .overview, !waitsForNote() else { return }
        push()
        setLevel(.overview)
    }

    /// ⌘[, the toolbar's ‹, the chip under the page and a mouse's back button: in Review the PDF's steps first.
    func goBack() {
        guard !waitsForNote(), let p = navHistory.goBack(from: place) else { return }
        restore(p)
    }

    /// ⌘] and the toolbar's ›.
    func goForward() {
        guard !waitsForNote(), let p = navHistory.goForward(from: place) else { return }
        restore(p)
    }

    /// A place from the history: its paper (loaded again if another), its level, and the overview's place or Review's
    /// round, selection and PDF place. A step in the PDF puts back only the PDF's place. Going to Review leaves the
    /// overview of the same paper as it is, so All Rounds finds it as it was last left.
    private func restore(_ p: NavPlace) {
        pendingReview = nil
        pdf.endSteps()
        if let h = p.hub { return showHub(h, scroll: p.hubScroll) }
        setHub(nil)
        if p.paper != selectedPath {
            if p.level == .review { setLevel(.review) }
            selectPaper(p.paper)
            overview.restore(p.overview)
            setLevel(p.level)
            if p.level == .review { reveal(target(p.review)) }
        } else if p.level == .overview {
            overview.restore(p.overview)
            setLevel(.overview)
        } else {
            setLevel(.review)
            if !p.step && !p.review.sameSelection(reviewPlace) {
                reveal(target(p.review))
            } else if let at = p.review.pdf {
                pdf.go(to: at)
            }
        }
    }

    private func target(_ r: ReviewPlace) -> ReviewTarget {
        ReviewTarget(round: r.round, comment: r.comment, change: r.change, pdf: r.pdf, tab: r.tab)
    }

    // MARK: Review at a position

    /// Shows the target in Review: its round first (asked for when another is shown, then applied when its state
    /// comes), then the comment or change selected, the section's heading or the page shown.
    func reveal(_ t: ReviewTarget) {
        guard state != nil else {  // the paper's state is coming
            pendingReview = (t, false)
            return
        }
        // a round no longer there (a place kept from before): the latest
        let wanted = t.round.flatMap { r in state?.rounds.contains { $0.n == r } == true ? r : nil }
        if let n = wanted ?? latestRound?.n, n != round?.n, fixtureURL == nil {
            pendingReview = (t, true)
            showRound(n, follow: false)  // the target, not the place being read
            return
        }
        pendingReview = nil
        applyTarget(t)
    }

    /// Entering Review is a window step already: none of these moves records a PDF step (PLAN §5.2).
    private func applyTarget(_ t: ReviewTarget) {
        let selects = t.comment.map { comment($0) != nil } == true || t.change.map { change($0) != nil } == true
        if let id = t.comment, comment(id) != nil {
            if tab != .comments { tab = .comments }
            select(.comment(id), reveal: t.pdf == nil, scroll: .centre, step: nil)
        } else if let id = t.change, change(id) != nil {
            if tab != .changes { tab = .changes }
            select(.change(id), reveal: t.pdf == nil, scroll: .centre, step: nil)
        } else if t.pdf == nil, let title = t.section, let r = state?.reading, let h = Self.heading(title, in: r.headings) {
            // as a Contents click (`outlineOpen`), through `reveal`, which waits for the round's PDF to load
            let first = r.paragraphs.filter { $0.block > h.block }.min { $0.block < $1.block }
            if let part = h.parts.first(where: \.valid) ?? first?.parts.first(where: \.valid) {
                pdf.reveal(page: part.page, rects: [part.rect])
            }
            outlineFollow(h.block, hold: true)
        } else if t.pdf == nil, let p = t.page {
            pdf.reveal(page: p, rects: [])
        }
        // the tab it was left on, when nothing above chose one (a comment or change gone since); the Checks tab only
        // while Checks is on and Focus, which has no tabs, is not
        if !selects, let tb = t.tab, tb != tab, tb != .checks || (checksOn && !focus) { tab = tb }
        if let at = t.pdf { pdf.go(to: at) }  // Review as it was left: the PDF's place, after the selection
    }

    /// The first-level heading with this title (spaces and case aside), else any heading with it.
    nonisolated static func heading(_ title: String, in headings: [Heading]) -> Heading? {
        func norm(_ s: String) -> String { s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        let t = norm(title)
        return headings.first { $0.level == 1 && norm($0.title) == t } ?? headings.first { norm($0.title) == t }
    }

    /// After every applied state (`apply`): a position waiting for this round is shown, and the overview, while it is
    /// shown, is asked again when the paper may have changed.
    func navigationApplied(_ st: EngineState) {
        if let (t, asked) = pendingReview {
            let n = t.round ?? latestRound?.n
            if n == nil || n == st.round?.n || fixtureURL != nil {
                pendingReview = nil
                applyTarget(t)
            } else if !asked {
                reveal(t)
            }
        }
        if level == .overview { loadOverview() }
        openPendingFinish()
    }

    /// Your Move's Finish Round N… (`pendingFinish`), once the paper's latest round is shown in Review: the sheet opens
    /// when the engine is free (the round's paragraphs are found first after an engine update, and the sheet then opens
    /// with their state), and is dropped once it can no longer open (another paper, the overview, another round, the
    /// round closed).
    func openPendingFinish() {
        guard let p = pendingFinish else { return }
        guard p == selectedPath, level == .review, round?.n == latestRound?.n, roundIsOpen else {
            pendingFinish = nil
            return
        }
        guard !busy else { return }
        pendingFinish = nil
        DispatchQueue.main.async { [weak self] in self?.openFinish() }
    }

    // MARK: The overview

    /// A click in the overview follows the item (and moves the strip to its round); a double click opens Review there;
    /// nil (a click on the empty map, Esc, the token's ×) follows nothing.
    func overviewClicked(_ item: OverviewItem?, double: Bool = false) {
        if !double { overview.takeKeys() }  // a click in the overview gives the map the keys, as in any window's content
        // a click picks the round previewed under the pointer (a comment's point in its row keeps that round), and one
        // on its way goes
        if let p = overview.preview, overview.strip != p { overview.strip = p }
        overview.endPreview()
        guard let item else {
            if overview.selection != nil { overview.selection = nil }
            return
        }
        actions.tips.dismiss(.follow)  // the first follow: the tip has done its job
        if double { return openReview(reviewTarget(for: item)) }
        // something inside a folded part (a section, a page, a comment there): the part is shown first (VISUAL §5.1)
        if let d = overview.data {
            let inside = MapFold.parts(of: item, d).intersection(overview.foldedParts)
            if !inside.isEmpty { overview.shownParts.formUnion(inside) }
        }
        if overview.selection != item { overview.selection = item }
        if let n = stripRound(for: item), overview.strip != n { overview.strip = n }
        overview.stripScroll.follow(item, round: stripRound, data: overview.data)  // its page in view on the strip
        if let n = Self.round(of: item, overview.data), overview.folded.contains(n), !overview.unfold {
            overview.unfold = true
            overview.revealRow(n)
        }
    }

    /// The round an item is drawn in on the map (a comment's: the strip's round, where its point is), for unfolding.
    nonisolated static func round(of item: OverviewItem, _ d: PaperOverview?) -> Int? {
        switch item {
        case .section(_, let n), .round(let n), .page(let n, _): return n
        case .comment, .tag: return nil
        }
    }

    /// A key on the map (`MapKeys`): what it follows moves, and VoiceOver says where it is.
    @discardableResult
    func overviewMove(_ key: MapKeys.Key) -> Bool {
        overview.endPreview()  // a key picks from the strip's round, never the one previewed
        guard let d = overview.data, let mv = MapKeys.move(key, from: overview.selection, data: d, strip: stripRound) else { return false }
        overviewClicked(mv.item)
        if let s = mv.strip, overview.strip != s { overview.strip = s }
        if let n = Self.round(of: mv.item, d) ?? stripRound { overview.revealRow(n) }  // the row followed in view
        let text = MapSpeech.item(mv.item, d, strip: stripRound, student: OverviewText.firstName(state?.paper.student ?? ""))
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        return true
    }

    /// A folded part shown at its real length (its block clicked, Show under the axis, VoiceOver's action), or folded
    /// again (Fold under the axis): the map is drawn again at the new scale at once, without animation (VISUAL §5.1).
    func showPart(_ kind: FoldKind) {
        overview.takeKeys()
        if !overview.shownParts.contains(kind) { overview.shownParts.insert(kind) }
    }

    func foldPart(_ kind: FoldKind) {
        overview.takeKeys()
        if overview.shownParts.contains(kind) { overview.shownParts.remove(kind) }
    }

    /// The paper map shown as a table, or as the map again: the viewer's choice, kept (never by a test run).
    func setMapAsTable(_ on: Bool) {
        guard overview.asTable != on else { return }
        let keys = overview.hasKeys
        overview.asTable = on
        if fixtureURL == nil { Prefs.set(on, Self.mapAsTableKey) }
        if keys { DispatchQueue.main.async { [weak self] in self?.overview.takeKeys() } }  // the keys stay with the map
    }

    static let mapAsTableKey = "overviewMapAsTable"

    /// The round the thumbnail strip shows: the one picked, else the latest that built (a failed round has no pages).
    var stripRound: Int? { overview.strip ?? MapRules.defaultStrip(overview.data) ?? latestRound?.n }

    /// The round the strip shows and the map's box marks: the one previewed under the pointer, else `stripRound`.
    var shownStripRound: Int? { overview.preview ?? stripRound }

    /// The strip follows a cell's round (OVERVIEW-v2 §8 decision 6), a round's, a page's; a comment keeps the strip's
    /// round when it is there, else goes to the last round it has a page in (placed, or its passage deleted there).
    func stripRound(for item: OverviewItem) -> Int? {
        switch item {
        case .section(_, let n), .round(let n), .page(let n, _): return n
        case .comment(let id):
            return overview.data?.comment(id)?.shownRound(strip: stripRound)
        case .tag:
            return nil  // a tag is in every round: the strip stays
        }
    }

    /// Where Review opens for an overview item: a cell at its round and section (its heading, else its first page), a
    /// round, a page of a round, a comment in the strip's round when it is there (else its last round).
    func reviewTarget(for item: OverviewItem) -> ReviewTarget {
        switch item {
        case .section(let id, let n):
            let span = overview.data?.round(n)?.spans?.first { $0.section == id }
            return ReviewTarget(round: n, section: span?.title, page: span.map { Int($0.start.rounded(.down)) })
        case .round(let n):
            return ReviewTarget(round: n)
        case .page(let n, let p):
            return ReviewTarget(round: n, page: p)
        case .comment(let id):
            let c = overview.data?.comment(id)
            let n = stripRound(for: item)
            let step = n.flatMap { c?.step(in: $0) }
            return ReviewTarget(round: n, comment: id, page: step?.page)
        case .tag:
            return ReviewTarget()  // Review as it opens: the latest round
        }
    }

    /// The overview's keys: Esc follows nothing (OVERVIEW-v2 §5.1 "清除"); while the map has the keys (a click in the
    /// overview: `OverviewModel.hasKeys`), ← → ↑ ↓ move what it follows (`MapKeys`) and Return opens Review
    /// there, as a double click. Review's keys do nothing here, and the sidebar keeps its arrows while it has the keys.
    func overviewKey(_ event: NSEvent, mapHasKeys: Bool? = nil) -> Bool {
        if Self.keyName(event) == "esc" {
            guard overview.selection != nil else { return false }
            overview.selection = nil
            return true
        }
        guard mapHasKeys ?? overview.hasKeys, event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch event.keyCode {
        case 123: return overviewMove(.left)
        case 124: return overviewMove(.right)
        case 125: return overviewMove(.down)
        case 126: return overviewMove(.up)
        case 36, 76:
            guard let s = overview.selection else { return false }
            openReview(reviewTarget(for: s))
            return true
        default: return false
        }
    }

    /// Asks the engine for the selected paper's overview when it has none for it, or the paper may have changed since
    /// (`ledgerEdits`). The engine's reply comes after the state asked before it (one engine, in order); an engine
    /// without `overview` answers "Unknown method", and the overview then shows what the state says. A
    /// --overview-fixture is read instead; a --fixture run without one has none.
    func loadOverview(force: Bool = false) {
        guard let path = selectedPath else { return }
        if overview.paper != path { overview.reset(for: path) }
        let fresh = overview.version == ledgerEdits && [.loading, .loaded, .unavailable].contains(overview.status)
        guard force || !fresh else { return }
        let seq = overview.begin(version: ledgerEdits)
        if let file = options.overviewFixture {
            let result = Result { () throws -> PaperOverview in
                let reply = try PaperOverview.decodeReply(Data(contentsOf: URL(fileURLWithPath: file)))
                guard let o = (reply.papers.first { $0.path == path } ?? reply.papers.first)?.overview else {
                    throw EngineError(message: "The overview fixture has no paper.")
                }
                return o
            }
            if case .success(let o) = result { TagCatalog.learn(o.tagNames) }
            return overview.finish(seq, paper: path, result)
        }
        // with the marks of every round, for the thumbnails (CONTRACT amendment "Overview": a mark names its comment)
        var params: [String: Any] = ["papers": [path], "marks": true, "tag_order": tags.catalog.order]
        let keys = Self.keyPages(papers.filter { $0.path == path })  // the advisor's key page (TAGS.md §7)
        if !keys.isEmpty { params["key_pages"] = keys }
        guard fixtureURL == nil, let json = try? JSONSerialization.data(withJSONObject: params) else {
            return overview.unavailable(seq)
        }
        let id = engine.send("overview", params: json)
        Task {
            do {
                let reply = try PaperOverview.decodeReply(try await engine.result(id))
                let e = reply.papers.first { $0.path == path } ?? reply.papers.first
                guard let o = e?.overview else { throw EngineError(message: e?.error ?? "The engine sent no overview.") }
                thumbnails.refresh()  // a round may have been built again
                TagCatalog.learn(o.tagNames)
                overview.finish(seq, paper: path, .success(o))
                fillIn(path, o)  // its pending closed rounds, in the second engine process (FEATURES E1b)
            } catch {
                overview.finish(seq, paper: path, .failure(error))
            }
        }
    }

    /// The failed round's errors, as its state says ("2 errors in methods.tex"), when the state shown is that round's:
    /// the overview's first sentence and its failed row (and the debug items, which say what they draw).
    var overviewBuildErrors: String? {
        guard let r = round, r.build.status == "failed" || overview.data?.round(r.n)?.failed == true else { return nil }
        return OverviewText.errors(r.build.errors)
    }

    /// The overview is shown over Review: at the overview level, unless the paper has no round yet (Review's own
    /// page then says to start Round 1).
    var showsOverview: Bool { level == .overview && !(state?.rounds.isEmpty ?? false) }

    // MARK: The toolbar

    /// The overview's one button on the right (OVERVIEW-v2 §5.1: the toolbar's one Sage button is Continue Round N):
    /// Continue Round N while the latest round is open and built (prominent); Show Log… when it did not build (Review
    /// shows the log); Open Round N once it is closed.
    var continueButton: (title: String, prominent: Bool, round: Int)? {
        guard let l = latestRound else { return nil }
        if l.closed { return ("Open Round \(l.n)", false, l.n) }
        if l.status == "failed" { return ("Show Log…", false, l.n) }
        return ("Continue Round \(l.n)", true, l.n)
    }

    /// The paper page's header figure (UI v4, mac/UX.md §40.4): the shown paper's state, its changed paragraphs to read
    /// counted (`withReading`); none while its folder is missing.
    var paperHeader: PaperHeader? {
        guard let path = selectedPath, !missingPapers.contains(path),
              let s = (state?.summary ?? summaries[path]).map(withReading) else { return nil }
        return PaperHeader.make(PaperStatus.of(s, finished: papers.first { $0.path == path }?.finished), s, overview.data)
    }
}
