import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Paperole

/// The app model's fixes of the 2026-10-24 review (batch B6): an answer's toast and keys stay with its paper; Review's
/// keys only in the review window; Your Move's Finish waits for the engine; drafts follow a paper put back elsewhere and
/// the quit question names only listed papers' drafts; the readable paragraphs are the state's; Jump; the Finish
/// sheet's refusals; the toast held under the pointer; a change's Show all; the fold setting redraws the map; a reply
/// asked before Mark as Finished keeps the mark. Synthetic fixtures and temporary folders only.
@MainActor
final class ModelFixTests: XCTestCase {
    private var tmp: URL!
    private var fm: FileManager { .default }

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("pc-modelfix-" + UUID().uuidString)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: tmp)
    }

    private func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    /// Waits (at most 10 s) until `done`.
    private func waitUntil(_ done: () -> Bool) async throws {
        for _ in 0..<200 {
            if done() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func makeModel(_ fixture: String = "state-m2a.json") -> AppModel {
        _ = NSApplication.shared
        var o = LaunchOptions()
        o.fixture = StepTests.fixtures.appendingPathComponent(fixture).path
        o.drafts = tmp.appendingPathComponent("drafts").path
        return AppModel(options: o)
    }

    /// The fixture's state, changed as the engine would send it.
    private func state(_ fixture: String = "state-m2a.json", _ change: (inout [String: Any]) -> Void) throws -> EngineState {
        let url = StepTests.fixtures.appendingPathComponent(fixture)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        change(&json)
        return try EngineState.decode(JSONSerialization.data(withJSONObject: json))
    }

    private func unreviewed(replaceable: Bool = true) throws -> EngineState {
        try state { json in
            json["comments"] = [] as [Any]
            var summary: [String: Any] = ["round": 2, "closed": false, "status": "ok", "to_judge": 0, "to_check": 1]
            summary["replaceable"] = replaceable
            json["summary"] = summary
        }
    }

    func testPaperMenuFinishesWithoutCommentsOrReadyStatus() throws {
        let m = makeModel()
        m.apply(try unreviewed())
        let path = try XCTUnwrap(m.selectedPath)
        XCTAssertNotNil(m.openRoundSummary(path))
        XCTAssertFalse(m.readyToFinish, "unchecked edits need not prevent finishing")
        m.openRoundAction(path, replace: false)
        spin(0.05)
        XCTAssertTrue(m.showFinish)
        XCTAssertFalse(m.showRetry)
    }

    func testPaperMenuReplacementWaitsForTheTargetPaper() throws {
        let m = makeModel(), target = tmp.appendingPathComponent("other-paper").path
        let original = try XCTUnwrap(m.selectedPath), reviewed = try XCTUnwrap(m.state)
        let fresh = try unreviewed()
        m.selectPaper(target, state: fresh)
        m.selectPaper(original, state: reviewed)
        XCTAssertEqual(m.openRoundSummary(target)?.replaceable, true)
        XCTAssertFalse(m.canBuildAgain, "the selected paper already has comments")
        m.openRoundAction(target, replace: true)
        XCTAssertEqual(m.selectedPath, target)
        XCTAssertEqual(m.pendingReplace, target)
        XCTAssertFalse(m.showRetry)
        m.apply(fresh)
        spin(0.05)
        XCTAssertTrue(m.showRetry)
        XCTAssertTrue(m.retryReplacingDraft)
        XCTAssertFalse(m.showFinish)
    }

    func testReplacementChecksFreshEligibilityAndUnsentDrafts() throws {
        let m = makeModel(), path = try XCTUnwrap(m.selectedPath)
        m.apply(try unreviewed(replaceable: false))
        XCTAssertFalse(m.canBuildAgain, "the engine may know about notes on automatic checks")
        m.openRoundAction(path, replace: true)
        spin(0.05)
        XCTAssertFalse(m.showRetry)
        XCTAssertNotNil(m.alertMessage)
        m.apply(try unreviewed())
        m.setDraft("R1-01", "An unsent explanation")
        m.openRoundAction(path, replace: true)
        spin(0.05)
        XCTAssertFalse(m.showRetry)
    }

    func testQueuedPaperActionsCannotOpenOnAnotherPaper() throws {
        for replace in [false, true] {
            let m = makeModel(), path = try XCTUnwrap(m.selectedPath)
            m.apply(try unreviewed())
            m.openRoundAction(path, replace: replace)
            m.selectPaper(tmp.appendingPathComponent("different-paper").path, state: try unreviewed())
            spin(0.05)
            XCTAssertFalse(m.showRetry)
            XCTAssertFalse(m.showFinish)
            XCTAssertNil(m.pendingReplace)
            XCTAssertNil(m.pendingFinish)
        }
    }

    func testReplacementCanRetryAFailedBuildAndUsesItsOwnSheetTitle() throws {
        let m = makeModel(), path = try XCTUnwrap(m.selectedPath)
        m.apply(try state { json in
            json["comments"] = [] as [Any]
            var r = json["round"] as? [String: Any] ?? [:]
            var build = r["build"] as? [String: Any] ?? [:]
            build["pdf"] = NSNull(); build["status"] = "failed"
            r["build"] = build; json["round"] = r
        })
        XCTAssertFalse(m.canFinish)
        m.openRoundAction(path, replace: true)
        spin(0.05)
        XCTAssertTrue(m.showRetry)
        XCTAssertEqual(RetrySheet.title(m.latestRound, replacing: m.retryReplacingDraft), "Replace Draft")
        m.showRetry = false
        m.openRetry()
        XCTAssertFalse(m.retryReplacingDraft)
        XCTAssertEqual(RetrySheet.title(m.latestRound), "Build Round 2 Again")
    }

    func testReplaceDraftSheetRenders() throws {
        let m = makeModel()
        m.apply(try unreviewed())
        m.openRetry(replacingDraft: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 350),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let host = NSHostingView(rootView: RetrySheet().environmentObject(m)
                .environment(\.colorScheme, name == "dark" ? .dark : .light)
                .background(Color(nsColor: .windowBackgroundColor)))
            host.appearance = NSAppearance(named: appearance)
            window.appearance = host.appearance
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: 560, height: 350)
            host.layoutSubtreeIfNeeded()
            spin(0.05)
            if let directory = ProcessInfo.processInfo.environment["PAPEROLE_ROUND_CAPTURE"],
               let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.effectiveAppearance.performAsCurrentDrawingAppearance {
                    host.cacheDisplay(in: host.bounds, to: rep)
                }
                try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("replace-draft-\(name).png"))
            }
        }
    }

    // MARK: A1-01

    /// Another paper opened while the engine answered (its state not in yet): the answer's draft and undo step stay with
    /// the paper answered, but its toast (whose Undo would act on the paper shown), the next card and the click guard
    /// do not come to the paper shown now.
    func testAnAnswerForAPaperLeftShowsNothingHere() throws {
        let m = makeModel()
        let key = try XCTUnwrap(m.draftsKey)
        m.select(.comment("R1-06"))
        m.selectPaper("/Users/advisor/Reviews/another")
        XCTAssertNil(m.state)
        m.answered("R1-06", before: Answer(), after: Answer(verdict: "verified"), on: key, advance: true)
        XCTAssertNil(m.panelToast.text, "no Undo for another paper's answer")
        XCTAssertEqual(m.history.undos.map(\.id), ["R1-06"], "the step is kept for the paper answered")
        XCTAssertFalse(m.clickIgnored("R1-06"))
        XCTAssertNil(m.selection)
    }

    /// The same answer on the paper shown still has its toast (the flow of AnswerFlowTests).
    func testAnAnswerOnThePaperShownHasItsToast() {
        let m = makeModel()
        m.select(.comment("R1-06"))
        m.answered("R1-06", before: Answer(), after: Answer(verdict: "verified"), on: m.draftsKey, advance: true)
        XCTAssertEqual(m.panelToast.text, "R1-06 resolved")
        XCTAssertEqual(m.panelToast.action, .undo)
    }

    // MARK: A1-02

    /// Review's single keys act in the review window only (its closing quits: `QuitOnClose`), never in Settings, which
    /// SwiftUI also makes the main window while it is key.
    func testKeysAreTheReviewWindowsOnly() {
        _ = NSApplication.shared
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered,
                         defer: true)
        w.isReleasedWhenClosed = false
        XCTAssertFalse(AppModel.isReviewWindow(w), "a window of its own, as Settings")
        QuitOnClose.install(on: w, quit: {})
        XCTAssertTrue(AppModel.isReviewWindow(w))
        w.close()
    }

    // MARK: A1-04

    /// Your Move's Finish Round N…: while the engine works on (the round's paragraphs found first, after an engine
    /// update) the sheet waits, and opens with the state after; it is dropped once it can no longer open.
    func testYourMovesFinishWaitsForTheEngine() throws {
        let m = makeModel()
        let path = try XCTUnwrap(m.selectedPath)
        let st = try XCTUnwrap(m.state)
        m.pendingFinish = path
        m.holdBusy(true)
        m.apply(st)
        spin(0.05)
        XCTAssertEqual(m.pendingFinish, path, "kept while the engine works")
        XCTAssertFalse(m.showFinish)
        m.holdBusy(false)
        m.apply(st)
        spin(0.05)
        XCTAssertNil(m.pendingFinish)
        XCTAssertTrue(m.showFinish, "the sheet opens with the next state")
        m.showFinish = false
        // the round closed meanwhile: it can no longer open
        m.pendingFinish = path
        m.apply(try state { json in
            var r = json["round"] as? [String: Any] ?? [:]
            r["closed"] = true
            json["round"] = r
        })
        spin(0.05)
        XCTAssertNil(m.pendingFinish)
        XCTAssertFalse(m.showFinish)
        // another paper: dropped
        m.pendingFinish = path
        m.selectPaper("/Users/advisor/Reviews/another")
        XCTAssertNil(m.pendingFinish)
    }

    // MARK: A1-05, A5b-06

    /// A paper put back at a new place takes its unsent drafts there; the quit question names only the drafts of
    /// listed papers (Use This Copy parks the replaced copy's drafts under its unlisted path).
    func testDraftsFollowAPutBackAndQuitNamesListedOnly() throws {
        let m = makeModel()
        XCTAssertNil(m.unsentDraftsQuestion())
        let old = "/Users/advisor/Reviews/lost", new = "/Users/advisor/Restored/lost"
        m.list([PaperRef(path: old, title: "Lost", student: "Mei Lin", factsMoved: true)])
        m.draftStore.save(paper: old, round: 2, drafts: ["R1-03": "Give the times."])
        m.list([PaperRef(path: new, title: "Lost", student: "Mei Lin", factsMoved: true)], replacing: old)
        XCTAssertEqual(m.papers.map(\.path).filter { $0.hasSuffix("/lost") }, [new])
        XCTAssertEqual(m.draftStore.load(paper: new, round: 2), ["R1-03": "Give the times."])
        XCTAssertEqual(m.draftStore.load(paper: old, round: 2), [:])
        XCTAssertEqual(m.unsentDraftsQuestion()?.title, "You have an unsent draft")
        // put back into its very place: the drafts stay
        m.list([PaperRef(path: new, title: "Lost", student: "Mei Lin", factsMoved: true)], replacing: new)
        XCTAssertEqual(m.draftStore.load(paper: new, round: 2), ["R1-03": "Give the times."])
        // a replaced copy's drafts, under a path no longer listed: not asked about
        m.draftStore.save(paper: "/Users/advisor/Replaced by Import/lost", round: 2, drafts: ["R1-04": "Say why."])
        let q = try XCTUnwrap(m.unsentDraftsQuestion())
        XCTAssertEqual(q.title, "You have an unsent draft")
        XCTAssertFalse(q.detail.contains("R1-04"), q.detail)
    }

    // MARK: A1-07

    /// An unrequested change is handled once the paragraphs it touches are read, among the state's own paragraphs: a
    /// later state without its paragraph counts it to check again.
    func testReadableParagraphsAreTheStatesOwn() throws {
        let m = makeModel("state-reading.json")
        XCTAssertEqual(m.toCheck, 2, "c03 and c06")
        m.setRead([27, 34], true)
        XCTAssertEqual(m.toCheck, 0)
        m.apply(try state("state-reading.json") { json in
            var r = json["reading"] as? [String: Any] ?? [:]
            r["paragraphs"] = (r["paragraphs"] as? [[String: Any]] ?? []).filter { $0["block"] as? Int != 34 }
            r["read"] = (r["read"] as? [Int] ?? []) + [27, 34]
            json["reading"] = r
        })
        XCTAssertEqual(m.toCheck, 1, "c06 touches no paragraph to read now")
    }

    // MARK: A3a-03, A3a-05

    /// Finish Round refused after the sheet was closed (Cancel during "Finishing…"): the window's alert says so; with
    /// the sheet shown, the sheet does.
    func testAFinishRefusedAfterTheSheetClosedIsSaid() {
        let m = makeModel()
        m.openFinish()
        XCTAssertTrue(m.showFinish)
        m.finishRound()  // a fixture run: refused at once
        XCTAssertNil(m.alertMessage)
        XCTAssertNotNil(m.finishPreview.error)
        m.showFinish = false
        m.finishRound()
        XCTAssertTrue(m.alertMessage?.hasPrefix("Round 2 was not finished: Fixture mode") == true, m.alertMessage ?? "no alert")
    }

    /// Finish Round… while the engine works says "Still loading…", as the other actions refused then.
    func testFinishWhileBusySaysStillLoading() {
        let m = makeModel()
        m.holdBusy(true)
        m.openFinish()
        XCTAssertFalse(m.showFinish)
        XCTAssertEqual(m.panelToast.text, AppModel.stillLoading)
        m.holdBusy(false)
        m.openFinish()
        XCTAssertTrue(m.showFinish)
    }

    // MARK: A3a-04

    /// After a click on Undo the pointer still rests on the toast's button (now Redo): it stays until the pointer leaves.
    func testTheToastStaysUnderThePointerAfterUndo() {
        let m = makeModel()
        m.showPanelToast("R1-05 resolved", action: .undo)
        m.holdPanelToast(true)
        m.showPanelToast("Undone · R1-05 is To check", action: .redo)
        spin(2.7)
        XCTAssertEqual(m.panelToast.text, "Undone · R1-05 is To check", "the pointer is still on it")
        m.holdPanelToast(false)
        spin(1.7)
        XCTAssertNil(m.panelToast.text, "gone 1.5 s after the pointer left")
        // a toast without a button is never held: it goes after 2.5 s, and the next one with Undo too
        m.showPanelToast("R1-05 resolved", action: .undo)
        m.holdPanelToast(true)
        m.showPanelToast(AppModel.stillLoading)
        m.showPanelToast("R1-06 resolved", action: .undo)
        spin(2.7)
        XCTAssertNil(m.panelToast.text)
    }

    // MARK: A3b-07

    /// A change's Show all goes with its card: another change expanded (or none) folds its blocks again.
    func testAChangesShowAllFoldsWithItsCard() {
        let m = makeModel()
        m.tab = .changes
        m.select(.change("c01"))
        m.actions.toggleShowAll("c01.b0")
        m.actions.toggleShowAll("fold")  // a comment card's folded line: not the change's
        XCTAssertTrue(m.edit.showAll.contains("c01.b0"))
        m.select(.change("c02"))
        XCTAssertFalse(m.edit.showAll.contains("c01.b0"))
        XCTAssertTrue(m.edit.showAll.contains("fold"))
        m.actions.toggleShowAll("c02.b0")
        m.toggleFold(.linked)  // its group hidden: no change expanded
        XCTAssertNil(m.changes.expanded)
        XCTAssertFalse(m.edit.showAll.contains("c02.b0"))
    }

    // MARK: A4a-03

    /// Settings' fold setting: the paper map on screen, which observes the overview, is drawn again.
    func testTheFoldSettingRedrawsTheMap() {
        let m = makeModel()
        var sent = 0
        let watch = m.overview.objectWillChange.sink { _ in sent += 1 }
        m.foldParts.toggle()
        XCTAssertEqual(sent, 1)
        m.foldParts = m.foldParts
        XCTAssertEqual(sent, 1, "unchanged: nothing drawn again")
        watch.cancel()
    }

    // MARK: A4b-02

    /// A summaries or hierarchy reply asked before Mark as Finished never puts the old mark back on the list.
    func testARepliesAskedBeforeMarkAsFinishedKeepTheMark() async throws {
        guard fm.isExecutableFile(atPath: EngineClient.defaultPython) else { throw XCTSkip("needs the engine's Python") }
        _ = NSApplication.shared
        var o = LaunchOptions()
        o.noList = true
        o.drafts = tmp.appendingPathComponent("drafts").path
        o.cache = tmp.appendingPathComponent("cache").path
        o.tags = tmp.appendingPathComponent("tags/tags.json").path
        let m = AppModel(options: o)
        let folder = tmp.appendingPathComponent("kelp").standardizedFileURL.path
        _ = try await m.engine.call("new", params: JSONSerialization.data(withJSONObject:
            ["paper": folder, "title": "Kelp Drift", "student": "Mei Lin"]))
        m.papers = [PaperRef(path: folder, title: "Kelp Drift", student: "Mei Lin", factsMoved: true)]
        // the hierarchy asked, then Mark as Finished: its reply still has no mark
        m.loadHub(force: true)
        m.setFinished(folder, true)
        let day = try XCTUnwrap(m.papers.first?.finished)
        try await waitUntil { !m.busy && !m.hubModel.pending }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNotNil(m.hubModel.data[folder], "the hierarchy's reply came")
        XCTAssertEqual(m.papers.first?.finished, day, "the hierarchy's reply asked before the mark did not clear it")
        // the summaries asked, then Mark as Not Finished before their reply is taken in: it still has the mark
        m.refreshSummaries()
        await Task.yield()  // the request is written from a task, off the main actor
        usleep(300_000)  // meanwhile the reply comes, and waits for the main actor
        m.setFinished(folder, false)
        try await waitUntil { !m.busy }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(m.papers.first?.finished, "the summaries' reply asked before the mark did not put it back")
        // asked after it, the hierarchy has the mark as it is
        m.setFinished(folder, true)
        m.loadHub(force: true)
        try await waitUntil { !m.busy && !m.hubModel.pending }
        XCTAssertEqual(m.hubModel.data[folder]?.paper?.finished, day)
        XCTAssertEqual(m.papers.first?.finished, day)
    }
}
