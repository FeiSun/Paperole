import AppKit
import PDFKit
import XCTest
@testable import Paperole

/// Checks that go to the student (design/checks-ui; engine/CONTRACT.md amendment "Checks to the student"): the
/// engine's `check_items` decoded, the Checks tab's groups as the Comments tab's (To check, For the student, Closed this
/// round), the marks on the page and a click on one, Follow Up…, the Finish sheet's lines and the round card's
/// Paperole line. On the reading fixture (round 2 open) with items made by hand on `Fixtures/checks-round2.json`'s
/// places. A test run never asks the engine. Synthetic only.
@MainActor
final class CheckItemsTests: XCTestCase {
    private var drafts: URL!
    private var window: NSWindow!
    private var model: AppModel!
    private var view: ReviewPDFView!

    /// Six items: A1-01 carried, still found, the student answered; A1-02 carried, still found; A2-01 and A2-02 new;
    /// A1-03 fixed; A2-03 new and marked OK.
    static func items() throws -> [Check] {
        let checks = try XCTUnwrap(try ChecksTests.reply().checks)
        let json = """
        {"round": 2, "items": [
          {"id": "A1-01", "state": "still", "carried": true, "code": "undefined_ref", "group": "references",
           "text": "\(checks[0].text)", "key": "undefined_ref|sec:model",
           "student_note": {"text": "Fixed in the source; the label was renamed.", "file": "main.tex", "line": 40},
           "history": [{"round": 1, "state": "new"}], "places": \(places(checks[0]))},
          {"id": "A1-02", "state": "still", "carried": true, "code": "lowered_caps", "group": "bibliography",
           "text": "\(checks[1].text.replacingOccurrences(of: "\"", with: "\\\""))", "key": "lowered_caps|sand|SAND",
           "advisor_note": "", "places": \(places(checks[1]))},
          {"id": "A2-01", "state": "new", "code": "ref_style", "group": "consistency", "text": "Eq. (1) · (1)",
           "key": "ref_style|equations", "places": \(places(checks[2]))},
          {"id": "A2-02", "state": "new", "code": "overfull", "group": "typesetting", "text": "Overfull line · 4.2 pt too wide",
           "key": "overfull|Overfull line|r2", "places": \(places(checks[3]))},
          {"id": "A1-03", "state": "fixed", "carried": true, "code": "doubled_word", "group": "typesetting",
           "text": "Doubled word the the", "key": "doubled_word|the the|r1", "places": []},
          {"id": "A2-03", "state": "new", "ok": true, "code": "pdf_author", "group": "submission", "text": "PDF author · Lin Zhou",
           "key": "pdf_author|Lin Zhou", "places": []}]}
        """
        return try XCTUnwrap(try makeDecoder().decode(CheckItemsReply.self, from: Data(json.utf8)).items)
    }

    private static func places(_ c: Check) -> String {
        "[" + c.places.map { p in "{\"page\": \(p.page), \"rects\": \(p.rects)}" }.joined(separator: ", ") + "]"
    }

    override func setUpWithError() throws {
        drafts = FileManager.default.temporaryDirectory.appendingPathComponent("pc-checkitems-" + UUID().uuidString)
        _ = NSApplication.shared
        var o = LaunchOptions()
        o.fixture = StepTests.fixtures.appendingPathComponent("state-reading.json").path
        o.drafts = drafts.path
        o.checks = true
        model = AppModel(options: o)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 900), styleMask: [.titled],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view = ReviewPDFView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(view)
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        model.pdf.attach(view)
        model.setChecks(try Self.items(), round: 2)
        model.pdf.update(url: model.pdfURL, key: MarkKey(version: model.stateVersion, showChanges: false,
                                                          checks: model.checkMarksVersion))
        view.layoutDocumentView()
    }

    override func tearDownWithError() throws {
        window.close()
        try? FileManager.default.removeItem(at: drafts)
    }

    private func shown() -> [String] {
        model.checks.items.map { item -> String in
            switch item.kind {
            case .message(let m): return "message: " + m
            case .group(let g, let n): return "group: \(g.rawValue) \(n)"
            case .kind(let k): return "kind: " + k
            case .check(let i): return "check \(i)"
            }
        }
    }

    /// The items decode: id, state, carried, the student's note, the advisor's (an empty one is none), the history.
    func testTheItemsDecode() throws {
        let cs = model.checks.list
        XCTAssertEqual(cs.map(\.id), ["A1-01", "A1-02", "A2-01", "A2-02", "A1-03", "A2-03"])
        XCTAssertEqual(cs.map(\.state), ["still", "still", "new", "new", "fixed", "new"])
        XCTAssertEqual(cs.map(\.carried), [true, true, false, false, true, false])
        XCTAssertEqual(cs[0].studentNote?.text, "Fixed in the source; the label was renamed.")
        XCTAssertEqual(cs[0].studentNote?.line, 40)
        XCTAssertNil(cs[1].advisorNote, "an empty note is none")
        XCTAssertEqual(cs[0].history, [Check.Record(round: 1, state: "new")])
        XCTAssertEqual(cs.map(\.stateWord), ["still found", "still found", "new", "new", "fixed", "marked OK"])
        XCTAssertEqual(cs.map(\.status), [.toCheck, .toCheck, .new, .new, .resolved, .keptAsIs])
        // an engine before check items: no ids, read as new
        let old = try XCTUnwrap(try ChecksTests.reply().checks)
        XCTAssertTrue(old.allSatisfy { $0.id == nil && $0.state == nil && !$0.carried && $0.status == .new })
    }

    /// The groups, as the Comments tab's: the answered check is To check (the tab's count), the others that go out are
    /// For the student by kind, the fixed and the marked OK Closed this round, folded; in a closed round nothing is To
    /// check and the sentence says they went out.
    func testTheGroups() throws {
        XCTAssertEqual(shown(), ["group: toCheck 1", "check 0", "group: forStudent 3", "kind: Bibliography", "check 1",
                                 "kind: Consistency", "check 2", "kind: Typesetting", "check 3", "group: closed 2"])
        XCTAssertEqual(model.checks.tabTitle, "Checks 1")
        XCTAssertEqual(model.checks.sent, 4)
        XCTAssertEqual(model.checks.closedWords, "1 fixed · 1 marked OK")
        model.checks.showClosed = true
        XCTAssertEqual(shown().suffix(3), ["group: closed 2", "check 4", "check 5"])
        model.checks.showStudent = false
        XCTAssertEqual(shown(), ["group: toCheck 1", "check 0", "group: forStudent 3", "group: closed 2", "check 4", "check 5"])
        XCTAssertEqual(model.checks.order, [0, 4, 5], "J and K pass a folded group")
        model.checks.showStudent = true
        model.checks.roundOpen = false
        XCTAssertEqual(model.checks.tabTitle, "Checks")
        XCTAssertEqual(model.checks.members(.toCheck), [])
        XCTAssertEqual(model.checks.members(.forStudent), [0, 1, 2, 3])
        XCTAssertEqual(model.checks.sentence, "Found by Paperole.")
        model.checks.show([], round: 2, key: model.checks.key ?? "", pages: nil)
        XCTAssertEqual(model.checks.sentence, "No checks went out with this round.", "a round finished with Checks off")
    }

    /// Review fixes 2026-11-01: a fixed check cannot be marked OK (it is closed already); the Finish sheet says when the
    /// checks are still being found; My Comment… is forgotten when its editor closes.
    func testReviewFixes() throws {
        XCTAssertEqual(model.checkMenu(4).first?.enabled, false, "A1-03 is fixed")
        model.markCheck(4, true)
        XCTAssertFalse(model.checks.list[4].ok)
        let key = try XCTUnwrap(model.checks.key)
        model.checks.ask(key)
        XCTAssertEqual(model.finishChecks, FinishSummary.Checks(sent: 0, ok: 0, toCheck: 0, pending: true))
        var s = FinishSummary(round: 2, comments: [], drafts: [:], unrequested: 0, unread: nil)
        s.checks = model.finishChecks
        XCTAssertEqual(s.left.first?.title, "Automatic checks still being found")
        XCTAssertNil(s.goes.first { $0.item == .checks })
        model.setChecks(try Self.items(), round: 2)
        model.pickCheckMenu(2, .comment)
        model.commentEditorClosed()
        model.createComment(anchor: ["page": 1, "rects": [[10, 10, 20, 20]], "text": "x"], note: "n", kind: .highlight,
                            color: .yellow, on: (model.selectedPath, model.round?.n)) { _ in }
        XCTAssertFalse(model.checks.list[2].ok, "the editor closed without a comment: the check is left as it was")
    }

    /// The checks that go out are marked on the page in Paperole's slate with square labels, under the comments; the
    /// fixed and the marked OK are not; a click on a check's mark shows its card on the Checks tab and outlines it.
    func testTheMarksOnThePage() throws {
        XCTAssertEqual(model.checkMarks.compactMap(\.id), ["A1-01", "A1-02", "A2-01", "A2-02"])
        let doc = try XCTUnwrap(view.document)
        let squares = (0..<doc.pageCount).flatMap { doc.page(at: $0)!.annotations.compactMap { $0 as? MarkAnnotation } }
            .filter(\.square)
        XCTAssertEqual(Set(squares.compactMap(\.label)), ["○ A1-01", "○ A1-02", "+ A2-01", "+ A2-02"])
        XCTAssertEqual(squares.count, 6, "each place with rects: two for A1-01, A2-01's two pages")
        XCTAssertTrue(squares.allSatisfy { $0.fill == Palette.checkFill && $0.labelColor == Palette.checkInk })
        XCTAssertEqual(model.tab, .comments)
        model.checkMarkClicked("A2-01")
        XCTAssertEqual(model.tab, .checks)
        XCTAssertEqual(model.checks.current, 2)
        XCTAssertEqual(model.selectedCheckID, "A2-01")
        model.checkMarkClicked("A1-03")
        XCTAssertEqual(model.checks.current, 2, "a fixed check has no mark to click")
        // marked OK: its marks go
        model.markCheck(2, true)
        model.pdf.update(url: model.pdfURL, key: MarkKey(version: model.stateVersion, showChanges: false,
                                                          checks: model.checkMarksVersion))
        let after = (0..<doc.pageCount).flatMap { doc.page(at: $0)!.annotations.compactMap { $0 as? MarkAnnotation } }
            .filter(\.square)
        XCTAssertFalse(after.contains { $0.label == "+ A2-01" })
    }

    /// Follow Up… keeps the advisor's words on the check (a test run keeps them here); My Comment… is the menu's.
    func testFollowUpAndMyComment() throws {
        model.followUpCheck(1, "  Please protect the capitals with braces.  ")
        XCTAssertEqual(model.checks.list[1].advisorNote, "Please protect the capitals with braces.")
        model.followUpCheck(1, "")
        XCTAssertNil(model.checks.list[1].advisorNote)
        XCTAssertEqual(model.checkMenu(2).map(\.title), ["Mark as OK", "My Comment…", "Keep Open", "Copy"])
    }

    /// The Finish sheet: what goes out (with those left out), and the checks the student answered as a to-do.
    func testTheFinishSheet() throws {
        let c = try XCTUnwrap(model.finishChecks)
        XCTAssertEqual(c, FinishSummary.Checks(sent: 4, ok: 1, toCheck: 1))
        var s = FinishSummary(round: 2, comments: [], drafts: [:], unrequested: 0, unread: nil)
        s.checks = c
        let goes = try XCTUnwrap(s.goes.first { $0.item == .checks })
        XCTAssertEqual(goes.title, "Automatic checks")
        XCTAssertEqual(goes.sub, "found by Paperole · 1 marked OK is left out")
        XCTAssertEqual(goes.count, 4)
        let left = try XCTUnwrap(s.left.first { $0.item == .checksToCheck })
        XCTAssertEqual(left.title, "Check the student answered")
        XCTAssertEqual(left.count, 1)
        s.checks = FinishSummary.Checks(sent: 0, ok: 2, toCheck: 0)
        XCTAssertNil(s.goes.first { $0.item == .checks }, "none going out: no line")
        model.checksOn = false
        XCTAssertNil(model.finishChecks)
    }

    /// The round card's Paperole line: what went out and what was fixed; none without checks.
    func testTheRoundCardLine() throws {
        let st = try XCTUnwrap(model.state)
        let stats = model.roundStats(st)
        XCTAssertEqual(stats.checksSent, 4)
        XCTAssertEqual(stats.checksFixed, 1)
        XCTAssertEqual(stats.checksLine?.lead, "Paperole")
        XCTAssertEqual(stats.checksLine?.rest, "4 automatic checks · 1 fixed")
        var none = stats
        none.checksSent = nil
        none.checksFixed = 0
        XCTAssertNil(none.checksLine)
    }
}
