import XCTest
import SwiftUI
@testable import Paperole

/// UI v4's figures (design/ui-v4/IMPLEMENTATION.md §2, D4–D11; UX.md §40.2) on the synthetic fixtures and small
/// hand-made values: the response bar, Closing's split, Turnaround's medians and hover dates, the strip's per-page
/// counts, short names, each paper's figures by state, and day counts across midnight and DST.
final class FiguresTests: XCTestCase {
    static let calendar = HierarchyDataTests.calendar
    static let today = HierarchyDataTests.day("2026-10-19")

    static func students() throws -> (OverviewReply, [String: PaperOverview]) {
        let r = try HierarchyDataTests.reply()
        return (r, Dictionary(r.papers.compactMap { e in e.overview.map { (e.path, $0) } }, uniquingKeysWith: { a, _ in a }))
    }

    static func overview(_ json: String) throws -> PaperOverview {
        try makeDecoder().decode(PaperOverview.self, from: Data(json.utf8))
    }

    func testTheResponseBar() throws {
        let kelp = try MapLayoutTests.kelp()
        let r4 = try XCTUnwrap(Response.make(kelp.round(4)))
        XCTAssertEqual(r4.carried, kelp.round(4)?.comments?.carried, "the segments add up to the carried comments")
        XCTAssertEqual(r4.words, "3 revised · 0 explained · 3 unchanged · 6 not asked", "Round 4: left open without an answer")
        let r2 = try XCTUnwrap(Response.make(kelp.round(2)))
        XCTAssertEqual(r2.carried, 15)
        XCTAssertEqual(r2.segments.map(\.word), ["revised", "explained", "unchanged"], "no fourth segment without any")
        XCTAssertNil(Response.make(kelp.round(1)), "Round 1 carries nothing")
        let (_, data) = try Self.students()
        for d in data.values { if let r = Response.make(d.latest) { XCTAssertEqual(r.carried, d.latest?.comments?.carried) } }
    }

    func testTheClosingSplit() throws {
        let (r, data) = try Self.students()
        let mei = try XCTUnwrap(r.students?.first { $0.student == "Mei Lin" })
        XCTAssertEqual(Closing.split(mei, data), Closing(toCheck: 3, stillOpen: 0), "Reef choruses' 3 to check are its 3 open")
        let jonas = try XCTUnwrap(r.students?.first { $0.student == "Jonas Berg" })
        XCTAssertEqual(Closing.split(jonas, data), Closing(toCheck: 0, stillOpen: 2), "a failed round has nothing to check")
        // Maya (BRIEF §4): 18 open, of which 14 came in and wait for your check
        let stats = try makeDecoder().decode(StudentStats.self, from: Data("""
            {"student": "Maya Chen", "papers": ["/m/ebh", "/m/cs"], "closed": {"papers": [], "total": {"1": 12, "2": 0, "3+": 0, "open": 18}}}
            """.utf8))
        let ebh = try Self.overview(#"{"sections": [], "comments": [], "pending": [], "rounds": [{"n": 1, "closed": true}, {"n": 2, "closed": false, "build": {"status": "ok"}, "comments": {"carried": 14, "to_check": 14}}]}"#)
        let cs = try Self.overview(#"{"sections": [], "comments": [], "pending": [], "rounds": [{"n": 2, "closed": true, "comments": {"to_check": 0}}]}"#)
        XCTAssertEqual(Closing.split(stats, ["/m/ebh": ebh, "/m/cs": cs]), Closing(toCheck: 14, stillOpen: 4))
        XCTAssertNil(Closing.split(nil, data))
    }

    func testTurnaround() throws {
        XCTAssertEqual(Turnaround.median([2, 2, 3])?.text, "2 d")
        XCTAssertEqual(Turnaround.median([12, 10])?.text, "11 d")
        XCTAssertEqual(Turnaround.median([10, 11]).map { [$0.text, $0.exactText] }, ["11 d", "10.5 d"], "half up, the exact value in the hover")
        XCTAssertEqual(Turnaround.median([0, 0, 1])?.text, "<1 d")
        XCTAssertNil(Turnaround.median([4]), "from the second trip")
        XCTAssertNil(Turnaround.median([]))
        let (r, data) = try Self.students()
        let mei = try XCTUnwrap(r.students?.first { $0.student == "Mei Lin" }?.time)
        let m = Turnaround.medians(mei)
        XCTAssertEqual(m.you?.exact, 3, "2, 3, 3 on Reef choruses, 3 and the closed last round's 6 on Shrimp snap detector")
        XCTAssertEqual(m.student?.exact, 11.5, "9, 14, 7, 39: not the open round, not the days so far")
        // a closed last round's days so far (D2): dropped for a paper the app marks finished before the ledger has
        let shrimp = HierarchyDataTests.root + "shrimp"
        let lastRow = { (t: [StudentStats.Trip]) in t.first { $0.path == shrimp && $0.last == true }?.student }
        XCTAssertEqual(lastRow(Turnaround.trips(mei, finished: [])), 91, "with the student: 91 days so far")
        XCTAssertNil(lastRow(Turnaround.trips(mei, finished: [shrimp])), "finished in the app")
        let done = Turnaround.medians(Turnaround.trips(mei, finished: [shrimp]))
        XCTAssertEqual([done.you, done.student], [m.you, m.student], "the medians do not use it")
        let priya = try XCTUnwrap(r.students?.first { $0.student == "Priya Nair" }?.time)
        XCTAssertEqual(Turnaround.medians(priya).student?.exactText, "25.5 d", "25 and 26 days")
        XCTAssertNil(Turnaround.medians(Array(priya.prefix(1))).student, "one trip that came back is not a median")

        // the hover's dates (README §7; plan §5 R6)
        let cs = try Self.overview("""
            {"paper": {"title": "Curriculum Signals for Small-Model Distillation"}, "sections": [], "comments": [], "pending": [],
             "rounds": [{"n": 1, "created": "2026-09-08T10:00:00+08:00", "closed": true, "closed_at": "2026-09-11T18:00:00+08:00"},
                        {"n": 2, "created": "2026-09-21T09:00:00+08:00", "received": "2026-09-20T22:00:00+08:00", "closed": true,
                         "closed_at": "2026-09-23T10:00:00+08:00"}]}
            """)
        let cal = Self.calendar
        let trip = StudentStats.Trip(path: "/m/cs", round: 1, next: 2, open: false, you: 3, student: 10, received: 9)
        XCTAssertEqual(Turnaround.dates(trip, cs, calendar: cal),
                       "Curriculum Signals · Round 1 Sep 8 · back Sep 11 · Round 2 Sep 21 · files Sep 20")
        var same = cs
        same.rounds[1].received = "2026-09-21T08:00:00+08:00"
        XCTAssertEqual(Turnaround.dates(trip, same, calendar: cal), "Curriculum Signals · Round 1 Sep 8 · back Sep 11 · Round 2 Sep 21",
                       "the files' day only when it is another")
        let last = StudentStats.Trip(path: "/m/cs", round: 2, open: false, you: 2, last: true)
        XCTAssertEqual(Turnaround.dates(last, cs, calendar: cal), "Curriculum Signals · Round 2 Sep 21 · back Sep 23")
        let reef = try XCTUnwrap(data[HierarchyDataTests.root + "reef"])
        let open = try XCTUnwrap(mei.first { $0.open })
        XCTAssertEqual(Turnaround.dates(open, reef, calendar: cal), "Reef choruses · Round 4 Oct 16")
    }

    func testThePerPageCounts() throws {
        let kelp = try MapLayoutTests.kelp()
        let r4 = try XCTUnwrap(kelp.round(4))
        let pages = PageStripView.pagesToCheck(r4, kelp)
        XCTAssertEqual(pages.values.reduce(0, +), (r4.comments?.toCheck ?? 0) + (r4.changes?.toCheck ?? 0))
        XCTAssertTrue(pages.values.allSatisfy { $0 > 0 })
        XCTAssertEqual(PageStripView.pagesToCheck(kelp.round(3), kelp), [:], "a closed round has nothing to check")
    }

    func testShortTitles() {
        XCTAssertEqual(ShortTitle.of("Easy Before Hard: Curriculum-Paced Distillation for Small Code Models"), "Easy Before Hard")
        XCTAssertEqual(ShortTitle.of("Curriculum Signals for Small-Model Distillation"), "Curriculum Signals")
        XCTAssertEqual(ShortTitle.of("Retrieval-Augmented Docstring Generation for Legacy Fortran Code"), "Retrieval-Augmented")
        XCTAssertEqual(ShortTitle.of("Confidence-Gated Early Exit for On-Device Speech Recognition"), "Confidence-Gated")
        XCTAssertEqual(ShortTitle.of("Untitled"), "Untitled")
        XCTAssertEqual(ShortTitle.of("  Reef choruses "), "Reef choruses")
        XCTAssertEqual(ShortTitle.of(": a title"), ": a")
        XCTAssertEqual(ShortTitle.of(""), "")
    }

    /// Each paper's figures follow its state (BRIEF §1.4): to check and the response while it waits on you, a closed
    /// count from Round 3 on; comments, closed and open with the student or finished, Round 1's always-0 ones left out.
    func testThePapersFigures() throws {
        let (r, data) = try Self.students()
        func figures(_ name: String, finished: String? = nil) throws -> PaperFigures {
            let d = try XCTUnwrap(data[HierarchyDataTests.root + name])
            return try XCTUnwrap(PaperFigures.make(PaperStatus.of(d.summary, finished: finished), d.summary, d,
                                                   today: Self.today, calendar: Self.calendar))
        }
        let reef = try figures("reef")
        XCTAssertEqual(reef.glyph, .ring(0))
        XCTAssertNil(reef.fill)
        XCTAssertEqual(reef.toCheck, PaperFigures.Count(comments: 3, edits: 5))
        XCTAssertEqual(reef.response?.words, "0 revised · 0 explained · 3 unchanged")
        XCTAssertEqual(reef.answered, PaperFigures.make(PaperStatus.of(data[HierarchyDataTests.root + "reef"]?.summary, finished: nil),
                                                        data[HierarchyDataTests.root + "reef"]?.summary, data[HierarchyDataTests.root + "reef"],
                                                        today: Date())?.answered, "the ring's fill in the to-check figure's help")
        XCTAssertEqual(reef.closed, 8, "Round 4: 7 resolved and 1 kept follow the figure")
        XCTAssertNil(reef.totals)
        XCTAssertEqual([reef.dayCounter, reef.hover], ["3 d", "Came in Fri, Oct 16"])
        XCTAssertNil(reef.answered)

        let mangrove = try figures("mangrove")
        XCTAssertEqual(mangrove.glyph, .ready)
        XCTAssertEqual(mangrove.closed, 4)
        XCTAssertNotNil(mangrove.response)
        let seagrass = try figures("seagrass")
        XCTAssertEqual(seagrass.glyph, .failed)
        XCTAssertNil(seagrass.response)
        XCTAssertNil(seagrass.closed)
        XCTAssertEqual(seagrass.dayCounter, "2 d")
        let draft = try figures("draft")
        XCTAssertEqual(draft.glyph, .ring(0))
        XCTAssertNil(draft.response, "a first draft carries nothing")
        XCTAssertEqual(draft.dayCounter, "1 d")
        XCTAssertEqual(try figures("kelp").closed, 5, "Kelp forest drift, Round 4: 4 resolved and 1 kept")
        let blue = try figures("blue")
        XCTAssertEqual(blue.glyph, .waiting)
        XCTAssertEqual(blue.totals, PaperFigures.Totals(comments: 4, resolved: nil, kept: nil, open: nil), "Round 1: only the comments")
        XCTAssertEqual([blue.dayCounter, blue.hover], ["16 d", "Round 1 sent back Sat, Oct 3"])
        XCTAssertNil(blue.response)
        let shrimp = try figures("shrimp", finished: "2026-07-20")
        XCTAssertEqual(shrimp.glyph, .finished)
        XCTAssertEqual(shrimp.totals, PaperFigures.Totals(comments: 4, resolved: 3, kept: 1, open: 0), "the closed figure's hover: 3 resolved, 1 kept")
        XCTAssertEqual(shrimp.totals?.closed, 4)
        XCTAssertEqual([shrimp.dayCounter, shrimp.hover], ["Jul 20", "Finished Jul 20"])
        XCTAssertNil(PaperFigures.make(nil, nil, nil, today: Self.today), "a missing folder has no figures")
        XCTAssertEqual(r.papers.count, 8)

        // partly answered (BRIEF §4 09): Maya's 8 + 2 left of 16, 6 answered; Leo's 3 left of 4
        var s = PaperSummary(round: 2, closed: false, status: "ok", toJudge: 8, toCheck: 2)
        s.answered = 6
        s.handled = 0
        let maya = try XCTUnwrap(PaperFigures.make(PaperStatus.of(s, finished: nil), s, nil, today: Self.today))
        XCTAssertEqual(maya.glyph, .ring(0.375))
        XCTAssertEqual(maya.answered, "6 of 16 answered so far")
        var leo = PaperSummary(round: 3, closed: false, status: "ok", toJudge: 3, toCheck: 0)
        leo.answered = 1
        leo.handled = 0
        XCTAssertEqual(PaperFigures.make(PaperStatus.of(leo, finished: nil), leo, nil, today: Self.today)?.fill, 0.25)
    }

    /// The paper page's header figure by state (UI v4 Step 4, plan §5 R7): to check with the response and, from Round 3
    /// on, closed; ready, to read, a first draft, a failed build; comments, closed and open with the student or finished.
    func testThePaperPagesHeader() throws {
        let (_, data) = try Self.students()
        func header(_ name: String, finished: String? = nil) throws -> PaperHeader {
            let d = try XCTUnwrap(data[HierarchyDataTests.root + name])
            return try XCTUnwrap(PaperHeader.make(PaperStatus.of(d.summary, finished: finished), d.summary, d))
        }
        let reef = try header("reef")
        XCTAssertEqual(reef.figure, .toCheck(PaperFigures.Count(comments: 3, edits: 5)))
        XCTAssertEqual(reef.words, "3 comments + 5 edits to check · 8 closed")
        XCTAssertEqual(reef.closedHelp, "7 resolved · 1 kept as is")
        XCTAssertEqual(reef.response?.words, "0 revised · 0 explained · 3 unchanged")
        XCTAssertEqual(try header("mangrove").words, "Ready to finish")
        XCTAssertNil(try header("mangrove").response, "ready: its sign and words only")
        XCTAssertEqual(try header("seagrass").words, "Build failed")
        XCTAssertEqual(try header("seagrass").glyph, .failed)
        XCTAssertEqual(try header("draft").words, "First draft")
        XCTAssertEqual(try header("blue").words, "4 comments", "Round 1 with the student: closed and open are always 0 and all")
        let shrimp = try header("shrimp", finished: "2026-07-20")
        XCTAssertEqual(shrimp.words, "4 comments · 4 closed · 0 left open")
        XCTAssertEqual(shrimp.closedHelp, "3 resolved · 1 kept as is")
        var read = PaperSummary(round: 2, closed: false, status: "ok", toJudge: 0, toCheck: 0)
        read.unread = 6
        let toRead = try XCTUnwrap(PaperHeader.make(PaperStatus.of(read, finished: nil), read, nil))
        XCTAssertEqual(toRead.figure, .toRead(6))
        XCTAssertEqual(toRead.glyph, .ring(1))
        XCTAssertEqual(toRead.words, "6 paragraphs to read")
        XCTAssertNil(PaperHeader.make(nil, nil, nil), "a missing folder: no figure")
        XCTAssertEqual(ToCheckFigure.help(14, 2), "14 comments · 2 unasked edits to check")
        XCTAssertEqual(ToCheckFigure.help(0, 1), "1 unasked edit to check")
    }

    /// The to-check header fits its 300 pt column from Round 3 on: four response labels (not asked) go two a line, and
    /// "N closed" goes under a wide to-check figure. Nothing is drawn past the column, in either mode.
    @MainActor
    func testTheToCheckHeaderFitsItsColumn() throws {
        func inkPast300<V: View>(_ v: V, dark: Bool = false) throws -> Bool {
            let r = ImageRenderer(content: HStack(spacing: 0) { v.frame(width: 300, alignment: .leading); Color.clear.frame(width: 120) }
                .environment(\.colorScheme, dark ? .dark : .light))
            r.scale = 1
            let cg = try XCTUnwrap(r.cgImage)
            let w = cg.width, h = cg.height
            var px = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = try XCTUnwrap(CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            // past the column's edge pixel (the bar's antialiased corner)
            return (0..<h).contains { y in (301..<w).contains { x in px[(y * w + x) * 4 + 3] > 0 } }
        }
        XCTAssertTrue(try inkPast300(Text(String(repeating: "x", count: 80)).fixedSize()), "the check sees an overflow")
        let wide = Response(revised: 114, explained: 12, unchanged: 23, notAsked: 15)
        for (c, e, closed) in [(23, 12, 15), (114, 2, 12), (2, 0, 4)] {
            let h = PaperHeader(figure: .toCheck(PaperFigures.Count(comments: c, edits: e)), glyph: .ring(0.4), response: wide,
                                closed: closed, closedHelp: "11 resolved · 1 kept as is", answered: "6 of 16 answered so far")
            for dark in [false, true] {
                XCTAssertFalse(try inkPast300(PaperHeaderFigure(header: h, round: 3), dark: dark), "\(c) + \(e) · \(closed) closed")
            }
        }
    }

    /// Day counts are calendar days in the calendar's time zone: a minute past midnight is a day later, and a day of 23
    /// or 25 hours is one day.
    func testDayCountsAcrossMidnightAndDST() throws {
        var ny = Calendar(identifier: .gregorian)
        ny.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        func at(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
        XCTAssertEqual(HubText.dayCounter(at("2026-10-27T23:59:00-04:00"), today: at("2026-10-28T00:01:00-04:00"), calendar: ny), "1 d")
        XCTAssertEqual(HubText.dayCounter(at("2026-10-28T00:01:00-04:00"), today: at("2026-10-28T23:59:00-04:00"), calendar: ny), "today")
        XCTAssertEqual(HubText.dayCount(at("2026-03-07T12:00:00-05:00"), today: at("2026-03-09T12:00:00-04:00"), calendar: ny), 2,
                       "spring forward: a 23-hour day")
        XCTAssertEqual(HubText.dayCount(at("2026-10-31T23:30:00-04:00"), today: at("2026-11-01T23:30:00-05:00"), calendar: ny), 1,
                       "fall back: a 25-hour day")
        XCTAssertEqual(HubText.days(at("2026-11-01T00:30:00-04:00"), today: at("2026-11-02T00:10:00-05:00"), calendar: ny), "1 day")
        // the same moment is another day in another zone
        let shanghai = Self.calendar
        XCTAssertEqual(HubText.dayCounter(at("2026-10-27T15:30:00Z"), today: at("2026-10-28T03:00:00Z"), calendar: shanghai), "1 d")
        XCTAssertEqual(HubText.dayCounter(at("2026-10-27T15:30:00Z"), today: at("2026-10-28T03:00:00Z"), calendar: ny), "today")
        XCTAssertEqual(HubText.dayCount(at("2026-10-29T10:00:00Z"), today: at("2026-10-28T10:00:00Z"), calendar: ny), 0, "never negative")
    }
}
