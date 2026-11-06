import AppKit
import PDFKit
import XCTest
@testable import Paperole

/// The Finish sheet's final.pdf preview (design/summary-page): which comment a summary row names, on a synthetic
/// one-page PDF with rows like the engine's. Synthetic only.
@MainActor
final class FinalPreviewTests: XCTestCase {
    func testIdsInText() {
        XCTAssertEqual(PreviewPDFView.ids(in: "R1-05 follow-up p.1 §1 Still hard to follow"), ["R1-05"])
        XCTAssertEqual(PreviewPDFView.ids(in: "✓ R1-01 ✓ R12-104"), ["R1-01", "R12-104"])
        XCTAssertEqual(PreviewPDFView.ids(in: "p.3 “412k” → “386k”"), [])
        XCTAssertEqual(PreviewPDFView.ids(in: "XR1-05 R1-0"), [], "a whole id only")
    }

    /// A summary page with a row (its id first), a group's line of chips, a plain line, an unknown id and the reply
    /// rule; a click on the row's text shows its comment, on a chip that chip's, and elsewhere nothing.
    func testClickOnSummaryRows() throws {
        let doc = try XCTUnwrap(Self.summaryPDF())
        let v = PreviewPDFView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
        v.displayMode = .singlePageContinuous
        v.isSummary = { _ in true }
        v.document = doc
        v.ids = ["R1-05", "R1-01", "R1-02", "R1-03"]
        var shown: [String] = []
        v.pick = { shown.append($0) }
        XCTAssertEqual(v.click(page: 0, x: 300, y: 97), "R1-05", "the row's text: its one id")
        XCTAssertEqual(v.click(page: 0, x: 166, y: 137), "R1-01", "a chip in a line of two: the chip's")
        XCTAssertNil(v.click(page: 0, x: 200, y: 137), "between chips in a line of two: none")
        XCTAssertNil(v.click(page: 0, x: 100, y: 177), "a line without an id")
        XCTAssertNil(v.click(page: 0, x: 80, y: 217), "an id that is not the round's")
        XCTAssertNil(v.click(page: 0, x: 60, y: 257), "the reply rule's example names no comment")
        XCTAssertNil(v.click(page: 0, x: 300, y: 257), "nor the rest of its line")
        XCTAssertEqual(shown, ["R1-05", "R1-01"])
    }

    /// A page that is not a summary page never acts.
    func testPaperPagesAreLeftAlone() throws {
        let doc = try XCTUnwrap(Self.summaryPDF())
        let v = PreviewPDFView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
        v.document = doc  // no page label: not a summary page
        v.ids = ["R1-05"]
        XCTAssertNil(v.click(page: 0, x: 300, y: 97))
    }

    /// One Letter page drawn with Core Text.
    static func summaryPDF() -> PDFDocument? {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data), let ctx = CGContext(consumer: consumer, mediaBox: &box, nil)
        else { return nil }
        ctx.beginPDFPage(nil)
        let font = NSFont(name: "Helvetica", size: 9) ?? .systemFont(ofSize: 9)
        func put(_ s: String, _ x: CGFloat, _ yTop: CGFloat) {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font]))
            ctx.textPosition = CGPoint(x: x, y: 792 - yTop)
            CTLineDraw(line, ctx)
        }
        put("R1-05", 56, 100); put("follow-up", 112, 100); put("p.1", 170, 100)
        put("Still hard to follow: split it into two sentences.", 230, 100)
        put("Resolved 2", 48, 140); put("R1-01", 160, 140); put("R1-02", 420, 140)
        put("% R1-03 your note. Next round, send the full LaTeX source (zip) again.", 48, 260)
        put("No need to list what you fixed.", 48, 180)
        put("R9-99 is not this round's", 48, 220)
        ctx.endPDFPage()
        ctx.closePDF()
        return PDFDocument(data: data as Data)
    }
}
