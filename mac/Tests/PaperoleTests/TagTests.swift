import AppKit
import SwiftUI
import XCTest
@testable import Paperole

/// The writing tags, Reopen, the key page and the last place (UX.md §24; design/tags/TAGS.md with the critique's
/// fixes). Synthetic data only: the catalogue's rules, the store's place in a test run, the suggestions, the picker's
/// working set and its chips' widths, the engine's new keys decoded, the cards' tags and Reopen, the paper page's
/// Topics and following a tag, the Student page's words, the hierarchy's request, and the last place.
@MainActor
final class TagCatalogTests: XCTestCase {
    func testTheDefaultTags() {
        let c = TagCatalog()
        XCTAssertEqual(c.tags.map(\.id), ["grammar", "wording", "clarity", "logic", "evidence", "structure", "figures", "math",
                                          "format", "praise"])
        XCTAssertEqual(c.tags.map(\.group), [.language, .language, .thinking, .thinking, .thinking, .thinking, .presentation,
                                             .presentation, .presentation, .praise])
        XCTAssertNotEqual(c.tag("clarity")?.sign, "eye", "the critique: an eye means hide in Settings and seen in rows")
        // every sign means one tag: the built-in ones, the Not tagged row's and the new tags' palette
        let signs = c.tags.compactMap(\.sign) + [TagCatalog.untaggedSign] + TagCatalog.palette
        XCTAssertEqual(Set(signs).count, signs.count, "a sign used twice")
        for s in signs { XCTAssertNotNil(NSImage(systemSymbolName: s, accessibilityDescription: nil), s + " is not an SF Symbol on macOS 14") }
        for t in c.tags where t.id != "praise" { XCTAssertFalse(t.focus.isEmpty, t.id + " has a next-draft line") }
        XCTAssertTrue(c.tags.allSatisfy { TagCatalog.validID($0.id) && !$0.hint.isEmpty })
        XCTAssertEqual(c.order.count, 10)
        XCTAssertEqual(c.name(TagCatalog.untagged), "Not tagged")
    }

    func testAddingRenamingHidingAndDeleting() throws {
        var c = TagCatalog()
        let (id, reused) = try XCTUnwrap(c.add(name: "  Hedging   words ", sign: "leaf", today: "2026-10-20"))
        XCTAssertFalse(reused)
        XCTAssertTrue(id.hasPrefix("u-") && id.count == 10 && TagCatalog.validID(id))
        XCTAssertEqual(c.tags.last?.name, "Hedging words", "white space collapsed, at the end")
        XCTAssertEqual(c.tags.last?.group, .other)
        XCTAssertEqual(c.tags.last?.created, "2026-10-20")
        // a name a tag has (case aside): that tag, shown again if hidden
        c.setHidden("wording", true)
        XCTAssertEqual(c.add(name: "WORDING", sign: nil)?.id, "wording")
        XCTAssertEqual(c.add(name: "wording", sign: nil)?.reused, true)
        XCTAssertFalse(c.tag("wording")!.hidden)
        XCTAssertNil(c.add(name: "   ", sign: nil))
        XCTAssertEqual(c.add(name: String(repeating: "x", count: 50), sign: nil).flatMap { c.tag($0.id)?.name.count }, 32)
        XCTAssertFalse(c.rename("clarity", to: "grammar"), "another tag's name")
        XCTAssertTrue(c.rename("clarity", to: "Clear writing"))
        XCTAssertEqual(c.name("clarity"), "Clear writing")
        // order: a drag and a step
        c.move(from: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(Array(c.tags.map(\.id).prefix(3)), ["wording", "clarity", "grammar"])
        c.step("grammar", by: -1)
        XCTAssertEqual(Array(c.tags.map(\.id).prefix(3)), ["wording", "grammar", "clarity"])
        // hidden: not in the picker's order, still named
        c.setHidden("math", true)
        XCTAssertFalse(c.order.contains("math"))
        XCTAssertEqual(c.name("math"), "Math & notation")
        // delete: only one of the advisor's own that no comment uses
        XCTAssertFalse(c.delete("grammar", used: 0))
        XCTAssertFalse(c.delete(id, used: 2))
        XCTAssertTrue(c.delete(id, used: 0))
        XCTAssertNil(c.tag(id))
        // Restore Default Names: the built-in names; order and the advisor's tags stay
        c.restoreDefaultNames()
        XCTAssertEqual(c.name("clarity"), "Clarity")
        XCTAssertEqual(Array(c.tags.map(\.id).prefix(3)), ["wording", "grammar", "clarity"])
        XCTAssertTrue(c.tag("math")!.hidden)
    }

    func testMergingAndNames() throws {
        XCTAssertEqual(TagCatalog.merged(["u-1", "clarity", "logic"], from: "u-1", into: "clarity"), ["clarity", "logic"],
                       "a comment with both keeps one")
        XCTAssertEqual(TagCatalog.merged(["logic"], from: "u-1", into: "clarity"), ["logic"])
        var c = TagCatalog()
        let id = try XCTUnwrap(c.add(name: "Hedging", sign: nil)).id
        XCTAssertEqual(c.names(for: ["logic", id]), [id: "Hedging"], "only the advisor's own go to the ledger")
        XCTAssertEqual(c.sorted(["format", "zz-other", "grammar", "format"]), ["grammar", "format", "zz-other"])
        XCTAssertEqual(c.name("zz-other", backup: ["zz-other": "From another Mac"]), "From another Mac")
    }

    func testTheStoreAndWhereATestRunKeepsIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-tags-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("tags.json")
        let store = TagStore(url: url)
        XCTAssertEqual(store.load(), TagCatalog(), "no file: the defaults")
        let m = TagModel(store: store, remember: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "nothing written before a change")
        m.update { $0.setHidden("format", true) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(store.load().tag("format")!.hidden)
        // a file missing a built-in tag, with a bad id and a duplicate: the tag added, the others dropped
        let json = #"{"schema": 1, "tags": [{"id": "logic", "name": "Claims", "group": "thinking"}, {"id": "Bad Id", "name": "x"}, {"id": "logic", "name": "again"}]}"#
        try Data(json.utf8).write(to: url)
        let c = store.load()
        XCTAssertEqual(c.tags.first?.name, "Claims")
        XCTAssertEqual(c.tags.count, 10)
        XCTAssertNil(c.tag("Bad Id"))
        // a test run never writes the advisor's file (the critique's fix): --tags, else a folder of its own
        XCTAssertEqual(TagStore.location(tags: url.path, testRun: false), url)
        XCTAssertEqual(TagStore.location(tags: url.path, testRun: true), url)
        XCTAssertEqual(TagStore.location(tags: nil, testRun: true), TagStore.temporary)
        XCTAssertEqual(TagStore.location(tags: nil, testRun: false), TagStore.standard, "the real app's")
        XCTAssertFalse(TagStore.temporary.path.contains("Application Support"))
        // one rule for a test run (the review, A5a-11: a --no-list run without --background wrote Dev's tags.json)
        for args in [["--background"], ["--no-list"], ["--fixture", "s.json"], []] {
            XCTAssertTrue(LaunchOptions.parse(["Paperole"] + args).isTestRun, "\(args), and a unit test in any case")
        }
        XCTAssertTrue(LaunchOptions.isTestRun, "this process: a unit test")
    }

    /// The store writes and reads TagFile, the shape Export Tags… and Import Tags… use (the review: two copies of it).
    /// As before, the store reads a file of another schema; Import Tags… does not.
    func testTheStoreKeepsTheTagFileShape() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-tags-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("tags.json")
        var c = TagCatalog()
        _ = c.add(name: "Hedging", sign: "leaf")
        TagStore(url: url).save(c)
        XCTAssertEqual(try TagFile.read(url), c.tags)
        try Data(#"{"schema": 2, "tags": [{"id": "logic", "name": "Claims", "group": "thinking"}]}"#.utf8).write(to: url)
        XCTAssertEqual(TagStore(url: url).load().name("logic"), "Claims")
        XCTAssertThrowsError(try TagFile.read(url))
    }

    /// New Tag… with a name a shown tag has: that tag, and nothing written (the review: a fallback for it was dead).
    func testNewTagWithANameAlreadyShown() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-tags-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("tags.json")
        let m = TagModel(store: TagStore(url: url), remember: false)
        let r = try XCTUnwrap(m.add(name: "GRAMMAR", sign: nil))
        XCTAssertEqual(r.id, "grammar")
        XCTAssertTrue(r.reused)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "no change written")
        XCTAssertNil(m.add(name: "  ", sign: nil))
    }

    /// The code audit: a tags.json that does not read was replaced with the defaults at the next change. It is set
    /// aside first, and never written over.
    func testAFileThatDoesNotReadIsSetAside() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-tags-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("tags.json")
        try Data(#"{"schema": 1, "tags": [{"id": "u-12345678", "name": "Hedg"#.utf8).write(to: url)  // cut short
        let store = TagStore(url: url)
        XCTAssertEqual(store.load(), TagCatalog(), "the defaults")
        let aside = dir.appendingPathComponent("tags.json.bad")
        XCTAssertEqual(try String(contentsOf: aside, encoding: .utf8).hasSuffix("Hedg"), true, "kept as it was")
        store.save(TagCatalog())
        XCTAssertNotNil(try? Data(contentsOf: url), "a new file")
        try Data("not json".utf8).write(to: url)
        TagModel(store: store, remember: false).update { $0.setHidden("format", true) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("tags-2.json.bad").path), "a second one, beside")
        XCTAssertTrue(store.load().tag("format")!.hidden)
    }

    /// The code audit: the app counted 32 characters, the engine 64 code points, so a name of emoji sequences was
    /// refused with every request carrying it.
    func testNamesFitTheEnginesLimit() throws {
        let family = "👩‍👩‍👧‍👦"  // one character, seven code points
        let long = try XCTUnwrap(TagCatalog.clean(String(repeating: family, count: 20)))
        XCTAssertLessThanOrEqual(long.unicodeScalars.count, TagCatalog.maxNameScalars)
        XCTAssertEqual(long.count, 9)
        XCTAssertEqual(TagCatalog.clean(String(repeating: "论", count: 40))?.count, 32, "CJK: 32 characters")
        var c = TagCatalog()
        let id = try XCTUnwrap(c.add(name: String(repeating: family, count: 20), sign: nil)).id
        XCTAssertLessThanOrEqual(try XCTUnwrap(c.names(for: [id])[id]).unicodeScalars.count, 64)
    }

    /// A tag the catalogue lacks shows the name its ledger keeps (`tag_names`), never its raw id (the code audit).
    func testLedgerNamesForTagsTheCatalogueLacks() {
        let saved = TagCatalog.ledgerNames
        defer { TagCatalog.ledgerNames = saved }
        TagCatalog.learn(["u-0badcafe": "Hedging"])
        XCTAssertEqual(TagCatalog().name("u-0badcafe"), "Hedging")
        XCTAssertEqual(TagCatalog().name("u-0badcafe", backup: ["u-0badcafe": "Own"]), "Own")
        XCTAssertEqual(TagCatalog().name("grammar"), "Grammar", "the catalogue first")
        XCTAssertEqual(TagSelection(on: ["u-0badcafe"]).shown(TagCatalog()).last?.name, "Hedging")
    }

    /// Restore Default Names while a tag is open in Settings: its fields take the restored words, so leaving it does
    /// not write the old ones back; a field typed in keeps its text unless that very field changed (the code audit).
    func testTheEditorFollowsTheTag() {
        var cat = TagCatalog()
        _ = cat.rename("grammar", to: "Grammar & usage")
        let before = cat.tag("grammar")!
        var f = TagEditorFields(before)
        f.hint = "typed, not saved yet"
        cat.restoreDefaultNames()
        f.follow(before, cat.tag("grammar")!)
        XCTAssertEqual(f.name, "Grammar")
        XCTAssertEqual(f.hint, "typed, not saved yet", "its stored words did not change")
        var other = before
        other.sign = "leaf"
        var g = TagEditorFields(before)
        g.name = "Typing"
        g.follow(before, other)
        XCTAssertEqual(g.name, "Typing")
    }

    /// The review: clearing a tag's name said "Another tag has that name." The field shows the tag's name again and
    /// nothing is refused or written.
    func testAnEmptiedNameIsPutBack() {
        let t = TagCatalog().tag("logic")!
        var f = TagEditorFields(t)
        f.name = "   "
        XCTAssertTrue(f.keepName(t))
        XCTAssertEqual(f.name, "Logic & claims")
        f.name = "Claims"
        XCTAssertFalse(f.keepName(t), "a name: renamed as before")
        XCTAssertEqual(f.name, "Claims")
    }

    /// The review: Restore Default Names left two tags with one name, and overwrote the advisor's words with one click.
    /// A default name another tag has stays as it is (one freed meanwhile is taken); it asks first, only when a
    /// built-in tag would change.
    func testRestoringNamesNeverGivesTwoTagsOneName() throws {
        var c = TagCatalog()
        XCTAssertEqual(c.restorable, [], "as they came: nothing to restore, the button is disabled")
        XCTAssertTrue(c.rename("clarity", to: "Clear writing"))
        let own = try XCTUnwrap(c.add(name: "Clarity", sign: nil)).id
        XCTAssertTrue(c.rename("grammar", to: "G"))
        XCTAssertTrue(c.rename("wording", to: "Grammar"))  // grammar's default name, freed when wording takes its own back
        c.setHint("clarity", "Mine")
        c.setHint("logic", "My own words")
        XCTAssertEqual(Set(c.restorable), ["clarity", "grammar", "wording", "logic"])
        XCTAssertEqual(TagsSettings.restoreDetail(["logic"], catalog: c),
                       "“Logic & claims” takes back the name, definition and next-draft line it came with. "
                       + "Your own tags and the order stay. This cannot be undone.")
        XCTAssertTrue(TagsSettings.restoreDetail(["grammar", "wording"], catalog: c).hasPrefix("“G” and “Grammar” take back the names"))
        XCTAssertTrue(TagsSettings.restoreDetail(c.restorable, catalog: c).hasPrefix("4 built-in tags take back"))
        c.restoreDefaultNames()
        XCTAssertEqual(c.name("grammar"), "Grammar", "taken once wording gave it back")
        XCTAssertEqual(c.name("wording"), "Wording")
        XCTAssertEqual(c.name("clarity"), "Clear writing", "your own tag has that name: it stays")
        XCTAssertEqual(c.tag("clarity")?.hint, TagCatalog().tag("clarity")?.hint, "its words restored all the same")
        XCTAssertEqual(c.name(own), "Clarity")
        XCTAssertEqual(c.tag("logic")?.hint, TagCatalog().tag("logic")?.hint)
        let names = c.tags.map { $0.name.lowercased() }
        XCTAssertEqual(Set(names).count, names.count, "no name twice")
        XCTAssertEqual(c.restorable, [], "nothing more it would change")
    }

    /// The review: the sign menus offered signs other tags have, though every sign means one tag, and showed the
    /// symbols' identifiers ("questionmark.circle") as their items.
    func testTheSignMenusOfferFreeSignsByName() throws {
        var c = TagCatalog()
        XCTAssertEqual(c.freeSigns(), TagCatalog.palette, "no tag has a sign of the palette yet")
        let hedging = try XCTUnwrap(c.add(name: "Hedging", sign: "leaf")).id
        XCTAssertFalse(c.freeSigns().contains("leaf"), "New Tag…: not one another tag has")
        XCTAssertFalse(c.freeSigns(for: "grammar").contains("leaf"))
        XCTAssertEqual(c.freeSigns(for: hedging), TagCatalog.palette, "a tag's own sign stays in its menu")
        XCTAssertEqual(c.freeSigns(for: "grammar").first, "textformat.abc", "a built-in tag's own, first")
        XCTAssertFalse(c.freeSigns(for: "grammar").contains("star"), "Well done's")
        for s in TagCatalog.palette + TagCatalog.defaults.compactMap(\.sign) {
            XCTAssertNotNil(TagCatalog.signNames[s], s + " has a name")
        }
        XCTAssertEqual(TagCatalog.signName("questionmark.circle"), "Question Mark")
        XCTAssertEqual(TagCatalog.signName("hand.raised"), "Hand", "a sign from elsewhere: its first word")
    }

    /// The review: when the hierarchy's overview failed, the Comments column said "Counting…" for good, and Merge and
    /// Delete were disabled with no reason.
    func testTheCountsSayWhyTheyAreMissing() {
        XCTAssertEqual(TagsSettings.failure(.failed("The engine stopped.")), "Your papers could not be read: The engine stopped.")
        XCTAssertNil(TagsSettings.failure(.loading))
        XCTAssertNil(TagsSettings.failure(.loaded))
    }
}

@MainActor
final class TagSuggestionTests: XCTestCase {
    private let c = TagCatalog()

    private func ids(_ note: String, kind: MarkKind? = nil, env: String? = nil, file: String? = nil, quote: String? = nil,
                     source: String? = nil, catalog: TagCatalog? = nil, on: [String] = []) -> [String] {
        TagSuggester.suggest(note: note, kind: kind, env: env, file: file, quote: quote, source: source, catalog: catalog ?? c,
                             on: on).map(\.id)
    }

    func testWordsInEnglishAndChinese() {
        XCTAssertEqual(ids("“prove” 太强：这里只有相关，没有因果。"), ["logic"])
        XCTAssertEqual(ids("Table 2 has no units."), ["figures", "math"], "earliest first, at most two")
        XCTAssertEqual(ids("Is this suitable here?"), [], "whole words: no table in suitable")
        XCTAssertEqual(ids("See fig. 3"), ["figures"])
        XCTAssertEqual(ids("Use \\cite here"), ["format"])
        XCTAssertEqual(ids("冠词用错了"), ["grammar"])
        XCTAssertEqual(ids("这句话太长，换个词"), ["wording"])
        XCTAssertEqual(ids("表达不清楚"), ["clarity"], "单字表 is not 表格")
        XCTAssertEqual(ids("Cite the earlier survey and compare."), ["evidence"], "one tag once")
        let s = TagSuggester.suggest(note: "这里的因果太强了", catalog: c).first
        XCTAssertEqual(s?.reason, "Suggested from “因果” in your note")
    }

    /// The audit's crash: lower-casing İ (and Ⱥ, Ⱦ) lengthens the string, and a range found in the lower-cased note
    /// sliced the note itself past its end (a keyword at the end) or in the wrong place (a keyword inside).
    func testLetterThatGrowsWhenLowerCased() {
        let end = "Ask İnce et al. here, citation"
        XCTAssertEqual(TagSuggester.hits(end).map(\.term), ["citation"], "a keyword at the very end")
        XCTAssertEqual(TagSuggester.hits(end).first?.at, 22)
        let inside = "Ⱥ and Ⱦ: CITATION needed"
        XCTAssertEqual(TagSuggester.hits(inside).first?.term, "CITATION", "the words as written, in the right place")
        XCTAssertEqual(TagSuggester.suggest(note: "İİİ Ⱥ citation", catalog: c).first?.reason,
                       "Suggested from “citation” in your note")
        XCTAssertEqual(ids("Straße: unclear"), ["clarity"])
    }

    func testPlaceAndKindFirst() {
        XCTAssertEqual(ids("Units?", env: "figure"), ["figures", "math"], "where it is first")
        XCTAssertEqual(ids("", env: "equation*"), ["math"])
        XCTAssertEqual(ids("", file: "main.bbl"), ["format"])
        XCTAssertEqual(ids("", env: "thebibliography"), ["format"])
        XCTAssertEqual(ids("", kind: .box, quote: ""), ["figures"], "a box drawn on the page, on no words")
        XCTAssertEqual(ids("cut", kind: .strikeout), ["wording"], "a strikeout with a very short note")
        XCTAssertEqual(ids("This should go because it says again what Section 2 already says at length", kind: .strikeout),
                       [], "not with a long note")
    }

    /// The review (A5a-03, A5a-05 + E3-10): the box rule needs words known to be none (Tag Comments… gave every box
    /// of another paper Figures & tables, whose words it does not know), and the `$` rule reads the source, as the PDF
    /// prints no `$` for math but does print "$5".
    func testTheBoxAndDollarRulesReadTheirOwnInputs() throws {
        XCTAssertEqual(ids("", kind: .box, quote: nil), [], "words not known: no place rule")
        XCTAssertEqual(ids("", kind: .box, quote: "Figure 3: Drift"), [], "a box on words")
        XCTAssertEqual(ids("", kind: .box, env: "equation", quote: nil), ["math"], "the place still counts")
        XCTAssertEqual(ids("", quote: "costs $5 a day"), [], "the PDF's words: a printed dollar is no math")
        XCTAssertEqual(ids("", quote: "the value x", source: "the value $x$"), ["math"], "the source's math")
        XCTAssertEqual(ids("", quote: "costs $5", source: "costs \\$5"), [], "an escaped dollar prints as one")
        // a comment, as the card, its picker and Tag Comments… on the paper shown read it
        func card(_ extra: [String: Any]) throws -> [String] {
            TagSuggester.suggest(for: try makeComment(["note": ""].merging(extra) { _, b in b }), catalog: c).map(\.id)
        }
        XCTAssertEqual(try card(["kind": "box", "text": ""]), ["figures"], "a box on no words")
        XCTAssertEqual(try card(["kind": "box", "text": NSNull()]), ["figures"], "no words in the state: as on none")
        XCTAssertEqual(try card(["kind": "box", "text": "Figure 3: Drift"]), [], "a box on words")
        XCTAssertEqual(try card(["text": "the value x", "new_quote": "the value $x$", "method": "selection"]), ["math"])
        XCTAssertEqual(try card(["text": "the value x", "new_quote": "the value $x$ and more", "method": "line"]), [],
                       "a source line may hold other words")
        XCTAssertEqual(try card(["text": "costs $5", "new_quote": "costs 5 dollars", "method": "selection"]), [],
                       "the PDF's dollar")
    }

    func testWellDoneOnlyForShortPraise() {
        XCTAssertEqual(ids("很好"), ["praise"])
        XCTAssertEqual(ids("不错"), ["praise"], "its own 不 is not a negation")
        XCTAssertEqual(ids("Well done."), ["praise"])
        XCTAssertEqual(ids("很好，但是这里还要改"), [], "a but")
        XCTAssertEqual(ids("Not good"), [], "a negation")
        XCTAssertEqual(ids("Good, but the conclusion is too strong here, much too strong"), ["logic"])
    }

    func testNeverOnHiddenOrAlreadyOn() {
        var hidden = TagCatalog()
        hidden.setHidden("logic", true)
        XCTAssertEqual(ids("因果太强", catalog: hidden), [])
        XCTAssertEqual(ids("因果太强", on: ["logic"]), [])
        XCTAssertEqual(ids("因果太强，引用文献"), ["logic", "evidence"])
    }

    /// The review: the words were searched again for every untagged card at every state reply. A note's hits are kept;
    /// the catalogue, the kind and the tags already on are still asked each time.
    func testHitsAreKeptPerNote() {
        let note = "因果太强，引用文献 " + UUID().uuidString
        let first = TagSuggester.hits(note)
        XCTAssertEqual(first.map(\.id), ["logic", "evidence"])
        XCTAssertEqual(TagSuggester.hits(note).map(\.id), first.map(\.id))
        XCTAssertEqual(TagSuggester.hits(note).map(\.at), first.map(\.at))
        var hidden = TagCatalog()
        hidden.setHidden("logic", true)
        XCTAssertEqual(ids(note, catalog: hidden), ["evidence"])
        XCTAssertEqual(ids(note, on: ["evidence"]), ["logic"])
        XCTAssertEqual(ids(note, env: "figure"), ["figures", "logic"])
        XCTAssertEqual(ids(note), ["logic", "evidence"])
    }
}

@MainActor
final class TagPickerTests: XCTestCase {
    func testTheWorkingSet() throws {
        let s = TagSelection(on: ["logic"], suggestions: [TagSuggestion(id: "figures", reason: "on a figure")])
        XCTAssertFalse(s.changed)
        s.toggle("figures")
        XCTAssertEqual(s.on, ["logic", "figures"])
        XCTAssertEqual(s.accepted, ["figures"], "a suggestion taken")
        XCTAssertNil(s.suggestion("figures"), "on: no longer dashed")
        s.toggle("wording")
        XCTAssertEqual(s.accepted, ["figures"])
        s.toggle("figures")
        XCTAssertEqual(s.accepted, [])
        XCTAssertTrue(s.changed)
        s.toggle("logic")
        s.toggle("wording")
        XCTAssertFalse(s.changed == false && s.on == ["logic"])
        XCTAssertEqual(s.on, [])
        // at most 12
        let many = TagSelection(on: (0..<12).map { "t\($0)" })
        many.toggle("grammar")
        XCTAssertEqual(many.on.count, 12)
    }

    func testNewTagInThePicker() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-tags-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tags = TagModel(store: TagStore(url: dir.appendingPathComponent("tags.json")), remember: false)
        let s = TagSelection(on: [])
        s.naming = true
        s.newName = "Hedging"
        s.newSign = "leaf"
        s.commitNew(tags)
        let id = try XCTUnwrap(tags.catalog.named("Hedging")?.id)
        XCTAssertEqual(s.on, [id], "added and turned on for this comment")
        XCTAssertFalse(s.naming)
        XCTAssertEqual(s.shown(tags.catalog).last?.name, "Hedging", "at the end: the other chips do not move")
        // a hidden tag's name: that tag, shown again, and said so
        tags.update { $0.setHidden("format", true) }
        XCTAssertFalse(s.shown(tags.catalog).contains { $0.id == "format" }, "hidden: not in the picker")
        s.naming = true
        s.newName = "format & latex"
        s.commitNew(tags)
        XCTAssertTrue(s.on.contains("format"))
        XCTAssertFalse(tags.catalog.tag("format")!.hidden)
        XCTAssertEqual(s.message, "Format & LaTeX was hidden from the picker: it is shown again.")
        // a hidden tag on the comment when the picker opens is shown, so it can be taken off; an unknown id too
        tags.update { $0.setHidden("math", true) }
        let saved = TagCatalog.ledgerNames
        defer { TagCatalog.ledgerNames = saved }
        TagCatalog.learn(["zz-elsewhere": "Elsewhere"])  // as a ledger read on this Mac names it
        let t = TagSelection(on: ["math", "zz-elsewhere"])
        let shown = t.shown(tags.catalog)
        XCTAssertTrue(shown.contains { $0.id == "math" })
        XCTAssertEqual(shown.last?.name, "Elsewhere")
    }

    /// A chip never moves (TAGS.md §2.1): its width is the same off and on; the built-in tags fit three rows.
    func testChipsKeepTheirWidth() {
        _ = NSApplication.shared
        for name in ["Grammar", "Logic & claims", "Evidence & citations", "Well done"] {
            func width(_ on: Bool, suggested: String? = nil) -> CGFloat {
                NSHostingView(rootView: TagChip(name: name, sign: "star", on: on, suggested: suggested, help: "", action: {})).fittingSize.width
            }
            XCTAssertEqual(width(false), width(true), name)
            XCTAssertEqual(width(false), width(false, suggested: "why"), name)
            XCTAssertEqual(width(true), TagChipMetrics.width(name), name)
        }
        XCTAssertEqual(TagChipMetrics.rows(TagCatalog.defaults.map(\.name), width: TagPickerSize.chips), 3)
    }

    /// The review: Return in Tag Comments…' New Tag… field pressed Done (AppKit's key equivalents go first), which
    /// closed the sheet and lost the name. While the field is open, Done is not the default button. The sheet is in a
    /// window that is never shown.
    func testReturnInNewTagDoesNotPressDone() throws {
        _ = NSApplication.shared
        let papers = try TagDataTests.reply().papers.compactMap { p in p.overview.map { (path: p.path, title: p.path, data: $0) } }
        let sheet = TagCommentsModel(title: "Mei Lin", papers: papers)
        let tags = TagModel(store: TagStore(url: TagStore.temporary), remember: false)
        var done = 0
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.contentView = NSHostingView(rootView: TagCommentsSheet(sheet: sheet, tags: tags) { done += 1 })
        func settle() {
            for _ in 0..<5 {
                window.contentView?.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
        }
        let ret = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                 windowNumber: window.windowNumber, context: nil, characters: "\r",
                                                 charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        settle()
        _ = window.performKeyEquivalent(with: ret)
        XCTAssertEqual(done, 1, "no row selected: Return is Done")
        let key = try XCTUnwrap(sheet.entries.first?.key)
        sheet.select(key, tags: tags)
        settle()
        _ = window.performKeyEquivalent(with: ret)
        XCTAssertEqual(done, 2, "a row's chips shown: Return is still Done")
        sheet.selection?.naming = true
        settle()
        _ = window.performKeyEquivalent(with: ret)
        XCTAssertEqual(done, 2, "New Tag…'s field open: Return is the field's")
        sheet.selection?.cancelNew()
        settle()
        _ = window.performKeyEquivalent(with: ret)
        XCTAssertEqual(done, 3)
    }

    /// The new-comment popover with its chips stays within a laptop's room (the critique: measure the whole height).
    func testThePopoverHeight() {
        _ = NSApplication.shared
        let d = CommentDraft(kind: .highlight, color: .yellow, note: "", mode: .text, page: 0,
                             quote: String(repeating: "a long selection of words ", count: 20))
        let tags = TagModel(store: TagStore(url: TagStore.temporary), remember: false)
        let host = NSHostingView(rootView: CommentEditor(title: "New comment", draft: d, tags: tags, onSave: {}, onCancel: {}))
        XCTAssertLessThanOrEqual(host.fittingSize.height, 420)
        XCTAssertEqual(host.fittingSize.width, TagPickerSize.popover, accuracy: 0.5)
    }
}

/// The engine's new keys in the state and the overview (CONTRACT amendment "Tags, key page and Reopen").
@MainActor
final class TagDataTests: XCTestCase {
    static let fixture = OverviewDataTests.fixtures.appendingPathComponent("overview-tags.json")

    static func reply() throws -> OverviewReply { try PaperOverview.decodeReply(Data(contentsOf: fixture)) }

    /// A state of the round-2 fixture with tags, a suggestion's place, a comment reopened and an edit near a closed one.
    static func state() throws -> EngineState {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: StepTests.fixtures
            .appendingPathComponent("state-round2.json"))) as? [String: Any])
        var comments = try XCTUnwrap(json["comments"] as? [[String: Any]])
        for i in comments.indices {
            switch comments[i]["id"] as? String {
            case "R1-05": comments[i]["tags"] = ["logic", "grammar"]
            case "R2-02": comments[i]["tags"] = []; comments[i]["env"] = "figure"
            case "R1-06": comments[i]["revived"] = ["from": 1, "at": "2026-10-20T10:00:00+08:00"]
            case "R1-01": comments[i]["revivable"] = true
            default: break
            }
        }
        json["comments"] = comments
        var changes = try XCTUnwrap(json["changes"] as? [[String: Any]])
        if !changes.isEmpty { changes[0]["near_closed"] = [["id": "R1-04", "round": 1, "verdict": "verified", "revivable": true]] }
        json["changes"] = changes
        return try EngineState.decode(JSONSerialization.data(withJSONObject: json))
    }

    /// Settings › Tags and Tag Comments… wait for the hierarchy's reply on its way (the code audit: `.loaded` stayed
    /// while a reload ran, and they decided from the old data).
    func testTheHubSaysWhenARequestIsOnItsWay() {
        let hub = HubModel()
        var ran: [Bool] = []
        let a = hub.begin(key: "a")
        XCTAssertTrue(hub.pending)
        hub.afterLoad { ran.append($0) }
        hub.finish(a, .success(OverviewReply(papers: [], students: [])))
        XCTAssertFalse(hub.pending)
        XCTAssertEqual(ran, [true])
        let b = hub.begin(key: "b")
        XCTAssertEqual(hub.status, .loaded, "the page keeps what it shows")
        XCTAssertTrue(hub.pending)
        hub.afterLoad { ran.append($0) }
        hub.finish(b, .failure(EngineError(message: "x")))
        XCTAssertEqual(ran, [true, false])
        XCTAssertFalse(hub.pending)
    }

    func testTheLedgersTagNamesDecode() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: StepTests.fixtures
            .appendingPathComponent("state-round2.json"))) as? [String: Any])
        json["tag_names"] = ["u-0badcafe": "Hedging"]
        XCTAssertEqual(try EngineState.decode(JSONSerialization.data(withJSONObject: json)).tagNames, ["u-0badcafe": "Hedging"])
        var ov = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: Self.fixture)) as? [String: Any])
        var papers = try XCTUnwrap(ov["papers"] as? [[String: Any]])
        var first = try XCTUnwrap(papers[0]["overview"] as? [String: Any])
        first["tag_names"] = ["u-0badcafe": "Hedging"]
        papers[0]["overview"] = first
        ov["papers"] = papers
        let r = try PaperOverview.decodeReply(JSONSerialization.data(withJSONObject: ov))
        XCTAssertEqual(r.papers[0].overview?.tagNames, ["u-0badcafe": "Hedging"])
        XCTAssertEqual(try Self.reply().papers[0].overview?.tagNames, [:], "an engine before them")
    }

    func testTheStateDecodes() throws {
        let st = try Self.state()
        XCTAssertEqual(st.comments.first { $0.id == "R1-05" }?.tagIDs, ["logic", "grammar"])
        XCTAssertEqual(st.comments.first { $0.id == "R2-02" }?.env, "figure")
        XCTAssertEqual(st.comments.first { $0.id == "R1-06" }?.revived?.from, 1)
        XCTAssertEqual(st.comments.first { $0.id == "R1-01" }?.revivable, true)
        XCTAssertEqual(st.changes.first?.nearClosed?.first?.id, "R1-04")
        // an engine before tags: none, nothing reopened
        let old = try EngineState.decode(Data(contentsOf: StepTests.fixtures.appendingPathComponent("state-round2.json")))
        XCTAssertTrue(old.comments.allSatisfy { $0.tags == nil && $0.revived == nil && $0.revivable == nil })
    }

    func testCardsShowTagsSuggestionsAndReopen() throws {
        let st = try Self.state()
        var cat = TagCatalog()
        _ = cat.rename("logic", to: "Claims")
        func card(_ id: String, suggest: Bool = true, reopenIn: Int? = nil) throws -> CardModel {
            CardModel(try XCTUnwrap(st.comments.first { $0.id == id }), round: 2, pdfs: [:], textX: [], showChanges: true,
                      catalog: cat, suggest: suggest, reopenIn: reopenIn)
        }
        let tagged = try card("R1-05")
        XCTAssertEqual(tagged.tags.map(\.name), ["Grammar", "Claims"], "the catalogue's order and names")
        XCTAssertNil(tagged.suggestion, "no suggestion on a tagged card")
        XCTAssertEqual(try card("R2-02").suggestion?.id, "figures", "by its place")
        XCTAssertNil(try card("R2-02", suggest: false).suggestion, "suggestions off")
        let revived = try card("R1-06")
        XCTAssertEqual(revived.revivedFrom, 1)
        XCTAssertEqual(revived.stateWord, "reopened", "the row's word")
        XCTAssertTrue(revived.turns.contains { $0.label == "R2 · you reopened it" }, revived.turns.map(\.label).joined(separator: " | "))
        // the cause before the act (the UI audit): the round's own turn (the student's, or unchanged) before the reopen
        let at = try XCTUnwrap(revived.turns.firstIndex { $0.label == "R2 · you reopened it" })
        XCTAssertTrue(revived.turns[..<at].contains { $0.round == 2 && $0.kind != .advisor }, revived.turns.map(\.label).joined(separator: " | "))
        XCTAssertFalse(revived.turns[(at + 1)...].contains { $0.round == 2 && [.student, .quiet, .engine].contains($0.kind) })
        XCTAssertEqual(try card("R1-01", reopenIn: 3).reopenIn, 3)
        let ch = ChangeModel(try XCTUnwrap(st.changes.first), round: 2, pdfs: [:], textX: [], statuses: [:])
        XCTAssertEqual(ch.nearClosed.map(\.id), ["R1-04"])
    }

    func testTheOverviewDecodes() throws {
        let r = try Self.reply()
        let reef = try XCTUnwrap(r.papers.first { $0.path == "/synthetic/reef" }?.overview)
        let t = try XCTUnwrap(reef.tags)
        XCTAssertEqual(t.comments, 17)
        XCTAssertEqual(t.tagged, 15)
        XCTAssertEqual(t.rounds.map(\.n), [1, 2, 3, 4])
        XCTAssertEqual(t.rounds.map(\.new), [13, 3, 1, 0])
        XCTAssertEqual(t.byTag["logic"]?.comments, 2)
        XCTAssertEqual(reef.keyPage?.round, 4)
        XCTAssertFalse(reef.keyPage?.chosen ?? true)
        XCTAssertTrue(reef.comments.contains { $0.revivable })
        XCTAssertEqual(reef.comments.first { $0.id == "R1-07" }?.tags, ["logic", "wording"])
        let s = try XCTUnwrap(r.students?.first?.tags)
        XCTAssertEqual(s.firstDrafts.points.count, 3)
        XCTAssertEqual(s.firstDrafts.trend["grammar"]?.word, "mixed")
        XCTAssertEqual(s.facts.count, 2)
        XCTAssertEqual(s.focus.map(\.tag), ["logic", "math"])
        XCTAssertEqual(s.praise?.comments, 1)
    }

    /// Topics (TAGS.md §6.2): the advisor's order in groups, Not tagged and New comments last, one column a round, the
    /// oldest folded when they do not fit; counts only.
    func testTopics() throws {
        let reef = try XCTUnwrap(Self.reply().papers.first { $0.path == "/synthetic/reef" }?.overview)
        var cat = TagCatalog()
        cat.move(from: IndexSet(integer: 3), to: 0)  // Logic & claims first: its group (Thinking) leads
        let table = TopicsTable.make(try XCTUnwrap(reef.tags), data: reef, catalog: cat)
        XCTAssertEqual(table.columns, ["Round 1", "Round 2", "Round 3", "Round 4"])
        XCTAssertEqual(table.rows.first?.id, "logic")
        XCTAssertEqual(table.rows.map(\.group).prefix(5).map { $0?.rawValue }, ["thinking", "thinking", "thinking", "thinking", "language"])
        XCTAssertEqual(table.rows.suffix(2).map(\.name), ["Not tagged", "New comments"])
        let total = try XCTUnwrap(table.rows.last)
        XCTAssertEqual(total.counts, [13, 3, 1, 0])
        XCTAssertEqual(total.open, 6)
        XCTAssertTrue(table.note.contains("Round 4 has no new comments yet."))
        XCTAssertFalse(table.rows.contains { $0.writtenIn.contains("%") || $0.name.contains("%") }, "no shares")
        let folded = TopicsTable.make(try XCTUnwrap(reef.tags), data: reef, catalog: cat, maxColumns: 3)
        XCTAssertEqual(folded.columns, ["R1–R2", "Round 3", "Round 4"])
        XCTAssertEqual(folded.rows.last?.counts, [16, 1, 0])
    }

    /// Following a tag (the critique's fix): the cells without it step back, none is outlined, no path is drawn and
    /// every number stays; each round's readout gets a Sage line.
    func testFollowingATag() throws {
        let reef = try XCTUnwrap(Self.reply().papers.first { $0.path == "/synthetic/reef" }?.overview)
        let plain = MapScene.build(MapInput(data: reef, width: 1100))
        let tag = MapScene.build(MapInput(data: reef, width: 1100, selection: .tag("logic")))
        XCTAssertEqual(plain.rows.flatMap { $0.cells.map(\.count) }, tag.rows.flatMap { $0.cells.map(\.count) }, "the numbers never change")
        XCTAssertTrue(tag.paths.isEmpty)
        XCTAssertFalse(tag.rows.flatMap(\.cells).contains(where: \.selected))
        let kept = tag.rows.flatMap(\.cells).filter { !$0.dim }
        XCTAssertFalse(kept.isEmpty)
        XCTAssertTrue(tag.rows.flatMap(\.cells).contains(where: \.dim))
        let held = Set(reef.comments.filter { $0.tags.contains("logic") }.map(\.id))
        for c in kept where c.fold == nil {
            XCTAssertTrue(reef.comments.contains { held.contains($0.id) && $0.step(in: c.round)?.section == c.section },
                          "\(c.section)@\(c.round) holds a Logic & claims comment")
        }
        XCTAssertTrue(tag.rows.contains { $0.sage?.text.contains("here") == true })
        let panel = try XCTUnwrap(OverviewPanel.make(.tag("logic"), data: reef, strip: 4, student: "Mei"))
        XCTAssertEqual(panel.title, "Logic & claims")
        XCTAssertTrue(panel.meta.hasPrefix("2 comments over all rounds, each counted once"))
        if case .lines(let lines, _, _) = panel.body { XCTAssertEqual(Set(lines.map(\.id)), held) } else { XCTFail("lines") }
        let untagged = try XCTUnwrap(OverviewPanel.make(.tag(TagCatalog.untagged), data: reef, strip: 4, student: "Mei"))
        XCTAssertEqual(untagged.buttons.map(\.action), [.tagComments])
        // a closed comment the student broke since: Reopen in Round 4 on its panel
        let id = try XCTUnwrap(reef.comments.first { $0.revivable }?.id)
        XCTAssertTrue(OverviewPanel.make(.comment(id), data: reef, strip: 4, student: "Mei")?.buttons.contains { $0.action == .revive(id) } ?? false)
        XCTAssertTrue(OverviewModel.valid(.tag("logic"), in: reef))
        XCTAssertFalse(OverviewModel.valid(.tag("nobody"), in: reef))
    }

    /// The Student page's words (TAGS.md §6.3 with the critique's fixes): facts one at a time, trend words with their
    /// counts, the email copy in English only.
    func testTheWritingProfilesWords() throws {
        let r = try Self.reply()
        let t = try XCTUnwrap(r.students?.first?.tags)
        let titles = ["/synthetic/reef": "Reef choruses", "/synthetic/shrimp": "Shrimp snap detector", "/synthetic/kelp": "Kelp holdfast survey"]
        let lede = ProfileText.lede(t, catalog: TagCatalog(), titles: titles)
        XCTAssertEqual(lede, "Three papers, eight rounds. Wording: 0 comments in Round 3 of Reef choruses, on 9 new words. "
                       + "Structure: none since Round 2 of Reef choruses.")
        XCTAssertEqual(ProfileText.trend("same"), "about the same")
        XCTAssertEqual(ProfileText.trend("mixed"), "no clear trend")
        XCTAssertNil(ProfileText.trend(nil))
        XCTAssertEqual(ProfileText.why("two_points"), "after a third")
        let email = ProfileText.email(t.focus, catalog: TagCatalog(), titles: titles)
        XCTAssertTrue(email.contains("• Logic & claims: Say only what your data show; mark a guess as a guess."))
        XCTAssertFalse(email.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }, "no Chinese: the student's copy is English")
        for w in ["better", "worse", "improved", "%"] { XCTAssertFalse(lede.contains(w)) }
    }

    func testTheHierarchysRequest() {
        var p = PaperRef(path: "/synthetic/reef", title: "Reef", student: "Mei Lin")
        p.keyPage = KeyPageChoice(round: 3, page: 4)
        let req = AppModel.hubRequest([p, PaperRef(path: "/synthetic/kelp", title: "Kelp", student: "Mei Lin")], order: ["logic", "grammar"])
        XCTAssertEqual((req["key_pages"] as? [String: [String: Int]])?["/synthetic/reef"], ["round": 3, "page": 4])
        XCTAssertNil((req["key_pages"] as? [String: [String: Int]])?["/synthetic/kelp"])
        XCTAssertEqual(req["tag_order"] as? [String], ["logic", "grammar"])
        XCTAssertNil(AppModel.hubRequest([PaperRef(path: "/a", title: "A", student: "")])["key_pages"])
        // papers.json keeps it, and an older list reads without it
        let data = try? JSONEncoder().encode([p])
        XCTAssertEqual(try? JSONDecoder().decode([PaperRef].self, from: data ?? Data()).first?.keyPage, p.keyPage)
        XCTAssertNil(try? JSONDecoder().decode([PaperRef].self, from: Data(#"[{"path": "/a", "title": "A", "student": "B"}]"#.utf8)).first?.keyPage)
    }

    func testTheKeyPageInTheStrip() throws {
        let reef = try XCTUnwrap(Self.reply().papers.first { $0.path == "/synthetic/reef" }?.overview)
        XCTAssertEqual(PageStripView.keyPage(4, data: reef, chosen: nil)?.page, reef.keyPage?.page, "the busiest, from the engine")
        XCTAssertEqual(PageStripView.keyPage(4, data: reef, chosen: nil)?.chosen, false)
        XCTAssertNil(PageStripView.keyPage(2, data: reef, chosen: nil), "another round's strip")
        XCTAssertEqual(PageStripView.keyPage(2, data: reef, chosen: KeyPageChoice(round: 2, page: 1))?.page, 1)
        XCTAssertEqual(PageStripView.keyPage(2, data: reef, chosen: KeyPageChoice(round: 2, page: 1))?.chosen, true)
        // the round built again with fewer pages: its last page, as the engine takes it (the code audit)
        let pages = try XCTUnwrap(reef.round(4)?.build?.pages)
        XCTAssertEqual(PageStripView.keyPage(4, data: reef, chosen: KeyPageChoice(round: 4, page: pages + 5))?.page, pages - 1)
        XCTAssertEqual(PageStripView.clamp(-2, pages: 3), 0)
        XCTAssertEqual(PageStripView.clamp(7, pages: nil), 7)
    }
}

/// The model's side: a card's tags written at once (a fixture run shows them only), the card's picker written once on
/// closing, a suggestion taken, and the last place.
@MainActor
final class TagModelTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-tagmodel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// `figure`: a comment put on a figure (its `env`).
    private func makeModel(figure: String? = nil) throws -> AppModel {
        _ = NSApplication.shared
        let st = try TagDataTests.state()
        let url = dir.appendingPathComponent("state.json")
        // the state's own JSON again, with its tags (the decoder reads snake case: write it as the engine would)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: StepTests.fixtures
            .appendingPathComponent("state-round2.json"))) as? [String: Any])
        var comments = try XCTUnwrap(json["comments"] as? [[String: Any]])
        for i in comments.indices where comments[i]["id"] as? String == "R1-05" { comments[i]["tags"] = st.comments.first { $0.id == "R1-05" }?.tags }
        for i in comments.indices where comments[i]["id"] as? String == figure { comments[i]["env"] = "figure" }
        json["comments"] = comments
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        for r in ["round1", "round2"] {
            try? FileManager.default.createSymbolicLink(at: dir.appendingPathComponent(r), withDestinationURL: StepTests.fixtures.appendingPathComponent(r))
        }
        var o = LaunchOptions()
        o.fixture = url.path
        o.drafts = dir.appendingPathComponent("drafts").path
        o.tags = dir.appendingPathComponent("tags.json").path
        return AppModel(options: o)
    }

    func testTagsOnACard() throws {
        let m = try makeModel()
        XCTAssertEqual(m.tags.store.url.lastPathComponent, "tags.json")
        XCTAssertTrue(m.tags.store.url.path.hasPrefix(dir.path), "the run's own catalogue")
        XCTAssertEqual(m.comment("R1-05")?.tagIDs, ["logic", "grammar"])
        m.setTags("R1-05", ["evidence"])
        XCTAssertEqual(m.comment("R1-05")?.tagIDs, ["evidence"])
        XCTAssertEqual(m.panel.cards.first { $0.id == "R1-05" }?.tags.map(\.id), ["evidence"], "the card at once")
        // the picker: opened with the comment's tags, written once when it closes
        m.openTagPicker("R1-05")
        XCTAssertEqual(m.edit.tagging, "R1-05")
        m.edit.tagSelection?.toggle("structure")
        m.edit.tagSelection?.toggle("clarity")
        XCTAssertEqual(m.comment("R1-05")?.tagIDs, ["evidence"], "nothing written while it is open")
        m.closeTagPicker("R1-05")
        XCTAssertNil(m.edit.tagging)
        XCTAssertEqual(m.comment("R1-05")?.tagIDs, ["evidence", "structure", "clarity"])
        XCTAssertEqual(m.panel.cards.first { $0.id == "R1-05" }?.tags.map(\.id), ["clarity", "evidence", "structure"],
                       "shown in the catalogue's order")
        // another picker closes the first one first
        m.openTagPicker("R1-05")
        m.edit.tagSelection?.toggle("clarity")
        m.openTagPicker("R1-02")
        XCTAssertEqual(m.comment("R1-05")?.tagIDs, ["evidence", "structure"])
        XCTAssertEqual(m.edit.tagging, "R1-02")
        m.closeTagPicker("R1-02")
        // a suggestion taken; the menu's toggle
        m.acceptSuggestion("R1-02", "wording")
        XCTAssertEqual(m.comment("R1-02")?.tagIDs, ["wording"])
        m.toggleTag("R1-02", "wording")
        XCTAssertEqual(m.comment("R1-02")?.tagIDs, [])
        // a rename shows on the card at once
        m.tags.update { _ = $0.rename("evidence", to: "Sources") }
        XCTAssertTrue(m.panel.cards.first { $0.id == "R1-05" }?.tags.contains { $0.name == "Sources" } ?? false)
        XCTAssertFalse(m.remembersPlace, "a test run never keeps or opens the last place")
    }

    /// Tag Comments… (A5a-03): a comment of the paper shown is suggested for as its card is (its place, its words);
    /// another paper's from its note and kind only, so its box gets no Figures & tables.
    func testTagCommentsReadTheShownPapersComments() throws {
        let m = try makeModel(figure: "R2-02")
        let sheet = TagCommentsModel(title: "", papers: [])
        sheet.model = m
        let shown = try XCTUnwrap(m.selectedPath)
        let r202 = try XCTUnwrap(m.comment("R2-02"))
        XCTAssertNotNil(r202.env, "the fixture's comment on a figure")
        func entry(_ paper: String, _ id: String, kind: String) -> TagCommentsModel.Entry {
            TagCommentsModel.Entry(paper: paper, paperTitle: "", id: id, round: 2, page: 0, note: "", kind: kind, color: nil, tags: [])
        }
        XCTAssertEqual(sheet.suggestions(entry(shown, "R2-02", kind: r202.kind), catalog: m.tags.catalog).map(\.id),
                       TagSuggester.suggest(for: r202, catalog: m.tags.catalog).map(\.id), "as its card")
        XCTAssertEqual(sheet.suggestions(entry(shown, "R2-02", kind: r202.kind), catalog: m.tags.catalog).first?.id, "figures")
        XCTAssertEqual(sheet.suggestions(entry("/elsewhere/paper", "R1-01", kind: "box"), catalog: m.tags.catalog), [],
                       "another paper's box: its words are not known")
    }

    /// The review: with a paper shown, Settings › Tags asked for the counts again only after a ledger edit, so a tag
    /// added (the order changed) left Delete disabled for good. It asks again whenever what they depend on changes.
    func testSettingsAsksForTheCountsAgain() throws {
        let m = try makeModel()
        XCTAssertNil(m.hub, "a paper shown: the catalogue's change does not ask the hierarchy itself")
        let host = NSHostingView(rootView: TagsSettings(model: m))
        host.frame = NSRect(x: 0, y: 0, width: SettingsView.width, height: TagsSettings.height)
        func settle() {
            for _ in 0..<5 {
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
        }
        settle()
        XCTAssertTrue(m.hubCurrent, "asked when it appeared")
        _ = m.tags.add(name: "Hedging", sign: nil)
        XCTAssertFalse(m.hubCurrent, "the picker's order changed")
        settle()
        XCTAssertTrue(m.hubCurrent, "asked again: Delete can decide")
    }

    func testTheLastPlace() throws {
        for item: OverviewItem in [.section("methods", round: 3), .round(2), .page(round: 4, page: 0), .comment("R1-05"), .tag("u-3f9c1a2b")] {
            XCTAssertEqual(OverviewItem(token: item.token), item, item.token)
        }
        XCTAssertNil(OverviewItem(token: "nonsense"))
        for p: HubPage in [.allStudents, .yourMove, .student(StudentName.key("Mei Lin"))] { XCTAssertEqual(HubPage(argument: p.token), p) }
        let place = LastPlace(paper: "/synthetic/reef", level: "review", round: 2, comment: "R1-05", tab: "comments", follow: "tag:logic",
                              strip: 3, shownParts: ["appendix"], overviewScroll: 120)
        XCTAssertEqual(LastPlace.parse(place.json()), place)
        XCTAssertNil(LastPlace.parse("{"))
        // opened again: the paper at its level with the overview's place; a paper gone from the list, or its folder,
        // opens nothing (All Students as before)
        let m = try makeModel()
        let folder = dir.appendingPathComponent("paper")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("ledger.json"))
        m.papers.append(PaperRef(path: folder.path, title: "Paper", student: "Mei Lin"))
        XCTAssertFalse(m.openLastPlace(LastPlace(paper: "/nowhere", level: "overview")))
        XCTAssertTrue(m.openLastPlace(LastPlace(paper: folder.path, level: "overview", follow: "round:2", strip: 2)))
        XCTAssertEqual(m.selectedPath, folder.path)
        XCTAssertEqual(m.level, .overview)
        XCTAssertEqual(m.overview.selection, .round(2))
        XCTAssertTrue(m.openLastPlace(LastPlace(hub: "move")))
        XCTAssertEqual(m.hub, .yourMove)
        XCTAssertFalse(m.openLastPlace(LastPlace(hub: "student:nobody")))
    }
}
