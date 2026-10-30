import AppKit
import PDFKit
import SwiftUI
import XCTest
@testable import Paperole

/// Reference previews (design/pdf-reader/PLAN.md §4): the link table, the layout rules, and clicks, keys and menus in a
/// PDF view on the round 2 fixture with its reading and the table the engine's link builder gave for its PDF
/// (`Fixtures/links-round2.json`, labels and float boxes set by hand: the fixture has no source). Synthetic only.
@MainActor
final class PreviewTests: XCTestCase {
    private var drafts: URL!
    private var window: NSWindow!
    private var model: AppModel!
    private var view: ReviewPDFView!

    static func table() throws -> LinkTable {
        try makeDecoder().decode(LinkTable.self, from: Data(contentsOf: StepTests.fixtures.appendingPathComponent("links-round2.json")))
    }

    override func setUpWithError() throws {
        _ = NSApplication.shared
        drafts = FileManager.default.temporaryDirectory.appendingPathComponent("pc-preview-drafts-" + UUID().uuidString)
        var o = LaunchOptions()
        o.fixture = StepTests.fixtures.appendingPathComponent("state-reading.json").path
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
        model.pdf.setLinks(try Self.table())
        show(page: 0, y: 300)
    }

    override func tearDownWithError() throws {
        model.pdf.closePreview()
        model.pdf.closePinned()
        window.close()
        try? FileManager.default.removeItem(at: drafts)
    }

    private func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    private func page(_ i: Int) -> PDFPage { view.document!.page(at: i)! }

    private func point(_ x: Double, _ y: Double, on i: Int) -> CGPoint {
        let cb = page(i).bounds(for: .cropBox)
        return CGPoint(x: cb.minX + x, y: cb.maxY - y)
    }

    private func show(page i: Int, y: Double) {
        view.go(to: PDFDestination(page: page(i), at: point(0, y - 20, on: i)))
        view.layoutDocumentView()
        model.pdf.ownMove()
    }

    private func window(_ x: Double, _ y: Double, on i: Int) -> CGPoint {
        view.convert(view.convert(point(x, y, on: i), from: page(i)), to: nil)
    }

    /// A drag between contract points of a page, as the mouse sends it.
    private func drag(from a: (Double, Double), to b: (Double, Double), on i: Int = 0) {
        while NSApp.nextEvent(matching: .any, until: nil, inMode: .default, dequeue: true) != nil {}
        let wa = window(a.0, a.1, on: i), wb = window(b.0, b.1, on: i)
        func event(_ type: NSEvent.EventType, _ at: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        NSApp.postEvent(event(.leftMouseDragged, wb), atStart: false)
        NSApp.postEvent(event(.leftMouseUp, wb), atStart: false)
        window.contentView?.superview?.hitTest(wa)?.mouseDown(with: event(.leftMouseDown, wa))
        view.layoutDocumentView()
    }

    /// The fixture's table with its JSON changed.
    private func table(_ change: (inout [String: Any]) -> Void) throws -> LinkTable {
        let url = StepTests.fixtures.appendingPathComponent("links-round2.json")
        var d = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        change(&d)
        return try makeDecoder().decode(LinkTable.self, from: JSONSerialization.data(withJSONObject: d))
    }

    /// A click at a contract point, as the mouse sends it (`count`: its click count).
    private func click(_ x: Double, _ y: Double, on i: Int = 0, count: Int = 1) {
        while NSApp.nextEvent(matching: .any, until: nil, inMode: .default, dequeue: true) != nil {}
        let w = window(x, y, on: i)
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: w, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1)!
        }
        NSApp.postEvent(event(.leftMouseUp), atStart: false)
        window.contentView?.superview?.hitTest(w)?.mouseDown(with: event(.leftMouseDown))
        view.layoutDocumentView()
    }

    private func menu(_ x: Double, _ y: Double, on i: Int = 0) -> NSMenu? {
        let e = NSEvent.mouseEvent(with: .rightMouseDown, location: window(x, y, on: i), modifierFlags: [], timestamp: 0,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        return view.menu(for: e)
    }

    private func titles(_ m: NSMenu?) -> [String] { (m?.items ?? []).map { $0.isSeparatorItem ? "—" : $0.title } }

    private var steps: [String?] { model.navHistory.back.map { $0.step ? $0.review.pdf?.label : nil } }

    private var state: [String: Any] { model.pdf.previewState()["preview"] as? [String: Any] ?? [:] }

    // MARK: The table and the layout

    func testTheTable() throws {
        let t = try Self.table()
        XCTAssertEqual(t.round, 2)
        XCTAssertTrue(t.hyperref)
        XCTAssertEqual(t.links.count, 19)
        XCTAssertEqual(t.targets.count, 15)
        XCTAssertEqual(t.onPage(1).count, 5)
        XCTAssertEqual(t.link(page: 0, x: 95, y: 347), 0)
        XCTAssertNil(t.link(page: 0, x: 300, y: 347))
        XCTAssertEqual(t.targets[3].cited, [0, 1])
        XCTAssertEqual(t.citing(3, on: 0).count, 2, "[9] twice on p.1")
        XCTAssertEqual(t.targets[13].title, "Figure 1 · p.3")
        XCTAssertEqual(t.targets[13].place?.rect, [72, 170, 540, 400])
        XCTAssertTrue(t.previews(0))
        // a target with no place previews only when it is missing or a URL the app opens, the PDF's own link too
        let json = """
        {"round": 1, "links": [{"page": 0, "rects": [[1, 1, 9, 9]], "targets": [0], "via": "source"},
                                {"page": 0, "rects": [[11, 1, 19, 9]], "targets": [1], "via": "pdf"},
                                {"page": 0, "rects": [[21, 1, 29, 9]], "targets": [2], "via": "source"},
                                {"page": 0, "rects": [[31, 1, 39, 9]], "targets": [1], "via": "source"},
                                {"page": 0, "rects": [[41, 1, 49, 9]], "targets": [7], "via": "pdf"}],
         "targets": [{"kind": "missing", "label": "Undefined reference", "page": null, "box": [], "parts": [],
                      "note": "No \\\\label{fig:old} in this round's source."},
                     {"kind": "url", "label": "https://example.org", "url": "https://example.org", "parts": []},
                     {"kind": "url", "label": "x", "url": "javascript:alert(1)", "parts": []}]}
        """
        let u = try makeDecoder().decode(LinkTable.self, from: Data(json.utf8))
        XCTAssertEqual(u.links.count, 4, "a link to no target is left out")
        XCTAssertEqual(u.targets[0].note, "No \\label{fig:old} in this round's source.")
        XCTAssertNil(u.targets[0].place)
        XCTAssertEqual([0, 1, 2, 3].map(u.previews), [true, true, false, true])
        XCTAssertEqual(u.targets[1].title, "Link", "the address is under it, once")
        XCTAssertNil(u.targets[2].openable, "only http, https and mailto open")
    }

    func testTheLayout() {
        // the page's scale up to 1.5×; a wide target fits 90% of the view, a tall one the height given
        XCTAssertEqual(PreviewLayout.scale([CGSize(width: 200, height: 100)], page: 1.2, width: 600, height: 600), 1.2)
        XCTAssertEqual(PreviewLayout.scale([CGSize(width: 200, height: 100)], page: 2.5, width: 600, height: 600), 1.5)
        XCTAssertEqual(PreviewLayout.scale([CGSize(width: 600, height: 100)], page: 1.2, width: 300, height: 600), 0.5)
        XCTAssertEqual(PreviewLayout.scale([CGSize(width: 100, height: 50), CGSize(width: 100, height: 50)], page: 1.5,
                                           width: 600, height: 106), 1.0, accuracy: 0.001)
        // above when it fits, else below, else the side with more room; never over the line
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 800), line = CGRect(x: 100, y: 600, width: 40, height: 10)
        XCTAssertTrue(PreviewLayout.above(height: 150, line: line, bounds: bounds))
        XCTAssertFalse(PreviewLayout.above(height: 300, line: line, bounds: bounds))
        XCTAssertFalse(PreviewLayout.above(height: 900, line: line, bounds: bounds))
        let size = CGSize(width: 300, height: 150)
        let a = PreviewLayout.origin(size: size, line: line, bounds: bounds, above: true)
        XCTAssertEqual(a.y, line.maxY + PreviewLayout.gap)
        XCTAssertEqual(a.x, PreviewLayout.margin, "kept inside the view across")
        let b = PreviewLayout.origin(size: size, line: line, bounds: bounds, above: false)
        XCTAssertEqual(b.y + size.height, line.minY - PreviewLayout.gap)
    }

    /// A preview's words stay within its widest (90% of the view): a long title is cut short, many "Cited" pages wrap;
    /// Copy Reference only when the entry's words were found (an empty copy would wipe the clipboard).
    func testTheWordsFitTheWidth() {
        var pv = LinkPreview(link: nil, target: 0, kind: "cite", title: String(repeating: "A very long label ", count: 20),
                             entries: [], continues: nil, cited: Array(0..<30), count: 30, note: nil, address: nil, url: nil)
        func size() -> CGSize {
            NSHostingView(rootView: LinkPreviewView(preview: pv, actions: PreviewActions(controller: nil), maxWidth: 400)).fittingSize
        }
        XCTAssertLessThanOrEqual(size().width, 400)
        XCTAssertGreaterThan(size().height, 80, "the pages on several rows")
        XCTAssertFalse(pv.canCopy)
        XCTAssertFalse(pv.footer.contains("Copy Reference"))
        pv.reference = "[7] A. Author. A title. 2024."
        XCTAssertTrue(pv.footer.hasSuffix(" · Copy Reference"))
        pv.cited = []
        XCTAssertEqual(pv.footer, "Copy Reference")
        pv.kind = "missing"
        pv.note = String(repeating: "No \\label{fig:old} in this round's source. ", count: 12)
        XCTAssertLessThanOrEqual(size().width, 400, "a long note wraps")
    }

    // MARK: Clicks (PLAN §4.1)

    /// A click on "[7]" previews its entry by it, above or below, never over its line; nothing moves and no step is
    /// recorded. A second click on it goes there: a step of Back, the target a third of the way down, flashed.
    func testAClickPreviewsAndASecondClickGoes() throws {
        click(95, 347)
        XCTAssertTrue(model.pdf.previewShown)
        XCTAssertEqual(model.pdf.shownPage, 0, "a preview moves nothing")
        XCTAssertEqual(steps, [])
        XCTAssertEqual(state["kind"] as? String, "cite")
        XCTAssertEqual(state["title"] as? String, "[7] · p.4")
        XCTAssertEqual(state["footer"] as? String, "Cited 1×: p.1 · Copy Reference")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(state["gap"] as? Double), 0, "never over the link's line")
        XCTAssertEqual(state["inView"] as? Bool, true)
        XCTAssertLessThanOrEqual(try XCTUnwrap(state["widthShare"] as? Double), 0.9)
        XCTAssertLessThanOrEqual(try XCTUnwrap(state["heightShare"] as? Double), 0.7)
        XCTAssertLessThanOrEqual(try XCTUnwrap(state["scale"] as? Double), 1.5)
        XCTAssertTrue(model.pdf.shownPreview?.reference?.hasPrefix("[7]") == true, model.pdf.shownPreview?.reference ?? "")
        click(95, 347)
        XCTAssertFalse(model.pdf.previewShown)
        XCTAssertEqual(model.pdf.shownPage, 3)
        XCTAssertEqual(steps.count, 1)
        XCTAssertTrue(model.pdf.flashing, "the whole target flashes")
        model.goBack()
        view.layoutDocumentView()
        XCTAssertEqual(model.pdf.shownPage, 0)
    }

    /// A drag from the preview's link selects, as from any text: it neither goes there nor leaves the preview open.
    func testADragFromItsLinkSelects() {
        click(95, 347)
        XCTAssertTrue(model.pdf.previewShown)
        drag(from: (93, 347), to: (300, 349))
        XCTAssertFalse(model.pdf.previewShown)
        XCTAssertEqual(model.pdf.shownPage, 0)
        XCTAssertEqual(steps, [])
        XCTAssertFalse((view.currentSelection?.string ?? "").isEmpty, "the words dragged over are selected")
    }

    /// A double click on a link: the first click previews, the second goes (it would select a word).
    func testADoubleClickGoes() {
        click(95, 347)
        click(95, 347, count: 2)
        XCTAssertFalse(model.pdf.previewShown)
        XCTAssertEqual(model.pdf.shownPage, 3)
        XCTAssertTrue((view.currentSelection?.string ?? "").isEmpty, "no word selected")
    }

    /// Esc, a click elsewhere, a click outside the PDF, a scroll and a zoom close it; nothing moves.
    func testWhatClosesIt() throws {
        click(95, 347)
        XCTAssertTrue(model.pdf.previewShown)
        let esc = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                 windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                                 charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        XCTAssertTrue(model.performKey(esc))
        XCTAssertFalse(model.pdf.previewShown)
        click(95, 347)
        click(300, 600)  // on the text
        XCTAssertFalse(model.pdf.previewShown)
        XCTAssertEqual(model.pdf.shownPage, 0)
        XCTAssertEqual(steps, [])
        click(95, 347)
        let clip = try XCTUnwrap(view.documentView?.enclosingScrollView?.contentView)
        var o = clip.bounds.origin
        o.y += clip.isFlipped ? 40 : -40
        clip.scroll(to: o)
        XCTAssertFalse(model.pdf.previewShown, "a scroll closes it")
        click(95, 347)
        model.pdf.setZoom(1.25)
        XCTAssertFalse(model.pdf.previewShown, "a zoom closes it")
    }

    /// Without the table (an older engine, a table that could not be built) a click goes there at once, as before.
    func testNoTableGoesAtOnce() {
        model.pdf.setLinks(nil)
        click(95, 347)
        XCTAssertFalse(model.pdf.previewShown)
        XCTAssertEqual(model.pdf.shownPage, 3)
        XCTAssertEqual(steps.count, 1)
        // a table for another round is not this one's
        var t = try? Self.table()
        t?.round = 1
        model.goBack()
        model.pdf.setLinks(t)
        view.layoutDocumentView()
        XCTAssertNil(model.pdf.previewLink(page: page(0), at: point(95, 347, on: 0)))
    }

    /// A figure: the whole float with its caption, at most 1.5× and within the view, "Cited on p.2" a link that goes there
    /// (a step); Go to › puts the figure a third of the way down and flashes it.
    func testAFigure() throws {
        show(page: 1, y: 600)
        click(121, 696, on: 1)
        XCTAssertEqual(state["kind"] as? String, "figure")
        XCTAssertEqual(state["title"] as? String, "Figure 1 · p.3")
        XCTAssertEqual(state["footer"] as? String, "Cited on p.2")
        let size = try XCTUnwrap((state["entries"] as? [[Any]])?.first?[1] as? [Double])
        XCTAssertLessThanOrEqual(size[0], Double(view.bounds.width) * 0.9)
        XCTAssertEqual(size[0] / size[1], 476.0 / 238.0, accuracy: 0.02, "the float's box, 4 pt round it")
        model.pdf.goToTarget(13)
        view.layoutDocumentView()
        XCTAssertFalse(model.pdf.previewShown)
        XCTAssertEqual(model.pdf.shownPage, 2)
        XCTAssertTrue(model.pdf.flashing)
        let k = try XCTUnwrap(model.pdf.pointAtThird())
        XCTAssertEqual(k.page, 2)
        XCTAssertEqual(k.y, 170, accuracy: 3, "the figure's top a third of the way down")
        XCTAssertEqual(steps, [], "less than a view away: no step (PLAN §5.2)")
        // its Cited on page goes back to the citation, another step
        show(page: 1, y: 600)
        click(121, 696, on: 1)
        model.pdf.goCited(1)
        view.layoutDocumentView()
        XCTAssertFalse(model.pdf.previewShown)
        XCTAssertEqual(model.pdf.pointAtThird()?.page, 1)
    }

    /// `\citep{wang,oakes}` printed "[10, 8]": each link shows every entry, the clicked one first.
    func testACitationOfSeveralKeys() {
        click(127, 383)  // "8]."
        XCTAssertEqual(model.pdf.shownPreview?.entries.map(\.label), ["[8]", "[10]"])
        XCTAssertEqual(model.pdf.shownPreview?.title, "[8] · p.4")
        click(115, 383)  // "[10,": a click on another link closes this preview and shows its own
        XCTAssertEqual(model.pdf.shownPreview?.entries.map(\.label), ["[10]", "[8]"])
    }

    /// The pin makes a small window of it; several can stay; they close with the round or paper.
    func testKeepOpen() throws {
        click(95, 347)
        model.pdf.pinPreview()
        XCTAssertFalse(model.pdf.previewShown)
        XCTAssertEqual(model.pdf.pinned.map(\.title), ["[7] · p.4"])
        XCTAssertFalse(model.pdf.pinned[0].delegate is QuitOnClose, "not a review window")
        // dragging the preview's title row away keeps it open too; a small drag does not
        show(page: 1, y: 600)
        click(121, 696, on: 1)
        model.pdf.dragPreview(CGSize(width: 2, height: 1), ended: true)
        XCTAssertTrue(model.pdf.previewShown)
        model.pdf.dragPreview(CGSize(width: 40, height: 30), ended: false)
        model.pdf.dragPreview(CGSize(width: 80, height: 60), ended: true)
        XCTAssertFalse(model.pdf.previewShown)
        XCTAssertEqual(model.pdf.pinned.map(\.title), ["[7] · p.4", "Figure 1 · p.3"])
        model.pdf.pinned[0].close()
        XCTAssertEqual(model.pdf.pinned.map(\.title), ["Figure 1 · p.3"])
        model.pdf.update(url: StepTests.fixtures.appendingPathComponent("round1/main.pdf"), key: MarkKey(version: 0, showChanges: true))
        XCTAssertEqual(model.pdf.pinned.count, 0, "another round's PDF closes them")
    }

    /// Review hidden (the overview) or another paper (a hub page): the kept windows close, as they would float over it
    /// and their Go to move a PDF nobody sees.
    func testKeptWindowsCloseWithReview() {
        click(95, 347)
        model.pdf.pinPreview()
        XCTAssertEqual(model.pdf.pinned.count, 1)
        model.pdf.setReviewHidden(true)
        XCTAssertEqual(model.pdf.pinned.count, 0, "Review hidden")
        model.pdf.setReviewHidden(false)
        click(95, 347)
        model.pdf.pinPreview()
        XCTAssertEqual(model.pdf.pinned.count, 1)
        model.selectPaper(nil)
        XCTAssertEqual(model.pdf.pinned.count, 0, "no paper shown")
    }

    /// The PDF's own link to a URL previews its address too (the browser only on a second click or from the preview),
    /// titled "Link" and within the view however long the address.
    func testAURLPreviews() throws {
        let address = "https://example.org/" + String(repeating: "a-very-long-path/", count: 12)
        let t = try table { d in
            var targets = d["targets"] as! [[String: Any]], links = d["links"] as! [[String: Any]]
            links.append(["page": 0, "rects": [[86, 307, 200, 318]], "text": "Introduction", "kind": "url",
                          "targets": [targets.count], "via": "pdf"])
            targets.append(["kind": "url", "label": address, "url": address, "parts": [] as [Any]])
            d["targets"] = targets
            d["links"] = links
        }
        let link = PDFAnnotation(bounds: CGRect(origin: point(86, 318, on: 0), size: CGSize(width: 114, height: 11)),
                                 forType: .link, withProperties: nil)
        link.url = URL(string: address)
        page(0).addAnnotation(link)  // in memory only, as PDFView would follow it
        defer { page(0).removeAnnotation(link) }
        model.pdf.setLinks(t)
        click(120, 312)
        XCTAssertEqual(state["kind"] as? String, "url")
        XCTAssertEqual(state["title"] as? String, "Link")
        XCTAssertEqual(state["footer"] as? String, address + " · Open in Browser · Copy Link")
        XCTAssertLessThanOrEqual(try XCTUnwrap(state["widthShare"] as? Double), 0.9)
        XCTAssertEqual(state["inView"] as? Bool, true)
        model.pdf.closePreview()
        // a PDF link to a file or an app: Copy Link, but no Open in Browser
        link.url = URL(string: "file:///Applications/Calculator.app")
        model.pdf.setLinks(nil)
        let items = titles(menu(120, 312))
        XCTAssertTrue(items.contains("Copy Link"), "\(items)")
        XCTAssertFalse(items.contains("Open in Browser"), "\(items)")
    }

    /// A table across pages, in a short window: "continues on p.4" is counted in its height, which stays within 70% of
    /// the window's and inside the view.
    func testATableAcrossPagesFitsAShortWindow() throws {
        let t = try table { d in
            var targets = d["targets"] as! [[String: Any]]
            targets[12]["parts"] = [[2, [80, 77, 532, 165]], [3, [80, 72, 532, 300]]]
            d["targets"] = targets
        }
        window.setContentSize(NSSize(width: 760, height: 300))
        view.frame = window.contentView!.bounds
        view.layoutDocumentView()
        model.pdf.setLinks(t)
        show(page: 1, y: 640)
        click(117, 648, on: 1)
        XCTAssertEqual(state["kind"] as? String, "table")
        XCTAssertEqual(state["continues"] as? Int, 3)
        XCTAssertLessThanOrEqual(try XCTUnwrap(state["heightShare"] as? Double), 0.7 + 0.005)
        XCTAssertEqual(state["inView"] as? Bool, true, "\(state["frame"] ?? "")")
    }

    /// Resting on a link draws its crop, so the click shows it at once.
    func testRestingOnALinkDrawsItsCrop() throws {
        XCTAssertTrue(model.pdf.hoverLink(page: page(0), at: point(95, 347, on: 0)))
        XCTAssertFalse(model.pdf.hoverLink(page: page(0), at: point(300, 600, on: 0)))
        XCTAssertTrue(model.pdf.hoverLink(page: page(0), at: point(250, 641, on: 0)))  // [9]
        // read at once, before the preview's own picture could draw anything
        spin(1.5)
        model.pdf.showPreview(10)
        let drawn = (state["entries"] as? [[Any]])?.first?[2] as? Bool ?? false
        XCTAssertTrue(drawn, "the crop was drawn before the click")
    }

    /// A "??" the engine found in the source (no PDF link): what is missing, and Comment… on its words in an open round.
    func testAMissingReference() throws {
        var json = try String(contentsOf: StepTests.fixtures.appendingPathComponent("links-round2.json"), encoding: .utf8)
        // a source link on "Introduction" of p.1, pointing at a missing label (a new last target, 15)
        json = json.replacingOccurrences(of: "\"links\": [\n", with: """
        "links": [
          {"page": 0, "rects": [[86, 307, 200, 318]], "text": "??", "kind": "missing", "targets": [15], "via": "source"},

        """)
        let end = try XCTUnwrap(json.range(of: "]}", options: .backwards))
        json.replaceSubrange(end, with: """
        ,
          {"kind": "missing", "label": "Undefined reference", "key": "fig:old", "page": null, "box": [], "parts": [],
           "note": "No \\\\label{fig:old} in this round's source.", "cited": [0], "count": 1}]}
        """)
        let t = try makeDecoder().decode(LinkTable.self, from: Data(json.utf8))
        XCTAssertEqual(t.targets.count, 16)
        XCTAssertEqual(t.links.count, 20)
        model.pdf.setLinks(t)
        click(120, 312)
        XCTAssertEqual(state["kind"] as? String, "missing")
        XCTAssertEqual(state["footer"] as? String, "No \\label{fig:old} in this round's source. · Comment…")
        XCTAssertEqual(model.pdf.shownPreview?.canGo, false)
        click(120, 312)
        XCTAssertFalse(model.pdf.previewShown, "a second click closes it: nowhere to go")
        XCTAssertEqual(titles(menu(120, 312)).first, "Preview “??”", "its printed words")
        click(120, 312)
        model.pdf.commentOnPreviewLink()
        XCTAssertFalse(model.pdf.previewShown)
        XCTAssertTrue(PDFMenus.collapsed(view.currentSelection?.string ?? "").contains("Introduction"),
                      view.currentSelection?.string ?? "no selection")
        XCTAssertNotNil(model.pdf.draft, "the new-comment editor")
        model.pdf.popover?.close()
    }

    // MARK: Menus (PLAN §3.3, §3.4)

    func testTheLinkMenu() throws {
        let items = titles(menu(95, 347))
        XCTAssertEqual(Array(items.prefix(5)), ["Preview [7]", "Go to [7] · p.4", "Keep [7] Open", "—", "Copy Reference"])
        XCTAssertTrue(items.last?.hasPrefix("Comment on “") == true, "\(items)")
        let m = try XCTUnwrap(menu(95, 347))
        m.performActionForItem(at: 0)
        XCTAssertTrue(model.pdf.previewShown, "Preview")
        m.performActionForItem(at: 2)
        XCTAssertEqual(model.pdf.pinned.map(\.title), ["[7] · p.4"], "Keep Open")
        m.performActionForItem(at: 1)
        view.layoutDocumentView()
        XCTAssertEqual(model.pdf.shownPage, 3, "Go to")
        XCTAssertEqual(steps.count, 1)
        // without the table, as before
        model.goBack()
        model.pdf.setLinks(nil)
        XCTAssertEqual(titles(menu(95, 347)).first, "Go to p.4")
    }

    /// hyperref links the number of "Figure 1" alone: Comment on takes in the name before it, so the note is anchored on
    /// "Figure 1", not on one digit.
    func testCommentOnAFigureLinkTakesItsName() throws {
        show(page: 1, y: 600)
        let items = titles(menu(121, 696, on: 1))
        XCTAssertEqual(Array(items.prefix(3)), ["Preview Figure 1", "Go to Figure 1 · p.3", "Keep Figure 1 Open"])
        XCTAssertEqual(items.last, "Comment on “Figure 1”…")
    }

    /// On a figure the table knows: Comment on Figure 1… (a box round the whole float), Keep Figure 1 Open, Cited on.
    func testTheFigureMenu() throws {
        show(page: 2, y: 200)
        let m = try XCTUnwrap(menu(300, 260, on: 2))
        XCTAssertEqual(titles(m), ["Comment on Figure 1…", "Add Note Here", "—", "Keep Figure 1 Open", "Cited on"])
        XCTAssertEqual(m.items.last?.submenu?.items.map(\.title), ["p.2"])
        m.performActionForItem(at: 0)
        XCTAssertEqual(model.pdf.pendingBox.map { Geometry.contractRect($0.rect, cropBox: page(2).bounds(for: .cropBox)) }?
            .map { $0.rounded() }, [72, 170, 540, 400])
        XCTAssertEqual(model.pdf.draft?.mode, .box)
        model.pdf.popover?.close()
        model.pdf.dropPendingBox()
        // a closed round or busy: no comment
        model.holdBusy(true)
        XCTAssertEqual(titles(menu(300, 260, on: 2)).first, "Keep Figure 1 Open")
        model.holdBusy(false)
    }

    /// Go to puts a figure under the pointer: its menu leads with the page's Back.
    func testTheFigureMenuHasBack() throws {
        model.pdf.goToTarget(13)
        view.layoutDocumentView()
        XCTAssertEqual(steps.count, 1)
        let items = titles(menu(300, 260, on: 2))
        XCTAssertTrue(items.first?.hasPrefix("Back to p.1") == true, "\(items)")
        XCTAssertEqual(Array(items.dropFirst()), ["—", "Comment on Figure 1…", "Add Note Here", "—", "Keep Figure 1 Open", "Cited on"])
    }
}
