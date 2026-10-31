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
                                       "edits Other edits not checked | No comment asked for them. | 2",
                                       "paragraphs Changed paragraphs not read | Finishing marks them read. | 12"])
        XCTAssertEqual(lines(s.goes), ["followUps Follow-ups |  | 2", "new New comments |  | 1",
                                       "closed Closed |  | 2"])  // R1-02's follow-up has no note
        let one = FinishSummary(round: 2, comments: [try makeComment(["id": "R1-03"]),
                                                     try makeComment(["id": "R1-01", "verdict": "reopened", "verdict_note": "Why?"])],
                                drafts: [:], unrequested: 1, unread: 1)
        XCTAssertEqual(lines(one.left), ["comments Comment still to check | It goes out as “still open”. | 1",
                                         "edits Other edit not checked | No comment asked for it. | 1",
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

    func testTheChangesTabSaysItsCountOnce() throws {
        func state(_ changes: [[String: Any]], closed: Bool = false, round: Int = 3) throws -> EngineState {
            let base: [String: Any] = [
                "schema": 1, "paper": ["path": "/p", "title": "T", "student": "S"], "rounds": [], "comments": [],
                "round": ["n": round, "closed": closed, "build": ["status": "ok", "warnings": [], "errors": []]],
                "changes": try changes.map { try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: $0)) }]
            return try EngineState.decode(JSONSerialization.data(withJSONObject: base))
        }
        func change(_ id: String, attached: [String] = []) -> [String: Any] {
            ["id": id, "kind": "replace", "old_text": "a", "new_text": "b", "page": 0, "rects": [],
             "attached_to": attached, "unrequested": attached.isEmpty]
        }
        let mixed = try state([change("c01"), change("c02"), change("c03", attached: ["R1-02"]),
                               change("c04", attached: ["R1-09"]), change("c05", attached: ["R2-01"])])
        // the number is the tab's (POLISH §3 row 10, §4.4): the sentence says only that some are left
        XCTAssertEqual(ChangesHeader.text(mixed, left: 2).map { String($0.characters) },
                       "Other edits to check. No comment asked for them. 3 more edits answer your comments.")
        XCTAssertEqual(ChangesHeader.text(mixed, left: 1).map { String($0.characters) },
                       "An edit to check. No comment asked for it. 3 more edits answer your comments.")
        XCTAssertEqual(ChangesHeader.text(mixed, left: 0).map { String($0.characters) },
                       "All checked. The 2 edits no comment asked for are checked, commented on or read. 3 more edits answer your comments.")
        XCTAssertEqual(ChangesHeader.text(try state([change("c03", attached: ["R1-02"])]), left: 0).map { String($0.characters) },
                       "Nothing to check. Every edit since R2 answers one of your comments.")
        XCTAssertEqual(ChangesHeader.text(try state([change("c01"), change("c03", attached: ["R1-02"])], closed: true), left: 0)
                        .map { String($0.characters) },
                       "Edits made since R2: 1 no comment asked for, 1 answering your comments.")
        XCTAssertNil(ChangesHeader.text(try state([], round: 3), left: 0))  // the list says the source did not change
        XCTAssertNil(ChangesHeader.text(try state([change("c01")], round: 1), left: 1))
        // its first words in the label colour, Semibold (POLISH §3 row 10: vermilion only where the count is, on the tab)
        let lead = try XCTUnwrap(ChangesHeader.text(mixed, left: 2))
        XCTAssertEqual(lead.runs.first?.foregroundColor, Ink.label)
        XCTAssertEqual(lead.runs.first.map { String(lead[$0.range].characters) }, "Other edits to check.")
    }
}
