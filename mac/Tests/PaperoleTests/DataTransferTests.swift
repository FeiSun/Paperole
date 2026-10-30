import AppKit
import CryptoKit
import SwiftUI
import XCTest
@testable import Paperole

/// Export, Import and the list's safety (design/data/DATA.md as its §0 leaves it), in temporary folders only: an
/// unreadable papers.json set aside and never replaced; the three facts moved into the ledger once; the Export tree's
/// checks and the file's name; Import's defaults for each status; export everything, delete the folders and the list,
/// import, and every primary file, each round's state and the overview the same; also one student, and one paper put
/// back where it was, and Use This Copy keeping yours; Undo of Remove from List; the Settings tab without paper rows.
/// The papers are synthetic, made by the engine from a few lines of LaTeX.
@MainActor
final class DataTransferTests: XCTestCase {
    private var tmp: URL!
    private var windows: [NSWindow] = []
    private var fm: FileManager { .default }

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("pc-transfer-" + UUID().uuidString)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        windows.forEach { $0.close() }
        windows = []
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
        guard fm.isExecutableFile(atPath: EngineClient.defaultPython), fm.fileExists(atPath: "/Library/TeX/texbin/latexmk") else {
            throw XCTSkip("needs the engine's Python and latexmk")
        }
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

    /// A synthetic paper made by the engine: round 1 from a few lines of LaTeX with one comment, then (`rounds` 2)
    /// finished and round 2 open from an edited source.
    private func paper(_ m: AppModel, _ folder: URL, title: String, student: String, rounds: Int = 2) async throws -> PaperRef {
        let src = tmp.appendingPathComponent("src-" + UUID().uuidString)
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        let tex = { (where_: String) in
            "\\documentclass{article}\n\\begin{document}\n\\section{Intro}\nKelp drifts in the \(where_).\n\\end{document}\n"
        }
        try Data(tex("bay").utf8).write(to: src.appendingPathComponent("main.tex"))
        try await rpc(m, "new", ["paper": folder.path, "title": title, "student": student])
        try await rpc(m, "ingest", ["paper": folder.path, "source": src.path])
        try await rpc(m, "comment", ["paper": folder.path, "page": 0, "rects": [[133.7, 148.8, 230.2, 158.8]],
                                     "text": "Kelp drifts in the bay.", "note": "Which bay?", "kind": "highlight"])
        if rounds > 1 {
            try await rpc(m, "finish", ["paper": folder.path])
            try Data(tex("northern bay").utf8).write(to: src.appendingPathComponent("main.tex"))
            try await rpc(m, "ingest", ["paper": folder.path, "source": src.path])
        }
        return PaperRef(path: folder.standardizedFileURL.path, title: title, student: student, factsMoved: true)
    }

    private func settle(_ data: DataModel) async throws {
        for _ in 0..<1200 where data.working { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertFalse(data.working, "the work did not finish")
    }

    /// Every primary file under a review folder (not caches, nor .lock) with its bytes and permissions.
    private func files(_ dir: URL) -> [String: String] {
        let caches: Set<String> = [".lock", "analysis.cache.json", "prose.json", "contexts.json", "prose.failed"]
        var out: [String: String] = [:]
        for rel in fm.subpaths(atPath: dir.path) ?? [] where !caches.contains((rel as NSString).lastPathComponent) {
            var isDir: ObjCBool = false
            let u = dir.appendingPathComponent(rel)
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir), !isDir.boolValue, let d = try? Data(contentsOf: u) else { continue }
            let mode = (try? fm.attributesOfItem(atPath: u.path)[.posixPermissions] as? Int) ?? 0
            out[rel] = SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() + " " + String(mode, radix: 8)
        }
        return out
    }

    /// What the app shows of the papers: each round's state and the overview, as the engine says them.
    private func views(_ m: AppModel, _ papers: [PaperRef]) async throws -> String {
        var out: [Any] = []
        for p in papers {
            let lg = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: p.path).appendingPathComponent("ledger.json"))) as? [String: Any])
            for r in lg["rounds"] as? [[String: Any]] ?? [] { out.append(try await rpc(m, "state", ["paper": p.path, "round": r["n"] ?? 1])) }
        }
        out.append(try await rpc(m, "overview", ["papers": papers.map(\.path)]))
        return String(decoding: try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]), as: UTF8.self)
    }

    private func ledger(_ p: PaperRef) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: p.path).appendingPathComponent("ledger.json"))) as? [String: Any])
    }

    // MARK: The list

    /// An unreadable papers.json is moved aside as papers.json.bad, never replaced by an empty list; nothing is saved
    /// over one that could not be moved; an entry written before the facts moved still reads.
    func testAnUnreadablePapersListIsSetAside() throws {
        let url = tmp.appendingPathComponent("papers.json")
        XCTAssertEqual(PaperStore.load(from: url).papers, [], "none yet")
        XCTAssertNil(PaperStore.load(from: url).problem)
        try Data("[{\"path\": \"/x\", \"title\": \"Kelp".utf8).write(to: url)
        let loaded = PaperStore.load(from: url)
        XCTAssertEqual(loaded.papers, [])
        XCTAssertTrue(loaded.problem?.contains("papers.json.bad") == true, loaded.problem ?? "")
        XCTAssertFalse(fm.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: url.appendingPathExtension("bad")), Data("[{\"path\": \"/x\", \"title\": \"Kelp".utf8))
        let kelp = PaperRef(path: "/r/kelp", title: "Kelp drift", student: "Mei Lin", finished: "2026-07-20", factsMoved: true)
        try PaperStore.save([kelp], to: url)
        XCTAssertEqual(PaperStore.load(from: url).papers, [kelp])
        // a file damaged since: set aside again, beside the first, before the list is saved
        try Data("{".utf8).write(to: url)
        try PaperStore.save([kelp], to: url)
        XCTAssertEqual(try Data(contentsOf: tmp.appendingPathComponent("papers-2.json.bad")), Data("{".utf8))
        XCTAssertEqual(PaperStore.load(from: url).papers, [kelp])
        // one that cannot be moved aside stays as it is, and nothing is saved over it
        let locked = tmp.appendingPathComponent("locked")
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        let inner = locked.appendingPathComponent("papers.json")
        try Data("not json".utf8).write(to: inner)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        XCTAssertTrue(PaperStore.load(from: inner).problem?.contains("nor moved aside") == true)
        XCTAssertThrowsError(try PaperStore.save([kelp], to: inner))
        XCTAssertEqual(try Data(contentsOf: inner), Data("not json".utf8))
        // a test run leaves an unreadable one as it is
        try Data("{".utf8).write(to: url)
        XCTAssertTrue(PaperStore.load(from: url, setAside: false).problem?.contains("A test run leaves it as it is") == true)
        XCTAssertEqual(try Data(contentsOf: url), Data("{".utf8))
        // an entry from before the facts moved into the ledgers
        let old = Data("[{\"path\":\"/r/a\",\"title\":\"A\",\"student\":\"B\",\"keyPage\":{\"round\":2,\"page\":3}}]".utf8)
        try old.write(to: url)
        let a = try XCTUnwrap(PaperStore.load(from: url).papers.first)
        XCTAssertEqual(a.keyPage, KeyPageChoice(round: 2, page: 3))
        XCTAssertNil(a.factsMoved)
        XCTAssertNil(a.ledgerID)
    }

    /// Remove from List says the folder stays, with Undo, which puts the entries back where they were; a student's
    /// papers go together.
    func testUndoOfRemoveFromList() throws {
        let m = fixtureModel()
        let kelp = PaperRef(path: tmp.appendingPathComponent("Reviews/Kelp drift").path, title: "Kelp drift: a study", student: "Mei Lin", finished: "2026-07-20")
        let reef = PaperRef(path: tmp.appendingPathComponent("Reviews/Reef").path, title: "Reef choruses", student: "Mei Lin")
        m.papers += [kelp, reef]
        let before = m.papers
        m.removePaper(kelp.path)
        XCTAssertFalse(m.papers.contains(kelp))
        let words = try XCTUnwrap(m.notice?.text)
        XCTAssertEqual(words, "Removed “Kelp drift” from the list. Its folder stays where it is.", "no path on the line")
        XCTAssertEqual(m.notice?.action, "Undo")
        m.noticeClicked()
        XCTAssertEqual(m.papers, before, "back where it was, with its facts")
        XCTAssertNil(m.notice)
        m.removePapers([kelp.path, reef.path], student: "Mei Lin")
        XCTAssertEqual(m.notice?.text, "Removed Mei Lin’s 2 papers from the list. Their folders stay where they are.")
        m.noticeClicked()
        XCTAssertEqual(m.papers, before)
    }

    /// Settings › Data & Storage lists no students or papers (DATA.md §0.2): places and totals only, so the tab is as
    /// long with forty papers of twenty students as with one.
    func testTheSettingsTabShowsNoPaperRows() throws {
        func formHeight(_ m: AppModel) -> CGFloat {
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
        let one = fixtureModel()
        let height = formHeight(one)
        XCTAssertGreaterThan(height, 200, "the form is measured")
        let many = fixtureModel()
        many.papers += (0..<40).map { i in
            PaperRef(path: tmp.appendingPathComponent("Paper \(i)").path, title: "Zanzibar kelp \(i)", student: "Student \(i / 2)")
        }
        XCTAssertEqual(formHeight(many), height, "no row for a paper or a student")
    }

    // MARK: Export

    /// The tree: all ticked from Settings or File, only a context menu's student or paper from there; a dash for a part
    /// ticked; a folder not there greyed and never ticked; the file's name for what is in it.
    func testTheExportTree() throws {
        func folder(_ name: String) throws -> String {
            let f = tmp.appendingPathComponent(name)
            try fm.createDirectory(at: f, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: f.appendingPathComponent("ledger.json"))
            return f.path
        }
        let easy = PaperRef(path: try folder("Easy"), title: "Easy Before Hard: Curriculum-Paced Distillation", student: "Maya Chen")
        let kelp = PaperRef(path: try folder("Kelp"), title: "Kelp drift", student: "Maya Chen")
        let gone = PaperRef(path: tmp.appendingPathComponent("Gone").path, title: "Gone", student: "Maya Chen")
        let away = PaperRef(path: "/Volumes/PC-No-Such-Drive-\(UUID().uuidString.prefix(6))/Reef", title: "Reef", student: "Maya Chen")
        let leo = PaperRef(path: try folder("Leo"), title: "Retrieval-Augmented Docstrings", student: "Leo Park")
        let groups = Hierarchy.groups([easy, kelp, gone, away, leo]) { _ in nil }
        var e = ExportChoice.make(groups, only: nil, origin: .settings)
        XCTAssertEqual(e.students.map(\.name), ["Leo Park", "Maya Chen"])
        XCTAssertEqual(e.students[1].papers.map(\.gone), [nil, nil, "missing", "on “\(away.path.split(separator: "/")[1])”, not connected"])
        XCTAssertEqual(e.chosen.map(\.path), [leo.path, easy.path, kelp.path])
        XCTAssertTrue(e.everything)
        XCTAssertEqual(e.mark(e.students[1].papers), .on, "the missing ones are not counted")
        XCTAssertEqual(e.fileName(day: "2026-10-22"), "Paperole – All Papers – 2026-10-22.zip")
        e.ticked.subtract(e.students[1].papers.map(\.id))  // Maya Chen's box clicked (the sheet's checkboxes)
        XCTAssertEqual(e.mark(e.students[1].papers), .off)
        XCTAssertEqual(e.mark(e.exportable), .mixed)
        XCTAssertFalse(e.everything)
        XCTAssertEqual(e.fileName(day: "2026-10-22"), "Paperole – Retrieval-Augmented Docstrings – 2026-10-22.zip")
        e.ticked.formUnion(e.exportable.map(\.id))
        XCTAssertEqual(e.mark(e.exportable), .on)
        XCTAssertTrue(e.everything)
        // from Maya Chen's context menu: only hers
        e = ExportChoice.make(groups, only: Set([easy.path, kelp.path, gone.path, away.path]), origin: .window)
        XCTAssertEqual(e.mark(e.students[0].papers), .off)
        XCTAssertEqual(e.fileName(day: "2026-10-22"), "Paperole – Maya Chen – 2026-10-22.zip")
        XCTAssertEqual(e.summary, "2 papers · counting…")
        e.sizes = [easy.path: 1_000_000, kelp.path: 100_000]
        XCTAssertTrue(e.summary.hasPrefix("2 papers · up to 1.1 MB"), e.summary)
        // from a paper's: its title up to its colon
        e = ExportChoice.make(groups, only: [easy.path], origin: .window)
        XCTAssertEqual(e.fileName(day: "2026-10-22"), "Paperole – Easy Before Hard – 2026-10-22.zip")
    }

    // MARK: Import

    /// Each status's group, default and choices (DATA.md §5.3 as §0 amends it): a newer copy is used (yours kept),
    /// unless the file is Paperole Dev's; a paper on a drive not connected is never "missing"; a folder on disk is
    /// never moved over yours.
    func testImportDefaultsForEachStatus() throws {
        let parent = tmp.appendingPathComponent("Reviews")
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        func paper(_ folder: String, _ status: String, listed: String? = nil, inPlace: Bool = false) -> [String: Any] {
            ["folder": folder, "in_place": inPlace, "id": "p-" + folder, "title": "T " + folder, "student": "S", "was_at": NSNull(),
             "status": status, "reason": status == "cannot_import" ? "A file in it is damaged: r1/final.pdf." : NSNull(),
             "listed": listed ?? NSNull(), "this": ["round": 3, "open": true, "comments": 6, "saved": "2026-10-21T13:26:00+08:00"],
             "yours": ["round": 3, "open": true, "comments": 8], "problems": [], "draft": folder == "new" ? ["paper": "/x", "rounds": ["1": ["R1-01": "Hi"]]] : NSNull()]
        }
        func reply(dev: Bool, _ papers: [[String: Any]], settings: Bool = true, old: Bool = false) throws -> ArchiveCheck {
            let variant = (old ? "PaperCollab" : "Paperole") + (dev ? " Dev" : "")
            let r: [String: Any] = ["kind": "export", "zip": true, "schema": 2, "created": "2026-10-21T13:40:00+08:00",
                                    "made_by": ["variant": variant, "install": "i-1", "app": "0.2", "engine": "0.2.0"],
                                    "scope": "everything", "intact": true, "checked": true, "problems": [], "missing": [],
                                    "tags": ["schema": 1, "tags": [["id": "t-tone", "name": "Tone", "group": "style"]]],
                                    "settings": settings ? [AppModel.readingMarksKey: true] : NSNull(), "papers": papers]
            return try ArchiveCheck.decode(JSONSerialization.data(withJSONObject: r))
        }
        let away = "/Volumes/PC-No-Such-Drive-\(UUID().uuidString.prefix(6))/Reviews/Away"
        let here = parent.appendingPathComponent("Here").path
        try fm.createDirectory(atPath: here, withIntermediateDirectories: true)
        let papers = [paper("new", "new"), paper("back", "put_back", listed: parent.appendingPathComponent("Back").path),
                      paper("away", "put_back", listed: away), paper("same", "same", listed: here),
                      paper("older", "older", listed: here), paper("newer", "newer", listed: here),
                      paper("diverged", "diverged", listed: here), paper("damaged", "yours_damaged", listed: here),
                      paper("other", "different_paper", listed: here), paper("bad", "cannot_import"),
                      paper(here, "same", listed: here, inPlace: true), paper("/elsewhere/Newer", "newer", listed: here, inPlace: true)]
        let catalog = TagCatalog()
        var plan = ImportPlan.make(try reply(dev: false, papers), source: tmp.appendingPathComponent("f.zip"), catalog: catalog,
                                   destination: parent, emptyList: false)
        let got = plan.items.map { "\($0.group) \($0.choice.rawValue) " + $0.choices.map(\.rawValue).joined(separator: ",") }
        XCTAssertEqual(got, ["add add ", "putBack putBack ", "here keepMine keepMine,keepBoth", "here keepMine keepMine,keepBoth",
                             "here keepMine keepMine,useThis,keepBoth", "here useThis useThis,keepMine,keepBoth",
                             "here keepMine keepMine,useThis,keepBoth", "here useThis useThis,keepMine,keepBoth",
                             "add add ", "cannot skip ", "here keepMine ", "here keepMine keepMine,keepBoth"])
        XCTAssertEqual(plan.items[2].unplugged, String(away.split(separator: "/")[1]))
        XCTAssertEqual(ImportPlan.oldPlace(plan.items[1])?.path, parent.appendingPathComponent("Back").path, "its old place is free")
        // short facts, and a place only where it is not "Put them in": one line, the full path in its help tag
        let back = parent.appendingPathComponent("Back").path
        XCTAssertEqual(plan.detail(plan.items[1]), [.init(text: "3 rounds · 6 comments"),
                                                    .init(text: "Back where it was: " + DataFiles.shown(URL(fileURLWithPath: back)), path: back)])
        XCTAssertEqual(plan.detail(plan.items[0]).map(\.text), ["3 rounds · 6 comments"], "into Put them in: no place")
        XCTAssertEqual(plan.detail(plan.items[2]).map(\.text), ["Yours is on “\(plan.items[2].unplugged ?? "")”, not connected: plug it in to compare."])
        let newer = plan.detail(plan.items[5]).map(\.text)
        XCTAssertTrue(newer[0].hasPrefix("This copy: round 3 open · 6 comments · ") && newer[0].hasSuffix(" (newer)"), newer[0])
        XCTAssertEqual(newer[1], "Yours: round 3 open · 8 comments")
        XCTAssertEqual(plan.detail(plan.items[3]).map(\.text), ["Same as yours: " + ImportPlan.facts(plan.items[3].paper.this!)])
        XCTAssertEqual(plan.detail(plan.items[9]).map(\.text), ["A file in it is damaged: r1/final.pdf."])
        XCTAssertEqual(plan.detail(plan.items[10]).map(\.text), ["The very folder in your list."])
        XCTAssertTrue(plan.mayReplace, "Use This Copy is offered: where yours is kept is said")
        XCTAssertEqual(plan.actionTitle, "Import 5 Papers")
        XCTAssertTrue(plan.header.hasPrefix("Made "), plan.header)
        XCTAssertTrue(plan.header.hasSuffix(" by Paperole · 12 papers · every file intact"), plan.header)
        XCTAssertEqual(plan.tagWords, "Tags: adds Tone. Yours stay as they are.")
        XCTAssertEqual(plan.draftWords, "Drafts: 1, for T new; never over one of yours.")
        XCTAssertFalse(plan.useSettings, "the file's settings only for an empty list")
        XCTAssertTrue(plan.needsDestination)
        XCTAssertNil(plan.listedAtOnce)
        plan.destination = nil
        XCTAssertFalse(plan.canImport, "Put them in is needed")
        // Paperole Dev's file (made_by "Paperole Dev"): never Use This Copy by default
        plan = ImportPlan.make(try reply(dev: true, papers), source: tmp, catalog: catalog, destination: parent, emptyList: true)
        XCTAssertEqual(plan.items[5].choice, .keepMine)
        XCTAssertEqual(plan.items[7].choice, .keepMine)
        XCTAssertTrue(plan.check.fromDev)
        XCTAssertTrue(plan.header.contains(" by Paperole Dev · "), plan.header)
        XCTAssertTrue(plan.useSettings)
        // the files made before the app was renamed (made_by "PaperCollab Dev", "PaperCollab"): read the same way
        let before = ImportPlan.make(try reply(dev: true, papers, old: true), source: tmp, catalog: catalog, destination: parent,
                                     emptyList: true)
        XCTAssertEqual(before.items[5].choice, .keepMine)
        XCTAssertTrue(before.check.fromDev)
        XCTAssertTrue(before.header.contains(" by Paperole Dev · "), before.header)
        let official = ImportPlan.make(try reply(dev: false, papers, old: true), source: tmp, catalog: catalog, destination: parent,
                                       emptyList: false)
        XCTAssertFalse(official.check.fromDev)
        XCTAssertEqual(official.items[5].choice, .useThis)
        XCTAssertTrue(official.header.hasSuffix(" by Paperole · 12 papers · every file intact"), official.header)
        // a new paper whose folder is still where it was, not listed: already here; the list lost (empty), Keep Mine
        // lists yours there; a paper removed from the list is left out; never added beside yours unasked
        var found = paper("found", "new")
        found["found"] = here
        let lost = ImportPlan.make(try reply(dev: false, [found]), source: tmp, catalog: catalog, destination: parent, emptyList: true)
        XCTAssertEqual(lost.items.map { "\($0.group) \($0.choice.rawValue) " + $0.choices.map(\.rawValue).joined(separator: ",") },
                       ["here keepMine keepMine,keepBoth,skip"])
        XCTAssertEqual(lost.detail(lost.items[0]), [.init(text: "Still at " + DataFiles.shown(URL(fileURLWithPath: here)), path: here)])
        XCTAssertFalse(lost.mayReplace)
        XCTAssertEqual(lost.actionTitle, "Import 1 Paper")
        XCTAssertFalse(lost.needsDestination, "yours is listed where it is")
        let removed = ImportPlan.make(try reply(dev: false, [found]), source: tmp, catalog: catalog, destination: parent, emptyList: false)
        XCTAssertEqual(removed.items.map(\.choice), [.skip])
        XCTAssertEqual(removed.actionTitle, "Add the Tags")
        // one review folder found on disk: listed at once
        let one = ImportPlan.make(try reply(dev: false, [paper("/r/Kelp", "new", inPlace: true)], settings: false), source: tmp,
                                  catalog: catalog, destination: nil, emptyList: true)
        XCTAssertEqual(one.listedAtOnce, "/r/Kelp")
        XCTAssertFalse(one.needsDestination)
    }

    /// An `archive_check` reply of these papers (each `[String: Any]` as the engine writes it).
    private func check(_ papers: [[String: Any]], dev: Bool = false) throws -> ArchiveCheck {
        let r: [String: Any] = ["kind": "backup", "zip": true, "schema": 2, "created": "2026-10-21T13:40:00+08:00",
                                "made_by": ["variant": dev ? "Paperole Dev" : "Paperole", "install": "i-1"],
                                "intact": true, "checked": true, "papers": papers]
        return try ArchiveCheck.decode(JSONSerialization.data(withJSONObject: r))
    }

    /// Restore from Last Backup… uses the backup only over a damaged copy of yours or an older one; a backup older than
    /// yours, or changed since they parted, stays at Keep Mine (the code review: one click put an older, as damaged,
    /// copy in place of the advisor's newer ledger). The report's other papers stay out.
    func testRestoreUsesTheBackupOnlyOverADamagedOrOlderCopy() throws {
        let listed = tmp.appendingPathComponent("Reviews/Kelp drift").path
        let ref = PaperRef(path: listed, title: "Kelp drift", student: "Mei Lin")
        for dev in [false, true] {
            for (status, want) in [("older", ImportPlan.Choice.keepMine), ("diverged", .keepMine), ("same", .keepMine),
                                   ("newer", .useThis), ("yours_damaged", .useThis)] {
                let p: [String: Any] = ["folder": "students/Mei Lin/Kelp drift", "in_place": false, "id": "p-kelp", "title": "Kelp drift",
                                        "student": "Mei Lin", "status": status, "listed": listed,
                                        "this": ["round": 1, "open": true, "comments": 1], "yours": ["round": 1, "open": true, "comments": 2]]
                let other: [String: Any] = ["folder": "students/Ana/Pools", "in_place": false, "id": "p-pools", "title": "Pools",
                                            "student": "Ana", "status": "newer", "listed": tmp.appendingPathComponent("Reviews/Pools").path]
                var plan = ImportPlan.make(try check([p, other], dev: dev), source: tmp.appendingPathComponent("b.zip"),
                                           catalog: TagCatalog(), destination: nil, emptyList: false)
                plan.tickOnly(ref)
                XCTAssertEqual(plan.items.map(\.choice), [want, .keepMine], "\(status), dev \(dev)")
                XCTAssertTrue(plan.only)
            }
        }
    }

    /// A "yours damaged" row says both copies' round, comments and time, as the other rows of Already here do, and the
    /// damage the engine counted: never a harmless problem listed before it (`.orphans`).
    func testAYoursDamagedRowSaysBothCopiesAndTheDamage() throws {
        var p: [String: Any] = ["folder": "students/Mei Lin/Kelp drift", "in_place": false, "id": "p-kelp", "title": "Kelp drift",
                                "student": "Mei Lin", "status": "yours_damaged", "listed": "/r/Kelp drift",
                                "this": ["round": 2, "open": true, "comments": 6], "yours": ["round": 2, "open": false, "comments": 7],
                                "yours_problems": [["code": "orphans", "message": "Some files are left over."],
                                                   ["code": "round_changed", "message": "Round 1’s source was changed."]]]
        var plan = ImportPlan.make(try check([p]), source: tmp, catalog: TagCatalog(), destination: nil, emptyList: false)
        XCTAssertEqual(plan.detail(plan.items[0]).map(\.text),
                       ["This copy: round 2 open · 6 comments", "Yours: round 2 · 7 comments",
                        "Yours is damaged: Round 1’s source was changed. This copy is intact."])
        plan.items[0].choice = .keepBoth
        XCTAssertEqual(plan.detail(plan.items[0]).last?.text, "This copy is added with “(copy)” after its title.")
        // yours unread (its ledger gone): no facts of it
        p["yours"] = NSNull()
        p["yours_problems"] = [["code": "no_ledger", "message": "There is no ledger.json in this folder."]]
        plan = ImportPlan.make(try check([p]), source: tmp, catalog: TagCatalog(), destination: nil, emptyList: false)
        XCTAssertEqual(plan.detail(plan.items[0]).map(\.text),
                       ["This copy: round 2 open · 6 comments", "Yours is damaged: There is no ledger.json in this folder. This copy is intact."])
        p["yours_problems"] = []
        plan = ImportPlan.make(try check([p]), source: tmp, catalog: TagCatalog(), destination: nil, emptyList: false)
        XCTAssertEqual(plan.detail(plan.items[0]).last?.text, "Yours is damaged; this copy is intact.")
    }

    /// The very folder listed, reached through a symbolic link (its parent's, as the engine's realpath sees it):
    /// nothing to choose, never Keep Both (which would fork and retitle the advisor's only copy and list it twice), and
    /// listed at once by the list's own path.
    func testTheVeryFolderThroughALink() throws {
        let real = tmp.appendingPathComponent("Real")
        try fm.createDirectory(at: real.appendingPathComponent("Kelp drift"), withIntermediateDirectories: true)
        let link = tmp.appendingPathComponent("Link")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        let listed = link.appendingPathComponent("Kelp drift").path, folder = real.appendingPathComponent("Kelp drift").path
        XCTAssertTrue(ImportPlan.samePlace(listed, folder))
        XCTAssertTrue(ImportPlan.samePlace("/tmp/x", "/private/tmp/x"))
        XCTAssertFalse(ImportPlan.samePlace(listed, real.appendingPathComponent("Reef").path))
        let p: [String: Any] = ["folder": folder, "in_place": true, "id": "p-kelp", "title": "Kelp drift", "student": "Mei Lin",
                                "status": "same", "listed": listed, "this": ["round": 1, "open": true, "comments": 1]]
        let plan = ImportPlan.make(try check([p]), source: URL(fileURLWithPath: folder), catalog: TagCatalog(), destination: nil,
                                   emptyList: false)
        XCTAssertEqual(plan.items.map(\.choices), [[]])
        XCTAssertEqual(plan.detail(plan.items[0]).map(\.text), ["The very folder in your list."])
        XCTAssertEqual(plan.listedAtOnce, listed, "its entry, not a second one")
    }

    /// The three facts move from the list into each paper's ledger once (`adopt_facts`), the entry marked so (never
    /// saved by a test run); from then on they are written through the engine.
    func testTheFactsMoveIntoTheLedger() async throws {
        let m = try engineModel()
        let saved = try? fm.attributesOfItem(atPath: PaperStore.fileURL.path)[.modificationDate] as? Date
        var p = try await paper(m, tmp.appendingPathComponent("Reviews/Kelp drift"), title: "Kelp drift", student: "Mei Lin", rounds: 1)
        p.finished = "2026-07-20"
        p.buckets = ["1": "introduction", "2": ""]
        p.keyPage = KeyPageChoice(round: 1, page: 0)
        p.factsMoved = nil
        m.papers = [p]
        m.moveFactsIn()
        for _ in 0..<200 where m.papers.first?.factsMoved != true { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(m.papers.first?.factsMoved, true)
        var lg = try XCTUnwrap(ledger(p)["paper"] as? [String: Any])
        XCTAssertEqual(lg["finished"] as? String, "2026-07-20")
        XCTAssertEqual(lg["buckets"] as? NSDictionary, ["1": "introduction", "2": NSNull()] as NSDictionary)
        XCTAssertEqual(lg["key_page"] as? NSDictionary, ["round": 1, "page": 0] as NSDictionary)
        XCTAssertEqual(m.papers.first?.ledgerID, lg["id"] as? String)
        XCTAssertEqual(m.papers.first?.buckets, ["1": "introduction", "2": ""], "the copies as the ledger has them")
        // asked again: the ledger's are never overwritten, and nothing is written
        let rev = try ledger(p)["rev"] as? Int
        m.papers[0].factsMoved = nil
        m.papers[0].finished = "2020-01-01"
        m.moveFactsIn()
        for _ in 0..<200 where m.papers.first?.factsMoved != true { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(try ledger(p)["rev"] as? Int, rev)
        XCTAssertEqual(m.papers.first?.finished, "2026-07-20", "the ledger's wins")
        // then through the engine
        m.setFinished(p.path, false)
        m.setKeyPage(p.path, nil)
        _ = try await rpc(m, "summaries", ["papers": [p.path]])  // after them, in order
        lg = try XCTUnwrap(ledger(p)["paper"] as? [String: Any])
        XCTAssertTrue(lg["finished"] is NSNull)
        XCTAssertTrue(lg["key_page"] is NSNull)
        XCTAssertEqual(try? fm.attributesOfItem(atPath: PaperStore.fileURL.path)[.modificationDate] as? Date, saved,
                       "a test run never saves the list")
    }

    /// Export everything, delete the folders, the list, the drafts and a tag, import: every primary file, each round's
    /// state and the overview the same, the drafts and the tag back.
    func testExportEverythingAndImportItBack() async throws {
        let m = try engineModel()
        let root = tmp.appendingPathComponent("Reviews")
        let kelp = try await paper(m, root.appendingPathComponent("Kelp drift"), title: "Kelp drift", student: "Mei Lin")
        let reef = try await paper(m, root.appendingPathComponent("Reef choruses"), title: "Reef choruses", student: "Mei Lin", rounds: 1)
        let pools = try await paper(m, root.appendingPathComponent("Warm pools"), title: "Warm pools", student: "Ana Sousa")
        let all = [kelp, reef, pools]
        m.papers = all
        m.setKeyPage(kelp.path, KeyPageChoice(round: 2, page: 0))
        m.draftStore.save(paper: kelp.path, round: 2, drafts: ["R1-01": "Say more."])
        m.tags.update { _ = $0.add(name: "Tone") }
        let shown = try await views(m, all)  // after the key page's write, in order
        let before = all.map { files(URL(fileURLWithPath: $0.path)) }

        m.data.openExport(origin: .window)
        XCTAssertEqual(m.data.export?.chosen.count, 3)
        XCTAssertEqual(m.data.export?.everything, true)
        let zip = tmp.appendingPathComponent("Exports/" + (m.data.export?.fileName(day: "2026-10-22") ?? "x.zip"))
        try fm.createDirectory(at: zip.deletingLastPathComponent(), withIntermediateDirectories: true)
        m.data.writeExport(to: zip)
        try await settle(m.data)
        guard case .done(let words, let url)? = m.data.export?.phase else { return XCTFail("\(String(describing: m.data.export?.phase))") }
        XCTAssertEqual(url?.path, zip.path)
        XCTAssertTrue(words.hasPrefix("Saved and checked: Paperole – All Papers – 2026-10-22.zip ("), words)
        m.data.closeExport()

        // lost: the folders, the list, the drafts and the tag
        try fm.removeItem(at: root)
        m.papers = []
        m.draftStore.save(paper: kelp.path, round: 2, drafts: [:])
        m.tags.update { $0.tags.removeAll { $0.name == "Tone" } }

        m.data.checkImport(zip, origin: .window, into: root)
        try await settle(m.data)
        let plan = try XCTUnwrap(m.data.importing?.plan, m.data.importing?.error ?? "")
        XCTAssertEqual(plan.items.map(\.choice), [.add, .add, .add])
        XCTAssertTrue(plan.header.hasSuffix(" · 3 papers · every file intact"), plan.header)
        XCTAssertFalse(plan.header.contains("2026"), "this year's date without its year: \(plan.header)")
        XCTAssertEqual(plan.tagWords, "Tags: adds Tone. Yours stay as they are.")
        XCTAssertEqual(plan.draftWords, "Drafts: 1, for Kelp drift; never over one of yours.")
        XCTAssertEqual(plan.actionTitle, "Import 3 Papers")
        m.data.performImport()
        try await settle(m.data)
        let report = try XCTUnwrap(m.data.importing?.report, m.data.importing?.error ?? "")
        XCTAssertNil(report.stopped)
        XCTAssertEqual(report.groups, [ImportReport.Group(title: "Added to", place: root.path,
                                                          papers: ["Warm pools · Ana Sousa", "Kelp drift · Mei Lin", "Reef choruses · Mei Lin"])])
        XCTAssertTrue(report.lines.contains("Added 1 draft. Added 1 tag: Tone."), report.lines.joined(separator: "\n"))
        XCTAssertEqual(report.lines.last, "Nothing else changed.")
        XCTAssertEqual(Set(m.papers.map(\.path)), Set(all.map(\.path)))
        XCTAssertEqual(all.map { files(URL(fileURLWithPath: $0.path)) }, before, "every primary file, byte for byte")
        let shownAfter = try await views(m, all)
        XCTAssertEqual(shownAfter, shown, "each round's state and the overview")
        XCTAssertEqual(m.draftStore.load(paper: kelp.path, round: 2), ["R1-01": "Say more."])
        XCTAssertNotNil(m.tags.catalog.named("Tone"))
        XCTAssertEqual((try ledger(kelp)["paper"] as? [String: Any])?["key_page"] as? NSDictionary, ["round": 2, "page": 0] as NSDictionary)
        m.data.closeImport()
        XCTAssertNil(m.data.importing)
    }

    /// One student exported, their folders gone and their papers removed from the list, imported: the same. One paper
    /// whose folder is gone but still listed: put back where it was. One newer here: Keep Mine by default, Use This
    /// Copy keeps yours in "Replaced by Import".
    func testOneStudentOnePaperAndUseThisCopy() async throws {
        let m = try engineModel()
        let root = tmp.appendingPathComponent("Reviews")
        let kelp = try await paper(m, root.appendingPathComponent("Kelp drift"), title: "Kelp drift", student: "Mei Lin")
        let pools = try await paper(m, root.appendingPathComponent("Warm pools"), title: "Warm pools", student: "Ana Sousa", rounds: 1)
        m.papers = [kelp, pools]
        let kelpFiles = files(URL(fileURLWithPath: kelp.path)), poolsFiles = files(URL(fileURLWithPath: pools.path))

        // one student
        m.data.openExport(origin: .window, only: [kelp.path])
        let zip = tmp.appendingPathComponent(m.data.export?.fileName(day: "2026-10-22") ?? "x.zip")
        XCTAssertEqual(zip.lastPathComponent, "Paperole – Kelp drift – 2026-10-22.zip", "one paper: its title")
        m.data.writeExport(to: zip)
        try await settle(m.data)
        m.data.closeExport()
        try fm.removeItem(atPath: kelp.path)
        m.removePapers([kelp.path], student: "Mei Lin")
        m.data.checkImport(zip, origin: .window, into: root)
        try await settle(m.data)
        XCTAssertEqual(m.data.importing?.plan?.items.map(\.choice), [.add])
        m.data.performImport()
        try await settle(m.data)
        XCTAssertNil(m.data.importing?.report?.stopped)
        XCTAssertEqual(files(URL(fileURLWithPath: kelp.path)), kelpFiles)
        XCTAssertTrue(m.papers.contains { $0.path == kelp.path })
        m.data.closeImport()

        // one paper whose folder is gone, still listed: put back where it was
        let one = tmp.appendingPathComponent("pools.zip")
        m.data.openExport(origin: .window, only: [pools.path])
        m.data.writeExport(to: one)
        try await settle(m.data)
        m.data.closeExport()
        try fm.removeItem(atPath: pools.path)
        m.noteMissing()
        XCTAssertEqual(m.missingPapers, [pools.path], "its row says missing")
        // a missing paper waits on no one: not counted, no amber on its tile, its line says why (the sign red)
        XCTAssertNil(m.status(of: pools))
        XCTAssertFalse(m.yourMove.contains { $0.paper.path == pools.path })
        XCTAssertEqual(m.statusText(pools), "Its folder is missing")
        XCTAssertTrue(m.folderBroken(pools))
        m.data.checkImport(one, origin: .window, into: tmp.appendingPathComponent("Elsewhere"))
        try await settle(m.data)
        let back = try XCTUnwrap(m.data.importing?.plan)
        XCTAssertEqual(back.items.map(\.group), [.putBack])
        XCTAssertFalse(back.needsDestination, "back where it was")
        m.data.performImport()
        try await settle(m.data)
        XCTAssertEqual(m.data.importing?.report?.groups, [ImportReport.Group(title: "Put back where it was", papers: ["Warm pools · Ana Sousa"])])
        XCTAssertEqual(files(URL(fileURLWithPath: pools.path)), poolsFiles)
        XCTAssertEqual(m.papers.map(\.path), [pools.path, kelp.path], "in its entry's place")
        XCTAssertEqual(m.missingPapers, [])
        m.data.closeImport()

        // yours newer: Keep Mine by default (and nothing changes); Use This Copy keeps yours beside it
        try await rpc(m, "comment", ["paper": pools.path, "page": 0, "rects": [[133.7, 148.8, 230.2, 158.8]],
                                     "text": "Kelp drifts in the bay.", "note": "Since when?", "kind": "highlight"])
        let mine = files(URL(fileURLWithPath: pools.path))
        m.data.checkImport(one, origin: .window, into: root)
        try await settle(m.data)
        XCTAssertEqual(m.data.importing?.plan?.items.map(\.choice), [.keepMine])
        XCTAssertEqual(m.data.importing?.plan?.items.first?.paper.status, "older")
        m.data.importing?.plan?.items[0].choice = .useThis
        m.data.performImport()
        try await settle(m.data)
        XCTAssertEqual(m.data.importing?.report?.groups.first,
                       ImportReport.Group(title: "Used this copy; yours is kept in “Replaced by Import” beside it", papers: ["Warm pools · Ana Sousa"]))
        XCTAssertEqual(files(URL(fileURLWithPath: pools.path)), poolsFiles, "this copy in its place")
        let kept = root.appendingPathComponent("Replaced by Import")
        let copies = try fm.contentsOfDirectory(atPath: kept.path)
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(files(kept.appendingPathComponent(copies[0])), mine, "yours kept whole")
        XCTAssertEqual(DataPlaces.replaced(m.papers.map(\.path)).copies, 1)
        XCTAssertTrue(m.papers.contains { $0.path == pools.path }, "its entry stays")
    }

    /// A listed paper's folder moved in Finder and imported where it is: listed at its new place, and said so in the
    /// preview and the report, never "put back where it was".
    func testAFolderMovedInFinderIsListedWhereItIs() async throws {
        let m = try engineModel()
        var kelp = try await paper(m, tmp.appendingPathComponent("Reviews/Kelp drift"), title: "Kelp drift", student: "Mei Lin", rounds: 1)
        kelp.ledgerID = try XCTUnwrap((try ledger(kelp)["paper"] as? [String: Any])?["id"] as? String)
        m.papers = [kelp]
        let moved = tmp.appendingPathComponent("Moved/Kelp drift")
        try fm.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(atPath: kelp.path, toPath: moved.path)
        m.noteMissing()
        m.data.checkImport(moved, origin: .window)
        try await settle(m.data)
        let plan = try XCTUnwrap(m.data.importing?.plan, m.data.importing?.error ?? "")
        XCTAssertEqual(plan.items.map { "\($0.group) \($0.paper.status) \($0.paper.inPlace)" }, ["putBack put_back true"])
        XCTAssertEqual(ImportPlan.Group.putBack.title, "Will be listed again", "the group's title claims no old place")
        XCTAssertEqual(plan.detail(plan.items[0]).last?.text, "Listed where it is now: " + DataFiles.shown(moved))
        m.data.performImport()
        try await settle(m.data)
        XCTAssertNil(m.data.importing?.report?.stopped)
        XCTAssertEqual(m.data.importing?.report?.groups, [ImportReport.Group(title: "Listed where it is", papers: ["Kelp drift · Mei Lin"])])
        XCTAssertEqual(m.papers.map(\.path), [moved.path], "its entry, at its new place")
        m.data.closeImport()
    }

    /// Use This Copy of a paper opened again while the import runs (a Settings import, earlier papers unpacking): the
    /// paper is closed right before its folder is swapped, so no later edit goes to the copy set aside.
    func testUseThisCopyClosesThePaperOpenedMeanwhile() async throws {
        let m = try engineModel()
        let pools = try await paper(m, tmp.appendingPathComponent("Reviews/Warm pools"), title: "Warm pools", student: "Ana Sousa", rounds: 1)
        m.papers = [pools]
        let one = tmp.appendingPathComponent("pools.zip")
        m.data.openExport(origin: .settings)
        m.data.writeExport(to: one)
        try await settle(m.data)
        m.data.closeExport()
        let exported = files(URL(fileURLWithPath: pools.path))
        try await rpc(m, "comment", ["paper": pools.path, "page": 0, "rects": [[133.7, 148.8, 230.2, 158.8]],
                                     "text": "Kelp drifts in the bay.", "note": "Since when?", "kind": "highlight"])
        m.data.checkImport(one, origin: .settings)
        try await settle(m.data)
        m.data.importing?.plan?.items[0].choice = .useThis
        m.data.performImport()
        m.selectPaper(pools.path)  // opened again from the sidebar once the import has begun
        XCTAssertEqual(m.selectedPath, pools.path)
        try await settle(m.data)
        XCTAssertNil(m.data.importing?.report?.stopped, m.data.importing?.report?.stopped ?? "")
        XCTAssertNil(m.selectedPath, "closed before its folder was swapped")
        XCTAssertEqual(files(URL(fileURLWithPath: pools.path)), exported, "this copy in its place")
    }

    /// Cancel is no error: an export cancelled while it writes says so as a quiet line in its sheet and in Settings
    /// (nothing written); an import cancelled between papers reports what came in, its stop a quiet line. And the
    /// review's engine answers while an export writes.
    func testCancelIsAQuietLine() async throws {
        let m = try engineModel()
        let root = tmp.appendingPathComponent("Reviews")
        let kelp = try await paper(m, root.appendingPathComponent("Kelp drift"), title: "Kelp drift", student: "Mei Lin", rounds: 1)
        let reef = try await paper(m, root.appendingPathComponent("Reef choruses"), title: "Reef choruses", student: "Mei Lin", rounds: 1)
        m.papers = [kelp, reef]
        // a big file in the folder, so the export is still writing when Cancel comes
        let noise = try XCTUnwrap(FileHandle(forReadingAtPath: "/dev/urandom")).readData(ofLength: 48_000_000)
        let big = URL(fileURLWithPath: kelp.path).appendingPathComponent("notes.bin")
        try noise.write(to: big)
        let zip = tmp.appendingPathComponent("all.zip")
        m.data.openExport(origin: .settings)
        m.data.writeExport(to: zip)
        for _ in 0..<400 where !(m.data.step ?? "").hasPrefix("Writing “") { try await Task.sleep(nanoseconds: 10_000_000) }
        // the archive has an engine process of its own: the review's requests never wait behind it
        try await rpc(m, "summaries", ["papers": [reef.path]])
        XCTAssertTrue(m.data.working, "answered while the export still writes")
        m.data.cancelWork()
        try await settle(m.data)
        XCTAssertEqual(m.data.export?.phase, .done("Cancelled. Nothing was written.", nil))
        XCTAssertEqual(m.data.status, .done("Cancelled. Nothing was written.", nil))
        XCTAssertFalse(fm.fileExists(atPath: zip.path))
        m.data.closeExport()
        try fm.removeItem(at: big)

        m.data.openExport(origin: .settings)
        m.data.writeExport(to: zip)
        try await settle(m.data)
        m.data.closeExport()
        m.papers = []
        try fm.removeItem(at: root)
        m.data.checkImport(zip, origin: .settings, into: root)
        try await settle(m.data)
        XCTAssertEqual(m.data.importing?.plan?.items.map(\.choice), [.add, .add])
        m.data.performImport()
        m.data.cancelWork()  // before the first paper
        try await settle(m.data)
        let report = try XCTUnwrap(m.data.importing?.report)
        XCTAssertTrue(report.cancelled)
        XCTAssertTrue(report.stopped?.hasPrefix("Stopped before “") == true && report.stopped?.hasSuffix(" (Mei Lin): cancelled.") == true,
                      report.stopped ?? "")
        XCTAssertEqual(report.title, "Imported 0 of 2 papers")
        XCTAssertEqual(m.data.status, .done("Imported 0 of 2 papers from “all.zip”.", nil), "not the status line's error")
        XCTAssertEqual(m.papers, [])
        m.data.closeImport()
    }

    /// A paper whose folder is gone is shown by the list's own copies of its title and student wherever it is shown:
    /// its student's group (the sidebar, All Students), its page and the window's subtitle; never its folder's name
    /// and Unassigned. The copies follow Edit Paper…, Rename Student… and a change made on the command line while the
    /// folder is there.
    func testAMissingPaperKeepsTheListsNames() async throws {
        let m = try engineModel()
        let root = tmp.appendingPathComponent("Reviews")
        let kelp = try await paper(m, root.appendingPathComponent("kelp-drift"), title: "Kelp drift", student: "Mei Lin", rounds: 1)
        let reef = try await paper(m, root.appendingPathComponent("reef"), title: "Reef choruses", student: "Mei Lin", rounds: 1)
        m.papers = [kelp, reef]
        func until(_ what: String, _ ok: () -> Bool) async throws {
            for _ in 0..<200 where !ok() { try await Task.sleep(nanoseconds: 50_000_000) }
            XCTAssertTrue(ok(), what)
        }
        m.editPaper(kelp.path, title: "Kelp drift in the bay", student: nil)
        try await until("Edit Paper… renames the list's copy") { m.papers[0].title == "Kelp drift in the bay" }
        m.renameStudent(StudentName.key("Mei Lin"), to: "Mei L. Lin")
        try await until("Rename Student… changes each copy") { m.papers.allSatisfy { $0.student == "Mei L. Lin" } }
        try await rpc(m, "edit_paper", ["paper": reef.path, "title": "Reef choruses at dusk"])
        m.refreshSummaries()
        try await until("a change on the command line is read again") { m.papers[1].title == "Reef choruses at dusk" }

        try fm.removeItem(atPath: kelp.path)
        m.refreshSummaries()
        m.openHub(.allStudents)
        try await until("the hierarchy's numbers") { m.hubModel.status == .loaded }
        XCTAssertEqual(m.missingPapers, [kelp.path])
        XCTAssertEqual(m.studentGroups.map(\.name), ["Mei L. Lin"], "not Unassigned")
        XCTAssertEqual(m.studentGroups.first?.papers.map(\.title), ["Kelp drift in the bay", "Reef choruses at dusk"])
        XCTAssertEqual(m.statusText(m.papers[0]), "Its folder is missing")
        m.openPaper(kelp.path)
        try await Task.sleep(nanoseconds: 1_000_000_000)  // its state asked for, and not read
        XCTAssertNil(m.state)
        XCTAssertNil(m.alertMessage, "its page says the folder is missing: no alert with its path")
        XCTAssertEqual(m.windowSubtitle, "Mei L. Lin", "the window says whose it is")
        XCTAssertEqual(m.papers[0].title, "Kelp drift in the bay", "nothing read since changed the copies")
        XCTAssertEqual(m.papers[0].student, "Mei L. Lin")
    }

    /// A date this year without its year ("Oct 22 at 14:31"), another year's with it; a test run's list from a file.
    func testShortDatesAndATestRunsList() throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-22T15:00:00Z")!
        let this = try XCTUnwrap(TransferText.when("2026-10-22T14:31:00Z", now: now))
        XCTAssertFalse(this.contains("2026"), this)
        XCTAssertTrue(this.hasPrefix("Oct 22"), this)
        XCTAssertTrue(try XCTUnwrap(TransferText.when("2025-10-22T14:31:00Z", now: now)).contains("2025"))
        // a copy's facts in the preview: another year's date with its year, as the header's
        let old = ImportPlan.facts(ArchiveCheck.Facts(round: 2, open: true, comments: 6, saved: "2025-10-22T14:31:00Z"))
        XCTAssertTrue(old.hasPrefix("round 2 open · 6 comments · ") && old.contains("2025"), old)
        XCTAssertEqual(TransferText.row("Kelp drift", "Mei Lin"), "Kelp drift · Mei Lin")
        XCTAssertEqual(TransferText.row("Kelp drift", ""), "Kelp drift")
        XCTAssertEqual(LaunchOptions.parse(["app", "--list", "/x/papers.json", "--background"]).list, "/x/papers.json")
    }

    /// The list lost while the review folders stay where they were: the file's copy of each is found there, and Keep
    /// Mine (the default, the list being empty) lists yours where it is, nothing written; Keep Both also adds the
    /// file's copy, with an id and a title of its own, yours as it was. Never an older copy added beside yours unasked.
    func testAFileImportedAfterTheListIsLost() async throws {
        let m = try engineModel()
        let root = tmp.appendingPathComponent("Reviews")
        let kelp = try await paper(m, root.appendingPathComponent("Kelp drift"), title: "Kelp drift", student: "Mei Lin", rounds: 1)
        m.papers = [kelp]
        let zip = tmp.appendingPathComponent("all.zip")
        m.data.openExport(origin: .window)
        m.data.writeExport(to: zip)
        try await settle(m.data)
        m.data.closeExport()
        try await rpc(m, "edit_paper", ["paper": kelp.path, "title": "Kelp drift in the bay"])  // yours newer since
        let mine = files(URL(fileURLWithPath: kelp.path))
        m.papers = []

        m.data.checkImport(zip, origin: .window, into: root)
        try await settle(m.data)
        var plan = try XCTUnwrap(m.data.importing?.plan, m.data.importing?.error ?? "")
        XCTAssertEqual(plan.items.map(\.choice), [.keepMine])
        XCTAssertEqual(plan.items.first?.paper.found, kelp.path)
        m.data.performImport()
        try await settle(m.data)
        XCTAssertNil(m.data.importing?.report?.stopped)
        XCTAssertEqual(m.data.importing?.report?.groups, [ImportReport.Group(title: "Listed where it is", papers: ["Kelp drift · Mei Lin"])])
        XCTAssertEqual(m.papers.map(\.path), [kelp.path], "yours, listed where it is")
        XCTAssertEqual(files(URL(fileURLWithPath: kelp.path)), mine, "yours as it was")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.path).filter { !$0.hasPrefix(".") }, ["Kelp drift"], "nothing unpacked")
        m.data.closeImport()

        m.papers = []
        m.data.checkImport(zip, origin: .window, into: root)
        try await settle(m.data)
        plan = try XCTUnwrap(m.data.importing?.plan, m.data.importing?.error ?? "")
        m.data.importing?.plan?.items[0].choice = .keepBoth
        XCTAssertEqual(m.data.importing?.plan.map { $0.detail($0.items[0]) }?.last?.text, "This copy is added with “(copy)” after its title.")
        m.data.performImport()
        try await settle(m.data)
        XCTAssertNil(m.data.importing?.report?.stopped)
        XCTAssertEqual(files(URL(fileURLWithPath: kelp.path)), mine, "yours as it was")
        XCTAssertEqual(m.papers.map(\.path), [kelp.path, root.appendingPathComponent("Kelp drift 2").path])
        let copy = m.papers[1]
        XCTAssertEqual(copy.title, "Kelp drift (copy)")
        let theirs = try ledger(copy)["paper"] as? [String: Any], yours = try ledger(kelp)["paper"] as? [String: Any]
        XCTAssertEqual(theirs?["title"] as? String, "Kelp drift (copy)")
        XCTAssertNotEqual(theirs?["id"] as? String, yours?["id"] as? String)
        m.data.closeImport()
    }

    /// Two listed folders with one id (a review folder copied in Finder, both listed): the later entry gets an id of its
    /// own (`fork`, the old one kept as `forked_from`) and the window's line says so; the first keeps its id.
    func testACopyOfAListedFolderGetsAnIDOfItsOwn() async throws {
        let m = try engineModel()
        let root = tmp.appendingPathComponent("Reviews")
        let kelp = try await paper(m, root.appendingPathComponent("Kelp drift"), title: "Kelp drift", student: "Mei Lin", rounds: 1)
        let copy = PaperRef(path: root.appendingPathComponent("Kelp drift copy").path, title: "Kelp drift", student: "Mei Lin",
                            factsMoved: true)
        try fm.copyItem(atPath: kelp.path, toPath: copy.path)
        let id = try XCTUnwrap((try ledger(kelp)["paper"] as? [String: Any])?["id"] as? String)
        m.papers = [kelp, copy]
        m.refreshSummaries()
        for _ in 0..<200 where m.papers[1].ledgerID == nil || m.papers[1].ledgerID == id {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let theirs = try XCTUnwrap(try ledger(copy)["paper"] as? [String: Any])
        XCTAssertEqual(theirs["forked_from"] as? String, id)
        XCTAssertEqual(m.papers[1].ledgerID, theirs["id"] as? String)
        XCTAssertNotEqual(m.papers[1].ledgerID, id)
        XCTAssertEqual((try ledger(kelp)["paper"] as? [String: Any])?["id"] as? String, id, "the first keeps its id")
        XCTAssertEqual(m.papers[0].ledgerID, id)
        XCTAssertTrue(m.notice?.text.contains("was a copy of another listed folder") == true, m.notice?.text ?? "")
    }

    /// What an import or backup killed midway left, over a day old, is removed at launch: only the engine's hidden
    /// staging folders (.Paperole-import-…, or .PaperCollab-import-… as the engine named them before the rename) and
    /// (in the backup folder) its hidden partial .zip files; never a link, a newer one or anything else. And the papers list's daily copy: the list as it was before the day's first save, the 14 newest kept.
    func testLeftoversSweptAndTheListsDailyCopy() throws {
        let dir = tmp.appendingPathComponent("Reviews")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = Date().addingTimeInterval(-2 * 86400)
        func make(_ name: String, folder: Bool, at date: Date) throws {
            let u = dir.appendingPathComponent(name)
            if folder {
                try fm.createDirectory(at: u.appendingPathComponent("r1"), withIntermediateDirectories: true)
            } else {
                try Data("x".utf8).write(to: u)
            }
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: u.path)
        }
        try make(".PaperCollab-import-abc", folder: true, at: old)
        try make(".Paperole-import-def", folder: true, at: old)
        try make(".Paperole-import-new", folder: true, at: Date())
        try make(".PaperCollab-import-new", folder: true, at: Date())  // an import may be running
        try make(".PaperCollab Backup 2026-10-20 0900.zip.k3j2.tmp", folder: false, at: old)
        try make("Kelp drift", folder: true, at: old)
        try make(".notes.tmp", folder: false, at: old)
        try fm.createSymbolicLink(atPath: dir.appendingPathComponent(".PaperCollab-import-link").path,
                                  withDestinationPath: dir.appendingPathComponent("Kelp drift").path)
        let before = Date().addingTimeInterval(-86400)
        XCTAssertEqual(Set(DataModel.sweep(dir, zips: false, before: before).map(\.lastPathComponent)),
                       [".PaperCollab-import-abc", ".Paperole-import-def"])
        XCTAssertEqual(DataModel.sweep(dir, zips: true, before: before).map(\.lastPathComponent),
                       [".PaperCollab Backup 2026-10-20 0900.zip.k3j2.tmp"])
        XCTAssertEqual(Set(try fm.contentsOfDirectory(atPath: dir.path)),
                       [".PaperCollab-import-new", ".Paperole-import-new", "Kelp drift", ".notes.tmp", ".PaperCollab-import-link"])
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("Kelp drift/r1").path))

        let list = tmp.appendingPathComponent("data/papers.json")
        let copies = list.deletingLastPathComponent().appendingPathComponent("papers copies")
        let kelp = PaperRef(path: "/r/Kelp drift", title: "Kelp drift", student: "Mei Lin")
        try PaperStore.save([], to: list, day: "2026-10-01")
        XCTAssertFalse(fm.fileExists(atPath: copies.path), "no list before it: nothing to copy")
        try PaperStore.save([kelp], to: list, day: "2026-10-01")
        try PaperStore.save([kelp, kelp], to: list, day: "2026-10-01")
        let first = copies.appendingPathComponent("papers 2026-10-01.json")
        XCTAssertEqual(PaperStore.load(from: first).papers, [], "the list as it was before the day's first save")
        try Data("mine".utf8).write(to: copies.appendingPathComponent("notes.txt"))
        for d in 2...20 { try PaperStore.save([kelp], to: list, day: String(format: "2026-10-%02d", d)) }
        let kept = try fm.contentsOfDirectory(atPath: copies.path).sorted()
        XCTAssertEqual(kept.count, 15)
        XCTAssertEqual(kept.first, "notes.txt")
        XCTAssertEqual(kept[1], "papers 2026-10-07.json")
        XCTAssertEqual(kept.last, "papers 2026-10-20.json")
        XCTAssertEqual(PaperStore.load(from: list).papers, [kelp])
    }

    /// Quitting closes an Export or Import sheet that waits for the advisor (nothing was done yet).
    func testQuittingClosesAWaitingSheet() throws {
        let m = fixtureModel()
        m.data.openExport(origin: .settings)
        XCTAssertNotNil(m.data.export)
        XCTAssertTrue(AppDelegate.dataAllowsQuit(m.data))
        XCTAssertNil(m.data.export)
        XCTAssertFalse(m.data.quitWhenDone)
    }
}
