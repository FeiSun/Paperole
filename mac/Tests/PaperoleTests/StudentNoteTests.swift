import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import Paperole

/// The student's notes (CONTRACT amendment "Student notes"; UX.md §2, §3, §16): `% R1-03 …` lines in the .tex that the
/// engine reads at ingest. Decoding (and old states without them), their place in a card's thread, the row's sign, the
/// Changes tab's link and the warnings line. Synthetic data only.
@MainActor
final class StudentNoteTests: XCTestCase {
    private func spin(_ s: Double = 0.1) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    private func note(_ text: String, line: Int = 16, changes: [String] = []) -> [String: Any] {
        ["text": text, "file": "main.tex", "line": line, "changes": changes]
    }

    // MARK: Decoding

    /// The keys as the engine writes them (a synthetic round 3, its output trimmed): `student_note` on a comment and its
    /// history, `student_notes` on a change, top-level `note_warnings`.
    func testTheEngineKeysDecode() throws {
        let json = """
        {"schema": 1, "paper": {"path": "/p", "title": "T", "student": "S", "main": "main.tex", "engine": "pdflatex"},
         "rounds": [], "round": null,
         "comments": [{"id": "R1-03", "kind": "highlight", "color": "teal", "note": "Define the forecast.", "source": "app",
           "created_round": 1, "carried": true, "verdict": null, "verdict_note": "", "anchor_state": "unchanged",
           "confidence": 1.0, "method": "diff", "page": 0, "rects": [], "text": "x", "old_quote": "x", "new_quote": "x",
           "file": "main.tex", "line": 12, "changes": ["c02"], "context": null, "paragraph": 4,
           "student_note": {"text": "gave the window", "file": "main.tex", "line": 18, "changes": ["c02"]},
           "history": [{"round": 1, "page": 0, "anchor_state": "new", "verdict": null, "verdict_note": "", "context": null,
                        "changes": [], "student_note": null},
                       {"round": 2, "page": 0, "anchor_state": "unchanged", "verdict": "reopened",
                        "verdict_note": "Over what window?", "context": null, "changes": ["c02"],
                        "student_note": {"text": "新加一段定义 forecast", "file": "main.tex", "line": 16, "changes": ["c02"]}}]}],
         "changes": [{"id": "c02", "kind": "replace", "file": "main.tex", "line": 18, "old_text": "a", "new_text": "b",
           "page": 0, "rects": [], "attached_to": ["R1-03"], "unrequested": false, "student_notes": ["R1-03"]},
          {"id": "c03", "kind": "insert", "file": "main.tex", "line": 30, "old_text": "", "new_text": "c", "page": 0,
           "rects": [], "attached_to": [], "unrequested": true, "student_notes": []}],
         "note_warnings": [{"kind": "closed", "ids": ["R1-01"], "file": "main.tex", "line": 10, "text": "% R1-01 also here",
                            "message": "R1-01 was closed in Round 2 (resolved), so this note is ignored."},
                           {"kind": "error", "ids": [], "file": null, "line": null, "text": null,
                            "message": "The student's notes could not be read: boom"}]}
        """
        let st = try EngineState.decode(Data(json.utf8))
        let c = try XCTUnwrap(st.comments.first)
        XCTAssertEqual(c.studentNote, StudentNote(text: "gave the window", file: "main.tex", line: 18, changes: ["c02"]))
        XCTAssertEqual(c.studentNote?.place, "main.tex:18")
        XCTAssertEqual(c.note, "Define the forecast.", "`note` stays the advisor's")
        XCTAssertNil(c.history[0].studentNote)
        XCTAssertEqual(c.history[1].studentNote?.text, "新加一段定义 forecast")
        XCTAssertEqual(st.changes.map(\.studentNotes), [["R1-03"], []])
        XCTAssertEqual(st.noteWarnings?.count, 2)
        XCTAssertEqual(st.noteWarnings?[0].place, "main.tex:10")
        XCTAssertEqual(st.noteWarnings?[0].ids, ["R1-01"])
        XCTAssertNil(st.noteWarnings?[1].place, "an error has no file")
        XCTAssertNil(st.noteWarnings?[1].text)
    }

    /// States from before notes (every fixture, and an engine that does not write them) read as without any.
    func testOldStatesHaveNoNotes() throws {
        for name in ["state-round2.json", "state-m2a.json", "state-reading.json", "state-many.json"] {
            let st = try EngineState.decode(Data(contentsOf: StepTests.fixtures.appendingPathComponent(name)))
            XCTAssertNil(st.noteWarnings, name)
            XCTAssertTrue(st.comments.allSatisfy { $0.studentNote == nil && $0.history.allSatisfy { $0.studentNote == nil } }, name)
            XCTAssertTrue(st.changes.allSatisfy { $0.studentNotes == nil }, name)
        }
        // a note with keys missing reads with the defaults; a bare `% R1-03` has no words
        let bare = try makeDecoder().decode(StudentNote.self, from: Data(#"{"text": ""}"#.utf8))
        XCTAssertEqual(bare, StudentNote(text: ""))
        XCTAssertTrue(bare.isEmpty)
        XCTAssertFalse(StudentNote(text: "", changes: ["c01"]).isEmpty, "it points at an edit")
    }

    // MARK: The thread

    /// The shown round's note is in the turn of the round's revision, with its text (and before the field).
    func testTheShownRoundsNoteFollowsItsText() throws {
        let c = try makeComment(["context": ctx("We use a static policy.", sel: [[9, 22]]), "changes": ["c02"],
                                 "student_note": note("renamed it", changes: ["c02"])])
        let t = CardContent.thread(c, round: 2)
        XCTAssertEqual(t.map { "R\($0.round) · \($0.event)" }, ["R1 · as commented", "R2 · revised"])
        let turns = CardContent.turns(c, sections: t, round: 2)
        XCTAssertEqual(turns.map(\.label), ["R1 · you commented on p.1", "R2 · the student revised · 1 edit"])
        XCTAssertNil(turns[0].words)
        XCTAssertEqual(turns[1].words, Turn.Words(text: "renamed it", place: Turn.Place(short: "main.tex:16", full: "main.tex:16")))
        XCTAssertEqual(turns[1].section, "r2", "its words, then the round's text")
    }

    /// A round that changed nothing is a tag on the section above; its note ("kept as is …") is a turn of its own, after
    /// what the advisor said in the rounds before it and before what the advisor said in its round, so the card reads
    /// in the order things were said.
    func testANoteInAnUnchangedRoundIsInTheSectionAbove() throws {
        let history = [hist(1, "new", "A simple keep-alive policy holds every instance.", sel: [[0, 26]]),
                       hist(2, "unchanged", "A simple keep-alive policy holds every instance.", sel: [[0, 26]],
                            verdict: "reopened", note: "Please give the reason.")]
        var h2 = history
        h2[1]["student_note"] = note("kept as is: the reviewers use this term", line: 9)
        let c = try makeComment(["history": h2, "anchor_state": "unchanged",
                                 "student_note": note("kept as is: the venue uses it too", line: 9),
                                 "context": ctx("A simple keep-alive policy holds every instance.", sel: [[0, 26]])])
        let t = CardContent.thread(c, round: 3)
        XCTAssertEqual(t.count, 1)
        XCTAssertEqual(t[0].tags, ["unchanged in R2 and R3"])
        let turns = CardContent.turns(c, sections: t, round: 3)
        XCTAssertEqual(turns.map(\.id), ["r1", "s2", "a2", "s3"], "R2's note, what you said in R2, R3's note")
        XCTAssertEqual(turns.map(\.words?.text), [nil, "kept as is: the reviewers use this term", "Please give the reason.",
                                                  "kept as is: the venue uses it too"])
        XCTAssertEqual(turns[1].label, "R2 · the student answered · no edit")
        // without notes each round's follow-up is a turn of its own, after the round it answered
        let plainComment = try makeComment(["history": history + [hist(3, "unchanged", "A simple keep-alive policy holds every instance.",
                                                                       sel: [[0, 26]], verdict: "reopened", note: "Again.")],
                                            "anchor_state": "unchanged",
                                            "context": ctx("A simple keep-alive policy holds every instance.", sel: [[0, 26]])])
        let plain = CardContent.turns(plainComment, sections: CardContent.thread(plainComment, round: 4), round: 4)
        XCTAssertEqual(plain.map(\.id), ["r1", "q2", "a2", "q3", "a3", "q4"])
        XCTAssertEqual(plain.map(\.words?.text), [nil, nil, "Please give the reason.", nil, "Again.", nil])
        // a note in R3 comes between R2's words and R3's
        var noted = history + [hist(3, "unchanged", "A simple keep-alive policy holds every instance.", sel: [[0, 26]],
                                    verdict: "reopened", note: "Again.")]
        noted[2]["student_note"] = note("still the reviewers' term")
        let splitComment = try makeComment(["history": noted, "anchor_state": "unchanged",
                                            "context": ctx("A simple keep-alive policy holds every instance.", sel: [[0, 26]])])
        let split = CardContent.turns(splitComment, sections: CardContent.thread(splitComment, round: 4), round: 4)
        XCTAssertEqual(split.map(\.id), ["r1", "q2", "a2", "s3", "a3", "q4"])
        XCTAssertEqual(split[3].words?.text, "still the reviewers' term")
    }

    /// Earlier rounds' notes stay in their rounds' turns (read only in a past round's thread too); a round's note comes
    /// before what the advisor said in that round.
    func testEarlierRoundsKeepTheirNotes() throws {
        var history = [hist(1, "new", "Our controller sizes the pool from a forecast.", sel: [[0, 46]]),
                       hist(2, "changed", "Our controller sizes the pool from a forecast. The forecast is a moving average.",
                            sel: [[0, 46]], verdict: "reopened", note: "Over what window?", changes: ["c02"])]
        history[1]["student_note"] = note("新加一段定义 forecast", changes: ["c02"])
        let c = try makeComment(["history": history, "changes": ["c02"],
                                 "student_note": note("gave the window", line: 18, changes: ["c02"]),
                                 "context": ctx("Our controller sizes the pool from a forecast. The forecast is a moving average over the last hour.",
                                                sel: [[0, 46]])])
        let t = CardContent.thread(c, round: 3)
        XCTAssertEqual(t.map { "R\($0.round) · \($0.event)" }, ["R1 · as commented", "R2 · revised", "R3 · revised"])
        let turns = CardContent.turns(c, sections: t, round: 3)
        XCTAssertEqual(turns.map(\.id), ["r1", "s2", "a2", "s3"])
        XCTAssertEqual(turns.map(\.words?.text), [nil, "新加一段定义 forecast", "Over what window?", "gave the window"])
        XCTAssertEqual(turns.map(\.section), ["r1", "r2", nil, "r3"], "each note with its round's text")
        // the same comment as round 2 showed it (state --round 2): R2's note, then the shown round's words, as before
        let pastComment = try makeComment(["history": [history[0]], "changes": ["c02"], "verdict": "reopened",
                                           "verdict_note": "Over what window?",
                                           "student_note": note("新加一段定义 forecast", changes: ["c02"]),
                                           "context": ctx("Our controller sizes the pool from a forecast. The forecast is a moving average.",
                                                          sel: [[0, 46]])])
        let past = CardContent.turns(pastComment, sections: CardContent.thread(pastComment, round: 2), round: 2)
        XCTAssertEqual(past.map(\.id), ["r1", "s2", "now"], "the shown round's words end the card")
        XCTAssertEqual(past.map(\.words?.text), [nil, "新加一段定义 forecast", "Over what window?"])
    }

    /// A bare `% R1-03` with no edit next to it says nothing. One beside an edit points at it: the note's sign and its
    /// place, no words.
    func testABareNote() throws {
        func turns(_ extra: [String: Any]) throws -> [Turn] {
            let c = try makeComment(extra)
            return CardContent.turns(c, sections: CardContent.thread(c, round: 2), round: 2)
        }
        let none = try turns(["student_note": note(""), "context": ctx("We use a static policy.")])
        XCTAssertTrue(none.allSatisfy { $0.words == nil && $0.bare == nil })
        let pointing = try turns(["student_note": note("", changes: ["c02"]), "changes": ["c02"],
                                  "context": ctx("We use a static policy.")])
        XCTAssertEqual(pointing.last?.label, "R2 · the student revised · 1 edit")
        XCTAssertNil(pointing.last?.words)
        XCTAssertEqual(pointing.last?.bare, Turn.Place(short: "main.tex:16", full: "main.tex:16"))
    }

    /// A folded line holds the turn of a note it hides (UI v2.2: the student's turn, "revised", whose words are its note).
    func testTheFoldCountsNotes() throws {
        var history = [hist(1, "new", "Canopy cover fell.", sel: [[0, 18]]),
                       hist(2, "changed", "Canopy cover fell by 40%.", sel: [[0, 25]], verdict: "reopened", note: "Why?"),
                       hist(3, "changed", "Canopy cover fell by 40% in 2023.", sel: [[0, 33]], verdict: "reopened", note: "Which sites?"),
                       hist(4, "changed", "Canopy cover fell by 40% in 2023 at four sites.", sel: [[0, 47]], verdict: "reopened", note: "Cite.")]
        history[1]["student_note"] = note("added the number")
        let t = CardContent.thread(try makeComment(["history": history, "context": ctx("Canopy cover fell by 40% in 2023 at four sites [3].", sel: [[0, 51]])]),
                                   round: 5)
        let c = try makeComment(["history": history, "context": ctx("Canopy cover fell by 40% in 2023 at four sites [3].", sel: [[0, 51]])])
        let turns = CardContent.turns(c, sections: t, round: 5)
        let fold = try XCTUnwrap(CardContent.fold(turns))
        XCTAssertEqual(fold.label, "R2–R3 · the student revised, you followed up, the student revised, you followed up")
        XCTAssertEqual(turns[fold.start].words?.text, "added the number", "the note's turn is folded with its words")
    }

    // MARK: Edits a note linked outside the commented text

    /// Review (2026-10-18): an edit a note linked outside the commented text (`elsewhere`) does not revise it. A round
    /// with no other edit is a tag, not "revised"; its words are not carried into the sentence; the note's label links
    /// it ("· 1 edit") in the shown round only.
    func testAnEditLinkedElsewhereDoesNotReviseTheText() throws {
        var linked = note("kept the term; explained it in the intro", line: 3, changes: ["c05"])
        linked["elsewhere"] = ["c05"]
        let other = AnchorContext(text: "Operators use a policy they can explain.", sel: [[0, 40]])
        let kept = CardContent.thread(try makeComment(["anchor_state": "unchanged", "changes": ["c05"], "student_note": linked,
                                                       "context": ctx("We use a simple policy.", sel: [[9, 22]])]),
                                      round: 2, edits: ["c05": other])
        XCTAssertEqual(kept.map(\.event), ["as commented"])
        XCTAssertEqual(kept[0].tags, ["unchanged in R2"])
        let keptCard = CardModel(try makeComment(["anchor_state": "unchanged", "changes": ["c05"], "student_note": linked,
                                                  "context": ctx("We use a simple policy.", sel: [[9, 22]])]),
                                 round: 2, pdfs: [:], textX: [], showChanges: true)
        XCTAssertEqual(keptCard.turns.last?.elsewhere, ["c05"])
        XCTAssertEqual(keptCard.turns.last?.label, "R2 · the student edited elsewhere · 1 edit")
        XCTAssertEqual(keptCard.stateWord, "edited elsewhere",
                       "UI v2.2 (CARD.md §3.4): not \"unchanged\"; \"edit on p.6\" with the edit's page (CardTurnsTests)")
        // revised by its own edit too: only that edit's words are marked, and the section's link is to it alone
        var both = linked
        both["changes"] = ["c01", "c05"]
        let own = AnchorContext(text: "We use a static policy.", sel: [[9, 15]])
        let bothComment = try makeComment(["anchor_state": "changed", "changes": ["c01", "c05"], "student_note": both,
                                           "context": ctx("We use a static policy.", sel: [[9, 22]])])
        let revised = CardContent.thread(bothComment, round: 2, edits: ["c01": own, "c05": other])
        XCTAssertEqual(revised.map(\.event), ["as commented", "revised"])
        XCTAssertEqual(words(revised[1].full, \.changed), ["static"])
        XCTAssertEqual(revised[1].edits, ["c01"])
        let revisedTurn = CardContent.turns(bothComment, sections: revised, round: 2).last
        XCTAssertEqual(revisedTurn?.elsewhere, ["c05"])
        XCTAssertEqual(revisedTurn?.reveal, "c01", "the count shows the edit here first")
        // an earlier round's note links nothing that can be shown now
        var history = [hist(1, "new", "We use a simple policy.", sel: [[9, 22]]),
                       hist(2, "unchanged", "We use a simple policy.", sel: [[9, 22]], verdict: "reopened", note: "Why?",
                            changes: ["c05"])]
        history[1]["student_note"] = linked
        let laterComment = try makeComment(["history": history, "anchor_state": "unchanged",
                                            "context": ctx("We use a simple policy.", sel: [[9, 22]])])
        let later = CardContent.thread(laterComment, round: 3)
        XCTAssertEqual(later.map(\.event), ["as commented"])
        XCTAssertEqual(later[0].tags, ["unchanged in R2 and R3"])
        let laterTurns = CardContent.turns(laterComment, sections: later, round: 3)
        XCTAssertEqual(laterTurns.map(\.id), ["r1", "s2", "a2", "q3"])
        XCTAssertEqual(laterTurns[1].elsewhere, [], "R2's edit is not in this round's PDF")
        XCTAssertNil(laterTurns[1].reveal)
    }

    /// Review (2026-10-18): a box whose earlier round's attached edit was linked by a note, or was text, read "new image
    /// file" once a later round was shown. The engine names the edits that replaced a picture (history[].figures);
    /// without that name (an engine before it) the guess from the anchor stays.
    func testAnEarlierRoundIsANewImageFileOnlyByItsPicture() throws {
        func events(_ second: [String: Any]) throws -> [String] {
            let history = [hist(1, "new", "", display: "image", page: 3), second]
            return try CardContent.thread(makeComment(["kind": "box", "history": history, "anchor_state": "unchanged",
                                                       "context": ctx("", display: "image", page: 3)]), round: 3)
                .map { "R\($0.round) · \($0.event)" }
        }
        var linked = hist(2, "unchanged", "", display: "image", page: 3, verdict: "reopened", note: "Label it.", changes: ["c03"])
        var n = note("the caption names the policies", changes: ["c03"])
        n["elsewhere"] = ["c03"]
        linked["student_note"] = n
        linked["figures"] = [String]()
        XCTAssertEqual(try events(linked), ["R1 · as commented"])
        var text = hist(2, "unchanged", "", display: "image", page: 3, changes: ["c03"])
        text["figures"] = [String]()
        XCTAssertEqual(try events(text), ["R1 · as commented", "R2 · revised"])
        text["figures"] = ["c03"]
        XCTAssertEqual(try events(text), ["R1 · as commented", "R2 · new image file"])
        text.removeValue(forKey: "figures")
        XCTAssertEqual(try events(text), ["R1 · as commented", "R2 · new image file"], "an engine before figures: the guess")
    }

    /// A note's lines each name their edits: the Changes tab shows the line next to that edit, not the note's first.
    func testTheChangesTabShowsTheLineNextToTheEdit() throws {
        let json = #"{"text": "simpler words", "file": "main.tex", "line": 9, "changes": ["c01", "c04"], "elsewhere": ["c04"],"#
            + #" "lines": [{"file": "main.tex", "line": 9, "changes": ["c01"]}, {"file": "main.tex", "line": 35, "changes": ["c04"]}]}"#
        let sn = try makeDecoder().decode(StudentNote.self, from: Data(json.utf8))
        XCTAssertEqual(sn.elsewhere, ["c04"])
        XCTAssertEqual(sn.lines, [.init(file: "main.tex", line: 9, changes: ["c01"]), .init(file: "main.tex", line: 35, changes: ["c04"])])
        XCTAssertEqual([sn.place(for: "c01"), sn.place(for: "c04"), sn.place(for: "c99")], ["main.tex:9", "main.tex:35", "main.tex:9"])
        let ch = try makeChange(["id": "c04", "attached_to": ["R1-02"], "unrequested": false, "student_notes": ["R1-02"]])
        let m = ChangeModel(ch, round: 2, pdfs: [:], textX: [], statuses: [:], notes: ["R1-02": sn])
        XCTAssertEqual(m.notes.map(\.place), ["main.tex:35"])
    }

    // MARK: Rows and cards

    /// The row's sign is for the shown round's note only; VoiceOver reads it.
    func testTheRowSignIsForThisRoundsNote() throws {
        let with = CardModel(try makeComment(["student_note": note("gave the number")]), round: 2, pdfs: [:], textX: [], showChanges: true)
        XCTAssertEqual(with.studentNote, "gave the number")
        XCTAssertTrue(with.accessibility.hasSuffix(". Student’s note: gave the number"), with.accessibility)
        var history = [hist(1, "new", "x", sel: [[0, 1]]), hist(2, "unchanged", "x", sel: [[0, 1]], verdict: "reopened", note: "Why?")]
        history[1]["student_note"] = note("an earlier note")
        let earlier = CardModel(try makeComment(["history": history]), round: 3, pdfs: [:], textX: [], showChanges: true)
        XCTAssertNil(earlier.studentNote, "an earlier round's note is in the thread, not on the row")
        let bare = CardModel(try makeComment(["student_note": note("")]), round: 2, pdfs: [:], textX: [], showChanges: true)
        XCTAssertNil(bare.studentNote)
        XCTAssertNotEqual(with, CardModel(try makeComment([:]), round: 2, pdfs: [:], textX: [], showChanges: true),
                          "a note redraws the row")
    }

    /// The expanded card draws the note (its label and quoted words make the card taller), in an open round and in a
    /// closed one, where it is read only.
    func testTheCardShowsTheNote() throws {
        _ = NSApplication.shared
        let actions = CardActions(), edit = EditState()
        actions.tips.dismiss(remember: false)
        edit.round = 2
        func height(_ card: CardModel, open: Bool) -> CGFloat {
            edit.roundOpen = open
            let host = NSHostingView(rootView: ExpandedCard(card: card, actions: actions).environmentObject(edit).frame(width: 380))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 900), styleMask: [.titled],
                                  backing: .buffered, defer: true)  // never ordered in
            window.isReleasedWhenClosed = false
            window.contentView = host
            spin()
            defer { window.close() }
            return host.fittingSize.height
        }
        let base: [String: Any] = ["context": ctx("We use a static policy.", sel: [[9, 22]]), "changes": ["c02"]]
        let plain = CardModel(try makeComment(base), round: 2, pdfs: [:], textX: [], showChanges: true)
        let noted = CardModel(try makeComment(base.merging(["student_note": note("renamed it", changes: ["c02"])]) { _, b in b }),
                              round: 2, pdfs: [:], textX: [], showChanges: true)
        XCTAssertGreaterThan(height(noted, open: true), height(plain, open: true) + 40, "label and quoted words")
        XCTAssertGreaterThan(height(noted, open: false), height(plain, open: false) + 40, "read only in a closed round")
    }

    // MARK: The Changes tab

    /// An edit a note linked answers that comment, with the note's words; VoiceOver reads them.
    func testAnEditLinkedByANoteAnswersItsComment() throws {
        let ch = try makeChange(["attached_to": ["R1-03"], "unrequested": false, "student_notes": ["R1-03"]])
        let m = ChangeModel(ch, round: 2, pdfs: [:], textX: [], statuses: ["R1-03": .toCheck], colors: ["R1-03": .teal],
                            notes: ["R1-03": StudentNote(text: "新加一段定义 forecast", file: "main.tex", line: 16)])
        XCTAssertFalse(m.unrequested)
        XCTAssertEqual(m.links.map(\.id), ["R1-03"])
        XCTAssertEqual(m.notes, [ChangeModel.Note(id: "R1-03", text: "新加一段定义 forecast", place: "main.tex:16")])
        XCTAssertTrue(m.accessibility.contains("answers R1-03"))
        XCTAssertTrue(m.accessibility.hasSuffix(". student’s note on R1-03: 新加一段定义 forecast"), m.accessibility)
        // attached by the anchor alone: no note
        XCTAssertEqual(ChangeModel(try makeChange(["attached_to": ["R1-03"], "unrequested": false]), round: 2, pdfs: [:],
                                   textX: [], statuses: [:]).notes, [])
        // a bare note: linked, no words
        let bare = ChangeModel(ch, round: 2, pdfs: [:], textX: [], statuses: [:], notes: ["R1-03": StudentNote(text: "", changes: ["c08"])])
        XCTAssertEqual(bare.notes.map(\.text), [""])
    }

    /// In the app: the change's note comes from its comment's note of the shown round.
    func testTheAppLinksTheChangeToTheNote() throws {
        let m = makeModel()
        m.apply(try state { json in
            var comments = json["comments"] as? [[String: Any]] ?? []
            let i = try XCTUnwrap(comments.firstIndex { $0["carried"] as? Bool == true })
            let id = try XCTUnwrap(comments[i]["id"] as? String)
            var changes = json["changes"] as? [[String: Any]] ?? []
            let k = try XCTUnwrap(changes.firstIndex { $0["unrequested"] as? Bool == true })
            let chid = try XCTUnwrap(changes[k]["id"] as? String)
            comments[i]["student_note"] = ["text": "this is the fix", "file": "main.tex", "line": 3, "changes": [chid]]
            comments[i]["changes"] = ((comments[i]["changes"] as? [String]) ?? []) + [chid]
            changes[k]["attached_to"] = [id]
            changes[k]["unrequested"] = false
            changes[k]["student_notes"] = [id]
            json["comments"] = comments
            json["changes"] = changes
            json["note_warnings"] = [["kind": "unknown", "ids": ["R1-09"], "file": "main.tex", "line": 19,
                                      "text": "% R1-09 typo fixed", "message": "There is no comment R1-09, so this note is ignored."]]
        })
        let linked = try XCTUnwrap(m.changes.linked.first { !$0.notes.isEmpty })
        XCTAssertEqual(linked.notes.first?.text, "this is the fix")
        XCTAssertEqual(m.panel.cards.filter { $0.studentNote != nil }.count, 1)
        XCTAssertEqual(m.noteWarnings.map(\.place), ["main.tex:19"])
        // one calm place: the line on the Comments tab's page (which slides away with it to the Changes tab), not in
        // Focus
        XCTAssertTrue(m.noteWarningsLine)
        m.tab = .changes
        XCTAssertTrue(m.noteWarningsLine, "still on the Comments tab's page, out of view")
        m.tab = .comments
        m.setFocus(true)
        XCTAssertTrue(m.focus)
        XCTAssertFalse(m.noteWarningsLine)
        m.setFocus(false)
        XCTAssertTrue(m.noteWarningsLine)
    }

    // MARK: Warnings

    /// One calm line on the Comments tab when some notes were not used, its popover listing each with file:line.
    func testTheWarningsLineAndItsList() throws {
        _ = NSApplication.shared
        let warnings = [NoteWarning(kind: "unknown", ids: ["R1-09"], file: "main.tex", line: 19, text: "% R1-09 typo fixed",
                                    message: "There is no comment R1-09, so this note is ignored."),
                        NoteWarning(kind: "malformed", file: "main.tex", line: 20, text: "% R1.03 see also the appendix",
                                    message: "This note's ID is not in the form R1-03, so it is ignored.")]
        let line = NSHostingView(rootView: NoteWarningsLine(warnings: warnings, round: 2, shown: .constant(false)).frame(width: 400))
        XCTAssertGreaterThan(line.fittingSize.height, 10)
        XCTAssertLessThan(line.fittingSize.height, 40, "one line")
        let one = NSHostingView(rootView: NoteWarningsList(warnings: [warnings[0]], round: 2))
        let two = NSHostingView(rootView: NoteWarningsList(warnings: warnings, round: 2))
        XCTAssertGreaterThan(two.fittingSize.height, one.fittingSize.height + 30, "a row for each")
        let m = makeModel()
        XCTAssertEqual(m.noteWarnings, [], "a state from before notes has none")
        XCTAssertFalse(m.noteWarningsLine)
    }

    // MARK: Helpers

    private var drafts: URL!

    override func setUpWithError() throws {
        drafts = FileManager.default.temporaryDirectory.appendingPathComponent("pc-notes-drafts-" + UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: drafts)
    }

    private func makeModel() -> AppModel {
        _ = NSApplication.shared
        var o = LaunchOptions()
        o.fixture = StepTests.fixtures.appendingPathComponent("state-m2a.json").path
        o.drafts = drafts.path
        return AppModel(options: o)
    }

    private func state(_ change: (inout [String: Any]) throws -> Void) throws -> EngineState {
        let url = StepTests.fixtures.appendingPathComponent("state-m2a.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        try change(&json)
        return try EngineState.decode(JSONSerialization.data(withJSONObject: json))
    }
}
