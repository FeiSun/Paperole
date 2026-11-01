import Foundation
import SwiftUI
import XCTest
@testable import Paperole

/// A change from JSON (round 2): an unrequested replace by default, with `extra` keys replacing the defaults.
func makeChange(_ extra: [String: Any]) throws -> Change {
    var base: [String: Any] = [
        "id": "c08", "kind": "replace", "file": "main.tex", "line": 60, "old_text": "34.7\\%", "new_text": "35.2\\%",
        "page": 0, "rects": [[300, 100, 330, 110]], "attached_to": [], "unrequested": true, "section": "Introduction",
        "checked": false,
        "context": ["before": ctx("Latency decreases by 34.7% on average.", sel: [[21, 26]], page: 0),
                    "now": ctx("Latency decreases by 35.2% on average.", sel: [[21, 26]], page: 0)]]
    for (k, v) in extra { base[k] = v }
    return try makeDecoder().decode(Change.self, from: JSONSerialization.data(withJSONObject: base))
}

func model(_ ch: Change, statuses: [String: Status] = [:], colors: [String: MarkColor] = [:]) -> ChangeModel {
    ChangeModel(ch, round: 2, pdfs: [1: "/r1.pdf", 2: "/r2.pdf"], textX: [], statuses: statuses, colors: colors)
}

final class ChangeTests: XCTestCase {
    func testDecoding() throws {
        let ch = try makeChange([:])
        XCTAssertEqual(ch.section, "Introduction")
        XCTAssertEqual(ch.checked, false)
        XCTAssertEqual(ch.context?.before?.sel, [[21, 26]])
        // a change from before change contexts (state-round2.json): no section, checked or context
        let old = try makeChange(["section": NSNull(), "checked": NSNull(), "context": NSNull()])
        XCTAssertNil(old.context)
        XCTAssertFalse(model(old).checked)
    }

    /// design/ui-v2 (UX.md §16): a change reads as a thread, "R1 · before" then "R2 · revised", with its words struck
    /// through in grey before it and underlined after it.
    func testAnEditReadsAsTheSentenceBeforeAndNow() throws {
        let m = model(try makeChange([:]))
        XCTAssertEqual(m.kind, .edited)
        XCTAssertEqual(m.place, "§ Introduction")
        XCTAssertEqual(m.page, 0)
        // the PDF's words, not "34.7\%": the words that differ, with three words around them, the old ones struck
        XCTAssertEqual(String(m.excerpt.characters), "Latency decreases by 34.7 35.2% on average …")
        XCTAssertTrue(m.excerpt.runs.contains { $0.strikethroughStyle != nil && String(m.excerpt[$0.range].characters) == "34.7" })
        XCTAssertEqual(m.blocks.map(\.id), ["before", "now"])
        XCTAssertEqual(m.blocks.map(\.label), ["R1 · before", "R2 · revised"])  // the page only when it is not p.1
        XCTAssertEqual(m.blocks.map(\.revised), [false, true])  // the student's side has the filled dot
        XCTAssertEqual(m.blocks[0].full.marks, [21..<25])  // the word diff's, within the change's own words
        // before: struck through, in grey; after: underlined
        let before = try XCTUnwrap(m.rendered["before"]), now = try XCTUnwrap(m.rendered["now"])
        XCTAssertTrue(before.runs.contains { $0.strikethroughStyle != nil && String(before[$0.range].characters) == "34.7"
                                             && $0.foregroundColor == Ink.secondary })
        XCTAssertTrue(now.runs.contains { $0.underlineStyle != nil && String(now[$0.range].characters) == "35.2" })
        XCTAssertFalse(now.runs.contains { $0.backgroundColor != nil })
        XCTAssertTrue(m.excerpt.runs.contains { $0.strikethroughStyle != nil && $0.foregroundColor == Ink.secondary })
        XCTAssertTrue(m.unrequested && m.links.isEmpty)
        XCTAssertEqual(m.barColor, Palette.unrequested)
        // an edit that answers a comment leads with its chip, in the comment's colour
        let linked = model(try makeChange(["attached_to": ["R1-02"], "unrequested": false]), statuses: ["R1-02": .toCheck],
                           colors: ["R1-02": .pink])
        XCTAssertEqual(linked.links, [ChangeModel.Link(id: "R1-02", status: .toCheck, color: .pink)])
        XCTAssertEqual(linked.barColor, MarkColor.pink.fill)
        XCTAssertTrue(linked.accessibility.contains("answers R1-02"))
    }

    func testInsertionAndDeletionPoints() throws {
        let added = model(try makeChange([
            "id": "c10", "kind": "insert", "old_text": "",
            "context": ["before": ctx("First. Second.", cut: 6, page: 0), "now": ctx("New one.", sel: [[0, 8]], page: 0)]]))
        XCTAssertEqual(added.kind, .added)
        XCTAssertEqual(String(added.excerpt.characters), "New one.")
        XCTAssertEqual(added.blocks.map(\.label), ["R1 · before", "R2 · added"])
        XCTAssertEqual(added.blocks[0].full.carets, [6])
        // a triangle means words removed, as on the cards: none where words were inserted
        XCTAssertEqual(String(try XCTUnwrap(added.rendered["before"]).characters), "First. Second.")
        let deleted = model(try makeChange([
            "id": "c09", "kind": "delete", "new_text": "",
            "context": ["before": ctx("Gone sentence.", sel: [[0, 14]], page: 1), "now": NSNull()]]))
        XCTAssertEqual(deleted.kind, .deleted)
        XCTAssertEqual(deleted.blocks.map(\.kind), [.text, .plain])
        XCTAssertEqual(deleted.blocks.map(\.label), ["R1 · before · p.2", "R2 · deleted"])  // not the change's page
        XCTAssertEqual(deleted.blocks[1].full.text, "Nothing is printed near it.")
        XCTAssertNotNil(deleted.excerpt.runs.first?.strikethroughStyle)
    }

    func testAMoveOrAFormattingEditThatReadsTheSameIsOneBlock() throws {
        let text = "Our simulator is event-driven."
        let moved = model(try makeChange([
            "kind": "move", "context": ["before": ctx(text, sel: [[0, 30]], page: 1), "now": ctx(text, sel: [[0, 30]], page: 2)]]))
        XCTAssertEqual(moved.kind, .moved)
        XCTAssertEqual(moved.blocks.map(\.label), ["R2 · moved from p.2"])
        XCTAssertEqual(moved.blocks[0].full.marks, [])
        let same = model(try makeChange([
            "old_text": "\\textbf{", "new_text": "\\noindent \\textbf{",
            "context": ["before": ctx(text, cut: 4, page: 0), "now": ctx(text, cut: 4, page: 0)]]))
        XCTAssertEqual(same.blocks.map(\.label), ["R2 · same words in the PDF"])
        XCTAssertEqual(String(same.excerpt.characters), "Same words in the PDF (formatting)")
    }

    func testImagesFiguresAndSourceFallbacks() throws {
        let table = model(try makeChange([
            "attached_to": ["R1-06"], "unrequested": false,
            "context": ["before": ctx("-1.21", display: "image", page: 7), "now": ctx("-1.12", display: "image", page: 7)]]),
                          statuses: ["R1-06": .resolved])
        XCTAssertEqual(table.blocks.map(\.kind), [.image, .image])
        XCTAssertEqual(table.blocks.map { $0.crop?.round }, [1, 2])
        XCTAssertEqual(table.blocks.map { $0.crop?.pdf }, ["/r1.pdf", "/r2.pdf"])
        XCTAssertEqual(String(table.excerpt.characters), "-1.21 → -1.12")
        XCTAssertEqual(table.links, [ChangeModel.Link(id: "R1-06", status: .resolved)])
        let figure = model(try makeChange(["figure": "figs/a.pdf", "context": ["before": ctx("", display: "image"),
                                                                                "now": ctx("", display: "image")]]))
        XCTAssertEqual(figure.kind, .figure)
        XCTAssertEqual(String(figure.excerpt.characters), "New image file: figs/a.pdf")
        // no PDF text on either side (an \input line): the source, labelled so
        let include = model(try makeChange(["old_text": "\\input{a}", "new_text": "\\input{b}", "section": NSNull(),
                                            "context": ["before": NSNull(), "now": NSNull()]]))
        XCTAssertEqual(include.blocks.map(\.label), ["R1 · before, in the source", "R2 · revised, in the source"])
        XCTAssertEqual(include.blocks.map(\.kind), [.source, .source])
        XCTAssertEqual(include.place, "")
    }

    func testChangesTheEngineSaysInWords() throws {
        // a change in a table is located by the table's name, not the section (there is none in a table's file)
        let table = model(try makeChange(["float": "Table 2", "section": NSNull(), "page": 7,
                                          "context": ["before": ctx("-0.85", display: "image", page: 7),
                                                      "now": ctx("-0.95", display: "image", page: 7)]]))
        XCTAssertEqual(table.place, "Table 2")
        XCTAssertNil(table.about)
        // an \input line renamed: its words, and no LaTeX source block for the side that prints nothing
        let renamed = model(try makeChange([
            "old_text": "07_conclusion", "new_text": "08_conclusion", "section": NSNull(), "page": 7,
            "about": ["kind": "file", "text": "Section file sections/07_conclusion.tex renamed to sections/08_conclusion.tex"],
            "context": ["before": NSNull(), "now": ctx("7 Discussion and Conclusion", cut: 1, page: 7)]]))
        XCTAssertEqual(String(renamed.excerpt.characters),
                       "Section file sections/07_conclusion.tex renamed to sections/08_conclusion.tex")
        XCTAssertEqual(renamed.blocks.map(\.label), ["R2 · revised"])
        XCTAssertFalse(renamed.blocks.contains { $0.kind == .source })
        // an \input of a figure commented out: a crop of the figure as round 1 printed it, nothing else
        let removed = model(try makeChange([
            "kind": "delete", "old_text": "\\input{figs/drop_two_panel}", "new_text": "", "page": NSNull(), "rects": [],
            "about": ["kind": "file", "text": "Figure 'drop_two_panel' removed"],
            "context": ["before": ctx("Figure 5: Left: mean distinct-k", display: "image", page: 6), "now": NSNull()]]))
        XCTAssertEqual(removed.kind, .deleted)
        XCTAssertEqual(String(removed.excerpt.characters), "Figure 'drop_two_panel' removed")
        XCTAssertEqual(removed.blocks.map(\.kind), [.image])
        XCTAssertEqual(removed.blocks.first?.crop?.round, 1)
        XCTAssertEqual(removed.about, "Figure 'drop_two_panel' removed")
        // formatting only: the engine's line, in secondary
        let format = model(try makeChange([
            "kind": "insert", "old_text": "", "new_text": "\\noindent",
            "about": ["kind": "formatting", "text": "Formatting only: no printed text changed in §4.1"],
            "context": ["before": ctx("Memory conditions. We evaluate four.", cut: 0), "now": ctx("Response Models.", cut: 0)]]))
        XCTAssertEqual(String(format.excerpt.characters), "Formatting only: no printed text changed in §4.1")
        XCTAssertNotNil(format.excerpt.runs.first?.foregroundColor)
        XCTAssertFalse(format.accessibility.contains("noindent"))
    }

    func testTheWordDiffOverridesAWrongSelection() throws {
        // a reference's year changed, but `sel` took in the author list
        let refBefore = "Lianmin Zheng, Wei-Lin Chiang, Ying Sheng, Tianle Li. 2023. Judging LLM-as-a-judge."
        let refNow = "Lianmin Zheng, Wei-Lin Chiang, Ying Sheng, Tianle Li. 2024. Judging LLM-as-a-judge."
        let m = model(try makeChange(["old_text": "2023", "new_text": "2024",
                                      "context": ["before": ctx(refBefore, sel: [[0, 50]]), "now": ctx(refNow, sel: [[0, 50]])]]))
        XCTAssertEqual(String(m.excerpt.characters), "… Tianle Li. 2023 2024. Judging LLM-as-a-judge …")
        XCTAssertEqual(m.blocks.map(\.full.marks), [[54..<58], [54..<58]])
        // a footnote turned into a parenthesis: the now side has no words of its own (sel []), the diff shows both
        let fn = model(try makeChange(["context": ["before": ctx("Five responses per query. 1See §4.2 for details.", sel: [[26, 30]]),
                                                   "now": ctx("Five responses per query (see §4.2 for details).", sel: [])]]))
        XCTAssertTrue(String(fn.excerpt.characters).contains("query"))
        XCTAssertFalse(fn.blocks[1].full.marks.isEmpty)
    }

    func testWordsAMacroPrintsAreShownThoughNoSideMarksThem() throws {
        // a NeurIPS checklist answer: \answerTODO prints "[TODO]", \answerYes "[Yes]"; neither side marks words of its
        // own (an analysis.json from before the engine marked them), yet the PDF's words changed
        let m = model(try makeChange(["old_text": "\\answerTODO", "new_text": "\\answerYes",
                                      "context": ["before": ctx("Answer: [TODO]", cut: 7), "now": ctx("Answer: [Yes]", cut: 7)]]))
        let excerpt = String(m.excerpt.characters)
        XCTAssertFalse(excerpt.contains("Same words"))
        XCTAssertFalse(excerpt.contains("\\"))
        XCTAssertTrue(excerpt.contains("TODO") && excerpt.contains("Yes"), excerpt)
        XCTAssertTrue(m.excerpt.runs.contains { $0.strikethroughStyle != nil && String(m.excerpt[$0.range].characters) == "TODO" })
        XCTAssertEqual(m.blocks.map(\.full.marks), [[9..<13], [9..<12]])
        // a formatting edit whose two sides are different sentences keeps the engine's line and marks nothing
        let format = model(try makeChange([
            "about": ["kind": "formatting", "text": "Formatting only: no printed text changed in §4.1"],
            "context": ["before": ctx("Memory conditions. We evaluate four.", cut: 0), "now": ctx("Response Models.", cut: 0)]]))
        XCTAssertEqual(String(format.excerpt.characters), "Formatting only: no printed text changed in §4.1")
        XCTAssertTrue(format.blocks.allSatisfy { $0.full.marks.isEmpty })
    }

    func testACommentOfThisRoundOnAnUnrequestedChangeHandlesIt() throws {
        let m = model(try makeChange(["commented_by": ["R2-07"]]), statuses: ["R2-07": .new])
        XCTAssertTrue(m.unrequested && !m.checked && m.handled)
        XCTAssertEqual(m.asked, [ChangeModel.Link(id: "R2-07", status: .new)])
        XCTAssertTrue(m.accessibility.contains("you asked in R2-07"))
        XCTAssertFalse(model(try makeChange([:])).handled)
        XCTAssertTrue(model(try makeChange(["checked": true])).handled)
    }

    /// Audit 2026-10-17: VoiceOver said "unrequested" while the tab says otherwise; the one noun since the Review page's
    /// polish is "unasked edit" (design/review-page/BRIEF.md §8).
    func testVoiceOverSaysUnaskedEdit() throws {
        let m = model(try makeChange([:]))
        XCTAssertTrue(m.accessibility.hasPrefix("c08, edited, unasked edit, "), m.accessibility)
        XCTAssertFalse(m.accessibility.contains("unrequested"))
    }

    func testCheckedState() throws {
        let m = model(try makeChange(["checked": true]))
        XCTAssertTrue(m.checked)
        XCTAssertTrue(m.accessibility.contains("checked"))
        XCTAssertNotEqual(m, model(try makeChange([:])))  // a check redraws the row
    }
}
