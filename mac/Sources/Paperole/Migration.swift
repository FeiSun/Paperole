import AppKit
import CryptoKit
import Darwin

// The app was PaperCollab until the advisor's decision of 2026-10-27 renamed everything, its data's places and its
// settings' domain too (UX.md §34). Its first real launch under the new name moves its data there, once: the folder
// in Application Support and the one in Caches, Paperole Dev's default review folder (~/PaperCollab Dev Reviews), and
// the settings, from the old bundle id's defaults. Every step is a rename on the same disk or a rewrite of a file it
// copied first; any step that fails puts back what was done, and the app runs on the old places. A test run, any
// bundle but the two installed ones, and `swift test` never do any of it (`gate`).

// MARK: Where the data is

/// Where an app's data is: its folders in Application Support and Caches by its name, or by its old name while the data
/// is still there (not moved yet, the move skipped or put back), and where new review folders go when none is chosen.
/// Worked out once per run, after the migration (App.init), from what is on the disk; a test run's are the new names,
/// and it never looks at the disk for them.
struct DataHome: Equatable {
    var support: URL
    var caches: URL
    /// ~/Reviews; Paperole Dev's own: ~/Paperole Dev Reviews, or ~/PaperCollab Dev Reviews while its reviews are there.
    var reviews: URL
    /// Both data folders are there and the migration did not make the new one: the old one is used, nothing is moved
    /// or merged (the advisor is told: Migration).
    var both = false

    /// Where the places are: this Mac's (`standard`), or a test's temporary folder.
    struct Roots: Equatable {
        var support: URL
        var caches: URL
        var home: URL

        static var standard: Roots {
            let fm = FileManager.default
            return Roots(support: fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
                         caches: fm.urls(for: .cachesDirectory, in: .userDomainMask)[0], home: fm.homeDirectoryForCurrentUser)
        }
    }

    /// From what is there: a folder of the new name, else one of the old, else the new name (made when first written).
    /// Both data folders and no finished migration in the new one: the old one, which holds the data the app had.
    static func resolve(_ v: AppVariant, roots r: Roots, fs: MigrationFS) -> DataHome {
        let oldS = v.support(r, old: true), newS = v.support(r, old: false)
        let marker = Migration.marker(newS, fs: fs)
        var home = DataHome(support: newS, caches: v.caches(r, old: false), reviews: v.reviews(r, old: false))
        if fs.kind(newS) != .none {
            if fs.kind(oldS) != .none && marker == nil {
                home.support = oldS
                home.both = true
            }
        } else if fs.kind(oldS) != .none {
            home.support = oldS
        }
        if fs.kind(home.caches) == .none && fs.kind(v.caches(r, old: true)) != .none { home.caches = v.caches(r, old: true) }
        if v.isDev && marker?.reviews == nil && fs.kind(v.reviews(r, old: true)) != .none { home.reviews = v.reviews(r, old: true) }
        return home
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var known: [AppVariant: DataHome] = [:]

    /// This run's, worked out at the first use: the disk in a real run (after the migration), the new names in a test
    /// run.
    static func current(_ v: AppVariant) -> DataHome {
        lock.withLock {
            if let h = known[v] { return h }
            let h = resolve(v, roots: .standard, fs: LaunchOptions.isTestRun ? .nothing : .disk)
            known[v] = h
            return h
        }
    }
}

extension AppVariant {
    /// Its folder in Application Support, by its name or its old one.
    func support(_ r: DataHome.Roots, old: Bool) -> URL { r.support.appendingPathComponent(old ? oldName : name) }
    func caches(_ r: DataHome.Roots, old: Bool) -> URL { r.caches.appendingPathComponent(old ? oldName : name) }
    /// Where its new review folders go by default: ~/Reviews (by either name); Paperole Dev's, by its name.
    func reviews(_ r: DataHome.Roots, old: Bool) -> URL {
        r.home.appendingPathComponent(isDev ? (old ? "PaperCollab Dev Reviews" : "Paperole Dev Reviews") : "Reviews")
    }
}

// MARK: What the migration does to files and settings

/// The file operations the migration uses, and only these: the disk's (`disk`), a test's (temporary folders, faults),
/// or none at all (`nothing`: every place empty).
struct MigrationFS {
    enum Kind: Equatable { case none, folder, link, file }

    /// A rename that fails when anything is at the destination, or the destination is on another disk (never a copy).
    var renameExclusive: (URL, URL) throws -> Void
    /// A file written whole: a temporary file beside it, renamed over it.
    var write: (Data, URL) throws -> Void
    var read: (URL) throws -> Data
    /// A new folder; fails when anything is there.
    var makeFolder: (URL) throws -> Void
    /// A folder's entries; none when it cannot be read.
    var list: (URL) -> [URL]
    /// What is there, the link itself for a link.
    var kind: (URL) -> Kind
    /// The disk it is on (lstat's st_dev); nil when nothing is there.
    var device: (URL) -> Int?

    static let disk = MigrationFS(
        renameExclusive: { from, to in
            guard renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) == 0 else { throw MigrationFS.posix(errno, from, to) }
        },
        write: { data, url in try data.write(to: url, options: .atomic) },
        read: { try Data(contentsOf: $0) },
        makeFolder: { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: false) },
        list: { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] },
        kind: { url in
            var st = stat()
            guard lstat(url.path, &st) == 0 else { return .none }
            switch st.st_mode & S_IFMT {
            case S_IFDIR: return .folder
            case S_IFLNK: return .link
            default: return .file
            }
        },
        device: { url in
            var st = stat()
            return lstat(url.path, &st) == 0 ? Int(st.st_dev) : nil
        })

    /// Nothing anywhere, and nothing can be done: a test run's DataHome.
    static let nothing = MigrationFS(
        renameExclusive: { _, _ in throw MigrationFS.posix(EPERM, nil, nil) }, write: { _, _ in throw MigrationFS.posix(EPERM, nil, nil) },
        read: { _ in throw MigrationFS.posix(ENOENT, nil, nil) }, makeFolder: { _ in throw MigrationFS.posix(EPERM, nil, nil) },
        list: { _ in [] }, kind: { _ in .none }, device: { _ in nil })

    static func posix(_ code: Int32, _ from: URL?, _ to: URL?) -> Error {
        let what = [from, to].compactMap { $0.map { DataFiles.shown($0) } }.joined(separator: " → ")
        return DataFailure(message: (what.isEmpty ? "" : what + ": ") + String(cString: strerror(code)))
    }
}

/// An app's defaults domain read and written whole: the system's (`system`), or a test's in memory.
struct DefaultsIO {
    var read: (String) -> [String: Any]?
    var write: (String, [String: Any]) throws -> Void
    var remove: (String) throws -> Void

    static let system = DefaultsIO(
        read: { UserDefaults.standard.persistentDomain(forName: $0) },
        write: { domain, values in
            UserDefaults.standard.setPersistentDomain(values, forName: domain)
            guard CFPreferencesAppSynchronize(domain as CFString) else {
                throw DataFailure(message: "the settings of \(domain) could not be saved")
            }
        },
        remove: { domain in
            UserDefaults.standard.removePersistentDomain(forName: domain)
            guard CFPreferencesAppSynchronize(domain as CFString) else {
                throw DataFailure(message: "the settings of \(domain) could not be removed")
            }
        })
}

// MARK: The migration

enum Migration {
    /// In the data folder: the journal while the migration runs, and once it is done the marker (state "done").
    static let journalName = "migration.json"
    static let logName = "migration.log"
    /// The copies made before anything changes: pre-paperole-20261027-101500/, in the data folder.
    static let prePrefix = "pre-paperole-"
    /// The new domain's note that its settings were copied from the old one.
    static let markerKey = "migratedFrom"
    /// The app's own settings (not AppKit's), as AppModel, AppIconModel, BackupModel, DataModel, TagModel, LastPlace,
    /// ListGrouping and EngineClient name them (MigrationTests checks them): what the new domain holds of them already is
    /// kept over the old domain's, except the installation identity, which follows the old data and its backups.
    static let appKeys: Set<String> = [
        "appIcon", "appIconStyle", "overviewMapAsTable", "markColor", "markKind", "tipAnswerSeen", "foldedStudents",
        "readingMarks", "foldAppendix", "openAtLaunch", "showChangedWords", "commentGrouping", "backups",
        "reviewFolderRoot", "installID", "enginePython", "lastPlace", "suggestTags", markerKey,
    ]
    /// Settings left behind: the icon chosen among three (only Paperole's is left; UX.md §34).
    static let droppedKeys: Set<String> = ["appIcon"]
    /// The two bundles that ever migrate (never a test bundle, a worktree's or another copy): /Applications', and the
    /// dev build of the checkout this app was built from (EngineClient.checkoutRoot), only when that is the main
    /// checkout, not a linked worktree (whose .git is a file).
    static let officialBundle = URL(fileURLWithPath: "/Applications/Paperole.app")
    static let devBundle = EngineClient.checkoutRoot.appendingPathComponent("mac/build/Paperole Dev.app")
    static let mainCheckout: Bool = {
        var folder: ObjCBool = false
        let git = EngineClient.checkoutRoot.appendingPathComponent(".git").path
        return FileManager.default.fileExists(atPath: git, isDirectory: &folder) && folder.boolValue
    }()

    /// What the migration did or left, in its journal (migration.json, written whole after each step).
    struct Journal: Codable, Equatable {
        /// running, done, rolled_back, both
        var state: String
        var app: String
        /// The data folder's old and new places.
        var from: String
        var to: String
        /// The review folder's, when it moves.
        var reviews: [String]?
        /// The copies' folder (its name, in the data folder).
        var pre: String?
        /// papers.json rewritten.
        var papers = false
        /// The drafts' files renamed and rewritten: [old name, new name].
        var drafts: [[String]] = []
        /// The files the migration writes, by their names in the data folder (papers.json, drafts/<new name>): the
        /// SHA-256 of what it writes. Recovery of a partial move stops if another writer has changed a file.
        var wrote: [String: String]?
        /// The settings copied into the new domain.
        var defaults = false
        /// The steps begun, in order: support, reviews, papers, drafts, defaults.
        var steps: [String] = []
        var at: String
        var version: String?
        var problem: String?
    }

    enum Outcome: Equatable {
        /// Nothing to move: no old data, or moved before.
        case nothing
        case moved(reviews: Bool, defaults: Bool)
        /// Both data folders and no marker: nothing moved; `first`: the first launch to find them so (the advisor is told).
        case both(first: Bool)
        /// Not moved, and why (a link, another disk, the copies could not be made).
        case skipped(String)
        /// A step failed; everything was put back.
        case rolledBack(String)
        /// Putting back failed, or its journal could not say it was done: the app must not run.
        case stuck(String)
    }

    struct Context {
        var variant: AppVariant
        var roots: DataHome.Roots
        var fs: MigrationFS
        var defaults: DefaultsIO
        var now: () -> Date = Date.init
        var version: String?
        /// Each step, as written to migration.log (with paths); NSLog gets step names and counts only.
        var log: (String) -> Void = { _ in }
    }

    // MARK: The gate

    /// The variant to migrate, only at a real launch of one of the two installed bundles: the exact bundle id, the exact
    /// place (links resolved), no launch argument (a `-psn_…` from the system aside), not a test run, not `swift test`.
    static func gate(bundleID: String?, bundleURL: URL, arguments: [String], unitTest: Bool, testRun: Bool,
                     mainCheckout: Bool = mainCheckout) -> AppVariant? {
        guard !unitTest, !testRun, arguments.dropFirst().allSatisfy({ $0.hasPrefix("-psn_") }) else { return nil }
        let v: AppVariant
        switch bundleID {
        case AppVariant.officialID: v = .official
        case AppVariant.devID: v = .dev
        default: return nil
        }
        if v.isDev && !mainCheckout { return nil }
        let canonical = (v.isDev ? devBundle : officialBundle).standardizedFileURL.resolvingSymlinksInPath().path
        return bundleURL.standardizedFileURL.resolvingSymlinksInPath().path == canonical ? v : nil
    }

    /// A running app as the check sees it.
    struct Running {
        var pid: pid_t
        var id: String?
        var executable: String?
        var name: String?
    }

    /// The other running instances of the same app, by its new id or its old (the old PaperCollab Dev, an agent's test
    /// bundle) and, for Paperole Dev, `swift run` (no bundle id): their names. Nothing is moved under a running app.
    static func others(_ v: AppVariant, in apps: [Running], me: pid_t) -> [String] {
        apps.filter { a in
            a.pid != me && ([v.id, v.oldID].contains(a.id ?? "")
                || (v.isDev && a.id == nil && ["Paperole", "PaperCollab"].contains(a.executable ?? "")))
        }.map { $0.name ?? $0.executable ?? "another copy of \(v.name)" }
    }

    // MARK: At launch

    /// A notice for the advisor once the app has launched (AppDelegate): the move was put back, or both folders found.
    nonisolated(unsafe) static var notice: (title: String, detail: String)?

    /// At the start of App.init, before anything reads the app's data or settings.
    static func atLaunch() {
        guard let v = gate(bundleID: Bundle.main.bundleIdentifier, bundleURL: Bundle.main.bundleURL, arguments: CommandLine.arguments,
                           unitTest: LaunchOptions.unitTest, testRun: LaunchOptions.isTestRun) else { return }
        let apps = NSWorkspace.shared.runningApplications.map {
            Running(pid: $0.processIdentifier, id: $0.bundleIdentifier, executable: $0.executableURL?.lastPathComponent, name: $0.localizedName)
        }
        if let other = others(v, in: apps, me: getpid()).first {
            stop("Quit \(other) first, then open \(v.name) again.",
                 "\(v.name) moves its data to its new name when it first opens, and never while another copy of it runs.")
        }
        let roots = DataHome.Roots.standard
        // the data folder in use locked while the migration runs: a second copy opened at the same moment waits out
        let held = [v.support(roots, old: true), v.support(roots, old: false)].first { MigrationFS.disk.kind($0) == .folder }
        var fd: Int32 = -1
        if let held {
            fd = open(held.path, O_RDONLY)
            if fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) != 0 {
                stop("Another copy of \(v.name) is opening.", "Quit it, then open \(v.name) again.")
            }
        }
        defer { if fd >= 0 { close(fd) } }
        let info = Bundle.main.infoDictionary
        let version = [info?["CFBundleShortVersionString"] as? String, info?["CFBundleVersion"] as? String].compactMap { $0 }
            .joined(separator: " ")
        let outcome = run(Context(variant: v, roots: roots, fs: .disk, defaults: .system, version: version))
        switch outcome {
        case .stuck(let why):
            let places = [v.support(roots, old: true), v.support(roots, old: false)]
                + (v.isDev ? [v.reviews(roots, old: true), v.reviews(roots, old: false)] : [])
            stop("\(v.name) could not finish moving its data to its new name.",
                 "Nothing was deleted. Your data is in these places: " + places.map { DataFiles.shown($0) }.joined(separator: ", ")
                    + ". \(v.name) will not open until this is sorted out. Details: \(why)")
        case .rolledBack(let why):
            notice = ("\(v.name) could not move its data to its new name and put everything back.",
                      "Nothing was lost; it uses the places it used before. Details: \(why)")
        case .both(true):
            let r = DataHome.resolve(v, roots: roots, fs: .disk)
            notice = ("Found both \(DataFiles.shown(v.support(roots, old: true))) and \(DataFiles.shown(v.support(roots, old: false))).",
                      "Nothing was moved or merged; \(v.name) uses \(DataFiles.shown(r.support)).")
        default:
            break
        }
        if let old = fallback(outcome, old: DefaultsIO.system.read(v.oldID)) { UserDefaults.standard.register(defaults: old) }
    }

    /// The settings the app reads where its own domain has none while its data is still at the old places (the move put
    /// back, not made, or both folders there): the old domain's, less what is dropped. Registered, so never written;
    /// the next move copies them. nil once the data has moved, or with nothing to read.
    static func fallback(_ outcome: Outcome, old: [String: Any]?) -> [String: Any]? {
        switch outcome {
        case .rolledBack, .skipped, .both:
            guard let old, !old.isEmpty else { return nil }
            return old.filter { !droppedKeys.contains($0.key) }
        default:
            return nil
        }
    }

    /// An alert, then the app quits, before it has read anything.
    private static func stop(_ title: String, _ detail: String) -> Never {
        NSLog("Paperole: migration stopped the launch: %@", title)
        NSApplication.shared.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        exit(1)
    }

    // MARK: The work

    /// The journal in a data folder that says the migration is done there (the marker), else nil.
    static func marker(_ folder: URL, fs: MigrationFS) -> Journal? {
        journal(folder, fs: fs).flatMap { $0.state == "done" ? $0 : nil }
    }

    static func journal(_ folder: URL, fs: MigrationFS) -> Journal? {
        (try? fs.read(folder.appendingPathComponent(journalName))).flatMap { try? JSONDecoder().decode(Journal.self, from: $0) }
    }

    /// The migration, start to end: an earlier one cut off put back first, then the plan, the copies, the steps.
    static func run(_ c: Context) -> Outcome {
        let fs = c.fs, v = c.variant
        let oldS = v.support(c.roots, old: true), newS = v.support(c.roots, old: false)
        var lines: [String] = []
        func log(_ s: String) {
            lines.append(stamp(c.now(), iso: true) + " " + s)
            c.log(s)
        }
        // one cut off (the app was killed midway): put back as its journal says, then again from the start
        for folder in [newS, oldS] {
            guard var j = journal(folder, fs: fs), j.state == "running" else { continue }
            log("found a migration cut off midway (\(j.steps.joined(separator: ", "))); putting back what it did")
            NSLog("Paperole: migration: putting back one cut off midway")
            if let failed = rollback(&j, c, log) {
                flush(lines, c, prefer: [oldS, newS])
                return .stuck(failed)
            }
        }
        // (what was put back above, if anything, is logged whatever comes next)
        if marker(newS, fs: fs) != nil {
            flush(lines, c, prefer: [newS])
            return .nothing
        }
        switch fs.kind(oldS) {
        case .none:
            flush(lines, c, prefer: [newS])
            return .nothing
        case .folder: break
        case .link, .file:
            log("not moved: \(oldS.path) is not a folder")
            flush(lines, c, prefer: [newS])
            return .skipped("\(DataFiles.shown(oldS)) is not a folder")
        }
        if fs.kind(newS) != .none {
            let first = journal(oldS, fs: fs)?.state != "both"
            if first {
                log("not moved: both \(oldS.path) and \(newS.path) are there; using the old one")
                NSLog("Paperole: migration: both data folders are there; nothing moved")
                let j = Journal(state: "both", app: v.name, from: oldS.path, to: newS.path, at: stamp(c.now(), iso: true))
                try? fs.write(encode(j), oldS.appendingPathComponent(journalName))
            }
            flush(lines, c, prefer: [oldS])
            return .both(first: first)
        }
        guard let d = fs.device(oldS), d == fs.device(c.roots.support) else {
            log("not moved: \(oldS.path) is on another disk than \(c.roots.support.path)")
            flush(lines, c, prefer: [oldS])
            return .skipped("\(DataFiles.shown(oldS)) is on another disk")
        }
        var plan = makePlan(c, log)
        do {
            try prepare(&plan, c, log)
        } catch {
            log("not moved: the copies could not be made: \(error.localizedDescription)")
            NSLog("Paperole: migration: not moved (the copies could not be made)")
            flush(lines, c, prefer: [oldS], pre: plan.journal.pre)
            return .skipped(error.localizedDescription)
        }
        do {
            try commit(&plan, c, log)
        } catch {
            plan.journal.problem = error.localizedDescription
            log("step \(plan.journal.steps.last ?? "?") failed: \(error.localizedDescription); putting everything back")
            NSLog("Paperole: migration: step %@ failed; putting back", plan.journal.steps.last ?? "?")
            if let failed = rollback(&plan.journal, c, log) {
                flush(lines, c, prefer: [oldS, newS], pre: plan.journal.pre)
                return .stuck(failed)
            }
            flush(lines, c, prefer: [oldS], pre: plan.journal.pre)
            return .rolledBack(error.localizedDescription)
        }
        // the thumbnails, best effort: a fresh cache otherwise
        let oldC = v.caches(c.roots, old: true), newC = v.caches(c.roots, old: false)
        if fs.kind(oldC) == .folder && fs.kind(newC) == .none {
            do {
                try fs.renameExclusive(oldC, newC)
                log("moved \(oldC.path) to \(newC.path)")
            } catch {
                log("left \(oldC.path) (\(error.localizedDescription)); the thumbnails are drawn again")
            }
        }
        log("done")
        NSLog("Paperole: migration done: papers rewritten %ld, drafts %ld, settings %@", plan.rewritten, plan.journal.drafts.count,
              plan.journal.defaults ? "copied" : "not copied")
        flush(lines, c, prefer: [newS], pre: plan.journal.pre)
        return .moved(reviews: plan.journal.reviews != nil, defaults: plan.journal.defaults)
    }

    /// What will be done, worked out before anything changes.
    struct Plan {
        var journal: Journal
        var papersData: Data?
        /// The rewritten drafts, by their new file name.
        var draftsData: [String: Data] = [:]
        var papersCount = 0
        var rewritten = 0
        /// Every listed paper whose folder is there now, at its place after the move (rewritten or not): there after
        /// the move too.
        var mustExist: [String] = []
        var defaults: [String: Any]?
        var oldDomain: [String: Any] = [:]
        var newDomain: [String: Any]?
    }

    private static func makePlan(_ c: Context, _ log: (String) -> Void) -> Plan {
        let fs = c.fs, v = c.variant
        let oldS = v.support(c.roots, old: true), newS = v.support(c.roots, old: false)
        var plan = Plan(journal: Journal(state: "running", app: v.name, from: oldS.path, to: newS.path, at: stamp(c.now(), iso: true),
                                         version: c.version))
        // Paperole Dev's review folder, when it can move whole and its paths can be rewritten
        if v.isDev {
            let oldR = v.reviews(c.roots, old: true), newR = v.reviews(c.roots, old: false)
            let from = oldR.standardizedFileURL.path, to = newR.standardizedFileURL.path
            var why: String?
            var papers: Data?, drafts: [(String, String, Data)] = [], count = 0, rewritten = 0, mustExist: [String] = []
            if fs.kind(oldR) == .none {
                why = ""
            } else if fs.kind(oldR) != .folder {
                why = "\(oldR.path) is not a folder"
            } else if fs.kind(newR) != .none {
                why = "\(newR.path) is there already"
            } else if fs.device(oldR) == nil || fs.device(oldR) != fs.device(c.roots.home) {
                why = "\(oldR.path) is on another disk than \(c.roots.home.path)"
            }
            let list = oldS.appendingPathComponent("papers.json")
            // the review folder as the disk has it (links resolved; any case): a listed paper in it by another path
            // (a link to it, other letter case) would be lost by the move, so the folder is not moved
            let real = oldR.resolvingSymlinksInPath().path.lowercased()
            if why == nil, fs.kind(list) != .none {
                // a regular file only: a link's target is not copied first, so it could not be put back (stuck)
                if fs.kind(list) == .file, let data = try? fs.read(list), let entries = (try? JSONSerialization.jsonObject(with: data)) as? [Any],
                   (try? JSONDecoder().decode([PaperRef].self, from: data)) != nil {
                    count = entries.count
                    let changed: [Any] = entries.map { e in
                        guard var d = e as? [String: Any], let p = d["path"] as? String else { return e }
                        let there = fs.kind(URL(fileURLWithPath: p)) != .none
                        guard let n = moved(p, from: from, to: to) else {
                            if there {
                                mustExist.append(p)
                                let r = URL(fileURLWithPath: p).resolvingSymlinksInPath().path.lowercased()
                                if r == real || r.hasPrefix(real + "/") { why = "\(p) is in it by another path" }
                            }
                            return e
                        }
                        d["path"] = n
                        rewritten += 1
                        if there { mustExist.append(n) }
                        return d
                    }
                    if rewritten > 0 {
                        papers = try? JSONSerialization.data(withJSONObject: changed, options: [.prettyPrinted, .withoutEscapingSlashes])
                        if papers == nil { why = "papers.json could not be written again" }
                    }
                } else {
                    why = "papers.json could not be read (it is left for the app to set aside)"
                }
            }
            if why == nil {
                let folder = oldS.appendingPathComponent("drafts")
                let store = DraftStore(directory: folder)
                for f in fs.list(folder).sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
                where f.pathExtension == "json" && fs.kind(f) == .file {
                    guard let data = try? fs.read(f), var d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                          let p = d["paper"] as? String else {
                        log("draft \(f.lastPathComponent) could not be read: left as it is")
                        continue
                    }
                    guard let n = moved(p, from: from, to: to) else { continue }
                    // only the file the app reads for the paper (its path's hash): a stray copy, never read, is left
                    // (two files for one paper would also be renamed to one name)
                    guard f.lastPathComponent == store.url(paper: p).lastPathComponent else {
                        log("draft \(f.lastPathComponent) is not the file of its paper: left as it is")
                        continue
                    }
                    let name = store.url(paper: n).lastPathComponent
                    d["paper"] = n
                    guard name != f.lastPathComponent, fs.kind(folder.appendingPathComponent(name)) == .none,
                          let out = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                    else {
                        why = "the draft for \(n) is in the way (\(name))"
                        break
                    }
                    drafts.append((f.lastPathComponent, name, out))
                }
            }
            if let why {
                if !why.isEmpty { log("the review folder is not moved: \(why)") }
            } else {
                plan.journal.reviews = [from, to]
                plan.papersData = papers
                plan.papersCount = count
                plan.rewritten = rewritten
                plan.mustExist = mustExist
                plan.journal.drafts = drafts.map { [$0.0, $0.1] }
                plan.draftsData = Dictionary(uniqueKeysWithValues: drafts.map { ($0.1, $0.2) })
                var wrote = Dictionary(uniqueKeysWithValues: drafts.map { ("drafts/" + $0.1, digest($0.2)) })
                if let papers { wrote["papers.json"] = digest(papers) }
                plan.journal.wrote = wrote.isEmpty ? nil : wrote
            }
        }
        // the settings, copied once (the marker): the old domain's under what the new one holds of the app's own (a run
        // of this app while its data was at the old places, or the advisor by hand), AppKit's there (an agent's test run)
        // giving way to the advisor's; every path into the moved review folder rewritten, whichever domain it is from
        let old = c.defaults.read(v.oldID) ?? [:], new = c.defaults.read(v.id)
        plan.oldDomain = old
        plan.newDomain = new
        if old.isEmpty {
            log("no settings under \(v.oldID) to copy")
        } else if new?[markerKey] != nil {
            log("settings not copied: \(v.id) has them already")
        } else {
            var merged = (new ?? [:]).filter { !droppedKeys.contains($0.key) }
            let kept = old.keys.filter { appKeys.contains($0) && $0 != "installID" && merged[$0] != nil }
            for (k, value) in old where !droppedKeys.contains(k) && !kept.contains(k) { merged[k] = value }
            if let r = plan.journal.reviews { merged = merged.mapValues { rewrite($0, from: r[0], to: r[1]) } }
            merged[markerKey] = ["id": v.oldID, "at": stamp(c.now(), iso: true)]
            plan.defaults = merged
            if !kept.isEmpty { log("settings: \(v.id)'s own \(kept.sorted().joined(separator: ", ")) kept over \(v.oldID)'s") }
        }
        return plan
    }

    /// The copies of everything that will be rewritten, in a new folder in the old data folder, and the journal.
    private static func prepare(_ plan: inout Plan, _ c: Context, _ log: (String) -> Void) throws {
        let fs = c.fs, v = c.variant
        let oldS = v.support(c.roots, old: true)
        // a new folder, never one there already (an earlier attempt's, in the same second)
        var name = prePrefix + stamp(c.now(), iso: false), n = 2
        while fs.kind(oldS.appendingPathComponent(name)) != .none {
            name = prePrefix + stamp(c.now(), iso: false) + "-\(n)"
            n += 1
        }
        let pre = oldS.appendingPathComponent(name)
        try fs.makeFolder(pre)
        plan.journal.pre = name
        let list = oldS.appendingPathComponent("papers.json")
        if fs.kind(list) == .file { try fs.write(fs.read(list), pre.appendingPathComponent("papers.json")) }
        if !plan.journal.drafts.isEmpty {
            try fs.makeFolder(pre.appendingPathComponent("drafts"))
            for d in plan.journal.drafts {
                try fs.write(fs.read(oldS.appendingPathComponent("drafts/" + d[0])), pre.appendingPathComponent("drafts/" + d[0]))
            }
        }
        try fs.write(plist(plan.oldDomain), pre.appendingPathComponent("defaults-\(v.oldID).plist"))
        try fs.write(plist(plan.newDomain ?? [:]), pre.appendingPathComponent("defaults-\(v.id).plist"))
        try fs.write(encode(plan.journal), oldS.appendingPathComponent(journalName))
        log("copies made in \(pre.path): papers.json, \(plan.journal.drafts.count) drafts, both settings domains")
    }

    /// The steps, each recorded in the journal before it is done.
    private static func commit(_ plan: inout Plan, _ c: Context, _ log: (String) -> Void) throws {
        let fs = c.fs, v = c.variant
        let oldS = v.support(c.roots, old: true), newS = v.support(c.roots, old: false)
        func begin(_ step: String, in folder: URL) throws {
            plan.journal.steps.append(step)
            try fs.write(encode(plan.journal), folder.appendingPathComponent(journalName))
        }
        try begin("support", in: oldS)
        try fs.renameExclusive(oldS, newS)
        log("moved \(oldS.path) to \(newS.path)")
        if let r = plan.journal.reviews {
            try begin("reviews", in: newS)
            try fs.renameExclusive(URL(fileURLWithPath: r[0]), URL(fileURLWithPath: r[1]))
            log("moved \(r[0]) to \(r[1])")
        }
        if let data = plan.papersData {
            try begin("papers", in: newS)
            plan.journal.papers = true
            try fs.write(data, newS.appendingPathComponent("papers.json"))
            log("papers.json: \(plan.rewritten) of \(plan.papersCount) papers' places rewritten")
        }
        if !plan.journal.drafts.isEmpty {
            try begin("drafts", in: newS)
            let folder = newS.appendingPathComponent("drafts")
            for d in plan.journal.drafts {
                try fs.renameExclusive(folder.appendingPathComponent(d[0]), folder.appendingPathComponent(d[1]))
                guard let data = plan.draftsData[d[1]] else { throw DataFailure(message: "no draft for \(d[1])") }
                try fs.write(data, folder.appendingPathComponent(d[1]))
            }
            log("drafts: \(plan.journal.drafts.count) renamed for their papers' new places")
        }
        if plan.papersData != nil {
            let back = try JSONDecoder().decode([PaperRef].self, from: fs.read(newS.appendingPathComponent("papers.json")))
            guard back.count == plan.papersCount else { throw DataFailure(message: "papers.json lists \(back.count) papers, not \(plan.papersCount)") }
        }
        if let gone = plan.mustExist.first(where: { fs.kind(URL(fileURLWithPath: $0)) == .none }) {
            throw DataFailure(message: "\(gone) is not there after the move")
        }
        if let merged = plan.defaults {
            try begin("defaults", in: newS)
            plan.journal.defaults = true
            try c.defaults.write(v.id, merged)
            guard let back = c.defaults.read(v.id), NSDictionary(dictionary: back).isEqual(to: merged) else {
                throw DataFailure(message: "the settings did not read back as written")
            }
            log("settings: \(merged.count - 1) copied from \(v.oldID) to \(v.id)")
        }
        plan.journal.state = "done"
        try fs.write(encode(plan.journal), newS.appendingPathComponent(journalName))
    }

    /// Everything a journal's steps did put back, last first, as the disk now is (a rename either happened or not); the
    /// journal then says "rolled_back". nil when all is back and the journal says so; else why not, having stopped at
    /// once.
    static func rollback(_ j: inout Journal, _ c: Context, _ log: (String) -> Void) -> String? {
        let fs = c.fs, v = c.variant
        let oldS = URL(fileURLWithPath: j.from), newS = URL(fileURLWithPath: j.to)
        let wrote = j.wrote
        /// A partial move's file put back from its copy, or left when already restored. Changed files stop recovery:
        /// leaving rewritten paths while moving the folders back would make the app lose track of their contents.
        func restore(_ file: URL, from copy: URL, wrote name: String) throws {
            let before = try fs.read(copy)
            guard fs.kind(file) == .file else { throw DataFailure(message: "\(DataFiles.shown(file)) is not a regular file") }
            if let sum = wrote?[name] {
                let now = try fs.read(file)
                if now == before { return }
                guard digest(now) == sum else {
                    throw DataFailure(message: "\(DataFiles.shown(file)) was changed after the migration wrote it; recovery stopped")
                }
            }
            try fs.write(before, file)
        }
        do {
            // the data folder was moved: the new one is there and the old one is not (the new one was not there before);
            // both there with this migration's journal in the new one: the old one was made again, and nothing can go back
            var moved = false
            if j.steps.contains("support") && fs.kind(newS) == .folder {
                if fs.kind(oldS) == .none {
                    moved = true
                } else if journal(newS, fs: fs)?.from == j.from {
                    throw DataFailure(message: "\(DataFiles.shown(oldS)) was made again while \(DataFiles.shown(newS)) holds the data")
                }
            }
            let here = moved ? newS : oldS
            let pre = j.pre.map { here.appendingPathComponent($0) }
            if moved && j.steps.contains("reviews"), let r = j.reviews {
                let old = fs.kind(URL(fileURLWithPath: r[0])), new = fs.kind(URL(fileURLWithPath: r[1]))
                guard (old == .folder && new == .none) || (old == .none && new == .folder) else {
                    throw DataFailure(message: "the review folder cannot safely be put back: \(r.joined(separator: ", "))")
                }
            }
            // Support moves first and is put back last. If it is already back, every undo is complete (or the move
            // never began). Never replay snapshots over work saved after a rollback, including older journals that
            // have no file hashes. Only the rollback's completion still needs to be recorded below.
            if moved && j.steps.contains("defaults") {
                let snapshot = try pre.map { try fs.read($0.appendingPathComponent("defaults-\(v.id).plist")) }
                    .flatMap { try PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
                guard let snapshot else { throw DataFailure(message: "the copy of \(v.id)’s settings could not be read") }
                if snapshot.isEmpty { try c.defaults.remove(v.id) } else { try c.defaults.write(v.id, snapshot) }
                guard NSDictionary(dictionary: c.defaults.read(v.id) ?? [:]).isEqual(to: snapshot) else {
                    throw DataFailure(message: "the settings could not be put back as they were")
                }
                log("settings of \(v.id) put back as they were")
            }
            if moved && j.steps.contains("drafts") {
                guard let pre else { throw DataFailure(message: "the copies of the drafts could not be found") }
                let folder = here.appendingPathComponent("drafts")
                for d in j.drafts.reversed() {
                    let old = folder.appendingPathComponent(d[0]), new = folder.appendingPathComponent(d[1])
                    let oldKind = fs.kind(old), newKind = fs.kind(new)
                    guard (oldKind == .file && newKind == .none) || (oldKind == .none && newKind == .file) else {
                        throw DataFailure(message: "the draft at \(DataFiles.shown(old)) cannot safely be put back")
                    }
                    try restore(oldKind == .file ? old : new, from: pre.appendingPathComponent("drafts/" + d[0]), wrote: "drafts/" + d[1])
                    if oldKind == .none { try fs.renameExclusive(new, old) }
                }
                log("drafts put back")
            }
            if moved && j.steps.contains("papers") {
                guard let pre else { throw DataFailure(message: "the copy of papers.json could not be found") }
                try restore(here.appendingPathComponent("papers.json"), from: pre.appendingPathComponent("papers.json"), wrote: "papers.json")
                log("papers.json put back")
            }
            if moved && j.steps.contains("reviews"), let r = j.reviews {
                let from = URL(fileURLWithPath: r[0]), to = URL(fileURLWithPath: r[1])
                if fs.kind(to) != .none && fs.kind(from) == .none {
                    try fs.renameExclusive(to, from)
                    log("moved \(r[1]) back to \(r[0])")
                }
            }
            if moved {
                try fs.renameExclusive(newS, oldS)
                log("moved \(j.to) back to \(j.from)")
            }
        } catch {
            log("could not put everything back: \(error.localizedDescription); stopped")
            NSLog("Paperole: migration: could not put everything back")
            return "could not put everything back: \(error.localizedDescription)"
        }
        j.state = "rolled_back"
        let folder = fs.kind(oldS) == .folder ? oldS : newS
        do {
            try fs.write(encode(j), folder.appendingPathComponent(journalName))
            guard journal(folder, fs: fs) == j else {
                throw DataFailure(message: "the rollback status did not read back as written")
            }
        } catch {
            // a journal still "running" is put back again at the next launch: the app must not run in between
            log("everything was put back, but \(journalName) could not say so: \(error.localizedDescription); stopped")
            NSLog("Paperole: migration: put back, but the journal could not say so")
            return "everything was put back, but \(journalName) could not be written: \(error.localizedDescription)"
        }
        return nil
    }

    /// The log appended to migration.log in the first of `prefer` that is a folder, and a copy in the copies' folder.
    private static func flush(_ lines: [String], _ c: Context, prefer: [URL], pre: String? = nil) {
        guard !lines.isEmpty, let folder = prefer.first(where: { c.fs.kind($0) == .folder }) else { return }
        let text = lines.joined(separator: "\n") + "\n"
        let url = folder.appendingPathComponent(logName)
        let before = (try? c.fs.read(url)) ?? Data()
        try? c.fs.write(before + Data(text.utf8), url)
        if let pre, c.fs.kind(folder.appendingPathComponent(pre)) == .folder {
            try? c.fs.write(Data(text.utf8), folder.appendingPathComponent(pre).appendingPathComponent(logName))
        }
    }

    // MARK: Pure helpers

    /// `s` with the old folder's path replaced by the new one's: the folder itself, or a path inside it ("…/Reviews2"
    /// is neither); nil when it names neither.
    static func moved(_ s: String, from old: String, to new: String) -> String? {
        if s == old { return new }
        return s.hasPrefix(old + "/") ? new + s.dropFirst(old.count) : nil
    }

    /// A setting with every such path rewritten: strings, arrays and dictionaries walked, and a string that holds a
    /// JSON object or array (lastPlace, backups) read, rewritten and written again, only when something in it changed.
    static func rewrite(_ value: Any, from old: String, to new: String) -> Any {
        switch value {
        case let s as String:
            if let m = moved(s, from: old, to: new) { return m }
            guard let first = s.first, first == "{" || first == "[", let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) else { return s }
            let changed = rewrite(obj, from: old, to: new)
            guard !(changed as AnyObject).isEqual(obj), let data = try? JSONSerialization.data(withJSONObject: changed, options: [.withoutEscapingSlashes])
            else { return s }
            return String(decoding: data, as: UTF8.self)
        case let a as [Any]:
            return a.map { rewrite($0, from: old, to: new) }
        case let d as [String: Any]:
            return d.mapValues { rewrite($0, from: old, to: new) }
        default:
            return value
        }
    }

    static func stamp(_ date: Date, iso: Bool) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = iso ? "yyyy-MM-dd'T'HH:mm:ssZZZZZ" : "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    private static func digest(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    private static func encode(_ j: Journal) -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(j)) ?? Data()
    }

    private static func plist(_ d: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: d, format: .xml, options: 0)
    }
}
