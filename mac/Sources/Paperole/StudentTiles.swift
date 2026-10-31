import SwiftUI

// The student page's tiles (UI v4 step 6; design/ui-v4 BRIEF §4 01/02, mockup `tile`, `bySection`, `closing`, `trips`,
// `topics`, `nextDraft`; mac/UX.md §40.5): By section | Closing, Topics | Turnaround (the left column about the writing,
// the right about the rounds), First drafts when it says more than Topics, and For the next draft across the page. A tile
// with nothing to show is left out. Every number of the old boxes is in a tile, its hover or a popover; their captions
// and footnotes are Help's (`HelpText.studentPage`).

/// What the tiles show, decided from the data alone (tested without views).
struct StudentTiles: Equatable {
    enum Kind: String, CaseIterable {
        case bySection, closing, topics, turnaround, firstDrafts

        /// Its row in Help › The Student Page (About This Chart).
        var helpSection: String {
            switch self {
            case .bySection: return "By section"
            case .closing: return "Closing"
            case .topics: return "Topics"
            case .turnaround: return "Turnaround"
            case .firstDrafts: return "First drafts"
            }
        }
    }

    /// A tile's headline: its figure (17 semibold) and words (13 secondary), "Results" "12 of 30".
    struct Headline: Equatable {
        var key: String
        var words: String
        var help: String?
    }

    /// By section (mockup `bySection`): each paper's comments over the standard sections, each once where it was
    /// written (the engine's `land`, with the advisor's Map Headings answers).
    struct BySection: Equatable {
        struct Row: Equatable {
            var path: String
            var name: String
            var title: String
            var counts: [Int]
        }

        /// The columns' heads ("Intro.") and their help: the column's name, then the headings mapped into it.
        var heads: [String]
        var headHelp: [String]
        var rows: [Row]
        /// Each comment once over the papers; only with more than one paper.
        var all: [Int]?
        /// The column with the most comments (the first on a tie): its head and All value in the label colour.
        var lead: Int?
        /// The paper map's steps over the table's cells (`MapShade`).
        var steps: [Int]
        var headline: Headline?
        /// Rounds whose sections the engine is still finding.
        var pending: Int
    }

    /// Closing (mockup `closing`): the comments closed in 1, 2 or 3+ rounds you answered in, then the open ones split
    /// into those to check now and those still open (BRIEF §0.3).
    struct ClosingTile: Equatable {
        struct Row: Equatable {
            var name: String
            var value: Int
            /// The per-paper split and the facts the old box printed.
            var help: String?
        }

        /// In 1 round, In 2 rounds, In 3 or more, To check, Still open.
        var rows: [Row]
        var headline: Headline
    }

    /// Turnaround (mockup `trips`): each round trip's days with you, then with the student, newest first in each paper.
    struct TurnaroundTile: Equatable {
        struct Row: Equatable {
            var path: String
            /// The paper's short name on its first row, with more than one paper.
            var name: String?
            var round: Int
            var you: Int?
            var student: Int?
            /// A stretch still running: yours (the round is open) or the student's (a closed last round).
            var openYou = false
            var openStudent = false
            var failed = false
            /// Its dates (D7): "Curriculum Signals · Round 1 Sep 8 · back Sep 11 · Round 2 Sep 21".
            var help: String
        }

        /// The student's first name, the column's head.
        var who: String
        var you: Turnaround.Median?
        var student: Turnaround.Median?
        var rows: [Row]
        /// The medians' exact values and how many trips they come from.
        var help: String?
    }

    /// Topics (mockup `topics`): each topic's comments per paper on one scale, by count, Not tagged last; Well done is
    /// the header's ★.
    struct TopicsTile: Equatable {
        struct Row: Equatable {
            var id: String
            var name: String
            var counts: [Int]
            var all: Int
            var untagged = false
            /// The topic's definition and the facts about it (the old lede's).
            var nameHelp: String
            /// "R1 3 · R2 –" for each paper.
            var cellHelp: [String]
            /// "9 comments · 4 open".
            var allHelp: String
        }

        var papers: [String]
        /// The papers' short names, only with more than one paper; their help the title, the new comments by round and,
        /// while First drafts is hidden, the first draft's pages.
        var heads: [String]
        var headHelp: [String]
        var rows: [Row]
        var headline: Headline
        /// Comments without a tag (Tag N Comments…).
        var untagged: Int
    }

    /// For the next draft (mockup `nextDraft`): a topic still happening, the advisor's line for it and the student's
    /// own sentence.
    struct NextItem: Equatable {
        var tag: String
        var name: String
        var open: Int?
        var line: String?
        var sentence: String?
        /// "Easy Before Hard p.2".
        var source: String?
        /// "5 comments · 1 needed a follow-up", the advisor's note and the comment's id.
        var help: String
    }

    var bySection: BySection?
    var closing: ClosingTile?
    var topics: TopicsTile?
    var turnaround: TurnaroundTile?
    /// First drafts shows only when it says more than Topics (plan §5 R11).
    var firstDrafts = false
    var nextDraft: [NextItem] = []

    /// The tiles in their order, a hidden one left out.
    var shown: [Kind] {
        [(Kind.bySection, bySection != nil), (.closing, closing != nil), (.topics, topics != nil),
         (.turnaround, turnaround != nil), (.firstDrafts, firstDrafts)].filter(\.1).map(\.0)
    }

    /// `landColumns`: the most columns By section has room for (the others fold into Other).
    static func make(_ group: StudentGroup, stats: StudentStats?, data: [String: PaperOverview], statuses: [String: PaperStatus],
                     catalog: TagCatalog, landColumns: Int = 8, calendar: Calendar = .current) -> StudentTiles {
        guard let stats else { return StudentTiles() }
        let titles = Dictionary(group.papers.map { ($0.path, PaperCardV4.title($0)) }, uniquingKeysWith: { a, _ in a })
        // the student's papers in the engine's order
        let paths = stats.papers.filter { titles[$0] != nil }
        var out = StudentTiles()
        out.bySection = bySection(stats, paths: paths, titles: titles, papers: group.papers, data: data, most: landColumns)
        out.closing = closing(stats, paths: paths, titles: titles, data: data, statuses: statuses)
        out.turnaround = turnaround(stats, paths: paths, titles: titles, data: data, statuses: statuses,
                                    who: group.unassigned ? "Student" : OverviewText.firstName(group.name), calendar: calendar)
        if let t = stats.tags, t.tagged > 0 {
            out.firstDrafts = firstDraftsSayMore(t, paths: paths)
            out.topics = topics(t, paths: paths, titles: titles, catalog: catalog, firstDrafts: out.firstDrafts)
            out.nextDraft = t.focus.map { next($0, titles: titles, catalog: catalog) }
        }
        return out
    }

    /// A trip's days: "2 d", "<1 d" for a stretch of no calendar day (as the medians), "–" for none.
    static func days(_ v: Int?) -> String { v.map { $0 == 0 ? "<1 d" : "\($0) d" } ?? "–" }

    /// "Easy Before Hard –, Curriculum Signals 12": a figure per paper; nil with one paper (the figure is the row's).
    static func split(_ paths: [String], _ titles: [String: String], _ value: (String) -> String?) -> String? {
        guard paths.count > 1 else { return nil }
        return paths.map { ShortTitle.of(titles[$0] ?? "") + " " + (value($0) ?? "–") }.joined(separator: ", ")
    }

    static func bySection(_ stats: StudentStats, paths: [String], titles: [String: String], papers: [PaperRef],
                          data: [String: PaperOverview], most: Int) -> BySection? {
        let pending = paths.compactMap { data[$0]?.pending.count }.reduce(0, +)
        guard let land = stats.land, !land.columns.isEmpty else { return nil }
        let fit = LandColumns.fit(land, most: most)
        guard fit.total.reduce(0, +) > 0 || pending > 0 else { return nil }
        let rows = zip(land.papers, fit.rows).compactMap { r, counts in
            titles[r.path].map { BySection.Row(path: r.path, name: ShortTitle.of($0), title: $0, counts: counts) }
        }
        let mapped = Self.mapped(papers.filter { paths.contains($0.path) }, data: data)
        let help = fit.titles.enumerated().map { i, t in
            (t == "Other" && i == fit.titles.count - 1 ? fit.other ?? t : t) + "\n" + mapped
        }
        let total = fit.total
        let lead = total.indices.max { a, b in total[a] < total[b] || (total[a] == total[b] && a > b) }.flatMap { total[$0] > 0 ? $0 : nil }
        let comments = stats.comments ?? total.reduce(0, +)
        let still = pending > 0 ? "Sections of \(count(pending, "round")) are still being found" : nil
        return BySection(heads: fit.titles.map(short), headHelp: help, rows: rows, all: rows.count > 1 ? total : nil, lead: lead,
                         steps: MapShade.steps(rows.flatMap(\.counts)),
                         headline: lead.map { Headline(key: fit.titles[$0], words: "\(total[$0]) of \(comments)", help: still) },
                         pending: pending)
    }

    /// "Intro.", "Disc.", "Concl." (the mockup's), the others as they are.
    static func short(_ t: String) -> String {
        ["Introduction": "Intro.", "Discussion": "Disc.", "Conclusion": "Concl."][t] ?? t
    }

    /// The headings that land in a standard section of another name ("Limitations → Discussion"), and whether the
    /// advisor has confirmed them (Map Headings…) or they are the engine's suggestions from their words.
    static func mapped(_ papers: [PaperRef], data: [String: PaperOverview]) -> String {
        var pairs: [String] = []
        var confirmed = true
        for p in papers {
            guard let d = data[p.path] else { continue }
            if p.buckets == nil { confirmed = false }
            for s in d.sections where s.key != "front" {
                let b = p.buckets?[s.key] ?? s.suggestedBucket ?? ""
                guard let title = MapHeadingsSheet.title(b), let name = s.name ?? s.title,
                      name.lowercased() != title.lowercased() else { continue }
                let pair = name + " → " + title
                if !pairs.contains(pair) { pairs.append(pair) }
            }
        }
        if pairs.isEmpty { return confirmed ? "Each heading is in the standard section of its own name." : "Each heading looks like the standard section of its name." }
        return (confirmed ? "Headings matched to the standard sections: " : "Headings matched by their words (not confirmed yet): ")
            + pairs.joined(separator: " · ") + "."
    }

    static func closing(_ stats: StudentStats, paths: [String], titles: [String: String], data: [String: PaperOverview],
                        statuses: [String: PaperStatus]) -> ClosingTile? {
        guard let table = stats.closed, let parts = Closing.split(stats, data) else { return nil }
        let t = table.total
        let closed = t.one + t.two + t.three
        // hidden while nothing closed, unless follow-ups were asked (their counts are the headline's and To check's hovers)
        guard closed > 0 || t.followedUp > 0 || t.untouchedAfterFollowUp > 0 else { return nil }
        let per = Dictionary(table.papers.compactMap { p in p.path.map { ($0, p) } }, uniquingKeysWith: { a, _ in a })
        func n(_ v: Int) -> String? { v > 0 ? "\(v)" : nil }
        // the open, built round's comments to check, as `Closing.split` counts them
        func toCheck(_ p: String) -> Int {
            guard let l = data[p]?.latest, !l.isClosed, !l.failed else { return 0 }
            return l.comments?.toCheck ?? 0
        }
        // still open after a follow-up: asked again at least once, not closed and not waiting for your check
        let followed = paths.compactMap { data[$0] }.flatMap(\.comments).filter { c in
            c.path.contains { $0.answer == "follow_up" } && !OverviewPanel.isClosed(c) && c.path.last?.answer != nil
        }.count
        let finished = Set(paths.filter { statuses[$0]?.isFinished == true })
        let stillOpen = split(paths, titles) { p in
            let v = max(0, (per[p]?.open ?? 0) - toCheck(p))
            return v > 0 ? "\(v)" + (finished.contains(p) ? " left open at finish" : "") : nil
        } ?? (paths.count == 1 && finished.contains(paths[0]) && parts.stillOpen > 0 ? "\(parts.stillOpen) left open at finish" : nil)
        func joined(_ parts: String?...) -> String? {
            let s = parts.compactMap { $0 }.joined(separator: " · ")
            return s.isEmpty ? nil : s
        }
        let rows = [
            ClosingTile.Row(name: "In 1 round", value: t.one, help: split(paths, titles) { n(per[$0]?.one ?? 0) }),
            ClosingTile.Row(name: "In 2 rounds", value: t.two, help: split(paths, titles) { n(per[$0]?.two ?? 0) }),
            ClosingTile.Row(name: "In 3 or more", value: t.three, help: split(paths, titles) { n(per[$0]?.three ?? 0) }),
            ClosingTile.Row(name: "To check", value: parts.toCheck,
                            help: joined(split(paths, titles) { n(toCheck($0)) },
                                         t.untouchedAfterFollowUp > 0 ? "\(t.untouchedAfterFollowUp) untouched after a follow-up" : nil)),
            ClosingTile.Row(name: "Still open", value: parts.stillOpen,
                            help: joined(stillOpen, followed > 0 ? "\(followed) of them followed up" : nil)),
        ]
        let up = t.followedUp > 0
            ? "\(t.followedUp) followed up" + (split(paths, titles) { n(per[$0]?.followedUp ?? 0) }.map { " (\($0))" } ?? "")
            : nil
        return ClosingTile(rows: rows, headline: Headline(key: "\(closed)", words: "closed of \(closed + t.open)", help: up))
    }

    static func turnaround(_ stats: StudentStats, paths: [String], titles: [String: String], data: [String: PaperOverview],
                           statuses: [String: PaperStatus], who: String, calendar: Calendar) -> TurnaroundTile? {
        let finished = Set(paths.filter { statuses[$0]?.isFinished == true })
        let trips = Turnaround.trips((stats.time ?? []).filter { paths.contains($0.path) }, finished: finished)
        guard !trips.isEmpty else { return nil }
        var rows: [TurnaroundTile.Row] = []
        for p in paths {
            for (i, t) in trips.filter({ $0.path == p }).sorted(by: { $0.round > $1.round }).enumerated() {
                var help = Turnaround.dates(t, data[p], calendar: calendar)
                if t.failed == true { help += " · build failed" }
                rows.append(TurnaroundTile.Row(path: p, name: paths.count > 1 && i == 0 ? ShortTitle.of(titles[p] ?? "") : nil,
                                               round: t.round, you: t.you, student: t.student, openYou: t.open,
                                               openStudent: t.last == true && t.student != nil, failed: t.failed == true, help: help))
            }
        }
        let m = Turnaround.medians(trips)
        let you = trips.filter { !$0.open }.compactMap(\.you).count
        let back = trips.filter { !$0.open && $0.next != nil }.compactMap(\.student).count
        let help = [m.you.map { "Median with you \($0.exactText) over \(count(you, "round"))" },
                    m.student.map { "with \(who) \($0.exactText) over \(count(back, "round trip"))" }]
            .compactMap { $0 }.joined(separator: ", ")
        return TurnaroundTile(who: who, you: m.you, student: m.student, rows: rows, help: help.isEmpty ? nil : help)
    }

    /// `firstDrafts`: whether First drafts shows; when not, each paper's first draft (its pages, why it is not compared)
    /// is in the paper heads' hovers (the headline's with one paper).
    static func topics(_ t: StudentTags, paths: [String], titles: [String: String], catalog: TagCatalog,
                       firstDrafts: Bool = true) -> TopicsTile {
        let papers = paths.filter { p in t.rounds.contains { $0.path == p } || t.byTag.values.contains { $0.count(in: p) > 0 } }
        let many = papers.count > 1
        func rounds(_ p: String) -> [StudentTags.Round] { t.rounds.filter { $0.path == p }.sorted { $0.n < $1.n } }
        func byRound(_ p: String, _ k: (StudentTags.Round) -> Int) -> String {
            rounds(p).map { r in "R\(r.n) " + (k(r) > 0 ? "\(k(r))" : "–") }.joined(separator: " · ")
        }
        func facts(_ id: String) -> [String] {
            t.facts.filter { $0.tag == id }.compactMap { ProfileText.fact($0, catalog: catalog, titles: titles) }
        }
        // by count, ties in the advisor's order (`sorted` gives it; the sort is stable); Well done is ★
        let ids = catalog.sorted(Array(t.byTag.keys)).filter { $0 != "praise" && (t.byTag[$0]?.comments ?? 0) > 0 }
        let ordered = ids.enumerated().sorted { a, b in
            let x = t.byTag[a.element]?.comments ?? 0, y = t.byTag[b.element]?.comments ?? 0
            return x != y ? x > y : a.offset < b.offset
        }.map(\.element)
        var rows: [TopicsTile.Row] = ordered.compactMap { id in
            guard let r = t.byTag[id] else { return nil }
            let help = ([catalog.tag(id).map(TagText.help) ?? catalog.name(id)] + facts(id)).joined(separator: "\n")
            return TopicsTile.Row(id: id, name: catalog.name(id), counts: papers.map { r.count(in: $0) }, all: r.comments,
                                  nameHelp: help, cellHelp: papers.map { p in byRound(p) { $0.byTag[id] ?? 0 } },
                                  allHelp: count(r.comments, "comment") + " · \(r.open) open")
        }
        if t.untagged.comments > 0 {
            let u = t.untagged
            rows.append(TopicsTile.Row(id: TagCatalog.untagged, name: "Not tagged", counts: papers.map { u.count(in: $0) },
                                       all: u.comments, untagged: true, nameHelp: "Comments without a topic yet",
                                       cellHelp: papers.map { p in byRound(p, \.untagged) },
                                       allHelp: count(u.comments, "comment") + " · \(u.open) open"))
        }
        let skipped = Dictionary(t.firstDrafts.skipped.map { ($0.path, $0.why) }, uniquingKeysWith: { a, _ in a })
        // "Round 1 · 4 pp · not compared: …", First drafts' head for the paper
        func first(_ p: String) -> String? {
            guard !firstDrafts, let r = t.rounds.first(where: { $0.path == p && $0.first }) else { return nil }
            let parts: [String?] = ["Round \(r.n)", r.pages.map { "\($0) pp" }, skipped[p].map { "not compared: " + ProfileText.whyHelp($0) }]
            return parts.compactMap { $0 }.joined(separator: " · ")
        }
        let paperHelp = papers.map { p in (["New comments " + byRound(p, \.new)] + [first(p)].compactMap { $0 }).joined(separator: "\n") }
        let top = rows.first { !$0.untagged }
        let tagged = "\(t.tagged) of \(count(t.comments, "comment")) tagged"
        return TopicsTile(papers: papers, heads: many ? papers.map { ShortTitle.of(titles[$0] ?? "") } : [],
                          headHelp: many ? zip(papers, paperHelp).map { (titles[$0] ?? "") + "\n" + $1 } : [],
                          rows: rows,
                          headline: Headline(key: top?.name ?? "Not tagged", words: "\(top?.all ?? t.untagged.comments) of \(t.comments)",
                                             help: ([tagged] + (many ? [] : paperHelp)).joined(separator: "\n")),
                          untagged: t.comments - t.tagged)
    }

    /// First drafts says more than Topics (plan §5 R11) when some trend word exists, or when its per-paper columns
    /// (each paper's Round 1) differ from Topics' (each paper's comments in all its rounds).
    static func firstDraftsSayMore(_ t: StudentTags, paths: [String]) -> Bool {
        let firsts = t.rounds.filter(\.first)
        guard !firsts.isEmpty else { return false }
        if t.firstDrafts.trend.contains(where: { $0.key != "praise" && $0.value.word != nil }) { return true }
        for p in paths {
            let f = firsts.first { $0.path == p }
            for (id, row) in t.byTag where id != "praise" && (f?.byTag[id] ?? 0) != row.count(in: p) { return true }
        }
        return false
    }

    static func next(_ f: StudentTags.Focus, titles: [String: String], catalog: TagCatalog) -> NextItem {
        let e = f.example
        let facts = [f.comments.map { count($0, "comment") }, (f.followedUp ?? 0) > 0 ? "\(f.followedUp!) needed a follow-up" : nil]
            .compactMap { $0 }.joined(separator: " · ")
        let source = [e?.path.flatMap { titles[$0] }.map(ShortTitle.of), e?.page.map { "p.\($0 + 1)" }].compactMap { $0 }.joined(separator: " ")
        let help = [facts, e?.note.flatMap { $0.isEmpty ? nil : "Your note: " + $0 }, e?.id].compactMap { $0 }.filter { !$0.isEmpty }
        let line = catalog.tag(f.tag)?.focus
        return NextItem(tag: f.tag, name: catalog.name(f.tag), open: f.open, line: (line ?? "").isEmpty ? nil : line,
                        sentence: (e?.text ?? "").isEmpty ? nil : e?.text, source: source.isEmpty ? nil : source,
                        help: help.joined(separator: "\n"))
    }
}

/// The captions and footnotes that left the pages, kept for Help (step 8): the student page's (INVENTORY S5, S8, S11,
/// S13, S16, S18, S20, S22), All Students' and Your Move's.
enum HelpText {
    static let studentPage: [(topic: String, text: String)] = [
        ("By section", "Each comment once, in the section where you wrote it. Map Headings… in the chart’s menu says which "
         + "standard section each of a paper’s headings belongs to."),
        ("Closing", "Each comment once, by the rounds you answered it in. Followed up: you asked again at least once. "
         + "Comments you left open count against nobody. No averages, no comparison with other students."),
        ("Closing by topic", "Each comment once in each of its topics’ rows. Rounds you left open count against nobody; a "
         + "comment you reopened counts as open until closed again."),
        ("Turnaround", "Days per round trip. With you: from the day a round came in to the day you finished it. With the "
         + "student: from then to the day the next round came in, so those days include any wait before it came in. The "
         + "medians start from the second trip."),
        ("Topics", "A comment with two topics is in both rows, so rows can add up to more than the total; All counts it once. "
         + "Later rounds look only at what changed, so this chart has no trend words: First drafts compares the first "
         + "drafts. Click a topic for its comments."),
        ("First drafts", "Each paper’s Round 1, with its pages. Trend words compare first drafts only, from the third of "
         + "similar length; never “better” or “worse”. The chart shows when it says more than Topics."),
        ("For the next draft", "At most two topics with 3 comments still open, new or followed up. Copy for the Email copies "
         + "the lines and the student’s sentences, in English only. Nothing is sent."),
    ]

    /// What left All Students and Your Move in UI v4 step 7 (the small maps' key, the timeline's old key, Your Move's
    /// empty-state sentence), for Help's All Students and Your Move (step 8).
    static let hub: [(topic: String, text: String)] = [
        ("Small maps", "One row per round, newest on top, shaded like that paper’s map (its own three steps). Point at a "
         + "row for its round and its comments."),
        ("Rounds in 2026", "A dot where a round came in; a line while it is with you, dotted while it is with the student. A "
         + "paper that waits on you has a red line and ring from its last round to Today; a finished one is drawn lighter, "
         + "with its checkmark. Point at a lane for its rounds’ dates."),
        ("Your Move", "A paper comes here when a student’s round comes in, until you finish it."),
    ]
}

// MARK: - The views

/// The tiles under the cards: two a row (6 columns each), a lone last one at the left, each row's tiles one height;
/// below 900 pt each takes the width. For the next draft across the page under them.
struct StudentTileGrid: View {
    let model: AppModel
    let hub: HubModel
    let group: StudentGroup
    let stats: StudentStats
    let tiles: StudentTiles
    let kinds: [StudentTiles.Kind]
    let width: CGFloat

    var body: some View {
        let narrow = width < 900
        let rows = narrow ? kinds.map { [$0] } : stride(from: 0, to: kinds.count, by: 2).map { Array(kinds[$0..<min($0 + 2, kinds.count)]) }
        VStack(alignment: .leading, spacing: StudentCardGrid.gutter) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: StudentCardGrid.gutter) {
                    ForEach(row, id: \.self) { k in
                        StudentTileView(model: model, hub: hub, group: group, stats: stats, tiles: tiles, kind: k,
                                        width: narrow ? width : StudentCardGrid.width(6, of: width))
                    }
                }
                .fixedSize(horizontal: false, vertical: true)  // one height for the row's tiles
            }
            if !tiles.nextDraft.isEmpty, let t = stats.tags {
                NextDraftCard(items: tiles.nextDraft, t: t, catalog: model.tags.catalog, group: group, width: width)
            }
        }
    }
}

/// A tile (mockup `.tile`): inset 24; the eyebrow 12 semibold secondary; the headline 8 below; the chart 16 below.
struct StudentTile<Head: View, Chart: View>: View {
    let eyebrow: String
    let width: CGFloat
    let head: Head
    let chart: Chart

    init(_ eyebrow: String, width: CGFloat, @ViewBuilder head: () -> Head, @ViewBuilder chart: () -> Chart) {
        self.eyebrow = eyebrow
        self.width = width
        self.head = head()
        self.chart = chart()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(eyebrow).font(TypeScale.callout.weight(.semibold)).foregroundStyle(Ink.secondary).frame(height: 16)
            head
            chart.padding(.top, 16)
        }
        .padding(24)
        .frame(width: width, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .hubCard(radius: 10)
    }
}

/// "Results 12 of 30": the figure 17 semibold, its words 13 secondary, 6 apart, 8 under the eyebrow.
struct TileHeadline: View {
    let headline: StudentTiles.Headline?

    var body: some View {
        if let h = headline {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(h.key).font(TypeScale.title2)
                Text(h.words).font(TypeScale.body).foregroundStyle(Ink.secondary)
            }
            .monospacedDigit()
            .lineLimit(1)
            .frame(height: 22)
            .padding(.top, 8)
            .help(ifAny: h.help)
        }
    }
}

/// One tile of the page, by its kind, with its context menu.
struct StudentTileView: View {
    let model: AppModel
    @ObservedObject var hub: HubModel
    let group: StudentGroup
    let stats: StudentStats
    let tiles: StudentTiles
    let kind: StudentTiles.Kind
    let width: CGFloat
    @State private var byTopic = false

    var body: some View {
        let inner = width - 48
        switch kind {
        case .bySection:
            if let s = tiles.bySection {
                StudentTile("By section", width: width) { TileHeadline(headline: s.headline) } chart: {
                    if s.headline == nil {
                        Text("Finding the sections of \(count(s.pending, "round"))…").font(TypeScale.body).foregroundStyle(Ink.secondary)
                    } else {
                        BySectionChart(tile: s, width: inner)
                    }
                }
                .contextMenu {
                    about
                    Button("Map Headings…") { model.mappingHeadings = group.key }
                }
            }
        case .closing:
            if let c = tiles.closing {
                StudentTile("Closing", width: width) { TileHeadline(headline: c.headline) } chart: { ClosingChart(tile: c, width: inner) }
                    .contextMenu {
                        about
                        if let t = stats.tags, t.tagged > 0 { Button("Show by Topic") { byTopic = true } }
                    }
                    .popover(isPresented: $byTopic, arrowEdge: .bottom) {
                        if let t = stats.tags { ClosedByTopicTable(t: t, catalog: model.tags.catalog).padding(16).frame(width: 520) }
                    }
            }
        case .topics:
            if let t = tiles.topics {
                StudentTile("Topics", width: width) { TileHeadline(headline: t.headline) } chart: {
                    TopicsChart(model: model, hub: hub, group: group, tile: t, width: inner)
                }
                .contextMenu {
                    about
                    if t.untagged > 0 { Button("Tag \(count(t.untagged, "Comment"))…") { model.openTagComments(student: group.key) } }
                }
            }
        case .turnaround:
            if let t = tiles.turnaround {
                StudentTile("Turnaround", width: width) { TurnaroundHeadline(tile: t) } chart: { TurnaroundChart(tile: t, width: inner) }
                    .contextMenu { about }
            }
        case .firstDrafts:
            if let t = stats.tags {
                StudentTile("First drafts", width: width) { EmptyView() } chart: {
                    FirstDraftsTable(t: t, catalog: model.tags.catalog,
                                     titles: Dictionary(group.papers.map { ($0.path, $0.title) }, uniquingKeysWith: { a, _ in a }))
                }
                .contextMenu { about }
            }
        }
    }

    /// First in every tile's menu: the tile's row in Help (UI v4; BRIEF §2: no ⓘ on the tiles).
    private var about: some View {
        Button("About This Chart") { model.openHelp(.studentPage, section: kind.helpSection) }
    }
}

/// By section (mockup `bySection`, `.heat`): a 136 pt name column and the All row only with more than one paper; heads
/// 12 secondary, the leader's in the label colour; cells 28 tall on the map's ramp, 4 apart.
struct BySectionChart: View {
    let tile: StudentTiles.BySection
    let width: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = MapInk(dark: scheme == .dark)
        let many = tile.all != nil, gap: CGFloat = 4, nameW: CGFloat = many ? 136 : 0
        let n = CGFloat(max(1, tile.heads.count))
        let colW = max(24, (width - nameW - gap * (many ? n : n - 1)) / n)
        VStack(alignment: .leading, spacing: gap) {
            HStack(spacing: gap) {
                if many { Color.clear.frame(width: nameW, height: 1) }
                ForEach(Array(tile.heads.enumerated()), id: \.offset) { i, h in
                    Text(h).font(TypeScale.callout).fontWeight(i == tile.lead ? .semibold : .regular)
                        .foregroundStyle(i == tile.lead ? Ink.label : Ink.secondary)
                        .lineLimit(1).frame(width: colW).help(tile.headHelp[i])
                }
            }
            .frame(height: 16)
            .padding(.bottom, 4)
            ForEach(Array(tile.rows.enumerated()), id: \.offset) { _, r in
                HStack(spacing: gap) {
                    if many {
                        Text(r.name).foregroundStyle(Ink.label2).lineLimit(1).truncationMode(.tail).padding(.trailing, 8)
                            .frame(width: nameW, alignment: .leading).help(r.title)
                    }
                    ForEach(Array(r.counts.enumerated()), id: \.offset) { _, v in cell(v, ink: ink).frame(width: colW, height: 28) }
                }
            }
            if let all = tile.all {
                Rectangle().fill(Color(nsColor: Palette.rule)).frame(height: 1).padding(.top, 4)
                HStack(spacing: gap) {
                    Text("All").font(TypeScale.callout).foregroundStyle(Ink.secondary).frame(width: nameW, alignment: .leading)
                    ForEach(Array(all.enumerated()), id: \.offset) { i, v in
                        Text(v > 0 ? "\(v)" : "–").fontWeight(i == tile.lead ? .semibold : .regular)
                            .foregroundStyle(v == 0 ? Ink.tertiary : i == tile.lead ? Ink.label : Ink.label2)
                            .frame(width: colW)
                    }
                }
                .frame(height: 18)
            }
        }
        .font(TypeScale.body)
        .monospacedDigit()
    }

    private func cell(_ v: Int, ink: MapInk) -> some View {
        RoundedRectangle(cornerRadius: 5).fill(ink.color(MapRole.cell(MapShade.level(v, tile.steps))))
            .overlay { if v == 0 { RoundedRectangle(cornerRadius: 5).strokeBorder(ink.color(.zeroline), lineWidth: 0.5) } }
            .overlay(Text(v > 0 ? "\(v)" : "–").fontWeight(v > 0 ? .medium : .regular).foregroundStyle(v > 0 ? Ink.label : Ink.tertiary))
    }
}

/// Closing (mockup `closing`, `.cbar`, `.cleg`): a 12 pt bar on the track with a .5 pt rule, the closed in the Sage
/// tints, To check a vermilion outline, Still open the track; the legend in two columns 40 apart, empty rows dimmed.
struct ClosingChart: View {
    let tile: StudentTiles.ClosingTile
    let width: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = MapInk(dark: scheme == .dark)
        let colW = (width - 40) / 2
        VStack(alignment: .leading, spacing: 12) {
            bar(ink).frame(width: width, height: 12)
            HStack(alignment: .top, spacing: 40) {
                column(0..<3, ink: ink).frame(width: colW)
                column(3..<5, ink: ink).frame(width: colW)
            }
        }
        .font(TypeScale.body)
        .monospacedDigit()
    }

    private func bar(_ ink: MapInk) -> some View {
        let values = tile.rows.map(\.value)
        return Canvas { ctx, size in
            let all = CGRect(origin: .zero, size: size)
            ctx.fill(Path(roundedRect: all, cornerRadius: 2), with: .color(ink.color(.track)))
            let total = CGFloat(values.reduce(0, +)), shown = values.indices.filter { values[$0] > 0 }
            guard total > 0 else { return }
            let room = size.width - 2 * CGFloat(shown.count - 1)
            var x: CGFloat = 0
            for i in shown {
                let r = CGRect(x: x, y: 0, width: room * CGFloat(values[i]) / total, height: size.height)
                if i < 3 {
                    ctx.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(ink.color([MapRole.c1, .c2, .c3][i])))
                } else if i == 3 {
                    ctx.stroke(Path(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), cornerRadius: 2), with: .color(ink.color(.attention)), lineWidth: 1.5)
                }
                x = r.maxX + 2
            }
            ctx.stroke(Path(roundedRect: all.insetBy(dx: 0.25, dy: 0.25), cornerRadius: 2), with: .color(ink.color(.rule)), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }

    private func column(_ range: Range<Int>, ink: MapInk) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(range, id: \.self) { i in
                let r = tile.rows[i], dim = r.value == 0
                HStack(spacing: 8) {
                    swatch(i, ink: ink).opacity(dim ? 0.55 : 1)
                    Text(r.name).foregroundStyle(dim ? Ink.secondary : Ink.label).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(dim ? "–" : "\(r.value)").fontWeight(dim ? .regular : .semibold).foregroundStyle(dim ? Ink.tertiary : Ink.label)
                }
                .frame(height: 28)
                .contentShape(Rectangle())
                .help(ifAny: r.help)
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder private func swatch(_ i: Int, ink: MapInk) -> some View {
        let shape = RoundedRectangle(cornerRadius: 2)
        Group {
            if i < 3 {
                shape.fill(ink.color([MapRole.c1, .c2, .c3][i]))
            } else {
                shape.fill(ink.color(.track))
                    .overlay(shape.strokeBorder(ink.color(i == 3 ? .attention : .rule), lineWidth: i == 3 ? 1.5 : 0.5))
            }
        }
        .frame(width: 10, height: 10)
    }
}

/// Turnaround's headline: the `you` swatch, "2 d" "you", 24 apart, the `stu` swatch, "11 d" "Maya" (the medians, from
/// the second trip; none before).
struct TurnaroundHeadline: View {
    let tile: StudentTiles.TurnaroundTile
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = MapInk(dark: scheme == .dark)
        if tile.you != nil || tile.student != nil {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                if let y = tile.you { part(ink.color(.you), y.text, "you") }
                if tile.you != nil && tile.student != nil { Color.clear.frame(width: 24, height: 1) }
                if let s = tile.student { part(ink.color(.stu), s.text, tile.who) }
            }
            .monospacedDigit()
            .lineLimit(1)
            .frame(height: 22)
            .padding(.top, 8)
            .help(ifAny: tile.help)
        }
    }

    private func part(_ color: Color, _ days: String, _ who: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
            Text(days).font(TypeScale.title2)
            Text(who).font(TypeScale.body).foregroundStyle(Ink.secondary)
        }
    }
}

/// Turnaround's rows (mockup `trips`, `.trip`): the short name on a paper's first row (more than one paper), "R2", the
/// bars at up to 14 pt a day (your days, then the student's), You and the student's days at the right; a stretch still
/// running an outline with "so far".
struct TurnaroundChart: View {
    let tile: StudentTiles.TurnaroundTile
    let width: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = MapInk(dark: scheme == .dark)
        let many = tile.rows.contains { $0.name != nil }
        let nameW: CGFloat = many ? 132 : 0
        let gaps: CGFloat = many ? 48 : 36
        let barsW: CGFloat = max(40, width - nameW - 110 - gaps)
        let most = CGFloat(max(1, tile.rows.map(Self.days).max() ?? 1))
        let day: CGFloat = min(14, max(1, (barsW - (tile.rows.contains(where: \.failed) ? 72 : 52)) / most))  // room for "so far" (and the failed octagon)
        VStack(alignment: .leading, spacing: 0) {
            heads
            ForEach(Array(tile.rows.enumerated()), id: \.offset) { _, r in
                row(r, nameW: nameW, barsW: barsW, day: day, ink: ink)
            }
        }
        .font(TypeScale.body)
        .monospacedDigit()
    }

    private static func days(_ r: StudentTiles.TurnaroundTile.Row) -> Int { (r.you ?? 0) + (r.student ?? 0) }

    private var heads: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            Text("You").frame(width: 44, alignment: .trailing)
            Text(tile.who).truncationMode(.tail).frame(width: 44, alignment: .trailing).help(tile.who)
        }
        .font(TypeScale.callout).foregroundStyle(Ink.secondary).lineLimit(1)
        .frame(height: 16)
        .padding(.bottom, 4)
    }

    private func row(_ r: StudentTiles.TurnaroundTile.Row, nameW: CGFloat, barsW: CGFloat, day: CGFloat, ink: MapInk) -> some View {
        HStack(spacing: 12) {
            if nameW > 0 { Text(r.name ?? "").foregroundStyle(Ink.label2).lineLimit(1).frame(width: nameW, alignment: .leading) }
            Text("R\(r.round)").font(TypeScale.callout).foregroundStyle(Ink.secondary).frame(width: 22, alignment: .leading)
            bars(r, day: day, ink: ink).frame(width: barsW, alignment: .leading)
            value(r.you, open: r.openYou)
            value(r.student, open: r.openStudent)
        }
        .frame(height: 28)
        .contentShape(Rectangle())
        .help(r.help)
    }

    private func bars(_ r: StudentTiles.TurnaroundTile.Row, day: CGFloat, ink: MapInk) -> some View {
        HStack(spacing: 2) {
            if let y = r.you { bar(y, day: day, color: ink.color(r.openYou ? .attention : .you), open: r.openYou) }
            if let s = r.student { bar(s, day: day, color: ink.color(.stu), open: r.openStudent) }
            if r.failed { StatusGlyphView(.failed).padding(.leading, 4) }
            if r.openYou || r.openStudent { Text("so far").font(TypeScale.callout).foregroundStyle(Ink.secondary).padding(.leading, 4) }
        }
    }

    @ViewBuilder private func bar(_ days: Int, day: CGFloat, color: Color, open: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 2)
        if open {
            shape.strokeBorder(color, lineWidth: 1.5).frame(width: max(8, CGFloat(days) * day), height: 12)
        } else {
            shape.fill(color).frame(width: max(3, CGFloat(days) * day), height: 12)
        }
    }

    private func value(_ v: Int?, open: Bool) -> some View {
        Text(StudentTiles.days(v))
            .foregroundStyle(v == nil ? Ink.tertiary : open ? Ink.secondary : Ink.label2)
            .lineLimit(1)
            .frame(width: 44, alignment: .trailing)
    }
}

/// Topics (mockup `topics`, `.tops`): rows by count, Not tagged last in secondary; an 8 pt bar per paper at up to 18 pt
/// a comment on one scale, its count beside it; All with more than one paper. A click on a row lists its comments in a
/// popover on the row (`hub.studentTag`); again, or a click outside, closes it.
struct TopicsChart: View {
    let model: AppModel
    @ObservedObject var hub: HubModel
    let group: StudentGroup
    let tile: StudentTiles.TopicsTile
    let width: CGFloat
    @State private var hovered: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = MapInk(dark: scheme == .dark)
        let many = tile.papers.count > 1, gap: CGFloat = 16, nameW: CGFloat = 150, allW: CGFloat = many ? 32 : 0
        let n = CGFloat(max(1, tile.papers.count))
        let colW = max(30, (width - nameW - allW - gap * (many ? n + 1 : n)) / n)
        let most = max(1, tile.rows.flatMap(\.counts).max() ?? 1)
        let k = min(18, max(1, (colW - 30) / CGFloat(most)))
        let picked = hub.studentTag.flatMap { $0.student == group.key ? $0.tag : nil }
        VStack(alignment: .leading, spacing: 0) {
            if many {
                HStack(spacing: gap) {
                    Color.clear.frame(width: nameW, height: 1)
                    ForEach(Array(tile.heads.enumerated()), id: \.offset) { i, h in
                        Text(h).lineLimit(1).frame(width: colW, alignment: .leading).help(tile.headHelp[i])
                    }
                    Text("All").frame(width: allW, alignment: .trailing)
                }
                .font(TypeScale.callout).foregroundStyle(Ink.secondary)
                .frame(height: 16)
                .padding(.bottom, 4)
            }
            ForEach(tile.rows, id: \.id) { r in
                row(r, many: many, nameW: nameW, colW: colW, allW: allW, gap: gap, k: k, ink: ink, picked: picked)
            }
        }
        .font(TypeScale.body)
        .monospacedDigit()
    }

    private func row(_ r: StudentTiles.TopicsTile.Row, many: Bool, nameW: CGFloat, colW: CGFloat, allW: CGFloat, gap: CGFloat,
                     k: CGFloat, ink: MapInk, picked: String?) -> some View {
        let on = picked == r.id, lead = r.id == tile.rows.first?.id && !r.untagged
        return HStack(spacing: gap) {
            Text(r.name).fontWeight(lead ? .semibold : .regular)
                .foregroundStyle(on ? Ink.accentText : r.untagged ? Ink.secondary : lead ? Ink.label : Ink.label2)
                .lineLimit(1).frame(width: nameW, alignment: .leading)
                .help(r.nameHelp)
            ForEach(Array(r.counts.enumerated()), id: \.offset) { i, v in
                HStack(spacing: 8) {
                    if v > 0 {
                        RoundedRectangle(cornerRadius: 2).fill(ink.color(.ink)).frame(width: CGFloat(v) * k, height: 8)
                        Text("\(v)").foregroundStyle(Ink.label2)
                    } else {
                        Text("–").foregroundStyle(Ink.tertiary)
                    }
                }
                .font(TypeScale.callout)
                .frame(width: colW, alignment: .leading)
                .help(many ? r.cellHelp[i] : r.cellHelp[i] + "\n" + r.allHelp)
            }
            if many {
                Text("\(r.all)").fontWeight(lead ? .semibold : .regular).foregroundStyle(lead ? Ink.label : Ink.label2)
                    .frame(width: allW, alignment: .trailing).help(r.allHelp)
            }
        }
        .frame(height: 28)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color(nsColor: Palette.accentTint)
                                                          : hovered == r.id ? Color(nsColor: Palette.hover) : .clear))
        .padding(.horizontal, -8)
        .contentShape(Rectangle())
        .onHover { h in hovered = h ? r.id : (hovered == r.id ? nil : hovered) }
        .onTapGesture { hub.studentTag = on ? nil : StudentTagChoice(student: group.key, tag: r.id) }
        .popover(isPresented: Binding(get: { on }, set: { if !$0, hub.studentTag?.tag == r.id { hub.studentTag = nil } }),
                 arrowEdge: .trailing) {
            ScrollView {
                StudentTagPanel(model: model, list: StudentTagList.make(r.id, papers: group.papers.map { ($0.path, $0.title) },
                                                                         data: hub.data, catalog: model.tags.catalog))
                    .padding(16)
            }
            .frame(width: 480)
            .frame(maxHeight: 420)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(on ? "Its comments are listed: click to close" : "Lists its comments across the papers")
    }
}

/// For the next draft (mockup `nextDraft`, `.nd`): across the page; the eyebrow and Copy for the Email at the top; a
/// column per topic, 48 apart: the topic 17 semibold and "4 open", the advisor's line, the student's sentence in New
/// York with a rule at its left, and where it is.
struct NextDraftCard: View {
    let items: [StudentTiles.NextItem]
    let t: StudentTags
    let catalog: TagCatalog
    let group: StudentGroup
    let width: CGFloat
    @State private var copied = false

    var body: some View {
        let inner = width - 48
        let two = inner >= 560
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("For the next draft").font(TypeScale.callout.weight(.semibold)).foregroundStyle(Ink.secondary)
                Spacer(minLength: 12)
                Button { copy() } label: { Label(copied ? "Copied" : "Copy for the Email", systemImage: "doc.on.doc") }
                    .buttonStyle(.bordered)
                    .help("The lines and \(OverviewText.firstName(group.name))’s sentences, in English, on the clipboard. Nothing is sent.")
            }
            .frame(height: 24)
            if two {
                HStack(alignment: .top, spacing: 48) {
                    ForEach(items, id: \.tag) { i in item(i).frame(width: (inner - 48) / 2, alignment: .topLeading) }
                }
                .padding(.top, 4)
            } else {
                VStack(alignment: .leading, spacing: 24) { ForEach(items, id: \.tag) { item($0) } }.padding(.top, 4)
            }
        }
        .padding(24)
        .frame(width: width, alignment: .topLeading)
        .hubCard(radius: 10)
    }

    private func item(_ i: StudentTiles.NextItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(i.name).font(TypeScale.title2)
                if let o = i.open, o > 0 { Text("\(o) open").font(TypeScale.body).foregroundStyle(Ink.secondary) }
            }
            .monospacedDigit()
            .lineLimit(1)
            .frame(height: 22)
            .help(ifAny: i.help)
            if let l = i.line {
                Text(l).font(TypeScale.body).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            }
            if let s = i.sentence {
                Text(s).font(.system(size: 15, design: .serif)).foregroundStyle(Ink.label2)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) { Rectangle().fill(Color(nsColor: Palette.rule)).frame(width: 2) }
                    .padding(.top, 12)
                if let src = i.source {
                    Text(src).font(TypeScale.callout).foregroundStyle(Ink.secondary).padding(.leading, 14).padding(.top, 4)
                }
            }
        }
    }

    private func copy() {
        let titles = Dictionary(group.papers.map { ($0.path, $0.title) }, uniquingKeysWith: { a, _ in a })
        AppModel.clipboard.clearContents()
        AppModel.clipboard.setString(ProfileText.email(t.focus, catalog: catalog, titles: titles), forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }
}
