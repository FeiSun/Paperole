import AppKit
import SwiftUI

/// The column's words (design/review-page/BRIEF.md §8).
enum LaneText {
    static func matches(_ n: Int) -> String { n == 1 ? "1 match" : "\(n) matches" }
    /// "p.4", "p.4–5".
    static func pages(_ ps: [Int]) -> String {
        guard let a = ps.min(), let b = ps.max() else { return "" }
        return a == b ? "p.\(a + 1)" : "p.\(a + 1)–\(b + 1)"
    }
}

/// One line of the column's window (BRIEF §5.2): the panel's own rows, so a click lands on something already read.
struct LaneRow: Equatable, Identifiable {
    enum Kind: Equatable {
        /// A comment to check, and how many edits answer it this round (" · 2 edits" from 2).
        case comment(CardModel, edits: Int)
        /// An unasked edit, waiting or handled.
        case unasked(ChangeModel)
        /// Edits that answer one comment the window does not list: the first, and how many there are in the group.
        case edits(ChangeModel, count: Int)
        /// A find match: its number, the matches' count and its line, cut so the match stays in view.
        case match(Int, of: Int, line: LaneMatchLine)
        /// An automatic check the student answered (design/checks-ui): your move, as a comment to check.
        case check(Check)
    }

    var kind: Kind
    var target: ScrollerMark.Target
    var page: Int?
    /// The page is given on the first row, and again only where it differs from the row above.
    var showsPage = true
    var id: String { StripLayout.key(target) }

    var words: String {
        let page = showsPage ? page.map { " · p.\($0 + 1)" } ?? "" : ""
        switch kind {
        case .comment(let c, let n):
            return "○ \(c.id) " + (c.stateWord ?? "") + (n >= 2 ? " · \(n) edits" : "") + (c.studentNote != nil ? " 💬" : "") + page
                + " | " + (c.firstLine.isEmpty ? c.quote ?? "" : c.firstLine)
        case .unasked(let ch):
            let word = ch.kind.word.prefix(1).uppercased() + ch.kind.word.dropFirst()
            return (ch.handled ? "✓" : "○") + " Unasked edit · " + word + (ch.place.isEmpty ? "" : " " + ch.place) + page
                + " | " + String(ch.excerpt.characters)
        case .edits(let ch, let n):
            return (ch.links.first?.id ?? "") + (n >= 2 ? " · \(n) edits" : "") + (ch.place.isEmpty ? "" : " " + ch.place)
                + (ch.checked ? " ✓" : "") + page + " | " + String(ch.excerpt.characters)
        case .match(let i, let n, let l):
            return "\(i + 1) of \(n)" + page + " | " + l.before + "[" + l.match + "]" + l.after
        case .check(let c):
            return "○ \(c.id ?? "") " + c.stateWord + (c.studentNote != nil ? " 💬" : "") + page + " | " + c.text
        }
    }
}

/// The line a match is in: the words before it (cut at the front), the match, the words after.
struct LaneMatchLine: Equatable {
    var before = ""
    var match = ""
    var after = ""

    /// Cut so the match stays in view: at most 24 characters before it, from a word's start, after "…".
    static func cut(_ line: String, match range: Range<String.Index>) -> LaneMatchLine {
        var pre = String(line[..<range.lowerBound])
        if pre.count > 24 {
            pre = String(pre.suffix(24))
            if let sp = pre.firstIndex(of: " "), pre.distance(from: pre.startIndex, to: sp) < 12 { pre = String(pre[pre.index(after: sp)...]) }
            pre = "…" + pre
        }
        return LaneMatchLine(before: pre, match: String(line[range]), after: String(line[range.upperBound...]))
    }
}

/// What a group's window lists (BRIEF §5.3): its rows in order, at most five, "+N more" for the rest with their pages
/// and the first of them (where a click on the line goes), and the row a click on the mark opens.
struct LaneRows: Equatable {
    var rows: [LaneRow] = []
    var more = 0
    var morePages = ""
    var moreTarget: ScrollerMark.Target?
    /// The row a click on the mark opens: the first; in Find the current match, else the one nearest the pointer.
    var current = 0
    static let cap = 5

    /// A window of one item gives its note two lines.
    var single: Bool { rows.count == 1 && more == 0 }
    /// Its height: 4 pt padding round 44 pt rows (60 for a single item) and a 28 pt "+N more" line (BRIEF §5.5).
    var height: CGFloat { 8 + CGFloat(rows.count) * (single ? 60 : 44) + (more > 0 ? 28 : 0) }
    var target: ScrollerMark.Target? { current < rows.count ? rows[current].target : nil }

    /// The rows of a group: `members` (item indices, top to bottom), `pointer` the pointer's y in the column (a run's
    /// rows are the five matches nearest it), `currentMatch` Find's current match. Comments to check come first, then
    /// the unasked edits that wait, then the other edits by the comment they answer (one row for each comment the
    /// window does not list; none for one it lists, whose " · N edits" counts them), then the unasked edits handled;
    /// matches in page order.
    static func make(_ members: [Int], items: [ScrollerMark], ys: [CGFloat], pointer: CGFloat?, currentMatch: Int?,
                     card: (String) -> CardModel?, change: (String) -> ChangeModel?, edits: (String) -> Int,
                     line: (Int) -> LaneMatchLine, check: (String) -> Check? = { _ in nil }) -> LaneRows {
        var out = LaneRows()
        var rows: [LaneRow] = []
        var rest: [(target: ScrollerMark.Target, page: Int)] = []
        if members.allSatisfy({ items[$0].kind == .find }) {
            let all = members.sorted { matchIndex(items[$0]) < matchIndex(items[$1]) }
            let near = { (i: Int) in abs(ys[i] - (pointer ?? ys[i])) }
            let picked = all.count > cap ? Array(all.sorted { (near($0), $0) < (near($1), $1) }.prefix(cap)) : all
            let shown = all.filter(picked.contains)
            rows = shown.map { i in
                let n = matchIndex(items[i])
                return LaneRow(kind: .match(n, of: items.count, line: line(n)), target: items[i].target, page: items[i].page)
            }
            rest = all.filter { !picked.contains($0) }.map { (items[$0].target, items[$0].page) }
            if let c = currentMatch, let k = rows.firstIndex(where: { $0.target == .find(c) }) {
                out.current = k
            } else if pointer != nil, !shown.isEmpty {
                out.current = shown.indices.min { near(shown[$0]) < near(shown[$1]) } ?? 0
            }
        } else {
            let comments = members.filter { items[$0].kind == .toCheck }
            let listed = Set(comments.compactMap { if case .comment(let id) = items[$0].target { return id } else { return nil } })
            for i in comments {
                if case .check(let id) = items[i].target, let c = check(id) {
                    rows.append(LaneRow(kind: .check(c), target: items[i].target, page: items[i].page))
                }
                guard case .comment(let id) = items[i].target, let c = card(id) else { continue }
                rows.append(LaneRow(kind: .comment(c, edits: edits(id)), target: items[i].target, page: items[i].page))
            }
            let unasked = members.filter { items[$0].kind == .unasked }
            for i in unasked where items[i].waits {
                guard case .change(let id) = items[i].target, let ch = change(id) else { continue }
                rows.append(LaneRow(kind: .unasked(ch), target: items[i].target, page: items[i].page))
            }
            var order: [String] = [], by: [String: [Int]] = [:]
            for i in members where items[i].kind == .edit {
                let of = items[i].answers ?? ""
                if listed.contains(of) { continue }
                if by[of] == nil { order.append(of) }
                by[of, default: []].append(i)
            }
            for of in order {
                let first = by[of]![0]
                guard case .change(let id) = items[first].target, let ch = change(id) else { continue }
                rows.append(LaneRow(kind: .edits(ch, count: by[of]!.count), target: items[first].target, page: items[first].page))
            }
            for i in unasked where !items[i].waits {
                guard case .change(let id) = items[i].target, let ch = change(id) else { continue }
                rows.append(LaneRow(kind: .unasked(ch), target: items[i].target, page: items[i].page))
            }
            if rows.count > cap {
                rest = rows[cap...].map { ($0.target, $0.page ?? 0) }
                rows = Array(rows.prefix(cap))
            }
        }
        for k in rows.indices { rows[k].showsPage = k == 0 || rows[k].page != rows[k - 1].page }
        out.rows = rows
        out.more = rest.count
        out.morePages = LaneText.pages(rest.map(\.page))
        out.moreTarget = rest.first?.target
        return out
    }

    /// The rows in words, as drawn (the debug script, the tests): "○ R1-03 revised · p.1 | Typo: distillation.", and
    /// "+2 more · p.4–5".
    var words: [String] {
        rows.map(\.words) + (more > 0 ? ["+\(more) more · \(morePages)"] : [])
    }

    private static func matchIndex(_ m: ScrollerMark) -> Int { if case .find(let i) = m.target { return i } else { return 0 } }

    /// The window's frame in the PDF view, y down from its top (BRIEF §5.5): 300 pt wide, its right edge 6 pt left of
    /// the column; its first row's first line level with the group's first glyph (`first`, the view's y), kept 8 pt
    /// inside the view and 8 pt under the find's button or bar (`under`), moved up near the foot.
    static func frame(height: CGFloat, first: CGFloat, view: CGSize, under: CGFloat) -> CGRect {
        let top = min(max(first - line1, max(8, under + 8)), view.height - 8 - height)
        return CGRect(x: view.width - 56 - width, y: top, width: width, height: height)
    }

    static let width: CGFloat = 300
    /// The window's top to its first line's middle: its padding, a row's inset and half the 18 pt line.
    static let line1: CGFloat = 4 + 4.5 + 9
}

/// The window's state; only the window observes it. `hot`: the line with the hover fill (a row, or `rows.count` for
/// "+N more"): while the pointer is on the mark, the row a click opens (two rows or more); in the window, the one under
/// the pointer.
@MainActor
final class LaneWindowModel: ObservableObject {
    @Published var rows = LaneRows()
    @Published var hot: Int?
    var onMark = true
    var go: (Int) -> Void = { _ in }
    var hover: (Bool) -> Void = { _ in }

    func show(_ r: LaneRows) {
        if rows != r { rows = r }
        if onMark { let h = r.rows.count + (r.more > 0 ? 1 : 0) >= 2 ? r.current : nil; if hot != h { hot = h } }
    }

    func point(row: Int?) {
        onMark = row == nil
        let h = row ?? (rows.rows.count + (rows.more > 0 ? 1 : 0) >= 2 ? rows.current : nil)
        if hot != h { hot = h }
    }
}

/// The column's window (BRIEF §5): the reference preview's float, opaque, no title or buttons; each row is the button.
struct LaneWindowView: View {
    @ObservedObject var model: LaneWindowModel

    var body: some View {
        let r = model.rows
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(r.rows.enumerated()), id: \.element.id) { k, row in
                LaneRowView(row: row, single: r.single)
                    .background(RoundedRectangle(cornerRadius: 6).fill(model.hot == k ? Color(nsColor: Palette.hover) : .clear))
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        if case .active = phase { NSCursor.pointingHand.set(); model.point(row: k) }
                    }
                    .onTapGesture { model.go(k) }
            }
            if r.more > 0 {
                Text("+\(r.more) more · \(r.morePages)")
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.secondary)
                    .padding(.leading, 16)
                    .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(model.hot == r.rows.count ? Color(nsColor: Palette.hover) : .clear))
                    .overlay(alignment: .top) { Rectangle().fill(Color(nsColor: Palette.rule)).frame(height: 0.5) }
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        if case .active = phase { NSCursor.pointingHand.set(); model.point(row: r.rows.count) }
                    }
                    .onTapGesture { model.go(r.rows.count) }
            }
        }
        .padding(4)
        .frame(width: LaneRows.width, height: r.height, alignment: .top)
        .onContinuousHover { phase in
            switch phase {
            case .active: model.hover(true)
            case .ended: model.point(row: nil); model.hover(false)
            }
        }
        .accessibilityHidden(true)  // its facts are the column's elements (BRIEF §3.8)
    }
}

/// A row of the window, as the panel draws it (`CompactRow`, `ChangeRow`) at the window's width.
struct LaneRowView: View {
    let row: LaneRow
    let single: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 7) {
                first
                Spacer(minLength: 4)
                if row.showsPage, let p = row.page {
                    Text("p.\(p + 1)").font(.system(size: 11)).foregroundStyle(Ink.secondary).monospacedDigit()
                }
            }
            .frame(height: 18)
            second.lineLimit(single ? 2 : 1).truncationMode(.tail).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 4.5)
        .frame(maxWidth: .infinity, minHeight: single ? 60 : 44, maxHeight: single ? 60 : 44, alignment: .topLeading)
        .foregroundStyle(Ink.label)
        .overlay(alignment: .leading) {
            if let c = bar { RoundedRectangle(cornerRadius: 1.5).fill(Color(nsColor: c)).frame(width: 3).padding(.leading, 6).padding(.vertical, 10) }
        }
    }

    private var bar: NSColor? {
        switch row.kind {
        case .comment(let c, _): return c.color.fill
        case .unasked(let ch), .edits(let ch, _): return ch.barColor
        case .match: return nil
        case .check: return Palette.checkBar
        }
    }

    /// The status sign a row lifted out of its list carries: its group header's.
    private func ring(_ waits: Bool) -> some View {
        Image(systemName: waits ? "circle" : "checkmark").font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(waits ? Color(nsColor: Palette.toCheck) : Ink.secondary)
    }

    @ViewBuilder private var first: some View {
        switch row.kind {
        case .comment(let c, let edits):
            HStack(spacing: 4) {
                Image(systemName: c.status.icon).font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color(nsColor: c.status == .notFound ? Palette.danger : Palette.toCheck))
                Text(c.id).font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(Ink.label2)
            }
            if let w = c.stateWord { StateWord(text: w + (edits >= 2 ? " · \(edits) edits" : ""), tone: c.stateTone) }
            if c.studentNote != nil { StudentNoteSign() }
            if c.unsent { UnsentTag() }
        case .unasked(let ch):
            ring(!ch.handled)
            HStack(spacing: 4) {
                Text("Unasked edit ·").font(.system(size: 12)).foregroundStyle(Ink.secondary)
                KindTag(change: ch)
            }
            .fixedSize()
            if !ch.place.isEmpty { Text(ch.place).font(.system(size: 12)).foregroundStyle(Ink.secondary).lineLimit(1) }
        case .edits(let ch, let n):
            HStack(spacing: 4) {
                ForEach(ch.links.prefix(1), id: \.id) { Chip(id: $0.id, status: $0.status, compact: true) }
                if n >= 2 { Text("· \(n) edits").font(.system(size: 12)).foregroundStyle(Ink.secondary) }
            }
            .fixedSize()
            if !ch.place.isEmpty { Text(ch.place).font(.system(size: 12)).foregroundStyle(Ink.secondary).lineLimit(1) }
            if ch.checked { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Ink.secondary) }
        case .match(let i, let n, _):
            Text("\(i + 1) of \(n)").font(.system(size: 12)).monospacedDigit().foregroundStyle(Ink.secondary)
        case .check(let c):
            HStack(spacing: 4) {
                Image(systemName: "circle").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Color(nsColor: Palette.toCheck))
                Text(c.id ?? "").font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(Ink.label2)
            }
            Text(c.stateWord).font(.system(size: 12)).foregroundStyle(Ink.secondary)
            if c.studentNote != nil { StudentNoteSign() }
        }
    }

    @ViewBuilder private var second: some View {
        switch row.kind {
        case .comment(let c, _):
            if c.firstLine.isEmpty, let q = c.quote {
                Text(q).font(.system(size: 13, design: .serif)).italic().foregroundStyle(Ink.secondary)
            } else {
                Text(c.firstLine).font(.system(size: 13))
            }
        case .unasked(let ch), .edits(let ch, _):
            Text(ch.excerpt).font(.system(size: 13, design: .serif))
        case .match(_, _, let l):
            (Text(l.before) + Text(l.match).fontWeight(.semibold) + Text(l.after)).font(.system(size: 13, design: .serif))
        case .check(let c):
            Text(c.text).font(.system(size: 13))
        }
    }
}
