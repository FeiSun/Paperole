import AppKit
import SwiftUI

/// The app's icon (UX.md §26, §34; design/brand/paperole): Paperole, light and dark, the only one since the advisor's
/// decision of 2026-10-27. The Round and The Round ¶ (chosen in Settings › Appearance from 2026-10-20) are kept in
/// design/logo as the icon's history, not in the app. paperole.icns and paperole-dark.icns are in mac/Resources/AppIcons,
/// copied into the bundle by build_app.sh; the bundle's own icon (CFBundleIconFile) is the light one, so Finder,
/// Spotlight and the Dock before launch show it (Paperole Dev's: paperole-dev.icns, with the DEV mark). macOS 14–15 give
/// an app one Finder icon whatever the appearance, so Finder always shows the light one. Settings › General chooses
/// the style.
enum AppIcon {
    /// Its .icns in the app's resources: paperole, paperole-dark.
    static func resource(dark: Bool) -> String { dark ? "paperole-dark" : "paperole" }
    /// The credit Paperole's traced handwriting needs wherever it is shipped, word for word as
    /// design/brand/paperole/hand/SOURCE.md gives it: in the About window.
    static let credit =
        "Handwriting: Marcel Proust (public domain); traced from a photo by Warburg, Wikimedia Commons, CC BY-SA 3.0"
    /// The photo's page on Wikimedia Commons, linked from the credit.
    static let creditSource = URL(string: "https://commons.wikimedia.org/wiki/File:Autographe_Proust_longtemps.JPG")!
}

/// The icon's style: Automatic follows the system's appearance, light or dark.
enum AppIconStyle: String, CaseIterable, Identifiable {
    case automatic, light, dark

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    func dark(system: Bool) -> Bool { self == .automatic ? system : self == .dark }
}

/// Shows the icon in its style wherever the app shows its icon, at launch and whenever the style or, in Automatic, the
/// system's appearance changes: the Dock and the App Switcher while the app runs (`NSApp.applicationIconImage`), the
/// About window (its icon given, and the icon's credit), and alerts, SwiftUI's too, which AppKit draws with the image named
/// NSApplicationIcon, the bundle's icon, which `applicationIconImage` does not change; that name gives the icon shown
/// from launch (`start`). In Paperole Dev all of these show the icon with its DEV mark (`mark`; DevMark.swift). The
/// style is kept in the app's defaults (`appIconStyle`; each app its own); a test run (--background, a fixture,
/// swift test, --icon-style, anything but the app's own bundles) reads and saves it never.
@MainActor
final class AppIconModel: ObservableObject {
    static let styleKey = "appIconStyle"
    /// Settings › General's words for it.
    static let title = "App icon"
    static let detail = "Automatic follows the system’s light or dark appearance."

    /// The app's, from its launch arguments and bundle.
    static let shared = make(options: LaunchOptions.parse(CommandLine.arguments), background: LaunchOptions.background,
                             bundle: .main)

    /// A real run of the app: no test flag, and the app's own bundle, Paperole's or Paperole Dev's (not
    /// `swift run`, nor the test runner).
    static func isRealRun(_ o: LaunchOptions, background: Bool, bundle: Bundle) -> Bool {
        !background && o.fixture == nil && o.iconStyle == nil
            && [AppVariant.officialID, AppVariant.devID].contains(bundle.bundleIdentifier ?? "")
            && bundle.bundleURL.pathExtension == "app"
    }

    static func make(options: LaunchOptions, background: Bool, bundle: Bundle) -> AppIconModel {
        AppIconModel(options: options, defaults: isRealRun(options, background: background, bundle: bundle) ? .standard : nil,
                     folder: bundle.resourceURL, mark: AppVariant(bundleID: bundle.bundleIdentifier).isDev)
    }

    @Published var style: AppIconStyle { didSet { if style != oldValue { changed() } } }
    /// The system's appearance is dark (NSApp.effectiveAppearance: a test run's --appearance too).
    @Published private(set) var systemDark = false

    /// nil in a test run: nothing read or saved.
    private let defaults: UserDefaults?
    /// Where the .icns are (the bundle's resources).
    private let folder: URL?
    /// Paperole Dev: the icon shown carries the DEV mark.
    let mark: Bool
    private var images: [String: NSImage] = [:]
    private var watcher: NSKeyValueObservation?
    private(set) var started = false

    init(options: LaunchOptions, defaults: UserDefaults?, folder: URL?, mark: Bool = false) {
        self.defaults = defaults
        self.folder = folder
        self.mark = mark
        style = options.iconStyle ?? defaults?.string(forKey: Self.styleKey).flatMap(AppIconStyle.init(rawValue:)) ?? .automatic
    }

    var remembers: Bool { defaults != nil }
    var dark: Bool { style.dark(system: systemDark) }
    /// The .icns shown now.
    var resource: String { AppIcon.resource(dark: dark) }
    /// The icon in the style in effect; nil without the app's resources (`swift run`, `swift test`).
    var image: NSImage? { image(dark: dark) }
    /// The image shown now: with the DEV mark in Paperole Dev.
    var shown: NSImage? { shown(dark: dark) }

    func image(dark: Bool) -> NSImage? {
        let name = AppIcon.resource(dark: dark)
        if let i = images[name] { return i }
        guard let url = folder?.appendingPathComponent(name + ".icns"), let i = NSImage(contentsOf: url) else { return nil }
        images[name] = i
        return i
    }

    /// The icon as the app shows it: in Paperole Dev with the DEV mark.
    func shown(dark: Bool) -> NSImage? {
        guard mark else { return image(dark: dark) }
        let name = AppIcon.resource(dark: dark) + " DEV"
        if let i = images[name] { return i }
        guard let i = image(dark: dark).map(DevMark.marked) else { return nil }
        images[name] = i
        return i
    }

    /// At launch (AppDelegate): the icon in the Dock, the About window and alerts, following the system's appearance
    /// from now on.
    func start() {
        guard !started else { return }
        started = true
        NamedIcon.install()
        systemDark = Self.isDark(NSApp.effectiveAppearance)
        watcher = NSApp.observe(\.effectiveAppearance) { [weak self] app, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.systemAppearance(dark: Self.isDark(app.effectiveAppearance)) }
            }
        }
        apply()
    }

    /// The system's appearance changed (also for tests).
    func systemAppearance(dark: Bool) {
        guard dark != systemDark else { return }
        systemDark = dark
        if style == .automatic { apply() }
    }

    /// The About window's options: its icon, the one shown now (a copy: the panel may size it), and the credits, the
    /// icon's credit in small grey type, "Wikimedia Commons" linked to the photo.
    var aboutOptions: [NSApplication.AboutPanelOptionKey: Any] {
        var o: [NSApplication.AboutPanelOptionKey: Any] = [.credits: Self.credits]
        if let i = shown { o[.applicationIcon] = i.copy() }
        return o
    }

    static var credits: NSAttributedString {
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        let text = NSMutableAttributedString(string: AppIcon.credit, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: centred,
        ])
        let commons = (AppIcon.credit as NSString).range(of: "Wikimedia Commons")
        text.addAttribute(.link, value: AppIcon.creditSource, range: commons)
        return text
    }

    private func changed() {
        defaults?.set(style.rawValue, forKey: Self.styleKey)
        apply()
    }

    private func apply() {
        guard started else { return }
        let i = shown
        NSApp.applicationIconImage = i
        NamedIcon.image = i
    }

    private static func isDark(_ a: NSAppearance) -> Bool { a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

/// The image named NSApplicationIcon, which AppKit's alerts draw (and the About window without its option): the
/// icon shown once set, the bundle's before. `NSImage(named:)` is replaced for that one name only.
enum NamedIcon {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: NSImage?
    nonisolated(unsafe) private static var installed = false

    /// A copy, so whatever AppKit does with it leaves the model's image as it was.
    static var image: NSImage? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue?.copy() as? NSImage } }
    }

    static func install() {
        guard !installed, let m = class_getClassMethod(NSImage.self, #selector(NSImage.init(named:))) else { return }
        installed = true
        typealias Named = @convention(c) (AnyClass, Selector, NSString?) -> NSImage?
        let original = unsafeBitCast(method_getImplementation(m), to: Named.self)
        let named: @convention(block) (AnyClass, NSString?) -> NSImage? = { cls, name in
            if name as String? == NSImage.applicationIconName, let i = image { return i }
            return original(cls, #selector(NSImage.init(named:)), name)
        }
        method_setImplementation(m, imp_implementationWithBlock(named))
    }
}
