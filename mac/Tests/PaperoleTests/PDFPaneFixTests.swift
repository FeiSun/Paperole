import AppKit
import PDFKit
import SwiftUI
import XCTest
@testable import Paperole

/// The PDF pane's fixes of the code review of 2026-10-24 (batch B8), on the open round 2 fixture.
@MainActor
final class PDFPaneFixTests: XCTestCase {
    private var drafts: URL!

    override func setUpWithError() throws {
        drafts = FileManager.default.temporaryDirectory.appendingPathComponent("pc-pdfpane-drafts-" + UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: drafts)
    }

    private func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    private func makeModel() -> AppModel {
        _ = NSApplication.shared
        var o = LaunchOptions()
        o.fixture = StepTests.fixtures.appendingPathComponent("state-round2.json").path
        o.drafts = drafts.path
        let m = AppModel(options: o)
        XCTAssertTrue(m.roundIsOpen)
        return m
    }

    private func makeWindow(height: CGFloat) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: height), styleMask: [.titled],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        return w
    }

    /// A PDF view in the window, attached to the model's controller; `load`: its round's PDF shown, as PDFPane does.
    private func addView(_ model: AppModel, to window: NSWindow, load: Bool = true) -> ReviewPDFView {
        let v = ReviewPDFView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(v)
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displaysPageBreaks = true
        model.pdf.attach(v)
        if load { self.load(model, v) }
        return v
    }

    private func load(_ model: AppModel, _ v: ReviewPDFView) {
        model.pdf.update(url: model.pdfURL, key: MarkKey(version: model.stateVersion, showChanges: model.showChanges))
        v.layoutDocumentView()
    }

    private func clip(_ v: PDFView) -> NSClipView { v.documentView!.enclosingScrollView!.contentView }

    /// The clip view's origin with page `i`'s top at the view's top.
    private func origin(atTopOf i: Int, in v: PDFView) -> NSPoint {
        let c = clip(v), page = v.document!.page(at: i)!
        let r = c.convert(v.convert(page.bounds(for: .cropBox), from: page), from: v)
        var b = c.bounds
        b.origin.y = c.isFlipped ? r.minY : r.maxY - b.height
        return c.constrainBoundsRect(b).origin
    }

    /// How far below the view's top the point `y` points down page `i` is (negative: above it, out of view); by default
    /// the page's top.
    private func pageTop(_ i: Int, y: CGFloat = 0, in v: PDFView) -> CGFloat {
        let page = v.document!.page(at: i)!, cb = page.bounds(for: .cropBox)
        return v.bounds.maxY - v.convert(CGPoint(x: cb.midX, y: cb.maxY - y), from: page).y
    }

    // MARK: A2-01 (M10): the floating toolbar after a new PDF view

    func testTheToolbarShowsInANewPDFView() throws {
        let model = makeModel()
        let window = makeWindow(height: 700)
        defer { window.close() }
        func select(in v: ReviewPDFView) throws {
            let page = try XCTUnwrap(v.document?.page(at: 0)), cb = page.bounds(for: .cropBox)
            v.setCurrentSelection(page.selection(from: CGPoint(x: cb.minX + 150, y: cb.maxY - 337),
                                                 to: CGPoint(x: cb.minX + 400, y: cb.maxY - 360)), animate: false)
            XCTAssertFalse((v.currentSelection?.string ?? "").isEmpty)
        }
        let first = addView(model, to: window)
        try select(in: first)
        model.pdf.showToolbar()
        XCTAssertTrue(model.pdf.toolbarShown)
        XCTAssertTrue(model.pdf.toolbarView?.superview === first)
        // another paper, or Review again after the hub: PDFPane makes a new view, and the old one leaves the window
        model.pdf.hideToolbar()
        first.removeFromSuperview()
        XCTAssertFalse(model.pdf.toolbarShown)
        let second = addView(model, to: window, load: false)
        second.document = PDFDocument(url: try XCTUnwrap(model.pdfURL))
        second.layoutDocumentView()
        try select(in: second)
        model.pdf.showToolbar()
        XCTAssertTrue(model.pdf.toolbarView?.superview === second, "the toolbar moves into the new view")
        XCTAssertNotNil(model.pdf.toolbarView?.window)
        XCTAssertTrue(model.pdf.toolbarShown)
        // shown only in the window: a toolbar left in a view that went is not shown
        second.removeFromSuperview()
        XCTAssertFalse(model.pdf.toolbarShown)
    }

    // MARK: A2-02 (M11): a scroll still animating does not undo the next one

    func testARevealOfAMarkInViewEndsAScrollStillRunning() throws {
        let model = makeModel()
        let window = makeWindow(height: 500)
        defer { window.close() }
        let v = addView(model, to: window)
        spin(0.6)  // opened at the top of p.1
        model.pdf.place(page: 0, rect: [0, 0, 0, 0], fromTop: 0)
        let sv = try XCTUnwrap(v.documentView?.enclosingScrollView)
        // the last J's reveal: on its way to the last page
        ScrollAnimator.scroll(sv, to: origin(atTopOf: v.document!.pageCount - 1, in: v), duration: 0.25)
        // this J's mark: near the top of p.1, in view now
        let mark: [[Double]] = [[72, 100, 300, 110]]
        XCTAssertTrue(model.pdf.isVisible(page: 0, rects: mark))
        model.pdf.reveal(page: 0, rects: mark)
        XCTAssertFalse(ScrollAnimator.isRunning(sv))
        spin(0.5)
        XCTAssertTrue(model.pdf.isVisible(page: 0, rects: mark), "the old scroll did not carry the view on")
    }

    func testAFarRevealIsNotCarriedBack() throws {
        let model = makeModel()
        let window = makeWindow(height: 500)
        defer { window.close() }
        let v = addView(model, to: window)
        spin(0.6)  // opened at the top of p.1
        model.pdf.place(page: 0, rect: [0, 0, 0, 0], fromTop: 0)
        let sv = try XCTUnwrap(v.documentView?.enclosingScrollView), c = clip(v)
        var b = c.bounds
        b.origin.y += c.isFlipped ? 120 : -120
        ScrollAnimator.scroll(sv, to: c.constrainBoundsRect(b).origin, duration: 0.25)  // a short reveal on p.1
        // the next mark is on the last page: too far to animate to (go(to:))
        let last = v.document!.pageCount - 1, mark: [[Double]] = [[72, 400, 300, 410]]
        model.pdf.reveal(page: last, rects: mark)
        spin(0.5)
        XCTAssertTrue(model.pdf.isVisible(page: last, rects: mark))
    }

    func testAContentsClickEndsAScrollStillRunning() throws {
        let model = makeModel()
        let window = makeWindow(height: 500)
        defer { window.close() }
        let v = addView(model, to: window)
        spin(0.6)  // opened at the top of p.1
        let sv = try XCTUnwrap(v.documentView?.enclosingScrollView)
        ScrollAnimator.scroll(sv, to: origin(atTopOf: v.document!.pageCount - 1, in: v), duration: 0.25)
        model.pdf.place(page: 0, rect: [0, 0, 0, 0], fromTop: 0)  // the title row (AppModel.outlineOpen)
        spin(0.5)
        XCTAssertEqual(pageTop(0, in: v), 0, accuracy: 1)
    }

    // MARK: A2-03: ⌥ off the page

    func testOptionClickAndDragBetweenPagesPlaceNothing() throws {
        let model = makeModel()
        let window = makeWindow(height: 900)
        defer { window.close() }
        let v = addView(model, to: window)
        let doc = try XCTUnwrap(v.document)
        model.pdf.place(page: 0, rect: [0, 700, 0, 700], fromTop: 100)  // the end of p.1 and the gap below it in view
        v.layoutDocumentView()
        let p0 = try XCTUnwrap(doc.page(at: 0)), p1 = try XCTUnwrap(doc.page(at: 1))
        let cb0 = p0.bounds(for: .cropBox), cb1 = p1.bounds(for: .cropBox)
        let bottom0 = v.convert(CGPoint(x: cb0.midX, y: cb0.minY), from: p0), top1 = v.convert(CGPoint(x: cb1.midX, y: cb1.maxY), from: p1)
        let gap = CGPoint(x: bottom0.x, y: (bottom0.y + top1.y) / 2)
        XCTAssertGreaterThan(bottom0.y - top1.y, 2, "a gap between the pages")
        XCTAssertNil(v.page(for: gap, nearest: false), "between the pages")
        let onPage = v.convert(CGPoint(x: cb1.minX + 300, y: cb1.maxY - 200), from: p1)

        func send(from a: CGPoint, to b: CGPoint) {
            while NSApp.nextEvent(matching: .any, until: nil, inMode: .default, dequeue: true) != nil {}
            let w1 = v.convert(a, to: nil), w2 = v.convert(b, to: nil)
            func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: p, modifierFlags: .option, timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            if a != b {
                for i in 1...6 {
                    let t = CGFloat(i) / 6
                    NSApp.postEvent(event(.leftMouseDragged, CGPoint(x: w1.x + (w2.x - w1.x) * t, y: w1.y + (w2.y - w1.y) * t)),
                                    atStart: false)
                }
            }
            NSApp.postEvent(event(.leftMouseUp, w2), atStart: false)
            window.contentView?.superview?.hitTest(w1)?.mouseDown(with: event(.leftMouseDown, w1))
        }
        // a ⌥-drag from the gap onto the page: no box (it lay partly outside the page), no selection
        send(from: gap, to: onPage)
        XCTAssertNil(model.pdf.pendingBox)
        XCTAssertTrue((v.currentSelection?.string ?? "").isEmpty)
        // a ⌥-click in the gap: no note
        send(from: gap, to: gap)
        XCTAssertNil(model.pdf.draft)
        XCTAssertNil(model.pdf.popover)
        // the same drag from the page makes its box
        send(from: v.convert(CGPoint(x: cb1.minX + 100, y: cb1.maxY - 60), from: p1), to: onPage)
        let box = try XCTUnwrap(model.pdf.pendingBox)
        XCTAssertTrue(box.page === p1)
        XCTAssertTrue(cb1.contains(box.rect))
        model.pdf.dropPendingBox()
    }

    // MARK: A2-05: a right-click leaves no word selected

    /// The app builds the menu itself (design/pdf-reader/PLAN.md §3), so no word is selected for it at all (PDFView's
    /// own selected the nearest one, which the fix cleared once the menu closed); a selection made before stays.
    func testARightClickSelectsNoWord() throws {
        let model = makeModel()
        let window = makeWindow(height: 900)
        defer { window.close() }
        let v = addView(model, to: window)
        let page = try XCTUnwrap(v.document?.page(at: 0)), cb = page.bounds(for: .cropBox)
        v.go(to: PDFDestination(page: page, at: CGPoint(x: cb.minX, y: cb.maxY - 300)))
        v.layoutDocumentView()
        func rightClick(_ x: Double, _ y: Double) -> NSMenu? {
            let w = v.convert(v.convert(CGPoint(x: cb.minX + x, y: cb.maxY - y), from: page), to: nil)
            let e = NSEvent.mouseEvent(with: .rightMouseDown, location: w, modifierFlags: [], timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            return v.menu(for: e)
        }
        v.clearSelection()
        let menu = try XCTUnwrap(rightClick(300, 337))  // on a word of the intro
        XCTAssertEqual(menu.items.first?.title, "Add Note Here")
        XCTAssertTrue((v.currentSelection?.string ?? "").isEmpty)
        XCTAssertFalse(model.hasPDFSelection)
        let sel = try XCTUnwrap(page.selection(from: CGPoint(x: cb.minX + 150, y: cb.maxY - 337), to: CGPoint(x: cb.minX + 400, y: cb.maxY - 360)))
        v.setCurrentSelection(sel, animate: false)
        let before = v.currentSelection?.string
        XCTAssertEqual(try XCTUnwrap(rightClick(300, 337)).items.first?.title, "Comment…")
        XCTAssertEqual(v.currentSelection?.string, before)
    }

    // MARK: UI-01 (M12): a PDF opens at the top of its first page

    func testAPDFOpensAtTheTopOfItsFirstPage() throws {
        let model = makeModel()
        let window = makeWindow(height: 500)
        defer { window.close() }
        let v = addView(model, to: window)
        // the re-zoom after the panes settled left the page about 155 pt down (UI review 2026-10-24)
        let c = clip(v)
        var b = c.bounds
        b.origin.y += c.isFlipped ? 155 : -155
        c.scroll(to: c.constrainBoundsRect(b).origin)
        XCTAssertLessThan(pageTop(0, in: v), -100)
        spin(0.8)  // the view settled (0.15 s), then settled again
        XCTAssertEqual(pageTop(0, in: v), 0, accuracy: 1, "the running head and title in view")
    }

    func testARevealWaitingForThePDFStillWins() throws {
        let model = makeModel()
        let window = makeWindow(height: 500)
        defer { window.close() }
        let v = addView(model, to: window, load: false)
        let mark: [[Double]] = [[72, 400, 300, 410]]
        model.pdf.reveal(page: 2, rects: mark)  // a comment selected before its PDF is shown: kept for the load
        load(model, v)
        spin(1.0)
        XCTAssertTrue(model.pdf.isVisible(page: 2, rects: mark), "the reveal, not the top of p.1")
    }

    func testAScrollToAnotherPageRightAfterTheLoadStays() throws {
        let model = makeModel()
        let window = makeWindow(height: 500)
        defer { window.close() }
        let v = addView(model, to: window)
        let last = v.document!.pageCount - 1
        ScrollAnimator.scroll(try XCTUnwrap(v.documentView?.enclosingScrollView), to: origin(atTopOf: last, in: v), duration: 0.1)
        spin(0.8)
        XCTAssertEqual(model.pdf.shownPage, last, "not taken back to p.1")
    }

    func testAContentsClickRightAfterTheLoadStays() throws {
        let model = makeModel()
        let window = makeWindow(height: 500)
        defer { window.close() }
        let v = addView(model, to: window)
        model.pdf.place(page: 1, rect: [72, 200, 300, 210], fromTop: 16)  // a heading's row
        spin(0.8)
        XCTAssertEqual(pageTop(1, y: 200, in: v), 16, accuracy: 1, "not the top of p.1")
    }
}

// MARK: A2-06: Jump's list follows ↑ and ↓

@MainActor
final class JumpScrollTests: XCTestCase {
    private func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    private func sources() -> Jump.Sources {
        var s = Jump.Sources()
        s.rounds = (1...3).map { RoundSummary(n: $0, created: nil, source: nil, closed: $0 < 3, closedAt: nil, status: "ok", pdf: nil) }
        s.commands = Jump.Command.allCases.map { .init(command: $0, title: "Command \($0.rawValue)", icon: "circle") }
        return s
    }

    func testKeysAndNewQueriesAskForTheRowHoverDoesNot() {
        let j = JumpModel()
        j.sources = sources
        j.open()
        let r = j.reveals
        j.move(1)
        XCTAssertEqual(j.highlighted, 1)
        XCTAssertEqual(j.reveals, r + 1)
        j.highlighted = 4  // the pointer over a row
        XCTAssertEqual(j.reveals, r + 1, "a hover does not scroll the list")
        j.setQuery("command")
        XCTAssertEqual(j.highlighted, 0)
        XCTAssertEqual(j.reveals, r + 2, "a new query shows its first row")
    }

    func testTheHighlightedRowStaysInView() throws {
        _ = NSApplication.shared
        var o = LaunchOptions()
        o.fixture = StepTests.fixtures.appendingPathComponent("state-round2.json").path
        o.drafts = FileManager.default.temporaryDirectory.appendingPathComponent("pc-jump-drafts-" + UUID().uuidString).path
        let model = AppModel(options: o)
        let j = JumpModel()
        j.sources = sources
        j.open()
        XCTAssertEqual(j.rows.count, 11, "3 rounds and 8 commands: 454 pt of rows")
        let host = NSHostingView(rootView: JumpPanel(jump: j, model: model))
        host.frame = NSRect(x: 0, y: 0, width: 620, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        spin(0.3)
        func all<T: NSView>(_ type: T.Type, in v: NSView) -> [T] { ((v as? T).map { [$0] } ?? []) + v.subviews.flatMap { all(type, in: $0) } }
        let list = try XCTUnwrap(all(NSScrollView.self, in: host).max { $0.frame.height < $1.frame.height })
        func inView(_ i: Int) throws -> Bool {
            let f = try XCTUnwrap(j.frames[i])  // the window's SwiftUI coordinates: y down from the top
            let shown = list.convert(list.contentView.bounds, to: nil)
            let row = CGRect(x: f.minX, y: host.bounds.height - f.maxY, width: f.width, height: f.height)
            return shown.insetBy(dx: -1, dy: -1).contains(row)
        }
        XCTAssertTrue(try inView(0))
        let last = j.rows.count - 1
        XCTAssertFalse(try inView(last), "the list is longer than its 380 pt")
        for _ in 0..<last {
            j.move(1)
            spin(0.05)
        }
        XCTAssertEqual(j.highlighted, last)
        spin(0.3)
        XCTAssertTrue(try inView(last), "↓ brought the last row into view")
        j.move(1)  // wraps to the first
        spin(0.3)
        XCTAssertEqual(j.highlighted, 0)
        XCTAssertTrue(try inView(0))
    }
}

// MARK: A2-07: R on a tall card scrolled past its end

final class TallCardEndTests: XCTestCase {
    func testAnEndAboveTheViewIsBroughtBack() {
        // the card's end 200 pt above the panel's top: its end 16 pt above the bottom
        XCTAssertEqual(ScrollDecision.decide(minY: -1500, maxY: -200, viewport: 800, mode: .end),
                       ScrollDecision(delta: -984, animated: true))
        XCTAssertEqual(ScrollDecision.decide(minY: -1500, maxY: 10, viewport: 800, mode: .end)?.delta, -774)
        XCTAssertNil(ScrollDecision.decide(minY: -1500, maxY: 16, viewport: 800, mode: .end), "its end in view")
        XCTAssertEqual(ScrollDecision.decide(minY: -4000, maxY: -2000, viewport: 800, mode: .end)?.animated, false, "far: at once")
    }
}

// MARK: A2-09: the crops keep few PDFs open

final class CropCacheOpenTests: XCTestCase {
    func testAtMostFourPDFsStayOpen() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-crops-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = try (1...6).map { n -> String in
            let url = dir.appendingPathComponent("r\(n).pdf")
            var box = CGRect(x: 0, y: 0, width: 200, height: 100)
            let ctx = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
            ctx.beginPDFPage(nil)
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 20, y: 40, width: 60, height: 10))
            ctx.endPDFPage()
            ctx.closePDF()
            return url.path
        }
        let cache = CropCache()
        let style = CropStyle(look: .paper, dark: false, density: 1, ink: .black)
        func crop(_ i: Int, _ y: Double = 40) async -> NSImage? {
            await cache.image(CropRequest(round: i + 1, pdf: paths[i], page: 0, rects: [[20, y, 80, y + 10]], textX: nil), style).image
        }
        for i in 0..<6 {
            let img = await crop(i)
            XCTAssertNotNil(img)
        }
        XCTAssertEqual(CropCache.openLimit, 4)
        XCTAssertEqual(cache.openPaths, Array(paths[2...5]), "the last four used")
        // a crop of one still open makes it the last used; a crop of one dropped opens it again
        _ = await crop(2, 50)
        XCTAssertEqual(cache.openPaths, [paths[3], paths[4], paths[5], paths[2]])
        let again = await crop(0, 50)
        XCTAssertNotNil(again)
        XCTAssertEqual(cache.openPaths, [paths[4], paths[5], paths[2], paths[0]])
    }
}
