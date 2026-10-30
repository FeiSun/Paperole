import Foundation
import XCTest
@testable import Paperole

final class StateDecodingTests: XCTestCase {
    static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/state-round2.json")

    func testRound2Fixture() throws {
        let st = try EngineState.decode(Data(contentsOf: Self.fixture))
        XCTAssertEqual(st.schema, 1)
        XCTAssertEqual(st.paper.student, "Lin Zhou")
        XCTAssertEqual(st.rounds.map(\.n), [1, 2])
        let round = try XCTUnwrap(st.round)
        XCTAssertEqual(round.n, 2)
        XCTAssertFalse(round.closed)
        XCTAssertEqual(round.build.status, "ok")
        XCTAssertEqual(round.build.pages, 4)
        XCTAssertNil(round.build.textX)  // state from before text_x
        XCTAssertNil(round.finalPdf)

        let states = Set(st.comments.map(\.anchorState))
        XCTAssertEqual(states, ["new", "unchanged", "changed", "moved", "gone", "orphan"])
        let verdicts = Set(st.comments.compactMap(\.verdict))
        XCTAssertEqual(verdicts, ["verified", "reopened", "wontfix"])

        let r102 = try XCTUnwrap(st.comments.first { $0.id == "R1-02" })
        XCTAssertTrue(r102.carried)
        XCTAssertEqual(r102.verdict, "reopened")
        XCTAssertEqual(r102.verdictNote, "还是没说清楚和 Hybrid 的区别。")
        XCTAssertEqual(r102.changes, ["c02"])
        XCTAssertEqual(r102.history, [HistoryEntry(round: 1, anchorState: "new", verdict: nil, verdictNote: "")])
        XCTAssertEqual(r102.rects.count, 2)

        let gone = try XCTUnwrap(st.comments.first { $0.anchorState == "gone" })
        XCTAssertEqual(gone.newQuote, "")
        let orphan = try XCTUnwrap(st.comments.first { $0.anchorState == "orphan" })
        XCTAssertNil(orphan.page)
        XCTAssertNil(orphan.newQuote)
        XCTAssertNil(orphan.file)
        XCTAssertEqual(Status(orphan), .notFound)
        XCTAssertFalse(r102.lowConfidence)

        let fresh = st.comments.filter { !$0.carried }
        XCTAssertFalse(fresh.isEmpty)
        XCTAssertTrue(fresh.allSatisfy { $0.anchorState == "new" && $0.oldQuote == nil && $0.verdict == nil })
        XCTAssertTrue(st.comments.contains { $0.kind == "strikeout" })
        XCTAssertTrue(st.comments.contains { $0.kind == "note" })

        XCTAssertEqual(st.changes.map(\.id), ["c01", "c02", "c03", "c04", "c05", "c06", "c07"])
        XCTAssertEqual(st.changes.filter(\.unrequested).map(\.id), ["c03", "c06"])
        XCTAssertEqual(Set(st.changes.map(\.kind)), ["replace", "delete", "move", "insert"])
        XCTAssertTrue(st.changes.allSatisfy { $0.unrequested == $0.attachedTo.isEmpty })
    }

    func testCarriedCardsComeFirst() throws {
        let st = try EngineState.decode(Data(contentsOf: Self.fixture))
        let ordered = AppModel.ordered(st.comments)
        let firstNew = try XCTUnwrap(ordered.firstIndex { !$0.carried })
        XCTAssertTrue(ordered[..<firstNew].allSatisfy(\.carried))
        XCTAssertTrue(ordered[firstNew...].allSatisfy { !$0.carried })
        // Document order is kept within each group.
        XCTAssertEqual(ordered.filter(\.carried).map(\.id), st.comments.filter(\.carried).map(\.id))
    }

    func testBeforeFirstIngestAndFailedBuild() throws {
        let empty = """
        {"schema": 1, "paper": {"path": "/p", "title": "T", "student": "S", "main": null, "engine": null},
         "rounds": [], "round": null, "comments": [], "changes": []}
        """
        let st = try EngineState.decode(Data(empty.utf8))
        XCTAssertNil(st.round)
        XCTAssertNil(st.paper.main)

        let failed = """
        {"schema": 1, "paper": {"path": "/p", "title": "T", "student": "S", "main": "main.tex", "engine": "pdflatex"},
         "rounds": [{"n": 1, "created": "2026-10-14T10:00:00+08:00", "source": "/src", "closed": false, "closed_at": null,
                     "status": "failed"}],
         "round": {"n": 1, "closed": false, "created": "2026-10-14T10:00:00+08:00", "closed_at": null,
                   "build": {"status": "failed", "pdf": null, "pages": null, "text_x": [], "warnings": [],
                             "errors": [{"file": "main.tex", "line": 12, "message": "Undefined control sequence."},
                                        {"file": null, "line": null, "message": "Emergency stop."}],
                             "log_tail": "! Emergency stop."},
                   "final_pdf": null, "email": null},
         "comments": [], "changes": [], "future_key": {"ignored": true}}
        """
        let f = try EngineState.decode(Data(failed.utf8))
        XCTAssertEqual(f.round?.build.status, "failed")
        XCTAssertNil(f.round?.build.pdf)
        XCTAssertEqual(f.round?.build.errors.count, 2)
        XCTAssertEqual(f.round?.build.logTail, "! Emergency stop.")
        XCTAssertEqual(f.round?.build.textX, [])

        let extents = try makeDecoder().decode(Build.self, from: Data("""
        {"status": "ok", "pdf": "/p/r1/build/main.pdf", "pages": 2, "text_x": [[107.67, 505.75], null],
         "warnings": [], "errors": [], "log_tail": ""}
        """.utf8))
        XCTAssertEqual(extents.textX, [[107.67, 505.75], nil])
    }

    func testSummaryAndNextStep() throws {
        let st = try EngineState.decode(Data("""
        {"schema": 1, "paper": {"path": "/p", "title": "T", "student": "S", "main": "main.tex", "engine": "pdflatex"},
         "rounds": [], "round": null, "comments": [], "changes": [],
         "summary": {"round": 3, "closed": false, "status": "ok", "to_judge": 2, "to_check": 3}}
        """.utf8))
        let s = try XCTUnwrap(st.summary)
        XCTAssertEqual(s.text, "To check")
        XCTAssertEqual(s.badge, 5)
        XCTAssertEqual(s.detail, "2 comments to check · 3 other edits to check")  // the gentle word, as Finish says it
        XCTAssertNil(try EngineState.decode(Data(contentsOf: Self.fixture)).summary)  // a state from before summary

        func step(_ n: Int?, closed: Bool = false, _ status: String? = "ok", judge: Int = 0, check: Int = 0) -> String {
            PaperSummary(round: n, closed: closed, status: status, toJudge: judge, toCheck: check).text
        }
        XCTAssertEqual(step(nil, nil), "No rounds yet")
        XCTAssertEqual(step(2, closed: true), "Waiting for student")
        XCTAssertEqual(step(1, "failed"), "Build failed")
        XCTAssertEqual(step(3, "errors", check: 1), "To check")
        XCTAssertEqual(step(3), "Ready to finish")
        XCTAssertEqual(step(1), "Round 1 in progress")  // round 1 has nothing to compare

        let reply = try makeDecoder().decode(SummariesReply.self, from: Data("""
        {"papers": [{"path": "/a", "summary": {"round": 1, "closed": true, "status": "ok", "to_judge": 0, "to_check": 0}},
                    {"path": "/gone", "error": "/gone is not a Paperole paper folder (no ledger.json)."}]}
        """.utf8))
        XCTAssertEqual(reply.papers.map(\.path), ["/a", "/gone"])
        XCTAssertEqual(reply.papers.map { $0.summary?.text }, ["Waiting for student", nil])
    }

    /// design/ui-v2/PROPOSAL.md §6, addition 10: the window subtitle says what is to check with the numbers of the
    /// panel's tabs (the shown open round's own when given), and names no round.
    func testWindowSubtitle() {
        func summary(_ n: Int?, closed: Bool = false, _ status: String? = "ok", judge: Int = 0, check: Int = 0) -> PaperSummary {
            PaperSummary(round: n, closed: closed, status: status, toJudge: judge, toCheck: check)
        }
        XCTAssertEqual(summary(3, judge: 7, check: 2).subtitle(), "7 comments and 2 edits to check")
        XCTAssertEqual(summary(3, judge: 7, check: 2).subtitle(comments: 1, edits: 0), "1 comment to check")
        XCTAssertEqual(summary(3, judge: 1).subtitle(comments: 0, edits: 1), "1 edit to check")
        XCTAssertEqual(summary(3).subtitle(comments: 0, edits: 0), "ready to finish")
        XCTAssertEqual(summary(1).subtitle(), "in progress")
        XCTAssertEqual(summary(2, closed: true).subtitle(), "waiting for student")
        XCTAssertEqual(summary(2, "failed").subtitle(), "build failed")
        XCTAssertNil(summary(3).badge)
        // the shown open round's changed paragraphs to read (interaction review 2026-10-18: "ready to finish" over "6 to
        // read"), which the engine's summary does not count: only when nothing is left to check
        var reading = summary(3)
        reading.unread = 6
        XCTAssertEqual(reading.subtitle(comments: 0, edits: 0), "6 changed paragraphs to read")
        XCTAssertEqual(reading.text, "Paragraphs to read")
        XCTAssertEqual(reading.step, .toRead(6))
        XCTAssertNil(reading.badge)
        reading.toJudge = 1
        XCTAssertEqual(reading.subtitle(), "1 comment to check")
        XCTAssertEqual(reading.text, "To check")
        var first = summary(1)
        first.unread = 4
        XCTAssertEqual(first.text, "Round 1 in progress", "round 1 reads nothing")
    }

    func testRoundPickerTitles() {
        let r = RoundSummary(n: 1, created: "2026-10-14T10:00:00+08:00", source: "/s", closed: true, closedAt: nil, status: "ok")
        XCTAssertEqual(RoundPicker.title(r), "Round 1 · Oct 14 · closed")
        XCTAssertEqual(RoundPicker.title(RoundSummary(n: 2, created: nil, closed: false, status: "failed")), "Round 2 · build failed")
        XCTAssertEqual(RoundPicker.title(RoundSummary(n: 3, created: "2026-10-16T23:30:00+08:00", closed: false, status: "ok")),
                       "Round 3 · Oct 16 · open")
        XCTAssertNil(shortDate("yesterday"))
    }

    func testRepeatedPaperArguments() {
        let o = LaunchOptions.parse(["app", "--background", "--paper", "/a", "--paper", "/b", "--paper", "/c", "--tab", "changes"])
        XCTAssertEqual(o.paper, "/a")
        XCTAssertEqual(o.morePapers, ["/b", "/c"])
        XCTAssertEqual(o.tab, "changes")
    }

    func testReplyWithId() throws {
        let data = try Data(contentsOf: Self.fixture)
        let state = String(decoding: data, as: UTF8.self)
        let reply = try makeDecoder().decode(Reply.self, from: Data(("{\"id\": \"R2-05\", \"state\": " + state + "}").utf8))
        XCTAssertEqual(reply.id, "R2-05")
        XCTAssertEqual(reply.state.round?.n, 2)
    }
}
