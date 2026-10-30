import AppKit
import PDFKit
import XCTest
@testable import Paperole

/// Crops of formulas and tables in the panel's ink, figures as printed (UX.md §4; the advisor's feedback of 2026-10-20).
final class CropLookTests: XCTestCase {
    // MARK: which look

    func testCommentLookByEnvironment() {
        for env in ["equation", "equation*", "align", "align*", "gather", "multline", "eqnarray", "displaymath",
                    "tabular", "tabular*", "tabularx", "longtable", "table", "table*", "wraptable", "subtable", "array",
                    "algorithm", "algorithmic", "theorem"] {
            XCTAssertEqual(CropLook.comment(env: env, kind: .highlight, words: "x"), .ink, env)
            XCTAssertEqual(CropLook.comment(env: env, kind: .box, words: ""), .ink, env)  // the environment wins
        }
        for env in ["figure", "figure*", "Figure", "subfigure", "wrapfigure", "tikzpicture", "picture", "center", "minipage"] {
            XCTAssertEqual(CropLook.comment(env: env, kind: .highlight, words: "x"), .paper, env)
            XCTAssertEqual(CropLook.comment(env: env, kind: .box, words: "Figure 3: caption"), .paper, env)
        }
    }

    func testCommentLookWithoutEnvironment() {
        XCTAssertEqual(CropLook.comment(env: nil, kind: .box, words: nil), .paper)  // a box on no words: a picture
        XCTAssertEqual(CropLook.comment(env: nil, kind: .box, words: "  "), .paper)
        XCTAssertEqual(CropLook.comment(env: "", kind: .box, words: ""), .paper)
        XCTAssertEqual(CropLook.comment(env: nil, kind: .box, words: "We set k = 5."), .ink)  // a box on words
        XCTAssertEqual(CropLook.comment(env: nil, kind: .highlight, words: nil), .ink)  // a display \[ … \]
    }

    func testChangeLook() throws {
        XCTAssertEqual(CropLook.change(try makeChange(["figure": "figs/plot.pdf"])), .paper)
        XCTAssertEqual(CropLook.change(try makeChange(["float": "Figure 4"])), .paper)
        XCTAssertEqual(CropLook.change(try makeChange(["float": "Fig. 2"])), .paper)
        XCTAssertEqual(CropLook.change(try makeChange(["float": "Table 2"])), .ink)
        XCTAssertEqual(CropLook.change(try makeChange(["about": ["kind": "file", "text": "Figure 'drop_two_panel' removed"],
                                                       "old_text": "\\input{figs/drop}", "new_text": ""])), .paper)
        XCTAssertEqual(CropLook.change(try makeChange(["about": ["kind": "file", "text": "Table 'results' added"]])), .ink)
        XCTAssertEqual(CropLook.change(try makeChange(["old_text": "\\includegraphics[width=3cm]{a}", "new_text": ""])), .paper)
        XCTAssertEqual(CropLook.change(try makeChange(["old_text": "x = 1", "new_text": "x = 2"])), .ink)  // display math
    }

    func testThreadAndChangeCropsCarryTheLook() throws {
        let img: [String: Any] = ["text": "H := − M X j=1 pj log2 pj. (5)", "sel": [], "display": "image", "page": 1,
                                  "rects": [[72, 100, 200, 140]], "clip": [64, 94, 298, 150], "cut": NSNull()]
        let eq = try makeComment(["kind": "box", "env": "equation", "context": img, "anchor_state": "unchanged",
                                  "history": [["round": 1, "anchor_state": "new", "verdict": NSNull(), "verdict_note": "",
                                               "page": 1, "context": img]]])
        let t = CardContent.thread(eq, round: 2, pdfs: [1: "/r1.pdf", 2: "/r2.pdf"])
        XCTAssertEqual(t.compactMap(\.crop?.look), [.ink])
        var fig = eq
        fig.env = "figure"
        XCTAssertEqual(CardContent.thread(fig, round: 2, pdfs: [1: "/r1.pdf"]).compactMap(\.crop?.look), [.paper])

        // a note on an empty area of the page is that area as printed, whatever the comment is in
        let point: [String: Any] = ["text": "", "sel": [], "display": "text", "page": 1, "rects": [[300, 400, 300, 400]],
                                    "cut": NSNull()]
        let note = try makeComment(["kind": "note", "env": "equation", "carried": false, "anchor_state": "new",
                                    "context": point, "history": []])
        XCTAssertEqual(CardContent.thread(note, round: 1, pdfs: [1: "/r1.pdf"]).compactMap(\.crop?.look), [.paper])

        var side = img
        side["page"] = 0
        let table = try makeChange(["float": "Table 2", "context": ["before": side, "now": side]])
        XCTAssertEqual(model(table).blocks.compactMap(\.crop?.look), [.ink, .ink])
        let figure = try makeChange(["float": "Figure 1", "figure": "figs/a.pdf", "context": ["before": side, "now": side]])
        XCTAssertEqual(model(figure).blocks.compactMap(\.crop?.look), [.paper, .paper])
    }

    // MARK: the ink in Dark Mode

    func hue(_ c: (Float, Float, Float)) -> CGFloat {
        NSColor(srgbRed: CGFloat(c.0), green: CGFloat(c.1), blue: CGFloat(c.2), alpha: 1).hueComponent
    }

    func testDarkInkTurnsLightnessRoundKeepingHue() {
        let black = InkMap.dark(0, 0, 0)
        XCTAssertEqual(black.0, 230 / 255, accuracy: 1e-6)  // the panel's label colour in Dark Mode
        XCTAssertEqual(black.1, 235 / 255, accuracy: 1e-6)
        let white = InkMap.dark(1, 1, 1)
        XCTAssertEqual(white.0 + white.1 + white.2, 0, accuracy: 1e-6)  // paper is the dark ground
        let grey = InkMap.dark(0.9, 0.9, 0.9)  // a shaded table row: a dark one
        XCTAssertEqual(grey.0, 0.1 * 230 / 255, accuracy: 1e-5)
        for c: (Float, Float, Float) in [(1, 0, 0), (0, 0, 0.5), (0.1, 0.4, 0.2), (0.63, 0.38, 0.03), (0.8, 0.2, 0.6)] {
            let d = InkMap.dark(c.0, c.1, c.2)
            XCTAssertEqual(hue(d), hue(c), accuracy: 0.01, "\(c)")  // the hue kept
            let l0 = (max(c.0, c.1, c.2) + min(c.0, c.1, c.2)) / 2
            let l1 = (max(d.0, d.1, d.2) + min(d.0, d.1, d.2)) / 2
            XCTAssertEqual(l1, (1 - l0) * 0.91, accuracy: 0.03, "\(c)")  // the lightness turned round
        }
        let navy = InkMap.dark(0, 0, 0.5)
        XCTAssertGreaterThan(navy.2, 0.85)  // a dark blue becomes a light one
        XCTAssertGreaterThan(navy.0, 0.4)
    }

    func testPaperIsTakenOut() {
        let white = InkMap.ink(1, 1, 1)
        XCTAssertEqual(white.a, 0)  // no ink: a table's white cells vanish
        let black = InkMap.ink(0, 0, 0)
        XCTAssertEqual([black.r, black.g, black.b, black.a], [0, 0, 0, 1])
        let grey = InkMap.ink(0.9, 0.9, 0.9)  // a shaded row: a faint black
        XCTAssertEqual(grey.a, 0.1, accuracy: 1e-6)
        XCTAssertEqual(grey.r, 0, accuracy: 1e-5)
        let pink = InkMap.ink(1, 0.8, 0.8)  // a fifth of red
        XCTAssertEqual(pink.a, 0.2, accuracy: 1e-6)
        XCTAssertEqual([pink.r, pink.g, pink.b].map { ($0 * 1000).rounded() / 1000 }, [1, 0, 0])
        for c: (Float, Float, Float) in [(0.2, 0.5, 0.9), (1, 0.6, 0), (0.95, 0.9, 0.85)] {  // laid on white, the same
            let i = InkMap.ink(c.0, c.1, c.2)
            XCTAssertEqual(i.r * i.a + 1 - i.a, c.0, accuracy: 1e-5)
            XCTAssertEqual(i.g * i.a + 1 - i.a, c.1, accuracy: 1e-5)
            XCTAssertEqual(i.b * i.a + 1 - i.a, c.2, accuracy: 1e-5)
        }
    }

    func testLiftKeepsInkAndRowPadding() {
        // 3 × 2 pixels on white, 16 bytes a row (4 of them padding): white, black, grey 90%; red, pink, a glyph's grey edge
        let page: [UInt8] = [255, 255, 255, 255, 0, 0, 0, 255, 230, 230, 230, 255, 7, 7, 7, 7,
                             255, 0, 0, 255, 255, 204, 204, 255, 128, 128, 128, 255, 7, 7, 7, 7]
        var light = page
        light.withUnsafeMutableBufferPointer { InkMap.lift($0.baseAddress!, width: 3, height: 2, bytesPerRow: 16, dark: false) }
        XCTAssertEqual(Array(light[0..<4]), [0, 0, 0, 0])  // paper: transparent
        XCTAssertEqual(Array(light[4..<8]), [0, 0, 0, 255])
        XCTAssertEqual(Array(light[8..<11]), [0, 0, 0])
        XCTAssertEqual(Int(light[11]), 25, accuracy: 1)  // the grey row: a tenth of black
        XCTAssertEqual(Array(light[12..<16]), [7, 7, 7, 7])  // padding untouched
        XCTAssertEqual(Array(light[16..<20]), [255, 0, 0, 255])
        XCTAssertEqual(Int(light[20]), 51, accuracy: 1)  // pink: red at a fifth, premultiplied
        XCTAssertEqual(Int(light[23]), 51, accuracy: 1)
        XCTAssertEqual(Int(light[27]), 127, accuracy: 1)  // a grey edge: half-covered black
        XCTAssertEqual(light[24], 0)

        var dark = page
        dark.withUnsafeMutableBufferPointer { InkMap.lift($0.baseAddress!, width: 3, height: 2, bytesPerRow: 16, dark: true) }
        XCTAssertEqual(Array(dark[0..<4]), [0, 0, 0, 0])
        XCTAssertEqual(Array(dark[4..<8]), [230, 235, 230, 255])  // black text: the panel's label colour
        XCTAssertEqual(Int(dark[8]), 23, accuracy: 1)  // the grey row: a faint light band, not a black one
        XCTAssertEqual(Int(dark[11]), 25, accuracy: 1)
        XCTAssertEqual(Array(dark[12..<16]), [7, 7, 7, 7])
        XCTAssertEqual(Array(dark[16..<20]), [230, 0, 0, 255])  // red stays red
        XCTAssertEqual(Int(dark[20]), 46, accuracy: 1)
        XCTAssertEqual(dark[21], 0)
        XCTAssertEqual(Int(dark[24]), 115, accuracy: 1)  // a glyph's edge: light, half covered
        XCTAssertEqual(Int(dark[27]), 127, accuracy: 1)
    }

    // MARK: density

    func testDensityFollowsTheShownWidth() {
        let eq = CGSize(width: 200, height: 48)
        XCTAssertEqual(CropStyle.density(width: 0, area: eq, screen: 2), 0)  // not laid out yet: nothing drawn
        XCTAssertEqual(CropStyle.density(width: 400, area: eq, screen: 2), 4)  // a wide card on a Retina screen
        XCTAssertEqual(CropStyle.density(width: 380, area: eq, screen: 2), 4)  // rounded up to half a pixel a point
        XCTAssertEqual(CropStyle.density(width: 340, area: eq, screen: 2), 3.5)
        XCTAssertEqual(CropStyle.density(width: 400, area: eq, screen: 1), 2)
        XCTAssertEqual(CropStyle.density(width: 50, area: eq, screen: 1), 1)  // at least one pixel a point
        XCTAssertEqual(CropStyle.density(width: 4000, area: eq, screen: 2), 8)  // at most 8
        XCTAssertEqual(CropStyle.density(width: 2400, area: CGSize(width: 3000, height: 200), screen: 2), 4096 / 3000)  // 4096 px
        // a few points of width draw nothing again
        XCTAssertEqual(CropStyle.density(width: 381, area: eq, screen: 2), CropStyle.density(width: 399, area: eq, screen: 2))
    }

    func testStyleColoursAndSharing() {
        let pair = Palette.pair(NSColor(hex: 0x1D4ED8), NSColor(hex: 0x60A5FA))
        let paperDark = CropStyle(look: .paper, dark: true, density: 2, ink: pair)
        let paperLight = CropStyle(look: .paper, dark: false, density: 2, ink: pair)
        XCTAssertEqual(paperDark, paperLight)  // a figure on its paper is the same in either mode
        XCTAssertEqual(paperDark.mark, CropStyle.RGBA(NSColor(hex: 0x1D4ED8), dark: false))
        let inkDark = CropStyle(look: .ink, dark: true, density: 2, ink: pair)
        XCTAssertEqual(inkDark.mark, CropStyle.RGBA(NSColor(hex: 0x60A5FA), dark: false))  // the lighter fill on dark
        XCTAssertNotEqual(inkDark, CropStyle(look: .ink, dark: false, density: 2, ink: pair))
        XCTAssertEqual(CropStyle(look: .ink, dark: false, density: 2, ink: pair).mark.b, paperLight.mark.b)
        XCTAssertEqual(inkDark.deletion, CropStyle.RGBA(NSColor(hex: 0x4ADE80), dark: false))
        XCTAssertEqual(paperDark.deletion, CropStyle.RGBA(NSColor(hex: 0x15803D), dark: false))
    }

    // MARK: drawing

    /// A 200 × 100 pt page: a black bar at contract (20, 20)–(80, 30), a red one at (120, 20)–(180, 30), a 90% grey one at
    /// (20, 40)–(80, 50) and a white one under it, at (20, 50)–(80, 60); nothing else.
    func page() throws -> PDFPage {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 200, height: 100)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let ctx = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 20, y: 70, width: 60, height: 10))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 120, y: 70, width: 60, height: 10))
        ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.9, blue: 0.9, alpha: 1))  // a shaded table row
        ctx.fill(CGRect(x: 20, y: 50, width: 60, height: 10))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))  // a white cell
        ctx.fill(CGRect(x: 20, y: 40, width: 60, height: 10))
        ctx.endPDFPage()
        ctx.closePDF()
        return try XCTUnwrap(PDFDocument(data: data as Data)?.page(at: 0))
    }

    /// The pixel at contract point (x, y) of a crop of the area (0, 0)–(200, 60) drawn at `density`.
    func pixel(_ img: CGImage, _ x: CGFloat, _ y: CGFloat, density: CGFloat) -> [Int] {
        let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let o = Int(y * density) * img.width * 4 + Int(x * density) * 4  // row 0 is the top in memory
        return (0..<4).map { Int(p[o + $0]) }
    }

    func testDrawingPipeline() throws {
        let pg = try page()
        // the mark: a box round (130, 40)–(170, 50), where the page prints nothing
        let req = CropRequest(round: 1, pdf: nil, page: 0, rects: [[130, 40, 170, 50]], textX: nil, clip: [0, 0, 200, 60])
        let ink = Palette.pair(NSColor(hex: 0x1D4ED8), NSColor(hex: 0x60A5FA))

        let paper = try XCTUnwrap(CropCache.draw(pg, req, CropStyle(look: .paper, dark: true, density: 2, ink: ink)))
        XCTAssertEqual([paper.width, paper.height], [400, 120])
        XCTAssertEqual(pixel(paper, 5, 5, density: 2), [255, 255, 255, 255])  // the white paper
        XCTAssertEqual(pixel(paper, 50, 25, density: 2), [0, 0, 0, 255])
        XCTAssertEqual(pixel(paper, 150, 51.4, density: 2)[2], 0xD8, "the mark in its ink on paper")

        let light = try XCTUnwrap(CropCache.draw(pg, req, CropStyle(look: .ink, dark: false, density: 3, ink: ink)))
        XCTAssertEqual([light.width, light.height], [600, 180])  // the density asked for
        XCTAssertEqual(pixel(light, 5, 5, density: 3)[3], 0)  // no paper: the card shows through
        XCTAssertEqual(pixel(light, 50, 25, density: 3), [0, 0, 0, 255])  // the page's black
        XCTAssertEqual(pixel(light, 150, 25, density: 3), [255, 0, 0, 255])  // its red
        XCTAssertEqual(pixel(light, 50, 45, density: 3)[3], 25, accuracy: 1)  // a grey row: a tenth of black
        XCTAssertEqual(pixel(light, 50, 55, density: 3), [0, 0, 0, 0])  // a white cell: no box

        let dark = try XCTUnwrap(CropCache.draw(pg, req, CropStyle(look: .ink, dark: true, density: 2, ink: ink)))
        XCTAssertEqual(pixel(dark, 5, 5, density: 2)[3], 0)
        let k = pixel(dark, 50, 25, density: 2)
        XCTAssertEqual(k[0], 230, accuracy: 1)  // black ink: the panel's label colour
        XCTAssertEqual(k[1], 235, accuracy: 1)
        XCTAssertEqual(k[3], 255)
        let r = pixel(dark, 150, 25, density: 2)
        XCTAssertEqual(r[0], 230, accuracy: 1)  // red stays red
        XCTAssertEqual(r[1] + r[2], 0)
        XCTAssertEqual(pixel(dark, 50, 45, density: 2)[0], 23, accuracy: 1)  // a faint light band
        XCTAssertEqual(pixel(dark, 50, 55, density: 2), [0, 0, 0, 0])  // the white cell is not a black box
        XCTAssertEqual(pixel(paper, 50, 55, density: 2), [255, 255, 255, 255])
        // an ink crop's mark is a tint under the ink, never an outline across the next line's words (UI audit 2026-10-21)
        XCTAssertEqual(pixel(dark, 150, 51.4, density: 2), [0, 0, 0, 0], "no outline round it")
        let m = pixel(dark, 150, 45, density: 2)
        XCTAssertEqual(m[3], 51, accuracy: 2, "the mark's lighter fill at a fifth, by default")
        XCTAssertEqual(m[2], 0xFA * 51 / 255, accuracy: 2, "not turned round")
        let tint = NSColor(hex: 0xEAB308).withAlphaComponent(0.36)
        let over = CropRequest(round: 1, pdf: nil, page: 0, rects: [[20, 20, 80, 30]], textX: nil, clip: [0, 0, 200, 60])
        let marked = try XCTUnwrap(CropCache.draw(pg, over, CropStyle(look: .ink, dark: false, density: 2, ink: ink, tint: tint)))
        XCTAssertEqual(pixel(marked, 50, 25, density: 2), [0, 0, 0, 255], "the ink over its tint, as printed")
        XCTAssertEqual(pixel(marked, 50, 19.7, density: 2)[3], 92, accuracy: 2, "the tint round it")
        XCTAssertEqual(pixel(marked, 50, 35, density: 2)[3], 0)

        var faint = req
        faint.faint = true
        let f = try XCTUnwrap(CropCache.draw(pg, faint, CropStyle(look: .ink, dark: false, density: 2, ink: ink)))
        XCTAssertEqual(pixel(f, 150, 45, density: 2)[3], 23, accuracy: 2)  // fainter on a later round's crop
        var faintPaper = req
        faintPaper.faint = true
        let fp = try XCTUnwrap(CropCache.draw(pg, faintPaper, CropStyle(look: .paper, dark: false, density: 2, ink: ink)))
        XCTAssertLessThan(pixel(fp, 150, 51.4, density: 2)[0], 255, "a figure's later outline at 40%")
    }

    /// An ink crop has no backing of its own (the advisor's feedback of 2026-10-21: a box round formula (6) or Table 1
    /// put a tinted plate behind it): a box that is most of its crop draws no tint, so the ink sits on the card; a box
    /// on a symbol or a few words of a wider crop keeps its tint, as words marked do.
    func testABoxOnTheWholeAreaHasNoPlate() throws {
        // the advisor's: formula (6) (86–89% of its crop) and Table 1 (93%), each with the engine's clip
        let formula = CropRequest(round: 3, pdf: nil, page: 5, rects: [[236, 425.51, 510, 458.51]], textX: nil,
                                  clip: [230, 425.46, 516, 460.89], look: .ink)
        XCTAssertFalse(CropCache.picksOut(formula))
        let table = CropRequest(round: 3, pdf: nil, page: 7, rects: [[100, 120, 520, 560]], textX: nil,
                                clip: [96, 112, 524, 572], look: .ink)
        XCTAssertFalse(CropCache.picksOut(table))
        // without a clip: the rect + 6 pt, widened to the column
        let whole = CropRequest(round: 1, pdf: nil, page: 0, rects: [[200, 300, 400, 340]], textX: nil, look: .ink)
        XCTAssertFalse(CropCache.picksOut(whole))
        let symbol = CropRequest(round: 1, pdf: nil, page: 0, rects: [[300, 300, 312, 312]], textX: [72, 540], look: .ink)
        XCTAssertTrue(CropCache.picksOut(symbol), "a box on a symbol of a wider crop is picked out")
        let row = CropRequest(round: 1, pdf: nil, page: 0, rects: [[100, 200, 520, 212]], textX: nil,
                              clip: [96, 112, 524, 572], look: .ink)
        XCTAssertTrue(CropCache.picksOut(row), "a box on one row of a table")

        // drawn with no tint (the card passes clear): the box's area shows the card through, the ink as printed
        let pg = try page()
        let req = CropRequest(round: 1, pdf: nil, page: 0, rects: [[10, 10, 190, 50]], textX: nil, clip: [0, 0, 200, 60])
        XCTAssertFalse(CropCache.picksOut(req))
        let ink = Palette.pair(NSColor(hex: 0x1D4ED8), NSColor(hex: 0x60A5FA))
        for dark in [false, true] {
            let bare = try XCTUnwrap(CropCache.draw(pg, req, CropStyle(look: .ink, dark: dark, density: 2, ink: ink, tint: .clear)))
            XCTAssertEqual(pixel(bare, 150, 45, density: 2), [0, 0, 0, 0], "no plate behind the ink")
            XCTAssertEqual(pixel(bare, 100, 35, density: 2), [0, 0, 0, 0])
            XCTAssertEqual(pixel(bare, 50, 25, density: 2)[3], 255, "the ink itself")
            let tinted = try XCTUnwrap(CropCache.draw(pg, req, CropStyle(look: .ink, dark: dark, density: 2, ink: ink)))
            XCTAssertGreaterThan(pixel(tinted, 150, 45, density: 2)[3], 0, "the plate a tint would have made")
        }
    }

    /// The outline is 1.5 pt on screen whatever the crop's scale: thinner in page points on a crop shown larger, thicker
    /// on one shown smaller (the UI audit: a hairline on a shrunk table, a heavy frame on an enlarged formula).
    func testTheOutlineIsOneAndAHalfPointsOnScreen() throws {
        let pg = try page()
        let req = CropRequest(round: 1, pdf: nil, page: 0, rects: [[130, 40, 170, 50]], textX: nil, clip: [0, 0, 200, 60])
        let ink = NSColor(hex: 0x1D4ED8)
        let big = CropStyle(look: .paper, dark: false, density: 4, screen: 2, ink: ink)  // shown at twice its size
        XCTAssertEqual(big.line(1.5), 0.75, accuracy: 0.001)
        let large = try XCTUnwrap(CropCache.draw(pg, req, big))
        XCTAssertEqual(pixel(large, 150, 50.75, density: 4)[2], 0xD8, accuracy: 3)
        XCTAssertEqual(pixel(large, 150, 51.4, density: 4), [255, 255, 255, 255])
        let small = CropStyle(look: .paper, dark: false, density: 1, screen: 2, ink: ink)  // shown at half its size
        XCTAssertEqual(small.line(1.5), 3, accuracy: 0.001)
        let shrunk = try XCTUnwrap(CropCache.draw(pg, req, small))
        XCTAssertEqual(pixel(shrunk, 150, 53, density: 1)[2], 0xD8, accuracy: 3)
        XCTAssertTrue(big.sameLook(small), "the same crop at another width")
        XCTAssertFalse(big.sameLook(CropStyle(look: .paper, dark: false, density: 4, screen: 2, ink: .red)))
    }

    /// An ink crop's size: at most 1.25× its print size, else the card's width over the widest ink area of the card, so
    /// every ink crop of a card is at one scale; a tall one folds to its first 112 pt.
    func testInkCropsShareTheCardsScale() {
        XCTAssertEqual(InkCropLayout.scale(width: 1000, widest: 300), CropView.most, "never past 1.25×")
        XCTAssertEqual(InkCropLayout.scale(width: 330, widest: 400), 330 / 400, accuracy: 0.0001, "a wide table: the card's width")
        XCTAssertEqual(InkCropLayout.scale(width: 330, widest: 0), 1)
        XCTAssertEqual(CropView.tall, 220)
        XCTAssertEqual(CropView.folded, 112)
    }
}
