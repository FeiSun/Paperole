import AppKit
import XCTest
@testable import Paperole

/// The review of 2026-10-24, batch B15 (the app's cross-file follow-ups): Start Round 1 when the engine asks for the
/// main file (E2E-04), Build Round N Again… (E2E-05), a paper that does not open (A1-06), one hierarchy request after
/// Map Headings… and Rename Student… (A4b-08), Your Move's round (A4b-10) and one rule for a test run (A5a-11 +
/// A5b-15). Synthetic papers and fixtures only.
@MainActor
final class CrossFileFixTests: XCTestCase {
    private let fm = FileManager.default
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("pc-b15-" + UUID().uuidString)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: tmp) }

    // MARK: Helpers

    private func fixture(_ edit: (inout [String: Any]) throws -> Void = { _ in }) throws -> EngineState {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: StepTests.fixtures
            .appendingPathComponent("state-round2.json"))) as? [String: Any])
        try edit(&json)
        return try EngineState.decode(JSONSerialization.data(withJSONObject: json))
    }

    private func fixtureModel() -> AppModel {
        _ = NSApplication.shared
        var o = LaunchOptions()
        o.fixture = StepTests.fixtures.appendingPathComponent("state-round2.json").path
        o.drafts = tmp.appendingPathComponent("drafts").path
        o.cache = tmp.appendingPathComponent("cache").path
        o.tags = tmp.appendingPathComponent("tags.json").path
        return AppModel(options: o)
    }

    /// A model with the engine and no list of its own (--no-list); skipped without the engine's Python (or latexmk).
    private func engineModel(latex: Bool = false) throws -> AppModel {
        guard fm.isExecutableFile(atPath: EngineClient.defaultPython),
              !latex || fm.fileExists(atPath: "/Library/TeX/texbin/latexmk") else {
            throw XCTSkip("needs the engine's Python" + (latex ? " and latexmk" : ""))
        }
        _ = NSApplication.shared
        var o = LaunchOptions()
        o.noList = true
        o.drafts = tmp.appendingPathComponent("drafts").path
        o.cache = tmp.appendingPathComponent("cache").path
        o.tags = tmp.appendingPathComponent("tags.json").path
        return AppModel(options: o)
    }

    @discardableResult
    private func rpc(_ m: AppModel, _ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let data = try await m.engine.call(method, params: JSONSerialization.data(withJSONObject: params))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func until(_ seconds: Double = 20, _ done: () -> Bool) async throws {
        for _ in 0..<Int(seconds * 20) where !done() { try await Task.sleep(nanoseconds: 50_000_000) }
    }

    // MARK: E2E-04, E2E-05

    /// Two top-level files with \documentclass, neither main.tex: the engine asks which. Start Round 1 shows its words
    /// with the folder kept (not an OK-only alert, the paper stuck at "No rounds yet"); with the main file given, the
    /// round builds, and as nothing was done in it yet it can be built again (Build Round 1 Again…).
    func testStartRoundOneAsksForTheMainFile() async throws {
        let m = try engineModel(latex: true)
        let paper = tmp.appendingPathComponent("Reviews/Two mains").path
        let src = tmp.appendingPathComponent("src")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        for (name, word) in [("paper.tex", "paper"), ("draft.tex", "draft")] {
            let tex = "\\documentclass{article}\n\\begin{document}\nThe \(word) of the kelp study.\n\\end{document}\n"
            try Data(tex.utf8).write(to: src.appendingPathComponent(name))
        }
        try await rpc(m, "new", ["paper": paper, "title": "Two mains", "student": "Mei Lin"])
        m.selectPaper(paper)
        try await until { m.state != nil }
        XCTAssertEqual(m.state?.rounds, [])
        XCTAssertEqual(RetrySheet.title(m.latestRound), "Start Round 1")
        m.ingest(source: src.path)
        try await until { m.showRetry }
        XCTAssertTrue(m.showRetry, "the sheet with the Main file field opens")
        XCTAssertEqual(m.startRefused?.source, src.path, "the folder chosen is kept")
        XCTAssertTrue(m.startRefused?.problem.contains("Choose one") == true, m.startRefused?.problem ?? "")
        XCTAssertNil(m.alertMessage, "said in the sheet, not in an alert")
        XCTAssertEqual(m.state?.rounds, [], "nothing ingested")
        m.ingest(source: src.path, main: "paper.tex")
        XCTAssertNil(m.startRefused, "the words go while it builds")
        try await until(60) { m.state?.rounds.isEmpty == false && !m.busy }
        XCTAssertEqual(m.round?.n, 1)
        XCTAssertEqual(m.round?.build.status, "ok")
        XCTAssertEqual(m.state?.paper.main, "paper.tex")
        XCTAssertNil(m.startRefused)
        XCTAssertTrue(m.canBuildAgain, "no comment or verdict in it yet: Build Round 1 Again…")
        XCTAssertEqual(RetrySheet.title(m.latestRound), "Build Round 1 Again")
    }

    /// Build Round N Again… follows the engine's rule (CONTRACT §6): the latest round, open, with no comment written,
    /// verdict given or comment reopened in it.
    func testARoundCanBeBuiltAgainUntilSomethingIsDoneInIt() throws {
        let m = fixtureModel()
        XCTAssertFalse(m.canBuildAgain, "round 2 has new comments and verdicts")
        m.apply(try fixture { json in
            let cs = try XCTUnwrap(json["comments"] as? [[String: Any]])
            json["comments"] = cs.filter { $0["carried"] as? Bool == true }.map { c in
                var c = c
                c["verdict"] = NSNull()
                return c
            }
        })
        XCTAssertTrue(m.canBuildAgain, "only carried comments, none answered")
        m.apply(try fixture { json in
            let cs = try XCTUnwrap(json["comments"] as? [[String: Any]])
            json["comments"] = cs.filter { $0["carried"] as? Bool == true }.map { c in
                var c = c
                c["verdict"] = NSNull()
                if c["id"] as? String == "R1-06" { c["revived"] = ["from": 1, "at": "2026-10-20T10:00:00+08:00"] }
                return c
            }
        })
        XCTAssertFalse(m.canBuildAgain, "a comment reopened into it")
        m.apply(try fixture { json in
            json["comments"] = []
            var rounds = try XCTUnwrap(json["rounds"] as? [[String: Any]])
            rounds[1]["closed"] = true
            json["rounds"] = rounds
        })
        XCTAssertFalse(m.canBuildAgain, "closed")
        XCTAssertEqual(RetrySheet.title(m.latestRound), "Start Round 3")
        m.apply(try fixture { json in
            json["comments"] = []
            var round = try XCTUnwrap(json["round"] as? [String: Any])
            round["n"] = 1
            json["round"] = round
        })
        XCTAssertFalse(m.canBuildAgain, "an earlier round shown")
    }

    // MARK: A1-06

    /// A paper whose state does not read: its page says so with Try Again (not an empty Review titled "No rounds
    /// yet"), and Try Again or its row clicked again asks again.
    func testAPaperThatDoesNotOpenSaysSoAndTriesAgain() async throws {
        let m = try engineModel()
        let paper = tmp.appendingPathComponent("Reviews/Kelp drift").path
        try await rpc(m, "new", ["paper": paper, "title": "Kelp drift", "student": "Mei Lin"])
        let ledger = URL(fileURLWithPath: paper).appendingPathComponent("ledger.json")
        let good = try Data(contentsOf: ledger)
        try Data("{".utf8).write(to: ledger)
        m.selectPaper(paper)
        try await until { m.stateError != nil }
        XCTAssertNotNil(m.stateError, "the engine's words kept for the page")
        XCTAssertNil(m.state)
        XCTAssertNil(m.alertMessage, "said on the page, not in an alert")
        XCTAssertEqual(m.roundLabel, "", "not \"No rounds yet\"")
        try good.write(to: ledger)
        m.retryState()
        XCTAssertNil(m.stateError)
        try await until { m.state != nil }
        XCTAssertNotNil(m.state, "Try Again")
        XCTAssertEqual(m.roundLabel, "No rounds yet")
        // again, through the row
        m.selectPaper(nil)
        try Data("{".utf8).write(to: ledger)
        m.selectPaper(paper)
        try await until { m.stateError != nil }
        XCTAssertNotNil(m.stateError)
        try good.write(to: ledger)
        m.selectPaper(paper)
        try await until { m.state != nil }
        XCTAssertNotNil(m.state, "the same paper clicked again is asked again")
        XCTAssertNil(m.stateError)
    }

    // MARK: A4b-08, A4b-10

    /// Map Headings…' Done keeps only the answers that changed (a paper never answered keeps its suggestions).
    func testMapHeadingsDoneWritesOnlyWhatChanged() {
        var a = PaperRef(path: "/r/a", title: "A", student: "Mei Lin")
        a.buckets = ["1": "introduction", "2": ""]
        let b = PaperRef(path: "/r/b", title: "B", student: "Mei Lin")
        let answers = ["/r/a": ["1": "introduction", "2": ""], "/r/b": ["1": "method"]]
        XCTAssertEqual(MapHeadingsSheet.changed(answers, [a, b]), ["/r/b": ["1": "method"]])
        XCTAssertEqual(MapHeadingsSheet.changed(["/r/a": ["1": "results", "2": ""]], [a, b]), ["/r/a": ["1": "results", "2": ""]])
        XCTAssertEqual(MapHeadingsSheet.changed([:], [a, b]), [:])
    }

    /// Before the hierarchy's data comes, or for good when a paper's overview failed, Your Move knows the round from
    /// the papers list (it said "Finish Round 0…"); without either it names none.
    func testYourMoveKnowsTheRoundBeforeTheHierarchy() {
        let p = PaperRef(path: "/r/kelp", title: "Kelp drift", student: "Mei Lin")
        let summary = PaperSummary(round: 3, closed: false, status: "ok", toJudge: 0, toCheck: 0)
        let moves = Hierarchy.yourMove([p], status: { _ in .ready }, data: [:], summaries: [p.path: summary])
        XCTAssertEqual(moves.map(\.round), [3])
        XCTAssertEqual(MoveRow.title(moves[0]), "Finish Round 3…")
        let unknown = MoveItem(paper: p, status: .ready, round: nil)
        XCTAssertEqual(MoveRow.title(unknown), "Finish Round…")
        XCTAssertEqual(MoveRow.help(MoveItem(paper: p, status: .firstDraft, round: nil)), "Open Review")
        XCTAssertEqual(MoveRow.help(MoveItem(paper: p, status: .firstDraft, round: 2)), "Open Review at Round 2")
        XCTAssertEqual(Hierarchy.yourMove([p], status: { _ in .ready }, data: [:]).map(\.round), [nil])
    }

    // MARK: A5a-11 + A5b-15

    /// One rule for a test run (`LaunchOptions.isTestRun`): a --no-list model without --drafts, --cache or --tags
    /// keeps its drafts, thumbnails and tags in folders of its own (it wrote Dev's own before), saves no setting, and
    /// a unit test reads no papers list.
    func testATestRunNeverUsesTheAdvisorsPlaces() {
        _ = NSApplication.shared
        var o = LaunchOptions()
        o.noList = true
        XCTAssertTrue(o.isTestRun)
        let m = AppModel(options: o)
        XCTAssertTrue(m.testRun)
        XCTAssertNotEqual(m.draftStore.directory.standardizedFileURL, DraftStore.standard.standardizedFileURL)
        XCTAssertNotEqual(m.thumbnails.root.standardizedFileURL, ThumbnailStore.standardRoot.standardizedFileURL)
        XCTAssertEqual(m.tags.store.url, TagStore.temporary)
        XCTAssertEqual(m.papers, [])
        XCTAssertFalse(m.remembersPlace, "nor the last place (it is `isTestRun` too)")
        let key = "b15-probe-" + UUID().uuidString
        Prefs.set(true, key)
        XCTAssertNil(UserDefaults.standard.object(forKey: key), "a test run saves no setting")
        XCTAssertNil(Prefs.bool(key))
    }
}
