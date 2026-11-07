import SwiftUI

/// A comment on several places, on its expanded card (design/comments/PLAN.md §3, 1 and 3, §6a; mac/UX.md §46): the
/// advisor's words for how the places relate, in a field under the note with one-click suggestions while it is empty,
/// then a line per place, its name and what happened there; a click shows that place, its context menu re-anchors or
/// removes it (never the comment).
struct PlacesBlock: View {
    let card: CardModel
    let actions: CardActions
    @EnvironmentObject var edit: EditState
    @State private var text = ""
    @State private var loaded = ""  // the relation the field last took from the card: only a change of it is saved
    @FocusState private var focused: Bool

    /// The suggestions under an empty field (PLAN §7 question 2).
    static let suggestions = ["does not match", "repeats", "needs evidence", "explained later", "examples: fix throughout"]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if edit.roundOpen {
                TextField("How the places relate", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .focused($focused)
                    .onSubmit { save() }
                    .help("The student reads these words at each place")
                if text.isEmpty {
                    FlowRow {
                        ForEach(Self.suggestions, id: \.self) { w in
                            Button { text = w; save() } label: {
                                Text(w).font(.system(size: 11.5)).foregroundStyle(Ink.accentText)
                                    .padding(.horizontal, 8).frame(height: 20)
                                    .background(Capsule().strokeBorder(Ink.accentText, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else if !card.relation.isEmpty {
                Text(card.relation).font(.system(size: 12)).foregroundStyle(Ink.secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(card.places) { p in line(p) }
            }
            .padding(.top, 2)
        }
        .onAppear {
            text = card.relation
            loaded = card.relation
            takeFocus()
        }
        .onChange(of: card.relation) {
            if text == loaded { text = card.relation }  // not typed over: it follows (an undo, another save)
            loaded = card.relation
        }
        .onChange(of: focused) { if !focused { save() } }
        .onDisappear { save() }  // the card closed with the field still focused
        .onChange(of: edit.relationFocus) { takeFocus() }
    }

    private func save() { if text != loaded { actions.setRelation(card.id, text) } }

    private func takeFocus() {
        guard edit.relationFocus == card.id else { return }
        edit.relationFocus = nil
        DispatchQueue.main.async { focused = true }
    }

    /// "⇄ Table 1 (p.4) · unchanged"
    private func line(_ p: PlaceLine) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.left.arrow.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Ink.secondary)
            Button(p.name) { actions.revealPlace(card.id, p.key) }
                .buttonStyle(.plain)
                .foregroundStyle(Ink.label)
                .help("Show this place in the PDF")
            Text("· " + p.state)
                .foregroundStyle(p.lost ? Color(nsColor: Palette.danger) : Ink.secondary)
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .contextMenu {
            if edit.roundOpen {
                Button(p.key == "a" ? "Re-anchor…" : "Re-anchor This Place…") { actions.reanchorPlace(card.id, p.key) }
                if p.key != "a" { Button("Remove This Place") { actions.removePlace(card.id, p.key) } }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(p.name + ", " + p.state)
    }
}
