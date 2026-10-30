import AppKit
import SwiftUI
import XCTest
@testable import Paperole

/// UI v2.2 fixes (2026-10-18): the panel's leftovers. Synthetic fixtures only.
@MainActor
final class FloatingHeaderTests: XCTestCase {
    private func spin(_ s: Double = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    private func items(_ ids: [String]) throws -> [PanelTable.Row] {
        try ids.map { .item(.card(CardModel(try makeComment(["id": $0]), round: 2, pdfs: [:], textX: [], showChanges: true))) }
    }

    private func makeTable() -> (PanelTable, PanelScroller, NSWindow) {
        _ = NSApplication.shared
        let scroller = PanelScroller()
        let table = PanelTable(scroller: scroller, expanded: nil, compact: { _, _ in AnyView(Color.clear) },
                               expandedView: { _ in AnyView(Color.gray.frame(height: 700)) })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: true)  // never ordered in
        window.isReleasedWhenClosed = false
        window.contentView = table.scrollView
        table.scrollView.layoutSubtreeIfNeeded()
        return (table, scroller, window)
    }

    /// The group-row views drawn over the list that are visible.
    private func floating(_ sv: NSScrollView) -> [NSTableRowView] {
        var out: [NSTableRowView] = []
        func walk(_ v: NSView) {
            if let r = v as? NSTableRowView, r.isGroupRowStyle || r.isFloating, !r.isHiddenOrHasHiddenAncestor { out.append(r) }
            v.subviews.forEach(walk)
        }
        walk(sv)
        return out
    }

    func testNoHeaderStaysOverTheOneCardInFocus() throws {
        let (table, scroller, window) = makeTable()
        let ids = (1...12).map { String(format: "R1-%02d", $0) }
        table.show([.header("To check")] + (try items(ids)) + [.gap, .fold("Closed this round", "Show", group: .closed)])
        table.setExpanded("R1-07")
        scroller.debugScroll(420)  // the card's top under the floating header
        table.scrollView.layoutSubtreeIfNeeded()
        spin()
        XCTAssertFalse(floating(table.scrollView).isEmpty, "the header floats over the card")
        // Focus: the list shows the one card at its top
        table.show(try items(["R1-07"]))
        table.scrollToTop()
        table.scrollView.layoutSubtreeIfNeeded()
        spin()
        let left = floating(table.scrollView)
        XCTAssertTrue(left.isEmpty, "no header left over the card: \(left.map(\.frame))")
        window.close()
    }

    /// The demo's repro (card R2-07; focus on): Focus began while the panel's scroll to the card was still animating,
    /// and the animation went on scrolling the one-card list, leaving the To check header over the card's top.
    func testFocusDuringAScrollLeavesNoHeader() throws {
        let (table, scroller, window) = makeTable()
        let ids = (1...12).map { String(format: "R1-%02d", $0) }
        table.show([.header("To check")] + (try items(ids)) + [.gap, .fold("Closed this round", "Show", group: .closed)])
        table.setExpanded("R1-07")
        scroller.debugScroll(200)
        table.scrollView.layoutSubtreeIfNeeded()
        spin()
        scroller.scroll(by: 160, animated: true)  // a card selected: the panel scrolls to it over 0.2 s
        spin(0.03)
        table.show(try items(["R1-07"]))  // Focus at once
        table.scrollToTop()
        spin(0.4)
        table.scrollView.layoutSubtreeIfNeeded()
        spin()
        XCTAssertEqual(table.scrollView.contentView.bounds.minY, 0, accuracy: 0.5, "the card at the top")
        let left = floating(table.scrollView)
        XCTAssertTrue(left.isEmpty, "no header left over the card: \(left.map(\.frame))")
        window.close()
    }
}

/// A card opened while the first group's header floats (visual review, 2026-10-18: the demo at the panel's 400 pt,
/// R1-19, R2-07, then R2-08's mark clicked): the table resizes itself range by range inside a height change, the
/// collapsing card first, and when the list got shorter than its scroll there, the clip view scrolled in the middle of
/// the table's update; the floating header whose place came back into view got a second view, and the next update
/// threw "The row at 0 is not floating". No header floats now while the list can scroll inside the table's update; it
/// floats again after, and the list ends where it would have.
@MainActor
final class FloatingHeaderUpdateTests: XCTestCase {
    private func spin(_ s: Double = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    /// Records the list's scrolls made inside the table's own update (its row data resizing the table) while its
    /// headers float.
    @MainActor private final class ScrollWatch: NSObject {
        var inside: [CGFloat] = []
        private let clip: NSClipView
        private let table: NSTableView
        init(_ sv: NSScrollView) {
            clip = sv.contentView
            table = sv.documentView as! NSTableView
            super.init()
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                                   object: clip)
        }
        @objc private func scrolled() {
            let inUpdate = Thread.callStackSymbols.contains { $0.contains("NSTableRowData") || $0.contains("NSTableRowHeightData") }
            if inUpdate, table.floatsGroupRows { inside.append(clip.bounds.minY) }
        }
        func stop() { NotificationCenter.default.removeObserver(self) }
    }

    private final class Height: ObservableObject {
        @Published var value: CGFloat = 1000
    }

    private struct Sized: View {
        @ObservedObject var height: Height
        var body: some View { Color.gray.frame(height: height.value) }
    }

    /// A 400 × 790 list (never ordered in) whose expanded cards are as tall as `heights` says (300 otherwise; `grows`:
    /// the card whose height follows `height`).
    private func makeTable(_ heights: [String: CGFloat], grows: String? = nil, height: Height = Height())
        -> (PanelTable, PanelScroller, NSScrollView, NSWindow) {
        _ = NSApplication.shared
        let scroller = PanelScroller()
        let table = PanelTable(scroller: scroller, expanded: nil, compact: { _, _ in AnyView(Color.clear) },
                               expandedView: { c in
                                   c.id == grows ? AnyView(Sized(height: height)) : AnyView(Color.gray.frame(height: heights[c.id] ?? 300))
                               })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 790), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = table.scrollView
        settle(table.scrollView)
        return (table, scroller, table.scrollView, window)
    }

    private func settle(_ sv: NSScrollView) {
        sv.layoutSubtreeIfNeeded()
        spin()
    }

    private func items(_ n: ClosedRange<Int>) throws -> [PanelTable.Row] {
        try n.map { i in
            .item(.card(CardModel(try makeComment(["id": String(format: "R1-%02d", i)]), round: 2, pdfs: [:], textX: [],
                                  showChanges: true)))
        }
    }

    /// The row views the table has for a row, in the list and floating over it.
    private func views(ofRow row: Int, in sv: NSScrollView) -> Int {
        guard let table = sv.documentView as? NSTableView else { return 0 }
        var n = 0
        func walk(_ v: NSView) {
            if let r = v as? NSTableRowView { if table.row(for: r) == row { n += 1 }; return }
            v.subviews.forEach(walk)
        }
        walk(sv)
        return n
    }

    private func floats(_ sv: NSScrollView) -> Bool { (sv.documentView as? NSTableView)?.floatsGroupRows == true }

    /// The furthest the list scrolls: its rows and its 12 pt foot below the view.
    private func maxOffset(_ sv: NSScrollView) -> CGFloat {
        guard let t = sv.documentView as? NSTableView, t.numberOfRows > 0 else { return 0 }
        return max(0, t.rect(ofRow: t.numberOfRows - 1).maxY + 12 - sv.contentView.bounds.height)
    }

    func testAStepWhoseCollapsingCardComesFirstNeverScrollsInsideTheUpdate() throws {
        let (table, scroller, sv, window) = makeTable(["R1-03": 608, "R1-05": 1043, "R1-01": 400])
        table.show([.header("To check")] + (try items(1...6)) + [.gap, .header("For the student"), .hint("Notes.")])
        settle(sv)
        table.setExpanded("R1-03")
        settle(sv)
        scroller.debugScroll(40)  // the header floats over R1-01
        settle(sv)
        let watch = ScrollWatch(sv)
        defer { watch.stop() }
        // R1-03 collapses before R1-05 grows: the list is 362 pt tall in between, shorter than its scroll
        table.setExpanded("R1-05")
        XCTAssertEqual(watch.inside, [], "no scroll inside the table's update while a header floats")
        XCTAssertTrue(floats(sv), "the headers float again")
        // R1-05's top stays where it was in view (734 pt down) as far as the list goes: the list's top
        XCTAssertEqual(sv.contentView.bounds.minY, 0, accuracy: 0.5)
        settle(sv)
        XCTAssertEqual(views(ofRow: 0, in: sv), 1, "one view for the first header")
        scroller.debugScroll(160)
        settle(sv)
        // R1-05 (1043 pt) closes and R1-01 (400 pt) opens: 730 pt of list in a 790 pt view, which ends at its top
        table.setExpanded("R1-01")
        XCTAssertEqual(watch.inside, [], "no scroll inside the table's update while a header floats")
        XCTAssertTrue(floats(sv))
        XCTAssertEqual(sv.contentView.bounds.minY, 0, accuracy: 0.5)
        settle(sv)
        XCTAssertEqual(table.expandedID, "R1-01")
        XCTAssertEqual(views(ofRow: 0, in: sv), 1)
        window.close()
    }

    func testRowsThatGoAtTheEndNeverScrollInsideTheUpdate() throws {
        let (table, scroller, sv, window) = makeTable(["R1-12": 600])
        table.show([.header("To check")] + (try items(1...12)) + [.gap, .fold("Closed this round", "Show", group: .closed)])
        settle(sv)
        table.setExpanded("R1-12")
        settle(sv)
        scroller.debugScroll(maxOffset(sv))  // the list's end
        settle(sv)
        let offset = sv.contentView.bounds.minY
        XCTAssertGreaterThan(offset, 300)
        let top = try XCTUnwrap(table.frame(of: "R1-12")).minY  // R1-12's top in view
        let watch = ScrollWatch(sv)
        defer { watch.stop() }
        table.show([.header("To check")] + (try items(1...3)) + (try items(12...12)) + [.gap, .fold("Closed this round", "Show", group: .closed)])
        XCTAssertEqual(watch.inside, [], "no scroll inside the table's update while a header floats")
        XCTAssertTrue(floats(sv))
        // the expanded card keeps its place in view as far as the list goes, and the list ends at its foot
        XCTAssertLessThanOrEqual(sv.contentView.bounds.minY, maxOffset(sv) + 0.5)
        XCTAssertEqual(try XCTUnwrap(table.frame(of: "R1-12")).minY, max(top, 166 - maxOffset(sv)), accuracy: 0.5)
        window.close()
    }

    func testACardThatGetsShorterAtTheEndNeverScrollsInsideTheUpdate() throws {
        let height = Height()
        let (table, scroller, sv, window) = makeTable([:], grows: "R1-06", height: height)
        table.show([.header("To check")] + (try items(1...6)) + [.gap, .header("For the student"), .hint("Notes.")])
        settle(sv)
        table.setExpanded("R1-06")
        settle(sv)
        scroller.debugScroll(maxOffset(sv))
        settle(sv)
        XCTAssertGreaterThan(sv.contentView.bounds.minY, 300)
        let watch = ScrollWatch(sv)
        defer { watch.stop() }
        height.value = 200  // an editor closed: the card is measured again and its row gets shorter
        for _ in 0..<5 { settle(sv) }
        XCTAssertEqual(try XCTUnwrap(table.frame(of: "R1-06")).height, 200, accuracy: 0.5, "the row took the new height")
        XCTAssertEqual(watch.inside, [], "no scroll inside the table's update while a header floats")
        XCTAssertTrue(floats(sv))
        XCTAssertEqual(sv.contentView.bounds.minY, maxOffset(sv), accuracy: 0.5, "the list ends at its foot")
        window.close()
    }
}

/// The status line's page follows a scroll of the PDF's clip view (a card revealed with ScrollAnimator), not only
/// PDFView's own page changes (BACKLOG O32: it said p.8 with p.7 filling the view).
@MainActor
final class StatusPageTests: XCTestCase {
    func testThePageFollowsAProgrammaticScroll() throws {
        _ = NSApplication.shared
        var o = LaunchOptions()
        o.fixture = StepTests.fixtures.appendingPathComponent("state-m2a.json").path
        let model = AppModel(options: o)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let v = ReviewPDFView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(v)
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        model.pdf.attach(v)
        model.pdf.update(url: model.pdfURL, key: MarkKey(version: model.stateVersion, showChanges: model.showChanges))
        v.layoutDocumentView()
        let doc = try XCTUnwrap(v.document)
        XCTAssertGreaterThan(doc.pageCount, 1)
        let clip = try XCTUnwrap(v.documentView?.enclosingScrollView?.contentView)
        func scroll(toPage i: Int) {
            let page = doc.page(at: i)!
            let r = clip.convert(v.convert(page.bounds(for: .cropBox), from: page), from: v)
            ScrollAnimator.scroll(clip.enclosingScrollView!, to: clip.constrainBoundsRect(
                NSRect(x: clip.bounds.minX, y: clip.isFlipped ? r.minY : r.maxY - clip.bounds.height, width: clip.bounds.width,
                       height: clip.bounds.height)).origin, duration: 0.1)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }
        let last = doc.pageCount - 1
        scroll(toPage: last)
        XCTAssertEqual(model.pdf.position.page, model.pdf.shownPage)
        XCTAssertEqual(model.pdf.position.page, last)
        scroll(toPage: 0)  // back, as a card earlier in the paper does
        XCTAssertEqual(model.pdf.position.page, 0, "the line follows the scroll back")
        window.close()
    }
}

/// A selected point note whose id label sits beside or over it in the margin: one ring round both,
/// not the square's ring drawn across the label's sign and first letters (BACKLOG O32).
final class NoteLabelOutlineTests: XCTestCase {
    func testAPointNoteAndItsLabelShareOneRing() {
        let point = CGRect(x: 545, y: 320, width: 0, height: 0)
        let label = CGRect(x: 541, y: 316, width: 30, height: 9)  // over the note's square
        let boxes = SelectionOutline.boxes(lines: [point], label: label)
        XCTAssertEqual(boxes.count, 2, "one ring: the paper's white and the accent")
        let accent = boxes.filter { !$0.paper }
        XCTAssertEqual(accent.count, 1)
        let square = CGRect(x: 540.5, y: 315.5, width: 9, height: 9)
        XCTAssertTrue(accent[0].rect.contains(label) && accent[0].rect.contains(square), "round the label and the square")
        XCTAssertEqual(accent[0].rect, label.union(square).insetBy(dx: -2, dy: -2))
        // a label a few points beside the square: still one ring (two would touch)
        XCTAssertEqual(SelectionOutline.boxes(lines: [point], label: CGRect(x: 552, y: 316, width: 30, height: 9)).count, 2)
        // a label far from it: a ring each, as before
        XCTAssertEqual(SelectionOutline.boxes(lines: [point], label: CGRect(x: 545, y: 400, width: 30, height: 9)).count, 4)
    }
}

/// Trimming a long round's text never cuts inside an underlined (changed) run (BACKLOG O32): the piece takes the whole
/// run, out to its words, so an edit never reads as two.
final class TrimChangedRunTests: XCTestCase {
    private func sub(_ s: String, _ r: Range<Int>) -> String {
        let u = Array(s.unicodeScalars)
        return String(String.UnicodeScalarView(u[r]))
    }

    func testTheWindowTakesARunItWouldCut() throws {
        let words = (0..<200).map { "w\($0)" }
        let text = words.joined(separator: " ")
        func at(_ w: String) -> Int { text.range(of: w + " ")!.lowerBound.utf16Offset(in: text) }
        let mark = at("w100")..<(at("w100") + 4)
        // a rewritten clause from inside the window to well past its end (the window ends about 160 characters after
        // the mark, near w133)
        let run = at("w125")..<(at("w150") + 4)
        let t = try XCTUnwrap(CardContent.trim(BlockText(text: text, marks: [mark], changed: [run])))
        XCTAssertEqual(t.changed.count, 1)
        XCTAssertEqual(sub(t.text, t.changed[0]), sub(text, run), "the whole run, not its first words")
        XCTAssertTrue(t.text.hasSuffix("w150 …"), String(t.text.suffix(20)))
        // and a run across the window's start
        let early = at("w60")..<(at("w90") + 3)
        let u = try XCTUnwrap(CardContent.trim(BlockText(text: text, marks: [mark], changed: [early])))
        XCTAssertEqual(sub(u.text, u.changed[0]), sub(text, early))
        XCTAssertTrue(u.text.hasPrefix("… w60 "), String(u.text.prefix(20)))
    }

    func testTheTwoEndsOfALongMarkMeetOverARun() throws {
        let text = (0..<300).map { "w\($0)" }.joined(separator: " ")
        func at(_ w: String) -> Int { text.range(of: w + " ")!.lowerBound.utf16Offset(in: text) }
        let mark = 0..<text.unicodeScalars.count
        let run = at("w40")..<(at("w270") + 4)  // spans the " … " between the ends
        let t = try XCTUnwrap(CardContent.trim(BlockText(text: text, marks: [mark], changed: [run])))
        XCTAssertFalse(t.text.contains(" … "), "one piece: the run is never cut")
        XCTAssertEqual(t.changed.map { sub(t.text, $0) }, [sub(text, run)])
    }
}

/// A Changes card says when a student's note within three lines of its edit was ignored (BACKLOG O32): the nearest one,
/// in the edit's own file.
final class IgnoredNoteNearTests: XCTestCase {
    private func warning(_ file: String?, _ line: Int?, _ text: String = "% R2.08 same claim, softened") -> NoteWarning {
        NoteWarning(kind: "malformed", file: file, line: line, text: text,
                    message: "This note's ID is not in the form R1-03, so it is ignored.")
    }

    func testTheNearestNoteInTheEditsFileWithinThreeLines() throws {
        let ch = try makeChange(["file": "sections/intro.tex", "line": 20])
        let n = try XCTUnwrap(ChangeModel.IgnoredNote.nearest(ch, [
            warning("sections/intro.tex", 12), warning("main.tex", 20), warning("sections/intro.tex", 22, "% far"),
            warning("sections/intro.tex", 19)]))
        XCTAssertEqual(n.offset, -1)
        XCTAssertEqual(n.whereWords, "1 line above")
        XCTAssertEqual(n.line, "% R2.08 same claim, softened")
        XCTAssertEqual(n.place, "sections/intro.tex:19")
        XCTAssertEqual(ChangeModel.IgnoredNote.nearest(ch, [warning("sections/intro.tex", 23)])?.whereWords, "3 lines below")
        XCTAssertEqual(ChangeModel.IgnoredNote.nearest(ch, [warning("sections/intro.tex", 20)])?.whereWords, "on its line")
        XCTAssertNil(ChangeModel.IgnoredNote.nearest(ch, [warning("sections/intro.tex", 24), warning("sections/intro.tex", 16)]),
                     "four lines away")
        XCTAssertNil(ChangeModel.IgnoredNote.nearest(ch, [warning(nil, nil)]), "an engine error has no place")
        let m = ChangeModel(ch, round: 2, pdfs: [:], textX: [], statuses: [:], warnings: [warning("sections/intro.tex", 19)])
        XCTAssertEqual(m.ignored?.offset, -1)
        XCTAssertTrue(m.accessibility.contains("An ignored student note 1 line above"))
        XCTAssertNil(ChangeModel(ch, round: 2, pdfs: [:], textX: [], statuses: [:]).ignored)
    }

    /// Section names (§ Q3: How Does the Sampling Temperature Change the Answers We Get?) are cut at their end, so the
    /// start of the heading reads (BACKLOG O32): no middle truncation on a change's place.
    func testPlacesAreCutAtTheirEnd() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Paperole/ChangeViews.swift")
        let s = try String(contentsOf: src, encoding: .utf8)
        let places = s.components(separatedBy: "\n").filter { $0.contains("Text(change.place)") }
        XCTAssertEqual(places.count, 2)
        XCTAssertTrue(places.allSatisfy { $0.contains(".truncationMode(.tail)") })
    }
}

/// Edit Note and Re-anchor… need no engine to start, so they are not refused while it works (BACKLOG O30, after
/// O27): only the save waits, queued behind the request the engine is working on.
@MainActor
final class BusyEditorTests: XCTestCase {
    private let drafts = FileManager.default.temporaryDirectory.appendingPathComponent("pc-busy-editor-" + UUID().uuidString)

    override func tearDown() {
        try? FileManager.default.removeItem(at: drafts)
        super.tearDown()
    }

    private func makeModel() -> AppModel {
        _ = NSApplication.shared
        var o = LaunchOptions()
        o.fixture = StepTests.fixtures.appendingPathComponent("state-m2a.json").path
        o.drafts = drafts.path
        return AppModel(options: o)
    }

    func testEditNoteAndReanchorStartWhileBusy() throws {
        let m = makeModel()
        let new = try XCTUnwrap(m.comment("R2-02"))
        XCTAssertFalse(new.carried)
        m.holdBusy(true)
        XCTAssertTrue(m.canEditNote(new))
        XCTAssertFalse(m.canEdit(new), "Delete still waits")
        m.beginNoteEdit("R2-02")
        XCTAssertEqual(m.edit.field, .note("R2-02"))
        XCTAssertNil(m.panelToast.text, "no Still loading…")
        // the menu's items
        let menu = CardMenus.more("R2-02", model: m)
        XCTAssertTrue(menu.items.first { $0.title == "Edit Note" }?.isEnabled == true)
        XCTAssertTrue(menu.items.first { $0.title == "Re-anchor…" }?.isEnabled == true)
        XCTAssertFalse(menu.items.first { $0.title == "Delete…" }?.isEnabled == true)
        // the save is sent (a fixture run has no engine to queue it: it says so)
        m.edit.text = "A new note."
        m.commitEdit()
        XCTAssertTrue(m.alertMessage?.hasPrefix("Fixture mode") == true, "the save went to the engine's queue")
        m.alertMessage = nil
        m.closeEdit()
        m.beginReanchor("R1-05")
        XCTAssertEqual(m.toolbar.reanchor, "R1-05")
        XCTAssertNil(m.panelToast.text)
        XCTAssertTrue(m.pdf.canDrawBox, "a box to re-anchor to may be drawn")
        m.leaveReanchor()
        XCTAssertFalse(m.pdf.canDrawBox, "a new comment's box waits")
        m.holdBusy(false)
    }
}

/// Links in words look like links (BACKLOG O32): the system's link colour, readable on the panel and the card, far from
/// every word colour of the panel and from the change greens; every inline link uses `LinkStyle` (an underline under
/// the pointer and the pointing hand), and the ignored notes' popover introduces the lines as source.
final class LinkLookTests: XCTestCase {
    private func srgb(_ c: NSColor, _ mode: NSAppearance.Name) -> NSColor {
        var out = NSColor.black
        NSAppearance(named: mode)!.performAsCurrentDrawingAppearance { out = c.usingColorSpace(.sRGB)! }
        return out
    }

    private func contrast(_ a: NSColor, _ b: NSColor, _ mode: NSAppearance.Name) -> CGFloat {
        func lum(_ c: NSColor) -> CGFloat {
            func ch(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * ch(c.redComponent) + 0.7152 * ch(c.greenComponent) + 0.0722 * ch(c.blueComponent)
        }
        let (x, y) = (lum(srgb(a, mode)), lum(srgb(b, mode)))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    func testTheLinkColourStandsApart() {
        for mode in [NSAppearance.Name.aqua, .darkAqua] {
            for ground in [Palette.panel, Palette.card] {
                XCTAssertGreaterThanOrEqual(contrast(Palette.link, ground, mode), 4.5, "\(mode) \(ground)")
            }
            let link = srgb(Palette.link, mode)
            for (name, other) in [("label", Palette.label), ("label2", Palette.label2), ("secondary", Palette.secondary),
                                  ("accentText", Palette.accentText), ("changedWords", Palette.changedWords),
                                  ("change", Palette.change), ("unrequested", Palette.unrequested), ("toCheck", Palette.toCheck)] {
                let d = DesignPaletteTests.deltaE(link, srgb(other, mode))
                // the palette's own bar for colours told apart is about 13–15 (UX.md §16, §19); the slate teal of other
                // edits, a blue-green, is the nearest (18 in Light Mode)
                XCTAssertGreaterThan(d, name == "unrequested" ? 15 : 20, "\(mode): the link and \(name) are \(d) apart")
            }
        }
        // the accent's text colour, which links had, was as quiet as the secondary words: that was the problem
        XCTAssertLessThan(DesignPaletteTests.deltaE(srgb(Palette.accentText, .aqua), srgb(Palette.secondary, .aqua)), 12)
    }

    func testInlineLinksUseTheLinkStyle() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Paperole")
        var styled = 0
        for f in try FileManager.default.contentsOfDirectory(atPath: dir.path) where f.hasSuffix(".swift") {
            let s = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
            styled += s.components(separatedBy: ".buttonStyle(LinkStyle())").count - 1
            // the panel toast's Undo keeps the system's link button on a capsule of its own; no other link does
            let plain = s.components(separatedBy: ".buttonStyle(.link)").count - 1
            XCTAssertEqual(plain, f == "RightPanel.swift" ? 1 : 0, f)
        }
        XCTAssertGreaterThanOrEqual(styled, 13, "Details… (twice), · N edit (twice), Show all (twice), Edit, Discard, …")
        XCTAssertEqual(NoteWarningsList.intro(open: false), "These lines in the source matched no open comment.")
        XCTAssertTrue(NoteWarningsList.intro(open: true).hasPrefix("These lines in the source matched no open comment. "))
    }
}

/// The Comments ↔ Changes switch (UX.md §1; v2.2): both pages live in one pager, the shown one in front and alone to
/// take clicks; an animated switch moves only the pages' layers and hides the page left once it has gone; each list
/// keeps its scroll position; a hidden list keeps no hover and does not place the shared toast.
@MainActor
final class TabPagerTests: XCTestCase {
    private func spin(_ s: Double = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    private func items(_ ids: [String]) throws -> [PanelTable.Row] {
        try ids.map { .item(.card(CardModel(try makeComment(["id": $0]), round: 2, pdfs: [:], textX: [], showChanges: true))) }
    }

    private func table() -> PanelTable {
        PanelTable(scroller: PanelScroller(), expanded: nil, compact: { _, _ in AnyView(Color.clear) },
                   expandedView: { _ in AnyView(Color.gray.frame(height: 300)) })
    }

    private func makePager(_ pages: [NSView]) -> (PagerView, NSWindow) {
        _ = NSApplication.shared
        let pager = PagerView(pages: pages)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: false)  // never ordered in
        window.isReleasedWhenClosed = false
        window.contentView = pager
        pager.layoutSubtreeIfNeeded()
        return (pager, window)
    }

    func testOnePageShownAndTakingTheClicks() {
        let (a, b) = (NSView(), NSView())
        let (pager, window) = makePager([a, b])
        pager.show(0, animated: false)
        XCTAssertFalse(a.isHidden)
        XCTAssertTrue(b.isHidden)
        XCTAssertEqual(a.frame, pager.bounds)
        XCTAssertTrue(pager.hitTest(NSPoint(x: 100, y: 100)) === a)
        pager.show(1, animated: false)
        XCTAssertTrue(a.isHidden)
        XCTAssertFalse(b.isHidden)
        XCTAssertTrue(pager.hitTest(NSPoint(x: 100, y: 100)) === b)
        XCTAssertTrue(pager.clipsToBounds, "the pages never slide over the PDF")
        window.close()
    }

    func testAnAnimatedSwitchMovesLayersThenHidesThePageLeft() {
        let (a, b) = (NSView(), NSView())
        let (pager, window) = makePager([a, b])
        pager.show(0, animated: false)
        pager.show(1, animated: true)
        XCTAssertTrue(pager.animating)
        XCTAssertFalse(a.isHidden, "the page left fades out")
        XCTAssertFalse(b.isHidden)
        XCTAssertTrue(pager.subviews.last === b, "the page shown in front")
        XCTAssertTrue(pager.hitTest(NSPoint(x: 100, y: 100)) === b, "and taking the clicks at once")
        XCTAssertNotNil(a.layer?.animation(forKey: "pager.move"))
        XCTAssertNotNil(b.layer?.animation(forKey: "pager.move"))
        XCTAssertEqual(b.frame, pager.bounds, "no view moved: only the layers")
        spin(TabMotion.duration + 0.25)
        XCTAssertFalse(pager.animating)
        XCTAssertTrue(a.isHidden)
        XCTAssertFalse(b.isHidden)
        XCTAssertNil(a.layer?.animation(forKey: "pager.move"))
        XCTAssertNil(b.layer?.animation(forKey: "pager.move"))
        // back during a switch: it turns round and ends on the page asked for last
        pager.show(0, animated: true)
        spin(0.08)
        pager.show(1, animated: true)
        spin(TabMotion.duration + 0.25)
        XCTAssertTrue(a.isHidden)
        XCTAssertFalse(b.isHidden)
        XCTAssertEqual(pager.shown, 1)
        window.close()
    }

    func testTheShiftIsShortAndFollowsTheWidth() {
        XCTAssertEqual(TabMotion.shift(width: 400), 50)
        XCTAssertEqual(TabMotion.shift(width: 560), 56)
        XCTAssertEqual(TabMotion.shift(width: 320), 40)
        XCTAssertEqual(TabMotion.duration, 0.25)
    }

    func testEachListKeepsItsPlaceAndAHiddenListNoHover() throws {
        let comments = table(), changes = table()
        let place = ToastPlace()
        comments.toastPlace = place
        changes.toastPlace = place
        let (pager, window) = makePager([comments.scrollView, changes.scrollView])
        pager.show(0, animated: false)
        let ids = (1...30).map { String(format: "R1-%02d", $0) }
        comments.show([.header("To check")] + (try items(ids)))
        changes.show([.header("To check")] + (try items(ids.map { "c" + $0 })))
        comments.scrollView.layoutSubtreeIfNeeded()
        comments.scroller(byDebug: 300)
        // a row under a pointer of the test's own
        comments.pointerLocation = { [weak comments] in
            guard let f = comments?.rowFrame("R1-12") else { return nil }
            return NSPoint(x: f.midX, y: f.midY)
        }
        spin(PanelTable.settleDelay + 0.1)
        comments.pointerMoved(to: comments.pointerLocation())
        XCTAssertEqual(comments.hoveredRows, ["R1-12"])
        let offset = comments.scrollView.contentView.bounds.minY
        pager.show(1, animated: false)
        XCTAssertEqual(comments.hoveredRows, [], "hidden: nothing hovered")
        // the hidden list moving does not move the shared toast
        place.bottom = 16
        changes.scrollView.layoutSubtreeIfNeeded()
        let before = place.bottom
        comments.scroller(byDebug: 40)
        XCTAssertEqual(place.bottom, before)
        pager.show(0, animated: false)
        XCTAssertEqual(comments.scrollView.contentView.bounds.minY, offset + 40, accuracy: 0.5, "its place kept")
        window.close()
    }

    /// The toast at the panel's foot goes above a group's header it would cover (BACKLOG O28: Undo over "Closed this
    /// round", where the answered card had just gone).
    func testTheToastGoesAboveAHeaderItWouldCover() {
        XCTAssertEqual(ToastPlace.bottom(base: 16, height: 500, headers: []), 16)
        XCTAssertEqual(ToastPlace.bottom(base: 16, height: 500, headers: [(top: 0, bottom: 34)]), 16, "the floating one on top")
        // "Closed this round" at 440–474 under a toast at 452–484: the toast's foot 6 pt above the header
        XCTAssertEqual(ToastPlace.bottom(base: 16, height: 500, headers: [(top: 440, bottom: 474)]), 66)
        XCTAssertEqual(ToastPlace.bottom(base: 16, height: 500, headers: [(top: 300, bottom: 334)]), 16, "well above")
        // two headers in a row at the foot: above the lower one only, never further up over the rows (review,
        // 2026-10-18: "For the student", its hint and "Closed this round" at the foot put the toast 141 pt up)
        XCTAssertEqual(ToastPlace.bottom(base: 16, height: 500, headers: [(top: 440, bottom: 474), (top: 396, bottom: 430)]), 66)
        XCTAssertEqual(ToastPlace.bottom(base: 16, height: 790, headers: [(top: 664, bottom: 698), (top: 734, bottom: 768)]), 62)
        XCTAssertEqual(ToastPlace.bottom(base: 56, height: 500, headers: []), 56, "over a pinned answer row")
    }

    /// The toast goes over the pinned answer row as soon as the row is pinned, with no scroll after it (review,
    /// 2026-10-18: the toast's place was worked out from the pin as it was before).
    func testTheToastFollowsThePinWithNoScroll() throws {
        _ = NSApplication.shared
        let scroller = PanelScroller()
        let table = PanelTable(scroller: scroller, expanded: nil, compact: { _, _ in AnyView(Color.clear) },
                               expandedView: { _ in AnyView(Color.gray.frame(height: 1000)) })
        let pin = PinState(), place = ToastPlace()
        table.pin = pin
        table.toastPlace = place
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: true)  // never ordered in
        window.isReleasedWhenClosed = false
        window.contentView = table.scrollView
        table.scrollView.layoutSubtreeIfNeeded()
        let ids = (1...4).map { String(format: "R1-%02d", $0) }
        table.show([.header("To check")] + (try ids.map { .item(.card(CardModel(try makeComment(["id": $0]), round: 2, pdfs: [:],
                                                                                  textX: [], showChanges: true))) }))
        XCTAssertEqual(place.bottom, 16)
        table.setExpanded("R1-02")  // 1000 pt in a 500 pt panel: its answer row pinned at the foot
        XCTAssertLessThan(pin.offset, 0, "the answer row pinned")
        XCTAssertEqual(place.bottom, 56, "the toast over it at once")
        table.setExpanded(nil)
        XCTAssertEqual(pin.offset, 0)
        XCTAssertEqual(place.bottom, 16)
        window.close()
    }
}

extension PanelTable {
    /// A scroll of the list by `dy`, as the scroller's debug scroll (tests).
    func scroller(byDebug dy: CGFloat) {
        let clip = scrollView.contentView
        var b = clip.bounds
        b.origin.y += dy
        clip.scroll(to: clip.constrainBoundsRect(b).origin)
        scrollView.reflectScrolledClipView(clip)
    }
}

/// O28/O30's cheap items: the Finish sheet's drafts list shows its scroll bar before it is scrolled; the panel opens at
/// its ideal width (or the one last used); the sidebar goes back to its top when the current section's row fits there.
@MainActor
final class LeftoverTests: XCTestCase {
    private func spin(_ s: Double = 0.1) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    func testTheDraftsListShowsItsScrollBar() throws {
        _ = NSApplication.shared
        let content = ScrollView {
            VStack { ForEach(0..<40) { Text("Draft \($0)").frame(height: 30) } }.background(AlwaysShownScroller())
        }
        .scrollIndicators(.visible)
        let host = NSHostingView(rootView: content.frame(width: 300, height: 200))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        spin(0.3)
        var scrollViews: [NSScrollView] = []
        func walk(_ v: NSView) { if let s = v as? NSScrollView { scrollViews.append(s) }; v.subviews.forEach(walk) }
        walk(host)
        let sv = try XCTUnwrap(scrollViews.first)
        XCTAssertEqual(sv.scrollerStyle, .legacy, "a bar with its track, there before any scroll")
        XCTAssertFalse(sv.autohidesScrollers)
        XCTAssertTrue(sv.hasVerticalScroller)
        window.close()
    }

    func testThePanelOpensAtItsIdealWidth() {
        // a 1440 pt window less the sidebar: the review's split view about 1204 pt
        XCTAssertEqual(PDFController.openingWidth(remembered: nil, split: 1204, divider: 1), 400)
        XCTAssertEqual(PDFController.openingWidth(remembered: 470, split: 1204, divider: 1), 470, "the width last used")
        XCTAssertEqual(PDFController.openingWidth(remembered: 900, split: 1204, divider: 1), 560, "at most 560")
        XCTAssertEqual(PDFController.openingWidth(remembered: nil, split: 760, divider: 1), 339, "the PDF keeps its 420")
        XCTAssertEqual(PDFController.openingWidth(remembered: nil, split: 700, divider: 1), 320, "never under 320")
    }

    /// Records the panel widths that the review's split view would remember (`PDFController.dividerDragged`).
    @MainActor private final class DividerWatch: NSObject {
        var remembered: [CGFloat] = []
        private var width: CGFloat
        private let split: NSSplitView, panel: NSView
        init(_ split: NSSplitView, panel: NSView) {
            self.split = split
            self.panel = panel
            width = split.bounds.width
            super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(resized), name: NSSplitView.didResizeSubviewsNotification,
                                                   object: split)
        }
        @objc private func resized() {
            let before = width
            width = split.bounds.width
            if PDFController.dividerDragged(NSApp.currentEvent, in: split, widthBefore: before) { remembered.append(panel.frame.width) }
        }
        func stop() { NotificationCenter.default.removeObserver(self) }
    }

    /// Only a width the advisor gives the panel by dragging the divider is remembered, not one a narrow window forced on
    /// it (review, 2026-10-18: after a 960 pt window, the next paper opened with a 339 pt panel).
    func testOnlyADragOfTheDividerIsRemembered() throws {
        _ = NSApplication.shared
        let c = NSSplitViewController()
        let pdf = NSViewController(), panel = NSViewController()
        pdf.view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        panel.view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        c.addSplitViewItem(NSSplitViewItem(viewController: pdf))
        c.addSplitViewItem(NSSplitViewItem(viewController: panel))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1204, height: 600), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)  // never ordered in; a window number for its events
        window.isReleasedWhenClosed = false
        window.contentViewController = c
        c.view.layoutSubtreeIfNeeded()
        let split = c.splitView
        let watch = DividerWatch(split, panel: panel.view)
        defer { watch.stop() }
        split.setPosition(split.bounds.width - 400 - split.dividerThickness, ofDividerAt: 0)  // the app opens it at 400
        split.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 560, height: 600))  // a narrow window squeezes the panel
        c.view.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 1204, height: 600))
        c.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(watch.remembered, [], "no width the window gave it")
        // the divider dragged 40 pt to the left, as the mouse does it
        let start = panel.view.frame.width
        let p = split.convert(NSPoint(x: pdf.view.frame.maxX + split.dividerThickness / 2, y: 300), to: nil)
        func event(_ type: NSEvent.EventType, _ x: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: p.y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        NSApp.postEvent(event(.leftMouseDragged, p.x - 40), atStart: false)
        NSApp.postEvent(event(.leftMouseUp, p.x - 40), atStart: false)
        split.mouseDown(with: event(.leftMouseDown, p.x))
        XCTAssertEqual(panel.view.frame.width, start + 40, accuracy: 1, "the drag widened the panel")
        XCTAssertEqual(try XCTUnwrap(watch.remembered.last), panel.view.frame.width, "the dragged width is remembered")
        window.close()
    }

    func testTheSidebarGoesToItsTopWhenTheRowFitsThere() {
        // a row within the first screen, the list scrolled down: to the top
        XCTAssertTrue(SidebarFollow.goesToTop(rowMaxY: 300, offset: 120, top: -28, height: 600))
        // already at the top: nothing to do
        XCTAssertFalse(SidebarFollow.goesToTop(rowMaxY: 300, offset: -28, top: -28, height: 600))
        // a row further down than the first screen: the least scroll, as before
        XCTAssertFalse(SidebarFollow.goesToTop(rowMaxY: 700, offset: 300, top: -28, height: 600))
    }
}

/// The panel in a window: both tabs' pages there from the start, one shown; switching tabs animates the pages unless
/// Reduce Motion is on, and lays out no list again (each keeps its rows and place).
@MainActor
final class PanelSwitchTests: XCTestCase {
    private func spin(_ s: Double = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    private let drafts = FileManager.default.temporaryDirectory.appendingPathComponent("pc-switch-" + UUID().uuidString)

    override func tearDown() {
        TabMotion.reduceOverride = nil
        try? FileManager.default.removeItem(at: drafts)
        super.tearDown()
    }

    func testBothPagesLiveAndTheSwitchSlidesUnlessReduceMotion() throws {
        _ = NSApplication.shared
        var o = LaunchOptions()
        o.fixture = StepTests.fixtures.appendingPathComponent("state-m2a.json").path
        o.drafts = drafts.path
        let m = AppModel(options: o)
        let host = NSHostingView(rootView: RightPanel().environmentObject(m))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        spin(0.3)
        func all<T: NSView>(_ type: T.Type, in v: NSView) -> [T] { ((v as? T).map { [$0] } ?? []) + v.subviews.flatMap { all(type, in: $0) } }
        let pager = try XCTUnwrap(all(PagerView.self, in: host).first)
        XCTAssertEqual(pager.pages.count, 2)
        XCTAssertEqual(pager.shown, 0)
        let tables = all(PanelTableView.self, in: host)
        XCTAssertEqual(tables.count, 2, "both lists are there from the start")
        XCTAssertEqual(tables.filter { !$0.isHiddenOrHasHiddenAncestor }.count, 1)
        XCTAssertEqual(PanelTabs.shown, 1)
        let comments = try XCTUnwrap(m.panel.scroller.table), changes = try XCTUnwrap(m.changes.scroller.table)
        let listBodies = BodyCount.list
        TabMotion.reduceOverride = false
        m.tab = .changes
        spin(0.02)
        XCTAssertEqual(pager.shown, 1)
        XCTAssertTrue(pager.animating, "the pages slide")
        spin(TabMotion.duration + 0.3)
        XCTAssertFalse(pager.animating)
        XCTAssertTrue(pager.pages[0].isHidden)
        XCTAssertTrue(m.panel.scroller.table === comments && m.changes.scroller.table === changes, "no list was made again")
        XCTAssertEqual(BodyCount.list, listBodies, "no rows came or went")
        TabMotion.reduceOverride = true
        m.tab = .comments
        spin(0.02)
        XCTAssertEqual(pager.shown, 0)
        XCTAssertFalse(pager.animating, "Reduce Motion: at once")
        XCTAssertTrue(pager.pages[1].isHidden)
        XCTAssertNil(TabMotion.animation)
        window.close()
    }
}
