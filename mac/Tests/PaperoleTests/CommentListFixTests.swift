import AppKit
import SwiftUI
import XCTest
@testable import Paperole

/// Fixes from the review of 2026-10-24 (design/review/2026-10-24/REVIEW.md, batch B9) to the panel's lists: a hint
/// row measured with its own words (A3a-02), and the Changes tab's header once every edit is handled (UI-02).
/// Synthetic data only.
@MainActor
final class CommentListFixTests: XCTestCase {
    private func item(_ id: String) throws -> PanelTable.Row {
        .item(.card(CardModel(try makeComment(["id": id]), round: 2, pdfs: [:], textX: [], showChanges: true)))
    }

    private func makeTable() -> (PanelTable, NSWindow) {
        _ = NSApplication.shared
        let table = PanelTable(scroller: PanelScroller(), expanded: nil, compact: { _, _ in AnyView(Color.clear) },
                               expandedView: { _ in AnyView(Color.gray.frame(height: 200)) })
        // the panel's minimum width; never ordered in: nothing appears on the screen
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = table.scrollView
        table.scrollView.layoutSubtreeIfNeeded()
        return (table, window)
    }

    /// The hint's row: the room between the rows above and below it.
    private func hintHeight(_ table: PanelTable) throws -> CGFloat {
        try XCTUnwrap(table.frame(of: "R1-02")).minY - XCTUnwrap(table.frame(of: "R1-01")).maxY
    }

    /// A3a-02: every hint is measured under one key, so a hint listed again after another was measured took the
    /// other's height (a gap, or a line cut, near the panel's 320 pt).
    func testAHintListedAgainIsMeasuredWithItsOwnWords() throws {
        let long = String(repeating: "To comment, select text in the PDF and click Comment. ", count: 4)
        let rows: [PanelTable.Row] = [.header("To check"), try item("R1-01"), .hint(long), try item("R1-02")]
        let (fresh, w1) = makeTable()
        defer { w1.close() }
        fresh.show(rows)
        let own = try hintHeight(fresh)
        let (table, w2) = makeTable()
        defer { w2.close() }
        table.show([.header("To check"), try item("R1-01"), .hint("Short."), try item("R1-02")])
        // its words change in place: measured again, and that measure kept (as after a resize)
        table.show([.header("To check"), try item("R1-01"), .hint("Short!"), try item("R1-02")])
        let short = try hintHeight(table)
        XCTAssertGreaterThan(own, short + 10, "the long hint takes more lines")
        table.show([.header("To check"), try item("R1-01"), try item("R1-02")])  // the hint goes
        table.show(rows)  // and another comes
        XCTAssertEqual(try hintHeight(table), own, accuracy: 0.5)
    }

    /// UI-02: once every unasked edit is handled, the group is not the advisor's move: its header "Unasked edits" has the
    /// quiet ring (as in a closed round), not the vermilion one (design/review-page/BRIEF.md E2).
    func testTheChangesHeaderIsNotAmberOnceEveryEditIsHandled() throws {
        _ = NSApplication.shared
        let panel = ChangePanel()
        panel.roundOpen = true
        let left = model(try makeChange(["id": "c01"])), checked = model(try makeChange(["id": "c02", "checked": true]))
        panel.unrequested = [left, checked]
        let list = ChangeListController(panel: panel, actions: CardActions(), edit: EditState())
        XCTAssertEqual(list.rows().first, .header("Unasked edits", glyph: .toCheck(open: true)))
        panel.unrequested = [model(try makeChange(["id": "c01", "checked": true])), checked]
        XCTAssertEqual(list.rows().first, .header("Unasked edits", glyph: .toCheck(open: false)))
        XCTAssertEqual(list.table.headers.first?.first as? String, "Unasked edits")
        panel.roundOpen = false  // a closed round, as before
        XCTAssertEqual(list.rows().first, .header("Unasked edits", glyph: .toCheck(open: false)))
        withExtendedLifetime(list) {}
    }
}
