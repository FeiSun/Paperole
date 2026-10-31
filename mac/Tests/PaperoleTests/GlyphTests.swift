import AppKit
import SwiftUI
import XCTest
@testable import Paperole

/// UI v4's status signs (design/ui-v4/BRIEF.md §3, §8.4; IMPLEMENTATION.md step 1): the ring fills clockwise from 12
/// o'clock, every paper status has its sign, and only the ring is vermilion.
final class GlyphTests: XCTestCase {
    func testTheWedgeFillsClockwise() throws {
        let g = RingGeometry(px: 14)
        XCTAssertEqual(g.stroke, max(1.8, 26 / 14), accuracy: 1e-9)
        XCTAssertEqual(g.inner, g.radius - g.stroke / 2 - 20 / 14, accuracy: 1e-9, "1 pt inside the stroke")
        XCTAssertNil(g.wedge(0), "empty at 0")
        let d = g.inner * 0.6  // a point well inside the wedge's circle, in each quarter
        let upperRight = CGPoint(x: 10 + d, y: 10 - d), lowerRight = CGPoint(x: 10 + d, y: 10 + d)
        let lowerLeft = CGPoint(x: 10 - d, y: 10 + d), upperLeft = CGPoint(x: 10 - d, y: 10 - d)
        let quarter = try XCTUnwrap(g.wedge(0.25))
        XCTAssertTrue(quarter.contains(upperRight), "a quarter: from 12 to 3 o'clock")
        XCTAssertFalse(quarter.contains(upperLeft))
        XCTAssertFalse(quarter.contains(lowerRight))
        XCTAssertEqual(quarter.boundingRect.minX, 10, accuracy: 0.01)
        XCTAssertEqual(quarter.boundingRect.maxY, 10, accuracy: 0.01)
        let half = try XCTUnwrap(g.wedge(0.5))
        XCTAssertTrue(half.contains(upperRight) && half.contains(lowerRight), "a half: the right side")
        XCTAssertFalse(half.contains(lowerLeft) || half.contains(upperLeft))
        let full = try XCTUnwrap(g.wedge(1))
        XCTAssertTrue([upperRight, lowerRight, lowerLeft, upperLeft].allSatisfy { full.contains($0) }, "solid at 1")
        XCTAssertEqual(full.boundingRect.width, 2 * g.inner, accuracy: 0.01)
        XCTAssertEqual(g.wedge(1.4)?.boundingRect, full.boundingRect, "never more than full")
        XCTAssertEqual(RingGeometry(px: 21).stroke, 1.8, "the stroke at least 1.8 units, thicker only when drawn small")
    }

    func testEveryStatusHasItsSign() {
        let all: [(PaperStatus, StatusGlyph)] = [
            (.noRounds, .noRounds), (.firstDraft, .ring(0)), (.toCheck(comments: 3, edits: 1), .ring(0)), (.toRead(4), .ring(1)),
            (.ready, .ready), (.failed, .failed), (.waiting, .waiting), (.finished("2026-07-20"), .finished),
        ]
        for (s, g) in all { XCTAssertEqual(StatusGlyph.of(s), g, "\(s)") }
        XCTAssertEqual(StatusGlyph.of(.toCheck(comments: 3, edits: 1), fill: 0.25), .ring(0.25))
        XCTAssertEqual(StatusGlyph.of(.firstDraft, fill: 0.5), .ring(0), "a first draft has nothing to answer yet")
    }

    func testTheSignsColours() {
        XCTAssertEqual(StatusGlyph.ring(0.5).color, Palette.toCheck, "the one vermilion sign")
        XCTAssertEqual(StatusGlyph.nothingWaits.color, Palette.secondary, "nothing waits: the ring in secondary")
        XCTAssertEqual(StatusGlyph.ready.color, Palette.accent)
        XCTAssertEqual(StatusGlyph.wellDone.color, Palette.accent)
        XCTAssertEqual(StatusGlyph.failed.color, Palette.label2, "the octagon neutral: red only for an error")
        for g in [StatusGlyph.waiting, .finished, .noRounds] { XCTAssertEqual(g.color, Palette.secondary, "\(g)") }
    }

    /// The mockup's RING_AT: a sign's side beside text of each size of the v4 scale.
    func testTheSignsSizes() {
        let at: [CGFloat: CGFloat] = [11: 10, 12: 10, 13: 11, 15: 13, 17: 14, 22: 17, 26: 21]
        for (text, px) in at { XCTAssertEqual(StatusGlyph.size(text: text), px, "beside \(text) pt") }
        XCTAssertEqual(StatusGlyphView(.ready, text: 22).size, 17)
        XCTAssertEqual(StatusGlyphView(.ready, size: 8).size, 8)
    }

    /// Every sign draws in its box without failing, in either mode.
    @MainActor
    func testTheSignsDraw() throws {
        let all: [StatusGlyph] = [.ring(0), .ring(0.3), .ring(1), .ready, .waiting, .finished, .failed, .noRounds, .wellDone, .nothingWaits]
        for dark in [false, true] {
            let r = ImageRenderer(content: HStack { ForEach(Array(all.enumerated()), id: \.offset) { StatusGlyphView($0.element, size: 14) } }
                .environment(\.colorScheme, dark ? .dark : .light))
            let image = try XCTUnwrap(r.nsImage)
            XCTAssertGreaterThanOrEqual(image.size.width, 14 * CGFloat(all.count))
            XCTAssertEqual(image.size.height, 14)
        }
    }
}
