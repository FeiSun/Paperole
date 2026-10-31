import AppKit
import XCTest
@testable import Paperole

/// UI v2.1's design language (design/ui-v2.1/POLISH.md §2; phase 1): the Sage accent and the palette's tokens, their
/// contrast and their distance from the colours that mean something, the note as a title, and Finish Round… prominent
/// only when the round is ready. Synthetic fixtures only.
final class DesignPaletteTests: XCTestCase {
    private func srgb(_ c: NSColor, _ mode: NSAppearance.Name) -> NSColor {
        var out = NSColor.black
        NSAppearance(named: mode)!.performAsCurrentDrawingAppearance { out = c.usingColorSpace(.sRGB)! }
        return out
    }

    private func lum(_ c: NSColor) -> CGFloat {
        func ch(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * ch(c.redComponent) + 0.7152 * ch(c.greenComponent) + 0.0722 * ch(c.blueComponent)
    }

    private func contrast(_ a: NSColor, _ b: NSColor, _ mode: NSAppearance.Name) -> CGFloat {
        let (x, y) = (lum(srgb(a, mode)), lum(srgb(b, mode)))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// `c` at `alpha` over `bg`, as a fill on the page or a card.
    private func over(_ c: NSColor, _ alpha: CGFloat, _ bg: NSColor = .white) -> NSColor {
        let (a, b) = (c.usingColorSpace(.sRGB)!, bg.usingColorSpace(.sRGB)!)
        return NSColor(srgbRed: alpha * a.redComponent + (1 - alpha) * b.redComponent,
                       green: alpha * a.greenComponent + (1 - alpha) * b.greenComponent,
                       blue: alpha * a.blueComponent + (1 - alpha) * b.blueComponent, alpha: 1)
    }

    /// CIELAB (D65) of an sRGB colour.
    static func lab(_ c: NSColor) -> (L: Double, a: Double, b: Double) {
        let s = c.usingColorSpace(.sRGB)!
        func lin(_ v: CGFloat) -> Double { let v = Double(v); return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let (r, g, b) = (lin(s.redComponent), lin(s.greenComponent), lin(s.blueComponent))
        let x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047
        let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
        let z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883
        func f(_ t: Double) -> Double { t > 216 / 24389 ? cbrt(t) : (24389 / 27 * t + 16) / 116 }
        return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }

    /// CIEDE2000: under about 10, two colours are easily taken for each other (POLISH §2.2).
    static func deltaE(_ c1: NSColor, _ c2: NSColor) -> Double { deltaE(lab(c1), lab(c2)) }

    static func deltaE(_ x: (L: Double, a: Double, b: Double), _ y: (L: Double, a: Double, b: Double)) -> Double {
        let (l1, a1, b1) = x, (l2, a2, b2) = y
        let rad = Double.pi / 180
        let cm = (hypot(a1, b1) + hypot(a2, b2)) / 2
        let g = 0.5 * (1 - sqrt(pow(cm, 7) / (pow(cm, 7) + pow(25, 7))))
        let (a1p, a2p) = ((1 + g) * a1, (1 + g) * a2)
        let (c1p, c2p) = (hypot(a1p, b1), hypot(a2p, b2))
        func hue(_ b: Double, _ a: Double) -> Double { let h = atan2(b, a) / rad; return h < 0 ? h + 360 : h }
        let (h1, h2) = (hue(b1, a1p), hue(b2, a2p))
        let dl = l2 - l1, dc = c2p - c1p
        var dh = h2 - h1
        if c1p * c2p == 0 { dh = 0 } else if dh > 180 { dh -= 360 } else if dh < -180 { dh += 360 }
        let dH = 2 * sqrt(c1p * c2p) * sin(dh / 2 * rad)
        let lm = (l1 + l2) / 2, cmp = (c1p + c2p) / 2
        var hm = h1 + h2
        if c1p * c2p != 0 { hm = abs(h1 - h2) <= 180 ? (h1 + h2) / 2 : (h1 + h2 < 360 ? (h1 + h2 + 360) / 2 : (h1 + h2 - 360) / 2) }
        let t = 1 - 0.17 * cos((hm - 30) * rad) + 0.24 * cos(2 * hm * rad) + 0.32 * cos((3 * hm + 6) * rad)
            - 0.20 * cos((4 * hm - 63) * rad)
        let dth = 30 * exp(-pow((hm - 275) / 25, 2)), rc = 2 * sqrt(pow(cmp, 7) / (pow(cmp, 7) + pow(25, 7)))
        let sl = 1 + 0.015 * pow(lm - 50, 2) / sqrt(20 + pow(lm - 50, 2)), sc = 1 + 0.045 * cmp, sh = 1 + 0.015 * cmp * t
        let rt = -sin(2 * dth * rad) * rc
        return sqrt(pow(dl / sl, 2) + pow(dc / sc, 2) + pow(dH / sh, 2) + rt * (dc / sc) * (dH / sh))
    }

    func testDeltaEMatchesTheReference() {
        // Sharma, Wu and Dalal's CIEDE2000 test data, pairs 1, 7 and 17
        XCTAssertEqual(Self.deltaE((50, 2.6772, -79.7751), (50, 0, -82.7485)), 2.0425, accuracy: 0.0001)
        XCTAssertEqual(Self.deltaE((50, 0, 0), (50, -1, 2)), 2.3669, accuracy: 0.0001)
        XCTAssertEqual(Self.deltaE((50, 2.5, 0), (73, 25, -18)), 27.1492, accuracy: 0.0001)
        // and POLISH §2.2's own: Sage and the olive bar, the system blue and the blue mark's ink
        XCTAssertEqual(Self.deltaE(NSColor(hex: 0x566B58), NSColor(hex: 0x6E7D2A)), 17.3, accuracy: 0.1)
        XCTAssertEqual(Self.deltaE(NSColor(hex: 0x007AFF), NSColor(hex: 0x1D4ED8)), 15.8, accuracy: 0.1)
    }

    /// The accent is the app's AccentColor asset, compiled by build_app.sh and named in its Info.plist.
    func testTheAccentAssetIsSage() throws {
        let mac = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: mac.appendingPathComponent(
            "Resources/Assets.xcassets/AccentColor.colorset/Contents.json"))) as? [String: Any])
        let colors = try XCTUnwrap(json["colors"] as? [[String: Any]])
        func hex(_ entry: [String: Any]) -> Int? {
            guard let c = (entry["color"] as? [String: Any])?["components"] as? [String: String] else { return nil }
            return ["red", "green", "blue"].reduce(0) { $0 << 8 | Int(c[$1]!.dropFirst(2), radix: 16)! }
        }
        let dark = colors.first { ($0["appearances"] as? [[String: String]])?.first?["value"] == "dark" }
        let light = colors.first { $0["appearances"] == nil }
        XCTAssertEqual(light.flatMap(hex), Palette.sage.light)
        XCTAssertEqual(dark.flatMap(hex), Palette.sage.dark)
        let script = try String(contentsOf: mac.appendingPathComponent("build_app.sh"), encoding: .utf8)
        XCTAssertTrue(script.contains("<key>NSAccentColorName</key><string>AccentColor</string>"))
        XCTAssertTrue(script.contains("actool Resources/Assets.xcassets"))
    }

    /// POLISH §2.2's contrast: white on the accent (the default button); secondary words 5.2:1 on the panel (6.9:1 in
    /// Dark Mode); accent text and errors as words; UI v4: To check's vermilion as a graphic, never words (measured
    /// 4.63:1 and 5.01:1 on the panel and the card, 4.98:1 and 4.15:1 in Dark Mode); tertiary for "–" only, between
    /// 3:1 and 4.7:1 (3.62:1 and 3.92:1, 4.61:1 and 3.84:1).
    func testContrast() {
        let sage = (light: NSColor(hex: Palette.sage.light), dark: NSColor(hex: Palette.sage.dark))
        XCTAssertGreaterThanOrEqual(contrast(.white, sage.light, .aqua), 5.7)
        XCTAssertGreaterThanOrEqual(contrast(.white, sage.dark, .darkAqua), 4.5)
        for mode in [NSAppearance.Name.aqua, .darkAqua] {
            for bg in [Palette.panel, Palette.card] {
                XCTAssertGreaterThanOrEqual(contrast(Palette.label, bg, mode), 11, mode.rawValue)
                XCTAssertGreaterThanOrEqual(contrast(Palette.label2, bg, mode), 8, mode.rawValue)
                XCTAssertGreaterThanOrEqual(contrast(Palette.secondary, bg, mode), 5.2, mode.rawValue)
                XCTAssertGreaterThanOrEqual(contrast(Palette.accentText, bg, mode), 6, mode.rawValue)
                XCTAssertGreaterThanOrEqual(contrast(Palette.danger, bg, mode), 5.4, mode.rawValue)
                XCTAssertGreaterThanOrEqual(contrast(Palette.toCheck, bg, mode), 3, "\(mode.rawValue): vermilion, a graphic")
                XCTAssertGreaterThanOrEqual(contrast(Palette.tertiary, bg, mode), 3, "\(mode.rawValue): \"–\" still seen")
                XCTAssertLessThan(contrast(Palette.tertiary, bg, mode), 4.7, "tertiary is for \"–\" only")
            }
        }
        XCTAssertGreaterThanOrEqual(contrast(Palette.secondary, Palette.panel, .darkAqua), 6.8)
        XCTAssertEqual(srgb(Palette.danger, .aqua), NSColor(hex: 0xC42121).usingColorSpace(.sRGB))  // was #DC2626
    }

    /// The accent is far from every colour that means something, in either mode (POLISH §2.2's table, measured again
    /// on the test build's screenshots, UX.md §19); the vermilion of "your move" (UI v4) is near the orange mark, the
    /// known limitation that the ring's shape answers, and apart from the red of an error.
    func testTheAccentIsApartFromTheMeaningfulColours() {
        for (accent, mode) in [(NSColor(hex: Palette.sage.light), NSAppearance.Name.aqua), (NSColor(hex: Palette.sage.dark), .darkAqua)] {
            let pairs: [(String, NSColor, Double)] = [
                ("olive reading bar", Palette.readingBar, 15), ("attached change band", Palette.attachedChange, 30),
                ("blue mark's fill on the page", over(MarkColor.blue.fill, 0.35), 35), ("blue mark's ink", MarkColor.blue.ink, 35),
                ("teal mark's ink", MarkColor.teal.ink, 12.5), ("unrequested band", over(Palette.unrequestedBand, 0.7), 18),
                ("decided grey", srgb(Palette.neutral, mode), 19), ("unrequested words", srgb(Palette.unrequested, mode), 16),
                ("changed words", srgb(Palette.changedWords, mode), 24), ("change dot", srgb(Palette.change, mode), 15),
            ]
            for (name, colour, least) in pairs {
                XCTAssertGreaterThanOrEqual(Self.deltaE(accent, colour), least, "\(mode.rawValue): \(name)")
            }
            for m in MarkColor.allCases {  // every mark, as fill on the page and as ink
                XCTAssertGreaterThanOrEqual(Self.deltaE(accent, over(m.fill, 0.35)), 12, m.name)
                XCTAssertGreaterThanOrEqual(Self.deltaE(accent, m.ink), 12, m.name)
            }
        }
        // To check's vermilion: 7.45 from the orange ink, 17.8 from the orange fill in Dark Mode (the nearest marks);
        // 20.9 and 34.6 from the yellow's; 5.75 from the red of an error (13.4 in Dark Mode)
        let vermilion = (light: srgb(Palette.toCheck, .aqua), dark: srgb(Palette.toCheck, .darkAqua))
        XCTAssertGreaterThanOrEqual(Self.deltaE(vermilion.light, MarkColor.orange.ink), 7.4)
        XCTAssertGreaterThanOrEqual(Self.deltaE(vermilion.dark, MarkColor.orange.fill), 17.7)
        XCTAssertGreaterThanOrEqual(Self.deltaE(vermilion.light, MarkColor.yellow.ink), 20)
        XCTAssertGreaterThanOrEqual(Self.deltaE(vermilion.dark, MarkColor.yellow.fill), 34)
        XCTAssertGreaterThanOrEqual(Self.deltaE(vermilion.light, srgb(Palette.danger, .aqua)), 5)
        XCTAssertGreaterThanOrEqual(Self.deltaE(vermilion.dark, srgb(Palette.danger, .darkAqua)), 5)
        XCTAssertTrue(Status.toCheck.tinted, "so its chip is outlined, its shape apart from a mark's label")
    }

    /// What the app draws (the PDF's backdrop, the panel, the cards) has almost no hue: LCH chroma ≤ 2.
    func testSurfacesHaveAlmostNoHue() {
        for mode in [NSAppearance.Name.aqua, .darkAqua] {
            for (name, c) in [("backdrop", Palette.pdfBackdrop), ("panel", Palette.panel), ("card", Palette.card)] {
                let l = Self.lab(srgb(c, mode))
                XCTAssertLessThanOrEqual(hypot(l.a, l.b), 2, "\(mode.rawValue) \(name)")
            }
        }
        // the card one step above the panel, the page the brightest thing in Light Mode
        XCTAssertGreaterThan(lum(srgb(Palette.card, .darkAqua)), lum(srgb(Palette.panel, .darkAqua)))
        XCTAssertGreaterThan(lum(srgb(Palette.card, .aqua)), lum(srgb(Palette.pdfBackdrop, .aqua)))
    }

    /// The marks' tint on a card: 36% / 14% in Light Mode, 30% / 16% in Dark Mode (POLISH §6, 12; it was 40% / 20%).
    func testDarkModeTints() {
        let yellow = MarkColor.yellow
        XCTAssertEqual(srgb(yellow.tint(strong: true), .darkAqua).alphaComponent, 0.30, accuracy: 0.001)
        XCTAssertEqual(srgb(yellow.tint(strong: false), .darkAqua).alphaComponent, 0.16, accuracy: 0.001)
        XCTAssertEqual(srgb(yellow.tint(strong: true), .aqua).alphaComponent, 0.36, accuracy: 0.001)
        XCTAssertEqual(srgb(yellow.tint(strong: false), .aqua).alphaComponent, 0.14, accuracy: 0.001)
    }
}

/// The note as a card's title (POLISH §2.3, §6 decision 6).
/// UI v4 (design/ui-v4/BRIEF.md §8.4): vermilion is a mark's colour, never the words'. Every use of it in the sources
/// on a line that makes a Text is the ring "○" itself, and no modifier chain that starts with a Text gives it the
/// colour. Multi-line uses through a variable are the views' own (StateWord, Tag, UnsentTag, the card's header).
final class VermilionTests: XCTestCase {
    func testNoWordsAreVermilion() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Paperole")
        let tokens = ["Palette.toCheck", "Status.toCheck.color", "color(.attention)", "ink: .attention"]
        let allowed: [String] = []
        var found: [String] = []
        for f in try FileManager.default.contentsOfDirectory(atPath: dir.path) where f.hasSuffix(".swift") {
            let lines = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8).components(separatedBy: "\n")
            for (i, line) in lines.enumerated() where tokens.contains(where: line.contains) {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") || allowed.contains(where: code.contains) || code.contains("○") { continue }
                if code.contains("ink: .attention") { found.append("\(f):\(i + 1)"); continue }
                // what the colour is given to: the words before it on the line, or a modifier chain's first line
                var head = String(code[..<tokens.compactMap { code.range(of: $0)?.lowerBound }.min()!])
                if code.hasPrefix(".") {
                    var j = i - 1
                    while j > 0, lines[j].trimmingCharacters(in: .whitespaces).hasPrefix(".") { j -= 1 }
                    head = lines[j]
                }
                if head.replacingOccurrences(of: "Text(Image", with: "").contains("Text(") { found.append("\(f):\(i + 1)") }
            }
        }
        XCTAssertEqual(found, [], "words in vermilion")
    }
}

final class NoteTitleTests: XCTestCase {
    func testTheFirstSentenceIsTheTitle() {
        let t = NoteTitle("Motivate the 2 kHz band first. Then cite the survey.")
        XCTAssertEqual(t.first, "Motivate the 2 kHz band first.")
        XCTAssertEqual(t.rest, "Then cite the survey.")
        XCTAssertEqual(t.style, .sentence)
        XCTAssertFalse(t.cjk)
        let one = NoteTitle("Motivate the 2 kHz band before you cite the survey.")
        XCTAssertEqual(one.first, "Motivate the 2 kHz band before you cite the survey.")
        XCTAssertEqual(one.rest, "")
    }

    func testChineseSentences() {
        let t = NoteTitle("式 (2) 里 c_m 的单位和 τ 对不上。请在正文里写清楚。")
        XCTAssertEqual(t.first, "式 (2) 里 c_m 的单位和 τ 对不上。")
        XCTAssertEqual(t.rest, "请在正文里写清楚。")
        XCTAssertTrue(t.cjk)
        XCTAssertEqual(NoteTitle("好，但要说明怎么缓解（比如换一个 judge 复核）。").rest, "")
        XCTAssertEqual(NoteTitle("这句有依据吗？加引用或删掉。").first, "这句有依据吗？")
        XCTAssertEqual(NoteTitle("Why this “robust”？ 说明一下").first, "Why this “robust”？")
    }

    /// Not at "Fig. 1", "e.g. the" or "et al. (2020)": a Latin sentence ends before a capital or a CJK character.
    func testAbbreviationsDoNotEndTheSentence() {
        XCTAssertEqual(NoteTitle("Night and day need separate baselines in Fig. 1. Say why.").first,
                       "Night and day need separate baselines in Fig. 1.")
        XCTAssertEqual(NoteTitle("Use a stronger baseline, e.g. the one in Table 2. It matters.").rest, "It matters.")
        XCTAssertEqual(NoteTitle("As in Lee et al. (2020), report the variance").rest, "")
        XCTAssertEqual(NoteTitle("Is this right? 再看一下。").first, "Is this right?")
    }

    func testANewLineEndsTheFirstSentence() {
        let t = NoteTitle("Axis labels\nare unreadable at print size")
        XCTAssertEqual(t.first, "Axis labels")
        XCTAssertEqual(t.rest, "are unreadable at print size")
    }

    /// A first sentence over about 80 Latin characters (40 CJK ones) makes the whole note one 14 pt block.
    func testALongFirstSentenceMakesOneBlock() {
        let long = "This paragraph claims that the memory module always increases diversity, which the table does not show at all. Fix it."
        let t = NoteTitle(long)
        XCTAssertEqual(t.style, .long)
        XCTAssertEqual(t.first, long)
        XCTAssertEqual(t.rest, "")
        let cjk = NoteTitle("这一段说记忆模块总是提高多样性但是表格里面并没有显示出这样的结果所以需要重新写一下这个结论并且补充实验。好。")
        XCTAssertEqual(cjk.style, .long)
        XCTAssertEqual(NoteTitle("这一段说记忆模块总是提高多样性。好。").style, .sentence)
        XCTAssertEqual(NoteTitle("").first, "")
    }
}

/// Finish Round… is the window's one prominent button once nothing is left (POLISH §3 row 1, §6 decision 10).
@MainActor
final class ReadyToFinishTests: XCTestCase {
    func testOnlyWhenNothingIsLeft() throws {
        _ = NSApplication.shared
        var o = LaunchOptions()
        o.fixture = StepTests.fixtures.appendingPathComponent("state-m2a.json").path
        o.drafts = FileManager.default.temporaryDirectory.appendingPathComponent("pc-ready-" + UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: o.drafts!) }
        let m = AppModel(options: o)
        XCTAssertFalse(m.readyToFinish, "comments and an edit to check")
        let url = StepTests.fixtures.appendingPathComponent("state-m2a.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["comments"] = (json["comments"] as? [[String: Any]] ?? []).map { c in
            var c = c
            if c["carried"] as? Bool == true, c["verdict"] is NSNull || c["verdict"] == nil { c["verdict"] = "verified" }
            return c
        }
        m.apply(try EngineState.decode(JSONSerialization.data(withJSONObject: json)))
        XCTAssertEqual(m.commentsToCheck, 0)
        XCTAssertFalse(m.readyToFinish, "c06 is still to check")
        json["changes"] = (json["changes"] as? [[String: Any]] ?? []).map { c in
            var c = c
            c["checked"] = true
            return c
        }
        m.apply(try EngineState.decode(JSONSerialization.data(withJSONObject: json)))
        XCTAssertTrue(m.readyToFinish)
        var closed = json
        var round = try XCTUnwrap(closed["round"] as? [String: Any])
        round["closed"] = true
        closed["round"] = round
        m.apply(try EngineState.decode(JSONSerialization.data(withJSONObject: closed)))
        XCTAssertFalse(m.readyToFinish, "a closed round has nothing to finish")
    }
}
