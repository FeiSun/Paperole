import SwiftUI

// A student's page (UI v4 step 5; design/ui-v4 BRIEF §4 01/02 and §7, mockup `studentMaya`, `studentSara`,
// `studentHead`; mac/UX.md §40.5): the header with the student's figures, an action card for each paper that waits on
// you, compact cards for the others, on a 12-column grid; the tiles under them (step 6, StudentTiles.swift).

/// What the student page shows, decided from the data alone (tested without views): the header's figures, the cards
/// and where each goes on the grid, and the tiles.
struct StudentPageModel: Equatable {
    struct Figure: Equatable {
        var value: String
        var label: String
        var help: String?
    }

    /// Well done (the praise tag): how many, and the latest's words with where it was written.
    struct Star: Equatable {
        var count: Int
        var note: String?
        /// "Curriculum Signals · Round 1 · p.4": the round it was written in, its page as printed.
        var source: String?
    }

    struct Header: Equatable {
        /// "since Sep 8": the first round's day.
        var since: String?
        /// "2 papers | 4 rounds | 30 comments", only with more than one paper (with one they would repeat its card).
        var figures: [Figure]
        var star: Star?
    }

    enum Kind: String { case action, compact, wide }

    struct Card: Equatable, Identifiable {
        var path: String
        var kind: Kind
        var status: PaperStatus?
        var figures: PaperFigures?
        /// Your move: the figure of the paper's state (the paper page's), its button and whether it is the page's
        /// primary one (the oldest only).
        var header: PaperHeader?
        var item: MoveItem?
        var primary = false
        /// Your move: "Round 2 · came in 2 days ago", its help "Came in Wed, Oct 28 · 2 rounds since Oct 14".
        var meta: String?
        var metaHelp: String?
        /// The others: "Finished Sep 23", "With Sara · 6 d"; its help "Round 1 sent back Sat, Oct 24 · 1 round since
        /// Oct 20", "2 rounds since Sep 8" (the rounds and the first day).
        var line: String?
        var lineHelp: String?
        /// The others' figures: comments, closed and open ("left open" once finished), or comments alone.
        var columns: [Figure] = []
        var id: String { path }

        /// The card's figure in words (the debug hook): "14 comments + 2 edits", "First draft · came in 1 d", "16
        /// comments · 12 closed · 4 left open".
        var words: String {
            guard kind == .action else { return columns.map { "\($0.value) \($0.label)" }.joined(separator: " · ") }
            guard let h = header else { return "" }
            switch h.figure {
            case .toCheck(let c): return HubText.figure(c.comments, c.edits) + (h.closed.map { " · \($0) closed" } ?? "")
            case .firstDraft: return "First draft" + (figures?.dayCounter.map { " · came in " + $0 } ?? "")
            case .failed: return "Build failed" + (item?.round.map { " · Round \($0)" } ?? "")
            default: return h.words
            }
        }
    }

    enum Slot: Equatable {
        case card(Int)
        /// Beside a student's single paper: Turnaround.
        case turnaround
    }

    struct Cell: Equatable {
        var slot: Slot
        /// Of 12 columns; every card takes 12 below 900 pt.
        var span: Int
    }

    var header: Header
    var cards: [Card]
    var grid: [[Cell]]
    var tiles: StudentTiles
    /// The tiles under the cards, in pairs (Turnaround left out when it is beside a single paper).
    var tileKinds: [StudentTiles.Kind]

    /// `landColumns`: the most columns By section has room for.
    static func make(_ group: StudentGroup, statuses: [String: PaperStatus], summaries: [String: PaperSummary],
                     data: [String: PaperOverview], stats: StudentStats?, today: Date, catalog: TagCatalog = TagCatalog(),
                     landColumns: Int = 8, calendar: Calendar = .current) -> StudentPageModel {
        let papers = group.papers
        // the header
        let rounds = papers.compactMap { data[$0.path]?.rounds.count }.reduce(0, +)
        let comments = stats?.comments ?? papers.compactMap { data[$0.path]?.threads?.comments }.reduce(0, +)
        let first = papers.compactMap { Hierarchy.date(data[$0.path]?.rounds.first?.created) }.min()
        var figures: [Figure] = []
        if papers.count > 1 {
            figures.append(Figure(value: "\(papers.count)", label: "papers"))
            if rounds > 0 { figures.append(Figure(value: "\(rounds)", label: rounds == 1 ? "round" : "rounds")) }
            if comments > 0 { figures.append(Figure(value: "\(comments)", label: comments == 1 ? "comment" : "comments")) }
        }
        var star: Star?
        if let p = stats?.tags?.praise, let n = p.comments, n > 0 {
            let l = p.latest, d = l?.path.flatMap { data[$0] }
            let title = l?.path.flatMap { path in papers.first { $0.path == path }?.title } ?? d?.paper?.title
            let round = l?.id.flatMap { d?.comment($0)?.createdRound } ?? l?.round
            let source = [title.map(ShortTitle.of), round.map { "Round \($0)" }, l?.page.map { "p.\($0 + 1)" }]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            star = Star(count: n, note: (l?.note ?? "").isEmpty ? nil : l?.note, source: source.isEmpty ? nil : source)
        }
        let header = Header(since: first.map { "since " + HubText.format($0, "MMM d", calendar.timeZone) }, figures: figures, star: star)

        // the cards: an action card for each paper that waits on you, oldest first (plan §5 R4), then the others
        let moves = Hierarchy.yourMove(papers, status: { statuses[$0.path] }, data: data, summaries: summaries)
        // the old card's "4 rounds since Sep 8", in the hovers; "1 round since Oct 20" too, but not after an action
        // card's "Came in" of the same day
        func since(_ d: PaperOverview?, from least: Int = 1) -> String? {
            guard let d, d.rounds.count >= least else { return nil }
            return count(d.rounds.count, "round")
                + (Hierarchy.date(d.rounds.first?.created).map { " since " + HubText.format($0, "MMM d", calendar.timeZone) } ?? "")
        }
        func joined(_ parts: String?...) -> String? {
            let s = parts.compactMap { $0 }.joined(separator: " · ")
            return s.isEmpty ? nil : s
        }
        var cards: [Card] = []
        for (i, m) in moves.enumerated() {
            let d = data[m.paper.path], created = Hierarchy.date(d?.latest?.created)
            var c = Card(path: m.paper.path, kind: .action, status: m.status)
            c.figures = PaperFigures.make(m.status, summaries[m.paper.path], d, today: today, calendar: calendar)
            c.header = PaperHeader.make(m.status, summaries[m.paper.path], d)
            c.item = m
            c.primary = i == 0
            c.meta = [m.round.map { "Round \($0)" }, created.map { HubText.cameIn($0, today: today, calendar: calendar) }]
                .compactMap { $0 }.joined(separator: " · ")
            c.metaHelp = joined(created.map { HubText.hoverCameIn($0, calendar: calendar) }, since(d, from: 2))
            cards.append(c)
        }
        let single = papers.count == 1 && moves.isEmpty
        for p in papers where !moves.contains(where: { $0.paper.path == p.path }) {
            let d = data[p.path], s = statuses[p.path]
            var c = Card(path: p.path, kind: single ? .wide : .compact, status: s)
            c.figures = PaperFigures.make(s, summaries[p.path], d, today: today, calendar: calendar)
            c.line = s.map { HubText.status($0, round: d?.latest?.n ?? summaries[p.path]?.round, student: p.student,
                                             since: d?.latest?.closedAt, today: today, calendar: calendar) }
            if s == .waiting {
                c.lineHelp = joined(c.figures?.hover, since(d))
            } else if s?.isFinished == true {
                c.lineHelp = since(d)
            }
            if let t = c.figures?.totals { c.columns = columns(t, finished: s?.isFinished == true) }
            cards.append(c)
        }

        // the grid: each action card (8) with a compact card (4) beside it while one is left, then the compact cards
        // three to a row; a single paper (8) with Turnaround (4), or the width without it when it is not waiting
        let tiles = StudentTiles.make(group, stats: stats, data: data, statuses: statuses, catalog: catalog,
                                      landColumns: landColumns, calendar: calendar)
        let beside = papers.count == 1 && tiles.turnaround != nil
        var grid: [[Cell]] = []
        if beside {
            grid = [[Cell(slot: .card(0), span: 8), Cell(slot: .turnaround, span: 4)]]
        } else if single {
            grid = [[Cell(slot: .card(0), span: 12)]]
        } else {
            var rest = Array(moves.count..<cards.count)
            for a in 0..<moves.count {
                var row = [Cell(slot: .card(a), span: 8)]
                if !rest.isEmpty { row.append(Cell(slot: .card(rest.removeFirst()), span: 4)) }
                grid.append(row)
            }
            for i in stride(from: 0, to: rest.count, by: 3) {
                grid.append(rest[i..<min(i + 3, rest.count)].map { Cell(slot: .card($0), span: 4) })
            }
        }
        return StudentPageModel(header: header, cards: cards, grid: grid, tiles: tiles,
                                tileKinds: tiles.shown.filter { !(beside && $0 == .turnaround) })
    }

    /// Comments, closed (help: resolved · kept as is) and open; comments alone while nothing has closed and every
    /// comment is open (Sara's Round 1 with her: BRIEF §7), and in Round 1 (`Totals` has no closed then).
    static func columns(_ t: PaperFigures.Totals, finished: Bool) -> [Figure] {
        var out = [Figure(value: "\(t.comments)", label: t.comments == 1 ? "comment" : "comments")]
        guard let c = t.closed, let o = t.open, !(c == 0 && o == t.comments) else { return out }
        out.append(Figure(value: "\(c)", label: "closed", help: "\(t.resolved ?? 0) resolved · \(t.kept ?? 0) kept as is"))
        out.append(Figure(value: "\(o)", label: finished ? "left open" : "open"))
        return out
    }
}

extension AppModel {
    /// The student page's model from what the hierarchy has loaded.
    func studentPage(_ g: StudentGroup, today: Date = Date(), landColumns: Int = 8) -> StudentPageModel {
        let statuses = Dictionary(g.papers.compactMap { p in status(of: p).map { (p.path, $0) } }, uniquingKeysWith: { a, _ in a })
        return StudentPageModel.make(g, statuses: statuses, summaries: summaries, data: hubModel.data,
                                     stats: hubModel.stats(for: g.papers.map(\.path)), today: today, catalog: tags.catalog,
                                     landColumns: landColumns)
    }
}

// MARK: - The page

/// A student's page: the header, the cards on the grid (32 below it), then the tiles 16 below them.
struct StudentPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var hub: HubModel
    let key: String
    let width: CGFloat

    var body: some View {
        if let g = model.studentGroups.first(where: { $0.key == key }) {
            content(g)
        } else {
            Text("This student has no papers in the list.").font(.system(size: 13)).foregroundStyle(Ink.secondary)
        }
    }

    private func content(_ g: StudentGroup) -> some View {
        let stats = hub.stats(for: g.papers.map(\.path))
        // By section's columns that fit beside the papers' names, each at least 56 pt and 4 apart
        let chart = (width < 900 ? width : StudentCardGrid.width(6, of: width)) - 48
        let page = model.studentPage(g, landColumns: max(4, Int((chart - 140) / 60)))
        return VStack(alignment: .leading, spacing: 0) {
            StudentHeader(model: model, hub: hub, group: g, header: page.header)
                .zIndex(1)  // the ★'s hover tag over the cards
            StudentCardGrid(model: model, hub: hub, group: g, page: page, width: width)
                .padding(.top, 32)
            if let stats {
                StudentTileGrid(model: model, hub: hub, group: g, stats: stats, tiles: page.tiles, kinds: page.tileKinds, width: width)
                    .padding(.top, StudentCardGrid.gutter)
            } else {
                Text(hub.status == .loading ? "Reading the papers…" : "The numbers come with the engine’s overview.")
                    .font(.system(size: 13)).foregroundStyle(Ink.secondary).padding(.top, 24)
            }
        }
    }
}

/// The header (mockup `.sh`): the avatar 44, the name 26 semibold over "since Sep 8"; at the right, top-aligned, the
/// student's figures on the name's and the since line's baselines, hairlines between, and ★ Well done.
struct StudentHeader: View {
    let model: AppModel
    let hub: HubModel
    let group: StudentGroup
    let header: StudentPageModel.Header

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Avatar(name: group.name, size: 44, flat: true)
                .contextMenu { menu }
            // the name's and the since line's baselines are the figures' and their labels' (spacings 2 and 5)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name).font(PageType.title).lineLimit(1)
                    if let s = header.since { Text(s).font(TypeScale.body).foregroundStyle(Ink.secondary) }
                }
                .contentShape(Rectangle())
                .contextMenu { menu }  // as the sidebar's student row (DATA.md §0.2), with Tag Comments…
                Spacer(minLength: 16)
                figures
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// The sidebar's student menu after Tag Comments… (the old empty Topics' link), while no comment is tagged.
    @ViewBuilder private var menu: some View {
        if (hub.stats(for: group.papers.map(\.path))?.tags?.tagged ?? 0) == 0 {
            Button("Tag Comments…") { model.openTagComments(student: group.key) }
            Divider()
        }
        StudentMenu(model: model, group: group)
    }

    private var figures: some View {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                ForEach(Array(header.figures.enumerated()), id: \.offset) { i, f in
                    column(i, last: i == header.figures.count - 1 && header.star == nil) {
                        Text(f.value).font(TypeScale.title2).monospacedDigit().foregroundStyle(Ink.label)
                    } label: {
                        Text(f.label)
                    }
                    .help(ifAny: f.help)
                }
                if let s = header.star {
                    column(header.figures.count, last: true) {
                        WellDoneFigure(model: model, hub: hub, group: group, star: s)
                    } label: {
                        Text("well done")
                    }
                }
            }
    }

    /// A figure over its label (12 secondary), right-aligned, 20 apart with a hairline between.
    private func column<V: View, L: View>(_ i: Int, last: Bool, @ViewBuilder value: () -> V, @ViewBuilder label: () -> L) -> some View {
        VStack(alignment: .trailing, spacing: 5) {
            value()
            label().font(TypeScale.callout).foregroundStyle(Ink.secondary)
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.leading, i == 0 ? 0 : 20)
        .padding(.trailing, last ? 0 : 20)
        .overlay(alignment: .leading) {
            if i > 0 { Rectangle().fill(Color(nsColor: Palette.rule)).frame(width: 1).padding(.top, 2) }
        }
    }
}

/// "★ 3" (the star in Sage): its hover the latest Well done note in New York italic with where it was written; a
/// click lists the praised comments (`StudentTagPanel`, as Topics' rows list theirs).
struct WellDoneFigure: View {
    let model: AppModel
    let hub: HubModel
    let group: StudentGroup
    let star: StudentPageModel.Star
    @State private var hovering = false
    @State private var tag = false
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                StatusGlyphView(.wellDone, size: 14, text: 17)
                Text("\(star.count)").font(TypeScale.title2).monospacedDigit().foregroundStyle(Ink.label)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in
            hovering = h
            if !h { tag = false; return }
            // as a help tag: after a moment, and not while the list is open
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { if hovering && !open { tag = true } }
        }
        .overlay(alignment: .topTrailing) {
            if tag && !open, star.note != nil || star.source != nil {
                note.fixedSize().offset(y: 46).allowsHitTesting(false)
            }
        }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ScrollView {
                StudentTagPanel(model: model, list: StudentTagList.make("praise", papers: group.papers.map { ($0.path, $0.title) },
                                                                         data: hub.data, catalog: model.tags.catalog))
                    .padding(16)
            }
            .frame(width: 480)
            .frame(maxHeight: 420)
        }
        .accessibilityLabel(count(star.count, "comment") + " well done")
        .accessibilityHint([star.note, star.source].compactMap { $0 }.joined(separator: ", "))
    }

    /// The latest note, drawn as a help tag (one can't be styled): its words in New York italic, then where.
    private var note: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let n = star.note {
                Text(n).font(.system(size: 13, design: .serif).italic()).foregroundStyle(Ink.label)
                    .frame(maxWidth: 320, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
            if let s = star.source { Text(s).font(TypeScale.small).foregroundStyle(Ink.secondary) }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: Palette.float))
            .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: Palette.floatLine), lineWidth: 0.5)))
    }
}

// MARK: - The cards

/// The cards on a 12-column grid, 16 apart, each row's cards one height; below 900 pt every card takes the width.
struct StudentCardGrid: View {
    let model: AppModel
    let hub: HubModel
    let group: StudentGroup
    let page: StudentPageModel
    let width: CGFloat

    static let gutter: CGFloat = 16

    /// The width of `span` columns of 12 in `width`.
    static func width(_ span: Int, of width: CGFloat) -> CGFloat {
        let col = (width - 11 * gutter) / 12
        return CGFloat(span) * col + CGFloat(span - 1) * gutter
    }

    var body: some View {
        let narrow = width < 900
        let rows: [[StudentPageModel.Cell]] = narrow
            ? page.grid.flatMap { $0.map { [StudentPageModel.Cell(slot: $0.slot, span: 12)] } }
            : page.grid
        VStack(alignment: .leading, spacing: Self.gutter) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: Self.gutter) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, c in cell(c, width: Self.width(c.span, of: width)) }
                }
                .fixedSize(horizontal: false, vertical: true)  // one height for the row's cards
            }
        }
    }

    @ViewBuilder private func cell(_ c: StudentPageModel.Cell, width w: CGFloat) -> some View {
        switch c.slot {
        case .card(let i):
            let card = page.cards[i]
            if let p = group.papers.first(where: { $0.path == card.path }) {
                Group {
                    if card.kind == .action {
                        ActionCard(model: model, card: card, paper: p, data: hub.data[p.path], width: w)
                    } else {
                        PaperCardV4(model: model, card: card, paper: p, data: hub.data[p.path], width: w)
                    }
                }
                .contextMenu { StudentCardMenu(model: model, paper: p, item: card.item, status: card.status) }
            }
        case .turnaround:
            if let stats = hub.stats(for: group.papers.map(\.path)) {
                StudentTileView(model: model, hub: hub, group: group, stats: stats, tiles: page.tiles, kind: .turnaround, width: w)
            }
        }
    }
}

/// A paper that waits on you (mockup `.act`): the sign and "Your move" with the button at the right; the key page
/// beside the title and when the round came in; the mini map, and at its right the figure of the paper's state at 22
/// (the page's one) with the response bar under it.
struct ActionCard: View {
    let model: AppModel
    let card: StudentPageModel.Card
    let paper: PaperRef
    let data: PaperOverview?
    let width: CGFloat

    var body: some View {
        let inner = width - 48
        let side = inner >= 300 + 48 + 160  // the figure beside the map, else under it
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if let f = card.figures { StatusGlyphView(f.glyph, text: 17) }
                Text("Your move").font(TypeScale.title2).lineLimit(1)
                Spacer(minLength: 12)
                if let item = card.item { button(item) }
            }
            .frame(height: 28)
            HStack(alignment: .top, spacing: 16) {
                KeyPageStack(thumbs: model.thumbnails, paper: paper.path, data: data, width: 44, depth: 1, marks: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(PaperCardV4.title(paper)).font(TypeScale.paperTitle(17)).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let m = card.meta, !m.isEmpty {
                        Text(m).font(TypeScale.body).foregroundStyle(Ink.secondary).lineLimit(1).help(ifAny: card.metaHelp)
                    }
                }
            }
            .padding(.top, 16)
            if side {
                HStack(alignment: .top, spacing: 48) {
                    map(inner - 348).padding(.top, 9)
                    figure.frame(width: 300, alignment: .leading)
                }
                .padding(.top, 24)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    map(inner)
                    figure
                }
                .padding(.top, 24)
            }
        }
        .padding(24)
        .frame(width: width, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .hubCard(radius: 10)
        .contentShape(Rectangle())
        .onTapGesture { model.openPaper(paper.path) }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func button(_ item: MoveItem) -> some View {
        let b = Button(MoveRow.title(item)) { model.moveAction(item) }.help(MoveRow.help(item)).controlSize(.large)
        if card.primary { b.buttonStyle(.borderedProminent) } else { b.buttonStyle(.bordered) }
    }

    @ViewBuilder private func map(_ w: CGFloat) -> some View {
        if let d = data, !d.rounds.isEmpty {
            MiniMapView(map: MiniMap.make(d, maxRows: 8, fold: model.foldParts), width: max(40, w), cell: 10, gap: 6,
                        empty: card.status == .firstDraft)
        }
    }

    /// The state's figure (plan step 5's table): to check with the response bar; first draft, to read, ready, failed.
    @ViewBuilder private var figure: some View {
        if let h = card.header {
            switch h.figure {
            // the paper page's figure, closed and the response bar, without "to check" (the top row says Your move)
            case .toCheck: PaperHeaderFigure(header: h, round: card.item?.round, tail: nil)
            case .toRead(let n): StateFigure(glyph: h.glyph, main: "\(n)", tail: n == 1 ? "paragraph to read" : "paragraphs to read")
            case .ready: StateFigure(glyph: h.glyph, main: "Ready to finish")
            case .firstDraft: StateFigure(glyph: h.glyph, main: "First draft", tail: card.figures?.dayCounter.map { "· came in " + $0 })
            case .failed: StateFigure(glyph: h.glyph, main: "Build failed", tail: card.item?.round.map { "· Round \($0)" })
            case .totals: EmptyView()
            }
        }
    }
}

/// A sign and its words at 22 (the action card's other states; 17 on the board), an optional tail at 13 secondary.
struct StateFigure: View {
    let glyph: StatusGlyph
    let main: String
    var tail: String?
    var size: CGFloat = 22

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            StatusGlyphView(glyph, text: size)
            Text(main).font(.system(size: size, weight: .semibold))
            if let tail { Text(tail).font(TypeScale.body).foregroundStyle(Ink.secondary) }
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// A paper that does not wait on you (mockup `.pc`; `.wc` for a single one, 8 columns with its figures beside the
/// map): the status line, the key page beside the title, the mini map, the figures at the bottom.
struct PaperCardV4: View {
    let model: AppModel
    let card: StudentPageModel.Card
    let paper: PaperRef
    let data: PaperOverview?
    let width: CGFloat

    static func title(_ p: PaperRef) -> String { p.title.isEmpty ? (p.path as NSString).lastPathComponent : p.title }

    var body: some View {
        let inner = width - 48
        let side = card.kind == .wide && inner >= 276 + 48 + 160
        let gone = model.missingWords(paper)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if model.folderBroken(paper) {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(Color(nsColor: Palette.danger))
                } else if let f = card.figures {
                    StatusGlyphView(f.glyph, text: 13)
                }
                Text(gone ?? card.line ?? "").lineLimit(1).truncationMode(.tail)
            }
            .font(TypeScale.body).foregroundStyle(Ink.label2)
            .help(ifAny: gone == nil ? card.lineHelp : nil)
            .frame(height: 28, alignment: .leading)
            HStack(alignment: .top, spacing: 16) {
                KeyPageStack(thumbs: model.thumbnails, paper: paper.path, data: data, width: 44, depth: 1, marks: true)
                    .opacity(model.missingPapers.contains(paper.path) ? 0.35 : 1)  // no page to draw: not a page loading
                Text(Self.title(paper)).font(TypeScale.paperTitle(15)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(card.status?.isFinished == true ? Ink.label2 : Ink.label)
            }
            .frame(minHeight: 58, alignment: .topLeading)
            .padding(.top, 16)
            if side {
                HStack(alignment: .top, spacing: 48) {
                    map(inner - 276 - 48).padding(.top, 6)
                    figures.frame(width: 276, alignment: .leading)
                }
                .padding(.top, 21)
            } else {
                map(inner).padding(.top, 21)
                Spacer(minLength: 16)
                figures
            }
        }
        .padding(24)
        .frame(width: width, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .hubCard(radius: 10)
        .contentShape(Rectangle())
        .onTapGesture { model.openPaper(paper.path) }
        .help("Open \(paper.title)’s overview")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder private func map(_ w: CGFloat) -> some View {
        if let d = data, !d.rounds.isEmpty {
            MiniMapView(map: MiniMap.make(d, maxRows: 8, fold: model.foldParts), width: max(40, w), cell: 10, gap: 6)
        }
    }

    @ViewBuilder private var figures: some View {
        if !card.columns.isEmpty { FigureColumns(figures: card.columns.map { ($0.value, $0.label, $0.help) }) }
    }
}

/// A card's context menu (the student page's and the board's): what its button does first for a paper that waits on
/// you, New Round… (Start Round 1…) for one with the student (or without rounds), then the sidebar's paper menu.
struct StudentCardMenu: View {
    let model: AppModel
    let paper: PaperRef
    let item: MoveItem?
    let status: PaperStatus?

    var body: some View {
        let gone = model.missingPapers.contains(paper.path)
        if let item, item.status != .ready {
            Button(MoveRow.title(item)) { model.moveAction(item) }.disabled(gone)
            Divider()
        } else if status == .waiting || status == .noRounds {
            Button(status == .noRounds ? "Start Round 1…" : "New Round…") { model.startRound(paper.path) }.disabled(gone)
            Divider()
        }
        PaperMenu(model: model, paper: paper, status: status)
    }
}
