import AppKit
import SwiftUI
import XCTest
@testable import Paperole

/// Settings › Data & Storage (UX.md §28), on synthetic review folders in temporary folders only: names that never
/// replace anything, files written whole or not at all, the tags' file and merge, comments as CSV and JSON from the
/// engine's reply, New Paper…'s folder, drafts merged and moved, thumbnails cleared, and the tab. Export and Import:
/// DataTransferTests.
@MainActor
final class DataStorageTests: XCTestCase {
    private var tmp: URL!
    private var windows: [NSWindow] = []

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pc-data-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        windows.forEach { $0.close() }
        windows = []
        try? FileManager.default.removeItem(at: tmp)
    }

    private var fm: FileManager { .default }

    private func makeModel() -> AppModel {
        _ = NSApplication.shared
        var o = LaunchOptions()
        o.fixture = ReadingTests.fixtures.appendingPathComponent("state-reading.json").path
        o.drafts = tmp.appendingPathComponent("drafts").path
        o.cache = tmp.appendingPathComponent("cache").path
        o.tags = tmp.appendingPathComponent("tags/tags.json").path
        return AppModel(options: o)
    }

    // MARK: Files

    func testNamesNeverReplaceAnything() throws {
        try fm.createDirectory(at: tmp.appendingPathComponent("Kelp"), withIntermediateDirectories: true)
        try fm.createDirectory(at: tmp.appendingPathComponent("Kelp 2"), withIntermediateDirectories: true)
        try Data().write(to: tmp.appendingPathComponent("a.zip"))
        XCTAssertEqual(DataFiles.unique("Kelp", in: tmp).lastPathComponent, "Kelp 3")
        XCTAssertEqual(DataFiles.unique("a.zip", in: tmp, file: true).lastPathComponent, "a 2.zip")
        XCTAssertEqual(DataFiles.unique("New", in: tmp).lastPathComponent, "New")
        XCTAssertEqual(DataFiles.unique("New", in: tmp, taken: ["new"]).lastPathComponent, "New 2")
        XCTAssertEqual(DataFiles.unique("Kelp 2", in: tmp).lastPathComponent, "Kelp 2 2", "a number in a name is the name's")
        XCTAssertEqual(DataFiles.unique("Kelp 7", in: tmp).lastPathComponent, "Kelp 7")
        // a title ending in a number never turns into another one (the code audit: "Llama 3" made "Llama 4")
        try fm.createDirectory(at: tmp.appendingPathComponent("Llama 3"), withIntermediateDirectories: true)
        try fm.createDirectory(at: tmp.appendingPathComponent("ICLR 2026"), withIntermediateDirectories: true)
        try fm.createDirectory(at: tmp.appendingPathComponent("Llama 3.1"), withIntermediateDirectories: true)
        XCTAssertEqual(DataFiles.unique("Llama 3", in: tmp).lastPathComponent, "Llama 3 2")
        XCTAssertEqual(DataFiles.unique("ICLR 2026", in: tmp).lastPathComponent, "ICLR 2026 2")
        XCTAssertEqual(DataFiles.unique("Llama 3.1", in: tmp).lastPathComponent, "Llama 3.1 2", "a folder has no extension")
        XCTAssertEqual(DataFiles.name("A/B: kelp   drift"), "A-B- kelp drift")
        XCTAssertEqual(DataFiles.name(".hidden"), "hidden")
        XCTAssertEqual(DataFiles.name("  "), "Paper")
        XCTAssertEqual(DataFiles.name(String(repeating: "x", count: 200)).count, 80)
        XCTAssertEqual(DataFiles.name("海带漂移"), "海带漂移")
    }

    func testAFileIsWrittenWholeOrNotAtAll() throws {
        let dest = tmp.appendingPathComponent("out.csv")
        XCTAssertThrowsError(try DataFiles.write(to: dest) { u in
            try Data("half".utf8).write(to: u)
            throw DataFailure(message: "stopped")
        })
        XCTAssertFalse(fm.fileExists(atPath: dest.path))
        try Data("old".utf8).write(to: dest)
        XCTAssertThrowsError(try DataFiles.write(to: dest) { _ in throw CancellationError() })
        XCTAssertEqual(try Data(contentsOf: dest), Data("old".utf8))
        try DataFiles.write(to: dest) { try Data("new".utf8).write(to: $0) }
        XCTAssertEqual(try Data(contentsOf: dest), Data("new".utf8))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: tmp.path), ["out.csv"])
    }

    // MARK: Tags

    func testTagsAreMergedWithoutDuplicates() throws {
        var mine = TagCatalog()
        mine.tags.append(WritingTag(id: "u-00000001", name: "Rigor", group: .other, sign: "leaf"))
        mine.tags[0].name = "Grammar & articles"
        let theirs = [WritingTag(id: "grammar", name: "Grammar", group: .language),
                      WritingTag(id: "u-00000001", name: "Rigour", group: .other),
                      WritingTag(id: "u-00000002", name: " rigor ", group: .other),
                      WritingTag(id: "u-00000003", name: "Tone", group: .language, sign: "leaf", hidden: true),
                      WritingTag(id: "u-00000004", name: "Novelty", group: .thinking, sign: "flag"),
                      WritingTag(id: "BAD id", name: "Bad", group: .other)]
        let m = mine.merging(theirs)
        XCTAssertEqual(m.added.map(\.name), ["Tone", "Novelty"])
        XCTAssertEqual(m.same, 2)
        XCTAssertEqual(m.clashes, ["rigor"])
        XCTAssertEqual(m.catalog.tags.prefix(mine.tags.count).map(\.name), mine.tags.map(\.name), "nothing here changes")
        XCTAssertEqual(m.catalog.tags.count, mine.tags.count + 2)
        let tone = try XCTUnwrap(m.catalog.tag("u-00000003"))
        XCTAssertTrue(tone.hidden)
        XCTAssertEqual(tone.sign, "bookmark", "a sign means one tag: not Rigor's leaf, nor Novelty's flag")
        let signs = m.catalog.tags.compactMap(\.sign)
        XCTAssertEqual(Set(signs).count, signs.count)
        XCTAssertEqual(m.catalog.tag("u-00000004")?.sign, "flag")
        XCTAssertEqual(mine.merging(mine.tags).added, [])
        XCTAssertEqual(DataModel.tagWords(["Tone", "Novelty"], same: 2, clashes: ["rigor"]),
                       "Added 2 tags: Tone, Novelty. 2 tags were here already. Left out, as you have a tag of that name: rigor.")
        XCTAssertEqual(DataModel.tagWords([], same: 11, clashes: []), "Nothing to add: you have every tag in it.")
    }

    func testTheTagsFile() throws {
        var c = TagCatalog()
        c.tags.append(WritingTag(id: "u-0000abcd", name: "Tone", group: .language, hint: "Register.", sign: "leaf"))
        let u = tmp.appendingPathComponent("tags.json")
        try TagFile.data(c).write(to: u)
        XCTAssertEqual(try TagFile.read(u), c.tags)
        // the same shape as the app's own tags.json
        let store = TagStore(url: tmp.appendingPathComponent("store/tags.json"))
        store.save(c)
        XCTAssertEqual(try TagFile.read(store.url), c.tags)
        try Data(#"{"schema": 1, "paper": {}}"#.utf8).write(to: u)
        XCTAssertThrowsError(try TagFile.read(u)) { XCTAssertTrue($0.localizedDescription.contains("no Paperole tags")) }
    }

    // MARK: Comments

    static let reply = #"""
    {"papers": [
      {"path": "/r/kelp", "paper": {"title": "Kelp drift", "student": "Mei Lin"}, "tag_names": {"u-0000abcd": "Tone"},
       "comments": [
         {"id": "R1-01", "created_round": 1, "created": "2026-10-14T10:00:00+08:00", "kind": "highlight", "color": "blue",
          "note": "Shorter, \"please\", and\nsimpler.", "tags": ["u-0000abcd", "grammar"],
          "rounds": [
            {"round": 1, "section": "1 Introduction", "page": 0, "place": "placed", "state": "new", "response": "new",
             "answer": null, "verdict": null, "verdict_note": "", "student_note": null, "text": "Kelp rafts, drift"},
            {"round": 2, "section": "1 Introduction", "page": 1, "place": "placed", "state": "changed", "response": "edited",
             "answer": "follow_up", "verdict": "reopened", "verdict_note": "还是太长。", "student_note": "Cut it.",
             "text": "Kelp rafts drift"}]},
         {"id": "R2-01", "created_round": 2, "kind": "note", "note": "Grid size?", "tags": [],
          "rounds": [{"round": 2, "section": null, "page": null, "place": "unplaced", "state": "orphan", "response": "new",
                      "answer": null, "verdict": null, "verdict_note": "", "student_note": null, "text": ""}]}]},
      {"path": "/r/gone", "error": "No ledger.json in /r/gone."}]}
    """#

    func testCommentsAsCSVAndJSON() throws {
        let reply = try makeDecoder().decode(CommentExportReply.self, from: Data(Self.reply.utf8))
        var catalog = TagCatalog()
        catalog.tags[0].name = "Grammar & articles"
        let rows = CommentExport.rows(reply, catalog: catalog)
        XCTAssertEqual(rows.count, 3, "one row for each round a comment is in")
        XCTAssertEqual(rows[0], ["Mei Lin", "Kelp drift", "R1-01", "1", "1", "1 Introduction", "1", "in the PDF", "new this round", "",
                                 "", "", "Grammar & articles; Tone", "highlight", "Shorter, \"please\", and\nsimpler.", "Kelp rafts, drift"])
        XCTAssertEqual(Array(rows[1][4...11]), ["2", "1 Introduction", "2", "in the PDF", "edited", "Followed up", "还是太长。", "Cut it."])
        XCTAssertEqual(Array(rows[2][5...9]), ["", "", "not found", "new this round", ""])
        let csv = try XCTUnwrap(String(data: CommentExport.csv(reply, catalog: catalog), encoding: .utf8))
        XCTAssertTrue(csv.hasPrefix("\u{FEFF}Student,Paper,Comment,Written in round,Round,Section,Page,Where,"))
        XCTAssertTrue(csv.contains(",\"Shorter, \"\"please\"\", and\nsimpler.\",\"Kelp rafts, drift\"\r\n"), csv)
        XCTAssertEqual(csv.components(separatedBy: "\r\n").count, 5)  // the header, three rows, the end
        XCTAssertEqual(CommentExport.field("plain"), "plain")
        XCTAssertEqual(CommentExport.field("a,b"), "\"a,b\"")
        // a field that would start a formula in Excel is text (the code audit: CSV injection)
        XCTAssertEqual(CommentExport.field("- add a citation"), "\"'- add a citation\"")
        XCTAssertEqual(CommentExport.field("=HYPERLINK(\"x\")"), "\"'=HYPERLINK(\"\"x\"\")\"")
        XCTAssertEqual(CommentExport.field("+1"), "\"'+1\"")
        XCTAssertEqual(CommentExport.field("@SUM(A1)"), "\"'@SUM(A1)\"")
        XCTAssertEqual(CommentExport.field("\tx"), "\"'\tx\"")
        XCTAssertEqual(CommentExport.field("a - b = c"), "a - b = c", "only a field's first character")
        XCTAssertEqual(CommentExport.field(""), "")

        let json = try CommentExport.json(reply, catalog: catalog, of: "Mei Lin", exported: "2026-10-20T23:00:00+08:00")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(root["schema"] as? Int, 1)
        XCTAssertEqual(root["of"] as? String, "Mei Lin")
        XCTAssertEqual((root["errors"] as? [[String: String]])?.first?["folder"], "/r/gone")
        let papers = try XCTUnwrap(root["papers"] as? [[String: Any]])
        XCTAssertEqual(papers.count, 1)
        let c = try XCTUnwrap((papers[0]["comments"] as? [[String: Any]])?.first)
        XCTAssertEqual(c["tags"] as? [String], ["Grammar & articles", "Tone"])
        XCTAssertEqual(c["tag_ids"] as? [String], ["grammar", "u-0000abcd"])
        let r2 = try XCTUnwrap((c["rounds"] as? [[String: Any]])?.last)
        XCTAssertEqual(r2["page"] as? Int, 2)
        XCTAssertEqual(r2["answer"] as? String, "Followed up")
        XCTAssertEqual(r2["verdict"] as? String, "reopened")
        XCTAssertEqual(r2["student_note"] as? String, "Cut it.")
        XCTAssertEqual(CommentExport.fileName("Mei Lin", student: true, format: .csv), "Mei Lin’s comments.csv")
        XCTAssertEqual(CommentExport.fileName("Kelp: drift", student: false, format: .json), "Kelp- drift comments.json")
    }

    // MARK: Smaller parts

    func testNewPaperPutsItsFolderInTheDefaultFolder() throws {
        XCTAssertNil(NewPaperSheet.folder(chosen: nil, root: nil, title: "Kelp"))
        XCTAssertNil(NewPaperSheet.folder(chosen: nil, root: tmp, title: "  "))
        XCTAssertEqual(NewPaperSheet.folder(chosen: "/x/y", root: tmp, title: "Kelp"), "/x/y")
        XCTAssertEqual(NewPaperSheet.folder(chosen: nil, root: tmp, title: "Kelp: drift"), tmp.appendingPathComponent("Kelp- drift").path)
        try fm.createDirectory(at: tmp.appendingPathComponent("Kelp- drift"), withIntermediateDirectories: true)
        XCTAssertEqual(NewPaperSheet.folder(chosen: nil, root: tmp, title: "Kelp: drift"), tmp.appendingPathComponent("Kelp- drift 2").path)
        // the folder is a setting a test run never saves, and is used only while it is there
        let m = makeModel()
        let key = DataModel.reviewRootKey
        let saved = UserDefaults.standard.object(forKey: key) as? String
        m.data.reviewRoot = tmp.path
        XCTAssertEqual(m.data.root?.path, tmp.path)
        m.data.reviewRoot = tmp.appendingPathComponent("unplugged").path
        XCTAssertNil(m.data.root)
        XCTAssertEqual(UserDefaults.standard.object(forKey: key) as? String, saved)
        // the default (DATA.md §0.3): ~/Reviews, Paperole Dev's own (~/Paperole Dev Reviews; a test run never looks for
        // the old ~/PaperCollab Dev Reviews: DataHome); a test run has none, so it makes nothing at home
        XCTAssertEqual(DataPlaces.defaultRoot.lastPathComponent, "Paperole Dev Reviews")
        m.data.reviewRoot = nil
        XCTAssertNil(m.data.root)
        XCTAssertNil(m.data.rootShown)
    }

    /// Import's drafts: an imported paper's drafts file kept under its path here, never over a draft here; Use This
    /// Copy's: the drafts typed against the replaced copy follow it.
    func testDraftsMergedAndMoved() throws {
        let theirs = DraftStore(directory: tmp.appendingPathComponent("theirs"))
        theirs.save(paper: "/old/kelp", round: 2, drafts: ["R1-01": "Say more.", "R1-02": "Which beach?"])
        let file = try JSONSerialization.data(withJSONObject: try XCTUnwrap(theirs.json(paper: "/old/kelp")))
        XCTAssertNil(theirs.json(paper: "/old/none"))
        let mine = DraftStore(directory: tmp.appendingPathComponent("mine"))
        mine.save(paper: "/new/kelp", round: 2, drafts: ["R1-01": "Mine."])
        XCTAssertEqual(mine.merge(file: file, into: "/new/kelp"), 1)
        XCTAssertEqual(mine.load(paper: "/new/kelp", round: 2), ["R1-01": "Mine.", "R1-02": "Which beach?"])
        XCTAssertEqual(mine.merge(file: Data("not json".utf8), into: "/new/kelp"), 0)
        mine.move(from: "/new/kelp", to: "/kept/kelp 2026-10-22")
        XCTAssertEqual(mine.load(paper: "/new/kelp", round: 2), [:])
        XCTAssertEqual(mine.load(paper: "/kept/kelp 2026-10-22", round: 2), ["R1-01": "Mine.", "R1-02": "Which beach?"])
        XCTAssertEqual(mine.all().count, 2)
    }

    /// Settings counts only the drafts of listed papers: one left under a path no paper is listed at (a put back to a
    /// new place, Use This Copy's copy set aside) can be neither sent nor discarded.
    func testSettingsCountsOnlyTheListedPapersDrafts() throws {
        let m = makeModel()
        let kelp = PaperRef(path: tmp.appendingPathComponent("Reviews/Kelp drift").path, title: "Kelp drift", student: "Mei Lin")
        m.papers = [kelp]
        m.draftStore.save(paper: kelp.path, round: 2, drafts: ["R1-01": "Say more.", "R1-02": "Which bay?"])
        m.draftStore.save(paper: tmp.appendingPathComponent("Replaced by Import/Kelp drift 2026-10-22").path, round: 2,
                          drafts: ["R1-01": "Old."])
        XCTAssertEqual(m.draftStore.all().count, 3)
        XCTAssertEqual(DataSettings.listedDrafts(m), 2)
        m.papers = []
        XCTAssertEqual(DataSettings.listedDrafts(m), 0)
    }

    /// Show in Finder of something not there, nor its folder: from a paper's context menu, said on the window's line
    /// (Settings' status line is not in view); from Settings, on its status line, never over the work running (its
    /// step and Cancel stay).
    func testShowInFinderOfSomethingNotThere() async throws {
        let m = makeModel()
        let gone = tmp.appendingPathComponent("Gone/Kelp drift")
        m.data.reveal(gone, origin: .window)
        XCTAssertEqual(m.notice?.text, "“\(DataFiles.shown(gone))” is not there, nor the folder that held it.")
        XCTAssertEqual(m.notice?.failed, true)
        XCTAssertNil(m.data.status, "not Settings' status line")
        m.data.clearCaches()
        XCTAssertTrue(m.data.working)
        m.data.reveal(gone)
        XCTAssertTrue(m.data.working, "the work's step stays")
        for _ in 0..<200 where m.data.working { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(m.data.working)
        m.data.reveal(gone)
        guard case .failed(let s)? = m.data.status else { return XCTFail("\(String(describing: m.data.status))") }
        XCTAssertTrue(s.contains("is not there yet"), s)
    }

    func testThumbnailsCleared() async throws {
        let store = ThumbnailStore(root: tmp.appendingPathComponent("thumbs"))
        try fm.createDirectory(at: store.folder(paper: "/p"), withIntermediateDirectories: true)
        try Data(count: 10).write(to: store.folder(paper: "/p").appendingPathComponent("a.png"))
        let arrived = store.arrived
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in store.clearAll { c.resume() } }
        XCTAssertFalse(fm.fileExists(atPath: store.root.path))
        XCTAssertEqual(store.arrived, arrived + 1)
    }

    func testTheTab() throws {
        XCTAssertEqual(SettingsView.Tab.data.title, "Data & Storage")
        XCTAssertNotNil(NSImage(systemSymbolName: SettingsView.Tab.data.symbol, accessibilityDescription: nil))
        let m = makeModel()
        let host = NSHostingView(rootView: DataSettings(model: m))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsView.width, height: DataSettings.height),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        windows.append(window)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.width, SettingsView.width)
        // a debug item's work and its result
        let done = expectation(description: "debug")
        var result: [String: Any] = [:]
        m.data.debug("tags export \(tmp.appendingPathComponent("t.json").path)") { result = $0; done.fulfill() }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(result["status"] as? String, "done")
        XCTAssertEqual(try TagFile.read(tmp.appendingPathComponent("t.json")), m.tags.catalog.tags)
    }
}
