import AppKit
import SwiftUI

/// The grey bubble of words on a card (design/ui-v2.2 CARD.md §3.5): the advisor's and the student's alike, so who said
/// it is told by the turn's label and dot, not by colour or side. Radius 8, 8 × 12 inside, SF 13/18.
struct Bubble<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .font(CardType.words)
            .lineSpacing(CardType.wordsSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: Palette.bubble)))
    }
}

/// Words in a bubble, as written, with no quotation marks added (CARD §3.5): an earlier round's long ones cut to whole
/// sentences with "Show all · 3 more sentences" (`clamp`, until `expanded`; CARD §1.3); a student's note with its sign
/// and its line in the source in the footer, the full path in the help tag. VoiceOver reads the whole words.
struct WordsBubble: View {
    let text: String
    var clamp: Turn.Clamp? = nil
    var expanded = false
    var place: Turn.Place? = nil
    var toggle: (() -> Void)? = nil

    var body: some View {
        Bubble {
            VStack(alignment: .leading, spacing: 4) {
                Text(clamp.map { expanded ? text : $0.shown } ?? text)
                    .textSelection(.enabled)
                    .accessibilityLabel(text)
                if let clamp, let toggle {
                    HStack(spacing: 0) {
                        Button(expanded ? "Show less" : "Show all", action: toggle)
                            .buttonStyle(LinkStyle())
                            .fontWeight(.medium)
                        if !expanded && clamp.more > 0 {
                            Text(" · " + count(clamp.more, "more sentence")).foregroundStyle(Ink.secondary)
                        }
                    }
                    .font(.system(size: 12))
                }
                if let place, !place.short.isEmpty {
                    HStack(spacing: 4) {
                        Spacer(minLength: 0)
                        Image(systemName: StudentNoteSign.symbol).font(.system(size: 11))
                        Text(place.short).lineLimit(1).truncationMode(.head)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Ink.secondary)  // tertiary on the bubble is under 3:1
                    .help(place.full)
                }
            }
        }
    }
}

/// A bare `% R1-03` beside an edit (CARD §3.5): no bubble, one secondary line with the note sign and its place; the
/// help tag says what it is.
struct BareNote: View {
    let place: Turn.Place
    let id: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: StudentNoteSign.symbol)
            if !place.short.isEmpty { Text(place.short).lineLimit(1).truncationMode(.head) }
        }
        .font(.system(size: 11))
        .foregroundStyle(Ink.secondary)
        .help("A comment line, % \(id), next to this edit points at it." + (place.full.isEmpty ? "" : "\n" + place.full))
    }
}

/// The fold's line (CARD §3.8): › where a dot would be, the turns it holds ("R2 · Ouyang Mingxuan revised, you followed
/// up"), wrapping under itself when a long name needs it so no verb is cut, "Show 2" on the right. The whole line is
/// the button, with the rows' light fill under the pointer; open, it says ⌄ and Hide, and the turns it held follow it.
struct FoldLine: View {
    let label: AttributedString
    let count: Int
    let open: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label).fixedSize(horizontal: false, vertical: true).layoutPriority(1)
                Spacer(minLength: 4)
                Text(open ? "Hide" : "Show \(count)").font(.system(size: 11, weight: .medium)).foregroundStyle(Ink.secondary)
                    .fixedSize()
            }
            // 24 pt to the left, so the fill takes in the chevron in the rail's place; 6 to the right
            .padding(.leading, 24)
            .padding(.trailing, 6)
            .padding(.vertical, 3)
            .overlay(alignment: .topLeading) {  // beside the first line
                Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Ink.secondary)
                    .frame(width: 9, height: 13)  // an 11 pt line
                    .padding(.leading, 6)
                    .padding(.top, 3)
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Color(nsColor: Palette.hover) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, -24)
        .padding(.trailing, -6)
        .onHover { hover = $0 }
        .help(open ? "Fold these rounds again" : "Show the rounds in between")
        .accessibilityLabel(String(label.characters) + (open ? "" : ", \(count) turns folded"))
    }
}

/// An edit the student's note alone linked outside the commented text (`elsewhere`; CARD §3.7), as the Changes tab
/// shows it: its kind, its section and page, then its shown round's block without a label. The edit is this round's
/// text when the commented text printed nothing new (`now`: 14/21 beside a 3 pt rule in the comment's colour), else
/// 13/20. The whole box shows the edit in the PDF, as the Changes tab's p.6 does.
struct ElsewhereAttachment: View {
    let change: ChangeModel
    let now: Bool
    let color: MarkColor
    let showAll: Set<String>
    let actions: CardActions
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                KindTag(change: change, chip: true)
                if !change.place.isEmpty {
                    Text(change.place).font(.system(size: 12)).foregroundStyle(Ink.secondary).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 4)
                if let p = change.page { Text("p.\(p + 1)").font(.system(size: 11)).foregroundStyle(Ink.secondary).fixedSize() }
            }
            .frame(height: 20)
            if let b = change.shown {
                ChangeBlockView(block: b, change: change, showAll: showAll.contains(change.id + "." + b.id), actions: actions,
                                attached: .init(now: now, rule: color.fill))
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 7)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(hover ? Color(nsColor: Palette.hover) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: Palette.rule), lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { actions.revealChange(change.id) }
        .help("Show the edit in the PDF")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { actions.revealChange(change.id) }
    }
}

extension ChangeModel {
    /// The block of the shown round: "now", or the one block of a move or of words that read the same.
    var shown: Block? { blocks.last { $0.id != "before" } ?? blocks.last }
}
