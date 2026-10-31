import AppKit
import SwiftUI

// Tags as a way to organise the comments (UX.md §27; the advisor, 2026-10-20: "can tags also be a way in to the
// comments?"). In Review: one calm line over the comment list, its menu at the right ("By status ⌄"; the tag chips
// were taken out on 2026-10-21, the advisor: their row broke the layout when one was clicked, and the menu already had
// the tags), which arranges the list by status (To check, For the student, Closed this round: the default), by tag or
// by section, and shows all the comments or only one tag's (Not tagged: those with none). The filter and the
// arrangement are the list's: J and K go through what is listed, an answer moves on to the next card listed to check,
// and the selected card stays where it was shown until the selection leaves it, whatever its tags.

/// How the comment list is arranged: by whose move it is (the default), by the advisor's tags, by the paper's sections.
enum ListGrouping: String, CaseIterable {
    case status, tag, section

    /// The menu's items and its button: "Status" … ("By status ⌄").
    var title: String {
        switch self {
        case .status: return "Status"
        case .tag: return "Tag"
        case .section: return "Section"
        }
    }

    static let key = "commentGrouping"

    /// `--group-by status|tag|section` and `--tag-filter <tag>|untagged`: a run's arrangement and filter (perf runs,
    /// screenshots), never saved.
    static var argument: ListGrouping? { Self.launch("--group-by").flatMap(ListGrouping.init(rawValue:)) }
    static var filterArgument: String? { Self.launch("--tag-filter").map { $0 == "untagged" ? TagCatalog.untagged : $0 } }

    private static func launch(_ flag: String) -> String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: flag), i + 1 < a.count else { return nil }
        return a[i + 1]
    }
}

/// A group of the list: by status, a tag (`TagCatalog.untagged`: Not tagged), or a section (its top-level heading's
/// block, −1 for the title and abstract; nil: no section).
enum ListKey: Hashable {
    case status(CardGroups.Group)
    case tag(String)
    case section(Int?)
}

/// The shown round's top-level sections for the list (from its paragraphs, as the sidebar's Contents): each comment's
/// section, the sections' numbers and names, and each comment's place in the paper (the order by tag and by section).
struct ListSections: Equatable {
    struct Title: Equatable {
        var number: String?
        var name: String
    }

    var of: [String: Int] = [:]
    var titles: [Int: Title] = [:]
    var rank: [String: Int] = [:]
    /// The round's paragraphs are in; until then no comment has a section.
    var found = false

    /// The cards in the paper's order (page, column, height on the page), the others after them as they came.
    func inPaperOrder(_ cards: [CardModel]) -> [CardModel] {
        guard !rank.isEmpty else { return cards }
        return cards.enumerated().sorted { a, b in
            (rank[a.element.id] ?? Int.max, a.offset) < (rank[b.element.id] ?? Int.max, b.offset)
        }.map(\.element)
    }

    /// From the shown round: the headings of the top level (the paper's highest), each comment by the paragraph its
    /// anchor is in; a paragraph before the first heading is the title and abstract's. `columns`: each page's column
    /// gap, so a right column comes after the left one.
    static func make(_ reading: ReadingInfo?, comments: [Comment], columns: [[Double]?] = []) -> ListSections {
        var s = ListSections()
        let placed = comments.enumerated().sorted { a, b in
            func key(_ c: Comment, _ i: Int) -> (Int, Int, Double, Double, Int) {
                guard let p = c.page, let r = c.rects.first, r.count == 4 else { return (Int.max, 0, 0, 0, i) }
                let gap = p < columns.count ? columns[p]?.first : nil
                return (p, gap.map { r[0] >= $0 - 3 ? 1 : 0 } ?? 0, r[1], r[0], i)
            }
            return key(a.element, a.offset) < key(b.element, b.offset)
        }
        for (i, c) in placed.enumerated() { s.rank[c.element.id] = i }
        guard let r = reading else { return s }
        s.found = true
        let headings = r.headings.sorted { $0.block < $1.block }
        let numbers = Outline.numbers(headings.map(\.title))
        let top = headings.map(\.level).min() ?? 1
        let tops = zip(headings, numbers).filter { $0.0.level == top }
        for (h, n) in tops {
            let name = n.map { String(h.title.dropFirst($0.count)).trimmingCharacters(in: .whitespaces) } ?? h.title
            s.titles[h.block] = Title(number: n, name: name.isEmpty ? h.title : name)
        }
        s.titles[-1] = Title(number: nil, name: "Title and abstract")
        for c in comments {
            guard let p = c.paragraph else { continue }
            s.of[c.id] = tops.last { $0.0.block <= p }?.0.block ?? -1
        }
        return s
    }
}

/// The filter and the groups by tag or by section (pure, so unit-tested).
enum ListFilter {
    /// A card the filter keeps: it has the tag, or (Not tagged) none.
    static func matches(_ c: CardModel, _ filter: String) -> Bool {
        filter == TagCatalog.untagged ? c.tags.isEmpty : c.tags.contains { $0.id == filter }
    }

    /// The tag a card is listed under by tag: the filter's when it has it, else its first in the advisor's order,
    /// else Not tagged. Each card once (a list with a selection and J/K has no duplicates); the filter finds a card
    /// under any of its tags.
    static func tagKey(_ c: CardModel, filter: String?) -> String {
        if let f = filter, f != TagCatalog.untagged, c.tags.contains(where: { $0.id == f }) { return f }
        return c.tags.first?.id ?? TagCatalog.untagged
    }

    /// By tag: a group per tag in the catalogue's order (another Mac's tags after them), Not tagged last.
    static func byTag(_ cards: [CardModel], held: String?, place: ListKey?, filter: String?,
                      catalog: TagCatalog) -> [CardGroups.Shown] {
        var buckets: [String: [CardModel]] = [:]
        for c in cards {
            var k = tagKey(c, filter: filter)
            if c.id == held, case .tag(let t)? = place { k = t }
            buckets[k, default: []].append(c)
        }
        let ids = catalog.sorted(buckets.keys.filter { $0 != TagCatalog.untagged }.sorted())
        var out = ids.map { id in
            CardGroups.Shown(key: .tag(id), title: catalog.name(id), glyph: .tag(catalog.sign(id), catalog.name(id)),
                             cards: buckets[id] ?? [])
        }
        if let none = buckets[TagCatalog.untagged] {
            out.append(CardGroups.Shown(key: .tag(TagCatalog.untagged), title: "Not tagged",
                                        glyph: .tag(TagCatalog.untaggedSign, ""), cards: none))
        }
        return out
    }

    /// By section: a group per top-level section in the paper's order, its number where the status groups have their
    /// sign; the comments not placed in this round (or all of them while the paragraphs are not found) last.
    static func bySection(_ cards: [CardModel], held: String?, place: ListKey?,
                          sections s: ListSections) -> [CardGroups.Shown] {
        var buckets: [Int?: [CardModel]] = [:]
        for c in cards {
            var k: Int? = s.of[c.id]
            if c.id == held, case .section(let b)? = place { k = b }
            buckets[k, default: []].append(c)
        }
        var out = buckets.keys.compactMap { $0 }.sorted().map { b in
            let t = s.titles[b] ?? ListSections.Title(number: nil, name: "Section")
            return CardGroups.Shown(key: .section(b), title: t.name, glyph: .number(t.number ?? ""), cards: buckets[b] ?? [])
        }
        if let none = buckets[Int?.none] {
            out.append(CardGroups.Shown(key: .section(nil), title: "No section",
                                        sub: s.found ? "not placed in this round" : "the sections are not found yet",
                                        glyph: .number(""), cards: none))
        }
        return out
    }

    /// The menu's Show section: each tag the round's comments have, in the advisor's order, with how many have it (each
    /// comment once in each of its tags'), then Not tagged; none while no comment of the round has a tag. The tag
    /// shown alone stays listed even when no comment has it any more, so the menu still says what is shown.
    static func options(_ cards: [CardModel], catalog: TagCatalog, filter: String?) -> [ListBar.Option] {
        var counts: [String: Int] = [:], untagged = 0
        for c in cards {
            if c.tags.isEmpty { untagged += 1 }
            for t in c.tags { counts[t.id, default: 0] += 1 }
        }
        guard !counts.isEmpty || filter != nil else { return [] }
        var ids = Array(counts.keys).sorted()
        if let f = filter, f != TagCatalog.untagged, counts[f] == nil { ids.append(f) }
        var out = catalog.sorted(ids).map { id in
            ListBar.Option(id: id, name: catalog.name(id), sign: catalog.sign(id), count: counts[id] ?? 0,
                           help: catalog.tag(id).map(TagText.help) ?? "A tag from another Mac’s list")
        }
        if untagged > 0 || filter == TagCatalog.untagged {
            out.append(ListBar.Option(id: TagCatalog.untagged, name: "Not tagged", sign: TagCatalog.untaggedSign,
                                      count: untagged, help: "The comments without a tag yet"))
        }
        return out
    }

    /// The line's words while one tag is shown alone, longest first: "3 of 17 comments", "3 of 17".
    static func captions(kept: Int, total: Int) -> [String] {
        ["\(kept) of \(count(total, "comment"))", "\(kept) of \(total)"]
    }
}

/// The line over the comment list (UX.md §27): the list's menu, and what it shows. Only the line observes it; the list
/// follows `PanelModel.groups`, which carries the filter and the arrangement.
@MainActor
final class ListBar: ObservableObject {
    /// An item of the menu's Show section: a tag of the round, or Not tagged.
    struct Option: Equatable, Identifiable {
        var id: String
        var name: String
        var sign: String?
        var count: Int
        var help: String
    }

    @Published var options: [Option] = []
    @Published var filter: String?
    @Published var grouping = ListGrouping.status
    /// The round has comments: the line is drawn (not in Focus, whose panel is one card).
    @Published var shown = false
    /// The round's comments, and those the filter keeps.
    @Published var total = 0
    @Published var kept = 0
    weak var model: AppModel?

    /// The menu's Show section: only that tag's comments (`TagCatalog.untagged`: those with none), or all (nil).
    func show(_ id: String?) { model?.setTagFilter(id) }
    func group(_ g: ListGrouping) { model?.setGrouping(g) }

    /// The tag shown alone, nil while every comment is shown.
    var shownTag: Option? { filter.flatMap { f in options.first { $0.id == f } } }

    /// The menu's title: the tag shown alone ("Math & notation ⌄"), else the arrangement ("By status ⌄").
    var title: String { shownTag?.name ?? "By " + grouping.title.lowercased() }

    /// Beside it while a tag is shown alone: "1 of 16 comments".
    var caption: String? { shownTag.map { _ in ListFilter.captions(kept: kept, total: total)[0] } }
}

/// The line's sizes, and what fits at a panel width (pure, so unit-tested). One row, always a token's height, so turning
/// a filter on or off moves nothing under it (the chips' caption, which came with a click, ran over the chips and the
/// list's first header). While a tag is shown alone: its count
/// ("1 of 16 comments") and Show All at the left, the menu as a token at the right (the tag's sign and name and ⌄ on the
/// accent's tint). Short of room, the count says "1 of 16", then the name is cut (to `minName` at least), then the count
/// goes; Show All, the sign and ⌄ always stay whole. Measured with the fonts drawn, each part framed at its measure.
enum ListBarMetrics {
    static let height: CGFloat = 22
    /// The line's inset from the panel's edges, as the notes line above it.
    static let side: CGFloat = 16
    /// The token's ends, and between its sign, name and ⌄.
    static let pad: CGFloat = 8
    static let gap: CGFloat = 4
    /// Between the count and Show All; at least between Show All and the menu.
    static let linkGap: CGFloat = 8
    static let between: CGFloat = 12
    static let minName: CGFloat = 48
    /// TagSign's box at 12 pt.
    static let sign: CGFloat = 19

    static let font = NSFont.systemFont(ofSize: 12)
    static let medium = NSFont.systemFont(ofSize: 12, weight: .medium)

    static func width(_ s: String, _ f: NSFont = font) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: f]).width)
    }

    /// ⌄ (chevron.down, 9 pt semibold), as the group headers' Hide ⌄.
    static let chevron: CGFloat = ceil(NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))?.size.width ?? 9)

    static var showAll: CGFloat { width("Show All") }

    /// The token with a name `name` pt wide.
    static func token(name: CGFloat) -> CGFloat { pad * 2 + sign + gap + name + gap + chevron }

    struct Fit: Equatable {
        /// The count's words, nil when they do not fit.
        var caption: String?
        /// The tag's name's width: less than it needs, it is cut with "…".
        var name: CGFloat
    }

    /// What fits in a panel `width` pt wide, `captions` longest first (before the width is known: all of it).
    static func fit(width: CGFloat, name: String, captions: [String]) -> Fit {
        let need = Self.width(name, medium)
        guard width > 0 else { return Fit(caption: captions.first, name: need) }
        let room = width - 2 * side, fixed = showAll + between + token(name: 0)
        for c in captions where fixed + Self.width(c) + linkGap + need <= room { return Fit(caption: c, name: need) }
        if let c = captions.last, fixed + Self.width(c) + linkGap + minName <= room {
            return Fit(caption: c, name: room - fixed - Self.width(c) - linkGap)
        }
        return Fit(caption: nil, name: max(min(need, room - fixed), 0))
    }

    /// The row's width as laid out (the least, `between` at its minimum).
    static func used(_ f: Fit) -> CGFloat {
        (f.caption.map { width($0) + linkGap } ?? 0) + showAll + between + token(name: f.name)
    }
}

/// The line over the comment list (UX.md §27; the advisor, 2026-10-21: the chips' row broke its layout when one was
/// clicked, and the menu at the right already had the tags): the list's menu at the right, "By status ⌄", whose
/// title is the tag shown alone when there is one; at the left then, "1 of 16 comments" and Show All.
struct CommentListBar: View {
    @ObservedObject var bar: ListBar

    var body: some View {
        if bar.shown {
            // the panel's width from a GeometryReader, which takes the width offered whatever its content: read from
            // the row, a row too wide for the panel (before its width was known) reported its own width, kept its
            // widest form, and ran past both edges
            GeometryReader { g in
                row(width: g.size.width)
                    .padding(.horizontal, ListBarMetrics.side)
                    .frame(width: g.size.width, height: ListBarMetrics.height)
            }
            .frame(height: ListBarMetrics.height)
            .padding(.bottom, 8)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Comment list")
        }
    }

    private func row(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            if let tag = bar.shownTag {
                let captions = ListFilter.captions(kept: bar.kept, total: bar.total)
                let fit = ListBarMetrics.fit(width: width, name: tag.name, captions: captions)
                if let c = fit.caption {
                    Text(c).foregroundStyle(Ink.secondary)
                        .frame(width: ListBarMetrics.width(c), alignment: .leading)
                        .padding(.trailing, ListBarMetrics.linkGap)
                        .accessibilityLabel(captions[0])
                }
                Button("Show All") { bar.show(nil) }
                    .buttonStyle(LinkStyle())
                    .frame(width: ListBarMetrics.showAll, alignment: .leading)
                    .help("Show every comment of the round again")
                Spacer(minLength: ListBarMetrics.between)
                ListMenuButton(bar: bar, tag: tag, name: fit.name)
            } else {
                Spacer(minLength: 0)
                ListMenuButton(bar: bar, tag: nil, name: 0)
            }
        }
        .font(.system(size: 12))
        .lineLimit(1)
    }
}

/// The list's menu (`ListMenu`) as its button: "By status ⌄" (12 Medium, secondary, as the group headers' Show › and
/// Hide ⌄), or while a tag is shown alone a token, its sign and name in the label colour on the accent's tint; the
/// hover fill under the pointer. The menu opens under it, by a click or by Space with keyboard navigation on.
struct ListMenuButton: View {
    @ObservedObject var bar: ListBar
    let tag: ListBar.Option?
    /// The tag's name's width (`ListBarMetrics.fit`).
    let name: CGFloat
    @State private var anchor = MenuAnchor.Box()

    var body: some View {
        Button { ListMenu.popUp(ListMenu.make(bar), under: anchor.view) } label: {
            HStack(spacing: tag == nil ? 3 : ListBarMetrics.gap) {
                if let tag {
                    TagSign(sign: tag.sign, name: tag.name).foregroundStyle(Ink.label2)
                        .frame(width: ListBarMetrics.sign)
                    Text(tag.name).foregroundStyle(Ink.label).truncationMode(.tail)
                        .frame(width: name, alignment: .leading)
                } else {
                    Text(bar.title)
                }
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    .frame(width: ListBarMetrics.chevron)
            }
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(Ink.secondary)
            .padding(.horizontal, tag == nil ? 0 : ListBarMetrics.pad)
            .frame(height: ListBarMetrics.height)
            .contentShape(Rectangle())
            .background(MenuAnchor(box: anchor))
        }
        .buttonStyle(ListMenuStyle(token: tag != nil))
        .fixedSize()
        .help("Arrange the comments by status, tag or section, or show one tag’s comments only")
        .accessibilityLabel("Arrange and show")
        .accessibilityValue(tag.map { "\($0.name) only, by \(bar.grouping.title.lowercased())" } ?? bar.title)
        .accessibilityHint("Opens a menu")
    }
}

/// The menu's button: the token's tint, and the hover fill (pressed, the chips' fill) over it or round the words.
private struct ListMenuStyle: ButtonStyle {
    let token: Bool

    func makeBody(configuration: Configuration) -> some View { ListMenuLabel(configuration: configuration, token: token) }
}

private struct ListMenuLabel: View {
    let configuration: ButtonStyle.Configuration
    let token: Bool
    @State private var hovering = false

    var body: some View {
        let shape = token ? AnyShape(Capsule()) : AnyShape(RoundedRectangle(cornerRadius: 5))
        configuration.label
            .background {
                ZStack {
                    if token { shape.fill(Color(nsColor: Palette.accentTint)) }
                    if hovering || configuration.isPressed {
                        shape.fill(Color(nsColor: configuration.isPressed ? Palette.chipFill : Palette.hover))
                    }
                }
                .padding(.horizontal, token ? 0 : -5)
            }
            .onHover { hovering = $0 }
    }
}

/// An empty AppKit view behind a button's label, for a menu to open under; it takes no click.
struct MenuAnchor: NSViewRepresentable {
    final class Box { weak var view: NSView? }
    let box: Box

    final class Anchor: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> NSView {
        let v = Anchor()
        box.view = v
        return v
    }

    func updateNSView(_ v: NSView, context: Context) { box.view = v }
}

/// The list's menu, an AppKit one (section headers, the counts as the menu's own badges, the tags' signs): Arrange
/// By (Status, Tag, Section) and, while some comment of the round has a tag, Show (All Comments, each tag the round
/// uses with its count in the advisor's order, Not tagged with its count); a check at each section's choice.
@MainActor
enum ListMenu {
    private final class Action: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func invoke() { run() }
    }

    private static func item(_ title: String, on: Bool, image: NSImage? = nil, count: Int? = nil, help: String? = nil,
                             _ run: @escaping () -> Void) -> NSMenuItem {
        let a = Action(run)
        let i = NSMenuItem(title: title, action: #selector(Action.invoke), keyEquivalent: "")
        i.target = a
        i.representedObject = a  // the item keeps its action
        i.state = on ? .on : .off
        i.image = image
        if let count { i.badge = NSMenuItemBadge(count: count) }
        i.toolTip = help
        return i
    }

    static func make(_ bar: ListBar) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        m.addItem(.sectionHeader(title: "Arrange By"))
        for g in ListGrouping.allCases {
            m.addItem(item(g.title, on: bar.grouping == g) { [weak bar] in bar?.group(g) })
        }
        guard !bar.options.isEmpty else { return m }
        m.addItem(.separator())
        m.addItem(.sectionHeader(title: "Show"))
        m.addItem(item("All Comments", on: bar.filter == nil) { [weak bar] in bar?.show(nil) })
        for o in bar.options {
            m.addItem(item(o.name, on: bar.filter == o.id, image: image(o), count: o.count, help: o.help) { [weak bar] in
                bar?.show(o.id)
            })
        }
        return m
    }

    /// A tag's sign as the menu draws images (the template's colour), its initial when it has none, as `TagSign`.
    private static func image(_ o: ListBar.Option) -> NSImage? {
        if let s = o.sign { return NSImage(systemSymbolName: s, accessibilityDescription: nil) }
        let letter = String(o.name.prefix(1)).uppercased() as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]
        let size = letter.size(withAttributes: attrs)
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { r in
            letter.draw(at: NSPoint(x: (r.width - size.width) / 2, y: (r.height - size.height) / 2), withAttributes: attrs)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Opens under `v`, its left edge at the button's (a click, or Space with keyboard navigation on).
    static func popUp(_ menu: NSMenu, under v: NSView?) {
        guard let v else { return }
        if let d = dryRun { return d(menu, v) }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: v.isFlipped ? v.bounds.maxY + 4 : -4), in: v)
    }

    /// --debug-script listmenuclick: the menu a click would open and the view it would open under, kept, not opened
    /// (an open menu would come up over the viewer's work).
    static var dryRun: ((NSMenu, NSView) -> Void)?

    /// --debug-script listmenu: each item as [title, checked, count] ("—" a separator, "# Show" a section's header).
    static func describe(_ m: NSMenu) -> [Any] {
        m.items.map { i -> Any in
            if i.isSeparatorItem { return "—" }
            if i.isSectionHeader { return "# " + i.title }
            return [i.title, i.state == .on, i.badge.map { $0.itemCount as Any } ?? NSNull()] as [Any]
        }
    }

    /// --debug-script listmenu <title>: that item chosen.
    static func perform(_ title: String, in m: NSMenu) -> Bool {
        guard let i = m.items.firstIndex(where: { $0.title == title && $0.action != nil }) else { return false }
        m.performActionForItem(at: i)
        return true
    }
}

extension AppModel {
    /// A comment listed on another page (a student's tag across papers, UX.md §27): its paper in Review, that comment
    /// selected in round `n` (the round it was last shown in; the latest when it is gone). Back returns to the page.
    func openInReview(paper path: String, comment id: String, round n: Int?) {
        openPaper(path, level: .review)
        guard selectedPath == path, level == .review else { return }
        reveal(ReviewTarget(round: n, comment: id))
    }
}

// MARK: Debug hooks (--debug-script tagfilter, listmenu, groupby, list, studenttag, studenttagopen; UX.md §13, §27)

extension AppModel {
    /// The line over the comment list and what the list shows.
    func listResult() -> [String: Any] {
        let b = listBar, g = panel.groups
        let selected: Any = { if case .comment(let id)? = selection { return id } else { return NSNull() } }()
        return ["filter": b.filter ?? NSNull(), "grouping": b.grouping.rawValue, "shown": b.shown,
                "options": b.options.map { [$0.id, $0.name, $0.count] as [Any] }, "title": b.title,
                "caption": b.caption ?? NSNull(),
                "selected": selected, "listed": panel.listed.map(\.id), "rows": panel.scroller.table?.listed ?? [],
                "headers": panel.scroller.table?.headers ?? [], "toCheck": g.toCheck.map(\.id),
                "next": panel.expanded.flatMap { g.nextToCheck(after: $0) } ?? NSNull()]
    }

    /// The student page shown: its key.
    private var shownStudent: String? { if case .student(let k)? = hub { return k } else { return nil } }

    /// A row of the shown student's Topics, as its click (nil: none listed).
    func pickStudentTag(_ tag: String?) {
        guard let k = shownStudent else { return }
        hubModel.studentTag = tag.map { StudentTagChoice(student: k, tag: $0) }
    }

    private var studentTagList: StudentTagList? {
        guard let k = shownStudent, let c = hubModel.studentTag, c.student == k,
              let g = studentGroups.first(where: { $0.key == k }) else { return nil }
        return StudentTagList.make(c.tag, papers: g.papers.map { ($0.path, $0.title) }, data: hubModel.data, catalog: tags.catalog)
    }

    /// A line of it: its paper's path as the list has it, and the line.
    func studentTagLine(_ path: String, _ id: String) -> (path: String, line: OverviewPanel.Line)? {
        let want = (path as NSString).standardizingPath
        guard let p = studentTagList?.papers.first(where: { ($0.path as NSString).standardizingPath == want }),
              let l = p.lines.first(where: { $0.id == id }) else { return nil }
        return (p.path, l)
    }

    func studentTagResult() -> [String: Any] {
        guard let l = studentTagList else { return ["student": shownStudent ?? NSNull(), "tag": NSNull()] }
        // the list shows in a popover on the Topics tile's row (UI v4): there is one when the tile has that row
        let g = studentGroups.first { $0.key == shownStudent }
        let popover = g.map { studentPage($0).tiles.topics?.rows.contains { $0.id == l.tag } == true } ?? false
        return ["student": shownStudent ?? NSNull(), "tag": l.tag, "title": l.title, "meta": l.meta,
                "papers": l.papers.map { p in [p.title, p.lines.map { [$0.id, $0.status, $0.round] as [Any] }] as [Any] },
                "popover": popover]
    }
}
