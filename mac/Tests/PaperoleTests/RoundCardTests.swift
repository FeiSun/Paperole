import AppKit
import SwiftUI
import XCTest
@testable import Paperole

/// The round card (design/stats-card; RoundStats.swift, RoundCard.swift): every number from a synthetic round's
/// state, the engine's word rule, the card's words and its image. Synthetic data only.
final class RoundCardTests: XCTestCase {
    /// A comment of round `n`'s state: `created` its round (carried when earlier), on `page` at `x`, `y`.
    private func comment(_ id: String, created: Int, round n: Int, note: String = "n", kind: String = "highlight",
                         verdict: String? = nil, said: String = "", tags: [String] = [], page: Int? = 0, x: Double = 80,
                         y: Double = 100, studentNote: String? = nil) -> [String: Any] {
        var c: [String: Any] = [
            "id": id, "kind": kind, "note": note, "source": "app", "created_round": created, "carried": created < n,
            "verdict": verdict.map { $0 as Any } ?? NSNull(), "verdict_note": said, "anchor_state": created < n ? "unchanged" : "new",
            "confidence": 1.0, "method": "diff", "page": page ?? NSNull(), "rects": page == nil ? [] : [[x, y, x + 100, y + 10]],
            "text": "words", "file": "main.tex", "line": 1, "changes": [], "history": [], "tags": tags]
        if let s = studentNote { c["student_note"] = ["text": s] }
        return c
    }

    private func state(round n: Int, created: String = "2026-10-21T09:00:00+08:00", closedAt: String? = "2026-10-24T18:30:00+08:00",
                       pages: Int = 4, columns: [Any] = [], comments: [[String: Any]], changes: Int = 0, unrequested: Int = 0,
                       tagNames: [String: String] = [:]) throws -> EngineState {
        let changeList: [[String: Any]] = (0..<changes).map { i in
            ["id": String(format: "c%02d", i + 1), "kind": "replace", "old_text": "a", "new_text": "b", "page": 0, "rects": [],
             "attached_to": i < unrequested ? [] : ["R1-01"], "unrequested": i < unrequested]
        }
        let json: [String: Any] = [
            "schema": 1, "paper": ["path": "/p", "title": "Easy Before Hard", "student": "Maya Chen"],
            "rounds": (1...n).map { ["n": $0, "closed": $0 < n || closedAt != nil] },
            "round": ["n": n, "closed": closedAt != nil, "created": created, "closed_at": closedAt.map { $0 as Any } ?? NSNull(),
                      "build": ["status": "ok", "pages": pages, "columns": columns, "warnings": [], "errors": []]],
            "comments": comments, "changes": changeList, "tag_names": tagNames]
        return try EngineState.decode(JSONSerialization.data(withJSONObject: json))
    }

    private let letter = Array(repeating: CGSize(width: 612, height: 792), count: 4)

    // MARK: Words

    /// The engine's rule (overview.WORD), case by case as the engine counts them (checked against its `_words`).
    func testWordsAreCountedAsTheEngineCountsThem() {
        let cases: [(String, Int)] = [
            ("多余，删掉。", 4), ("Fig. 3 很好", 4), ("，。！—…", 0), ("", 0), ("Say which window.", 3), ("R1-02 很好!", 3),
            ("e.g. the 2 kHz band (see §3.1)", 7), ("  \n\t ", 0), ("式 (2) 里 c_m 的单位和 τ 对不上。", 12),
            ("Why this “robust”？ 说明一下", 7), ("Ｆｕｌｌ ｗｉｄｔｈ ２０２６", 3), ("—", 0), ("a—b", 1),
            ("日本語のテキスト", 4), ("한국어 문장", 2), ("x²+y²", 1), ("①②", 1), ("\u{a0}nbsp\u{a0}here", 2),
        ]
        for (text, words) in cases { XCTAssertEqual(CardWords.count(text), words, text) }
    }

    // MARK: A later round

    /// Round 3, finished: new comments, answers, tags, marks, the student, two facts.
    private func roundThree() throws -> EngineState {
        let long = Array(repeating: "word", count: 41).joined(separator: " ")
        return try state(round: 3, columns: [NSNull(), NSNull(), [306, 396], NSNull()], comments: [
            comment("R1-01", created: 1, round: 3, verdict: "verified", said: "Good.", page: 0, y: 500),
            comment("R1-02", created: 1, round: 3, verdict: "reopened", said: "Say which window.", page: 1, y: 396,
                    studentNote: "Fixed in §2."),
            comment("R2-01", created: 2, round: 3, verdict: "wontfix", page: 1),
            comment("R2-02", created: 2, round: 3, verdict: "verified", said: "  ", page: 3),
            comment("R3-01", created: 3, round: 3, note: "多余，删掉。", tags: ["grammar"], page: 0, y: 79.2),
            comment("R3-02", created: 3, round: 3, note: "Fig. 3 很好", kind: "note", tags: ["praise"], page: 2, x: 400),
            comment("R3-03", created: 3, round: 3, note: long, kind: "box", tags: ["logic", "clarity"], page: 2, y: 300),
            comment("R3-04", created: 3, round: 3, note: "Cite it.", kind: "underline", page: 2, y: 600),
            comment("R3-05", created: 3, round: 3, note: "Lost.", page: nil),
        ], changes: 3, unrequested: 1)
    }

    func testTheNumbersOfALaterRound() throws {
        let s = RoundStats(state: try roundThree(), pageSizes: letter, catalog: TagCatalog())
        XCTAssertEqual([s.new, s.carried, s.resolved, s.followedUp, s.kept, s.leftOpen], [5, 4, 2, 1, 1, 0])
        // the notes 4 + 4 + 41 + 2 + 1, the follow-up 3, the closing remark 1 (an empty one and an unanswered card: 0)
        XCTAssertEqual(s.words, 4 + 4 + 41 + 2 + 1 + 3 + 1)
        XCTAssertEqual(s.wroteLine, "in your notes, follow-up and closing remark")
        // the tags of the new comments only, in the catalogue's order; praise apart; two tags count in both
        XCTAssertEqual(s.tags.map { "\($0.name) \($0.count)" }, ["Grammar 1", "Clarity 1", "Logic & claims 1"])
        XCTAssertEqual([s.praise, s.untagged], [1, 2])
        XCTAssertTrue(s.tagsShown)
        // the marks: the new comments and the follow-up with a page; height, column (p.3 has two, its own split), kind
        XCTAssertEqual(s.marks, [
            RoundStats.Mark(page: 0, y: 0.1, column: 0, kind: .stroke),
            RoundStats.Mark(page: 1, y: 0.5, column: 0, kind: .stroke, followUp: true),
            RoundStats.Mark(page: 2, y: 100 / 792, column: 1, kind: .dot),
            RoundStats.Mark(page: 2, y: 300 / 792, column: 0, kind: .frame),
            RoundStats.Mark(page: 2, y: 600 / 792, column: 0, kind: .stroke),
        ])
        XCTAssertEqual(s.pages, 4)
        XCTAssertEqual(s.days, 3)
        XCTAssertEqual(s.dateLine, "Oct 21 – Oct 24, 2026 · 3 days · 4 pages")
        XCTAssertEqual(s.figures, [.init(value: 5, label: "New"), .init(value: 2, label: "Resolved"),
                                   .init(value: 1, label: "Followed up"), .init(value: 1, label: "Kept as is")])
        XCTAssertEqual([s.edits, s.own, s.studentNotes], [3, 1, 1])
        XCTAssertEqual(s.studentLine(named: false).map { $0.lead + " · " + $0.rest },
                       "The student · 3 edits, 1 of their own · 1 note on your comments")
        XCTAssertEqual(s.studentLine(named: true)?.lead, "Maya Chen")
        // the first two facts that hold: R1-01 open since round 1; all answered (busiest page and longest note wait)
        XCTAssertEqual(s.facts, ["R1-01 is resolved after two rounds.", "All four earlier comments answered, the follow-up with a note."])
    }

    /// The facts in their order, each only when it holds; numbers one to nine in words.
    func testTheFactsHoldOrStayOut() throws {
        var comments = try roundThreeComments()
        // R1-01 left open: no "resolved after", nothing "all answered"; the busiest page and the longest note come next
        comments[0]["verdict"] = NSNull()
        var s = RoundStats(state: try state(round: 3, comments: comments), pageSizes: letter, catalog: TagCatalog())
        XCTAssertEqual(s.facts, ["Busiest page: p.3, with three of your comments.", "Longest note: 41 words, on R3-03."])
        // finished the day it came in, the last fact
        comments = comments.filter { ($0["created_round"] as? Int) == 3 && ($0["page"] as? Int) != 2 }
        s = RoundStats(state: try state(round: 3, created: "2026-10-24T08:00:00+08:00", comments: comments), pageSizes: letter,
                       catalog: TagCatalog())
        XCTAssertEqual(s.days, 0)
        XCTAssertEqual(s.dateLine, "Oct 24, 2026 · the same day · 4 pages")
        XCTAssertEqual(s.facts, ["Finished the day it came in."])
        XCTAssertEqual(RoundStats.spelled(9), "nine")
        XCTAssertEqual(RoundStats.spelled(10), "10")
        XCTAssertEqual(RoundStats.spelled(1146), "1,146")
        // every follow-up without its note: answered, but not "with a note"
        comments = try roundThreeComments()
        comments[1]["verdict_note"] = ""
        s = RoundStats(state: try state(round: 3, comments: comments), pageSizes: letter, catalog: TagCatalog())
        XCTAssertEqual(s.facts.last, "Both earlier comments answered.")
    }

    private func roundThreeComments() throws -> [[String: Any]] {
        let long = Array(repeating: "word", count: 41).joined(separator: " ")
        return [comment("R1-01", created: 1, round: 3, verdict: "verified", said: "Good.", page: 0, y: 500),
                comment("R1-02", created: 1, round: 3, verdict: "reopened", said: "Say which window.", page: 1),
                comment("R3-01", created: 3, round: 3, note: "多余，删掉。", tags: ["grammar"], page: 0),
                comment("R3-02", created: 3, round: 3, note: "x", page: 2),
                comment("R3-03", created: 3, round: 3, note: long, page: 2),
                comment("R3-04", created: 3, round: 3, note: "Cite it.", page: 2)]
    }

    // MARK: Round 1 and the tag table

    /// Round 1: New, Pages with a mark and Done well; ten tags fold to six rows and a line, ties folding the later tag;
    /// the compact card's line names how many.
    func testRoundOneAndTheFold() throws {
        let ids = ["grammar", "wording", "clarity", "logic", "evidence", "structure", "figures", "math", "format", "u-1a2b3c4d"]
        let counts = [3, 2, 3, 1, 2, 1, 2, 1, 2, 1]
        var comments: [[String: Any]] = []
        var k = 0
        for (id, c) in zip(ids, counts) {
            for _ in 0..<c {
                k += 1
                comments.append(comment(String(format: "R1-%02d", k), created: 1, round: 1, tags: [id], page: k % 3))
            }
        }
        comments.append(comment("R1-99", created: 1, round: 1, tags: ["praise"], page: 0))
        comments.append(comment("R1-98", created: 1, round: 1, page: 0))
        let s = RoundStats(state: try state(round: 1, created: "2026-10-14T10:00:00+08:00",
                                            closedAt: "2026-10-15T10:00:00+08:00", pages: 5, comments: comments),
                           pageSizes: letter, catalog: TagCatalog())
        XCTAssertEqual(s.figures, [.init(value: 20, label: "New"), .init(value: 3, of: 5, label: "Pages with a mark"),
                                   .init(value: 1, label: "Done well")])
        XCTAssertNil(s.studentLine(named: false), "round 1 has no student line")
        XCTAssertEqual(s.tags.last?.name, "u-1a2b3c4d", "a tag the catalogue lacks keeps its place, last")
        let full = s.tagTable(maxRows: 7)
        // the six largest stay in order (ties: the earlier tag), the rest fold in the catalogue's order
        XCTAssertEqual(full.rows.map(\.id), ["grammar", "wording", "clarity", "evidence", "figures", "format"])
        XCTAssertEqual(full.folded.map(\.id), ["logic", "structure", "math", "u-1a2b3c4d"])
        XCTAssertEqual(s.alsoLine(full.folded, names: true),
                       "Also Logic & claims 1 · Structure 1 · Math & notation 1 · u-1a2b3c4d 1 · 1 not tagged")
        let compact = s.tagTable(maxRows: 6)
        XCTAssertEqual(compact.rows.count, 5)
        XCTAssertEqual(s.alsoLine(compact.folded, names: false), "Also 5 more tags · 1 not tagged")
        XCTAssertEqual(s.tagTable(maxRows: 10).folded, [], "ten tags fit ten rows")
        XCTAssertEqual(s.facts, ["Busiest page: p.1, with eight of your comments."])
    }

    /// A round with no new comment: the grid drops New and shows Left open; no tag section; follow-ups are marks.
    func testARoundWithoutNewComments() throws {
        let s = RoundStats(state: try state(round: 4, comments: [
            comment("R1-10", created: 1, round: 4, verdict: "verified", said: "Thanks, this reads well now."),
            comment("R2-03", created: 2, round: 4, verdict: "reopened", said: "Still unclear.", page: 3, x: 400),
            comment("R2-04", created: 2, round: 4),
        ]), pageSizes: letter, catalog: TagCatalog())
        XCTAssertEqual(s.figures.map(\.label), ["Resolved", "Followed up", "Kept as is", "Left open"])
        XCTAssertFalse(s.tagsShown)
        XCTAssertEqual(s.marks, [RoundStats.Mark(page: 3, y: 100 / 792, column: 1, kind: .stroke, followUp: true)])
        XCTAssertEqual(s.wroteLine, "in your follow-up and closing remark")
        XCTAssertEqual(s.facts, ["R1-10 is resolved after three rounds."])
        let nothing = RoundStats(state: try state(round: 4, comments: []), pageSizes: letter, catalog: TagCatalog())
        XCTAssertNil(nothing.wroteLine)
        XCTAssertEqual(nothing.figures.map(\.value), [0, 0, 0])
        XCTAssertEqual(nothing.words, 0)
    }

    /// Round 1 with no comment, and one whose only comments have no words and no page: zeros, never a fact, a tag
    /// section or a line of what was written; the pages VoiceOver reads say how many have a mark.
    func testAnEmptyRoundOne() throws {
        let empty = RoundStats(state: try state(round: 1, comments: []), pageSizes: letter, catalog: TagCatalog())
        XCTAssertEqual(empty.figures, [.init(value: 0, label: "New"), .init(value: 0, of: 4, label: "Pages with a mark")])
        XCTAssertEqual([empty.words, empty.praise, empty.untagged], [0, 0, 0])
        XCTAssertNil(empty.wroteLine)
        XCTAssertFalse(empty.tagsShown)
        XCTAssertEqual(empty.facts, [])
        XCTAssertNil(empty.studentLine(named: true))
        XCTAssertEqual(PageStrip.spoken(empty), "A mark on 0 of 4 pages")
        let bare = RoundStats(state: try state(round: 1, comments: [
            comment("R1-01", created: 1, round: 1, note: "，。", page: 1),
            comment("R1-02", created: 1, round: 1, note: "", tags: ["praise"], page: nil),
        ]), pageSizes: letter, catalog: TagCatalog())
        XCTAssertEqual(bare.words, 0, "punctuation alone is no word")
        XCTAssertNil(bare.wroteLine)
        XCTAssertEqual(bare.figures.map(\.value), [2, 1, 1], "New, Pages with a mark, Done well")
        XCTAssertFalse(bare.tagsShown, "praise alone is no tag section")
        XCTAssertEqual(PageStrip.spoken(bare), "A mark on 1 of 4 pages")
    }

    /// An open round counts its days to today, as the overview does: each time on the date it was written.
    func testAnOpenRoundCountsToToday() throws {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        let today = try XCTUnwrap(c.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 12)))
        let s = RoundStats(state: try state(round: 2, created: "2026-10-21T23:30:00-07:00", closedAt: nil, comments: []),
                           pageSizes: [], catalog: TagCatalog(), today: today)
        XCTAssertFalse(s.closed)
        XCTAssertEqual(s.days, 3)
        XCTAssertEqual(s.soFarLine, "Oct 21 – today · 3 days")
        let fresh = RoundStats(state: try state(round: 2, created: "2026-10-24T08:00:00+08:00", closedAt: nil, comments: []),
                               catalog: TagCatalog(), today: today)
        XCTAssertEqual(fresh.soFarLine, "Oct 24 · today")
        XCTAssertEqual(CardDay(iso: "2026-12-28T10:00:00+08:00")?.days(to: CardDay(year: 2027, month: 1, day: 3)), 6)
        let across = RoundStats(state: try state(round: 2, created: "2026-12-28T10:00:00+08:00",
                                                 closedAt: "2027-01-03T10:00:00+08:00", pages: 1, comments: []),
                                pageSizes: [], catalog: TagCatalog())
        XCTAssertEqual(across.dateLine, "Dec 28, 2026 – Jan 3, 2027 · 6 days · 1 page")
    }

    /// The tags' names: the catalogue's, else the ledger's for a tag it lacks.
    func testTagNamesFallBackToTheLedgers() throws {
        let s = RoundStats(state: try state(round: 1, comments: [comment("R1-01", created: 1, round: 1, tags: ["u-00ff00ff"])],
                                            tagNames: ["u-00ff00ff": "Hedging"]),
                           pageSizes: letter, catalog: TagCatalog())
        XCTAssertEqual(s.tags.map(\.name), ["Hedging"])
    }

    // MARK: The look

    /// The ring is the logo's polygon, filling its box; the card's colours keep their contrast on the paper.
    func testTheRingAndTheColours() {
        let b = RoundRing().path(in: CGRect(x: 0, y: 0, width: 612, height: 572)).boundingRect
        XCTAssertEqual(b.minX, 221.4 - 216, accuracy: 0.01)
        XCTAssertEqual(b.width, 791.9 - 221.4, accuracy: 0.01)
        XCTAssertEqual(b.height, 750.9 - 236.1, accuracy: 0.01)
        func srgb(_ c: NSColor, _ dark: Bool) -> NSColor {
            var out = c
            NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance { out = c.usingColorSpace(.sRGB)! }
            return out
        }
        func lum(_ c: NSColor) -> CGFloat {
            func ch(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * ch(c.redComponent) + 0.7152 * ch(c.greenComponent) + 0.0722 * ch(c.blueComponent)
        }
        func contrast(_ a: NSColor, _ dark: Bool) -> CGFloat {
            let (x, y) = (lum(srgb(a, dark)), lum(srgb(CardPalette.paper, dark)))
            return (max(x, y) + 0.05) / (min(x, y) + 0.05)
        }
        // the spec's 4.5:1 and 4.9:1, 5.1:1 and 6.8:1, as rounded to one place
        XCTAssertGreaterThanOrEqual(contrast(CardPalette.vermilion, false), 4.5)
        XCTAssertGreaterThanOrEqual(contrast(CardPalette.vermilion, true), 4.85)
        XCTAssertGreaterThanOrEqual(contrast(Palette.secondary, false), 5.05)
        XCTAssertGreaterThanOrEqual(contrast(Palette.secondary, true), 6.75)
    }

    /// The exported image: the card at 2×, 1080 px wide, in either appearance; the file's name leaves the title out
    /// unless it is on the card.
    @MainActor
    func testTheImageIsTwiceTheCard() throws {
        _ = NSApplication.shared
        let s = RoundStats(state: try roundThree(), pageSizes: letter, catalog: TagCatalog())
        let card = RoundCardView.size(s, showTitle: true, showStudent: true)
        for dark in [false, true] {
            let png = try XCTUnwrap(RoundCardImage.png(s, showTitle: true, showStudent: true, dark: dark))
            let rep = try XCTUnwrap(NSBitmapImageRep(data: png))
            XCTAssertEqual([rep.pixelsWide, rep.pixelsHigh], [1080, Int(card.height * 2)])
            XCTAssertEqual(rep.size, card, "144 dpi: the image's points are the card's")
        }
        XCTAssertEqual(RoundCardImage.fileName(s, showTitle: false), "Round 3.png")
        XCTAssertEqual(RoundCardImage.fileName(s, showTitle: true), "Easy Before Hard – Round 3.png")
    }

    // MARK: The card's height

    /// The card is as tall as what it holds, from a square to 4:5, and its image is that card at 2× in either
    /// appearance: a sparse round's a square (round 1 with three comments; one new comment and no tag), a rich one's
    /// 4:5 (a fact gives way), one in between as tall as its content; the title and the name, ticked, a line taller.
    @MainActor
    func testTheCardIsAsTallAsWhatItHolds() throws {
        _ = NSApplication.shared
        var heights: [String: CGFloat] = [:]
        for (name, s) in try shapes() {
            let card = RoundCardView.size(s)
            XCTAssertEqual(card.width, 540, name)
            XCTAssertTrue(RoundCardView.heights.contains(card.height), name)
            XCTAssertEqual(card.height, card.height.rounded(), "\(name): whole points, so whole pixels")
            heights[name] = card.height
            for dark in [false, true] {
                let rep = try XCTUnwrap(RoundCardImage.png(s, showTitle: false, showStudent: false, dark: dark)
                    .flatMap(NSBitmapImageRep.init(data:)))
                XCTAssertEqual([rep.pixelsWide, rep.pixelsHigh], [1080, Int(card.height * 2)], name)
            }
        }
        XCTAssertEqual(heights["round 1"], 540)
        XCTAssertEqual(heights["one new"], 540)
        XCTAssertEqual(heights["rich"], 675)
        let answers = try XCTUnwrap(heights["answers"])
        XCTAssertGreaterThan(answers, 540, "only answers: two facts, the student, two rows of pages")
        XCTAssertLessThan(answers, 675)
        let s = try XCTUnwrap(shapes().first { $0.name == "answers" }?.stats)
        XCTAssertGreaterThan(RoundCardView.size(s, showTitle: true, showStudent: true).height, answers)
        let rich = try XCTUnwrap(shapes().first { $0.name == "rich" }?.stats)
        XCTAssertEqual([rich.tags.count, rich.facts.count], [6, 2], "six tag rows, two rows of pages and both facts: still 4:5")
    }

    /// A card taller than what it holds gives the room to its pages first: as tall as the room, at most `roomyPage`
    /// or the row's width, never smaller than usual; the compact card's pages never grow.
    func testThePagesGrowIntoTheRoom() throws {
        func strip(pages: Int, roomy: CGFloat?) throws -> PageStrip {
            let s = RoundStats(state: try state(round: 1, pages: pages, comments: []), pageSizes: letter, catalog: TagCatalog())
            return PageStrip(stats: s, width: 460, perRow: 8, gap: 10, lines: true, maxPage: 54, roomyPage: roomy,
                             t: CardTheme(dark: false))
        }
        let four = try strip(pages: 4, roomy: 96)
        XCTAssertEqual(four.layout().page.width, 54)
        XCTAssertEqual(four.layout(room: 100).page.height, 100, accuracy: 0.001, "as tall as the room")
        XCTAssertEqual(four.layout(room: 1000).page.width, 96, "at most roomyPage")
        XCTAssertEqual(four.layout(room: 10).page.width, 54, "never smaller")
        XCTAssertEqual(four.height(roomy: true), 96 * 792 / 612, accuracy: 0.001)
        let twelve = try strip(pages: 12, roomy: 96)
        XCTAssertEqual(twelve.layout(room: 1000).page.width, (460 - 7 * 10) / 8, "the row's width")
        XCTAssertEqual(twelve.layout(room: 1000).rows, 2, "the rows stay")
        XCTAssertEqual(try strip(pages: 4, roomy: nil).layout(room: 1000).page.width, 54)
    }

    /// The rounds the card's height is checked on (request of 2026-10-26: a sparse round left the lower half of a
    /// fixed 4:5 card empty): round 1 with three comments; a round with one new comment and no tag; a rich round (24
    /// new comments, six tags, 28 pages); a round with no new comment, only answers.
    func shapes() throws -> [(name: String, stats: RoundStats)] {
        let one = try state(round: 1, closedAt: "2026-10-22T18:00:00+08:00", pages: 6, comments: [
            comment("R1-01", created: 1, round: 1, note: "Say which window you mean.", tags: ["clarity"], page: 0, y: 200),
            comment("R1-02", created: 1, round: 1, note: "Tense: the results show.", kind: "note", tags: ["grammar"], page: 2, x: 400),
            comment("R1-03", created: 1, round: 1, note: "Cite the source of this table.", kind: "box", page: 4, y: 300),
        ])
        let single = try state(round: 2, pages: 8, comments: [
            comment("R1-01", created: 1, round: 2, verdict: "verified", said: "Good.", page: 0),
            comment("R1-02", created: 1, round: 2, verdict: "verified", page: 2),
            comment("R1-03", created: 1, round: 2, verdict: "verified", page: 3),
            comment("R1-04", created: 1, round: 2, verdict: "reopened", said: "Still unclear: which baseline?", page: 5,
                    y: 500, studentNote: "Added the baseline in §4."),
            comment("R2-01", created: 2, round: 2, note: "Cite the source of Table 2.", page: 5, y: 300),
        ], changes: 5, unrequested: 2)
        let tags = ["grammar", "grammar", "grammar", "grammar", "grammar", "grammar", "clarity", "clarity", "clarity",
                    "clarity", "clarity", "logic", "logic", "logic", "logic", "evidence", "evidence", "evidence", "figures",
                    "figures", "figures", "math", "math"]
        var many = tags.enumerated().map { k, tag in
            comment(String(format: "R2-%02d", k + 1), created: 2, round: 2, note: "Rephrase this sentence, it reads twice.",
                    kind: ["highlight", "underline", "note", "box"][k % 4], tags: k % 9 == 4 ? [tag, "praise"] : [tag],
                    page: k < 4 ? 3 : (k * 5) % 28, x: k % 2 == 0 ? 80 : 400, y: Double(90 + (k * 97) % 600))
        }
        many.append(comment("R2-24", created: 2, round: 2, note: Array(repeating: "word", count: 52).joined(separator: " "),
                            page: 11, y: 420))
        many += (1...10).map { k in
            comment(String(format: "R1-%02d", k), created: 1, round: 2, verdict: k <= 7 ? "verified" : k <= 9 ? "reopened" : "wontfix",
                    said: k > 7 && k <= 9 ? "Still there." : "", page: k * 2, studentNote: k <= 5 ? "Done." : nil)
        }
        let rich = try state(round: 2, pages: 28, comments: many, changes: 31, unrequested: 6)
        let answers = try state(round: 3, pages: 12, comments: [
            comment("R1-02", created: 1, round: 3, verdict: "verified", said: "Thanks, this reads well now.", page: 1),
            comment("R2-01", created: 2, round: 3, verdict: "verified", page: 4),
            comment("R2-02", created: 2, round: 3, verdict: "verified", page: 6),
            comment("R2-03", created: 2, round: 3, verdict: "reopened", said: "Say why the second run differs.", page: 7, y: 380,
                    studentNote: "Explained in §5.2."),
            comment("R2-04", created: 2, round: 3, verdict: "wontfix", page: 9),
        ], changes: 9, unrequested: 2)
        return [("round 1", one), ("one new", single), ("rich", rich), ("answers", answers)].map {
            ($0.0, RoundStats(state: $0.1, pageSizes: letter, catalog: TagCatalog()))
        }
    }
}

/// Finish Round without the email (request of 2026-10-26): the sheet turns into the round's card, its Done says where
/// final.pdf is, and the card is there again for the finished round. Synthetic papers in a temporary folder only.
@MainActor
final class RoundCardFlowTests: XCTestCase {
    private var tmp: URL!
    private var fm: FileManager { .default }

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("pc-roundcard-" + UUID().uuidString)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: tmp)
    }

    private func model(fixture: String? = nil) -> AppModel {
        _ = NSApplication.shared
        var o = LaunchOptions()
        if let fixture { o.fixture = StepTests.fixtures.appendingPathComponent(fixture).path } else { o.noList = true }
        o.drafts = tmp.appendingPathComponent("drafts").path
        o.cache = tmp.appendingPathComponent("cache").path
        o.tags = tmp.appendingPathComponent("tags/tags.json").path
        return AppModel(options: o)
    }

    /// The window's line after Done has two buttons, each running its own action.
    func testTheNoticeHasTwoButtons() throws {
        let m = model(fixture: "state-m2a.json")
        let st = try XCTUnwrap(m.state)
        m.openFinish()
        XCTAssertTrue(m.showFinish)
        XCTAssertNil(m.finishPreview.done, "the sheet opens on the hand-off and the card so far")
        XCTAssertFalse(RoundStats(state: st, catalog: TagCatalog()).closed)
        var clicked: [String] = []
        m.showNotice(WindowNotice(text: "Round 2 is finished · final.pdf is ready", action: "Show in Finder", second: "Open"),
                     second: { clicked.append("open") }, action: { clicked.append("finder") })
        m.noticeClicked(second: true)
        XCTAssertEqual(clicked, ["open"])
        XCTAssertNil(m.notice)
        m.noticeClicked()
        XCTAssertEqual(clicked, ["open"], "the line is gone, and its actions with it")
        // a trailing closure is still the first button's (Remove from List's Undo)
        m.showNotice(WindowNotice(text: "Removed", action: "Undo")) { clicked.append("undo") }
        m.noticeClicked()
        XCTAssertEqual(clicked, ["open", "undo"])
        // Done on the card closes the sheet and says where final.pdf is
        m.finishPreview.done = RoundCardAsk(stats: m.roundStats(st), justFinished: true, finalPdf: tmp.appendingPathComponent("final.pdf").path)
        m.closeFinishSummary()
        XCTAssertFalse(m.showFinish)
        XCTAssertNil(m.finishPreview.done)
        XCTAssertEqual(m.notice?.text, "Round 2 is finished · final.pdf is ready")
        XCTAssertEqual([m.notice?.action, m.notice?.second], ["Show in Finder", "Open"])
        // the round is open: no summary of it; another round cannot be read without the engine
        m.openRoundSummary()
        XCTAssertNil(m.roundCard)
        m.openRoundSummary(1)
        XCTAssertNil(m.roundCard)
        XCTAssertEqual(m.reading.toast, "Fixture mode: the engine is not running, so Round 1 cannot be read.")
    }

    private func rpc(_ m: AppModel, _ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let data = try await m.engine.call(method, params: JSONSerialization.data(withJSONObject: params))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func waitUntil(_ done: () -> Bool) async throws {
        for _ in 0..<400 where !done() { try await Task.sleep(nanoseconds: 50_000_000) }
    }

    /// A synthetic paper's round 1 finished from the sheet: final.pdf is written (email.txt still, for backups), nothing
    /// is copied, the sheet shows the round's card; Done closes it; Round 1 Summary… shows the same card later.
    func testFinishShowsTheCard() async throws {
        guard fm.isExecutableFile(atPath: EngineClient.defaultPython), fm.fileExists(atPath: "/Library/TeX/texbin/latexmk") else {
            throw XCTSkip("needs the engine's Python and latexmk")
        }
        let m = model()
        let folder = tmp.appendingPathComponent("kelp-review"), src = tmp.appendingPathComponent("src")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try Data("\\documentclass{article}\n\\begin{document}\n\\section{Intro}\nKelp drifts in the bay.\n\\end{document}\n".utf8)
            .write(to: src.appendingPathComponent("main.tex"))
        _ = try await rpc(m, "new", ["paper": folder.path, "title": "Kelp drift", "student": "Mei Lin"])
        _ = try await rpc(m, "ingest", ["paper": folder.path, "source": src.path])
        _ = try await rpc(m, "comment", ["paper": folder.path, "page": 0, "rects": [[133.7, 148.8, 230.2, 158.8]],
                                         "text": "Kelp drifts in the bay.", "note": "Which bay? 哪个海湾", "kind": "highlight",
                                         "tags": ["clarity"]])
        let path = folder.standardizedFileURL.path
        m.papers = [PaperRef(path: path, title: "Kelp drift", student: "Mei Lin", factsMoved: true)]
        m.openPaper(path, level: .review)
        try await waitUntil { m.state?.round?.n == 1 && !m.busy }
        m.openFinish()
        XCTAssertTrue(m.showFinish)
        m.finishRound()
        try await waitUntil { m.finishPreview.done != nil && !m.busy }
        XCTAssertNil(m.finishPreview.error)
        let done = try XCTUnwrap(m.finishPreview.done)
        XCTAssertTrue(m.showFinish, "the same sheet, now the card")
        XCTAssertTrue(done.justFinished)
        XCTAssertEqual(done.finalPdf, folder.appendingPathComponent("r1/final.pdf").standardizedFileURL.path)
        XCTAssertTrue(fm.fileExists(atPath: folder.appendingPathComponent("r1/final.pdf").path))
        XCTAssertTrue(fm.fileExists(atPath: folder.appendingPathComponent("r1/email.txt").path), "the engine still writes it")
        let s = done.stats
        XCTAssertEqual([s.round, s.new, s.words, s.pages, s.days ?? -1], [1, 1, 6, 1, 0])
        XCTAssertTrue(s.closed)
        XCTAssertEqual(s.tags.map(\.id), ["clarity"])
        XCTAssertEqual(s.marks.count, 1)
        // its height on the page: the top of its first rect over the page's height, the PDF's own (A4 here)
        let page = try XCTUnwrap(RoundStats.pageSizes(m.state?.round?.build.pdf).first)
        XCTAssertEqual(page.height, 841.9, accuracy: 0.1)
        let top = try XCTUnwrap(m.state?.comments.first?.rects.first?[1])
        XCTAssertEqual(s.marks.first?.y ?? 0, top / page.height, accuracy: 0.0001)
        XCTAssertEqual(s.figures.map(\.label), ["New", "Pages with a mark"])
        XCTAssertEqual(s.facts, ["Finished the day it came in."])
        m.closeFinishSummary()
        XCTAssertFalse(m.showFinish)
        XCTAssertEqual(m.notice?.text, "Round 1 is finished · final.pdf is ready")
        try await waitUntil { m.state?.round?.closed == true && !m.busy }
        m.openRoundSummary(1)
        let later = try XCTUnwrap(m.roundCard)
        XCTAssertFalse(later.justFinished)
        XCTAssertEqual(later.stats, s)
    }
}
