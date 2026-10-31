import XCTest
@testable import Paperole

/// All Students' board, Your Move's rows and the sidebar's trail (UI v4 step 7; UX.md §40.6) on the synthetic students
/// fixture: every paper in one lane, the lanes' orders and the eight-week cut, each card's figure and corner by state,
/// the ring's fill, day counters across midnight and DST, the view's choice, Your Move's one primary button.
final class BoardTests: XCTestCase {
    static let calendar = HierarchyDataTests.calendar
    static let today = HierarchyDataTests.day("2026-10-19")
    static let root = HierarchyDataTests.root

    private func fixture(finished: [String: String] = [:]) throws -> (papers: [PaperRef], statuses: [String: PaperStatus],
                                                                     summaries: [String: PaperSummary], data: [String: PaperOverview]) {
        let (r, data) = try FiguresTests.students()
        let papers = HierarchyDataTests.papers(r).map { p -> PaperRef in
            var p = p
            p.finished = finished[(p.path as NSString).lastPathComponent]
            return p
        }
        let summaries = data.compactMapValues(\.summary)
        let statuses = Dictionary(papers.compactMap { p in PaperStatus.of(summaries[p.path], finished: p.finished).map { (p.path, $0) } },
                                  uniquingKeysWith: { a, _ in a })
        return (papers, statuses, summaries, data)
    }

    private func names(_ cards: [BoardCard]) -> [String] { cards.map { ($0.path as NSString).lastPathComponent } }

    func testEveryPaperIsInOneLane() throws {
        var f = try fixture(finished: ["urchin": "2026-09-01", "shrimp": "2026-07-20"])
        f.statuses[Self.root + "kelp"] = nil  // its folder missing: no status (plan §5 R13)
        let b = BoardModel.make(f.papers, statuses: f.statuses, summaries: f.summaries, data: f.data,
                                missing: [Self.root + "kelp": "Its folder is missing"], today: Self.today, calendar: Self.calendar)
        XCTAssertEqual(b.lanes.map(\.kind), [.yourMove, .withStudents, .finished])
        XCTAssertEqual(names(b.lane(.yourMove).cards), ["mangrove", "reef", "seagrass", "draft"], "oldest arrival first")
        XCTAssertEqual(names(b.lane(.withStudents).cards), ["blue", "kelp"], "the missing folder with the students, after the dated")
        XCTAssertEqual(b.lane(.withStudents).cards.last?.figure, .missing("Its folder is missing"))
        XCTAssertNil(b.lane(.withStudents).cards.last?.glyph)
        XCTAssertEqual(names(b.lane(.finished).cards), ["urchin"], "finished 48 days ago: on the board")
        XCTAssertEqual(names(b.lane(.finished).earlier), ["shrimp"], "91 days ago: under Earlier")
        XCTAssertEqual(b.lane(.finished).count, 2, "the lane's count holds Earlier's")
        XCTAssertEqual(Set(b.lanes.flatMap { $0.cards + $0.earlier }.map(\.path)), Set(f.papers.map(\.path)), "no paper left out")
        XCTAssertEqual(b.lanes.map(\.count).reduce(0, +), f.papers.count)
        XCTAssertEqual(b.lane(.yourMove).detail, "3 to review or finish · 1 build failed", "the lane head's help")
        // before its summary is read a paper is in no lane; a damaged one is with the students in the sidebar's words
        f.statuses[Self.root + "reef"] = nil
        f.statuses[Self.root + "blue"] = nil
        let c = BoardModel.make(f.papers, statuses: f.statuses, summaries: f.summaries, data: f.data,
                                missing: [Self.root + "kelp": "Its folder is missing", Self.root + "blue": "Damaged: no ledger"],
                                today: Self.today, calendar: Self.calendar)
        XCTAssertFalse(c.lanes.flatMap { $0.cards + $0.earlier }.contains { $0.path == Self.root + "reef" })
        XCTAssertEqual(names(c.lane(.withStudents).cards), ["blue", "kelp"])
        XCTAssertEqual(c.lane(.withStudents).cards.first?.words(), "Damaged: no ledger")
    }

    func testTheLanesOrders() throws {
        let f = try fixture()
        let b = BoardModel.make(f.papers, statuses: f.statuses, summaries: f.summaries, data: f.data, today: Self.today, calendar: Self.calendar)
        XCTAssertEqual(names(b.lane(.withStudents).cards), ["urchin", "shrimp", "blue"], "the longest with the student first")
        XCTAssertTrue(b.lane(.finished).cards.isEmpty)
        // finished newest first; the cut: 55 days on the board, 56 under Earlier
        let g = try fixture(finished: ["urchin": "2026-08-25", "shrimp": "2026-08-24", "blue": "2026-10-10"])
        let c = BoardModel.make(g.papers, statuses: g.statuses, summaries: g.summaries, data: g.data, today: Self.today, calendar: Self.calendar)
        XCTAssertEqual(names(c.lane(.finished).cards), ["blue", "urchin"])
        XCTAssertEqual(names(c.lane(.finished).earlier), ["shrimp"])
        XCTAssertTrue(c.lane(.withStudents).cards.isEmpty)
    }

    func testTheCardsFigureAndCornerByState() throws {
        let f = try fixture(finished: ["shrimp": "2026-07-20"])
        func card(_ name: String) throws -> BoardCard {
            let p = try XCTUnwrap(f.papers.first { $0.path == Self.root + name })
            return BoardCard.make(p, status: f.statuses[p.path], summary: f.summaries[p.path], data: f.data[p.path],
                                  today: Self.today, calendar: Self.calendar)
        }
        let reef = try card("reef")
        XCTAssertEqual(reef.figure, .toCheck(PaperFigures.Count(comments: 3, edits: 5)))
        XCTAssertEqual([reef.who, reef.corner, reef.cornerHelp], ["Mei Lin", "3 d", "Came in Fri, Oct 16"])
        XCTAssertEqual(reef.words(), "3 comments + 5 edits")
        XCTAssertTrue(reef.map)
        XCTAssertNil(reef.fill, "nothing answered: an empty ring")
        XCTAssertEqual(reef.facts, "4 rounds since Sep 8 · 11 comments", "the old tile's facts, in the title's hover")
        let mangrove = try card("mangrove")
        XCTAssertEqual([mangrove.words(), mangrove.corner], ["Ready to finish", "6 d"])
        XCTAssertEqual(mangrove.glyph, .ready)
        let seagrass = try card("seagrass")
        XCTAssertEqual([seagrass.words(), seagrass.corner], ["Build failed · Round 3", "2 d"])
        let draft = try card("draft")
        XCTAssertEqual([draft.words(), draft.corner, draft.who], ["First draft", "1 d", "Unassigned"])
        XCTAssertEqual(draft.glyph, .ring(0))
        let blue = try card("blue")
        XCTAssertEqual([blue.words(), blue.words(state: true), blue.corner, blue.cornerHelp],
                       ["4 comments", "With Priya · 4 comments", "16 d", "Round 1 sent back Sat, Oct 3"])
        XCTAssertNil(blue.fill, "no to-check figure: no ring")
        XCTAssertEqual(blue.glyph, .waiting)
        let kelp = try card("kelp")
        XCTAssertEqual(kelp.figure, .toCheck(PaperFigures.Count(comments: 2, edits: 3)))
        let urchin = try card("urchin")
        XCTAssertEqual(urchin.words(), "4 comments · 4 closed", "with the student after Round 1: the closed follow")
        let shrimp = try card("shrimp")
        XCTAssertEqual([shrimp.words(), shrimp.words(state: true), shrimp.corner],
                       ["2 rounds · 4 of 4 closed", "Finished · 2 rounds · 4 of 4 closed", "Jul 20"])
        XCTAssertFalse(shrimp.map, "a finished paper has no mini map")
        let none = BoardCard.make(PaperRef(path: "/new", title: "Type Hints", student: "Leo Park"), status: .noRounds, summary: nil,
                                  data: nil, today: Self.today, calendar: Self.calendar)
        XCTAssertEqual([none.words(), none.corner], ["No rounds yet", nil])
        XCTAssertEqual(none.glyph, .noRounds)
        XCTAssertFalse(none.map)
        // partly answered (BRIEF §4 09): the ring a quarter full, the answers in its hover
        var s = PaperSummary(round: 3, closed: false, status: "ok", toJudge: 3, toCheck: 0)
        s.answered = 1
        s.handled = 0
        let leo = BoardCard.make(PaperRef(path: "/leo", title: "Retrieval", student: "Leo Park"), status: PaperStatus.of(s, finished: nil),
                                 summary: s, data: nil, today: Self.today, calendar: Self.calendar)
        XCTAssertEqual(leo.fill, 0.25)
        XCTAssertEqual(leo.glyph, .ring(0.25))
        XCTAssertEqual(leo.answered, "1 of 4 answered so far")
        XCTAssertNil(leo.corner, "no arrival day before the data")
        // the frozen engine's summary: an empty ring, never a guess
        let old = PaperSummary(round: 3, closed: false, status: "ok", toJudge: 3, toCheck: 0)
        XCTAssertNil(BoardCard.make(PaperRef(path: "/leo", title: "R", student: ""), status: PaperStatus.of(old, finished: nil),
                                    summary: old, data: nil, today: Self.today).fill)
    }

    func testTheCornerAcrossMidnightAndDST() throws {
        var ny = Calendar(identifier: .gregorian)
        ny.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        func at(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
        func corner(created: String, today: String) throws -> String? {
            let d = try FiguresTests.overview(#"{"sections": [], "comments": [], "pending": [], "rounds": [{"n": 2, "closed": false, "created": "\#(created)", "build": {"status": "ok"}}]}"#)
            return BoardCard.make(PaperRef(path: "/p", title: "P", student: ""), status: .toCheck(comments: 1, edits: 0), summary: nil,
                                  data: d, today: at(today), calendar: ny).corner
        }
        XCTAssertEqual(try corner(created: "2026-10-27T23:59:00-04:00", today: "2026-10-28T00:01:00-04:00"), "1 d", "across midnight")
        XCTAssertEqual(try corner(created: "2026-10-28T00:01:00-04:00", today: "2026-10-28T23:59:00-04:00"), "today")
        XCTAssertEqual(try corner(created: "2026-03-07T12:00:00-05:00", today: "2026-03-09T12:00:00-04:00"), "2 d", "spring forward")
        XCTAssertEqual(try corner(created: "2026-10-31T23:30:00-04:00", today: "2026-11-01T23:30:00-05:00"), "1 d", "fall back")
    }

    func testYourMovesRows() throws {
        let f = try fixture()
        let m = YourMoveModel.make(f.papers, statuses: f.statuses, summaries: f.summaries, data: f.data, today: Self.today,
                                   calendar: Self.calendar)
        XCTAssertEqual(names(m.rows.map(\.card)), ["mangrove", "kelp", "reef", "seagrass", "draft"])
        XCTAssertEqual(m.rows.map(\.primary), [true, false, false, false, false], "only the oldest row's button is primary")
        XCTAssertEqual(m.rows.map(\.sub).first, "Priya Nair · Round 3")
        XCTAssertEqual(m.rows.last?.sub, "Round 1", "no student")
        XCTAssertEqual(m.rows.map(\.days), [6, 4, 3, 2, 1])
        XCTAssertEqual(m.rows.first?.help, "Came in Tue, Oct 13")
        XCTAssertEqual(m.rows.compactMap { $0.card.item.map(MoveRow.title) }, ["Finish Round 3…", "Continue", "Continue", "Show Log…", "Continue"])
        XCTAssertEqual(names(m.quiet.map(\.card)), ["urchin", "shrimp", "blue"], "the papers with students, the longest away first")
        XCTAssertEqual([m.quiet.last?.sub, m.quiet.last?.help], ["Priya Nair · Round 1", "Sent back Sat, Oct 3"])
        XCTAssertTrue(m.quiet.allSatisfy { $0.card.item == nil && !$0.primary }, "no buttons")
        func waiting(_ n: Int?) -> [String?] { let w = YourMoveModel.waiting(n); return [w.value, w.unit] }
        XCTAssertEqual(waiting(16), ["16", "days"])
        XCTAssertEqual(waiting(1), ["1", "day"])
        XCTAssertEqual(waiting(0), ["today", nil])
        XCTAssertEqual(waiting(nil), ["–", nil], "before the data")
        // before the hierarchy's data: the rows from the summaries, "–" for the days
        let early = YourMoveModel.make(f.papers, statuses: f.statuses, summaries: f.summaries, data: [:], today: Self.today)
        XCTAssertEqual(early.rows.count, 5)
        XCTAssertTrue(early.rows.allSatisfy { $0.days == nil && $0.help == nil })
        XCTAssertEqual(early.rows.first?.primary, true)
        XCTAssertEqual(early.rows.first?.card.words(), "3 comments + 5 edits", "the figure from the summary")
    }

    func testTheSidebarsTrail() {
        XCTAssertEqual(SidebarTrail.of(.toCheck(comments: 14, edits: 2), fill: nil, isOpen: false),
                       SidebarTrail(glyph: .ring(0), size: 11, text: "14 + 2"))
        XCTAssertEqual(SidebarTrail.of(.toCheck(comments: 3, edits: 0), fill: 0.25, isOpen: false),
                       SidebarTrail(glyph: .ring(0.25), size: 11, text: "3"))
        XCTAssertEqual(SidebarTrail.of(.toCheck(comments: 0, edits: 2), fill: nil, isOpen: false).text, "+ 2")
        XCTAssertEqual(SidebarTrail.of(.toCheck(comments: 14, edits: 2), fill: nil, isOpen: true),
                       SidebarTrail(glyph: .ring(0), size: 11, text: nil), "the open paper: the ring only")
        XCTAssertEqual(SidebarTrail.of(.waiting, fill: nil, isOpen: false), SidebarTrail(glyph: .waiting, size: 12))
        XCTAssertEqual(SidebarTrail.of(.finished("2026-07-20"), fill: nil, isOpen: false), SidebarTrail(glyph: .finished, size: 11))
        XCTAssertEqual(SidebarTrail.of(.ready, fill: nil, isOpen: false).glyph, .ready)
        XCTAssertEqual(SidebarTrail.of(.failed, fill: nil, isOpen: false).glyph, .failed)
        XCTAssertEqual(SidebarTrail.of(.firstDraft, fill: 0.5, isOpen: false).glyph, .ring(0))
        XCTAssertEqual(SidebarTrail.of(.toRead(6), fill: nil, isOpen: false).glyph, .ring(1))
        XCTAssertEqual(SidebarTrail.of(.noRounds, fill: nil, isOpen: false).glyph, .noRounds)
    }

    /// Board | Students: Board by default, `--all-view` for a run, and a test run never writes the choice.
    @MainActor
    func testTheViewsChoice() throws {
        _ = NSApplication.shared
        XCTAssertNil(LaunchOptions.parse(["app"]).allView)
        XCTAssertEqual(LaunchOptions.parse(["app", "--all-view", "students"]).allView, .students)
        XCTAssertNil(LaunchOptions.parse(["app", "--all-view", "lanes"]).allView)
        let drafts = FileManager.default.temporaryDirectory.appendingPathComponent("pc-board-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: drafts) }
        var o = LaunchOptions()
        o.fixture = StepTests.fixtures.appendingPathComponent("state-m2a.json").path
        o.overviewFixture = HierarchyDataTests.fixture.path
        o.drafts = drafts.path
        let before = UserDefaults.standard.object(forKey: AppModel.allStudentsViewKey) as? String
        let m = AppModel(options: o)
        XCTAssertEqual(m.allStudentsView, .board)
        m.allStudentsView = .students
        XCTAssertEqual(m.allStudentsView, .students)
        XCTAssertEqual(UserDefaults.standard.object(forKey: AppModel.allStudentsViewKey) as? String, before, "never saved by a test run")
        o.allView = .students
        XCTAssertEqual(AppModel(options: o).allStudentsView, .students)
    }
}
