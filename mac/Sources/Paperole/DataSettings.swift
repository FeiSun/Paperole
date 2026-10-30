import AppKit
import SwiftUI

/// Settings › Data & Storage (UX.md §28; design/data/DATA.md §7 as its §0 cuts it): places and totals only, no list of
/// students or papers (each paper's and student's actions are in their context menus): Backups (one switch, off by
/// default; the folder, the last backup and Back Up Now only while it is on), Export… and Import…, where new
/// review folders go (and "Replaced by Import" while there are any), the writing tags' file, and Paperole's own
/// files. Each action is a button (mouse first); the work runs off the main thread, its step, result or error in the
/// status line at the bottom (`DataModel.status`).
struct DataSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var data: DataModel
    @ObservedObject var tags: TagModel
    @ObservedObject var backups: BackupModel
    /// The unsent drafts of listed papers, counted when the tab appears and after each job (the files are read: not at
    /// every change of the model, which J/K in Review makes).
    @State private var drafts = 0

    init(model: AppModel) {
        self.model = model
        data = model.data
        tags = model.tags
        backups = model.backups
    }

    static let height: CGFloat = 560

    var body: some View {
        VStack(spacing: 0) {
            Form {
                backupsSection
                transfer
                folders
                writingTags
                ownFiles
            }
            .formStyle(.grouped)
            if let s = data.status {
                Divider()
                DataStatusLine(data: data, status: s)
            }
        }
        .frame(width: SettingsView.width, height: Self.height)
        .onAppear {
            data.countThumbnails()
            data.countReplaced()
            drafts = Self.listedDrafts(model)
            backups.noteSameDisk()
        }
        .onChange(of: data.status) {
            drafts = Self.listedDrafts(model)
            data.countReplaced()
        }
        .sheet(item: Binding(get: { data.export?.origin == .settings ? data.export : nil },
                             set: { if $0 == nil { data.closeExport() } })) { _ in ExportSheet(model: model) }
        .sheet(item: Binding(get: { data.importing?.origin == .settings ? data.importing : nil },
                             set: { if $0 == nil { data.closeImport() } })) { _ in ImportSheet(data: data) }
    }

    // MARK: Sections

    /// Backups (DATA.md §0.1, §6.2): one switch, off by default; turning it on asks for the folder (Cancel leaves it
    /// off). Only while it is on: the folder with Choose… and Show in Finder (and the note when it shares a disk with
    /// the review folders), the last backup or why the backups fail (§28's error style, never amber), Back Up Now, and
    /// what is kept.
    private var backupsSection: some View {
        Section {
            // the panel opens after the click, the switch still off: Cancel leaves it so
            Toggle(isOn: Binding(get: { backups.state.on },
                                 set: { on in if on { DispatchQueue.main.async { backups.turnOn() } } else { backups.turnOff() } })) {
                Text("Back up automatically")
                // what the switch does, on or off, as every switch in Settings says it
                Text("Each day you work and after each Finish Round, when something has changed.").foregroundStyle(Ink.secondary)
            }
            .toggleStyle(.switch)
            if backups.state.on, let folder = backups.state.folder {
                LabeledContent {
                    HStack(spacing: 6) {
                        Button("Show in Finder") { data.reveal(URL(fileURLWithPath: folder)) }.disabled(backups.placeProblem() != nil)
                        Button("Choose…") { if let u = backups.chooseFolder() { backups.use(u) } }.disabled(backups.running)
                    }
                } label: {
                    Text("Backup folder")
                    Text(DataFiles.shown(URL(fileURLWithPath: folder))).foregroundStyle(Ink.secondary).lineLimit(1)
                        .truncationMode(.middle).help(folder)
                    if backups.sameDisk {
                        // a third line of a label is set smaller than the second: the captions' size, as the path's
                        Text("On the same disk as your review folders: this guards against mistakes, not against losing the disk.")
                            .font(.subheadline).foregroundStyle(Ink.secondary)
                    }
                }
                LabeledContent {
                    Button("Back Up Now") { backups.backUp(manual: true) }.disabled(backups.running || data.working)
                } label: {
                    lastBackup
                    // the papers a partial backup left out on a line of their own, so the last backup's line never wraps
                    Text([backups.step == nil && backups.state.failure == nil ? backups.state.last?.leftWords : nil,
                          "Keeps 7 daily, 4 weekly and 6 monthly backups, within 5 GB, and always the last copy of each paper."]
                        .compactMap { $0 }.joined(separator: " "))
                        .foregroundStyle(Ink.secondary)
                }
            }
        } header: {
            Text("Backups")
        }
    }

    /// "Last backup: today at 16:40 · 3 papers · 2.3 MB · checked", the step while one is made, or why they fail.
    @ViewBuilder private var lastBackup: some View {
        let now = Date()
        if let step = backups.step {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Backing up: " + step).foregroundStyle(Ink.label2)
            }
        } else if let f = backups.state.failure {
            Trouble(text: f.words(now: now))
        } else if let last = backups.state.last {
            Text("Last backup: " + last.words(now: now))
        } else {
            Text("No backup yet.")
        }
    }

    private var transfer: some View {
        Section {
            LabeledContent {
                Button("Export…") { data.openExport(origin: .settings) }
            } label: {
                Text("Export")
                Text("Everything, chosen students or chosen papers, in one file you can import later.").foregroundStyle(Ink.secondary)
            }
            LabeledContent {
                Button("Import…") { data.chooseImport(origin: .settings) }
            } label: {
                Text("Import")
                Text("A Paperole file, a review folder, or a folder to look in. Shows what it holds first and never overwrites.")
                    .foregroundStyle(Ink.secondary)
            }
        } header: {
            Text("Export and import")
        }
        .disabled(data.working)
    }

    private var folders: some View {
        Section {
            LabeledContent {
                HStack(spacing: 6) {
                    if data.reviewRoot != nil {
                        Button { data.reviewRoot = nil } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(Ink.secondary)
                            .help("Use the default folder, \(DataFiles.shown(DataPlaces.defaultRoot))")
                            .accessibilityLabel("Use the default folder")
                    }
                    if let r = data.rootShown { Button("Show in Finder") { data.reveal(r) } }
                    Button("Choose…") { data.chooseReviewRoot() }
                }
            } label: {
                Text("New review folders")
                Text(rootWords).foregroundStyle(Ink.secondary).lineLimit(1).truncationMode(.middle).help(data.rootShown?.path ?? "")
            }
            if let r = data.replaced, r.copies > 0 {
                LabeledContent {
                    HStack(spacing: 6) {
                        Text((r.copies == 1 ? "1 copy" : "\(r.copies) copies") + " · " + DataFiles.size(r.bytes))
                            .monospacedDigit().foregroundStyle(Ink.secondary)
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(r.folders) }
                    }
                } label: {
                    Text("Replaced by Import")
                    Text("Your copies that an import replaced, beside each paper’s folder. \(AppVariant.current.name) never deletes them.")
                        .foregroundStyle(Ink.secondary)
                }
            }
        } header: {
            Text("Review folders")
            Text("Right-click a paper or a student in the sidebar to show it in Finder or export it.")
                .foregroundStyle(Ink.secondary)
        }
        .disabled(data.working)
    }

    private var writingTags: some View {
        Section {
            LabeledContent(Self.count(tags.catalog.tags.count, "tag")) {
                HStack(spacing: 6) {
                    Button("Import…") { data.importTags() }
                        .help("Add the tags of a Paperole tags file that you don’t have; yours stay as they are")
                    Button("Export…") { data.exportTags() }.help("Save your writing tags as a file")
                    Button("Show in Finder") { data.reveal(tags.store.url) }
                }
            }
            .help(tags.store.url.path)
        } header: {
            Text("Writing tags")
        }
        .disabled(data.working)
    }

    private var ownFiles: some View {
        Section {
            own("Papers list", PaperStore.fileURL, Self.count(model.papers.count, "paper"))
            own("Unsent drafts", model.draftStore.directory, Self.count(drafts, "draft"))
            LabeledContent("Page thumbnails") {
                HStack(spacing: 6) {
                    Text(data.thumbnailBytes.map(DataFiles.size) ?? "…").monospacedDigit().foregroundStyle(Ink.secondary)
                    Button("Clear") { data.clearCaches() }
                        .help("Delete every page thumbnail; they are drawn again as pages are shown")
                }
            }
            .help(model.thumbnails.root.path)
        } header: {
            Text("\(AppVariant.current.name)’s own files")
        } footer: {
            Text("All on this Mac; nothing is uploaded.").font(.system(size: 11)).foregroundStyle(Ink.secondary)
        }
        .disabled(data.working)
    }

    // MARK: Rows

    private var rootWords: String {
        guard let r = data.rootShown else { return "Chosen each time, in New Paper…" }
        return DataFiles.shown(r) + (data.reviewRoot != nil && data.root == nil ? " (not there now)" : "")
    }

    /// A file or folder of the app's own: its count and Show in Finder, its path in the help tag.
    private func own(_ title: String, _ url: URL, _ detail: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Text(detail).monospacedDigit().foregroundStyle(Ink.secondary)
                Button("Show in Finder") { data.reveal(url) }
            }
        }
        .help(url.path)
    }

    static func count(_ n: Int, _ word: String) -> String { DataModel.count(n, word) }

    /// The unsent drafts of the listed papers: one left under a path no paper is listed at any more (a put back to a
    /// new place, Use This Copy's copy kept aside) can be neither sent nor discarded, so it is not counted.
    static func listedDrafts(_ model: AppModel) -> Int {
        let listed = Set(model.papers.map(\.path))
        return model.draftStore.all().filter { listed.contains($0.paper) }.count
    }
}

/// The tab's status line: the work's step with Cancel, or its result (with Show in Finder) or error.
struct DataStatusLine: View {
    @ObservedObject var data: DataModel
    let status: DataModel.Status

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            switch status {
            case .working(let s, let f):
                Group {
                    if let f { ProgressView(value: f).frame(width: 72) } else { ProgressView().controlSize(.small) }
                }
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                Text(s).foregroundStyle(Ink.label2)
                Spacer(minLength: 8)
                if data.cancellable { Button("Cancel") { data.cancelWork() } }
            case .done(let s, let url):
                Image(systemName: "checkmark.circle").foregroundStyle(Ink.secondary)
                Text(s).foregroundStyle(Ink.label2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let url { Button("Show in Finder") { data.reveal(url) } }
                close
            case .failed(let s):
                Image(systemName: "exclamationmark.circle").foregroundStyle(Color(nsColor: Palette.danger))
                Text(s).foregroundStyle(Ink.label).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Spacer(minLength: 8)
                close
            }
        }
        .font(.system(size: 12))
        .controlSize(.small)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
    }

    private var close: some View {
        Button { data.clearStatus() } label: { Image(systemName: "xmark") }
            .buttonStyle(.borderless).foregroundStyle(Ink.secondary).help("Dismiss").accessibilityLabel("Dismiss")
    }
}

