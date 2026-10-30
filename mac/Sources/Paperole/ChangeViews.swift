import AppKit
import SwiftUI

/// The kind of a change as a sign and a word (UX.md §16; design/ui-v2 mockup §7): "Edited", "Added", in slate teal
/// when no comment asked for it; on a quiet fill, as a chip, in the expanded card's header.
struct KindTag: View {
    let change: ChangeModel
    var chip = false

    var body: some View {
        let word = change.kind.word.prefix(1).uppercased() + change.kind.word.dropFirst()
        let tag = HStack(spacing: 4) {
            Image(systemName: change.kind.symbol).font(.system(size: 9, weight: .semibold))
            Text(word)
        }
        .font(.system(size: chip ? 11 : 12, weight: chip ? .medium : .regular))
        .foregroundStyle(change.unrequested ? Color(nsColor: Palette.unrequested) : Ink.secondary)
        if chip {
            tag.padding(.leading, 6).padding(.trailing, 7).frame(height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: Palette.chipFill)))
        } else {
            tag
        }
    }
}

extension ChangeModel {
    /// The bar beside its row, and the rule beside its card's text of the shown round: slate teal when no comment
    /// asked for it, else the colour of the comment it answers.
    var barColor: NSColor { unrequested ? Palette.unrequested : (links.first?.color.fill ?? Palette.changedWords) }
    /// Its words after it, and the area of a crop: slate teal when no comment asked for it, else the changes' green.
    var ink: NSColor { unrequested ? Palette.unrequested : Palette.changedWords }
    /// Its area on an ink crop (a table's, a formula's): its colour as a tint under the ink, as its band in the PDF.
    var inkTint: NSColor {
        unrequested ? Palette.pair(NSColor(hex: 0x355F6C).withAlphaComponent(0.16), NSColor(hex: 0x9CC3CF).withAlphaComponent(0.22))
            : Palette.pair(NSColor(hex: 0x16A34A).withAlphaComponent(0.18), NSColor(hex: 0x4ADE80).withAlphaComponent(0.22))
    }
    /// The widest area of its ink crops, which share a scale (`CropView`).
    var inkWidest: CGFloat { blocks.compactMap { $0.crop.flatMap { $0.look == .ink ? CropCache.area($0)?.width : nil } }.max() ?? 0 }
}

/// A change that is not selected (UX.md §16): exactly 44 pt, flat with a 3 pt bar, as a comment row. An edit no comment
/// asked for leads with its kind; one that answers comments with their chips. Done rows are at 60%.
struct ChangeRow: View, Equatable {
    let change: ChangeModel
    @ObservedObject var look: RowLook  // the pointer over it (`PanelTable.hovered`); a change row never dims

    static func == (a: ChangeRow, b: ChangeRow) -> Bool { a.change == b.change && a.look === b.look }

    var body: some View {
        let _ = { BodyCount.row += 1 }()
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 7) {
                if change.unrequested {
                    KindTag(change: change)
                } else {
                    ForEach(change.links.prefix(2), id: \.id) { Chip(id: $0.id, status: $0.status, compact: true) }
                    if change.links.count > 2 {
                        Text("+\(change.links.count - 2)").font(.system(size: 11)).foregroundStyle(Ink.secondary)
                    }
                    if !change.notes.isEmpty { StudentNoteSign() }  // linked by the student's note
                }
                if !change.place.isEmpty {
                    Text(change.place).font(.system(size: 12)).foregroundStyle(Ink.secondary).lineLimit(1).truncationMode(.tail)
                }
                if change.unrequested {  // the comments of this round that ask about it
                    ForEach(change.asked.prefix(2), id: \.id) { Chip(id: $0.id, status: $0.status, compact: true) }
                }
                if let near = change.nearClosed.first {  // an edit in a closed comment's sentence (Reopen, TAGS.md §9.7)
                    Text("near " + near.id + (change.nearClosed.count > 1 ? " +\(change.nearClosed.count - 1)" : ""))
                        .font(.system(size: 11)).foregroundStyle(Ink.secondary).lineLimit(1).fixedSize()
                }
                Spacer(minLength: 4)
                if change.checked { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Ink.secondary) }
                Text(change.page.map { "p.\($0 + 1)" } ?? "—").font(.system(size: 11)).foregroundStyle(Ink.secondary).monospacedDigit()
            }
            .frame(height: 18)
            Text(change.excerpt).font(.system(size: 13, design: .serif)).foregroundStyle(Ink.label).lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(look.hovering ? Color(nsColor: Palette.hover) : .clear))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5).fill(Color(nsColor: change.barColor)).frame(width: 3)
                .padding(.leading, 6).padding(.vertical, 10)
        }
        .opacity(change.unrequested && change.handled || change.checked ? 0.6 : 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(change.accessibility)
        .accessibilityAddTraits(.isButton)
    }
}

/// The selected change (UX.md §16), a raised card like a comment's: its kind or the comments it answers, why it is
/// listed, then the thread, "R1 · before" and "R2 · revised", and Mark checked and Comment on it.
struct ChangeCard: View, Equatable {
    let change: ChangeModel
    let actions: CardActions
    @EnvironmentObject var edit: EditState
    @State private var showInfo = false

    static func == (a: ChangeCard, b: ChangeCard) -> Bool { a.change == b.change }

    var body: some View {
        let _ = { BodyCount.expanded += 1 }()
        VStack(alignment: .leading, spacing: 0) {
            header
            why.padding(.top, 8)
            ForEach(change.nearClosed, id: \.id) { near in NearClosedLine(near: near, actions: actions, open: edit.roundOpen).padding(.top, 6) }
            if let n = change.ignored { IgnoredNoteLine(note: n).padding(.top, 4) }
            if change.about != nil {  // what it is in words: an \input line, or formatting (the row's line)
                Text(change.excerpt).font(CardType.paper).lineSpacing(CardType.paperSpacing)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled).padding(.top, 8)
            }
            if !change.blocks.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(change.blocks.enumerated()), id: \.element.id) { i, b in
                        Railed(dot: b.revised ? .change : .hollow, rail: i < change.blocks.count - 1,
                               gap: i < change.blocks.count - 1 ? 16 : 0) {
                            VStack(alignment: .leading, spacing: 0) {
                                ChangeBlockView(block: b, change: change, showAll: edit.showAll.contains(change.id + "." + b.id),
                                                actions: actions)
                                if i == change.blocks.count - 1 { notes }
                            }
                        }
                    }
                }
                .padding(.top, 12)
            }
            if change.blocks.isEmpty { notes }
            if edit.roundOpen { buttons.padding(.top, 12) }
        }
        .fixedSize(horizontal: false, vertical: true)
        .modifier(RaisedCard())  // no bar at its edge, as a comment's card: the colour is on this round's text (POLISH §3, 10)
        .foregroundStyle(Ink.label)
        .onChange(of: change.id) { showInfo = false }
    }

    private var header: some View {
        HStack(spacing: 8) {
            KindTag(change: change, chip: true)  // the comments it answers are on the line below
            if !change.place.isEmpty {
                Text(change.place).font(.system(size: 12)).foregroundStyle(Ink.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 4)
            HStack(spacing: 10) {
                if let p = change.page {
                    Button("p.\(p + 1)") { actions.revealChange(change.id) }
                        .buttonStyle(.plain)
                        .help("Show the change in the PDF")
                }
                Button { showInfo.toggle() } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.plain)
                    .help("Where it is in the source")
                    .popover(isPresented: $showInfo, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(change.footer.isEmpty ? "Not in the source" : change.footer)
                                .font(.system(size: 12).monospaced()).textSelection(.enabled)
                            Text("Change " + change.id).font(.system(size: 12)).foregroundStyle(Ink.secondary)
                        }
                        .padding(12)
                        .frame(minWidth: 200, alignment: .leading)
                    }
            }
            .font(.system(size: 11))
            .imageScale(.large)
            .foregroundStyle(Ink.secondary)
            .fixedSize()
        }
        .frame(height: 20)
    }

    /// The student linked it to a comment with a note next to it (CONTRACT amendment "Student notes"): their words
    /// after the shown round's text, as on the comment's card (UX.md §3, §16), named by the comment when it answers
    /// several.
    private var notes: some View {
        ForEach(change.notes, id: \.id) { n in
            VStack(alignment: .leading, spacing: 0) {
                threadLabel("R\(edit.round) · student’s note" + (change.links.count > 1 ? " on \(n.id)" : ""))
                    .font(CardType.label).lineLimit(1).frame(minHeight: 16)
                // the grey bubble of the comment's card, as written, its line in the source in the footer (CARD §3.9)
                if n.text.isEmpty {
                    BareNote(place: Turn.Place(path: n.place ?? ""), id: n.id).padding(.top, 5)
                } else {
                    WordsBubble(text: n.text, place: n.place.map(Turn.Place.init(path:))).padding(.top, 5)
                }
            }
            .accessibilityElement(children: .combine)
            .padding(.top, 8)
        }
    }

    /// A comment's chip that opens its card.
    private func chip(_ link: ChangeModel.Link) -> some View {
        Button { actions.showComment(link.id) } label: { Chip(id: link.id, status: link.status) }  // a chip: it is a button
            .buttonStyle(.plain)
            .help("Show \(link.id)")
    }

    /// Why it is listed: no comment asked for it (and whether that is settled), or the comments it answers. The words
    /// and chips wrap (`FlowRow`): in one row an edit that answers four or five comments cut its chips to "R…". Each
    /// line of words is at a chip's height, so its words stay level with the chips beside it.
    @ViewBuilder private var why: some View {
        if !change.unrequested {
            FlowRow {
                Text("Answers").font(.system(size: 12.5)).foregroundStyle(Ink.secondary).frame(minHeight: 20)
                ForEach(change.links, id: \.id) { link in chip(link) }
            }
        } else if !change.asked.isEmpty {
            FlowRow {
                Text("No comment asked for this edit; you asked about it in").font(.system(size: 12.5)).foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 20)
                ForEach(change.asked, id: \.id) { link in chip(link) }
            }
        } else {
            let settled = change.checked ? " You marked it checked." : change.read ? " Its paragraphs are marked read." : ""
            Text("No comment asked for this edit." + settled)
                .font(.system(size: 12.5))
                .foregroundStyle(settled.isEmpty && edit.roundOpen ? Color(nsColor: Palette.unrequested) : Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Mark checked (V; again clears it) and Comment on it (Return), as the comment cards' answer buttons, the keys
    /// in their help tags (POLISH §6). Comment on it… on an edit that prints no words says so (AppModel.commentOnChange);
    /// either, while the engine works, says "Still loading…" (O27).
    private var buttons: some View {
        HStack(spacing: 8) {
            Button { actions.toggleChecked(change.id) } label: {
                Label(change.checked ? "Checked" : "Mark Checked", systemImage: "checkmark")
            }
            .buttonStyle(AnswerButtonStyle(style: change.checked ? .on : .plain))
            .fixedSize()
            .help(change.checked ? "Checked · click again (or press V) to clear" : "Mark checked (V): you read it and it is fine")
            Button { actions.commentOnChange(change.id) } label: { Text("Comment on it…") }
                .buttonStyle(AnswerButtonStyle(style: .plain))
                .fixedSize()
                .help("Select the change in the PDF and write a comment on it (Return)")
            Spacer(minLength: 0)
        }
    }
}

/// An edit in the sentence of a comment closed in an earlier round (TAGS.md §9.7, core to Reopen with the critique's
/// fix): "Near R1-05 · resolved in R2", and, in the open round, Reopen R1-05… (it brings the comment back as To check).
struct NearClosedLine: View {
    let near: NearClosed
    let actions: CardActions
    let open: Bool

    var body: some View {
        let how = near.verdict == "wontfix" ? "kept as is" : "resolved"
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle").font(.system(size: 11)).foregroundStyle(Ink.secondary)
            Text("Near \(near.id) · \(how) in R\(near.round)").font(.system(size: 12.5)).foregroundStyle(Ink.label2)
                .lineLimit(1)
            if open && near.revivable == true {
                Button("Reopen \(near.id)…") { actions.reopen(near.id) }
                    .buttonStyle(LinkStyle())
                    .font(.system(size: 12.5, weight: .medium))
                    .help("This edit changes the sentence of \(near.id), which you closed in Round \(near.round). Reopen brings "
                          + "it back into this round as To check, compared with its Round \(near.round) text.")
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A student's note the engine did not use, a few lines from the edit (BACKLOG O32): one secondary line under why the
/// edit is listed, the student's note sign and "Ignored note 1 line above: % R2.08 same claim…", the line as written,
/// in monospace, cut at its end; the help tag has where it is and why it was not used. Perhaps the student meant it
/// for this edit (an ID written R2.08), so the advisor can say so in a follow-up.
struct IgnoredNoteLine: View {
    let note: ChangeModel.IgnoredNote

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: StudentNoteSign.symbol).font(.system(size: 10.5))
            // the student's note sign says whose note it is; the line itself gets the room
            (Text("Ignored note \(note.whereWords): ") + Text(note.line).font(.system(size: 11.5).monospaced()))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.system(size: 12))
        .foregroundStyle(Ink.secondary)
        .help(note.place + "  " + note.line + "\n" + note.message)
        .accessibilityElement(children: .combine)
    }
}

/// One section of a change's thread (UX.md §16): its label, then the text as that round's PDF printed it beside a
/// rule (the change's words struck through in grey before it, underlined after it), or a crop. The shown round's text
/// is one size up, 14/21, beside a 3 pt rule in the change's colour (slate teal, or the colour of the comment it
/// answers), as on a comment's card (POLISH §3 row 10); the round before it 13/20 beside a 2 pt grey one. `attached`:
/// on a comment's card, under a student's note that linked it (design/ui-v2.2 CARD.md §3.7): no label, the size and
/// the rule the card gives it, and no text selection, as the whole box is its button.
struct ChangeBlockView: View {
    struct Attached {
        var now: Bool
        var rule: NSColor
    }

    let block: Block
    let change: ChangeModel
    let showAll: Bool
    let actions: CardActions
    var attached: Attached? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if attached == nil { threadLabel(block.label).font(CardType.label).lineLimit(1).frame(minHeight: 16) }
            switch block.kind {
            case .text, .source:
                let short = block.short != nil && !showAll
                let now = attached?.now ?? (block.id != "before")
                VStack(alignment: .leading, spacing: 2) {
                    Text(change.rendered[block.id + (short ? ".short" : "")] ?? AttributedString(block.full.text))
                        .font(block.kind == .source ? .system(size: 12, design: .monospaced) : now ? CardType.now : CardType.paper)
                        .lineSpacing(now ? CardType.nowSpacing : CardType.paperSpacing)
                        .fixedSize(horizontal: false, vertical: true)
                        .modifier(Selectable(on: attached == nil))
                    if block.short != nil {
                        Button(short ? "Show all" : "Show less") { actions.toggleShowAll(change.id + "." + block.id) }
                            .buttonStyle(LinkStyle()).font(CardType.label)
                    }
                }
                .padding(.leading, now ? 11 : 10)
                .overlay(alignment: .leading) {
                    Rectangle().fill(now ? Color(nsColor: attached?.rule ?? change.barColor) : Color(nsColor: Palette.rule))
                        .frame(width: now ? 3 : 2)
                }
                .padding(.top, 4)
            case .image:
                Group {
                    if let req = block.crop {
                        // a table's or formula's ink at the change's one scale (`ChangeModel.inkWidest`), its mark a tint
                        CropView(request: req, ink: change.ink, tint: change.inkTint, widest: change.inkWidest,
                                 fold: (showAll, { actions.toggleShowAll(change.id + "." + block.id) }),
                                 onTap: block.id == "now" ? { actions.revealChange(change.id) } : nil)
                    } else {
                        Text("No image of this area").font(.system(size: 11)).foregroundStyle(Ink.secondary)
                    }
                }
                .padding(.top, 4)
            case .plain:
                Text(block.full.text).font(CardType.words).foregroundStyle(Ink.secondary)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) { Rectangle().fill(Color(nsColor: Palette.rule)).frame(width: 2) }
                    .padding(.top, 4)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Text selection on, or off (where a click on the text belongs to the box around it).
private struct Selectable: ViewModifier {
    let on: Bool

    func body(content: Content) -> some View {
        if on { content.textSelection(.enabled) } else { content.textSelection(.disabled) }
    }
}
