import CoreGraphics
import XCTest
@testable import Paperole

final class GeometryTests: XCTestCase {
    let letter = CGRect(x: 0, y: 0, width: 612, height: 792)

    func testContractToPDFKitOnLaTeXPage() {
        // CONTRACT §3: CGRect(x: cb.minX + x0, y: cb.maxY - y1, width: x1 - x0, height: y1 - y0)
        let r = Geometry.pdfKitRect([72.0, 336.1, 223.2, 346.1], cropBox: letter)!
        XCTAssertEqual(r.minX, 72.0, accuracy: 1e-9)
        XCTAssertEqual(r.minY, 792 - 346.1, accuracy: 1e-9)
        XCTAssertEqual(r.width, 151.2, accuracy: 1e-9)
        XCTAssertEqual(r.height, 10.0, accuracy: 1e-9)
        XCTAssertEqual(r.maxY, 792 - 336.1, accuracy: 1e-9)  // the top edge
    }

    func testCropBoxOffset() {
        let cb = CGRect(x: 10, y: 20, width: 600, height: 780)  // maxY = 800
        let r = Geometry.pdfKitRect([5, 100, 55, 110], cropBox: cb)!
        XCTAssertEqual(r, CGRect(x: 15, y: 690, width: 50, height: 10))
        XCTAssertEqual(Geometry.contractRect(r, cropBox: cb), [5, 100, 55, 110])
    }

    func testRoundTripRoundsToHundredths() {
        let pk = CGRect(x: 181.704, y: 390.996, width: 101.567, height: 9.9649)
        let c = Geometry.contractRect(pk, cropBox: letter)
        XCTAssertEqual(c, [181.7, 391.04, 283.27, 401.0])
        let back = Geometry.pdfKitRect(c, cropBox: letter)!
        XCTAssertEqual(back.minX, pk.minX, accuracy: 0.01)
        XCTAssertEqual(back.minY, pk.minY, accuracy: 0.01)
        XCTAssertEqual(back.maxX, pk.maxX, accuracy: 0.01)
        XCTAssertEqual(back.maxY, pk.maxY, accuracy: 0.01)
    }

    func testTopOfPageIsSmallContractY() {
        // A line near the top of a PDFKit page (large y) has a small top-left y.
        let c = Geometry.contractRect(CGRect(x: 72, y: 700, width: 100, height: 10), cropBox: letter)
        XCTAssertEqual(c, [72, 82, 172, 92])
        XCTAssertLessThan(c[1], c[3])
    }

    func testMalformedRect() {
        XCTAssertNil(Geometry.pdfKitRect([1, 2, 3], cropBox: letter))
    }
}

/// Drag points left or right of a page's text are moved onto its edge (round.build.text_x).
final class ClampTests: XCTestCase {
    let letter = CGRect(x: 0, y: 0, width: 612, height: 792)
    let text: [Double] = [107.25, 505.75]  // a review paper's page: ruler at 73-86, text from 107

    func testGapAndRulerMoveToTheLeftEdge() {
        for x: CGFloat in [0, 73, 86, 90, 95, 100, 104, 106.2] {
            XCTAssertEqual(Geometry.clampedX(x, textX: text, cropBox: letter), 107.25, "x = \(x)")
        }
    }

    func testFarRightMovesToTheRightEdge() {
        for x: CGFloat in [506.8, 530, 560, 611] {
            XCTAssertEqual(Geometry.clampedX(x, textX: text, cropBox: letter), 505.75, "x = \(x)")
        }
    }

    func testInsideOrWithinTolerance() {
        for x: CGFloat in [106.3, 107.25, 108, 300, 505.75, 506.7] {
            XCTAssertNil(Geometry.clampedX(x, textX: text, cropBox: letter), "x = \(x)")
        }
    }

    func testTwoColumnsKeepTheGutter() {
        // the union of both columns: a point between them stays, so a drag may start in either column
        let both: [Double] = [54, 558]
        XCTAssertNil(Geometry.clampedX(306, textX: both, cropBox: letter))
        XCTAssertEqual(Geometry.clampedX(30, textX: both, cropBox: letter), 54)
        XCTAssertEqual(Geometry.clampedX(590, textX: both, cropBox: letter), 558)
    }

    func testCropBoxOffset() {
        let cb = CGRect(x: 10, y: 20, width: 600, height: 780)
        XCTAssertEqual(Geometry.clampedX(100, textX: text, cropBox: cb), 117.25)
        XCTAssertNil(Geometry.clampedX(117.25, textX: text, cropBox: cb))
        XCTAssertEqual(Geometry.clampedX(600, textX: text, cropBox: cb), 515.75)
    }

    func testNoExtentChangesNothing() {
        XCTAssertNil(Geometry.clampedX(20, textX: nil, cropBox: letter))  // a page without text
        XCTAssertNil(Geometry.clampedX(20, textX: [], cropBox: letter))
        XCTAssertNil(Geometry.clampedX(20, textX: [300, 200], cropBox: letter))
    }
}

/// Drag points are kept on the text of their row (PDFKit page space, y up; lines 12 pt apart).
final class LineClampTests: XCTestCase {
    let letter = CGRect(x: 0, y: 0, width: 612, height: 792)
    let text: [Double] = [107.25, 505.75]
    // Page 1 of a review paper: abstract lines, narrower than text_x. Below: a paragraph's last two lines.
    let abstract = [CGRect(x: 143.9, y: 572, width: 361.8, height: 10), CGRect(x: 143.9, y: 560, width: 361.8, height: 10)]
    let full = CGRect(x: 108, y: 352, width: 397.7, height: 10), short = CGRect(x: 108, y: 340, width: 112.3, height: 10)

    private func clamp(_ x: CGFloat, _ y: CGFloat, _ lines: [CGRect], textX: [Double]? = nil) -> CGPoint {
        Geometry.clampedPoint(CGPoint(x: x, y: y), lines: lines, textX: textX ?? text, cropBox: letter)
    }

    func testLeftOfTheRowMovesJustInsideItsFirstGlyph() {
        for x: CGFloat in [40, 80, 95, 107.67, 143.8] {
            let p = clamp(x, 561, abstract)
            XCTAssertEqual(p.x, 144.4, accuracy: 1e-9, "x = \(x)")
            XCTAssertEqual(p.y, 565, "x = \(x)")
        }
    }

    func testRightOfAShortLineMovesJustInsideItsLastGlyph() {
        for x: CGFloat in [220.4, 225, 400, 505.75, 560, 640] {
            let p = clamp(x, 348, [full, short])
            XCTAssertEqual(p.x, 219.8, accuracy: 1e-9, "x = \(x)")
            XCTAssertEqual(p.y, 345, "x = \(x)")
        }
    }

    func testOverTheRowStays() {
        for x: CGFloat in [108, 150, 220.2] {
            XCTAssertEqual(clamp(x, 341, [full, short]), CGPoint(x: x, y: 341))
        }
    }

    func testBetweenTwoLinesTheNearerOne() {
        XCTAssertEqual(clamp(95, 351.5, [full, short]).y, 357)  // 0.5 below the full line
        XCTAssertEqual(clamp(95, 350.5, [full, short]).y, 345)  // 0.5 above the short one
        XCTAssertEqual(clamp(560, 350.5, [full, short]).x, 219.8, accuracy: 1e-9)
    }

    func testTwoColumns() {
        // Two columns whose lines are not level. Each margin goes to its own column; the gutter stays by the text.
        let left = (0..<40).map { CGRect(x: 54, y: 100 + 12 * CGFloat($0), width: 247, height: 9) }
        let right = (0..<40).map { CGRect(x: 311, y: 104 + 12 * CGFloat($0), width: 247, height: 9) }
        let t: [Double] = [54, 558]
        XCTAssertEqual(clamp(30, 113, left + right, textX: t), CGPoint(x: 54.5, y: 116.5))
        XCTAssertEqual(clamp(590, 113, left + right, textX: t), CGPoint(x: 557.5, y: 108.5))
        XCTAssertTrue((300.5...311.5).contains(clamp(306, 113, left + right, textX: t).x))
        // Over a column with no text at that height (its end, a float, a gap): the point stays, and is not moved onto
        // the other column's line.
        let rightTop = right.filter { $0.minY > 300 }, leftTop = left.filter { $0.minY > 300 }
        XCTAssertEqual(clamp(400, 113, left + rightTop, textX: t), CGPoint(x: 400, y: 113))
        XCTAssertEqual(clamp(150, 113, leftTop + right, textX: t), CGPoint(x: 150, y: 113))
        XCTAssertEqual(clamp(590, 113, left + rightTop, textX: t).x, 300.5)  // the margin still goes to the text
    }

    func testIndentedLinesAboveFullOnes() {
        // The abstract is narrower than the text below it: a point in the indent goes to the abstract line.
        let body = (0..<10).map { CGRect(x: 108, y: 300 + 12 * CGFloat($0), width: 397.7, height: 10) }
        let p = clamp(112, 561, abstract + body)
        XCTAssertEqual(p.x, 144.4, accuracy: 1e-9)
        XCTAssertEqual(p.y, 565)
    }

    func testAPointOverTextStaysOnItsLine() {
        // Text beside a figure: a small label at the point's height, the body line just below it.
        let body = CGRect(x: 108, y: 230, width: 249, height: 9), label = CGRect(x: 370, y: 237, width: 20, height: 6)
        XCTAssertEqual(clamp(200, 239.5, [label, body]), CGPoint(x: 200, y: 239.5))
        XCTAssertEqual(clamp(95, 239.5, [label, body]), CGPoint(x: 108.5, y: 234.5))  // the margin: the body's column
    }

    func testAnEquationNumberEndsTheRow() {
        let display = CGRect(x: 200, y: 100, width: 150, height: 10), number = CGRect(x: 490, y: 101, width: 15, height: 8)
        let below = CGRect(x: 108, y: 88, width: 390, height: 10)
        XCTAssertEqual(clamp(560, 104, [below, number, display]).x, 504.5, accuracy: 1e-9)
        XCTAssertEqual(clamp(95, 104, [below, number, display]).x, 200.5, accuracy: 1e-9)
    }

    func testANarrowLineKeepsThePointOnIt() {
        XCTAssertEqual(clamp(200, 101, [CGRect(x: 300, y: 100, width: 0.6, height: 10)]).x, 300.3, accuracy: 1e-9)
    }

    func testWithoutALineTextXDecides() {
        let far = [CGRect(x: 108, y: 300, width: 397, height: 10)]  // more than 6 pt away
        XCTAssertEqual(clamp(95, 400, far), CGPoint(x: 107.25, y: 400))
        XCTAssertEqual(clamp(560, 400, []), CGPoint(x: 505.75, y: 400))
        XCTAssertEqual(clamp(300, 400, []), CGPoint(x: 300, y: 400))
        XCTAssertEqual(Geometry.clampedPoint(CGPoint(x: 20, y: 400), lines: [], textX: nil, cropBox: letter),
                       CGPoint(x: 20, y: 400))
    }

    /// A sentence from the bottom of the left column to the top of the right column, under a figure there: two
    /// runs, the second starting at the first text line below the figure (found in a review: PDFKit took the figure's
    /// words in between).
    func testColumnRunsSkipAFloatAtTheTopOfTheNextColumn() {
        // PDFKit page space, y up. Left column lines from y 700 down to 100, 12 pt apart.
        let left = (0..<51).map { CGRect(x: 70, y: 700 - 12 * CGFloat($0), width: 220, height: 9) }
        let figure = [CGRect(x: 320, y: 720, width: 80, height: 7), CGRect(x: 330, y: 610, width: 160, height: 9)]
        let right = (0..<40).map { CGRect(x: 306, y: 560 - 12 * CGFloat($0), width: 220, height: 9) }
        let a = CGPoint(x: 150, y: left[48].midY), b = CGPoint(x: 400, y: right[1].midY)
        let runs = Geometry.columnRuns(a, b, lines: left + figure + right, gap: 298)!
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].0, a)
        XCTAssertEqual(runs[0].1.y, left[50].midY)  // down to the left column's last line
        XCTAssertEqual(runs[0].1.x, left[50].maxX - 0.5)
        XCTAssertEqual(runs[1].0.y, right[0].midY)  // the right column's text starts below the figure
        XCTAssertEqual(runs[1].1, b)
        // dragged backwards (from the right column to the left one): the same runs
        let back = Geometry.columnRuns(b, a, lines: left + figure + right, gap: 298)!
        XCTAssertEqual(back[0].0, a)
        XCTAssertEqual(back[1].1, b)
        // a gap of more than a line in the left column (a float at its bottom) ends its run
        let shortLeft = Array(left[0..<45]) + [CGRect(x: 80, y: 120, width: 150, height: 9)]
        let r2 = Geometry.columnRuns(CGPoint(x: 150, y: left[40].midY), b, lines: shortLeft + right, gap: 298)!
        XCTAssertEqual(r2[0].1.y, left[44].midY)
        // both points in one column, or one beside no line: PDFKit's own selection
        XCTAssertNil(Geometry.columnRuns(a, CGPoint(x: 100, y: left[2].midY), lines: left + right, gap: 298))
        XCTAssertNil(Geometry.columnRuns(CGPoint(x: 150, y: 50), b, lines: left + right, gap: 298))
    }
}

final class WordDiffTests: XCTestCase {
    /// The words both sides share are in no hunk: "Both approaches" before the first, "instance" between the two.
    func testReplaceKeepsSharedWords() {
        let old = "Both approaches decide when to keep a\nsingle instance alive."
        let new = "Both approaches reason about the lifetime of one instance and leave"
        let d = WordDiff.hunks(old, new)
        XCTAssertEqual(d.hunks.map { substring(old, $0.old) }, ["decide when to keep a\nsingle", "alive."])
        XCTAssertEqual(d.hunks.map { substring(new, $0.new) }, ["reason about the lifetime of one", "and leave"])
    }

    func testGoneDeletesEverything() {
        XCTAssertEqual(WordDiff.hunks("two words", "").hunks, [WordDiff.Hunk(steps: 0..<2, old: 0..<9, new: 0..<0)])
        let gone = WordDiff.changes(from: "two words", to: "")
        XCTAssertEqual(gone.changed, [])
        XCTAssertEqual(gone.carets, [0])
    }
}

/// Id labels beside a margin ruler (Geometry.labelPlace): never over a line number, inside the crop box.
final class LabelPlaceTests: XCTestCase {
    let letter = CGRect(x: 0, y: 0, width: 612, height: 792)
    private let normal = CGSize(width: 33, height: 9), compact = CGSize(width: 21, height: 8)

    private func place(ruler: CGRect, textX: [Double], first: CGRect, placed: [CGRect] = []) -> (rect: CGRect, compact: Bool) {
        let text = CGRect(x: ruler.minX, y: 60, width: CGFloat(textX[1]) - ruler.minX, height: 670)
        let r = Geometry.labelPlace(sizes: [normal, compact], first: first, text: text, textX: textX, ruler: ruler,
                                    cropBox: letter, placed: placed)
        return (r.rect, r.size == 1)
    }

    /// design/ui-v2's 8.5 pt label does not fit between ACL's ruler and its text: M1's 7 pt label with the status sign
    /// goes there, not the 6 pt one without it.
    func testTheLargestLabelThatFits() {
        let ruler = CGRect(x: 12.2, y: 60, width: 13.3, height: 670), first = CGRect(x: 75, y: 400, width: 200, height: 10)
        let text = CGRect(x: ruler.minX, y: 60, width: 526.23 - ruler.minX, height: 670)
        let sizes = [CGSize(width: 45, height: 10), CGSize(width: 35, height: 9), CGSize(width: 22, height: 8)]
        let r = Geometry.labelPlace(sizes: sizes, first: first, text: text, textX: [70.47, 526.23], ruler: ruler,
                                    cropBox: letter, placed: [])
        XCTAssertEqual(r.size, 1)
        XCTAssertEqual(r.rect.minX, 70.47 - 7 - 35, accuracy: 0.01)
        // a thin space after the sign at 7 pt and 6 pt ("○R1-03" read as "OR1-03"); without it only where nothing fits
        XCTAssertEqual(MarkAnnotation.labels("R1-02", glyph: "○"), ["○ R1-02", "○\u{2009}R1-02", "○\u{2009}R1-02", "R1-02"])
        XCTAssertEqual(MarkAnnotation.labelFonts.map(\.pointSize), [8.5, 7, 6, 6])
    }

    func testLabelPastARulerCloseToTheText() {
        // ICML submission: the ruler 15 pt from the text and 26 pt from the page's edge; the normal label fits nowhere
        let ruler = CGRect(x: 25.6, y: 60, width: 14.9, height: 670)
        let (r, small) = place(ruler: ruler, textX: [55.08, 543.09], first: CGRect(x: 60, y: 400, width: 240, height: 10))
        XCTAssertTrue(small)
        XCTAssertFalse(r.intersects(ruler.insetBy(dx: -1, dy: -1)))
        XCTAssertGreaterThanOrEqual(r.minX, letter.minX + 1)
        XCTAssertEqual(r.midY, 405, accuracy: 0.01)
    }

    func testLabelBetweenTextAndAnEdgeRuler() {
        // ACL: the ruler at the page's edge, 45 pt from the text: between them, normal size
        let ruler = CGRect(x: 12.2, y: 60, width: 13.3, height: 670)
        let first = CGRect(x: 75, y: 400, width: 200, height: 10)
        let (r, small) = place(ruler: ruler, textX: [70.47, 526.23], first: first)
        XCTAssertFalse(small)
        XCTAssertEqual(r.minX, 70.47 - 7 - 33, accuracy: 0.01)
        // a second label on the same line is not pushed over the ruler or out of the page: a line below or above
        let (r2, _) = place(ruler: ruler, textX: [70.47, 526.23], first: first, placed: [r])
        XCTAssertFalse(r2.intersects(ruler.insetBy(dx: -1, dy: -1)))
        XCTAssertFalse(r2.insetBy(dx: -1, dy: 0).intersects(r))
        XCTAssertGreaterThanOrEqual(r2.minX, letter.minX + 1)
    }

    func testLabelOutsideAllTextWhenThereIsRoom() {
        // NeurIPS: the ruler 9 pt from the text, 91 pt from the edge: left of everything, normal size
        let ruler = CGRect(x: 91.4, y: 60, width: 6.6, height: 670)
        let (r, small) = place(ruler: ruler, textX: [107.64, 505.25], first: CGRect(x: 110, y: 300, width: 200, height: 10))
        XCTAssertFalse(small)
        XCTAssertEqual(r.maxX, 91.4 - 5, accuracy: 0.01)
    }
}
