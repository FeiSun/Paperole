import AppKit
import SwiftUI

// The sheets of Export… and Import… (design/data/DATA.md §4, §5; mockups b, c and e), Put Back an Earlier Ledger…
// (§6.4), the window's bottom line (Remove from List's Undo) and the context menus' new items. The work is DataModel's
// and AppModel's; mouse first: every action a button, a checkbox or a pop-up.

/// The red sign and words of something that went wrong, as the status line shows them (§28: the sign red, the words in
/// the label colour).
struct Trouble: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(Color(nsColor: Palette.danger))
            Text(text).foregroundStyle(Ink.label).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }
}

/// The step of the work running, with Cancel.
private struct Working: View {
    @ObservedObject var data: DataModel
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(data.step ?? title).foregroundStyle(Ink.label2).lineLimit(2)
            Spacer(minLength: 8)
            Button("Cancel") { data.cancelWork() }.disabled(!data.cancellable)
        }
    }
}

/// A sheet's list, as tall as it is up to `maxHeight`, then scrolling; once it goes on below its edge its scroll bar is
/// shown before any scroll (BACKLOG O28, as the Finish sheet's drafts), so a group cut at the edge, or a heading with
/// its rows below, does not read as the end.
private struct SheetList<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: Content
    @State private var height: CGFloat = 0

    var body: some View {
        ScrollView {
            content
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height = $0 }
                .background { if height > maxHeight { AlwaysShownScroller() } }
        }
        .scrollIndicators(.visible)
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Export Papers

/// Export Papers (mockup b): All students › each student › their papers, a checkbox each (a dash when only some are
/// ticked), each paper's state; what goes in, in one sentence, and one total; Export… (the save panel). Then the steps
/// with Cancel, and "Saved and checked" with Show in Finder.
struct ExportSheet: View {
    @ObservedObject var data: DataModel
    @ObservedObject var model: AppModel
    @ObservedObject var hub: HubModel

    init(model: AppModel) {
        self.model = model
        data = model.data
        hub = model.hubModel
    }

    var body: some View {
        if let e = data.export {
            VStack(alignment: .leading, spacing: 14) {
                Text("Export Papers").font(.title3.bold())
                switch e.phase {
                case .choosing: chooser(e)
                case .working:
                    Working(data: data, title: "Writing…")
                case .done(let words, let url):
                    // saved and checked; without a file, a cancel's quiet line
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if url != nil { Image(systemName: "checkmark.circle").foregroundStyle(Ink.secondary) }
                        Text(words).foregroundStyle(url == nil ? Ink.secondary : Ink.label).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Spacer()
                        if let url { Button("Show in Finder") { data.reveal(url, origin: e.origin) } }
                        Button("Done") { data.closeExport() }.keyboardShortcut(.defaultAction)
                    }
                case .failed(let m):
                    Trouble(text: m)
                    HStack {
                        Spacer()
                        Button("Done") { data.closeExport() }.keyboardShortcut(.defaultAction)
                    }
                }
            }
            .padding(20)
            .frame(width: 520)
            .interactiveDismissDisabled()
        }
    }

    @ViewBuilder
    private func chooser(_ e: ExportChoice) -> some View {
        SheetList(maxHeight: 320) {
            VStack(alignment: .leading, spacing: 7) {
                Toggle(sources: ticks(e.exportable), isOn: \.self) {
                    HStack(spacing: 6) {
                        Text("All students").fontWeight(.semibold)
                        Text(count(e.students.count, "student") + " · " + count(e.students.flatMap(\.papers).count, "paper"))
                            .foregroundStyle(Ink.secondary)
                    }
                }
                .disabled(e.exportable.isEmpty)
                ForEach(e.students) { s in
                    Toggle(sources: ticks(s.papers), isOn: \.self) {
                        HStack(spacing: 6) {
                            Text(s.name)
                            Text(count(s.papers.count, "paper")).foregroundStyle(Ink.secondary)
                        }
                    }
                    .disabled(s.papers.allSatisfy { $0.gone != nil })
                    .padding(.leading, 20)
                    ForEach(s.papers) { p in
                        Toggle(isOn: tick(p)) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.ref.title.isEmpty ? (p.ref.path as NSString).lastPathComponent : p.ref.title).lineLimit(1)
                                Text(line(p)).font(.system(size: 11)).foregroundStyle(Ink.secondary).lineLimit(1)
                            }
                        }
                        .disabled(p.gone != nil)
                        .help(p.ref.path)
                        .padding(.leading, 40)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        Text("Each review folder goes in whole, every round and its history, with your writing tags and these papers’ unsent drafts"
             + (e.everything ? ", and your settings." : "."))
            .font(.callout).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
        HStack {
            Text(e.summary).monospacedDigit().foregroundStyle(Ink.label2)
            Spacer()
            Button("Cancel", role: .cancel) { data.closeExport() }.keyboardShortcut(.cancelAction)
            Button("Export…") { data.chooseExportFile() }
                .keyboardShortcut(.defaultAction)
                .disabled(e.chosen.isEmpty || data.working)
        }
    }

    /// "Round 2 open · 14 comments" ("Round 1 finished", "Round 3 with Mei"), from the papers list's summaries and the
    /// hierarchy's numbers.
    private func line(_ p: ExportChoice.Paper) -> String {
        if let g = p.gone { return g }
        let s = model.summaries[p.ref.path], comments = hub.data[p.ref.path]?.threads?.comments
        guard let s else { return comments.map { count($0, "comment") } ?? "" }
        let student = OverviewText.firstName(p.ref.student)
        let closed = model.status(of: p.ref)?.isFinished == true ? "finished" : student.isEmpty ? "with the student" : "with " + student
        let round = s.round.map { "Round \($0) " + (s.closed ? closed : "open") } ?? "No rounds yet"
        return [round, comments.map { count($0, "comment") }].compactMap { $0 }.joined(separator: " · ")
    }

    private func tick(_ p: ExportChoice.Paper) -> Binding<Bool> {
        Binding(get: { data.export?.ticked.contains(p.id) ?? false },
                set: { on in if on { data.export?.ticked.insert(p.id) } else { data.export?.ticked.remove(p.id) } })
    }

    /// The papers' checkboxes that can be ticked; none (every folder missing): one off, so the student's box shows empty,
    /// not a ticked box with nothing ticked under it.
    private func ticks(_ papers: [ExportChoice.Paper]) -> [Binding<Bool>] {
        let t = papers.filter { $0.gone == nil }.map(tick)
        return t.isEmpty ? [.constant(false)] : t
    }
}

// MARK: Import

/// Import… (mockups c and e): while the engine reads the file, its step with Cancel; then what it holds, in four
/// groups, each paper with a checkbox or a pop-up and where it goes, "Put them in", the tags and drafts that come
/// with it and the settings' checkbox; then what was done.
struct ImportSheet: View {
    @ObservedObject var data: DataModel

    var body: some View {
        if let st = data.importing {
            VStack(alignment: .leading, spacing: 14) {
                Text("Import “\(st.source.lastPathComponent)”").font(.title3.bold()).lineLimit(1).truncationMode(.middle)
                if let r = st.report {
                    report(r, st)
                } else if let plan = st.plan {
                    preview(plan, error: st.error)
                } else if st.error != nil || st.note != nil {
                    // an error, or the check cancelled (a quiet line)
                    if let e = st.error { Trouble(text: e) } else { Text(st.note ?? "").foregroundStyle(Ink.secondary) }
                    HStack {
                        Spacer()
                        Button("Done") { data.closeImport() }.keyboardShortcut(.defaultAction)
                    }
                } else {
                    Text("Reading it without unpacking anything, and checking every file.").foregroundStyle(Ink.secondary)
                    Working(data: data, title: "Checking…")
                }
            }
            .padding(20)
            .frame(width: 580)
            .interactiveDismissDisabled()
        }
    }

    @ViewBuilder
    private func preview(_ plan: ImportPlan, error: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            // a damaged file's sign inline, so the line wraps as one text
            (plan.check.intact ? Text("") : Text(Image(systemName: "exclamationmark.circle")).foregroundColor(Color(nsColor: Palette.danger)) + Text(" "))
                + Text(plan.header).foregroundColor(Ink.label2)
            if plan.check.fromDev {
                Text("Test data: none of it replaces yours unless you choose.").font(.system(size: 11)).foregroundStyle(Ink.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        SheetList(maxHeight: 330) {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(ImportPlan.Group.allCases, id: \.self) { g in
                    let items = plan.items.filter { $0.group == g }
                    if !items.isEmpty {
                        VStack(alignment: .leading, spacing: 9) {
                            Text(g.title).font(.headline)
                            ForEach(items) { it in row(it, plan) }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if plan.needsDestination {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Put them in")
                    Text(plan.destination.map(DataFiles.shown) ?? "Choose a folder for the papers")
                        .font(.system(size: 11))
                        .foregroundStyle(plan.destination == nil ? Ink.label : Ink.secondary)  // vermilion is only "your move"
                        .lineLimit(1).truncationMode(.middle).help(plan.destination?.path ?? "")
                }
                Spacer(minLength: 8)
                Button("Choose…") { data.chooseImportFolder() }.fixedSize()
            }
        }
        let extras = [plan.tagWords, plan.draftWords].compactMap { $0 }
        if !extras.isEmpty { Text(extras.joined(separator: " ")).foregroundStyle(Ink.label2).fixedSize(horizontal: false, vertical: true) }
        if plan.check.settingsJSON != nil {
            Toggle("Also use this file’s settings", isOn: Binding(get: { data.importing?.plan?.useSettings ?? false },
                                                                 set: { data.importing?.plan?.useSettings = $0 }))
                .toggleStyle(.checkbox)
        }
        if plan.mayReplace {
            Text("Use This Copy keeps yours in “Replaced by Import” beside it.").font(.callout).foregroundStyle(Ink.secondary)
        }
        if let error { Trouble(text: error) }
        if data.working {
            Working(data: data, title: "Importing…")
        } else {
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { data.closeImport() }.keyboardShortcut(.cancelAction)
                Button(plan.actionTitle) { data.performImport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!plan.canImport)
            }
        }
    }

    private func row(_ it: ImportPlan.Item, _ plan: ImportPlan) -> some View {
        let label = VStack(alignment: .leading, spacing: 2) {
            PaperRowText(text: it.name)
            ForEach(Array(plan.detail(it).enumerated()), id: \.offset) { _, line in
                if let path = line.path {
                    // a place: one line, the home folder as ~, cut in the middle, the whole path in its help tag
                    Text(line.text).font(.system(size: 11)).foregroundStyle(Ink.secondary)
                        .lineLimit(1).truncationMode(.middle).help(path)
                } else {
                    Text(line.text).font(.system(size: 11)).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            if it.checkbox {
                Toggle(isOn: Binding(get: { choice(it).acts },
                                     set: { set(it, $0 ? (it.group == .putBack ? .putBack : .add) : .skip) })) { label }
                    .toggleStyle(.checkbox)
            } else {
                // in line with the checkbox rows' titles
                label.foregroundStyle(it.group == .cannot ? Ink.secondary : Ink.label).padding(.leading, 20)
            }
            Spacer(minLength: 8)
            if !it.choices.isEmpty {
                Picker("", selection: Binding(get: { choice(it) }, set: { set(it, $0) })) {
                    ForEach(it.choices, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("What to do with \(it.paper.title ?? "this paper")")
            }
        }
        .help(it.paper.inPlace ? it.paper.folder : (it.paper.listed ?? ""))
    }

    private func choice(_ it: ImportPlan.Item) -> ImportPlan.Choice {
        data.importing?.plan?.items.first { $0.id == it.id }?.choice ?? it.choice
    }

    private func set(_ it: ImportPlan.Item, _ c: ImportPlan.Choice) {
        if let i = data.importing?.plan?.items.firstIndex(where: { $0.id == it.id }) { data.importing?.plan?.items[i].choice = c }
    }

    @ViewBuilder
    private func report(_ r: ImportReport, _ st: ImportSheetState) -> some View {
        Text(r.title + (r.stopped == nil ? "" : ".")).font(.headline)
        // as the preview: a heading for each kind of thing done (a folder said once, on its line), a row for each paper
        SheetList(maxHeight: 330) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(r.groups.enumerated()), id: \.offset) { _, g in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(g.title + (g.place.map { " " + DataFiles.shown(URL(fileURLWithPath: $0)) } ?? ""))
                            .fontWeight(.medium).foregroundStyle(Ink.label2).lineLimit(g.place == nil ? nil : 1).truncationMode(.middle)
                            .fixedSize(horizontal: false, vertical: g.place == nil)
                            .help(g.place ?? "")
                        ForEach(Array(g.papers.enumerated()), id: \.offset) { _, row in
                            PaperRowText(text: row).foregroundStyle(Ink.label).padding(.leading, 20)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(r.lines.enumerated()), id: \.offset) { _, line in
                Text(line).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if let s = r.stopped {
                if r.cancelled { Text(s).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true) } else { Trouble(text: s) }
            }
        }
        HStack {
            Spacer()
            if let u = r.reveal { Button("Show in Finder") { data.reveal(u, origin: st.origin) } }
            Button("Done") { data.closeImport() }.keyboardShortcut(.defaultAction)
        }
    }
}

/// A paper's row in the import preview and report (`TransferText.row`), on one line: a long title is cut, the student
/// after it kept whole.
private struct PaperRowText: View {
    let text: String

    var body: some View {
        if let r = text.range(of: " · ", options: .backwards) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(text[..<r.lowerBound]).lineLimit(1).truncationMode(.tail)
                Text(text[r.lowerBound...]).lineLimit(1).fixedSize()
            }
        } else {
            Text(text).lineLimit(1).truncationMode(.tail)
        }
    }
}

// MARK: Put Back an Earlier Ledger

/// Put Back an Earlier Ledger… (DATA.md §6.4): the paper's saved versions, newest first ("Oct 21 at 09:12 ·
/// 2 rounds · 14 comments · a round finished"), one chosen; Put Back makes it the newest, keeping the one it replaces.
struct LedgerHistorySheet: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let h = model.ledgerHistory {
            VStack(alignment: .leading, spacing: 12) {
                Text("Put Back an Earlier Ledger").font(.title3.bold())
                Text("“\(TransferText.short(h.title))”, newest first. Put Back keeps the one it replaces.")
                    .foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
                if let vs = h.versions {
                    if vs.isEmpty {
                        Text("No earlier versions are saved yet.").foregroundStyle(Ink.secondary)
                    } else {
                        List(selection: Binding(get: { model.ledgerHistory?.selected }, set: { model.ledgerHistory?.selected = $0 })) {
                            ForEach(vs) { v in Text(v.words).monospacedDigit().tag(v.name) }
                        }
                        .frame(height: 230)
                    }
                } else if h.error == nil {
                    ProgressView().controlSize(.small)
                }
                if let e = h.error { Trouble(text: e) }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { model.ledgerHistory = nil }.keyboardShortcut(.cancelAction)
                    Button("Put Back") { model.putBackLedger() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(h.selected == nil || h.working)
                }
            }
            .padding(20)
            .frame(width: 520)
        }
    }
}

// MARK: The window's bottom line

/// The line at the bottom of the window (DATA.md §6.4): "Removed “Kelp drift” from the list. Its folder stays where
/// it is." with Undo, or a context menu's result with Show in Finder; × closes it, it goes by itself after 10 s
/// (not while the pointer is on it).
struct WindowNoticeView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let n = model.notice {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if n.failed {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(Color(nsColor: Palette.danger))
                }
                Text(n.text).foregroundStyle(Ink.label).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if let a = n.action { Button(a) { model.noticeClicked() }.fixedSize() }
                if let b = n.second { Button(b) { model.noticeClicked(second: true) }.fixedSize() }
                Button { model.notice = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).foregroundStyle(Ink.secondary).help("Dismiss").accessibilityLabel("Dismiss")
            }
            .font(.system(size: 12.5))
            .controlSize(.small)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: 620)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            .onHover { model.holdNotice($0) }
            .padding(.bottom, 18)
            .transition(.opacity)
        }
    }
}

// MARK: Context menus

/// Export Comments ▸ CSV… / JSON… (a paper's or a student's context menu).
struct CommentExportMenu: View {
    let model: AppModel
    let papers: [PaperRef]
    let label: String
    let student: Bool

    var body: some View {
        Menu("Export Comments") {
            ForEach(CommentExport.Format.allCases, id: \.self) { f in
                Button("\(f.title)…") { model.data.exportComments(papers, label: label, student: student, format: f) }
            }
        }
    }
}

/// A student's context menu in the sidebar, and on their block of All Students and their page's header: their page and
/// Rename (not Unassigned's), Show / Hide Papers, Show in Finder
/// (their papers' folders that are there; DATA.md §0.2), Export…, Export Comments ▸, Remove from List (their papers; the
/// folders stay, with Undo).
struct StudentMenu: View {
    let model: AppModel
    let group: StudentGroup

    var body: some View {
        if !group.unassigned {
            Button("Open \(group.name)’s Page") { model.openHub(.student(group.key)) }
            Button("Rename Student…") { model.renamingStudent = group.key }
            Divider()
        }
        Button(model.foldedStudents.contains(group.key) ? "Show Papers" : "Hide Papers") { model.toggleStudentFold(group.key) }
        Divider()
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(group.papers.map { URL(fileURLWithPath: $0.path) }
                .filter { FileManager.default.fileExists(atPath: $0.path) })
        }
        .disabled(group.papers.allSatisfy { model.missingPapers.contains($0.path) })
        Button("Export…") { model.data.openExport(origin: .window, only: group.papers.map(\.path)) }
        CommentExportMenu(model: model, papers: group.papers, label: group.name, student: true)
        Divider()
        Button("Remove from List") { model.removePapers(group.papers.map(\.path), student: group.unassigned ? nil : group.name) }
    }
}
