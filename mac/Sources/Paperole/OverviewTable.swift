import AppKit
import SwiftUI

/// The paper map as a table (OVERVIEW-v2 §7 "表格视图"): the same numbers in rows and columns, for whoever reads a grid
/// more easily than a drawing, and for VoiceOver. A row per first-level section (in the paper's order, a section that
/// left it where it last was), a column per round, oldest first: each cell the map's count and shade, "○ 2" still to
/// check in the open round, or why the section is not there ("merged", "removed"; "…" while the round's sections are
/// not known); the last column the section's comments over all rounds, each once. Under them the readout's numbers per
/// round. Nothing in it changes with what is followed but what stands out.
struct MapTable: Equatable {
    struct Column: Equatable, Identifiable {
        var n: Int
        var dates: String
        var failed: Bool
        var id: Int { n }
    }

    struct Cell: Equatable {
        var count = 0
        var level = 0
        var toCheck = 0
        /// Not in this round: why ("merged", "removed", "…"), or "" before it was written.
        var absent: String?
        /// It holds a comment followed (a comment, or a page's comments).
        var holds = false
    }

    struct Row: Equatable, Identifiable {
        var key: String
        var title: String
        var cells: [Cell]
        var once: Int
        var id: String { key }
    }

    /// A line of the readout's numbers under the sections: one value per round.
    struct Total: Equatable, Identifiable {
        var label: String
        var values: [String]
        var bold = false
        var id: String { label }
    }

    var columns: [Column]
    var rows: [Row]
    var totals: [Total]

    /// The sections over all rounds in the paper's order: the latest round's, then each older round's that left it,
    /// before the section that came after it there (a section merged away sits over the one it went into), else after
    /// the one before it.
    static func keys(_ d: PaperOverview) -> [String] {
        var out: [String] = []
        for r in d.rounds.reversed() {
            let ks = (r.spans ?? []).map(\.section)
            for (i, k) in ks.enumerated() where !out.contains(k) {
                if let after = ks[(i + 1)...].first(where: { out.contains($0) }), let j = out.firstIndex(of: after) { out.insert(k, at: j) }
                else if let before = ks[..<i].last(where: { out.contains($0) }), let j = out.firstIndex(of: before) { out.insert(k, at: j + 1) }
                else { out.append(k) }
            }
        }
        return out
    }

    static func make(_ d: PaperOverview, selection: OverviewItem?, student: String) -> MapTable {
        let steps = MapShade.steps(d.rounds.flatMap { ($0.heat ?? []).map(\.present) })
        let scope = Scope(selection, d)
        let columns = d.rounds.map { r in Column(n: r.n, dates: OverviewText.dates(r.created, r.isClosed ? r.closedAt : nil), failed: r.failed) }
        var rows: [Row] = []
        for key in keys(d) {
            var cells: [Cell] = []
            var seen = false
            for r in d.rounds {
                var c = Cell()
                if r.failed {
                    c.absent = ""
                } else if !r.hasSections {
                    c.absent = "…"
                } else if r.spans?.contains(where: { $0.section == key }) == true {
                    let h = r.heat?.first { $0.section == key }
                    c.count = h?.present ?? 0
                    c.level = MapShade.level(c.count, steps)
                    c.toCheck = !r.isClosed ? h?.toCheck ?? 0 : 0
                    c.holds = scope.holds(d, key, r.n)
                    seen = true
                } else if seen {
                    // it left the paper in this round: merged into another section, or removed; nothing after
                    let m = r.match?.first { $0.from == key }
                    c.absent = m?.to != nil ? "merged" : m != nil ? "removed" : ""
                    seen = false
                } else {
                    c.absent = ""
                }
                cells.append(c)
            }
            let once = d.comments.filter { c in c.path.contains { $0.section == key && $0.state != "unplaced" } }.count
            rows.append(Row(key: key, title: d.sectionTitle(key) ?? key, cells: cells, once: once))
        }
        var totals: [Total] = []
        let first = d.rounds.first?.n
        let readouts = d.rounds.map { r in
            r.failed ? nil : MapScene.readoutColumns(d, r, first: r.n == first, columns: 3, ready: false)
        }
        func join(_ a: String, _ b: String) -> String { [a, b].filter { !$0.isEmpty && $0 != "none" }.joined(separator: " · ") }
        let unplaced = d.rounds.map { r in r.unplaced ?? MapScene.unplacedCount(d, r.n) }
        if unplaced.contains(where: { $0 > 0 }) {
            totals.append(Total(label: "Unplaced", values: unplaced.map { $0 > 0 ? "+\($0)" : "" }))
        }
        totals.append(Total(label: "Comments", values: d.rounds.indices.map { i in
            d.rounds[i].failed ? MapScene.waitWords(MapScene.waiting(d, d.rounds[i].n), counted: false) : join(readouts[i]?[0].0 ?? "", readouts[i]?[0].1 ?? "")
        }, bold: true))
        let toCheck = d.rounds.map { r in r.isClosed || r.failed ? 0 : (r.comments?.toCheck ?? 0) }
        if toCheck.contains(where: { $0 > 0 }) { totals.append(Total(label: "To check", values: toCheck.map { $0 > 0 ? "○ \($0)" : "" })) }
        totals.append(Total(label: student.isEmpty ? "Student" : student, values: readouts.map { join($0?[1].0 ?? "", $0?[1].1 ?? "") }))
        totals.append(Total(label: "You", values: readouts.map { join($0?[2].0 ?? "", $0?[2].1 ?? "") }))
        totals.append(Total(label: "Edits", values: d.rounds.map { r in
            guard r.n != first, !r.failed else { return "" }
            let e = r.edits ?? [], u = e.filter(\.unrequested).count
            return "\(e.count)" + (u > 0 ? " · \(u) nobody asked for" : "")
        }))
        totals.append(Total(label: "Words", values: d.rounds.map { r in
            guard let w = r.words else { return "" }
            if r.n == first { return w.body.map { OverviewText.grouped($0) } ?? "" }
            return w.added.map { "+\($0) −\(w.deleted ?? 0)" } ?? ""
        }))
        return MapTable(columns: columns, rows: rows, totals: totals)
    }
}

/// The table drawn: a native grid, a click on a cell follows its section in that round, on a section's name the
/// section, on a round's heading the round; a double click opens Review there; the pointer shows the map's help tags.
/// What is followed stands out as on the map: the section's row and the round's column on the accent's tint, the cells
/// holding the comments followed outlined in Sage.
struct MapTableView: View {
    let model: AppModel
    @ObservedObject var overview: OverviewModel
    let table: MapTable
    let data: PaperOverview
    let width: CGFloat
    let student: String
    @Environment(\.colorScheme) private var scheme

    private var nameWidth: CGFloat { Self.widths(width, rounds: table.columns.count).name }
    private var onceWidth: CGFloat { Self.once }
    private static let once: CGFloat = 74
    private var columnWidth: CGFloat { Self.widths(width, rounds: table.columns.count).column }
    private var gridWidth: CGFloat { Self.widths(width, rounds: table.columns.count).grid }

    /// The sections' names, each round's column and the whole grid for the overview's `width`: the names give way
    /// first to the columns (down to 100 pt), then the columns (down to 52); a grid that still does not fit (many
    /// rounds in a narrow window) is wider than the overview and scrolls sideways (the code audit: it ran past the
    /// right edge, out of reach).
    static func widths(_ width: CGFloat, rounds: Int) -> (name: CGFloat, column: CGFloat, grid: CGFloat) {
        let once = Self.once, n = CGFloat(rounds)
        let name = max(100, min(min(240, max(130, width * 0.24)), width - once - n * 52))
        let column = min(150, max(52, (width - name - once) / max(n, 1)))
        return (name, column, max(width, name + once + n * column))
    }

    var body: some View {
        if gridWidth > width + 0.5 {
            ScrollView(.horizontal) { grid }
                .frame(width: width)
        } else {
            grid
        }
    }

    private var grid: some View {
        let ink = MapInk(dark: scheme == .dark)
        return Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                Text("Section").font(.system(size: 11, weight: .medium)).foregroundStyle(Ink.secondary)
                    .frame(width: nameWidth, alignment: .leading)
                ForEach(table.columns) { c in header(c, ink) }
                Text("each once").font(.system(size: 11, weight: .medium)).foregroundStyle(Ink.secondary)
                    .frame(width: onceWidth, alignment: .trailing)
                    .help("A section’s comments over all rounds, each counted once")
            }
            .padding(.bottom, 4)
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(table.rows) { row in
                GridRow {
                    name(row)
                    ForEach(Array(row.cells.enumerated()), id: \.offset) { i, c in cell(row, table.columns[i], c, ink) }
                    Text("\(row.once)").font(.system(size: 12.5)).monospacedDigit().foregroundStyle(Ink.secondary)
                        .frame(width: onceWidth, height: 26, alignment: .trailing)
                }
                .background(followsSection(row.key) ? ink.color(.accentTint) : .clear)
            }
            Divider().gridCellUnsizedAxes(.horizontal).padding(.vertical, 4)
            ForEach(table.totals) { t in
                GridRow(alignment: .top) {
                    Text(t.label).font(.system(size: 12, weight: t.bold ? .semibold : .medium)).foregroundStyle(Ink.label2)
                        .frame(width: nameWidth, alignment: .leading)
                    ForEach(Array(t.values.enumerated()), id: \.offset) { i, v in
                        amberRings(v).font(.system(size: t.bold ? 12.5 : 11.5, weight: t.bold ? .semibold : .regular))
                            .foregroundStyle(t.bold ? Ink.label : Ink.secondary)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: columnWidth - 8, alignment: .trailing)
                            .padding(.trailing, 8)
                            .background(followsRound(table.columns[i].n) ? ink.color(.accentTint) : .clear)
                    }
                    Color.clear.frame(width: onceWidth, height: 1)
                }
                .padding(.vertical, 2)
            }
        }
        .frame(width: gridWidth, alignment: .leading)
    }

    private func followsSection(_ key: String) -> Bool {
        if case .section(let k, _)? = overview.selection { return k == key }
        return false
    }

    private func followsRound(_ n: Int) -> Bool { overview.selection == .round(n) }

    private func header(_ c: MapTable.Column, _ ink: MapInk) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(Self.roundTitle(c.n, room: columnWidth - 8)).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.label)
            Text(c.failed ? "build failed" : c.dates).font(.system(size: 11))
                .foregroundStyle(c.failed ? Color(nsColor: Palette.danger) : Ink.secondary)
        }
        .lineLimit(1)
        .frame(width: columnWidth - 8, alignment: .trailing)
        .padding(.trailing, 8).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(followsRound(c.n) ? ink.color(.accentTint) : .clear))
        .clicks({ model.overviewClicked(.round(c.n)) }, double: { model.overviewClicked(.round(c.n), double: true) })
        .overviewTip(overview.hover, key: "tround:\(c.n)") { MapHelp.lines(.round(c.n), data, student: student) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.overviewClicked(.round(c.n)) }
    }

    /// "Round 9", or "R9" in a column too narrow for it, so the round's number is never cut (review 2026-10-19:
    /// "Roun…" in every header of a nine-round paper at 960 pt).
    static func roundTitle(_ n: Int, room: CGFloat) -> String {
        let full = "Round \(n)"
        return MapFont.bodyBold.width(full) <= room ? full : "R\(n)"
    }

    private func name(_ row: MapTable.Row) -> some View {
        let at = model.stripRound.flatMap { n in data.round(n)?.spans?.contains { $0.section == row.key } == true ? n : nil }
            ?? data.rounds.last { $0.spans?.contains { $0.section == row.key } == true }?.n
        return Text(row.title).font(.system(size: 12.5, weight: followsSection(row.key) ? .semibold : .regular)).lineLimit(1)
            .truncationMode(.tail)
            .frame(width: nameWidth - 8, height: 26, alignment: .leading)
            .padding(.leading, 8)
            .clicks({ if let at { model.overviewClicked(.section(row.key, round: at)) } },
                    double: { if let at { model.overviewClicked(.section(row.key, round: at), double: true) } })
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if let at { model.overviewClicked(.section(row.key, round: at)) } }
    }

    private func cell(_ row: MapTable.Row, _ col: MapTable.Column, _ c: MapTable.Cell, _ ink: MapInk) -> some View {
        let item = OverviewItem.section(row.key, round: col.n)
        return HStack(spacing: 4) {
            Spacer(minLength: 0)
            if let a = c.absent {
                Text(a).font(.system(size: 11)).foregroundStyle(Ink.tertiary)
            } else {
                if c.toCheck > 0 {
                    HStack(spacing: 2) {
                        Circle().strokeBorder(ink.color(.attention), lineWidth: 1.3).frame(width: 6, height: 6)
                        Text("\(c.toCheck)").font(.system(size: 11, weight: .semibold))
                    }
                    .padding(.horizontal, 4).frame(height: 14)
                    .background(Capsule().fill(ink.color(.card)))
                    .overlay(Capsule().strokeBorder(ink.color(.attention), lineWidth: 0.8))
                }
                Text("\(c.count)").font(.system(size: 12.5, weight: c.count > 0 ? .semibold : .regular)).monospacedDigit()
                    .foregroundStyle(c.count > 0 ? ink.color(.number) : Ink.tertiary)
            }
        }
        .padding(.horizontal, 6)
        .frame(width: columnWidth - 4, height: 22)
        .background(RoundedRectangle(cornerRadius: 4).fill(c.absent == nil && c.count > 0 ? ink.color(.cell(c.level)) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(c.holds ? ink.color(.accent) : .clear, lineWidth: 2).padding(-1))
        .padding(2)
        .background(followsRound(col.n) ? ink.color(.accentTint) : .clear)
        .clicks({ if c.absent == nil { model.overviewClicked(item) } },
                double: { if c.absent == nil { model.overviewClicked(item, double: true) } })
        .overviewTip(overview.hover, key: "tcell:\(row.key)@\(col.n)") {
            c.absent == nil ? MapHelp.lines(.cell(row.key, round: col.n), data, student: student) : []
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(c.absent == nil ? MapSpeech.cell(data, row.key, col.n)
                            : "\(data.shortTitle(row.key, row.title)), Round \(col.n): \(c.absent == "…" ? "sections not known yet" : c.absent!.isEmpty ? "not in this round" : c.absent!)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if c.absent == nil { model.overviewClicked(item) } }
        .accessibilityAction(named: "Open in Review") { if c.absent == nil { model.overviewClicked(item, double: true) } }
    }
}
