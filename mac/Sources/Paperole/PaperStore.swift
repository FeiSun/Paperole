import Foundation

/// A review folder the app remembers. The engine keeps no list of papers (CONTRACT §2).
/// The three facts (finished, buckets, keyPage) live in the paper's ledger since DATA.md §2.2 (`edit_paper`); the list
/// keeps copies for display, from the ledger once `factsMoved`.
struct PaperRef: Codable, Hashable, Identifiable {
    var path: String
    var title: String
    var student: String
    /// The day the advisor marked the paper finished ("2026-07-20"; FEATURES OV-7), shown while its latest round is
    /// closed; nil while it is not marked.
    var finished: String? = nil
    /// The advisor's Map Headings answers (FEATURES OV-9, OVERVIEW-v2 §3.2): a section key → a standard section id
    /// (abstract, introduction, method, results, discussion, conclusion), or "" for a column of its own name. Sent
    /// to the engine's `overview` as `buckets`; nil until the advisor confirms them.
    var buckets: [String: String]? = nil
    /// The page the advisor chose to stand for the paper (Set as Key Page; TAGS.md §7): a round and a page of it
    /// (0-based), followed into later rounds by the engine (`overview`'s `key_pages`); nil: the busiest page.
    var keyPage: KeyPageChoice? = nil
    /// The paper's id as its ledger has it (a copy, from `summaries`): Import matches a paper whose folder is gone by it.
    var ledgerID: String? = nil
    /// The facts above were moved into the ledger (`adopt_facts`, once per paper): from then on they are the ledger's.
    var factsMoved: Bool? = nil
    var id: String { path }
}

/// A key page as chosen: in `papers.json` as `{"round": 4, "page": 5}`.
struct KeyPageChoice: Codable, Hashable {
    var round: Int
    var page: Int
}

/// Application Support/Paperole/papers.json (Paperole Dev's own folder in the dev app; AppVariant). A file that
/// does not read is never replaced by an empty list (DATA.md §2.5): it is moved aside as papers.json.bad
/// (papers-2.json.bad …), as tags.json is, and nothing is saved while it could not be.
enum PaperStore {
    static var fileURL: URL { AppVariant.current.dataFolder.appendingPathComponent("papers.json") }

    private static func read(_ url: URL) -> [PaperRef]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([PaperRef].self, from: data)
    }

    /// The list, and what went wrong reading it (the words for the advisor), if anything. `setAside` false (a test
    /// run): an unreadable file is left as it is.
    static func load(from url: URL = fileURL, setAside move: Bool = true) -> (papers: [PaperRef], problem: String?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return ([], nil) }
        if let papers = read(url) { return (papers, nil) }
        guard move else { return ([], "Your papers list (\(DataFiles.shown(url))) could not be read. A test run leaves it as it is.") }
        guard let aside = setAside(url) else {
            return ([], "Your papers list (\(DataFiles.shown(url))) could not be read, nor moved aside, so it is left as it is and nothing is saved to it.")
        }
        return ([], "Your papers list could not be read. It was kept as “\(aside.lastPathComponent)” beside it. Import… a folder of review folders (such as ~/Reviews) lists them again.")
    }

    /// Moves an unreadable list aside; nil when it could not be.
    static func setAside(_ url: URL) -> URL? {
        let fm = FileManager.default
        var aside = url.appendingPathExtension("bad")
        var n = 2
        while fm.fileExists(atPath: aside.path) {
            aside = url.deletingLastPathComponent().appendingPathComponent("papers-\(n).json.bad")
            n += 1
        }
        do {
            try fm.moveItem(at: url, to: aside)
            return aside
        } catch {
            NSLog("Paperole: papers.json could not be read nor moved aside: %@", error.localizedDescription)
            return nil
        }
    }

    /// Writes the list whole (a temporary file, then a replace). An unreadable file there is moved aside first, and
    /// is never written over. The day's first save keeps the list as it was in "papers copies" (`keepCopy`).
    static func save(_ papers: [PaperRef], to url: URL = fileURL, day: String = DataFiles.day()) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path), read(url) == nil, setAside(url) == nil {
            throw DataFailure(message: "the file there could not be read, nor moved aside.")
        }
        keepCopy(url, day: day)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try enc.encode(papers).write(to: url, options: .atomic)
    }

    /// A daily copy (DATA.md §2.5): the list as it was before the day's first save, "papers copies/papers
    /// 2026-10-22.json" beside it, the 14 newest kept (only files of that name are ever deleted). Nothing when there is
    /// no readable list yet.
    static func keepCopy(_ url: URL, day: String) {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent().appendingPathComponent("papers copies")
        let copy = dir.appendingPathComponent("papers \(day).json")
        guard !fm.fileExists(atPath: copy.path), read(url) != nil,
              (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil,
              (try? fm.copyItem(at: url, to: copy)) != nil else { return }
        let ours = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { name in
            name.hasPrefix("papers ") && name.hasSuffix(".json") && name.count == "papers 2026-10-22.json".count
        }
        for name in ours.sorted().dropLast(14) { try? fm.removeItem(at: dir.appendingPathComponent(name)) }
    }
}

/// Debug launch arguments: --paper <folder> (again for more papers, listed but not selected), --select <comment id>, --tab comments|changes, --fixture <state.json>,
/// --debug-open-comment <phrase> (select the phrase in an open round's PDF and open the new-comment popover),
/// --debug-note <text> (with --debug-open-comment: type the note, try to close the popover, press Save),
/// --debug-switch-to <folder> (select this paper right after --paper's, while its first request runs),
/// --debug-script "item;…" (or its M1 name --debug-drag; items in DebugScript.swift and UX.md §13),
/// --debug-out <file> (where --debug-script writes one JSON value per item, or --debug-scroll-perf its result;
/// default stderr), --debug-quit (quit when the script or the perf run ends),
/// --debug-scroll-perf scroll|keys (measure the comment panel's frames), --debug-marks off (no marks),
/// --drafts <folder> (where unsent drafts are kept instead of Application Support; a --background run without it keeps
/// them in a temporary folder of its own),
/// --reading on|off (Settings' "Mark changed paragraphs to read" for this run, never saved; UX.md §18),
/// --fold on|off (Settings' "Fold the appendix and long reference lists" for this run, never saved; UX.md §21),
/// --tags <file> (the writing tags' catalogue for this run instead of Application Support's; UX.md §24),
/// --icon-style automatic|light|dark (Settings › General's app icon style for this run: a test run, which reads and
/// saves it never; UX.md §26),
/// --level overview|review (where --paper or --fixture opens the paper; Review by default, as before the overview),
/// --overview-fixture <overview.json> (the engine's `overview` reply to show instead of asking the engine; UX.md §21),
/// --cache <folder> (where the overview's thumbnails are kept instead of the caches folder; a --background or fixture
/// run without it keeps them in a temporary folder of its own),
/// --no-list (the Papers list shows only the --paper papers: the user's list is neither read nor saved; screenshots),
/// --list <papers.json> (a --background run's papers list read from that file instead of Application Support's, never
/// saved: a test of the list's own copies, such as a missing paper's title and student),
/// --hub all|move|student:<name> (open at All Students, Your Move or that student's page instead of a paper; UX.md §22),
/// --background (a test run: never activated, no Dock icon, the window behind all others; README).
struct LaunchOptions {
    static var background: Bool { CommandLine.arguments.contains("--background") }
    /// `swift test`: XCTest is loaded.
    static var unitTest: Bool { NSClassFromString("XCTestCase") != nil }
    /// A test run (CLAUDE.md): --background, a fixture, --no-list or `swift test`, one rule everywhere (the code audit:
    /// five had drifted, and a --no-list run without --background wrote Dev's own tags, settings, drafts and
    /// thumbnails). It never saves the list, a setting, the tags, a draft or a thumbnail where the advisor's are.
    var isTestRun: Bool { Self.background || fixture != nil || noList || Self.unitTest }
    /// This process's own (Prefs, which no model holds), from its arguments, read once.
    static let isTestRun = parse(CommandLine.arguments).isTestRun
    /// `--appearance light|dark`: a test run's window in that appearance, whatever the system's (screenshots of either).
    static var appearance: String? {
        guard let i = CommandLine.arguments.firstIndex(of: "--appearance"), i + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[i + 1]
    }

    var paper: String?
    var morePapers: [String] = []
    var select: String?
    var tab: String?
    var fixture: String?
    var openComment: String?
    var note: String?
    var switchTo: String?
    var script: String?
    var debugOut: String?
    var quit = false
    var scrollPerf: String?
    var marks = true
    var drafts: String?
    var focus = false  // --focus: Focus once the PDF is shown (test runs: the Focus perf check)
    /// --reading on|off: reading marks on or off for this run, whatever the user's setting, which it never changes.
    var reading: Bool?
    /// --level overview|review: the level a paper given at launch opens at (Review when not given).
    var level: Level?
    /// --overview-fixture: an `overview` reply (OVERVIEW-v2 §5.2) read instead of the engine's.
    var overviewFixture: String?
    /// --cache: the thumbnails' folder for this run.
    var cache: String?
    /// --no-list: only the --paper papers in the list; papers.json is neither read nor written.
    var noList = false
    /// --list: a --background run's papers list, read from this file (never saved).
    var list: String?
    /// --hub: the hierarchy's page to open at (All Students, Your Move, a student's page), no paper selected.
    var hub: HubPage?
    /// --fold on|off: Settings' folding of a long appendix for this run, whatever the user's setting, never saved.
    var fold: Bool?
    /// --tags <file>: the tag catalogue of this run (a test run without it keeps one in a temporary folder of its own).
    var tags: String?
    /// --icon-style: the app icon's style for this run (AppIcons.swift), never saved.
    var iconStyle: AppIconStyle?

    static func parse(_ args: [String]) -> LaunchOptions {
        var o = LaunchOptions()
        var i = 1
        while i < args.count {
            let value = i + 1 < args.count ? args[i + 1] : nil
            switch args[i] {
            case "--paper":
                if o.paper == nil { o.paper = value } else if let value { o.morePapers.append(value) }
                i += 1
            case "--select": o.select = value; i += 1
            case "--tab": o.tab = value; i += 1
            case "--fixture": o.fixture = value; i += 1
            case "--debug-open-comment": o.openComment = value; i += 1
            case "--debug-note": o.note = value; i += 1
            case "--debug-switch-to": o.switchTo = value; i += 1
            case "--debug-script", "--debug-drag": o.script = value; i += 1
            case "--debug-out": o.debugOut = value; i += 1
            case "--debug-quit": o.quit = true
            case "--debug-scroll-perf": o.scrollPerf = value; i += 1
            case "--debug-marks": o.marks = value != "off"; i += 1
            case "--drafts": o.drafts = value; i += 1
            case "--focus": o.focus = true
            case "--reading": o.reading = value.map { $0 != "off" }; i += 1
            case "--level": o.level = value.flatMap(Level.init(rawValue:)); i += 1
            case "--overview-fixture": o.overviewFixture = value; i += 1
            case "--cache": o.cache = value; i += 1
            case "--no-list": o.noList = true
            case "--list": o.list = value; i += 1
            case "--hub": o.hub = value.flatMap(HubPage.init(argument:)); i += 1
            case "--fold": o.fold = value.map { $0 != "off" }; i += 1
            case "--tags": o.tags = value; i += 1
            case "--icon-style": o.iconStyle = value.flatMap(AppIconStyle.init(rawValue:)); i += 1
            default: break
            }
            i += 1
        }
        return o
    }
}

/// The view preferences remembered across launches (style, Papers folded, changed words, reading marks). A test run
/// (`LaunchOptions.isTestRun`) starts from the defaults and saves nothing, so it never changes how the user's own app
/// opens (CLAUDE.md).
enum Prefs {
    static func string(_ key: String) -> String? { LaunchOptions.isTestRun ? nil : UserDefaults.standard.string(forKey: key) }
    static func bool(_ key: String) -> Bool? { LaunchOptions.isTestRun ? nil : UserDefaults.standard.object(forKey: key) as? Bool }
    static func strings(_ key: String) -> [String]? { LaunchOptions.isTestRun ? nil : UserDefaults.standard.stringArray(forKey: key) }
    static func set(_ value: Any, _ key: String) { if !LaunchOptions.isTestRun { UserDefaults.standard.set(value, forKey: key) } }
}
