import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Paperole

/// The hierarchy (UX.md §22; OVERVIEW-v2 §3.1–3.2, §8 decisions 8 and 10; FEATURES OV-7–OV-9): students grouped as the
/// engine groups them, whose move each paper is, Your Move's order and the one count every level says, the pages'
/// words, the small maps and the timeline, the sidebar's rows, the navigation through the pages, and the pages drawn
/// at the three window widths. Synthetic only: `Fixtures/overview-students.json` is the engine's `overview` of eight
/// papers it built for four made-up students and one paper without a student (paths replaced).
final class HierarchyDataTests: XCTestCase {
    static let fixture = OverviewDataTests.fixtures.appendingPathComponent("overview-students.json")
    static let root = "/tmp/synthetic/students/"

    static func reply() throws -> OverviewReply {
        try PaperOverview.decodeReply(Data(contentsOf: fixture))
    }

    static func papers(_ r: OverviewReply) -> [PaperRef] {
        r.papers.map { PaperRef(path: $0.path, title: $0.overview?.paper?.title ?? "", student: $0.overview?.paper?.student ?? "") }
    }

    /// Asia/Shanghai, as the fixture's times (+08:00), so days and weekdays do not depend on where the test runs.
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        return c
    }

    static func day(_ s: String) -> Date { Hierarchy.date(s + "T12:00:00+08:00")! }

    func testStudentsAreGroupedAsTheEngineGroupsThem() {
        XCTAssertEqual(StudentName.key("Mei Lin"), StudentName.key("  mei   LIN "))
        XCTAssertEqual(StudentName.key("Mei Lin"), StudentName.key("MeiLin"))
        XCTAssertEqual(StudentName.key("Mei Lin"), StudentName.key("Ｍｅｉ Ｌｉｎ"), "compatibility forms (NFKC), as overview.fold")
        XCTAssertNotEqual(StudentName.key("Tomás Ruiz"), StudentName.key("Tomas Ruiz"))
        XCTAssertEqual(StudentName.key(""), "")
        XCTAssertEqual(StudentName.initials("Tomás  Ruiz"), "TR")
        let ps = [PaperRef(path: "/a", title: "A", student: "mei lin"), PaperRef(path: "/b", title: "B", student: "Jonas Berg"),
                  PaperRef(path: "/c", title: "C", student: ""), PaperRef(path: "/d", title: "D", student: "Mei  Lin"),
                  PaperRef(path: "/e", title: "E", student: "Mei Lin", finished: "2026-07-20")]
        let status: (PaperRef) -> PaperStatus? = { $0.finished != nil ? .finished($0.finished!) : .waiting }
        let g = Hierarchy.groups(ps, status: status)
        XCTAssertEqual(g.map(\.name), ["Jonas Berg", "mei lin", "Unassigned"], "by name, the first listed spelling; Unassigned last")
        XCTAssertEqual(g[1].papers.map(\.path), ["/a", "/d", "/e"])
        let finishedFirst = [ps[4], ps[0]]
        XCTAssertEqual(Hierarchy.groups(finishedFirst, status: status)[0].papers.map(\.path), ["/a", "/e"], "finished papers after the others")
        XCTAssertTrue(g[2].unassigned)
    }

    /// Decision 10: a paper waits on you while a round is open, a failed build included; the Finished mark only while
    /// its latest round is closed.
    func testWhoseMoveItIs() {
        func s(_ round: Int?, closed: Bool = false, status: String? = "ok", judge: Int = 0, check: Int = 0, unread: Int? = nil) -> PaperSummary {
            PaperSummary(round: round, closed: closed, status: status, toJudge: judge, toCheck: check, unread: unread)
        }
        XCTAssertEqual(PaperStatus.of(s(4, judge: 3, check: 5), finished: nil), .toCheck(comments: 3, edits: 5))
        XCTAssertEqual(PaperStatus.of(s(3), finished: nil), .ready)
        XCTAssertEqual(PaperStatus.of(s(1), finished: nil), .firstDraft)
        XCTAssertEqual(PaperStatus.of(s(3, status: "failed"), finished: nil), .failed)
        XCTAssertEqual(PaperStatus.of(s(2, unread: 6), finished: nil), .toRead(6))
        XCTAssertEqual(PaperStatus.of(s(2, closed: true), finished: nil), .waiting)
        XCTAssertEqual(PaperStatus.of(s(2, closed: true), finished: "2026-07-20"), .finished("2026-07-20"))
        XCTAssertEqual(PaperStatus.of(s(3, judge: 1), finished: "2026-07-20"), .toCheck(comments: 1, edits: 0),
                       "a new round of a finished paper is your move again")
        XCTAssertEqual(PaperStatus.of(s(nil), finished: nil), .noRounds)
        XCTAssertNil(PaperStatus.of(nil, finished: nil))
        let mine: [PaperStatus] = [.firstDraft, .toCheck(comments: 1, edits: 0), .toRead(2), .ready, .failed]
        XCTAssertTrue(mine.allSatisfy(\.yourMove))
        XCTAssertFalse([PaperStatus.waiting, .finished("x"), .noRounds].contains(where: \.yourMove))
        XCTAssertEqual(PaperStatus.toCheck(comments: 3, edits: 5).badge, 8)
        XCTAssertNil(PaperStatus.ready.badge)
    }

    /// Your Move: the earliest import first; to review or finish, and failed builds, counted apart.
    func testYourMoveIsOldestFirst() throws {
        let r = try Self.reply()
        let papers = Self.papers(r)
        let data = Dictionary(r.papers.compactMap { e in e.overview.map { (e.path, $0) } }, uniquingKeysWith: { a, _ in a })
        let status: (PaperRef) -> PaperStatus? = { PaperStatus.of(data[$0.path]?.summary, finished: nil) }
        let moves = Hierarchy.yourMove(papers, status: status, data: data)
        XCTAssertEqual(moves.map(\.paper.title), ["Mangrove sediment cores", "Kelp forest drift", "Reef choruses",
                                                  "Seagrass carbon budget", "Untitled draft"])
        XCTAssertEqual(moves.map(\.round), [3, 4, 4, 3, 1])
        XCTAssertTrue(Hierarchy.counts(moves) == (4, 1))
        // without the overview's dates, the list's order
        let undated = Hierarchy.yourMove(papers, status: status, data: [:])
        XCTAssertEqual(undated.map(\.paper.title), ["Reef choruses", "Kelp forest drift", "Mangrove sediment cores",
                                                    "Seagrass carbon budget", "Untitled draft"])
    }

    func testTheEnginesStudentsDecode() throws {
        let r = try Self.reply()
        let mei = try XCTUnwrap(r.students?.first { $0.student == "Mei Lin" })
        XCTAssertEqual(mei.papers, [Self.root + "reef", Self.root + "shrimp"])
        XCTAssertEqual(mei.comments, 15)
        XCTAssertEqual(mei.land?.columns.map(\.title), ["Abstract", "Introduction", "Methods", "Results", "Discussion"])
        XCTAssertEqual(mei.land?.total, [0, 2, 5, 4, 4])
        XCTAssertEqual(mei.closed?.total.values, [11, 1, 0, 3, 2], "1, 2, 3+ rounds, still open, followed up")
        XCTAssertEqual(mei.closed?.total.untouchedAfterFollowUp, 2)
        let trips = try XCTUnwrap(mei.time)
        XCTAssertEqual(trips.map(\.round), [1, 2, 3, 4, 1])
        XCTAssertEqual(trips.map(\.student), [9, 14, 7, nil, 39])
        XCTAssertEqual(trips.first?.received, 8)
        XCTAssertTrue(trips[3].open)
        // the summaries' names (CONTRACT amendment "App, hierarchy")
        let json = #"{"papers": [{"path": "/p", "summary": {"round": 1, "closed": false, "status": "ok", "to_judge": 0, "to_check": 0}, "paper": {"title": "T", "student": "S"}}, {"path": "/q", "error": "no"}]}"#
        let s = try makeDecoder().decode(SummariesReply.self, from: Data(json.utf8))
        XCTAssertEqual(s.papers.first?.paper, SummariesReply.Entry.Paper(title: "T", student: "S"))
        XCTAssertNil(s.papers.last?.paper)
    }

    /// The pages' words: one count of the papers that wait on you, the status lines, the sentences.
    /// FEATURES E1b: the second engine process fills in the closed rounds the overview reports pending, oldest first;
    /// not the open round (ingest and Review find it) nor a failed build.
    func testWhichRoundsAreFilledIn() throws {
        let r = try Self.reply()
        var reef = try XCTUnwrap(r.papers.first { $0.path == Self.root + "reef" }?.overview)
        XCTAssertEqual(Backfill.rounds(reef), [])
        reef.pending = [4, 2, 1]
        XCTAssertEqual(Backfill.rounds(reef), [1, 2], "closed rounds only, oldest first")
        var sea = try XCTUnwrap(r.papers.first { $0.path == Self.root + "seagrass" }?.overview)
        sea.pending = [1, 3]
        XCTAssertEqual(Backfill.rounds(sea), [1], "not the failed round")
    }

    func testTheWords() throws {
        XCTAssertEqual(HubText.waits(4), "4 papers wait on you")
        XCTAssertEqual(HubText.waits(1), "1 paper waits on you")
        XCTAssertEqual(HubText.waits(0), "Nothing waits on you")
        XCTAssertEqual(HubText.waitsDetail(review: 3, failed: 1), "3 to review or finish · 1 build failed")
        XCTAssertEqual(HubText.waitsDetail(review: 0, failed: 2), "2 builds failed")
        XCTAssertEqual(HubText.status(.toCheck(comments: 7, edits: 2), round: 4, student: "Mei Lin", since: nil),
                       "Round 4 · 7 comments and 2 edits to check")
        XCTAssertEqual(HubText.status(.toCheck(comments: 7, edits: 2), round: 4, student: "Mei Lin", since: nil, short: true),
                       "Round 4 · 7 comments, 2 edits to check")
        XCTAssertEqual(HubText.status(.ready, round: 3, student: "", since: nil), "Round 3 · ready to finish")
        XCTAssertEqual(HubText.status(.failed, round: 5, student: "", since: nil), "Round 5 · build failed")
        XCTAssertEqual(HubText.status(.waiting, round: 1, student: "Priya Nair", since: "2026-10-03T10:00:00+08:00"),
                       "With Priya since Oct 3")
        XCTAssertEqual(HubText.status(.finished("2026-07-20"), round: 2, student: "Mei Lin", since: nil), "Finished Jul 20")
        XCTAssertEqual(HubText.week(Self.day("2026-10-19"), calendar: Self.calendar), "Oct 13–19")
        XCTAssertEqual(HubText.week(Self.day("2026-10-02"), calendar: Self.calendar), "Sep 26 – Oct 2")
        XCTAssertEqual(HubText.land(["Abstract", "Methods", "Results"], [0, 18, 11]), "Most comments land in Methods (18), then Results (11).")
        XCTAssertEqual(HubText.land(["Abstract"], [0]), "No comments yet.")

        let r = try Self.reply()
        let data = Dictionary(r.papers.compactMap { e in e.overview.map { (e.path, $0) } }, uniquingKeysWith: { a, _ in a })
        let rows = Self.papers(r).map { p -> (paper: PaperRef, status: PaperStatus?, data: PaperOverview?) in
            (p, PaperStatus.of(data[p.path]?.summary, finished: p.title == "Shrimp snap detector" ? "2026-07-20" : nil), data[p.path])
        }
        let week = HubText.thisWeek(rows, today: Self.day("2026-10-19"), calendar: Self.calendar).map(\.text).joined()
        XCTAssertEqual(week, "Five rounds came in this week: Priya’s Mangrove sediment cores (Tue), Tomás’s Kelp forest drift (Thu), "
                       + "Mei’s Reef choruses (Fri), Jonas’s Seagrass carbon budget (Sat) and Untitled draft (Sun). Mangrove sediment "
                       + "cores is decided and only needs Finish; Seagrass carbon budget did not build. Urchin barrens survey is with Tomás; "
                       + "Blue carbon review is with Priya.")
        XCTAssertEqual(HubText.thisWeek(rows, today: Self.day("2026-08-01"), calendar: Self.calendar).first?.text, "No rounds came in this week.")
        let titles = HubText.thisWeek(rows, today: Self.day("2026-10-19"), calendar: Self.calendar).filter(\.bold).map(\.text)
        XCTAssertEqual(titles.count, 5, "the titles that came in are bold")
        let mei = rows.filter { $0.paper.student == "Mei Lin" }
        XCTAssertEqual(HubText.studentLede(mei).map(\.text).joined(),
                       "○ Reef choruses is your move: Round 4 came in Oct 16. Shrimp snap detector finished on Jul 20 after 2 rounds.")
        XCTAssertEqual(HubText.studentLede(mei).filter(\.amber).map(\.text), ["○"], "the amber ○ of your move")
        let stats = try XCTUnwrap(r.students?.first { $0.student == "Mei Lin" })
        let t = Dictionary(mei.map { ($0.paper.path, $0.paper.title) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(HubText.time(stats.time ?? [], titles: t, first: "Mei"),
                       "Mei’s revisions took 9, 14 and 7 days on Reef choruses; 39 days on Shrimp snap detector. You returned each round in 2–3 days.")
        XCTAssertEqual(HubText.time([], titles: [:], first: "Ana"), "No round has gone back to Ana yet.")
    }

    /// The small maps (OVERVIEW-v2 §3.1, VISUAL v3 §6.2): a row per round, newest first, shaded with the paper's own
    /// three steps, the round's comments at the right, "–" for a failed build, plain pages without sections, no bands.
    func testSmallMaps() throws {
        let r = try Self.reply()
        let reef = try XCTUnwrap(r.papers.first { $0.path == Self.root + "reef" }?.overview)
        let m = MiniMap.make(reef, ring: true)
        XCTAssertEqual(m.rows.map(\.n), [4, 3, 2, 1])
        XCTAssertEqual(m.rows.map(\.count), [3, 6, 9, 6], "the readout's Comments of each round")
        XCTAssertEqual(m.rows.first?.ring, true)
        XCTAssertEqual(m.rows.dropFirst().filter(\.ring).count, 0)
        XCTAssertEqual(m.rows.first?.cells.count, reef.round(4)?.spans?.count)
        XCTAssertTrue(m.rows.flatMap(\.cells).contains { $0.level > 0 })
        XCTAssertTrue(m.rows.flatMap(\.cells).allSatisfy { $0.level <= 3 }, "three steps")
        XCTAssertNil(m.folded)
        let two = MiniMap.make(reef, maxRows: 2)
        XCTAssertEqual(two.rows.map(\.n), [4], "the newest rows, and the fold's row")
        XCTAssertEqual(two.folded, 1...3, "the oldest rounds folded, never left out without a sign")
        XCTAssertEqual(MiniMap.make(reef, maxRows: 4).folded, nil)
        XCTAssertEqual(MiniMap.make(reef, maxRows: 3).folded, 1...2)
        let sea = try XCTUnwrap(r.papers.first { $0.path == Self.root + "seagrass" }?.overview)
        let s = MiniMap.make(sea)
        XCTAssertTrue(s.rows[0].failed)
        XCTAssertNil(s.rows[0].count)
        var pending = reef
        pending.rounds[0].prose = "pending"
        XCTAssertTrue(MiniMap.make(pending).rows.last?.plain == true, "a round without sections: plain pages")
    }

    /// Rounds in 2026 (the mockup's timeline): with you while open or until it closed, with the student until the next
    /// round, amber for a round that waits on you, a check for one ready to finish, a triangle for a failed build, a
    /// diamond for a finished paper.
    func testTheTimeline() throws {
        let r = try Self.reply()
        let data = Dictionary(r.papers.compactMap { e in e.overview.map { (e.path, $0) } }, uniquingKeysWith: { a, _ in a })
        let rows = Self.papers(r).map { p -> (paper: PaperRef, status: PaperStatus?, data: PaperOverview?) in
            (p, PaperStatus.of(data[p.path]?.summary, finished: p.title == "Urchin barrens survey" ? "2026-05-02" : nil), data[p.path])
        }
        let t = try XCTUnwrap(Timeline.make(rows, today: Self.day("2026-10-19"), calendar: Self.calendar))
        XCTAssertEqual(t.title, "Rounds in 2026")
        XCTAssertEqual(t.months.first?.0, "Mar", "from the month of the first round")
        XCTAssertEqual(t.months.last?.0, "Oct")
        XCTAssertEqual(t.lanes.count, 8)
        let reef = try XCTUnwrap(t.lanes.first { $0.title == "Reef choruses" })
        XCTAssertEqual(reef.marks.map(\.kind), [.imported, .imported, .imported, .yourMove])
        XCTAssertEqual(reef.you.count, 4)
        XCTAssertEqual(reef.you[0].upperBound - reef.you[0].lowerBound, 2, "Sep 8 to Sep 10")
        XCTAssertEqual(reef.student.count, 3)
        XCTAssertEqual(reef.you[3].upperBound, t.today, "the open round is with you until today")
        XCTAssertEqual(t.lanes.first { $0.title == "Mangrove sediment cores" }?.marks.last?.kind, .ready)
        let sea = try XCTUnwrap(t.lanes.first { $0.title == "Seagrass carbon budget" })
        XCTAssertEqual(sea.marks.last?.kind, .failed)
        XCTAssertEqual(sea.student.last?.upperBound, sea.marks.last?.day, "with the student until the failed round came in")
        let urchin = try XCTUnwrap(t.lanes.first { $0.title == "Urchin barrens survey" })
        XCTAssertNotNil(urchin.finished)
        XCTAssertEqual(urchin.student.last?.upperBound, urchin.finished, "with the student until it was marked finished")
        let blue = try XCTUnwrap(t.lanes.first { $0.title == "Blue carbon review" })
        XCTAssertEqual(blue.student.last?.upperBound, t.today, "with the student until today")
        let across = Timeline.make(rows, today: Self.day("2027-01-10"), calendar: Self.calendar)
        XCTAssertEqual(across?.title, "Rounds since Mar 2026")
    }

    /// The sidebar's rows (FEATURES OV-7): All Students, Your Move, Students with their papers (a folded student
    /// without them); in Review the open paper alone under its student, then the Contents.
    func testTheSidebarsRows() throws {
        let r = try Self.reply()
        let ps = Self.papers(r)
        let g = Hierarchy.groups(ps) { _ in .waiting }
        let rows = SidebarLayout.rows(groups: g, folded: [], review: nil, contents: 0)
        XCTAssertEqual(rows.prefix(5), [.allStudents, .yourMove, .header("Students"), .student(StudentName.key("Jonas Berg")),
                                        .paper(Self.root + "seagrass")])
        XCTAssertEqual(rows.count, 3 + 5 + 8)
        let folded = SidebarLayout.rows(groups: g, folded: [StudentName.key("Mei Lin")], review: nil, contents: 0)
        XCTAssertEqual(folded.count, rows.count - 2)
        XCTAssertFalse(folded.contains(.paper(Self.root + "reef")))
        let review = SidebarLayout.rows(groups: g, folded: [], review: Self.root + "reef", contents: 3)
        XCTAssertEqual(review, [.allStudents, .yourMove, .header("Mei Lin"), .paper(Self.root + "reef"), .contentsHeader,
                                .contents(0), .contents(1), .contents(2)])
        XCTAssertEqual(SidebarLayout.rows(groups: g, folded: [], review: Self.root + "draft", contents: 0)[2], .header("Unassigned"))
    }

    /// Map Headings… (FEATURES OV-9): filled with the engine's suggestions until answered; the answers go to the engine
    /// as `buckets`, "" (its own column) as null; the line under the table says what lands where.
    func testMapHeadings() throws {
        let r = try Self.reply()
        let data = Dictionary(r.papers.compactMap { e in e.overview.map { (e.path, $0) } }, uniquingKeysWith: { a, _ in a })
        var kelp = try XCTUnwrap(Self.papers(r).first { $0.title == "Kelp forest drift" })
        let initial = MapHeadingsSheet.initial([kelp], data: data)[kelp.path]
        XCTAssertEqual(initial?["study-area"], "method")
        XCTAssertEqual(initial?["front"], "abstract")
        XCTAssertEqual(LandBox.mapped([kelp], data: data),
                       "Headings matched by their words (not confirmed yet): Study area → Methods · Materials and methods → Methods.")
        kelp.buckets = ["study-area": "", "methods": "method"]
        XCTAssertEqual(MapHeadingsSheet.initial([kelp], data: data)[kelp.path]?["study-area"], "", "the advisor's answer first")
        XCTAssertTrue(LandBox.mapped([kelp], data: data).hasPrefix("Headings matched to the standard sections: Materials and methods → Methods"))
        let req = AppModel.hubRequest([kelp])
        XCTAssertEqual(req["papers"] as? [String], [kelp.path])
        let b = try XCTUnwrap((req["buckets"] as? [String: [String: Any]])?[kelp.path])
        XCTAssertTrue(b["study-area"] is NSNull)
        XCTAssertEqual(b["methods"] as? String, "method")
        XCTAssertEqual(MapHeadingsSheet.title("method"), "Methods")
        XCTAssertNil(MapHeadingsSheet.title(""))
        XCTAssertEqual(LandBox.short("Introduction"), "Intro.")
        XCTAssertEqual(HubPage(argument: "student:Mei  Lin"), .student(StudentName.key("Mei Lin")))
        XCTAssertEqual(HubPage(argument: "move"), .yourMove)
        XCTAssertNil(HubPage(argument: "nope"))
    }

    /// Where the comments land's columns fit the box: the standard sections, then headings of their own name while
    /// they fit, the rest in "Other" (its help tag names them).
    func testLandColumnsFit() throws {
        let json = #"{"columns": [{"bucket": "abstract", "title": "Abstract"}, {"bucket": "method", "title": "Methods"}, {"bucket": null, "title": "Ethics"}, {"bucket": null, "title": "References"}, {"bucket": null, "title": "Appendix"}], "papers": [{"path": "/a", "counts": [1, 2, 3, 4, 5]}, {"path": "/b", "counts": [0, 1, 0, 2, 1]}], "total": [1, 3, 3, 6, 6]}"#
        let land = try makeDecoder().decode(StudentStats.Land.self, from: Data(json.utf8))
        XCTAssertEqual(LandColumns.fit(land, most: 6).titles, ["Abstract", "Methods", "Ethics", "References", "Appendix"])
        let f = LandColumns.fit(land, most: 4)
        XCTAssertEqual(f.titles, ["Abstract", "Methods", "Ethics", "Other"])
        XCTAssertEqual(f.rows, [[1, 2, 3, 9], [0, 1, 0, 3]])
        XCTAssertEqual(f.total, [1, 3, 3, 12])
        XCTAssertEqual(f.other, "References 6 · Appendix 6")
        XCTAssertEqual(f.total.reduce(0, +), land.total.reduce(0, +), "each comment still once")
    }

    /// papers.json keeps the new fields optional: an older list reads, a new one writes them only when set.
    func testThePapersListKeepsOlderEntries() throws {
        let old = #"[{"path": "/a", "title": "A", "student": "S"}]"#
        let ps = try JSONDecoder().decode([PaperRef].self, from: Data(old.utf8))
        XCTAssertNil(ps[0].finished)
        XCTAssertNil(ps[0].buckets)
        let back = String(decoding: try JSONEncoder().encode(ps), as: UTF8.self)
        XCTAssertFalse(back.contains("finished") || back.contains("buckets"))
        var p = ps[0]
        p.finished = "2026-07-20"
        p.buckets = ["methods": "method"]
        XCTAssertEqual(try JSONDecoder().decode(PaperRef.self, from: JSONEncoder().encode(p)), p)
    }
}

/// The hierarchy in the app's model: one count of the papers that wait on you for the sidebar, All Students and Your
/// Move; the navigation to and from its pages and Back; Your Move's buttons; the Finished mark and the fold.
@MainActor
final class HierarchyModelTests: XCTestCase {
    private var drafts: URL!

    override func setUp() {
        drafts = FileManager.default.temporaryDirectory.appendingPathComponent("pc-hub-" + UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: drafts)
    }

    /// A fixture run (the M2a paper selected, nothing saved) whose list holds the eight synthetic papers, with the
    /// students fixture as the engine's `overview`.
    private func makeModel() throws -> AppModel {
        _ = NSApplication.shared
        var o = LaunchOptions()
        o.fixture = StepTests.fixtures.appendingPathComponent("state-m2a.json").path
        o.overviewFixture = HierarchyDataTests.fixture.path
        o.drafts = drafts.path
        let m = AppModel(options: o)
        m.papers = HierarchyDataTests.papers(try HierarchyDataTests.reply())  // the fixture's paper stays selected, unlisted
        return m
    }

    func testOneCountEverywhere() throws {
        let m = try makeModel()
        m.openHub(.allStudents)
        XCTAssertNil(m.selectedPath, "a page of the hierarchy shows no paper")
        XCTAssertEqual(m.hub, .allStudents)
        XCTAssertEqual(m.hubModel.status, .loaded)
        XCTAssertEqual(m.hubModel.data.count, 8)
        XCTAssertEqual(m.yourMove.count, 5, "the sidebar's Your Move count")
        XCTAssertEqual(HubText.waits(m.yourMove.count), "5 papers wait on you", "All Students' heading")
        let (review, failed) = Hierarchy.counts(m.yourMove)
        XCTAssertEqual(HubText.waitsDetail(review: review, failed: failed), "4 to review or finish · 1 build failed")
        XCTAssertEqual(m.sidebarSelection, .allStudents)
        XCTAssertEqual(m.status(of: m.papers.first { $0.title == "Reef choruses" }!), .toCheck(comments: 3, edits: 5),
                       "the overview's summaries are taken for the badges")
        m.openHub(.yourMove)
        XCTAssertEqual(m.yourMove.first?.paper.title, "Mangrove sediment cores")
        XCTAssertEqual(m.statusText(m.yourMove[0].paper), "Round 3 · ready to finish")
        XCTAssertEqual(m.statusText(m.papers.first { $0.title == "Blue carbon review" }!), "With Priya since Oct 3")
    }

    func testBackAndForwardThroughThePages() throws {
        let m = try makeModel()
        let reef = HierarchyDataTests.root + "reef"
        m.openHub(.student(StudentName.key("Mei Lin")))
        m.openPaper(reef)
        XCTAssertNil(m.hub)
        XCTAssertEqual(m.selectedPath, reef)
        XCTAssertEqual(m.level, .overview)
        XCTAssertEqual(m.sidebarSelection, .paper(reef))
        m.goBack()
        XCTAssertEqual(m.hub, .student(StudentName.key("Mei Lin")))
        XCTAssertNil(m.selectedPath)
        XCTAssertEqual(m.sidebarSelection, .student(StudentName.key("Mei Lin")))
        m.goBack()
        XCTAssertNil(m.hub, "back to the fixture's paper where the run began")
        XCTAssertNotNil(m.selectedPath)
        XCTAssertEqual(m.level, .review)
        m.goForward()
        XCTAssertEqual(m.hub, .student(StudentName.key("Mei Lin")))
        m.goForward()
        XCTAssertEqual(m.selectedPath, reef)
        XCTAssertEqual(m.level, .overview)
        XCTAssertFalse(m.canGoForward)
        // the sidebar's clicks
        m.sidebarSelected(.yourMove)
        XCTAssertEqual(m.hub, .yourMove)
        m.sidebarSelected(.student(""))
        XCTAssertEqual(m.hub, .yourMove, "Unassigned has no page")
        m.sidebarSelected(.paper(reef))
        XCTAssertEqual(m.selectedPath, reef)
    }

    /// The sidebar's clicks (UX.md §21): a click on a paper selects it (its overview); a double click or Return (the
    /// list's primary action) opens Review, where the list selects nothing, so a click on the open paper shows its
    /// overview again; Back and Forward go through each; the students' and the pages' rows are as before.
    func testTheSidebarsClicksOnAPaper() throws {
        let m = try makeModel()
        let reef = HierarchyDataTests.root + "reef", kelp = HierarchyDataTests.root + "kelp"
        let mei = StudentName.key("Mei Lin")
        m.sidebarSelected(.allStudents)
        XCTAssertEqual(m.sidebarSelection, .allStudents)
        // a click: the overview, the row selected
        m.sidebarSelected(.paper(reef))
        XCTAssertEqual(m.selectedPath, reef)
        XCTAssertNil(m.hub)
        XCTAssertEqual(m.level, .overview)
        XCTAssertEqual(m.sidebarSelection, .paper(reef))
        XCTAssertEqual(m.overview.status, .loaded)
        // its double click's second click (or Return): Review, the tree folded to the paper, the list selecting nothing
        m.sidebarOpened([.paper(reef)])
        XCTAssertEqual(m.level, .review)
        XCTAssertEqual(m.selectedPath, reef)
        XCTAssertEqual(m.reviewPaper, reef)
        XCTAssertNil(m.sidebarSelection, "the open paper's row is marked by its own fill")
        XCTAssertEqual(m.sidebarRows.prefix(4), [.allStudents, .yourMove, .header("Mei Lin"), .paper(reef)])
        // a click on the open paper selects it: its overview
        m.sidebarSelected(.paper(reef))
        XCTAssertEqual(m.level, .overview)
        XCTAssertEqual(m.selectedPath, reef)
        XCTAssertEqual(m.sidebarSelection, .paper(reef))
        XCTAssertNil(m.reviewPaper)
        // Back and Forward: Review, the overview, All Students, and on again
        m.goBack()
        XCTAssertEqual(m.level, .review)
        XCTAssertNil(m.sidebarSelection)
        m.goBack()
        XCTAssertEqual(m.level, .overview)
        XCTAssertEqual(m.sidebarSelection, .paper(reef))
        m.goBack()
        XCTAssertEqual(m.hub, .allStudents)
        XCTAssertEqual(m.sidebarSelection, .allStudents)
        m.goForward()
        XCTAssertEqual(m.sidebarSelection, .paper(reef))
        m.goForward()
        XCTAssertEqual(m.level, .review)
        XCTAssertEqual(m.selectedPath, reef)
        // a double click on the paper open in Review (2026-10-20 leftover): its first click shows the overview and
        // unfolds the tree, so the second lands on another row; it brings Review back as it was, and the overview its
        // first click showed is no place in the history
        let back = m.navHistory.back.count
        m.sidebarSelected(.paper(reef))
        XCTAssertEqual(m.level, .overview)
        m.sidebarSelected(.student(mei), secondClick: true)
        XCTAssertNil(m.hub, "not the student's page: the pointer never went to that row")
        XCTAssertEqual(m.level, .review, "a double click on the paper open in Review keeps Review")
        XCTAssertEqual(m.selectedPath, reef)
        XCTAssertNil(m.sidebarSelection)
        XCTAssertEqual(m.navHistory.back.count, back, "the overview its first click showed left no place")
        m.sidebarOpened([.student(mei)])
        XCTAssertEqual(m.level, .review, "the list's primary action after it: nothing more")
        // a lone click on it: its overview; a second click later than the double-click interval does nothing more
        m.sidebarSelected(.paper(reef))
        XCTAssertEqual(m.level, .overview)
        RunLoop.main.run(until: Date().addingTimeInterval(NSEvent.doubleClickInterval + 0.05))
        m.sidebarSelected(.student(mei), secondClick: true)
        m.sidebarOpened([.student(mei)])
        m.sidebarSelected(.paper(kelp), secondClick: true)
        m.sidebarOpened([.paper(kelp)])
        XCTAssertEqual(m.selectedPath, reef, "not another paper either")
        XCTAssertEqual(m.level, .overview)
        // a double click on another paper: its overview at the first click, Review at the second, waiting for its state
        m.sidebarSelected(.paper(kelp))
        XCTAssertEqual(m.level, .overview)
        m.sidebarOpened([.paper(kelp)])
        XCTAssertEqual(m.selectedPath, kelp)
        XCTAssertEqual(m.level, .review)
        XCTAssertNotNil(m.pendingReview, "Review at the latest round once the paper's state is in")
        m.goBack()
        XCTAssertEqual(m.level, .overview)
        XCTAssertEqual(m.selectedPath, kelp, "the double click's first click is a place of its own, as before")
        // students, the pages and Unassigned: as before; their primary action does nothing more
        m.sidebarSelected(.student(mei))
        XCTAssertEqual(m.hub, .student(mei))
        XCTAssertEqual(m.sidebarSelection, .student(mei))
        m.sidebarOpened([.student(mei)])
        XCTAssertEqual(m.hub, .student(mei))
        XCTAssertNil(m.selectedPath)
        m.sidebarOpened([.paper(reef)])
        XCTAssertEqual(m.hub, .student(mei), "a paper the list does not select opens nothing")
        m.sidebarSelected(.student(""))
        XCTAssertEqual(m.hub, .student(mei), "Unassigned has no page")
        m.sidebarSelected(.yourMove)
        XCTAssertEqual(m.sidebarSelection, .yourMove)
        m.sidebarOpened([.yourMove])
        XCTAssertEqual(m.hub, .yourMove)
        m.sidebarSelected(nil)
        XCTAssertEqual(m.hub, .yourMove)
    }

    /// Review opened from the sidebar (Return or a double click, the list's primary action), from the overview or by
    /// Back: the PDF takes the keys (2026-10-20 leftover: the sidebar kept them, and its arrows went on choosing
    /// papers); a text field that has them keeps them; Review hidden behind the overview never takes them.
    func testReviewTakesTheKeys() throws {
        let m = try makeModel()
        let reef = HierarchyDataTests.root + "reef"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = NSView(frame: window.contentRect(forFrameRect: window.frame))
        let pdfView = ReviewPDFView(frame: NSRect(x: 0, y: 0, width: 600, height: 700))
        let list = OverviewKeyView(frame: NSRect(x: 600, y: 0, width: 300, height: 700))  // stands for the sidebar's list
        let field = NSTextField(frame: NSRect(x: 610, y: 10, width: 200, height: 22))
        content.addSubview(pdfView)
        content.addSubview(list)
        content.addSubview(field)
        window.contentView = content
        m.pdf.attach(pdfView)
        func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        m.sidebarSelected(.paper(reef))
        XCTAssertEqual(m.level, .overview)
        window.makeFirstResponder(list)
        spin()
        XCTAssertTrue(window.firstResponder === list, "the overview: the list keeps them")
        m.sidebarOpened([.paper(reef)])  // Return
        XCTAssertEqual(m.level, .review)
        spin()
        XCTAssertTrue(window.firstResponder === pdfView, "Review: the PDF has the keys")
        m.goBack()
        XCTAssertEqual(m.level, .overview)
        window.makeFirstResponder(list)
        m.goForward()
        spin()
        XCTAssertTrue(window.firstResponder === pdfView, "Forward into Review too")
        m.showAllRounds()
        window.makeFirstResponder(field)
        m.openReview(ReviewTarget(round: nil))
        spin()
        XCTAssertFalse(window.firstResponder === pdfView, "a text field that has the keys keeps them")
        m.showAllRounds()
        window.makeFirstResponder(list)
        m.pdf.takeKeys()
        XCTAssertTrue(window.firstResponder === list, "never while Review is hidden")
    }

    /// A second click's selection is not taken, nor Unassigned's, and the list is then told to show the model's
    /// selection again (as for a paper switch a new comment's note holds back); which clicks are second clicks.
    func testASecondClickSelectsNothing() throws {
        let m = try makeModel()
        var changes = 0
        let sink = m.objectWillChange.sink { _ in changes += 1 }
        func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        m.sidebarSelected(.yourMove, secondClick: true)
        XCTAssertEqual(changes, 0)
        spin()
        XCTAssertEqual(changes, 1, "the list asks for the selection again")
        XCTAssertNil(m.hub)
        m.sidebarSelected(.student(""))
        spin()
        XCTAssertEqual(changes, 2, "Unassigned has no page: the selection again")
        m.sidebarSelected(.yourMove)
        XCTAssertEqual(m.hub, .yourMove)
        let taken = changes
        spin()
        XCTAssertEqual(changes, taken, "taken: nothing more")
        sink.cancel()
        func mouse(_ type: NSEvent.EventType, _ n: Int) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                               eventNumber: 0, clickCount: n, pressure: 1)!
        }
        XCTAssertFalse(AppModel.isSecondClick(mouse(.leftMouseDown, 1)))
        XCTAssertFalse(AppModel.isSecondClick(mouse(.leftMouseUp, 1)))
        XCTAssertTrue(AppModel.isSecondClick(mouse(.leftMouseDown, 2)))
        XCTAssertTrue(AppModel.isSecondClick(mouse(.leftMouseUp, 3)))
        XCTAssertFalse(AppModel.isSecondClick(mouse(.rightMouseDown, 2)))
        XCTAssertFalse(AppModel.isSecondClick(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                               windowNumber: 0, context: nil, characters: "\r",
                                                               charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)))
        XCTAssertFalse(AppModel.isSecondClick(nil), "an arrow key's or the debug hooks' selection")
    }

    /// The sidebar's own list (a window that is never shown; a background window's list takes no synthetic click, so
    /// its selection is set as the debug hooks set it): the table's selection reaches the model, the paper's row is
    /// selected in its overview and not in Review, where selecting it shows the overview; Return (the list's primary
    /// action, as a double click) opens Review; each row keeps its own context menu under the list's empty one.
    func testTheSidebarsList() throws {
        let m = try makeModel()
        let reef = HierarchyDataTests.root + "reef"
        m.openHub(.allStudents)
        let host = NSHostingView(rootView: Sidebar().environmentObject(m).frame(width: 260, height: 760))
        host.frame = NSRect(x: 0, y: 0, width: 260, height: 760)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        func spin(_ s: Double = 0.2) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        func table(_ v: NSView) -> NSTableView? { v as? NSTableView ?? v.subviews.lazy.compactMap(table).first }
        spin(0.4)
        let t = try XCTUnwrap(table(host))
        XCTAssertEqual(t.numberOfRows, m.sidebarRows.count, "the debug hooks' rows are the table's")
        func row(_ r: SidebarRow) throws -> Int { try XCTUnwrap(m.sidebarRows.firstIndex(of: r)) }
        func menu(_ r: SidebarRow) throws -> [String] {
            let rect = t.rect(ofRow: try row(r))
            let p = t.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            let e = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: p, modifierFlags: [], timestamp: 0,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                     clickCount: 1, pressure: 1))
            // as AppKit looks for it: the view under the pointer, then the views round it
            var v = window.contentView?.superview?.hitTest(p)
            while let view = v {
                if let found = view.menu(for: e) {
                    found.delegate?.menuNeedsUpdate?(found)
                    return found.items.filter { !$0.isSeparatorItem }.map(\.title)
                }
                v = view.superview
            }
            return []
        }
        XCTAssertEqual(t.selectedRow, try row(.allStudents))
        // a paper's row selected: its overview, the row selected
        t.selectRowIndexes([try row(.paper(reef))], byExtendingSelection: false)
        spin()
        XCTAssertEqual(m.selectedPath, reef)
        XCTAssertEqual(m.level, .overview)
        XCTAssertEqual(t.selectedRow, try row(.paper(reef)))
        // DATA.md §0.2: each paper's and student's actions are here, not in Settings
        XCTAssertEqual(try menu(.paper(reef)), ["Open in Review", "Edit Paper…", "Show in Finder", "Export…", "Export Comments",
                                                "Put Back an Earlier Ledger…", "Remove from List"])
        XCTAssertEqual(try menu(.student(StudentName.key("Mei Lin"))), ["Open Mei Lin’s Page", "Rename Student…", "Hide Papers",
                                                                         "Show in Finder", "Export…", "Export Comments",
                                                                         "Remove from List"])
        XCTAssertEqual(try menu(.student("")), ["Hide Papers", "Show in Finder", "Export…", "Export Comments", "Remove from List"],
                       "Unassigned: no page, no name")
        XCTAssertEqual(try menu(.allStudents), [])
        // Return on it, as a double click: Review, the tree folded to it, the list selecting nothing
        window.makeFirstResponder(t)
        t.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                       windowNumber: window.windowNumber, context: nil, characters: "\r",
                                                       charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)))
        spin()
        XCTAssertEqual(m.level, .review)
        XCTAssertEqual(m.selectedPath, reef)
        XCTAssertEqual(t.numberOfRows, m.sidebarRows.count)
        XCTAssertEqual(t.selectedRow, -1, "Review: the open paper is marked by its own fill")
        XCTAssertEqual(try menu(.paper(reef)).first, "Open in Review")
        // the open paper's row selected: its overview again
        t.selectRowIndexes([try row(.paper(reef))], byExtendingSelection: false)
        spin()
        XCTAssertEqual(m.level, .overview)
        XCTAssertEqual(m.selectedPath, reef)
        XCTAssertEqual(t.selectedRow, try row(.paper(reef)))
        // a student's row: the student's page, as before
        t.selectRowIndexes([try row(.student(StudentName.key("Mei Lin")))], byExtendingSelection: false)
        spin()
        XCTAssertEqual(m.hub, .student(StudentName.key("Mei Lin")))
        XCTAssertEqual(t.selectedRow, try row(.student(StudentName.key("Mei Lin"))))
        window.close()
    }

    /// Your Move's buttons go straight into Review; Finish Round N… opens the Finish sheet once the paper's state is
    /// in (a fixture run has the M2a paper's).
    func testYourMovesButtons() throws {
        let m = try makeModel()
        let fixturePaper = try XCTUnwrap(m.selectedPath)
        let st = try XCTUnwrap(m.state)
        m.openHub(.yourMove)
        let ready = MoveItem(paper: PaperRef(path: fixturePaper, title: "M2a", student: "Lin Zhou"), status: .ready, round: 2)
        m.moveAction(ready)
        XCTAssertEqual(m.level, .review)
        XCTAssertNil(m.hub)
        XCTAssertEqual(m.pendingFinish, fixturePaper)
        m.apply(st)
        XCTAssertNil(m.pendingFinish, "applied once the latest round's state is in")
        let cont = MoveItem(paper: m.papers.first { $0.title == "Kelp forest drift" }!, status: .toCheck(comments: 2, edits: 3), round: 4)
        m.openHub(.yourMove)
        m.moveAction(cont)
        XCTAssertEqual(m.selectedPath, HierarchyDataTests.root + "kelp")
        XCTAssertEqual(m.level, .review)
        XCTAssertNil(m.pendingFinish)
    }

    /// A round filled in while the hierarchy waits for more of that paper's rounds is not asked for at once, but the
    /// next request is a new one (it was the round's pending data that the pages showed).
    func testARoundFilledInMakesTheNextRequestNew() throws {
        let m = try makeModel()
        m.openHub(.allStudents)
        let key = try XCTUnwrap(m.hubModel.key)
        m.backfill.filled?(HierarchyDataTests.root + "kelp", true)
        XCTAssertEqual(m.hubModel.key, key, "more of the paper's rounds to come: not yet")
        m.loadHub()
        XCTAssertNotEqual(m.hubModel.key, key)
        XCTAssertEqual(m.hubModel.status, .loaded)
    }

    /// The Finished mark and Map Headings' answers live in the app's list (not saved by a fixture run); the students'
    /// fold is the viewer's; Remove from List of the paper shown goes home to All Students.
    func testMarksFoldsAndRemoving() throws {
        let m = try makeModel()
        let shrimp = HierarchyDataTests.root + "shrimp"
        m.openHub(.allStudents)
        m.setFinished(shrimp, true, today: HierarchyDataTests.day("2026-07-20"))
        let p = try XCTUnwrap(m.papers.first { $0.path == shrimp })
        XCTAssertEqual(p.finished, "2026-07-20")
        XCTAssertEqual(m.status(of: p), .finished("2026-07-20"))
        XCTAssertEqual(m.studentGroups.first { $0.name == "Mei Lin" }?.papers.last?.path, shrimp)
        m.setFinished(shrimp, false)
        XCTAssertEqual(m.status(of: m.papers.first { $0.path == shrimp }!), .waiting)
        let key = StudentName.key("Mei Lin")
        m.toggleStudentFold(key)
        XCTAssertTrue(m.foldedStudents.contains(key))
        XCTAssertFalse(m.sidebarRows.contains(.paper(HierarchyDataTests.root + "reef")))
        m.toggleStudentFold(key)
        m.setBuckets(HierarchyDataTests.root + "kelp", ["study-area": ""])
        XCTAssertEqual(m.papers.first { $0.title == "Kelp forest drift" }?.buckets, ["study-area": ""])
        m.openPaper(HierarchyDataTests.root + "reef")
        m.removePaper(HierarchyDataTests.root + "reef")
        XCTAssertEqual(m.hub, .allStudents, "home again")
        XCTAssertFalse(m.papers.contains { $0.path == HierarchyDataTests.root + "reef" })
        // a name from the engine (summaries, overview) regroups the list
        m.adoptNames(shrimp, title: nil, student: "Ana Sousa")
        XCTAssertEqual(m.studentGroups.map(\.name).first, "Ana Sousa")
    }

    /// The pages lay out at the three window widths (the overview's width at 1440, 1280 and 960 with the sidebar), in
    /// both appearances, without the engine.
    func testThePagesLayOut() throws {
        let m = try makeModel()
        m.openHub(.allStudents)
        for page in [HubPage.allStudents, .yourMove, .student(StudentName.key("Mei Lin")), .student(StudentName.key("Nobody"))] {
            for (w, h) in [(1204.0, 872.0), (1044.0, 772.0), (724.0, 612.0)] {
                for dark in [false, true] {
                    let host = NSHostingView(rootView: HubScreen(model: m, hub: m.hubModel, page: page).frame(width: w, height: h))
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    host.frame = NSRect(x: 0, y: 0, width: w, height: h)
                    host.layoutSubtreeIfNeeded()
                    XCTAssertGreaterThan(host.fittingSize.width, 0)
                }
            }
        }
    }
}
