import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import Paperole

/// A student's note as the engine writes it (CONTRACT amendment "Student notes"): its lines, by default one in main.tex.
func studentNote(_ text: String, changes: [String] = [], elsewhere: [String] = [], file: String = "main.tex",
                 lines: [Int] = [56]) -> [String: Any] {
    ["text": text, "file": file, "line": lines.first ?? NSNull(), "changes": changes, "elsewhere": elsewhere,
     "lines": lines.map { ["file": file, "line": $0, "changes": changes] }]
}

/// The card's conversation in turns (design/ui-v2.2 CARD.md §3, option C; UX.md §3): `CardContent.turns` over the
/// thread's sections, which keep deciding what is a revision. Every row of CARD §3.2 and §3.4, the fold (§3.8), and the
/// cases of the mockup. Synthetic data only.
final class CardTurnsTests: XCTestCase {
    /// The turns of a comment in round `n` (the defaults of `makeComment`: a carried highlight on p.1).
    private func turns(_ extra: [String: Any], round n: Int = 2, student: String = "Lin Mei", figures: [String: String] = [:],
                       emailed: [Int: String] = [:]) throws -> [Turn] {
        var e: [String: Any] = ["page": 0]
        for (k, v) in extra { e[k] = v }
        let c = try makeComment(e)
        let sections = CardContent.thread(c, round: n, figures: figures)
        return CardContent.turns(c, sections: sections, round: n, student: student, emailed: emailed)
    }

    private let start = hist(1, "new", "We use a simple policy.", sel: [[9, 22]])
    private func now(_ text: String = "We use a static policy.") -> [String: Any] { ctx(text, sel: [[9, 22]], page: 0) }

    // MARK: The mockup's cases (CARD §3.10)

    /// R1-19: a figure, two rounds with nothing, your follow-up, then a new image file with a note: in the order it
    /// happened, the note in the image's turn with its place in the footer.
    func testAFigureWithAFollowUp() throws {
        let image = { (r: Int, s: String, v: String?, n: String) in hist(r, s, "", display: "image", verdict: v, note: n) }
        let t = try turns(["kind": "box", "history": [image(1, "new", nil, ""), image(2, "unchanged", nil, ""),
                                                       image(3, "unchanged", "reopened", "图 3 还是 events/min。")],
                           "context": ctx("", display: "image", page: 0), "changes": ["c01"],
                           "student_note": studentNote("Re-plotted fig3_rate.pdf: the y-axis now reads \"snaps/s\".",
                                                       changes: ["c01"], file: "figs/fig3/rate_by_hour_panels.tex", lines: [12])],
                          round: 4, student: "Ouyang Mingxuan", figures: ["c01": "fig3_rate.pdf"], emailed: [3: "Oct 17"])
        XCTAssertEqual(t.map(\.label), ["R1 · you commented on", "R2–R3 · unchanged", "R3 · you followed up",
                                        "R4 · Ouyang Mingxuan replaced the image · 1 edit"])
        XCTAssertEqual(t.map(\.dot), [.you, .small, .you, .change])
        XCTAssertEqual(t[2].date, "sent Oct 17")
        XCTAssertEqual(t[2].words?.text, "图 3 还是 events/min。")
        XCTAssertEqual(t[3].words?.text, "Re-plotted fig3_rate.pdf: the y-axis now reads \"snaps/s\".", "as written, no quotes added")
        XCTAssertEqual(t[3].words?.place, Turn.Place(short: "rate_by_hour_panels.tex:12",
                                                     full: "figs/fig3/rate_by_hour_panels.tex:12"))
        XCTAssertEqual(t[3].section, "r4", "the evidence: this round's crop")
        XCTAssertEqual(t[3].reveal, "c01", "the shown round's count is a link")
        XCTAssertEqual(t[0].section, "r1")
        XCTAssertNil(CardContent.fold(t))
    }

    /// R1-21 / R3-02: "kept as is", no edit: one turn, "answered · no edit", a hollow dot; nothing green.
    func testAKeptAsIsNote() throws {
        let t = try turns(["kind": "box", "anchor_state": "unchanged",
                           "history": [start, hist(2, "unchanged", "We use a simple policy.", sel: [[9, 22]]),
                                       hist(3, "unchanged", "We use a simple policy.", sel: [[9, 22]])],
                           "context": now("We use a simple policy."),
                           "student_note": studentNote("保持原样：式 (2) 里已经写成 log₂，所以 H 的单位就是 bit。",
                                                       file: "sections/02_methods_detection.tex", lines: [61])], round: 4)
        XCTAssertEqual(t.map(\.label), ["R1 · you commented on", "R2–R3 · unchanged", "R4 · Lin Mei answered · no edit"])
        XCTAssertEqual(t.last?.dot, .hollow)
        XCTAssertNil(t.last?.section, "the text did not change: no evidence")
        XCTAssertNil(t.last?.reveal)
        XCTAssertEqual(t.last?.words?.place?.short, "02_methods_detection.tex:61")
        XCTAssertNil(t.last?.words?.clamp, "the shown round's words are never cut")
    }

    /// R2-08: revised with a note: the words, then this round's text.
    func testRevisedWithANote() throws {
        let t = try turns(["history": [hist(2, "new", "We use a simple policy.", sel: [[9, 22]]),
                                       hist(3, "unchanged", "We use a simple policy.", sel: [[9, 22]])],
                           "context": now(), "changes": ["c02"],
                           "student_note": studentNote("softened it to \"static\".", changes: ["c02"])], round: 4)
        XCTAssertEqual(t.map(\.label), ["R2 · you commented on", "R3 · unchanged", "R4 · Lin Mei revised · 1 edit"])
        XCTAssertEqual(t[2].section, "r4")
        XCTAssertEqual(t[2].words?.place?.short, "main.tex:56")
        XCTAssertEqual(t[2].dot, .change)
    }

    /// R2-06: a note that linked an edit elsewhere and no change here: "edited elsewhere · 1 edit", a green dot, no
    /// text of its own, the edit as an attachment in the shown round; the row says "edit on p.7".
    func testANoteWithAnEditElsewhere() throws {
        let extra: [String: Any] = ["anchor_state": "unchanged", "page": 0,
                                    "history": [hist(2, "new", "We use a simple policy.", sel: [[9, 22]]),
                                                hist(3, "unchanged", "We use a simple policy.", sel: [[9, 22]])],
                                    "context": now("We use a simple policy."), "changes": ["c05"],
                                    "student_note": studentNote("I put the summary at the end of Q3 instead.",
                                                                changes: ["c05"], elsewhere: ["c05"],
                                                                file: "sections/05_results.tex", lines: [61])]
        let t = try turns(extra, round: 4)
        XCTAssertEqual(t.map(\.label), ["R2 · you commented on", "R3 · unchanged", "R4 · Lin Mei edited elsewhere · 1 edit"])
        XCTAssertEqual(t[2].dot, .change, "the paper did change")
        XCTAssertNil(t[2].section, "the commented sentence did not change")
        XCTAssertEqual(t[2].elsewhere, ["c05"])
        XCTAssertEqual(t[2].reveal, "c05")
        let ch = ChangeModel(try makeChange(["id": "c05", "kind": "insert", "attached_to": ["R1-01"], "unrequested": false,
                                             "page": 6, "section": "Q3: Does the Sampling Temperature Matter?"]),
                             round: 4, pdfs: [:], textX: [], statuses: ["R1-01": .toCheck])
        let m = CardModel(try makeComment(extra), round: 4, pdfs: [:], textX: [], showChanges: true, changes: ["c05": ch])
        XCTAssertEqual(m.attachments.map(\.id), ["c05"])
        XCTAssertEqual(m.stateWord, "edit on p.7", "not \"unchanged\"")
        XCTAssertEqual(ch.shown?.id, "now", "the attachment shows the shown round's block")
        // an earlier round's edit elsewhere: no attachment (its context is not in the state), its page in the label
        var earlier = hist(2, "unchanged", "We use a simple policy.", sel: [[9, 22]], changes: ["c09"])
        earlier["student_note"] = studentNote("explained it in the intro", changes: ["c09"], elsewhere: ["c09"])
        earlier["change_pages"] = ["c09": 5]
        let past = try turns(["anchor_state": "unchanged", "history": [start, earlier], "context": now("We use a simple policy.")],
                             round: 3)
        XCTAssertEqual(past.map(\.label), ["R1 · you commented on", "R2 · Lin Mei edited elsewhere · 1 edit on p.6",
                                           "R3 · unchanged"])
        XCTAssertEqual(past[1].elsewhere, [])
        XCTAssertNil(past[1].reveal, "an earlier round's count is no link")
    }

    /// The commented text changed and the note linked another edit too: "revised · 2 edits", the other in the attachment.
    func testRevisedWithAnEditElsewhereToo() throws {
        let t = try turns(["history": [start], "context": now(), "changes": ["c02", "c05"],
                           "student_note": studentNote("renamed it, and said why in §2", changes: ["c02", "c05"],
                                                       elsewhere: ["c05"])])
        XCTAssertEqual(t.last?.label, "R2 · Lin Mei revised · 2 edits")
        XCTAssertEqual(t.last?.reveal, "c02", "the link shows the edit here first")
        XCTAssertEqual(t.last?.elsewhere, ["c05"])
        XCTAssertEqual(t.last?.section, "r2")
    }

    // MARK: Quiet lines (CARD §3.2)

    /// Earlier rounds with nothing merge into one line; this round's is a line of its own, said against the turn above.
    func testQuietLines() throws {
        let since = { (history: [[String: Any]], n: Int) in
            try self.turns(["anchor_state": "unchanged", "history": history, "context": self.now("We use a simple policy.")],
                           round: n)
        }
        let same = { (r: Int, s: String, v: String?) in hist(r, s, "We use a simple policy.", sel: [[9, 22]], verdict: v, note: "x") }
        XCTAssertEqual(try since([start], 2).map(\.label), ["R1 · you commented on", "R2 · unchanged since you commented"])
        XCTAssertEqual(try since([start, same(2, "unchanged", "reopened")], 3).map(\.label),
                       ["R1 · you commented on", "R2 · unchanged", "R2 · you followed up", "R3 · unchanged since your follow-up"])
        let still = try since([start, same(2, "unchanged", nil)], 3)
        XCTAssertEqual(still.map(\.label), ["R1 · you commented on", "R2 · unchanged", "R3 · still unchanged"])
        XCTAssertEqual(still.map(\.dot), [.you, .small, .hollow])
        XCTAssertEqual(still.map(\.now), [false, false, true])
        XCTAssertEqual(try since([start, hist(2, "changed", "We use a simpler policy.", sel: [[9, 24]])], 3).map(\.label),
                       ["R1 · you commented on", "R2 · Lin Mei revised", "R3 · unchanged"])
        let merged = try turns(["history": [start] + (2...4).map { same($0, "unchanged", nil) }, "context": now()], round: 5)
        XCTAssertEqual(merged.map(\.label), ["R1 · you commented on", "R2–R4 · unchanged", "R5 · Lin Mei revised"])
        XCTAssertEqual(merged[1].accessibility, "Rounds 2 to 4, unchanged")
        // a follow-up between them splits the line; this round never merges
        let split = try since([start, same(2, "unchanged", nil), same(3, "unchanged", "reopened"), same(4, "unchanged", nil)], 5)
        XCTAssertEqual(split.map(\.label), ["R1 · you commented on", "R2–R3 · unchanged", "R3 · you followed up",
                                            "R4 · unchanged", "R5 · still unchanged"])
    }

    /// Only moved: a quiet line, the page only when it is not the card's; moved with edits: the student's turn, its
    /// page only when not the card's, so the shown round never names one.
    func testMoved() throws {
        let moved = try turns(["anchor_state": "unchanged", "history": [start, hist(2, "moved", "We use a simple policy.",
                                                                                  sel: [[9, 22]], page: 5),
                                                                        hist(3, "moved", "We use a simple policy.", sel: [[9, 22]])],
                               "context": now("We use a simple policy.")], round: 4)
        XCTAssertEqual(moved.map(\.label), ["R1 · you commented on", "R2 · moved to p.6", "R3 · moved", "R4 · unchanged"],
                       "not \"still unchanged\": it had moved")
        let revised = try turns(["anchor_state": "moved", "changes": ["c03"],
                                 "history": [start, hist(2, "moved", "We use a simpler policy.", sel: [[9, 24]], page: 5,
                                                         changes: ["c01"])],
                                 "context": now()], round: 3)
        XCTAssertEqual(revised.map(\.label), ["R1 · you commented on", "R2 · Lin Mei moved and revised it · p.6 · 1 edit",
                                              "R3 · Lin Mei moved and revised it · 1 edit"])
        // the row says what happened to the paper: "revised" (it said "moved", as for a move with nothing attached)
        let m = CardModel(try makeComment(["page": 0, "anchor_state": "moved", "changes": ["c03"],
                                           "history": [start, hist(2, "moved", "We use a simpler policy.", sel: [[9, 24]], page: 5,
                                                                   changes: ["c01"])], "context": now()]),
                          round: 3, pdfs: [:], textX: [], showChanges: true)
        XCTAssertEqual(m.stateWord, "revised")
        let onlyMovedNow = try turns(["anchor_state": "moved", "history": [start], "context": now("We use a simple policy.")])
        XCTAssertEqual(onlyMovedNow.map(\.label), ["R1 · you commented on", "R2 · moved"])
        XCTAssertEqual(onlyMovedNow.last?.dot, .hollow)
    }

    /// Only moved, the move attached (behaviour review 2026-10-19): "moved it", a
    /// hollow dot and no count, as the Changes tab's "Moved"; the row says "moved". With a word changed it stays "moved
    /// and revised it".
    func testOnlyMovedWithTheMoveAttached() throws {
        // the shown round: its one attached change is no edit of words (not in `edits`), and no word differs
        let shown = try makeComment(["page": 0, "anchor_state": "moved", "changes": ["c06"],
                                     "history": [hist(1, "new", "We use a simple policy.", sel: [[9, 22]], page: 3)],
                                     "context": now("We use a simple policy.")])
        let sections = CardContent.thread(shown, round: 2)
        XCTAssertEqual(sections.last?.onlyMoved, true)
        let t = CardContent.turns(shown, sections: sections, round: 2, student: "Lin Mei")
        XCTAssertEqual(t.map(\.label), ["R1 · you commented on p.4", "R2 · Lin Mei moved it"])
        XCTAssertEqual(t.last?.dot, .hollow)
        XCTAssertNil(t.last?.reveal)
        XCTAssertEqual(t.last?.section, "r2", "its text where it is now")
        XCTAssertEqual(CardModel(shown, round: 2, pdfs: [:], textX: [], showChanges: true).stateWord, "moved to p.1",
                       "not \"revised\"")
        // the same with an edit of words attached
        let edit = try XCTUnwrap(try makeComment(["context": ctx("We use a simple policy now.", sel: [[23, 26]], page: 0)]).context)
        let real = CardContent.thread(shown, round: 2, edits: ["c06": edit])
        XCTAssertEqual(real.last?.onlyMoved, false)
        XCTAssertEqual(CardContent.turns(shown, sections: real, round: 2, student: "Lin Mei").last?.label,
                       "R2 · Lin Mei moved and revised it · 1 edit")
        // an earlier round: no word differs from the text above
        let earlier: [String: Any] = ["anchor_state": "unchanged", "context": now("We use a simple policy."),
                                      "history": [start, hist(2, "moved", "We use a simple policy.", sel: [[9, 22]], page: 5,
                                                              changes: ["c06"])]]
        let past = try turns(earlier, round: 3)
        XCTAssertEqual(past.map(\.label), ["R1 · you commented on", "R2 · Lin Mei moved it · p.6", "R3 · unchanged"])
        XCTAssertEqual(past[1].dot, .hollow)
        var e = earlier
        e["page"] = 0
        XCTAssertEqual(CardModel(try makeComment(e), round: 3, pdfs: [:], textX: [], showChanges: true).stateWord,
                       "moved in R2")
    }

    /// The shown round's quiet line after an earlier "moved" is "unchanged", not "still unchanged"; after "you marked",
    /// "unchanged since you marked it" (behaviour review 2026-10-19).
    func testTheShownRoundsQuietLineAfterAMoveOrAMark() throws {
        let afterMove = try turns(["anchor_state": "unchanged", "context": now("We use a simple policy."),
                                   "history": [start, hist(2, "moved", "We use a simple policy.", sel: [[9, 22]])]], round: 3)
        XCTAssertEqual(afterMove.map(\.label), ["R1 · you commented on", "R2 · moved", "R3 · unchanged"])
        let marked = try turns(["note": "", "anchor_state": "unchanged", "history": [start], "context": now("We use a simple policy.")])
        XCTAssertEqual(marked.map(\.label), ["R1 · you marked", "R2 · unchanged since you marked it"])
    }

    /// A deletion is the edit: "deleted it" has no count, though the engine attaches the deletion (CARD §3.3, visual
    /// review 2026-10-19); an edit its note linked elsewhere is still counted.
    func testADeletionIsNotCounted() throws {
        let gone = ctx("Each unit was calibrated.", cut: 25, page: 0)
        let t = try turns(["anchor_state": "gone", "changes": ["c04"], "history": [start], "context": gone])
        XCTAssertEqual(t.last?.label, "R2 · Lin Mei deleted it")
        XCTAssertEqual(t.last?.dot, .change)
        XCTAssertNil(t.last?.reveal)
        let noted = try turns(["anchor_state": "gone", "changes": ["c04", "c05"], "history": [start], "context": gone,
                               "student_note": studentNote("said it in §2 instead", changes: ["c05"], elsewhere: ["c05"])])
        XCTAssertEqual(noted.last?.label, "R2 · Lin Mei deleted it · 1 edit")
        XCTAssertEqual(noted.last?.reveal, "c05")
    }

    /// Where the engine takes the turn (not found), or the round is a quiet one, an edit attached with the student's
    /// note is counted: "revised · 1 edit", not "answered · no edit" (behaviour review 2026-10-19).
    func testAnEditWhereTheEngineTookTheTurn() throws {
        let lost = try turns(["anchor_state": "orphan", "changes": ["c02"], "history": [start], "context": NSNull(),
                              "student_note": studentNote("rewrote the sentence", changes: ["c02"])])
        XCTAssertEqual(lost.map(\.label), ["R1 · you commented on", "R2 · text not found", "R2 · Lin Mei revised · 1 edit"])
        XCTAssertEqual(lost.last?.dot, .change)
        XCTAssertEqual(lost.last?.reveal, "c02")
        XCTAssertNil(lost.last?.section)
        let still = try turns(["anchor_state": "orphan", "changes": ["c03"], "history": [start, hist(2, "orphan", nil)],
                               "context": NSNull(), "student_note": studentNote("tried again", changes: ["c03"])], round: 3)
        XCTAssertEqual(still.last?.label, "R3 · Lin Mei revised · 1 edit")
        let words = try turns(["anchor_state": "orphan", "history": [start], "context": NSNull(),
                               "student_note": studentNote("it is gone on purpose")])
        XCTAssertEqual(words.last?.label, "R2 · Lin Mei answered · no edit")
        XCTAssertEqual(words.last?.dot, .hollow)
    }

    /// The drawn label keeps "· 1 edit" together, joined by no-break spaces, so a long name wraps before the verb's
    /// last word, never between "·" and "1 edit" (behaviour and visual reviews 2026-10-19); the count is the link.
    func testTheCountStaysWithTheVerb() throws {
        let t = try XCTUnwrap(try turns(["history": [start], "context": now(), "changes": ["c02"]]).last)
        XCTAssertEqual(t.label, "R2 · Lin Mei revised · 1 edit", "the model keeps plain spaces")
        let label = CardContent.label(t)
        XCTAssertEqual(String(label.characters), "R2 · Lin Mei revised\u{00A0}·\u{00A0}1\u{00A0}edit")
        let links = label.runs.filter { $0.link != nil }.map { String(label[$0.range].characters) }
        XCTAssertEqual(links, ["1\u{00A0}edit"])
        let none = try XCTUnwrap(try turns(["anchor_state": "unchanged", "history": [start], "context": now("We use a simple policy."),
                                            "student_note": studentNote("kept")]).last)
        XCTAssertEqual(String(CardContent.label(none).characters), "R2 · Lin Mei answered\u{00A0}·\u{00A0}no\u{00A0}edit")
    }

    /// Deleted, still deleted, then typed in again after a follow-up: "deleted it" (no count without edits), a quiet
    /// "still deleted", "restored it · 1 edit".
    func testDeletedAndRestored() throws {
        let gone = { (r: Int) in hist(r, "gone", "Each unit was calibrated.", cut: 25) }
        var third = gone(3)
        third["verdict"] = "reopened"
        third["verdict_note"] = "Keep the sentence."
        let t = try turns(["anchor_state": "moved", "changes": ["c04"], "history": [start, gone(2), third],
                           "context": now("We use a static policy, calibrated.")], round: 4)
        XCTAssertEqual(t.map(\.label), ["R1 · you commented on", "R2 · Lin Mei deleted it", "R3 · still deleted",
                                        "R3 · you followed up", "R4 · Lin Mei restored it · 1 edit"])
        XCTAssertEqual(t.map(\.dot), [.you, .change, .small, .you, .change])
        let stillNow = try turns(["anchor_state": "gone", "history": [start, gone(2)], "context": ctx("Each unit was calibrated.", cut: 25, page: 0)],
                                 round: 3)
        XCTAssertEqual(stillNow.last?.label, "R3 · still deleted")
        XCTAssertTrue(stillNow.last?.now == true)
    }

    /// The engine's turns: "text not found" with a red ring (its section says Not found), "still not found" quiet, and
    /// "found again" with that round's text; found with a change is the student's "revised".
    func testNotFoundAndFoundAgain() throws {
        let lost = { (r: Int) in hist(r, "orphan", nil) }
        let t = try turns(["anchor_state": "unchanged", "history": [start, lost(2), lost(3)], "context": now()], round: 4)
        XCTAssertEqual(t.map(\.label), ["R1 · you commented on", "R2 · text not found", "R3 · still not found", "R4 · found again"])
        XCTAssertEqual(t.map(\.dot), [.you, .notFound, .small, .hollow])
        XCTAssertEqual(t[1].section, "r2", "its section says Not found in R2")
        XCTAssertEqual(t[3].section, "r4")
        let stillNow = try turns(["anchor_state": "orphan", "history": [start, lost(2)], "context": NSNull()], round: 3)
        XCTAssertEqual(stillNow.last?.label, "R3 · still not found")
        XCTAssertEqual(stillNow.last?.dot, .notFound, "this round's is a red ring")
        let revised = try turns(["anchor_state": "changed", "changes": ["c02"], "history": [start, lost(2)], "context": now()],
                                round: 3)
        XCTAssertEqual(revised.last?.label, "R3 · Lin Mei revised · 1 edit")
    }

    // MARK: Who and in what order

    /// In one round the student's turn comes before yours: you spoke after reading that round's paper.
    func testTheStudentBeforeYouInARound() throws {
        var second = hist(2, "changed", "We use a simpler policy.", sel: [[9, 24]], verdict: "reopened", note: "Why?",
                          changes: ["c01"])
        second["student_note"] = studentNote("renamed it")
        let t = try turns(["history": [start, second], "context": now(), "changes": ["c02"]], round: 3,
                          emailed: [2: "Oct 9"])
        XCTAssertEqual(t.map(\.label), ["R1 · you commented on", "R2 · Lin Mei revised · 1 edit", "R2 · you followed up",
                                        "R3 · Lin Mei revised · 1 edit"])
        XCTAssertNil(t[1].reveal, "an earlier round's edits are not in this PDF")
        XCTAssertEqual(t[3].reveal, "c02")
        XCTAssertEqual(t[2].date, "sent Oct 9")
    }

    /// The shown round answered: your turn, its words the card's own (never cut); in a closed round the day it was finished.
    func testTheShownRoundsAnswer() throws {
        let long = String(repeating: "Name the survey you mean and give its year. ", count: 10)
        let t = try turns(["history": [start], "context": now(), "verdict": "reopened", "verdict_note": long],
                          emailed: [2: "Oct 17"])
        XCTAssertEqual(t.last?.label, "R2 · you followed up")
        XCTAssertEqual(t.last?.kind, .answer)
        XCTAssertEqual(t.last?.date, "sent Oct 17")
        XCTAssertNil(t.last?.words?.clamp)
        let resolved = try turns(["history": [start], "context": now(), "verdict": "verified", "verdict_note": ""])
        XCTAssertEqual(resolved.last?.label, "R2 · you resolved it")
        XCTAssertNil(resolved.last?.words, "no words: the label only")
    }

    /// An earlier round's view stops at that round: its answer is "you followed up" with its date, nothing after it.
    func testAPastRound() throws {
        let t = try turns(["anchor_state": "unchanged", "history": [start, hist(2, "unchanged", "We use a simple policy.", sel: [[9, 22]])],
                           "context": now("We use a simple policy."), "verdict": "reopened", "verdict_note": "Still no times."],
                          round: 3, emailed: [1: "Oct 2", 2: "Oct 9", 3: "Oct 17"])
        XCTAssertEqual(t.map(\.label), ["R1 · you commented on", "R2 · unchanged", "R3 · still unchanged", "R3 · you followed up"])
        XCTAssertEqual(t.last?.date, "sent Oct 17")
    }

    /// A new comment has one turn, named by how it was made; a carried one without a note says "you marked".
    func testFirstTurns() throws {
        let fresh = { (extra: [String: Any]) in
            try self.turns(["carried": false, "anchor_state": "new", "history": []].merging(extra) { _, b in b })
        }
        XCTAssertEqual(try fresh(["context": now()]).map(\.label), ["R2 · you selected text"])
        XCTAssertEqual(try fresh(["kind": "box", "context": ctx("", display: "image", page: 0)]).map(\.label),
                       ["R2 · you selected an area"])
        XCTAssertEqual(try fresh(["context": now()]).first?.section, "r2")
        XCTAssertEqual(try turns(["note": "", "history": [start], "context": now()]).first?.label, "R1 · you marked")
        XCTAssertEqual(try turns(["history": [hist(1, "new", "We use a simple policy.", sel: [[9, 22]], page: 3)],
                                  "context": now()]).first?.label, "R1 · you commented on p.4", "its page when not the card's")
    }

    /// No countable edit, no count; no name in the paper's record, "the student".
    func testNoCountAndNoName() throws {
        let t = try turns(["history": [start], "context": now()], student: "  ")
        XCTAssertEqual(t.last?.label, "R2 · the student revised")
        XCTAssertNil(t.last?.reveal)
    }

    /// A bare `% R1-03` (no words) points at the edit: no bubble, its place; a note on two lines in a row gives the range.
    func testBareAndTwoLineNotes() throws {
        let bare = try turns(["history": [start], "context": now(), "changes": ["c02"],
                              "student_note": studentNote("", changes: ["c02"])])
        XCTAssertNil(bare.last?.words)
        XCTAssertEqual(bare.last?.bare?.short, "main.tex:56")
        let two = try turns(["history": [start], "context": now(), "changes": ["c02"],
                             "student_note": studentNote("I kept one-minute windows. Could that wait?", changes: ["c02"],
                                                         lines: [103, 104])])
        XCTAssertEqual(two.last?.words?.place?.short, "main.tex:103–104")
    }

    /// The place in the bubble's footer (CARD §3.5): the file's name and line, the paths in the help tag.
    func testNotePlaces() throws {
        func place(_ lines: [(String, Int)]) -> Turn.Place? {
            CardContent.notePlace(StudentNote(text: "x", file: lines.first?.0, line: lines.first?.1,
                                              lines: lines.map { StudentNote.Line(file: $0.0, line: $0.1) }))
        }
        XCTAssertEqual(place([("sections/a/main.tex", 56)]), Turn.Place(short: "main.tex:56", full: "sections/a/main.tex:56"))
        XCTAssertEqual(place([("main.tex", 103), ("main.tex", 104)])?.short, "main.tex:103–104")
        XCTAssertEqual(place([("main.tex", 56), ("main.tex", 60)])?.short, "main.tex:56, 60")
        XCTAssertEqual(place([("main.tex", 56), ("main.tex", 60), ("main.tex", 70)])?.short, "main.tex:56 +2")
        let files = place([("intro.tex", 3), ("sections/method.tex", 12)])
        XCTAssertEqual(files?.short, "intro.tex:3 +1")
        XCTAssertEqual(files?.full, "intro.tex:3\nsections/method.tex:12", "each place in the help tag")
        XCTAssertEqual(CardContent.notePlace(StudentNote(text: "x", file: "main.tex", line: 9))?.short, "main.tex:9",
                       "a note from before `lines`")
        XCTAssertNil(CardContent.notePlace(StudentNote(text: "x")))
    }

    // MARK: Folding (CARD §3.8)

    /// R1-08: six turns, so the two between the first and the last three fold; the first never does. Five do not.
    func testFolding() throws {
        var answered = hist(3, "unchanged", "We use a simpler policy.", sel: [[9, 24]], verdict: "reopened", note: "Good.")
        answered["student_note"] = studentNote("I am rerunning the detector.")
        let history = [start, hist(2, "changed", "We use a simpler policy.", sel: [[9, 24]], verdict: "reopened",
                                   note: "Citing [12] is not a justification."), answered]
        let t = try turns(["history": history, "context": now(), "changes": ["c02"],
                           "student_note": studentNote("Added Table S2.", changes: ["c02"])], round: 4,
                          student: "Ouyang Mingxuan")
        XCTAssertEqual(t.map(\.label), ["R1 · you commented on", "R2 · Ouyang Mingxuan revised", "R2 · you followed up",
                                        "R3 · Ouyang Mingxuan answered · no edit", "R3 · you followed up",
                                        "R4 · Ouyang Mingxuan revised · 1 edit"])
        let fold = try XCTUnwrap(CardContent.fold(t))
        XCTAssertEqual(fold.start, 1)
        XCTAssertEqual(fold.end, 3)
        XCTAssertEqual(fold.count, 2)
        XCTAssertEqual(fold.label, "R2 · Ouyang Mingxuan revised, you followed up")
        XCTAssertNil(CardContent.fold(Array(t.prefix(5))), "five turns: nothing folds")
        // quiet lines do not count, and fold with the turns around them
        let quiet = try turns(["history": [start, hist(2, "unchanged", "We use a simple policy.", sel: [[9, 22]]),
                                           hist(3, "changed", "a", verdict: "reopened", note: "x"),
                                           hist(4, "changed", "b", verdict: "reopened", note: "y")],
                               "context": now(), "verdict": "reopened", "verdict_note": "z"], round: 5)
        XCTAssertEqual(quiet.map(\.label), ["R1 · you commented on", "R2 · unchanged", "R3 · Lin Mei revised",
                                            "R3 · you followed up", "R4 · Lin Mei revised", "R4 · you followed up",
                                            "R5 · Lin Mei revised", "R5 · you followed up"])
        let f = try XCTUnwrap(CardContent.fold(quiet))
        XCTAssertEqual(f.label, "R2–R4 · Lin Mei revised, you followed up, Lin Mei revised")
        XCTAssertEqual(f.count, 3)
        XCTAssertEqual(quiet[f.end].label, "R4 · you followed up")
        // while folded, the first turn's text is cut closer round its mark
        let long = String(repeating: "word ", count: 60) + "the marked words" + String(repeating: " word", count: 60)
        let mark = long.unicodeScalars.count - 300 - 16
        let cut = try XCTUnwrap(CardContent.foldTrim(BlockText(text: long, marks: [mark..<(mark + 16)])))
        XCTAssertLessThan(cut.text.count, 200)
        XCTAssertTrue(cut.text.hasPrefix("… ") && cut.text.hasSuffix(" …"))
        XCTAssertNil(CardContent.foldTrim(BlockText(text: "A short sentence with the marked words.", marks: [25..<38])))
    }

    /// The card model folds by turns and keeps the first section's shorter text for the folded state.
    func testTheCardModelFolds() throws {
        let words = String(repeating: "word ", count: 40) + "the marked words" + String(repeating: " word", count: 40)
        let mark = 200
        let history: [[String: Any]] = [hist(1, "new", words, sel: [[mark, mark + 16]])]
            + (2...5).map { hist($0, "changed", words + " \($0)", sel: [[mark, mark + 16]], verdict: "reopened", note: "again") }
        let m = CardModel(try makeComment(["page": 0, "history": history, "context": ctx(words + " 6", sel: [[mark, mark + 16]], page: 0)]),
                          round: 6, pdfs: [:], textX: [], showChanges: true)
        XCTAssertEqual(m.turns.count, 10)
        XCTAssertEqual(m.fold?.count, 6)
        XCTAssertNotNil(m.rendered["r1.fold"])
        XCTAssertNotNil(m.labels["fold"])
        XCTAssertEqual(Set(m.labels.keys).subtracting(["fold"]), Set(m.turns.map(\.id)))
    }

    // MARK: The length limit (CARD §1.3)

    /// Only earlier rounds' bubbles are cut: your earlier follow-up and the student's earlier note; this round's note,
    /// your answer and the title never.
    func testOnlyEarlierBubblesAreCut() throws {
        let long = (1...8).map { "Sentence number \($0) explains one more part of the reason at some length." }
            .joined(separator: " ")
        var second = hist(2, "unchanged", "We use a simple policy.", sel: [[9, 22]], verdict: "reopened", note: long)
        second["student_note"] = studentNote(long)
        let t = try turns(["history": [start, second], "context": now(), "changes": ["c02"],
                           "student_note": studentNote(long, changes: ["c02"])], round: 3)
        XCTAssertEqual(t.map(\.kind), [.first, .student, .advisor, .student])
        XCTAssertNotNil(t[1].words?.clamp, "the student's earlier note")
        XCTAssertNotNil(t[2].words?.clamp, "your earlier follow-up")
        XCTAssertNil(t[3].words?.clamp, "this round's note")
        let title = NoteTitle(long)
        XCTAssertEqual(title.first + " " + title.rest, long, "the title shows whole")
    }

    func testClampRule() throws {
        XCTAssertNil(CardContent.clamped("Short words."))
        XCTAssertNil(CardContent.clamped(String(repeating: "a", count: 320)), "320 characters show whole")
        // whole sentences within 200, and how many are left
        let s = (1...6).map { _ in "X" + String(repeating: "x", count: 54) + "." }  // 56 characters each
        let text = s.joined(separator: " ")  // 341
        let c = try XCTUnwrap(CardContent.clamped(text))
        XCTAssertEqual(c.shown, s.prefix(3).joined(separator: " "))  // 170 within 200; 227 is not
        XCTAssertEqual(c.more, 3)
        // a first sentence over 200: cut at the last word within it, "…", no count
        let one = String(repeating: "word ", count: 80).trimmingCharacters(in: .whitespaces) + "."
        let cut = try XCTUnwrap(CardContent.clamped(one))
        XCTAssertEqual(cut.more, 0)
        XCTAssertTrue(cut.shown.hasSuffix("word…"))
        XCTAssertLessThanOrEqual(cut.shown.count, 201)
        // "Fig. 1" and "e.g. the" do not end a sentence
        let figs = "See Fig. 1 and e.g. the second panel " + String(repeating: "y", count: 150) + ". "
            + String(repeating: "Then more words follow here. ", count: 8)
        let f = try XCTUnwrap(CardContent.clamped(figs))
        XCTAssertTrue(f.shown.hasPrefix("See Fig. 1 and e.g. the second panel"))
        XCTAssertTrue(f.shown.hasSuffix(String(repeating: "y", count: 150) + "."), f.shown)
        // CJK counts twice: 161 characters weigh 322
        let cjk = String(repeating: "这一轮还没改好。", count: 20) + "下"
        let k = try XCTUnwrap(CardContent.clamped(cjk))
        XCTAssertEqual(k.shown, String(repeating: "这一轮还没改好。", count: 12))  // 96 characters weigh 192
        XCTAssertEqual(k.more, 9)
        XCTAssertNil(CardContent.clamped(String(repeating: "这", count: 160)), "160 CJK characters weigh 320")
        // one long CJK sentence is cut at a character
        let run = try XCTUnwrap(CardContent.clamped(String(repeating: "这", count: 200)))
        XCTAssertEqual(run.shown, String(repeating: "这", count: 100) + "…")
    }

    // MARK: Words for VoiceOver and the row

    /// Labels and VoiceOver words never assume the student's gender (CARD §7).
    func testNoGenderedPronouns() throws {
        var all: [Turn] = []
        all += try turns(["history": [start], "context": now(), "changes": ["c02"],
                          "student_note": studentNote("renamed it", changes: ["c02"])], student: "")
        all += try turns(["anchor_state": "unchanged", "history": [start], "context": now("We use a simple policy."),
                          "student_note": studentNote("kept as is")], student: "")
        all += try turns(["anchor_state": "orphan", "history": [start], "context": NSNull()], student: "")
        all += try turns(["history": [start], "context": now(), "changes": ["c02"],
                          "student_note": studentNote("", changes: ["c02"])], student: "")
        let words = Set(["he", "she", "his", "her", "hers", "him"])
        for t in all {
            for s in [t.label, t.accessibility] {
                let tokens = s.lowercased().split { !$0.isLetter }.map(String.init)
                XCTAssertTrue(words.isDisjoint(with: tokens), s)
            }
        }
        XCTAssertEqual(all[1].accessibility, "Round 2, the student revised, 1 edit. Note: renamed it, main.tex line 56. We use a static policy.")
        XCTAssertEqual(all[3].accessibility, "Round 2, the student answered, no edit. Note: kept as is, main.tex line 56")
    }

    /// The row's note sign is the neutral speech bubble, not the quote bubble that looked like the comment sign.
    func testTheNoteSign() {
        XCTAssertEqual(StudentNoteSign.symbol, "bubble.left")
    }

    /// "Position uncertain" goes with the turn that holds the shown round.
    func testUncertainGoesWithTheShownRound() throws {
        let t = try turns(["confidence": 0.5, "history": [start], "context": now()])
        XCTAssertEqual(t.map(\.uncertain), [false, true])
        let quiet = try turns(["confidence": 0.5, "anchor_state": "unchanged", "history": [start],
                               "context": now("We use a simple policy."), "verdict": "reopened", "verdict_note": "x"])
        XCTAssertEqual(quiet.map(\.uncertain), [false, true, false], "the quiet line, not your answer")
    }
}

/// The conversation as the card draws it: folded in Review, whole in Focus; an earlier bubble cut, whole in Focus.
@MainActor
final class CardTurnsViewTests: XCTestCase {
    private func spin(_ s: Double = 0.1) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    private func height(_ card: CardModel, focus: Bool, showAll: Set<String> = []) -> CGFloat {
        _ = NSApplication.shared
        let actions = CardActions(), edit = EditState()
        actions.tips.dismiss(remember: false)
        edit.round = card.turns.last?.round ?? 2
        edit.roundOpen = true
        edit.focus = focus
        edit.showAll = showAll
        let host = NSHostingView(rootView: ExpandedCard(card: card, actions: actions).environmentObject(edit).frame(width: 380))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 900), styleMask: [.titled],
                              backing: .buffered, defer: true)  // never ordered in
        window.isReleasedWhenClosed = false
        window.contentView = host
        spin()
        defer { window.close() }
        return host.fittingSize.height
    }

    /// Review 2026-10-24 (A3b-02): the "position uncertain" caption names the tint only on the shown round's own text.
    /// When the shown round is a tag on R1's section (unchanged, a low-confidence carry), the only tint there is R1's
    /// selection, so it said the tint showed where the mark sits now when it did not.
    func testTheUncertainCaptionNamesTheTintOnlyOnTheShownRoundsText() throws {
        let start = hist(1, "new", "We use a simple policy.", sel: [[9, 22]])
        let revised = CardContent.thread(try makeComment(["confidence": 0.5, "history": [start],
                                                          "context": ctx("We use a static policy.", sel: [[9, 22]], page: 0)]),
                                         round: 2)
        let own = try XCTUnwrap(revised.last)
        XCTAssertTrue(own.uncertain && own.round == 2)
        XCTAssertEqual(ExpandedCard.uncertainWords(own, page: 0, round: 2, open: true),
                       "The faint tint shows where the mark sits now, and it may be on the wrong words. Check it on p.1; "
                       + "if it is wrong, choose [Re-anchor…](reanchor:)")
        let tagged = CardContent.thread(try makeComment(["confidence": 0.5, "anchor_state": "unchanged", "history": [start],
                                                         "context": ctx("We use a simple policy.", sel: [[9, 22]], page: 0)]),
                                        round: 2)
        XCTAssertEqual(tagged.map(\.round), [1], "the shown round is a tag on R1's section")
        let s = try XCTUnwrap(tagged.last)
        XCTAssertTrue(s.uncertain && s.strong)
        XCTAssertEqual(ExpandedCard.uncertainWords(s, page: 0, round: 2, open: true),
                       "The mark may be in the wrong place. Check it on p.1; if it is wrong, choose [Re-anchor…](reanchor:)")
        XCTAssertEqual(ExpandedCard.uncertainWords(s, page: 0, round: 2, open: false),
                       "The mark may be in the wrong place. Check it on p.1.", "a closed round: no link")
        XCTAssertEqual(ExpandedCard.uncertainWords(s, page: nil, round: 2, open: true),
                       "This round’s mark is on no page of the PDF. Choose [Re-anchor…](reanchor:) to place it.")
        // a new comment's one section is the shown round's own
        let new = CardContent.thread(try makeComment(["carried": false, "created_round": 2, "anchor_state": "new", "history": [],
                                                      "confidence": 0.5, "context": ctx("A short forecast.", sel: [[2, 16]])]),
                                     round: 2)
        XCTAssertTrue(ExpandedCard.uncertainWords(try XCTUnwrap(new.last), page: 1, round: 2, open: true)
            .hasPrefix("The tint shows where the mark sits now"))
    }

    /// The fold's line wraps under itself with a long name, so the verbs it lists are never cut (visual review
    /// 2026-10-19: "… Konstantinidou-Papadopoulou revi…").
    func testTheFoldLineWraps() {
        _ = NSApplication.shared
        func height(_ words: String) -> CGFloat {
            let f = TurnFold(start: 1, end: 3, count: 2, rounds: "R2", words: words)
            let host = NSHostingView(rootView: FoldLine(label: CardContent.label(f), count: 2, open: false) {}
                .padding(.leading, 24).frame(width: 300))
            return host.fittingSize.height
        }
        let short = height("Lin Mei revised, you followed up")
        let long = height("Alexandra Konstantinidou-Papadopoulou revised, you followed up")
        XCTAssertGreaterThan(long, short + 8, "two lines, not one cut")
    }

    func testFocusNeitherFoldsNorCuts() throws {
        let long = (1...8).map { "Sentence number \($0) explains one more part of the reason at some length." }
            .joined(separator: " ")
        let history: [[String: Any]] = [hist(1, "new", "We use a simple policy.", sel: [[9, 22]])]
            + (2...4).map { hist($0, "changed", "We use a simple policy \($0).", sel: [[9, 22]], verdict: "reopened", note: long) }
        let card = CardModel(try makeComment(["page": 0, "history": history, "context": ctx("We use a static policy.", sel: [[9, 22]], page: 0)]),
                             round: 5, pdfs: [:], textX: [], showChanges: true)
        XCTAssertNotNil(card.fold)
        let review = height(card, focus: false), focus = height(card, focus: true)
        let open = height(card, focus: false, showAll: Set(["fold"] + card.turns.filter { $0.words?.clamp != nil }.map { $0.id + ".words" }))
        XCTAssertGreaterThan(focus, review + 100, "Focus shows every turn and every word")
        // as Review with the fold open and every Show all, less the fold's line (two lines here: it wraps rather than
        // cut a verb) and the Show less links
        XCTAssertLessThan(focus, open)
        XCTAssertLessThan(open - focus, 120)
    }
}
