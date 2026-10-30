import AppKit
import PDFKit
import XCTest
@testable import Paperole

/// The way back (design/pdf-reader/PLAN.md §5): which jumps record a step, the history's steps (folded on leaving
/// Review, 20 a visit), and Back, the chip and the page's menu in a PDF view. Synthetic fixtures only.
final class PDFStepRulesTests: XCTestCase {
    private func at(_ page: Int, _ y: Double = 100) -> PDFPlace { PDFPlace(page: page, x: 300, y: y, zoom: nil, label: "p.\(page + 1)") }

    func testALookUpRecordsWhereItLeavesUnlessNear() {
        var s = PDFSteps()
        XCTAssertNil(s.jump(.lookUp, from: at(0), near: { _ in true }), "a target in view, or less than a view away")
        XCTAssertEqual(s.jump(.lookUp, from: at(0), near: { _ in false }), at(0))
        XCTAssertEqual(s.jump(.lookUp, from: at(3), near: { _ in false }), at(3), "each look-up records its own")
    }

    func testARunRecordsOneStepWhereItBegan() {
        var s = PDFSteps()
        XCTAssertNil(s.jump(.run, from: at(0), near: { _ in true }), "the first card is near")
        // the third card is far from where the run began, though near the second
        XCTAssertEqual(s.jump(.run, from: at(1), near: { $0 != at(0) }), at(0), "the place your own reading left off")
        XCTAssertNil(s.jump(.run, from: at(2), near: { _ in false }), "the run has its step")
        XCTAssertNil(s.jump(.run, from: at(3), near: { _ in false }))
        s.ownMove()  // a scroll of your own
        XCTAssertEqual(s.jump(.run, from: at(4), near: { _ in false }), at(4), "a new run")
        XCTAssertEqual(s.jump(.lookUp, from: at(5), near: { _ in false }), at(5))
        XCTAssertEqual(s.jump(.run, from: at(6), near: { _ in false }), at(6), "a look-up ends the run")
    }

    func testFindsNextMatchesGoWithItsFirst() {
        var s = PDFSteps()
        XCTAssertEqual(s.jump(.find, from: at(4), near: { _ in false }), at(4), "the first match: a look-up")
        XCTAssertNil(s.jump(.run, from: at(0), near: { _ in false }), "Return, or typing on, to a far match: no second step")
        var n = PDFSteps()
        XCTAssertNil(n.jump(.find, from: at(4), near: { _ in true }), "a first match near")
        XCTAssertEqual(n.jump(.run, from: at(4, 300), near: { $0 != at(4) }), at(4), "then a far one: where reading left off")
    }

    func testNearMeansInViewOrLessThanAViewAway() {
        let v = CGRect(x: 0, y: 1000, width: 600, height: 800)
        XCTAssertTrue(PDFSteps.isNear(CGRect(x: 0, y: 1200, width: 100, height: 10), visible: v))
        XCTAssertTrue(PDFSteps.isNear(CGRect(x: 0, y: 2500, width: 100, height: 10), visible: v), "700 below")
        XCTAssertFalse(PDFSteps.isNear(CGRect(x: 0, y: 2600, width: 100, height: 10), visible: v), "800 below")
        XCTAssertTrue(PDFSteps.isNear(CGRect(x: 0, y: 300, width: 100, height: 10), visible: v), "690 above")
        XCTAssertFalse(PDFSteps.isNear(CGRect(x: 0, y: 100, width: 100, height: 10), visible: v))
    }

    func testBacksFlashTakesTheNearestLine() {
        let lines = [CGRect(x: 72, y: 500, width: 200, height: 10), CGRect(x: 320, y: 498, width: 200, height: 10),
                     CGRect(x: 72, y: 480, width: 450, height: 10)]
        XCTAssertEqual(PDFSteps.line(at: CGPoint(x: 300, y: 504), in: lines), lines[1], "level with it, then the nearer across")
        XCTAssertEqual(PDFSteps.line(at: CGPoint(x: 100, y: 504), in: lines), lines[0])
        XCTAssertEqual(PDFSteps.line(at: CGPoint(x: 300, y: 486), in: lines), lines[2])
        XCTAssertNil(PDFSteps.line(at: CGPoint(x: 300, y: 300), in: lines), "a figure: no line")
    }
}

final class NavStepTests: XCTestCase {
    private func review(_ paper: String, page: Int? = nil) -> NavPlace {
        NavPlace(paper: paper, level: .review,
                 review: ReviewPlace(pdf: page.map { PDFPlace(page: $0, x: 300, y: 100, zoom: nil, label: "p.\($0 + 1)") }))
    }

    func testStepsAreCappedAtTwentyAVisit() {
        var h = NavHistory()
        h.push(NavPlace(paper: "/a", level: .overview))
        for i in 0..<25 { h.pushStep(review("/a", page: i)) }
        XCTAssertEqual(h.back.count, 1 + NavHistory.stepLimit)
        XCTAssertEqual(h.back[1].review.pdf?.page, 5, "the oldest went first")
        XCTAssertEqual(h.back.last?.review.pdf?.page, 24)
        XCTAssertTrue(h.back.dropFirst().allSatisfy(\.step))
        XCTAssertEqual(h.back.first?.level, .overview, "the window's place stays")
    }

    func testLeavingReviewFoldsItsSteps() {
        var h = NavHistory()
        h.push(NavPlace(paper: "/a", level: .overview))
        h.pushStep(review("/a", page: 1))
        h.pushStep(review("/a", page: 4))
        h.fold(paper: "/a")
        h.push(review("/a", page: 7))  // the Review step, with the PDF's place
        XCTAssertEqual(h.back.map(\.level), [.overview, .review])
        XCTAssertFalse(h.back[1].step)
        XCTAssertEqual(h.back[1].review.pdf?.page, 7)
    }

    func testBackBetweenStepsKeepsThemSteps() {
        var h = NavHistory()
        h.push(NavPlace(paper: "/a", level: .overview))
        h.pushStep(review("/a", page: 1))
        let p = h.goBack(from: review("/a", page: 6))
        XCTAssertEqual(p?.review.pdf?.page, 1)
        XCTAssertEqual(h.forward.last?.step, true, "the place left is a step of the visit too")
        var g2 = h
        g2.fold(paper: "/a")  // another round shown
        XCTAssertTrue(g2.forward.isEmpty, "a fold takes the forward steps too")
        XCTAssertEqual(h.goBack(from: review("/a", page: 1))?.level, .overview)
        XCTAssertEqual(h.forward.map(\.step), [true, false], "Review left for the overview: its Review step")
        // a place of another paper is never a step
        var g = NavHistory()
        g.push(review("/b"))
        _ = g.goBack(from: review("/a", page: 2))
        XCTAssertEqual(g.forward.last?.step, false)
    }

    /// Two Review places of one paper that are not steps (a paper removed from between them) are two visits: Back
    /// from one keeps it whole for Forward.
    func testTwoVisitsOfOnePapersReviewAreNoSteps() {
        var h = NavHistory()
        h.push(review("/a", page: 1))
        h.push(review("/b"))
        h.remove(paper: "/b")
        XCTAssertEqual(h.back.map(\.step), [false])
        _ = h.goBack(from: review("/a", page: 6))
        XCTAssertEqual(h.forward.last?.step, false)
        h.fold(paper: "/a")
        XCTAssertEqual(h.forward.count, 1, "a fold leaves it")
    }

    /// A double click on the row of the paper in Review: its first click's fold and push are taken back, the steps too.
    func testADoubleClicksFirstClickKeepsTheSteps() {
        var h = NavHistory()
        h.push(NavPlace(paper: "/a", level: .overview))
        h.pushStep(review("/a", page: 1))
        h.pushStep(review("/a", page: 4))
        h.fold(paper: "/a")
        h.push(review("/a", page: 7))
        h.dropLast { $0.paper == "/a" && $0.level == .review }
        XCTAssertEqual(h.back.map { $0.review.pdf?.page }, [nil, 1, 4])
        XCTAssertTrue(h.back.dropFirst().allSatisfy(\.step))
    }
}

/// Back in a PDF view, on the round 2 fixture with its reading (hyperref's links, sections on four pages).
@MainActor
final class BackFlowTests: XCTestCase {
    private var drafts: URL!
    private var window: NSWindow!
    private var model: AppModel!
    private var view: ReviewPDFView!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        drafts = FileManager.default.temporaryDirectory.appendingPathComponent("pc-back-drafts-" + UUID().uuidString)
        var o = LaunchOptions()
        o.fixture = StepTests.fixtures.appendingPathComponent("state-reading.json").path
        o.drafts = drafts.path
        model = AppModel(options: o)
        XCTAssertEqual(model.level, .review)
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
        show(page: 0, y: 300)
    }

    override func tearDownWithError() throws {
        window.close()
        try? FileManager.default.removeItem(at: drafts)
    }

    private func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    private func page(_ i: Int) -> PDFPage { view.document!.page(at: i)! }

    private func point(_ x: Double, _ y: Double, on i: Int = 0) -> CGPoint {
        let cb = page(i).bounds(for: .cropBox)
        return CGPoint(x: cb.minX + x, y: cb.maxY - y)
    }

    /// The page scrolled so contract y `y` is near the view's top.
    private func show(page i: Int, y: Double) {
        view.go(to: PDFDestination(page: page(i), at: point(0, y - 20, on: i)))
        view.layoutDocumentView()
        model.pdf.ownMove()
    }

    /// A click at a contract point of page 0, as the mouse sends it.
    private func click(_ x: Double, _ y: Double) {
        while NSApp.nextEvent(matching: .any, until: nil, inMode: .default, dequeue: true) != nil {}
        let w = view.convert(view.convert(point(x, y), from: page(0)), to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: w, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        NSApp.postEvent(event(.leftMouseUp), atStart: false)
        window.contentView?.superview?.hitTest(w)?.mouseDown(with: event(.leftMouseDown))
        view.layoutDocumentView()
    }

    /// Runs the main loop until the find has its matches (at most 5 s).
    private func settle(_ find: PaperFind) {
        let deadline = Date().addingTimeInterval(5)
        repeat { spin(0.02) } while find.isSearching && Date() < deadline
        XCTAssertFalse(find.isSearching, "the search came in")
        spin(0.05)
    }

    private var steps: [String?] { model.navHistory.back.map { $0.step ? $0.review.pdf?.label : nil } }

    /// A citation's link: the app goes there (p.4), the place left is a step, the chip and the help tag name it; Back
    /// puts the place back a third of the way down and flashes its line; the chip goes; Forward goes there again.
    func testALinkClickIsAStepAndBackReturns() throws {
        let left = try XCTUnwrap(model.pdf.currentPlace())
        XCTAssertTrue(left.label.hasPrefix("p.1 · "), left.label)
        click(95, 347)  // cite.jonas2019cloud
        XCTAssertEqual(model.pdf.shownPage, 3)
        XCTAssertEqual(steps, [left.label])
        XCTAssertEqual(model.pdf.backChip.label, left.label)
        XCTAssertFalse(model.pdf.backChip.faded)
        XCTAssertEqual(model.backLabel, left.label)
        model.goBack()
        view.layoutDocumentView()
        let back = try XCTUnwrap(model.pdf.currentPlace())
        XCTAssertEqual(back.page, 0)
        XCTAssertEqual(back.y, left.y, accuracy: 1)
        XCTAssertTrue(model.pdf.flashing, "the line left flashes")
        XCTAssertNil(model.pdf.backChip.label)
        XCTAssertEqual(steps, [])
        XCTAssertTrue(model.navHistory.forward.last?.step == true)
        XCTAssertTrue(model.forwardLabel?.hasPrefix("p.4") == true)
        model.goForward()
        view.layoutDocumentView()
        XCTAssertEqual(model.pdf.shownPage, 3)
        XCTAssertEqual(steps, [left.label])
    }

    /// The link menu's Go to is the same look-up; the page's menu then offers Back first.
    func testGoToAndThePagesBack() throws {
        let w = view.convert(view.convert(point(95, 347), from: page(0)), to: nil)
        func menu(at p: CGPoint) -> NSMenu? {
            view.menu(for: NSEvent.mouseEvent(with: .rightMouseDown, location: p, modifierFlags: [], timestamp: 0,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
        let m = try XCTUnwrap(menu(at: w))
        m.performActionForItem(at: 0)
        view.layoutDocumentView()
        XCTAssertEqual(model.pdf.shownPage, 3)
        XCTAssertEqual(steps.count, 1)
        let page3 = view.convert(view.convert(point(300, 20, on: 3), from: page(3)), to: nil)
        let items = try XCTUnwrap(menu(at: page3)).items
        XCTAssertEqual(items.first?.title, "Back to " + (steps[0] ?? ""))
        XCTAssertTrue(items.dropFirst().first?.isSeparatorItem == true)
    }

    /// A jump to a target in view, or less than a view away, records nothing (and moves nothing here).
    func testANearTargetIsNoStep() {
        model.select(.comment("R1-02"))  // p.1, in view
        model.pdf.reveal(page: 0, rects: [[72, 700, 200, 710]], step: .lookUp)
        XCTAssertEqual(steps, [])
        XCTAssertNil(model.pdf.backChip.label)
    }

    /// Cards in a row (a click, J/K) are one run: one step, where reading left off, so Back skips the cards.
    func testARunThroughTheCardsIsOneStep() throws {
        show(page: 0, y: 20)
        let left = try XCTUnwrap(model.pdf.currentPlace())
        for id in ["R1-07", "R2-01", "R1-04"] {  // p.2, p.3, p.3
            model.select(.comment(id))
            view.layoutDocumentView()
        }
        spin(0.4)  // the animated reveals end
        XCTAssertEqual(steps, [left.label])
        XCTAssertEqual(model.pdf.backChip.label, left.label, "the chip stays through the run")
        model.move(1)  // J
        spin(0.1)
        XCTAssertEqual(steps.count, 1)
        let card = model.selectedComment?.id
        model.goBack()
        view.layoutDocumentView()
        XCTAssertEqual(model.pdf.currentPlace()?.page, 0)
        XCTAssertEqual(model.pdf.currentPlace()?.y ?? 0, left.y, accuracy: 1)
        XCTAssertEqual(model.selectedComment?.id, card, "Back moves the PDF only; the card stays")
    }

    /// Contents (a look-up) records; its Back returns.
    func testAContentsJumpAndBack() throws {
        let left = try XCTUnwrap(model.pdf.currentPlace())
        model.outlineOpen(33)  // 5 Conclusion, p.3
        view.layoutDocumentView()
        XCTAssertEqual(model.pdf.shownPage, 2)
        XCTAssertEqual(steps, [left.label])
        model.goBack()
        view.layoutDocumentView()
        XCTAssertEqual(model.pdf.currentPlace()?.page, 0)
    }

    /// Leaving Review folds its steps into the Review step, which keeps the PDF's place: Back into Review is there.
    func testLeavingReviewFoldsTheSteps() throws {
        click(95, 347)
        model.outlineOpen(2)  // 1 Introduction, p.1
        view.layoutDocumentView()
        XCTAssertEqual(steps.count, 2)
        let here = try XCTUnwrap(model.pdf.currentPlace())
        model.showAllRounds()
        XCTAssertEqual(model.level, .overview)
        XCTAssertEqual(steps, [nil], "one place: Review, no steps")
        XCTAssertEqual(model.navHistory.back.last?.review.pdf?.page, here.page)
        model.goBack()
        view.layoutDocumentView()
        XCTAssertEqual(model.level, .review)
        XCTAssertEqual(model.pdf.currentPlace()?.page, here.page)
        XCTAssertEqual(model.pdf.currentPlace()?.y ?? 0, here.y, accuracy: 1)
    }

    /// Find's first match records where reading left off; Return to a far match, and typing on to one, record no step
    /// of their own: the chip follows, and one Back returns.
    func testFindsNextMatchesGoWithItsFirst() throws {
        show(page: 3, y: 700)  // the paper's end: no "Catalyzer" below
        let left = try XCTUnwrap(model.pdf.currentPlace())
        let find = model.pdf.find
        find.find("Catalyzer", fromStart: true)  // p.1, Related Work
        settle(find)
        XCTAssertEqual(model.pdf.shownPage, 0)
        XCTAssertEqual(steps, [left.label])
        find.step(previous: false)  // Return: p.4's, in the references
        view.layoutDocumentView()
        spin(0.4)
        XCTAssertEqual(model.pdf.shownPage, 3)
        XCTAssertEqual(steps, [left.label], "no step at the first match")
        XCTAssertEqual(model.pdf.backChip.label, left.label, "the chip follows the find")
        model.goBack()
        view.layoutDocumentView()
        XCTAssertEqual(model.pdf.currentPlace()?.page, 3, "one Back: where reading left off")
        XCTAssertEqual(steps, [])
        find.find("Catalyzer", fromStart: true)
        settle(find)
        XCTAssertEqual(model.pdf.shownPage, 0)
        XCTAssertEqual(steps.count, 1)
        find.type("Catalyzer:")  // only the reference's, on p.4
        settle(find)
        view.layoutDocumentView()
        XCTAssertEqual(model.pdf.shownPage, 3)
        XCTAssertEqual(steps.count, 1, "typing on adds no step at the match it left")
        XCTAssertFalse(steps[0]?.hasPrefix("p.1") ?? true)
    }

    /// Jump's find from the overview opens Review, a window step already: its first match records none.
    func testJumpsFindFromTheOverviewIsNoStep() throws {
        show(page: 3, y: 700)
        model.showAllRounds()
        model.jumpTo(.find("Firecracker"))  // p.1 only
        settle(model.pdf.find)
        view.layoutDocumentView()
        XCTAssertEqual(model.level, .review)
        XCTAssertEqual(model.pdf.shownPage, 0)
        XCTAssertFalse(model.navHistory.back.contains(where: \.step))
        XCTAssertEqual(model.navHistory.back.last?.level, .overview, "Back goes to the overview")
        XCTAssertNil(model.pdf.backChip.label)
    }

    /// The chip stays while you read near where the jump landed, and goes after a scroll of more than two views.
    func testTheChipGoesAfterAScrollOfMoreThanTwoViews() throws {
        click(95, 347)
        XCTAssertNotNil(model.pdf.backChip.label)
        show(page: 3, y: 300)  // less than two views
        XCTAssertNotNil(model.pdf.backChip.label)
        show(page: 0, y: 20)
        spin(0.05)
        XCTAssertNil(model.pdf.backChip.label)
        XCTAssertEqual(steps.count, 1, "Back still goes there")
    }

    /// A mouse's side buttons are ‹ and ›, in the review's window only.
    func testTheSideButtons() throws {
        click(95, 347)
        func side(_ n: Int64) -> NSEvent { DebugScript.sideButton(n, in: window)! }
        XCTAssertFalse(model.sideButton(side(3)), "not the review's window")
        QuitOnClose.install(on: window) {}
        XCTAssertFalse(model.sideButton(side(2)), "the middle button is not Back")
        XCTAssertTrue(model.sideButton(side(3)))
        view.layoutDocumentView()
        XCTAssertEqual(model.pdf.shownPage, 0)
        XCTAssertTrue(model.sideButton(side(4)))
        view.layoutDocumentView()
        XCTAssertEqual(model.pdf.shownPage, 3)
    }
}
