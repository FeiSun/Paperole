import AppKit
import SwiftUI
import XCTest
@testable import Paperole

/// UI v2.1 phase 2 (design/ui-v2.1/POLISH.md §3 rows 2–3, §5, §6): one sidebar with Papers and Contents, the section
/// the PDF is in kept apart from the list's data, the reading count in the status line with Next and Mark Read, a
/// click on a bar marking its paragraph read, and the window's minimum width. Synthetic fixtures only.
final class ContentsTests: XCTestCase {
    func testNumbersInAColumnOfTheirOwn() {
        XCTAssertEqual(Outline.numbers(["1 Introduction", "2.1 LLM Agent Memory", "5.1 Q1: Does Memory Help?", "Limitations",
                                        "References", "A Dataset Details", "A.1 Rule-based Filtering", "B Evaluation"]),
                       ["1", "2.1", "5.1", nil, nil, "A", "A.1", "B"])
        // appendices without subsections: a run from A on
        XCTAssertEqual(Outline.numbers(["7 Conclusion", "A Selective prediction.", "B Limited Coverage", "C Details", "I Prompts"]),
                       ["7", "A", "B", "C", nil])
        // a capital letter that only starts a title keeps it; a number with a dot is a number
        XCTAssertEqual(Outline.numbers(["A Note on Noise", "1. Introduction", "I Background", "Stage 2"]), [nil, "1.", nil, nil])
        XCTAssertEqual(Outline.numbers([]), [])
    }

    func testRowsSplitTheirNumber() {
        let r = ReadingInfo(read: [], count: 1, unread: 1,
                            paragraphs: [Paragraph(block: 1, section: -1, parts: []), Paragraph(block: 3, section: 2, parts: [])],
                            headings: [Heading(block: 2, level: 1, title: "1 Intro"), Heading(block: 4, level: 2, title: "1.1 Sub"),
                                       Heading(block: 6, level: 1, title: "References")])
        let rows = Outline.rows(r, read: [], round: 2)
        XCTAssertEqual(rows.map(\.number), [nil, "1", "1.1", nil])
        XCTAssertEqual(rows.map(\.name), ["Title and abstract", "Intro", "Sub", "References"])
        XCTAssertEqual(rows.map(\.title), ["Title and abstract", "1 Intro", "1.1 Sub", "References"])
    }

    /// The status line's count (POLISH §3 row 3): counting down with Next and Mark Read in an open round; a closed round
    /// says what was left, with no buttons; round 1 has its own words.
    func testTheStatusLineCountsDown() {
        let ps = [1, 3, 5].map { Paragraph(block: $0, section: -1, parts: []) }
        let r = ReadingInfo(read: [1], count: 3, unread: 2, paragraphs: ps)
        XCTAssertEqual(Outline.status(r, read: [1], round: 3, closed: false),
                       ReadingLine(text: "2 changed paragraphs to read", short: "2 to read", bar: true, actions: true))
        XCTAssertEqual(Outline.status(r, read: [1, 3], round: 3, closed: false).text, "1 changed paragraph to read")
        XCTAssertEqual(Outline.status(r, read: [1, 3, 5], round: 3, closed: false),
                       ReadingLine(text: "All changed paragraphs are read", short: "All read", done: true))
        XCTAssertEqual(Outline.status(r, read: [1], round: 2, closed: true),
                       ReadingLine(text: "2 changed paragraphs left unread when Round 2 closed", short: "2 left unread", bar: true))
        XCTAssertEqual(Outline.status(r, read: [], round: 1, closed: false),
                       ReadingLine(text: "Round 1: finishing it marks every paragraph read", short: "Round 1"))
    }

    /// The paragraph Next went to has a bolder bar, 1 pt wider outwards, never towards the text (POLISH §3 row 3).
    func testTheParagraphNextWentToHasABolderBar() {
        let left = PageRect(page: 1, rect: [70.87, 74.43, 289.13, 246.78]), right = PageRect(page: 1, rect: [306.14, 74.43, 524.41, 111.29])
        let tx = [70.47, 526.22]
        XCTAssertEqual(Reading.bar(left, textX: tx, gap: 298.34, bold: true)[0], 64.47, accuracy: 1e-9)
        XCTAssertEqual(Reading.bar(left, textX: tx, gap: 298.34, bold: true)[2], 67.47, accuracy: 1e-9)
        XCTAssertEqual(Reading.bar(right, textX: tx, gap: 298.34, bold: true)[0], 529.22, accuracy: 1e-9)
        XCTAssertEqual(Reading.bar(right, textX: tx, gap: 298.34, bold: true)[2], 532.22, accuracy: 1e-9)
    }

    /// A click on a bar counts 8 view points wide, but never on the text 3 pt beside it (POLISH §6).
    func testABarsClickArea() {
        let left = CGRect(x: 102.25, y: 200, width: 2, height: 100)  // text from x 107.25
        let a = MarkHit.barArea(left, textRight: true, minSize: 8)
        XCTAssertEqual(a.minX, 99.25)
        XCTAssertEqual(a.maxX, 106.75)  // 3 pt of growth asked for, 2.5 given: the text starts 0.5 pt further on
        XCTAssertEqual([a.minY, a.maxY], [199, 301])
        let zoomedOut = MarkHit.barArea(left, textRight: true, minSize: 16)  // 8 view points at half size
        XCTAssertEqual(zoomedOut.minX, 95.25)
        XCTAssertLessThan(zoomedOut.maxX, 107.25)
        let right = MarkHit.barArea(CGRect(x: 508.75, y: 0, width: 2, height: 10), textRight: false, minSize: 8)
        XCTAssertEqual(right.minX, 506.25)  // the text ends at 505.75
        XCTAssertEqual(right.maxX, 513.75)
        XCTAssertEqual(MarkHit.barArea(left, textRight: true, minSize: 1).width, 2, "never narrower than the bar")
    }

    func testTheWindowFitsThreePanesAtItsMinimum() {
        XCTAssertEqual(WindowLayout.window, WindowLayout.sidebar + WindowLayout.review)
        XCTAssertGreaterThanOrEqual(WindowLayout.review, WindowLayout.pdf + WindowLayout.panel)
        XCTAssertEqual(WindowLayout.window, 960)
        XCTAssertLessThanOrEqual(WindowLayout.sidebar, WindowLayout.sidebarIdeal)
    }
}

/// The section the PDF is in lives in its own object (POLISH §5): a new section redraws the row it leaves and the row
/// it enters, never the others.
@MainActor
final class CurrentSectionTests: XCTestCase {
    func testOnlyTheRowsLeftAndEnteredRedraw() throws {
        _ = NSApplication.shared
        let current = CurrentSection()
        let rows = (0..<6).map { OutlineRow(block: $0 * 10, title: "\($0) S", number: "\($0)", name: "S", level: 1,
                                            range: $0 * 10..<$0 * 10 + 10, read: 0, count: 0, open: 0, changed: false, tracked: true) }
        let host = NSHostingView(rootView: VStack { ForEach(rows) { ContentsRow(row: $0, look: current.look($0.block)) } })
        host.frame = NSRect(x: 0, y: 0, width: 240, height: 200)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(BodyCount.section, 6)
        var before = BodyCount.section
        current.set(20)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(BodyCount.section - before, 1, "the row entered")
        before = BodyCount.section
        current.set(30)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(BodyCount.section - before, 2, "the row left and the row entered")
        before = BodyCount.section
        current.set(30)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(BodyCount.section - before, 0, "the same section: nothing")
        XCTAssertEqual(current.block, 30)
        XCTAssertTrue(current.look(30).current)
        XCTAssertFalse(current.look(20).current)
        XCTAssertTrue(CurrentSection().look(5).current == false)
        window.close()
    }
}

/// On the reading fixture (round 2 open: 6 changed paragraphs to read), with reading marks on (Settings; they are off
/// by default, `ReadingSettingTests`).
@MainActor
final class ReadingStatusTests: XCTestCase {
    private var drafts: URL!

    override func setUpWithError() throws {
        drafts = FileManager.default.temporaryDirectory.appendingPathComponent("pc-sidebar-drafts-" + UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: drafts)
    }

    private func makeModel() -> AppModel {
        _ = NSApplication.shared
        var o = LaunchOptions()
        o.fixture = ReadingTests.fixtures.appendingPathComponent("state-reading.json").path
        o.drafts = drafts.path
        o.reading = true
        return AppModel(options: o)
    }

    func testTheContentsAndTheStatusLine() {
        let m = makeModel()
        XCTAssertEqual(m.reading.contents.rows.map(\.number), [nil, "1", "2", "3", "4", "5", nil])
        XCTAssertTrue(m.reading.contents.canMark)
        XCTAssertNil(m.reading.contents.message)
        XCTAssertEqual(m.reading.status.line,
                       ReadingLine(text: "6 changed paragraphs to read", short: "6 to read", bar: true, actions: true))
        m.outlineFollow(12)
        XCTAssertEqual(m.reading.current.block, 10, "3 Method")
        XCTAssertTrue(m.reading.current.look(10).current)
        // a paper switch clears them until its state comes
        m.selectPaper(nil)
        XCTAssertEqual(m.reading.contents.rows, [])
        XCTAssertNil(m.reading.status.line)
        XCTAssertNil(m.reading.current.block)
    }

    /// A click on a bar marks its paragraph read (POLISH §6); the status line counts down, with no toast.
    func testAClickOnABarMarksItRead() {
        let m = makeModel()
        XCTAssertFalse(m.readBlocks.contains(8))
        m.barClicked(8)
        XCTAssertTrue(m.readBlocks.contains(8))
        XCTAssertEqual(m.reading.status.line?.text, "5 changed paragraphs to read")
        XCTAssertNil(m.reading.toast)
        m.barClicked(8)  // read already (its bar is gone): nothing
        m.barClicked(1)  // a paragraph without a bar: nothing
        XCTAssertEqual(m.unreadCount, 5)
        for b in [4, 18, 27, 31, 34] { m.barClicked(b) }
        XCTAssertEqual(m.reading.status.line, ReadingLine(text: "All changed paragraphs are read", short: "All read", done: true))
        // un-reading stays in the menus
        m.markParagraph(8, read: false)
        XCTAssertEqual(m.reading.status.line?.text, "1 changed paragraph to read")
    }

    /// Next counts down in the status line, not in a toast (each number once, POLISH §4.4); Mark Read with nothing to
    /// act on says what to click.
    func testNextAndMarkReadSpeakMouseFirst() {
        let m = makeModel()
        m.perform(.markRead)
        XCTAssertEqual(m.reading.toast, "Click Next to go to a changed paragraph, or select text in one first.")
        m.reading.toast = nil
        m.perform(.nextUnread)
        XCTAssertNotNil(m.currentParagraph)
        XCTAssertNil(m.reading.toast)
    }
}
