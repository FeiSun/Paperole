import AppKit
import SwiftUI

/// The text of an open note editor. It lives outside the editor's view, so a note is kept until it is saved or
/// discarded on purpose: a click elsewhere or an engine error does not lose it.
@MainActor
final class CommentDraft: ObservableObject, Identifiable {
    /// What the comment is on: selected text, a drawn box, or a point; `replace`: selected text struck out, the note
    /// the words that replace it (the PDF's menu, Replace With…).
    /// `overall`: on the whole paper (design/comments/PLAN.md §3 S), from + Overall comment: no words, kind or page.
    enum Mode { case text, box, point, replace, overall }

    @Published var kind: MarkKind
    @Published var color: MarkColor
    @Published var note: String
    @Published var saving = false
    @Published var confirmDiscard = false
    let mode: Mode
    let original: String
    /// The page it is on (0-based), so what waits for it can say where (UX.md §8).
    let page: Int?
    /// The words selected in the PDF, which the editor shows on top (POLISH §3 row 4); "" for a box or a point.
    let quote: String
    /// The writing tags picked under the note (TAGS.md §2.1), saved with it.
    let tags = TagSelection(on: [])

    init(kind: MarkKind, color: MarkColor, note: String, mode: Mode, page: Int? = nil, quote: String = "") {
        self.kind = kind
        self.color = color
        self.note = note
        self.mode = mode
        self.page = page
        self.quote = quote
        original = note
    }

    /// A note typed or a tag picked: a click elsewhere then keeps the popover (and asks before Cancel drops it).
    var changed: Bool { note != original || !tags.on.isEmpty }
}

/// The new-comment editor, in a popover over the PDF. Its style row (colour, and the kind for text) starts from the
/// last style used and has the last word. Under it the words selected in the PDF, in the paper's serif beside a rule in
/// the comment's colour (POLISH §3 row 4), so the note is written next to what it is about. Save keeps it open until
/// the engine has saved the comment; Cancel or Esc asks again before dropping a changed note.
struct CommentEditor: View {
    let title: String
    @ObservedObject var draft: CommentDraft
    @ObservedObject var tags: TagModel
    @ObservedObject var picking: TagSelection
    let onSave: () -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    init(title: String, draft: CommentDraft, tags: TagModel, onSave: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.title = title
        self.draft = draft
        self.tags = tags
        picking = draft.tags
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                (Text(title).font(.system(size: 13, weight: .semibold))
                    + Text(draft.page.map { " · p.\($0 + 1)" } ?? "").font(.system(size: 13)).foregroundColor(Ink.secondary))
                    .lineLimit(1)
                Spacer(minLength: 8)
                ForEach(MarkColor.allCases) { c in
                    Swatch(color: c, selected: draft.color == c) { draft.color = c }
                }
                if draft.mode == .text {
                    Divider().frame(height: 16)
                    ForEach(MarkKind.textKinds) { k in
                        Button { draft.kind = k } label: {
                            Image(systemName: k.symbol).frame(width: 20, height: 20)
                                .foregroundStyle(draft.kind == k ? Ink.accentText : Color.primary)
                                .background(RoundedRectangle(cornerRadius: 4)
                                    .fill(draft.kind == k ? Color.accentColor.opacity(0.15) : .clear))
                        }
                        .buttonStyle(.plain)
                        .help(k.name)
                        .accessibilityLabel(k.name)
                        .accessibilityAddTraits(draft.kind == k ? .isSelected : [])
                    }
                }
            }
            if !draft.quote.isEmpty {
                Text(draft.quote.split(whereSeparator: \.isWhitespace).joined(separator: " "))
                    .font(.system(size: 12.5, design: .serif))
                    .lineSpacing(3)
                    .foregroundStyle(Ink.label2)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 9)
                    .overlay(alignment: .leading) { Rectangle().fill(Color(nsColor: draft.color.fill)).frame(width: 2) }
                    .accessibilityLabel("Selected text: " + draft.quote)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $draft.note)
                    .font(.body)
                    .focused($focused)
                if draft.note.isEmpty {
                    Text(draft.mode == .replace ? "The new words" : "Your note (it may be empty)").font(.body).foregroundStyle(Ink.tertiary)
                        .padding(.leading, 5).allowsHitTesting(false)
                }
            }
            .frame(height: 96)
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.2)))
            // the writing tags (TAGS.md §2.1): one click each, several or none; New Tag… where it is, Cancel and Save
            TagPicker(tags: tags, selection: picking, width: TagPickerSize.chips) {
                if draft.confirmDiscard {
                    Text("Discard this note?").font(.system(size: 11, weight: .semibold)).foregroundStyle(.primary)  // red is for errors
                }
                Button(draft.confirmDiscard ? "Discard" : "Cancel", action: cancel)
                    // Esc in the New Tag… field closes the field, not the popover
                    .keyboardShortcut(picking.naming ? nil : .cancelAction)
                    .help(draft.confirmDiscard ? "Discard this note (Esc)" : "Close without saving (Esc)")
                Button(draft.saving ? "Saving…" : "Save", action: onSave)
                    .keyboardShortcut(.return, modifiers: .command)
                    // a comment on the whole paper is only its words
                    .disabled(draft.mode == .overall && draft.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .buttonStyle(.borderedProminent)
                    .help("Save the comment and its tags (⌘↩)")
            }
            .disabled(draft.saving)
        }
        .padding(14)
        .frame(width: TagPickerSize.popover)
        // an opaque float, as Jump and the selection toolbar (POLISH §2.4): the ink tokens are tuned for it, not for
        // the popover's vibrant material, on which the footer and the suggestions fell to 2.5:1 (the UI audit)
        .background(Color(nsColor: Palette.float))
        .onAppear { focused = true }
        .onChange(of: draft.note) { draft.confirmDiscard = false }
        .onChange(of: picking.on) { draft.confirmDiscard = false }
        // suggestions from the note's words as it is typed (0.3 s after the last key), on this Mac only (TAGS.md §5)
        .task(id: draft.note) {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let kind: MarkKind = draft.mode == .box ? .box : draft.mode == .point ? .note : draft.kind
            let s = tags.suggest ? TagSuggester.suggest(note: draft.note, kind: kind, quote: draft.quote, catalog: tags.catalog,
                                                        on: picking.on) : []
            if s != picking.suggestions { picking.suggestions = s }
        }
    }

    private func cancel() {
        if draft.changed && !draft.confirmDiscard {
            draft.confirmDiscard = true
        } else {
            onCancel()
        }
    }
}

struct NewPaperSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var student = ""
    /// The folder chosen with Choose…; without one, a new folder named by the title in Settings › Data & Storage's
    /// "New review folders" (`DataModel.root`), when that is set.
    @State private var chosen: String?

    /// The review folder Create makes: the one chosen, else `<default folder>/<title>` (a name not taken there).
    static func folder(chosen: String?, root: URL?, title: String) -> String? {
        if let chosen { return chosen }
        guard let root, !title.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return DataFiles.unique(DataFiles.name(title), in: root).path
    }

    var body: some View {
        let root = model.data.root
        let folder = Self.folder(chosen: chosen, root: root, title: title)
        VStack(alignment: .leading, spacing: 14) {
            Text("New Paper").font(.title2.bold())
            Form {
                TextField("Title", text: $title)
                TextField("Student", text: $student)
                LabeledContent("Review folder") {
                    HStack {
                        Text(folder.map { DataFiles.shown(URL(fileURLWithPath: $0)) }
                             ?? (root == nil ? "None chosen" : "Named by the title, in " + DataFiles.shown(root!)))
                            .foregroundStyle(folder == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(folder ?? "")
                        Spacer()
                        Button("Choose…") {
                            chosen = model.chooseFolder(prompt: "Choose",
                                                        message: "Choose or create an empty folder for this paper’s review files.") ?? chosen
                        }
                    }
                }
            }
            Text("The review folder holds the ledger, round snapshots and outputs. It is not the student’s source folder."
                 + (root != nil && chosen == nil ? " Settings › Data & Storage sets where new ones go." : ""))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    if let folder { model.createPaper(title: title, student: student, folder: folder) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty
                          || student.trimmingCharacters(in: .whitespaces).isEmpty || folder == nil)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

/// Start Round 1 that the engine refused: the folder chosen and the engine's words ("Several files could be the main
/// file: draft.tex, paper.tex. Choose one.").
struct StartRefusal: Equatable {
    var source: String
    var problem: String
}

/// Run ingest again, optionally with another source, main file, engine or shell escape: after a failed build (Retry…),
/// for a round that built before anything was done in it (Build Round N Again…), or for Round 1 when the engine refused
/// it (`AppModel.startRefused`). That one stays until the round is there, so a second refusal shows here too.
struct RetrySheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var source = ""
    @State private var main = ""
    @State private var engine = ""
    @State private var first = false
    @State private var shellEscape = false
    @State private var askedShellEscape = false
    @FocusState private var mainFocused: Bool

    /// "Build Round 2 Again" for the open round it replaces; "Start Round 1" when there is none to replace.
    static func title(_ latest: RoundSummary?, replacing: Bool = false) -> String {
        if replacing { return "Replace Draft" }
        guard let r = latest, !r.closed else { return "Start Round \((latest?.n ?? 0) + 1)" }
        return "Build Round \(r.n) Again"
    }

    /// The Shell escape toggle, only where it matters (UX.md §41): never before a round exists (Start Round 1); else
    /// when Build Again with Shell Escape… opened the sheet, the paper has it on, or the latest round's build asks for
    /// it. Build sends its value only while it is shown; otherwise the engine keeps the paper's choice.
    static func showsShellEscape(hasRound: Bool, asked: Bool, paperOn: Bool, latestNeeds: Bool) -> Bool {
        hasRound && (asked || paperOn || latestNeeds)
    }

    private var showsShellEscape: Bool {
        let shown = model.round, latest = model.latestRound
        return Self.showsShellEscape(hasRound: latest != nil, asked: askedShellEscape, paperOn: model.state?.paper.shellEscape == true,
                                     latestNeeds: shown != nil && shown?.n == latest?.n && shown?.build.needsShellEscape == true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(Self.title(model.latestRound, replacing: model.retryReplacingDraft)).font(.title2.bold())
            if model.retryReplacingDraft, let n = model.latestRound?.n {
                Text("Replace the source for Round \(n). The previous draft is not kept as a separate round.")
                    .foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if first, let problem = model.startRefused?.problem {
                Text(problem).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            Form {
                LabeledContent("Source") {
                    HStack {
                        Text(source).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Choose…") {
                            if let s = model.chooseFolder(prompt: "Choose", message: "Choose the student’s LaTeX source folder (or a .zip).",
                                                          allowZip: true) { source = s }
                        }
                    }
                }
                TextField("Main file", text: $main).focused($mainFocused)
                Picker("Engine", selection: $engine) {
                    // none chosen yet (Round 1): the engine's own choice from the source, as Start Round 1… makes it
                    if model.state?.paper.engine == nil { Text("Automatic").tag("") }
                    Text("pdflatex").tag("pdflatex")
                    Text("xelatex").tag("xelatex")
                    Text("lualatex").tag("lualatex")
                }
                if showsShellEscape {
                    Toggle("Shell escape", isOn: $shellEscape)
                    if shellEscape {
                        // the small size of a control's explanation, so it stays one line in the form's column
                        Text("Lets this paper’s LaTeX run commands on your Mac. Use it only for a source you trust.")
                            .font(.system(size: 11))
                            .foregroundStyle(Ink.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack {
                if first && model.busy {
                    ProgressView().controlSize(.small)
                    Text(model.progress.isEmpty ? "Working…" : model.progress).font(.callout).foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Cancel", role: .cancel) {
                    model.startRefused = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(model.retryReplacingDraft ? "Replace" : "Build") {
                    model.ingest(source: source, main: main, engine: engine, shellEscape: showsShellEscape ? shellEscape : nil)
                    if !first { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(source.isEmpty || model.busy || (model.retryReplacingDraft && !model.canBuildAgain))
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            first = model.startRefused != nil
            // Replace Draft… asks for a new source, unless one was dropped on the paper (SourceDrop.swift)
            source = model.retryReplacingDraft ? model.retrySource ?? "" : model.startRefused?.source ?? model.lastSource ?? ""
            model.retrySource = nil
            main = model.state?.paper.main ?? ""
            engine = model.state?.paper.engine ?? ""
            askedShellEscape = model.retryWithShellEscape
            shellEscape = askedShellEscape || model.state?.paper.shellEscape == true
            if first { mainFocused = true }
        }
        // Round 1 is there: built, or not (a failed build has its own Retry…)
        .onChange(of: model.state?.rounds.isEmpty == false) { _, built in
            if first && built {
                model.startRefused = nil
                dismiss()
            }
        }
    }
}

/// What the Finish sheet states, each once (POLISH §3 row 11; design/ui-v2/PROPOSAL.md §3): what is left for the
/// advisor (the three to-dos), the words not sent yet (the unsent drafts), and what goes to the student. Pure, so it is
/// unit-tested.
struct FinishSummary: Equatable {
    struct Draft: Equatable, Identifiable {
        var id: String
        var text: String
        var status: Status
    }

    /// A draft sent as a follow-up or discarded in the sheet (`sent`): its row stays where it was and says so, with the
    /// words as typed (`raw`), which a discard's Undo puts back.
    struct Handled: Equatable {
        var draft: Draft
        var raw: String
        var sent: Bool
    }

    /// A row of Words not sent yet: an unsent draft, or one handled in the sheet.
    struct DraftRow: Equatable, Identifiable {
        var draft: Draft
        var handled: Handled?
        var id: String { draft.id }
    }

    /// The sheet's draft rows in the drafts' order (by id), the handled ones where they were, so no row moves under the
    /// pointer when one is sent or discarded (interaction review 2026-10-18). A draft still unsent (its Send under way,
    /// or refused by the engine) is shown as one.
    static func rows(_ drafts: [Draft], handled: [String: Handled]) -> [DraftRow] {
        let live = Set(drafts.map(\.id))
        return (drafts.map { DraftRow(draft: $0) } + handled.values.filter { !live.contains($0.draft.id) }
            .map { DraftRow(draft: $0.draft, handled: $0) })
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    /// One of the sheet's rows: what it counts, its words and how many. `nothing`: the line saying none go to the
    /// student, drawn without a sign or a count (review 2026-10-24: it read "+ No follow-ups, new or closed comments 0").
    struct Line: Equatable {
        enum Item: String { case comments, edits, paragraphs, checksToCheck, checksPending, followUps, new, closed, checks, nothing }
        var item: Item
        var title: String
        var sub = ""
        var count: Int
    }

    var round: Int
    var followUps = 0
    var followUpsWithNotes = 0
    var new = 0
    var toCheck = 0  // carried without an answer: they go out as "still open"
    var closed = 0  // resolved or kept as is
    var drafts: [Draft] = []  // unsent drafts of cards to check, by id
    var unrequested = 0  // edits no comment asked for, not checked, asked about or read (AppModel.toCheck)
    var unread: Int?  // changed paragraphs not marked read, from round 2 (nil before they are found)
    /// The round's automatic checks that go out, those marked OK, and those the student answered (design/checks-ui):
    /// nil while Checks is off or its checks are not in.
    var checks: Checks?

    struct Checks: Equatable {
        var sent: Int
        var ok: Int
        var toCheck: Int
        /// Still being found: Finish now sends none of this round's new ones.
        var pending = false
    }

    init(round: Int, comments: [Comment], drafts: [String: String], unrequested: Int, unread: Int?) {
        self.round = round
        for c in comments {
            switch Status(c) {
            case .new: new += 1
            case .toCheck, .notFound: toCheck += 1
            case .followUp:
                followUps += 1
                if !AppModel.trimmed(c.verdictNote ?? "").isEmpty { followUpsWithNotes += 1 }
            case .resolved, .keptAsIs: closed += 1
            }
        }
        let open = Dictionary(comments.filter { $0.carried && $0.verdict == nil }.map { ($0.id, Status($0)) },
                              uniquingKeysWith: { a, _ in a })
        self.drafts = drafts.compactMap { id, text in
            let t = AppModel.trimmed(text)
            return t.isEmpty ? nil : open[id].map { Draft(id: id, text: t, status: $0) }
        }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        self.unrequested = unrequested
        self.unread = round > 1 ? unread : nil
    }

    /// Left for you: the three to-dos side by side, each only when some are left, with what finishing does to them.
    /// The round can be finished with any of them left.
    var left: [Line] {
        var out: [Line] = []
        if toCheck > 0 {
            out.append(Line(item: .comments, title: toCheck == 1 ? "Comment still to check" : "Comments still to check",
                            sub: toCheck == 1 ? "It goes out as “still open”." : "They go out as “still open”.", count: toCheck))
        }
        if unrequested > 0 {
            // the one noun (design/review-page/BRIEF.md §8): its title says what they are
            out.append(Line(item: .edits, title: unrequested == 1 ? "Unasked edit not checked" : "Unasked edits not checked",
                            sub: "", count: unrequested))
        }
        if let c = checks, c.pending {
            out.append(Line(item: .checksPending, title: "Automatic checks still being found",
                            sub: "Finished now, none of them goes out with this round.", count: 0))
        }
        if let c = checks, c.toCheck > 0 {
            out.append(Line(item: .checksToCheck, title: c.toCheck == 1 ? "Check the student answered" : "Checks the student answered",
                            sub: c.toCheck == 1 ? "It goes out again as “still open”." : "They go out again as “still open”.",
                            count: c.toCheck))
        }
        if let u = unread, u > 0 {
            out.append(Line(item: .paragraphs, title: u == 1 ? "Changed paragraph not read" : "Changed paragraphs not read",
                            sub: u == 1 ? "Finishing marks it read." : "Finishing marks them read.", count: u))
        }
        return out
    }

    /// Goes to the student, in final.pdf: the follow-ups ("with your notes" when each has one), the new comments and
    /// the closed ones; each only when there are some, as Left for you (visual review 2026-10-18: New comments 0 was
    /// listed, Follow-ups 0 not), and one line saying so when there are none.
    var goes: [Line] {
        var out: [Line] = []
        if followUps > 0 {
            out.append(Line(item: .followUps, title: "Follow-ups" + (followUpsWithNotes == followUps ? " · with your notes" : ""),
                            count: followUps))
        }
        if new > 0 { out.append(Line(item: .new, title: "New comments", count: new)) }
        if closed > 0 { out.append(Line(item: .closed, title: "Closed", count: closed)) }
        if let c = checks, c.sent > 0 {
            out.append(Line(item: .checks, title: "Automatic checks",
                            sub: "found by Paperole" + (c.ok > 0 ? " · \(c.ok) marked OK " + (c.ok == 1 ? "is" : "are") + " left out" : ""),
                            count: c.sent))
        }
        return out.isEmpty ? [Line(item: .nothing, title: "No follow-ups, new or closed comments", count: 0)] : out
    }

    /// Review's card for Comments still to check: the first by its status, as the count is. A card answered while
    /// selected stays listed in To check (`CardGroups`' held card) but is not one.
    static func firstToCheck(_ cards: [CardModel]) -> String? {
        cards.first { CardGroups.group($0.status) == .toCheck }?.id
    }

    /// A resumed round's one quiet line (UX.md §31): "Finished before on Oct 21. Those files are kept in the round’s
    /// folder." (each day once: "on Oct 20 and Oct 21"); nil for a round never resumed.
    static func finishedBefore(_ finishes: [RoundInfo.Finish]) -> String? {
        guard !finishes.isEmpty else { return nil }
        var days: [String] = []
        for f in finishes { if let d = shortDate(f.at), !days.contains(d) { days.append(d) } }
        let on = days.count < 2 ? days.first : days.dropLast().joined(separator: ", ") + " and " + days.last!
        return "Finished before" + (on.map { " on " + $0 } ?? "") + ". Those files are kept in the round’s folder."
    }

    /// The kept files that are there, for Show in Finder.
    static func keptFiles(_ finishes: [RoundInfo.Finish]) -> [URL] {
        finishes.flatMap { [$0.final, $0.email] }.compactMap { $0 }
            .filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
}

/// Finish Round (UX.md §17; POLISH §3 row 11): one sheet that reads top to bottom as a hand-off. On the left, what is
/// left for you (the comments, other edits and changed paragraphs, each with its count and a way to it), the words not
/// sent yet (each unsent draft by its comment's chip and its own words, sent as a follow-up or discarded here; nothing
/// goes out silently), then what goes to the student. On the right the round's card so far (RoundCard.swift), again
/// after every engine reply. Finish Round writes final.pdf and closes the round (no email: request of 2026-10-26, the
/// PDF is enough); the sheet then turns into the round's card, whole (`RoundSummaryView`).
struct FinishSheet: View {
    @ObservedObject var preview: FinishPreview
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let done = preview.done {
            RoundSummaryView(ask: done) { model.closeFinishSummary() }
        } else {
            finishing
        }
    }

    private var finishing: some View {
        let n = model.round?.n ?? 0
        var s = FinishSummary(round: n, comments: model.state?.comments ?? [], drafts: model.drafts,
                              unrequested: model.toCheck, unread: model.unreadCount)
        s.checks = model.finishChecks
        return VStack(alignment: .leading, spacing: 0) {
            Text("Finish Round \(n)").font(.title2.bold())  // as every sheet's title
            Text("This writes final.pdf, then closes Round \(n). A closed round is read only.")
                .font(.system(size: 12.5)).foregroundStyle(Ink.secondary).padding(.top, 4)
            // a resumed round (UX.md §31): what the earlier Finish wrote is kept, beside the new files
            if let finishes = model.round?.finishes, let before = FinishSummary.finishedBefore(finishes) {
                HStack(spacing: 8) {
                    Text(before).foregroundStyle(Ink.secondary)
                    let kept = FinishSummary.keptFiles(finishes)
                    if !kept.isEmpty {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(kept) }
                            .buttonStyle(LinkStyle())
                            .help("Show the final.pdf and email kept from the earlier finish")
                    }
                }
                .font(.system(size: 12))
                .lineLimit(1)
                .padding(.top, 3)
            }
            HStack(alignment: .top, spacing: 22) {
                // the whole column when it fits; else the drafts scroll, so the round's card stays in view
                ViewThatFits(in: .vertical) {
                    handOff(s, scrollingDrafts: false).padding(2)
                    handOff(s, scrollingDrafts: true).padding(2)
                }
                .frame(width: 430, alignment: .top)
                .frame(maxHeight: .infinity, alignment: .top)
                // what the student gets, as Finish would write it now (design/summary-page)
                VStack(alignment: .leading, spacing: 0) {
                    header("final.pdf", first: true)
                    finalPreview
                }
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .padding(.top, 16)
            .frame(maxHeight: .infinity)
            HStack(spacing: 10) {
                if let e = preview.error {
                    Text(e).font(.system(size: 12)).foregroundStyle(Color(nsColor: Palette.danger)).lineLimit(2)
                }
                Spacer(minLength: 8)
                Button("Cancel") { model.showFinish = false }.keyboardShortcut(.cancelAction)
                Button(preview.finishing ? "Finishing…" : "Finish Round") { model.finishRound() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(preview.finishing || model.busy || !model.roundIsOpen)
                    .help("Write final.pdf and close Round \(n)")
            }
            .controlSize(.large)
            .padding(.top, 16)
        }
        .foregroundStyle(Ink.label)
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 18)
        .frame(width: 1120, height: 760)
        .background(Color(nsColor: Palette.sheet))
    }

    /// The preview in a white box: the document, else while the first is made a quiet spinner, else its error. A
    /// newer preview replaces the shown one when it is ready.
    private var finalPreview: some View {
        ZStack {
            Color.white
            if let doc = preview.document {
                FinalPreviewView(document: doc, ids: Set((model.state?.comments ?? []).map(\.id))) { id in
                    model.review(.comment(id))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let e = preview.previewError {
                Text(e).font(.system(size: 12)).foregroundStyle(Color(nsColor: NSColor(white: 0.36, alpha: 1)))
                    .multilineTextAlignment(.center).padding(24)
            } else {
                ProgressView().controlSize(.small).colorScheme(.light)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: Palette.rule), lineWidth: 0.5))
    }

    /// The left column: Left for you, Words not sent yet (`scrollingDrafts`: in a list of their own that scrolls), the
    /// round's card so far, and what finishing does to the paragraphs. What goes to the student is the preview's.
    private func handOff(_ s: FinishSummary, scrollingDrafts: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !s.left.isEmpty {
                header("Left for you", sub: "· you can still finish", first: true)
                box(s.left)
            }
            let rows = FinishSummary.rows(s.drafts, handled: preview.handled)
            if !rows.isEmpty {
                header("Words not sent yet", sub: "· not in final.pdf unless you send them", first: s.left.isEmpty)
                let drafts = group {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                        draft(r).overlay(alignment: .top) { if i > 0 { separator } }
                    }
                }
                if scrollingDrafts {
                    // a scroll bar shown before any scroll, so a list that goes on below reads as one (BACKLOG O28)
                    ScrollView { drafts.padding(1).background(AlwaysShownScroller()) }.scrollIndicators(.visible)
                } else {
                    drafts
                }
            }
            header("This round", sub: "· your card when you finish", first: s.left.isEmpty && rows.isEmpty)
            if let st = model.state { CompactRoundCard(stats: model.roundStats(st), dark: scheme == .dark) }
            // about the bars: not said while reading marks are off (Settings), when there are none
            if model.readingMarksOn {
                Text(s.round == 1 ? "Finishing Round 1 marks every paragraph read."
                     : "Finishing marks every paragraph read, so the next round’s bars show only what changes after it.")
                    .font(.system(size: 12)).foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
        }
    }

    /// A group's name (12 Semibold in the second label colour) and its quieter words.
    private func header(_ text: String, sub: String = "", first: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.label2)
            if !sub.isEmpty { Text(sub).font(.system(size: 12)).foregroundStyle(Ink.secondary) }
        }
        .lineLimit(1)
        .padding(.horizontal, 2)
        .padding(.top, first ? 0 : 14)
        .padding(.bottom, 6)
    }

    /// Rows with a hairline between them, in a grouped box: the sign, the words (and what they mean, under them), the
    /// way to them, and the count.
    private func box(_ lines: [FinishSummary.Line]) -> some View {
        group {
            ForEach(Array(lines.enumerated()), id: \.element.item) { i, l in
                HStack(spacing: 9) {
                    if l.item != .nothing { icon(l.item).frame(width: 18) }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(l.title).font(.system(size: 13))
                        if !l.sub.isEmpty { Text(l.sub).font(.system(size: 11)).foregroundStyle(Ink.secondary) }
                    }
                    .lineLimit(1)
                    Spacer(minLength: 4)
                    if let w = way(l.item) {
                        Button(w.title) { go(l.item) }
                            .buttonStyle(AnswerButtonStyle(style: .plain, small: true))
                            .help(w.help)
                    }
                    if l.item != .nothing && l.item != .checksPending {
                        Text("\(l.count)").font(.system(size: 13, weight: .semibold)).monospacedDigit().frame(minWidth: 18, alignment: .trailing)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(minHeight: 38)
                .overlay(alignment: .top) { if i > 0 { separator } }
            }
        }
    }

    /// The hairline between two rows, from the words on (not under the signs).
    private var separator: some View {
        Rectangle().fill(Color(nsColor: Palette.rule)).frame(height: 1).padding(.leading, 39)
    }

    @ViewBuilder private func icon(_ item: FinishSummary.Line.Item) -> some View {
        let attention = Color(nsColor: Palette.toCheck), neutral = Color(nsColor: Palette.neutral)
        switch item {
        case .paragraphs: RoundedRectangle(cornerRadius: 1.5).fill(Color(nsColor: Palette.reading)).frame(width: 3, height: 13)
        default:
            let (name, color): (String, Color) = switch item {
            case .comments, .checksToCheck: ("circle", attention)
            case .checksPending: ("hourglass", neutral)
            case .edits: ("pencil", attention)
            case .checks: ("square.dashed", neutral)
            case .followUps: ("arrow.uturn.backward", neutral)
            case .new: ("plus", neutral)
            default: ("checkmark", neutral)
            }
            Image(systemName: name).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
        }
    }

    /// A to-do's button: Review closes the sheet and shows the first comment or edit left; Show goes to the next
    /// changed paragraph to read, as Next does.
    private func way(_ item: FinishSummary.Line.Item) -> (title: String, help: String)? {
        switch item {
        case .comments: ("Review", "Show the first comment still to check")
        case .checksToCheck: ("Review", "Show the first check the student answered, on the Checks tab")
        case .edits: ("Review", "Show the first other edit not checked, on the Changes tab")
        case .paragraphs: ("Show", "Go to the next changed paragraph to read")
        default: nil
        }
    }

    private func go(_ item: FinishSummary.Line.Item) {
        switch item {
        case .comments: model.review(FinishSummary.firstToCheck(model.panel.cards).map { .comment($0) })
        case .edits: model.review(model.changes.unrequested.first { !$0.handled }.map { .change($0.id) })
        case .paragraphs: model.reviewReading()
        case .checksToCheck: model.reviewCheck()
        default: break
        }
    }

    /// An unsent draft: its card's chip, its words, and what to do with them. Once sent or discarded here, the row stays
    /// where it is and says so, its buttons gone (a double click's second click finds none), a discard with Undo at the
    /// far right, away from where Discard was.
    private func draft(_ r: FinishSummary.DraftRow) -> some View {
        let d = r.draft
        return HStack(alignment: .top, spacing: 9) {
            Chip(id: d.id, status: d.status).padding(.top, 1)
            VStack(alignment: .leading, spacing: 0) {
                Text("“" + d.text + "”").font(.system(size: 12.5)).lineSpacing(2).lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(r.handled == nil ? Ink.label : Ink.secondary)
                Text("Unsent draft · kept on this Mac").font(.system(size: 11)).foregroundStyle(Ink.secondary).padding(.top, 3)
                    .opacity(r.handled == nil ? 1 : 0)
                HStack(spacing: 8) {
                    if let h = r.handled {
                        Image(systemName: h.sent ? "arrow.uturn.backward" : "trash").font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Ink.secondary)
                        Text(h.sent ? "Sent as a follow-up" : "Discarded")
                            .font(.system(size: 12)).foregroundStyle(Ink.secondary)
                        Spacer(minLength: 8)
                        if !h.sent {
                            Button("Undo") { model.finishRestoreDraft(d.id) }
                                .buttonStyle(LinkStyle()).font(.system(size: 12, weight: .medium))
                                .help("Put the draft back on \(d.id)")
                        }
                    } else {
                        Button { model.finishDraft(d.id, send: true) } label: { Label("Send as follow-up", systemImage: "arrow.uturn.backward") }
                            .buttonStyle(AnswerButtonStyle(style: .plain, small: true))
                            .help("Send it to the student with this round’s final.pdf; \(d.id) stays open")
                        Button("Discard") { model.finishDraft(d.id, send: false) }
                            .buttonStyle(AnswerButtonStyle(style: .plain, small: true))
                            .help("Delete this draft (Undo here brings it back)")
                        Button("Show") { model.review(.comment(d.id)) }
                            .buttonStyle(LinkStyle()).font(.system(size: 12, weight: .medium))
                            .help("Close this and show \(d.id)")
                        Spacer(minLength: 0)
                    }
                }
                .frame(height: 22)
                .disabled(model.busy || preview.finishing)
                .padding(.top, 7)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: Palette.group))
                .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.06), radius: 1, y: 1))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: Palette.rule), lineWidth: 0.5))
    }
}

/// Inside a SwiftUI ScrollView's content: its scroll bar always shown, with its track (BACKLOG O28: the Finish sheet's
/// drafts list had the overlay scroller, which shows only while it scrolls, so a list that went on below its edge
/// looked whole). Again when the system's scroll bar setting changes, which resets every scroll view's style.
struct AlwaysShownScroller: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ v: Probe, context: Context) { v.apply() }

    final class Probe: NSView {
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            DispatchQueue.main.async { [weak self] in self?.apply() }  // after SwiftUI has set up its scroll view
            if observer == nil {
                observer = NotificationCenter.default.addObserver(forName: NSScroller.preferredScrollerStyleDidChangeNotification,
                                                                  object: nil, queue: .main) { [weak self] _ in
                    DispatchQueue.main.async { self?.apply() }
                }
            }
        }

        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

        func apply() {
            guard let sv = enclosingScrollView else { return }
            if !sv.hasVerticalScroller { sv.hasVerticalScroller = true }
            if sv.autohidesScrollers { sv.autohidesScrollers = false }
            if sv.scrollerStyle != .legacy { sv.scrollerStyle = .legacy }
        }
    }
}
