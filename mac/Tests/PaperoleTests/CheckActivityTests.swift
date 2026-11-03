import AppKit
import SwiftUI
import XCTest
@testable import Paperole

@MainActor
final class CheckActivityTests: XCTestCase {
    private var model: AppModel!
    private var drafts: URL!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        drafts = FileManager.default.temporaryDirectory.appendingPathComponent("check-log-" + UUID().uuidString)
        var options = LaunchOptions()
        options.fixture = StepTests.fixtures.appendingPathComponent("state-reading.json").path
        options.drafts = drafts.path
        options.checks = true
        model = AppModel(options: options)
        model.refs.store = nil  // snapshot tests never start an engine to persist their stand-in results
        model.lookUp = []
        model.setChecks([], round: 2)
        model.checks.report = CheckScanReport(startedAt: "2026-11-03T10:00:00Z", completedAt: "2026-11-03T10:00:03Z", rules: [rule()])
    }

    override func tearDownWithError() throws {
        for source in RefSource.allCases { model.refs.stop(source) }
        try? FileManager.default.removeItem(at: drafts)
    }

    private func rule(_ status: String = "done", count: Int = 0) -> CheckRuleRun {
        CheckRuleRun(code: "short_last_line", group: "typesetting", title: "Short last lines", count: count,
                     status: status, detail: "16 of 16 body paragraphs mapped before the bibliography.", online: false)
    }

    func testNoFindingsIsDifferentFromFailureAndUnknownCoverage() {
        XCTAssertEqual(CheckActivitySnapshot(model).headline, "Checks complete · No findings")
        for status in ["failed", "partial", "unavailable"] {
            model.checks.report?.rules = [rule(status)]
            let snapshot = CheckActivitySnapshot(model)
            XCTAssertEqual(snapshot.headline, "Checks incomplete")
            XCTAssertTrue(snapshot.attention)
            XCTAssertFalse(snapshot.text.contains("No findings"))
        }
        model.checks.report = nil
        XCTAssertEqual(CheckActivitySnapshot(model).headline, "Checks · No scan record")
    }

    func testCompleteLogIncludesAllRulesScopeAndFindings() {
        let finding = Check(code: "short_last_line", group: "typesetting", text: "Paragraph ends in one word",
                            detail: "A single word falls on the last line.", places: [.init(page: 2, rects: [])])
        model.setChecks([finding], round: 2)
        model.checks.report?.rules = [rule(count: 1), CheckRuleRun(code: "pdf_author", group: "submission",
            title: "Author names in PDF metadata", count: 0, status: "skipped", detail: "No anonymous mode selected.", online: false)]
        let log = CheckActivitySnapshot(model).text
        for text in ["Round 2", "Short last lines: 1 finding", "16 of 16", finding.text, finding.detail!,
                     "Author names in PDF metadata: Not applicable", "No anonymous mode selected.", "Google Scholar: Off"] {
            XCTAssertTrue(log.contains(text), text)
        }
        XCTAssertNil(model.panelToast.text, "no success notification is needed for a readable log")
    }

    func testLogKeepsFindingsExcludedFromTheReviewList() {
        let finding = Check(code: "short_last_line", group: "typesetting", text: "A previously accepted short ending", ok: true)
        model.checks.scanFindings = [finding]
        model.checks.report?.rules = [rule(count: 1)]
        XCTAssertTrue(model.checks.list.isEmpty)
        XCTAssertTrue(CheckActivitySnapshot(model).text.contains(finding.text))
    }

    func testOffAndNotApplicableAreNotFailed() {
        model.checks.report?.rules = [rule("skipped"), rule("off")]
        XCTAssertFalse(CheckActivitySnapshot(model).attention)
        model.checks.report?.rules = [rule("off")]
        XCTAssertEqual(CheckActivitySnapshot(model).headline, "No checks selected")
        model.checksOn = false
        XCTAssertEqual(CheckActivitySnapshot(model).headline, "Checks off")
    }

    func testLocalCompletionDoesNotClaimOnlineCompletion() {
        model.lookUp = [.googleScholar]
        let entry = RefEntry(key: "synthetic", title: "Synthetic bounded queues")
        model.showReferences([entry], [:])
        model.refs.start(paper: model.selectedPath!, round: 2, entries: [entry], stored: [:], sources: [.googleScholar])
        let snapshot = CheckActivitySnapshot(model)
        XCTAssertEqual(snapshot.headline, "Checks · Looking up references…")
        XCTAssertEqual(snapshot.rules.first?.conclusion, "No findings")
        XCTAssertEqual(snapshot.sources.last?.rows.first?.conclusion, "Pending")
        model.refs.deliver(.init(paper: model.selectedPath!, round: 2, entry: entry, source: .googleScholar),
                           RefResult(found: false))
        model.showReferences([entry], ["google_scholar": [entry.key: RefResult(found: false)]])
        XCTAssertTrue(CheckActivitySnapshot(model).headline.hasPrefix("Checks complete"))
        XCTAssertTrue(CheckActivitySnapshot(model).text.contains("No matching record"))
    }

    func testSavedFailureIsNeitherNoRecordNorCompleted() {
        model.lookUp = [.googleScholar]
        let entry = RefEntry(key: "synthetic", title: "Synthetic bounded queues")
        model.showReferences([entry], [:])
        model.refs.start(paper: model.selectedPath!, round: 2, entries: [], stored: [:], sources: [.googleScholar],
                         recorded: ["google_scholar": [entry.key: RefAttempt("unavailable", at: "2026-11-03T09:00:00Z")]])
        let snapshot = CheckActivitySnapshot(model)
        XCTAssertEqual(snapshot.headline, "Checks incomplete")
        XCTAssertTrue(snapshot.text.contains("No usable response"))
        XCTAssertFalse(snapshot.text.contains("No matching record"))
        XCTAssertEqual(model.refShown(entry.key)?.counts.first?.count, .pending, "a failure is not a bibliographic result")
    }

    func testQueueForAnotherRoundDoesNotChangeThisStatus() {
        model.lookUp = [.googleScholar]
        model.refs.start(paper: "/synthetic-other-paper", round: 1,
                         entries: [RefEntry(key: "another", title: "Synthetic second paper")], stored: [:], sources: [.googleScholar])
        XCTAssertTrue(CheckActivitySnapshot(model).headline.hasPrefix("Checks complete"))
        XCTAssertFalse(CheckActivitySnapshot(model).text.contains("Synthetic second paper"))
    }

    func testPreviousRoundsReferenceRecordsAreNotShownWhileNextRoundLoads() throws {
        model.lookUp = [.googleScholar]
        let entry = RefEntry(key: "previous", title: "Synthetic previous round reference")
        model.showReferences([entry], ["google_scholar": [entry.key: RefResult(found: true, citations: 8)]])
        XCTAssertTrue(CheckActivitySnapshot(model).text.contains(entry.title!))
        var state = try XCTUnwrap(model.state)
        state.round?.n = 1
        model.apply(state)
        XCTAssertFalse(CheckActivitySnapshot(model).text.contains(entry.title!))
    }

    func testSavedLookupResultsKeepTheirOriginalRecordedTime() {
        model.lookUp = [.semanticScholar]
        let entry = RefEntry(key: "stored", title: "Synthetic stored reference")
        let result = RefResult(found: true, title: entry.title, year: 2025, venue: "Synthetic Conference", citations: 9)
        let recorded = RefAttempt("matched", at: "2026-11-01T10:00:00Z")
        model.showReferences([entry], ["semantic_scholar": [entry.key: result]])
        model.refs.start(paper: model.selectedPath!, round: 2, entries: [entry],
                         stored: ["semantic_scholar": [entry.key: result]], sources: [.semanticScholar],
                         recorded: ["semantic_scholar": [entry.key: recorded]])
        let snapshot = CheckActivitySnapshot(model)
        XCTAssertTrue(snapshot.text.contains("Synthetic Conference · 9 citations"))
        XCTAssertTrue(snapshot.text.contains(CheckActivitySnapshot.date(recorded.at)))
        XCTAssertEqual(snapshot.sources.first?.rows.first?.conclusion, "Record found")
        XCTAssertTrue(snapshot.headline.hasPrefix("Checks complete"))
    }

    func testRefreshingAndClearingDiscardStaleReport() {
        model.checks.refreshing = true
        XCTAssertEqual(CheckActivitySnapshot(model).headline, "Updating check log…")
        model.checks.clear()
        XCTAssertNil(model.checks.report)
        XCTAssertNil(model.checks.reportError)
        XCTAssertFalse(model.checks.refreshing)
        XCTAssertFalse(CheckActivitySnapshot(model).text.contains("16 of 16"))
    }

    func testEngineReportDecodesAndKeepsTimestamp() throws {
        let json = #"{"round":2,"checks":[],"report":{"started_at":"2026-11-03T10:00:00+00:00","completed_at":"2026-11-03T10:00:03+00:00","rules":[{"code":"spelling","group":"consistency","title":"Inconsistent spelling","count":0,"status":"done","detail":"Body text","online":false}]}}"#
        let reply = try makeDecoder().decode(ChecksReply.self, from: Data(json.utf8))
        XCTAssertEqual(reply.report?.completedAt, "2026-11-03T10:00:03+00:00")
        XCTAssertEqual(reply.report?.rules.first?.conclusion, "No findings")
    }

    func testUnusableOnlineResponseIsRecordedWithoutInventingAResult() async throws {
        let lookup = RefLookup(cacheURL: nil, fetchers: [.semanticScholar: { _ in nil }])
        let saved = expectation(description: "lookup failure recorded")
        lookup.store = { _, _, _, results, attempts in
            XCTAssertTrue(results.isEmpty)
            XCTAssertEqual(attempts["synthetic"]?.status, "unavailable")
            saved.fulfill()
        }
        lookup.start(paper: "/synthetic", round: 1, entries: [RefEntry(key: "synthetic", title: "Synthetic queues")],
                     stored: [:], sources: [.semanticScholar])
        await fulfillment(of: [saved], timeout: 2)
        XCTAssertNil(lookup.line(paper: "/synthetic", round: 1))
        XCTAssertEqual(lookup.attempts["/synthetic|1"]?[.semanticScholar]?["synthetic"]?.status, "unavailable")
    }

    func testActivityRendersInBothAppearances() throws {
        model.checks.report?.rules = [rule(count: 2), CheckRuleRun(code: "paragraph_break", group: "typesetting",
            title: "Single-line paragraph breaks", count: 0, status: "unavailable", detail: "No mapped body paragraphs.", online: false)]
        let host = NSHostingView(rootView: CheckActivityPanel(model: model, checks: model.checks, refs: model.refs,
                                                             expanded: ["typesetting", "google_scholar"]))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 590), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            host.appearance = NSAppearance(named: appearance)
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            host.layoutSubtreeIfNeeded()
            window.setContentSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(host.fittingSize.width, 481)
            if let directory = ProcessInfo.processInfo.environment["PAPEROLE_CHECK_LOG_SHOTS"] {
                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("check-log-\(name).png"))
            }
        }
    }

    func testStatusBarFitsAtMinimumPDFWidth() throws {
        let round = try XCTUnwrap(model.round)
        model.pdf.position.page = 7
        model.pdf.position.count = 30
        for width in [WindowLayout.pdf, CGFloat(960)] {
            let host = NSHostingView(rootView: BuildStatusLine(round: round, position: model.pdf.position)
                .environmentObject(model).frame(width: width, height: 26))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 26), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            host.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(host.fittingSize.width, width)
            if let directory = ProcessInfo.processInfo.environment["PAPEROLE_CHECK_LOG_SHOTS"] {
                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("check-bar-\(Int(width)).png"))
            }
        }
    }
}
