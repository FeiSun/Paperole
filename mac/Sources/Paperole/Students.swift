import Foundation

/// The hierarchy's own pages (OVERVIEW-v2 §3.1–3.2; FEATURES OV-7–OV-9; UX.md §22): All Students, Your Move and a
/// student's page. A paper's own levels are its overview and Review (`Level`).
enum HubPage: Hashable {
    case allStudents, yourMove
    /// A student, by `StudentName.key`.
    case student(String)

    /// `--hub all|move|student:<name>`.
    init?(argument a: String) {
        switch a {
        case "all": self = .allStudents
        case "move": self = .yourMove
        default:
            guard a.hasPrefix("student:") else { return nil }
            self = .student(StudentName.key(String(a.dropFirst("student:".count))))
        }
    }
}

/// What the sidebar's list selects: a page of the hierarchy, or a paper (its overview or Review).
enum SidebarItem: Hashable {
    case allStudents, yourMove
    case student(String)
    case paper(String)
}

enum StudentName {
    /// The engine's grouping (`overview.fold`): compatibility forms, case and all white space ignored, so "Mei Lin",
    /// "mei  lin" and "MeiLin" are one student. "" for a paper without a student (Unassigned).
    static func key(_ name: String) -> String {
        name.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .filter { !$0.isWhitespace }
    }

    /// The name as shown: white space collapsed (as `edit_paper` stores it).
    static func shown(_ name: String) -> String { name.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    /// "ML" for Mei Lin, "TR" for Tomás Ruiz, "P" for a one-word name.
    static func initials(_ name: String) -> String {
        String(shown(name).split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
    }
}

/// Whose move a paper is (OVERVIEW-v2 §8 decision 10: it waits on you while a round is open, a failed build included,
/// and nowhere else), from its summary and the app's own Finished mark (FEATURES OV-7).
enum PaperStatus: Equatable {
    case noRounds
    /// Round 1 is open: the first draft, yours to comment.
    case firstDraft
    /// Carried comments without an answer and edits nobody asked for, still to check.
    case toCheck(comments: Int, edits: Int)
    /// The open paper's changed paragraphs to read (reading marks on), nothing else left.
    case toRead(Int)
    /// Nothing left: Finish Round N.
    case ready
    case failed
    /// The latest round is closed: with the student.
    case waiting
    /// Marked finished by the advisor on that day ("2026-07-20"), its latest round closed.
    case finished(String)

    static func of(_ s: PaperSummary?, finished: String?) -> PaperStatus? {
        guard let s else { return nil }
        switch s.step {
        case .noRounds: return .noRounds
        case .buildFailed: return .failed
        case .waiting: return finished.map { .finished($0) } ?? .waiting
        case .toCheck: return .toCheck(comments: s.toJudge, edits: s.toCheck)
        case .toRead(let n): return .toRead(n)
        case .open: return .firstDraft
        case .allChecked: return .ready
        }
    }

    /// The paper waits on you: a round is open (decision 10), to review, to finish, or a failed build.
    var yourMove: Bool {
        switch self {
        case .firstDraft, .toCheck, .toRead, .ready, .failed: return true
        case .noRounds, .waiting, .finished: return false
        }
    }

    var isFinished: Bool { if case .finished = self { return true } else { return false } }

    /// The sidebar's badge: the comments and edits to check (as the papers list counted them).
    var badge: Int? {
        if case .toCheck(let c, let e) = self, c + e > 0 { return c + e }
        return nil
    }
}

/// The papers of one student in the sidebar and on the hierarchy's pages: grouped by the name as the engine groups
/// them (`StudentName.key`), named as the first listed paper spells it.
struct StudentGroup: Equatable, Identifiable {
    var key: String
    var name: String
    var papers: [PaperRef]
    var id: String { key }
    var unassigned: Bool { key.isEmpty }
}

/// A paper that waits on you (Your Move): its status, its latest round and when that came in.
struct MoveItem: Equatable, Identifiable {
    var paper: PaperRef
    var status: PaperStatus
    var round: Int?
    /// The latest round's import (`created`), ISO 8601; nil without the overview.
    var imported: String?
    var id: String { paper.path }
}

enum Hierarchy {
    /// The students, by name (Unassigned last), each with its papers in the list's order and the finished ones after
    /// the others, greyed (FEATURES OV-7: "完成的论文灰色留在学生下面").
    static func groups(_ papers: [PaperRef], status: (PaperRef) -> PaperStatus?) -> [StudentGroup] {
        var order: [String] = [], byKey: [String: StudentGroup] = [:]
        for p in papers {
            let k = StudentName.key(p.student)
            if byKey[k] == nil {
                order.append(k)
                byKey[k] = StudentGroup(key: k, name: k.isEmpty ? "Unassigned" : StudentName.shown(p.student), papers: [])
            }
            byKey[k]?.papers.append(p)
        }
        var out = order.compactMap { byKey[$0] }
        for i in out.indices {
            let ps = out[i].papers
            out[i].papers = ps.filter { status($0)?.isFinished != true } + ps.filter { status($0)?.isFinished == true }
        }
        return out.filter { !$0.unassigned }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            + out.filter(\.unassigned)
    }

    /// The papers that wait on you, the earliest import first (FEATURES OV-8: "最早来的在前"); those without a date
    /// after them, in the list's order. The round from the overview, else from the papers list's `summaries` (before
    /// the hierarchy's data comes, or for good when a paper's overview failed: the review, "Finish Round 0…").
    static func yourMove(_ papers: [PaperRef], status: (PaperRef) -> PaperStatus?, data: [String: PaperOverview],
                         summaries: [String: PaperSummary] = [:]) -> [MoveItem] {
        let items = papers.compactMap { p -> (item: MoveItem, date: Date?)? in
            guard let s = status(p), s.yourMove else { return nil }
            let latest = data[p.path]?.latest
            return (MoveItem(paper: p, status: s, round: latest?.n ?? summaries[p.path]?.round, imported: latest?.created),
                    date(latest?.created))
        }
        // each date read once, not twice per comparison (the code audit: the sidebar sorts at every redraw)
        return items.enumerated().sorted { a, b in
            switch (a.element.date, b.element.date) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map(\.element.item)
    }

    /// An engine time ("2026-10-16T09:30:00+08:00"), with one formatter made once (a new one cost about 0.1 ms).
    static func date(_ iso: String?) -> Date? {
        guard let iso else { return nil }
        return isoFormatter.date(from: iso)
    }

    private static let isoFormatter = ISO8601DateFormatter()
}

/// The hierarchy's words (OVERVIEW-v2 §3.1–3.2, the mockup's `statusLine`, `studentView`; UI v4's), in English as the
/// rest of the app: the student by first name, no pronoun (UX.md §12), each number said once.
enum HubText {
    static let posix = Locale(identifier: "en_US_POSIX")

    static func format(_ d: Date, _ f: String, _ tz: TimeZone = .current) -> String {
        formatter(f, tz).string(from: d)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var formatters: [String: DateFormatter] = [:]

    /// The formatter for `f` in `tz` (en_US_POSIX), made once for each (the code audit: a new DateFormatter cost
    /// about 0.1 ms, and the pages and the sidebar ask for dates at every redraw).
    static func formatter(_ f: String, _ tz: TimeZone = .current) -> DateFormatter {
        let key = f + "|" + tz.identifier
        lock.lock()
        defer { lock.unlock() }
        if let df = formatters[key] { return df }
        let df = DateFormatter()
        df.locale = posix
        df.timeZone = tz
        df.dateFormat = f
        formatters[key] = df
        return df
    }

    /// "Jul 20" from "2026-07-20" (the Finished mark) or an engine time.
    static func day(_ s: String?) -> String? {
        guard let s else { return nil }
        if let d = Hierarchy.date(s) { return format(d, "MMM d") }
        return formatter("yyyy-MM-dd").date(from: s).map { format($0, "MMM d") }
    }

    /// "4 papers wait on you", "1 paper waits on you", "Nothing waits on you": one definition everywhere
    /// (decision 10), so the sidebar's Your Move, All Students and Your Move say the same number.
    static func waits(_ n: Int) -> String {
        n == 0 ? "Nothing waits on you" : n == 1 ? "1 paper waits on you" : "\(n) papers wait on you"
    }

    /// The status line of a paper on the hierarchy's pages (the mockup's `statusLine`): "Round 4 · 7 comments and 2
    /// edits to check", "Round 3 · ready to finish", "Round 5 · build failed", "With Priya · 6 d" (UI v4: the days since
    /// it went back; the date is the line's hover), "Finished Jul 20".
    static func status(_ s: PaperStatus, round n: Int?, student: String, since: String?,
                       today: Date = Date(), calendar: Calendar = .current) -> String {
        let r = n.map { "Round \($0) · " } ?? ""
        switch s {
        case .noRounds: return "No rounds yet"
        case .firstDraft: return r + "first draft, in progress"
        case .toCheck(let c, let e):
            let parts = [c > 0 ? count(c, "comment") : nil, e > 0 ? count(e, "edit") : nil].compactMap { $0 }
            return r + parts.joined(separator: " and ") + " to check"
        case .toRead(let u): return r + count(u, "changed paragraph") + " to read"
        case .ready: return r + "ready to finish"
        case .failed: return r + "build failed"
        case .waiting:
            let name = OverviewText.firstName(student)
            return "With " + (name.isEmpty ? "the student" : name)
                + (Hierarchy.date(since).map { " · " + dayCounter($0, today: today, calendar: calendar) } ?? "")
        case .finished(let d): return "Finished" + (day(d).map { " " + $0 } ?? "")
        }
    }

    /// "a, b and c".
    static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items.last!
    }

    // UI v4's words (design/ui-v4/BRIEF §3, §5; plan §2): the to-check figure, the badge, day counters and hovers.

    /// The to-check figure's words: "14 comments + 2 edits", "3 comments", "1 comment", "2 edits".
    static func figure(_ c: Int, _ e: Int) -> String {
        let edits = count(e, "edit")
        return c == 0 ? edits : count(c, "comment") + (e > 0 ? " + " + edits : "")
    }

    /// The sidebar's badge: "14 + 2", "3", "+ 2".
    static func badge(_ c: Int, _ e: Int) -> String {
        c == 0 ? "+ \(e)" : e > 0 ? "\(c) + \(e)" : "\(c)"
    }

    /// Calendar days from `from` to `today`, each on its own date in the calendar's time zone (0 for a later `from`).
    static func dayCount(_ from: Date, today: Date, calendar: Calendar = .current) -> Int {
        max(0, calendar.dateComponents([.day], from: calendar.startOfDay(for: from), to: calendar.startOfDay(for: today)).day ?? 0)
    }

    /// A card corner's counter: "2 d", "today".
    static func dayCounter(_ from: Date, today: Date, calendar: Calendar = .current) -> String {
        let n = dayCount(from, today: today, calendar: calendar)
        return n == 0 ? "today" : "\(n) d"
    }

    /// Your Move's Waiting: "2 days", "1 day", "today".
    static func days(_ from: Date, today: Date, calendar: Calendar = .current) -> String {
        let n = dayCount(from, today: today, calendar: calendar)
        return n == 0 ? "today" : count(n, "day")
    }

    /// "came in 2 days ago", "came in 1 day ago", "came in today".
    static func cameIn(_ created: Date, today: Date, calendar: Calendar = .current) -> String {
        let n = dayCount(created, today: today, calendar: calendar)
        return "came in " + (n == 0 ? "today" : count(n, "day") + " ago")
    }

    /// "Came in Wed, Oct 28".
    static func hoverCameIn(_ created: Date, calendar: Calendar = .current) -> String {
        "Came in " + format(created, "EEE, MMM d", calendar.timeZone)
    }

    /// "Sent back Sat, Oct 24"; with a round, "Round 1 sent back Sat, Oct 24".
    static func hoverSentBack(_ closed: Date, round: Int? = nil, calendar: Calendar = .current) -> String {
        (round.map { "Round \($0) sent back " } ?? "Sent back ") + format(closed, "EEE, MMM d", calendar.timeZone)
    }

    /// A finished paper's line: "2 rounds · 12 of 16 closed" (closed: resolved and kept as is).
    static func finishedLine(rounds: Int, closed: Int, of comments: Int) -> String {
        count(rounds, "round") + " · \(closed) of \(comments) closed"
    }

    /// The ring's hover once something is answered: "6 of 16 answered so far".
    static func answeredSoFar(_ done: Int, of total: Int) -> String { "\(done) of \(total) answered so far" }

    /// All Students' numbers, the help of its Board | Students control (plan §5 R12): "3 students · 4 papers · 9 rounds".
    static func allCounts(students: Int, papers: Int, rounds: Int) -> String {
        [count(students, "student"), count(papers, "paper"), count(rounds, "round")].joined(separator: " · ")
    }

    /// "3 to review or finish · 1 build failed" (the old subtitle's numbers): the help of Your move's lane head and of
    /// Your Move's title.
    static func waitsDetail(review: Int, failed: Int) -> String {
        [review > 0 ? "\(review) to review or finish" : nil, failed > 0 ? count(failed, "build") + " failed" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// "5 rounds came in this week" (the old lede's count; the last seven days): the timeline title's help.
    static func cameThisWeek(_ data: [PaperOverview], today: Date, calendar: Calendar = .current) -> String {
        let from = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -6, to: today) ?? today)
        let n = data.flatMap(\.rounds).compactMap { Hierarchy.date($0.created) }.filter { $0 >= from && $0 <= today }.count
        return n == 0 ? "No rounds came in this week" : count(n, "round") + " came in this week"
    }

}

// MARK: - The engine's `students`

/// One student's numbers for the Student page (CONTRACT amendment "Overview": `students`): where the comments land
/// (each once, where it was written), the round trips' days, and how the comments closed.
struct StudentStats: Decodable, Equatable {
    struct Column: Decodable, Equatable {
        var bucket: String?
        var title: String
    }

    struct LandRow: Decodable, Equatable {
        var path: String
        var counts: [Int]
    }

    struct Land: Decodable, Equatable {
        var columns: [Column] = []
        var papers: [LandRow] = []
        var total: [Int] = []
    }

    /// A round trip: `you` from the round's import to its close (to today while open), `student` from the close to
    /// the next round's import, `received` to when the student's files last changed (null for older rounds).
    struct Trip: Decodable, Equatable {
        var path: String
        var round: Int
        var next: Int?
        var open: Bool
        var you: Int?
        var student: Int?
        var received: Int?
        /// The open row of a round whose build failed (with you all the same, decision 10).
        var failed: Bool?
        /// A closed last round (CONTRACT amendment "UI v4 data"): `student` is the days so far, nil once finished.
        var last: Bool?
    }

    /// How the comments closed: after 1, 2 or 3+ rounds you answered in, still open, followed up, untouched after a
    /// follow-up.
    struct Closed: Decodable, Equatable {
        var path: String?
        var one = 0, two = 0, three = 0, open = 0, followedUp = 0, untouchedAfterFollowUp = 0

        init(path: String? = nil) { self.path = path }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            path = try c.decodeIfPresent(String.self, forKey: .path)
            func n(_ k: Keys) throws -> Int { try c.decodeIfPresent(Int.self, forKey: k) ?? 0 }
            one = try n(.one); two = try n(.two); three = try n(.three); open = try n(.open)
            followedUp = try n(.followedUp); untouchedAfterFollowUp = try n(.untouchedAfterFollowUp)
        }

        enum Keys: String, CodingKey {
            case path, open, followedUp, untouchedAfterFollowUp
            case one = "1", two = "2", three = "3+"
        }

        var values: [Int] { [one, two, three, open, followedUp] }
    }

    struct ClosedTable: Decodable, Equatable {
        var papers: [Closed] = []
        var total = Closed()
    }

    var student: String
    var papers: [String]
    var rounds: Int?
    var comments: Int?
    var land: Land?
    var time: [Trip]?
    var closed: ClosedTable?
    /// The writing profile from the tags (`tags.student_tags`); nil from an engine before tags.
    var tags: StudentTags?
}

// MARK: - Small maps and the timeline (pure geometry)

/// A paper's small map (OVERVIEW-v2 §3.1, the mockup's `miniMapSVG`; VISUAL v3 §6.2): one row per round, newest on
/// top, each section where it is in that round and shaded like the paper's map (its own three steps, `MapShade`), the
/// round's comments in its help tag; no numbers in the cells and no bands (in rows this small they are only stripes: the
/// structure is the paper page's). A long appendix (and a long References list) folds as on the paper map, decided once
/// for the paper: a block exactly two pages wide (one and a half for References), shaded by its busiest section.
struct MiniMap: Equatable {
    struct Cell: Equatable {
        /// In the map's own pages: past a folded block, everything moves up by what it saved.
        var start: Double
        var end: Double
        var level: Int
        var block = false
    }

    struct Row: Equatable {
        var n: Int
        var cells: [Cell]
        /// The round's length in the map's pages.
        var pages: Double
        /// The round's comments (written and carried); nil for a failed build ("–").
        var count: Int?
        var failed = false
        /// No sections known yet (§5.5): the row is drawn as plain pages.
        var plain = false
    }

    var rows: [Row]
    /// The longest round's pages (folded): one page scale for every row.
    var pages: Double
    /// The oldest rounds, folded into one last row ("R1–2") when there are more than the rows it has room for: never
    /// left out without a sign (review 2026-10-19).
    var folded: ClosedRange<Int>?

    /// `fold`: Settings' folding (the paper map's rule, at the small maps' fixed block widths).
    static func make(_ d: PaperOverview, maxRows: Int = 9, fold: Bool = true) -> MiniMap {
        let steps = MapShade.steps(MapShade.counts(d))
        let all = Array(d.rounds.reversed())
        let foldRows = all.count > max(2, maxRows)
        let shown = foldRows ? Array(all.prefix(max(2, maxRows) - 1)) : all
        let folded = foldRows ? all.last.flatMap { lo in all.dropFirst(shown.count).first.map { lo.n...$0.n } } : nil
        // the parts the paper folds: longer than their threshold in the round where they are longest
        let sectioned = d.rounds.filter { $0.hasSections && !$0.failed }
        let parts: [FoldKind] = fold ? FoldKind.allCases.filter { k in
            (sectioned.compactMap { MapFold.range(k, $0)?.length }.max() ?? 0) > k.longerThan
        } : []
        var rows: [Row] = []
        for r in shown {
            let heat = Dictionary((r.heat ?? []).map { ($0.section, $0.present) }, uniquingKeysWith: { a, _ in a })
            let pages = Double(r.build?.pages ?? 0)
            var row = Row(n: r.n, cells: [], pages: pages, count: r.failed ? nil : r.comments?.present, failed: r.failed)
            if r.hasSections {
                let spans = r.spans ?? []
                let ranges = MapFold.ranges(spans).filter { parts.contains($0.kind) }
                var shift = 0.0
                for (i, sp) in spans.enumerated() {
                    if let f = ranges.first(where: { $0.spans.contains(i) }) {
                        guard i == f.spans.lowerBound else { continue }
                        let busiest = spans[f.spans].map { heat[$0.section] ?? 0 }.max() ?? 0
                        row.cells.append(Cell(start: f.start - shift, end: f.start - shift + f.kind.pages,
                                              level: MapShade.level(busiest, steps), block: true))
                        shift += f.length - f.kind.pages
                        continue
                    }
                    row.cells.append(Cell(start: sp.start - shift, end: sp.end - shift, level: MapShade.level(heat[sp.section] ?? 0, steps)))
                }
                row.pages = pages - shift
            } else if !r.failed {
                row.plain = true
            }
            rows.append(row)
        }
        let most = max(1, rows.map(\.pages).max() ?? 1)
        return MiniMap(rows: rows, pages: most, folded: folded)
    }

    /// The cells as drawn at `k` pt per page: neighbouring empty cells each narrower than 6 pt join into one quiet
    /// stretch (VISUAL §6.2): (start, end, level) of each piece drawn.
    static func runs(_ cells: [Cell], k: CGFloat) -> [(Double, Double, Int)] {
        var out: [(Double, Double, Int)] = []
        var run: (Double, Double)?
        func flush() {
            if let r = run { out.append((r.0, r.1, 0)) }
            run = nil
        }
        for c in cells {
            let narrow = !c.block && c.level == 0 && CGFloat(c.end - c.start) * k < 6
            if narrow, let r = run, abs(r.1 - c.start) < 0.01 {
                run = (r.0, c.end)
                continue
            }
            flush()
            if narrow { run = (c.start, c.end) } else { out.append((c.start, c.end, c.level)) }
        }
        flush()
        return out
    }
}

/// All Students' "Rounds in 2026" (UI v4, BRIEF §8.2, mockup `timeline()`): one lane per paper, a dot at each round's
/// arrival, a line while it is with you and a dotted one while it is with the student; a paper that waits on you has
/// the vermilion stretch from its last arrival to today (`open`), one ready to finish an ink line; a failed build its
/// octagon, a finished paper its checkmark after its last point. No round numbers on the plot: each lane's hover gives
/// its rounds' dates. Days are calendar days from `start`.
struct Timeline: Equatable {
    enum Kind: Equatable { case imported, yourMove, ready, failed }

    struct Mark: Equatable {
        var day: Double
        var n: Int
        var kind: Kind
    }

    struct Lane: Equatable {
        var path: String
        var title: String
        /// The lane's label (`ShortTitle`); the full title is in `hover`.
        var short: String
        var you: [ClosedRange<Double>] = []
        var student: [ClosedRange<Double>] = []
        var marks: [Mark] = []
        /// The open round that waits on you, from its arrival to today: the vermilion stretch.
        var open: ClosedRange<Double>?
        var finished: Double?
        /// "Easy Before Hard: … · Round 2 came in Oct 28 · Round 1 Oct 14 – Oct 16", newest first.
        var hover = ""
    }

    var start: Date
    var days: Double
    var today: Double
    /// Month starts: their abbreviation and day.
    var months: [(String, Double)]
    var lanes: [Lane]
    var title: String

    static func == (a: Timeline, b: Timeline) -> Bool {
        a.start == b.start && a.days == b.days && a.today == b.today && a.lanes == b.lanes && a.title == b.title
            && a.months.map(\.0) == b.months.map(\.0) && a.months.map(\.1) == b.months.map(\.1)
    }

    static func make(_ rows: [(paper: PaperRef, status: PaperStatus?, data: PaperOverview?)], today now: Date,
                     calendar cal: Calendar = .current) -> Timeline? {
        let dated = rows.filter { !($0.data?.rounds.isEmpty ?? true) }
        let firsts = dated.compactMap { Hierarchy.date($0.data?.rounds.first?.created) }
        guard let earliest = firsts.min() else { return nil }
        let today = cal.startOfDay(for: now)
        // the first round's month (UI v4, BRIEF §4 05: no three-month minimum)
        var startC = cal.dateComponents([.year, .month], from: earliest)
        startC.day = 1
        let start = cal.date(from: startC) ?? earliest
        let endMonth = cal.date(byAdding: .month, value: 1, to: cal.date(from: cal.dateComponents([.year, .month], from: today)) ?? today) ?? today
        func day(_ d: Date) -> Double { Double(cal.dateComponents([.day], from: start, to: cal.startOfDay(for: d)).day ?? 0) }
        func day(_ iso: String?) -> Double? { Hierarchy.date(iso).map(day) }
        func shown(_ iso: String?) -> String { Hierarchy.date(iso).map { HubText.format($0, "MMM d", cal.timeZone) } ?? "–" }
        var months: [(String, Double)] = []
        var m = start
        while m < endMonth {
            months.append((HubText.format(m, "MMM", cal.timeZone), day(m)))
            m = cal.date(byAdding: .month, value: 1, to: m) ?? endMonth
        }
        let t = day(today)
        var lanes: [Lane] = []
        for r in dated {
            guard let d = r.data else { continue }
            var lane = Lane(path: r.paper.path, title: r.paper.title, short: ShortTitle.of(r.paper.title))
            var done: String?, dates: [String] = []
            if case .finished(let f)? = r.status {
                let date = HubText.formatter("yyyy-MM-dd", cal.timeZone).date(from: f)
                lane.finished = date.map(day)
                done = date.map { "Finished " + HubText.format($0, "MMM d", cal.timeZone) }
            }
            for (i, round) in d.rounds.enumerated() {
                dates.append("Round \(round.n) " + (round.failed ? "came in \(shown(round.created)), build failed"
                                                     : round.isClosed ? shown(round.created) + " – " + shown(round.closedAt)
                                                     : "came in " + shown(round.created)))
                guard let a = day(round.created) else { continue }
                let next = d.rounds.indices.contains(i + 1) ? day(d.rounds[i + 1].created) : nil
                if round.failed {
                    lane.marks.append(Mark(day: a, n: round.n, kind: .failed))
                    continue
                }
                if round.isClosed, let c = day(round.closedAt) {
                    lane.you.append(a...max(a, c))
                    let end = next ?? lane.finished ?? t
                    if end > c { lane.student.append(c...end) }
                    lane.marks.append(Mark(day: a, n: round.n, kind: .imported))
                } else if r.status == .ready {
                    lane.you.append(a...max(a, t))
                    lane.marks.append(Mark(day: a, n: round.n, kind: .ready))
                } else {
                    lane.open = a...max(a, t)
                    lane.marks.append(Mark(day: a, n: round.n, kind: .yourMove))
                }
            }
            lane.hover = ([r.paper.title, done].compactMap { $0 } + dates.reversed()).filter { !$0.isEmpty }.joined(separator: " · ")
            lanes.append(lane)
        }
        // "Rounds in 2026" while every round and today are in one year, else "Rounds since Sep 2025"
        let years = Set(lanes.flatMap(\.marks).map { cal.component(.year, from: cal.date(byAdding: .day, value: Int($0.day), to: start) ?? start) }
                        + [cal.component(.year, from: today)])
        let title = years.count == 1 ? "Rounds in \(years.first ?? 0)" : "Rounds since " + HubText.format(start, "MMM yyyy", cal.timeZone)
        return Timeline(start: start, days: max(1, day(endMonth)), today: t, months: months, lanes: lanes, title: title)
    }
}

/// Where the comments land's columns as they fit (OVERVIEW-v2 §3.2; FEATURES OV-9: a heading not matched to a
/// standard section keeps a column of its own name): the standard sections first, then the others while they fit, the
/// rest added up in one "Other" column whose help tag names them.
struct LandColumns: Equatable {
    var titles: [String]
    /// Each paper's counts and the total row, in the columns' order.
    var rows: [[Int]]
    var total: [Int]
    /// "Ethical considerations 2 · References 1": what "Other" holds; nil without it.
    var other: String?

    static func fit(_ land: StudentStats.Land, most: Int) -> LandColumns {
        let n = land.columns.count
        let all = LandColumns(titles: land.columns.map(\.title), rows: land.papers.map(\.counts), total: land.total)
        guard n > most, most >= 2 else { return all }
        let standard = land.columns.indices.filter { land.columns[$0].bucket != nil }
        let own = land.columns.indices.filter { land.columns[$0].bucket == nil }
        let keep = standard + own.prefix(max(0, most - standard.count - 1))
        let rest = own.filter { !keep.contains($0) }
        func pick(_ v: [Int]) -> [Int] {
            keep.map { v.indices.contains($0) ? v[$0] : 0 } + [rest.map { v.indices.contains($0) ? v[$0] : 0 }.reduce(0, +)]
        }
        let other = rest.map { "\(land.columns[$0].title) \(land.total.indices.contains($0) ? land.total[$0] : 0)" }.joined(separator: " · ")
        return LandColumns(titles: keep.map { land.columns[$0].title } + ["Other"], rows: land.papers.map { pick($0.counts) },
                           total: pick(land.total), other: other)
    }
}
