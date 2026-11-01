import AppKit
import PDFKit
import SwiftUI
import XCTest
@testable import Paperole

/// Reading marks are optional and off by default (UX.md §18 "Optional"; the advisor's decision, 2026-10-18): the
/// Settings window's toggle, the --reading flag, and every place the marks show, off and on, on the reading fixture
/// (round 2 open: 6 changed paragraphs to read, 2 other edits to check). Synthetic fixtures only.
@MainActor
final class ReadingSettingTests: XCTestCase {
    private var drafts: URL!
    private var windows: [NSWindow] = []

    override func setUpWithError() throws {
        drafts = FileManager.default.temporaryDirectory.appendingPathComponent("pc-setting-drafts-" + UUID().uuidString)
    }

    override func tearDownWithError() throws {
        windows.forEach { $0.close() }
        windows = []
        try? FileManager.default.removeItem(at: drafts)
    }

    private func makeModel(reading: Bool? = nil) -> AppModel {
        _ = NSApplication.shared
        var o = LaunchOptions()
        o.fixture = ReadingTests.fixtures.appendingPathComponent("state-reading.json").path
        o.drafts = drafts.path
        o.reading = reading
        return AppModel(options: o)
    }

    /// The fixture's PDF in a PDF view of its own, in a window never shown, so the bars are drawn.
    private func attachPDF(_ m: AppModel) -> ReviewPDFView {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 900), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        windows.append(window)
        let view = ReviewPDFView(frame: NSRect(x: 0, y: 0, width: 760, height: 900))
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        window.contentView = view
        m.pdf.attach(view)
        m.pdf.update(url: m.pdfURL, key: MarkKey(version: m.stateVersion, showChanges: m.showChanges))
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// The PDF's own right-click menu at a contract point of page 0 (¶4, a changed paragraph, is at y 392–437).
    private func menuTitles(_ view: ReviewPDFView, at x: Double, _ y: Double) throws -> [String] {
        let page = try XCTUnwrap(view.document?.page(at: 0))
        let cb = page.bounds(for: .cropBox)
        view.go(to: PDFDestination(page: page, at: CGPoint(x: 0, y: cb.maxY)))
        view.layoutDocumentView()
        let w = view.convert(view.convert(CGPoint(x: cb.minX + x, y: cb.maxY - y), from: page), to: nil)
        let e = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: w, modifierFlags: [], timestamp: 0,
                                                 windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                                                 clickCount: 1, pressure: 1))
        return view.menu(for: e)?.items.map(\.title) ?? []
    }

    /// The fixture with every carried comment answered and every change checked: nothing left but the paragraphs.
    private func allAnswered() throws -> EngineState {
        let url = ReadingTests.fixtures.appendingPathComponent("state-reading.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["comments"] = (json["comments"] as? [[String: Any]] ?? []).map { c in
            var c = c
            if c["carried"] as? Bool == true, c["verdict"] is NSNull || c["verdict"] == nil { c["verdict"] = "verified" }
            return c
        }
        json["changes"] = (json["changes"] as? [[String: Any]] ?? []).map { c in
            var c = c
            c["checked"] = true
            return c
        }
        return try EngineState.decode(JSONSerialization.data(withJSONObject: json))
    }

    func testTheLaunchFlag() {
        XCTAssertEqual(LaunchOptions.parse(["app", "--reading", "on"]).reading, true)
        let o = LaunchOptions.parse(["app", "--background", "--reading", "off", "--paper", "/a"])
        XCTAssertEqual(o.reading, false)
        XCTAssertEqual(o.paper, "/a")
        XCTAssertNil(LaunchOptions.parse(["app", "--background"]).reading)
        XCTAssertTrue(makeModel(reading: true).readingMarksOn)
        XCTAssertFalse(makeModel(reading: false).readingMarksOn)
    }

    /// Off (the default): no bars, no count with Next and Mark Read, no dots in the Contents, nothing about paragraphs
    /// in the subtitle, the papers list, the done card or the Finish sheet, no reading items in the PDF's menu or Jump,
    /// and N, C and Shift-C are not keys. The Contents, Focus, the Changes tab and the engine's read state stay.
    func testOffByDefault() throws {
        let m = makeModel()
        XCTAssertFalse(m.readingMarksOn)
        let view = attachPDF(m)
        XCTAssertTrue(m.barParagraphs.isEmpty)
        XCTAssertTrue(m.pdf.readingBars.isEmpty, "no bars in the margin")
        XCTAssertNil(m.reading.status.line, "no count, Next or Mark Read in the status line")
        XCTAssertNil(m.unreadCount)
        let rows = m.reading.contents.rows
        XCTAssertEqual(rows.count, 7, "the Contents stay")
        XCTAssertTrue(rows.allSatisfy { !$0.changed && !$0.tracked }, "no dots, no Mark Section Read")
        // the subtitle and the papers list's line
        let s = PaperSummary(round: 2, closed: false, status: "ok", toJudge: 0, toCheck: 0)
        XCTAssertNil(m.withReading(s).unread)
        XCTAssertEqual(m.withReading(s).step, .allChecked)
        XCTAssertEqual(m.withReading(s).subtitle(), "ready to finish")
        // the Finish sheet has no paragraphs row
        let finish = FinishSummary(round: 2, comments: m.state?.comments ?? [], drafts: [:], unrequested: m.toCheck,
                                   unread: m.unreadCount)
        XCTAssertFalse(finish.left.contains { $0.item == .paragraphs })
        // the keys, the PDF's menu and Jump
        XCTAssertFalse(m.keyState.reading)
        for k in ["n", "c", "shift-c"] { XCTAssertNil(KeyRoute.action(k, m.keyState), k) }
        XCTAssertEqual(KeyRoute.action("f", m.keyState), .toggleFocus)
        XCTAssertEqual(KeyRoute.action("j", m.keyState), .next)
        let titles = try menuTitles(view, at: 300, 410)
        XCTAssertFalse(titles.contains("Mark Paragraph Read"), "\(titles)")
        XCTAssertTrue(titles.contains("Add Note Here"), "\(titles)")
        XCTAssertFalse(m.jumpSources().commands.contains { $0.command == .next })
        // a bar's click does nothing (there is none); the read state is the engine's and stays
        m.barClicked(4)
        XCTAssertEqual(m.readBlocks, Set(m.state?.reading?.read ?? []))
        // the Changes tab is unaffected: 2 other edits to check
        XCTAssertEqual(m.toCheck, 2)
        XCTAssertEqual(m.changes.unrequested.filter { !$0.handled }.count, 2)
        // Focus is still the reading mode, without bars
        m.setFocus(true)
        XCTAssertTrue(m.focus)
        XCTAssertTrue(m.pdf.readingBars.isEmpty)
        m.setFocus(false)
        // nothing left but the paragraphs: ready to finish, the done card shown
        m.apply(try allAnswered())
        XCTAssertTrue(m.readyToFinish)
        XCTAssertTrue(m.panel.ready)
    }

    /// On: every place shows the marks, as before the setting (`ReadingStatusTests`).
    func testOn() throws {
        let m = makeModel(reading: true)
        let view = attachPDF(m)
        XCTAssertEqual(m.barParagraphs.map(\.block), [4, 8, 18, 27, 31, 34])
        XCTAssertEqual(Set(m.pdf.readingBars.map(\.block)), [4, 8, 18, 27, 31, 34])
        XCTAssertEqual(m.reading.status.line,
                       ReadingLine(text: "6 changed paragraphs to read", short: "6 to read", bar: true, actions: true))
        XCTAssertEqual(m.reading.contents.rows.filter(\.changed).count, 5)
        let s = PaperSummary(round: 2, closed: false, status: "ok", toJudge: 0, toCheck: 0)
        XCTAssertEqual(m.withReading(s).subtitle(), "6 changed paragraphs to read")
        XCTAssertEqual(m.withReading(s).step, .toRead(6))
        XCTAssertEqual(FinishSummary(round: 2, comments: [], drafts: [:], unrequested: 0, unread: m.unreadCount).left.map(\.item),
                       [.paragraphs])
        XCTAssertTrue(m.keyState.reading)
        XCTAssertEqual(KeyRoute.action("n", m.keyState), .nextUnread)
        XCTAssertEqual(KeyRoute.action("shift-c", m.keyState), .markSectionRead)
        XCTAssertTrue(try menuTitles(view, at: 300, 410).contains("Mark Paragraph Read"))
        m.holdBusy(true)  // as in a closed round: it could not act, so it is left out
        XCTAssertFalse(try menuTitles(view, at: 300, 410).contains("Mark Paragraph Read"))
        m.holdBusy(false)
        XCTAssertTrue(m.jumpSources().commands.contains { $0.command == .next })
        m.apply(try allAnswered())
        XCTAssertFalse(m.readyToFinish, "6 changed paragraphs to read")
        XCTAssertFalse(m.panel.ready)
    }

    /// Turning the setting on shows the marks at once, from the engine's read state (kept while they were off); off
    /// takes them away at once and forgets the paragraph Next went to. A fixture run never saves it.
    func testTurningItOnAndOff() throws {
        let saved = UserDefaults.standard.object(forKey: AppModel.readingMarksKey) as? Bool
        let m = makeModel()
        _ = attachPDF(m)
        m.readingMarksOn = true
        XCTAssertEqual(m.pdf.readingBars.count, 6)
        XCTAssertEqual(m.reading.status.line?.text, "6 changed paragraphs to read")
        m.perform(.nextUnread)
        XCTAssertNotNil(m.currentParagraph)
        m.barClicked(8)
        XCTAssertEqual(m.reading.status.line?.text, "5 changed paragraphs to read")
        m.readingMarksOn = false
        XCTAssertTrue(m.pdf.readingBars.isEmpty)
        XCTAssertNil(m.reading.status.line)
        XCTAssertNil(m.currentParagraph)
        XCTAssertTrue(m.reading.contents.rows.allSatisfy { !$0.changed })
        XCTAssertTrue(m.readBlocks.contains(8), "the read state stays")
        m.readingMarksOn = true
        XCTAssertEqual(m.reading.status.line?.text, "5 changed paragraphs to read")
        XCTAssertEqual(UserDefaults.standard.object(forKey: AppModel.readingMarksKey) as? Bool, saved, "never saved by a test run")
    }

    /// The Settings window's Reading tab: "Mark changed paragraphs to read", a switch that sets the model's setting.
    func testTheSettingsToggle() throws {
        let m = makeModel()
        let host = NSHostingView(rootView: SettingsView(model: m, tab: .reading))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        windows.append(window)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func find<T: NSView>(_ type: T.Type, in v: NSView) -> [T] { ((v as? T).map { [$0] } ?? []) + v.subviews.flatMap { find(type, in: $0) } }
        let toggle = try XCTUnwrap(find(NSSwitch.self, in: host).first, "a switch, as System Settings' toggles")
        XCTAssertEqual(toggle.state, .off)
        toggle.performClick(nil)
        XCTAssertTrue(m.readingMarksOn)
        XCTAssertEqual(m.reading.status.line?.text, "6 changed paragraphs to read")
        XCTAssertEqual(SettingsView.title, "Mark changed paragraphs to read")
    }

    /// The Reading tab's second switch: Checks (UX.md §39), off by default, setting the model's setting.
    func testTheChecksToggle() throws {
        let m = makeModel()
        let host = NSHostingView(rootView: SettingsView(model: m, tab: .reading))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        windows.append(window)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func find<T: NSView>(_ type: T.Type, in v: NSView) -> [T] { ((v as? T).map { [$0] } ?? []) + v.subviews.flatMap { find(type, in: $0) } }
        let switches = find(NSSwitch.self, in: host)
        XCTAssertEqual(switches.count, 2, "reading marks, then Checks")
        XCTAssertFalse(m.checksOn)
        XCTAssertEqual(switches.map(\.state), [.off, .off])
        switches[1].performClick(nil)
        XCTAssertTrue(m.checksOn)
        XCTAssertFalse(m.readingMarksOn)
        XCTAssertEqual(SettingsView.checksTitle, "Checks")
        XCTAssertTrue(SettingsView.checksDetail.hasSuffix("goes to the student with your comments, unless you mark it OK."))
        // the kinds under it, all on by default (a test run reads no saved choice)
        XCTAssertEqual(m.checkKinds, Set(ChecksModel.groups.map(\.id)))
    }
}
