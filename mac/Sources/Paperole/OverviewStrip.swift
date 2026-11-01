import AppKit
import SwiftUI

/// The page strip of one round (OVERVIEW-v2 §3.3; UI v4, UX.md §40.4): its pages as thumbnails at their slots with the
/// comments' marks of the round (neutral, the followed comment in its colour) and their numbers (with a ring and the
/// count where a page has something to check), and under it the section ruler. A click on a page follows it, a
/// double click opens Review there; a click on a section name follows the section. It shows the round previewed under
/// the pointer while there is one (`AppModel.shownStripRound`), at one height for every round of the paper.
struct PageStripView: View {
    let model: AppModel
    @ObservedObject var overview: OverviewModel
    @ObservedObject var thumbs: ThumbnailStore
    let hover: OverviewHover
    let width: CGFloat
    /// The map's names (`MapScene.names`), for the ruler.
    var names: [String: MapScene.SectionName] = [:]
    @State private var last: (target: StripTarget?, time: TimeInterval)?

    var body: some View {
        let d = overview.data
        let n = model.shownStripRound
        let r = n.flatMap { d?.round($0) }
        let pages = r?.build?.pages ?? (n == model.round?.n ? model.round?.build.pages : nil) ?? 0
        let toCheck = Self.pagesToCheck(r, d)
        let row = Self.rowHeight(d, thumb: { thumbs.thumbSize(pdf: $0) })
        VStack(alignment: .leading, spacing: 0) {
            // the strip's round, the latest's too, on a line of its own; every row under it as high in every round, so
            // nothing moves when a click or the pointer shows another round's pages (the advisor's review of 2026-10-31)
            Text(Self.roundLabel(n) ?? " ")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.secondary)
                .frame(height: 16, alignment: .topLeading)
                .padding(.bottom, 6)
            if let n, let r, pages > 0, !r.failed {
                let geo = StripGeometry(width: width, pages: pages, thumb: thumbs.thumbSize(pdf: r.pdf), row: row)
                // the strip and its ruler scroll sideways together when the round's pages are wider than the overview
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 0) {
                        strip(n, r, geo: geo, toCheck: toCheck)
                        SectionRuler(model: model, overview: overview, hover: hover, round: r, geo: geo, names: names)
                            .padding(.top, 1)
                    }
                    .background(StripScrollProbe(scroll: overview.stripScroll))
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .frame(width: width, height: row + 20 + 21, alignment: .topLeading)
                .background(GeometryReader { g in
                    let o = g.frame(in: .named(OverviewLayout.viewport)).origin
                    Color.clear
                        .onAppear { origins(o, row: row) }
                        .onChange(of: o) { _, v in origins(v, row: row) }
                })
                .onAppear { overview.stripScroll.shown(round: n, geo: geo) }
                .onChange(of: StripShown(round: n, geo: geo)) { _, v in overview.stripScroll.shown(round: v.round, geo: v.geo) }
            } else {
                Text(Self.noPages(r, loading: overview.status == .loading))
                    .font(.system(size: 12)).foregroundStyle(Ink.secondary)
                    .frame(height: row + 20 + 21, alignment: .center)
            }
        }
        .frame(width: width, alignment: .leading)
        // the pointer here keeps the round shown, so a round previewed from the map can be clicked (§40.9); nothing
        // while the app is not active, as on the map
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            if case .active = phase { if NSApp.isActive { overview.point(strip: true) } } else { overview.point(strip: false) }
        }
        .onAppear { prefetch() }
        .onChange(of: d?.rounds.map(\.pdf)) { _, _ in prefetch() }
    }

    private struct StripShown: Equatable {
        var round: Int
        var geo: StripGeometry
    }

    /// The strip's and the ruler's top left in the overview's visible frame (the strip's, unscrolled: its tags add the
    /// scroll), for their tags and the debug script.
    private func origins(_ o: CGPoint, row: CGFloat) {
        hover.stripOrigin = o
        hover.rulerOrigin = CGPoint(x: o.x, y: o.y + row + 20 + 1)
    }

    /// "Round 1" over the strip, for every round it shows (the latest too: the advisor's review of 2026-10-31).
    static func roundLabel(_ n: Int?) -> String? {
        n.map { "Round \($0)" }
    }

    /// The thumbnails' row for this paper, the same for every round it shows (so nothing under it moves): 72 pt (a
    /// Letter page's thumbnail), or as high as its tallest pages' thumbnails (an A4 paper's 76.5); a page lower than
    /// the row sits on the numbers' line (`StripGeometry.top`). The thumbnails are never smaller for a longer round
    /// (the advisor's decision of 2026-11-01: one size for every paper; a round wider than the overview scrolls).
    static func rowHeight(_ d: PaperOverview?, thumb: (String?) -> CGSize) -> CGFloat {
        let heights = (d?.rounds ?? []).compactMap { r -> CGFloat? in
            guard !r.failed, let pages = r.build?.pages, pages > 0 else { return nil }
            return thumb(r.pdf).height
        }
        return max(StripGeometry.height, heights.max() ?? 0)
    }

    /// Every built round's pages asked for once the overview is in (read from the folder, or drawn off the main
    /// thread), so a round previewed or clicked shows its pages at once; not past half the store's capacity, nor past
    /// the room it has left: full, it lets every image go, the pages shown with them.
    private func prefetch() {
        guard let d = overview.data, let paper = model.selectedPath else { return }
        let built = d.rounds.filter { !$0.failed }
        let pages = built.reduce(0) { $0 + ($1.build?.pages ?? 0) }
        guard pages <= thumbs.capacity / 2, thumbs.count + pages <= thumbs.capacity else { return }
        for r in built {
            for p in 0..<(r.build?.pages ?? 0) { _ = thumbs.image(paper: paper, pdf: r.pdf, page: p, height: StripGeometry.height) }
        }
    }

    /// Why the strip shows no pages: the overview is being read, the round's build failed, or none to show (the
    /// overview could not be read, or the round is gone: the code audit, it said the build failed then).
    static func noPages(_ r: PaperOverview.Round?, loading: Bool) -> String {
        if loading { return "Reading the rounds…" }
        if let r, r.failed { return "No PDF for Round \(r.n): the build failed." }
        return "No pages yet."
    }

    /// One page of the strip: its thumbnail, its number (then the ring and the page's count to check, or the ring on
    /// the page's corner; the key page's bookmark), its menu. The cell is as wide as the thumbnail, so it stays at its
    /// slot (`StripGeometry.thumbX`, where clicks find it): the row under it is centred on it and may run past it (the
    /// code audit: the key page's bookmark widened the cell).
    @ViewBuilder
    private func pageCell(_ n: Int, _ r: PaperOverview.Round, page p: Int, geo: StripGeometry,
                          framing: (framed: Set<Int>, dimmed: Set<Int>), labels: StripLabels, followed: Set<String>,
                          pageSize: @escaping (Int) -> CGSize?, key: (page: Int, chosen: Bool)?, toCheck: [Int: Int]) -> some View {
        let image = thumbs.image(paper: model.selectedPath ?? "", pdf: r.pdf, page: p, height: geo.thumbHeight)
        let k = toCheck[p] ?? 0
        VStack(spacing: 6) {
            PageThumb(image: image, round: r, data: overview.data, page: p, size: CGSize(width: geo.thumbWidth, height: geo.thumbHeight),
                      pageSize: image == nil ? nil : pageSize(p), followed: followed, framed: framing.framed.contains(p))
                .overlay(alignment: .topTrailing) {
                    // a crowded strip: the ring on the page's corner, so the numbers keep their room
                    if k > 0 && !labels.ringBeside {
                        Circle().fill(Color(nsColor: Palette.panel)).frame(width: 10, height: 10)
                            .overlay(StatusGlyphView(.ring(0), size: 10))
                            .offset(x: 3, y: -3)
                    }
                }
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                // the key page (TAGS.md §7): a small bookmark before its number
                if key?.page == p {
                    Image(systemName: "bookmark.fill").font(.system(size: 8)).foregroundStyle(Ink.secondary)
                        .padding(.trailing, 3)
                        .help(key?.chosen == true ? "Key page: chosen by you · stands for this paper on the Student page, All Students and Your Move"
                              : "Key page: the busiest page · Set as Key Page (right-click a page) to choose another")
                }
                if labels.shows(p, key: key?.page == p, ring: k > 0 && labels.ringBeside) {
                    Text("\(p + 1)").font(.system(size: 11)).monospacedDigit().foregroundStyle(Ink.secondary)
                }
                if k > 0 && labels.ringBeside {
                    StatusGlyphView(.ring(0), size: 10, text: 11).padding(.leading, 6).padding(.trailing, 3)
                    Text("\(k)").font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(Ink.label2)
                }
            }
            .fixedSize()
            .frame(width: geo.thumbWidth, height: 14)
        }
        .opacity(framing.dimmed.contains(p) ? 0.4 : 1)
        .contextMenu { pageMenu(n, page: p, key: key) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(p + 1) of Round \(n). " + (key?.page == p ? "Key page. " : "")
                            + Self.pageHelp(r, overview.data, page: p).dropFirst().dropLast().joined(separator: ". "))
        .accessibilityAddTraits(framing.framed.contains(p) ? [.isButton, .isSelected] : [.isButton])
        .accessibilityAction { model.overviewClicked(.page(round: n, page: p)) }
        .accessibilityAction(named: "Open in Review") { model.overviewClicked(.page(round: n, page: p), double: true) }
    }

    /// The key page shown in round `n`'s strip (TAGS.md §7): the page chosen in that round, else the engine's key page
    /// when it is in that round (followed from an earlier choice, or the busiest); nil in another round. A page chosen
    /// beyond the round's pages (the round built again, shorter) is its last page, as the engine takes it.
    static func keyPage(_ n: Int, data d: PaperOverview?, chosen: KeyPageChoice?) -> (page: Int, chosen: Bool)? {
        if let c = chosen, c.round == n { return (clamp(c.page, pages: d?.round(n)?.build?.pages), true) }
        if let k = d?.keyPage, k.round == n { return (k.page, k.chosen ?? (chosen != nil)) }
        return nil
    }

    /// A chosen page within a round of `pages` pages (unknown: as chosen).
    static func clamp(_ page: Int, pages: Int?) -> Int {
        guard let pages, pages > 0 else { return max(page, 0) }
        return min(max(page, 0), pages - 1)
    }

    /// A thumbnail's menu (TAGS.md §7): Set as Key Page (Use the Busiest Page on the one chosen), Open in Review there,
    /// Follow This Page.
    @ViewBuilder
    private func pageMenu(_ n: Int, page p: Int, key: (page: Int, chosen: Bool)?) -> some View {
        if let path = model.selectedPath {
            if key?.page == p && key?.chosen == true {
                Button("Use the Busiest Page") { model.setKeyPage(path, nil) }
            } else {
                Button("Set as Key Page") { model.setKeyPage(path, KeyPageChoice(round: n, page: p)) }
            }
            Divider()
        }
        Button("Open in Review at p.\(p + 1)") { model.overviewClicked(.page(round: n, page: p), double: true) }
        Button("Follow This Page") { model.overviewClicked(.page(round: n, page: p)) }
    }

    /// The pages of the round with something to check (0-based), with how many: comments to check, and edits nobody
    /// asked for that wait for you; only while the round is open.
    static func pagesToCheck(_ r: PaperOverview.Round?, _ d: PaperOverview?) -> [Int: Int] {
        guard let r, !r.isClosed, let d else { return [:] }
        var out: [Int: Int] = [:]
        for c in d.comments { if let st = c.step(in: r.n), st.answer == "to_check", let p = st.page { out[p, default: 0] += 1 } }
        for e in r.edits ?? [] where e.toCheck { if let p = e.page { out[p, default: 0] += 1 } }
        return out
    }

    private func strip(_ n: Int, _ r: PaperOverview.Round, geo: StripGeometry, toCheck: [Int: Int]) -> some View {
        let pages = geo.pages
        let framing = Self.framing(overview.selection, r, overview.data, pages: pages)
        let labels = StripLabels(slot: geo.slot, pages: pages, most: toCheck.values.max() ?? 0)
        let followed = Self.followed(overview.selection, overview.data)
        let pageSize = { (p: Int) in thumbs.pageSize(pdf: r.pdf, page: p) }
        let key = Self.keyPage(n, data: overview.data, chosen: model.selectedPath.flatMap(model.keyPage(of:)))
        return ZStack(alignment: .topLeading) {
            ForEach(0..<pages, id: \.self) { p in
                pageCell(n, r, page: p, geo: geo, framing: framing, labels: labels, followed: followed, pageSize: pageSize,
                         key: key, toCheck: toCheck)
                .offset(x: geo.thumbX(p), y: geo.top)
            }
        }
        .frame(width: geo.contentWidth, height: geo.row + 20, alignment: .topLeading)
        .contentShape(Rectangle())
        // a click on a comment's mark follows the comment, elsewhere on a page the page (§5.1); a second on the same
        // thing within the double-click interval opens Review there
        // in the strip's own (scrolled) points: what is under them is the content's; the tag goes where the pointer is
        // in the overview's visible frame, the scroll taken off
        .onTapGesture(count: 1, coordinateSpace: .local) { p in
            let t = geo.target(at: p, marks: r.marks ?? [], pageSize: pageSize)
            let now = ProcessInfo.processInfo.systemUptime
            let double = last.map { $0.target == t && now - $0.time <= NSEvent.doubleClickInterval } ?? false
            last = double ? nil : (t, now)
            hover.dismissTip()
            Self.act(t, round: n, model: model, double: double)
        }
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let p):
                Self.hover(at: p, round: r, geo: geo, model: model, hover: hover, offset: overview.stripScroll.offset)
            case .ended: hover.leave()
            }
        }
    }

    /// A click on the strip's `t`: a comment's mark follows the comment, elsewhere on a page the page (§5.1).
    static func act(_ t: StripTarget?, round n: Int, model: AppModel, double: Bool) {
        switch t {
        case .comment(let id, _)?: model.overviewClicked(.comment(id), double: double)
        case .page(let q)?: model.overviewClicked(.page(round: n, page: q), double: double)
        case nil: break
        }
    }

    /// The pointer at `p` in the strip's content (scrolled by `offset`): what it is over and its help tag, at its place
    /// in the overview's visible frame. `force`: the debug script's, at once.
    static func hover(at p: CGPoint, round r: PaperOverview.Round, geo: StripGeometry, model: AppModel, hover: OverviewHover,
                      offset: CGFloat, force: Bool = false) {
        let d = model.overview.data
        let t = geo.target(at: p, marks: r.marks ?? [], pageSize: { model.thumbnails.pageSize(pdf: r.pdf, page: $0) })
        let at = CGPoint(x: p.x - offset + hover.stripOrigin.x, y: p.y + hover.stripOrigin.y)
        switch t {
        case .comment(let id, _)?:
            let followed = Self.followed(model.overview.selection, d)
            hover.point(at: at, key: "strip:c:" + id, comment: followed.contains(id) ? nil : id, force: force) {
                d.map { MapHelp.lines(.comment(id, round: r.n), $0, student: OverviewText.firstName(model.state?.paper.student ?? "")) } ?? []
            }
        case .page(let q)?:
            hover.point(at: at, key: "strip:p:\(q)", force: force) { Self.pageHelp(r, d, page: q) }
        case nil:
            hover.point(at: at, key: nil, force: force) { [] }
        }
    }

    /// The pages framed (a section's, the page followed, the pages of the comments followed) and those that step back.
    static func framing(_ s: OverviewItem?, _ r: PaperOverview.Round, _ d: PaperOverview?, pages: Int) -> (framed: Set<Int>, dimmed: Set<Int>) {
        let all = Set(0..<pages)
        switch s {
        case .section(let key, _)?:
            guard r.hasSections, let sp = r.spans?.first(where: { $0.section == key }) else { return ([], []) }
            let lo = Int(sp.start.rounded(.down)), hi = max(lo, Int((sp.end - 0.001).rounded(.down)))
            let framed = Set((lo...hi).filter { all.contains($0) })
            return (framed, all.subtracting(framed))
        case .page(let n, let p)?:
            let ids = Set(d?.comments.filter { $0.step(in: n)?.page == p }.map(\.id) ?? [])
            var framed = Set(d?.comments.filter { ids.contains($0.id) }.compactMap { $0.step(in: r.n)?.page } ?? [])
            if n == r.n { framed.insert(p) }
            return (framed, all.subtracting(framed))
        case .comment(let id)?:
            let framed = Set([d?.comment(id)?.step(in: r.n)?.page].compactMap { $0 })
            return (framed, all.subtracting(framed))
        default:
            return ([], [])
        }
    }

    static func followed(_ s: OverviewItem?, _ d: PaperOverview?) -> Set<String> {
        switch s {
        case .comment(let id)?: return [id]
        case .page(let n, let p)?: return Set(d?.comments.filter { $0.step(in: n)?.page == p }.map(\.id) ?? [])
        default: return []
        }
    }

    static func pageHelp(_ r: PaperOverview.Round, _ d: PaperOverview?, page p: Int) -> [String] {
        let steps = d?.comments.compactMap { $0.step(in: r.n) }.filter { $0.page == p && $0.state != "unplaced" } ?? []
        let tc = r.isClosed ? 0 : steps.filter { $0.answer == "to_check" }.count
        let edits = (r.edits ?? []).filter { $0.page == p }
        let unasked = edits.filter(\.unrequested).count
        let et = r.isClosed ? 0 : edits.filter(\.toCheck).count
        return ["Page \(p + 1)" + (r.build?.pages.map { " of \($0)" } ?? "") + " · Round \(r.n)",
                count(steps.count, "comment") + (tc > 0 ? " (○ \(tc) to check)" : "") + " · \(count(edits.count, "edit"))"
                    + (unasked > 0 ? ", \(unasked) unasked" : "") + (et > 0 ? " (○ \(et) to check)" : ""),
                "Click to follow these comments · a mark follows its comment · double-click opens the page"]
    }
}

/// What a point on the strip is over: a comment's mark on a page (as the thumbnail draws it, 2.5 pt of slop round
/// it; the smallest of marks that overlap), else the page; nil past the pages.
enum StripTarget: Equatable {
    case page(Int)
    case comment(String, page: Int)
}

extension StripGeometry {
    /// What a point in the strip's visible frame is over, the strip scrolled by `offset`.
    func target(seen p: CGPoint, offset: CGFloat, marks: [PaperOverview.Mark], pageSize: (Int) -> CGSize?) -> StripTarget? {
        guard p.x >= 0, p.x < width else { return nil }
        return target(at: CGPoint(x: p.x + offset, y: p.y), marks: marks, pageSize: pageSize)
    }

    /// What a point in the strip's content is over.
    func target(at p: CGPoint, marks: [PaperOverview.Mark], pageSize: (Int) -> CGSize?) -> StripTarget? {
        guard let page = page(at: p.x) else { return nil }
        let x0 = thumbX(page)
        guard p.y >= top, p.y <= top + thumbHeight, p.x >= x0 - 2, p.x <= x0 + thumbWidth + 2, let ps = pageSize(page), ps.height > 0 else {
            return .page(page)
        }
        let k = thumbHeight / ps.height, slop = 2.5 / k
        let q = CGPoint(x: (p.x - x0) / k, y: (p.y - top) / k)
        let hits = marks.filter { $0.page == page && $0.kind == "comment" && $0.id != nil
            && $0.rect.insetBy(dx: -slop, dy: -slop).contains(q) }
        if let m = hits.min(by: { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }), let id = m.id {
            return .comment(id, page: page)
        }
        return .page(page)
    }
}

/// The strip's page numbers (UI v4, mac/UX.md §40.4): under each page its number, then 6 pt later the ring and the
/// page's count to check while the slot has room for them, else a ring on the page's corner (the count in its help
/// tag); every number while the slots have room for the widest, else every other one (1, 3, 5 …).
struct StripLabels: Equatable {
    var slot: CGFloat
    var pages: Int
    /// The most any page has to check, for its count's room.
    var most = 9

    /// The ring and its count after a number: 6 pt, the 10 pt ring, 3 pt, the count (11 semibold).
    var ringWidth: CGFloat { 6 + 10 + 3 + MapFont.label.width("\(most)") }
    var ringBeside: Bool { MapFont.small.width("\(pages)") + ringWidth + 4 <= slot }
    var every: Int { MapFont.small.width("\(pages)") + 4 <= slot ? 1 : 2 }
    func shows(_ p: Int) -> Bool { p % every == 0 }

    /// Page `p`'s number beside the key page's bookmark (`key`, 7 pt and its gap; `ring`: the ring and count beside it
    /// too) while they fit the slot, else the bookmark alone, so no number runs into the next one.
    func shows(_ p: Int, key: Bool, ring: Bool) -> Bool {
        guard shows(p) else { return false }
        return !key || MapFont.small.width("\(p + 1)") + 10 + (ring ? ringWidth : 0) + 4 <= slot
    }
}

/// One page: its thumbnail (the white page ground until it is drawn) and where its comments sit (UI v4, mac/UX.md
/// §40.4): the comments' marks in a neutral ink, which keeps their clicks, the followed comment in its colour with a
/// Sage outline; the edits and the to-check rings are the map's and the numbers' under the page (plan §5 R9). White
/// paper in either appearance, as in Review (the advisor's review of 2026-10-31: the Dark Mode dimming read as a veil);
/// the keyline and the shadow set it off the dark panel.
struct PageThumb: View {
    /// The comments' marks while not followed: black at 0.16.
    static let markInk = 0.16
    let image: NSImage?
    let round: PaperOverview.Round
    let data: PaperOverview?
    let page: Int
    let size: CGSize
    let pageSize: CGSize?
    let followed: Set<String>
    let framed: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = MapInk(dark: scheme == .dark)
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.white)
            if let image { Image(nsImage: image).resizable().interpolation(.high) }
            if let ps = pageSize, ps.height > 0 {
                Canvas { ctx, _ in
                    Self.drawMarks(ctx, round: round, data: data, page: page, k: size.height / ps.height,
                                   coloured: followed.contains, outline: ink.color(.accent))
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 1.5))
        .overlay(RoundedRectangle(cornerRadius: 1.5).strokeBorder(Color.black.opacity(scheme == .dark ? 0.3 : 0.16), lineWidth: 0.5))
        .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.10), radius: scheme == .dark ? 3 : 1.5, y: 1)
        .overlay(RoundedRectangle(cornerRadius: 2.5).strokeBorder(framed ? ink.color(.accent) : .clear, lineWidth: 2).padding(-2))
    }

    /// The comments' marks on `page` at `k` pt a point, as each is drawn on the page: a highlight filled, a box
    /// outlined, a line under or through the words, a note a dot. In the neutral ink, or in its colour (at 0.55 when
    /// filled) when `coloured` (followed on the strip, outlined in `outline`; every one on a paper's icon, BRIEF §8.1).
    static func drawMarks(_ ctx: GraphicsContext, round: PaperOverview.Round, data: PaperOverview?, page: Int, k: CGFloat,
                          coloured: (String) -> Bool, outline: Color?) {
        for m in round.marks ?? [] where m.page == page && m.kind == "comment" {
            let r = CGRect(x: m.rect.minX * k, y: m.rect.minY * k, width: max(m.rect.width * k, 2), height: max(m.rect.height * k, 1.5))
            let c = m.id.flatMap { data?.comment($0) }
            let on = m.id.map(coloured) ?? false
            let colour = on ? Color(nsColor: (c?.color.flatMap(MarkColor.init(name:)) ?? .yellow).fill) : Color.black.opacity(markInk)
            let a = on ? 0.55 : 1
            switch c?.kind {
            case "box": ctx.stroke(Path(r), with: .color(colour.opacity(on ? 0.85 : 1)), lineWidth: 1)
            case "underline": ctx.fill(Path(CGRect(x: r.minX, y: r.maxY - 0.8, width: r.width, height: 1)), with: .color(colour))
            case "strikeout": ctx.fill(Path(CGRect(x: r.minX, y: r.midY - 0.5, width: r.width, height: 1)), with: .color(colour))
            case "note": ctx.fill(Path(ellipseIn: CGRect(x: r.minX - 1.5, y: r.minY - 1.5, width: 3.5, height: 3.5)), with: .color(colour))
            default: ctx.fill(Path(roundedRect: r.insetBy(dx: 0, dy: -0.5), cornerRadius: 0.6), with: .color(colour.opacity(a)))
            }
            if on, let outline {
                ctx.stroke(Path(roundedRect: r.insetBy(dx: -1.5, dy: -1.8), cornerRadius: 1.5), with: .color(outline), lineWidth: 1.5)
            }
        }
    }
}

/// The section ruler under the strip (OVERVIEW-v2 §3.3): each section's name where it starts in the strip's round, as
/// long as fits (its title, its name, the start of it, its number); a click follows it.
struct SectionRuler: View {
    let model: AppModel
    @ObservedObject var overview: OverviewModel
    let hover: OverviewHover
    let round: PaperOverview.Round
    /// The strip's geometry: the ruler names the sections under their pages, and scrolls with them.
    let geo: StripGeometry
    /// The map's names (`MapScene.names`): the ruler names a section with the same stem as its cells.
    var names: [String: MapScene.SectionName] = [:]
    @Environment(\.colorScheme) private var scheme

    /// What fits in `room`, by the map's rule for names (`MapRules.label`, the advisor's review of 2026-10-20: a short
    /// form or the first letters rather than nothing): the title; a numbered one its number and as much of its name as
    /// fits ("1 Intro.", "3 Bench.", "6 RW"), else its number alone, never hidden while it fits (an appendix's sections
    /// their letters, "A"); one without a number its short name ("Abstract") as far as it fits ("Abs."), but not a lone
    /// letter, which would read as an appendix's. With the map's name for it (`map`, UI audit 2026-10-21: the ruler
    /// said "1 Intro." over cells saying "Int."), the map's name or a longer form of its stem, and the ruler's own rule
    /// only when that does not fit. The ruler stays at the strip's page scale, under the pages it names; the lens joins
    /// it to the map's own scale. The help tag says the whole.
    static func label(_ title: String, room: CGFloat, map: MapScene.SectionName? = nil) -> String? {
        let f = MapFont.small
        if f.width(title) <= room { return title }
        let num = (Outline.numbers([title]).first ?? nil) ?? MapFold.letter(title)
        /// The map's forms of it without its letter (an appendix section's lead with it, as the ruler's number does).
        func mapForm(_ r: CGFloat) -> String? {
            guard let map else { return nil }
            let lead = num.map { $0 + " " } ?? ""
            func strip(_ t: String?) -> String? { t.map { lead.isEmpty || !$0.hasPrefix(lead) ? $0 : String($0.dropFirst(lead.count)) } }
            let m = MapScene.SectionName(forms: map.forms.compactMap(strip), base: strip(map.base), fixed: strip(map.fixed),
                                         avoid: map.avoid)
            return m.fit(f, r).flatMap { MapRules.isLetter($0) || $0 == num ? nil : $0 }
        }
        if let num {
            let name = String(title.dropFirst(num.count)).trimmingCharacters(in: .whitespaces)
            let lead = num + " "
            if !name.isEmpty, let t = mapForm(room - f.width(lead)) { return lead + t }
            // a lone letter after the number ("3 B", "3 B.") reads as an appendix's: the number alone then
            if !name.isEmpty, let t = MapRules.labels(name).first(where: { !MapRules.isLetter($0) && f.width($0) <= room - f.width(lead) }) {
                return lead + t
            }
            return f.width(num) <= room ? num : nil
        }
        if let t = mapForm(room) { return t }
        // a lone letter without a number reads as an appendix's ("A" for the abstract): none then
        return MapRules.labels(MapScene.shortName(title)).first { !MapRules.isLetter($0) && f.width($0) <= room }
    }

    var body: some View {
        let ink = MapInk(dark: scheme == .dark)
        let slot = geo.slot
        ZStack(alignment: .topLeading) {
            if round.hasSections {
                ForEach(Array((round.spans ?? []).enumerated()), id: \.offset) { _, sp in
                    let xa = CGFloat(sp.start) * slot, w = CGFloat(sp.end - sp.start) * slot
                    let on = overview.selection.map { if case .section(let k, _) = $0 { return k == sp.section } else { return false } } ?? false
                    ZStack(alignment: .topLeading) {
                        if on { RoundedRectangle(cornerRadius: 5).fill(ink.color(.accentTint)).frame(width: max(w - 2, 1), height: 18).offset(x: 1, y: 1) }
                        Rectangle().fill(ink.color(.rule)).frame(width: 1, height: 15).offset(y: 2)
                        if let t = Self.label(sp.title, room: w - 9, map: names[MapScene.nameID(sp.section, sp.title)]) {
                            Text(t).font(.system(size: on ? 12.5 : 11, weight: on ? .semibold : .medium))
                                .foregroundStyle(on ? Ink.label : Ink.secondary)
                                .lineLimit(1).fixedSize()
                                .offset(x: 5, y: on ? 2 : 3)
                        }
                    }
                    .frame(width: max(w, 1), height: 20, alignment: .topLeading)
                    .contentShape(Rectangle())
                    .clicks({ model.overviewClicked(.section(sp.section, round: round.n)) },
                            double: { model.overviewClicked(.section(sp.section, round: round.n), double: true) })
                    .overviewTip(hover, key: "ruler:\(sp.section)@\(round.n)") {
                        overview.data.map { MapHelp.lines(.cell(sp.section, round: round.n), $0, student: OverviewText.firstName(model.state?.paper.student ?? "")) } ?? []
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(sp.title + ", Round \(round.n)")
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : [.isButton])
                    .accessibilityAction { model.overviewClicked(.section(sp.section, round: round.n)) }
                    .accessibilityAction(named: "Open in Review") { model.overviewClicked(.section(sp.section, round: round.n), double: true) }
                    .offset(x: xa)
                }
            } else {
                Text(round.prose == "unavailable" ? "Sections unavailable for this round" : "Finding sections…")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Ink.secondary).offset(x: 4, y: 3)
            }
            Rectangle().fill(ink.color(.rule)).frame(width: 1, height: 15).offset(x: geo.contentWidth - 1, y: 2)
        }
        .frame(width: geo.contentWidth, height: 20, alignment: .topLeading)
    }
}

/// The strip's sideways scroll (mac/UX.md §40.9): one scroll view for the strip and its ruler, whose offset the lens
/// draws from. It keeps the page at the strip's left edge (`anchor`, page units) while the strip shows another round
/// (previewed or picked) and when the overview comes back, so the same page stays in view where that round has it
/// (else the start); a page, section or comment followed scrolls its page into view (at once with Reduce Motion).
@MainActor
final class StripScroll: ObservableObject {
    /// The offset in view, for the lens.
    @Published private(set) var offset: CGFloat = 0
    private(set) weak var scrollView: NSScrollView?
    /// The geometry and round the strip shows (`shown`), and the paper's overview, for what a follow scrolls to.
    private(set) var geo: StripGeometry?
    private(set) var round: Int?
    private var data: PaperOverview?
    /// The page at the strip's left edge, in page units: where the viewer or a follow left it.
    private(set) var anchor: Double = 0
    /// What was followed, to scroll into view once the strip shows `round`.
    private var pending: (item: OverviewItem, round: Int)?
    /// A round or width shown and not yet scrolled to its place: the clip view's own moves (its document narrower) do
    /// not move the anchor.
    private var switching = false
    private var setting = false
    private var observers: [NSObjectProtocol] = []

    /// Another paper: its strip from the start.
    func reset() {
        anchor = 0
        pending = nil
        round = nil
        geo = nil
        if scrollView != nil, offset != 0 { set(0, animated: false) }
    }

    /// The scroll view of the strip (`StripScrollProbe`): overlay scrollers, its offset followed.
    func attach(_ sv: NSScrollView) {
        if sv.scrollerStyle != .overlay { sv.scrollerStyle = .overlay }
        sv.hasVerticalScroller = false
        sv.verticalScrollElasticity = .none
        guard sv !== scrollView else { return }
        for o in observers { NotificationCenter.default.removeObserver(o) }
        scrollView = sv
        sv.contentView.postsBoundsChangedNotifications = true
        observers = [
            NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: sv.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scrolled() }
            },
            // the system's setting changed (a mouse plugged in): overlay scrollers still, so no row grows under the strip
            NotificationCenter.default.addObserver(forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main) { [weak sv] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { sv?.scrollerStyle = .overlay } }
            },
        ]
        apply()
    }

    /// The strip shows round `n` at `g` (its appearance, another round, another width): scrolled to its place once laid out.
    func shown(round n: Int, geo g: StripGeometry) {
        guard n != round || g != geo else { return }
        round = n
        geo = g
        switching = true
        DispatchQueue.main.async { [weak self] in self?.apply() }
    }

    /// `item` followed, the strip showing round `n` for it: its page scrolled into view.
    func follow(_ item: OverviewItem?, round n: Int?, data d: PaperOverview?) {
        guard let item, let n else { return }
        if case .round = item { return }
        if case .tag = item { return }
        data = d
        pending = (item, n)
        DispatchQueue.main.async { [weak self] in self?.apply() }
    }

    /// The pages (page units) of `item` in round `n`'s strip: a page, a section's span, a comment's page there.
    static func pages(_ item: OverviewItem, data d: PaperOverview?, round n: Int) -> (Double, Double)? {
        switch item {
        case .page(let r, let p): return r == n ? (Double(p), Double(p + 1)) : nil
        case .section(let key, let r):
            guard r == n, let sp = d?.round(n)?.spans?.first(where: { $0.section == key }) else { return nil }
            return (sp.start, max(sp.end, sp.start + 0.01))
        case .comment(let id):
            return d?.comment(id)?.step(in: n)?.page.map { (Double($0), Double($0 + 1)) }
        case .round, .tag: return nil
        }
    }

    /// The offset for the round shown: its anchor's page at the left edge where the round has it (else the start), as
    /// far as it scrolls; then what was followed in view.
    private func apply(try t: Int = 0) {
        guard let sv = scrollView, sv.window != nil, let g = geo, let n = round else { return }
        // the document laid out at the round's width first, else the clip view cuts the offset short
        if let doc = sv.documentView, abs(doc.frame.width - g.contentWidth) > 0.5 {
            if t < 10 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in self?.apply(try: t + 1) } }
            return
        }
        var x = anchor < Double(g.pages) ? min(g.x(anchor), g.maxOffset) : 0
        var animated = false
        if let p = pending, p.round == n {
            pending = nil
            if let (lo, hi) = Self.pages(p.item, data: data, round: n), let to = g.reveal(lo, hi, from: switching ? x : current(sv)) {
                animated = !switching && !Motion.reduced
                x = to
                anchor = Double(to / g.slot)
            } else if !switching {
                return
            }
        }
        set(x, animated: animated)
        switching = false
    }

    private func current(_ sv: NSScrollView) -> CGFloat { sv.contentView.bounds.minX }

    private func set(_ x: CGFloat, animated: Bool) {
        guard let sv = scrollView else { return }
        let clip = sv.contentView, origin = NSPoint(x: x, y: clip.bounds.minY)
        if abs(clip.bounds.minX - x) < 0.25 { return scrolled() }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.allowsImplicitAnimation = true
                clip.animator().setBoundsOrigin(origin)
            } completionHandler: { [weak sv] in
                MainActor.assumeIsolated { if let sv { sv.reflectScrolledClipView(sv.contentView) } }
            }
        } else {
            setting = true
            clip.scroll(to: origin)
            sv.reflectScrolledClipView(clip)
            setting = false
            scrolled()
        }
    }

    /// The clip view moved: the offset for the lens, and, moved by the viewer (or a follow), the anchor.
    private func scrolled() {
        guard let sv = scrollView else { return }
        let x = current(sv)
        if abs(offset - x) > 0.01 { offset = x }
        guard !setting, !switching, let g = geo, let doc = sv.documentView, abs(doc.frame.width - g.contentWidth) <= 0.5 else { return }
        anchor = Double(x / g.slot)
    }

    /// The debug items' scroll: to `x` (content points), at once.
    func scroll(to x: CGFloat) {
        guard let g = geo else { return }
        let to = min(max(0, x), g.maxOffset)
        anchor = Double(to / g.slot)
        set(to, animated: false)
    }
}

/// Finds the strip's scroll view from inside its content (`StripScroll.attach`).
struct StripScrollProbe: NSViewRepresentable {
    let scroll: StripScroll

    final class Probe: NSView {
        weak var scroll: StripScroll?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
        }

        func attach() {
            MainActor.assumeIsolated {
                guard window != nil, let sv = enclosingScrollView else { return }
                scroll?.attach(sv)
            }
        }
    }

    func makeNSView(context: Context) -> Probe {
        let p = Probe()
        p.scroll = scroll
        return p
    }

    func updateNSView(_ p: Probe, context: Context) {
        p.scroll = scroll
        DispatchQueue.main.async { p.attach() }
    }
}
