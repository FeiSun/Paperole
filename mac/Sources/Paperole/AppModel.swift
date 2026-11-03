import AppKit
import Combine
import UniformTypeIdentifiers

/// The panel's tabs; Checks only while Settings › Reading's Checks is on (UX.md §39).
enum PanelTab: String { case comments, changes, checks }

enum Selection: Equatable {
    case comment(String)
    case change(String)
}

/// What the comment list shows. Only the list observes it, so busy state, progress, the PDF selection and the
/// editors never redraw the list (UX.md §10.5).
@MainActor
final class PanelModel: ObservableObject {
    @Published var groups = CardGroups()
    @Published var showClosed = false  // the Closed this round group, folded until shown
    @Published var showStudent = false  // the For the student group, folded until shown too (POLISH §6)
    @Published var expanded: String?
    @Published var round = 0
    @Published var roundOpen = false
    /// Nothing left in the open round (`AppModel.readyToFinish`): the done card heads the list (POLISH §3 row 9).
    @Published var ready = false
    /// Focus (POLISH §7): the list shows only the expanded card.
    @Published var focus = false
    let scroller = PanelScroller()
    /// Every card, carried then new, and the group the expanded card stays in until the selection leaves it.
    var cards: [CardModel] = []
    var held: (id: String, group: CardGroups.Group)?
    /// How the list is arranged and the tag it shows only (UX.md §27; `groups` carries them, so only the list follows),
    /// the group of the arrangement the expanded card stays in while selected (by tag or section), and where each
    /// comment is in the paper.
    var grouping = ListGrouping.status
    var filter: String?
    var heldKey: ListKey?
    var sections = ListSections()

    var all: [CardModel] { cards }
    /// The cards J and K go through, in the list's order: a folded group is skipped.
    var listed: [CardModel] { groups.listed(showClosed: showClosed, showStudent: showStudent) }
}

/// A group that folds into its header line, with Show / Hide: For the student and Closed this round on the Comments
/// tab, the changes answering comments on the Changes tab.
enum FoldedGroup: String {
    case student, closed, linked
}

/// The comment list's groups (design/ui-v2/PROPOSAL.md §2, §6; UX.md §1): To check (the advisor's move), For the
/// student (follow-ups, then new comments: what final.pdf asks for), Closed this round (Resolved and Kept as is,
/// folded until shown). Pure, so it is unit-tested. `toCheck`, `forStudent` and `closed` are always every card by
/// status; `shown` is what the list shows (UX.md §27): those groups, or groups by tag or by section, with only the
/// cards the tag filter keeps (and the selected card, whatever its tags).
struct CardGroups: Equatable {
    enum Group: Hashable { case toCheck, forStudent, closed }

    /// A group as the list shows it: its key, its header's words and sign (by tag or section; the status groups' are
    /// the list's own), and its cards.
    struct Shown: Equatable {
        var key: ListKey
        var title = ""
        var sub = ""
        var glyph = HeaderGlyph.none
        var cards: [CardModel]
    }

    var toCheck: [CardModel] = []
    var forStudent: [CardModel] = []
    var closed: [CardModel] = []
    var grouping = ListGrouping.status
    /// A tag id, `TagCatalog.untagged` (Not tagged), or nil: every card.
    var filter: String?
    var shown: [Shown] = []

    /// `cards` in the list's order. `held`: the selected card, which stays in the group it was shown in until the
    /// selection leaves it, so no row moves under the pointer (`place`: its group by tag or section), and is listed
    /// whatever the filter. `catalog`: the tags' order and names; `sections`: where each comment is (by section).
    init(_ cards: [CardModel] = [], held: (id: String, group: Group)? = nil, place: ListKey? = nil,
         grouping: ListGrouping = .status, filter: String? = nil, catalog: TagCatalog = TagCatalog(),
         sections: ListSections = ListSections()) {
        for c in cards {
            switch held.flatMap({ $0.id == c.id ? $0.group : nil }) ?? Self.group(c.status) {
            case .toCheck: toCheck.append(c)
            case .forStudent: forStudent.append(c)
            case .closed: closed.append(c)
            }
        }
        self.grouping = grouping
        self.filter = filter
        let heldID = held?.id
        let keeps = { (c: CardModel) in filter.map { c.id == heldID || ListFilter.matches(c, $0) } ?? true }
        switch grouping {
        case .status:
            shown = [Shown(key: .status(.toCheck), cards: toCheck.filter(keeps)),
                     Shown(key: .status(.forStudent), cards: forStudent.filter(keeps)),
                     Shown(key: .status(.closed), cards: closed.filter(keeps))]
        case .tag, .section:
            let kept = sections.inPaperOrder(cards.filter(keeps))
            shown = grouping == .tag
                ? ListFilter.byTag(kept, held: heldID, place: place, filter: filter, catalog: catalog)
                : ListFilter.bySection(kept, held: heldID, place: place, sections: sections)
        }
    }

    /// Where a status belongs: Not found counts as To check, New goes with the follow-ups.
    static func group(_ s: Status) -> Group {
        switch s {
        case .toCheck, .notFound: return .toCheck
        case .new, .followUp: return .forStudent
        case .resolved, .keptAsIs: return .closed
        }
    }

    func group(of id: String) -> Group? {
        if toCheck.contains(where: { $0.id == id }) { return .toCheck }
        if forStudent.contains(where: { $0.id == id }) { return .forStudent }
        return closed.contains(where: { $0.id == id }) ? .closed : nil
    }

    /// The cards listed, in order: by status, a folded group is skipped; by tag or section nothing folds.
    func listed(showClosed: Bool, showStudent: Bool = true) -> [CardModel] {
        guard grouping == .status, shown.count == 3 else { return shown.flatMap(\.cards) }
        return shown[0].cards + (showStudent ? shown[1].cards : []) + (showClosed ? shown[2].cards : [])
    }

    /// The group of the arrangement a card is listed in, or nil (the filter hides it).
    func key(of id: String) -> ListKey? { shown.first { $0.cards.contains { $0.id == id } }?.key }

    /// After an answer on `id`: the next card to check below it, else the first one (wrapping); nil when no other is
    /// left. Only cards the list shows: by status the To check group as shown, by tag or section the cards to check in
    /// the list's order.
    func nextToCheck(after id: String) -> String? {
        if grouping == .status {
            let list = shown.first?.cards ?? toCheck
            guard let i = list.firstIndex(where: { $0.id == id }) else { return list.first?.id }
            return (list[(i + 1)...] + list[..<i]).first?.id
        }
        let all = shown.flatMap(\.cards)
        let i = all.firstIndex { $0.id == id }.map { $0 + 1 } ?? 0
        return (all[i...] + all[..<i]).first { $0.id != id && Self.group($0.status) == .toCheck }?.id
    }
}

/// The panel's toast after an answer (UX.md §8): what was done and the button that takes it back (Undo, or Redo after
/// an undo), for 2.5 s, longer while the pointer is on it. Only the toast observes it.
@MainActor
final class PanelToast: ObservableObject {
    enum Action { case undo, redo }

    @Published var text: String?
    @Published var action: Action?
    /// Where its button is, in the window's SwiftUI coordinates (--debug-script toastclick).
    var buttonFrame: CGRect?
}

/// What the Changes list shows (UX.md §16): unrequested changes first, then those linked to comments (folded until
/// shown). Only the list observes it.
@MainActor
final class ChangePanel: ObservableObject {
    @Published var unrequested: [ChangeModel] = []
    @Published var linked: [ChangeModel] = []
    @Published var showLinked = false
    @Published var hint = ""  // shown when there are no changes
    @Published var roundOpen = false
    @Published var expanded: String?
    /// Focus (POLISH §7): the list shows only the expanded change.
    @Published var focus = false
    let scroller = PanelScroller()

    /// The listed changes, in order (J/K).
    var all: [ChangeModel] { unrequested + (showLinked ? linked : []) }
}

/// The expanded card's editors and busy state. Only the expanded card observes it.
@MainActor
final class EditState: ObservableObject {
    enum Field: Equatable {
        case note(String)  // a new comment's note
        case remark(String)  // this round's follow-up or closing remark of a carried comment
    }

    /// The row a bare V or W shows on a card with text (UX.md §8): close with `text` (an unsent draft, or the follow-up
    /// `sent` this round) as the closing remark, or without it.
    struct Choice: Equatable {
        var id: String
        var verdict: String
        var text: String
        var sent: Bool
        /// false: asked where the answer moves nothing on (the PDF's menu on the mark, Focus), and so is its answer.
        var advance = true
    }

    @Published var field: Field?
    @Published var text = ""
    @Published var saving = false
    @Published var escArmed = false  // Esc once on a changed text: the next Esc discards it
    @Published var busy = false
    @Published var showAll: Set<String> = []  // the expanded card's sections and change's blocks shown whole; "fold": the folded line open
    /// The card whose source and edits show in a popover at its ⋯ button (⋯ › Source and Edits…).
    @Published var info: String?
    /// The card whose colour dot shows its mark's swatches and kinds in a popover (UX.md §8).
    @Published var swatches: String?
    @Published var roundOpen = false
    @Published var round = 0
    /// The expanded card's follow-up field (UX.md §8): its text (the card's unsent draft), the card whose field has
    /// focus, and a request for focus (R, Return; never a selection), dropped once the field has it.
    @Published var draft = ""
    @Published var fieldFocused: String?
    @Published var focusRequest: String?
    @Published var choice: Choice?
    /// Focus is on (POLISH §7): an answer does not move on, so the first-run tip, which says it does, waits for Review.
    @Published var focus = false
    /// The card whose tag picker is open (its + or a tag clicked; UX.md §24), and the picker's working set, written when
    /// it closes.
    @Published var tagging: String?
    var tagSelection: TagSelection?
    var original = ""

    var id: String? {
        switch field {
        case .note(let i)?, .remark(let i)?: return i
        case nil: return nil
        }
    }
}

/// The Finish sheet's state (UX.md §17): an error (the finish's), whether the finish is under way, and once it is
/// done the round's card, which the sheet turns into (`done`). Only the sheet observes it. `handled`: the drafts sent
/// or discarded in the sheet, whose rows stay where they were with what was done (a discarded one with Undo), so the
/// next draft's buttons never slide under the pointer; `guardUntil`: the sheet's draft buttons ignore clicks until
/// then, 0.4 s after one of them was clicked (interaction review 2026-10-18).
@MainActor
final class FinishPreview: ObservableObject {
    @Published var done: RoundCardAsk?
    @Published var error: String?
    @Published var finishing = false
    @Published var handled: [String: FinishSummary.Handled] = [:]
    var guardUntil: TimeInterval = 0
}

/// The pending mark style and the modes over the PDF; observed by the floating toolbar, the Comment menu and the
/// re-anchor bar.
@MainActor
final class ToolbarModel: ObservableObject {
    @Published var color: MarkColor
    @Published var kind: MarkKind
    @Published var boxArmed = false
    @Published var hasBox = false
    @Published var reanchor: String?
    @Published var reanchorError: String?
    /// At a find match the floating toolbar is the Comment button alone (design/review-page/BRIEF.md E5): the composer
    /// it opens has the swatches and kinds.
    @Published var matchOnly = false

    init() {
        color = MarkColor(name: Prefs.string("markColor") ?? "") ?? .yellow
        let k = MarkKind(rawValue: Prefs.string("markKind") ?? "") ?? .highlight
        kind = MarkKind.textKinds.contains(k) ? k : .highlight
    }

    /// A swatch or kind click (or 1–6, H/U/S) sets the pending style and remembers it.
    func setColor(_ c: MarkColor) {
        color = c
        Prefs.set(c.rawValue, "markColor")
    }

    func setKind(_ k: MarkKind) {
        guard MarkKind.textKinds.contains(k) else { return }
        kind = k
        Prefs.set(k.rawValue, "markKind")
    }
}

/// The one-time tips (POLISH §3 row 14; UI v4 BRIEF 03): Answer, under a card's answer buttons until Got it or the
/// first answer, and Follow anything, under the paper map until Got it or the first follow; then never again (the ids
/// seen, remembered in `tipsSeen`, except in a test run). Help › Show Tips Again shows both again. Only the tips observe it.
@MainActor
final class Tips: ObservableObject {
    enum ID: String, CaseIterable { case answer, follow }

    @Published private(set) var seen: Set<ID> = []
    private var remember = false
    private static let key = "tipsSeen"
    /// Before UI v4 only Answer: true reads as Answer seen while `tipsSeen` was never written. Kept, never removed.
    private static let legacy = "tipAnswerSeen"

    var answer: Bool { !seen.contains(.answer) }
    var follow: Bool { !seen.contains(.follow) }

    /// The ids seen from the stored list, else the legacy key.
    nonisolated static func seen(stored: [String]?, legacy: Bool?) -> Set<ID> {
        if let stored { return Set(stored.compactMap(ID.init(rawValue:))) }
        return legacy == true ? [.answer] : []
    }

    /// What was seen; from now on it is remembered when `remember` (not by a fixture run; Prefs skips a --background
    /// run).
    func load(remember: Bool) {
        self.remember = remember
        seen = remember ? Self.seen(stored: Prefs.strings(Self.key), legacy: Prefs.bool(Self.legacy)) : []
    }

    /// Got it, or the tip's first use. `remember: false`: gone for this run only (a perf run).
    func dismiss(_ id: ID, remember: Bool = true) {
        guard !seen.contains(id) else { return }
        seen.insert(id)
        if remember && self.remember { Prefs.set(seen.map(\.rawValue).sorted(), Self.key) }
    }

    /// Answer's tip, as before the tips were two.
    func dismiss(remember: Bool = true) { dismiss(.answer, remember: remember) }

    /// Help › Show Tips Again.
    func showAgain() {
        seen = []
        if remember { Prefs.set([String](), Self.key) }
    }
}

/// The card views' actions. One stable object, so passing it never makes a card redraw.
@MainActor
final class CardActions {
    weak var model: AppModel?
    /// The selected card's answer row, kept at the panel's bottom edge (UX.md §2).
    let pin = PinState()
    /// In Focus, the panel's toast under the one card (`ToastPlace`).
    let toastPlace = ToastPlace()
    /// The first-run tip under the answer buttons.
    let tips = Tips()

    func rowClicked(_ id: String) { model?.select(.comment(id), reveal: true, scroll: .minimal) }
    /// A card's page number or an edit's link: a look-up, a step of Back when it goes far (PLAN §5.2).
    func reveal(_ id: String) { if let c = model?.comment(id) { model?.pdf.reveal(page: c.page, rects: c.rects, step: .lookUp) } }
    func revealChange(_ id: String) {
        if let ch = model?.change(id) { model?.pdf.reveal(page: ch.page, rects: ch.rects, step: .lookUp) }
    }
    func changeClicked(_ id: String) { model?.select(.change(id), reveal: true, scroll: .minimal) }
    /// Mark checked (or Checked, which clears it): in Review it moves on to the next change to check, as V does, and
    /// that change's buttons ignore clicks for a moment (`ClickGuard`).
    func toggleChecked(_ id: String) {
        if let m = model, !m.clickIgnored(id) { m.toggleChecked(id, advance: !m.focus) }
    }
    func commentOnChange(_ id: String) { model?.commentOnChange(id) }
    func showComment(_ id: String) {
        model?.tab = .comments
        model?.select(.comment(id), scroll: .centre)
    }
    func editNote(_ id: String) { model?.beginNoteEdit(id) }
    func editRemark(_ id: String) { model?.beginRemarkEdit(id) }
    /// The card's colour dot: its swatches and kinds open (or close), in place of the ⋯ popover.
    func toggleSwatches(_ id: String) {
        guard let edit = model?.edit else { return }
        if edit.info != nil { edit.info = nil }
        edit.swatches = edit.swatches == id ? nil : id
    }
    /// A swatch or kind in the card's colour dot: applied at once, and the popover closes.
    func restyle(_ id: String, color: MarkColor? = nil, kind: MarkKind? = nil) {
        model?.edit.swatches = nil
        model?.setStyle(id, color: color, kind: kind)
    }
    /// A verdict button: with text in the field, "+ note" and Follow up act at once (VerdictPlan). An answer moves on
    /// to the next card to check, as from the keyboard (POLISH §6). The buttons of a card an answer just moved on to
    /// ignore clicks for a moment (`ClickGuard`), so a double click answers one card.
    func press(_ verdict: String, _ id: String) { if model?.clickIgnored(id) == false { model?.press(verdict, for: id, button: true) } }
    func choose(_ c: CloseChoice) {
        if let id = model?.edit.choice?.id, model?.clickIgnored(id) == false { model?.choose(c) }
    }
    func draftChanged(_ id: String, _ text: String) { model?.draftTyped(id, text) }
    /// Follow up with text in the field (a click), or ⌘↩ in it (`keyboard`, which no guard holds back).
    func sendDraft(_ id: String, keyboard: Bool = false) {
        if keyboard || model?.clickIgnored(id) == false { model?.sendDraft(id, advance: true) }
    }
    /// The field's Discard: the answer row moves up into the tag row's place, so the card's buttons ignore clicks for a
    /// moment, and a double click on Discard never closes the comment too.
    func discardDraft(_ id: String) {
        guard let m = model, !m.clickIgnored(id) else { return }
        m.setDraft(id, "")
        m.guardClicks(id)
    }
    /// The panel toast's Undo or Redo. Undo turns into Redo where it stands (and Redo into Undo), so for 0.4 s after one
    /// the other ignores clicks: a double click undoes once.
    func undo() { if toastClick() { model?.undo() } }
    func redo() { if toastClick() { model?.redo() } }
    private var toastGuard: TimeInterval = 0
    private func toastClick() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= toastGuard else { return false }
        toastGuard = now + ClickGuard.interval
        return true
    }
    /// The pointer on the panel's toast keeps it shown.
    func holdToast(_ held: Bool) { model?.holdPanelToast(held) }
    func fieldFocused(_ id: String) { model?.fieldFocused(id) }
    func fieldBlurred(_ id: String) { model?.fieldBlurred(id) }
    func leaveField() { model?.leaveField() }
    func commitEdit() { model?.commitEdit() }
    func cancelEdit() { model?.cancelEdit() }
    func focusLost() { model?.commitEdit(focusLost: true) }
    func reanchor(_ id: String) { model?.beginReanchor(id) }
    /// A section's Show all, or the thread's folded line ("fold").
    func toggleShowAll(_ block: String) {
        guard let e = model?.edit else { return }
        if e.showAll.contains(block) { e.showAll.remove(block) } else { e.showAll.insert(block) }
    }
    /// Show / Hide of a folded group.
    func toggleFold(_ g: FoldedGroup) { model?.toggleFold(g) }
    /// The done card's Finish Round….
    func finish() { model?.openFinish() }
    func moreMenu(_ id: String) { if let m = model { CardMenus.popUp(CardMenus.more(id, model: m)) } }
    /// The writing tags (UX.md §24): the catalogue, the card's picker, a suggestion taken, Reopen.
    weak var tagModel: TagModel?
    func openTags(_ id: String) { model?.openTagPicker(id) }
    func closeTags(_ id: String) { model?.closeTagPicker(id) }
    func acceptSuggestion(_ id: String, _ tag: String) { model?.acceptSuggestion(id, tag) }
    func reopen(_ id: String) { model?.revive(id) }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var papers: [PaperRef]
    /// Each listed paper's next step (F6): from `summaries` for the others, from its states for the selected paper.
    @Published private(set) var summaries: [String: PaperSummary] = [:]
    @Published private(set) var selectedPath: String?
    @Published private(set) var state: EngineState?
    @Published private(set) var busy = false {
        didSet {
            if edit.busy != busy { edit.busy = busy }
            syncCheckComment()
        }
    }
    @Published private(set) var progress = ""
    @Published var alertMessage: String?
    @Published var tab: PanelTab = .comments { didSet { if tab != oldValue { tabChanged() } } }
    /// Not published: a new selection redraws only the comment list (through PanelModel) and the Changes list (through
    /// ChangePanel), never the window around them (UX.md §10.5).
    private(set) var selection: Selection?
    @Published var showChanges = true
    @Published var hasPDFSelection = false { didSet { if hasPDFSelection { dropChoice() } } }
    /// The hierarchy's page shown instead of a paper (UX.md §22): All Students, Your Move or a student's page; no
    /// paper is selected meanwhile. Set only by `setHub`.
    @Published private(set) var hub: HubPage?
    /// The hierarchy's data: every listed paper's overview and the students' numbers.
    let hubModel = HubModel()
    /// The second engine process that fills in pending closed rounds (FEATURES E1b).
    let backfill = Backfill()
    /// The students whose papers are folded in the sidebar (their keys), remembered (never by a test run).
    @Published private(set) var foldedStudents: Set<String> = []
    static let foldedStudentsKey = "foldedStudents"
    /// All Students' Board or Students (UX.md §40.6): the viewer's choice, Board by default, remembered (never by a test
    /// run; `--all-view` sets it for a run).
    @Published var allStudentsView: AllStudentsView = .board {
        didSet { if allStudentsView != oldValue && options.allView == nil && fixtureURL == nil { Prefs.set(allStudentsView.rawValue, Self.allStudentsViewKey) } }
    }
    static let allStudentsViewKey = "allStudentsView"
    /// The app became active again (a paper may have changed from the command line): the hierarchy asks again.
    private(set) var activations = 0
    /// Rounds whose paragraphs were found in this run (by the second engine process, or by Review's own `prose` for the
    /// round it shows): the overviews had them pending, so the hierarchy asks again when next shown.
    private(set) var roundsFound = 0
    /// Your Move's Finish Round N…: that paper's Finish sheet opens once its state is in.
    var pendingFinish: String?
    /// The sheets of the hierarchy: Edit Paper… (a paper's path), Rename Student… and Map Headings… (a student's key).
    @Published var editingPaper: String?
    @Published var renamingStudent: String?
    @Published var mappingHeadings: String?
    /// Tag Comments… (UX.md §24): the sheet's comments, of the paper shown or of a student's papers.
    @Published var tagComments: TagCommentsModel?
    /// Focus, the reading mode (POLISH §3 row 5, §4.3, §6, §7): the sidebar hidden, the page larger, and the panel
    /// showing only the selected card; an answer there moves neither the PDF nor the selection. The toolbar's Focus
    /// button and F switch it at once (`setFocus`).
    @Published private(set) var focus = false
    /// The sidebar shown outside Focus: its system toggle and View › Show Sidebar set it, Focus hides it for a while.
    @Published private(set) var sidebarShown = true
    /// In Focus, the panel's width when Focus began, which it does not go past (PaperView): the sidebar's room goes to
    /// the page. In a narrow window the PDF's minimum width had squeezed the panel below the width it holds, and it
    /// sprang back to that width in Focus, wider than the page (review 2026-10-18). nil outside Focus.
    @Published private(set) var focusPanelWidth: CGFloat?
    /// The shown round's paragraphs that are read: the engine's, changed at once by C and Shift-C (UX.md §18).
    @Published private(set) var readBlocks: Set<Int> = []
    /// The paragraph last gone to with N (or confirmed under a selection): what C acts on while it is in view. Its bar
    /// is drawn bolder (POLISH §3 row 3).
    private(set) var currentParagraph: Int? { didSet { if currentParagraph != oldValue { pdf.updateReadingBars() } } }
    /// Reading marks (UX.md §18 "Optional"; the advisor's decision, 2026-10-18): the bars beside the changed paragraphs
    /// not read yet, the status line's count with Next and Mark Read, the Contents' dots, N, C and Shift-C and the
    /// Reading menu. Off by default: the Changes tab lists every edit either way, and they are checked there. Settings
    /// (⌘,) sets it, kept in the app's defaults; a test run (--background, a fixture, --reading) never saves it, and
    /// --reading on|off sets it for the run. The engine keeps the read state either way, so turning it on later works.
    @Published var readingMarksOn: Bool { didSet { if readingMarksOn != oldValue { readingMarksChanged() } } }
    static let readingMarksKey = "readingMarks"
    /// Checks (UX.md §39; design/pdf-reader/PLAN.md P1.5; the advisor's decision, 2026-10-30): the panel's Checks tab,
    /// the engine's `checks` of the shown round. Off by default, and nothing is asked for while off. Settings › Reading
    /// sets it, kept in the app's defaults; a test run never saves it, and --checks on|off sets it for the run.
    @Published var checksOn: Bool { didSet { if checksOn != oldValue { checksChanged() } } }
    static let checksKey = "checks"
    /// Settings › Reading › Checks: the kinds checked (references, bibliography, consistency, typesetting, submission),
    /// all by default; kept in the app's defaults, never by a test run. Only these become items that go to the student.
    @Published var checkKinds: Set<String> {
        didSet {
            guard checkKinds != oldValue else { return }
            if fixtureURL == nil { Prefs.set(Array(checkKinds).sorted(), Self.checkKindsKey) }
            checkSelectionChanged()
        }
    }
    static let checkKindsKey = "checkKinds"
    @Published var disabledCheckCodes: Set<String> {
        didSet {
            guard disabledCheckCodes != oldValue else { return }
            if fixtureURL == nil { Prefs.set(Array(disabledCheckCodes).sorted(), Self.disabledCheckCodesKey) }
            checkSelectionChanged()
        }
    }
    static let disabledCheckCodesKey = "disabledCheckCodes"
    /// Settings › Reading › Look up the references (design/pdf-reader/PLAN.md P1.3): Semantic Scholar and Google
    /// Scholar, each off by default, kept in the app's defaults (never by a test run). Off drops its queue.
    @Published var lookUp: Set<RefSource> {
        didSet {
            guard lookUp != oldValue else { return }
            if fixtureURL == nil && options.lookUp == nil { Prefs.set(lookUp.map(\.rawValue).sorted(), Self.lookUpKey) }
            for s in oldValue.subtracting(lookUp) { refs.stop(s) }
            requestReferences()
        }
    }
    static let lookUpKey = "lookUp"
    /// The look-ups' queues (one for the app; a test's own).
    let refs: RefLookup
    /// The shown round's cited entries and what the sources found for them, by key (the engine's `references`).
    @Published private(set) var refEntries: [String: RefEntry] = [:]
    @Published private(set) var refResults: [String: [RefSource: RefResult]] = [:]
    @Published private(set) var referencesLoading = false
    @Published private(set) var referenceRoundKey: String?
    @Published private(set) var referenceLoadError: String?
    @Published private(set) var referenceStores: [UUID: String] = [:]
    @Published private(set) var referenceStoreErrors: Set<String> = []
    private var refsAsked: String?
    private var refWatch: AnyCancellable?
    /// Settings › Overview (VISUAL v3 §5, §7): a long appendix (and a References list over four pages) folds into one
    /// block on the paper map and the small maps. On by default; kept in the app's defaults, never by a test run (a
    /// fixture run reads none; `--fold on|off` sets it for a run). The paper map on screen observes only the overview,
    /// which is told to draw it again.
    @Published var foldParts: Bool {
        didSet {
            guard foldParts != oldValue else { return }
            if options.fold == nil && fixtureURL == nil { Prefs.set(foldParts, Self.foldPartsKey) }
            overview.objectWillChange.send()
        }
    }
    static let foldPartsKey = "foldAppendix"
    /// Settings › General (design/tags/TAGS.md §8): where Paperole opens, the last place or All Students. Kept in
    /// the app's defaults under `openAtLaunch`, never by a test run; the place itself is `lastPlace` (written and read
    /// by the last-place feature, not here).
    @Published var openAtLaunch: OpenAtLaunch {
        didSet { if openAtLaunch != oldValue && fixtureURL == nil { Prefs.set(openAtLaunch.rawValue, Self.openAtLaunchKey) } }
    }
    static let openAtLaunchKey = "openAtLaunch"
    @Published var showNewPaper = false
    @Published var showFinish = false
    /// The popover of the student's notes that were not used, from the line at the top of the Comments tab (UX.md §3).
    @Published var showNoteWarnings = false
    /// A finished round's card in its sheet (Round N Summary…; RoundCard.swift).
    @Published var roundCard: RoundCardAsk?
    /// The sheet that builds the latest round again (Retry…, Build Round N Again…), or starts Round 1 when the engine
    /// refused it (`startRefused`).
    @Published var showRetry = false
    /// The sheet opened by Build Again with Shell Escape…: its Shell escape toggle starts on (`openRetry`; UX.md §41).
    private(set) var retryWithShellEscape = false
    /// The build's Details on the status line (`BuildStatusLine`), here so a debug script can open it (`builddetails`).
    @Published var showBuildDetails = false
    /// Turn On Shell Escape… asked, waiting for the confirmation's Turn On or Cancel (UX.md §41).
    @Published var confirmShellEscape: ShellEscapeAsk?
    /// Start Round 1 refused by the engine (two top-level files with \documentclass, neither main.tex: "Choose one."):
    /// the folder chosen and the engine's words, for the sheet that asks for the main file (review 2026-10-24, E2E-04).
    @Published var startRefused: StartRefusal?
    /// Why the selected paper's state could not be read (the engine's words): its page says so, with Try Again, until
    /// it is asked again (review 2026-10-24, A1-06: an empty Review titled "No rounds yet").
    @Published private(set) var stateError: String?
    @Published var confirmDelete: String?
    /// Resume Round N asked, waiting for the confirmation's Resume or Cancel (UX.md §31).
    @Published var confirmResume: ResumeAsk?
    /// Underline changed words in the cards' Now blocks (panel header toggle).
    @Published var showChangedWords = Prefs.bool("showChangedWords") ?? true {
        didSet {
            Prefs.set(showChangedWords, "showChangedWords")
            if let state { buildCards(state) }
        }
    }
    /// Increased with every applied state, so the PDF redraws its marks only when they may have changed.
    private(set) var stateVersion = 0
    /// Increased with every request that may change a paper (all but the read-only ones), so the overview asks the
    /// engine again only when its numbers may have changed (`loadOverview`).
    /// Published, so Settings › Tags counts again after an edit while it is open (the code audit).
    @Published private(set) var ledgerEdits = 0

    // MARK: Navigation (UX.md §21; AppNavigation.swift)

    /// The selected paper's level: its overview, the default when it is clicked in the sidebar, or Review. Set only by
    /// `setLevel`; a launch with --paper or --fixture opens in Review unless --level overview says otherwise.
    @Published private(set) var level: Level
    /// The window's history (⌘[ and ⌘], the toolbar's ‹ ›).
    var navHistory = NavHistory() {
        didSet {
            if canGoBack != navHistory.canGoBack { canGoBack = navHistory.canGoBack }
            if canGoForward != navHistory.canGoForward { canGoForward = navHistory.canGoForward }
            if backLabel != backStep?.label { backLabel = backStep?.label }
            if forwardLabel != forwardStep?.label { forwardLabel = forwardStep?.label }
        }
    }
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    /// Where ‹ and › go while it is a step in the PDF, "p.4 · 2.1 Data", for their help tags (PLAN §5.3).
    @Published private(set) var backLabel: String?
    @Published private(set) var forwardLabel: String?
    /// A click on the sidebar's row of the paper open in Review, which showed its overview at once: a second click
    /// within the double-click interval brings Review back as it was (`sidebarSelected`, `sidebarOpened`).
    private var reviewRowClick: (path: String, time: TimeInterval)?
    /// An empty toolbar item shown for a moment after the paper's width changed (`toolbarWidthChanged`): a change of
    /// the toolbar's items is what makes it bring back the items it moved into its overflow (»). The title's room
    /// follows the window's width a layout late, so a jump to a narrower window (a programmatic resize, a tile, Zoom)
    /// had moved every item into the overflow, for good (review 2026-10-19; UX.md §21 "The toolbar").
    @Published private(set) var toolbarNudge = false
    /// How many times the toolbar was laid out again so (the debug item `nav`).
    private(set) var toolbarNudges = 0
    private var toolbarNudgeWork: DispatchWorkItem?

    /// The paper's width changed (`PaperWidthReader`; the toolbar titles' room follows it): once it has settled (0.2 s,
    /// and not while the window is being dragged), the toolbar is laid out again with the title's new room, so an item
    /// it moved into its overflow comes back (`toolbarNudge`).
    func toolbarWidthChanged() {
        toolbarNudgeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.pdf.view?.window?.inLiveResize == true { return self.toolbarWidthChanged() }
            self.toolbarNudges += 1
            self.toolbarNudge = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.toolbarNudge = false }
        }
        toolbarNudgeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// Review opened at a position whose state has not come yet, and whether its round was asked for: applied when
    /// that round's state comes (`AppModel.reveal`).
    var pendingReview: (target: ReviewTarget, asked: Bool)?
    /// The selected paper's overview: its data, what it follows, its scroll.
    let overview = OverviewModel()

    let engine = EngineClient()
    let pdf = PDFController()
    let panel = PanelModel()
    /// The line over the comment list: its menu (the arrangement, the tags to show), the filter (UX.md §27).
    let listBar = ListBar()
    /// The paper whose cards the tag filter was set on: another paper shows all its comments again; `--tag-filter`'s,
    /// for the first paper shown.
    private var filterPaper: String?
    private var launchFilter: String?
    let changes = ChangePanel()
    let edit = EditState()
    let toolbar = ToolbarModel()
    let actions = CardActions()
    /// The Help window's topic (Help.swift).
    let help = HelpModel()
    let panelToast = PanelToast()
    let finishPreview = FinishPreview()
    let reading = ReadingModel()
    /// The Checks tab's checks of the shown round (Checks.swift).
    let checks = ChecksModel()
    let jump = JumpModel()
    let draftStore: DraftStore
    /// The overview's page thumbnails (Thumbnails.swift), cached per paper.
    let thumbnails: ThumbnailStore
    /// The writing tags' catalogue and the suggestions' switch (Tags.swift; UX.md §24).
    let tags: TagModel
    /// Settings › Data & Storage: where things are, export and import (DataStore.swift, Transfer.swift).
    private(set) lazy var data = DataModel(app: self, remember: !testRun)
    /// Settings › Data & Storage › Backups (opt-in) and the quiet check (Backups.swift): scheduled only outside a test run.
    private(set) lazy var backups = BackupModel(app: self, remember: !testRun)
    /// --fixture: render a state JSON without the engine. Relative PDF paths resolve against its folder.
    let fixtureURL: URL?
    let options: LaunchOptions
    /// A test run (--background, a fixture, --no-list, `swift test`; `LaunchOptions.isTestRun`): it never saves the
    /// list, a setting, an id, the tags, a draft or a thumbnail where the advisor's are.
    var testRun: Bool { options.isTestRun }
    /// The listed papers whose folder is not there (the sidebar's "missing"), as last looked (`noteMissing`).
    @Published private(set) var missingPapers: Set<String> = []
    /// The listed papers the quiet check found damaged (BackupModel.checkFolders), with the engine's words: the sidebar
    /// says so on their rows.
    @Published var damagedPapers: [String: String] = [:]
    /// A line at the bottom of the window (Remove from List's Undo, an export's result): its words and button.
    @Published var notice: WindowNotice?
    private var noticeTimer: Timer?
    /// Put Back an Earlier Ledger… (a paper's context menu): the sheet's paper, versions and choice.
    @Published var ledgerHistory: LedgerHistory?
    private var transientPaths: Set<String> = []
    /// A --background run: the papers of the list it read, whose folders it never writes to (`moveFactsIn`, `fillIn`).
    private var listRead: Set<String> = []
    /// Copies of a listed paper being given an id of their own (`forkCopy`).
    private var forking: Set<String> = []
    /// The last place kept as the window changes (LastPlace.swift).
    var placeWatchers: [AnyCancellable] = []
    private var changeFold: AnyCancellable?
    /// A paper given on the command line: listed for the run only.
    func isTransient(_ path: String) -> Bool { transientPaths.contains(path) }
    private var pendingSelect: String?
    /// Whether the PDF goes to the comment selected after a round switch (`showRound`): no while it reads on.
    private var pendingSelectReveal = true
    /// --focus (test runs): Focus once the paper's PDF is shown (PDFController.update).
    var pendingFocus = false
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var running = 0  // requests sent and not answered yet; the engine runs them one at a time, in order
    private var sent = 0, applied = 0  // sequence numbers, so an older reply never replaces a newer state
    private var perf: ScrollPerf?
    private var activation: Any?
    private var readingRequested: Set<String> = []  // paper|round|created whose paragraphs were asked for
    private var linksKey: String?  // paper|round|created whose link table was asked for (`requestLinks`)
    private var checksAsked: String?  // paper|round|created whose checks were asked for (`requestChecks`)
    private var checksRequest = 0  // also distinguishes successive choices for the same round
    /// The checks are built by an engine of their own, so a long paper's checks never hold the window's requests (the
    /// engine answers one request at a time); it writes only the round's checks.json, a cache.
    private lazy var checksEngine = EngineClient()
    /// My Comment… on a check: its paper|round, its key and its page, marked OK once a comment is made on that page
    /// while the editor it opened is open (`commentEditorClosed` lets it go).
    private var checkComment: (round: String, key: String, page: Int)?
    private var markGuard: TimeInterval = 0  // a row's check mark: until when a click is a double click's second
    private var readingFailed: String?
    private var readingRound: String?  // paper|round|created of the paragraphs shown (currentParagraph is per round)
    private var toastTimer: Timer?
    private var panelToastTimer: Timer?
    /// The unsent drafts of the shown paper's open round (comment id → text), as in `draftStore`, and that paper and
    /// round (nil when no round is open). `history`: the answers given there, for ⌘Z (UX.md §8).
    private(set) var drafts: [String: String] = [:]
    private(set) var draftsKey: (paper: String, round: Int)?
    private(set) var history = AnswerHistory()
    /// The answers of another paper's open round, or of this paper's while an earlier round is shown, kept for when
    /// it is shown again (UX.md §8: the history is per paper and round).
    private var histories: [String: (round: Int, history: AnswerHistory)] = [:]
    /// The card the last answer moved on to, whose buttons ignore clicks for a moment (POLISH §6); or the card answered,
    /// when no other card took its place (interaction review 2026-10-18).
    private(set) var clickGuard = ClickGuard()

    /// The app's model, for a window made outside SwiftUI (AppDelegate, a debug run while the screen is locked).
    private(set) static weak var current: AppModel?

    init(options: LaunchOptions) {
        self.options = options
        level = options.level ?? .review
        // a fixture run (`swift test` too) reads no setting: off unless --reading says on
        readingMarksOn = options.reading ?? (options.fixture == nil ? Prefs.bool(Self.readingMarksKey) : nil) ?? false
        checksOn = options.checks ?? (options.fixture == nil ? Prefs.bool(Self.checksKey) : nil) ?? false
        checkKinds = Set(Prefs.strings(Self.checkKindsKey) ?? ChecksModel.groups.map(\.id))
        disabledCheckCodes = Set((options.fixture == nil ? Prefs.strings(Self.disabledCheckCodesKey) : nil) ?? [])
        lookUp = options.lookUp
            ?? Set((options.fixture == nil ? Prefs.strings(Self.lookUpKey) : nil)?.compactMap(RefSource.init(rawValue:)) ?? [])
        refs = LaunchOptions.unitTest || options.fixture != nil ? RefLookup(cacheURL: nil, fetchers: [:]) : RefLookup.shared
        foldParts = options.fold ?? (options.fixture == nil ? Prefs.bool(Self.foldPartsKey) : nil) ?? true
        openAtLaunch = (options.fixture == nil ? Prefs.string(Self.openAtLaunchKey).flatMap(OpenAtLaunch.init(rawValue:)) : nil) ?? .lastPlace
        // a fixture run, --no-list or a unit test shows its own papers only: the list is not read (a unit test's model
        // would otherwise list Dev's real reviews); a --background run reads it, but never moves an unreadable one
        // aside nor writes to its papers' folders
        let listed: (papers: [PaperRef], problem: String?) = options.noList || options.fixture != nil || LaunchOptions.unitTest
            ? ([], nil)
            : PaperStore.load(from: options.list.flatMap { LaunchOptions.background ? URL(fileURLWithPath: $0) : nil } ?? PaperStore.fileURL,
                              setAside: !options.isTestRun)
        papers = listed.papers
        if LaunchOptions.background { listRead = Set(listed.papers.map(\.path)) }
        fixtureURL = options.fixture.map { URL(fileURLWithPath: $0) }
        // A test run (`LaunchOptions.isTestRun`) never writes into the user's Application Support: --drafts, or a
        // folder of its own.
        draftStore = DraftStore(directory: options.drafts.map { URL(fileURLWithPath: $0) }
            ?? (options.isTestRun ? FileManager.default.temporaryDirectory
                .appendingPathComponent("Paperole-drafts-\(getpid())") : DraftStore.standard))
        // the thumbnails: the caches folder, or a test run's own (--cache, else a temporary folder of its own)
        thumbnails = ThumbnailStore(root: options.cache.map { URL(fileURLWithPath: $0) }
            ?? (options.isTestRun ? FileManager.default.temporaryDirectory
                .appendingPathComponent("Paperole-thumbnails-\(getpid())") : ThumbnailStore.standardRoot))
        // the writing tags: Application Support's tags.json in real use; a test run's own (--tags, else a temporary
        // folder), never the advisor's (the critique's fix)
        tags = TagModel(store: TagStore(url: TagStore.location(tags: options.tags, testRun: options.isTestRun)),
                        remember: !options.isTestRun)
        if options.tab == "changes" { tab = .changes }
        if options.tab == "checks" && checksOn { tab = .checks }
        // the students folded in the sidebar: the viewer's choice; a fixture run (`swift test` too) reads none
        foldedStudents = Set(options.fixture == nil ? Prefs.strings(Self.foldedStudentsKey) ?? [] : [])
        allStudentsView = options.allView
            ?? (options.fixture == nil ? Prefs.string(Self.allStudentsViewKey).flatMap(AllStudentsView.init(rawValue:)) : nil) ?? .board
        // the paper map as a table: the viewer's choice; a fixture run (`swift test` too) reads none
        overview.asTable = options.fixture == nil ? Prefs.bool(Self.mapAsTableKey) ?? false : false
        // the comment list's arrangement (UX.md §27): the viewer's choice; a fixture run reads none
        panel.grouping = ListGrouping.argument
            ?? (options.fixture == nil ? Prefs.string(ListGrouping.key).flatMap(ListGrouping.init(rawValue:)) : nil) ?? .status
        launchFilter = ListGrouping.filterArgument
        listBar.grouping = panel.grouping
        listBar.model = self
        pendingSelect = options.select
        pendingFocus = options.focus
        Self.current = self
        pdf.model = self
        pdf.setReviewHidden(level != .review)  // --level overview: Review hidden from the start (UX.md §21)
        actions.model = self
        actions.tagModel = tags
        tags.changed = { [weak self] in self?.tagsChanged() }
        jump.sources = { [weak self] in self?.jumpSources() ?? Jump.Sources() }
        actions.tips.load(remember: options.fixture == nil)
        if let phrase = options.openComment { pdf.debugOpenComment(phrase, note: options.note) }
        if let script = options.script {
            pdf.debugScript(script, out: options.debugOut, quit: options.quit)
        }
        pdf.showMarks = options.marks
        if let problem = listed.problem { alertMessage = problem }
        moveFactsIn()  // first, so every later request reads the ledgers with their facts
        if let url = fixtureURL {
            do {
                let st = try EngineState.decode(Data(contentsOf: url))
                papers = [PaperRef(path: st.paper.path, title: st.paper.title, student: st.paper.student)]
                selectPaper(st.paper.path, state: st)
            } catch {
                alertMessage = "Could not read the fixture: " + describe(error)
            }
        } else if let path = options.paper {
            if options.hub == nil {
                selectPaper(addTransient(path))
            } else {
                _ = addTransient(path)
            }
            for more in options.morePapers { _ = addTransient(more) }
            // debug: switch papers while the first paper's request is still running
            if let other = options.switchTo { selectPaper(addTransient(other)) }
        }
        // no paper given: where the advisor left off (Settings › General; UX.md §24), else the hierarchy's page asked
        // for, else All Students as the home page (UX.md §22)
        if selectedPath == nil, fixtureURL == nil, remembersPlace, openAtLaunch == .lastPlace,
           openLastPlace(LastPlace.parse(UserDefaults.standard.string(forKey: LastPlace.key))) {
        } else if selectedPath == nil, fixtureURL == nil, let page = options.hub ?? (papers.isEmpty ? nil : .allStudents) {
            setHub(page)
            loadHub()
            // a debug script starts here, with no PDF to wait for
            if options.script != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.pdf.startScript() } }
        }
        // a closed round filled in by the second engine process: the overview shown asks again (UX.md §21, §22)
        backfill.filled = { [weak self] paper, more in
            guard let self else { return }
            self.roundsFound += 1
            if paper == self.overview.paper { self.overview.stale() }  // Review shown: asked again when the overview is
            if paper == self.selectedPath && self.level == .overview { self.loadOverview(force: true) }
            if self.hub != nil && !more { self.loadHub(force: true) }
        }
        if let mode = options.scrollPerf { startScrollPerf(mode) }
        refreshSummaries()
        // A paper may have changed outside the app (the command line): its next step is read again on activation, and
        // the hierarchy's numbers when one of its pages is shown.
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.activations += 1
                self.refreshSummaries()
                if self.hub != nil { self.loadHub() }
            }
        }
        placeWatchers = watchPlace()
        watchLookUps()
        // a change's Show all goes with its card (UX.md §3, §16): another change expanded, or none, folds the blocks the
        // old one showed whole (@Published sends in willSet: `changes.expanded` is still the old one)
        changeFold = changes.$expanded.sink { [weak self] new in
            guard let self, let old = self.changes.expanded, old != new else { return }
            let kept = self.edit.showAll.filter { !$0.hasPrefix(old + ".") }
            if kept != self.edit.showAll { self.edit.showAll = kept }
        }
        if !testRun {
            backups.start()
            data.sweepLeftovers()
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            nonisolated(unsafe) let e = event  // local monitors run on the main thread
            return MainActor.assumeIsolated { self?.handleKey(e) == true } ? nil : event
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
            nonisolated(unsafe) let e = event
            return MainActor.assumeIsolated { self?.sideButton(e) == true } ? nil : event
        }
    }

    // MARK: Derived state

    /// The round shown: the latest, or an earlier one picked in the toolbar (read only).
    var round: RoundInfo? { state?.round }
    /// The paper's latest round, which New round is about.
    var latestRound: RoundSummary? { state?.rounds.last }
    var viewingEarlierRound: Bool { (round?.n ?? 0) < (latestRound?.n ?? 0) }
    var roundIsOpen: Bool { round.map { !$0.closed && $0.build.pdf != nil } ?? false }
    /// The paper and round shown: a new comment's note is saved to the ones it was begun on only (UX.md §8).
    var shown: (paper: String?, round: Int?) { (selectedPath, round?.n) }
    /// The round menu's label: the round, named once (design/ui-v2/PROPOSAL.md §6, addition 10); its items say which
    /// rounds are closed. Nothing while the paper's state is not in (it may have no rounds, or not open at all).
    var roundLabel: String { round.map { "Round \($0.n)" } ?? (state == nil ? "" : "No rounds yet") }

    /// "Mei Lin · 7 comments and 2 edits to check": the student and the paper's next step, with the numbers of the
    /// panel's tabs while its open round is shown.
    /// In the overview the latest round is named too, as there is no round menu there (UX.md §21): "Mei Lin · Round 4 ·
    /// 7 comments and 2 edits to check".
    var windowSubtitle: String {
        // no state (its folder missing, its ledger unreadable): the student as the list keeps it
        guard let st = state else { return papers.first { $0.path == selectedPath }.map { StudentName.shown($0.student) } ?? "" }
        let live = roundIsOpen && !viewingEarlierRound
        var step = st.summary.map { withReading($0).subtitle(comments: live ? commentsToCheck : nil, edits: live ? toCheck : nil) }
        // Review, while the round waits on you (design/review-page/BRIEF.md D1 (b)): the tabs carry the numbers, so the
        // subtitle gives the day counter; Focus hides the tabs, so its subtitle keeps them, in v4's words
        if level == .review, live, commentsToCheck + toCheck > 0 {
            if focus {
                step = [commentsToCheck > 0 ? count(commentsToCheck, "comment") : nil, toCheck > 0 ? count(toCheck, "edit") : nil]
                    .compactMap { $0 }.joined(separator: " + ") + " to check"
            } else if let came = Hierarchy.date(latestRound?.created) {
                step = HubText.cameIn(came, today: Date())
            }
        }
        let round = level == .overview ? latestRound.map { "Round \($0.n)" } : nil
        return [st.paper.student, round ?? "", step ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    var canStartRound: Bool { state != nil && (latestRound?.closed ?? true) && !busy }
    /// The shown round can be built again with another source, main file or engine: the latest, open, and with no
    /// comment written, verdict given or comment reopened in it yet (CONTRACT §6, as the engine's ingest checks), and
    /// never finished before (a resumed round: replacing it would delete what its earlier finish wrote, UX.md §31). After
    /// a failed build that is Retry…; after one that built, with errors or not, Build Round N Again… in the build's
    /// Details (review 2026-10-24, E2E-05).
    var canBuildAgain: Bool {
        guard let r = round, let latest = latestRound, r.n == latest.n, !latest.closed, (r.finishes ?? []).isEmpty
        else { return false }
        return (state?.comments ?? []).allSatisfy { $0.carried && $0.verdict == nil && $0.revived == nil }
    }
    var canFinish: Bool { roundIsOpen && !busy }
    /// Nothing left in the open round (from round 2 on): no comment or other edit to check and no changed paragraph to
    /// read (a review folder without paragraphs has none). Finish Round… is then the accent's button (POLISH §3 row 1).
    var readyToFinish: Bool {
        guard roundIsOpen, !viewingEarlierRound, let n = round?.n, n > 1 else { return false }
        return commentsToCheck == 0 && toCheck == 0 && (unreadCount ?? 0) == 0
    }
    var canComment: Bool { roundIsOpen && (hasPDFSelection || toolbar.hasBox) && !busy }
    func canVerdict(_ c: Comment) -> Bool { roundIsOpen && c.carried && !busy }
    func canEdit(_ c: Comment) -> Bool { roundIsOpen && !c.carried && !busy }
    /// Edit Note: a new comment of the open round, the engine busy or not (`beginNoteEdit`).
    func canEditNote(_ c: Comment) -> Bool { roundIsOpen && !c.carried }
    /// Kind changes: new text comments only; a box stays a box, a carried comment changes kind only by re-anchoring.
    func canChangeKind(_ c: Comment) -> Bool { canEdit(c) && MarkKind.textKinds.contains(c.markKind) }

    var pdfURL: URL? { resolve(round?.build.pdf).map { URL(fileURLWithPath: $0) } }

    /// An engine path, or a fixture's path relative to its folder.
    func resolve(_ p: String?) -> String? {
        guard let p else { return nil }
        if p.hasPrefix("/") { return p }
        return fixtureURL?.deletingLastPathComponent().appendingPathComponent(p).path
    }

    /// Carried comments first (in the engine's document order), then new ones.
    nonisolated static func ordered(_ cs: [Comment]) -> [Comment] {
        cs.filter(\.carried) + cs.filter { !$0.carried }
    }

    func comment(_ id: String) -> Comment? { state?.comments.first { $0.id == id } }
    func change(_ id: String) -> Change? { state?.changes.first { $0.id == id } }
    var selectedComment: Comment? {
        if case .comment(let id)? = selection { return comment(id) }
        return nil
    }

    /// The shown round's paragraphs that are not read, or nil before the engine has found them and while reading marks
    /// are off (then no count is shown: the subtitle, the papers list, the done card and the Finish sheet ignore it).
    var unreadCount: Int? {
        guard readingMarksOn, let r = state?.reading else { return nil }
        return r.paragraphs.isEmpty ? r.unread : r.paragraphs.filter { !readBlocks.contains($0.block) }.count
    }

    /// An unrequested change that is not a move is handled once every paragraph it touches is read (UX.md §18); a
    /// change that touches none (a heading, a deleted paragraph) is not.
    func isRead(_ ch: Change) -> Bool {
        guard let blocks = ch.blocks, let r = state?.reading, !r.paragraphs.isEmpty else { return ch.read ?? false }
        let touched = blocks.filter(readableBlocks.contains)
        return ch.kind != "move" && !touched.isEmpty && touched.allSatisfy(readBlocks.contains)
    }

    /// The shown round's paragraphs to read (`isRead`), once per applied state.
    private var readableBlocks: Set<Int> = []

    /// The shown paper's summary with its open round's changed paragraphs still to read, which the engine's does not
    /// count (`PaperSummary.unread`): its subtitle and its line in the papers list then agree with the status line.
    func withReading(_ s: PaperSummary) -> PaperSummary {
        var s = s
        s.unread = !s.closed && roundIsOpen && !viewingEarlierRound ? unreadCount : nil
        return s
    }

    // MARK: Focus (POLISH §3 row 5, §4.3, §6, §7)

    /// The toolbar's Focus button (and Jump's), whose symbol reads as reading the page (POLISH §7: the arrows to the
    /// corners read as full screen): a page of text, as Safari's Reader. `doc.plaintext` is drawn as `text.page` from
    /// macOS 15, and exists on 14, the app's oldest.
    static let focusSymbol = "doc.plaintext"

    /// The toolbar's Focus button, F, View › Focus: at once (no animated pane), the sidebar goes, the page grows
    /// (`PDFController.focusChanged`), and the panel shows only the selected card, without its tabs (POLISH §7: the
    /// bar docked under the page read oddly); the status line stays. Leaving shows the whole list again with the card in
    /// view. An editor open on the card stays open: the card is the same. Only a round with a PDF has Focus.
    func setFocus(_ on: Bool) {
        guard on != focus, !on || round?.build.pdf != nil else { return }
        // a new comment's note being written waits, and says so: the page's new scale would leave its popover pointing
        // at the backdrop (interaction review 2026-10-18)
        if waitsForNote() { return }
        if on && tab == .checks { tab = .comments }  // Focus shows the selected card, which the Checks have not
        pdf.focusChanged(on)
        focusPanelWidth = on ? pdf.panelWidth : nil
        focus = on
        if panel.focus != on { panel.focus = on }
        if changes.focus != on { changes.focus = on }
        if edit.focus != on { edit.focus = on }
        if !on {  // the whole list again: its card in view
            if let id = panel.expanded { panel.scroller.request(id, mode: .centre) }
            if let id = changes.expanded { changes.scroller.request(id, mode: .centre) }
        }
    }

    /// The sidebar's system toggle (or View › Show Sidebar): outside Focus it is the sidebar's; in Focus, showing it
    /// leaves Focus.
    func sidebarToggled(_ shown: Bool) {
        if focus {
            if shown { setFocus(false) }
        } else if sidebarShown != shown {
            sidebarShown = shown
        }
    }

    // MARK: Jump (POLISH §3 row 12, §6)

    /// The sidebar's "Jump to…" and ⌘K: the Jump panel opens, or closes when it is open.
    func openJump() {
        if jump.shown { return closeJump() }
        jump.open()
    }

    /// Esc, a click outside the panel, or a row chosen: it goes, and the keys go back to the PDF; in the overview to the
    /// map (UX.md §21), once Jump's field has given them up, never to the PDF hidden behind it.
    func closeJump() {
        guard jump.shown else { return }
        jump.close()
        if pdf.reviewHidden {
            if let w = pdf.view?.window ?? overview.keyView?.window { w.makeFirstResponder(nil) }
            DispatchQueue.main.async { [weak self] in self?.overview.takeKeysIfFree() }
        } else if let v = pdf.view, let w = v.window {
            w.makeFirstResponder(v)
        }
    }

    /// A row of the Jump panel: a comment or an edit is selected as a click on its mark would (in Focus, the panel shows
    /// its card), a section shown as a Contents click, a round as the round menu, a command run, the query found in the
    /// PDF.
    func jumpTo(_ t: Jump.Target) {
        closeJump()
        // a comment, an edit, a section, a round or a find: in Review, at the round it shows (Jump lists that round's);
        // a look-up, a step of Back, unless it opened Review (a window step already)
        let step: PDFSteps.Kind? = level == .overview ? nil : .lookUp
        if level == .overview, t.inReview { enterReview() }
        switch t {
        case .comment(let id):
            tab = .comments
            select(.comment(id), scroll: .centre, step: step)
        case .edit(let id):
            tab = .changes
            select(.change(id), scroll: .centre, step: step)
        case .section(let block): outlineOpen(block, step: step)
        case .round(let n): showRound(n)
        case .command(let c): runJump(c)
        case .find(let q): findInPaper(q, step: step == nil ? nil : .find)
        case .page(let n): pdf.goToPage(n, step: step)
        }
    }

    /// What Jump searches, from what the app shows now: the comments in the list's order with the words they are on
    /// (the shown round's sentence) and this round's words, the edits no comment asked for, the Contents, the rounds,
    /// and the commands that can act.
    func jumpSources() -> Jump.Sources {
        var s = Jump.Sources()
        let byID = Dictionary((state?.comments ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let g = panel.groups
        s.comments = (g.toCheck + g.forStudent + g.closed).compactMap { card in
            byID[card.id].map {
                Jump.CommentSource(id: $0.id, status: card.status, note: $0.note,
                                   words: $0.context?.text ?? $0.text ?? $0.oldQuote ?? "", said: $0.verdictNote ?? "", page: $0.page)
            }
        }
        s.edits = changes.unrequested.map {
            Jump.EditSource(id: $0.id, kind: $0.kind, place: $0.place, excerpt: String($0.excerpt.characters), page: $0.page)
        }
        s.sections = reading.contents.rows
        s.rounds = state?.rounds ?? []
        s.shownRound = round?.n
        s.pages = round?.build.pdf == nil ? 0 : pdf.position.count
        var c: [Jump.CommandSource] = []
        func add(_ k: Jump.Command, _ title: String, _ icon: String) { c.append(Jump.CommandSource(command: k, title: title, icon: icon)) }
        if round?.build.pdf != nil { add(.focus, focus ? "Leave Focus" : "Focus: the page larger, one card beside it", Self.focusSymbol) }
        if canFinish { add(.finish, "Finish Round \(round?.n ?? 0)…", "checkmark.circle") }
        if readingMarksOn && readingTracked && round?.build.pdf != nil { add(.next, "Next Changed Paragraph to Read", "arrow.down") }
        if state != nil {
            add(.comments, "Show the Comments", "text.bubble")
            add(.changes, "Show the Changes", "pencil")
            add(.changeMarks, showChanges ? "Hide Change Marks" : "Show Change Marks", "highlighter")
            add(.underline, showChangedWords ? "Stop Underlining Changed Words" : "Underline Changed Words", "underline")
        }
        if let r = round, r.closed {
            add(.summary, "Round \(r.n) Summary…", "chart.bar.doc.horizontal")
            if r.finalPdf != nil { add(.finalPDF, "Open Round \(r.n) final.pdf", "doc.richtext") }
        }
        if canStartRound { add(.newRound, round == nil ? "Start Round 1…" : "New Round…", "tray.and.arrow.down") }
        add(.newPaper, "New Paper…", "plus")
        add(.addPaper, "Add Existing Paper…", "folder.badge.plus")
        s.commands = c
        return s
    }

    /// Jump's commands: what the toolbar and the menus do. The tabs are not shown in Focus, so they leave it.
    func runJump(_ c: Jump.Command) {
        switch c {
        case .focus: setFocus(!focus)
        case .finish: openFinish()
        case .next: nextUnread()
        case .changeMarks: showChanges.toggle()
        case .underline: showChangedWords.toggle()
        case .comments, .changes:
            setFocus(false)
            tab = c == .comments ? .comments : .changes
        case .newRound: startRound()
        case .summary: openRoundSummary()
        case .finalPDF: if let p = round?.finalPdf { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
        case .newPaper: showNewPaper = true
        case .addPaper: addExistingPaper()
        }
    }

    /// The query of the find in the paper, nil without one (Edit › Find Next in Paper goes on with it).
    var findQuery: String? { pdf.find.query.isEmpty ? nil : pdf.find.query }

    /// Jump's "Find “boat” in the paper", and Find Next / Previous in Paper (⌘G, ⇧⌘G): the toolbar's find in the paper
    /// (Find.swift), since Jump does not index the paper's text (POLISH §3 row 12). The query goes into the toolbar's
    /// field, the match is selected in the PDF and shown, and the field's counter says which of how many. `step`: what
    /// the query's first match is for Back; nil when Jump opened Review for it.
    func findInPaper(_ q: String? = nil, previous: Bool = false, step: PDFSteps.Kind? = .find) {
        guard round?.build.pdf != nil else { return }
        if let q, !q.isEmpty { pdf.find.find(q, step: step) } else { pdf.find.step(previous: previous) }
    }

    /// The student's notes in the shown round that the engine did not use, with file:line (UX.md §3).
    var noteWarnings: [NoteWarning] { state?.noteWarnings ?? [] }
    /// Their one calm place (UX.md §3): a line at the top of the Comments tab's page (`CommentsPage`), not in Focus.
    /// The page stays while the Changes tab is shown, sliding away with its line, so the tab shown does not matter.
    var noteWarningsLine: Bool { !focus && !noteWarnings.isEmpty }

    /// Carried comments without an answer (To check and Not found): the Comments tab's count (UX.md §1).
    var commentsToCheck: Int { (state?.comments ?? []).filter { $0.carried && $0.verdict == nil }.count }

    /// Unrequested changes not checked and not asked about by a comment of this round (UX.md §16).
    var toCheck: Int {
        (state?.changes ?? []).filter { $0.unrequested && $0.checked != true && ($0.commentedBy ?? []).isEmpty && !isRead($0) }.count
    }

    // MARK: Papers

    func selectPaper(_ path: String?, state preloaded: EngineState? = nil) {
        // the same paper again when its state could not be read: asked again (A1-06)
        guard path != selectedPath || preloaded != nil || stateError != nil else { return }
        if waitsForNote() {  // a new comment's note stays with its paper; the list shows this one selected again
            DispatchQueue.main.async { self.objectWillChange.send() }
            return
        }
        if path == nil { setFocus(false) }
        pendingFinish = nil  // Your Move's Finish was another paper's
        if let t = edit.tagging { closeTagPicker(t) }  // a card's tag picker: written to its own paper first
        // an open inline editor is saved first, to the paper it was begun on, as for another round (UX.md §17)
        commitEdit(focusLost: true)
        closeEdit()
        toolbar.reanchor = nil
        clearPanelToast()  // its Undo is this paper's: never another's
        pdf.endSteps()
        pdf.closePinned()  // the kept previews are this paper's (none over a hub page)
        selectedPath = path
        if overview.paper != path { overview.reset(for: path) }
        state = nil
        stateError = nil
        startRefused = nil
        showBuildDetails = false  // the last paper's build
        confirmShellEscape = nil  // asked about the last paper (UX.md §41)
        selection = nil
        panel.expanded = nil
        panel.held = nil
        changes.expanded = nil
        hasPDFSelection = false
        currentParagraph = nil
        buildOutline()  // no Contents or reading count until the paper's state comes
        requestChecks()  // nor the last paper's checks: no round shown, so they go
        if let preloaded {
            apply(preloaded)
        } else if let path, fixtureURL == nil {
            // a folder missing: its page says so (the list's title and student), no alert with its path
            if DataFiles.isReviewFolder(URL(fileURLWithPath: path)) { loadState(path) } else { noteMissing() }
        }
        if level == .overview { loadOverview() }  // asked now, answered after the state (one engine, in order)
    }

    /// The shown paper's state. When it cannot be read (a ledger that does not read, the engine stopped), the page
    /// says so with Try Again (`stateError`), not an alert over an empty Review titled "No rounds yet" (A1-06).
    private func loadState(_ path: String) {
        stateError = nil
        call("state", ["paper": path], quiet: true, failed: { [weak self] message in
            guard let self, self.selectedPath == path, self.state == nil else { return }
            self.stateError = message
        })
    }

    /// Try Again on the page of a paper whose state could not be read.
    func retryState() {
        guard let path = selectedPath, state == nil, fixtureURL == nil else { return }
        stateError = nil
        if DataFiles.isReviewFolder(URL(fileURLWithPath: path)) { loadState(path) } else { noteMissing() }
    }

    /// Shows the selected paper's overview or Review (UX.md §21). Review is never rebuilt: its PDF and panel stay in
    /// the window, hidden behind the overview (`PDFController.setReviewHidden`), so coming back finds the page, the
    /// selection and the list as they were. Leaving Review ends Focus, saves an open editor as a click elsewhere
    /// does, and takes the keys from the hidden PDF; leaving the overview keeps its scroll position and ends the round
    /// previewed under the pointer (mac/UX.md §40.9).
    func setLevel(_ l: Level) {
        guard l != level else { return }
        if level == .overview {
            overview.saveScroll()
            overview.pointerLeft()
        }
        if l == .overview {
            setFocus(false)
            if let t = edit.tagging { closeTagPicker(t) }
            commitEdit(focusLost: true)
            dropChoice()
            leaveReanchor()
            clearPanelToast()
            if jump.shown { jump.close() }
        }
        let fromReview = level == .review
        if fromReview { pdf.endSteps() }
        level = l
        pdf.setReviewHidden(l != .review)
        // Review shown: the PDF takes the keys (the sidebar's arrows had gone on choosing papers after Return or a
        // double click opened it; 2026-10-20 leftover), unless a text field has them
        if l == .review { DispatchQueue.main.async { [weak self] in self?.pdf.takeKeys() } }
        if l == .overview {
            loadOverview()
            if fromReview { DispatchQueue.main.async { [weak self] in self?.overview.takeKeysIfFree() } }
        }
    }

    /// The round picker (F7): shows round n as it was left, read only unless it is the latest. The selected comment
    /// stays selected when it is in that round. A new comment's note being written waits, and says so.
    func showRound(_ n: Int, follow: Bool = true) {
        guard let path = selectedPath, n != round?.n, fixtureURL == nil, !waitsForNote() else { return }
        if let t = edit.tagging { closeTagPicker(t) }
        commitEdit(focusLost: true)
        leaveReanchor()
        dropChoice()  // its keys answer the open round's comment: never from another round
        clearPanelToast()  // its Undo is the open round's
        pdf.clearSelection()
        pdf.dropPendingBox()
        pdf.endSteps()
        navHistory.fold(paper: path)  // the PDF's steps were the other round's PDF
        changes.expanded = nil  // change ids are per round
        if case .change? = selection { selection = nil; pdf.setSelectedChange(nil) }
        // A selected comment comes along (selected there too); the PDF goes to it only while its mark is on screen,
        // else to the paragraph being read (PLAN P1.1). A reveal (Back, the overview) goes to its own target instead.
        var shown: String?  // the selected comment, its mark on screen
        if tab == .comments, case .comment(let id)? = selection {
            pendingSelect = id
            if comment(id).map({ pdf.isVisible(page: $0.page, rects: $0.rects) }) == true { shown = id }
            pendingSelectReveal = shown != nil || !follow
        }
        let place = follow ? readingPlace() : nil, moves = pdf.ownMoves
        call("state", n == latestRound?.n ? ["paper": path] : ["paper": path, "round": n], then: { _ in
            if let id = self.panel.expanded, self.comment(id) == nil { self.panel.expanded = nil }
            // the comment went to its mark when it is in this round too; else the paragraph read
            if let id = shown, self.comment(id) != nil { return }
            if let place, self.round?.n == n { self.follow(place, path: path, to: n, moves: moves) }
        })
    }

    /// Where the advisor reads in the shown round's PDF (design/pdf-reader/PLAN.md P1.1): the block at the view's third,
    /// or only the page and point while its paragraphs are not found.
    private func readingPlace() -> ReadingPlace? {
        guard let n = round?.n, round?.build.pdf != nil, !pdf.reviewHidden, let p = pdf.pointAtThird() else { return nil }
        guard let r = state?.reading else { return ReadingPlace(round: n, page: p.page, x: p.x, y: p.y) }
        return Reading.place(round: n, page: p.page, x: p.x, y: p.y, paragraphs: r.paragraphs, headings: r.headings)
    }

    /// The place read in another round, put a third of the way down round n's PDF (its line flashed, no step of Back):
    /// its block there (the engine's `follow`), else the same point of the same page.
    private func follow(_ from: ReadingPlace, path: String, to n: Int, moves: Int) {
        // dropped once the advisor has moved on since the switch (a scroll or a key: `moves`, from before the state
        // came) or since this round was shown (another selection, a jump: Go to Page, a link, Find, Back): the engine
        // may first be finding the round's paragraphs
        let jumps = pdf.jumps, selected = selection
        func go(_ reply: FollowReply?) {
            guard selectedPath == path, round?.n == n, level == .review, pdf.ownMoves == moves, pdf.jumps == jumps,
                  selection == selected,
                  let at = Reading.followed(from, reply: reply, pages: round?.build.pages ?? 0) else { return }
            pdf.go(to: PDFPlace(page: at.page, x: at.x, y: at.y, zoom: pdf.zoom, label: ""))
        }
        guard let b = from.block,
              let json = try? JSONSerialization.data(withJSONObject: ["paper": path, "round": from.round, "block": b, "to": n])
        else { return go(nil) }
        let id = engine.send("follow", params: json)
        Task { go(try? makeDecoder().decode(FollowReply.self, from: try await engine.result(id))) }
    }

    /// The papers list's next steps, from one light engine call. The selected paper's comes with its states.
    func refreshSummaries() {
        noteMissing()
        // a paper marked damaged is checked again (one caught mid-write by the day's check clears then)
        if !damagedPapers.isEmpty { backups.checkFolders(Array(damagedPapers.keys)) }
        let paths = papers.map(\.path).filter { $0 != selectedPath }
        guard fixtureURL == nil, !paths.isEmpty, let json = try? JSONSerialization.data(withJSONObject: ["papers": paths])
        else { return }
        let edits = ledgerEdits
        Task {
            guard let data = try? await engine.call("summaries", params: json),
                  let reply = try? makeDecoder().decode(SummariesReply.self, from: data) else { return }
            for e in reply.papers {
                // the sidebar groups the papers by student: each paper's name and student as its ledger has them
                if let p = e.paper {
                    adoptNames(e.path, title: p.title, student: p.student)
                    // not when an edit was sent since (Mark as Finished): the reply's facts are older than the list's
                    if p.id != nil && edits == ledgerEdits { adoptFacts(e.path, id: p.id, finished: .some(p.finished)) }
                }
                if e.path != selectedPath && summaries[e.path] != e.summary { summaries[e.path] = e.summary }
            }
        }
    }

    /// Which listed papers' folders are not there (a test run's too): the sidebar says so on their rows, and they wait
    /// on no one (`status(of:)`). Not a fixture run's, whose papers are no folders.
    func noteMissing() {
        guard fixtureURL == nil else { return }
        let gone = Set(papers.map(\.path).filter { !DataFiles.isReviewFolder(URL(fileURLWithPath: $0)) })
        if gone != missingPapers { missingPapers = gone }
    }

    func createPaper(title: String, student: String, folder: String) {
        call("new", ["paper": folder, "title": title, "student": student], then: { reply in
            self.papers.removeAll { $0.path == folder }
            self.papers.append(PaperRef(path: folder, title: title, student: student, ledgerID: reply.state.paper.id,
                                        factsMoved: true))
            self.persist()
            self.selectPaper(folder, state: reply.state)
        })
    }

    /// Add Existing Paper…: Import… (DATA.md §5.1): a review folder, listed where it is, an export or backup file, or
    /// a folder to look in; a new review folder is listed at once, anything else shows what it holds first.
    func addExistingPaper() { data.chooseImport(origin: .window) }

    /// Lists a review folder (its title and student from its ledger) and shows it. A folder listed already keeps its
    /// place and what the app keeps for it (Map Headings, key page, finished): only its names are read again. One new
    /// to the list comes in with shell escape off, as a paper from a file does (UX.md §41): listed once it is off.
    func addReviewFolder(_ path: String) {
        call("state", ["paper": path], then: { reply in
            let title = reply.state.paper.title, student = reply.state.paper.student
            if let i = self.papers.firstIndex(where: { $0.path == path }) {
                self.papers[i].title = title
                self.papers[i].student = student
            } else if reply.state.paper.shellEscape == true {
                // trust does not travel: its ledger may have been written on another Mac, or by anyone who could
                // write the folder
                self.call("edit_paper", ["paper": path, "shell_escape": false],
                          then: { _ in self.addReviewFolder(path) })
                return
            } else {
                // a folder's own ledger has its facts, if any: nothing to move in
                self.papers.append(PaperRef(path: path, title: title, student: student, ledgerID: reply.state.paper.id,
                                            factsMoved: true))
            }
            self.persist()
            self.selectPaper(path, state: reply.state)
        })
    }

    /// Papers brought in by Import (Transfer.swift): listed and saved, as Add Existing… does, not shown; their names
    /// are read again from their ledgers. One already listed at its path keeps its entry; one put back for a lost entry
    /// (`replacing`: the path the list names, whose folder is gone) takes that entry's place, and its unsent drafts go
    /// with it. Facts an entry carries (a schema-1 backup's) are moved into its ledger.
    func list(_ refs: [PaperRef], replacing old: String? = nil) {
        guard !refs.isEmpty else { return }
        for r in refs {
            if r.path != old && papers.contains(where: { $0.path == r.path }) { continue }
            if let old, let i = papers.firstIndex(where: { $0.path == old }) {
                if r.path != old { draftStore.move(from: old, to: r.path) }
                papers[i].path = r.path
                papers[i].title = r.title
                papers[i].student = r.student
                if r.factsMoved != true { papers[i].factsMoved = nil }  // the list's facts go into the folder put back
            } else if !papers.contains(where: { $0.path == r.path }) {
                papers.append(r)
            }
        }
        persist()
        moveFactsIn()
        refreshSummaries()
        if hub != nil { loadHub(force: true) }
    }

    /// A paper given on the command line: listed, but not saved to the papers list.
    private func addTransient(_ path: String) -> String {
        let abs = URL(fileURLWithPath: path).standardizedFileURL.path
        if !papers.contains(where: { $0.path == abs }) {
            papers.append(PaperRef(path: abs, title: (abs as NSString).lastPathComponent, student: "", factsMoved: true))
            transientPaths.insert(abs)
        }
        return abs
    }

    func removePaper(_ path: String) { removePapers([path]) }

    /// Remove from List (a paper's or a student's context menu): their folders stay where they are, and the line at the
    /// bottom of the window says so with Undo (DATA.md §6.4). `student`: the student's name, for the words.
    func removePapers(_ paths: [String], student: String? = nil) {
        if let s = selectedPath, paths.contains(s), waitsForNote() { return }
        let gone = papers.enumerated().filter { paths.contains($0.element.path) }
        guard !gone.isEmpty else { return }
        papers.removeAll { paths.contains($0.path) }
        persist()
        for (_, p) in gone {
            thumbnails.clear(paper: p.path)
            backfill.drop(p.path)
            navHistory.remove(paper: p.path)
        }
        if let s = selectedPath, paths.contains(s) {
            selectPaper(nil)
            if !papers.isEmpty { setHub(.allStudents) }  // the home page (UX.md §22)
        }
        if hub != nil { loadHub() }
        let words = gone.count == 1 && student == nil
            ? "Removed “\(TransferText.short(gone[0].element.title))” from the list. Its folder stays where it is."
            : "Removed \(student.map { $0 + "’s " } ?? "")\(count(gone.count, "paper")) from the list. "
                + (gone.count == 1 ? "Its folder stays where it is." : "Their folders stay where they are.")
        showNotice(WindowNotice(text: words, action: "Undo")) { [weak self] in self?.undoRemove(gone) }
    }

    /// Undo of Remove from List: the entries back where they were in the list, as they were.
    private func undoRemove(_ gone: [(offset: Int, element: PaperRef)]) {
        for (i, p) in gone where !papers.contains(where: { $0.path == p.path }) { papers.insert(p, at: min(i, papers.count)) }
        persist()
        refreshSummaries()
        if hub != nil { loadHub(force: true) }
    }

    /// Shows the window's bottom line for 10 s (longer while the pointer is on it); `action` runs its button.
    func showNotice(_ n: WindowNotice, action: (() -> Void)? = nil) { showNotice(n, second: nil, action: action) }

    /// The same with a second button, which `second` runs (no defaults here, so a trailing closure is always the
    /// first button's, through the one above).
    func showNotice(_ n: WindowNotice, second: (() -> Void)?, action: (() -> Void)?) {
        noticeAction = action
        noticeSecond = second
        notice = n
        holdNotice(false)
    }

    private(set) var noticeAction: (() -> Void)?
    private(set) var noticeSecond: (() -> Void)?

    func holdNotice(_ held: Bool) {
        noticeTimer?.invalidate()
        guard !held, let id = notice?.id else { return }
        noticeTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { if self?.notice?.id == id { self?.notice = nil } }
        }
    }

    /// The notice's button: Undo, Show in Finder; `second`: its second button, Open.
    func noticeClicked(second: Bool = false) {
        let a = second ? noticeSecond : noticeAction
        notice = nil
        noticeAction = nil
        noticeSecond = nil
        a?()
    }

    private func persist() {
        noteMissing()
        // a test run (a fixture, --no-list: the user's list was not read, saving would replace it; --background; a
        // unit test) never changes the advisor's list (CLAUDE.md; the critique: a key page or a mark set in a test run)
        guard !testRun else { return }
        do {
            try PaperStore.save(papers.filter { !transientPaths.contains($0.path) })
        } catch {
            alertMessage = "Your papers list could not be saved: " + error.localizedDescription
        }
    }

    // MARK: Engine actions

    func startRound() {
        // just selected from a card (`startRound(_:)`): its state not in yet, its summary is
        let n = (latestRound?.n ?? selectedPath.flatMap { summaries[$0]?.round } ?? 0) + 1
        guard let source = chooseFolder(prompt: "Start round \(n)", message: "Choose the student’s LaTeX source folder (or a .zip) for round \(n).",
                                        allowZip: true) else { return }
        ingest(source: source)
    }

    /// `shellEscape`: the paper's choice, sent only when given (UX.md §41); without it the engine builds as the paper has
    /// it.
    func ingest(source: String, main: String? = nil, engine: String? = nil, shellEscape: Bool? = nil) {
        guard let paper = selectedPath else { return }
        var params: [String: Any] = ["paper": paper, "source": source]
        if let main, !main.isEmpty { params["main"] = main }
        if let engine, !engine.isEmpty { params["engine"] = engine }
        if let shellEscape { params["shell_escape"] = shellEscape }
        // No round yet: a refusal (two top-level files with \documentclass, neither main.tex: "Choose one.") shows in
        // Start Round 1, with the folder chosen, where the main file is given (E2E-04: the only Main file field was
        // Retry…'s, after a failed build, so such a paper stayed at "No rounds yet")
        guard state?.rounds.isEmpty == true else { return call("ingest", params) }
        startRefused = nil
        call("ingest", params, quiet: true, failed: { [weak self] message in
            guard let self else { return }
            guard self.selectedPath == paper, self.state?.rounds.isEmpty == true else { self.alertMessage = message; return }
            self.startRefused = StartRefusal(source: source, problem: message)
            self.openRetry()
        })
    }

    /// The sheet that builds the latest round again or starts Round 1 (`showRetry`); `shellEscape`: opened by Build Again
    /// with Shell Escape…, its toggle on (UX.md §41).
    func openRetry(shellEscape: Bool = false) {
        retryWithShellEscape = shellEscape
        showRetry = true
    }

    var lastSource: String? {
        guard let n = round?.n else { return nil }
        return state?.rounds.first { $0.n == n }?.source
    }

    /// `anchor` is `page`, `rects` and `text` from the PDF; `shown` the paper and round the note was begun on, the
    /// only ones it is saved to. `done(false)` when it is not saved (or the engine refused it), so the editor can keep
    /// the note.
    func createComment(anchor: [String: Any], note: String, kind: MarkKind, color: MarkColor, tags picked: TagSelection? = nil,
                       on shown: (paper: String?, round: Int?), done: @escaping (Bool) -> Void) {
        guard let paper = selectedPath else { return done(false) }
        guard shown == self.shown else {
            alertMessage = "This note was begun on another paper or round, so it was not saved here. Copy it, then cancel it."
            return done(false)
        }
        var params: [String: Any] = ["paper": paper, "note": note, "kind": kind.rawValue, "color": color.rawValue]
        // its writing tags, saved with it in one write (CONTRACT amendment "Tags, key page and Reopen")
        if let picked, !picked.on.isEmpty {
            params["tags"] = picked.on
            params["accepted"] = picked.accepted.filter(picked.on.contains)
            let names = tags.catalog.names(for: picked.on)
            if !names.isEmpty { params["names"] = names }
        }
        let fromCheck = checkComment
        checkComment = nil
        call("comment", anchor.merging(params) { a, _ in a },
             then: { reply in
                 if let f = fromCheck, f.round == self.checks.key, anchor["page"] as? Int == f.page,
                    let i = self.checks.list.firstIndex(where: { $0.key == f.key }), !self.checks.list[i].ok {
                     self.markCheck(i, true)
                 }
                 self.pdf.clearSelection()
                 self.pdf.dropPendingBox()
                 // From a change ("Comment on this change"): the Changes tab keeps its place, and the row shows the
                 // new comment's chip. Otherwise the new card is shown.
                 if self.tab == .changes, case .change? = self.selection {
                 } else {
                     self.tab = .comments
                     if let id = reply.id { self.select(.comment(id), reveal: false, scroll: .centre) }
                 }
                 done(true)
             }, failed: { _ in done(false) })
    }

    /// Colour (any comment of the open round) or kind (new text comments) from the mark's toolbar, the card's colour dot,
    /// the style menu or 1–6, recorded for ⌘Z unless it is an undo or redo itself (`record` false). `done(true)` once the
    /// engine has it, or when there is nothing to change.
    func setStyle(_ id: String, color: MarkColor? = nil, kind: MarkKind? = nil, record: Bool = true,
                  done: ((Bool) -> Void)? = nil) {
        guard let paper = selectedPath, let c = comment(id), roundIsOpen, !refusedWhileBusy() else { done?(false); return }
        var params: [String: Any] = ["paper": paper, "id": id]
        let before = MarkStyle(color: c.markColor, kind: c.markKind)
        var after = before
        if let color, color != c.markColor {
            params["color"] = color.rawValue
            after.color = color
        }
        if let kind, kind != c.markKind, canChangeKind(c), MarkKind.textKinds.contains(kind) {
            params["kind"] = kind.rawValue
            after.kind = kind
        }
        guard params.count > 2 else { done?(true); return }
        let key = draftsKey
        call("edit_comment", params, then: { _ in
            if record { self.recordStyle(StyleStep(id: id, before: before, after: after), on: key) }
            done?(true)
        }, failed: { _ in done?(false) })
    }

    /// A style change the engine has, for ⌘Z: in the history of the paper and round it was made on, which is kept aside
    /// when another paper or round was shown meanwhile.
    private func recordStyle(_ step: StyleStep, on key: (paper: String, round: Int)?) {
        guard let key else { return }
        if draftsKey?.paper == key.paper && draftsKey?.round == key.round {
            history.record(step)
        } else if var kept = histories[key.paper], kept.round == key.round {
            kept.history.record(step)
            histories[key.paper] = kept
        }
    }

    /// Delete…: asks first (panel-level dialog), then deletes and selects the next card.
    func requestDelete(_ id: String) {
        guard let c = comment(id), roundIsOpen, !c.carried, !refusedWhileBusy() else { return }
        confirmDelete = id
    }

    func deleteConfirmed(_ id: String) {
        guard let paper = selectedPath else { return }
        let ids = panel.listed.map(\.id)
        let next = ids.firstIndex(of: id).flatMap { i in i + 1 < ids.count ? ids[i + 1] : (i > 0 ? ids[i - 1] : nil) }
        call("delete_comment", ["paper": paper, "id": id], then: { _ in
            self.history.forget(id)  // its style steps: ⌘Z must not recolour a comment that is gone
            if let next { self.select(.comment(next), reveal: false, scroll: .centre) }
        })
    }

    func setVerdict(_ id: String, _ verdict: String?, note: String = "", done: ((Bool) -> Void)? = nil) {
        guard let paper = selectedPath else { done?(false); return }
        call("verdict", ["paper": paper, "id": id, "verdict": verdict ?? NSNull(), "note": note],
             then: { _ in done?(true) }, failed: { _ in done?(false) })
    }

    /// Whether an answer on a card moves on to the next card to check (UX.md §8; POLISH §6): in Review, from a key or a
    /// click alike; never in Focus, where an answer moves neither the PDF nor the selection, so reading goes on.
    var answersAdvance: Bool { !focus }

    /// What an answer or comment action refused while the engine works says (O27; POLISH §7). The action is not kept
    /// for later: the engine's reply can change what it would act on.
    static let stillLoading = "Still loading… try again in a moment."

    /// An action that needs the engine, while the engine works on an earlier request: refused, and the panel's toast
    /// says so, at the foot of the panel by the card's buttons, where an answer's own toast shows (review 2026-10-18: over
    /// the PDF it was far from the click and wore the reading bar). true: refused.
    func refusedWhileBusy() -> Bool {
        guard busy else { return false }
        showPanelToast(Self.stillLoading)
        return true
    }

    /// An answer on `c` can be given: a carried comment of the open round, and the engine free (else it says so).
    private func answerable(_ c: Comment) -> Bool { roundIsOpen && c.carried && !refusedWhileBusy() }

    /// The card whose answer the engine is working on: a click on its buttons meanwhile is a double click's second
    /// click (or one more of the same), ignored without a word; "Still loading…" would invite one more, which in Review
    /// would answer the card that then takes its place (review 2026-10-18).
    var answerPending: String?

    /// The card's buttons ignore clicks for a moment (`ClickGuard`): the row under the pointer just changed.
    func guardClicks(_ id: String) { clickGuard.arm(id, now: ProcessInfo.processInfo.systemUptime) }

    /// A click on `id`'s answer buttons is ignored: too soon after an answer moved on to it (`ClickGuard`), or while its
    /// own answer is with the engine (`answerPending`).
    func clickIgnored(_ id: String) -> Bool {
        answerPending == id || clickGuard.blocks(id, now: ProcessInfo.processInfo.systemUptime)
    }

    /// V/R/W and the card buttons (UX.md §8): what they do is VerdictPlan's. `button`: a click, which with text in the
    /// follow-up field closes or follows up with it at once. Either moves on once answered (`answersAdvance`). Putting
    /// the cursor in the field (R, or Follow up with the field empty) needs no engine, so it is never refused as busy.
    /// `stay`: from the PDF's menu on the mark, the answer moves nothing on, as in Focus, nor does the choice row's answer
    /// it asks for (design/pdf-reader/PLAN.md §3.2).
    func press(_ verdict: String, for id: String, button: Bool = false, stay: Bool = false) {
        guard let c = comment(id), roundIsOpen, c.carried else { return }
        let plan = VerdictPlan.press(verdict, current: c.verdict, note: c.verdictNote ?? "", draft: draftText(id), button: button)
        if plan != .focusField, refusedWhileBusy() { return }
        // this round's words being edited on the card are saved first, and the answer starts from them
        if edit.field == .remark(id) { return commitEdit { self.press(verdict, for: id, button: button, stay: stay) } }
        run(plan, id, advance: !stay && answersAdvance)
    }

    /// ⌘↩ in the follow-up field or on the card, or Follow up with text: the field's text goes out as the follow-up (an
    /// empty field follows up without a note). `advance`: from the card (not from the Finish sheet), it moves on.
    func sendDraft(_ id: String, advance: Bool = false) {
        guard let c = comment(id), c.verdict == nil, answerable(c) else { return }
        run(VerdictPlan.sendDraft(draftText(id)), id, advance: advance && answersAdvance)
    }

    /// The choice row's Return, ⌫, Esc or ⌘↩, or its buttons. Its Esc (Cancel) needs no engine.
    func choose(_ c: CloseChoice) {
        guard let ch = edit.choice, let comment = comment(ch.id),
              c == .cancel ? roundIsOpen && comment.carried : answerable(comment) else { return }
        edit.choice = nil
        if let plan = VerdictPlan.choose(c, verdict: ch.verdict, text: ch.text, sent: ch.sent) {
            run(plan, ch.id, advance: ch.advance && answersAdvance)
        }
    }

    /// `advance`: the next card to check is selected once the answer is given.
    private func run(_ plan: VerdictPlan, _ id: String, advance: Bool) {
        switch plan {
        case .focusField:
            requestFieldFocus(id)
        case .ask(let verdict, let text, let sent):
            if panel.expanded != id { select(.comment(id), reveal: false, scroll: .centre) }
            leaveField()
            // the row takes Return and Esc: a PDF selection or box made before it goes (one made later drops the row;
            // re-anchoring keeps both keys while it lasts)
            if toolbar.reanchor == nil {
                pdf.clearSelection()
                pdf.dropPendingBox()
            }
            edit.choice = EditState.Choice(id: id, verdict: verdict, text: text, sent: sent, advance: advance)
        case .send(let answer, let focus):
            give(id, answer, focus: focus, advance: advance)
        }
    }

    /// Sends an answer, then sets the card's draft; recorded for ⌘Z (with a toast saying so) unless it is an undo or
    /// redo itself. `advance`: an answer that gives a verdict selects the next card to check.
    private func give(_ id: String, _ after: Answer, focus: Bool = false, record: Bool = true, advance: Bool = false,
                      done: ((Bool) -> Void)? = nil) {
        // only the open round's answers: the engine's `verdict` always acts on it, whatever round is shown
        guard let c = comment(id), roundIsOpen else { done?(false); return }
        let before = Answer(verdict: c.verdict, note: c.verdict == nil ? "" : c.verdictNote ?? "", draft: drafts[id] ?? "")
        var after = after
        after.note = after.verdict == nil ? "" : Self.trimmed(after.note)
        edit.choice = nil
        let key = draftsKey
        let finish = {
            self.answered(id, before: before, after: after, on: key, record: record, focus: focus, advance: advance)
            done?(true)
        }
        if c.verdict == after.verdict && before.note == after.note { return finish() }
        answerPending = id
        setVerdict(id, after.verdict, note: after.note) { ok in
            if self.answerPending == id { self.answerPending = nil }
            ok ? finish() : done?(false)
        }
    }

    /// The engine has the answer `after` (it was `before`) on `id` of the paper and round `key`: the card's draft, the
    /// undo step and the toast; then the field (`focus`), the next card (`advance`) and the click guard.
    func answered(_ id: String, before: Answer, after: Answer, on key: (paper: String, round: Int)?, record: Bool = true,
                  focus: Bool = false, advance: Bool = false) {
        // another paper was opened while the engine answered (this round's words saved as it opened): the draft and the
        // step go to the paper they belong to, and nothing here changes
        guard draftsKey?.paper == key?.paper, draftsKey?.round == key?.round else {
            if let key { keep(AnswerStep(id: id, before: before, after: after), record: record, in: key) }
            return
        }
        setDraft(id, after.draft)
        // another paper (or round) shown already, its state not in yet: the toast, whose Undo would act there, the
        // field, the next card and the click guard are not its (review 2026-10-24)
        let here = shows(key)
        if record {
            history.record(AnswerStep(id: id, before: before, after: after))
            if let v = after.verdict, v != before.verdict {
                if here { showPanelToast("\(id) " + Self.done(v), action: .undo) }
                actions.tips.dismiss()  // the first answer: the tip has done its job
            } else if after.verdict == nil && before.verdict != nil && here {
                clearPanelToast()  // a cleared answer: the toast's Undo would name what no longer is
            }
        }
        guard here else { return }
        if focus { requestFieldFocus(id) }
        let moved = advance && after.verdict != nil && self.advance(from: id)
        // no other card took its place (the last card to check, or the selection moved meanwhile): its own buttons
        // ignore a double click's second click, which would clear the answer just given (or give it again)
        if record && !moved && after.verdict != before.verdict { guardClicks(id) }
    }

    /// The paper and round of an answer (`draftsKey` when it was given) are the ones shown.
    private func shows(_ key: (paper: String, round: Int)?) -> Bool {
        key != nil && selectedPath == key?.paper && round?.n == key?.round
    }

    /// An answer's draft and step, given on a paper no longer shown: into that paper's drafts file and its kept history.
    private func keep(_ step: AnswerStep, record: Bool, in key: (paper: String, round: Int)) {
        var d = draftStore.load(paper: key.paper, round: key.round)
        d[step.id] = step.after.draft.isEmpty ? nil : step.after.draft
        draftStore.save(paper: key.paper, round: key.round, drafts: d)
        if record, var kept = histories[key.paper], kept.round == key.round {
            kept.history.record(step)
            histories[key.paper] = kept
        }
    }

    /// What the toast says was done: "resolved", "followed up", "kept as is".
    private static func done(_ verdict: String) -> String {
        verdict == "reopened" ? "followed up" : Status(verdict: verdict).word.lowercased()
    }

    /// After an answer: the next card to check, below this one, else from the top (design/ui-v2 PROPOSAL §6, decision 3;
    /// POLISH §6). It takes the answered card's place on screen (ScrollMode.slot), so nothing jumps, and its buttons
    /// ignore clicks for a moment (`ClickGuard`). Not when the selection moved on meanwhile, or when no card is left to
    /// check. Whether it moved on.
    @discardableResult
    func advance(from id: String) -> Bool {
        guard panel.expanded == id, selection == .comment(id), let next = panel.groups.nextToCheck(after: id) else { return false }
        select(.comment(next), scroll: .slot, deferPDF: true)
        guardClicks(next)
        return true
    }

    /// ⌘Z: the last answer or style change of the open round is taken back; the engine gets the answer or style before
    /// it again. Its toast only on the paper and round it was given on (another may be shown by the time the engine
    /// answers).
    func undo() {
        guard roundIsOpen, !refusedWhileBusy() else { return }
        guard let step = history.undo() else { return showPanelToast("Nothing to undo") }
        let key = draftsKey
        let toast = { (what: String) in
            if self.shows(key) { self.showPanelToast("Undone · \(step.id) is " + what, action: .redo) }
        }
        switch step {
        case .answer(let a):
            restore(a.id, a.before) { ok in ok ? toast(self.word(a.before)) : self.history.undoFailed() }
        case .style(let s):
            restyle(s, to: s.before, from: s.after) { ok in ok ? toast(s.words(self.style(s.id) ?? s.before)) : self.history.undoFailed() }
        }
    }

    /// ⇧⌘Z: the answer or style change undone last is made again.
    func redo() {
        guard roundIsOpen, !refusedWhileBusy() else { return }
        guard let step = history.redo() else { return showPanelToast("Nothing to redo") }
        let key = draftsKey
        let toast = { (what: String) in
            if self.shows(key) { self.showPanelToast("Redone · \(step.id) is " + what, action: .undo) }
        }
        switch step {
        case .answer(let a):
            restore(a.id, a.after) { ok in ok ? toast(self.word(a.after)) : self.history.redoFailed() }
        case .style(let s):
            restyle(s, to: s.after, from: s.before) { ok in ok ? toast(s.words(self.style(s.id) ?? s.after)) : self.history.redoFailed() }
        }
    }

    /// The parts of the mark the step changed, put back as `to` has them; the card is selected, as for an answer.
    private func restyle(_ s: StyleStep, to: MarkStyle, from: MarkStyle, done: @escaping (Bool) -> Void) {
        guard comment(s.id) != nil else { return done(false) }
        if tab == .checks { tab = .comments }  // the card is shown where it is outlined (UX.md §39: rows are no selection)
        if panel.expanded != s.id { select(.comment(s.id), reveal: !focus, scroll: .centre) }
        setStyle(s.id, color: to.color != from.color ? to.color : nil, kind: to.kind != from.kind ? to.kind : nil,
                 record: false, done: done)
    }

    private func style(_ id: String) -> MarkStyle? { comment(id).map { MarkStyle(color: $0.markColor, kind: $0.markKind) } }

    /// The card is selected in the group its restored answer puts it in, so an undone Resolve is back with the cards
    /// to check, not in the folded Closed group. In Focus the PDF stays where it is, as for the answer.
    private func restore(_ id: String, _ a: Answer, done: @escaping (Bool) -> Void) {
        guard let c = comment(id), canVerdict(c) else { return done(false) }
        if tab == .checks { tab = .comments }  // the card is shown where it is outlined (UX.md §39: rows are no selection)
        if panel.expanded != id {
            select(.comment(id), reveal: !focus, scroll: .centre, group: CardGroups.group(Status(verdict: a.verdict)))
        }
        leaveField()
        give(id, a, record: false, done: done)
    }

    private func word(_ a: Answer) -> String { Status(verdict: a.verdict).word }

    // MARK: Drafts (UX.md §8)

    nonisolated static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The card's unsent draft, or "" when it holds only white space.
    func draftText(_ id: String) -> String { Self.trimmed(drafts[id] ?? "") }

    /// Typing in a card's field: undo and redo no longer go back over that card's answers, so they never put a step's
    /// draft over the text typed since (UX.md §8: a typed note is never lost silently).
    func draftTyped(_ id: String, _ text: String) {
        if (drafts[id] ?? "") != text { history.forget(id, answersOnly: true) }
        setDraft(id, text)
    }

    /// The field's text changed (or a draft was set or discarded): kept in memory and in the drafts file at once.
    func setDraft(_ id: String, _ text: String) {
        guard let key = draftsKey, (drafts[id] ?? "") != text else { return }
        if showFinish { objectWillChange.send() }  // the Finish sheet lists the drafts
        let had = !draftText(id).isEmpty
        drafts[id] = text.isEmpty ? nil : text
        draftStore.save(paper: key.paper, round: key.round, drafts: drafts)
        if panel.expanded == id && edit.draft != text { edit.draft = text }
        if had != !draftText(id).isEmpty, let i = panel.cards.firstIndex(where: { $0.id == id }) {
            panel.cards[i].unsent = unsent(id)
            regroup()
        }
    }

    /// The row and card say "unsent draft": a card to check whose field holds text.
    private func unsent(_ id: String) -> Bool {
        roundIsOpen && comment(id).map { $0.carried && $0.verdict == nil } == true && !draftText(id).isEmpty
    }

    /// The drafts of the shown paper's open round, read when the paper or round changes, and the undo history with
    /// them: an open round's is kept while another paper or an earlier round is shown, and dropped once that round is
    /// finished.
    private func loadDrafts(_ st: EngineState) {
        let key = selectedPath.flatMap { p in st.round.flatMap { r in !r.closed && r.n == st.rounds.last?.n ? (p, r.n) : nil } }
        guard key?.0 != draftsKey?.paper || key?.1 != draftsKey?.round else { return }
        if let old = draftsKey { histories[old.paper] = (old.round, history) }
        draftsKey = key
        if let key { draftStore.keepOnly(paper: key.0, round: key.1) }
        drafts = key.map { draftStore.load(paper: $0.0, round: $0.1) } ?? [:]
        if let p = selectedPath, let kept = histories[p], st.rounds.last.map({ $0.closed || $0.n != kept.round }) ?? true {
            histories[p] = nil
        }
        history = key.flatMap { k in histories[k.0].flatMap { $0.round == k.1 ? $0.history : nil } } ?? AnswerHistory()
    }

    /// The choice row goes when something else takes its keys: a PDF selection or box, re-anchoring, another round.
    func dropChoice() { if edit.choice != nil { edit.choice = nil } }

    /// R, Return, or a click on Follow up with the field empty: the cursor goes into the card's field (in Focus too,
    /// whose panel shows the card: POLISH §7). It needs no engine, so it is not refused while the engine works, as a
    /// click in the field is not (review 2026-10-18); sending what is written there is.
    func requestFieldFocus(_ id: String) {
        guard let c = comment(id), roundIsOpen, c.carried, c.verdict == nil else { return }
        if edit.field != nil { commitEdit() }
        if panel.expanded != id { select(.comment(id), reveal: false, scroll: .centre) }
        edit.choice = nil
        edit.focusRequest = id
        panel.scroller.request(id, mode: .end)  // a card taller than the panel shows its end: the field, in view
    }

    func fieldFocused(_ id: String) {
        if edit.focusRequest != nil { edit.focusRequest = nil }
        if edit.choice != nil { edit.choice = nil }
        if edit.fieldFocused != id { edit.fieldFocused = id }
    }

    func fieldBlurred(_ id: String) {
        if edit.fieldFocused == id { edit.fieldFocused = nil }
    }

    /// Esc in the field: the cursor leaves it; the text stays as an unsent draft.
    func leaveField() {
        if edit.focusRequest != nil { edit.focusRequest = nil }  // EditState redraws the card on every assignment
        guard edit.fieldFocused != nil else { return }
        edit.fieldFocused = nil
        if let w = pdf.view?.window, w.firstResponder is NSTextView { w.makeFirstResponder(nil) }
    }

    /// Where the new-comment popover's note is ("p.7") while it holds text that is not saved yet, or nil.
    var unsavedNote: String? {
        guard pdf.popover?.isShown == true, let d = pdf.draft, d.changed || d.saving else { return nil }
        return d.page.map { "p.\($0 + 1)" } ?? "this page"
    }

    /// What would leave a new comment's unsaved note behind (another paper or round, Finish Round…, Comment on it… for
    /// another change, a check's Comment…) waits until it is saved or cancelled, and says so over the PDF (UX.md §8); an
    /// untouched popover just closes. true: wait.
    func waitsForNote() -> Bool {
        guard pdf.popover?.isShown == true else { return false }
        guard let place = unsavedNote else {
            pdf.popover?.close()
            return false
        }
        toast("Your new comment on \(place) is not saved · click Save or Cancel in it first")
        return true
    }

    /// For the question on quitting (UX.md §8): a new comment's note not saved yet, which quitting loses, and every
    /// unsent draft of a listed paper, which stay (a copy Use This Copy replaced keeps its drafts under its new, unlisted
    /// path, where they can be neither sent nor discarded). nil when there is neither. (An editor open on a card is
    /// saved before it is asked: `saveEditBeforeQuit`.)
    func unsentDraftsQuestion() -> (title: String, detail: String)? {
        let listed = Set(self.papers.map(\.path))
        let all = draftStore.all().filter { listed.contains($0.paper) }
        let papers = Dictionary(grouping: all, by: \.paper).sorted { $0.key < $1.key }.map { path, ds -> String in
            let title = self.papers.first { $0.path == path && !$0.title.isEmpty }?.title
            let ids = ds.map(\.id).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            return ids.joined(separator: ", ") + " in “" + (title ?? (path as NSString).lastPathComponent) + "”"
        }
        return Self.quitQuestion(note: unsavedNote, drafts: all.count, listed: papers.joined(separator: "; "))
    }

    /// The question's words: `note`, where an unsaved new comment's note is; `drafts`, how many unsent drafts there are,
    /// `listed` by id and paper.
    nonisolated static func quitQuestion(note: String?, drafts: Int, listed: String) -> (title: String, detail: String)? {
        let kept = "Drafts stay on this Mac and come back on their cards; nothing goes to the student until you send it."
        let some = drafts == 1 ? "an unsent draft" : "\(drafts) unsent drafts"
        if let note {
            return ("Your new comment on \(note) is not saved",
                    "Quitting discards its note. Click Cancel, then Save in the comment."
                        + (drafts == 0 ? "" : " You also have \(some): \(listed). " + kept))
        }
        guard drafts > 0 else { return nil }
        return ("You have " + some, listed + ". " + kept)
    }

    /// What quitting waits for (`saveEditBeforeQuit`).
    enum QuitSave { case nothing, waiting, refused }

    /// Quitting (UX.md §8): an editor open on a card (a new comment's note, this round's words) is saved first, as when
    /// focus leaves it. `.waiting`: `done` is called once the engine has answered (false: it refused, and the editor
    /// stays open with the text), and quitting is asked again then. `.refused`: it could not be sent. `.nothing`:
    /// nothing to wait for.
    func saveEditBeforeQuit(_ done: @escaping (Bool) -> Void) -> QuitSave {
        if let t = edit.tagging { closeTagPicker(t) }  // a card's picker open: its tags are sent first
        if edit.field != nil && !edit.saving { commitEdit(focusLost: true) }
        guard edit.field != nil else { return .nothing }  // unchanged, or its card's words became a draft
        guard edit.saving else { return .refused }
        editSaved = done
        return .waiting
    }

    /// Mark checked (V on the Changes tab, or its button), or clear it (UX.md §16). `advance`: after marking, the next
    /// unrequested change that still needs checking is selected in its place (`ScrollMode.slot`), as an answer moves on
    /// to the next card; its buttons (else this change's own) ignore clicks for a moment, so a double click checks one.
    func toggleChecked(_ id: String, advance: Bool = false) {
        guard let paper = selectedPath, let ch = change(id), roundIsOpen, !refusedWhileBusy() else { return }
        let checking = !(ch.checked ?? false)
        call("check_change", ["paper": paper, "id": id, "checked": checking])
        let list = changes.unrequested
        if advance, checking, let i = list.firstIndex(where: { $0.id == id }),
           let next = (list[(i + 1)...] + list[..<i]).first(where: { !$0.handled && $0.id != id }) {
            select(.change(next.id), scroll: .slot, deferPDF: true)
            guardClicks(next.id)
        } else {
            guardClicks(id)
        }
    }

    /// Comment on this change: its words selected in the PDF and the new-comment editor opened on them. An edit that
    /// prints no words there (an `\input` renamed, formatting only) has nothing to select, and says so (POLISH §0).
    func commentOnChange(_ id: String) {
        // a note being written for another change keeps its change selected and the PDF where it is
        guard let ch = change(id), roundIsOpen, !waitsForNote(), !refusedWhileBusy() else { return }
        if selection != .change(id) { select(.change(id), reveal: false, scroll: nil) }
        if !pdf.commentOn(ch) { toast(Self.noWordsToComment) }
    }

    static let noWordsToComment = "This edit prints no words in the PDF to select. Select text near it to comment there."

    // MARK: Finish Round (UX.md §17)

    /// Finish Round…: one sheet with what goes out, what is left, the unsent drafts and the round's card so far. An
    /// editor open on a card is saved first; a new comment's note being written waits, and says so, so
    /// nothing typed is left out of the sheet unseen. While the engine works it says "Still loading…", as the card's
    /// actions do (the done card's Finish Round… ignored the click without a word).
    func openFinish() {
        guard roundIsOpen, !refusedWhileBusy(), !waitsForNote() else { return }
        commitEdit(focusLost: true)
        leaveField()
        edit.choice = nil
        finishPreview.done = nil
        finishPreview.error = nil
        finishPreview.handled = [:]
        showFinish = true
    }

    /// The sheet's Send as follow-up (`send`) or Discard on an unsent draft. Its row stays where it is and says what was
    /// done, so the next draft's buttons do not slide under the pointer, and for 0.4 s the sheet's draft buttons ignore
    /// clicks: a double click acts on one draft (interaction review 2026-10-18). false: ignored.
    @discardableResult
    func finishDraft(_ id: String, send: Bool) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime, text = drafts[id] ?? ""
        guard now >= finishPreview.guardUntil, !Self.trimmed(text).isEmpty, let c = comment(id) else { return false }
        finishPreview.guardUntil = now + ClickGuard.interval
        finishPreview.handled[id] = FinishSummary.Handled(draft: FinishSummary.Draft(id: id, text: Self.trimmed(text), status: Status(c)),
                                                         raw: text, sent: send)
        if send { sendDraft(id) } else { setDraft(id, "") }
        return true
    }

    /// The Undo of a draft discarded in the sheet: its words are back, on its card and in the sheet.
    func finishRestoreDraft(_ id: String) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= finishPreview.guardUntil, let h = finishPreview.handled[id], !h.sent else { return }
        finishPreview.guardUntil = now + ClickGuard.interval
        finishPreview.handled[id] = nil
        setDraft(id, h.raw)
    }

    /// Finish Round: the engine writes final.pdf (and email.txt, which backups and exports keep) and the round closes.
    /// The sheet turns into the round's card (its Done then says where final.pdf is); a sheet closed meanwhile has the
    /// window's line say it at once. Unsent drafts left in the sheet are dropped (the sheet says they are not sent).
    func finishRound() {
        guard let paper = selectedPath, let n = round?.n, canFinish else { return }
        finishPreview.finishing = true
        finishPreview.error = nil
        call("finish", ["paper": paper, "checks": checksOn, "groups": Array(checkKinds).sorted(),
                        "disabled": Array(disabledCheckCodes).sorted()], quiet: true, then: { reply in
            self.finishPreview.finishing = false
            self.draftStore.save(paper: paper, round: n, drafts: [:])
            let card = RoundCardAsk(stats: self.roundStats(reply.state), justFinished: true, finalPdf: reply.state.round?.finalPdf)
            if self.showFinish { self.finishPreview.done = card } else { self.finishedNotice(n, final: card.finalPdf) }
            self.backups.roundFinished()
        }, failed: { message in
            self.finishPreview.finishing = false
            self.finishPreview.error = message
            // the sheet closed meanwhile (Cancel or Esc during "Finishing…"): the window's alert says it, else nothing would
            if !self.showFinish { self.alertMessage = "Round \(n) was not finished: " + message }
        })
    }

    /// Where Copy Email Text and the card's Copy Image put what they copy: the clipboard, or in a test run
    /// (--background) a pasteboard of its own, so the user's clipboard is left alone.
    static let clipboard = LaunchOptions.background ? NSPasteboard(name: NSPasteboard.Name("com.paperole.test")) : .general

    /// The sheet's Review and Show card: it closes, and the panel shows the card or change.
    func review(_ s: Selection?) {
        showFinish = false
        guard let s else { return }
        if case .change = s { tab = .changes } else { tab = .comments }
        select(s, scroll: .centre)
    }

    /// The sheet's Show on the changed paragraphs not read: it closes, and the PDF goes to the next one, as Next does.
    func reviewReading() {
        showFinish = false
        nextUnread()
    }

    // MARK: Inline editors (UX.md §8)

    /// Opening the editor needs no engine, so it is never refused while the engine works: only the save waits for it
    /// (queued behind the request it is working on, "Saving…" meanwhile; BACKLOG O30, after O27).
    func beginNoteEdit(_ id: String) {
        guard let c = comment(id), canEditNote(c) else { return }
        beginEdit(.note(id), text: c.note)
    }

    /// Return on an answered card, or Edit on its words: this round's follow-up or closing remark.
    func beginRemarkEdit(_ id: String) {
        guard let c = comment(id), c.verdict != nil, answerable(c) else { return }
        beginEdit(.remark(id), text: c.verdictNote ?? "")
    }

    private func beginEdit(_ f: EditState.Field, text: String) {
        if edit.saving { NSSound.beep(); return }
        if edit.field != nil && edit.field != f { commitEdit() }
        if edit.saving { return }
        let id: String
        switch f { case .note(let i), .remark(let i): id = i }
        if panel.expanded != id { select(.comment(id), reveal: false, scroll: .centre) }
        leaveField()
        edit.choice = nil
        edit.field = f
        edit.text = text
        edit.original = text
        edit.escArmed = false
    }

    /// ⌘↩, or focus leaving the editor. An unchanged note sends nothing. If the engine refuses, the editor stays open
    /// with the text and its card is selected again. `then`: once the editor has closed.
    func commitEdit(focusLost: Bool = false, then: (() -> Void)? = nil) {
        guard let f = edit.field, !edit.saving else { return }
        let text = edit.text
        let closed = {
            self.closeEdit()
            then?()
            self.editSaveEnded(true)
        }
        let paper = selectedPath
        switch f {
        case .note(let id):
            guard text != edit.original, let paper else { return closed() }
            edit.saving = true
            call("edit_comment", ["paper": paper, "id": id, "note": text], then: { _ in closed() },
                 failed: { _ in self.editFailed(id, paper: paper) })
        case .remark(let id):
            guard text != edit.original, let c = comment(id) else { return closed() }
            // the card's answer was cleared meanwhile: the words go to its field as an unsent draft
            guard c.verdict != nil else {
                setDraft(id, text)
                return closed()
            }
            edit.saving = true
            give(id, Answer(verdict: c.verdict, note: text)) { ok in ok ? closed() : self.editFailed(id, paper: paper) }
        }
    }

    /// The engine refused the edit: its card is selected again, unless another paper is shown now (the alert says why).
    private func editFailed(_ id: String, paper: String?) {
        edit.saving = false
        if panel.expanded != id && paper == selectedPath { select(.comment(id), reveal: false, scroll: .centre) }
        editSaveEnded(false)
    }

    /// Quitting waits for the editor's save (`saveEditBeforeQuit`).
    private var editSaved: ((Bool) -> Void)?

    private func editSaveEnded(_ ok: Bool) {
        guard let f = editSaved else { return }
        editSaved = nil
        f(ok)
    }

    /// Esc: closes an unchanged editor; a changed note needs a second Esc (this round's words close at once).
    func cancelEdit() {
        guard let f = edit.field, !edit.saving else { return }
        if case .note = f, edit.text != edit.original && !edit.escArmed {
            edit.escArmed = true
        } else {
            closeEdit()
        }
    }

    func closeEdit() {
        edit.field = nil
        edit.text = ""
        edit.original = ""
        edit.saving = false
        edit.escArmed = false
    }

    /// After a new state: the expanded card's field shows its draft; a card that is answered now (or gone) has no
    /// field, and its choice row goes.
    private func syncField() {
        let id = panel.expanded
        let open = id.flatMap { comment($0) }.map { canVerdict($0) && $0.verdict == nil } ?? false
        if !open, edit.fieldFocused != nil || edit.focusRequest != nil { leaveField() }
        if let ch = edit.choice, ch.id != id || comment(ch.id) == nil || !roundIsOpen { edit.choice = nil }
        let d = id.flatMap { drafts[$0] } ?? ""
        if edit.draft != d { edit.draft = d }
    }

    // MARK: Re-anchoring (UX.md §8)

    /// Like a note's editor, re-anchoring starts while the engine works; Place waits for it (the request is queued).
    func beginReanchor(_ id: String) {
        guard let c = comment(id), roundIsOpen else { return }
        commitEdit()
        dropChoice()
        tab = .comments
        if panel.expanded != id { select(.comment(id), scroll: .centre) }
        pdf.clearSelection()
        pdf.dropPendingBox()
        toolbar.reanchorError = nil
        toolbar.reanchor = c.id
        syncCheckComment()
        pdf.refreshMarks()
    }

    func leaveReanchor() {
        guard toolbar.reanchor != nil else { return }
        toolbar.reanchor = nil
        toolbar.reanchorError = nil
        syncCheckComment()
        pdf.clearSelection()
        pdf.dropPendingBox()
        pdf.refreshMarks()
    }

    /// Place (or Return): sends the selection or the pending box as the comment's new anchor.
    func placeReanchor() {
        guard let id = toolbar.reanchor, let c = comment(id), let paper = selectedPath else { return }
        var params: [String: Any] = ["paper": paper, "id": id]
        guard let a = pdf.pendingAnchor() else {
            toolbar.reanchorError = "Select the text or ⌥-drag a box first."
            return
        }
        params.merge(["page": a.page, "rects": a.rects, "text": a.text]) { a, _ in a }
        let isBox = a.isBox
        if isBox {
            params["kind"] = MarkKind.box.rawValue
        } else if c.markKind == .box {
            params["kind"] = MarkKind.highlight.rawValue
        }
        toolbar.reanchorError = nil
        call("reanchor", params, quiet: true, then: { _ in
            self.leaveReanchor()
            self.select(.comment(id), reveal: true, scroll: .centre)
        }, failed: { message in self.toolbar.reanchorError = message })
    }

    // MARK: Requests

    /// Sends a request. One sent while another runs waits for it (the engine runs requests in order), so
    /// switching papers or adding one during an ingest is never dropped. `quiet` leaves the error to `failed`.
    func call(_ method: String, _ params: [String: Any], quiet: Bool = false, then: ((Reply) -> Void)? = nil,
                      failed: ((String) -> Void)? = nil) {
        guard fixtureURL == nil else {
            let m = "Fixture mode: the engine is not running, so nothing is saved."
            if !quiet { alertMessage = m }
            failed?(m)
            return
        }
        let json: Data
        do { json = try JSONSerialization.data(withJSONObject: params) } catch {
            if !quiet { alertMessage = error.localizedDescription }
            failed?(error.localizedDescription)
            return
        }
        let paper = params["paper"] as? String
        if !Self.readOnlyMethods.contains(method) { ledgerEdits += 1 }
        if running == 0 { progress = "" }
        running += 1
        busy = true
        sent += 1
        let seq = sent
        let id = engine.send(method, params: json) { [weak self] message in  // now, so the engine gets them in order
            Task { @MainActor in self?.progress = message }
        }
        Task {
            var reply: Reply?
            var message = ""
            do {
                let data = try await engine.result(id)
                reply = try makeDecoder().decode(Reply.self, from: data)
            } catch {
                message = describe(error)
                if !quiet { alertMessage = message }
            }
            running -= 1
            busy = running > 0 || heldBusy
            if !busy { progress = "" }
            guard let reply else { failed?(message); return }
            if paper == selectedPath && seq > applied {
                applied = seq
                apply(reply.state)
            }
            then?(reply)
        }
    }

    /// The requests sent through `call` that change no paper (CONTRACT §7 and amendments): the overview need not be
    /// asked again after them. (`summaries`, `overview` and a round's card's `state` are sent to the engine directly.)
    static let readOnlyMethods: Set<String> = ["state", "prose"]

    func apply(_ st: EngineState) {
        TagCatalog.learn(st.tagNames)
        state = st
        if stateError != nil { stateError = nil }
        stateVersion += 1
        readableBlocks = Set(st.reading?.paragraphs.map(\.block) ?? [])
        let read = Set(st.reading?.read ?? [])
        if readBlocks != read { readBlocks = read }
        if let path = selectedPath, let s = st.summary.map(withReading), summaries[path] != s { summaries[path] = s }
        if let path = selectedPath, let i = papers.firstIndex(where: { $0.path == path }),
           papers[i].title != st.paper.title || papers[i].student != st.paper.student {
            papers[i].title = st.paper.title
            papers[i].student = st.paper.student
            if !transientPaths.contains(path) { persist() }
        }
        loadDrafts(st)
        buildCards(st)
        switch selection {
        case .comment(let id)? where comment(id) == nil: selection = nil; panel.expanded = nil
        case .change(let id)? where change(id) == nil: selection = nil; changes.expanded = nil
        default: break
        }
        if let id = toolbar.reanchor, comment(id) == nil || !roundIsOpen { leaveReanchor() }
        if let id = edit.id, comment(id) == nil { closeEdit() }
        syncField()
        if focus && round?.build.pdf == nil { setFocus(false) }  // Focus is for a PDF
        let shown = selectedPath.map { "\($0)|\(st.round?.n ?? 0)|\(st.round?.created ?? "")" }
        if shown != readingRound {
            readingRound = shown
            currentParagraph = nil
        }
        buildOutline()
        requestReading()
        requestLinks()
        requestChecks()
        if let id = pendingSelect {
            pendingSelect = nil
            let reveal = pendingSelectReveal
            pendingSelectReveal = true
            if comment(id) != nil {
                select(.comment(id), reveal: reveal, scroll: .centre)
                // At launch the window still resizes: centre the card again once the view has settled.
                pdf.whenSettled { [weak self] in self?.panel.scroller.request(id, mode: .centre) }
            } else if change(id) != nil {
                tab = .changes
                select(.change(id))
            }
        }
        navigationApplied(st)
    }

    /// The build PDF of each round, for crops.
    private func roundPDFs(_ st: EngineState) -> [Int: String] {
        var pdfs: [Int: String] = [:]
        for r in st.rounds { if let p = resolve(r.pdf) { pdfs[r.n] = p } }
        if let n = st.round?.n, pdfs[n] == nil, let p = pdfURL?.path { pdfs[n] = p }
        return pdfs
    }

    /// The card models, once per applied state (UX.md §10.3). Unchanged sections are not republished.
    private func buildCards(_ st: EngineState) {
        let n = st.round?.n ?? 0
        let pdfs = roundPDFs(st)
        let textX = st.round?.build.textX ?? []
        let figures = Dictionary(st.changes.compactMap { ch in ch.figure.map { (ch.id, $0) } }, uniquingKeysWith: { a, _ in a })
        let edits = CardContent.edits(st.changes)
        let emailed = Dictionary(st.rounds.compactMap { r in r.closed ? shortDate(r.closedAt).map { (r.n, $0) } : nil },
                                 uniquingKeysWith: { a, _ in a })
        // the Changes tab's models first: a card shows the edits its student's note linked elsewhere as that tab does
        let changeModels = self.changeModels(st)
        let byID = Dictionary(changeModels.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let cards = Self.ordered(st.comments).map {
            let closed = $0.verdict == "verified" || $0.verdict == "wontfix"
            let reopenIn = viewingEarlierRound && closed && $0.revivable == true ? latestRound?.n : nil
            var m = CardModel($0, round: n, pdfs: pdfs, textX: textX, showChanges: showChangedWords, figures: figures,
                              edits: edits, emailed: emailed, open: roundIsOpen, student: st.paper.student, changes: byID,
                              catalog: tags.catalog, suggest: tags.suggest, reopenIn: reopenIn)
            m.unsent = unsent($0.id)
            return m
        }
        panel.cards = cards
        panel.sections = ListSections.make(st.reading, comments: st.comments, columns: st.round?.build.columns ?? [])
        // the tag filter (UX.md §27): another paper shows all its comments; another round keeps it while some of its
        // comments have the tag
        if filterPaper != selectedPath {
            filterPaper = selectedPath
            panel.filter = launchFilter
            launchFilter = nil
        } else if panel.round != n, let f = panel.filter, !cards.contains(where: { ListFilter.matches($0, f) }) {
            panel.filter = nil
        }
        // Another round, or this one just finished: the card shows where it is now (a resolved card held in To check
        // would read as "Left open").
        if panel.round != n || panel.roundOpen != roundIsOpen || panel.held?.id != panel.expanded {
            panel.held = panel.expanded.flatMap { id in cards.first { $0.id == id }.map { (id, CardGroups.group($0.status)) } }
            panel.heldKey = nil
            // a selected card is listed: its group, folded, is shown (a card resolved with the last click before Finish
            // stayed selected in the folded Closed this round, unlisted; integration 2026-10-18)
            if panel.held?.group == .closed && !panel.showClosed { panel.showClosed = true }
            if panel.held?.group == .forStudent && !panel.showStudent { panel.showStudent = true }
        }
        regroup()
        if panel.round != n { panel.round = n }
        let open = roundIsOpen
        if panel.roundOpen != open { panel.roundOpen = open }
        if edit.roundOpen != open { edit.roundOpen = open }
        if edit.round != n { edit.round = n }
        buildChanges(st, models: changeModels)
    }

    /// The groups again from the cards (UX.md §1): the expanded card stays where it was shown (`panel.held`; by tag or
    /// section `panel.heldKey`, set where it is first listed while selected), whatever the tag filter (§27).
    private func regroup() {
        let held = panel.held.flatMap { $0.id == panel.expanded ? $0 : nil }
        let g = CardGroups(panel.cards, held: held, place: held != nil ? panel.heldKey : nil, grouping: panel.grouping,
                           filter: panel.filter, catalog: tags.catalog, sections: panel.sections)
        if let h = held, panel.heldKey == nil, panel.grouping != .status { panel.heldKey = g.key(of: h.id) }
        if g != panel.groups { panel.groups = g }
        updateListBar()
    }

    /// The line over the list (UX.md §27): the round's tags with their counts, the filter, the arrangement.
    private func updateListBar() {
        let b = listBar
        let options = ListFilter.options(panel.cards, catalog: tags.catalog, filter: panel.filter)
        if b.options != options { b.options = options }
        if b.filter != panel.filter { b.filter = panel.filter }
        if b.grouping != panel.grouping { b.grouping = panel.grouping }
        if b.shown != !panel.cards.isEmpty { b.shown = !panel.cards.isEmpty }
        let kept = panel.filter.map { f in panel.cards.filter { ListFilter.matches($0, f) }.count } ?? panel.cards.count
        if b.total != panel.cards.count { b.total = panel.cards.count }
        if b.kept != kept { b.kept = kept }
    }

    /// The list menu's Show section, or the line's Show All (UX.md §27): only the comments with that tag
    /// (`TagCatalog.untagged`: those with none), or all of them again (nil). A selected card the filter hides is no
    /// longer selected, as with a folded group's Hide: what is not listed takes no keys.
    func setTagFilter(_ f: String?) {
        guard f != panel.filter else { return }
        panel.filter = f
        filterPaper = selectedPath
        if let f, let id = panel.expanded, let c = panel.cards.first(where: { $0.id == id }), !ListFilter.matches(c, f) {
            select(nil, reveal: false, scroll: nil)
        }
        regroup()
        if let id = panel.expanded { panel.scroller.request(id, mode: .centre) } else { panel.scroller.table?.scrollToTop() }
    }

    /// "By status ⌄" (UX.md §27): the list by status, by tag or by section, kept as the viewer's choice (never by a
    /// test run). The selected card is shown in its own group of the new arrangement, and in view.
    func setGrouping(_ g: ListGrouping) {
        guard g != panel.grouping else { return }
        panel.grouping = g
        if fixtureURL == nil { Prefs.set(g.rawValue, ListGrouping.key) }
        panel.heldKey = nil
        if g == .status, let h = panel.held, h.id == panel.expanded {
            if h.group == .closed && !panel.showClosed { panel.showClosed = true }
            if h.group == .forStudent && !panel.showStudent { panel.showStudent = true }
        }
        regroup()
        if let id = panel.expanded { panel.scroller.request(id, mode: .centre) } else { panel.scroller.table?.scrollToTop() }
    }

    /// The panel expands `id`, which stays in `group` (where it is shown now when nil) until the selection leaves it;
    /// the card the selection leaves moves to its own group now, after the new card is laid out, so the panel keeps it
    /// in place (PanelTable.show). A card of a folded group shows the group; a card the tag filter hides is listed while
    /// it is selected (a mark clicked in the PDF, Jump), and leaves the list with the selection (UX.md §27).
    private func expand(_ id: String?, in group: CardGroups.Group?) {
        let shown = id.flatMap { panel.groups.group(of: $0) }
        let target = group ?? shown
        if panel.grouping == .status {  // only the status groups fold
            if target == .closed && !panel.showClosed { panel.showClosed = true }
            if target == .forStudent && !panel.showStudent { panel.showStudent = true }
        }
        let left = panel.held, leftKey = panel.heldKey
        let listed = id.map { panel.groups.key(of: $0) != nil } ?? true
        panel.held = id.flatMap { i in target.map { (i, $0) } }
        panel.heldKey = id.flatMap { panel.groups.key(of: $0) }
        panel.expanded = id
        let moves = left.map { l in
            guard l.id != id, let c = panel.cards.first(where: { $0.id == l.id }) else { return false }
            if let f = panel.filter, !ListFilter.matches(c, f) { return true }  // listed only while it was selected
            switch panel.grouping {
            case .status: return CardGroups.group(c.status) != l.group
            case .tag: return leftKey != .tag(ListFilter.tagKey(c, filter: panel.filter))
            case .section: return leftKey != .section(panel.sections.of[c.id])
            }
        } ?? false
        if moves || target != shown || !listed { regroup() }
    }

    /// The change models (UX.md §16), in the PDF's order: page, the left column before the right, top.
    private func changeModels(_ st: EngineState) -> [ChangeModel] {
        let n = st.round?.n ?? 0
        let gaps = st.round?.build.columns ?? []
        let statuses = Dictionary(st.comments.map { ($0.id, Status($0)) }, uniquingKeysWith: { a, _ in a })
        let colors = Dictionary(st.comments.map { ($0.id, $0.markColor) }, uniquingKeysWith: { a, _ in a })
        let notes = Dictionary(st.comments.compactMap { c in c.studentNote.map { (c.id, $0) } }, uniquingKeysWith: { a, _ in a })
        func key(_ ch: Change) -> (Int, Int, Double, Double) {
            guard let p = ch.page, let r = ch.rects.first, r.count == 4 else { return (Int.max, 0, 0, 0) }
            let gap = p < gaps.count ? gaps[p]?.first : nil
            return (p, gap.map { r[0] >= $0 - 3 ? 1 : 0 } ?? 0, r[1], r[0])
        }
        let pdfs = roundPDFs(st), textX = st.round?.build.textX ?? []
        return st.changes.sorted { key($0) < key($1) }.map {
            ChangeModel($0, round: n, pdfs: pdfs, textX: textX, statuses: statuses, colors: colors, read: isRead($0),
                        notes: notes, warnings: st.noteWarnings ?? [])
        }
    }

    /// The Changes tab's lists from the change models (`changeModels`).
    private func buildChanges(_ st: EngineState, models: [ChangeModel]) {
        let n = st.round?.n ?? 0
        let unrequested = models.filter(\.unrequested), linked = models.filter { !$0.unrequested }
        if changes.unrequested != unrequested { changes.unrequested = unrequested }
        if changes.linked != linked { changes.linked = linked }
        let hint = n <= 1 ? "Round 1 has nothing to compare with." : models.isEmpty ? "The source did not change." : ""
        if changes.hint != hint { changes.hint = hint }
        if changes.roundOpen != roundIsOpen { changes.roundOpen = roundIsOpen }
    }

    // MARK: Selection and keys

    /// Selects a comment or change. `reveal` scrolls the PDF to its mark if it is off screen and flashes it; `scroll`
    /// scrolls the panel to the card; `flash` flashes the mark without moving the PDF (a click on the mark).
    /// `deferPDF` (J/K): the PDF follows on the next turn of the run loop (`pdfStep`). `group`: the group a card shows in
    /// while selected, when not the one it is listed in now (an undo). `step`: what the PDF's move is for Back (PLAN
    /// §5.2): one of a run through the comments by default, a look-up (Jump), or nil (Review being entered).
    func select(_ s: Selection?, reveal: Bool = true, scroll: ScrollMode? = .centre, flash: Bool = false,
                deferPDF: Bool = false, group: CardGroups.Group? = nil, step: PDFSteps.Kind? = .run) {
        // Focus's panel shows the one card at its top (POLISH §7): the list scrolls to the card when Focus ends
        let scroll = focus ? nil : scroll
        let id: String? = { if case .comment(let i)? = s { return i } else { return nil } }()
        let chid: String? = { if case .change(let i)? = s { return i } else { return nil } }()
        if let e = edit.id, e != id { commitEdit(focusLost: true) }
        if let t = edit.tagging, t != id { closeTagPicker(t) }  // its card is left: its tags are written (UX.md §24)
        let previous = panel.expanded
        selection = s
        if case .change? = s {} else if previous != id {
            if !edit.showAll.isEmpty { edit.showAll = [] }
            if edit.swatches != nil { edit.swatches = nil }
            leaveField()  // the field never keeps (or takes) the cursor across a selection
            if edit.choice != nil { edit.choice = nil }
            let d = id.flatMap { drafts[$0] } ?? ""
            if edit.draft != d { edit.draft = d }
            if let id, let scroll { panel.scroller.request(id, mode: scroll) }
            expand(id, in: group)
        } else if let id, let scroll {
            panel.scroller.request(id, mode: scroll)
        }
        if let chid {
            if !changes.showLinked && changes.linked.contains(where: { $0.id == chid }) { changes.showLinked = true }
            if let scroll { changes.scroller.request(chid, mode: scroll) }
            if changes.expanded != chid { changes.expanded = chid }
        }
        pdfStep?.timer.invalidate()
        pdfStep = nil
        if deferPDF {
            let timer = Timer(timeInterval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.showStepInPDF() }
            }
            RunLoop.main.add(timer, forMode: .common)
            pdfStep = (s, reveal, flash, step, timer)
        } else {
            showInPDF(s, reveal: reveal, flash: flash, step: step)
        }
    }

    /// A J/K step's PDF part: the outline on the selected mark, the scroll to it and its flash. A timer fires only after
    /// the run loop has waited, so after the turn that laid out and drew the new card: the two do not share a frame
    /// (UX.md §10.9), and steps faster than that (a held key) move the PDF once, to the last one.
    private var pdfStep: (selection: Selection?, reveal: Bool, flash: Bool, step: PDFSteps.Kind?, timer: Timer)?

    private func showStepInPDF() {
        guard let step = pdfStep else { return }
        pdfStep = nil
        if step.selection == selection { showInPDF(step.selection, reveal: step.reveal, flash: step.flash, step: step.step) }
    }

    private func showInPDF(_ s: Selection?, reveal: Bool, flash: Bool, step: PDFSteps.Kind?) {
        let id: String? = { if case .comment(let i)? = s { return i } else { return nil } }()
        let chid: String? = { if case .change(let i)? = s { return i } else { return nil } }()
        pdf.setSelected(id)
        pdf.setSelectedChange(chid)
        guard let s else { return }
        switch s {
        case .comment(let cid):
            guard let c = comment(cid) else { return }
            if reveal { pdf.reveal(page: c.page, rects: c.rects, step: step) } else if flash { pdf.flash(page: c.page, rects: c.rects) }
        case .change(let chid):
            guard let ch = change(chid) else { return }
            if reveal { pdf.reveal(page: ch.page, rects: ch.rects, step: step) } else if flash { pdf.flash(page: ch.page, rects: ch.rects) }
        }
    }

    /// The keys and the PDF follow the tab shown: its expanded card or change becomes the selection, and only it is
    /// outlined in the PDF.
    private func tabChanged() {
        if showNoteWarnings { showNoteWarnings = false }  // its line slides away with the Comments page
        let s: Selection?
        switch tab {
        case .comments: s = panel.expanded.map { .comment($0) }
        case .changes: s = changes.expanded.map { .change($0) }
        case .checks: s = nil  // its rows are no selection: the PDF outlines no comment or change
        }
        if tab == .checks {
            // its page has no list to place the toast: the panel's foot
            let p = actions.toastPlace
            if p.below != nil { p.below = nil }
            if p.bottom != 16 { p.bottom = 16 }
        } else {
            checks.unhover()  // the hidden page's rows get no exit from the pointer
        }
        pdf.setSelectedCheck(selectedCheckID, place: selectedCheckPlace)
        if let e = edit.id, s != .comment(e) { commitEdit(focusLost: true) }
        if tab != .comments { leaveField(); edit.choice = nil }
        selection = s
        pdfStep?.timer.invalidate()
        pdfStep = nil
        pdf.setSelected(selectedComment?.id)
        if case .change(let chid)? = s { pdf.setSelectedChange(chid) } else { pdf.setSelectedChange(nil) }
    }

    /// A click on a comment's mark or label in the PDF.
    func markClicked(_ id: String) {
        tab = .comments
        select(.comment(id), reveal: false, scroll: .centre, flash: true)
    }

    /// Show / Hide of a folded group (For the student, Closed this round; the changes answering comments); nil: the
    /// shown tab's Closed this round, or its changes answering comments. Hidden with one of its cards or changes
    /// selected, the selection goes too: what is not listed takes no keys.
    func toggleFold(_ g: FoldedGroup? = nil) {
        if g == nil && tab == .checks { return }  // the Checks' groups fold by their own Show / Hide
        switch g ?? (tab == .comments ? .closed : .linked) {
        case .student:
            panel.showStudent.toggle()
            if !panel.showStudent, let id = panel.expanded, panel.groups.group(of: id) == .forStudent {
                select(nil, reveal: false, scroll: nil)
            }
        case .closed:
            panel.showClosed.toggle()
            if !panel.showClosed, let id = panel.expanded, panel.groups.group(of: id) == .closed {
                select(nil, reveal: false, scroll: nil)
            }
        case .linked:
            changes.showLinked.toggle()
            if !changes.showLinked, let id = changes.expanded, changes.linked.contains(where: { $0.id == id }) {
                selection = nil
                changes.expanded = nil
                pdf.setSelectedChange(nil)
            }
        }
    }

    func move(_ delta: Int) {
        if tab == .checks { return moveCheck(delta) }
        let items: [Selection] = tab == .comments
            ? panel.listed.map { .comment($0.id) }
            : changes.all.map { .change($0.id) }
        guard !items.isEmpty else { return }
        let next: Int
        if let s = selection, let i = items.firstIndex(of: s) {
            next = min(max(i + delta, 0), items.count - 1)
        } else {
            next = delta > 0 ? 0 : items.count - 1
        }
        select(items[next], scroll: .centre, deferPDF: true)
    }

    /// Keys in the review's window, never while a text field or editor has focus (UX.md §9).
    func handleKey(_ event: NSEvent) -> Bool {
        guard let win = NSApp.keyWindow, win === NSApp.mainWindow, Self.isReviewWindow(win), win.attachedSheet == nil,
              Self.routesKeys(firstResponder: win.firstResponder) else { return false }
        return performKey(event)
    }

    /// The review's window (its closing quits: `QuitOnClose`), not Settings, which SwiftUI also makes the main window
    /// while it is key: its keys stay its own (review 2026-10-24).
    static func isReviewWindow(_ w: NSWindow) -> Bool { w.delegate is QuitOnClose }

    /// Whether the keys go through the keyboard map: not while an editor has the cursor. Text that is only selectable
    /// (a card's note, its paper text, a bubble) becomes the first responder when clicked, and keeps ⌘C and the keys the
    /// map does not use, but not the others.
    static func routesKeys(firstResponder r: NSResponder?) -> Bool {
        guard let t = r as? NSText else { return true }
        return !t.isEditable
    }

    /// The key's name for KeyRoute: "j", "shift-c", "return", "cmd-return", "cmd-shift-z"…; nil with ⌃ or ⌥.
    static func keyName(_ event: NSEvent) -> String? {
        let mods = event.modifierFlags
        guard mods.intersection([.control, .option]).isEmpty else { return nil }
        let k: String?
        switch event.keyCode {
        case 36, 76: k = "return"
        case 53: k = "esc"
        case 51, 117: k = "delete"
        default: k = event.charactersIgnoringModifiers?.lowercased()
        }
        guard let k else { return nil }
        if mods.contains(.command) { return "cmd-" + (mods.contains(.shift) ? "shift-" : "") + k }
        return k == "c" && mods.contains(.shift) ? "shift-c" : k
    }

    var keyState: KeyState {
        var s = KeyState()
        s.roundOpen = roundIsOpen
        s.reanchoring = toolbar.reanchor != nil
        s.textSelection = hasPDFSelection
        s.pendingBox = toolbar.hasBox
        s.boxArmed = toolbar.boxArmed
        s.reading = readingMarksOn
        s.markBar = pdf.markBarShown
        if tab == .comments, let c = selectedComment {
            s.card = c.carried ? .carried(answered: c.verdict != nil) : .new
            s.draft = c.carried && c.verdict == nil && !draftText(c.id).isEmpty
            s.choice = edit.choice?.id == c.id
        }
        if tab == .changes, case .change? = selection { s.changeSelected = true }
        return s
    }

    func performKey(_ event: NSEvent) -> Bool {
        if hub != nil { return false }  // a page of the hierarchy has no keys of its own: the sidebar's list keeps them
        if level == .overview { return overviewKey(event) }  // the hidden Review takes no keys
        if pdf.previewShown, Self.keyName(event) == "esc" {  // a reference preview closes first (PLAN §4.1)
            pdf.closePreview()
            return true
        }
        if pdf.laneShown {  // the column's window closes at once on any key; Esc does nothing else (BRIEF §4.1)
            pdf.closeLane()
            if Self.keyName(event) == "esc" { return true }
        }
        guard state != nil, let key = Self.keyName(event), let action = KeyRoute.action(key, keyState) else { return false }
        perform(action)
        return true
    }

    func perform(_ action: KeyAction) {
        let id = selectedComment?.id
        switch action {
        case .next: move(1)
        case .previous: move(-1)
        case .verdict(let v): if let id { press(v, for: id) }
        case .openEditor: beginComment()
        case .pendingColor(let c): toolbar.setColor(c)
        case .pendingKind(let k): toolbar.setKind(k)
        case .clearSelection:
            pdf.clearSelection()
            pdf.dropPendingBox()
        case .place: placeReanchor()
        case .leaveReanchor: leaveReanchor()
        case .editNote: if let id { beginNoteEdit(id) }
        case .focusField: if let id { requestFieldFocus(id) }
        case .editRemark: if let id { beginRemarkEdit(id) }
        case .sendDraft: if let id { sendDraft(id, advance: true) }
        case .choose(let c): choose(c)
        case .undo: undo()
        case .redo: redo()
        case .recolor(let c): if let id { setStyle(id, color: c) }
        case .delete: if let id { requestDelete(id) }
        case .armBox: toolbar.boxArmed.toggle()
        case .check: if case .change(let chid)? = selection { toggleChecked(chid, advance: !focus) }
        case .commentOnChange: if case .change(let chid)? = selection { commentOnChange(chid) }
        case .nextUnread: nextUnread()
        case .markRead: markRead()
        case .markSectionRead: markSectionRead()
        case .toggleFocus: setFocus(!focus)
        case .hideMarkBar: pdf.hideMarkBar()
        }
    }

    /// Return, Comment, or Add comment…: on the selection or the pending box.
    func beginComment() { pdf.beginComment() }

    // MARK: Reading in the PDF view (UX.md §18)

    /// The shown round's paragraphs to read, in reading order (none until the engine has found them).
    var paragraphs: [Paragraph] { state?.reading?.paragraphs ?? [] }

    func paragraph(_ block: Int) -> Paragraph? { paragraphs.first { $0.block == block } }

    /// Bars, N, C and Shift-C are for round 2 on: in round 1 every paragraph is new, and finishing it marks them all
    /// read.
    var readingTracked: Bool { Reading.tracked(round: round?.n) }

    /// The paragraphs with a bar in the PDF: from round 2 on, those not confirmed read (the student changed them since
    /// the advisor last read them, or they were marked unread); none while reading marks are off.
    var barParagraphs: [Paragraph] {
        readingMarksOn && readingTracked ? paragraphs.filter { !readBlocks.contains($0.block) } : []
    }

    /// Why the reading keys cannot act here, or nil. `changing`: C and Shift-C, which change the read state.
    private func readingRefusal(changing: Bool) -> String? {
        // nothing reaches them while reading marks are off (no keys, menus, bars or buttons); said, should anything
        guard readingMarksOn else { return "Reading marks are off: Settings turns them on." }
        guard let r = round else { return "There is no round yet." }
        if r.build.pdf == nil { return "Round \(r.n) has no PDF." }
        if state?.reading == nil {
            return readingFailed.map { "The paragraphs could not be found: " + $0 } ?? "The paragraphs are still being found…"
        }
        if !readingTracked { return "Round 1 has no changed paragraphs: finishing it marks every paragraph read." }
        if changing && !roundIsOpen {
            return viewingEarlierRound ? "Round \(r.n) is read only." : "Round \(r.n) is closed: its reading cannot be changed."
        }
        return nil
    }

    /// N: the next changed paragraph still unread, after the one last gone to (while it is in view), else from the
    /// first paragraph in view; wrapping. The PDF scrolls so it is fully visible, and it flashes.
    func nextUnread() {
        if let why = readingRefusal(changing: false) { return toast(why) }
        let visible = pdf.visibleBlocks(paragraphs)  // in reading order
        let current = currentParagraph.flatMap { visible.contains($0) ? $0 : nil }
        // no paragraph in view (a page of figures): from the block at the view's third
        let top = visible.first ?? pdf.pointAtThird().flatMap { p in
            state?.reading.flatMap { Reading.block(page: p.page, x: p.x, y: p.y, paragraphs: $0.paragraphs, headings: $0.headings) }
        }
        guard let b = Reading.next(after: current, from: current == nil ? top : nil, in: paragraphs, read: readBlocks),
              let p = paragraph(b) else {
            return toast("All changed paragraphs are read.")
        }
        currentParagraph = b
        pdf.showParagraph(p.parts, step: .run)
        outlineFollow(b, hold: true)
        // the status line counts down (POLISH §3 row 3, §4.4: each number once): no toast, only VoiceOver
        let left = barParagraphs.count
        announce(left == 1 ? "1 changed paragraph to read" : "\(left) changed paragraphs to read")
    }

    /// C (and Mark Read): marks read the paragraph under the PDF selection, else the one last gone to with N while it is
    /// in view. Its bar goes at once and the status line counts down; the engine's `read` follows. On a read paragraph it
    /// only says so: one press too many never un-reads (Mark Paragraph Unread is in the PDF's menu).
    func markRead() {
        if let why = readingRefusal(changing: true) { return toast(why) }
        guard let p = keyParagraph() else { return }
        if readBlocks.contains(p.block) {
            pdf.flashParagraph(p.parts)
            return toast("This paragraph is already read.")
        }
        setRead([p.block], true)
        announceLeft()
    }

    /// A click on a paragraph's bar in the PDF (POLISH §6, its help tag "Mark read"): marks it read, in an open round.
    func barClicked(_ block: Int) {
        guard readingRefusal(changing: true) == nil, paragraph(block) != nil, !readBlocks.contains(block) else { return }
        setRead([block], true)
        announceLeft()
    }

    /// The count after marking read, for VoiceOver (the status line shows it).
    private func announceLeft() {
        let left = barParagraphs.count
        announce(left == 0 ? "Marked read · all changed paragraphs are read" : "Marked read · \(left) to read")
    }

    /// Shift-C: marks read every paragraph of that paragraph's section (from its heading to the next heading at its
    /// level or above, subsections included).
    func markSectionRead() {
        if let why = readingRefusal(changing: true) { return toast(why) }
        guard let p = keyParagraph(), let r = state?.reading else { return }
        let range = Reading.section(p.section, headings: r.headings)
        let unread = paragraphs.filter { range.contains($0.block) && !readBlocks.contains($0.block) }.map(\.block)
        let name = sectionName(p.section)
        guard !unread.isEmpty else { return toast("\(name) is already read.") }
        setRead(unread, true)
        toast("\(name): \(count(unread.count, "paragraph")) marked read")
    }

    /// The paragraph C and Shift-C act on: the one under the selection, else the one last gone to with N while it is
    /// in view. When there is none, it says what to do.
    private func keyParagraph() -> Paragraph? {
        if hasPDFSelection {
            guard let at = pdf.selectionPoint(), let b = Reading.paragraph(at: at.page, x: at.x, y: at.y, in: paragraphs),
                  let p = paragraph(b) else {
                toast("The selection is not in a paragraph to read (headings and the title are not).")
                return nil
            }
            currentParagraph = b
            return p
        }
        guard let b = currentParagraph, let p = paragraph(b), pdf.isVisible(parts: p.parts) else {
            toast("Click Next to go to a changed paragraph, or select text in one first.")
            return nil
        }
        return p
    }

    private func sectionName(_ head: Int) -> String {
        head < 0 ? "The title and abstract" : state?.reading?.headings.first { $0.block == head }.map { "“\($0.title)”" } ?? "The section"
    }

    /// The PDF's menu: Mark Paragraph Read / Unread on the paragraph under the click.
    func markParagraph(_ block: Int, read: Bool) {
        guard readingRefusal(changing: true) == nil, paragraph(block) != nil else { return }
        setRead([block], read)
        toast(read ? "Marked read" : "Marked unread · its bar is back")
    }

    /// Marks paragraphs read or unread: the bars, the Contents, the status line and the Changes tab change at once; the
    /// engine's `read` follows (paragraphs with the same text go with them), and a refusal restores them (fixture mode
    /// keeps it local).
    func setRead(_ blocks: [Int], _ read: Bool) {
        guard roundIsOpen, let paper = selectedPath, !blocks.isEmpty else { return }
        let before = readBlocks
        if read { readBlocks.formUnion(blocks) } else { readBlocks.subtract(blocks) }
        readingChanged()
        guard fixtureURL == nil else { return }
        call("read", ["paper": paper, "blocks": blocks.sorted(), "read": read], quiet: true, failed: { message in
            self.readBlocks = before
            self.readingChanged()
            self.alertMessage = message
        })
    }

    private func readingChanged() {
        if let path = selectedPath, let s = state?.summary.map(withReading), summaries[path] != s { summaries[path] = s }
        pdf.updateReadingBars()
        buildOutline()
        if let st = state { buildChanges(st, models: changeModels(st)) }
    }

    /// Settings' reading marks turned on or off: saved (never by a test run), and the bars, the status line's count,
    /// the Contents' dots, the subtitle, the papers list's line and the done card follow at once; the paragraph Next
    /// went to is forgotten when they go. The read state itself is the engine's and does not change.
    private func readingMarksChanged() {
        if options.reading == nil && fixtureURL == nil { Prefs.set(readingMarksOn, Self.readingMarksKey) }
        if !readingMarksOn { currentParagraph = nil }
        readingChanged()
    }

    /// Asks the engine for the shown round's paragraphs when the state has none yet (the `prose` call: a review folder
    /// from before, or after an engine update), once per round.
    func requestReading() {
        guard let path = selectedPath, let r = round, state?.reading == nil, r.build.pdf != nil, fixtureURL == nil
        else { return }
        let key = "\(path)|\(r.n)|\(r.created ?? "")"
        guard readingRequested.insert(key).inserted else { return }
        readingFailed = nil
        call("prose", ["paper": path, "round": r.n], quiet: true, then: { _ in
            // the round's paragraphs are found (the open round after an engine update, which the second process leaves
            // alone): the overview, asked before them, had the round pending (UX.md §21 "Pending rounds")
            self.roundsFound += 1
            if self.overview.paper == path, self.overview.data?.pending.contains(r.n) ?? true {
                self.overview.stale()
                if self.selectedPath == path && self.level == .overview { self.loadOverview() }
            }
        }, failed: { message in
            self.readingFailed = message
            self.buildOutline()
            self.openPendingFinish()  // no state follows: Your Move's Finish opens (or goes) now
        })
    }

    /// The shown round's link table for the reference previews (design/pdf-reader/PLAN.md §4), asked once per round
    /// shown: the engine's read-only `links`, sent outside `call` (it changes nothing, has no state, and is not busy
    /// work). No table (an older engine's "Unknown method", a table that could not be built, an error): a click on a
    /// link goes there, as before.
    func requestLinks() {
        let key = fixtureURL != nil ? nil : selectedPath.flatMap { path in
            round.flatMap { r in r.build.pdf == nil ? nil : "\(path)|\(r.n)|\(r.created ?? "")" }
        }
        guard key != linksKey else { return }
        linksKey = key
        pdf.setLinks(nil)
        guard let key, let path = selectedPath, let n = round?.n,
              let json = try? JSONSerialization.data(withJSONObject: ["paper": path, "round": n]) else { return }
        let id = engine.send("links", params: json)
        Task {
            let table = try? makeDecoder().decode(LinksReply.self, from: try await engine.result(id)).table
            guard linksKey == key else { return }
            pdf.setLinks(table?.round == n ? table : nil)
        }
    }

    // MARK: Checks (UX.md §39; design/pdf-reader/PLAN.md P1.5)

    private func checkSelectionChanged() {
        checksAsked = nil
        if roundIsOpen { checks.clear(); checksMarksChanged() }
        requestChecks()
    }

    /// The shown round's paper|round|created, when it has a PDF: what the checks are for.
    private var checksRoundKey: String? {
        selectedPath.flatMap { path in
            round.flatMap { r in r.build.pdf == nil ? nil : "\(path)|\(r.n)|\(r.created ?? "")|\(r.closed ? "closed" : "open")" }
        }
    }

    /// Settings' Checks turned on or off: saved (never by a test run); on asks for the shown round's checks at once, off
    /// drops them and the tab (the Comments are shown when it was).
    private func checksChanged() {
        if options.checks == nil && fixtureURL == nil { Prefs.set(checksOn, Self.checksKey) }
        if !checksOn {
            checksAsked = nil
            checks.clear()
            for s in RefSource.allCases { refs.stop(s) }  // nothing more is sent while Checks is off
            refsAsked = nil
            if tab == .checks { tab = .comments }
        }
        requestChecks()
    }

    /// The shown round's checks (UX.md §39; engine/CONTRACT.md amendments "Checks" and "Checks to the student"), asked
    /// once per round shown while Checks is on, outside `call` (nothing is busy, the window goes on): the engine of the
    /// checks builds them (`checks`, seconds on a long paper), then the window's engine gives their items (`check_items`:
    /// in an open round it numbers them, A2-03, and finds which went out before and which are fixed). An error, an older
    /// engine's "Unknown method 'checks'." or no checks leaves the tab without them; an engine before check items shows
    /// the checks without ids. A reply for another round than the one asked is dropped. Completion stays in the
    /// status bar's activity panel. A fixture run and `swift test` never ask: their checks are set (`setChecks`).
    func requestChecks() {
        let key = checksOn ? checksRoundKey : nil
        if checks.key != nil && checks.key != key { checks.clear() }
        guard key != checksAsked else { return }
        checksAsked = key
        checksRequest += 1
        let request = checksRequest
        let kinds = ChecksModel.groups.map(\.id).filter(checkKinds.contains)
        let disabled = disabledCheckCodes
        guard let key, fixtureURL == nil, !LaunchOptions.unitTest, let path = selectedPath, let n = round?.n,
              let json = try? JSONSerialization.data(withJSONObject: ["paper": path, "round": n, "groups": kinds,
                                                                     "disabled": Array(disabled).sorted()]) else { return }
        let open = roundIsOpen
        checks.roundOpen = open
        // the same round asked again (the look-ups' results): what is shown stays until the new list comes
        if !(checks.key == key && checks.phase == .ready) { checks.ask(key) }
        let pages = round?.build.pages
        checks.refreshing = true
        checks.reportError = nil
        let built = checksEngine.send("checks", params: json)
        Task {
            let reply = try? makeDecoder().decode(ChecksReply.self, from: try await checksEngine.result(built))
            guard checksAsked == key, checksRequest == request, checksOn else { return }
            guard reply?.round == n, let list = reply?.checks else {
                checks.show(nil, round: n, key: key, pages: pages)
                checks.reportError = "Checks could not finish. The PDF or its source mapping may be unavailable."
                return
            }
            var items: [Check]? = nil
            if let params = try? JSONSerialization.data(withJSONObject: ["paper": path, "round": n, "groups": kinds,
                                                                        "disabled": Array(disabled).sorted()]) {
                let asked = engine.send("check_items", params: params)
                let r = try? makeDecoder().decode(CheckItemsReply.self, from: try await engine.result(asked))
                items = r?.round == n ? r?.items : nil
            }
            guard checksAsked == key, checksRequest == request, checksOn else { return }
            // a finished round shows what went out with it (nothing, when it was finished with Checks off)
            let shown = items ?? (open ? list : [])
            checks.show(open ? shown.filter { kinds.contains($0.group) && !disabled.contains($0.code) } : shown,
                        round: n, key: key, pages: pages)
            checks.report = reply?.report
            checks.scanFindings = list
            checks.refreshing = false
            if reply?.report == nil { checks.reportError = "This scan has no execution record. Its coverage is unknown." }
            checksMarksChanged()
            requestReferences()
        }
    }

    /// The shown round's checks as if the engine had answered (tests, a fixture run): nil, none to show; ignored while
    /// Checks is off or for another round than the one shown.
    func setChecks(_ list: [Check]?, round n: Int) {
        guard checksOn, let key = checksRoundKey, round?.n == n else { return }
        checksAsked = key
        checks.roundOpen = roundIsOpen
        checks.show(list, round: n, key: key, pages: round?.build.pages)
        checks.scanFindings = list ?? []
        checksMarksChanged()
    }

    /// The new-comment editor closed: a check's My Comment… is over, saved (it was read when the comment was sent) or
    /// not.
    func commentEditorClosed() { checkComment = nil }

    /// The Finish sheet's checks: what goes out, what is marked OK and what the student answered; nil while Checks is
    /// off or the shown round's checks are not in.
    var finishChecks: FinishSummary.Checks? {
        guard checksOn else { return nil }
        if checks.phase == .asking && checks.key == checksRoundKey { return FinishSummary.Checks(sent: 0, ok: 0, toCheck: 0, pending: true) }
        guard checksShown else { return nil }
        return FinishSummary.Checks(sent: checks.sent, ok: checks.markedOK, toCheck: checks.members(.toCheck).count)
    }

    /// The Finish sheet's Review for the checks the student answered: the sheet closes, the first one's card shows.
    func reviewCheck() {
        showFinish = false
        guard let i = checks.members(.toCheck).first else { return }
        tab = .checks
        checkClicked(i)
    }

    // MARK: Looking the references up (design/pdf-reader/PLAN.md P1.3; RefLookup.swift)

    /// The shown round's cited entries and the results the engine keeps (`references`, on the checks' engine), once per
    /// round shown while Checks and a look-up are on; then the sources on look up what is not known yet (`RefLookup`).
    func requestReferences() {
        // the sources in the key: one turned on later asks again (those on already skip what they have)
        let key = checksOn && !lookUp.isEmpty ? checksRoundKey.map { $0 + "|" + lookUp.map(\.rawValue).sorted().joined(separator: ",") } : nil
        guard key != refsAsked else { return }
        refsAsked = key
        referencesLoading = false
        referenceLoadError = nil
        refEntries = [:]
        refResults = [:]
        guard let key, fixtureURL == nil, !LaunchOptions.unitTest, let path = selectedPath, let n = round?.n,
              let json = try? JSONSerialization.data(withJSONObject: ["paper": path, "round": n]) else { return }
        let sources = RefSource.allCases.filter(lookUp.contains)
        referenceRoundKey = RefLookup.roundKey(path, n)
        referencesLoading = true
        let sent = checksEngine.send("references", params: json)
        Task {
            let reply = try? makeDecoder().decode(ReferencesReply.self, from: try await checksEngine.result(sent))
            guard refsAsked == key, selectedPath == path, round?.n == n else { return }
            referencesLoading = false
            guard let reply, reply.round == n, let entries = reply.entries else {
                referenceLoadError = "Reference records could not be loaded."
                return
            }
            showReferences(entries, reply.results ?? [:])
            refs.start(paper: path, round: n, entries: entries, stored: reply.results ?? [:], sources: sources,
                       recorded: reply.attempts ?? [:])
        }
    }

    /// The shown round's entries and results (tests set them).
    func showReferences(_ entries: [RefEntry], _ results: [String: [String: RefResult]]) {
        referenceRoundKey = RefLookup.roundKey(selectedPath ?? "", round?.n ?? 0)
        refEntries = Dictionary(entries.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var by: [String: [RefSource: RefResult]] = [:]
        for (s, rs) in results { if let src = RefSource(rawValue: s) { for (k, r) in rs { by[k, default: [:]][src] = r } } }
        refResults = by
    }

    /// What a citation's preview shows of the look-ups (nil while none is on, or the entry is not known).
    func refShown(_ key: String?) -> RefShown? {
        guard let key, !lookUp.isEmpty, let e = refEntries[key] else { return nil }
        return RefShown(entry: e, results: refResults[key] ?? [:], on: RefSource.allCases.filter(lookUp.contains))
    }

    /// A citation's preview opened: Google Scholar looks its entry up next.
    func refPreviewOpened(_ key: String?) {
        guard let key, let path = selectedPath, let n = round?.n else { return }
        refs.prefer(paper: path, round: n, key: key)
    }

    /// The look-ups' hooks: results go to the engine (`ref_results`, on the checks' engine), and the shown round's
    /// checks are built again with them; the Checks tab and activity panel follow the queues.
    private func watchLookUps() {
        refs.store = { [weak self] paper, round, source, results, attempts in
            guard let self, let json = try? JSONSerialization.data(withJSONObject: [
                "paper": paper, "round": round, "source": source.rawValue,
                "results": results.mapValues(\.json), "attempts": attempts.mapValues(\.json)] as [String: Any]) else { return }
            let token = UUID(), key = RefLookup.roundKey(paper, round)
            self.referenceStores[token] = key
            let sent = self.checksEngine.send("ref_results", params: json)
            Task {
                let saved = (try? await self.checksEngine.result(sent)) != nil
                self.referenceStores[token] = nil
                if !saved { self.referenceStoreErrors.insert(key) }
                guard saved, !results.isEmpty, paper == self.selectedPath, round == self.round?.n else { return }
                self.checksAsked = nil  // built again with the results; the selection and look-ups kept
                self.requestChecks()
            }
        }
        refs.arrived = { [weak self] paper, round, key, source, result in
            guard let self, paper == self.selectedPath, round == self.round?.n else { return }
            self.refResults[key, default: [:]][source] = result  // shown at once; the checks follow the batch
            self.pdf.refreshPreview(key: key)
        }
        refWatch = refs.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async {
                guard let self, let path = self.selectedPath, let n = self.round?.n else { return }
                let line = self.refs.line(paper: path, round: n)
                if self.checks.progress != line { self.checks.progress = line }
            }
        }
    }

    /// The checks' marks on the page follow their list (`ChecksModel.version`): the PDF view is told to draw them again.
    @Published private(set) var checkMarksVersion = 0
    private func checksMarksChanged() { checkMarksVersion = checks.version }

    /// A click on a check's mark on the page: the Checks tab shows its card, as a click on a comment's mark shows the
    /// comment's (`markClicked`); nothing moves.
    func checkMarkClicked(_ id: String) {
        guard checksShown, let i = checks.index(of: id), !checks.list[i].closed else { return }  // only those marked have marks
        tab = .checks
        checks.select(i)
        pdf.setSelectedCheck(selectedCheckID, place: selectedCheckPlace)
    }

    /// The checks with marks on the page: the shown round's that go to the student (not fixed, not marked OK), their
    /// ids and the places with rects.
    var checkMarks: [Check] {
        guard checksOn, checksShown else { return [] }
        return checks.list.filter { $0.id != nil && !$0.closed }
    }

    /// The checks the student answered in the open round shown (To check): their rings beside the scroller.
    var checksToCheck: [Check] {
        guard checksOn, checksShown, roundIsOpen else { return [] }
        return checks.members(.toCheck).map { checks.list[$0] }
    }

    /// The id of the check selected on the Checks tab, outlined on the page, and the place it went to last.
    var selectedCheckID: String? {
        guard tab == .checks, checksShown, let i = checks.current, checks.list.indices.contains(i) else { return nil }
        return checks.list[i].id
    }

    var selectedCheckPlace: Int { checks.cursor.flatMap { $0.check == checks.current ? $0.place : nil } ?? 0 }

    /// Follow Up… on a check that went out before: the advisor's words go with it again (`check_note`, outside `call`;
    /// a refusal says why and puts the words back).
    func followUpCheck(_ i: Int, _ text: String) {
        guard checksShown, roundIsOpen, checks.list.indices.contains(i), let id = checks.list[i].id, let paper = selectedPath else { return }
        let words = Self.trimmed(text), before = checks.list[i].advisorNote, round = checks.key
        checks.setAdvisorNote(i, words.isEmpty ? nil : words)
        guard fixtureURL == nil, !LaunchOptions.unitTest,
              let json = try? JSONSerialization.data(withJSONObject: ["paper": paper, "id": id, "text": words]) else { return }
        let sent = engine.send("check_note", params: json)
        Task {
            do {
                _ = try await engine.result(sent)
            } catch {
                alertMessage = describe(error)
                guard checks.key == round, checks.list.indices.contains(i), checks.list[i].id == id else { return }
                checks.setAdvisorNote(i, before)
            }
        }
    }

    /// Whether Comment… can be offered, for the rows' menus (`ChecksModel.canComment`): every condition of `checkMenu`'s
    /// but the place's. Called wherever one of them changes.
    private func syncCheckComment() {
        let can = roundIsOpen && !busy && toolbar.reanchor == nil
        if checks.canComment != can { checks.canComment = can }
    }

    /// Whether the checks shown are the shown round's (a click goes only to the PDF they belong to).
    private var checksShown: Bool { checks.phase == .ready && checks.key != nil && checks.key == checksRoundKey }

    /// A click on a check's row: its first place, or after a click on it, its next (cycling), a look-up with a step of
    /// Back and a flash; a place without rects, the page's top; a check without places, nothing.
    func checkClicked(_ i: Int) {
        guard checksShown, checks.list.indices.contains(i) else { return }
        defer { pdf.setSelectedCheck(selectedCheckID, place: selectedCheckPlace) }
        guard let p = checks.step(i) else { return checks.select(i) }  // no place: the row is still the one chosen
        let place = checks.list[i].places[p]
        if place.rects.isEmpty {
            pdf.goToPage(place.page)
        } else {
            pdf.reveal(page: place.page, rects: place.rects, step: .lookUp)
        }
    }

    /// A check's right-click menu: Mark as OK, or Not OK (the shown round's checks), Comment… (in an open round, not
    /// busy, on a place with rects: its words, then the editor with the check's note), Keep Open (a place with rects)
    /// and Copy (its words and detail).
    func checkMenu(_ i: Int) -> [CheckMenuItem] {
        guard checks.list.indices.contains(i) else { return [] }
        let place = checksShown ? checks.menuPlace(i) : nil
        return [CheckMenuItem(action: .ok, title: checks.list[i].ok ? "Mark as Not OK" : "Mark as OK",
                              enabled: checksShown && !checks.list[i].fixed),  // a fixed one is closed already
                CheckMenuItem(action: .comment, title: "My Comment…",
                              enabled: place != nil && roundIsOpen && !busy && toolbar.reanchor == nil),
                CheckMenuItem(action: .keepOpen, title: "Keep Open", enabled: place != nil),
                CheckMenuItem(action: .copy, title: "Copy", enabled: true)]
    }

    /// J and K on the Checks tab: the next or the previous row, as a click on it (the first or last with none chosen).
    private func moveCheck(_ delta: Int) {
        let order = checks.order, n = order.count
        guard checksShown, n > 0 else { return }
        let at = checks.current.flatMap { order.firstIndex(of: $0) }
        let k = at.map { min(max($0 + delta, 0), n - 1) }
            ?? checks.gap.map { delta > 0 ? min($0, n - 1) : max($0 - 1, 0) }  // after a row marked OK folded away
            ?? (delta > 0 ? 0 : n - 1)
        if order[k] != checks.current { checkClicked(order[k]) }
    }

    /// Mark as OK (the paper is fine there) or Not OK: the row moves to the marked OK group (or back) at once and the
    /// tab's count follows; the engine's `check_ok` keeps it in the paper's ledger, for this round and the rounds after
    /// (outside `call`: it changes no state); a refusal puts it back and says why. A fixture run keeps it here.
    func markCheck(_ i: Int, _ ok: Bool) {
        guard checksShown, checks.list.indices.contains(i), checks.list[i].ok != ok, !checks.list[i].fixed,
              let paper = selectedPath else { return }
        let key = checks.list[i].key, round = checks.key
        checks.setOK(i, ok)
        checksMarksChanged()
        guard fixtureURL == nil, !LaunchOptions.unitTest,
              let json = try? JSONSerialization.data(withJSONObject: ["paper": paper, "key": key, "ok": ok]) else { return }
        let id = engine.send("check_ok", params: json)
        Task {
            do {
                _ = try await engine.result(id)
            } catch {
                alertMessage = describe(error)  // said even when another paper or round is shown by now
                guard checks.key == round, checks.list.indices.contains(i), checks.list[i].key == key else { return }
                checks.setOK(i, !ok)
                checksMarksChanged()
            }
        }
    }

    /// The row's check mark: a double click's second click (the next row now under the pointer) is ignored.
    func markCheckClicked(_ i: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= markGuard, checks.list.indices.contains(i) else { return }
        markGuard = now + ClickGuard.interval
        markCheck(i, !checks.list[i].ok)
    }

    func pickCheckMenu(_ i: Int, _ action: CheckMenuItem.Action) {
        guard checkMenu(i).contains(where: { $0.action == action && $0.enabled }) else { return }
        let c = checks.list[i]
        switch action {
        case .ok: markCheck(i, !c.ok)
        case .comment:
            // a note being written keeps its words selected and the PDF where it is (UX.md §8), as Comment on it… does
            guard !waitsForNote(), let p = checks.menuPlace(i) else { return }
            // the comment takes its place: the check is marked OK once the comment is made (on that page)
            if let k = checks.key { checkComment = (k, c.key, p.page) }
            pdf.commentOn(check: p, note: c.note ?? "")
        case .keepOpen: if let p = checks.menuPlace(i) { pdf.keepOpen(check: p, title: c.text) }
        case .copy:
            Self.clipboard.clearContents()
            Self.clipboard.setString(c.copied, forType: .string)
        }
    }

    /// The sidebar's Contents and the status line's reading count, once per applied state or reading change (and with
    /// them whether the round is ready to finish). A round without a PDF has neither; with reading marks off the
    /// Contents have no dots and the status line no count.
    private func buildOutline() {
        let contents = reading.contents, line: ReadingLine?
        if let r = state?.reading, let n = round?.n, round?.build.pdf != nil {
            let open = (state?.comments ?? []).filter { !Status($0).closed }.compactMap(\.paragraph)
            let rows = Outline.rows(r, read: readBlocks, comments: open, round: n, marks: readingMarksOn)
            if contents.rows != rows { contents.rows = rows }
            if contents.message != nil { contents.message = nil }
            line = readingMarksOn ? Outline.status(r, read: readBlocks, round: n, closed: round?.closed ?? false) : nil
        } else {
            if !contents.rows.isEmpty { contents.rows = [] }
            let m = round?.build.pdf == nil ? nil
                : readingFailed.map { "The paragraphs could not be found: " + $0 } ?? "Finding the paragraphs…"
            if contents.message != m { contents.message = m }
            line = nil
            reading.current.set(nil)
        }
        if contents.canMark != roundIsOpen { contents.canMark = roundIsOpen }
        syncCheckComment()
        if reading.status.line != line { reading.status.line = line }
        // the done card follows the same counts as the status line (POLISH §3 row 9)
        let ready = readyToFinish
        if panel.ready != ready { panel.ready = ready }
    }

    /// The Contents' current section follows the PDF. `hold`: N or a Contents click chose it; the scroll they start
    /// does not move it for 0.6 s.
    func outlineFollow(_ block: Int?, hold: Bool = false) {
        reading.current.set(Outline.current(reading.contents.rows, block: block))
        if hold { followHeld = Date().addingTimeInterval(0.6) }
    }

    private var pdfFollowPending = false
    private var followHeld = Date.distantPast
    func pdfScrolled() {
        guard !pdfFollowPending, Date() > followHeld else { return }
        pdfFollowPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.pdfFollowPending = false
            if Date() > self.followHeld, let r = self.state?.reading, let p = self.pdf.pointAtThird() {
                self.outlineFollow(Reading.block(page: p.page, x: p.x, y: p.y, paragraphs: r.paragraphs, headings: r.headings))
            }
        }
    }

    /// A Contents row: its heading 16 pt below the top of the PDF view (References without a place of its own: its
    /// first entry); the title and abstract: the top of the first page. A look-up, a step of Back (PLAN §5.2).
    func outlineOpen(_ block: Int, step: PDFSteps.Kind? = .lookUp) {
        guard let r = state?.reading else { return }
        if let h = r.headings.first(where: { $0.block == block }) {
            let first = r.paragraphs.filter { $0.block > block }.min { $0.block < $1.block }
            if let part = h.parts.first(where: \.valid) ?? first?.parts.first(where: \.valid) {
                pdf.place(page: part.page, rect: part.rect, fromTop: 16, step: step)
            }
        } else {
            pdf.place(page: 0, rect: [0, 0, 0, 0], fromTop: 0, step: step)
        }
        outlineFollow(block, hold: true)
    }

    /// Right-click on a Contents row: Mark Section Read / Unread.
    func markSection(_ row: OutlineRow) {
        guard readingRefusal(changing: true) == nil else { return }
        let ps = paragraphs.filter { row.range.contains($0.block) }.map(\.block)
        let read = !ps.allSatisfy(readBlocks.contains)
        setRead(ps, read)
        toast("“\(row.title)”: " + (read ? "marked read" : "marked unread"))
    }

    /// A short message over the PDF (UX.md §18 Feedback), for 2.5 s, also read by VoiceOver.
    func toast(_ text: String) {
        reading.toast = text
        toastTimer?.invalidate()
        toastTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.reading.toast = nil }
        }
        announce(text)
    }

    /// Says something to VoiceOver only.
    private func announce(_ text: String) {
        if let w = pdf.view?.window {
            NSAccessibility.post(element: w, notification: .announcementRequested,
                                 userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
    }

    /// The panel's toast (UX.md §8): an answer given, undone or redone, with the button that takes it back (Undo, Redo),
    /// for 2.5 s.
    func showPanelToast(_ text: String, action: PanelToast.Action? = nil) {
        if panelToast.action != action { panelToast.action = action }
        panelToast.text = text
        // the pointer still on the button just clicked (Undo, now Redo): it stays until the pointer leaves (UX.md §8)
        if panelToastHeld && action != nil {
            panelToastTimer?.invalidate()
        } else {
            panelToastHeld = false  // no button: nothing under the pointer holds it
            hidePanelToast(after: 2.5)
        }
        announce(text)
    }

    /// The pointer on the toast's Undo keeps it, so Undo can be reached with the mouse; it goes 1.5 s after the pointer
    /// leaves.
    func holdPanelToast(_ held: Bool) {
        guard panelToast.text != nil else { return }
        panelToastHeld = held
        if held { panelToastTimer?.invalidate() } else { hidePanelToast(after: 1.5) }
    }

    /// The pointer is on the toast's button (`holdPanelToast`); a toast without one is never held.
    private var panelToastHeld = false

    /// The toast goes at once: an answer cleared, or another paper or round shown (its Undo would act there).
    func clearPanelToast() {
        panelToastTimer?.invalidate()
        panelToastHeld = false
        if panelToast.text != nil { panelToast.text = nil }
    }

    private func hidePanelToast(after seconds: TimeInterval) {
        panelToastTimer?.invalidate()
        panelToastTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panelToastHeld = false
                self?.panelToast.text = nil
            }
        }
    }

    // MARK: Debug

    /// --debug-script busy: the engine held busy, as while it works on a request (O27), without one.
    private var heldBusy = false

    func holdBusy(_ on: Bool) {
        heldBusy = on
        busy = running > 0 || on
    }

    /// --debug-scroll-perf: once the panel is shown and the expanded card's crops had time to render.
    private func startScrollPerf(_ mode: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, let win = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { return }
            let quit = self.options.quit
            if self.tab == .checks { self.tab = .comments }  // the run times and steps a list of cards
            let onChanges = self.tab == .changes  // the list on screen, with all its rows
            if onChanges { self.changes.showLinked = true }
            // For the student listed, as before it folded (POLISH §6), and the first-run tip gone, as it is after the first
            // answer, so runs compare with earlier builds' step by step
            if !onChanges { self.panel.showStudent = true }
            self.actions.tips.dismiss(remember: false)
            let p = ScrollPerf(mode: mode, out: self.options.debugOut,
                               cards: onChanges ? self.changes.all.count : self.panel.listed.count,
                               press: { [weak self] k in self?.move(k == "j" ? 1 : -1) },
                               done: { if quit { NSApp.terminate(nil) } })
            self.perf = p
            p.sectionChanges = { [weak self] in self?.reading.current.changes ?? 0 }
            p.focus = self.focus
            // in Focus (--focus) the panel shows one card: J and K step through the same cards, one at a time
            p.run(in: win, scrollView: mode == "pdf" ? self.pdf.view?.documentView?.enclosingScrollView
                  : (onChanges ? self.changes.scroller : self.panel.scroller).scrollView)
        }
    }

    // MARK: Helpers

    func chooseFolder(prompt: String, message: String, allowZip: Bool = false) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = allowZip
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if allowZip { panel.allowedContentTypes = [.folder, .zip] }
        panel.prompt = prompt
        panel.message = message
        return panel.runModal() == .OK ? panel.url?.standardizedFileURL.path : nil
    }

    func describe(_ error: Error) -> String {
        guard let e = error as? DecodingError else { return error.localizedDescription }
        func path(_ keys: [CodingKey]) -> String {
            keys.map { $0.intValue.map { "[\($0)]" } ?? "." + $0.stringValue }.joined()
        }
        switch e {
        case .keyNotFound(let key, let ctx):
            return "The engine’s reply has no \(path(ctx.codingPath + [key]))."
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx):
            return "The engine’s reply has an unexpected value at \(path(ctx.codingPath)): \(ctx.debugDescription)"
        case .dataCorrupted(let ctx):
            return "The engine’s reply is not valid JSON: \(ctx.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }
}

// MARK: - The hierarchy (UX.md §22; OVERVIEW-v2 §3.1–3.2, FEATURES OV-7–OV-9)

extension AppModel {
    /// Shows a page of the hierarchy, or none (a paper is shown). Its scroll is kept for Back.
    func setHub(_ h: HubPage?) {
        guard h != hub else { return }
        hubModel.saveScroll(hub)
        hub = h
    }

    /// A paper's status in the hierarchy: whose move it is, from its summary and the Finished mark; none while its
    /// folder is missing (it waits on no one, and is counted nowhere).
    func status(of p: PaperRef) -> PaperStatus? {
        missingPapers.contains(p.path) ? nil : PaperStatus.of(summaries[p.path], finished: p.finished)
    }

    /// The students and their papers, as the sidebar and the pages list them.
    var studentGroups: [StudentGroup] { Hierarchy.groups(papers, status: status(of:)) }

    /// The status ring's fill of a paper (`PaperSummary.fill`): nil for an empty ring.
    func fill(of path: String) -> Double? { summaries[path]?.fill }

    /// The papers that wait on you, oldest first: one definition for the sidebar's count, All Students and Your Move.
    var yourMove: [MoveItem] { Hierarchy.yourMove(papers, status: status(of:), data: hubModel.data, summaries: summaries) }

    /// The paper Review shows, while it does: the sidebar folds its tree to it.
    var reviewPaper: String? {
        guard hub == nil, level == .review, let p = selectedPath, papers.contains(where: { $0.path == p }) else { return nil }
        return p
    }

    /// The sidebar's selection: the hierarchy's page, or the paper whose overview is shown. In Review none: the open
    /// paper's row has a fill of its own (`Sidebar`), and a click on it selects it, which shows its overview (UX.md §21;
    /// a click on the row the list already selects would not reach the list's selection).
    var sidebarSelection: SidebarItem? {
        switch hub {
        case .allStudents?: return .allStudents
        case .yourMove?: return .yourMove
        case .student(let k)?: return .student(k)
        case nil: return level == .review ? nil : selectedPath.map { .paper($0) }
        }
    }

    /// The sidebar's rows in order (debug hooks, the Contents' follower).
    var sidebarRows: [SidebarRow] {
        let c = reading.contents
        return SidebarLayout.rows(groups: studentGroups, folded: foldedStudents, review: reviewPaper,
                                  contents: c.rows.isEmpty ? (c.message == nil ? 0 : 1) : c.rows.count)
    }

    /// A click in the sidebar's list (or an arrow key). `secondClick`: the second click of a double click
    /// (`isSecondClick`), which selects nothing: it lands on the row its first click selected unless that click moved
    /// the rows (a click on the paper in Review unfolds the tree), and would then open a row never pointed at. When the
    /// selection is not taken (that click, a new comment's note being written, Unassigned), the list shows it again.
    func sidebarSelected(_ item: SidebarItem?, secondClick: Bool = false) {
        if secondClick && returnToReview() { return }
        if !secondClick {
            // the paper open in Review: its overview now, and Review again if this was a double click's first click
            if case .paper(let p)? = item, p == selectedPath, hub == nil, level == .review {
                reviewRowClick = (p, ProcessInfo.processInfo.systemUptime)
            } else {
                reviewRowClick = nil
            }
            switch item {
            case .allStudents?: openHub(.allStudents)
            case .yourMove?: openHub(.yourMove)
            case .student(let k)?: if !k.isEmpty { openHub(.student(k)) }
            case .paper(let p)?: openPaper(p)
            case nil: break
            }
        }
        if sidebarSelection != item { DispatchQueue.main.async { self.objectWillChange.send() } }
    }

    /// The sidebar list's primary action: a double click (its first click has selected the row and shown it) or Return.
    /// On a paper, Review (UX.md §21); the other rows' click has done it all. Only the paper the list selects, so a
    /// double click whose first click moved the rows under the pointer opens no other paper.
    func sidebarOpened(_ items: Set<SidebarItem>) {
        if returnToReview() { return }
        guard items.count == 1, case .paper(let p)? = items.first, p == selectedPath, hub == nil else { return }
        openPaper(p, level: .review)
    }

    /// A double click on the row of the paper open in Review (the 2026-10-20 leftover: it ended in the overview, its
    /// first click having shown it and folded the tree open under the pointer): its second click, wherever it lands,
    /// brings Review back as it was, and the overview its first click showed leaves no place in the history.
    @discardableResult
    private func returnToReview() -> Bool {
        guard let c = reviewRowClick else { return false }
        reviewRowClick = nil
        guard ProcessInfo.processInfo.systemUptime - c.time <= NSEvent.doubleClickInterval, c.path == selectedPath, hub == nil,
              level == .overview, !waitsForNote() else { return false }
        navHistory.dropLast { $0.paper == c.path && $0.level == .review && $0.hub == nil }
        setLevel(.review)
        DispatchQueue.main.async { self.objectWillChange.send() }  // the list shows the open paper's row as Review's again
        return true
    }

    /// The second (or later) click of a multiple click, as the list's selection hears of it: during that click.
    nonisolated static func isSecondClick(_ event: NSEvent?) -> Bool {
        guard let e = event, e.type == .leftMouseDown || e.type == .leftMouseUp else { return false }
        return e.clickCount > 1
    }

    /// The paper's status in words, for its help tag and the hierarchy's lines.
    func statusText(_ p: PaperRef) -> String {
        if let gone = missingWords(p) { return gone }
        guard let s = status(of: p) else { return "" }
        let d = hubModel.data[p.path]
        return HubText.status(s, round: d?.latest?.n ?? summaries[p.path]?.round, student: p.student,
                              since: d?.latest?.closedAt)
    }

    /// The other form of a waiting paper's day counter ("With Priya · 6 d"), for its line's help tag: "Round 1 sent
    /// back Sat, Oct 3".
    func statusHelp(_ p: PaperRef) -> String? {
        guard missingWords(p) == nil, status(of: p) == .waiting, let l = hubModel.data[p.path]?.latest,
              let back = Hierarchy.date(l.closedAt) else { return nil }
        return HubText.hoverSentBack(back, round: l.n)
    }

    /// The hierarchy's line for a paper whose folder is not there, as its sidebar row says it: "Its folder is missing"
    /// (`broken`: the red sign), or "Its folder is on “Lab SSD”, not connected"; nil while it is there.
    func missingWords(_ p: PaperRef) -> String? {
        guard missingPapers.contains(p.path) else { return nil }
        return DataPlaces.unplugged(p.path).map { "Its folder is on “\($0)”, not connected" } ?? "Its folder is missing"
    }

    func folderBroken(_ p: PaperRef) -> Bool { missingPapers.contains(p.path) && DataPlaces.unplugged(p.path) == nil }

    /// The chevron of a student in the sidebar, remembered (never by a test run).
    func toggleStudentFold(_ key: String) {
        if foldedStudents.contains(key) { foldedStudents.remove(key) } else { foldedStudents.insert(key) }
        if fixtureURL == nil { Prefs.set(foldedStudents.sorted(), Self.foldedStudentsKey) }
    }

    /// A paper's name and student as its ledger has them (`summaries`, `overview`, `edit_paper`): the list follows,
    /// and is saved when the paper is the advisor's own (not a --paper one).
    func adoptNames(_ path: String, title: String?, student: String?) {
        guard let i = papers.firstIndex(where: { $0.path == path }) else { return }
        var p = papers[i]
        if let t = title, !t.isEmpty { p.title = t }
        if let s = student { p.student = s }
        guard p != papers[i] else { return }
        papers[i] = p
        if !transientPaths.contains(path) { persist() }
    }

    /// Mark as Finished (FEATURES OV-7): today's date, in the paper's ledger (`edit_paper`; the list keeps a copy).
    func setFinished(_ path: String, _ on: Bool, today: Date = Date()) {
        guard let i = papers.firstIndex(where: { $0.path == path }) else { return }
        let day = on ? HubText.format(today, "yyyy-MM-dd") : nil
        papers[i].finished = day
        persist()
        writeFact(path, "finished", day)
        if hub != nil { loadHub() }
    }

    /// Map Headings… (FEATURES OV-9): the advisor's answers for a paper's sections, in the paper's ledger (the list
    /// keeps a copy, also sent to the engine's `overview` as `buckets`). `reload` false: the caller asks the hierarchy
    /// once after all its papers (Map Headings…' Done; the review, A4b-08: once per paper before).
    func setBuckets(_ path: String, _ answers: [String: String], reload: Bool = true) {
        guard let i = papers.firstIndex(where: { $0.path == path }) else { return }
        papers[i].buckets = answers
        persist()
        writeFact(path, "buckets", answers.mapValues { $0.isEmpty ? NSNull() : $0 as Any })
        if reload && hub != nil { loadHub() }
    }

    /// One of the three facts written to the paper's ledger (`edit_paper`; DATA.md §2.2), nil clearing it. A fixture
    /// run keeps the list's copy only.
    private func writeFact(_ path: String, _ key: String, _ value: Any?) {
        guard fixtureURL == nil else { return }
        call("edit_paper", ["paper": path, key: value ?? NSNull()])
    }

    /// Moves the list's three facts into each listed paper's ledger, once per paper (the engine's `adopt_facts`, which
    /// never overwrites what the ledger has), and marks the entry so (saved, never by a test run). A paper whose folder
    /// is not there is asked again at the next launch. The reply's facts, the ledger's, become the list's copies. A
    /// --background run leaves the papers of the list it read alone (`listRead`): their folders are the advisor's.
    func moveFactsIn() {
        guard fixtureURL == nil else { return }
        for p in papers where p.factsMoved != true && !listRead.contains(p.path) {
            var params: [String: Any] = ["paper": p.path]
            if let f = p.finished { params["finished"] = f }
            if let b = p.buckets { params["buckets"] = b.mapValues { $0.isEmpty ? NSNull() : $0 as Any } }
            if let k = p.keyPage { params["key_page"] = ["round": k.round, "page": k.page] }
            guard let json = try? JSONSerialization.data(withJSONObject: params) else { continue }
            let id = engine.send("adopt_facts", params: json)
            Task {
                guard let data = try? await engine.result(id),
                      let reply = try? makeDecoder().decode(FactsReply.self, from: data) else { return }
                guard let i = papers.firstIndex(where: { $0.path == p.path }) else { return }
                papers[i].factsMoved = true
                adoptFacts(p.path, id: reply.paper.id, finished: .some(reply.paper.finished), buckets: .some(reply.paper.buckets),
                           keyPage: .some(reply.paper.keyPage), save: false)
                persist()
            }
        }
    }

    /// A paper's pending closed rounds, to the second engine process (FEATURES E1b), which writes their prose.json and
    /// analysis cache: never a --background run's papers of the list it read (`listRead`), whose folders are the
    /// advisor's (the 2026-10-24 fix review: a test run's All Students filled in Dev's listed papers).
    func fillIn(_ path: String, _ o: PaperOverview) {
        guard !listRead.contains(path) else { return }
        backfill.want(path, o)
    }

    /// A listed folder with the id of another listed one: a new id (the engine's `fork`, the old one kept in
    /// `forked_from`), said on the window's line. Never a --background run's folders of the list it read.
    private func forkCopy(_ path: String) {
        guard fixtureURL == nil, !listRead.contains(path), !forking.contains(path),
              let p = papers.first(where: { $0.path == path }) else { return }
        forking.insert(path)
        call("fork", ["paper": path], quiet: true, then: { reply in
            self.forking.remove(path)
            guard let i = self.papers.firstIndex(where: { $0.path == path }) else { return }
            self.papers[i].ledgerID = reply.state.paper.id
            if !self.transientPaths.contains(path) { self.persist() }
            self.showNotice(WindowNotice(text: "“\(TransferText.short(p.title))” was a copy of another listed folder. It now has an id of its own, so imports and backups tell them apart."))
        }, failed: { _ in self.forking.remove(path) })
    }

    /// The ledger's facts (`adopt_facts`, `summaries`, `overview`) as the list's copies, for a paper whose facts were
    /// moved in; each given (a double optional: .some(nil) clears it), saved when changed.
    func adoptFacts(_ path: String, id: String? = nil, finished: String?? = nil, buckets: [String: String?]?? = nil,
                    keyPage: KeyPageChoice?? = nil, save: Bool = true) {
        guard let i = papers.firstIndex(where: { $0.path == path }), papers[i].factsMoved == true else { return }
        var p = papers[i]
        if let id { p.ledgerID = id }
        // ids stay unique in the list (DATA.md §2.3): of two folders with one id (a copy made in Finder), the later
        // entry gets one of its own, so Import and Restore tell the two apart
        if let id, let j = papers.firstIndex(where: { $0.path != path && $0.ledgerID == id }) {
            forkCopy(papers[max(i, j)].path)
        }
        if let f = finished { p.finished = f }
        if let b = buckets { p.buckets = b.map { $0.mapValues { $0 ?? "" } } }
        if let k = keyPage { p.keyPage = k }
        guard p != papers[i] else { return }
        papers[i] = p
        if save && !transientPaths.contains(path) { persist() }
    }

    /// Edit Paper… (`edit_paper`): its title and student, each only when given. The sidebar regroups when the engine
    /// has it. `reload` false: the caller asks the hierarchy once after all its papers (Rename Student…).
    func editPaper(_ path: String, title: String?, student: String?, reload: Bool = true) {
        var params: [String: Any] = ["paper": path]
        if let title { params["title"] = title }
        if let student { params["student"] = student }
        guard params.count > 1 else { return }
        call("edit_paper", params, then: { reply in
            self.adoptNames(path, title: reply.state.paper.title, student: reply.state.paper.student)
            if reload && self.hub != nil { self.loadHub(force: true) }
        })
    }

    /// Rename Student…: every paper of the student gets the new name (also the way to put one student's papers
    /// written two ways under one name). The page and the fold follow the new name.
    func renameStudent(_ key: String, to name: String) {
        let new = StudentName.shown(name)
        guard !new.isEmpty, let g = studentGroups.first(where: { $0.key == key }) else { return }
        let newKey = StudentName.key(new)
        if foldedStudents.contains(key) && newKey != key {
            foldedStudents.remove(key)
            foldedStudents.insert(newKey)
        }
        if hub == .student(key) { setHub(.student(newKey)) }
        let renamed = g.papers.filter { $0.student != new }
        for p in renamed { editPaper(p.path, title: nil, student: new, reload: false) }
        // the hierarchy asked once, after the edits (one engine, in order), not once per paper (A4b-08)
        if !renamed.isEmpty && hub != nil { loadHub(force: true) }
    }

    /// Asks the engine for the overview of every listed paper (with marks), with the advisor's Map Headings answers, when
    /// it has none for them or something may have changed since (`HubModel.key`). Through the review's engine process,
    /// after whatever it is doing; the page shows what it has meanwhile. A --overview-fixture is read instead.
    func loadHub(force: Bool = false) {
        let params = Self.hubRequest(papers, order: tags.catalog.order)
        let key = hubKey
        guard force || hubModel.key != key else { return }
        let seq = hubModel.begin(key: key)
        if let file = options.overviewFixture {
            let result = Result { try PaperOverview.decodeReply(Data(contentsOf: URL(fileURLWithPath: file))) }
            if case .success(let r) = result { adoptHub(r) }
            return hubModel.finish(seq, result)
        }
        guard fixtureURL == nil, !papers.isEmpty, let json = try? JSONSerialization.data(withJSONObject: params) else {
            return hubModel.finish(seq, .success(OverviewReply(papers: [], students: [])))
        }
        let id = engine.send("overview", params: json)
        let edits = ledgerEdits
        Task {
            do {
                let reply = try PaperOverview.decodeReply(try await engine.result(id))
                adoptHub(reply, facts: edits == ledgerEdits)
                thumbnails.refresh()  // a round may have been built again
                hubModel.finish(seq, .success(reply))
                for e in reply.papers { if let o = e.overview { fillIn(e.path, o) } }
            } catch {
                hubModel.finish(seq, .failure(error))
            }
        }
    }

    /// What the hierarchy's data must have been asked with to say what the engine would now (`HubModel.key`).
    var hubKey: String {
        let answers = papers.compactMap { p in p.buckets.map { p.path + ":" + $0.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",") } }
        let keys = papers.compactMap { p in p.keyPage.map { "\(p.path)@\($0.round):\($0.page)" } }
        let order: String = tags.catalog.order.joined(separator: ",")
        let listed: String = papers.map(\.path).joined(separator: "\n")
        return ["\(ledgerEdits)", "\(roundsFound)", "\(activations)", listed, answers.joined(separator: ";"),
                keys.joined(separator: ";"), order].joined(separator: "|")
    }

    /// The hierarchy's data is the engine's answer to the papers as they are now: loaded, no request on its way, and
    /// asked after the last edit (the code audit: Delete, Merge and Tag Comments… decided from overviews gone stale).
    var hubCurrent: Bool { hubModel.status == .loaded && !hubModel.pending && hubModel.key == hubKey }

    /// Runs `f` with the hierarchy's data current: at once, or after asking the engine again (a beep if that fails).
    func withCurrentHub(_ f: @escaping () -> Void) {
        if hubCurrent { return f() }
        hubModel.afterLoad { [weak self] ok in
            guard let self else { return }
            if ok && self.hubCurrent { f() } else { NSSound.beep() }
        }
        loadHub(force: true)
    }

    /// The hierarchy's request (CONTRACT amendment "Overview"): every listed paper, with marks (UI v4: the thumbnails'
    /// highlights), and the advisor's Map Headings answers as `buckets` ("" sent as null: the heading's own column).
    nonisolated static func hubRequest(_ papers: [PaperRef], order: [String]? = nil) -> [String: Any] {
        var buckets: [String: [String: Any]] = [:]
        for p in papers { if let b = p.buckets { buckets[p.path] = b.mapValues { $0.isEmpty ? NSNull() : $0 as Any } } }
        var out: [String: Any] = ["papers": papers.map(\.path), "marks": true, "buckets": buckets]
        let keys = keyPages(papers)
        if !keys.isEmpty { out["key_pages"] = keys }
        if let order { out["tag_order"] = order }  // the writing profile's picks: the advisor's visible tags, in order
        return out
    }

    /// The advisor's key pages (Set as Key Page; TAGS.md §7) as the engine's `overview` takes them.
    nonisolated static func keyPages(_ papers: [PaperRef]) -> [String: [String: Int]] {
        var out: [String: [String: Int]] = [:]
        for p in papers { if let k = p.keyPage { out[p.path] = ["round": k.round, "page": k.page] } }
        return out
    }

    /// Each paper's name, student and next step as the overview has them: the sidebar and the counts follow at once.
    /// `facts`: no edit was sent since it was asked, so its facts are not older than the list's (a Finished mark, Map
    /// Headings or a key page set meanwhile would go back to what they were).
    private func adoptHub(_ reply: OverviewReply, facts: Bool = true) {
        for e in reply.papers {
            guard let o = e.overview else { continue }
            TagCatalog.learn(o.tagNames)
            adoptNames(e.path, title: o.paper?.title, student: o.paper?.student)
            if facts, let p = o.paper, p.id != nil {
                adoptFacts(e.path, id: p.id, finished: .some(p.finished), buckets: .some(p.buckets), keyPage: .some(p.keyPage))
            }
            if e.path != selectedPath, let s = o.summary, summaries[e.path] != s { summaries[e.path] = s }
        }
    }
}

// MARK: - Writing tags, Reopen and the key page (design/tags/TAGS.md; UX.md §24)

extension AppModel {
    /// The catalogue changed (a tag added, renamed, hidden, moved) or the suggestions were switched: the cards take the
    /// new names and signs, and the overviews are asked again with the new order (the writing profile's picks).
    func tagsChanged() {
        if let state { buildCards(state) }
        if hub != nil { loadHub() }
        if level == .overview { loadOverview(force: true) }
    }

    /// The card's picker opens (its + or a tag clicked), with the comment's tags and, while it has none, the
    /// suggestions. One picker at a time: another one open is closed (and written) first.
    func openTagPicker(_ id: String) {
        guard let c = comment(id) else { return }
        if let open = edit.tagging, open != id { closeTagPicker(open) }
        if edit.tagging == id { return }
        let suggestions = tags.suggest && c.tagIDs.isEmpty
            ? TagSuggester.suggest(for: c, catalog: tags.catalog)
            : []
        edit.tagSelection = TagSelection(on: c.tagIDs, suggestions: suggestions)
        edit.tagging = id
    }

    /// The card's picker closes (a click outside, Esc): its tags are written in one request when they changed (the
    /// critique's fix). A name typed in New Tag… and not added with Return is dropped.
    func closeTagPicker(_ id: String) {
        guard edit.tagging == id, let sel = edit.tagSelection else { return }
        edit.tagging = nil
        edit.tagSelection = nil
        if sel.changed { setTags(id, sel.on, accepted: sel.accepted) }
    }

    /// A card's dashed suggestion clicked: that tag, taken from a suggestion.
    func acceptSuggestion(_ id: String, _ tag: String) {
        guard let c = comment(id), !c.tagIDs.contains(tag) else { return }
        setTags(id, c.tagIDs + [tag], accepted: [tag])
    }

    /// ⋯ › Tags ›: one tag on or off.
    func toggleTag(_ id: String, _ tag: String) {
        guard let c = comment(id) else { return }
        setTags(id, c.tagIDs.contains(tag) ? c.tagIDs.filter { $0 != tag } : c.tagIDs + [tag])
    }

    /// A comment's whole list of tags (TAGS.md §3.2), written through the engine's `tag`, on a comment of any round
    /// (tags change nothing the student receives). The card shows them at once; the engine's state, of the round shown,
    /// follows. A fixture run only shows them.
    func setTags(_ id: String, _ ids: [String], accepted: [String] = []) {
        guard let paper = selectedPath, let i = state?.comments.firstIndex(where: { $0.id == id }) else { return }
        let list = Array(ids.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.prefix(TagCatalog.maxPerComment))
        guard list != state?.comments[i].tagIDs else { return }
        state?.comments[i].tags = list
        if let st = state { buildCards(st) }
        guard fixtureURL == nil else { return }
        var params: [String: Any] = ["paper": paper, "id": id, "tags": list, "accepted": accepted.filter(list.contains)]
        let names = tags.catalog.names(for: list)
        if !names.isEmpty { params["names"] = names }
        if viewingEarlierRound, let n = round?.n { params["round"] = n }
        call("tag", params)
    }

    /// A comment of another paper (Tag Comments… from a student's page, Merge…): its tags written without a state.
    func setTags(paper: String, id: String, _ ids: [String], accepted: [String] = [], done: ((Bool) -> Void)? = nil) {
        if paper == selectedPath, comment(id) != nil {  // a card shown: at once, with the round's state
            setTags(id, ids, accepted: accepted)
            done?(true)
            return
        }
        guard fixtureURL == nil else { done?(false); return }
        var params: [String: Any] = ["paper": paper, "id": id, "tags": ids, "accepted": accepted.filter(ids.contains), "state": false]
        let names = tags.catalog.names(for: ids)
        if !names.isEmpty { params["names"] = names }
        guard let json = try? JSONSerialization.data(withJSONObject: params) else { done?(false); return }
        ledgerEdits += 1
        let rid = engine.send("tag", params: json)
        Task {
            do {
                _ = try await engine.result(rid)
                done?(true)
            } catch {
                alertMessage = describe(error)
                done?(false)
            }
        }
    }

    // MARK: Reopen (TAGS.md §9; the engine's `revive`)

    /// Reopen in Round N: the comment closed in an earlier round comes back into the open round as To check. Review
    /// then shows the open round with its card selected and the cursor in its follow-up field, to say what broke.
    func revive(_ id: String) {
        guard let paper = selectedPath, fixtureURL == nil, let n = latestRound?.n, !waitsForNote(), !refusedWhileBusy() else { return }
        commitEdit(focusLost: true)
        leaveReanchor()
        dropChoice()
        clearPanelToast()
        pdf.clearSelection()
        pdf.dropPendingBox()
        changes.expanded = nil
        if case .change? = selection { selection = nil; pdf.setSelectedChange(nil) }
        pendingSelect = id
        let entered = level != .review  // Review opened: a window step already, so the card's reveal records none
        if entered { openReview(ReviewTarget(round: n)) }
        call("revive", ["paper": paper, "id": id], then: { _ in
            // the advisor may have moved to another paper meanwhile, whose comment of the same id is not this one
            guard self.selectedPath == paper, !self.viewingEarlierRound else { return }
            if self.tab != .comments { self.tab = .comments }
            if self.comment(id) != nil {
                self.select(.comment(id), scroll: .centre, step: entered ? nil : .run)
                self.requestFieldFocus(id)
            }
            self.showPanelToast("\(id) is back in Round \(n), to check · say what broke in its field")
        })
    }

    /// ⋯ › Undo Reopen, while the round is open: the comment goes back to being closed in its round. A follow-up written
    /// for it since goes too, so that is asked first.
    func undoRevive(_ id: String, confirmed: Bool = false) {
        guard let paper = selectedPath, let c = comment(id), c.revived != nil, roundIsOpen, !refusedWhileBusy() else { return }
        let words = !(c.verdictNote ?? "").isEmpty || !draftText(id).isEmpty
        if words && !confirmed {
            let a = NSAlert()
            a.messageText = "Undo Reopen discards your follow-up?"
            a.informativeText = "\(id) goes back to being closed in Round \(c.revived?.from ?? 0), and what you wrote for it in this round goes."
            a.addButton(withTitle: "Undo Reopen")
            a.addButton(withTitle: "Cancel")
            if let w = pdf.view?.window {
                a.beginSheetModal(for: w) { r in
                    MainActor.assumeIsolated { if r == .alertFirstButtonReturn { self.undoRevive(id, confirmed: true) } }
                }
            }
            return
        }
        setDraft(id, "")
        call("revive", ["paper": paper, "id": id, "undo": true], then: { _ in
            // its answers of this round went with its record: ⌘Z must not try them again (the code audit: it stuck)
            self.histories[paper]?.history.forget(id)  // kept while another paper or round is shown
            guard self.selectedPath == paper else { return }
            self.history.forget(id)
            self.showPanelToast("\(id) is closed again, as in Round \(c.revived?.from ?? 0)")
        })
    }

    // MARK: The key page (TAGS.md §7)

    /// Set as Key Page (or Use the Busiest Page with nil): in the paper's ledger (the list keeps a copy, also sent to
    /// the engine's `overview`, which follows it into later rounds).
    func setKeyPage(_ path: String, _ k: KeyPageChoice?) {
        guard let i = papers.firstIndex(where: { $0.path == path }), papers[i].keyPage != k else { return }
        papers[i].keyPage = k
        if !transientPaths.contains(path) { persist() }
        writeFact(path, "key_page", k.map { ["round": $0.round, "page": $0.page] })
        if path == selectedPath { loadOverview(force: true) }
        if hub != nil { loadHub(force: true) }
    }

    func keyPage(of path: String) -> KeyPageChoice? { papers.first { $0.path == path }?.keyPage }
}

// MARK: - Tag Comments… and Merge (UX.md §24)

extension AppModel {
    /// Tag Comments… for the paper shown (its overview's comments, every round), or for a student's papers (the
    /// hierarchy's), the comments not tagged yet first.
    /// The rows come from overviews asked after the last edit (the code audit: a stale list, written back whole,
    /// overwrote tags put on since): the engine is asked again first when they may be older.
    func openTagComments(student key: String? = nil) {
        if let key {
            guard let g = studentGroups.first(where: { $0.key == key }) else { return NSSound.beep() }
            return withCurrentHub { [weak self] in
                guard let self else { return }
                self.showTagComments(g.name, g.papers.compactMap { p in self.hubModel.data[p.path].map { (p.path, p.title, $0) } })
            }
        }
        guard let path = selectedPath else { return NSSound.beep() }
        let open = { [weak self] in
            guard let self, self.selectedPath == path, let d = self.overview.data else { return NSSound.beep() }
            let title = self.state?.paper.title ?? self.papers.first { $0.path == path }?.title ?? ""
            self.showTagComments(title, [(path, title, d)])
        }
        if overview.paper == path && overview.version == ledgerEdits && overview.status == .loaded { return open() }
        overview.afterLoad { ok in ok ? open() : NSSound.beep() }
        loadOverview(force: true)
    }

    private func showTagComments(_ title: String, _ papers: [(path: String, title: String, data: PaperOverview)]) {
        guard !papers.isEmpty, tagComments == nil else { return NSSound.beep() }
        let m = TagCommentsModel(title: title, papers: papers)
        m.model = self
        tagComments = m
    }

    /// The sheet closed: the overviews are asked again with the new tags (the requests were counted as edits).
    func closeTagComments() {
        guard tagComments != nil else { return }  // Done, then the sheet's own dismissal: once
        tagComments?.commit()
        tagComments = nil
        if level == .overview && hub == nil { loadOverview(force: true) }
        if hub != nil { loadHub(force: true) }
        refreshShownState()  // the cards of the round shown take the tags written from the sheet
    }

    /// The round shown asked for again (tags written to its paper without a state).
    func refreshShownState() {
        guard let path = selectedPath, fixtureURL == nil, state != nil else { return }
        var p: [String: Any] = ["paper": path]
        if viewingEarlierRound, let n = round?.n { p["round"] = n }
        call("state", p)
    }

    /// Merge Into… (Settings › Tags): in every listed paper, each comment with `from` gets `into` instead, through
    /// the engine's `retag`, which reads each comment's tags from its ledger as they are now (the code audit: whole
    /// lists sent from the hierarchy's overviews overwrote tags put on since, and missed papers whose overview had
    /// failed). Only when every paper took it does `from` leave the catalogue (a built-in tag is hidden); else it stays
    /// and the papers that refused are named. Papers not in the list keep `from` (their ledgers keep its name).
    func mergeTags(from: String, into: String) {
        guard from != into, tags.catalog.tag(into) != nil, fixtureURL == nil, !papers.isEmpty else { return }
        let names = tags.catalog.names(for: [from, into])
        let sent: [(path: String, title: String, id: Int)] = papers.compactMap { p in
            var params: [String: Any] = ["paper": p.path, "from": from, "into": into, "state": false]
            if !names.isEmpty { params["names"] = names }
            guard let json = try? JSONSerialization.data(withJSONObject: params) else { return nil }
            return (p.path, p.title, engine.send("retag", params: json))
        }
        ledgerEdits += 1
        let fromName = tags.catalog.name(from), intoName = tags.catalog.name(into)
        Task {
            var failed: [String] = []
            for s in sent {
                do { _ = try await engine.result(s.id) } catch { failed.append(s.title.isEmpty ? s.path : s.title) }
            }
            if sent.count < papers.count { failed.append("a paper whose request could not be made") }
            if failed.isEmpty {
                tags.update { c in
                    if c.tag(from)?.builtIn == true { c.setHidden(from, true) } else { _ = c.delete(from, used: 0) }
                }
            } else {
                alertMessage = "\(fromName) stays in your tags: " + (failed.count == 1 ? "this paper" : "these papers")
                    + " could not be changed: " + failed.joined(separator: ", ") + ". The others’ comments now have \(intoName)."
            }
            loadHub(force: true)
            if level == .overview { loadOverview(force: true) }
            refreshShownState()
        }
    }
}

// MARK: - Import, Put Back an Earlier Ledger (design/data/DATA.md §5, §6.4)

extension AppModel {
    /// Before Use This Copy replaces the paper shown: the paper closed (All Students shown), an open editor saved to it
    /// first as when another paper is chosen (its request goes to the engine before Import's). False while a new
    /// comment's note is being written.
    func closeForImport() -> Bool {
        if waitsForNote() { return false }
        selectPaper(nil)
        setHub(.allStudents)
        loadHub()
        return true
    }

    /// Import put another copy of the paper in its folder (Use This Copy): its state and numbers are read again, and the
    /// list's facts go into its ledger where it lacks them (`adopt_facts` never overwrites).
    func paperReplaced(_ path: String) {
        if let i = papers.firstIndex(where: { $0.path == path }) { papers[i].factsMoved = nil }
        ledgerEdits += 1
        thumbnails.clear(paper: path)
        moveFactsIn()
        refreshSummaries()
        if hub != nil { loadHub(force: true) }
        if damagedPapers[path] != nil { backups.checkFolders([path]) }
    }

    /// Put Back an Earlier Ledger… (a paper's context menu): the sheet, with the engine's `history` of its ledger.
    func openLedgerHistory(_ path: String) {
        guard let p = papers.first(where: { $0.path == path }), fixtureURL == nil else { return NSSound.beep() }
        ledgerHistory = LedgerHistory(paper: path, title: p.title)
        guard let json = try? JSONSerialization.data(withJSONObject: ["paper": path]) else { return }
        let id = engine.send("history", params: json)
        Task {
            do {
                let r = try makeDecoder().decode(LedgerHistory.Reply.self, from: try await engine.result(id))
                guard ledgerHistory?.paper == path else { return }
                ledgerHistory?.versions = r.versions  // none chosen: the newest is much as the ledger is now
            } catch {
                ledgerHistory?.error = describe(error)
            }
        }
    }

    /// Its Put Back: the version chosen becomes the ledger's newest (the engine's `put_back_ledger`, which keeps the one
    /// it replaces); the engine's refusal stays in the sheet.
    func putBackLedger() {
        guard let h = ledgerHistory, let name = h.selected, !h.working else { return }
        if h.paper == selectedPath { commitEdit(focusLost: true) }
        ledgerHistory?.working = true
        ledgerHistory?.error = nil
        let when = h.versions?.first { $0.name == name }.flatMap { TransferText.when($0.time) } ?? name
        call("put_back_ledger", ["paper": h.paper, "version": name], quiet: true, then: { _ in
            self.ledgerHistory = nil
            self.refreshSummaries()
            if self.damagedPapers[h.paper] != nil { self.backups.checkFolders([h.paper]) }
            if self.hub != nil { self.loadHub(force: true) }
            self.showNotice(WindowNotice(text: "Put back the ledger of “\(TransferText.short(h.title))” as it was on \(when). The one it replaced is kept in its history."))
        }, failed: { message in
            self.ledgerHistory?.working = false
            self.ledgerHistory?.error = message
        })
    }
}
