import AppKit
import XCTest
@testable import Paperole

/// The promo's debug-script hooks (design/promo/STORYBOARD.md §9): `mark` leaves its ProcessInfo.systemUptime in its
/// file and in the output (A1), and `typeslow` types one character at a time at a seeded, repeatable rhythm (A2).
@MainActor
final class DebugScriptHooksTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("pc-hooks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Runs a script against a PDF view in a window never shown (with `field` as its first responder) until it has
    /// written its output; its lines.
    private func run(_ spec: String, field: NSTextView? = nil) throws -> [[String: Any]] {
        _ = NSApplication.shared
        let pdf = ReviewPDFView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let content = NSView(frame: pdf.frame)
        content.addSubview(pdf)
        let window = NSWindow(contentRect: content.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        defer { window.close() }
        if let field {
            content.addSubview(field)
            XCTAssertTrue(window.makeFirstResponder(field))
        }
        let c = PDFController()
        c.attach(pdf)
        let out = folder.appendingPathComponent("out.jsonl")
        let script = DebugScript(spec: spec, out: out.path, quit: false, controller: c)
        script.start()
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: out.path), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        let text = try String(contentsOf: out, encoding: .utf8)
        return try text.split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    // MARK: A1

    func testMarkWritesItsTimeToItsFileAndToTheOutput() throws {
        let t0 = ProcessInfo.processInfo.systemUptime
        let lines = try run("mark sized; wait 0.1; mark shot-hero")
        let t1 = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(lines.map { $0["mark"] as? String }, ["sized", "shot-hero"], "one line per mark, in order")
        let times = lines.compactMap { $0["uptime"] as? Double }
        XCTAssertEqual(times.count, 2)
        XCTAssertTrue(times.allSatisfy { $0 >= t0 && $0 <= t1 }, "the app's own uptime clock, as the frame times")
        XCTAssertGreaterThanOrEqual(times[1] - times[0], 0.1, "the wait between them")
        for (name, t) in zip(["sized", "shot-hero"], times) {
            let file = folder.appendingPathComponent("out.jsonl." + name)
            let held = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(try XCTUnwrap(Double(held)), t, accuracy: 1e-6, "the mark's file holds the same time")
        }
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(left, ["out.jsonl", "out.jsonl.shot-hero", "out.jsonl.sized"], "no temporary file beside them")
    }

    // MARK: A2

    func testTypeslowArgumentsKeepTheTextsSpaces() throws {
        let a = try XCTUnwrap(DebugScript.typeslowArguments("16 Table 1 says +3.7. Which is right?"))
        XCTAssertEqual(a.cps, 16)
        XCTAssertEqual(a.text, "Table 1 says +3.7. Which is right?", "the rest of the item, inner spaces kept")
        XCTAssertEqual(DebugScript.typeslowArguments("12.5 \" Split it in two. \"")?.text, " Split it in two. ",
                       "in double quotes, its spaces at either end too")
        XCTAssertEqual(DebugScript.typeslowArguments("12.5 \" Split it in two. \"")?.cps, 12.5)
        XCTAssertEqual(DebugScript.typeslowArguments("16 \"\"")?.text, "", "empty quotes: nothing")
        XCTAssertEqual(DebugScript.typeslowArguments("16 \"")?.text, "\"", "a lone quote is text")
        XCTAssertEqual(DebugScript.typeslowArguments("16 say \"hi\" now")?.text, "say \"hi\" now", "inner quotes kept")
        XCTAssertEqual(DebugScript.typeslowArguments("16")?.text, "")
        for bad in ["", "fast hello", "0 hello", "-4 hello", "inf hello", "nan hello"] {
            XCTAssertNil(DebugScript.typeslowArguments(bad), bad)
        }
    }

    func testTypingPausesRepeatAndStayWithinThirtyPercent() {
        let p = DebugScript.typingPauses(cps: 16, count: 400)
        XCTAssertEqual(p, DebugScript.typingPauses(cps: 16, count: 400), "a fixed seed: every run the same")
        XCTAssertEqual(Array(p.prefix(37)), DebugScript.typingPauses(cps: 16, count: 37), "a shorter text, the same start")
        XCTAssertNotEqual(p, DebugScript.typingPauses(cps: 16, count: 400, seed: 7))
        XCTAssertTrue(p.allSatisfy { $0 >= 0.7 / 16 && $0 <= 1.3 / 16 }, "±30% of 1/cps")
        XCTAssertEqual(p.reduce(0, +) / Double(p.count), 1.0 / 16, accuracy: 0.03 / 16, "about cps on average")
        XCTAssertLessThan(p.min()!, 0.8 / 16, "it jitters")
        XCTAssertGreaterThan(p.max()!, 1.2 / 16, "both ways")
        for (a, b) in zip(DebugScript.typingPauses(cps: 8, count: 10), DebugScript.typingPauses(cps: 16, count: 10)) {
            XCTAssertEqual(a * 8, b * 16, accuracy: 1e-12, "the rhythm scales with cps")
        }
        XCTAssertEqual(DebugScript.typingPauses(cps: 16, count: 0), [])
    }

    func testTypeslowInsertsOneCharacterAtATimeIntoTheFocusedField() throws {
        let field = InsertRecorder(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        let lines = try run("typeslow 40 Still hard; typeslow 40 \" to parse τ.\"; mark end", field: field)
        XCTAssertEqual(field.string, "Still hard to parse τ.", "spaces inside and at the quoted text's start survive")
        XCTAssertEqual(field.inserts, Array("Still hard to parse τ.").map(String.init), "one insert per character")
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0]["typeslow"] as? String, "Still hard")
        XCTAssertEqual(lines[0]["typed"] as? Int, 10)
        XCTAssertEqual(lines[1]["typeslow"] as? String, " to parse τ.")
        XCTAssertEqual(lines[1]["typed"] as? Int, 12, "τ is one character")
        // the characters on the pauses' timeline: the first to the last is the sum of all pauses but the last
        let start = try XCTUnwrap(lines[0]["start"] as? Double), end = try XCTUnwrap(lines[0]["end"] as? Double)
        let planned = DebugScript.typingPauses(cps: 40, count: 10).dropLast().reduce(0, +)
        XCTAssertGreaterThanOrEqual(end - start, planned - 0.02)
        XCTAssertLessThan(end - start, planned + 0.25)
        let mark = try XCTUnwrap(lines[2]["uptime"] as? Double)
        let second = try XCTUnwrap(lines[1]["end"] as? Double)
        XCTAssertGreaterThanOrEqual(mark - second, DebugScript.typingPauses(cps: 40, count: 12).last! - 0.02,
                                    "the next item a pause after the last character")
    }

    func testTypeslowWithoutAFieldTypesNothingAndSaysSo() throws {
        let lines = try run("typeslow 50 abc; typeslow quick abc")
        XCTAssertEqual(lines.first?["typed"] as? Int, 0, "no text field has focus")
        XCTAssertNotNil(lines.last?["error"], "a <cps> that is not a number")
    }
}

/// A text view that records each insertText, as the app's editors get them.
private final class InsertRecorder: NSTextView {
    var inserts: [String] = []

    override func insertText(_ string: Any, replacementRange: NSRange) {
        inserts.append(string as? String ?? (string as? NSAttributedString)?.string ?? "")
        super.insertText(string, replacementRange: replacementRange)
    }
}
