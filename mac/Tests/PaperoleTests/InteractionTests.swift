import CoreGraphics
import XCTest
@testable import Paperole

final class MarkHitTests: XCTestCase {
    let label = MarkShape.label("R1-01", CGRect(x: 545, y: 600, width: 24, height: 9), order: 0)
    let small = MarkShape.text("R2-01", [CGRect(x: 351, y: 640, width: 15, height: 10)], order: 2)
    let box = MarkShape.box("R1-10", [CGRect(x: 147, y: 630, width: 317, height: 69)], order: 1)

    func testOrderLabelsThenTextThenBoxes() {
        XCTAssertEqual(MarkHit.hits(at: CGPoint(x: 358, y: 645), shapes: [box, small, label], minSize: 6), ["R2-01", "R1-10"])
        XCTAssertEqual(MarkHit.hits(at: CGPoint(x: 300, y: 650), shapes: [box, small], minSize: 6), ["R1-10"])
        XCTAssertEqual(MarkHit.hits(at: CGPoint(x: 556, y: 604), shapes: [box, small, label], minSize: 6), ["R1-01"])
        XCTAssertEqual(MarkHit.hits(at: CGPoint(x: 20, y: 20), shapes: [box, small, label], minSize: 6), [])
    }

    func testSmallerAreaThenDocumentOrder() {
        let wide = MarkShape.text("A", [CGRect(x: 0, y: 0, width: 200, height: 10)], order: 0)
        let narrow = MarkShape.text("B", [CGRect(x: 50, y: 0, width: 20, height: 10)], order: 1)
        let twin = MarkShape.text("C", [CGRect(x: 50, y: 0, width: 20, height: 10)], order: 2)
        XCTAssertEqual(MarkHit.hits(at: CGPoint(x: 60, y: 5), shapes: [wide, twin, narrow], minSize: 1), ["B", "C", "A"])
    }

    func testAreasHaveAMinimumSize() {
        let caret = MarkShape.caret("G", CGRect(x: 100, y: 100, width: 2, height: 10), order: 0)
        XCTAssertEqual(caret.areas[0].size, CGSize(width: 10, height: 14))
        XCTAssertEqual(MarkHit.hits(at: CGPoint(x: 107, y: 105), shapes: [caret], minSize: 6), [])
        XCTAssertEqual(MarkHit.hits(at: CGPoint(x: 107, y: 105), shapes: [caret], minSize: 20), ["G"])  // zoomed out
        let point = MarkShape.point("N", CGPoint(x: 10, y: 10), order: 0)
        XCTAssertEqual(point.areas[0], CGRect(x: 4, y: 4, width: 12, height: 12))
        XCTAssertEqual(label.areas[0], CGRect(x: 543, y: 598, width: 28, height: 13))
    }

    func testCycling() {
        XCTAssertEqual(MarkHit.pick(["A", "B", "C"], selected: nil), "A")
        XCTAssertEqual(MarkHit.pick(["A", "B", "C"], selected: "A"), "B")
        XCTAssertEqual(MarkHit.pick(["A", "B", "C"], selected: "C"), "A")
        XCTAssertEqual(MarkHit.pick(["A", "B"], selected: "Z"), "A")
        XCTAssertNil(MarkHit.pick([], selected: "A"))
    }

    func testChangeBandsAndCrosses() {
        let r = CGRect(x: 100, y: 200, width: 50, height: 10)
        XCTAssertTrue(MarkHit.changeHit(at: CGPoint(x: 120, y: 198), rects: [r], isDelete: false))
        XCTAssertFalse(MarkHit.changeHit(at: CGPoint(x: 120, y: 205), rects: [r], isDelete: false))
        XCTAssertTrue(MarkHit.changeHit(at: CGPoint(x: 128, y: 207), rects: [r], isDelete: true))
        // on the Changes tab the changed words themselves are the target, + 2 pt, and at least 8 view points high
        XCTAssertTrue(MarkHit.changeHit(at: CGPoint(x: 120, y: 205), rects: [r], isDelete: false, whole: true))
        XCTAssertTrue(MarkHit.changeHit(at: CGPoint(x: 99, y: 211.5), rects: [r], isDelete: false, whole: true))
        XCTAssertFalse(MarkHit.changeHit(at: CGPoint(x: 120, y: 213), rects: [r], isDelete: false, whole: true))
        let thin = CGRect(x: 100, y: 200, width: 1, height: 2)
        XCTAssertTrue(MarkHit.changeHit(at: CGPoint(x: 96, y: 201), rects: [thin], isDelete: false, whole: true, minSize: 10))
    }
}

final class ScrollDecisionTests: XCTestCase {
    func testVisibleCardDoesNotMove() {
        XCTAssertNil(ScrollDecision.decide(minY: 16, maxY: 300, viewport: 800, mode: .centre))
        XCTAssertNil(ScrollDecision.decide(minY: 400, maxY: 784, viewport: 800, mode: .minimal))
    }

    func testCentre() {
        let d = ScrollDecision.decide(minY: 900, maxY: 1100, viewport: 800, mode: .centre)
        XCTAssertEqual(d, ScrollDecision(delta: 600, animated: true))  // lands at 300…500
        XCTAssertEqual(ScrollDecision.decide(minY: -300, maxY: -100, viewport: 800, mode: .centre)?.delta, -600)
    }

    func testMinimalScrollsTopFirst() {
        XCTAssertEqual(ScrollDecision.decide(minY: 700, maxY: 900, viewport: 800, mode: .minimal)?.delta, 116)
        XCTAssertEqual(ScrollDecision.decide(minY: -50, maxY: 150, viewport: 800, mode: .minimal)?.delta, -66)
    }

    func testTallCardTopsAt16() {
        XCTAssertEqual(ScrollDecision.decide(minY: 300, maxY: 1300, viewport: 800, mode: .centre)?.delta, 284)
        XCTAssertEqual(ScrollDecision.decide(minY: 300, maxY: 1300, viewport: 800, mode: .minimal)?.delta, 284)
        XCTAssertNil(ScrollDecision.decide(minY: 16, maxY: 1300, viewport: 800, mode: .minimal))
    }

    /// R on a card taller than the panel: the least movement that shows its end, the follow-up field above the answer
    /// row (behaviour review 2026-10-19: the cursor went into a field out of view); another card as `minimal`.
    func testTheFieldsEnd() {
        XCTAssertEqual(ScrollDecision.decide(minY: 16, maxY: 1300, viewport: 800, mode: .end)?.delta, 516)
        XCTAssertNil(ScrollDecision.decide(minY: -500, maxY: 700, viewport: 800, mode: .end), "its end in view")
        XCTAssertEqual(ScrollDecision.decide(minY: 700, maxY: 900, viewport: 800, mode: .end)?.delta, 116)
        XCTAssertNil(ScrollDecision.decide(minY: 400, maxY: 784, viewport: 800, mode: .end))
    }

    func testLongJumpsAndReduceMotionAreInstant() {
        XCTAssertEqual(ScrollDecision.decide(minY: 3000, maxY: 3100, viewport: 800, mode: .centre)?.animated, false)
        XCTAssertEqual(ScrollDecision.decide(minY: 900, maxY: 1100, viewport: 800, mode: .centre, reduceMotion: true)?.animated, false)
    }
}

final class KeyRouteTests: XCTestCase {
    func state(_ f: (inout KeyState) -> Void) -> KeyState {
        var s = KeyState()
        s.roundOpen = true
        f(&s)
        return s
    }

    func testSelectionFirst() {
        let s = state { $0.textSelection = true; $0.card = .new }
        XCTAssertEqual(KeyRoute.action("return", s), .openEditor)
        XCTAssertEqual(KeyRoute.action("3", s), .pendingColor(.blue))
        XCTAssertEqual(KeyRoute.action("u", s), .pendingKind(.underline))
        XCTAssertEqual(KeyRoute.action("esc", s), .clearSelection)
        XCTAssertEqual(KeyRoute.action("j", s), .next)
        let box = state { $0.pendingBox = true }
        XCTAssertNil(KeyRoute.action("h", box))  // a box stays a box
        XCTAssertEqual(KeyRoute.action("return", box), .openEditor)
    }

    func testCardKeys() {
        let fresh = state { $0.card = .new }
        XCTAssertEqual(KeyRoute.action("return", fresh), .editNote)
        XCTAssertEqual(KeyRoute.action("delete", fresh), .delete)
        XCTAssertEqual(KeyRoute.action("6", fresh), .recolor(.orange))
        XCTAssertNil(KeyRoute.action("v", fresh))  // verdicts only for carried comments
        let carried = state { $0.card = .carried(answered: false) }
        XCTAssertEqual(KeyRoute.action("v", carried), .verdict("verified"))
        XCTAssertEqual(KeyRoute.action("r", carried), .verdict("reopened"))
        XCTAssertEqual(KeyRoute.action("w", carried), .verdict("wontfix"))
        XCTAssertEqual(KeyRoute.action("return", carried), .focusField)  // into the follow-up field
        XCTAssertNil(KeyRoute.action("delete", carried))
        XCTAssertEqual(KeyRoute.action("return", state { $0.card = .carried(answered: true) }), .editRemark)
        XCTAssertEqual(KeyRoute.action("b", carried), .armBox)
    }

    func testChangeKeys() {
        let change = state { $0.changeSelected = true }
        XCTAssertEqual(KeyRoute.action("v", change), .check)
        XCTAssertEqual(KeyRoute.action("j", change), .next)
        XCTAssertNil(KeyRoute.action("r", change))
        XCTAssertNil(KeyRoute.action("v", state { $0.changeSelected = true; $0.reanchoring = true }))
        // Return comments on the selected change ("Comment on it… ↩"); with text selected it opens the editor on that
        XCTAssertEqual(KeyRoute.action("return", change), .commentOnChange)
        XCTAssertEqual(KeyRoute.action("return", state { $0.changeSelected = true; $0.textSelection = true }), .openEditor)
        var closed = KeyState()
        closed.changeSelected = true
        XCTAssertNil(KeyRoute.action("v", closed))
        XCTAssertNil(KeyRoute.action("return", closed))
    }

    func testEscDisarmsBoxMode() {
        XCTAssertEqual(KeyRoute.action("esc", state { $0.boxArmed = true; $0.textSelection = true }), .armBox)
        XCTAssertEqual(KeyRoute.action("esc", state { $0.textSelection = true }), .clearSelection)
    }

    func testMissingFileHeadline() throws {
        let b = try makeDecoder().decode(Build.self, from: Data("""
        {"status": "failed", "pdf": null, "warnings": [], "errors": [{"file": "main.tex", "line": 88,
         "message": "LaTeX Error: File `tables/results.tex' not found."}], "log_tail": ""}
        """.utf8))
        XCTAssertEqual(missingFile(b), "tables/results.tex")
        var ok = b
        ok.errors = []
        XCTAssertNil(missingFile(ok))
    }

    func testReanchorMode() {
        let s = state { $0.reanchoring = true; $0.card = .carried(answered: false) }
        XCTAssertEqual(KeyRoute.action("return", s), .place)
        XCTAssertEqual(KeyRoute.action("esc", s), .leaveReanchor)
        XCTAssertNil(KeyRoute.action("j", s))
        XCTAssertNil(KeyRoute.action("v", s))
        XCTAssertEqual(KeyRoute.action("return", state { $0.reanchoring = true; $0.textSelection = true }), .place)
    }

    func testClosedRound() {
        var s = KeyState()
        s.card = .carried(answered: false)
        s.textSelection = true
        XCTAssertEqual(KeyRoute.action("j", s), .next)
        XCTAssertEqual(KeyRoute.action("k", s), .previous)
        for k in ["v", "return", "1", "b", "esc", "delete", "cmd-z", "cmd-return"] { XCTAssertNil(KeyRoute.action(k, s), k) }
    }
}

final class PaletteTests: XCTestCase {
    func testColoursAndKeys() {
        XCTAssertEqual(MarkColor.allCases.map(\.rawValue), ["yellow", "teal", "blue", "pink", "purple", "orange"])
        XCTAssertEqual(MarkColor.allCases.map(\.key), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(MarkColor.forKey(4), .pink)
        XCTAssertNil(MarkColor.forKey(7))
        XCTAssertEqual(MarkColor.yellow.fill, NSColor(hex: 0xEAB308))
        XCTAssertEqual(MarkColor.orange.ink, NSColor(hex: 0xC2410C))
    }

    /// Each status colour as a word on the card, in either mode, and each ink on white reach 4.5:1 (UX.md §2, §5).
    func testContrast() {
        func lum(_ c: NSColor) -> CGFloat {
            let s = c.usingColorSpace(.sRGB)!
            func ch(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * ch(s.redComponent) + 0.7152 * ch(s.greenComponent) + 0.0722 * ch(s.blueComponent)
        }
        func resolved(_ c: NSColor, _ name: NSAppearance.Name) -> NSColor {
            var out = NSColor.black
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance { out = c.usingColorSpace(.sRGB)! }
            return out
        }
        for s in [Status.new, .toCheck, .notFound, .followUp, .resolved, .keptAsIs] {
            XCTAssertGreaterThanOrEqual(1.05 / (lum(resolved(s.color, .aqua)) + 0.05), 4.5, s.word)
            XCTAssertGreaterThanOrEqual((lum(resolved(s.color, .darkAqua)) + 0.05)
                                        / (lum(resolved(Palette.card, .darkAqua)) + 0.05), 4.5, s.word)
        }
        for c in MarkColor.allCases { XCTAssertGreaterThanOrEqual(1.05 / (lum(c.ink) + 0.05), 4.5, c.name) }
        // the unrequested colour as text: on light panels (white, #ECECEC) and dark ones (#1E1E1E, #323232)
        let light = lum(resolved(Palette.unrequested, .aqua)), dark = lum(resolved(Palette.unrequested, .darkAqua))
        for bg in [0xFFFFFF, 0xECECEC] { XCTAssertGreaterThanOrEqual((lum(NSColor(hex: bg)) + 0.05) / (light + 0.05), 4.5) }
        for bg in [0x1E1E1E, 0x323232] { XCTAssertGreaterThanOrEqual((dark + 0.05) / (lum(NSColor(hex: bg)) + 0.05), 4.5) }
        XCTAssertEqual(Palette.unrequestedBand, NSColor(hex: 0x355F6C))  // the PDF page is white in either mode
        // the papers list's badge is grey since POLISH §3 row 7 (DesignPaletteTests has the v2.1 palette)
    }

    func testStatus() throws {
        XCTAssertEqual(Status(try makeComment(["verdict": "wontfix"])), .keptAsIs)
        XCTAssertEqual(Status(try makeComment(["verdict": "verified"])), .resolved)
        XCTAssertEqual(Status(try makeComment(["verdict": "reopened"])), .followUp)
        XCTAssertEqual(Status(try makeComment([:])), .toCheck)
        XCTAssertEqual(Status(try makeComment(["anchor_state": "orphan"])), .notFound)  // counts as to check
        XCTAssertEqual(Status(try makeComment(["anchor_state": "orphan", "verdict": "verified"])), .resolved)
        XCTAssertEqual(Status(try makeComment(["carried": false])), .new)
        XCTAssertTrue(Status.resolved.closed && Status.keptAsIs.closed && !Status.followUp.closed && !Status.notFound.closed)
        // v2's words (design/ui-v2/PROPOSAL.md §1.4); the PDF label's glyphs
        XCTAssertEqual([Status.toCheck, .followUp, .resolved, .keptAsIs, .new, .notFound].map(\.word),
                       ["To check", "Follow-up", "Resolved", "Kept as is", "New", "Not found"])
        XCTAssertEqual([Status.toCheck, .followUp, .resolved, .keptAsIs, .new].map(\.glyph), ["○", "↩", "✓", "–", "+"])
        XCTAssertEqual(MarkKind(rawValue: "box")?.symbol, "rectangle.dashed")
        XCTAssertEqual(MarkKind.textKinds.compactMap(\.key), ["h", "u", "s"])
    }
}
