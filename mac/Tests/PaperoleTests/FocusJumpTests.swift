import AppKit
import PDFKit
import SwiftUI
import XCTest
@testable import Paperole

/// UI v2.1 phase 4 (design/ui-v2.1/POLISH.md §3 rows 5 and 12, §4.3, §6): Jump's search over comments, other edits,
/// sections, rounds and commands, with the paper's own text left to the PDF's find; Focus, the reading mode. Synthetic
/// fixtures only.
final class JumpSearchTests: XCTestCase {
    private func section(_ block: Int, _ number: String, _ name: String) -> OutlineRow {
        OutlineRow(block: block, title: number + " " + name, number: number, name: name, level: number.contains(".") ? 2 : 1,
                   range: block..<(block + 5), read: 0, count: 0, open: 0, changed: false, tracked: true)
    }

    private func sources() -> Jump.Sources {
        var s = Jump.Sources()
        s.comments = [
            .init(id: "R2-05", status: .toCheck, note: "Which tide state? Give the times of the recordings.",
                  words: "Recordings were made at night, when boat traffic is low and the reef is quiet.", said: "", page: 3),
            .init(id: "R3-01", status: .new, note: "Say how the index rejects boat noise, or drop “robust”.",
                  words: "a band-limited index robust to boat noise", said: "", page: 0),
            .init(id: "R1-02", status: .followUp, note: "Motivate the 2 kHz band before you cite the survey.",
                  words: "Coral reefs are among the loudest habitats in the sea.", said: "Still no groundwork before the survey citation.",
                  page: 0),
        ]
        s.edits = [.init(id: "c04", kind: .moved, place: "§ 4 Discussion", excerpt: "Boat traffic peaks at dawn on weekends.", page: 5)]
        s.sections = [section(10, "2", "Methods"), section(11, "2.1", "Recorders"), section(20, "3", "Results")]
        s.rounds = [RoundSummary(n: 1, created: nil, source: nil, closed: true, closedAt: nil, status: "ok", pdf: nil),
                    RoundSummary(n: 2, created: nil, source: nil, closed: false, closedAt: nil, status: "ok", pdf: nil)]
        s.shownRound = 2
        s.commands = [.init(command: .focus, title: "Focus: the page alone", icon: "arrow.up.left.and.arrow.down.right"),
                      .init(command: .finish, title: "Finish Round 2…", icon: "checkmark.circle")]
        return s
    }

    /// The mockup's "boat": comments in the list's order (the words a comment is on after "on"), the other edit, and
    /// the PDF's find last.
    func testGroupsInOrderWithTheFindRowLast() throws {
        let g = Jump.search("boat", in: sources())
        XCTAssertEqual(g.map(\.title), ["Comments", "Unasked edits", "In the paper"])
        XCTAssertEqual(g[0].rows.map(\.lead), ["R2-05", "R3-01"])
        XCTAssertEqual(g[0].rows[0].title, "Which tide state? Give the times of the recordings.")
        XCTAssertTrue(g[0].rows[0].detail.hasPrefix("on “"), "found in the words it is on")
        XCTAssertTrue(g[0].rows[0].detail.contains("boat traffic"))
        XCTAssertEqual(g[0].rows[1].detail, "", "the note has the word")
        XCTAssertEqual(g[0].rows[0].trailing, "p.4")
        XCTAssertEqual(g[0].rows[0].target, .comment("R2-05"))
        XCTAssertEqual(g[1].rows[0].title, "§ 4 Discussion")
        XCTAssertTrue(g[1].rows[0].detail.hasPrefix("Moved: “Boat traffic"))
        XCTAssertEqual(g[1].rows[0].target, .edit("c04"))
        XCTAssertEqual(g[2].rows.map(\.title), ["Find “boat” in the paper"])
        XCTAssertEqual(g[2].rows[0].target, .find("boat"))
    }

    /// Ids by their start, what you wrote this round, and every word of the query somewhere.
    func testIdsWordsAndEveryWord() {
        XCTAssertEqual(Jump.search("r1-0", in: sources()).first?.rows.map(\.lead), ["R1-02"])
        let said = Jump.search("groundwork", in: sources())[0].rows[0]
        XCTAssertEqual(said.lead, "R1-02")
        XCTAssertTrue(said.detail.hasPrefix("you wrote “"))
        XCTAssertEqual(Jump.search("boat night", in: sources())[0].rows.map(\.lead), ["R2-05"])
        XCTAssertEqual(Jump.search("BOAT dawn", in: sources()).map(\.title), ["Unasked edits", "In the paper"], "any case")
        XCTAssertEqual(Jump.search("zzqx", in: sources()).map(\.title), ["In the paper"])
    }

    func testSectionsRoundsAndCommands() {
        let sec = Jump.search("recorders", in: sources())
        XCTAssertEqual(sec.map(\.title), ["Sections", "In the paper"])
        XCTAssertEqual(sec[0].rows[0].lead, "2.1")
        XCTAssertEqual(sec[0].rows[0].title, "Recorders")
        XCTAssertEqual(sec[0].rows[0].target, .section(11))
        XCTAssertEqual(Jump.search("2.1", in: sources()).first { $0.title == "Sections" }?.rows.map(\.lead), ["2.1"])
        let rounds = Jump.search("round 2", in: sources())
        XCTAssertEqual(rounds.first { $0.title == "Rounds" }?.rows.map(\.target), [.round(2)])
        XCTAssertEqual(rounds.first { $0.title == "Rounds" }?.rows.first?.trailing, "shown")
        XCTAssertEqual(rounds.first { $0.title == "Commands" }?.rows.map(\.target), [.command(.finish)])
        XCTAssertEqual(Jump.search("focus", in: sources()).first { $0.title == "Commands" }?.rows.map(\.target), [.command(.focus)])
    }

    /// With no query, Jump offers the rounds and the commands (a mouse can go on from there); no find row.
    func testNoQueryOffersRoundsAndCommands() {
        let g = Jump.search("  ", in: sources())
        XCTAssertEqual(g.map(\.title), ["Rounds", "Commands"])
        XCTAssertEqual(g[1].rows.count, 2)
    }

    func testAtMostEightComments() {
        var s = sources()
        s.comments = (1...12).map { .init(id: String(format: "R1-%02d", $0), status: .toCheck, note: "Cite it.", words: "", said: "", page: 0) }
        XCTAssertEqual(Jump.search("cite", in: s)[0].rows.count, Jump.limits.comments)
    }

    func testSnippetCutsRoundTheWord() {
        let text = String(repeating: "lorem ipsum dolor ", count: 10) + "the boat traffic is low " + String(repeating: "sit amet ", count: 10)
        let s = Jump.snippet(text, around: ["boat"])
        XCTAssertTrue(s.hasPrefix("…") && s.hasSuffix("…"))
        XCTAssertTrue(s.contains("boat traffic"))
        XCTAssertLessThanOrEqual(s.count, 56 + 14)
        XCTAssertEqual(Jump.snippet("short  text", around: ["x"]), "short text")
    }

    /// The query's words are Semibold in the label colour where a row has them.
    func testTheQuerysWordsAreMarked() {
        let a = Jump.styled("Boat traffic and a boat", ["boat"], color: Ink.secondary)
        let marked = a.runs.filter { $0.foregroundColor == Ink.label }.map { String(a[$0.range].characters) }
        XCTAssertEqual(marked, ["Boat", "boat"])
    }
}

@MainActor
final class JumpModelTests: XCTestCase {
    func testHighlightWrapsAndTheQueryIsKept() {
        let j = JumpModel()
        j.sources = {
            var s = Jump.Sources()
            s.rounds = [RoundSummary(n: 1, created: nil, source: nil, closed: true, closedAt: nil, status: "ok", pdf: nil)]
            s.commands = [.init(command: .focus, title: "Focus: the page alone", icon: "x")]
            return s
        }
        j.open()
        XCTAssertTrue(j.shown)
        XCTAssertEqual(j.rows.count, 2)
        j.move(-1)
        XCTAssertEqual(j.highlighted, 1, "up from the first: the last")
        j.move(1)
        XCTAssertEqual(j.highlighted, 0)
        j.setQuery("focus")
        XCTAssertEqual(j.rows.map(\.target), [.command(.focus), .find("focus")])
        j.close()
        XCTAssertFalse(j.shown)
        j.open()
        XCTAssertEqual(j.query, "focus", "kept for the next open")
    }
}

/// Focus on the fixture (round 2, open): the panel showing only the selected card (POLISH §7), answers that stay, the
/// field written in Focus.
@MainActor
final class FocusTests: XCTestCase {
    private var drafts: URL!

    override func setUpWithError() throws {
        drafts = FileManager.default.temporaryDirectory.appendingPathComponent("pc-focus-drafts-" + UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: drafts)
    }

    private func spin(_ s: Double = 0.1) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    private func makeModel() -> AppModel {
        _ = NSApplication.shared
        var o = LaunchOptions()
        o.fixture = StepTests.fixtures.appendingPathComponent("state-m2a.json").path
        o.drafts = drafts.path
        return AppModel(options: o)
    }

    private func state(_ change: (inout [String: Any]) -> Void) throws -> EngineState {
        let url = StepTests.fixtures.appendingPathComponent("state-m2a.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        change(&json)
        return try EngineState.decode(JSONSerialization.data(withJSONObject: json))
    }

    /// The fixture's PDF in a PDF view of its own, in a window never shown.
    private func attachPDF(_ m: AppModel, width: CGFloat = 700) -> (ReviewPDFView, NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 900), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = ReviewPDFView(frame: NSRect(x: 0, y: 0, width: width, height: 900))
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        window.contentView = view
        m.pdf.attach(view)
        m.pdf.update(url: m.pdfURL, key: MarkKey(version: m.stateVersion, showChanges: m.showChanges))
        view.layoutSubtreeIfNeeded()
        return (view, window)
    }

    /// POLISH §6: in Focus an answer moves neither the selection nor the PDF; only a round with a PDF has Focus.
    func testFocusAnswersInPlace() throws {
        let m = makeModel()
        XCTAssertTrue(m.answersAdvance)
        m.setFocus(true)
        XCTAssertTrue(m.focus)
        XCTAssertFalse(m.answersAdvance)
        m.setFocus(false)
        XCTAssertTrue(m.answersAdvance)
        let noPDF = try state { json in
            var round = json["round"] as? [String: Any] ?? [:]
            var build = round["build"] as? [String: Any] ?? [:]
            build["pdf"] = NSNull()
            round["build"] = build
            json["round"] = round
        }
        m.setFocus(true)
        m.apply(noPDF)
        XCTAssertFalse(m.focus, "a round without a PDF leaves Focus")
        m.setFocus(true)
        XCTAssertFalse(m.focus, "and has none")
    }

    /// POLISH §7: in Focus the panel shows only the selected card, the same list showing that one row (or what to
    /// click when nothing is selected), and the whole list again when Focus ends.
    func testThePanelShowsOnlyTheSelectedCard() throws {
        let m = makeModel()
        let list = CommentListController(panel: m.panel, actions: m.actions, edit: m.edit)
        let changes = ChangeListController(panel: m.changes, actions: m.actions, edit: m.edit)
        let all = list.table.listed
        XCTAssertGreaterThan(all.count, 3)
        m.select(.comment("R1-05"))
        m.setFocus(true)
        XCTAssertTrue(m.panel.focus && m.changes.focus && m.edit.focus)
        XCTAssertEqual(list.table.listed, ["R1-05"])
        XCTAssertEqual(list.table.expandedID, "R1-05")
        m.move(1)
        let next = try XCTUnwrap(m.panel.expanded)
        XCTAssertNotEqual(next, "R1-05")
        XCTAssertEqual(list.table.listed, [next], "J shows the next card alone")
        XCTAssertEqual(list.table.expandedID, next)
        m.markClicked("R1-02")
        XCTAssertEqual(list.table.listed, ["R1-02"], "a click on a mark shows its card")
        m.select(nil)
        XCTAssertEqual(list.table.listed, ["focus hint"], "nothing selected: what to click")
        m.tab = .changes
        XCTAssertEqual(changes.table.listed, ["focus hint"], "no edit selected yet")
        m.select(.change("c06"))
        XCTAssertEqual(changes.table.listed, ["c06"])
        m.tab = .comments
        m.markClicked("R1-02")  // in For the student, folded: the group is shown with it
        m.setFocus(false)
        XCTAssertFalse(m.panel.focus || m.changes.focus || m.edit.focus)
        XCTAssertEqual(list.table.listed.filter { $0.hasPrefix("header: ") }, all.filter { $0.hasPrefix("header: ") },
                       "the whole list again")
        XCTAssertEqual(list.table.listed.filter { !$0.hasPrefix("header: ") },
                       m.panel.listed.map(\.id), "every listed card")
        XCTAssertEqual(list.table.expandedID, "R1-02")
        withExtendedLifetime((list, changes)) {}
    }

    /// Focus's panel shows the card at its top, so a selection asks it for no scroll; leaving Focus scrolls the card
    /// into view in the whole list.
    func testThePanelScrollsWhenFocusEnds() {
        let m = makeModel()
        m.setFocus(true)
        m.select(.comment("R1-09"), scroll: .centre)
        XCTAssertNil(m.panel.scroller.pendingMode)
        m.setFocus(false)
        XCTAssertFalse(m.focus)
        XCTAssertEqual(m.panel.scroller.pendingMode, .centre)
    }

    /// POLISH §7: the follow-up is written in the card in Focus: R, Return and editing a note keep Focus.
    func testTheFieldIsWrittenInFocus() {
        let m = makeModel()
        m.select(.comment("R1-05"))
        m.setFocus(true)
        m.perform(.verdict("reopened"))  // R on a card to check
        XCTAssertTrue(m.focus)
        XCTAssertEqual(m.edit.focusRequest, "R1-05")
        XCTAssertEqual(m.selection, .comment("R1-05"))
        m.select(.comment("R2-02"))  // a new comment
        m.perform(.editNote)
        XCTAssertTrue(m.focus)
        XCTAssertEqual(m.edit.field, .note("R2-02"))
    }

    /// Mark checked in Focus stays on the edit; in Review it moves on to the next one to check.
    func testCheckingAnEditInFocusStays() throws {
        let m = makeModel()
        m.apply(try state { json in
            var list = json["changes"] as? [[String: Any]] ?? []
            for i in list.indices where list[i]["id"] as? String == "c07" { list[i]["unrequested"] = true }
            json["changes"] = list
        })
        XCTAssertEqual(m.changes.unrequested.map(\.id).sorted(), ["c06", "c07"])
        m.tab = .changes
        m.select(.change("c06"))
        m.setFocus(true)
        m.perform(.check)
        XCTAssertEqual(m.selection, .change("c06"))
        m.alertMessage = nil
        m.setFocus(false)
        m.perform(.check)
        XCTAssertNotEqual(m.selection, .change("c06"), "Review moves on")
    }

    func testFTogglesFocus() {
        XCTAssertEqual(KeyRoute.action("f", KeyState()), .toggleFocus)
        var s = KeyState()
        s.roundOpen = true
        s.textSelection = true
        XCTAssertEqual(KeyRoute.action("f", s), .toggleFocus)
        s.textSelection = false
        s.card = .carried(answered: false)
        s.choice = true
        XCTAssertNil(KeyRoute.action("f", s), "the choice row takes only its own keys")
        let m = makeModel()
        m.perform(.toggleFocus)
        XCTAssertTrue(m.focus)
        m.perform(.toggleFocus)
        XCTAssertFalse(m.focus)
    }

    /// Showing the sidebar again (its toggle, ⌃⌘S) ends Focus; outside Focus it is the sidebar's own state.
    func testShowingTheSidebarEndsFocus() {
        let m = makeModel()
        m.setFocus(true)
        m.sidebarToggled(true)
        XCTAssertFalse(m.focus)
        XCTAssertTrue(m.sidebarShown)
        m.sidebarToggled(false)
        XCTAssertFalse(m.sidebarShown)
        m.setFocus(true)
        m.setFocus(false)
        XCTAssertFalse(m.sidebarShown, "Focus gives back the sidebar as it was")
    }

    /// In Focus a J step lays the next card out at the top of the panel, in place of the last one; the list scrolled
    /// down before Focus starts from its top.
    func testAJStepInFocusShowsTheNextCardAtTheTop() throws {
        let m = makeModel()
        let list = CommentListController(panel: m.panel, actions: m.actions, edit: m.edit)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = list.table.scrollView
        list.table.scrollView.layoutSubtreeIfNeeded()
        m.select(.comment(try XCTUnwrap(m.panel.listed.last?.id)), scroll: nil)
        m.panel.scroller.debugScroll(400)
        spin(0.1)
        XCTAssertGreaterThan(list.table.scrollView.contentView.bounds.minY, 0)
        m.setFocus(true)
        spin(0.1)
        XCTAssertEqual(list.table.scrollView.contentView.bounds.minY, 0, "the card at the top")
        let cards = BodyCount.expanded
        m.select(.comment("R1-05"))
        spin(0.2)
        m.move(1)
        spin(0.2)
        XCTAssertEqual(list.table.listed, [try XCTUnwrap(m.panel.expanded)])
        XCTAssertEqual(try XCTUnwrap(list.table.frame(of: try XCTUnwrap(m.panel.expanded))).minY, 0, accuracy: 0.5)
        XCTAssertGreaterThan(BodyCount.expanded, cards, "the card shows the new comment")
        window.close()
        withExtendedLifetime(list) {}
    }

    /// Review 2026-10-18: in Focus the panel's toast (an answer's, "Still loading…") goes 12 pt under the one card, by
    /// its buttons, not at the panel's foot some 550 pt away; in Review, with nothing selected, or when the card leaves
    /// no room under it, at the foot.
    func testInFocusTheToastIsUnderTheCard() throws {
        let m = makeModel()
        let list = CommentListController(panel: m.panel, actions: m.actions, edit: m.edit)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 900), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = list.table.scrollView
        list.table.scrollView.layoutSubtreeIfNeeded()
        let place = m.actions.toastPlace
        m.select(.comment("R1-05"))
        spin(0.2)
        XCTAssertNil(place.below, "Review: at the panel's foot")
        m.setFocus(true)
        spin(0.2)
        let card = try XCTUnwrap(list.table.frame(of: "R1-05"))
        let below = try XCTUnwrap(place.below, "Focus: under the card")
        XCTAssertEqual(below, card.maxY - 8 + 12, accuracy: 0.5)
        m.select(nil)
        spin(0.1)
        XCTAssertNil(place.below, "no card: at the foot")
        m.select(.comment("R1-05"))
        spin(0.1)
        XCTAssertNotNil(place.below)
        window.setContentSize(NSSize(width: 420, height: card.height + 20))  // no room under the card
        list.table.scrollView.layoutSubtreeIfNeeded()
        m.panel.scroller.debugScroll(1)
        spin(0.1)
        XCTAssertNil(place.below, "a card that fills the panel: at the foot, over its answer row")
        window.setContentSize(NSSize(width: 420, height: 900))
        list.table.scrollView.layoutSubtreeIfNeeded()
        m.setFocus(false)
        spin(0.1)
        XCTAssertNil(place.below)
        window.close()
        withExtendedLifetime(list) {}
    }

    /// POLISH §7: the toolbar's Focus symbol reads as a page to read, not as full screen, and exists on macOS 14 (the
    /// app's oldest): `doc.plaintext`, drawn as `text.page` from macOS 15. Jump's command uses the same one.
    func testTheFocusSymbol() {
        XCTAssertEqual(AppModel.focusSymbol, "doc.plaintext")
        XCTAssertNotNil(NSImage(systemSymbolName: AppModel.focusSymbol, accessibilityDescription: nil))
        let m = makeModel()
        XCTAssertEqual(m.jumpSources().commands.first { $0.command == .focus }?.icon, AppModel.focusSymbol)
    }

    /// The first-run tip says an answer moves on, which in Focus it does not: it waits for Review.
    func testTheTipWaitsForReview() {
        let m = makeModel()
        XCTAssertFalse(m.edit.focus)
        m.setFocus(true)
        XCTAssertTrue(m.edit.focus)
        m.setFocus(false)
        XCTAssertFalse(m.edit.focus)
    }

    /// Focus makes the page 1.3 times as large as it was (at most as wide as the view), in the layout that gives the
    /// view its new width, and keeps the place being read a third of the way down; leaving gives the old scale back.
    func testThePageGrowsAndThePlaceStays() throws {
        let m = makeModel()
        let (view, window) = attachPDF(m, width: 500)
        // in the middle of the document: at its ends the place cannot go past the first page's top or the last one's foot
        let doc = try XCTUnwrap(view.document)
        XCTAssertGreaterThan(doc.pageCount, 1)
        let page = try XCTUnwrap(doc.page(at: 0))
        view.go(to: PDFDestination(page: page, at: CGPoint(x: 0, y: page.bounds(for: .cropBox).minY + 300)))
        let s0 = view.scaleFactor
        let third = try XCTUnwrap(m.pdf.pointAtThird())
        m.setFocus(true)
        view.setFrameSize(NSSize(width: 1400, height: 836))
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(view.autoScales)
        XCTAssertEqual(view.scaleFactor, min(view.scaleFactorForSizeToFit, s0 * 1.3), accuracy: 0.001)
        XCTAssertGreaterThan(view.scaleFactor, s0)
        let inFocus = try XCTUnwrap(m.pdf.pointAtThird())
        XCTAssertEqual(inFocus.page, third.page)
        XCTAssertEqual(inFocus.y, third.y, accuracy: 3)
        m.setFocus(false)
        view.setFrameSize(NSSize(width: 500, height: 900))
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.autoScales)
        XCTAssertEqual(view.scaleFactor, s0, accuracy: 0.001)
        let after = try XCTUnwrap(m.pdf.pointAtThird())
        XCTAssertEqual(after.y, third.y, accuracy: 3)
        window.close()
    }

    /// Jump's rows go where a click on the mark, the Contents or the round menu goes; its commands run.
    func testJumpGoesThere() {
        let m = makeModel()
        let s = m.jumpSources()
        XCTAssertEqual(s.comments.map(\.id), (m.panel.groups.toCheck + m.panel.groups.forStudent + m.panel.groups.closed).map(\.id))
        XCTAssertTrue(s.comments.contains { $0.id == "R1-06" && $0.words.contains("125") }, "the words it is on")
        XCTAssertEqual(s.edits.map(\.id), ["c06"])
        XCTAssertTrue(s.commands.contains { $0.command == .focus })
        m.openJump()
        XCTAssertTrue(m.jump.shown)
        m.jumpTo(.comment("R1-09"))
        XCTAssertFalse(m.jump.shown)
        XCTAssertEqual(m.selection, .comment("R1-09"))
        m.jumpTo(.edit("c06"))
        XCTAssertEqual(m.tab, .changes)
        XCTAssertEqual(m.selection, .change("c06"))
        m.jumpTo(.command(.focus))
        XCTAssertTrue(m.focus)
        m.jumpTo(.command(.comments))
        XCTAssertFalse(m.focus, "a tab needs the panel")
        XCTAssertEqual(m.tab, .comments)
    }

    /// The paper's text goes to the toolbar's find (Find.swift): the query in its field, the match after the last one
    /// found, wrapping; Previous goes back; the field's counter says which of how many.
    func testFindInThePaper() throws {
        let m = makeModel()
        let (view, window) = attachPDF(m)
        let doc = try XCTUnwrap(view.document)
        let n = doc.findString("the", withOptions: [.caseInsensitive]).count
        XCTAssertGreaterThan(n, 2)
        func settle() {
            let deadline = Date().addingTimeInterval(5)
            repeat { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) } while m.pdf.find.isSearching && Date() < deadline
        }
        m.findInPaper("the")
        settle()
        XCTAssertEqual(m.findQuery, "the")
        XCTAssertEqual(m.pdf.find.counter, "1 of \(n)")
        XCTAssertEqual(view.currentSelection?.string?.lowercased(), "the")
        m.findInPaper()
        XCTAssertEqual(m.pdf.find.counter, "2 of \(n)")
        m.findInPaper(previous: true)
        XCTAssertEqual(m.pdf.find.counter, "1 of \(n)")
        m.findInPaper(previous: true)
        XCTAssertEqual(m.pdf.find.counter, "\(n) of \(n)", "wrapping")
        m.findInPaper("the")
        XCTAssertEqual(m.pdf.find.counter, "1 of \(n)", "Jump's find again goes on to the next")
        m.findInPaper("zzqxw")
        settle()
        XCTAssertEqual(m.pdf.find.counter, "No matches")
        XCTAssertNil(m.reading.toast, "the field says it; no toast")
        window.close()
    }
}

/// The inline editor is measured on a layout of its own: resizing the shown text's container while SwiftUI measured
/// looped without end when the panel came back after Focus (several widths tried, each one laying the editor out again).
@MainActor
final class InlineEditorMeasureTests: XCTestCase {
    func testMeasuringGrowsWithTheTextAndLeavesTheEditorAlone() {
        let editor = InlineTextEditor(text: .constant(""), onSubmit: {}, onCancel: {}, onFocusLost: {})
        let c = editor.makeCoordinator()
        let font = NSFont.systemFont(ofSize: 13)
        let one = c.measure("Name it.", font: font, padding: 5, width: 300)
        let wrapped = c.measure(String(repeating: "Name the effect size for each condition. ", count: 4), font: font, padding: 5,
                                width: 300)
        XCTAssertGreaterThan(one.line, 10)
        XCTAssertEqual(one.used, one.line, accuracy: 1, "one line")
        XCTAssertGreaterThan(wrapped.used, 2 * one.line, "wraps at the width")
        XCTAssertGreaterThan(c.measure("a\nb\nc", font: font, padding: 5, width: 300).used, 2.5 * one.line, "line breaks")
        XCTAssertEqual(c.measure("Name it.", font: font, padding: 5, width: 300).used, one.used, "the same text, the same height")
    }
}
