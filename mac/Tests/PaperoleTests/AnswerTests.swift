import AppKit
import SwiftUI
import XCTest
@testable import Paperole

/// Resolve / Follow up / Keep as is (UX.md §8, design/ui-v2/PROPOSAL.md §1.4): what V, R, W and the buttons do, the
/// choice row, undo, the drafts file, and the follow-up field's focus.
final class VerdictPlanTests: XCTestCase {
    private func press(_ v: String, _ current: String? = nil, note: String = "", draft: String = "", button: Bool = false) -> VerdictPlan {
        VerdictPlan.press(v, current: current, note: note, draft: draft, button: button)
    }

    func testToCheckWithoutText() {
        XCTAssertEqual(press("verified"), .send(Answer(verdict: "verified"), focus: false))
        XCTAssertEqual(press("wontfix"), .send(Answer(verdict: "wontfix"), focus: false))
        XCTAssertEqual(press("reopened"), .focusField)  // R puts the cursor in the field; it sends nothing
        XCTAssertEqual(press("reopened", button: true), .focusField)  // so does Follow up with the field empty
        XCTAssertEqual(VerdictPlan.sendDraft(""), .send(Answer(verdict: "reopened"), focus: false))  // ⌘↩, no note
    }

    /// A bare V or W never turns text into a closing remark: the choice row asks.
    func testBareKeyOnTextAsks() {
        XCTAssertEqual(press("verified", draft: "Say which stage."), .ask(verdict: "verified", text: "Say which stage.", sent: false))
        XCTAssertEqual(press("wontfix", draft: "x"), .ask(verdict: "wontfix", text: "x", sent: false))
        // a follow-up sent this round
        XCTAssertEqual(press("verified", "reopened", note: "Still vague."), .ask(verdict: "verified", text: "Still vague.", sent: true))
        // a follow-up without a note closes at once
        XCTAssertEqual(press("wontfix", "reopened"), .send(Answer(verdict: "wontfix"), focus: false))
        // a click on Resolve on a follow-up card asks too: its label does not say "+ note"
        XCTAssertEqual(press("verified", "reopened", note: "n", button: true), .ask(verdict: "verified", text: "n", sent: true))
    }

    /// "Resolve + note", "Keep as is + note" and Follow up act at once with the field's text.
    func testButtonsWithText() {
        XCTAssertEqual(press("verified", draft: "Reads well.", button: true), .send(Answer(verdict: "verified", note: "Reads well."), focus: false))
        XCTAssertEqual(press("wontfix", draft: "Fine.", button: true), .send(Answer(verdict: "wontfix", note: "Fine."), focus: false))
        XCTAssertEqual(press("reopened", draft: "More.", button: true), .send(Answer(verdict: "reopened", note: "More."), focus: false))
        XCTAssertEqual(VerdictPlan.sendDraft("More."), .send(Answer(verdict: "reopened", note: "More."), focus: false))
    }

    /// The same key again clears without a dialog; the note returns to the field as an unsent draft.
    func testSameKeyClears() {
        XCTAssertEqual(press("verified", "verified", note: "Reads well."), .send(Answer(verdict: nil, draft: "Reads well."), focus: false))
        XCTAssertEqual(press("wontfix", "wontfix"), .send(Answer(verdict: nil), focus: false))
        XCTAssertEqual(press("reopened", "reopened", note: "Still vague."), .send(Answer(verdict: nil, draft: "Still vague."), focus: true))
        XCTAssertEqual(press("verified", "verified", note: "n", button: true), .send(Answer(verdict: nil, draft: "n"), focus: false))
    }

    /// Resolved and Kept as is switch keeping the remark; R on either clears and puts the remark in the field.
    func testClosedCards() {
        XCTAssertEqual(press("wontfix", "verified", note: "ok"), .send(Answer(verdict: "wontfix", note: "ok"), focus: false))
        XCTAssertEqual(press("verified", "wontfix", note: "ok"), .send(Answer(verdict: "verified", note: "ok"), focus: false))
        XCTAssertEqual(press("reopened", "verified", note: "ok"), .send(Answer(verdict: nil, draft: "ok"), focus: true))
        XCTAssertEqual(press("reopened", "wontfix"), .send(Answer(verdict: nil), focus: true))
    }

    func testChoiceRow() {
        XCTAssertEqual(VerdictPlan.choose(.withText, verdict: "verified", text: "t", sent: false),
                       .send(Answer(verdict: "verified", note: "t"), focus: false))
        XCTAssertEqual(VerdictPlan.choose(.withoutText, verdict: "wontfix", text: "t", sent: false),
                       .send(Answer(verdict: "wontfix"), focus: false))  // the draft goes; ⌘Z brings it back
        XCTAssertNil(VerdictPlan.choose(.cancel, verdict: "verified", text: "t", sent: false))
        XCTAssertEqual(VerdictPlan.choose(.followUp, verdict: "verified", text: "t", sent: false),
                       .send(Answer(verdict: "reopened", note: "t"), focus: false))
        XCTAssertNil(VerdictPlan.choose(.followUp, verdict: "verified", text: "t", sent: true))  // already a follow-up
        XCTAssertEqual(VerdictPlan.choose(.withText, verdict: "verified", text: "t", sent: true),
                       .send(Answer(verdict: "verified", note: "t"), focus: false))
    }
}

final class AnswerHistoryTests: XCTestCase {
    let sent = AnswerStep(id: "R1-02", before: Answer(verdict: nil, draft: "More."), after: Answer(verdict: "reopened", note: "More."))
    let resolved = AnswerStep(id: "R1-04", before: Answer(), after: Answer(verdict: "verified"))

    func testUndoRedo() {
        var h = AnswerHistory()
        h.record(sent)
        h.record(resolved)
        XCTAssertEqual(h.undo(), .answer(resolved))
        XCTAssertEqual(h.undo(), .answer(sent))  // its `before` brings the unsent draft back
        XCTAssertNil(h.undo())
        XCTAssertEqual(h.redo(), .answer(sent))
        XCTAssertEqual(h.undos, [.answer(sent)])
        XCTAssertEqual(h.redos, [.answer(resolved)])
        h.record(AnswerStep(id: "R1-07", before: Answer(), after: Answer(verdict: "wontfix")))
        XCTAssertEqual(h.redos, [])  // a new answer drops the redo stack
        XCTAssertNil(h.redo())
    }

    func testRefusedStepsGoBack() {
        var h = AnswerHistory()
        h.record(sent)
        _ = h.undo()
        h.undoFailed()
        XCTAssertEqual(h.undos, [.answer(sent)])
        XCTAssertEqual(h.redos, [])
        _ = h.undo()
        _ = h.redo()
        h.redoFailed()
        XCTAssertEqual(h.undos, [])
        XCTAssertEqual(h.redos, [.answer(sent)])
    }

    func testNothingChangedIsNotRecorded() {
        var h = AnswerHistory()
        h.record(AnswerStep(id: "R1-02", before: Answer(verdict: "verified"), after: Answer(verdict: "verified")))
        XCTAssertEqual(h.undos, [])
    }

    /// Interaction review: text typed in a field after an undo was replaced by redo (and undo) with a step's draft.
    /// Typing drops that card's steps; the other cards' stay.
    func testTypingForgetsTheCardsSteps() {
        var h = AnswerHistory()
        h.record(sent)
        h.record(resolved)
        _ = h.undo()
        _ = h.undo()
        h.record(AnswerStep(id: "R1-07", before: Answer(), after: Answer(verdict: "wontfix")))
        _ = h.undo()
        XCTAssertEqual(h.redos.map(\.id), ["R1-07"])
        h.forget("R1-02")
        h.forget("R1-07")
        XCTAssertEqual(h.undos, [])
        XCTAssertEqual(h.redos, [])
        var other = AnswerHistory()
        other.record(sent)
        other.record(resolved)
        other.forget("R1-02")
        XCTAssertEqual(other.undos, [.answer(resolved)])
    }
}

final class DraftStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-drafts-test-" + UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testSaveLoadAndDelete() throws {
        let store = DraftStore(directory: dir)
        let paper = "/tmp/a paper/review"
        XCTAssertEqual(store.load(paper: paper, round: 3), [:])
        store.save(paper: paper, round: 3, drafts: ["R1-02": "Say which stage.", "R1-05": ""])
        store.save(paper: paper, round: 2, drafts: ["R1-01": "old round"])
        XCTAssertEqual(store.load(paper: paper, round: 3), ["R1-02": "Say which stage."])  // empty texts are dropped
        XCTAssertEqual(DraftStore(directory: dir).load(paper: paper, round: 2), ["R1-01": "old round"])  // a new launch
        XCTAssertEqual(store.load(paper: "/tmp/other", round: 3), [:])
        XCTAssertEqual(store.all().map(\.id), ["R1-01", "R1-02"])
        XCTAssertEqual(store.all().first?.paper, paper)
        // sent or discarded: deleted; a paper without drafts has no file
        store.save(paper: paper, round: 3, drafts: [:])
        XCTAssertEqual(store.load(paper: paper, round: 3), [:])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(paper: paper).path))
        store.save(paper: paper, round: 2, drafts: [:])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(paper: paper).path))
        XCTAssertEqual(store.all().count, 0)
    }

    /// Once a later round is open, an earlier round's drafts can no longer be sent: they go.
    func testKeepOnlyTheOpenRound() {
        let store = DraftStore(directory: dir)
        store.save(paper: "/p", round: 2, drafts: ["R1-01": "left from round 2"])
        store.keepOnly(paper: "/p", round: 3)
        XCTAssertEqual(store.all().count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(paper: "/p").path))
        store.save(paper: "/p", round: 3, drafts: ["R1-01": "now"])
        store.keepOnly(paper: "/p", round: 3)
        XCTAssertEqual(store.load(paper: "/p", round: 3), ["R1-01": "now"])
    }

    func testFilesPerPaper() {
        let store = DraftStore(directory: dir)
        XCTAssertNotEqual(store.url(paper: "/a"), store.url(paper: "/b"))
        XCTAssertEqual(store.url(paper: "/a"), DraftStore(directory: dir).url(paper: "/a"))
        XCTAssertEqual(store.url(paper: "/a").deletingLastPathComponent().path, dir.path)
        // the dev app's folder: swift test is never the official app (AppVariant)
        XCTAssertTrue(DraftStore.standard.path.hasSuffix("Application Support/Paperole Dev/drafts"))
    }

    /// A test run keeps its drafts out of the user's Application Support.
    func testLaunchOption() {
        XCTAssertEqual(LaunchOptions.parse(["app", "--background", "--drafts", "/tmp/d"]).drafts, "/tmp/d")
        XCTAssertNil(LaunchOptions.parse(["app", "--background"]).drafts)
    }
}

final class AnswerKeyTests: XCTestCase {
    private func state(_ f: (inout KeyState) -> Void) -> KeyState {
        var s = KeyState()
        s.roundOpen = true
        f(&s)
        return s
    }

    func testChoiceRowKeys() {
        let s = state { $0.card = .carried(answered: false); $0.choice = true; $0.draft = true }
        XCTAssertEqual(KeyRoute.action("return", s), .choose(.withText))
        XCTAssertEqual(KeyRoute.action("delete", s), .choose(.withoutText))
        XCTAssertEqual(KeyRoute.action("esc", s), .choose(.cancel))
        XCTAssertEqual(KeyRoute.action("cmd-return", s), .choose(.followUp))
        XCTAssertEqual(KeyRoute.action("j", s), .next)  // leaves the card, and the row
        for k in ["v", "w", "r", "1", "cmd-z", "n"] { XCTAssertNil(KeyRoute.action(k, s), k) }
    }

    /// Interaction review: the choice row's keys never act in a round that is not open (an earlier round shown), and a
    /// PDF selection, a pending box or re-anchoring keeps Return and Esc.
    func testOtherKeysComeBeforeTheChoiceRow() {
        func choice(_ f: (inout KeyState) -> Void) -> KeyState {
            state { $0.card = .carried(answered: false); $0.choice = true; $0.draft = true; f(&$0) }
        }
        let earlier = choice { $0.roundOpen = false }
        for k in ["return", "delete", "esc", "cmd-return", "v"] { XCTAssertNil(KeyRoute.action(k, earlier), k) }
        XCTAssertEqual(KeyRoute.action("j", earlier), .next)
        XCTAssertEqual(KeyRoute.action("return", choice { $0.reanchoring = true }), .place)
        XCTAssertEqual(KeyRoute.action("esc", choice { $0.reanchoring = true }), .leaveReanchor)
        XCTAssertEqual(KeyRoute.action("return", choice { $0.textSelection = true }), .openEditor)
        XCTAssertEqual(KeyRoute.action("esc", choice { $0.textSelection = true }), .clearSelection)
        XCTAssertEqual(KeyRoute.action("return", choice { $0.pendingBox = true }), .openEditor)
    }

    /// Interaction review: a click on a card's selectable text (its note, paper text, a bubble) made that text the first
    /// responder, and the keys stopped working. Only an editor that has the cursor keeps them.
    @MainActor func testSelectableTextDoesNotHoldTheKeys() {
        let shown = NSTextView()
        shown.isEditable = false
        shown.isSelectable = true
        XCTAssertTrue(AppModel.routesKeys(firstResponder: shown))
        XCTAssertFalse(AppModel.routesKeys(firstResponder: NSTextView()), "an editor keeps them")
        XCTAssertTrue(AppModel.routesKeys(firstResponder: nil))
        XCTAssertTrue(AppModel.routesKeys(firstResponder: NSView()))
    }

    func testSendDraftAndUndoKeys() {
        let toCheck = state { $0.card = .carried(answered: false) }
        XCTAssertNil(KeyRoute.action("cmd-return", toCheck))  // nothing to send
        XCTAssertEqual(KeyRoute.action("cmd-return", state { $0.card = .carried(answered: false); $0.draft = true }), .sendDraft)
        XCTAssertNil(KeyRoute.action("cmd-return", state { $0.card = .carried(answered: true); $0.draft = true }))
        XCTAssertEqual(KeyRoute.action("cmd-z", toCheck), .undo)
        XCTAssertEqual(KeyRoute.action("cmd-shift-z", state { _ in }), .redo)
        XCTAssertNil(KeyRoute.action("cmd-z", state { $0.reanchoring = true }))
        XCTAssertNil(KeyRoute.action("cmd-n", toCheck))  // menu shortcuts pass through
    }

    @MainActor func testKeyNames() {
        func name(_ chars: String, _ code: UInt16, _ mods: NSEvent.ModifierFlags = []) -> String? {
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0,
                                     context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                     isARepeat: false, keyCode: code)!
            return AppModel.keyName(e)
        }
        XCTAssertEqual(name("v", 9), "v")
        XCTAssertEqual(name("\r", 36), "return")
        XCTAssertEqual(name("\r", 36, .command), "cmd-return")
        XCTAssertEqual(name("z", 6, .command), "cmd-z")
        XCTAssertEqual(name("Z", 6, [.command, .shift]), "cmd-shift-z")
        XCTAssertEqual(name("C", 8, .shift), "shift-c")
        XCTAssertEqual(name("\u{7f}", 51), "delete")
        XCTAssertNil(name("v", 9, .option))
    }
}

/// The follow-up field is always on a card to check, but selecting the card never puts the cursor in it: V, R, W, J
/// and K stay single keys. Only a request (R, Return) or a click does.
@MainActor
final class FieldFocusTests: XCTestCase {
    private func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    func testSelectionNeverTakesFocusAndARequestDoes() throws {
        _ = NSApplication.shared
        let card = CardModel(try makeComment([:]), round: 2, pdfs: [:], textX: [], showChanges: true)
        let edit = EditState()
        edit.roundOpen = true
        edit.round = 2
        let host = NSHostingView(rootView: ExpandedCard(card: card, actions: CardActions()).environmentObject(edit))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 700)
        // never ordered in: nothing appears on the screen
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        spin(0.4)
        func field(_ v: NSView) -> NSTextView? {
            (v as? NSTextView) ?? v.subviews.lazy.compactMap(field).first
        }
        let tv = try XCTUnwrap(field(host), "a card to check has its follow-up field")
        XCTAssertFalse(window.firstResponder === tv, "the field took focus without being asked")
        edit.draft = "Still vague."  // an unsent draft on the card does not take it either
        spin(0.3)
        XCTAssertFalse(window.firstResponder is NSTextView)
        edit.focusRequest = card.id  // R or Return
        spin(0.4)
        XCTAssertTrue(window.firstResponder === field(host), "R or Return puts the cursor in the field")
        window.close()
    }
}
