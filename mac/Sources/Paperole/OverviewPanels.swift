import AppKit
import SwiftUI

/// The panel under the map for what the overview follows (OVERVIEW-v2 §5.1, the mockup's `panelHTML`), as a pure
/// function of the engine's overview: a section's comments, each once, and the edits nobody asked for that still wait;
/// a round's responses and words with its comments grouped by how they ended; a page's comments; a comment's words and,
/// round by round, what the student changed for it. Never the replies back and forth: they are Review's (§5.1
/// "不和审阅重复"), so a round says one word, a place and an edit's first words.
struct OverviewPanel: Equatable {
    /// A comment as a line (the mockup's `crowHTML`): its colour, id, the advisor's words, the rounds it was on the map
    /// and how it ended ("R1–R2 · ✓ resolved", "R1–R3 · kept as is", "R1–R4 · ○ to check").
    struct Line: Equatable, Identifiable {
        var id: String
        var color: String?
        var text: String
        var status: String
        /// The round its help tag speaks of: the strip's when it is there, else its last with a page.
        var round: Int
    }

    /// An edit nobody asked for: "Edit · its first words · p.4 · ○ to check".
    struct EditLine: Equatable, Identifiable {
        var id: String
        var round: Int
        var text: String
        var status: String
        var section: String?
    }

    /// A round's comments by how they ended there (the mockup's `vgrp`): "✓ Resolved · 9" and their id chips.
    struct Group: Equatable, Identifiable {
        enum Glyph: Equatable { case none, check, followUp, kept, toCheck }
        var label: String
        var glyph: Glyph
        var chips: [Chip] = []
        var edits: [EditLine] = []
        var id: String { label }
    }

    struct Chip: Equatable, Identifiable {
        var id: String
        var color: String?
    }

    /// A row of "What ⟨student⟩ changed for it": the round, where it was, the edits made for it (or the student's one
    /// word), their words, their first words, your answer.
    struct Step: Equatable, Identifiable {
        var round: Int
        var place: String
        var what: String
        var added: Int?
        var deleted: Int?
        var first: String?
        var answer: String
        var id: Int { round }
    }

    struct Detail: Equatable {
        var quote: String?
        var facts: String
        var steps: [Step]
    }

    enum Body: Equatable {
        case lines([Line], edits: [EditLine], empty: String?)
        case groups([Group])
        case comment(Detail)
    }

    enum Action: Equatable {
        case follow(OverviewItem)
        case review(OverviewItem)
        /// Reopen in Round N (TAGS.md §9.2): a comment closed in an earlier round brought back into the open round.
        case revive(String)
        /// Tag Comments… (TAGS.md §2.4): the comments not tagged yet.
        case tagComments
    }

    struct Button: Equatable {
        var title: String
        var action: Action
    }

    var title: String
    var meta: String
    var buttons: [Button]
    var body: Body

    /// The student's responses in the response bar's words (UI v4); the engine's keys are unchanged.
    static let responses = ["edited": "revised", "note_only": "explained", "untouched": "unchanged", "waiting": "not asked",
                            "moved_only": "moved only"]
}

extension OverviewPanel {
    /// The panel for `item`; nil when the data has no such thing. `strip`: the strip's round, where a comment is shown.
    static func make(_ item: OverviewItem, data d: PaperOverview, strip: Int?, student: String) -> OverviewPanel? {
        let name = student.isEmpty ? "The student" : student
        switch item {
        case .section(let key, let n): return section(key, n, d, strip: strip)
        case .round(let n): return round(n, d, student: name)
        case .page(let n, let p): return page(n, p, d, strip: strip)
        case .comment(let id): return comment(id, d, strip: strip)
        case .tag(let id): return tag(id, d, strip: strip)
        }
    }

    /// A writing tag followed (TAGS.md §6.2): its comments over all rounds, each once, how many are open and where they
    /// were written; the comments by the section they were written in, each with what became of it.
    static func tag(_ id: String, _ d: PaperOverview, strip: Int?) -> OverviewPanel {
        let cat = TagCatalog.current
        let untagged = id == TagCatalog.untagged
        let list = d.comments.filter { untagged ? $0.tags.isEmpty : $0.tags.contains(id) }
        let open = list.filter { !isClosed($0) }.count
        func written(_ c: PaperOverview.Comment) -> String? {
            let first = c.createdRound ?? c.path.first?.round ?? 0
            return c.path.first { $0.round == first }?.section
        }
        let order = Dictionary(d.sections.enumerated().map { ($0.element.key, $0.offset) }, uniquingKeysWith: { a, _ in a })
        let sorted = list.enumerated().sorted { a, b in
            (written(a.element).flatMap { order[$0] } ?? Int.max, a.offset) < (written(b.element).flatMap { order[$0] } ?? Int.max, b.offset)
        }.map(\.element)
        var places: [(String, Int)] = []
        for c in sorted {
            guard let k = written(c) else { continue }
            let name = d.shortTitle(k, d.sectionTitle(k) ?? k)
            if let i = places.firstIndex(where: { $0.0 == name }) { places[i].1 += 1 } else { places.append((name, 1)) }
        }
        var meta = "\(count(list.count, "comment")) over all rounds, each counted once · \(open) open"
        if !places.isEmpty { meta += " · written in " + places.prefix(3).map { "\($0.0) \($0.1)" }.joined(separator: " · ") }
        let lines = sorted.map { c -> Line in
            var l = line(c, d, strip: strip)
            if let k = written(c) { l.status = d.shortTitle(k, d.sectionTitle(k) ?? k) + " · " + l.status }
            if let rv = c.revived.last { l.status += " · reopened in R\(rv.round)" }
            return l
        }
        return OverviewPanel(title: cat.name(id), meta: meta, buttons: untagged && !list.isEmpty ? [Button(title: "Tag Comments…", action: .tagComments)] : [],
                             body: .lines(lines, edits: [], empty: list.isEmpty ? "No comment has this tag." : nil))
    }

    // MARK: Lines

    static func line(_ c: PaperOverview.Comment, _ d: PaperOverview, strip: Int?) -> Line {
        let first = c.createdRound ?? c.path.first?.round ?? 0
        let last = c.path.last
        let rounds = last.map { $0.round == first ? "R\(first)" : "R\(first)–R\($0.round)" } ?? "R\(first)"
        let end: String
        switch last?.answer {
        // in words after the rounds, whose last is the round it ended in ("R1–R2 · ✓ resolved"; "– R2" read as a range)
        case "resolved": end = "✓ resolved"
        case "kept": end = "kept as is"
        case "to_check": end = "○ to check"
        case "left_open": end = "left open"
        default: end = last?.state == "gone" ? "passage deleted" : "open"
        }
        return Line(id: c.id, color: c.color, text: words(c), status: rounds + " · " + end,
                    round: c.shownRound(strip: strip) ?? last?.round ?? first)
    }

    /// The advisor's words, or what the mark is when it has none.
    static func words(_ c: PaperOverview.Comment) -> String {
        if let n = c.note?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { return n }
        return "A \(c.kind ?? "highlight") with no note"
    }

    static func isClosed(_ c: PaperOverview.Comment) -> Bool { ["resolved", "kept"].contains(c.path.last?.answer ?? "") }

    static func editLine(_ e: PaperOverview.Edit, _ r: PaperOverview.Round) -> EditLine {
        let first = r.excerpts?[e.id].flatMap { $0.isEmpty ? nil : $0 }
        let text = first ?? (e.move ? "A section moved (prints no words)" : "Unasked edit")
        let status = [e.page.map { "p.\($0 + 1)" }, e.toCheck ? "○ to check" : nil].compactMap { $0 }.joined(separator: " · ")
        return EditLine(id: e.id, round: r.n, text: text, status: status, section: e.section)
    }

    /// The comments ever in a section (each once, in their order), with whether the section was renamed.
    static func section(_ key: String, _ n: Int, _ d: PaperOverview, strip: Int?) -> OverviewPanel {
        let list = d.comments.filter { c in c.path.contains { $0.section == key && $0.state != "unplaced" } }
        let open = list.filter { !isClosed($0) }.count
        let has = { (m: Int) in d.round(m)?.spans?.contains { $0.section == key } == true }
        let at = [strip, n].compactMap { $0 }.first(where: has) ?? d.rounds.last { has($0.n) }?.n ?? n
        let title = d.sectionTitle(key, round: at) ?? key
        var meta = "\(count(list.count, "comment")) over all rounds, each counted once · \(open) still open"
        // a section renamed: its name until then
        let names = d.rounds.compactMap { r in r.spans?.first { $0.section == key }.map { (r.n, d.shortTitle(key, $0.title)) } }
        if let last = names.last, let i = names.lastIndex(where: { $0.1 != last.1 }), i + 1 < names.count {
            meta += " · called \(names[i].1) until Round \(names[i + 1].0)"
        }
        var edits: [EditLine] = []
        if let l = d.latest, !l.isClosed, !l.failed {
            edits = (l.edits ?? []).filter { $0.section == key && $0.unrequested }.map { editLine($0, l) }
        }
        return OverviewPanel(title: title, meta: meta,
                             buttons: [Button(title: "Open Round \(at) at \(d.shortTitle(key, title))", action: .review(.section(key, round: at)))],
                             body: .lines(list.map { line($0, d, strip: strip) }, edits: edits,
                                          empty: list.isEmpty && edits.isEmpty ? "No comment has been on this section." : nil))
    }

    /// A round: its dates and state, the student's responses, its words and edits; its comments grouped by how they
    /// ended there (in an open round: so far), and its edits nobody asked for while it is open.
    static func round(_ n: Int, _ d: PaperOverview, student: String) -> OverviewPanel? {
        guard let r = d.round(n) else { return nil }
        var meta = [OverviewText.dates(r.created, r.isClosed ? r.closedAt : nil),
                    r.failed ? "build failed" : r.isClosed ? "closed" : "open"].filter { !$0.isEmpty }
        let c = r.comments ?? .init()
        if r.failed {
            meta.append(MapScene.waitWords(MapScene.waiting(d, n)))
        } else if n == d.rounds.first?.n {
            if let w = r.words?.body { meta.append(OverviewText.grouped(w) + " words") }
            if let p = r.build?.pages { meta.append(count(p, "page")) }
        } else {
            let resp = MapScene.responses(c)
            if !resp.isEmpty { meta.append(student + ": " + resp.joined(separator: " · ")) }
            if let w = r.words, let a = w.added { meta.append("+\(a) −\(w.deleted ?? 0) words") }
            let edits = r.edits ?? [], unasked = edits.filter(\.unrequested).count
            meta.append(count(edits.count, "edit") + (unasked > 0 ? ", \(unasked) unasked" : ""))
        }
        let inRound = d.comments.filter { $0.step(in: n) != nil }
        func chips(_ cs: [PaperOverview.Comment]) -> [Chip] { cs.map { Chip(id: $0.id, color: $0.color) } }
        var groups: [Group] = []
        let written = inRound.filter { $0.createdRound == n }
        if !written.isEmpty { groups.append(Group(label: "New in this round · \(written.count)", glyph: .none, chips: chips(written))) }
        let carried = inRound.filter { $0.createdRound != n }
        let open = !r.isClosed && !r.failed
        let kinds: [(String?, String, Group.Glyph)] = open
            ? [("to_check", "To check", .toCheck), ("resolved", "Resolved so far", .check), ("follow_up", "Followed up so far", .followUp),
               ("kept", "Kept as is so far", .kept)]
            : [("resolved", "Resolved", .check), ("follow_up", "Followed up", .followUp), ("kept", "Kept as is", .kept),
               ("left_open", "Left open", .none)]
        let known = Set(kinds.compactMap(\.0))
        for (answer, label, glyph) in kinds + [(nil, "Open", .none)] {
            let cs = carried.filter { c in
                let a = c.step(in: n)?.answer
                return answer == nil ? !known.contains(a ?? "") : a == answer
            }
            if !cs.isEmpty { groups.append(Group(label: "\(label) · \(cs.count)", glyph: glyph, chips: chips(cs))) }
        }
        if open {
            let unasked = (r.edits ?? []).filter(\.unrequested)
            if !unasked.isEmpty {
                groups.append(Group(label: "Unasked edits · \(unasked.count)", glyph: .none, edits: unasked.map { editLine($0, r) }))
            }
        }
        let title = "Open Round \(n) in Review" + (r.isClosed ? " (read-only)" : "")
        return OverviewPanel(title: "Round \(n)", meta: meta.joined(separator: " · "),
                             buttons: [Button(title: title, action: .review(.round(n)))], body: .groups(groups))
    }

    /// A page of a round: the sections on it, its comments and the edits nobody asked for on it.
    static func page(_ n: Int, _ p: Int, _ d: PaperOverview, strip: Int?) -> OverviewPanel? {
        guard let r = d.round(n) else { return nil }
        let cs = d.comments.filter { c in c.step(in: n).map { $0.page == p && $0.state != "unplaced" } ?? false }
        let edits = (r.edits ?? []).filter { $0.page == p }
        let unasked = edits.filter(\.unrequested)
        let secs = r.hasSections
            ? (r.spans ?? []).filter { $0.start < Double(p + 1) && $0.end > Double(p) }.map(\.title).joined(separator: ", ")
            : "sections not known yet"
        let meta = [secs, count(cs.count, "comment"), count(edits.count, "edit") + (unasked.isEmpty ? "" : ", \(unasked.count) unasked")]
        return OverviewPanel(title: "Page \(p + 1) · Round \(n)", meta: meta.filter { !$0.isEmpty }.joined(separator: " · "),
                             buttons: [Button(title: "Open page \(p + 1) in Review", action: .review(.page(round: n, page: p)))],
                             body: .lines(cs.map { line($0, d, strip: strip) }, edits: unasked.map { editLine($0, r) },
                                          empty: cs.isEmpty && unasked.isEmpty ? "No comments on this page in this round." : nil))
    }

    /// A comment: where it is now, its words, when it was written and how it ended, and round by round what the student
    /// changed for it (the edits attached to it, their words and first words) and your answer.
    static func comment(_ id: String, _ d: PaperOverview, strip: Int?) -> OverviewPanel? {
        guard let c = d.comment(id), let last = c.path.last else { return nil }
        let n = c.shownRound(strip: strip) ?? last.round
        let section = last.section.flatMap { d.sectionTitle($0, round: last.round) }
        let place: String
        switch last.state {
        case "unplaced": place = "not placed in Round \(last.round)"
        case "whole": place = "on the whole paper"
        case "gone": place = (last.page.map { "p.\($0 + 1): " } ?? "") + "passage deleted"
        default: place = last.page.map { "p.\($0 + 1)" } ?? "no page"
        }
        var buttons: [Button] = []
        if let s = last.section, d.round(last.round)?.spans?.contains(where: { $0.section == s }) == true, let t = section {
            buttons.append(Button(title: "Follow \(d.shortTitle(s, t))", action: .follow(.section(s, round: last.round))))
        }
        buttons.append(Button(title: "Open \(id) in Round \(n)", action: .review(.comment(id))))
        // closed in an earlier round and the open round is built: Reopen in Round N (TAGS.md §9.2)
        if c.revivable, let latest = d.latest?.n { buttons.append(Button(title: "Reopen in Round \(latest)", action: .revive(id))) }
        let written = c.createdRound ?? c.path.first?.round ?? last.round
        let date = d.round(written).flatMap { shortDate($0.created) }
        let state: String
        switch last.answer {
        case "to_check": state = "○ to check in Round \(last.round)"
        case "resolved": state = "✓ resolved in Round \(last.round)"
        case "kept": state = Status.keptAsIs.glyph + " kept as is in Round \(last.round)"
        default:
            state = last.state == "gone" ? "passage deleted in Round \(last.round)"
                : d.round(last.round)?.isClosed == false ? "open in Round \(last.round)" : "open after Round \(last.round)"
        }
        var facts = ["Written in Round \(written)" + (date.map { " (\($0))" } ?? ""), "on the map for \(count(c.path.count, "round"))", state]
        if let rv = c.revived.last { facts.append("reopened in Round \(rv.round)") }
        if !c.tags.isEmpty { facts.append(TagCatalog.current.sorted(c.tags).map { TagCatalog.current.name($0) }.joined(separator: ", ")) }
        let steps = c.path.filter { $0.round != written }.map { st -> Step in
            let r = d.round(st.round)
            let eds = (r?.edits ?? []).filter { $0.attachedTo.contains(id) }
            let a = eds.reduce(0) { $0 + ($1.added ?? 0) }, del = eds.reduce(0) { $0 + ($1.deleted ?? 0) }
            let what: String
            if st.state == "unplaced" { what = "not placed in this round" }
            else if st.state == "whole" && eds.isEmpty { what = st.response.flatMap { responses[$0] } ?? "" }
            else if st.state == "gone" { what = "passage deleted" }
            else if !eds.isEmpty { what = count(eds.count, "edit") + (a + del > 0 ? "" : " · no printed words") }
            else { what = st.response.flatMap { responses[$0] } ?? "" }  // nothing: an empty cell ("–" is Kept as is)
            let first = eds.lazy.compactMap { r?.excerpts?[$0.id] }.first { !$0.isEmpty }
            return Step(round: st.round, place: st.state == "unplaced" ? "" : st.page.map { "p.\($0 + 1)" } ?? "", what: what,
                        added: !eds.isEmpty && a + del > 0 ? a : nil, deleted: !eds.isEmpty && a + del > 0 ? del : nil,
                        first: first, answer: st.answer.flatMap { Scope.answers[$0] } ?? "")
        }
        return OverviewPanel(title: id, meta: [section, place].compactMap { $0 }.joined(separator: " · "), buttons: buttons,
                             body: .comment(Detail(quote: c.note.flatMap { $0.isEmpty ? nil : $0 }, facts: facts.joined(separator: " · "),
                                                   steps: steps)))
    }
}

// MARK: The views

/// The panel under the map (OVERVIEW-v2 §5.1): a header with the thing's name, a line of facts and its buttons (Open in
/// Review, the window's other buttons plain: the toolbar's Continue Round N stays the one Sage button), then its
/// comments as lines in two columns, a round's groups of id chips, or a comment's words and round-by-round table.
/// A click on a comment follows it, a double click opens Review at it; the pointer on one previews its path on the map.
/// A click on the panel's own space keeps what is followed.
struct OverviewPanelView: View {
    let model: AppModel
    @ObservedObject var overview: OverviewModel
    let selection: OverviewItem
    let width: CGFloat
    let student: String

    var body: some View {
        if let d = overview.data, let p = OverviewPanel.make(selection, data: d, strip: model.stripRound, student: student) {
            VStack(alignment: .leading, spacing: 10) {
                Divider()
                header(p)
                switch p.body {
                case .lines(let lines, let edits, let empty):
                    PanelLines(model: model, overview: overview, hover: overview.hover, data: d, lines: lines, edits: edits,
                               student: student, columns: width >= 820 ? 2 : 1)
                    if let empty { Text(empty).font(.system(size: 12)).foregroundStyle(Ink.secondary) }
                case .groups(let groups):
                    PanelGroups(model: model, overview: overview, hover: overview.hover, data: d, groups: groups, student: student,
                                labelWidth: width >= 700 ? 190 : 140)
                case .comment(let detail):
                    PanelComment(detail: detail, student: student)
                }
            }
            .padding(.bottom, 4)
            .contentShape(Rectangle())
            .onTapGesture {}  // the panel's own space: what is followed stays
            .accessibilityElement(children: .contain)
            .accessibilityLabel(p.title)
        }
    }

    private func header(_ p: OverviewPanel) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(p.title).font(TypeScale.body.weight(.semibold)).lineLimit(1).fixedSize()
            ringText(p.meta).font(.system(size: 12)).foregroundStyle(Ink.secondary)
                .lineLimit(1).truncationMode(.tail)
                .help(p.meta)
            Spacer(minLength: 8)
            ForEach(Array(p.buttons.enumerated()), id: \.offset) { _, b in
                Button {
                    switch b.action {
                    case .follow(let item): model.overviewClicked(item)
                    case .review(let item): model.openReview(model.reviewTarget(for: item))
                    case .revive(let id): model.revive(id)
                    case .tagComments: model.openTagComments()
                    }
                } label: {
                    // a long section title is cut, whole in the help tag
                    HStack(spacing: 5) {
                        Text(b.title).lineLimit(1).truncationMode(.tail)
                        if case .review = b.action { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)) }
                    }
                    .frame(maxWidth: 300)
                }
                .fixedSize()
                .help(b.title)
            }
        }
    }
}

/// A comment's colour bar (its mark colour; yellow by default).
private func markColor(_ name: String?) -> Color {
    Color(nsColor: (name.flatMap(MarkColor.init(name:)) ?? .yellow).fill)
}

/// The comments of a section or a page, as lines in one or two columns, and the edits nobody asked for after them.
struct PanelLines: View {
    let model: AppModel
    @ObservedObject var overview: OverviewModel
    @ObservedObject var hover: OverviewHover
    let data: PaperOverview
    let lines: [OverviewPanel.Line]
    let edits: [OverviewPanel.EditLine]
    let student: String
    let columns: Int

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 28, alignment: .leading), count: columns),
                  alignment: .leading, spacing: 4) {
            ForEach(lines) { l in line(l) }
            ForEach(edits) { e in edit(e) }
        }
    }

    private func line(_ l: OverviewPanel.Line) -> some View {
        let selected = overview.selection == .comment(l.id)
        return HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(markColor(l.color)).frame(width: 4, height: 18)
            Text(l.id).font(.system(size: 12, weight: .semibold)).monospacedDigit().frame(width: 50, alignment: .leading)
            Text(l.text).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 6)
            ringText(l.status).font(.system(size: 12)).foregroundStyle(Ink.secondary).lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .frame(minHeight: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: selected ? Palette.accentTint
            : hover.comment == l.id ? Palette.hover : .clear)))
        .clicks({ model.overviewClicked(.comment(l.id)) }, double: { model.overviewClicked(.comment(l.id), double: true) })
        .overviewTip(hover, key: "line:" + l.id, comment: selected ? nil : l.id) {
            MapHelp.lines(.comment(l.id, round: l.round), data, student: student)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(l.id): \(l.text). \(l.status.replacingOccurrences(of: "○", with: ""))")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityAction { model.overviewClicked(.comment(l.id)) }
        .accessibilityAction(named: "Open in Review") { model.overviewClicked(.comment(l.id), double: true) }
    }

    private func edit(_ e: OverviewPanel.EditLine) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: Palette.unrequested)).frame(width: 4, height: 18)
            Text("Edit").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(nsColor: Palette.unrequested))
                .frame(width: 50, alignment: .leading)
            Text(e.text).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 6)
            ringText(e.status).font(.system(size: 12)).foregroundStyle(Ink.secondary).lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .frame(minHeight: 26)
        .modifier(EditClicks(model: model, data: data, edit: e))
        .overviewTip(hover, key: "edit:" + e.id) { MapHelp.lines(.edit(e.id, round: e.round), data, student: student) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Unasked edit: \(e.text). \(e.status.replacingOccurrences(of: "○", with: ""))")
    }
}

/// An edit's line or chip: a click follows its section in its round (as its tick on the map does), a double click
/// opens Review there.
private struct EditClicks: ViewModifier {
    let model: AppModel
    let data: PaperOverview
    let edit: OverviewPanel.EditLine

    func body(content: Content) -> some View {
        let item = edit.section.flatMap { s in
            data.round(edit.round)?.spans?.contains { $0.section == s } == true ? OverviewItem.section(s, round: edit.round) : nil
        }
        return content.clicks({ if let item { model.overviewClicked(item) } },
                              double: { if let item { model.overviewClicked(item, double: true) } })
    }
}

/// A round's comments by how they ended there, as id chips (the mockup's `vgrp`).
struct PanelGroups: View {
    let model: AppModel
    @ObservedObject var overview: OverviewModel
    @ObservedObject var hover: OverviewHover
    let data: PaperOverview
    let groups: [OverviewPanel.Group]
    let student: String
    let labelWidth: CGFloat

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 8) {
            ForEach(groups) { g in
                GridRow {
                    HStack(spacing: 6) {
                        glyph(g.glyph)
                        Text(g.label)
                    }
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Ink.label2)
                    .frame(width: labelWidth, height: 22, alignment: .leading)
                    WrapLayout(spacing: 5) {
                        ForEach(g.chips) { c in chip(c) }
                        ForEach(g.edits) { e in editChip(e) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func glyph(_ g: OverviewPanel.Group.Glyph) -> some View {
        switch g {
        case .none: EmptyView()
        case .check: Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
        case .followUp: Image(systemName: "arrow.uturn.backward").font(.system(size: 11, weight: .semibold))
        case .kept: Image(systemName: Status.keptAsIs.icon).font(.system(size: 11, weight: .semibold))
        case .toCheck: Circle().strokeBorder(Color(nsColor: Palette.toCheck), lineWidth: 1.8).frame(width: 9, height: 9)
        }
    }

    private func chip(_ c: OverviewPanel.Chip) -> some View {
        let selected = overview.selection == .comment(c.id)
        let n = data.comment(c.id)?.shownRound(strip: model.stripRound) ?? 0
        return HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5).fill(markColor(c.color)).frame(width: 3, height: 12)
            Text(c.id).font(.system(size: 11.5, weight: .semibold)).monospacedDigit().foregroundStyle(Ink.label2)
        }
        .padding(.horizontal, 8).frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: selected ? Palette.accentTint : Palette.panel)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.accentColor
            : hover.comment == c.id ? Ink.secondary : Color(nsColor: Palette.rule), lineWidth: selected ? 1.5 : hover.comment == c.id ? 1 : 0.5))
        .clicks({ model.overviewClicked(.comment(c.id)) }, double: { model.overviewClicked(.comment(c.id), double: true) })
        .overviewTip(hover, key: "chip:" + c.id, comment: selected ? nil : c.id) {
            MapHelp.lines(.comment(c.id, round: n), data, student: student)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(c.id + (data.comment(c.id)?.note.map { ": " + $0 } ?? ""))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityAction { model.overviewClicked(.comment(c.id)) }
        .accessibilityAction(named: "Open in Review") { model.overviewClicked(.comment(c.id), double: true) }
    }

    private func editChip(_ e: OverviewPanel.EditLine) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5).fill(Color(nsColor: Palette.unrequested)).frame(width: 3, height: 12)
            ringText(([e.status, e.text]).filter { !$0.isEmpty }.joined(separator: " "))
                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Ink.label2).lineLimit(1)
        }
        .frame(maxWidth: 320, alignment: .leading)
        .padding(.horizontal, 8).frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: Palette.panel)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: Palette.rule), lineWidth: 0.5))
        .modifier(EditClicks(model: model, data: data, edit: e))
        .overviewTip(hover, key: "edit:" + e.id) { MapHelp.lines(.edit(e.id, round: e.round), data, student: student) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Unasked edit: \(e.text)")
    }
}

/// A comment's panel body: the advisor's note (as the card's title), when it was written and how it ended, and the table of what the
/// student changed for it, round by round.
struct PanelComment: View {
    let detail: OverviewPanel.Detail
    let student: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let q = detail.quote {
                // the advisor's note as the card's title, in SF: New York is for the paper's words (the UI audit)
                NoteTitleView(title: NoteTitle(q)).foregroundStyle(Ink.label)
                    .textSelection(.enabled)
            }
            ringText(detail.facts).font(.system(size: 12.5)).foregroundStyle(Ink.secondary)
            if !detail.steps.isEmpty { table.padding(.top, 6) }
            Text("The replies themselves are in Review, on the comment’s card.")
                .font(.system(size: 12.5)).foregroundStyle(Ink.secondary).padding(.top, 2)
        }
    }

    private var table: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
            GridRow {
                Text("What \(student.isEmpty ? "the student" : student) changed for it")
                Text("where")
                Text("edits")
                Text("first words of the change")
                Text("you").gridColumnAlignment(.trailing)
            }
            .font(.system(size: 11, weight: .medium)).foregroundStyle(Ink.secondary)
            .padding(.bottom, 6)
            ForEach(detail.steps) { s in
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    Text("Round \(s.round)").foregroundStyle(Ink.label2)
                    Text(s.place)
                    words(s)
                    Text(s.first.map { "“" + $0 + "”" } ?? "").foregroundStyle(Ink.secondary).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: 420, alignment: .leading)
                    ringText(s.answer)
                }
                .font(.system(size: 12.5))
                .padding(.vertical, 5)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: 900, alignment: .leading)
    }

    private func words(_ s: OverviewPanel.Step) -> Text {
        guard let a = s.added, let d = s.deleted else { return Text(s.what) }
        return Text(s.what + " · ") + Text("+\(a)").foregroundColor(Color(nsColor: Palette.changedWords)) + Text(" −\(d) words")
    }
}
