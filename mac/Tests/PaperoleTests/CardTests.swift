import Foundation
import SwiftUI
import XCTest
@testable import Paperole

/// A comment from JSON: a carried highlight in round 2 by default, with `extra` keys replacing the defaults.
func makeComment(_ extra: [String: Any]) throws -> Comment {
    var base: [String: Any] = [
        "id": "R1-01", "kind": "highlight", "note": "n", "source": "app", "created_round": 1, "carried": true,
        "verdict": NSNull(), "verdict_note": "", "anchor_state": "changed", "confidence": 0.9, "method": "diff",
        "page": 1, "rects": [[72, 100, 200, 110]], "text": "pdf words", "old_quote": "old \\emph{quote}",
        "new_quote": "new quote", "file": "main.tex", "line": 7, "changes": [], "history": [
            ["round": 1, "anchor_state": "new", "verdict": NSNull(), "verdict_note": "", "page": 0,
             "context": ["text": "We use a simple policy.", "sel": [[9, 22]], "display": "text", "page": 0]]]]
    for (k, v) in extra { base[k] = v }
    return try makeDecoder().decode(Comment.self, from: JSONSerialization.data(withJSONObject: base))
}

func ctx(_ text: String, sel: [[Int]] = [], cut: Int? = nil, display: String = "text", page: Int = 1) -> [String: Any] {
    var d: [String: Any] = ["text": text, "sel": sel, "display": display, "page": page, "rects": [[72, 100, 200, 110]]]
    d["cut"] = cut ?? NSNull()
    return d
}

func substring(_ s: String, _ r: Range<Int>) -> String {
    let u = Array(s.unicodeScalars)
    return String(String.UnicodeScalarView(u[r]))
}

final class M2aDecodingTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    func testM2aFixture() throws {
        let st = try EngineState.decode(Data(contentsOf: Self.fixtures.appendingPathComponent("state-m2a.json")))
        XCTAssertEqual(st.rounds.map(\.pdf), ["round1/main.pdf", "round2/main.pdf"])
        XCTAssertEqual(Set(st.comments.map(\.anchorState)), ["new", "unchanged", "changed", "moved", "gone", "orphan"])
        XCTAssertEqual(Set(st.comments.map(\.kind)), ["highlight", "underline", "strikeout", "note", "box"])
        XCTAssertEqual(Set(st.comments.map(\.markColor)), Set(MarkColor.allCases))
        let by = Dictionary(uniqueKeysWithValues: st.comments.map { ($0.id, $0) })
        XCTAssertNil(by["R1-01"]?.color)  // missing means yellow
        XCTAssertEqual(by["R1-01"]?.markColor, .yellow)
        let gone = try XCTUnwrap(by["R1-03"]?.context)
        XCTAssertEqual(gone.cut, 213)
        XCTAssertEqual(gone.sel, [])
        XCTAssertNil(by["R1-08"]?.context)  // orphan
        XCTAssertEqual(by["R1-08"]?.history.first?.context?.sel, [[66, 113]])
        let box = try XCTUnwrap(by["R1-10"])
        XCTAssertEqual(box.markKind, .box)
        XCTAssertTrue(box.context?.isImage ?? false)
        XCTAssertEqual(box.history.first?.page, 2)
        XCTAssertTrue(box.history.first?.context?.isImage ?? false)
        let r102 = try XCTUnwrap(by["R1-02"]?.context)
        XCTAssertEqual(substring(r102.text, r102.sel[0][0]..<r102.sel[0][1]).prefix(15), "Both approaches")
    }

    func testOldStateHasNoContextOrColour() throws {
        let st = try EngineState.decode(Data(contentsOf: Self.fixtures.appendingPathComponent("state-round2.json")))
        XCTAssertTrue(st.comments.allSatisfy { $0.context == nil && $0.color == nil && $0.markColor == .yellow })
        XCTAssertTrue(st.rounds.allSatisfy { $0.pdf == nil })
        XCTAssertTrue(st.comments.flatMap(\.history).allSatisfy { $0.context == nil && $0.page == nil })
    }

    func testEngineContextKeysAreReadOrIgnored() throws {
        // The engine also sends clip, changed and against; clip sets the crop area, the others are ignored.
        let c = try makeDecoder().decode(AnchorContext.self, from: Data("""
        {"page": 2, "rects": [[118.8, 174.6, 493.2, 361.9]], "clip": [112.8, 168.6, 499.2, 367.9], "sel": [], "cut": null,
         "changed": [[1, 2]], "against": 1, "display": "image", "text": ""}
        """.utf8))
        XCTAssertEqual(c.clip, [112.8, 168.6, 499.2, 367.9])
        let req = CropRequest(round: 1, pdf: nil, page: 2, rects: c.rects, textX: [72, 540], clip: c.clip)
        let a = try XCTUnwrap(CropCache.area(req))
        XCTAssertEqual(a.minX, 112.8, accuracy: 1e-9)
        XCTAssertEqual(a.maxY, 367.9, accuracy: 1e-9)
        var noClip = req
        noClip.clip = nil
        XCTAssertEqual(CropCache.area(noClip)?.minX, 70)  // rects + 6, widened to text_x − 2
        XCTAssertEqual(CropCache.area(noClip)?.minY ?? 0, 168.6, accuracy: 1e-9)
    }
}

/// A history entry (an earlier round) for makeComment.
func hist(_ round: Int, _ state: String, _ text: String?, sel: [[Int]] = [], cut: Int? = nil, display: String = "text",
          page: Int = 0, verdict: String? = nil, note: String = "", changes: [String]? = []) -> [String: Any] {
    var h: [String: Any] = ["round": round, "anchor_state": state, "verdict": verdict ?? NSNull(), "verdict_note": note,
                            "page": page]
    h["context"] = text.map { ctx($0, sel: sel, cut: cut, display: display, page: page) } ?? NSNull()
    if let changes { h["changes"] = changes }
    return h
}

/// The words of `t` in the given ranges.
func words(_ t: BlockText, _ ranges: KeyPath<BlockText, [Range<Int>]>) -> [String] {
    t[keyPath: ranges].map { substring(t.text, $0) }
}

/// The thread of a card (UX.md §3, design/ui-v2 examples a–i).
final class ThreadTests: XCTestCase {
    let pdfs = [1: "/r1.pdf", 2: "/r2.pdf", 3: "/r3.pdf"]

    func thread(_ extra: [String: Any], round n: Int = 2, figures: [String: String] = [:]) throws -> [ThreadSection] {
        CardContent.thread(try makeComment(extra), round: n, pdfs: pdfs, figures: figures)
    }

    func labels(_ t: [ThreadSection], page: Int? = 1) -> [String] {
        t.map { "R\($0.round) · " + $0.event + ($0.page != nil && $0.page != page ? " · p.\($0.page! + 1)" : "") }
    }

    // MARK: New comments: one section

    func testNewComment() throws {
        let t = try thread(["carried": false, "created_round": 2, "anchor_state": "new", "history": [],
                            "context": ctx("A short forecast is enough here.", sel: [[2, 16]])])
        XCTAssertEqual(labels(t), ["R2 · selected text"])
        XCTAssertEqual(t[0].kind, .text)
        XCTAssertEqual(t[0].full.marks, [2..<16])
        XCTAssertTrue(t[0].strong)
        XCTAssertFalse(t[0].revised)
    }

    func testNewBoxIsAnImageOfThisRound() throws {
        let t = try thread(["carried": false, "created_round": 2, "anchor_state": "new", "history": [], "kind": "box",
                            "context": ctx("", display: "image", page: 2), "page": 2])
        XCTAssertEqual(labels(t, page: 2), ["R2 · selected area"])
        XCTAssertEqual(t[0].kind, .image)
        XCTAssertEqual(t[0].crop?.round, 2)
        XCTAssertEqual(t[0].crop?.pdf, "/r2.pdf")
        XCTAssertEqual(t[0].crop?.faint, false)
    }

    func testClickNote() throws {
        let t = try thread(["carried": false, "created_round": 2, "anchor_state": "new", "history": [], "kind": "note",
                            "method": "line", "confidence": 0.5, "context": ctx("The nearest sentence.")])
        XCTAssertEqual(labels(t), ["R2 · note placed near this text"])
        XCTAssertEqual(t[0].full.marks, [])
        XCTAssertFalse(t[0].uncertain)  // its place is a guess by design
    }

    func testANewNoteOnAnEmptyArea() throws {
        let t = try thread(["carried": false, "created_round": 2, "anchor_state": "new", "history": [], "kind": "note",
                            "method": "line", "new_quote": "\\clearpage",
                            "context": ["text": "", "sel": [], "page": 1, "rects": [[300, 400, 300, 400]]]])
        XCTAssertEqual(labels(t), ["R2 · note on an empty area"])
        XCTAssertEqual(t[0].crop?.clip, [190, 340, 410, 460])
    }

    // MARK: Sections by the engine's signals

    func testChangedIsASectionWithItsChangedWords() throws {
        let t = try thread(["context": ctx("We use a static policy.", sel: [[9, 22]]), "changes": ["c02"]])
        XCTAssertEqual(labels(t), ["R1 · as commented · p.1", "R2 · revised"])
        XCTAssertEqual(t[0].full.marks, [9..<22])
        XCTAssertTrue(t[0].strong && !t[1].strong && t[1].revised && !t[0].revised)
        XCTAssertEqual(words(t[1].full, \.changed), ["static"])
        XCTAssertEqual(t[1].full.carets, [])
        XCTAssertEqual(t[1].edits, ["c02"])  // "· 1 edit", this round's only
    }

    func testDeletedWordsLeaveACaret() throws {
        let t = try thread(["context": ctx("We use a policy.", sel: [[9, 15]])])
        XCTAssertEqual(t[1].full.changed, [])
        XCTAssertEqual(t[1].full.carets, [8])  // after "a", where "simple" was
    }

    func testUnchangedAndMovedAreTagsOnTheSectionAbove() throws {
        let same = try thread(["anchor_state": "unchanged", "page": 0, "context": ctx("We  use a simple\npolicy.", sel: [[10, 24]], page: 0)])
        XCTAssertEqual(labels(same, page: 0), ["R1 · as commented"])
        XCTAssertEqual(same[0].tags, ["unchanged in R2"])
        XCTAssertEqual(same[0].rounds, [1, 2])
        let moved = try thread(["anchor_state": "moved", "page": 3, "context": ctx("We use a simple policy.", sel: [[9, 22]], page: 3)])
        XCTAssertEqual(labels(moved, page: 3), ["R1 · as commented · p.1"])
        XCTAssertEqual(moved[0].tags, ["moved to p.4 in R2"])
        // moved with edits attached (a section moved to the appendix): a section that says so, not "revised"
        let movedEdited = try thread(["anchor_state": "moved", "page": 3, "changes": ["c20"],
                                      "context": ctx("We use a simple policy.", sel: [[9, 22]], page: 3)])
        XCTAssertEqual(labels(movedEdited, page: 1), ["R1 · as commented · p.1", "R2 · moved · p.4"])
        XCTAssertEqual(movedEdited[1].tags, [])
        XCTAssertFalse(movedEdited[1].revised)
        // a section is not made by comparing the text: an unchanged round that prints other words is still a tag
        let other = try thread(["anchor_state": "unchanged", "context": ctx("Something else entirely.")])
        XCTAssertEqual(other.count, 1)
        // and an attached edit makes a section though the anchor is unchanged
        let attached = try thread(["anchor_state": "unchanged", "changes": ["c01"], "context": ctx("We use a simple policy.", sel: [[9, 22]])])
        XCTAssertEqual(labels(attached), ["R1 · as commented · p.1", "R2 · revised"])
        XCTAssertEqual(attached[1].full.changed, [])
    }

    /// Example a (R1-02): R2 changed nothing and was followed up; R3 revised.
    func testExampleAFollowedUpOnAnUnchangedRound() throws {
        let history = [hist(1, "new", "Coral reefs are loud. Snapping shrimp dominate reef soundscapes [7].", sel: [[22, 68]]),
                       hist(2, "unchanged", "Coral reefs are loud. Snapping shrimp dominate reef soundscapes [7].", sel: [[22, 68]],
                            verdict: "reopened", note: "Still no groundwork.")]
        let now = "Coral reefs are loud. Snapping shrimp dominate reef soundscapes below 2 kHz [7]."
        let c = try makeComment(["history": history, "page": 0, "changes": ["c07"], "context": ctx(now, sel: [[22, 80]], page: 0)])
        let t = CardContent.thread(c, round: 3, pdfs: pdfs)
        XCTAssertEqual(labels(t, page: 0), ["R1 · as commented", "R3 · revised"])
        XCTAssertEqual(t[0].tags, ["unchanged in R2"])
        XCTAssertEqual(words(t[1].full, \.changed), ["below 2 kHz"])
        XCTAssertEqual(t[1].edits, ["c07"])
        // what you said in R2 is a turn after the round it answered, with the day its round was finished
        let turns = CardContent.turns(c, sections: t, round: 3, emailed: [2: "Oct 9"])
        XCTAssertEqual(turns.map(\.label), ["R1 · you commented on", "R2 · unchanged", "R2 · you followed up",
                                            "R3 · the student revised · 1 edit"])
        XCTAssertEqual(turns[2].date, "sent Oct 9")
        XCTAssertEqual(turns[2].words?.text, "Still no groundwork.")
        let m = CardModel(try makeComment(["history": history, "page": 0, "changes": ["c07"],
                                           "context": ctx(now, sel: [[22, 80]], page: 0)]),
                          round: 3, pdfs: [:], textX: [], showChanges: true)
        XCTAssertEqual(m.status, .toCheck)
        XCTAssertEqual(m.stateWord, "revised")
        XCTAssertNil(m.fold)
    }

    /// Example b: revised in R2, followed up on that R2 sentence, revised again in R3: each section against the one
    /// above only.
    func testExampleBRevisedFollowedUpRevisedAgain() throws {
        let history = [hist(1, "new", "Each hydrophone was connected to a preamplifier.", sel: [[0, 48]]),
                       hist(2, "changed", "Each hydrophone (sensitivity −165 dB) was connected to a preamplifier.",
                            sel: [[0, 70]], verdict: "reopened", note: "Give the unit.", changes: ["c03"])]
        let now = "Each hydrophone (sensitivity −165 dB re 1 V/µPa) was connected to a preamplifier."
        let c = try makeComment(["history": history, "page": 0, "context": ctx(now, sel: [[0, 81]], page: 0)])
        let t = CardContent.thread(c, round: 3, pdfs: pdfs)
        XCTAssertEqual(labels(t, page: 0), ["R1 · as commented", "R2 · revised", "R3 · revised"])
        XCTAssertEqual(words(t[1].full, \.changed), ["(sensitivity −165 dB)"])
        XCTAssertEqual(words(t[2].full, \.changed), ["re 1 V/µPa"])  // against R2, not R1
        XCTAssertEqual(t[2].edits, [])  // the shown round attached no change here
        // the follow-up on the R2 sentence comes between the two revisions
        let turns = CardContent.turns(c, sections: t, round: 3)
        XCTAssertEqual(turns.map(\.id), ["r1", "s2", "a2", "s3"])
        XCTAssertEqual(turns.map(\.section), ["r1", "r2", nil, "r3"])
        XCTAssertEqual(turns[2].words?.text, "Give the unit.")
    }

    /// Example c: a long history; a round that changed nothing is a tag on the section above, and each follow-up is a
    /// turn after the round it answered. The card folds by turns since UI v2.2 (CARD.md §3.8): past five, the ones
    /// between the first and the last three.
    func testExampleCALongHistoryFolds() throws {
        let history = [hist(1, "new", "Canopy cover fell.", sel: [[0, 18]]),
                       hist(2, "changed", "Canopy cover fell by 40%.", sel: [[0, 25]], verdict: "reopened", note: "Why?"),
                       hist(3, "changed", "Canopy cover fell by 40% in 2023.", sel: [[0, 33]], verdict: "reopened", note: "Which sites?"),
                       hist(4, "unchanged", "Canopy cover fell by 40% in 2023.", sel: [[0, 33]], verdict: "reopened", note: "Still no sites."),
                       hist(5, "changed", "Canopy cover fell by 40% in 2023 at four sites.", sel: [[0, 47]], verdict: "reopened",
                            note: "Give the years.")]
        let c = try makeComment(["history": history, "page": 0,
                                 "context": ctx("Canopy cover fell by 40% in 2023 at four sites, 2000–2020.", sel: [[0, 58]], page: 0)])
        let t = CardContent.thread(c, round: 6)
        XCTAssertEqual(labels(t, page: 0), ["R1 · as commented", "R2 · revised", "R3 · revised", "R5 · revised", "R6 · revised"])
        XCTAssertEqual(t[2].tags, ["unchanged in R4"])
        let turns = CardContent.turns(c, sections: t, round: 6)
        XCTAssertEqual(turns.map(\.id), ["r1", "s2", "a2", "s3", "a3", "q4", "a4", "s5", "a5", "s6"])
        let fold = try XCTUnwrap(CardContent.fold(turns))
        XCTAssertEqual(fold.count, 5)  // the first turn and the last three stay open
        XCTAssertEqual(fold.label, "R2–R4 · the student revised, you followed up, the student revised, you followed up, "
                       + "you followed up")
        XCTAssertNil(CardContent.fold(Array(turns.prefix(5))))  // five turns or fewer: nothing folds
    }

    /// Example d and the third extra case: below 0.75 the shown round's section says "position uncertain", except for
    /// a note placed by a click (carried or new).
    func testExampleDPositionUncertain() throws {
        let t = try thread(["confidence": 0.5, "context": ctx("Recordings started two hours after low water.", sel: [[19, 44]])])
        XCTAssertEqual(t.map(\.uncertain), [false, true])
        XCTAssertEqual(CardModel(try makeComment(["confidence": 0.5]), round: 2, pdfs: [:], textX: [], showChanges: true).stateWord,
                       "position uncertain")
        let note = try thread(["kind": "note", "method": "line", "confidence": 0.5, "anchor_state": "unchanged"])
        XCTAssertEqual(note.map(\.uncertain), [false])
        XCTAssertFalse(try makeComment(["kind": "note", "confidence": 0.5, "carried": false, "anchor_state": "new"]).lowConfidence)
        XCTAssertTrue(try makeComment(["kind": "note", "confidence": 0.5, "anchor_state": "gone"]).lowConfidence)
        let unchanged = try thread(["confidence": 0.6, "anchor_state": "unchanged"])
        XCTAssertEqual(unchanged.map(\.uncertain), [true])  // on the section that holds the shown round
    }

    /// Example e: deleted; the text around the cut, a caret, nothing underlined.
    func testExampleEDeleted() throws {
        let history = [hist(2, "new", "Fixed 1 m up. All recorders sampled at 96 kHz. Each lasted six weeks.", sel: [[14, 46]])]
        let t = try thread(["created_round": 2, "history": history, "anchor_state": "gone", "page": 0, "changes": ["c12"],
                            "context": ctx("Fixed 1 m up. Each lasted six weeks.", cut: 13, page: 0)], round: 3)
        XCTAssertEqual(labels(t, page: 0), ["R2 · as commented", "R3 · deleted"])
        XCTAssertTrue(t[1].gone && t[1].revised)
        XCTAssertEqual(t[1].full.carets, [13])
        XCTAssertEqual(t[1].full.changed, [])
        let row = try thread(["anchor_state": "gone", "context": ctx("", display: "image")])  // a table row: where it was
        XCTAssertEqual(row.last?.kind, .image)
        XCTAssertEqual(row.last?.crop?.deletion, true)
        let nothing = try thread(["anchor_state": "gone", "context": NSNull()])
        XCTAssertEqual(nothing.last?.kind, .plain)
        XCTAssertEqual(nothing.last?.full.text, "Nothing is printed near the cut.")
        let still = try thread(["history": history + [hist(3, "gone", "Fixed 1 m up. Each lasted six weeks.", cut: 13)],
                                "created_round": 2, "anchor_state": "gone", "context": ctx("Fixed 1 m up. Each lasted.", cut: 13)],
                               round: 4)
        XCTAssertEqual(still.map(\.event), ["as commented", "deleted"])
        XCTAssertEqual(still[1].tags, ["still deleted in R4"])
    }

    /// The second extra case: deleted, then typed in again (the engine's `moved` after `gone`): "restored", compared
    /// with the section before the deletion.
    func testDeletedThenRestored() throws {
        let history = [hist(1, "new", "We sample at 96 kHz.", sel: [[3, 19]]),
                       hist(2, "gone", "Before. After.", cut: 7, changes: ["c04"])]
        let t = try thread(["history": history, "anchor_state": "moved", "changes": ["c09"], "page": 0,
                            "context": ctx("We sample at 48 kHz.", sel: [[3, 19]], page: 0)], round: 3)
        XCTAssertEqual(labels(t, page: 0), ["R1 · as commented", "R2 · deleted", "R3 · restored"])
        XCTAssertEqual(words(t[2].full, \.changed), ["48"])  // against R1, not the text around R2's cut
        XCTAssertEqual(t[2].tags, [])
    }

    /// Example f: a figure; a new image file makes a section (inferred for an earlier round from its attached edit),
    /// the same image is a tag; crops of each round, the box faint after the first.
    func testExampleFAFigure() throws {
        let image = ctx("", display: "image", page: 3)
        let history = [hist(1, "new", "", display: "image", page: 3),
                       hist(2, "unchanged", "", display: "image", page: 3, verdict: "reopened", note: "Label the bar.",
                            changes: ["c05"]),
                       hist(3, "unchanged", "", display: "image", page: 3)]
        var moved = image
        moved["page"] = 4
        let t = try thread(["kind": "box", "history": history, "anchor_state": "moved", "page": 4, "changes": ["c09"],
                            "context": moved], round: 4, figures: ["c09": "reef.pdf"])
        XCTAssertEqual(labels(t, page: 4), ["R1 · as commented · p.4", "R2 · new image file · p.4", "R4 · new image file"])
        XCTAssertEqual(t[1].tags, ["unchanged in R3"])
        XCTAssertEqual(t[2].tags, ["moved to p.5"])
        XCTAssertEqual(t.map { $0.crop?.round }, [1, 2, 4])
        XCTAssertEqual(t.map { $0.crop?.faint }, [false, true, true])
        XCTAssertEqual(t.map { $0.crop?.pdf }, ["/r1.pdf", "/r2.pdf", nil])
        // an edit of the shown round that is not a picture file is "revised"
        XCTAssertEqual(try thread(["kind": "box", "history": [history[0]], "anchor_state": "changed", "changes": ["c01"],
                                   "context": image]).last?.event, "revised")
        let m = CardModel(try makeComment(["kind": "box", "history": history, "anchor_state": "moved", "page": 4,
                                           "changes": ["c09"], "context": moved]),
                          round: 4, pdfs: [:], textX: [], showChanges: true, figures: ["c09": "reef.pdf"])
        XCTAssertEqual(m.info.newImages, ["reef.pdf"])
    }

    /// Example g: a whole paragraph; long text trims as before, and words cut from the mark leave a caret at its end.
    func testExampleGAWholeParagraph() throws {
        let sentences = ["Seagrass meadows store carbon in their sediments for centuries.",
                         "Because the sediments are rarely disturbed, the carbon they hold stays buried for a long time."]
            + (1...6).map { "In other words (\($0)), meadow sediments keep carbon out of the air for a long time." }
        let para = sentences.joined(separator: " ")
        let n = para.unicodeScalars.count
        let now = "Seagrass meadows store carbon in their sediments for centuries, because the sediments are rarely disturbed."
        let t = try thread(["history": [hist(1, "new", para, sel: [[0, n]])], "page": 0,
                            "context": ctx(now, sel: [[0, now.unicodeScalars.count]], page: 0)])
        let short = try XCTUnwrap(t[0].short)
        XCTAssertTrue(short.text.contains(" … "))
        XCTAssertEqual(short.marks.count, 2)
        XCTAssertNil(t[1].short)
        XCTAssertEqual(words(t[1].full, \.changed), [", because"])
        XCTAssertEqual(t[1].full.carets.last, now.unicodeScalars.count)  // the sentences cut from the mark
    }

    /// Examples h and i: Resolved and Kept as is; a round that changed nothing hangs on the section above, which holds
    /// the shown round's words (the view puts them, and the field, at the end of the last section).
    func testExamplesHAndIClosed() throws {
        let h = [hist(1, "new", "We deployed hydrophones on several reefs.", sel: [[12, 40]]),
                 hist(2, "changed", "We deployed twelve hydrophones on six reefs.", sel: [[12, 43]])]
        let rc = try makeComment(["history": h, "anchor_state": "unchanged", "verdict": "verified", "verdict_note": "Reads well.",
                                  "context": ctx("We deployed twelve hydrophones on six reefs.", sel: [[12, 43]])])
        let resolved = CardContent.thread(rc, round: 3, pdfs: pdfs)
        XCTAssertEqual(resolved.map(\.event), ["as commented", "revised"])
        XCTAssertEqual(resolved[1].tags, ["unchanged in R3"])
        XCTAssertEqual(resolved[1].rounds, [2, 3])
        // the shown round's words are the card's own answer, not a past bubble
        let turns = CardContent.turns(rc, sections: resolved, round: 3)
        XCTAssertEqual(turns.map(\.id), ["r1", "s2", "q3", "now"])
        XCTAssertEqual(turns.last?.words?.text, "Reads well.")
        XCTAssertNil(turns.last?.words?.clamp)
        let m = CardModel(try makeComment(["history": h, "anchor_state": "unchanged", "verdict": "verified",
                                           "verdict_note": "Reads well.", "context": ctx("We deployed twelve hydrophones on six reefs.")]),
                          round: 3, pdfs: [:], textX: [], showChanges: true)
        XCTAssertEqual(m.status, .resolved)
        XCTAssertEqual(m.stateWord, "revised in R2")  // a fix from an earlier round is not "unchanged"
        XCTAssertEqual(m.verdictNote, "Reads well.")
        let kept = try thread(["history": [hist(1, "new", "Sampled at 96 kHz.", sel: [[11, 17]]),
                                           hist(2, "unchanged", "Sampled at 96 kHz.", sel: [[11, 17]])],
                               "anchor_state": "unchanged", "verdict": "wontfix", "context": ctx("Sampled at 96 kHz.")], round: 3)
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept[0].tags, ["unchanged in R2 and R3"])
    }

    /// The first extra case: a round whose shown sentences grew with an attached edit, and shrank again in the next
    /// round, makes no extra section, and the words that only one side shows at either end are not marked.
    func testShownExtentGrowsThenShrinks() throws {
        let b = "We use a simple policy."
        let history = [hist(1, "new", b, sel: [[9, 22]]),
                       hist(2, "unchanged", "Warm pools help. " + b, sel: [[26, 39]], changes: ["c02"])]
        let t = try thread(["history": history, "anchor_state": "unchanged", "context": ctx(b, sel: [[9, 22]])], round: 3)
        XCTAssertEqual(t.map(\.event), ["as commented", "revised"])
        XCTAssertEqual(t[1].tags, ["unchanged in R3"])
        XCTAssertEqual(t[1].full.changed, [])  // "Warm pools help." is the shown extent, not an edit
        XCTAssertEqual(t[1].full.carets, [])
        let edited = try thread(["history": history, "context": ctx("We use a static policy.", sel: [[9, 22]])], round: 3)
        XCTAssertEqual(edited.map(\.event), ["as commented", "revised", "revised"])
        XCTAssertEqual(words(edited[2].full, \.changed), ["static"])
        XCTAssertEqual(edited[2].full.carets, [])  // "Warm pools help." left the extent: no caret at the start
    }

    /// Found in a review: the student answered with a sentence before the commented one. The shown extent
    /// rule alone leaves it unmarked; the attached edit's own words mark it.
    func testASentenceAddedBeforeIsMarkedByItsAttachedEdit() throws {
        let b = "We use a simple policy."
        let now = "Pools matter because cold starts are slow. " + b
        let extra: [String: Any] = ["changes": ["c07"], "context": ctx(now, sel: [[52, 65]])]
        XCTAssertEqual(try thread(extra)[1].full.changed, [])
        let edit = AnchorContext(text: "Intro. " + now, sel: [[7, 49]])
        let t = CardContent.thread(try makeComment(extra), round: 2, edits: ["c07": edit, "c99": edit])
        XCTAssertEqual(words(t[1].full, \.changed), ["Pools matter because cold starts are slow."])
        let earlier = CardContent.thread(try makeComment(extra), round: 2, edits: ["c99": edit])  // not attached
        XCTAssertEqual(earlier[1].full.changed, [])
    }

    /// Interaction and visual reviews ("R3 · moved"): a sentence that was only moved was underlined
    /// whole as if rewritten. A move, or a change whose words read the same, marks nothing.
    func testAMoveIsNotUnderlined() throws {
        let b = "We use a simple policy."
        let moved = try makeChange(["id": "c06", "kind": "move", "old_text": b, "new_text": b, "attached_to": ["R1-01"],
                                    "unrequested": false, "context": ["before": ctx(b, sel: [[0, 23]]), "now": ctx(b, sel: [[0, 23]])]])
        let same = try makeChange(["id": "c07", "old_text": "a  b", "new_text": "a b"])
        let replaced = try makeChange([:])
        XCTAssertEqual(Set(CardContent.edits([moved, same, replaced]).keys), ["c08"])
        let extra: [String: Any] = ["anchor_state": "moved", "page": 3, "changes": ["c06"], "context": ctx(b, sel: [[9, 22]], page: 3)]
        let t = CardContent.thread(try makeComment(extra), round: 2, edits: CardContent.edits([moved]))
        XCTAssertEqual(t.map(\.event), ["as commented", "moved"])
        XCTAssertEqual(t[1].full.changed, [])
        XCTAssertFalse(t[1].revised)
    }

    func testOrphan() throws {
        let t = try thread(["anchor_state": "orphan", "context": NSNull(), "page": NSNull(), "rects": [], "text": ""])
        XCTAssertEqual(t.map(\.event), ["as commented", "no text found"])
        XCTAssertEqual(t.last?.kind, ThreadSection.Kind.none)
        XCTAssertFalse(t.last?.uncertain ?? true)  // Not found is the status
        let m = CardModel(try makeComment(["anchor_state": "orphan", "page": NSNull(), "context": NSNull()]),
                          round: 3, pdfs: [:], textX: [], showChanges: true)
        XCTAssertEqual(m.status, .notFound)
        XCTAssertEqual(m.stateWord, "not found · re-anchor")  // the mockup's row; the chip has the sign
        XCTAssertEqual(m.stateTone, .danger)
    }

    func testFallbacksWithoutContext() throws {
        let t = try thread(["context": NSNull(), "history": [hist(1, "new", nil)]])
        XCTAssertEqual(t.map(\.kind), [.source, .text])
        XCTAssertEqual(t[0].full.text, "old \\emph{quote}")
        XCTAssertEqual(t[1].full.text, "pdf words")  // the anchor's PDF text, all of it marked
        XCTAssertEqual(t[1].full.marks, [0..<9])
        XCTAssertEqual(t[1].full.changed, [])  // no diff against LaTeX source
        let none = try thread(["context": NSNull(), "text": "", "new_quote": "", "old_quote": NSNull(),
                               "history": [hist(1, "new", nil)]])
        XCTAssertEqual(none.map(\.kind), [ThreadSection.Kind.none, .none])
        let older = try thread(["anchor_state": "unchanged", "context": NSNull(),  // a state from before history[].changes
                                "history": [["round": 1, "anchor_state": "new", "verdict": NSNull(), "verdict_note": ""]]])
        XCTAssertEqual(older.count, 1)
    }

    /// UX review: a note clicked on a blank page has no text; its first section is that area of the
    /// page, and the LaTeX quote is used only when it is the creation round's.
    func testANoteOnAnEmptyArea() throws {
        let point: [String: Any] = ["text": "", "sel": [], "display": "text", "page": 22, "rects": [[300, 400, 300, 400]]]
        let history: [[String: Any]] = [
            ["round": 1, "anchor_state": "new", "verdict": NSNull(), "verdict_note": "", "page": 22, "context": point],
            hist(2, "changed", "Figure 11: Source dialogue.", sel: [[0, 10]], page: 20)]
        let t = try thread(["kind": "note", "history": history, "anchor_state": "unchanged",
                            "old_quote": "figure}{Source dialogue,", "context": ctx("Figure 11: Source dialogue.", page: 20)],
                           round: 3)
        XCTAssertEqual(t.first?.event, "note on an empty area")
        XCTAssertEqual(t.first?.kind, .image)
        XCTAssertEqual(t.first?.crop?.round, 1)
        XCTAssertEqual(t.first?.crop?.clip, [190, 340, 410, 460])
        XCTAssertFalse(t.contains { $0.kind == .source })
        let later = try thread(["context": NSNull(), "history": history.map { h -> [String: Any] in
            var h = h; h["context"] = NSNull(); return h }], round: 3)
        XCTAssertFalse(later.contains { $0.kind == .source })  // old_quote is round 2's, not the creation round's
    }

    // MARK: Trimming

    func testShortTextIsNotTrimmed() {
        XCTAssertNil(CardContent.trim(BlockText(text: String(repeating: "word ", count: 96), marks: [0..<4])))
    }

    func testLongTextKeepsTheMarkAndWholeWords() throws {
        let words = (0..<200).map { "w\($0)" }
        let text = words.joined(separator: " ")
        let start = text.range(of: "w100")!.lowerBound.utf16Offset(in: text)
        let t = try XCTUnwrap(CardContent.trim(BlockText(text: text, marks: [start..<(start + 4)], changed: [0..<2])))
        XCTAssertTrue(t.text.hasPrefix("… "))
        XCTAssertTrue(t.text.hasSuffix(" …"))
        XCTAssertLessThan(t.text.count, 400)
        XCTAssertEqual(t.marks.map { substring(t.text, $0) }, ["w100"])
        XCTAssertEqual(t.changed, [])  // outside the window
        // Every piece starts and ends at a word boundary.
        let inner = t.text.dropFirst(2).dropLast(2)
        XCTAssertTrue(inner.split(separator: " ").allSatisfy { words.contains(String($0)) })
    }

    func testAVeryLongMarkShowsItsEnds() throws {
        let text = (0..<300).map { "w\($0)" }.joined(separator: " ")
        let t = try XCTUnwrap(CardContent.trim(BlockText(text: text, marks: [0..<text.unicodeScalars.count])))
        XCTAssertTrue(t.text.hasPrefix("w0 w1"))
        XCTAssertTrue(t.text.contains(" … "))
        XCTAssertTrue(t.text.hasSuffix("w299"))
        XCTAssertEqual(t.marks.count, 2)
    }

    func testCaretsSurviveTrimming() throws {
        let text = (0..<200).map { "w\($0)" }.joined(separator: " ")
        let t = try XCTUnwrap(CardContent.trim(BlockText(text: text, carets: [500])))
        XCTAssertEqual(t.carets.count, 1)
    }

    /// Review 2026-10-24 (A3b-03): a section with no mark and no cut (a note's text) was cut to its first window, so its
    /// only underline could hide behind Show all. It now runs from the start to the last changed word.
    func testATextWithNoMarkKeepsItsUnderline() throws {
        let words = (0..<200).map { "w\($0)" }
        let text = words.joined(separator: " ")
        let start = text.range(of: "w150")!.lowerBound.utf16Offset(in: text)
        XCTAssertGreaterThan(start, CardContent.window, "past the first window")
        let t = try XCTUnwrap(CardContent.trim(BlockText(text: text, changed: [start..<(start + 4)])))
        XCTAssertEqual(t.changed.map { substring(t.text, $0) }, ["w150"])
        XCTAssertTrue(t.text.hasPrefix("w0 w1 "), "from the start, as before")
        XCTAssertTrue(t.text.contains(" … "))
        // near the start: one piece from the start, the change and the words after it
        let early = text.range(of: "w20")!.lowerBound.utf16Offset(in: text)
        let e = try XCTUnwrap(CardContent.trim(BlockText(text: text, changed: [early..<(early + 3)])))
        XCTAssertEqual(e.changed.map { substring(e.text, $0) }, ["w20"])
        XCTAssertTrue(e.text.hasPrefix("w0 ") && e.text.hasSuffix(" …") && !e.text.contains(" … "))
        // nothing changed either: the first window, as before
        let plain = try XCTUnwrap(CardContent.trim(BlockText(text: text)))
        XCTAssertTrue(plain.text.hasPrefix("w0 ") && plain.text.hasSuffix(" …"))
        XCTAssertLessThan(plain.text.unicodeScalars.count, CardContent.window + 10)
    }

    /// A context's text with its words marked inside it, and its cut as a caret only when asked (A3b-09: one rule for a
    /// card's section and a change's block).
    func testABlockFromAContext() {
        let c = AnchorContext(text: "We use a policy.", sel: [[9, 15], [3, 3], [12, 99], [-4, 2], [1]], cut: 40)
        XCTAssertEqual(BlockText(context: c, carets: true), BlockText(text: c.text, marks: [9..<15, 12..<16, 0..<2], carets: [16]))
        XCTAssertEqual(BlockText(context: c, carets: false).carets, [])
        XCTAssertEqual(BlockText(context: AnchorContext(text: "abc"), carets: true), BlockText(text: "abc"))
    }

    // MARK: Rendering

    func testRenderedSpans() {
        let t = BlockText(text: "We use a static policy.", marks: [9..<22], changed: [9..<15], carets: [2])
        let on = CardContent.render(t, color: .blue, strong: false, showChanges: true)
        XCTAssertEqual(String(on.characters), "We\u{2009}▲\u{2009} use a static policy.")
        let runs = on.runs.map { (String(on[$0.range].characters), $0.backgroundColor != nil, $0.underlineStyle != nil) }
        XCTAssertTrue(runs.contains { $0.0 == "static" && $0.1 && $0.2 })  // marked and changed
        XCTAssertTrue(runs.contains { $0.0 == " policy" && $0.1 && !$0.2 })
        XCTAssertTrue(runs.contains { $0.0 == "We" && !$0.1 && !$0.2 })
        let off = CardContent.render(t, color: .blue, strong: false, showChanges: false)
        XCTAssertEqual(String(off.characters), "We use a static policy.")
        XCTAssertFalse(off.runs.contains { $0.underlineStyle != nil })
    }

    /// Review 2026-10-24 (A3b-09): the Changes tab drew its own, smaller triangle (6.5 pt against the card's 9 pt). Both
    /// draw `CardContent.caret`.
    func testTheChangesTabDrawsTheCardsCaret() throws {
        let t = BlockText(text: "We use a policy.", marks: [9..<15], carets: [8])
        func caret(_ a: AttributedString) -> AttributedString? {
            a.runs.first { String(a[$0.range].characters).contains("▲") }.map { AttributedString(a[$0.range]) }
        }
        let card = try XCTUnwrap(caret(CardContent.render(t, color: .blue, strong: false, showChanges: true)))
        let change = try XCTUnwrap(caret(ChangeContent.render(t, style: .added)))
        let one = try XCTUnwrap(caret(CardContent.caret(Color(nsColor: Palette.changedWords))))
        for c in [card, change] {
            XCTAssertEqual(String(c.characters), String(one.characters))
            XCTAssertEqual(c.runs.first?.font, one.runs.first?.font)
            XCTAssertEqual(c.runs.first?.baselineOffset, one.runs.first?.baselineOffset)
        }
        XCTAssertNil(caret(ChangeContent.render(t, style: .removed)), "before the change, a point inserted at is not drawn")
    }

    /// The mark is a tint whatever its kind, so an underline on a card always means an edit (UX.md §3).
    func testEveryKindIsATint() throws {
        for k in MarkKind.allCases where k != .box {
            let m = CardModel(try makeComment(["kind": k.rawValue, "context": ctx("We use a static policy.", sel: [[9, 22]])]),
                              round: 2, pdfs: [:], textX: [], showChanges: true)
            let a = try XCTUnwrap(m.rendered["r1"])
            let run = try XCTUnwrap(a.runs.first { String(a[$0.range].characters) == "simple policy" }, "\(k)")
            XCTAssertNotNil(run.backgroundColor, "\(k)")
            XCTAssertNil(run.underlineStyle, "\(k)")
            XCTAssertNil(run.strikethroughStyle, "\(k)")
        }
    }

    // MARK: Card models

    func testCardModel() throws {
        let c = try makeComment(["note": "", "verdict": "reopened", "verdict_note": "again", "changes": ["c01"],
                                 "context": ctx("x y z", sel: [[0, 1]])])
        let m = CardModel(c, round: 2, pdfs: [:], textX: [], showChanges: true, emailed: [1: "Oct 9"])
        XCTAssertEqual(m.status, .followUp)
        XCTAssertEqual(m.stateWord, "follow-up")  // in For the student the row says what final.pdf asks for
        XCTAssertEqual(m.quote, "“pdf words”")
        XCTAssertEqual(m.info, CardInfo(location: "main.tex:7", method: "diff", changes: ["c01"], newImages: []))
        XCTAssertEqual(m.turns.last?.kind, .answer)
        XCTAssertNil(m.turns.last?.date)  // round 2 is open: its final.pdf has not gone out
        XCTAssertEqual(Set(m.rendered.keys), ["r1", "r2"])
        let fresh = CardModel(try makeComment(["carried": false, "anchor_state": "new", "history": []]),
                              round: 2, pdfs: [:], textX: [], showChanges: true)
        XCTAssertEqual(fresh.stateWord, "new")
        XCTAssertEqual(fresh.status, .new)
        XCTAssertEqual(fresh.accessibility, "R1-01, new, page 2. Note: n", "the word is not said twice")
        let closed = CardModel(c, round: 2, pdfs: [:], textX: [], showChanges: true, emailed: [2: "Oct 16"])
        XCTAssertEqual(closed.turns.last?.date, "sent Oct 16")
    }

    /// UX review: a carried click note stays at 0.5 by design; it is not flagged every round.
    func testACarriedClickNoteNeedsNoAttention() throws {
        let note = try makeComment(["kind": "note", "confidence": 0.5, "anchor_state": "unchanged"])
        XCTAssertFalse(note.lowConfidence)
        XCTAssertEqual(CardModel(note, round: 2, pdfs: [:], textX: [], showChanges: true).stateWord, "unchanged")
        XCTAssertTrue(try makeComment(["kind": "note", "confidence": 0.5, "anchor_state": "gone"]).lowConfidence)
        XCTAssertTrue(try makeComment(["confidence": 0.5]).lowConfidence)
    }

    func testBuildingEightyCardsIsFast() throws {
        let st = try EngineState.decode(Data(contentsOf: M2aDecodingTests.fixtures.appendingPathComponent("state-many.json")))
        XCTAssertEqual(st.comments.count, 80)
        let t0 = Date()
        let cards = st.comments.map { CardModel($0, round: 2, pdfs: [:], textX: [], showChanges: true) }
        let ms = Date().timeIntervalSince(t0) * 1000
        print("80 card models: \(String(format: "%.1f", ms)) ms (debug build)")
        XCTAssertEqual(cards.count, 80)
        XCTAssertLessThan(ms, 250)  // UX.md §10.3 asks < 10 ms for 100 in release; debug builds are much slower
    }
}

final class WordDiffSplitTests: XCTestCase {
    /// Review 2026-10-24 (A3b-05): the tokenizer classes each scalar once, ASCII ones from a table. Its tokens are
    /// those of the rule as written before, with the character sets asked for every scalar.
    func testTokensAreThoseOfTheCharacterSets() {
        func reference(_ s: String) -> [WordDiff.Token] {
            let u = Array(s.unicodeScalars), space = CharacterSet.whitespacesAndNewlines
            let edge = CharacterSet.punctuationCharacters.union(.symbols)
            var out: [WordDiff.Token] = [], i = 0
            func add(_ a: Int, _ b: Int) { out.append(.init(text: String(String.UnicodeScalarView(u[a..<b])), range: a..<b)) }
            while i < u.count {
                if space.contains(u[i]) { i += 1; continue }
                var j = i
                while j < u.count && !space.contains(u[j]) { j += 1 }
                var a = i, b = j, tail: [Int] = []
                while a < b && edge.contains(u[a]) { add(a, a + 1); a += 1 }
                while b > a && edge.contains(u[b - 1]) { b -= 1; tail.insert(b, at: 0) }
                if a < b { add(a, b) }
                tail.forEach { add($0, $0 + 1) }
                i = j
            }
            return out
        }
        let texts = ["policy. $x$. (about state-of-the-art)", "这句 很好，now。“引号”", "a\u{00A0}b\u{2009}c — “quoted” ±5 % µPa",
                     "x² ≤ y³; f(x)=∑ᵢ aᵢ → ∞", "👍🏽 emoji\tand\nlines\r\n", "", "   ", "...", "Ünïcödé façade naïve",
                     "e\u{0301} combining", "[7]. Fig. 3(a)–(c), p<0.05 & q>1 | r~2 ^ s`t' @u #v", "\u{3000}全角\u{FF0C}标点"]
        for t in texts { XCTAssertEqual(WordDiff.tokens(t), reference(t), t) }
        for v in 0..<128 {
            let s = "ab" + String(Character(Unicode.Scalar(UInt8(v)))) + "cd"
            XCTAssertEqual(WordDiff.tokens(s), reference(s), "ASCII \(v)")
        }
    }

    func testPunctuationIsSplitOff() {
        XCTAssertEqual(WordDiff.tokens("policy. $x$. (about state-of-the-art)").map(\.text),
                       ["policy", ".", "$", "x", "$", ".", "(", "about", "state-of-the-art", ")"])
        XCTAssertEqual(WordDiff.tokens("a  bc").map(\.range), [0..<1, 3..<5])
        // only x → y differs: the $ around it and the . are shared
        XCTAssertEqual(WordDiff.hunks("is $x$.", "is $y$.").hunks, [WordDiff.Hunk(steps: 2..<4, old: 4..<5, new: 4..<5)])
    }

    func testChangesAreRunsInTheNewText() {
        let new = "Both approaches reason about the lifetime of one instance."
        let d = WordDiff.changes(from: "Both approaches decide when to keep a single instance alive.", to: new)
        XCTAssertEqual(d.changed.map { substring(new, $0) }, ["reason about the lifetime of one"])
        XCTAssertEqual(d.carets, [new.unicodeScalars.count - 1])  // "alive" was left out before the "."
        let none = WordDiff.changes(from: "same words.", to: "same  words.")
        XCTAssertEqual(none.changed, [])
        XCTAssertEqual(none.carets, [])
        XCTAssertEqual(WordDiff.changes(from: "a b", to: "b").carets, [0])  // deleted at the start
    }

    /// A thread's sections (UX.md §3): words only one side shows at either end are the shown extent, not an edit,
    /// unless they are in that side's mark.
    func testEndsOutsideTheMarksAreNotChanges() {
        let old = "We use a simple policy.", new = "Warm pools help. We use a static policy. It scales."
        let all = WordDiff.changes(from: old, to: new)
        XCTAssertEqual(all.changed.map { substring(new, $0) }, ["Warm pools help.", "static", "It scales."])
        let focused = WordDiff.changes(from: old, to: new, oldFocus: [9..<22], newFocus: [26..<39])
        XCTAssertEqual(focused.changed.map { substring(new, $0) }, ["static"])
        // words removed at the end inside the old mark leave a caret; outside it, none
        let cut = WordDiff.changes(from: "A b c. D e f.", to: "A b c.", oldFocus: [0..<13], newFocus: [0..<6])
        XCTAssertEqual(cut.carets, [6])
        XCTAssertEqual(WordDiff.changes(from: "A b c. D e f.", to: "A b c.", oldFocus: [0..<6], newFocus: [0..<6]).carets, [])
        // nothing in common: only the marked words count
        let rewritten = WordDiff.changes(from: "Old words.", to: "Before. New text here.", oldFocus: [0..<10], newFocus: [8..<22])
        XCTAssertEqual(rewritten.changed.map { substring("Before. New text here.", $0) }, ["New text here."])
    }

    func testOffsetsAreUnicodeScalars() {
        let new = "这句 很好 now"
        let d = WordDiff.changes(from: "这句 now", to: new)
        XCTAssertEqual(d.changed.map { substring(new, $0) }, ["很好"])
    }
}


/// Review 2026-10-24 (A3b): the editor's undo once the app replaced its text, the Answers chips that wrap, and the ⋯
/// menu's way to add words to an answer without any. Synthetic data and the fixtures only.
@MainActor
final class CardReviewFixTests: XCTestCase {
    private let drafts = FileManager.default.temporaryDirectory.appendingPathComponent("pc-card-fixes-" + UUID().uuidString)

    override func tearDown() {
        try? FileManager.default.removeItem(at: drafts)
        super.tearDown()
    }

    private func spin(_ s: Double = 0.1) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    /// A window never ordered in, holding `view`.
    private func window<V: View>(_ view: V, width: CGFloat) -> (NSHostingView<V>, NSWindow) {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600), styleMask: [.titled],
                         backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        w.contentView = host
        spin()
        return (host, w)
    }

    private struct Field: View {
        @ObservedObject var edit: EditState
        var body: some View {
            InlineTextEditor(text: $edit.text, autoFocus: false, onSubmit: {}, onCancel: {}, onFocusLost: {})
        }
    }

    private func editor(in v: NSView) -> InlineTextEditor.EditorTextView? {
        if let t = v as? InlineTextEditor.EditorTextView { return t }
        return v.subviews.lazy.compactMap { self.editor(in: $0) }.first
    }

    /// A3b-01: Discard puts "" in the field; its typing undo, of the old text, stayed, so ⌘Z raised NSRangeException
    /// and undo in that field was dead until the card collapsed.
    func testTextTheAppPutsInTheEditorClearsItsUndo() throws {
        let edit = EditState()
        let (host, w) = window(Field(edit: edit).frame(width: 300, height: 80), width: 300)
        defer { w.close() }
        let tv = try XCTUnwrap(editor(in: host))
        let undo = try XCTUnwrap(tv.undoManager)
        tv.insertText("Still no unit.", replacementRange: NSRange(location: 0, length: 0))
        spin()
        XCTAssertEqual(edit.text, "Still no unit.")
        XCTAssertTrue(undo.canUndo, "the typing can be undone")
        edit.text = ""  // Discard
        spin()
        XCTAssertEqual(tv.string, "")
        XCTAssertFalse(undo.canUndo, "nothing left to undo of a text that is gone")
        tv.insertText("Give the unit.", replacementRange: NSRange(location: 0, length: 0))
        spin()
        XCTAssertTrue(undo.canUndo, "new typing undoes again")
        undo.undo()
        XCTAssertEqual(tv.string, "")
    }

    /// A3b-04: an edit that answers five comments cut its chips to "R…" in one row; they wrap to a second line.
    func testTheAnswersChipsWrap() throws {
        func height(_ links: [String]) throws -> CGFloat {
            let ch = model(try makeChange(["attached_to": links, "unrequested": false]))
            let edit = EditState()
            edit.round = 2
            let (host, w) = window(ChangeCard(change: ch, actions: CardActions()).environmentObject(edit).frame(width: 300),
                                   width: 300)
            defer { w.close() }
            return host.fittingSize.height
        }
        let one = try height(["R1-01"])
        XCTAssertEqual(try height(["R1-01", "R1-02"]), one, accuracy: 0.5, "two fit on one line, as before")
        XCTAssertGreaterThan(try height(["R1-01", "R1-02", "R1-03", "R1-04", "R1-05"]), one + 18, "a second line of chips")
    }

    private func makeModel() throws -> AppModel {
        _ = NSApplication.shared
        var o = LaunchOptions()
        o.fixture = StepTests.fixtures.appendingPathComponent("state-m2a.json").path
        o.drafts = drafts.path
        let m = AppModel(options: o)
        // R1-01 resolved without words (as the fixture has it); R1-02 followed up without words
        let url = StepTests.fixtures.appendingPathComponent("state-m2a.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var comments = try XCTUnwrap(json["comments"] as? [[String: Any]])
        let i = try XCTUnwrap(comments.firstIndex { $0["id"] as? String == "R1-02" })
        comments[i]["verdict_note"] = ""
        json["comments"] = comments
        m.apply(try EngineState.decode(JSONSerialization.data(withJSONObject: json)))
        return m
    }

    /// A3b-06: only Return added words to an answer without any; its ⋯ menu now has Add Closing Remark (Add Follow-up
    /// Note for a follow-up), which opens the empty editor in place, as Return does.
    func testTheMenuAddsWordsToAnAnswerWithoutAny() throws {
        let m = try makeModel()
        func titles(_ id: String) -> [String] { CardMenus.more(id, model: m).items.map(\.title) }
        XCTAssertEqual(m.comment("R1-01")?.verdict, "verified")
        XCTAssertEqual(Array(titles("R1-01").prefix(2)), ["Edit Note", "Add Closing Remark"])
        XCTAssertEqual(Array(titles("R1-02").prefix(2)), ["Edit Note", "Add Follow-up Note"])
        XCTAssertFalse(titles("R1-07").contains { $0.hasPrefix("Add ") }, "words have their Edit link")
        XCTAssertFalse(titles("R1-05").contains { $0.hasPrefix("Add ") }, "no answer yet: the card has its field")
        XCTAssertFalse(titles("R2-02").contains { $0.hasPrefix("Add ") }, "a new comment is not answered")
        XCTAssertTrue(CardMenus.perform("Add Closing Remark", in: CardMenus.more("R1-01", model: m)))
        XCTAssertEqual(m.edit.field, .remark("R1-01"))
        XCTAssertEqual(m.edit.text, "")
        m.closeEdit()
        // while the engine works the item stays enabled and says so, as Return does
        m.holdBusy(true)
        let busy = CardMenus.more("R1-02", model: m)
        XCTAssertEqual(busy.items.first { $0.title == "Add Follow-up Note" }?.isEnabled, true)
        XCTAssertTrue(CardMenus.perform("Add Follow-up Note", in: busy))
        XCTAssertNil(m.edit.field)
        XCTAssertEqual(m.panelToast.text, AppModel.stillLoading)
        m.holdBusy(false)
    }
}
