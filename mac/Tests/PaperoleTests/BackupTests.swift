import AppKit
import SwiftUI
import XCTest
@testable import Paperole

/// Automatic backups and the quiet check (design/data/DATA.md §6 as its §0 amends it), with an injected clock and
/// temporary folders only: off by default and never scheduled by a test run; on, into a folder whose drive is
/// recorded; the daily backup and the one after Finish Round, skipped while no ledger changed; never written to a
/// drive that is not connected, made once it is back; the rotation (days, weeks, months, 5 GB, a paper's last copy)
/// and only this app's own files; a failure said in Settings only; a damaged paper marked by the check and restored
/// from the last backup. The papers are synthetic, made by the engine's `new` (no TeX needed).
@MainActor
final class BackupTests: XCTestCase {
    private var tmp: URL!
    private var windows: [NSWindow] = []
    private var fm: FileManager { .default }

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("pc-backups-" + UUID().uuidString).standardizedFileURL
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        windows.forEach { $0.close() }
        windows = []
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.appendingPathComponent("Backups").path)
        try? fm.removeItem(at: tmp)
    }

    // MARK: Helpers

    private func fixtureModel() -> AppModel {
        _ = NSApplication.shared
        var o = LaunchOptions()
        o.fixture = ReadingTests.fixtures.appendingPathComponent("state-reading.json").path
        o.drafts = tmp.appendingPathComponent("drafts").path
        o.cache = tmp.appendingPathComponent("cache").path
        o.tags = tmp.appendingPathComponent("tags/tags.json").path
        return AppModel(options: o)
    }

    /// A model with the engine and no list of its own (--no-list: papers.json neither read nor written).
    private func engineModel() throws -> AppModel {
        guard fm.isExecutableFile(atPath: EngineClient.defaultPython) else { throw XCTSkip("needs the engine's Python") }
        _ = NSApplication.shared
        var o = LaunchOptions()
        o.noList = true
        o.drafts = tmp.appendingPathComponent("drafts").path
        o.cache = tmp.appendingPathComponent("cache").path
        o.tags = tmp.appendingPathComponent("tags/tags.json").path
        return AppModel(options: o)
    }

    @discardableResult
    private func rpc(_ m: AppModel, _ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let data = try await m.engine.call(method, params: JSONSerialization.data(withJSONObject: params))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// A paper made by the engine's `new`: a review folder with its ledger, no rounds.
    private func paper(_ m: AppModel, _ title: String, student: String) async throws -> PaperRef {
        let folder = tmp.appendingPathComponent("Reviews").appendingPathComponent(title)
        try await rpc(m, "new", ["paper": folder.path, "title": title, "student": student])
        return PaperRef(path: folder.path, title: title, student: student, factsMoved: true)
    }

    private func folder(_ name: String = "Backups") throws -> URL {
        let u = tmp.appendingPathComponent(name)
        try fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// 2026-10-20 09:00 in this Mac's time zone, as the backups' days and names are.
    private func date(_ s: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)!
    }

    private func settle(_ m: AppModel) async throws {
        for _ in 0..<1200 where m.backups.running || m.backups.checking || m.data.working {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(m.backups.running || m.backups.checking || m.data.working, "the work did not finish")
    }

    private func zips(_ dir: URL) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".zip") }.sorted()
    }

    private func formHeight(_ m: AppModel) -> CGFloat {
        let host = NSHostingView(rootView: DataSettings(model: m))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsView.width, height: DataSettings.height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        func scrollers(_ v: NSView) -> [NSScrollView] { ((v as? NSScrollView).map { [$0] } ?? []) + v.subviews.flatMap(scrollers) }
        return scrollers(host).compactMap { $0.documentView?.frame.height }.max() ?? 0
    }

    // MARK: On and off

    /// Off by default, and a test run schedules nothing; while off, the tab has the switch alone; on, the folder (its
    /// drive recorded by UUID), the last backup and Back Up Now appear. The folder suggested, the file's name, the
    /// same-disk note.
    func testOffByDefaultThenOnIntoAFolder() throws {
        let m = fixtureModel()
        XCTAssertEqual(m.backups.state, BackupState())
        XCTAssertFalse(m.backups.state.on)
        m.backups.start()
        XCTAssertFalse(m.backups.scheduled, "a test run never schedules backups")
        XCTAssertFalse(m.backups.due)
        let off = formHeight(m)

        let dir = try folder()
        m.backups.use(dir)
        XCTAssertTrue(m.backups.state.on)
        XCTAssertEqual(m.backups.state.folder, dir.path)
        XCTAssertNotNil(m.backups.state.volume)
        XCTAssertEqual(m.backups.state.volume, BackupPlaces.volume(dir).uuid)
        XCTAssertTrue(m.backups.due, "the first one at the next quiet moment")
        XCTAssertFalse(m.backups.scheduled)
        XCTAssertGreaterThan(formHeight(m), off + 40, "the folder, the last backup and Back Up Now show only while on")
        m.backups.turnOff()
        XCTAssertFalse(m.backups.state.on)
        XCTAssertEqual(formHeight(m), off)

        let home = fm.homeDirectoryForCurrentUser
        XCTAssertEqual(BackupPlaces.suggested(drive: URL(fileURLWithPath: "/Volumes/Lab SSD")).path, "/Volumes/Lab SSD/Paperole Dev Backups")
        let atHome = BackupPlaces.suggested(drive: nil)
        XCTAssertEqual(atHome.deletingLastPathComponent().standardizedFileURL, home.standardizedFileURL)
        XCTAssertTrue(["Paperole Dev Backups", "PaperCollab Dev Backups"].contains(atHome.lastPathComponent),
                      "Paperole Dev never suggests Paperole's folder: \(atHome.path)")
        XCTAssertEqual(BackupPlaces.fileName(date("2026-10-21 16:40")), "Paperole Dev Backup 2026-10-21 1640.zip")
        // the renaming (2026-10-27): where a folder of the old name is, it is the one suggested, so the backups made
        // before are found; never the official app's
        let drive = try folder("Lab SSD")
        _ = try folder("Lab SSD/PaperCollab Backups")
        XCTAssertEqual(BackupPlaces.suggested(drive: drive), drive.appendingPathComponent("Paperole Dev Backups"))
        let old = try folder("Lab SSD/PaperCollab Dev Backups")
        XCTAssertEqual(BackupPlaces.suggested(drive: drive).path, old.path)
        try fm.removeItem(at: old)
        try Data().write(to: old)
        XCTAssertEqual(BackupPlaces.suggested(drive: drive), drive.appendingPathComponent("Paperole Dev Backups"), "a file is no folder")

        // the note: on the disk of a listed review folder
        let reviews = try folder("Reviews/Kelp drift")
        m.papers = [PaperRef(path: reviews.path, title: "Kelp drift", student: "Mei Lin")]
        m.backups.use(dir)
        XCTAssertTrue(m.backups.sameDisk)
        m.backups.volumeOf = { $0.path.hasPrefix(dir.path) ? "LAB-SSD" : "THIS-MAC" }
        m.backups.noteSameDisk()
        XCTAssertFalse(m.backups.sameDisk)
    }

    // MARK: When

    /// The day's first quiet moment (after the day's check), and after Finish Round; never while the review's engine
    /// works; skipped while no ledger changed (the day noted), made again once one has; Back Up Now always.
    func testDailyAndAfterFinishSkippedWhenNothingChanged() async throws {
        let m = try engineModel()
        let kelp = try await paper(m, "Kelp drift", student: "Mei Lin")
        let pools = try await paper(m, "Warm pools", student: "Ana Sousa")
        m.papers = [kelp, pools]
        let dir = try folder()
        var clock = date("2026-10-20 09:00")
        m.backups.now = { clock }
        m.backups.launched = clock.addingTimeInterval(-120)
        m.backups.use(dir)

        m.holdBusy(true)
        m.backups.tick()
        XCTAssertFalse(m.backups.running || m.backups.checking, "never while the engine works")
        m.holdBusy(false)
        m.backups.launched = clock
        m.backups.tick()
        XCTAssertFalse(m.backups.running || m.backups.checking, "not in the app's first minute")
        m.backups.launched = clock.addingTimeInterval(-120)

        m.backups.tick()  // the day's check first
        try await settle(m)
        XCTAssertTrue(m.backups.due)
        m.backups.tick()
        try await settle(m)
        XCTAssertNil(m.backups.state.failure)
        XCTAssertEqual(m.backups.state.last?.file, "Paperole Dev Backup 2026-10-20 0900.zip")
        XCTAssertEqual(m.backups.state.last?.papers, 2)
        XCTAssertEqual(m.backups.state.last?.left, [])
        XCTAssertEqual(zips(dir), ["Paperole Dev Backup 2026-10-20 0900.zip"])
        XCTAssertFalse(m.backups.due, "one a day")
        let words = try XCTUnwrap(m.backups.state.last?.words(now: clock))
        XCTAssertTrue(words.hasPrefix("today at "), words)
        XCTAssertTrue(words.hasSuffix(" · 2 papers · \(DataFiles.size(m.backups.state.last?.bytes ?? 0)) · checked"), words)

        // Finish Round: due again, and a ledger changed
        clock = date("2026-10-20 10:00")
        try await rpc(m, "edit_paper", ["paper": kelp.path, "title": "Kelp drift in the bay"])
        m.backups.roundFinished()
        XCTAssertTrue(m.backups.due)
        m.backups.tick()
        try await settle(m)
        XCTAssertEqual(m.backups.state.last?.file, "Paperole Dev Backup 2026-10-20 1000.zip")
        XCTAssertFalse(m.backups.state.afterFinish)
        XCTAssertEqual(zips(dir), ["Paperole Dev Backup 2026-10-20 1000.zip"], "the same day's earlier one rotated away")

        // the next day, nothing changed: no backup, the day noted
        clock = date("2026-10-21 09:00")
        XCTAssertTrue(m.backups.due)
        m.backups.tick()
        try await settle(m)
        m.backups.tick()
        try await settle(m)
        XCTAssertEqual(m.backups.state.last?.file, "Paperole Dev Backup 2026-10-20 1000.zip")
        XCTAssertEqual(m.backups.state.day, "2026-10-21")
        XCTAssertFalse(m.backups.due)
        XCTAssertEqual(zips(dir).count, 1)
        // Back Up Now: made all the same
        m.backups.backUp(manual: true)
        try await settle(m)
        XCTAssertEqual(m.backups.state.last?.file, "Paperole Dev Backup 2026-10-21 0900.zip")
        XCTAssertTrue(m.backups.state.last?.words(now: date("2026-10-22 08:00")).hasPrefix("yesterday at ") == true)

        // a change: the next day's is made
        clock = date("2026-10-22 09:00")
        try await rpc(m, "edit_paper", ["paper": pools.path, "title": "Warm pools of the reef"])
        m.backups.tick()
        try await settle(m)
        m.backups.tick()
        try await settle(m)
        XCTAssertEqual(m.backups.state.last?.file, "Paperole Dev Backup 2026-10-22 0900.zip")
    }

    /// Another folder chosen, or the last backup gone from the folder: one is made however little changed, never
    /// skipped as "nothing new" while the folder holds none of them.
    func testANewFolderOrAMissingLastBackupGetsOne() async throws {
        let m = try engineModel()
        m.papers = [try await paper(m, "Kelp drift", student: "Mei Lin")]
        let dir = try folder(), other = try folder("Other")
        m.backups.now = { self.date("2026-10-20 09:00") }
        m.backups.use(dir)
        m.backups.backUp()
        try await settle(m)
        let first = try XCTUnwrap(m.backups.state.last?.file)
        try fm.moveItem(at: dir.appendingPathComponent(first), to: tmp.appendingPathComponent(first))  // moved away in Finder
        m.backups.backUp()
        try await settle(m)
        XCTAssertEqual(zips(dir), [first], "made again")
        m.backups.backUp()
        try await settle(m)
        XCTAssertEqual(zips(dir), [first], "nothing new: skipped")
        m.backups.use(other)
        XCTAssertNil(m.backups.state.last, "the last backup is in the other folder")
        XCTAssertTrue(m.backups.due)
        m.backups.backUp()
        try await settle(m)
        XCTAssertEqual(zips(other), [first])
    }

    // MARK: Drives

    /// A folder on a drive (under /Volumes) whose drive is not the one chosen (simulated: this Mac's disk reached as
    /// /Volumes/<its name>, another volume there) or not connected at all is never written to, nor made: the failure
    /// says so, the backup is missed and made once the drive is back.
    func testANotConnectedDriveIsNeverWrittenTo() async throws {
        let m = try engineModel()
        m.papers = [try await paper(m, "Kelp drift", student: "Mei Lin")]
        let dir = try folder()
        let boot = try XCTUnwrap(BackupPlaces.volume(URL(fileURLWithPath: "/")).name)
        let onDrive = URL(fileURLWithPath: "/Volumes/" + boot + dir.path)
        guard fm.fileExists(atPath: onDrive.path) else { throw XCTSkip("this Mac's disk is not at /Volumes/\(boot)") }
        var clock = date("2026-10-14 10:00")
        m.backups.now = { clock }
        m.backups.use(onDrive)
        let drive = try XCTUnwrap(m.backups.state.volumeName)
        m.backups.volumeOf = { _ in "ANOTHER-DRIVE" }
        m.backups.backUp()
        try await settle(m)
        XCTAssertNil(m.backups.state.last)
        XCTAssertEqual(zips(dir), [])
        XCTAssertEqual(m.backups.state.failure?.message, "“\(drive)” isn’t connected.")
        XCTAssertEqual(m.backups.state.failure?.words(now: date("2026-10-14 18:00")), "Couldn’t back up today: “\(drive)” isn’t connected.")
        XCTAssertEqual(m.backups.state.failure?.words(now: date("2026-10-22 09:00")), "Couldn’t back up since Oct 14: “\(drive)” isn’t connected.")
        XCTAssertFalse(m.backups.due, "not tried again every minute")
        clock = date("2026-10-15 09:00")
        m.backups.backUp()
        try await settle(m)
        XCTAssertEqual(m.backups.state.failure?.since, date("2026-10-14 10:00"), "failing since the first")

        // the drive is back: the missed backup is made; a paper on a drive not connected is left out and said so
        let away = "/Volumes/PC-No-Such-Drive-\(UUID().uuidString.prefix(6))"
        let name = String(away.dropFirst("/Volumes/".count))
        m.papers.append(PaperRef(path: away + "/Reviews/Reef", title: "Reef", student: "Mei Lin"))
        m.backups.volumeOf = { BackupPlaces.volume($0).uuid }
        m.backups.driveConnected()
        XCTAssertTrue(m.backups.due)
        m.backups.backUp()
        try await settle(m)
        XCTAssertNil(m.backups.state.failure)
        XCTAssertEqual(zips(dir), ["Paperole Dev Backup 2026-10-15 0900.zip"])
        XCTAssertEqual(m.backups.state.last?.left, [name])
        XCTAssertTrue(m.backups.state.last?.words(now: clock).contains(" · 1 of 2 papers · ") == true,
                      m.backups.state.last?.words(now: clock) ?? "")
        XCTAssertEqual(m.backups.state.last?.leftWords, "Left out: 1 on “\(name)”, not connected.")
        var r = try XCTUnwrap(m.backups.state.last)
        r.left = ["", name, name]
        XCTAssertTrue(r.words(now: clock).contains(" · 1 of 4 papers · "))
        XCTAssertEqual(r.leftWords, "Left out: 2 on “\(name)”, not connected; 1 missing.")
        r.left = []
        XCTAssertNil(r.leftWords)

        // a folder on a drive that is not there: not made
        m.backups.use(URL(fileURLWithPath: away + "/Backups"))
        m.backups.backUp(manual: true)
        try await settle(m)
        XCTAssertEqual(m.backups.state.failure?.message, "“\(name)” isn’t connected.")
        XCTAssertFalse(fm.fileExists(atPath: away))
    }

    /// A folder outside /Volumes whose volume is another than the one recorded (this Mac's own disk, new after Migration
    /// Assistant or a restore onto a new disk) is no drive gone: its volume is recorded again, the backup made, and
    /// Restore from Last Backup… stays offered (the code review: every backup failed with "“Macintosh HD” isn't
    /// connected." after a move to a new Mac).
    func testAHomeFolderOnANewDiskIsRecordedAgain() async throws {
        let m = try engineModel()
        m.papers = [try await paper(m, "Kelp drift", student: "Mei Lin")]
        let dir = try folder()
        m.backups.now = { self.date("2026-10-20 09:00") }
        m.backups.use(dir)
        let name = m.backups.state.volumeName
        XCTAssertNotEqual(m.backups.state.volume, "NEW-MAC-DISK")
        m.backups.volumeOf = { _ in "NEW-MAC-DISK" }
        XCTAssertNil(m.backups.placeProblem())
        m.backups.backUp()
        try await settle(m)
        XCTAssertNil(m.backups.state.failure)
        XCTAssertEqual(zips(dir), ["Paperole Dev Backup 2026-10-20 0900.zip"])
        XCTAssertEqual(m.backups.state.volume, "NEW-MAC-DISK", "recorded again")
        XCTAssertEqual(m.backups.state.volumeName, name)
        XCTAssertEqual(m.backups.files.count, 1, "Restore from Last Backup… finds it")
    }

    /// A paper whose ledger.json is gone (its folder there: it reads as missing) is restored from the last backup: the
    /// backup's copy in its place, yours kept in "Replaced by Import", never a failed swap leaving an unlisted
    /// "Kelp drift 2" beside it (the code review's A5b-01; the engine's `swap_in` takes a folder without its ledger).
    func testARestoreOntoAFolderWhoseLedgerIsGone() async throws {
        let m = try engineModel()
        let kelp = try await paper(m, "Kelp drift", student: "Mei Lin")
        m.papers = [kelp]
        m.backups.use(try folder())
        m.backups.backUp(manual: true)
        try await settle(m)
        XCTAssertEqual(m.backups.files.count, 1)
        let ledger = URL(fileURLWithPath: kelp.path).appendingPathComponent("ledger.json")
        let good = try Data(contentsOf: ledger)
        try fm.removeItem(at: ledger)
        m.noteMissing()
        XCTAssertEqual(m.missingPapers, [kelp.path])
        XCTAssertTrue(m.backups.restorable(kelp))

        m.data.restoreFromBackup(kelp)
        try await settle(m)
        let plan = try XCTUnwrap(m.data.importing?.plan, m.data.importing?.error ?? "")
        XCTAssertEqual(plan.items.map(\.paper.status), ["yours_damaged"])
        XCTAssertEqual(plan.items.map(\.choice), [.useThis])
        m.data.performImport()
        try await settle(m)
        XCTAssertNil(m.data.importing?.report?.stopped, m.data.importing?.report?.stopped ?? "")
        XCTAssertEqual(try Data(contentsOf: ledger), good)
        let reviews = URL(fileURLWithPath: kelp.path).deletingLastPathComponent()
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: reviews.path).filter { !$0.hasPrefix(".") }.sorted(),
                       ["Kelp drift", "Replaced by Import"], "no unlisted copy beside it")
        m.noteMissing()
        XCTAssertEqual(m.missingPapers, [])
        m.data.closeImport()
    }

    // MARK: Rotation

    /// 7 daily, 4 weekly and 6 monthly, within 5 GB, the new one always; never a paper's last copy; of two made in the
    /// same second the new one stays.
    func testTheRotation() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let start = ISO8601DateFormatter().date(from: "2025-09-01T12:00:00Z")!
        func file(_ day: Int, _ papers: Set<String> = ["a"], gb: Int64 = 0) -> BackupFile {
            BackupFile(url: URL(fileURLWithPath: "/b/\(day).zip"), created: start.addingTimeInterval(Double(day) * 86400),
                       bytes: gb > 0 ? gb * 1_000_000_000 : 1_000_000, papers: papers, paths: [], ours: true)
        }
        let files = (0..<400).map { file($0) }
        let new = files.last!.url
        let gone = BackupRotation.plan(files, new: new, calendar: cal)
        let kept = Set(files.map(\.url)).subtracting(gone)
        func newest<K: Hashable>(_ n: Int, _ key: (Date) -> K) -> Set<URL> {
            var out: [K: URL] = [:], order: [K] = []
            for f in files.reversed() {
                let k = key(f.created)
                if out[k] == nil { out[k] = f.url; order.append(k) }
            }
            return Set(order.prefix(n).map { out[$0]! })
        }
        let want = newest(7) { cal.startOfDay(for: $0) }
            .union(newest(4) { d -> [Int] in let c = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: d); return [c.yearForWeekOfYear!, c.weekOfYear!] })
            .union(newest(6) { d -> [Int] in let c = cal.dateComponents([.year, .month], from: d); return [c.year!, c.month!] })
        XCTAssertEqual(kept, want)
        XCTAssertTrue(kept.isSuperset(of: files.suffix(7).map(\.url)), "the last 7 days")
        XCTAssertGreaterThan(want.count, 12)
        XCTAssertEqual(gone.first, files.first?.url, "oldest first")

        // within 5 GB: the oldest kept go first, the new one always
        let big = (0..<400).map { file($0, gb: 1) }
        XCTAssertEqual(Set(big.map(\.url)).subtracting(BackupRotation.plan(big, new: new, calendar: cal)),
                       Set(big.suffix(5).map(\.url)))
        let huge = [file(0), file(1, gb: 6)]
        XCTAssertEqual(BackupRotation.plan(huge, new: huge[1].url, calendar: cal), [huge[0].url])

        // the last copy of a paper is kept: b only in day 10's, c newest in day 30's (day 20's c is in it)
        var mixed = files
        mixed[10] = file(10, ["b"])
        mixed[20] = file(20, ["a", "c"])
        mixed[30] = file(30, ["c"])
        let left = Set(mixed.map(\.url)).subtracting(BackupRotation.plan(mixed, new: new, calendar: cal))
        XCTAssertTrue(left.contains(mixed[10].url))
        XCTAssertTrue(left.contains(mixed[30].url))
        XCTAssertFalse(left.contains(mixed[20].url))
        XCTAssertEqual(left, want.union([mixed[10].url, mixed[30].url]))

        // two in one second: the new one stays
        let a = file(0), b = BackupFile(url: URL(fileURLWithPath: "/b/new.zip"), created: a.created, bytes: 1, papers: ["a"], paths: [], ours: true)
        XCTAssertEqual(BackupRotation.plan([a, b], new: b.url, calendar: cal), [a.url])
        XCTAssertEqual(BackupRotation.plan([b, a], new: b.url, calendar: cal), [a.url])
    }

    /// Only this app's own automatic backups are deleted: never an export, Paperole's, another Mac's (another
    /// install id), a file that is not an export, nor a link; and never one holding a paper no newer backup holds.
    func testOnlyItsOwnBackupsAreRotated() async throws {
        let m = try engineModel()
        let kelp = try await paper(m, "Kelp drift", student: "Mei Lin")
        let pools = try await paper(m, "Warm pools", student: "Ana Sousa")
        let dir = try folder()
        let elsewhere = try folder("Elsewhere")
        func write(_ name: String, in d: URL, kind: String, variant: String? = nil, install: String? = nil) async throws {
            var p = m.data.archiveParams([kelp], dest: d.appendingPathComponent(name), everything: false, kind: kind)
            var made = p["made_by"] as? [String: Any] ?? [:]
            if let variant { made["variant"] = variant }
            if let install { made["install"] = install }
            p["made_by"] = made
            try await rpc(m, "archive_write", p)
        }
        try await write("export.zip", in: dir, kind: "export")
        try await write("official.zip", in: dir, kind: "automatic", variant: "Paperole")
        try await write("other mac.zip", in: dir, kind: "automatic", install: "i-another-mac")
        try await write("linked.zip", in: elsewhere, kind: "automatic")
        try fm.createSymbolicLink(at: dir.appendingPathComponent("link.zip"), withDestinationURL: elsewhere.appendingPathComponent("linked.zip"))
        try Data("notes".utf8).write(to: dir.appendingPathComponent("notes.zip"))
        let foreign = zips(dir)

        var clock = date("2026-10-20 09:00")
        m.backups.now = { clock }
        m.backups.use(dir)
        m.papers = [kelp, pools]
        m.backups.backUp(manual: true)
        try await settle(m)
        let first = try XCTUnwrap(m.backups.state.last?.file)
        // pools removed from the list: the first backup is its last copy
        m.papers = [kelp]
        clock = date("2026-10-20 09:05")
        m.backups.backUp(manual: true)
        try await settle(m)
        let second = try XCTUnwrap(m.backups.state.last?.file)
        XCTAssertEqual(Set(zips(dir)), Set(foreign + [first, second]))
        clock = date("2026-10-20 09:10")
        m.backups.backUp(manual: true)
        try await settle(m)
        let third = try XCTUnwrap(m.backups.state.last?.file)
        XCTAssertEqual(Set(zips(dir)), Set(foreign + [first, third]), "the second is in the third; the first holds Warm pools")
        XCTAssertTrue(fm.fileExists(atPath: elsewhere.appendingPathComponent("linked.zip").path))
        XCTAssertEqual(Set(m.backups.files.map(\.url.lastPathComponent)), ["export.zip", "official.zip", "other mac.zip", first, third],
                       "Paperole's files in the folder, for Restore; not a link, nor a file that is not one")
        XCTAssertEqual(m.backups.files.filter(\.ours).map(\.url.lastPathComponent).sorted(), [first, third].sorted())
    }

    // MARK: Failures

    /// A backup that fails says why in Settings (§28's error style), and nowhere else: no alert, no window line.
    func testAFailureIsSaidInSettingsOnly() async throws {
        let m = try engineModel()
        m.papers = [try await paper(m, "Kelp drift", student: "Mei Lin")]
        let dir = try folder()
        m.backups.use(dir)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        m.backups.backUp()
        try await settle(m)
        let f = try XCTUnwrap(m.backups.state.failure)
        XCTAssertEqual(f.message, "the folder can’t be written to.", "its path is on the Backup folder row, not again here")
        XCTAssertEqual(f.words(now: Date()), "Couldn’t back up today: the folder can’t be written to.")
        XCTAssertNil(m.alertMessage)
        XCTAssertNil(m.notice)
        XCTAssertEqual(m.data.status, nil, "not the tab's status line either")
        let shown = m.data.debugResult()["backups"] as? [String: Any]
        XCTAssertEqual(shown?["failure"] as? String, f.words(now: Date()))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        m.backups.backUp(manual: true)
        try await settle(m)
        XCTAssertNil(m.backups.state.failure, "gone with the next backup")
    }

    // MARK: The quiet check

    /// The check marks a damaged paper's row (not a sound one, nor leftovers); Restore from Last Backup… is offered only
    /// while backups are on and one holds the paper, and opens the import preview with only that paper ticked; the
    /// paper restored, its mark goes.
    func testTheCheckMarksADamagedPaperAndItIsRestored() async throws {
        let m = try engineModel()
        let kelp = try await paper(m, "Kelp drift", student: "Mei Lin")
        let pools = try await paper(m, "Warm pools", student: "Ana Sousa")
        m.papers = [kelp, pools]
        let dir = try folder()
        for item in ["backup on \(dir.path)", "backup now"] {
            let done = expectation(description: item)
            m.data.debug(item) { _ in done.fulfill() }
            await fulfillment(of: [done], timeout: 60)
        }
        XCTAssertNotNil(m.backups.state.last)
        XCTAssertEqual(m.backups.files.count, 1)
        let ledger = URL(fileURLWithPath: kelp.path).appendingPathComponent("ledger.json")
        let good = try Data(contentsOf: ledger)

        try Data("{".utf8).write(to: ledger)
        let leftover = URL(fileURLWithPath: pools.path).appendingPathComponent(".ledger.json.x.tmp")
        try Data("x".utf8).write(to: leftover)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: leftover.path)
        m.backups.checkFolders()
        try await settle(m)
        XCTAssertEqual(Array(m.damagedPapers.keys), [kelp.path], "a temporary file left over is no damage")
        XCTAssertFalse(m.damagedPapers[kelp.path]?.isEmpty ?? true)
        XCTAssertTrue(m.backups.restorable(kelp))
        XCTAssertFalse(m.backups.restorable(pools))
        XCTAssertEqual(m.data.debugResult()["damaged"] as? [String], [kelp.path])

        m.data.restoreFromBackup(kelp)
        try await settle(m)
        let plan = try XCTUnwrap(m.data.importing?.plan, m.data.importing?.error ?? "")
        XCTAssertEqual(plan.items.map(\.paper.title), ["Kelp drift", "Warm pools"])
        XCTAssertEqual(plan.items.map(\.paper.status), ["yours_damaged", "same"])
        XCTAssertEqual(plan.items.map(\.choice), [.useThis, .keepMine], "only that paper ticked")
        XCTAssertFalse(plan.useSettings)
        m.data.performImport()
        try await settle(m)
        XCTAssertNil(m.data.importing?.report?.stopped)
        XCTAssertFalse(m.data.importing?.report?.groups.contains { $0.title.hasPrefix("Kept yours") } ?? true,
                       "a restore of one paper leaves the file's others unsaid")
        XCTAssertEqual(try Data(contentsOf: ledger), good)
        try await settle(m)
        XCTAssertEqual(m.damagedPapers, [:], "checked again: its mark is gone")
        m.data.closeImport()

        // a folder gone: offered too, from this app's own backups only (never Paperole Dev's in Paperole);
        // never while backups are off
        try fm.removeItem(atPath: pools.path)
        m.noteMissing()
        XCTAssertTrue(m.backups.restorable(pools))
        XCTAssertEqual(m.backups.holding(pools)?.variant, AppVariant.current.name, "by its name")
        let other = BackupFile.make(["path": "/b/x.zip", "backup": ["app": "PaperCollab", "schema": 2, "kind": "automatic",
                                                                   "created": "2026-10-22T09:00:00+08:00",
                                                                   "made_by": ["variant": "PaperCollab", "install": "i-1"],
                                                                   "papers": [["id": "p-1", "was_at": "/r/a"]]]],
                                    variant: "Paperole Dev", install: "i-1")
        XCTAssertEqual(other?.variant, "PaperCollab")
        XCTAssertEqual(other?.ours, false, "the official app's, from before the rename")
        // made before the rename (2026-10-27: "PaperCollab" files, "PaperCollab Dev Backup …"), or after: this app's own
        // either way, by backup.json alone
        for (name, app, variant) in [("PaperCollab Dev Backup 2026-10-20 0900.zip", "PaperCollab", "PaperCollab Dev"),
                                     ("Paperole Dev Backup 2026-10-28 0900.zip", "Paperole", "Paperole Dev"),
                                     ("x.zip", "Paperole", "PaperCollab Dev")] {
            let mine = BackupFile.make(["path": "/b/" + name, "backup": ["app": app, "schema": 2, "kind": "automatic",
                                                                       "created": "2026-10-22T09:00:00+08:00",
                                                                       "made_by": ["variant": variant, "install": "i-1"],
                                                                       "papers": [["id": "p-1", "was_at": "/r/a"]]]],
                                       variant: AppVariant.current.name, install: "i-1")
            XCTAssertEqual(mine?.ours, true, name)
            XCTAssertEqual(mine.flatMap { AppVariant(stored: $0.variant) }, AppVariant.current, name)
        }
        XCTAssertNil(BackupFile.make(["path": "/b/y.zip", "backup": ["app": "Other", "schema": 2, "kind": "automatic",
                                                                     "created": "2026-10-22T09:00:00+08:00"]],
                                     variant: AppVariant.current.name, install: "i-1"), "not a Paperole export")
        m.backups.turnOff()
        XCTAssertFalse(m.backups.restorable(pools))
        XCTAssertNil(m.backups.holding(pools))
    }
}
