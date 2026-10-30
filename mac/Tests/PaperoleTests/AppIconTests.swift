import AppKit
import SwiftUI
import XCTest
@testable import Paperole

/// The app icon (UX.md §26, §34; design/logo/LOGO.md §9, §10): Paperole only, Automatic, Light or Dark; its two .icns
/// (and Dev's own) in Resources/AppIcons, The Round's gone from the app; the style in the defaults; test runs read and
/// save nothing; Settings › General's style; the icon's credit in About. Nothing here sets an icon on any file or
/// writes any defaults.
@MainActor
final class AppIconTests: XCTestCase {
    static let mac = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    static let icons = mac.appendingPathComponent("Resources/AppIcons")

    /// Defaults kept in memory: the model reads and saves through it, nothing reaches a file.
    final class MemoryDefaults: UserDefaults {
        var values: [String: Any] = [:]
        override func object(forKey defaultName: String) -> Any? { values[defaultName] }
        override func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
        override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    }

    private var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("pc-icon-" + UUID().uuidString)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: temp) }

    private func model(_ o: LaunchOptions = LaunchOptions(), defaults: UserDefaults? = nil) -> AppIconModel {
        AppIconModel(options: o, defaults: defaults, folder: Self.icons)
    }

    /// The two forms: light or dark as the style and (in Automatic) the system say.
    func testTheStyle() {
        XCTAssertEqual(AppIconStyle.allCases.map(\.title), ["Automatic", "Light", "Dark"])
        let m = model()
        XCTAssertEqual(m.style, .automatic, "Automatic by default")
        var seen: [String] = []
        for style in AppIconStyle.allCases {
            for system in [false, true] {
                m.style = style
                m.systemAppearance(dark: system)
                let dark = style == .dark || (style == .automatic && system)
                XCTAssertEqual(m.dark, dark, "\(style) \(system)")
                XCTAssertEqual(m.resource, dark ? "paperole-dark" : "paperole")
                seen.append(m.resource)
            }
        }
        XCTAssertEqual(Set(seen), ["paperole", "paperole-dark"])
        // the system's appearance changes only Automatic
        m.style = .light
        m.systemAppearance(dark: true)
        XCTAssertEqual(m.resource, "paperole")
        m.style = .automatic
        XCTAssertEqual(m.resource, "paperole-dark")
        m.systemAppearance(dark: false)
        XCTAssertEqual(m.resource, "paperole")
        XCTAssertFalse(m.started, "nothing shown in the Dock by a model not started")
    }

    /// The two .icns: every size from 16 to 1024, the dark one dark; nothing else in Resources/AppIcons but Dev's own
    /// (The Round's are kept in design/logo/red/icns, byte for byte); the About window's icon the one shown, and its
    /// credits the icon's credit; build_app.sh copies these only, under the new ids.
    func testTheIcons() throws {
        let m = model()
        var looks: [Bool: (Double, [UInt8])] = [:]
        for dark in [false, true] {
            let image = try XCTUnwrap(m.image(dark: dark), "\(dark)")
            XCTAssertEqual(Set(image.representations.map(\.pixelsWide)), [16, 32, 64, 128, 256, 512, 1024])
            XCTAssertEqual(image.representations.count, 10)
            looks[dark] = Self.look(image)
        }
        let light = try XCTUnwrap(looks[false]), dark = try XCTUnwrap(looks[true])
        XCTAssertGreaterThan(light.0, 0.65, "the light one is a paper with dark ink")
        XCTAssertLessThan(dark.0, 0.5, "the dark one a dark page with pale ink")
        XCTAssertGreaterThan(light.0 - dark.0, 0.25)
        XCTAssertNotEqual(light.1, dark.1)
        XCTAssertTrue(m.image(dark: false) === m.image(dark: false), "loaded once")
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.icons.path).filter { !$0.hasPrefix(".") }.sorted()
        XCTAssertEqual(files, ["paperole-dark.icns", "paperole-dev.icns", "paperole.icns"], "only Paperole's")
        let history = Self.mac.deletingLastPathComponent().appendingPathComponent("design/logo/red/icns")
        for name in ["round", "round-dark", "round-pilcrow", "round-pilcrow-dark", "round-dev"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: history.appendingPathComponent(name + ".icns").path), name)
        }
        m.style = .dark
        let about = try XCTUnwrap(m.aboutOptions[.applicationIcon] as? NSImage)
        XCTAssertEqual(Self.look(about).1, dark.1, "the About window's icon is the one shown")
        let credits = try XCTUnwrap(m.aboutOptions[.credits] as? NSAttributedString)
        XCTAssertEqual(credits.string, AppIcon.credit)
        XCTAssertEqual(credits.string, "Handwriting: Marcel Proust (public domain); traced from a photo by Warburg, "
                       + "Wikimedia Commons, CC BY-SA 3.0")
        let link = (credits.string as NSString).range(of: "Wikimedia Commons")
        XCTAssertEqual(credits.attribute(.link, at: link.location, effectiveRange: nil) as? URL, AppIcon.creditSource)
        XCTAssertNil(credits.attribute(.link, at: 0, effectiveRange: nil), "only Wikimedia Commons is a link")
        let bare = AppIconModel(options: LaunchOptions(), defaults: nil, folder: temp)
        XCTAssertNil(bare.image, "no icon without the resources (swift run): the bundle's stays")
        XCTAssertNil(bare.aboutOptions[.applicationIcon])
        XCTAssertEqual((bare.aboutOptions[.credits] as? NSAttributedString)?.string, AppIcon.credit, "the credit always")
        // the bundle: CFBundleIconFile is Paperole, light (Paperole Dev's: paperole-dev, Paperole with the DEV mark);
        // the two copied in, and paperole-dev in the dev app; the new ids
        let script = try String(contentsOf: Self.mac.appendingPathComponent("build_app.sh"), encoding: .utf8)
        XCTAssertTrue(script.contains("<key>CFBundleIconFile</key><string>$ICON</string>"))
        XCTAssertTrue(script.contains("NAME=\"Paperole\"; EXE=Paperole; ID=com.paperole.app; ICON=paperole ;"))
        XCTAssertTrue(script.contains("NAME=\"Paperole Dev\"; EXE=PaperoleDev; ID=com.paperole.app.dev; ICON=paperole-dev ;"))
        XCTAssertTrue(script.contains("cp Resources/AppIcons/paperole.icns Resources/AppIcons/paperole-dark.icns \"$NEW/Contents/Resources/\""))
        XCTAssertTrue(script.contains("cp Resources/AppIcons/paperole-dev.icns"))
        XCTAssertFalse(script.contains("round.icns") || script.contains("round-"), "The Round's icons are no longer the app's")
        XCTAssertFalse(script.contains("ID=com.papercollab"))
        XCTAssertTrue(script.contains("/Paperole\"\n"), "the binary swift build makes is Paperole")
        let release = try String(contentsOf: Self.mac.appendingPathComponent("release.sh"), encoding: .utf8)
        XCTAssertTrue(release.contains("ID=com.paperole.app\nOLD_ID=com.papercollab.app\n"))
        XCTAssertTrue(release.contains("SNAP=\"$DEST/Contents/Resources/engine/paperole\""))
        let devIcon = try String(contentsOf: Self.mac.appendingPathComponent("tools/dev_icon.sh"), encoding: .utf8)
        XCTAssertTrue(devIcon.contains("Sources/Paperole/DevMark.swift tools/DevIcon/main.swift"))
    }

    /// The style is kept in the app's defaults in a real run (`appIconStyle`), read back at the next launch; an unknown
    /// value is the default; the icon chosen among three before 2026-10-27 (`appIcon`) is never read.
    func testTheDefaults() {
        let d = MemoryDefaults()
        let m = model(defaults: d)
        XCTAssertTrue(m.remembers)
        XCTAssertTrue(d.values.isEmpty, "nothing saved before a change")
        m.style = .dark
        XCTAssertEqual(d.values as? [String: String], [AppIconModel.styleKey: "dark"], "the style only")
        XCTAssertEqual(model(defaults: d).style, .dark)
        d.values = [AppIconModel.styleKey: "sepia", "appIcon": "round"]
        let unknown = model(defaults: d)
        XCTAssertEqual(unknown.style, .automatic)
        XCTAssertEqual(unknown.resource, "paperole", "The Round, chosen before, is Paperole now")
    }

    /// --icon-style sets the style for a run; a test run (--background, a fixture, the flag, swift test, any bundle but
    /// the app's, the old ids) reads and saves it never. --icon is gone.
    func testTestRunsNeverSave() throws {
        let o = LaunchOptions.parse(["app", "--background", "--icon", "round-pilcrow", "--icon-style", "dark", "--paper", "/a"])
        XCTAssertEqual(o.iconStyle, .dark)
        XCTAssertEqual(o.paper, "/a")
        XCTAssertNil(LaunchOptions.parse(["app", "--icon-style", "sepia"]).iconStyle)
        let flagged = model(o, defaults: MemoryDefaults())
        XCTAssertEqual(flagged.style, .dark)
        XCTAssertEqual(flagged.resource, "paperole-dark")

        // the app's own bundle (made here, never launched) is a real run only without any test flag
        func bundle(_ name: String, _ id: String, _ exe: String) throws -> Bundle {
            let app = temp.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id, "CFBundleExecutable": exe,
                                                                  "CFBundlePackageType": "APPL"], format: .xml, options: 0)
                .write(to: app.appendingPathComponent("Contents/Info.plist"))
            return try XCTUnwrap(Bundle(url: app))
        }
        let app = try bundle("Paperole.app", "com.paperole.app", "Paperole")
        XCTAssertEqual(app.bundleIdentifier, "com.paperole.app")
        XCTAssertTrue(AppIconModel.isRealRun(LaunchOptions(), background: false, bundle: app))
        var fixture = LaunchOptions()
        fixture.fixture = "/f.json"
        var style = LaunchOptions()
        style.iconStyle = .light
        for (name, opts, background) in [("background", LaunchOptions(), true), ("fixture", fixture, false),
                                         ("--icon-style", style, false)] {
            XCTAssertFalse(AppIconModel.isRealRun(opts, background: background, bundle: app), name)
            XCTAssertFalse(AppIconModel.make(options: opts, background: background, bundle: app).remembers, name)
        }
        XCTAssertFalse(AppIconModel.make(options: LaunchOptions(), background: true, bundle: app).mark, "the official app: no mark")
        // Paperole Dev's bundle is a real run too (its own defaults), its icon marked
        let dev = try bundle("Paperole Dev.app", "com.paperole.app.dev", "PaperoleDev")
        XCTAssertTrue(AppIconModel.isRealRun(LaunchOptions(), background: false, bundle: dev))
        XCTAssertFalse(AppIconModel.isRealRun(LaunchOptions(), background: true, bundle: dev))
        let devModel = AppIconModel.make(options: LaunchOptions(), background: true, bundle: dev)
        XCTAssertTrue(devModel.mark)
        XCTAssertFalse(devModel.remembers)
        // the old ids are not the app's any more; swift test, and a bundle of another id
        for (name, id) in [("PaperCollab.app", "com.papercollab.app"), ("PaperCollab Dev.app", "com.papercollab.app.dev"),
                           ("Other.app", "com.example.other")] {
            XCTAssertFalse(AppIconModel.isRealRun(LaunchOptions(), background: false, bundle: try bundle(name, id, "X")), name)
        }
        XCTAssertFalse(AppIconModel.isRealRun(LaunchOptions(), background: false, bundle: .main))
        XCTAssertFalse(AppIconModel.shared.remembers)
        XCTAssertFalse(AppIconModel.shared.started, "swift test never shows an icon")
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.bundleURL.appendingPathComponent("Icon\r").path), "no icon set on it")

        // a test run's model saves nothing anywhere
        let before = UserDefaults.standard.dictionaryRepresentation().filter { $0.key.hasPrefix("appIcon") }.count
        let m = model()
        m.style = .light
        XCTAssertFalse(m.remembers)
        XCTAssertEqual(UserDefaults.standard.dictionaryRepresentation().filter { $0.key.hasPrefix("appIcon") }.count, before)
    }

    /// Settings › General: the style, Automatic, Light or Dark, a segmented control that sets the model's style; the
    /// Appearance tab is gone.
    func testTheStyleInGeneral() throws {
        XCTAssertNil(SettingsView.Tab(rawValue: "appearance"))
        _ = NSApplication.shared
        var o = LaunchOptions()
        o.fixture = ReadingTests.fixtures.appendingPathComponent("state-reading.json").path
        let app = AppModel(options: o)
        let m = model()
        let host = NSHostingView(rootView: GeneralSettings(model: app, icons: m))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func find<T: NSView>(_ type: T.Type, in v: NSView) -> [T] { ((v as? T).map { [$0] } ?? []) + v.subviews.flatMap { find(type, in: $0) } }
        let control = try XCTUnwrap(find(NSSegmentedControl.self, in: host).first)
        XCTAssertEqual((0..<control.segmentCount).map { control.label(forSegment: $0) }, ["Automatic", "Light", "Dark"])
        XCTAssertEqual(control.selectedSegment, 0)
        control.selectedSegment = 2
        _ = control.sendAction(control.action, to: control.target)
        XCTAssertEqual(m.style, .dark)
        XCTAssertEqual(m.resource, "paperole-dark")
        XCTAssertEqual(AppIconModel.title, "App icon")
        XCTAssertEqual(AppIconModel.detail, "Automatic follows the system’s light or dark appearance.")
    }

    /// The image drawn at 32 × 32: its mean lightness inside the body, and its pixels.
    static func look(_ image: NSImage) -> (Double, [UInt8]) {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 128, bitsPerPixel: 32)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
        NSGraphicsContext.restoreGraphicsState()
        let px = Array(UnsafeBufferPointer(start: rep.bitmapData, count: 32 * 32 * 4))
        var sum = 0.0, n = 0.0
        for y in 6..<26 {
            for x in 6..<26 {
                let i = (y * 32 + x) * 4
                sum += (0.2126 * Double(px[i]) + 0.7152 * Double(px[i + 1]) + 0.0722 * Double(px[i + 2])) / 255
                n += 1
            }
        }
        return (sum / n, px)
    }
}
