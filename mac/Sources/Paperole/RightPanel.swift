import AppKit
import Combine
import SwiftUI

/// The panel: the tabs and the shown tab's page, its top line and its list (`PanelPager`, both pages alive, the switch
/// sliding between them); in Focus (POLISH §7) only the selected card, the same list showing that one card
/// (CommentListController, ChangeListController), with no tabs or header over it.
struct RightPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if !model.focus { tabs }
            if let r = model.round, r.closed { ReadOnlyBanner(round: r).padding(.top, model.focus ? 12 : 0) }
            // each tab's sentence or line and list on a page of its own, which slides in with its tab (PanelPages)
            ZStack(alignment: .bottom) {
                PanelPager(model: model, tab: model.tab)
                PanelToastView(toast: model.panelToast, place: model.actions.toastPlace, actions: model.actions)
            }
            .padding(.top, model.focus ? 8 : 0)
        }
        .background(Color(nsColor: Palette.panel))
    }

    /// The two tabs across the panel (POLISH §2.3, §3 row 6; v2.2: a segment that slides, `PanelTabs`), measured once
    /// (MeasuredOnce, UX.md §10.10); the cards' underline toggle is in the View menu (Underline Changed Words).
    private var tabs: some View {
        // what needs doing there, not how many there are (UX.md §1, §16)
        let comments = model.roundIsOpen ? model.commentsToCheck : 0
        return MeasuredOnce {
            PanelTabs(tab: $model.tab, comments: comments > 0 ? "Comments \(comments)" : "Comments",
                      changes: model.roundIsOpen && model.toCheck > 0 ? "Changes \(model.toCheck)" : "Changes")
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
}

/// The student's notes that were not used (UX.md §3; CONTRACT amendment "Student notes"): one calm line at the top of
/// the Comments tab, "2 student notes were ignored · Details…", in the secondary colour (not the advisor's move, nor
/// an error of the app), and Details… a popover listing each with file:line, its line as written and why.
struct NoteWarningsLine: View {
    let warnings: [NoteWarning]
    let round: Int
    var open = true
    @Binding var shown: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: StudentNoteSign.symbol).font(.system(size: 11)).foregroundStyle(Ink.secondary)
            Text(warnings.count == 1 ? "1 student note was ignored" : "\(warnings.count) student notes were ignored")
                .foregroundStyle(Ink.secondary)
                .lineLimit(1)
            Button("Details…") { shown.toggle() }
                .buttonStyle(LinkStyle())
                .help("The student’s % R… lines that did not reach a comment, with where they are")
                .popover(isPresented: $shown, arrowEdge: .bottom) { NoteWarningsList(warnings: warnings, round: round, open: open) }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }
}

/// Each note not used: where it is (file:line), the comment line as the student wrote it, and the engine's sentence.
/// In the label colours, not the panel's secondary: a popover of a window that is not key is a lighter grey, on which
/// the secondary was faint in Dark Mode.
struct NoteWarningsList: View {
    let warnings: [NoteWarning]
    let round: Int
    var open = true

    /// Under the title (BACKLOG O32: "Lines such as % R1-03 in the source that reached no comment." set a line of
    /// source in the text's own font): what the list is, the lines themselves below it in monospace as written.
    static func intro(open: Bool) -> String {
        "These lines in the source matched no open comment." + (open ? " Tell the student in a follow-up if one matters." : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Student notes ignored in Round \(round)").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.label)
            Text(Self.intro(open: open))
                .font(.system(size: 11.5)).foregroundStyle(Ink.label2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(warnings.enumerated()), id: \.offset) { i, w in
                        VStack(alignment: .leading, spacing: 3) {
                            if let p = w.place {
                                Text(p).font(.system(size: 11).monospaced()).foregroundStyle(Ink.label2)
                            }
                            if let t = w.text, !t.isEmpty {
                                Text(t).font(.system(size: 12).monospaced()).foregroundStyle(Ink.label)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Text(w.message).font(.system(size: 12)).foregroundStyle(Ink.label2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .textSelection(.enabled)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .top) {
                            if i > 0 { Rectangle().fill(Color(nsColor: Palette.rule)).frame(height: 1) }
                        }
                    }
                }
            }
            .frame(maxHeight: 440)  // four notes whole (integration 2026-10-18: at 340 the fourth's sentence was cut)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
        }
        .padding(14)
        .frame(width: 380, alignment: .leading)
    }
}

/// A closed round is read only (UX.md §17; design/ui-v2/PROPOSAL.md §3): a neutral box under the tabs, inset as in the
/// mockup's 06f (visual review 2026-10-18: it ran across the panel above the tabs), "Round 2 · closed Oct 9 · read
/// only", with the way back to the latest round while an earlier one is shown.
struct ReadOnlyBanner: View {
    let round: RoundInfo
    @EnvironmentObject var model: AppModel

    static func words(_ round: RoundInfo, readOnly: Bool, day: Bool = true) -> String {
        "Round \(round.n) · closed" + (day ? shortDate(round.closedAt).map { " " + $0 } ?? "" : "") + (readOnly ? " · read only" : "")
    }

    var body: some View {
        HStack(spacing: 8) {
            // a lock says read only; the words say it too when there is room, never cut off (the UI audit: "read o…")
            Image(systemName: "lock").foregroundStyle(Ink.secondary)
            ViewThatFits(in: .horizontal) {
                Text(Self.words(round, readOnly: true))
                Text(Self.words(round, readOnly: false))
                Text(Self.words(round, readOnly: false, day: false))  // beside Resume Round N in a narrow panel
            }
            .foregroundStyle(Ink.label2)
            .lineLimit(1)
            .help("Round \(round.n) is closed: read only")
            Spacer(minLength: 4)
            if model.viewingEarlierRound, let latest = model.latestRound?.n {
                Button("Back to Round \(latest)") { model.showRound(latest) }
                    .controlSize(.small)
                    .help("Show Round \(latest), the latest")
            } else if model.canResumeShown {
                // the latest round, finished, until the student's next version starts the next one (UX.md §31)
                Button("Resume Round \(round.n)") { model.askResume() }
                    .controlSize(.small)
                    .fixedSize()
                    .help("Open Round \(round.n) again to add and change comments, then finish it again")
            }
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 34)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: Palette.chipFill)))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

/// The panel's toast (UX.md §8; design/ui-v2 mockup §5): what an answer did and the button that takes it back (Undo;
/// Redo after an undo; the keys in their help tags), as a dark pill (a light one in Dark Mode) at the bottom of the
/// panel, above the answer row while that is pinned there; in Focus 12 pt under the one card, by its buttons
/// (`ToastPlace`). It also says "Still loading…" when an action waits for the engine (`AppModel.refusedWhileBusy`).
/// The pointer on Undo keeps it shown; the rest of it takes no clicks, so a row under it can still be clicked.
struct PanelToastView: View {
    @ObservedObject var toast: PanelToast
    @ObservedObject var place: ToastPlace
    let actions: CardActions

    var body: some View {
        if let t = toast.text {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    // what was done, by its sign (POLISH §2.5: "✓ R1-06 resolved"): an answer given or given again, or
                    // one taken back
                    if let a = toast.action {
                        Image(systemName: a == .undo ? "checkmark" : "arrow.uturn.backward").font(.system(size: 11, weight: .semibold))
                    }
                    Text(t).font(.system(size: 12, weight: .medium))
                }
                .allowsHitTesting(false)
                if let a = toast.action {
                    // the link style is an AppKit button, as the card's Edit and Discard; on a quiet capsule of its own,
                    // so it reads as a button (visual review 2026-10-18)
                    Button(a == .undo ? "Undo" : "Redo") { a == .undo ? actions.undo() : actions.redo() }
                        .buttonStyle(.link)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(nsColor: Palette.toastText))
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background(Capsule().fill(Color(nsColor: Palette.toastText).opacity(0.16)).allowsHitTesting(false))
                        .padding(.trailing, -6)
                        .help(a == .undo ? "Undo this answer (⌘Z)" : "Give the answer again (⇧⌘Z)")
                        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { toast.buttonFrame = $0 }
                        .onHover { actions.holdToast($0) }
                }
            }
            .foregroundStyle(Color(nsColor: Palette.toastText))
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background {
                Capsule().fill(Color(nsColor: Palette.toast)).shadow(color: .black.opacity(0.18), radius: 7, y: 4)
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, 12)
            .padding(.top, place.below ?? 0)
            .padding(.bottom, place.below != nil ? 0 : place.bottom)
            .frame(maxHeight: place.below != nil ? .infinity : nil, alignment: .top)
            .transition(.opacity)
        }
    }
}

/// Where the panel's toast goes in Focus (review 2026-10-18): the one card sits at the panel's top, so at the panel's
/// foot the toast (an answer's, or "Still loading…") was some 550 pt from the buttons clicked. `below`: from the list's
/// top, 12 pt under the card's foot, set by the list's table as it lays the card out and scrolls; nil (Review, no card,
/// or a card that leaves no room under it): at the panel's foot. Only the toast observes it.
///
/// `bottom`, in Review: from the panel's foot, 16 pt, 56 while the answer row is pinned there (UX.md §2), and above a
/// group's header that it would cover (BACKLOG O28: the Undo toast over "Closed this round", where the answered card
/// had just gone), once only. Set by the shown list's table only (`PanelTable.updateToastPlace`).
@MainActor
final class ToastPlace: ObservableObject {
    @Published var below: CGFloat?
    @Published var bottom: CGFloat = 16
    /// The toast's height, about (12 pt type, 6 pt above and below; 20 pt with Undo's capsule).
    static let height: CGFloat = 32

    /// Where the toast's foot goes, from the panel's foot: `base` (16, or 56 over a pinned answer row), or 6 pt above
    /// the lowest header (`headers`: their tops and bottoms from the list's visible top) that the toast would cover
    /// there in a list `height` tall. Only that one: lifted again above each header it then covered, the toast could
    /// end up far from the foot, over a card's row (review, 2026-10-18: 141 pt up, over R1-13).
    /// `answers`: the expanded card's answer row (and field), from the visible top: the toast never covers it, but
    /// goes 8 pt above it (the UI audit: right after an answer it sat on the next card's Follow up and its field).
    static func bottom(base: CGFloat, height: CGFloat, headers: [(top: CGFloat, bottom: CGFloat)],
                       answers: (top: CGFloat, bottom: CGFloat)? = nil) -> CGFloat {
        func covers(_ b: CGFloat, _ o: (top: CGFloat, bottom: CGFloat)) -> Bool {
            let zoneTop = height - b - Self.height, zoneBottom = height - b
            return o.bottom > zoneTop - 2 && o.top < zoneBottom + 2
        }
        let seen = answers.flatMap { $0.bottom > 0 && $0.top < height ? $0 : nil }
        // the lowest thing covered: 6 pt above a header, 8 pt above the answer row; then above the row if still on it
        let things = headers.map { (top: $0.top, bottom: $0.bottom, gap: CGFloat(6)) }
            + (seen.map { [(top: $0.top, bottom: $0.bottom, gap: CGFloat(8))] } ?? [])
        var b = base
        if let h = things.filter({ covers(base, ($0.top, $0.bottom)) }).max(by: { $0.top < $1.top }) { b = height - h.top + h.gap }
        if let a = seen, covers(b, a) { b = height - a.top + 8 }
        return min(b, max(base, height - Self.height - 4))  // never above the list's top
    }
}

/// Lays out one view at the width it is offered (never below its narrowest) and at its own height, measuring it only
/// when it changes. For the panel's tabs: until UI v2.2 an NSSegmentedControl, whose size came from CoreUI each time
/// SwiftUI asked, and the panel's stacks asked it up to 200 times on every J/K step (anything moving in the panel lays
/// the panel out again); `PanelTabs` is SwiftUI's own text now, still measured once.
struct MeasuredOnce: Layout {
    struct Cache {
        var ideal: CGSize?
        var minWidth: CGFloat = 0
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = Cache() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        guard let view = subviews.first else { return .zero }
        if cache.ideal == nil {
            cache.ideal = view.sizeThatFits(.unspecified)
            cache.minWidth = view.sizeThatFits(ProposedViewSize(width: 0, height: nil)).width
        }
        let ideal = cache.ideal ?? .zero
        return CGSize(width: proposal.width.map { max($0, cache.minWidth) } ?? ideal.width, height: ideal.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// The sign before a group's name (POLISH §7): whose move the group is, as the rows' chips and the PDF's labels say it.
enum HeaderGlyph: Equatable {
    case none
    /// ○, amber in an open round (the advisor's move, the one amber of the list), grey in a closed one (Left open).
    case toCheck(open: Bool)
    /// What goes to the student in the round’s final.pdf.
    case student
    case closed
    /// The Changes tab's edits that answer comments.
    case answering
    /// A group by tag (UX.md §27): the tag's sign (its name's letter without one), in the secondary colour.
    case tag(String?, String)
    /// A group by section: its number where the others have a sign ("" for none, so the names still line up).
    case number(String)

    var symbol: String? {
        switch self {
        case .none, .tag, .number: return nil
        case .toCheck: return "circle"
        case .student: return "envelope"
        case .closed: return "checkmark.circle"
        case .answering: return "text.bubble"
        }
    }

    var color: Color {
        if case .toCheck(let open) = self { return Color(nsColor: open ? Palette.toCheck : Palette.neutral) }
        return Ink.secondary
    }
}

/// The pointer over a group's header and a click held on it (`HeaderHost`); only that header observes it.
@MainActor
final class HeaderState: ObservableObject {
    @Published var hovering = false
    @Published var pressed = false
}

/// A group's header (POLISH §7, after the advisor's use: at 12 pt it was smaller than the rows and read as one of
/// them): 34 pt on the panel's opaque grey with a hairline under it, still floating; the group's sign (12 Semibold),
/// its name 14 Semibold in the label colour, a folded group's count in a capsule (shown or folded), the quieter words
/// after it (12, secondary; they give way first), and a folded group's Show › / Hide ⌄ on the right. A folded group's
/// whole header is its button (`HeaderHost`), with the rows' hover fill under the pointer. Headers never dim.
///
/// Its edges are the rows' (review 2026-10-18: they lined up with nothing): the sign starts at the rows' content edge,
/// where their chips' signs and their notes start (`SectionHeader.lead` from the panel's edge), the bars hanging left of
/// it as under a row; the name after a column as wide as the widest sign, so every header's name starts at the same
/// place; Show › / Hide ⌄ ends where the rows' page numbers end.
struct SectionHeader: View {
    /// From the panel's edge to the sign: the list's 10 and the rows' 16 (CompactRow, ChangeRow).
    static let lead: CGFloat = 26
    /// The sign's column, the widest sign (`envelope` at 12 pt, 18 pt) and 5 pt before the name.
    static let signColumn: CGFloat = 23

    /// A header's quieter words, longest first, each a little shorter: "goes in the Round 2 final.pdf", "in the
    /// Round 2 final.pdf", "Round 2 final.pdf".
    static func forms(_ sub: String) -> [String] {
        var out = [sub]
        if sub.hasPrefix("goes ") { out.append(String(sub.dropFirst(5))) }
        if let last = out.last, last.hasPrefix("in the ") { out.append(String(last.dropFirst(7))) }
        return out
    }

    let text: String
    var sub = ""
    var count: Int? = nil
    var glyph: HeaderGlyph = .none
    var button: String? = nil  // a folded group's Show / Hide
    var action: (() -> Void)? = nil
    @ObservedObject var state: HeaderState
    @Environment(\.displayScale) private var scale

    var body: some View {
        HStack(spacing: 0) {
            if let symbol = glyph.symbol {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(glyph.color)
                    .frame(width: Self.signColumn, alignment: .leading)
            } else if case .tag(let sign, let name) = glyph {
                TagSign(sign: sign, name: name, size: 12).foregroundStyle(Ink.secondary)
                    .frame(width: Self.signColumn, alignment: .leading)
            } else if case .number(let n) = glyph {
                Text(n).font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(Ink.secondary)
                    .frame(width: Self.signColumn, alignment: .leading)
            }
            Text(text).font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.label).layoutPriority(2)
            if let count {
                Text("\(count)").font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(Ink.label2)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 17, minHeight: 17)
                    .background(Capsule().fill(Color(nsColor: Palette.chipFill)))
                    .padding(.leading, 7)
                    .layoutPriority(2)
            }
            if !sub.isEmpty {
                // its short form when the whole does not fit ("in the Round 2 final.pdf", then "Round 2 final.pdf"; the UI
                // audit: "goes in the Round 2 em…" at the default panel width)
                ViewThatFits(in: .horizontal) {
                    ForEach(Self.forms(sub), id: \.self) { Text($0) }
                }
                .font(.system(size: 12)).foregroundStyle(Ink.secondary).truncationMode(.tail).padding(.leading, 8)
            }
            Spacer(minLength: 8)
            if let button {
                HStack(spacing: 3) {
                    Text(button)
                    Image(systemName: button == "Hide" ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Ink.secondary)
                .fixedSize()
                .layoutPriority(2)
            }
        }
        .lineLimit(1)
        .padding(.leading, Self.lead - 10)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background {
            if button != nil && (state.hovering || state.pressed) {
                RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: state.pressed ? Palette.chipFill : Palette.hover))
                    .padding(.vertical, 3)
            }
        }
        .padding(.horizontal, 10)  // as the rows, whose hover fill starts here
        .frame(height: PanelScroller.header)
        .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: Palette.rule)).frame(height: 1 / max(scale, 1)) }
        .background(Color(nsColor: Palette.panel))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(([text] + (count.map { [String($0)] } ?? []) + (sub.isEmpty ? [] : [sub])).joined(separator: ", "))
        .accessibilityAddTraits(button == nil ? .isHeader : [.isHeader, .isButton])
        .accessibilityHint(button.map { $0 == "Hide" ? "Hides the group" : "Shows the group" } ?? "")
        .accessibilityAction { action?() }
    }
}

/// A group header's view in the panel's table (UX.md §1): a folded group's whole header is its Show / Hide. The click
/// and the pointer are AppKit's here, as a floating group row needs: a click that ends over the header folds or unfolds
/// the group once (a double click's second click does nothing, as on the cards' buttons), and the pointer over it
/// shows the hover fill. A header that does not fold takes no clicks.
final class HeaderHost: NSHostingView<AnyView> {
    let state = HeaderState()
    var onClick: (() -> Void)?
    private var area: NSTrackingArea?

    required init(rootView: AnyView) { super.init(rootView: rootView) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard onClick != nil else { return super.hitTest(point) }
        return frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let onClick else { return super.mouseDown(with: event) }
        guard event.clickCount == 1 else { return }
        // tracked to the mouse-up, as a button tracks it: the click counts if it ends over the header
        state.pressed = true
        var inside = true
        while let e = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            inside = bounds.contains(convert(e.locationInWindow, from: nil))
            if state.pressed != inside { state.pressed = inside }
            if e.type == .leftMouseUp { break }
        }
        state.pressed = false
        if inside { onClick() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self,
                               userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if onClick != nil && !state.hovering { state.hovering = true }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if state.hovering { state.hovering = false }
    }
}

/// The done card at the top of the comment list (POLISH §3 row 9, §6 decision 10): once nothing is left in the round
/// (no comment or other edit to check, no changed paragraph to read; `AppModel.readyToFinish`), a calm card with no
/// numbers (the groups below say them) and a plain Finish Round… button: the toolbar's is the window's one prominent
/// button.
struct DoneCard: View {
    let round: Int
    let finish: () -> Void
    /// Where its button is, in the card's view (--debug-script doneclick).
    var buttonFrame: ((CGRect) -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "checkmark.circle").font(.system(size: 26, weight: .light)).foregroundStyle(Color(nsColor: Palette.neutral))
            Text("Nothing left to check in this round.").font(.system(size: 15, weight: .semibold)).padding(.top, 8)
            Text("Finish when you are ready.").font(.system(size: 12.5)).foregroundStyle(Ink.secondary).padding(.top, 4)
            Button("Finish Round \(round)…", action: finish)
                .help("Write final.pdf and close Round \(round)")
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("done")) }) { buttonFrame?($0) }
                .padding(.top, 12)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)  // centred in the card (RaisedCard sets its content at the leading edge)
        .padding(.vertical, 6)
        .modifier(RaisedCard())
        .foregroundStyle(Ink.label)
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .coordinateSpace(name: "done")
    }
}

/// An open round with no comments yet (POLISH §3 row 15): what to do first, in words a mouse can follow (POLISH §6:
/// no key caps).
struct EmptyComments: View {
    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "highlighter").font(.system(size: 22, weight: .light)).foregroundStyle(Ink.secondary)
            Text("No comments yet").font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.label).padding(.top, 6)
            Text("Select text in the PDF, then click Comment.\nHold Option and drag round a figure, table or equation.\n"
                 + "Pick the colour on the bar over the selection.")
                .font(.system(size: 12.5)).foregroundStyle(Ink.secondary).lineSpacing(3.5).padding(.top, 4)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 28)
        .padding(.bottom, 16)
    }
}

/// Focus with no comment (or edit) selected (POLISH §7): the panel says what to click, in mouse words.
struct FocusHint: View {
    let changes: Bool

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "cursorarrow.click").font(.system(size: 22, weight: .light)).foregroundStyle(Ink.secondary)
            Text(changes ? "No edit selected" : "No comment selected").font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Ink.label).padding(.top, 6)
            Text(changes ? "Click a changed passage in the page to show it here." : "Click a comment’s mark in the page to show it here.")
                .font(.system(size: 12.5)).foregroundStyle(Ink.secondary).lineSpacing(3.5).padding(.top, 4)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 28)
        .padding(.bottom, 16)
    }
}

// MARK: Comments

/// The comment list: a PanelTable that follows PanelModel itself, so SwiftUI never re-renders it.
struct CommentList: NSViewRepresentable {
    let panel: PanelModel
    let actions: CardActions
    let edit: EditState

    func makeCoordinator() -> CommentListController { CommentListController(panel: panel, actions: actions, edit: edit) }
    func makeNSView(context: Context) -> NSScrollView { context.coordinator.table.scrollView }
    func updateNSView(_ v: NSScrollView, context: Context) {}
}

/// Hands PanelModel's groups to the table (UX.md §1): To check, then For the student and Closed this round, folded; the
/// done card on top once nothing is left, the empty state while there are no comments. In Focus (POLISH §7) only the
/// expanded card's row, at the top, or what to click when there is none.
@MainActor
final class CommentListController {
    let table: PanelTable
    private var lists: (groups: CardGroups, showClosed: Bool, showStudent: Bool, open: Bool, round: Int, ready: Bool,
                        focus: Bool, expanded: String?)
    private var subscriptions: Set<AnyCancellable> = []

    init(panel: PanelModel, actions: CardActions, edit: EditState) {
        table = PanelTable(scroller: panel.scroller, expanded: panel.expanded, compact: { item, look in
            switch item {
            case .card(let c):
                return AnyView(CompactRow(card: c, look: look).equatable().onTapGesture { actions.rowClicked(c.id) }
                    .padding(.horizontal, 10))
            case .line(let c):
                return AnyView(ClosedLine(card: c, look: look).equatable().onTapGesture { actions.rowClicked(c.id) }
                    .padding(.horizontal, 10))
            case .change:
                return AnyView(EmptyView())
            }
        }, expandedView: { item in
            guard let c = item.card else { return AnyView(EmptyView()) }
            return AnyView(ExpandedCard(card: c, actions: actions).equatable().environmentObject(edit)
                .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 8))
        })
        lists = (panel.groups, panel.showClosed, panel.showStudent, panel.roundOpen, panel.round, panel.ready, panel.focus,
                 panel.expanded)
        table.pin = actions.pin
        table.toastPlace = actions.toastPlace
        table.toastUnderCard = panel.focus
        table.dims = true
        table.onFold = { actions.toggleFold($0) }
        table.onFinish = { actions.finish() }
        table.show(rows())
        // @Published sends in willSet: the new value comes as the argument, the model still has the old one.
        panel.$groups.dropFirst().sink { [weak self] v in self?.lists.groups = v; self?.update() }.store(in: &subscriptions)
        panel.$showClosed.dropFirst().sink { [weak self] v in self?.lists.showClosed = v; self?.update() }.store(in: &subscriptions)
        panel.$showStudent.dropFirst().sink { [weak self] v in self?.lists.showStudent = v; self?.update() }.store(in: &subscriptions)
        panel.$roundOpen.dropFirst().sink { [weak self] v in self?.lists.open = v; self?.update() }.store(in: &subscriptions)
        panel.$round.dropFirst().sink { [weak self] v in self?.lists.round = v; self?.update() }.store(in: &subscriptions)
        panel.$ready.dropFirst().sink { [weak self] v in self?.lists.ready = v; self?.update() }.store(in: &subscriptions)
        panel.$focus.dropFirst().sink { [weak self] v in
            self?.lists.focus = v
            self?.update()
            if v { self?.table.scrollToTop() }
            self?.table.toastUnderCard = v
        }.store(in: &subscriptions)
        panel.$expanded.dropFirst().sink { [weak self] id in
            guard let self else { return }
            lists.expanded = id
            if lists.focus { update() }  // the one row is the new card's
            table.setExpanded(id)
            if lists.focus { table.scrollToTop() }
        }.store(in: &subscriptions)
    }

    private func update() { table.show(rows()) }

    /// The rows shown: in Focus, the expanded card's own row (as the list has it) or the hint.
    func rows() -> [PanelTable.Row] {
        let all = groupRows()
        guard lists.focus else { return all }
        if let id = lists.expanded, let row = all.first(where: { $0.cardID == id }) { return [row] }
        return [.focusHint(changes: false)]
    }

    private func groupRows() -> [PanelTable.Row] {
        let (g, _, _, open, round, ready, _, _) = lists
        // once the last card answered has left To check, as an answered card does when the selection leaves it: shown
        // above a card still held there, it pushed that card down under the pointer (a short list cannot scroll back)
        let r: [PanelTable.Row] = ready && g.toCheck.isEmpty ? [.done(round: round)] : []
        if open && g.toCheck.isEmpty && g.forStudent.isEmpty && g.closed.isEmpty { return r + [.empty] }
        guard g.grouping == .status, g.filter == nil else { return PanelTable.spaced(r + arranged(g, round: round)) }
        return PanelTable.spaced(r + statusRows(g, round: round, filtered: false))
    }

    /// The three groups by status, from `g.shown`. `filtered` (a tag shown alone, UX.md §27): only the cards kept, and
    /// a group none of them is in not listed (no hint about commenting: the filter hides the rest).
    private func statusRows(_ g: CardGroups, round: Int, filtered: Bool) -> [PanelTable.Row] {
        let (_, showClosed, showStudent, open, _, _, _, _) = lists
        let (check, student, closed) = (g.shown[0].cards, g.shown[1].cards, g.shown[2].cards)
        var r: [PanelTable.Row] = []
        if !check.isEmpty {
            // the Comments tab carries the count (POLISH §4.4: each number once)
            r.append(.header(open ? "To check" : "Left open", glyph: .toCheck(open: open)))
            r += check.map { .item(.card($0)) }
        }
        // folded into one line with its count, as Closed this round (POLISH §6); with no card, its header and the hint
        // (mouse first, POLISH §6)
        if !student.isEmpty {
            r.append(.fold("For the student", showStudent ? "Hide" : "Show",
                           sub: open ? "goes in the Round \(round) final.pdf" : "in the Round \(round) final.pdf", group: .student,
                           count: student.count, glyph: .student))
        } else if open && !filtered {
            r.append(.header("For the student", glyph: .student))
        }
        if showStudent || student.isEmpty {
            r += student.map { .item(.card($0)) }
            if open && !filtered && !student.contains(where: { !$0.carried }) {
                r.append(.hint("To comment, select text in the PDF and click Comment."))
            }
        }
        if !closed.isEmpty {
            r.append(.fold("Closed this round", showClosed ? "Hide" : "Show", group: .closed, count: closed.count, glyph: .closed))
            if showClosed { r += closed.map { .item(.line($0)) } }
        }
        return r
    }

    /// The groups filtered on a tag, or by tag or by section (UX.md §27). By status with a filter: the three groups as
    /// above (`statusRows`). By tag or by section: a plain header a group, its count in the capsule, every card as a
    /// row (a closed one too, its bar faded: a 30 pt line would turn into a row when it is reopened). A filter that
    /// keeps nothing says so.
    private func arranged(_ g: CardGroups, round: Int) -> [PanelTable.Row] {
        var r: [PanelTable.Row] = []
        if g.grouping == .status, g.shown.count == 3 {
            r = statusRows(g, round: round, filtered: true)
        } else {
            for s in g.shown where !s.cards.isEmpty {
                r.append(.header(s.title, sub: s.sub, count: s.cards.count, glyph: s.glyph))
                // by tag, a row does not repeat its header's sign
                let under: String? = { if case .tag(let id) = s.key { return id } else { return nil } }()
                r += s.cards.map { c in
                    var c = c
                    c.listedUnder = under
                    return .item(.card(c))
                }
            }
        }
        if let f = g.filter, g.shown.allSatisfy(\.cards.isEmpty) {
            r.append(.hint(f == TagCatalog.untagged ? "Every comment of Round \(round) has a tag now."
                           : "No comment of Round \(round) has this tag now."))
        }
        return r
    }
}

// MARK: Changes

/// The Changes tab's one sentence on top (UX.md §16; POLISH §3 row 10, §4.4): whether edits no comment asked for are
/// left to check, without their number, which the tab says, then how many more answer comments. nil in round 1 and
/// when the source did not change (the list says so).
enum ChangesHeader {
    static func text(_ state: EngineState?, left: Int) -> AttributedString? {
        guard let st = state, let n = st.round?.n, n > 1, !st.changes.isEmpty else { return nil }
        let u = st.changes.filter(\.unrequested).count, a = st.changes.count - u
        guard st.round?.closed == false else {  // what there was, asking for nothing
            return AttributedString("Edits made since R\(n - 1): \(u) no comment asked for, \(a) answering your comments.")
        }
        let more = a == 0 ? "" : " \(count(a, "more edit")) answer\(a == 1 ? "s" : "") your comments."
        var lead: AttributedString, rest: String
        if left > 0 {
            // in the label colour, not amber (POLISH §6, 3); how many is the tab's to say (§4.4)
            lead = AttributedString(left == 1 ? "An edit to check." : "Other edits to check.")
            rest = (left == 1 ? " No comment asked for it." : " No comment asked for them.") + more
        } else if u > 0 {
            lead = AttributedString("All checked.")
            rest = " The \(count(u, "edit")) no comment asked for \(u == 1 ? "is" : "are") checked, commented on or read." + more
        } else {
            lead = AttributedString("Nothing to check.")
            rest = " Every edit since R\(n - 1) answers one of your comments."
        }
        lead.font = .system(size: 12.5, weight: .semibold)
        lead.foregroundColor = Ink.label
        return lead + AttributedString(rest)
    }
}

/// The change list: a PanelTable that follows ChangePanel itself (UX.md §16).
struct ChangeList: NSViewRepresentable {
    let panel: ChangePanel
    let actions: CardActions
    let edit: EditState

    func makeCoordinator() -> ChangeListController { ChangeListController(panel: panel, actions: actions, edit: edit) }
    func makeNSView(context: Context) -> NSScrollView { context.coordinator.table.scrollView }
    func updateNSView(_ v: NSScrollView, context: Context) {}
}

/// Hands ChangePanel's changes to the table: unrequested first, then those linked to comments; in Focus only the
/// expanded change's row, or what to click.
@MainActor
final class ChangeListController {
    let table: PanelTable
    private var lists: (unrequested: [ChangeModel], linked: [ChangeModel], showLinked: Bool, hint: String, open: Bool,
                        focus: Bool, expanded: String?)
    private var subscriptions: Set<AnyCancellable> = []

    init(panel: ChangePanel, actions: CardActions, edit: EditState) {
        table = PanelTable(scroller: panel.scroller, expanded: panel.expanded, compact: { item, look in
            guard case .change(let c) = item else { return AnyView(EmptyView()) }
            return AnyView(ChangeRow(change: c, look: look).equatable().onTapGesture { actions.changeClicked(c.id) }.padding(.horizontal, 10))
        }, expandedView: { item in
            guard case .change(let c) = item else { return AnyView(EmptyView()) }
            return AnyView(ChangeCard(change: c, actions: actions).equatable().environmentObject(edit)
                .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 8))
        })
        lists = (panel.unrequested, panel.linked, panel.showLinked, panel.hint, panel.roundOpen, panel.focus, panel.expanded)
        table.onFold = { actions.toggleFold($0) }
        table.toastPlace = actions.toastPlace
        table.toastUnderCard = panel.focus
        table.show(rows())
        panel.$unrequested.dropFirst().sink { [weak self] v in self?.lists.unrequested = v; self?.update() }.store(in: &subscriptions)
        panel.$linked.dropFirst().sink { [weak self] v in self?.lists.linked = v; self?.update() }.store(in: &subscriptions)
        panel.$showLinked.dropFirst().sink { [weak self] v in self?.lists.showLinked = v; self?.update() }.store(in: &subscriptions)
        panel.$hint.dropFirst().sink { [weak self] v in self?.lists.hint = v; self?.update() }.store(in: &subscriptions)
        panel.$roundOpen.dropFirst().sink { [weak self] v in self?.lists.open = v; self?.update() }.store(in: &subscriptions)
        panel.$focus.dropFirst().sink { [weak self] v in
            self?.lists.focus = v
            self?.update()
            if v { self?.table.scrollToTop() }
            self?.table.toastUnderCard = v
        }.store(in: &subscriptions)
        panel.$expanded.dropFirst().sink { [weak self] id in
            guard let self else { return }
            lists.expanded = id
            if lists.focus { update() }
            table.setExpanded(id)
            if lists.focus { table.scrollToTop() }
        }.store(in: &subscriptions)
    }

    private func update() { table.show(rows()) }

    func rows() -> [PanelTable.Row] {
        let all = groupRows()
        guard lists.focus else { return all }
        if let id = lists.expanded, let row = all.first(where: { $0.cardID == id }) { return [row] }
        return [.focusHint(changes: true)]
    }

    private func groupRows() -> [PanelTable.Row] {
        let (unrequested, linked, showLinked, hint, open, _, _) = lists
        var r: [PanelTable.Row] = hint.isEmpty ? [] : [.hint(hint)]
        // the sentence on top says how many (ChangesHeader): the headers do not say it again (UX.md §16); with every
        // edit handled ("All checked.") nothing is the advisor's move, as in a closed round
        if !unrequested.isEmpty {
            let left = open && unrequested.contains { !$0.handled }
            r.append(.header(left ? "To check" : "No comment asked for", glyph: .toCheck(open: left)))
            r += unrequested.map { .item(.change($0)) }
        }
        if !linked.isEmpty {
            r.append(.fold("Answering your comments", showLinked ? "Hide" : "Show", group: .linked, glyph: .answering))
            if showLinked { r += linked.map { .item(.change($0)) } }
        }
        return PanelTable.spaced(r)
    }
}
