import AppKit
import XCTest
@testable import Paperole

/// Tags as a way to organise the comments (UX.md §27): the list's tag filter and its menu, the arrangement by status,
/// tag or section, the held card, J/K and the next card to check; and one tag across a student's papers. Synthetic
/// fixtures only.
@MainActor
final class TagOrganizerTests: XCTestCase {
    private func card(_ id: String, tags: [String] = [], _ extra: [String: Any] = [:]) throws -> CardModel {
        var e = extra
        e["id"] = id
        e["tags"] = tags
        return CardModel(try makeComment(e), round: 2, pdfs: [:], textX: [], showChanges: true, catalog: TagCatalog())
    }

    /// Carried in document order, then new, as AppModel.ordered lists them.
    private func cards() throws -> [CardModel] {
        [try card("R1-01", tags: ["grammar"]), try card("R1-02", tags: ["clarity"], ["verdict": "verified"]),
         try card("R1-03", tags: ["logic", "grammar"], ["verdict": "reopened"]), try card("R1-04", ["anchor_state": "orphan"]),
         try card("R1-05", tags: ["clarity"], ["verdict": "wontfix"]), try card("R1-06", tags: ["clarity", "grammar"]),
         try card("R2-01", tags: ["grammar"], ["carried": false, "created_round": 2, "anchor_state": "new"])]
    }

    func testTheFilterKeepsTheStatusGroups() throws {
        let g = CardGroups(try cards(), filter: "grammar")
        XCTAssertEqual(g.toCheck.map(\.id), ["R1-01", "R1-04", "R1-06"], "the status groups are every card")
        XCTAssertEqual(g.shown.map { $0.cards.map(\.id) }, [["R1-01", "R1-06"], ["R1-03", "R2-01"], []])
        XCTAssertEqual(g.listed(showClosed: true, showStudent: false).map(\.id), ["R1-01", "R1-06"], "a folded group is skipped")
        let untagged = CardGroups(try cards(), filter: TagCatalog.untagged)
        XCTAssertEqual(untagged.listed(showClosed: true).map(\.id), ["R1-04"])
        XCTAssertNil(untagged.key(of: "R1-01"))
        XCTAssertEqual(untagged.key(of: "R1-04"), .status(.toCheck))
    }

    /// The selected card is listed whatever the filter (a mark clicked in the PDF), in the group it is shown in.
    func testTheSelectedCardIsListedWhateverTheFilter() throws {
        let g = CardGroups(try cards(), held: ("R1-05", .closed), filter: "grammar")
        XCTAssertEqual(g.shown[2].cards.map(\.id), ["R1-05"])
        let byTag = CardGroups(try cards(), held: ("R1-04", .toCheck), grouping: .tag, filter: "grammar")
        XCTAssertEqual(byTag.shown.map(\.key), [.tag("grammar"), .tag(TagCatalog.untagged)])
    }

    /// By tag: each card once, under its first tag in the catalogue's order (the filter's tag when it has it); the
    /// groups in the catalogue's order, Not tagged last; the selected card stays in the group it was shown in.
    func testGroupsByTag() throws {
        let g = CardGroups(try cards(), grouping: .tag)
        XCTAssertEqual(g.shown.map(\.key), [.tag("grammar"), .tag("clarity"), .tag("logic"), .tag(TagCatalog.untagged)].filter { k in
            g.shown.contains { $0.key == k }
        })
        XCTAssertEqual(g.shown.map(\.title), ["Grammar", "Clarity", "Not tagged"])
        XCTAssertEqual(g.shown.map { $0.cards.map(\.id) }, [["R1-01", "R1-03", "R1-06", "R2-01"], ["R1-02", "R1-05"], ["R1-04"]])
        XCTAssertEqual(Set(g.shown.flatMap(\.cards).map(\.id)).count, 7, "each card once")
        XCTAssertEqual(g.shown.first?.glyph, .tag("textformat.abc", "Grammar"))
        // filtered on Clarity: R1-06 (Grammar first) is listed under Clarity
        let f = CardGroups(try cards(), grouping: .tag, filter: "clarity")
        XCTAssertEqual(f.shown.map(\.key), [.tag("clarity")])
        XCTAssertEqual(f.shown[0].cards.map(\.id), ["R1-02", "R1-05", "R1-06"])
        // retagged while selected: it stays where it was shown
        var moved = try cards()
        moved[0] = try card("R1-01", tags: ["logic"])
        let held = CardGroups(moved, held: ("R1-01", .toCheck), place: .tag("grammar"), grouping: .tag)
        XCTAssertEqual(held.key(of: "R1-01"), .tag("grammar"))
        XCTAssertEqual(CardGroups(moved, grouping: .tag).key(of: "R1-01"), .tag("logic"))
        XCTAssertEqual(g.listed(showClosed: false, showStudent: false).count, 7, "nothing folds by tag")
    }

    func testGroupsBySection() throws {
        var s = ListSections(found: true)
        s.titles = [-1: .init(number: nil, name: "Title and abstract"), 2: .init(number: "1", name: "Introduction"),
                    10: .init(number: "2", name: "Method")]
        s.of = ["R1-01": 10, "R1-02": 2, "R1-03": 10, "R1-05": -1, "R1-06": 2, "R2-01": 2]
        s.rank = ["R2-01": 0, "R1-06": 1, "R1-02": 2]  // the others after them, as they came
        let g = CardGroups(try cards(), grouping: .section, sections: s)
        XCTAssertEqual(g.shown.map(\.key), [.section(-1), .section(2), .section(10), .section(nil)])
        XCTAssertEqual(g.shown.map(\.title), ["Title and abstract", "Introduction", "Method", "No section"])
        XCTAssertEqual(g.shown[1].cards.map(\.id), ["R2-01", "R1-06", "R1-02"], "in the paper's order")
        XCTAssertEqual(g.shown[1].glyph, .number("1"))
        XCTAssertEqual(g.shown[3].cards.map(\.id), ["R1-04"])
        XCTAssertEqual(g.shown[3].sub, "not placed in this round")
        XCTAssertEqual(CardGroups(try cards(), grouping: .section).shown.map(\.sub), ["the sections are not found yet"])
    }

    /// After an answer: by tag or section the next card to check in the list's order (wrapping; never a closed one or
    /// the card answered); by status with a filter only the To check cards it keeps.
    func testNextToCheck() throws {
        let g = CardGroups(try cards(), held: ("R1-01", .toCheck), grouping: .tag)
        XCTAssertEqual(g.nextToCheck(after: "R1-01"), "R1-06", "R1-03 is the student's")
        XCTAssertEqual(g.nextToCheck(after: "R1-06"), "R1-04")
        XCTAssertEqual(g.nextToCheck(after: "R1-04"), "R1-01", "wraps")
        let f = CardGroups(try cards(), held: ("R1-01", .toCheck), filter: "grammar")
        XCTAssertEqual(f.nextToCheck(after: "R1-01"), "R1-06")
        XCTAssertEqual(f.nextToCheck(after: "R1-06"), "R1-01")
        XCTAssertEqual(CardGroups(try cards(), filter: "clarity").nextToCheck(after: "R1-02"), "R1-06")
    }

    /// The menu's Show section: the round's tags in the advisor's order with their counts, then Not tagged.
    func testTheMenuOptions() throws {
        let options = ListFilter.options(try cards(), catalog: TagCatalog(), filter: nil)
        XCTAssertEqual(options.map(\.id), ["grammar", "clarity", "logic", TagCatalog.untagged], "the catalogue's order, never by count")
        XCTAssertEqual(options.map(\.count), [4, 3, 1, 1], "a comment with two tags counts in each")
        XCTAssertEqual(options.last?.name, "Not tagged")
        XCTAssertEqual(options.last?.sign, TagCatalog.untaggedSign)
        XCTAssertTrue(ListFilter.options([try card("R1-01")], catalog: TagCatalog(), filter: nil).isEmpty, "nothing tagged: no Show section")
        let kept = ListFilter.options(try cards(), catalog: TagCatalog(), filter: "math")
        XCTAssertEqual(kept.first { $0.id == "math" }?.count, 0, "the tag shown alone stays listed")
        XCTAssertEqual(ListFilter.captions(kept: 1, total: 16), ["1 of 16 comments", "1 of 16"])
        XCTAssertEqual(ListFilter.captions(kept: 1, total: 1), ["1 of 1 comment", "1 of 1"])
    }

    /// The line while a tag is shown alone: nothing overlaps at any panel width (the advisor's screenshot of 2026-10-21:
    /// the caption ran over the chips and the list's first header), with long and CJK names too; the count gives way
    /// first, then the name is cut, Show All and the token's sign and ⌄ always whole.
    func testTheLineFits() throws {
        typealias M = ListBarMetrics
        let names = ["Grammar", "Math & notation", "Not tagged", "Statistical reporting and inference quality",
                     "数学符号与公式", "数学符号、公式与单位的规范写法和排版"]
        for w in stride(from: CGFloat(WindowLayout.panel), through: 560, by: 10) {
            for name in names {
                for (k, t) in [(1, 16), (12, 160), (148, 1200)] {
                    let f = M.fit(width: w, name: name, captions: ListFilter.captions(kept: k, total: t))
                    XCTAssertLessThanOrEqual(M.used(f), w - 2 * M.side, "\(name) at \(w) pt")
                    XCTAssertLessThanOrEqual(f.name, M.width(name, M.medium), "never wider than it needs")
                    if f.name < M.width(name, M.medium) && f.caption != nil { XCTAssertGreaterThanOrEqual(f.name, M.minName) }
                }
            }
        }
        // the panel's widths of the screenshots
        let all = ListFilter.captions(kept: 1, total: 16)
        XCTAssertEqual(M.fit(width: 400, name: "Math & notation", captions: all), .init(caption: all[0], name: M.width("Math & notation", M.medium)))
        XCTAssertEqual(M.fit(width: 520, name: "Math & notation", captions: all).caption, all[0])
        let narrow = M.fit(width: 330, name: "Math & notation", captions: all)
        XCTAssertNotNil(narrow.caption)
        XCTAssertEqual(narrow.name, M.width("Math & notation", M.medium), "the name whole at 330 pt")
        let long = M.fit(width: 330, name: "Statistical reporting and inference quality", captions: all)
        XCTAssertEqual(long.caption, all[1], "the short count, then the name cut")
        XCTAssertGreaterThanOrEqual(long.name, M.minName)
        let cjk = M.fit(width: 330, name: "数学符号、公式与单位的规范写法和排版", captions: all)
        XCTAssertLessThan(cjk.name, M.width("数学符号、公式与单位的规范写法和排版", M.medium))
        XCTAssertEqual(M.fit(width: 0, name: "Grammar", captions: all), .init(caption: all[0], name: M.width("Grammar", M.medium)),
                       "before the width is known")
        XCTAssertGreaterThan(M.chevron, 0)
    }

    /// The sections from a round's paragraphs: the top level only, the number apart from the name, the title and
    /// abstract before the first heading; the paper's order by page, column and height.
    func testListSectionsFromTheReading() throws {
        let reading = ReadingInfo(read: [], count: 0, unread: 0, paragraphs: [],
                                  headings: [Heading(block: 2, level: 1, title: "1 Introduction"), Heading(block: 5, level: 2, title: "1.1 Aims"),
                                             Heading(block: 9, level: 1, title: "2 Method"), Heading(block: 20, level: 1, title: "References")])
        let cs = [try makeComment(["id": "a", "paragraph": 1, "page": 0, "rects": [[72, 300, 200, 310]]]),
                  try makeComment(["id": "b", "paragraph": 6, "page": 0, "rects": [[320, 100, 500, 110]]]),
                  try makeComment(["id": "c", "paragraph": 12, "page": 0, "rects": [[72, 500, 200, 510]]]),
                  try makeComment(["id": "d", "paragraph": NSNull(), "page": NSNull(), "rects": []])]
        let s = ListSections.make(reading, comments: cs, columns: [[306]])
        XCTAssertEqual(s.of, ["a": -1, "b": 2, "c": 9])
        XCTAssertEqual(s.titles[9], .init(number: "2", name: "Method"))
        XCTAssertEqual(s.titles[20], .init(number: nil, name: "References"))
        XCTAssertNil(s.titles[5], "a subsection is in its section")
        XCTAssertEqual(s.rank.sorted { $0.value < $1.value }.map(\.key), ["a", "c", "b", "d"], "the left column first")
        XCTAssertFalse(ListSections.make(nil, comments: cs).found)
    }

    /// One tag across a student's papers: by paper, each comment once with where it was written and how it ended; Not
    /// tagged as its own list.
    func testOneTagAcrossAStudentsPapers() throws {
        let reply = try TagDataTests.reply()
        let data = Dictionary(reply.papers.compactMap { p in p.overview.map { (p.path, $0) } }, uniquingKeysWith: { a, _ in a })
        let papers = [("/synthetic/shrimp", "Shrimp snap detector"), ("/synthetic/reef", "Reef choruses at dawn and dusk"),
                      ("/synthetic/kelp", "Kelp holdfast survey")]
        let logic = StudentTagList.make("logic", papers: papers.map { (path: $0.0, title: $0.1) }, data: data, catalog: TagCatalog())
        XCTAssertEqual(logic.title, "Logic & claims")
        XCTAssertEqual(logic.papers.map(\.title), papers.map(\.1))
        XCTAssertEqual(logic.papers.map { $0.lines.map(\.id) }, [["R1-04", "R1-08"], ["R1-05", "R1-07"], ["R1-03"]])
        XCTAssertEqual(logic.count, 5)
        XCTAssertEqual(logic.meta, "5 comments in 3 papers, each counted once · 2 open")
        XCTAssertTrue(logic.papers[1].lines[0].status.contains("to check"), logic.papers[1].lines[0].status)
        XCTAssertEqual(logic.papers[1].lines[0].round, 4, "Review opens in the round it was last shown in")
        let none = StudentTagList.make(TagCatalog.untagged, papers: papers.map { (path: $0.0, title: $0.1) }, data: data, catalog: TagCatalog())
        XCTAssertEqual(none.title, "Not tagged")
        XCTAssertEqual(none.papers.map { $0.lines.map(\.id) }, [["R1-04", "R2-03"]])
        XCTAssertEqual(none.meta, "2 comments, each counted once · 1 open")
        XCTAssertTrue(StudentTagList.make("format", papers: papers.map { (path: $0.0, title: $0.1) }, data: data, catalog: TagCatalog()).papers.isEmpty)
    }
}

/// The model: the filter and the arrangement on the real list (a fixture state with tags and paragraphs), J/K, a card
/// the filter hides selected from the PDF, a card retagged while selected, and the line's chips.
@MainActor
final class TagOrganizerModelTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-tagorg-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// state-reading.json (synthetic) with tags on its comments.
    private func makeModel() throws -> AppModel {
        _ = NSApplication.shared
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: StepTests.fixtures
            .appendingPathComponent("state-reading.json"))) as? [String: Any])
        var comments = try XCTUnwrap(json["comments"] as? [[String: Any]])
        let tags: [String: [String]] = ["R1-01": ["grammar"], "R2-02": ["clarity"], "R1-06": ["grammar", "clarity"],
                                        "R1-02": ["logic"], "R1-05": ["grammar"], "R1-09": ["clarity"]]
        for i in comments.indices { comments[i]["tags"] = tags[comments[i]["id"] as? String ?? ""] ?? [] }
        json["comments"] = comments
        let url = dir.appendingPathComponent("state.json")
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        var o = LaunchOptions()
        o.fixture = url.path
        o.drafts = dir.appendingPathComponent("drafts").path
        o.tags = dir.appendingPathComponent("tags.json").path
        return AppModel(options: o)
    }

    func testFilterAndKeys() throws {
        let m = try makeModel()
        XCTAssertTrue(m.listBar.shown)
        XCTAssertEqual(m.listBar.options.map(\.id), ["grammar", "clarity", "logic", TagCatalog.untagged])
        XCTAssertEqual(m.listBar.options.map(\.count), [3, 3, 1, 7])
        XCTAssertEqual(m.listBar.title, "By status")
        XCTAssertNil(m.listBar.caption)
        m.listBar.show("grammar")
        XCTAssertEqual(m.panel.filter, "grammar")
        XCTAssertEqual(m.listBar.title, "Grammar", "the menu's title says what is shown")
        XCTAssertEqual(m.listBar.caption, "3 of 13 comments")
        XCTAssertEqual(Set(m.panel.listed.map(\.id)), ["R1-06", "R1-05"], "R1-01 is closed, its group folded")
        var seen: [String] = []
        for _ in 0..<5 { m.move(1); if let id = m.panel.expanded { seen.append(id) } }
        XCTAssertTrue(Set(seen).isSubset(of: ["R1-06", "R1-05"]), "J and K go through what is listed")
        // a mark clicked in the PDF that the filter hides: listed while selected, gone once the selection leaves
        m.markClicked("R1-09")
        XCTAssertEqual(m.panel.expanded, "R1-09")
        XCTAssertNotNil(m.panel.groups.key(of: "R1-09"))
        m.markClicked("R1-05")
        XCTAssertNil(m.panel.groups.key(of: "R1-09"))
        // a filter that hides the selected card: no card selected (what is not listed takes no keys)
        m.setTagFilter("logic")
        XCTAssertNil(m.panel.expanded)
        XCTAssertEqual(m.panel.listed.map(\.id), [], "R1-02 is the student's: folded")
        m.listBar.show(nil)
        XCTAssertNil(m.panel.filter, "Show All")
        XCTAssertEqual(m.listBar.title, "By status")
        XCTAssertEqual(m.panel.listed.map(\.id), m.panel.groups.toCheck.map(\.id))
    }

    /// A card that loses the filter's tag while selected stays listed until the selection leaves it; another round
    /// keeps the filter while some of its comments have the tag.
    func testTheFilterAndChangingTags() throws {
        let m = try makeModel()
        m.setTagFilter("grammar")
        m.select(.comment("R1-05"), scroll: nil)
        m.setTags("R1-05", [])
        XCTAssertNotNil(m.panel.groups.key(of: "R1-05"), "held while selected")
        XCTAssertEqual(m.listBar.kept, 2)
        m.select(.comment("R1-06"), scroll: nil)
        XCTAssertNil(m.panel.groups.key(of: "R1-05"))
        // another round: the filter stays while a comment has the tag, else the whole list again
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: StepTests.fixtures
            .appendingPathComponent("state-reading.json"))) as? [String: Any])
        var round = try XCTUnwrap(json["round"] as? [String: Any])
        round["n"] = 3
        json["round"] = round
        var comments = try XCTUnwrap(json["comments"] as? [[String: Any]])
        for i in comments.indices { comments[i]["tags"] = comments[i]["id"] as? String == "R1-09" ? ["grammar"] : [] }
        json["comments"] = comments
        m.apply(try EngineState.decode(JSONSerialization.data(withJSONObject: json)))
        XCTAssertEqual(m.panel.filter, "grammar")
        round["n"] = 4
        json["round"] = round
        for i in comments.indices { comments[i]["tags"] = [] }
        json["comments"] = comments
        m.apply(try EngineState.decode(JSONSerialization.data(withJSONObject: json)))
        XCTAssertNil(m.panel.filter)
        XCTAssertTrue(m.listBar.options.isEmpty, "nothing tagged: the menu arranges only")
        XCTAssertEqual(ListMenu.make(m.listBar).items.map(\.title), ["Arrange By", "Status", "Tag", "Section"])
        XCTAssertTrue(m.listBar.shown)
    }

    func testArrangements() throws {
        let m = try makeModel()
        let before = UserDefaults.standard.object(forKey: ListGrouping.key) as? String
        m.listBar.group(.section)
        XCTAssertEqual(m.panel.grouping, .section)
        XCTAssertEqual(m.panel.groups.shown.map(\.title), ["Introduction", "Related Work", "Method", "Evaluation", "No section"])
        XCTAssertEqual(m.panel.groups.shown[0].glyph, .number("1"))
        XCTAssertEqual(m.panel.groups.shown.last?.title, "No section")
        XCTAssertEqual(m.panel.listed.count, m.panel.cards.count, "nothing folds by section")
        m.listBar.group(.tag)
        XCTAssertEqual(m.panel.groups.shown.map(\.title), ["Grammar", "Clarity", "Logic & claims", "Not tagged"])
        // a card retagged while selected stays where it was shown, and moves once the selection leaves it
        m.select(.comment("R1-05"), scroll: nil)
        XCTAssertEqual(m.panel.groups.key(of: "R1-05"), .tag("grammar"))
        m.setTags("R1-05", ["structure"])
        XCTAssertEqual(m.panel.groups.key(of: "R1-05"), .tag("grammar"), "held while selected")
        XCTAssertTrue(m.listBar.options.contains { $0.id == "structure" }, "the menu follows the tags at once")
        m.select(.comment("R1-09"), scroll: nil)
        XCTAssertEqual(m.panel.groups.key(of: "R1-05"), .tag("structure"))
        // J and K in the list's order; the first card of each group follows the last of the one above
        let order = m.panel.listed.map(\.id)
        XCTAssertEqual(order, m.panel.groups.shown.flatMap(\.cards).map(\.id))
        m.listBar.group(.status)
        XCTAssertEqual(m.panel.groups.shown.map(\.key), [.status(.toCheck), .status(.forStudent), .status(.closed)])
        XCTAssertEqual(UserDefaults.standard.object(forKey: ListGrouping.key) as? String, before, "a test run never saves it")
    }

    /// The list's menu, as its button opens it: Arrange By and Show, each with its choice checked, the tags in the
    /// advisor's order with their counts as the menu's badges and their signs; its items do what the line did.
    func testTheMenu() throws {
        let m = try makeModel()
        var menu = ListMenu.make(m.listBar)
        XCTAssertEqual(menu.items.filter(\.isSectionHeader).map(\.title), ["Arrange By", "Show"])
        let picks = menu.items.filter { $0.action != nil }
        XCTAssertEqual(picks.map(\.title), ["Status", "Tag", "Section", "All Comments", "Grammar", "Clarity", "Logic & claims", "Not tagged"])
        XCTAssertEqual(picks.filter { $0.state == .on }.map(\.title), ["Status", "All Comments"])
        XCTAssertEqual(picks.compactMap { $0.badge?.itemCount }, [3, 3, 1, 7])
        XCTAssertNotNil(picks[4].image, "the tag's sign")
        XCTAssertNotNil(picks[7].image, "Not tagged's sign")
        XCTAssertFalse(picks[4].toolTip?.isEmpty ?? true, "the tag's definition")
        // Show: one tag's comments; the menu then says so, and its title is the tag
        XCTAssertTrue(ListMenu.perform("Logic & claims", in: menu))
        XCTAssertEqual(m.panel.filter, "logic")
        XCTAssertEqual(m.listBar.title, "Logic & claims")
        menu = ListMenu.make(m.listBar)
        XCTAssertEqual(menu.items.filter { $0.state == .on }.map(\.title), ["Status", "Logic & claims"])
        // Arrange By with the filter kept
        XCTAssertTrue(ListMenu.perform("Tag", in: menu))
        XCTAssertEqual(m.panel.grouping, .tag)
        XCTAssertEqual(m.panel.filter, "logic")
        XCTAssertEqual(m.panel.groups.shown.map(\.key), [.tag("logic")])
        XCTAssertTrue(ListMenu.perform("All Comments", in: ListMenu.make(m.listBar)))
        XCTAssertNil(m.panel.filter)
        XCTAssertEqual(m.listBar.title, "By tag")
        XCTAssertTrue(ListMenu.perform("Not tagged", in: ListMenu.make(m.listBar)))
        XCTAssertEqual(m.panel.filter, TagCatalog.untagged)
        XCTAssertEqual(m.listBar.caption, "7 of 13 comments")
        m.listBar.group(.status)
        XCTAssertFalse(ListMenu.perform("Arrange By", in: ListMenu.make(m.listBar)), "a header is not an item")
        let d = ListMenu.describe(ListMenu.make(m.listBar))
        XCTAssertEqual(d.first as? String, "# Arrange By")
        XCTAssertTrue(d.contains { ($0 as? String) == "—" })
    }

    /// The list's rows: by tag a plain header a group with its count and the tag's sign, every card as a row; a
    /// filter with a group it keeps nothing of lists no header for it.
    func testTheRows() throws {
        let m = try makeModel()
        let list = CommentListController(panel: m.panel, actions: m.actions, edit: m.edit)
        m.listBar.group(.tag)
        let headers = list.rows().compactMap { r -> String? in
            if case .header(let t, _, let n, _) = r { return "\(t) \(n ?? -1)" } else { return nil }
        }
        XCTAssertEqual(headers, ["Grammar 3", "Clarity 2", "Logic & claims 1", "Not tagged 7"])
        XCTAssertFalse(list.rows().contains { if case .item(.line) = $0 { return true } else { return false } }, "no 30 pt lines")
        m.listBar.group(.status)
        m.setTagFilter("grammar")
        let rows = list.rows()
        XCTAssertFalse(rows.contains { if case .header("For the student", _, _, _) = $0 { return true } else { return false } })
        XCTAssertFalse(rows.contains { if case .hint = $0 { return true } else { return false } }, "no commenting hint under a filter")
    }
}
