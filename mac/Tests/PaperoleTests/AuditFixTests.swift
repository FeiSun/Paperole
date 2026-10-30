import AppKit
import SwiftUI
import XCTest
@testable import Paperole

/// The fixes of the 2026-10-20 UI audit that a test can hold: the closed comments' PDF labels, the map's dimmed words
/// and calmer light ramp, its links, one sign per meaning (Kept as is, did not build, position uncertain), the toast
/// kept off the answer row, a group header's short forms, the tag signs in one box, and typographic apostrophes.
/// Synthetic values only.
@MainActor
final class AuditFixTests: XCTestCase {
    private func srgb(_ c: NSColor, dark: Bool) -> NSColor {
        var out = NSColor.black
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance { out = c.usingColorSpace(.sRGB)! }
        return out
    }

    private func over(_ c: NSColor, _ alpha: CGFloat, _ bg: NSColor) -> NSColor {
        let (a, b) = (c.usingColorSpace(.sRGB)!, bg.usingColorSpace(.sRGB)!)
        let k = alpha * a.alphaComponent
        return NSColor(srgbRed: k * a.redComponent + (1 - k) * b.redComponent, green: k * a.greenComponent + (1 - k) * b.greenComponent,
                       blue: k * a.blueComponent + (1 - k) * b.blueComponent, alpha: 1)
    }

    /// A closed comment's id label on the white page: an outline with the id in the label's colour, at 4.5:1 or more
    /// for every colour (before: white at 80% on the colour at 50%, 1.8:1).
    func testClosedLabelsRead() {
        for color in MarkColor.allCases {
            let style = MarkAnnotation.labelStyle(color.ink, faded: true)
            let ground = over(style.fill, 1, .white)
            XCTAssertGreaterThanOrEqual(MapFoldTests.contrast(style.text, ground), 4.5, "\(color)")
            XCTAssertNotNil(style.stroke)
            let open = MarkAnnotation.labelStyle(color.ink, faded: false)
            XCTAssertEqual(open.text, .white)
            XCTAssertNil(open.stroke)
        }
    }

    /// While something is followed, a dimmed cell's name and number step back together, by colour, and still read at
    /// 4.5:1 on the darkest step dimmed and on the panel; the light steps are as nearly neutral as the dark ones.
    func testDimmedWordsAndTheCalmLightRamp() {
        for dark in [false, true] {
            let ink = MapInk(dark: dark)
            let dimmedCell = over(ink.over(.s3), CGFloat(ink.dim), ink.over(.content))
            XCTAssertGreaterThanOrEqual(MapFoldTests.contrast(ink.over(.dimText), dimmedCell), 4.5, "dark \(dark)")
            XCTAssertGreaterThanOrEqual(MapFoldTests.contrast(ink.over(.dimText), ink.over(.content)), 4.5, "dark \(dark)")
            XCTAssertLessThan(MapFoldTests.contrast(ink.over(.dimText), ink.over(.content)),
                              MapFoldTests.contrast(ink.over(.number), ink.over(.content)), "it steps back")
            for step in [MapRole.track, .s1, .s2, .s3, .mini1, .mini2, .mini3] {
                let c = DesignPaletteTests.lab(ink.over(step))
                XCTAssertLessThanOrEqual(hypot(c.a, c.b), 5, "nearly neutral: \(step), dark \(dark)")
            }
            // the map's links are the system's link colour, as every link in words
            XCTAssertLessThan(DesignPaletteTests.deltaE(ink.over(.link), srgb(Palette.link, dark: dark)), 1, "dark \(dark)")
        }
    }

    /// The toast never covers the expanded card's answer row: it goes 8 pt above it when the row is in its zone, and
    /// stays at its place when not (the UI audit: it sat on the next card's Follow up).
    func testTheToastKeepsOffTheAnswerRow() {
        let h: CGFloat = 600
        XCTAssertEqual(ToastPlace.bottom(base: 16, height: h, headers: []), 16)
        // the row from 540 to 580 from the top: in the zone (552–584)
        XCTAssertEqual(ToastPlace.bottom(base: 16, height: h, headers: [], answers: (540, 580)), h - 540 + 8)
        // far above the zone: no change
        XCTAssertEqual(ToastPlace.bottom(base: 16, height: h, headers: [], answers: (200, 240)), 16)
        // a header in the zone and the row above it: above both
        let b = ToastPlace.bottom(base: 16, height: h, headers: [(560, 590)], answers: (520, 556))
        XCTAssertEqual(b, h - 520 + 8)
        // scrolled out of sight: ignored; never above the list's top
        XCTAssertEqual(ToastPlace.bottom(base: 16, height: h, headers: [], answers: (-80, -10)), 16)
        XCTAssertLessThanOrEqual(ToastPlace.bottom(base: 16, height: 100, headers: [], answers: (10, 96)), 100 - ToastPlace.height - 4)
    }

    func testAGroupHeadersShortForms() {
        XCTAssertEqual(SectionHeader.forms("goes in the Round 2 email"), ["goes in the Round 2 email", "in the Round 2 email", "Round 2 email"])
        XCTAssertEqual(SectionHeader.forms("in the Round 3 email"), ["in the Round 3 email", "Round 3 email"])
        XCTAssertEqual(SectionHeader.forms("left open"), ["left open"])
    }

    /// Every tag sign fits one box, a wide one set smaller, so the names after the signs line up.
    func testTagSignsFitOneBox() {
        for t in TagCatalog.defaults {
            guard let sign = t.sign else { continue }
            let box = TagSign(sign: sign, name: t.name, size: 12).box
            let size = TagSign.fitted(sign, size: 11.5, box: box)
            let image = NSImage(systemSymbolName: sign, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .regular))
            XCTAssertLessThanOrEqual(image?.size.width ?? 0, box + 1, sign)
            XCTAssertLessThanOrEqual(size, 11.5)
        }
        XCTAssertLessThan(TagSign.fitted("textformat.abc", size: 11.5, box: 19), 11.5, "the wide one, smaller")
        XCTAssertEqual(TagSign.fitted("function", size: 11.5, box: 19), 11.5, "the others as they are")
    }

    /// One sign per meaning, read in the sources (as KeyHintTests: SwiftUI builds no tree for views never on screen):
    /// Kept as is is "–" in the overview as in Review (no "=" and no `equal`); the triangle only for Not found and a
    /// build with errors (the octagon for did not build, a question mark for position uncertain); and the UI's words
    /// use the typographic apostrophe.
    func testOneSignPerMeaningAndTypographicApostrophes() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Paperole")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "DebugScript.swift" }
        XCTAssertGreaterThan(files.count, 10)
        let literal = try NSRegularExpression(pattern: #"(?<!#)"((?:[^"\\]|\\.)*)""#)
        var equalSigns: [String] = [], triangles: [String] = [], straight: [String] = []
        for f in files {
            for (n, raw) in try String(contentsOf: f, encoding: .utf8).components(separatedBy: "\n").enumerated() {
                let line = raw.components(separatedBy: " //").first ?? ""
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                let at = "\(f.lastPathComponent):\(n + 1)"
                if f.lastPathComponent.hasPrefix("Overview") && (line.contains("\"= ") || line.contains("\"equal\"")) { equalSigns.append(at) }
                if line.contains("\"exclamationmark.triangle\"") { triangles.append(at) }
                for m in literal.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                    guard let r = Range(m.range(at: 1), in: line) else { continue }
                    let text = String(line[r])
                    if text.range(of: #"[A-Za-z]'[a-z]"#, options: .regularExpression) != nil && !text.contains("n't") {
                        straight.append(at + " " + text)
                    }
                }
            }
        }
        XCTAssertEqual(equalSigns, [], "Kept as is has one sign")
        XCTAssertEqual(Set(triangles.map { $0.components(separatedBy: ":")[0] }), ["Palette.swift"], triangles.joined(separator: ", "))
        XCTAssertEqual(triangles.count, 2, "Not found's and BuildSign.errors")
        XCTAssertEqual(straight, [], "a straight apostrophe in the UI's words")
        XCTAssertEqual(Scope.answers["kept"], Status.keptAsIs.glyph + " kept as is")
        XCTAssertEqual(BuildSign.failed, "xmark.octagon")
    }
}
