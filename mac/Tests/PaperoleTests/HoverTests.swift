import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Paperole

/// The row under the pointer (UX.md §1 Hover): the list's one hovered row, from its own pointer tracking. A background
/// capture (2026-10-18) showed R2-05 and R2-02 both hovered long after the pointer had left them: each row's own
/// enter and exit (SwiftUI's onHover) missed exits. Synthetic cards only; the window is never ordered in, so the
/// pointer is the test's own (`pointerLocation`, `pointerMoved`).
@MainActor
final class RowHoverTests: XCTestCase {
    private let ids = (1...20).map { String(format: "R1-%02d", $0) }

    /// Long enough for the list to settle after a scroll or a step.
    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(PanelTable.settleDelay + 0.1)) }

    private func items(_ ids: [String], note: [String: String] = [:]) throws -> [PanelTable.Row] {
        try ids.map {
            .item(.card(CardModel(try makeComment(["id": $0, "note": note[$0] ?? "n"]), round: 2, pdfs: [:], textX: [],
                                  showChanges: true)))
        }
    }

    private func makeTable() throws -> (PanelTable, PanelScroller, NSWindow) {
        _ = NSApplication.shared
        let scroller = PanelScroller()
        let table = PanelTable(scroller: scroller, expanded: nil, compact: { _, _ in AnyView(Color.clear) },
                               expandedView: { _ in AnyView(Color.gray.frame(height: 200)) })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: true)  // never ordered in
        window.isReleasedWhenClosed = false
        window.contentView = table.scrollView
        table.dims = true
        table.pointerLocation = { nil }  // off the list until a test puts it somewhere
        table.show([.header("To check")] + (try items(ids)))
        table.scrollView.layoutSubtreeIfNeeded()
        settle()
        return (table, scroller, window)
    }

    /// The middle of a row in window coordinates (rows 1 to 8 are in view at first: no scroll).
    private func middle(_ table: PanelTable, _ id: String) throws -> NSPoint {
        let f = try XCTUnwrap(table.rowFrame(id))
        return NSPoint(x: f.midX, y: f.midY)
    }

    /// How many times each row's look changed, by id.
    private func watch(_ table: PanelTable) -> (counts: () -> [String: Int], keep: [AnyCancellable]) {
        var counts: [String: Int] = [:]
        let keep = ids.compactMap { id in table.look(id).map { $0.objectWillChange.sink { _ in counts[id, default: 0] += 1 } } }
        return ({ counts }, keep)
    }

    /// One row at most, and only the one under the pointer: a move from row to row needs no exit from the first (the
    /// stuck capture's case), the list's exit clears it, and the moves come from the table's own tracking.
    func testOneRowIsHoveredOnlyWhereThePointerIs() throws {
        let (table, _, window) = try makeTable()
        let p2 = try middle(table, "R1-02"), p5 = try middle(table, "R1-05")
        let w = watch(table)
        table.pointerMoved(to: p2)
        XCTAssertEqual(table.hoveredRows, ["R1-02"])
        XCTAssertFalse(try XCTUnwrap(table.look("R1-02")).quiet)
        table.pointerMoved(to: p5)  // R1-02 gets no exit of its own
        XCTAssertEqual(table.hoveredRows, ["R1-05"])
        XCTAssertEqual(w.counts(), ["R1-02": 2, "R1-05": 1], "only the two rows whose hover changed")
        table.pointerMoved(to: nil)  // it leaves the list
        XCTAssertEqual(table.hoveredRows, [])
        // a mouse-moved event as the table's tracking area delivers it
        let tv = try XCTUnwrap(table.scrollView.documentView as? NSTableView)
        tv.mouseMoved(with: try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved, location: p2, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)))
        XCTAssertEqual(table.hoveredRows, ["R1-02"])
        withExtendedLifetime(w.keep) {}
        window.close()
    }

    /// The expanded card and a floating header lie over rows: neither is a row under the pointer.
    func testTheCardAndAFloatingHeaderAreNotRows() throws {
        let (table, scroller, window) = try makeTable()
        table.setExpanded("R1-03")
        settle()
        let card = try XCTUnwrap(table.cardFrame)
        table.pointerMoved(to: NSPoint(x: card.midX, y: card.midY))
        XCTAssertEqual(table.hoveredRows, [])
        scroller.debugScroll(400)  // the header floats over R1-06 and R1-07 at the top
        settle()
        let clip = table.scrollView.convert(table.scrollView.bounds, to: nil)
        let underHeader = NSPoint(x: clip.midX, y: clip.maxY - PanelScroller.header / 2)
        XCTAssertNil(table.item(at: underHeader), "the floating header is over that row")
        XCTAssertNotNil(table.item(at: NSPoint(x: clip.midX, y: clip.maxY - PanelScroller.header - 22)), "the row under it")
        window.close()
    }

    /// The list scrolls under a still pointer, which sends no event: nothing is hovered while it moves (the pointer's
    /// moves then do not count), and the row under the pointer is once it has settled; a live scroll (trackpad, the
    /// scroller's knob) the same, until it ends.
    func testAScrollClearsItAndTheStillPointerFindsItsRowWhenItEnds() throws {
        let (table, scroller, window) = try makeTable()
        let p = try middle(table, "R1-03")
        table.pointerLocation = { p }
        table.pointerMoved(to: p)
        XCTAssertEqual(table.hoveredRows, ["R1-03"])
        scroller.debugScroll(88)  // two rows
        XCTAssertEqual(table.hoveredRows, [], "cleared as it scrolls")
        table.pointerMoved(to: p)
        XCTAssertEqual(table.hoveredRows, [], "the pointer's moves wait for the scroll to end")
        settle()
        XCTAssertEqual(table.hoveredRows, ["R1-05"], "the row now under the still pointer")
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: table.scrollView)
        XCTAssertEqual(table.hoveredRows, [])
        scroller.debugScroll(44)
        settle()
        XCTAssertEqual(table.hoveredRows, [], "still scrolling")
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: table.scrollView)
        settle()
        XCTAssertEqual(table.hoveredRows, ["R1-06"])
        window.close()
    }

    /// Rows that come or go (a card leaving its group, a group shown) clear it until the list settles; a row whose
    /// content alone changed keeps it.
    func testRowsThatComeOrGoClearIt() throws {
        let (table, _, window) = try makeTable()
        let p = try middle(table, "R1-04")
        table.pointerLocation = { p }
        table.pointerMoved(to: p)
        table.show([.header("To check")] + (try items(ids, note: ["R1-04": "changed"])))
        XCTAssertEqual(table.hoveredRows, ["R1-04"], "the same rows")
        table.show([.header("To check")] + (try items(ids.filter { $0 != "R1-02" })))
        XCTAssertEqual(table.hoveredRows, [], "cleared at once")
        settle()
        XCTAssertEqual(table.hoveredRows, ["R1-05"], "the row that moved up under the pointer")
        window.close()
    }

    /// The window resigning key and the app resigning active take it away (no exit comes then); the window becoming key
    /// finds the row under the pointer again. Another window's notifications change nothing.
    func testTheWindowAndTheAppTakeItAway() throws {
        let (table, _, window) = try makeTable()
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled],
                             backing: .buffered, defer: true)
        other.isReleasedWhenClosed = false
        let p = try middle(table, "R1-02")
        var key = true
        table.pointerLocation = { key ? p : nil }
        table.pointerMoved(to: p)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: other)
        XCTAssertEqual(table.hoveredRows, ["R1-02"])
        key = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertEqual(table.hoveredRows, [])
        key = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: other)
        XCTAssertEqual(table.hoveredRows, [])
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertEqual(table.hoveredRows, ["R1-02"])
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        XCTAssertEqual(table.hoveredRows, [])
        other.close()
        window.close()
    }

    /// A J/K step changes no row's look with the pointer off the list; with it resting on the list, only the looks of
    /// the row it leaves and the row now under it, once the rows have settled.
    func testAStepRedrawsOnlyTheRowsWhoseHoverChanges() throws {
        let (table, scroller, window) = try makeTable()
        table.setExpanded("R1-02")
        settle()
        var w = watch(table)
        table.setExpanded("R1-03")
        settle()
        XCTAssertEqual(w.counts(), [:], "the pointer off the list: no row changes")
        table.setExpanded("R1-10")
        scroller.debugScroll(300)
        settle()
        let p = try middle(table, "R1-09")  // above the card, in view
        table.pointerLocation = { p }
        table.pointerMoved(to: p)
        XCTAssertEqual(table.hoveredRows, ["R1-09"])
        w = watch(table)
        table.setExpanded("R1-11")  // the card above collapses; the list keeps R1-11's top in place, rows move under p
        settle()
        let now = try XCTUnwrap(table.item(at: p))
        XCTAssertNotEqual(now, "R1-09", "another row under the pointer now")
        XCTAssertEqual(table.hoveredRows, [now])
        XCTAssertEqual(w.counts(), ["R1-09": 1, now: 1], "only the row it left and the row under it")
        withExtendedLifetime(w.keep) {}
        window.close()
    }
}
