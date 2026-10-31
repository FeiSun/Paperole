import AppKit
import SwiftUI
import XCTest
@testable import Paperole

/// The paper map's layout (OVERVIEW-v2 §4, the mockup's rules), as pure functions: the geometry by width, the shades
/// per paper, the fold, the key page, where a count goes, and over every state of the synthetic papers that every
/// count is there, inside its cell, never covered by a label, a pill or a path dot, and never changed by what is
/// followed; the structure labels never overlap; nothing runs past the overview's width. Synthetic data only: the
/// engine's reply for a four-round paper it built (Fixtures/overview-kelp.json: a merge, a rename, a split, a move, a
/// removed appendix and an added Conclusion), the M2a fixture, a generated stress paper (17 sections, 8 rounds), and a
/// generated crowded paper (14 sections of 0.1 to 16 pages, 3 rounds) for the scale and the names.
final class MapLayoutTests: XCTestCase {
    static let fixtures = OverviewDataTests.fixtures

    static func kelpJSON() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent("overview-kelp.json"))) as? [String: Any])
    }

    static func decode(_ json: [String: Any]) throws -> PaperOverview {
        let reply = try PaperOverview.decodeReply(JSONSerialization.data(withJSONObject: json))
        return try XCTUnwrap(reply.papers.first?.overview)
    }

    static func kelp() throws -> PaperOverview { try decode(kelpJSON()) }

    /// The overview's widths of a 1440, 1280 and 960 pt window with a 236 pt sidebar.
    static let widths: [CGFloat] = [1440 - 236 - 48, 1280 - 236 - 48, 960 - 236 - 48]

    /// A paper of 17 sections over 8 rounds and 22 pages (the mockup's stress paper), with counts and edits from a
    /// fixed seed; round 8 open with some to check, and one comment the last round could not place.
    static func stress() throws -> PaperOverview {
        var seed: UInt64 = 7
        func next() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) }
        let names = ["Introduction", "Background", "Related work", "Data", "Study sites", "Model", "Estimation", "Validation",
                     "Results", "Sensitivity", "Discussion", "Limitations", "Outlook", "Conclusion", "Acknowledgements", "References", "Appendix"]
        var rounds: [[String: Any]] = [], comments: [[String: Any]] = []
        for n in 1...8 {
            var w = names.map { _ in 0.4 + next() * 1.8 }
            let total = w.reduce(0, +)
            w = w.map { $0 / total * 21.6 }
            var spans: [[Any]] = [["front", "Title and abstract", 0.0, 0.4]], x = 0.4
            for (i, name) in names.enumerated() {
                spans.append([name.lowercased(), "\(i + 1) \(name)", x, min(22, x + w[i])])
                x += w[i]
            }
            var heat: [[Any]] = [], edits: [[Any]] = []
            var present = 0
            for sp in spans {
                let k = sp[0] as! String
                let new = next() < 0.4 ? Int(next() * 3) : 0, before = n > 1 && next() < 0.5 ? Int(next() * 4) : 0
                let tc = n == 8 ? min(before, next() < 0.3 ? 1 : 0) : 0
                heat.append([k, new, before, tc, 0, 0, 0])
                present += new + before
                if n > 1 && next() < 0.5 {
                    let a = sp[2] as! Double, b = sp[3] as! Double
                    edits.append(["c\(edits.count)", Int(a), a + (b - a) / 2, k, next() < 0.5 ? [] : ["R1-01"], next() < 0.4, n == 8 && next() < 0.2,
                                  false, 3, 1])
                }
            }
            rounds.append(["n": n, "created": "2026-0\(min(9, n + 1))-02T10:00:00+08:00", "closed": n < 8,
                           "closed_at": n < 8 ? "2026-0\(min(9, n + 1))-05T10:00:00+08:00" : NSNull(),
                           "build": ["status": "ok", "pages": 22], "prose": "ok", "spans": spans,
                           "match": n == 1 ? NSNull() : spans.map { [$0[0], $0[0], "same", 3, 3] },
                           "heat": heat, "edits": edits, "unplaced": n == 8 ? 1 : 0,
                           "comments": ["new": 4, "carried": present + (n == 8 ? 1 : 0) - 4, "edited": 2, "to_check": n == 8 ? 3 : 0]])
        }
        comments.append(["id": "R1-01", "created_round": 1, "path": (1...8).map { n -> [Any] in
            let model = (rounds[n - 1]["spans"] as! [[Any]]).first { $0[0] as! String == "model" }!
            let pos = ((model[2] as! Double) + (model[3] as! Double)) / 2
            return n == 8 ? [n, "unplaced", NSNull(), NSNull(), NSNull(), "untouched", "to_check"]
                : [n, "placed", Int(pos), pos, "model", n == 1 ? "new" : "edited", n == 1 ? NSNull() : "left_open"]
        }])
        return try decode(["papers": [["path": "/synthetic/tide", "overview": ["paper": ["title": "Tide", "student": "Ana Sousa"],
                                                                                   "rounds": rounds, "comments": comments]]]])
    }

    /// A fictional paper as crowded as a long real one (review 2026-10-20): three rounds of 31 pages, ten
    /// body sections of 0.1 to 2 pages, References of 2.7 and an appendix A–C of 20 pages (folded), counts of 0 to 5
    /// from a fixed seed; Related Work and the Discussion empty in round 1 (a quiet segment).
    static func crowded() throws -> PaperOverview {
        let body: [(String, String, Double)] = [
            ("front", "Title and abstract", 0.40), ("intro", "1 Introduction", 1.26), ("prelim", "2 Abstract Interpretation", 0.57),
            ("design", "3 Survey Design and Construction", 2.04), ("settings", "4 Evaluation Settings", 1.13),
            ("results", "5 Experimental Results and Analysis", 1.90), ("related", "6 Related Work", 0.40),
            ("discussion", "7 Discussion and Conclusion", 0.30), ("limits", "Limitations", 0.11), ("ethics", "Ethical Considerations", 0.15),
            ("references", "References", 2.74), ("sites", "A Site Details", 1.70), ("calibration", "B Instrument Calibration", 2.01),
            ("more", "C Supplementary Results and Analysis", 16.29)]
        var seed: UInt64 = 11
        func next() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) }
        var rounds: [[String: Any]] = []
        for n in 1...3 {
            var spans: [[Any]] = [], heat: [[Any]] = [], x = 0.0
            for (k, title, len) in body {
                spans.append([k, title, x, x + len])
                x += len
                let empty = n == 1 && (k == "related" || k == "discussion")
                heat.append([k, empty ? 0 : Int(next() * 4), empty ? 0 : (n > 1 ? Int(next() * 2) : 0), 0, 0, 0, 0])
            }
            rounds.append(["n": n, "created": "2026-10-1\(n)T10:00:00+08:00", "closed": true, "closed_at": "2026-10-1\(n)T12:00:00+08:00",
                           "build": ["status": "ok", "pages": 31], "prose": "ok", "spans": spans,
                           "match": n == 1 ? NSNull() : spans.map { [$0[0], $0[0], "same", 3, 3] }, "heat": heat, "edits": [], "unplaced": 0,
                           "comments": ["new": 3, "carried": 2]])
        }
        return try decode(["papers": [["path": "/synthetic/bubble", "overview": ["paper": ["title": "Bubble", "student": "Ana Sousa"],
                                                                                     "rounds": rounds, "comments": []]]]])
    }

    /// Every state the mockup's visibility test went through: nothing, each section of the latest round, each round,
    /// each comment, each page of the latest round.
    static func selections(_ d: PaperOverview) -> [OverviewItem?] {
        var out: [OverviewItem?] = [nil]
        let latest = d.rounds.last { $0.hasSections }
        for sp in latest?.spans ?? [] { out.append(.section(sp.section, round: latest!.n)) }
        for r in d.rounds { out.append(.round(r.n)) }
        for c in d.comments { out.append(.comment(c.id)) }
        for p in 0..<(d.latest?.build?.pages ?? 0) { out.append(.page(round: d.latest!.n, page: p)) }
        return out
    }

    /// The fields of the engine's reply the map reads besides navigation's (CONTRACT amendment "App, paper map"):
    /// unplaced, excerpts, marks naming their comment or change, the sections' names and rounds, a comment's kind,
    /// colour and note; a mark of an older engine has no id.
    func testTheEnginesFieldsForTheMapDecode() throws {
        let d = try Self.kelp()
        let r4 = try XCTUnwrap(d.round(4))
        XCTAssertEqual(r4.unplaced, 0)
        XCTAssertEqual(r4.excerpts?.count, r4.edits?.count)
        let marks = try XCTUnwrap(r4.marks)
        let comment = try XCTUnwrap(marks.first { $0.kind == "comment" })
        XCTAssertNotNil(comment.id.flatMap { d.comment($0) }, "a comment mark names its comment")
        XCTAssertGreaterThan(comment.rect.width, 0)
        XCTAssertTrue(marks.filter { $0.kind == "change" }.allSatisfy { m in r4.edits?.contains { $0.id == m.id } ?? false })
        let methods = try XCTUnwrap(d.sections.first { $0.key == "methods" })
        XCTAssertEqual(methods.name, "Materials and methods")
        XCTAssertEqual(methods.first, 1)
        XCTAssertEqual(methods.last, 4)
        XCTAssertEqual(methods.written, 7)
        XCTAssertEqual(d.sections.first { $0.key == "study-area" }?.gone, true)
        XCTAssertEqual(d.comment("R1-01")?.kind, "highlight")
        XCTAssertEqual(d.comment("R1-01")?.color, "yellow")
        XCTAssertEqual(d.comment("R1-01")?.note, "Shorter.")
        let old = try PaperOverview.decodeReply(Data(#"{"papers": [{"path": "/a", "overview": {"rounds": [{"n": 1, "marks": [[0, "comment", 10, 20, 5, 30]]}]}}]}"#.utf8))
        let m = try XCTUnwrap(old.papers.first?.overview?.round(1)?.marks?.first)
        XCTAssertNil(m.id)
        XCTAssertEqual(m.rect, CGRect(x: 5, y: 20, width: 5, height: 10), "corners in any order")
    }

    // MARK: Pure rules

    func testGeometryByWidth() {
        // UI v4: the readout a fixed 168 pt at every width (it was 320, 214 or 132 by width), Comments and, by the
        // data only, You; so the map keeps its room whether You shows or not
        let wide = MapGeometry(width: Self.widths[0], maxPages: 12, unplaced: false)
        XCTAssertEqual(wide.columns, 1)
        XCTAssertEqual(wide.readoutWidth, 168)
        let you = MapGeometry(width: Self.widths[0], maxPages: 12, unplaced: false, you: true)
        XCTAssertEqual(you.columns, 2)
        XCTAssertEqual(you.readoutWidth, 168)
        XCTAssertEqual(you.mapRight, wide.mapRight)
        XCTAssertEqual(you.columnRight, [you.readoutX + 48, you.width], "figures right-aligned: Comments, then You at the edge")
        XCTAssertEqual(wide.columnRight, [wide.width])
        XCTAssertEqual(wide.mapRight, wide.width - 168 - 22)
        XCTAssertEqual(wide.x(0), 108)
        XCTAssertEqual(wide.x(12), wide.mapRight, accuracy: 0.001)
        let narrow = MapGeometry(width: Self.widths[2], maxPages: 12, unplaced: true)
        XCTAssertEqual(narrow.capWidth, 46, "room for the unplaced caps")
        XCTAssertEqual(narrow.mapWidth, Self.widths[2] - 168 - 22 - 46 - 108)
        // the map's widths at 1440, 1280 and 960 pt windows (they were 812, 672 and 414)
        XCTAssertEqual(MapGeometry(width: Self.widths[0], maxPages: 1, unplaced: false).mapWidth, 858)
        XCTAssertEqual(MapGeometry(width: Self.widths[1], maxPages: 1, unplaced: false).mapWidth, 698)
        XCTAssertEqual(MapGeometry(width: Self.widths[2], maxPages: 1, unplaced: false).mapWidth, 378)
        XCTAssertEqual(MapGeometry.cell, 32, "UI v4: 32 pt cells (they were 28)")
    }

    /// Three steps per paper (VISUAL v3 §4.1, decision 1): thirds of its own non-zero counts; 1 · 2 · 3+ while no count
    /// passes 3.
    func testShadesArePerPaper() {
        XCTAssertEqual(MapShade.steps([1, 2, 3]), [1, 2], "small counts keep 1, 2, 3+")
        XCTAssertEqual(MapShade.labels([1, 2]), ["1", "2", "3+"])
        XCTAssertEqual(MapShade.labels(MapShade.steps([1, 2, 3, 4])), ["1–2", "3", "4+"])
        // the mockup's Reef: 1–3 · 4–5 · 6+
        let reef = [4, 7, 4, 3, 5, 6, 4, 3, 9, 6, 4, 3, 6, 5, 4, 1, 3, 3, 2, 2]
        XCTAssertEqual(MapShade.labels(MapShade.steps(reef)), ["1–3", "4–5", "6+"])
        let s = MapShade.steps(reef)
        XCTAssertEqual(MapShade.level(0, s), 0)
        XCTAssertEqual(MapShade.level(3, s), 1)
        XCTAssertEqual(MapShade.level(5, s), 2)
        XCTAssertEqual(MapShade.level(9, s), 3)
        // equal counts still give three steps, the top one the highest count
        let flat = MapShade.steps([5, 5, 5, 5])
        XCTAssertEqual(flat, [3, 4])
        XCTAssertEqual(MapShade.level(5, flat), 3)
        XCTAssertEqual(MapShade.steps([]), [1, 2])
        XCTAssertEqual(MapRole.cell(7), .s3, "never past the third step")
    }

    func testOlderRoundsFoldWhenTheyDoNotFit() {
        XCTAssertEqual(MapRules.folded(rounds: 4, room: 400), 0, "four rounds fit 400 pt")
        XCTAssertEqual(MapRules.folded(rounds: 8, room: 481), 2, "the mockup: eight rounds at 1280 × 800 fold two")
        XCTAssertEqual(MapRules.folded(rounds: 8, room: 900), 0)
        XCTAssertEqual(MapRules.folded(rounds: 2, room: 50), 0, "two rounds never fold")
        XCTAssertEqual(MapRules.folded(rounds: 3, room: 50), 2, "at least two fold, one stays")
        XCTAssertEqual(MapRules.folded(rounds: 12, room: 50), 10, "two stay when there are more than three")
        XCTAssertEqual(MapRules.folded(rounds: 6, room: 0), 0, "not measured yet")
    }

    func testTheKeyPage() throws {
        let d = try Self.kelp()
        let r = try XCTUnwrap(d.latest)
        let busiest = (r.pages ?? []).max { ($0.comments ?? 0) + ($0.changes ?? 0) < ($1.comments ?? 0) + ($1.changes ?? 0) }
        XCTAssertEqual(MapRules.keyPage(r), busiest?.page)
        let json = #"{"papers": [{"path": "/a", "overview": {"rounds": [{"n": 1, "pages": [{"page": 3, "comments": 2, "changes": 0},"#
            + #"{"page": 1, "comments": 1, "changes": 1}, {"page": 5, "comments": 0, "changes": 1}]}, {"n": 2}]}}]}"#
        let o = try XCTUnwrap(PaperOverview.decodeReply(Data(json.utf8)).papers.first?.overview)
        XCTAssertEqual(MapRules.keyPage(o.round(1)), 1, "the first of equals")
        XCTAssertEqual(MapRules.keyPage(o.round(2)), 0, "no pages listed: the first")
    }

    /// VISUAL v3 §4.1 with the advisor's review of 2026-10-20: with a name the count goes right, 7 pt in (4 in a
    /// narrow cell), in any cell the name fits beside it; without one in the middle; never under a path dot.
    func testWhereACountGoes() {
        // a wide cell with a name: the count right, the name left
        var p = MapRules.placeNumber(xa: 100, xb: 200, width: 8, count: 3, dots: [], name: 40)
        XCTAssertEqual(p, MapRules.NumberPlace(x: 193, anchor: .end, name: true, nudge: false))
        // no name: in the middle
        p = MapRules.placeNumber(xa: 100, xb: 200, width: 8, count: 3, dots: [])
        XCTAssertEqual(p, MapRules.NumberPlace(x: 150, anchor: .middle, name: false, nudge: false))
        // a name too long for the cell with its count: the count in the middle, no name
        XCTAssertFalse(MapRules.placeNumber(xa: 100, xb: 160, width: 8, count: 3, dots: [], name: 40).name)
        // a narrow cell: a short name with the count, in the normal spacing where it fits, else the narrow one
        XCTAssertTrue(MapRules.placeNumber(xa: 100, xb: 150, width: 8, count: 3, dots: [], name: 10).name, "no 56 pt threshold")
        XCTAssertFalse(MapRules.placeNumber(xa: 100, xb: 130, width: 8, count: 3, dots: [], name: 10).name)
        p = MapRules.placeNumber(xa: 100, xb: 130, width: 8, count: 3, dots: [], name: 9, spacing: .tight)
        XCTAssertEqual(p, MapRules.NumberPlace(x: 126, anchor: .end, name: true, nudge: false), "4 pt in, 5 pt from the name")
        XCTAssertEqual(MapRules.CellSpacing.tight.room(30, count: 8), 30 - 4 - 4 - 5 - 8)
        // a narrow one: in the middle, no name
        p = MapRules.placeNumber(xa: 100, xb: 130, width: 8, count: 3, dots: [])
        XCTAssertEqual(p.anchor, .middle)
        XCTAssertFalse(p.name)
        // a path dot in the middle: the count moves beside it, never under it, and no name
        p = MapRules.placeNumber(xa: 100, xb: 200, width: 8, count: 3, dots: [150], name: 20)
        XCTAssertFalse(p.name, "nothing but the count beside a path")
        XCTAssertTrue(p.x + 4 < 150 - 9.5 || p.x - 4 > 150 + 9.5 || (p.anchor == .end && p.x < 150 - 9.5) || (p.anchor == .start && p.x > 150 + 9.5))
        // dots everywhere: the dot moves to the cell's lower edge
        p = MapRules.placeNumber(xa: 100, xb: 130, width: 8, count: 3, dots: [105, 115, 125])
        XCTAssertTrue(p.nudge)
        // no count: the name when it fits
        XCTAssertTrue(MapRules.placeNumber(xa: 0, xb: 60, width: 8, count: 0, dots: [], name: 30).name)
        XCTAssertTrue(MapRules.placeNumber(xa: 0, xb: 45, width: 8, count: 0, dots: [], name: 20).name)
        XCTAssertFalse(MapRules.placeNumber(xa: 0, xb: 30, width: 8, count: 0, dots: [], name: 20).name)
    }

    /// The advisor's review of 2026-10-20: a name too long for its cell shows as much as fits, its short form, its
    /// first words, its first letters with ".", its initials, its first letter; nothing only when one letter does not
    /// fit.
    func testNamesFallBackToWhatFits() {
        func w(_ s: String) -> CGFloat { MapFont.name.width(s) }
        func label(_ s: String, _ room: CGFloat) -> String? { MapRules.label(s, .name, room) }
        // each step at the room it needs
        let intro = ["Introduction", "Intro.", "Int.", "In.", "I.", "I"]
        for t in intro { XCTAssertEqual(label("Introduction", w(t)), t, "at \(t)'s width") }
        XCTAssertFalse(MapRules.labels("Introduction").contains("Intr."), "one letter short of its fixed form: a misspelling")
        let bench = ["Benchmark Construction", "Benchmark…", "Bench.", "Ben.", "Be.", "B.", "B"]
        for t in bench { XCTAssertEqual(label("Benchmark Construction", w(t) + 0.05), t, "at \(t)'s width") }
        XCTAssertNil(label("Benchmark Construction", w("B") - 0.5), "nothing only when one letter does not fit")
        XCTAssertEqual(label("Discussion and Conclusion", w("Discussion…") + 0.1), "Discussion…", "never ending on “and”")
        XCTAssertEqual(label("Results and Discussion", w("Results and…") + 0.1), "Results…")
        XCTAssertEqual(label("Related Work", w("Related")), "Related", "the fixed short form first")
        XCTAssertEqual(label("Ethical Considerations", w("Ethics")), "Ethics")
        XCTAssertEqual(label("On Model Bias", w("Mo.")), "Mo.", "a cut of the first word that is not a small word")
        XCTAssertNil(MapRules.labels("Evaluation Settings").first { $0 == "ES" }, "two initials read as a word")
        XCTAssertTrue(MapRules.labels("Ablation as Sensitivity Probe").contains("ASP"), "three are initials")
        XCTAssertEqual(MapRules.initials("Abstract Interpretation"), "AI", "two only as a way out of a look-alike")
        // the code audit: a small word, punctuation or a hyphen first; text without letters to cut at
        XCTAssertEqual(MapRules.labels("The Proposed Method").suffix(4), ["Prop.", "Pr.", "P.", "P"])
        XCTAssertEqual(MapRules.labels("A Case Study").suffix(2), ["C.", "C"], "not “A”, which reads as an appendix's")
        XCTAssertEqual(MapRules.labels("(a) Setup").suffix(3), ["Se.", "S.", "S"])
        XCTAssertFalse(MapRules.labels("Pre-training Data").contains { $0.contains("-") && $0.hasSuffix(".") }, "never inside “Pre-training”")
        XCTAssertEqual(MapRules.labels("实验结果与分析").dropFirst().first, "实验结果…")
        XCTAssertFalse(MapRules.labels("实验结果与分析").contains { $0.hasSuffix(".") })
        // a lettered appendix section: its letter first, as the paper says it, and last
        XCTAssertEqual(MapRules.labels("Experimental Details", letter: "C").first, "C Experimental Details")
        XCTAssertTrue(MapRules.labels("Experimental Details", letter: "C").contains("C Exp."))
        XCTAssertEqual(MapRules.labels("Experimental Details", letter: "C").last, "C")
        // a wider cell may show a longer form of the stem its narrowest has
        XCTAssertTrue(MapRules.extends("Bench.", "Ben."))
        XCTAssertTrue(MapRules.extends("Benchmark…", "Ben."))
        XCTAssertFalse(MapRules.extends("Be.", "Ben."))
        XCTAssertFalse(MapRules.extends("Ablation…", "ASP"))
        let forms = MapRules.labels("Benchmark Construction")
        XCTAssertEqual(MapRules.pick(forms, base: "Ben.", .name, w("Bench.") + 0.1), "Bench.")
        XCTAssertEqual(MapRules.pick(MapRules.labels("Ablation as Sensitivity Probe"), base: "ASP", .name, w("Ablation…") + 0.1), "ASP",
                       "initials stay initials: “Ablation…” reads as another name")
        // a longer form never reads as another section's name (Ablation named "A." where the abstract is "Ab.")
        let asp = MapRules.labels("Ablation as Sensitivity Probe")
        XCTAssertEqual(MapRules.pick(asp, base: "A.", .name, max(w("Abst."), w("ASP")) + 0.1, avoid: ["Ab."]), "ASP")
        XCTAssertEqual(MapRules.pick(asp, base: "A.", .name, w("Ab.") + 0.1, avoid: ["Ab."]), "A.")
        XCTAssertEqual(label("Warm by Forecast, then Scale on Demand", w("Warm by Forecast…") + 0.1), "Warm by Forecast…",
                       "no comma before the ellipsis")
        // names that read alike: one starts with the other
        XCTAssertTrue(MapRules.clash("Abs.", "Abst."))
        XCTAssertTrue(MapRules.clash("E", "ES"))
        XCTAssertTrue(MapRules.clash("Results…", "Results"))
        XCTAssertFalse(MapRules.clash("Abs.", "ASP"))
        XCTAssertFalse(MapRules.clash("Exp.", "Eval."))
        // the word cuts: five letters at most, never ending on a vowel or inside "ch"
        XCTAssertEqual(MapRules.cuts("Benchmark"), ["Bench.", "Ben.", "Be."])
        XCTAssertEqual(MapRules.cuts("Evaluation"), ["Eval.", "Ev."])
        XCTAssertEqual(MapRules.cuts("Preliminaries"), ["Prel.", "Pr."])
        XCTAssertEqual(MapRules.cuts("Experiments").first, "Exper.")
        XCTAssertEqual(MapRules.cuts("Me"), [], "too short to cut")
        XCTAssertEqual(MapRules.cuts("Ethical"), ["Eth.", "Et."], "two letters even before an h; never three short of the word")
        XCTAssertEqual(MapRules.cuts("Related"), ["Rel.", "Re."], "not “Relat.”")
        XCTAssertEqual(MapRules.cuts("Datasets").first, "Dat.", "not “Datas.”")
        XCTAssertEqual(MapRules.cuts("Abstract").first, "Abst.", "not “Abstr.”")
        // every label fits its room
        for room in stride(from: CGFloat(0), through: 160, by: 3.5) {
            for t in ["Introduction", "Materials and methods", "Ablation as Sensitivity Probe", "A", "3D Reconstruction"] {
                if let l = label(t, room) { XCTAssertLessThanOrEqual(w(l), room, "\(l) at \(room)") }
            }
        }
    }

    /// The map's scale (the advisor's review of 2026-10-20, `MapScale`): every section at least the floor that holds
    /// "Abc." and a count of one or two digits, the room taken from the sections above it in proportion; the row keeps
    /// its width and ends; places stay in page order; a longer section is never narrower; a folded block keeps its
    /// width and a quiet segment's sections their share; a row too crowded for the floor stays in proportion above 90%
    /// of an equal share.
    func testTheScaleGivesEverySectionRoomForItsName() {
        // the floor: "Abc." and the count, in the narrow cell's spacing, 1 pt in from each end
        let one = MapScene.floorWidths(most: 7), two = MapScene.floorWidths(most: 12), many = MapScene.floorWidths(most: 140)
        XCTAssertEqual(two.label, many.label, "two digits at most")
        XCTAssertLessThan(one.label, two.label)
        XCTAssertEqual(MapScene.floorWidths(most: 0).label, 2 + 8 + MapFont.name.width("Abc.") + 0.5, "no count: the name alone")
        for (f, n) in [(one, 7), (two, 12)] {
            let cw = MapFont.number.width("\(n)") + 1
            XCTAssertEqual(MapRules.label("Abcdefgh", .name, MapRules.CellSpacing.tight.room(f.label - 2, count: cw)), "Abc.")
            XCTAssertTrue(MapRules.placeNumber(xa: 0, xb: f.label - 2, width: cw, count: n, dots: [],
                                               name: MapFont.name.width("Abc."), spacing: .tight).name)
        }
        // a crowded paper's body at 1280 pt (in page units × 45 pt): too crowded for the whole floor
        let pages: [CGFloat] = [0.40, 1.26, 0.57, 2.04, 1.13, 1.90, 0.40, 0.30, 0.11, 0.15, 2.74]
        let w = pages.map { $0 * 45 }, kinds = [MapScale.Kind](repeating: .section, count: w.count)
        let total = w.reduce(0, +)
        let m = MapScale.floor(desired: two.label, count: two.count, free: total, sections: w.count)
        XCTAssertEqual(m, 0.9 * total / CGFloat(w.count), accuracy: 0.001, "90% of an equal share")
        let d = MapScale.widths(w, kinds, floor: m)
        XCTAssertEqual(d.reduce(0, +), total, accuracy: 0.001, "the row keeps its width")
        XCTAssertTrue(d.allSatisfy { $0 >= m - 0.001 }, "every section at least the floor")
        for i in w.indices { for j in w.indices where w[i] < w[j] { XCTAssertLessThanOrEqual(d[i], d[j] + 0.001, "a longer one never narrower") } }
        XCTAssertGreaterThan(d[10], d[1] + 5, "and still in proportion above the floor")
        XCTAssertEqual(d[10] / d[3], pages[10] / pages[3], accuracy: 0.001, "above the floor, as their lengths")
        // a roomier row: the whole floor, the rest in proportion
        let roomy = w.map { $0 * 2.5 }
        let m2 = MapScale.floor(desired: two.label, count: two.count, free: roomy.reduce(0, +), sections: w.count)
        XCTAssertEqual(m2, two.label, "the floor it wants when there is room")
        let d2 = MapScale.widths(roomy, kinds, floor: m2)
        XCTAssertEqual(d2.reduce(0, +), roomy.reduce(0, +), accuracy: 0.001)
        XCTAssertEqual(d2.min() ?? 0, m2, accuracy: 0.001)
        XCTAssertEqual(MapScale.widths(roomy, kinds, floor: 1), roomy, "nothing under the floor: as it is")
        // a block keeps its width; a quiet segment is one unit, floored and scaled whole, shared by its sections' lengths
        let mixed: [CGFloat] = [10, 100, 6, 5, 200, 128]
        let mk: [MapScale.Kind] = [.section, .section, .section, .section, .section, .fixed]
        XCTAssertEqual(MapScale.units(count: 6, runs: [[2, 3]]), [[0], [1], [2, 3], [4], [5]])
        let d3 = MapScale.widths(mixed, mk, runs: [[2, 3]], floor: 40)
        XCTAssertEqual(d3[5], 128, "the block")
        XCTAssertEqual(d3[0], 40, accuracy: 0.001)
        XCTAssertEqual(d3[2] + d3[3], 40, accuracy: 0.001, "the quiet segment at the floor as one")
        XCTAssertEqual(d3[2] / d3[3], 6 / 5, accuracy: 0.001)
        XCTAssertEqual(d3[4] / d3[1], 2, accuracy: 0.001)
        XCTAssertEqual(d3.reduce(0, +), mixed.reduce(0, +), accuracy: 0.001)
        let long = MapScale.widths([10, 100, 60, 50, 200], [MapScale.Kind](repeating: .section, count: 5), runs: [[2, 3]], floor: 40)
        XCTAssertGreaterThan(long[2] + long[3], long[1], "a quiet segment longer than a section is drawn wider")
        // the count's room when the floor cannot be had but that can
        let tight = [CGFloat](repeating: 10, count: 10)
        XCTAssertEqual(MapScale.floor(desired: 60, count: 9.6, free: 100, sections: 10), 9.5, accuracy: 0.001, "95% of an equal share")
        XCTAssertEqual(MapScale.floor(desired: 60, count: 8.5, free: 100, sections: 10), 9, accuracy: 0.001)
        XCTAssertEqual(MapScale.widths(tight, [MapScale.Kind](repeating: .section, count: 10), floor: 9.5), tight, "equal: as it is")
        let uneven: [CGFloat] = [2, 18, 10, 10, 10, 10, 10, 10, 10, 10]
        XCTAssertEqual(MapScale.widths(uneven, [MapScale.Kind](repeating: .section, count: 10), floor: 30).min() ?? 0, 9.5, accuracy: 0.001,
                       "a floor that cannot be had: 95% of an equal share at most")
        // the places: in order, the ends kept, each section from its drawn start to its drawn end
        var x: CGFloat = 108
        let cells = w.map { v -> (CGFloat, CGFloat) in defer { x += v }; return (x, x + v) }
        let rs = RowScale.make(cells, drawn: d)
        XCTAssertEqual(rs.x(108), 108, accuracy: 0.001)
        XCTAssertEqual(rs.x(108 + total), 108 + total, accuracy: 0.001, "the row keeps its ends")
        for (c, v) in zip(cells, d) { XCTAssertEqual(rs.x(c.1) - rs.x(c.0), v, accuracy: 0.001) }
        var last = -CGFloat.infinity
        for t in stride(from: CGFloat(100), through: 108 + total + 10, by: 0.25) {
            XCTAssertGreaterThan(rs.x(t), last, "in page order")
            last = rs.x(t)
        }
        XCTAssertEqual(RowScale.make(cells, drawn: w), .identity, "nothing changed: as it is")
    }

    /// The crowded paper at 1440, 1280 and 960 pt: every section but a quiet segment's has a name at 1440 and 1280
    /// (at 960 its 23 pt hold the count alone), its name in its narrowest cell or a longer form of that stem in every
    /// round, and its count; a quiet segment named too; a longer section never narrower; each row as long as its
    /// pages; the page axis's numbers apart; the lens from each section's start on the strip to its place on the map.
    func testACrowdedPaperNamesEverySection() throws {
        let d = try Self.crowded()
        for w in Self.widths {
            let s = MapScene.build(MapInput(data: d, width: w))
            try Self.check(s, d, nil)
            XCTAssertEqual(s.plan.folded, [.appendix])
            var names: [String: String] = [:]
            for row in s.rows {
                let spans = Dictionary((d.round(row.n)?.spans ?? []).map { ($0.section, $0.end - $0.start) }, uniquingKeysWith: { a, _ in a })
                let cells = row.cells.filter { $0.fold == nil && !$0.quiet }
                XCTAssertTrue(row.cells.filter(\.quiet).allSatisfy { _ in row.n == 1 }, "Related Work and the Discussion, empty in round 1")
                if w != Self.widths[2] {
                    for q in row.quiet { XCTAssertNotNil(q.name, "a quiet segment is named, \(q.sections) at \(w)") }
                }
                for c in cells {
                    if c.count > 0 { XCTAssertNotNil(c.number, "its count, \(c.section)@\(row.n) at \(w)") }
                    // UI v4: 19.5 pt at 960 (it was over 20; the readout is 168 pt there, it was 132), still its count's room
                    XCTAssertGreaterThan(c.rect.width, w == Self.widths[2] ? 19 : 38, "\(c.section) at \(w): \(c.rect.width)")
                    guard w != Self.widths[2] else { continue }
                    let name = try XCTUnwrap(c.name, "\(c.section)@\(row.n) at \(w) has a name")
                    let sn = try XCTUnwrap(s.names[MapScene.nameID(c.section, d.sectionTitle(c.section, round: row.n) ?? "")])
                    if let base = sn.base {
                        XCTAssertTrue(name.text == base || MapRules.extends(name.text, base) || name.text == sn.forms.first || name.text == sn.fixed,
                                      "\(name.text) reads as \(base), \(c.section)@\(row.n) at \(w)")
                        names[c.section] = base
                    }
                    for o in cells where (spans[o.section] ?? 0) > (spans[c.section] ?? 0) + 0.001 {
                        XCTAssertGreaterThanOrEqual(o.rect.width, c.rect.width - 0.01, "\(o.section) longer than \(c.section), never narrower")
                    }
                }
                let first = try XCTUnwrap(row.cells.first), last = try XCTUnwrap(row.cells.last)
                XCTAssertEqual(first.rect.minX, MapGeometry.mapX + 1, accuracy: 0.01)
                XCTAssertEqual(last.rect.maxX + 1, s.pageMaps[row.n]?.x(31) ?? 0, accuracy: 0.01, "the row as long as its pages")
            }
            if w != Self.widths[2] {
                XCTAssertEqual(names["intro"].map { $0 == "Introduction" || $0.hasPrefix("In") }, true, names["intro"] ?? "")
                // the abstract's name and Abstract Interpretation's never read alike
                let a = try XCTUnwrap(names["front"]), b = try XCTUnwrap(names["prelim"])
                XCTAssertFalse(MapRules.clash(a, b), "\(a) and \(b) at \(w)")
            }
            let numbers = s.axis.dropFirst()
            for (a, b) in zip(numbers, numbers.dropFirst()) { XCTAssertGreaterThan(b.rect.minX, a.rect.maxX + 2.9, "\(a.text), \(b.text) apart") }
            // the lens: a hairline's map end at a section's start in the strip's round (the top row), or an end
            let top = try XCTUnwrap(s.rows.first)
            let edges = top.cells.map(\.rect.minX).map { $0 - 1 } + [top.cells.last!.rect.maxX + 1]
            for f in s.fans { XCTAssertTrue(edges.contains { abs($0 - f[1].x) < 0.01 }, "a hairline at \(f[1].x) at \(w)") }
        }
    }

    func testFittingWords() {
        XCTAssertEqual(MapRules.fit("Methods", .name, 200), "Methods")
        let cut = try? XCTUnwrap(MapRules.fit("Materials and methods", .name, 60))
        XCTAssertTrue(cut?.hasSuffix("…") ?? false)
        XCTAssertLessThanOrEqual(MapFont.name.width(cut ?? ""), 60)
        XCTAssertNil(MapRules.fit("Materials and methods", .name, 8), "fewer than three letters: nothing")
        XCTAssertEqual(MapRules.fitParts(["6 here", "5 edited", "✓ 3", "+120 −90"], .label, MapFont.label.width("6 here · 5 edited · ✓") + 1),
                       "6 here · 5 edited", "the tail goes first")
        XCTAssertEqual(SectionRuler.label("2 Materials and methods", room: 300), "2 Materials and methods")
        XCTAssertEqual(SectionRuler.label("2 Materials and methods", room: MapFont.small.width("Materials and methods") + 1), "2 Methods",
                       "a numbered title keeps its number, with its short form")
        XCTAssertEqual(SectionRuler.label("2 Benchmark design", room: MapFont.small.width("Benchmark") + 1), "2 Bench.",
                       "no short form: its number and its first letters")
        XCTAssertEqual(SectionRuler.label("2 Benchmark design", room: MapFont.small.width("2 B") + 1), "2",
                       "not a lone letter after its number: the number alone")
        XCTAssertEqual(SectionRuler.label("12 Discussion", room: MapFont.small.width("12") + 1), "12", "at least its number")
        XCTAssertNil(SectionRuler.label("12 Discussion", room: MapFont.small.width("12") - 1), "nothing when even that does not fit")
        XCTAssertEqual(SectionRuler.label("C Extra results", room: MapFont.small.width("C Extra") + 1), "C Ex.",
                       "an appendix: its letter and its first letters (not “Extr.”, a letter short of the word)")
        XCTAssertEqual(SectionRuler.label("C Extra results", room: MapFont.small.width("C") + 1), "C")
        XCTAssertEqual(SectionRuler.label("Title and abstract", room: MapFont.small.width("Abstract") + 1), "Abstract",
                       "without a number: its short name")
        XCTAssertEqual(SectionRuler.label("References", room: MapFont.small.width("Refs") + 1), "Refs")
        XCTAssertEqual(SectionRuler.label("Title and abstract", room: MapFont.small.width("Ab.") + 1), "Ab.")
        XCTAssertNil(SectionRuler.label("Title and abstract", room: MapFont.small.width("Ab.") - 1), "not a lone “A”: an appendix's")
        let ethics = try? XCTUnwrap(SectionRuler.label("Ethics and consent", room: 30))
        XCTAssertLessThanOrEqual(MapFont.small.width(ethics ?? "-"), 30, "its first letters: \(ethics ?? "")")
        XCTAssertNil(SectionRuler.label("Ethics and consent", room: 4), "not even one letter")
    }

    func testTheStrip() {
        let g = StripGeometry(width: 1156, pages: 12, aspect: 8.5 / 11)
        XCTAssertEqual(g.thumbHeight, 72, accuracy: 0.01, "72 pt high when the slot is wide enough")
        XCTAssertEqual(g.page(at: g.thumbX(5) + 2), 5)
        let crowded = StripGeometry(width: 676, pages: 22, aspect: 8.5 / 11)
        XCTAssertLessThanOrEqual(crowded.thumbWidth, crowded.slot - 8)
        XCTAssertLessThanOrEqual(crowded.thumbX(21) + crowded.thumbWidth, 676)
        XCTAssertNil(crowded.page(at: 700))
        // the numbers: the ○ beside them while there is room, else on the page; then every other number
        XCTAssertTrue(StripLabels(slot: g.slot, pages: 12).ringBeside)
        XCTAssertEqual(StripLabels(slot: g.slot, pages: 12).every, 1)
        let thirty = StripLabels(slot: 676 / 30, pages: 30)
        XCTAssertFalse(thirty.ringBeside)
        XCTAssertEqual(thirty.every, 1)
        let sixty = StripLabels(slot: 676 / 60, pages: 60)
        XCTAssertEqual(sixty.every, 2)
        XCTAssertTrue(sixty.shows(0) && !sixty.shows(1), "1, 3, 5 …")
        // UI v4: the ring and the page's count 6 pt after the number while they fit (8 pages), else a ring on the page's
        // corner (30 pages; a 3-digit page in a slot that fits its number alone)
        let eight = StripLabels(slot: 1156 / 8, pages: 8, most: 3)
        XCTAssertTrue(eight.ringBeside)
        XCTAssertEqual(eight.every, 1)
        XCTAssertEqual(eight.ringWidth, 6 + 10 + 3 + MapFont.label.width("3"))
        XCTAssertFalse(StripLabels(slot: 676 / 30, pages: 30, most: 3).ringBeside)
        let wide = StripLabels(slot: 40, pages: 120, most: 12)
        XCTAssertEqual(wide.every, 1)
        XCTAssertFalse(wide.ringBeside, "a 3-digit page with a 2-digit count")
        XCTAssertFalse(StripLabels(slot: 676 / 60, pages: 60, most: 1).ringBeside)
        // the strip names its round only when it is not the latest
        XCTAssertEqual(PageStripView.roundLabel(1, latest: 2), "Round 1")
        XCTAssertNil(PageStripView.roundLabel(2, latest: 2))
        XCTAssertNil(PageStripView.roundLabel(nil, latest: 2))
    }

    /// A page's help tag gives the round's page count and adds up to its count to check (comments and edits), which
    /// shows on the page's corner instead when the strip is crowded.
    func testThePagesHelpHasItsCountToCheck() throws {
        let d = try Self.kelp()
        let r = try XCTUnwrap(d.round(4))
        let toCheck = PageStripView.pagesToCheck(r, d)
        XCTAssertFalse(toCheck.isEmpty)
        let re = try NSRegularExpression(pattern: "○ (\\d+) to check")
        for p in 0..<(r.build?.pages ?? 0) {
            let help = PageStripView.pageHelp(r, d, page: p)
            XCTAssertEqual(help[0], "Page \(p + 1) of \(r.build?.pages ?? 0) · Round 4")
            let line = help[1] as NSString
            let sum = re.matches(in: help[1], range: NSRange(location: 0, length: line.length))
                .compactMap { Int(line.substring(with: $0.range(at: 1))) }.reduce(0, +)
            XCTAssertEqual(sum, toCheck[p] ?? 0, "page \(p + 1): \(help[1])")
        }
    }

    // MARK: The scene

    func testTheKelpMap() throws {
        let d = try Self.kelp()
        let s = MapScene.build(MapInput(data: d, width: 1700 - 236 - 48, student: "Tomás"))
        XCTAssertEqual(s.rows.map(\.n), [4, 3, 2, 1], "the latest on top")
        // cells at their places, counts from heat
        let r4 = try XCTUnwrap(s.rows.first)
        XCTAssertEqual(r4.cells.map(\.section), d.round(4)?.spans?.map(\.section))
        XCTAssertEqual(r4.cells.first { $0.section == "methods" }?.count, 6)
        XCTAssertEqual(r4.cells.first { $0.section == "methods" }?.number?.text, "6")
        XCTAssertNil(r4.cells.first { $0.section == "front" }?.number, "no comment: no number")
        // UI v4: no chips; the cells to check add up to the round's comments to check, outlined once something in the
        // round is answered (Kelp's Round 4 has 2 resolved)
        XCTAssertEqual(r4.cells.map(\.toCheck).reduce(0, +), (d.round(4)?.heat ?? []).map(\.toCheck).reduce(0, +))
        XCTAssertEqual(r4.cells.filter(\.outlined).map(\.section), r4.cells.filter { $0.toCheck > 0 }.map(\.section))
        XCTAssertTrue(s.rows.dropFirst().allSatisfy { $0.cells.allSatisfy { $0.toCheck == 0 && !$0.outlined } }, "only in the open round")
        XCTAssertNotNil(r4.ring, "the open round's ring before its name")
        XCTAssertTrue(s.rows.dropFirst().allSatisfy { $0.ring == nil })
        XCTAssertEqual(s.rows.map(\.old), [false, true, true, true], "every row but the top one from the older rounds' ramp")
        XCTAssertEqual(r4.title.text, "Round 4")
        XCTAssertEqual(r4.dates.text, shortDate(d.round(4)?.created), "the day it came in only")
        // the structure the engine found, said beside its bands
        let words = Set(s.labels.map(\.text.text))
        for w in ["merged into Methods", "renamed", "split", "moved", "removed", "added"] { XCTAssertTrue(words.contains(w), w) }
        XCTAssertTrue(s.labels.allSatisfy { $0.text.ink == .secondary }, "never red: red is a failed build's")
        XCTAssertTrue(s.bands.contains { $0.kind == "merged" && $0.changed })
        XCTAssertTrue(s.bands.contains { $0.kind == "removed" && $0.points.count == 3 }, "a removed section's band ends in a point")
        XCTAssertEqual(s.bands.filter { $0.kind == "split" }.count, 2, "a split draws two bands")
        // the readout: this round's numbers
        // UI v4: Comments and You (Round 4 has answers), no student column (its words in the round's tag); no "0 new"
        // or "all new"; "–" where a round has no answers (they were "12 · 0 new · 3 edited · 3 untouched · 6 waiting")
        XCTAssertEqual(r4.readout.map(\.text), ["12", "✓ 2 so far"])
        XCTAssertEqual(s.rows.last?.readout.map(\.text), ["15", "–"])
        XCTAssertEqual(s.rows.last?.readout.last?.ink, .tertiary)
        XCTAssertEqual(s.captions.map(\.text), ["Comments", "You"])
        // edits: one tick each, where it was made; the one without a place has none
        XCTAssertEqual(r4.ticks.count, (d.round(4)?.edits ?? []).filter { $0.pos != nil }.count)
        XCTAssertEqual(r4.ticks.filter(\.toCheck).count, d.round(4)?.changes?.toCheck)
        // the lens: the strip's two ends, and at most one hairline a section after the first (fewer where they crowd)
        let starts = (d.round(4)?.spans?.count ?? 1) - 1
        XCTAssertGreaterThanOrEqual(s.fans.count, 2)
        XCTAssertLessThanOrEqual(s.fans.count, starts + 2)
        XCTAssertEqual(s.fans.first?.first?.x, 0, "from the strip's left end")
        XCTAssertEqual(s.fans.last?.first?.x ?? 0, s.geometry.width, accuracy: 0.5, "to its right end")
        XCTAssertTrue(s.axis.isEmpty, "UI v4: the strip numbers the pages, the axis does not")
        let noStrip = MapScene.build(MapInput(data: d, width: 1700 - 236 - 48, student: "Tomás", stripShown: false))
        XCTAssertEqual(noStrip.axis.first?.text, "page", "without the strip, the axis numbers them")
    }

    func testClicksFindWhatIsUnderThem() throws {
        let d = try Self.kelp()
        let s = MapScene.build(MapInput(data: d, width: Self.widths[1]))
        let cell = try XCTUnwrap(s.rows[1].cells.first { $0.section == "methods" })
        XCTAssertEqual(s.target(at: CGPoint(x: cell.rect.midX, y: cell.rect.midY)), .cell("methods", round: 3))
        XCTAssertEqual(MapTarget.cell("methods", round: 3).item, .section("methods", round: 3))
        XCTAssertEqual(s.target(at: CGPoint(x: 30, y: s.rows[2].y + 10)), .round(2), "the round's label")
        XCTAssertEqual(s.target(at: CGPoint(x: s.geometry.readoutX + 20, y: s.rows[0].y + 10)), .round(4), "the readout")
        let band = try XCTUnwrap(s.bands.first { $0.kind == "renamed" })
        let mid = CGPoint(x: band.points.map(\.x).reduce(0, +) / 4, y: band.points.map(\.y).reduce(0, +) / 4)
        XCTAssertEqual(s.target(at: mid), .band(from: "methods", to: "methods", round: 3))
        XCTAssertEqual(MapTarget.band(from: "extra", to: nil, round: 4).item, .section("extra", round: 3), "a removed band: its section before")
        XCTAssertNil(s.target(at: CGPoint(x: s.geometry.mapRight - 2, y: 2)), "the lens is empty space")
        XCTAssertNil(s.target(at: CGPoint(x: cell.rect.midX, y: s.rows[0].y - 12)), "no chips over the cells (UI v4)")
    }

    /// The mockup's visibility test (OVERVIEW-v2 §6), for the app's layout: in every state of every paper at the three
    /// window widths, each non-zero count is drawn inside its cell (or left out only when its cell is narrower than
    /// it and a neighbour's count is in the way), in full opacity when its cell holds what is followed, covered by no
    /// label, pill, path point or name (UI v4: no chips); the structure labels do not overlap each other or the pills; the rounds'
    /// readout is the same whatever is followed; nothing runs past the overview's width.
    func testNothingCoversACount() throws {
        var kelpPending = try Self.kelpJSON()
        Self.edit(&kelpPending) { o in
            var rounds = o["rounds"] as! [[String: Any]]
            for i in [0, 1] { rounds[i]["prose"] = "pending"; rounds[i]["spans"] = NSNull(); rounds[i]["heat"] = NSNull(); rounds[i]["match"] = NSNull() }
            rounds[2]["match"] = NSNull()
            o["rounds"] = rounds
        }
        let papers = [try Self.kelp(), try OverviewDataTests.overviewFixture(), try Self.stress(), try Self.decode(kelpPending)]
        var states = 0
        for d in papers {
            for w in Self.widths {
                var readouts: [Int: [String]]?
                for sel in Self.selections(d) {
                    for fold in [0, 2] {
                        let s = MapScene.build(MapInput(data: d, width: w, fold: fold, selection: sel, student: "Ana"))
                        states += 1
                        try Self.check(s, d, sel)
                        if fold == 0 {
                            let lines = Dictionary(uniqueKeysWithValues: s.rows.map { ($0.n, $0.readout.map(\.text)) })
                            if let r = readouts { XCTAssertEqual(lines, r, "the readout never changes (\(String(describing: sel)))") } else { readouts = lines }
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(states, 400)
    }

    static func check(_ s: MapScene, _ d: PaperOverview, _ sel: OverviewItem?) throws {
        let where_ = "\(String(describing: sel)) at \(s.geometry.width)"
        let labels = s.labels.map(\.text.rect)
        let pills = s.carriedPills.map(\.0)
        let dots = s.paths.flatMap(\.points).map { p -> CGRect in
            let r: CGFloat = p.glyph == .toCheck ? 8.5 : 6.5
            let k: CGFloat = p.small ? 0.75 : 1
            return CGRect(x: p.at.x - r * k, y: p.at.y - r * k, width: 2 * r * k, height: 2 * r * k)
        }
        var numbers: [CGRect] = []
        for row in s.rows {
            let heat = Dictionary((d.round(row.n)?.heat ?? []).map { ($0.section, $0.present) }, uniquingKeysWith: { a, _ in a })
            for c in row.cells {
                // a folded part's block counts all of its sections
                XCTAssertEqual(c.count, c.fold == nil ? heat[c.section] ?? 0 : c.sections.reduce(0) { $0 + (heat[$1] ?? 0) })
                guard c.count > 0 else { XCTAssertNil(c.number); continue }
                guard let t = c.number else {
                    XCTAssertLessThan(c.rect.width, MapFont.number.width("\(c.count)") + 4, "a count left out only in a cell too narrow for it, \(where_)")
                    continue
                }
                XCTAssertEqual(t.text, "\(c.count)")
                let ink = t.inkRect
                if c.rect.width >= MapFont.number.width(t.text) + 4 {
                    XCTAssertTrue(c.rect.insetBy(dx: 1, dy: 0).contains(ink), "inside its cell: \(c.section)@\(row.n) \(where_)")
                }
                for r in labels + pills + dots { XCTAssertFalse(r.intersects(ink), "\(c.section)@\(row.n) covered by \(r), \(where_)") }
                for o in row.cells { if let n = o.name { XCTAssertFalse(n.rect.intersects(ink), "a name over \(c.section)@\(row.n)") } }
                for o in numbers { XCTAssertFalse(o.intersects(ink), "two counts overlap at \(c.section)@\(row.n), \(where_)") }
                numbers.append(ink)
                if case .comment(let id)? = sel, let sec = d.comment(id)?.step(in: row.n)?.section, c.sections.contains(sec),
                   d.comment(id)?.step(in: row.n)?.state != "unplaced" {
                    XCTAssertFalse(c.dim, "the cell of the comment followed stays in full, \(where_)")
                }
                if case .section(let k, _)? = sel, c.sections.contains(k) { XCTAssertFalse(c.dim) }
            }
            // a name inside its cell, never past it (the advisor's review of 2026-10-20: names in narrow cells too)
            for c in row.cells where c.fold == nil {
                guard let n = c.name else { continue }
                XCTAssertGreaterThanOrEqual(n.rect.minX, c.rect.minX + 3.9, "\(n.text) in \(c.section)@\(row.n), \(where_)")
                XCTAssertLessThanOrEqual(n.rect.maxX, c.rect.maxX - 3.9, "\(n.text) in \(c.section)@\(row.n), \(where_)")
                XCTAssertFalse(c.quiet, "no name in a quiet segment")
            }
            for t in row.readout + [row.title, row.dates] + (row.endText.map { [$0] } ?? []) {
                XCTAssertLessThanOrEqual(t.rect.maxX, s.geometry.width + 0.5, "\(t.text) runs past the width, \(where_)")
            }
            if let t = row.sage { XCTAssertLessThanOrEqual(t.rect.maxX, s.geometry.width + 0.5, "the Sage line fits, \(where_)") }
            for c in row.cells { XCTAssertLessThanOrEqual(c.rect.maxX, s.geometry.mapRight + 0.5) }
        }
        // a removed band's point: no label on it but its own ("removed", or the gap's one label)
        let tips = s.bands.filter { $0.kind == "removed" && $0.points.count == 3 }.map { b in
            LabelPlacer.Point(id: 0, left: b.points[0].x, right: b.points[1].x, base: b.points[0].y, tip: b.points[2])
        }
        for (i, a) in s.labels.enumerated() {
            XCTAssertEqual(a.text.ink, .secondary, "never red: \(a.text.text), \(where_)")
            if !a.text.text.contains("removed") && !a.text.text.hasSuffix("changed") {
                for t in tips { XCTAssertFalse(t.crosses(a.text.rect), "\(a.text.text) on a removed band's point, \(where_)") }
            }
            for b in s.labels[(i + 1)...] { XCTAssertFalse(a.text.rect.intersects(b.text.rect), "\(a.text.text) over \(b.text.text), \(where_)") }
            for p in pills { XCTAssertFalse(a.text.rect.intersects(p), "\(a.text.text) over a pill, \(where_)") }
            XCTAssertLessThanOrEqual(a.text.rect.maxX, s.geometry.width)
        }
    }

    static func edit(_ json: inout [String: Any], _ f: (inout [String: Any]) -> Void) {
        var papers = json["papers"] as! [[String: Any]]
        var o = papers[0]["overview"] as! [String: Any]
        f(&o)
        papers[0]["overview"] = o
        json["papers"] = papers
    }

    func testRowsWithoutSections() throws {
        var json = try Self.kelpJSON()
        Self.edit(&json) { o in
            var rounds = o["rounds"] as! [[String: Any]]
            rounds[0]["prose"] = "pending"; rounds[0]["spans"] = NSNull(); rounds[0]["heat"] = NSNull()
            rounds[1]["prose"] = "unavailable"; rounds[1]["spans"] = NSNull(); rounds[1]["heat"] = NSNull(); rounds[1]["match"] = NSNull()
            rounds[2]["match"] = NSNull()
            o["rounds"] = rounds
        }
        let d = try Self.decode(json)
        let s = MapScene.build(MapInput(data: d, width: Self.widths[1]))
        let r1 = try XCTUnwrap(s.rows.first { $0.n == 1 }), r2 = try XCTUnwrap(s.rows.first { $0.n == 2 })
        XCTAssertEqual(r1.caption?.text, "Finding sections…")
        XCTAssertEqual(r2.caption?.text, "Sections unavailable for this round")
        XCTAssertTrue(r1.cells.isEmpty)
        XCTAssertEqual(r1.dots.count, d.comments.filter { $0.step(in: 1).map { $0.state != "unplaced" && $0.pos != nil } ?? false }.count,
                       "a dot per comment placed")
        XCTAssertEqual(r1.pageLines.count, (d.round(1)?.build?.pages ?? 1) - 1)
        XCTAssertFalse(r2.ticks.isEmpty, "the edits are drawn")
        XCTAssertTrue(s.bands.allSatisfy { $0.round == 4 }, "no bands to or from a row without sections")
        XCTAssertEqual(s.target(at: CGPoint(x: r1.pages!.midX, y: r1.pages!.midY)), .round(1))
    }

    func testABuildThatFailed() throws {
        var json = try Self.kelpJSON()
        Self.edit(&json) { o in
            var rounds = o["rounds"] as! [[String: Any]]
            rounds.append(["n": 5, "created": "2026-10-20T10:00:00+08:00", "closed": false, "build": ["status": "failed", "pages": NSNull()],
                           "prose": "unavailable", "spans": NSNull(), "heat": NSNull(), "match": NSNull(), "edits": [],
                           "comments": ["new": 0, "carried": 0]])
            var r4 = rounds[3]
            r4["closed"] = true
            rounds[3] = r4
            o["rounds"] = rounds
        }
        let d = try Self.decode(json)
        XCTAssertEqual(MapRules.defaultStrip(d), 4, "the strip shows the latest round that built")
        let s = MapScene.build(MapInput(data: d, width: Self.widths[0], buildErrors: "2 errors in methods.tex"))
        let r5 = try XCTUnwrap(s.rows.first)
        XCTAssertEqual(r5.n, 5)
        XCTAssertNil(r5.ring, "the octagon in its row says it, no ring")
        XCTAssertNotNil(r5.failed)
        let waiting = d.round(4)?.comments?.openAfter ?? 0
        XCTAssertEqual(r5.failedText?.text, "⚠ Build failed · 2 errors in methods.tex. \(MapScene.waitWords(waiting)).")
        XCTAssertEqual(r5.readout.first?.text, MapScene.waitWords(waiting, counted: false), "the shorter form in the 168 pt readout")
        XCTAssertEqual(MapScene.waitWords(1), "1 comment waits for a PDF")
        XCTAssertEqual(MapScene.waitWords(3, counted: false), "3 wait for a PDF")
        XCTAssertEqual(MapScene.waitWords(0), "No comment waits for a PDF")
        XCTAssertEqual(r5.carried?.text, "↑ \(waiting) carried")
        XCTAssertTrue(s.bands.allSatisfy { $0.round != 5 })
    }

    func testFoldingAndUnplaced() throws {
        let d = try Self.stress()
        let s = MapScene.build(MapInput(data: d, width: Self.widths[1], fold: 2))
        XCTAssertEqual(s.rows.map(\.n), [8, 7, 6, 5, 4, 3])
        XCTAssertEqual(s.folded, [2, 1])
        let f = try XCTUnwrap(s.fold)
        XCTAssertEqual(f.title.text, "Rounds 1–2")
        XCTAssertTrue(f.text.text.hasPrefix("2 older rounds folded: 8 comments written"))
        XCTAssertEqual(f.link.text, "Show all 8 rounds")
        XCTAssertEqual(s.target(at: CGPoint(x: f.rect.midX, y: f.rect.midY)), .unfold)
        XCTAssertNil(s.foldLink)
        let all = MapScene.build(MapInput(data: d, width: Self.widths[1], fold: 2, unfold: true))
        XCTAssertEqual(all.rows.count, 8)
        XCTAssertNil(all.fold)
        XCTAssertEqual(all.foldLink?.text, "Fold")
        XCTAssertGreaterThan(all.height, s.height)
        // the comment the open round could not place: in the row's cap, its path a square there
        XCTAssertEqual(s.geometry.capWidth, 46)
        XCTAssertEqual(s.rows.first?.unplacedText?.text, "+1")
        let followed = MapScene.build(MapInput(data: d, width: Self.widths[1], fold: 2, selection: .comment("R1-01")))
        let path = try XCTUnwrap(followed.paths.first)
        XCTAssertEqual(path.points.last?.glyph, .unplaced, "oldest to newest: the open round last")
        XCTAssertEqual(path.points.first?.glyph, .folded, "a dot on the fold for the rounds folded, where the path starts")
        // the stress paper's map fits the widths: 17 sections at 22 pages
        for w in Self.widths {
            let m = MapScene.build(MapInput(data: d, width: w, fold: 2))
            XCTAssertTrue(m.rows.allSatisfy { $0.cells.count == 18 })
            XCTAssertLessThanOrEqual(m.axis.map(\.rect.maxX).max() ?? 0, m.geometry.mapRight + 10)
        }
    }

    func testFollowingASectionAndAComment() throws {
        let d = try Self.kelp()
        let s = MapScene.build(MapInput(data: d, width: Self.widths[0], selection: .section("methods", round: 4)))
        XCTAssertEqual(s.sageCaption?.text, "Materials and methods only")
        XCTAssertTrue(s.rows.allSatisfy { r in r.cells.allSatisfy { $0.selected == ($0.section == "methods") && $0.dim == !$0.selected } })
        let carried = s.bands.filter { $0.selected }
        XCTAssertFalse(carried.isEmpty)
        XCTAssertEqual(s.carriedPills.count, carried.count, "a pill for each band that carried comments")
        XCTAssertEqual(s.rows.first?.sage?.text.hasPrefix("6 here"), true)
        XCTAssertNotNil(s.lensSelected)
        // a comment whose passage was deleted: ⊗ where it was
        let gone = try XCTUnwrap(d.comments.first { $0.path.contains { $0.state == "gone" } })
        let c = MapScene.build(MapInput(data: d, width: Self.widths[0], selection: .comment(gone.id)))
        let path = try XCTUnwrap(c.paths.first)
        XCTAssertEqual(path.points.first?.glyph, .written, "oldest to newest")
        XCTAssertEqual(path.points.last?.glyph, .gone)
        XCTAssertTrue(c.rows.first?.sage?.text.contains("passage deleted") ?? false)
        // the readout is the round's whatever is followed; edits made for the comment stand out
        let edited = try XCTUnwrap(d.comments.first { c in d.rounds.contains { r in (r.edits ?? []).contains { $0.attachedTo.contains(c.id) } } })
        let e = MapScene.build(MapInput(data: d, width: Self.widths[0], selection: .comment(edited.id)))
        XCTAssertTrue(e.rows.flatMap(\.ticks).contains { $0.strong && !$0.dim })
        XCTAssertTrue(e.rows.flatMap(\.ticks).filter { !$0.strong }.allSatisfy(\.dim))
        let round = MapScene.build(MapInput(data: d, width: Self.widths[0], strip: 2, selection: .round(2)))
        XCTAssertEqual(round.rows.filter(\.dim).map(\.n), [4, 3, 1])
        // the selected round's box behind the followed round's label: tinted and outlined (UI v4)
        let r2 = try XCTUnwrap(round.rows.first { $0.n == 2 })
        XCTAssertEqual(round.box?.minY, r2.y - 6)
        XCTAssertTrue(round.boxFollowed)
        let page = MapScene.build(MapInput(data: d, width: Self.widths[0], selection: .page(round: 4, page: 1)))
        XCTAssertNotNil(page.pageBand)
        XCTAssertEqual(page.paths.count, d.comments.filter { $0.step(in: 4)?.page == 1 && $0.step(in: 4)?.state != "unplaced" }.count)
    }

    /// UI v4's map (plan §3 step 3, mac/UX.md §40.3): no chips, the round's label over its arrival date, older rows
    /// from their own ramp, vermilion outlines on the cells to check only once something in the round is answered, a
    /// You column only with answers, and the selected round's box at the strip's round (none while it is folded).
    func testTheV4Map() throws {
        var json = try Self.kelpJSON()
        let answered = MapScene.build(MapInput(data: try Self.decode(json), width: Self.widths[0]))
        XCTAssertFalse(answered.rows.contains { r in Mirror(reflecting: r).children.contains { $0.label == "chips" } }, "no chips in a scene")
        XCTAssertFalse(answered.rows[0].cells.filter(\.outlined).isEmpty, "2 answered: the cells still to check outlined")
        // nothing answered yet: every cell all to check, the round's ring says it once, no outline
        Self.edit(&json) { o in
            var rounds = o["rounds"] as! [[String: Any]]
            rounds[3]["heat"] = (rounds[3]["heat"] as! [[Any]]).map { h -> [Any] in var h = h; h[3] = h[2]; return h }
            var c = rounds[3]["comments"] as! [String: Any]
            c["resolved"] = 0
            c["to_check"] = 12
            rounds[3]["comments"] = c
            o["rounds"] = rounds
        }
        let d = try Self.decode(json)
        let fresh = MapScene.build(MapInput(data: d, width: Self.widths[0]))
        XCTAssertFalse(fresh.rows[0].cells.filter { $0.toCheck > 0 }.isEmpty)
        XCTAssertTrue(fresh.rows.allSatisfy { $0.cells.allSatisfy { !$0.outlined } }, "nothing answered: no outline")
        // the advisor's own new comment in the round answers nothing: still no outline (by the answers, not the counts)
        var withNew = json
        Self.edit(&withNew) { o in
            var rounds = o["rounds"] as! [[String: Any]]
            var heat = rounds[3]["heat"] as! [[Any]]
            let i = heat.firstIndex { ($0[3] as! Int) > 0 }!
            heat[i][1] = (heat[i][1] as! Int) + 1
            rounds[3]["heat"] = heat
            var c = rounds[3]["comments"] as! [String: Any]
            c["new"] = 1
            rounds[3]["comments"] = c
            o["rounds"] = rounds
        }
        let written = MapScene.build(MapInput(data: try Self.decode(withNew), width: Self.widths[0]))
        XCTAssertTrue(written.rows[0].cells.contains { $0.toCheck > 0 && $0.toCheck < $0.count }, "a new comment counted in a cell")
        XCTAssertTrue(written.rows.allSatisfy { $0.cells.allSatisfy { !$0.outlined } }, "a new comment, nothing answered: no outline")
        XCTAssertEqual(fresh.rows[0].ring ?? -1, 0, accuracy: 0.001, "an empty ring: 0 comments answered, 0 of 8 unasked edits handled")
        XCTAssertEqual(answered.rows[0].ring ?? -1, 2.0 / 20, accuracy: 0.001, "2 answered of 2 + 10 comments and 8 unasked edits")
        // the same fill as the sidebar's and headers' ring (`PaperSummary.fill`), from the round's own counts
        var summary = try XCTUnwrap(Self.kelp().summary)
        summary.answered = 2
        summary.handled = 0
        XCTAssertEqual(answered.rows[0].ring ?? -1, summary.fill ?? -2, accuracy: 0.001)
        XCTAssertEqual(fresh.rows.map(\.old), [false, true, true, true])
        for r in fresh.rows {
            XCTAssertEqual(r.dates.text, shortDate(d.round(r.n)?.created), "the arrival date only")
            XCTAssertFalse(r.title.ink == .label && r.old, "an older round's name in secondary")
            for c in r.cells { if let t = c.number { XCTAssertEqual(t.ink == .label2, r.old, "an older round's numbers in label2") } }
        }
        // You: only while a shown round has answers, by the data only, never by what is followed
        XCTAssertEqual(fresh.geometry.columns, 2, "Rounds 2 and 3 closed with answers")
        let firstOnly = MapScene.build(MapInput(data: d, width: Self.widths[0], fold: 3))
        XCTAssertEqual(firstOnly.rows.map(\.n), [4])
        XCTAssertEqual(firstOnly.geometry.columns, 1, "no shown round with answers: Comments only")
        XCTAssertEqual(firstOnly.captions.map(\.text), ["Comments"])
        for sel in Self.selections(d) {
            XCTAssertEqual(MapScene.build(MapInput(data: d, width: Self.widths[0], selection: sel)).geometry.columns, 2)
        }
        // the box: at the strip's round's row, nil while it is folded
        for n in [4, 3, 1] {
            let s = MapScene.build(MapInput(data: d, width: Self.widths[0], strip: n))
            let row = try XCTUnwrap(s.rows.first { $0.n == n })
            XCTAssertEqual(s.box?.minY, row.y - 6, "Round \(n)")
            XCTAssertEqual(s.box?.size, MapGeometry.box)
            XCTAssertFalse(s.boxFollowed)
        }
        XCTAssertNil(MapScene.build(MapInput(data: d, width: Self.widths[0], fold: 2, strip: 1)).box, "Round 1 folded away")
        // You: all three answers, one count of two digits, drawn whole at every width, open and closed
        var many = try Self.kelpJSON()
        Self.edit(&many) { o in
            var rounds = o["rounds"] as! [[String: Any]]
            for i in [2, 3] {
                var c = rounds[i]["comments"] as! [String: Any]
                c["resolved"] = 11; c["follow_up"] = 2; c["kept"] = 1
                rounds[i]["comments"] = c
            }
            o["rounds"] = rounds
        }
        let dm = try Self.decode(many)
        let done = MapScene.answers(try XCTUnwrap(dm.round(4)?.comments))
        XCTAssertEqual(done, "✓ 11 · ↩ 2 · \(Status.keptAsIs.glyph) 1")
        for w in Self.widths {
            let s = MapScene.build(MapInput(data: dm, width: w))
            for n in [4, 3] {
                let texts = try XCTUnwrap(s.rows.first { $0.n == n }).readout.map(\.text)
                XCTAssertTrue(texts.contains(done) || texts.contains(done + " so far"), "Round \(n) at \(w): \(texts)")
            }
        }
        XCTAssertNil(MapMotion.animation(reduceMotion: true), "Reduce Motion: it jumps")
        XCTAssertEqual(MapMotion.animation(reduceMotion: false), .timingCurve(0.3, 0.7, 0.2, 1, duration: 0.28))
    }

    func testHelpTags() throws {
        let d = try Self.kelp()
        let cell = MapHelp.lines(.cell("methods", round: 2), d, student: "Tomás")
        XCTAssertEqual(cell.first, "3 Methods · Round 2")
        XCTAssertTrue(cell.contains { $0.contains("merged") }, "two sections of Round 1 became it")
        let band = MapHelp.lines(.band(from: "study-area", to: "methods", round: 2), d, student: "Tomás")
        XCTAssertEqual(band.first, "3 Study area → 3 Methods · Round 1 → 2")
        XCTAssertEqual(band[1], "Merged: 4 of its 4 paragraphs now sit in 3 Methods")
        let removed = MapHelp.lines(.band(from: "extra", to: nil, round: 4), d, student: "")
        XCTAssertEqual(removed.last, "Removed: none of its paragraphs are in Round 4.")
        XCTAssertTrue(MapHelp.lines(.round(1), d, student: "Tomás").contains { $0.hasSuffix("words") })
        // UI v4: the round's tag carries what its label and the readout leave out: its return, new comments, the
        // student's responses (in the response bar's words), your answers, and its body's words in every round
        let r4 = MapHelp.lines(.round(4), d, student: "Tomás")
        XCTAssertEqual(r4[0], "Round 4 · " + OverviewText.dates(d.round(4)?.created, nil))
        XCTAssertTrue(r4.contains("Tomás: 3 revised, 3 unchanged, 6 not asked"), "\(r4)")
        XCTAssertTrue(r4.contains("You: ✓ 2 so far · ○ 10 to check"), "\(r4)")
        XCTAssertTrue(r4.contains { $0.hasPrefix("12 comments, 0 new") }, "\(r4)")
        if d.round(4)?.words?.body != nil { XCTAssertTrue(r4.contains { $0.contains(" words · +") }, "\(r4)") }
        let r3 = MapHelp.lines(.round(3), d, student: "Tomás")
        XCTAssertEqual(r3[0], "Round 3 · " + OverviewText.dates(d.round(3)?.created, d.round(3)?.closedAt), "a closed round's return too")
        let edit = try XCTUnwrap(d.round(4)?.edits?.first { $0.toCheck })
        XCTAssertTrue(MapHelp.lines(.edit(edit.id, round: 4), d, student: "").contains("○ to check"))
    }

    // MARK: The view

    /// The map's own click, as the mouse sends it (down and up to the view under the point): it follows the cell under
    /// it; the readout follows its round; a click on empty map follows nothing; a second click on the same cell opens
    /// Review there (`PaperMapView`).
    @MainActor
    func testAClickOnTheMapFollowsWhatIsUnderIt() throws {
        _ = NSApplication.shared
        let drafts = FileManager.default.temporaryDirectory.appendingPathComponent("pc-map-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: drafts) }
        var o = LaunchOptions()
        o.fixture = StepTests.fixtures.appendingPathComponent("state-m2a.json").path
        o.overviewFixture = OverviewDataTests.fixture.path
        o.level = .overview
        o.drafts = drafts.path
        o.cache = drafts.appendingPathComponent("cache").path
        let m = AppModel(options: o)
        let d = try XCTUnwrap(m.overview.data)
        let scene = MapScene.build(MapInput(data: d, width: 900))
        let host = NSHostingView(rootView: PaperMapView(model: m, overview: m.overview, hover: m.overview.hover, scene: scene, data: d, student: "Lin"))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: scene.height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        func click(_ p: CGPoint, count: Int = 1) {
            let q = NSPoint(x: p.x, y: scene.height - p.y)  // the window's points are from the bottom
            func event(_ type: NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: q, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1)!
            }
            let target = window.contentView?.superview?.hitTest(q)
            target?.mouseDown(with: event(.leftMouseDown))
            target?.mouseUp(with: event(.leftMouseUp))
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        let cell = try XCTUnwrap(scene.rows.first?.cells.first { $0.section == "design" })
        click(CGPoint(x: cell.rect.midX, y: cell.rect.midY))
        XCTAssertEqual(m.overview.selection, .section("design", round: 2))
        click(CGPoint(x: scene.geometry.readoutX + 10, y: scene.rows[1].y + 12))
        XCTAssertEqual(m.overview.selection, .round(1))
        click(CGPoint(x: scene.geometry.mapRight - 4, y: 4))
        XCTAssertNil(m.overview.selection, "the empty lens: nothing")
        XCTAssertEqual(m.level, .overview)
        click(CGPoint(x: cell.rect.midX, y: cell.rect.midY))
        click(CGPoint(x: cell.rect.midX, y: cell.rect.midY), count: 2)
        XCTAssertEqual(m.level, .review, "a double click opens Review there")
        window.close()
    }

    /// A test run's own thumbnails folder, and a list of only its own papers (screenshots without the user's list).
    func testTheTestRunOptions() {
        let o = LaunchOptions.parse(["Paperole", "--paper", "/a", "--no-list", "--cache", "/tmp/thumbs"])
        XCTAssertTrue(o.noList)
        XCTAssertEqual(o.cache, "/tmp/thumbs")
        XCTAssertEqual(o.paper, "/a")
        XCTAssertFalse(LaunchOptions.parse(["Paperole"]).noList)
    }

    // MARK: Thumbnails

    @MainActor
    func testThumbnailsAreCachedPerPaperAndCleared() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-thumbs-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // a two-page PDF of the app's own drawing
        let pdf = dir.appendingPathComponent("main.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = try XCTUnwrap(CGContext(pdf as CFURL, mediaBox: &box, nil))
        for i in 0..<2 {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(CGColor(gray: CGFloat(i) * 0.5, alpha: 1))
            ctx.fill(CGRect(x: 72, y: 600, width: 300, height: 100))
            ctx.endPDFPage()
        }
        ctx.closePDF()
        let store = ThumbnailStore(root: dir.appendingPathComponent("cache"))
        XCTAssertEqual(store.aspect(pdf: pdf.path), 612 / 792, accuracy: 0.001)
        XCTAssertEqual(store.pageSize(pdf: pdf.path, page: 1), CGSize(width: 612, height: 792))
        XCTAssertNil(store.image(paper: "/papers/a", pdf: pdf.path, page: 1, height: 72), "drawn off the main thread")
        await store.flush()
        for _ in 0..<50 where store.image(paper: "/papers/a", pdf: pdf.path, page: 1, height: 72) == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let image = try XCTUnwrap(store.image(paper: "/papers/a", pdf: pdf.path, page: 1, height: 72))
        XCTAssertEqual(image.size.height, 80, "160 px at 2×")
        let folder = store.folder(paper: "/papers/a")
        XCTAssertEqual(folder.lastPathComponent, ThumbnailStore.hash("/papers/a"), "named by a hash of the paper's path")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].hasSuffix("-p1-160.png"))
        // a second store finds it in the folder
        let again = ThumbnailStore(root: dir.appendingPathComponent("cache"))
        _ = again.image(paper: "/papers/a", pdf: pdf.path, page: 1, height: 72)
        await again.flush()
        // Remove from List clears it
        store.clear(paper: "/papers/a")
        await store.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertNil(store.image(paper: "/papers/a", pdf: "/no/such.pdf", page: 0, height: 72))
    }

    /// The Key (UI v4 Step 4): a row only for a mark on this map; as a table, its shades and ○.
    func testTheKeysRowsAreTheMarksOnTheMap() throws {
        let d = try Self.kelp()
        let s = MapScene.build(MapInput(data: d, width: 1300, student: "Tomás"))
        let rows = MapKeyRow.rows(s, d)
        let ticks = s.rows.flatMap(\.ticks)
        XCTAssertEqual(rows.contains(.revised), ticks.contains { !$0.unrequested })
        XCTAssertEqual(rows.contains(.unasked), ticks.contains(where: \.unrequested))
        XCTAssertEqual(rows.contains(.band), !s.bands.isEmpty)
        XCTAssertEqual(rows.contains(.folded), !s.plan.folded.isEmpty)
        XCTAssertTrue(rows.contains(.shades))
        XCTAssertTrue(rows.contains(.toCheck), "Round 4 is open with comments to check")
        XCTAssertEqual(rows, MapKeyRow.allCases.filter(rows.contains), "in the Key's order")
        XCTAssertEqual(MapKeyRow.rows(nil, d), [.shades, .toCheck], "the table: shades and ○")
        var one = d
        one.rounds = Array(d.rounds.prefix(1))
        let first = MapKeyRow.rows(MapScene.build(MapInput(data: one, width: 1300, student: "Tomás")), one)
        XCTAssertFalse(first.contains(.band), "one round: no band")
        XCTAssertFalse(first.contains(.revised) || first.contains(.unasked), "Round 1 has no edits")
        XCTAssertEqual(MapKeyRow.allCases.map(\.noun), ["Comments on a section", "To check", "Revised", "Unasked edit",
                                                       "Same section a round apart", "Folded part"])
    }

    func testThePagesToCheckAndTheFirstSentence() throws {
        let d = try Self.kelp()
        let r4 = try XCTUnwrap(d.round(4))
        let pages = PageStripView.pagesToCheck(r4, d)
        XCTAssertFalse(pages.isEmpty)
        XCTAssertTrue(PageStripView.pagesToCheck(d.round(3), d).isEmpty, "a closed round has nothing to check")
        XCTAssertEqual(OverviewText.errors([BuildError(file: "sections/methods.tex", line: 3, message: "x"),
                                            BuildError(file: "sections/methods.tex", line: 9, message: "y")]), "2 errors in methods.tex")
        XCTAssertNil(OverviewText.errors([]))
        XCTAssertEqual(OverviewText.firstSentence(nil, student: "Jonas Berg", fallback: [
            RoundSummary(n: 5, created: "2026-10-17T12:00:00+08:00", closed: false, status: "failed")], errors: "2 errors in methods.tex"),
                       "Round 5 came in on Sat, Oct 17 but did not build: 2 errors in methods.tex.")
    }
}
