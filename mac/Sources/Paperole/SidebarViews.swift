import AppKit
import SwiftUI

/// The sidebar's rows in the order the list shows them (UX.md §22; FEATURES OV-7): All Students, Your Move, then the
/// students and their papers (a folded student without them), or in Review the open paper alone under its student
/// with the Contents after it. The debug hooks and the Contents' follower find a row's place in the list's table here.
enum SidebarRow: Equatable {
    case allStudents, yourMove
    case header(String)
    case student(String)
    case paper(String)
    case contentsHeader
    case contents(Int)
}

enum SidebarLayout {
    /// `review`: the open paper's path while Review shows it (the tree folds to it); `contents`: its Contents rows.
    static func rows(groups: [StudentGroup], folded: Set<String>, review: String?, contents: Int) -> [SidebarRow] {
        var out: [SidebarRow] = [.allStudents, .yourMove]
        if let path = review {
            let g = groups.first { $0.papers.contains { $0.path == path } }
            out += [.header(g?.name ?? "Unassigned"), .paper(path)]
            if contents > 0 { out += [.contentsHeader] + (0..<contents).map { .contents($0) } }
            return out
        }
        out.append(.header("Students"))
        for g in groups {
            out.append(.student(g.key))
            if !folded.contains(g.key) { out += g.papers.map { .paper($0.path) } }
        }
        return out
    }
}

/// The window's one sidebar (POLISH §3 row 2, §6; OVERVIEW-v2 §3.1–3.2; FEATURES OV-7): "Jump to…" at the top, All
/// Students, Your Move with the count of papers that wait on you, then Students, each a row that opens the student's
/// page with its papers under it (folded with its chevron, remembered); papers without a student under Unassigned. In
/// Review the tree folds to the open paper under its student's name (a menu there lists the student's other papers),
/// with the paper's Contents after it.
struct Sidebar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let _ = { BodyCount.sidebar += 1 }()
        let groups = model.studentGroups
        let review = model.reviewPaper
        let waiting = model.yourMove.count  // once a redraw (the code audit: it was worked out three times)
        ScrollViewReader { proxy in
            // a click on a paper shows its overview, a double click or Return Review (the primary action below; UX.md
            // §21); a student, the student's page
            List(selection: Binding(get: { model.sidebarSelection },
                                    set: { model.sidebarSelected($0, secondClick: AppModel.isSecondClick(NSApp.currentEvent)) })) {
                HubRow(title: "All Students", icon: "person.2")
                    .tag(SidebarItem.allStudents)
                // amber only when something waits on the advisor (amber means "your move")
                HubRow(title: "Your Move", icon: "circle", amber: waiting > 0, count: waiting)
                    .help(HubText.waits(waiting))
                    .tag(SidebarItem.yourMove)
                if let path = review, let p = model.papers.first(where: { $0.path == path }) {  // listed: `reviewPaper`
                    let g = groups.first { $0.papers.contains { $0.path == path } }
                    Section {
                        paperRow(p, indent: false)
                            .listRowBackground(OpenPaperFill())  // not the list's selection: a click on it shows its overview
                    } header: {
                        ReviewStudentHeader(model: model, group: g, paper: path)
                    }
                    ContentsSection(contents: model.reading.contents, current: model.reading.current, model: model)
                } else {
                    Section {
                        ForEach(groups) { g in
                            StudentRow(group: g, folded: model.foldedStudents.contains(g.key),
                                       toggle: { model.toggleStudentFold(g.key) })
                                .tag(SidebarItem.student(g.key))
                                .selectionDisabled(g.unassigned)
                                .contextMenu { StudentMenu(model: model, group: g) }
                            if !model.foldedStudents.contains(g.key) {
                                ForEach(g.papers) { p in paperRow(p, indent: true) }
                            }
                        }
                    } header: {
                        Text("Students").modifier(SidebarHeader())
                    }
                }
            }
            .listStyle(.sidebar)
            // the rows keep their own menus (an empty one here leaves them theirs); a single click is the list's selection
            .contextMenu(forSelectionType: SidebarItem.self, menu: { _ in }, primaryAction: { model.sidebarOpened($0) })
            .background(SectionFollower(current: model.reading.current, proxy: proxy, row: { b in
                model.reading.contents.rows.firstIndex { $0.block == b }.flatMap { i in
                    model.sidebarRows.firstIndex(of: .contents(i))
                }
            }))
        }
        .safeAreaInset(edge: .top, spacing: 0) { JumpField(model: model) }
        .safeAreaInset(edge: .bottom) {
            // in a narrow sidebar (the window at its minimum width) Add Existing… is an icon, so no title wraps
            ViewThatFits(in: .horizontal) {
                footer(compact: false)
                footer(compact: true)
            }
            .buttonStyle(.borderless)
            .padding(10)
        }
    }

    @ViewBuilder
    private func paperRow(_ p: PaperRef, indent: Bool) -> some View {
        let status = model.status(of: p)
        let gone = model.missingPapers.contains(p.path)
        let drive = gone ? DataPlaces.unplugged(p.path) : nil
        let damage = gone ? nil : model.damagedPapers[p.path]
        SidebarPaperRow(title: p.title.isEmpty ? (p.path as NSString).lastPathComponent : p.title, status: status,
                        detail: gone ? (drive.map { "Its folder is on “\($0)”, which is not connected." }
                                        ?? "Its folder is missing: \(DataFiles.shown(URL(fileURLWithPath: p.path)))")
                            : damage.map { "Damaged: " + $0 } ?? model.statusText(p),
                        open: p.path == model.selectedPath, indent: indent,
                        missing: gone ? (drive == nil ? "missing" : "not connected") : damage == nil ? nil : "damaged")
            .tag(SidebarItem.paper(p.path))
            .contextMenu { PaperMenu(model: model, paper: p, status: status) }
    }

    private func footer(compact: Bool) -> some View {
        HStack {
            Button { model.showNewPaper = true } label: { Label("New Paper…", systemImage: "plus") }
            Spacer(minLength: 8)
            if compact {
                Button { model.addExistingPaper() } label: { Image(systemName: "folder.badge.plus") }
                    .help("Add Existing Paper…")
                    .accessibilityLabel("Add Existing Paper…")
            } else {
                Button("Add Existing…") { model.addExistingPaper() }
            }
        }
    }
}

/// A sheet shown for one paper or student.
struct SheetID: Identifiable {
    var id: String
}

/// A paper's context menu, in the sidebar and on the hierarchy's pages: Review, Edit Paper… (its title and student,
/// `edit_paper`), Mark as Finished while it is with the student (FEATURES OV-7), Finder, Export… and Export Comments ▸
/// (DATA.md §0.2, §4), Put Back an Earlier Ledger… (§6.4), Restore from Last Backup… (only while backups are on, for a
/// paper missing or damaged that a backup holds), Remove from List (with Undo). A paper whose folder is not there can
/// only be shown in Finder (its place), restored or removed.
struct PaperMenu: View {
    let model: AppModel
    let paper: PaperRef
    let status: PaperStatus?

    var body: some View {
        let gone = model.missingPapers.contains(paper.path)
        Button("Open in Review") { model.openPaper(paper.path, level: .review) }.disabled(gone)
        if let a = model.resumable(paper.path) {  // its latest round, finished (UX.md §31)
            Button("Resume Round \(a.round)") { model.askResume(paper.path) }.disabled(gone)
        }
        Divider()
        Button(paper.student.isEmpty ? "Assign to a Student…" : "Edit Paper…") { model.editingPaper = paper.path }.disabled(gone)
        if status == .waiting {
            Button("Mark as Finished") { model.setFinished(paper.path, true) }
        } else if status?.isFinished == true {
            Button("Mark as Not Finished") { model.setFinished(paper.path, false) }
        }
        Divider()
        // a folder not there is said on the window's line, where the advisor is looking (A5b-07), not in Settings
        Button("Show in Finder") { model.data.reveal(URL(fileURLWithPath: paper.path), origin: .window) }
        Button("Export…") { model.data.openExport(origin: .window, only: [paper.path]) }.disabled(gone)
        CommentExportMenu(model: model, papers: [paper], label: paper.title, student: false).disabled(gone)
        // also for a folder whose ledger.json is gone (it reads as missing): its history is in the folder
        Button("Put Back an Earlier Ledger…") { model.openLedgerHistory(paper.path) }
            .disabled(gone && !FileManager.default.fileExists(atPath: paper.path))
        if model.backups.restorable(paper) {
            Button("Restore from Last Backup…") { model.data.restoreFromBackup(paper) }
        }
        Divider()
        Button("Remove from List") { model.removePaper(paper.path) }
    }
}

/// All Students and Your Move: an icon, the name (13 Medium), and Your Move's count of papers that wait on you in the
/// system's grey count badge (the amber ○ is its icon; the count is the same number All Students and Your Move say).
struct HubRow: View {
    let title: String
    let icon: String
    var amber = false
    var count: Int?
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: amber ? 11 : 12, weight: amber ? .bold : .medium))
                .foregroundStyle(amber ? Color(nsColor: Palette.toCheck) : Ink.secondary)
                .frame(width: 18)
            Text(title).font(.system(size: 13, weight: .medium))
                .foregroundStyle(prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(Ink.label))
            Spacer(minLength: 4)
            if let n = count, n > 0 { CountBadge(n: n) }
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
    }
}

/// The system sidebars' count: grey digits on the chips' quiet fill.
struct CountBadge: View {
    let n: Int

    var body: some View {
        Text("\(n)")
            .font(.system(size: 11, weight: .semibold)).monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(minWidth: 20, minHeight: 16)
            .background(Capsule().fill(Color(nsColor: Palette.chipFill)))
    }
}

/// A student: the fold's chevron, a person, the name (13 Medium). Its click opens the student's page; the chevron
/// shows or hides the papers under it. Unassigned has no page.
struct StudentRow: View {
    let group: StudentGroup
    let folded: Bool
    let toggle: () -> Void
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        HStack(spacing: 5) {
            Button(action: toggle) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9.5, weight: .bold))
                    .rotationEffect(.degrees(folded ? 0 : 90))
                    .foregroundStyle(Ink.secondary)  // a control: 3:1 or more (the UI audit: the placeholder grey, 2.2:1)
                    .frame(width: 14, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(folded ? "Show \(group.name)’s papers" : "Hide \(group.name)’s papers")
            .accessibilityLabel(folded ? "Show papers" : "Hide papers")
            Image(systemName: group.unassigned ? "questionmark.circle" : "person")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Ink.secondary)
                .frame(width: 16)
            Text(group.name).font(.system(size: 13, weight: .medium))
                .foregroundStyle(group.unassigned ? AnyShapeStyle(Ink.secondary)
                                 : prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(Ink.label))
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.leading, -4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(group.name + ", " + count(group.papers.count, "paper"))
    }
}

/// A paper under its student (the mockup's sidebar): its title on one line (13), and at the right what it waits for:
/// the count of comments and edits to check in the grey badge (not on the open paper, whose counts the window's
/// subtitle and the panel's tabs say), or a sign: ready to finish ✓○, with the student ⌛, finished (the title grey),
/// build failed (the octagon, the only red), the first draft •, paragraphs to read ▍. The help tag says it in words.
struct SidebarPaperRow: View {
    let title: String
    let status: PaperStatus?
    let detail: String
    var open = false
    var indent = true
    /// "missing" or "damaged" (in the danger red: its folder is gone, or the quiet check found damage) or "not connected"
    /// (its drive's; grey), instead of the sign.
    var missing: String? = nil
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let _ = { BodyCount.paper += 1 }()
        HStack(spacing: 6) {
            Text(title).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                .foregroundStyle(prominence == .increased ? AnyShapeStyle(.primary)
                                 : status?.isFinished == true ? AnyShapeStyle(Ink.secondary) : AnyShapeStyle(Ink.label))
            Spacer(minLength: 4)
            trail
        }
        .padding(.leading, indent ? 21 : 2)
        .padding(.vertical, 1)
        .help(detail)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title + (detail.isEmpty ? "" : ", " + detail))
    }

    @ViewBuilder private var trail: some View {
        if let m = missing {
            Text(m).font(.system(size: 11))
                .foregroundStyle(m != "not connected" && prominence != .increased ? Color(nsColor: Palette.danger) : Ink.secondary)
        } else if let s = status {
            if let n = s.badge {
                if !open { CountBadge(n: n) }
            } else {
                StatusSign(status: s).font(.system(size: 11))
            }
        }
    }
}

/// The paper Review shows, marked as the list marks the paper whose overview is shown (the selection of a list without
/// the keys); the list itself selects nothing then, so a click on the row shows the overview (UX.md §21).
struct OpenPaperFill: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(Color(nsColor: Palette.openPaper))
            .padding(.horizontal, 10)
    }
}

/// A status's sign (the mockup's STATE_GLYPH): ○ amber to check, ✓○ ready to finish, ⌛ with the student, a seal
/// finished, ⊗ (the octagon) red build failed, • the first draft, ▍ olive paragraphs to read, a tray without rounds.
struct StatusSign: View {
    let status: PaperStatus

    var body: some View {
        switch status {
        case .toCheck: Image(systemName: "circle").fontWeight(.semibold).foregroundStyle(Color(nsColor: Palette.toCheck))
        case .ready: Image(systemName: "checkmark.circle").foregroundStyle(Ink.secondary)
        case .waiting: Image(systemName: "hourglass").foregroundStyle(Ink.secondary)
        case .finished: Image(systemName: "checkmark.seal").foregroundStyle(Ink.secondary)
        case .failed: Image(systemName: BuildSign.failed).foregroundStyle(Color(nsColor: Palette.danger))
        case .firstDraft: Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(Ink.secondary).frame(width: 12)
        case .toRead: RoundedRectangle(cornerRadius: 1).fill(Color(nsColor: Palette.reading)).frame(width: 2.5, height: 10).frame(width: 12)
        case .noRounds: Image(systemName: "tray").foregroundStyle(Ink.secondary)
        }
    }
}

/// In Review the tree folds to the open paper (FEATURES OV-7): its student's name over it, with a menu of the
/// student's page and other papers.
struct ReviewStudentHeader: View {
    let model: AppModel
    let group: StudentGroup?
    let paper: String

    var body: some View {
        HStack(spacing: 4) {
            Text(group?.name ?? "Unassigned").modifier(SidebarHeader()).lineLimit(1)
            Spacer(minLength: 4)
            if let g = group {
                let others = g.papers.filter { $0.path != paper }
                if !g.unassigned || !others.isEmpty {
                    Menu {
                        if !g.unassigned { Button("\(g.name)’s Page") { model.openHub(.student(g.key)) } }
                        if !others.isEmpty {
                            Divider()
                            ForEach(others) { p in Button(p.title.isEmpty ? (p.path as NSString).lastPathComponent : p.title) { model.openPaper(p.path) } }
                        }
                        Divider()
                        Button("All Students") { model.openHub(.allStudents) }
                    } label: {
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .foregroundStyle(Ink.secondary)
                    .help(others.isEmpty ? "\(g.name)’s page" : "\(g.name)’s page and other papers")
                    .padding(.trailing, 6)
                }
            }
        }
    }
}

/// The visible way to Jump (POLISH §6): a field-like button at the top of the sidebar, which opens the Jump panel
/// (`AppModel.openJump`), as ⌘K does.
struct JumpField: View {
    let model: AppModel

    var body: some View {
        Button { model.openJump() } label: {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium))
                Text("Jump to…").font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Jump to a comment, an edit, a section or a round, or run a command (⌘K)")
        .accessibilityLabel("Jump to…")
        .padding(.horizontal, 10)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }
}
