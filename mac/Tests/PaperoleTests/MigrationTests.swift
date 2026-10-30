import AppKit
import XCTest
@testable import Paperole

/// The move of the app's data to its new name (Migration.swift; UX.md §34; the advisor's decision of 2026-10-27), on a
/// Mac made up in a temporary folder: Application Support, Caches and a home folder of its own, the settings domains in
/// memory. Never a real place, never a real defaults domain, never the real gate's bundle.
final class MigrationTests: XCTestCase {
    private let fm = FileManager.default
    private var tmp: URL!
    private var roots: DataHome.Roots!

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("pc-migration-" + UUID().uuidString).resolvingSymlinksInPath()
        roots = DataHome.Roots(support: tmp.appendingPathComponent("Support"), caches: tmp.appendingPathComponent("Caches"),
                               home: tmp.appendingPathComponent("home"))
        for u in [roots.support, roots.caches, roots.home] { try fm.createDirectory(at: u, withIntermediateDirectories: true) }
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: tmp) }

    /// Settings domains in memory: what each holds, and every write.
    final class Domains {
        var values: [String: [String: Any]] = [:]
        var written: [String] = []
        /// A write that does not stick (the domain reads back as it was).
        var lose: String?
        var io: DefaultsIO {
            DefaultsIO(read: { self.values[$0] }, write: { d, v in
                self.written.append(d)
                if self.lose != d { self.values[d] = v }
            }, remove: { d in
                self.written.append(d)
                self.values[d] = nil
            })
        }
    }

    /// The disk's operations with faults: a rename or a write made to fail once, or every change and read failing from
    /// that point on (`dieAfterFault`: the app killed there, nothing more happens), or another disk.
    final class Faults {
        var rename: ((URL, URL) -> Bool)?
        var write: ((URL, Data) -> Bool)?
        var dead = false
        var device: ((URL) -> Int?)?
        /// What a place is said to be instead of what it is (nil: as it is).
        var kind: ((URL) -> MigrationFS.Kind?)?
        var dieAfterFault = false
        var fs: MigrationFS {
            let real = MigrationFS.disk
            var f = real
            func fault() -> Error {
                if dieAfterFault { dead = true }
                return DataFailure(message: "an injected fault")
            }
            f.renameExclusive = { a, b in
                if self.dead { throw DataFailure(message: "dead") }
                if self.rename?(a, b) == true {
                    self.rename = nil
                    throw fault()
                }
                try real.renameExclusive(a, b)
            }
            f.write = { d, u in
                if self.dead { throw DataFailure(message: "dead") }
                if self.write?(u, d) == true {
                    self.write = nil
                    throw fault()
                }
                try real.write(d, u)
            }
            f.read = { u in
                if self.dead { throw DataFailure(message: "dead") }
                return try real.read(u)
            }
            f.makeFolder = { u in
                if self.dead { throw DataFailure(message: "dead") }
                try real.makeFolder(u)
            }
            f.device = { u in self.device.map { $0(u) } ?? real.device(u) }
            f.kind = { u in self.kind?(u) ?? real.kind(u) }
            return f
        }
    }

    // MARK: A Mac as Paperole Dev left it

    private var oldS: URL { roots.support.appendingPathComponent("PaperCollab Dev") }
    private var newS: URL { roots.support.appendingPathComponent("Paperole Dev") }
    private var oldR: URL { roots.home.appendingPathComponent("PaperCollab Dev Reviews") }
    private var newR: URL { roots.home.appendingPathComponent("Paperole Dev Reviews") }
    private var oldC: URL { roots.caches.appendingPathComponent("PaperCollab Dev") }
    private var newC: URL { roots.caches.appendingPathComponent("Paperole Dev") }

    private func paper(_ u: URL) throws {
        try fm.createDirectory(at: u.appendingPathComponent("r1"), withIntermediateDirectories: true)
        try Data("{\"paper\": {\"id\": \"p-\(u.lastPathComponent.count)\"}}".utf8).write(to: u.appendingPathComponent("ledger.json"))
    }

    /// Four papers (two in the review folder, one elsewhere, one in a folder whose name only starts the same), their
    /// drafts (two, and one that cannot be read), the tags, a day's copy of the list, the thumbnails, and the settings:
    /// where Paperole Dev left off, where new folders go, a backup folder elsewhere, its install id, The Round chosen.
    private func oldDev(newDomain: [String: Any]? = nil) throws -> Domains {
        let a = oldR.appendingPathComponent("Kelp drift"), b = oldR.appendingPathComponent("Warm pools")
        let c = roots.home.appendingPathComponent("Elsewhere/Other")
        let d = roots.home.appendingPathComponent("PaperCollab Dev Reviews2/Sibling")
        for u in [a, b, c, d] { try paper(u) }
        try fm.createDirectory(at: oldS, withIntermediateDirectories: true)
        let papers = [PaperRef(path: a.path, title: "Kelp drift", student: "Mei Lin", keyPage: KeyPageChoice(round: 1, page: 2)),
                      PaperRef(path: b.path, title: "Warm pools", student: "Lin Zhou", ledgerID: "p-10"),
                      PaperRef(path: c.path, title: "Other", student: "Maya Chen"),
                      PaperRef(path: d.path, title: "Sibling", student: "Leo Park", finished: "2026-10-01")]
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try enc.encode(papers).write(to: oldS.appendingPathComponent("papers.json"))
        try fm.createDirectory(at: oldS.appendingPathComponent("papers copies"), withIntermediateDirectories: true)
        try enc.encode(papers).write(to: oldS.appendingPathComponent("papers copies/papers 2026-10-26.json"))
        try Data("{\"schema\": 1, \"tags\": []}".utf8).write(to: oldS.appendingPathComponent("tags.json"))
        let drafts = DraftStore(directory: oldS.appendingPathComponent("drafts"))
        drafts.save(paper: a.path, round: 2, drafts: ["R1-01": "Say which beach."])
        drafts.save(paper: c.path, round: 1, drafts: ["R1-02": "Shorter."])
        try Data("not json".utf8).write(to: oldS.appendingPathComponent("drafts/0000000000000000.json"))
        try fm.createDirectory(at: oldC.appendingPathComponent("Thumbnails/ab"), withIntermediateDirectories: true)
        try Data("png".utf8).write(to: oldC.appendingPathComponent("Thumbnails/ab/1.png"))
        let place = LastPlace(paper: a.path, level: "review", round: 2, comment: "R1-01").json()!
        let backups = String(decoding: try JSONEncoder().encode(BackupState(on: true, folder: roots.home.appendingPathComponent("Backups").path)), as: UTF8.self)
        let domains = Domains()
        domains.values[AppVariant.oldDevID] = [
            LastPlace.key: place, "reviewFolderRoot": oldR.path, "backups": backups, "installID": "i-0123456789abcdef",
            "appIcon": "round", "appIconStyle": "dark", "foldedStudents": ["Mei Lin"], "readingMarks": true,
            "NSWindow Frame main": "0 0 1440 900 0 0 1728 1079 ",
        ]
        if let newDomain { domains.values[AppVariant.devID] = newDomain }
        return domains
    }

    private func context(_ domains: Domains, _ v: AppVariant = .dev, fs: MigrationFS = .disk) -> Migration.Context {
        Migration.Context(variant: v, roots: roots, fs: fs, defaults: domains.io, now: { Date(timeIntervalSince1970: 1_793_000_000) },
                          version: "0.1 1")
    }

    /// Every file and folder under the temporary Mac: its contents (a folder: "/", a link: "->" its target).
    private func tree(skip: (String) -> Bool = { _ in false }) -> [String: Data] {
        var out: [String: Data] = [:]
        let base = tmp.path + "/"
        let e = fm.enumerator(atPath: tmp.path)
        while let rel = e?.nextObject() as? String {
            guard !skip(rel) else { continue }
            let full = base + rel
            if let target = try? fm.destinationOfSymbolicLink(atPath: full) {
                out[rel] = Data(("->" + target).utf8)
            } else if (try? fm.attributesOfItem(atPath: full)[.type] as? FileAttributeType) == .typeDirectory {
                out[rel] = Data("/".utf8)
            } else {
                out[rel] = fm.contents(atPath: full)
            }
        }
        return out
    }

    /// The tree before, less what a migration that did not happen adds: its copies, journal and log in the old folder.
    private func untouched(_ before: [String: Data]) -> Bool {
        tree { $0.contains("/" + Migration.prePrefix) || $0.hasSuffix("/" + Migration.journalName) || $0.hasSuffix("/" + Migration.logName) }
            == before
    }

    /// A DataHome as its paths (URLs of folders may end in "/" or not, as the disk was when they were made).
    private func at(_ h: DataHome) -> [String] { [h.support.path, h.caches.path, h.reviews.path, h.both ? "both" : ""] }
    private func home(_ s: URL, _ c: URL, _ r: URL, both: Bool = false) -> [String] { [s.path, c.path, r.path, both ? "both" : ""] }

    private func inode(_ u: URL) -> Int? { (try? fm.attributesOfItem(atPath: u.path)[.systemFileNumber] as? Int) ?? nil }

    private func papers(_ folder: URL) throws -> [PaperRef] {
        try JSONDecoder().decode([PaperRef].self, from: Data(contentsOf: folder.appendingPathComponent("papers.json")))
    }

    private func draftFiles(_ folder: URL) -> [String: [String: Any]] {
        var out: [String: [String: Any]] = [:]
        for f in (try? fm.contentsOfDirectory(at: folder.appendingPathComponent("drafts"), includingPropertiesForKeys: nil)) ?? [] {
            out[f.lastPathComponent] = (try? Data(contentsOf: f)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
        }
        return out
    }

    private func equal(_ a: [String: Any]?, _ b: [String: Any]?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return NSDictionary(dictionary: a).isEqual(to: b)
    }

    // MARK: The gate

    /// Only a real launch of one of the two installed bundles: the exact id, the exact place (a link resolved), no
    /// argument but the system's -psn_, never a test run nor `swift test`. A test bundle (APP_OUT), a worktree's build,
    /// the old ids and `swift run` never.
    func testTheGate() throws {
        let dev = Migration.devBundle, official = Migration.officialBundle
        XCTAssertEqual(dev.path, EngineClient.checkoutRoot.appendingPathComponent("mac/build/Paperole Dev.app").path)
        XCTAssertTrue(dev.path.hasSuffix("/mac/build/Paperole Dev.app"))
        XCTAssertEqual(official.path, "/Applications/Paperole.app")
        func gate(_ id: String?, _ url: URL, _ args: [String] = ["x"], unit: Bool = false, test: Bool = false,
                  main: Bool = true) -> AppVariant? {
            Migration.gate(bundleID: id, bundleURL: url, arguments: args, unitTest: unit, testRun: test, mainCheckout: main)
        }
        XCTAssertEqual(gate("com.paperole.app.dev", dev), .dev)
        XCTAssertEqual(gate("com.paperole.app", official), .official)
        XCTAssertEqual(gate("com.paperole.app", official, ["x", "-psn_0_12345"]), .official, "the system's own argument")
        XCTAssertNil(gate("com.paperole.app", dev), "the official id at Dev's place")
        XCTAssertNil(gate("com.paperole.app.dev", official))
        XCTAssertNil(gate("com.paperole.app.dev", dev, main: false), "a linked worktree's dev build")
        XCTAssertEqual(gate("com.paperole.app", official, main: false), .official)
        for args in [["x", "--background"], ["x", "--paper", "/p"], ["x", "--no-list"], ["x", "--fixture", "/f"],
                     ["x", "--debug-script", "quit"], ["x", "--list", "/l"], ["x", "-NSDocumentRevisionsDebugMode", "YES"]] {
            XCTAssertNil(gate("com.paperole.app.dev", dev, args), args.joined(separator: " "))
        }
        XCTAssertNil(gate("com.paperole.app.dev", dev, unit: true), "swift test")
        XCTAssertNil(gate("com.paperole.app.dev", dev, test: true), "a test run")
        for id in [nil, "", "com.papercollab.app.dev", "com.papercollab.app", "com.paperole.app.dev ", "com.example"] as [String?] {
            XCTAssertNil(gate(id, dev), id ?? "nil")
            XCTAssertNil(gate(id, official), id ?? "nil")
        }
        let checkout = EngineClient.checkoutRoot.path, home = NSHomeDirectory()
        for place in ["/private/tmp/x/Paperole Dev.app", checkout + "/mac/build/PaperCollab Dev.app",
                      checkout + "-wt/mac/build/Paperole Dev.app", "/Applications/Paperole Dev.app",
                      home + "/Applications/Paperole.app"] {
            XCTAssertNil(gate("com.paperole.app.dev", URL(fileURLWithPath: place)), place)
            XCTAssertNil(gate("com.paperole.app", URL(fileURLWithPath: place)), place)
        }
        XCTAssertNil(gate("com.paperole.app.dev", Bundle.main.bundleURL), "this test runner")
        // a link to elsewhere named as the place is not the place
        let link = tmp.appendingPathComponent("Paperole Dev.app")
        try fm.createSymbolicLink(at: link, withDestinationURL: tmp.appendingPathComponent("elsewhere.app"))
        XCTAssertNil(gate("com.paperole.app.dev", link))
        // this run
        XCTAssertNil(Migration.gate(bundleID: Bundle.main.bundleIdentifier, bundleURL: Bundle.main.bundleURL,
                                    arguments: CommandLine.arguments, unitTest: LaunchOptions.unitTest, testRun: LaunchOptions.isTestRun))
    }

    /// Another copy of the same app running, by either id (an agent's test bundle, the old PaperCollab Dev) or, for
    /// Dev, `swift run`'s binary: named, and nothing is moved. The other app never counts, nor this process.
    func testAnotherCopyRunning() {
        let apps = [Migration.Running(pid: 10, id: "com.paperole.app.dev", executable: "PaperoleDev", name: "Paperole Dev"),
                    Migration.Running(pid: 11, id: "com.papercollab.app.dev", executable: "PaperCollabDev", name: "PaperCollab Dev"),
                    Migration.Running(pid: 12, id: nil, executable: "Paperole", name: nil),
                    Migration.Running(pid: 13, id: "com.paperole.app", executable: "Paperole", name: "Paperole"),
                    Migration.Running(pid: 14, id: "com.papercollab.app", executable: "PaperCollab", name: "PaperCollab"),
                    Migration.Running(pid: 15, id: "com.apple.finder", executable: "Finder", name: "Finder")]
        XCTAssertEqual(Migration.others(.dev, in: apps, me: 10), ["PaperCollab Dev", "Paperole"])
        XCTAssertEqual(Migration.others(.dev, in: apps, me: 99), ["Paperole Dev", "PaperCollab Dev", "Paperole"])
        XCTAssertEqual(Migration.others(.official, in: apps, me: 13), ["PaperCollab"])
        XCTAssertEqual(Migration.others(.official, in: Array(apps.suffix(1)), me: 1), [])
        XCTAssertEqual(Migration.others(.dev, in: [apps[3], apps[4], apps[5]], me: 1), [], "the official app may run")
    }

    // MARK: Paths

    /// The old review folder's path for the new one: the folder or a path inside it, never a sibling whose name starts
    /// the same; in settings, inside JSON strings too, the rest of them as they were.
    func testThePathRewrite() throws {
        let old = "/Users/a/PaperCollab Dev Reviews", new = "/Users/a/Paperole Dev Reviews"
        XCTAssertEqual(Migration.moved(old, from: old, to: new), new)
        XCTAssertEqual(Migration.moved(old + "/Kelp drift", from: old, to: new), new + "/Kelp drift")
        XCTAssertEqual(Migration.moved(old + "/", from: old, to: new), new + "/")
        for s in [old + "2/Kelp", old + " old", "/Users/a/PaperCollab Dev", "x" + old, "", "Kelp drift"] {
            XCTAssertNil(Migration.moved(s, from: old, to: new), s)
        }
        XCTAssertEqual(Migration.rewrite(old + "/K", from: old, to: new) as? String, new + "/K")
        XCTAssertEqual(Migration.rewrite([old, "x", old + "2"], from: old, to: new) as? [String], [new, "x", old + "2"])
        XCTAssertEqual(Migration.rewrite(42, from: old, to: new) as? Int, 42)
        let place = LastPlace(paper: old + "/Kelp drift", level: "review", round: 2).json()!
        XCTAssertTrue(place.contains("\\/"), "JSONEncoder escapes slashes")
        let moved = try XCTUnwrap(Migration.rewrite(place, from: old, to: new) as? String)
        XCTAssertEqual(LastPlace.parse(moved)?.paper, new + "/Kelp drift")
        XCTAssertEqual(LastPlace.parse(moved)?.round, 2)
        let other = LastPlace(paper: "/Users/a/Elsewhere/K", level: "review").json()!
        XCTAssertEqual(Migration.rewrite(other, from: old, to: new) as? String, other, "unchanged, byte for byte")
        let json = "{\"folder\":\"\(old)/B\",\"unknown\":{\"deep\":[\"\(old)\"]},\"n\":1.5,\"on\":true}"
        let back = try XCTUnwrap(Migration.rewrite(json, from: old, to: new) as? String)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(back.utf8)) as? [String: Any])
        XCTAssertEqual(obj["folder"] as? String, new + "/B")
        XCTAssertEqual((obj["unknown"] as? [String: Any])?["deep"] as? [String], [new], "unknown fields kept, walked")
        XCTAssertEqual(obj["n"] as? Double, 1.5)
        XCTAssertEqual(obj["on"] as? Bool, true)
        XCTAssertEqual(Migration.rewrite("{not json", from: old, to: new) as? String, "{not json")
    }

    /// The app's own settings, as their owners name them: a new domain with any of them is never written over.
    func testTheAppsKeys() {
        MainActor.assumeIsolated {
            for k in [AppIconModel.styleKey, AppModel.mapAsTableKey, AppModel.foldedStudentsKey, AppModel.readingMarksKey,
                      AppModel.foldPartsKey, AppModel.openAtLaunchKey, ListGrouping.key, BackupModel.key, DataModel.reviewRootKey,
                      LastPlace.key, TagModel.suggestKey] {
                XCTAssertTrue(Migration.appKeys.contains(k), k)
            }
        }
        XCTAssertEqual(Migration.droppedKeys, ["appIcon"])
    }

    // MARK: Moving

    /// Nothing of the old app: nothing done, nothing made; the new names.
    func testNothingToMove() {
        let d = Domains()
        XCTAssertEqual(Migration.run(context(d)), .nothing)
        XCTAssertEqual(Set(try fm.contentsOfDirectory(atPath: roots.support.path)), [])
        XCTAssertTrue(d.written.isEmpty)
        XCTAssertEqual(at(DataHome.resolve(.dev, roots: roots, fs: .disk)), home(newS, newC, newR))
        XCTAssertEqual(at(DataHome.resolve(.official, roots: roots, fs: .disk)),
                       home(roots.support.appendingPathComponent("Paperole"), roots.caches.appendingPathComponent("Paperole"),
                            roots.home.appendingPathComponent("Reviews")))
    }

    /// Paperole Dev's first launch: its data folder, review folder and thumbnails renamed (the same folders, not
    /// copies), the two papers in the review folder listed at their new places and nothing else changed, their drafts
    /// renamed for them, the settings copied with the paths in them rewritten (The Round's choice left behind); the
    /// old domain never written; copies of everything rewritten; a log and the marker. Then the same launch again
    /// changes nothing.
    func testTheDevAppsFirstLaunch() throws {
        let d = try oldDev()
        let before = tree()
        let inodes = [oldS, oldR, oldC].map(inode)
        let oldList = try Data(contentsOf: oldS.appendingPathComponent("papers.json"))
        let oldDrafts = draftFiles(oldS)
        XCTAssertEqual(at(DataHome.resolve(.dev, roots: roots, fs: .disk)), home(oldS, oldC, oldR), "before: the old places")
        XCTAssertEqual(Migration.run(context(d)), .moved(reviews: true, defaults: true))

        XCTAssertFalse(fm.fileExists(atPath: oldS.path))
        XCTAssertFalse(fm.fileExists(atPath: oldR.path))
        XCTAssertFalse(fm.fileExists(atPath: oldC.path))
        XCTAssertEqual([newS, newR, newC].map(inode), inodes, "renamed, never copied")
        XCTAssertEqual(at(DataHome.resolve(.dev, roots: roots, fs: .disk)), home(newS, newC, newR))
        // the list: only the two in the review folder, at their new places; the rest as it was
        let list = try papers(newS)
        XCTAssertEqual(list.map(\.path), [newR.appendingPathComponent("Kelp drift").path, newR.appendingPathComponent("Warm pools").path,
                                          roots.home.appendingPathComponent("Elsewhere/Other").path,
                                          roots.home.appendingPathComponent("PaperCollab Dev Reviews2/Sibling").path])
        var expected = try JSONDecoder().decode([PaperRef].self, from: oldList)
        expected[0].path = list[0].path
        expected[1].path = list[1].path
        XCTAssertEqual(list, expected, "titles, students, key pages, ids and facts as they were")
        for p in list { XCTAssertTrue(fm.fileExists(atPath: p.path + "/ledger.json"), p.path) }
        // the drafts: Kelp drift's under the name of its new path, saying it; Other's and the unreadable one as they were
        let store = DraftStore(directory: newS.appendingPathComponent("drafts"))
        XCTAssertEqual(store.load(paper: list[0].path, round: 2), ["R1-01": "Say which beach."])
        XCTAssertEqual(store.load(paper: list[2].path, round: 1), ["R1-02": "Shorter."])
        let drafts = draftFiles(newS)
        XCTAssertEqual(drafts.count, 3)
        XCTAssertNil(drafts[DraftStore(directory: oldS).url(paper: oldR.appendingPathComponent("Kelp drift").path).lastPathComponent])
        XCTAssertEqual(try Data(contentsOf: newS.appendingPathComponent("drafts/0000000000000000.json")), Data("not json".utf8))
        // everything else in the folders as it was
        XCTAssertEqual(try Data(contentsOf: newS.appendingPathComponent("tags.json")), before["Support/PaperCollab Dev/tags.json"])
        XCTAssertEqual(try Data(contentsOf: newS.appendingPathComponent("papers copies/papers 2026-10-26.json")),
                       before["Support/PaperCollab Dev/papers copies/papers 2026-10-26.json"], "history")
        XCTAssertEqual(try Data(contentsOf: newC.appendingPathComponent("Thumbnails/ab/1.png")), Data("png".utf8))
        XCTAssertEqual(try Data(contentsOf: newR.appendingPathComponent("Kelp drift/ledger.json")),
                       before["home/PaperCollab Dev Reviews/Kelp drift/ledger.json"], "ledgers never rewritten")
        // the settings: copied, rewritten, The Round's choice dropped, marked; the old domain never written
        let new = try XCTUnwrap(d.values[AppVariant.devID])
        XCTAssertEqual(d.written, [AppVariant.devID])
        XCTAssertEqual(new["reviewFolderRoot"] as? String, newR.path)
        XCTAssertEqual(LastPlace.parse(new[LastPlace.key] as? String)?.paper, list[0].path)
        XCTAssertEqual(LastPlace.parse(new[LastPlace.key] as? String)?.comment, "R1-01")
        XCTAssertEqual(new["backups"] as? String, d.values[AppVariant.oldDevID]?["backups"] as? String, "a backup folder elsewhere: as it was")
        XCTAssertEqual(new["installID"] as? String, "i-0123456789abcdef", "the same install: its automatic backups still rotate")
        XCTAssertEqual(new["appIconStyle"] as? String, "dark")
        XCTAssertEqual(new["foldedStudents"] as? [String], ["Mei Lin"])
        XCTAssertEqual(new["NSWindow Frame main"] as? String, "0 0 1440 900 0 0 1728 1079 ")
        XCTAssertNil(new["appIcon"])
        XCTAssertEqual((new[Migration.markerKey] as? [String: String])?["id"], AppVariant.oldDevID)
        XCTAssertEqual(Set(new.keys), Set(d.values[AppVariant.oldDevID]!.keys).subtracting(["appIcon"]).union([Migration.markerKey]))
        // the copies: byte for byte what was rewritten, and both domains as they were
        let pres = try fm.contentsOfDirectory(atPath: newS.path).filter { $0.hasPrefix(Migration.prePrefix) }
        XCTAssertEqual(pres.count, 1)
        let pre = newS.appendingPathComponent(pres[0])
        XCTAssertEqual(try Data(contentsOf: pre.appendingPathComponent("papers.json")), oldList)
        let kelp = DraftStore(directory: oldS).url(paper: oldR.appendingPathComponent("Kelp drift").path).lastPathComponent
        XCTAssertEqual(try Data(contentsOf: pre.appendingPathComponent("drafts/" + kelp)), before["Support/PaperCollab Dev/drafts/" + kelp])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: pre.appendingPathComponent("drafts").path), [kelp], "only what was rewritten")
        let oldCopy = try PropertyListSerialization.propertyList(from: Data(contentsOf: pre.appendingPathComponent("defaults-com.papercollab.app.dev.plist")),
                                                                 format: nil) as? [String: Any]
        XCTAssertTrue(equal(oldCopy, d.values[AppVariant.oldDevID]))
        let newCopy = try PropertyListSerialization.propertyList(from: Data(contentsOf: pre.appendingPathComponent("defaults-com.paperole.app.dev.plist")),
                                                                 format: nil) as? [String: Any]
        XCTAssertEqual(newCopy?.count, 0)
        XCTAssertEqual(oldDrafts.count, 3)
        // the marker and the log
        let marker = try XCTUnwrap(Migration.marker(newS, fs: .disk))
        XCTAssertEqual(marker.state, "done")
        XCTAssertEqual(marker.reviews, [oldR.path, newR.path])
        XCTAssertEqual(marker.steps, ["support", "reviews", "papers", "drafts", "defaults"])
        XCTAssertEqual(marker.version, "0.1 1")
        let log = try String(contentsOf: newS.appendingPathComponent(Migration.logName), encoding: .utf8)
        XCTAssertTrue(log.contains("papers.json: 2 of 4 papers' places rewritten"), log)
        XCTAssertTrue(log.contains("drafts: 1 renamed"), log)
        XCTAssertTrue(log.contains("draft 0000000000000000.json could not be read: left as it is"), log)
        XCTAssertTrue(log.hasSuffix(" done\n"), log)
        XCTAssertEqual(try Data(contentsOf: pre.appendingPathComponent(Migration.logName)), Data(log.utf8))

        // again: nothing
        let after = tree(), domain = d.values
        XCTAssertEqual(Migration.run(context(d)), .nothing)
        XCTAssertEqual(tree(), after)
        XCTAssertTrue(equal(d.values[AppVariant.devID], domain[AppVariant.devID]))
        XCTAssertEqual(d.written, [AppVariant.devID])
        // an old app opened afterwards makes its folders again: never used, never touched
        try fm.createDirectory(at: oldS, withIntermediateDirectories: true)
        try fm.createDirectory(at: oldR, withIntermediateDirectories: true)
        XCTAssertEqual(Migration.run(context(d)), .nothing)
        XCTAssertEqual(at(DataHome.resolve(.dev, roots: roots, fs: .disk)), home(newS, newC, newR))
    }

    /// The official app's first launch: its data folder and thumbnails renamed and its settings copied; ~/Reviews and
    /// the list's places as they were (papers.json copied all the same).
    func testTheOfficialAppsFirstLaunch() throws {
        let support = roots.support.appendingPathComponent("PaperCollab"), reviews = roots.home.appendingPathComponent("Reviews")
        try paper(reviews.appendingPathComponent("Kelp drift"))
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        let list = try JSONEncoder().encode([PaperRef(path: reviews.appendingPathComponent("Kelp drift").path, title: "K", student: "S")])
        try list.write(to: support.appendingPathComponent("papers.json"))
        try fm.createDirectory(at: roots.caches.appendingPathComponent("PaperCollab"), withIntermediateDirectories: true)
        let d = Domains()
        d.values[AppVariant.oldOfficialID] = ["installID": "i-1", "appIcon": "round-pilcrow", LastPlace.key: "{\"hub\":\"all\"}"]
        XCTAssertEqual(Migration.run(context(d, .official)), .moved(reviews: false, defaults: true))
        let new = roots.support.appendingPathComponent("Paperole")
        XCTAssertEqual(try Data(contentsOf: new.appendingPathComponent("papers.json")), list, "not rewritten")
        XCTAssertTrue(fm.fileExists(atPath: reviews.appendingPathComponent("Kelp drift/ledger.json").path))
        XCTAssertTrue(fm.fileExists(atPath: roots.caches.appendingPathComponent("Paperole").path))
        XCTAssertEqual(d.values[AppVariant.officialID]?["installID"] as? String, "i-1")
        XCTAssertNil(d.values[AppVariant.officialID]?["appIcon"])
        XCTAssertEqual(d.written, [AppVariant.officialID])
        XCTAssertEqual(Migration.marker(new, fs: .disk)?.state, "done")
        XCTAssertNil(Migration.marker(new, fs: .disk)?.reviews)
        let pre = try XCTUnwrap(try fm.contentsOfDirectory(atPath: new.path).first { $0.hasPrefix(Migration.prePrefix) })
        XCTAssertEqual(try Data(contentsOf: new.appendingPathComponent(pre + "/papers.json")), list)
        XCTAssertEqual(at(DataHome.resolve(.official, roots: roots, fs: .disk)),
                       home(new, roots.caches.appendingPathComponent("Paperole"), reviews))
    }

    /// Never over or into anything there: both data folders and no marker, nothing moved, the old one used and the
    /// advisor told once; the new review folder there already, the review folder left (and its paths), the data folder
    /// moved all the same.
    func testNeverOverAnythingThere() throws {
        let d = try oldDev()
        try fm.createDirectory(at: newS, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: newS.appendingPathComponent("papers.json"))
        let before = tree()
        XCTAssertEqual(Migration.run(context(d)), .both(first: true))
        XCTAssertEqual(Migration.run(context(d)), .both(first: false), "said once")
        XCTAssertTrue(untouched(before))
        XCTAssertTrue(d.written.isEmpty)
        XCTAssertEqual(at(DataHome.resolve(.dev, roots: roots, fs: .disk)), home(oldS, oldC, oldR, both: true))

        try fm.removeItem(at: newS)
        try fm.createDirectory(at: newR, withIntermediateDirectories: true)
        let list = try Data(contentsOf: oldS.appendingPathComponent("papers.json"))
        XCTAssertEqual(Migration.run(context(d)), .moved(reviews: false, defaults: true))
        XCTAssertTrue(fm.fileExists(atPath: oldR.appendingPathComponent("Kelp drift/ledger.json").path))
        XCTAssertEqual(try Data(contentsOf: newS.appendingPathComponent("papers.json")), list, "the paths not rewritten")
        XCTAssertEqual(d.values[AppVariant.devID]?["reviewFolderRoot"] as? String, oldR.path)
        XCTAssertEqual(at(DataHome.resolve(.dev, roots: roots, fs: .disk)), home(newS, newC, oldR))
        let log = try String(contentsOf: newS.appendingPathComponent(Migration.logName), encoding: .utf8)
        XCTAssertTrue(log.contains("the review folder is not moved: \(newR.path) is there already"), log)
    }

    /// A step that fails puts back everything done before it, last first: the tree and both domains as they were (but
    /// the copies, journal and log the migration adds to the old folder), the old places used.
    func testAFailedStepPutsEverythingBack() throws {
        let cases: [(String, (Faults, String) -> Void)] = [
            ("the data folder", { f, _ in f.rename = { a, _ in a.lastPathComponent == "PaperCollab Dev" } }),
            ("the review folder", { f, _ in f.rename = { a, _ in a.lastPathComponent == "PaperCollab Dev Reviews" } }),
            ("papers.json", { f, _ in f.write = { u, _ in u.lastPathComponent == "papers.json" && u.path.contains("/Paperole Dev/") } }),
            ("a draft's rename", { f, kelp in f.rename = { _, b in b.lastPathComponent == kelp } }),
            ("a draft's rewrite", { f, kelp in f.write = { u, _ in u.lastPathComponent == kelp } }),
            ("the marker", { f, _ in f.write = { u, d in u.lastPathComponent == Migration.journalName && Self.done(d) } }),
        ]
        for (name, inject) in cases {
            try? fm.removeItem(at: tmp)
            try setUpWithError()
            let d = try oldDev(newDomain: ["NSNavLastRootDirectory": "~/Desktop"])
            let before = tree(), domains = d.values
            let f = Faults()
            inject(f, kelpDraft)
            guard case .rolledBack = Migration.run(context(d, fs: f.fs)) else { return XCTFail(name) }
            XCTAssertTrue(untouched(before), name)
            XCTAssertTrue(equal(d.values[AppVariant.devID], domains[AppVariant.devID]), name)
            XCTAssertTrue(equal(d.values[AppVariant.oldDevID], domains[AppVariant.oldDevID]), name)
            XCTAssertEqual(Migration.journal(oldS, fs: .disk)?.state, "rolled_back", name)
            XCTAssertEqual(at(DataHome.resolve(.dev, roots: roots, fs: .disk)), home(oldS, oldC, oldR), name)
            let log = try String(contentsOf: oldS.appendingPathComponent(Migration.logName), encoding: .utf8)
            XCTAssertTrue(log.contains("putting everything back"), name)
        }
        // the settings: a write that does not read back
        try? fm.removeItem(at: tmp)
        try setUpWithError()
        let d = try oldDev()
        let before = tree()
        d.lose = AppVariant.devID
        guard case .rolledBack(let why) = Migration.run(context(d)) else { return XCTFail("settings") }
        XCTAssertEqual(why, "the settings did not read back as written")
        XCTAssertTrue(untouched(before))
        XCTAssertNil(d.values[AppVariant.devID], "removed again: there was none")
    }

    /// Kelp drift's drafts file at its new place's name.
    private var kelpDraft: String {
        DraftStore(directory: newS.appendingPathComponent("drafts")).url(paper: newR.appendingPathComponent("Kelp drift").path).lastPathComponent
    }

    /// The journal being written says "done" (the marker).
    private static func done(_ d: Data) -> Bool { (try? JSONDecoder().decode(Migration.Journal.self, from: d))?.state == "done" }

    /// Putting back that fails stops at once: nothing more is touched, nothing is deleted, the app must not run.
    func testAFailedUndoStops() throws {
        let d = try oldDev()
        let files = Set(tree().values)
        let f = Faults()
        f.dieAfterFault = true
        f.rename = { a, _ in a.lastPathComponent == "PaperCollab Dev Reviews" }
        guard case .stuck = Migration.run(context(d, fs: f.fs)) else { return XCTFail("stuck") }
        XCTAssertTrue(files.isSubset(of: Set(tree().values)), "every file still there, somewhere")
        XCTAssertTrue(fm.fileExists(atPath: newS.path), "left where it was when it stopped")
        XCTAssertEqual(Migration.journal(newS, fs: .disk)?.state, "running")
    }

    /// The app killed midway (after the data folder, the review folder, papers.json or one draft): the next launch puts
    /// back what was done, then moves everything as a first launch does.
    func testAMigrationCutOffIsPutBackThenDone() throws {
        let points: [(String, (Faults, String) -> Void)] = [
            ("after the data folder", { f, _ in f.rename = { a, _ in a.lastPathComponent == "PaperCollab Dev Reviews" } }),
            ("after the review folder", { f, _ in f.write = { u, _ in u.lastPathComponent == "papers.json" && u.path.contains("/Paperole Dev/") } }),
            ("after papers.json", { f, kelp in f.rename = { _, b in b.lastPathComponent == kelp } }),
            ("after a draft's rename", { f, kelp in f.write = { u, _ in u.lastPathComponent == kelp } }),
        ]
        for (name, inject) in points {
            try? fm.removeItem(at: tmp)
            try setUpWithError()
            let d = try oldDev()
            let f = Faults()
            f.dieAfterFault = true
            inject(f, kelpDraft)
            guard case .stuck = Migration.run(context(d, fs: f.fs)) else { return XCTFail(name) }
            XCTAssertEqual([newS, oldS].compactMap { Migration.journal($0, fs: .disk)?.state }, ["running"], name)
            // the next launch
            XCTAssertEqual(Migration.run(context(d)), .moved(reviews: true, defaults: true), name)
            XCTAssertFalse(fm.fileExists(atPath: oldS.path), name)
            XCTAssertFalse(fm.fileExists(atPath: oldR.path), name)
            let list = try papers(newS)
            XCTAssertEqual(list.filter { $0.path.hasPrefix(newR.path + "/") }.count, 2, name)
            XCTAssertEqual(DraftStore(directory: newS.appendingPathComponent("drafts")).load(paper: list[0].path, round: 2),
                           ["R1-01": "Say which beach."], name)
            XCTAssertEqual(draftFiles(newS).count, 3, name)
            XCTAssertEqual(Migration.marker(newS, fs: .disk)?.state, "done", name)
            let pres = try fm.contentsOfDirectory(atPath: newS.path).filter { $0.hasPrefix(Migration.prePrefix) }
            XCTAssertEqual(pres.count, 2, "\(name): the first one's copies (the same second here) are never written over")
            let log = try String(contentsOf: newS.appendingPathComponent(Migration.logName), encoding: .utf8)
            XCTAssertTrue(log.contains("found a migration cut off midway"), name)
        }
    }

    /// A list that cannot be read: the review folder is not moved (its paths could not be rewritten) and the list left
    /// for the app to set aside; the data folder moved.
    func testAnUnreadableListLeavesTheReviewFolder() throws {
        let d = try oldDev()
        try Data("[{\"path\":".utf8).write(to: oldS.appendingPathComponent("papers.json"))
        XCTAssertEqual(Migration.run(context(d)), .moved(reviews: false, defaults: true))
        XCTAssertTrue(fm.fileExists(atPath: oldR.path))
        XCTAssertEqual(try Data(contentsOf: newS.appendingPathComponent("papers.json")), Data("[{\"path\":".utf8))
        XCTAssertEqual(d.values[AppVariant.devID]?["reviewFolderRoot"] as? String, oldR.path)
        XCTAssertEqual(DataHome.resolve(.dev, roots: roots, fs: .disk).reviews.path, oldR.path)
    }

    /// Never a copy: another disk, a link or a file where a folder was is left as it is.
    func testNeverACopy() throws {
        // the data folder on another disk
        var d = try oldDev()
        var before = tree()
        let f = Faults()
        f.device = { [oldS] u in u.path == oldS.path ? 999 : MigrationFS.disk.device(u) }
        XCTAssertEqual(Migration.run(context(d, fs: f.fs)), .skipped("\(DataFiles.shown(oldS)) is on another disk"))
        XCTAssertTrue(untouched(before))
        XCTAssertTrue(d.written.isEmpty)
        // the review folder on another disk: the data folder moved, the review folder left
        f.device = { [oldR] u in u.path == oldR.path ? 999 : MigrationFS.disk.device(u) }
        XCTAssertEqual(Migration.run(context(d, fs: f.fs)), .moved(reviews: false, defaults: true))
        XCTAssertTrue(fm.fileExists(atPath: oldR.path))

        // the review folder a link: left
        try? fm.removeItem(at: tmp)
        try setUpWithError()
        d = try oldDev()
        let real = roots.home.appendingPathComponent("Real Reviews")
        try fm.moveItem(at: oldR, to: real)
        try fm.createSymbolicLink(at: oldR, withDestinationURL: real)
        XCTAssertEqual(Migration.run(context(d)), .moved(reviews: false, defaults: true))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: oldR.path), real.path)

        // the data folder a link, or a file: left
        for link in [true, false] {
            try? fm.removeItem(at: tmp)
            try setUpWithError()
            d = try oldDev()
            let elsewhere = roots.home.appendingPathComponent("data")
            try fm.moveItem(at: oldS, to: elsewhere)
            if link { try fm.createSymbolicLink(at: oldS, withDestinationURL: elsewhere) } else { try Data().write(to: oldS) }
            before = tree()
            XCTAssertEqual(Migration.run(context(d)), .skipped("\(DataFiles.shown(oldS)) is not a folder"))
            XCTAssertEqual(tree(), before)
            XCTAssertTrue(d.written.isEmpty)
        }
    }

    /// A new domain's explicit preferences survive; missing ones and the installation identity follow the old data.
    /// Only the migration marker, not an individual preference, means the settings have already been copied.
    func testTheSettingsMergeUntilTheyHaveBeenMigrated() throws {
        var d = try oldDev(newDomain: ["NSNavLastRootDirectory": "~/Desktop", "NSWindow Frame main": "1 1 2 2 "])
        XCTAssertEqual(Migration.run(context(d)), .moved(reviews: true, defaults: true))
        let new = try XCTUnwrap(d.values[AppVariant.devID])
        XCTAssertEqual(new["NSNavLastRootDirectory"] as? String, "~/Desktop", "AppKit's kept")
        XCTAssertEqual(new["NSWindow Frame main"] as? String, "0 0 1440 900 0 0 1728 1079 ", "the advisor's own window")
        XCTAssertEqual(new["installID"] as? String, "i-0123456789abcdef")
        for theirs in [["readingMarks": false], ["installID": "i-new"]] as [[String: Any]] {
            try? fm.removeItem(at: tmp)
            try setUpWithError()
            d = try oldDev(newDomain: theirs)
            XCTAssertEqual(Migration.run(context(d)), .moved(reviews: true, defaults: true), "\(theirs)")
            let merged = try XCTUnwrap(d.values[AppVariant.devID])
            XCTAssertEqual(merged["readingMarks"] as? Bool, theirs["readingMarks"] as? Bool ?? true)
            XCTAssertEqual(merged["installID"] as? String, "i-0123456789abcdef")
            XCTAssertEqual(merged["backups"] as? String, d.values[AppVariant.oldDevID]?["backups"] as? String)
            XCTAssertNotNil(merged[Migration.markerKey])
        }
        try? fm.removeItem(at: tmp)
        try setUpWithError()
        let migrated: [String: Any] = [Migration.markerKey: ["id": "x"]]
        d = try oldDev(newDomain: migrated)
        XCTAssertEqual(Migration.run(context(d)), .moved(reviews: true, defaults: false))
        XCTAssertTrue(equal(d.values[AppVariant.devID], migrated))
        XCTAssertTrue(d.written.isEmpty)
        // no old settings at all
        try? fm.removeItem(at: tmp)
        try setUpWithError()
        d = try oldDev()
        d.values[AppVariant.oldDevID] = nil
        XCTAssertEqual(Migration.run(context(d)), .moved(reviews: true, defaults: false))
        XCTAssertTrue(d.written.isEmpty)
    }

    /// Both the completed move and the completed rollback cannot be recorded. All writes to user files still work.
    private func failRollbackJournal(_ d: Domains, silently: Bool = false) -> Migration.Outcome {
        var fs = MigrationFS.disk
        let write = fs.write
        fs.write = { data, url in
            if url.lastPathComponent == Migration.journalName,
               let j = try? JSONDecoder().decode(Migration.Journal.self, from: data) {
                if j.state == "done" { throw DataFailure(message: "cannot finish the migration") }
                if j.state == "rolled_back" {
                    if silently { return }
                    throw DataFailure(message: "cannot record the rollback")
                }
            }
            try write(data, url)
        }
        return Migration.run(context(d, fs: fs))
    }

    func testARollbackMustPersistAndReadBackItsCompletion() throws {
        for silently in [false, true] {
            try? fm.removeItem(at: tmp)
            try setUpWithError()
            let d = try oldDev()
            let before = tree()
            guard case .stuck = failRollbackJournal(d, silently: silently) else { return XCTFail("must stop the launch") }
            XCTAssertTrue(untouched(before))
            XCTAssertEqual(Migration.journal(oldS, fs: .disk)?.state, "running")
            XCTAssertEqual(Migration.run(context(d)), .moved(reviews: true, defaults: true))
            let list = try papers(newS)
            XCTAssertEqual(DraftStore(directory: newS.appendingPathComponent("drafts")).load(paper: list[0].path, round: 2),
                           ["R1-01": "Say which beach."])
            XCTAssertEqual(Migration.run(context(d)), .nothing)
        }
    }

    /// Support is put back last: an old or new journal left running after that must never replay its snapshots.
    func testACompletedRollbackNeverOverwritesNewerWork() throws {
        for legacy in [true, false] {
            try? fm.removeItem(at: tmp)
            try setUpWithError()
            let d = try oldDev()
            guard case .stuck = failRollbackJournal(d) else { return XCTFail("the stale journal") }
            if legacy {
                var j = try XCTUnwrap(Migration.journal(oldS, fs: .disk))
                j.wrote = nil
                try JSONEncoder().encode(j).write(to: oldS.appendingPathComponent(Migration.journalName))
            }
            let store = DraftStore(directory: oldS.appendingPathComponent("drafts"))
            let path = oldR.appendingPathComponent("Kelp drift").path
            store.save(paper: path, round: 2, drafts: ["R1-01": "A new draft after rollback."])
            var list = try papers(oldS)
            list.removeLast()
            list[0].title = "An updated paper after rollback"
            try JSONEncoder().encode(list).write(to: oldS.appendingPathComponent("papers.json"))
            d.values[AppVariant.devID] = ["readingMarks": false, "enginePython": "/new/python"]
            XCTAssertEqual(Migration.run(context(d)), .moved(reviews: true, defaults: true))
            let after = try papers(newS)
            XCTAssertEqual(after.count, list.count)
            XCTAssertEqual(after[0].title, list[0].title)
            XCTAssertEqual(DraftStore(directory: newS.appendingPathComponent("drafts")).load(paper: after[0].path, round: 2),
                           ["R1-01": "A new draft after rollback."])
            XCTAssertEqual(d.values[AppVariant.devID]?["readingMarks"] as? Bool, false)
            XCTAssertEqual(d.values[AppVariant.devID]?["enginePython"] as? String, "/new/python")
            XCTAssertNotNil(Migration.marker(newS, fs: .disk))
        }
    }

    func testRecoveryStopsForChangesInAPartialMove() throws {
        for change in ["draft", "papers", "duplicate draft", "review folder"] {
            try? fm.removeItem(at: tmp)
            try setUpWithError()
            let d = try oldDev()
            let f = Faults()
            f.dieAfterFault = true
            f.write = { u, data in u.lastPathComponent == Migration.journalName && Self.done(data) }
            guard case .stuck = Migration.run(context(d, fs: f.fs)) else { return XCTFail("the interrupted move") }
            let file: URL
            switch change {
            case "draft":
                let store = DraftStore(directory: newS.appendingPathComponent("drafts"))
                let path = newR.appendingPathComponent("Kelp drift").path
                store.save(paper: path, round: 2, drafts: ["R1-01": "Newer work during the interruption."])
                file = store.url(paper: path)
            case "papers":
                var list = try papers(newS)
                list.removeLast()
                file = newS.appendingPathComponent("papers.json")
                try JSONEncoder().encode(list).write(to: file)
            case "duplicate draft":
                let store = DraftStore(directory: newS.appendingPathComponent("drafts"))
                let path = oldR.appendingPathComponent("Kelp drift").path
                store.save(paper: path, round: 2, drafts: ["R1-01": "A second draft that must survive."])
                file = store.url(paper: path)
            default:
                try fm.createDirectory(at: oldR, withIntermediateDirectories: true)
                file = oldR.appendingPathComponent("keep.txt")
                try Data("New contents at the old place".utf8).write(to: file)
            }
            let bytes = try Data(contentsOf: file)
            guard case .stuck = Migration.run(context(d)) else { return XCTFail("\(change): recovery must stop") }
            XCTAssertEqual(try Data(contentsOf: file), bytes, change)
            XCTAssertTrue(fm.fileExists(atPath: newR.appendingPathComponent("Kelp drift/ledger.json").path))
            XCTAssertTrue(fm.fileExists(atPath: newS.path))
            XCTAssertEqual(Migration.journal(newS, fs: .disk)?.state, "running")
        }
    }

    func testAFailedSettingsRollbackStopsBeforeMovingFoldersBack() throws {
        let d = try oldDev()
        let f = Faults()
        f.write = { u, data in u.lastPathComponent == Migration.journalName && Self.done(data) }
        var c = context(d, fs: f.fs)
        c.defaults.remove = { _ in }  // the new domain cannot be restored to its original, absent state
        guard case .stuck = Migration.run(c) else { return XCTFail("the defaults were not restored") }
        XCTAssertTrue(fm.fileExists(atPath: newS.path))
        XCTAssertTrue(fm.fileExists(atPath: newR.path))
        XCTAssertEqual(Migration.journal(newS, fs: .disk)?.state, "running")
    }

    func testSettingsPersistenceErrorsPropagate() throws {
        for phase in ["copy", "remove", "restore"] {
            try? fm.removeItem(at: tmp)
            try setUpWithError()
            let d = try oldDev(newDomain: phase == "restore" ? ["readingMarks": false] : nil)
            let before = tree()
            let f = Faults()
            f.write = { u, data in u.lastPathComponent == Migration.journalName && Self.done(data) }
            var c = context(d, fs: f.fs)
            let write = c.defaults.write, remove = c.defaults.remove
            c.defaults.write = { domain, values in
                if phase == "restore", values[Migration.markerKey] == nil { throw DataFailure(message: "restore failed") }
                try write(domain, values)
                if phase == "copy" { throw DataFailure(message: "synchronization failed after updating the cache") }
            }
            c.defaults.remove = { domain in
                if phase == "remove" { throw DataFailure(message: "remove failed") }
                try remove(domain)
            }
            let result = Migration.run(c)
            if phase == "copy" {
                guard case .rolledBack = result else { return XCTFail("a settings-copy failure must roll back") }
                XCTAssertTrue(untouched(before))
                XCTAssertNil(d.values[AppVariant.devID])
            } else {
                guard case .stuck = result else { return XCTFail("a failed settings undo must stop") }
                XCTAssertTrue(fm.fileExists(atPath: newS.path))
                XCTAssertTrue(fm.fileExists(atPath: newR.path))
                XCTAssertEqual(Migration.journal(newS, fs: .disk)?.state, "running")
            }
        }
    }

    func testARetryKeepsOldSettingsAfterTheAppSavesItsPlace() throws {
        let d = try oldDev()
        d.values[AppVariant.oldDevID]?["enginePython"] = "/synthetic/old-python"
        let old = d.values[AppVariant.oldDevID]
        let f = Faults()
        f.rename = { a, _ in a.lastPathComponent == "PaperCollab Dev Reviews" }
        let failed = Migration.run(context(d, fs: f.fs))
        guard case .rolledBack = failed else { return XCTFail("one transient failure") }
        let fallback = try XCTUnwrap(Migration.fallback(failed, old: old))
        XCTAssertEqual(fallback["backups"] as? String, old?["backups"] as? String)
        XCTAssertEqual(fallback["enginePython"] as? String, "/synthetic/old-python")
        XCTAssertNil(fallback["appIcon"])
        XCTAssertNil(d.values[AppVariant.devID], "fallback values have not been persisted")
        let place = LastPlace(paper: oldR.appendingPathComponent("Kelp drift").path, level: "review").json()!
        // A launch of the earlier buggy build may have generated an install id; it must not replace the old identity.
        d.values[AppVariant.devID] = ["lastPlace": place, "installID": "i-generated", "readingMarks": false,
                                      "enginePython": "/synthetic/new-python"]
        XCTAssertEqual(Migration.run(context(d)), .moved(reviews: true, defaults: true))
        let merged = try XCTUnwrap(d.values[AppVariant.devID])
        XCTAssertEqual(merged["installID"] as? String, old?["installID"] as? String)
        XCTAssertEqual(merged["backups"] as? String, old?["backups"] as? String)
        XCTAssertEqual(merged["readingMarks"] as? Bool, false)
        XCTAssertEqual(merged["enginePython"] as? String, "/synthetic/new-python")
        XCTAssertEqual(merged["reviewFolderRoot"] as? String, newR.path)
        XCTAssertEqual(LastPlace.parse(merged["lastPlace"] as? String)?.paper, newR.appendingPathComponent("Kelp drift").path)
        XCTAssertTrue(equal(d.values[AppVariant.oldDevID], old), "the old domain never changes")
        let before = tree(), settings = merged
        XCTAssertEqual(Migration.run(context(d)), .nothing)
        XCTAssertEqual(tree(), before)
        XCTAssertTrue(equal(d.values[AppVariant.devID], settings))
    }

    func testFallbackPreferencesAreUsedOnlyWhileMigrationIsPending() {
        let old: [String: Any] = ["readingMarks": true, "installID": "i-old", "appIcon": "round"]
        for result in [Migration.Outcome.rolledBack("x"), .skipped("x"), .both(first: true), .both(first: false)] {
            let values = Migration.fallback(result, old: old)
            XCTAssertEqual(values?["readingMarks"] as? Bool, true)
            XCTAssertEqual(values?["installID"] as? String, "i-old")
            XCTAssertNil(values?["appIcon"])
        }
        for result in [Migration.Outcome.nothing, .moved(reviews: true, defaults: true), .stuck("x")] {
            XCTAssertNil(Migration.fallback(result, old: old))
        }
        XCTAssertNil(Migration.fallback(.rolledBack("x"), old: nil))
    }

    /// The review's second pass (2026-10-27). A stray copy of a draft (a second file for the same paper, which the app
    /// never reads): left as it is, and no longer two files renamed to one name (that trapped at every launch).
    func testAStrayDraftCopyIsLeft() throws {
        let d = try oldDev()
        let kelp = DraftStore(directory: oldS).url(paper: oldR.appendingPathComponent("Kelp drift").path).lastPathComponent
        let stray = oldS.appendingPathComponent("drafts/" + kelp.replacingOccurrences(of: ".json", with: " 2.json"))
        try fm.copyItem(at: oldS.appendingPathComponent("drafts/" + kelp), to: stray)
        let bytes = try Data(contentsOf: stray)
        XCTAssertEqual(Migration.run(context(d)), .moved(reviews: true, defaults: true))
        let list = try papers(newS)
        XCTAssertEqual(DraftStore(directory: newS.appendingPathComponent("drafts")).load(paper: list[0].path, round: 2), ["R1-01": "Say which beach."])
        XCTAssertEqual(try Data(contentsOf: newS.appendingPathComponent("drafts/" + stray.lastPathComponent)), bytes, "left as it was")
        XCTAssertEqual(draftFiles(newS).count, 4)
    }

    /// A listed paper in the review folder by another path (a link to the folder, other letter case): the review
    /// folder is not moved, so it is never lost; the data folder is. And a listed paper there before the move that is
    /// not there after it, whatever the reason: everything is put back.
    func testAPaperInTheReviewFolderByAnotherPath() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        // a link to the review folder
        var d = try oldDev()
        let link = roots.home.appendingPathComponent("Desktop/Reviews")
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: oldR)
        var list = try papers(oldS)
        list.append(PaperRef(path: link.appendingPathComponent("Warm pools").path, title: "Warm pools", student: "Lin Zhou"))
        try enc.encode(list).write(to: oldS.appendingPathComponent("papers.json"))
        XCTAssertEqual(Migration.run(context(d)), .moved(reviews: false, defaults: true))
        XCTAssertTrue(fm.fileExists(atPath: link.appendingPathComponent("Warm pools/ledger.json").path))
        XCTAssertTrue(fm.fileExists(atPath: oldR.path))
        XCTAssertEqual(try papers(newS), list, "not rewritten")
        var log = try String(contentsOf: newS.appendingPathComponent(Migration.logName), encoding: .utf8)
        XCTAssertTrue(log.contains("is in it by another path"), log)
        // other letter case, where the disk ignores it (APFS's default)
        try? fm.removeItem(at: tmp)
        try setUpWithError()
        d = try oldDev()
        let lower = roots.home.appendingPathComponent("papercollab dev reviews/Kelp drift")
        if fm.fileExists(atPath: lower.path) {
            list = try papers(oldS)
            list.append(PaperRef(path: lower.path, title: "Kelp drift", student: "Mei Lin"))
            try enc.encode(list).write(to: oldS.appendingPathComponent("papers.json"))
            XCTAssertEqual(Migration.run(context(d)), .moved(reviews: false, defaults: true))
            XCTAssertTrue(fm.fileExists(atPath: lower.path))
        }
        // a listed paper elsewhere gone after the move (what no check before it can see): put back
        try? fm.removeItem(at: tmp)
        try setUpWithError()
        d = try oldDev()
        let before = tree()
        let other = roots.home.appendingPathComponent("Elsewhere/Other")
        let f = Faults()
        f.kind = { [fm, newR] u in u.path == other.path && fm.fileExists(atPath: newR.path) ? MigrationFS.Kind.none : nil }
        guard case .rolledBack(let why) = Migration.run(context(d, fs: f.fs)) else { return XCTFail("put back") }
        XCTAssertEqual(why, "\(other.path) is not there after the move")
        XCTAssertTrue(untouched(before))
        log = try String(contentsOf: oldS.appendingPathComponent(Migration.logName), encoding: .utf8)
        XCTAssertTrue(log.contains("putting everything back"), log)
    }

    /// papers.json a link: never rewritten (its target is not copied first, so it could not be put back), the review
    /// folder left; the link moves with the data folder, as it was.
    func testAListThatIsALink() throws {
        let d = try oldDev()
        let target = roots.home.appendingPathComponent("lists/papers.json")
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: oldS.appendingPathComponent("papers.json"), to: target)
        try fm.createSymbolicLink(at: oldS.appendingPathComponent("papers.json"), withDestinationURL: target)
        let bytes = try Data(contentsOf: target)
        XCTAssertEqual(Migration.run(context(d)), .moved(reviews: false, defaults: true))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: newS.appendingPathComponent("papers.json").path), target.path)
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        XCTAssertTrue(fm.fileExists(atPath: oldR.path))
    }

    /// A backup folder in the review folder: Settings' backup state rewritten with it, every other field (the last
    /// backup's time to the fraction of a second, its counts) read back the same.
    func testTheBackupStateInTheReviewFolder() throws {
        let d = try oldDev()
        let rec = BackupRecord(time: Date(timeIntervalSinceReferenceDate: 783_000_000.123456), file: "x.zip", papers: 3, left: [""],
                               bytes: 5_000_000_123, ledgers: ["ab"])
        var state = BackupState(on: true, folder: oldR.appendingPathComponent("Backups").path, volume: "V-1", volumeName: "Mac",
                                last: rec, day: "2026-10-26", afterFinish: true)
        d.values[AppVariant.oldDevID]?[BackupModel.key] = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        XCTAssertEqual(Migration.run(context(d)), .moved(reviews: true, defaults: true))
        let back = try JSONDecoder().decode(BackupState.self, from: Data(try XCTUnwrap(d.values[AppVariant.devID]?[BackupModel.key] as? String).utf8))
        state.folder = newR.appendingPathComponent("Backups").path
        XCTAssertEqual(back, state)
    }

    /// The disk's exclusive rename: never over anything, a folder or a file.
    func testTheRenameNeverReplaces() throws {
        let a = tmp.appendingPathComponent("a"), b = tmp.appendingPathComponent("b")
        try fm.createDirectory(at: a, withIntermediateDirectories: true)
        try Data("b".utf8).write(to: b)
        XCTAssertThrowsError(try MigrationFS.disk.renameExclusive(a, b))
        XCTAssertEqual(try Data(contentsOf: b), Data("b".utf8))
        try fm.removeItem(at: b)
        try fm.createDirectory(at: b, withIntermediateDirectories: true)
        XCTAssertThrowsError(try MigrationFS.disk.renameExclusive(a, b), "not even an empty folder")
        try fm.removeItem(at: b)
        try MigrationFS.disk.renameExclusive(a, b)
        XCTAssertEqual(MigrationFS.disk.kind(b), .folder)
        XCTAssertEqual(MigrationFS.disk.kind(a), .none)
        XCTAssertThrowsError(try MigrationFS.disk.makeFolder(b), "a new folder only")
        XCTAssertEqual(MigrationFS.nothing.kind(roots.support), .none, "a test run sees nothing")
    }
}
