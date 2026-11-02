import AppKit
import PDFKit
import SwiftUI

/// Read-only PDF of the round's build. The PDF is loaded with PDFDocument(data:) and never saved;
/// comment and change marks and the bars beside paragraphs to read are in-memory annotations only.
struct PDFPane: NSViewRepresentable {
    @ObservedObject var model: AppModel

    func makeNSView(context: Context) -> ReviewPDFView {
        let v = ReviewPDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displaysPageBreaks = true
        v.backgroundColor = Palette.pdfBackdrop  // the page is the brightest thing (POLISH §2.1)
        model.pdf.attach(v)
        return v
    }

    func updateNSView(_ v: ReviewPDFView, context: Context) {
        v.textX = model.round?.build.textX ?? []
        v.columns = model.round?.build.columns ?? []
        v.rulers = model.round?.build.rulers ?? []
        model.pdf.update(url: model.pdfURL, key: MarkKey(version: model.stateVersion, showChanges: model.showChanges,
                                                         checks: model.checkMarksVersion))
        model.pdf.setSelectedCheck(model.selectedCheckID, place: model.selectedCheckPlace)
    }
}

/// What the marks are drawn from, besides the selection: the state and the Changes toggle.
struct MarkKey: Equatable {
    var version: Int
    var showChanges: Bool
    var reanchor: String? = nil
    /// The checks' marks (`AppModel.checkMarksVersion`).
    var checks = 0
}

final class ReviewPDFView: PDFView {
    weak var controller: PDFController?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { MainActor.assumeIsolated { controller?.applyReviewHidden() } }
    }
    /// round.build.text_x: per page, [x0, x1] of the text in contract coordinates, or nil.
    var textX: [[Double]?] = []
    var columns: [[Double]?] = []
    /// round.build.rulers: per page, [left, right], the bounds of the margin line numbers beside text_x (contract
    /// coordinates), each nil when that side has none; nil for a page without text_x.
    var rulers: [[[Double]?]?] = []

    /// A single click, plain or with shift, is tracked here instead of by PDFView. PDFView starts and ends a selection
    /// at the character nearest the mouse: beside a review paper's line-number ruler that is a line number (the
    /// selection then takes in the ruler, the running head and the text from the top of the page), and right of a short
    /// line it is on the line above. It also ignores a drag that starts inside the current selection's bounding box.
    /// Here each end of a drag is kept on the text of its row (Geometry.clampedPoint). A click without a drag clears
    /// the selection and selects the comment whose mark or label is under it (UX.md §6). With shift, the selection runs
    /// from the current one's first character to the mouse, or, when the mouse is before that, from the mouse to the
    /// current one's end. ⌥-drag (or a plain drag after B) draws a box, and ⌥-click places a note (UX.md §7). A click
    /// on a link the round's link table knows previews its target (`PDFController.showPreview`, design/pdf-reader/PLAN.md
    /// §4); a click on its link again, the second click of a double click too, goes there (a URL's: the browser), and
    /// any other click closes the preview first. Without the table a click on a link within the PDF goes there through
    /// the app (`PDFController.followLink`: a step of Back). A drag from a link selects, its preview's link too. A click
    /// on a URL the table does not preview or another interactive annotation, a double or triple click, and a click
    /// with command or control go to PDFView.
    override func mouseDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.shift, .command, .control, .option])
        let ctl = controller
        if let p = pagePoint(event), MainActor.assumeIsolated({
            ctl?.previewClick(page: p.page, at: p.point, plain: modifiers.isEmpty, count: event.clickCount) ?? false
        }) {
            return
        }
        // a double click on a mark opens its comment, as the first click did: the second does not select a word under
        // it (which brought up the floating Comment toolbar; interaction review 2026-10-18)
        if event.clickCount > 1, let m = markClick, event.timestamp - m.time < NSEvent.doubleClickInterval,
           hypot(event.locationInWindow.x - m.point.x, event.locationInWindow.y - m.point.y) < 5 {
            markClick = (event.timestamp, m.point)
            return
        }
        markClick = nil
        if event.clickCount == 1, MainActor.assumeIsolated({ ctl?.canDrawBox ?? false }),
           modifiers == .option || (modifiers.isEmpty && MainActor.assumeIsolated({ ctl?.model?.toolbar.boxArmed ?? false })) {
            MainActor.assumeIsolated { ctl?.closePreview() }  // a press on its link left it open (`previewClick`)
            return trackBox(event, option: modifiers == .option)
        }
        if event.clickCount == 1, modifiers.isEmpty {
            clearSelection()
            MainActor.assumeIsolated { ctl?.dropPendingBox() }
        }
        guard event.clickCount == 1, modifiers.subtracting(.shift).isEmpty, let window, let doc = document,
              let start = pagePoint(event),
              !isInteractive(start) || MainActor.assumeIsolated({ ctl?.previewLink(page: start.page, at: start.point) }) != nil
        else { return super.mouseDown(with: event) }
        window.makeFirstResponder(self)
        let old = modifiers.contains(.shift) ? currentSelection : nil
        let anchor = old.flatMap(Self.firstCharacter) ?? clamped(start)
        func select(to e: NSEvent) {
            let end = pagePoint(e).map(clamped)
            var sel = end.flatMap { runs(from: anchor, to: $0, in: doc) ?? doc.selection(from: anchor.page, at: anchor.point,
                                                                                       to: $0.page, at: $0.point) }
            if let s = sel, let old, Self.startsBefore(s, old, in: doc) {
                sel = s.copy() as? PDFSelection  // add to a copy: once its ranges are read, add() leaves .string stale
                sel?.add(old)
            }
            guard let sel, !(sel.string ?? "").isEmpty else {
                return old == nil ? clearSelection() : setCurrentSelection(old, animate: false)
            }
            setCurrentSelection(sel, animate: false)
        }
        var moved = old != nil  // a shift-click extends the selection without a drag
        var last = event
        if moved { select(to: event) }
        while true {
            guard let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                                           until: Date(timeIntervalSinceNow: 0.05), inMode: .eventTracking, dequeue: true) else {
                // The mouse is held still: keep scrolling while it is outside the view. A mouse-up that never came
                // (the button is up) ends the drag.
                if NSEvent.pressedMouseButtons & 1 == 0 { break }
                if moved, documentView?.autoscroll(with: last) == true { select(to: last) }
                continue
            }
            let d = hypot(e.locationInWindow.x - event.locationInWindow.x, e.locationInWindow.y - event.locationInWindow.y)
            if moved || d >= 3 {
                if !moved { MainActor.assumeIsolated { ctl?.closePreview() } }  // a drag from its link selects
                moved = true
                last = e
                if e.type == .leftMouseDragged { documentView?.autoscroll(with: e) }
                select(to: e)
            }
            if e.type == .leftMouseUp { break }
        }
        if !moved, let l = MainActor.assumeIsolated({ ctl?.previewLink(page: start.page, at: start.point) }) {
            MainActor.assumeIsolated { ctl?.clickLink(l) }
        } else if !moved, let dest = start.page.annotations.first(where: { $0.type == "Link" && $0.bounds.contains(start.point) })
            .flatMap(Self.goTo) {
            MainActor.assumeIsolated { ctl?.followLink(dest) }
        } else if !moved, MainActor.assumeIsolated({ ctl?.click(page: start.page, at: start.point) }) != nil {
            markClick = (event.timestamp, event.locationInWindow)
        }
    }

    /// When and where the last click selected a comment's mark (`mouseDown`).
    private var markClick: (time: TimeInterval, point: NSPoint)?

    /// ⌥-drag: a rubber band kept to the start page. At least 8×8 pt it becomes a pending box; smaller, with ⌥, it is
    /// a ⌥-click (a note at the point). One that starts off the page (between pages, beside one) does nothing: its
    /// note or box would lie outside the page.
    private func trackBox(_ event: NSEvent, option: Bool) {
        guard let window, let start = pagePoint(event), start.page.bounds(for: .cropBox).contains(start.point) else { return }
        let ctl = controller
        window.makeFirstResponder(self)
        clearSelection()
        MainActor.assumeIsolated { ctl?.dropPendingBox() }
        let page = start.page, cb = page.bounds(for: .cropBox)
        func rect(_ e: NSEvent) -> CGRect {
            var p = convert(convert(e.locationInWindow, from: nil), to: page)
            p.x = min(max(p.x, cb.minX), cb.maxX)
            p.y = min(max(p.y, cb.minY), cb.maxY)
            return CGRect(x: min(p.x, start.point.x), y: min(p.y, start.point.y),
                          width: abs(p.x - start.point.x), height: abs(p.y - start.point.y))
        }
        MainActor.assumeIsolated { ctl?.rubberBand(page: page, rect: CGRect(origin: start.point, size: .zero)) }
        var r = CGRect(origin: start.point, size: .zero)
        while true {
            guard let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                                           until: Date(timeIntervalSinceNow: 0.05), inMode: .eventTracking, dequeue: true) else {
                if NSEvent.pressedMouseButtons & 1 == 0 { break }
                continue
            }
            r = rect(e)
            if e.type == .leftMouseUp { break }
            documentView?.autoscroll(with: e)
            let band = r
            MainActor.assumeIsolated { ctl?.rubberBand(page: page, rect: band) }
        }
        let final = r
        MainActor.assumeIsolated { ctl?.endBox(page: page, rect: final, start: start.point, option: option) }
    }

    /// The page nearest an event's location, and the location on it in page space.
    fileprivate func pagePoint(_ e: NSEvent) -> (page: PDFPage, point: CGPoint)? {
        let loc = convert(e.locationInWindow, from: nil)
        guard let page = page(for: loc, nearest: true) else { return nil }
        return (page, convert(loc, to: page))
    }

    /// A drag from one column of a page to the other, selected as two runs (Geometry.columnRuns), or nil.
    private func runs(from a: (page: PDFPage, point: CGPoint), to b: (page: PDFPage, point: CGPoint),
                      in doc: PDFDocument) -> PDFSelection? {
        let i = doc.index(for: a.page)
        guard a.page == b.page, i >= 0, i < columns.count, let c = columns[i], c.count == 2,
              let pairs = Geometry.columnRuns(a.point, b.point,
                                              lines: Geometry.lines(on: a.page, textX: i < textX.count ? textX[i] : nil),
                                              gap: a.page.bounds(for: .cropBox).minX + c[0]) else { return nil }
        let parts = pairs.compactMap { doc.selection(from: a.page, at: $0.0, to: a.page, at: $0.1) }
        guard parts.count == 2 else { return nil }
        parts[0].add(parts[1])
        return parts[0]
    }

    /// The point kept on the text of its row, with the page's round.build.text_x.
    private func clamped(_ p: (page: PDFPage, point: CGPoint)) -> (page: PDFPage, point: CGPoint) {
        let i = document?.index(for: p.page) ?? -1
        return (p.page, Geometry.clampedPoint(p.point, on: p.page, textX: i >= 0 && i < textX.count ? textX[i] : nil))
    }

    /// Whether PDFView acts on a click at the point: a URL's link, a form field, a note or an attachment. The app's
    /// marks (MarkAnnotation, a square) are not, nor a link within the PDF (`mouseDown` follows it).
    private func isInteractive(_ p: (page: PDFPage, point: CGPoint)) -> Bool {
        p.page.annotations.contains {
            ["Link", "Widget", "Text", "FileAttachment"].contains($0.type ?? "") && $0.bounds.contains(p.point) && Self.goTo($0) == nil
        }
    }

    /// A link's destination within the PDF; nil for a URL's link or anything else.
    static func goTo(_ a: PDFAnnotation) -> PDFDestination? {
        guard a.type == "Link" else { return nil }
        return a.destination ?? (a.action as? PDFActionGoTo)?.destination
    }

    /// Whether selection a starts before selection b.
    private static func startsBefore(_ a: PDFSelection, _ b: PDFSelection, in doc: PDFDocument) -> Bool {
        guard let pa = a.pages.first, let pb = b.pages.first, a.numberOfTextRanges(on: pa) > 0,
              b.numberOfTextRanges(on: pb) > 0 else { return false }
        let ia = doc.index(for: pa), ib = doc.index(for: pb)
        return ia != ib ? ia < ib : a.range(at: 0, on: pa).location < b.range(at: 0, on: pb).location
    }

    /// A point just inside a selection's first character (the start of its first line), and its page.
    private static func firstCharacter(_ sel: PDFSelection) -> (page: PDFPage, point: CGPoint)? {
        guard let line = sel.selectionsByLine().first, let page = line.pages.first else { return nil }
        let b = line.bounds(for: page)
        return b.isEmpty ? nil : (page, CGPoint(x: b.minX + min(0.5, b.width / 2), y: b.midY))
    }

    /// The app's own menu, by what is under the pointer (`PDFController.menu`; design/pdf-reader/PLAN.md §3). PDFView's
    /// (`super.menu(for:)`) selected the word nearest the click and added its stock items: zoom, page layouts, Search
    /// with Google and Translate (which send the text away).
    override func menu(for event: NSEvent) -> NSMenu? {
        var menu: NSMenu?
        MainActor.assumeIsolated { menu = controller?.menu(for: event) }
        return menu
    }

    /// ⌘-scroll zooms at the pointer (PLAN §3.6); a scroll without ⌘ scrolls, your own reading (`ownMove`).
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command), event.scrollingDeltaY != 0 else {
            MainActor.assumeIsolated { controller?.ownMove() }
            return super.scrollWheel(with: event)
        }
        let d = event.scrollingDeltaY / (event.hasPreciseScrollingDeltas ? 200 : 20)
        let p = convert(event.locationInWindow, from: nil)
        MainActor.assumeIsolated { controller?.zoom(by: exp(d), at: p) }
    }

    /// A pinch zooms as PDFView does it; the zoom it leaves is the paper's (`PDFController.pinched`).
    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        MainActor.assumeIsolated { controller?.pinched() }
    }

    /// The keys PDFView scrolls with (arrows, Space, Page Up and Down; the app's own keys never reach it): your own
    /// reading (`ownMove`).
    override func keyDown(with event: NSEvent) {
        MainActor.assumeIsolated { controller?.ownMove() }
        super.keyDown(with: event)
    }

    /// ⌘C (Edit › Copy): the selection's words cleaned (design/pdf-reader/PLAN.md P1.2, `CleanCopy`), not PDFKit's own
    /// copy with its line breaks, hyphens and line numbers.
    override func copy(_ sender: Any?) {
        guard let sel = currentSelection, let text = MainActor.assumeIsolated({ controller?.cleanText(sel) }), !text.isEmpty
        else { return super.copy(sender) }
        MainActor.assumeIsolated {
            AppModel.clipboard.clearContents()
            AppModel.clipboard.setString(text, forType: .string)
        }
    }

    /// ⌘= is Zoom In too, as ⌘+ (View › Zoom In takes ⌘+ only with shift).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
           event.charactersIgnoringModifiers == "=", window?.isKeyWindow == true, !isHiddenOrHasHiddenAncestor {
            MainActor.assumeIsolated { controller?.zoomStep(in: true) }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// A pointing hand over id labels, over the links a click previews (PDFView's own over the PDF's links) and over the
    /// bars of paragraphs to read (with the help tag "Mark read", POLISH §6), a crosshair while ⌥ is held (or box mode
    /// is armed) in an open round.
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateCursor(event)
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        updateCursor(event)
    }

    /// Focus makes the page larger, and keeps the reader's place when it starts or ends (PDFController.focusChanged):
    /// done here, in the layout that gives the view its new width, so the page never shows at the old scale first.
    override func layout() {
        super.layout()
        MainActor.assumeIsolated { controller?.viewLaidOut() }
    }

    private func updateCursor(_ event: NSEvent) {
        let ctl = controller
        let option = event.modifierFlags.contains(.option)
        guard let p = pagePoint(event) else { return }
        let bar = MainActor.assumeIsolated { () -> Bool in
            guard let ctl else { return false }
            let link = ctl.hoverLink(page: p.page, at: p.point)
            if ctl.canDrawBox && (option || ctl.model?.toolbar.boxArmed == true) {
                NSCursor.crosshair.set()
            } else if ctl.labelHit(page: p.page, at: p.point) || link {
                NSCursor.pointingHand.set()
            } else if ctl.barHit(page: p.page, at: p.point) != nil {
                NSCursor.pointingHand.set()
                return true
            }
            // the column's zones: a pointing hand, whichever of the two views sets the cursor last
            if let l = ctl.lane, l.group(at: l.convert(event.locationInWindow, from: nil)) != nil { NSCursor.pointingHand.set() }
            return false
        }
        let tip = bar ? "Mark read" : nil
        if toolTip != tip { toolTip = tip }
    }
}

private final class MenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func invoke() { run() }
}

/// The page the PDF shows, its page count and the paper's zoom (nil: Fit Width), for the status line under it (only
/// the line observes them).
@MainActor
final class PDFPosition: ObservableObject {
    @Published var page: Int?
    @Published var count = 0
    @Published var zoom: CGFloat?
}

/// Where Back goes after a jump (design/pdf-reader/PLAN.md §5.3), "p.4 · 2.1 Data": a link in the status line before
/// the page (design/review-page/BRIEF.md E4, decision D3 (a)). Only the link observes it.
@MainActor
final class BackChip: ObservableObject {
    @Published var label: String?
}

@MainActor
final class PDFController: NSObject, NSPopoverDelegate, NSWindowDelegate {
    weak var model: AppModel?
    let position = PDFPosition()
    /// Find in the paper (Find.swift): the toolbar's field and the matches in the PDF shown.
    let find = PaperFind()
    private(set) weak var view: ReviewPDFView?
    private var loadedKey: String?
    /// The path of the PDF shown (for --debug-script round).
    var loadedPath: String? { loadedKey.map { String($0[..<($0.lastIndex(of: "|") ?? $0.endIndex)]) } }
    /// The PDF shown, its path and modification time, and its bytes: the find searches a document of its own made from
    /// them (`PaperSearcher`).
    var documentKey: String? { view?.document == nil ? nil : loadedKey }
    private(set) var loadedData: Data?

    override init() {
        super.init()
        find.controller = self
    }
    private var markKey: MarkKey?
    private var marks: [(PDFPage, PDFAnnotation)] = []
    private var commentMarks: [String: (page: PDFPage, mark: MarkAnnotation)] = [:]
    /// The bars beside the paragraphs to read (UX.md §18), by block, with the parts they were drawn for and whether
    /// bold (the paragraph Next went to).
    private var readingMarks: [Int: (parts: [PageRect], bold: Bool, marks: [(PDFPage, MarkAnnotation)])] = [:]
    private var changeMarks: [String: PDFPage] = [:]
    private var shapes: [Int: [MarkShape]] = [:]  // page index → clickable areas of its comments
    /// The checks' marks by id (their first place's), and their clickable areas by page index (design/checks-ui).
    private var checkMarks: [String: [Int: (page: PDFPage, mark: MarkAnnotation)]] = [:]  // id → place → mark
    private var checkShapes: [Int: [MarkShape]] = [:]
    private var selectedCheck: String?
    private var selectedCheckPlace = 0
    private var changeAreas: [Int: [(id: String, rects: [CGRect], delete: Bool)]] = [:]
    private var placedLabels: [Int: [CGRect]] = [:]
    private var rulers: [Int: CGRect?] = [:]  // rulerBounds: page index × 2 + side
    private var selectedID: String?
    private var selectedChange: (id: String, page: PDFPage, rects: [CGRect])?
    private var pendingReveal: (page: Int?, rects: [[Double]])?
    /// A PDF just loaded is put at the top of its first page once the view has settled, unless it was moved first.
    private var opensAtTop = false
    private var pendingComment: (phrase: String, note: String?)?
    private var pendingScript: DebugScript?
    private var runningScript: DebugScript?  // the script holds its controller weakly; this keeps it alive
    /// --debug-marks off: no comment or change marks.
    var showMarks = true
    /// The column beside the scroller (design/review-page/BRIEF.md; mac/UX.md §42): its items and layout, and the shown
    /// PDF's page heights they are placed by; its view in the PDF view; when its window opens (`LaneHover`), the
    /// window's rows and its view; the click and key monitor while the window shows.
    let strip = ScrollerMarks()
    private var pageHeights: [Double] = []
    private(set) var lane: MarkLane?
    let laneHover = LaneHover()
    let laneWindow = LaneWindowModel()
    private(set) var laneWindowView: FloatView?
    private var laneMonitor: Any?
    /// When the PDF last scrolled: a window opens only once it has been still for the panel's 150 ms.
    private var lastScroll: TimeInterval = 0
    /// --debug-script striphover's `force`: the hover acts while the app is not active (a background run).
    var laneForced = false
    /// The find's Comment button hidden while the window covers it.
    private var laneHidToolbar = false
    private var selectedChangeID: String?
    /// The shown PDF's text, for Clean Copy's hyphens (`cleanText`), read once it is needed.
    private var docText: String?
    private var flash: (outlines: [OutlineView], timer: Timer, ticks: Int)?
    /// The way back (PLAN §5): which jumps record the place they leave (`PDFSteps`), the chip and the jump it is for
    /// (it goes after a scroll of more than two views from there), and a place for Back waiting for its PDF.
    private var steps = PDFSteps()
    let backChip = BackChip()
    private var chipTarget: (page: PDFPage, rect: CGRect)?
    private var pendingPlace: PDFPlace?
    /// The selected change's outline (UX.md §16), over the PDF in a view of its own like the flash.
    private var changeOutline: OutlineView?
    /// The selected comment's outline round its mark and id label (UX.md §5), a view of its own too: taking the mark off
    /// its page and putting it back with an outline made PDFKit redraw the whole page, every mark on it, on each J/K.
    private var selectionOutline: OutlineView?
    /// Set only here, and by a test to stand for a shown editor (no window is on screen in a test run).
    var popover: NSPopover?
    private(set) var draft: CommentDraft?
    private(set) var saveDraft: (() -> Void)?
    private(set) var toolbarView: NSView?
    private var toolbarTimer: Timer?
    /// The toolbar by a new comment's mark (MarkToolbar.swift, UX.md §8): what it shows, its view, and the comment it is
    /// for while it shows.
    let markBar = MarkToolbarModel()
    private(set) var markBarView: NSView?
    private(set) var markBarID: String?
    private(set) var pendingBox: (page: PDFPage, rect: CGRect, mark: MarkAnnotation)?
    private var rubber: (page: PDFPage, mark: MarkAnnotation)?
    private var observers: [NSObjectProtocol] = []
    /// Focus's page (POLISH §4.3; mockup §10: the page 1.3 times as large): the scale that fitted Review's width when
    /// Focus began; at Fit Width Focus shows 1.3 times it, never wider than the view (`applyZoom`).
    private var focusFit: CGFloat?
    /// Each paper's zoom in this run, by its path (design/pdf-reader/PLAN.md §3.6): absent, Fit Width. Never stored.
    private var zooms: [String: CGFloat] = [:]
    /// When Focus starts or ends: the view's width then (the new scale waits for a new width), the point a third of the
    /// way down the view, put back there at each new width while the panes settle (`until`), and the width it was last
    /// put back at; the width the scale was last fitted to in Focus.
    private var focusFrom: (width: CGFloat, keep: (page: Int, x: Double, y: Double)?, until: TimeInterval, applied: CGFloat)?
    private var focusWidth: CGFloat = 0

    /// The comment the last click without a drag selected, or nil, and the paragraph whose bar it marked read (for
    /// --debug-script click).
    private(set) var lastClick: String?
    private(set) var lastBar: Int?

    /// A box for a new comment waits for the engine; one to re-anchor to does not (Place waits instead).
    var canDrawBox: Bool { model?.roundIsOpen == true && (model?.busy == false || model?.toolbar.reanchor != nil) }

    /// Review hidden behind the overview (`AppModel.setLevel`, UX.md §21): the split view that holds the PDF and the
    /// panel is hidden in AppKit too, so their tracking areas, cursor rects and help tags do not act through the
    /// overview over them, and the keys leave the PDF. SwiftUI's own hiding would not do: `.hidden()` or a branch
    /// rebuilds the views, and `.opacity` or `.allowsHitTesting` moves them to another superview and leaves their
    /// tracking areas on. Kept, so a PDF view made while hidden (another paper, a round that now builds) is hidden at
    /// once (`ReviewPDFView.viewDidMoveToWindow`).
    private(set) var reviewHidden = false

    /// Review shown: the PDF view takes the keys, unless a text field has them (an editor, Jump's field) or Review is
    /// hidden behind the overview.
    func takeKeys() {
        guard let v = view, let w = v.window, !reviewHidden, !(w.firstResponder is NSText), w.firstResponder !== v else { return }
        w.makeFirstResponder(v)
    }

    func setReviewHidden(_ hidden: Bool) {
        reviewHidden = hidden
        applyReviewHidden()
    }

    func applyReviewHidden() {
        guard let v = view, v.window != nil else { return }
        let root = Self.reviewRoot(of: v)
        if root.isHidden != reviewHidden { root.isHidden = reviewHidden }
        guard reviewHidden else { return }
        hideToolbar()
        hideMarkBar()
        closePreview()
        laneHover.reset()
        closePinned()  // they would float over the overview, their Go to moving a PDF nobody sees
        if popover?.isShown == true { popover?.close() }  // a note being written never gets here (AppModel.waitsForNote)
        if let w = v.window, let r = w.firstResponder as? NSView, r === root || r.isDescendant(of: root) { w.makeFirstResponder(nil) }
    }

    /// The PDF's and the panel's split view (PaperView's HSplitView): the nearest split view round the PDF view.
    static func reviewRoot(of v: NSView) -> NSView {
        var s = v.superview
        while let x = s, !(x is NSSplitView) { s = x.superview }
        return s ?? v
    }

    func attach(_ v: ReviewPDFView) {
        let nc = NotificationCenter.default
        // a new view (another paper, Review again after the hub): the old one's observers go
        for o in observers { nc.removeObserver((o as? ClipObserver)?.token ?? o) }
        observers = []
        view = v
        v.controller = self
        attachLane(v)
        // the window or the app going to the back closes the column's window at once
        for name in [NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                let w = n.object as? NSWindow
                MainActor.assumeIsolated {
                    guard let self, w == nil || w === self.view?.window, !self.laneForced else { return }
                    self.closeLane()
                }
            })
        }
        observers.append(nc.addObserver(forName: .PDFViewSelectionChanged, object: v, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.selectionChanged() }
        })
        observers.append(nc.addObserver(forName: .PDFViewPageChanged, object: v, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pageChanged() }
        })
        observers.append(nc.addObserver(forName: .PDFViewScaleChanged, object: v, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hideToolbar()
                self?.hideMarkBar()
                self?.closePreview()
                self?.closeLane()  // a zoom closes the column's window at once
                self?.updateLaneHalo()  // the rail, when the page grew wider than the view
                self?.placeChangeOutline()
                self?.placeSelectionOutline()
                self?.find.placeRing()
            }
        })
    }

    /// The PDF's clip view, once the document is shown: scrolling it hides the floating toolbar.
    private func observeScrolling() {
        guard let clip = view?.documentView?.enclosingScrollView?.contentView,
              !observers.contains(where: { ($0 as? ClipObserver)?.clip === clip }) else { return }
        clip.postsBoundsChangedNotifications = true
        let token = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip,
                                                           queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hideToolbar()
                self?.hideMarkBar()
                self?.closePreview()
                self?.pageChanged()  // only the status line observes the page
                self?.lastScroll = ProcessInfo.processInfo.systemUptime  // the column's window waits for it to settle
                self?.model?.pdfScrolled()
                self?.checkChip()
            }
        }
        observers.append(ClipObserver(clip: clip, token: token))
        // the scroller dragged (a scroll gesture comes through `scrollWheel` too): your own reading
        if let sv = clip.enclosingScrollView {
            observers.append(NotificationCenter.default.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: sv,
                                                                    queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.ownMove() }
            })
        }
    }

    private final class ClipObserver: NSObject {
        weak var clip: NSClipView?
        let token: NSObjectProtocol
        init(clip: NSClipView, token: NSObjectProtocol) { self.clip = clip; self.token = token }
    }

    private func pageChanged() {
        let doc = view?.document
        let page = shownPage
        if position.page != page { position.page = page }
        if position.count != doc?.pageCount ?? 0 { position.count = doc?.pageCount ?? 0 }
    }

    /// The page the status line names: the one a third of the way down the view, where the Contents' current section
    /// is read too (`pointAtThird`). PDFView's `currentPage` did not follow a scroll of its clip view (a selected card
    /// revealed with `ScrollAnimator`): after a card scrolled the PDF back to p.7 the line still said p.8 until the
    /// PDF was scrolled by hand (BACKLOG O32).
    var shownPage: Int? {
        guard let v = view, let doc = v.document else { return nil }
        let p = CGPoint(x: v.bounds.midX, y: v.bounds.maxY - v.bounds.height / 3)
        return (v.page(for: p, nearest: true) ?? v.currentPage).map { doc.index(for: $0) }
    }

    private func selectionChanged() {
        let text = view?.currentSelection?.string ?? ""
        let has = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if model?.hasPDFSelection != has { model?.hasPDFSelection = has }
        if has {
            hideMarkBar()  // the selection's toolbar takes its place
            scheduleToolbar()
        } else if pendingBox == nil {
            hideToolbar()
        }
    }

    func clearSelection() { view?.clearSelection() }

    // MARK: Document and marks

    func update(url: URL?, key input: MarkKey) {
        guard let v = view else { return }
        var key: String?
        if let url {
            let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            key = url.path + "|" + String(mtime?.timeIntervalSince1970 ?? 0)
        }
        if key != loadedKey {
            find.documentWillChange()  // its highlights and match are this PDF's
            loadedKey = key
            closePreview()
            closePinned()
            laneHover.reset()
            hovered = nil
            stopFlash()
            steps = PDFSteps()
            hideChip()
            dropPendingBox()
            hideMarkBar()
            selectedChange = nil
            placeChangeOutline()
            marks = []
            commentMarks = [:]
            readingMarks = [:]
            markKey = nil
            placeSelectionOutline()
            pageHeights = []
            docText = nil
            if let url, let data = try? Data(contentsOf: url), let doc = PDFDocument(data: data) {
                Self.hideLinkBoxes(doc)
                v.document = doc
                applyZoom()  // this paper's
                loadedData = data
                find.documentChanged()  // the query is found again in this PDF
                opensAtTop = true
                // Keys go to the PDF, not the papers list (where arrow keys would switch papers), unless a text field
                // has them.
                whenSettled { [weak self, weak v] in
                    self?.holdPanel()
                    // The page re-zooms once the panes have settled and was left scrolled about 155 pt down, through the
                    // author line (UI review 2026-10-24): once that has settled too, its top is put back at the view's
                    // top, unless a reveal (a comment, a change, a section, the last place) or a place came first, or
                    // the view was scrolled on to another page meanwhile.
                    self?.whenSettled { [weak self] in
                        guard let self, self.opensAtTop, self.shownPage == 0 else { return }
                        self.place(page: 0, rect: [0, 0, 0, 0], fromTop: 0)
                    }
                    // not while Review is hidden behind the overview (UX.md §21): the papers list keeps them there
                    guard let v, let w = v.window, !(w.firstResponder is NSText), self?.reviewHidden != true else { return }
                    w.makeFirstResponder(v)
                }
            } else {
                v.document = nil
                loadedData = nil
                find.documentChanged()
            }
            pageChanged()
        }
        var k = input
        k.reanchor = model?.toolbar.reanchor
        if v.document != nil, k != markKey { rebuildMarks(k) }
        if v.document != nil { observeScrolling() }
        if let r = pendingReveal, v.document != nil {
            pendingReveal = nil
            whenSettled { [weak self] in self?.reveal(page: r.page, rects: r.rects) }
        }
        if let p = pendingPlace, v.document != nil {
            pendingPlace = nil
            whenSettled { [weak self] in self?.go(to: p) }
        }
        if let pending = pendingComment, v.document != nil, model?.roundIsOpen == true {
            pendingComment = nil
            whenSettled { [weak self] in self?.selectAndComment(pending.phrase, note: pending.note) }
        }
        if v.document != nil, model?.pendingFocus == true {
            model?.pendingFocus = false
            whenSettled { [weak self] in self?.model?.setFocus(true) }
        }
        if let s = pendingScript, v.document != nil {
            pendingScript = nil
            runningScript = s
            whenSettled { s.start() }
        }
    }

    /// hyperref's link boxes read as box marks (PLAN §4.1; final.pdf hides them too): drawn with no border, in memory
    /// only. Not `shouldDisplay = false`, which PDFKit also takes as "not clickable".
    static func hideLinkBoxes(_ doc: PDFDocument) {
        for i in 0..<doc.pageCount {
            for a in doc.page(at: i)?.annotations ?? [] where a.type == "Link" && (a.border?.lineWidth ?? 0) > 0 {
                let none = PDFBorder()
                none.lineWidth = 0
                a.border = none
            }
        }
    }

    /// Re-anchor mode starts or ends: the old mark is drawn dashed while it lasts.
    func refreshMarks() {
        guard let m = markKey else { return }
        var k = m
        k.reanchor = model?.toolbar.reanchor
        if k != markKey { rebuildMarks(k) }
    }

    private func rebuildMarks(_ k: MarkKey) {
        guard let v = view, let doc = v.document, let model else { return }
        defer {
            placeChangeOutline()  // shown with the change marks only
            placeSelectionOutline()
            updateReadingBars()
            placeMarkBar()  // the comment's new style, or gone
            updateStrip()
        }
        if k.showChanges != markKey?.showChanges { closeLane() }  // change marks turned on or off
        for (page, a) in marks { page.removeAnnotation(a) }
        marks = []
        commentMarks = [:]
        checkMarks = [:]
        checkShapes = [:]
        changeMarks = [:]
        shapes = [:]
        changeAreas = [:]
        placedLabels = [:]
        rulers = [:]
        markKey = k
        guard showMarks else { return }
        let st = model.state
        if k.showChanges {
            for ch in st?.changes ?? [] {
                let style: MarkAnnotation.Style = ch.kind == "delete" ? .cross : (ch.unrequested ? .unrequested : .band)
                let color = ch.kind == "delete" ? Palette.deletion : (ch.unrequested ? Palette.unrequestedBand : Palette.attachedChange)
                guard let (page, idx, rs) = pageRects(doc, ch.page, ch.rects) else { continue }
                let a = MarkAnnotation(rects: rs, style: style, fill: color, ink: color)
                page.addAnnotation(a)
                marks.append((page, a))
                changeMarks[ch.id] = page
                changeAreas[idx, default: []].append((ch.id, rs, ch.kind == "delete"))
            }
        }
        var later: [(PDFPage, MarkAnnotation)] = []  // the comments' marks: their labels placed first, drawn last
        for (order, c) in (st?.comments ?? []).enumerated() {
            guard let (page, idx, rs) = pageRects(doc, c.page, c.rects) else { continue }
            let status = Status(c)
            let point = rs.allSatisfy { $0.width < 1 && $0.height < 1 }
            let style: MarkAnnotation.Style
            if c.anchorState == "gone" {
                style = .gone
            } else {
                switch c.markKind {
                case .highlight: style = .highlight
                case .underline: style = .underline
                case .strikeout: style = .strike
                case .box: style = .box
                case .note: style = point ? .sticky : .textNote
                }
            }
            // The label is in the comment's own ink with its status as a glyph: in the status colours it was read as
            // a mark colour next to a mark of the same hue (resolved green, new blue).
            let labels = MarkAnnotation.labels(c.id, glyph: status.glyph)
            let (lr, size) = labelRect(labels, beside: rs[0], on: page, index: idx)
            let a = MarkAnnotation(rects: rs, style: style, fill: c.markColor.fill, ink: c.markColor.ink,
                                   label: labels[size], labelRect: lr, labelColor: c.markColor.ink, labelSize: size)
            a.faded = status.closed
            a.dashed = c.id == k.reanchor
            later.append((page, a))  // added after the checks' marks, so it lies over them
            marks.append((page, a))
            commentMarks[c.id] = (page, a)
            var s = [MarkShape.label(c.id, lr, order: order)]
            switch style {
            case .gone: s.append(.caret(c.id, rs[0], order: order))
            case .sticky: s.append(.point(c.id, CGPoint(x: rs[0].midX, y: rs[0].midY), order: order))
            case .box: s.append(.box(c.id, rs, order: order))
            default: s.append(.text(c.id, rs, order: order))
            }
            shapes[idx, default: []] += s
        }
        // the checks that go to the student: Paperole's slate highlight and a square label, placed after the comments'
        // labels (a comment's never moves for a check's) and drawn under the comments' marks
        for (order, c) in model.checkMarks.enumerated() {
            guard let id = c.id else { continue }
            let glyph = c.status.glyph
            for (k, place) in c.places.enumerated() where !place.rects.isEmpty {
                guard let (page, idx, rs) = pageRects(doc, place.page, place.rects) else { continue }
                let labels = MarkAnnotation.labels(id, glyph: glyph)
                let (lr, size) = labelRect(labels, beside: rs[0], on: page, index: idx)
                let a = MarkAnnotation(rects: rs, style: .highlight, fill: Palette.checkFill, ink: Palette.checkInk,
                                       label: labels[size], labelRect: lr, labelColor: Palette.checkInk, labelSize: size)
                a.square = true
                page.addAnnotation(a)
                marks.append((page, a))
                checkMarks[id, default: [:]][k] = (page, a)
                checkShapes[idx, default: []] += [.label(id, lr, order: order), .text(id, rs, order: order)]
            }
        }
        for (page, a) in later { page.addAnnotation(a) }
    }

    /// The bars beside the paragraphs to read (UX.md §18): added and removed one by one as paragraphs are read or
    /// unread, so C redraws only its page. Each part of a paragraph (a column, a page) gets its own bar; the paragraph
    /// Next went to has a bolder one (POLISH §3 row 3).
    func updateReadingBars() {
        guard let v = view, let doc = v.document, let model else { return }
        let want = showMarks ? Dictionary(model.barParagraphs.map { ($0.block, $0.parts) }, uniquingKeysWith: { a, _ in a }) : [:]
        let bold = model.currentParagraph
        for (b, drawn) in readingMarks where want[b] != drawn.parts || drawn.bold != (b == bold) {
            for (page, a) in drawn.marks { page.removeAnnotation(a) }
            readingMarks[b] = nil
        }
        // every paragraph's parts by page, read or not, so a bar never moves when another paragraph is read (Reading.bar)
        let onPage = want.isEmpty ? [:] : Dictionary(grouping: model.paragraphs.flatMap(\.parts), by: \.page)
        for (b, parts) in want where readingMarks[b] == nil {
            var drawn: [(PDFPage, MarkAnnotation)] = []
            for part in parts where part.valid && part.page >= 0 && part.page < doc.pageCount {
                guard let page = doc.page(at: part.page) else { continue }
                let tx = part.page < v.textX.count ? v.textX[part.page] : nil
                let gap = part.page < v.columns.count ? v.columns[part.page]?.first : nil
                let bar = Reading.bar(part, textX: tx, gap: gap, beside: onPage[part.page] ?? [], bold: b == bold)
                guard let r = Geometry.pdfKitRect(bar, cropBox: page.bounds(for: .cropBox)) else { continue }
                let a = MarkAnnotation(rects: [r], style: .reading, fill: Palette.readingBar, ink: Palette.readingBar)
                page.addAnnotation(a)
                drawn.append((page, a))
            }
            readingMarks[b] = (parts, b == bold, drawn)
        }
    }

    /// The paragraph whose bar is under a point, in an open round (POLISH §6: a click marks it read; `MarkHit.barArea`);
    /// of two bars side by side (beside a wrapped float), the nearer.
    func barHit(page: PDFPage, at p: CGPoint) -> Int? {
        guard let v = view, let model, model.roundIsOpen, model.toolbar.reanchor == nil else { return nil }
        let minSize = 8 / max(v.scaleFactor, 0.01), mid = page.bounds(for: .cropBox).midX
        var best: (block: Int, distance: CGFloat)?
        for (b, drawn) in readingMarks {
            for (pg, a) in drawn.marks where pg === page {
                for r in a.lines {
                    guard MarkHit.barArea(r, textRight: r.midX < mid, minSize: minSize).contains(p) else { continue }
                    let d = abs(p.x - r.midX)
                    if best.map({ d < $0.distance }) ?? true { best = (b, d) }
                }
            }
        }
        return best?.block
    }

    /// For --debug-script: the blocks that have bars, and the bars' pages and rects (contract coordinates).
    var readingBars: [(block: Int, page: Int, rect: [Double])] {
        guard let doc = view?.document else { return [] }
        return readingMarks.sorted { $0.key < $1.key }.flatMap { b, drawn in
            drawn.marks.compactMap { page, a in
                a.lines.first.map { (b, doc.index(for: page), Geometry.contractRect($0, cropBox: page.bounds(for: .cropBox))) }
            }
        }
    }

    private func pageRects(_ doc: PDFDocument, _ index: Int?, _ rects: [[Double]]) -> (PDFPage, Int, [CGRect])? {
        guard let index, index >= 0, index < doc.pageCount, let page = doc.page(at: index) else { return nil }
        let cb = page.bounds(for: .cropBox)
        let rs = rects.compactMap { Geometry.pdfKitRect($0, cropBox: cb) }
        return rs.isEmpty ? nil : (page, index, rs)
    }

    /// The check selected on the Checks tab gets the same outline while no comment is selected.
    func setSelectedCheck(_ id: String?, place: Int = 0) {
        guard id != selectedCheck || place != selectedCheckPlace else { return }
        selectedCheck = id
        selectedCheckPlace = place
        placeSelectionOutline()
    }

    /// The selected comment's mark gets an accent outline; no page is redrawn.
    func setSelected(_ id: String?) {
        if markBarID != nil && id != markBarID { hideMarkBar() }
        guard id != selectedID else { return }
        selectedID = id
        placeSelectionOutline()
        updateLaneHalo()
    }

    /// Lays the selected comment's outline over its mark again (a new selection, new marks, a zoom). In re-anchor mode
    /// only the label's ring: the old place is drawn dashed.
    private func placeSelectionOutline() {
        let m = selectedID.flatMap { commentMarks[$0] } ?? selectedCheck.flatMap { id in
            checkMarks[id].flatMap { $0[selectedCheckPlace] ?? $0.min { $0.key < $1.key }?.value }
        }
        let boxes = m.map { SelectionOutline.boxes(lines: $0.mark.dashed ? [] : $0.mark.lines, label: $0.mark.labelRect) } ?? []
        guard let m, !boxes.isEmpty else {
            selectionOutline?.removeFromSuperview()
            selectionOutline = nil
            return
        }
        let o = selectionOutline ?? OutlineView(width: 2)
        if !o.place(boxes, on: m.page, in: view) { o.removeFromSuperview() }
        selectionOutline = o
    }

    /// The selected change gets a lasting accent outline while it is selected (UX.md §16): a view over the PDF, so
    /// no page is redrawn. nil removes it.
    func setSelectedChange(_ id: String?) {
        if selectedChangeID != id {
            selectedChangeID = id
            updateLaneHalo()
        }
        guard id != selectedChange?.id else { return }
        selectedChange = nil
        if let id, let ch = model?.change(id), let doc = view?.document, let (page, _, rs) = pageRects(doc, ch.page, ch.rects) {
            selectedChange = (id, page, rs)
        }
        placeChangeOutline()
    }

    /// Lays the selected change's outline over its words again (a new selection, a zoom).
    private func placeChangeOutline() {
        // an unasked edit that waits keeps its outline with change marks off, as it keeps its ring (D2)
        guard let s = selectedChange, showMarks, markKey?.showChanges != false || waits(s.id) else {
            changeOutline?.removeFromSuperview()
            changeOutline = nil
            return
        }
        let o = changeOutline ?? OutlineView(width: 2)
        if !o.place(s.rects.flatMap { SelectionOutline.ring($0) }, on: s.page, in: view) { o.removeFromSuperview() }
        changeOutline = o
    }

    /// An unasked edit of the open round not handled yet (`ChangeModel.handled`): it waits on you (BRIEF D2).
    func waits(_ changeID: String) -> Bool {
        guard let model, model.roundIsOpen else { return false }
        return model.changes.unrequested.first { $0.id == changeID }.map { !$0.handled } ?? false
    }

    /// For --debug-script dump: the comments whose marks are drawn as selected, and the change outlined.
    var selectedMarks: [String] {
        (selectionOutline?.superview != nil ? [selectedID ?? ""] : [])
            + (changeOutline?.superview != nil ? [selectedChange?.id ?? ""] : [])
    }

    /// At launch the window still resizes and autoScales re-zooms, which would undo a scroll; wait until the
    /// view's size has been stable for one tick.
    func whenSettled(lastSize: CGSize? = nil, tries: Int = 0, _ action: @escaping () -> Void) {
        guard let v = view else { return }
        let size = v.bounds.size
        if size.height > 0 && v.window != nil && (size == lastSize || tries >= 20) {
            action()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.whenSettled(lastSize: size, tries: tries + 1, action)
        }
    }

    /// Id labels sit in the page margin nearest the mark, level with its first line, so they never cover text or a
    /// margin ruler's numbers (Geometry.labelPlace): outside all of the page's text, between the body text
    /// (round.build.text_x) and the ruler, or past the ruler; in smaller type (`labels`, MarkAnnotation.labelFonts)
    /// when only that fits (a ruler close to the text: ACL, ICML, ACM review); labels on one line side by side, else a
    /// line apart. The page's text and ruler come from the engine (round.build.text_x and rulers, `labelBounds`); only
    /// without them is the page's text read (PDFKit: 0.3–0.6 s before the first frame of a 20–30 page paper). Returns
    /// the rect and the index of the label used.
    private func labelRect(_ labels: [String], beside first: CGRect, on page: PDFPage, index: Int) -> (rect: CGRect, size: Int) {
        let cb = page.bounds(for: .cropBox)
        let tx = index < (view?.textX.count ?? 0) ? view?.textX[index] : nil
        let known = Self.labelBounds(textX: tx, rulers: index < (view?.rulers.count ?? 0) ? view?.rulers[index] : nil,
                                     cropBox: cb)
        let text = known?.text ?? page.selection(for: cb)?.bounds(for: page) ?? cb.insetBy(dx: 72, dy: 72)
        func size(_ s: String, _ font: NSFont, pad: CGFloat) -> CGSize {
            let z = (s as NSString).size(withAttributes: [.font: font])
            return CGSize(width: ceil(z.width) + pad, height: ceil(z.height))
        }
        let left = first.midX < text.midX
        let ruler: CGRect? = known.map { left ? $0.left : $0.right } ?? rulerBounds(page, index: index, left: left, textX: tx)
        let placed = placedLabels[index] ?? []
        let sizes = labels.indices.map { size(labels[$0], MarkAnnotation.labelFonts[$0], pad: 2 * MarkAnnotation.labelPads[$0]) }
        let r = Geometry.labelPlace(sizes: sizes, first: first, text: text, textX: tx, ruler: ruler, cropBox: cb, placed: placed)
        placedLabels[index] = placed + [r.rect]
        return r
    }

    /// A page's text and margin rulers for its id labels (PDFKit page space), from round.build's text_x and rulers:
    /// `text` spans all of the page's words, the body text and the line numbers beside it (only its x is used), and
    /// `left`, `right` are the line numbers left and right of text_x. nil when the round has no such data for the page.
    nonisolated static func labelBounds(textX t: [Double]?, rulers r: [[Double]?]?, cropBox cb: CGRect)
        -> (text: CGRect, left: CGRect?, right: CGRect?)? {
        guard let t, t.count == 2, t[0] <= t[1], let r, r.count == 2, r.allSatisfy({ ($0?.count ?? 4) == 4 }) else { return nil }
        let left = r[0].flatMap { Geometry.pdfKitRect($0, cropBox: cb) }
        let right = r[1].flatMap { Geometry.pdfKitRect($0, cropBox: cb) }
        let x0 = min(cb.minX + t[0], left?.minX ?? .infinity), x1 = max(cb.minX + t[1], right?.maxX ?? -.infinity)
        return (CGRect(x: x0, y: cb.minY, width: x1 - x0, height: cb.height), left, right)
    }

    /// The bounds of a page's words outside text_x on one side (a review ruler's line numbers), or nil; per page. Read
    /// from the page's text, for a round without round.build.rulers (`labelBounds`).
    private func rulerBounds(_ page: PDFPage, index: Int, left: Bool, textX t: [Double]?) -> CGRect? {
        let key = index * 2 + (left ? 0 : 1)
        if let found = rulers[key] { return found }
        var out: CGRect?
        if let t, t.count == 2, t[0] <= t[1] {
            let cb = page.bounds(for: .cropBox)
            let strip = left ? CGRect(x: cb.minX, y: cb.minY, width: max(0, t[0] - 1), height: cb.height)
                : CGRect(x: cb.minX + t[1] + 1, y: cb.minY, width: max(0, cb.width - t[1] - 1), height: cb.height)
            if strip.width > 0, let sel = page.selection(for: strip),
               !(sel.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let b = sel.bounds(for: page)
                out = b.isNull || b.isEmpty ? nil : b
            }
        }
        rulers[key] = .some(out)
        return out
    }

    // MARK: Clicks on marks (UX.md §6)

    /// A click without a drag: the comment under it (labels first, cycling through overlapping marks), else the bar of a
    /// paragraph to read, which it marks read (POLISH §6), else on the Changes tab the change under it. Returns the
    /// comment id, or nil.
    @discardableResult
    func click(page: PDFPage, at p: CGPoint) -> String? {
        lastClick = nil
        lastBar = nil
        hideMarkBar()  // a click elsewhere puts it away; one on a new comment's mark shows it there
        // in re-anchor mode a click places nothing and selects no other comment (the bar names the one being moved)
        guard let v = view, let doc = v.document, let model, model.toolbar.reanchor == nil else { return nil }
        let idx = doc.index(for: page)
        let minSize = 8 / max(v.scaleFactor, 0.01)
        let all = shapes[idx] ?? [], areas = changeAreas[idx] ?? []
        func comment(_ s: [MarkShape]) -> String? {
            MarkHit.pick(MarkHit.hits(at: p, shapes: s, minSize: minSize), selected: selectedID)
        }
        // On the Changes tab the changed words are what is clicked: id labels first, then the changes, then the
        // comments' marks. On the Comments tab the comments come first, and a change's band switches to Changes.
        let onChanges = model.tab == .changes
        let labels = all.filter { $0.group == .label }
        if let id = comment(labels) {
            lastClick = id
            model.markClicked(id)
            showMarkBar(id)
            return id
        }
        if let b = barHit(page: page, at: p) {  // the bars are in the margin, beside the text
            lastBar = b
            model.barClicked(b)
            return nil
        }
        if !onChanges, let id = comment(all) {
            lastClick = id
            model.markClicked(id)
            showMarkBar(id)
            return id
        }
        if let ch = areas.first(where: { MarkHit.changeHit(at: p, rects: $0.rects, isDelete: $0.delete, whole: onChanges,
                                                           minSize: onChanges ? minSize : 0) }) {
            lastClick = ch.id
            model.tab = .changes
            model.select(.change(ch.id), reveal: false, scroll: .centre, flash: true)
            return nil
        }
        if onChanges, let id = comment(all) {
            lastClick = id
            model.markClicked(id)
            showMarkBar(id)
            return id
        }
        // a check's mark, under every comment's and change's (design/checks-ui): its card on the Checks tab
        if let id = MarkHit.pick(MarkHit.hits(at: p, shapes: checkShapes[idx] ?? [], minSize: minSize), selected: selectedCheck) {
            model.checkMarkClicked(id)
            return nil
        }
        return nil
    }

    func labelHit(page: PDFPage, at p: CGPoint) -> Bool {
        guard let v = view, let doc = v.document else { return false }
        let labels = (shapes[doc.index(for: page)] ?? []).filter { $0.group == .label }
        return !MarkHit.hits(at: p, shapes: labels, minSize: 8 / max(v.scaleFactor, 0.01)).isEmpty
    }

    // MARK: Focus (POLISH §3 row 5, §4.3)

    /// Focus starts or ends: the place being read is noted, and the scale changes in the layout that gives the view
    /// its new width (no animated resize, POLISH §2.5).
    func focusChanged(_ on: Bool) {
        closeLane()
        guard let v = view, v.document != nil else { return }
        focusFrom = (v.bounds.width, pointAtThird(), ProcessInfo.processInfo.systemUptime + 0.3, v.bounds.width)
        if on { focusFit = zoom == nil ? v.scaleFactor : v.scaleFactorForSizeToFit }
        holdPanel()
        // whatever the layouts did meanwhile, nothing is left half done
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.viewLaidOut(force: true) }
    }

    /// The panel keeps its width when the sidebar goes or comes (Focus, POLISH §7: the page takes the room, and the card
    /// is not laid out again) and when the window is resized, as an inspector does: its holding priority in the split
    /// view is above the PDF's. Left equal, the split view shared each change out between the two, and again later
    /// (the panel drifted by 40–50 pt over a Focus switch). The split view is its controller's (SwiftUI's HSplitView),
    /// whose items hold the priorities. Set once the window has settled with a document shown (set at launch, the
    /// panel kept its minimum width while the window grew to its size), and before a Focus switch.
    func holdPanel() {
        guard let items = splitItems, items[1].holdingPriority <= items[0].holdingPriority else { return }
        items[1].holdingPriority = NSLayoutConstraint.Priority(min(items[0].holdingPriority.rawValue + 10, 999))
        openPanel()
    }

    /// The panel's width when its split view first settles (BACKLOG O30: it opened at the split view's share, 497 or
    /// 520 pt in a 1440 pt window, not its ideal 400): the ideal, or the width it was last given in this run (another
    /// paper's split view is a new one), within its limits and the PDF's minimum. Then the widths the advisor gives it
    /// by dragging the divider are remembered, outside Focus (`dividerDragged`).
    private func openPanel() {
        guard model?.focus != true, let split = reviewSplit, let now = panelWidth else { return }
        let want = Self.openingWidth(remembered: Self.panelWidthUsed, split: split.bounds.width, divider: split.dividerThickness)
        if abs(want - now) >= 1 {
            split.setPosition(split.bounds.width - want - split.dividerThickness, ofDividerAt: 0)
            split.layoutSubtreeIfNeeded()
        }
        if let old = splitObserver { NotificationCenter.default.removeObserver(old) }
        splitWidth = split.bounds.width
        splitObserver = NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: split,
                                                           queue: .main) { [weak self, weak split] _ in
            MainActor.assumeIsolated {
                guard let self, let split else { return }
                let before = self.splitWidth
                self.splitWidth = split.bounds.width
                guard self.model?.focus != true, let w = self.panelWidth,
                      Self.dividerDragged(NSApp.currentEvent, in: split, widthBefore: before) else { return }
                Self.panelWidthUsed = w
            }
        }
        Self.panelWidthUsed = panelWidth
    }

    private var splitObserver: NSObjectProtocol?
    private var splitWidth: CGFloat = 0  // the review's split view's width at its last resize

    /// A resize of the review's split view that the advisor made by dragging its divider: during a drag of the mouse
    /// (or its release) in its window, not a live resize of the window, and with the split view as wide as before
    /// (dragging the sidebar's edge makes it wider or narrower). A width the window or the sidebar forced on the
    /// panel is not remembered (review, 2026-10-18: after a narrow window, the next paper opened with a 339 pt panel).
    static func dividerDragged(_ event: NSEvent?, in split: NSSplitView, widthBefore: CGFloat) -> Bool {
        guard let e = event, e.type == .leftMouseDragged || e.type == .leftMouseUp, let window = split.window,
              e.window === window, !window.inLiveResize else { return false }
        return abs(split.bounds.width - widthBefore) < 0.5
    }

    /// The panel's last width in this run, outside Focus (nil before any panel opened).
    static var panelWidthUsed: CGFloat?

    /// The width a panel opens at: the last one used, else the ideal 400, within the panel's 320–560 and leaving the
    /// PDF its minimum.
    nonisolated static func openingWidth(remembered: CGFloat?, split: CGFloat, divider: CGFloat) -> CGFloat {
        let most = min(560, split - divider - WindowLayout.pdf)
        return max(WindowLayout.panel, min(remembered ?? 400, most))
    }

    /// The panel's width now (nil when the review's split view is not there: tests, a fixture without a window).
    var panelWidth: CGFloat? {
        guard let w = splitItems?[1].viewController.view.frame.width, w > 0 else { return nil }
        return w
    }

    /// The PDF's and the panel's items of the review's split view.
    private var splitItems: [NSSplitViewItem]? {
        guard let c = reviewSplit?.delegate as? NSSplitViewController, c.splitViewItems.count == 2 else { return nil }
        return c.splitViewItems
    }

    /// The split view of the PDF and the panel (the window's sidebar is in another, further out).
    private var reviewSplit: NSSplitView? {
        var v = view?.superview
        while let s = v {
            if let sp = s as? NSSplitView, sp.isVertical { return sp }
            v = s.superview
        }
        return nil
    }

    /// After the PDF view's layout: in Focus the page is 1.3 times its Review scale (`applyZoom`, again whenever the
    /// view's width changes); when Focus ends, the paper's zoom again. While the panes settle after the switch, the
    /// place being read is put back a third of the way down the view at each new width.
    func viewLaidOut(force: Bool = false) {
        guard let v = view, v.document != nil, v.bounds.width > 0 else { return }
        placeLane()  // a new size, or the scroller's style changed (a mouse plugged in)
        let width = v.bounds.width
        if let f = focusFrom, width == f.applied { if force { focusFrom = nil }; return }  // no new width
        if model?.focus == true, focusFit != nil {
            if width != focusWidth {
                focusWidth = width
                applyZoom()
            }
        } else if focusFit != nil {
            focusFit = nil
            focusWidth = 0
            applyZoom()
        }
        guard let f = focusFrom else { return }
        if force || ProcessInfo.processInfo.systemUptime > f.until { focusFrom = nil } else { focusFrom?.applied = width }
        if let k = f.keep { putAtThird(k) }
    }

    // MARK: Zoom (design/pdf-reader/PLAN.md §3.6)

    /// The shown paper's zoom in Review (Focus shows it 1.3 times as large); nil: Fit Width.
    var zoom: CGFloat? { model?.selectedPath.flatMap { zooms[$0] } }

    /// View › Zoom In, Zoom Out, Actual Size and Fit Width (nil), and the status line's menu: the paper's zoom, the
    /// point a third of the way down the view kept where it is.
    func setZoom(_ z: CGFloat?) {
        guard let path = model?.selectedPath, view?.document != nil else { return }
        let keep = pointAtThird()
        zooms[path] = z.map(ZoomRules.clamped)
        applyZoom()
        if let keep { putAtThird(keep) }
    }

    /// Zoom In (`in`) or Out: the next step from the zoom shown, or Fit Width when it comes first (`ZoomRules.step`).
    func zoomStep(in up: Bool) {
        guard let v = view, v.document != nil else { return }
        let focus = model?.focus == true
        let now = zoom ?? v.scaleFactor / (focus ? ZoomRules.focus : 1)
        let fit = focus ? focusFit ?? now : v.scaleFactorForSizeToFit
        setZoom(ZoomRules.step(from: now, fit: fit, up: up))
    }

    /// ⌘-scroll: the zoom `factor` times as large, the point under the pointer (`at`, in the view) staying under it.
    func zoom(by factor: CGFloat, at p: CGPoint) {
        guard let v = view, let doc = v.document, let path = model?.selectedPath, let page = v.page(for: p, nearest: true)
        else { return }
        let focus = model?.focus == true ? ZoomRules.focus : 1
        let q = v.convert(p, to: page)
        zooms[path] = ZoomRules.clamped(v.scaleFactor / focus * factor)
        applyZoom()
        put(doc.index(for: page), q, at: p)
    }

    /// A pinch has zoomed the page (PDFView's own): its scale is the paper's zoom, held within 50–400% as the others.
    func pinched() {
        guard let v = view, v.document != nil, !v.autoScales, let path = model?.selectedPath else { return }
        zooms[path] = ZoomRules.clamped(v.scaleFactor / (model?.focus == true ? ZoomRules.focus : 1))
        applyZoom()
    }

    /// The page's scale for the paper's zoom: Fit Width fits the view and refits with it (`autoScales`); in Focus 1.3
    /// times as large, at Fit Width never wider than the view.
    private func applyZoom() {
        guard let v = view, v.document != nil else { return }
        let z = zoom
        var scale = z
        if model?.focus == true, let fit = focusFit {
            scale = z.map { $0 * ZoomRules.focus } ?? min(v.scaleFactorForSizeToFit, fit * ZoomRules.focus)
        }
        if let scale {
            if v.autoScales { v.autoScales = false }
            if abs(v.scaleFactor - scale) > 0.001 { v.scaleFactor = scale }
        } else if !v.autoScales {
            v.autoScales = true
        }
        if position.zoom != z { position.zoom = z }
    }

    /// Puts a place (page index and contract point, `pointAtThird`) back a third of the way down the view, centred.
    private func putAtThird(_ k: (page: Int, x: Double, y: Double)) {
        guard let v = view, let doc = v.document, k.page >= 0, k.page < doc.pageCount, let pg = doc.page(at: k.page) else { return }
        let cb = pg.bounds(for: .cropBox)
        put(k.page, CGPoint(x: cb.minX + CGFloat(k.x), y: cb.maxY - CGFloat(k.y)),
            at: CGPoint(x: v.bounds.midX, y: v.bounds.maxY - v.bounds.height / 3))
    }

    /// Scrolls so the point `q` of page `index` (page space) is at the point `target` of the view, as near as the
    /// document allows; a scroll still animating ends first.
    private func put(_ index: Int, _ q: CGPoint, at target: CGPoint) {
        guard let v = view, let pg = v.document?.page(at: index) else { return }
        v.layoutDocumentView()
        guard let clip = v.documentView?.enclosingScrollView?.contentView, let sv = clip.enclosingScrollView else { return }
        let now = clip.convert(v.convert(q, from: pg), from: v), want = clip.convert(target, from: v)
        var b = clip.bounds
        b.origin.x += now.x - want.x
        b.origin.y += now.y - want.y
        ScrollAnimator.stop(sv)  // a reveal still animating would scroll on from the old place
        clip.scroll(to: clip.constrainBoundsRect(b).origin)
        sv.reflectScrolledClipView(clip)
    }

    // MARK: Reveal and flash

    /// Scrolls to a mark only when it is outside the view inset by 30 pt, putting it a third of the way down, animated
    /// over 0.25 s when the distance is at most 1.5 view heights; then flashes it (UX.md §6 PDF scroll). A scroll still
    /// animating to the last mark ends where it is first (J pressed twice within 0.25 s, held J/K): on its next step it
    /// would carry the view to the last mark, past this one. `step`: what the move is for Back (PLAN §5.2; nil: none).
    func reveal(page: Int?, rects: [[Double]], step: PDFSteps.Kind? = nil) {
        // After a round is picked in the toolbar, its PDF is loaded on the next update: reveal there.
        guard let v = view, let doc = v.document, let path = model?.pdfURL?.path, loadedKey?.hasPrefix(path + "|") == true
        else {
            pendingReveal = (page, rects)
            return
        }
        guard let page, page >= 0, page < doc.pageCount, let pg = doc.page(at: page) else { return }
        willMove()
        let cb = pg.bounds(for: .cropBox)
        let rs = rects.compactMap { Geometry.pdfKitRect($0, cropBox: cb) }
        guard let first = rs.first else {
            willJump(step, to: pg, rect: CGRect(x: cb.minX, y: cb.maxY, width: cb.width, height: 0))
            v.go(to: pg)
            return
        }
        let union = rs.dropFirst().reduce(first) { $0.union($1) }
        willJump(step, to: pg, rect: union)
        let inView = v.convert(union, from: pg)
        if !v.bounds.insetBy(dx: 0, dy: 30).contains(inView) {
            let reduce = Motion.reduced
            let clip = v.documentView?.enclosingScrollView?.contentView
            // How far the visible area moves so the mark's top lands a third of the way down (clip coordinates).
            let delta = clip.map { clip -> CGFloat in
                let m = clip.convert(inView, from: v), b = clip.bounds
                return clip.isFlipped ? m.minY - (b.minY + b.height / 3) : m.maxY - (b.maxY - b.height / 3)
            } ?? .infinity
            if let clip, abs(delta) <= 1.5 * clip.bounds.height, !reduce {
                var b = clip.bounds
                b.origin.y += delta
                if let sv = clip.enclosingScrollView {
                    ScrollAnimator.scroll(sv, to: clip.constrainBoundsRect(b).origin, duration: 0.25)
                }
            } else {
                let visible = v.bounds.height / max(v.scaleFactor, 0.01)
                let top = min(union.maxY + visible / 3, cb.maxY)
                v.go(to: PDFDestination(page: pg, at: CGPoint(x: cb.minX, y: top)))
            }
        }
        startFlash(rs, on: pg)
    }

    /// A click on a mark: flash it where it is.
    func flash(page: Int?, rects: [[Double]]) {
        guard let doc = view?.document, let (pg, _, rs) = pageRects(doc, page, rects) else { return }
        startFlash(rs, on: pg)
    }

    var flashing: Bool { flash != nil }

    /// The point a third of the way down the view, centred across it: page index and contract coordinates (the
    /// Contents' current section).
    func pointAtThird() -> (page: Int, x: Double, y: Double)? {
        guard let v = view, let doc = v.document else { return nil }
        let p = CGPoint(x: v.bounds.midX, y: v.bounds.maxY - v.bounds.height / 3)
        guard let page = v.page(for: p, nearest: true) else { return nil }
        let q = v.convert(p, to: page), cb = page.bounds(for: .cropBox)
        return (doc.index(for: page), Double(q.x - cb.minX), Double(cb.maxY - q.y))
    }

    /// Puts a box's top a third of the way down the view, or `fromTop` points below the top; no flash. A scroll still
    /// animating (a reveal) ends first, or it would carry the view back. `step`: what the move is for Back.
    func place(page: Int, rect: [Double], fromTop: CGFloat? = nil, step: PDFSteps.Kind? = nil) {
        guard let v = view, let doc = v.document, page >= 0, page < doc.pageCount, let pg = doc.page(at: page),
              let r = Geometry.pdfKitRect(rect, cropBox: pg.bounds(for: .cropBox)) else { return }
        willJump(step, to: pg, rect: r)
        willMove()
        let scale = max(v.scaleFactor, 0.01)
        let above = fromTop.map { $0 / scale } ?? v.bounds.height / scale / 3
        v.go(to: PDFDestination(page: pg, at: CGPoint(x: pg.bounds(for: .cropBox).minX, y: min(r.maxY + above, pg.bounds(for: .cropBox).maxY))))
    }

    /// Before the view is moved another way: the PDF's animated scroll (`ScrollAnimator`) ends where it is, and a PDF
    /// just loaded no longer goes to its top.
    private func willMove() {
        opensAtTop = false
        if let sv = view?.documentView?.enclosingScrollView { ScrollAnimator.stop(sv) }
    }

    /// Whether a mark is on screen.
    func isVisible(page: Int?, rects: [[Double]]) -> Bool {
        guard let v = view, let doc = v.document, let (pg, _, rs) = pageRects(doc, page, rects) else { return false }
        return v.bounds.intersects(v.convert(rs[0], from: pg))
    }

    // MARK: The way back (design/pdf-reader/PLAN.md §5)

    /// The place being read: the point a third of the way down the view, the paper's zoom and its label.
    func currentPlace() -> PDFPlace? {
        guard let k = pointAtThird() else { return nil }
        return PDFPlace(page: k.page, x: k.x, y: k.y, zoom: zoom,
                        label: model?.placeLabel(page: k.page, x: k.x, y: k.y) ?? "p.\(k.page + 1)")
    }

    /// Before a jump to `rect` of `page` (PDFKit page space): the place being left becomes a step of Back when
    /// `PDFSteps` says so, the chip then naming it. The chip goes with any other jump, except the next cards of a run
    /// that has its step: Back still goes there, and the chip follows the run. Only in Review shown; nil `kind`: no step.
    private func willJump(_ kind: PDFSteps.Kind?, to page: PDFPage, rect: CGRect) {
        if kind != nil { jumps &+= 1 }
        if kind == .run, steps.run?.recorded == true, chipTarget != nil {
            chipTarget = (page, rect)
            return
        }
        hideChip()
        guard let kind, !reviewHidden, model?.level == .review, let here = currentPlace(), let v = view,
              let clip = v.documentView?.enclosingScrollView?.contentView else { return }
        let target = clip.convert(v.convert(rect, from: page), from: v)
        guard let at = steps.jump(kind, from: here, near: { [weak self] p in
            self?.visible(at: p).map { PDFSteps.isNear(target, visible: $0) } ?? true
        }) else { return }
        model?.recordPDFStep(at)
        chipTarget = (page, rect)
        backChip.label = at.label
    }

    /// The view's area (its clip view's coordinates) with the place a third of the way down it.
    private func visible(at p: PDFPlace) -> CGRect? {
        guard let v = view, let doc = v.document, p.page >= 0, p.page < doc.pageCount, let pg = doc.page(at: p.page),
              let clip = v.documentView?.enclosingScrollView?.contentView else { return nil }
        let cb = pg.bounds(for: .cropBox)
        let at = clip.convert(v.convert(CGPoint(x: cb.minX + p.x, y: cb.maxY - p.y), from: pg), from: v)
        let third = clip.convert(CGPoint(x: v.bounds.midX, y: v.bounds.maxY - v.bounds.height / 3), from: v)
        return clip.bounds.offsetBy(dx: at.x - third.x, dy: at.y - third.y)
    }

    private func hideChip() {
        chipTarget = nil
        if backChip.label != nil { backChip.label = nil }
    }

    /// On each scroll, only while the chip shows: it goes once its jump's target is more than two views from the
    /// third of the view where it landed.
    private func checkChip() {
        guard let t = chipTarget, let v = view else { return }
        if abs(v.convert(t.rect, from: t.page).maxY - (v.bounds.maxY - v.bounds.height / 3)) > 2 * v.bounds.height { hideChip() }
    }

    /// A scroll or a key of your own: the next run through the cards records where it starts.
    func ownMove() {
        steps.ownMove()
        ownMoves &+= 1
    }

    /// Counts your own scrolls and keys, and the jumps you make (a look-up or a run: `willJump`; Back and Forward:
    /// `go(to:)`), so a place that arrives late (`AppModel.follow`) is not forced on you.
    private(set) var ownMoves = 0
    private(set) var jumps = 0

    /// Review left, another paper or round, Back or Forward: no run under way, no chip, no place waiting.
    func endSteps() {
        steps = PDFSteps()
        pendingPlace = nil
        hideChip()
    }

    /// A click on one of the PDF's links within it, or the link menu's Go to: the app goes there itself, so the place
    /// it leaves is a step of Back (PDFKit's own history stays unused), the target a third of the way down.
    func followLink(_ dest: PDFDestination) {
        guard let v = view, let pg = dest.page else { return }
        let cb = pg.bounds(for: .cropBox)
        let y = dest.point.y.isFinite && dest.point.y <= cb.maxY ? dest.point.y : cb.maxY  // unspecified: the page's top
        willJump(.lookUp, to: pg, rect: CGRect(x: cb.minX, y: y, width: cb.width, height: 0))
        willMove()
        v.go(to: PDFDestination(page: pg, at: CGPoint(x: cb.minX, y: min(y + v.bounds.height / max(v.scaleFactor, 0.01) / 3, cb.maxY))))
    }

    /// Lays the column beside the scroller again (BRIEF §3): after the marks are drawn again, Find's matches change or
    /// the view resizes; never on a scroll. Find's matches while it has a query, else the open round's comments to
    /// check and unasked edits that wait (rings, with change marks off too: D2) and, with change marks shown, the edits.
    func updateStrip() {
        var items: [ScrollerMark] = []
        let findMode = find.open && FindRules.searchable(find.query)
        if let v = view, let doc = v.document, let model, showMarks {
            if pageHeights.count != doc.pageCount {
                pageHeights = (0..<doc.pageCount).map { Double(doc.page(at: $0)?.bounds(for: .cropBox).height ?? 0) }
            }
            func add(_ m: ScrollerMark, _ top: Double?) {
                guard let top, let f = ScrollerMarks.fraction(page: m.page, top: top, heights: pageHeights) else { return }
                var m = m
                m.fraction = f
                items.append(m)
            }
            func top(_ rects: [[Double]]) -> Double? { rects.compactMap { $0.count == 4 ? $0[1] : nil }.min() }
            if findMode {
                let hits = find.hitPlaces
                for (i, h) in hits.enumerated() {
                    let cb = doc.page(at: h.page)?.bounds(for: .cropBox) ?? .zero
                    add(ScrollerMark(kind: .find, fraction: 0, target: .find(i), page: h.page, label: "Match \(i + 1) of \(hits.count)"),
                        Double(cb.maxY - h.bounds.maxY))
                }
            } else {
                let shown = markKey?.showChanges == true
                let models = Dictionary((model.changes.unrequested + model.changes.linked).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                for ch in model.state?.changes ?? [] {
                    guard let page = ch.page else { continue }
                    let waits = ch.unrequested && model.roundIsOpen && !(models[ch.id]?.handled ?? true)
                    guard shown || waits else { continue }
                    let label = models[ch.id]?.accessibility ?? ch.id
                    add(ScrollerMark(kind: ch.unrequested ? .unasked : .edit, fraction: 0, target: .change(ch.id), page: page,
                                     label: label, waits: waits, tick: shown, answers: ch.attachedTo.first), top(ch.rects))
                }
                let cards = Dictionary(model.panel.cards.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                for c in model.state?.comments ?? [] where model.roundIsOpen && Status(c) == .toCheck {  // vermilion: your move
                    guard let page = c.page else { continue }
                    add(ScrollerMark(kind: .toCheck, fraction: 0, target: .comment(c.id), page: page,
                                     label: cards[c.id]?.accessibility ?? c.id), top(c.rects))
                }
                // the checks the student answered: your move too (design/checks-ui), at their first place with rects
                for c in model.checksToCheck {
                    guard let id = c.id, let p = c.places.first(where: { !$0.rects.isEmpty }) else { continue }
                    add(ScrollerMark(kind: .toCheck, fraction: 0, target: .check(id), page: p.page,
                                     label: "\(id), still found, the student answered: " + c.text), top(p.rects))
                }
            }
        }
        let wasFind = strip.find, old = laneHover.shown.map { shownTargets($0) }
        if strip.set(items, height: laneHeight, find: findMode) {
            lane?.set(strip.items, layout: strip.layout, find: findMode)
            if wasFind != findMode || findMode {
                closeLane()  // Find opened or closed, or its query changed
            } else if let old {  // the group changed under the pointer: its rows in place, or the window closes
                let now = strip.layout.groups.firstIndex { g in g.members.contains { old.contains(strip.items[$0].target) } }
                laneHover.remap(shown: now)
                if laneHover.shown != nil { showLaneRows() }
            }
        }
        placeLane()
        updateLaneHalo()
    }

    /// A click on a marker, a row of its window or a VoiceOver element: the comment or edit selected as Jump selects
    /// it, or Find's match shown; a step of Back.
    func goMark(_ t: ScrollerMark.Target) {
        guard let model else { return }
        switch t {
        case .comment(let id):
            model.tab = .comments
            model.select(.comment(id), scroll: .centre, step: .lookUp)
        case .change(let id):
            model.tab = .changes
            model.select(.change(id), scroll: .centre, step: .lookUp)
        case .find(let i): find.goTo(i)
        case .check(let id):
            model.checkMarkClicked(id)
            if let i = model.checks.index(of: id) { model.checkClicked(i) }  // its place, a step of Back, the flash
        }
    }

    /// A selection's words for Copy (`CleanCopy`): its lines in contract coordinates, with each page's text column.
    func cleanText(_ sel: PDFSelection) -> String? {
        guard let v = view, let doc = v.document else { return nil }
        let lines: [CleanCopy.Line] = sel.selectionsByLine().compactMap { l in
            guard let page = l.pages.first, let text = l.string else { return nil }
            let b = l.bounds(for: page), cb = page.bounds(for: .cropBox)
            return CleanCopy.Line(text: text, page: doc.index(for: page), x0: Double(b.minX - cb.minX), top: Double(cb.maxY - b.maxY),
                                  x1: Double(b.maxX - cb.minX), bottom: Double(cb.maxY - b.minY))
        }
        guard !lines.isEmpty else { return nil }
        let reading = model?.state?.reading
        return CleanCopy.text(lines, rulers: { i in i < v.rulers.count ? v.rulers[i] : nil }, block: { l in
            reading.flatMap { CleanCopy.block(of: l, paragraphs: $0.paragraphs, headings: $0.headings) }
        }, outside: { l in
            reading.map { CleanCopy.outside(l, paragraphs: $0.paragraphs, headings: $0.headings) } ?? false
        }) { [weak self] left, right in
            CleanCopy.keepsHyphen(left, right, text: { self?.documentText() ?? "" }) { w in
                NSSpellChecker.shared.checkSpelling(of: w, startingAt: 0, language: "en", wrap: false,
                                                    inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
            }
        }
    }

    /// The shown PDF's text, read once, when a line-end hyphen first needs it.
    private func documentText() -> String {
        if let t = docText { return t }
        let t = view?.document?.string ?? ""
        docText = t
        return t
    }

    /// Go to Page (design/pdf-reader/PLAN.md P1.4: the status line's "p.4 of 12", Jump's "p.12"): the page's top at the
    /// view's top, the place left a step of Back.
    func goToPage(_ i: Int, step: PDFSteps.Kind? = .lookUp) {
        guard let v = view, let doc = v.document, i >= 0, i < doc.pageCount, let pg = doc.page(at: i) else { return }
        let cb = pg.bounds(for: .cropBox)
        willJump(step, to: pg, rect: CGRect(x: cb.minX, y: cb.maxY, width: cb.width, height: 0))
        willMove()
        v.go(to: PDFDestination(page: pg, at: CGPoint(x: cb.minX, y: cb.maxY)))
    }

    /// Back or Forward to a place in the PDF (PLAN §5.3): the paper's zoom then, the point a third of the way down put
    /// back there and the line there flashed; nothing when it is there already (Review shown again). It waits for its
    /// PDF while another loads.
    func go(to p: PDFPlace) {
        jumps &+= 1
        guard let v = view, let doc = v.document, let path = model?.pdfURL?.path, loadedKey?.hasPrefix(path + "|") == true else {
            pendingPlace = p
            return
        }
        guard p.page >= 0, p.page < doc.pageCount, let pg = doc.page(at: p.page) else { return }
        if let here = currentPlace(), here.page == p.page, abs(here.y - p.y) < 1, here.zoom == p.zoom { return }
        willMove()
        if let key = model?.selectedPath, zooms[key] != p.zoom {
            zooms[key] = p.zoom
            applyZoom()
        }
        putAtThird((p.page, p.x, p.y))
        let cb = pg.bounds(for: .cropBox), tx = p.page < v.textX.count ? v.textX[p.page] : nil
        let lines = Geometry.lines(on: pg, textX: tx ?? [0, Double(cb.width)])
        if let line = PDFSteps.line(at: CGPoint(x: cb.minX + p.x, y: cb.maxY - p.y), in: lines) { startFlash([line], on: pg) }
    }

    // MARK: Reference previews (design/pdf-reader/PLAN.md §4)

    /// The shown round's link table (`AppModel.requestLinks`). nil until it comes, from an older engine, or when it could
    /// not be built: a click on a link then goes there (`followLink`), as before.
    private(set) var links: LinkTable?

    func setLinks(_ t: LinkTable?) {
        guard t != links else { return }
        closePreview()
        links = t
        hovered = nil
    }

    /// The table, when it is the shown round's.
    private var table: LinkTable? { links.flatMap { $0.round == model?.round?.n ? $0 : nil } }

    /// The preview shown over the PDF: what it shows, its view, the link's line (view coordinates) and whether it is
    /// above it; where a drag of its title row began.
    private var preview: (content: LinkPreview, view: NSView, line: CGRect, above: Bool)?
    private var previewDrag: CGPoint?
    private var previewMonitor: Any?
    /// The previews kept open (PLAN §4.3), small windows of their own; closed with the paper or round, never saved.
    private(set) var pinned: [NSPanel] = []
    private var hovered: Int?
    private var hoverTimer: Timer?

    var previewShown: Bool { preview != nil }
    var shownPreview: LinkPreview? { preview?.content }

    /// The table's link under a point of a page (PDFKit page space), when a click on it previews (`LinkTable.previews`).
    func previewLink(page: PDFPage, at p: CGPoint) -> Int? {
        guard let t = table, let doc = view?.document else { return nil }
        let cb = page.bounds(for: .cropBox)
        return t.link(page: doc.index(for: page), x: Double(p.x - cb.minX), y: Double(cb.maxY - p.y)).flatMap { t.previews($0) ? $0 : nil }
    }

    /// A press (`ReviewPDFView.mouseDown`) while a preview shows: on its link, without modifiers, the second click of a
    /// double click goes there (true: the click is spent, it would select a word), and a first press is left to the
    /// mouse's tracking, where a click goes there (`clickLink`) and a drag selects; anywhere else it closes the preview,
    /// and the click goes on.
    func previewClick(page: PDFPage, at p: CGPoint, plain: Bool, count: Int) -> Bool {
        guard let pv = preview?.content else { return false }
        if plain, let l = previewLink(page: page, at: p), l == pv.link {
            guard count > 1 else { return false }
            follow(pv)
            return true
        }
        closePreview()
        return false
    }

    /// A click without a drag on a link a click previews: its preview, or, while that shows, there.
    func clickLink(_ l: Int) {
        if let pv = preview?.content, pv.link == l { follow(pv) } else { showPreview(l) }
    }

    /// The preview's link clicked again: its target, a URL in the browser; a missing target's preview just closes.
    private func follow(_ pv: LinkPreview) {
        if pv.canGo { goToTarget(pv.target) } else if pv.url != nil { openPreviewURL() } else { closePreview() }
    }

    /// What the clicked target shows; a grouped citation previews only that target, as its metadata does.
    func makePreview(link: Int?, target: Int) -> LinkPreview? {
        guard let t = table, target >= 0, target < t.targets.count, let doc = view?.document, let model else { return nil }
        let main = t.targets[target]
        let entries = [target].compactMap { i -> LinkPreview.Entry? in
            guard let at = t.targets[i].place, at.page < doc.pageCount, let pg = doc.page(at: at.page) else { return nil }
            let cb = pg.bounds(for: .cropBox), r = t.targets[i].kind == "cite" ? hanging(at, on: pg) : at.rect
            let clip = [max(r[0] - 4, 0), max(r[1] - 4, 0), min(r[2] + 4, Double(cb.width)), min(r[3] + 4, Double(cb.height))]
            guard clip[2] > clip[0], clip[3] > clip[1] else { return nil }
            // on white paper as printed, with no mark: no rects to outline
            let req = CropRequest(round: t.round, pdf: model.pdfURL?.path, page: at.page, rects: [], textX: nil, clip: clip, look: .paper)
            return LinkPreview.Entry(id: i, label: t.targets[i].label, request: req,
                                     area: CGSize(width: clip[2] - clip[0], height: clip[3] - clip[1]))
        }
        var pv = LinkPreview(link: link, target: target, kind: main.kind, title: main.title, entries: entries,
                             continues: main.parts.first { $0.page != main.place?.page }?.page, cited: main.cited,
                             count: main.count, note: main.note, address: main.url, url: main.openable)
        if main.kind == "cite", let at = main.place, at.page < doc.pageCount, let pg = doc.page(at: at.page),
           let r = Geometry.pdfKitRect(hanging(at, on: pg), cropBox: pg.bounds(for: .cropBox)) {
            pv.reference = PDFMenus.collapsed(pg.selection(for: r)?.string ?? "")
        }
        pv.canComment = link != nil && model.roundIsOpen && !model.busy && model.toolbar.reanchor == nil
        if main.kind == "cite" {
            pv.refKey = main.key
            pv.refs = model.refShown(main.key)
        }
        return pv
    }

    /// An author-year entry's box widened to its first line, which hangs left of the box when its other lines are
    /// indented (natbib: the box's left edge cut "Ge" off "Geoffrey"): the words up to 20 pt left of its first line,
    /// in its own column.
    private func hanging(_ at: PageRect, on pg: PDFPage) -> [Double] {
        let r = at.rect, cb = pg.bounds(for: .cropBox), cols = view?.columns ?? []
        var left = r[0] - 20
        if at.page < cols.count, let c = cols[at.page], c.count == 2, r[0] > c[0] { left = max(left, c[0]) }
        guard left < r[0] - 0.5, let strip = Geometry.pdfKitRect([left, r[1], r[0] - 0.5, min(r[1] + 6, r[3])], cropBox: cb),
              let s = pg.selection(for: strip), !PDFMenus.collapsed(s.string ?? "").isEmpty else { return r }
        return [min(r[0], Geometry.contractRect(s.bounds(for: pg), cropBox: cb)[0]), r[1], r[2], r[3]]
    }

    /// A link's words as one rect in the view (a reference broken across lines: both lines).
    private func lineRect(_ l: LinkTable.Link) -> CGRect? {
        guard let v = view, let doc = v.document, l.page >= 0, l.page < doc.pageCount, let page = doc.page(at: l.page) else { return nil }
        let cb = page.bounds(for: .cropBox)
        let rs = l.rects.compactMap { Geometry.pdfKitRect($0, cropBox: cb) }.map { v.convert($0, from: page) }
        return rs.first.map { f in rs.dropFirst().reduce(f) { $0.union($1) } }
    }

    /// Sizes the preview's pictures for the view and the window (`PreviewLayout`): true when it goes above the line.
    /// Its words' height (the title row, "continues on", the footer, a note of several lines) is measured with the
    /// pictures at no size.
    private func layout(_ pv: inout LinkPreview, line: CGRect) -> Bool {
        guard let v = view else { return true }
        let areas = pv.entries.map(\.area), between = PreviewLayout.spacing * CGFloat(max(areas.count - 1, 0))
        var bare = pv
        for i in bare.entries.indices { bare.entries[i].size = .zero }
        let maxWidth = PreviewLayout.maxWidth(view: v.bounds.width)
        let chrome = NSHostingView(rootView: LinkPreviewView(preview: bare, actions: PreviewActions(controller: self), maxWidth: maxWidth))
            .fittingSize.height - between
        let cap = 0.7 * (v.window?.contentLayoutRect.height ?? v.bounds.height) - chrome
        let width = maxWidth - 2 * PreviewLayout.padding
        let s0 = PreviewLayout.scale(areas, page: v.scaleFactor, width: width, height: cap)
        let height = areas.map(\.height).reduce(0, +) * s0 + between + chrome
        let above = PreviewLayout.above(height: height, line: line, bounds: v.bounds)
        let room = PreviewLayout.room(line: line, bounds: v.bounds)
        let s = PreviewLayout.scale(areas, page: v.scaleFactor, width: width,
                                    height: min(cap, (above ? room.above : room.below) - chrome))
        for i in pv.entries.indices {
            let a = pv.entries[i].area
            pv.entries[i].size = CGSize(width: (a.width * s).rounded(), height: (a.height * s).rounded())
        }
        return above
    }

    /// A click on a link with the table (PLAN §4.1): its preview by it. A click elsewhere, a scroll, Esc, a zoom or
    /// another paper or round closes it.
    func showPreview(_ l: Int) {
        guard let t = table, l >= 0, l < t.links.count, let v = view, let line = lineRect(t.links[l]),
              var pv = makePreview(link: l, target: t.links[l].targets[0]) else { return }
        closePreview()
        hideToolbar()
        hideMarkBar()
        let above = layout(&pv, line: line)
        if !refreshing { model?.refPreviewOpened(pv.refKey) }  // Google Scholar: this one next
        let host = FloatView.holding(LinkPreviewView(preview: pv, actions: PreviewActions(controller: self),
                                                     maxWidth: PreviewLayout.maxWidth(view: v.bounds.width)))
        v.addSubview(host)
        let size = host.fittingSize
        host.frame = CGRect(origin: PreviewLayout.origin(size: size, line: line, bounds: v.bounds, above: above), size: size)
        preview = (pv, host, line, above)
        // a click outside the PDF view closes it too; the PDF's own clicks are `previewClick`'s and its menu's
        previewMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] e in
            MainActor.assumeIsolated {
                guard let self, let v = self.view else { return }
                if e.window === v.window, v.bounds.contains(v.convert(e.locationInWindow, from: nil)) { return }
                self.closePreview()
            }
            return e
        }
    }

    func closePreview() {
        guard let p = preview else { return }
        preview = nil
        previewDrag = nil
        p.view.removeFromSuperview()
        if let m = previewMonitor { NSEvent.removeMonitor(m) }
        previewMonitor = nil
    }

    /// Go to (the preview's Go to ›, its picture, a second click, the link menu's Go to): the place left is a step of
    /// Back, the target a third of the way down, all of it flashed (PLAN §4.4).
    func goToTarget(_ i: Int) {
        closePreview()
        guard let t = table, i >= 0, i < t.targets.count else { return }
        goTo(t.targets[i])
    }

    private func goTo(_ target: LinkTable.Target) {
        guard let doc = view?.document, let at = target.place else { return }
        putTop(at)
        let parts = (target.parts.isEmpty ? [at] : target.parts).compactMap { pageRects(doc, $0.page, [$0.rect]) }
        startFlash(parts.map { ($0.0, $0.2) })
    }

    /// A "Cited on" page: the link there that cites the target (another than the one clicked when there is one), a
    /// third of the way down and flashed, a step of Back.
    func goCited(_ page: Int) {
        guard let pv = preview?.content else { return }
        goCited(page, target: pv.target, except: pv.link)
    }

    private func goCited(_ page: Int, target: Int, except: Int?) {
        closePreview()
        guard let t = table else { return }
        let ls = t.citing(target, on: page)
        guard let l = ls.first(where: { $0 != except }) ?? ls.first else { return }
        let rs = t.links[l].rects
        putTop(PageRect(page: page, rect: [rs.map { $0[0] }.min()!, rs.map { $0[1] }.min()!, rs.map { $0[2] }.max()!,
                                           rs.map { $0[3] }.max()!]))
        flash(page: page, rects: rs)
    }

    /// A look-up to a box (contract coordinates): the place left is a step of Back, the box's top a third of the way
    /// down, centred across.
    private func putTop(_ at: PageRect) {
        guard let doc = view?.document, at.page >= 0, at.page < doc.pageCount, let pg = doc.page(at: at.page),
              let r = Geometry.pdfKitRect(at.rect, cropBox: pg.bounds(for: .cropBox)) else { return }
        willJump(.lookUp, to: pg, rect: r)
        willMove()
        putAtThird((at.page, (at.rect[0] + at.rect[2]) / 2, at.rect[1]))
    }

    /// Copy Reference: the clicked entry's words as printed.
    func copyReference() {
        guard let r = preview?.content.reference, !r.isEmpty else { return }
        Self.copy(r)
    }

    private static func copy(_ s: String) {
        AppModel.clipboard.clearContents()
        AppModel.clipboard.setString(s, forType: .string)
    }

    /// A look-up's link in a citation's preview (a source's page, a published version): http and https only, in the
    /// browser; a test run (--background) only notes it.
    private(set) var openedRefURL: URL?
    func openRefURL(_ u: URL) {
        guard ["http", "https"].contains(u.scheme?.lowercased() ?? "") else { return }
        openedRefURL = u
        closePreview()
        if !LaunchOptions.background { NSWorkspace.shared.open(u) }
    }

    /// A look-up's result came for an entry: the open preview of a citation of it is shown again with it.
    func refreshPreview(key: String) {
        guard let p = preview, p.content.refKey == key, let l = p.content.link else { return }
        refreshing = true
        showPreview(l)
        refreshing = false
    }

    /// `showPreview` called by `refreshPreview`: the same entry, no new preference.
    private var refreshing = false

    func openPreviewURL() {
        guard let u = preview?.content.url else { return }
        closePreview()
        NSWorkspace.shared.open(u)
    }

    func copyPreviewURL() {
        guard let u = preview?.content.url else { return }
        Self.copy(u.absoluteString)
    }

    /// A missing reference's Comment…: its words selected, then the new-comment editor.
    func commentOnPreviewLink() {
        guard let l = preview?.content.link else { return }
        closePreview()
        commentOn(link: l)
    }

    /// The words of one of the table's links, as a selection.
    private func linkWords(_ l: Int) -> PDFSelection? {
        guard let t = table, let doc = view?.document, t.links[l].page < doc.pageCount, let page = doc.page(at: t.links[l].page)
        else { return nil }
        let cb = page.bounds(for: .cropBox), sel = PDFSelection(document: doc)
        for r in t.links[l].rects { if let pr = Geometry.pdfKitRect(r, cropBox: cb), let s = page.selection(for: pr) { sel.add(s) } }
        return PDFMenus.collapsed(sel.string ?? "").isEmpty ? nil : sel
    }

    private func commentOn(link l: Int) {
        guard let v = view, let words = linkWords(l) else { return }
        dropPendingBox()
        v.setCurrentSelection(words, animate: false)
        beginComment()
    }

    /// Dragging the preview's title row: it follows the pointer, and let go away from where it was it is kept open
    /// there (PLAN §4.3). `t`: the drag so far, SwiftUI's (y down).
    func dragPreview(_ t: CGSize, ended: Bool) {
        guard let p = preview else { return }
        let from = previewDrag ?? p.view.frame.origin
        previewDrag = from
        p.view.setFrameOrigin(CGPoint(x: from.x + t.width, y: from.y - t.height))
        guard ended else { return }
        previewDrag = nil
        if hypot(t.width, t.height) >= 6 { pinPreview() } else { p.view.setFrameOrigin(from) }
    }

    /// The pin, or a drag away: the preview becomes a small window where it was.
    func pinPreview() {
        guard let p = preview, let v = view, let w = v.window else { return }
        let at = w.convertToScreen(v.convert(p.view.frame, to: nil))
        closePreview()
        keepOpen(p.content, topLeft: CGPoint(x: at.minX, y: at.maxY))
    }

    /// Keep … Open from a menu: the window where the preview would be (`near`: the link's line, or the pointer).
    private func keepOpen(target: Int, link: Int?, near line: CGRect) {
        guard let v = view, let w = v.window, var pv = makePreview(link: link, target: target) else { return }
        closePreview()
        let above = layout(&pv, line: line)
        let size = pv.entries.first.map { PinnedPreviewView.content($0.size) } ?? .zero
        let o = PreviewLayout.origin(size: size, line: line, bounds: v.bounds, above: above)
        let at = w.convertToScreen(v.convert(CGRect(origin: o, size: size), to: nil))
        keepOpen(pv, topLeft: CGPoint(x: at.minX, y: at.maxY))
    }

    private func keepOpen(_ pv: LinkPreview, topLeft: CGPoint) {
        guard let e = pv.entries.first, let target = table?.targets[pv.target] else { return }
        keepOpen(e, title: pv.title, topLeft: topLeft) { [weak self] in self?.goTo(target) }
    }

    /// A kept window of a crop (a preview's first entry, a check's place): titled, the picture scaled to fit, Go to ›.
    private func keepOpen(_ e: LinkPreview.Entry, title: String, topLeft: CGPoint, go: @escaping () -> Void) {
        let size = PinnedPreviewView.content(e.size)
        let panel = NSPanel(contentRect: CGRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel], backing: .buffered,
                            defer: false)
        panel.title = title
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true  // the keys stay the review window's
        panel.contentMinSize = CGSize(width: 120, height: 90)
        // over the review window while the app is in front; a test run's stays behind, as its window does
        let test = LaunchOptions.background || LaunchOptions.unitTest
        panel.isFloatingPanel = !test
        panel.hidesOnDeactivate = !test
        panel.contentView = NSHostingView(rootView: PinnedPreviewView(entry: e, go: go))
        panel.delegate = self
        pinned.append(panel)
        if LaunchOptions.unitTest { return }
        if LaunchOptions.background { panel.orderBack(nil) } else { panel.orderFront(nil) }
    }

    func windowWillClose(_ notification: Notification) {
        pinned.removeAll { $0 === notification.object as? NSPanel }
    }

    /// The paper or round changed, Review hidden or left for a hub page: the kept previews close.
    func closePinned() {
        let all = pinned
        pinned = []
        all.forEach { $0.close() }
    }

    // MARK: Checks (UX.md §39)

    /// A check's Comment…: the PDF goes to its place (a look-up, a step of Back), then the words in its rects are
    /// selected, or a pending box goes round them when they hold none, and the new-comment editor opens with `note`.
    func commentOn(check place: Check.Place, note: String) {
        guard let doc = view?.document, let (page, _, rs) = pageRects(doc, place.page, place.rects), let first = rs.first
        else { return }
        let sel = PDFSelection(document: doc)
        for r in rs { if let s = page.selection(for: r) { sel.add(s) } }
        let words = !PDFMenus.collapsed(sel.string ?? "").isEmpty
        let union = rs.dropFirst().reduce(first) { $0.union($1) }
        clearSelection()
        dropPendingBox()
        reveal(page: place.page, rects: place.rects, step: .lookUp)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, let v = self.view, v.document === doc else { return }
            if words {
                v.setCurrentSelection(sel, animate: false)
            } else {
                self.setPendingBox(page: page, rect: union.insetBy(dx: -3, dy: -3))
            }
            self.beginComment(note: note)
        }
    }

    /// A check's Keep Open: a kept window of its place as printed (its rects' union, 4 pt round it), titled with the
    /// check's words, near the place when it is on screen; its Go to › goes back there.
    func keepOpen(check place: Check.Place, title: String) {
        guard let v = view, let w = v.window, let doc = v.document, let model,
              let (page, _, rs) = pageRects(doc, place.page, place.rects), let first = rs.first else { return }
        let cb = page.bounds(for: .cropBox), rects = place.rects
        let clip = [max(rects.map { $0[0] }.min()! - 4, 0), max(rects.map { $0[1] }.min()! - 4, 0),
                    min(rects.map { $0[2] }.max()! + 4, Double(cb.width)), min(rects.map { $0[3] }.max()! + 4, Double(cb.height))]
        guard clip[2] > clip[0], clip[3] > clip[1] else { return }
        let req = CropRequest(round: model.round?.n ?? 0, pdf: model.pdfURL?.path, page: place.page, rects: [], textX: nil,
                              clip: clip, look: .paper)
        var e = LinkPreview.Entry(id: -1, label: "p.\(place.page + 1)", request: req,
                                  area: CGSize(width: clip[2] - clip[0], height: clip[3] - clip[1]))
        let s = PreviewLayout.scale([e.area], page: v.scaleFactor,
                                    width: PreviewLayout.maxWidth(view: v.bounds.width) - 2 * PreviewLayout.padding,
                                    height: 0.7 * w.contentLayoutRect.height)
        e.size = CGSize(width: e.area.width * s, height: e.area.height * s)
        let size = PinnedPreviewView.content(e.size)
        var line = v.convert(rs.dropFirst().reduce(first) { $0.union($1) }, from: page)
        if !v.bounds.intersects(line) { line = CGRect(x: v.bounds.midX, y: v.bounds.midY, width: 0, height: 0) }
        let o = PreviewLayout.origin(size: size, line: line, bounds: v.bounds,
                                     above: PreviewLayout.above(height: size.height, line: line, bounds: v.bounds))
        let at = w.convertToScreen(v.convert(CGRect(origin: o, size: size), to: nil))
        keepOpen(e, title: title, topLeft: CGPoint(x: at.minX, y: at.maxY)) { [weak self] in
            self?.reveal(page: place.page, rects: place.rects, step: .lookUp)
        }
    }

    /// The pointer at a point of a page: true over a link a click previews (a pointing hand). Once it rests on one its
    /// crop is drawn, so the click shows it at once (PLAN §4.1); only arithmetic runs while it moves.
    func hoverLink(page: PDFPage, at p: CGPoint) -> Bool {
        let l = previewLink(page: page, at: p)
        if l != hovered {
            hovered = l
            hoverTimer?.invalidate()
            hoverTimer = l.map { l in
                Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.prefetch(l) }
                }
            }
        }
        return l != nil
    }

    private func prefetch(_ l: Int) {
        guard hovered == l, preview == nil, let t = table, l < t.links.count, let line = lineRect(t.links[l]),
              var pv = makePreview(link: l, target: t.links[l].targets[0]) else { return }
        _ = layout(&pv, line: line)
        for e in pv.entries {
            let r = e.request, st = cropStyle(e)
            Task { _ = await CropCache.shared.image(r, st) }
        }
    }

    /// The style a preview's picture is drawn in (`CropPicture`'s for the same width, on this screen).
    private func cropStyle(_ e: LinkPreview.Entry) -> CropStyle {
        let screen = view?.window?.backingScaleFactor ?? 2
        return CropStyle(look: .paper, dark: false, density: CropStyle.density(width: e.size.width, area: e.area, screen: screen),
                         screen: screen, ink: .clear)
    }

    /// For --debug-script preview and the tests: the preview shown and the windows kept open.
    func previewState() -> [String: Any] {
        var r: [String: Any] = ["table": table != nil, "pinned": pinned.map(\.title)]
        guard let p = preview, let v = view else {
            r["preview"] = NSNull()
            return r
        }
        let f = p.view.frame, c = p.content, at = table?.targets[c.target].place
        let height = v.window?.contentLayoutRect.height ?? v.bounds.height
        r["preview"] = ["kind": c.kind, "title": c.title, "page": at.map { $0.page } as Any? ?? NSNull(),
                        "box": at.map { $0.rect } as Any? ?? NSNull(),
                        "entries": c.entries.map { e -> [Any] in [e.label, [Double(e.size.width), Double(e.size.height)],
                                                                 CropCache.shared.cached(e.request, cropStyle(e)) != nil] },
                        "cited": c.cited, "count": c.count, "footer": c.footer, "continues": c.continues as Any? ?? NSNull(),
                        "side": p.above ? "above" : "below", "gap": Double(p.above ? f.minY - p.line.maxY : p.line.minY - f.maxY),
                        "frame": [f.minX, f.minY, f.width, f.height].map(Double.init), "inView": v.bounds.contains(f),
                        "widthShare": Double(f.width / max(v.bounds.width, 1)), "heightShare": Double(f.height / max(height, 1)),
                        "scale": Double(c.entries.first.map { $0.size.width / max($0.area.width, 1) } ?? 0),
                        "pageScale": Double(v.scaleFactor)] as [String: Any]
        return r
    }

    /// For --debug-script: the preview's link, its first rect's centre (page, contract point).
    var previewPoint: (page: Int, x: Double, y: Double)? {
        guard let l = preview?.content.link, let t = table, let r = t.links[l].rects.first else { return nil }
        return (t.links[l].page, (r[0] + r[2]) / 2, (r[1] + r[3]) / 2)
    }

    // MARK: Paragraphs to read (UX.md §18)

    /// A paragraph's parts as page rects (PDFKit page space).
    private func placed(_ parts: [PageRect]) -> [(page: PDFPage, rect: CGRect)] {
        guard let doc = view?.document else { return [] }
        return parts.compactMap { part in pageRects(doc, part.page, [part.rect]).map { ($0.0, $0.2[0]) } }
    }

    /// Whether any part of a paragraph is on screen.
    func isVisible(parts: [PageRect]) -> Bool {
        guard let v = view else { return false }
        return placed(parts).contains { v.bounds.intersects(v.convert($0.rect, from: $0.page)) }
    }

    /// Whether every part of a paragraph is wholly on screen (for --debug-script reading).
    func isFullyVisible(parts: [PageRect]) -> Bool {
        guard let v = view else { return false }
        let ps = placed(parts)
        return !ps.isEmpty && ps.allSatisfy { v.bounds.contains(v.convert($0.rect, from: $0.page)) }
    }

    /// The paragraphs with a part on screen.
    func visibleBlocks(_ ps: [Paragraph]) -> [Int] { ps.filter { isVisible(parts: $0.parts) }.map(\.block) }

    /// N: scrolls so the paragraph is fully visible, 16 pt inside the view: with the least movement when it is partly on
    /// screen, else landing a third of the way down (higher when it would not fit there); a paragraph taller than the
    /// view gets its top 16 pt below the top. Animated over 0.25 s within 1.5 view heights. Then it flashes. `step`:
    /// what the move is for Back.
    func showParagraph(_ parts: [PageRect], step: PDFSteps.Kind? = nil) {
        let ps = placed(parts)
        guard let v = view, let clip = v.documentView?.enclosingScrollView?.contentView, let sv = clip.enclosingScrollView,
              !ps.isEmpty else { return }
        willJump(step, to: ps[0].page, rect: ps[0].rect)
        willMove()
        let inClip = ps.map { clip.convert(v.convert($0.rect, from: $0.page), from: v) }
        let u = inClip.dropFirst().reduce(inClip[0]) { $0.union($1) }
        let b = clip.bounds, m: CGFloat = 16, f = clip.isFlipped
        // distances down the document, whichever way the clip view is flipped
        let top = f ? u.minY : -u.maxY, bottom = f ? u.maxY : -u.minY, viewTop = f ? b.minY : -b.maxY
        let height = bottom - top
        var newTop = viewTop
        if top < viewTop + m - 0.5 || bottom > viewTop + b.height - m + 0.5 {
            if height > b.height - 2 * m {
                newTop = top - m
            } else if bottom > viewTop && top < viewTop + b.height {  // partly on screen: the least movement
                newTop = top < viewTop + m ? top - m : bottom + m - b.height
            } else {
                newTop = top - min(b.height / 3, b.height - height - m)
            }
        }
        let delta = newTop - viewTop
        if abs(delta) >= 0.5 {
            var target = b
            target.origin.y += f ? delta : -delta
            let reduce = Motion.reduced
            ScrollAnimator.scroll(sv, to: clip.constrainBoundsRect(target).origin,
                                  duration: !reduce && abs(delta) <= 1.5 * b.height ? 0.25 : 0)
        }
        flashParagraph(parts)
    }

    /// The paragraph's flash: an accent outline round each part (C on a paragraph already read, N).
    func flashParagraph(_ parts: [PageRect]) {
        let ps = placed(parts)
        let pages = ps.reduce(into: [(PDFPage, [CGRect])]()) { out, p in
            if let i = out.firstIndex(where: { $0.0 === p.page }) { out[i].1.append(p.rect) } else { out.append((p.page, [p.rect])) }
        }
        startFlash(pages)
    }

    /// Where the selection starts, as page index and contract point (C under a selection).
    func selectionPoint() -> (page: Int, x: Double, y: Double)? {
        guard let a = selectionAnchor(), let r = a.rects.first, r.count == 4 else { return nil }
        return (a.page, (r[0] + r[2]) / 2, (r[1] + r[3]) / 2)
    }

    /// Two pulses of a 2 pt accent outline, 0.15 s on and 0.15 s off; with Reduce Motion a static outline for 0.6 s.
    /// The outline is a view over the PDF (it scrolls with it): as an annotation, each pulse redrew the whole page with
    /// all its marks, 2–3 dropped frames per J/K step.
    private func startFlash(_ rects: [CGRect], on page: PDFPage) { startFlash([(page, rects)]) }

    /// The flash over rects of one or more pages (a paragraph across a page break).
    private func startFlash(_ pages: [(PDFPage, [CGRect])]) {
        stopFlash()
        let outlines = pages.compactMap { page, rects -> OutlineView? in
            let o = OutlineView(width: 2)
            return o.place(rects.map { $0.width < 1 ? $0.insetBy(dx: -7, dy: -7) : $0.insetBy(dx: -2, dy: -2) }, on: page,
                           in: view) ? o : nil
        }
        guard !outlines.isEmpty else { return }
        let reduce = Motion.reduced
        let timer = Timer.scheduledTimer(withTimeInterval: reduce ? 0.6 : 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.flashTick(reduce ? 4 : 1) }
        }
        flash = (outlines, timer, 0)
    }

    private func flashTick(_ step: Int) {
        guard var f = flash else { return }
        f.ticks += step
        if f.ticks >= 4 { stopFlash(); return }
        f.outlines.forEach { $0.isHidden.toggle() }
        flash = f
    }

    private func stopFlash() {
        guard let f = flash else { return }
        f.timer.invalidate()
        f.outlines.forEach { $0.removeFromSuperview() }
        flash = nil
    }

    // MARK: Boxes (UX.md §7)

    func rubberBand(page: PDFPage, rect: CGRect) {
        hideMarkBar()
        if let r = rubber, r.page !== page { r.page.removeAnnotation(r.mark); rubber = nil }
        if let r = rubber {
            r.mark.update(rects: [rect])
            view?.annotationsChanged(on: page)
        } else {
            let m = MarkAnnotation(rects: [rect], style: .rubber, fill: .controlAccentColor, ink: .controlAccentColor)
            page.addAnnotation(m)
            rubber = (page, m)
        }
    }

    func endBox(page: PDFPage, rect: CGRect, start: CGPoint, option: Bool) {
        if let r = rubber { r.page.removeAnnotation(r.mark); rubber = nil }
        model?.toolbar.boxArmed = false
        if rect.width >= 8 && rect.height >= 8 {
            setPendingBox(page: page, rect: rect)
        } else if option, model?.toolbar.reanchor == nil {
            beginPointNote(page: page, at: start)
        }
    }

    private func setPendingBox(page: PDFPage, rect: CGRect) {
        dropPendingBox()
        let m = MarkAnnotation(rects: [rect], style: .pendingBox, fill: .controlAccentColor, ink: .controlAccentColor)
        page.addAnnotation(m)
        pendingBox = (page, rect, m)
        model?.toolbar.hasBox = true
        model?.dropChoice()
        scheduleToolbar()
    }

    /// "Comment on this change" (UX.md §16): the PDF scrolls to the change, then its words are selected and the
    /// new-comment editor opens on them; a figure, table or formula gets a pending box, a deletion a note at its point.
    /// false: the change prints no words in the PDF (no place, or only white space under it: an `\input` renamed), so
    /// nothing is selected and the PDF only shows where it is.
    func commentOn(_ ch: Change) -> Bool {
        guard let doc = view?.document, let (page, _, rs) = pageRects(doc, ch.page, ch.rects) else { return false }
        let union = rs.dropFirst().reduce(rs[0]) { $0.union($1) }
        let point = ch.kind == "delete", box = ch.figure != nil || ch.context?.now?.isImage == true
        // the words of each line of the change (a range in content order could take in a margin ruler)
        let sel = PDFSelection(document: doc)
        if !point && !box {
            for r in rs { if let line = page.selection(for: r.insetBy(dx: 0.5, dy: 1)) { sel.add(line) } }
        }
        let words = !(sel.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if point || box || words {
            clearSelection()
            dropPendingBox()
        }
        reveal(page: ch.page, rects: ch.rects)
        guard point || box || words else { return false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, let v = self.view else { return }
            if point { return self.beginPointNote(page: page, at: CGPoint(x: union.midX, y: union.midY)) }
            if box {
                self.setPendingBox(page: page, rect: union.insetBy(dx: -3, dy: -3))
            } else {
                v.setCurrentSelection(sel, animate: false)
            }
            self.beginComment()
        }
        return true
    }

    func dropPendingBox() {
        guard let b = pendingBox else { return }
        b.page.removeAnnotation(b.mark)
        pendingBox = nil
        model?.toolbar.hasBox = false
        if model?.hasPDFSelection != true { hideToolbar() }
    }

    /// The selection or the pending box, as an anchor for a comment or a re-anchor.
    func pendingAnchor() -> (page: Int, rects: [[Double]], text: String, isBox: Bool)? {
        if let b = pendingBox, let doc = view?.document {
            let cb = b.page.bounds(for: .cropBox)
            let words = b.page.selection(for: b.rect)?.string ?? ""
            return (doc.index(for: b.page), [Geometry.contractRect(b.rect, cropBox: cb)],
                    words.split(whereSeparator: \.isWhitespace).joined(separator: " "), true)
        }
        guard let a = selectionAnchor() else { return nil }
        return (a.page, a.rects, a.text, false)
    }

    // MARK: Floating toolbar (UX.md §7)

    private func scheduleToolbar() {
        toolbarTimer?.invalidate()
        toolbarTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.showToolbar() }
        }
    }

    /// Centred 8 pt above the first selected line, or 8 pt below the last one when there is no room above; kept 8 pt
    /// inside the view.
    func showToolbar() {
        guard let v = view, let model, model.roundIsOpen, popover?.isShown != true else { return hideToolbar() }
        if NSEvent.pressedMouseButtons & 1 != 0 { return scheduleToolbar() }  // still dragging
        var lines: [CGRect] = []
        if let b = pendingBox {
            lines = [v.convert(b.rect, from: b.page)]
        } else if let sel = v.currentSelection, !(sel.string ?? "").isEmpty {
            lines = sel.selectionsByLine().compactMap { l in l.pages.first.map { v.convert(l.bounds(for: $0), from: $0) } }
                .filter { !$0.isEmpty }
        }
        guard let first = lines.max(by: { $0.maxY < $1.maxY }), let last = lines.min(by: { $0.minY < $1.minY }) else {
            return hideToolbar()
        }
        hideMarkBar()
        // at a find match, the Comment button alone (BRIEF E5); a selection of your own, the whole toolbar
        let only = pendingBox == nil && find.currentIsSelection
        if model.toolbar.matchOnly != only { model.toolbar.matchOnly = only }
        // made once; a paper switch or a trip to the hub makes a new PDF view, and the toolbar moves into it
        let bar = toolbarView ?? makeToolbar()
        if bar.superview !== v { v.addSubview(bar) }
        bar.isHidden = false
        let size = bar.fittingSize
        bar.frame.size = size
        let top = v.bounds.maxY - (model.toolbar.reanchor != nil ? 56 : 0)  // below the re-anchor bar
        if let o = FloatPlace.origin(size: size, lines: [first, last], width: v.bounds.width, top: top) { bar.setFrameOrigin(o) }
        // the Comment button alone, or the whole toolbar again, shows in the toolbar's next update: laid again then
        DispatchQueue.main.async { [weak self] in
            guard let self, self.toolbarShown, let bar = self.toolbarView, bar.fittingSize != bar.frame.size else { return }
            self.showToolbar()
        }
    }

    func hideToolbar() {
        toolbarTimer?.invalidate()
        toolbarView?.isHidden = true
    }

    var toolbarShown: Bool { toolbarView.map { !$0.isHidden && $0.superview === view && $0.window != nil } ?? false }

    private func makeToolbar() -> NSView {
        let effect = FloatingToolbar.hosted(model: model)
        toolbarView = effect
        return effect
    }

    // MARK: The mark's toolbar (UX.md §8)

    /// A click on a comment's mark: its toolbar by the mark, when it is a new comment of the open round, to recolour
    /// it, change its kind, edit its note or delete it. A carried comment's mark shows none: its card is answered, and
    /// clicking marks is how its round is read (its colour is in the card's colour dot).
    func showMarkBar(_ id: String) {
        markBarID = id
        placeMarkBar()
    }

    func hideMarkBar() {
        markBarID = nil
        markBarView?.isHidden = true
    }

    var markBarShown: Bool { markBarView.map { !$0.isHidden && $0.superview === view && $0.window != nil } ?? false }

    /// For --debug-script markbar: a comment's mark's page and lines (page space).
    func debugMark(_ id: String) -> (page: PDFPage, lines: [CGRect])? { commentMarks[id].map { ($0.page, $0.mark.lines) } }

    /// Whether a click on the comment's mark shows its toolbar: a new comment of the open round, outside re-anchoring.
    static func showsMarkBar(_ c: Comment, roundOpen: Bool, reanchoring: Bool) -> Bool {
        roundOpen && !c.carried && !reanchoring
    }

    /// Lays the toolbar by its mark (shown, or the marks drawn again after an edit) with the comment's style, as the
    /// selection's toolbar is laid by the selection (`FloatPlace`, past the selected mark's outline); hidden when the
    /// comment is gone or no longer selected, and while a selection, a box or the new-comment editor is there.
    private func placeMarkBar() {
        guard let id = markBarID else { return }
        guard let v = view, let model, let c = model.comment(id), id == selectedID, let m = commentMarks[id],
              Self.showsMarkBar(c, roundOpen: model.roundIsOpen, reanchoring: model.toolbar.reanchor != nil),
              popover?.isShown != true, pendingBox == nil, (v.currentSelection?.string ?? "").isEmpty else { return hideMarkBar() }
        markBar.show(c)
        // made once, as the selection's toolbar; a new PDF view takes it in
        let bar = markBarView ?? MarkToolbar.hosted(model: model)
        markBarView = bar
        if bar.superview !== v { v.addSubview(bar) }
        bar.isHidden = false
        let size = bar.fittingSize
        bar.frame.size = size
        // the outline is 1–3 pt outside the lines, a note's square 9 pt round its point
        let lines = m.mark.lines.map { r in v.convert(r.width < 1 && r.height < 1 ? r.insetBy(dx: -6, dy: -6) : r.insetBy(dx: -3, dy: -3), from: m.page) }
        if let o = FloatPlace.origin(size: size, lines: lines, width: v.bounds.width, top: v.bounds.maxY) { bar.setFrameOrigin(o) }
        // kinds that came or went show in the toolbar's next update: laid again at its new size then
        DispatchQueue.main.async { [weak self] in
            guard let self, self.markBarShown, let bar = self.markBarView, bar.fittingSize != bar.frame.size else { return }
            self.placeMarkBar()
        }
    }

    // MARK: Writing comments

    /// Return, Comment (toolbar or window), or the context menu: comment on the selection or the pending box; in
    /// re-anchor mode, place the comment there instead. `note`: the editor's words to start with (a check's Comment…).
    func beginComment(note start: String = "") {
        guard let model else { return }
        if model.toolbar.reanchor != nil { return model.placeReanchor() }
        guard let v = view else { return }
        let shown = model.shown  // the note is saved to this paper and round only
        if let b = pendingBox, let a = pendingAnchor() {
            let rect = v.convert(b.rect, from: b.page)
            return showEditor(at: rect, page: a.page, quote: "", mode: .box, note: start) { [weak self] _, color, note, tags, done in
                self?.model?.createComment(anchor: ["page": a.page, "rects": a.rects, "text": a.text], note: note, kind: .box,
                                           color: color, tags: tags, on: shown, done: done)
            }
        }
        guard let a = selectionAnchor() else { return }
        showEditor(at: a.viewRect, page: a.page, quote: a.text, mode: .text, note: start) { [weak self] kind, color, note, tags, done in
            self?.model?.createComment(anchor: ["page": a.page, "rects": a.rects, "text": a.text], note: note, kind: kind,
                                       color: color, tags: tags, on: shown, done: done)
        }
    }

    /// The current selection as a comment anchor: page index, per-line rects (contract coordinates) and text.
    /// A comment has one page; a selection that crosses pages keeps its lines on the first page.
    func selectionAnchor() -> (page: Int, rects: [[Double]], text: String, viewRect: CGRect)? {
        guard let v = view, let doc = v.document, let sel = v.currentSelection else { return nil }
        var lines = sel.selectionsByLine()
        guard let page = lines.first?.pages.first ?? sel.pages.first else { return nil }
        let cb = page.bounds(for: .cropBox)
        let i = doc.index(for: page)
        if i < v.columns.count, let c = v.columns[i], c.count == 2 {  // PDFKit lists lines in content order: across
            let gap = cb.minX + c[0]                                  // the columns, the left one's come first
            let side = { (l: PDFSelection) in l.bounds(for: page).midX < gap ? 0 : 1 }
            if Set(lines.map(side)).count == 2 {
                lines = lines.enumerated().sorted { (side($0.element), $0.offset) < (side($1.element), $1.offset) }
                    .map(\.element)
            }
        }
        var rects: [[Double]] = []
        var texts: [String] = []
        var union: CGRect?
        for line in lines where line.pages.first == page {
            let b = line.bounds(for: page)
            guard b.width > 0, b.height > 0 else { continue }
            rects.append(Geometry.contractRect(b, cropBox: cb))
            texts.append(line.string ?? "")
            union = union?.union(b) ?? b
        }
        guard let union, !rects.isEmpty else { return nil }
        let reordered = lines.map { $0.string ?? "" } != sel.selectionsByLine().map { $0.string ?? "" }
            || sel.numberOfTextRanges(on: page) > 1  // runs added together: their string has no breaks between them
        let text = sel.pages.count > 1 || reordered ? texts.joined(separator: " ") : (sel.string ?? texts.joined(separator: " "))
        return (doc.index(for: page), rects, text, v.convert(union, from: page))
    }

    /// Right-click with no selection, or ⌥-click: a note at a point, sent as a zero-size rect (CONTRACT amendments).
    private func beginPointNote(page: PDFPage, at point: CGPoint) {
        guard let v = view, let doc = v.document, let shown = model?.shown else { return }
        let rect = Geometry.contractRect(CGRect(origin: point, size: .zero), cropBox: page.bounds(for: .cropBox))
        let index = doc.index(for: page)
        let anchor = v.convert(CGRect(x: point.x - 1, y: point.y - 6, width: 2, height: 12), from: page)
        showEditor(at: anchor, page: index, quote: "", mode: .point) { [weak self] _, color, note, tags, done in
            self?.model?.createComment(anchor: ["page": index, "rects": [rect], "text": ""], note: note, kind: .note,
                                       color: color, tags: tags, on: shown, done: done)
        }
    }

    // MARK: The right-click menu (design/pdf-reader/PLAN.md §3)

    /// The PDF's right-click menu, by what is under the pointer: the selection, a comment's mark or a change's band, a
    /// link, a figure the link table knows, the page. The first of them with an item that can act decides; items that cannot act are left out. nil
    /// (no menu) off the pages.
    func menu(for event: NSEvent) -> NSMenu? {
        guard let v = view, v.document != nil else { return nil }
        let loc = v.convert(event.locationInWindow, from: nil)
        guard let page = v.page(for: loc, nearest: false) else { return nil }
        let p = v.convert(loc, to: page)
        closePreview()
        // one after another, stopping at the first with items: the mark's selects its comment
        var groups: [[NSMenuItem]] = []
        for items in [selectionItems, markItems, linkItems, figureItems, pageItems] where groups.isEmpty { groups = items(p, page) }
        guard !groups.isEmpty else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (i, g) in groups.enumerated() {
            if i > 0 { menu.addItem(.separator()) }
            g.forEach(menu.addItem)
        }
        return menu
    }

    /// On selected text (PLAN §3.1): in an open round Comment…, Strike Out (no note: "delete this") and Replace With…;
    /// then Copy, Find “…” in Paper (from its first use) and, for one word, Look Up.
    private func selectionItems(at p: CGPoint, on page: PDFPage) -> [[NSMenuItem]] {
        guard let v = view, let model, let sel = v.currentSelection, let text = sel.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              sel.selectionsByLine().contains(where: { $0.pages.first === page && $0.bounds(for: page).insetBy(dx: -2, dy: -2).contains(p) })
        else { return [] }
        var groups: [[NSMenuItem]] = []
        if model.roundIsOpen, !model.busy, model.toolbar.reanchor == nil {
            groups.append([Self.menuItem("Comment…") { [weak self] in self?.beginComment() },
                           Self.menuItem("Strike Out") { [weak self] in self?.strikeOut() },
                           Self.menuItem("Replace With…") { [weak self] in self?.replaceSelection() }])
        }
        let query = PDFMenus.collapsed(text)
        var look = [Self.menuItem("Copy") { [weak self] in
                        let clean = self?.cleanText(sel).flatMap { $0.isEmpty ? nil : $0 } ?? text
                        AppModel.clipboard.clearContents()
                        AppModel.clipboard.setString(clean, forType: .string)
                    },
                    Self.menuItem("Find “\(PDFMenus.short(query))” in Paper") { [weak self] in self?.find.find(query, fromStart: true) }]
        if let l = lookUpItem(sel, on: page) { look.append(l) }
        groups.append(look)
        return groups
    }

    /// On a comment's mark (PLAN §3.2), outside re-anchoring: the right-click selects it first, as a click does (the
    /// selected one while it is among the marks there). A carried comment in an open round: Resolve, Follow Up… and
    /// Keep as Is, answered in place (decision 3); then the card's ⋯ items that can act (`CardMenus.more`); Other
    /// Comments Here where marks overlap. On a change's band (the changed words on the Changes tab): Mark Checked and
    /// Comment on It…, in an open round. What is under the pointer is taken in a click's order (`click(page:at:)`):
    /// id labels first; then on the Changes tab the changes before the comments' marks, on the Comments tab after them.
    private func markItems(at p: CGPoint, on page: PDFPage) -> [[NSMenuItem]] {
        guard let v = view, let doc = v.document, let model, model.toolbar.reanchor == nil else { return [] }
        let idx = doc.index(for: page), minSize = 8 / max(v.scaleFactor, 0.01), all = shapes[idx] ?? []
        let onChanges = model.tab == .changes
        let hits = MarkHit.hits(at: p, shapes: all, minSize: minSize)
        func comment(_ h: [String]) -> String? { h.contains(where: { $0 == selectedID }) ? selectedID : h.first }
        func change() -> [[NSMenuItem]]? {
            guard model.roundIsOpen, let area = (changeAreas[idx] ?? []).first(where: {
                MarkHit.changeHit(at: p, rects: $0.rects, isDelete: $0.delete, whole: onChanges, minSize: onChanges ? minSize : 0)
            }), let ch = model.change(area.id) else { return nil }
            if model.selection != .change(ch.id) {
                model.tab = .changes
                model.select(.change(ch.id), reveal: false, scroll: .centre, flash: true)
            }
            let check = Self.menuItem("Mark Checked") { [weak model] in model?.toggleChecked(ch.id) }
            check.state = ch.checked == true ? .on : .off
            return [[check, Self.menuItem("Comment on It…") { [weak model] in model?.commentOnChange(ch.id) }]]
        }
        let label = comment(MarkHit.hits(at: p, shapes: all.filter { $0.group == .label }, minSize: minSize))
        if label == nil, onChanges, let items = change() { return items }
        guard let id = label ?? comment(hits), let c = model.comment(id) else { return onChanges ? [] : change() ?? [] }
        clearSelection()  // as a click clears it
        if id != selectedID || model.selection != .comment(id) {
            model.markClicked(id)
            showMarkBar(id)
        }
        var groups: [[NSMenuItem]] = []
        if model.roundIsOpen, c.carried {
            groups.append([("Resolve", "verified"), ("Follow Up…", "reopened"), ("Keep as Is", "wontfix")].map { title, verdict in
                let item = Self.menuItem(title) { [weak model] in model?.press(verdict, for: id, stay: true) }
                item.state = c.verdict == verdict ? .on : .off
                return item
            })
        }
        groups += PDFMenus.actionable(CardMenus.more(id, model: model))
        let others = hits.filter { $0 != id }.compactMap { model.comment($0) }
        if !others.isEmpty {
            let item = NSMenuItem(title: "Other Comments Here", action: nil, keyEquivalent: "")
            item.submenu = NSMenu()
            for o in others {
                item.submenu?.addItem(Self.menuItem(PDFMenus.otherTitle(o)) { [weak self] in
                    self?.model?.markClicked(o.id)
                    self?.showMarkBar(o.id)
                })
            }
            groups.append([item])
        }
        return groups
    }

    /// On a link (the PDF's own, or one the engine found; PLAN §3.3): with the round's link table Preview <Label> (what
    /// a click does; a missing target's Preview “??”, its words), Go to <Label> · p.N (the target, flashed whole) and
    /// Keep <Label> Open, and a citation's Copy Reference; without it, Go to p.N as before. In an open round Comment on
    /// “<its words>”…, with the name before a number hyperref links alone ("Figure" of "Figure 1", `named`); for a URL
    /// Open in Browser (http, https, mailto only) and Copy Link.
    private func linkItems(at p: CGPoint, on page: PDFPage) -> [[NSMenuItem]] {
        guard let v = view, let doc = v.document else { return [] }
        let link = page.annotations.first(where: { $0.type == "Link" && $0.bounds.contains(p) })
        let row = previewLink(page: page, at: p)
        guard link != nil || row != nil else { return [] }
        var groups: [[NSMenuItem]] = []
        let dest = link.flatMap(ReviewPDFView.goTo)
        let goTo = dest.flatMap { d in d.page.map { pg in Self.menuItem("Go to p.\(doc.index(for: pg) + 1)") { [weak self] in self?.followLink(d) } } }
        if let row, let t = table, let pv = makePreview(link: row, target: t.links[row].targets[0]), pv.kind != "url" {
            let label = PDFMenus.short(t.targets[pv.target].label), words = PDFMenus.collapsed(t.links[row].text)
            let shown = pv.kind == "missing" && !words.isEmpty ? "“\(PDFMenus.short(words))”" : label
            var items = [Self.menuItem("Preview \(shown)") { [weak self] in self?.showPreview(row) }]
            if let at = t.targets[pv.target].place {
                items.append(Self.menuItem("Go to \(label) · p.\(at.page + 1)") { [weak self] in self?.goToTarget(pv.target) })
                let line = lineRect(t.links[row]) ?? CGRect(origin: v.convert(p, from: page), size: .zero)
                items.append(Self.menuItem("Keep \(label) Open") { [weak self] in self?.keepOpen(target: pv.target, link: row, near: line) })
            } else if let goTo {
                items.append(goTo)
            }
            groups.append(items)
            if pv.kind == "cite", let r = pv.reference, !r.isEmpty { groups.append([Self.menuItem("Copy Reference") { Self.copy(r) }]) }
        } else if let goTo {
            groups.append([goTo])
        }
        let rowURL = row.flatMap { r in table.flatMap { $0.targets[$0.links[r].targets[0]].openable } }
        let url = link.flatMap({ $0.url ?? ($0.action as? PDFActionURL)?.url }) ?? rowURL
        if let model, model.roundIsOpen, !model.busy, model.toolbar.reanchor == nil,
           let found = link.flatMap({ page.selection(for: $0.bounds) }) ?? row.flatMap(linkWords),
           case let words = url == nil ? named(found, on: page) : found, !PDFMenus.collapsed(words.string ?? "").isEmpty {
            groups.append([Self.menuItem("Comment on “\(PDFMenus.short(PDFMenus.collapsed(words.string ?? "")))”…") { [weak self] in
                guard let self, let v = self.view else { return }
                self.dropPendingBox()
                v.setCurrentSelection(words, animate: false)
                self.beginComment()
            }])
        }
        if let url {
            // a link to a file or an app is not opened from "Open in Browser"; its address can still be copied
            groups.append((LinkTable.opens(url) ? [Self.menuItem("Open in Browser") { NSWorkspace.shared.open(url) }] : [])
                          + [Self.menuItem("Copy Link") { Self.copy(url.absoluteString) }])
        }
        return groups
    }

    /// A reference's words with the name printed before its number when hyperref links the number alone ("Figure" of
    /// "Figure 1", "Eq. (" and ")" of "Eq. (4)"), so a comment on it is anchored on "Figure 1"; else as they are.
    private func named(_ words: PDFSelection, on page: PDFPage) -> PDFSelection {
        guard let text = page.string, words.numberOfTextRanges(on: page) > 0 else { return words }
        let s = text as NSString, first = words.range(at: 0, on: page)
        let last = words.range(at: words.numberOfTextRanges(on: page) - 1, on: page)
        guard first.location != NSNotFound, last.location != NSNotFound, first.location <= s.length,
              NSMaxRange(last) <= s.length else { return words }
        let from = max(first.location - 24, 0), before = NSRange(location: from, length: first.location - from)
        guard let m = Self.nounBefore.firstMatch(in: text, range: before) else { return words }
        var end = NSMaxRange(last)
        if s.substring(with: m.range).hasSuffix("("), end < s.length, s.character(at: end) == 0x29 { end += 1 }  // ")"
        return page.selection(for: NSRange(location: m.range.location, length: end - m.range.location)) ?? words
    }

    private static let nounBefore = try! NSRegularExpression(
        pattern: #"(?<![\p{L}])(?:Figures?|Figs?\.|Tables?|Tabs?\.|Equations?|Eqs?\.|Sections?|Secs?\.|Algorithms?|Alg\.|"#
            + #"Appendix|Appendices|Theorems?|Lemmas?|Corollary|Definitions?|Propositions?)[\s\u00A0~]*\(?$"#)

    /// On a figure, table or algorithm the link table knows (PLAN §3.4): the page's Back to p.N · <section> first, as it
    /// is where Go to puts a figure; in an open round Comment on Figure 3… (a box round the whole float, then the note)
    /// and the page's Add Note Here, then Keep Figure 3 Open and Cited on ▸ its pages.
    private func figureItems(at p: CGPoint, on page: PDFPage) -> [[NSMenuItem]] {
        guard let v = view, let doc = v.document, let model, let t = table else { return [] }
        let i = doc.index(for: page), cb = page.bounds(for: .cropBox)
        let x = Double(p.x - cb.minX), y = Double(cb.maxY - p.y)
        func holds(_ r: PageRect) -> Bool { r.page == i && r.rect[0] <= x && x <= r.rect[2] && r.rect[1] <= y && y <= r.rect[3] }
        guard let k = t.targets.indices.first(where: { ["figure", "table", "algorithm"].contains(t.targets[$0].kind)
                  && t.targets[$0].place != nil && t.targets[$0].parts.contains(where: holds) }),
              let part = t.targets[k].parts.first(where: holds) else { return [] }
        let label = PDFMenus.short(t.targets[k].label)
        var groups = backItems()
        if model.roundIsOpen, !model.busy, model.toolbar.reanchor == nil, let r = Geometry.pdfKitRect(part.rect, cropBox: cb) {
            groups.append([Self.menuItem("Comment on \(label)…") { [weak self] in
                               self?.clearSelection()
                               self?.setPendingBox(page: page, rect: r)
                               self?.beginComment()
                           },
                           addNoteItem(at: p, on: page)])
        }
        let near = CGRect(origin: v.convert(p, from: page), size: .zero)
        var items = [Self.menuItem("Keep \(label) Open") { [weak self] in self?.keepOpen(target: k, link: nil, near: near) }]
        if !t.targets[k].cited.isEmpty {
            let cited = NSMenuItem(title: "Cited on", action: nil, keyEquivalent: "")
            cited.submenu = NSMenu()
            for c in t.targets[k].cited {
                cited.submenu?.addItem(Self.menuItem("p.\(c + 1)") { [weak self] in self?.goCited(c, target: k, except: nil) })
            }
            items.append(cited)
        }
        groups.append(items)
        return groups
    }

    /// On the page (PLAN §3.5): Back to p.N · <section> while Back is a step in the PDF (§5.3); in an open round Add
    /// Note Here and Draw a Box (B); Look Up over a word; in an open round Mark Paragraph Read / Unread while reading
    /// marks are on (UX.md §18; un-reading is only here and in the Contents' menu); Set p.N as Key Page (TAGS.md §7), in
    /// any round, last.
    private func pageItems(at p: CGPoint, on page: PDFPage) -> [[NSMenuItem]] {
        guard let v = view, let doc = v.document, let model else { return [] }
        let i = doc.index(for: page)
        var groups = backItems()
        if model.roundIsOpen, !model.busy, model.toolbar.reanchor == nil {
            groups.append([addNoteItem(at: p, on: page),
                           Self.menuItem("Draw a Box") { [weak model] in model?.toolbar.boxArmed = true }])
        }
        if let word = page.selectionForWord(at: p), word.bounds(for: page).insetBy(dx: -1, dy: -1).contains(p),
           let l = lookUpItem(word, on: page) {
            groups.append([l])
        }
        if model.readingMarksOn && model.readingTracked, model.roundIsOpen, !model.busy, model.toolbar.reanchor == nil {
            let c = Geometry.contractRect(CGRect(origin: p, size: .zero), cropBox: page.bounds(for: .cropBox))
            if let b = Reading.paragraph(at: i, x: c[0], y: c[1], in: model.paragraphs) {
                let read = model.readBlocks.contains(b)
                groups.append([Self.menuItem(read ? "Mark Paragraph Unread" : "Mark Paragraph Read") { [weak model] in
                    model?.markParagraph(b, read: !read)
                }])
            }
        }
        // the page under the pointer stands for the paper; a page beyond a round built again shorter is its last one
        if let path = model.selectedPath, let n = model.round?.n {
            let k = model.keyPage(of: path)
            groups.append([k?.round == n && PageStripView.clamp(k?.page ?? -1, pages: doc.pageCount) == i
                ? Self.menuItem("Use the Busiest Page") { [weak model] in model?.setKeyPage(path, nil) }
                : Self.menuItem("Set p.\(i + 1) as Key Page") { [weak model] in model?.setKeyPage(path, KeyPageChoice(round: n, page: i)) }])
        }
        return groups
    }

    /// Back to p.N · <section> while Back is a step in the PDF (§5.3).
    private func backItems() -> [[NSMenuItem]] {
        guard let model, let at = model.backStep else { return [] }
        return [[Self.menuItem("Back to " + at.label) { [weak model] in model?.goBack() }]]
    }

    private func addNoteItem(at p: CGPoint, on page: PDFPage) -> NSMenuItem {
        Self.menuItem("Add Note Here") { [weak self] in
            self?.clearSelection()
            self?.beginPointNote(page: page, at: p)
        }
    }

    /// Look Up “word”, for a selection of one word: the system's Look Up panel by it (which may search online).
    private func lookUpItem(_ sel: PDFSelection, on page: PDFPage) -> NSMenuItem? {
        guard let word = PDFMenus.oneWord(sel.string ?? "") else { return nil }
        return Self.menuItem("Look Up “\(word)”") { [weak self] in
            guard let v = self?.view else { return }
            let b = v.convert(sel.bounds(for: page), from: page)
            let text = NSAttributedString(string: word, attributes: [.font: NSFont.systemFont(ofSize: max(b.height * 0.8, 9))])
            v.showDefinition(for: text, at: CGPoint(x: b.minX, y: b.minY + b.height * 0.2))
        }
    }

    /// Strike Out: a strikeout comment on the selection with no note ("delete this").
    private func strikeOut() {
        guard let model, let a = selectionAnchor() else { return }
        model.createComment(anchor: ["page": a.page, "rects": a.rects, "text": a.text], note: "", kind: .strikeout,
                            color: model.toolbar.color, on: model.shown) { _ in }
    }

    /// Replace With…: the editor asks for the new words; the comment is a strikeout noted "Replace with “were”." (the
    /// strikeout shows what goes; PLAN §3.1, decision 4). Saved with no words, it is a plain Strike Out.
    private func replaceSelection() {
        guard let a = selectionAnchor() else { return }
        let shown = model?.shown ?? (nil, nil)
        showEditor(at: a.viewRect, page: a.page, quote: a.text, mode: .replace) { [weak self] _, color, note, tags, done in
            self?.model?.createComment(anchor: ["page": a.page, "rects": a.rects, "text": a.text], note: PDFMenus.replaceNote(note),
                                       kind: .strikeout, color: color, tags: tags, on: shown, done: done)
        }
    }

    private static func menuItem(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
        let action = MenuAction(run)
        let item = NSMenuItem(title: title, action: #selector(MenuAction.invoke), keyEquivalent: "")
        item.target = action
        item.representedObject = action  // keeps the target alive
        return item
    }

    /// The new-comment popover at `rect` of `target` (the PDF by default), for a comment on `page`, its note starting
    /// with `note`.
    func showEditor(at rect: CGRect, page: Int, quote: String, mode: CommentDraft.Mode, in target: NSView? = nil, note: String = "",
                    save: @escaping (_ kind: MarkKind, _ color: MarkColor, _ note: String, _ tags: TagSelection,
                                     _ done: @escaping (Bool) -> Void) -> Void) {
        guard let v = target ?? view, let model else { return }
        if popover?.isShown == true, let d = draft, d.changed || d.saving {
            NSSound.beep()  // a note is being written: it is saved or discarded first
            return
        }
        popover?.close()
        hideToolbar()
        hideMarkBar()
        let pop = NSPopover()
        pop.behavior = .transient
        pop.delegate = self
        let kind: MarkKind = mode == .box ? .box : (mode == .point ? .note : (mode == .replace ? .strikeout : model.toolbar.kind))
        let d = CommentDraft(kind: kind, color: model.toolbar.color, note: note, mode: mode, page: page, quote: quote)
        let toolbar = model.toolbar
        let tagModel = model.tags
        let saveDraft = { [weak pop] in
            // a name typed in New Tag… goes in as Return would add it (TAGS.md §2.3)
            if d.tags.naming && TagCatalog.clean(d.tags.newName) != nil { d.tags.commitNew(tagModel) }
            d.saving = true
            // the editor's style row has the last word, and is remembered
            toolbar.setColor(d.color)
            if mode == .text { toolbar.setKind(d.kind) }
            save(d.kind, d.color, d.note, d.tags) { ok in  // after an engine error the popover stays open with the note
                d.saving = false
                if ok { pop?.close() }
            }
        }
        let title = mode == .text ? "New comment" : mode == .box ? "New comment on this area" : mode == .replace ? "Replace with" : "New note"
        let editor = CommentEditor(title: title, draft: d, tags: model.tags, onSave: saveDraft,
                                   onCancel: { [weak pop] in pop?.close() })
        let host = NSHostingController(rootView: editor)
        host.sizingOptions = .preferredContentSize
        pop.contentViewController = host
        pop.show(relativeTo: rect, of: v, preferredEdge: .minY)
        popover = pop
        draft = d
        self.saveDraft = saveDraft
    }

    /// The new-comment editor closed, saved or not: a check's My Comment… waits no longer.
    func popoverDidClose(_ notification: Notification) {
        model?.commentEditorClosed()
    }

    /// A click elsewhere (or Esc) closes the popover only while its note is untouched.
    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        guard popover === self.popover, let d = draft else { return true }
        return !d.changed && !d.saving
    }

    // MARK: Debug

    /// --debug-open-comment: once an open round's PDF is shown, select the phrase's first occurrence and open
    /// the new-comment popover on it. With --debug-note, also type the note, try to close the popover as a click
    /// elsewhere would, then press Save.
    func debugOpenComment(_ phrase: String, note: String?) { pendingComment = (phrase, note) }

    private func selectAndComment(_ phrase: String, note: String?) {
        guard let v = view, let sel = v.document?.findString(phrase, withOptions: []).first else { return }
        willMove()
        v.setCurrentSelection(sel, animate: false)
        v.go(to: sel)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.beginComment()
            guard let note, let self, let pop = self.popover, let draft = self.draft else { return }
            draft.note = note
            pop.performClose(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.saveDraft?() }
        }
    }

    /// --debug-script (and its M1 name --debug-drag): runs once the PDF is settled.
    func debugScript(_ spec: String, out: String?, quit: Bool) {
        pendingScript = DebugScript(spec: spec, out: out, quit: quit, controller: self)
    }

    /// A launch at a page of the hierarchy (--hub): the script starts without a PDF to wait for.
    func startScript() {
        guard let s = pendingScript else { return }
        pendingScript = nil
        runningScript = s
        s.start()
    }
}

/// The floating toolbar's ground: `Palette.float` with `Palette.floatLine` round it, radius 8, in the view's appearance.
/// Every float over the page has one look (design/review-page/BRIEF.md E1): the overview's tag's soft shadow (black 14%,
/// blur 10, 4 pt down), with a shadow path so nothing is redrawn while the page scrolls under it.
final class FloatView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 0.5
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.14
        layer?.shadowRadius = 5  // CALayer's radius is about half SwiftUI's `shadow(radius: 10)` blur
        layer?.shadowOffset = CGSize(width: 0, height: -4)  // 4 pt down (the layer's y goes up)
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 8, cornerHeight: 8, transform: nil)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layer?.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: newSize), cornerWidth: 8, cornerHeight: 8, transform: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Palette.float.cgColor
            layer?.borderColor = Palette.floatLine.cgColor
        }
    }
}

/// The floating toolbar's buttons.
@MainActor
struct ToolbarActions {
    weak var model: AppModel?
    func comment() { model?.beginComment() }
    func place() { model?.placeReanchor() }
}

/// Swatches, kinds and Comment, over the PDF next to a selection or a pending box (UX.md §7).
struct FloatingToolbar: View {
    @ObservedObject var toolbar: ToolbarModel
    let actions: ToolbarActions

    /// The toolbar on the floats' opaque colour, radius 8, a hairline border, as Jump (POLISH §2.4: nothing blurred over
    /// the scrolling PDF; it had popover material); the caller adds it over its view.
    @MainActor
    static func hosted(model: AppModel?) -> NSView {
        guard let model else { return FloatView() }
        return FloatView.holding(FloatingToolbar(toolbar: model.toolbar, actions: ToolbarActions(model: model)))
    }

    var body: some View {
        HStack(spacing: 6) {
            if toolbar.matchOnly && toolbar.reanchor == nil {
                Button { actions.comment() } label: { Text("Comment").fontWeight(.semibold) }
                    .buttonStyle(VerdictButtonStyle(active: true, color: .accentColor))
                    .help("Write a comment (Return)")
            } else if let id = toolbar.reanchor {
                Button { actions.place() } label: { Text("Place \(id)").fontWeight(.semibold) }
                    .buttonStyle(VerdictButtonStyle(active: true, color: .accentColor))
                    .help("Move \(id) here (Return)")
            } else {
                ForEach(MarkColor.allCases) { c in
                    Swatch(color: c, selected: toolbar.color == c) { toolbar.setColor(c) }
                }
                if !toolbar.hasBox {
                    Divider().frame(height: 16)
                    ForEach(MarkKind.textKinds) { k in
                        KindButton(kind: k, selected: toolbar.kind == k, help: "\(k.name) (\(k.key?.uppercased() ?? ""))") {
                            toolbar.setKind(k)
                        }
                    }
                }
                Divider().frame(height: 16)
                Button { actions.comment() } label: { Text("Comment").fontWeight(.semibold) }
                    .buttonStyle(VerdictButtonStyle(active: true, color: .accentColor))
                    .help("Write a comment (Return)")
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 30)
    }
}

struct Swatch: View {
    let color: MarkColor
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle().fill(Color(nsColor: color.fill))
                .overlay(Circle().strokeBorder(Color(nsColor: color.ink).opacity(0.6), lineWidth: 0.5))
                .frame(width: 14, height: 14)
                .padding(2)
                .overlay(Circle().strokeBorder(selected ? Color.primary : .clear, lineWidth: 2))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(color.name) (\(color.key))")
        .accessibilityLabel(color.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// One comment or change, drawn over the page in PDF page space (UX.md §5).
final class MarkAnnotation: PDFAnnotation {
    enum Style { case highlight, underline, strike, sticky, textNote, box, gone, band, unrequested, cross, rubber, pendingBox, reading }

    let style: Style
    let fill: NSColor
    let ink: NSColor
    private(set) var lines: [CGRect]
    let label: String?
    let labelRect: CGRect?
    let labelColor: NSColor
    let labelSize: Int  // which of labelFonts: the type labelPlace found room for
    var faded = false  // resolved or kept as is this round
    var dashed = false  // being re-anchored
    var square = false  // an automatic check's label: square, so it is never read as a comment's
    /// The id label's type at the sizes labelPlace tries in turn (UX.md §5): 8.5 pt Semibold with tabular digits and
    /// the status sign (design/ui-v2/PROPOSAL.md §3); where that does not fit, M1's 7 pt Bold with the sign (a ruler
    /// close to the text: ACL); then 6 pt, with the sign while it fits (closer still: ICML, ACM review), without it
    /// only where nothing else does. `labelPads`: either side.
    static let labelFonts = [NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .semibold),
                             NSFont.systemFont(ofSize: 7, weight: .bold), NSFont.systemFont(ofSize: 6, weight: .bold),
                             NSFont.systemFont(ofSize: 6, weight: .bold)]
    static let labelPads: [CGFloat] = [3, 2, 1, 1]

    /// A comment's label at each of labelFonts' sizes: "○ R1-02", then "○ R1-02" with a thin space (with none, "○R1-02"
    /// read as "OR1-02"), and "R1-02".
    /// A label's colours: open, the label colour filled with white words; closed (faded), an outline on the white
    /// page with the words in the label colour, so the id still reads (≥ 4.5:1 for every label colour).
    static func labelStyle(_ color: NSColor, faded: Bool) -> (fill: NSColor, stroke: NSColor?, text: NSColor) {
        faded ? (NSColor.white.withAlphaComponent(0.92), color.withAlphaComponent(0.55), color) : (color, nil, .white)
    }

    static func labels(_ id: String, glyph: String) -> [String] {
        [glyph + " " + id, glyph + "\u{2009}" + id, glyph + "\u{2009}" + id, id]
    }

    init(rects: [CGRect], style: Style, fill: NSColor, ink: NSColor, label: String? = nil, labelRect: CGRect? = nil,
         labelColor: NSColor = .clear, labelSize: Int = 0) {
        self.style = style
        self.fill = fill
        self.ink = ink
        self.lines = rects
        self.label = label
        self.labelRect = labelRect
        self.labelColor = labelColor
        self.labelSize = labelSize
        super.init(bounds: Self.bounds(rects, labelRect), forType: .square, withProperties: nil)
    }

    required init?(coder: NSCoder) { nil }

    private static func bounds(_ rects: [CGRect], _ labelRect: CGRect?) -> CGRect {
        var b = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
        if let labelRect { b = b.union(labelRect) }
        return b.insetBy(dx: -8, dy: -8)
    }

    func update(rects: [CGRect]) {
        lines = rects
        bounds = Self.bounds(rects, labelRect)
    }

    override func draw(with box: PDFDisplayBox, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let f: CGFloat = faded ? 0.35 : 1
        let inkColor = ink.withAlphaComponent(f).cgColor
        if dashed {
            ctx.setStrokeColor(inkColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [3, 2])
            lines.forEach { ctx.stroke($0.width < 1 ? $0.insetBy(dx: -4, dy: -4) : $0.insetBy(dx: -1, dy: -1)) }
            ctx.setLineDash(phase: 0, lengths: [])
        } else {
            drawMark(ctx, f: f, inkColor: inkColor)
        }
        if let label, let lr = labelRect {
            ctx.setBlendMode(.normal)
            let corner: CGFloat = square ? 0 : labelSize == 0 ? 2 : 1.5
            let style = Self.labelStyle(labelColor, faded: faded)
            ctx.setFillColor(style.fill.cgColor)
            ctx.addPath(CGPath(roundedRect: lr, cornerWidth: corner, cornerHeight: corner, transform: nil))
            ctx.fillPath()
            if let stroke = style.stroke {
                // a closed comment's label is an outline, its id in the label's own colour (the UI audit: white at 80%
                // on the colour at 50% read at 1.8:1)
                ctx.setStrokeColor(stroke.cgColor)
                ctx.setLineWidth(1)
                let inner = lr.insetBy(dx: 0.5, dy: 0.5)
                ctx.addPath(CGPath(roundedRect: inner, cornerWidth: corner, cornerHeight: corner, transform: nil))
                ctx.strokePath()
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            (label as NSString).draw(at: CGPoint(x: lr.minX + Self.labelPads[labelSize], y: lr.minY),
                                     withAttributes: [.font: Self.labelFonts[labelSize], .foregroundColor: style.text])
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func drawMark(_ ctx: CGContext, f: CGFloat, inkColor: CGColor) {
        func line(_ y: (CGRect) -> CGFloat, width: CGFloat) {
            ctx.setStrokeColor(inkColor)
            ctx.setLineWidth(width)
            for r in lines {
                ctx.move(to: CGPoint(x: r.minX, y: y(r)))
                ctx.addLine(to: CGPoint(x: r.maxX, y: y(r)))
            }
            ctx.strokePath()
        }
        switch style {
        case .highlight:
            ctx.setFillColor(fill.withAlphaComponent(0.35 * f).cgColor)
            lines.forEach { ctx.fill($0) }
        case .underline:
            line({ $0.minY + 0.15 * $0.height }, width: 1.2)
        case .strike:
            line({ $0.minY + 0.45 * $0.height }, width: 1.2)
        case .textNote:
            // A note on text (M1): a dotted underline.
            ctx.setLineDash(phase: 0, lengths: [1.2, 1.5])
            line({ $0.minY + 0.5 }, width: 1)
        case .sticky:
            let p = CGPoint(x: lines[0].midX, y: lines[0].midY)
            let r = CGRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9)
            let path = CGPath(roundedRect: r, cornerWidth: 2, cornerHeight: 2, transform: nil)
            ctx.setFillColor(fill.withAlphaComponent(f).cgColor)
            ctx.addPath(path)
            ctx.fillPath()
            ctx.setStrokeColor(inkColor)
            ctx.setLineWidth(1)
            ctx.addPath(path)
            ctx.strokePath()
        case .box:
            for r in lines {
                let path = CGPath(roundedRect: r, cornerWidth: 2, cornerHeight: 2, transform: nil)
                ctx.setFillColor(fill.withAlphaComponent(0.10 * f).cgColor)
                ctx.addPath(path)
                ctx.fillPath()
                ctx.setStrokeColor(inkColor)
                ctx.setLineWidth(1.5)
                ctx.addPath(path)
                ctx.strokePath()
            }
        case .gone:
            // The deletion point: a caret.
            let r = lines[0]
            ctx.setFillColor(inkColor)
            ctx.fill(CGRect(x: r.midX - 0.75, y: r.minY, width: 1.5, height: r.height))
            ctx.move(to: CGPoint(x: r.midX - 3, y: r.minY - 2.5))
            ctx.addLine(to: CGPoint(x: r.midX + 3, y: r.minY - 2.5))
            ctx.addLine(to: CGPoint(x: r.midX, y: r.minY + 1))
            ctx.fillPath()
        case .band, .unrequested:
            // Changed text: a band just below each line, so it never mixes with a comment's colour. It sits under
            // the descenders: PDFKit composites annotations over the page, so a band across them hides them.
            ctx.setFillColor(fill.withAlphaComponent(style == .band ? 1 : 0.7).cgColor)
            lines.forEach { ctx.fill(CGRect(x: $0.minX, y: $0.minY - 2, width: $0.width, height: 2)) }
        case .cross:
            // A deletion: a caret under the line at the deletion point, in the change bands' lane, so it never covers
            // the letters (design/review-page/BRIEF.md E10; it was a × over them). `.gone`'s triangle without its bar,
            // so it is not taken for a comment whose text has gone: 6 pt wide, its apex at the line box's foot, its base
            // 2.5 pt below, in the gap before the next line's ascenders.
            let r = lines[0]
            ctx.setFillColor(ink.cgColor)
            ctx.move(to: CGPoint(x: r.midX - 3, y: r.minY - 2.5))
            ctx.addLine(to: CGPoint(x: r.midX + 3, y: r.minY - 2.5))
            ctx.addLine(to: CGPoint(x: r.midX, y: r.minY))
            ctx.fillPath()
        case .reading:
            // A paragraph to read: a bar in the page margin beside it (UX.md §18).
            ctx.setFillColor(fill.cgColor)
            for r in lines {
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: 1, cornerHeight: 1, transform: nil))
                ctx.fillPath()
            }
        case .rubber, .pendingBox:
            ctx.setFillColor(ink.withAlphaComponent(style == .rubber ? 0.08 : 0.05).cgColor)
            lines.forEach { ctx.fill($0) }
            ctx.setStrokeColor(ink.cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            lines.forEach { ctx.stroke($0) }
        }
    }
}

/// The selected comment's outline in page space (UX.md §5; POLISH §2.2): one 2 pt accent contour round the union of
/// its lines, 1–3 pt outside them, with the paper's white in the 1 pt between, so the outline never touches the mark
/// it surrounds (a square round a point note), and the same ring round its id label.
enum SelectionOutline {
    static func boxes(lines: [CGRect], label: CGRect?) -> [OutlineView.Box] {
        let squares = lines.filter { $0.width < 1 && $0.height < 1 }.map { CGRect(x: $0.midX - 4.5, y: $0.midY - 4.5, width: 9, height: 9) }
        // A point note in the margin has its label beside it, or over it: the two rings crossed, and the square's was
        // drawn over the label's sign and first letters ("○ R2-06" read "◎ ʀ2-06"; BACKLOG O32). Rings that would touch
        // become one ring round both.
        var label = label, apart: [CGRect] = []
        for sq in squares {
            if let l = label, sq.insetBy(dx: -3, dy: -3).intersects(l.insetBy(dx: -3, dy: -3)) { label = l.union(sq) } else { apart.append(sq) }
        }
        return runs(lines.filter { !($0.width < 1 && $0.height < 1) }).flatMap { run -> [OutlineView.Box] in
            // the runs are 1.5 pt outside the lines: the gap's middle 0.5 pt out, the accent's 2 pt
            let gap = contour(run.map { $0.insetBy(dx: 1, dy: 1) }), line = contour(run.map { $0.insetBy(dx: -0.5, dy: -0.5) })
            return [OutlineView.Box(rect: bounds(gap), width: 1, points: gap, paper: true),
                    OutlineView.Box(rect: bounds(line), width: 2, points: line)]
        } + apart.flatMap { ring($0) } + (label.map { ring($0, corner: 2) } ?? [])
    }

    /// A rect's ring: the paper's white 0–1 pt outside it, the 2 pt accent 1–3 pt outside (the selected change too).
    static func ring(_ r: CGRect, corner: CGFloat = 0) -> [OutlineView.Box] {
        [OutlineView.Box(rect: r.insetBy(dx: -0.5, dy: -0.5), corner: corner, width: 1, paper: true),
         OutlineView.Box(rect: r.insetBy(dx: -2, dy: -2), corner: corner + 1, width: 2)]
    }

    /// The lines (in the mark's order, page space with y up) as the text lines they are on, 1.5 pt larger all round,
    /// in runs that one contour can go round: each line below the one before and overlapping it across. A mark that
    /// goes on in the next column, below a figure, or from the end of one line to the start of the next without
    /// overlapping gets a contour per run.
    static func runs(_ lines: [CGRect]) -> [[CGRect]] {
        var merged: [CGRect] = []
        for r in lines {  // rects of one text line (a word in another font): one rect
            if let last = merged.last, min(last.maxY, r.maxY) - max(last.minY, r.minY) > 0.5 * min(last.height, r.height) {
                merged[merged.count - 1] = last.union(r)
            } else {
                merged.append(r)
            }
        }
        var out: [[CGRect]] = []
        for r in merged.map({ $0.insetBy(dx: -1.5, dy: -1.5) }) {
            if let prev = out.last?.last, r.maxY <= prev.midY, prev.minY - r.maxY < max(prev.height, r.height),
               r.minX < prev.maxX, prev.minX < r.maxX {
                out[out.count - 1].append(r)
            } else {
                out.append([r])
            }
        }
        return out
    }

    /// The outline of a run of lines, top to bottom: two lines meet halfway between them, and the edges step at each
    /// line's ends. Clockwise from the first line's top left.
    static func contour(_ run: [CGRect]) -> [CGPoint] {
        var ls = run
        for i in ls.indices.dropLast() {
            let m = (ls[i].minY + ls[i + 1].maxY) / 2
            ls[i] = CGRect(x: ls[i].minX, y: m, width: ls[i].width, height: ls[i].maxY - m)
            ls[i + 1] = CGRect(x: ls[i + 1].minX, y: ls[i + 1].minY, width: ls[i + 1].width, height: m - ls[i + 1].minY)
        }
        var p = [CGPoint(x: ls[0].minX, y: ls[0].maxY), CGPoint(x: ls[0].maxX, y: ls[0].maxY)]
        for (i, l) in ls.enumerated() {
            p.append(CGPoint(x: l.maxX, y: l.minY))
            if i + 1 < ls.count { p.append(CGPoint(x: ls[i + 1].maxX, y: l.minY)) }
        }
        p.append(CGPoint(x: ls[ls.count - 1].minX, y: ls[ls.count - 1].minY))
        for i in stride(from: ls.count - 1, to: 0, by: -1) {
            p.append(CGPoint(x: ls[i].minX, y: ls[i].maxY))
            p.append(CGPoint(x: ls[i - 1].minX, y: ls[i].maxY))
        }
        // the corners only: no point twice, none on a straight edge
        var out: [CGPoint] = []
        for q in p where out.last != q { out.append(q) }
        if out.count > 1, out.last == out.first { out.removeLast() }
        return out.indices.compactMap { i in
            let a = out[(i + out.count - 1) % out.count], b = out[i], c = out[(i + 1) % out.count]
            return (a.x == b.x && b.x == c.x) || (a.y == b.y && b.y == c.y) ? nil : b
        }
    }

    private static func bounds(_ p: [CGPoint]) -> CGRect {
        let xs = p.map(\.x), ys = p.map(\.y)
        return CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0),
                      height: (ys.max() ?? 0) - (ys.min() ?? 0))
    }
}

/// Accent outlines over the PDF in a view of their own (the flash, the selected comment and change), laid in the PDF's
/// document view so they scroll with the page; PDFKit redraws a whole page for a changed annotation. Clicks pass
/// through. The strokes are shape layers: placing, showing or hiding an outline draws nothing on the main thread.
final class OutlineView: NSView {
    /// One outline in page space. `width` and `corner` are page points, so they follow the zoom as a mark's lines do;
    /// a nil `width` is the view's own width, in document points.
    struct Box: Equatable {
        var rect: CGRect
        var corner: CGFloat = 0
        var width: CGFloat? = nil
        /// A polygon instead of the rect (a merged contour, SelectionOutline), with `rect` its bounds.
        var points: [CGPoint]? = nil
        /// In the paper's white, not the accent: the gap between a selection's outline and its mark.
        var paper = false
    }

    /// The placed outlines in the view's coordinates (for the tests).
    private(set) var strokes: [(path: CGPath, width: CGFloat, paper: Bool)] = []
    private let width: CGFloat

    init(width: CGFloat) {
        self.width = width
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    /// Over `rects` (page space) of `page`; false when the page is not laid out.
    @MainActor
    func place(_ rects: [CGRect], on page: PDFPage, in v: PDFView?) -> Bool {
        place(rects.map { Box(rect: $0) }, on: page, in: v)
    }

    @MainActor
    func place(_ boxes: [Box], on page: PDFPage, in v: PDFView?) -> Bool {
        guard let v, let doc = v.documentView, !boxes.isEmpty, v.document?.index(for: page) ?? -1 >= 0 else { return false }
        func inDoc(_ r: CGRect) -> CGRect { doc.convert(v.convert(r, from: page), from: v) }
        let scale = inDoc(CGRect(x: 0, y: 0, width: 100, height: 100)).width / 100  // page points → document points
        let placed = boxes.map { (rect: inDoc($0.rect), corner: $0.corner * scale, width: $0.width.map { $0 * scale } ?? width,
                                  points: $0.points?.map { doc.convert(v.convert($0, from: page), from: v) }, paper: $0.paper) }
        let union = placed.map { $0.rect.insetBy(dx: -$0.width, dy: -$0.width) }.reduce(CGRect.null) { $0.union($1) }
        if superview !== doc { doc.addSubview(self) }
        frame = union
        strokes = placed.map { p in
            guard let points = p.points else {
                return (CGPath(roundedRect: convert(p.rect, from: doc), cornerWidth: p.corner, cornerHeight: p.corner,
                               transform: nil), p.width, p.paper)
            }
            let path = CGMutablePath()
            path.addLines(between: points.map { convert($0, from: doc) })
            path.closeSubpath()
            return (path, p.width, p.paper)
        }
        needsDisplay = true
        return true
    }

    /// One shape layer per outline, in the accent colour of the view's appearance (AppKit calls this again when the
    /// appearance changes), or the paper's white.
    override func updateLayer() {
        guard let layer else { return }
        let shapes = (layer.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
        shapes.dropFirst(strokes.count).forEach { $0.removeFromSuperlayer() }
        let color = NSColor.controlAccentColor.cgColor, paper = NSColor.white.cgColor  // the page is white in either mode
        for (i, s) in strokes.enumerated() {
            let shape = i < shapes.count ? shapes[i] : CAShapeLayer()
            if shape.superlayer == nil {
                shape.actions = ["path": NSNull(), "lineWidth": NSNull(), "strokeColor": NSNull(), "bounds": NSNull(),
                                 "position": NSNull()]  // no implicit animation when an outline moves
                shape.fillColor = nil
                shape.lineJoin = .round
                layer.addSublayer(shape)
            }
            shape.frame = layer.bounds
            shape.path = s.path
            shape.lineWidth = s.width
            shape.strokeColor = s.paper ? paper : color
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: The column beside the scroller (design/review-page/BRIEF.md §3–6; mac/UX.md §42)

extension PDFController {
    /// The column's view in a new PDF view (another paper, Review again after the hub), and its hover's hooks.
    func attachLane(_ v: ReviewPDFView) {
        lane?.removeFromSuperview()
        laneHover.reset()
        let l = MarkLane()
        l.controller = self
        v.addSubview(l)
        lane = l
        laneHover.canOpen = { [weak self] in self?.laneCanOpen ?? false }
        laneHover.changed = { [weak self] c in self?.laneChanged(c) }
        laneWindow.go = { [weak self] k in self?.laneRowClicked(k) }
        laneWindow.hover = { [weak self] inside in
            if inside { self?.laneHover.enterWindow() } else { self?.laneHover.leaveWindow() }
        }
        if !strip.items.isEmpty { l.set(strip.items, layout: strip.layout, find: strip.find) }
    }

    /// The scroller's width (a mouse's, or an overlay scroller's when it shows), which the column's foot keeps clear of.
    private var scrollerInset: CGFloat {
        guard let sv = view?.documentView?.enclosingScrollView else { return 0 }
        return sv.scrollerStyle == .legacy
            ? (sv.hasVerticalScroller ? sv.verticalScroller?.frame.width ?? 0 : 0)
            : NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)
    }

    /// The column's height: from 46 pt under the view's top to `max(4, scroller)` above its foot.
    var laneHeight: CGFloat { max(0, (view?.bounds.height ?? 0) - StripLayout.top - max(4, scrollerInset)) }

    /// The column at R − 50 … R − 20, clear of the scroller as the find's button is; laid again at a new height (the
    /// window closes at once when the view resizes).
    func placeLane() {
        guard let v = view, let l = lane else { return }
        if l.superview !== v { v.addSubview(l) }
        let h = laneHeight, foot = max(4, scrollerInset)
        let f = CGRect(x: v.bounds.width - 50, y: foot - StripLayout.below, width: StripLayout.width,
                       height: h + StripLayout.above + StripLayout.below)
        if l.frame != f {
            if l.frame.size != .zero, laneHover.shown != nil { closeLane() }
            l.frame = f
        }
        if h != strip.height, strip.set(strip.items, height: h, find: strip.find) {
            l.set(strip.items, layout: strip.layout, find: strip.find)
            updateLaneHalo()
        }
    }

    /// The selection's halo (a comment's or an edit's glyph, however it was selected), Find's current match, and the
    /// rail when the page is wider than the view.
    func updateLaneHalo() {
        guard let l = lane else { return }
        let sel: ScrollerMark.Target? = selectedID.map { .comment($0) } ?? selectedChangeID.map { .change($0) }
        let glyph = sel.flatMap { t in strip.items.firstIndex { $0.target == t } }.flatMap { strip.layout.glyph(of: $0) }
        let current = strip.find ? find.index.flatMap { i in strip.items.firstIndex { $0.target == .find(i) } }.map { strip.layout.ys[$0] } : nil
        let rail = (view?.documentView?.frame.width ?? 0) > (view?.bounds.width ?? 0) + 0.5
        l.setHalo(glyph, current: current, rail: rail)
        l.refreshCurrentLabel()
    }

    /// The targets of a group, to find it again in a new layout.
    private func shownTargets(_ g: Int) -> Set<ScrollerMark.Target> {
        guard g < strip.layout.groups.count else { return [] }
        return Set(strip.layout.groups[g].members.map { strip.items[$0].target })
    }

    /// Whether the window may open now (BRIEF §4.1): no button down, the PDF still for 150 ms, the app active (unless
    /// forced), and no other float: a selection's toolbar (not a find match's Comment), the mark's toolbar, a reference
    /// preview, the composer, a popover.
    var laneCanOpen: Bool {
        guard NSEvent.pressedMouseButtons == 0, ProcessInfo.processInfo.systemUptime - lastScroll >= 0.15,
              laneForced || NSApp.isActive, !markBarShown, !previewShown, popover?.isShown != true,
              model?.showBuildDetails != true else { return false }
        if toolbarShown && !(model?.toolbar.matchOnly ?? false) { return false }
        return !NSApp.windows.contains { $0.isVisible && $0.className.contains("Popover") }
    }

    var laneShown: Bool { laneHover.shown != nil }

    /// The pointer over the column (`MarkLane`): in group `g`'s zone, or none.
    func lanePointer(_ g: Int?, at p: CGPoint?) {
        guard laneForced || NSApp.isActive || g == nil else { return }
        laneHover.point(g, at: p)
    }

    func lanePress(_ down: Bool) { laneHover.press(down) }

    /// The page's id label or a link a click previews under a point of the PDF view: it wins over the column.
    func pageWins(at p: CGPoint) -> Bool {
        guard let v = view, let page = v.page(for: p, nearest: false) else { return false }
        let q = v.convert(p, to: page)
        return labelHit(page: page, at: q) || previewLink(page: page, at: q) != nil
    }

    /// A group's rows, with the pointer where it is now (a run's five nearest matches).
    func laneRows(_ g: Int, pointer: CGFloat? = nil) -> LaneRows {
        guard g < strip.layout.groups.count else { return LaneRows() }
        let cards = Dictionary((model?.panel.cards ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let all = (model?.changes.unrequested ?? []) + (model?.changes.linked ?? [])
        let changes = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var edits: [String: Int] = [:]
        for ch in all { for l in ch.links { edits[l.id, default: 0] += 1 } }
        return LaneRows.make(strip.layout.groups[g].members, items: strip.items, ys: strip.layout.ys, pointer: pointer ?? laneHover.pointer?.y,
                             currentMatch: strip.find ? find.index : nil, card: { cards[$0] }, change: { changes[$0] },
                             edits: { edits[$0] ?? 0 }, line: { [weak self] in self?.find.matchLine($0) ?? LaneMatchLine() },
                             check: { [weak self] id in self?.model?.checksToCheck.first { $0.id == id } })
    }

    /// On a grown run, the match nearest the pointer: the one a click opens.
    private var laneNear: CGFloat? {
        guard strip.find, let g = laneHover.grown, g < strip.layout.groups.count, let y = laneHover.pointer?.y,
              strip.layout.groups[g].glyphs.contains(where: { strip.layout.glyphs[$0].shape == .run }) else { return nil }
        return strip.layout.groups[g].members.map { strip.layout.ys[$0] }.min { abs($0 - y) < abs($1 - y) }
    }

    private func laneChanged(_ c: LaneHover.Change) {
        switch c {
        case .grow: break
        case .pointer: if strip.find, laneHover.shown != nil { showLaneRows() }
        case .open(let instant): showLaneWindow(appear: !instant)
        case .glide: showLaneWindow(appear: false, glide: true)
        case .close(let fade): hideLaneWindow(fade: fade)
        }
        lane?.setGrown(laneHover.grown, pressed: laneHover.pressed, near: laneNear)
    }

    /// The window's frame for its rows (BRIEF §5.5), in the PDF view (y up).
    private func laneFrame(_ rows: LaneRows, group g: Int) -> CGRect? {
        guard let v = view, g < strip.layout.groups.count else { return nil }
        let under: CGFloat = find.open ? 41 : 40  // the find's bar, or its button, 10 pt down
        let f = LaneRows.frame(height: rows.height, first: StripLayout.top + strip.layout.groups[g].first, view: v.bounds.size, under: under)
        return CGRect(x: f.minX, y: v.bounds.height - f.maxY, width: f.width, height: f.height)
    }

    /// The rows of the shown group again, in place (the pointer moved along a run, the group changed).
    private func showLaneRows() {
        guard let g = laneHover.shown, let host = laneWindowView, host.superview != nil else { return }
        let rows = laneRows(g)
        laneWindow.show(rows)
        if let f = laneFrame(rows, group: g), f != host.frame { host.frame = f; noteLaneFrame(f) }
    }

    /// The window appears (a fade with a 4 pt slide out of the column, 120 ms ease-out; a 100 ms fade with Reduce
    /// Motion; at once when warm), or glides to another group (120 ms ease-out; a jump with Reduce Motion), its rows
    /// changing at once.
    private func showLaneWindow(appear: Bool, glide: Bool = false) {
        guard let v = view, let g = laneHover.shown else { return }
        let rows = laneRows(g)
        guard !rows.rows.isEmpty, let f = laneFrame(rows, group: g) else { return laneHover.closeNow() }
        laneWindow.onMark = !laneHover.inWindow
        laneWindow.show(rows)
        let host = laneWindowView ?? FloatView.holding(LaneWindowView(model: laneWindow))
        laneWindowView = host
        let fresh = host.superview !== v || host.isHidden
        if host.superview !== v { v.addSubview(host, positioned: .above, relativeTo: lane) }
        host.isHidden = false
        noteLaneFrame(f)
        let reduce = Motion.reduced
        if fresh {
            host.layer?.removeAllAnimations()
            host.frame = appear && !reduce ? f.offsetBy(dx: 4, dy: 0) : f
            host.alphaValue = appear ? 0 : 1
            if appear {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = reduce ? 0.1 : 0.12
                    ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.33, 1, 0.68, 1)
                    ctx.allowsImplicitAnimation = true
                    host.animator().alphaValue = 1
                    host.animator().frame = f
                }
            }
        } else if glide && !reduce {
            host.alphaValue = 1
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.33, 1, 0.68, 1)
                host.animator().frame = f
            }
        } else {
            host.alphaValue = 1
            host.frame = f
        }
        if laneMonitor == nil {
            // a click anywhere but the window and the column, and any key, close it at once; Esc is spent doing so
            laneMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] e in
                let type = e.type, key = type == .keyDown ? e.keyCode : 0, window = e.window, at = e.locationInWindow
                let spent = MainActor.assumeIsolated { () -> Bool in
                    guard let self, self.laneShown else { return false }
                    if type == .leftMouseDown, let host = self.laneWindowView, window === host.window,
                       host.bounds.contains(host.convert(at, from: nil)) { return false }
                    if type == .leftMouseDown, let l = self.lane, window === l.window, l.group(at: l.convert(at, from: nil)) != nil {
                        return false
                    }
                    self.closeLane()
                    return type == .keyDown && key == 53
                }
                return spent ? nil : e
            }
        }
    }

    /// The window's frame in the column's coordinates (for the aim's triangle), and the find match's Comment button
    /// hidden where the window would cover it.
    private func noteLaneFrame(_ f: CGRect) {
        guard let v = view else { return }
        laneHover.windowFrame = CGRect(x: f.minX - (v.bounds.width - 50), y: v.bounds.height - f.maxY - StripLayout.top,
                                       width: f.width, height: f.height)
        if let bar = toolbarView, toolbarShown, bar.frame.intersects(f) {
            bar.isHidden = true
            laneHidToolbar = true
        }
    }

    /// The window goes: a 100 ms fade (ease-in) after the grace, at once otherwise; a Comment button it hid comes back.
    private func hideLaneWindow(fade: Bool) {
        if let m = laneMonitor { NSEvent.removeMonitor(m) }
        laneMonitor = nil
        laneWindow.onMark = true
        laneWindow.hot = nil
        if laneHidToolbar {
            laneHidToolbar = false
            if model?.hasPDFSelection == true { showToolbar() }
        }
        guard let host = laneWindowView, !host.isHidden else { return }
        if fade {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.1
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.42, 0, 1, 1)
                host.animator().alphaValue = 0
            }, completionHandler: { [weak self, weak host] in
                MainActor.assumeIsolated {
                    guard let self, let host, self.laneHover.shown == nil else { return }
                    host.isHidden = true
                }
            })
        } else {
            host.isHidden = true
            host.alphaValue = 1
        }
    }

    /// Closes the column's window at once (a click, a key, Esc, a zoom, Focus, Find, change marks, a resize).
    func closeLane() { laneHover.closeNow() }

    /// A click on a group's mark: its first row (Find: the current match, else the match nearest the pointer).
    func laneClick(_ g: Int, at p: CGPoint) {
        guard g < strip.layout.groups.count else { return }
        let rows = laneRows(g, pointer: p.y)
        laneHover.closeNow()
        if let t = rows.target { laneGo(t) }
    }

    /// A click on a row of the window, or on "+N more" (the first item not listed).
    func laneRowClicked(_ k: Int) {
        let rows = laneWindow.rows
        let t = k < rows.rows.count ? rows.rows[k].target : rows.moreTarget
        laneHover.closeNow()
        if let t { laneGo(t) }
    }

    /// VoiceOver pressed an element: its item; in Find, the current match if it is on that page, else its first.
    func laneAccessibilityPress(_ idx: [Int]) {
        let ts = idx.filter { $0 < strip.items.count }.map { strip.items[$0].target }
        if let i = find.index, ts.contains(.find(i)) { return laneGo(.find(i)) }
        if let t = ts.first { laneGo(t) }
    }

    /// Goes to an item as Jump does (`goMark`). The halo is drawn first, before the PDF moves; the item already
    /// selected scrolls nothing, its page mark flashing again.
    func laneGo(_ t: ScrollerMark.Target) {
        guard let model else { return }
        switch t {
        case .comment(let id) where selectedID == id:
            model.tab = .comments
            if let c = model.comment(id) { flash(page: c.page, rects: c.rects) }
        case .change(let id) where selectedChangeID == id:
            model.tab = .changes
            if let ch = model.change(id) { flash(page: ch.page, rects: ch.rects) }
        case .comment(let id):
            selectedID = id
            selectedChangeID = nil
            updateLaneHalo()
            selectedID = nil  // `setSelected` lays its outline
            goMark(t)
        case .change(let id):
            selectedChangeID = id
            updateLaneHalo()
            selectedChangeID = nil
            goMark(t)
        case .find, .check:
            goMark(t)
        }
        updateLaneHalo()
    }
}
