import AppKit
import SwiftUI

/// The page strip of one round (OVERVIEW-v2 §3.3): its title, its pages as thumbnails at their slots with the marks of
/// the round (comments in their colours, edits as bars, an amber ring where something waits for you) and their numbers
/// (with ○ where a page has something to check), and under it the section ruler. A click on a page follows it, a
/// double click opens Review there; a click on a section name follows the section.
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
        let n = model.stripRound
        let r = n.flatMap { d?.round($0) }
        let pages = r?.build?.pages ?? (n == model.round?.n ? model.round?.build.pages : nil) ?? 0
        let toCheck = Self.pagesToCheck(r, d)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(n.map { "Pages of Round \($0)" } ?? "Pages").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.label)
                    .fixedSize()
                if pages > 0 {
                    HStack(spacing: 4) {
                        Text(count(pages, "page"))
                        if !toCheck.isEmpty {
                            Text("·")
                            Circle().strokeBorder(Color(nsColor: Palette.toCheck), lineWidth: 2).frame(width: 8, height: 8)
                            Text("something to check")
                        }
                    }
                    .font(.system(size: 12)).foregroundStyle(Ink.secondary).fixedSize()
                }
                Spacer(minLength: 8)
                Text(overview.selection == nil ? "Click a section, round, page or comment to follow it · double-click opens Review"
                     : "Esc shows the whole paper again")
                    .font(.system(size: 12)).foregroundStyle(Ink.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            .frame(minHeight: 22)
            .padding(.bottom, 7)
            if let n, let r, pages > 0, !r.failed {
                strip(n, r, pages: pages, toCheck: toCheck)
                SectionRuler(model: model, overview: overview, hover: hover, round: r, pages: pages, width: width, names: names)
                    .padding(.top, 1)
            } else {
                Text(Self.noPages(r, loading: overview.status == .loading))
                    .font(.system(size: 12)).foregroundStyle(Ink.secondary)
                    .frame(height: StripGeometry.height + 18 + 21, alignment: .center)
            }
        }
        .frame(width: width, alignment: .leading)
    }


    /// Why the strip shows no pages: the overview is being read, the round's build failed, or none to show (the
    /// overview could not be read, or the round is gone: the code audit, it said the build failed then).
    static func noPages(_ r: PaperOverview.Round?, loading: Bool) -> String {
        if loading { return "Reading the rounds…" }
        if let r, r.failed { return "No PDF for Round \(r.n): the build failed." }
        return "No pages yet."
    }

    /// One page of the strip: its thumbnail with the marks, its number (the ○, the key page's bookmark), its menu. The
    /// cell is as wide as the thumbnail, so it stays at its slot (`StripGeometry.thumbX`, where clicks find it): the
    /// row under it is centred on it and may run past it (the code audit: the key page's bookmark widened the cell).
    @ViewBuilder
    private func pageCell(_ n: Int, _ r: PaperOverview.Round, page p: Int, geo: StripGeometry,
                          framing: (framed: Set<Int>, dimmed: Set<Int>), labels: StripLabels, followed: Set<String>,
                          pageSize: @escaping (Int) -> CGSize?, key: (page: Int, chosen: Bool)?, toCheck: Set<Int>) -> some View {
        let image = thumbs.image(paper: model.selectedPath ?? "", pdf: r.pdf, page: p, height: geo.thumbHeight)
        VStack(spacing: 5) {
            PageThumb(image: image, round: r, data: overview.data, page: p, size: CGSize(width: geo.thumbWidth, height: geo.thumbHeight),
                      pageSize: image == nil ? nil : pageSize(p), followed: followed, framed: framing.framed.contains(p))
                .overlay(alignment: .topTrailing) {
                    // a crowded strip: the ○ on the page's corner, so the numbers keep their room
                    if toCheck.contains(p) && !labels.ringBeside {
                        Circle().fill(Color(nsColor: Palette.panel)).frame(width: 9, height: 9)
                            .overlay(Circle().strokeBorder(Color(nsColor: Palette.toCheck), lineWidth: 1.8))
                            .offset(x: 3, y: -3)
                    }
                }
            HStack(spacing: 3) {
                if toCheck.contains(p) && labels.ringBeside {
                    Circle().strokeBorder(Color(nsColor: Palette.toCheck), lineWidth: 1.8).frame(width: 7, height: 7)
                }
                // the key page (TAGS.md §7): a small bookmark before its number
                if key?.page == p {
                    Image(systemName: "bookmark.fill").font(.system(size: 8)).foregroundStyle(Ink.secondary)
                        .help(key?.chosen == true ? "Key page: chosen by you · stands for this paper on the Student page, All Students and Your Move"
                              : "Key page: the busiest page · Set as Key Page (right-click a page) to choose another")
                }
                if labels.shows(p, key: key?.page == p, ring: toCheck.contains(p) && labels.ringBeside) {
                    Text("\(p + 1)").font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(Ink.secondary)
                }
            }
            .fixedSize()
            .frame(width: geo.thumbWidth, height: 13)
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

    /// The pages of the round with something to check (0-based): a comment to check, or an edit nobody asked for that
    /// waits for you; only while the round is open.
    static func pagesToCheck(_ r: PaperOverview.Round?, _ d: PaperOverview?) -> Set<Int> {
        guard let r, !r.isClosed, let d else { return [] }
        var out: Set<Int> = []
        for c in d.comments { if let st = c.step(in: r.n), st.answer == "to_check", let p = st.page { out.insert(p) } }
        for e in r.edits ?? [] where e.toCheck { if let p = e.page { out.insert(p) } }
        return out
    }

    private func strip(_ n: Int, _ r: PaperOverview.Round, pages: Int, toCheck: Set<Int>) -> some View {
        let geo = StripGeometry(width: width, pages: pages, aspect: thumbs.aspect(pdf: r.pdf))
        let framing = Self.framing(overview.selection, r, overview.data, pages: pages)
        let labels = StripLabels(slot: geo.slot, pages: pages)
        let followed = Self.followed(overview.selection, overview.data)
        let pageSize = { (p: Int) in thumbs.pageSize(pdf: r.pdf, page: p) }
        let key = Self.keyPage(n, data: overview.data, chosen: model.selectedPath.flatMap(model.keyPage(of:)))
        return ZStack(alignment: .topLeading) {
            ForEach(0..<pages, id: \.self) { p in
                pageCell(n, r, page: p, geo: geo, framing: framing, labels: labels, followed: followed, pageSize: pageSize,
                         key: key, toCheck: toCheck)
                .offset(x: geo.thumbX(p))
            }
        }
        .frame(width: width, height: geo.thumbHeight + 18, alignment: .topLeading)
        .contentShape(Rectangle())
        // a click on a comment's mark follows the comment, elsewhere on a page the page (§5.1); a second on the same
        // thing within the double-click interval opens Review there
        .onTapGesture(count: 1, coordinateSpace: .local) { p in
            let t = geo.target(at: p, marks: r.marks ?? [], pageSize: pageSize)
            let now = ProcessInfo.processInfo.systemUptime
            let double = last.map { $0.target == t && now - $0.time <= NSEvent.doubleClickInterval } ?? false
            last = double ? nil : (t, now)
            hover.dismissTip()
            switch t {
            case .comment(let id, _)?: model.overviewClicked(.comment(id), double: double)
            case .page(let q)?: model.overviewClicked(.page(round: n, page: q), double: double)
            case nil: break
            }
        }
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let p):
                let t = geo.target(at: p, marks: r.marks ?? [], pageSize: pageSize)
                let at = CGPoint(x: p.x + hover.stripOrigin.x, y: p.y + hover.stripOrigin.y)
                switch t {
                case .comment(let id, _)?:
                    hover.point(at: at, key: "strip:c:" + id, comment: followed.contains(id) ? nil : id) {
                        overview.data.map { MapHelp.lines(.comment(id, round: n), $0, student: OverviewText.firstName(model.state?.paper.student ?? "")) } ?? []
                    }
                case .page(let q)?:
                    hover.point(at: at, key: "strip:p:\(q)") { Self.pageHelp(r, overview.data, page: q) }
                case nil:
                    hover.point(at: at, key: nil) { [] }
                }
            case .ended: hover.leave()
            }
        }
        .background(GeometryReader { g in
            let o = g.frame(in: .named(OverviewLayout.viewport)).origin
            Color.clear
                .onAppear { hover.stripOrigin = o }
                .onChange(of: o) { _, v in hover.stripOrigin = v }
        })
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
        return ["Page \(p + 1) · Round \(r.n)",
                count(steps.count, "comment") + (tc > 0 ? " (○ \(tc) to check)" : "") + " · \(count(edits.count, "edit"))"
                    + (unasked > 0 ? ", \(unasked) nobody asked for" : ""),
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
    func target(at p: CGPoint, marks: [PaperOverview.Mark], pageSize: (Int) -> CGSize?) -> StripTarget? {
        guard let page = page(at: p.x) else { return nil }
        let x0 = thumbX(page)
        guard p.y >= 0, p.y <= thumbHeight, p.x >= x0 - 2, p.x <= x0 + thumbWidth + 2, let ps = pageSize(page), ps.height > 0 else {
            return .page(page)
        }
        let k = thumbHeight / ps.height, slop = 2.5 / k
        let q = CGPoint(x: (p.x - x0) / k, y: p.y / k)
        let hits = marks.filter { $0.page == page && $0.kind == "comment" && $0.id != nil
            && $0.rect.insetBy(dx: -slop, dy: -slop).contains(q) }
        if let m = hits.min(by: { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }), let id = m.id {
            return .comment(id, page: page)
        }
        return .page(page)
    }
}

/// The strip's page numbers: the ○ beside a number while the slot has room for both, else on the page's corner; every
/// number while the slots have room for the widest, else every other one (1, 3, 5 …).
struct StripLabels: Equatable {
    var slot: CGFloat
    var pages: Int

    var ringBeside: Bool { MapFont.small.width("\(pages)") + 10 + 4 <= slot }
    var every: Int { MapFont.small.width("\(pages)") + 4 <= slot ? 1 : 2 }
    func shows(_ p: Int) -> Bool { p % every == 0 }

    /// Page `p`'s number beside the key page's bookmark (`key`, 7 pt and its gap; `ring`: the ○ beside it too) while
    /// they fit the slot, else the bookmark alone, so no number runs into the next one.
    func shows(_ p: Int, key: Bool, ring: Bool) -> Bool {
        guard shows(p) else { return false }
        return !key || MapFont.small.width("\(p + 1)") + 10 + (ring ? 10 : 0) + 4 <= slot
    }
}

/// One page: its thumbnail (white until it is drawn) and the round's marks on it.
struct PageThumb: View {
    /// In Dark Mode a page thumbnail is about 88% white, not pure white: a row of thirty white pages on the dark panel
    /// was the most glaring thing on the screen (the UI audit; before, 96%). The full-size page in Review stays white,
    /// as the marks' colours are tuned for it.
    static let darkDim = 0.12
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
            if scheme == .dark { Color.black.opacity(Self.darkDim) }  // paper, but not glaring on the dark page
            if let ps = pageSize, ps.height > 0 {
                Canvas { ctx, _ in
                    let k = size.height / ps.height
                    var seen: Set<String> = []  // one bar or ring per comment or change, at its first rect
                    for m in round.marks ?? [] where m.page == page {
                        let firstRect = m.id.map { seen.insert(m.kind + $0).inserted } ?? true
                        let r = CGRect(x: m.rect.minX * k, y: m.rect.minY * k, width: max(m.rect.width * k, 2), height: max(m.rect.height * k, 1.5))
                        if m.kind == "comment" {
                            let c = m.id.flatMap { data?.comment($0) }
                            let st = c?.step(in: round.n)
                            let colour = Color(nsColor: (c?.color.flatMap(MarkColor.init(name:)) ?? .yellow).fill)
                            let closed = st?.answer == "resolved" || st?.answer == "kept"
                            let a = closed ? 0.3 : 0.55
                            // as the mark is drawn on the page: a highlight filled, a box outlined, a line under or through
                            // the words, a note a dot
                            switch c?.kind {
                            case "box": ctx.stroke(Path(r), with: .color(colour.opacity(a + 0.3)), lineWidth: 1)
                            case "underline": ctx.fill(Path(CGRect(x: r.minX, y: r.maxY - 0.8, width: r.width, height: 1)), with: .color(colour))
                            case "strikeout": ctx.fill(Path(CGRect(x: r.minX, y: r.midY - 0.5, width: r.width, height: 1)), with: .color(colour))
                            case "note": ctx.fill(Path(ellipseIn: CGRect(x: r.minX - 1.5, y: r.minY - 1.5, width: 3.5, height: 3.5)), with: .color(colour))
                            default: ctx.fill(Path(roundedRect: r.insetBy(dx: 0, dy: -0.5), cornerRadius: 0.6), with: .color(colour.opacity(a)))
                            }
                            if let id = m.id, followed.contains(id) {
                                ctx.stroke(Path(roundedRect: r.insetBy(dx: -1.5, dy: -1.8), cornerRadius: 1.5), with: .color(ink.color(.accent)), lineWidth: 1.5)
                            }
                            if firstRect && !round.isClosed && st?.answer == "to_check" {
                                ctx.stroke(Path(ellipseIn: CGRect(x: 1, y: r.midY - 2.2, width: 4.4, height: 4.4)), with: .color(ink.color(.attention)),
                                           lineWidth: 1)
                            }
                        } else if firstRect {
                            let e = m.id.flatMap { id in round.edits?.first { $0.id == id } }
                            let unasked = e?.unrequested ?? false
                            ctx.fill(Path(CGRect(x: r.minX, y: r.maxY - 0.6, width: r.width, height: unasked ? 1.3 : 1)),
                                     with: .color(ink.color(unasked ? .other : .words)))
                            if e?.toCheck == true {
                                ctx.stroke(Path(ellipseIn: CGRect(x: size.width - 5.4, y: r.maxY - 2.6, width: 4.4, height: 4.4)),
                                           with: .color(ink.color(.attention)), lineWidth: 1)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 1.5))
        .overlay(RoundedRectangle(cornerRadius: 1.5).strokeBorder(Color.black.opacity(scheme == .dark ? 0.3 : 0.16), lineWidth: 0.5))
        .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.10), radius: scheme == .dark ? 3 : 1.5, y: 1)
        .overlay(RoundedRectangle(cornerRadius: 2.5).strokeBorder(framed ? ink.color(.accent) : .clear, lineWidth: 2).padding(-2))
    }
}

/// The section ruler under the strip (OVERVIEW-v2 §3.3): each section's name where it starts in the strip's round, as
/// long as fits (its title, its name, the start of it, its number); a click follows it.
struct SectionRuler: View {
    let model: AppModel
    @ObservedObject var overview: OverviewModel
    let hover: OverviewHover
    let round: PaperOverview.Round
    let pages: Int
    let width: CGFloat
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
        let slot = width / CGFloat(max(pages, 1))
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
            Rectangle().fill(ink.color(.rule)).frame(width: 1, height: 15).offset(x: width - 1, y: 2)
        }
        .frame(width: width, height: 20, alignment: .topLeading)
    }
}
