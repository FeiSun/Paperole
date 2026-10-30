import AppKit
import SwiftUI

// The tag picker and the tags on a card (design/tags/TAGS.md §2 with the critique's fixes; UX.md §24). One click turns
// a tag on or off, several or none; a chip never moves (its width is measured with the bold label it gets when on),
// "on" is the accent's tint with a check in place of the sign, so it does not rely on colour; a suggestion is a dashed
// chip in its own place; New Tag… turns into a name field where it is. The same chips in the new-comment popover, in
// the card's popover and in Tag Comments….

/// The chips' sizes (TAGS.md §2.1): 22 pt pills, 12 pt words and signs, measured with the semibold label.
enum TagChipMetrics {
    static let height: CGFloat = 22
    static let pad: CGFloat = 9
    static let signWidth: CGFloat = 14
    static let gap: CGFloat = 4
    static let spacing: CGFloat = 6

    static func width(_ name: String, signed: Bool = true) -> CGFloat {
        let w = (name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width
        return ceil(pad * 2 + (signed ? signWidth + gap : 0) + w)
    }

    /// How many rows the chips take at a width (the popover's height, tested at its width).
    static func rows(_ names: [String], width: CGFloat) -> Int {
        var rows = names.isEmpty ? 0 : 1, x: CGFloat = 0
        for n in names {
            let w = Self.width(n)
            if x > 0 && x + spacing + w > width { rows += 1; x = 0 }
            x += (x > 0 ? spacing : 0) + w
        }
        return rows
    }
}

/// A tag's sign: its SF Symbol, or the first letter of its name when it has none; in a box of one width, a wide symbol
/// set a little smaller to fit it, so the names after the signs line up (the UI audit: Grammar's "abc" sat 5 pt out).
struct TagSign: View {
    let sign: String?
    let name: String
    var size: CGFloat = 12

    /// The box: the widest a sign may be.
    var box: CGFloat { (size * 1.6).rounded() }

    var body: some View {
        Group {
            if let sign {
                Image(systemName: sign).font(.system(size: Self.fitted(sign, size: size - 0.5, box: box)))
            } else {
                Text(String(name.prefix(1)).uppercased()).font(.system(size: size - 1.5, weight: .semibold))
            }
        }
        .frame(width: box)
    }

    nonisolated(unsafe) private static var widths: [String: CGFloat] = [:]

    /// The point size at which a symbol is at most `box` wide (at most `size`).
    static func fitted(_ sign: String, size: CGFloat, box: CGFloat) -> CGFloat {
        let w: CGFloat
        if let known = widths[sign] { w = known } else {
            let image = NSImage(systemSymbolName: sign, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
            w = image?.size.width ?? 12
            widths[sign] = w
        }
        let at = w * size / 12  // its width at `size`
        return at <= box ? size : (size * box / at * 10).rounded(.down) / 10
    }
}

/// The picker's working set: the tags on (in the order put on), the suggestions it was opened with and those taken,
/// and the New Tag… field. `original`: the tags on when it opened (the card's picker writes only a change).
@MainActor
final class TagSelection: ObservableObject {
    @Published var on: [String]
    @Published private(set) var accepted: [String] = []
    @Published var suggestions: [TagSuggestion]
    @Published var naming = false
    @Published var newName = ""
    @Published var newSign: String?
    /// One line under the chips after New Tag… found a tag of that name ("Wording was hidden: it is shown again").
    @Published var message: String?
    let original: [String]
    /// The hidden tags it shows because they were on when it opened (so they can be taken off).
    let pinned: Set<String>

    init(on: [String], suggestions: [TagSuggestion] = []) {
        self.on = on
        original = on
        pinned = Set(on)
        self.suggestions = suggestions
    }

    var changed: Bool { on != original }

    func isOn(_ id: String) -> Bool { on.contains(id) }
    func suggestion(_ id: String) -> TagSuggestion? { isOn(id) ? nil : suggestions.first { $0.id == id } }

    /// One click: on, or off again. A suggestion taken is remembered as one (`accepted`: the ledger's `by`).
    func toggle(_ id: String) {
        if let i = on.firstIndex(of: id) {
            on.remove(at: i)
            accepted.removeAll { $0 == id }
        } else {
            guard on.count < TagCatalog.maxPerComment else { return NSSound.beep() }
            on.append(id)
            if suggestions.contains(where: { $0.id == id }) && !accepted.contains(id) { accepted.append(id) }
        }
        message = nil
    }

    /// The chips in the catalogue's order: the visible tags, the hidden ones it opened with, then ids no catalogue
    /// knows (another Mac's).
    func shown(_ c: TagCatalog) -> [(id: String, name: String, sign: String?, help: String)] {
        var out = c.tags.filter { !$0.hidden || pinned.contains($0.id) }.map {
            (id: $0.id, name: $0.name, sign: $0.sign, help: TagText.help($0))
        }
        for id in on where c.tag(id) == nil && !out.contains(where: { $0.id == id }) {
            out.append((id: id, name: c.name(id), sign: nil, help: "A tag from another Mac’s list"))
        }
        return out
    }

    /// Return in the New Tag… field: the tag is added (or the one of that name found) and turned on for this comment;
    /// the field becomes New Tag… again. Nothing for an empty name.
    func commitNew(_ tags: TagModel) {
        let name = newName
        let wasHidden = tags.catalog.named(name)?.hidden == true
        guard let (id, reused) = tags.add(name: name, sign: newSign) else { return }
        if !isOn(id) { toggle(id) }
        naming = false
        newName = ""
        newSign = nil
        let shown = tags.catalog.name(id)
        message = reused ? (wasHidden ? "\(shown) was hidden from the picker: it is shown again." : "\(shown) is already one of your tags.") : nil
    }

    func cancelNew() {
        naming = false
        newName = ""
        newSign = nil
    }
}

/// Words about tags shared by the picker, the cards and Settings.
enum TagText {
    /// A tag's help tag: "Logic & claims · Thinking", then its definition.
    static func help(_ t: WritingTag) -> String {
        t.name + " · " + t.group.title + (t.hint.isEmpty ? "" : "\n" + t.hint)
    }

    static let privacy = "Only you see tags: they never go into the email or final.pdf."
}

/// One chip (TAGS.md §2.1): off, a neutral fill; on, the accent's tint, its words in the accent's text colour and
/// semibold, a check for the sign; suggested, a dashed outline in the accent's text colour. Its width is fixed.
struct TagChip: View {
    let name: String
    let sign: String?
    let on: Bool
    var suggested: String?
    let help: String
    let action: () -> Void

    var body: some View {
        let accent = Ink.accentText
        Button(action: action) {
            HStack(spacing: TagChipMetrics.gap) {
                Group {
                    if on { Image(systemName: "checkmark").font(.system(size: 10.5, weight: .bold)) } else { TagSign(sign: sign, name: name) }
                }
                .frame(width: TagChipMetrics.signWidth)
                Text(name).font(.system(size: 12, weight: on ? .semibold : .regular)).lineLimit(1)
            }
            .padding(.horizontal, TagChipMetrics.pad)
            .frame(width: TagChipMetrics.width(name), height: TagChipMetrics.height, alignment: .leading)
            .foregroundStyle(on || suggested != nil ? accent : Ink.label)
            .background {
                if on {
                    Capsule().fill(Color(nsColor: TagInk.on))
                } else if suggested != nil {
                    Capsule().strokeBorder(accent, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                } else {
                    Capsule().fill(Color(nsColor: TagInk.off))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(suggested.map { $0 + ". Click to tag it so.\n" + help } ?? help)
        .accessibilityLabel(name)
        .accessibilityValue(on ? "on" : suggested != nil ? "suggested" : "off")
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

/// The chips' fills (TAGS.md §2.1): off a quiet neutral (6% ink, 7.5% white in Dark Mode); on the accent at 15%
/// (22% in Dark Mode). No tag has a colour of its own; amber, red and the mark colours are never used for them.
enum TagInk {
    static let off = Palette.pair(NSColor(white: 0, alpha: 0.06), NSColor(white: 1, alpha: 0.075))
    static let on = Palette.pair(NSColor(hex: Palette.sage.light).withAlphaComponent(0.15),
                                 NSColor(hex: Palette.sage.dark).withAlphaComponent(0.22))
}

/// The chips in rows at the width given; New Tag… and the trailing buttons under them.
struct TagPicker<Trailing: View>: View {
    @ObservedObject var tags: TagModel
    @ObservedObject var selection: TagSelection
    let width: CGFloat
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WrapLayout(spacing: TagChipMetrics.spacing) {
                ForEach(selection.shown(tags.catalog), id: \.id) { t in
                    TagChip(name: t.name, sign: t.sign, on: selection.isOn(t.id), suggested: selection.suggestion(t.id)?.reason,
                            help: t.help) { selection.toggle(t.id) }
                }
            }
            .frame(width: width, alignment: .leading)
            .help(TagText.privacy)
            if let m = selection.message {
                Text(m).font(.system(size: 11)).foregroundStyle(Ink.secondary)
            }
            HStack(spacing: 10) {
                NewTagControl(tags: tags, selection: selection)
                Spacer(minLength: 8)
                trailing
            }
            .frame(width: width)
        }
    }
}

/// New Tag… (TAGS.md §2.3): a link that becomes a name field where it is, with a sign to pick (optional). Return adds
/// the tag and turns it on (while an input method has marked text, Return is the input method's); Esc closes only the
/// field. A name that is already a tag's (case aside) turns that tag on, shown again if it was hidden.
struct NewTagControl: View {
    @ObservedObject var tags: TagModel
    @ObservedObject var selection: TagSelection
    @FocusState private var focused: Bool

    var body: some View {
        if selection.naming {
            HStack(spacing: 6) {
                Menu {
                    Button("No Sign") { selection.newSign = nil }
                    Divider()
                    ForEach(tags.catalog.freeSigns(), id: \.self) { s in
                        Button { selection.newSign = s } label: { Label(TagCatalog.signName(s), systemImage: s) }
                    }
                } label: {
                    Group {
                        if let s = selection.newSign { Image(systemName: s) } else { Image(systemName: "circle.dashed") }
                    }
                    .font(.system(size: 12))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("A sign for the new tag (optional)")
                TextField("New tag", text: $selection.newName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(width: 170)
                    .focused($focused)
                    .onSubmit { selection.commitNew(tags) }
                    .onExitCommand { selection.cancelNew() }
                    .help("Return adds the tag and turns it on for this comment; Esc closes the field")
                    .onAppear { focused = true }
            }
        } else {
            Button { selection.naming = true } label: {
                HStack(spacing: 4) { Image(systemName: "plus").font(.system(size: 10.5, weight: .semibold)); Text("New Tag…") }
            }
            .buttonStyle(LinkStyle())
            .font(.system(size: 12))
            .help("Add a tag of your own and turn it on for this comment")
        }
    }
}

/// The tags on a card (TAGS.md §2.2 with the critique's fix: they are secondary in Review, so words with their
/// signs in the secondary colour, not pills), then + (or "+ Tag" with none), which opens the picker; with none, a
/// suggestion first as a dashed chip, taken with one click.
struct CardTagRow: View {
    let card: CardModel
    let actions: CardActions
    @EnvironmentObject var edit: EditState

    var body: some View {
        FlowRow {
            if card.tags.isEmpty, let s = card.suggestion {
                TagChip(name: s.name, sign: s.sign, on: false, suggested: s.reason, help: s.help) {
                    actions.acceptSuggestion(card.id, s.id)
                }
            }
            ForEach(card.tags, id: \.id) { t in
                Button { actions.openTags(card.id) } label: {
                    HStack(spacing: 4) {
                        TagSign(sign: t.sign, name: t.name, size: 11.5)
                        Text(t.name).font(.system(size: 12))
                    }
                    .foregroundStyle(Ink.secondary)
                }
                .buttonStyle(.plain)
                .help(t.help)
            }
            Button { actions.openTags(card.id) } label: {
                HStack(spacing: 3) {
                    Image(systemName: "plus").font(.system(size: 10.5, weight: .semibold))
                    if card.tags.isEmpty { Text("Tag").font(.system(size: 12)) }
                }
                .foregroundStyle(Ink.secondary)
                .frame(minWidth: 18, minHeight: 18)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(card.tags.isEmpty ? "Tag this comment for your writing analysis. " + TagText.privacy
                  : "Change this comment’s tags. " + TagText.privacy)
            .accessibilityLabel(card.tags.isEmpty ? "Tag" : "Change tags")
            .popover(isPresented: Binding(get: { edit.tagging == card.id }, set: { if !$0 { actions.closeTags(card.id) } }),
                     arrowEdge: .bottom) {
                if let sel = edit.tagSelection, let tags = actions.tagModel {
                    CardTagPopover(tags: tags, selection: sel, id: card.id)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tags")
    }
}

/// The card's picker (TAGS.md §2.2): the new-comment popover's chips at the same width and places; a click turns a
/// tag on or off, and the comment's tags are written when it closes (a click outside, Esc), in one request (the
/// critique's fix: one request a click went through the engine's queue and redrew the card under the open popover).
struct CardTagPopover: View {
    @ObservedObject var tags: TagModel
    @ObservedObject var selection: TagSelection
    let id: String

    var body: some View {
        TagPicker(tags: tags, selection: selection, width: TagPickerSize.chips) {
            Text("For \(id) in every round · only you see tags")
                .font(.system(size: 11)).foregroundStyle(Ink.secondary).lineLimit(1)
        }
        .padding(14)
        .background(Color(nsColor: Palette.float))  // opaque, as the new-comment popover (the UI audit)
    }
}

/// The popovers' width (TAGS.md §2.1): the built-in tags in three rows of chips.
enum TagPickerSize {
    static let chips: CGFloat = 416
    static let popover: CGFloat = chips + 28
}
