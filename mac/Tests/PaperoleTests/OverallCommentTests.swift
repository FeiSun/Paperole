import AppKit
import XCTest
@testable import Paperole

/// Comments on the whole paper in Review (design/comments/PLAN.md §3 S, §6a): their row and card say "overall" where
/// the page goes, never "not found", "position uncertain" or "unchanged"; they come first in their group; they have no
/// kind or Re-anchor…; + Overall comment is on the list's line in an open round, from the start. Synthetic fixtures only.
@MainActor
final class OverallCommentTests: XCTestCase {
    private var tmp: URL!
    private let fixtureRefusal = "Fixture mode: the engine is not running, so nothing is saved."

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pc-overall-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func overall(_ extra: [String: Any] = [:]) throws -> Comment {
        var base: [String: Any] = [
            "id": "R1-04", "kind": "overall", "note": "Separate the two claims.\nSay so in the introduction.",
            "created_round": 1, "carried": true, "anchor_state": "overall", "confidence": 1.0, "method": "overall",
            "page": NSNull(), "rects": [], "text": NSNull(), "old_quote": NSNull(), "new_quote": NSNull(),
            "file": NSNull(), "line": NSNull(), "context": NSNull(),
            "history": [["round": 1, "anchor_state": "new", "verdict": NSNull(), "verdict_note": "", "page": NSNull()]]]
        for (k, v) in extra { base[k] = v }
        return try makeComment(base)
    }

    func testItsCardSaysOverallAndNothingAboutAPlace() throws {
        let c = try overall()
        XCTAssertTrue(c.isOverall)
        let card = CardModel(c, round: 2, pdfs: [:], textX: [], showChanges: true)
        XCTAssertTrue(card.overall)
        XCTAssertNil(card.page)
        XCTAssertEqual(card.status, .toCheck, "never Not found")
        XCTAssertEqual(card.stateWord, "no note")
        XCTAssertEqual(card.thread.count, 1)
        XCTAssertEqual(card.thread[0].event, "on the whole paper")
        XCTAssertEqual(card.thread[0].rounds, [1, 2])
        XCTAssertFalse(card.thread[0].uncertain)
        XCTAssertFalse(card.turns.contains { $0.verb == "unchanged" || $0.verb == "still not found" })

        let explained = CardModel(try overall(["student_note": ["text": "Split in §3 and §4.", "file": "main.tex", "line": 4]]),
                                  round: 2, pdfs: [:], textX: [], showChanges: true)
        XCTAssertEqual(explained.stateWord, "explained")
        let new = CardModel(try overall(["carried": false, "created_round": 2, "anchor_state": "new", "history": []]),
                            round: 2, pdfs: [:], textX: [], showChanges: true)
        XCTAssertEqual(new.stateWord, "new")
    }

    func testOverallCommentsComeFirstInTheirGroup() throws {
        let placed = try makeComment(["id": "R1-01"]), later = try makeComment(["id": "R2-01", "carried": false, "created_round": 2])
        let o1 = try overall(), o2 = try overall(["id": "R2-02", "carried": false, "created_round": 2, "anchor_state": "new"])
        XCTAssertEqual(AppModel.ordered([placed, later, o2, o1]).map(\.id), ["R1-04", "R2-02", "R1-01", "R2-01"])
    }

    func testPlusOverallCommentOpensItsEditorAndSaves() throws {
        _ = NSApplication.shared
        var o = LaunchOptions()
        o.fixture = StepTests.fixtures.appendingPathComponent("state-m2a.json").path
        o.drafts = tmp.appendingPathComponent("drafts").path
        let m = AppModel(options: o)
        XCTAssertTrue(m.roundIsOpen)
        XCTAssertTrue(m.listBar.shown)
        XCTAssertTrue(m.listBar.canAddOverall)
        m.beginOverallComment()
        let d = try XCTUnwrap(m.listBar.overallDraft)
        XCTAssertEqual(d.mode, .overall)
        d.note = "Too long for 8 pages."
        m.saveOverallComment(d)
        XCTAssertEqual(m.alertMessage, fixtureRefusal, "the engine's comment was asked for")
        XCTAssertNotNil(m.listBar.overallDraft, "a refusal keeps the note")
        XCTAssertFalse(d.saving)

        // another paper shown meanwhile: not saved there
        m.alertMessage = nil
        m.overallFor = ("/elsewhere", 2)
        m.saveOverallComment(d)
        XCTAssertNotNil(m.alertMessage)
        XCTAssertNotEqual(m.alertMessage, fixtureRefusal)
    }

    func testNoKindChangeOrReanchorForAnOverallComment() throws {
        _ = NSApplication.shared
        var o = LaunchOptions()
        o.fixture = StepTests.fixtures.appendingPathComponent("state-m2a.json").path
        o.drafts = tmp.appendingPathComponent("drafts").path
        let m = AppModel(options: o)
        // the fixture's state with a new overall comment of its open round
        let url = StepTests.fixtures.appendingPathComponent("state-m2a.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var cs = try XCTUnwrap(json["comments"] as? [[String: Any]])
        cs.append(["id": "R2-09", "kind": "overall", "color": "blue", "note": "Too long.", "source": "app",
                   "created_round": 2, "carried": false, "verdict": NSNull(), "verdict_note": "", "anchor_state": "new",
                   "confidence": 1.0, "method": "overall", "page": NSNull(), "rects": [], "text": NSNull(),
                   "old_quote": NSNull(), "new_quote": NSNull(), "file": NSNull(), "line": NSNull(), "changes": [],
                   "history": [], "context": NSNull()])
        json["comments"] = cs
        m.apply(try EngineState.decode(JSONSerialization.data(withJSONObject: json)))
        let c = try XCTUnwrap(m.comment("R2-09"))
        XCTAssertFalse(m.canChangeKind(c))
        XCTAssertTrue(m.canEditNote(c))
        let titles = CardMenus.more(c.id, model: m).items.map(\.title)
        XCTAssertTrue(titles.contains("Edit Note") && titles.contains("Colour"), "\(titles)")
        XCTAssertFalse(titles.contains("Re-anchor…") || titles.contains("Kind"), "\(titles)")
        XCTAssertEqual(m.panel.cards.first { $0.id == "R2-09" }?.overall, true)
    }

    func testANoteClosedByAClickElsewhereComesBack() throws {
        _ = NSApplication.shared
        var o = LaunchOptions()
        o.fixture = StepTests.fixtures.appendingPathComponent("state-m2a.json").path
        o.drafts = tmp.appendingPathComponent("drafts").path
        let m = AppModel(options: o)
        m.beginOverallComment()
        let d = try XCTUnwrap(m.listBar.overallDraft)
        d.note = "Half a thought"
        // what the popover's binding does when a click elsewhere closes it
        m.overallStash = d
        m.listBar.overallDraft = nil
        m.beginOverallComment()
        XCTAssertTrue(m.listBar.overallDraft === d, "the same note again")
        XCTAssertNil(m.overallStash)
        // on another paper or round it is not offered
        m.listBar.overallDraft = nil
        m.overallStash = d
        m.overallFor = ("/elsewhere", 1)
        m.beginOverallComment()
        XCTAssertFalse(m.listBar.overallDraft === d)
        XCTAssertEqual(m.listBar.overallDraft?.note, "")
    }

    func testOverallLabelsSitInARowOverTheTextOfPageOne() {
        let cb = CGRect(x: 0, y: 0, width: 612, height: 792), text = CGRect(x: 100, y: 72, width: 200, height: 620)
        let z = CGSize(width: 90, height: 11)
        let r = PDFController.overallLabelRects([z, z, z], text: text, cropBox: cb)
        XCTAssertEqual(r[0].origin, CGPoint(x: 100, y: 712), "the first row on top, at the text's left edge")
        XCTAssertEqual(r[1].origin, CGPoint(x: 194, y: 712))
        XCTAssertEqual(r[2].origin, CGPoint(x: 100, y: 698), "past the text's right edge: the next row, 6 pt over the text")
        // the text's top near the page's: never above the page, never over each other
        let high = PDFController.overallLabelRects([z, z, z, z, z], text: CGRect(x: 100, y: 72, width: 200, height: 691),
                                                   cropBox: cb)
        XCTAssertLessThanOrEqual(high.map(\.maxY).max() ?? 0, 788)
        for (i, a) in high.enumerated() {
            for b in high[(i + 1)...] { XCTAssertFalse(a.intersects(b), "\(a) \(b)") }
        }
    }

    /// The round 2 fixture with an overall comment of its own, shown in a PDF view in a window.
    private var windows: [NSWindow] = []

    private func shown() throws -> (AppModel, ReviewPDFView) {
        _ = NSApplication.shared
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: StepTests.fixtures
            .appendingPathComponent("state-round2.json"))) as? [String: Any])
        var cs = try XCTUnwrap(json["comments"] as? [[String: Any]])
        cs.append(["id": "R2-09", "kind": "overall", "color": "blue", "note": "Too long.", "source": "app",
                   "created_round": 2, "carried": false, "verdict": NSNull(), "verdict_note": "", "anchor_state": "new",
                   "confidence": 1.0, "method": "overall", "page": NSNull(), "rects": [], "text": NSNull(),
                   "old_quote": NSNull(), "new_quote": NSNull(), "file": NSNull(), "line": NSNull(), "changes": [],
                   "history": [], "context": NSNull()])
        json["comments"] = cs
        let url = tmp.appendingPathComponent("state.json")
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        for r in ["round1", "round2"] {
            try? FileManager.default.createSymbolicLink(at: tmp.appendingPathComponent(r),
                                                        withDestinationURL: StepTests.fixtures.appendingPathComponent(r))
        }
        var o = LaunchOptions()
        o.fixture = url.path
        o.drafts = tmp.appendingPathComponent("drafts").path
        o.tags = tmp.appendingPathComponent("tags.json").path
        let m = AppModel(options: o)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 900), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        let v = ReviewPDFView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(v)
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        m.pdf.attach(v)
        m.pdf.update(url: m.pdfURL, key: MarkKey(version: m.stateVersion, showChanges: m.showChanges))
        v.layoutDocumentView()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        return (m, v)
    }

    func testItsLabelIsAtTheTopOfPageOneAndSelectsItsCard() throws {
        let (m, v) = try shown()
        defer { windows.forEach { $0.close() } }
        let c = try XCTUnwrap(m.comment("R2-09"))
        let at = try XCTUnwrap(m.pdf.overallLabel(c.id))
        XCTAssertEqual(at.page, 0)
        let r = at.rect
        let page = try XCTUnwrap(v.document?.page(at: 0)), cb = page.bounds(for: .cropBox)
        XCTAssertLessThan(r[1], 100, "in the top margin: \(r)")
        // over the first words of the page
        let words = try XCTUnwrap(page.selection(for: cb)?.bounds(for: page))
        XCTAssertGreaterThanOrEqual(cb.maxY - r[3], words.maxY, "clear of the text")
        // a click on it selects the card; no mark toolbar, as there is no mark to restyle
        let hit = m.pdf.click(page: page, at: CGPoint(x: cb.minX + (r[0] + r[2]) / 2, y: cb.maxY - (r[1] + r[3]) / 2))
        XCTAssertEqual(hit, "R2-09")
        XCTAssertEqual(m.selection, .comment("R2-09"))
        XCTAssertFalse(m.pdf.markBarShown)
        XCTAssertEqual(m.pdf.selectedMarks, ["R2-09"], "outlined")
        XCTAssertTrue(m.pdf.isVisible(c), "p.1's top is shown")
        // marks off (--debug-marks off): no label, and its card moves the PDF nowhere
        m.pdf.showMarks = false
        m.pdf.update(url: m.pdfURL, key: MarkKey(version: m.stateVersion, showChanges: !m.showChanges))
        XCTAssertNil(m.pdf.overallLabel(c.id))
    }

    func testByTagAndSectionAnOverallCommentIsFirstUnderWholePaper() throws {
        let o1 = try overall(), placed = try makeComment(["id": "R1-01"])
        let s = ListSections.make(nil, comments: [placed, o1])
        XCTAssertEqual(s.of["R1-04"], ListSections.whole)
        XCTAssertEqual(s.titles[ListSections.whole]?.name, "Whole paper")
        XCTAssertLessThan(try XCTUnwrap(s.rank["R1-04"]), try XCTUnwrap(s.rank["R1-01"]))
    }
}
