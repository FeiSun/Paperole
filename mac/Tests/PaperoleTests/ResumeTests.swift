import AppKit
import XCTest
@testable import Paperole

/// Resume Round N (UX.md §31; CONTRACT amendment "Resume a finished round"): the new state fields, where Resume shows
/// (the latest round, finished, and nowhere else), the confirmation's words, the Finish sheet's line for a resumed
/// round, the history's label, and with the engine the round open again in Review. Synthetic fixtures and temporary
/// folders only.
@MainActor
final class ResumeTests: XCTestCase {
    private var tmp: URL!
    private var fm: FileManager { .default }

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("pc-resume-" + UUID().uuidString)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: tmp)
    }

    private func fixtureModel() -> AppModel {
        _ = NSApplication.shared
        var o = LaunchOptions()
        o.fixture = StepTests.fixtures.appendingPathComponent("state-m2a.json").path
        o.drafts = tmp.appendingPathComponent("drafts").path
        o.cache = tmp.appendingPathComponent("cache").path
        o.tags = tmp.appendingPathComponent("tags/tags.json").path
        return AppModel(options: o)
    }

    /// The fixture's state (round 1 closed, round 2 open and shown), changed as the engine would send it.
    private func state(_ change: (inout [String: Any]) -> Void) throws -> EngineState {
        let url = StepTests.fixtures.appendingPathComponent("state-m2a.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        change(&json)
        return try EngineState.decode(JSONSerialization.data(withJSONObject: json))
    }

    private static let finishedAt = "2026-10-21T15:30:00+08:00"

    /// Round 2, the latest, finished; `flags`: with the engine's `resumable` keys (a fixture or an older engine has none).
    private func finished(flags: Bool = true) throws -> EngineState {
        try state { json in
            var rounds = json["rounds"] as? [[String: Any]] ?? []
            rounds[1]["closed"] = true
            rounds[1]["closed_at"] = Self.finishedAt
            json["rounds"] = rounds
            var r = json["round"] as? [String: Any] ?? [:]
            r["closed"] = true
            r["closed_at"] = Self.finishedAt
            var s: [String: Any] = ["round": 2, "closed": true, "status": "ok", "to_judge": 0, "to_check": 0]
            if flags {
                r["resumable"] = true
                r["finishes"] = [] as [Any]
                s["closed_at"] = Self.finishedAt
                s["resumable"] = true
            }
            json["round"] = r
            json["summary"] = s
        }
    }

    // MARK: Decoding

    /// The engine's new keys: `round.resumable` and `round.finishes` (absolute paths, null when a file is not there),
    /// `summary.closed_at` and `summary.resumable`, in a state and in `summaries`; a state without them reads as before.
    func testTheNewStateFieldsDecode() throws {
        let st = try state { json in
            var r = json["round"] as? [String: Any] ?? [:]
            r["resumable"] = false
            r["finishes"] = [["at": Self.finishedAt, "resumed": "2026-10-22T09:00:00+08:00",
                              "final": "/r/kelp/r2/earlier/final 2026-10-21 1530.pdf", "email": NSNull()]]
            json["round"] = r
            json["summary"] = ["round": 2, "closed": false, "status": "ok", "to_judge": 3, "to_check": 1,
                               "closed_at": NSNull(), "resumable": false]
        }
        let round = try XCTUnwrap(st.round)
        XCTAssertEqual(round.resumable, false)
        XCTAssertEqual(round.finishes, [RoundInfo.Finish(at: Self.finishedAt, resumed: "2026-10-22T09:00:00+08:00",
                                                         final: "/r/kelp/r2/earlier/final 2026-10-21 1530.pdf", email: nil)])
        XCTAssertEqual(st.summary?.resumable, false)
        XCTAssertNil(st.summary?.closedAt)
        XCTAssertEqual(st.summary?.step, .toCheck(4), "a resumed round is your move again")

        let old = try state { _ in }
        XCTAssertNil(old.round?.resumable)
        XCTAssertNil(old.round?.finishes)

        let reply = try makeDecoder().decode(SummariesReply.self, from: Data("""
            {"papers": [{"path": "/r/kelp", "summary": {"round": 1, "closed": true, "status": "ok", "to_judge": 0,
                         "to_check": 0, "closed_at": "\(Self.finishedAt)", "resumable": true}},
                        {"path": "/r/reef", "summary": {"round": 2, "closed": false, "status": "ok", "to_judge": 0,
                         "to_check": 0}}]}
            """.utf8))
        XCTAssertEqual(reply.papers[0].summary?.resumable, true)
        XCTAssertEqual(reply.papers[0].summary?.closedAt, Self.finishedAt)
        XCTAssertEqual(reply.papers[0].summary?.step, .waiting)
        XCTAssertNil(reply.papers[1].summary?.resumable, "from an engine before Resume")
    }

    // MARK: Where it shows

    /// Only the latest round, finished, as the engine says: the read-only box's button, the round menu, the overview's
    /// More menu and the paper's context menu (`resumable`, `canResumeShown`). Never in an open round, never for an
    /// earlier round (its box says Back to Round N), and never without the engine's flag (a Dev fixture).
    func testResumeShowsOnlyForTheLatestFinishedRound() throws {
        let m = fixtureModel()
        let path = try XCTUnwrap(m.selectedPath)

        m.apply(try finished())
        XCTAssertEqual(m.resumable(), ResumeAsk(paper: path, round: 2, closedAt: Self.finishedAt))
        XCTAssertEqual(m.resumable(path), m.resumable(), "the paper's context menu says the same")
        XCTAssertTrue(m.canResumeShown)
        XCTAssertNil(m.resumable("/Users/advisor/Reviews/another"), "a paper without a summary")

        // the fixture as it is: round 2 open
        m.apply(try state { _ in })
        XCTAssertNil(m.resumable())
        XCTAssertFalse(m.canResumeShown)
        // open, even if a summary said resumable
        m.apply(try state { json in
            json["summary"] = ["round": 2, "closed": false, "status": "ok", "to_judge": 0, "to_check": 0, "resumable": true]
        })
        XCTAssertNil(m.resumable())
        XCTAssertFalse(m.canResumeShown)

        // finished, without the engine's flags (a Dev fixture, an older engine)
        m.apply(try finished(flags: false))
        XCTAssertTrue(m.round?.closed == true)
        XCTAssertNil(m.resumable())
        XCTAssertFalse(m.canResumeShown)

        // round 1 shown while round 2 is open: round 1 stays finished for good
        func roundOne(latestFinished: Bool) throws -> EngineState {
            try state { json in
                json["round"] = ["n": 1, "closed": true, "created": "2026-10-07T09:12:40+08:00",
                                 "closed_at": "2026-10-08T21:30:05+08:00", "build": (json["round"] as? [String: Any])?["build"] ?? [:],
                                 "final_pdf": NSNull(), "email": NSNull(), "resumable": false, "finishes": [] as [Any]]
                if latestFinished {
                    var rounds = json["rounds"] as? [[String: Any]] ?? []
                    rounds[1]["closed"] = true
                    rounds[1]["closed_at"] = Self.finishedAt
                    json["rounds"] = rounds
                }
                json["summary"] = ["round": 2, "closed": latestFinished, "status": "ok", "to_judge": 0, "to_check": 0,
                                   "closed_at": latestFinished ? Self.finishedAt as Any : NSNull(), "resumable": latestFinished]
            }
        }
        m.apply(try roundOne(latestFinished: false))
        XCTAssertTrue(m.viewingEarlierRound)
        XCTAssertNil(m.resumable())
        XCTAssertFalse(m.canResumeShown)

        // round 1 shown while round 2 is finished: no button in round 1's box; the round menu offers Round 2 only
        m.apply(try roundOne(latestFinished: true))
        XCTAssertTrue(m.viewingEarlierRound)
        XCTAssertFalse(m.canResumeShown)
        XCTAssertEqual(m.resumable()?.round, 2)
    }

    /// Resume asks first; it needs the flag (a beep otherwise); in a fixture run nothing is sent and the round stays
    /// as it was.
    func testResumeAsksFirst() throws {
        let m = fixtureModel()
        m.askResume()
        XCTAssertNil(m.confirmResume, "round 2 is open: nothing to ask")
        m.apply(try finished())
        m.askResume()
        let a = try XCTUnwrap(m.confirmResume)
        XCTAssertEqual(a.title, "Resume Round 2?")
        m.resumeRound(a)
        XCTAssertNil(m.confirmResume)
        XCTAssertEqual(m.alertMessage, "Fixture mode: the engine is not running, so nothing is saved.")
        XCTAssertEqual(m.round?.closed, true)
    }

    /// Round 2 open again after a Resume: its earlier finish recorded; `change` as `state`'s.
    private func resumed(_ change: (inout [String: Any]) -> Void = { _ in }) throws -> EngineState {
        try state { json in
            var r = json["round"] as? [String: Any] ?? [:]
            r["resumable"] = false
            r["finishes"] = [["at": Self.finishedAt, "resumed": "2026-10-22T09:00:00+08:00", "final": NSNull(),
                              "email": NSNull()]]
            json["round"] = r
            change(&json)
        }
    }

    // MARK: In the resumed round

    /// Undo starts afresh: an answer given before the earlier Finish (it went to the student in that email) is not
    /// undone from the resumed round.
    func testUndoStartsAfreshInAResumedRound() throws {
        let m = fixtureModel()
        let key = try XCTUnwrap(m.draftsKey)
        let id = try XCTUnwrap(m.state?.comments.first { $0.carried && $0.verdict == nil }?.id)
        m.answered(id, before: Answer(verdict: nil), after: Answer(verdict: "verified"), on: key)
        XCTAssertEqual(m.history.undos.count, 1)
        m.apply(try finished())
        m.apply(try resumed())
        XCTAssertTrue(m.roundIsOpen)
        XCTAssertTrue(m.history.undos.isEmpty)
        m.undo()
        XCTAssertEqual(m.panelToast.text, "Nothing to undo")
    }

    /// Build Round N Again… is not offered in a resumed round, even without comments of its own: the engine's ingest
    /// refuses to replace it (that would delete rN/earlier/).
    func testAResumedRoundIsNotBuiltAgain() throws {
        let m = fixtureModel()
        m.apply(try state { json in json["comments"] = [] as [Any] })
        XCTAssertTrue(m.canBuildAgain, "an open round without comments")
        m.apply(try resumed { json in json["comments"] = [] as [Any] })
        XCTAssertTrue(m.roundIsOpen)
        XCTAssertFalse(m.canBuildAgain)
    }

    // MARK: Words

    /// The confirmation names the earlier finish's day, and says nothing is lost.
    func testTheConfirmationNamesTheFinish() {
        let a = ResumeAsk(paper: "/r/kelp", round: 2, closedAt: Self.finishedAt)
        XCTAssertEqual(a.title, "Resume Round 2?")
        XCTAssertEqual(a.message, "You can add and change comments, then finish the round again. The final.pdf and email "
                       + "from Oct 21 stay in the round’s folder.")
        XCTAssertEqual(ResumeAsk(paper: "/r/kelp", round: 1, closedAt: nil).message,
                       "You can add and change comments, then finish the round again. The final.pdf and email stay in "
                       + "the round’s folder.")
    }

    /// The Finish sheet of a resumed round says once that the earlier files are kept (each day once), and Show in Finder
    /// selects those that are there.
    func testTheFinishSheetSaysWhatWasKept() throws {
        typealias F = RoundInfo.Finish
        XCTAssertNil(FinishSummary.finishedBefore([]), "a round never resumed")
        let oct21 = F(at: Self.finishedAt, resumed: nil, final: nil, email: nil)
        XCTAssertEqual(FinishSummary.finishedBefore([oct21]),
                       "Finished before on Oct 21. Those files are kept in the round’s folder.")
        XCTAssertEqual(FinishSummary.finishedBefore([oct21, F(at: "2026-10-21T17:05:00+08:00")]),
                       "Finished before on Oct 21. Those files are kept in the round’s folder.", "the same day once")
        XCTAssertEqual(FinishSummary.finishedBefore([F(at: "2026-10-20T10:00:00+08:00"), oct21, F(at: "2026-10-23T10:00:00+08:00")]),
                       "Finished before on Oct 20, Oct 21 and Oct 23. Those files are kept in the round’s folder.")
        XCTAssertEqual(FinishSummary.finishedBefore([F(at: nil)]), "Finished before. Those files are kept in the round’s folder.")

        let final = tmp.appendingPathComponent("final 2026-10-21 1530.pdf")
        try Data("%PDF".utf8).write(to: final)
        let kept = FinishSummary.keptFiles([F(at: Self.finishedAt, final: final.path,
                                              email: tmp.appendingPathComponent("email 2026-10-21 1530.txt").path),
                                            F(at: nil, final: nil, email: nil)])
        XCTAssertEqual(kept.map(\.path), [final.path], "only the files that are there")
    }

    /// Put Back an Earlier Ledger… names the version from before a Resume.
    func testTheHistoryNamesAResume() {
        let v = LedgerHistory.Version(name: "20261022T010000Z-7-resume.json", time: "2026-10-22T09:00:00+08:00", rev: 7,
                                      kind: "resume", comments: 4, rounds: 2)
        XCTAssertTrue(v.words.hasSuffix(" · 2 rounds · 4 comments · before a round was resumed"), v.words)
    }

    // MARK: With the engine

    private func rpc(_ m: AppModel, _ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let data = try await m.engine.call(method, params: JSONSerialization.data(withJSONObject: params))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func waitUntil(_ done: () -> Bool) async throws {
        for _ in 0..<400 where !done() { try await Task.sleep(nanoseconds: 50_000_000) }
    }

    /// A synthetic paper's round 1, finished, resumed from Review: the confirmation, then Review shows round 1 open on
    /// the Comments tab, your move again, with nothing to resume; the earlier final.pdf and email are kept in
    /// r1/earlier/, and the Finish sheet's line names them. Finished again, round 1 has a new final.pdf beside them and
    /// can be resumed again.
    func testResumeOpensTheRoundInReview() async throws {
        guard fm.isExecutableFile(atPath: EngineClient.defaultPython), fm.fileExists(atPath: "/Library/TeX/texbin/latexmk") else {
            throw XCTSkip("needs the engine's Python and latexmk")
        }
        _ = NSApplication.shared
        var o = LaunchOptions()
        o.noList = true
        o.drafts = tmp.appendingPathComponent("drafts").path
        o.cache = tmp.appendingPathComponent("cache").path
        o.tags = tmp.appendingPathComponent("tags/tags.json").path
        let m = AppModel(options: o)
        let folder = tmp.appendingPathComponent("kelp-review"), src = tmp.appendingPathComponent("src")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try Data("\\documentclass{article}\n\\begin{document}\n\\section{Intro}\nKelp drifts in the bay.\n\\end{document}\n".utf8)
            .write(to: src.appendingPathComponent("main.tex"))
        _ = try await rpc(m, "new", ["paper": folder.path, "title": "Kelp drift", "student": "Mei Lin"])
        _ = try await rpc(m, "ingest", ["paper": folder.path, "source": src.path])
        _ = try await rpc(m, "comment", ["paper": folder.path, "page": 0, "rects": [[133.7, 148.8, 230.2, 158.8]],
                                         "text": "Kelp drifts in the bay.", "note": "Which bay?", "kind": "highlight"])
        _ = try await rpc(m, "finish", ["paper": folder.path])
        let path = folder.standardizedFileURL.path
        m.papers = [PaperRef(path: path, title: "Kelp drift", student: "Mei Lin", factsMoved: true)]
        m.openPaper(path, level: .review)
        try await waitUntil { m.state?.round?.closed == true && !m.busy }
        XCTAssertTrue(m.canResumeShown)
        XCTAssertEqual(m.resumable()?.round, 1)
        XCTAssertEqual(m.status(of: m.papers[0]), .waiting)
        let finishedAt = try XCTUnwrap(m.state?.round?.closedAt)

        m.askResume()
        let a = try XCTUnwrap(m.confirmResume)
        XCTAssertEqual(a.closedAt, finishedAt)
        m.showAllRounds()  // asked from the overview's More menu: Review shows the round after
        m.resumeRound(a)
        try await waitUntil { m.state?.round?.closed == false && !m.busy }
        XCTAssertNil(m.alertMessage)
        let round = try XCTUnwrap(m.round)
        XCTAssertEqual(round.n, 1)
        XCTAssertFalse(round.closed)
        XCTAssertNil(round.finalPdf)
        XCTAssertEqual(m.level, .review)
        XCTAssertEqual(m.tab, .comments)
        XCTAssertTrue(m.roundIsOpen)
        XCTAssertEqual(m.state?.comments.map(\.id), ["R1-01"], "its comments as they were")
        XCTAssertNil(m.resumable())
        XCTAssertFalse(m.canResumeShown)
        XCTAssertEqual(m.status(of: m.papers[0]), .firstDraft, "your move again")
        XCTAssertEqual(m.reading.toast, "Round 1 is open again · finish it again when you are done")

        let finishes = try XCTUnwrap(round.finishes)
        XCTAssertEqual(finishes.count, 1)
        XCTAssertEqual(finishes[0].at, finishedAt)
        let earlier = folder.appendingPathComponent("r1/earlier")
        let kept = try fm.contentsOfDirectory(atPath: earlier.path).sorted()
        XCTAssertEqual(kept.count, 3, "\(kept)")
        XCTAssertEqual(Set(kept.map { $0.split(separator: " ")[0] }), ["final", "email", "manifest-sha256"])
        XCTAssertEqual(FinishSummary.keptFiles(finishes).map(\.lastPathComponent).sorted(), kept.filter { !$0.hasPrefix("manifest") }.sorted())
        XCTAssertFalse(fm.fileExists(atPath: folder.appendingPathComponent("r1/final.pdf").path))
        XCTAssertNotNil(FinishSummary.finishedBefore(finishes))

        // finished again (the engine directly: the app's Finish copies to the clipboard): a new final.pdf, the kept ones
        let reply = try await rpc(m, "finish", ["paper": path])
        let st = try XCTUnwrap(reply["state"] as? [String: Any])
        let again = try XCTUnwrap(st["round"] as? [String: Any])
        XCTAssertEqual(again["closed"] as? Bool, true)
        XCTAssertEqual(again["resumable"] as? Bool, true)
        XCTAssertEqual((again["finishes"] as? [Any])?.count, 1)
        XCTAssertTrue(fm.fileExists(atPath: folder.appendingPathComponent("r1/final.pdf").path))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: earlier.path).sorted(), kept)
    }
}
