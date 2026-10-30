import AppKit
import CryptoKit
import Foundation

// Automatic backups and the quiet check (design/data/DATA.md §6, as its §0 amends it). Backups are opt-in and off by
// default: while off, nothing of them shows anywhere. While on, everything is written into the folder the advisor chose
// (the engine's `archive_write`, kind automatic: the same checked file as Export…) at the first quiet moment of each day
// the app is used and after each Finish Round, skipped while no ledger changed since the last backup; only while the
// folder's drive (its volume, recorded by UUID) is connected, a missed backup made once it is back. Earlier backups
// are then rotated: 7 daily, 4 weekly and 6 monthly, within 5 GB; only this app's own (backup.json says automatic,
// this variant, this install), only after the new one was checked, never a paper's last copy. The quiet check runs the
// engine's read-only `check` on the listed folders once after launch and each day; a damaged paper says so on its
// sidebar row. Both use an engine process of their own, so the review's requests never wait behind them, and start
// only while the review's engine is idle (never during a build or a Finish). A test run schedules neither: its tests
// and debug items run them by hand.

/// What Backups keeps between launches (`backups` in the app's defaults, never saved by a test run).
struct BackupState: Codable, Equatable {
    var on = false
    var folder: String?
    /// The folder's volume, by UUID, and its name ("Lab SSD"), recorded when it was chosen.
    var volume: String?
    var volumeName: String?
    var last: BackupRecord?
    var failure: BackupFailure?
    /// The day ("2026-10-22") the daily backup was made, or found not needed.
    var day: String?
    /// A round was finished since the last backup.
    var afterFinish = false
}

/// The last backup, as Settings says it.
struct BackupRecord: Codable, Equatable {
    var time: Date
    var file: String
    var papers: Int
    /// The listed papers left out: each one's drive when it is not connected, else "" (its folder is missing).
    var left: [String]
    var bytes: Int64
    /// The SHA-256 of each paper's ledger.json as backed up, sorted: the next backup is skipped while they are the same
    /// (a ledger's `rev` is in its bytes).
    var ledgers: [String]

    /// "today at 16:40 · 3 papers · 2.3 MB · checked"; a partial one "… · 2 of 3 papers · …", the papers left out
    /// in `leftWords`, a line of its own (so this one does not wrap).
    func words(now: Date, calendar: Calendar = .current) -> String {
        let n = left.isEmpty ? DataModel.count(papers, "paper") : "\(papers) of \(DataModel.count(papers + left.count, "paper"))"
        return [BackupModel.when(time, now: now, calendar: calendar), n, DataFiles.size(bytes), "checked"].joined(separator: " · ")
    }

    /// "Left out: 1 on “Lab SSD”, not connected; 1 missing."; nil when none was.
    var leftWords: String? {
        guard !left.isEmpty else { return nil }
        let drives = left.filter { !$0.isEmpty }
        var why: [String] = []
        for d in Array(Set(drives)).sorted() { why.append("\(drives.filter { $0 == d }.count) on “\(d)”, not connected") }
        if drives.count < left.count { why.append("\(left.count - drives.count) missing") }
        return "Left out: " + why.joined(separator: "; ") + "."
    }
}

struct BackupFailure: Codable, Equatable {
    /// The first failure since the last backup.
    var since: Date
    var message: String

    /// "Couldn't back up since Oct 14: “Lab SSD” isn't connected." / "Couldn't back up today: …".
    func words(now: Date, calendar: Calendar = .current) -> String {
        let when = calendar.isDate(since, inSameDayAs: now) ? "today" : "since " + since.formatted(.dateTime.month(.abbreviated).day())
        return "Couldn’t back up \(when): \(message)"
    }
}

/// A file in the backup folder, as its backup.json says (the engine's `archive_info`).
struct BackupFile: Equatable {
    var url: URL
    var created: Date
    var bytes: Int64
    /// The papers it holds: each one's id, else the place it was backed up from.
    var papers: Set<String>
    /// The places they were backed up from.
    var paths: [String]
    /// This app's own automatic backup (kind automatic, this variant, this install): only these are rotated.
    var ours: Bool
    /// The app that made it, as made_by names it ("Paperole", "Paperole Dev", or before the rename "PaperCollab",
    /// "PaperCollab Dev": `AppVariant(stored:)`): Restore from Last Backup… takes only this app's.
    var variant: String? = nil

    /// From one file of `archive_info`'s reply; nil for a file that is not a Paperole export (nor a PaperCollab one,
    /// as the app was called before). `variant`: this app's name; a file made_by names with either of this app's names
    /// is this app's.
    static func make(_ entry: [String: Any], variant: String, install: String) -> BackupFile? {
        guard let path = entry["path"] as? String, let b = entry["backup"] as? [String: Any], AppVariant.readsFormat(b["app"]),
              let created = (b["created"] as? String).flatMap({ ISO8601DateFormatter().date(from: $0) }) else { return nil }
        let url = URL(fileURLWithPath: path)
        let made = b["made_by"] as? [String: Any]
        var papers = Set<String>(), paths: [String] = []
        for p in b["papers"] as? [[String: Any]] ?? [] {
            let at = p["was_at"] as? String
            if let at { paths.append(at) }
            if let key = (p["id"] as? String) ?? at { papers.insert(key) }
        }
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let app = AppVariant(stored: made?["variant"] as? String)
        let ours = b["schema"] as? Int == 2 && b["kind"] as? String == "automatic" && app != nil && app == AppVariant(stored: variant)
            && made?["install"] as? String == install
        return BackupFile(url: url, created: created, bytes: Int64(bytes), papers: papers, paths: paths, ours: ours,
                          variant: made?["variant"] as? String)
    }
}

/// Which of the app's own automatic backups to delete once a new one is checked (DATA.md §6.1). Pure, so it is
/// unit-tested.
enum BackupRotation {
    static let daily = 7, weekly = 4, monthly = 6
    /// 5 GB, decimal, as Finder counts.
    static let limit: Int64 = 5_000_000_000

    /// Of `files` (this app's own automatic backups in the folder, `new` among them): kept are `new`, the newest of
    /// each of the 7 latest days, 4 latest weeks and 6 latest months that have one, the oldest of those dropped while
    /// they come to more than 5 GB; and, whatever that says, every file holding a paper that no newer file kept holds,
    /// so the last copy of a paper is never deleted. The rest, oldest first.
    static func plan(_ files: [BackupFile], new: URL, calendar: Calendar = .current) -> [URL] {
        // newest first; of two made in the same second, the new one first
        let newest = files.sorted { a, b in a.created != b.created ? a.created > b.created : a.url == new && b.url != new }
        var keep: Set<URL> = [new]
        func newestOf<K: Hashable>(_ n: Int, _ key: (Date) -> K) {
            var seen: [K] = []
            for f in newest {
                let k = key(f.created)
                if seen.contains(k) { continue }
                guard seen.count < n else { break }
                seen.append(k)
                keep.insert(f.url)
            }
        }
        newestOf(daily) { calendar.startOfDay(for: $0) }
        newestOf(weekly) { d -> [Int] in
            let c = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: d)
            return [c.yearForWeekOfYear ?? 0, c.weekOfYear ?? 0]
        }
        newestOf(monthly) { d -> [Int] in
            let c = calendar.dateComponents([.year, .month], from: d)
            return [c.year ?? 0, c.month ?? 0]
        }
        var total = newest.filter { keep.contains($0.url) }.reduce(Int64(0)) { $0 + $1.bytes }
        for f in newest.reversed() where total > limit && f.url != new && keep.contains(f.url) {
            keep.remove(f.url)
            total -= f.bytes
        }
        var held = Set<String>()  // the papers newer kept files hold
        for f in newest {
            if !keep.contains(f.url) && !f.papers.isSubset(of: held) { keep.insert(f.url) }
            if keep.contains(f.url) { held.formUnion(f.papers) }
        }
        return newest.reversed().filter { !keep.contains($0.url) }.map(\.url)
    }
}

enum BackupPlaces {
    /// "Paperole Backups"; Paperole Dev's is "Paperole Dev Backups", never Paperole's.
    static var folderName: String { AppVariant.current.name + " Backups" }
    /// The name the folder had before the app was renamed (AppVariant): "PaperCollab Backups", "PaperCollab Dev Backups".
    /// A backup folder is a place the advisor chose (an external drive, often), so it is never moved or renamed.
    static var oldFolderName: String { AppVariant.current.oldName + " Backups" }

    /// Where Back up automatically suggests: that folder on an external drive when one is connected, else in the home
    /// folder; the one of the old name there instead, when there is one, so backups made before the rename are found.
    static func suggested(drive: URL?) -> URL {
        let base = drive ?? FileManager.default.homeDirectoryForCurrentUser
        var isFolder: ObjCBool = false
        let old = base.appendingPathComponent(oldFolderName)
        if FileManager.default.fileExists(atPath: old.path, isDirectory: &isFolder), isFolder.boolValue { return old }
        return base.appendingPathComponent(folderName)
    }

    /// A connected external drive: local, writable, not this Mac's own disk; nil when there is none.
    static func externalDrive() -> URL? {
        let keys: [URLResourceKey] = [.volumeIsInternalKey, .volumeIsLocalKey, .volumeIsReadOnlyKey, .volumeIsRootFileSystemKey,
                                      .volumeIsBrowsableKey]
        for v in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [] {
            guard let r = try? v.resourceValues(forKeys: Set(keys)), r.volumeIsInternal == false, r.volumeIsLocal == true,
                  r.volumeIsReadOnly == false, r.volumeIsRootFileSystem != true, r.volumeIsBrowsable != false else { continue }
            return v
        }
        return nil
    }

    /// A folder's volume: its UUID and name; nil when the folder is not there.
    nonisolated static func volume(_ url: URL) -> (uuid: String?, name: String?) {
        let v = try? url.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeNameKey])
        return (v?.volumeUUIDString, v?.volumeName)
    }

    /// "Paperole Backup 2026-10-21 1640.zip" (Paperole Dev's: "Paperole Dev Backup …"). Only backup.json says what a
    /// file is, so the ones named before the rename ("PaperCollab Backup …") rotate and restore as these.
    static func fileName(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmm"
        return "\(AppVariant.current.name) Backup \(f.string(from: date)).zip"
    }
}

/// Settings › Data & Storage › Backups and the quiet check: the state, the schedule and the work.
@MainActor
final class BackupModel: ObservableObject {
    @Published private(set) var state: BackupState {
        didSet { if remember, state != oldValue, let d = try? JSONEncoder().encode(state) { Prefs.set(String(decoding: d, as: UTF8.self), Self.key) } }
    }
    /// The step of the backup running ("Writing “Kelp drift” (1 of 3)…"); nil when none runs.
    @Published private(set) var step: String?
    /// The Paperole files in the backup folder, newest first, as last read: Restore from Last Backup… looks here.
    @Published private(set) var files: [BackupFile] = []
    /// The backup folder is on the disk of a listed review folder (or of where new ones go).
    @Published private(set) var sameDisk = false
    static let key = "backups"

    weak var app: AppModel?
    private let remember: Bool
    /// The clock and a folder's volume UUID: the tests' own.
    var now: () -> Date = Date.init
    var volumeOf: (URL) -> String? = { BackupPlaces.volume($0).uuid }
    /// When the app started: the first quiet moment is a minute later.
    var launched = Date()
    private lazy var engine = EngineClient()
    /// The `archive_write` running, which Cancel asks the engine to stop; `stopping` once it was asked.
    private var request: Int?
    private var stopping = false
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    /// After a failure, not tried again before this (a drive connected, a Finish or Back Up Now clears it).
    private var retryAfter: Date?
    /// The day the quiet check last ran, and papers to check again once it has finished.
    private var checkDay: String?
    private var recheck: Set<String> = []
    @Published private(set) var checking = false

    init(app: AppModel, remember: Bool) {
        self.app = app
        self.remember = remember
        let saved = remember ? Prefs.string(Self.key).flatMap { try? JSONDecoder().decode(BackupState.self, from: Data($0.utf8)) } : nil
        state = saved ?? BackupState()
    }

    var running: Bool { step != nil }
    /// The schedule is on: never in a test run.
    var scheduled: Bool { timer != nil }

    nonisolated static func day(_ d: Date) -> String { DataFiles.day(d) }

    /// "today at 16:40", "yesterday at 9:12", "Oct 14 at 16:40", the time as the system writes it.
    nonisolated static func when(_ d: Date, now: Date, calendar: Calendar = .current) -> String {
        let t = d.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(d, inSameDayAs: now) { return "today at \(t)" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(d, inSameDayAs: y) { return "yesterday at \(t)" }
        return d.formatted(.dateTime.month(.abbreviated).day()) + " at " + t
    }

    // MARK: The schedule

    /// A minute's tick, and a drive connected or the Mac woken; never in a test run.
    func start() {
        guard remember, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didWakeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.driveConnected() }
            })
        }
        if state.on { refreshFiles() }
    }

    /// A drive was connected (or the Mac woke): a missed backup is tried again at once.
    func driveConnected() {
        retryAfter = nil
        soon()
    }

    private func soon() {
        guard remember else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.tick() }
    }

    /// The review's engine idle (no build, no Finish, no request), no work in Data & Storage, none of ours.
    var quiet: Bool {
        guard let app else { return false }
        return !running && !checking && app.fixtureURL == nil && !app.busy && !app.data.working && !app.finishPreview.finishing
    }

    /// At the first quiet moment, a minute after launch or later: the day's check, else a backup that is due.
    func tick() {
        guard quiet, now().timeIntervalSince(launched) >= 60 else { return }
        if checkDay != Self.day(now()) { return checkFolders() }
        if due { backUp() }
    }

    /// On, and a round finished since the last backup, or none made (nor found not needed) today; not yet again after
    /// a failure.
    var due: Bool {
        guard state.on else { return false }
        if let r = retryAfter, now() < r { return false }
        return state.afterFinish || state.day != Self.day(now())
    }

    /// Finish Round: a backup at the next quiet moment.
    func roundFinished() {
        guard state.on else { return }
        state.afterFinish = true
        retryAfter = nil
        soon()
    }

    // MARK: On and off

    /// The switch turned on: the folder chosen first (Cancel leaves it off).
    func turnOn() {
        guard let u = chooseFolder() else { return }
        use(u)
    }

    func turnOff() {
        stopBackup()
        state.on = false
        state.failure = nil
        files = []
    }

    /// Backups on, into `folder` (its volume recorded): the first is made at the next quiet moment. Another folder
    /// than before starts with no last backup, so it gets one today however little changed.
    func use(_ folder: URL) {
        let u = folder.standardizedFileURL
        if state.folder != u.path {
            state.last = nil
            state.day = nil
        }
        state.folder = u.path
        state.volume = volumeOf(u)
        state.volumeName = BackupPlaces.volume(u).name
        state.on = true
        state.failure = nil
        retryAfter = nil
        noteSameDisk()
        refreshFiles()
        soon()
    }

    /// The folder panel, at the folder suggested (the one used before, else on an external drive when one is connected,
    /// else in the home folder), made for the panel and removed again when another is chosen or Cancel and it is still
    /// empty; a folder synced to a cloud asks first (DATA.md §2.6).
    func chooseFolder() -> URL? {
        guard !LaunchOptions.background else { return nil }  // a test run never shows a panel (the debug items give folders)
        let fm = FileManager.default
        var dir: ObjCBool = false
        let before = state.folder.flatMap { fm.fileExists(atPath: $0, isDirectory: &dir) && dir.boolValue ? URL(fileURLWithPath: $0) : nil }
        let drive = before == nil ? BackupPlaces.externalDrive() : nil
        let start = before ?? BackupPlaces.suggested(drive: drive)
        let made = !fm.fileExists(atPath: start.path) && (try? fm.createDirectory(at: start, withIntermediateDirectories: false)) != nil
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.allowsMultipleSelection = false
        p.directoryURL = start
        p.prompt = "Choose"
        p.message = "Choose the folder for automatic backups. " + (drive.map {
            "“\($0.lastPathComponent)” is connected: a backup on it also guards against losing this Mac’s disk."
        } ?? "A folder on an external drive also guards against losing this Mac’s disk.")
        let chosen = p.runModal() == .OK ? p.url?.standardizedFileURL : nil
        if made && chosen?.path != start.standardizedFileURL.path { rmdir(start.path) }  // only while it is empty
        guard let u = chosen else { return nil }
        if let service = DataPlaces.synced(u) {
            let a = NSAlert()
            a.messageText = "This folder is synced to \(service)."
            a.informativeText = "Your students’ unpublished papers would be uploaded, and macOS may remove files from this Mac to save space."
            a.addButton(withTitle: "Choose Another Folder")
            a.addButton(withTitle: "Use It Anyway")
            if a.runModal() == .alertFirstButtonReturn { return chooseFolder() }
        }
        return u
    }

    /// Whether the backup folder shares a disk with the listed review folders or where new ones go: the note says a
    /// backup there guards against mistakes, not against losing the disk.
    func noteSameDisk() {
        guard let app, let f = state.folder, let v = volumeOf(URL(fileURLWithPath: f)) else { sameDisk = false; return }
        let places = app.papers.map(\.path) + [app.data.root?.path].compactMap { $0 }
        sameDisk = places.contains { volumeOf(URL(fileURLWithPath: $0)) == v }
    }

    /// Why a backup cannot be written now, or nil: the folder is not there, or (a folder on a drive, under /Volumes) its
    /// drive is not the one chosen. Another volume under a folder elsewhere is this Mac's own disk, new after a move to
    /// a new Mac or a restore onto a new disk: no problem (`backUp` records it again).
    func placeProblem() -> String? {
        guard let f = state.folder else { return "No folder is chosen." }
        var dir: ObjCBool = false
        let there = FileManager.default.fileExists(atPath: f, isDirectory: &dir) && dir.boolValue
        let onDrive = (f as NSString).standardizingPath.split(separator: "/").first == "Volumes"
        let other = there && onDrive && state.volume != nil && volumeOf(URL(fileURLWithPath: f)) != state.volume
        guard !there || other else { return nil }
        if let drive = DataPlaces.unplugged(f) ?? (other ? state.volumeName : nil) { return "“\(drive)” isn’t connected." }
        return "the folder is not there any more."  // its path is on the Backup folder row above
    }

    // MARK: Backing up

    /// The SHA-256 of each review folder's ledger.json that is there, sorted.
    nonisolated static func ledgers(_ paths: [String]) -> [String] {
        paths.compactMap { p -> String? in
            guard let d = try? Data(contentsOf: URL(fileURLWithPath: p).appendingPathComponent("ledger.json")) else { return nil }
            return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
        }.sorted()
    }

    /// A backup of everything into the folder, then the rotation. Skipped while no ledger changed since the last one and
    /// it is still in the folder (unless `manual`: Back Up Now), or no review folder is there; a failure is kept for
    /// Settings, and tried again later.
    func backUp(manual: Bool = false) {
        guard let app, state.on, !running else { return }
        let at = now()
        let papers = app.papers
        step = "Looking for changes…"
        if manual { retryAfter = nil }
        Task {
            let paths = papers.map(\.path)
            let current = await Task.detached { Self.ledgers(paths) }.value
            // nothing new: no ledger changed since the last backup, which is still in the folder (or the folder is not
            // there to look: its drive not connected)
            let lastThere = state.last.map { l in
                placeProblem() != nil || FileManager.default.fileExists(atPath: (state.folder ?? "") + "/" + l.file)
            } ?? false
            if current.isEmpty || (!manual && lastThere && current == state.last?.ledgers) {  // nothing to back up, or nothing new
                state.day = Self.day(at)
                state.afterFinish = false
                state.failure = nil
                return finished()
            }
            if stopping { return finished() }
            if let why = placeProblem() {
                retryAfter = at.addingTimeInterval(600)
                return failed(why, at: at)
            }
            let folder = URL(fileURLWithPath: state.folder ?? "")
            if let v = volumeOf(folder), v != state.volume {  // this Mac's own disk, new since (placeProblem)
                state.volume = v
                state.volumeName = BackupPlaces.volume(folder).name
            }
            guard FileManager.default.isWritableFile(atPath: folder.path) else {
                retryAfter = at.addingTimeInterval(600)
                return failed("the folder can’t be written to.", at: at)
            }
            let dest = DataFiles.unique(BackupPlaces.fileName(at), in: folder, file: true)
            var written = false
            do {
                step = "Writing…"
                let reply = try await call("archive_write", app.data.archiveParams(papers, dest: dest, everything: true, kind: "automatic"))
                let r = try JSONSerialization.jsonObject(with: reply) as? [String: Any] ?? [:]
                let b = r["backup"] as? [String: Any] ?? [:]
                let held = b["papers"] as? [[String: Any]] ?? []
                let left = (b["missing"] as? [[String: Any]] ?? []).map { DataPlaces.unplugged($0["path"] as? String ?? "") ?? "" }
                written = true
                state.last = BackupRecord(time: at, file: dest.lastPathComponent, papers: held.count, left: left,
                                          bytes: (r["bytes"] as? NSNumber)?.int64Value ?? 0,
                                          ledgers: held.compactMap { ($0["ledger"] as? [String: Any])?["sha256"] as? String }.sorted())
                state.day = Self.day(at)
                state.afterFinish = false
                state.failure = nil
                retryAfter = nil
                if state.on && !stopping {
                    step = "Tidying up…"
                    try await rotate(new: URL(fileURLWithPath: r["path"] as? String ?? dest.path))
                }
            } catch {
                // a cancel (quitting, the switch turned off) is no failure, nor is one after the backup was made
                if !written && !stopping {
                    retryAfter = at.addingTimeInterval(3600)
                    return failed(error.localizedDescription, at: at)
                }
            }
            finished()
        }
    }

    private func failed(_ message: String, at: Date) {
        let f = BackupFailure(since: state.failure?.since ?? at, message: message.hasSuffix(".") ? message : message + ".")
        if f != state.failure { state.failure = f }
        finished()
    }

    private func finished() {
        step = nil
        request = nil
        stopping = false
        idle()
    }

    /// Quitting (or the switch turned off) while a backup runs: the engine stops it where it leaves nothing; the next
    /// launch makes it.
    func stopBackup() {
        guard running else { return }
        stopping = true
        guard let id = request, let json = try? JSONSerialization.data(withJSONObject: ["id": id]) else { return }
        _ = engine.send("cancel", params: json)
    }

    /// The Paperole files in the folder, and this app's own automatic backups deleted as BackupRotation says: only
    /// regular files directly in the folder (never a link), never `new`.
    private func rotate(new: URL) async throws {
        let found = try await readFolder()
        files = found
        let folder = new.deletingLastPathComponent().standardizedFileURL
        let gone = BackupRotation.plan(found.filter(\.ours), new: new.standardizedFileURL)
        for u in gone {
            let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard u.deletingLastPathComponent().standardizedFileURL == folder, v?.isRegularFile == true, v?.isSymbolicLink != true
            else { continue }
            if (try? FileManager.default.removeItem(at: u)) != nil { files.removeAll { $0.url == u } }
        }
    }

    /// What each .zip directly in the backup folder holds (the engine's `archive_info`, its backup.json alone), newest
    /// first.
    private func readFolder() async throws -> [BackupFile] {
        guard let app, let f = state.folder else { return [] }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        let zips = ((try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: f), includingPropertiesForKeys: Array(keys),
                                                                    options: [.skipsHiddenFiles])) ?? [])
            .filter { u in
                let v = try? u.resourceValues(forKeys: keys)
                return u.pathExtension.lowercased() == "zip" && v?.isRegularFile == true && v?.isSymbolicLink != true
            }
            .map { $0.standardizedFileURL }
        guard !zips.isEmpty else { return [] }
        let reply = try await call("archive_info", ["paths": zips.map(\.path)])
        let entries = (try JSONSerialization.jsonObject(with: reply) as? [String: Any])?["files"] as? [[String: Any]] ?? []
        let install = app.data.madeBy["install"] as? String ?? ""
        return entries.compactMap { BackupFile.make($0, variant: AppVariant.current.name, install: install) }
            .sorted { $0.created > $1.created }
    }

    /// The files read again (Restore from Last Backup… looks there), while on and the folder is there.
    func refreshFiles() {
        guard state.on, placeProblem() == nil, !running else { return }
        Task {
            let found = (try? await readFolder()) ?? []
            if state.on { files = found }
            idle()
        }
    }

    // MARK: Restore

    /// The newest backup in the folder holding this paper (by its id, else its place), while backups are on; only one
    /// this app made, so Paperole never restores Paperole Dev's test data (whose copy the preview would use).
    func holding(_ p: PaperRef) -> BackupFile? {
        guard state.on else { return nil }
        return files.first { f in
            AppVariant(stored: f.variant) == AppVariant.current
                && (p.ledgerID.map(f.papers.contains) == true || f.paths.contains { ImportPlan.samePlace($0, p.path) })
        }
    }

    /// Restore from Last Backup… is offered: backups on, their folder there, the paper's folder missing (not on a drive
    /// that is not connected) or damaged, and a backup holds it.
    func restorable(_ p: PaperRef) -> Bool {
        guard state.on, let app, placeProblem() == nil else { return false }
        let gone = app.missingPapers.contains(p.path) && DataPlaces.unplugged(p.path) == nil
        return (gone || app.damagedPapers[p.path] != nil) && holding(p) != nil
    }

    // MARK: The quiet check

    /// The quiet check (DATA.md §6.3): the engine's read-only `check` on the listed folders that are there. A paper
    /// with damage is marked on its sidebar row; leftovers, `.orphans`, conflict copies and files iCloud removed are
    /// no damage (as Import has them), and a folder that is not there is already "missing". `only`: these papers
    /// again (after Put Back an Earlier Ledger…, Use This Copy).
    func checkFolders(_ only: [String]? = nil) {
        guard let app else { return }
        if checking {
            recheck.formUnion(only ?? app.papers.map(\.path))
            return
        }
        if only == nil { checkDay = Self.day(now()) }
        let paths = (only ?? app.papers.map(\.path)).filter { DataFiles.isReviewFolder(URL(fileURLWithPath: $0)) }
        var found = only == nil ? [:] : app.damagedPapers.filter { !(only ?? []).contains($0.key) }
        guard !paths.isEmpty else {
            if found != app.damagedPapers { app.damagedPapers = found }
            return
        }
        checking = true
        Task {
            if let reply = try? await call("check", ["papers": paths]),
               let papers = (try? JSONSerialization.jsonObject(with: reply) as? [String: Any])?["papers"] as? [[String: Any]] {
                for (path, p) in zip(paths, papers) {
                    if let m = Self.damage(p["problems"] as? [[String: Any]] ?? []) { found[path] = m }
                }
                if found != app.damagedPapers { app.damagedPapers = found }
            }
            checking = false
            if !recheck.isEmpty {
                let again = Array(recheck)
                recheck = []
                return checkFolders(again)
            }
            idle()
        }
    }

    /// `check`'s problems that are no damage, as the engine's Import has them (archive.QUIET).
    nonisolated static let harmless: Set<String> = ["leftovers", "orphans", "conflict_copies", "evicted"]
    /// Also no damage to the quiet check: a folder that is not there, or holds no ledger, is "missing".
    nonisolated static let noDamage: Set<String> = harmless.union(["missing_folder", "no_ledger"])

    /// The engine's words for the first damage among `check`'s problems, or nil.
    nonisolated static func damage(_ problems: [[String: Any]]) -> String? {
        problems.first { !noDamage.contains($0["code"] as? String ?? "") }.map { $0["message"] as? String ?? "A file is damaged." }
    }

    // MARK: The engine

    /// A request to the backups' own engine process; its progress is the step shown while a backup runs.
    private func call(_ method: String, _ params: [String: Any]) async throws -> Data {
        let id = engine.send(method, params: try JSONSerialization.data(withJSONObject: params)) { message in
            Task { @MainActor [weak self] in if self?.running == true { self?.step = message } }
        }
        if method == "archive_write" { request = id }
        return try await engine.result(id)
    }

    /// The engine process ends between jobs, so it holds no memory all day.
    private func idle() {
        if !running && !checking { engine.stop() }
    }

    // MARK: Debug

    func debugResult() -> [String: Any] {
        func null(_ v: Any?) -> Any { v ?? NSNull() }
        return ["on": state.on, "folder": null(state.folder), "volume": null(state.volumeName), "step": null(step),
                "last": null(state.last?.words(now: now())), "left": null(state.last?.leftWords),
                "failure": null(state.failure?.words(now: now())),
                "files": files.map(\.url.lastPathComponent), "sameDisk": sameDisk, "scheduled": scheduled, "due": due]
    }
}
