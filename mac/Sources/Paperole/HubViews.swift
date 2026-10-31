import AppKit
import SwiftUI

/// The hierarchy's pages (OVERVIEW-v2 §3.1–3.2; UX.md §22, §40.5–§40.6): All Students (Board or Students), Your Move,
/// and a student's page. Each scrolls on the panel's colour, inset 32 pt, with the toolbar's ‹ ›; All Students keeps its
/// title there, with Board | Students in the middle.
struct HubScreen: View {
    @ObservedObject var model: AppModel
    @ObservedObject var hub: HubModel
    let page: HubPage

    static let inset: CGFloat = 32

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width - 2 * Self.inset, 300)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    switch page {
                    case .allStudents: AllStudentsPage(model: model, hub: hub, width: width)
                    case .yourMove: YourMovePage(model: model, hub: hub, width: width)
                    case .student(let k): StudentPage(model: model, hub: hub, key: k, width: width)
                    }
                    PageHelpLink(model: model, topic: HelpTopic.of(hub: page, level: nil))
                }
                .padding(Self.inset)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(HubScrollProbe(hub: hub))
            }
        }
        .background(Color(nsColor: Palette.panel))
        .foregroundStyle(Ink.label)
        .navigationTitle(title)
        .navigationSubtitle("")
        .modifier(OwnToolbarTitle())
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 8) {
                    HistoryButtons(model: model)
                    // the page's only title on All Students; the other pages have their own (UI v4); with the
                    // numbers' help as Board | Students
                    if #available(macOS 15, *), page == .allStudents {
                        Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1).padding(.leading, 4).help(allCounts)
                    }
                }
            }
            if page == .allStudents {
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: $model.allStudentsView) {
                        Text("Board").tag(AllStudentsView.board)
                        Text("Students").tag(AllStudentsView.students)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    // the old subtitle's numbers (plan §5 R12): the students are counted nowhere else
                    .help(allCounts)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Spacer()
                if model.busy || hub.status == .loading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(model.busy && !model.progress.isEmpty ? model.progress : "Reading the papers…").lineLimit(1)
                            .frame(maxWidth: 240, alignment: .leading)
                    }
                }
            }
        }
        .sheet(item: Binding(get: { model.mappingHeadings.map(SheetID.init) }, set: { model.mappingHeadings = $0?.id })) { s in
            MapHeadingsSheet(model: model, key: s.id)
        }
    }

    /// "3 students · 4 papers · 9 rounds" (plan §5 R12): the students are counted nowhere else.
    private var allCounts: String {
        HubText.allCounts(students: model.studentGroups.filter { !$0.unassigned }.count, papers: model.papers.count,
                          rounds: model.papers.compactMap { hub.data[$0.path]?.rounds.count ?? model.summaries[$0.path]?.round }.reduce(0, +))
    }

    private var title: String {
        switch page {
        case .allStudents: return "All Students"
        case .yourMove: return "Your Move"
        case .student(let k): return model.studentGroups.first { $0.key == k }?.name ?? "Student"
        }
    }
}

/// The page's scroll view, for Back (`HubModel.scrollView`).
struct HubScrollProbe: NSViewRepresentable {
    let hub: HubModel

    final class Probe: NSView {
        weak var hub: HubModel?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
        }
        func attach() {
            MainActor.assumeIsolated {
                guard window != nil, let sv = enclosingScrollView, hub?.scrollView !== sv else { return }
                hub?.scrollView = sv
            }
        }
    }

    func makeNSView(context: Context) -> Probe {
        let p = Probe()
        p.hub = hub
        return p
    }

    func updateNSView(_ p: Probe, context: Context) {
        p.hub = hub
        DispatchQueue.main.async { p.attach() }
    }
}

// MARK: - Shared pieces

extension View {
    /// The hierarchy's cards (the mockup's `--card`): white (a lighter grey in Dark Mode) with a soft shadow, radius 12.
    func hubCard(radius: CGFloat = 12) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius)
                .fill(Color(nsColor: Palette.card))
                .shadow(color: .black.opacity(0.07), radius: 1.5, y: 0.5)
                .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Color(nsColor: Palette.cardLine), lineWidth: 1))
        )
    }
}

/// A student's initials in a circle.
struct Avatar: View {
    let name: String
    var size: CGFloat = 36
    /// UI v4 (mockup `.sh .av`): the `fill` ground without a ring, the initials 15 semibold.
    var flat = false

    var body: some View {
        Text(StudentName.initials(name))
            .font(flat ? .system(size: 15, weight: .semibold) : .system(size: size * 0.36, weight: .medium))
            .foregroundStyle(Ink.secondary)
            .frame(width: size, height: size)
            .background(Circle().fill(Color(nsColor: flat ? Palette.fill : Palette.chipFill)))
            .overlay(Circle().strokeBorder(flat ? .clear : Color(nsColor: Palette.rule), lineWidth: 1))
            .accessibilityHidden(true)
    }
}

/// The paper's key page (FEATURES OV-3, `MapRules.keyPage`), the latest round's on top of up to two earlier rounds'
/// (the mockup's `stackHTML`), from the thumbnails' cache; a blank page while it is drawn.
struct KeyPageStack: View {
    @ObservedObject var thumbs: ThumbnailStore
    let paper: String
    let data: PaperOverview?
    let width: CGFloat
    var depth = 3
    /// The key page's comment marks in their colours (UI v4, BRIEF §8.1: the thumbnail as the paper's icon).
    var marks = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let built = (data?.rounds ?? []).filter { $0.pdf != nil && ($0.build?.pages ?? 0) > 0 && !$0.failed }
        let shown = Array(built.suffix(depth))
        // the key page: the engine's (the advisor's choice followed into the latest round, else the busiest; TAGS.md §7)
        let k = data?.keyPage.flatMap { $0.round == shown.last?.n ? $0.page : nil } ?? MapRules.keyPage(shown.last)
        let aspect = thumbs.aspect(pdf: shown.last?.pdf)
        let h = width / aspect, n = max(1, shown.count)
        ZStack(alignment: .topLeading) {
            if shown.isEmpty {
                page(nil, page: 0, h: h)
                    .offset(y: 0)
            }
            ForEach(Array(shown.enumerated()), id: \.offset) { i, r in
                let back = shown.count - 1 - i  // 0: the latest
                page(r.pdf, page: min(k, max(0, (r.build?.pages ?? 1) - 1)), h: h, marks: marks && back == 0 ? r : nil)
                    .opacity(back == 0 ? 1 : max(0.2, 0.55 - Double(back - 1) * 0.2))
                    .offset(x: CGFloat(back) * 6, y: CGFloat(n - 1 - back) * 3)
            }
        }
        .frame(width: width + CGFloat(n - 1) * 6, height: h + CGFloat(n - 1) * 3, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    private func page(_ pdf: String?, page: Int, h: CGFloat, marks round: PaperOverview.Round? = nil) -> some View {
        let _ = thumbs.arrived
        let im = thumbs.image(paper: paper, pdf: pdf, page: page, height: h)
        return ZStack {
            Rectangle().fill(Color.white)
            if let im { Image(nsImage: im).resizable().interpolation(.high) }
            if scheme == .dark { Color.black.opacity(PageThumb.darkDim) }
            if let round, im != nil, let ps = thumbs.pageSize(pdf: pdf, page: page), ps.height > 0 {
                Canvas { ctx, _ in
                    PageThumb.drawMarks(ctx, round: round, data: data, page: page, k: h / ps.height, coloured: { _ in true }, outline: nil)
                }
            }
        }
        .frame(width: width, height: h)
        .overlay(Rectangle().strokeBorder(Color.black.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.08), radius: 1, y: 0.5)
    }
}

/// A paper's small map (`MiniMap`, VISUAL v3 §6.2; UI v4, mockup `mini`): the rows at `width`, newest on top, without
/// labels, counts or ring (the card's sign and figures say them), the sections in the map's one ramp (a cell without
/// comments keeps a keyline in Dark Mode), no outlines and no bands, cells 2 pt apart with 2 pt corners, the older
/// rounds in the older-round ramp; each row's round and comments in its help tag, a failed build's row a dashed label2
/// outline, the folded rounds a dotted line. `empty`: a first draft's cells, all track.
struct MiniMapView: View {
    let map: MiniMap
    let width: CGFloat
    var cell: CGFloat = 8
    var gap: CGFloat = 6
    var empty = false
    @Environment(\.colorScheme) private var scheme

    /// The rows and the fold's row (the oldest rounds) under them.
    var lines: Int { map.rows.count + (map.folded == nil ? 0 : 1) }
    var height: CGFloat { CGFloat(lines) * cell + CGFloat(max(0, lines - 1)) * gap }

    /// "Round 2 · 14 comments", "Round 3 · build failed".
    static func rowHelp(_ r: MiniMap.Row) -> String {
        "Round \(r.n) · " + (r.count.map { count($0, "comment") } ?? "build failed")
    }

    /// "Rounds 1–2", "Round 1".
    static func foldHelp(_ f: ClosedRange<Int>) -> String {
        f.lowerBound == f.upperBound ? "Round \(f.lowerBound)" : "Rounds \(f.lowerBound)–\(f.upperBound)"
    }

    private var accessibility: String {
        (map.rows.map { "Round \($0.n): " + ($0.count.map { count($0, "comment") } ?? "build failed") }
         + (map.folded.map { ["Rounds \($0.lowerBound) to \($0.upperBound) folded"] } ?? [])).joined(separator: ", ")
    }

    var body: some View {
        let ink = MapInk(dark: scheme == .dark)
        let k = width / CGFloat(map.pages)
        return VStack(alignment: .leading, spacing: gap) {
            ForEach(Array(map.rows.enumerated()), id: \.offset) { i, r in
                Canvas { ctx, _ in
                    func x(_ p: Double) -> CGFloat { CGFloat(min(p, map.pages)) * k }
                    func fill(_ rect: CGRect, _ level: Int) {
                        ctx.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(ink.color(i > 0 ? MapRole.old(level) : MapRole.mini(level))))
                        guard level == 0 else { return }
                        ctx.stroke(Path(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), cornerRadius: 1.75), with: .color(ink.color(.zeroline)), lineWidth: 0.5)
                    }
                    if r.failed {
                        ctx.stroke(Path(roundedRect: CGRect(x: 0.5, y: 0.5, width: width - 1, height: cell - 1), cornerRadius: 2),
                                   with: .color(ink.color(.label2)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    } else if r.plain {
                        fill(CGRect(x: 0, y: 0, width: max(1, x(r.pages)), height: cell), 0)
                    } else {
                        // 2 pt between cells, none outside the row
                        for (a, b, level) in MiniMap.runs(r.cells, k: k) {
                            let lo = a <= 0.001 ? x(a) : x(a) + 1, hi = b >= r.pages - 0.001 ? x(b) : x(b) - 1
                            fill(CGRect(x: lo, y: 0, width: max(1, hi - lo), height: cell), empty ? 0 : level)
                        }
                    }
                }
                .frame(width: width, height: cell)
                .help(Self.rowHelp(r))
            }
            if let f = map.folded {
                Canvas { ctx, size in
                    var p = Path()
                    p.move(to: CGPoint(x: 0.5, y: size.height / 2))
                    p.addLine(to: CGPoint(x: size.width - 0.5, y: size.height / 2))
                    ctx.stroke(p, with: .color(ink.color(.tertiary)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                }
                .frame(width: width, height: cell)
                .help(Self.foldHelp(f))
            }
        }
        .accessibilityElement()
        .accessibilityLabel(accessibility)
    }
}

// MARK: - All Students

/// All Students (UI v4, BRIEF §4 05; mockup `board`): the Board, its lanes and the rounds of the year under them, or the
/// Students, a block for each student with a card for each paper (the toolbar's Board | Students). The old page's hero,
/// sentence, chips and the small maps' key are gone: the lanes' counts, the cards' corners and figures carry them.
struct AllStudentsPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var hub: HubModel
    let width: CGFloat

    var body: some View {
        let groups = model.studentGroups
        VStack(alignment: .leading, spacing: 0) {
            if model.papers.isEmpty {
                Text("No papers yet. New Paper… makes one; Import… (File) lists review folders you have, or brings back a backup.")
                    .font(TypeScale.body).foregroundStyle(Ink.secondary)
            } else if model.allStudentsView == .board {
                // dimmed until the papers are first read: the lanes fill as their summaries come
                BoardView(model: model, hub: hub, board: model.board(), width: width)
                    .opacity(hub.status == .idle || hub.status == .loading ? 0.5 : 1)
                let rows = model.papers.map { (paper: $0, status: model.status(of: $0), data: hub.data[$0.path]) }
                let today = Date()
                if let t = Timeline.make(rows, today: today) {
                    RoundsTimeline(model: model, timeline: t, help: HubText.cameThisWeek(rows.compactMap(\.data), today: today))
                        .padding(.top, 32)
                }
            } else {
                let columns = width >= 900 ? 2 : 1
                let blockW = (width - CGFloat(columns - 1) * 16) / CGFloat(columns)
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(stride(from: 0, to: groups.count, by: columns)), id: \.self) { i in
                        HStack(alignment: .top, spacing: 16) {
                            ForEach(groups[i..<min(i + columns, groups.count)]) { g in
                                StudentBlock(model: model, hub: hub, group: g, width: blockW)
                            }
                        }
                    }
                }
            }
            if case .failed(let m) = hub.status {
                Text("The papers could not be read: " + m).font(TypeScale.callout).foregroundStyle(Ink.secondary).padding(.top, 10)
            }
        }
    }
}

/// A student in the students mode: initials, name and numbers (a click opens the student's page), a card for each
/// paper as the board draws it (with its sign and words, without the name the block says), and where most comments
/// land (each comment once, where it was written).
struct StudentBlock: View {
    @ObservedObject var model: AppModel
    @ObservedObject var hub: HubModel
    let group: StudentGroup
    let width: CGFloat

    var body: some View {
        let stats = hub.stats(for: group.papers.map(\.path))
        let rounds = group.papers.compactMap { hub.data[$0.path]?.rounds.count }.reduce(0, +)
        let comments = stats?.comments ?? group.papers.compactMap { hub.data[$0.path]?.threads?.comments }.reduce(0, +)
        let inner = width - 48
        let tileW = group.papers.count > 1 ? (inner - 16) / 2 : min(inner, (inner - 16) / 2 + 60)
        let today = Date()
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Avatar(name: group.unassigned ? "?" : group.name, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name).font(TypeScale.title2)
                    Text([count(group.papers.count, "paper"), rounds > 0 ? count(rounds, "round") : nil,
                          comments > 0 ? count(comments, "comment") : nil].compactMap { $0 }.joined(separator: " · "))
                        .font(TypeScale.callout).foregroundStyle(Ink.secondary)
                }
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
            .onTapGesture { if !group.unassigned { model.openHub(.student(group.key)) } }
            .help(ifAny: group.unassigned ? nil : "\(group.name)’s page")
            .contextMenu { StudentMenu(model: model, group: group) }  // as the sidebar's student row (DATA.md §0.2)
            // two cards a row, each row's one height
            let moves = model.yourMove
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(stride(from: 0, to: group.papers.count, by: 2)), id: \.self) { i in
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(group.papers[i..<min(i + 2, group.papers.count)]) { p in
                            BoardCardView(model: model, card: BoardCard.make(p, status: model.status(of: p), summary: model.summaries[p.path],
                                                                             data: hub.data[p.path], missing: model.cardWords(p),
                                                                             item: moves.first { $0.paper.path == p.path }, today: today),
                                          paper: p, data: hub.data[p.path], width: tileW, who: false, state: true)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 16)
            if let land = stats?.land, let most = Self.most(land) {
                Divider().padding(.top, 16)
                HStack(spacing: 6) {
                    Image(systemName: "tablecells").font(.system(size: 11)).foregroundStyle(Ink.secondary)
                    (Text("Most comments in ") + Text("\(most.0) (\(most.1))").fontWeight(.semibold).foregroundColor(Ink.label))
                }
                .font(TypeScale.body).foregroundStyle(Ink.secondary)
                .padding(.top, 12)
            }
        }
        .padding(24)
        .frame(width: width, alignment: .topLeading)
        .hubCard(radius: 10)
    }

    /// The column with most comments, each counted once where it was written.
    static func most(_ land: StudentStats.Land) -> (String, Int)? {
        zip(land.columns.map(\.title), land.total).filter { $0.1 > 0 }.max { $0.1 < $1.1 }
    }
}

// MARK: - Your Move

/// Your Move (UI v4, BRIEF §4 06/07; mockup `yourMove`, `mrow`): "2 papers wait on you" with the ring at 26, then one
/// card of rows, oldest first, each with its key page, mini map, title, the figure of its state, the days it has waited
/// and its button (Continue, Finish Round N…, Show Log…; primary on the oldest only); then the papers with students as
/// quiet rows. Nothing waiting: the ring in the secondary ink and "Nothing waits on you". Below 900 pt the rows drop
/// the mini map and put the figure under the title.
struct YourMovePage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var hub: HubModel
    let width: CGFloat

    var body: some View {
        let page = model.yourMovePage(), narrow = width < 900
        let failed = page.rows.filter { $0.card.status == .failed }.count
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                StatusGlyphView(page.rows.isEmpty ? .nothingWaits : .ring(0), size: 21, text: 26)
                Text(HubText.waits(page.rows.count)).font(TypeScale.hero).lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .help(ifAny: HubText.waitsDetail(review: page.rows.count - failed, failed: failed))
            if !page.rows.isEmpty {
                VStack(spacing: 0) {
                    MoveRowView.head(narrow: narrow)
                    ForEach(page.rows) { r in
                        Rectangle().fill(Color(nsColor: Palette.rule)).frame(height: 1)
                        MoveRowView(model: model, hub: hub, row: r, narrow: narrow)
                    }
                }
                .padding(.horizontal, 24)
                .hubCard(radius: 10)
                .padding(.top, 24)
            }
            if !page.quiet.isEmpty {
                HStack(spacing: 6) {
                    StatusGlyphView(.waiting, size: 12, text: 12)
                    Text("With students").fontWeight(.semibold)
                    Text("\(page.quiet.count)").monospacedDigit()
                }
                .font(TypeScale.callout).foregroundStyle(Ink.secondary)
                .padding(.top, 32).padding(.bottom, 8)
                VStack(spacing: 0) {
                    ForEach(Array(page.quiet.enumerated()), id: \.element.id) { i, r in
                        if i > 0 { Rectangle().fill(Color(nsColor: Palette.rule)).frame(height: 1) }
                        MoveRowView(model: model, hub: hub, row: r, quiet: true, narrow: narrow)
                    }
                }
                .padding(.horizontal, 24)
                .hubCard(radius: 10)
            }
        }
    }
}

/// A row of Your Move (mockup `.mr`): the key page 40 (32 quiet), the mini map 112, the title (New York 15, 13 quiet)
/// over the student and round, the figure in a 190 pt column, the days waited in an 84 pt one, the button in 100; 24
/// apart, every cell on the title's first baseline. `narrow`: without the mini map, the figure under the title.
struct MoveRowView: View {
    let model: AppModel
    @ObservedObject var hub: HubModel
    let row: YourMoveModel.Row
    var quiet = false
    var narrow = false

    static let thumb: CGFloat = 40, map: CGFloat = 112, figure: CGFloat = 190, waiting: CGFloat = 84, button: CGFloat = 100

    /// The column heads, "To check" (not when narrow) and "Waiting", right-aligned to their numbers.
    static func head(narrow: Bool) -> some View {
        HStack(spacing: 24) {
            Spacer(minLength: 0)
            if !narrow {
                Text("To check").fixedSize().frame(width: 46, alignment: .trailing)
                    .frame(width: figure, alignment: .leading)
            }
            Text("Waiting").fixedSize().padding(.trailing, 36).frame(width: waiting, alignment: .trailing)
            Color.clear.frame(width: button, height: 1)
        }
        .font(TypeScale.callout).foregroundStyle(Ink.secondary)
        .padding(.top, 12).padding(.bottom, 8)
    }

    var body: some View {
        let c = row.card
        let p = model.papers.first { $0.path == c.path } ?? PaperRef(path: c.path, title: c.title, student: "")
        let d = hub.data[c.path]
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            KeyPageStack(thumbs: model.thumbnails, paper: c.path, data: d, width: quiet ? 32 : Self.thumb, depth: 1, marks: true)
                .opacity(model.missingPapers.contains(c.path) ? 0.35 : 1)
                .frame(width: Self.thumb, alignment: .leading)
                .alignmentGuide(.firstTextBaseline) { v in v[.top] + (quiet ? 12 : 15) }
            if !narrow {
                Group {
                    if let d, !d.rounds.isEmpty {
                        MiniMapView(map: MiniMap.make(d, maxRows: 8, fold: model.foldParts), width: Self.map, cell: 8, gap: 4,
                                    empty: c.status == .firstDraft)
                    } else {
                        Color.clear.frame(width: Self.map, height: 8)
                    }
                }
                .alignmentGuide(.firstTextBaseline) { v in v[.top] + (quiet ? 8 : 10) }
            }
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.title).font(TypeScale.paperTitle(quiet ? 13 : 15)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Text(row.sub).font(TypeScale.callout).foregroundStyle(Ink.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { model.openPaper(c.path) }
                .help("Open \(c.title)’s overview")
                if narrow && !quiet { BoardFigure(card: c, broken: model.folderBroken(p)) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !narrow {
                Group {
                    if quiet {
                        Color.clear.frame(height: 1)
                    } else if case .toCheck(let n) = c.figure {
                        ToCheckColumn(comments: n.comments, edits: n.edits, fill: c.fill ?? 0)
                            .help(ToCheckFigure.help(n.comments, n.edits) + (c.answered.map { " · " + $0 } ?? ""))
                    } else {
                        BoardFigure(card: c, broken: model.folderBroken(p))
                    }
                }
                .frame(width: Self.figure, alignment: .leading)
            }
            waiting.frame(width: Self.waiting, alignment: .trailing).help(ifAny: row.help)
            Group {
                if let item = c.item {
                    let b = Button(MoveRow.title(item)) { model.moveAction(item) }.help(MoveRow.help(item))
                    if row.primary { b.buttonStyle(.borderedProminent) } else { b.buttonStyle(.bordered) }
                } else {
                    Color.clear.frame(height: 1)
                }
            }
            .fixedSize()
            .frame(minWidth: Self.button, alignment: .trailing)
        }
        .padding(.vertical, 12)
        .frame(minHeight: quiet ? 0 : 64, alignment: .top)
        .contextMenu { StudentCardMenu(model: model, paper: p, item: c.item, status: c.status) }
        .accessibilityElement(children: .contain)
    }

    /// "2 days" (17 semibold, the unit 12 secondary in a 32 pt slot); quiet: "6 days" at 13 secondary; "today"; "–"
    /// before the data.
    @ViewBuilder private var waiting: some View {
        let w = YourMoveModel.waiting(row.days)
        if w.value == "–" {
            Text("–").font(TypeScale.body).foregroundStyle(Ink.tertiary).padding(.trailing, 36)
        } else if let unit = w.unit {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(w.value).font(quiet ? TypeScale.body : TypeScale.title2).monospacedDigit()
                    .foregroundStyle(quiet ? Ink.secondary : Ink.label)
                Text(unit).font(TypeScale.callout).foregroundStyle(Ink.secondary)
                    .frame(width: 32, alignment: .leading)
            }
        } else {
            Text(w.value).font(TypeScale.body).foregroundStyle(Ink.secondary).padding(.trailing, 5)
        }
    }
}

/// Your Move's button for a paper: its words and help (also the student page's action card and the cards' menus).
enum MoveRow {
    /// The button's words; without the round when it is not known (the review: "Finish Round 0…").
    static func title(_ item: MoveItem) -> String {
        switch item.status {
        case .ready: return item.round.map { "Finish Round \($0)…" } ?? "Finish Round…"
        case .failed: return "Show Log…"
        default: return "Continue"
        }
    }

    static func help(_ item: MoveItem) -> String {
        switch item.status {
        case .ready: return "Open Review and finish the round, which writes final.pdf"
        case .failed: return "Open Review: the build’s errors and its log"
        default: return item.round.map { "Open Review at Round \($0)" } ?? "Open Review"
        }
    }
}
