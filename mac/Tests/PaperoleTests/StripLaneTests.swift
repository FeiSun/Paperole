import AppKit
import PDFKit
import XCTest
@testable import Paperole

/// The demo's column (samples/promo-demo: Maya Chen, Easy Before Hard, Round 2), as design/review-page/BRIEF.md §3.9
/// lays it: each item's share of the paper's height in a 773 pt column (`rv1/mock/nums.js`). Synthetic data.
enum StripDemo {
    static let height: CGFloat = 773

    static let open: [ScrollerMark] = {
        let rows: [(ScrollerMark.Kind, Double, String, Int, Bool, String?)] = [
            (.toCheck, 0.045565, "R1-01", 0, false, nil), (.toCheck, 0.047295, "R1-02", 0, false, nil),
            (.toCheck, 0.067318, "R1-03", 0, false, nil), (.toCheck, 0.070778, "R1-04", 0, false, nil),
            (.toCheck, 0.080369, "R1-05", 0, false, nil), (.toCheck, 0.173408, "R1-06", 1, false, nil),
            (.toCheck, 0.268684, "R1-07", 2, false, nil), (.toCheck, 0.304888, "R1-08", 2, false, nil),
            (.toCheck, 0.417252, "R1-09", 3, false, nil), (.toCheck, 0.450898, "R1-10", 3, false, nil),
            (.toCheck, 0.464599, "R1-11", 3, false, nil), (.toCheck, 0.544320, "R1-14", 4, false, nil),
            (.toCheck, 0.597134, "R1-12", 4, false, nil), (.toCheck, 0.602323, "R1-13", 4, false, nil),
            (.edit, 0.045565, "c01", 0, false, "R1-01"), (.edit, 0.047295, "c02", 0, false, "R1-02"),
            (.edit, 0.067318, "c03", 0, false, "R1-03"), (.edit, 0.070778, "c04", 0, false, "R1-04"),
            (.edit, 0.082099, "c05", 0, false, "R1-05"), (.edit, 0.082099, "c06", 0, false, "R1-05"),
            (.edit, 0.173408, "c07", 1, false, "R1-06"), (.edit, 0.276605, "c08", 2, false, "R1-07"),
            (.edit, 0.305283, "c09", 2, false, "R1-08"), (.edit, 0.305283, "c10", 2, false, "R1-08"),
            (.unasked, 0.351682, "c11", 2, true, nil), (.edit, 0.450898, "c12", 3, false, "R1-10"),
            (.edit, 0.544793, "c13", 4, false, "R1-14"), (.edit, 0.608812, "c14", 4, false, "R1-09"),
            (.edit, 0.608812, "c15", 4, false, "R1-09"), (.unasked, 0.703649, "c16", 5, true, nil),
            (.edit, 0.956408, "c17", 7, false, "R1-09"), (.edit, 0.962588, "c18", 7, false, "R1-09"),
            (.edit, 0.973002, "c19", 7, false, "R1-09")]
        return rows.map { k, f, id, p, waits, of in
            ScrollerMark(kind: k, fraction: f, target: k == .toCheck ? .comment(id) : .change(id), page: p, label: id,
                         waits: waits, answers: of)
        }
    }()

    /// Change marks off (D2): the comments and the unasked edits that wait, as rings alone.
    static var marksOff: [ScrollerMark] {
        open.filter { $0.kind == .toCheck || $0.waits }.map { var m = $0; m.tick = $0.kind != .unasked; return m }
    }

    static let curriculum: [Double] = [0.012705, 0.036918, 0.088232, 0.089962, 0.099525, 0.112271, 0.173393, 0.200723, 0.310412,
                                       0.388251, 0.390355, 0.449205, 0.466329, 0.529721, 0.540464, 0.580283, 0.640030, 0.678870,
                                       0.688868, 0.737271, 0.799779]

    static func find(_ fs: [Double]) -> [ScrollerMark] {
        fs.enumerated().map { i, f in ScrollerMark(kind: .find, fraction: f, target: .find(i), page: 0, label: "Match \(i + 1)") }
    }
}

/// The column's layout (BRIEF §3): glyphs, joins, groups and zones. Pure.
final class StripLayoutTests: XCTestCase {
    private func shapes(_ l: StripLayout.Layout) -> [StripLayout.Shape: Int] {
        l.glyphs.reduce(into: [:]) { $0[$1.shape, default: 0] += 1 }
    }

    /// The demo at rest: 33 items, 26 glyphs (9 rings, 3 capsules, 14 ticks), 13 groups; nothing hidden.
    func testTheDemoAtRest() {
        let l = StripLayout.layout(StripDemo.open, height: StripDemo.height, find: false)
        XCTAssertEqual(l.glyphs.count, 26)
        XCTAssertEqual(shapes(l), [.ring: 9, .capsule: 3, .tick: 12, .unaskedTick: 2])
        XCTAssertEqual(l.groups.count, 13)
        // G1 at window y 119.7 (the column's top at window y 84.5), G13's three ticks at the foot
        XCTAssertEqual(l.groups[0].first + 84.5, 119.7, accuracy: 0.1)
        XCTAssertEqual(l.groups[12].glyphs.count, 3)
        XCTAssertEqual(Set(l.groups[1].members.map { StripDemo.open[$0].label }), ["R1-03", "R1-04", "R1-05", "c03", "c04", "c05", "c06"])
        // every item is in exactly one group
        XCTAssertEqual(l.groups.flatMap(\.members).sorted(), Array(StripDemo.open.indices))
    }

    /// Zones never overlap, are at least 18 pt at rest (R1-10 and R1-11: 18.3), stay 2 pt above the column's top (the
    /// find's button keeps its clicks) and 4 pt past its foot.
    func testZones() {
        let l = StripLayout.layout(StripDemo.open, height: StripDemo.height, find: false)
        for k in l.groups.indices.dropFirst() { XCTAssertLessThanOrEqual(l.groups[k - 1].zone.upperBound, l.groups[k].zone.lowerBound) }
        let sizes = l.groups.map { $0.zone.upperBound - $0.zone.lowerBound }
        XCTAssertEqual(sizes.min()!, 18.3, accuracy: 0.1)
        XCTAssertGreaterThanOrEqual(l.groups[0].zone.lowerBound, -StripLayout.above)
        XCTAssertLessThanOrEqual(l.groups.last!.zone.upperBound, StripDemo.height + StripLayout.below)
        XCTAssertEqual(l.group(at: l.groups[6].first), 6)
        XCTAssertNil(l.group(at: 170), "between groups' zones: the page's")
        // in Find they halve the gaps with no floor
        let f = StripLayout.layout(StripDemo.find(StripDemo.curriculum), height: StripDemo.height, find: true)
        XCTAssertEqual(f.groups.map { $0.zone.upperBound - $0.zone.lowerBound }.min()!, 16.4, accuracy: 0.1)
    }

    /// Rings closer than 9 pt join a capsule (11 pt long for two, 15 for three or more); ticks closer than 3 pt are one.
    func testJoins() {
        func m(_ k: ScrollerMark.Kind, _ y: Double, _ id: String) -> ScrollerMark {
            ScrollerMark(kind: k, fraction: y / 100, target: k == .toCheck ? .comment(id) : .change(id), page: 0, label: id)
        }
        let a = StripLayout.layout([m(.toCheck, 10, "a"), m(.toCheck, 18.9, "b"), m(.toCheck, 40, "c"), m(.toCheck, 49, "d")],
                                   height: 100, find: false)
        XCTAssertEqual(a.glyphs.map(\.shape), [.capsule, .ring, .ring], "8.9 pt joins, 9 does not")
        XCTAssertEqual(a.glyphs[0].hi - a.glyphs[0].lo, 15.9, accuracy: 0.01, "3.5 pt past each member")
        let two = StripLayout.layout([m(.toCheck, 10, "a"), m(.toCheck, 12, "b")], height: 100, find: false)
        XCTAssertEqual(two.glyphs[0].hi - two.glyphs[0].lo, 11, accuracy: 0.01, "at least 11 pt for two")
        XCTAssertEqual((two.glyphs[0].hi + two.glyphs[0].lo) / 2, 11, accuracy: 0.01, "about their middle")
        let three = StripLayout.layout([m(.toCheck, 10, "a"), m(.toCheck, 11, "b"), m(.toCheck, 12, "c")], height: 100, find: false)
        XCTAssertEqual(three.glyphs[0].hi - three.glyphs[0].lo, 15, accuracy: 0.01)
        let t = StripLayout.layout([m(.edit, 10, "a"), m(.edit, 12.9, "b"), m(.unasked, 30, "c"), m(.unasked, 33, "d")],
                                   height: 100, find: false)
        XCTAssertEqual(t.glyphs.map(\.shape), [.tick, .unaskedTick, .unaskedTick], "2.9 pt is one tick, 3 is two")
        XCTAssertEqual(t.groups.count, 2, "glyphs chaining less than 9 pt apart are one group")
        // rings and ticks in two lanes: both drawn at the same height
        let both = StripLayout.layout([m(.toCheck, 10, "a"), m(.edit, 10, "b")], height: 100, find: false)
        XCTAssertEqual(both.glyphs.map(\.shape), [.ring, .tick])
        XCTAssertEqual(both.groups.count, 1)
    }

    /// D2: with change marks off the unasked edits that wait keep their rings (12 rings or capsules), none otherwise (10).
    func testChangeMarksOff() {
        let l = StripLayout.layout(StripDemo.marksOff, height: StripDemo.height, find: false)
        XCTAssertEqual(shapes(l), [.ring: 9, .capsule: 3])
        let without = StripLayout.layout(StripDemo.open.filter { $0.kind == .toCheck }, height: StripDemo.height, find: false)
        XCTAssertEqual(without.glyphs.count, 10)
    }

    /// Find's matches less than 9 pt apart join a run, at least 6 pt long: "curriculum" 12 ticks and 4 runs.
    func testRuns() {
        let l = StripLayout.layout(StripDemo.find(StripDemo.curriculum), height: StripDemo.height, find: true)
        XCTAssertEqual(shapes(l), [.findTick: 12, .run: 4])
        XCTAssertTrue(l.glyphs.filter { $0.shape == .run }.allSatisfy { $0.hi - $0.lo >= 6 })
        // a dense query: one page's matches in one long run
        let dense = StripDemo.find((0..<45).map { 0.3 + Double($0) * 0.0018 })
        let d = StripLayout.layout(dense, height: StripDemo.height, find: true)
        XCTAssertEqual(d.glyphs.map(\.shape), [.run])
    }

    /// A tick keeps 2 pt clear of a halo round its ring, at rest and grown.
    func testTicksClearTheHalo() {
        let l = StripLayout.layout([ScrollerMark(kind: .toCheck, fraction: 0.5, target: .comment("a"), page: 0, label: ""),
                                    ScrollerMark(kind: .edit, fraction: 0.5, target: .change("b"), page: 0, label: ""),
                                    ScrollerMark(kind: .unasked, fraction: 0.6, target: .change("c"), page: 0, label: "", waits: true)],
                                   height: 100, find: false)
        for grown in [false, true] {
            for ring in l.glyphs where ring.shape == .ring {
                let halo = StripLayout.haloBox(ring, grown: grown)
                for tick in l.glyphs where tick.shape == .tick || tick.shape == .unaskedTick {
                    XCTAssertGreaterThanOrEqual(halo.minX - StripLayout.box(tick, grown: grown).rect.maxX, 2 - 0.001, "grown \(grown)")
                }
            }
        }
        let ring = l.glyphs.first { $0.shape == .ring }!
        XCTAssertEqual(StripLayout.haloBox(ring, grown: false).width, 12, "a 12 pt circle round a ring")
        XCTAssertEqual(StripLayout.haloBox(ring, grown: true).width, 15)
        XCTAssertEqual(StripLayout.box(ring, grown: true).rect.width, 10, "7 pt grows to 10")
        XCTAssertEqual(l.glyph(of: 2), l.glyphs.firstIndex { $0.shape == .ring && $0.members == [2] }, "an unasked edit's halo goes on its ring")
    }

    /// Every ink keeps 3:1 on the page and both backdrops (BRIEF §2).
    func testInksKeepThreeToOne() {
        for ink in [LaneInk.ring, LaneInk.edit, LaneInk.find, LaneInk.selected] {
            for ground in [NSColor.white, NSColor(hex: 0xE2E3E0), NSColor(hex: 0x151615)] {
                XCTAssertGreaterThanOrEqual(Contrast.ratio(ink, ground), 3, "\(ink) on \(ground)")
            }
        }
    }
}

/// E3: a centred card lands whole: the row above it whole under the floating header or hidden by it, whichever moves
/// less, by at most 22 pt; the card kept in view.
final class WholeLandingTests: XCTestCase {
    func testTheRowAboveIsWholeOrHidden() {
        // after the scroll the row above spans 20…64 under a 34 pt header: hidden by moving 30, shown whole by −14
        let above = CGRect(x: 0, y: 120, width: 300, height: 44), card = CGRect(x: 0, y: 168, width: 300, height: 300)
        XCTAssertEqual(ScrollDecision.whole(delta: 100, above: above, card: card, header: 34, viewport: 800), 86, "−14 moves less")
        // spanning 30…74: hidden by 40 (too far), whole by −4
        XCTAssertEqual(ScrollDecision.whole(delta: 90, above: above, card: card, header: 34, viewport: 800), 86)
        // not cut: unchanged
        XCTAssertEqual(ScrollDecision.whole(delta: 50, above: above, card: card, header: 34, viewport: 800), 50)
        // a card taller than the view: its top stays below the header; hiding the row by 12 pt is the smaller move
        let tall = CGRect(x: 0, y: 168, width: 300, height: 1200), row = CGRect(x: 0, y: 104, width: 300, height: 44)
        XCTAssertEqual(ScrollDecision.whole(delta: 100, above: row, card: tall, header: 34, viewport: 800), 114)
    }
}

/// WCAG contrast of two opaque colours.
enum Contrast {
    static func ratio(_ a: NSColor, _ b: NSColor) -> CGFloat {
        func lum(_ c: NSColor) -> CGFloat {
            let c = c.usingColorSpace(.sRGB)!
            func ch(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * ch(c.redComponent) + 0.7152 * ch(c.greenComponent) + 0.0722 * ch(c.blueComponent)
        }
        let x = lum(a), y = lum(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// `c` over `ground` at its alpha.
    static func over(_ c: NSColor, _ ground: NSColor) -> NSColor {
        let a = c.usingColorSpace(.sRGB)!, g = ground.usingColorSpace(.sRGB)!, t = a.alphaComponent
        return NSColor(srgbRed: a.redComponent * t + g.redComponent * (1 - t), green: a.greenComponent * t + g.greenComponent * (1 - t),
                       blue: a.blueComponent * t + g.blueComponent * (1 - t), alpha: 1)
    }
}

/// When the window opens, moves and closes (BRIEF §4.1): dwell and slop, crossing, warm, aim, grace, a click or a key,
/// a press, the floats that block it, Reduce Motion.
@MainActor
final class StripHoverTests: XCTestCase {
    private func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
    private func p(_ y: CGFloat, _ x: CGFloat = 15) -> CGPoint { CGPoint(x: x, y: y) }

    func testTheWindowWaitsForTheDwell() {
        let h = LaneHover()
        var log: [LaneHover.Change] = []
        h.changed = { log.append($0) }
        h.point(0, at: p(100))
        XCTAssertEqual(h.grown, 0, "the mark grows at once")
        XCTAssertNil(h.shown)
        spin(0.15)
        XCTAssertNil(h.shown, "not before 300 ms")
        spin(0.25)
        XCTAssertEqual(h.shown, 0)
        XCTAssertEqual(log.first, .grow)
        XCTAssertTrue(log.contains(.open(instant: false)), "a cold open fades in")
    }

    /// A pointer that keeps moving more than 3 pt never opens it; a hand's tremor within 3 pt does not put it off.
    func testSlop() {
        let h = LaneHover()
        for i in 0..<12 {
            h.point(0, at: p(100 + CGFloat(i) * 4))
            spin(0.04)
        }
        XCTAssertNil(h.shown, "moving along the zone")
        for i in 0..<10 {
            h.point(0, at: p(150 + CGFloat(i % 3), 15 + CGFloat(i % 2)))
            spin(0.04)
        }
        XCTAssertEqual(h.shown, 0, "resting, give or take 3 pt")
    }

    /// Another zone while the window shows: it glides there at once; within 600 ms of a close, a zone opens at once.
    func testCrossingAndWarm() {
        let h = LaneHover()
        var log: [LaneHover.Change] = []
        h.changed = { log.append($0) }
        h.point(0, at: p(100))
        spin(0.4)
        h.point(1, at: p(140))
        XCTAssertEqual(h.shown, 1)
        XCTAssertEqual(h.grown, 1)
        XCTAssertEqual(log.last, .glide)
        h.point(nil, at: p(200))
        spin(0.35)
        XCTAssertNil(h.shown, "gone after the grace")
        XCTAssertEqual(log.last, .close(fade: true))
        h.point(2, at: p(250))
        XCTAssertEqual(h.shown, 2, "warm: at once")
        XCTAssertEqual(log.last, .open(instant: true))
        h.point(nil, at: p(300))
        spin(0.35)
        spin(0.7)
        h.point(3, at: p(350))
        XCTAssertNil(h.shown, "cold again after 600 ms")
    }

    /// On the way to the window, a zone crossed inside the triangle to its right corners takes over only after 150 ms
    /// of rest; outside the triangle, at once.
    func testAim() {
        let h = LaneHover()
        h.point(0, at: p(100))
        spin(0.4)
        h.windowFrame = CGRect(x: -306, y: 80, width: 300, height: 140)  // left of the column
        h.point(1, at: p(112, 8))  // down-left, inside the triangle
        XCTAssertEqual(h.shown, 0, "still the first window")
        spin(0.25)
        XCTAssertEqual(h.shown, 1, "after a rest in it")
        h.point(0, at: p(100))
        XCTAssertEqual(h.shown, 0)
        h.point(1, at: p(140, 20))  // straight down, outside the triangle
        XCTAssertEqual(h.shown, 1, "at once")
    }

    /// Leaving both the zone and the window: gone after 250 ms; back within it, nothing changes; in the window it stays.
    func testGraceAndTheWindow() {
        let h = LaneHover()
        h.point(0, at: p(100))
        spin(0.4)
        h.point(nil, at: p(200))
        spin(0.15)
        h.point(0, at: p(100))
        spin(0.3)
        XCTAssertEqual(h.shown, 0, "back within the grace")
        h.point(nil, at: nil)
        h.enterWindow()
        spin(0.4)
        XCTAssertEqual(h.shown, 0, "in the window")
        XCTAssertEqual(h.grown, 0, "the group stays grown")
        h.leaveWindow()
        spin(0.35)
        XCTAssertNil(h.shown)
        XCTAssertNil(h.grown)
    }

    /// A click, Esc or a key closes it at once; the group under the pointer previews again only once the pointer has
    /// left it.
    func testCloseAtOnceBlocksTheGroup() {
        let h = LaneHover()
        var log: [LaneHover.Change] = []
        h.changed = { log.append($0) }
        h.point(0, at: p(100))
        spin(0.4)
        h.closeNow()
        XCTAssertNil(h.shown)
        XCTAssertEqual(log.last, .close(fade: false))
        XCTAssertEqual(h.grown, 0, "it stays grown under the pointer")
        h.point(0, at: p(106))
        spin(0.4)
        XCTAssertNil(h.shown, "not again in the same zone")
        h.point(nil, at: p(200))
        spin(0.7)
        h.point(0, at: p(100))
        spin(0.4)
        XCTAssertEqual(h.shown, 0, "after leaving it")
    }

    /// With the button down the group is drawn at rest size and nothing opens; nor while a float blocks it (canOpen),
    /// though the mark still grows.
    func testPressAndBlockingFloats() {
        let h = LaneHover()
        h.point(0, at: p(100))
        h.press(true)
        XCTAssertTrue(h.pressed)
        spin(0.4)
        XCTAssertNil(h.shown)
        h.press(false)
        let b = LaneHover()
        b.canOpen = { false }
        b.point(0, at: p(100))
        spin(0.4)
        XCTAssertEqual(b.grown, 0)
        XCTAssertNil(b.shown, "a float, a scroll or an inactive app")
    }

    /// The column laid again: the window follows its group to its new index, or closes when it is gone; a reset clears all.
    func testRemapAndReset() {
        let h = LaneHover()
        h.point(2, at: p(100))
        spin(0.4)
        h.remap(shown: 3)
        XCTAssertEqual(h.shown, 3)
        h.remap(shown: nil)
        XCTAssertNil(h.shown)
        h.reset()
        XCTAssertNil(h.grown)
        XCTAssertNil(h.zone)
    }

    /// The aim's triangle.
    func testTriangle() {
        let a = CGPoint(x: 15, y: 100), b = CGPoint(x: -6, y: 80), c = CGPoint(x: -6, y: 220)
        XCTAssertTrue(LaneHover.inTriangle(CGPoint(x: 5, y: 110), a, b, c))
        XCTAssertFalse(LaneHover.inTriangle(CGPoint(x: 15, y: 140), a, b, c))
        XCTAssertFalse(LaneHover.inTriangle(CGPoint(x: 20, y: 100), a, b, c))
    }

    /// Reduce Motion is read from one place (E11): the override, else the system's; the grow then changes at once.
    func testReduceMotionIsOneSource() {
        Motion.override = true
        defer { Motion.override = nil }
        XCTAssertTrue(Motion.reduced)
        XCTAssertTrue(TabMotion.reduced)
        let lane = MarkLane(frame: CGRect(x: 0, y: 0, width: 30, height: 200))
        let l = StripLayout.layout([ScrollerMark(kind: .toCheck, fraction: 0.5, target: .comment("a"), page: 0, label: "a")],
                                   height: 194, find: false)
        lane.set([ScrollerMark(kind: .toCheck, fraction: 0.5, target: .comment("a"), page: 0, label: "a")], layout: l, find: false)
        lane.setGrown(0, pressed: false, near: nil)
        let layers = lane.layer?.sublayers?.compactMap { $0 as? CAShapeLayer } ?? []
        XCTAssertTrue(layers.allSatisfy { ($0.animationKeys() ?? []).isEmpty }, "no animation")
        Motion.override = false
        XCTAssertFalse(Motion.reduced)
    }
}

/// The window's rows (BRIEF §5.2–5.5): by kind and order, folding, " · N edits", "Unasked edit ·" and its handled form,
/// the page given once, the cap and "+N more", Find's rows, the inks, and placement.
final class StripWindowTests: XCTestCase {
    private func card(_ id: String, page: Int, note: String = "A note.") throws -> CardModel {
        CardModel(try makeComment(["id": id, "page": page, "note": note]), round: 2, pdfs: [:], textX: [], showChanges: true)
    }

    private func change(_ id: String, page: Int, answers: [String] = [], unasked: Bool = false, checked: Bool = false) throws -> ChangeModel {
        model(try makeChange(["id": id, "page": page, "attached_to": answers, "unrequested": unasked, "checked": checked,
                              "section": "Setup"]), statuses: Dictionary(answers.map { ($0, .toCheck) }, uniquingKeysWith: { a, _ in a }))
    }

    private func rows(_ items: [ScrollerMark], cards: [CardModel], changes: [ChangeModel], pointer: CGFloat? = nil,
                      current: Int? = nil, height: CGFloat = 100) -> LaneRows {
        let ys = items.map { CGFloat($0.fraction) * height }
        var edits: [String: Int] = [:]
        for ch in changes { for l in ch.links { edits[l.id, default: 0] += 1 } }
        return LaneRows.make(Array(items.indices), items: items, ys: ys, pointer: pointer, currentMatch: current,
                             card: { id in cards.first { $0.id == id } }, change: { id in changes.first { $0.id == id } },
                             edits: { edits[$0] ?? 0 }, line: { i in LaneMatchLine(before: "line ", match: "m\(i)", after: "") })
    }

    private func c(_ id: String, _ f: Double, page: Int = 4) -> ScrollerMark {
        ScrollerMark(kind: .toCheck, fraction: f, target: .comment(id), page: page, label: id)
    }

    private func e(_ id: String, _ f: Double, of: String?, page: Int = 4, unasked: Bool = false, waits: Bool = false) -> ScrollerMark {
        ScrollerMark(kind: unasked ? .unasked : .edit, fraction: f, target: .change(id), page: page, label: id, waits: waits, answers: of)
    }

    /// G11: R1-12 and R1-13 to check, then one row for R1-09's two edits (it is not listed); the page given once.
    func testOrderAndFolding() throws {
        let items = [c("R1-12", 0.50), c("R1-13", 0.505), e("c14", 0.51, of: "R1-09"), e("c15", 0.51, of: "R1-09")]
        let r = rows(items, cards: [try card("R1-12", page: 4), try card("R1-13", page: 4)],
                     changes: [try change("c14", page: 4, answers: ["R1-09"]), try change("c15", page: 4, answers: ["R1-09"])])
        XCTAssertEqual(r.rows.map(\.id), ["c:R1-12", "c:R1-13", "e:c14"])
        XCTAssertEqual(r.rows.map(\.showsPage), [true, false, false], "the page once")
        XCTAssertTrue(r.words[2].hasPrefix("R1-09 · 2 edits § Setup"), r.words[2])
        XCTAssertEqual(r.target, .comment("R1-12"), "a click on the mark: the first comment to check")
        XCTAssertEqual(r.height, 140, "three rows")
        // an edit answering a comment the window lists has no row: the comment's " · 2 edits" counts it
        let g2 = rows([c("R1-05", 0.1, page: 0), e("c05", 0.11, of: "R1-05", page: 0), e("c06", 0.11, of: "R1-05", page: 0)],
                      cards: [try card("R1-05", page: 0)],
                      changes: [try change("c05", page: 0, answers: ["R1-05"]), try change("c06", page: 0, answers: ["R1-05"])])
        XCTAssertEqual(g2.rows.count, 1)
        XCTAssertTrue(g2.words[0].contains("· 2 edits"), g2.words[0])
        XCTAssertTrue(g2.single)
        XCTAssertEqual(g2.height, 68, "one item: its 60 pt row and the padding")
    }

    /// Comments first, then the unasked edits that wait, then the other edits, then the unasked edits handled; an
    /// unasked edit names itself, with its ring while it waits and ✓ once handled.
    func testUnaskedEdits() throws {
        let items = [e("c20", 0.30, of: nil, unasked: true, waits: false), e("c11", 0.31, of: nil, unasked: true, waits: true),
                     c("R1-08", 0.32), e("c09", 0.33, of: "R1-07")]
        let r = rows(items, cards: [try card("R1-08", page: 4)],
                     changes: [try change("c20", page: 4, unasked: true, checked: true), try change("c11", page: 4, unasked: true),
                               try change("c09", page: 4, answers: ["R1-07"])])
        XCTAssertEqual(r.rows.map(\.id), ["c:R1-08", "e:c11", "e:c09", "e:c20"])
        XCTAssertTrue(r.words[1].hasPrefix("○ Unasked edit · Edited § Setup"), r.words[1])
        XCTAssertTrue(r.words[3].hasPrefix("✓ Unasked edit · Edited"), r.words[3])
        let only = rows([e("c11", 0.3, of: nil, unasked: true, waits: true), e("c09", 0.31, of: "R1-07")], cards: [],
                        changes: [try change("c11", page: 4, unasked: true), try change("c09", page: 4, answers: ["R1-07"])])
        XCTAssertEqual(only.target, .change("c11"), "no comment: the first unasked edit that waits")
    }

    /// At most five rows; "+N more · p.4–5" for the rest, whose first is where a click on it goes.
    func testTheCap() throws {
        let ids = (1...7).map { "R1-\($0)" }
        let items = ids.enumerated().map { c($1, 0.3 + Double($0) * 0.01, page: $0 < 6 ? 3 : 4) }
        let r = rows(items, cards: try ids.enumerated().map { try card($1, page: $0 < 6 ? 3 : 4) }, changes: [])
        XCTAssertEqual(r.rows.count, 5)
        XCTAssertEqual(r.more, 2)
        XCTAssertEqual(r.morePages, "p.4–5")
        XCTAssertEqual(r.moreTarget, .comment("R1-6"))
        XCTAssertEqual(r.words.last, "+2 more · p.4–5")
        XCTAssertEqual(r.height, 256, "five rows and \"+N more\"")
    }

    /// Find: a run of more than five shows the five matches nearest the pointer, in page order; the current match is
    /// the row a click opens when it is listed, else the one nearest the pointer.
    func testFindRows() {
        let items = (0..<9).map { ScrollerMark(kind: .find, fraction: 0.5 + Double($0) * 0.01, target: .find($0), page: 3, label: "") }
        let r = rows(items, cards: [], changes: [], pointer: 54)  // y 50 … 58: nearest 54 are matches 2…6
        XCTAssertEqual(r.rows.map(\.target), (2...6).map { .find($0) })
        XCTAssertEqual(r.more, 4)
        XCTAssertEqual(r.target, .find(4), "the match nearest the pointer")
        let cur = rows(items, cards: [], changes: [], pointer: 54, current: 3)
        XCTAssertEqual(cur.target, .find(3), "the current match")
        XCTAssertTrue(cur.words[0].hasPrefix("3 of 9 · p.4 | line [m2]"), cur.words[0])
    }

    /// The match's line cut so the match stays in view.
    func testTheMatchLine() {
        let line = "Distillation of a student with curriculum length S and a temperature"
        let l = LaneMatchLine.cut(line, match: line.range(of: "curriculum")!)
        XCTAssertTrue(l.before.hasPrefix("…"))
        XCTAssertLessThanOrEqual(l.before.count, 25)
        XCTAssertEqual(l.match, "curriculum")
        XCTAssertEqual(LaneMatchLine.cut("short curriculum", match: "short curriculum".range(of: "curriculum")!).before, "short ")
    }

    /// 300 pt wide, its right edge 6 pt left of the column; its first line level with the glyph (top = glyph − 17.5);
    /// 8 pt under the find's button or bar; up at the view's foot (G13: 797.0 in the capture); it fits at 420 pt.
    func testPlacement() {
        let view = CGSize(width: 802, height: 834.5)
        let f = LaneRows.frame(height: 68, first: 407.0 - 38.5, view: view, under: 40)
        XCTAssertEqual(f.width, 300)
        XCTAssertEqual(f.maxX, 802 - 56)
        XCTAssertEqual(f.minY + LaneRows.line1, 407.0 - 38.5, accuracy: 0.01)
        XCTAssertEqual(LaneRows.frame(height: 68, first: 823.8 - 38.5, view: view, under: 40).minY + 38.5, 797.0, accuracy: 0.1)
        XCTAssertEqual(LaneRows.frame(height: 140, first: 50, view: view, under: 41).minY, 49, "under the open find bar")
        XCTAssertGreaterThanOrEqual(LaneRows.frame(height: 256, first: 300, view: CGSize(width: 420, height: 600), under: 40).minX, 8)
    }

    /// The window's inks against §2's table: words 4.5:1, signs 3:1, on the float and on the hover fill, in both modes.
    func testWindowInks() {
        for dark in [false, true] {
            let a = NSAppearance(named: dark ? .darkAqua : .aqua)!
            var floor: [(NSColor, CGFloat)] = []
            a.performAsCurrentDrawingAppearance {
                floor = [(Palette.label, 4.5), (Palette.label2, 4.5), (Palette.secondary, 4.5), (Palette.rowChangedWords, 4.5),
                         (Palette.unrequested, 4.5), (Palette.toCheck, 3), (Palette.neutral, 3)]
                    .map { (NSColor(cgColor: $0.0.cgColor)!, $0.1) }
                let float = NSColor(cgColor: Palette.float.cgColor)!, fill = Contrast.over(NSColor(cgColor: Palette.hover.cgColor)!, float)
                for (ink, need) in floor {
                    XCTAssertGreaterThanOrEqual(Contrast.ratio(ink, float), need, "\(ink) dark \(dark)")
                    XCTAssertGreaterThanOrEqual(Contrast.ratio(ink, fill), need, "\(ink) on the fill, dark \(dark)")
                }
            }
        }
    }
}

/// The column in a PDF view on the round 2 fixture: its items, a click that selects with a step of Back and the
/// halo, Back moving only the PDF, D2's rings and outline with change marks off.
@MainActor
final class StripFlowTests: XCTestCase {
    private var drafts: URL!
    private var window: NSWindow!
    private var model: AppModel!
    private var view: ReviewPDFView!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        drafts = FileManager.default.temporaryDirectory.appendingPathComponent("pc-strip-drafts-" + UUID().uuidString)
        var o = LaunchOptions()
        o.fixture = StepTests.fixtures.appendingPathComponent("state-reading.json").path
        o.drafts = drafts.path
        model = AppModel(options: o)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view = ReviewPDFView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(view)
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        model.pdf.attach(view)
        model.pdf.update(url: model.pdfURL, key: MarkKey(version: model.stateVersion, showChanges: true))
        view.layoutDocumentView()
        model.pdf.viewLaidOut(force: true)
        model.pdf.updateStrip()
    }

    override func tearDownWithError() throws {
        Motion.override = nil
        window.close()
        try? FileManager.default.removeItem(at: drafts)
    }

    private func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    private var targets: [ScrollerMark.Target] { model.pdf.strip.items.map(\.target) }

    /// The column at R − 50 … R − 20, from 44 pt under the view's top; the comments to check and the unasked edits that
    /// wait as rings; with change marks off those edits keep theirs (D2), their ticks gone.
    func testItemsAndD2() throws {
        let lane = try XCTUnwrap(model.pdf.lane)
        XCTAssertEqual(lane.frame.minX, view.bounds.width - 50)
        XCTAssertEqual(lane.frame.width, 30)
        XCTAssertEqual(lane.frame.maxY, view.bounds.height - 44, accuracy: 0.01)
        let items = model.pdf.strip.items
        XCTAssertTrue(targets.contains(.comment("R1-05")))
        XCTAssertFalse(targets.contains(.comment("R1-01")), "a resolved comment has no mark")
        XCTAssertFalse(targets.contains(.comment("R1-08")), "not found: no place")
        XCTAssertEqual(items.first { $0.target == .change("c03") }?.waits, true)
        XCTAssertTrue(items.first { $0.target == .change("c01") }.map { $0.kind == .edit && $0.tick } ?? false)
        model.showChanges = false
        model.pdf.update(url: model.pdfURL, key: MarkKey(version: model.stateVersion, showChanges: false))
        let off = model.pdf.strip.items
        XCTAssertNil(off.first { $0.target == .change("c01") }, "edits follow change marks")
        XCTAssertEqual(off.first { $0.target == .change("c03") }.map { [$0.waits, $0.tick] }, [true, false], "D2: its ring alone")
        // its outline is drawn while it is selected, with change marks off (BRIEF D2)
        model.tab = .changes
        model.select(.change("c03"), scroll: nil)
        XCTAssertTrue(model.pdf.selectedMarks.contains("c03"))
        model.select(.change("c01"), scroll: nil)
        XCTAssertFalse(model.pdf.selectedMarks.contains("c01"), "another edit follows change marks")
    }

    /// A click on a mark selects as Jump does, with a step of Back and the halo; a second click scrolls nothing; Back
    /// moves only the PDF, the selection and halo staying.
    func testClickHaloAndBack() throws {
        view.go(to: view.document!.page(at: 2)!)
        view.layoutDocumentView()
        model.pdf.ownMove()
        let l = model.pdf.strip.layout
        let g = try XCTUnwrap(l.groups.firstIndex { $0.members.contains { model.pdf.strip.items[$0].target == .comment("R1-06") } })
        model.pdf.laneClick(g, at: CGPoint(x: StripLayout.axis, y: l.groups[g].first))
        view.layoutDocumentView()
        XCTAssertEqual(model.selection, .comment("R1-06"))
        XCTAssertEqual(model.tab, .comments)
        let halo = try XCTUnwrap(model.pdf.lane?.halo)
        XCTAssertTrue(l.glyphs[halo].members.contains { model.pdf.strip.items[$0].target == .comment("R1-06") })
        XCTAssertEqual(model.navHistory.back.filter(\.step).count, 1, "a look-up's step")
        let page = model.pdf.shownPage
        model.pdf.laneClick(g, at: CGPoint(x: StripLayout.axis, y: l.groups[g].first))
        XCTAssertEqual(model.pdf.shownPage, page, "the item already selected: nothing scrolls")
        XCTAssertTrue(model.pdf.flashing, "its mark flashes again")
        model.goBack()
        view.layoutDocumentView()
        XCTAssertEqual(model.pdf.shownPage, 2)
        XCTAssertEqual(model.selection, .comment("R1-06"), "Back moves only the PDF")
        XCTAssertEqual(model.pdf.lane?.halo, halo)
    }

    /// Find: the column shows only its matches (rings come back when it closes); the current match is Sage; at a
    /// match the floating toolbar is the Comment button alone (E5); a selection of your own has the whole toolbar.
    func testFindsColumnAndCommentOnlyToolbar() throws {
        let find = model.pdf.find
        find.find("Catalyzer", fromStart: true)
        let deadline = Date().addingTimeInterval(5)
        repeat { spin(0.02) } while find.isSearching && Date() < deadline
        spin(0.6)
        XCTAssertTrue(model.pdf.strip.find)
        XCTAssertTrue(model.pdf.strip.items.allSatisfy { $0.kind == .find })
        XCTAssertNotNil(model.pdf.lane?.current, "the current match's tick")
        XCTAssertTrue(model.toolbar.matchOnly, "the Comment button alone at a match")
        XCTAssertTrue(model.pdf.lane?.accessibilityValue() as? String == LaneText.matches(model.pdf.strip.items.count))
        let line = find.matchLine(find.index ?? 0)
        XCTAssertEqual(line.match.lowercased(), "catalyzer")
        find.close()
        XCTAssertFalse(model.pdf.strip.find)
        XCTAssertTrue(model.pdf.strip.items.contains { $0.kind == .toCheck }, "the rings come back")
    }

    /// The status line says the page count once, and no zero (E6); rows under To check have no ○ (E7).
    func testStatusWordsAndRowsUnderToCheck() throws {
        var b = try XCTUnwrap(model.round?.build)
        XCTAssertFalse(BuildStatusLine.details(b).contains("page"))
        b.warnings = []
        XCTAssertEqual(BuildStatusLine.details(b), "")
        b.warnings = ["w"]
        XCTAssertEqual(BuildStatusLine.details(b), " · 1 warning")
        let list = CommentListController(panel: model.panel, actions: model.actions, edit: model.edit)
        var under = false
        for r in list.rows() {
            if case .header(let t, _, _, _) = r { under = t == "To check" }
            if case .item(.card(let c)) = r { XCTAssertEqual(c.underToCheck, under, c.id) }
        }
        withExtendedLifetime(list) {}
    }

    /// The window opens at a forced hover with the group's rows, beside the column; any key and Esc close it.
    func testTheWindow() throws {
        model.pdf.laneForced = true
        let g = 0
        LaneHover.dwell = 0
        defer { LaneHover.dwell = 0.3 }
        spin(0.2)  // the PDF still for 150 ms
        model.pdf.lanePointer(g, at: CGPoint(x: 15, y: model.pdf.strip.layout.groups[g].first))
        spin(0.05)
        XCTAssertEqual(model.pdf.laneHover.shown, g)
        let host = try XCTUnwrap(model.pdf.laneWindowView)
        XCTAssertFalse(host.isHidden)
        XCTAssertEqual(host.frame.maxX, view.bounds.width - 56, accuracy: 0.5)
        XCTAssertEqual(host.frame.width, 300)
        XCTAssertFalse(model.pdf.laneWindow.rows.rows.isEmpty)
        XCTAssertEqual(host.layer?.shadowOpacity, 0.14, "E1: the float's shadow")
        model.pdf.closeLane()
        XCTAssertNil(model.pdf.laneHover.shown)
        XCTAssertTrue(host.isHidden)
    }
}
