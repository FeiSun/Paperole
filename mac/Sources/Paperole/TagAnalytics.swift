import AppKit
import SwiftUI

// The writing tags' analytics (design/tags/TAGS.md §6 with the critique's fixes; UX.md §24, §40.4): the paper page's
// Topics and the Student page's writing profile. The engine counts (`overview`'s `tags`); the app lays them out and
// puts the engine's codes into words. Honest by rule: counts only, no shares or decimals, no ranking or comparing groups
// in words, Not tagged as a grey row, trend words only from the third comparable first draft and never between rounds
// of one paper. UI v4 (design/ui-v4/BRIEF.md, approved 2026-10-31; plan §5 R10): Topics' rows by count, ties in the
// advisor's tag order, on the paper page and the Student page (its tiles: StudentTiles.swift).

/// One row of a Topics table: a tag (or Not tagged, or the All total), its counts per column, open now and where its
/// comments were written.
struct TopicsRow: Equatable, Identifiable {
    enum Kind: Equatable { case tag, untagged, total }

    var id: String
    var name: String
    var kind: Kind
    var counts: [Int]
    var open: Int
    /// The section most of its comments were written in; all of them, with their counts, in `writtenAll`.
    var writtenIn: String
    var writtenAll: String
    var help: String
}

/// The paper page's Topics (TAGS.md §6.2; UI v4, mac/UX.md §40.4; mockup `.ptab`): rows by count, ties in the
/// advisor's tag order, Not tagged (when some are) and All last; a column per round that has a comment (the oldest
/// folded into one when they do not fit); Open only when some row's open differs from its count; Mostly in. The
/// counting rules and "N of M tagged" are the All row's help tag.
struct TopicsTable: Equatable {
    var columns: [String]
    var columnHelp: [String]
    var rows: [TopicsRow]
    /// Open is shown: some row has comments closed.
    var showsOpen: Bool
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
            let names = row.writtenIn.map { (d.shortTitle($0.key, d.sectionTitle($0.key) ?? $0.key), $0.count) }
            return (names.first?.0 ?? "", names.map { "\($0.0) \($0.1)" }.joined(separator: " · "))
        }
        var rows: [TopicsRow] = []
        // by count, ties in the advisor's order (`sorted` gives it; the sort is stable)
        let ids = c.sorted(Array(t.byTag.keys)).filter { (t.byTag[$0]?.comments ?? 0) > 0 }
        let ordered = ids.enumerated().sorted { a, b in
            let x = t.byTag[a.element]?.comments ?? 0, y = t.byTag[b.element]?.comments ?? 0
            return x != y ? x > y : a.offset < b.offset
        }.map(\.element)
        for id in ordered {
            guard let row = t.byTag[id] else { continue }
            let w = written(row)
            rows.append(TopicsRow(id: id, name: c.name(id), kind: .tag, counts: per { $0.byTag[id] ?? 0 }, open: row.open,
                                  writtenIn: w.0, writtenAll: w.1, help: c.tag(id).map(TagText.help) ?? "A tag from another Mac’s list"))
        }
        if t.untagged.comments > 0 {  // every comment tagged: no row of "–" (the All row's help says so)
            let w = written(t.untagged)
            rows.append(TopicsRow(id: TagCatalog.untagged, name: "Not tagged", kind: .untagged, counts: per { $0.untagged },
                                  open: t.untagged.open, writtenIn: w.0, writtenAll: w.1, help: "Comments without a tag yet"))
        }
        var note = "Counts of comments, each in the round you wrote it. A comment with two tags is in both rows; All and "
            + "Open count it once. Later rounds look only at what changed, so fewer new comments there is no trend."
        if let l = d.latest, !l.isClosed, (rounds.last?.new ?? 0) == 0, rounds.last?.n == l.n {
            note += " Round \(l.n) has no new comments yet."
        }
        rows.append(TopicsRow(id: "all", name: "All", kind: .total, counts: per { $0.new }, open: t.open, writtenIn: "",
                              writtenAll: "", help: "\(t.tagged) of \(t.comments) tagged. " + note))
        // a round column only where some count is not 0
        let keep = columns.indices.filter { i in rows.contains { $0.counts[i] > 0 } }
        for i in rows.indices { rows[i].counts = keep.map { rows[i].counts[$0] } }
        // Open only when some row has closed comments: its open differs from its count
        func total(_ r: TopicsRow) -> Int {
            r.kind == .tag ? t.byTag[r.id]?.comments ?? 0 : r.kind == .untagged ? t.untagged.comments : t.comments
        }
        let showsOpen = rows.contains { $0.open != total($0) }
        return TopicsTable(columns: keep.map { columns[$0] }, columnHelp: keep.map { help[$0] }, rows: rows, showsOpen: showsOpen,
                           tagged: t.tagged, comments: t.comments, note: note)
    }
}

/// A count with its short bar (TAGS.md §6.2): one scale a table, at most 30 pt, 5 pt high and round; 1 a 6 pt capsule;
/// none "–". The bars are the ramp's `ink`: they count comments, as the map's steps do.
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
                    Capsule().fill(MapInk(dark: scheme == .dark).color(.ink))
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

/// The paper page's Topics, under the map's Key (TAGS.md §6.2; UI v4, mac/UX.md §40.4): an eyebrow and the table at
/// the full width. A click on a row follows that tag (the map's numbers stay; the cells without it step back), again
/// on the row followed shows the whole paper again. Tag Comments… is in the toolbar's More menu.
struct TopicsView: View {
    let model: AppModel
    @ObservedObject var overview: OverviewModel
    @ObservedObject var tags: TagModel
    let width: CGFloat

    var body: some View {
        if let d = overview.data, let t = d.tags, t.tagged > 0 {
            let table = TopicsTable.make(t, data: d, catalog: tags.catalog,
                                         maxColumns: max(3, Int((width - TopicsGrid.nameWidth - TopicsGrid.gap - 200) / TopicsGrid.countWidth) - 1))
            let followed: String? = { if case .tag(let id)? = overview.selection { return id } else { return nil } }()
            VStack(alignment: .leading, spacing: 0) {
                Text("Topics").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.secondary)
                    .padding(.top, 32).padding(.bottom, 8)
                TopicsGrid(table: table, followed: followed, follow: { id in
                    model.overviewClicked(id == followed ? nil : .tag(id))
                })
            }
            .contentShape(Rectangle())
            .onTapGesture {}  // its own space keeps what is followed
        }
    }
}

/// The Topics table (mockup `.ptab`): columns 200 | 88 a round (and Open) | 32 | Mostly in, rows of 32 pt on hairlines
/// under a 24 pt head; each row follows its tag when clicked, the row followed on the accent's tint, the pointer's on
/// the hover fill. "–" for none, in the tertiary ink.
struct TopicsGrid: View {
    let table: TopicsTable
    let followed: String?
    let follow: (String) -> Void
    @State private var hovered: String?

    static let nameWidth: CGFloat = 200, countWidth: CGFloat = 88, gap: CGFloat = 32

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: Self.nameWidth, height: 1)
                ForEach(Array(table.columns.enumerated()), id: \.offset) { i, c in
                    Text(c).lineLimit(1).frame(width: Self.countWidth, alignment: .trailing).help(table.columnHelp[i])
                }
                if table.showsOpen {
                    Text("Open").frame(width: Self.countWidth, alignment: .trailing)
                        .help("Comments with this tag still open now, each once")
                }
                Text("Mostly in").padding(.leading, Self.gap).help("The section most of them were written in")
                Spacer(minLength: 0)
            }
            .font(TypeScale.callout).foregroundStyle(Ink.secondary)
            .frame(height: 24)
            hairline
            ForEach(table.rows) { r in
                row(r)
                if r.kind != .total { hairline }
            }
        }
        .font(TypeScale.body)
    }

    private var hairline: some View { Rectangle().fill(Color(nsColor: Palette.rule)).frame(height: 1) }

    private func figure(_ v: Int, bold: Bool, zero: Bool) -> some View {
        Text(v > 0 || zero ? "\(v)" : "–").monospacedDigit().fontWeight(bold ? .semibold : .regular)
            .foregroundStyle(v > 0 || zero ? Ink.label : Ink.tertiary)
            .frame(width: Self.countWidth, alignment: .trailing)
    }

    private func row(_ r: TopicsRow) -> some View {
        let on = followed == r.id
        let total = r.kind == .total
        return HStack(spacing: 0) {
            Text(r.name).fontWeight(total ? .semibold : on ? .medium : .regular)
                .foregroundStyle(r.kind == .untagged ? Ink.secondary : on ? Ink.accentText : Ink.label)
                .lineLimit(1)
                .frame(width: Self.nameWidth, alignment: .leading)
                .help(r.help)
            ForEach(Array(r.counts.enumerated()), id: \.offset) { _, v in figure(v, bold: total, zero: total) }
            if table.showsOpen { figure(r.open, bold: total, zero: total) }
            Text(r.writtenIn).foregroundStyle(Ink.secondary).lineLimit(1).truncationMode(.tail).help(r.writtenAll)
                .padding(.leading, Self.gap)
            Spacer(minLength: 0)
        }
        .frame(height: 32)
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

/// First drafts (TAGS.md §6.1 T6 with the critique's fix; UI v4 a tile of the student page, shown when it says more
/// than Topics): each paper's Round 1 with its pages, the counts, and a Trend word only from the third comparable first
/// draft of similar length, its numbers beside it.
struct FirstDraftsTable: View {
    let t: StudentTags
    let catalog: TagCatalog
    let titles: [String: String]

    var body: some View {
        let firsts = t.rounds.filter(\.first)
        let ids = catalog.sorted(Array(t.byTag.keys)).filter { id in id != "praise" && firsts.contains { ($0.byTag[id] ?? 0) > 0 } }
        let skipped = Dictionary(t.firstDrafts.skipped.map { ($0.path, $0.why) }, uniquingKeysWith: { a, _ in a })
        Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 0) {
            GridRow {
                Text("").gridColumnAlignment(.leading)
                ForEach(Array(firsts.enumerated()), id: \.offset) { _, r in
                    Text(ShortTitle.of(titles[r.path] ?? "") + (r.pages.map { " · \($0) pp" } ?? ""))
                        .font(TypeScale.callout).foregroundStyle(Ink.secondary).lineLimit(1)
                        .help((titles[r.path] ?? "") + (skipped[r.path].map { " · not compared: " + ProfileText.whyHelp($0) } ?? ""))
                }
                Text("Trend").font(TypeScale.callout).foregroundStyle(Ink.secondary).gridColumnAlignment(.leading)
            }
            .padding(.bottom, 4)
            ForEach(ids, id: \.self) { id in
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    Text(catalog.name(id)).foregroundStyle(Ink.label2).lineLimit(1)
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
                .frame(height: 28)
            }
        }
        .font(TypeScale.body)
    }
}

/// How comments closed, by topic (TAGS.md §6.3; UI v4 Closing's Show by Topic, in a popover): each tag's comments
/// closed after 1, 2 or 3+ rounds you answered in, open, followed up; rounds you left open count against nobody; a
/// reopened comment is open until closed again (Help says so).
struct ClosedByTopicTable: View {
    let t: StudentTags
    let catalog: TagCatalog

    var body: some View {
        let ids = catalog.sorted(Array(t.byTag.keys)).filter { $0 != "praise" && (t.byTag[$0]?.comments ?? 0) > 0 }
        let most = ids.compactMap { t.byTag[$0].map { max($0.one, $0.two, $0.three) } }.max() ?? 1
        let revived = ids.reduce(0) { $0 + (t.byTag[$1]?.revived ?? 0) }
        VStack(alignment: .leading, spacing: 10) {
            Text("Closing by topic").font(TypeScale.body.weight(.semibold))
                .help(ifAny: revived > 0 ? "\(count(revived, "comment")) you reopened \(revived == 1 ? "counts" : "count") as open until closed again" : nil)
            Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 0) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    ForEach(["1 round", "2", "3+", "open", "followed up"], id: \.self) { h in
                        Text(h).font(TypeScale.callout).foregroundStyle(Ink.secondary).lineLimit(1)
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
            .font(TypeScale.body)
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

/// In a popover on a Topics row (UI v4) while its tag is picked, and under ★ Well done: its comments in each paper, a line each (its colour, id, your
/// words, where it was written and what became of it); a click on a line opens Review at that comment, in the round it
/// is last shown in (Not tagged's Tag Comments… is the Topics tile's menu).
struct StudentTagPanel: View {
    let model: AppModel
    let list: StudentTagList
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(list.title).font(TypeScale.body.weight(.semibold)).lineLimit(1).fixedSize()
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
            ringText(l.status).font(.system(size: 12)).foregroundStyle(Ink.secondary).lineLimit(1).fixedSize()
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
