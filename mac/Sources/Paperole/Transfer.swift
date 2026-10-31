import AppKit
import Foundation

// Export and Import (design/data/DATA.md §3–§5, as the advisor's decisions and cuts of its §0 leave them): one kind of
// export file, written and read by the engine (`archive_write`, `archive_check`, `archive_unpack`, `swap_in`; CONTRACT
// amendment "Export and import files"); the app chooses what goes in, shows what a file holds before anything happens,
// and lists what came in. The engine stays the only writer of ledgers and PDFs: the app only renames a folder the
// engine unpacked into the place it was. Pure where it can be, so it is unit-tested; the work is DataModel's.

/// Where a sheet of Data & Storage's shows: on the Settings window (its buttons) or on the main window (File, the
/// context menus, the empty list, Add Existing Paper…).
enum SheetOrigin: Equatable {
    case settings, window
}

/// Words the transfer sheets share.
enum TransferText {
    /// A title up to its colon, else cut at 40 characters: "Easy Before Hard" for "Easy Before Hard: Curriculum…".
    static func short(_ title: String) -> String {
        let t = title.split(separator: ":", maxSplits: 1).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? title
        return t.count > 40 ? String(t.prefix(39)) + "…" : (t.isEmpty ? "Paper" : t)
    }

    /// "Oct 21 at 13:40" from an ISO 8601 time ("Oct 21, 2025 at 13:40" in another year), as the system writes it.
    static func when(_ iso: String?, now: Date = Date()) -> String? {
        guard let iso, let d = ISO8601DateFormatter().date(from: iso) else { return nil }
        let cal = Calendar.current
        return cal.component(.year, from: d) == cal.component(.year, from: now)
            ? d.formatted(.dateTime.month(.abbreviated).day().hour().minute())
            : d.formatted(date: .abbreviated, time: .shortened)
    }

    /// "“Kelp drift” (Mei Lin)", or the title alone.
    static func paper(_ title: String?, _ student: String?) -> String {
        "“\(title ?? "Paper")”" + ((student ?? "").isEmpty ? "" : " (\(student!))")
    }

    /// A paper's row in the import preview and report: "Kelp drift · Mei Lin", or the title alone.
    static func row(_ title: String?, _ student: String?) -> String {
        (title ?? "Paper") + ((student ?? "").isEmpty ? "" : " · " + student!)
    }

    /// "a, b and c".
    static func list(_ items: [String]) -> String {
        items.count < 2 ? items.joined() : items.dropLast().joined(separator: ", ") + " and " + items.last!
    }
}

/// The window's line at the bottom (Remove from List and its Undo; a result of the context menus' exports).
struct WindowNotice: Identifiable, Equatable {
    let id = UUID()
    var text: String
    /// Its button's title ("Undo", "Show in Finder"); `AppModel.noticeAction` runs it.
    var action: String?
    /// A second button's title after it ("Open" after Show in Finder: a round finished); `AppModel.noticeSecond`.
    var second: String? = nil
    var failed = false
}

/// The engine's `adopt_facts` reply: the ledger's facts after it.
struct FactsReply: Decodable {
    struct Facts: Decodable {
        var id: String?
        var finished: String?
        var buckets: [String: String?]?
        var keyPage: KeyPageChoice?
    }
    var adopted: [String]
    var paper: Facts
}

// MARK: Places

enum DataPlaces {
    /// Where new review folders go when none is chosen (DATA.md §0, §11.3): ~/Reviews; Paperole Dev never defaults
    /// to Paperole's places, so its own is ~/Paperole Dev Reviews (~/PaperCollab Dev Reviews until the app moved it
    /// there, at its first launch under the new name: DataHome, Migration.swift).
    static var defaultRoot: URL { DataHome.current(AppVariant.current).reviews }

    /// The service a folder is synced to, or nil (DATA.md §2.6): iCloud Drive (its files, and Desktop and Documents
    /// while iCloud keeps them), or Dropbox, Google Drive, OneDrive and the like in ~/Library/CloudStorage.
    static func synced(_ url: URL) -> String? {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let storage = home + "/Library/CloudStorage/"
        if path.hasPrefix(storage) {
            let name = String(path.dropFirst(storage.count).prefix { $0 != "/" })
            let provider = name.split(separator: "-").first.map(String.init) ?? name
            return ["GoogleDrive": "Google Drive", "OneDrive": "OneDrive", "Dropbox": "Dropbox", "Box": "Box"][provider] ?? provider
        }
        if path.hasPrefix(home + "/Library/Mobile Documents/") { return "iCloud Drive" }
        if (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true { return "iCloud Drive" }
        return nil
    }

    /// The name of the drive a path is on while that drive is not connected ("Lab SSD" for /Volumes/Lab SSD/…), else
    /// nil: its papers are not "missing".
    static func unplugged(_ path: String) -> String? {
        let parts = (path as NSString).standardizingPath.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count > 1, parts[0] == "Volumes" else { return nil }
        return FileManager.default.fileExists(atPath: "/Volumes/" + parts[1]) ? nil : String(parts[1])
    }

    /// Import's copies of yours that Use This Copy replaced: the "Replaced by Import" folders beside the listed papers'
    /// folders, how many copies they hold and their size.
    nonisolated static func replaced(_ papers: [String]) -> (folders: [URL], copies: Int, bytes: Int64) {
        let fm = FileManager.default
        let folders = Set(papers.map { URL(fileURLWithPath: $0).deletingLastPathComponent().appendingPathComponent("Replaced by Import") })
            .filter { fm.fileExists(atPath: $0.path) }.sorted { $0.path < $1.path }
        var copies = 0, bytes: Int64 = 0
        for f in folders {
            let items = (try? fm.contentsOfDirectory(at: f, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            copies += items.count
            bytes += DataFiles.bytes(f)
        }
        return (folders, copies, bytes)
    }
}

// MARK: Settings carried in an export of everything

/// The settings an export of everything carries (`app/settings.json`, DATA.md §3.3): how the app looks and reads, not
/// where review folders go nor the engine's Python. Brought in only when the import's "Also use this file's settings"
/// is ticked, never by a test run.
@MainActor
enum PortableSettings {
    static let keys = [AppModel.readingMarksKey, AppModel.checksKey, AppModel.foldPartsKey, AppModel.openAtLaunchKey, TagModel.suggestKey,
                       "showChangedWords", AppModel.mapAsTableKey, ListGrouping.key, AppIconModel.styleKey]

    static func current(_ defaults: UserDefaults = .standard) -> [String: Any] {
        var out: [String: Any] = [:]
        for k in keys {
            if let v = defaults.object(forKey: k), v is String || v is NSNumber { out[k] = v }
        }
        return out
    }

    /// Writes the file's settings this app knows (each of the kind it keeps) and takes the main ones at once. The names.
    static func apply(_ s: [String: Any], to app: AppModel) -> [String] {
        guard !app.testRun else { return [] }
        var used: [String] = []
        for k in keys {
            guard let v = s[k], v is String || v is NSNumber else { continue }
            UserDefaults.standard.set(v, forKey: k)
            used.append(k)
        }
        if let v = s[AppModel.readingMarksKey] as? Bool { app.readingMarksOn = v }
        if let v = s[AppModel.checksKey] as? Bool { app.checksOn = v }
        if let v = s[AppModel.foldPartsKey] as? Bool { app.foldParts = v }
        if let v = (s[AppModel.openAtLaunchKey] as? String).flatMap(OpenAtLaunch.init(rawValue:)) { app.openAtLaunch = v }
        if let v = s[TagModel.suggestKey] as? Bool { app.tags.suggest = v }
        if let v = s["showChangedWords"] as? Bool { app.showChangedWords = v }
        return used
    }
}

// MARK: Export

/// Export Papers (DATA.md §4, mockup b, without the cut "to send" kind): the students and their papers as a tree of
/// checkboxes, a dash on one whose papers are ticked only in part; a paper whose folder is not there greyed. From
/// Settings or File all are ticked; from a context menu only that student's or paper's.
struct ExportChoice: Identifiable, Equatable {
    struct Paper: Identifiable, Equatable {
        var ref: PaperRef
        /// Why it cannot go in: "missing", "on “Lab SSD”, not connected"; nil when its folder is there.
        var gone: String?
        var id: String { ref.path }
    }

    struct Student: Identifiable, Equatable {
        var key: String
        var name: String
        var papers: [Paper]
        var id: String { key }
    }

    enum Mark: Equatable { case on, off, mixed }

    enum Phase: Equatable {
        case choosing, working
        /// The file saved and checked; no URL: Cancel stopped it (a quiet line, not an error).
        case done(String, URL?)
        case failed(String)
    }

    let id = UUID()
    var origin: SheetOrigin
    var students: [Student]
    var ticked: Set<String>
    /// Each folder's bytes on disk, once counted.
    var sizes: [String: Int64] = [:]
    var phase: Phase = .choosing

    /// `only`: the papers ticked (a context menu's student or paper); nil: all.
    static func make(_ groups: [StudentGroup], only: Set<String>?, origin: SheetOrigin) -> ExportChoice {
        let students = groups.map { g in
            Student(key: g.key, name: g.name, papers: g.papers.map { p in
                Paper(ref: p, gone: DataFiles.isReviewFolder(URL(fileURLWithPath: p.path)) ? nil
                      : DataPlaces.unplugged(p.path).map { "on “\($0)”, not connected" } ?? "missing")
            })
        }
        let there = students.flatMap(\.papers).filter { $0.gone == nil }.map(\.id)
        return ExportChoice(origin: origin, students: students, ticked: Set(there.filter { only?.contains($0) ?? true }))
    }

    /// The papers that can go in, in the tree's order.
    var exportable: [Paper] { students.flatMap(\.papers).filter { $0.gone == nil } }
    var chosen: [PaperRef] { exportable.filter { ticked.contains($0.id) }.map(\.ref) }
    /// Every paper that can go in is ticked: an export of everything, which also carries the settings.
    var everything: Bool { !exportable.isEmpty && exportable.allSatisfy { ticked.contains($0.id) } }

    func mark(_ papers: [Paper]) -> Mark {
        let ps = papers.filter { $0.gone == nil }
        let n = ps.filter { ticked.contains($0.id) }.count
        return n == 0 ? .off : n == ps.count ? .on : .mixed
    }

    /// "1 paper · up to 1.1 MB" ("…" while counted): the folders' size on disk, which the file's compression only
    /// makes smaller.
    var summary: String {
        let ps = chosen
        guard !ps.isEmpty else { return "No papers ticked" }
        let counted = ps.allSatisfy { sizes[$0.path] != nil }
        let bytes = ps.reduce(Int64(0)) { $0 + (sizes[$1.path] ?? 0) }
        return DataModel.count(ps.count, "paper") + " · " + (counted ? "up to " + DataFiles.size(bytes) : "counting…")
    }

    /// The file's name (DATA.md §3.1): "Paperole – Maya Chen – 2026-10-21.zip" (all of one student's papers),
    /// "Paperole – Easy Before Hard – 2026-10-21.zip" (one paper, its title up to its colon), "Paperole – All
    /// Papers – 2026-10-21.zip"; else "Paperole – 3 Papers – …".
    func fileName(day: String) -> String {
        let ps = chosen
        var label = "\(ps.count) Papers"
        if everything {
            label = "All Papers"
        } else if ps.count == 1 {
            label = TransferText.short(ps[0].title)
        } else if let s = students.first(where: { s in !s.key.isEmpty && Set(s.papers.filter { $0.gone == nil }.map(\.id)) == Set(ps.map(\.path)) }) {
            label = s.name
        }
        return DataFiles.name("Paperole – \(label) – \(day)") + ".zip"
    }
}

/// The engine's `archive_write` reply, as the app reads it.
struct ExportReply: Decodable {
    var path: String
    var bytes: Int64
}

// MARK: Import

/// The engine's `archive_check` reply (CONTRACT amendment "Export and import files"): what a file or folder holds, each
/// paper compared with the list. The JSON the app's own files had (tags, settings, each paper's draft) is kept as it
/// came (`tagsJSON`, `settingsJSON`, `Paper.draftJSON`).
struct ArchiveCheck: Decodable, Equatable {
    struct MadeBy: Decodable, Equatable {
        var variant: String?
    }

    /// The facts the preview shows of a copy.
    struct Facts: Decodable, Equatable {
        var title: String?
        var student: String?
        var round: Int?
        var open: Bool?
        var comments: Int?
        var saved: String?
    }

    struct Problem: Decodable, Equatable {
        var code: String?
        var message: String?
    }

    /// A schema-1 backup's papers.json entry facts.
    struct OldFacts: Decodable, Equatable {
        var finished: String?
        var buckets: [String: String?]?
        var keyPage: KeyPageChoice?
    }

    struct Paper: Decodable, Equatable {
        var folder: String
        var inPlace: Bool
        var id: String?
        var title: String?
        var student: String?
        var status: String
        var reason: String?
        var listed: String?
        /// A new paper's folder still where it was (`was_at`), not in the list: the list lost, or the paper removed.
        var found: String?
        var this: Facts?
        var yours: Facts?
        var problems: [Problem]?
        var yoursProblems: [Problem]?
        var facts: OldFacts?
        var draftJSON: Data? = nil

        enum CodingKeys: String, CodingKey {
            case folder, inPlace, id, title, student, status, reason, listed, found, this, yours, problems, yoursProblems, facts
        }
    }

    var kind: String
    var zip: Bool
    var schema: Int?
    var created: String?
    var madeBy: MadeBy?
    var intact: Bool
    var checked: Bool
    var papers: [Paper]
    var tagsJSON: Data? = nil
    var settingsJSON: Data? = nil

    enum CodingKeys: String, CodingKey {
        case kind, zip, schema, created, madeBy, intact, checked, papers
    }

    static func decode(_ data: Data) throws -> ArchiveCheck {
        var c = try makeDecoder().decode(ArchiveCheck.self, from: data)
        let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        func json(_ v: Any?) -> Data? {
            guard let v, !(v is NSNull), JSONSerialization.isValidJSONObject(v) else { return nil }
            return try? JSONSerialization.data(withJSONObject: v)
        }
        c.tagsJSON = json(raw["tags"])
        c.settingsJSON = json(raw["settings"])
        let papers = raw["papers"] as? [[String: Any]] ?? []
        for i in c.papers.indices where i < papers.count { c.papers[i].draftJSON = json(papers[i]["draft"]) }
        return c
    }

    /// Made by Paperole Dev (made_by's "variant" "Paperole Dev", or "PaperCollab Dev" before the rename): test data,
    /// never used over a paper of yours by default.
    var fromDev: Bool { AppVariant(stored: madeBy?.variant) == .dev }
}

/// What Import will do (DATA.md §5.3, mockup c): each paper of the file or folder in one of four groups, with a
/// checkbox (put back, added) or a pop-up (already here), and the defaults of §5.3 as §0 amends them (a newer copy
/// is used, yours kept, unless the file is Paperole Dev's; no Repair Mine). Nothing has happened yet.
struct ImportPlan: Equatable {
    enum Group: Int, CaseIterable, Equatable {
        case putBack, add, here, cannot

        /// A put-back paper's line says where it goes (back where it was, where it is now, or into the folder below).
        var title: String {
            switch self {
            case .putBack: return "Will be listed again"
            case .add: return "Will be added"
            case .here: return "Already here"
            case .cannot: return "Can’t import"
            }
        }
    }

    enum Choice: String, Equatable {
        case putBack, add, keepMine, useThis, keepBoth, skip

        var title: String {
            switch self {
            case .keepMine: return "Keep Mine"
            case .useThis: return "Use This Copy"
            case .keepBoth: return "Keep Both"
            case .skip: return "Leave Out"
            default: return rawValue
            }
        }
        /// Something comes in.
        var acts: Bool { self != .keepMine && self != .skip }
    }

    struct Item: Identifiable, Equatable {
        var paper: ArchiveCheck.Paper
        var group: Group
        var choice: Choice
        /// The pop-up's choices (Already here); empty for a checkbox (its choice or `skip`) or none.
        var choices: [Choice]
        /// Yours is on a drive that is not connected.
        var unplugged: String?
        var id: String { paper.folder }

        /// A checkbox's: ticked or not.
        var checkbox: Bool { group == .putBack || group == .add }
        /// Something happens: its choice brings it in, or yours, still where it was (`found`), is listed there.
        var acts: Bool { choice.acts || (choice == .keepMine && paper.found != nil) }
        /// Its row's words: "Kelp drift · Mei Lin".
        var name: String { TransferText.row(paper.title, paper.student) }
    }

    var source: URL
    var check: ArchiveCheck
    var items: [Item]
    /// "Put them in": where added papers and copies go.
    var destination: URL?
    /// "Also use this file's settings" (only when it has them).
    var useSettings: Bool
    /// The file's tags this Mac lacks, by name.
    var newTags: [String]
    /// Restore from Last Backup…: one paper only (`tickOnly`); the report leaves the file's others unsaid.
    var only = false

    static func make(_ check: ArchiveCheck, source: URL, catalog: TagCatalog, destination: URL?, emptyList: Bool) -> ImportPlan {
        let items = check.papers.map { item($0, dev: check.fromDev, emptyList: emptyList) }
        let tags = check.tagsJSON.flatMap { try? JSONDecoder().decode(TagFile.self, from: $0).tags } ?? []
        return ImportPlan(source: source, check: check, items: items, destination: destination,
                          useSettings: check.settingsJSON != nil && emptyList,
                          newTags: catalog.merging(tags).added.map(\.name))
    }

    /// A paper's group, default and choices (DATA.md §5.3's table, as §0 amends it).
    static func item(_ p: ArchiveCheck.Paper, dev: Bool, emptyList: Bool = false) -> Item {
        let use: Choice = dev ? .keepMine : .useThis
        // a folder on disk is listed where it is: never moved over yours
        let here: [Choice] = p.inPlace ? [.keepMine, .keepBoth] : [.keepMine, .useThis, .keepBoth]
        switch p.status {
        case "new", "different_paper":
            // yours still where it was, not listed: Keep Mine lists yours there (by default when the list is empty:
            // lost), Keep Both also adds this copy beside it, Leave Out does nothing (a paper removed from the list)
            if p.found != nil {
                return Item(paper: p, group: .here, choice: emptyList ? .keepMine : .skip, choices: [.keepMine, .keepBoth, .skip])
            }
            return Item(paper: p, group: .add, choice: .add, choices: [])
        case "put_back":
            if let drive = p.listed.flatMap(DataPlaces.unplugged) {
                return Item(paper: p, group: .here, choice: .keepMine, choices: [.keepMine, .keepBoth], unplugged: drive)
            }
            return Item(paper: p, group: .putBack, choice: .putBack, choices: [])
        case "same":
            // the very folder listed: nothing to choose
            let itself = p.inPlace && p.listed.map { samePlace($0, p.folder) } == true
            return Item(paper: p, group: .here, choice: .keepMine, choices: itself ? [] : [.keepMine, .keepBoth])
        case "older", "diverged":
            return Item(paper: p, group: .here, choice: .keepMine, choices: here)
        case "newer", "yours_damaged":
            return Item(paper: p, group: .here, choice: p.inPlace ? .keepMine : use,
                        choices: p.inPlace ? here : [.useThis, .keepMine, .keepBoth])
        default:
            return Item(paper: p, group: .cannot, choice: .skip, choices: [])
        }
    }

    /// Restore from Last Backup…: only this listed paper comes in, put back where it was or used in place of a damaged
    /// copy (yours kept in "Replaced by Import"); every other paper of the file stays out, and so do its settings. A
    /// backup older than yours, or changed since they parted, stays at Keep Mine: never an older copy over yours.
    mutating func tickOnly(_ paper: PaperRef) {
        for i in items.indices {
            let p = items[i].paper
            if p.listed.map({ Self.samePlace($0, paper.path) }) == true || (paper.ledgerID != nil && p.id == paper.ledgerID) {
                if items[i].group == .putBack || items[i].group == .add { continue }
                if ["yours_damaged", "newer"].contains(p.status), items[i].choices.contains(.useThis) { items[i].choice = .useThis }
            } else if items[i].checkbox || items[i].paper.found != nil {
                items[i].choice = .skip
            } else if !items[i].choices.isEmpty {
                items[i].choice = .keepMine
            }
        }
        useSettings = false
        only = true
    }

    /// Two spellings of one place ("/private/tmp/…" and "/tmp/…", or through a symbolic link, as the engine's
    /// realpath has them).
    static func samePlace(_ a: String, _ b: String) -> Bool {
        func s(_ p: String) -> String {
            let t = URL(fileURLWithPath: (p as NSString).standardizingPath).resolvingSymlinksInPath().path
            return t.hasPrefix("/private/") ? String(t.dropFirst("/private".count)) : t
        }
        return a == b || s(a) == s(b)
    }

    /// One review folder found on disk, new or the one listed already: listed (and shown) at once, nothing to decide.
    /// The one listed already by its listed path, however the folder was spelled.
    var listedAtOnce: String? {
        guard items.count == 1, let it = items.first, it.paper.inPlace, it.paper.reason == nil,
              it.paper.status == "new" || (it.paper.status == "same" && it.choices.isEmpty) else { return nil }
        return it.paper.status == "same" ? it.paper.listed ?? it.paper.folder : it.paper.folder
    }

    /// Where a put-back paper goes: its old place, when nothing is there and the folder holding it is.
    static func oldPlace(_ it: Item) -> URL? {
        guard it.choice == .putBack, !it.paper.inPlace, let listed = it.paper.listed else { return nil }
        let u = URL(fileURLWithPath: listed)
        var dir: ObjCBool = false
        let fm = FileManager.default
        guard !fm.fileExists(atPath: u.path), fm.fileExists(atPath: u.deletingLastPathComponent().path, isDirectory: &dir),
              dir.boolValue else { return nil }
        return u
    }

    /// Some ticked paper goes into "Put them in" (not back to its old place, not listed where it is).
    var needsDestination: Bool {
        items.contains { it in
            !it.paper.inPlace && (it.choice == .add || it.choice == .keepBoth || (it.choice == .putBack && Self.oldPlace(it) == nil))
        }
    }

    var acting: [Item] { items.filter(\.acts) }

    /// The Import button's title: "Import 2 Papers", "Add the Tags", "Import".
    var actionTitle: String {
        let n = acting.count
        return n == 0 ? (newTags.isEmpty ? "Import" : "Add the Tags") : n == 1 ? "Import 1 Paper" : "Import \(n) Papers"
    }

    var canImport: Bool { (!acting.isEmpty || !newTags.isEmpty || useSettings) && (destination != nil || !needsDestination) }

    /// The line under the title: "Made Oct 21 at 13:40 by Paperole · 3 papers · every file intact".
    var header: String {
        let c = check
        var parts: [String] = []
        if c.kind == "folders" {
            parts.append("A folder: " + DataModel.count(items.count, "review folder") + ", listed where they are")
        } else {
            let by = AppVariant.shown(stored: c.madeBy?.variant ?? AppVariant.official.name)
            parts.append(((TransferText.when(c.created)).map { "Made \($0) by \(by)" } ?? "Made by \(by)")
                         + (c.kind == "backup" ? " (a backup)" : ""))
            parts.append(DataModel.count(items.count, "paper"))
        }
        parts.append(c.intact ? (c.checked ? "every file intact" : "no damage found") : "some files damaged")
        return parts.joined(separator: " · ")
    }

    /// A line under a paper: words, or a place (`path`: shown on one line with the home folder as ~, cut in the
    /// middle, the full path in its help tag).
    struct Line: Equatable {
        var text: String
        var path: String? = nil
    }

    /// The lines under a paper: short facts ("3 rounds · 6 comments"), or the two copies compared, or why it cannot
    /// come in; a place only where it is not "Put them in" (back where it was, still where it is).
    func detail(_ it: Item) -> [Line] {
        let p = it.paper
        let size = p.this.map(Self.size).flatMap { $0.isEmpty ? nil : [Line(text: $0)] } ?? []
        let copy = it.choice == .keepBoth ? [Line(text: "This copy is added with “(copy)” after its title.")] : []
        switch it.group {
        case .cannot:
            return [Line(text: p.reason ?? "It cannot be read.")]
        case .putBack:
            if p.inPlace { return size + [Self.place("Listed where it is now: ", p.folder)] }
            if let old = Self.oldPlace(it) { return size + [Self.place("Back where it was: ", old.path)] }
            return size + [Line(text: "Its old place is taken or gone: into the folder below.")]
        case .add:
            let other = p.status == "different_paper" ? [Line(text: "Another of yours has its id: this one gets its own.")] : []
            return size + other + (p.inPlace ? [Self.place("Listed where it is: ", p.folder)] : [])
        case .here:
            if let drive = it.unplugged { return [Line(text: "Yours is on “\(drive)”, not connected: plug it in to compare.")] }
            if let f = p.found { return [Self.place("Still at ", f)] + copy }
            if it.choices.isEmpty { return [Line(text: "The very folder in your list.")] }
            if p.status == "same" { return [Line(text: "Same as yours: " + (p.this.map(Self.facts) ?? ""))] + copy }
            let mark = ["older": (false, true), "newer": (true, false)][p.status] ?? (false, false)
            var lines = [Line(text: "This copy: " + (p.this.map(Self.facts) ?? "") + (mark.0 ? " (newer)" : ""))]
            // yours unread (its ledger damaged or gone): no facts of it to show
            if p.status != "yours_damaged" || p.yours != nil {
                lines.append(Line(text: "Yours: " + (p.yours.map(Self.facts) ?? "") + (mark.1 ? " (newer)" : "")))
            }
            if p.status == "diverged" { lines.append(Line(text: "Both changed since they parted.")) }
            if p.status == "yours_damaged" {
                // the damage the engine counted, never a harmless problem such as `.orphans` listed before it
                let why = p.yoursProblems?.first { !BackupModel.harmless.contains($0.code ?? "") }?.message
                lines.append(Line(text: why.map { "Yours is damaged: \($0) This copy is intact." } ?? "Yours is damaged; this copy is intact."))
            }
            return lines + copy
        }
    }

    /// "Back where it was: ~/Reviews/Kelp drift".
    private static func place(_ words: String, _ path: String) -> Line {
        Line(text: words + DataFiles.shown(URL(fileURLWithPath: path)), path: path)
    }

    /// "3 rounds · 6 comments" (a copy's latest round is its number of rounds).
    static func size(_ f: ArchiveCheck.Facts) -> String {
        [f.round.map { DataModel.count($0, "round") }, f.comments.map { DataModel.count($0, "comment") }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// "round 3 open · 6 comments · Oct 21 at 13:26" (another year's date with its year, as the header's).
    static func facts(_ f: ArchiveCheck.Facts) -> String {
        var parts: [String] = []
        if let r = f.round { parts.append("round \(r)" + (f.open == true ? " open" : "")) } else { parts.append("no rounds") }
        if let c = f.comments { parts.append(DataModel.count(c, "comment")) }
        if let w = TransferText.when(f.saved) { parts.append(w) }
        return parts.joined(separator: " · ")
    }

    /// "Tags: adds Rigor, Tone. Yours stay as they are."; nil without a tag to add.
    var tagWords: String? {
        newTags.isEmpty ? nil : "Tags: adds \(newTags.joined(separator: ", ")). Yours stay as they are."
    }

    /// Some paper offers Use This Copy: the preview says where yours would be kept.
    var mayReplace: Bool { items.contains { $0.choices.contains(.useThis) } }

    /// "Drafts: 1, for Easy Before Hard; never over one of yours."; nil without drafts coming in.
    var draftWords: String? {
        let with = acting.filter { $0.paper.draftJSON != nil }
        guard !with.isEmpty else { return nil }
        return "Drafts: \(with.count), for " + TransferText.list(with.map { TransferText.short($0.paper.title ?? "") }) + "; never over one of yours."
    }
}

/// The sheet of Import…: the file or folder, then what it holds (the plan), then what happened (the report); an error
/// when it could not be read.
struct ImportSheetState: Identifiable, Equatable {
    let id = UUID()
    var source: URL
    var origin: SheetOrigin
    var plan: ImportPlan?
    var report: ImportReport?
    var error: String?
    /// The check stopped by Cancel: a quiet line, not an error.
    var note: String?
}

/// What Import did (DATA.md §5.5, mockup e), as the preview shows what it would do: a heading for each kind of thing
/// done, a row for each paper; then the drafts, tags and settings; where it stopped.
struct ImportReport: Equatable {
    /// One kind of thing done ("Put back where it was") and its papers ("Kelp drift · Mei Lin").
    struct Group: Equatable {
        var title: String
        /// A folder named once, after the title on its one line ("Added to ~/Reviews"): its full path.
        var place: String? = nil
        var papers: [String]
    }

    var groups: [Group] = []
    /// The drafts, tags and settings, and "Nothing else changed."
    var lines: [String]
    /// "Stopped at “…” (Maya Chen): … Nothing of it was written."
    var stopped: String?
    /// Cancel stopped it: `stopped` is a quiet line, not an error.
    var cancelled = false
    var done: Int
    var of: Int
    var reveal: URL?

    var title: String { stopped == nil ? "Imported" : "Imported \(done) of \(of) " + (of == 1 ? "paper" : "papers") }
}

// MARK: Put Back an Earlier Ledger

/// Put Back an Earlier Ledger… (DATA.md §6.4; the engine's `history` and `put_back_ledger`): a paper's saved versions,
/// newest first, none chosen until the advisor clicks one.
struct LedgerHistory: Identifiable, Equatable {
    struct Version: Decodable, Equatable, Identifiable {
        var name: String
        var time: String?
        var rev: Int?
        var kind: String
        var comments: Int?
        var rounds: Int?
        var id: String { name }

        /// "Oct 21 at 09:12 · 2 rounds · 14 comments · a round finished".
        var words: String {
            let what = ["ingest": "a round started", "finish": "a round finished", "reopen": "a comment reopened",
                        "edit": "before an edit", "replaced": "replaced by a put back",
                        "resume": "before a round was resumed"][kind] ?? kind
            var parts = [TransferText.when(time) ?? name]
            if let r = rounds { parts.append(DataModel.count(r, "round")) }
            parts.append(comments.map { DataModel.count($0, "comment") } ?? "cannot be read")
            parts.append(what)
            return parts.joined(separator: " · ")
        }
    }

    struct Reply: Decodable { var versions: [Version] }

    var paper: String
    var title: String
    var versions: [Version]?
    var selected: String?
    var error: String?
    var working = false
    var id: String { paper }
}
