import AppKit
import Foundation
import UniformTypeIdentifiers

// Settings › Data & Storage (UX.md §28; design/data/DATA.md as its §0 leaves it): where the app keeps things, the
// folder new review folders go in, Export… and Import… (the engine's export files; Transfer.swift), comments as CSV
// or JSON, the tags' file, and clearing the thumbnails. Everything stays on this Mac: a file goes where the advisor
// picks it in a save panel. The engine stays the only writer of ledgers and PDFs; the app only renames a folder the
// engine unpacked into the place it was.

// MARK: Files

/// A failure the advisor can read.
struct DataFailure: LocalizedError, Equatable {
    var message: String
    var errorDescription: String? { message }
}

/// The file work: a file written whole or not at all, names that never replace what is there. Pure or file-only, so it
/// is unit-tested.
enum DataFiles {
    /// `name` in `dir`, or "name 2", "name 3" … when something there (or in `taken`, lowercased) has that name:
    /// nothing is ever written over. The number goes after the whole name, as Finder's Keep Both does: a name that
    /// ends in a number is a name ("Llama 3" taken: "Llama 3 2", never "Llama 4", which reads as another paper). A
    /// `file`'s number goes before its extension ("a 2.zip"); a folder has none ("Llama 3.1 2").
    nonisolated static func unique(_ name: String, in dir: URL, taken: Set<String> = [], file: Bool = false) -> URL {
        let fm = FileManager.default
        let ext = file ? (name as NSString).pathExtension : ""
        let base = file ? (name as NSString).deletingPathExtension : name
        var n = 1
        while true {
            let candidate = n == 1 ? name : "\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)")
            let u = dir.appendingPathComponent(candidate)
            if !taken.contains(candidate.lowercased()) && !fm.fileExists(atPath: u.path) { return u }
            n += 1
        }
    }

    /// A folder or file name from a paper's title: no "/" or ":", no $, `, " or \ (latexmk's command lines would read
    /// them in a review folder's path, so the engine refuses one: engine/CONTRACT.md amendment "Shell escape per
    /// paper"), no dot first, white space collapsed, at most 80 characters; "Paper" for a title with none of those.
    nonisolated static func name(_ title: String) -> String {
        let s = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .filter { !"$`\"\\".contains($0) }
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var out = String(s.drop { $0 == "." || $0 == "-" || $0 == " " }.prefix(80)).trimmingCharacters(in: .whitespaces)
        if out.isEmpty { out = "Paper" }
        return out
    }

    /// Writes `dest` only once the whole file is made (`make` writes the temporary file it is given, on dest's volume):
    /// a failed or cancelled export leaves nothing, and a file the save panel said to replace stays whole until then.
    nonisolated static func write(to dest: URL, _ make: (URL) throws -> Void) throws {
        let fm = FileManager.default
        let dir = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: dest.deletingLastPathComponent(),
                             create: true)
        defer { try? fm.removeItem(at: dir) }
        let tmp = dir.appendingPathComponent(dest.lastPathComponent)
        try make(tmp)
        if fm.fileExists(atPath: dest.path) {
            _ = try fm.replaceItemAt(dest, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: dest)
        }
    }

    /// The bytes the files under `url` take on disk (a file: its own).
    nonisolated static func bytes(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        func size(_ u: URL) -> Int64 {
            guard let v = try? u.resourceValues(forKeys: keys), v.isRegularFile == true else { return 0 }
            return Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return size(url) }
        var total: Int64 = 0
        for case let u as URL in e { total += size(u) }
        return total + size(url)
    }

    /// "12.4 MB", as Finder writes sizes.
    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    /// "~/Library/Application Support/Paperole/papers.json" (the dev app's: …/Paperole Dev/papers.json; AppVariant).
    static func shown(_ url: URL) -> String { (url.path as NSString).abbreviatingWithTildeInPath }

    /// Whether `folder` is a review folder: it has a ledger.json.
    nonisolated static func isReviewFolder(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("ledger.json").path)
    }

    /// Today as the backup's name has it: "2026-10-20".
    static func day(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func now(_ date: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f.string(from: date)
    }
}

// MARK: Tags

/// tags.json's shape (`TagStore`): `{"schema": 1, "tags": [...]}`, as Export Tags… writes and Import Tags… reads.
struct TagFile: Codable {
    var schema: Int
    var tags: [WritingTag]

    static func read(_ url: URL) throws -> [WritingTag] {
        guard let data = try? Data(contentsOf: url) else { throw DataFailure(message: "The file could not be read.") }
        guard let f = try? JSONDecoder().decode(TagFile.self, from: data), f.schema == 1 else {
            throw DataFailure(message: "This file holds no Paperole tags. Choose one made by Export… under Writing tags, or a tags.json.")
        }
        return f.tags
    }

    static func data(_ c: TagCatalog) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return try enc.encode(TagFile(schema: 1, tags: c.tags))
    }
}

extension TagCatalog {
    /// What an import adds (Import Tags…, a restore): the file's tags this catalogue lacks, at the end in the file's
    /// order. A tag with an id here (`same`) or with the name of another tag here, case aside (`clashes`, by name), is
    /// left out: no tag here changes and no name is there twice. A sign another tag here has is swapped for a free one
    /// of the palette, or none (every sign means one tag); a name is cleaned as the editor cleans it.
    func merging(_ other: [WritingTag]) -> (catalog: TagCatalog, added: [WritingTag], same: Int, clashes: [String]) {
        var c = self, added: [WritingTag] = [], same = 0, clashes: [String] = []
        let wanted = Set(other.compactMap(\.sign))  // a swapped sign is not one a later tag of the file has
        for var t in other where Self.validID(t.id) {
            if c.tag(t.id) != nil {
                same += 1
                continue
            }
            guard let name = Self.clean(t.name) else { continue }
            if c.named(name) != nil {
                clashes.append(name)
                continue
            }
            t.name = name
            let signs = Set(c.tags.compactMap(\.sign) + [Self.untaggedSign])
            if let s = t.sign, signs.contains(s) {
                t.sign = Self.palette.first { !signs.contains($0) && !wanted.contains($0) } ?? Self.palette.first { !signs.contains($0) }
            }
            c.tags.append(t)
            added.append(t)
        }
        return (c, added, same, clashes)
    }
}

// MARK: Comments

/// The engine's `export_comments` reply (CONTRACT amendment "Export"): each paper's comments, round by round.
struct CommentExportReply: Decodable, Equatable {
    struct Paper: Decodable, Equatable {
        var path: String
        var paper: Info? = nil
        var tagNames: [String: String]? = nil
        var comments: [Comment]? = nil
        var error: String? = nil
    }

    struct Info: Decodable, Equatable {
        var title: String
        var student: String
    }

    struct Comment: Decodable, Equatable {
        var id: String
        var createdRound: Int
        var created: String? = nil
        var kind: String
        var color: String? = nil
        var note: String
        var tags: [String] = []
        var rounds: [Round]
    }

    struct Round: Decodable, Equatable {
        var round: Int
        var section: String? = nil
        var page: Int? = nil
        var place: String
        var state: String? = nil
        var response: String? = nil
        var answer: String? = nil
        var verdict: String? = nil
        var verdictNote: String = ""
        var studentNote: String? = nil
        var text: String = ""
    }

    var papers: [Paper]
}

/// Comments as a spreadsheet (CSV: one row for each round a comment is in) or as JSON (each comment once, its rounds
/// inside), in the app's words. Pure, so it is unit-tested.
enum CommentExport {
    enum Format: String, CaseIterable {
        case csv, json
        var title: String { rawValue.uppercased() }
        var type: UTType { self == .csv ? .commaSeparatedText : .json }
    }

    static let columns = ["Student", "Paper", "Comment", "Written in round", "Round", "Section", "Page", "Where",
                          "Student’s response", "Your answer", "Answer note", "Student’s note", "Tags", "Kind", "Note",
                          "Marked text"]

    static let places = ["placed": "in the PDF", "gone": "text deleted", "unplaced": "not found", "whole": "whole paper"]
    static let responses = ["new": "new this round", "edited": "edited", "note_only": "note only", "untouched": "untouched",
                            "waiting": "waiting for you"]
    static let answers = ["resolved": "Resolved", "follow_up": "Followed up", "kept": "Kept as is", "left_open": "Left open",
                          "to_check": "To check"]

    /// A tag's name: the catalogue's, else the one the paper's ledger keeps, else its id.
    static func tagNames(_ ids: [String], _ p: CommentExportReply.Paper, catalog: TagCatalog) -> [String] {
        catalog.sorted(ids).map { catalog.name($0, backup: p.tagNames ?? [:]) }
    }

    /// A CSV field: quoted when it holds a comma, a quote or a line break, its quotes doubled (RFC 4180). One that
    /// starts as a formula would (=, +, -, @, a tab or a return: "- add a citation", a student's note, "= \sum…") gets
    /// a ' first and is quoted, so Excel shows it as text and never runs it (OWASP's CSV injection advice).
    static func field(_ s: String) -> String {
        let formula = s.first.map { "=+-@\t\r".contains($0) } ?? false
        let t = formula ? "'" + s : s
        return formula || t.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
            ? "\"" + t.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : t
    }

    /// The rows under `columns`, pages from 1 as the app shows them.
    static func rows(_ reply: CommentExportReply, catalog: TagCatalog) -> [[String]] {
        var out: [[String]] = []
        for p in reply.papers {
            guard let info = p.paper, let comments = p.comments else { continue }
            for c in comments {
                let tags = tagNames(c.tags, p, catalog: catalog).joined(separator: "; ")
                for r in c.rounds {
                    out.append([info.student, info.title, c.id, String(c.createdRound), String(r.round), r.section ?? "",
                                r.page.map { String($0 + 1) } ?? "", places[r.place] ?? r.place,
                                r.response.map { responses[$0] ?? $0 } ?? "", r.answer.map { answers[$0] ?? $0 } ?? "",
                                r.verdictNote, r.studentNote ?? "", tags, c.kind, c.note, r.text])
                }
            }
        }
        return out
    }

    /// UTF-8 with a byte-order mark (so Excel reads Chinese notes right), lines ended by CR LF.
    static func csv(_ reply: CommentExportReply, catalog: TagCatalog) -> Data {
        let lines = ([columns] + rows(reply, catalog: catalog)).map { $0.map(field).joined(separator: ",") }
        return Data(("\u{FEFF}" + lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    /// `{"schema": 1, "exported", "of", "papers": [{"title", "student", "folder", "comments": [...]}], "errors"}`.
    static func json(_ reply: CommentExportReply, catalog: TagCatalog, of label: String, exported: String) throws -> Data {
        func null(_ v: Any?) -> Any { v ?? NSNull() }
        var papers: [[String: Any]] = [], errors: [[String: Any]] = []
        for p in reply.papers {
            guard let info = p.paper, let comments = p.comments else {
                errors.append(["folder": p.path, "error": p.error ?? "Not read."])
                continue
            }
            let cs: [[String: Any]] = comments.map { c in
                ["id": c.id, "written_in": c.createdRound, "created": null(c.created), "kind": c.kind,
                 "color": c.color ?? "yellow", "note": c.note, "tags": tagNames(c.tags, p, catalog: catalog),
                 "tag_ids": catalog.sorted(c.tags),
                 "rounds": c.rounds.map { r -> [String: Any] in
                     ["round": r.round, "section": null(r.section), "page": null(r.page.map { $0 + 1 }),
                      "where": places[r.place] ?? r.place, "state": null(r.state),
                      "response": null(r.response.map { responses[$0] ?? $0 }),
                      "answer": null(r.answer.map { answers[$0] ?? $0 }), "verdict": null(r.verdict),
                      "answer_note": r.verdictNote, "student_note": null(r.studentNote), "text": r.text]
                 }]
            }
            papers.append(["title": info.title, "student": info.student, "folder": p.path, "comments": cs])
        }
        let root: [String: Any] = ["schema": 1, "exported": exported, "of": label, "papers": papers, "errors": errors]
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// "Mei Lin’s comments.csv", "Kelp drift comments.json".
    static func fileName(_ label: String, student: Bool, format: Format) -> String {
        DataFiles.name(student ? "\(label)’s comments" : "\(label) comments") + "." + format.rawValue
    }
}


// MARK: The model

/// Settings › Data & Storage's state and work: one job at a time, its step in the tab's status line (and in the
/// Export and Import sheets) with Cancel, its result or error there afterwards. The panels are the system's; the work
/// itself takes URLs, so tests and the debug items run it without a panel. Export and Import are the engine's
/// (`archive_write`, `archive_check`, `archive_unpack`, `swap_in`), asked to stop with its `cancel`.
@MainActor
final class DataModel: ObservableObject {
    enum Status: Equatable {
        case working(String, Double?)
        case done(String, URL?)
        case failed(String)
    }

    @Published private(set) var status: Status? {
        didSet { if quitWhenDone && !working { DispatchQueue.main.async { NSApp.terminate(nil) } } }
    }
    /// The job running can be stopped (its Cancel).
    @Published private(set) var cancellable = false
    /// Export Papers (its sheet).
    @Published var export: ExportChoice?
    /// Import… (its sheet: checking, the preview, the report).
    @Published var importing: ImportSheetState?
    /// The thumbnails' bytes on disk (nil while counted).
    @Published private(set) var thumbnailBytes: Int64?
    /// "Replaced by Import": the folders, how many copies and their size (nil while counted).
    @Published private(set) var replaced: (folders: [URL], copies: Int, bytes: Int64)?
    /// Settings › Data & Storage "New review folders": the folder chosen for New Paper… and Import to put new review
    /// folders in; nil: the default (`DataPlaces.defaultRoot`), which a test run has not.
    @Published var reviewRoot: String? {
        didSet { if remember, reviewRoot != oldValue { Prefs.set(reviewRoot ?? "", Self.reviewRootKey) } }
    }
    static let reviewRootKey = "reviewFolderRoot"

    weak var app: AppModel?
    private let remember: Bool
    /// The engine request the job waits for and the engine it went to, which Cancel asks to stop it; `stopping` stops
    /// the next step.
    private var request: (id: Int, on: EngineClient)?
    private var stopping = false
    /// Export and Import's own engine process for the archive's requests, which can take minutes (as Backups has one):
    /// the review's never wait behind them. It ends between jobs. `fork`, `edit_paper` and `swap_in` stay on the
    /// review's engine, after an editor's edit sent there.
    private lazy var archiveEngine = EngineClient()
    private static let archiveMethods: Set<String> = ["archive_write", "archive_check", "archive_unpack"]

    init(app: AppModel, remember: Bool) {
        self.app = app
        self.remember = remember
        let saved = remember ? Prefs.string(Self.reviewRootKey) : nil
        reviewRoot = saved.flatMap { $0.isEmpty ? nil : $0 }
    }

    var working: Bool { if case .working = status { return true }; return false }
    /// The work's step as the status line says it ("Writing “Kelp drift” (2 of 3)…"), while it runs.
    var step: String? { if case .working(let s, _) = status { return s }; return nil }
    /// Quitting was asked while work ran: the app quits once it has ended (`dataAllowsQuit`).
    var quitWhenDone = false

    /// Where new review folders go now: the folder chosen, while it is there (an unplugged drive's is not), else the
    /// default, made when first used; a test run has no default.
    var root: URL? {
        if let r = reviewRoot {
            var dir: ObjCBool = false
            return FileManager.default.fileExists(atPath: r, isDirectory: &dir) && dir.boolValue ? URL(fileURLWithPath: r) : nil
        }
        return remember ? DataPlaces.defaultRoot : nil
    }

    /// The folder Settings shows: the chosen one, or the default.
    var rootShown: URL? { reviewRoot.map { URL(fileURLWithPath: $0) } ?? (remember ? DataPlaces.defaultRoot : nil) }

    func clearStatus() { if !working { status = nil } }

    // MARK: Where things are

    /// Show in Finder: the item, else the folder holding it. Neither there: said where the advisor is looking (`origin`
    /// .window, a paper's context menu: the window's bottom line), else on the status line, never over the work running.
    func reveal(_ url: URL, origin: SheetOrigin = .settings) {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else if fm.fileExists(atPath: url.deletingLastPathComponent().path) {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        } else if origin == .window {
            app?.showNotice(WindowNotice(text: "“\(DataFiles.shown(url))” is not there, nor the folder that held it.", failed: true))
        } else if working {
            NSSound.beep()
        } else {
            status = .failed("“\(DataFiles.shown(url))” is not there yet: \(AppVariant.current.name) makes it when it first keeps something there.")
        }
    }

    /// Choose… for new review folders; a folder synced to iCloud Drive or another cloud asks first (DATA.md §2.6).
    func chooseReviewRoot() {
        guard let u = openPanel(prompt: "Choose", message: "Choose the folder where New Paper… and Import put new review folders.",
                                folders: true, types: [], start: root) else { return }
        if let service = DataPlaces.synced(u) {
            let a = NSAlert()
            a.messageText = "This folder is synced to \(service)."
            a.informativeText = "Your students’ unpublished papers would be uploaded, and macOS may remove files from this Mac to save space."
            a.addButton(withTitle: "Choose Another Folder")
            a.addButton(withTitle: "Use It Anyway")
            if a.runModal() == .alertFirstButtonReturn { return chooseReviewRoot() }
        }
        reviewRoot = u.path
    }

    func countThumbnails() {
        guard let root = app?.thumbnails.root else { return }
        Task.detached {
            let n = DataFiles.bytes(root)
            await MainActor.run { self.thumbnailBytes = n }
        }
    }

    /// "Replaced by Import" beside the listed papers' folders, counted off the main thread.
    func countReplaced() {
        let paths = app?.papers.map(\.path) ?? []
        Task.detached {
            let r = DataPlaces.replaced(paths)
            await MainActor.run { self.replaced = r }
        }
    }

    /// At launch (never a test run): what an export, import or backup killed midway left, over a day old (DATA.md
    /// §2.5), where they are made: the engine's hidden `.Paperole-import-…` folders where imports unpack (where new
    /// review folders go, beside each listed paper's folder) and its hidden `.….zip.….tmp` files in the backup folder.
    func sweepLeftovers() {
        guard let app, remember else { return }
        var dirs = Set(app.papers.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent().path })
        if let r = root?.path { dirs.insert(r) }
        let backups = app.backups.state.on ? app.backups.state.folder : nil
        if let b = backups { dirs.insert(b) }
        Task.detached {
            for d in dirs.sorted() {
                for gone in Self.sweep(URL(fileURLWithPath: d), zips: d == backups, before: Date().addingTimeInterval(-86400)) {
                    NSLog("Paperole: removed a leftover of an interrupted import or backup: %@", gone.path)
                }
            }
        }
    }

    /// The leftovers directly in `dir` changed before `before`, removed: hidden folders named `.Paperole-import-…` (or
    /// `.PaperCollab-import-…`, the engine's name for them until the app was renamed, 2026-10-27)
    /// and, with `zips`, hidden files named `.<name>.zip.<random>.tmp`. Never a link, nothing else. What was removed.
    nonisolated static func sweep(_ dir: URL, zips: Bool, before: Date) -> [URL] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        var gone: [URL] = []
        for u in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? [] {
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true,
                  let changed = v.contentModificationDate, changed < before else { continue }
            let name = u.lastPathComponent
            let staging = v.isDirectory == true && (name.hasPrefix(".Paperole-import-") || name.hasPrefix(".PaperCollab-import-"))
            let partial = zips && v.isRegularFile == true && name.hasPrefix(".") && name.contains(".zip.") && name.hasSuffix(".tmp")
            if (staging || partial) && (try? fm.removeItem(at: u)) != nil { gone.append(u) }
        }
        return gone
    }

    /// Clear: every page thumbnail (they are drawn again when shown).
    func clearCaches() {
        guard let app, !working else { return }
        status = .working("Clearing the thumbnails…", nil)
        app.thumbnails.clearAll { [weak self] in
            self?.thumbnailBytes = 0
            self?.status = .done("Cleared the thumbnails. They are drawn again as pages are shown.", nil)
        }
    }

    // MARK: Export

    /// Export Papers: the sheet, every paper ticked, or only `only`'s (a context menu's student or paper).
    func openExport(origin: SheetOrigin, only: [String]? = nil) {
        guard let app else { return }
        guard !working else { return busy(origin) }
        export = ExportChoice.make(app.studentGroups, only: only.map(Set.init), origin: origin)
        if app.hubModel.data.isEmpty { app.loadHub() }  // the papers' comments, for their lines
        let paths = export?.exportable.map(\.id) ?? []
        Task.detached {
            var sizes: [String: Int64] = [:]
            for p in paths { sizes[p] = DataFiles.bytes(URL(fileURLWithPath: p)) }
            await MainActor.run { [sizes] in self.export?.sizes = sizes }
        }
    }

    func closeExport() {
        if working, export?.phase == .working { cancelWork() }
        export = nil
    }

    /// Export…: the save panel, then the file.
    func chooseExportFile() {
        guard let e = export, !e.chosen.isEmpty else { return }
        guard let dest = savePanel(name: e.fileName(day: DataFiles.day()), type: .zip,
                                   message: "Export \(DataModel.count(e.chosen.count, "paper")), checked as it is written.") else { return }
        writeExport(to: dest)
    }

    /// The engine writes the ticked papers' review folders whole, with the tags, their drafts and (an export of
    /// everything) the settings, into a file it reads back before naming it: a failure or Cancel leaves nothing.
    func writeExport(to dest: URL) {
        guard let e = export, !e.chosen.isEmpty, !working else { return }
        let params = archiveParams(e.chosen, dest: dest, everything: e.everything, kind: "export")
        export?.phase = .working
        job("Writing…", failed: { [weak self] m in self?.export?.phase = .failed(m) },
            cancelled: { [weak self] m in self?.export?.phase = .done(m, nil) }) { [weak self] in
            guard let self else { return }
            let data: Data
            do {
                data = try await self.engine("archive_write", params)
            } catch let e as EngineError where e.message.hasPrefix("Unknown method") {
                throw DataFailure(message: "This engine is older than the app and cannot export. Update the engine.")
            }
            let r = try makeDecoder().decode(ExportReply.self, from: data)
            let url = URL(fileURLWithPath: r.path)
            let words = "Saved and checked: \(url.lastPathComponent) (\(DataFiles.size(r.bytes)))."
            self.export?.phase = .done(words, url)
            self.status = .done(words, url)
        }
    }

    /// `archive_write`'s parameters (Export…, an automatic backup): the papers, the tags, the papers' drafts and, in a
    /// file of everything, the portable settings.
    func archiveParams(_ papers: [PaperRef], dest: URL, everything: Bool, kind: String) -> [String: Any] {
        guard let app else { return [:] }
        var params: [String: Any] = ["papers": papers.map { ["path": $0.path, "title": $0.title, "student": $0.student] },
                                     "dest": dest.path, "scope": everything ? "everything" : "chosen", "kind": kind,
                                     "made_by": madeBy]
        if let tags = try? JSONSerialization.jsonObject(with: TagFile.data(app.tags.catalog)) { params["tags"] = tags }
        var drafts: [String: Any] = [:]
        for p in papers { if let d = app.draftStore.json(paper: p.path) { drafts[p.path] = d } }
        if !drafts.isEmpty { params["drafts"] = drafts }
        if everything { params["settings"] = app.testRun ? [:] : PortableSettings.current() }
        return params
    }

    /// What this app is, for the file (backup.json's `made_by`): its name, Paperole or Paperole Dev (AppVariant), this
    /// Mac's install id, the app's version.
    var madeBy: [String: Any] {
        let info = Bundle.main.infoDictionary
        let version = [info?["CFBundleShortVersionString"] as? String, (info?["CFBundleVersion"] as? String).map { "(\($0))" }]
            .compactMap { $0 }.joined(separator: " ")
        return ["variant": AppVariant.current.name, "install": installID, "app": version.isEmpty ? NSNull() : version]
    }

    /// A random id of this Mac's app (`installID` in its defaults; a test run's is its own, never saved).
    private lazy var installID: String = {
        if remember, let s = Prefs.string("installID"), !s.isEmpty { return s }
        let id = "i-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
        if remember { Prefs.set(id, "installID") }
        return id
    }()

    // MARK: Comments

    /// Comments of these papers (a paper's, or a student's: `student`) as CSV or JSON, from a context menu.
    func exportComments(_ papers: [PaperRef], label: String, student: Bool, format: CommentExport.Format) {
        guard let dest = savePanel(name: CommentExport.fileName(label, student: student, format: format), type: format.type,
                                   message: "Export \(student ? label + "’s" : "“" + label + "”’s") comments as \(format.title).")
        else { return }
        writeComments(papers, label: label, format: format, to: dest, origin: .window)
    }

    /// `origin` .window: the result is also the window's bottom line (the status line is in Settings).
    func writeComments(_ papers: [PaperRef], label: String, format: CommentExport.Format, to dest: URL,
                       origin: SheetOrigin = .settings) {
        guard let app else { return }
        guard !working else { return busy(origin) }
        guard !papers.isEmpty else { status = .failed("There are no papers to export."); return }
        guard app.fixtureURL == nil else { status = .failed("Fixture mode: the engine is not running."); return }
        let catalog = app.tags.catalog
        job("Reading the comments of \(Self.count(papers.count, "paper"))…", cancellable: false, failed: { m in
            if origin == .window { app.showNotice(WindowNotice(text: m, failed: true)) }
        }) { [weak self] in
            guard let self else { return }
            let data: Data
            do {
                data = try await self.engine("export_comments", ["papers": papers.map(\.path)])
            } catch let e as EngineError where e.message.hasPrefix("Unknown method") {
                throw DataFailure(message: "This engine is older than the app and cannot export comments. Update the engine.")
            }
            let reply = try makeDecoder().decode(CommentExportReply.self, from: data)
            let read = reply.papers.filter { $0.comments != nil }
            guard !read.isEmpty else {
                throw DataFailure(message: "No paper could be read: " + (reply.papers.first?.error ?? "the engine gave none."))
            }
            let out = format == .csv ? CommentExport.csv(reply, catalog: catalog)
                : try CommentExport.json(reply, catalog: catalog, of: label, exported: DataFiles.now())
            try DataFiles.write(to: dest) { try out.write(to: $0) }
            let n = read.reduce(0) { $0 + ($1.comments?.count ?? 0) }
            let skipped = reply.papers.count - read.count
            let words = "Saved \(Self.count(n, "comment")) to “\(dest.lastPathComponent)”."
                + (skipped > 0 ? " \(Self.count(skipped, "paper")) could not be read." : "")
            self.status = .done(words, dest)
            if origin == .window {
                app.showNotice(WindowNotice(text: words, action: "Show in Finder")) { [weak self] in self?.reveal(dest, origin: .window) }
            }
        }
    }

    // MARK: Tags

    func exportTags() {
        guard let dest = savePanel(name: "Paperole Tags.json", type: .json, message: "Export your writing tags.") else { return }
        writeTags(to: dest)
    }

    func writeTags(to dest: URL) {
        guard let app else { return }
        do {
            let data = try TagFile.data(app.tags.catalog)
            try DataFiles.write(to: dest) { try data.write(to: $0) }
            status = .done("Saved \(Self.count(app.tags.catalog.tags.count, "tag")) to “\(dest.lastPathComponent)”.", dest)
        } catch {
            status = .failed("Could not export the tags: " + error.localizedDescription)
        }
    }

    func importTags() {
        guard let u = openPanel(prompt: "Import", message: "Choose a Paperole tags file (.json).",
                                folders: false, types: [.json]) else { return }
        readTags(from: u)
    }

    func readTags(from url: URL) {
        guard let app else { return }
        do {
            let m = app.tags.catalog.merging(try TagFile.read(url))
            if !m.added.isEmpty { app.tags.update { $0 = m.catalog } }
            status = .done(Self.tagWords(m.added.map(\.name), same: m.same, clashes: m.clashes), nil)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// "Added 2 tags: Rigor, Tone. 10 were here already." / "Nothing to add: …".
    static func tagWords(_ added: [String], same: Int, clashes: [String]) -> String {
        var s = added.isEmpty ? "Nothing to add: you have every tag in it." : "Added \(count(added.count, "tag")): " + added.joined(separator: ", ") + "."
        if !added.isEmpty && same > 0 { s += " \(count(same, "tag")) \(same == 1 ? "was" : "were") here already." }
        if !clashes.isEmpty { s += " Left out, as you have a tag of that name: " + clashes.joined(separator: ", ") + "." }
        return s
    }

    // MARK: Import

    /// Import… (and Add Existing Paper…): an export or backup file, a review folder or a folder to look in.
    func chooseImport(origin: SheetOrigin) {
        guard let u = openPanel(prompt: "Import", message: "Choose a Paperole export or backup (.zip), a review folder, or a folder to look in for review folders.",
                                folders: true, types: [.folder, .zip]) else { return }
        checkImport(u, origin: origin)
    }

    /// The engine reads the file or folder without unpacking anything and compares each paper with the list; then the
    /// preview shows what Import would do. One review folder found on disk, new or the one listed already, is listed
    /// (and shown) at once: nothing to decide. `into`: "Put them in" (the debug item's). `only`: Restore from Last
    /// Backup…'s paper, the only one ticked.
    func checkImport(_ url: URL, origin: SheetOrigin, into dest: URL? = nil, only: PaperRef? = nil) {
        guard let app else { return }
        guard !working else { return busy(origin) }
        guard app.fixtureURL == nil else { status = .failed("Fixture mode: the engine is not running."); return }
        importing = ImportSheetState(source: url, origin: origin)
        // each paper's id as the list keeps it: the engine takes a readable ledger's own, this one for a folder gone or
        // a ledger that cannot be read
        let listed: [[String: Any]] = app.papers.map { p in
            var e: [String: Any] = ["path": p.path]
            if let id = p.ledgerID { e["id"] = id }
            return e
        }
        job("Checking “\(url.lastPathComponent)”…", failed: { [weak self] m in self?.importing?.error = m },
            cancelled: { [weak self] m in self?.importing?.note = m }) { [weak self] in
            guard let self else { return }
            let check: ArchiveCheck
            do {
                check = try ArchiveCheck.decode(try await self.engine("archive_check", ["path": url.path, "papers": listed]))
            } catch let e as EngineError where e.message.hasPrefix("Unknown method") {
                throw DataFailure(message: "This engine is older than the app and cannot import. Update the engine.")
            }
            var plan = ImportPlan.make(check, source: url, catalog: app.tags.catalog, destination: dest ?? self.root,
                                       emptyList: app.papers.isEmpty)
            if let only { plan.tickOnly(only) }
            if let folder = plan.listedAtOnce {
                self.importing = nil
                app.addReviewFolder(folder)
                return
            }
            self.importing?.plan = plan
        }
    }

    /// Restore from Last Backup… (a missing or damaged paper's context menu, DATA.md §6.4): the import preview of the
    /// newest backup holding it, only that paper ticked.
    func restoreFromBackup(_ paper: PaperRef) {
        guard let file = app?.backups.holding(paper)?.url, FileManager.default.fileExists(atPath: file.path) else {
            app?.alertMessage = "No backup in the backup folder holds “\(TransferText.short(paper.title))” now."
            return
        }
        checkImport(file, origin: .window, only: paper)
    }

    func closeImport() {
        if working, importing != nil { cancelWork() }
        importing = nil
    }

    func chooseImportFolder() {
        guard let u = openPanel(prompt: "Choose", message: "Choose the folder to put the imported review folders in.",
                                folders: true, types: [], start: importing?.plan?.destination) else { return }
        importing?.plan?.destination = u
    }

    /// Import: each paper as its choice says, one at a time, each listed as soon as it is in, so what was done stays
    /// done when a later one fails or Cancel stops it (the engine leaves nothing of the one it was writing); then the
    /// drafts (never over one of yours), the tags (merged by id, then name) and, when ticked, the settings. Use This
    /// Copy first closes the paper, its pending edit saved.
    func performImport() {
        guard let app, let plan = importing?.plan, plan.canImport, !working else { return }
        let replacing = Set(plan.acting.filter { $0.choice == .useThis }.compactMap(\.paper.listed))
        if let s = app.selectedPath, replacing.contains(s) {
            guard app.closeForImport() else {
                importing?.error = "Save or discard the note you are writing in “\(TransferText.short(app.state?.paper.title ?? ""))”, then import again."
                return
            }
        }
        job("Importing…", failed: { [weak self] m in self?.importing?.error = m }) { [weak self] in
            guard let self else { return }
            self.importing?.report = await self.importPapers(plan)
        }
    }

    private func importPapers(_ plan: ImportPlan) async -> ImportReport {
        guard let app else { return ImportReport(lines: [], done: 0, of: 0) }
        let fm = FileManager.default
        let acting = plan.acting
        // each paper's row ("Kelp drift · Mei Lin") under what was done to it; `listed`: listed where it is
        var put: [String] = [], putInto: [String] = [], added: [String] = [], copies: [String] = [], used: [String] = []
        var listed: [String] = []
        var drafts = 0, stopped: String?, reveal: URL?, done = 0
        var cancelled = false  // Cancel stopped it: said as a quiet line, not an error
        for (i, it) in acting.enumerated() {
            let p = it.paper
            let name = TransferText.paper(p.title, p.student)
            if stopping {
                stopped = "Stopped before \(name): cancelled."
                cancelled = true
                break
            }
            status = .working("Importing \(name) (\(i + 1) of \(acting.count))…", Double(i) / Double(acting.count))
            // a folder unpacked and not in place yet: said when a later step of this paper fails (Cancel stops only
            // between papers, the engine's unpacking aside)
            var unpacked: String?
            do {
                var ref = PaperRef(path: p.folder, title: p.title ?? "", student: p.student ?? "", factsMoved: true)
                if let f = p.facts {  // a schema-1 backup's: moved into the ledger once listed
                    ref.finished = f.finished
                    ref.buckets = f.buckets.map { $0.mapValues { $0 ?? "" } }
                    ref.keyPage = f.keyPage
                    ref.factsMoved = nil
                }
                switch it.choice {
                case .add:
                    if p.inPlace {
                        if p.status == "different_paper" { _ = try await engine("fork", ["paper": p.folder]) }
                        try await distrust(p.folder)
                    } else {
                        ref.path = try await unpack(plan, p, into: try destination(plan), fork: p.status == "different_paper")
                    }
                    app.list([ref])
                    if p.inPlace { listed.append(it.name) } else { added.append(it.name) }
                case .putBack:
                    ref.factsMoved = nil  // the list's facts go into its ledger where it lacks them (they are newer)
                    var back = true
                    if !p.inPlace {
                        if let old = ImportPlan.oldPlace(it) {
                            ref.path = try await unpack(plan, p, into: old.deletingLastPathComponent(), fork: false)
                            unpacked = ref.path
                            // into its very place, when the file named its folder otherwise (made safe, "… 2")
                            if ref.path != old.path, !fm.fileExists(atPath: old.path) {
                                try fm.moveItem(atPath: ref.path, toPath: old.path)
                                ref.path = old.path
                            }
                        } else {
                            ref.path = try await unpack(plan, p, into: try destination(plan), fork: false)
                            back = false
                        }
                    } else {
                        try await distrust(p.folder)
                    }
                    app.list([ref], replacing: p.listed)
                    // a folder moved in Finder and imported where it is: listed at its new place, not put back
                    if p.inPlace { listed.append(it.name) } else if back { put.append(it.name) } else { putInto.append(it.name) }
                case .keepBoth:
                    if let f = p.found {  // yours, still where it was, listed there too
                        var mine = ref
                        mine.path = f
                        app.list([mine])
                        listed.append(it.name)
                    }
                    ref.title = (p.title ?? "Paper") + " (copy)"
                    if p.inPlace {  // listed where it is, with an id of its own (listed even if its title stays)
                        _ = try await engine("fork", ["paper": p.folder])
                        if (try? await engine("edit_paper", ["paper": p.folder, "title": ref.title])) == nil { ref.title = p.title ?? "" }
                        try await distrust(p.folder)
                    } else {
                        ref.path = try await unpack(plan, p, into: try destination(plan), fork: false, copy: true)
                    }
                    app.list([ref])
                    copies.append(it.name)
                case .useThis:
                    guard let current = p.listed else { continue }
                    let parent = URL(fileURLWithPath: current).deletingLastPathComponent()
                    let incoming = try await unpack(plan, p, into: parent, fork: false)
                    unpacked = incoming
                    // the paper opened again while earlier papers came in (a Settings import): closed before its folder
                    // is swapped, an editor's edit sent first
                    if app.selectedPath == current {
                        guard app.closeForImport() else {
                            throw DataFailure(message: "Save or discard the note you are writing in “\(TransferText.short(p.title ?? ""))”, then import it again.")
                        }
                    }
                    let r = try makeDecoder().decode(SwapReply.self, from: try await engine("swap_in", ["incoming": incoming, "current": current]))
                    // a draft was typed against your copy: it stays with it, unless this copy is newer (its ids mean
                    // the same comments)
                    if p.status != "newer" { app.draftStore.move(from: current, to: r.replaced) }
                    ref.path = current
                    app.paperReplaced(current)
                    used.append(it.name)
                case .keepMine:
                    // yours, still where it was and not listed (the list lost): listed there; nothing else
                    guard let f = p.found else { continue }
                    ref.path = f
                    app.list([ref])
                    listed.append(it.name)
                case .skip:
                    continue
                }
                if let d = p.draftJSON { drafts += app.draftStore.merge(file: d, into: ref.path) }
                if reveal == nil { reveal = URL(fileURLWithPath: ref.path) }
                done += 1
            } catch {
                cancelled = stopping && unpacked == nil
                let why = cancelled ? "cancelled." : error.localizedDescription
                let left = unpacked.map { " This copy is in “\(DataFiles.shown(URL(fileURLWithPath: $0)))”, not listed; yours is as it was." }
                stopped = "Stopped at \(name): \(why)" + (why.hasSuffix(".") ? "" : ".") + (left ?? " Nothing of it was written.")
                break
            }
        }
        // the tags (by id, then name, as Import Tags… does) and, ticked, the settings
        var tagLine = ""
        if !stopping, let t = plan.check.tagsJSON.flatMap({ try? JSONDecoder().decode(TagFile.self, from: $0).tags }) {
            let m = app.tags.catalog.merging(t)
            if !m.added.isEmpty { app.tags.update { $0 = m.catalog } }
            tagLine = m.added.isEmpty ? "" : "Added \(Self.count(m.added.count, "tag")): " + m.added.map(\.name).joined(separator: ", ") + "."
        }
        var settingsLine = ""
        if plan.useSettings, !stopping, stopped == nil, let s = plan.check.settingsJSON.flatMap({ (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }) {
            settingsLine = PortableSettings.apply(s, to: app).isEmpty ? "" : "Used this file’s settings."
        }
        typealias Group = ImportReport.Group
        let dest = plan.destination?.path
        let they = { (n: [String], one: String, more: String) in n.count == 1 ? one : more }
        var groups = [Group(title: "Put back where " + they(put, "it was", "they were"), papers: put),
                      Group(title: "Put back into", place: dest, papers: putInto),
                      Group(title: "Listed where " + they(listed, "it is", "they are"), papers: listed),
                      Group(title: "Added to", place: dest, papers: added),
                      Group(title: "Added as a copy, “(copy)” after the title", papers: copies),
                      Group(title: "Used this copy; yours " + they(used, "is", "are") + " kept in “Replaced by Import” beside it",
                            papers: used)]
        // a restore of one paper leaves the file's others unsaid
        let kept = plan.only ? [] : plan.items.filter { $0.group == .here && $0.choice == .keepMine && !$0.choices.isEmpty && $0.paper.found == nil }
        let why = ["older": " (yours is newer)", "same": " (the same)", "diverged": " (both changed)", "newer": " (this copy is newer)"]
        for status in ["older", "same", "diverged", "newer", ""] {
            let ps = kept.filter { (why[$0.paper.status] == nil ? "" : $0.paper.status) == status }
            groups.append(Group(title: "Kept yours" + (why[status] ?? ""), papers: ps.map(\.name)))
        }
        // the preview's "Can't import", so the report accounts for every paper of the file
        let cannot = plan.only ? [] : plan.items.filter { $0.group == .cannot }
        groups.append(Group(title: "Left out: can’t be imported", papers: cannot.map(\.name)))
        groups.removeAll { $0.papers.isEmpty }
        var lines: [String] = []
        let tail = [drafts > 0 ? "Added \(Self.count(drafts, "draft"))." : "", tagLine, settingsLine].filter { !$0.isEmpty }
        if !tail.isEmpty { lines.append(tail.joined(separator: " ")) }
        if stopped == nil { lines.append("Nothing else changed.") }
        let report = ImportReport(groups: groups, lines: lines, stopped: stopped, cancelled: cancelled, done: done, of: acting.count,
                                  reveal: reveal)
        status = stopped == nil || cancelled ? .done(report.title + " from “\(plan.source.lastPathComponent)”.", reveal)
            : .failed(report.stopped ?? "")
        return report
    }

    /// "Put them in", made when it is the default and not there yet.
    private func destination(_ plan: ImportPlan) throws -> URL {
        guard let d = plan.destination else { throw DataFailure(message: "no folder was chosen to put it in.") }
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// One paper of the file into a new folder of `dest` (the engine's `archive_unpack`): its path.
    private func unpack(_ plan: ImportPlan, _ p: ArchiveCheck.Paper, into dest: URL, fork: Bool, copy: Bool = false) async throws -> String {
        let data = try await engine("archive_unpack", ["path": plan.source.path, "paper": p.folder, "dest": dest.path,
                                                       "fork": fork, "copy": copy])
        return try makeDecoder().decode(UnpackReply.self, from: data).path
    }

    private struct UnpackReply: Decodable {
        var path: String
    }

    /// Trust does not travel (UX.md §41): a review folder listed where it is, new to the list, comes in with shell
    /// escape off, as a paper unpacked from a file does (the engine's `archive._distrusted`); its ledger may have been
    /// written on another Mac. Thrown when it cannot be turned off, so the folder is not listed. A folder whose state
    /// cannot be read is listed as before (nothing builds from a ledger that does not read; Put Back leaves it off).
    private func distrust(_ folder: String) async throws {
        guard let data = try? await engine("state", ["paper": folder]),
              (try? makeDecoder().decode(Reply.self, from: data))?.state.paper.shellEscape == true else { return }
        _ = try await engine("edit_paper", ["paper": folder, "shell_escape": false])
    }

    private struct SwapReply: Decodable {
        var path: String
        var replaced: String
    }

    // MARK: Running

    /// Wait for the work running: said where the advisor is looking.
    private func busy(_ origin: SheetOrigin) {
        let m = "Wait until the work in Settings › Data & Storage has finished (\(step ?? "")), then try again."
        if origin == .window { app?.alertMessage = m } else { NSSound.beep() }
    }

    /// A request to the engine, its progress the status line's step; Cancel asks the engine to stop it. Sent also
    /// once Cancel was asked: Import checks `stopping` between papers, so a paper half imported is finished.
    private func engine(_ method: String, _ params: [String: Any]) async throws -> Data {
        guard let app else { throw CancellationError() }
        let json = try JSONSerialization.data(withJSONObject: params)
        let client = Self.archiveMethods.contains(method) ? archiveEngine : app.engine
        let id = client.send(method, params: json) { message in
            Task { @MainActor [weak self] in if self?.working == true { self?.status = .working(message, nil) } }
        }
        request = (id, client)
        defer { request = nil }
        return try await client.result(id)
    }

    /// Runs `work` with the status line showing its steps (Cancel stops it unless `cancellable` is false), then its
    /// result as it set it, or its error (`failed` hears it too); "Cancelled. Nothing was written." when stopped, a
    /// quiet line (`cancelled` hears it), never an error.
    private func job(_ title: String, cancellable: Bool = true, failed: ((String) -> Void)? = nil,
                     cancelled: ((String) -> Void)? = nil, _ work: @escaping () async throws -> Void) {
        guard !working else { return }
        stopping = false
        self.cancellable = cancellable
        status = .working(title, nil)
        Task {
            do {
                try await work()
                if working { status = nil }
            } catch {
                let stopped = stopping || error is CancellationError
                let m = stopped ? "Cancelled. Nothing was written." : error.localizedDescription
                status = stopped ? .done(m, nil) : .failed(m)
                if stopped { cancelled?(m) } else { failed?(m) }
            }
            self.cancellable = false
            stopping = false
            archiveEngine.stop()  // its process ends between jobs (once it has answered everything sent)
        }
    }

    /// Cancel: the engine stops the request at its next block, and the job stops before its next step.
    func cancelWork() {
        guard working, cancellable else { return }
        stopping = true
        if let r = request, let json = try? JSONSerialization.data(withJSONObject: ["id": r.id]) {
            let c = r.on.send("cancel", params: json)  // to the engine running it
            Task { _ = try? await r.on.result(c) }  // its reply, so none is kept waiting
        }
    }

    nonisolated static func count(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }

    // MARK: Panels

    private func savePanel(name: String, type: UTType, message: String) -> URL? {
        guard !LaunchOptions.background else { return nil }  // a test run never shows a panel (the debug items give URLs)
        let p = NSSavePanel()
        p.nameFieldStringValue = name
        p.allowedContentTypes = [type]
        p.canCreateDirectories = true
        p.message = message
        return p.runModal() == .OK ? p.url : nil
    }

    private func openPanel(prompt: String, message: String, folders: Bool, types: [UTType], start: URL? = nil) -> URL? {
        guard !LaunchOptions.background else { return nil }
        let p = NSOpenPanel()
        p.canChooseDirectories = folders
        p.canChooseFiles = !types.isEmpty && types != [.folder]
        p.canCreateDirectories = folders
        p.allowsMultipleSelection = false
        if !types.isEmpty { p.allowedContentTypes = types }
        if let start { p.directoryURL = start }
        p.prompt = prompt
        p.message = message
        return p.runModal() == .OK ? p.url?.standardizedFileURL : nil
    }
}

// MARK: Debug item

extension DataModel {
    /// The debug item `data …` (UX.md §13, §28; DATA.md): Settings › Data & Storage's work and the transfer sheets without
    /// a panel, for background runs; `done` gets the result once the work has finished (at most 120 s).
    ///   data                                    the result alone
    ///   data root <folder>|none                 the folder for new review folders (never saved by a test run)
    ///   data export [student:<name>|<paper folder>]  Export… (File's, or that student's or paper's): the sheet on the window
    ///   data exportto <out.zip>                 the sheet's Export…, to that file
    ///   data import <file or folder> [<folder>] Import…: the check, then the preview on the window (into that folder)
    ///   data choose <n> <choice>                the preview's n-th paper (from 0): add, putBack, keepMine, useThis,
    ///                                           keepBoth or skip, as its checkbox or pop-up
    ///   data settings on|off                    the preview's "Also use this file's settings"
    ///   data importnow                          the preview's Import (the report follows in the sheet)
    ///   data close                              the Export, Import or history sheet's Cancel or Done
    ///   data history <paper folder>             Put Back an Earlier Ledger…: the sheet; `data putback <n>` its n-th
    ///                                           version (from 0) put back
    ///   data remove <paper folder>|student:<name>  Remove from List; `data undo` the window line's Undo
    ///   data comments csv|json <out> <paper folder>|student:<name>   Export Comments ▸ CSV… / JSON…
    ///   data tags export|import <file>          Writing tags' Export… / Import…
    ///   data backup on <folder>|off|now         Backups: the switch on with that folder (no panel) or off; Back Up Now
    ///   data check                              the quiet check on the listed folders, now
    ///   data restore <paper folder>             Restore from Last Backup…: the import preview, that paper ticked
    ///   data clear / data cancel                the thumbnails' Clear / the work's Cancel
    ///   data scroll top|bottom                  the tab's form scrolled, in the window showing it (screenshots)
    /// Result: {status, message, url, root, papers, missing, tags, drafts, thumbnails, notice, export: {rows: [[depth,
    /// title, mark, line]], summary, name, everything, phase} | null, import: {header, items: [[title, group, choice,
    /// choices, detail]], destination, settings, action, report: [[title, place, [rows]], …, [lines]], stopped, error}
    /// | null, history: {versions, selected, error} | null, backups: {on, folder, volume, step, last, left, failure, files, sameDisk, scheduled, due}, damaged:
    /// [paper folder]}.
    func debug(_ rest: String, done: @escaping ([String: Any]) -> Void) {
        let w = rest.split(separator: " ").map(String.init)
        let url = { (i: Int) -> URL? in i < w.count ? URL(fileURLWithPath: w[i]) : nil }
        let paper = { (i: Int) -> String in w.count > i ? URL(fileURLWithPath: w[i...].joined(separator: " ")).standardizedFileURL.path : "" }
        var settle = 0.8
        switch w.first ?? "" {
        case "root": reviewRoot = w.count > 1 && w[1] != "none" ? w[1] : nil
        case "export":
            let who = w.count > 1 ? w[1...].joined(separator: " ") : ""
            if who.hasPrefix("student:") {
                let g = app?.studentGroups.first { $0.name == String(who.dropFirst("student:".count)) }
                openExport(origin: .window, only: g?.papers.map(\.path) ?? [])
            } else {
                openExport(origin: .window, only: who.isEmpty ? nil : [paper(1)])
            }
            settle = 1.5  // the sizes counted
        case "exportto": if let u = url(1) { writeExport(to: u) }
        case "import": if let u = url(1) { checkImport(u, origin: .window, into: url(2)) }
        case "choose":
            if w.count > 2, let n = Int(w[1]), let c = ImportPlan.Choice(rawValue: w[2]), let p = importing?.plan, n < p.items.count {
                importing?.plan?.items[n].choice = c
            }
        case "settings": importing?.plan?.useSettings = w.count > 1 && w[1] == "on"
        case "importnow": performImport()
        case "close":
            if export != nil { closeExport() }
            if importing != nil { closeImport() }
            app?.ledgerHistory = nil
        case "history":
            app?.openLedgerHistory(paper(1))
            settle = 1.5
        case "putback":
            if w.count > 1, let n = Int(w[1]), let vs = app?.ledgerHistory?.versions, n < vs.count {
                app?.ledgerHistory?.selected = vs[n].name
                app?.putBackLedger()
            }
            settle = 2
        case "remove":
            let who = w.count > 1 ? w[1...].joined(separator: " ") : ""
            if who.hasPrefix("student:"), let g = app?.studentGroups.first(where: { $0.name == String(who.dropFirst("student:".count)) }) {
                app?.removePapers(g.papers.map(\.path), student: g.name)
            } else {
                app?.removePaper(paper(1))
            }
        case "undo": app?.noticeClicked()
        case "comments":
            if w.count > 3, let f = CommentExport.Format(rawValue: w[1]), let u = url(2), let app {
                let who = w[3...].joined(separator: " ")
                if who.hasPrefix("student:") {
                    let name = String(who.dropFirst("student:".count))
                    let g = app.studentGroups.first { $0.name == name }
                    writeComments(g?.papers ?? [], label: name, format: f, to: u)
                } else {
                    let p = app.papers.filter { $0.path == paper(3) }
                    writeComments(p, label: p.first?.title ?? who, format: f, to: u)
                }
            }
        case "tags": if w.count > 2, let u = url(2) { if w[1] == "export" { writeTags(to: u) } else { readTags(from: u) } }
        case "backup":
            let b = app?.backups
            switch w.count > 1 ? w[1] : "" {
            case "on": if w.count > 2 { b?.use(URL(fileURLWithPath: w[2...].joined(separator: " "))) }
            case "off": b?.turnOff()
            case "now": b?.backUp(manual: true)
            default: break
            }
        case "check": app?.backups.checkFolders()
        case "restore":
            if let p = app?.papers.first(where: { $0.path == paper(1) }) { restoreFromBackup(p) }
        case "clear": clearCaches()
        case "cancel": cancelWork()
        case "scroll":  // the tab's form scrolled to its top or bottom, in the window showing it (screenshots)
            let title = SettingsView.Tab.data.title
            func scrollers(_ v: NSView) -> [NSScrollView] { ((v as? NSScrollView).map { [$0] } ?? []) + v.subviews.flatMap(scrollers) }
            for win in NSApp.windows where win.title == title {
                for sv in win.contentView.map(scrollers) ?? [] {
                    guard let doc = sv.documentView, doc.frame.height > sv.contentView.bounds.height else { continue }
                    let y = w.count > 1 && w[1] == "bottom" ? (doc.isFlipped ? doc.frame.height - sv.contentView.bounds.height : 0)
                        : (doc.isFlipped ? 0 : doc.frame.height - sv.contentView.bounds.height)
                    sv.contentView.scroll(to: NSPoint(x: 0, y: y))
                    sv.reflectScrolledClipView(sv.contentView)
                }
            }
        default: break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.whenDone {
                // a listed paper is read by the engine after the work: a moment for its `state`
                DispatchQueue.main.asyncAfter(deadline: .now() + settle) { done(self?.debugResult() ?? [:]) }
            }
        }
    }

    private func whenDone(_ f: @escaping () -> Void, tries: Int = 1200) {
        let backups = app?.backups
        if (!working && backups?.running != true && backups?.checking != true) || tries == 0 { return f() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.whenDone(f, tries: tries - 1) }
    }

    func debugResult() -> [String: Any] {
        func null(_ v: Any?) -> Any { v ?? NSNull() }
        var r: [String: Any] = ["root": null(root?.path), "papers": app?.papers.map(\.path) ?? [],
                                "missing": app?.missingPapers.sorted() ?? [],
                                "tags": app?.tags.catalog.tags.count ?? 0, "drafts": app?.draftStore.all().count ?? 0,
                                "thumbnails": null(thumbnailBytes), "notice": null(app?.notice?.text),
                                "backups": app?.backups.debugResult() ?? [:], "damaged": app?.damagedPapers.keys.sorted() ?? []]
        switch status {
        case .working(let s, _): r["status"] = "working"; r["message"] = s
        case .done(let s, let u): r["status"] = "done"; r["message"] = s; r["url"] = null(u?.path)
        case .failed(let s): r["status"] = "failed"; r["message"] = s
        case nil: r["status"] = "none"
        }
        if let e = export {
            var rows: [[Any]] = [[0, "All students", "\(e.mark(e.students.flatMap(\.papers)))", ""]]
            for s in e.students {
                rows.append([1, s.name, "\(e.mark(s.papers))", ""])
                for p in s.papers { rows.append([2, p.ref.title, "\(e.mark([p]))", null(p.gone)]) }
            }
            let phase: String
            switch e.phase {
            case .choosing: phase = "choosing"
            case .working: phase = "working"
            case .done(let s, _): phase = s
            case .failed(let s): phase = "failed: " + s
            }
            r["export"] = ["rows": rows, "summary": e.summary, "name": e.fileName(day: DataFiles.day()),
                           "everything": e.everything, "phase": phase]
        } else {
            r["export"] = NSNull()
        }
        if let st = importing {
            var i: [String: Any] = ["error": null(st.error), "stopped": null(st.report?.stopped),
                                    "report": null(st.report.map { r in r.groups.map { [$0.title, null($0.place), $0.papers] as [Any] } + [r.lines] })]
            if let p = st.plan {
                i["header"] = p.header
                i["items"] = p.items.map { [$0.paper.title ?? "", "\($0.group)", $0.choice.rawValue, $0.choices.map(\.rawValue),
                                            p.detail($0).map(\.text)] as [Any] }
                i["destination"] = null(p.destination?.path)
                i["settings"] = p.check.settingsJSON == nil ? NSNull() : p.useSettings as Any
                i["action"] = p.actionTitle
                i["tags"] = null(p.tagWords)
                i["drafts"] = null(p.draftWords)
            }
            r["import"] = i
        } else {
            r["import"] = NSNull()
        }
        if let h = app?.ledgerHistory {
            r["history"] = ["versions": null(h.versions?.map(\.words)), "selected": null(h.selected), "error": null(h.error)]
        } else {
            r["history"] = NSNull()
        }
        return r
    }
}
