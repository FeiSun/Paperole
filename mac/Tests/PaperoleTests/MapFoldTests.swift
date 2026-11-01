import AppKit
import SwiftUI
import XCTest
@testable import Paperole

/// The paper map's v3 visual layer (design/overview/v3/VISUAL.md with the critique's fixes): a long appendix folded
/// into one block (decided once per paper, every row with an appendix folds or none; its block, count, outline, label,
/// axis and lens; shown and folded again; followed things inside it shown first; kept in the place for Back), a long
/// References list the same way, the quiet segments, the small maps, the map's colours (their distances and contrast),
/// and Settings' switch. Synthetic data only: `Fixtures/overview-sonar.json` is a fictional four-round paper of 27–29
/// pages with References of 3.2 pages and an appendix A–E of 10–12 pages (made for this design, as its mockup's).
@MainActor
final class MapFoldTests: XCTestCase {
    static let sonarURL = OverviewDataTests.fixtures.appendingPathComponent("overview-sonar.json")
    static let widths = MapLayoutTests.widths

    static func sonarJSON() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sonarURL)) as? [String: Any])
    }

    static func sonar() throws -> PaperOverview { try MapLayoutTests.decode(sonarJSON()) }

    private var drafts: URL!

    override func setUpWithError() throws {
        drafts = FileManager.default.temporaryDirectory.appendingPathComponent("pc-fold-drafts-" + UUID().uuidString)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: drafts) }

    // MARK: The parts

    func testThePartsFromTheEngineOrWorkedOut() {
        typealias S = PaperOverview.Span
        // the engine's 5th field when every span has it
        let tagged = [S(section: "front", title: "Title and abstract", start: 0, end: 0.4, part: "front"),
                      S(section: "a", title: "1 Intro", start: 0.4, end: 3, part: "body"),
                      S(section: "x", title: "Proofs", start: 3, end: 8, part: "appendix")]
        XCTAssertEqual(MapFold.parts(tagged), ["front", "body", "appendix"], "an appendix without letters, as the engine says")
        // worked out: References by its heading, the lettered sections after it
        let old = [S(section: "front", title: "Title and abstract", start: 0, end: 0.4),
                   S(section: "i", title: "1 Introduction", start: 0.4, end: 2), S(section: "r", title: "References", start: 2, end: 4),
                   S(section: "a", title: "A Data", start: 4, end: 6), S(section: "b", title: "B. Proofs", start: 6, end: 9),
                   S(section: "c", title: "NeurIPS checklist", start: 9, end: 10)]
        XCTAssertEqual(MapFold.parts(old), ["front", "body", "references", "appendix", "appendix", "body"])
        let ranges = MapFold.ranges(old)
        XCTAssertEqual(ranges.map(\.kind), [.references, .appendix])
        XCTAssertEqual(ranges[1].spans, 3..<5)
        XCTAssertEqual(ranges[1].length, 5, accuracy: 0.001)
        XCTAssertEqual(MapFold.label(.appendix, old[3..<5], short: false), "Appendix A–B")
        XCTAssertEqual(MapFold.label(.appendix, old[3..<4], short: false), "Appendix A")
        XCTAssertEqual(MapFold.label(.appendix, old[3..<5], short: true), "A–B")
        XCTAssertEqual(MapFold.label(.references, old[2..<3], short: false), "References")
        XCTAssertEqual(MapFold.pages(ranges[1]), "pp. 5–9")
        // a paper without References: a run of lettered sections at the end that starts with A
        let noRefs = [S(section: "i", title: "1 Intro", start: 0, end: 3), S(section: "a", title: "A Extra", start: 3, end: 7)]
        XCTAssertEqual(MapFold.parts(noRefs), ["body", "appendix"])
        // lettered sections in the middle are not an appendix
        let middle = [S(section: "a", title: "A Setup", start: 0, end: 3), S(section: "b", title: "2 Results", start: 3, end: 7)]
        XCTAssertEqual(MapFold.parts(middle), ["body", "body"])
        XCTAssertEqual(MapFold.letter("C Extra results"), "C")
        XCTAssertNil(MapFold.letter("Conclusion"))
        XCTAssertNil(MapFold.letter("A"))
    }

    func testAPageMapFoldsABlock() {
        let m = PageMap(x0: 100, k: 10, blocks: [.init(kind: .appendix, start: 10, end: 20, width: 30)])
        XCTAssertEqual(m.x(0), 100)
        XCTAssertEqual(m.x(10), 200)
        XCTAssertEqual(m.x(15), 215, "inside the block: in proportion")
        XCTAssertEqual(m.x(20), 230)
        XCTAssertEqual(m.x(22), 250, "after it at the page scale")
        var last: CGFloat = -1
        for t in stride(from: -1.0, through: 25, by: 0.25) { XCTAssertGreaterThanOrEqual(m.x(t), last); last = m.x(t) }
        XCTAssertEqual(m.block(at: 12)?.kind, .appendix)
        XCTAssertNil(m.block(at: 9.5))
    }

    // MARK: The plan

    /// The appendix folds once per paper: every row has its block, the same width in every row, never narrower than
    /// its label, and the rest of the paper gains room (VISUAL §1: 24 → about 35 pt a page at 1440 × 900).
    func testThePaperFoldsItsAppendixInEveryRow() throws {
        let d = try Self.sonar()
        for w in Self.widths {
            let s = MapScene.build(MapInput(data: d, width: w))
            XCTAssertEqual(s.plan.folded, [.appendix], "at \(w)")
            XCTAssertEqual(s.plan.foldable, [.appendix], "References are 3.2 pages: they stay")
            let blocks = s.rows.compactMap { $0.cells.first { $0.fold == .appendix } }
            XCTAssertEqual(blocks.count, s.rows.count, "every row with an appendix folds it")
            let widths = Set(blocks.map { ($0.rect.width * 10).rounded() })
            XCTAssertEqual(widths.count, 1, "one block width for every row")
            let unfolded = MapGeometry(width: w, maxPages: 29, unplaced: false).pageWidth
            XCTAssertGreaterThan(s.geometry.pageWidth, unfolded * 1.25, "the body gets room at \(w)")
            for b in blocks {
                XCTAssertEqual(b.count, b.sections.reduce(0) { n, k in n + (d.round(b.round)?.heat?.first { $0.section == k }?.present ?? 0) })
                XCTAssertEqual(s.target(at: CGPoint(x: b.rect.midX, y: b.rect.midY)), .block(.appendix, round: b.round))
                XCTAssertNotNil(b.number, "its total")
                for c in s.rows.first(where: { $0.n == b.round })?.cells ?? [] { XCTAssertLessThanOrEqual(c.rect.maxX, s.geometry.mapRight + 0.5) }
            }
            XCTAssertTrue(s.rows.allSatisfy { r in r.cells.filter { $0.fold != nil }.count == 1 })
            // the open round's block: its comments to check (UI v4: an outline, no chip), its words in label2 on a pad
            let r4 = try XCTUnwrap(s.rows.first)
            let tc = (d.round(4)?.heat ?? []).filter { r4.cells.last?.sections.contains($0.section) ?? false }.map(\.toCheck).reduce(0, +)
            XCTAssertEqual(r4.cells.first { $0.fold == .appendix }?.toCheck, tc)
            XCTAssertTrue(blocks.allSatisfy { $0.name.map { $0.ink == .label2 } ?? true }, "a block's label in label2 (UI v4)")
        }
        let wide = MapScene.build(MapInput(data: d, width: Self.widths[0]))
        XCTAssertEqual(wide.rows.first?.cells.last?.name?.text, "Appendix A–E", "its label on its stripes")
        XCTAssertFalse(wide.plan.short)
        let narrow = MapScene.build(MapInput(data: d, width: Self.widths[2]))
        XCTAssertTrue(narrow.plan.short, "a narrow window: the short label (the critique's 960 × 640 check)")
        XCTAssertEqual(narrow.rows.first?.cells.last?.name?.text, "A–E")
    }

    /// Decided once per paper (the critique): a round whose appendix is a page long still shows a block, so rows never
    /// mix a block and unfolded sections.
    func testARoundWithAShortAppendixFoldsToo() throws {
        var json = try Self.sonarJSON()
        MapLayoutTests.edit(&json) { o in
            var rounds = o["rounds"] as! [[String: Any]]
            var spans = rounds[0]["spans"] as! [[Any]]
            // round 1: its appendix one page long (the others' stay)
            let first = spans.firstIndex { ($0[4] as? String) == "appendix" }!
            let start = spans[first][2] as! Double
            for i in first..<spans.count {
                spans[i][2] = start + Double(i - first) * 0.2
                spans[i][3] = start + Double(i - first + 1) * 0.2
            }
            rounds[0]["spans"] = spans
            o["rounds"] = rounds
        }
        let d = try MapLayoutTests.decode(json)
        let s = MapScene.build(MapInput(data: d, width: Self.widths[1]))  // where the long rounds' appendix folds
        XCTAssertEqual(s.plan.folded, [.appendix])
        XCTAssertTrue(s.rows.allSatisfy { $0.cells.contains { $0.fold == .appendix } }, "every row, the short one too")
    }

    func testNothingFoldsWhenShortTurnedOffOrShown() throws {
        let kelp = try MapLayoutTests.kelp()
        XCTAssertTrue(MapScene.build(MapInput(data: kelp, width: Self.widths[0])).plan.folded.isEmpty, "a quarter-page appendix")
        let d = try Self.sonar()
        let off = MapScene.build(MapInput(data: d, width: Self.widths[0], foldParts: false))
        XCTAssertTrue(off.plan.foldable.isEmpty)
        XCTAssertTrue(off.rows.allSatisfy { $0.cells.allSatisfy { $0.fold == nil } })
        XCTAssertEqual(off.geometry.pageWidth, MapGeometry(width: Self.widths[0], maxPages: 29, unplaced: false).pageWidth, accuracy: 0.01)
        // shown: its sections at their real length, Fold under the axis
        let shown = MapScene.build(MapInput(data: d, width: Self.widths[0], shownParts: [.appendix]))
        XCTAssertEqual(shown.plan.foldable, [.appendix])
        XCTAssertTrue(shown.plan.folded.isEmpty)
        XCTAssertTrue(shown.rows.allSatisfy { $0.cells.allSatisfy { $0.fold == nil } })
        let fold = try XCTUnwrap(shown.axisParts.first)
        XCTAssertTrue(fold.shown)
        XCTAssertEqual(fold.text.text + fold.link.text, "Appendix A–E · pp. 17–29 · Fold")
        XCTAssertEqual(fold.bracket.count, 3)
        XCTAssertEqual(shown.target(at: CGPoint(x: fold.link.rect.midX, y: fold.link.rect.midY)), .foldPart(.appendix))
        XCTAssertGreaterThan(shown.height, MapScene.build(MapInput(data: d, width: Self.widths[0])).height - 0.5)
    }

    /// The page axis: under a folded part its pages and Show, no page number under its block; the lens's wedge over it.
    /// UI v4: the pages are numbered only without the strip (it numbers them); the part's pages and Show stay.
    func testTheAxisAndTheLens() throws {
        let d = try Self.sonar()
        let withStrip = MapScene.build(MapInput(data: d, width: Self.widths[0]))
        XCTAssertTrue(withStrip.axis.isEmpty)
        XCTAssertEqual(withStrip.axisParts.map { $0.text.text + $0.link.text }, ["pp. 17–29 · Show"])
        let s = MapScene.build(MapInput(data: d, width: Self.widths[0], stripShown: false))
        let part = try XCTUnwrap(s.axisParts.first)
        XCTAssertFalse(part.shown)
        XCTAssertEqual(part.text.text + part.link.text, "pp. 17–29 · Show")
        XCTAssertEqual(s.target(at: CGPoint(x: part.link.rect.midX, y: part.link.rect.midY)), .showPart(.appendix))
        let numbers = s.axis.dropFirst().compactMap { Int($0.text) }
        XCTAssertEqual(numbers.max(), 16, "the pages before the appendix, then its pages under it")
        for t in s.axis { XCTAssertFalse(t.rect.intersects(part.text.rect) || t.rect.intersects(part.link.rect), "\(t.text) under the part's pages") }
        // the strip of 29 pages scrolls (mac/UX.md §40.9): the lens with its end in view
        let end = s.lens(offset: .greatestFiniteMagnitude)
        XCTAssertEqual(end.wedges.count, 1, "a faint wedge over the folded part")
        XCTAssertNil(end.selected)
        // the hairlines: the strip's ends and the fold's edges always; none from inside the folded part
        let block = try XCTUnwrap(s.rows.first?.cells.last?.rect)
        let inside = end.fans.filter { $0[1].x > block.minX + 2 && $0[1].x < block.maxX - 2 }
        XCTAssertTrue(inside.isEmpty)
        XCTAssertLessThanOrEqual(end.fans.count, (d.round(4)?.spans?.count ?? 0) + 2)
        // at its start, the folded part partly in view: its wedge over the part in view only, from the strip's right edge
        let start = s.lens(offset: 0)
        let wedge = try XCTUnwrap(start.wedges.first)
        XCTAssertEqual(wedge[1].x, s.geometry.width, accuracy: 0.5)
        XCTAssertLessThan(wedge[3].x, block.maxX - 2, "to where the strip's edge is in the part")
    }

    /// References fold only past four pages, decided once the appendix is.
    func testLongReferencesFold() throws {
        var json = try Self.sonarJSON()
        MapLayoutTests.edit(&json) { o in
            var rounds = o["rounds"] as! [[String: Any]]
            for i in rounds.indices {
                var spans = rounds[i]["spans"] as! [[Any]]
                let r = spans.firstIndex { ($0[0] as? String) == "references" }!
                let grow = 2.4
                spans[r][3] = (spans[r][3] as! Double) + grow
                for j in (r + 1)..<spans.count { spans[j][2] = (spans[j][2] as! Double) + grow; spans[j][3] = (spans[j][3] as! Double) + grow }
                rounds[i]["spans"] = spans
                var b = rounds[i]["build"] as! [String: Any]
                b["pages"] = (b["pages"] as! Int) + 3
                rounds[i]["build"] = b
            }
            o["rounds"] = rounds
        }
        let d = try MapLayoutTests.decode(json)
        let s = MapScene.build(MapInput(data: d, width: Self.widths[0]))
        XCTAssertEqual(s.plan.folded, [.references, .appendix])
        XCTAssertTrue(s.rows.allSatisfy { r in r.cells.filter { $0.fold == .references }.count == 1 })
        XCTAssertEqual(s.axisParts.map(\.kind), [.references, .appendix])
    }

    // MARK: Following inside a folded part

    private func makeModel() -> AppModel {
        _ = NSApplication.shared
        var o = LaunchOptions()
        o.fixture = StepTests.fixtures.appendingPathComponent("state-m2a.json").path
        o.overviewFixture = Self.sonarURL.path
        o.level = .overview
        o.drafts = drafts.path
        return AppModel(options: o)
    }

    /// A click on the block shows the part; following a section, a page or a comment inside it shows it first; the
    /// shown part is the place's (Back keeps it); another paper opens folded; Fold folds it again.
    func testFollowingInsideShowsThePart() throws {
        let m = makeModel()
        XCTAssertEqual(m.overview.status, .loaded)
        XCTAssertTrue(m.foldParts, "on by default (a fixture run reads no setting)")
        m.overview.foldedParts = [.appendix]  // as the map writes it
        m.showPart(.appendix)
        XCTAssertEqual(m.overview.shownParts, [.appendix])
        XCTAssertEqual(m.overview.place.shownParts, [.appendix], "the shown part is the place's")
        m.foldPart(.appendix)
        XCTAssertTrue(m.overview.shownParts.isEmpty)
        // following an appendix section shows the appendix first
        m.overviewClicked(.section("extra", round: 4))
        XCTAssertEqual(m.overview.shownParts, [.appendix])
        XCTAssertEqual(m.overview.selection, .section("extra", round: 4))
        m.overview.shownParts = []
        m.overviewClicked(.section("methods", round: 4))
        XCTAssertTrue(m.overview.shownParts.isEmpty, "a body section leaves it folded")
        m.overviewClicked(.page(round: 4, page: 20))
        XCTAssertEqual(m.overview.shownParts, [.appendix], "a page of the appendix")
        m.overview.shownParts = []
        let d = try XCTUnwrap(m.overview.data)
        let inApp = try XCTUnwrap(d.comments.first { c in c.path.contains { $0.section == "extra" } })
        m.overviewClicked(.comment(inApp.id))
        XCTAssertEqual(m.overview.shownParts, [.appendix], "a comment there")
        m.overview.shownParts = []
        m.overview.foldedParts = []
        m.overviewClicked(.section("extra", round: 4))
        XCTAssertTrue(m.overview.shownParts.isEmpty, "not folded now: nothing to show")
        // another paper's overview opens folded
        m.overview.shownParts = [.appendix]
        m.overview.reset(for: "/elsewhere")
        XCTAssertTrue(m.overview.shownParts.isEmpty)
        var p = OverviewPlace()
        p.shownParts = [.appendix]
        m.overview.restore(p)
        XCTAssertEqual(m.overview.shownParts, [.appendix], "Back puts it back")
    }

    // MARK: Quiet segments

    /// Neighbouring empty sections each under 24 pt are one quiet stretch of track; a click still finds each section,
    /// and the pointer's tag names them all, the one under it in bold.
    func testQuietSegments() throws {
        let d = try Self.sonar()
        let s = MapScene.build(MapInput(data: d, width: Self.widths[0]))
        let r4 = try XCTUnwrap(s.rows.first)
        let q = try XCTUnwrap(r4.quiet.first)
        XCTAssertEqual(q.sections, ["limitations", "ethics", "acknowledgments"])
        for k in q.sections {
            let c = try XCTUnwrap(r4.cells.first { $0.section == k })
            XCTAssertTrue(c.quiet)
            XCTAssertEqual(c.count, 0)
            let sp = try XCTUnwrap(d.round(4)?.spans?.first { $0.section == k })
            XCTAssertLessThan(s.pageMaps[4].map { $0.x(sp.end) - $0.x(sp.start) } ?? 99, 24, "under 24 pt at the page scale")
            XCTAssertEqual(s.target(at: CGPoint(x: c.rect.midX, y: c.rect.midY)), .cell(k, round: 4), "a click goes section by section")
        }
        // no gap inside the segment
        let cells = q.sections.compactMap { k in r4.cells.first { $0.section == k } }
        for (a, b) in zip(cells, cells.dropFirst()) { XCTAssertEqual(a.rect.maxX, b.rect.minX, accuracy: 0.01) }
        XCTAssertEqual(q.rect.minX, cells.first!.rect.minX, accuracy: 0.01)
        let lines = MapHelp.quiet(q, under: "ethics", round: 4, d)
        XCTAssertTrue(lines[0].hasPrefix("Round 4 · pp. "))
        XCTAssertTrue(lines[0].hasSuffix("no comments"))
        XCTAssertEqual(lines[1], "Limitations · **Ethics statement** · Acknowledgments")
        XCTAssertEqual(lines.last, "A click follows Ethics statement (under the pointer)")
        XCTAssertNotNil(s.quiet("ethics", round: 4))
        XCTAssertNil(s.quiet("methods", round: 4))
        // a counted section is never quiet
        XCTAssertTrue(s.rows.allSatisfy { r in r.cells.filter(\.quiet).allSatisfy { $0.count == 0 && $0.fold == nil } })
        // named like a cell (the UI audit of 2026-10-21: a blank stretch), inside it, in secondary as every cell without
        // comments (UI v4; it was the name ink)
        let name = try XCTUnwrap(q.name, "a quiet segment has a name")
        XCTAssertEqual(name.ink, .secondary)
        XCTAssertGreaterThanOrEqual(name.rect.minX, q.rect.minX + 3.9)
        XCTAssertLessThanOrEqual(name.rect.maxX, q.rect.maxX - 3.9)
        XCTAssertTrue(name.text.hasPrefix("Li"), name.text)
    }

    /// A quiet segment's name: its sections' names in an equal share each, else the first's and how many more, else
    /// the first's as it fits; nothing only when not a letter fits.
    func testAQuietSegmentsName() {
        func n(_ s: String) -> MapScene.SectionName { MapScene.SectionName(forms: MapRules.labels(s), base: nil, fixed: nil) }
        let parts = [n("Related Work"), n("Discussion")]
        let w = MapFont.name.width
        XCTAssertEqual(MapScene.quietName(parts, room: 400), "Related Work · Discussion")
        let both = MapScene.quietName(parts, room: 2 * w("Disc.") + w(" · ") + 1) ?? ""
        XCTAssertTrue(both.contains(" · "), both)
        let one = MapScene.quietName(parts, room: w("Rel. +1") + 0.5) ?? ""
        XCTAssertTrue(one.hasSuffix(" +1"), one)
        XCTAssertEqual(MapScene.quietName(parts, room: w("R") + 0.5), "R", "the first's letter rather than nothing")
        XCTAssertNil(MapScene.quietName(parts, room: w("R") - 0.5), "nothing only when not a letter fits")
        XCTAssertEqual(MapScene.quietName([n("Limitations")], room: 400), "Limitations")
    }

    // MARK: Every count drawn, over every state of the folded paper

    func testNothingCoversACountWhenFolded() throws {
        let d = try Self.sonar()
        var states = 0
        for w in Self.widths {
            for sel in MapLayoutTests.selections(d) {
                for shown in [Set<FoldKind>(), [.appendix]] {
                    let s = MapScene.build(MapInput(data: d, width: w, selection: sel, student: "Ana", shownParts: shown))
                    try MapLayoutTests.check(s, d, sel)
                    states += 1
                }
            }
        }
        XCTAssertGreaterThan(states, 200)
    }

    // MARK: The help tag and VoiceOver

    func testTheBlockSaysWhatItHolds() throws {
        let d = try Self.sonar()
        let lines = MapHelp.lines(.block(.appendix, round: 4), d, student: "Ana")
        XCTAssertEqual(lines.first, "Appendix A–E · Round 4 · pp. 17–29")
        XCTAssertTrue(lines[1].hasSuffix("pages, folded"))
        XCTAssertTrue(lines.contains { $0.contains("A Survey transects") && $0.contains("E Field log") })
        XCTAssertEqual(lines.last, "Click to show its sections")
        let said = MapSpeech.block(d, .appendix, 4)
        XCTAssertTrue(said.hasPrefix("Appendix A to E, Round 4: "))
        XCTAssertTrue(said.hasSuffix("Pages 17 to 29. Folded."))
        XCTAssertEqual(MapTarget.block(.appendix, round: 4).item, nil, "a click shows it; it follows nothing")
    }

    // MARK: Small maps

    func testSmallMapsFoldTheSameWay() throws {
        let d = try Self.sonar()
        let m = MiniMap.make(d)
        for r in m.rows {
            let blocks = r.cells.filter(\.block)
            XCTAssertEqual(blocks.count, 1, "the appendix one block, two pages wide")
            XCTAssertEqual(blocks[0].end - blocks[0].start, 2, accuracy: 0.001)
            XCTAssertLessThan(r.pages, Double(d.round(r.n)?.build?.pages ?? 0))
        }
        // shaded by its busiest section
        let r3 = try XCTUnwrap(d.round(3))
        let steps = MapShade.steps(MapShade.counts(d))
        let range = try XCTUnwrap(MapFold.range(.appendix, r3))
        let busiest = (r3.spans ?? [])[range.spans].map { s in r3.heat?.first { $0.section == s.section }?.present ?? 0 }.max() ?? 0
        XCTAssertEqual(m.rows.first { $0.n == 3 }?.cells.first(where: \.block)?.level, MapShade.level(busiest, steps))
        let off = MiniMap.make(d, fold: false)
        XCTAssertTrue(off.rows.allSatisfy { $0.cells.allSatisfy { !$0.block } })
        // neighbouring empty cells under 6 pt join; a counted cell never does
        let cells = [MiniMap.Cell(start: 0, end: 1, level: 1), MiniMap.Cell(start: 1, end: 1.1, level: 0),
                     MiniMap.Cell(start: 1.1, end: 1.2, level: 0), MiniMap.Cell(start: 1.2, end: 1.3, level: 2),
                     MiniMap.Cell(start: 1.3, end: 1.35, level: 0)]
        let runs = MiniMap.runs(cells, k: 10)
        XCTAssertEqual(runs.count, 4)
        XCTAssertEqual(runs[1].0, 1, accuracy: 0.001)
        XCTAssertEqual(runs[1].1, 1.2, accuracy: 0.001)
    }

    // MARK: Settings

    func testTheSettingsSwitchAndFlag() {
        XCTAssertEqual(LaunchOptions.parse(["app", "--fold", "off"]).fold, false)
        XCTAssertEqual(LaunchOptions.parse(["app", "--fold", "on"]).fold, true)
        XCTAssertNil(LaunchOptions.parse(["app"]).fold)
        let m = makeModel()
        let saved = UserDefaults.standard.object(forKey: AppModel.foldPartsKey) as? Bool
        m.foldParts = false
        XCTAssertEqual(UserDefaults.standard.object(forKey: AppModel.foldPartsKey) as? Bool, saved, "never saved by a test run")
        XCTAssertEqual(m.openAtLaunch, .lastPlace, "Where you left off by default")
        let open = UserDefaults.standard.string(forKey: AppModel.openAtLaunchKey)
        m.openAtLaunch = .allStudents
        XCTAssertEqual(UserDefaults.standard.string(forKey: AppModel.openAtLaunchKey), open, "never saved by a test run")
        XCTAssertFalse(AppModel.openAtLaunchKey.lowercased().contains("reopen"), "Reopen is the word for comments (TAGS.md §9)")
    }

    /// The Settings window's five tabs (VISUAL §7; Data & Storage, UX.md §28; Appearance went, §34), and the Overview tab's switch as a switch that
    /// sets the model's setting.
    func testTheSettingsWindow() throws {
        XCTAssertEqual(SettingsView.Tab.allCases.map(\.title), ["General", "Overview", "Reading", "Tags", "Data & Storage"])
        XCTAssertEqual(SettingsView.Tab.allCases.map(\.symbol), ["gearshape", "map", "book", "tag", "externaldrive"])
        for t in SettingsView.Tab.allCases { XCTAssertNotNil(NSImage(systemSymbolName: t.symbol, accessibilityDescription: nil), t.symbol) }
        let m = makeModel()
        let host = NSHostingView(rootView: OverviewSettings(model: m))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func find<T: NSView>(_ type: T.Type, in v: NSView) -> [T] { ((v as? T).map { [$0] } ?? []) + v.subviews.flatMap { find(type, in: $0) } }
        let toggle = try XCTUnwrap(find(NSSwitch.self, in: host).first)
        XCTAssertEqual(toggle.state, .on)
        toggle.performClick(nil)
        XCTAssertFalse(m.foldParts)
        XCTAssertEqual(OverviewSettings.foldTitle, "Fold the appendix and long reference lists")
    }

    // MARK: The colours

    /// UI v4's ramp in Sage green (the advisor's choice of 2026-10-31, mac/UX.md §40.10; design/ui-v4/README.md §6, the
    /// mockup's `:root`): the panel, the track, the three steps and `ink` each at least ΔE00 2.3 from the next, in one
    /// order of lightness; text on every step at 4.5:1 or more (on s3 only the label colour does: numbers and names
    /// there are in label; an older round's counts and names, and a folded block's on its pad, are in label2); an older
    /// round's ramp in the same order, lighter (darker in Dark Mode) than the open one's; what is followed drawn over
    /// the cells (`path`: the cell's and the page's outlines, a comment's path) and vermilion's to-check marks far from
    /// every step; the days with you and with the student seen on the card and apart from each other; a small map's
    /// empty cell seen on a hub card (with its keyline in Dark Mode); a band not merged with the track. Measured: label
    /// on s3 6.50:1 (4.75:1 dark), label2 on s2 5.59:1 (4.72:1) and on os3 5.55:1 (4.72:1); `path` from s3 ΔE00 24.3
    /// (23.8), 2.42:1 (2.39:1), where Dark Mode's accent would be 5.9, 1.21:1; vermilion from s3 47.8 (47.1), 2.10:1
    /// (1.69:1; from the grey's s3 31.0 and 27.6, 1.88:1 and 1.61:1); you and stu ΔE 22.8 (24.8), stu on the card
    /// 3.30:1 (3.08:1).
    func testTheMapsColours() {
        let ramp: [MapRole] = [.track, .s1, .s2, .s3, .ink, .otrack, .os1, .os2, .os3]
        let sage = [false: [0xECEDE9, 0xD4E0D5, 0xB3CBB7, 0x8FB096, 0x5E7F65, 0xF0F1EE, 0xE1EAE2, 0xCCDBCE, 0xB3CAB7],
                    true: [0x2C2F2C, 0x32453A, 0x3C5A44, 0x476F51, 0x8FB898, 0x282B28, 0x2E3B31, 0x344A3B, 0x3C5A44]]
        for dark in [false, true] {
            let ink = MapInk(dark: dark)
            XCTAssertEqual(ramp.map { ink.rgba($0).hex }, sage[dark], "the mockup's Sage ramp, dark \(dark)")
            XCTAssertTrue(ramp.allSatisfy { ink.rgba($0).alpha == 1 })
            let seq: [MapRole] = [.content, .track, .s1, .s2, .s3, .ink]
            let colours = seq.map { ink.over($0) }
            for (a, b) in zip(colours, colours.dropFirst()) {
                XCTAssertGreaterThanOrEqual(DesignPaletteTests.deltaE(a, b), 2.3, "dark \(dark)")
            }
            let l = colours.map { DesignPaletteTests.lab($0).L }
            XCTAssertEqual(l, dark ? l.sorted() : l.sorted(by: >), "one order of lightness (dark \(dark))")
            let old = [MapRole.otrack, .os1, .os2, .os3].map { DesignPaletteTests.lab(ink.over($0)).L }
            XCTAssertEqual(old, dark ? old.sorted() : old.sorted(by: >), "an older round's steps in the same order")
            for (o, n) in zip(old, l.dropFirst()) { XCTAssertEqual(dark ? o < n : o > n, true, "an older round steps back (dark \(dark))") }
            for step in [MapRole.track, .s1, .s2, .s3] {
                XCTAssertGreaterThanOrEqual(Self.contrast(ink.over(.label), ink.over(step)), 4.5, "a number on \(step)")
                if step != .s3 { XCTAssertGreaterThanOrEqual(Self.contrast(ink.over(.name), ink.over(step)), 4.5, "a name on \(step)") }
            }
            // UI v4: a folded block's label on its solid pad; an older round's words (label2) on its steps; a cell's name
            // without comments (secondary) on the track
            for step in [MapRole.track, .otrack, .os1, .os2, .os3] {
                XCTAssertGreaterThanOrEqual(Self.contrast(ink.over(.label2), ink.over(step)), 4.5, "label2 on \(step), dark \(dark)")
            }
            for step in [MapRole.track, .otrack] {
                XCTAssertGreaterThanOrEqual(Self.contrast(ink.over(.secondary), ink.over(step)), 4.5, "secondary on \(step), dark \(dark)")
            }
            // the outlines and paths of what is followed, and the to-check outlines and rings, never taken for a step
            for step in [MapRole.track, .s1, .s2, .s3, .otrack, .os1, .os2, .os3] {
                XCTAssertGreaterThanOrEqual(DesignPaletteTests.deltaE(ink.over(.path), ink.over(step)), 15, "Sage over \(step), dark \(dark)")
                XCTAssertGreaterThanOrEqual(DesignPaletteTests.deltaE(ink.over(.attention), ink.over(step)), 15, "vermilion on \(step), dark \(dark)")
            }
            XCTAssertGreaterThanOrEqual(Self.contrast(ink.over(.you, .card), ink.over(.card)), 3, "your days, a graphic")
            XCTAssertGreaterThanOrEqual(Self.contrast(ink.over(.stu, .card), ink.over(.card)), 3, "the student's days, a graphic")
            XCTAssertGreaterThanOrEqual(DesignPaletteTests.deltaE(ink.over(.you, .card), ink.over(.stu, .card)), 20, "the two series apart")
            XCTAssertLessThan(DesignPaletteTests.deltaE(ink.over(.fan), ink.over(.content)), DesignPaletteTests.deltaE(ink.over(.track), ink.over(.content)),
                              "the lens's hairlines quieter than any cell")
            // A small map's cell without comments on a hub card: the track, or in Dark Mode its keyline (the track
            // alone is within ΔE 1.4 of the dark card, #2A2C2A). Measured: 4.41 light, keyline 6.30 dark (the grey's:
            // 4.59, 6.16).
            let card = ink.over(.card), edge = ink.over(.zeroline, .track)
            let seen = max(DesignPaletteTests.deltaE(ink.over(.track, .card), card), DesignPaletteTests.deltaE(edge, card))
            XCTAssertGreaterThanOrEqual(seen, 2.3, "an empty small-map cell on the card, dark \(dark)")
            // A band is about the track's tone (1.47, 2.44 dark; the grey's 0.86, 1.30); its shape and label tell it
            // from an empty cell (UX §40.1). This only keeps the two from merging.
            XCTAssertGreaterThanOrEqual(DesignPaletteTests.deltaE(ink.over(.band), ink.over(.track)), 0.8, "a band apart from the track, dark \(dark)")
        }
        // over the cells, what is followed is the accent in Light Mode, a lighter Sage in Dark Mode (the accent is
        // within ΔE00 6 of the green s3 there)
        XCTAssertEqual(MapInk(dark: false).rgba(.path).hex, MapInk(dark: false).rgba(.accent).hex)
    }

    /// The roles the app's palette owns are read from it, so the map's colours never drift from the panel's (UI v4).
    func testTheMapReadsThePalette() {
        let shared: [(MapRole, NSColor)] = [
            (.label, Palette.label), (.number, Palette.label), (.label2, Palette.label2), (.name, Palette.label2),
            (.secondary, Palette.secondary), (.tertiary, Palette.tertiary), (.attention, Palette.toCheck),
            (.danger, Palette.danger), (.accent, Palette.accent), (.accentText, Palette.accentText),
            (.words, Palette.changedWords), (.other, Palette.unrequested), (.content, Palette.panel), (.card, Palette.card),
            (.neutral, Palette.neutral),
        ]
        for dark in [false, true] {
            let ink = MapInk(dark: dark)
            for (role, colour) in shared {
                XCTAssertEqual(ink.rgba(role).hex, MapInk.hex(colour, dark: dark), "\(role), dark \(dark)")
                XCTAssertEqual(ink.rgba(role).alpha, 1)
            }
        }
        XCTAssertEqual(MapInk(dark: false).rgba(.attention).hex, 0xC04734, "vermilion")
        XCTAssertEqual(MapInk(dark: true).rgba(.attention).hex, 0xDB6A50)
        XCTAssertEqual(MapRole.mini(2), .s2, "the small maps use the one ramp")
    }

    static func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        func lum(_ c: NSColor) -> CGFloat {
            let s = c.usingColorSpace(.sRGB)!
            func ch(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * ch(s.redComponent) + 0.7152 * ch(s.greenComponent) + 0.0722 * ch(s.blueComponent)
        }
        let (x, y) = (lum(a), lum(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}
