import AppKit
import PDFKit
import XCTest
@testable import Paperole

/// A student's source dropped on a paper (UX.md §43, BACKLOG D11): what the drop does by the latest round, which items
/// are sources, the confirmation's words, and the round starting on the paper it was dropped on. Synthetic fixtures and
/// temporary folders only; fixture mode never runs the engine, so a started round shows as the fixture's refusal.
@MainActor
final class SourceDropTests: XCTestCase {
    private var tmp: URL!
    private var fm: FileManager { .default }
    private let fixtureRefusal = "Fixture mode: the engine is not running, so nothing is saved."

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("pc-sourcedrop-" + UUID().uuidString)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: tmp)
    }

    private func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    private func makeModel() -> AppModel {
        _ = NSApplication.shared
        var o = LaunchOptions()
        o.fixture = StepTests.fixtures.appendingPathComponent("state-m2a.json").path
        o.drafts = tmp.appendingPathComponent("drafts").path
        return AppModel(options: o)
    }

    /// The fixture (Round 2 open, with comments) with its latest round closed or open, and the engine's `replaceable`.
    private func state(closed: Bool, replaceable: Bool, comments: Bool = true) throws -> EngineState {
        let url = StepTests.fixtures.appendingPathComponent("state-m2a.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var rounds = try XCTUnwrap(json["rounds"] as? [[String: Any]])
        rounds[rounds.count - 1]["closed"] = closed
        json["rounds"] = rounds
        if !comments { json["comments"] = [] as [Any] }
        json["summary"] = ["round": 2, "closed": closed, "status": "ok", "to_judge": 0, "to_check": 0,
                           "replaceable": replaceable] as [String: Any]
        return try EngineState.decode(JSONSerialization.data(withJSONObject: json))
    }

    private func folder(_ name: String) throws -> URL {
        let u = tmp.appendingPathComponent(name)
        try fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func file(_ name: String) throws -> URL {
        let u = tmp.appendingPathComponent(name)
        try Data("x".utf8).write(to: u)
        return u
    }

    // MARK: Pure rules

    func testTheLatestRoundDecidesWhatADropDoes() {
        XCTAssertEqual(SourceDrop.of(round: nil, closed: true, replaceable: nil), .start(1))
        XCTAssertEqual(SourceDrop.of(round: 2, closed: true, replaceable: false), .start(3))
        XCTAssertEqual(SourceDrop.of(round: 2, closed: false, replaceable: true), .replace(2))
        XCTAssertEqual(SourceDrop.of(round: 2, closed: false, replaceable: nil), .replace(2), "the sheet's own checks decide")
        XCTAssertEqual(SourceDrop.of(round: 2, closed: false, replaceable: false), .open(2))
        XCTAssertFalse(SourceDrop.open(2).accepts)
        XCTAssertEqual(SourceDrop.start(3).label, "Start Round 3")
        XCTAssertEqual(SourceDrop.replace(2).label, "Replace Draft")
        XCTAssertEqual(SourceDrop.open(2).label, "Round 2 is open")
    }

    func testOnlyAFolderOrAZipIsASource() throws {
        let src = try folder("draft-v3")
        XCTAssertEqual(SourceDrop.source(src), src.standardizedFileURL.path)
        let zip = try file("draft-v3.ZIP")
        XCTAssertEqual(SourceDrop.source(zip), zip.standardizedFileURL.path)
        XCTAssertNil(SourceDrop.source(try file("main.pdf")))
        XCTAssertNil(SourceDrop.source(tmp.appendingPathComponent("gone.zip")))
        XCTAssertNil(SourceDrop.source(try folder("Tool.app")), "a package is not a source")
        XCTAssertNil(SourceDrop.source(try XCTUnwrap(URL(string: "https://example.com/draft.zip"))))
    }

    func testTheConfirmationNamesThePaperTheStudentAndTheFile() {
        let a = DropAsk(paper: "/p", title: "Predictive Warm Pools: Cold Starts", student: "Lin Zhou",
                        source: "/Users/x/Downloads/warmcast-v3.zip", round: 3)
        XCTAssertEqual(a.question, "Start Round 3?")
        XCTAssertEqual(a.message, "\(ShortTitle.of(a.title)) · Lin Zhou\nfrom warmcast-v3.zip")
        let b = DropAsk(paper: "/p", title: "Untitled", student: "", source: "/d/src", round: 1)
        XCTAssertEqual(b.message, "\(ShortTitle.of("Untitled"))\nfrom src")
    }

    // MARK: The model

    func testADropOnAFinishedRoundAsksThenStartsTheNextRound() throws {
        let m = makeModel()
        m.apply(try state(closed: true, replaceable: false))
        let path = try XCTUnwrap(m.selectedPath), src = try folder("warmcast-v3")
        XCTAssertEqual(m.sourceDrop(on: path), .start(3))
        XCTAssertTrue(m.dropSource([src], on: path))
        XCTAssertEqual(m.confirmDrop?.round, 3)
        XCTAssertEqual(m.confirmDrop?.source, src.standardizedFileURL.path)
        XCTAssertNil(m.alertMessage, "nothing starts before the confirmation")
        m.startDropped(try XCTUnwrap(m.confirmDrop))
        XCTAssertNil(m.confirmDrop)
        XCTAssertEqual(m.alertMessage, fixtureRefusal, "ingest was sent")
    }

    func testADropOnAnUnreviewedOpenRoundOpensReplaceDraftWithTheSource() throws {
        let m = makeModel()
        m.apply(try state(closed: false, replaceable: true, comments: false))
        let path = try XCTUnwrap(m.selectedPath), zip = try file("warmcast-v2b.zip")
        XCTAssertTrue(m.dropSource([zip], on: path))
        spin(0.05)
        XCTAssertNil(m.confirmDrop)
        XCTAssertTrue(m.showRetry)
        XCTAssertTrue(m.retryReplacingDraft)
        XCTAssertEqual(m.retrySource, zip.standardizedFileURL.path)
        // the menu's Replace Draft… asks for a source again
        m.showRetry = false
        m.openRoundAction(path, replace: true)
        XCTAssertNil(m.retrySource)
    }

    func testADropOnAReviewedOpenRoundDoesNothing() throws {
        let m = makeModel()
        m.apply(try state(closed: false, replaceable: false))
        let path = try XCTUnwrap(m.selectedPath)
        XCTAssertEqual(m.sourceDrop(on: path), .open(2))
        XCTAssertFalse(m.dropSource([try folder("v3")], on: path))
        spin(0.05)
        XCTAssertNil(m.confirmDrop)
        XCTAssertFalse(m.showRetry)
        XCTAssertNil(m.alertMessage)
    }

    func testAnythingButOneSourceIsRefusedWithAReason() throws {
        let m = makeModel()
        m.apply(try state(closed: true, replaceable: false))
        let path = try XCTUnwrap(m.selectedPath)
        XCTAssertFalse(m.dropSource([try folder("a"), try folder("b")], on: path))
        XCTAssertNotNil(m.alertMessage)
        m.alertMessage = nil
        XCTAssertFalse(m.dropSource([try file("main.pdf")], on: path))
        XCTAssertNotNil(m.alertMessage)
        XCTAssertNil(m.confirmDrop)
    }

    func testADropOnAnotherPapersRowStartsTheRoundOnThatPaper() throws {
        let m = makeModel(), original = try XCTUnwrap(m.selectedPath), reviewed = try XCTUnwrap(m.state)
        let target = tmp.appendingPathComponent("other-paper").path, finished = try state(closed: true, replaceable: false)
        m.selectPaper(target, state: finished)  // its summary in the list, as the sidebar has it
        m.selectPaper(original, state: reviewed)
        XCTAssertEqual(m.sourceDrop(on: target), .start(3))
        XCTAssertTrue(m.dropSource([try folder("v3")], on: target))
        m.startDropped(try XCTUnwrap(m.confirmDrop))
        XCTAssertEqual(m.selectedPath, target)
        XCTAssertEqual(m.level, .review)
        XCTAssertNotNil(m.pendingStart, "waits for the paper's state")
        XCTAssertNil(m.alertMessage)
        m.apply(finished)
        XCTAssertNil(m.pendingStart)
        XCTAssertEqual(m.alertMessage, fixtureRefusal, "ingest was sent for the dropped paper")
    }

    func testAWaitingRoundIsDroppedWhenItsPaperChangedOrAnotherIsShown() throws {
        let m = makeModel(), original = try XCTUnwrap(m.selectedPath), reviewed = try XCTUnwrap(m.state)
        let target = tmp.appendingPathComponent("other-paper").path
        m.selectPaper(target, state: try state(closed: true, replaceable: false))
        m.selectPaper(original, state: reviewed)
        XCTAssertTrue(m.dropSource([try folder("v3")], on: target))
        m.startDropped(try XCTUnwrap(m.confirmDrop))
        // meanwhile Round 3 was started elsewhere: its state says open, so this drop starts nothing
        m.apply(try state(closed: false, replaceable: true))
        XCTAssertNil(m.pendingStart)
        XCTAssertNotEqual(m.alertMessage, fixtureRefusal)
        XCTAssertNotNil(m.alertMessage, "says nothing was started")

        // waiting for its paper's state: a page of the hierarchy, or another paper, drops it
        for leave in ["hub", "paper"] {
            m.alertMessage = nil
            m.selectPaper(target, state: try state(closed: true, replaceable: false))
            m.selectPaper(original, state: reviewed)
            XCTAssertTrue(m.dropSource([try folder("v4")], on: target))
            m.startDropped(try XCTUnwrap(m.confirmDrop))
            XCTAssertNotNil(m.pendingStart)
            if leave == "hub" { m.openHub(.allStudents) } else { m.selectPaper(original, state: reviewed) }
            XCTAssertNil(m.pendingStart, leave)
            m.apply(try state(closed: true, replaceable: false))
            XCTAssertNotEqual(m.alertMessage, fixtureRefusal, "nothing started later (\(leave))")
        }
    }

    func testNoDropWhileTheEngineIsBusy() throws {
        let m = makeModel()
        m.apply(try state(closed: true, replaceable: false))
        let path = try XCTUnwrap(m.selectedPath)
        m.holdBusy(true)
        XCTAssertNil(m.sourceDrop(on: path), "a round being built leaves the summary as it was")
        XCTAssertFalse(m.dropSource([try folder("v3")], on: path))
        XCTAssertNil(m.confirmDrop)
        m.holdBusy(false)
        XCTAssertEqual(m.sourceDrop(on: path), .start(3))
    }

    func testAMissingPapersFolderTakesNoDrop() throws {
        let m = makeModel()
        XCTAssertNil(m.sourceDrop(on: tmp.appendingPathComponent("never-listed").path), "no summary yet")
    }
}

extension SourceDropTests {
    /// AppKit gives a drag to the deepest view registered for it: a PDF view taking file URLs would hide the page's drop
    /// target under the PDF.
    func testThePDFViewLeavesFileDropsToThePage() {
        let v = ReviewPDFView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let doc = PDFDocument()
        doc.insert(PDFPage(), at: 0)
        v.document = doc
        v.layoutDocumentView()
        XCTAssertFalse(v.documentView?.registeredDraggedTypes.contains(.fileURL) ?? false)
        XCTAssertFalse(v.registeredDraggedTypes.contains(.fileURL), "\(v.registeredDraggedTypes)")
    }
}
