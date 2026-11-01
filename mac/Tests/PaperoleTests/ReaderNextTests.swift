import XCTest
@testable import Paperole

/// The reader's next four (design/pdf-reader/PLAN.md P1.1, P1.2, P1.4, P1.6): Go to Page's numbers, the place followed
/// across rounds, Clean Copy and the markers beside the scroller. Pure logic on synthetic values.
final class ReaderNextTests: XCTestCase {
    // MARK: Go to Page (P1.4)

    func testPageQueries() {
        XCTAssertEqual(Jump.page("p.12", count: 20), 11)
        XCTAssertEqual(Jump.page(" P 3 ", count: 20), 2)
        XCTAssertEqual(Jump.page("p7", count: 20), 6)
        XCTAssertEqual(Jump.page("page 20", count: 20), 19)
        XCTAssertNil(Jump.page("p.21", count: 20), "a page the PDF has not")
        XCTAssertNil(Jump.page("p.0", count: 20))
        XCTAssertNil(Jump.page("12", count: 20), "a bare number is a comment's words, not a page")
        XCTAssertNil(Jump.page("p.12", count: 0), "no PDF")
        XCTAssertNil(Jump.page("pages 2", count: 20))
        XCTAssertEqual(GoToPageField.page("4", count: 12), 3)
        XCTAssertEqual(GoToPageField.page("p.4", count: 12), 3)
        XCTAssertNil(GoToPageField.page("13", count: 12))
        XCTAssertNil(GoToPageField.page("four", count: 12))
    }

    func testJumpOffersThePageFirst() {
        var s = Jump.Sources()
        s.pages = 12
        let g = Jump.search("p.4", in: s)
        XCTAssertEqual(g.first?.title, "Pages")
        XCTAssertEqual(g.first?.rows, [Jump.Row(target: .page(3), icon: "doc", title: "Go to p.4", trailing: "of 12")])
        XCTAssertEqual(g.last?.rows.first?.target, .find("p.4"), "the find stays last")
        XCTAssertNil(Jump.search("p.13", in: s).first { $0.title == "Pages" })
    }

    // MARK: The same place across rounds (P1.1)

    private let paragraphs = [
        Paragraph(block: 3, section: 1, parts: [PageRect(page: 0, rect: [100, 100, 500, 200]), PageRect(page: 1, rect: [100, 80, 500, 120])]),
        Paragraph(block: 4, section: 1, parts: [PageRect(page: 1, rect: [100, 140, 500, 300])]),
    ]
    private let headings = [Heading(block: 1, level: 1, title: "1 Intro", parts: [PageRect(page: 0, rect: [100, 60, 300, 75])])]

    func testThePlaceRead() {
        let p = Reading.place(round: 2, page: 1, x: 300, y: 100, paragraphs: paragraphs, headings: headings)
        XCTAssertEqual(p, ReadingPlace(round: 2, block: 3, part: 1, offset: 20, page: 1, x: 300, y: 100), "its second part")
        let gap = Reading.place(round: 2, page: 1, x: 300, y: 130, paragraphs: paragraphs, headings: headings)
        XCTAssertEqual(gap.block, 4, "between paragraphs: the one below")
        XCTAssertEqual(gap.offset, 0)
        XCTAssertEqual(Reading.place(round: 2, page: 0, x: 200, y: 70, paragraphs: paragraphs, headings: headings).block, 1, "a heading")
    }

    func testWhereAFollowedPlaceGoes() {
        let from = ReadingPlace(round: 2, block: 3, part: 1, offset: 20, page: 1, x: 300, y: 100)
        let two = [PageRect(page: 4, rect: [100, 500, 500, 700]), PageRect(page: 5, rect: [90, 60, 490, 70])]
        XCTAssertTrue(Reading.followed(from, reply: FollowReply(block: 9, exact: true, parts: two), pages: 9)! == (5, 290, 70),
                      "the same part, as far down as it has room for")
        let one = [PageRect(page: 4, rect: [100, 500, 500, 700])]
        XCTAssertTrue(Reading.followed(from, reply: FollowReply(block: 9, exact: true, parts: one), pages: 9)! == (4, 300, 520),
                      "a block in one part: that part")
        XCTAssertTrue(Reading.followed(from, reply: FollowReply(block: 8, exact: false, parts: one), pages: 9)! == (4, 300, 500),
                      "a neighbour: its top")
        XCTAssertTrue(Reading.followed(from, reply: FollowReply(block: nil, exact: false, parts: []), pages: 9)! == (1, 300, 100),
                      "nothing to follow: the same page and point")
        XCTAssertTrue(Reading.followed(ReadingPlace(round: 2, page: 12, x: 5, y: 6), reply: nil, pages: 9)! == (8, 5, 6), "the last page")
        XCTAssertNil(Reading.followed(from, reply: nil, pages: 0))
    }

    // MARK: Clean Copy (P1.2)

    private func line(_ text: String, page: Int = 0, x0: Double = 100, _ top: Double, x1: Double = 500) -> CleanCopy.Line {
        CleanCopy.Line(text: text, page: page, x0: x0, top: top, x1: x1, bottom: top + 10)
    }

    func testLinesJoinedAndHyphensMended() {
        let lines = [line("We train a segmen-", 100), line("tation model on the state-of-the-", 112),
                     line("art data (pre-", 124), line("training) with 3–", 136), line("5 seeds.", 148)]
        XCTAssertEqual(CleanCopy.text(lines, rulers: { _ in nil }),
                       "We train a segmentation model on the state-of-the-art data (pretraining) with 3–5 seeds.")
        XCTAssertEqual(CleanCopy.join("BERT-", "Base"), "BERT-Base", "a capital after: the hyphen stays")
        XCTAssertEqual(CleanCopy.join("the temperature-", "softened outputs") { l, r in l == "temperature" && r == "softened" },
                       "the temperature-softened outputs", "a compound's hyphen stays")
    }

    func testCompoundOrBrokenWord() {
        let words: Set<String> = ["self", "attention", "temper", "under", "standing", "pre", "training", "further", "more",
                                  "furthermore"]
        func keeps(_ l: String, _ r: String, _ text: String = "") -> Bool {
            CleanCopy.keepsHyphen(l, r, text: { text }) { words.contains($0) }
        }
        XCTAssertTrue(keeps("self", "attention"), "two words")
        XCTAssertFalse(keeps("temper", "ature"), "a broken word")
        XCTAssertFalse(keeps("pre", "training"), "under four letters")
        XCTAssertTrue(keeps("under", "standing"), "two words, nothing else known")
        XCTAssertFalse(keeps("under", "standing", "the Understanding of"), "the paper has it whole")
        XCTAssertTrue(keeps("pre", "training", "our pre-training data"), "the paper has it hyphenated")
        XCTAssertFalse(keeps("further", "more"), "joined, a word")
        XCTAssertEqual(CleanCopy.join("the", "end"), "the end")
        XCTAssertEqual(CleanCopy.join("the model –", "which"), "the model – which", "a spaced dash keeps its space")
        XCTAssertEqual(CleanCopy.join("results -", "which") { _, _ in true }, "results - which")
        XCTAssertEqual(CleanCopy.join("and/", "or"), "and/or")
    }

    func testParagraphsColumnsAndPages() {
        let lines = [line("First paragraph ends.", 100), line("Second one starts", 125), line("and runs on", 137),
                     line("in the next column", x0: 520, 60, x1: 900), line("onto the next page.", page: 1, 60)]
        XCTAssertEqual(CleanCopy.text(lines, rulers: { _ in nil }),
                       "First paragraph ends.\n\nSecond one starts and runs on in the next column onto the next page.",
                       "without paragraphs: a gap starts one")
        // no space between paragraphs (article, IEEEtran): the engine's blocks tell them apart
        let tight = [line("First paragraph ends.", 100), line("Second one starts", 112), line("and runs on", 124)]
        let paragraphs = [Paragraph(block: 7, section: 1, parts: [PageRect(page: 0, rect: [100, 90, 500, 111])]),
                          Paragraph(block: 8, section: 1, parts: [PageRect(page: 0, rect: [100, 111, 500, 140])])]
        XCTAssertEqual(CleanCopy.text(tight, rulers: { _ in nil }, block: { CleanCopy.block(of: $0, paragraphs: paragraphs, headings: []) }),
                       "First paragraph ends.\n\nSecond one starts and runs on")
        XCTAssertEqual(CleanCopy.text(lines, rulers: { _ in nil }, block: { _ in 3 }),
                       "First paragraph ends. Second one starts and runs on in the next column onto the next page.",
                       "one block: one paragraph, gap or not")
    }

    func testAParagraphAcrossAPageBreak() {
        let ps = [Paragraph(block: 4, section: 1, parts: [PageRect(page: 0, rect: [100, 600, 500, 700]),
                                                          PageRect(page: 1, rect: [100, 80, 500, 120])])]
        let lines = [line("the end of page one runs", 690), line("5", page: 0, x0: 298, 740, x1: 304),
                     line("Under review as a conference paper", page: 1, 30), line("on to page two.", page: 1, 80)]
        func copy(_ ls: [CleanCopy.Line]) -> String {
            CleanCopy.text(ls, rulers: { _ in nil }, block: { CleanCopy.block(of: $0, paragraphs: ps, headings: []) },
                           outside: { CleanCopy.outside($0, paragraphs: ps, headings: []) })
        }
        XCTAssertEqual(copy(lines), "the end of page one runs on to page two.", "the foot and the running head left out")
        XCTAssertEqual(copy([lines[2]]), "Under review as a conference paper", "the running head alone is copied")
    }

    func testLineNumbersAndLigaturesLeftOut() {
        let rulers: [[Double]?] = [[70, 90, 85, 600], [505, 90, 520, 600]]
        let lines = [line("12", x0: 70, 100, x1: 80), line("The ﬁrst line", 100), line("13 The second", x0: 70, 112),
                     line("third line 14", 124, x1: 518), line("2024 was a year", 136), line("Model A 0.83", 148, x1: 512)]
        XCTAssertEqual(CleanCopy.text(lines, rulers: { _ in rulers }),
                       "The first line The second third line 2024 was a year Model A 0.83",
                       "the rulers' numbers go; a number the text starts with, or a decimal's tail, stays")
        XCTAssertEqual(CleanCopy.text([line("12", x0: 70, 100, x1: 80), line("trained on 12", 112, x1: 512)], rulers: { _ in nil }),
                       "12 trained on 12", "a page without rulers keeps every digit")
        XCTAssertEqual(CleanCopy.text([line("trained on 12", 112, x1: 512)], rulers: { _ in [nil, nil] }), "trained on 12")
        XCTAssertEqual(CleanCopy.clean("of\u{00AD}fer  ﬂow\n"), "offer flow")
    }

    // MARK: Markers beside the scroller (P1.6)

    func testFractionsOfThePapersHeight() {
        let h = [800.0, 800, 400]
        XCTAssertEqual(ScrollerMarks.fraction(page: 0, top: 0, heights: h), 0)
        XCTAssertEqual(ScrollerMarks.fraction(page: 1, top: 400, heights: h), 0.6)
        XCTAssertEqual(ScrollerMarks.fraction(page: 2, top: 900, heights: h), 1, "kept on its page")
        XCTAssertNil(ScrollerMarks.fraction(page: 3, top: 0, heights: h))
        XCTAssertNil(ScrollerMarks.fraction(page: 0, top: 0, heights: []))
    }
}
