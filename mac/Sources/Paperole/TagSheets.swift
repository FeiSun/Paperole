import AppKit
import SwiftUI

// Tag Comments… (design/tags/TAGS.md §2.4 with the critique's fix: the comments not tagged yet, of every round at once,
// under round headers) and Settings › Tags (§4, with the critique's fixes: a Show in Picker checkbox, the system's
// selection, Merge without the engine's alias). UX.md §24.

/// The comments a Tag Comments… sheet lists: one paper's (its overview) or a student's papers' (the hierarchy's).
@MainActor
final class TagCommentsModel: ObservableObject, Identifiable {
    struct Entry: Identifiable, Equatable {
        var paper: String
        var paperTitle: String
        var id: String
        var round: Int
        var page: Int?
        var note: String
        var kind: String?
        var color: String?
        var tags: [String]

        var key: String { paper + "#" + id }
        var markColor: MarkColor { MarkColor(name: color ?? "") ?? .yellow }
    }

    let id = UUID()
    let title: String
    @Published private(set) var entries: [Entry]
    /// Every comment, or (by default) those not tagged yet and those tagged in this sheet, which stay where they are.
    @Published var showAll = false
    @Published private(set) var selected: String?
    @Published private(set) var selection: TagSelection?
    private var touched: Set<String> = []
    weak var model: AppModel?

    init(title: String, papers: [(path: String, title: String, data: PaperOverview)]) {
        self.title = title
        var out: [Entry] = []
        for p in papers {
            for c in p.data.comments {
                let n = c.createdRound ?? c.path.first?.round ?? 0
                out.append(Entry(paper: p.path, paperTitle: p.title, id: c.id, round: n, page: c.path.first { $0.round == n }?.page,
                                 note: c.note ?? "", kind: c.kind, color: c.color, tags: c.tags))
            }
        }
        let order = Dictionary(papers.enumerated().map { ($0.element.path, $0.offset) }, uniquingKeysWith: { a, _ in a })
        entries = out.sorted { a, b in
            (order[a.paper] ?? 0, a.round, Self.number(a.id), a.id) < (order[b.paper] ?? 0, b.round, Self.number(b.id), b.id)
        }
    }

    /// R1-02 before R1-10.
    static func number(_ id: String) -> Int { Int(id.split(separator: "-").last ?? "") ?? 0 }

    var listed: [Entry] { showAll ? entries : entries.filter { $0.tags.isEmpty || touched.contains($0.key) } }
    var tagged: Int { entries.filter { !$0.tags.isEmpty }.count }
    var papers: Int { Set(entries.map(\.paper)).count }

    /// A row clicked: the row before is written (when changed), this one shows the chips.
    func select(_ key: String?, tags: TagModel) {
        commit()
        selected = key
        guard let key, let e = entries.first(where: { $0.key == key }) else { selection = nil; return }
        let s = tags.suggest && e.tags.isEmpty ? suggestions(e, catalog: tags.catalog) : []
        selection = TagSelection(on: e.tags, suggestions: s)
    }

    /// An entry's suggestions: from its note and kind (the overview has no more); a comment of the paper shown as the
    /// card has them, from its state (its place, the words it is on). A box elsewhere gets none by its place: its words
    /// are not known (the review: every box got Figures & tables, and equations and references nothing).
    func suggestions(_ e: Entry, catalog: TagCatalog) -> [TagSuggestion] {
        if let m = model, e.paper == m.selectedPath, let c = m.comment(e.id) { return TagSuggester.suggest(for: c, catalog: catalog) }
        return TagSuggester.suggest(note: e.note, kind: e.kind.flatMap(MarkKind.init(rawValue:)), catalog: catalog)
    }

    /// The selected row's tags, written when they changed (through the engine's `tag`, without a state).
    func commit() {
        guard let key = selected, let sel = selection, sel.changed, let i = entries.firstIndex(where: { $0.key == key }) else { return }
        entries[i].tags = sel.on
        touched.insert(key)
        model?.setTags(paper: entries[i].paper, id: entries[i].id, sel.on, accepted: sel.accepted)
        selection = TagSelection(on: sel.on, suggestions: sel.suggestions)  // a second change is written again
    }

    /// The header's words: "15 of 18 tagged", in how many papers.
    var summary: String {
        "\(tagged) of \(count(entries.count, "comment")) tagged" + (papers > 1 ? " in \(papers) papers" : "")
    }
}

/// Tag Comments…: the comments listed by paper and round written, the selected one with the chips (the picker's,
/// at its width and places); a click on another row writes this one's tags. Done closes it. Suggestions are dashed
/// chips, each taken with a click (no bulk accept: the critique's fix, so what counts is what the advisor clicked).
struct TagCommentsSheet: View {
    @ObservedObject var sheet: TagCommentsModel
    @ObservedObject var tags: TagModel
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Tag Comments").font(.title2.bold())  // as every sheet's title
                    Text(sheet.title + " · " + sheet.summary).font(.system(size: 13)).foregroundStyle(Ink.secondary)
                }
                Spacer()
                Toggle("Show all comments", isOn: $sheet.showAll).toggleStyle(.checkbox)
                    .help("Also list the comments that have tags, to change them")
            }
            .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let listed = sheet.listed
                        if listed.isEmpty {
                            Text(sheet.entries.isEmpty ? "No comments yet." : "Every comment has a tag. Show all comments to change them.")
                                .font(.system(size: 13)).foregroundStyle(Ink.secondary).padding(22)
                        }
                        ForEach(Array(listed.enumerated()), id: \.element.key) { i, e in
                            if i == 0 || listed[i - 1].paper != e.paper || listed[i - 1].round != e.round {
                                Text((sheet.papers > 1 ? e.paperTitle + " · " : "") + "Round \(e.round)")
                                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.label2)
                                    .padding(.horizontal, 22).padding(.top, i == 0 ? 12 : 16).padding(.bottom, 4)
                            }
                            row(e).id(e.key)
                        }
                    }
                    .padding(.bottom, 12)
                }
                .onChange(of: sheet.selected) { _, k in if let k { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(k) } } }
            }
            Divider()
            HStack {
                Text(TagText.privacy).font(.system(size: 11)).foregroundStyle(Ink.secondary)
                Spacer()
                if let sel = sheet.selection {
                    TagCommentsDone(selection: sel) { sheet.commit(); done() }
                } else {
                    Button("Done") { sheet.commit(); done() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
        }
        .frame(width: 620, height: 600)
        .background(Color(nsColor: Palette.sheet))
    }

    private func row(_ e: TagCommentsModel.Entry) -> some View {
        let on = sheet.selected == e.key
        let firstLine = e.note.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(e.id).font(.system(size: 11.5, weight: .semibold)).monospacedDigit().foregroundStyle(Ink.label2)
                Text(e.page.map { "p.\($0 + 1)" } ?? "").font(.system(size: 11)).foregroundStyle(Ink.secondary).monospacedDigit()
                Text(firstLine.isEmpty ? "A \(e.kind ?? "mark") with no note" : firstLine)
                    .font(.system(size: 13)).foregroundStyle(firstLine.isEmpty ? Ink.secondary : Ink.label)
                    .lineLimit(on ? 3 : 1).truncationMode(.tail)
                Spacer(minLength: 6)
                if !on {
                    let cat = tags.catalog
                    if e.tags.isEmpty, tags.suggest, let s = sheet.suggestions(e, catalog: cat).first {
                        // its first suggestion, quietly: the chips show it dashed when the row is clicked
                        Text(cat.name(s.id) + "?").font(.system(size: 12)).italic().foregroundStyle(Ink.secondary).lineLimit(1)
                            .help(s.reason)
                    } else {
                        Text(cat.sorted(e.tags).map { cat.name($0) }.joined(separator: " · "))
                            .font(.system(size: 12)).foregroundStyle(Ink.secondary).lineLimit(1)
                    }
                }
            }
            if on, let sel = sheet.selection {
                TagPicker(tags: tags, selection: sel, width: TagPickerSize.chips) { EmptyView() }
                    .padding(.leading, 2)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 8).fill(on ? Color(nsColor: Palette.group) : .clear))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5).fill(Color(nsColor: e.markColor.fill)).frame(width: 3).padding(.vertical, 9)
        }
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .onTapGesture { if !on { sheet.select(e.key, tags: tags) } }
        .accessibilityElement(children: on ? .contain : .combine)
        .accessibilityAddTraits(on ? [.isSelected] : [.isButton])
    }
}

/// Done, the sheet's default button, except while New Tag… has its name field: Return there adds the tag (the review:
/// AppKit gave Return to Done first, which closed the sheet and lost the name).
struct TagCommentsDone: View {
    @ObservedObject var selection: TagSelection
    let action: () -> Void

    var body: some View {
        Button("Done", action: action).keyboardShortcut(selection.naming ? nil : .defaultAction)
    }
}

// MARK: - Settings › Tags

/// Settings › Tags (TAGS.md §4 with the critique's fixes): the tags in the picker's order (drag to reorder), the
/// selected one's name, group, sign, definition and For the next draft line below; Show in Picker (a hidden tag keeps
/// its comments: history counts it); the comments each tag has in the listed papers; New Tag…, Delete for the
/// advisor's own tags no comment uses, Restore Default Names, Merge Into…; and the suggestions' switch.
struct TagsSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var tags: TagModel
    @ObservedObject var hub: HubModel
    @State private var selected: String?
    @State private var merging: (from: String, into: String)?
    @State private var restoring = false

    init(model: AppModel) {
        self.model = model
        tags = model.tags
        hub = model.hubModel
        _selected = State(initialValue: Self.debugSelection)
    }

    /// The tag selected when the tab opens (the debug item `settings tags <id>`, for screenshots); nil in use.
    nonisolated(unsafe) static var debugSelection: String?

    static let height: CGFloat = 640

    var body: some View {
        let counts = Self.counts(hub.data)
        let known = hub.status == .loaded
        let failure = Self.failure(hub.status)
        let uncounted = failure ?? "Counting the comments of your papers…"
        // Delete only from counts asked after the last edit, with every listed paper read (the code audit)
        let current = model.hubCurrent && hub.errors.isEmpty
        let restorable = tags.catalog.restorable
        Form {
            Section {
                List(selection: $selected) {
                    Section {
                        ForEach(tags.catalog.tags) { t in
                            row(t, count: known ? counts[t.id] ?? 0 : nil, uncounted: uncounted).tag(t.id)
                        }
                        .onMove { from, to in tags.update { $0.move(from: from, to: to) } }
                    } header: {
                        // the columns named (the UI audit: an unlabeled count and checkbox)
                        HStack(spacing: 8) {
                            Text("Tag").padding(.leading, 26)
                            Spacer(minLength: 6)
                            Text("Group").frame(width: Self.groupWidth, alignment: .leading)
                            Text("Comments").frame(width: Self.countWidth, alignment: .trailing)
                            Text("In Picker").frame(width: Self.pickerWidth, alignment: .center)
                        }
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Ink.secondary)
                    }
                }
                .frame(height: 264)
                .listStyle(.bordered(alternatesRowBackgrounds: false))
                HStack(spacing: 8) {
                    Button { addTag() } label: { Image(systemName: "plus") }.help("Add a tag of your own")
                    Button { deleteSelected(counts: counts, known: current) } label: { Image(systemName: "minus") }
                        .disabled(!canDelete(counts: counts, known: current))
                        .help(known && !hub.errors.isEmpty
                              ? "A paper of your list could not be read, so whether its comments use this tag is not known"
                              : failure ?? "Delete the selected tag: only one of your own that no comment uses (hide a tag in use instead)")
                    Text("Drag to reorder").font(.system(size: 11)).foregroundStyle(Ink.secondary)
                    Spacer()
                    // it asks first, and only when a built-in tag has words of yours (the review: one click overwrote
                    // them, with no undo)
                    Button("Restore Default Names") { restoring = true }
                        .disabled(restorable.isEmpty)
                        .help(restorable.isEmpty
                              ? "The built-in tags have the names, definitions and next-draft lines they came with"
                              : "The built-in tags' names, definitions and next-draft lines as they came; your own tags and the order stay")
                        .alert("Restore the default names?", isPresented: $restoring) {
                            Button("Restore") { tags.update { $0.restoreDefaultNames() } }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text(Self.restoreDetail(restorable, catalog: tags.catalog))
                        }
                }
                .controlSize(.small)
                if let id = selected, let t = tags.catalog.tag(id) {
                    TagEditor(tags: tags, tag: t, count: known ? counts[id] ?? 0 : nil, uncounted: uncounted,
                              merge: { into in merging = (id, into) })
                        .id(id)
                }
            } header: {
                Text("Your tags")
                Text("In the order the picker shows them. A hidden tag leaves the picker; its comments keep it and still count.")
            }
            Section {
                Toggle(isOn: $tags.suggest) {
                    Text("Suggest tags as you write")
                    Text("A dashed chip from your note’s words and from where the comment is (a figure, an equation, the references). Worked out on this Mac; nothing leaves it.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsView.width, height: Self.height)
        .onAppear { model.loadHub() }  // the comments each tag has in the listed papers
        // anything the counts depend on changed meanwhile (a comment tagged in Review, a tag added or moved, the app
        // active again): asked again, so Delete is not left disabled while a paper is shown (the review)
        .onChange(of: model.hubKey) { model.loadHub() }
        .alert(mergeTitle, isPresented: Binding(get: { merging != nil }, set: { if !$0 { merging = nil } })) {
            Button("Merge") { if let m = merging { model.mergeTags(from: m.from, into: m.into) }; merging = nil }
            Button("Cancel", role: .cancel) { merging = nil }
        } message: {
            Text(mergeDetail(counts: counts))
        }
    }

    private var mergeTitle: String {
        guard let m = merging else { return "" }
        return "Merge “\(tags.catalog.name(m.from))” into “\(tags.catalog.name(m.into))”?"
    }

    private func mergeDetail(counts: [String: Int]) -> String {
        guard let m = merging else { return "" }
        let from = tags.catalog.name(m.from), into = tags.catalog.name(m.into)
        let n = counts[m.from] ?? 0
        let papers = hub.data.values.filter { $0.comments.contains { $0.tags.contains(m.from) } }.count
        let gone = tags.catalog.tag(m.from)?.builtIn == true ? "is hidden" : "leaves your tags"
        return "The \(count(n, "comment")) tagged \(from)" + (papers > 0 ? " in \(count(papers, "paper"))" : "")
            + " get \(into) instead (one with both keeps one), and \(from) then \(gone). Their papers’ records change, so this cannot "
            + "be undone; papers not in your list keep \(from). To keep them apart, hide \(from) instead."
    }

    /// The hierarchy's overview failed: why, for the help of the Comments column, Merge and Delete (the review: the
    /// column said "Counting…" for good, and they were disabled with no reason). Nil otherwise.
    static func failure(_ status: HubModel.Status) -> String? {
        if case .failed(let m) = status { return "Your papers could not be read: " + m }
        return nil
    }

    /// Restore Default Names' question: which tags take back their words.
    static func restoreDetail(_ ids: [String], catalog: TagCatalog) -> String {
        let which = ids.count <= 3 ? HubText.list(ids.map { "“" + catalog.name($0) + "”" }) : "\(ids.count) built-in tags"
        return which + (ids.count == 1 ? " takes back the name, definition and next-draft line it came with."
                                       : " take back the names, definitions and next-draft lines they came with.")
            + " Your own tags and the order stay. This cannot be undone."
    }

    static let groupWidth: CGFloat = 92, countWidth: CGFloat = 64, pickerWidth: CGFloat = 58

    /// A row: sign, name (its definition in its help tag and in the editor below, not cut off in the row: the UI
    /// audit), group, comments, In Picker.
    private func row(_ t: WritingTag, count: Int?, uncounted: String) -> some View {
        HStack(spacing: 8) {
            TagSign(sign: t.sign, name: t.name).frame(width: 18).foregroundStyle(t.hidden ? Ink.secondary : Ink.label2)
            Text(t.name).foregroundStyle(t.hidden ? Ink.secondary : Ink.label).lineLimit(1)
                .help(t.hint)
            if t.hidden {
                Text("hidden").foregroundStyle(Ink.secondary).lineLimit(1)
                    .help("Hidden from the picker; its comments keep it and still count")
            }
            Spacer(minLength: 6)
            Text(t.group.title).foregroundStyle(Ink.secondary).lineLimit(1).frame(width: Self.groupWidth, alignment: .leading)
            Text(count.map(String.init) ?? "–").monospacedDigit().foregroundStyle(Ink.label2)
                .frame(width: Self.countWidth, alignment: .trailing)
                .help(count == nil ? uncounted : "Comments with this tag in your listed papers, each once")
            Toggle("Show in Picker", isOn: Binding(get: { !t.hidden }, set: { on in tags.update { $0.setHidden(t.id, !on) } }))
                .toggleStyle(.checkbox).labelsHidden()
                .frame(width: Self.pickerWidth, alignment: .center)
                .help(t.hidden ? "Hidden from the picker: check to show it again" : "Shown in the picker: uncheck to hide it (its comments keep it)")
        }
        .font(.system(size: 12.5))
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Move Up") { tags.update { $0.step(t.id, by: -1) } }
        .accessibilityAction(named: "Move Down") { tags.update { $0.step(t.id, by: 1) } }
    }

    private func addTag() {
        var n = 1
        while tags.catalog.named("New tag" + (n == 1 ? "" : " \(n)")) != nil { n += 1 }
        if let (id, _) = tags.add(name: "New tag" + (n == 1 ? "" : " \(n)"), sign: nil) { selected = id }
    }

    private func canDelete(counts: [String: Int], known: Bool) -> Bool {
        guard let id = selected, let t = tags.catalog.tag(id), !t.builtIn, known else { return false }
        return (counts[id] ?? 0) == 0
    }

    private func deleteSelected(counts: [String: Int], known: Bool) {
        guard canDelete(counts: counts, known: known), let id = selected else { return }
        tags.update { _ = $0.delete(id, used: 0) }
        selected = nil
    }

    /// The comments each tag has in the listed papers (the hierarchy's overviews), each comment once a tag.
    static func counts(_ data: [String: PaperOverview]) -> [String: Int] {
        var out: [String: Int] = [:]
        for d in data.values { for c in d.comments { for t in Set(c.tags) { out[t, default: 0] += 1 } } }
        return out
    }
}

/// The selected tag in Settings › Tags: its name (Return or a click elsewhere keeps it), group, sign, definition (its
/// help tag) and For the next draft line (the Student page's), and Merge Into….
struct TagEditor: View {
    @ObservedObject var tags: TagModel
    let tag: WritingTag
    let count: Int?
    /// Why `count` is nil: the comments being counted, or the papers that could not be read.
    let uncounted: String
    let merge: (String) -> Void
    @State private var fields: TagEditorFields
    @State private var refused = false

    init(tags: TagModel, tag: WritingTag, count: Int?, uncounted: String, merge: @escaping (String) -> Void) {
        self.tags = tags
        self.tag = tag
        self.count = count
        self.uncounted = uncounted
        self.merge = merge
        _fields = State(initialValue: TagEditorFields(tag))
    }

    var body: some View {
        Group {
            LabeledContent("Name") {
                HStack(spacing: 8) {
                    TextField("Name", text: $fields.name)
                        .labelsHidden()
                        .onSubmit(rename)
                        .onChange(of: fields.name) { refused = false }
                    Menu {
                        Button("No Sign") { tags.update { $0.setSign(tag.id, nil) } }
                        Divider()
                        ForEach(tags.catalog.freeSigns(for: tag.id), id: \.self) { s in
                            Button { tags.update { $0.setSign(tag.id, s) } } label: { Label(TagCatalog.signName(s), systemImage: s) }
                        }
                    } label: {
                        TagSign(sign: tag.sign, name: tag.name)
                    }
                    .fixedSize()
                    .help("Its sign")
                }
            }
            if refused { Text("Another tag has that name.").font(.system(size: 11)).foregroundStyle(Ink.secondary) }
            Picker("Group", selection: Binding(get: { tag.group }, set: { g in tags.update { $0.setGroup(tag.id, g) } })) {
                ForEach(TagGroup.allCases) { Text($0.title).tag($0) }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Definition")
                TextField("What the tag is for: its help tag", text: $fields.hint, axis: .vertical)
                    .textFieldStyle(.roundedBorder).labelsHidden().lineLimit(1...3).multilineTextAlignment(.leading)
                    .onSubmit { tags.update { $0.setHint(tag.id, fields.hint) } }
            }
            if tag.group != .praise {
                VStack(alignment: .leading, spacing: 5) {
                    Text("For the next draft")
                    TextField("A line for the student, in English: the Student page’s For the next draft", text: $fields.focus, axis: .vertical)
                        .textFieldStyle(.roundedBorder).labelsHidden().lineLimit(1...3).multilineTextAlignment(.leading)
                        .onSubmit { tags.update { $0.setFocus(tag.id, fields.focus) } }
                }
            }
            LabeledContent("Merge") {
                Menu("Merge Into…") {
                    ForEach(tags.catalog.tags.filter { $0.id != tag.id }) { t in
                        Button(t.name) { merge(t.id) }
                    }
                }
                .fixedSize()
                .disabled(count == nil || count == 0)
                .help(count == nil ? uncounted
                      : count == 0 ? "No comment has this tag: hide or delete it instead" : "Give its comments another tag, then let it go")
            }
        }
        // the tag changed from elsewhere (Restore Default Names): the fields follow, so leaving does not write the old
        // words back (the code audit)
        .onChange(of: tag) { old, new in fields.follow(old, new) }
        .onDisappear(perform: save)
    }

    private func rename() {
        if fields.keepName(tag) { return }
        var ok = true
        tags.update { ok = $0.rename(tag.id, to: fields.name) }
        if !ok && TagCatalog.clean(fields.name) != tag.name { refused = true }
    }

    private func save() {
        if fields.name != tag.name { rename() }
        if fields.hint != tag.hint { tags.update { $0.setHint(tag.id, fields.hint) } }
        if fields.focus != tag.focus { tags.update { $0.setFocus(tag.id, fields.focus) } }
    }
}

/// The tag editor's text fields. When the tag changes from elsewhere, each field whose stored words changed takes
/// them; one the advisor is typing in keeps its text unless that very field changed.
struct TagEditorFields: Equatable {
    var name: String
    var hint: String
    var focus: String

    init(_ t: WritingTag) {
        name = t.name
        hint = t.hint
        focus = t.focus
    }

    mutating func follow(_ old: WritingTag, _ new: WritingTag) {
        if old.name != new.name { name = new.name }
        if old.hint != new.hint { hint = new.hint }
        if old.focus != new.focus { focus = new.focus }
    }

    /// The name field emptied: the tag keeps its name, which the field shows again (the review: it said another tag
    /// had that name). True when so, and there is nothing to write.
    mutating func keepName(_ t: WritingTag) -> Bool {
        guard TagCatalog.clean(name) == nil else { return false }
        name = t.name
        return true
    }
}
