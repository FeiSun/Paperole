import AppKit
import SwiftUI

// The writing tags' analytics (design/tags/TAGS.md §6 with the critique's fixes; UX.md §24): the paper page's Topics
// and the Student page's writing profile. The engine counts (`overview`'s `tags`); the app lays them out in the
// advisor's tag order and puts the engine's codes into words. Honest by rule: counts only, no shares or decimals, never
// sorted by count, no ranking or comparing groups in words, Not tagged as a grey row, trend words only from the third
// comparable first draft and never between rounds of one paper.

/// One row of a Topics table: a tag (or Not tagged, or the New comments total), its counts per column, Open now and
/// where its comments were written.
struct TopicsRow: Equatable, Identifiable {
    enum Kind: Equatable { case tag, untagged, total }

    var id: String
    var name: String
    var sign: String?
    var group: TagGroup?
    var kind: Kind
    var counts: [Int]
    var open: Int
    var writtenIn: String
    var writtenAll: String
    var help: String
}

/// The paper page's Topics (TAGS.md §6.2): rows in the advisor's order, grouped as the catalogue groups them (the
/// groups in the order their first tag comes); a column per round, the oldest folded into one when they do not fit;
/// Open now; Written in (three sections at most, all in the help tag); Not tagged and New comments last.
struct TopicsTable: Equatable {
    var columns: [String]
    var columnHelp: [String]
    var rows: [TopicsRow]
    var most: Int
    var tagged: Int
    var comments: Int
    var note: String

    var untagged: Int { comments - tagged }

    static func make(_ t: PaperTags, data d: PaperOverview, catalog c: TagCatalog, maxColumns: Int = 8) -> TopicsTable {
        let rounds = t.rounds
        // the oldest rounds fold into one column when they do not fit (as on the map)
        let folded = rounds.count > maxColumns ? Array(rounds.prefix(rounds.count - maxColumns + 1)) : []
        let shown = Array(rounds.dropFirst(folded.count))
        var columns: [String] = [], help: [String] = []
        if let a = folded.first?.n, let b = folded.last?.n {
            columns.append("R\(a)–R\(b)")
            help.append("Rounds \(a) to \(b): new comments in each, added up")
        }
        for r in shown {
            columns.append(shown.count + (folded.isEmpty ? 0 : 1) > 5 ? "R\(r.n)" : "Round \(r.n)")
            help.append("New comments written in Round \(r.n)")
        }
        func per(_ f: (PaperTags.Round) -> Int) -> [Int] {
            (folded.isEmpty ? [] : [folded.reduce(0) { $0 + f($1) }]) + shown.map(f)
        }
        func written(_ row: TagRow) -> (String, String) {
            let parts = row.writtenIn.map { "\(d.shortTitle($0.key, d.sectionTitle($0.key) ?? $0.key)) \($0.count)" }
            return (parts.prefix(3).joined(separator: " · "), parts.joined(separator: " · "))
        }
        var rows: [TopicsRow] = []
        let ids = c.sorted(Array(t.byTag.keys))
        let groupOrder = c.tags.map(\.group).reduce(into: [TagGroup]()) { if !$0.contains($1) { $0.append($1) } }
        let ordered = ids.enumerated().sorted { a, b in
            let ga = c.tag(a.element)?.group, gb = c.tag(b.element)?.group
            let ia = ga.flatMap { groupOrder.firstIndex(of: $0) } ?? groupOrder.count
            let ib = gb.flatMap { groupOrder.firstIndex(of: $0) } ?? groupOrder.count
            return (ia, a.offset) < (ib, b.offset)
        }.map(\.element)
        for id in ordered {
            guard let row = t.byTag[id], row.comments > 0 else { continue }
            let tag = c.tag(id)
            let w = written(row)
            rows.append(TopicsRow(id: id, name: c.name(id), sign: tag?.sign, group: tag?.group ?? .other, kind: .tag,
                                  counts: per { $0.byTag[id] ?? 0 }, open: row.open, writtenIn: w.0, writtenAll: w.1,
                                  help: tag.map(TagText.help) ?? "A tag from another Mac’s list"))
        }
        let w = written(t.untagged)
        rows.append(TopicsRow(id: TagCatalog.untagged, name: "Not tagged", sign: TagCatalog.untaggedSign, group: nil, kind: .untagged,
                              counts: per { $0.untagged }, open: t.untagged.open, writtenIn: w.0, writtenAll: w.1,
                              help: "Comments without a tag yet"))
        rows.append(TopicsRow(id: "new", name: "New comments", sign: nil, group: nil, kind: .total, counts: per { $0.new },
                              open: t.open, writtenIn: "", writtenAll: "", help: "Each comment once, in the round you wrote it"))
        let most = rows.filter { $0.kind == .tag }.flatMap(\.counts).max() ?? 1
        var note = "Counts of comments, each in the round you wrote it. A comment with two tags is in both rows; New comments and "
            + "Open now count it once. The bars share one scale. Later rounds look only at what changed, so fewer new comments "
            + "there is no trend."
        if let l = d.latest, !l.isClosed, (rounds.last?.new ?? 0) == 0, rounds.last?.n == l.n {
            note += " Round \(l.n) has no new comments yet."
        }
        return TopicsTable(columns: columns, columnHelp: help, rows: rows, most: max(1, most), tagged: t.tagged,
                           comments: t.comments, note: note)
    }
}

/// A count with its short bar (TAGS.md §6.2): one scale a table, at most 30 pt, 5 pt high and round; 1 a 6 pt capsule;
/// none "–". The bars are the small maps' warm stone: they count comments, as the map's steps do.
struct TagCount: View {
    let value: Int
    let most: Int
    var bar = true
    var bold = false
    /// A total says 0, not "–".
    var zero = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 5) {
            if value > 0 || zero {
                if bar && value > 0 {
                    Capsule().fill(MapInk(dark: scheme == .dark).color(.mini2))
                        .frame(width: max(6, CGFloat(value) / CGFloat(max(1, most)) * 30), height: 5)
                }
                Text("\(value)").fontWeight(bold ? .semibold : .regular).monospacedDigit()
            } else {
                Text("–").foregroundStyle(Ink.secondary)
            }
        }
        .frame(minWidth: bar ? 52 : 28, alignment: .trailing)
    }
}

/// The paper page's Topics, under the map's legend (TAGS.md §6.2): a click on a row follows that tag (the map's
/// numbers stay; the cells without it step back), again on the row followed shows the whole paper again.
struct TopicsView: View {
    let model: AppModel
    @ObservedObject var overview: OverviewModel
    @ObservedObject var tags: TagModel
    let width: CGFloat

    var body: some View {
        if let d = overview.data, let t = d.tags, t.tagged > 0 {
            let table = TopicsTable.make(t, data: d, catalog: tags.catalog, maxColumns: max(3, Int((width - 520) / 76)))
            let followed: String? = { if case .tag(let id)? = overview.selection { return id } else { return nil } }()
            VStack(alignment: .leading, spacing: 10) {
                Divider()
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Topics").font(.system(size: 14, weight: .semibold))
                    Text("new comments in each round, by your tags").font(.system(size: 12)).foregroundStyle(Ink.secondary)
                    Spacer(minLength: 8)
                    Text("\(table.tagged) of \(table.comments) tagged").font(.system(size: 12)).foregroundStyle(Ink.secondary)
                    if table.untagged > 0 {
                        Text("·").foregroundStyle(Ink.secondary)
                        Button("Tag \(count(table.untagged, "Comment"))…") { model.openTagComments() }
                            .buttonStyle(LinkStyle()).font(.system(size: 12, weight: .medium))
                            .help("Tag the comments that have none yet, of every round")
                    }
                }
                TopicsGrid(table: table, followed: followed, follow: { id in
                    model.overviewClicked(id == followed ? nil : .tag(id))
                })
                Text(table.note).font(.system(size: 11.5)).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 620, alignment: .leading)  // about 85 characters a line (the UI audit)
            }
            .contentShape(Rectangle())
            .onTapGesture {}  // its own space keeps what is followed
        }
    }
}

/// The Topics table: group headers in small capitals of the secondary colour (not tertiary: the critique, POLISH keeps
/// tertiary for placeholders), each row one line that follows its tag when clicked, the row followed on the accent's
/// tint as one band (rows of fixed columns, so a row's fill is one shape), the pointer's row on the hover fill.
struct TopicsGrid: View {
    let table: TopicsTable
    let followed: String?
    let follow: (String) -> Void
    @State private var hovered: String?

    static let nameWidth: CGFloat = 190, openWidth: CGFloat = 70

    private var countWidth: CGFloat { table.columns.contains { $0.hasPrefix("Round") } ? 70 : 58 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: Self.nameWidth, height: 1)
                ForEach(Array(table.columns.enumerated()), id: \.offset) { i, c in
                    Text(c).lineLimit(1).frame(width: countWidth, alignment: .trailing).help(table.columnHelp[i])
                }
                Text("Open now").frame(width: Self.openWidth, alignment: .trailing)
                    .help("Comments with this tag still open now, each once")
                Text("Written in").padding(.leading, 20).help("The sections they were written in, most first")
                Spacer(minLength: 0)
            }
            .font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.secondary)
            .padding(.bottom, 4)
            ForEach(Array(table.rows.enumerated()), id: \.element.id) { i, r in
                if r.kind == .tag, i == 0 || table.rows[i - 1].group != r.group, let g = r.group {
                    // a group's name as the sidebar's section headers: no capitals, nothing under 11 pt (the UI audit)
                    Text(g.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.secondary)
                        .padding(.top, i == 0 ? 4 : 12).padding(.bottom, 3)
                }
                if r.kind != .tag { Divider().padding(.top, r.kind == .untagged ? 8 : 0) }
                row(r)
            }
        }
        .font(.system(size: 13))
    }

    private func row(_ r: TopicsRow) -> some View {
        let on = followed == r.id
        let total = r.kind == .total
        return HStack(spacing: 0) {
            HStack(spacing: 7) {
                if !total { TagSign(sign: r.sign, name: r.name).frame(width: 16).foregroundStyle(on ? Ink.accentText : Ink.secondary) }
                Text(r.name).fontWeight(total ? .semibold : on ? .medium : .regular)
                    .foregroundStyle(r.kind == .untagged ? Ink.secondary : on ? Ink.accentText : Ink.label)
                    .lineLimit(1)
            }
            .frame(width: Self.nameWidth, alignment: .leading)
            .help(r.help)
            ForEach(Array(r.counts.enumerated()), id: \.offset) { _, v in
                TagCount(value: v, most: table.most, bar: r.kind == .tag, bold: total, zero: total)
                    .frame(width: countWidth, alignment: .trailing)
            }
            Text(r.open > 0 || total ? "\(r.open)" : "–").monospacedDigit().fontWeight(total ? .semibold : .regular)
                .foregroundStyle(r.open > 0 && r.kind != .untagged || total ? Ink.label : Ink.secondary)
                .frame(width: Self.openWidth, alignment: .trailing)
            Text(r.writtenIn).foregroundStyle(Ink.secondary).lineLimit(1).truncationMode(.tail).help(r.writtenAll)
                .padding(.leading, 20)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color(nsColor: Palette.accentTint)
                                                          : hovered == r.id && !total ? Color(nsColor: Palette.hover) : .clear))
        .padding(.horizontal, -8)
        .contentShape(Rectangle())
        .onHover { h in if !total { hovered = h ? r.id : (hovered == r.id ? nil : hovered) } }
        .onTapGesture { if !total { follow(r.id) } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(total ? [] : on ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(total ? "" : on ? "Followed: click to show the whole paper" : "Follows \(r.name) on the map")
    }
}

// MARK: - The Student page's writing profile

/// The words of the writing profile (TAGS.md §6.3 with the critique's fixes): the engine's codes as sentences, facts
/// one at a time, trend words with their numbers beside them.
enum ProfileText {
    /// "fewer", "more", "about the same", "no clear trend"; nil while there is no word.
    static func trend(_ word: String?) -> String? {
        switch word {
        case "fewer": return "fewer"
        case "more": return "more"
        case "same": return "about the same"
        case "mixed": return "no clear trend"
        default: return nil
        }
    }

    /// Why there is no trend word yet, in the First drafts' Trend column.
    static func why(_ why: String?) -> String {
        switch why {
        case "two_points": return "after a third"
        case "small": return "too few to compare"
        case "untagged": return "too few tagged"
        case "lengths_differ": return "lengths differ"
        default: return ""
        }
    }

    static func whyHelp(_ why: String?) -> String {
        switch why {
        case "two_points": return "Trend words need three first drafts: two are not a trend."
        case "small": return "A first draft with fewer than 5 new comments is not compared."
        case "untagged": return "A first draft is compared once at least 4 in 5 of its comments are tagged."
        case "lengths_differ": return "The longest first draft has more than 1.5 times the pages of the shortest, so counts are not compared."
        default: return "Every step goes the same way and the last is at most half the first (or at least double): fewer or more. All within one: about the same."
        }
    }

    /// One fact, a whole sentence (the critique's fix: never two papers' counts side by side).
    static func fact(_ f: StudentTags.Fact, catalog c: TagCatalog, titles: [String: String]) -> String? {
        let tag = c.name(f.tag)
        let paper = f.path.flatMap { titles[$0] } ?? "the paper"
        switch f.kind {
        case "none_since":
            guard let n = f.round else { return nil }
            return "\(tag): none since Round \(n) of \(paper)."  // as the other facts (the UI audit: a title’s possessive)
        case "slow":
            guard let n = f.n, let of = f.of else { return nil }
            return "\(tag): \(n) of its \(of) comments took two rounds or more."
        case "new_words":
            guard let n = f.n, let r = f.round, let w = f.words else { return nil }
            return "\(tag): \(count(n, "comment")) in Round \(r) of \(paper), on \(OverviewText.grouped(w)) new words."
        default: return nil
        }
    }

    /// The opening sentence: the papers and rounds, then the facts.
    static func lede(_ t: StudentTags, catalog c: TagCatalog, titles: [String: String]) -> String {
        let papers = Set(t.rounds.map(\.path)).count
        let head = "\(HubText.spelled(papers)) \(papers == 1 ? "paper" : "papers"), \(HubText.spelled(t.rounds.count).lowercased()) \(t.rounds.count == 1 ? "round" : "rounds")."
        let facts = t.facts.compactMap { fact($0, catalog: c, titles: titles) }
        return ([head] + facts).joined(separator: " ")
    }

    /// For the next draft, copied for the email (TAGS.md §6.3): English only, the lines and the student's sentences
    /// with their pages; the advisor's own words (often Chinese) are not copied. Nothing is sent.
    static func email(_ focus: [StudentTags.Focus], catalog c: TagCatalog, titles: [String: String]) -> String {
        var out = ["For the next draft:"]
        for f in focus {
            guard let t = c.tag(f.tag) else { continue }
            out.append("")
            out.append("• " + t.name + (t.focus.isEmpty ? "" : ": " + t.focus))
            if let e = f.example, let text = e.text, !text.isEmpty {
                let where_ = [e.path.flatMap { titles[$0] }, e.page.map { "p.\($0 + 1)" }].compactMap { $0 }.joined(separator: " ")
                out.append("  For example" + (where_.isEmpty ? "" : " (\(where_))") + ": “\(text)”")
            }
        }
        return out.joined(separator: "\n")
    }
}

/// The writing profile's tag parts on a student's page (TAGS.md §6.3): Topics by round, First drafts, For the next
/// draft, Done well and How comments closed by topic; or, before any tag, one line and Tag Comments….
struct StudentTagsProfile: View {
    @ObservedObject var model: AppModel
    @ObservedObject var tags: TagModel
    /// The tag whose comments are listed under the table (`HubModel.studentTag`, UX.md §27).
    @ObservedObject var hub: HubModel
    let group: StudentGroup
    let stats: StudentStats
    let width: CGFloat
    /// The student's comments open now, each once (the papers' threads).
    var open = 0

    var body: some View {
        let titles = Dictionary(group.papers.map { ($0.path, $0.title) }, uniquingKeysWith: { a, _ in a })
        if let t = stats.tags, t.tagged > 0 {
            VStack(alignment: .leading, spacing: 18) {
                ProfileBox(title: "Topics by round", caption: "\(t.tagged) of \(count(t.comments, "comment")) tagged") {
                    Text(ProfileText.lede(t, catalog: tags.catalog, titles: titles))
                        .font(.system(size: 13.5)).foregroundStyle(Ink.label2).fixedSize(horizontal: false, vertical: true)
                    // a row's tag clicked: its comments across the papers, under the table (UX.md §27)
                    let picked = hub.studentTag.flatMap { $0.student == group.key ? $0.tag : nil }
                    StudentTopicsGrid(t: t, catalog: tags.catalog, titles: titles, open: open, selected: picked) { id in
                        hub.studentTag = picked == id ? nil : StudentTagChoice(student: group.key, tag: id)
                    }
                    HStack(alignment: .firstTextBaseline) {
                        Text("A comment with two tags is in both rows; All and Open now count it once. Later rounds look only at what changed, so this table has no trend words: the first drafts are compared below. Click a tag for its comments.")
                            .font(.system(size: 11.5)).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 620, alignment: .leading)
                        Spacer(minLength: 8)
                        if t.comments > t.tagged {
                            Button("Tag \(count(t.comments - t.tagged, "Comment"))…") { model.openTagComments(student: group.key) }
                                .buttonStyle(LinkStyle()).font(.system(size: 12, weight: .medium)).fixedSize()
                        }
                    }
                    if let picked {
                        Divider()
                        StudentTagPanel(model: model, list: StudentTagList.make(picked, papers: group.papers.map { ($0.path, $0.title) },
                                                                                 data: hub.data, catalog: tags.catalog))
                    }
                }
                let wide = width >= 900
                let left = VStack(spacing: 18) {
                    FirstDraftsBox(t: t, catalog: tags.catalog, titles: titles)
                    ClosedByTopicBox(t: t, catalog: tags.catalog)
                }
                let right = VStack(spacing: 18) {
                    NextDraftBox(model: model, t: t, catalog: tags.catalog, titles: titles, student: group.name)
                    if let p = t.praise, (p.comments ?? 0) > 0 { DoneWellBox(praise: p, titles: titles) }
                }
                if wide {
                    HStack(alignment: .top, spacing: 18) {
                        left.frame(width: (width - 18) * 0.52)
                        right.frame(width: (width - 18) * 0.48)
                    }
                } else {
                    VStack(spacing: 18) { left; right }
                }
            }
        } else {
            HStack(spacing: 8) {
                Image(systemName: "tag").foregroundStyle(Ink.secondary)
                Text("Topics, first drafts and For the next draft start when you tag comments.")
                    .foregroundStyle(Ink.secondary)
                Button("Tag Comments…") { model.openTagComments(student: group.key) }.buttonStyle(LinkStyle())
                    .help("Tag this student’s comments, of every paper and round")
                Spacer(minLength: 0)
            }
            .font(.system(size: 13))
        }
    }
}

/// Topics by round: a row per tag, a column per round of each paper (the paper's name over its rounds, Round 1 with
/// its month), All (each comment once) and Open now.
struct StudentTopicsGrid: View {
    let t: StudentTags
    let catalog: TagCatalog
    let titles: [String: String]
    /// The comments open now, each once (the papers' threads).
    let open: Int
    /// The tag (or Not tagged) whose comments are listed under the table, and a click on a row's name (UX.md §27).
    var selected: String? = nil
    var pick: (String) -> Void = { _ in }
    @State private var hovered: String?

    private var papers: [String] { t.rounds.map(\.path).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } } }
    private var cols: [StudentTags.Round] { papers.flatMap { p in t.rounds.filter { $0.path == p }.sorted { $0.n < $1.n } } }
    private var ids: [String] { catalog.sorted(Array(t.byTag.keys)).filter { (t.byTag[$0]?.comments ?? 0) > 0 } }
    private var most: Int { ids.flatMap { id in cols.map { $0.byTag[id] ?? 0 } }.max() ?? 1 }

    var body: some View {
        let cols = self.cols, most = self.most
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 0) {
                paperRow
                roundRow(cols)
                ForEach(ids, id: \.self) { id in tagRow(id, cols: cols, most: most) }
                untaggedRow(cols, most: most)
                totalRow(cols)
            }
            .font(.system(size: 13))
        }
    }

    private var paperRow: some View {
        GridRow {
            Text("").gridColumnAlignment(.leading)
            ForEach(papers, id: \.self) { p in
                let n = cols.filter { $0.path == p }.count
                Text(LandBox.short(titles[p] ?? "")).font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.label2)
                    .lineLimit(1).frame(maxWidth: 220, alignment: .center)
                    .gridCellColumns(n).gridCellAnchor(.center)
                    .help(titles[p] ?? "")
            }
            Text("").gridCellColumns(2)
        }
    }

    private func roundLabel(_ r: StudentTags.Round) -> String {
        guard r.first, let d = HubText.day(r.date), let month = d.split(separator: " ").first else { return "R\(r.n)" }
        return "R\(r.n) · " + month
    }

    private func roundRow(_ cols: [StudentTags.Round]) -> some View {
        GridRow {
            Text("").gridColumnAlignment(.leading)
            ForEach(Array(cols.enumerated()), id: \.offset) { _, r in
                Text(roundLabel(r)).font(.system(size: 11.5)).foregroundStyle(Ink.secondary).lineLimit(1)
            }
            Text(papers.count == 2 ? "Both papers" : papers.count > 2 ? "All papers" : "All rounds")
                .font(.system(size: 11.5)).foregroundStyle(Ink.secondary).lineLimit(1)
            Text("Open now").font(.system(size: 11.5)).foregroundStyle(Ink.secondary).lineLimit(1)
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func tagRow(_ id: String, cols: [StudentTags.Round], most: Int) -> some View {
        let row = t.byTag[id] ?? TagRow()
        Divider().gridCellUnsizedAxes(.horizontal)
        GridRow {
            name(id)
            ForEach(Array(cols.enumerated()), id: \.offset) { _, r in TagCount(value: r.byTag[id] ?? 0, most: most) }
            Text("\(row.comments)").monospacedDigit()
            Text(row.open > 0 ? "\(row.open)" : "–").monospacedDigit().foregroundStyle(row.open > 0 ? Ink.label : Ink.secondary)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func untaggedRow(_ cols: [StudentTags.Round], most: Int) -> some View {
        Divider().gridCellUnsizedAxes(.horizontal)
        GridRow {
            pickable(TagCatalog.untagged, help: "The comments without a tag yet") { on in
                HStack(spacing: 6) {
                    TagSign(sign: TagCatalog.untaggedSign, name: "").frame(width: 16)
                    Text("Not tagged").fontWeight(on ? .medium : .regular)
                }
                .foregroundStyle(on ? Ink.accentText : Ink.secondary)
            }
            ForEach(Array(cols.enumerated()), id: \.offset) { _, r in TagCount(value: r.untagged, most: most, bar: false) }
            Text("\(t.untagged.comments)").monospacedDigit().foregroundStyle(Ink.secondary)
            Text(t.untagged.open > 0 ? "\(t.untagged.open)" : "–").monospacedDigit().foregroundStyle(Ink.secondary)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func totalRow(_ cols: [StudentTags.Round]) -> some View {
        Divider().gridCellUnsizedAxes(.horizontal)
        GridRow {
            Text("New comments").fontWeight(.semibold)
            ForEach(Array(cols.enumerated()), id: \.offset) { _, r in Text("\(r.new)").fontWeight(.semibold).monospacedDigit() }
            Text("\(t.comments)").fontWeight(.semibold).monospacedDigit()
            Text(open > 0 ? "\(open)" : "–").fontWeight(.semibold).monospacedDigit()
        }
        .padding(.vertical, 4)
    }

    private func name(_ id: String) -> some View {
        pickable(id, help: catalog.tag(id).map(TagText.help) ?? "") { on in
            HStack(spacing: 6) {
                TagSign(sign: catalog.sign(id), name: catalog.name(id)).frame(width: 16)
                    .foregroundStyle(on ? Ink.accentText : Ink.secondary)
                Text(catalog.name(id)).lineLimit(1).fontWeight(on ? .medium : .regular)
                    .foregroundStyle(on ? Ink.accentText : Ink.label)
            }
        }
    }

    /// A row's name, which lists its comments under the table when clicked (again: no list): the row's name on the
    /// accent's tint while listed, on the hover fill under the pointer, as the paper page's Topics rows; a › after it
    /// (⌄ while listed) says it opens something without the pointer over it.
    private func pickable<Label: View>(_ id: String, help: String, @ViewBuilder label: (Bool) -> Label) -> some View {
        let on = selected == id
        return HStack(spacing: 5) {
            label(on)
            Image(systemName: on ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                .foregroundStyle(on ? Ink.accentText : Ink.secondary)
        }
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color(nsColor: Palette.accentTint)
                                                               : hovered == id ? Color(nsColor: Palette.hover) : .clear))
            .padding(.horizontal, -6)
            .contentShape(Rectangle())
            .onHover { h in hovered = h ? id : (hovered == id ? nil : hovered) }
            .onTapGesture { pick(id) }
            .help(help + (help.isEmpty ? "" : "\n") + (on ? "Click to hide its comments" : "Click to list its comments across the papers"))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { pick(id) }
    }
}

/// First drafts (TAGS.md §6.1 T6 with the critique's fix): each paper's Round 1 with its pages, the counts, and a Trend
/// word only from the third comparable first draft of similar length, its numbers beside it.
struct FirstDraftsBox: View {
    let t: StudentTags
    let catalog: TagCatalog
    let titles: [String: String]

    var body: some View {
        let firsts = t.rounds.filter(\.first)
        let ids = catalog.sorted(Array(t.byTag.keys)).filter { id in id != "praise" && firsts.contains { ($0.byTag[id] ?? 0) > 0 } }
        let skipped = Dictionary(t.firstDrafts.skipped.map { ($0.path, $0.why) }, uniquingKeysWith: { a, _ in a })
        ProfileBox(title: "First drafts", caption: "counts, pages beside") {
            if firsts.isEmpty {
                Text("No first draft yet.").font(.system(size: 13)).foregroundStyle(Ink.secondary)
            } else {
                Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 0) {
                    GridRow {
                        Text("").gridColumnAlignment(.leading)
                        ForEach(Array(firsts.enumerated()), id: \.offset) { _, r in
                            Text(LandBox.short(Self.short(titles[r.path] ?? "")) + (r.pages.map { " · \($0) pp" } ?? ""))
                                .font(.system(size: 11.5)).foregroundStyle(skipped[r.path] == nil ? Ink.secondary : Ink.tertiary).lineLimit(1)
                                .help((titles[r.path] ?? "") + (skipped[r.path].map { " · not compared: " + ProfileText.whyHelp($0) } ?? ""))
                        }
                        Text("Trend").font(.system(size: 11.5)).foregroundStyle(Ink.secondary).gridColumnAlignment(.leading)
                    }
                    .padding(.bottom, 4)
                    ForEach(ids, id: \.self) { id in
                        Divider().gridCellUnsizedAxes(.horizontal)
                        GridRow {
                            Text(catalog.name(id)).lineLimit(1)
                            ForEach(Array(firsts.enumerated()), id: \.offset) { _, r in
                                Text("\(r.byTag[id] ?? 0)").monospacedDigit()
                            }
                            let tr = t.firstDrafts.trend[id]
                            Group {
                                if let w = ProfileText.trend(tr?.word) {
                                    Text(w).foregroundStyle(Ink.label2)
                                } else {
                                    Text(ProfileText.why(tr?.why ?? "two_points")).foregroundStyle(Ink.secondary)
                                }
                            }
                            .help(ProfileText.whyHelp(tr?.word == nil ? tr?.why ?? "two_points" : nil))
                        }
                        .padding(.vertical, 4)
                    }
                }
                .font(.system(size: 13))
                Text("Trend words compare first drafts only, from the third of similar length; never “better” or “worse”.")
                    .font(.system(size: 11.5)).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A paper's short name for a column: its first word or two.
    static func short(_ title: String) -> String {
        let words = title.split(separator: " ")
        return words.prefix(words.first.map { $0.count < 5 } == true ? 2 : 1).joined(separator: " ")
    }
}

/// For the next draft (TAGS.md §6.3): at most two tags still happening (the engine's picks, in the advisor's order on a
/// tie), each with its facts, the advisor's line for it, the student's own sentence and the advisor's words; Copy for
/// the Email copies the English lines and the sentences only. Nothing is sent.
struct NextDraftBox: View {
    let model: AppModel
    let t: StudentTags
    let catalog: TagCatalog
    let titles: [String: String]
    let student: String
    @State private var copied = false

    var body: some View {
        ProfileBox(title: "For the next draft", caption: "your words, to copy") {
            if t.focus.isEmpty {
                Text("Nothing stands out yet: a tag needs 3 comments still open, new or followed up.")
                    .font(.system(size: 13)).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(t.focus, id: \.tag) { f in card(f) }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Button { copy() } label: { Label(copied ? "Copied" : "Copy for the Email", systemImage: "doc.on.doc") }
                        .help("The lines and \(OverviewText.firstName(student))’s sentences, in English, on the clipboard. Nothing is sent.")
                    Text("English only: the lines and the student’s sentences. Nothing is sent.")
                        .font(.system(size: 11.5)).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func card(_ f: StudentTags.Focus) -> some View {
        let tag = catalog.tag(f.tag)
        let facts = [f.comments.map { count($0, "comment") }, (f.followedUp ?? 0) > 0 ? "\(f.followedUp!) needed a follow-up" : nil,
                     (f.open ?? 0) > 0 ? "\(f.open!) open" : nil].compactMap { $0 }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                TagSign(sign: tag?.sign, name: catalog.name(f.tag)).foregroundStyle(Ink.secondary)
                Text(catalog.name(f.tag)).font(.system(size: 14, weight: .semibold))
            }
            Text(facts).font(.system(size: 12)).foregroundStyle(Ink.secondary)
            if let line = tag?.focus, !line.isEmpty {
                Text(line).font(.system(size: 13.5)).fixedSize(horizontal: false, vertical: true)
            }
            if let e = f.example {
                if let text = e.text, !text.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(text).font(.system(size: 13.5, design: .serif)).foregroundStyle(Ink.label2)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        Text([OverviewText.firstName(student), e.path.flatMap { titles[$0] }.map { $0 + (e.page.map { " p.\($0 + 1)" } ?? "") },
                              e.id].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 11)).foregroundStyle(Ink.secondary)
                    }
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) { Rectangle().fill(Color(nsColor: Palette.rule)).frame(width: 2) }
                }
                if let note = e.note, !note.isEmpty {
                    Text(note).font(.system(size: 12.5)).foregroundStyle(Ink.label2).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: Palette.bubble)))
                        .textSelection(.enabled)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: Palette.rule), lineWidth: 1))
    }

    private func copy() {
        AppModel.clipboard.clearContents()
        AppModel.clipboard.setString(ProfileText.email(t.focus, catalog: catalog, titles: titles), forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }
}

/// Done well: how many, and the latest of the advisor's words.
struct DoneWellBox: View {
    let praise: StudentTags.Praise
    let titles: [String: String]

    var body: some View {
        ProfileBox(title: "Done well", caption: "never counted as a problem") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "star").foregroundStyle(Ink.secondary)
                Text(count(praise.comments ?? 0, "comment")).font(.system(size: 13, weight: .medium))
            }
            if let l = praise.latest, let note = l.note, !note.isEmpty {
                Text([l.path.flatMap { titles[$0] }, l.round.map { "R\($0)" }, l.page.map { "p.\($0 + 1)" }].compactMap { $0 }
                        .joined(separator: " ") + ": “" + note + "”")
                    .font(.system(size: 13)).foregroundStyle(Ink.label2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// How comments closed, by topic (TAGS.md §6.3): each tag's comments closed after 1, 2 or 3+ rounds you answered in,
/// open, followed up; rounds you left open count against nobody; a reopened comment is open until closed again.
struct ClosedByTopicBox: View {
    let t: StudentTags
    let catalog: TagCatalog

    var body: some View {
        let ids = catalog.sorted(Array(t.byTag.keys)).filter { $0 != "praise" && (t.byTag[$0]?.comments ?? 0) > 0 }
        let most = ids.compactMap { t.byTag[$0].map { max($0.one, $0.two, $0.three) } }.max() ?? 1
        let revived = ids.reduce(0) { $0 + (t.byTag[$1]?.revived ?? 0) }
        ProfileBox(title: "How comments closed, by topic", caption: "rounds you answered in") {
            Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 0) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    ForEach(["1 round", "2", "3+", "open", "followed up"], id: \.self) { h in
                        Text(h).font(.system(size: 11.5)).foregroundStyle(Ink.secondary).lineLimit(1)
                    }
                }
                .padding(.bottom, 4)
                ForEach(ids, id: \.self) { id in
                    let r = t.byTag[id]!
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        Text(catalog.name(id)).lineLimit(1)
                        TagCount(value: r.one, most: most)
                        TagCount(value: r.two, most: most, bar: false)
                        TagCount(value: r.three, most: most, bar: false)
                        TagCount(value: r.open, most: most, bar: false)
                        TagCount(value: r.followedUp, most: most, bar: false)
                    }
                    .padding(.vertical, 4)
                }
            }
            .font(.system(size: 13))
            Text("Each comment once in each of its tags’ rows. Rounds you left open count against nobody"
                 + (revived > 0 ? "; \(count(revived, "comment")) you reopened \(revived == 1 ? "counts" : "count") as open until closed again." : "."))
                .font(.system(size: 11.5)).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - One tag across a student's papers (UX.md §27)

/// The tag a student's page lists the comments of: the student's key and the tag (`TagCatalog.untagged`: Not tagged).
struct StudentTagChoice: Equatable {
    var student: String
    var tag: String
}

/// One tag's comments across a student's papers (UX.md §27): by paper in the student's order, each comment once, by
/// the section it was written in, each with what became of it (the paper page's tag panel, `OverviewPanel.tag`).
struct StudentTagList: Equatable {
    struct Paper: Equatable, Identifiable {
        var path: String
        var title: String
        var lines: [OverviewPanel.Line]
        var open: Int
        var id: String { path }
    }

    var tag: String
    var title: String
    var meta: String
    var papers: [Paper]
    var count: Int

    static func make(_ tag: String, papers: [(path: String, title: String)], data: [String: PaperOverview],
                     catalog: TagCatalog) -> StudentTagList {
        let untagged = tag == TagCatalog.untagged
        var out: [Paper] = []
        for p in papers {
            guard let d = data[p.path], case .lines(let lines, _, _) = OverviewPanel.tag(tag, d, strip: nil).body,
                  !lines.isEmpty else { continue }
            let open = d.comments.filter { c in (untagged ? c.tags.isEmpty : c.tags.contains(tag)) && !OverviewPanel.isClosed(c) }.count
            out.append(Paper(path: p.path, title: p.title, lines: lines, open: open))
        }
        let total = out.reduce(0) { $0 + $1.lines.count }, open = out.reduce(0) { $0 + $1.open }
        let meta = out.isEmpty ? "" : Paperole.count(total, "comment") + (out.count > 1 ? " in \(out.count) papers" : "")
            + ", each counted once · \(open) open"
        return StudentTagList(tag: tag, title: catalog.name(tag), meta: meta, papers: out, count: total)
    }
}

/// Under Topics by round while a row's tag is picked: its comments in each paper, a line each (its colour, id, your
/// words, where it was written and what became of it); a click on a line opens Review at that comment, in the round it
/// is last shown in (Not tagged's Tag Comments… is the table's, just above).
struct StudentTagPanel: View {
    let model: AppModel
    let list: StudentTagList
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(list.title).font(.system(size: 14, weight: .semibold)).lineLimit(1).fixedSize()
                Text(list.meta).font(.system(size: 12)).foregroundStyle(Ink.secondary).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
            }
            if list.papers.isEmpty {
                Text("No comment has this tag now.").font(.system(size: 12)).foregroundStyle(Ink.secondary)
            }
            ForEach(list.papers) { p in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(p.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.label2).lineLimit(1)
                        Text(count(p.lines.count, "comment") + " · \(p.open) open").font(.system(size: 12)).foregroundStyle(Ink.secondary)
                            .lineLimit(1).fixedSize()
                    }
                    .padding(.bottom, 2)
                    ForEach(p.lines) { l in line(p, l) }
                }
            }
            Text("A click on a comment opens Review there, in the round it was last shown in.")
                .font(.system(size: 11.5)).foregroundStyle(Ink.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(list.title + ", comments")
        // the list is under the page's last box, so usually below the window's bottom: its top is scrolled into view
        // when a tag is picked, else the click would seem to do nothing
        .background(ScrollIntoView(trigger: list.tag))
    }

    private func line(_ p: StudentTagList.Paper, _ l: OverviewPanel.Line) -> some View {
        let key = p.path + "|" + l.id
        return HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: (l.color.flatMap(MarkColor.init(name:)) ?? .yellow).fill))
                .frame(width: 4, height: 18)
            Text(l.id).font(.system(size: 12, weight: .semibold)).monospacedDigit().frame(width: 50, alignment: .leading)
            Text(l.text).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 6)
            amberRings(l.status).font(.system(size: 12)).foregroundStyle(Ink.secondary).lineLimit(1).fixedSize()
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Ink.secondary)
                .opacity(hovered == key ? 1 : 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .frame(minHeight: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovered == key ? Color(nsColor: Palette.hover) : .clear))
        .padding(.horizontal, -8)
        .contentShape(Rectangle())
        .onHover { h in hovered = h ? key : (hovered == key ? nil : hovered) }
        .onTapGesture { model.openInReview(paper: p.path, comment: l.id, round: l.round) }
        .help("Open \(l.id) of \(p.title) in Review, Round \(l.round)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(l.id): \(l.text). \(l.status.replacingOccurrences(of: "○", with: ""))")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.openInReview(paper: p.path, comment: l.id, round: l.round) }
    }
}

/// Scrolls the page so the top of the view it is the background of is in sight, each time `trigger` changes (and when
/// it first appears): the least scroll that shows its first 220 pt, as NSView's scrollToVisible does.
struct ScrollIntoView: NSViewRepresentable {
    let trigger: String

    final class Anchor: NSView {
        var shown: String?
        func reveal() {
            guard window != nil, enclosingScrollView != nil else { return }
            let h = min(bounds.height, 220)
            scrollToVisible(NSRect(x: 0, y: isFlipped ? 0 : bounds.height - h, width: bounds.width, height: h))
        }
    }

    func makeNSView(context: Context) -> Anchor { Anchor() }

    func updateNSView(_ v: Anchor, context: Context) {
        guard v.shown != trigger else { return }
        v.shown = trigger
        DispatchQueue.main.async { v.reveal() }  // once the page has laid the list out
    }
}
