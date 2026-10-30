import AppKit
import SwiftUI

/// Markers beside the scroller (design/pdf-reader/PLAN.md P1.6): ticks in a 6 pt strip at the PDF's right edge, left
/// of the scroller (a mouse's, or where an overlay scroller shows), below the find's button, showing what the page
/// shows: in an open round the comments to check in amber; while change marks are shown, the student's edits in
/// green, those no comment asked for in slate teal; while Find has a query, only its matches, in the find's grey.
/// Ticks of a kind closer than 4 pt merge. A click goes there (a step of Back), hover names it.
/// Where a tick goes is the place's share of the paper's height, so the strip is laid again when the marks or the
/// matches change, never on a scroll.
struct ScrollerMark: Equatable {
    enum Kind: Int, Comparable {
        case edit, unrequested, toCheck, find  // drawn in this order, the later on top
        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    enum Target: Equatable { case comment(String), change(String), find(Int) }

    var kind: Kind
    var fraction: Double  // 0 the paper's top, 1 its foot
    var target: Target
    var page: Int
    var label: String  // "C3 · to check"
}

/// The strip's state; only the strip observes it.
@MainActor
final class ScrollerMarks: ObservableObject {
    @Published var items: [ScrollerMark] = []
    /// The scroller's width (a mouse's, or an overlay scroller's when it shows), so the strip sits left of it.
    @Published var inset: CGFloat = 0

    struct Tick: Equatable, Identifiable {
        var kind: ScrollerMark.Kind
        var y: CGFloat
        var target: ScrollerMark.Target
        var help: String
        var id: String { "\(kind.rawValue)|\(y)" }
    }

    /// A place's share of the paper's height: the pages above it and its distance below its page's top (contract
    /// coordinates), over all the pages' heights; PDFKit's few points between pages are left out.
    nonisolated static func fraction(page: Int, top: Double, heights: [Double]) -> Double? {
        let total = heights.reduce(0, +)
        guard page >= 0, page < heights.count, total > 0 else { return nil }
        return min(max((heights[..<page].reduce(0, +) + min(max(top, 0), heights[page])) / total, 0), 1)
    }

    /// The ticks for a strip `height` high: each item's place down it; the items of a kind within 4 pt of the first of
    /// a run merge into it, which then goes to that first one and names how many there are and their pages.
    nonisolated static func ticks(_ items: [ScrollerMark], height: CGFloat) -> [Tick] {
        var out: [Tick] = []
        for kind in Set(items.map(\.kind)).sorted() {
            let mine = items.filter { $0.kind == kind }.sorted { $0.fraction < $1.fraction }
            var i = 0
            while i < mine.count {
                let y = CGFloat(mine[i].fraction) * height
                var j = i + 1
                while j < mine.count, CGFloat(mine[j].fraction) * height - y < 4 { j += 1 }
                let run = mine[i..<j]
                out.append(Tick(kind: kind, y: y, target: mine[i].target,
                                help: run.count == 1 ? mine[i].label + " · p.\(mine[i].page + 1)" : merged(Array(run))))
                i = j
            }
        }
        return out
    }

    /// "3 comments to check · p.4–5".
    nonisolated static func merged(_ run: [ScrollerMark]) -> String {
        let n = run.count, kind = run[0].kind
        let what: String
        switch kind {
        case .toCheck: what = "\(n) comments to check"
        case .edit: what = "\(n) edits"
        case .unrequested: what = "\(n) edits no comment asked for"
        case .find: what = "\(n) matches"
        }
        let first = run.map(\.page).min()! + 1, last = run.map(\.page).max()! + 1
        return what + " · " + (first == last ? "p.\(first)" : "p.\(first)–\(last)")
    }
}

struct ScrollerMarksView: View {
    @ObservedObject var marks: ScrollerMarks
    let go: (ScrollerMark.Target) -> Void

    var body: some View {
        if !marks.items.isEmpty {
            GeometryReader { g in
                ZStack(alignment: .topLeading) {
                    ForEach(ScrollerMarks.ticks(marks.items, height: g.size.height)) { t in
                        // drawn 6 by 3 pt, clicked 14 by 11 (reaching left, over the page's margin)
                        Button { go(t.target) } label: {
                            Rectangle().fill(Self.color(t.kind)).frame(width: 6, height: 3)
                                .frame(width: 14, height: 11, alignment: .trailing)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(t.help)
                        .accessibilityLabel(t.help)
                        .position(x: -1, y: t.y)
                    }
                }
            }
            .frame(width: 6)
            .padding(.top, 46)  // below the find's button (PaperView: 10 pt down, 30 pt high)
            .padding(.bottom, max(4, marks.inset))  // clear of a horizontal scroller as wide
            .padding(.trailing, marks.inset + 1)
        }
    }

    static func color(_ k: ScrollerMark.Kind) -> Color {
        switch k {
        case .toCheck: return Color(nsColor: Palette.toCheck)
        case .edit: return Color(nsColor: Palette.change)
        case .unrequested: return Color(nsColor: Palette.unrequested)
        case .find: return Color(nsColor: Palette.find.withAlphaComponent(1))  // the find's grey, solid on a thin tick
        }
    }
}
