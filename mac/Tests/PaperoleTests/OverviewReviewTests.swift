import AppKit
import SwiftUI
import XCTest
@testable import Paperole

/// The fixes after the overview's reviews (2026-10-19; UX.md §21, §22): a gap's structure labels said once when they do
/// not all fit, never in red and never on a removed band's point; the hovered row's names clear of the chips; the
/// followed row scrolled into view; one date for "came in"; a failed last round's header and readout; the engine's
/// section names for a lone appendix; the Sage caption named as the token; the readout's words; the table's round
/// headers. Synthetic data only (Fixtures/overview-kelp.json and MapLayoutTests' generated papers).
final class OverviewReviewTests: XCTestCase {
    private let widths = MapLayoutTests.widths

    /// The stress paper with every section of its last round renamed: 17 "renamed" labels in one gap.
    private func renamedEverywhere() throws -> PaperOverview {
        var d = try MapLayoutTests.stress()
        let json = try JSONSerialization.jsonObject(with: Data(#"[["a", "a", "renamed", 3, 3]]"#.utf8))
        let renamed = try PaperOverview.decodeReply(JSONSerialization.data(withJSONObject: [
            "papers": [["path": "/x", "overview": ["rounds": [["n": 1, "match": json]]]]]]))
        let template = try XCTUnwrap(renamed.papers.first?.overview?.round(1)?.match?.first)
        let last = d.rounds.count - 1
        d.rounds[last].match = (d.rounds[last].spans ?? []).filter { $0.section != "front" }.map { sp in
            var m = template
            m.from = sp.section
            m.to = sp.section
            return m
        }
        return d
    }

    func testAGapsLabelsAreSaidOnceWhenTheyDoNotAllFit() throws {
        let d = try renamedEverywhere()
        for w in widths {
            let s = MapScene.build(MapInput(data: d, width: w))
            let top = s.labels.filter { $0.text.baseline < s.rows[1].y }
            XCTAssertFalse(top.isEmpty, "the gap says something at \(w)")
            XCTAssertTrue(s.labels.allSatisfy { $0.text.ink == .secondary }, "never red")
            for (i, a) in s.labels.enumerated() {
                for b in s.labels[(i + 1)...] { XCTAssertFalse(a.text.rect.intersects(b.text.rect), "\(a.text.text) over \(b.text.text) at \(w)") }
            }
            if top.count < 17 {
                XCTAssertEqual(top.map(\.text.text), ["17 renamed"], "all of the gap's, in one label, at \(w)")
            }
        }
        let narrow = MapScene.build(MapInput(data: d, width: widths[2]))
        XCTAssertEqual(narrow.labels.filter { $0.text.baseline < narrow.rows[1].y }.map(\.text.text), ["17 renamed"])
        // following one of them: its own label in full, the others step back and give way
        let followed = MapScene.build(MapInput(data: d, width: widths[2], selection: .section("model", round: 8)))
        XCTAssertTrue(followed.labels.contains { $0.text.text == "renamed" && $0.text.opacity == 1 })
    }

    func testTheHoveredRowsNamesCoverNoLabel() throws {
        for d in [try MapLayoutTests.kelp(), try MapLayoutTests.stress(), try renamedEverywhere()] {
            for w in widths {
                let s = MapScene.build(MapInput(data: d, width: w))
                for row in s.rows {
                    let names = s.hoverNames(row.n, d)
                    let leaders = s.labels.compactMap { l in l.leader.map { CGRect(x: min($0.0.x, $0.1.x), y: $0.0.y - 1, width: abs($0.1.x - $0.0.x), height: 2) } }
                    for n in names {
                        for l in s.labels { XCTAssertFalse(n.rect.intersects(l.text.rect), "\(n.text) over \(l.text.text)") }
                        for l in leaders + s.carriedPills.map(\.0) { XCTAssertFalse(n.rect.intersects(l)) }
                    }
                    for (i, a) in names.enumerated() { for b in names[(i + 1)...] { XCTAssertFalse(a.rect.intersects(b.rect)) } }
                }
            }
        }
        // every section of the open round named (the UI audit of 2026-10-21; UI v4: no chips in the way)
        let kelp = try MapLayoutTests.kelp()
        for w in widths {
            let s = MapScene.build(MapInput(data: kelp, width: w))
            let top = try XCTUnwrap(s.rows.first)
            let names = s.hoverNames(top.n, kelp)
            XCTAssertEqual(names.count, top.cells.filter { $0.fold == nil }.count, "every section named at \(w): \(names.map(\.text))")
        }
        // a closed round keeps its names (the engine's for a lone appendix: "Extra")
        let k = try MapLayoutTests.kelp()
        let s = MapScene.build(MapInput(data: k, width: widths[0]))
        XCTAssertTrue([1, 2, 3].contains { s.hoverNames($0, k).map(\.text).contains { $0.hasSuffix("Extra") } })
    }

    func testScrollingAFollowedRowIntoView() {
        XCTAssertNil(OverviewModel.scrollToShow(top: 200, bottom: 260, offset: 100, height: 400), "in view: no scroll")
        XCTAssertEqual(OverviewModel.scrollToShow(top: 600, bottom: 660, offset: 100, height: 400), 272, "below: as little as needed")
        XCTAssertEqual(OverviewModel.scrollToShow(top: 50, bottom: 110, offset: 100, height: 400), 38, "above: its top with a margin")
        XCTAssertEqual(OverviewModel.scrollToShow(top: 600, bottom: 1200, offset: 100, height: 400), 588, "taller than the view: its top")
        XCTAssertEqual(OverviewModel.scrollToShow(top: 5, bottom: 30, offset: 20, height: 400), 0, "never above the top")
    }

    func testCameInIsTheImportEverywhere() throws {
        var json = try MapLayoutTests.kelpJSON()
        MapLayoutTests.edit(&json) { o in
            var rounds = o["rounds"] as! [[String: Any]]
            rounds[3]["received"] = "2026-10-10T09:00:00+08:00"  // files changed nine days before the import
            o["rounds"] = rounds
        }
        let d = try MapLayoutTests.decode(json)
        let r4 = try XCTUnwrap(d.round(4))
        let created = try XCTUnwrap(OverviewText.day(r4.created))
        XCTAssertTrue(OverviewText.firstSentence(d, student: "Mei Lin").hasPrefix("Round 4 came in on \(created)."))
        let s = MapScene.build(MapInput(data: d, width: widths[0]))
        XCTAssertEqual(s.rows.first?.dates.text, shortDate(r4.created), "UI v4: the map's label the arrival date only")
        XCTAssertTrue(MapSpeech.row(d, r4, student: "Mei").hasPrefix("Round 4, " + MapSpeech.spoken(OverviewText.dates(r4.created, nil))))
        XCTAssertEqual(MapTable.make(d, selection: nil, student: "Mei").columns.last?.dates, OverviewText.dates(r4.created, nil))
        XCTAssertTrue(OverviewPanel.round(4, d, student: "Mei")?.meta.hasPrefix(OverviewText.dates(r4.created, nil)) == true)
        // the files' own day only in the round's help tag, named so
        let tag = MapHelp.lines(.round(4), d, student: "Mei")
        XCTAssertEqual(tag[1], "Files last changed " + (shortDate("2026-10-10T09:00:00+08:00") ?? ""))
        XCTAssertFalse(MapHelp.lines(.round(3), d, student: "Mei").contains { $0.hasPrefix("Files") }, "the same day: not said")
    }

    /// A failed last round (the kelp paper with a Round 5 that did not build): the header's pages and words are the
    /// last built round's, and the failed readout fits its column at every width.
    func testAFailedLastRound() throws {
        var json = try MapLayoutTests.kelpJSON()
        MapLayoutTests.edit(&json) { o in
            var rounds = o["rounds"] as! [[String: Any]]
            rounds.append(["n": 5, "created": "2026-10-20T10:00:00+08:00", "closed": false, "build": ["status": "failed", "pages": 0],
                           "prose": "unavailable", "spans": NSNull(), "heat": NSNull(), "match": NSNull(), "edits": [],
                           "comments": ["new": 0, "carried": 0]])
            rounds[3]["closed"] = true
            o["rounds"] = rounds
        }
        let d = try MapLayoutTests.decode(json)
        let f = OverviewText.facts(d, rounds: [], pages: 0)
        let r4 = try XCTUnwrap(d.round(4))
        XCTAssertTrue(f.details.contains("\(r4.build?.pages ?? -1) pp"), "\(f.details)")
        XCTAssertTrue(f.details.contains(OverviewText.grouped(r4.words?.body ?? -1) + " words"))
        XCTAssertFalse(f.details.contains("0 pp"))
        for w in widths {
            let s = MapScene.build(MapInput(data: d, width: w, buildErrors: "1 error"))
            let r5 = try XCTUnwrap(s.rows.first)
            XCTAssertEqual(r5.readout.count, 2)
            for t in r5.readout { XCTAssertLessThanOrEqual(t.rect.maxX, s.geometry.width + 0.5, "\(t.text) at \(w)") }
            XCTAssertTrue(r5.readout[0].text.hasSuffix(" for a PDF"), r5.readout[0].text)
        }
        // UI v4: the readout a fixed 168 pt at every width, which holds the longer pointer
        let narrow = MapScene.build(MapInput(data: d, width: widths[2], buildErrors: "1 error"))
        XCTAssertEqual(narrow.rows.first?.readout.map(\.text), [MapScene.waitWords(MapScene.waiting(d, 5), counted: false), "Show Log… in the toolbar"])
    }

    func testNamesTitlesAndTheReadoutsWords() throws {
        let d = try MapLayoutTests.kelp()
        XCTAssertEqual(d.shortTitle("extra", "A Extra"), "Extra", "a lone appendix's letter, by the engine's name")
        XCTAssertEqual(d.shortTitle("methods", "4 Methods"), "Methods", "an older title: by its number")
        XCTAssertEqual(d.shortTitle("front", "Title and abstract"), "Abstract")
        XCTAssertTrue(MapSpeech.cell(d, "extra", 3).hasPrefix("Extra, Round 3"))
        // the Sage caption names the section as the token does: by its title in the round followed
        let r2 = MapScene.build(MapInput(data: d, width: widths[0], selection: .section("methods", round: 2)))
        XCTAssertEqual(r2.sageCaption?.text, "Methods only")
        XCTAssertEqual(OverviewText.following(.section("methods", round: 2), d), "3 Methods")
        let r4 = MapScene.build(MapInput(data: d, width: widths[0], selection: .section("methods", round: 4)))
        XCTAssertEqual(r4.sageCaption?.text, "Materials and methods only")
        // the readout: follow-ups in the open round's so-far line; "none yet", "n left open"; nothing for no comment
        var c = PaperOverview.Round.Comments()
        c.carried = 5
        c.followUp = 1
        c.resolved = 2
        var open = try XCTUnwrap(d.round(4))
        open.comments = c
        XCTAssertEqual(MapScene.readoutColumns(d, open, first: false, columns: 3, ready: false)[2].0, "✓ 2 · ↩ 1 so far")
        c.followUp = 0
        c.resolved = 0
        open.comments = c
        XCTAssertEqual(MapScene.readoutColumns(d, open, first: false, columns: 3, ready: false)[2].0, "none yet")
        var closed = try XCTUnwrap(d.round(3))
        c.leftOpen = 5
        closed.comments = c
        XCTAssertEqual(MapScene.readoutColumns(d, closed, first: false, columns: 3, ready: false)[2].0, "5 left open")
        var empty = try XCTUnwrap(d.round(1))
        empty.comments = PaperOverview.Round.Comments()
        XCTAssertEqual(MapScene.readoutColumns(d, empty, first: true, columns: 1, ready: false)[0].1, "", "no comment: not \"all new\"")
        // the map's readout (UI v4): "–" for none, "so far" while open, what was left open under a closed round's answers
        c.resolved = 2
        c.followUp = 1
        c.leftOpen = 0
        open.comments = c
        XCTAssertEqual(MapScene.readoutLines(open, first: false, you: true, ready: true)[1], ["✓ 2 · ↩ 1 so far", "✓ 2 · ↩ 1", "ready to finish"])
        c.leftOpen = 2
        closed.comments = c
        XCTAssertEqual(MapScene.readoutLines(closed, first: false, you: true, ready: false)[1], ["✓ 2 · ↩ 1", "2 left open"])
        XCTAssertEqual(MapScene.readoutLines(empty, first: true, you: true, ready: false), [["–", ""], ["–", ""]])
        XCTAssertEqual(MapScene.readoutLines(open, first: false, you: false, ready: true), [["5", "ready to finish"]])
        XCTAssertTrue(MapSpeech.row(d, empty, student: "Mei").contains("0 comments. "))
        // the fold counts its comments as words
        let one = MapScene.build(MapInput(data: try MapLayoutTests.stress(), width: widths[1], fold: 2))
        XCTAssertFalse(one.fold?.text.text.contains(" 1 comments") ?? true)
        // the table's headers keep the round's number
        XCTAssertEqual(MapTableView.roundTitle(9, room: 200), "Round 9")
        XCTAssertEqual(MapTableView.roundTitle(9, room: 40), "R9")
    }

    /// A band followed by its heading only (no paragraph of it left): its tag says so, never "0 of 2 kept" as a match.
    func testABandFollowedByItsHeadingSaysSo() throws {
        var json = try MapLayoutTests.kelpJSON()
        MapLayoutTests.edit(&json) { o in
            var rounds = o["rounds"] as! [[String: Any]]
            var match = rounds[3]["match"] as! [[Any]]
            if let i = match.firstIndex(where: { ($0[0] as? String) == "discussion" }) { match[i][3] = 0 }
            rounds[3]["match"] = match
            o["rounds"] = rounds
        }
        let d = try MapLayoutTests.decode(json)
        let tag = MapHelp.lines(.band(from: "discussion", to: "discussion", round: 4), d, student: "Mei")
        XCTAssertTrue(tag[1].hasPrefix("Followed by its heading: none of its"), tag[1])
    }
}

/// The hierarchy's fixes (UX.md §22): a failed last round's open row in Where the time goes; and the toolbar laid out
/// again once the window's width settles (UX.md §21 "The toolbar"). (The Student page's lede went with UI v4.)
@MainActor
final class HierarchyReviewTests: XCTestCase {
    func testAFailedRoundsTripDecodes() throws {
        let json = #"{"papers": [], "students": [{"student": "A", "papers": ["/a"], "time": [{"path": "/a", "round": 1, "next": 2, "open": false, "you": 2, "student": 7, "received": null}, {"path": "/a", "round": 2, "next": null, "open": true, "you": 2, "student": null, "received": null, "failed": true}]}]}"#
        let s = try XCTUnwrap(PaperOverview.decodeReply(Data(json.utf8)).students?.first)
        XCTAssertEqual(s.time?.map(\.failed), [nil, true])
    }

    func testTheToolbarIsLaidOutAgainOnceTheWidthSettles() throws {
        _ = NSApplication.shared
        let drafts = FileManager.default.temporaryDirectory.appendingPathComponent("pc-toolbar-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: drafts) }
        var o = LaunchOptions()
        o.fixture = StepTests.fixtures.appendingPathComponent("state-m2a.json").path
        o.drafts = drafts.path
        let m = AppModel(options: o)
        for _ in 0..<3 { m.toolbarWidthChanged() }  // a resize's widths, one after another
        XCTAssertEqual(m.toolbarNudges, 0, "not while it changes")
        let e = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { e.fulfill() }
        wait(for: [e], timeout: 3)
        XCTAssertEqual(m.toolbarNudges, 1, "once, after it settled")
        XCTAssertFalse(m.toolbarNudge, "the empty item is gone again")
    }
}
