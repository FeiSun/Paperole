import AppKit
import SwiftUI

/// A status sign and the id (POLISH §2.2, §3 rows 7 and 8; UX.md §2). On a card's header, a chip: To check outlined in
/// vermilion (near the orange mark, so its shape tells it apart; UI v4), Not found tinted red, a decided status
/// on a quiet fill with a neutral sign. In a row (`compact`), the sign and the id with no fill: the group's header says
/// whose move it is, so only Not found is coloured. Status never relies on colour alone. In a closed round (`open`
/// false) nothing is the advisor's move, so To check is neutral too.
struct Chip: View {
    let id: String
    let status: Status
    var compact = false
    var open = true
    /// A row under the To check header, arranged by status: the header states it, so no sign (design/review-page
    /// BRIEF.md E7); Not found keeps its ⚠.
    var sign = true

    var body: some View {
        let quiet = !open && status == .toCheck
        let colour = Color(nsColor: quiet ? Palette.neutral : status.color)
        if compact {  // no tooltips in rows (UX.md §10.7)
            let bad = status == .notFound
            HStack(spacing: 4) {
                if sign || bad {
                    Image(systemName: status.icon).font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(bad ? colour : Color(nsColor: Palette.neutral))
                }
                Text(id).font(.system(size: 11, weight: .medium)).monospacedDigit()
                    .foregroundStyle(bad ? colour : Ink.label2)
            }
        } else {
            let outlined = status == .toCheck && !quiet
            HStack(spacing: 4) {
                Image(systemName: status.icon).font(.system(size: 10, weight: .semibold)).foregroundStyle(colour)
                Text(id).font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(Ink.label)
            }
            .padding(.leading, 6)
            .padding(.trailing, 7)
            .frame(height: 20)
            .background {
                if outlined {
                    RoundedRectangle(cornerRadius: 5).strokeBorder(colour.opacity(0.62), lineWidth: 1)
                } else {
                    RoundedRectangle(cornerRadius: 5).fill(status == .notFound ? colour.opacity(0.085) : Color(nsColor: Palette.chipFill))
                }
            }
            .help(status.word(open: open))
        }
    }
}

/// A card that is not selected: exactly 44 pt, flat on the panel with a 3 pt bar in the mark's colour (design/ui-v2
/// PROPOSAL §3; UX.md §2). The selected card is the panel's one raised layer; while it is expanded the rows fade
/// (`RowLook`), and the pointer shows a row as it is.
struct CompactRow: View, Equatable {
    let card: CardModel
    @ObservedObject var look: RowLook
    @Environment(\.colorScheme) private var scheme

    static func == (a: CompactRow, b: CompactRow) -> Bool { a.card == b.card && a.look === b.look }

    var body: some View {
        let _ = { BodyCount.row += 1 }()
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 7) {
                Chip(id: card.id, status: card.status, compact: true, open: card.open, sign: !(card.underToCheck && card.status == .toCheck))
                if let w = card.stateWord { StateWord(text: w, tone: card.stateTone) }
                if card.studentNote != nil { StudentNoteSign() }
                if card.unsent { UnsentTag() }
                Spacer(minLength: 4)
                // its tags' signs only, at most three (UX.md §24): secondary, as POLISH keeps tertiary for placeholders;
                // listed by tag, not the one its header shows (§27)
                let tags = card.tags.filter { $0.id != card.listedUnder }
                if !tags.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(tags.prefix(3), id: \.id) { t in TagSign(sign: t.sign, name: t.name, size: 11) }
                        if tags.count > 3 { Text("+\(tags.count - 3)").font(.system(size: 11)) }
                    }
                    .foregroundStyle(Ink.secondary)
                    .padding(.trailing, 3)
                }
                Text(card.overall ? "overall" : card.page.map { "p.\($0 + 1)" } ?? "—").font(.system(size: 11))
                    .foregroundStyle(Ink.secondary).monospacedDigit()
            }
            .frame(height: 18)
            Group {
                if card.firstLine.isEmpty, let q = card.quote {
                    Text(q).font(.system(size: 13, design: .serif)).italic().foregroundStyle(Ink.secondary)
                } else {
                    Text(card.firstLine).font(.system(size: 13))
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44, alignment: .leading)
        .foregroundStyle(Ink.label)
        .overlay(alignment: .leading) { MarkBar(color: card.color, faded: card.status.closed).padding(.vertical, 10) }
        .opacity(look.quiet ? RowLook.opacity(scheme) : 1)
        .background(RoundedRectangle(cornerRadius: 6).fill(look.hovering ? Color(nsColor: Palette.hover) : .clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.accessibility + (card.unsent ? ", unsent draft" : "")
                            + (card.tags.isEmpty ? "" : ". Tags: " + card.tags.map(\.name).joined(separator: ", ")))
        .accessibilityAddTraits(.isButton)
    }
}

/// A comment closed this round, in its folded group: one 30 pt line with its sign and id, the status word and the
/// closing remark (design/ui-v2/PROPOSAL.md §2, §6; UX.md §2). A click opens its card.
struct ClosedLine: View, Equatable {
    let card: CardModel
    @ObservedObject var look: RowLook
    @Environment(\.colorScheme) private var scheme

    static func == (a: ClosedLine, b: ClosedLine) -> Bool { a.card == b.card && a.look === b.look }

    var body: some View {
        let _ = { BodyCount.row += 1 }()
        let remark = card.verdictNote.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        HStack(spacing: 8) {
            Chip(id: card.id, status: card.status, compact: true)
            if card.studentNote != nil { StudentNoteSign() }
            Text(card.status.word.lowercased() + (remark.isEmpty ? "" : " · " + remark))
                .font(.system(size: 12))
                .foregroundStyle(Ink.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .leading)
        .foregroundStyle(Ink.label)
        .overlay(alignment: .leading) { MarkBar(color: card.color, faded: true).padding(.vertical, 8) }
        .opacity(look.quiet ? RowLook.opacity(scheme) : 1)
        .background(RoundedRectangle(cornerRadius: 6).fill(look.hovering ? Color(nsColor: Palette.hover) : .clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.accessibility + (remark.isEmpty ? "" : ". Closing remark: " + remark))
        .accessibilityAddTraits(.isButton)
    }
}

/// The 3 pt bar in a comment's mark colour, 6 pt inside the left edge of its row or card; at 45% when the comment is
/// closed.
struct MarkBar: View {
    let color: MarkColor
    let faded: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5).fill(Color(nsColor: color.fill)).frame(width: 3)
            .opacity(faded ? 0.45 : 1).padding(.leading, 6)
    }
}

/// A row's word: secondary; position uncertain with its question mark in vermilion, the words secondary (the
/// triangle is Not found's; the UI audit; UI v4: vermilion for the sign only); not found in red (the chip has the sign).
struct StateWord: View {
    let text: String
    let tone: CardModel.Tone

    var body: some View {
        let colour: Color = switch tone {
        case .plain, .attention: Ink.secondary
        case .danger: Color(nsColor: Palette.danger)
        }
        HStack(spacing: 3) {
            if tone == .attention {
                Image(systemName: BuildSign.uncertain).font(.system(size: 11)).foregroundStyle(Color(nsColor: Palette.toCheck))
            }
            Text(text)
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .foregroundStyle(colour)
    }
}

/// A row's sign that the student wrote a note on the comment in the shown round (a `% R1-03 …` line; UX.md §2): a
/// speech bubble in the second label colour, neutral (design/ui-v2.2 CARD.md §3.9; `quote.bubble` looked too much like
/// the comment sign `text.bubble`). The same sign is in a note's bubble footer and on the lines about ignored notes.
struct StudentNoteSign: View {
    static let symbol = "bubble.left"

    var body: some View {
        Image(systemName: Self.symbol).font(.system(size: 11)).foregroundStyle(Ink.label2)
    }
}

/// "unsent draft": text in a card's follow-up field that was not sent (UX.md §8), after a small vermilion ring (UI v4:
/// the mark colour for the sign, the words in label2).
struct UnsentTag: View {
    var body: some View {
        HStack(spacing: 4) {
            StatusRing(fill: 0, color: Color(nsColor: Palette.toCheck)).frame(width: 8, height: 8)
            Text("unsent draft").foregroundStyle(Ink.label2)
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 6)
        .frame(height: 17)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: Palette.chipFill)))
    }
}

/// How far the selected card's answer row is moved up so it stays at the panel's bottom edge while the card is taller
/// than the panel (UX.md §2); set by the panel's table as it scrolls. Only the answer row observes it.
@MainActor
final class PinState: ObservableObject {
    @Published var offset: CGFloat = 0
    /// The answer row's height (with the follow-up field when it shows) as laid out, and its card's id: the toast
    /// keeps off it.
    var height: (id: String, height: CGFloat)? {
        didSet { if height?.id != oldValue?.id || abs((height?.height ?? 0) - (oldValue?.height ?? 0)) >= 0.5 { measured?() } }
    }
    var measured: (() -> Void)?
}

/// The card's type (design/ui-v2/PROPOSAL.md §3; POLISH §2.3): the paper's text in New York 13/20, the shown round's
/// 14/21; the advisor's words in SF 13/18.
enum CardType {
    static let paper = Font.system(size: 13, design: .serif)
    static let paperSpacing: CGFloat = 4.5  // New York 13 sets 15.5 pt lines
    static let now = Font.system(size: 14, design: .serif)
    static let nowSpacing: CGFloat = 4.3  // New York 14 sets 16.7 pt lines
    static let words = Font.system(size: 13)
    static let wordsSpacing: CGFloat = 2.5
    static let label = Font.system(size: 11, weight: .medium)
}

/// A note as its card's title (`NoteTitle`, POLISH §2.3): the first sentence 15/20 (Semibold; Medium in CJK), the
/// rest 13 Regular on the lines under it, or a long first sentence's whole note 14 pt Medium. One Text, so a J/K step
/// lays out (and makes selectable) one text, as before the title had two sizes.
struct NoteTitleView: View {
    let title: NoteTitle
    var placeholder = false

    var body: some View {
        Group {
            switch title.style {
            case .long:
                Text(title.first).font(.system(size: 14, weight: .medium))
            case .sentence:
                let first = Text(title.first).font(.system(size: 15, weight: placeholder ? .regular : title.cjk ? .medium : .semibold))
                if title.rest.isEmpty { first } else { first + Text("\n" + title.rest).font(.system(size: 13)) }
            }
        }
        .lineSpacing(2.5)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The selected card (UX.md §2, §3): header, the note as its title, the conversation (its turns, then this round's
/// follow-up field or your answer this round), then the answer buttons or the choice row.
struct ExpandedCard: View, Equatable {
    let card: CardModel
    let actions: CardActions
    @EnvironmentObject var edit: EditState

    static func == (a: ExpandedCard, b: ExpandedCard) -> Bool { a.card == b.card }

    private var editingNote: Bool { edit.field == .note(card.id) }
    private var editingRemark: Bool { edit.field == .remark(card.id) }
    /// The field holds text: the buttons read "+ note" and Follow up is the default.
    private var hasText: Bool { card.verdict == nil && !AppModel.trimmed(edit.draft).isEmpty }

    var body: some View {
        let _ = { BodyCount.expanded += 1 }()
        VStack(alignment: .leading, spacing: 0) {
            header
            note.padding(.top, 10)
            // the writing tags under the title (UX.md §24): words and signs, + for the picker; in any round
            CardTagRow(card: card, actions: actions).padding(.top, card.note.isEmpty && card.carried ? 0 : 8)
            thread.padding(.top, 14)
            if card.carried && edit.roundOpen {
                PinnedRow(pin: actions.pin, id: card.id) {
                    if let ch = edit.choice, ch.id == card.id { choiceRow(ch) } else { verdicts }
                }
                .padding(.top, 12)
            } else if let n = card.reopenIn {
                reopenRow(n).padding(.top, 12)
            }
        }
        // at its own height: the stacks then size each part once, not for every height the table's measure tries
        .fixedSize(horizontal: false, vertical: true)
        .modifier(RaisedCard())  // no bar at its edge: the mark's colour is on this round's text (POLISH §3, 8)
        .foregroundStyle(Ink.label)
        .onChange(of: card.id) { if edit.info != nil { edit.info = nil } }
    }

    /// The chip and the status word; on the right only the page, which reveals the mark, and ⋯ (POLISH §3, 8): the
    /// colour and kind, the source and edits (the old ⓘ), Re-anchor…, Copy ID and Delete… are in its menu. In an open
    /// round the mark's colour dot before the page opens its swatches and kinds (UX.md §8).
    private var header: some View {
        HStack(spacing: 8) {
            let tinted = card.status.tinted && (card.open || card.status != .toCheck)
            Chip(id: card.id, status: card.status, open: card.open)
            // To check in the label colour, its chip's ring vermilion (UI v4: the mark colour is never the words')
            Text(card.status.word(open: card.open))
                .font(.system(size: 12, weight: tinted ? .medium : .regular))
                .foregroundStyle(!tinted ? Ink.secondary : card.status == .toCheck ? Ink.label : Color(nsColor: card.status.color))
            Spacer(minLength: 4)
            if edit.saving && edit.id == card.id { ProgressView().controlSize(.small) }
            HStack(spacing: 12) {
                if edit.roundOpen { ColourDot(card: card, actions: actions) }
                if card.overall {
                    Text("overall").help("On the whole paper: it has no mark")
                } else {
                    Button(card.page.map { "p.\($0 + 1)" } ?? "no page") { actions.reveal(card.id) }
                        .buttonStyle(.plain)
                        .help("Show the mark in the PDF")
                }
                Button { actions.moreMenu(card.id) } label: { Image(systemName: "ellipsis.circle").font(.system(size: 16)) }
                    .buttonStyle(.plain)
                    .help(card.overall ? "Colour, Edit Note, tags, Copy ID" : "Colour, kind, source and edits, Re-anchor…, Copy ID")
                    .popover(isPresented: Binding(get: { edit.info == card.id }, set: { if !$0 { edit.info = nil } }),
                             arrowEdge: .bottom) { info }
            }
            .font(.system(size: 11))
            .foregroundStyle(Ink.secondary)
            .fixedSize()
        }
        .frame(height: 20)
    }

    /// ⓘ: the source location, how the engine placed the mark, and this round's edits (UX.md §2).
    private var info: some View {
        let i = card.info
        // its own colours: the header's secondary, inherited, and .secondary over it made its lines tertiary (visual
        // review 2026-10-18)
        return VStack(alignment: .leading, spacing: 6) {
            Text(i.location ?? "Not in the source").font(.system(size: 12).monospaced()).textSelection(.enabled)
                .foregroundStyle(Ink.label)
            Text("Placed by: " + i.method).font(.system(size: 12)).foregroundStyle(Ink.secondary)
            if !i.changes.isEmpty {
                HStack(spacing: 6) {
                    Text("Edits in R\(edit.round):").font(.system(size: 12)).foregroundStyle(Ink.secondary)
                    ForEach(i.changes, id: \.self) { id in
                        Button(id) { actions.revealChange(id) }.buttonStyle(LinkStyle())
                            .font(.system(size: 12).monospaced())
                            .help("Show change \(id) in the PDF")
                    }
                }
            }
            if !i.newImages.isEmpty {
                Text("New image file: " + i.newImages.joined(separator: ", ")).font(.system(size: 12))
                    .foregroundStyle(Ink.secondary)
            }
        }
        .padding(12)
        .frame(minWidth: 200, alignment: .leading)
    }

    /// The note is the card's title: what the advisor said when the comment was made (R1 says nothing more).
    @ViewBuilder private var note: some View {
        if editingNote {
            VStack(alignment: .leading, spacing: 3) {
                InlineTextEditor(text: $edit.text, font: .systemFont(ofSize: 13, weight: .medium),
                                 onSubmit: actions.commitEdit, onCancel: actions.cancelEdit, onFocusLost: actions.focusLost)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(0.6)))
                editButtons
            }
        } else if card.carried {
            if !card.note.isEmpty { NoteTitleView(title: card.title).textSelection(.enabled) }
        } else {
            EditableNote(title: card.title, enabled: edit.roundOpen) { actions.editNote(card.id) }  // busy too: only Save waits
        }
    }

    /// Under an inline editor (POLISH §6, mouse first): Cancel and Save, their keys (Esc, ⌘↩) in the help tags;
    /// "Saving…" while the engine has it. Cancel on a changed note asks for a second Cancel, which discards it.
    private var editButtons: some View {
        HStack(spacing: 12) {
            if edit.saving {
                Text("Saving…").foregroundStyle(Ink.secondary)
            } else {
                if edit.escArmed { Text("Your changes are not saved.") }  // primary: red is for errors
                Spacer(minLength: 0)
                Button(edit.escArmed ? "Discard changes" : "Cancel") { actions.cancelEdit() }
                    .buttonStyle(LinkStyle())
                    .help(edit.escArmed ? "Discard your changes (Esc)" : "Close the editor without saving (Esc)")
                Button("Save") { actions.commitEdit() }
                    .buttonStyle(LinkStyle())
                    .help("Save (⌘↩); a click elsewhere saves too")
            }
        }
        .font(.system(size: 11))
    }

    // MARK: The conversation

    /// What the conversation lists, in order: its turns, the fold's line, the follow-up field.
    private enum Row: Hashable {
        case turn(Int)
        case fold(open: Bool)
        case field
    }

    /// The turns on the rail (UX.md §3; design/ui-v2.2 CARD.md option C), each round's label saying who did what; past
    /// five turns the ones between the first and the last three fold into one line, which a click opens (not in Focus,
    /// where the card has the panel); the follow-up field where the rail ends, with no dot.
    private var thread: some View {
        let fold = edit.focus ? nil : card.fold
        let open = edit.showAll.contains("fold")
        var rows: [Row] = []
        for i in card.turns.indices {
            if let f = fold, i >= f.start, i < f.end {
                if i == f.start { rows.append(.fold(open: open)) }
                if !open { continue }
            }
            rows.append(.turn(i))
        }
        if card.carried && card.verdict == nil && edit.roundOpen { rows.append(.field) }
        let folded = fold != nil && !open
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element) { k, row in
                let rail = k < rows.count - 1
                switch row {
                case .turn(let i):
                    let t = card.turns[i]
                    Railed(dot: Self.dot(t), rail: rail, gap: rail ? (t.kind == .quiet && !t.now ? 10 : 14) : 0) {
                        turn(t, folded: folded)
                    }
                case .fold(let open):
                    if let fold {
                        Railed(dot: .none, rail: rail, railTop: 16, gap: rail ? 11 : 0) {
                            FoldLine(label: card.labels["fold"] ?? AttributedString(fold.label), count: fold.count, open: open) {
                                actions.toggleShowAll("fold")
                            }
                        }
                    }
                case .field:
                    Railed(dot: .none) { followUpField }
                }
            }
        }
    }

    static func dot(_ t: Turn) -> RailDot {
        switch t.dot {
        case .you: return .you
        case .change: return .change
        case .hollow: return .hollow
        case .small: return .small
        case .notFound: return .notFound
        }
    }

    /// A turn: its label (the date on the right), what was said, the evidence (the round's text or crop), the edits a
    /// note linked elsewhere; the shown round's answer is the card's own words, edited in place. The turn is one
    /// VoiceOver element, whose count link is its action; each edit linked elsewhere is a button of its own after it.
    /// A new comment's one turn ends with when it goes out (CARD §3.2).
    @ViewBuilder private func turn(_ t: Turn, folded: Bool) -> some View {
        if t.kind == .answer {
            VStack(alignment: .leading, spacing: 0) {
                turnLabel(t)
                words
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    turnLabel(t)
                    if let w = t.words {
                        let key = t.id + ".words"
                        WordsBubble(text: w.text, clamp: edit.focus ? nil : w.clamp, expanded: edit.showAll.contains(key),
                                    place: w.place, toggle: { actions.toggleShowAll(key) })
                            .padding(.top, 5)
                    } else if let b = t.bare {
                        BareNote(place: b, id: card.id).padding(.top, 5)
                    }
                    if let id = t.section, let s = card.thread.first(where: { $0.id == id }) {
                        paper(s, folded: folded && t.kind == .first).padding(.top, t.words != nil || t.bare != nil ? 8 : 6)
                    }
                    if t.uncertain, let s = card.thread.last { uncertainCaption(s, open: edit.roundOpen && t.round == edit.round) }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(t.accessibility)
                .modifier(RevealAction(change: t.reveal, actions: actions))
                if !t.elsewhere.isEmpty && !card.attachments.isEmpty { attachments(alone: t.section == nil).padding(.top, 8) }
                if t.kind == .first && !card.carried && edit.roundOpen {
                    // how to edit it is in the help tag (design/review-page/BRIEF.md E9: no how-to words stay on screen)
                    Text("Goes out in the Round \(edit.round) final.pdf")
                        .font(.system(size: 11)).foregroundStyle(Ink.secondary).padding(.top, 12)
                        .help("Click the note to edit it. Delete it with Delete… in the ⋯ menu (⌫)")
                }
            }
        }
    }

    /// "R4 · Ouyang Mingxuan replaced the image · 1 edit" (the count a link in the shown round), wrapping under itself
    /// when it is long, never cut; "position uncertain" beside it or under it; the date on the right.
    private func turnLabel(_ t: Turn) -> some View {
        let text = Text(card.labels[t.id] ?? AttributedString(t.label)).fixedSize(horizontal: false, vertical: true)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            if t.uncertain {
                FlowRow {
                    text
                    Tag(text: "position uncertain", attention: edit.roundOpen)
                }
                .layoutPriority(1)
            } else {
                text.layoutPriority(1)
            }
            Spacer(minLength: 0)
            if let date = t.date {
                Text(date).font(.system(size: 11)).foregroundStyle(Ink.secondary).fixedSize()  // dates are secondary
            }
        }
        .frame(minHeight: 16)
        .tint(Ink.link)
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "edit" { actions.revealChange(String(url.absoluteString.dropFirst("edit:".count))) }
            return .handled
        })
    }

    /// The edits the student's note alone linked outside the commented text, as the Changes tab shows them, two at most
    /// and a link to the next (CARD §3.7). `alone`: the commented text printed nothing new this round, so the edit is
    /// this round's text, at its size.
    private func attachments(alone: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(card.attachments.prefix(2), id: \.id) { ch in
                ElsewhereAttachment(change: ch, now: alone, color: card.color, showAll: edit.showAll, actions: actions)
            }
            if card.attachments.count > 2 {
                Button("+" + count(card.attachments.count - 2, "more edit")) { actions.revealChange(card.attachments[2].id) }
                    .buttonStyle(LinkStyle())
                    .font(.system(size: 11, weight: .medium))
                    .help("Show the next edit in the PDF")
            }
        }
    }

    /// The text the round printed (or its crop), with a rule beside it: the shown round's one size up, 14/21, beside a
    /// 3 pt rule in the mark's colour, the earlier rounds' 13/20 beside a 2 pt grey one (POLISH §3, 8: "now" by type,
    /// not by a box); the shown round's crop 112 pt tall, the others 64. `folded`: the first turn while the
    /// conversation folds, its text cut closer round the mark.
    /// The widest area of the card's ink crops, which share its scale (`CropView`).
    private var inkWidest: CGFloat {
        card.thread.compactMap { $0.crop.flatMap { $0.look == .ink ? CropCache.area($0)?.width : nil } }.max() ?? 0
    }

    @ViewBuilder private func paper(_ s: ThreadSection, folded: Bool) -> some View {
        let now = s.round == edit.round
        switch s.kind {
        case .text, .source:
            let whole = edit.showAll.contains(s.id)
            let cut = folded && card.rendered[s.id + ".fold"] != nil ? ".fold" : s.short != nil ? ".short" : nil
            VStack(alignment: .leading, spacing: 2) {
                Text(card.rendered[s.id + (whole ? "" : cut ?? "")] ?? AttributedString(s.full.text))
                    .font(s.kind == .source ? .system(size: 12, design: .monospaced) : now ? CardType.now : CardType.paper)
                    .lineSpacing(now ? CardType.nowSpacing : CardType.paperSpacing)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if cut != nil {
                    Button(whole ? "Show less" : "Show all") { actions.toggleShowAll(s.id) }
                        .buttonStyle(LinkStyle()).font(CardType.label)
                }
            }
            .padding(.leading, now ? 11 : 10)
            .overlay(alignment: .leading) {
                Rectangle().fill(now ? Color(nsColor: card.color.fill).opacity(card.status.closed ? 0.45 : 1)
                                     : Color(nsColor: Palette.rule))
                    .frame(width: now ? 3 : 2)
            }
        case .image:
            if let req = s.crop {
                // the mark in its ink on paper (a figure's crop 112 pt tall in the shown round, 64 in the others); a
                // formula's or table's ink at its print size, one scale for the card's (`inkWidest`), bare on the card,
                // the mark its tint under the marked words (a box's the faint one; none when the box is most of the
                // crop, as round a whole formula or table: there it was a backing of its own, `CropCache.picksOut`)
                CropView(request: req, ink: Palette.pair(card.color.ink, card.color.fill),
                         tint: card.kind == .box && !CropCache.picksOut(req) ? .clear
                             : card.color.tint(strong: !req.faint && card.kind != .box),
                         height: now ? 112 : 64, widest: inkWidest,
                         fold: (edit.showAll.contains(s.id + ".crop"), { actions.toggleShowAll(s.id + ".crop") }))
            } else {
                Text("No image of this area").font(.system(size: 11)).foregroundStyle(Ink.secondary)
            }
        case .plain:
            Text(s.full.text).font(CardType.words).foregroundStyle(Ink.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(Color(nsColor: Palette.rule)).frame(width: 2) }
        case .none where card.overall:
            EmptyView()  // on the whole paper: no words of its own to show, and nothing lost
        case .none:
            Text(LocalizedStringKey("Not found in R\(s.round)."
                                    + (edit.roundOpen && now ? " Choose [Re-anchor…](reanchor:) to place it." : "")))
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: Palette.danger))
                .tint(Ink.link)  // a link in words, as `LinkStyle`
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.openURL, OpenURLAction { _ in
                    actions.reanchor(card.id)
                    return .handled
                })
        }
    }

    private func uncertainCaption(_ s: ThreadSection, open: Bool) -> some View {
        caption(icon: Color(nsColor: edit.roundOpen ? Palette.toCheck : Palette.neutral),
                Self.uncertainWords(s, page: card.page, round: edit.round, open: open))
    }

    /// The "position uncertain" caption under the turn that holds the shown round (UX.md §3), in markdown. The tint is
    /// named only on the shown round's own text: when the shown round is a tag on an earlier section, the tint there
    /// is that round's mark, not where the mark sits now.
    static func uncertainWords(_ s: ThreadSection, page: Int?, round: Int, open: Bool) -> String {
        let on = page.map { " on p.\($0 + 1)" } ?? ""
        let what = page == nil ? "This round’s mark is on no page of the PDF."
            : s.kind == .text && s.round == round
                ? "The \(s.strong ? "" : "faint ")tint shows where the mark sits now, and it may be on the wrong words. Check it\(on)"
            : "The mark may be in the wrong place. Check it\(on)"
        let then = page == nil ? (open ? " Choose [Re-anchor…](reanchor:) to place it." : "")
            : open ? "; if it is wrong, choose [Re-anchor…](reanchor:)" : "."
        return what + then
    }

    /// A line under a turn with a warning sign; "[Re-anchor…](reanchor:)" in it is a link.
    private func caption(icon: Color, _ markdown: String) -> some View {
        Text(LocalizedStringKey(markdown)).font(.system(size: 11.5)).foregroundStyle(Ink.secondary)
            .tint(Ink.link)  // a link in words, as `LinkStyle`
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 17)
            .overlay(alignment: .topLeading) {
                Image(systemName: BuildSign.uncertain).font(.system(size: 10)).foregroundStyle(icon).padding(.top, 2.5)
            }
        .padding(.top, 8)
        .environment(\.openURL, OpenURLAction { _ in
            actions.reanchor(card.id)
            return .handled
        })
    }

    /// The follow-up field, always there on a card to check in an open round (UX.md §8). It takes the cursor only from
    /// R, Return or a click; ⌘↩ sends, Return adds a line, Esc leaves it with the text kept as an unsent draft.
    private var followUpField: some View {
        let focused = edit.fieldFocused == card.id
        return VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topLeading) {
                InlineTextEditor(text: Binding(get: { edit.draft }, set: { actions.draftChanged(card.id, $0) }),
                                 minLines: 1, maxLines: 8, autoFocus: false, wantsFocus: edit.focusRequest == card.id,
                                 onSubmit: { actions.sendDraft(card.id, keyboard: true) }, onCancel: actions.leaveField,
                                 onFocus: { actions.fieldFocused(card.id) }, onFocusLost: { actions.fieldBlurred(card.id) })
                    .id(card.id)  // a field of its own per card: no cursor or typing undo crosses to the next card
                if edit.draft.isEmpty {
                    Text("Write a follow-up for the student…")
                        .font(CardType.words)
                        .foregroundStyle(Ink.tertiary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 3)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(focused ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: 1))
            .shadow(color: focused ? Color.accentColor.opacity(0.25) : .clear, radius: 2)
            if hasText && !focused {
                HStack(spacing: 6) {
                    UnsentTag()
                    Text("kept on this Mac").font(.system(size: 11)).foregroundStyle(Ink.secondary)
                    Spacer(minLength: 4)
                    Button("Discard") { actions.discardDraft(card.id) }.buttonStyle(LinkStyle())
                        .font(.system(size: 11, weight: .medium))
                        .help("Delete this draft")
                }
            }
        }
    }

    /// This round's words, under its answer's label ("R4 · you followed up"): the follow-up sent with ⌘↩ (it goes out
    /// in the round’s final.pdf), or the closing remark of a Resolved or Kept-as-is card, in the grey bubble. Click Edit or
    /// press Return to change them before the round is finished.
    @ViewBuilder private var words: some View {
        let followUp = card.verdict == "reopened"
        if editingRemark {
            VStack(alignment: .leading, spacing: 3) {
                ZStack(alignment: .topLeading) {
                    InlineTextEditor(text: $edit.text, minLines: 2, maxLines: 8,
                                     onSubmit: actions.commitEdit, onCancel: actions.cancelEdit, onFocusLost: actions.focusLost)
                    if edit.text.isEmpty {
                        Text(followUp ? "Follow-up for the student (optional)" : "Closing remark (optional)")
                            .font(CardType.words).foregroundStyle(Ink.tertiary)
                            .padding(.horizontal, 7).padding(.vertical, 4).allowsHitTesting(false)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accentColor, lineWidth: 1.5))
                editButtons
            }
            .padding(.top, 5)
        } else if card.verdict != nil, !card.verdictNote.isEmpty {
            Bubble {
                VStack(alignment: .leading, spacing: 4) {
                    Text(card.verdictNote).textSelection(.enabled)
                    HStack(spacing: 6) {
                        Group {
                            if !followUp {
                                Text("Closing remark · in final.pdf" + (edit.roundOpen ? ", not a to-do" : ""))
                            } else if edit.roundOpen {
                                Text("Goes out in the Round \(edit.round) final.pdf")
                            }
                        }
                        .foregroundStyle(Ink.secondary)
                        Spacer(minLength: 0)
                        if edit.roundOpen {  // busy too: a click then says "Still loading…", as Return does
                            Button("Edit") { actions.editRemark(card.id) }.buttonStyle(LinkStyle())
                                .help("Edit what you wrote this round (Return)")
                        }
                    }
                    .font(.system(size: 11))
                }
            }
            .padding(.top, 5)
        }
    }

    // MARK: Answers

    /// Resolve · Follow up · Keep as is, always in these places. With text in the field, Follow up is the default and
    /// the other two close with the text as a closing remark. No key letters on them (POLISH §6, mouse first): the keys
    /// are in the help tags. They stay enabled while the engine works: a click then says "Still loading…" (O27; POLISH
    /// §7), as their keys do. The first-run tip, which says an answer moves on, is not shown in Focus, where none does.
    private var verdicts: some View {
        let text = hasText
        return VStack(alignment: .leading, spacing: 8) {
            AnswerRow {  // in a narrow panel Keep as is goes to a line of its own (`AnswerRow`)
                verdictButton(text ? "Resolve + note" : "Resolve", "checkmark", "verified", key: "V",
                              help: "Resolve (V): the student dealt with it and you are satisfied: they fixed it, deleted "
                                  + "the passage, or gave a reason you accept. Closes the comment; the student reads “resolved”."
                                  + (text ? " Your text goes with it as a closing remark." : ""))
                if text {
                    Button { actions.sendDraft(card.id) } label: {
                        Label("Follow up", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(AnswerButtonStyle(style: .default))
                    .fixedSize()
                    .help("Follow up (⌘↩): send your text to the student in this round’s final.pdf. The comment stays open.")
                } else {
                    verdictButton("Follow up", "arrow.uturn.backward", "reopened", key: "R",
                                  help: "Follow up (R): not done yet. Write what is still missing in the field above, then "
                                      + "click Follow up (or press ⌘↩) to send it in this round’s final.pdf; the comment stays open.")
                }
                Button { actions.press("wontfix", card.id) } label: { Text(text ? "Keep as is + note" : "Keep as is") }
                    .buttonStyle(QuietButtonStyle(active: card.verdict == "wontfix"))
                    .fixedSize()
                    .help(card.verdict == "wontfix" ? "Kept as is · click again (or press W) to clear; your remark goes back to the field"
                          : "Keep as is (W): the student did not deal with it and you no longer require it: on rereading the "
                            + "original is fine, or you changed your mind. Closes the comment; the student reads “no change needed”."
                            + (text ? " Your text goes with it as a closing remark." : ""))
            }
            if text { Text("A new request belongs in Follow up.").font(.system(size: 11)).foregroundStyle(Ink.secondary) }
            if card.verdict == nil && !edit.focus { AnswerTip(tips: actions.tips) }
        }
    }

    /// A comment closed in the earlier round shown, which the student broke since (TAGS.md §9.2): the one action an
    /// earlier round has, as it acts on the open round. No circular arrow (the critique: ↺ meant follow-up before).
    private func reopenRow(_ n: Int) -> some View {
        HStack(spacing: 10) {
            Button { actions.reopen(card.id) } label: { Text("Reopen in Round \(n)") }
                .buttonStyle(AnswerButtonStyle(style: .plain))
                .fixedSize()
                .help("Bring \(card.id) back into Round \(n) as To check, placed against this round’s text, to follow it up "
                      + "there. Undo Reopen is in its ⋯ menu until Round \(n) is finished.")
            Spacer(minLength: 0)
        }
    }

    private func verdictButton(_ title: String, _ icon: String, _ verdict: String, key: String, help: String) -> some View {
        let active = card.verdict == verdict
        return Button { actions.press(verdict, card.id) } label: { Label(title, systemImage: icon) }
            .buttonStyle(AnswerButtonStyle(style: active ? .on : .plain))
            .fixedSize()  // the spacer gives way, never a title (the stack would cut one though there is room)
            .help(active ? "\(Status(verdict: verdict).word) · click again (or press \(key)) to clear; "
                    + (verdict == "reopened" ? "your follow-up goes back to the field" : "your remark goes back to the field")
                  : help)
    }

    /// After a bare V or W on a card with text: close with it as a closing remark (Return), without it (⌫), or not
    /// (Esc); ⌘↩ sends it as a follow-up instead. The keys are in the help tags.
    private func choiceRow(_ ch: EditState.Choice) -> some View {
        let name = ch.verdict == "verified" ? "Resolve" : "Keep as is"
        let what = ch.sent ? "follow-up" : "draft"
        return VStack(alignment: .leading, spacing: 8) {
            Text("Close \(card.id) with your \(what) as a closing remark?")
                .font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            AnswerRow {
                Button { actions.choose(.withText) } label: { Text(name + " + note") }
                    .buttonStyle(AnswerButtonStyle(style: .default))
                    .fixedSize()
                    .help("Close it with your \(what) as the closing remark (Return)")
                Button { actions.choose(.withoutText) } label: { Text(name + " without it") }
                    .buttonStyle(AnswerButtonStyle(style: .plain))
                    .fixedSize()
                    .help("Close it and drop the text (⌫); Undo brings it back")
                Button("Cancel") { actions.choose(.cancel) }.buttonStyle(QuietButtonStyle(active: false))
                    .fixedSize()
                    .help(ch.sent ? "Leave it a follow-up (Esc)"
                          : "Keep the draft in the field (Esc); Follow up then sends it to the student (⌘↩ here does both)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: Palette.chipFill)))
    }
}

/// The first-run tip (POLISH §3 row 14), under the answer buttons of a card to check: how answering goes, in mouse
/// words (POLISH §6), until Got it or the first answer; the paper map's tip's look (`InlineTip`, UI v4), its arrow at
/// the answer buttons. Only it observes `Tips`, so a J/K step costs nothing once it is gone.
struct AnswerTip: View {
    @ObservedObject var tips: Tips

    static let title = "Answer each comment"
    static let text = "Answer with Resolve, Follow up or Keep as is. The next comment to check then takes this one’s place."

    var body: some View {
        if tips.answer {
            InlineTip(title: Self.title, text: Self.text, arrow: 28) { tips.dismiss() }
                .padding(.top, 4)
        }
    }
}

/// The dots of `Railed`.
enum RailDot { case you, change, hollow, small, notFound, none }

/// A turn of a card's conversation (UX.md §3; the Changes tab's sections too, §16) with its dot on the rail, and the
/// rail on down to the next row's dot (`rail`), `gap` below it. The dots (design/ui-v2.2 CARD.md §3.3) say what kind of
/// turn it was: the advisor's (neutral grey), the student's change to the paper (green), nothing changed (hollow; small
/// for an earlier quiet line), not found (a red ring); the follow-up field and the fold's line have none. The dot and
/// the rail are overlays, not an HStack, which would measure the text again for each width it tries (J/K, UX.md §10).
/// A turn's count link for VoiceOver: "Show the edit in the PDF" as the turn's action, when the count is a link.
private struct RevealAction: ViewModifier {
    let change: String?
    let actions: CardActions

    func body(content: Content) -> some View {
        if let change {
            content.accessibilityAction(named: "Show the edit in the PDF") { actions.revealChange(change) }
        } else {
            content
        }
    }
}

struct Railed<Content: View>: View {
    typealias Dot = RailDot

    let dot: Dot
    var rail = false
    var railTop: CGFloat = 8  // where the rail starts: the dot's middle (it is drawn over the rail)
    var gap: CGFloat = 0
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 18)
            .padding(.bottom, gap)
            .overlay(alignment: .topLeading) {
                if rail {  // down to the next row's dot, 8 pt into it
                    Rectangle().fill(Color(nsColor: Palette.rule)).frame(width: 1)
                        .padding(.top, railTop).padding(.bottom, -8).offset(x: 4)
                }
            }
            .overlay(alignment: .topLeading) { mark }
    }

    @ViewBuilder private var mark: some View {
        let card = Color(nsColor: Palette.card)
        switch dot {
        case .you, .change:  // with a ring of the card's colour, so the rail stops short of it
            Circle().fill(Color(nsColor: dot == .you ? Palette.neutral : Palette.change)).frame(width: 9, height: 9)
                .padding(2).background(Circle().fill(card))
                .offset(x: -2, y: 1.5)
        case .hollow, .notFound:
            Circle().fill(card).frame(width: 9, height: 9)
                .overlay(Circle().strokeBorder(dot == .notFound ? Color(nsColor: Palette.danger) : Ink.tertiary,
                                               lineWidth: dot == .notFound ? 1.6 : 1.5))
                .offset(y: 3.5)
        case .small:
            Circle().fill(card).frame(width: 5, height: 5)
                .overlay(Circle().strokeBorder(Ink.tertiary, lineWidth: 1.2))
                .offset(x: 2, y: 5.5)
        case .none:
            EmptyView()
        }
    }
}

/// A thread label, "R3 · revised": the round in the label colour and Semibold (POLISH §2.3), the rest secondary.
func threadLabel(_ s: String, weight: Font.Weight = .medium) -> Text {
    guard let dot = s.range(of: " · ") else { return Text(s).fontWeight(.semibold).foregroundColor(Ink.label) }
    return Text(s[..<dot.lowerBound]).fontWeight(.semibold).foregroundColor(Ink.label)
        + Text(s[dot.lowerBound...]).fontWeight(weight).foregroundColor(Ink.secondary)
}

/// The panel's raised card (UX.md §2; POLISH §2.4): radius 10, white with a soft shadow, or lighter with a hairline in
/// Dark Mode; no bar at its edge (POLISH §3 rows 8 and 10).
struct RaisedCard: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: Palette.card))
                    .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.06), radius: 1, y: 1)
                    .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.07), radius: 7, y: 4)
            }
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: Palette.cardLine)))
    }
}

/// The answer row, moved up to the panel's bottom edge while the card is taller than the panel (PinState), on the
/// card's colour with a hairline above it, so the thread scrolls under it.
struct PinnedRow<Content: View>: View {
    @ObservedObject var pin: PinState
    let id: String
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background {
                GeometryReader { g in
                    Color.clear
                        .onAppear { pin.height = (id, g.size.height) }
                        .onChange(of: g.size.height) { pin.height = (id, g.size.height) }
                }
            }
            .background(alignment: .top) {
                if pin.offset < 0 {
                    // down to the card's bottom edge, so no text shows below the row
                    Rectangle().fill(Color(nsColor: Palette.card))
                        .overlay(alignment: .top) { Rectangle().fill(Color(nsColor: Palette.rule)).frame(height: 1) }
                        .padding(.horizontal, -16).padding(.top, -8).padding(.bottom, pin.offset - 12)
                }
            }
            .offset(y: pin.offset)
    }
}

/// Its children in a row, 6 pt apart, and on the next line (4 pt below) those that no longer fit: a turn's label and
/// "position uncertain". A child wider than the row gets the row's width, at the height it has there (a label that
/// wraps).
struct FlowRow: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = place(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (v, f) in zip(subviews, place(subviews, width: bounds.width)) {
            v.place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY),
                    proposal: ProposedViewSize(width: f.width, height: f.height))
        }
    }

    private func place(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        var out: [CGRect] = [], x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for v in subviews {
            var s = v.sizeThatFits(.unspecified)
            if x > 0 && x + 6 + s.width > width {
                y += line + 4
                x = 0
                line = 0
            }
            if x > 0 { x += 6 }
            if s.width > width - x {
                s = v.sizeThatFits(ProposedViewSize(width: max(width - x, 0), height: nil))
                s.width = min(s.width, max(width - x, 0))
            }
            out.append(CGRect(origin: CGPoint(x: x, y: y), size: s))
            x += s.width
            line = max(line, s.height)
        }
        return out
    }
}

/// The answer buttons in one row (UX.md §2): the first ones from the left, 8 pt apart, the last one (Keep as is, the
/// quieter; the choice row's Cancel) at the right edge. A button that does not fit goes to the next line (6 pt below),
/// the last one still at the right: a card with a draft in a narrow panel ran its buttons out of the card (interaction
/// review 2026-10-18). Each button is measured once, at its own size (the cache), however often the card is laid out.
struct AnswerRow: Layout {
    func makeCache(subviews: Subviews) -> [CGSize] { subviews.map { $0.sizeThatFits(.unspecified) } }
    func updateCache(_ cache: inout [CGSize], subviews: Subviews) { cache = makeCache(subviews: subviews) }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout [CGSize]) -> CGSize {
        let frames = Self.frames(cache, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout [CGSize]) {
        for (v, f) in zip(subviews, Self.frames(cache, width: bounds.width)) {
            v.place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), proposal: ProposedViewSize(f.size))
        }
    }

    static func frames(_ sizes: [CGSize], width: CGFloat) -> [CGRect] {
        var out: [CGRect] = [], x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for (i, s) in sizes.enumerated() {
            if x > 0 && x + 8 + s.width > width {
                y += line + 6
                x = 0
                line = 0
            }
            var left = x > 0 ? x + 8 : 0
            if i == sizes.count - 1 && width.isFinite { left = max(left, width - s.width) }
            out.append(CGRect(x: left, y: y, width: s.width, height: s.height))
            x = left + s.width
            line = max(line, s.height)
        }
        return out
    }

}

/// A tag beside a section label: "unchanged in R2", "position uncertain" (its question mark vermilion, the words
/// label2; UI v4).
struct Tag: View {
    let text: String
    var attention = false

    var body: some View {
        HStack(spacing: 3) {
            if attention {
                Image(systemName: BuildSign.uncertain).font(.system(size: 10)).foregroundStyle(Color(nsColor: Palette.toCheck))
            }
            Text(text).lineLimit(1)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(attention ? Ink.label2 : Ink.secondary)
        .padding(.horizontal, 6)
        .frame(height: 17)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: Palette.chipFill)))
    }
}

/// A link in words (BACKLOG O32: "· 1 edit", Details… and Show all in the accent's text colour, a grey-green as quiet
/// as the words around them, read as plain words): the system's link colour (`Palette.link`), an underline while the
/// pointer is over it, the pointing hand, a little fainter while pressed. No underline at rest: on a card an underline
/// means changed words (UX.md §3).
struct LinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { LinkLabel(configuration: configuration) }
}

private struct LinkLabel: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(enabled ? Ink.link : Ink.tertiary)
            .opacity(configuration.isPressed ? 0.65 : 1)
            .underline(hovering)
            .contentShape(Rectangle())
            // set at every move, not pushed: a text view under the pointer next to it sets its I-beam again
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    guard enabled else { return }
                    NSCursor.pointingHand.set()
                    if !hovering { hovering = true }
                case .ended:
                    guard hovering else { return }
                    hovering = false
                    NSCursor.arrow.set()
                }
            }
            .onDisappear { if hovering { NSCursor.arrow.set() } }
    }
}

/// The card's answer buttons (26 pt, radius 7, 13 pt; POLISH §2.3, §2.4): plain, on (the current answer, pressed in),
/// or the one default (the accent). `small`: 22 pt, 12 pt, in the rows of the Finish sheet.
struct AnswerButtonStyle: ButtonStyle {
    enum Style { case plain, on, `default` }
    let style: Style
    var small = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        let dark = scheme == .dark
        let fill: Color = switch style {
        case .default: .accentColor
        case .on: Color.primary.opacity(dark ? 0.20 : 0.10)
        case .plain: dark ? Color(nsColor: NSColor(hex: 0x48484B)) : .white
        }
        configuration.label
            .font(.system(size: small ? 12 : 13))
            .labelStyle(AnswerLabelStyle())
            .padding(.horizontal, small ? 8 : 9)
            .frame(height: small ? 22 : 26)
            .foregroundStyle(style == .default ? Color.white : Ink.label)
            .background(RoundedRectangle(cornerRadius: 7).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(style == .plain && !dark ? Color.black.opacity(0.14) : .clear, lineWidth: 0.5))
            .shadow(color: style == .plain && !dark ? .black.opacity(0.12) : .clear, radius: 0.5, y: 0.5)
            .brightness(configuration.isPressed ? (dark ? 0.08 : -0.06) : 0)
            .opacity(enabled ? 1 : 0.5)
            .contentShape(Rectangle())
    }
}

/// An answer button's icon and title, 5 pt apart, the icon small.
struct AnswerLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 11, weight: .semibold))
            configuration.title
        }
    }
}

/// A verdict button: filled with the verdict's colour when it is the current verdict, in any window state. Also the
/// floating toolbar's accent buttons and the Changes tab's.
struct VerdictButtonStyle: ButtonStyle {
    let active: Bool
    let color: Color
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .foregroundStyle(active ? Color.white : Color.primary)
            .background(RoundedRectangle(cornerRadius: 6).fill(active ? color : Color.primary.opacity(configuration.isPressed ? 0.16 : 0.08)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(active ? Color.clear : Color.primary.opacity(0.12)))
            .opacity(enabled ? 1 : 0.5)
            .contentShape(Rectangle())
    }
}

/// The quieter Keep as is button (and Cancel): text only, with a fill when it is the current answer or pressed.
struct QuietButtonStyle: ButtonStyle {
    let active: Bool
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .padding(.horizontal, active ? 8 : 4)
            .frame(height: 26)
            .foregroundStyle(active ? Ink.label : Ink.secondary)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(Color.primary.opacity(active ? 0.10 : configuration.isPressed ? 0.06 : 0)))
            .opacity(enabled ? 1 : 0.5)
            .contentShape(Rectangle())
    }
}

/// A new comment's note, as a carried one's title (`NoteTitleView`): click to edit it in place; a light background and
/// a pencil on hover.
struct EditableNote: View {
    let title: NoteTitle
    let enabled: Bool
    let edit: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Group {
                if title.first.isEmpty {
                    NoteTitleView(title: NoteTitle("Add a note…"), placeholder: true).foregroundStyle(Ink.tertiary)
                } else {
                    NoteTitleView(title: title)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if hover && enabled { Image(systemName: "pencil").font(.system(size: 11)).foregroundStyle(Ink.tertiary) }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 5).fill(hover && enabled ? Color.primary.opacity(0.045) : .clear))
        .padding(.horizontal, -5)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { if enabled { edit() } }
        .help(enabled ? "Click to edit the note (Return)" : "")
    }
}

/// The card's ⋯ menu, as an AppKit menu: the colours' key equivalents (1–6) show but act only while it is open.
@MainActor
enum CardMenus {
    private final class Item: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func invoke() { run() }
    }

    private static func item(_ title: String, key: String = "", on: Bool = false, enabled: Bool = true,
                             image: NSImage? = nil, _ run: @escaping () -> Void) -> NSMenuItem {
        let action = Item(run)
        let i = NSMenuItem(title: title, action: enabled ? #selector(Item.invoke) : nil, keyEquivalent: key)
        i.keyEquivalentModifierMask = []
        i.target = action
        i.representedObject = action
        i.state = on ? .on : .off
        i.isEnabled = enabled
        i.image = image
        return i
    }

    static func swatch(_ c: MarkColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
            c.fill.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
            c.ink.setStroke()
            NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).stroke()
            return true
        }
    }

    private static func colorItems(_ c: Comment, _ model: AppModel) -> [NSMenuItem] {
        MarkColor.allCases.map { col in
            item(col.name, key: "\(col.key)", on: c.markColor == col, enabled: model.roundIsOpen && !model.busy,
                 image: swatch(col)) { model.setStyle(c.id, color: col) }
        }
    }

    private static func kindItems(_ c: Comment, _ model: AppModel) -> [NSMenuItem] {
        let kinds = c.markKind == .box || c.markKind == .note ? [c.markKind] : MarkKind.textKinds
        return kinds.map { k in
            item(k.name, on: c.markKind == k, enabled: model.canChangeKind(c) && k != c.markKind,
                 image: NSImage(systemSymbolName: k.symbol, accessibilityDescription: nil)) { model.setStyle(c.id, kind: k) }
        }
    }

    static func more(_ id: String, model: AppModel) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        guard let c = model.comment(id) else { return m }
        let edit = item("Edit Note", enabled: model.canEditNote(c)) { model.beginNoteEdit(id) }
        if c.carried { edit.toolTip = "Sent in R\(c.createdRound) — write a follow-up in the card’s field instead" }
        m.addItem(edit)
        // an answer of the open round without words: they are added in place, as Return does (words have their Edit
        // link); busy too: it then says "Still loading…"
        if c.carried, let v = c.verdict, (c.verdictNote ?? "").isEmpty, model.roundIsOpen {
            m.addItem(item(v == "reopened" ? "Add Follow-up Note" : "Add Closing Remark") { model.beginRemarkEdit(id) })
        }
        let colour = NSMenuItem(title: "Colour", action: nil, keyEquivalent: "")
        colour.submenu = NSMenu()
        colour.submenu?.autoenablesItems = false
        colorItems(c, model).forEach { colour.submenu?.addItem($0) }
        m.addItem(colour)
        let kind = NSMenuItem(title: "Kind", action: nil, keyEquivalent: "")
        kind.submenu = NSMenu()
        kind.submenu?.autoenablesItems = false
        kindItems(c, model).forEach { kind.submenu?.addItem($0) }
        if !c.isOverall { m.addItem(kind) }  // no mark, so no kind
        // the writing tags (UX.md §24), in any round: one on or off each
        let tagsItem = NSMenuItem(title: "Tags", action: nil, keyEquivalent: "")
        tagsItem.submenu = NSMenu()
        tagsItem.submenu?.autoenablesItems = false
        let cat = model.tags.catalog
        for t in cat.tags where !t.hidden || c.tagIDs.contains(t.id) {
            let i = item(t.name, on: c.tagIDs.contains(t.id),
                         image: t.sign.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }) { model.toggleTag(id, t.id) }
            i.toolTip = TagText.help(t)
            tagsItem.submenu?.addItem(i)
        }
        tagsItem.submenu?.addItem(.separator())
        tagsItem.submenu?.addItem(item("Choose Tags…") { model.openTagPicker(id) })
        m.addItem(tagsItem)
        m.addItem(.separator())
        // Reopen (TAGS.md §9.2): on a comment closed in the earlier round shown; Undo Reopen in the open round
        if model.viewingEarlierRound, c.revivable == true, c.verdict == "verified" || c.verdict == "wontfix", let n = model.latestRound?.n {
            m.addItem(item("Reopen in Round \(n)") { model.revive(id) })
            m.addItem(.separator())
        } else if c.revived != nil, model.roundIsOpen {
            m.addItem(item("Undo Reopen", enabled: !model.busy) { model.undoRevive(id) })
            m.addItem(.separator())
        }
        // the card's old ⓘ (POLISH §3, 8): a popover at the ⋯ button
        m.addItem(item("Source and Edits…") { model.edit.info = id })
        if !c.isOverall {  // on the whole paper: no place to move
            m.addItem(item("Re-anchor…", enabled: model.roundIsOpen) { model.beginReanchor(id) })  // busy too: Place waits
        }
        m.addItem(item("Copy ID") {
            AppModel.clipboard.clearContents()
            AppModel.clipboard.setString(id, forType: .string)
        })
        m.addItem(.separator())
        m.addItem(item("Delete…", enabled: model.canEdit(c)) { model.requestDelete(id) })
        return m
    }

    /// Opens a menu at the mouse (the click that asked for it).
    /// A change card's ⋯ (design/review-page/BRIEF.md E2): Source…, which opens the card's popover of where the edit is.
    static func changeMore(source: @escaping () -> Void) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        m.addItem(item("Source…", source))
        return m
    }

    static func popUp(_ menu: NSMenu) {
        guard let e = NSApp.currentEvent, let v = e.window?.contentView else { return }
        menu.popUp(positioning: nil, at: v.convert(e.locationInWindow, from: nil), in: v)
    }

    /// --debug-script cardmenu: the item with this title (in the menu or a submenu), performed.
    static func perform(_ title: String, in menu: NSMenu) -> Bool {
        for (i, it) in menu.items.enumerated() {
            if it.title == title, it.isEnabled, it.action != nil { menu.performActionForItem(at: i); return true }
            if let sub = it.submenu, perform(title, in: sub) { return true }
        }
        return false
    }
}
