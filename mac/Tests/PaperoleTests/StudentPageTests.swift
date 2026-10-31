import XCTest
@testable import Paperole

/// The student page's model (UI v4 step 5; mac/UX.md §40.5): which papers get an action card (oldest first, one
/// primary), the compact cards and their figures, the header's figures and ★, the grid. Synthetic only: the papers of
/// `Fixtures/overview-students.json`, grouped as each case needs; today is Fri, Oct 30, 2026 in +08:00.
final class StudentPageTests: XCTestCase {
    var data: [String: PaperOverview] = [:]
    var refs: [String: PaperRef] = [:]
    var reply: OverviewReply!
    let today = HierarchyDataTests.day("2026-10-30")
    let cal = HierarchyDataTests.calendar

    override func setUpWithError() throws {
        reply = try HierarchyDataTests.reply()
        data = Dictionary(reply.papers.compactMap { e in e.overview.map { (e.path, $0) } }, uniquingKeysWith: { a, _ in a })
        refs = Dictionary(HierarchyDataTests.papers(reply).map { ($0.path.replacingOccurrences(of: HierarchyDataTests.root, with: ""), $0) },
                          uniquingKeysWith: { a, _ in a })
    }

    /// The statuses as the app finds them: the summaries, Shrimp marked finished on Jul 20.
    private var statuses: [String: PaperStatus] {
        Dictionary(refs.values.compactMap { p in
            PaperStatus.of(data[p.path]?.summary, finished: p.title == "Shrimp snap detector" ? "2026-07-20" : nil).map { (p.path, $0) }
        }, uniquingKeysWith: { a, _ in a })
    }

    private func page(_ names: [String], stats: StudentStats? = nil, today: Date? = nil) -> StudentPageModel {
        let g = StudentGroup(key: "s", name: "Mei Lin", papers: names.map { refs[$0]! })
        return StudentPageModel.make(g, statuses: statuses, summaries: [:], data: data, stats: stats, today: today ?? self.today, calendar: cal)
    }

    private func spans(_ p: StudentPageModel) -> [[String]] {
        p.grid.map { $0.map { c in
            switch c.slot {
            case .card(let i): return "\(p.cards[i].kind.rawValue) \(c.span)"
            case .turnaround: return "turnaround \(c.span)"
            }
        } }
    }

    /// Maya-like: one paper waits, one is finished.
    func testOnePaperWaitsBesideAFinishedOne() throws {
        let stats = try XCTUnwrap(reply.students?.first { $0.student == "Mei Lin" })
        let p = page(["reef", "shrimp"], stats: stats)
        XCTAssertEqual(p.cards.map(\.kind), [.action, .compact])
        XCTAssertEqual(spans(p), [["action 8", "compact 4"]])
        XCTAssertEqual(p.header.since, "since Jun 2", "the first round's day")
        XCTAssertEqual(p.header.figures.map { "\($0.value) \($0.label)" }, ["2 papers", "6 rounds", "15 comments"])
        XCTAssertNil(p.header.star, "no Well done without praise")

        let a = p.cards[0]
        XCTAssertTrue(a.primary)
        XCTAssertEqual(a.item.map(MoveRow.title), "Continue")
        XCTAssertEqual(a.meta, "Round 4 · came in 14 days ago")
        XCTAssertEqual(a.metaHelp, "Came in Fri, Oct 16 · 4 rounds since Sep 8")
        XCTAssertEqual(a.words, "3 comments + 5 edits · 8 closed", "Round 4: closed after the to-check figure")
        XCTAssertEqual(a.header?.response, Response.make(data[HierarchyDataTests.root + "reef"]?.latest))
        XCTAssertNotNil(a.header?.response)

        let c = p.cards[1]
        XCTAssertEqual(c.line, "Finished Jul 20")
        XCTAssertEqual(c.lineHelp, "2 rounds since Jun 2", "the rounds and the first day, as the old card's facts")
        XCTAssertEqual(c.words, "4 comments · 4 closed · 0 left open")
        XCTAssertEqual(c.columns[1].help, "3 resolved · 1 kept as is")
        XCTAssertNil(c.item)
    }

    /// Sara-like: a single paper with the student takes 8 columns, Turnaround beside it; no header figures.
    func testASinglePaperWithTheStudent() throws {
        let p = page(["blue"], stats: try XCTUnwrap(reply.students?.first { $0.student == "Priya Nair" }))
        XCTAssertEqual(spans(p), [["wide 8", "turnaround 4"]])
        XCTAssertEqual(spans(page(["blue"])), [["wide 12"]], "no trips (no numbers yet): no Turnaround, the card takes the width")
        XCTAssertEqual(p.header.figures, [], "with one paper the figures would repeat its card")
        XCTAssertEqual(p.header.since, "since Oct 1")
        let c = p.cards[0]
        XCTAssertEqual(c.line, "With Priya · 27 d")
        XCTAssertEqual(c.lineHelp, "Round 1 sent back Sat, Oct 3 · 1 round since Oct 1", "Round 1's day too, as the old card's")
        XCTAssertEqual(c.words, "4 comments", "Round 1 with the student: comments only")
        XCTAssertEqual(c.figures?.glyph, .waiting)
    }

    /// Several papers wait: an action card each, oldest first, only the oldest's button primary; the other papers
    /// beside the first, then three to a row.
    func testSeveralPapersWait() {
        let p = page(["reef", "seagrass", "blue", "mangrove"])
        XCTAssertEqual(p.cards.prefix(3).map { $0.item?.paper.title }, ["Mangrove sediment cores", "Reef choruses", "Seagrass carbon budget"],
                       "oldest first: Oct 13, 16, 17")
        XCTAssertEqual(p.cards.map(\.primary), [true, false, false, false])
        XCTAssertEqual(p.cards.compactMap { $0.item.map(MoveRow.title) }, ["Finish Round 3…", "Continue", "Show Log…"])
        XCTAssertEqual(p.cards.map(\.words), ["Ready to finish", "3 comments + 5 edits · 8 closed", "Build failed · Round 3", "4 comments"])
        XCTAssertEqual(spans(p), [["action 8", "compact 4"], ["action 8"], ["action 8"]])
        XCTAssertEqual(p.cards[0].figures?.glyph, .ready)
        XCTAssertEqual(p.cards[2].figures?.glyph, .failed)
        XCTAssertNil(p.cards[2].header?.response, "no response bar for a failed build")
        XCTAssertEqual(p.cards[3].lineHelp, "Round 1 sent back Sat, Oct 3 · 1 round since Oct 1",
                       "a one-round paper's first day beside the others' (the header's since is the student's)")
    }

    /// Three papers, one waiting: the action card with one compact card, the other on the next row.
    func testThreePapers() {
        let p = page(["urchin", "reef", "shrimp"])
        XCTAssertEqual(spans(p), [["action 8", "compact 4"], ["compact 4"]])
        XCTAssertEqual(p.cards.map { c in (c.path as NSString).lastPathComponent }, ["reef", "urchin", "shrimp"])
        XCTAssertEqual(p.header.figures.map(\.value), ["3", "9", "19"])
        // Urchin: Round 3 with the student, all closed
        XCTAssertEqual(p.cards[1].words, "4 comments · 4 closed · 0 open")
        XCTAssertEqual(p.cards[1].line, "With Tomás · 189 d")
        XCTAssertEqual(p.cards[1].lineHelp, "Round 3 sent back Fri, Apr 24 · 3 rounds since Mar 9")
    }

    /// The compact figures: comments alone while nothing closed and every comment is open (Sara's rule).
    func testTheCompactFigures() {
        func cols(_ t: PaperFigures.Totals, _ finished: Bool) -> [String] {
            StudentPageModel.columns(t, finished: finished).map { "\($0.value) \($0.label)" }
        }
        XCTAssertEqual(cols(.init(comments: 5, resolved: 0, kept: 0, open: 5), false), ["5 comments"])
        XCTAssertEqual(cols(.init(comments: 1, resolved: nil, kept: nil, open: nil), false), ["1 comment"])
        XCTAssertEqual(cols(.init(comments: 16, resolved: 11, kept: 1, open: 4), true), ["16 comments", "12 closed", "4 left open"])
        XCTAssertEqual(cols(.init(comments: 6, resolved: 0, kept: 0, open: 5), false), ["6 comments", "0 closed", "5 open"],
                       "0 closed shown when not every comment is open")
        XCTAssertEqual(StudentPageModel.columns(.init(comments: 16, resolved: 11, kept: 1, open: 4), finished: true)[1].help,
                       "11 resolved · 1 kept as is")
    }

    /// ★: with praise, its count, the latest note, and where it was written (the round it was created in, the page
    /// printed); alone in the header for one paper.
    func testWellDone() throws {
        let json = #"{"papers": [], "students": [{"student": "Mei Lin", "papers": [], "comments": 15, "tags": {"comments": 15, "tagged": 3, "praise": {"comments": 3, "latest": {"path": "/tmp/synthetic/students/reef", "id": "R1-02", "round": 4, "page": 3, "note": "The ablation answers the reviewer’s question."}}}}]}"#
        let stats = try XCTUnwrap(PaperOverview.decodeReply(Data(json.utf8)).students?.first)
        let two = page(["reef", "shrimp"], stats: stats)
        XCTAssertEqual(two.header.star, .init(count: 3, note: "The ablation answers the reviewer’s question.", source: "Reef choruses · Round 1 · p.4"))
        XCTAssertEqual(two.header.figures.count, 3)
        let one = page(["reef"], stats: stats)
        XCTAssertEqual(one.header.figures, [])
        XCTAssertEqual(one.header.star?.count, 3, "★ alone for one paper (plan §5 R5)")
        XCTAssertEqual(spans(one), [["action 8"]])
    }

    /// "came in" today and one day ago; a first draft's figure.
    func testCameIn() {
        XCTAssertEqual(page(["reef"], today: HierarchyDataTests.day("2026-10-16")).cards[0].meta, "Round 4 · came in today")
        XCTAssertEqual(page(["reef"], today: HierarchyDataTests.day("2026-10-17")).cards[0].meta, "Round 4 · came in 1 day ago")
        let draft = page(["draft"]).cards[0]
        XCTAssertEqual(draft.kind, .action)
        XCTAssertEqual(draft.words, "First draft · came in 12 d")
        XCTAssertNil(draft.header?.response)
        XCTAssertEqual(draft.metaHelp, "Came in Sun, Oct 18", "Round 1: no rounds-since after its own day")
    }

    // MARK: - The tiles (step 6)

    private func stats(_ name: String) throws -> StudentStats { try XCTUnwrap(reply.students?.first { $0.student == name }) }

    /// Maya-like (Mei: Reef choruses waits, Shrimp snap detector finished): By section | Closing, Turnaround; no tags.
    func testTheTilesOfTwoPapers() throws {
        let p = page(["reef", "shrimp"], stats: try stats("Mei Lin"))
        XCTAssertEqual(p.tiles.shown, [.bySection, .closing, .turnaround], "no Topics or First drafts without tags")
        XCTAssertEqual(p.tileKinds, [.bySection, .closing, .turnaround])
        XCTAssertEqual(p.tiles.nextDraft, [])

        // By section: the leading column and its All count of the comments; the name column and All with two papers
        let b = try XCTUnwrap(p.tiles.bySection)
        XCTAssertEqual(b.heads, ["Abstract", "Intro.", "Methods", "Results", "Disc."])
        XCTAssertEqual(b.rows.map(\.name), ["Reef choruses", "Shrimp snap"])
        XCTAssertEqual(b.rows.map(\.counts), [[0, 1, 4, 3, 3], [0, 1, 1, 1, 1]])
        XCTAssertEqual(b.all, [0, 2, 5, 4, 4])
        XCTAssertEqual(b.lead, 2)
        XCTAssertEqual(b.headline, .init(key: "Methods", words: "5 of 15", help: nil))
        XCTAssertTrue(b.headHelp[1].hasPrefix("Introduction\n"), "the column's name, then the mapped headings")

        // Closing: closed of every comment once; the open ones split into to check and still open
        let c = try XCTUnwrap(p.tiles.closing)
        let reef = try XCTUnwrap(data[HierarchyDataTests.root + "reef"]?.latest?.comments?.toCheck)
        XCTAssertEqual(c.headline.key, "12")
        XCTAssertEqual(c.headline.words, "closed of 15")
        XCTAssertEqual(c.headline.help, "2 followed up (Reef choruses 2, Shrimp snap –)")
        XCTAssertEqual(c.rows.map(\.name), ["In 1 round", "In 2 rounds", "In 3 or more", "To check", "Still open"])
        XCTAssertEqual(c.rows.map(\.value), [11, 1, 0, reef, 3 - reef])
        XCTAssertEqual(c.rows[0].help, "Reef choruses 7, Shrimp snap 4")
        XCTAssertEqual(c.rows[2].help, "Reef choruses –, Shrimp snap –")
        XCTAssertTrue(c.rows[3].help?.hasSuffix("2 untouched after a follow-up") == true)
        XCTAssertEqual(c.rows.map(\.value).reduce(0, +), 15, "the bar adds up to the headline's total")

        // Turnaround: newest first in each paper, the name on its first row; the finished paper's days so far dropped
        let t = try XCTUnwrap(p.tiles.turnaround)
        XCTAssertEqual(t.who, "Mei")
        XCTAssertEqual(t.rows.map { "\($0.name ?? "") R\($0.round) \(StudentTiles.days($0.you)) \(StudentTiles.days($0.student))" },
                       ["Reef choruses R4 3 d –", " R3 3 d 7 d", " R2 3 d 14 d", " R1 2 d 9 d", "Shrimp snap R2 6 d –", " R1 3 d 39 d"])
        XCTAssertEqual(t.rows.map(\.openYou), [true, false, false, false, false, false])
        XCTAssertEqual(t.rows.map(\.openStudent), [false, false, false, false, false, false], "finished: no days so far")
        XCTAssertEqual(t.you?.text, "3 d")
        XCTAssertEqual(t.student?.text, "12 d", "9, 14, 7 and 39 days: 11.5, half up")
        XCTAssertEqual(t.help, "Median with you 3 d over 5 rounds, with Mei 11.5 d over 4 round trips")
        XCTAssertEqual(t.rows[3].help, "Reef choruses · Round 1 Sep 8 · back Sep 10 · Round 2 Sep 19 · files Sep 18")
    }

    /// Sara-like (Priya's Blue carbon review alone): Turnaround beside the card with its days so far and no headline;
    /// Closing hidden (nothing closed); By section without names or All.
    func testTheTilesOfOnePaper() throws {
        // Priya's numbers for Blue carbon review alone, as the engine gives a student with one paper
        var s = try stats("Priya Nair")
        let blue = HierarchyDataTests.root + "blue"
        s.papers = [blue]
        s.comments = 4
        var land = try XCTUnwrap(s.land), closed = try XCTUnwrap(s.closed)
        land.papers = land.papers.filter { $0.path == blue }
        land.total = land.papers.first?.counts ?? []
        closed.papers = closed.papers.filter { $0.path == blue }
        closed.total = try XCTUnwrap(closed.papers.first)
        s.land = land
        s.closed = closed
        s.time = s.time?.filter { $0.path == blue }
        let p = page(["blue"], stats: s)
        XCTAssertEqual(p.tiles.shown, [.bySection, .turnaround])
        XCTAssertEqual(p.tileKinds, [.bySection], "Turnaround is beside the card")
        XCTAssertNil(p.tiles.closing, "nothing closed")
        let b = try XCTUnwrap(p.tiles.bySection)
        XCTAssertNil(b.all)
        XCTAssertEqual(b.lead, 1, "a tie: the first column wins")
        XCTAssertEqual(b.headline?.key, "Introduction")
        let t = try XCTUnwrap(p.tiles.turnaround)
        XCTAssertEqual(t.rows.count, 1)
        XCTAssertNil(t.rows[0].name)
        XCTAssertTrue(t.rows[0].openStudent, "a closed last round with the student: an outline, so far")
        XCTAssertNil(t.you)
        XCTAssertNil(t.student, "no headline before the second trip")
    }

    /// A tile with nothing to show is left out; without the engine's numbers there are none.
    func testHiddenTiles() throws {
        XCTAssertEqual(page(["reef", "shrimp"]).tiles, StudentTiles(), "no numbers yet")
        var s = try stats("Mei Lin")
        s.land = nil
        s.time = []
        s.closed?.total = StudentStats.Closed()
        let p = page(["reef", "shrimp"], stats: s)
        XCTAssertEqual(p.tiles.shown, [])
        // nothing closed but follow-ups asked: Closing stays, for the followed-up and untouched counts
        s.closed?.total.open = 15
        s.closed?.total.followedUp = 2
        s.closed?.total.untouchedAfterFollowUp = 2
        let c = try XCTUnwrap(page(["reef", "shrimp"], stats: s).tiles.closing)
        XCTAssertEqual(c.headline.key, "0")
        XCTAssertEqual(c.headline.words, "closed of 15")
        XCTAssertEqual(c.headline.help, "2 followed up (Reef choruses 2, Shrimp snap –)")
        XCTAssertTrue(c.rows[3].help?.hasSuffix("2 untouched after a follow-up") == true)
        XCTAssertEqual(StudentTiles.days(0), "<1 d", "a stretch of no calendar day, as the medians")
        XCTAssertEqual(StudentTiles.days(nil), "–")
    }

    /// Topics: by count, ties in the advisor's order, Not tagged last, Well done left out (★); a bar per paper; the
    /// hovers keep the old table's numbers (by round, open) and the lede's facts. First drafts shows with a trend word.
    @MainActor func testTopics() throws {
        let r = try TagDataTests.reply()
        let mei = try XCTUnwrap(r.students?.first)
        let titles = ["/synthetic/shrimp": "Shrimp snap detector", "/synthetic/reef": "Reef choruses", "/synthetic/kelp": "Kelp holdfast survey"]
        let g = StudentGroup(key: "mei", name: "Mei Lin", papers: mei.papers.map { PaperRef(path: $0, title: titles[$0]!, student: "Mei Lin") })
        let data = Dictionary(r.papers.compactMap { e in e.overview.map { (e.path, $0) } }, uniquingKeysWith: { a, _ in a })
        let catalog = TagCatalog()
        let tiles = StudentTiles.make(g, stats: mei, data: data, statuses: [:], catalog: catalog, calendar: cal)
        let t = try XCTUnwrap(tiles.topics)
        XCTAssertEqual(t.rows.map(\.id), ["grammar", "wording", "logic", "clarity", "evidence", "figures", "math", "structure", "untagged"],
                       "by count, ties in the tag order, Not tagged last; no praise")
        XCTAssertEqual(t.rows.map(\.all), [6, 5, 5, 4, 4, 3, 3, 2, 2])
        XCTAssertEqual(t.headline.key, catalog.name("grammar"))
        XCTAssertEqual(t.headline.words, "6 of 32")
        XCTAssertEqual(t.headline.help, "30 of 32 comments tagged")
        XCTAssertEqual(t.heads, ["Shrimp snap", "Reef choruses", "Kelp holdfast"])
        XCTAssertEqual(t.rows[0].counts, [3, 2, 1])
        XCTAssertEqual(t.rows[0].cellHelp[0], "R1 3 · R2 –")
        XCTAssertEqual(t.rows[0].allHelp, "6 comments · 1 open")
        XCTAssertEqual(t.rows.last?.counts, [0, 2, 0])
        XCTAssertTrue(t.headHelp[1].hasPrefix("Reef choruses\nNew comments R1 13 · R2 3 · R3 1 · R4 –"))
        XCTAssertEqual(t.untagged, 2)
        let wording = try XCTUnwrap(t.rows.first { $0.id == "wording" })
        XCTAssertTrue(wording.nameHelp.hasSuffix("\nWording: 0 comments in Round 3 of Reef choruses, on 9 new words."), wording.nameHelp)
        XCTAssertTrue(tiles.firstDrafts, "trend words exist")
        XCTAssertEqual(tiles.shown, [.bySection, .closing, .topics, .turnaround, .firstDrafts])
        // For the next draft: the topic's line and the student's sentence, the facts and the advisor's note in the hover
        let n = try XCTUnwrap(tiles.nextDraft.first)
        XCTAssertEqual(n.tag, "logic")
        XCTAssertEqual(n.open, 2)
        XCTAssertEqual(n.sentence, "Hydro hydrophone swell night")
        XCTAssertEqual(n.source, "Kelp holdfast p.1")
        XCTAssertEqual(n.line, catalog.tag("logic")?.focus)
        XCTAssertTrue(n.help.hasPrefix("5 comments · 1 needed a follow-up\nYour note: "), n.help)
    }

    /// First drafts says more than Topics only when its columns differ from Topics' or a trend word exists (plan §5 R11).
    /// While it is hidden, each paper's first draft (its pages, why it is not compared) is in Topics' paper heads.
    @MainActor func testTheFirstDraftsRule() throws {
        func tags(_ rounds: String, trend: String = "{}", skipped: String = "[]") throws -> StudentTags {
            let json = #"{"comments": 3, "tagged": 3, "by_tag": {"logic": {"comments": 3, "papers": {"/a": 2, "/b": 1}}}, "rounds": \#(rounds), "first_drafts": {"trend": \#(trend), "skipped": \#(skipped)}}"#
            return try makeDecoder().decode(StudentTags.self, from: Data(json.utf8))
        }
        let same = try tags(#"[{"path": "/a", "n": 1, "first": true, "by_tag": {"logic": 2}}, {"path": "/b", "n": 1, "first": true, "by_tag": {"logic": 1}}]"#)
        XCTAssertFalse(StudentTiles.firstDraftsSayMore(same, paths: ["/a", "/b"]), "the same columns as Topics")
        let later = try tags(#"[{"path": "/a", "n": 1, "first": true, "by_tag": {"logic": 1}}, {"path": "/a", "n": 2, "by_tag": {"logic": 1}}, {"path": "/b", "n": 1, "first": true, "by_tag": {"logic": 1}}]"#)
        XCTAssertTrue(StudentTiles.firstDraftsSayMore(later, paths: ["/a", "/b"]), "a later round's comments: the columns differ")
        let trend = try tags(#"[{"path": "/a", "n": 1, "first": true, "by_tag": {"logic": 2}}, {"path": "/b", "n": 1, "first": true, "by_tag": {"logic": 1}}]"#,
                             trend: #"{"logic": {"word": "fewer", "counts": [2, 1]}}"#)
        XCTAssertTrue(StudentTiles.firstDraftsSayMore(trend, paths: ["/a", "/b"]), "a trend word")
        XCTAssertFalse(StudentTiles.firstDraftsSayMore(try tags("[]"), paths: ["/a"]), "no first draft")

        let paged = try tags(#"[{"path": "/a", "n": 1, "first": true, "pages": 4, "by_tag": {"logic": 2}}, {"path": "/b", "n": 1, "first": true, "pages": 9, "by_tag": {"logic": 1}}]"#,
                             skipped: #"[{"path": "/b", "why": "lengths_differ"}]"#)
        let titles = ["/a": "Alpha study", "/b": "Beta study"]
        let hidden = StudentTiles.topics(paged, paths: ["/a", "/b"], titles: titles, catalog: TagCatalog(), firstDrafts: false)
        XCTAssertEqual(hidden.headHelp, ["Alpha study\nNew comments R1 –\nRound 1 · 4 pp",
                                         "Beta study\nNew comments R1 –\nRound 1 · 9 pp · not compared: " + ProfileText.whyHelp("lengths_differ")])
        XCTAssertEqual(StudentTiles.topics(paged, paths: ["/a"], titles: titles, catalog: TagCatalog(), firstDrafts: false).headline.help,
                       "3 of 3 comments tagged\nNew comments R1 –\nRound 1 · 4 pp", "one paper: the headline's hover")
        XCTAssertEqual(StudentTiles.topics(paged, paths: ["/a", "/b"], titles: titles, catalog: TagCatalog()).headHelp[0],
                       "Alpha study\nNew comments R1 –", "First drafts shows them")
    }
}
