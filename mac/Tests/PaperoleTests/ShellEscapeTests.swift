import AppKit
import XCTest
@testable import Paperole

/// Shell escape per paper (UX.md §41; engine/CONTRACT.md amendment "Shell escape per paper, 2026-11-01"): the state's
/// new keys, what the build's Details offer, the sheet's toggle, and with the engine what ingest and edit_paper send.
/// Synthetic papers and fixtures only.
@MainActor
final class ShellEscapeTests: XCTestCase {
    private let fm = FileManager.default
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("pc-shell-escape-" + UUID().uuidString)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: tmp) }

    // MARK: Helpers

    private func fixture(_ edit: (inout [String: Any]) throws -> Void = { _ in }) throws -> EngineState {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: StepTests.fixtures
            .appendingPathComponent("state-round2.json"))) as? [String: Any])
        try edit(&json)
        return try EngineState.decode(JSONSerialization.data(withJSONObject: json))
    }

    /// The round-2 fixture's open round, its build asking for shell escape (`needs`), the paper's choice (`on`), and
    /// (`fresh`) only carried comments without an answer, so it can be built again.
    private func asking(needs: Bool = true, on: Bool? = nil, fresh: Bool = false) throws -> EngineState {
        try fixture { json in
            var round = try XCTUnwrap(json["round"] as? [String: Any]), build = try XCTUnwrap(round["build"] as? [String: Any])
            build["shell_escape"] = false
            build["needs_shell_escape"] = needs
            build["errors"] = [["file": "preamble.tex", "line": 28,
                                "message": "Package minted Error: You must invoke LaTeX with the -shell-escape flag."]]
            round["build"] = build
            json["round"] = round
            if let on {
                var paper = try XCTUnwrap(json["paper"] as? [String: Any])
                paper["shell_escape"] = on
                json["paper"] = paper
            }
            if fresh {
                let cs = try XCTUnwrap(json["comments"] as? [[String: Any]])
                json["comments"] = cs.filter { $0["carried"] as? Bool == true }.map { c in
                    var c = c
                    c["verdict"] = NSNull()
                    return c
                }
            }
        }
    }

    private func fixtureModel() -> AppModel {
        _ = NSApplication.shared
        var o = LaunchOptions()
        o.fixture = StepTests.fixtures.appendingPathComponent("state-round2.json").path
        o.drafts = tmp.appendingPathComponent("drafts").path
        o.cache = tmp.appendingPathComponent("cache").path
        o.tags = tmp.appendingPathComponent("tags.json").path
        return AppModel(options: o)
    }

    /// A model with the engine and no list of its own (--no-list: papers.json neither read nor written).
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

    private func until(_ seconds: Double = 60, _ done: () -> Bool) async throws {
        for _ in 0..<Int(seconds * 20) where !done() { try await Task.sleep(nanoseconds: 50_000_000) }
    }

    // MARK: The state

    /// The three keys decode when the engine sends them, and are nil from an engine before them (the official app's
    /// frozen one, an old fixture): nothing is offered then.
    func testTheNewKeysDecodeAndAreOptional() throws {
        let new = try EngineState.decode(Data("""
        {"schema": 1, "paper": {"path": "/p", "title": "T", "student": "S", "main": "main.tex", "engine": "pdflatex",
                                "id": "p-0123456789abcdef", "shell_escape": true},
         "rounds": [{"n": 1, "created": "2026-11-01T10:00:00+08:00", "source": "/src", "closed": false, "closed_at": null,
                     "status": "ok", "pdf": "/p/r1/build/main.pdf"}],
         "round": {"n": 1, "closed": false, "created": "2026-11-01T10:00:00+08:00", "closed_at": null,
                   "build": {"status": "ok", "pdf": "/p/r1/build/main.pdf", "pages": 1, "warnings": [], "errors": [],
                             "log_tail": "", "shell_escape": true, "needs_shell_escape": false},
                   "final_pdf": null, "email": null},
         "comments": [], "changes": []}
        """.utf8))
        XCTAssertEqual(new.paper.shellEscape, true)
        XCTAssertEqual(new.round?.build.shellEscape, true)
        XCTAssertEqual(new.round?.build.needsShellEscape, false)

        let asks = try makeDecoder().decode(Build.self, from: Data("""
        {"status": "errors", "pdf": "/p/r1/build/main.pdf", "pages": 1, "warnings": [], "log_tail": "",
         "errors": [{"file": "preamble.tex", "line": 28,
                     "message": "Package minted Error: You must invoke LaTeX with the -shell-escape flag."}],
         "shell_escape": false, "needs_shell_escape": true}
        """.utf8))
        XCTAssertEqual(asks.shellEscape, false)
        XCTAssertEqual(asks.needsShellEscape, true)

        let old = try EngineState.decode(Data(contentsOf: StateDecodingTests.fixture))
        XCTAssertNil(old.paper.shellEscape)
        XCTAssertNil(old.round?.build.shellEscape)
        XCTAssertNil(old.round?.build.needsShellEscape)
        XCTAssertNil(ShellEscapeOffer.of(needs: old.round?.build.needsShellEscape == true, latest: true, canBuildAgain: true,
                                         paperOn: old.paper.shellEscape == true), "an engine before it: nothing offered")
    }

    // MARK: What the Details offer

    /// Only for the latest round while its build asks for it: Build Again with Shell Escape… while the round can be
    /// built again, else Turn On Shell Escape… until the paper has it.
    func testTheOffer() {
        typealias O = ShellEscapeOffer
        XCTAssertEqual(O.of(needs: true, latest: true, canBuildAgain: true, paperOn: false), .buildAgain)
        XCTAssertEqual(O.of(needs: true, latest: true, canBuildAgain: true, paperOn: true), .buildAgain,
                       "on for the next round, this one built without: built again with it")
        XCTAssertEqual(O.of(needs: true, latest: true, canBuildAgain: false, paperOn: false), .turnOn)
        XCTAssertNil(O.of(needs: true, latest: true, canBuildAgain: false, paperOn: true), "already on for the next round")
        XCTAssertNil(O.of(needs: true, latest: false, canBuildAgain: false, paperOn: false), "an earlier round")
        XCTAssertNil(O.of(needs: false, latest: true, canBuildAgain: true, paperOn: false))
        XCTAssertEqual(O.buildAgain.title, "Build Again with Shell Escape…")
        XCTAssertEqual(O.turnOn.title, "Turn On Shell Escape…")
    }

    /// The model's offer follows the shown round, Build Round N Again…'s rule and the paper's choice; its button opens
    /// the sheet with the toggle on, or the confirmation with the round's words; Retry… and Build Round N Again… open
    /// the sheet with it off.
    func testTheModelsOfferAndItsButton() throws {
        let m = fixtureModel()
        XCTAssertNil(m.shellEscapeOffer, "the fixture's build asks for nothing")
        m.apply(try asking())
        XCTAssertFalse(m.canBuildAgain, "round 2 has new comments and verdicts")
        XCTAssertEqual(m.shellEscapeOffer, .turnOn)
        m.showBuildDetails = true
        m.takeShellEscapeOffer(.turnOn)
        XCTAssertFalse(m.showBuildDetails, "the Details close for the confirmation")
        let ask = try XCTUnwrap(m.confirmShellEscape)
        XCTAssertEqual(ask.paper, try XCTUnwrap(m.selectedPath), "the paper it asks about, for Turn On")
        XCTAssertEqual(ask.title, "Turn on shell escape for this paper?")
        XCTAssertEqual(ask.message, "Round 3 and later will build with it; Round 2 stays as built. It lets this paper’s LaTeX "
                       + "run commands on your Mac, so use it only for a source you trust.")
        XCTAssertFalse(m.showRetry)
        m.confirmShellEscape = nil

        m.apply(try asking(on: true))
        XCTAssertNil(m.shellEscapeOffer, "on for the next round already: Turn Off is the Details' link")
        m.apply(try asking(on: false, fresh: true))
        XCTAssertTrue(m.canBuildAgain)
        XCTAssertEqual(m.shellEscapeOffer, .buildAgain)
        m.showBuildDetails = true
        m.takeShellEscapeOffer(.buildAgain)
        XCTAssertFalse(m.showBuildDetails)
        XCTAssertTrue(m.showRetry)
        XCTAssertTrue(m.retryWithShellEscape, "the sheet's toggle starts on")
        XCTAssertNil(m.confirmShellEscape)
        m.showRetry = false
        m.openRetry()  // Retry…, Build Round N Again…
        XCTAssertTrue(m.showRetry)
        XCTAssertFalse(m.retryWithShellEscape)

        m.apply(try asking(needs: false, fresh: true))
        XCTAssertNil(m.shellEscapeOffer)
        m.apply(try fixture { json in
            var round = try XCTUnwrap(json["round"] as? [String: Any]), build = try XCTUnwrap(round["build"] as? [String: Any])
            build["needs_shell_escape"] = true
            round["build"] = build
            round["n"] = 1
            json["round"] = round
            json["comments"] = []
        })
        XCTAssertNil(m.shellEscapeOffer, "an earlier round shown")

        m.apply(try asking())
        m.takeShellEscapeOffer(.turnOn)
        XCTAssertNotNil(m.confirmShellEscape)
        m.selectPaper(nil)  // another place chosen while it asks (Go › Back, Jump to…): the confirmation goes
        XCTAssertNil(m.confirmShellEscape)
    }

    /// The about line names shell escape for a round built with it; the source follows.
    func testTheAboutLine() {
        let paper = PaperInfo(path: "/p", title: "T", student: "S", main: "main.tex", engine: "pdflatex", shellEscape: true)
        var b = Build(status: "ok", pdf: "/p/r1/build/main.pdf", pages: 1, warnings: [], errors: [], shellEscape: true,
                      needsShellEscape: false)
        XCTAssertEqual(BuildDetails.about(paper, build: b, source: "/Users/s/minted"),
                       ["pdflatex · main.tex · shell escape", "Source: minted"])
        b.shellEscape = false
        XCTAssertEqual(BuildDetails.about(paper, build: b, source: nil), ["pdflatex · main.tex"], "built without, whatever the paper's choice")
        b.shellEscape = nil
        XCTAssertEqual(BuildDetails.about(paper, build: b, source: nil), ["pdflatex · main.tex"], "an engine before it")
        XCTAssertEqual(BuildDetails.about(nil, build: b, source: "/s/src.zip"), ["Source: src.zip"])
    }

    /// A failed minted build without shell escape misses minted's own output, which no student sends: the page names no
    /// missing file for it, and still names a real one after it.
    func testMintedsOwnOutputIsNoMissingFile() throws {
        let b = try makeDecoder().decode(Build.self, from: Data("""
        {"status": "failed", "pdf": null, "warnings": [], "log_tail": "",
         "errors": [{"file": "main.tex", "line": 3,
                     "message": "Package minted Error: You must invoke LaTeX with the -shell-escape flag."},
                    {"file": "main.tex", "line": 7,
                     "message": "Package catchfile Error: File `_minted-main/default.pygstyle' not found."}],
         "shell_escape": false, "needs_shell_escape": true}
        """.utf8))
        XCTAssertNil(missingFile(b))
        var both = b
        both.logTail = "File `_minted-main/default.pygstyle' not found.\n! LaTeX Error: File `tables/results.tex' not found."
        XCTAssertEqual(missingFile(both), "tables/results.tex")
    }

    // MARK: The sheet

    /// The toggle shows only where it matters, never for Start Round 1.
    func testTheSheetsToggleShowsOnlyWhereItMatters() {
        func shows(_ hasRound: Bool = true, asked: Bool = false, on: Bool = false, needs: Bool = false) -> Bool {
            RetrySheet.showsShellEscape(hasRound: hasRound, asked: asked, paperOn: on, latestNeeds: needs)
        }
        XCTAssertFalse(shows(), "Retry… and Build Round N Again… of a paper that never asked")
        XCTAssertTrue(shows(asked: true), "Build Again with Shell Escape…")
        XCTAssertTrue(shows(on: true), "the paper has it on: also the way to build without it")
        XCTAssertTrue(shows(needs: true), "the latest build asks for it")
        XCTAssertFalse(shows(false, asked: true, on: true, needs: true), "no round yet: Start Round 1")
    }

    // MARK: With the engine

    /// What the app sends, as the engine keeps it: ingest's shell_escape given is the paper's choice and the build's;
    /// not given, the engine builds as the ledger has it (changed there behind the model, so a model that sent its own
    /// choice would build otherwise); edit_paper's alone turns it off and on without a build, the round shown staying as
    /// built. A synthetic minted paper: built without, minted's error asks for it.
    func testIngestAndEditPaperSendTheChoice() async throws {
        let m = try engineModel()
        let paper = tmp.appendingPathComponent("Reviews/Kelp code").path, src = tmp.appendingPathComponent("src")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try Data("""
        \\documentclass{article}
        \\usepackage{minted}
        \\begin{document}
        Kelp drifts in the bay.
        \\begin{minted}{python}
        def drift():
            return 1
        \\end{minted}
        \\end{document}

        """.utf8).write(to: src.appendingPathComponent("main.tex"))
        try await rpc(m, "new", ["paper": paper, "title": "Kelp code", "student": "Mei Lin"])
        m.selectPaper(paper)
        try await until { m.state != nil && !m.busy }

        m.ingest(source: src.path)
        try await until { m.state?.round != nil && !m.busy }
        var b = try XCTUnwrap(m.round?.build)
        XCTAssertNil(m.alertMessage)
        XCTAssertEqual(m.state?.paper.shellEscape, false)
        XCTAssertEqual(b.shellEscape, false)
        XCTAssertEqual(b.needsShellEscape, true, b.errors.map(errorLine).joined(separator: "\n"))
        XCTAssertNotNil(b.pdf, "minted's error, and a PDF")
        XCTAssertEqual(m.shellEscapeOffer, .buildAgain)

        m.ingest(source: src.path, shellEscape: true)
        try await until { m.round?.build.shellEscape == true && !m.busy }
        b = try XCTUnwrap(m.round?.build)
        XCTAssertNil(m.alertMessage)
        XCTAssertEqual(m.state?.paper.shellEscape, true)
        XCTAssertEqual(b.shellEscape, true)
        XCTAssertEqual(b.needsShellEscape, false)
        XCTAssertNil(m.shellEscapeOffer)
        XCTAssertEqual(BuildDetails.about(m.state?.paper, build: b, source: m.lastSource)[0], "pdflatex · main.tex · shell escape")
        // pygmentize beside the engine's Python (the venv's bin, last on latexmk's PATH): minted lists the code
        if fm.isExecutableFile(atPath: (EngineClient.defaultPython as NSString).deletingLastPathComponent + "/pygmentize") {
            XCTAssertEqual(b.status, "ok", b.errors.map(errorLine).joined(separator: "\n"))
        }

        m.setShellEscape(false)
        try await until { m.state?.paper.shellEscape == false && !m.busy }
        XCTAssertNil(m.alertMessage, "edit_paper given only shell_escape")
        XCTAssertEqual(m.state?.paper.shellEscape, false)
        XCTAssertEqual(m.round?.build.shellEscape, true, "the round stays as built")
        XCTAssertEqual(m.state?.rounds.count, 1)
        m.setShellEscape(true)
        try await until { m.state?.paper.shellEscape == true && !m.busy }
        XCTAssertEqual(m.state?.paper.shellEscape, true)

        // nothing sent: the engine builds as the ledger has it, off there behind the model (which still has it on), so
        // a model that sent its own choice would build with it
        try await rpc(m, "edit_paper", ["paper": paper, "shell_escape": false])
        XCTAssertEqual(m.state?.paper.shellEscape, true)
        let version = m.stateVersion
        m.ingest(source: src.path)
        try await until { !m.busy }
        XCTAssertNil(m.alertMessage)
        XCTAssertGreaterThan(m.stateVersion, version, "built again")
        XCTAssertEqual(m.round?.build.shellEscape, false, "built as the ledger has it: nothing sent")
        XCTAssertEqual(m.state?.paper.shellEscape, false)
        m.setShellEscape(true)
        try await until { m.state?.paper.shellEscape == true && !m.busy }

        m.ingest(source: src.path, shellEscape: false)
        try await until { m.round?.build.shellEscape == false && !m.busy }
        XCTAssertNil(m.alertMessage)
        XCTAssertEqual(m.state?.paper.shellEscape, false)
        XCTAssertEqual(m.round?.build.needsShellEscape, true)
        XCTAssertEqual(m.state?.rounds.count, 1, "built again: still Round 1")
    }

    // MARK: Folders listed where they are

    /// Trust does not travel for a review folder listed where it is, as for a paper from a file (the engine's
    /// `archive._distrusted`): one new to the list comes in with shell escape off, by Add Existing… of one folder
    /// (listed at once), by Import of a folder holding several, as a listed folder moved in Finder, and as Keep Both of
    /// a Finder copy of a listed one; a folder listed already keeps it. The ledgers have it on as another Mac's may.
    func testAFolderListedWhereItIsComesInWithItOff() async throws {
        let m = try engineModel()
        func on(_ path: String) throws -> Bool? {
            let url = URL(fileURLWithPath: path).appendingPathComponent("ledger.json")
            let lg = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            return ((lg as? [String: Any])?["paper"] as? [String: Any])?["shell_escape"] as? Bool
        }
        func made(_ folder: String, _ title: String) async throws -> String {
            let path = tmp.appendingPathComponent(folder).path
            try await rpc(m, "new", ["paper": path, "title": title, "student": "Mei Lin"])
            try await rpc(m, "edit_paper", ["paper": path, "shell_escape": true])
            return path
        }
        func imported(_ folder: String, _ choice: ImportPlan.Choice? = nil) async throws -> ImportPlan {
            m.data.checkImport(URL(fileURLWithPath: folder), origin: .window)
            for _ in 0..<1200 where m.data.working { try await Task.sleep(nanoseconds: 50_000_000) }
            let plan = try XCTUnwrap(m.data.importing?.plan, m.data.importing?.error ?? "")
            if let choice { m.data.importing?.plan?.items[0].choice = choice }
            m.data.performImport()
            for _ in 0..<1200 where m.data.working { try await Task.sleep(nanoseconds: 50_000_000) }
            XCTAssertNil(m.data.importing?.report?.stopped, m.data.importing?.report?.stopped ?? "")
            m.data.closeImport()
            return plan
        }

        let kelp = try await made("Found/Kelp drift", "Kelp drift")
        m.data.checkImport(URL(fileURLWithPath: kelp), origin: .window)  // Add Existing…: listed at once
        try await until { m.selectedPath == kelp && m.state != nil && !m.busy && !m.data.working }
        XCTAssertNil(m.alertMessage)
        XCTAssertNil(try on(kelp))
        XCTAssertEqual(m.state?.paper.shellEscape, false)
        XCTAssertEqual(m.papers.map(\.path), [kelp])
        try await rpc(m, "edit_paper", ["paper": kelp, "shell_escape": true])  // turned on here, once listed
        m.addReviewFolder(kelp)
        try await until { m.state?.paper.shellEscape == true && !m.busy }
        XCTAssertEqual(try on(kelp), true, "a folder listed already keeps it")

        let reef = try await made("More/Reef choruses", "Reef choruses")
        let sonar = try await made("More/Sonar pings", "Sonar pings")
        let more = try await imported(tmp.appendingPathComponent("More").path)
        XCTAssertEqual(more.items.map { "\($0.choice) \($0.paper.inPlace)" }, ["add true", "add true"])
        XCTAssertNil(try on(reef))
        XCTAssertNil(try on(sonar))

        try await until { m.papers.first { $0.path == reef }?.ledgerID != nil }  // its id, so the list knows it moved
        try await rpc(m, "edit_paper", ["paper": reef, "shell_escape": true])
        let moved = tmp.appendingPathComponent("Moved/Reef choruses").path
        try fm.createDirectory(at: tmp.appendingPathComponent("Moved"), withIntermediateDirectories: true)
        try fm.moveItem(atPath: reef, toPath: moved)
        m.noteMissing()
        let back = try await imported(moved)
        XCTAssertEqual(back.items.map { "\($0.choice) \($0.paper.inPlace)" }, ["putBack true"])
        XCTAssertNil(try on(moved), "listed at its new place, off")

        let copy = tmp.appendingPathComponent("Copy/Kelp drift").path
        try fm.createDirectory(at: tmp.appendingPathComponent("Copy"), withIntermediateDirectories: true)
        try fm.copyItem(atPath: kelp, toPath: copy)
        let both = try await imported(copy, .keepBoth)
        XCTAssertEqual(both.items.map { "\($0.group) \($0.paper.inPlace)" }, ["here true"])
        XCTAssertNil(try on(copy), "Keep Both: the copy, off")
        XCTAssertEqual(try on(kelp), true, "yours as it was")
        XCTAssertEqual(Set(m.papers.map(\.path)), [kelp, sonar, moved, copy])
    }
}
