import AppKit
import SwiftUI

/// Re-editing a comment's mark after it was made (UX.md §8, the advisor's request of 2026-10-26): a click on a new
/// comment's mark in an open round shows a toolbar by the mark, as a selection's floating toolbar shows (§7): its
/// colour swatches, its kinds (text comments), Edit Note and Delete…. The card's header has a colour dot that opens the
/// same swatches and kinds in a popover, for any comment of the open round. A swatch or kind applies at once
/// (`AppModel.setStyle`, undone with ⌘Z).

/// What the mark's toolbar shows; set by `PDFController.placeMarkBar`. Only the toolbar observes it.
@MainActor
final class MarkToolbarModel: ObservableObject {
    @Published private(set) var id = ""
    @Published private(set) var color = MarkColor.yellow
    @Published private(set) var kind = MarkKind.highlight
    @Published private(set) var kinds: [MarkKind] = []
    /// Each button's frame in the toolbar (top-left origin), by a colour's or kind's name, "edit" and "delete": for
    /// --debug-script markbarclick.
    var frames: [String: CGRect] = [:]

    func show(_ c: Comment) {
        if id != c.id { id = c.id }
        if color != c.markColor { color = c.markColor }
        if kind != c.markKind { kind = c.markKind }
        let k = MarkStyleRow.kinds(carried: c.carried, kind: c.markKind)
        if kinds != k { kinds = k }
    }
}

/// The mark's toolbar's buttons.
@MainActor
struct MarkToolbarActions {
    weak var model: AppModel?
    func restyle(_ id: String, color: MarkColor?, kind: MarkKind?) { model?.setStyle(id, color: color, kind: kind) }
    /// The note opens in its card, which takes the keys; the toolbar's work is done.
    func editNote(_ id: String) {
        model?.pdf.hideMarkBar()
        model?.beginNoteEdit(id)
    }
    /// The panel's "Delete R3-02?" dialog; the toolbar goes with the mark, or stays after Cancel.
    func delete(_ id: String) { model?.requestDelete(id) }
}

/// The toolbar by a new comment's mark: swatches, kinds, Edit Note, Delete….
struct MarkToolbar: View {
    @ObservedObject var bar: MarkToolbarModel
    let actions: MarkToolbarActions
    static let space = "markToolbar"

    @MainActor
    static func hosted(model: AppModel) -> NSView {
        FloatView.holding(MarkToolbar(bar: model.pdf.markBar, actions: MarkToolbarActions(model: model)))
    }

    var body: some View {
        HStack(spacing: 6) {
            MarkStyleRow(color: bar.color, kind: bar.kind, kinds: bar.kinds,
                         frame: { bar.frames[$0] = $1 }) { c, k in actions.restyle(bar.id, color: c, kind: k) }
            Divider().frame(height: 16)
            Button("Edit Note") { actions.editNote(bar.id) }
                .buttonStyle(VerdictButtonStyle(active: false, color: .accentColor))
                .help("Edit the note in its card (Return)")
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { bar.frames["edit"] = $0 }
            Button { actions.delete(bar.id) } label: {
                Image(systemName: "trash").frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Delete \(bar.id)… (Delete)")
            .accessibilityLabel("Delete \(bar.id)…")
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { bar.frames["delete"] = $0 }
        }
        .padding(.horizontal, 7)
        .frame(height: 30)
        .coordinateSpace(name: Self.space)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(bar.id)’s mark")  // which comment the swatches, kinds and buttons act on
    }
}

/// A comment's colour swatches, the current one ringed, and the kinds it can be given, the current one in the accent
/// (UX.md §7's toolbar style): on the mark's toolbar and in the card's colour dot. A click picks at once.
struct MarkStyleRow: View {
    let color: MarkColor
    let kind: MarkKind
    let kinds: [MarkKind]
    /// Each button's frame (the mark's toolbar records them), by its colour's or kind's name.
    var frame: ((String, CGRect) -> Void)? = nil
    let pick: (_ color: MarkColor?, _ kind: MarkKind?) -> Void

    /// The kinds a comment can be given (UX.md §8): a new text comment's three; none for a box, a note at a point, or a
    /// carried comment, which changes kind only by re-anchoring.
    nonisolated static func kinds(carried: Bool, kind: MarkKind) -> [MarkKind] {
        !carried && MarkKind.textKinds.contains(kind) ? MarkKind.textKinds : []
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(MarkColor.allCases) { c in
                Swatch(color: c, selected: c == color) { pick(c, nil) }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(MarkToolbar.space)) } action: { frame?(c.rawValue, $0) }
            }
            if !kinds.isEmpty {
                Divider().frame(height: 16)
                ForEach(kinds) { k in
                    KindButton(kind: k, selected: k == kind, help: k.name) { pick(nil, k) }
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(MarkToolbar.space)) } action: { frame?(k.rawValue, $0) }
                }
            }
        }
    }
}

/// A kind's button: its symbol, the current one in the accent's text colour on a 15% accent fill (UX.md §7).
struct KindButton: View {
    let kind: MarkKind
    let selected: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: kind.symbol).frame(width: 20, height: 20)
                .foregroundStyle(selected ? Ink.accentText : Color.primary)
                .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Color.accentColor.opacity(0.15) : .clear))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(kind.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The card header's colour dot (UX.md §2, §8), in an open round: the mark's colour; a click shows its swatches and
/// kinds in a popover, which a pick closes.
struct ColourDot: View {
    let card: CardModel
    let actions: CardActions
    @EnvironmentObject var edit: EditState

    var body: some View {
        let kinds = MarkStyleRow.kinds(carried: card.carried, kind: card.kind)
        Button { actions.toggleSwatches(card.id) } label: {
            Circle().fill(Color(nsColor: card.color.fill))
                .overlay(Circle().strokeBorder(Color(nsColor: card.color.ink).opacity(0.6), lineWidth: 0.5))
                .frame(width: 10, height: 10)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(kinds.isEmpty ? "The mark’s colour" : "The mark’s colour and kind")
        .accessibilityLabel("Mark colour: \(card.color.name)")
        .popover(isPresented: Binding(get: { edit.swatches == card.id }, set: { if !$0 && edit.swatches == card.id { edit.swatches = nil } }),
                 arrowEdge: .bottom) {
            MarkStyleRow(color: card.color, kind: card.kind, kinds: kinds) { c, k in actions.restyle(card.id, color: c, kind: k) }
                .padding(.horizontal, 10)
                .frame(height: 34)
        }
    }
}

/// Where a float goes over the PDF view (`showToolbar`, `placeMarkBar`): centred 8 pt above the topmost of `lines`, or
/// 8 pt below the lowest when there is no room above under `top`; kept 8 pt inside the view's `width` and `top`. View
/// coordinates, y up.
enum FloatPlace {
    static func origin(size: CGSize, lines: [CGRect], width: CGFloat, top: CGFloat) -> CGPoint? {
        guard let first = lines.max(by: { $0.maxY < $1.maxY }), let last = lines.min(by: { $0.minY < $1.minY }) else { return nil }
        var y = first.maxY + 8
        if top - first.maxY < size.height + 8 + 8 { y = last.minY - 8 - size.height }
        var x = first.midX - size.width / 2
        x = min(max(x, 8), width - 8 - size.width)
        y = min(max(y, 8), top - 8 - size.height)
        return CGPoint(x: x, y: y)
    }
}

extension FloatView {
    /// `root` in a hosting view filling the floats' ground; the caller adds it over its view.
    @MainActor
    static func holding<V: View>(_ root: V) -> FloatView {
        let effect = FloatView()
        let host = NSHostingView(rootView: root)
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor), host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor), host.bottomAnchor.constraint(equalTo: effect.bottomAnchor)])
        return effect
    }
}
