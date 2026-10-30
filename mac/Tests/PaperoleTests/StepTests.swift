import AppKit
import PDFKit
import SwiftUI
import XCTest
@testable import Paperole

/// A J/K step's cost (UX.md §10.9, BACKLOG O1): the card is laid out in the key's own turn of the run loop and the PDF
/// follows in the next; a new selection redraws no page; the tab picker is measured once. Synthetic fixtures only.
@MainActor
final class StepTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Fixtures")

    private var window: NSWindow!
    private var view: ReviewPDFView!

    private func makeView() throws -> ReviewPDFView {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 900), styleMask: [.titled], backing: .buffered,
                          defer: false)
        let v = ReviewPDFView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(v)
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        return v
    }

    /// Round 2 of the engine's synthetic test paper (`state-m2a.json`), its PDF and marks shown in a PDF view.
    private func makeModel() throws -> AppModel {
        var o = LaunchOptions()
        o.fixture = Self.fixtures.appendingPathComponent("state-m2a.json").path
        let model = AppModel(options: o)
        view = try makeView()
        model.pdf.attach(view)
        model.pdf.update(url: model.pdfURL, key: MarkKey(version: model.stateVersion, showChanges: model.showChanges))
        view.layoutDocumentView()
        XCTAssertNotNil(view.document)
        XCTAssertGreaterThan(model.panel.listed.count, 3)
        return model
    }

    private func turnRunLoop() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

    /// Every page's annotations, in order: taking a mark off its page and putting it back changes the order.
    private func annotations() -> [[ObjectIdentifier]] {
        guard let doc = view.document else { return [] }
        return (0..<doc.pageCount).map { doc.page(at: $0)?.annotations.map(ObjectIdentifier.init) ?? [] }
    }

    func testStepShowsTheCardAtOnceAndThePDFOnTheNextTurn() throws {
        let model = try makeModel()
        let first = model.panel.listed[0].id
        model.move(1)
        XCTAssertEqual(model.selection, .comment(first))
        XCTAssertEqual(model.panel.expanded, first)
        XCTAssertEqual(model.pdf.selectedMarks, [], "the PDF follows after the card's turn")
        XCTAssertFalse(model.pdf.flashing)
        turnRunLoop()
        XCTAssertEqual(model.pdf.selectedMarks, [first])
        XCTAssertTrue(model.pdf.flashing)
    }

    func testHeldKeyMovesThePDFOnceToTheLastStep() throws {
        let model = try makeModel()
        let third = model.panel.listed[2].id
        model.move(1)
        model.move(1)
        model.move(1)
        XCTAssertEqual(model.panel.expanded, third)
        turnRunLoop()
        XCTAssertEqual(model.pdf.selectedMarks, [third])
    }

    func testAClickCancelsAPendingStep() throws {
        let model = try makeModel()
        let clicked = model.panel.listed[3].id
        model.move(1)
        model.markClicked(clicked)  // before the step's PDF part ran
        XCTAssertEqual(model.pdf.selectedMarks, [clicked])
        turnRunLoop()
        XCTAssertEqual(model.pdf.selectedMarks, [clicked], "the step's PDF part must not undo the click")
    }

    func testSelectingRedrawsNoPage() throws {
        let model = try makeModel()
        let before = annotations()
        XCTAssertFalse(before.joined().isEmpty)
        for _ in 0..<4 {
            model.move(1)
            turnRunLoop()
        }
        model.move(-1)
        turnRunLoop()
        XCTAssertEqual(annotations(), before, "no mark is taken off its page or put back")
        XCTAssertEqual(model.pdf.selectedMarks, [model.panel.listed[2].id])
    }

    /// The outline round a selected mark (UX.md §5; POLISH §2.2): one 2 pt contour round the union of its lines with
    /// the paper's white in the 1 pt between, a square round a point note, and a ring round its label, each the same.
    func testSelectionOutlineBoxes() {
        let line = CGRect(x: 100, y: 500, width: 200, height: 10)
        let point = CGRect(x: 50, y: 60, width: 0, height: 0)
        let label = CGRect(x: 80, y: 500, width: 18, height: 9)
        XCTAssertEqual(SelectionOutline.boxes(lines: [line, point], label: label), [
            OutlineView.Box(rect: CGRect(x: 99.5, y: 499.5, width: 201, height: 11), width: 1,
                            points: [CGPoint(x: 99.5, y: 510.5), CGPoint(x: 300.5, y: 510.5), CGPoint(x: 300.5, y: 499.5),
                                     CGPoint(x: 99.5, y: 499.5)], paper: true),
            OutlineView.Box(rect: CGRect(x: 98, y: 498, width: 204, height: 14), width: 2,
                            points: [CGPoint(x: 98, y: 512), CGPoint(x: 302, y: 512), CGPoint(x: 302, y: 498),
                                     CGPoint(x: 98, y: 498)]),
            OutlineView.Box(rect: CGRect(x: 45, y: 55, width: 10, height: 10), width: 1, paper: true),
            OutlineView.Box(rect: CGRect(x: 43.5, y: 53.5, width: 13, height: 13), corner: 1, width: 2),
            OutlineView.Box(rect: CGRect(x: 79.5, y: 499.5, width: 19, height: 10), corner: 2, width: 1, paper: true),
            OutlineView.Box(rect: CGRect(x: 78, y: 498, width: 22, height: 13), corner: 3, width: 2),
        ])
        XCTAssertEqual(SelectionOutline.boxes(lines: [line], label: nil).count, 2)
    }

    /// Three lines of a mark (starting mid-line, ending mid-line) make one contour: the lines meet halfway between them
    /// and the edges step at their ends. A word in another font on the same line joins its line.
    func testOneContourRoundAMarkOfSeveralLines() {
        let lines = [CGRect(x: 300, y: 600, width: 150, height: 10), CGRect(x: 450, y: 599, width: 50, height: 11),
                     CGRect(x: 100, y: 586, width: 400, height: 10), CGRect(x: 100, y: 572, width: 150, height: 10)]
        let boxes = SelectionOutline.boxes(lines: lines, label: nil)
        XCTAssertEqual(boxes.map(\.paper), [true, false])  // the white gap, then the accent
        XCTAssertEqual(boxes[1].points, [CGPoint(x: 298, y: 612), CGPoint(x: 502, y: 612), CGPoint(x: 502, y: 584),
                                         CGPoint(x: 252, y: 584), CGPoint(x: 252, y: 570), CGPoint(x: 98, y: 570),
                                         CGPoint(x: 98, y: 597.5), CGPoint(x: 298, y: 597.5)])
        XCTAssertEqual(boxes[1].rect, CGRect(x: 98, y: 570, width: 404, height: 42))
        XCTAssertEqual(boxes[0].rect, CGRect(x: 99.5, y: 571.5, width: 401, height: 39))
        // from the end of one line to the start of the next without overlapping, or on into the next column: two
        let apart = [CGRect(x: 400, y: 600, width: 100, height: 10), CGRect(x: 100, y: 586, width: 100, height: 10)]
        XCTAssertEqual(SelectionOutline.boxes(lines: apart, label: nil).filter { !$0.paper }.count, 2)
        let columns = [CGRect(x: 60, y: 100, width: 220, height: 10), CGRect(x: 320, y: 700, width: 220, height: 10)]
        XCTAssertEqual(SelectionOutline.boxes(lines: columns, label: nil).filter { !$0.paper }.map(\.rect),
                       columns.map { $0.insetBy(dx: -2, dy: -2) })
    }

    /// Page-point widths follow the zoom, as a mark's lines do; the view's own width does not. The strokes are shape
    /// layers in the outline view.
    func testOutlineFollowsTheZoomInShapeLayers() throws {
        view = try makeView()
        view.document = PDFDocument(data: try Data(contentsOf: Self.fixtures.appendingPathComponent("round2/main.pdf")))
        let page = try XCTUnwrap(view.document?.page(at: 0))
        view.layoutDocumentView()
        let box = OutlineView.Box(rect: CGRect(x: 100, y: 500, width: 200, height: 10), width: 1.5)
        let o = OutlineView(width: 2)
        for scale in [1.0, 2.0] as [CGFloat] {
            view.autoScales = false
            view.scaleFactor = scale
            view.layoutDocumentView()
            XCTAssertTrue(o.place([box, OutlineView.Box(rect: CGRect(x: 100, y: 520, width: 50, height: 10))], on: page, in: view))
            let doc = try XCTUnwrap(view.documentView)
            XCTAssertTrue(o.superview === doc)
            let inDoc = doc.convert(view.convert(box.rect, from: page), from: view)
            let unit = inDoc.width / box.rect.width  // document points per page point
            XCTAssertEqual(o.strokes.count, 2)
            XCTAssertEqual(o.strokes[0].width, 1.5 * unit, accuracy: 0.01)
            XCTAssertEqual(o.strokes[1].width, 2)
            // on screen the mark's outline is 1.5 page points wide at any zoom
            let onScreen = view.convert(CGRect(x: 0, y: 0, width: o.strokes[0].width, height: 1), from: doc).width
            XCTAssertEqual(onScreen, 1.5 * scale, accuracy: 0.05)
            XCTAssertTrue(o.frame.contains(inDoc.insetBy(dx: -1.5 * unit + 0.01, dy: -1.5 * unit + 0.01)))
            XCTAssertEqual(o.strokes[0].path.boundingBox.integral, o.convert(inDoc, from: doc).integral)
            o.updateLayer()
            let shapes = (o.layer?.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
            XCTAssertEqual(shapes.count, 2)
            XCTAssertEqual(shapes[0].lineWidth, 1.5 * unit, accuracy: 0.01)
            XCTAssertEqual(shapes[1].lineWidth, 2)
            XCTAssertNil(shapes.first?.fillColor)
        }
        XCTAssertTrue(o.wantsUpdateLayer, "drawn by the render server, not in draw(_:)")
    }

    /// The tab picker's layout: the offered width (never below the narrowest), its own height, and the view measured
    /// again only when it changes, not each time the views beside it are laid out again.
    func testMeasuredOnceMeasuresOnlyWhenTheViewChanges() {
        let probe = Probe(), beside = Beside()
        let host = NSHostingController(rootView: VStack {
            HStack(spacing: 8) {
                MeasuredOnce { ProbeView(probe: probe) }
                BesideView(beside: beside)
            }
            .frame(width: 300)
            BesideView(beside: beside)
        })
        func width(_ proposed: CGFloat) -> CGFloat {
            NSHostingController(rootView: MeasuredOnce { ProbeView(probe: probe) })
                .sizeThatFits(in: CGSize(width: proposed, height: 100)).width
        }
        XCTAssertEqual(width(300), 300)
        XCTAssertEqual(width(10), 40, "never below its narrowest")
        _ = host.sizeThatFits(in: CGSize(width: 300, height: 400))
        let measured = probe.calls
        for i in 0..<5 {  // the views beside it change: the stacks lay out again
            beside.text = String(repeating: "word ", count: i + 2)
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            _ = host.sizeThatFits(in: CGSize(width: 300, height: 400 + CGFloat(i)))
        }
        // at most once a pass, to place it (an uncached picker was asked over 4 times a pass here, ~200 in the panel)
        XCTAssertLessThanOrEqual(probe.calls - measured, 5, "measured once")
        probe.wide = 60  // a longer label
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(width(10), 60)
        _ = host.sizeThatFits(in: CGSize(width: 300, height: 400))
        XCTAssertGreaterThan(probe.calls, measured, "measured again when it changed")
    }
}

/// A platform view whose narrowest width can change, and which counts how often it is measured (as an
/// NSSegmentedControl, it is asked again on every layout of the views around it).
@MainActor
private final class Probe: ObservableObject {
    @Published var wide: CGFloat = 40
    var calls = 0
}

private struct ProbeView: View {
    @ObservedObject var probe: Probe

    var body: some View { ProbeControl(probe: probe, narrowest: probe.wide) }
}

@MainActor
private final class Beside: ObservableObject {
    @Published var text = "word"
}

private struct BesideView: View {
    @ObservedObject var beside: Beside

    var body: some View { Text(beside.text) }
}

private struct ProbeControl: NSViewRepresentable {
    let probe: Probe
    let narrowest: CGFloat

    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        probe.calls += 1
        return CGSize(width: max(proposal.width ?? 120, narrowest), height: 22)
    }
}
