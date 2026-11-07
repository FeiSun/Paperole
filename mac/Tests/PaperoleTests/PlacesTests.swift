import AppKit
import XCTest
@testable import Paperole

/// A comment on several places in Review (design/comments/PLAN.md §3, 1 and 3, §6a; mac/UX.md §45): a mark and a
/// label at every place, the line between labels with the relation, the card's place lines and its count, Not found
/// only when every place is, [+ R1-05 ▾]'s candidates and the place's undo. Synthetic fixtures only.
@MainActor
final class PlacesTests: XCTestCase {
    private var dir: URL!
    private var windows: [NSWindow] = []

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-places-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for w in windows { w.close() }
        windows = []
        try? FileManager.default.removeItem(at: dir)
    }

    private func place(_ key: String = "b", page: Int? = 0, state: String = "changed", name: String? = "Table 1",
                       rects: [[Double]] = [[181.7, 391.04, 283.27, 401.0]]) -> [String: Any] {
        ["key": key, "kind": "highlight", "added": 1, "page": page as Any? ?? NSNull(), "rects": rects, "text": "34.9",
         "anchor_state": state, "confidence": 0.9, "method": "diff", "name": name as Any? ?? NSNull(), "changes": []]
    }

    func testNotFoundOnlyWhenEveryPlaceIs() throws {
        let lost = try makeComment(["anchor_state": "orphan", "page": NSNull(), "rects": []])
        XCTAssertEqual(Status(lost), .notFound)
        let one = try makeComment(["anchor_state": "orphan", "page": NSNull(), "rects": [], "places": [place()]])
        XCTAssertEqual(Status(one), .toCheck, "its other place is found")
        XCTAssertEqual(one.shownPlace.page, 0, "shown from the place found")
        let none = try makeComment(["anchor_state": "orphan", "page": NSNull(), "rects": [],
                                    "places": [place(page: nil, state: "orphan", rects: [])]])
        XCTAssertEqual(Status(none), .notFound)
    }

    func testTheCardCountsThePlacesRevisedAndNamesEach() throws {
        let c = try makeComment(["anchor_state": "unchanged", "name": "§1 Introduction", "page": 0, "relation": "does not match",
                                 "places": [place(page: 3)]])
        let card = CardModel(c, round: 2, pdfs: [:], textX: [], showChanges: true)
        XCTAssertEqual(card.stateWord, "1 of 2 revised")
        XCTAssertEqual(card.pageWords, "p.1 ⇄ p.4")
        XCTAssertEqual(card.relation, "does not match")
        XCTAssertEqual(card.places.map(\.name), ["§1 Introduction (p.1)", "Table 1 (p.4)"])
        XCTAssertEqual(card.places.map(\.state), ["unchanged", "revised"])
        XCTAssertTrue(card.turns.contains { $0.round == 2 && $0.verb.contains("1 of 2") }, "\(card.turns.map(\.verb))")
        // one place lost, none revised
        let lost = try makeComment(["anchor_state": "unchanged", "page": 0,
                                    "places": [place(page: nil, state: "orphan", name: nil, rects: [])]])
        XCTAssertEqual(CardModel(lost, round: 2, pdfs: [:], textX: [], showChanges: true).stateWord, "1 of 2 not found")
        XCTAssertEqual(CardModel(lost, round: 2, pdfs: [:], textX: [], showChanges: true).places.last?.name, "Place 2",
                       "a lost place without a name: never \"not found · not found\"")
        // a place added this round is new to the student too: no count, the row's own word
        var added = place(page: 3, state: "new")
        added["added"] = 2
        let new = CardModel(try makeComment(["anchor_state": "changed", "page": 0, "places": [added]]), round: 2, pdfs: [:],
                            textX: [], showChanges: true)
        XCTAssertEqual(new.stateWord, "revised")
        XCTAssertFalse(new.turns.contains { $0.verb.contains(" of ") })
        // nothing revised or lost: the row's own word stays ("moved to p.4", not "unchanged")
        let moved = CardModel(try makeComment(["anchor_state": "moved", "page": 3, "places": [place(page: 3, state: "unchanged")]]),
                              round: 2, pdfs: [:], textX: [], showChanges: true)
        XCTAssertEqual(moved.stateWord, "moved to p.4")
        // one place: as before
        let one = try makeComment(["anchor_state": "unchanged", "page": 0])
        let plain = CardModel(one, round: 2, pdfs: [:], textX: [], showChanges: true)
        XCTAssertTrue(plain.places.isEmpty)
        XCTAssertEqual(plain.pageWords, "p.1")
    }

    func testPlaceStepsUndoAndRekey() {
        var h = AnswerHistory()
        let s = PlaceStep(id: "R1-02", key: "b", page: 3, rects: [[1, 2, 3, 4]], text: "34.9", kind: "highlight")
        h.record(s)
        XCTAssertEqual(h.undo(), .place(s))
        XCTAssertEqual(h.redo(), .place(s))
        h.rekey(s, to: "c")
        var c = s
        c.key = "c"
        XCTAssertEqual(h.undo(), .place(c), "added again under its new key")
        h.forget("R1-02", answersOnly: true)
        XCTAssertEqual(h.redo(), .place(c), "typing in the field keeps place steps")
        // a place taken off: its place steps go, its answer stays
        let a = AnswerStep(id: "R1-02", before: Answer(verdict: nil), after: Answer(verdict: "verified"))
        h.record(a)
        h.record(s)
        h.forgetPlaces("R1-02")
        XCTAssertEqual(h.undo(), .answer(a))
    }

    /// The round 2 fixture with R1-06 on a second place of p.1, shown in a PDF view in a window.
    private func shown() throws -> (AppModel, ReviewPDFView) {
        _ = NSApplication.shared
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: StepTests.fixtures
            .appendingPathComponent("state-round2.json"))) as? [String: Any])
        var cs = try XCTUnwrap(json["comments"] as? [[String: Any]])
        let i = try XCTUnwrap(cs.firstIndex { $0["id"] as? String == "R1-06" })
        cs[i]["places"] = [place()]
        cs[i]["relation"] = "does not match"
        json["comments"] = cs
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
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        return (m, v)
    }

    func testAMarkAtEachPlaceAndTheLineBetweenTheirLabels() throws {
        let (m, v) = try shown()
        let drawn = m.pdf.debugPlaces("R1-06")
        XCTAssertEqual(drawn.map(\.key), ["a", "b"])
        // a click on the other place's label selects the comment; both are outlined, and the line joins the labels
        let b = try XCTUnwrap(drawn.last), lr = try XCTUnwrap(b.label)
        XCTAssertEqual(m.pdf.click(page: b.page, at: CGPoint(x: lr.midX, y: lr.midY)), "R1-06")
        XCTAssertEqual(m.selection, .comment("R1-06"))
        let line = try XCTUnwrap(m.pdf.linkLine)
        XCTAssertTrue(line.superview != nil)
        XCTAssertEqual(line.text, "does not match")
        XCTAssertFalse(line.path.isEmpty)
        // another comment selected: no line
        m.select(.comment("R1-05"), reveal: false, scroll: nil)
        XCTAssertNil(m.pdf.linkLine)
        _ = v
    }

    func testTheCandidatesForAnotherPlace() throws {
        let (m, _) = try shown()
        m.select(.comment("R1-06"), reveal: false, scroll: nil)
        let ids = m.addTargets().map(\.id)
        XCTAssertEqual(ids.first, "R1-06", "the shown one first")
        XCTAssertEqual(Array(ids.dropFirst().prefix(4)), ["R2-04", "R2-03", "R2-02", "R2-01"], "this round's, latest first")
        XCTAssertFalse(ids.contains("R1-01"), "answered: not offered")
        XCTAssertTrue(m.addTargets().first { $0.id == "R1-05" }?.toCheck == true)
        // a resolved card shown: it is not first, and the list goes on
        m.select(.comment("R1-01"), reveal: false, scroll: nil)
        XCTAssertEqual(m.addTargets().first?.id, "R2-04")
    }
}
