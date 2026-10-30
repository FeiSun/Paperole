import AppKit
import PDFKit
import XCTest
@testable import Paperole

/// Drags are sent the way the app's --debug-drag sends them: PDFView tracks a drag inside mouseDown, so the drags and
/// the mouse-up are queued before the mouse-down is delivered to the view under the point.
@MainActor
final class SelectionTests: XCTestCase {
    static let pdf = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/round2/main.pdf")

    var window: NSWindow!
    var view: ReviewPDFView!
    var page: PDFPage!

    override func setUp() async throws {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 900), styleMask: [.titled],
                          backing: .buffered, defer: false)
        view = ReviewPDFView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(view)
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(data: try Data(contentsOf: Self.pdf))
        page = try XCTUnwrap(view.document?.page(at: 0))
        view.layoutDocumentView()
        view.go(to: PDFDestination(page: page, at: CGPoint(x: 0, y: page.bounds(for: .cropBox).maxY - 300)))
    }

    /// Contract point (top-left origin) to PDFKit page space.
    private func pagePoint(_ x: Double, _ y: Double) -> CGPoint {
        let cb = page.bounds(for: .cropBox)
        return CGPoint(x: cb.minX + x, y: cb.maxY - y)
    }

    private func drag(from a: CGPoint, to b: CGPoint, modifiers: NSEvent.ModifierFlags = []) {
        // A mouse-up left over from an earlier drag would end this one at once.
        while NSApp.nextEvent(matching: .any, until: nil, inMode: .default, dequeue: true) != nil {}
        let w1 = view.convert(view.convert(a, from: page), to: nil), w2 = view.convert(view.convert(b, from: page), to: nil)
        func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        for i in 1...6 {
            let t = CGFloat(i) / 6
            NSApp.postEvent(event(.leftMouseDragged, CGPoint(x: w1.x + (w2.x - w1.x) * t, y: w1.y + (w2.y - w1.y) * t)), atStart: false)
        }
        NSApp.postEvent(event(.leftMouseUp, w2), atStart: false)
        let target = window.contentView?.superview?.hitTest(w1)
        XCTAssertNotNil(target)
        target?.mouseDown(with: event(.leftMouseDown, w1))
    }

    /// Clicks `count` times at a point; PDFView tracks a click inside mouseDown too, so each mouse-up is queued first.
    private func click(at a: CGPoint, count: Int = 1, modifiers: NSEvent.ModifierFlags = []) {
        while NSApp.nextEvent(matching: .any, until: nil, inMode: .default, dequeue: true) != nil {}
        let w = view.convert(view.convert(a, from: page), to: nil)
        for n in 1...count {
            func event(_ type: NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: w, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: n, pressure: 1)!
            }
            NSApp.postEvent(event(.leftMouseUp), atStart: false)
            window.contentView?.superview?.hitTest(w)?.mouseDown(with: event(.leftMouseDown))
        }
    }

    func testMarginPointsGoToTheLineStart() throws {
        // Abstract lines: "keep finished …" 233.4–242.4 and "and still misses …" 244.4–253.4 (contract y).
        for y in [234.5, 238.0, 242.0, 243.0] {
            let p = Geometry.clampedPoint(pagePoint(20, y), on: page, textX: [72, 540])
            XCTAssertEqual(p.x, 97.4, accuracy: 0.5, "y = \(y)")
            XCTAssertEqual(page.selection(from: p, to: pagePoint(300, 260))?.string?.hasPrefix("keep finished"), true)
        }
        XCTAssertGreaterThan(Geometry.lines(on: page, textX: [72, 540]).count, 40)
        XCTAssertEqual(Geometry.lines(on: page, textX: nil), [])
    }

    func testDragFromTheMarginStartsAtTheLineStart() throws {
        view.textX = [[72, 540]]
        view.go(to: PDFDestination(page: page, at: pagePoint(0, 170)))
        drag(from: pagePoint(20, 235), to: pagePoint(300, 260))
        let expected = try XCTUnwrap(page.selection(from: pagePoint(97.2, 238), to: pagePoint(300, 260))?.string)
        XCTAssertTrue(expected.hasPrefix("keep finished"))
        XCTAssertEqual(view.currentSelection?.string, expected)
    }

    func testDragEndingRightOfAShortLineEndsOnIt() throws {
        // "one." (72–89.7) ends a paragraph; PDFKit alone ends this drag on the line above, or selects nothing.
        let a = pagePoint(300, 432)
        XCTAssertNotEqual(page.selection(from: a, to: pagePoint(580, 444))?.string?.hasSuffix("one."), true)
        let expected = try XCTUnwrap(page.selection(from: a, to: pagePoint(89.2, 443.8))?.string)
        XCTAssertTrue(expected.hasSuffix("receives only\none."))
        view.textX = [[72, 540]]
        for x in [100.0, 300, 580] {
            drag(from: a, to: pagePoint(x, 444))
            XCTAssertEqual(view.currentSelection?.string, expected, "x = \(x)")
        }
    }

    func testClickWithoutADragClearsTheSelection() {
        view.textX = [[72, 540]]
        view.setCurrentSelection(page.selection(from: pagePoint(150, 337), to: pagePoint(400, 360)), animate: false)
        click(at: pagePoint(300, 349))
        XCTAssertNil(view.currentSelection)
    }

    func testClickBesideALinkDoesNotFollowIt() throws {
        // A link "[x]" ends the line at 601.6–610.0 (531.3–538.2); its line end is where the clamp puts a point.
        view.textX = [[72, 540]]
        click(at: pagePoint(575, 606))
        XCTAssertEqual(view.currentPage, page)
        drag(from: pagePoint(300, 594), to: pagePoint(575, 606))
        let s = try XCTUnwrap(view.currentSelection?.string)
        XCTAssertTrue(s.hasSuffix("from a checkpoint. SAND [2]"), s)
        XCTAssertEqual(s, page.selection(from: pagePoint(300, 594), to: pagePoint(539.5, 605.8))?.string)
        XCTAssertEqual(view.currentPage, page)
    }

    func testClickOnALinkFollowsIt() throws {
        view.textX = [[72, 540]]
        let c = PDFController()  // the app goes there itself (design/pdf-reader/PLAN.md §5), not PDFView
        c.attach(view)
        click(at: pagePoint(534.7, 605.8))
        XCTAssertEqual(view.currentPage, try XCTUnwrap(view.document?.page(at: 3)))
    }

    func testDoubleAndTripleClicksGoToPDFView() {
        view.textX = [[72, 540]]
        click(at: pagePoint(300, 349), count: 2)
        let word = view.currentSelection?.string ?? ""
        XCTAssertFalse(word.isEmpty)
        XCTAssertFalse(word.contains(" "))
        click(at: pagePoint(300, 349), count: 3)
        XCTAssertGreaterThan(view.currentSelection?.string?.count ?? 0, 60)
    }

    func testDragBelowTheViewScrolls() throws {
        while NSApp.nextEvent(matching: .any, until: nil, inMode: .default, dequeue: true) != nil {}
        let before = try XCTUnwrap(view.documentView?.visibleRect)
        let w1 = view.convert(view.convert(pagePoint(150, 400), from: page), to: nil), w2 = CGPoint(x: w1.x, y: -60)
        func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        for _ in 1...3 { NSApp.postEvent(event(.leftMouseDragged, w2), atStart: false) }
        NSApp.postEvent(event(.leftMouseUp, w2), atStart: false)
        window.contentView?.superview?.hitTest(w1)?.mouseDown(with: event(.leftMouseDown, w1))
        XCTAssertNotEqual(view.documentView?.visibleRect.origin.y, before.origin.y)
        XCTAssertGreaterThan(view.currentSelection?.string?.count ?? 0, 0)
    }

    func testShiftClickExtendsFromTheSelectionStart() throws {
        view.textX = [[72, 540]]
        let a = pagePoint(150, 337)
        view.setCurrentSelection(page.selection(from: a, to: pagePoint(400, 349)), animate: false)
        click(at: pagePoint(200, 372), modifiers: .shift)
        XCTAssertEqual(view.currentSelection?.string, try XCTUnwrap(page.selection(from: a, to: pagePoint(200, 372))?.string))
        // backwards, to the left margin of the same line: from the line's start to the end of the selection
        let end = try XCTUnwrap(view.currentSelection?.string)
        click(at: pagePoint(20, 336), modifiers: .shift)
        let s = try XCTUnwrap(view.currentSelection?.string)
        XCTAssertTrue(s.hasPrefix("Function-as-a-Service (FaaS) lets"), s)
        XCTAssertTrue(s.hasSuffix(end), s)
    }

    func testDragInsideTheCurrentSelectionStartsANewOne() throws {
        // Intro paragraph: from mid line 2 to mid line 4, then a drag on line 2 left of the selection (inside its
        // bounding box, not on selected text).
        let first = try XCTUnwrap(page.selection(from: pagePoint(300, 349), to: pagePoint(200, 372)))
        view.setCurrentSelection(first, animate: false)
        let a = pagePoint(100, 349), b = pagePoint(180, 349)
        drag(from: a, to: b)
        let expected = try XCTUnwrap(page.selection(from: a, to: b)?.string)
        XCTAssertFalse(expected.isEmpty)
        XCTAssertEqual(view.currentSelection?.string, expected)
    }

    func testDragOnUnmarkedTextMatchesPDFKit() throws {
        let a = pagePoint(150, 337), b = pagePoint(400, 360)
        drag(from: a, to: b)
        XCTAssertEqual(view.currentSelection?.string, page.selection(from: a, to: b)?.string)
    }

    /// The app's menu follows what was selected before the click (PDFView's own selected the word under it).
    func testContextMenuFollowsTheSelectionBeforeTheClick() throws {
        var options = LaunchOptions()
        options.fixture = Self.pdf.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("state-round2.json").path
        let model = AppModel(options: options)
        XCTAssertTrue(model.roundIsOpen)
        model.pdf.attach(view)
        func firstItem(at x: Double, _ y: Double) -> String? {
            let w = view.convert(view.convert(pagePoint(x, y), from: page), to: nil)
            let e = NSEvent.mouseEvent(with: .rightMouseDown, location: w, modifierFlags: [], timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            return view.menu(for: e)?.items.first?.title
        }
        view.clearSelection()
        XCTAssertEqual(firstItem(at: 300, 337), "Add Note Here")  // on a word of the intro
        view.setCurrentSelection(page.selection(from: pagePoint(150, 337), to: pagePoint(400, 360)), animate: false)
        XCTAssertEqual(firstItem(at: 300, 337), "Comment…")
    }

    func testDebugLaunchOptions() {
        let o = LaunchOptions.parse(["app", "--debug-drag", "0,1,2,3,4", "--debug-out", "/tmp/x", "--debug-marks", "off"])
        XCTAssertEqual(o.script, "0,1,2,3,4")  // --debug-drag is --debug-script's M1 name
        XCTAssertEqual(o.debugOut, "/tmp/x")
        XCTAssertFalse(o.marks)
        XCTAssertFalse(o.quit)
        XCTAssertTrue(LaunchOptions.parse(["app"]).marks)
        let s = LaunchOptions.parse(["app", "--debug-script", "click 0,1,2;dump", "--debug-quit", "--debug-scroll-perf", "keys",
                                     "--fixture", "f.json"])
        XCTAssertEqual(s.script, "click 0,1,2;dump")
        XCTAssertTrue(s.quit)
        XCTAssertEqual(s.scrollPerf, "keys")
        XCTAssertEqual(s.fixture, "f.json")
    }
}
