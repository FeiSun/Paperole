import AppKit
import Foundation

// The writing tags (design/tags/TAGS.md §1–§5 with the design critique's fixes; UX.md §24): an app-level catalogue
// of the advisor's tags (names, groups, order, hidden, signs, definitions), kept in Application Support/Paperole/
// tags.json in real use and in a folder of the run's own in a test run; the ledger holds only the tag ids per comment,
// written by the engine (`tag`, `comment` with `tags`; CONTRACT amendment "Tags, key page and Reopen"). Suggestions
// are worked out here, on this Mac only, from the note's words, the comment's kind and where it is.

/// A tag's group: only for rows and for filing a new tag, never for comparing (TAGS.md §1.2, T5).
enum TagGroup: String, Codable, CaseIterable, Identifiable {
    case language, thinking, presentation, praise, other

    var id: String { rawValue }
    var title: String {
        switch self {
        case .language: return "Language"
        case .thinking: return "Thinking"
        case .presentation: return "Presentation"
        case .praise: return "Not a problem"
        case .other: return "Other"
        }
    }
}

/// One tag of the catalogue: a stable id (`grammar` … `praise` built in; `u-` and 8 hex digits for the advisor's own),
/// the advisor's name for it, its group, a one-line definition (the help tag), the For the next draft line, an SF
/// Symbol (no colour), and whether the picker shows it (a hidden tag keeps its comments: history counts it).
struct WritingTag: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var group: TagGroup
    var hint: String = ""
    var focus: String = ""
    var sign: String?
    var hidden = false
    var created: String?

    init(id: String, name: String, group: TagGroup, hint: String = "", focus: String = "", sign: String? = nil,
         hidden: Bool = false, created: String? = nil) {
        self.id = id
        self.name = name
        self.group = group
        self.hint = hint
        self.focus = focus
        self.sign = sign
        self.hidden = hidden
        self.created = created
    }

    private enum Keys: String, CodingKey { case id, name, group, hint, focus, sign, hidden, created }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        group = (try? c.decodeIfPresent(TagGroup.self, forKey: .group)) ?? .other
        hint = try c.decodeIfPresent(String.self, forKey: .hint) ?? ""
        focus = try c.decodeIfPresent(String.self, forKey: .focus) ?? ""
        sign = try c.decodeIfPresent(String.self, forKey: .sign)
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        created = try c.decodeIfPresent(String.self, forKey: .created)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(group, forKey: .group)
        try c.encode(hint, forKey: .hint)
        try c.encode(focus, forKey: .focus)
        try c.encodeIfPresent(sign, forKey: .sign)
        try c.encode(hidden, forKey: .hidden)
        try c.encodeIfPresent(created, forKey: .created)
    }

    var builtIn: Bool { TagCatalog.builtInIDs.contains(id) }
}

/// The catalogue: its order is the picker's and every table's, except Topics, by count with ties in this order (UI v4).
/// Pure, so every rule is tested.
struct TagCatalog: Equatable {
    var tags: [WritingTag]

    init(tags: [WritingTag] = TagCatalog.defaults) { self.tags = tags }

    /// The default tags (TAGS.md §1.2; Clarity's sign is not an eye, the critique: Settings hid tags with an eye and
    /// the rows showed it as "seen").
    static let defaults: [WritingTag] = [
        WritingTag(id: "grammar", name: "Grammar", group: .language,
                   hint: "Articles, tense, plurals and agreement, sentence structure, punctuation.",
                   focus: "Read each noun phrase once for a/the and singular/plural, and each verb for tense.",
                   sign: "textformat.abc"),
        WritingTag(id: "wording", name: "Wording", group: .language,
                   hint: "Word choice and collocation, register, Chinglish, repetition, wordiness.",
                   focus: "Prefer the plain word your field uses; cut words that add nothing.",
                   sign: "character.cursor.ibeam"),
        WritingTag(id: "clarity", name: "Clarity", group: .thinking,
                   hint: "Vague or ambiguous sentences, unclear “this” or “it”, terms not defined at first use.",
                   focus: "Define each term and symbol where it first appears.",
                   sign: "text.magnifyingglass"),
        WritingTag(id: "logic", name: "Logic & claims", group: .thinking,
                   hint: "Claims beyond the evidence: overclaiming, cause vs. correlation, gaps in the argument.",
                   focus: "Say only what your data show; mark a guess as a guess.",
                   sign: "scalemass"),
        WritingTag(id: "evidence", name: "Evidence & citations", group: .thinking,
                   hint: "Missing citation or source, comparison with prior work, baselines, statistics.",
                   focus: "Back each claim with a source or your own result, and compare with prior work.",
                   sign: "books.vertical"),
        WritingTag(id: "structure", name: "Structure", group: .thinking,
                   hint: "Order of ideas, topic sentences, transitions, what belongs in which paragraph or section.",
                   focus: "Open each paragraph with its point; one idea per paragraph.",
                   sign: "list.bullet.indent"),
        WritingTag(id: "figures", name: "Figures & tables", group: .presentation,
                   hint: "Captions, axes and units, legends, readability, a figure the text never mentions.",
                   focus: "Give every axis a label and a unit, and refer to every figure in the text.",
                   sign: "chart.xyaxis.line"),
        WritingTag(id: "math", name: "Math & notation", group: .presentation,
                   hint: "Symbols defined at first use, consistent notation, equations, units in formulas.",
                   focus: "Define every symbol once and keep the same symbol for the same thing.",
                   sign: "function"),
        WritingTag(id: "format", name: "Format & LaTeX", group: .presentation,
                   hint: "Reference style, \\cite and \\ref, capitals, spacing, the template.",
                   focus: "Use \\cite and \\ref for every reference, and one reference style.",
                   sign: "curlybraces"),
        WritingTag(id: "praise", name: "Well done", group: .praise,
                   hint: "Something done well. Never counted as a problem.", sign: "star"),
    ]
    static let builtInIDs = Set(defaults.map(\.id))
    /// Not a tag: the Not tagged row (and following it on the paper page), with its own sign.
    static let untagged = "untagged"
    static let untaggedSign = "tag"
    /// The signs a new tag may take (TAGS.md §2.3, with the critique's fix: none a built-in tag or the Not tagged row
    /// uses, so every sign means one tag).
    static let palette = ["leaf", "flag", "bookmark", "bolt", "pin", "ruler", "globe", "clock", "link", "number",
                          "questionmark.circle", "person", "scissors", "lightbulb", "paperclip", "info.circle"]
    /// The signs' names in the sign menus (the review: they showed the symbols' identifiers, "questionmark.circle").
    static let signNames: [String: String] = [
        "leaf": "Leaf", "flag": "Flag", "bookmark": "Bookmark", "bolt": "Bolt", "pin": "Pin", "ruler": "Ruler",
        "globe": "Globe", "clock": "Clock", "link": "Link", "number": "Number Sign", "questionmark.circle": "Question Mark",
        "person": "Person", "scissors": "Scissors", "lightbulb": "Light Bulb", "paperclip": "Paper Clip", "info.circle": "Info",
        // the built-in tags' own, which their menus list first
        "textformat.abc": "Letters", "character.cursor.ibeam": "Text Cursor", "text.magnifyingglass": "Magnifying Glass",
        "scalemass": "Scales", "books.vertical": "Books", "list.bullet.indent": "Indented List",
        "chart.xyaxis.line": "Line Chart", "function": "Function", "curlybraces": "Braces", "star": "Star",
    ]

    /// A sign's name: its own, else its identifier's first word ("hand.raised" → "Hand").
    static func signName(_ sign: String) -> String {
        if let n = signNames[sign] { return n }
        let word = sign.split(separator: ".").first.map(String.init) ?? sign
        return word.prefix(1).uppercased() + word.dropFirst()
    }

    /// The signs a sign menu offers: the palette's that no other tag has (every sign means one tag; the review: the
    /// menus offered taken ones), and first the tag's own when the palette lacks it (a built-in one's). `id`: the tag
    /// whose menu it is; nil for New Tag….
    func freeSigns(for id: String? = nil) -> [String] {
        let taken = Set(tags.filter { $0.id != id }.compactMap(\.sign) + [Self.untaggedSign])
        var s = Self.palette.filter { !taken.contains($0) }
        if let own = id.flatMap({ tag($0)?.sign }), !s.contains(own) { s.insert(own, at: 0) }
        return s
    }
    static let maxName = 32
    /// The engine's rule for an id (CONTRACT: `^[a-z][a-z0-9-]{0,31}$`), and its limit per comment.
    static let maxPerComment = 12

    static func validID(_ id: String) -> Bool {
        id.range(of: #"^[a-z][a-z0-9-]{0,31}$"#, options: .regularExpression) != nil
    }

    /// The app's catalogue as it is now, for the words of pure code that has no model (the overview's token and
    /// captions); kept by `TagModel`.
    nonisolated(unsafe) static var current = TagCatalog()
    /// The names the ledgers read so far keep for tags (`tag_names` of every state and overview): the name of a tag
    /// the catalogue lacks (deleted or merged while a paper was out of the list, a folder from another Mac, a tags.json
    /// set aside), never its raw id. Ids are random per tag, so the papers' names never clash.
    nonisolated(unsafe) static var ledgerNames: [String: String] = [:]

    /// Takes the names a ledger keeps (before the reply that carries them is shown, so its views use them).
    static func learn(_ names: [String: String]?) {
        guard let names, !names.isEmpty else { return }
        for (id, n) in names where ledgerNames[id] != n { ledgerNames[id] = n }
    }

    func tag(_ id: String) -> WritingTag? { tags.first { $0.id == id } }
    func index(_ id: String) -> Int? { tags.firstIndex { $0.id == id } }

    /// The picker's tags: the visible ones, in order.
    var visible: [WritingTag] { tags.filter { !$0.hidden } }
    /// The advisor's visible tags in order: the engine's `tag_order` (the writing profile's picks consider only these).
    var order: [String] { visible.map(\.id) }

    /// A tag's name: the catalogue's, else the name a ledger kept for it (`tag_names`, a folder read on another Mac),
    /// else its id.
    func name(_ id: String, backup: [String: String] = [:]) -> String {
        if id == Self.untagged { return "Not tagged" }
        return tag(id)?.name ?? backup[id] ?? Self.ledgerNames[id] ?? id
    }

    func sign(_ id: String) -> String? { id == Self.untagged ? Self.untaggedSign : tag(id)?.sign }

    /// Ids in the catalogue's order, unknown ones last as they came (a tag of another Mac's catalogue).
    func sorted(_ ids: [String]) -> [String] {
        let known = tags.map(\.id).filter(ids.contains)
        return known + ids.filter { id in !known.contains(id) }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }

    /// The engine's limit for a name in `tag_names` (NAME_MAX), which counts Unicode code points, not characters.
    static let maxNameScalars = 64

    /// A name as kept: white space collapsed, at most 32 characters and at most 64 code points (an emoji sequence is
    /// one character of several code points: the engine refused such a name, and every request carrying it); nil when
    /// empty.
    static func clean(_ name: String) -> String? {
        let s = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var out = "", scalars = 0
        for ch in s.prefix(maxName) {
            scalars += ch.unicodeScalars.count
            if scalars > maxNameScalars { break }
            out.append(ch)
        }
        out = out.trimmingCharacters(in: .whitespaces)
        return out.isEmpty ? nil : out
    }

    /// The tag whose name is this one, case aside (hidden ones too).
    func named(_ name: String) -> WritingTag? {
        guard let n = Self.clean(name)?.lowercased() else { return nil }
        return tags.first { $0.name.lowercased() == n }
    }

    /// New Tag…: a new tag at the end of the list, group Other, or the tag already called so (case aside), shown
    /// again if hidden (`reused`). nil for an empty name.
    mutating func add(name: String, sign: String? = nil, today: String? = nil) -> (id: String, reused: Bool)? {
        guard let n = Self.clean(name) else { return nil }
        if let t = named(n) {
            if let i = index(t.id), tags[i].hidden { tags[i].hidden = false }
            return (t.id, true)
        }
        let id = Self.newID(existing: Set(tags.map(\.id)))
        tags.append(WritingTag(id: id, name: n, group: .other, sign: sign, created: today))
        return (id, false)
    }

    /// "u-" and 8 hex digits not used yet.
    static func newID(existing: Set<String>) -> String {
        while true {
            let hex = (0..<4).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
            let id = "u-" + hex
            if !existing.contains(id) { return id }
        }
    }

    /// Renames a tag; refused for an empty name or one another tag has (case aside).
    @discardableResult
    mutating func rename(_ id: String, to name: String) -> Bool {
        guard let n = Self.clean(name), let i = index(id) else { return false }
        if let other = named(n), other.id != id { return false }
        tags[i].name = n
        return true
    }

    mutating func setHidden(_ id: String, _ hidden: Bool) { if let i = index(id) { tags[i].hidden = hidden } }
    mutating func setGroup(_ id: String, _ g: TagGroup) { if let i = index(id) { tags[i].group = g } }
    mutating func setHint(_ id: String, _ s: String) { if let i = index(id) { tags[i].hint = s } }
    mutating func setFocus(_ id: String, _ s: String) { if let i = index(id) { tags[i].focus = s } }
    mutating func setSign(_ id: String, _ s: String?) { if let i = index(id) { tags[i].sign = s } }

    /// Reorders, as a list's drag does.
    mutating func move(from: IndexSet, to: Int) {
        let moving = from.sorted().map { tags[$0] }
        var rest = tags.enumerated().filter { !from.contains($0.offset) }.map(\.element)
        let at = to - from.filter { $0 < to }.count
        rest.insert(contentsOf: moving, at: max(0, min(at, rest.count)))
        tags = rest
    }

    /// Moves a tag one place up or down (the Settings list's buttons and its VoiceOver actions).
    mutating func step(_ id: String, by d: Int) {
        guard let i = index(id) else { return }
        let j = i + d
        guard j >= 0, j < tags.count else { return }
        tags.swapAt(i, j)
    }

    /// Deletes one of the advisor's own tags that no comment uses (`used`: the comments counted with it; a used tag is
    /// hidden instead, its history kept). Built-in tags are never deleted.
    @discardableResult
    mutating func delete(_ id: String, used: Int) -> Bool {
        guard used == 0, let i = index(id), !tags[i].builtIn else { return false }
        tags.remove(at: i)
        return true
    }

    /// Restore Default Names: the built-in tags' names, definitions and next-draft lines; the advisor's own tags and
    /// the order stay. A default name another tag has stays as it is (the review: two tags got one name); one that a
    /// tag restored here frees is taken on the next pass.
    mutating func restoreDefaultNames() {
        var renamed = true
        while renamed {
            renamed = false
            for d in Self.defaults {
                guard let i = index(d.id) else { continue }
                tags[i].hint = d.hint
                tags[i].focus = d.focus
                if tags[i].name != d.name && rename(d.id, to: d.name) { renamed = true }
            }
        }
    }

    /// The built-in tags Restore Default Names would change (it asks first, and only when there is one).
    var restorable: [String] {
        var c = self
        c.restoreDefaultNames()
        return tags.filter { c.tag($0.id) != $0 }.map(\.id)
    }

    /// Merge…: the comments of `from` take `into` (TAGS.md §3.3, without the engine's alias, deferred with the
    /// critique: the app rewrites each comment's list through `tag`, so the counts stay one a comment); `from` then
    /// leaves the catalogue unless it is built in, which is hidden. The list a comment then holds.
    static func merged(_ ids: [String], from: String, into: String) -> [String] {
        var out: [String] = []
        for id in ids {
            let t = id == from ? into : id
            if !out.contains(t) { out.append(t) }
        }
        return out
    }

    /// The names a ledger keeps for the advisor's own tags (`names`), for the ids sent.
    func names(for ids: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for id in ids { if let t = tag(id), !t.builtIn { out[id] = Self.clean(t.name) ?? t.id } }  // within the engine's limit
        return out
    }
}

/// tags.json: `{"schema": 1, "tags": [...]}`. No file is the default catalogue; it is written at the first change (a
/// temporary file and a replace, as papers.json). Real use: Application Support/Paperole/tags.json (Paperole
/// Dev's own folder in the dev app; AppVariant); a test run (--background, a fixture, --no-list, `swift test`): a folder
/// of its own, or `--tags <file>`, never Application Support.
struct TagStore {
    let url: URL

    static var standard: URL { AppVariant.current.dataFolder.appendingPathComponent("tags.json") }

    /// A test run's own: a temporary folder named by the process.
    static var temporary: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Paperole-tags-\(getpid())/tags.json")
    }

    /// Where this run keeps its tags: `--tags`, else Application Support only in the real app (not a test run,
    /// `LaunchOptions.isTestRun`: the critique's fix, a test run never writes the advisor's file).
    static func location(tags: String?, testRun: Bool) -> URL {
        if let tags { return URL(fileURLWithPath: tags) }
        return testRun ? temporary : standard
    }

    private func read() -> TagFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TagFile.self, from: data)
    }

    /// A tags.json that does not read (damaged, cut short) is never written over (the code audit: the next change
    /// replaced the advisor's tags with the defaults): it is moved aside as tags.json.bad (tags-2.json.bad …) and the
    /// defaults are used. False when such a file is still in the way (it could not be moved).
    @discardableResult
    func setAsideIfUnreadable() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path), read() == nil else { return true }
        var aside = url.appendingPathExtension("bad")
        var n = 2
        while fm.fileExists(atPath: aside.path) {
            aside = url.deletingLastPathComponent().appendingPathComponent("tags-\(n).json.bad")
            n += 1
        }
        do {
            try fm.moveItem(at: url, to: aside)
            NSLog("Paperole: tags.json could not be read; it was kept as %@", aside.lastPathComponent)
            return true
        } catch {
            NSLog("Paperole: tags.json could not be read nor moved aside: %@", error.localizedDescription)
            return false
        }
    }

    /// The catalogue: the file's, with any built-in tag it lacks added at the end; the defaults without a file (or
    /// with one that does not read, set aside first).
    func load() -> TagCatalog {
        guard let f = read() else {
            setAsideIfUnreadable()
            return TagCatalog()
        }
        var tags = f.tags.filter { TagCatalog.validID($0.id) }.reduce(into: [WritingTag]()) { out, t in
            if !out.contains(where: { $0.id == t.id }) { out.append(t) }
        }
        for d in TagCatalog.defaults where !tags.contains(where: { $0.id == d.id }) { tags.append(d) }
        return TagCatalog(tags: tags)
    }

    func save(_ c: TagCatalog) {
        guard setAsideIfUnreadable() else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try TagFile.data(c).write(to: url, options: .atomic)
        } catch {
            NSLog("Paperole: could not save the tags: %@", error.localizedDescription)
        }
    }
}

/// The app's tags: the catalogue (written at each change) and whether suggestions are on. Observed by the pickers,
/// Settings and the analytics; a change rebuilds the cards (their names and signs) and asks the overviews again.
@MainActor
final class TagModel: ObservableObject {
    @Published private(set) var catalog: TagCatalog
    /// Settings › Tags "Suggest tags as you write" (on by default; never saved by a test run).
    @Published var suggest: Bool {
        didSet {
            guard suggest != oldValue else { return }
            if remember { Prefs.set(suggest, Self.suggestKey) }
            changed?()
        }
    }
    static let suggestKey = "suggestTags"
    let store: TagStore
    private let remember: Bool
    /// Called after every change of the catalogue (the cards' names, the overviews' order).
    var changed: (() -> Void)?

    init(store: TagStore, remember: Bool) {
        self.store = store
        self.remember = remember
        catalog = store.load()
        suggest = (remember ? Prefs.bool(Self.suggestKey) : nil) ?? true
        TagCatalog.current = catalog
    }

    /// Changes the catalogue and writes it.
    func update(_ f: (inout TagCatalog) -> Void) {
        var c = catalog
        f(&c)
        guard c != catalog else { return }
        catalog = c
        TagCatalog.current = c
        store.save(c)
        changed?()
    }

    /// New Tag…: the tag (new, or the one already called so); nil for an empty name.
    func add(name: String, sign: String?) -> (id: String, reused: Bool)? {
        var out: (id: String, reused: Bool)?
        // `update` runs the change even when it changes nothing (a name already shown), so `out` is always its answer
        update { out = $0.add(name: name, sign: sign, today: HubText.format(Date(), "yyyy-MM-dd")) }
        return out
    }
}

// MARK: - Suggestions (TAGS.md §5.2): rules, on this Mac only

/// A suggested tag: a dashed chip that counts only once clicked, and why ("Suggested from “因果” in your note").
struct TagSuggestion: Equatable {
    var id: String
    var reason: String
}

enum TagSuggester {
    /// The words of each built-in tag (TAGS.md §5.2): English matched as whole words, case aside; Chinese terms of two
    /// characters or more as they are (a single character, as 表, also hits 表达).
    static let words: [(id: String, zh: [String], en: [String])] = [
        ("grammar", ["语法", "时态", "冠词", "单复数", "复数", "单数", "主谓", "介词", "病句", "标点", "逗号"],
         ["grammar", "grammatical", "tense", "article", "articles", "plural", "singular", "agreement", "preposition",
          "fragment", "run-on", "punctuation"]),
        ("wording", ["用词", "措辞", "搭配", "口语", "啰嗦", "冗余", "重复", "中式英语", "不地道", "换个词"],
         ["wording", "word choice", "phrasing", "collocation", "informal", "colloquial", "wordy", "redundant",
          "repetitive", "awkward", "chinglish"]),
        ("clarity", ["不清楚", "看不懂", "含糊", "模糊", "歧义", "指代", "指什么", "什么意思", "说清楚", "不明确", "定义一下"],
         ["unclear", "clarify", "ambiguous", "vague", "confusing", "define", "what do you mean", "hard to follow"]),
        ("logic", ["逻辑", "结论", "因果", "推不出", "太强", "夸大", "过度", "矛盾", "论证", "不成立"],
         ["claim", "claims", "overclaim", "overstated", "causal", "cause", "imply", "implies", "conclusion", "contradict",
          "justify", "unsupported", "speculative"]),
        ("evidence", ["引用", "文献", "出处", "证据", "对比", "比较", "基线", "显著", "统计", "前人"],
         ["cite", "citation", "citations", "source", "evidence", "compare", "comparison", "baseline", "prior work",
          "significance", "p-value", "statistics"]),
        ("structure", ["结构", "段落", "顺序", "挪到", "移到", "过渡", "衔接", "分段", "合并到", "章节"],
         ["structure", "paragraph", "reorder", "move this", "transition", "flow", "topic sentence", "organise",
          "organize", "outline"]),
        ("figures", ["图注", "表注", "坐标轴", "纵轴", "横轴", "图例", "表格", "子图", "配色", "分辨率"],
         ["figure", "fig.", "table", "axis", "axes", "caption", "legend", "panel", "colorbar", "resolution"]),
        ("math", ["公式", "符号", "记号", "下标", "上标", "变量", "单位", "量纲", "推导"],
         ["equation", "eq.", "notation", "symbol", "subscript", "superscript", "variable", "unit", "units", "formula"]),
        ("format", ["格式", "排版", "参考文献格式", "大小写", "空格", "字体", "斜体", "模板", "编号"],
         ["format", "formatting", "latex", "\\cite", "\\ref", "bibtex", "bibliography", "capitalise", "capitalize",
          "spacing", "italic", "hyphen", "template"]),
        ("praise", ["很好", "不错", "好多了", "清楚了", "写得好"], ["good", "nice", "well done", "great", "excellent", "clear now"]),
    ]

    static let figureEnvs: Set<String> = ["figure", "table", "wrapfigure", "wraptable", "subfigure", "subtable", "tabular",
                                          "longtable", "tabularx"]
    static let mathEnvs: Set<String> = ["equation", "align", "gather", "multline", "math", "eqnarray", "displaymath",
                                        "flalign", "alignat"]
    static let negations = ["不", "没", "但", "not", "but", "however", "no", "n't"]

    /// At most two suggestions for a comment: where it is first (an anchor in a figure or table, a box, display math,
    /// the references), its kind (a strikeout with a very short note: Wording), then its note's words, earliest in
    /// the note first. Never a tag already on it, a hidden one or one not in the catalogue.
    /// `quote` is the words it is on as the PDF prints them, "" for none (a box round a picture), nil when not known
    /// (a comment of another paper in Tag Comments…: the review, every box got Figures & tables there); `source` the
    /// words as the source has them, the only place a `$` means math (the PDF prints none for math, but "$5" as it is).
    static func suggest(note: String, kind: MarkKind? = nil, env: String? = nil, file: String? = nil, quote: String? = nil,
                        source: String? = nil, catalog: TagCatalog, on: [String] = []) -> [TagSuggestion] {
        var out: [TagSuggestion] = []
        func add(_ id: String, _ reason: String) {
            guard out.count < 2, !on.contains(id), !out.contains(where: { $0.id == id }),
                  let t = catalog.tag(id), !t.hidden else { return }
            out.append(TagSuggestion(id: id, reason: reason))
        }
        let e = env?.lowercased().replacingOccurrences(of: "*", with: "")
        if let e, figureEnvs.contains(e) {
            add("figures", e.contains("tab") ? "Suggested because it is on a table" : "Suggested because it is on a figure")
        } else if let e, mathEnvs.contains(e) {
            add("math", "Suggested because it is on an equation")
        } else if e == "thebibliography" || file?.lowercased().hasSuffix(".bbl") == true {
            add("format", "Suggested because it is in the references")
        } else if kind == .box, env == nil, quote == "" {
            add("figures", "Suggested because it is a box drawn on the page")
        } else if let s = source, s.replacingOccurrences(of: "\\$", with: "").contains("$") {  // \$ prints a dollar
            add("math", "Suggested because the words it is on hold math")
        }
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .strikeout, !text.isEmpty, short(text, cjk: 8, words: 6) {
            add("wording", "Suggested because it strikes words out with a short note")
        }
        for hit in hits(text) {
            if hit.id == "praise" && !praiseAllowed(text) { continue }
            add(hit.id, "Suggested from “\(hit.term)” in your note")
        }
        return out
    }

    /// A comment's suggestions from what the state says of it (the card, its picker, Tag Comments… on the paper
    /// shown): the PDF's words it is on ("" for none), and the source's only when it is anchored to its selection (a
    /// source line, or a range carried into a later round, may hold other words).
    static func suggest(for c: Comment, catalog: TagCatalog, on: [String] = []) -> [TagSuggestion] {
        suggest(note: c.note, kind: c.markKind, env: c.env, file: c.file, quote: c.text ?? "",
                source: c.method == "selection" ? c.newQuote : nil, catalog: catalog, on: on)
    }

    /// Every tag the note's words name, earliest first: (id, the words as written, where). Kept per note (the review:
    /// about 0.6 ms a card, for every untagged card at every state reply): the words are fixed, so a note's hits never
    /// change. On the main thread, as every caller; emptied past a few thousand notes.
    static func hits(_ note: String) -> [(id: String, term: String, at: Int)] {
        if let found = memo[note] { return found }
        let found = search(note)
        if memo.count >= 4096 { memo.removeAll() }
        memo[note] = found
        return found
    }

    nonisolated(unsafe) private static var memo: [String: [(id: String, term: String, at: Int)]] = [:]

    /// The English terms are searched in the note itself, case aside: a range found in `note.lowercased()` does not
    /// fit `note` once lower-casing has lengthened a character before it (İ → i + U+0307), and slicing with it trapped.
    private static func search(_ note: String) -> [(id: String, term: String, at: Int)] {
        var found: [(id: String, term: String, at: Int)] = []
        for w in words {
            var best: (String, Int)?
            for t in w.zh { if let r = note.range(of: t) { let at = note.distance(from: note.startIndex, to: r.lowerBound); if best == nil || at < best!.1 { best = (t, at) } } }
            for t in w.en { if let (r, at) = wholeWord(t, in: note) { if best == nil || at < best!.1 { best = (String(note[r]), at) } } }
            if let b = best { found.append((w.id, b.0, b.1)) }
        }
        return found.sorted { $0.at < $1.at }
    }

    /// The first place a term stands as whole words in a text, case aside: no letter or digit just before a term that
    /// starts with one, nor just after one that ends with one ("table" is not in "suitable"; "fig." matches "fig. 3").
    /// The range is the text's own, so it always slices the text it came from.
    static func wholeWord(_ term: String, in text: String) -> (Range<String.Index>, Int)? {
        var from = text.startIndex
        while from < text.endIndex, let r = text.range(of: term, options: .caseInsensitive, range: from..<text.endIndex) {
            // a LaTeX command is not a word: "cite" is not in "\cite"
            let beforeOK = r.lowerBound == text.startIndex || !(term.first?.isLetterOrDigit ?? false)
                || !(text[text.index(before: r.lowerBound)].isLetterOrDigit || text[text.index(before: r.lowerBound)] == "\\")
            let afterOK = r.upperBound == text.endIndex || !(term.last?.isLetterOrDigit ?? false)
                || !text[r.upperBound].isLetterOrDigit
            if beforeOK && afterOK { return (r, text.distance(from: text.startIndex, to: r.lowerBound)) }
            from = r.upperBound
        }
        return nil
    }

    /// Well done only for a short note without a negation (TAGS.md §5.2): "很好，但…" is not praise. Its own words are
    /// taken out first, so 不错 is not read as 不.
    static func praiseAllowed(_ note: String) -> Bool {
        guard short(note, cjk: 12, words: 6) else { return false }
        var rest = note.lowercased()
        for t in words.first(where: { $0.id == "praise" })!.zh + ["well done"] { rest = rest.replacingOccurrences(of: t, with: " ") }
        for n in negations {
            if n.first?.isASCII == true {
                if n == "n't" ? rest.contains(n) : wholeWord(n, in: rest) != nil { return false }
            } else if rest.contains(n) { return false }
        }
        return true
    }

    /// At most `cjk` CJK characters and at most `words` Latin words.
    static func short(_ s: String, cjk: Int, words: Int) -> Bool {
        let c = s.unicodeScalars.filter { (0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) }.count
        let w = s.split { !$0.isLetter || ($0.unicodeScalars.first.map { $0.value >= 0x3000 } ?? false) }.count
        return c <= cjk && w <= words
    }
}

private extension Character {
    var isLetterOrDigit: Bool { isLetter || isNumber }
}
