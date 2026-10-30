import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Paperole

/// The mouse-first answer flow and list of UI v2.1 (design/ui-v2.1/POLISH.md §6) and its phase 0: an answer from a
/// click or a key moves on, the next card taking the answered card's place; a double click answers one card; rows dim
/// while a card is expanded; For the student folds; no key letters on buttons; closing the window goes the way quitting
/// goes; Comment on it… on an edit without words says so. Synthetic fixtures only.
final class ClickGuardTests: XCTestCase {
    func testTheNewCardIgnoresClicksForAMoment() {
        var g = ClickGuard()
        XCTAssertFalse(g.blocks("R1-02", now: 10), "nothing armed")
        g.arm("R1-02", now: 10)
        XCTAssertTrue(g.blocks("R1-02", now: 10.2), "a double click's second click")
        XCTAssertFalse(g.blocks("R1-03", now: 10.2), "another card's buttons")
        XCTAssertFalse(g.blocks("R1-02", now: 10 + ClickGuard.interval + 0.01), "after 0.4 s")
        XCTAssertEqual(ClickGuard.interval, 0.4)
    }

    /// Interaction review 2026-10-18: in a narrow panel the answer buttons ran out of the card. They wrap, Keep as is
    /// (the last) always at the right edge.
    func testTheAnswerRowWraps() {
        let sizes = [CGSize(width: 125, height: 26), CGSize(width: 95, height: 26), CGSize(width: 116, height: 26)]
        let wide = AnswerRow.frames(sizes, width: 400)
        XCTAssertEqual(wide.map(\.minX), [0, 133, 284])
        XCTAssertEqual(Set(wide.map(\.minY)), [0])
        let narrow = AnswerRow.frames(sizes, width: 268)  // the panel at its minimum, 320
        XCTAssertEqual(narrow.map(\.minX), [0, 133, 152])
        XCTAssertEqual(narrow.map(\.minY), [0, 0, 32])
        XCTAssertTrue(narrow.allSatisfy { $0.maxX <= 268 })
        let tiny = AnswerRow.frames(sizes, width: 200)
        XCTAssertEqual(tiny.map(\.minY), [0, 32, 64])
        XCTAssertEqual(tiny[2].maxX, 200)
        XCTAssertEqual(AnswerRow.frames(sizes, width: .infinity).map(\.minX), [0, 133, 236])
    }

    func testForTheStudentFoldsOutOfTheListed() throws {
        let cards = [CardModel(try makeComment(["id": "R1-01"]), round: 2, pdfs: [:], textX: [], showChanges: true),
                     CardModel(try makeComment(["id": "R1-02", "verdict": "reopened"]), round: 2, pdfs: [:], textX: [],
                               showChanges: true),
                     CardModel(try makeComment(["id": "R1-03", "verdict": "verified"]), round: 2, pdfs: [:], textX: [],
                               showChanges: true)]
        let g = CardGroups(cards)
        XCTAssertEqual(g.listed(showClosed: false, showStudent: false).map(\.id), ["R1-01"])
        XCTAssertEqual(g.listed(showClosed: true, showStudent: false).map(\.id), ["R1-01", "R1-03"])
        XCTAssertEqual(g.listed(showClosed: false).map(\.id), ["R1-01", "R1-02"])
    }
}

/// The comment list's table: the next card takes the answered card's slot; rows dim while a card is expanded.
@MainActor
final class SlotAndDimTests: XCTestCase {
    private func spin(_ s: Double = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    private func items(_ ids: [String]) throws -> [PanelTable.Row] {
        try ids.map { .item(.card(CardModel(try makeComment(["id": $0]), round: 2, pdfs: [:], textX: [], showChanges: true))) }
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

    private let ids = (1...20).map { String(format: "R1-%02d", $0) }

    func testTheNextCardTakesTheAnsweredCardsSlot() throws {
        let (table, scroller, window) = makeTable()
        table.show([.header("To check")] + (try items(ids)))
        table.setExpanded("R1-08")
        scroller.debugScroll(250)
        spin()
        let answered = try XCTUnwrap(table.frame(of: "R1-08"))
        let above = try XCTUnwrap(table.frame(of: "R1-07"))
        XCTAssertGreaterThan(answered.minY, PanelScroller.header + 16, "in view")
        // the answer moves on (AppModel.advance): the next card is expanded in the slot mode...
        scroller.request("R1-09", mode: .slot)
        table.setExpanded("R1-09")
        XCTAssertEqual(try XCTUnwrap(table.frame(of: "R1-09")).minY, answered.minY, accuracy: 0.5)
        // ...then the answered card leaves To check for its folded group
        table.show([.header("To check")] + (try items(ids.filter { $0 != "R1-08" }))
                   + [.fold("Closed this round · 1", "Show", group: .closed)])
        XCTAssertNil(table.frame(of: "R1-08"))
        XCTAssertEqual(try XCTUnwrap(table.frame(of: "R1-09")).minY, answered.minY, accuracy: 0.5, "in the answered card's place")
        XCTAssertEqual(try XCTUnwrap(table.frame(of: "R1-07")).minY, above.minY, accuracy: 0.5, "the rows above did not move")
        spin()  // the scroller decides: the card is whole in view, so nothing moves
        XCTAssertEqual(try XCTUnwrap(table.frame(of: "R1-09")).minY, answered.minY, accuracy: 0.5)
        window.close()
    }

    /// The next card to check can be an earlier one (wrapping to the top): it is brought to the answered card's place.
    func testAnEarlierNextCardComesToTheSlot() throws {
        let (table, scroller, window) = makeTable()
        table.show([.header("To check")] + (try items(ids)))
        table.setExpanded("R1-15")
        scroller.debugScroll(600)
        spin()
        let answered = try XCTUnwrap(table.frame(of: "R1-15"))
        scroller.request("R1-10", mode: .slot)
        table.setExpanded("R1-10")
        table.show([.header("To check")] + (try items(ids.filter { $0 != "R1-15" })))
        XCTAssertEqual(try XCTUnwrap(table.frame(of: "R1-10")).minY, answered.minY, accuracy: 0.5)
        window.close()
    }

    /// A J/K step (no slot) keeps the newly selected row where it was, as before.
    func testAStepKeepsTheNewRowInPlace() throws {
        let (table, scroller, window) = makeTable()
        table.show([.header("To check")] + (try items(ids)))
        table.setExpanded("R1-08")
        scroller.debugScroll(250)
        spin()
        let row = try XCTUnwrap(table.frame(of: "R1-09"))
        scroller.request("R1-09", mode: .minimal)
        table.setExpanded("R1-09")
        XCTAssertEqual(try XCTUnwrap(table.frame(of: "R1-09")).minY, row.minY, accuracy: 0.5)
        window.close()
    }

    func testRowsDimWhileACardIsExpanded() throws {
        let (table, _, window) = makeTable()
        table.dims = true
        let three = ["R1-01", "R1-02", "R1-03"]
        table.show([.header("To check")] + (try items(three)))
        let tv = try XCTUnwrap(table.scrollView.documentView as? NSTableView)
        for row in 1...3 { _ = tv.view(atColumn: 0, row: row, makeIfNecessary: true) }  // the rows' views
        XCTAssertEqual(table.dimmed, [], "nothing expanded: nothing dimmed")
        table.setExpanded("R1-02")
        XCTAssertEqual(table.dimmed, ["R1-01", "R1-03"])
        let looks = three.compactMap { table.look($0) }
        XCTAssertEqual(looks.count, 3)
        XCTAssertTrue(looks[0].quiet)
        var published = 0
        let subscriptions = looks.map { $0.objectWillChange.sink { _ in published += 1 } }
        table.setExpanded("R1-03")  // a J step
        XCTAssertEqual(table.dimmed, ["R1-01", "R1-02"])
        XCTAssertEqual(published, 0, "a step from one card to another lays out no row")
        looks[0].hovering = true
        XCTAssertFalse(looks[0].quiet, "the pointer shows the row as it is")
        looks[0].hovering = false
        XCTAssertTrue(looks[0].quiet)
        spin(PanelTable.settleDelay + 0.1)  // the step's rows settled: the pointer counts again
        let row = try XCTUnwrap(table.rowFrame("R1-01"))
        table.pointerMoved(to: NSPoint(x: row.midX, y: row.midY))
        XCTAssertTrue(looks[0].hovering)
        table.setExpanded("R1-01")  // a click on a hovered row expands it: it comes back unhovered
        XCTAssertFalse(looks[0].hovering)
        table.setExpanded(nil)
        XCTAssertEqual(table.dimmed, [])
        XCTAssertFalse(looks.contains { $0.quiet })
        withExtendedLifetime(subscriptions) {}
        window.close()
    }

    /// A card first in its group is placed with its own header (behaviour review 2026-10-19): the least scroll puts the
    /// header, not the card's top, just under the floating one, so the two never overlap. Not in the slot mode.
    func testACardFirstInItsGroupKeepsItsHeaderInView() throws {
        let (table, scroller, window) = makeTable()
        table.show([.header("To check")] + (try items(Array(ids.prefix(10)))) + [.gap, .header("For the student")]
                   + (try items(Array(ids.suffix(10)))))
        table.setExpanded("R1-11")
        spin()
        let card = try XCTUnwrap(table.frame(of: "R1-11")), whole = try XCTUnwrap(table.frame(of: "R1-11", header: true))
        XCTAssertLessThan(whole.minY, card.minY - 10, "up over its group's header")
        XCTAssertEqual(whole.maxY, card.maxY)
        XCTAssertEqual(table.frame(of: "R1-12", header: true), table.frame(of: "R1-12"), "not a group's first")
        scroller.debugScroll(card.minY - 20)  // the card's top 20 pt from the top, under the floating header
        spin()
        scroller.request("R1-11", mode: .minimal)
        spin(0.5)
        let placed = try XCTUnwrap(table.frame(of: "R1-11", header: true))
        XCTAssertEqual(placed.minY, PanelScroller.header + ScrollDecision.margin, accuracy: 0.5)
        window.close()
    }

    func testTheChangesListDoesNotDim() throws {
        let (table, _, window) = makeTable()
        table.show([.header("To check")] + (try items(["R1-01", "R1-02"])))
        table.setExpanded("R1-02")
        XCTAssertEqual(table.dimmed, [])
        window.close()
    }
}

/// The flow in the app model, on the synthetic round-2 fixture (`state-m2a.json`).
@MainActor
final class AnswerFlowTests: XCTestCase {
    private var drafts: URL!

    override func setUpWithError() throws {
        drafts = FileManager.default.temporaryDirectory.appendingPathComponent("pc-flow-drafts-" + UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: drafts)
    }

    private func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

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

    private func edit(_ key: String, _ id: String, _ set: [String: Any]) -> (inout [String: Any]) -> Void {
        { json in
            var list = json[key] as? [[String: Any]] ?? []
            for i in list.indices where list[i]["id"] as? String == id { list[i].merge(set) { _, b in b } }
            json[key] = list
        }
    }

    /// R: the cursor goes into the card's field, and the panel to the card's end, where the field is: a card taller
    /// than the panel no longer took the cursor into a field out of view (behaviour review 2026-10-19).
    func testRShowsTheField() throws {
        let m = makeModel()
        m.select(.comment("R1-05"))
        m.requestFieldFocus("R1-05")
        XCTAssertEqual(m.edit.focusRequest, "R1-05")
        XCTAssertEqual(m.panel.scroller.pendingMode, .end)
        m.leaveField()
    }

    /// POLISH §6: Review answers move on, from a click as from a key; Focus (later) turns `answersAdvance` off.
    func testAnAnswerMovesOnToTheNextCardInItsSlot() throws {
        let m = makeModel()
        XCTAssertTrue(m.answersAdvance)
        XCTAssertEqual(m.panel.groups.toCheck.map(\.id), ["R1-06", "R1-05", "R1-09", "R1-10", "R1-03", "R1-08"])
        m.select(.comment("R1-05"))
        // the engine's reply to a Resolve: R1-05 stays in To check while it is selected
        m.apply(try state(edit("comments", "R1-05", ["verdict": "verified"])))
        XCTAssertEqual(m.panel.groups.group(of: "R1-05"), .toCheck)
        m.advance(from: "R1-05")
        XCTAssertEqual(m.selection, .comment("R1-09"), "the next card to check below")
        XCTAssertEqual(m.panel.expanded, "R1-09")
        XCTAssertEqual(m.panel.groups.group(of: "R1-05"), .closed, "the answered card went to its group")
        XCTAssertFalse(m.panel.showClosed, "which stays folded")
        XCTAssertEqual(m.panel.scroller.pendingMode, .slot, "in the answered card's place")
        // a double click's second click on the new card's buttons answers nothing; a key is not held back
        XCTAssertTrue(m.clickIgnored("R1-09"))
        m.actions.press("verified", "R1-09")
        m.actions.press("wontfix", "R1-09")
        m.actions.discardDraft("R1-09")
        XCTAssertNil(m.alertMessage, "nothing was sent")
        spin(ClickGuard.interval + 0.05)
        XCTAssertFalse(m.clickIgnored("R1-09"))
        m.actions.press("verified", "R1-09")
        XCTAssertTrue(m.alertMessage?.hasPrefix("Fixture mode") == true, "a click after 0.4 s answers (sent to the engine)")
        m.alertMessage = nil
        m.advance(from: "R1-09")  // R1-09 not answered in the state: it stays To check, and the next one comes
        XCTAssertEqual(m.panel.expanded, "R1-10")
        m.press("verified", for: "R1-10")
        XCTAssertTrue(m.alertMessage?.hasPrefix("Fixture mode") == true, "keys are never held back")
    }

    /// No card left to check, or the selection moved meanwhile: the selection stays.
    func testNoNextCardOrAMovedSelectionStays() throws {
        let m = makeModel()
        m.select(.comment("R1-05"))
        m.select(.comment("R1-06"))
        m.advance(from: "R1-05")
        XCTAssertEqual(m.panel.expanded, "R1-06", "the selection moved on meanwhile")
        let none = try state { json in
            var list = json["comments"] as? [[String: Any]] ?? []
            for i in list.indices where list[i]["carried"] as? Bool == true && list[i]["verdict"] is NSNull {
                list[i]["verdict"] = "verified"
            }
            json["comments"] = list
        }
        m.apply(none)
        XCTAssertEqual(m.panel.groups.toCheck.map(\.id), ["R1-06"], "held while selected")
        m.advance(from: "R1-06")
        XCTAssertEqual(m.panel.expanded, "R1-06")
    }

    /// For the student is folded by default, as Closed this round: J and K skip it, a card of it shows it when selected
    /// another way, and Hide with one of its cards selected leaves no card selected.
    func testForTheStudentFoldsByDefault() throws {
        let m = makeModel()
        XCTAssertFalse(m.panel.showStudent)
        let student = Set(m.panel.groups.forStudent.map(\.id))
        XCTAssertTrue(student.contains("R1-02"))
        XCTAssertTrue(student.isDisjoint(with: m.panel.listed.map(\.id)))
        for _ in 0..<(m.panel.all.count + 2) {
            m.move(1)
            XCTAssertFalse(student.contains(m.panel.expanded ?? ""))
        }
        let list = CommentListController(panel: m.panel, actions: m.actions, edit: m.edit)
        XCTAssertNil(list.table.frame(of: "R1-02"), "folded: not listed")
        m.markClicked("R1-02")
        XCTAssertTrue(m.panel.showStudent, "a click on its mark shows the group")
        XCTAssertNotNil(list.table.frame(of: "R1-02"))
        m.toggleFold(.student)
        XCTAssertFalse(m.panel.showStudent)
        XCTAssertNil(m.panel.expanded, "a card that is not listed takes no keys")
        m.toggleFold(.student)
        m.select(.comment("R1-05"))
        m.toggleFold(.student)
        XCTAssertEqual(m.panel.expanded, "R1-05", "a card of another group stays selected")
        XCTAssertNil(list.table.frame(of: "R1-02"))
        withExtendedLifetime(list) {}
    }

    /// The toast's Undo is a button (Redo after an undo); the keys are in its help tag.
    func testTheToastOffersUndo() {
        let m = makeModel()
        m.showPanelToast("R1-05 resolved", action: .undo)
        XCTAssertEqual(m.panelToast.action, .undo)
        m.actions.undo()  // nothing recorded in a fixture: it says so, with no button
        XCTAssertEqual(m.panelToast.text, "Nothing to undo")
        XCTAssertNil(m.panelToast.action)
    }

    /// Undo turns into Redo where it stands: for 0.4 s after one the other ignores clicks, so a double click undoes once.
    func testTheToastsButtonIgnoresADoubleClick() {
        let m = makeModel()
        m.showPanelToast("R1-05 resolved", action: .undo)
        m.actions.undo()
        XCTAssertEqual(m.panelToast.text, "Nothing to undo")
        m.actions.redo()
        XCTAssertEqual(m.panelToast.text, "Nothing to undo", "the second click: ignored")
        spin(ClickGuard.interval + 0.05)
        m.actions.redo()
        XCTAssertEqual(m.panelToast.text, "Nothing to redo")
    }

    /// The pointer on the toast's Undo keeps it past its 2.5 s, so Undo can be reached; it goes 1.5 s after the pointer
    /// leaves.
    func testThePointerKeepsTheToast() {
        let m = makeModel()
        m.showPanelToast("R1-05 resolved", action: .undo)
        m.holdPanelToast(true)
        spin(2.7)
        XCTAssertEqual(m.panelToast.text, "R1-05 resolved")
        m.holdPanelToast(false)
        spin(1.0)
        XCTAssertNotNil(m.panelToast.text)
        spin(0.7)
        XCTAssertNil(m.panelToast.text)
    }

    /// The toast takes clicks only on its Undo; elsewhere a click reaches what is under it (integration, 2026-10-18: a
    /// click on a mark under it did nothing, for as long as the pointer held it). Also in Focus, where it sits under
    /// the one card (`ToastPlace`) and its frame runs down the panel.
    func testTheToastTakesClicksOnlyOnItsButton() throws {
        let m = makeModel()
        m.showPanelToast("R1-05 resolved", action: .undo)
        for under in [nil, 10] as [CGFloat?] {
            let place = ToastPlace()
            place.below = under
            let frame = NSRect(x: 0, y: 0, width: 300, height: 160)
            let below = NSView(frame: frame)  // the list under the toast
            let host = NSHostingView(rootView: Below(view: below)
                .overlay(alignment: .bottom) { PanelToastView(toast: m.panelToast, place: place, actions: m.actions) })
            host.frame = frame
            let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = host
            spin(0.2)
            func buttons(_ v: NSView) -> [NSButton] { (v as? NSButton).map { [$0] } ?? v.subviews.flatMap(buttons) }
            let undo = try XCTUnwrap(buttons(host).first, "Undo is an AppKit button")
            let b = undo.convert(undo.bounds, to: host.superview)
            XCTAssertEqual(b.midY > frame.midY, under != nil, "under the card (top) in Focus, else at the foot")
            XCTAssertTrue(host.hitTest(CGPoint(x: b.midX, y: b.midY))?.isDescendant(of: undo) == true, "Undo takes the click")
            let onText = CGPoint(x: b.minX - 40, y: b.midY)  // the words before Undo, on the pill
            XCTAssertTrue(host.hitTest(onText)?.isDescendant(of: below) == true, "the words and the pill pass the click on")
            let away = CGPoint(x: frame.midX, y: under != nil ? 20 : frame.maxY - 20)  // the rest of the panel
            XCTAssertTrue(host.hitTest(away)?.isDescendant(of: below) == true, "the rest of the panel takes its clicks")
            window.close()
        }
    }

    /// Interaction review 2026-10-18: on the last card to check no other card takes its place, so its own buttons ignore
    /// a double click's second click, which cleared the answer just given; clearing an answer takes its toast away.
    func testTheLastCardIgnoresADoubleClicksSecondClick() throws {
        let m = makeModel()
        let others = try state { json in
            var list = json["comments"] as? [[String: Any]] ?? []
            for i in list.indices where list[i]["carried"] as? Bool == true && list[i]["verdict"] is NSNull
                && list[i]["id"] as? String != "R1-06" {
                list[i]["verdict"] = "verified"
            }
            json["comments"] = list
        }
        m.apply(others)
        XCTAssertEqual(m.panel.groups.toCheck.map(\.id), ["R1-06"])
        m.select(.comment("R1-06"))
        m.apply(try state { json in  // the engine's reply: all resolved, R1-06 too
            var list = json["comments"] as? [[String: Any]] ?? []
            for i in list.indices where list[i]["carried"] as? Bool == true && list[i]["verdict"] is NSNull { list[i]["verdict"] = "verified" }
            json["comments"] = list
        })
        m.answered("R1-06", before: Answer(), after: Answer(verdict: "verified"), on: m.draftsKey, advance: true)
        XCTAssertEqual(m.panel.expanded, "R1-06", "no card left to move on to")
        XCTAssertEqual(m.panelToast.text, "R1-06 resolved")
        XCTAssertTrue(m.clickIgnored("R1-06"), "its own buttons ignore the double click's second click")
        m.actions.press("verified", "R1-06")
        XCTAssertNil(m.alertMessage, "the second click cleared nothing (nothing was sent)")
        spin(ClickGuard.interval + 0.05)
        XCTAssertFalse(m.clickIgnored("R1-06"))
        // a later click clears it on purpose: the toast that named the answer goes
        m.answered("R1-06", before: Answer(verdict: "verified"), after: Answer(), on: m.draftsKey, advance: true)
        XCTAssertNil(m.panelToast.text, "a cleared answer's toast would undo what no longer is")
        XCTAssertTrue(m.clickIgnored("R1-06"), "clearing is guarded too: a double click on Resolve clears it once")
    }

    /// Interaction review 2026-10-18: another paper (or no paper) takes the answer toast away, whose Undo acted on the
    /// paper shown; an open inline editor is saved first (sent to the engine), as for another round, not dropped.
    func testAnotherPaperTakesTheToastAndSavesTheEditor() throws {
        let m = makeModel()
        m.showPanelToast("R1-05 resolved", action: .undo)
        m.beginNoteEdit("R2-02")
        XCTAssertEqual(m.edit.field, .note("R2-02"))
        m.edit.text = "A note typed and not saved yet."
        m.selectPaper(nil)
        XCTAssertNil(m.panelToast.text)
        XCTAssertTrue(m.alertMessage?.hasPrefix("Fixture mode") == true, "the note was sent to be saved")
        XCTAssertNil(m.edit.field)
    }

    /// POLISH §6, §7 (an answer while reading never moves the PDF or jumps): Follow up with no draft in Focus puts the
    /// cursor in the card's field there, without leaving Focus; the follow-up sent from it stays on the same card.
    func testAFollowUpWrittenInFocusStaysOnTheCard() throws {
        let m = makeModel()
        m.select(.comment("R1-05"))
        m.setFocus(true)
        XCTAssertTrue(m.focus)
        m.actions.press("reopened", "R1-05")  // the card's Follow up, no draft
        XCTAssertTrue(m.focus, "the card's field is in Focus's panel")
        XCTAssertEqual(m.edit.focusRequest, "R1-05")
        XCTAssertFalse(m.answersAdvance)
        m.apply(try state(edit("comments", "R1-05", ["verdict": "reopened", "verdict_note": "Still missing."])))
        m.answered("R1-05", before: Answer(), after: Answer(verdict: "reopened", note: "Still missing."), on: m.draftsKey,
                   advance: m.answersAdvance)
        XCTAssertTrue(m.focus)
        XCTAssertEqual(m.selection, .comment("R1-05"), "on the same card: nothing moved on")
    }

    /// Interaction review 2026-10-18: the Finish sheet's Send as follow-up and Discard leave their row where it was (the
    /// next draft's buttons slid under the pointer, so a double click handled two drafts), ignore clicks for 0.4 s,
    /// and a discard can be undone there.
    func testTheFinishSheetKeepsHandledDraftsInPlace() throws {
        let m = makeModel()
        m.setDraft("R1-05", "Give the times.")
        m.setDraft("R1-06", "Which window?")
        m.setDraft("R1-09", "Say why.")
        m.openFinish()
        XCTAssertTrue(m.showFinish)
        XCTAssertTrue(m.finishDraft("R1-05", send: false))
        XCTAssertFalse(m.finishDraft("R1-06", send: false), "the double click's second click: ignored")
        XCTAssertEqual(m.draftText("R1-05"), "")
        XCTAssertEqual(m.draftText("R1-06"), "Which window?")
        let s = FinishSummary(round: 2, comments: m.state?.comments ?? [], drafts: m.drafts, unrequested: 0, unread: nil)
        let rows = FinishSummary.rows(s.drafts, handled: m.finishPreview.handled)
        XCTAssertEqual(rows.map(\.id), ["R1-05", "R1-06", "R1-09"], "the discarded row stays where it was")
        XCTAssertEqual(rows.map { $0.handled?.sent }, [false, nil, nil])
        m.finishRestoreDraft("R1-05")
        XCTAssertEqual(m.draftText("R1-05"), "", "Undo too soon after Discard: ignored")
        spin(ClickGuard.interval + 0.05)
        m.finishRestoreDraft("R1-05")
        XCTAssertEqual(m.drafts["R1-05"], "Give the times.", "Undo puts the words back")
        XCTAssertNil(m.finishPreview.handled["R1-05"])
        spin(ClickGuard.interval + 0.05)
        XCTAssertTrue(m.finishDraft("R1-06", send: true))  // sent: the engine has it (here, fixture mode refuses)
        XCTAssertEqual(m.finishPreview.handled["R1-06"]?.sent, true)
        XCTAssertEqual(FinishSummary.rows(FinishSummary(round: 2, comments: m.state?.comments ?? [], drafts: m.drafts,
                                                        unrequested: 0, unread: nil).drafts,
                                          handled: m.finishPreview.handled).first { $0.id == "R1-06" }?.handled,
                       nil, "refused: still unsent, shown as such")
        m.openFinish()
        XCTAssertEqual(m.finishPreview.handled, [:], "the sheet opens anew")
    }

    /// Interaction review 2026-10-18: Mark checked on the Changes tab moves on, as V does (it did not), the next change
    /// taking its place; that change's buttons ignore a double click's second click (else the change's own).
    func testMarkCheckedMovesOnAndGuards() throws {
        let m = makeModel()
        m.apply(try state { json in
            self.edit("changes", "c03", ["unrequested": true])(&json)
            self.edit("changes", "c07", ["unrequested": true])(&json)
        })
        m.tab = .changes
        let list = m.changes.unrequested.map(\.id)
        XCTAssertEqual(list.count, 3)
        m.select(.change(list[0]))
        m.actions.toggleChecked(list[0])
        m.alertMessage = nil  // fixture mode: the engine is not there
        XCTAssertEqual(m.selection, .change(list[1]), "moved on")
        XCTAssertEqual(m.changes.scroller.pendingMode, .slot, "in the checked change's place")
        XCTAssertTrue(m.clickIgnored(list[1]))
        m.actions.toggleChecked(list[1])
        XCTAssertNil(m.alertMessage, "the second click checked nothing")
        XCTAssertEqual(m.selection, .change(list[1]))
        m.setFocus(true)  // in Focus the bar's Mark checked stays on its change
        spin(ClickGuard.interval + 0.05)
        m.actions.toggleChecked(list[1])
        XCTAssertEqual(m.selection, .change(list[1]))
    }

    /// Integration 2026-10-18: a card answered with the last click before Finish stayed selected in the folded Closed
    /// this round, not listed. Finishing shows its group.
    func testFinishingShowsTheSelectedCardsGroup() throws {
        let m = makeModel()
        m.select(.comment("R1-05"))
        m.apply(try state(edit("comments", "R1-05", ["verdict": "verified"])))
        XCTAssertEqual(m.panel.groups.group(of: "R1-05"), .toCheck, "held where it was while selected")
        XCTAssertFalse(m.panel.showClosed)
        m.apply(try state { json in
            self.edit("comments", "R1-05", ["verdict": "verified"])(&json)
            var r = json["round"] as? [String: Any] ?? [:]
            r["closed"] = true
            json["round"] = r
        })
        XCTAssertEqual(m.panel.groups.group(of: "R1-05"), .closed)
        XCTAssertTrue(m.panel.showClosed, "its group is shown: the selected card is listed")
        XCTAssertEqual(m.panel.expanded, "R1-05")
    }

    /// An AppKit view under SwiftUI content, as the PDF view is under the toast.
    private struct Below: NSViewRepresentable {
        let view: NSView
        func makeNSView(context: Context) -> NSView { view }
        func updateNSView(_ nsView: NSView, context: Context) {}
    }

    /// POLISH §0: Comment on it… on an edit that prints no words (no place in the PDF, or only white space under it)
    /// said nothing. It says why, and opens no editor.
    func testCommentOnAnEditWithoutWordsSaysSo() throws {
        let m = makeModel()
        m.apply(try state { json in
            self.edit("changes", "c01", ["rects": [[2.0, 2.0, 6.0, 6.0]]])(&json)  // a corner of the page: no words
            self.edit("changes", "c03", ["page": NSNull(), "rects": []])(&json)
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 900), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = ReviewPDFView(frame: NSRect(x: 0, y: 0, width: 760, height: 900))
        window.contentView = view
        m.pdf.attach(view)
        m.pdf.update(url: m.pdfURL, key: MarkKey(version: m.stateVersion, showChanges: m.showChanges))
        XCTAssertNotNil(view.document)
        m.tab = .changes
        for id in ["c01", "c03"] {
            m.reading.toast = nil
            m.commentOnChange(id)
            XCTAssertEqual(m.reading.toast, AppModel.noWordsToComment, id)
            XCTAssertEqual(m.selection, .change(id))
        }
        spin(0.4)
        XCTAssertNil(m.pdf.popover, "no editor opened")
        window.close()
    }
}

/// Closing the window goes the way quitting goes (POLISH §0): the window stays until quitting is decided.
@MainActor
final class QuitOnCloseTests: XCTestCase {
    private final class Original: NSObject, NSWindowDelegate {
        var resized = 0
        func windowDidResize(_ notification: Notification) { resized += 1 }
    }

    func testClosingAsksToQuitAndKeepsTheWindow() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled, .closable],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let original = Original()
        window.delegate = original
        var asked = 0
        QuitOnClose.install(on: window) { asked += 1 }
        QuitOnClose.install(on: window) { asked += 100 }  // once only
        XCTAssertTrue(window.delegate is QuitOnClose)
        XCTAssertEqual(window.delegate?.windowShouldClose?(window), false, "the window stays until quitting decides")
        XCTAssertEqual(asked, 1)
        // every other message goes to the window's own delegate (SwiftUI's in the app)
        let d = try XCTUnwrap(window.delegate as? NSObject)
        XCTAssertTrue(d.responds(to: #selector(NSWindowDelegate.windowDidResize(_:))))
        window.delegate?.windowDidResize?(Notification(name: NSWindow.didResizeNotification, object: window))
        XCTAssertEqual(original.resized, 1)
        XCTAssertFalse(d.responds(to: #selector(NSWindowDelegate.windowDidMiniaturize(_:))))
        window.close()
    }
}

/// POLISH §6: the buttons and fields carry no key letters (V, R, W, ↩, ⌫, ⌘↩, Esc); the keys are in the help tags and
/// menus. SwiftUI builds no accessibility tree for a view that is never on screen, so this reads the sources: no
/// `Button`, `Label` or `Text` literal names a key, and the key-letter view is gone.
final class KeyHintTests: XCTestCase {
    func testNoKeyLettersOnButtonsOrFields() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Paperole")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 10)
        let literal = try NSRegularExpression(pattern: #"\b(Text|Button|Label)\("((?:[^"\\]|\\.)*)""#)
        let key = try NSRegularExpression(pattern: #"[↩⌫⌘]|\bEsc\b|^[VRW]$"#)
        var found: [String] = []
        for f in files {
            for (n, raw) in try String(contentsOf: f, encoding: .utf8).components(separatedBy: "\n").enumerated() {
                let line = raw.components(separatedBy: "//").first ?? ""  // not the comments
                if line.contains("KeyHint(") { found.append("\(f.lastPathComponent):\(n + 1) KeyHint") }
                for m in literal.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                    guard let r = Range(m.range(at: 2), in: line) else { continue }
                    let text = String(line[r])
                    if key.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                        found.append("\(f.lastPathComponent):\(n + 1) \(text)")
                    }
                }
            }
        }
        XCTAssertEqual(found, [])
    }
}

/// A dimmed row is drawn with its text secondary, and the pointer draws it as it is (POLISH §6).
@MainActor
final class RowLookDrawingTests: XCTestCase {
    private func bitmap(_ v: NSView) -> Data {
        v.layoutSubtreeIfNeeded()
        let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
        v.cacheDisplay(in: v.bounds, to: rep)
        return rep.tiffRepresentation ?? Data()
    }

    func testADimmedRowIsDrawnQuieter() throws {
        _ = NSApplication.shared
        let card = CardModel(try makeComment(["note": "Define SPL at first use."]), round: 2, pdfs: [:], textX: [], showChanges: true)
        let look = RowLook()
        let host = NSHostingView(rootView: AnyView(CompactRow(card: card, look: look).equatable()))
        host.frame = NSRect(x: 0, y: 0, width: 380, height: 44)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let plain = bitmap(host)
        look.dimmed = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let dimmed = bitmap(host)
        XCTAssertNotEqual(plain, dimmed, "the dimmed row is drawn differently")
        look.hovering = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertNotEqual(bitmap(host), dimmed, "under the pointer it is drawn as it is (with the hover fill)")
        window.close()
    }
}
