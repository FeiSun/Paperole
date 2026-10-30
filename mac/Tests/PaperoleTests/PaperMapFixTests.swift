import AppKit
import XCTest
@testable import Paperole

/// The paper map's fixes from the code review of 2026-10-24 (design/review/2026-10-24, batch B11): no two sections of a
/// row with one name (a section whose every short form that fits is another's name is nameless, UI-10), Fold under the axis only
/// where folding gains room (A4a-02), Show and Fold for a part the strip's round lacks (A4a-04), VoiceOver's buttons for
/// the fold and the axis (A4a-05), the follow-ups said in an open round (A4a-06), the Full Key's cell sentence (A4a-07),
/// the table's widths with many rounds (A4a-08), and the fonts made once (A4a-01). Synthetic data only.
@MainActor
final class PaperMapFixTests: XCTestCase {
    /// A paper of `rounds` rounds, each with its own sections (key, title, pages) and page count; every section has a
    /// comment or two from a fixed rule, and the latest round is open when `open`. The sections' names are the engine's:
    /// the title without its number or appendix letter.
    static func paper(_ rounds: [(sections: [(String, String, Double)], pages: Int)], open: Bool = false) throws -> PaperOverview {
        var out: [[String: Any]] = [], sections: [[String: Any]] = []
        for (k, title, _) in rounds.flatMap(\.sections) where !sections.contains(where: { $0["key"] as? String == k }) {
            let lead = title.split(separator: " ", maxSplits: 1)
            let numbered = k != "front" && lead.count == 2 && (lead[0].allSatisfy(\.isNumber) || lead[0].count == 1 && lead[0].first!.isUppercase)
            sections.append(["key": k, "title": title, "name": numbered ? String(lead[1]) : title, "gone": false])
        }
        for (i, r) in rounds.enumerated() {
            let n = i + 1, last = i == rounds.count - 1
            var spans: [[Any]] = [], heat: [[Any]] = [], x = 0.0
            for (j, (k, title, len)) in r.sections.enumerated() {
                spans.append([k, title, x, x + len])
                x += len
                heat.append([k, (j + n) % 3, n > 1 ? 1 : 0, 0, 0, 0, 0])
            }
            out.append(["n": n, "created": "2026-10-1\(n)T10:00:00+08:00", "closed": !(open && last),
                        "closed_at": open && last ? NSNull() : "2026-10-1\(n)T12:00:00+08:00" as Any,
                        "build": ["status": "ok", "pages": r.pages], "prose": "ok", "spans": spans,
                        "match": n == 1 ? NSNull() : spans.map { [$0[0], $0[0], "same", 3, 3] } as Any, "heat": heat, "edits": [],
                        "unplaced": 0, "comments": ["new": 3, "carried": 2]])
        }
        return try MapLayoutTests.decode(["papers": [["path": "/synthetic/kd", "overview": ["paper": ["title": "KD", "student": "Maya Chen"],
                                                                                              "sections": sections, "rounds": out,
                                                                                              "comments": []]]]])
    }

    /// A short ICLR-style paper (the promo demo's sections): an abstract, Analysis and a two-section appendix, too short to fold.
    static let promo: [(String, String, Double)] = [
        ("front", "Title and abstract", 0.5), ("intro", "1 Introduction", 1.4), ("related", "2 Related Work", 1.0),
        ("method", "3 Curriculum-Paced Distillation", 2.2), ("exp", "4 Experiments", 2.4), ("analysis", "5 Analysis", 1.0),
        ("concl", "6 Conclusion", 0.5), ("repro", "Reproducibility statement", 0.3), ("references", "References", 1.2),
        ("impl", "A Implementation details", 1.0), ("more", "B Additional results", 1.0)]

    /// UI-10: in a narrow window Abstract and Analysis were both "A." in one row. A section whose every form that fits
    /// its narrowest cell reads as another section's name takes the first that is not another's very name (case and
    /// "." aside), else it has no short name: its cells show its whole name where it fits, else none. No two sections
    /// of a row have one name; an appendix's lone letter stays where no other section is named so.
    func testNoTwoSectionsOfARowShareAName() throws {
        let d = try Self.paper([(Self.promo, 13), (Self.promo, 13)])
        var nameless = 0
        for w in MapLayoutTests.widths {
            let s = MapScene.build(MapInput(data: d, width: w))
            for row in s.rows {
                let named = row.cells.compactMap { c in c.name.map { (c.section, $0.text) } }
                for (i, a) in named.enumerated() {
                    for b in named[(i + 1)...] { XCTAssertNotEqual(MapRules.bare(a.1), MapRules.bare(b.1), "\(a) and \(b) in round \(row.n) at \(w)") }
                }
                for c in row.cells where c.fold == nil && !c.quiet {
                    let title = d.sectionTitle(c.section, round: row.n) ?? ""
                    let sn = try XCTUnwrap(s.names[MapScene.nameID(c.section, title)])
                    guard sn.nameless else { continue }
                    nameless += 1
                    XCTAssertNil(sn.base)
                    if let t = c.name?.text { XCTAssertTrue(t == sn.forms.first || t == sn.fixed, "\(t): a nameless section's own name only") }
                }
            }
        }
        XCTAssertGreaterThan(nameless, 0, "the narrow window has sections whose short forms all read as another's")
        // the narrowest: Analysis comes after the abstract took "A", the only form that fits it, so it has no short name;
        // nor has appendix A
        let narrow = MapScene.build(MapInput(data: d, width: MapLayoutTests.widths[2]))
        let analysis = try XCTUnwrap(narrow.names[MapScene.nameID("analysis", "5 Analysis")])
        XCTAssertTrue(analysis.nameless)
        XCTAssertEqual(narrow.names[MapScene.nameID("front", "Title and abstract")]?.base.map(MapRules.bare), "a")
        XCTAssertTrue(narrow.rows.allSatisfy { $0.cells.first { $0.section == "analysis" }?.name == nil })
        XCTAssertEqual(narrow.names[MapScene.nameID("impl", "A Implementation details")]?.nameless, true)
        // the names over a hovered row still name them, appendix A with its letter
        let hover = narrow.hoverNames(2, d).map(\.text)
        XCTAssertTrue(hover.contains { $0.hasPrefix("An") }, "\(hover)")
        XCTAssertTrue(hover.contains { $0.hasPrefix("A Im") }, "\(hover)")
        // at 1280 pt appendix A keeps its letter beside the abstract's "Abs." (a cut that is not the same name)
        let mid = MapScene.build(MapInput(data: d, width: MapLayoutTests.widths[1]))
        XCTAssertEqual(mid.names[MapScene.nameID("front", "Title and abstract")]?.base, "Abs.")
        XCTAssertTrue(mid.rows.allSatisfy { $0.cells.first { $0.section == "impl" }?.name?.text == "A" })
        // a wide window names every section as before
        let wide = MapScene.build(MapInput(data: d, width: MapLayoutTests.widths[0]))
        XCTAssertTrue(wide.names.values.allSatisfy { !$0.nameless })
        XCTAssertTrue(wide.rows.allSatisfy { $0.cells.allSatisfy { $0.name != nil } })
    }

    func testANamelessSectionShowsOnlyItsOwnName() {
        let w = MapFont.name.width
        let analysis = MapScene.SectionName(forms: MapRules.labels("Analysis"), base: nil, fixed: nil, nameless: true)
        XCTAssertEqual(analysis.fit(.name, w("Analysis")), "Analysis", "its whole name where it fits")
        XCTAssertNil(analysis.fit(.name, w("Analysis") - 1), "no cut name")
        XCTAssertNil(analysis.fit(.name, w("A.") + 1))
        let concl = MapScene.SectionName(forms: MapRules.labels("Conclusion"), base: nil, fixed: "Concl.", nameless: true)
        XCTAssertEqual(concl.fit(.name, w("Concl.") + 0.5), "Concl.", "or its fixed short form, which is always its own")
        XCTAssertNil(concl.fit(.name, w("Con.") + 0.5))
        // not nameless, without a base (nothing fits its narrowest): as much as fits, as before
        let open = MapScene.SectionName(forms: MapRules.labels("Analysis"), base: nil, fixed: nil)
        XCTAssertEqual(open.fit(.name, w("A.") + 0.5), "A.")
    }

    /// A4a-02: a paper whose longest round has no appendix gains nothing from folding another round's: nothing folds,
    /// and the axis offers no Fold that would do nothing.
    func testNoFoldUnderTheAxisWhenFoldingGainsNothing() throws {
        let body: [(String, String, Double)] = [("front", "Title and abstract", 0.5), ("intro", "1 Introduction", 9.5),
                                                ("results", "2 Results", 8), ("references", "References", 2)]
        let appendix: [(String, String, Double)] = [("a", "A Proofs", 5), ("b", "B More results", 5)]
        let d = try Self.paper([(body + [("methods", "3 Methods", 20)], 40), (body + appendix, 30)])
        for w in MapLayoutTests.widths {
            let s = MapScene.build(MapInput(data: d, width: w))
            XCTAssertTrue(s.plan.folded.isEmpty, "the 40-page round sets the scale at \(w)")
            XCTAssertTrue(s.plan.foldable.isEmpty, "at \(w)")
            XCTAssertTrue(s.axisParts.isEmpty, "no Fold that does nothing at \(w)")
            XCTAssertFalse(s.hits.contains { if case .foldPart = $0.target { return true }; return false })
        }
        // shown by the viewer, it keeps its Fold: a click on it folds what was shown
        let shown = MapScene.build(MapInput(data: d, width: MapLayoutTests.widths[0], shownParts: [.appendix]))
        XCTAssertEqual(shown.plan.foldable, [.appendix])
        XCTAssertEqual(shown.axisParts.map(\.shown), [true])
    }

    /// A4a-04: the latest round (the strip's) has no appendix; the older rows fold theirs, and the axis says its pages
    /// and Show under the top row that has it; shown, its bracket and Fold.
    func testShowAndFoldForAPartTheStripsRoundLacks() throws {
        let body: [(String, String, Double)] = [("front", "Title and abstract", 0.5), ("intro", "1 Introduction", 6.5),
                                                ("results", "2 Results", 11), ("references", "References", 2)]
        let appendix: [(String, String, Double)] = [("a", "A Proofs", 5), ("b", "B More results", 5)]
        let d = try Self.paper([(body + appendix, 30), (body + appendix, 30), (body, 20)])
        for w in MapLayoutTests.widths {
            let s = MapScene.build(MapInput(data: d, width: w))
            XCTAssertEqual(s.plan.folded, [.appendix], "at \(w)")
            let part = try XCTUnwrap(s.axisParts.first, "Show at \(w)")
            XCTAssertFalse(part.shown)
            XCTAssertEqual(part.text.text + part.link.text, "pp. 21–30 · Show")
            XCTAssertEqual(s.target(at: CGPoint(x: part.link.rect.midX, y: part.link.rect.midY)), .showPart(.appendix))
            // under the block of the top row that has it (round 2)
            let block = try XCTUnwrap(s.rows.first { $0.n == 2 }?.cells.first { $0.fold == .appendix }?.rect)
            XCTAssertEqual((part.text.rect.minX + part.link.rect.maxX) / 2, block.midX, accuracy: 1, "at \(w)")
            for t in s.axis { XCTAssertFalse(t.rect.intersects(part.text.rect) || t.rect.intersects(part.link.rect), "\(t.text) at \(w)") }
            let shown = MapScene.build(MapInput(data: d, width: w, shownParts: [.appendix]))
            let fold = try XCTUnwrap(shown.axisParts.first, "Fold at \(w)")
            XCTAssertTrue(fold.shown)
            XCTAssertEqual(fold.text.text + fold.link.text, "Appendix A–B · pp. 21–30 · Fold", "round 2's sections name it")
            XCTAssertEqual(shown.target(at: CGPoint(x: fold.link.rect.midX, y: fold.link.rect.midY)), .foldPart(.appendix))
        }
    }

    /// A4a-05: VoiceOver reached neither the older rounds folded, their Fold, nor the axis's Show and Fold: each is a
    /// button now, said in words, where a click on it lands.
    func testVoiceOverReachesTheFoldAndTheAxis() throws {
        let stress = try MapLayoutTests.stress()
        let folded = MapScene.build(MapInput(data: stress, width: MapLayoutTests.widths[1], fold: 3))
        let unfold = try XCTUnwrap(MapSpeech.controls(folded).first { $0.target == .unfold })
        XCTAssertTrue(unfold.label.hasPrefix("Rounds 1 to 3, 3 older rounds folded: "), unfold.label)
        XCTAssertTrue(unfold.label.hasSuffix(" written, \(count(stress.rounds.prefix(3).reduce(0) { $0 + ($1.edits?.count ?? 0) }, "edit")). Show all 8 rounds"),
                      unfold.label)
        XCTAssertFalse(unfold.label.contains("·"))
        let unfolded = MapScene.build(MapInput(data: stress, width: MapLayoutTests.widths[1], fold: 3, unfold: true))
        XCTAssertEqual(MapSpeech.controls(unfolded).map(\.label), ["Fold the older rounds"])
        let sonar = try MapFoldTests.sonar()
        let s = MapScene.build(MapInput(data: sonar, width: MapLayoutTests.widths[0]))
        XCTAssertEqual(MapSpeech.controls(s).map(\.label), ["Show the appendix, pages 17 to 29"])
        let shown = MapScene.build(MapInput(data: sonar, width: MapLayoutTests.widths[0], shownParts: [.appendix]))
        XCTAssertEqual(MapSpeech.controls(shown).map(\.label), ["Fold the appendix, Appendix A to E, pages 17 to 29"])
        for scene in [folded, unfolded, s, shown] {
            for c in MapSpeech.controls(scene) {
                XCTAssertEqual(scene.target(at: CGPoint(x: c.rect.midX, y: c.rect.midY)), c.target, c.label)
            }
        }
        XCTAssertTrue(MapSpeech.controls(MapScene.build(MapInput(data: try MapLayoutTests.kelp(), width: MapLayoutTests.widths[0]))).isEmpty)
    }

    /// A4a-06: an open round's sentence says the follow-ups so far, as its readout does.
    func testAnOpenRoundSaysItsFollowUps() throws {
        var json = try MapLayoutTests.kelpJSON()
        MapLayoutTests.edit(&json) { o in
            var rounds = o["rounds"] as! [[String: Any]]
            var c = rounds[3]["comments"] as! [String: Any]
            c["follow_up"] = 1
            rounds[3]["comments"] = c
            o["rounds"] = rounds
        }
        let d = try MapLayoutTests.decode(json)
        let r4 = try XCTUnwrap(d.round(4))
        XCTAssertFalse(r4.isClosed)
        let row = MapSpeech.row(d, r4, student: "Tomás")
        XCTAssertTrue(row.contains("You: 2 resolved so far, 1 followed up so far, 10 to check."), row)
        XCTAssertTrue(MapScene.readoutColumns(d, r4, first: false, columns: 3, ready: false)[2].0.contains("↩ 1"), "as the readout")
    }

    /// A4a-07: since 2026-10-20 a short section is drawn wider than its length; the Full Key says so.
    func testTheFullKeySaysShortSectionsAreWider() {
        let cells = MapKey.items[0].1
        XCTAssertFalse(cells.contains("its width is its length"))
        XCTAssertTrue(cells.contains("a short section is drawn wider"))
        XCTAssertTrue(cells.contains("at one page scale for every row"))
    }

    /// A4a-08: with many rounds in a narrow window the names give way first, then the grid scrolls sideways rather than
    /// running past the overview's right edge.
    func testTheTableFitsOrScrolls() {
        let narrow = MapLayoutTests.widths[2]
        // nine rounds at 960 pt: they ran 28 pt past the edge; the names now give way
        let nine = MapTableView.widths(narrow, rounds: 9)
        XCTAssertEqual(nine.grid, narrow)
        XCTAssertLessThanOrEqual(nine.name + 74 + 9 * nine.column, narrow + 0.01)
        XCTAssertGreaterThanOrEqual(nine.column, 52)
        // twelve: the names at their least, the columns at theirs, and a grid wider than the overview (it scrolls)
        let twelve = MapTableView.widths(narrow, rounds: 12)
        XCTAssertEqual(twelve.name, 100)
        XCTAssertEqual(twelve.column, 52)
        XCTAssertEqual(twelve.grid, 100 + 74 + 12 * 52)
        // a wide window, as before
        let wide = MapTableView.widths(MapLayoutTests.widths[0], rounds: 4)
        XCTAssertEqual(wide.name, 240)
        XCTAssertEqual(wide.column, 150)
        XCTAssertEqual(wide.grid, MapLayoutTests.widths[0])
        for w in MapLayoutTests.widths {
            for n in 1...20 {
                let t = MapTableView.widths(w, rounds: n)
                XCTAssertGreaterThanOrEqual(t.grid, t.name + 74 + CGFloat(n) * t.column - 0.01, "\(n) rounds at \(w)")
                XCTAssertGreaterThanOrEqual(t.name, 100)
            }
        }
    }

    /// A4a-01: each style's font is made once, and a heading's number is still found.
    func testFontsAreMadeOnce() {
        for f in MapFont.allCases { XCTAssertTrue(f.nsFont === f.nsFont, "\(f)") }
        XCTAssertEqual(MapFont.number.nsFont.pointSize, 12.5)
        XCTAssertEqual(Outline.numbers(["2.1 Setup", "A Details", "B More", "Results"]), ["2.1", "A", "B", nil])
    }
}
