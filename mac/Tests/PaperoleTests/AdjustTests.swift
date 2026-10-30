import AppKit
import SwiftUI
import XCTest
@testable import Paperole

/// UI v2.1 after the advisor's use (design/ui-v2.1/POLISH.md §7, 2026-10-18): group headers that read as headers,
/// rows that visibly step back while a card is expanded, and "Still loading…" when the engine is busy (O27). Focus's
/// panel is in FocusJumpTests. Synthetic fixtures only.
@MainActor
final class GroupHeaderTests: XCTestCase {
    private var drafts: URL!

    override func setUpWithError() throws {
        drafts = FileManager.default.temporaryDirectory.appendingPathComponent("pc-adjust-drafts-" + UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: drafts)
    }

    private func makeModel() -> AppModel {
        _ = NSApplication.shared
        var o = LaunchOptions()
        o.fixture = StepTests.fixtures.appendingPathComponent("state-m2a.json").path
        o.drafts = drafts.path
        return AppModel(options: o)
    }

    /// Each group's header has its sign, its name without the count, the folded groups' count in a capsule, the quieter
    /// words apart, and a gap above it unless it starts the list; To check has no count (the tab says it, POLISH §4.4).
    func testHeadersHaveSignsCountsAndGaps() throws {
        let m = makeModel()
        let list = CommentListController(panel: m.panel, actions: m.actions, edit: m.edit)
        let g = m.panel.groups
        XCTAssertFalse(g.toCheck.isEmpty || g.forStudent.isEmpty || g.closed.isEmpty, "the fixture has all three groups")
        let headers = list.table.headers.map { $0.map { "\($0)" } }
        XCTAssertEqual(headers, [
            ["To check", "<null>", "", "circle", "<null>"],
            ["For the student", "\(g.forStudent.count)", "goes in the Round 2 final.pdf", "envelope", "Show"],
            ["Closed this round", "\(g.closed.count)", "", "checkmark.circle", "Show"],
        ])
        let rows = list.rows()
        XCTAssertTrue(rows.first?.isHeader == true, "no gap on top")
        for (i, r) in rows.enumerated() where r.isHeader && i > 0 {
            XCTAssertEqual(rows[i - 1], .gap, "a gap above the header at \(i)")
        }
        XCTAssertEqual(rows.filter { $0 == .gap }.count, 2)
        XCTAssertFalse(list.table.listed.contains("gap"), "gaps are not listed")
        XCTAssertEqual(list.table.listed.filter { $0.hasPrefix("header: ") },
                       ["header: To check", "header: For the student · \(g.forStudent.count)",
                        "header: Closed this round · \(g.closed.count)"])
        withExtendedLifetime(list) {}
    }

    /// In a closed round To check is Left open, its sign grey (no amber: nothing is the advisor's move).
    func testLeftOpenIsGrey() {
        XCTAssertEqual(HeaderGlyph.toCheck(open: true).color, Color(nsColor: Palette.toCheck))
        XCTAssertEqual(HeaderGlyph.toCheck(open: false).color, Color(nsColor: Palette.neutral))
        XCTAssertEqual(HeaderGlyph.student.symbol, "envelope")
        XCTAssertEqual(HeaderGlyph.closed.symbol, "checkmark.circle")
        XCTAssertNil(HeaderGlyph.none.symbol)
        for g in [HeaderGlyph.toCheck(open: true), .student, .closed, .answering] {
            XCTAssertNotNil(NSImage(systemSymbolName: g.symbol ?? "", accessibilityDescription: nil), "\(g)")
        }
    }

    /// The Changes tab's headers look the same, without numbers (the sentence on top says them, UX.md §16).
    func testTheChangesTabHasTheSameHeaders() throws {
        let m = makeModel()
        m.changes.showLinked = false
        let list = ChangeListController(panel: m.changes, actions: m.actions, edit: m.edit)
        let headers = list.table.headers.map { $0.map { "\($0)" } }
        XCTAssertEqual(headers.first, ["To check", "<null>", "", "circle", "<null>"])
        XCTAssertEqual(headers.last, ["Answering your comments", "<null>", "", "text.bubble", "Show"])
        withExtendedLifetime(list) {}
    }

    func testGapsGoAboveHeadersButTheFirstAndUnderTheDoneCard() throws {
        let item = PanelTable.Row.item(.card(CardModel(try makeComment(["id": "R1-01"]), round: 2, pdfs: [:], textX: [],
                                                       showChanges: true)))
        let fold = PanelTable.Row.fold("Closed this round", "Show", group: .closed, count: 2)
        XCTAssertEqual(PanelTable.spaced([.header("To check"), item, fold, .fold("For the student", "Show", group: .student)]),
                       [.header("To check"), item, .gap, fold, .gap, .fold("For the student", "Show", group: .student)])
        XCTAssertEqual(PanelTable.spaced([.done(round: 3), .header("For the student"), .hint("h"), fold]),
                       [.done(round: 3), .header("For the student"), .hint("h"), .gap, fold])
    }

    /// The header is 34 pt, taller than before (26) and than a closed line (30), the gap 10.
    func testHeaderAndGapHeights() throws {
        XCTAssertEqual(PanelScroller.header, 34)
        let (table, window) = makeTable()
        table.show([.header("To check")] + (try items(["R1-01", "R1-02"])) + [.gap, .fold("Closed this round", "Show", group: .closed)])
        let tv = try XCTUnwrap(table.scrollView.documentView as? NSTableView)
        XCTAssertEqual(tv.rect(ofRow: 0).height, 34)
        XCTAssertEqual(tv.rect(ofRow: 3).height, 10)
        XCTAssertEqual(tv.rect(ofRow: 4).height, 34)
        window.close()
    }

    private func items(_ ids: [String]) throws -> [PanelTable.Row] {
        try ids.map { .item(.card(CardModel(try makeComment(["id": $0]), round: 2, pdfs: [:], textX: [], showChanges: true))) }
    }

    private func makeTable() -> (PanelTable, NSWindow) {
        _ = NSApplication.shared
        let table = PanelTable(scroller: PanelScroller(), expanded: nil, compact: { _, _ in AnyView(Color.clear) },
                               expandedView: { _ in AnyView(Color.gray.frame(height: 200)) })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: true)  // never ordered in
        window.isReleasedWhenClosed = false
        window.contentView = table.scrollView
        table.scrollView.layoutSubtreeIfNeeded()
        return (table, window)
    }

    /// A folded group's whole header is its button: a click on its name folds it, once, also for a double click; a
    /// header that does not fold takes no click.
    func testTheWholeHeaderFoldsItsGroupOnce() throws {
        let (table, window) = makeTable()
        var folds: [FoldedGroup] = []
        table.onFold = { folds.append($0) }
        table.show([.header("To check")] + (try items(["R1-01", "R1-02"])) + [.gap, .fold("Closed this round", "Show", group: .closed, count: 2)])
        let frame = try XCTUnwrap(table.foldFrame(.closed))
        let p = CGPoint(x: frame.minX + 60, y: frame.midY)  // on its name, away from Show
        let host = try XCTUnwrap(window.contentView?.superview?.hitTest(p) as? HeaderHost)
        func event(_ type: NSEvent.EventType, clicks: Int) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
        }
        NSApp.postEvent(event(.leftMouseUp, clicks: 1), atStart: false)  // the press is tracked to its mouse-up
        host.mouseDown(with: event(.leftMouseDown, clicks: 1))
        XCTAssertEqual(folds, [.closed])
        host.mouseDown(with: event(.leftMouseDown, clicks: 2))  // a double click's second click
        XCTAssertEqual(folds, [.closed], "folded once")
        XCTAssertFalse(host.state.pressed)
        let plain = try XCTUnwrap(table.rowFrameOfHeader(0))
        let plainHost = window.contentView?.superview?.hitTest(CGPoint(x: plain.minX + 60, y: plain.midY))
        XCTAssertNil((plainHost as? HeaderHost)?.onClick, "To check does not fold")
        window.close()
    }

    /// The pointer over a folded group's header shows the rows' hover fill; never over one that does not fold.
    func testTheHoverFillIsForFoldingHeadersOnly() {
        func bitmap(_ v: some View) -> Data {
            let host = NSHostingView(rootView: v.frame(width: 380))
            host.frame = NSRect(x: 0, y: 0, width: 380, height: PanelScroller.header)
            host.layoutSubtreeIfNeeded()
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            return rep.tiffRepresentation ?? Data()
        }
        _ = NSApplication.shared
        let idle = HeaderState(), over = HeaderState()
        over.hovering = true
        XCTAssertNotEqual(bitmap(SectionHeader(text: "Closed this round", count: 2, glyph: .closed, button: "Show", state: idle)),
                          bitmap(SectionHeader(text: "Closed this round", count: 2, glyph: .closed, button: "Show", state: over)))
        XCTAssertEqual(bitmap(SectionHeader(text: "To check", glyph: .toCheck(open: true), state: idle)),
                       bitmap(SectionHeader(text: "To check", glyph: .toCheck(open: true), state: over)))
    }
}

/// Review 2026-10-18: a header's edges are the rows' edges. Measured on the drawn header and row, as the list draws them
/// (its 10 pt each side): where the ink starts and ends.
@MainActor
final class HeaderAlignmentTests: XCTestCase {
    private static let width: CGFloat = 380

    /// The columns (in points from the panel's edge) holding ink in the band `y`, a pixel counted as ink when it is
    /// far enough from the panel's grey.
    private func inkColumns(_ view: some View, height: CGFloat, y: Range<CGFloat>) -> [CGFloat] {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: AnyView(view.frame(width: Self.width, height: height)
            .background(Color(nsColor: Palette.panel))))
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(x: 0, y: 0, width: Self.width, height: height)
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        let s = CGFloat(rep.pixelsWide) / Self.width
        let ground = rep.colorAt(x: 2, y: Int(height * s / 2))!.usingColorSpace(.sRGB)!
        var columns: [CGFloat] = []
        for x in 0..<rep.pixelsWide {
            let inked = (Int(y.lowerBound * s)..<Int(y.upperBound * s)).contains { yy in
                guard let c = rep.colorAt(x: x, y: yy)?.usingColorSpace(.sRGB) else { return false }
                return max(abs(c.redComponent - ground.redComponent), abs(c.greenComponent - ground.greenComponent),
                           abs(c.blueComponent - ground.blueComponent)) > 0.2
            }
            if inked { columns.append(CGFloat(x) / s) }
        }
        return columns
    }

    /// The first ink of each run of ink, runs apart by more than `gap` points.
    private func runs(_ columns: [CGFloat], gap: CGFloat = 2.5) -> [CGFloat] {
        var starts: [CGFloat] = []
        var last = -CGFloat.infinity
        for x in columns {
            if x - last > gap { starts.append(x) }
            last = x
        }
        return starts
    }

    private func header(_ text: String, _ glyph: HeaderGlyph, button: String? = nil) -> [CGFloat] {
        inkColumns(SectionHeader(text: text, glyph: glyph, button: button, state: HeaderState()), height: PanelScroller.header,
                   y: 8..<26)
    }

    func testTheHeadersEdgesAreTheRows() throws {
        let card = CardModel(try makeComment(["id": "R1-21", "note": "Define SPL at first use."]), round: 2, pdfs: [:],
                             textX: [], showChanges: true)
        let row = CompactRow(card: card, look: RowLook()).padding(.horizontal, 10)  // as CommentListController lists it
        // the row's first line (sign, id; the bar hangs left of 22) and its note
        let line = inkColumns(row, height: 44, y: 6..<20).filter { $0 >= 22 }
        let note = inkColumns(row, height: 44, y: 26..<38).filter { $0 >= 22 }
        let chip = try XCTUnwrap(line.first), id = try XCTUnwrap(runs(line).dropFirst().first)
        let noteStart = try XCTUnwrap(note.first), page = try XCTUnwrap(line.last)
        XCTAssertEqual(chip, noteStart, accuracy: 1.5, "the row's sign and note start together")
        var names: [CGFloat] = []
        for (text, glyph) in [("To check", HeaderGlyph.toCheck(open: true)), ("For the student", .student),
                              ("Closed this round", .closed), ("Answering your comments", .answering)] {
            let ink = header(text, glyph)
            let sign = try XCTUnwrap(ink.first), name = try XCTUnwrap(runs(ink, gap: 3).dropFirst().first)
            XCTAssertEqual(sign, chip, accuracy: 1, "\(text): its sign over the rows' signs and notes")
            XCTAssertGreaterThan(name, id, "\(text): its name right of the ids, clear of the widest sign")
            names.append(name)
        }
        XCTAssertLessThanOrEqual((names.max() ?? 0) - (names.min() ?? 0), 1, "every header's name starts at one place")
        // Show › ends where the rows' page numbers end
        let show = try XCTUnwrap(header("Closed this round", .closed, button: "Show").last)
        XCTAssertEqual(show, page, accuracy: 1.5)
        XCTAssertEqual(SectionHeader.lead, 26)
    }
}

/// POLISH §7: the rows other than the expanded card fade as a whole, visibly but slightly, in Light and Dark Mode; the
/// pointer shows a row as it is. Measured on the drawn row: the note's ink, its distance from the panel's grey.
@MainActor
final class RowDimmingTests: XCTestCase {
    /// How far the note's text is from the panel, the plain row's as 1, in the given appearance: dimmed, and dimmed
    /// under the pointer; and the page's ("p.2", secondary already), dimmed.
    private func inkDistances(_ name: NSAppearance.Name) throws -> (dimmed: Double, hovered: Double, page: Double) {
        _ = NSApplication.shared
        let card = CardModel(try makeComment(["note": "Define SPL at first use and give the units everywhere."]), round: 2,
                             pdfs: [:], textX: [], showChanges: true)
        let look = RowLook()
        let host = NSHostingView(rootView: AnyView(CompactRow(card: card, look: look).background(Color(nsColor: Palette.panel))))
        host.appearance = NSAppearance(named: name)
        host.frame = NSRect(x: 0, y: 0, width: 380, height: 44)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: name)
        window.contentView = host
        defer { window.close() }
        let dark = name == .darkAqua
        // the panel's grey and the note's most inked pixel (the brightest in Dark Mode, the darkest in Light), as luma
        func ink(x: Range<Double> = 30..<330, y: Range<Double> = 25..<40) -> (ink: Double, ground: Double) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            host.layoutSubtreeIfNeeded()
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            let s = Double(rep.pixelsHigh) / 44
            var lumas: [Double] = []
            for y in Int(y.lowerBound * s)..<Int(y.upperBound * s) {
                for x in Int(x.lowerBound * s)..<Int(x.upperBound * s) {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    lumas.append(0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent)
                }
            }
            lumas.sort()
            let ground = lumas[lumas.count / 2]
            return (dark ? lumas.last! : lumas.first!, ground)
        }
        let page = (x: 330.0..<372.0, y: 3.0..<21.0)
        let plain = ink(), plainPage = ink(x: page.x, y: page.y)
        look.dimmed = true
        let dimmed = ink(), dimmedPage = ink(x: page.x, y: page.y)
        look.hovering = true
        let hovered = ink()
        return (abs(dimmed.ink - dimmed.ground) / abs(plain.ink - plain.ground),
                abs(hovered.ink - hovered.ground) / abs(plain.ink - plain.ground),
                abs(dimmedPage.ink - dimmedPage.ground) / abs(plainPage.ink - plainPage.ground))
    }

    func testADimmedRowStepsBackInLightAndDark() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let d = try inkDistances(name)
            // the row's opacity: visibly lighter (the secondary grey it had before was not seen as dimmed), still
            // well readable
            XCTAssertLessThan(d.dimmed, 0.75, "\(name.rawValue): visibly dimmed")
            XCTAssertGreaterThan(d.dimmed, 0.45, "\(name.rawValue): only slightly")
            XCTAssertGreaterThan(d.hovered, 0.9, "\(name.rawValue): the pointer shows it as it is")
            // the whole row steps back, its secondary words too (before, only the note and id changed colour)
            XCTAssertLessThan(d.page, 0.75, "\(name.rawValue): the page number fades with it")
        }
        XCTAssertEqual(RowLook.opacity(.light), 0.66)
        XCTAssertEqual(RowLook.opacity(.dark), 0.55)
    }
}

/// O27, POLISH §7: an answer or comment action while the engine works says "Still loading…" and is not kept for later;
/// moving through the list never waits.
@MainActor
final class BusyTests: XCTestCase {
    private var drafts: URL!

    override func setUpWithError() throws {
        drafts = FileManager.default.temporaryDirectory.appendingPathComponent("pc-busy-drafts-" + UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: drafts)
    }

    private func makeModel() -> AppModel {
        _ = NSApplication.shared
        var o = LaunchOptions()
        o.fixture = StepTests.fixtures.appendingPathComponent("state-m2a.json").path
        o.drafts = drafts.path
        return AppModel(options: o)
    }

    func testAnswersWhileBusySayStillLoading() throws {
        let m = makeModel()
        m.select(.comment("R1-05"))
        XCTAssertNil(m.comment("R1-05")?.verdict)
        m.holdBusy(true)
        XCTAssertTrue(m.busy)
        let refused: [(String, () -> Void)] = [
            ("V", { m.perform(.verdict("verified")) }),
            ("Keep as is", { m.actions.press("wontfix", "R1-05") }),
            ("⌘↩", { m.sendDraft("R1-05", advance: true) }),
            ("⌘Z", { m.undo() }),
            ("⇧⌘Z", { m.redo() }),
            ("3", { m.setStyle("R1-05", color: .blue) }),
            ("Mark checked", { m.toggleChecked("c06") }),
            ("Comment on it…", { m.commentOnChange("c06") }),
            ("Delete", { m.requestDelete("R2-02") }),
        ]  // Edit Note and Re-anchor… start while it works: only their saving waits (BusyEditorTests)
        for (name, action) in refused {
            m.clearPanelToast()
            action()
            // in the panel's toast, by the card's buttons (review 2026-10-18: over the PDF it was far from the click)
            XCTAssertEqual(m.panelToast.text, AppModel.stillLoading, name)
            XCTAssertNil(m.panelToast.action, "\(name): nothing to undo")
            XCTAssertNil(m.reading.toast, "\(name): not over the PDF")
        }
        XCTAssertNil(m.comment("R1-05")?.verdict)
        XCTAssertNil(m.alertMessage, "nothing went to the engine (a fixture run would say it is not running)")
        XCTAssertNil(m.edit.focusRequest)
        XCTAssertNil(m.edit.field)
        XCTAssertNil(m.confirmDelete)
        XCTAssertNil(m.toolbar.reanchor)
        // the list never waits
        m.clearPanelToast()
        m.perform(.next)
        XCTAssertNotEqual(m.selection, .comment("R1-05"))
        XCTAssertNil(m.panelToast.text)
        // the choice row's Cancel needs no engine
        m.select(.comment("R1-05"))
        m.edit.choice = EditState.Choice(id: "R1-05", verdict: "verified", text: "Fine.", sent: false)
        m.choose(.cancel)
        XCTAssertNil(m.edit.choice)
        XCTAssertNil(m.panelToast.text)
        // nor does putting the cursor in the field (R, Return, Follow up with the field empty), as a click in it
        let toField: [(String, () -> Void)] = [
            ("R", { m.perform(.verdict("reopened")) }),
            ("Return", { m.perform(.focusField) }),
            ("Follow up", { m.actions.press("reopened", "R1-05") }),
        ]
        for (name, action) in toField {
            m.edit.focusRequest = nil
            action()
            XCTAssertEqual(m.edit.focusRequest, "R1-05", name)
            XCTAssertNil(m.panelToast.text, name)
        }
        XCTAssertNil(m.alertMessage)
        // what is written there waits for the engine
        m.setDraft("R1-05", "Please check the units.")
        m.sendDraft("R1-05", advance: true)
        XCTAssertEqual(m.panelToast.text, AppModel.stillLoading)
        m.clearPanelToast()
        m.actions.sendDraft("R1-05")
        XCTAssertEqual(m.panelToast.text, AppModel.stillLoading, "Follow up with text")
        m.setDraft("R1-05", "")
        // not kept for later: free again, nothing happens until the next answer
        m.holdBusy(false)
        XCTAssertFalse(m.busy)
        XCTAssertNil(m.alertMessage)
        m.perform(.verdict("verified"))
        XCTAssertTrue(m.alertMessage?.hasPrefix("Fixture mode") == true, "now it goes to the engine")
    }

    /// A click on a card whose own answer is with the engine (a double click's second click, the engine slower than
    /// the click) is ignored without a word: "Still loading…" would invite one more click, which in Review would answer
    /// the card that then takes its place. A key, or a click elsewhere, still says it (review 2026-10-18).
    func testASecondClickWhileTheCardsAnswerIsSentIsIgnored() throws {
        let m = makeModel()
        m.select(.comment("R1-05"))
        m.holdBusy(true)
        m.answerPending = "R1-05"  // as `give` sets it while the engine answers
        XCTAssertTrue(m.clickIgnored("R1-05"))
        XCTAssertFalse(m.clickIgnored("R1-06"))
        for (name, click) in [("Resolve", { m.actions.press("verified", "R1-05") }),
                              ("Keep as is", { m.actions.press("wontfix", "R1-05") })] as [(String, () -> Void)] {
            m.clearPanelToast()
            click()
            XCTAssertNil(m.panelToast.text, name)
        }
        m.perform(.verdict("verified"))
        XCTAssertEqual(m.panelToast.text, AppModel.stillLoading, "a key is not held back")
        XCTAssertNil(m.comment("R1-05")?.verdict)
        XCTAssertNil(m.alertMessage)
        // the engine's reply (here a fixture run's refusal, at once) ends it
        m.holdBusy(false)
        m.answerPending = nil
        m.actions.press("verified", "R1-05")
        XCTAssertNil(m.answerPending)
        XCTAssertFalse(m.clickIgnored("R1-05"))
        XCTAssertTrue(m.alertMessage?.hasPrefix("Fixture mode") == true)
    }
}

extension PanelTable {
    /// The window frame of a header row, by row index (tests).
    func rowFrameOfHeader(_ row: Int) -> CGRect? {
        guard let tv = scrollView.documentView as? NSTableView, row < tv.numberOfRows else { return nil }
        tv.scrollRowToVisible(row)
        tv.layoutSubtreeIfNeeded()
        return tv.rowView(atRow: row, makeIfNecessary: false).map { $0.convert($0.bounds, to: nil) }
    }
}
