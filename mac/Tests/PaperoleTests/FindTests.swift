import AppKit
import CoreText
import PDFKit
import XCTest
@testable import Paperole

/// Find in the paper (Find.swift): its rules alone.
final class FindRulesTests: XCTestCase {
    private func hit(_ page: Int, _ location: Int, _ length: Int = 3) -> FindHit {
        FindHit(runs: [.init(page: page, location: location, length: length)])
    }

    /// The document's order: by page, then by where the match begins in the page's text; ties keep PDFKit's order.
    func testOrderIsByPageThenCharacter() {
        let hits = [hit(1, 40), hit(0, 90), hit(1, 5), hit(0, 12), hit(0, 12, 7)]
        XCTAssertEqual(FindRules.ordered(hits), [hit(0, 12), hit(0, 12, 7), hit(0, 90), hit(1, 5), hit(1, 40)])
        let across = FindHit(runs: [.init(page: 2, location: 900, length: 4), .init(page: 3, location: 0, length: 3)])
        XCTAssertEqual(FindRules.ordered([hit(3, 1), across]), [across, hit(3, 1)], "a match across a page break by its start")
    }

    /// Next and previous wrap round both ends.
    func testStepWraps() {
        XCTAssertEqual(FindRules.step(0, count: 3, previous: false), 1)
        XCTAssertEqual(FindRules.step(2, count: 3, previous: false), 0, "past the last: the first")
        XCTAssertEqual(FindRules.step(0, count: 3, previous: true), 2, "before the first: the last")
        XCTAssertEqual(FindRules.step(1, count: 3, previous: true), 0)
        XCTAssertEqual(FindRules.step(0, count: 1, previous: false), 0)
        XCTAssertEqual(FindRules.step(0, count: 1, previous: true), 0)
        XCTAssertEqual(FindRules.step(5, count: 3, previous: false), 0, "an index from a longer list stays in range")
    }

    /// Where a find starts: a query typed on stays on the match shown (or the next one that still matches); a new one
    /// starts at the top of the view, Previous at the match before it.
    func testWhereAFindStarts() {
        let hits = [hit(0, 10), hit(0, 50), hit(2, 5), hit(4, 0)]
        XCTAssertEqual(FindRules.start(hits, at: (0, 50)), 1, "the match shown")
        XCTAssertEqual(FindRules.start(hits, at: (0, 51)), 2, "the next one after it")
        XCTAssertEqual(FindRules.start(hits, at: (5, 0)), 0, "none after it: the first")
        XCTAssertNil(FindRules.start([], at: (0, 0)))
        // page space grows upwards: a match at or below the view's top is one whose top is at or under its y
        let tops: [(page: Int, top: CGFloat)] = [(0, 700), (0, 300), (1, 650), (1, 100), (2, 720)]
        XCTAssertEqual(FindRules.start(tops: tops, page: 0, y: 800, previous: false), 0, "the top of the paper")
        XCTAssertEqual(FindRules.start(tops: tops, page: 0, y: 500, previous: false), 1)
        XCTAssertEqual(FindRules.start(tops: tops, page: 1, y: 700, previous: false), 2, "the next page's first")
        XCTAssertEqual(FindRules.start(tops: tops, page: 1, y: 649.5, previous: false), 2, "within a point")
        XCTAssertEqual(FindRules.start(tops: tops, page: 1, y: 600, previous: true), 2, "Previous: the one before")
        XCTAssertEqual(FindRules.start(tops: tops, page: 3, y: 800, previous: false), 0, "past the last: wrapping")
        XCTAssertEqual(FindRules.start(tops: tops, page: 0, y: 800, previous: true), 4, "Previous from the top: the last")
        XCTAssertNil(FindRules.start(tops: [], page: 0, y: 0, previous: false))
    }

    /// The find bar over the PDF: closed until ⌘F (or a query from Jump), then Esc or × closes it and drops the query.
    @MainActor
    func testTheFindBarOpensAndCloses() {
        let f = PaperFind()
        XCTAssertFalse(f.open)
        f.focusField()
        XCTAssertTrue(f.open, "⌘F or the button opens it")
        f.close()
        XCTAssertFalse(f.open)
        XCTAssertEqual(f.query, "", "closing drops the query")
        f.find("boat")
        XCTAssertTrue(f.open, "Jump's Find in the paper opens it")
        f.close()
        f.type("boat")
        XCTAssertTrue(f.open, "a query typed or set from outside opens it")
        f.close()
    }

    /// Every match is highlighted only while no page has more than 25 and there are at most 1,500: one letter typed
    /// held the window up (PDFKit's ~1 ms per highlight in view).
    func testTooManyMatchesAreNotHighlighted() {
        let spread = (0..<60).flatMap { p in (0..<25).map { hit(p, $0 * 10) } }
        XCTAssertTrue(FindRules.highlightsAll(spread), "25 a page, 1,500 in all")
        XCTAssertFalse(FindRules.highlightsAll(spread + [hit(0, 999)]), "a page with 26")
        XCTAssertFalse(FindRules.highlightsAll((0..<1501).map { hit($0, 0) }), "more than 1,500")
        XCTAssertTrue(FindRules.highlightsAll([]))
    }

    func testCounterAndQueries() {
        XCTAssertEqual(FindRules.counter(count: nil, index: nil), "", "the first search still running")
        XCTAssertEqual(FindRules.counter(count: 0, index: nil), "No matches")
        XCTAssertEqual(FindRules.counter(count: 12, index: nil), "12 matches", "none shown yet (another round)")
        XCTAssertEqual(FindRules.counter(count: 1, index: nil), "1 match")
        XCTAssertEqual(FindRules.counter(count: 12, index: 2), "3 of 12")
        XCTAssertEqual(FindRules.counter(count: 2, index: 5), "2 matches", "an index out of range is not shown")
        XCTAssertTrue(FindRules.searchable("boat"))
        XCTAssertTrue(FindRules.searchable(" a "))
        XCTAssertFalse(FindRules.searchable(""))
        XCTAssertFalse(FindRules.searchable("  \n"))
    }
}

/// The find on PDFs: one made here (accents and case), and the fixture's two rounds in Review's model.
@MainActor
final class PaperFindTests: XCTestCase {
    private var folder: URL!
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("pc-find-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        windows.forEach { $0.close() }
        windows = []
        try? FileManager.default.removeItem(at: folder)
    }

    /// A PDF of these pages' text, one page each, in 12 pt type.
    private func makePDF(_ pages: [String], name: String = "made.pdf") throws -> URL {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        let ctx = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        for text in pages {
            ctx.beginPDFPage(nil)
            let s = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)])
            let setter = CTFramesetterCreateWithAttributedString(s)
            CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0),
                                                 CGPath(rect: box.insetBy(dx: 72, dy: 72), transform: nil), nil), ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        let url = folder.appendingPathComponent(name)
        try (data as Data).write(to: url)
        return url
    }

    /// A PDF view in a window never shown, its controller showing `url` (no model: the find alone).
    private func controller(showing url: URL) -> (PDFController, ReviewPDFView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 900), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = ReviewPDFView(frame: NSRect(x: 0, y: 0, width: 700, height: 900))
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        window.contentView = view
        windows.append(window)
        let c = PDFController()
        c.attach(view)
        c.update(url: url, key: MarkKey(version: 0, showChanges: false))
        view.layoutSubtreeIfNeeded()
        return (c, view)
    }

    /// Runs the main loop until the find has its matches (at most 5 s).
    private func settle(_ find: PaperFind) {
        let deadline = Date().addingTimeInterval(5)
        repeat { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) } while find.isSearching && Date() < deadline
        XCTAssertFalse(find.isSearching, "the search came in")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))  // the selection's notification
    }

    private let cafes = ["Café society began here. The cafe opened at nine. A CAFÉ at noon, then tea.",
                         "Another café on the second page."]

    /// Any case and any accents, every page, in the document's order; the matches are highlighted in the find's grey,
    /// the first becomes the PDF's selection; the page's marks are left alone.
    func testMatchesAnyCaseAndAccentsInTheDocumentsOrder() throws {
        let (c, view) = controller(showing: try makePDF(cafes))
        let find = c.find
        let doc = try XCTUnwrap(view.document)
        let before = (0..<doc.pageCount).map { doc.page(at: $0)?.annotations.count ?? 0 }
        find.type("cafe")
        XCTAssertTrue(find.isSearching, "typing searches after a pause, off the main thread")
        XCTAssertNil(find.count)
        XCTAssertEqual(find.highlighted.count, 0)
        settle(find)
        XCTAssertEqual(find.count, 4)
        XCTAssertEqual(find.index, 0)
        XCTAssertEqual(find.counter, "1 of 4")
        let h = try XCTUnwrap(view.highlightedSelections)
        XCTAssertEqual(h.map { $0.string ?? "" }, ["Café", "cafe", "CAFÉ", "café"], "in the document's order")
        XCTAssertEqual(h.map { doc.index(for: $0.pages[0]) }, [0, 0, 0, 1])
        XCTAssertTrue(h.allSatisfy { $0.color == Palette.find }, "the find's own grey, never a mark's colour")
        XCTAssertTrue(find.ringShown, "the current match has the accent's outline")
        XCTAssertTrue(find.highlighted.inShownDocument)
        XCTAssertEqual(view.currentSelection?.string, "Café", "the first match is the PDF's selection")
        XCTAssertEqual((0..<doc.pageCount).map { doc.page(at: $0)?.annotations.count ?? 0 }, before, "no annotation added")
        find.type("CAFÉ")
        settle(find)
        XCTAssertEqual(find.count, 4, "accents and case either way")
        find.type("tea")
        settle(find)
        XCTAssertEqual(find.counter, "1 of 1")
        find.type("zzqxw")
        settle(find)
        XCTAssertEqual(find.counter, "No matches")
        XCTAssertEqual(find.highlighted.count, 0)
    }

    /// A query on almost every word of a page (one letter typed): counted and stepped through, the current one
    /// selected and outlined, but none highlighted; a query found again sparsely highlights again.
    func testAQueryOnEveryWordHighlightsOnlyTheCurrentOne() throws {
        let dense = Array(repeating: "tea", count: 40).joined(separator: " ") + ". Then cafe."
        let (c, view) = controller(showing: try makePDF([dense]))
        let find = c.find
        find.type("t")
        settle(find)
        XCTAssertEqual(find.count, 41)
        XCTAssertEqual(find.index, 0)
        XCTAssertNil(view.highlightedSelections, "41 on one page: not highlighted")
        XCTAssertFalse(find.isSearching)
        XCTAssertTrue(find.ringShown, "the current match still has its outline")
        XCTAssertEqual(view.currentSelection?.string, "t")
        find.step(previous: true)
        XCTAssertEqual(find.index, 40, "stepped through as ever")
        find.type("cafe")
        settle(find)
        XCTAssertEqual(view.highlightedSelections?.count, 1)
    }

    /// Typing quickly searches once, for the last text; a query typed on stays on the match shown.
    func testTypingOnKeepsThePlace() throws {
        let (c, view) = controller(showing: try makePDF(cafes))
        let find = c.find
        find.type("c")
        find.type("ca")
        find.type("caf")
        settle(find)
        XCTAssertEqual(find.query, "caf")
        XCTAssertEqual(find.count, 4)
        find.step(previous: false)
        find.step(previous: false)
        XCTAssertEqual(find.index, 2)
        XCTAssertEqual(view.currentSelection?.string, "CAF")
        find.type("café")
        settle(find)
        XCTAssertEqual(find.index, 2, "still the match shown")
        XCTAssertEqual(view.currentSelection?.string, "CAFÉ")
    }

    /// Return and ⇧Return (‹ ›) go on from the current match, wrapping, also once the selection is elsewhere; Esc clears
    /// the query, the highlights and the match's selection, and gives the keys back to the PDF.
    func testStepsWrapAndClearing() throws {
        let (c, view) = controller(showing: try makePDF(cafes))
        let find = c.find
        let field = NSSearchField(frame: NSRect(x: 0, y: 0, width: 180, height: 22))
        view.window?.contentView?.addSubview(field)
        find.field = field
        find.focusField()
        XCTAssertTrue((view.window?.firstResponder as? NSTextView)?.delegate === field, "⌘F: the cursor in the field")
        let coordinator = FindField.Coordinator(find: find)
        find.type("cafe")
        settle(find)
        let enter = #selector(NSResponder.insertNewline(_:))
        XCTAssertTrue(coordinator.command(enter, shift: false))
        XCTAssertEqual(find.counter, "2 of 4")
        XCTAssertTrue(coordinator.command(enter, shift: true))
        XCTAssertTrue(coordinator.command(enter, shift: true))
        XCTAssertEqual(find.counter, "4 of 4", "⇧Return before the first: the last")
        XCTAssertEqual(view.currentSelection?.string, "café")
        find.step(previous: false)
        XCTAssertEqual(find.counter, "1 of 4", "Return past the last: the first")
        find.step(previous: false)
        XCTAssertEqual(find.index, 1)
        view.clearSelection()  // a click elsewhere in the PDF
        XCTAssertEqual(find.highlighted.count, 4, "a click leaves the highlights")
        XCTAssertTrue(find.ringShown, "and the current one's outline: Return goes on from it")
        find.step(previous: false)
        XCTAssertEqual(find.index, 2, "on from the current match")
        XCTAssertEqual(view.currentSelection?.string, "CAFÉ", "selected again")
        XCTAssertFalse(coordinator.command(#selector(NSResponder.moveUp(_:)), shift: false), "other keys are the field's")
        XCTAssertTrue(coordinator.command(#selector(NSResponder.cancelOperation(_:)), shift: false))
        XCTAssertEqual(find.query, "")
        XCTAssertNil(find.count)
        XCTAssertNil(find.index)
        XCTAssertEqual(find.highlighted.count, 0, "the highlights go")
        XCTAssertNil(view.highlightedSelections)
        XCTAssertFalse(find.ringShown)
        XCTAssertNil(view.currentSelection, "the match it showed is deselected")
        XCTAssertTrue(view.window?.firstResponder === view, "the keys back to the PDF")
        find.step(previous: false)
        XCTAssertNil(find.index, "nothing to go on with")
    }

    /// The field's ⊗ empties it: the find clears, and a selection the advisor made since is left alone.
    func testEmptyingTheFieldLeavesAnotherSelection() throws {
        let (c, view) = controller(showing: try makePDF(cafes))
        let find = c.find
        let coordinator = FindField.Coordinator(find: find)
        find.type("tea")
        settle(find)
        let doc = try XCTUnwrap(view.document)
        let other = try XCTUnwrap(doc.findString("Another", withOptions: []).first)
        view.setCurrentSelection(other, animate: false)
        let field = NSSearchField()
        field.stringValue = ""
        coordinator.searched(field)
        XCTAssertEqual(find.query, "")
        XCTAssertEqual(find.highlighted.count, 0)
        XCTAssertEqual(view.currentSelection?.string, "Another", "not the find's: kept")
    }

    /// Another round's PDF: the query stays and is found again there, highlighted in the new document, with none shown
    /// until Return; a PDF gone takes the highlights with it.
    func testAnotherRoundKeepsTheQueryAndSearchesAgain() throws {
        _ = NSApplication.shared
        var o = LaunchOptions()
        o.fixture = StepTests.fixtures.appendingPathComponent("state-m2a.json").path
        o.drafts = folder.appendingPathComponent("drafts").path
        let m = AppModel(options: o)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 900), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        windows.append(window)
        let view = ReviewPDFView(frame: NSRect(x: 0, y: 0, width: 700, height: 900))
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        window.contentView = view
        m.pdf.attach(view)
        let key = MarkKey(version: m.stateVersion, showChanges: m.showChanges)
        m.pdf.update(url: m.pdfURL, key: key)
        view.layoutSubtreeIfNeeded()
        let find = m.pdf.find
        // a word of a few matches a page, so they are highlighted ("the", 49 on a page, would not be)
        m.findInPaper("with")
        settle(find)
        let r2 = try XCTUnwrap(view.document)
        let n2 = r2.findString("with", withOptions: [.caseInsensitive, .diacriticInsensitive]).count
        XCTAssertEqual(find.counter, "1 of \(n2)")
        XCTAssertTrue(m.hasPDFSelection, "the match is a selection, so the floating toolbar can comment on it")
        let marks = (0..<r2.pageCount).map { r2.page(at: $0)?.annotations.count ?? 0 }
        XCTAssertGreaterThan(marks.reduce(0, +), 0, "the fixture's marks are drawn")
        // round 1's PDF, as the round menu shows it
        let r1url = StepTests.fixtures.appendingPathComponent("round1/main.pdf")
        m.pdf.update(url: r1url, key: key)
        XCTAssertEqual(find.query, "with", "the query stays")
        XCTAssertEqual(find.highlighted.count, 0, "round 2's highlights went with its PDF")
        settle(find)
        let r1 = try XCTUnwrap(view.document)
        XCTAssertFalse(r1 === r2)
        let n1 = r1.findString("with", withOptions: [.caseInsensitive, .diacriticInsensitive]).count
        XCTAssertNotEqual(n1, n2, "the rounds' texts differ")
        XCTAssertEqual(find.count, n1)
        XCTAssertNil(find.index, "none shown until Return: the PDF opens where it opens")
        XCTAssertFalse(find.ringShown, "round 2's outline went with its PDF")
        XCTAssertEqual(find.counter, "\(n1) matches")
        XCTAssertEqual(find.highlighted.count, n1)
        XCTAssertTrue(find.highlighted.inShownDocument)
        find.step(previous: false)
        XCTAssertEqual(find.counter, "1 of \(n1)")
        XCTAssertTrue(view.currentSelection?.pages.first?.document === r1)
        // and back to round 2: its marks were not touched by the find
        m.pdf.update(url: m.pdfURL, key: key)
        settle(find)
        XCTAssertEqual(find.count, n2)
        let again = try XCTUnwrap(view.document)
        XCTAssertEqual((0..<again.pageCount).map { again.page(at: $0)?.annotations.count ?? 0 }, marks)
        // no PDF (a round that did not build)
        m.pdf.update(url: nil, key: key)
        XCTAssertEqual(find.query, "with")
        XCTAssertNil(find.count)
        XCTAssertEqual(find.counter, "")
        XCTAssertFalse(find.isSearching)
    }
}
