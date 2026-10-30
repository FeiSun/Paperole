import AppKit
import SwiftUI

@main
struct PaperoleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel(options: LaunchOptions.parse(CommandLine.arguments))

    init() {
        // The app's data moved to its new name at its first real launch since the rename (Migration.swift; UX.md §34),
        // before anything reads the data or the settings. Never in a test run.
        Migration.atLaunch()
        // Launch arguments are options, never files to open: AppKit pairs `--background --paper P` as -background
        // = --paper and took P for a file, and SwiftUI then opened no window until the app was activated.
        UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": false])
        // --background (test runs, README): no Dock icon and no menu bar, set before the app finishes launching, and
        // no window frame or split view size read from or saved to the user's defaults.
        if LaunchOptions.background {
            NSApplication.shared.setActivationPolicy(.accessory)
            BackgroundRun.keepUsersFrames()
        }
        if let a = LaunchOptions.appearance { NSApplication.shared.appearance = NSAppearance(named: a == "dark" ? .darkAqua : .aqua) }
    }

    var body: some Scene {
        // the app's name, "Paperole Dev" in the dev app (AppVariant)
        Window(AppVariant.current.name, id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: WindowLayout.window, minHeight: 640)
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            // the About window with the app icon in the style chosen in Settings › General (UX.md §26)
            CommandGroup(replacing: .appInfo) {
                Button("About \(AppVariant.current.name)") { NSApp.orderFrontStandardAboutPanel(options: AppIconModel.shared.aboutOptions) }
            }
            SidebarCommands()  // View › Show / Hide Sidebar (⌃⌘S), beside the toolbar's sidebar button
            CommandGroup(replacing: .newItem) {
                Button("New Paper…") { model.showNewPaper = true }.keyboardShortcut("n")
                Divider()
                // Export and Import (design/data/DATA.md §4, §5): their sheets on this window. Import… is also what
                // Add Existing Paper… was here (the sidebar's Add Existing… opens it too), so the menu names it once.
                Button("Import…") { model.data.chooseImport(origin: .window) }
                Button("Export…") { model.data.openExport(origin: .window) }.disabled(model.papers.isEmpty)
            }
            // The reading commands (UX.md §18). Their keys are named in the titles but are not menu key equivalents:
            // a menu item with a plain letter takes that letter from every text field (and from the input method)
            // before it is typed. The keys go through the review's key monitor (KeyRoute) instead.
            // Comment and Box left the toolbar (design/ui-v2/PROPOSAL.md §3); the floating toolbar, Return and ⌥-drag
            // do them too. Keys are named in the titles only, as in Reading below.
            CommandMenu("Comment") {
                Button("Comment on Selection (Return)") { model.beginComment() }
                    .disabled(!model.canComment || model.level != .review)
                Button("Draw a Box Round a Figure, Table or Equation (B, or ⌥-drag)") { model.toolbar.boxArmed.toggle() }
                    .disabled(!model.roundIsOpen || model.busy || model.level != .review)
            }
            // the window's history across papers and levels (UX.md §21), as Finder's Go menu
            CommandMenu("Go") {
                Button("Back") { model.goBack() }.keyboardShortcut("[")
                    .disabled(!model.canGoBack)
                Button("Forward") { model.goForward() }.keyboardShortcut("]")
                    .disabled(!model.canGoForward)
                Divider()
                // the hierarchy's pages (UX.md §22), as the sidebar's first rows
                Button("All Students") { model.openHub(.allStudents) }
                    .disabled(model.hub == .allStudents)
                Button("Your Move") { model.openHub(.yourMove) }
                    .disabled(model.hub == .yourMove)
                Divider()
                Button("Overview") { model.showAllRounds() }
                    .disabled(model.selectedPath == nil || model.level == .overview)
                Button(model.continueButton?.title ?? "Review") { model.openReview(ReviewTarget(round: model.continueButton?.round)) }
                    .disabled(model.selectedPath == nil || model.level == .review || model.continueButton == nil)
            }
            // the cards' underline toggle left the panel's header for the View menu (POLISH §3, 1; §6, 11). Focus names
            // its key in the title, as the Reading menu does (F is not a menu key equivalent, for the same reason).
            CommandGroup(before: .toolbar) {
                Toggle("Underline Changed Words", isOn: $model.showChangedWords)
                Divider()
                Toggle("Focus (F)", isOn: Binding(get: { model.focus }, set: { model.setFocus($0) }))
                    .disabled(model.round?.build.pdf == nil || model.level != .review)
                Button("Jump to…") { model.openJump() }.keyboardShortcut("k")
                Divider()
                // the PDF's zoom (design/pdf-reader/PLAN.md §3.6): it left the PDF's right-click menu; ⌘-scroll and
                // pinch zoom too, and ⌘= is Zoom In as well (ReviewPDFView.performKeyEquivalent)
                Group {
                    Button("Zoom In") { model.pdf.zoomStep(in: true) }.keyboardShortcut("+")
                    Button("Zoom Out") { model.pdf.zoomStep(in: false) }.keyboardShortcut("-")
                    Button("Actual Size") { model.pdf.setZoom(1) }.keyboardShortcut("0")
                    Button("Fit Width") { model.pdf.setZoom(nil) }.keyboardShortcut("9")
                }
                .disabled(model.round?.build.pdf == nil || model.level != .review)
                Divider()
            }
            // the toolbar's find in the paper (Find.swift): ⌘F puts the cursor in its field; Jump's last row finds there
            // too (POLISH §3 row 12); these go on with it
            CommandGroup(after: .pasteboard) {
                Divider()
                FindCommands(model: model, find: model.pdf.find)
            }
            // only while reading marks are on (Settings; UX.md §18): off, N, C and Shift-C are not keys either
            if model.readingMarksOn {
                CommandMenu("Reading") {
                    Group {
                        Button("Next Changed Paragraph to Read (N)") { model.perform(.nextUnread) }
                        Button("Mark Paragraph Read (C)") { model.perform(.markRead) }
                        Button("Mark Section Read (⇧C)") { model.perform(.markSectionRead) }
                    }
                    .disabled(model.level != .review)
                }
            }
        }
        // Paperole › Settings… (⌘,): reading marks, off by default
        Settings {
            SettingsView(model: model)
        }
    }
}

/// A --background run (a test) leaves the window frame and the split views' sizes alone: they are kept in the user's
/// defaults under the same bundle id and would move the user's own window. SwiftUI names them before the app has
/// finished launching, and AppKit saves a named frame as soon as it has to move it onto the current screens, so a name
/// cleared afterwards came too late (2026-10-17). From the start of such a run, naming a window frame or a split view
/// does nothing and no frame is saved by name, so nothing is read from or written to those defaults.
enum BackgroundRun {
    static func keepUsersFrames() {
        func replace(_ cls: AnyClass, _ sel: Selector, with block: Any) {
            guard let m = class_getInstanceMethod(cls, sel) else { return }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
        let refuseName: @convention(block) (NSWindow, NSString) -> Bool = { _, _ in false }
        replace(NSWindow.self, #selector(NSWindow.setFrameAutosaveName(_:)), with: refuseName)
        let saveNothing: @convention(block) (NSWindow, NSString) -> Void = { _, _ in }
        replace(NSWindow.self, #selector(NSWindow.saveFrame(usingName:)), with: saveNothing)
        let noSplitName: @convention(block) (NSSplitView, NSString?) -> Void = { _, _ in }
        replace(NSSplitView.self, #selector(setter: NSSplitView.autosaveName), with: noSplitName)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The app icon in the style chosen in Settings › General from the start (AppIcons.swift; UX.md §26).
    func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppIconModel.shared.start() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)  // a dead engine must not kill the app when we write to its stdin
        let background = LaunchOptions.background
        if background {
            // Never activated. SwiftUI's window is ordered in by now but not yet drawn: made transparent and sent
            // behind every other window here, it is never shown in front.
            for w in NSApp.windows where w.isVisible {
                w.alphaValue = 0
                w.orderBack(nil)
                DispatchQueue.main.async { w.alphaValue = 1 }
            }
        } else {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        // the migration put everything back, or found both data folders (Migration.swift): said once, the app goes on
        if let n = Migration.notice {
            Migration.notice = nil
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = n.title
                alert.informativeText = n.detail
                alert.runModal()
            }
        }
        // A debug run (--debug-script, --debug-scroll-perf) while the screen is locked: the app is not activated and
        // SwiftUI opens no window, so nothing would run. The window is then made here, with the same content.
        let args = CommandLine.arguments
        if args.contains("--debug-script") || args.contains("--debug-drag") || args.contains("--debug-scroll-perf") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard NSApp.windows.allSatisfy({ !$0.isVisible }), let model = AppModel.current else { return }
                let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                                 styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
                w.title = AppVariant.current.name
                w.contentView = NSHostingView(rootView: ContentView().environmentObject(model)
                    .frame(minWidth: WindowLayout.window, minHeight: 640))
                w.isReleasedWhenClosed = false
                if background {
                    w.orderBack(nil)
                } else {
                    w.orderFrontRegardless()
                    w.makeKey()
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Quitting (UX.md §8): an editor open on a card is saved first, as when focus leaves it, and the app quits once the
    /// engine has it (it stays, with the editor open, when the engine refuses). Then a new comment's note that is not
    /// saved, or unsent drafts (kept either way), ask once; a test run never asks.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let model = AppModel.current else { return .terminateNow }
            // Not .terminateLater: AppKit would wait in a run loop of its own, and when quitting came from a block on
            // the main queue (a debug script's quit) the engine's reply, delivered on the main actor, never arrived.
            // Quitting is asked again once the save is done.
            let save = model.saveEditBeforeQuit { ok in if ok { NSApp.terminate(nil) } }
            guard save == .nothing else { return .terminateCancel }
            guard Self.dataAllowsQuit(model.data), Self.mayQuit(model) else { return .terminateCancel }
            model.backups.stopBackup()  // an automatic backup stops where it leaves nothing; the next launch makes it
            return .terminateNow
        }
    }

    /// Settings › Data & Storage's work (UX.md §28) is never cut off by quitting: an export or an import stops only
    /// where it leaves nothing half written. A sheet waiting for the advisor closes (nothing was done yet). While work
    /// runs the advisor chooses: stop it (when it can stop) and quit, or quit once it has finished, or not quit; a test
    /// run stops what can stop and quits once it has ended.
    @MainActor static func dataAllowsQuit(_ data: DataModel) -> Bool {
        if !data.working {
            data.export = nil
            data.importing = nil
        }
        guard data.working else { return true }
        guard !LaunchOptions.background else {
            data.cancelWork()
            data.quitWhenDone = true
            return false
        }
        let alert = NSAlert()
        alert.messageText = data.cancellable ? "Stop the work in Data & Storage and quit?"
            : "Quit once the work in Data & Storage has finished?"
        alert.informativeText = (data.step.map { $0 + " " } ?? "")
            + (data.cancellable ? "Stopping it leaves nothing half written."
                : "It is not stopped halfway; \(AppVariant.current.name) quits by itself once it has finished.")
        alert.addButton(withTitle: data.cancellable ? "Stop and Quit" : "Quit When Finished")
        alert.addButton(withTitle: "Don’t Quit")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        data.cancelWork()
        data.quitWhenDone = true
        return false
    }

    @MainActor private static func mayQuit(_ model: AppModel) -> Bool {
        guard !LaunchOptions.background, let q = model.unsentDraftsQuestion() else { return true }
        let alert = NSAlert()
        alert.messageText = q.title
        alert.informativeText = q.detail
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Closing the review window quits the app (it is the last window), so it goes the way quitting goes (UX.md §8): an
/// editor open on a card is saved first, and a new comment's unsaved note or unsent drafts ask once (POLISH §0). The
/// window does not close first. The window's close button asks at once: a new-comment popover holding a note vetoes
/// the window's own close, silently, before its delegate is asked. File › Close comes to the delegate, set in front of
/// SwiftUI's, which gets every other message.
final class QuitOnClose: NSObject, NSWindowDelegate {
    private weak var original: NSWindowDelegate?
    private let quit: () -> Void

    init(original: NSWindowDelegate?, quit: @escaping () -> Void) {
        self.original = original
        self.quit = quit
    }

    /// The window's delegate becomes one, in front of the one it has (once).
    @MainActor static func install(on w: NSWindow, quit: @escaping () -> Void = { MainActor.assumeIsolated { NSApp.terminate(nil) } }) {
        guard !(w.delegate is QuitOnClose) else { return }
        let q = QuitOnClose(original: w.delegate, quit: quit)
        objc_setAssociatedObject(w, &key, q, .OBJC_ASSOCIATION_RETAIN)  // the delegate is weak
        w.delegate = q
        if let b = w.standardWindowButton(.closeButton) {
            b.target = q
            b.action = #selector(closeClicked(_:))
        }
    }

    @objc func closeClicked(_ sender: Any?) {
        Self.asked += 1
        quit()
    }

    private nonisolated(unsafe) static var key = 0

    /// How many times closing was asked for (--debug-script close).
    nonisolated(unsafe) private(set) static var asked = 0

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        Self.asked += 1
        quit()  // asks and quits, or stays with the window as it was
        return false
    }

    override func responds(to sel: Selector!) -> Bool { super.responds(to: sel) || original?.responds(to: sel) == true }
    override func forwardingTarget(for sel: Selector!) -> Any? {
        original?.responds(to: sel) == true ? original : super.forwardingTarget(for: sel)
    }
}

/// Hands its window to `found` once it is in one.
private struct WindowReader: NSViewRepresentable {
    let found: (NSWindow) -> Void

    final class View: NSView {
        var found: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let w = window { found?(w) }
        }
    }

    func makeNSView(context: Context) -> View {
        let v = View()
        v.found = found
        return v
    }

    func updateNSView(_ v: View, context: Context) {}
}

/// The window's three panes (POLISH §3 row 2: four became three): the sidebar, the PDF and the panel. At the window's
/// minimum width the sidebar and the review (the PDF and the panel at their minimums, as before) fit side by side, so
/// the panel is never clipped.
enum WindowLayout {
    static let sidebar: CGFloat = 200, sidebarIdeal: CGFloat = 236, sidebarMax: CGFloat = 340
    static let pdf: CGFloat = 420
    static let panel: CGFloat = 320
    static let review: CGFloat = 760  // the PDF's 420 and the panel's 320, with room for the split view's divider
    static var window: CGFloat { sidebar + review }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        // Focus hides the sidebar (POLISH §4.3); showing it again (its toggle, ⌃⌘S) ends Focus
        NavigationSplitView(columnVisibility: Binding(get: { model.focus || !model.sidebarShown ? .detailOnly : .all },
                                                      set: { model.sidebarToggled($0 != .detailOnly) })) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: WindowLayout.sidebar, ideal: WindowLayout.sidebarIdeal,
                                                max: WindowLayout.sidebarMax)
        } detail: {
            // a page of the hierarchy (UX.md §22), a paper (its overview or Review), or no paper yet
            if let page = model.hub {
                HubScreen(model: model, hub: model.hubModel, page: page)
            } else if model.selectedPath != nil {
                PaperView()
            } else {
                NoPaperView(hasPapers: !model.papers.isEmpty, newPaper: { model.showNewPaper = true },
                            addExisting: { model.data.chooseImport(origin: .window) })
            }
        }
        .background(WindowReader { QuitOnClose.install(on: $0) })
        // the hierarchy's sheets (UX.md §22), here so they show whether the sidebar is shown or not; each on a view
        // of its own
        .background(Color.clear.sheet(item: Binding(get: { model.editingPaper.map(SheetID.init) },
                                                    set: { model.editingPaper = $0?.id })) { s in
            EditPaperSheet(model: model, path: s.id)
        })
        .background(Color.clear.sheet(item: Binding(get: { model.renamingStudent.map(SheetID.init) },
                                                    set: { model.renamingStudent = $0?.id })) { s in
            RenameStudentSheet(model: model, key: s.id)
        })
        // Tag Comments… (UX.md §24), from the paper page, the overview's More menu or a student's page
        .background(Color.clear.sheet(item: Binding(get: { model.tagComments }, set: { if $0 == nil { model.closeTagComments() } })) { s in
            TagCommentsSheet(sheet: s, tags: model.tags, done: { model.closeTagComments() })
        })
        .modifier(TransferSheets(model: model, data: model.data))
        // Resume Round N's confirmation (UX.md §31), from Review, the menus or a paper's context menu, on a view of its
        // own as the sheets
        .background(Color.clear.alert(model.confirmResume?.title ?? "",
                                      isPresented: Binding(get: { model.confirmResume != nil },
                                                           set: { if !$0 { model.confirmResume = nil } }),
                                      presenting: model.confirmResume) { a in
            Button("Resume") { model.resumeRound(a) }.keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: { a in
            Text(a.message)
        })
        .overlay { JumpOverlay(jump: model.jump, model: model) }
        .sheet(isPresented: $model.showNewPaper) { NewPaperSheet() }
        .alert(AppVariant.current.name, isPresented: Binding(get: { model.alertMessage != nil },
                                                   set: { if !$0 { model.alertMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
    }
}

/// No paper open (POLISH §3 row 15: empty screens teach the next step). With none listed, "Add a student's paper", what
/// happens then, and New Paper… as the window's one prominent button, Import… beside it (it brings back an export or
/// a backup, or lists review folders you have; DATA.md §6.4); else a line pointing to the sidebar, the same two
/// buttons plain.
struct NoPaperView: View {
    let hasPapers: Bool
    let newPaper: () -> Void
    let addExisting: () -> Void

    var body: some View {
        EmptyPage(icon: "doc", title: hasPapers ? "No paper open" : "Add a student’s paper",
                  text: hasPapers ? "Choose one in the sidebar, or add another student’s paper."
                      : "Create it, then start Round 1 with their LaTeX folder or .zip.\n\(AppVariant.current.name) builds it, and you comment on the PDF.\nImport… brings back a backup.") {
            if hasPapers {
                Button("New Paper…", action: newPaper)
            } else {
                Button("New Paper…", action: newPaper).buttonStyle(.borderedProminent)
            }
            Button("Import…", action: addExisting).help("List review folders you have, or bring back an export or a backup")
        }
    }
}

/// Export…, Import… and Put Back an Earlier Ledger… from File, the context menus and the empty list (design/data/DATA.md
/// §4–§6), each sheet on a view of its own; Settings shows its own Export and Import on its window. The window's bottom
/// line (Remove from List's Undo).
struct TransferSheets: ViewModifier {
    @ObservedObject var model: AppModel
    @ObservedObject var data: DataModel

    func body(content: Content) -> some View {
        content
            .background(Color.clear.sheet(item: Binding(get: { data.export?.origin == .window ? data.export : nil },
                                                        set: { if $0 == nil { data.closeExport() } })) { _ in
                ExportSheet(model: model)
            })
            .background(Color.clear.sheet(item: Binding(get: { data.importing?.origin == .window ? data.importing : nil },
                                                        set: { if $0 == nil { data.closeImport() } })) { _ in
                ImportSheet(data: data)
            })
            .background(Color.clear.sheet(item: Binding(get: { model.ledgerHistory }, set: { if $0 == nil { model.ledgerHistory = nil } })) { _ in
                LedgerHistorySheet(model: model)
            })
            .overlay(alignment: .bottom) { WindowNoticeView(model: model) }
    }
}

/// An empty screen (POLISH §3 row 15): an icon, what is missing, the next step in words, and its buttons, centred.
struct EmptyPage<Buttons: View>: View {
    let icon: String
    let title: String
    let text: String
    @ViewBuilder let buttons: Buttons

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: icon).font(.system(size: 26, weight: .light)).foregroundStyle(Ink.secondary)
            Text(title).font(.system(size: 15, weight: .semibold)).padding(.top, 8)
            // lines broken by hand: a Text sized to its height here (fixedSize) shifted the sidebar up under the title bar
            Text(text).font(.system(size: 12.5)).foregroundStyle(Ink.secondary).lineSpacing(3).padding(.top, 4)
            HStack(spacing: 8) { buttons }.padding(.top, 14)
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(Ink.label)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The sidebar's group names, "Students" and "Contents" (POLISH §2.3): 11 Semibold in the palette's secondary, named,
/// not the system's header style, which drew them at 1.9:1 (visual review 2026-10-18).
struct SidebarHeader: ViewModifier {
    func body(content: Content) -> some View {
        content.font(.system(size: 11, weight: .semibold)).foregroundStyle(Ink.secondary)
    }
}
