import SwiftUI
import XCTest
@testable import Paperole

/// The Finish sheet and the Changes tab's sentence (design/ui-v2/PROPOSAL.md §3; UX.md §16, §17): each count said once.
final class FinishTests: XCTestCase {
    private func comments() throws -> [Comment] {
        try [makeComment(["id": "R1-01", "verdict": "reopened", "verdict_note": "Say which window."]),
             makeComment(["id": "R1-02", "verdict": "reopened", "verdict_note": "  "]),
             makeComment(["id": "R1-03"]),
             makeComment(["id": "R1-10", "anchor_state": "orphan"]),
             makeComment(["id": "R1-04", "verdict": "verified"]),
             makeComment(["id": "R1-05", "verdict": "wontfix", "verdict_note": "Fine."]),
             makeComment(["id": "R2-01", "carried": false, "created_round": 2])]
    }

    func testTheBatchIsStatedOnce() throws {
        let s = FinishSummary(round: 2, comments: try comments(),
                              drafts: ["R1-10": "Where did it go?", "R1-03": " Give the times.\n", "R1-04": "late", "R1-05": "  "],
                              unrequested: 2, unread: 3)
        XCTAssertEqual([s.followUps, s.followUpsWithNotes, s.new, s.toCheck, s.closed], [2, 1, 1, 2, 2])
        // only the cards to check have unsent drafts (an answered card's text was sent), by id, trimmed
        XCTAssertEqual(s.drafts, [FinishSummary.Draft(id: "R1-03", text: "Give the times.", status: .toCheck),
                                  FinishSummary.Draft(id: "R1-10", text: "Where did it go?", status: .notFound)])
        XCTAssertEqual(s.unrequested, 2)
        XCTAssertEqual(s.unread, 3)
        XCTAssertNil(FinishSummary(round: 1, comments: [], drafts: [:], unrequested: 0, unread: 9).unread)  // round 1
    }

    /// POLISH §3 row 11: the sheet reads as a hand-off, Left for you (the three to-dos, each only when some are left),
    /// then what goes to the student in final.pdf (each group only when it has some).
    func testTheSheetHandsOff() throws {
        let s = FinishSummary(round: 2, comments: try comments(), drafts: [:], unrequested: 2, unread: 12)
        func lines(_ l: [FinishSummary.Line]) -> [String] { l.map { "\($0.item.rawValue) \($0.title) | \($0.sub) | \($0.count)" } }
        XCTAssertEqual(lines(s.left), ["comments Comments still to check | They go out as “still open”. | 2",
                                       "edits Unasked edits not checked |  | 2",
                                       "paragraphs Changed paragraphs not read | Finishing marks them read. | 12"])
        XCTAssertEqual(lines(s.goes), ["followUps Follow-ups |  | 2", "new New comments |  | 1",
                                       "closed Closed |  | 2"])  // R1-02's follow-up has no note
        let one = FinishSummary(round: 2, comments: [try makeComment(["id": "R1-03"]),
                                                     try makeComment(["id": "R1-01", "verdict": "reopened", "verdict_note": "Why?"])],
                                drafts: [:], unrequested: 1, unread: 1)
        XCTAssertEqual(lines(one.left), ["comments Comment still to check | It goes out as “still open”. | 1",
                                         "edits Unasked edit not checked |  | 1",
                                         "paragraphs Changed paragraph not read | Finishing marks it read. | 1"])
        // each group only when it has some (visual review 2026-10-18: New comments 0 was listed, Follow-ups 0 not)
        XCTAssertEqual(lines(one.goes), ["followUps Follow-ups · with your notes |  | 1"])
        // none: a line of its own, drawn without New comments' + or a count (review 2026-10-24: "+ No follow-ups … 0")
        XCTAssertEqual(lines(FinishSummary(round: 2, comments: [], drafts: [:], unrequested: 0, unread: 0).goes),
                       ["nothing No follow-ups, new or closed comments |  | 0"])
        // nothing left: no Left for you; round 1 has no paragraphs to read
        let done = FinishSummary(round: 1, comments: [try makeComment(["id": "R1-01", "carried": false, "created_round": 1])],
                                 drafts: [:], unrequested: 0, unread: 4)
        XCTAssertEqual(done.left, [])
        XCTAssertEqual(lines(done.goes), ["new New comments |  | 1"])
    }

    /// Review next to Comments still to check goes to the first card still to check by its status, not to the selected
    /// card that was answered and stays listed in To check (review 2026-10-24, A3a-01).
    func testReviewSkipsAnAnsweredCardHeldInToCheck() throws {
        let cards = try [makeComment(["id": "R1-01", "verdict": "verified"]), makeComment(["id": "R1-02"]),
                         makeComment(["id": "R1-03", "anchor_state": "orphan"])]
            .map { CardModel($0, round: 2, pdfs: [:], textX: [], showChanges: true) }
        XCTAssertEqual(CardGroups(cards, held: (id: "R1-01", group: .toCheck)).toCheck.map(\.id), ["R1-01", "R1-02", "R1-03"])
        XCTAssertEqual(FinishSummary.firstToCheck(cards), "R1-02")
        XCTAssertEqual(FinishSummary.firstToCheck(Array(cards.suffix(1))), "R1-03", "Not found is still to check")
        XCTAssertNil(FinishSummary.firstToCheck(Array(cards.prefix(1))))
    }

    /// Interaction review 2026-10-18: a draft sent or discarded in the sheet keeps its row, in the drafts' order, so the
    /// next draft's buttons never slide under the pointer; one still unsent (its Send refused) shows as unsent.
    func testHandledDraftsKeepTheirRows() {
        let d = { (id: String) in FinishSummary.Draft(id: id, text: "t " + id, status: .toCheck) }
        let handled = ["R1-10": FinishSummary.Handled(draft: d("R1-10"), raw: "t R1-10 ", sent: false),
                       "R1-02": FinishSummary.Handled(draft: d("R1-02"), raw: "t R1-02", sent: true),
                       "R1-03": FinishSummary.Handled(draft: d("R1-03"), raw: "t R1-03", sent: true)]
        let rows = FinishSummary.rows([d("R1-03"), d("R1-09")], handled: handled)
        XCTAssertEqual(rows.map(\.id), ["R1-02", "R1-03", "R1-09", "R1-10"], "by id, as the drafts, R1-10 after R1-9")
        XCTAssertEqual(rows.map { $0.handled.map { $0.sent ? "sent" : "discarded" } ?? "unsent" },
                       ["sent", "unsent", "unsent", "discarded"])
    }

    /// The Changes tab says each thing once (design/review-page/BRIEF.md E2): no sentence on top; "Unasked edits" over
    /// the edits nobody asked for; the folded group's count in its capsule.
    @MainActor
    func testTheChangesTabSaysItsCountOnce() throws {
        _ = NSApplication.shared
        let panel = ChangePanel()
        panel.roundOpen = true
        panel.unrequested = [model(try makeChange(["id": "c01"])), model(try makeChange(["id": "c02"]))]
        panel.linked = try ["c03", "c04", "c05"].map { model(try makeChange(["id": $0, "unrequested": false, "attached_to": ["R1-02"]])) }
        let list = ChangeListController(panel: panel, actions: CardActions(), edit: EditState())
        XCTAssertEqual(list.rows().first, .header("Unasked edits", glyph: .toCheck(open: true)))
        XCTAssertTrue(list.rows().contains(.fold("Answering your comments", "Show", group: .linked, count: 3, glyph: .answering)))
        withExtendedLifetime(list) {}
    }
}
