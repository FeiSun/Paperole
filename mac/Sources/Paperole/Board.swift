import SwiftUI

// All Students and Your Move (UI v4 step 7; design/ui-v4 BRIEF §4 05/06/07/09, §8.2, mockup `board`, `bcard`,
// `timeline`, `yourMove`, `mrow`; mac/UX.md §40.6): the board's three lanes and the rounds of the year under them, the
// paper card every lane and the students mode draw, and Your Move's queue. The models are pure values (BoardTests).

/// All Students' two views, the toolbar's Board | Students: the viewer's choice, kept in Prefs (never by a test run).
enum AllStudentsView: String, CaseIterable {
    case board, students
}

/// A paper as the board, the students mode and Your Move draw it (mockup `bcard`): the student and the corner's time,
/// the title, and the figure of its state (mockup `states`, BRIEF §4 09).
struct BoardCard: Equatable, Identifiable {
    enum Figure: Equatable {
        /// "○ 14 comments + 2 edits", the ring filled by what is answered.
        case toCheck(PaperFigures.Count)
        /// The ring full, "6 paragraphs to read".
        case toRead(Int)
        case ready
        /// The ring empty, "First draft"; the mini map's cells empty.
        case firstDraft
        /// The octagon, "Build failed" and the round.
        case failed(Int?)
        /// With the student: the comments, and "· 3 closed" when some closed (nil before the data).
        case withStudent(comments: Int?, closed: Int?)
        /// "2 rounds · 12 of 16 closed" ("" before the data).
        case finished(String)
        case noRounds
        /// No status: the folder is missing, not connected or damaged, in the sidebar's words.
        case missing(String)
    }

    var path: String
    /// The student's name ("Unassigned" without one).
    var who: String
    var title: String
    var status: PaperStatus?
    var figure: Figure
    /// The state's sign; nil without a status.
    var glyph: StatusGlyph?
    /// The ring's fill when something is answered; nil for an empty ring and for every figure without a ring.
    var fill: Double?
    /// "6 of 16 answered so far": the to-check figure's hover.
    var answered: String?
    /// "2 d" since the round came in (your move) or went back (with the student), "Sep 23" (finished); its other form
    /// ("Came in Wed, Oct 28") in `cornerHelp`.
    var corner: String?
    var cornerHelp: String?
    /// A mini map under the title: not for a finished paper or one without rounds (BRIEF §4 05).
    var map = false
    /// Your move: what the card's menu and Your Move's button do.
    var item: MoveItem?
    /// "4 rounds since Sep 8 · 28 comments" (the old tile's facts): the title's hover.
    var facts: String?
    var id: String { path }

    static func make(_ p: PaperRef, status: PaperStatus?, summary: PaperSummary?, data d: PaperOverview?, missing: String? = nil,
                     item: MoveItem? = nil, today: Date, calendar: Calendar = .current) -> BoardCard {
        let f = PaperFigures.make(status, summary, d, today: today, calendar: calendar)
        let title = p.title.isEmpty ? (p.path as NSString).lastPathComponent : p.title
        let who = p.student.isEmpty ? "Unassigned" : StudentName.shown(p.student)
        var c = BoardCard(path: p.path, who: who, title: title, status: status, figure: .missing(missing ?? ""), glyph: f?.glyph,
                          corner: f?.dayCounter, cornerHelp: f?.hover, item: item)
        c.map = !(d?.rounds.isEmpty ?? true)
        if let d, !d.rounds.isEmpty {
            c.facts = [count(d.rounds.count, "round")
                       + (Hierarchy.date(d.rounds.first?.created).map { " since " + HubText.format($0, "MMM d", calendar.timeZone) } ?? ""),
                       d.threads?.comments.map { count($0, "comment") }].compactMap { $0 }.joined(separator: " · ")
        }
        switch status {
        case nil: break
        case .toCheck(let n, let e)?:
            c.figure = .toCheck(PaperFigures.Count(comments: n, edits: e))
            c.fill = f?.fill
            c.answered = f?.answered
        case .toRead(let n)?: c.figure = .toRead(n)
        case .ready?: c.figure = .ready
        case .firstDraft?: c.figure = .firstDraft
        case .failed?: c.figure = .failed(d?.latest?.n ?? summary?.round)
        case .waiting?: c.figure = .withStudent(comments: f?.totals?.comments, closed: f?.totals?.closed.flatMap { $0 > 0 ? $0 : nil })
        case .finished?:
            c.figure = .finished(f?.totals.map { HubText.finishedLine(rounds: d?.rounds.count ?? 0, closed: $0.closed ?? 0, of: $0.comments) } ?? "")
            c.map = false
        case .noRounds?:
            c.figure = .noRounds
            c.map = false
        }
        return c
    }

    /// The figure in words (the debug hooks, VoiceOver). `state`: with the sign's words a lane says already ("With Sara
    /// · 5 comments", "Finished · 2 rounds · 12 of 16 closed"), as the students mode shows them.
    func words(state: Bool = false) -> String {
        switch figure {
        case .toCheck(let n): return HubText.figure(n.comments, n.edits)
        case .toRead(let n): return count(n, "paragraph") + " to read"
        case .ready: return "Ready to finish"
        case .firstDraft: return "First draft"
        case .failed(let r): return "Build failed" + (r.map { " · Round \($0)" } ?? "")
        case .withStudent(let n, let closed):
            let first = OverviewText.firstName(who == "Unassigned" ? "" : who)
            let parts = [state ? "With " + (first.isEmpty ? "the student" : first) : nil, n.map { count($0, "comment") },
                         closed.map { "\($0) closed" }]
            return parts.compactMap { $0 }.joined(separator: " · ")
        case .finished(let s): return ([state ? "Finished" : nil, s.isEmpty ? nil : s]).compactMap { $0 }.joined(separator: " · ")
        case .noRounds: return "No rounds yet"
        case .missing(let w): return w
        }
    }
}

/// The board (mockup `board`): Your move, oldest arrival first; With students, the longest with the student first (and
/// the papers without a status, their folder missing or damaged: plan §5 R13); Finished in the last eight weeks, newest
/// first, the older ones under "Earlier · N". Every listed paper is in one lane once its summary is read (before, a
/// paper without a status or words is in none).
struct BoardModel: Equatable {
    enum LaneKind: String, CaseIterable {
        case yourMove = "Your move", withStudents = "With students", finished = "Finished"

        var glyph: StatusGlyph {
            switch self {
            case .yourMove: return .ring(0)
            case .withStudents: return .waiting
            case .finished: return .finished
            }
        }
    }

    struct Lane: Equatable {
        var kind: LaneKind
        var cards: [BoardCard]
        /// Finished more than eight weeks ago: under "Earlier · N".
        var earlier: [BoardCard] = []
        var count: Int { cards.count + earlier.count }
        /// "3 to review or finish · 1 build failed" (Your move's): its head's help.
        var detail: String {
            let failed = cards.filter { $0.status == .failed }.count
            return HubText.waitsDetail(review: cards.count - failed, failed: failed)
        }
    }

    var lanes: [Lane]

    /// How recent a finished paper stays on the board: finished fewer than 56 calendar days ago.
    static let recentDays = 56

    static func make(_ papers: [PaperRef], statuses: [String: PaperStatus], summaries: [String: PaperSummary],
                     data: [String: PaperOverview], missing: [String: String] = [:], today: Date,
                     calendar: Calendar = .current) -> BoardModel {
        func card(_ p: PaperRef, item: MoveItem? = nil) -> BoardCard {
            BoardCard.make(p, status: statuses[p.path], summary: summaries[p.path], data: data[p.path], missing: missing[p.path],
                           item: item, today: today, calendar: calendar)
        }
        let moves = Hierarchy.yourMove(papers, status: { statuses[$0.path] }, data: data, summaries: summaries)
        // the longest with the student first (the earliest return); the others after them in the list's order
        let away = papers.enumerated().filter { e in
            guard let s = statuses[e.element.path] else { return missing[e.element.path] != nil }
            return s == .waiting || s == .noRounds
        }
        .map { (i: $0.offset, p: $0.element, back: Hierarchy.date(data[$0.element.path]?.latest?.closedAt)) }
        .sorted { a, b in
            switch (a.back, b.back) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.i < b.i
            }
        }
        let parse = HubText.formatter("yyyy-MM-dd", calendar.timeZone)
        let done = papers.enumerated().compactMap { e -> (i: Int, p: PaperRef, day: Date?)? in
            guard case .finished(let d)? = statuses[e.element.path] else { return nil }
            return (e.offset, e.element, parse.date(from: d))
        }
        .sorted { a, b in
            switch (a.day, b.day) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.i < b.i
            }
        }
        let recent = done.filter { $0.day.map { HubText.dayCount($0, today: today, calendar: calendar) < recentDays } ?? true }
        let older = done.filter { $0.day.map { HubText.dayCount($0, today: today, calendar: calendar) >= recentDays } ?? false }
        return BoardModel(lanes: [
            Lane(kind: .yourMove, cards: moves.map { card($0.paper, item: $0) }),
            Lane(kind: .withStudents, cards: away.map { card($0.p) }),
            Lane(kind: .finished, cards: recent.map { card($0.p) }, earlier: older.map { card($0.p) }),
        ])
    }

    func lane(_ k: LaneKind) -> Lane { lanes.first { $0.kind == k } ?? Lane(kind: k, cards: []) }
}

/// Your Move (mockup `yourMove`, `mrow`): the papers that wait on you, oldest first, the oldest's button the primary
/// one; then the papers with students, the longest away first, as quiet rows.
struct YourMoveModel: Equatable {
    struct Row: Equatable, Identifiable {
        var card: BoardCard
        /// "Maya Chen · Round 2".
        var sub: String
        /// Days since the round came in (or went back, for a quiet row); nil before the hierarchy's data.
        var days: Int?
        /// "Came in Wed, Oct 28", "Sent back Sat, Oct 24".
        var help: String?
        var primary = false
        var id: String { card.path }
    }

    var rows: [Row]
    var quiet: [Row]

    static func make(_ papers: [PaperRef], statuses: [String: PaperStatus], summaries: [String: PaperSummary],
                     data: [String: PaperOverview], today: Date, calendar: Calendar = .current) -> YourMoveModel {
        func sub(_ p: PaperRef, _ round: Int?) -> String {
            [p.student.isEmpty ? nil : StudentName.shown(p.student), round.map { "Round \($0)" }].compactMap { $0 }.joined(separator: " · ")
        }
        let moves = Hierarchy.yourMove(papers, status: { statuses[$0.path] }, data: data, summaries: summaries)
        let rows = moves.enumerated().map { i, m -> Row in
            let came = Hierarchy.date(m.imported)
            return Row(card: BoardCard.make(m.paper, status: m.status, summary: summaries[m.paper.path], data: data[m.paper.path],
                                            item: m, today: today, calendar: calendar),
                       sub: sub(m.paper, m.round), days: came.map { HubText.dayCount($0, today: today, calendar: calendar) },
                       help: came.map { HubText.hoverCameIn($0, calendar: calendar) }, primary: i == 0)
        }
        let quiet = BoardModel.make(papers.filter { statuses[$0.path] == .waiting }, statuses: statuses, summaries: summaries,
                                    data: data, today: today, calendar: calendar).lane(.withStudents).cards.compactMap { c -> Row? in
            guard let p = papers.first(where: { $0.path == c.path }) else { return nil }
            let back = Hierarchy.date(data[p.path]?.latest?.closedAt)
            return Row(card: c, sub: sub(p, data[p.path]?.latest?.n ?? summaries[p.path]?.round),
                       days: back.map { HubText.dayCount($0, today: today, calendar: calendar) },
                       help: back.map { HubText.hoverSentBack($0, calendar: calendar) })
        }
        return YourMoveModel(rows: rows, quiet: quiet)
    }

    /// The Waiting column: ("2", "days"), ("1", "day"), ("today", nil); ("–", nil) before the data.
    static func waiting(_ days: Int?) -> (value: String, unit: String?) {
        guard let n = days else { return ("–", nil) }
        return n == 0 ? ("today", nil) : ("\(n)", n == 1 ? "day" : "days")
    }
}

extension AppModel {
    /// The statuses of the listed papers that have one (a missing folder has none).
    var statuses: [String: PaperStatus] {
        Dictionary(papers.compactMap { p in status(of: p).map { (p.path, $0) } }, uniquingKeysWith: { a, _ in a })
    }

    /// A card's words without a status: the folder missing or not connected, or "Damaged: …", as the sidebar's row.
    func cardWords(_ p: PaperRef) -> String? {
        missingWords(p) ?? damagedPapers[p.path].map { "Damaged: " + $0 }
    }

    func board(today: Date = Date()) -> BoardModel {
        let missing = Dictionary(papers.compactMap { p in cardWords(p).map { (p.path, $0) } }, uniquingKeysWith: { a, _ in a })
        return BoardModel.make(papers, statuses: statuses, summaries: summaries, data: hubModel.data, missing: missing, today: today)
    }

    func yourMovePage(today: Date = Date()) -> YourMoveModel {
        YourMoveModel.make(papers, statuses: statuses, summaries: summaries, data: hubModel.data, today: today)
    }
}

// MARK: - The board

/// The lanes (mockup `.board`): Your move over two of four columns, With students and Finished one each, each lane its
/// own stack of cards 8 apart; the cards of one visual row one height (plan §5 R14). Below 900 pt the lanes stack, each
/// at the full width with its cards two to a row.
struct BoardView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var hub: HubModel
    let board: BoardModel
    let width: CGFloat

    static let gutter: CGFloat = 16

    /// One of the four columns.
    static func column(_ width: CGFloat) -> CGFloat { (width - 3 * gutter) / 4 }

    /// A cell of a lane: a card, or Finished's "Earlier · N" row.
    private enum Slot { case card(BoardCard), earlier(Int) }

    var body: some View {
        if width < 900 {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(board.lanes, id: \.kind) { lane in
                    VStack(alignment: .leading, spacing: 0) {
                        header(lane)
                        let slots = self.slots(lane), half = (width - Self.gutter) / 2
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(stride(from: 0, to: slots.count, by: 2)), id: \.self) { i in
                                row([slots[i], i + 1 < slots.count ? slots[i + 1] : nil], width: half)
                            }
                        }
                    }
                }
            }
        } else {
            let col = Self.column(width)
            let ym = slots(board.lane(.yourMove)), ws = slots(board.lane(.withStudents)), fin = slots(board.lane(.finished))
            let n = max((ym.count + 1) / 2, ws.count, fin.count)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: Self.gutter) {
                    header(board.lane(.yourMove)).frame(width: 2 * col + Self.gutter)
                    header(board.lane(.withStudents)).frame(width: col)
                    header(board.lane(.finished)).frame(width: col)
                }
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(0..<n, id: \.self) { i in
                        row([at(ym, 2 * i), at(ym, 2 * i + 1), at(ws, i), at(fin, i)], width: col)
                    }
                }
            }
        }
    }

    private func at(_ s: [Slot], _ i: Int) -> Slot? { s.indices.contains(i) ? s[i] : nil }

    private func slots(_ lane: BoardModel.Lane) -> [Slot] {
        guard !lane.earlier.isEmpty else { return lane.cards.map { .card($0) } }
        return lane.cards.map { .card($0) } + [.earlier(lane.earlier.count)] + (hub.showEarlier ? lane.earlier.map { .card($0) } : [])
    }

    /// The cells of one visual row, one height (an empty cell keeps its column).
    private func row(_ cells: [Slot?], width w: CGFloat) -> some View {
        HStack(alignment: .top, spacing: Self.gutter) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, s in
                switch s {
                case .card(let c)?:
                    if let p = model.papers.first(where: { $0.path == c.path }) {
                        BoardCardView(model: model, card: c, paper: p, data: hub.data[c.path], width: w)
                    } else {
                        Color.clear.frame(width: w, height: 1)
                    }
                case .earlier(let n)?: earlier(n).frame(width: w, alignment: .topLeading).frame(maxHeight: .infinity, alignment: .top)
                case nil: Color.clear.frame(width: w, height: 1)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The lane's head (mockup `.lh`): its sign, name 13 semibold and count 12 secondary over a hairline, 28 tall.
    private func header(_ lane: BoardModel.Lane) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            StatusGlyphView(lane.kind.glyph, size: 13, text: 13)
            Text(lane.kind.rawValue).font(.system(size: 13, weight: .semibold))
            Text("\(lane.count)").font(TypeScale.callout).monospacedDigit().foregroundStyle(Ink.secondary)
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .frame(height: 28)
        .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: Palette.rule)).frame(height: 1) }
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
        .help(ifAny: lane.kind == .yourMove ? lane.detail : nil)
    }

    /// "Earlier · 3": a quiet row that shows the older finished papers in place (not remembered; plan §5 R15).
    private func earlier(_ n: Int) -> some View {
        Button { hub.showEarlier.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    .rotationEffect(.degrees(hub.showEarlier ? 90 : 0))
                Text("Earlier · \(n)")
            }
            .font(TypeScale.callout).foregroundStyle(Ink.secondary)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(hub.showEarlier ? "Hide the papers finished more than eight weeks ago" : "Show the papers finished more than eight weeks ago")
    }
}

/// A paper's card on the board and in the students mode (mockup `.bc`; inset 16): the student and the corner's time,
/// the title (New York 15 semibold, a two-line slot), the bare mini map, and the figure of its state at the bottom.
/// `who` false: without the student (the students mode's block names the student); `state`: with the sign and words a
/// lane says already.
struct BoardCardView: View {
    let model: AppModel
    let card: BoardCard
    let paper: PaperRef
    let data: PaperOverview?
    let width: CGFloat
    var who = true
    var state = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            top
            Text(card.title).font(TypeScale.paperTitle(15)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
                .help(ifAny: card.facts)
                .padding(.top, 8)
            map
            Spacer(minLength: 16)
            BoardFigure(card: card, state: state, broken: model.folderBroken(paper))
        }
        .padding(16)
        .frame(width: width, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .hubCard(radius: 10)
        .contentShape(Rectangle())
        .onTapGesture { model.openPaper(paper.path) }
        .contextMenu { StudentCardMenu(model: model, paper: paper, item: card.item, status: card.status) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibility)
        .accessibilityAddTraits(.isButton)
    }

    private var accessibility: String {
        let parts: [String?] = [card.who, card.title, card.words(state: true), card.corner]
        return parts.compactMap { $0 }.joined(separator: ", ")
    }

    /// The student (12 secondary) and the corner's time at the right.
    private var top: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(who ? card.who : "").lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            if let c = card.corner { Text(c).monospacedDigit().lineLimit(1).fixedSize().help(ifAny: card.cornerHelp) }
        }
        .font(TypeScale.callout).foregroundStyle(Ink.secondary)
        .frame(height: 16)
    }

    @ViewBuilder private var map: some View {
        if card.map, let d = data {
            MiniMapView(map: MiniMap.make(d, maxRows: 8, fold: model.foldParts), width: max(40, width - 32), cell: 10, gap: 6,
                        empty: card.status == .firstDraft)
                .padding(.top, 16)
        }
    }
}

/// A card's figure (mockup `states`): the to-check figure at 17; a sign and its words at 17 (to read, ready, first
/// draft, failed); with the student, finished and no rounds a 13 pt line in label2.
struct BoardFigure: View {
    let card: BoardCard
    var state = false
    var broken = false

    var body: some View {
        switch card.figure {
        case .toCheck(let n):
            // the count over its nouns in a narrow card rather than past its edge ("120 comments + 15 edits")
            ViewThatFits(in: .horizontal) {
                ToCheckFigure(comments: n.comments, edits: n.edits, fill: card.fill ?? 0, size: 17, answered: card.answered)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        StatusGlyphView(.ring(card.fill ?? 0), text: 17)
                        Text("\(n.comments > 0 ? n.comments : n.edits)").font(.system(size: 17, weight: .semibold)).monospacedDigit()
                    }
                    ToCheckFigure.nouns(n.comments, n.edits).font(.system(size: 13)).foregroundStyle(Ink.secondary)
                }
                .lineLimit(1)
                .help(ToCheckFigure.help(n.comments, n.edits) + (card.answered.map { " · " + $0 } ?? ""))
            }
        case .toRead(let n):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                StatusGlyphView(.ring(1), text: 17)
                Text("\(n)").font(TypeScale.title2).monospacedDigit()
                Text(n == 1 ? "paragraph to read" : "paragraphs to read").font(TypeScale.body).foregroundStyle(Ink.secondary)
            }
            .lineLimit(1).fixedSize()
        case .ready: StateFigure(glyph: .ready, main: "Ready to finish", size: 17)
        case .firstDraft: StateFigure(glyph: .ring(0), main: "First draft", size: 17)
        case .failed(let r): StateFigure(glyph: .failed, main: "Build failed", tail: r.map { "Round \($0)" }, size: 17)
        case .withStudent: line(state ? .waiting : nil)
        case .finished: line(state ? .finished : nil)
        case .noRounds: line(.noRounds)
        case .missing: line(nil)
        }
    }

    private func line(_ glyph: StatusGlyph?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if broken {
                Image(systemName: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(Color(nsColor: Palette.danger))
            } else if let glyph {
                StatusGlyphView(glyph, text: 13)
            }
            // two lines in a narrow card rather than cut ("Finished · 2 rounds · 12 of 14 closed")
            Text(card.words(state: state)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .font(TypeScale.body).foregroundStyle(Ink.label2)
    }
}

// MARK: - Rounds in 2026

/// "Rounds in 2026" under the lanes (mockup `timeline()`, `.tl`; BRIEF §8.2): its title and a hairline with the two line
/// styles at the right; a 28 pt lane per paper, its short name at the left (the full title and its rounds' dates in
/// the hover); the months' gridlines and names under the plot and the Today rule. A click on a lane opens the paper.
struct RoundsTimeline: View {
    let model: AppModel
    let timeline: Timeline
    /// "5 rounds came in this week": the title's help.
    var help: String?
    @Environment(\.colorScheme) private var scheme

    static let lane: CGFloat = 28, labels: CGFloat = 168, axis: CGFloat = 24

    var body: some View {
        let ink = MapInk(dark: scheme == .dark)
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(timeline.title).font(.system(size: 13, weight: .semibold)).help(ifAny: help)
                Spacer(minLength: 8)
                legend(ink)
            }
            .lineLimit(1)
            .frame(height: 28)
            .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: Palette.rule)).frame(height: 1) }
            GeometryReader { g in
                let plot = max(60, g.size.width - Self.labels - 16)
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, _ in draw(&ctx, plot: plot, ink: ink) }
                    VStack(spacing: 0) {
                        ForEach(timeline.lanes, id: \.path) { l in
                            HStack(spacing: 0) {
                                Text(l.short).font(TypeScale.body).lineLimit(1).truncationMode(.tail)
                                    .foregroundStyle(l.finished != nil ? Ink.secondary : Ink.label2)
                                    .frame(width: Self.labels - 12, alignment: .leading)
                                Spacer(minLength: 0)
                            }
                            .frame(height: Self.lane)
                            .contentShape(Rectangle())
                            .onTapGesture { model.openPaper(l.path) }
                            .help(l.hover)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(l.hover)
                            .accessibilityAddTraits(.isButton)
                        }
                    }
                }
            }
            .frame(height: CGFloat(timeline.lanes.count) * Self.lane + Self.axis)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(timeline.title)
    }

    /// Two items: a solid 14 pt line "with you", a dotted one "with the student".
    private func legend(_ ink: MapInk) -> some View {
        HStack(spacing: 16) {
            ForEach([false, true], id: \.self) { dotted in
                HStack(spacing: 6) {
                    Path { p in p.move(to: CGPoint(x: 1, y: 1)); p.addLine(to: CGPoint(x: 13, y: 1)) }
                        .stroke(ink.color(.ink), style: Self.line(dotted: dotted)).frame(width: 14, height: 2)
                    Text(dotted ? "with the student" : "with you")
                }
            }
        }
        .font(TypeScale.callout).foregroundStyle(Ink.secondary)
        .fixedSize()
    }

    /// A 2 pt line, solid or dotted (round dots 2 apart, as CSS's dotted).
    static func line(dotted: Bool) -> StrokeStyle {
        dotted ? StrokeStyle(lineWidth: 2, lineCap: .round, dash: [0.01, 4]) : StrokeStyle(lineWidth: 2, lineCap: .butt)
    }

    private func draw(_ ctx: inout GraphicsContext, plot: CGFloat, ink: MapInk) {
        let t = timeline, lx = Self.labels
        func x(_ d: Double) -> CGFloat { lx + CGFloat(d / t.days) * plot }
        let bottom = CGFloat(t.lanes.count) * Self.lane
        let todayX = x(t.today)
        func vline(_ at: CGFloat, _ role: MapRole) {
            var p = Path()
            p.move(to: CGPoint(x: at, y: 0))
            p.addLine(to: CGPoint(x: at, y: bottom))
            ctx.stroke(p, with: .color(ink.color(role)), lineWidth: 1)
        }
        for (name, d) in t.months {
            vline(x(d), .rule)
            // a month's name gives way to Today's
            if abs(x(d) + 14 - todayX) > 34 {
                ctx.draw(Text(name).font(TypeScale.small).foregroundColor(ink.color(.secondary)),
                         at: CGPoint(x: x(d) + 4, y: bottom + Self.axis - 7), anchor: .leading)
            }
        }
        vline(todayX, .today)
        ctx.draw(Text("Today").font(TypeScale.small).foregroundColor(ink.color(.secondary)),
                 at: CGPoint(x: todayX, y: bottom + Self.axis - 7), anchor: .center)
        func seg(_ a: Double, _ b: Double, y: CGFloat, dotted: Bool, role: MapRole, in c: inout GraphicsContext) {
            var p = Path()
            p.move(to: CGPoint(x: x(a), y: y))
            p.addLine(to: CGPoint(x: max(x(b), x(a) + 0.1), y: y))
            c.stroke(p, with: .color(ink.color(role)), style: Self.line(dotted: dotted))
        }
        for (i, l) in t.lanes.enumerated() {
            let y = CGFloat(i) * Self.lane + Self.lane / 2
            ctx.drawLayer { c in
                if l.finished != nil { c.opacity = 0.65 }
                for s in l.student { seg(s.lowerBound, s.upperBound, y: y, dotted: true, role: .ink, in: &c) }
                for s in l.you { seg(s.lowerBound, s.upperBound, y: y, dotted: false, role: .ink, in: &c) }
                if let o = l.open { seg(o.lowerBound, o.upperBound, y: y, dotted: false, role: .attention, in: &c) }
                for m in l.marks {
                    let at = CGPoint(x: x(m.day), y: y)
                    switch m.kind {
                    case .imported: c.fill(Path(ellipseIn: CGRect(x: at.x - 4, y: y - 4, width: 8, height: 8)), with: .color(ink.color(.ink)))
                    case .yourMove: glyph(&c, .ring(0), at: at, size: 12, ink: ink)
                    case .ready: glyph(&c, .ready, at: at, size: 12, ink: ink)
                    case .failed: glyph(&c, .failed, at: at, size: 12, ink: ink)
                    }
                }
                if let f = l.finished {
                    let last = max(f, l.you.map(\.upperBound).max() ?? f)
                    glyph(&c, .finished, at: CGPoint(x: x(last) + 12, y: y), size: 12, ink: ink, disc: false)
                }
            }
        }
    }

    /// A sign of `size` centred at `at` in its colour (`StatusGlyph.color`), on a disc of the page's colour (so the line
    /// under it does not show through).
    private func glyph(_ c: inout GraphicsContext, _ g: StatusGlyph, at: CGPoint, size: CGFloat, ink: MapInk, disc: Bool = true) {
        let r = CGRect(x: at.x - size / 2, y: at.y - size / 2, width: size, height: size)
        if disc { c.fill(Path(ellipseIn: r), with: .color(ink.color(.content))) }
        let k = size / 20, t = CGAffineTransform(translationX: r.minX, y: r.minY).scaledBy(x: k, y: k)
        let role: MapRole = { switch g { case .ring: return .attention; case .ready: return .accent; case .failed: return .label2
                                         default: return .secondary } }()
        let color = ink.color(role)
        func stroke(_ p: Path, _ w: CGFloat) {
            c.stroke(p.applying(t), with: .color(color), style: StrokeStyle(lineWidth: w * k, lineCap: .round, lineJoin: .round))
        }
        switch g {
        case .ring(let f): c.fill(RingShape(fill: f).path(in: r), with: .color(color))
        case .ready:
            c.fill(Path(ellipseIn: r.insetBy(dx: 0.8 * k, dy: 0.8 * k)), with: .color(color))
            c.stroke(Glyphs.check(ready: true).applying(t), with: .color(.white), style: StrokeStyle(lineWidth: 2.6 * k, lineCap: .round, lineJoin: .round))
        case .failed: stroke(Glyphs.octagon, 1.7)
        case .finished: stroke(Glyphs.check(ready: false), 2.1)
        default: break
        }
    }
}
