import AppKit
import SwiftUI
import XCTest
@testable import Paperole

/// UI v2.1 phase 3, the other screens (design/ui-v2.1/POLISH.md §3 rows 4, 9, 14, 15): the done card on top of the
/// comment list once nothing is left, the empty state and the comment hint in mouse words, the one first-run tip, and
/// the selected words in the new-comment editor. Synthetic fixtures only.
@MainActor
final class ScreensTests: XCTestCase {
    private var drafts: URL!

    override func setUpWithError() throws {
        drafts = FileManager.default.temporaryDirectory.appendingPathComponent("pc-screens-drafts-" + UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: drafts)
    }

    private func spin(_ s: Double = 0.1) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    private func makeModel() -> AppModel {
        _ = NSApplication.shared
        var o = LaunchOptions()
        o.fixture = StepTests.fixtures.appendingPathComponent("state-m2a.json").path
        o.drafts = drafts.path
        return AppModel(options: o)
    }

    /// The fixture's state, changed as the engine would send it.
    private func state(_ change: (inout [String: Any]) -> Void) throws -> EngineState {
        let url = StepTests.fixtures.appendingPathComponent("state-m2a.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        change(&json)
        return try EngineState.decode(JSONSerialization.data(withJSONObject: json))
    }

    private func answerAll(_ json: inout [String: Any]) {
        json["comments"] = (json["comments"] as? [[String: Any]] ?? []).map { c in
            var c = c
            if c["carried"] as? Bool == true, c["verdict"] is NSNull || c["verdict"] == nil { c["verdict"] = "verified" }
            return c
        }
    }

    private func checkAll(_ json: inout [String: Any]) {
        json["changes"] = (json["changes"] as? [[String: Any]] ?? []).map { c in
            var c = c
            c["checked"] = true
            return c
        }
    }

    /// POLISH §3 row 9: once nothing is left (no comment or other edit to check, no changed paragraph to read), a calm
    /// card heads the list, whose plain button opens the Finish sheet; not before, and not in a closed round.
    func testTheDoneCardHeadsTheListOnceNothingIsLeft() throws {
        let m = makeModel()
        let list = CommentListController(panel: m.panel, actions: m.actions, edit: m.edit)
        XCTAssertFalse(m.panel.ready)
        XCTAssertEqual(list.table.listed.first, "header: To check")
        m.apply(try state(answerAll))
        XCTAssertFalse(m.panel.ready, "an other edit is still to check")
        XCTAssertFalse(list.table.listed.contains("done"))
        m.apply(try state { answerAll(&$0); checkAll(&$0) })
        XCTAssertTrue(m.readyToFinish)
        XCTAssertTrue(m.panel.ready)
        XCTAssertEqual(list.table.listed.first, "done")
        XCTAssertTrue(list.table.listed.dropFirst().first?.hasPrefix("header: For the student") == true, "no To check group")
        list.table.onFinish?()
        XCTAssertTrue(m.showFinish, "its button opens the Finish sheet")
        m.showFinish = false
        // the last card answered stays in To check while it is selected: the done card waits until it leaves, so the
        // card is not pushed down under the pointer
        m.apply(try state { _ in })
        m.select(.comment("R1-06"))
        m.apply(try state { answerAll(&$0); checkAll(&$0) })
        XCTAssertTrue(m.panel.ready)
        XCTAssertEqual(m.panel.groups.toCheck.map(\.id), ["R1-06"])
        XCTAssertFalse(list.table.listed.contains("done"))
        m.select(.comment("R1-02"))
        XCTAssertEqual(list.table.listed.first, "done")
        m.apply(try state { answerAll(&$0); checkAll(&$0); $0["round"] = ($0["round"] as? [String: Any] ?? [:]).merging(["closed": true]) { _, b in b } })
        XCTAssertFalse(m.panel.ready, "a closed round has nothing to finish")
        XCTAssertFalse(list.table.listed.contains("done"))
        withExtendedLifetime(list) {}
    }

    /// POLISH §3 row 15: an open round without comments shows what to do first, and nothing else; with comments but no
    /// new one, For the student ends with the hint, both in mouse words (POLISH §6).
    func testTheEmptyStateAndTheHintTeachTheNextStep() throws {
        let m = makeModel()
        let list = CommentListController(panel: m.panel, actions: m.actions, edit: m.edit)
        m.apply(try state { $0["comments"] = [] })
        XCTAssertEqual(list.table.listed, ["empty"])
        m.apply(try state { $0["comments"] = ($0["comments"] as? [[String: Any]] ?? []).filter { $0["carried"] as? Bool == true } })
        XCTAssertFalse(list.table.listed.contains { $0.hasPrefix("hint") }, "folded: its hint is hidden too")
        m.toggleFold(.student)
        XCTAssertEqual(list.table.listed.last(where: { $0.hasPrefix("hint") }), "hint: To comment, select text in the PDF and click Comment.")
        withExtendedLifetime(list) {}
    }

    /// The done card and the empty state are measured at the column's width, as the hint is.
    func testTheDoneCardIsMeasured() throws {
        _ = NSApplication.shared
        let scroller = PanelScroller()
        let table = PanelTable(scroller: scroller, expanded: nil, compact: { _, _ in AnyView(Color.clear) },
                               expandedView: { _ in AnyView(Color.gray.frame(height: 200)) })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: true)  // never ordered in
        window.isReleasedWhenClosed = false
        window.contentView = table.scrollView
        table.scrollView.layoutSubtreeIfNeeded()
        let card = PanelItem.card(CardModel(try makeComment(["id": "R1-02", "verdict": "reopened"]), round: 2, pdfs: [:], textX: [],
                                            showChanges: true))
        table.show([.done(round: 3), .header("For the student"), .item(card)])
        spin()
        let below = try XCTUnwrap(table.frame(of: "R1-02")).minY
        XCTAssertGreaterThan(below, 26 + 120, "the card, its words and its button")
        XCTAssertNotNil(table.donePoint(), "its button reported where it is")
        table.show([.empty, .item(card)])
        spin()
        XCTAssertGreaterThan(try XCTUnwrap(table.frame(of: "R1-02")).minY, 100, "an icon, a title and three lines")
        window.close()
    }

    /// POLISH §3 row 14: one tip under the answer buttons of a card to check, until Got it or the first answer; a test
    /// run never remembers it. UI v4: in the paper map's tip's look (`InlineTip`), the two tips dismissed one by one
    /// (HelpTests.testTheTips).
    func testTheTipShowsUntilGotIt() throws {
        let t = Tips()
        XCTAssertTrue(t.answer)
        t.dismiss()
        XCTAssertFalse(t.answer)
        XCTAssertTrue(t.follow, "Got it on the answer tip leaves the map's")
        t.load(remember: false)
        XCTAssertTrue(t.answer, "a fixture run does not remember it")
        let m = makeModel()
        XCTAssertTrue(m.actions.tips.answer)
        XCTAssertTrue(m.actions.tips.follow)

        _ = NSApplication.shared
        let actions = CardActions(), edit = EditState()
        edit.roundOpen = true
        edit.round = 2
        func height(_ card: CardModel) -> CGFloat {
            let host = NSHostingView(rootView: ExpandedCard(card: card, actions: actions).environmentObject(edit).frame(width: 380))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 800), styleMask: [.titled],
                                  backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = host
            spin()
            defer { window.close() }
            return host.fittingSize.height
        }
        let toCheck = CardModel(try makeComment(["note": "Define SPL at first use."]), round: 2, pdfs: [:], textX: [], showChanges: true)
        let resolved = CardModel(try makeComment(["note": "Define SPL at first use.", "verdict": "verified"]), round: 2, pdfs: [:],
                                 textX: [], showChanges: true)
        let withTip = height(toCheck), answeredWithTip = height(resolved)
        actions.tips.dismiss(remember: false)
        XCTAssertGreaterThan(withTip, height(toCheck) + 30, "the tip is under the buttons of a card to check")
        XCTAssertEqual(answeredWithTip, height(resolved), accuracy: 0.5, "not on an answered card")
    }

    /// POLISH §3 row 4: the new-comment editor shows the words selected in the PDF on top.
    func testTheEditorShowsTheSelectedWords() {
        _ = NSApplication.shared
        func height(_ quote: String) -> CGFloat {
            let d = CommentDraft(kind: .highlight, color: .yellow, note: "", mode: .text, page: 0, quote: quote)
            let tags = TagModel(store: TagStore(url: TagStore.temporary), remember: false)
            let host = NSHostingView(rootView: CommentEditor(title: "New comment", draft: d, tags: tags, onSave: {}, onCancel: {}))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 400), styleMask: [.titled],
                                  backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = host
            spin()
            defer { window.close() }
            return host.fittingSize.height
        }
        let none = height(""), one = height("band-limited index robust to boat noise")
        XCTAssertGreaterThan(one, none + 12)
        XCTAssertLessThan(height(String(repeating: "a long selection of words ", count: 40)), one + 50, "at most three lines")
    }
}
