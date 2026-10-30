import AppKit
import PDFKit
import XCTest
@testable import Paperole

/// Re-editing a comment's mark (UX.md §8, the advisor's request of 2026-10-26): the toolbar by a new comment's mark,
/// the card's colour dot, and ⌘Z over style changes. Fixtures and a synthetic paper only.
final class MarkStyleRulesTests: XCTestCase {
    func testAFloatGoesAboveTheMarkElseBelowInsideTheView() throws {
        let size = CGSize(width: 200, height: 30)
        let lines = [CGRect(x: 100, y: 500, width: 300, height: 12), CGRect(x: 100, y: 486, width: 120, height: 12)]
        // room above: centred 8 pt over the top line
        XCTAssertEqual(FloatPlace.origin(size: size, lines: lines, width: 800, top: 900), CGPoint(x: 150, y: 520))
        // none above (the view's top is 30 pt over the line): 8 pt under the lowest line
        XCTAssertEqual(FloatPlace.origin(size: size, lines: lines, width: 800, top: 542), CGPoint(x: 150, y: 448))
        // kept 8 pt inside the view's sides
        let left = [CGRect(x: 0, y: 500, width: 40, height: 12)]
        XCTAssertEqual(FloatPlace.origin(size: size, lines: left, width: 800, top: 900)?.x, 8)
        let right = [CGRect(x: 760, y: 500, width: 40, height: 12)]
        XCTAssertEqual(FloatPlace.origin(size: size, lines: right, width: 800, top: 900)?.x, 592)
        // a mark taller than the view: the float stays inside it
        let tall = [CGRect(x: 100, y: -200, width: 300, height: 1200)]
        let o = try XCTUnwrap(FloatPlace.origin(size: size, lines: tall, width: 800, top: 900))
        XCTAssertEqual(o.y, 8)
        XCTAssertNil(FloatPlace.origin(size: size, lines: [], width: 800, top: 900))
    }

    func testTheKindsAMarkCanTake() {
        XCTAssertEqual(MarkStyleRow.kinds(carried: false, kind: .highlight), MarkKind.textKinds)
        XCTAssertEqual(MarkStyleRow.kinds(carried: false, kind: .strikeout), MarkKind.textKinds)
        XCTAssertEqual(MarkStyleRow.kinds(carried: false, kind: .box), [], "a box stays a box")
        XCTAssertEqual(MarkStyleRow.kinds(carried: false, kind: .note), [], "a note stays a note")
        XCTAssertEqual(MarkStyleRow.kinds(carried: true, kind: .highlight), [], "a carried comment: only by re-anchoring")
    }

    func testEscPutsTheMarksToolbarAway() {
        var s = KeyState()
        s.roundOpen = true
        s.card = .new
        XCTAssertNil(KeyRoute.action("esc", s))
        s.markBar = true
        XCTAssertEqual(KeyRoute.action("esc", s), .hideMarkBar)
        XCTAssertEqual(KeyRoute.action("return", s), .editNote, "its other keys stay the card's")
        XCTAssertEqual(KeyRoute.action("2", s), .recolor(.teal))
        XCTAssertEqual(KeyRoute.action("delete", s), .delete)
        s.boxArmed = true
        XCTAssertEqual(KeyRoute.action("esc", s), .armBox, "box mode first")
    }

    func testStyleStepsUndoInTurnWithAnswers() {
        let resolved = AnswerStep(id: "R1-04", before: Answer(), after: Answer(verdict: "verified"))
        let blue = StyleStep(id: "R2-02", before: MarkStyle(color: .yellow, kind: .highlight), after: MarkStyle(color: .blue, kind: .highlight))
        let under = StyleStep(id: "R2-02", before: MarkStyle(color: .blue, kind: .highlight), after: MarkStyle(color: .blue, kind: .underline))
        var h = AnswerHistory()
        h.record(blue)
        h.record(resolved)
        h.record(under)
        h.record(StyleStep(id: "R2-03", before: MarkStyle(color: .pink, kind: .box), after: MarkStyle(color: .pink, kind: .box)))
        XCTAssertEqual(h.undos, [.style(blue), .answer(resolved), .style(under)], "nothing changed is not recorded")
        XCTAssertEqual(h.undo(), .style(under))
        XCTAssertEqual(h.undo(), .answer(resolved))
        XCTAssertEqual(h.redo(), .answer(resolved))
        XCTAssertEqual(h.redos, [.style(under)])
        // typing in R2-02's field (were it carried) keeps its style steps: they put no draft back
        h.forget("R2-02", answersOnly: true)
        XCTAssertEqual(h.undos, [.style(blue), .answer(resolved)])
        XCTAssertEqual(h.redos, [.style(under)])
        // deleted: all its steps go
        h.forget("R2-02")
        XCTAssertEqual(h.undos, [.answer(resolved)])
        XCTAssertEqual(h.redos, [])
    }

    func testTheToastNamesWhatChanged() {
        let colour = StyleStep(id: "R2-02", before: MarkStyle(color: .yellow, kind: .highlight), after: MarkStyle(color: .blue, kind: .highlight))
        XCTAssertEqual(colour.words(colour.before), "yellow")
        let kind = StyleStep(id: "R2-02", before: MarkStyle(color: .blue, kind: .highlight), after: MarkStyle(color: .blue, kind: .underline))
        XCTAssertEqual(kind.words(kind.before), "a highlight")
        XCTAssertEqual(kind.words(kind.after), "an underline")
        let both = StyleStep(id: "R2-02", before: MarkStyle(color: .orange, kind: .strikeout), after: MarkStyle(color: .teal, kind: .highlight))
        XCTAssertEqual(both.words(both.before), "an orange strikeout")
        XCTAssertEqual(both.words(both.after), "a teal highlight")
    }
}

/// The toolbar by a mark on the open round 2 fixture: R2-02 is a new highlight on p.1, R1-06 a carried one.
@MainActor
final class MarkToolbarTests: XCTestCase {
    private var dir: URL!
    private var windows: [NSWindow] = []

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-markbar-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for w in windows { w.close() }
        windows = []
        try? FileManager.default.removeItem(at: dir)
    }

    private func spin(_ s: Double = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    /// The round 2 fixture, changed as `edit` says, with its PDFs beside it; shown in a PDF view in a window.
    private func makeModel(_ edit: (inout [String: Any]) -> Void = { _ in }) throws -> (AppModel, ReviewPDFView) {
        _ = NSApplication.shared
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: StepTests.fixtures
            .appendingPathComponent("state-round2.json"))) as? [String: Any])
        edit(&json)
        let url = dir.appendingPathComponent("state.json")
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        for r in ["round1", "round2"] {
            try? FileManager.default.createSymbolicLink(at: dir.appendingPathComponent(r),
                                                        withDestinationURL: StepTests.fixtures.appendingPathComponent(r))
        }
        var o = LaunchOptions()
        o.fixture = url.path
        o.drafts = dir.appendingPathComponent("drafts").path
        o.tags = dir.appendingPathComponent("tags.json").path
        let m = AppModel(options: o)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 900), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        let v = ReviewPDFView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(v)
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        m.pdf.attach(v)
        m.pdf.update(url: m.pdfURL, key: MarkKey(version: m.stateVersion, showChanges: m.showChanges))
        v.layoutDocumentView()
        spin(0.8)  // settled, and put at the top of p.1 as a PDF just loaded is (a scroll, which puts floats away)
        return (m, v)
    }

    private func comments(_ json: inout [String: Any], _ change: (inout [String: Any]) -> Void) {
        var cs = json["comments"] as? [[String: Any]] ?? []
        for i in cs.indices { change(&cs[i]) }
        json["comments"] = cs
    }

    /// A click without a drag on a comment's mark (its first line's middle), as the PDF view's tracker sends it.
    @discardableResult
    private func click(_ m: AppModel, _ v: ReviewPDFView, _ id: String) throws -> String? {
        let c = try XCTUnwrap(m.comment(id))
        let page = try XCTUnwrap(v.document?.page(at: try XCTUnwrap(c.page)))
        let r = try XCTUnwrap(c.rects.first), cb = page.bounds(for: .cropBox)
        return m.pdf.click(page: page, at: CGPoint(x: cb.minX + (r[0] + r[2]) / 2, y: cb.maxY - (r[1] + r[3]) / 2))
    }

    func testANewCommentsMarkShowsItsToolbar() throws {
        let (m, v) = try makeModel()
        XCTAssertEqual(try click(m, v, "R2-02"), "R2-02")
        XCTAssertEqual(m.selection, .comment("R2-02"), "selected as before")
        XCTAssertTrue(m.pdf.markBarShown)
        XCTAssertEqual(m.pdf.markBarID, "R2-02")
        XCTAssertEqual(m.pdf.markBar.color, .yellow)
        XCTAssertEqual(m.pdf.markBar.kind, .highlight)
        XCTAssertEqual(m.pdf.markBar.kinds, MarkKind.textKinds)
        XCTAssertFalse(m.pdf.toolbarShown, "not the selection's toolbar")
        XCTAssertTrue(m.keyState.markBar)
        // by the mark: above its line, past the selection's outline, inside the view
        let bar = try XCTUnwrap(m.pdf.markBarView)
        XCTAssertTrue(bar.superview === v)
        let mark = try XCTUnwrap(m.pdf.debugMark("R2-02"))
        let line = v.convert(mark.lines[0], from: mark.page)
        XCTAssertGreaterThanOrEqual(bar.frame.minY, line.maxY + 10)
        XCTAssertLessThanOrEqual(bar.frame.minY, line.maxY + 12)
        XCTAssertEqual(bar.frame.midX, line.midX, accuracy: 1)
        XCTAssertTrue(v.bounds.insetBy(dx: 7.9, dy: 7.9).contains(bar.frame))
        XCTAssertGreaterThan(bar.frame.width, 300, "swatches, kinds, Edit Note and Delete")
        // a click on the bar reaches the bar, not the PDF under it
        let hit = v.window?.contentView?.superview?.hitTest(v.convert(CGPoint(x: bar.frame.midX, y: bar.frame.midY), to: nil))
        XCTAssertTrue(hit.map { $0.isDescendant(of: bar) } ?? false)
        // Esc puts it away; the card stays selected
        m.perform(.hideMarkBar)
        XCTAssertFalse(m.pdf.markBarShown)
        XCTAssertEqual(m.selection, .comment("R2-02"))
    }

    func testACarriedCommentsMarkOnlySelects() throws {
        let (m, v) = try makeModel()
        XCTAssertEqual(try click(m, v, "R1-06"), "R1-06")
        XCTAssertEqual(m.selection, .comment("R1-06"))
        XCTAssertFalse(m.pdf.markBarShown, "clicking marks is how a round of carried comments is read")
        try click(m, v, "R2-02")
        XCTAssertTrue(m.pdf.markBarShown)
        // another card's mark: the toolbar leaves with the selection
        try click(m, v, "R1-06")
        XCTAssertFalse(m.pdf.markBarShown)
        XCTAssertNil(m.pdf.markBarID)
    }

    func testAClickElsewhereAKeyOrAScrollPutsItAway() throws {
        let (m, v) = try makeModel()
        let page = try XCTUnwrap(v.document?.page(at: 0)), cb = page.bounds(for: .cropBox)
        try click(m, v, "R2-02")
        XCTAssertNil(m.pdf.click(page: page, at: CGPoint(x: cb.minX + 300, y: cb.maxY - 80)), "nothing there")
        XCTAssertFalse(m.pdf.markBarShown)
        XCTAssertEqual(m.selection, .comment("R2-02"), "the card selection stays")
        // a click on the selected mark again shows it again
        try click(m, v, "R2-02")
        XCTAssertTrue(m.pdf.markBarShown)
        // J: another card
        m.perform(.next)
        spin()
        XCTAssertNotEqual(m.selection, .comment("R2-02"))
        XCTAssertFalse(m.pdf.markBarShown)
        // a row clicked in the panel selects without showing it
        m.actions.rowClicked("R2-02")
        spin()
        XCTAssertEqual(m.selection, .comment("R2-02"))
        XCTAssertFalse(m.pdf.markBarShown, "only a click on the mark shows it")
        // a scroll of the PDF
        try click(m, v, "R2-02")
        XCTAssertTrue(m.pdf.markBarShown)
        let clip = try XCTUnwrap(v.documentView?.enclosingScrollView?.contentView)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + 40))
        spin()
        XCTAssertFalse(m.pdf.markBarShown)
    }

    func testTheSelectionsToolbarABoxAndReanchoringComeFirst() throws {
        let (m, v) = try makeModel()
        let page = try XCTUnwrap(v.document?.page(at: 0)), cb = page.bounds(for: .cropBox)
        try click(m, v, "R2-02")
        // text selected (a drag): the selection's toolbar takes its place
        v.setCurrentSelection(page.selection(from: CGPoint(x: cb.minX + 150, y: cb.maxY - 337),
                                             to: CGPoint(x: cb.minX + 400, y: cb.maxY - 360)), animate: false)
        spin(0.3)
        XCTAssertFalse(m.pdf.markBarShown)
        XCTAssertTrue(m.pdf.toolbarShown)
        v.clearSelection()
        spin()
        // a ⌥-drag's rubber band
        try click(m, v, "R2-02")
        XCTAssertTrue(m.pdf.markBarShown)
        m.pdf.rubberBand(page: page, rect: CGRect(x: cb.minX + 100, y: cb.maxY - 200, width: 1, height: 1))
        XCTAssertFalse(m.pdf.markBarShown)
        m.pdf.endBox(page: page, rect: CGRect(x: cb.minX + 100, y: cb.maxY - 300, width: 80, height: 80),
                     start: CGPoint(x: cb.minX + 100, y: cb.maxY - 220), option: true)
        XCTAssertNotNil(m.pdf.pendingBox)
        XCTAssertFalse(m.pdf.markBarShown, "the box's toolbar instead")
        m.pdf.dropPendingBox()
        // re-anchoring: put away, and a click on a mark selects nothing
        try click(m, v, "R2-02")
        XCTAssertTrue(m.pdf.markBarShown)
        m.beginReanchor("R2-02")
        XCTAssertFalse(m.pdf.markBarShown)
        XCTAssertNil(try click(m, v, "R2-02"))
        XCTAssertFalse(m.pdf.markBarShown)
        m.leaveReanchor()
        try click(m, v, "R2-02")
        XCTAssertTrue(m.pdf.markBarShown, "and back once it ends")
    }

    func testEditNoteAndDelete() throws {
        let (m, v) = try makeModel()
        try click(m, v, "R2-02")
        let actions = MarkToolbarActions(model: m)
        actions.delete("R2-02")
        XCTAssertEqual(m.confirmDelete, "R2-02", "the panel's dialog")
        XCTAssertTrue(m.pdf.markBarShown, "kept for a Cancel; it goes with the mark")
        m.confirmDelete = nil
        actions.editNote("R2-02")
        XCTAssertEqual(m.edit.field, .note("R2-02"), "the note opens in its card")
        XCTAssertFalse(m.pdf.markBarShown)
    }

    func testABoxShowsNoKindsAndTheToolbarFitsIt() throws {
        let (m, v) = try makeModel { json in
            self.comments(&json) { c in if c["id"] as? String == "R2-03" { c["kind"] = "box" } }
        }
        try click(m, v, "R2-02")
        spin()
        let wide = try XCTUnwrap(m.pdf.markBarView?.frame.width)
        try click(m, v, "R2-03")
        XCTAssertTrue(m.pdf.markBarShown)
        XCTAssertEqual(m.pdf.markBar.kinds, [])
        spin()
        let bar = try XCTUnwrap(m.pdf.markBarView)
        XCTAssertLessThan(bar.frame.width, wide - 50, "laid again without the kinds")
        XCTAssertEqual(bar.frame.size, bar.fittingSize)
    }

    func testNoneInAClosedRound() throws {
        let (m, v) = try makeModel { json in
            var r = json["round"] as? [String: Any] ?? [:]
            r["closed"] = true
            json["round"] = r
        }
        XCTAssertFalse(m.roundIsOpen)
        XCTAssertEqual(try click(m, v, "R2-02"), "R2-02", "the click selects as before")
        XCTAssertFalse(m.pdf.markBarShown)
        XCTAssertFalse(m.edit.roundOpen, "nor the card's colour dot")
    }

    func testTheColourDotsPopoverClosesOnAPickAndWithTheSelection() throws {
        let (m, _) = try makeModel()
        m.select(.comment("R2-02"))
        m.edit.info = "R2-02"
        m.actions.toggleSwatches("R2-02")
        XCTAssertEqual(m.edit.swatches, "R2-02")
        XCTAssertNil(m.edit.info, "in place of the ⋯ popover")
        m.actions.restyle("R2-02", color: .blue)
        XCTAssertNil(m.edit.swatches, "a pick closes it")
        XCTAssertTrue(m.alertMessage?.hasPrefix("Fixture mode") == true, "and is sent to the engine at once")
        m.alertMessage = nil
        m.edit.swatches = "R2-02"
        m.select(.comment("R1-06"))
        XCTAssertNil(m.edit.swatches, "another card")
    }
}

/// The engine has the style changes, and ⌘Z / ⇧⌘Z take them back and give them again, as answers.
@MainActor
final class MarkStyleUndoTests: XCTestCase {
    private let fm = FileManager.default
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("pc-markstyle-" + UUID().uuidString)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: tmp) }

    private func engineModel() throws -> AppModel {
        guard fm.isExecutableFile(atPath: EngineClient.defaultPython), fm.fileExists(atPath: "/Library/TeX/texbin/latexmk") else {
            throw XCTSkip("needs the engine's Python and latexmk")
        }
        _ = NSApplication.shared
        var o = LaunchOptions()
        o.noList = true
        o.drafts = tmp.appendingPathComponent("drafts").path
        o.cache = tmp.appendingPathComponent("cache").path
        o.tags = tmp.appendingPathComponent("tags.json").path
        return AppModel(options: o)
    }

    @discardableResult
    private func rpc(_ m: AppModel, _ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let data = try await m.engine.call(method, params: JSONSerialization.data(withJSONObject: params))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func until(_ seconds: Double = 20, _ done: () -> Bool) async throws {
        for _ in 0..<Int(seconds * 20) where !done() { try await Task.sleep(nanoseconds: 50_000_000) }
    }

    func testRestyleUndoRedo() async throws {
        let m = try engineModel()
        let paper = tmp.appendingPathComponent("Reviews/Kelp").path
        let src = tmp.appendingPathComponent("src")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try Data("\\documentclass{article}\n\\begin{document}\n\\section{Intro}\nKelp drifts in the bay.\n\\end{document}\n".utf8)
            .write(to: src.appendingPathComponent("main.tex"))
        try await rpc(m, "new", ["paper": paper, "title": "Kelp", "student": "Mei Lin"])
        try await rpc(m, "ingest", ["paper": paper, "source": src.path])
        try await rpc(m, "comment", ["paper": paper, "page": 0, "rects": [[133.7, 148.8, 230.2, 158.8]],
                                     "text": "Kelp drifts in the bay.", "note": "Which bay?", "kind": "highlight"])
        m.selectPaper(paper)
        try await until { m.comment("R1-01") != nil && !m.busy }
        XCTAssertTrue(m.roundIsOpen)
        func style() -> [String]? { m.comment("R1-01").map { [$0.markColor.rawValue, $0.markKind.rawValue] } }
        XCTAssertEqual(style(), ["yellow", "highlight"])

        // the mark's toolbar's swatch, then its kind
        MarkToolbarActions(model: m).restyle("R1-01", color: .blue, kind: nil)
        try await until { style() == ["blue", "highlight"] && !m.busy }
        XCTAssertEqual(style(), ["blue", "highlight"])
        MarkToolbarActions(model: m).restyle("R1-01", color: nil, kind: .underline)
        try await until { style() == ["blue", "underline"] && !m.busy }
        XCTAssertEqual(style(), ["blue", "underline"])
        XCTAssertEqual(m.history.undos.count, 2)
        XCTAssertNil(m.panelToast.text, "no toast for a change the mark shows at once")
        // the same swatch again changes nothing and records nothing
        m.setStyle("R1-01", color: .blue)
        XCTAssertEqual(m.history.undos.count, 2)

        m.undo()
        try await until { style() == ["blue", "highlight"] && !m.busy }
        XCTAssertEqual(style(), ["blue", "highlight"])
        XCTAssertEqual(m.panelToast.text, "Undone · R1-01 is a highlight")
        m.undo()
        try await until { style() == ["yellow", "highlight"] && !m.busy }
        XCTAssertEqual(m.panelToast.text, "Undone · R1-01 is yellow")
        m.undo()
        XCTAssertEqual(m.panelToast.text, "Nothing to undo")
        m.redo()
        try await until { style() == ["blue", "highlight"] && !m.busy }
        XCTAssertEqual(m.panelToast.text, "Redone · R1-01 is blue")
        XCTAssertEqual(m.history.undos.count, 1)
        XCTAssertEqual(m.history.redos.count, 1)

        // the card's colour dot, and a key: the same path
        m.actions.restyle("R1-01", color: .orange)
        try await until { style() == ["orange", "highlight"] && !m.busy }
        XCTAssertEqual(m.history.redos.count, 0, "a new change drops the redo stack")
        m.select(.comment("R1-01"))
        m.perform(.recolor(.purple))
        try await until { style() == ["purple", "highlight"] && !m.busy }
        XCTAssertEqual(m.history.undos.count, 3)

        // deleted: its steps go, so ⌘Z does not recolour what is gone
        m.deleteConfirmed("R1-01")
        try await until { m.comment("R1-01") == nil && !m.busy }
        XCTAssertEqual(m.history.undos.count, 0)
    }
}
