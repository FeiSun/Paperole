import XCTest
@testable import Paperole

/// Reading in the PDF view (UX.md §18 Tests): the outline, N's order, Shift-C's sections, the paragraph under a point,
/// the bars' place in the margin, the keys, and the state's reading data.
final class ReadingTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Fixtures")

    func fixture() throws -> EngineState {
        try EngineState.decode(Data(contentsOf: Self.fixtures.appendingPathComponent("state-reading.json")))
    }

    /// A small paper: title (0) and abstract (1), §1 Intro (2) with ¶3, a \paragraph heading (4, not listed) and ¶5,
    /// §1.1 Sub (6) with ¶7, §2 Method (8) with ¶9, References (10) with two entries (11, 12).
    func small() -> ReadingInfo {
        func p(_ b: Int, _ s: Int, _ page: Int = 0, _ y: Double = 0) -> Paragraph {
            Paragraph(block: b, section: s, parts: [PageRect(page: page, rect: [108, y, 504, y + 40])])
        }
        let ps = [p(1, -1, 0, 100), p(3, 2, 0, 200), p(5, 2, 0, 300), p(7, 6, 1, 100), p(9, 8, 1, 300), p(11, 10, 2, 100),
                  p(12, 10, 2, 150)]
        let hs = [Heading(block: 2, level: 1, title: "1 Intro", parts: [PageRect(page: 0, rect: [108, 180, 504, 190])]),
                  Heading(block: 6, level: 2, title: "1.1 Sub", parts: [PageRect(page: 1, rect: [108, 80, 504, 90])]),
                  Heading(block: 8, level: 1, title: "2 Method", parts: []),
                  Heading(block: 10, level: 1, title: "References", parts: [])]
        return ReadingInfo(read: [1, 3, 9], count: ps.count, unread: 4, paragraphs: ps, headings: hs)
    }

    // MARK: Outline

    func testOutlineRows() {
        let r = small()
        let rows = Outline.rows(r, read: [1, 3, 9], comments: [3, 7, 7], round: 2)
        XCTAssertEqual(rows.map(\.title), ["Title and abstract", "1 Intro", "1.1 Sub", "2 Method", "References"])
        XCTAssertEqual(rows.map(\.level), [1, 1, 2, 1, 1])
        XCTAssertEqual(rows.map(\.count), [1, 3, 1, 1, 2])  // §1 counts its subsection
        XCTAssertEqual(rows.map(\.read), [1, 1, 0, 1, 0])
        XCTAssertEqual(rows.map(\.open), [0, 3, 2, 0, 0])
        XCTAssertEqual(rows.map(\.changed), [false, true, true, false, true])  // it has bars
        XCTAssertEqual(rows.map(\.done), [true, false, false, true, false])
        XCTAssertTrue(rows.allSatisfy(\.tracked))
        // the to-do, not a completion rate: most paragraphs count as read because finishing a round marks them read
        XCTAssertEqual(Outline.footer(r, read: [1, 3, 9], round: 2, closed: false), "4 changed paragraphs to read")
        XCTAssertEqual(Outline.footer(r, read: [1, 3, 5, 7, 9, 12], round: 2, closed: false), "1 changed paragraph to read")
        XCTAssertEqual(Outline.footer(r, read: [1, 3, 5, 7, 9, 11, 12], round: 3, closed: false), "All changed paragraphs are read")
        // a closed round says what was left, which nothing can change now
        XCTAssertEqual(Outline.footer(r, read: [1, 3, 9], round: 2, closed: true),
                       "4 changed paragraphs left unread when Round 2 closed")
        XCTAssertEqual(Outline.footer(r, read: [1, 3, 5, 7, 9, 11, 12], round: 2, closed: true),
                       "All changed paragraphs were read in Round 2")
        XCTAssertEqual(Outline.current(rows, block: 7), 6)  // the deepest row that holds it
        XCTAssertEqual(Outline.current(rows, block: 4), 2)
        XCTAssertNil(Outline.current(rows, block: nil))
        // round 1: no progress and no bars, only the comments
        let one = Outline.rows(r, read: [], comments: [3], round: 1)
        XCTAssertTrue(one.allSatisfy { !$0.tracked && !$0.changed })
        XCTAssertEqual(Outline.footer(r, read: [], round: 1, closed: false), "Round 1: finishing it marks every paragraph read")
        XCTAssertEqual(Outline.footer(r, read: [], round: 1, closed: true), "Finishing Round 1 marked every paragraph read")
    }

    func testOutlineOfTheFixturePaper() throws {
        let st = try fixture()
        let r = try XCTUnwrap(st.reading)
        let rows = Outline.rows(r, read: Set(r.read), round: 2)
        XCTAssertEqual(rows.map(\.title), ["Title and abstract", "1 Introduction", "2 Related Work", "3 Method",
                                           "4 Evaluation", "5 Conclusion", "References"])
        XCTAssertEqual(rows.reduce(0) { $0 + ($1.level == 1 ? $1.count : 0) }, r.count)
        XCTAssertEqual(rows.reduce(0) { $0 + ($1.level == 1 ? $1.count - $1.read : 0) }, r.unread)
        XCTAssertEqual(rows.filter(\.changed).map(\.title), ["1 Introduction", "2 Related Work", "3 Method", "4 Evaluation",
                                                            "5 Conclusion"])
    }

    // MARK: N and Shift-C

    func testNextUnreadInReadingOrder() {
        let ps = small().paragraphs, read: Set<Int> = [1, 3, 9]
        XCTAssertEqual(Reading.next(after: 3, from: nil, in: ps, read: read), 5)
        XCTAssertEqual(Reading.next(after: 12, from: nil, in: ps, read: read), 5)  // wraps
        XCTAssertEqual(Reading.next(after: nil, from: 6, in: ps, read: read), 7)  // the first in view on
        XCTAssertEqual(Reading.next(after: nil, from: 7, in: ps, read: read), 7)  // in view and unread: that one
        XCTAssertEqual(Reading.next(after: 7, from: 1, in: ps, read: read), 11)  // after the current one, not from the top
        XCTAssertEqual(Reading.next(after: nil, from: nil, in: ps, read: read), 5)
        XCTAssertNil(Reading.next(after: 3, from: nil, in: ps, read: [1, 3, 5, 7, 9, 11, 12]))
        XCTAssertNil(Reading.next(after: nil, from: nil, in: [], read: []))
    }

    func testNextFollowsThePrintedOrder() {
        // a float (block 4) set at the foot of the page, below the paragraphs that follow it in the source
        let ps = [1, 3, 5, 4, 7].map { Paragraph(block: $0, section: -1, parts: []) }, read: Set<Int> = [1, 3]
        XCTAssertEqual(Reading.next(after: 5, from: nil, in: ps, read: read), 4)
        XCTAssertEqual(Reading.next(after: 4, from: nil, in: ps, read: read), 7)
        XCTAssertEqual(Reading.next(after: 7, from: nil, in: ps, read: read), 5)  // wraps
        XCTAssertEqual(Reading.next(after: nil, from: 4, in: ps, read: read), 4)
        XCTAssertEqual(Reading.next(after: nil, from: 2, in: ps, read: read), 5)  // from a heading: the paragraph after it
        XCTAssertEqual(Reading.next(after: nil, from: 6, in: ps, read: read), 7)
        XCTAssertEqual(Reading.next(after: 5, from: nil, in: ps, read: [1, 3, 4]), 7)
    }

    func testSectionRanges() {
        let hs = small().headings
        XCTAssertEqual(Reading.section(2, headings: hs), 2..<8)  // §1 with §1.1
        XCTAssertEqual(Reading.section(6, headings: hs), 6..<8)  // §1.1 only
        XCTAssertEqual(Reading.section(-1, headings: hs), 0..<2)  // the title and abstract
        XCTAssertEqual(Reading.section(10, headings: hs), 10..<Int.max)
        XCTAssertEqual(Reading.section(-1, headings: []), 0..<Int.max)
    }

    func testTrackedFromRound2() {
        XCTAssertFalse(Reading.tracked(round: 1))
        XCTAssertFalse(Reading.tracked(round: nil))
        XCTAssertTrue(Reading.tracked(round: 2))
    }

    // MARK: Points in the PDF

    func testParagraphAtAPoint() {
        let ps = small().paragraphs
        XCTAssertEqual(Reading.paragraph(at: 0, x: 300, y: 220, in: ps), 3)
        XCTAssertEqual(Reading.paragraph(at: 0, x: 300, y: 241, in: ps), 3)  // 2 pt of slack
        XCTAssertNil(Reading.paragraph(at: 0, x: 300, y: 250, in: ps))  // between paragraphs
        XCTAssertNil(Reading.paragraph(at: 0, x: 50, y: 220, in: ps))  // in the margin
        XCTAssertEqual(Reading.paragraph(at: 2, x: 300, y: 120, in: ps), 11)
        // overlapping parts (a float beside a paragraph): the smaller one
        let float = Paragraph(block: 20, section: 2, parts: [PageRect(page: 0, rect: [300, 210, 500, 230])])
        XCTAssertEqual(Reading.paragraph(at: 0, x: 400, y: 220, in: ps + [float]), 20)
        // a paragraph across a page break is found on either page
        let split = Paragraph(block: 30, section: 2, parts: [PageRect(page: 3, rect: [108, 700, 504, 730]),
                                                            PageRect(page: 4, rect: [108, 80, 504, 100])])
        XCTAssertEqual(Reading.paragraph(at: 4, x: 200, y: 90, in: [split]), 30)
    }

    func testBlockAtAPointForTheOutline() throws {
        let r = small()
        XCTAssertEqual(Reading.block(page: 0, x: 300, y: 185, paragraphs: r.paragraphs, headings: r.headings), 2)
        XCTAssertEqual(Reading.block(page: 0, x: 300, y: 250, paragraphs: r.paragraphs, headings: r.headings), 5)  // the next below
        XCTAssertEqual(Reading.block(page: 1, x: 300, y: 700, paragraphs: r.paragraphs, headings: r.headings), 9)  // the last above
        XCTAssertEqual(Reading.block(page: 9, x: 0, y: 0, paragraphs: r.paragraphs, headings: r.headings), 12)  // an earlier page
        let st = try fixture(), f = try XCTUnwrap(st.reading)
        let first = try XCTUnwrap(f.paragraphs.first { $0.block == 4 }?.parts.first)
        let y = (first.rect[1] + first.rect[3]) / 2
        XCTAssertEqual(Reading.block(page: first.page, x: 300, y: y, paragraphs: f.paragraphs, headings: f.headings), 4)
    }

    /// The bar sits 3 pt outside the text column (text_x), 2 pt wide: left of one column and of the left column,
    /// right of the right column; clear of the text and of a margin ruler.
    func testBarsAreInTheMargin() {
        // ICLR, one column, ruler at x 73–86
        let iclr = Reading.bar(PageRect(page: 3, rect: [108, 486.99, 504, 594.53]), textX: [107.25, 505.75], gap: nil)
        XCTAssertEqual(iclr, [102.25, 486.99, 104.25, 594.53])
        XCTAssertTrue(iclr[0] > 86.4 && iclr[2] < 107.25)
        // ACL, two columns (gap 298.34), rulers at x 12–26 and 566–580
        let left = Reading.bar(PageRect(page: 1, rect: [70.87, 74.43, 289.13, 246.78]), textX: [70.47, 526.22], gap: 298.34)
        XCTAssertEqual(left[0], 65.47, accuracy: 1e-9)
        XCTAssertEqual(left[2], 67.47, accuracy: 1e-9)
        XCTAssertEqual([left[1], left[3]], [74.43, 246.78])
        let right = Reading.bar(PageRect(page: 1, rect: [306.14, 74.43, 524.41, 111.29]), textX: [70.47, 526.22], gap: 298.34)
        XCTAssertEqual(right[0], 529.22, accuracy: 1e-9)
        XCTAssertEqual(right[2], 531.22, accuracy: 1e-9)
        XCTAssertTrue(left[0] > 25.5 && right[2] < 566.4)
        // a figure across both columns: the left margin; no text_x: beside the part itself
        XCTAssertEqual(Reading.bar(PageRect(page: 2, rect: [70.87, 70.87, 524.42, 294.29]), textX: [70.47, 526.22], gap: 298.34)[0],
                       65.47, accuracy: 1e-9)
        XCTAssertEqual(Reading.bar(PageRect(page: 0, rect: [100, 10, 200, 20]), textX: nil, gap: nil), [95, 10, 97, 20])
        // ICLR, one column: a wraptable on the right gets the right margin, the paragraph wrapped round it the left
        XCTAssertEqual(Reading.bar(PageRect(page: 15, rect: [320.4, 140.8, 504, 211.5]), textX: [107.25, 505.75], gap: nil),
                       [508.75, 140.8, 510.75, 211.5])
        XCTAssertEqual(Reading.bar(PageRect(page: 15, rect: [108, 128.4, 504, 257.8]), textX: [107.25, 505.75], gap: nil)[0],
                       102.25)
    }

    /// A float wrapped in a paragraph's text gets a bar of its own: on its own side when it is flush with the text's
    /// right edge, else 4 pt further out than the paragraph's, 2 pt clear of it; the paragraph's bar stays put, and
    /// nothing moves for parts that only touch or are about as wide (an item below a paragraph).
    func testBarsBesideAWrappedFloat() {
        let tx = [107.25, 505.75]
        let para = PageRect(page: 15, rect: [108, 128.4, 504, 257.8])
        func bar(_ r: [Double], _ others: [PageRect] = [para], gap: Double? = nil, textX: [Double]? = tx) -> [Double] {
            Reading.bar(PageRect(page: 15, rect: r), textX: textX, gap: gap, beside: others + [PageRect(page: 15, rect: r)])
        }
        // ICLR's wraptable (its box runs past the text's right edge): the right margin; its paragraph the left
        XCTAssertEqual(bar([346, 141, 540, 212]), [508.75, 141, 510.75, 212])
        XCTAssertEqual(Reading.bar(para, textX: tx, gap: nil, beside: [para, PageRect(page: 15, rect: [346, 141, 540, 212])]),
                       [102.25, 128.4, 104.25, 257.8])
        // a wide float wrapped on the right, starting left of the middle: still its own (right) side
        XCTAssertEqual(bar([200, 141, 504, 212]), [508.75, 141, 510.75, 212])
        // wrapped on the left: the left margin, 4 pt out from the paragraph's bar, 2 pt between, clear of the ruler
        let left = bar([108, 141, 250, 212])
        XCTAssertEqual(left, [98.25, 141, 100.25, 212])
        XCTAssertEqual(102.25 - left[2], 2)
        XCTAssertTrue(left[0] > 86.4)
        // the same float alone on its page (no paragraph beside it): the plain left bar
        XCTAssertEqual(bar([108, 141, 250, 212], []), [102.25, 141, 104.25, 212])
        // a part on another page, one that only touches (1 pt), and an item about as wide as the paragraph: no change
        XCTAssertEqual(bar([108, 141, 250, 212], [PageRect(page: 14, rect: para.rect)])[0], 102.25)
        XCTAssertEqual(bar([108, 257, 250, 300])[0], 102.25)
        XCTAssertEqual(bar([118, 250, 504, 300])[0], 102.25)
        // two columns (ACL): a float wrapped at the left of the left column, beside its paragraph: 4 pt out, clear
        // of the ruler at x 12–26
        let acl = bar([70.87, 100, 180, 160], [PageRect(page: 15, rect: [70.87, 74.43, 289.13, 246.78])], gap: 298.34,
                      textX: [70.47, 526.22])
        XCTAssertEqual(acl[0], 61.47, accuracy: 1e-9)
        XCTAssertTrue(acl[0] > 25.5)
    }

    // MARK: Keys

    func testReadingKeys() {
        func state(_ f: (inout KeyState) -> Void) -> KeyState {
            var s = KeyState()
            s.roundOpen = true
            f(&s)
            return s
        }
        let open = state { _ in }
        XCTAssertEqual(KeyRoute.action("n", open), .nextUnread)
        XCTAssertEqual(KeyRoute.action("c", open), .markRead)
        XCTAssertEqual(KeyRoute.action("shift-c", open), .markSectionRead)
        XCTAssertNil(KeyRoute.action("p", open))  // there is no prose view to switch to
        XCTAssertEqual(KeyRoute.action("b", open), .armBox)
        // a closed or earlier round: N moves, and C / Shift-C say why they do nothing (never silent)
        let closed = KeyState()
        XCTAssertEqual(KeyRoute.action("n", closed), .nextUnread)
        XCTAssertEqual(KeyRoute.action("c", closed), .markRead)
        XCTAssertEqual(KeyRoute.action("shift-c", closed), .markSectionRead)
        // with a selection, Return and the style keys act on it, and C marks its paragraph read
        let sel = state { $0.textSelection = true; $0.card = .new }
        XCTAssertEqual(KeyRoute.action("return", sel), .openEditor)
        XCTAssertEqual(KeyRoute.action("s", sel), .pendingKind(.strikeout))
        XCTAssertEqual(KeyRoute.action("c", sel), .markRead)
        // reading marks off (Settings, their default): N, C and Shift-C are not the app's keys; F, J and B still are
        let off = state { $0.reading = false }
        for k in ["n", "c", "shift-c"] { XCTAssertNil(KeyRoute.action(k, off), k) }
        XCTAssertNil(KeyRoute.action("c", state { $0.reading = false; $0.textSelection = true; $0.card = .new }))
        XCTAssertEqual(KeyRoute.action("f", off), .toggleFocus)
        XCTAssertEqual(KeyRoute.action("b", off), .armBox)
        XCTAssertEqual(KeyRoute.action("j", open), .next)
        XCTAssertEqual(KeyRoute.action("v", state { $0.card = .carried(answered: false) }), .verdict("verified"))
    }

    // MARK: State

    func testStateDecodesReading() throws {
        let st = try fixture()
        let r = try XCTUnwrap(st.reading)
        XCTAssertEqual(r.count, 35)
        XCTAssertEqual(r.unread, 6)
        XCTAssertEqual(r.paragraphs.count, 35)
        XCTAssertEqual(Set(r.paragraphs.map(\.block)).subtracting(r.read), [4, 8, 18, 27, 31, 34])
        XCTAssertTrue(r.paragraphs.allSatisfy { !$0.parts.isEmpty && $0.parts.allSatisfy(\.valid) })
        XCTAssertEqual(r.headings.map(\.title), ["1 Introduction", "2 Related Work", "3 Method", "4 Evaluation", "5 Conclusion",
                                                 "References"])
        XCTAssertEqual(r.paragraphs.first?.section, -1)  // the abstract
        XCTAssertEqual(st.comments.first { $0.id == "R1-01" }?.paragraph, 4)
        XCTAssertNil(st.comments.first { $0.id == "R1-08" }?.paragraph)
        XCTAssertEqual(st.changes.first { $0.id == "c06" }?.blocks, [34])
        // the older fixtures have none of it
        let old = try EngineState.decode(Data(contentsOf: Self.fixtures.appendingPathComponent("state-round2.json")))
        XCTAssertNil(old.reading)
        let bare = try JSONDecoder().decode(ReadingInfo.self, from: Data(#"{"read": [1], "count": 2, "unread": 1}"#.utf8))
        XCTAssertEqual(bare.paragraphs, [])
    }

    func testChangeReadCountsAsHandled() throws {
        let st = try fixture()
        let c06 = try XCTUnwrap(st.changes.first { $0.id == "c06" })
        XCTAssertFalse(ChangeModel(c06, round: 2, pdfs: [:], textX: [], statuses: [:]).handled)
        XCTAssertTrue(ChangeModel(c06, round: 2, pdfs: [:], textX: [], statuses: [:], read: true).handled)
    }
}
