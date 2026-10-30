import AppKit
import PDFKit
import XCTest
@testable import Paperole

/// The PDF's right-click menu by target and its zoom (design/pdf-reader/PLAN.md §3, §3.6), on the open round 2 fixture
/// (its PDF has hyperref's links).
@MainActor
final class PDFMenuTests: XCTestCase {
    private var drafts: URL!
    private var window: NSWindow!
    private var model: AppModel!
    private var view: ReviewPDFView!
    private var page: PDFPage!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        drafts = FileManager.default.temporaryDirectory.appendingPathComponent("pc-pdfmenu-drafts-" + UUID().uuidString)
        var o = LaunchOptions()
        o.fixture = StepTests.fixtures.appendingPathComponent("state-round2.json").path
        o.drafts = drafts.path
        model = AppModel(options: o)
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
        page = try XCTUnwrap(view.document?.page(at: 0))
        show(y: 300)
    }

    override func tearDownWithError() throws {
        window.close()
        try? FileManager.default.removeItem(at: drafts)
    }

    private func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    private func point(_ x: Double, _ y: Double, on p: PDFPage? = nil) -> CGPoint {
        let cb = (p ?? page).bounds(for: .cropBox)
        return CGPoint(x: cb.minX + x, y: cb.maxY - y)
    }

    /// Page 0 scrolled so contract y `y` is near the view's top.
    private func show(y: Double) {
        view.go(to: PDFDestination(page: page, at: point(0, y - 20)))
        view.layoutDocumentView()
    }

    /// The menu of a right-click at a contract point of page 0: its titles, "—" for a separator, "✓ " before one on.
    private func menu(_ x: Double, _ y: Double, page index: Int = 0) -> [String] {
        let p = view.document!.page(at: index)!
        let w = view.convert(view.convert(point(x, y, on: p), from: p), to: nil)
        let e = NSEvent.mouseEvent(with: .rightMouseDown, location: w, modifierFlags: [], timestamp: 0,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        return (view.menu(for: e)?.items ?? []).map { $0.isSeparatorItem ? "—" : ($0.state == .on ? "✓ " : "") + $0.title }
    }

    private static let stock = ["Zoom In", "Zoom Out", "Actual Size", "Automatically Resize", "Single Page", "Two Pages",
                                "Next Page", "Previous Page", "Search with Google", "Translate", "Look Up"]

    // MARK: The menu by target (PLAN §3)

    func testOnThePage() throws {
        view.clearSelection()
        let titles = menu(300, 337)  // on a word of the intro
        XCTAssertEqual(titles.prefix(3), ["Add Note Here", "Draw a Box", "—"])
        XCTAssertTrue(titles[3].hasPrefix("Look Up “"), "\(titles)")
        XCTAssertEqual(titles.last, "Set p.1 as Key Page")
        XCTAssertFalse(titles.contains { Self.stock.contains($0) }, "none of PDFKit's items: \(titles)")
        XCTAssertTrue((view.currentSelection?.string ?? "").isEmpty, "a right-click selects no word")
        // in the margin, over no word: no Look Up
        XCTAssertEqual(menu(20, 337), ["Add Note Here", "Draw a Box", "—", "Set p.1 as Key Page"])
        // a closed round's page, or while the engine works: only what does not write
        model.holdBusy(true)
        XCTAssertEqual(menu(20, 337), ["Set p.1 as Key Page"])
        model.holdBusy(false)
    }

    func testOnTheSelection() throws {
        let sel = try XCTUnwrap(page.selection(from: point(150, 337), to: point(400, 360)))
        view.setCurrentSelection(sel, animate: false)
        let titles = menu(300, 337)
        XCTAssertEqual(titles.prefix(5), ["Comment…", "Strike Out", "Replace With…", "—", "Copy"])
        XCTAssertTrue(titles[5].hasPrefix("Find “") && titles[5].hasSuffix("” in Paper"), "\(titles)")
        XCTAssertEqual(titles.count, 6, "no Look Up for several words: \(titles)")
        XCTAssertEqual(view.currentSelection?.string, sel.string, "the selection stays")
        // a right-click away from the selection is on the page
        XCTAssertEqual(menu(20, 600).first, "Add Note Here")
        // one word: Look Up too
        let word = try XCTUnwrap(page.selectionForWord(at: point(300, 342)))
        view.setCurrentSelection(word, animate: false)
        let one = menu(300, 342)
        XCTAssertEqual(one.last, "Look Up “\(PDFMenus.oneWord(word.string ?? "") ?? "")”")
    }

    /// Review: the mark's items were built (and its comment selected) even when the selection's won, which cleared the
    /// selection; Comment…, Strike Out and Replace With… then found nothing to act on.
    func testASelectionOverAMarkStays() throws {
        show(y: 450)
        let sel = try XCTUnwrap(page.selection(from: point(150, 467), to: point(300, 467)))  // inside R2-02's highlight
        view.setCurrentSelection(sel, animate: false)
        let before = model.selection
        XCTAssertEqual(menu(200, 467).prefix(3), ["Comment…", "Strike Out", "Replace With…"])
        XCTAssertEqual(view.currentSelection?.string, sel.string, "the selection stays")
        XCTAssertEqual(model.selection, before, "no comment selected")
        XCTAssertNotNil(model.pdf.selectionAnchor(), "Strike Out has its words")
    }

    func testOnAMark() throws {
        // a new comment of the open round: the right-click selects it, then the card's ⋯ items that can act
        show(y: 450)
        view.setCurrentSelection(page.selection(from: point(150, 337), to: point(400, 360)), animate: false)
        let titles = menu(200, 467)  // R2-02's highlight
        XCTAssertEqual(model.selection, .comment("R2-02"))
        XCTAssertTrue((view.currentSelection?.string ?? "").isEmpty, "the selection elsewhere goes, as on a click")
        XCTAssertEqual(titles.prefix(4), ["Edit Note", "Colour", "Kind", "Tags"])
        XCTAssertTrue(titles.contains("Delete…"))
        XCTAssertFalse(titles.contains("Resolve"))
        XCTAssertFalse(titles.contains("Reopen in Round 2"), "greyed or absent items are left out")
        // a carried comment to check: the answers first
        show(y: 580)
        let carried = menu(500, 594)  // R1-06
        XCTAssertEqual(model.selection, .comment("R1-06"))
        XCTAssertEqual(carried.prefix(4), ["Resolve", "Follow Up…", "Keep as Is", "—"])
        XCTAssertFalse(carried.contains("Delete…"), "a carried comment cannot be deleted: \(carried)")
        // one followed up: its answer is checked
        show(y: 650)
        XCTAssertEqual(menu(450, 665).prefix(3), ["Resolve", "✓ Follow Up…", "Keep as Is"])  // R1-02
    }

    func testOtherCommentsWhereMarksOverlap() throws {
        model.apply(try overlapping())
        model.pdf.update(url: model.pdfURL, key: MarkKey(version: model.stateVersion, showChanges: true))
        show(y: 450)
        let w = view.convert(view.convert(point(200, 467), from: page), to: nil)
        let e = NSEvent.mouseEvent(with: .rightMouseDown, location: w, modifierFlags: [], timestamp: 0,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let m = try XCTUnwrap(view.menu(for: e))
        let other = try XCTUnwrap(m.items.last?.submenu, "\(m.items.map(\.title))")
        XCTAssertEqual(m.items.last?.title, "Other Comments Here")
        let selected = try XCTUnwrap(model.selectedComment?.id)
        XCTAssertEqual(other.items.count, 1)
        XCTAssertTrue(other.items[0].title.hasPrefix(selected == "R2-02" ? "R2-09" : "R2-02"), other.items[0].title)
        other.performActionForItem(at: 0)
        XCTAssertNotEqual(model.selectedComment?.id, selected, "the other one selected")
    }

    /// The fixture with a second comment on R2-02's words.
    private func overlapping() throws -> EngineState {
        let url = StepTests.fixtures.appendingPathComponent("state-round2.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var comments = json["comments"] as? [[String: Any]] ?? []
        var c = try XCTUnwrap(comments.first { $0["id"] as? String == "R2-02" })
        c["id"] = "R2-09"
        c["note"] = "A second note on the same words."
        comments.append(c)
        json["comments"] = comments
        return try EngineState.decode(JSONSerialization.data(withJSONObject: json))
    }

    func testOnAChangeBand() throws {
        // c06's band, just under its words on p.3 (no comment there; under a comment's mark the mark wins, as a click)
        let p2 = try XCTUnwrap(view.document?.page(at: 2))
        view.go(to: PDFDestination(page: p2, at: point(0, 500, on: p2)))
        view.layoutDocumentView()
        let titles = menu(300, 582, page: 2)
        XCTAssertEqual(titles, ["Mark Checked", "Comment on It…"])
        XCTAssertEqual(model.selection, .change("c06"))
        XCTAssertEqual(model.tab, .changes)
    }

    /// Review: on the Changes tab a right-click on changed words under a comment's mark went to the comment; as a click,
    /// the change comes first there, the comment on the Comments tab.
    func testOnAChangeUnderAMark() throws {
        show(y: 650)
        model.tab = .changes
        XCTAssertEqual(menu(500, 666), ["Mark Checked", "Comment on It…"])  // c02, under R1-02's highlight
        XCTAssertEqual(model.selection, .change("c02"))
        model.tab = .comments
        XCTAssertEqual(menu(500, 666).prefix(3), ["Resolve", "✓ Follow Up…", "Keep as Is"])
        XCTAssertEqual(model.selection, .comment("R1-02"))
    }

    /// Decision 3: an answer from the mark's menu moves nothing on, nor does the choice row it asks for (a draft there).
    func testAnAnswerFromTheMenuAsksToStay() throws {
        show(y: 580)
        model.setDraft("R1-06", "half typed")
        let w = view.convert(view.convert(point(500, 594), from: page), to: nil)
        let e = NSEvent.mouseEvent(with: .rightMouseDown, location: w, modifierFlags: [], timestamp: 0,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let m = try XCTUnwrap(view.menu(for: e))
        XCTAssertEqual(m.items.first?.title, "Resolve")
        m.performActionForItem(at: 0)
        XCTAssertEqual(model.edit.choice?.id, "R1-06")
        XCTAssertEqual(model.edit.choice?.advance, false)
        model.choose(.cancel)
        model.press("verified", for: "R1-06")  // from the card: its answer moves on, as before
        XCTAssertEqual(model.edit.choice?.advance, true)
        model.choose(.cancel)
    }

    func testOnALink() throws {
        let links = (0..<view.document!.pageCount).flatMap { view.document!.page(at: $0)!.annotations.filter { $0.type == "Link" } }
        XCTAssertEqual(links.count, 19)
        let titles = menu(95, 347)  // cite.jonas2019cloud, whose entry is on p.4
        XCTAssertEqual(titles.first, "Go to p.4")
        XCTAssertEqual(titles.dropFirst().first, "—")
        XCTAssertTrue(titles.last?.hasPrefix("Comment on “") == true && titles.last?.hasSuffix("”…") == true, "\(titles)")
        XCTAssertEqual(titles.count, 3)
        // Go to goes there
        let w = view.convert(view.convert(point(95, 347), from: page), to: nil)
        let e = NSEvent.mouseEvent(with: .rightMouseDown, location: w, modifierFlags: [], timestamp: 0,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let m = try XCTUnwrap(view.menu(for: e))
        m.performActionForItem(at: 0)
        view.layoutDocumentView()
        XCTAssertEqual(model.pdf.shownPage, 3)
    }

    /// hyperref's boxes go (this fixture's have none; the synthetic paper's are 1 pt green and red), in memory.
    func testLinkBoxesHidden() throws {
        let doc = try XCTUnwrap(PDFDocument(url: SelectionTests.pdf))
        let links = (0..<doc.pageCount).flatMap { doc.page(at: $0)!.annotations.filter { $0.type == "Link" } }
        for a in links {
            let b = PDFBorder()
            b.lineWidth = 1
            a.border = b
        }
        PDFController.hideLinkBoxes(doc)
        XCTAssertTrue(links.allSatisfy { $0.border?.lineWidth == 0 && $0.shouldDisplay })
    }

    /// A hidden link box still acts: a click on the link goes there (PDFView's own handling).
    func testAHiddenLinkStillGoes() throws {
        while NSApp.nextEvent(matching: .any, until: nil, inMode: .default, dequeue: true) != nil {}
        let w = view.convert(view.convert(point(95, 347), from: page), to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: w, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        NSApp.postEvent(event(.leftMouseUp), atStart: false)
        window.contentView?.superview?.hitTest(w)?.mouseDown(with: event(.leftMouseDown))
        spin(0.3)
        view.layoutDocumentView()
        XCTAssertEqual(model.pdf.shownPage, 3)
    }

    func testTheWords() {
        XCTAssertEqual(PDFMenus.replaceNote("  were\n"), "Replace with “were”.")
        XCTAssertEqual(PDFMenus.replaceNote(" "), "")
        XCTAssertEqual(PDFMenus.oneWord(" gauge, "), "gauge")
        XCTAssertNil(PDFMenus.oneWord("two words"))
        XCTAssertNil(PDFMenus.oneWord(" . "))
        XCTAssertEqual(PDFMenus.short("cold starts"), "cold starts")
        XCTAssertEqual(PDFMenus.short("the keep-alive window of a function, in minutes"), "the keep-alive window of…")
        XCTAssertEqual(PDFMenus.collapsed(" a\n b  c "), "a b c")
    }

    /// The card's ⋯ menu gives only the items that can act, in its groups.
    func testActionableItems() {
        let m = NSMenu()
        m.autoenablesItems = false
        let on = NSMenuItem(title: "A", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        let off = NSMenuItem(title: "B", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        off.isEnabled = false
        let sub = NSMenuItem(title: "C", action: nil, keyEquivalent: "")
        sub.submenu = NSMenu()
        sub.submenu?.addItem(off.copy() as! NSMenuItem)
        let d = NSMenuItem(title: "D", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        [on, off, sub, .separator(), .separator(), d].forEach(m.addItem)
        XCTAssertEqual(PDFMenus.actionable(m).map { $0.map(\.title) }, [["A"], ["D"]])
        XCTAssertTrue(m.items.isEmpty)
    }

    // MARK: Zoom (PLAN §3.6)

    func testZoomSteps() {
        // from Fit Width at 1.1: the steps round it, Fit Width itself one of them
        XCTAssertEqual(ZoomRules.step(from: 1.1, fit: 1.1, up: true), 1.25)
        XCTAssertEqual(ZoomRules.step(from: 1.1, fit: 1.1, up: false), 1)
        XCTAssertNil(ZoomRules.step(from: 1.25, fit: 1.1, up: false), "back to Fit Width")
        XCTAssertNil(ZoomRules.step(from: 1, fit: 1.1, up: true))
        XCTAssertEqual(ZoomRules.step(from: 1.5, fit: 1.1, up: true), 1.75)
        XCTAssertEqual(ZoomRules.step(from: 4, fit: 1.1, up: true), 4, "the end")
        XCTAssertEqual(ZoomRules.step(from: 0.5, fit: 1.1, up: false), 0.5)
        XCTAssertEqual(ZoomRules.step(from: 1.3, fit: 1.1, up: true), 1.5, "from a ⌘-scroll's zoom")
        XCTAssertEqual(ZoomRules.step(from: 1.3, fit: 1.1, up: false), 1.25)
        XCTAssertEqual(ZoomRules.clamped(9), 4)
        XCTAssertEqual(ZoomRules.label(1.25), "125%")
        XCTAssertEqual(ZoomRules.menu.map(ZoomRules.label), ["100%", "125%", "150%", "175%", "200%"])
    }

    func testZoomKeepsTheThirdAndFocusMultipliesIt() throws {
        let fit = view.scaleFactor
        XCTAssertTrue(view.autoScales)
        XCTAssertNil(model.pdf.position.zoom, "Fit Width: no zoom in the status line")
        let third = try XCTUnwrap(model.pdf.pointAtThird())
        model.pdf.setZoom(1.5)
        XCTAssertFalse(view.autoScales)
        XCTAssertEqual(view.scaleFactor, 1.5, accuracy: 0.001)
        XCTAssertEqual(model.pdf.position.zoom, 1.5)
        let now = try XCTUnwrap(model.pdf.pointAtThird())
        XCTAssertEqual(now.page, third.page)
        XCTAssertEqual(now.y, third.y, accuracy: 1, "the place a third of the way down stays")
        XCTAssertEqual(now.x, third.x, accuracy: 1)
        // Zoom In and Out step from there; Out past Fit Width's scale lands on Fit Width
        model.pdf.zoomStep(in: true)
        XCTAssertEqual(view.scaleFactor, 1.75, accuracy: 0.001)
        model.pdf.setZoom(try XCTUnwrap(ZoomRules.steps.first { $0 > fit * 1.01 }))  // the first step above Fit Width
        model.pdf.zoomStep(in: false)
        XCTAssertTrue(view.autoScales)
        XCTAssertNil(model.pdf.position.zoom)
        XCTAssertEqual(view.scaleFactor, fit, accuracy: 0.001)
        // Focus: 1.3 times the zoom, not capped at the view's width; leaving gives it back
        model.pdf.setZoom(1.5)
        model.setFocus(true)
        view.setFrameSize(NSSize(width: 1200, height: 900))
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.scaleFactor, 1.95, accuracy: 0.001)
        XCTAssertEqual(model.pdf.position.zoom, 1.5, "the status line names the paper's zoom")
        model.pdf.zoomStep(in: true)
        XCTAssertEqual(view.scaleFactor, 1.75 * 1.3, accuracy: 0.001)
        model.setFocus(false)
        view.setFrameSize(NSSize(width: 760, height: 900))
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.scaleFactor, 1.75, accuracy: 0.001)
        XCTAssertFalse(view.autoScales)
    }

    func testCommandScrollZoomsAtThePointer() throws {
        let q = point(300, 400), at = view.convert(q, from: page)
        model.pdf.zoom(by: 1.4, at: at)
        XCTAssertEqual(model.pdf.position.zoom ?? 0, view.scaleFactor, accuracy: 0.001)
        let after = view.convert(q, from: page)
        XCTAssertEqual(after.x, at.x, accuracy: 1, "the point under the pointer stays under it")
        XCTAssertEqual(after.y, at.y, accuracy: 1)
        model.pdf.zoom(by: 100, at: at)
        XCTAssertEqual(view.scaleFactor, 4, accuracy: 0.001, "at most 400%")
    }

    /// Review: a pinch past 50% or 400% left a zoom no other control gives, and Zoom Out from under 50% zoomed in.
    func testAPinchStaysInTheRange() {
        view.autoScales = false
        view.scaleFactor = 0.3
        model.pdf.pinched()
        XCTAssertEqual(view.scaleFactor, 0.5, accuracy: 0.001)
        XCTAssertEqual(model.pdf.position.zoom, 0.5)
        view.scaleFactor = 6
        model.pdf.pinched()
        XCTAssertEqual(view.scaleFactor, 4, accuracy: 0.001)
    }

    /// A zoom stays with its paper: the same PDF shown again (another round, a build) keeps it.
    func testTheZoomStaysWithThePaper() throws {
        model.pdf.setZoom(1.25)
        model.pdf.update(url: nil, key: MarkKey(version: model.stateVersion, showChanges: true))
        XCTAssertNil(view.document)
        model.pdf.update(url: model.pdfURL, key: MarkKey(version: model.stateVersion, showChanges: true))
        XCTAssertEqual(view.scaleFactor, 1.25, accuracy: 0.001)
        XCTAssertEqual(model.pdf.position.zoom, 1.25)
    }
}
