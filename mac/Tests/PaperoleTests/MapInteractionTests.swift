import AppKit
import SwiftUI
import XCTest
@testable import Paperole

/// The paper map's interactions (OVERVIEW-v2 §5.1, §7), as pure functions where they can be: the keys that move what
/// is followed, the panel under the map for each kind, the table view, the sentences VoiceOver reads, a comment's
/// previewed path, what a point on the strip is over, the "n carried" pills kept apart; and through the model: the
/// keys routed while the map has them, Return into Review and Back with the selection kept, the table's switch, the
/// help tags. Synthetic data only (Fixtures/overview-kelp.json, the engine's reply for a paper it built; the M2a
/// fixture).
final class MapInteractionTests: XCTestCase {
    private func kelp() throws -> PaperOverview { try MapLayoutTests.kelp() }

    // MARK: Keys

    func testArrowsMoveAlongARoundAndAcrossRounds() throws {
        let d = try kelp()
        func mv(_ k: MapKeys.Key, _ s: OverviewItem?, strip: Int? = 4) -> MapKeys.Move? { MapKeys.move(k, from: s, data: d, strip: strip) }
        // nothing followed: the strip round's first section
        XCTAssertEqual(mv(.down, nil)?.item, .section("front", round: 4))
        XCTAssertEqual(mv(.right, nil, strip: 2)?.item, .section("front", round: 2))
        // along a round, without wrapping
        XCTAssertEqual(mv(.right, .section("front", round: 4))?.item, .section("introduction", round: 4))
        XCTAssertEqual(mv(.left, .section("introduction", round: 4))?.item, .section("front", round: 4))
        XCTAssertNil(mv(.left, .section("front", round: 4)))
        XCTAssertNil(mv(.right, .section("conclusion", round: 4)), "the last section")
        // across rounds: the same key, else where its paragraphs went, else the nearest place
        XCTAssertEqual(mv(.down, .section("methods", round: 4))?.item, .section("methods", round: 3))
        XCTAssertEqual(mv(.up, .section("methods", round: 3))?.item, .section("methods", round: 4))
        XCTAssertEqual(mv(.up, .section("study-area", round: 1))?.item, .section("methods", round: 2), "merged into Methods")
        XCTAssertEqual(mv(.down, .section("analysis", round: 3))?.item, .section("results", round: 2), "split from Results")
        XCTAssertEqual(mv(.down, .section("conclusion", round: 4))?.item, .section("extra", round: 3), "added: the nearest place")
        XCTAssertNil(mv(.up, .section("methods", round: 4)), "no newer round")
        // a round
        XCTAssertEqual(mv(.up, .round(2))?.item, .round(3))
        XCTAssertEqual(mv(.down, .round(2))?.item, .round(1))
        XCTAssertNil(mv(.up, .round(4)))
        XCTAssertEqual(mv(.right, .round(2))?.item, .section("front", round: 2))
        XCTAssertEqual(mv(.left, .round(2))?.item, .section("extra", round: 2))
        // a page
        XCTAssertEqual(mv(.right, .page(round: 4, page: 0))?.item, .page(round: 4, page: 1))
        XCTAssertNil(mv(.left, .page(round: 4, page: 0)))
        XCTAssertEqual(mv(.down, .page(round: 4, page: 3))?.item, .page(round: 3, page: 3))
        // a comment: ← → the strip round's comments in their order on the page; ↑ ↓ the same comment through its rounds
        XCTAssertEqual(mv(.down, .comment("R1-04")), MapKeys.Move(item: .comment("R1-04"), strip: 3))
        XCTAssertEqual(mv(.down, .comment("R1-04"), strip: 1)?.strip, nil, "its first round")
        XCTAssertNil(mv(.up, .comment("R1-04")))
        let r4 = d.comments.compactMap { c in c.step(in: 4).flatMap { st in st.pos.map { (c.id, $0) } } }.sorted { $0.1 < $1.1 }.map(\.0)
        let i = try XCTUnwrap(r4.firstIndex(of: "R1-04"))
        XCTAssertEqual(mv(.right, .comment("R1-04"))?.item, .comment(r4[i + 1]))
        XCTAssertEqual(mv(.right, .comment("R1-04"))?.strip, 4)
    }

    // MARK: The panel

    func testTheSectionPanelListsItsCommentsOnce() throws {
        let d = try kelp()
        let p = try XCTUnwrap(OverviewPanel.make(.section("methods", round: 4), data: d, strip: 4, student: "Tomás"))
        XCTAssertEqual(p.title, d.sectionTitle("methods", round: 4))
        guard case .lines(let lines, let edits, let empty) = p.body else { return XCTFail("lines") }
        let ever = d.comments.filter { c in c.path.contains { $0.section == "methods" } }.map(\.id)
        XCTAssertEqual(lines.map(\.id), ever, "each once, in their order")
        XCTAssertEqual(Set(lines.map(\.id)).count, lines.count)
        let open = d.comments.filter { ever.contains($0.id) && !["resolved", "kept"].contains($0.path.last?.answer ?? "") }.count
        XCTAssertTrue(p.meta.hasPrefix("\(ever.count) comments over all rounds, each counted once · \(open) still open"))
        XCTAssertTrue(p.meta.hasSuffix("called Methods until Round 3"), p.meta)
        XCTAssertEqual(lines.first { $0.id == "R1-04" }?.status, "R1–R4 · ○ to check")
        XCTAssertEqual(lines.first { $0.id == "R1-07" }?.status, "R1–R2 · ✓ resolved")
        XCTAssertEqual(lines.first { $0.id == "R1-05" }?.status, "R1–R3 · kept as is")
        XCTAssertEqual(lines.first { $0.id == "R1-04" }?.text, "Map please.")
        // the edits nobody asked for that wait in the open round, in this section
        XCTAssertEqual(edits.map(\.id), (d.round(4)?.edits ?? []).filter { $0.section == "methods" && $0.unrequested }.map(\.id))
        XCTAssertTrue(edits.allSatisfy { $0.status.contains("○ to check") })
        XCTAssertNil(empty)
        XCTAssertEqual(p.buttons, [OverviewPanel.Button(title: "Open Round 4 at Materials and methods", action: .review(.section("methods", round: 4)))])
        // a section that left the paper: Review opens at its last round
        let gone = try XCTUnwrap(OverviewPanel.make(.section("study-area", round: 1), data: d, strip: 4, student: ""))
        XCTAssertEqual(gone.buttons.first?.action, .review(.section("study-area", round: 1)))
    }

    func testTheRoundPanelGroupsItsComments() throws {
        let d = try kelp()
        for r in d.rounds {
            let p = try XCTUnwrap(OverviewPanel.make(.round(r.n), data: d, strip: 4, student: "Tomás"))
            guard case .groups(let groups) = p.body else { return XCTFail("groups") }
            let chips = groups.flatMap(\.chips).map(\.id)
            XCTAssertEqual(chips.count, Set(chips).count, "each comment in one group")
            XCTAssertEqual(chips.count, r.comments?.present, "Round \(r.n): every comment of the round")
            XCTAssertEqual(p.buttons.first?.title, "Open Round \(r.n) in Review" + (r.isClosed ? " (read-only)" : ""))
        }
        let r4 = try XCTUnwrap(OverviewPanel.make(.round(4), data: d, strip: 4, student: "Tomás"))
        guard case .groups(let g4) = r4.body else { return XCTFail("groups") }
        XCTAssertEqual(g4.first { $0.glyph == .toCheck }?.chips.count, d.round(4)?.comments?.toCheck)
        XCTAssertEqual(g4.first { $0.label.hasPrefix("Edits nobody asked for") }?.edits.count, d.round(4)?.edits?.filter(\.unrequested).count)
        XCTAssertTrue(r4.meta.contains("open · Tomás: "), r4.meta)
        let r2 = try XCTUnwrap(OverviewPanel.make(.round(2), data: d, strip: 4, student: "Tomás"))
        guard case .groups(let g2) = r2.body else { return XCTFail("groups") }
        XCTAssertEqual(g2.map(\.label).first, "New in this round · 5")
        XCTAssertTrue(g2.map(\.label).contains("Left open · \(d.round(2)?.comments?.leftOpen ?? 0)"))
        XCTAssertFalse(g2.contains { !$0.edits.isEmpty }, "a closed round's edits are not waiting")
        let r1 = try XCTUnwrap(OverviewPanel.make(.round(1), data: d, strip: 4, student: "Tomás"))
        XCTAssertTrue(r1.meta.hasSuffix("words · 4 pages"), r1.meta)
    }

    func testThePagePanel() throws {
        let d = try kelp()
        let p = try XCTUnwrap(OverviewPanel.make(.page(round: 4, page: 1), data: d, strip: 4, student: ""))
        XCTAssertEqual(p.title, "Page 2 · Round 4")
        guard case .lines(let lines, _, _) = p.body else { return XCTFail("lines") }
        XCTAssertEqual(Set(lines.map(\.id)), Set(d.comments.filter { $0.step(in: 4)?.page == 1 && $0.step(in: 4)?.state == "placed" }.map(\.id)))
        XCTAssertTrue(p.meta.hasPrefix(d.round(4)!.spans!.filter { $0.start < 2 && $0.end > 1 }.map(\.title).joined(separator: ", ")))
        XCTAssertEqual(p.buttons.first?.action, .review(.page(round: 4, page: 1)))
    }

    /// A comment: where it is, its words, how it ended, and what the student changed for it, round by round.
    func testTheCommentPanelSaysWhatChangedForIt() throws {
        let d = try kelp()
        let p = try XCTUnwrap(OverviewPanel.make(.comment("R1-04"), data: d, strip: 4, student: "Tomás"))
        XCTAssertEqual(p.title, "R1-04")
        XCTAssertEqual(p.buttons.map(\.title), ["Follow Materials and methods", "Open R1-04 in Round 4"])
        guard case .comment(let detail) = p.body else { return XCTFail("comment") }
        XCTAssertEqual(detail.quote, "Map please.")
        XCTAssertTrue(detail.facts.hasPrefix("Written in Round 1"))
        XCTAssertTrue(detail.facts.hasSuffix("on the map for 4 rounds · ○ to check in Round 4"), detail.facts)
        XCTAssertEqual(detail.steps.map(\.round), [2, 3, 4])
        XCTAssertEqual(detail.steps.map(\.answer), ["left open", "↩ followed up", "○ to check"])
        XCTAssertEqual(detail.steps.map(\.what), ["unchanged", "not asked", "unchanged"], "UI v4: the response bar's words")
        // edits made for it: their number, words and first words
        let e = try XCTUnwrap(d.round(4)?.edits?.first { $0.attachedTo.contains("R2-03") })
        let q = try XCTUnwrap(OverviewPanel.make(.comment("R2-03"), data: d, strip: 4, student: "Tomás"))
        guard case .comment(let dq) = q.body, let s4 = dq.steps.last else { return XCTFail("comment") }
        XCTAssertEqual(s4.what, "1 edit")
        XCTAssertEqual(s4.added, e.added)
        XCTAssertEqual(s4.first, d.round(4)?.excerpts?[e.id])
        XCTAssertEqual(s4.answer, "✓ resolved")
        // its passage deleted
        let g = try XCTUnwrap(OverviewPanel.make(.comment("R1-15"), data: d, strip: 4, student: "Tomás"))
        guard case .comment(let dg) = g.body else { return XCTFail("comment") }
        XCTAssertEqual(dg.steps.last?.what, "passage deleted")
        XCTAssertTrue(g.meta.hasSuffix("passage deleted"), g.meta)
        // the strip's round decides where Review opens, as a double click on it
        XCTAssertEqual(OverviewPanel.make(.comment("R1-12"), data: d, strip: 4, student: "")?.buttons.last?.title, "Open R1-12 in Round 3")
        XCTAssertEqual(OverviewPanel.make(.comment("R1-12"), data: d, strip: 2, student: "")?.buttons.last?.title, "Open R1-12 in Round 2")
    }

    // MARK: The table

    func testTheTableHasTheMapsNumbers() throws {
        for d in [try kelp(), try MapLayoutTests.stress(), try OverviewDataTests.overviewFixture()] {
            let t = MapTable.make(d, selection: nil, student: "Ana")
            XCTAssertEqual(t.columns.map(\.n), d.rounds.map(\.n), "oldest first")
            XCTAssertEqual(Set(t.rows.map(\.key)), Set(d.rounds.flatMap { ($0.spans ?? []).map(\.section) }))
            for (i, r) in d.rounds.enumerated() where r.hasSections {
                XCTAssertEqual(t.rows.map { $0.cells[i].count }.reduce(0, +) + (r.unplaced ?? MapScene.unplacedCount(d, r.n)),
                               r.comments?.present, "Round \(r.n): the cells and the unplaced add up to its comments")
                for h in r.heat ?? [] {
                    XCTAssertEqual(t.rows.first { $0.key == h.section }?.cells[i].count, h.present)
                }
            }
            XCTAssertEqual(Array(t.rows.map(\.key).filter { k in d.latest?.spans?.contains { $0.section == k } == true }),
                           d.latest?.spans?.map(\.section), "the latest round's order")
        }
        let d = try kelp()
        let t = MapTable.make(d, selection: .comment("R1-04"), student: "Tomás")
        let extra = try XCTUnwrap(t.rows.first { $0.key == "extra" })
        XCTAssertEqual(extra.cells.map(\.absent), [nil, nil, nil, "removed"])
        let study = try XCTUnwrap(t.rows.first { $0.key == "study-area" })
        XCTAssertEqual(study.cells.map(\.absent), [nil, "merged", "", ""])
        XCTAssertEqual(t.rows.firstIndex { $0.key == "study-area" }, t.rows.firstIndex { $0.key == "methods" }.map { $0 - 1 },
                       "a section merged away: over the one it went into")
        XCTAssertEqual(t.rows.firstIndex { $0.key == "extra" }, t.rows.firstIndex { $0.key == "discussion" }.map { $0 + 1 },
                       "a section removed at the end: after the one before it")
        XCTAssertEqual(t.rows.first { $0.key == "conclusion" }?.cells.map(\.absent), ["", "", "", nil])
        XCTAssertEqual(t.rows.filter { $0.cells.contains(where: \.holds) }.map(\.key).sorted(), ["methods", "study-area"])
        XCTAssertEqual(t.totals.first { $0.label == "To check" }?.values.last, "○ \(d.round(4)?.comments?.toCheck ?? 0)")
        XCTAssertEqual(t.totals.first { $0.label == "Comments" }?.values.first, "\(d.round(1)?.comments?.present ?? 0) · all new")
    }

    // MARK: VoiceOver

    func testVoiceOverSentences() throws {
        let d = try kelp()
        let r4 = try XCTUnwrap(d.round(4))
        let row = MapSpeech.row(d, r4, student: "Tomás")
        XCTAssertTrue(row.hasPrefix("Round 4, Oct 19, open. "), row)
        XCTAssertFalse(row.contains("→"), "no arrows said")
        XCTAssertTrue(row.contains("open. \(r4.comments?.present ?? 0) comments, none new."), row)
        XCTAssertTrue(row.contains("Tomás: "), row)
        XCTAssertTrue(row.contains("\(r4.comments?.toCheck ?? 0) to check"), row)
        XCTAssertTrue(row.contains("Materials and methods 6"), row)
        XCTAssertTrue(MapSpeech.row(d, try XCTUnwrap(d.round(1)), student: "Tomás").contains("all new."))
        let cell = MapSpeech.cell(d, "methods", 4)
        XCTAssertTrue(cell.hasPrefix("Materials and methods, Round 4: 6 comments, none new, 5 to check."), cell)
        XCTAssertTrue(cell.contains("Pages 1 to 2."), cell)
        XCTAssertTrue(MapSpeech.item(.page(round: 4, page: 0), d, strip: 4, student: "").hasPrefix("Page 1 of Round 4: "))
        XCTAssertTrue(MapSpeech.item(.comment("R1-04"), d, strip: 4, student: "").hasPrefix("R1-04 · "))
        // a row without sections says why
        var json = try MapLayoutTests.kelpJSON()
        var papers = try XCTUnwrap(json["papers"] as? [[String: Any]])
        var o = try XCTUnwrap(papers[0]["overview"] as? [String: Any])
        var rounds = try XCTUnwrap(o["rounds"] as? [[String: Any]])
        rounds[1]["prose"] = "pending"
        o["rounds"] = rounds; papers[0]["overview"] = o; json["papers"] = papers
        let p = try MapLayoutTests.decode(json)
        XCTAssertTrue(MapSpeech.row(p, try XCTUnwrap(p.round(2)), student: "").hasSuffix("Sections not known yet."))
    }

    // MARK: The map

    /// A comment hovered is previewed through the places its path would have: a point in each shown round, the unplaced
    /// cap, a point on the fold for the rounds folded.
    func testAPreviewGoesWhereThePathWould() throws {
        let d = try kelp()
        let w = MapLayoutTests.widths[0]
        let c = try XCTUnwrap(d.comment("R1-04"))
        let plain = MapScene.build(MapInput(data: d, width: w))
        let followed = MapScene.build(MapInput(data: d, width: w, selection: .comment("R1-04")))
        let path = try XCTUnwrap(followed.paths.first)
        let preview = plain.previewPoints(c)
        XCTAssertEqual(preview.count, 4)
        XCTAssertEqual(preview.map(\.x), path.points.map(\.at.x), "the same places")
        let folded = MapScene.build(MapInput(data: d, width: w, fold: 2))
        let pf = folded.previewPoints(c)
        XCTAssertEqual(pf.count, 3, "two rows shown and the fold")
        XCTAssertEqual(pf.first?.y, folded.geometry.rowY(2) + 11)
    }

    /// Two bands into one section (a merge) carry comments each: their pills sit side by side, never over each other.
    func testCarriedPillsNeverOverlap() throws {
        for d in [try kelp(), try MapLayoutTests.stress()] {
            for w in MapLayoutTests.widths {
                for s in MapLayoutTests.selections(d) {
                    let m = MapScene.build(MapInput(data: d, width: w, selection: s))
                    let pills = m.carriedPills.map(\.0)
                    for i in pills.indices {
                        for j in pills.indices where j > i { XCTAssertFalse(pills[i].intersects(pills[j]), "\(String(describing: s)) at \(w)") }
                        XCTAssertGreaterThanOrEqual(pills[i].minX, MapGeometry.mapX)
                        XCTAssertLessThanOrEqual(pills[i].maxX, m.geometry.mapRight + 0.5)
                    }
                }
            }
        }
        let m = MapScene.build(MapInput(data: try kelp(), width: MapLayoutTests.widths[1], selection: .section("methods", round: 2)))
        XCTAssertEqual(m.carriedPills.count, 4, "two into Methods in Round 2, one into each round above")
        XCTAssertTrue(m.carriedPills.allSatisfy { abs($0.1.x - $0.0.midX) < 0.01 }, "the words in their pill")
    }

    /// A label set beside its band has a short leader to it, and the leader crosses no other label or pill.
    func testLeadersCrossNoOtherLabel() throws {
        for d in [try kelp(), try MapLayoutTests.stress()] {
            for w in MapLayoutTests.widths {
                for s in MapLayoutTests.selections(d) {
                    let m = MapScene.build(MapInput(data: d, width: w, selection: s))
                    for (i, l) in m.labels.enumerated() {
                        guard let (a, b) = l.leader else { continue }
                        let line = CGRect(x: min(a.x, b.x), y: a.y - 0.5, width: abs(b.x - a.x), height: 1)
                        for (j, o) in m.labels.enumerated() where j != i {
                            XCTAssertFalse(o.text.rect.intersects(line), "\(l.text.text) over \(o.text.text), \(String(describing: s)) at \(w)")
                        }
                        XCTAssertFalse(m.carriedPills.contains { $0.0.intersects(line) })
                    }
                }
            }
        }
    }

    /// A click on a comment's mark in a thumbnail follows the comment; elsewhere on the page, the page.
    func testWhatAPointOnTheStripIsOver() {
        let geo = StripGeometry(width: 800, pages: 4, aspect: 612.0 / 792)
        let mark = PaperOverview.Mark(page: 1, kind: "comment", rect: CGRect(x: 100, y: 200, width: 120, height: 12), id: "R1-04")
        let change = PaperOverview.Mark(page: 1, kind: "change", rect: CGRect(x: 100, y: 400, width: 120, height: 12), id: "c01")
        let size: (Int) -> CGSize? = { _ in CGSize(width: 612, height: 792) }
        let k = geo.thumbHeight / 792
        let on = CGPoint(x: geo.thumbX(1) + 160 * k, y: 206 * k)
        XCTAssertEqual(geo.target(at: on, marks: [mark, change], pageSize: size), .comment("R1-04", page: 1))
        XCTAssertEqual(geo.target(at: CGPoint(x: on.x, y: 406 * k), marks: [mark, change], pageSize: size), .page(1), "a change is not followed")
        XCTAssertEqual(geo.target(at: CGPoint(x: geo.thumbX(2) + 5, y: 5), marks: [mark], pageSize: size), .page(2))
        XCTAssertEqual(geo.target(at: CGPoint(x: on.x, y: geo.thumbHeight + 8), marks: [mark], pageSize: size), .page(1), "its number")
        XCTAssertEqual(geo.target(at: on, marks: [mark], pageSize: { _ in nil }), .page(1), "not drawn yet")
        XCTAssertNil(geo.target(at: CGPoint(x: 900, y: 5), marks: [], pageSize: size))
    }
}

/// The interactions through the model: keys while the map has them, Return into Review and Back, the table's switch,
/// the help tags.
@MainActor
final class MapInteractionModelTests: XCTestCase {
    private var drafts: URL!

    override func setUpWithError() throws {
        drafts = FileManager.default.temporaryDirectory.appendingPathComponent("pc-mapi-" + UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: drafts)
    }

    private func makeModel() -> AppModel {
        _ = NSApplication.shared
        var o = LaunchOptions()
        o.fixture = StepTests.fixtures.appendingPathComponent("state-m2a.json").path
        o.overviewFixture = OverviewDataTests.fixture.path
        o.level = .overview
        o.drafts = drafts.path
        o.cache = drafts.appendingPathComponent("cache").path
        return AppModel(options: o)
    }

    private func arrow(_ code: UInt16) -> NSEvent {
        let chars = String(UnicodeScalar(UInt32([123: NSLeftArrowFunctionKey, 124: NSRightArrowFunctionKey, 125: NSDownArrowFunctionKey,
                                                 126: NSUpArrowFunctionKey, 36: 13][Int(code)]!))!)
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    /// The arrows move what is followed only while the map has the keys (else the sidebar keeps them); Return opens
    /// Review there, and Back returns to the overview as it was, following the same thing.
    func testKeysMoveAndReturnOpensReviewAndBackKeepsIt() throws {
        let m = makeModel()
        let d = try XCTUnwrap(m.overview.data)
        XCTAssertFalse(m.overviewKey(arrow(124), mapHasKeys: false), "the sidebar's arrows")
        XCTAssertNil(m.overview.selection)
        XCTAssertTrue(m.overviewKey(arrow(124), mapHasKeys: true))
        let first = try XCTUnwrap(d.round(2)?.spans?.first)
        XCTAssertEqual(m.overview.selection, .section(first.section, round: 2))
        XCTAssertTrue(m.overviewKey(arrow(124), mapHasKeys: true))
        let second = try XCTUnwrap(d.round(2)?.spans?[1])
        XCTAssertEqual(m.overview.selection, .section(second.section, round: 2))
        XCTAssertTrue(m.overviewKey(arrow(125), mapHasKeys: true))
        XCTAssertEqual(m.overview.selection.flatMap { if case .section(_, let n) = $0 { return n } else { return nil } }, 1)
        XCTAssertEqual(m.stripRound, 1, "the strip goes with the cell's round")
        XCTAssertFalse(m.overviewKey(arrow(125), mapHasKeys: true), "no older round: not taken")
        let followed = m.overview.selection
        XCTAssertTrue(m.overviewKey(arrow(36), mapHasKeys: true))
        XCTAssertEqual(m.level, .review, "Return: Review there")
        m.goBack()
        XCTAssertEqual(m.level, .overview)
        XCTAssertEqual(m.overview.selection, followed, "Back: still following it")
        XCTAssertEqual(m.stripRound, 1)
        // a comment through its rounds: the strip goes with it
        m.overviewClicked(.comment("R1-05"))
        XCTAssertTrue(m.overviewKey(arrow(126), mapHasKeys: true))
        XCTAssertEqual(m.overview.selection, .comment("R1-05"))
        XCTAssertEqual(m.stripRound, 2)
        // Esc wherever the keys are
        XCTAssertTrue(m.overviewKey(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                     context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                                     isARepeat: false, keyCode: 53)!, mapHasKeys: false))
        XCTAssertNil(m.overview.selection)
        XCTAssertFalse(m.overviewKey(arrow(36), mapHasKeys: true), "Return with nothing followed: not taken")
    }

    /// A key that moves into a folded round unfolds the map.
    func testAKeyIntoAFoldedRoundUnfolds() throws {
        let m = makeModel()
        m.overview.folded = [1]
        m.overviewClicked(.round(2))
        XCTAssertFalse(m.overview.unfold)
        XCTAssertTrue(m.overviewMove(.down))
        XCTAssertEqual(m.overview.selection, .round(1))
        XCTAssertTrue(m.overview.unfold)
    }

    /// The panel's buttons and lines act as the map does; a double click on a line opens Review at the comment, and Back
    /// follows it again.
    func testThePanelOpensReviewAndBackFollowsAgain() throws {
        let m = makeModel()
        m.overviewClicked(.section("design", round: 2))
        let p = try XCTUnwrap(OverviewPanel.make(.section("design", round: 2), data: XCTUnwrap(m.overview.data), strip: m.stripRound, student: "Lin"))
        guard case .lines(let lines, _, _) = p.body, let line = lines.first else { return XCTFail("lines") }
        m.overviewClicked(.comment(line.id))
        XCTAssertEqual(m.overview.selection, .comment(line.id))
        m.overviewClicked(.comment(line.id), double: true)
        XCTAssertEqual(m.level, .review)
        XCTAssertEqual(m.selectedComment?.id, line.id)
        m.goBack()
        XCTAssertEqual(m.overview.selection, .comment(line.id))
    }

    /// The map's key view takes the keys on a click in the overview (`takeKeys`), and is in the window's key view loop
    /// (whether Tab reaches it depends on the system's Keyboard navigation and SwiftUI's own focus: not checked here).
    func testTheMapTakesTheKeys() throws {
        let m = makeModel()
        let host = NSHostingView(rootView: VStack {
            TextField("other", text: .constant(""))
            Color.clear.frame(width: 200, height: 100).background(OverviewKeyTarget(overview: m.overview))
        }.frame(width: 300, height: 200))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let v = try XCTUnwrap(m.overview.keyView)
        XCTAssertFalse(m.overview.hasKeys)
        m.overviewClicked(.round(1))
        XCTAssertTrue(m.overview.hasKeys, "a click in the overview")
        XCTAssertNil(v.hitTest(NSPoint(x: 10, y: 10)), "it takes no click")
        window.recalculateKeyViewLoop()
        var chain: [NSView] = []
        var k: NSView? = host
        for _ in 0..<8 { k = k?.nextKeyView; if let k { chain.append(k) } }
        XCTAssertTrue(chain.contains { $0 === v }, "in the key view loop")
        window.makeFirstResponder(nil)
        m.overview.takeKeysIfFree()
        XCTAssertTrue(m.overview.hasKeys, "nobody had them")
        window.close()
    }

    /// The table's switch (UI v4: the toolbar's Map | Table control) is the viewer's; a test run keeps it only for
    /// itself.
    func testTheTableSwitch() throws {
        let before = UserDefaults.standard.object(forKey: AppModel.mapAsTableKey) as? Bool
        let m = makeModel()
        XCTAssertFalse(m.overview.asTable, "a fixture run reads no setting")
        let control = OverviewToolbarTrail.mapOrTable(m)
        XCTAssertFalse(control.wrappedValue, "Map")
        control.wrappedValue = true
        XCTAssertTrue(m.overview.asTable)
        XCTAssertTrue(control.wrappedValue, "Table")
        control.wrappedValue = false
        XCTAssertFalse(m.overview.asTable)
        XCTAssertEqual(UserDefaults.standard.object(forKey: AppModel.mapAsTableKey) as? Bool, before, "nothing saved")
    }

    /// The help tag: at once when forced (the debug script) or right after another; gone with the pointer.
    func testTheHelpTag() throws {
        let h = OverviewHover()
        h.point(at: CGPoint(x: 10, y: 20), key: "a", target: .round(2), comment: "R1-05", force: true) { ["Round 2", "x"] }
        XCTAssertEqual(h.tip?.lines, ["Round 2", "x"])
        XCTAssertEqual(h.target, .round(2))
        XCTAssertEqual(h.comment, "R1-05")
        h.leave("b")
        XCTAssertNotNil(h.tip, "another key's exit")
        h.leave("a")
        XCTAssertNil(h.tip)
        XCTAssertNil(h.comment)
        h.point(at: .zero, key: "c", force: true) { [] }
        XCTAssertNil(h.tip, "no lines, no tag")
    }
}
