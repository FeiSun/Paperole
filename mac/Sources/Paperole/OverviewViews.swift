import AppKit
import SwiftUI

/// The overview's geometry (OVERVIEW-v2 §2 and the mockup's `geo`): the window's content inset 24 pt, and the readout
/// at the right (UI v4, mac/UX.md §40.3). The map's own is `MapGeometry`.
enum OverviewLayout {
    static let inset: CGFloat = 24
    /// The overview's scrolled content, where the map's top is measured.
    static let space = "overview"
    /// The overview's visible frame, where its help tags are placed.
    static let viewport = "overview viewport"

    /// The readout's columns, by the data only (UI v4): Comments, and You once a shown round has answers. The
    /// student's responses are in the round's help tag and the table (the UI audit of 2026-10-21: a wide readout took
    /// the room the map's cells needed for their names).
    static func readoutColumns(you: Bool) -> Int { you ? 2 : 1 }
    /// A fixed width, whatever the columns, so the Sage line under the readout keeps its room (plan §5 R2).
    static let readoutWidth: CGFloat = 168
}

/// One round as the overview lists it without the engine's overview (the map is `MapScene`'s): from the paper's
/// state, latest first, its rail's dates and whether its build failed.
struct OverviewRow: Identifiable, Equatable {
    var n: Int
    var dates: String
    var failed = false
    var id: Int { n }

    static func rows(state rounds: [RoundSummary]) -> [OverviewRow] {
        rounds.reversed().map { r in
            OverviewRow(n: r.n, dates: OverviewText.dates(r.created, r.closed ? r.closedAt : nil), failed: r.status == "failed")
        }
    }
}

extension OverviewText {
    /// The rail's dates: "Oct 16 →" for the open round, "Sep 6 → 9" or "Sep 28 → Oct 2" for a closed one.
    static func dates(_ created: String?, _ closed: String?) -> String {
        guard let a = shortDate(created) else { return "" }
        guard let closed, let b = shortDate(closed) else { return a + " →" }
        if a == b { return a }
        let sameMonth = a.split(separator: " ").first == b.split(separator: " ").first
        return a + " → " + (sameMonth ? String(b.split(separator: " ").last ?? "") : b)
    }
}

/// A click and a double click on one view (OVERVIEW-v2 §5.1): the click acts at once, without waiting to see whether
/// a second comes (a TapGesture of count 2 would delay it); a second click within the system's double-click interval
/// opens Review. The view stays under the pointer between the two (what a click follows is redrawn, not removed).
struct Clicks: ViewModifier {
    let single: () -> Void
    let double: () -> Void
    @State private var last: TimeInterval?

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture {
                let now = ProcessInfo.processInfo.systemUptime
                if let l = last, now - l <= NSEvent.doubleClickInterval {
                    last = nil  // a third click starts again
                    double()
                } else {
                    last = now
                    single()
                }
            }
    }
}

extension View {
    func clicks(_ single: @escaping () -> Void, double: @escaping () -> Void) -> some View {
        modifier(Clicks(single: single, double: double))
    }
}

/// The overview's scroll view, for its offset (`OverviewModel.scrollView`): a probe in its content.
struct OverviewScrollProbe: NSViewRepresentable {
    let overview: OverviewModel

    final class Probe: NSView {
        weak var overview: OverviewModel?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
        }

        func attach() {
            MainActor.assumeIsolated {
                guard window != nil, let sv = enclosingScrollView, overview?.scrollView !== sv else { return }
                overview?.scrollView = sv
            }
        }
    }

    func makeNSView(context: Context) -> Probe {
        let p = Probe()
        p.overview = overview
        return p
    }

    func updateNSView(_ p: Probe, context: Context) {
        p.overview = overview
        DispatchQueue.main.async { p.attach() }
    }
}

/// A paper's overview (OVERVIEW-v2 §3.3, UX.md §21, §40.4), over Review, which stays hidden behind it: the header with
/// the title and the figure of the paper's state; the pages of the strip's round and the section ruler; the paper map
/// with its readout and its Key; Topics, or the panel of what it follows. Older rounds fold when the map would run past the
/// window's bottom (§4.1): the room is measured from the map's top in the scrolled content.
struct OverviewScreen: View {
    let model: AppModel
    @ObservedObject var overview: OverviewModel
    @State private var mapTop: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width - 2 * OverviewLayout.inset, 300)
            ZStack(alignment: .topLeading) {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        let scene = scene(width: width, viewport: geo.size.height)
                        // the ruler names each section with the map's stem (the UI audit: "1 Intro." over "Int."); a
                        // folder not there has no pages to show, only its line (UX.md §28)
                        if !folderGone {
                            PageStripView(model: model, overview: overview, thumbs: model.thumbnails, hover: overview.hover, width: width,
                                          names: scene?.names ?? [:])
                        }
                        map(width: width, scene: scene)
                            .padding(.top, 1)
                        // Topics under the Key while nothing is followed, or a tag is: its row then on the accent's
                        // tint and the tag's comments under it, so nothing moves under the pointer (UX.md §24)
                        if case .tag? = overview.selection {
                            TopicsView(model: model, overview: overview, tags: model.tags, width: width)
                        }
                        if let s = overview.selection {
                            OverviewPanelView(model: model, overview: overview, selection: s, width: width, student: firstName)
                                .padding(.top, 14)
                        } else {
                            TopicsView(model: model, overview: overview, tags: model.tags, width: width)
                        }
                        PageHelpLink(model: model, topic: .paperMap)
                    }
                    .padding(EdgeInsets(top: 18, leading: OverviewLayout.inset, bottom: 26, trailing: OverviewLayout.inset))
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .contentShape(Rectangle())
                    .onTapGesture { model.overviewClicked(nil) }  // a click on empty space follows nothing (§5.1)
                    .background(OverviewScrollProbe(overview: overview))
                    .coordinateSpace(name: OverviewLayout.space)
                    .onPreferenceChange(MapTopKey.self) { y in
                        MainActor.assumeIsolated { overview.mapTop = y }
                        if abs(y - mapTop) > 0.5 { mapTop = y }
                    }
                }
                OverviewTipLayer(hover: overview.hover, size: geo.size)
            }
            .background(OverviewKeyTarget(overview: overview))
            .coordinateSpace(name: OverviewLayout.viewport)
            .onContinuousHover { phase in if case .ended = phase { overview.hover.leave() } }
        }
        .background(Color(nsColor: Palette.panel))
        .foregroundStyle(Ink.label)
    }

    private var firstName: String { OverviewText.firstName(student) }

    private var title: String {
        model.state?.paper.title ?? overview.data?.paper?.title
            ?? model.papers.first { $0.path == model.selectedPath }?.title ?? ""
    }

    /// The ledger's, else the list's copy (a folder missing, or a ledger that cannot be read).
    private var student: String {
        model.state?.paper.student ?? overview.data?.paper?.student
            ?? model.papers.first { $0.path == model.selectedPath }?.student ?? ""
    }

    private var buildErrors: String? { model.overviewBuildErrors }

    /// The paper's folder is not there (missing, or on a drive not connected).
    private var folderGone: Bool {
        model.papers.first { $0.path == model.selectedPath }.flatMap(model.missingWords) != nil
    }

    /// The title (New York 22 Semibold, two lines at most) over the student, and at the right the figure the paper's
    /// state calls for (UI v4, mac/UX.md §40.4; mockup `.ph`). The first sentence and the facts are its help tag and
    /// VoiceOver's, so no number of the older header is lost.
    private var header: some View {
        let sentence = OverviewText.firstSentence(overview.data, student: student, fallback: model.state?.rounds ?? [], errors: buildErrors)
        let facts = OverviewText.facts(overview.data, rounds: model.state?.rounds ?? [], pages: model.round?.build.pages)
        let help = OverviewText.headerHelp(sentence, facts)
        return HStack(alignment: .top, spacing: 48) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(PageType.paperTitle)
                    .lineLimit(2).truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                Text(StudentName.shown(student)).font(TypeScale.body).foregroundStyle(Ink.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let h = model.paperHeader {
                PaperHeaderFigure(header: h, round: overview.data?.latest?.n)
                    .frame(width: 300, alignment: .leading)
            }
        }
        .padding(.bottom, 16)
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, model.paperHeader?.words, model.paperHeader?.response?.words, model.paperHeader?.closedHelp,
                             model.paperHeader?.answered, help].compactMap { $0 }.joined(separator: ". "))
    }

    /// The map's scene for the overview's width (nil as a table, or without the engine's overview); built before the
    /// strip, whose ruler reads its names.
    private func scene(width: CGFloat, viewport: CGFloat) -> MapScene? {
        guard let d = overview.data, !d.rounds.isEmpty, !overview.asTable else { return nil }
        let fold = MapRules.folded(rounds: d.rounds.count, room: viewport - mapTop - 52)
        let t0 = ProcessInfo.processInfo.systemUptime
        let scene = MapScene.build(MapInput(data: d, width: width, fold: fold, unfold: overview.unfold, strip: model.stripRound,
                                            selection: overview.selection, student: firstName, buildErrors: buildErrors,
                                            readyToFinish: d.summary?.step == .allChecked, foldParts: model.foldParts,
                                            shownParts: overview.shownParts, stripShown: !folderGone))
        MapTiming.built(since: t0)
        return scene
    }

    /// The map and its Key, or, without the engine's overview, why not and the rounds the state knows.
    @ViewBuilder
    private func map(width: CGFloat, scene: MapScene?) -> some View {
        if let d = overview.data, !d.rounds.isEmpty {
            let first = firstName
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    if let scene {
                        PaperMapView(model: model, overview: overview, hover: overview.hover, scene: scene, data: d, student: first)
                    } else {
                        MapTableView(model: model, overview: overview, table: MapTable.make(d, selection: overview.selection, student: first),
                                     data: d, width: width, student: first)
                            .padding(.top, 14).padding(.bottom, 8)
                    }
                }
                .background(GeometryReader { g in
                    Color.clear.preference(key: MapTopKey.self, value: g.frame(in: .named(OverviewLayout.space)).minY)
                })
                // the first-use tip at the left (UI v4 BRIEF 03), the Key at the right
                HStack(alignment: .top, spacing: 16) {
                    let place = OverviewTip.place(scene)
                    OverviewTip(tips: model.actions.tips, x0: place.x0, arrow: place.arrow)
                    Spacer(minLength: 0)
                    Button("Key") { overview.keyOpen.toggle() }
                        .controlSize(.small)
                        .help("What the marks on this map mean")
                        .popover(isPresented: $overview.keyOpen, arrowEdge: .bottom) {
                            MapKeyPopover(rows: MapKeyRow.rows(scene, d), steps: MapShade.steps(MapShade.counts(d))) {
                                overview.keyOpen = false
                                model.openHelp(.paperMap)
                            }
                        }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if let line = statusLine {
                    Text(line).font(.system(size: 12)).foregroundStyle(Ink.secondary)
                }
                ForEach(OverviewRow.rows(state: model.state?.rounds ?? [])) { r in
                    HStack(spacing: 8) {
                        Text("Round \(r.n)").font(.system(size: 12.5, weight: .semibold))
                        Text(r.dates).font(.system(size: 11)).foregroundStyle(Ink.secondary)
                        if r.failed { Text("build failed").font(.system(size: 11)).foregroundStyle(Ink.label2) }
                    }
                    .clicks({ model.overviewClicked(.round(r.n)) }, double: { model.overviewClicked(.round(r.n), double: true) })
                }
            }
            .padding(.top, 14)
        }
    }

    private var statusLine: String? {
        switch overview.status {
        case .unavailable: return "The paper map needs the engine’s overview, which this engine does not have yet."
        case .failed(let m):
            // a folder missing says only that, as its row and tile do (its path is in the row's help tag)
            let ref = model.papers.first { $0.path == model.selectedPath }
            return ref.flatMap(model.missingWords).map { $0 + "." } ?? "The overview could not be read: " + m
        case .loading, .idle: return "Reading the rounds…"
        default: return nil
        }
    }
}

/// The paper page's header figure (UI v4, mac/UX.md §40.4; mockup `.pfig`), by the paper's state (plan §5 R7): to
/// check, the 22 pt figure and the response bar under it; ready, to read, a first draft or a failed build, its sign
/// and words; with the student or finished, comments, closed and open.
struct PaperHeaderFigure: View {
    let header: PaperHeader
    /// The round that came in, for the response bar's help tag.
    var round: Int?
    /// After the to-check figure's nouns; none on the student page's action card.
    var tail: String? = "to check"

    var body: some View {
        switch header.figure {
        case .toCheck(let c):
            let tc = ToCheckFigure(comments: c.comments, edits: c.edits, fill: fill, size: 22, tail: tail,
                                       answered: header.answered)
            VStack(alignment: .leading, spacing: 12) {
                if let n = header.closed {
                    let closed = (Text("\(n)").fontWeight(.semibold).foregroundColor(Ink.label2) + Text(" closed"))
                        .font(TypeScale.body).foregroundStyle(Ink.secondary).fixedSize()
                        .help(ifAny: header.closedHelp)
                    // beside the figure, else under it when the line is wider than the column
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) { tc; closed }.frame(height: 28)
                        VStack(alignment: .leading, spacing: 4) { tc.frame(height: 28); closed }
                    }
                } else {
                    tc.frame(height: 28)
                }
                if let r = header.response { ResponseBar(response: r, round: round) }
            }
        case .ready: line(.ready, "Ready to finish")
        case .toRead(let n): figure(.ring(1), n, n == 1 ? "paragraph to read" : "paragraphs to read")
        case .firstDraft: line(.ring(0), "First draft")
        case .failed: line(.failed, "Build failed")
        case .totals(let t, let finished): FigureColumns(figures: header.columns(t, finished: finished))
        }
    }

    private var fill: Double { if case .ring(let f) = header.glyph { return f } else { return 0 } }

    private func line(_ g: StatusGlyph, _ words: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            StatusGlyphView(g, text: 22)
            Text(words).font(TypeScale.title1).lineLimit(1).fixedSize()
        }
        .frame(height: 28)
    }

    private func figure(_ g: StatusGlyph, _ n: Int, _ words: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            StatusGlyphView(g, text: 22)
            Text("\(n)").font(TypeScale.title1).monospacedDigit()
            Text(words).font(TypeScale.body).foregroundStyle(Ink.secondary)
        }
        .lineLimit(1).fixedSize()
        .frame(height: 28)
    }
}

/// The map's top in the overview's scrolled content, for the fold (`MapRules.folded`).
struct MapTopKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    /// The views round the map give none (0): the map's own is the largest.
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Lays its subviews out in rows, wrapping at the width offered.
struct WrapLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews) {
            var x = bounds.minX
            for i in row.items {
                let s = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(s))
                x += s.width + spacing
            }
        }
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [(items: [Int], y: CGFloat, width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], y: CGFloat, width: CGFloat, height: CGFloat)] = []
        var items: [Int] = [], x: CGFloat = 0, y: CGFloat = 0, h: CGFloat = 0
        for (i, v) in subviews.enumerated() {
            let s = v.sizeThatFits(.unspecified)
            if !items.isEmpty && x + s.width > width {
                rows.append((items, y, x - spacing, h))
                y += h + spacing
                items = []; x = 0; h = 0
            }
            items.append(i)
            x += s.width + spacing
            h = max(h, s.height)
        }
        if !items.isEmpty { rows.append((items, y, x - spacing, h)) }
        return rows
    }
}

/// The toolbar's ‹ › (OVERVIEW-v2 mockup; ⌘[ and ⌘] in the Go menu): the window's history, in both levels.
/// Compact (borderless, 24 pt each), so Review's toolbar keeps its room: at the window's minimum width Finish Round…
/// still fits beside a long title, as before.
struct HistoryButtons: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            Button { model.goBack() } label: { Image(systemName: "chevron.left").frame(width: 24, height: 24) }
                .disabled(!model.canGoBack)
                .help(model.backLabel.map { "Back to \($0) (⌘[)" } ?? "Back (⌘[)")  // a step in the PDF named (PLAN §5.3)
                .accessibilityLabel("Back")
            Button { model.goForward() } label: { Image(systemName: "chevron.right").frame(width: 24, height: 24) }
                .disabled(!model.canGoForward)
                .help(model.forwardLabel.map { "Forward to \($0) (⌘])" } ?? "Forward (⌘])")
                .accessibilityLabel("Forward")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 14, weight: .medium))
        .contentShape(Rectangle())
    }
}

/// The paper's width, for the toolbar titles' room: written by a reader behind PaperView into `OverviewModel.width`,
/// which only the titles observe, so a resize redraws nothing else; once it settles the toolbar is laid out again
/// (`AppModel.toolbarWidthChanged`).
struct PaperWidthReader: View {
    let model: AppModel

    var body: some View {
        GeometryReader { g in
            Color.clear
                .onAppear { model.overview.width = g.size.width }
                .onChange(of: g.size.width) { _, w in
                    model.overview.width = w
                    model.toolbarWidthChanged()
                }
        }
    }
}

/// The empty item that lays the toolbar out again (`AppModel.toolbarNudge`): nothing to see or say.
struct ToolbarNudge: View {
    var body: some View {
        Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
    }
}

/// The toolbar's title and subtitle (from macOS 15) in either level, truncated in a narrow window to leave room for
/// the items after it (`reserve`, besides the title): with ‹ › before it, a long title pushed Review's Finish Round…,
/// or the overview's Continue Round N, into the toolbar's overflow at the window's minimum width. In a wide window it
/// is whole, as before.
struct ToolbarTitle: View {
    @ObservedObject var model: AppModel
    @ObservedObject var overview: OverviewModel
    let reserve: CGFloat
    /// More room while the overview follows something (its "Following …" token).
    var following: CGFloat = 0

    var body: some View {
        let token = overview.selection.map { following + Self.extra(OverviewText.following($0, overview.data)) } ?? 0
        let room = overview.width > 0 ? overview.width - reserve - token : 600
        VStack(alignment: .leading, spacing: 0) {
            Text(model.state?.paper.title ?? model.papers.first { $0.path == model.selectedPath }?.title ?? "")
                .font(.system(size: 13, weight: .semibold))
            Text(model.windowSubtitle).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: max(160, room), alignment: .leading)
        .padding(.leading, 4)
    }

    /// The token's room past a short name (`following` is for a name of 60 pt): a section's long title takes more,
    /// up to the token's 180 pt for it, so the token, More and Continue Round N stay out of the toolbar's overflow.
    static func extra(_ name: String) -> CGFloat {
        let w = (name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width
        return max(0, min(180, ceil(w)) - 60)
    }
}

/// The overview's toolbar on the right (§5.1; UI v4): "Following Methods ×" while it follows something, Map | Table,
/// the More menu ("⋯"), and Continue Round N, the window's one Sage button (or Show Log… / Open Round N, plain).
struct OverviewToolbarTrail: View {
    @ObservedObject var model: AppModel
    @ObservedObject var overview: OverviewModel

    var body: some View {
        HStack(spacing: 10) {
            if let s = overview.selection {
                HStack(spacing: 5) {
                    // the token keeps its words; the title gives way (OverviewToolbarTitle)
                    Text("Following").foregroundStyle(Ink.secondary)
                    Text(OverviewText.following(s, overview.data)).fontWeight(.semibold).foregroundStyle(Ink.accentText)
                        .lineLimit(1).frame(maxWidth: 180, alignment: .leading).fixedSize(horizontal: true, vertical: false)
                    Button { model.overviewClicked(nil) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Ink.secondary)
                        .help("Show the whole paper (Esc)")
                        .accessibilityLabel("Stop following")
                }
                .font(.system(size: 12))
                .fixedSize()
                .padding(.horizontal, 8).frame(height: 22)
                .background(Capsule().fill(Color(nsColor: Palette.accentTint)))
            }
            if overview.data?.rounds.isEmpty == false {
                Picker("View", selection: Self.mapOrTable(model)) {
                    Image(systemName: "square.grid.3x2").help("Map").accessibilityLabel("Map").tag(false)
                    Image(systemName: "tablecells").help("Table").accessibilityLabel("Table").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Menu {
                if let r = overview.data?.rounds.last(where: { $0.isClosed && $0.finalPdf != nil }), let final = r.finalPdf {
                    Button("Open Round \(r.n) final.pdf") { NSWorkspace.shared.open(URL(fileURLWithPath: final)) }
                }
                // each finished round's card (RoundCard.swift), the latest first
                let finished = (overview.data?.rounds ?? []).filter(\.isClosed).map(\.n).reversed()
                if finished.count == 1, let n = finished.first {
                    Button("Round \(n) Summary…") { model.openRoundSummary(n) }
                } else if finished.count > 1 {
                    Menu("Round Summary") {
                        ForEach(Array(finished), id: \.self) { n in Button("Round \(n)…") { model.openRoundSummary(n) } }
                    }
                }
                if let a = model.resumable() {  // the latest round, finished (UX.md §31)
                    Button("Resume Round \(a.round)") { model.askResume() }
                }
                if model.canStartRound {
                    Button(model.round == nil ? "Start Round 1…" : "New Round…") { model.startRound() }
                }
                if overview.data?.comments.isEmpty == false {
                    Button("Tag Comments…") { model.openTagComments() }
                }
                if let p = model.selectedPath {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More for this paper")
            if let c = model.continueButton {
                if c.prominent {
                    Button(c.title) { model.openReview(ReviewTarget(round: c.round)) }
                        .buttonStyle(.borderedProminent)
                        .help("Review Round \(c.round): its PDF and comments (or double-click the paper)")
                } else {
                    Button(c.title) { model.openReview(ReviewTarget(round: c.round)) }
                        .help("Open Round \(c.round) in Review")
                }
            }
        }
    }

    /// The Map | Table control's choice: the map as a table, the viewer's (`AppModel.setMapAsTable`).
    static func mapOrTable(_ model: AppModel) -> Binding<Bool> {
        Binding(get: { model.overview.asTable }, set: { model.setMapAsTable($0) })
    }
}
