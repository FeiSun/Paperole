import AppKit
import SwiftUI
import XCTest
@testable import Paperole

/// The strip and the map's box show one round (mac/UX.md §40.9): the round previewed once the pointer rests on its
/// row, kept on the pointer's way to the strip, back to the strip's round elsewhere, picked by a click, never by a key;
/// and nothing moves when the strip shows another round (the latest, an older one, a round of other pages, pages with
/// and without counts to check).
@MainActor
final class StripPreviewTests: XCTestCase {
    private func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    func testThePreviewWaitsForThePointerToRest() {
        let o = OverviewModel()
        o.point(round: 1, at: CGPoint(x: 300, y: 70))
        XCTAssertNil(o.preview, "not at once")
        spin(0.05)
        XCTAssertNil(o.preview, "not before the dwell")
        spin(0.35)
        XCTAssertEqual(o.preview, 1, "the pointer stopped on its row")
        // a row crossed slowly (a move every 30 ms for 300 ms, 4 pt each) previews nothing: the pointer never rests
        for i in 0..<10 {
            o.point(round: 2, at: CGPoint(x: 300, y: 125 + CGFloat(i) * 4))
            spin(0.03)
            XCTAssertEqual(o.preview, 1, "crossing round 2, move \(i)")
        }
        o.point(round: 3, at: CGPoint(x: 300, y: 190))
        spin(0.4)
        XCTAssertEqual(o.preview, 3, "resting on the row after it")
        // resting, the hand's tremor (under 3 pt from where it stopped) does not put it off
        for i in 0..<10 {
            o.point(round: 2, at: CGPoint(x: 300 + CGFloat(i % 3), y: 140 + CGFloat(i % 2)))
            spin(0.03)
        }
        XCTAssertEqual(o.preview, 2)
        // a moment off the rows keeps it; staying off them, even moving on, brings the strip's round back
        o.point(round: nil, at: CGPoint(x: 300, y: 400))
        spin(0.02)
        o.point(round: 2, at: CGPoint(x: 300, y: 140))
        spin(0.4)
        XCTAssertEqual(o.preview, 2)
        o.point(round: nil, at: CGPoint(x: 300, y: 400))
        spin(0.05)
        o.point(round: nil, at: CGPoint(x: 320, y: 420))
        spin(0.35)
        XCTAssertNil(o.preview)
        // another paper: none, and none on its way
        o.point(round: 2, at: CGPoint(x: 300, y: 140))
        o.reset(for: "/other")
        spin(0.4)
        XCTAssertNil(o.preview)
    }

    /// The way to the strip's pages (the lens over the rows, the strip, its ruler) keeps the round shown, in whatever
    /// order the map's and the strip's events come; leaving them elsewhere brings the strip's round back.
    func testThePreviewStaysOnTheWayToTheStrip() {
        let o = OverviewModel()
        o.point(round: 1, at: CGPoint(x: 300, y: 130))
        spin(0.4)
        XCTAssertEqual(o.preview, 1)
        // up across round 2's row and the lens, off the map onto the strip (the map's exit first)
        o.point(round: 2, at: CGPoint(x: 300, y: 80))
        spin(0.03)
        o.point(round: nil, lens: true, at: CGPoint(x: 300, y: 30))
        spin(0.4)
        XCTAssertEqual(o.preview, 1, "the lens keeps it; round 2 was only crossed")
        o.pointOffMap()
        o.point(strip: true)
        spin(0.4)
        XCTAssertEqual(o.preview, 1, "the strip keeps it")
        // back onto the lens (the strip's exit second), onto the strip again (the map's exit second)
        o.point(round: nil, lens: true, at: CGPoint(x: 300, y: 2))
        o.point(strip: false)
        spin(0.4)
        XCTAssertEqual(o.preview, 1)
        o.point(strip: true)
        o.pointOffMap()
        spin(0.4)
        XCTAssertEqual(o.preview, 1)
        // off the strip, up to the header: the strip's round is back
        o.point(strip: false)
        spin(0.4)
        XCTAssertNil(o.preview)
        // the strip's exit that comes after the pointer is on a row leaves the row's wait alone
        o.point(round: 2, at: CGPoint(x: 300, y: 80))
        o.point(strip: false)
        spin(0.4)
        XCTAssertEqual(o.preview, 2)
        // a strip exit SwiftUI missed: the pointer's next place on the map, under the rows, counts
        o.point(round: nil, lens: true, at: CGPoint(x: 300, y: 30))
        o.pointOffMap()
        o.point(strip: true)
        o.point(round: nil, at: CGPoint(x: 300, y: 400))
        spin(0.4)
        XCTAssertNil(o.preview)
    }

    private func model(_ fixture: URL) -> AppModel {
        _ = NSApplication.shared
        var o = LaunchOptions()
        o.fixture = StepTests.fixtures.appendingPathComponent("state-m2a.json").path
        o.overviewFixture = fixture.path
        o.level = .overview
        let drafts = FileManager.default.temporaryDirectory.appendingPathComponent("pc-strip-preview-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: drafts) }
        o.drafts = drafts.path
        let m = AppModel(options: o)
        if m.overview.data == nil { m.loadOverview(force: true) }
        return m
    }

    func testAClickPicksThePreviewedRoundAndAKeyDoesNot() throws {
        let m = model(OverviewDataTests.fixture)
        XCTAssertEqual(m.stripRound, 2)
        let row1 = CGPoint(x: 40, y: 130), row2 = CGPoint(x: 40, y: 70)
        m.overview.point(round: 1, at: row1)
        spin(0.4)
        XCTAssertEqual(m.shownStripRound, 1, "the strip shows the round previewed")
        XCTAssertEqual(m.stripRound, 2, "which is not picked yet")
        XCTAssertNil(m.overview.selection)
        m.overviewClicked(.section("introduction", round: 1))
        XCTAssertNil(m.overview.preview)
        XCTAssertEqual(m.stripRound, 1)
        XCTAssertEqual(m.overview.place.strip, 1, "kept for Back")
        // the pointer on round 2's row, then a key: it moves from the strip's round, the preview goes
        m.overview.point(round: 2, at: row2)
        spin(0.4)
        XCTAssertEqual(m.shownStripRound, 2)
        XCTAssertTrue(m.overviewMove(.up))
        XCTAssertNil(m.overview.preview)
        XCTAssertEqual(m.stripRound, 2)
        // the row the pointer is on previews again only once the pointer has left it, however it moves on it
        m.overview.point(round: 2, at: CGPoint(x: row2.x + 20, y: row2.y))
        spin(0.4)
        XCTAssertNil(m.overview.preview)
        // a round previewed, kept on the way to the strip, picked by a click on one of its pages there
        m.overview.point(round: 1, at: row1)
        spin(0.4)
        m.overview.point(round: nil, lens: true, at: CGPoint(x: 300, y: 20))
        m.overview.pointOffMap()
        m.overview.point(strip: true)
        spin(0.4)
        XCTAssertEqual(m.shownStripRound, 1)
        m.overviewClicked(.page(round: 1, page: 2))
        XCTAssertNil(m.overview.preview)
        XCTAssertEqual(m.stripRound, 1)
        XCTAssertEqual(m.overview.selection, .page(round: 1, page: 2))
        // a click before the pointer has rested on the row: nothing previewed after it
        m.overview.point(strip: false)
        m.overview.point(round: 2, at: row2)
        m.overviewClicked(.round(2))
        spin(0.4)
        XCTAssertNil(m.overview.preview)
        XCTAssertEqual(m.stripRound, 2)
    }

    /// Leaving the overview without a click (Return on the map, a menu command, Back) ends the preview and the pointer's
    /// place: the overview's views go before the pointer's exit reaches them (the review of 2026-11-01), so All Rounds
    /// shows the strip's round without the old help tag, and the row under the pointer previews again.
    func testLeavingTheOverviewEndsThePreview() throws {
        let m = model(OverviewDataTests.fixture)
        let row1 = CGPoint(x: 40, y: 130), row2 = CGPoint(x: 40, y: 70)
        let ret = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                   characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        m.overviewClicked(.round(2))
        m.overview.point(round: 1, at: row1)
        m.overview.hover.point(at: row1, key: "map:cell", target: .cell("introduction", round: 1), force: true) { ["Introduction"] }
        spin(0.4)
        XCTAssertEqual(m.shownStripRound, 1)
        XCTAssertNotNil(m.overview.hover.tip)
        // Return on the map: Review, then All Rounds
        XCTAssertTrue(m.overviewKey(ret, mapHasKeys: true))
        XCTAssertEqual(m.level, .review)
        m.showAllRounds()
        XCTAssertEqual(m.level, .overview)
        XCTAssertNil(m.overview.preview)
        XCTAssertEqual(m.shownStripRound, m.stripRound)
        XCTAssertEqual(m.stripRound, 2)
        XCTAssertNil(m.overview.hover.target)
        XCTAssertNil(m.overview.hover.tip)
        // the pointer on the same row, where it was: it previews again
        m.overview.point(round: 1, at: row1)
        spin(0.4)
        XCTAssertEqual(m.shownStripRound, 1)
        // Back with another round on its way (the pointer on round 2's row for less than the dwell): none after
        m.overview.point(round: 2, at: row2)
        m.goBack()
        XCTAssertEqual(m.level, .review)
        spin(0.4)
        XCTAssertNil(m.overview.preview)
        m.showAllRounds()
        XCTAssertEqual(m.shownStripRound, 2)
    }

    /// The box marks the round previewed, with the fill alone; the page axis, and so the map's height, keep the strip's.
    func testTheBoxMarksThePreview() throws {
        let d = try OverviewDataTests.overviewFixture()
        let held = MapScene.build(MapInput(data: d, width: 900, strip: 2, selection: .round(2)))
        let shown = MapScene.build(MapInput(data: d, width: 900, strip: 2, preview: 1, selection: .round(2)))
        let row1 = try XCTUnwrap(shown.rows.first { $0.n == 1 })
        XCTAssertEqual(try XCTUnwrap(shown.box).minY, row1.y - 6)
        XCTAssertFalse(shown.boxFollowed, "no outline on a preview")
        XCTAssertTrue(held.boxFollowed)
        XCTAssertEqual(shown.height, held.height)
        XCTAssertEqual(shown.rows.map(\.y), held.rows.map(\.y))
        // the rows' bands: label, cells and the gap under them; over the first one the lens
        XCTAssertEqual(shown.round(atY: row1.y + 10), 1)
        XCTAssertEqual(shown.round(atY: row1.y + MapGeometry.cell + 15), 1)
        XCTAssertNil(shown.round(atY: 4))
        XCTAssertTrue(shown.overLens(4))
        let first = try XCTUnwrap(shown.rows.first)
        XCTAssertFalse(shown.overLens(first.y - 10), "the first row's band")
        XCTAssertNil(shown.round(atY: 1000))
        XCTAssertFalse(shown.overLens(1000), "under the rows")
    }

    /// The page axis keeps the strip's round while another is previewed (the review of 2026-11-01: it followed the
    /// round previewed, so on a paper whose appendix folds its pages, Show or Fold and the page numbers moved under the
    /// map as the pointer rested on rows of other lengths); the lens follows the round previewed.
    func testThePageAxisKeepsTheStripsRound() throws {
        let d = try MapFoldTests.sonar()  // the appendix folds; Round 1 has 27 pages, Round 4 (the strip's) 29
        XCTAssertNotEqual(d.round(1)?.build?.pages, d.round(4)?.build?.pages)
        for stripShown in [true, false] {
            for parts in [Set<FoldKind>(), [.appendix]] {
                func scene(_ preview: Int?) -> MapScene {
                    MapScene.build(MapInput(data: d, width: MapFoldTests.widths[0], strip: 4, preview: preview, shownParts: parts,
                                            stripShown: stripShown))
                }
                let held = scene(nil), shown = scene(1), name = "strip shown \(stripShown), parts shown \(parts)"
                XCTAssertFalse(held.axisParts.isEmpty, name)
                XCTAssertEqual(held.axis.isEmpty, stripShown, "numbered only without the strip: \(name)")
                XCTAssertEqual(shown.axisParts, held.axisParts, name)
                XCTAssertEqual(shown.axis, held.axis, name)
                func links(_ s: MapScene) -> [MapScene.Hit] { s.hits.filter { [MapTarget.showPart(.appendix), .foldPart(.appendix)].contains($0.target) } }
                XCTAssertEqual(links(shown), links(held), name)
                XCTAssertEqual(shown.height, held.height, name)
                XCTAssertNotEqual(shown.fans, held.fans, "the lens from the previewed round's pages: \(name)")
            }
        }
    }

    /// A fixture variant: round 1 of `pages1` pages, round 2 (the latest) of `pages2` (their PDFs are not there: the
    /// default page shape), and the open round's comments to check answered or not.
    private func fixture(pages1: Int, pages2: Int, toCheck: Bool) throws -> URL {
        var j = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: OverviewDataTests.fixture)) as? [String: Any])
        var papers = try XCTUnwrap(j["papers"] as? [[String: Any]])
        var o = try XCTUnwrap(papers[0]["overview"] as? [String: Any])
        var rounds = try XCTUnwrap(o["rounds"] as? [[String: Any]])
        for (i, pages) in [pages1, pages2].enumerated() {
            var build = try XCTUnwrap(rounds[i]["build"] as? [String: Any])
            build["pages"] = pages
            rounds[i]["build"] = build
        }
        o["rounds"] = rounds
        if !toCheck {
            var cs = try XCTUnwrap(o["comments"] as? [[String: Any]])
            for i in cs.indices {
                cs[i]["path"] = (cs[i]["path"] as? [[Any]])?.map { s in
                    var s = s
                    if s.count > 6, s[6] as? String == "to_check" { s[6] = "resolved" }
                    return s
                }
            }
            o["comments"] = cs
            rounds[1]["edits"] = nil
            o["rounds"] = rounds
        }
        papers[0]["overview"] = o
        j["papers"] = papers
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pc-strip-\(pages1)-\(pages2)-\(toCheck)-" + UUID().uuidString + ".json")
        try JSONSerialization.data(withJSONObject: j).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// The overview of `fixture` in a window 900 pt wide (the strip 852), shown.
    private func shown(_ fixture: URL, height: CGFloat = 800) -> (AppModel, NSWindow) {
        let m = model(fixture)
        let host = NSHostingView(rootView: OverviewScreen(model: m, overview: m.overview).frame(width: 900, height: height))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        spin(0.5)
        return (m, window)
    }

    /// The strip's label, the ruler and the map's top stay put, and the thumbnails keep their size: the latest round
    /// (its pages with counts to check, or none), an older one previewed, back, clicked; a round of 30 pages, older or
    /// latest (the advisor's decision of 2026-11-01: one size of thumbnails for every paper and round, a round wider
    /// than the overview scrolls).
    func testNothingMovesWhenTheStripShowsAnotherRound() throws {
        var tops: [String: [CGFloat]] = [:]
        for (pages1, pages2, toCheck) in [(4, 4, true), (4, 4, false), (30, 4, true), (4, 30, true)] {
            let (m, window) = shown(try fixture(pages1: pages1, pages2: pages2, toCheck: toCheck))
            XCTAssertEqual(PageStripView.pagesToCheck(m.overview.data?.round(2), m.overview.data).isEmpty, !toCheck)
            let name = "\(pages1)/\(pages2)/\(toCheck)"
            func top(_ state: String) {
                spin(0.4)
                let h = m.overview.hover
                tops[name + " " + state] = [h.stripOrigin.y, h.rulerOrigin.y, h.mapOrigin.y, m.overview.mapTop]
                let g = m.overview.stripScroll.geo
                XCTAssertEqual(g?.thumb, StripGeometry.letterThumb, "\(name) \(state)")
                XCTAssertEqual(g?.row, 72, "\(name) \(state)")
                XCTAssertEqual(g?.scrolls, g?.pages == 30, "\(name) \(state)")
            }
            XCTAssertEqual(m.shownStripRound, 2)
            top("latest")
            m.overview.point(round: 1, at: CGPoint(x: 40, y: 130))
            top("previewed")
            XCTAssertEqual(m.shownStripRound, 1)
            m.overview.pointOffMap()
            top("back")
            XCTAssertEqual(m.shownStripRound, 2)
            m.overviewClicked(.round(1))
            top("clicked")
            XCTAssertEqual(m.shownStripRound, 1)
            window.close()
        }
        let first = try XCTUnwrap(tops["4/4/true latest"])
        XCTAssertGreaterThan(first[1], first[0], "the ruler under the strip")
        XCTAssertGreaterThan(first[2], first[1], "the map under the ruler")
        for (name, t) in tops.sorted(by: { $0.key < $1.key }) { XCTAssertEqual(t, first, name) }
    }

    /// A round of 30 pages scrolls in its strip, one of 4 does not (the thumbnails one size); a page followed on page 25
    /// comes into view; another round shown keeps the page at the left edge where it has it, else the start; a
    /// vertical wheel over the strip scrolls the overview, a sideways one the strip.
    func testALongRoundScrolls() throws {
        let (m, window) = shown(try fixture(pages1: 4, pages2: 30, toCheck: true), height: 420)
        defer { window.close() }
        let s = m.overview.stripScroll
        let sv = try XCTUnwrap(s.scrollView)
        let g = try XCTUnwrap(s.geo)
        XCTAssertEqual(g.pages, 30)
        XCTAssertTrue(g.scrolls)
        XCTAssertEqual(sv.documentView?.frame.width ?? 0, g.contentWidth, accuracy: 0.5, "the strip wider than the overview")
        XCTAssertGreaterThan(g.contentWidth, sv.contentView.bounds.width + 100)
        XCTAssertEqual(sv.scrollerStyle, .overlay)
        XCTAssertEqual(s.offset, 0, accuracy: 0.5)
        // page 25 followed (a click on the map or the panel): in view, at once with Reduce Motion
        Motion.override = true
        defer { Motion.override = nil }
        m.overviewClicked(.page(round: 2, page: 24))
        spin(0.4)
        XCTAssertGreaterThan(s.offset, 0)
        XCTAssertGreaterThanOrEqual(g.thumbX(24), s.offset)
        XCTAssertLessThanOrEqual(g.thumbX(24) + g.thumbWidth, s.offset + g.width)
        XCTAssertEqual(sv.contentView.bounds.minX, s.offset, accuracy: 0.5)
        // the lens from the pages in view: its top edge inside the strip's width, its ends at the strip's two edges
        let scene = try XCTUnwrap(m.overview.hover.scene)
        let lens = scene.lens(offset: s.offset)
        XCTAssertTrue(lens.fans.allSatisfy { $0[0].x >= 0 && $0[0].x <= g.width })
        XCTAssertEqual(lens.fans.first?[0].x, 0)
        XCTAssertEqual(lens.fans.last?[0].x ?? 0, g.width, accuracy: 0.5)
        XCTAssertGreaterThan(lens.fans.first?[1].x ?? 0, scene.lens(offset: 0).fans.first?[1].x ?? 0, "from where the pages in view are on the map")
        let followed = try XCTUnwrap(lens.selected, "the page followed")
        XCTAssertEqual(followed[0].x, g.x(24) - s.offset, accuracy: 0.5)
        let at = s.offset
        // Round 1 (4 pages) previewed: no scroll; back: page 25 still in view
        m.overview.point(round: 1, at: CGPoint(x: 40, y: 130))
        spin(0.4)
        XCTAssertEqual(m.shownStripRound, 1)
        XCTAssertEqual(s.geo?.scrolls, false)
        XCTAssertEqual(s.geo?.thumb, g.thumb, "the same size")
        XCTAssertEqual(s.offset, 0, accuracy: 0.5)
        m.overview.pointOffMap()
        spin(0.4)
        XCTAssertEqual(m.shownStripRound, 2)
        XCTAssertEqual(s.offset, at, accuracy: 0.5, "the same pages in view")
        // Round 1 clicked: its strip from the start; Round 2 clicked: where it was
        m.overviewClicked(.round(1))
        spin(0.4)
        XCTAssertEqual(s.offset, 0, accuracy: 0.5)
        m.overviewClicked(.round(2))
        spin(0.4)
        XCTAssertEqual(s.offset, at, accuracy: 0.5, "back on the long round where it was")
        // a vertical wheel over the strip goes to the overview; a sideways one moves the strip
        func wheel(dx: Int32, dy: Int32) throws -> NSEvent {
            let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0))
            cg.location = CGPoint(x: 200, y: 200)
            return try XCTUnwrap(NSEvent(cgEvent: cg))
        }
        let outer = try XCTUnwrap(m.overview.scrollView)
        let y0 = outer.contentView.bounds.minY
        sv.scrollWheel(with: try wheel(dx: 0, dy: -40))
        spin(0.3)
        XCTAssertEqual(s.offset, at, accuracy: 0.5, "the strip stays")
        XCTAssertGreaterThan(OverviewModel.room(outer), 40)
        XCTAssertNotEqual(outer.contentView.bounds.minY, y0, "the overview scrolls")
        sv.scrollWheel(with: try wheel(dx: -40, dy: 0))
        spin(0.3)
        XCTAssertNotEqual(s.offset, at, "the strip scrolls sideways")
        XCTAssertEqual(s.anchor, Double(s.offset / g.slot), accuracy: 0.01, "the viewer's place kept")
        // a mouse's wheel with Shift (lines, which AppKit turns sideways)
        let before = s.offset, y1 = outer.contentView.bounds.minY
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 3, wheel2: 0, wheel3: 0))
        cg.flags = .maskShift
        sv.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: cg)))
        spin(0.3)
        XCTAssertLessThan(s.offset, before - 1, "Shift and the wheel: the strip")
        XCTAssertEqual(outer.contentView.bounds.minY, y1, "not the overview")
        // without Reduce Motion the strip glides to page 2 followed, and keeps it as its place
        Motion.override = false
        m.overviewClicked(.page(round: 2, page: 1))
        spin(0.6)
        XCTAssertGreaterThanOrEqual(g.thumbX(1), s.offset)
        XCTAssertLessThanOrEqual(g.thumbX(1) + g.thumbWidth, s.offset + g.width)
        XCTAssertEqual(s.anchor, Double(s.offset / g.slot), accuracy: 0.01)
    }
}
