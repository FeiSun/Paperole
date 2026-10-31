import AppKit
import SwiftUI
import XCTest
@testable import Paperole

/// The navigation and the overview's scaffold (UX.md §21; design/overview/v2/OVERVIEW-v2.md §5, FEATURES OV-6): the
/// history, the `overview` reply's shape (§5.2) and its fallback, the first sentence and the facts, and the levels in a
/// fixture run. Synthetic fixtures only (Fixtures/overview-m2a.json, the state-m2a.json paper's overview).
final class NavHistoryTests: XCTestCase {
    private func place(_ paper: String, _ level: Level, sel: OverviewItem? = nil) -> NavPlace {
        NavPlace(paper: paper, level: level, overview: OverviewPlace(selection: sel))
    }

    func testBackAndForwardKeepEachPlace() {
        var h = NavHistory()
        XCTAssertFalse(h.canGoBack)
        let a = place("/a", .overview, sel: .round(2)), b = place("/a", .review), c = place("/b", .overview)
        h.push(a)  // a → b
        h.push(b)  // b → c
        XCTAssertEqual(h.goBack(from: c), b)
        XCTAssertEqual(h.goBack(from: b), a)
        XCTAssertNil(h.goBack(from: a))
        XCTAssertTrue(h.canGoForward)
        XCTAssertEqual(h.goForward(from: a), b)
        XCTAssertEqual(h.goForward(from: b), c)
        XCTAssertFalse(h.canGoForward)
    }

    func testANewPlaceDropsTheForwardOnes() {
        var h = NavHistory()
        let a = place("/a", .overview), b = place("/a", .review)
        h.push(a)
        _ = h.goBack(from: b)
        XCTAssertTrue(h.canGoForward)
        h.push(a)
        XCTAssertFalse(h.canGoForward)
        XCTAssertEqual(h.back, [a], "the same place twice in a row is kept once")
    }

    func testTheHistoryIsBoundedAndForgetsARemovedPaper() {
        var h = NavHistory()
        for i in 0..<(NavHistory.limit + 10) { h.push(place("/p\(i % 3)", i % 2 == 0 ? .overview : .review)) }
        XCTAssertEqual(h.back.count, NavHistory.limit)
        var g = NavHistory()
        g.push(place("/a", .overview))
        g.push(place("/b", .overview))
        g.push(place("/a", .overview))
        g.remove(paper: "/b")
        XCTAssertEqual(g.back, [place("/a", .overview)], "no Back to a paper no longer listed, nor twice to the same place")
    }
}

final class OverviewDataTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Fixtures")
    static let fixture = fixtures.appendingPathComponent("overview-m2a.json")

    static func overviewFixture() throws -> PaperOverview {
        let reply = try PaperOverview.decodeReply(Data(contentsOf: fixture))
        return try XCTUnwrap(reply.papers.first?.overview)
    }

    /// OVERVIEW-v2 §5.2's fields, the tuples read by position, the section ids as strings whatever the engine sends.
    func testTheFixtureDecodes() throws {
        let d = try Self.overviewFixture()
        XCTAssertEqual(d.paper?.student, "Lin Zhou")
        XCTAssertEqual(d.rounds.map(\.n), [1, 2])
        let r2 = try XCTUnwrap(d.round(2))
        XCTAssertEqual(r2.prose, "ok")
        XCTAssertTrue(r2.hasSections)
        XCTAssertEqual(r2.spans?.first, PaperOverview.Span(section: "front", title: "Title and abstract", start: 0, end: 0.6))
        XCTAssertEqual(r2.match?.first { $0.kind == "renamed" }?.to, "background-and-related-work")
        XCTAssertEqual(r2.comments?.present, 17)
        XCTAssertEqual(r2.comments?.edited, 7)
        let c06 = try XCTUnwrap(r2.edits?.first { $0.id == "c06" })
        XCTAssertTrue(c06.unrequested)
        XCTAssertTrue(c06.toCheck)
        XCTAssertEqual(c06.section, "design")
        XCTAssertEqual(r2.edits?.first { $0.id == "c05" }?.move, true)
        XCTAssertEqual(r2.edits?.first { $0.id == "c05" }?.attachedTo, ["R1-04"])
        XCTAssertEqual(d.comment("R1-08")?.step(in: 2)?.state, "unplaced")
        XCTAssertNil(d.comment("R1-08")?.step(in: 2)?.page)
        XCTAssertEqual(d.comment("R1-03")?.step(in: 2)?.state, "gone")
        XCTAssertEqual(d.sections.map(\.key), ["front", "introduction", "background-and-related-work", "design", "evaluation", "conclusion", "references"])
        XCTAssertEqual(d.threads?.closedAfter?["1"], 3)
        XCTAssertEqual(d.summary?.toJudge, 6)
        // the readout's count is the row's cells plus its unplaced comments (§4.2)
        let heat = (r2.heat ?? []).map(\.present).reduce(0, +)
        let unplaced = d.comments.filter { $0.step(in: 2)?.state == "unplaced" }.count
        XCTAssertEqual(heat + unplaced, r2.comments?.present)
    }

    /// An engine that gives fewer fields, nulls, numbers for booleans, or an error for one paper still decodes.
    func testAnyShapeOfTheReplyDecodes() throws {
        let json = #"""
        {"papers": [{"path": "/a", "overview": {"rounds": [{"n": 2, "spans": [["7", "Methods", 1, 2.5]],
                       "edits": [["c1", null, null, "7", [], 1, 0]], "words": null, "heat": [[7, 2]]}, {"n": 1}]}},
                    {"path": "/b", "error": "No ledger.json in /b"}]}
        """#
        let reply = try PaperOverview.decodeReply(Data(json.utf8))
        let d = try XCTUnwrap(reply.papers[0].overview)
        XCTAssertEqual(d.rounds.map(\.n), [1, 2], "sorted by round")
        XCTAssertEqual(d.round(2)?.spans?.first?.section, "7")
        let e = try XCTUnwrap(d.round(2)?.edits?.first)
        XCTAssertTrue(e.unrequested)
        XCTAssertFalse(e.toCheck)
        XCTAssertFalse(e.move)
        XCTAssertNil(e.page)
        XCTAssertEqual(d.round(2)?.heat?.first?.present, 2)
        XCTAssertFalse(d.round(1)?.hasSections ?? true)
        XCTAssertEqual(d.sections, [])
        XCTAssertNil(reply.papers[1].overview)
        XCTAssertEqual(reply.papers[1].error, "No ledger.json in /b")
    }

    /// A reply as the engine wrote it (2026-10-19, a synthetic two-round paper, its paths replaced): its own section
    /// keys, `null` for round 1's `match`, and keys the app does not read (`excerpts`, `unplaced`, a comment's `note`).
    func testTheEnginesReplyDecodes() throws {
        let reply = try PaperOverview.decodeReply(Data(contentsOf: Self.fixtures.appendingPathComponent("overview-engine-sample.json")))
        let d = try XCTUnwrap(reply.papers.first?.overview)
        XCTAssertEqual(d.rounds.map(\.n), [1, 2])
        XCTAssertNil(d.round(1)?.match)
        XCTAssertEqual(d.round(2)?.spans?.map(\.section), ["front", "introduction", "method", "results", "conclusion"])
        XCTAssertEqual(d.round(2)?.edits?.filter(\.unrequested).count, d.round(2)?.changes?.unrequested)
        XCTAssertEqual(d.comment("R1-01")?.step(in: 2)?.section, "method")
        XCTAssertEqual(OverviewText.firstSentence(d, student: d.paper?.student ?? "").hasPrefix("Round 2 came in on "), true)
        XCTAssertTrue(OverviewText.firstSentence(d, student: "Ana Example").hasSuffix("that no comment asked about."))
    }

    /// The engine without `overview` (rpc.py's "Unknown method") is not an error to show: the overview says what the
    /// state says and that the map needs a newer engine.
    @MainActor
    func testAnEngineWithoutTheOverviewFallsBack() {
        XCTAssertTrue(OverviewModel.isUnknownMethod("Unknown method 'overview'."))
        XCTAssertFalse(OverviewModel.isUnknownMethod("No ledger.json"))
        let o = OverviewModel()
        o.reset(for: "/a")
        let seq = o.begin(version: 0)
        o.finish(seq, paper: "/a", .failure(EngineError(message: "Unknown method 'overview'.")))
        XCTAssertEqual(o.status, .unavailable)
        let again = o.begin(version: 1)
        o.finish(again, paper: "/a", .failure(EngineError(message: "No ledger.json in /a")))
        XCTAssertEqual(o.status, .failed("No ledger.json in /a"))
        // a late reply to an older request, or for another paper, is dropped
        let third = o.begin(version: 2)
        o.finish(third - 1, paper: "/a", .failure(EngineError(message: "old")))
        o.finish(third, paper: "/b", .failure(EngineError(message: "other paper")))
        XCTAssertEqual(o.status, .loading)
    }

    /// FEATURES OV-1: no counts in the first sentence, the student by first name, no pronoun.
    func testTheFirstSentence() throws {
        let d = try Self.overviewFixture()
        XCTAssertEqual(OverviewText.firstSentence(d, student: "Lin Zhou"),
                       "Round 2 came in on Wed, Oct 14. Lin edited most open passages, and changed part of Design that no comment asked about.")
        XCTAssertEqual(OverviewText.firstSentence(nil, student: "Lin Zhou", fallback: [
            RoundSummary(n: 1, created: "2026-10-07T12:00:00+08:00", closed: true, closedAt: "2026-10-08T12:00:00+08:00", status: "ok")]),
                       "Round 1 was sent back to Lin on Thu, Oct 8; nothing to do until the next round comes in.")
        XCTAssertEqual(OverviewText.firstSentence(nil, student: "", fallback: [
            RoundSummary(n: 3, created: "2026-10-16T12:00:00+08:00", closed: false, status: "failed")]),
                       "Round 3 came in on Fri, Oct 16 but did not build.")
        XCTAssertEqual(OverviewText.firstSentence(nil, student: "Lin Zhou"), "")
    }

    func testTheFactsAndTheRailsDates() throws {
        let d = try Self.overviewFixture()
        let f = OverviewText.facts(d, rounds: [], pages: nil)
        XCTAssertEqual(f.comments, "17 comments")
        XCTAssertEqual(f.rounds, "2 rounds since Oct 7")
        XCTAssertEqual(f.details, ["2 resolved", "1 kept", "14 open", "4 pp", "3,120 words"])
        // UI v4: the facts left the canvas for the header's help tag, every one of them
        XCTAssertEqual(OverviewText.headerHelp("Round 2 came in on Wed, Oct 14.", f),
                       "Round 2 came in on Wed, Oct 14.\n17 comments · 2 rounds since Oct 7 · 2 resolved · 1 kept · 14 open · 4 pp · 3,120 words")
        XCTAssertEqual(OverviewText.headerHelp("", OverviewText.Facts()), "")
        XCTAssertEqual(OverviewText.dates("2026-10-07T12:00:00+08:00", "2026-10-08T12:00:00+08:00"), "Oct 7 → 8")
        XCTAssertEqual(OverviewText.dates("2026-09-28T12:00:00+08:00", "2026-10-02T12:00:00+08:00"), "Sep 28 → Oct 2")
        XCTAssertEqual(OverviewText.dates("2026-10-14T12:00:00+08:00", nil), "Oct 14 →")
        XCTAssertEqual(OverviewText.shortTitle("3 Design"), "Design")
        XCTAssertEqual(OverviewText.shortTitle("2.1 Warm pools"), "Warm pools")
        XCTAssertEqual(OverviewText.shortTitle("References"), "References")
        XCTAssertEqual(OverviewText.shortTitle("A Note on Noise"), "A Note on Noise")
    }

    /// Without the engine's overview, the rounds the state knows, latest first, with the rail's dates and a failed
    /// build (the map itself is `MapScene`'s: the code audit removed `rows`' overview branch, which only tests reached).
    func testTheRows() throws {
        let fromState = OverviewRow.rows(state: [
            RoundSummary(n: 1, created: "2026-10-07T12:00:00+08:00", closed: true, closedAt: "2026-10-08T12:00:00+08:00", status: "ok"),
            RoundSummary(n: 2, created: nil, closed: false, status: "failed")])
        XCTAssertEqual(fromState.map(\.n), [2, 1])
        XCTAssertTrue(fromState[0].failed)
        XCTAssertFalse(fromState[1].failed)
        XCTAssertEqual(fromState[1].dates, "Oct 7 → 8")
    }
}

/// The levels in a fixture run (`--fixture` with `--overview-fixture`): the overview by default for a click, Review
/// at a position, Back and Forward with the overview's place, All Rounds, the keys, the window's subtitle.
@MainActor
final class NavigationModelTests: XCTestCase {
    private var drafts: URL!

    override func setUpWithError() throws {
        drafts = FileManager.default.temporaryDirectory.appendingPathComponent("pc-nav-drafts-" + UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: drafts)
    }

    private func makeModel(level: Level? = .overview, overview: Bool = true, summary: Bool = false) throws -> AppModel {
        _ = NSApplication.shared
        var o = LaunchOptions()
        if summary {
            let url = drafts.appendingPathComponent("state.json")
            try FileManager.default.createDirectory(at: drafts, withIntermediateDirectories: true)
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: StepTests.fixtures
                .appendingPathComponent("state-m2a.json"))) as? [String: Any])
            json["summary"] = ["round": 2, "closed": false, "status": "ok", "to_judge": 6, "to_check": 1]
            try JSONSerialization.data(withJSONObject: json).write(to: url)
            // the fixture's PDFs are relative to its folder: link them in
            for r in ["round1", "round2"] {
                try? FileManager.default.createSymbolicLink(at: drafts.appendingPathComponent(r),
                                                            withDestinationURL: StepTests.fixtures.appendingPathComponent(r))
            }
            o.fixture = url.path
        } else {
            o.fixture = StepTests.fixtures.appendingPathComponent("state-m2a.json").path
        }
        if overview { o.overviewFixture = OverviewDataTests.fixture.path }
        o.level = level
        o.drafts = drafts.path
        return AppModel(options: o)
    }

    private func key(_ chars: String, code: UInt16 = 0) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    func testAFixtureRunOpensInReviewAsBefore() throws {
        let m = try makeModel(level: nil)
        XCTAssertEqual(m.level, .review)
        XCTAssertFalse(m.showsOverview)
        XCTAssertFalse(m.canGoBack)
        XCTAssertEqual(m.overview.status, .idle, "the overview is not asked for until it is shown")
    }

    func testTheOverviewLoadsAndNamesTheRound() throws {
        let m = try makeModel(summary: true)
        XCTAssertEqual(m.level, .overview)
        XCTAssertTrue(m.showsOverview)
        XCTAssertEqual(m.overview.status, .loaded)
        XCTAssertEqual(m.overview.data?.rounds.count, 2)
        XCTAssertEqual(m.stripRound, 2)
        XCTAssertEqual(m.windowSubtitle, "Lin Zhou · Round 2 · 6 comments and 1 edit to check")
        XCTAssertEqual(m.continueButton?.title, "Continue Round 2")
        XCTAssertEqual(m.continueButton?.prominent, true)
        m.openReview()
        XCTAssertEqual(m.windowSubtitle, "Lin Zhou · 6 comments and 1 edit to check", "Review's own, as before: the round menu names it")
    }

    func testWithoutAnOverviewTheScreenStillShows() throws {
        let m = try makeModel(overview: false)
        XCTAssertEqual(m.overview.status, .unavailable)
        XCTAssertTrue(m.showsOverview)
        XCTAssertEqual(OverviewRow.rows(state: m.state?.rounds ?? []).map(\.n), [2, 1])
    }

    /// A click follows an item and moves the strip to its round; Esc follows nothing; Review's keys do nothing here.
    func testClicksAndKeysInTheOverview() throws {
        let m = try makeModel()
        m.overviewClicked(.section("design", round: 1))
        XCTAssertEqual(m.overview.selection, .section("design", round: 1))
        XCTAssertEqual(m.stripRound, 1)
        m.overviewClicked(.comment("R1-05"))
        XCTAssertEqual(m.stripRound, 1, "the comment is in the strip's round: it stays")
        m.overviewClicked(.comment("R2-06"))
        XCTAssertEqual(m.stripRound, 2, "a comment written later: its round")
        XCTAssertFalse(m.performKey(key("j")), "J is Review's")
        XCTAssertNil(m.selectedComment)
        XCTAssertTrue(m.performKey(key("\u{1b}", code: 53)))
        XCTAssertNil(m.overview.selection)
        XCTAssertFalse(m.performKey(key("\u{1b}", code: 53)), "nothing followed: Esc is not taken")
    }

    /// Where Review opens for each item (§5.1): a cell's round and heading (and first page), a round, a page, a comment
    /// in the strip's round.
    func testReviewTargets() throws {
        let m = try makeModel()
        XCTAssertEqual(m.reviewTarget(for: .section("design", round: 2)), ReviewTarget(round: 2, section: "3 Design", page: 1))
        XCTAssertEqual(m.reviewTarget(for: .section("front", round: 1)), ReviewTarget(round: 1, section: "Title and abstract", page: 0))
        let hs = [Heading(block: 4, level: 2, title: "3.1 Design notes"), Heading(block: 9, level: 1, title: "3  Design")]
        XCTAssertEqual(AppModel.heading("3 design", in: hs)?.block, 9, "a section's heading by its title, spaces and case aside")
        XCTAssertNil(AppModel.heading("Title and abstract", in: hs))
        XCTAssertEqual(m.reviewTarget(for: .round(1)), ReviewTarget(round: 1))
        XCTAssertEqual(m.reviewTarget(for: .page(round: 2, page: 3)), ReviewTarget(round: 2, page: 3))
        XCTAssertEqual(m.reviewTarget(for: .comment("R1-10")), ReviewTarget(round: 2, comment: "R1-10", page: 2))
        m.overview.strip = 1
        XCTAssertEqual(m.reviewTarget(for: .comment("R1-10")), ReviewTarget(round: 1, comment: "R1-10", page: 2))
    }

    /// A double click opens Review at the comment; Back returns to the overview as it was left (what it followed, the
    /// strip's round); Forward to Review with the comment; All Rounds is a place too.
    func testBackAndForwardBetweenTheLevels() throws {
        let m = try makeModel()
        m.overviewClicked(.section("evaluation", round: 2))
        m.overviewClicked(.comment("R1-05"), double: true)
        XCTAssertEqual(m.level, .review)
        XCTAssertFalse(m.showsOverview)
        XCTAssertEqual(m.selectedComment?.id, "R1-05")
        XCTAssertEqual(m.tab, .comments)
        XCTAssertTrue(m.canGoBack)
        m.goBack()
        XCTAssertEqual(m.level, .overview)
        XCTAssertEqual(m.overview.selection, .section("evaluation", round: 2), "the double click's first click did not follow it")
        XCTAssertEqual(m.stripRound, 2)
        XCTAssertTrue(m.canGoForward)
        m.overviewClicked(nil)
        m.goForward()
        XCTAssertEqual(m.level, .review)
        XCTAssertEqual(m.selectedComment?.id, "R1-05", "Review was never rebuilt: its selection is there")
        m.select(.comment("R2-01"))
        m.showAllRounds()
        XCTAssertEqual(m.level, .overview)
        XCTAssertNil(m.overview.selection, "All Rounds: the overview as it was left")
        m.goBack()
        XCTAssertEqual(m.level, .review)
        XCTAssertEqual(m.selectedComment?.id, "R2-01")
    }

    /// Opening Review on a paper whose state has not come yet waits for it (`pendingReview`), and the sidebar's click on
    /// the shown paper's row changes only the level.
    func testAPositionWaitsForItsState() throws {
        let m = try makeModel()
        let st = try XCTUnwrap(m.state)
        let path = st.paper.path
        m.papers.append(PaperRef(path: "/tmp/other-paper", title: "Other", student: ""))
        m.openPaper("/tmp/other-paper")
        XCTAssertEqual(m.selectedPath, "/tmp/other-paper")
        XCTAssertEqual(m.level, .overview)
        XCTAssertNil(m.state)
        m.goBack()  // to the fixture's paper, whose state a fixture run does not ask for again
        XCTAssertEqual(m.selectedPath, path)
        m.openReview(ReviewTarget(round: 2, comment: "R1-10"))
        XCTAssertEqual(m.level, .review)
        XCTAssertNotNil(m.pendingReview)
        m.apply(st)  // as the engine's reply would
        XCTAssertNil(m.pendingReview)
        XCTAssertEqual(m.selectedComment?.id, "R1-10")
        m.openPaper(path)  // its own row: the overview of it
        XCTAssertEqual(m.level, .overview)
        m.openPaper(path, level: .review)
        XCTAssertEqual(m.level, .review)
        m.removePaper("/tmp/other-paper")
        XCTAssertFalse(m.navHistory.back.contains { $0.paper == "/tmp/other-paper" })
    }

    /// Jump from the overview: what only Review shows opens Review as it was left (a place, so Back returns); New
    /// Paper… does not leave the overview.
    func testJumpFromTheOverview() throws {
        let m = try makeModel()
        m.jumpTo(.command(.newPaper))
        XCTAssertEqual(m.level, .overview)
        m.showNewPaper = false
        m.jumpTo(.comment("R2-01"))
        XCTAssertEqual(m.level, .review)
        XCTAssertEqual(m.selectedComment?.id, "R2-01")
        m.goBack()
        XCTAssertEqual(m.level, .overview)
    }

    /// A paper with no round has no overview: Review's own page says to start Round 1.
    func testNoRoundsNoOverview() throws {
        let m = try makeModel()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: StepTests.fixtures
            .appendingPathComponent("state-m2a.json"))) as? [String: Any])
        json["rounds"] = []
        json["round"] = NSNull()
        json["comments"] = []
        json["changes"] = []
        m.apply(try EngineState.decode(JSONSerialization.data(withJSONObject: json)))
        XCTAssertEqual(m.level, .overview)
        XCTAssertFalse(m.showsOverview)
        XCTAssertNil(m.continueButton)
    }

    /// A round the overview had pending, filled in while Review is shown (the second engine process; Review's own
    /// `prose` likewise), is asked for again when the overview comes back; without one, coming back asks nothing.
    func testARoundFilledInWhileInReviewIsAskedForAgain() throws {
        let m = try makeModel()
        let path = try XCTUnwrap(m.selectedPath)
        XCTAssertEqual(m.overview.status, .loaded)
        let version = m.overview.version
        m.openReview()
        m.showAllRounds()
        XCTAssertEqual(m.overview.version, version, "nothing changed: the data shown is kept")
        m.openReview()
        m.backfill.filled?(path, false)
        XCTAssertEqual(m.overview.version, -1, "the data shown had the round pending")
        XCTAssertEqual(m.level, .review, "Review stays")
        m.showAllRounds()
        XCTAssertEqual(m.overview.version, version, "asked again")
        XCTAssertEqual(m.overview.status, .loaded)
    }
}

/// The scaffold drawn: the scroll position kept for Back, a click and a double click on one view, and Review's
/// AppKit views hidden behind the overview without the sidebar.
@MainActor
final class OverviewViewTests: XCTestCase {
    private func spin(_ s: Double = 0.15) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    func testTheOverviewKeepsItsScrollForBack() throws {
        _ = NSApplication.shared
        var o = LaunchOptions()
        o.fixture = StepTests.fixtures.appendingPathComponent("state-m2a.json").path
        o.overviewFixture = OverviewDataTests.fixture.path
        o.level = .overview
        let drafts = FileManager.default.temporaryDirectory.appendingPathComponent("pc-nav-scroll-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: drafts) }
        o.drafts = drafts.path
        let m = AppModel(options: o)
        m.overviewClicked(.round(2))  // the panel, so the overview is taller than the window
        let host = NSHostingView(rootView: OverviewScreen(model: m, overview: m.overview).frame(width: 900, height: 260))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 260), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        spin(0.4)
        let sv = try XCTUnwrap(m.overview.scrollView, "the probe found the scroll view")
        OverviewModel.scroll(sv, to: 120)
        spin()
        XCTAssertEqual(m.overview.liveScroll ?? -1, 120, accuracy: 1)
        let left = m.overview.place
        XCTAssertEqual(left.scroll, 120, accuracy: 1)
        OverviewModel.scroll(sv, to: 0)
        spin()
        m.overview.restore(left)
        spin(0.3)
        XCTAssertEqual(m.overview.liveScroll ?? -1, 120, accuracy: 1, "put back")
        m.overview.reset(for: "/other")
        spin(0.3)
        XCTAssertEqual(m.overview.liveScroll ?? -1, 0, accuracy: 1, "another paper starts at the top")
        window.close()
    }

    /// `Clicks`: the first click acts at once, the second of a double click opens (OVERVIEW-v2 §5.1).
    func testAClickAndADoubleClick() throws {
        _ = NSApplication.shared
        final class Counts { var single = 0, double = 0 }
        let n = Counts()
        let host = NSHostingView(rootView: Color.gray.frame(width: 100, height: 60).clicks({ n.single += 1 }, double: { n.double += 1 }))
        host.frame = NSRect(x: 0, y: 0, width: 100, height: 60)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        spin()
        // as the debug script's clicks: the mouse-down and -up to the view under the point (a tap gesture needs both)
        func click(_ count: Int) {
            let p = NSPoint(x: 50, y: 30)
            func event(_ type: NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1)!
            }
            let target = window.contentView?.superview?.hitTest(p)
            target?.mouseDown(with: event(.leftMouseDown))
            target?.mouseUp(with: event(.leftMouseUp))
            spin(0.05)
        }
        click(1)
        spin(0.1)
        XCTAssertEqual(n.single, 1, "at once")
        XCTAssertEqual(n.double, 0)
        click(2)
        spin(0.1)
        XCTAssertEqual(n.double, 1)
        window.close()
    }

    /// Review's split view (the PDF and the panel) is hidden in AppKit, not the window's sidebar split view round it.
    func testReviewIsHiddenInAppKitNotTheSidebar() {
        _ = NSApplication.shared
        let outer = NSSplitView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        let sidebar = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        let detail = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        outer.addArrangedSubview(sidebar)
        outer.addArrangedSubview(detail)
        let inner = NSSplitView(frame: detail.bounds)
        detail.addSubview(inner)
        let left = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        inner.addArrangedSubview(left)
        inner.addArrangedSubview(NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 400)))
        let pdf = ReviewPDFView(frame: left.bounds)
        left.addSubview(pdf)
        let window = NSWindow(contentRect: outer.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = outer
        let c = PDFController()
        c.attach(pdf)
        XCTAssertTrue(PDFController.reviewRoot(of: pdf) === inner)
        c.setReviewHidden(true)
        XCTAssertTrue(inner.isHidden)
        XCTAssertTrue(pdf.isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(sidebar.isHiddenOrHasHiddenAncestor)
        c.setReviewHidden(false)
        XCTAssertFalse(pdf.isHiddenOrHasHiddenAncestor)
        window.close()
    }
}

/// The code audit of 2026-10-24 on the hierarchy, the strip and the overview's screen (B12): thumbnails asked for again
/// after the cache empties, the key page's bookmark and the strip's cells, what an empty strip says, a hub page put
/// back near its bottom, the formatters made once, Turnaround under a day.
@MainActor
final class HubAndStripAuditTests: XCTestCase {
    private func spin(_ s: Double = 0.15) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    /// A4b-01: past its capacity the cache empties and forgets what it was asked for, so a page shown before is
    /// drawn again (it stayed blank until relaunch).
    func testThumbnailsAreAskedForAgainAfterTheCacheEmpties() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-thumbs-cap-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pdf = dir.appendingPathComponent("main.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = try XCTUnwrap(CGContext(pdf as CFURL, mediaBox: &box, nil))
        for _ in 0..<3 {
            ctx.beginPDFPage(nil)
            ctx.fill(CGRect(x: 72, y: 600, width: 300, height: 100))
            ctx.endPDFPage()
        }
        ctx.closePDF()
        let store = ThumbnailStore(root: dir.appendingPathComponent("cache"), capacity: 2)
        func drawn(_ page: Int) async throws -> NSImage? {
            for _ in 0..<50 {
                if let im = store.image(paper: "/papers/a", pdf: pdf.path, page: page, height: 72) { return im }
                await store.flush()
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            return nil
        }
        _ = try await drawn(0)
        _ = try await drawn(1)
        // the third goes past the capacity: all three leave the memory, page 0 among them
        XCTAssertNil(store.image(paper: "/papers/a", pdf: pdf.path, page: 2, height: 72))
        await store.flush()
        try await Task.sleep(nanoseconds: 100_000_000)
        let again = try await drawn(0)
        XCTAssertNotNil(again, "a page shown before is drawn again, not left blank")
    }

    /// A4b-04: the key page's bookmark keeps its number only while both fit the slot (a 60-page strip: the bookmark
    /// alone); a wide slot keeps both, and the ○ beside them counts.
    func testTheKeyPagesBookmarkKeepsItsNumberOnlyWhereItFits() {
        let sixty = StripLabels(slot: 676 / 60, pages: 60)
        XCTAssertTrue(sixty.shows(40), "every other number")
        XCTAssertTrue(sixty.shows(40, key: false, ring: false))
        XCTAssertFalse(sixty.shows(40, key: true, ring: false), "the bookmark alone")
        XCTAssertFalse(sixty.shows(41, key: false, ring: false))
        let twelve = StripLabels(slot: 1156 / 12, pages: 12)
        XCTAssertTrue(twelve.shows(3, key: true, ring: true))
        let tight = StripLabels(slot: 30, pages: 12)
        XCTAssertTrue(tight.shows(9, key: true, ring: false))
        XCTAssertFalse(tight.shows(9, key: true, ring: true), "with the ○ too it no longer fits")
    }

    /// A4b-06: the strip says the build failed only when it did; a round gone from the data (Put Back) is not the
    /// strip's round any more.
    func testTheStripSaysTheBuildFailedOnlyWhenItDid() throws {
        let reply = try PaperOverview.decodeReply(Data(#"{"papers": [{"path": "/a", "overview": {"rounds": [{"n": 3, "build": {"status": "failed"}}]}}]}"#.utf8))
        let failed = try XCTUnwrap(reply.papers.first?.overview?.round(3))
        XCTAssertEqual(PageStripView.noPages(failed, loading: false), "No PDF for Round 3: the build failed.")
        XCTAssertEqual(PageStripView.noPages(nil, loading: false), "No pages yet.", "no data for the round: not a failed build")
        XCTAssertEqual(PageStripView.noPages(nil, loading: true), "Reading the rounds…")
        let o = OverviewModel()
        o.reset(for: "/a")
        let d = try OverviewDataTests.overviewFixture()
        o.strip = 5
        o.finish(o.begin(version: 1), paper: "/a", .success(d))
        XCTAssertNil(o.strip, "a round the data no longer has: the latest that built")
        o.strip = 1
        o.finish(o.begin(version: 2), paper: "/a", .success(d))
        XCTAssertEqual(o.strip, 1, "a round still there stays")
    }

    /// A4b-05: Back to a hub page scrolled near its bottom puts it back at once: the room under the toolbar (the
    /// scroll view's content insets) counts, as the overview's does.
    func testAHubPageNearItsBottomIsPutBackAtOnce() throws {
        _ = NSApplication.shared
        final class Flipped: NSView { override var isFlipped: Bool { true } }
        let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        sv.automaticallyAdjustsContentInsets = false
        sv.contentInsets = NSEdgeInsets(top: 52, left: 0, bottom: 0, right: 0)
        sv.documentView = Flipped(frame: NSRect(x: 0, y: 0, width: 300, height: 2000))
        let window = NSWindow(contentRect: sv.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sv
        defer { window.close() }
        let visible = OverviewModel.visibleHeight(sv)
        XCTAssertEqual(OverviewModel.room(sv), 2000 - visible, accuracy: 1)
        let hub = HubModel()
        hub.scrollView = sv
        let y = OverviewModel.room(sv) - 10  // past the room the hub's own sum left (2000 less the whole clip view)
        XCTAssertGreaterThan(y, Double(2000 - sv.contentView.bounds.height))
        hub.show(scroll: y)
        XCTAssertEqual(hub.liveScroll ?? -1, y, accuracy: 1, "put back at once, not after 1.8 s")
    }

    /// A4b-07, A4a-01: the date formatters are made once for each format and zone, and say what they said.
    func testTheDateFormattersAreMadeOnce() {
        XCTAssertTrue(HubText.formatter("MMM d") === HubText.formatter("MMM d"))
        let tz = TimeZone(secondsFromGMT: 8 * 3600)!
        XCTAssertTrue(HubText.formatter("MMM d", tz) === HubText.formatter("MMM d", tz))
        XCTAssertFalse(HubText.formatter("MMM d", tz) === HubText.formatter("EEE", tz))
        XCTAssertEqual(HubText.format(HierarchyDataTests.day("2026-10-14"), "EEE, MMM d", tz), "Wed, Oct 14")
        XCTAssertEqual(OverviewText.day("2026-10-14T12:00:00+08:00"), HubText.format(HierarchyDataTests.day("2026-10-14"), "EEE, MMM d"))
        XCTAssertNil(OverviewText.day("not a date"))
        XCTAssertEqual(HubText.day("2026-07-20"), "Jul 20")
        // Your Move: the earliest import first, those without a date after them in the list's order
        let ps = ["/a", "/b", "/c", "/d"].map { PaperRef(path: $0, title: $0, student: "") }
        func overview(_ created: String) throws -> PaperOverview {
            try XCTUnwrap(PaperOverview.decodeReply(Data(#"{"papers": [{"path": "/x", "overview": {"rounds": [{"n": 1, "created": "\#(created)"}]}}]}"#.utf8))
                .papers.first?.overview)
        }
        let data = ["/a": try? overview("2026-10-16T09:00:00+08:00"), "/c": try? overview("2026-10-02T09:00:00+08:00"),
                    "/d": try? overview("2026-10-09T09:00:00+08:00")].compactMapValues { $0 }
        let moves = Hierarchy.yourMove(ps, status: { _ in .firstDraft }, data: data)
        XCTAssertEqual(moves.map(\.paper.path), ["/c", "/d", "/a", "/b"])
    }

    /// UI-08, UI v4: a trip of no calendar days reads "<1 d" in Turnaround's rows and medians (was "under a day" and
    /// "the same day" in the old box's sentence, `HubText.time`).
    func testTurnaroundSaysUnderADay() throws {
        func trip(_ round: Int, you: Int, student: Int, path: String = "/kelp") -> StudentStats.Trip {
            StudentStats.Trip(path: path, round: round, next: round + 1, open: false, you: you, student: student, received: nil)
        }
        let trips = [trip(1, you: 0, student: 0), trip(2, you: 0, student: 0)]
        let m = Turnaround.medians(trips)
        XCTAssertEqual(m.you?.text, "<1 d")
        XCTAssertEqual(m.student?.text, "<1 d")
        let stats = try makeDecoder().decode(StudentStats.self, from: Data(#"{"student": "Leo Park", "papers": ["/kelp"], "comments": 2}"#.utf8))
        var s = stats
        s.time = trips + [trip(1, you: 2, student: 9, path: "/reef")]
        let g = StudentGroup(key: "leo", name: "Leo Park", papers: [PaperRef(path: "/kelp", title: "Kelp forest drift", student: "Leo Park")])
        let t = try XCTUnwrap(StudentTiles.make(g, stats: s, data: [:], statuses: [:], catalog: TagCatalog()).turnaround)
        XCTAssertEqual(t.rows.map { StudentTiles.days($0.you) + " " + StudentTiles.days($0.student) }, ["<1 d <1 d", "<1 d <1 d"],
                       "the other student's paper is not this page's")
        XCTAssertEqual(t.who, "Leo")
    }
}
