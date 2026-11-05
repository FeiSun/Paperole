import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A student's source dropped on a paper (UX.md §43, BACKLOG D11): a folder or a .zip on the paper's page (Review or its
/// overview) or on its row in the sidebar. What it does follows the paper's latest round, from its summary, so a row
/// needs nothing loaded. Pure, so it is unit-tested.
enum SourceDrop: Equatable {
    /// No round yet, or the latest one finished: Start Round N, after a confirmation.
    case start(Int)
    /// The latest round open with nothing done in it yet: Replace Draft…, its sheet holding the dropped source.
    case replace(Int)
    /// The latest round open with review work in it: nothing; finish it first.
    case open(Int)

    /// `replaceable` nil (an engine before it): Replace Draft…'s own checks decide when its sheet would open.
    static func of(round: Int?, closed: Bool, replaceable: Bool?) -> SourceDrop {
        guard let n = round else { return .start(1) }
        if closed { return .start(n + 1) }
        return replaceable == false ? .open(n) : .replace(n)
    }

    var accepts: Bool {
        if case .open = self { return false }
        return true
    }

    /// What the highlight says while the source is over the paper.
    var label: String {
        switch self {
        case .start(let n): return "Start Round \(n)"
        case .replace: return "Replace Draft"
        case .open(let n): return "Round \(n) is open"
        }
    }

    /// The dropped item as a source: a folder, or a file whose extension is .zip (any case), that exists. Packages
    /// (an .app) are folders to the file system, but no student sends one, so they are not sources.
    static func source(_ url: URL) -> String? {
        guard url.isFileURL else { return nil }
        let u = url.standardizedFileURL
        var folder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: u.path, isDirectory: &folder) else { return nil }
        if folder.boolValue { return NSWorkspace.shared.isFilePackage(atPath: u.path) ? nil : u.path }
        return u.pathExtension.lowercased() == "zip" ? u.path : nil
    }
}

/// Start Round N's confirmation for a dropped source: the paper and the file are named, as a drop can land on the
/// wrong row.
struct DropAsk: Equatable, Identifiable {
    var paper: String
    var title: String
    var student: String
    var source: String
    var round: Int
    var id: String { paper }

    var question: String { "Start Round \(round)?" }
    var message: String {
        let name = (source as NSString).lastPathComponent
        let who = student.isEmpty ? "" : " · " + student
        return "\(ShortTitle.of(title))\(who)\nfrom \(name)"
    }
}

/// The paper the source is over, and where: the highlight shows on that place only.
struct DropHover: Equatable {
    var paper: String
    var row: Bool
}

extension AppModel {
    /// What a source dropped on `path` would do; nil when nothing can be done there: its folder missing, or its
    /// summary not in yet (a row before the list's summaries).
    /// Nothing either while the engine is busy: a round being built leaves the summary as it was, so a second drop would
    /// start the same round again, and Replace Draft… does not open while busy.
    func sourceDrop(on path: String) -> SourceDrop? {
        guard !missingPapers.contains(path), !busy else { return nil }
        if path == selectedPath, state != nil {
            return .of(round: latestRound?.n, closed: latestRound?.closed ?? true, replaceable: state?.summary?.replaceable)
        }
        guard let s = summaries[path] else { return nil }
        return .of(round: s.round, closed: s.closed, replaceable: s.replaceable)
    }

    /// The drop itself (`SourceDropTarget`). False, and nothing changes, for anything but one folder or .zip, a paper
    /// whose round is open with review work, the engine busy, or a note being written on another paper.
    @discardableResult
    func dropSource(_ urls: [URL], on path: String) -> Bool {
        dropHover = nil
        guard urls.count == 1, let source = SourceDrop.source(urls[0]) else {
            alertMessage = "Drop the student’s LaTeX source here: one folder or one .zip."
            return false
        }
        guard let action = sourceDrop(on: path), action.accepts, !(path != selectedPath && waitsForNote()) else { return false }
        switch action {
        case .start(let n):
            let p = papers.first { $0.path == path }
            confirmDrop = DropAsk(paper: path, title: p?.title ?? (path as NSString).lastPathComponent, student: p?.student ?? "",
                                  source: source, round: n)
        case .replace:
            openRoundAction(path, replace: true, source: source)
        case .open:
            return false
        }
        return true
    }

    /// The confirmation's Start Round N: the paper opened in Review if it is not the one shown, then `ingest` once its
    /// state is in (`navigationApplied`), so a refused Round 1 opens its sheet on the right paper.
    func startDropped(_ a: DropAsk) {
        confirmDrop = nil
        if a.paper == selectedPath, state != nil {
            return ingestDropped(a)
        }
        openPaper(a.paper, level: .review)
        guard selectedPath == a.paper else { return }
        pendingStart = a
    }

    /// After every applied state: the dropped source waiting for its paper starts its round, unless the paper moved on
    /// meanwhile (another round started or finished from elsewhere), or another paper is shown.
    func startPendingDrop() {
        guard let a = pendingStart, state != nil else { return }
        pendingStart = nil
        guard a.paper == selectedPath else { return }
        ingestDropped(a)
    }

    private func ingestDropped(_ a: DropAsk) {
        guard sourceDrop(on: a.paper) == .start(a.round) else {
            alertMessage = "\(ShortTitle.of(a.title)) changed before Round \(a.round) could start, so nothing was started."
            return
        }
        ingest(source: a.source)
    }
}

/// Start Round N's confirmation for a dropped source, on a view of its own as the window's other alerts.
struct SourceDropConfirm: ViewModifier {
    @ObservedObject var model: AppModel

    func body(content: Content) -> some View {
        content.background(Color.clear.alert(model.confirmDrop?.question ?? "",
                                             isPresented: Binding(get: { model.confirmDrop != nil },
                                                                  set: { if !$0 { model.confirmDrop = nil } }),
                                             presenting: model.confirmDrop) { a in
            Button("Start Round \(a.round)") { model.startDropped(a) }.keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: { a in
            Text(a.message)
        })
    }
}

/// The drop target on a paper's page or row: Finder's file URLs only. While a source is over it, the place is outlined
/// in the accent with what a drop does ("Start Round 3"), or in grey with why it does nothing ("Round 2 is open").
struct SourceDropTarget: ViewModifier {
    @ObservedObject var model: AppModel
    let path: String?
    var row = false

    func body(content: Content) -> some View {
        content
            .onDrop(of: [.fileURL], isTargeted: Binding(get: { hovered }, set: { on in
                guard let path else { return }
                if on { model.dropHover = DropHover(paper: path, row: row) }
                else if model.dropHover == DropHover(paper: path, row: row) { model.dropHover = nil }
            })) { providers in
                guard let path, model.sourceDrop(on: path)?.accepts == true else { return false }
                Self.urls(providers) { model.dropSource($0, on: path) }
                return true
            }
            // a row redrawn or a page swapped mid-drag may never hear the drag leave
            .onDisappear { if let path, model.dropHover == DropHover(paper: path, row: row) { model.dropHover = nil } }
            .overlay {
                if hovered, let path, let action = model.sourceDrop(on: path) {
                    SourceDropHighlight(action: action, row: row).allowsHitTesting(false)
                }
            }
    }

    private var hovered: Bool { path != nil && model.dropHover == DropHover(paper: path!, row: row) }

    /// The providers' file URLs, in their order, on the main queue.
    static func urls(_ providers: [NSItemProvider], done: @escaping ([URL]) -> Void) {
        var found = [URL?](repeating: nil, count: providers.count)
        let group = DispatchGroup()
        for (i, p) in providers.enumerated() {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                DispatchQueue.main.async {
                    found[i] = url
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { done(found.compactMap { $0 }) }
    }
}

/// The page: an inset accent outline, a faint tint and the action in a capsule at the centre. A row: the outline and
/// tint over the row, the action at its trailing end in place of the status.
struct SourceDropHighlight: View {
    let action: SourceDrop
    let row: Bool

    var body: some View {
        let tint = action.accepts ? Color.accentColor : Ink.secondary
        let shape = RoundedRectangle(cornerRadius: row ? 5 : 10, style: .continuous)
        ZStack(alignment: row ? .trailing : .center) {
            if row {
                // the action over the row's status, on the sidebar's own ground, so neither shows through
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Text(action.label).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(action.accepts ? Ink.label : Ink.secondary)
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 7)
                        .frame(maxHeight: .infinity)
                        .background(tint.opacity(0.16))
                        .background(Color(nsColor: .windowBackgroundColor))
                }
                .background(tint.opacity(0.16))
                .clipShape(shape)
                shape.strokeBorder(tint, lineWidth: 1.5)
            } else {
                shape.fill(tint.opacity(0.12))
                shape.strokeBorder(tint, lineWidth: 3)
                Label {
                    Text(action.label).foregroundStyle(Ink.label)
                } icon: {
                    Image(systemName: action.accepts ? "tray.and.arrow.down.fill" : "lock").foregroundStyle(tint)
                }
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(Color(nsColor: .windowBackgroundColor), in: Capsule())
                .overlay(Capsule().strokeBorder(tint, lineWidth: 1.5))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
            }
        }
        // a row's outline just outside its text; the page's inside the window's edges
        .padding(row ? -4 : 8)
        .accessibilityHidden(true)
    }
}
