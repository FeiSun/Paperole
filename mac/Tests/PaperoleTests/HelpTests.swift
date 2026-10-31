import AppKit
import SwiftUI
import XCTest
@testable import Paperole

/// Help and the tips (UI v4 step 8; UX.md §40.7): the Help menu, the topic of the page in front, the search field's
/// Help Topics, one "?" per overview page, About This Chart on every tile, everything that left the pages in Help, and
/// the two one-time tips.
@MainActor
final class HelpTests: XCTestCase {
    private var drafts: URL!

    override func setUpWithError() throws {
        drafts = FileManager.default.temporaryDirectory.appendingPathComponent("help-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: drafts, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: drafts)
    }

    private func spin(_ s: Double = 0.1) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    private func makeModel() -> AppModel {
        _ = NSApplication.shared
        var o = LaunchOptions()
        o.fixture = StepTests.fixtures.appendingPathComponent("state-m2a.json").path
        o.overviewFixture = OverviewDataTests.fixture.path
        o.level = .overview
        o.drafts = drafts.path
        o.cache = drafts.appendingPathComponent("cache").path
        return AppModel(options: o)
    }

    private func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Paperole/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The menu (BRIEF §8, 08): Paperole Help ⌘?, Keyboard Shortcuts, a separator, Show Tips Again; nothing else.
    /// The scene's menu is not built under XCTest: its items are `HelpMenu.items` (the live menu: `menubar Help/`).
    func testTheMenu() throws {
        XCTAssertEqual(HelpMenu.items.map(HelpMenu.title), ["Paperole Help", "Keyboard Shortcuts", "-", "Show Tips Again"])
        let app = try source("App.swift"), help = try source("Help.swift")
        XCTAssertTrue(app.contains("CommandGroup(replacing: .help) { HelpCommands(model: model) }"), "the system's items replaced")
        XCTAssertTrue(help.contains(".keyboardShortcut(\"?\", modifiers: .command)"), "⌘?")
        XCTAssertEqual(HelpTopic.allCases.map(\.title), ["Getting Started", "Reading the Paper Map", "Following and Review",
                                                         "The Student Page", "All Students and Your Move", "Status Signs",
                                                         "Keyboard Shortcuts"])
    }

    /// ⌘? opens the topic of the page in front.
    func testTheTopicOfThePageInFront() {
        XCTAssertEqual(HelpTopic.of(hub: .allStudents, level: nil), .allStudents)
        XCTAssertEqual(HelpTopic.of(hub: .yourMove, level: .review), .allStudents, "the hub's page wins")
        XCTAssertEqual(HelpTopic.of(hub: .student("maya chen"), level: nil), .studentPage)
        XCTAssertEqual(HelpTopic.of(hub: nil, level: .overview), .paperMap)
        XCTAssertEqual(HelpTopic.of(hub: nil, level: .review), .following)
        XCTAssertEqual(HelpTopic.of(hub: nil, level: nil), .gettingStarted)
        let m = makeModel()
        XCTAssertEqual(m.helpTopic, .paperMap)
        m.openHelp()
        XCTAssertEqual(m.help.topic, .paperMap, "a test run sets the topic and opens no window")
        m.openHelp(.studentPage, section: "Turnaround")
        XCTAssertEqual(m.help.section, "Turnaround")
        XCTAssertEqual(HelpTopic(argument: "\"The Student Page\""), .studentPage)
        XCTAssertEqual(HelpTopic(argument: "statusSigns"), .statusSigns)
    }

    /// The Help menu's search field (`NSUserInterfaceItemSearching`) lists "Turnaround" under Help Topics.
    func testTheSearchFindsTurnaround() {
        var found: [Any] = []
        HelpSearch.shared.searchForItems(withSearch: "turnaround", resultLimit: 10) { found = $0 }
        let titles = found.flatMap { HelpSearch.shared.localizedTitles(forItem: $0) }
        XCTAssertEqual(titles.first, "Turnaround", "the section named so first")
        XCTAssertEqual(Set(titles).count, titles.count, "one hit per name")
        XCTAssertEqual((found.first as? HelpHit)?.topic, .studentPage)
        HelpSearch.shared.searchForItems(withSearch: "", resultLimit: 10) { found = $0 }
        XCTAssertTrue(found.isEmpty)
    }

    /// One "?" per overview page: at the end of the hub's page (All Students, Your Move, a student) and of the paper's
    /// overview, nowhere else.
    func testOneHelpLinkPerPage() throws {
        let hub = try source("HubViews.swift"), overview = try source("OverviewViews.swift")
        XCTAssertEqual(hub.components(separatedBy: "PageHelpLink(").count - 1, 1)
        XCTAssertTrue(hub.contains("PageHelpLink(model: model, topic: HelpTopic.of(hub: page, level: nil))"))
        XCTAssertEqual(overview.components(separatedBy: "PageHelpLink(").count - 1, 1)
        XCTAssertTrue(overview.contains("PageHelpLink(model: model, topic: .paperMap)"))
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Paperole")
        let others = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { !["HubViews.swift", "OverviewViews.swift", "Help.swift"].contains($0.lastPathComponent) }
            .filter { (try? String(contentsOf: $0, encoding: .utf8).contains("HelpLink")) == true }
        XCTAssertEqual(others.map(\.lastPathComponent), [])
    }

    /// Every tile's context menu starts with About This Chart, which opens its row in The Student Page.
    func testEveryTileHasAboutThisChart() throws {
        let s = try source("StudentTiles.swift")
        let start = try XCTUnwrap(s.range(of: "struct StudentTileView"))
        let end = try XCTUnwrap(s.range(of: "struct BySectionChart", range: start.upperBound..<s.endIndex))
        let view = String(s[start.upperBound..<end.lowerBound])
        let menus = view.components(separatedBy: ".contextMenu {").dropFirst()
        XCTAssertEqual(menus.count, StudentTiles.Kind.allCases.count, "one menu per tile")
        for m in menus { XCTAssertEqual(m.trimmingCharacters(in: .whitespacesAndNewlines).prefix(5), "about", "About This Chart first") }
        XCTAssertTrue(view.contains("Button(\"About This Chart\") { model.openHelp(.studentPage, section: kind.helpSection) }"))
        let rows = HelpContent.studentPage.map(\.title)
        for k in StudentTiles.Kind.allCases { XCTAssertTrue(rows.contains(k.helpSection), k.helpSection) }
    }

    /// Every caption, footnote and key that left the pages is in Help (the advisor's rule: nothing is dropped).
    func testWhatLeftThePagesIsInHelp() {
        let all = HelpTopic.allCases.flatMap(HelpContent.sections).map(\.text).joined(separator: "\n")
        for t in HelpText.studentPage { XCTAssertTrue(all.contains(t.text), t.topic) }
        for t in HelpText.hub { XCTAssertTrue(all.contains(t.text), t.topic) }
        for i in MapKey.items { XCTAssertTrue(all.contains(i.1), i.0) }
        XCTAssertTrue(all.contains(OverviewTip.text))
        XCTAssertTrue(all.contains(AnswerTip.text))
        XCTAssertEqual(HelpContent.studentPage.count, 7, "the mockup's seven rows")
        XCTAssertEqual(HelpContent.lead(.studentPage),
                       "One student’s papers and rounds, never compared with other students. Each comment belongs to the round it was written in.")
        XCTAssertTrue(HelpContent.lead(.allStudents).hasPrefix("A paper comes to Your Move when a student’s round comes in"))
        let signs = HelpContent.statusSigns.map(\.title)
        XCTAssertTrue(signs.contains("Nothing waits") && signs.contains("Ready to finish"), "told apart")
        for t in HelpTopic.allCases { XCTAssertFalse(HelpContent.sections(t).isEmpty, t.title) }
    }

    /// The tips are a set of ids seen: the legacy key reads as Answer seen until `tipsSeen` is written; Show Tips Again
    /// clears it; a fixture run never remembers; Got it or the first follow dismisses Follow anything.
    func testTheTips() throws {
        XCTAssertEqual(Tips.seen(stored: nil, legacy: true), [.answer], "the legacy key")
        XCTAssertEqual(Tips.seen(stored: nil, legacy: nil), [])
        XCTAssertEqual(Tips.seen(stored: [], legacy: true), [], "after Show Tips Again, the legacy key is not read")
        XCTAssertEqual(Tips.seen(stored: ["follow", "nonsense"], legacy: true), [.follow])

        let before = UserDefaults.standard.object(forKey: "tipsSeen") as? [String]
        let t = Tips()
        t.load(remember: false)
        XCTAssertTrue(t.answer && t.follow)
        t.dismiss(.follow)
        XCTAssertFalse(t.follow)
        XCTAssertTrue(t.answer, "one tip at a time")
        t.dismiss()
        XCTAssertFalse(t.answer, "the old form is Answer's")
        t.showAgain()
        XCTAssertTrue(t.answer && t.follow)
        XCTAssertEqual(UserDefaults.standard.object(forKey: "tipsSeen") as? [String], before, "a fixture run never remembers")

        let m = makeModel()
        XCTAssertTrue(m.actions.tips.follow)
        m.overviewClicked(nil)
        XCTAssertTrue(m.actions.tips.follow, "a click on nothing follows nothing")
        m.overviewClicked(.round(2))
        XCTAssertFalse(m.actions.tips.follow, "the first follow")
        XCTAssertTrue(m.actions.tips.answer)
    }

    /// The paper map's tip sits under the bottom row from its first cell, its arrow at the second cell; as a table
    /// it has no arrow. Shown, it pushes what is under it down; Got it takes it away.
    func testTheFollowTip() throws {
        let d = try XCTUnwrap(makeModel().overview.data)
        let scene = MapScene.build(MapInput(data: d, width: 900))
        let row = try XCTUnwrap(scene.rows.last)
        let place = OverviewTip.place(scene)
        XCTAssertEqual(place.x0, row.cells[0].rect.minX)
        XCTAssertEqual(place.arrow, row.cells[1].rect.midX)
        XCTAssertNil(OverviewTip.place(nil).arrow)

        let tips = Tips()
        func height() -> CGFloat {
            let host = NSHostingView(rootView: VStack(spacing: 0) {
                OverviewTip(tips: tips, x0: place.x0, arrow: place.arrow)
                Color.clear.frame(height: 10)
            }.frame(width: 900))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 300), styleMask: [.titled],
                                  backing: .buffered, defer: true)  // never ordered in
            window.isReleasedWhenClosed = false
            window.contentView = host
            spin()
            defer { window.close() }
            return host.fittingSize.height
        }
        let shown = height()
        XCTAssertGreaterThan(shown, 60, "title, sentence, padding and the arrow")
        tips.dismiss(.follow, remember: false)
        XCTAssertEqual(height(), 10, accuracy: 0.5, "gone after Got it")
    }

    /// The Help window draws every topic (its pictures from the app's own views) in both appearances.
    func testTheWindowDrawsEveryTopic() {
        _ = NSApplication.shared
        let help = HelpModel()
        for dark in [false, true] {
            for t in HelpTopic.allCases {
                help.topic = t
                let host = NSHostingView(rootView: HelpPage(topic: t).frame(width: 760, height: 700))
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 700), styleMask: [.titled],
                                      backing: .buffered, defer: true)
                window.isReleasedWhenClosed = false
                window.contentView = host
                spin(0.05)
                XCTAssertEqual(host.fittingSize.width, 760, accuracy: 1, t.title)
                window.close()
            }
        }
    }
}
