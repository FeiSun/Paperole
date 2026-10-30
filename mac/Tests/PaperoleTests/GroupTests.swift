import AppKit
import SwiftUI
import XCTest
@testable import Paperole

/// The comment list's groups (design/ui-v2/PROPOSAL.md §2, §6; UX.md §1): To check, For the student, Closed this round
/// (folded); the selected card stays in its group until the selection leaves it; after a keyboard answer the next
/// card to check. Synthetic fixtures only.
final class GroupTests: XCTestCase {
    private func card(_ id: String, _ extra: [String: Any] = [:]) throws -> CardModel {
        var e = extra
        e["id"] = id
        return CardModel(try makeComment(e), round: 2, pdfs: [:], textX: [], showChanges: true)
    }

    /// Carried in document order, then new, as AppModel.ordered lists them.
    private func cards() throws -> [CardModel] {
        [try card("R1-01"), try card("R1-02", ["verdict": "verified"]), try card("R1-03", ["verdict": "reopened"]),
         try card("R1-04", ["anchor_state": "orphan"]), try card("R1-05", ["verdict": "wontfix"]), try card("R1-06"),
         try card("R2-01", ["carried": false, "created_round": 2, "anchor_state": "new"])]
    }

    func testGroupsByStatus() throws {
        let g = CardGroups(try cards())
        XCTAssertEqual(g.toCheck.map(\.id), ["R1-01", "R1-04", "R1-06"], "Not found counts as To check")
        XCTAssertEqual(g.forStudent.map(\.id), ["R1-03", "R2-01"], "follow-ups, then new comments")
        XCTAssertEqual(g.closed.map(\.id), ["R1-02", "R1-05"])
        XCTAssertEqual(g.group(of: "R1-05"), .closed)
        XCTAssertNil(g.group(of: "R9-99"))
        XCTAssertEqual(CardGroups.group(.notFound), .toCheck)
        XCTAssertEqual(CardGroups.group(.new), .forStudent)
        XCTAssertEqual(CardGroups.group(.keptAsIs), .closed)
    }

    /// An answered card stays where it was shown while it is selected, in its place in document order.
    func testTheSelectedCardStaysInItsGroup() throws {
        let g = CardGroups(try cards(), held: ("R1-02", .toCheck))
        XCTAssertEqual(g.toCheck.map(\.id), ["R1-01", "R1-02", "R1-04", "R1-06"])
        XCTAssertEqual(g.closed.map(\.id), ["R1-05"])
        let undone = CardGroups(try cards(), held: ("R1-06", .closed))  // an undo, before the engine's answer
        XCTAssertEqual(undone.closed.map(\.id), ["R1-02", "R1-05", "R1-06"])
    }

    func testAFoldedGroupIsSkipped() throws {
        let g = CardGroups(try cards())
        XCTAssertEqual(g.listed(showClosed: false).map(\.id), ["R1-01", "R1-04", "R1-06", "R1-03", "R2-01"])
        XCTAssertEqual(g.listed(showClosed: true).map(\.id), ["R1-01", "R1-04", "R1-06", "R1-03", "R2-01", "R1-02", "R1-05"])
    }

    /// After a keyboard answer: the next card to check below, else from the top; never the answered card itself.
    func testNextToCheck() throws {
        let g = CardGroups(try cards(), held: ("R1-04", .toCheck))
        XCTAssertEqual(g.nextToCheck(after: "R1-04"), "R1-06")
        XCTAssertEqual(g.nextToCheck(after: "R1-06"), "R1-01", "wraps to the top")
        XCTAssertEqual(g.nextToCheck(after: "R1-03"), "R1-01", "from another group: the first to check")
        let last = CardGroups([try card("R1-01", ["verdict": "verified"])], held: ("R1-01", .toCheck))
        XCTAssertNil(last.nextToCheck(after: "R1-01"), "none left: the selection stays")
        XCTAssertNil(CardGroups([try card("R1-01", ["verdict": "verified"])]).nextToCheck(after: "R1-01"))
    }
}

/// The comment list's table: closed lines are 30 pt and rows touch; when rows come or go (a card the selection left
/// moves to its group), the expanded card keeps its place on screen.
@MainActor
final class PanelTableTests: XCTestCase {
    private func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

    private func items(_ ids: [String], line: Set<String> = []) throws -> [PanelTable.Row] {
        try ids.map { id in
            let c = CardModel(try makeComment(["id": id]), round: 2, pdfs: [:], textX: [], showChanges: true)
            return .item(line.contains(id) ? .line(c) : .card(c))
        }
    }

    private func makeTable() -> (PanelTable, PanelScroller, NSWindow) {
        _ = NSApplication.shared
        let scroller = PanelScroller()
        let table = PanelTable(scroller: scroller, expanded: nil, compact: { _, _ in AnyView(Color.clear) },
                               expandedView: { _ in AnyView(Color.gray.frame(height: 200)) })
        // never ordered in: nothing appears on the screen
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = table.scrollView
        table.scrollView.layoutSubtreeIfNeeded()
        return (table, scroller, window)
    }

    func testLinesAre30AndRowsTouch() throws {
        let (table, _, window) = makeTable()
        table.show([.header("To check")] + (try items(["R1-01", "R1-02"])) + [.fold("Closed this round · 2", "Hide", group: .closed)]
                   + (try items(["R1-03", "R1-04"], line: ["R1-03", "R1-04"])))
        let a = try XCTUnwrap(table.frame(of: "R1-01")), b = try XCTUnwrap(table.frame(of: "R1-02"))
        let c = try XCTUnwrap(table.frame(of: "R1-03")), d = try XCTUnwrap(table.frame(of: "R1-04"))
        XCTAssertEqual(a.height, 44)
        XCTAssertEqual(b.minY, a.maxY, "rows touch")
        XCTAssertEqual(c.height, 30)
        XCTAssertEqual(d.minY - c.minY, 30)
        window.close()
    }

    func testTheExpandedCardKeepsItsPlaceWhenARowAboveLeaves() throws {
        let (table, scroller, window) = makeTable()
        let ids = (1...20).map { String(format: "R1-%02d", $0) }
        table.show([.header("To check")] + (try items(ids)))
        table.setExpanded("R1-12")
        scroller.debugScroll(300)
        spin()
        let before = try XCTUnwrap(table.frame(of: "R1-12"))
        XCTAssertEqual(before.height, 200)
        XCTAssertGreaterThan(before.minY, 0, "in view")
        // R1-05 and R1-06 leave the group above it; R1-05 goes to the end of the list
        table.show([.header("To check")] + (try items(ids.filter { $0 != "R1-05" && $0 != "R1-06" }))
                   + [.fold("Closed this round · 1", "Hide", group: .closed)] + (try items(["R1-05"], line: ["R1-05"])))
        let after = try XCTUnwrap(table.frame(of: "R1-12"))
        XCTAssertEqual(after.minY, before.minY, accuracy: 0.5, "the expanded card did not move on screen")
        XCTAssertEqual(after.height, 200)
        XCTAssertNil(table.frame(of: "R1-06"))
        window.close()
    }

    /// Visual review: resizing the window with a floating header and the hint row listed threw "The row at 0 is not
    /// floating". The hint, measured at the column's width, is measured again once the resize is done.
    func testAResizeMeasuresTheHintAgain() throws {
        let (table, _, window) = makeTable()
        let hint = String(repeating: "Select text and press Return to comment. ", count: 6)
        table.show([.header("To check")] + (try items(["R1-01", "R1-02"])) + [.header("For the student"), .hint(hint)]
                   + (try items(["R1-03"])))
        table.setExpanded("R1-02")
        spin()
        let wide = try XCTUnwrap(table.frame(of: "R1-03")).minY
        window.setContentSize(NSSize(width: 220, height: 500))
        table.scrollView.layoutSubtreeIfNeeded()
        spin()
        let narrow = try XCTUnwrap(table.frame(of: "R1-03")).minY
        XCTAssertGreaterThan(narrow, wide, "the hint wraps to more lines and its row grows")
        XCTAssertEqual(try XCTUnwrap(table.frame(of: "R1-02")).height, 200, "the expanded card keeps its height")
        window.close()
    }
}

/// The groups in the app model, on the synthetic round-2 fixture (`state-m2a.json`): J and K skip the folded group; a
/// card of it shows the group when selected; a card selected into another group goes back once the selection leaves.
@MainActor
final class PanelGroupTests: XCTestCase {
    private var drafts: URL!

    override func setUpWithError() throws {
        drafts = FileManager.default.temporaryDirectory.appendingPathComponent("pc-group-drafts-" + UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: drafts)
    }

    private func makeModel() throws -> AppModel {
        _ = NSApplication.shared
        var o = LaunchOptions()
        o.fixture = StepTests.fixtures.appendingPathComponent("state-m2a.json").path
        o.drafts = drafts.path
        return AppModel(options: o)
    }

    /// The fixture's state with its round closed, as the engine sends it after Finish.
    private func closedState() throws -> EngineState {
        let url = StepTests.fixtures.appendingPathComponent("state-m2a.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var round = try XCTUnwrap(json["round"] as? [String: Any])
        round["closed"] = true
        json["round"] = round
        return try EngineState.decode(JSONSerialization.data(withJSONObject: json))
    }

    func testFixtureGroups() throws {
        let m = try makeModel()
        XCTAssertEqual(m.panel.groups.closed.map(\.id), ["R1-01", "R1-07", "R1-04"])
        XCTAssertEqual(m.panel.groups.forStudent.first?.id, "R1-02", "the follow-up before the new comments")
        XCTAssertTrue(m.panel.groups.toCheck.contains { $0.id == "R1-08" }, "Not found counts as To check")
        XCTAssertFalse(m.panel.showClosed, "folded by default")
        XCTAssertEqual(m.commentsToCheck, m.panel.groups.toCheck.count)
    }

    func testJAndKSkipTheFoldedGroup() throws {
        let m = try makeModel()
        let closed = Set(m.panel.groups.closed.map(\.id))
        var seen: [String] = []
        for _ in 0..<(m.panel.all.count + 2) {
            m.move(1)
            if let id = m.panel.expanded { seen.append(id) }
        }
        XCTAssertTrue(closed.isDisjoint(with: seen))
        XCTAssertEqual(seen.last, m.panel.listed.last?.id)
        m.panel.showClosed = true
        m.move(1)
        XCTAssertTrue(closed.contains(m.panel.expanded ?? ""), "shown, the group is listed")
    }

    func testSelectingAClosedCardShowsItsGroup() throws {
        let m = try makeModel()
        m.markClicked("R1-07")
        XCTAssertTrue(m.panel.showClosed)
        XCTAssertEqual(m.panel.expanded, "R1-07")
        XCTAssertEqual(m.panel.groups.group(of: "R1-07"), .closed)
    }

    /// As an undo puts a card in the group of its restored answer: it stays there while selected, and goes back to its
    /// own group once the selection leaves it.
    func testACardHeldInAnotherGroupMovesWhenLeft() throws {
        let m = try makeModel()
        m.select(.comment("R1-06"), group: .closed)
        XCTAssertEqual(m.panel.groups.group(of: "R1-06"), .closed)
        XCTAssertTrue(m.panel.showClosed)
        m.select(.comment("R1-05"))
        XCTAssertEqual(m.panel.groups.group(of: "R1-06"), .toCheck)
        XCTAssertEqual(m.panel.groups.group(of: "R1-05"), .toCheck)
    }

    /// A card resolved with a click stays in To check while selected; once the round is finished it is listed with the
    /// closed ones, not under the closed round's "Left open".
    func testFinishingTheRoundEndsTheHold() throws {
        let m = try makeModel()
        m.select(.comment("R1-01"), group: .toCheck)
        XCTAssertEqual(m.panel.groups.group(of: "R1-01"), .toCheck)
        m.apply(try closedState())
        XCTAssertEqual(m.panel.expanded, "R1-01")
        XCTAssertEqual(m.panel.groups.group(of: "R1-01"), .closed)
    }

    /// Interaction review: Hide folded the Closed group over its selected card, which still took V, W and R.
    func testHidingTheClosedGroupDropsItsSelection() throws {
        let m = try makeModel()
        m.markClicked("R1-07")
        XCTAssertTrue(m.panel.showClosed)
        m.toggleFold()
        XCTAssertFalse(m.panel.showClosed)
        XCTAssertNil(m.panel.expanded)
        XCTAssertNil(m.selectedComment, "a card that is not listed takes no keys")
        m.select(.comment("R1-05"))
        m.toggleFold()
        m.toggleFold()
        XCTAssertEqual(m.panel.expanded, "R1-05", "a card of another group stays selected")
        // the Changes tab's folded group likewise, and the Comments tab's card is left as it was
        m.tab = .changes
        let linked = try XCTUnwrap(m.changes.linked.first?.id)
        m.select(.change(linked))
        XCTAssertTrue(m.changes.showLinked)
        m.toggleFold()
        XCTAssertFalse(m.changes.showLinked)
        XCTAssertNil(m.changes.expanded)
        XCTAssertEqual(KeyRoute.action("v", m.keyState), nil, "no change selected to mark checked")
        XCTAssertEqual(m.panel.expanded, "R1-05")
    }

    /// Interaction review: a choice row left open survived a switch to an earlier round, and its Return gave the open
    /// round's comment a verdict from there. It goes with the open round, and answers nothing in a closed one.
    func testAChoiceRowNeverAnswersInAClosedRound() throws {
        let m = try makeModel()
        m.select(.comment("R1-05"))
        m.edit.choice = EditState.Choice(id: "R1-05", verdict: "verified", text: "stale draft", sent: false)
        XCTAssertTrue(m.keyState.choice)
        m.apply(try closedState())
        XCTAssertNil(m.edit.choice, "the row goes with the open round")
        m.edit.choice = EditState.Choice(id: "R1-05", verdict: "verified", text: "stale draft", sent: false)
        XCTAssertNil(KeyRoute.action("return", m.keyState))
        m.choose(.withText)
        XCTAssertNil(m.alertMessage, "no verdict was sent (the fixture would say it cannot save one)")
    }

    /// Interaction review: a choice row kept Return over re-anchoring and a PDF selection. Either now drops it.
    func testSelectionsAndReanchoringDropTheChoiceRow() throws {
        let m = try makeModel()
        m.select(.comment("R1-05"))
        m.edit.choice = EditState.Choice(id: "R1-05", verdict: "verified", text: "my draft", sent: false)
        m.hasPDFSelection = true
        XCTAssertNil(m.edit.choice)
        XCTAssertEqual(KeyRoute.action("return", m.keyState), .openEditor)
        m.hasPDFSelection = false
        m.edit.choice = EditState.Choice(id: "R1-05", verdict: "verified", text: "my draft", sent: false)
        m.beginReanchor("R1-05")
        XCTAssertNil(m.edit.choice)
        XCTAssertEqual(KeyRoute.action("return", m.keyState), .place)
        m.leaveReanchor()
    }

    /// Interaction review: with this round's remark being edited, a click on an answer button dropped the edit. The
    /// editor is closed first (saved when changed), then the answer is given.
    func testARemarkBeingEditedIsSavedBeforeAnAnswer() throws {
        let m = try makeModel()
        m.beginRemarkEdit("R1-01")  // resolved, without a remark
        XCTAssertEqual(m.edit.field, .remark("R1-01"))
        m.press("verified", for: "R1-01", button: true)  // unchanged: it closes, and Resolve then clears (an engine call)
        XCTAssertNil(m.edit.field)
        XCTAssertNotNil(m.alertMessage, "the answer was sent after the editor closed")
    }

    /// A remark editor left open on a card whose answer was cleared meanwhile: its words become the card's draft.
    func testARemarkOfAClearedCardBecomesItsDraft() throws {
        let m = try makeModel()
        m.select(.comment("R1-05"))  // to check
        m.edit.field = .remark("R1-05")
        m.edit.original = "first remark"
        m.edit.text = "first remark plus edit"
        m.commitEdit()
        XCTAssertNil(m.edit.field)
        XCTAssertEqual(m.drafts["R1-05"], "first remark plus edit")
        XCTAssertEqual(DraftStore(directory: drafts).load(paper: m.selectedPath ?? "", round: 2)["R1-05"],
                       "first remark plus edit")
    }

    /// Audit 2026-10-17: an editor open on a card was neither saved nor asked about when the app quit. Quitting saves
    /// it first, as focus leaving it does; words left for a card whose answer was cleared become its draft.
    func testQuittingSavesAnEditorFirst() throws {
        let m = try makeModel()
        var called: [Bool] = []
        XCTAssertEqual(m.saveEditBeforeQuit { called.append($0) }, .nothing, "no editor")
        // this round's words, on a card whose answer was cleared meanwhile: they become its unsent draft at once
        m.select(.comment("R1-05"))
        m.edit.field = .remark("R1-05")
        m.edit.original = "remark"
        m.edit.text = "remark, edited"
        XCTAssertEqual(m.saveEditBeforeQuit { called.append($0) }, .nothing)
        XCTAssertNil(m.edit.field)
        XCTAssertEqual(m.drafts["R1-05"], "remark, edited")
        XCTAssertNotNil(m.unsentDraftsQuestion(), "then the question lists the draft")
        // a new comment's note: sent to the engine (which a fixture cannot reach), so quitting does not go on and the
        // editor keeps the text
        m.beginNoteEdit("R2-01")
        XCTAssertEqual(m.edit.field, .note("R2-01"))
        m.edit.text = "a longer note"
        XCTAssertEqual(m.saveEditBeforeQuit { called.append($0) }, .refused)
        XCTAssertEqual(m.edit.field, .note("R2-01"))
        XCTAssertEqual(m.edit.text, "a longer note")
        XCTAssertFalse(m.edit.saving)
        // unchanged: it closes, and nothing waits
        m.edit.text = m.edit.original
        XCTAssertEqual(m.saveEditBeforeQuit { called.append($0) }, .nothing)
        XCTAssertNil(m.edit.field)
        XCTAssertEqual(called, [], "nothing was left waiting for the engine")
    }

    /// Audit 2026-10-17: the question on quitting names a new comment's note that is not saved (quitting loses it),
    /// with the unsent drafts (which stay).
    func testTheQuitQuestionNamesAnUnsavedNote() {
        XCTAssertNil(AppModel.quitQuestion(note: nil, drafts: 0, listed: ""))
        let drafts = AppModel.quitQuestion(note: nil, drafts: 2, listed: "R1-02, R1-05 in “T”")
        XCTAssertEqual(drafts?.title, "You have 2 unsent drafts")
        XCTAssertEqual(drafts?.detail, "R1-02, R1-05 in “T”. Drafts stay on this Mac and come back on their cards; nothing "
                       + "goes to the student until you send it.")
        let note = AppModel.quitQuestion(note: "p.7", drafts: 0, listed: "")
        XCTAssertEqual(note?.title, "Your new comment on p.7 is not saved")
        XCTAssertEqual(note?.detail, "Quitting discards its note. Click Cancel, then Save in the comment.")  // mouse first
        let both = AppModel.quitQuestion(note: "p.7", drafts: 1, listed: "R1-02 in “T”")
        XCTAssertEqual(both?.title, "Your new comment on p.7 is not saved")
        XCTAssertTrue(both?.detail.contains(" You also have an unsent draft: R1-02 in “T”. Drafts stay on this Mac") == true)
    }

    /// Audit 2026-10-17: a note begun on one paper was saved to the paper shown when Save was pressed. It goes only to
    /// the paper and round it was begun on.
    func testANewCommentIsSavedOnlyWhereItWasBegun() throws {
        let m = try makeModel()
        var saved: [Bool] = []
        let anchor: [String: Any] = ["page": 0, "rects": [[72, 100, 200, 110]], "text": "x"]
        m.createComment(anchor: anchor, note: "n", kind: .highlight, color: .yellow, on: ("/another/paper", m.round?.n)) {
            saved.append($0)
        }
        XCTAssertEqual(saved, [false])
        XCTAssertTrue(m.alertMessage?.hasPrefix("This note was begun on another paper or round") == true)
        m.alertMessage = nil
        m.createComment(anchor: anchor, note: "n", kind: .highlight, color: .yellow, on: (m.selectedPath, 1)) { saved.append($0) }
        XCTAssertEqual(saved, [false, false], "another round")
        m.alertMessage = nil
        m.createComment(anchor: anchor, note: "n", kind: .highlight, color: .yellow, on: m.shown) { saved.append($0) }
        XCTAssertTrue(m.alertMessage?.hasPrefix("Fixture mode") == true, "the shown paper and round: sent to the engine")
    }

    /// A fixture run, `swift test` among them, keeps its drafts out of the user's Application Support.
    func testAFixtureKeepsItsDraftsOutOfApplicationSupport() throws {
        _ = NSApplication.shared
        var o = LaunchOptions()
        o.fixture = StepTests.fixtures.appendingPathComponent("state-m2a.json").path
        XCTAssertNotEqual(AppModel(options: o).draftStore.directory.standardizedFileURL, DraftStore.standard.standardizedFileURL)
    }

    /// Visual review: in a closed round nothing is the advisor's move, so a comment left open is not amber.
    func testAClosedRoundIsNotAmber() throws {
        let m = try makeModel()
        XCTAssertEqual(m.panel.cards.first { $0.id == "R1-09" }?.stateTone, .attention)
        m.apply(try closedState())
        let open = try XCTUnwrap(m.panel.cards.first { $0.id == "R1-05" })
        XCTAssertFalse(open.open)
        XCTAssertEqual(open.status, .toCheck)
        // audit 2026-10-17: listed under "Left open", its card, chip tooltip and VoiceOver said "To check"
        XCTAssertEqual(open.status.word(open: open.open), "Left open")
        XCTAssertTrue(open.accessibility.hasPrefix("R1-05, left open, "), open.accessibility)
        let uncertain = try XCTUnwrap(m.panel.cards.first { $0.id == "R1-09" })
        XCTAssertEqual(uncertain.stateWord, "position uncertain")
        XCTAssertEqual(uncertain.stateTone, .plain)
        XCTAssertEqual(m.panel.cards.first { $0.id == "R1-08" }?.stateWord, "not found", "no re-anchor in a closed round")
    }
}
