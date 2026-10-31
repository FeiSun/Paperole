import SwiftUI

// UI v4's shared figures (design/ui-v4/BRIEF.md §3; mockup `tc`, `tcCol`, `resp`, `figs`; mac/UX.md §40.4): one form of
// each wherever a paper's figures show (the paper page's header, and later the student page's cards, the board and
// Your Move).

/// The to-check figure (mockup `tc`): the ring, the count semibold, then "comments + **2** edits" at 13 in the secondary
/// ink with the edits' count in label2; an optional tail (" to check").
struct ToCheckFigure: View {
    let comments: Int
    let edits: Int
    var fill: Double = 0
    var size: CGFloat = 17
    var tail: String?
    /// "6 of 16 answered so far", after the help (the number behind the ring's fill).
    var answered: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            StatusGlyphView(.ring(fill), text: size)
            Text("\(comments > 0 ? comments : edits)").font(.system(size: size, weight: .semibold)).monospacedDigit()
            Self.nouns(comments, edits, tail: tail).font(.system(size: 13)).foregroundStyle(Ink.secondary)
        }
        .lineLimit(1)
        .fixedSize()
        .help(Self.help(comments, edits) + (answered.map { " · " + $0 } ?? ""))
    }

    /// "comments + **2** edits", the edits' count in label2; "edits" alone without comments.
    static func nouns(_ c: Int, _ e: Int, tail: String? = nil) -> Text {
        var t = Text(c > 0 ? (c == 1 ? "comment" : "comments") : (e == 1 ? "edit" : "edits"))
        if c > 0 && e > 0 {
            t = t + Text(" + ") + Text("\(e)").foregroundColor(Ink.label2) + Text(e == 1 ? " edit" : " edits")
        }
        return tail.map { t + Text(" " + $0) } ?? t
    }

    /// "14 comments · 2 unasked edits to check" (BRIEF §3).
    static func help(_ c: Int, _ e: Int) -> String {
        [c > 0 ? count(c, "comment") : nil, e > 0 ? count(e, "unasked edit") : nil].compactMap { $0 }.joined(separator: " · ") + " to check"
    }
}

/// The to-check figure in a table's column (mockup `tcCol`): the ring and count right-aligned in a 46 pt box, so the
/// nouns after it start on one line.
struct ToCheckColumn: View {
    let comments: Int
    let edits: Int
    var fill: Double = 0

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                StatusGlyphView(.ring(fill), text: 17)
                Text("\(comments > 0 ? comments : edits)").font(TypeScale.title2).monospacedDigit()
            }
            .frame(width: 46, alignment: .trailing)
            ToCheckFigure.nouns(comments, edits).font(.system(size: 13)).foregroundStyle(Ink.secondary)
        }
        .lineLimit(1)
        .help(ToCheckFigure.help(comments, edits))
    }
}

/// The response bar (mockup `resp`; plan D4): what the student did with the carried comments, an 8 pt bar of segments
/// 2 pt apart (revised in ink, explained s3, unchanged s2 with a hairline, not asked s1), labelled under it.
struct ResponseBar: View {
    let response: Response
    /// The round that came in, for the not asked segment's help tag.
    var round: Int?
    @Environment(\.colorScheme) private var scheme

    static let roles: [MapRole] = [.ink, .s3, .s2, .s1]

    var body: some View {
        let ink = MapInk(dark: scheme == .dark), segs = response.segments
        VStack(alignment: .leading, spacing: 8) {
            Canvas { ctx, size in
                let shown = segs.enumerated().filter { $0.element.count > 0 }
                let total = CGFloat(shown.map(\.element.count).reduce(0, +))
                guard total > 0 else { return }
                let room = size.width - 2 * CGFloat(shown.count - 1)
                var x: CGFloat = 0
                for (i, s) in shown {
                    let r = CGRect(x: x, y: 0, width: room * CGFloat(s.count) / total, height: size.height)
                    let p = Path(roundedRect: r, cornerRadius: 2)
                    ctx.fill(p, with: .color(ink.color(Self.roles[i])))
                    if i == 2 { ctx.stroke(Path(roundedRect: r.insetBy(dx: 0.25, dy: 0.25), cornerRadius: 2), with: .color(ink.color(.rule)), lineWidth: 0.5) }
                    x = r.maxX + 2
                }
            }
            .frame(height: 8)
            // one line, 16 apart, else 10; else two a line (four labels in the paper header's 300 pt)
            ViewThatFits(in: .horizontal) {
                labels(ink, spacing: 16)
                labels(ink, spacing: 10)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    ForEach(Array(stride(from: 0, to: segs.count, by: 2)), id: \.self) { i in
                        GridRow { ForEach(i..<min(i + 2, segs.count), id: \.self) { j in label(ink, j, segs[j]) } }
                    }
                }
                .lineLimit(1)
                .fixedSize()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(response.words)
    }

    private func labels(_ ink: MapInk, spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            ForEach(Array(response.segments.enumerated()), id: \.offset) { i, s in label(ink, i, s) }
        }
        .lineLimit(1)
        .fixedSize()
    }

    private func label(_ ink: MapInk, _ i: Int, _ s: (count: Int, word: String)) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            RoundedRectangle(cornerRadius: 2).fill(ink.color(Self.roles[i])).frame(width: 10, height: 10)
                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(i == 2 ? ink.color(.rule) : .clear, lineWidth: 0.5))
                .alignmentGuide(.firstTextBaseline) { d in d.height - 1 }
                .padding(.trailing, 6)
            Text("\(s.count)").font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(Ink.label)
                .padding(.trailing, 4)
            Text(s.word).font(.system(size: 12)).foregroundStyle(Ink.secondary)
        }
        .help(ifAny: i == 3 ? Self.notAskedHelp(round) : nil)
    }

    /// The not asked segment's help tag (plan §5 R3).
    static func notAskedHelp(_ round: Int?) -> String {
        "Left open in Round \(round.map { String($0 - 1) } ?? "N−1") without an answer, so the student was not asked"
    }
}

/// Aligned figures (mockup `figs`): values 17 semibold over labels 12 in the secondary ink, 16 apart with a hairline
/// between.
struct FigureColumns: View {
    let figures: [(value: String, label: String, help: String?)]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(figures.enumerated()), id: \.offset) { i, f in
                if i > 0 { Rectangle().fill(Color(nsColor: Palette.rule)).frame(width: 1).padding(.horizontal, 16) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(f.value).font(TypeScale.title2).monospacedDigit().foregroundStyle(Ink.label)
                    Text(f.label).font(TypeScale.callout).foregroundStyle(Ink.secondary)
                }
                .help(ifAny: f.help)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }
}

extension View {
    /// A help tag only when there is one: an empty tag would cover the help of the view round it (the paper header's).
    @ViewBuilder func help(ifAny text: String?) -> some View {
        if let text, !text.isEmpty { help(text) } else { self }
    }
}
