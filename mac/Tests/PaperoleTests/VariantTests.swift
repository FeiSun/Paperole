import AppKit
import XCTest
@testable import Paperole

/// The two apps (AppVariant.swift; the advisor's decision, 2026-10-21): only the bundle id com.paperole.app is the
/// official app, anything else is Paperole Dev, with folders of its own; `swift test` is Dev; the DEV mark only in
/// Dev; the engine's folder first on PYTHONPATH (the official app's bundled one, else the checkout's); a backup's
/// format name the same in both. Nothing here reads or writes the apps' folders or any defaults.
@MainActor
final class VariantTests: XCTestCase {
    private var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("pc-variant-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: temp) }

    /// Exactly com.paperole.app is official; the dev id, any other id (the old ids among them), and none are Dev.
    func testTheVariantComesFromTheBundleID() {
        XCTAssertEqual(AppVariant(bundleID: "com.paperole.app"), .official)
        let others: [String?] = ["com.paperole.app.dev", "com.paperole.App", "com.paperole.app ", "com.paperole",
                                 "com.paperole.apps", "com.papercollab.app", "com.papercollab.app.dev", "com.apple.dt.xctest.tool",
                                 "", nil]
        for id in others { XCTAssertEqual(AppVariant(bundleID: id), .dev, id ?? "nil") }
        XCTAssertEqual(AppVariant.officialID, "com.paperole.app")
        XCTAssertEqual(AppVariant.devID, "com.paperole.app.dev")
        XCTAssertEqual([AppVariant.official.id, AppVariant.dev.id], ["com.paperole.app", "com.paperole.app.dev"])
        XCTAssertEqual([AppVariant.official.oldID, AppVariant.dev.oldID], ["com.papercollab.app", "com.papercollab.app.dev"])
        XCTAssertEqual(AppVariant.current, .dev, "swift test is never the official app")
        XCTAssertTrue(AppVariant.current.isDev)
        XCTAssertFalse(AppVariant.official.isDev)
    }

    /// Each app's name and folders; under `swift test` every standard place is Dev's, none the official app's. The
    /// folders are named after the app since 2026-10-27; a test run takes the new names and never looks at the disk for
    /// the old ones (DataHome; where a real run finds them: MigrationTests).
    func testTheFolders() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        XCTAssertEqual(AppVariant.official.name, "Paperole")
        XCTAssertEqual(AppVariant.dev.name, "Paperole Dev")
        XCTAssertEqual(AppVariant.official.oldName, "PaperCollab")
        XCTAssertEqual(AppVariant.dev.oldName, "PaperCollab Dev")
        XCTAssertEqual(AppVariant.official.dataFolder, support.appendingPathComponent("Paperole"))
        XCTAssertEqual(AppVariant.dev.dataFolder, support.appendingPathComponent("Paperole Dev"))
        XCTAssertEqual(AppVariant.official.cachesFolder, caches.appendingPathComponent("Paperole"))
        XCTAssertEqual(AppVariant.dev.cachesFolder, caches.appendingPathComponent("Paperole Dev"))
        let dev = AppVariant.dev.dataFolder
        XCTAssertEqual(PaperStore.fileURL, dev.appendingPathComponent("papers.json"))
        XCTAssertEqual(DraftStore.standard, dev.appendingPathComponent("drafts"))
        XCTAssertEqual(TagStore.standard, dev.appendingPathComponent("tags.json"))
        XCTAssertEqual(ThumbnailStore.standardRoot, AppVariant.dev.cachesFolder.appendingPathComponent("Thumbnails"))
        for u in [PaperStore.fileURL, DraftStore.standard, TagStore.standard, ThumbnailStore.standardRoot] {
            XCTAssertFalse(u.path.hasPrefix(AppVariant.official.dataFolder.path + "/"), u.path)
            XCTAssertFalse(u.path.hasPrefix(AppVariant.official.cachesFolder.path + "/"), u.path)
        }
        XCTAssertTrue(AppVariant.devNote.hasPrefix("This is Paperole Dev, for testing."))
    }

    /// The renaming (2026-10-27): a file's made_by "variant" is read by either name, the app's (every file from now on)
    /// or the one it had before, and shown as the app's name; anything else is no app of these and shown as it is. The
    /// format's name ("app") is written "Paperole" and read by either name, as the engine's archive.FORMATS.
    func testAFileNamesTheAppByEitherName() {
        XCTAssertEqual(AppVariant(stored: "PaperCollab"), .official)
        XCTAssertEqual(AppVariant(stored: "Paperole"), .official)
        XCTAssertEqual(AppVariant(stored: "PaperCollab Dev"), .dev)
        XCTAssertEqual(AppVariant(stored: "Paperole Dev"), .dev)
        for s in [nil, "", "papercollab", "PaperCollab Dev ", "Other App"] as [String?] { XCTAssertNil(AppVariant(stored: s), s ?? "nil") }
        XCTAssertEqual(AppVariant.shown(stored: "PaperCollab"), "Paperole")
        XCTAssertEqual(AppVariant.shown(stored: "PaperCollab Dev"), "Paperole Dev")
        XCTAssertEqual(AppVariant.shown(stored: "Other App"), "Other App")
        XCTAssertEqual(AppVariant.fileFormat, "Paperole")
        XCTAssertTrue(AppVariant.readsFormat("Paperole"))
        XCTAssertTrue(AppVariant.readsFormat("PaperCollab"))
        for other in [nil, "", "paperole", "Paperole ", "Other", 2] as [Any?] { XCTAssertFalse(AppVariant.readsFormat(other), "\(String(describing: other))") }
        for v in [AppVariant.official, .dev] { XCTAssertEqual(AppVariant(stored: v.oldName), v); XCTAssertEqual(AppVariant(stored: v.name), v) }
    }

    /// The DEV mark: on every icon the dev app shows (Dock, About, alerts), in the bottom-right corner only; never in
    /// the official app, whose icon is shown as it is.
    func testTheDevMarkOnlyInDev() throws {
        let official = AppIconModel(options: LaunchOptions(), defaults: nil, folder: AppIconTests.icons)
        let dev = AppIconModel(options: LaunchOptions(), defaults: nil, folder: AppIconTests.icons, mark: true)
        XCTAssertFalse(official.mark)
        for dark in [false, true] {
            let plain = try XCTUnwrap(official.image(dark: dark))
            XCTAssertTrue(official.shown(dark: dark) === plain, "the official app shows the icon as it is")
            XCTAssertEqual(Self.pixels(try XCTUnwrap(dev.image(dark: dark))), Self.pixels(plain), "the image itself is unmarked")
            let marked = try XCTUnwrap(dev.shown(dark: dark))
            let (corner, rest) = Self.difference(marked, plain)
            XCTAssertGreaterThan(corner, 40, "\(dark): the mark, bottom right")
            XCTAssertEqual(rest, 0, "\(dark): the rest as it is")
        }
        dev.style = .dark
        let about = try XCTUnwrap(dev.aboutOptions[.applicationIcon] as? NSImage)
        XCTAssertGreaterThan(Self.difference(about, try XCTUnwrap(dev.image)).corner, 40, "About: marked")
        XCTAssertEqual(Self.difference(try XCTUnwrap(official.aboutOptions[.applicationIcon] as? NSImage),
                                       try XCTUnwrap(official.image)).corner, 0, "About: as it is")
    }

    /// The dev bundle's own icon, paperole-dev.icns (tools/dev_icon.sh), is Paperole, light, with this drawing's mark.
    func testTheDevBundleIcon() throws {
        let icns = try XCTUnwrap(NSImage(contentsOf: AppIconTests.icons.appendingPathComponent("paperole-dev.icns")))
        XCTAssertEqual(Set(icns.representations.map(\.pixelsWide)), [16, 32, 64, 128, 256, 512, 1024])
        let paperole = try XCTUnwrap(NSImage(contentsOf: AppIconTests.icons.appendingPathComponent("paperole.icns")))
        let a = Self.pixels(icns), b = Self.pixels(DevMark.marked(paperole))
        let mean = Double(zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(a.count)
        XCTAssertLessThan(mean, 2, "made from DevMark: run tools/dev_icon.sh after changing it")
        XCTAssertGreaterThan(Self.difference(icns, paperole).corner, 40)
    }

    /// The engine's environment: its folder first on PYTHONPATH, and with a bundled engine (the official app) no
    /// bytecode written. A bundled engine is found only where the bundle has engine/paperole; Dev, `swift test` and
    /// `swift run` run the checkout's engine folder (this checkout's, from the source file's path), `-m paperole.cli`.
    func testTheEngineEnvironment() throws {
        let base = ["PATH": "/usr/bin", "HOME": "/Users/someone"]
        let plain = EngineClient.environment(base, engine: nil)
        XCTAssertEqual(plain, ["PATH": "/usr/bin", "HOME": "/Users/someone", "PYTHONUNBUFFERED": "1", "PYTHONIOENCODING": "utf-8"])
        XCTAssertEqual(EngineClient.environment(["PYTHONPATH": "/x"], engine: nil)["PYTHONPATH"], "/x", "nothing changed")
        let engine = URL(fileURLWithPath: "/Applications/Paperole.app/Contents/Resources/engine")
        let env = EngineClient.environment(base, engine: engine)
        XCTAssertEqual(env["PYTHONPATH"], engine.path)
        XCTAssertEqual(env["PYTHONDONTWRITEBYTECODE"], "1")
        XCTAssertEqual(env["PYTHONUNBUFFERED"], "1")
        XCTAssertEqual(env["PATH"], "/usr/bin")
        XCTAssertEqual(EngineClient.environment(["PYTHONPATH": "/x:/y"], engine: engine)["PYTHONPATH"], engine.path + ":/x:/y", "first")
        XCTAssertEqual(EngineClient.environment(["PYTHONPATH": ""], engine: engine)["PYTHONPATH"], engine.path)
        let live = EngineClient.environment(["PYTHONPATH": "/x"], engine: engine, frozen: false)
        XCTAssertEqual(live["PYTHONPATH"], engine.path + ":/x")
        XCTAssertNil(live["PYTHONDONTWRITEBYTECODE"], "the checkout's engine writes its __pycache__ as Python does")

        XCTAssertNil(EngineClient.bundledEngine(resources: nil))
        XCTAssertNil(EngineClient.bundledEngine(resources: temp), "no engine folder")
        let folder = temp.appendingPathComponent("engine")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertNil(EngineClient.bundledEngine(resources: temp), "no package in it")
        try Data().write(to: folder.appendingPathComponent("paperole"))
        XCTAssertNil(EngineClient.bundledEngine(resources: temp), "a file, not the package")
        try FileManager.default.removeItem(at: folder.appendingPathComponent("paperole"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("papercollab"), withIntermediateDirectories: true)
        XCTAssertNil(EngineClient.bundledEngine(resources: temp), "the package's old name is no engine")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("paperole"), withIntermediateDirectories: true)
        XCTAssertEqual(EngineClient.bundledEngine(resources: temp)?.standardizedFileURL, folder.standardizedFileURL)
        XCTAssertNil(EngineClient.bundledEngine(), "swift test: the checkout's engine")
        // the checkout's: engine/ beside mac/, from EngineClient.swift's own path, holding the paperole package
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertEqual(EngineClient.checkoutEngine()?.standardizedFileURL, checkout.appendingPathComponent("engine").standardizedFileURL)
        XCTAssertTrue(EngineClient.sourceFile.hasSuffix("/mac/Sources/Paperole/EngineClient.swift"), EngineClient.sourceFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: checkout.appendingPathComponent("engine/paperole/cli.py").path))
        XCTAssertNil(EngineClient.checkoutEngine(source: temp.appendingPathComponent("mac/Sources/Paperole/EngineClient.swift").path),
                     "no engine there")
        // "Engine Python not found" names the running bundle's own defaults domain
        XCTAssertEqual(EngineClient.defaultsDomain, Bundle.main.bundleIdentifier)
        XCTAssertNotEqual(EngineClient.defaultsDomain, AppVariant.officialID)
    }

    /// An export says which app made it (backup.json's `made_by`, DATA.md §3.2): "Paperole Dev" in the dev app, so an
    /// import elsewhere never prefers its papers over real ones; the file's format name ("app": "Paperole") is the
    /// engine's, the same in both.
    func testAnExportSaysWhichAppMadeIt() throws {
        XCTAssertTrue(AppVariant.current.isDev)
        _ = NSApplication.shared
        var o = LaunchOptions()
        o.fixture = ReadingTests.fixtures.appendingPathComponent("state-reading.json").path
        let m = AppModel(options: o)
        XCTAssertEqual(m.data.madeBy["variant"] as? String, "Paperole Dev")
        let install = try XCTUnwrap(m.data.madeBy["install"] as? String)
        XCTAssertTrue(install.hasPrefix("i-"))
        XCTAssertEqual(m.data.madeBy["install"] as? String, install, "one id for the run")
        XCTAssertNil(UserDefaults.standard.string(forKey: "installID").flatMap { $0 == install ? $0 : nil }, "never saved by a test")
    }

    // MARK: Helpers

    static let side = 128

    /// The image drawn at 128 × 128, RGBA, top row first.
    static func pixels(_ image: NSImage) -> [UInt8] {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return Array(UnsafeBufferPointer(start: rep.bitmapData, count: side * side * 4))
    }

    /// The mean difference of two images per channel, in the mark's corner (DevMark: 668–948 × 92–220 of 1024, from
    /// the bottom left) and in the rest of the icon (outside that corner, with a margin).
    static func difference(_ a: NSImage, _ b: NSImage) -> (corner: Double, rest: Double) {
        let x = pixels(a), y = pixels(b)
        var corner = (0.0, 0.0), rest = (0.0, 0.0)
        let k = Double(side) / 1024
        for row in 0..<side {
            let fromBottom = Double(side - row) - 0.5
            for col in 0..<side {
                let cx = Double(col) + 0.5
                let inMark = cx > 668 * k && cx < 948 * k && fromBottom > 92 * k && fromBottom < 220 * k
                let nearMark = cx > 640 * k && fromBottom < 250 * k
                let i = (row * side + col) * 4
                let d = (0..<4).reduce(0.0) { $0 + Double(abs(Int(x[i + $1]) - Int(y[i + $1]))) } / 4
                if inMark { corner = (corner.0 + d, corner.1 + 1) } else if !nearMark { rest = (rest.0 + d, rest.1 + 1) }
            }
        }
        return (corner.0 / corner.1, rest.0 / rest.1)
    }
}
