import AppKit
import PDFKit
import SwiftUI
import XCTest
@testable import Paperole

/// Checks (UX.md §39; design/pdf-reader/PLAN.md P1.5): the engine's `checks` reply decoded, the panel's Checks tab, a
/// click on a row, its menu and the setting, on the reading fixture (round 2 open) with `Fixtures/checks-round2.json`,
/// made by hand: its places are rects of real words of the fixture's round-2 PDF (read with PyMuPDF). A test run never
/// asks the engine: the checks are set (`AppModel.setChecks`). Synthetic only.
@MainActor
final class ChecksTests: XCTestCase {
    private var drafts: URL!
    private var window: NSWindow!
    private var model: AppModel!
    private var view: ReviewPDFView!

    static func reply() throws -> ChecksReply {
        try makeDecoder().decode(ChecksReply.self, from: Data(contentsOf: StepTests.fixtures.appendingPathComponent("checks-round2.json")))
    }

    private func makeModel(checks: Bool? = true) -> AppModel {
        _ = NSApplication.shared
        var o = LaunchOptions()
        o.fixture = StepTests.fixtures.appendingPathComponent("state-reading.json").path
        o.drafts = drafts.path
        o.checks = checks
        return AppModel(options: o)
    }

    override func setUpWithError() throws {
        drafts = FileManager.default.temporaryDirectory.appendingPathComponent("pc-checks-drafts-" + UUID().uuidString)
        model = makeModel()
        XCTAssertTrue(model.roundIsOpen)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 900), styleMask: [.titled],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view = ReviewPDFView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(view)
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        model.pdf.attach(view)
        model.pdf.update(url: model.pdfURL, key: MarkKey(version: model.stateVersion, showChanges: true))
        view.layoutDocumentView()
        model.setChecks(try Self.reply().checks, round: 2)
        top(of: 0)
    }

    override func tearDownWithError() throws {
        model.pdf.popover?.close()
        model.pdf.closePinned()
        window.close()
        try? FileManager.default.removeItem(at: drafts)
    }

    private func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    private func top(of i: Int) {
        let page = view.document!.page(at: i)!
        view.go(to: PDFDestination(page: page, at: CGPoint(x: 0, y: page.bounds(for: .cropBox).maxY)))
        view.layoutDocumentView()
        model.pdf.ownMove()
    }

    private var steps: Int { model.navHistory.back.filter(\.step).count }

    /// The page at the view's third and whether a check's place is on screen.
    private func at(_ check: Int, _ place: Int) -> (page: Int?, visible: Bool) {
        view.layoutDocumentView()
        let p = model.checks.list[check].places[place]
        return (model.pdf.shownPage, model.pdf.isVisible(page: p.page, rects: p.rects))
    }

    /// The menu's items after Mark as OK (`testMarkAsOK` has it).
    private func titles(_ i: Int) -> [String] { model.checkMenu(i).filter { $0.action != .ok }.map(\.title) }
    private func enabled(_ i: Int) -> [Bool] { model.checkMenu(i).filter { $0.action != .ok }.map(\.enabled) }

    // MARK: The reply

    func testTheReply() throws {
        let r = try Self.reply()
        XCTAssertEqual(r.round, 2)
        let cs = try XCTUnwrap(r.checks)
        XCTAssertEqual(cs.map(\.code), ["undefined_ref", "lowered_caps", "ref_style", "overfull", "type3_font", "pdf_author"])
        XCTAssertEqual(cs[0].places.count, 2)
        XCTAssertEqual(cs[0].places[0].rects, [[389.7, 486.7, 440.2, 496.6]])
        XCTAssertEqual(cs[0].places[0].text, "Section 3")
        XCTAssertEqual(cs[0].note, "The reference to sec:model prints “??”: its \\label is missing.")
        XCTAssertNil(cs[5].note)
        XCTAssertEqual(cs[4].places, [Check.Place(page: 1, rects: [])], "a page only")
        XCTAssertEqual(cs[5].places, [], "the PDF's metadata")
        // the row's words, trail and help tag
        XCTAssertEqual(cs[0].trail, "p.1")  // two places on one page: the page once
        XCTAssertEqual(cs[2].trail, "p.2, 3")
        XCTAssertEqual(cs[3].trail, "p.3")
        XCTAssertNil(cs[5].trail)
        XCTAssertEqual(cs[0].help, "Click again for the next place.")
        XCTAssertEqual(cs[3].help, "", "one place: no help tag (the detail is under the words)")
        XCTAssertEqual(cs[5].help, "It has no place on the pages to go to.")
        XCTAssertEqual(cs[3].copied, "Overfull line · 4.2 pt too wide\n" + (cs[3].detail ?? ""))
    }

    /// Lenient: missing fields take defaults, a rect that is not four numbers and a place with a negative page are left
    /// out, an unknown group is kept; checks null (no paragraphs) decodes as none.
    func testALenientDecoding() throws {
        let json = """
        {"round": 3, "path": null, "checks": [
          {"code": "x_new", "group": "style", "text": "Something new", "places": [
            {"page": 0, "rects": [[1, 2, 3], [10, 10, 20, 20]]}, {"page": -1, "rects": []}, {"page": 9}]},
          {"code": "bare"}]}
        """
        let r = try makeDecoder().decode(ChecksReply.self, from: Data(json.utf8))
        let cs = try XCTUnwrap(r.checks)
        XCTAssertEqual(cs[0].group, "style")
        XCTAssertNil(cs[0].detail)
        XCTAssertEqual(cs[0].places, [Check.Place(page: 0, rects: [[10, 10, 20, 20]]), Check.Place(page: 9, rects: [])])
        XCTAssertEqual(cs[1].text, "bare", "no text: its code")
        XCTAssertEqual(cs[1].group, "other")
        XCTAssertEqual(cs[1].places, [])
        let none = try makeDecoder().decode(ChecksReply.self, from: Data(#"{"round": 2, "path": null, "checks": null}"#.utf8))
        XCTAssertNil(none.checks)
        // a place past the round's pages (4) is left out when shown; an unknown group after the known ones
        model.setChecks(cs + (try Self.reply().checks ?? []), round: 2)
        XCTAssertEqual(model.checks.list[0].places, [Check.Place(page: 0, rects: [[10, 10, 20, 20]])])
        XCTAssertEqual(model.checks.sections.map(\.title),
                       ["References", "Bibliography", "Consistency", "Typesetting", "Submission", "Style", "Other"])
        XCTAssertEqual(model.checks.items.compactMap { if case .group(let g) = $0.kind { return g } else { return nil } },
                       ["References", "Bibliography", "Consistency", "Typesetting", "Submission", "Style", "Other"])
    }

    /// A malformed place or rect is left out by itself: a place without a page (missing, null, not a number) and a rect
    /// that holds a null or a string, or is not an array, never cost the other places or checks (review 2026-10-30).
    func testABadPlaceIsLeftOutAlone() throws {
        let json = """
        {"round": 2, "path": null, "checks": [
          {"code": "a", "places": [{"rects": [[1, 2, 3, 4]]}, {"page": null}, {"page": "2"}, {"page": 1, "rects": [[5, 6, 7, 8]]}]},
          {"code": "b", "places": [{"page": 0, "rects": [[1, null, 3, 4], ["x", 2, 3, 4], "x", [10, 10, 20, 20]]}]},
          {"code": "c", "places": [{"page": 2, "rects": "x"}]}]}
        """
        let cs = try XCTUnwrap(try makeDecoder().decode(ChecksReply.self, from: Data(json.utf8)).checks)
        XCTAssertEqual(cs.map(\.code), ["a", "b", "c"])
        XCTAssertEqual(cs[0].places, [Check.Place(page: 1, rects: [[5, 6, 7, 8]])])
        XCTAssertEqual(cs[1].places, [Check.Place(page: 0, rects: [[10, 10, 20, 20]])])
        XCTAssertEqual(cs[2].places, [Check.Place(page: 2, rects: [])], "rects that are not a list: the page only")
    }

    // MARK: The tab

    /// A third tab beside the comments while Checks is on: its count, its page's groups and rows, its sentence.
    func testTheTab() throws {
        XCTAssertEqual(model.checks.phase, .ready)
        XCTAssertEqual(model.checks.tabTitle, "Checks 6")
        let shown = model.checks.items.map { item -> String in
            switch item.kind {
            case .message(let m): return "message: " + m
            case .group(let g): return "group: " + g
            case .check(let i): return "check \(i)"
            case .ok(let n): return "ok: \(n)"
            }
        }
        XCTAssertEqual(shown, ["group: References", "check 0", "group: Bibliography", "check 1", "group: Consistency", "check 2",
                               "group: Typesetting", "check 3", "group: Submission", "check 4", "check 5"])
        XCTAssertEqual(model.checks.sections.map(\.checks), [[0], [1], [2], [3], [4, 5]])
        XCTAssertTrue(model.checks.sentence.hasPrefix("Slips found"))
        XCTAssertEqual(model.sidebarRows.last, .contents(6), "nothing after the Contents in the sidebar")
        // no problems; asking
        model.setChecks([], round: 2)
        XCTAssertEqual(model.checks.items, [ChecksItem(kind: .message("No problems found"))])
        XCTAssertEqual(model.checks.tabTitle, "Checks")
        XCTAssertEqual(model.checks.sentence, "No problems found in this round’s PDF.")
        model.checks.ask("x")
        XCTAssertEqual(model.checks.items, [ChecksItem(kind: .message("Checking…"))])
        XCTAssertEqual(model.checks.sections.count, 0)
    }

    /// The Checks tab shown: no comment or change selected in the PDF; J and K step through its rows as clicks; Focus
    /// and the setting turned off go back to the Comments.
    func testTheTabsKeysAndLeaving() throws {
        model.tab = .checks
        XCTAssertNil(model.selection)
        XCTAssertNil(model.checks.current)
        model.move(1)
        XCTAssertEqual(model.checks.current, 0, "J: the first row")
        XCTAssertEqual(model.checks.cursor?.place, 0)
        model.move(1)
        XCTAssertEqual(model.checks.current, 1)
        model.move(-1)
        model.move(-1)
        XCTAssertEqual(model.checks.current, 0, "K stops at the first")
        model.checkClicked(5)  // no place: chosen all the same
        XCTAssertEqual(model.checks.current, 5)
        XCTAssertNil(model.checks.cursor)
        model.move(1)
        XCTAssertEqual(model.checks.current, 5, "J stops at the last")
        let closed = model.panel.showClosed
        model.toggleFold()
        XCTAssertEqual(model.panel.showClosed, closed, "no fold of a hidden tab's group")
        model.setFocus(true)
        XCTAssertEqual(model.tab, .comments, "Focus shows a card")
        model.setFocus(false)
        model.tab = .checks
        model.checksOn = false
        XCTAssertEqual(model.tab, .comments, "no Checks tab while off")
    }

    /// The tab comes back with Back and Forward, and with the last place, while Checks is on (review 2026-10-31: the
    /// place kept the tab but nothing read it); on it the toast sits at the panel's foot and a row's hover is dropped
    /// when the tab is left.
    func testTheTabComesBack() throws {
        let id = try XCTUnwrap(model.state?.comments.first?.id)
        model.tab = .checks
        model.showAllRounds()
        model.openReview(ReviewTarget(round: 2, comment: id))
        XCTAssertEqual(model.tab, .comments)
        model.goBack()
        XCTAssertEqual(model.level, .overview)
        model.goBack()
        XCTAssertEqual(model.level, .review)
        XCTAssertEqual(model.tab, .checks, "Back to Review as it was left: on the Checks")
        XCTAssertNil(model.selection)
        // a place's comment gone since: its tab all the same; Focus, which has no tabs, never gets the Checks
        model.tab = .comments
        model.reveal(ReviewTarget(round: 2, comment: "gone", tab: .checks))
        XCTAssertEqual(model.tab, .checks)
        model.tab = .comments
        model.setFocus(true)
        XCTAssertTrue(model.focus)
        model.reveal(ReviewTarget(round: 2, tab: .checks))
        XCTAssertEqual(model.tab, .comments, "not in Focus")
        model.setFocus(false)
        // the toast's place, and the hover
        model.tab = .comments
        model.actions.toastPlace.bottom = 56
        model.checks.hover(2, true)
        XCTAssertTrue(model.checks.look(2).hovering)
        model.checks.hover(3, true)
        XCTAssertFalse(model.checks.look(2).hovering, "one row at a time")
        model.checks.hover(2, false)
        XCTAssertEqual(model.checks.hovered, 3, "a late exit of another row changes nothing")
        model.tab = .checks
        XCTAssertEqual(model.actions.toastPlace.bottom, 16, "no list on the page: the panel's foot")
        XCTAssertNil(model.actions.toastPlace.below)
        XCTAssertEqual(model.checks.hovered, 3)
        model.tab = .comments
        XCTAssertNil(model.checks.hovered, "the hidden page's row gets no exit")
        XCTAssertFalse(model.checks.look(3).hovering)
        // the last place (a synthetic folder listed for it), on and off
        let folder = drafts.appendingPathComponent("paper")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("ledger.json"))
        model.papers.append(PaperRef(path: folder.path, title: "Paper", student: "Mei Lin"))
        XCTAssertTrue(model.openLastPlace(LastPlace(paper: folder.path, level: "review", round: 2, tab: "checks")))
        XCTAssertEqual(model.tab, .checks)
        model.checksOn = false
        XCTAssertEqual(model.tab, .comments)
        XCTAssertTrue(model.openLastPlace(LastPlace(paper: folder.path, level: "review", round: 2, tab: "checks")))
        XCTAssertEqual(model.tab, .comments, "no Checks tab while off")
    }

    /// Mark as OK (the advisor's double check, 2026-10-31): the row goes to the marked OK group, folded at first, out of
    /// the tab's count; J and K pass it while the group is folded; Mark as Not OK brings it back. The reply's `ok` and
    /// `key` decode; a test run keeps it here.
    func testMarkAsOK() throws {
        XCTAssertEqual(model.checks.list[0].key, "undefined_ref|" + model.checks.list[0].text, "the default key")
        XCTAssertFalse(model.checks.list[0].ok)
        XCTAssertEqual(model.checkMenu(2).first?.title, "Mark as OK")
        model.pickCheckMenu(2, .ok)
        XCTAssertTrue(model.checks.list[2].ok)
        XCTAssertEqual(model.checks.tabTitle, "Checks 5")
        XCTAssertEqual(model.checkMenu(2).first?.title, "Mark as Not OK")
        let shown = model.checks.items.map(\.kind)
        XCTAssertFalse(shown.contains(.group("Consistency")), "its group had only it")
        XCTAssertEqual(shown.last, .ok(1), "folded: the header only")
        XCTAssertFalse(model.checks.order.contains(2))
        model.tab = .checks
        model.move(1); model.move(1)
        XCTAssertEqual(model.checks.current, 1)
        model.move(1)
        XCTAssertEqual(model.checks.current, 3, "J passes the folded one")
        model.checks.showOK = true
        XCTAssertEqual(model.checks.items.suffix(2).map(\.kind), [.ok(1), .check(2)])
        XCTAssertEqual(model.checks.order.last, 2)
        model.markCheck(2, false)
        XCTAssertFalse(model.checks.list[2].ok)
        XCTAssertEqual(model.checks.tabTitle, "Checks 6")
        XCTAssertFalse(model.checks.items.contains { if case .ok = $0.kind { return true } else { return false } })
        // all marked OK
        for i in model.checks.list.indices { model.markCheck(i, true) }
        XCTAssertEqual(model.checks.tabTitle, "Checks")
        XCTAssertEqual(model.checks.sentence, "Every check of this round’s PDF is marked OK.")
        // decoded from the reply
        let json = #"{"round": 2, "checks": [{"code": "a", "text": "A", "key": "a|A", "ok": true}, {"code": "b", "ok": "x"}]}"#
        let cs = try XCTUnwrap(try makeDecoder().decode(ChecksReply.self, from: Data(json.utf8)).checks)
        XCTAssertEqual(cs.map(\.ok), [true, false], "a bad ok: not OK")
        XCTAssertEqual(cs.map(\.key), ["a|A", "b|b"])
    }

    /// After review 2026-10-31: J goes on from a row marked OK and folded away, not from the top; a row of the same key
    /// goes with it; a double click on the check mark marks one row; the hovered row's look is dropped as it moves.
    func testMarkAsOKKeepsThePlace() throws {
        model.tab = .checks
        model.checkClicked(1)
        model.markCheck(1, true)
        XCTAssertNil(model.checks.current, "folded away")
        model.move(1)
        XCTAssertEqual(model.checks.current, 2, "the row after it")
        model.markCheck(1, false)
        model.checkClicked(3)
        model.markCheck(3, true)
        model.move(-1)
        XCTAssertEqual(model.checks.current, 2, "K: the row before it")
        // two checks of one key (as the engine numbers repeats, this is a shared key on purpose)
        var cs = try XCTUnwrap(Self.reply().checks)
        cs.append(cs[3])
        model.setChecks(cs, round: 2)
        model.markCheck(3, true)
        XCTAssertTrue(model.checks.list[6].ok, "its key's other row too")
        model.markCheck(6, false)
        XCTAssertFalse(model.checks.list[3].ok)
        // a double click on the check mark: the second click is ignored
        model.markCheckClicked(0)
        model.markCheckClicked(1)
        XCTAssertTrue(model.checks.list[0].ok)
        XCTAssertFalse(model.checks.list[1].ok, "a double click's second click")
        // the hovered row's look goes as the row moves
        model.checks.hover(2, true)
        model.markCheck(2, true)
        XCTAssertNil(model.checks.hovered)
        XCTAssertFalse(model.checks.look(2).hovering)
    }

    /// The page's rows, hosted: a check's row has its menu.
    func testThePagesMenu() throws {
        let host = NSHostingView(rootView: ChecksPage().environmentObject(model).frame(width: 400, height: 900))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 900)
        let w = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = host
        defer { w.close() }
        spin(0.4)
        var titles: [String] = []
        for y in stride(from: 880.0, to: 20, by: -8) where titles.isEmpty {  // from the top down, the first row's menu
            let p = NSPoint(x: 200, y: y)
            let e = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: p, modifierFlags: [], timestamp: 0,
                                                     windowNumber: w.windowNumber, context: nil, eventNumber: 0,
                                                     clickCount: 1, pressure: 1))
            var v = w.contentView?.superview?.hitTest(p)
            while let view = v {
                if let found = view.menu(for: e) {
                    found.delegate?.menuNeedsUpdate?(found)
                    titles = found.items.filter { !$0.isSeparatorItem }.map(\.title)
                    break
                }
                v = view.superview
            }
        }
        XCTAssertEqual(titles, ["Mark as OK", "Comment…", "Keep Open", "Copy"])
    }

    // MARK: Clicks

    /// A click goes to the check's place, a look-up with a step of Back, and flashes it.
    func testAClickRevealsWithAStepOfBack() throws {
        XCTAssertEqual(steps, 0)
        model.checkClicked(3)  // the overfull line, p.3
        spin(0.4)
        XCTAssertEqual(at(3, 0).page, 2)
        XCTAssertTrue(at(3, 0).visible)
        XCTAssertTrue(model.pdf.flashing)
        XCTAssertEqual(steps, 1, "a step of Back")
        model.goBack()
        view.layoutDocumentView()
        XCTAssertEqual(model.pdf.shownPage, 0)
    }

    /// A second click on the same row goes to its next place, cycling; another row starts at its first.
    func testASecondClickCycles() throws {
        model.checkClicked(2)
        spin(0.4)
        XCTAssertEqual(at(2, 0).page, 1)
        XCTAssertTrue(at(2, 0).visible)
        model.checkClicked(2)
        spin(0.4)
        XCTAssertTrue(at(2, 1).visible, "its second place, p.3")
        XCTAssertEqual(model.checks.cursor?.place, 1)
        model.checkClicked(2)
        spin(0.4)
        XCTAssertEqual(model.checks.cursor?.place, 0, "back to its first")
        XCTAssertTrue(at(2, 0).visible)
        model.checkClicked(0)
        spin(0.4)
        XCTAssertEqual(model.checks.cursor?.check, 0)
        XCTAssertEqual(model.checks.cursor?.place, 0, "another row: its first place")
        XCTAssertTrue(at(0, 0).visible)
    }

    /// A place with a page only: the page's top at the view's top; no places: nothing.
    func testAPageOnlyPlaceAndNone() throws {
        top(of: 3)  // two pages away, so the look-up is a step of Back (PLAN §5.2: none when near)
        model.checkClicked(4)
        view.layoutDocumentView()
        XCTAssertEqual(model.pdf.pointAtThird()?.page, 1)
        XCTAssertLessThan(model.pdf.pointAtThird()?.y ?? 999, 300, "the page's top")
        XCTAssertEqual(model.pdf.shownPage, 1)
        XCTAssertEqual(steps, 1)
        model.checkClicked(5)
        view.layoutDocumentView()
        XCTAssertEqual(model.pdf.shownPage, 1, "no place: nothing")
        XCTAssertEqual(steps, 1)
        XCTAssertEqual(model.checks.current, 5, "the row chosen all the same")
        XCTAssertNil(model.checks.cursor)
    }

    /// The checks of another round than the one shown are never used.
    func testAnotherRoundsChecks() throws {
        model.setChecks(nil, round: 2)
        XCTAssertEqual(model.checks.phase, .hidden, "no checks: the group hidden")
        model.setChecks(try Self.reply().checks, round: 1)
        XCTAssertEqual(model.checks.phase, .hidden, "a reply for another round is dropped")
        model.setChecks(try Self.reply().checks, round: 2)
        XCTAssertEqual(model.checks.phase, .ready)
    }

    /// Another paper chosen: the shown paper's checks go at once, so its rows never stand under the next paper's row
    /// while its state is asked for, or for good when it cannot be read (review 2026-10-30).
    func testAnotherPaperDropsTheChecks() throws {
        XCTAssertEqual(model.checks.phase, .ready)
        model.selectPaper("/nonexistent/pc-checks-other-paper")
        XCTAssertNil(model.state)
        XCTAssertEqual(model.checks.phase, .hidden)
        XCTAssertTrue(model.checks.list.isEmpty)
        XCTAssertEqual(model.checkMenu(0), [], "no Copy of the other paper's check")
    }

    // MARK: The menu

    func testTheMenu() throws {
        XCTAssertEqual(titles(0), ["Comment…", "Keep Open", "Copy"])
        XCTAssertEqual(enabled(0), [true, true, true])
        XCTAssertEqual(enabled(4), [false, false, true], "a page only: no words to comment on or keep")
        XCTAssertEqual(enabled(5), [false, false, true], "no places")
        model.holdBusy(true)
        XCTAssertEqual(enabled(0), [false, true, true], "busy: no comment")
        model.holdBusy(false)
        // a closed round: Keep Open and Copy only
        let url = StepTests.fixtures.appendingPathComponent("state-reading.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var r = try XCTUnwrap(json["round"] as? [String: Any])
        r["closed"] = true
        json["round"] = r
        model.apply(try EngineState.decode(JSONSerialization.data(withJSONObject: json)))
        XCTAssertFalse(model.roundIsOpen)
        XCTAssertEqual(model.checks.phase, .ready, "the same round: kept")
        XCTAssertFalse(model.checks.canComment)
        XCTAssertEqual(enabled(0), [false, true, true])
    }

    /// Re-anchoring disables Comment…, and the rows' menus are told (`canComment`): a menu drawn before would offer an
    /// item that does nothing (review 2026-10-30).
    func testReanchoringRedrawsTheMenu() throws {
        XCTAssertTrue(model.checks.canComment)
        model.beginReanchor("R2-02")
        XCTAssertNotNil(model.toolbar.reanchor)
        XCTAssertEqual(enabled(0), [false, true, true])
        XCTAssertFalse(model.checks.canComment, "the menus drawn again without Comment…")
        model.leaveReanchor()
        XCTAssertEqual(enabled(0), [true, true, true])
        XCTAssertTrue(model.checks.canComment, "and again with it")
    }

    /// Comment… while a new comment's note is being written waits, as Comment on it… does (UX.md §8): the note's
    /// selection and the PDF stay where they are, and the toast says so (review 2026-10-30).
    func testCommentWaitsForAnUnsavedNote() throws {
        model.pickCheckMenu(0, .comment)
        spin(0.6)
        let d = try XCTUnwrap(model.pdf.draft)
        model.pdf.popover?.close()
        model.pdf.popover = ShownPopover()  // the window is not on screen: the editor stands as shown
        d.note = "Label the axes."
        let selected = view.currentSelection?.string
        let page = model.pdf.shownPage, back = steps
        model.pickCheckMenu(3, .comment)  // its place is on p.3
        spin(0.6)
        XCTAssertTrue(model.pdf.draft === d, "the same editor")
        XCTAssertEqual(d.note, "Label the axes.")
        XCTAssertEqual(view.currentSelection?.string, selected, "its words still selected")
        view.layoutDocumentView()
        XCTAssertEqual(model.pdf.shownPage, page, "the PDF where it was")
        XCTAssertEqual(steps, back, "no step of Back")
        XCTAssertEqual(model.reading.toast, "Your new comment on p.1 is not saved · click Save or Cancel in it first")
    }

    /// Comment…: the place's words selected, then the editor with the check's note.
    func testCommentStartsWithTheNote() throws {
        model.pickCheckMenu(0, .comment)
        spin(0.6)
        let d = try XCTUnwrap(model.pdf.draft, "the new-comment editor")
        XCTAssertEqual(d.mode, .text)
        XCTAssertEqual(d.note, "The reference to sec:model prints “??”: its \\label is missing.")
        XCTAssertFalse(d.changed, "the note as given: a click elsewhere may close it")
        XCTAssertEqual(PDFMenus.collapsed(view.currentSelection?.string ?? ""), "(Section 3).")
        XCTAssertEqual(d.page, 0)
        model.pdf.popover?.close()
        // a place with no words (a blank margin): a pending box round it
        let blank = Check(code: "x", group: "typesetting", text: "Blank", note: "Look here.",
                          places: [Check.Place(page: 0, rects: [[20, 600, 60, 640]])])
        model.setChecks([blank], round: 2)
        model.pickCheckMenu(0, .comment)
        spin(0.6)
        XCTAssertNotNil(model.pdf.pendingBox)
        XCTAssertEqual(model.pdf.draft?.mode, .box)
        XCTAssertEqual(model.pdf.draft?.note, "Look here.")
        model.pdf.popover?.close()
        model.pdf.dropPendingBox()
    }

    /// Keep Open: a kept window of the place, titled with the check's words.
    func testKeepOpen() throws {
        model.pickCheckMenu(1, .keepOpen)
        XCTAssertEqual(model.pdf.pinned.map(\.title), ["“SAND” prints as “Sand” · [2]"])
        model.pickCheckMenu(4, .keepOpen)
        XCTAssertEqual(model.pdf.pinned.count, 1, "a page only: nothing to keep")
        model.pdf.closePinned()
    }

    // MARK: Debug items

    /// checks, checkclick, checkmenu and setting checks (DebugScript.swift), in-process on this model.
    func testTheDebugItems() throws {
        let out = drafts.appendingPathComponent("debug.jsonl")
        try FileManager.default.createDirectory(at: drafts, withIntermediateDirectories: true)
        let script = DebugScript(spec: "checks; tab checks; checkclick 3; checkmenu 4; checkmenu 1 Keep Open; setting checks off",
                                 out: out.path, quit: false, controller: model.pdf)
        script.start()
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: out.path), Date() < deadline { spin(0.05) }
        let lines = try String(contentsOf: out, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        XCTAssertEqual(lines.count, 6)
        XCTAssertEqual(lines[0]["state"] as? String, "ready")
        XCTAssertEqual(lines[0]["tab"] as? String, "Checks 6")
        XCTAssertEqual(lines[0]["shown"] as? Bool, false)
        XCTAssertEqual(lines[0]["count"] as? Int, 6)
        let rows = try XCTUnwrap(lines[0]["rows"] as? [[String: Any]])
        XCTAssertEqual(rows[0]["code"] as? String, "undefined_ref")
        XCTAssertEqual(rows[0]["places"] as? Int, 2)
        XCTAssertEqual(rows[3]["page"] as? Int, 2)
        XCTAssertEqual((lines[0]["items"] as? [String])?.first, "group: References")
        XCTAssertEqual(lines[1]["tab"] as? String, "checks")
        XCTAssertEqual(lines[2]["shown"] as? Bool, true)
        XCTAssertEqual(lines[2]["current"] as? Int, 3)
        XCTAssertEqual(lines[2]["cursor"] as? [Int], [3, 0])
        XCTAssertNotNil(lines[2]["nav"] as? [String: Any])
        XCTAssertEqual(lines[3]["menu"] as? [[AnyHashable]],
                       [["Mark as OK", true], ["Comment…", false], ["Keep Open", false], ["Copy", true]])
        XCTAssertEqual(lines[4]["picked"] as? String, "Keep Open")
        XCTAssertEqual(lines[4]["pinned"] as? [String], ["“SAND” prints as “Sand” · [2]"])
        XCTAssertEqual(lines[5]["on"] as? Bool, false)
        XCTAssertEqual(lines[5]["state"] as? String, "hidden")
        XCTAssertTrue(lines[5]["tab"] is NSNull)
        XCTAssertEqual(lines[5]["shown"] as? Bool, false, "back on the Comments")
    }

    // MARK: The setting

    func testTheLaunchFlag() {
        XCTAssertEqual(LaunchOptions.parse(["app", "--checks", "on"]).checks, true)
        XCTAssertEqual(LaunchOptions.parse(["app", "--background", "--checks", "off"]).checks, false)
        XCTAssertNil(LaunchOptions.parse(["app", "--background"]).checks)
    }

    /// Off by default: nothing shown and nothing taken; on shows what is set; off again drops the rows. A test run never
    /// saves the setting, and never asks the engine.
    func testOffHidesAndAsksNothing() throws {
        let saved = UserDefaults.standard.object(forKey: AppModel.checksKey) as? Bool
        let m = makeModel(checks: nil)
        XCTAssertFalse(m.checksOn, "off by default")
        m.setChecks(try Self.reply().checks, round: 2)
        XCTAssertEqual(m.checks.phase, .hidden, "nothing while off")
        m.checksOn = true
        XCTAssertEqual(m.checks.phase, .hidden, "a test run asks nothing")
        m.setChecks(try Self.reply().checks, round: 2)
        XCTAssertEqual(m.checks.list.count, 6)
        m.checksOn = false
        XCTAssertEqual(m.checks.phase, .hidden)
        XCTAssertTrue(m.checks.list.isEmpty)
        m.checkClicked(0)
        XCTAssertNil(m.checks.cursor)
        XCTAssertEqual(UserDefaults.standard.object(forKey: AppModel.checksKey) as? Bool, saved, "never saved by a test run")
    }
}

/// A popover that counts as shown, for an editor in a window that is not on screen.
private final class ShownPopover: NSPopover {
    override var isShown: Bool { true }
}
