import AppKit

/// Which app this is (the advisor's decision, 2026-10-21): Paperole, for real reviews (/Applications, installed by
/// release.sh), or Paperole Dev (build/Paperole Dev.app, made by build_app.sh), for agents' tests and the advisor's
/// experiments. Each keeps its own papers list, tags, drafts and thumbnails, in folders named after it, and its own
/// defaults (they follow the bundle id by themselves). Only the bundle id "com.paperole.app" is the official app;
/// anything else is Dev: the dev bundle, `swift test`, `swift run`, a test bundle (APP_OUT), no bundle id at all. So no
/// test, debug run or dev build reads or writes the official data. A test run's own folders (--background, a fixture)
/// stay as they were, on top.
///
/// The app was called PaperCollab until 2026-10-27, and so were its bundle ids, its folders and its files' names for it.
/// The advisor's decision of that day renamed all of them; the app's first real launch under the new name moves its
/// data to the new places (Migration.swift; UX.md §34), and it reads every file the old app wrote.
enum AppVariant: Equatable {
    case official, dev

    static let officialID = "com.paperole.app"
    static let devID = "com.paperole.app.dev"
    /// The bundle ids, and so the defaults domains, until 2026-10-27: the migration copies their settings.
    static let oldOfficialID = "com.papercollab.app"
    static let oldDevID = "com.papercollab.app.dev"

    init(bundleID: String?) { self = bundleID == Self.officialID ? .official : .dev }

    /// This run's, from its bundle.
    static let current = AppVariant(bundleID: Bundle.main.bundleIdentifier)

    var isDev: Bool { self == .dev }
    /// Its bundle id (its defaults domain), and the one it had before the rename.
    var id: String { isDev ? Self.devID : Self.officialID }
    var oldID: String { isDev ? Self.oldDevID : Self.oldOfficialID }
    /// The app's name wherever the app shows it, and what its data goes by: the window's title, menus, alerts, About,
    /// the names of the files and folders it makes or suggests, its folders in Application Support and Caches, and an
    /// export's made_by "variant".
    var name: String { isDev ? "Paperole Dev" : "Paperole" }
    /// Its name before the rename (its old folders' names, an older export's made_by "variant").
    var oldName: String { isDev ? "PaperCollab Dev" : "PaperCollab" }
    /// ~/Library/Application Support/Paperole (or Paperole Dev): papers.json, tags.json, drafts. Until the app's data
    /// was moved there, the old folder (DataHome).
    var dataFolder: URL { DataHome.current(self).support }
    /// ~/Library/Caches/Paperole (or Paperole Dev): the page thumbnails; the old folder until it was moved (DataHome).
    var cachesFolder: URL { DataHome.current(self).caches }

    /// The app an export's made_by "variant" names: its name, or the name it had before the rename; nil for anything
    /// else (none, another app's).
    init?(stored: String?) {
        switch stored {
        case "Paperole", "PaperCollab": self = .official
        case "Paperole Dev", "PaperCollab Dev": self = .dev
        default: return nil
        }
    }

    /// The name to show for a made_by "variant": the app's name, else the text as it is.
    static func shown(stored: String) -> String { AppVariant(stored: stored)?.name ?? stored }

    /// The format's name in every export's backup.json ("app"), the same in Dev (engine archive.FORMAT); the files the
    /// app wrote before the rename say "PaperCollab", and are read as ever (archive.FORMATS).
    static let fileFormat = "Paperole"
    static func readsFormat(_ app: Any?) -> Bool { [fileFormat, "PaperCollab"].contains(app as? String ?? "") }

    /// Settings › General's footnote, in the dev app only.
    static let devNote = "This is Paperole Dev, for testing. Its papers, tags and settings are separate from Paperole."
}
