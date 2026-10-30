import AppKit
import SwiftUI

/// The hierarchy's pages (OVERVIEW-v2 §3.1–3.2, the mockup's `allStudentsView`, `yourMoveView`, `studentView`; UX.md
/// §22): All Students (C's layout, quantified), Your Move, and a student's page (C's skeleton with B's Where the time
/// goes). Each scrolls on the panel's colour, inset 24 pt, with the toolbar's ‹ › and its title.
struct HubScreen: View {
    @ObservedObject var model: AppModel
    @ObservedObject var hub: HubModel
    let page: HubPage

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width - 2 * OverviewLayout.inset, 300)
            ScrollView(.vertical) {
                Group {
                    switch page {
                    case .allStudents: AllStudentsPage(model: model, hub: hub, width: width)
                    case .yourMove: YourMovePage(model: model, hub: hub, width: width)
                    case .student(let k): StudentPage(model: model, hub: hub, key: k, width: width)
                    }
                }
                .padding(EdgeInsets(top: 18, leading: OverviewLayout.inset, bottom: 26, trailing: OverviewLayout.inset))
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(HubScrollProbe(hub: hub))
            }
        }
        .background(Color(nsColor: Palette.panel))
        .foregroundStyle(Ink.label)
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .modifier(OwnToolbarTitle())
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 8) {
                    HistoryButtons(model: model)
                    if #available(macOS 15, *) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(title).font(.system(size: 13, weight: .semibold))
                            Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                        .padding(.leading, 4)
                    }
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
                if page == .allStudents {
                    Button { model.showNewPaper = true } label: { Label("New Paper…", systemImage: "plus") }
                        .labelStyle(.titleAndIcon)
                        .help("Create a review folder for a student’s paper")
                }
            }
        }
        .sheet(item: Binding(get: { model.mappingHeadings.map(SheetID.init) }, set: { model.mappingHeadings = $0?.id })) { s in
            MapHeadingsSheet(model: model, key: s.id)
        }
    }

    private var title: String {
        switch page {
        case .allStudents: return "All Students"
        case .yourMove: return "Your Move"
        case .student(let k): return model.studentGroups.first { $0.key == k }?.name ?? "Student"
        }
    }

    private var subtitle: String {
        let groups = model.studentGroups
        switch page {
        case .allStudents:
            let rounds = model.papers.compactMap { hub.data[$0.path]?.rounds.count ?? model.summaries[$0.path]?.round }.reduce(0, +)
            return [count(groups.filter { !$0.unassigned }.count, "student"), count(model.papers.count, "paper"), count(rounds, "round")]
                .joined(separator: " · ")
        case .yourMove:
            let m = model.yourMove, failed = Hierarchy.counts(m).failed
            return HubText.waits(m.count) + (m.count > 1 ? ", oldest first" : "") + (failed > 0 ? " · \(count(failed, "build")) failed" : "")
        case .student(let k):
            guard let g = groups.first(where: { $0.key == k }) else { return "" }
            let rounds = g.papers.compactMap { hub.data[$0.path]?.rounds.count }.reduce(0, +)
            return [count(g.papers.count, "paper"), rounds > 0 ? count(rounds, "round") : nil].compactMap { $0 }.joined(separator: " · ")
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

/// A sentence with bold parts (a paper's title).
struct RunsText: View {
    let runs: [HubText.Run]

    var body: some View {
        runs.reduce(Text("")) { t, r in
            r.amber ? t + Text(r.text).fontWeight(.bold).foregroundColor(Color(nsColor: Palette.toCheck))
                : t + Text(r.text).fontWeight(r.bold ? .semibold : .regular)
        }
    }
}

/// A student's initials in a circle.
struct Avatar: View {
    let name: String
    var size: CGFloat = 36

    var body: some View {
        Text(StudentName.initials(name))
            .font(.system(size: size * 0.36, weight: .medium))
            .foregroundStyle(Ink.secondary)
            .frame(width: size, height: size)
            .background(Circle().fill(Color(nsColor: Palette.chipFill)))
            .overlay(Circle().strokeBorder(Color(nsColor: Palette.rule), lineWidth: 1))
            .accessibilityHidden(true)
    }
}

/// A status with its sign: "○ Round 4 · 7 comments and 2 edits to check"; `broken`: the red sign of a paper whose
/// folder is missing.
struct StatusLine: View {
    let status: PaperStatus?
    let text: String
    var lines = 1
    var broken = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if broken {
                Image(systemName: "exclamationmark.circle").font(.system(size: 11.5)).foregroundStyle(Color(nsColor: Palette.danger))
            } else if let s = status {
                StatusSign(status: s).font(.system(size: 11.5))
            }
            // a failed build's words in the label's ink, its sign red (the mockup's: no more red than the sign)
            Text(text).lineLimit(lines).truncationMode(.tail).fixedSize(horizontal: false, vertical: lines > 1)
                .foregroundStyle(Ink.label2)
        }
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
                page(r.pdf, page: min(k, max(0, (r.build?.pages ?? 1) - 1)), h: h)
                    .opacity(back == 0 ? 1 : max(0.2, 0.55 - Double(back - 1) * 0.2))
                    .offset(x: CGFloat(back) * 6, y: CGFloat(n - 1 - back) * 3)
            }
        }
        .frame(width: width + CGFloat(n - 1) * 6, height: h + CGFloat(n - 1) * 3, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    private func page(_ pdf: String?, page: Int, h: CGFloat) -> some View {
        let _ = thumbs.arrived
        return ZStack {
            Rectangle().fill(Color.white)
            if let im = thumbs.image(paper: paper, pdf: pdf, page: page, height: h) {
                Image(nsImage: im).resizable().interpolation(.high)
            }
            if scheme == .dark { Color.black.opacity(PageThumb.darkDim) }
        }
        .frame(width: width, height: h)
        .overlay(Rectangle().strokeBorder(Color.black.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.08), radius: 1, y: 0.5)
    }
}

/// A paper's small map (`MiniMap`, VISUAL v3 §6.2): "R4" at the left (the open round with something to check in
/// Semibold after an amber ring), the sections in the small maps' own steps (a step stronger than the paper map's:
/// there are no numbers in them), no outlines and no bands, 8 pt rows on a 14 pt pitch, the round's comments at the
/// right ("–" for a failed build, with a dashed red outline).
struct MiniMapView: View {
    let map: MiniMap
    let width: CGFloat
    var cell: CGFloat = 8
    var gap: CGFloat = 6
    @Environment(\.colorScheme) private var scheme

    static let labelWidth: CGFloat = 30, countWidth: CGFloat = 26

    /// The rows and the fold's row ("R1–2", the oldest rounds) under them.
    var lines: Int { map.rows.count + (map.folded == nil ? 0 : 1) }
    var height: CGFloat { CGFloat(lines) * cell + CGFloat(max(0, lines - 1)) * gap + 2 }

    var body: some View {
        let ink = MapInk(dark: scheme == .dark)
        Canvas { ctx, size in
            let x0 = Self.labelWidth
            let k = width / CGFloat(map.pages)
            func x(_ p: Double) -> CGFloat { x0 + CGFloat(min(p, map.pages)) * k }
            func y(_ i: Int) -> CGFloat { 1 + CGFloat(i) * (cell + gap) }
            for (i, r) in map.rows.enumerated() {
                let top = y(i), mid = top + cell / 2
                var lx: CGFloat = 0
                if r.ring {
                    ctx.stroke(Path(ellipseIn: CGRect(x: 0.7, y: mid - 3, width: 6, height: 6)), with: .color(ink.color(.attention)), lineWidth: 1.3)
                    lx = 9.5
                }
                ctx.draw(Text("R\(r.n)").font(.system(size: 11, weight: r.ring ? .semibold : .regular))
                            .foregroundColor(ink.color(r.ring ? .label : .secondary)),
                         at: CGPoint(x: lx, y: mid), anchor: .leading)
                if r.failed {
                    let rect = CGRect(x: x0 + 0.5, y: top + 0.5, width: width - 1, height: cell - 1)
                    ctx.stroke(Path(roundedRect: rect, cornerRadius: 2), with: .color(ink.color(.danger)),
                               style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                } else if r.plain {
                    let rect = CGRect(x: x0 + 0.5, y: top, width: max(1, x(r.pages) - x0 - 1), height: cell)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(ink.color(.miniTrack)))
                } else {
                    for (a, b, level) in MiniMap.runs(r.cells, k: k) {
                        let rect = CGRect(x: x(a) + 0.5, y: top, width: max(1, x(b) - x(a) - 1), height: cell)
                        ctx.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(ink.color(MapRole.mini(level))))
                    }
                }
                let n = r.count.map(String.init) ?? "–"
                ctx.draw(Text(n).font(.system(size: 11, weight: r.ring ? .semibold : .regular).monospacedDigit())
                            .foregroundColor(ink.color(r.failed ? .danger : r.ring ? .label : .secondary)),
                         at: CGPoint(x: size.width, y: mid), anchor: .trailing)
            }
            if let f = map.folded {
                let mid = y(map.rows.count) + cell / 2
                ctx.draw(Text(f.lowerBound == f.upperBound ? "R\(f.lowerBound)" : "R\(f.lowerBound)–\(f.upperBound)")
                            .font(.system(size: 11)).foregroundColor(ink.color(.secondary)),
                         at: CGPoint(x: 0, y: mid), anchor: .leading)
                var p = Path()
                p.move(to: CGPoint(x: x0 + 0.5, y: mid))
                p.addLine(to: CGPoint(x: x0 + width - 0.5, y: mid))
                ctx.stroke(p, with: .color(ink.color(.tertiary)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
        }
        .frame(width: Self.labelWidth + width + Self.countWidth, height: height)
        .accessibilityElement()
        .accessibilityLabel((map.rows.map { "Round \($0.n): " + ($0.count.map { count($0, "comment") } ?? "build failed") }
                             + (map.folded.map { ["Rounds \($0.lowerBound) to \($0.upperBound) folded"] } ?? [])).joined(separator: ", "))
    }
}

// MARK: - All Students

/// All Students (OVERVIEW-v2 §3.1, C quantified; the mockup's `allStudentsView`): this week in one sentence with the
/// count of papers that wait on you (the sidebar's and Your Move's number) and a chip for each; the rounds of the year
/// on a timeline; a block for each student with a tile for each paper (its key page and small map); the small maps'
/// key at the end.
struct AllStudentsPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var hub: HubModel
    let width: CGFloat

    var body: some View {
        let groups = model.studentGroups
        let moves = model.yourMove
        let rows = groups.flatMap(\.papers).map { (paper: $0, status: model.status(of: $0), data: hub.data[$0.path]) }
        let today = Date()
        VStack(alignment: .leading, spacing: 0) {
            if width >= 900 {
                let side = min(580, width * 0.48)
                HStack(alignment: .top, spacing: 24) {
                    week(moves: moves, rows: rows, today: today).frame(width: width - side - 24, alignment: .leading)
                    timeline(rows: rows, today: today).frame(width: side)
                }
            } else {
                week(moves: moves, rows: rows, today: today)
                timeline(rows: rows, today: today).padding(.top, 18)
            }
            if model.papers.isEmpty {
                Text("No papers yet. New Paper… makes one; Import… (File) lists review folders you have, or brings back a backup.")
                    .font(.system(size: 13)).foregroundStyle(Ink.secondary).padding(.top, 24)
            }
            let columns = width >= 900 ? 2 : 1
            let blockW = (width - CGFloat(columns - 1) * 18) / CGFloat(columns)
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(stride(from: 0, to: groups.count, by: columns)), id: \.self) { i in
                    HStack(alignment: .top, spacing: 18) {
                        ForEach(groups[i..<min(i + columns, groups.count)]) { g in
                            StudentBlock(model: model, hub: hub, group: g, width: blockW)
                        }
                    }
                }
            }
            .padding(.top, 24)
            if !groups.isEmpty {
                HStack(spacing: 8) {
                    MiniMapKey()
                    (Text("Small maps: ").fontWeight(.semibold)
                        + Text("one row per round, newest on top, shaded like that paper’s map (its own three steps); the number at the right is the comments in that round"))
                        .font(.system(size: 12)).foregroundStyle(Ink.secondary)
                }
                .padding(.top, 16)
            }
            if case .failed(let m) = hub.status {
                Text("The papers could not be read: " + m).font(.system(size: 12)).foregroundStyle(Ink.secondary).padding(.top, 10)
            }
        }
    }

    private func week(moves: [MoveItem], rows: [(paper: PaperRef, status: PaperStatus?, data: PaperOverview?)], today: Date) -> some View {
        let (review, failed) = Hierarchy.counts(moves)
        let detail = HubText.waitsDetail(review: review, failed: failed)
        return VStack(alignment: .leading, spacing: 0) {
            Text("This week · " + HubText.week(today)).font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.secondary)
            HStack(spacing: 10) {
                if !moves.isEmpty {
                    Image(systemName: "circle").font(.system(size: 18, weight: .bold)).foregroundStyle(Color(nsColor: Palette.toCheck))
                }
                Text(HubText.waits(moves.count)).font(PageType.title)
            }
            .padding(.top, 6)
            .accessibilityElement(children: .combine)
            if !detail.isEmpty {
                Text(detail).font(.system(size: 14)).foregroundStyle(Ink.secondary).padding(.leading, moves.isEmpty ? 0 : 30).padding(.top, 2)
            }
            if hub.status == .loaded || !hub.data.isEmpty {
                RunsText(runs: HubText.thisWeek(rows, today: today))
                    .font(.system(size: 15)).foregroundStyle(Ink.label2).lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
            if !moves.isEmpty {
                WrapLayout(spacing: 8) {
                    ForEach(moves) { m in MoveChip(model: model, item: m, room: width < 900 ? width : width - min(580, width * 0.48) - 24) }
                }
                .padding(.top, 14)
            }
        }
    }

    @ViewBuilder
    private func timeline(rows: [(paper: PaperRef, status: PaperStatus?, data: PaperOverview?)], today: Date) -> some View {
        if let t = Timeline.make(rows, today: today) {
            TimelineCard(model: model, timeline: t)
        }
    }
}

/// A paper that waits on you, as a chip under All Students' sentence: its sign, its title and what it needs; a click
/// opens its overview.
struct MoveChip: View {
    let model: AppModel
    let item: MoveItem
    /// The width the chips wrap in: a long title is cut so its chip fits.
    var room: CGFloat = 600

    var body: some View {
        Button { model.openPaper(item.paper.path) } label: {
            HStack(spacing: 6) {
                StatusSign(status: item.status).font(.system(size: 11.5))
                Text(item.paper.title).fontWeight(.semibold).foregroundStyle(Ink.label)
                    .truncationMode(.tail).frame(maxWidth: Self.titleWidth(room: room, words: words), alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                Text(words).foregroundStyle(Ink.secondary)
            }
            .font(.system(size: 13))
            .lineLimit(1)
            .padding(.horizontal, 11).frame(height: 30)
            .background(Capsule().fill(Color(nsColor: Palette.card)))
            .overlay(Capsule().strokeBorder(Color(nsColor: Palette.rule), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Open \(item.paper.title)’s overview")
    }

    /// The title's room: the chip's room less its words as measured, its sign, gaps and padding (the UI audit: a
    /// fixed 300 pt for them let "Round 2 · 14 comments and 2 edits to check" run the chip past its column).
    static func titleWidth(room: CGFloat, words: String) -> CGFloat {
        let w = ceil((words as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width)
        let rest: CGFloat = 22 + 14 + 12 + 2  // the padding, the sign, the two gaps and a little to spare
        return max(120, room - w - rest)
    }

    private var words: String {
        switch item.status {
        case .ready: return "ready to finish"
        case .failed: return "build failed"
        default: return model.statusText(item.paper)
        }
    }
}

/// "Rounds in 2026" (the mockup's `timelineSVG`): a lane per paper with its title, the months under it and today's
/// line; a click on a lane opens the paper's overview.
struct TimelineCard: View {
    let model: AppModel
    let timeline: Timeline
    @Environment(\.colorScheme) private var scheme

    static let lane: CGFloat = 22, top: CGFloat = 26, labels: CGFloat = 150

    var body: some View {
        let ink = MapInk(dark: scheme == .dark)
        VStack(alignment: .leading, spacing: 6) {
            // the key beside the title, or under it in a narrow card
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(timeline.title).font(.system(size: 14, weight: .semibold))
                    Spacer(minLength: 8)
                    key(ink)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(timeline.title).font(.system(size: 14, weight: .semibold))
                    key(ink)
                }
            }
            let h = Self.top + CGFloat(timeline.lanes.count) * Self.lane + 22
            GeometryReader { g in
                let plot = max(60, g.size.width - Self.labels - 12)
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, size in draw(&ctx, plot: plot, ink: ink) }
                    VStack(spacing: 0) {
                        Color.clear.frame(height: Self.top)
                        ForEach(timeline.lanes, id: \.path) { l in
                            Color.clear.frame(height: Self.lane).contentShape(Rectangle())
                                .onTapGesture { model.openPaper(l.path) }
                                .help(l.title + (model.papers.first { $0.path == l.path }.map { " · " + model.statusText($0) } ?? ""))
                        }
                    }
                }
            }
            .frame(height: h)
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 10, trailing: 16))
        .hubCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(timeline.title)
    }

    private func key(_ ink: MapInk) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) { Circle().fill(ink.color(.secondary)).frame(width: 6, height: 6); Text("came in") }
            HStack(spacing: 4) { Capsule().fill(ink.color(.chartYou)).frame(width: 13, height: 3); Text("with you") }
            HStack(spacing: 4) {
                Path { p in p.move(to: CGPoint(x: 0, y: 1.5)); p.addLine(to: CGPoint(x: 13, y: 1.5)) }
                    .stroke(ink.color(.secondary), style: StrokeStyle(lineWidth: 1, dash: [2, 3])).frame(width: 13, height: 3)
                Text("with the student")
            }
            HStack(spacing: 4) { Circle().strokeBorder(ink.color(.attention), lineWidth: 1.6).frame(width: 9, height: 9); Text("your move") }
        }
        .font(.system(size: 11.5)).foregroundStyle(Ink.secondary)
        .lineLimit(1)
        .fixedSize()
    }

    private func draw(_ ctx: inout GraphicsContext, plot: CGFloat, ink: MapInk) {
        let t = timeline, lx = Self.labels
        func x(_ d: Double) -> CGFloat { lx + CGFloat(d / t.days) * plot }
        let bottom = Self.top + CGFloat(t.lanes.count) * Self.lane
        for (name, d) in t.months {
            var p = Path()
            p.move(to: CGPoint(x: x(d), y: Self.top - 8))
            p.addLine(to: CGPoint(x: x(d), y: bottom))
            ctx.stroke(p, with: .color(ink.color(.rule)), lineWidth: 0.5)
            ctx.draw(Text(name).font(.system(size: 11)).foregroundColor(ink.color(.secondary)),
                     at: CGPoint(x: x(d) + 3, y: bottom + 11), anchor: .leading)
        }
        var today = Path()
        today.move(to: CGPoint(x: x(t.today), y: Self.top - 12))
        today.addLine(to: CGPoint(x: x(t.today), y: bottom))
        ctx.stroke(today, with: .color(ink.color(.secondary)), lineWidth: 1)
        ctx.draw(Text("Today").font(.system(size: 11)).foregroundColor(ink.color(.secondary)),
                 at: CGPoint(x: x(t.today), y: Self.top - 19), anchor: .center)
        for (i, l) in t.lanes.enumerated() {
            let y = Self.top + CGFloat(i) * Self.lane + Self.lane / 2
            ctx.draw(Text(l.title).font(.system(size: 11.5)).foregroundColor(ink.color(.label2)),
                     in: CGRect(x: 0, y: y - 8, width: lx - 12, height: 16))
            for s in l.student {
                var p = Path()
                p.move(to: CGPoint(x: x(s.lowerBound), y: y))
                p.addLine(to: CGPoint(x: x(s.upperBound), y: y))
                ctx.stroke(p, with: .color(ink.color(.secondary)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
            for s in l.you {
                var p = Path()
                p.move(to: CGPoint(x: x(s.lowerBound), y: y))
                p.addLine(to: CGPoint(x: max(x(s.upperBound), x(s.lowerBound) + 0.1), y: y))
                ctx.stroke(p, with: .color(ink.color(.chartYou)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
            // a round's number over its mark, unless the next one's is within 9 pt (rounds a day apart): the latest wins
            var numbered: [Int] = []
            var lastX = CGFloat.infinity
            for m in l.marks.reversed() where lastX - x(m.day) >= 9 {
                numbered.append(m.n)
                lastX = x(m.day)
            }
            for m in l.marks {
                let c = CGPoint(x: x(m.day), y: y)
                switch m.kind {
                case .imported:
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - 3.4, y: y - 3.4, width: 6.8, height: 6.8)), with: .color(ink.color(.secondary)))
                case .yourMove, .ready:
                    let r = CGRect(x: c.x - 4.6, y: y - 4.6, width: 9.2, height: 9.2)
                    ctx.fill(Path(ellipseIn: r), with: .color(ink.color(.card)))
                    ctx.stroke(Path(ellipseIn: r), with: .color(ink.color(m.kind == .ready ? .secondary : .attention)), lineWidth: 1.8)
                    if m.kind == .ready {
                        var tick = Path()
                        tick.move(to: CGPoint(x: c.x - 2, y: y))
                        tick.addLine(to: CGPoint(x: c.x - 0.5, y: y + 1.5))
                        tick.addLine(to: CGPoint(x: c.x + 2.2, y: y - 1.5))
                        ctx.stroke(tick, with: .color(ink.color(.secondary)), lineWidth: 1.3)
                    }
                case .failed:
                    var tri = Path()
                    tri.move(to: CGPoint(x: c.x, y: y - 5))
                    tri.addLine(to: CGPoint(x: c.x + 5, y: y + 4))
                    tri.addLine(to: CGPoint(x: c.x - 5, y: y + 4))
                    tri.closeSubpath()
                    ctx.fill(tri, with: .color(ink.color(.card)))
                    ctx.stroke(tri, with: .color(ink.color(.danger)), style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
                }
                if numbered.contains(m.n) {
                    // with a halo of the card's colour, so a number on the Today rule or a month's line stays legible
                    let at = CGPoint(x: c.x, y: y - 10.5)
                    let halo = ctx.resolve(Text("\(m.n)").font(.system(size: 11)).foregroundColor(ink.color(.card)))
                    for (dx, dy) in [(-1.2, 0.0), (1.2, 0), (0, -1.2), (0, 1.2)] {
                        ctx.draw(halo, at: CGPoint(x: at.x + dx, y: at.y + dy), anchor: .center)
                    }
                    ctx.draw(Text("\(m.n)").font(.system(size: 11)).foregroundColor(ink.color(.secondary)), at: at, anchor: .center)
                }
            }
            if let f = l.finished {
                let c = CGPoint(x: x(f), y: y)
                var d = Path()
                d.move(to: CGPoint(x: c.x, y: y - 5.5))
                d.addLine(to: CGPoint(x: c.x + 5.5, y: y))
                d.addLine(to: CGPoint(x: c.x, y: y + 5.5))
                d.addLine(to: CGPoint(x: c.x - 5.5, y: y))
                d.closeSubpath()
                ctx.fill(d, with: .color(ink.color(.card)))
                ctx.stroke(d, with: .color(ink.color(.secondary)), lineWidth: 1.2)
            }
        }
    }
}

/// The small maps' key: two rows of shaded cells.
struct MiniMapKey: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = MapInk(dark: scheme == .dark)
        Canvas { ctx, _ in
            let cells: [(CGFloat, CGFloat, CGFloat, Int)] = [(1, 1, 9, 1), (11, 1, 16, 3), (28, 1, 9, 0), (1, 11, 9, 2), (11, 11, 16, 3), (28, 11, 9, 1)]
            for (x, y, w, l) in cells {
                ctx.fill(Path(roundedRect: CGRect(x: x, y: y, width: w, height: 8), cornerRadius: 2), with: .color(ink.color(MapRole.mini(l))))
            }
        }
        .frame(width: 38, height: 20)
        .accessibilityHidden(true)
    }
}

/// A student on All Students: initials, name and numbers, Profile ›, a tile for each paper, and where most comments
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
        let inner = width - 36
        let tileW = group.papers.count > 1 ? (inner - 12) / 2 : min(inner, (inner - 12) / 2 + 60)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Avatar(name: group.unassigned ? "?" : group.name, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name).font(.system(size: 16, weight: .semibold))
                    Text([count(group.papers.count, "paper"), rounds > 0 ? count(rounds, "round") : nil,
                          comments > 0 ? count(comments, "comment") : nil].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 12.5)).foregroundStyle(Ink.secondary)
                }
                Spacer(minLength: 8)
                if !group.unassigned {
                    Button("Profile") { model.openHub(.student(group.key)) }
                        .buttonStyle(LinkStyle())  // a link, as every link in words (the UI audit: grey, it read as a label)
                        .font(.system(size: 13))
                    .help("\(group.name)’s page: papers, where the comments land, where the time goes")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { if !group.unassigned { model.openHub(.student(group.key)) } }
            .contextMenu { StudentMenu(model: model, group: group) }  // as the sidebar's student row (DATA.md §0.2)
            WrapLayout(spacing: 12) {
                ForEach(group.papers) { p in PaperTile(model: model, hub: hub, paper: p, width: tileW) }
            }
            .padding(.top, 14)
            if let land = stats?.land, let most = Self.most(land) {
                Divider().padding(.top, 14)
                HStack(spacing: 7) {
                    Image(systemName: "tablecells").font(.system(size: 11)).foregroundStyle(Ink.secondary)
                    (Text("Most comments in ") + Text("\(most.0) (\(most.1))").fontWeight(.semibold).foregroundColor(Ink.label))
                }
                .font(.system(size: 13)).foregroundStyle(Ink.secondary)
                .padding(.top, 10)
            }
        }
        .padding(18)
        .frame(width: width, alignment: .topLeading)
        .hubCard()
    }

    /// The column with most comments, each counted once where it was written.
    static func most(_ land: StudentStats.Land) -> (String, Int)? {
        zip(land.columns.map(\.title), land.total).filter { $0.1 > 0 }.max { $0.1 < $1.1 }
    }
}

/// A paper on All Students (the mockup's `tileHTML`): its key page and small map, title, status, and its rounds and
/// comments; a click opens its overview.
struct PaperTile: View {
    @ObservedObject var model: AppModel
    @ObservedObject var hub: HubModel
    let paper: PaperRef
    let width: CGFloat

    var body: some View {
        let d = hub.data[paper.path]
        let status = model.status(of: paper)
        let n = d?.rounds.count ?? 0
        let thumbs = n > 0 ? min(3, n) : 1
        let page: CGFloat = width < 250 ? 46 : 56  // a narrow tile (two students a row at 1280) keeps room for its map
        let side: CGFloat = 24 + page + 10 + MiniMapView.labelWidth + MiniMapView.countWidth
        let mapW: CGFloat = min(220, max(40, width - side - CGFloat(thumbs - 1) * 6))
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                KeyPageStack(thumbs: model.thumbnails, paper: paper.path, data: d, width: page)
                    .opacity(model.missingPapers.contains(paper.path) ? 0.35 : 1)  // no page to draw: not a page loading
                if let d, !d.rounds.isEmpty {
                    MiniMapView(map: MiniMap.make(d, maxRows: 7, ring: status?.badge != nil, fold: model.foldParts), width: mapW)
                        .padding(.top, 2)
                }
            }
            .frame(height: 96, alignment: .topLeading)
            Text(paper.title.isEmpty ? (paper.path as NSString).lastPathComponent : paper.title)
                .font(.system(size: 14.5, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                .foregroundStyle(status?.isFinished == true ? Ink.secondary : Ink.label)
                .padding(.top, 10)
            // two lines in a narrow tile (two students a row at 1280 × 800) rather than cut
            StatusLine(status: status, text: model.statusText(paper, short: true), lines: 2, broken: model.folderBroken(paper))
                .font(.system(size: 13)).padding(.top, 3)
            let facts = Self.facts(d)
            if !facts.isEmpty {
                Text(facts).font(.system(size: 12.5)).foregroundStyle(Ink.secondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 3)
            }
        }
        .padding(12)
        .frame(width: width, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: Palette.panel)))
        .contentShape(Rectangle())
        .onTapGesture { model.openPaper(paper.path) }
        .contextMenu { PaperMenu(model: model, paper: paper, status: status) }
        .help("Open \(paper.title)’s overview")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    /// "4 rounds since Sep 8 · 28 comments"; nothing without rounds (the status line says so).
    static func facts(_ d: PaperOverview?) -> String {
        guard let d, !d.rounds.isEmpty else { return "" }
        return [count(d.rounds.count, "round") + (shortDate(d.rounds.first?.created).map { " since " + $0 } ?? ""),
                d.threads?.comments.map { count($0, "comment") }].compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - Your Move

/// Your Move (FEATURES OV-8, the mockup's `yourMoveView`): the papers that wait on you, the earliest import first, each
/// with its key page, its student, round and import, its status and one button straight into Review (Continue, Finish
/// Round N…, Show Log…); a click on its title opens its overview. The papers with students follow in one line.
struct YourMovePage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var hub: HubModel
    let width: CGFloat

    var body: some View {
        let moves = model.yourMove
        let away = model.papers.filter { model.status(of: $0) == .waiting }
        VStack(alignment: .leading, spacing: 10) {
            if moves.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Nothing waits on you.").font(.system(size: 15, weight: .semibold))
                    Text("A paper comes here when a student’s round comes in, until you finish it.")
                        .font(.system(size: 13)).foregroundStyle(Ink.secondary)
                }
                .padding(.vertical, 8)
            }
            ForEach(moves) { m in MoveRow(model: model, hub: hub, item: m) }
            if !away.isEmpty {
                Text("With students: " + HubText.list(away.map { p in
                    let since = HubText.day(hub.data[p.path]?.latest?.closedAt)
                    let who = p.student.isEmpty ? nil : StudentName.shown(p.student)
                    let paren = [who, since.map { "since " + $0 }].compactMap { $0 }.joined(separator: ", ")
                    return p.title + (paren.isEmpty ? "" : " (\(paren))")
                }) + ".")
                .font(.system(size: 12.5)).foregroundStyle(Ink.secondary)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: 860, alignment: .leading)
    }
}

struct MoveRow: View {
    @ObservedObject var model: AppModel
    @ObservedObject var hub: HubModel
    let item: MoveItem

    var body: some View {
        let p = item.paper
        let d = hub.data[p.path]
        HStack(spacing: 18) {
            KeyPageStack(thumbs: model.thumbnails, paper: p.path, data: d, width: 44, depth: 1)
            VStack(alignment: .leading, spacing: 3) {
                Button { model.openPaper(p.path) } label: {
                    Text(p.title.isEmpty ? (p.path as NSString).lastPathComponent : p.title)
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(Ink.label)
                        .lineLimit(1).truncationMode(.tail)
                }
                .buttonStyle(.plain)
                .help("Open \(p.title)’s overview")
                Text([p.student.isEmpty ? nil : StudentName.shown(p.student), item.round.map { "Round \($0)" },
                      HubText.day(item.imported).map { "came in " + $0 }].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 13)).foregroundStyle(Ink.secondary)
                StatusLine(status: item.status, text: model.statusText(p)).font(.system(size: 13.5)).padding(.top, 2)
            }
            Spacer(minLength: 12)
            Button(Self.title(item)) { model.moveAction(item) }
                .help(Self.help(item))
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 18))
        .hubCard(radius: 10)
        .contextMenu { PaperMenu(model: model, paper: p, status: item.status) }
    }

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

// MARK: - The Student page

/// A student's page (OVERVIEW-v2 §3.2, C's skeleton with B's Where the time goes; the mockup's `studentView`): who
/// waits on whom; a card for each paper with its key page, small map and numbers; then Where the comments land (each
/// comment once, numbers with short bars, the advisor's Map Headings), Where the time goes (the student's days and
/// yours, decision 8) and How comments closed. Topics wait for tags (v2).
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
        let rows = g.papers.map { (paper: $0, status: model.status(of: $0), data: hub.data[$0.path]) }
        let rounds = rows.compactMap { $0.data?.rounds.count }.reduce(0, +)
        let first = rows.compactMap { Hierarchy.date($0.data?.rounds.first?.created) }.min()
        let comments = stats?.comments ?? rows.compactMap { $0.data?.threads?.comments }.reduce(0, +)
        let meta = [count(g.papers.count, "paper"),
                    rounds > 0 ? count(rounds, "round") + (first.map { " since " + HubText.format($0, "MMM d") } ?? "") : nil,
                    comments > 0 ? count(comments, "comment") : nil].compactMap { $0 }.joined(separator: " · ")
        let lede = HubText.studentLede(rows)
        let wide = width >= 980
        let cols = width >= 860 ? 2 : 1
        let cardW = (width - CGFloat(cols - 1) * 18) / CGFloat(cols)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 24) {
                HStack(spacing: 16) {
                    Avatar(name: g.name, size: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(g.name).font(PageType.title)
                        Text(meta).font(.system(size: 14)).foregroundStyle(Ink.secondary)
                    }
                }
                .contentShape(Rectangle())
                .contextMenu { StudentMenu(model: model, group: g) }  // as the sidebar's student row (DATA.md §0.2)
                if wide && !lede.isEmpty {
                    Spacer(minLength: 12)
                    RunsText(runs: lede).font(.system(size: 14)).foregroundStyle(Ink.label2).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: width * 0.44, alignment: .leading)
                        .padding(.top, 6)
                }
            }
            if !wide && !lede.isEmpty {
                RunsText(runs: lede).font(.system(size: 14)).foregroundStyle(Ink.label2).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            }
            Text("Papers").font(.system(size: 15, weight: .semibold)).padding(.top, 22)
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(stride(from: 0, to: g.papers.count, by: cols)), id: \.self) { i in
                    HStack(alignment: .top, spacing: 18) {
                        ForEach(g.papers[i..<min(i + cols, g.papers.count)]) { p in
                            PaperCard(model: model, hub: hub, paper: p, width: cardW)
                        }
                    }
                }
            }
            .padding(.top, 10)
            Text("Writing profile").font(.system(size: 15, weight: .semibold)).padding(.top, 24)
            if let stats {
                let first = OverviewText.firstName(g.name)
                Group {
                    if wide {
                        // until v2's boxes: How comments closed under Where the comments land, so the columns are
                        // about as long (visual review 2026-10-19)
                        HStack(alignment: .top, spacing: 18) {
                            VStack(spacing: 18) {
                                LandBox(model: model, hub: hub, group: g, stats: stats, width: (width - 18) * 0.56)
                                ClosedBox(group: g, stats: stats)
                            }
                            .frame(width: (width - 18) * 0.56)
                            TimeBox(group: g, stats: stats, first: first)
                                .frame(width: (width - 18) * 0.44)
                        }
                    } else {
                        VStack(spacing: 18) {
                            LandBox(model: model, hub: hub, group: g, stats: stats, width: width)
                            TimeBox(group: g, stats: stats, first: first)
                            ClosedBox(group: g, stats: stats)
                        }
                    }
                }
                .padding(.top, 10)
                // the writing tags' parts (UX.md §24): Topics by round, First drafts, For the next draft, Done well
                StudentTagsProfile(model: model, tags: model.tags, hub: hub, group: g, stats: stats, width: width,
                                   open: g.papers.compactMap { hub.data[$0.path]?.threads?.open }.reduce(0, +))
                    .padding(.top, 18)
            } else {
                Text(hub.status == .loading ? "Reading the papers…" : "The numbers come with the engine’s overview.")
                    .font(.system(size: 13)).foregroundStyle(Ink.secondary).padding(.top, 8)
            }
        }
    }
}

/// A paper on its student's page (the mockup's `pcard`): key page, title, status, small map and its numbers.
struct PaperCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var hub: HubModel
    let paper: PaperRef
    let width: CGFloat

    var body: some View {
        let d = hub.data[paper.path]
        let status = model.status(of: paper)
        let n = d?.rounds.count ?? 0
        let thumbs = n > 0 ? min(3, n) : 1
        let facts = Self.facts(d, status: status)
        let factsW: CGFloat = 172
        let side: CGFloat = 36 + 74 + 16 + MiniMapView.labelWidth + MiniMapView.countWidth + 16 + factsW
        let mapW: CGFloat = max(60, min(176, width - side - CGFloat(thumbs - 1) * 6))
        HStack(alignment: .top, spacing: 16) {
            KeyPageStack(thumbs: model.thumbnails, paper: paper.path, data: d, width: 74)
                .opacity(model.missingPapers.contains(paper.path) ? 0.35 : 1)  // no page to draw: not a page loading
            VStack(alignment: .leading, spacing: 0) {
                Text(paper.title.isEmpty ? (paper.path as NSString).lastPathComponent : paper.title)
                    .font(.system(size: 18, weight: .semibold)).lineLimit(2)
                    .foregroundStyle(status?.isFinished == true ? Ink.label2 : Ink.label)
                StatusLine(status: status, text: model.statusText(paper), broken: model.folderBroken(paper))
                    .font(.system(size: 13.5)).padding(.top, 6)
                HStack(alignment: .top, spacing: 16) {
                    if let d, !d.rounds.isEmpty {
                        MiniMapView(map: MiniMap.make(d, maxRows: 8, ring: status?.badge != nil, fold: model.foldParts), width: mapW)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(facts.enumerated()), id: \.offset) { i, f in
                            Text(f).fontWeight(i == 1 ? .semibold : .regular).foregroundStyle(i == 1 ? Ink.label : Ink.label2)
                        }
                    }
                    .font(.system(size: 13))
                    .frame(width: factsW, alignment: .leading)
                }
                .padding(.top, 12)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(width: width, alignment: .topLeading)
        .hubCard()
        .contentShape(Rectangle())
        .onTapGesture { model.openPaper(paper.path) }
        .contextMenu { PaperMenu(model: model, paper: paper, status: status) }
        .help("Open \(paper.title)’s overview")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    /// "4 rounds since Sep 8", "28 comments", "19 resolved · 2 kept as is", "7 open" (or "finished Jul 20"); nothing
    /// without rounds (the status line says so).
    static func facts(_ d: PaperOverview?, status: PaperStatus?) -> [String] {
        guard let d, !d.rounds.isEmpty else { return [] }
        var f = [count(d.rounds.count, "round") + (shortDate(d.rounds.first?.created).map { " since " + $0 } ?? "")]
        if let t = d.threads {
            f.append(count(t.comments ?? 0, "comment"))
            f.append("\(t.resolved ?? 0) resolved · \(t.kept ?? 0) kept as is")
            if case .finished(let day)? = status {
                f.append(((t.open ?? 0) > 0 ? "\(t.open ?? 0) left open · " : "") + "finished " + (HubText.day(day) ?? ""))
            } else {
                f.append("\(t.open ?? 0) open")
            }
        }
        return f
    }
}

/// A box of the Student page: its title and quieter words at the right, then its content.
struct ProfileBox<Content: View>: View {
    let title: String
    let caption: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 15.5, weight: .semibold))
                Spacer(minLength: 8)
                Text(caption).font(.system(size: 12)).foregroundStyle(Ink.secondary).lineLimit(1)
            }
            content
        }
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .hubCard()
    }
}

/// A count with a short bar before it, scaled to the table's largest (the mockup's `.num .bar`); "–" for none.
struct CountBar: View {
    let value: Int
    let most: Int
    var bar: CGFloat = 30
    var bold = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 5) {
            if value > 0 {
                Capsule().fill(MapInk(dark: scheme == .dark).color(.mini2))
                    .frame(width: max(3, CGFloat(value) / CGFloat(max(1, most)) * bar), height: 5)
                Text("\(value)").fontWeight(bold ? .semibold : .regular).monospacedDigit()
            } else {
                Text("–").foregroundStyle(Ink.tertiary)
            }
        }
        .frame(minWidth: bar + 26, alignment: .trailing)
    }
}

/// Where the comments land (OVERVIEW-v2 §3.2; FEATURES OV-9): the student's papers over the standard sections, each
/// comment once where it was written, with the advisor's Map Headings answers (the engine's `students[].land`).
struct LandBox: View {
    @ObservedObject var model: AppModel
    @ObservedObject var hub: HubModel
    let group: StudentGroup
    let stats: StudentStats
    /// The box's width: the columns that fit beside the papers' names (each about 56 pt).
    var width: CGFloat = 640

    var body: some View {
        let land = stats.land ?? StudentStats.Land()
        let fit = LandColumns.fit(land, most: max(4, Int((width - 36 - 120) / 56)))
        let titles = fit.titles
        let rows: [(String, [Int], Bool)] = zip(land.papers, fit.rows).compactMap { r, counts in
            group.papers.first { $0.path == r.path }.map { ($0.title, counts, false) }
        } + (land.papers.count > 1 ? [(land.papers.count == 2 ? "Both papers" : "All \(land.papers.count) papers", fit.total, true)] : [])
        let most = rows.flatMap(\.1).max() ?? 1
        let pending = group.papers.compactMap { hub.data[$0.path]?.pending.count }.reduce(0, +)
        ProfileBox(title: "Where the comments land", caption: "each comment once, where you wrote it") {
            Text(land.total.reduce(0, +) == 0 && pending > 0
                 ? "Finding the sections of \(count(pending, "round"))… the comments land here once they are found."
                 : HubText.land(titles, land.total) + (pending > 0 ? " Sections of \(count(pending, "round")) are still being found." : ""))
                .font(.system(size: 13.5)).foregroundStyle(Ink.label2)
                .fixedSize(horizontal: false, vertical: true)
            if !titles.isEmpty { table(titles: titles, rows: rows, most: most, other: fit.other) }
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(mapped).font(.system(size: 12)).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Map Headings…") { model.mappingHeadings = group.key }
                    .buttonStyle(LinkStyle())
                    .font(.system(size: 12, weight: .medium))
                    .help("Say once for each paper which standard section each of its headings belongs to")
            }
        }
    }

    private func table(titles: [String], rows: [(String, [Int], Bool)], most: Int, other: String?) -> some View {
        Grid(alignment: .trailing, horizontalSpacing: 6, verticalSpacing: 0) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    ForEach(Array(titles.enumerated()), id: \.offset) { i, t in
                        Text(Self.short(t)).font(.system(size: 12)).foregroundStyle(Ink.secondary).lineLimit(1)
                            .help(t == "Other" && i == titles.count - 1 ? other ?? t : t)
                    }
                }
                .padding(.bottom, 5)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        Text(r.0).fontWeight(r.2 ? .semibold : .regular).lineLimit(1).truncationMode(.tail)
                            .frame(minWidth: 70, maxWidth: .infinity, alignment: .leading)
                            .help(r.0)
                        ForEach(Array(r.1.enumerated()), id: \.offset) { _, v in CountBar(value: v, most: most, bar: 28, bold: r.2) }
                    }
                    .padding(.vertical, 6)
                }
            }
            .font(.system(size: 13))
    }

    /// "Intro.", "Disc.", "Concl." (the mockup's), the others as they are.
    static func short(_ t: String) -> String {
        ["Introduction": "Intro.", "Discussion": "Disc.", "Conclusion": "Concl."][t] ?? t
    }

    private var mapped: String { Self.mapped(group.papers, data: hub.data) }

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
}

/// Where the time goes (OVERVIEW-v2 §3.2, from B; decision 8: the student's days and yours): each round trip, the
/// days with you (import to close) and with the student (close to the next import), the open round so far.
struct TimeBox: View {
    let group: StudentGroup
    let stats: StudentStats
    let first: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = MapInk(dark: scheme == .dark)
        let trips = (stats.time ?? []).filter { t in group.papers.contains { $0.path == t.path } }
        let titles = Dictionary(group.papers.map { ($0.path, $0.title) }, uniquingKeysWith: { a, _ in a })
        let most = max(1, trips.map { ($0.you ?? 0) + ($0.student ?? 0) }.max() ?? 1)
        let px = 118 / CGFloat(most)
        let who = first.isEmpty ? "the student" : first
        ProfileBox(title: "Where the time goes", caption: "days per round trip") {
            Text(HubText.time(trips, titles: titles, first: first)).font(.system(size: 13.5)).foregroundStyle(Ink.label2)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
                ForEach(Array(trips.enumerated()), id: \.offset) { i, t in
                    if i == 0 || trips[i - 1].path != t.path {
                        GridRow {
                            Text(titles[t.path] ?? "").fontWeight(.medium).lineLimit(1).truncationMode(.tail)
                                .gridCellColumns(3)
                                .padding(.top, i == 0 ? 0 : 4)
                        }
                    }
                    GridRow {
                        Text(t.open ? "R\(t.round), " + (t.failed == true ? "build failed" : "open") : "R\(t.round) → R\(t.next ?? t.round + 1)")
                            .foregroundStyle(Ink.secondary)
                            .lineLimit(1).fixedSize()
                            .padding(.leading, 12)
                        HStack(spacing: 1) {
                            if t.open {
                                RoundedRectangle(cornerRadius: 1.5).strokeBorder(ink.color(.attention), lineWidth: 1.5)
                                    .frame(width: max(6, CGFloat(t.you ?? 0) * px), height: 9)
                            } else {
                                RoundedRectangle(cornerRadius: 1.5).fill(ink.color(.chartYou)).frame(width: max(3, CGFloat(t.you ?? 0) * px), height: 9)
                                RoundedRectangle(cornerRadius: 1.5).fill(ink.color(.chartStudent)).frame(width: CGFloat(t.student ?? 0) * px, height: 9)
                            }
                        }
                        .frame(width: 120, alignment: .leading)
                        (t.open ? Text("you ") + Text("\(t.you ?? 0)").fontWeight(.semibold) + Text(" " + days(t.you) + " so far")
                         : Text("you ") + Text("\(t.you ?? 0)").fontWeight(.semibold) + Text(" · \(first.isEmpty ? "student" : first) ")
                            + Text("\(t.student ?? 0)").fontWeight(.semibold) + Text(" " + days(t.student)))
                            .foregroundStyle(Ink.label2).lineLimit(1).fixedSize()
                    }
                    .help(help(t, who: who))
                }
            }
            .font(.system(size: 13))
            HStack(spacing: 14) {
                HStack(spacing: 5) { RoundedRectangle(cornerRadius: 1.5).fill(ink.color(.chartYou)).frame(width: 12, height: 9); Text("with you") }
                HStack(spacing: 5) { RoundedRectangle(cornerRadius: 1.5).fill(ink.color(.chartStudent)).frame(width: 12, height: 9); Text("with \(who)") }
                HStack(spacing: 5) { RoundedRectangle(cornerRadius: 1.5).strokeBorder(ink.color(.attention), lineWidth: 1.5).frame(width: 12, height: 9); Text("open, so far") }
            }
            .font(.system(size: 12)).foregroundStyle(Ink.secondary)
            Text("With you: came in → you finished. With \(who): you finished → next round came in, so those days include any wait before it came in.")
                .font(.system(size: 12)).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func days(_ n: Int?) -> String { n == 1 ? "day" : "days" }

    private func help(_ t: StudentStats.Trip, who: String) -> String {
        guard !t.open else {
            return "Round \(t.round) " + (t.failed == true ? "did not build; it has been with you " : "has been with you ")
                + "\(t.you ?? 0) \(days(t.you)) so far"
        }
        var s = "Round \(t.round): with you \(t.you ?? 0) \(days(t.you)), then with \(who) \(t.student ?? 0) \(days(t.student)) until Round \(t.next ?? t.round + 1) came in"
        if let r = t.received {
            s += r >= 0 ? "; \(who)’s files last changed \(r) \(days(r)) after you finished" : "; the files had last changed before you finished"
        }
        return s
    }
}

/// How comments closed (OVERVIEW-v2 §3.2): after 1, 2 or 3+ rounds you answered in, still open, followed up; each
/// comment once, no averages, no comparison with other students.
struct ClosedBox: View {
    let group: StudentGroup
    let stats: StudentStats

    var body: some View {
        let rows = (stats.closed?.papers ?? []).compactMap { r in group.papers.first { $0.path == r.path }.map { ($0.title, r.values) } }
        let most = rows.flatMap(\.1).max() ?? 1
        let after = stats.closed?.total.untouchedAfterFollowUp ?? 0
        ProfileBox(title: "How comments closed", caption: "rounds you answered in") {
            Grid(alignment: .trailing, horizontalSpacing: 8, verticalSpacing: 0) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    ForEach(["1 round", "2", "3+", "still open", "followed up"], id: \.self) { h in
                        Text(h).font(.system(size: 12)).foregroundStyle(Ink.secondary).lineLimit(1)
                    }
                }
                .padding(.bottom, 5)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        Text(r.0).lineLimit(1).truncationMode(.tail)
                            .frame(minWidth: 70, maxWidth: .infinity, alignment: .leading)
                            .help(r.0)
                        ForEach(Array(r.1.enumerated()), id: \.offset) { _, v in CountBar(value: v, most: most, bar: 20) }
                    }
                    .padding(.vertical, 6)
                }
            }
            .font(.system(size: 13))
            Text("Each comment once. Followed up: you asked again at least once" + (after > 0 ? "; \(after) \(after == 1 ? "was" : "were") then left untouched" : "")
                 + ". Comments you left open count against nobody. No averages, no comparison with other students.")
                .font(.system(size: 12)).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
