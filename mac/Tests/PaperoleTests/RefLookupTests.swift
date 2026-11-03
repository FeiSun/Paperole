import AppKit
import XCTest
@testable import Paperole

/// Looking the references up (design/pdf-reader/PLAN.md P1.3; RefLookup.swift): titles folded and compared, what a
/// citation's preview shows, the queues (what the engine has is left, a fresh cached result is given at once, a click
/// moves an entry first, a source turned off drops its queue), results given to the engine in batches, the Checks
/// tab's line, Semantic Scholar's JSON read, and the column's ring for a check the student answered. Nothing is
/// fetched: the sources are stand-ins. Synthetic only.
@MainActor
final class RefLookupTests: XCTestCase {
    private let vit = RefEntry(key: "dosovitskiy2021", label: "[12]",
                               title: "An Image is Worth 16x16 Words: Transformers for Image Recognition at Scale",
                               authors: ["Dosovitskiy, Alexey"], year: "2020", venue: "arXiv preprint arXiv:2010.11929",
                               arxiv: "2010.11929", preprint: true)
    private let made = RefEntry(key: "wang2023", label: "[19]", title: "Efficient sparse attention for long video reasoning",
                                authors: ["Wang, Li"], year: "2023", venue: "NeurIPS")

    func testTitlesFolded() {
        XCTAssertEqual(RefText.fold("{BERT}: Pre-training of Deep  Bidirectional \\emph{Transformers}"),
                       "bert pre training of deep bidirectional transformers")
        XCTAssertTrue(RefText.same("Deep Residual Learning for Image Recognition", "Deep residual learning for image recognition."))
        XCTAssertTrue(RefText.same("Attention is all you need", "Attention Is All You Need: transformers"), "a subtitle")
        XCTAssertFalse(RefText.same("Efficient sparse attention for long video reasoning",
                                    "Efficient sparse attention for long-range video understanding"))
        XCTAssertEqual(vit.lookupKey, "arxiv:2010.11929")
        XCTAssertEqual(made.lookupKey, "title:efficient sparse attention for long video reasoning")
    }

    /// The preview: a count per source on, "—" not yet; a cited preprint published since; no record anywhere with the
    /// closest match and no counts.
    func testWhatThePreviewShows() {
        let both: [RefSource] = [.semanticScholar, .googleScholar]
        var s = RefShown(entry: vit, results: [:], on: both)
        XCTAssertEqual(s.counts.map(\.count), [.pending, .pending])
        XCTAssertNil(s.published)
        let s2 = RefResult(found: true, title: vit.title, year: 2020, citations: 48902,
                           url: "https://www.semanticscholar.org/paper/x", doi: nil, record: "x", published: "ICLR 2021")
        s = RefShown(entry: vit, results: [.semanticScholar: s2], on: both)
        XCTAssertEqual(s.counts.map(\.count), [.cited(48902, URL(string: "https://www.semanticscholar.org/paper/x")), .pending])
        XCTAssertEqual(s.published?.venue, "ICLR 2021")
        XCTAssertFalse(s.noRecord)
        let none = RefResult(found: false, closest: .init(title: "Efficient sparse attention for long-range video understanding",
                                                          year: 2024, authors: ["L. Wang"]))
        s = RefShown(entry: made, results: [.semanticScholar: none], on: both)
        XCTAssertFalse(s.noRecord, "Google Scholar not looked up yet")
        s = RefShown(entry: made, results: [.semanticScholar: none, .googleScholar: RefResult(found: false)], on: both)
        XCTAssertTrue(s.noRecord)
        XCTAssertEqual(s.closest, "Efficient sparse attention for long-range video understanding · 2024 · L. Wang")
        // a work not a preprint shows no venue
        s = RefShown(entry: made, results: [.semanticScholar: RefResult(found: true, citations: 3, published: "NeurIPS 2023")],
                     on: [.semanticScholar])
        XCTAssertNil(s.published)
    }

    /// The queues: stored results are left, a fresh cached one is given to the engine at once, the rest queued in
    /// order; a preview moves its entry first in Google Scholar's; results go to the engine in one batch; the line; off.
    func testTheQueues() {
        let l = RefLookup(cacheURL: nil, fetchers: [:])
        var stored: [(RefSource, [String])] = []
        var ended = 0
        l.store = { _, _, s, rs, _ in if !rs.isEmpty { stored.append((s, rs.keys.sorted())) } }
        l.finished = { _, _ in ended += 1 }
        let third = RefEntry(key: "he2016", title: "Deep residual learning for image recognition")
        l.deliver(RefLookup.Job(paper: "/p", round: 1, entry: third, source: .semanticScholar),
                  RefResult(found: true, citations: 9, at: Date()))  // cached from another paper
        stored = []
        l.start(paper: "/p", round: 2, entries: [vit, made, third],
                stored: ["semantic_scholar": ["dosovitskiy2021": RefResult(found: true)]],
                sources: [.semanticScholar, .googleScholar])
        XCTAssertEqual(stored.map(\.0), [.semanticScholar])
        XCTAssertEqual(stored.first?.1, ["he2016"], "the cached result, at once")
        XCTAssertEqual(l.queued[.semanticScholar]?.map(\.entry.key), ["wang2023"], "the engine had ViT's")
        XCTAssertEqual(l.queued[.googleScholar]?.map(\.entry.key), ["dosovitskiy2021", "wang2023", "he2016"])
        XCTAssertEqual(l.line(paper: "/p", round: 2),
                       "Looking up references · Semantic Scholar 1 of 2 · Google Scholar 0 of 3, about 3 min")
        l.prefer(paper: "/p", round: 2, key: "he2016")
        XCTAssertEqual(l.queued[.googleScholar]?.map(\.entry.key), ["he2016", "dosovitskiy2021", "wang2023"])
        l.deliver(RefLookup.Job(paper: "/p", round: 2, entry: made, source: .semanticScholar), RefResult(found: false))
        XCTAssertEqual(stored.last?.1, ["wang2023"])
        XCTAssertEqual(l.line(paper: "/p", round: 2), "Looking up references · Google Scholar 0 of 3, about 3 min")
        // an entry with an arXiv id but no title: Semantic Scholar only (Google Scholar searches titles)
        let bare = RefEntry(key: "x2021", title: nil, arxiv: "2101.00001")
        l.start(paper: "/p", round: 2, entries: [bare], stored: [:], sources: [.semanticScholar, .googleScholar])
        XCTAssertEqual(l.queued[.semanticScholar]?.map(\.entry.key), ["x2021"])
        XCTAssertFalse(l.queued[.googleScholar]?.contains { $0.entry.key == "x2021" } ?? true)
        l.stop(.semanticScholar)
        l.stop(.googleScholar)
        XCTAssertEqual(l.queued[.googleScholar], [])
        XCTAssertNil(l.line(paper: "/p", round: 2))
        XCTAssertEqual(ended, 1, "round 1's; round 2's ended by turning Google Scholar off, without the toast")
        XCTAssertNotNil(l.cached(made, .semanticScholar))
        XCTAssertNil(l.cached(made, .semanticScholar, now: Date().addingTimeInterval(31 * 86400)), "30 days")
    }

    /// Semantic Scholar's paper JSON: the short venue with the year when published, none for a preprint's.
    func testSemanticScholarRead() {
        let r = SemanticScholar.result([
            "paperId": "abc", "title": "An Image is Worth 16x16 Words", "year": 2020, "citationCount": 48902,
            "venue": "International Conference on Learning Representations",
            "publicationVenue": ["name": "International Conference on Learning Representations", "alternate_names": ["ICLR", "Int Conf Learn Represent"]],
            "externalIds": ["ArXiv": "2010.11929", "DBLP": "conf/iclr/x"], "authors": [["name": "Alexey Dosovitskiy"]],
            "url": "https://www.semanticscholar.org/paper/abc"])
        XCTAssertEqual(r.published, "ICLR", "no year: Semantic Scholar's is often the arXiv version's")
        XCTAssertEqual(r.arxiv, "2010.11929")
        XCTAssertEqual(r.authors, ["Alexey Dosovitskiy"])
        XCTAssertEqual(r.citations, 48902)
        let pre = SemanticScholar.result(["paperId": "d", "title": "X", "year": 2024, "venue": "arXiv.org"])
        XCTAssertNil(pre.published)
        // the engine's form leaves `at` out
        var withAt = r
        withAt.at = Date()
        XCTAssertNil(withAt.json["at"])
        XCTAssertEqual(withAt.json["published"] as? String, "ICLR")
    }

    /// The sources' own logos decode (2026-11-02), at their sites' sizes.
    func testTheLogos() throws {
        XCTAssertEqual(try XCTUnwrap(SourceLogos.googleScholar).representations.first?.pixelsWide, 48)
        XCTAssertEqual(try XCTUnwrap(SourceLogos.semanticScholar).representations.first?.pixelsWide, 32)
    }

    /// The column's window lists a check the student answered as a row of its own.
    func testTheColumnsCheckRow() {
        let c = Check(code: "spelling", group: "consistency", text: "“data set” and “dataset”",
                      places: [Check.Place(page: 2, rects: [[72, 300, 120, 312]])], id: "A2-05", state: "still", carried: true,
                      studentNote: StudentNote(text: "The venue's style guide."))
        let items = [ScrollerMark(kind: .toCheck, fraction: 0.3, target: .check("A2-05"), page: 2, label: "A2-05")]
        let rows = LaneRows.make([0], items: items, ys: [100], pointer: nil, currentMatch: nil, card: { _ in nil },
                                 change: { _ in nil }, edits: { _ in 0 }, line: { _ in LaneMatchLine() }, check: { $0 == "A2-05" ? c : nil })
        XCTAssertEqual(rows.rows.map(\.words), ["○ A2-05 still found 💬 · p.3 | “data set” and “dataset”"])
        XCTAssertEqual(StripLayout.key(.check("A2-05")), "a:A2-05")
    }
}
