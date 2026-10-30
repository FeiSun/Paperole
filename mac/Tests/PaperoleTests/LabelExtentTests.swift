import AppKit
import PDFKit
import XCTest
@testable import Paperole

/// Id labels placed from the engine's text extent and ruler bounds (round.build.text_x and rulers) instead of the
/// page's text read through PDFKit (code review 2026-10-24, A2-10).
@MainActor
final class LabelExtentTests: XCTestCase {
    private var drafts: URL!

    override func setUpWithError() throws {
        drafts = FileManager.default.temporaryDirectory.appendingPathComponent("pc-labels-drafts-" + UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: drafts)
    }

    // MARK: labelBounds

    func testTheTextSpansTheBodyAndTheRulers() throws {
        let cb = CGRect(x: 0, y: 0, width: 612, height: 792)
        // ICLR's review ruler, as the engine gives it for the demo paper
        let iclr = try XCTUnwrap(PDFController.labelBounds(textX: [108, 504], rulers: [[73.13, 81.07, 86.43, 722.66], nil],
                                                           cropBox: cb))
        XCTAssertEqual(iclr.text.minX, 73.13, accuracy: 1e-9)
        XCTAssertEqual(iclr.text.maxX, 504, accuracy: 1e-9)
        XCTAssertEqual(iclr.left, Geometry.pdfKitRect([73.13, 81.07, 86.43, 722.66], cropBox: cb))
        XCTAssertNil(iclr.right)
        // ACL's rulers on both sides
        let acl = try XCTUnwrap(PDFController.labelBounds(textX: [70.47, 526.23],
                                                          rulers: [[12.2, 60, 25.5, 730], [566, 60, 580, 730]], cropBox: cb))
        XCTAssertEqual([acl.text.minX, acl.text.maxX], [12.2, 580])
        XCTAssertEqual(acl.right?.minX, 566)
        // no ruler: the body text; contract x counts from the crop box's left edge
        let shifted = CGRect(x: 20, y: 30, width: 612, height: 792)
        let plain = try XCTUnwrap(PDFController.labelBounds(textX: [72, 540], rulers: [nil, nil], cropBox: shifted))
        XCTAssertEqual([plain.text.minX, plain.text.maxX], [92, 560])
        XCTAssertNil(plain.left ?? plain.right)
    }

    func testWithoutTheEngineDataThePageTextIsRead() {
        let cb = CGRect(x: 0, y: 0, width: 612, height: 792)
        XCTAssertNil(PDFController.labelBounds(textX: [72, 540], rulers: nil, cropBox: cb), "a round from before rulers")
        XCTAssertNil(PDFController.labelBounds(textX: nil, rulers: [nil, nil], cropBox: cb), "a page without text_x")
        XCTAssertNil(PDFController.labelBounds(textX: [540, 72], rulers: [nil, nil], cropBox: cb))
        XCTAssertNil(PDFController.labelBounds(textX: [72, 540], rulers: [nil], cropBox: cb))
        XCTAssertNil(PDFController.labelBounds(textX: [72, 540], rulers: [[1, 2, 3], nil], cropBox: cb))
    }

    // MARK: The labels of a round

    /// The engine's layout of mac/Fixtures/round2/main.pdf (comments.layout): no ruler.
    private let textX: [[Double]?] = [[72.0, 540.0], [72.0, 540.01], [72.0, 540.03], [72.0, 540.05]]

    /// Each comment's label rect and size on the open round 2 fixture, with the view's text_x and rulers set as
    /// PDFPane sets them from round.build.
    private func labels(rulers: [[[Double]?]?]) throws -> [String: (page: Int, rect: CGRect, size: Int)] {
        _ = NSApplication.shared
        var o = LaunchOptions()
        o.fixture = StepTests.fixtures.appendingPathComponent("state-round2.json").path
        o.drafts = drafts.path
        let model = AppModel(options: o)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 700), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let v = ReviewPDFView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(v)
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.textX = textX
        v.rulers = rulers
        model.pdf.attach(v)
        model.pdf.update(url: model.pdfURL, key: MarkKey(version: model.stateVersion, showChanges: model.showChanges))
        let doc = try XCTUnwrap(v.document)
        var out: [String: (page: Int, rect: CGRect, size: Int)] = [:]
        for i in 0..<doc.pageCount {
            for case let a as MarkAnnotation in doc.page(at: i)?.annotations ?? [] {
                guard let label = a.label, let r = a.labelRect else { continue }
                out[String(label.suffix(5))] = (i, r, a.labelSize)  // the status glyph, then the id
            }
        }
        return out
    }

    func testTheEngineDataPutsTheLabelsWhereThePageTextDid() throws {
        let read = try labels(rulers: [])  // a round from before rulers: the page's text
        let known = try labels(rulers: Array(repeating: [nil, nil], count: 4))
        XCTAssertEqual(read.count, 12, "every comment with a page has a label")
        XCTAssertEqual(Set(read.keys), Set(known.keys))
        for (id, a) in read {
            let b = try XCTUnwrap(known[id])
            XCTAssertEqual(a.page, b.page, id)
            XCTAssertEqual(a.size, b.size, id)
            XCTAssertEqual(a.rect.minX, b.rect.minX, accuracy: 0.5, id)
            XCTAssertEqual(a.rect.minY, b.rect.minY, accuracy: 0.5, id)
        }
    }

    func testTheLabelsKeepClearOfTheEnginesRuler() throws {
        // a ruler the PDF does not have: labels follow the engine's data, not the page's text
        let ruler: [Double] = [40, 0, 70, 792]
        let read = try labels(rulers: Array(repeating: [nil, nil], count: 4))
        let known = try labels(rulers: Array(repeating: [ruler, nil], count: 4))
        let cb = CGRect(x: 0, y: 0, width: 612, height: 792)
        let box = try XCTUnwrap(Geometry.pdfKitRect(ruler, cropBox: cb)).insetBy(dx: -1, dy: -1)
        let left = read.filter { $0.value.rect.midX < cb.midX }
        XCTAssertFalse(left.isEmpty, "the fixture has labels in the left margin")
        XCTAssertTrue(left.values.contains { $0.rect.intersects(box) }, "where they were, they would cover it")
        for (id, l) in known where l.rect.midX < cb.midX {
            XCTAssertFalse(l.rect.intersects(box), id)
        }
    }
}
