import AppKit
import SwiftUI

struct PaperView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if let round = model.round {
                if round.build.pdf == nil {
                    FailedBuildView(round: round)
                    Divider()
                    BuildStatusLine(round: round, position: model.pdf.position)
                } else {
                    // in Focus too (POLISH §7): the panel then shows only the selected card, and the status line stays
                    HSplitView {
                        VStack(spacing: 0) {
                            PDFPane(model: model)
                                .overlay(alignment: .top) { ReanchorBar(toolbar: model.toolbar) }
                                .overlay(alignment: .bottom) { ReadingToast(reading: model.reading) }
                                // the find over the page it searches, clear of the scroller (Find.swift)
                                .overlay(alignment: .topTrailing) {
                                    FindBar(find: model.pdf.find).padding(.top, 10).padding(.trailing, 20)
                                }
                            Divider()
                            BuildStatusLine(round: round, position: model.pdf.position)
                        }
                        .frame(minWidth: WindowLayout.pdf, maxWidth: .infinity, maxHeight: .infinity)
                        // in Focus no wider than when it began (AppModel.focusPanelWidth): the page takes the room
                        let most = model.focusPanelWidth.map { min(max($0, WindowLayout.panel), 560) } ?? 560
                        RightPanel()
                            .frame(minWidth: WindowLayout.panel, idealWidth: min(400, most), maxWidth: most, maxHeight: .infinity)
                    }
                }
            } else if model.state != nil {
                EmptyPage(icon: "tray.and.arrow.down", title: "No rounds yet",
                          text: "Choose or drop the student’s LaTeX folder or .zip to start Round 1.\n\(AppVariant.current.name) builds it, and you comment on the PDF.") {
                    Button("Start Round 1…") { model.startRound() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canStartRound)
                }
            } else if model.busy {
                ProgressView("Waiting for the engine…")  // this paper's state is queued behind a running request
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let problem = model.stateError {
                // its state could not be read (A1-06): said, with Try Again, not an empty page titled "No rounds yet";
                // the sign of the app's other failures (the triangle is a build's errors' and Not found's)
                EmptyPage(icon: "exclamationmark.circle", title: "This paper could not be opened", text: problem) {
                    Button("Try Again") { model.retryState() }
                }
            } else {
                Color.clear
            }
        }
        .frame(minWidth: WindowLayout.review)
        // The overview over Review (UX.md §21): Review stays in the window, hidden (its AppKit views by
        // PDFController.setReviewHidden), so it is never rebuilt; an overlay, as a branch or SwiftUI's own hiding
        // would rebuild it or move its views
        .accessibilityHidden(model.showsOverview)
        .overlay { if model.showsOverview { OverviewScreen(model: model, overview: model.overview) } }
        .background(PaperWidthReader(model: model))
        .navigationTitle(model.state?.paper.title ?? model.papers.first { $0.path == model.selectedPath }?.title ?? "")
        .navigationSubtitle(model.windowSubtitle)
        .modifier(OwnToolbarTitle())
        .toolbar {
            if model.showsOverview { overviewToolbar } else { toolbar }
        }
        .sheet(item: $model.roundCard) { ask in RoundSummaryView(ask: ask) { model.roundCard = nil } }
        .sheet(isPresented: $model.showRetry) { RetrySheet() }
        .sheet(isPresented: $model.showFinish) { FinishSheet(preview: model.finishPreview) }
        // here, not on the panel, so ⌫ on a new comment asks in Focus too
        .alert("Delete \(model.confirmDelete ?? "")?", isPresented: Binding(get: { model.confirmDelete != nil },
                                                                           set: { if !$0 { model.confirmDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let id = model.confirmDelete { model.deleteConfirmed(id) }
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its note will be lost. The ID will not be reused.")
        }
        // Turn On Shell Escape…'s confirmation (UX.md §41), on a view of its own as Resume's. Return is Cancel's, as
        // Turn On lets the student's LaTeX run commands (an alert's first button takes Return when no button has it)
        .background(Color.clear.alert(model.confirmShellEscape?.title ?? "",
                                      isPresented: Binding(get: { model.confirmShellEscape != nil },
                                                           set: { if !$0 { model.confirmShellEscape = nil } }),
                                      presenting: model.confirmShellEscape) { a in
            Button("Turn On") { model.setShellEscape(true, paper: a.paper) }
            Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
        } message: { a in
            Text(a.message)
        })
    }

    /// Room for the round menu and Change marks, Focus and Finish Round… (in a closed round final.pdf with its menu, as
    /// wide), measured at the window's minimum width (ToolbarTitle's); New Round…, once the latest round is closed, needs
    /// 125 more (measured at 1100 and 1440 pt).
    private var toolbarReserve: CGFloat { model.latestRound?.closed ?? true ? 585 : 460 }

    private var finishButton: some View {
        Button { model.openFinish() } label: { Text("Finish Round…") }.disabled(!model.canFinish)
    }

    /// design/ui-v2/PROPOSAL.md §3: the title with "Mei Lin · 7 comments and 2 edits to check" under it, then the round
    /// menu; Change marks as an icon, and Finish Round… (in a closed round: final.pdf and New Round…). The
    /// sidebar's toggle is the system's (POLISH §3 row 1: it was the outline's). Comment and Box are in the Comment
    /// menu, the floating toolbar, Return and ⌥-drag.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 16) {
                HStack(spacing: 8) {
                    HistoryButtons(model: model)  // the window's history (UX.md §21), as in the overview
                    if #available(macOS 15, *) {  // the window's title, here so the round menu can follow it
                        // room for the items after it (`toolbarReserve`)
                        ToolbarTitle(model: model, overview: model.overview, reserve: toolbarReserve)
                    }
                }
                // not while the paper's state is not in: no rounds to name (an empty menu was a lone chevron; A1-06)
                if model.state != nil { RoundPicker() }
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Spacer()  // a flexible space: without the system's title the items would follow the round menu
            if model.toolbarNudge { ToolbarNudge() }
            busyIndicator
            Toggle(isOn: $model.showChanges) { Label("Change marks", systemImage: "highlighter") }
                .disabled(model.round?.build.pdf == nil)  // no PDF to mark, as Focus
                .help("Change marks: show the student’s changes in the PDF")
            // Focus, the reading mode (POLISH §3 row 5, §6, §7): the page larger, the selected card alone beside it; a page of
            // text, as Safari's Reader, the same in both states (the toggle's pressed look says which)
            Toggle(isOn: Binding(get: { model.focus }, set: { model.setFocus($0) })) {
                Label("Focus", systemImage: AppModel.focusSymbol)
            }
            // named, as its neighbours final.pdf and New Round…: the page glyph alone read as one more document
            // (review 2026-10-18)
            .labelStyle(.titleAndIcon)
            .disabled(model.round?.build.pdf == nil)
            .help(model.focus ? "Leave Focus: show the sidebar and the whole list again (F)"
                  : "Focus: hide the sidebar and the list and read the page larger; the comment you click shows on the right (F)")
            if let round = model.round, round.closed {
                // a click opens it; its menu has Show in Finder and, for the rare case, the email text the engine
                // still writes (request of 2026-10-26: no email at Finish, the PDF is enough)
                Menu {
                    Button("Show in Finder") {
                        if let p = round.finalPdf { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
                    }
                    .disabled(round.finalPdf == nil)
                    Divider()
                    Button("Copy Email Text") { model.copyEmailText() }.disabled((round.email ?? "").isEmpty)
                } label: {
                    Label("final.pdf", systemImage: "doc.richtext")
                } primaryAction: {
                    if let p = round.finalPdf { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
                }
                .labelStyle(.titleAndIcon)
                .disabled(round.finalPdf == nil)
                .help("Open round \(round.n)'s final.pdf, as the student got it")
            } else if model.round != nil {
                // the window's one prominent button, and only once nothing is left (POLISH §3 row 1, §6 decision 10)
                if model.readyToFinish {
                    finishButton.buttonStyle(.borderedProminent)
                        .help("Nothing is left to check or read: finish the round and write final.pdf")
                } else {
                    finishButton
                        .help("What goes to the student, what is left and your unsent drafts, then final.pdf")
                }
            }
            if model.latestRound?.closed ?? true {  // no round open: the student's next one can come in
                Button { model.startRound() } label: {
                    Label(model.round == nil ? "Start Round 1…" : "New Round…", systemImage: "tray.and.arrow.down")
                }
                .labelStyle(.titleAndIcon)
                .disabled(!model.canStartRound)
                .help("Ingest the student’s revised source as the next round")
            }
        }
    }
}

extension PaperView {
    /// The overview's toolbar (OVERVIEW-v2 §5.1; UI v4, mac/UX.md §40.4): ‹ › and no title (the page has its own; the
    /// window keeps it for the Window menu), the engine's progress, then "Following …", Map | Table, More and Continue
    /// Round N.
    @ToolbarContentBuilder
    var overviewToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HistoryButtons(model: model)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Spacer()
            if model.toolbarNudge { ToolbarNudge() }
            busyIndicator
            OverviewToolbarTrail(model: model, overview: model.overview)
        }
    }

    /// The engine's progress in either toolbar, while it works.
    @ViewBuilder private var busyIndicator: some View {
        if model.busy {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(model.progress.isEmpty ? "Working…" : model.progress)
                    .lineLimit(1)
                    .frame(maxWidth: 280, alignment: .leading)
            }
        }
    }
}

/// From macOS 15 the toolbar shows the window's title and subtitle itself (PaperView's toolbar), followed by the round
/// menu as in design/ui-v2; macOS 14 shows the system's, after the menu.
struct OwnToolbarTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) { content.toolbar(removing: .title) } else { content }
    }
}

/// "Round 3 ▾": every round with the date its source came in and its status (F7). Picking an earlier round shows it
/// read only.
struct RoundPicker: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Menu {
            // the paper's overview, as it was left (UX.md §21; Back does the same when Review was opened from it)
            Button("All Rounds") { model.showAllRounds() }
            Divider()
            Picker("Round", selection: Binding(get: { model.round?.n ?? 0 }, set: { model.showRound($0) })) {
                ForEach(model.state?.rounds ?? [], id: \.n) { r in
                    Text(Self.title(r)).tag(r.n)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            if model.round?.closed == true || model.resumable() != nil { Divider() }
            // the shown round's card, once it is finished (RoundCard.swift)
            if let r = model.round, r.closed { Button("Round \(r.n) Summary…") { model.openRoundSummary(r.n) } }
            if let a = model.resumable() {  // the latest round, finished (UX.md §31)
                Button("Resume Round \(a.round)") { model.askResume() }
            }
        } label: {
            Text(model.roundLabel)
        }
        .menuStyle(.borderlessButton)  // "Round 3 ⌄", as the mockup's plain text (visual review 2026-10-18)
        .fixedSize()
        .disabled(model.round == nil)
        .help("Show an earlier round")
    }

    /// "Round 1 · Oct 14 · closed"
    static func title(_ r: RoundSummary) -> String {
        let status = r.closed ? "closed" : r.status == "failed" ? "build failed" : "open"
        return (["Round \(r.n)", shortDate(r.created)].compactMap { $0 } + [status]).joined(separator: " · ")
    }
}

/// "Oct 14" from an engine time (ISO 8601 with offset), in English like the rest of the app; nil if unreadable. The
/// formatters are made once: a new pair cost about 0.1 ms per call (review 2026-10-24, A4a-01).
func shortDate(_ iso: String?) -> String? {
    guard let iso, let date = isoTime.date(from: iso) else { return nil }
    return monthDay.string(from: date)
}

private let isoTime = ISO8601DateFormatter()
private let monthDay: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "MMM d"
    return f
}()

/// The build in one line under the PDF (design/ui-v2/PROPOSAL.md §3): a grey tick when it built, red only for errors,
/// label2 for a failed build (UI v4); Details… for the warnings, errors and log; on the right the reading count with Next and Mark Read (POLISH
/// §3 row 3; `ReadingStatusView`, which observes only its own count) and the page shown. It observes only the PDF's
/// position, so scrolling redraws nothing else.
struct BuildStatusLine: View {
    let round: RoundInfo
    @ObservedObject var position: PDFPosition
    @EnvironmentObject var model: AppModel
    @State private var showGoTo = false

    private var build: Build { round.build }

    var body: some View {
        // errors in red with the triangle; a failed build's octagon and words in label2 (UI v4: red only for an error)
        let tone = build.status == "errors" ? Color(nsColor: Palette.danger) : build.status == "ok" ? Ink.secondary : Ink.label2
        HStack(spacing: 6) {
            Image(systemName: build.status == "ok" ? "checkmark" : build.status == "errors" ? BuildSign.errors : BuildSign.failed)
                .foregroundStyle(tone)
            (Text(headline).foregroundColor(tone) + Text(details + " ·"))
                .lineLimit(1)
            Button("Details…") { model.showBuildDetails = true }
                .buttonStyle(LinkStyle())
                .popover(isPresented: $model.showBuildDetails, arrowEdge: .top) {
                    BuildDetails(build: build, about: BuildDetails.about(model.state?.paper, build: build, source: model.lastSource),
                                 again: model.canBuildAgain && !model.busy ? buildAgain : nil,
                                 turnOff: model.state?.paper.shellEscape == true ? { model.setShellEscape(false) } : nil,
                                 offer: model.shellEscapeOffer.map { o in (o.title, !model.busy, { model.takeShellEscapeOffer(o) }) })
                }
                .fixedSize()
            if build.pdf != nil {
                Divider().frame(height: 12).padding(.horizontal, 4)
                CheckActivityButton(model: model, checks: model.checks, refs: model.refs)
            }
            Spacer(minLength: 8)
            if build.pdf != nil {
                ReadingStatusView(status: model.reading.status, model: model)
                    .layoutPriority(1)
                // where Back goes, beside where you are (BRIEF E4)
                BackLink(chip: model.pdf.backChip) { model.goBack() }
                    .padding(.leading, 6)
                if let p = position.page, position.count > 0 {
                    // Go to Page (design/pdf-reader/PLAN.md P1.4): a click, the number, Return
                    Button { showGoTo = true } label: { Text("p.\(p + 1) of \(position.count)").monospacedDigit() }
                        .buttonStyle(.plain)
                        .fixedSize()
                        .padding(.leading, 6)
                        .help("Go to Page")
                        .accessibilityLabel("Page \(p + 1) of \(position.count)")
                        .popover(isPresented: $showGoTo, arrowEdge: .top) {
                            GoToPageField(current: p, count: position.count) { i in
                                showGoTo = false
                                model.pdf.goToPage(i)
                                model.pdf.takeKeys()
                            }
                        }
                }
                // a zoom other than Fit Width (design/pdf-reader/PLAN.md §3.6), with Fit Width and 100–200% under it
                if let z = position.zoom {
                    Menu {
                        Button("Fit Width") { model.pdf.setZoom(nil) }
                        Divider()
                        ForEach(ZoomRules.menu, id: \.self) { s in Button(ZoomRules.label(s)) { model.pdf.setZoom(s) } }
                    } label: {
                        Text(ZoomRules.label(z)).monospacedDigit()
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Zoom · View › Fit Width (⌘9) fits the page to the window again")
                }
            }
        }
        .font(.system(size: 11))
        // the palette's secondary (5.2:1), not the system's lighter grey (3.95:1 on the bar; visual review 2026-10-18),
        // on the panel's opaque grey, not the translucent bar (POLISH §2.4)
        .foregroundStyle(Ink.secondary)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(Color(nsColor: Palette.panel))
    }

    private var headline: String {
        switch build.status {
        case "ok": return "Built"
        case "errors": return "Built with \(count(build.errors.count, "error"))"
        default: return "Build failed, no PDF"
        }
    }

    /// " · 3 warnings", or nothing: the page count is in "p.1 of 8", and a figure that is zero is not shown
    /// (design/review-page/BRIEF.md E6).
    private var details: String { Self.details(build) }

    static func details(_ build: Build) -> String {
        build.warnings.isEmpty ? "" : " · " + count(build.warnings.count, "warning")
    }

    /// Build Round N Again… (E2E-05): a round that built, with errors or not, before any comment or verdict in it,
    /// built again with a corrected source, main file or engine (the engine replaces it; CONTRACT §6).
    private var buildAgain: (title: String, run: () -> Void) {
        ("Build Round \(round.n) Again…", {
            model.showBuildDetails = false
            model.openRetry()
        })
    }
}

func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

struct BuildDetails: View {
    let build: Build
    var about: [String] = []
    /// Build Round N Again…, under the engine and the source, while the round can be built again.
    var again: (title: String, run: () -> Void)?
    /// Turn Off Shell Escape, under them while the paper has it on: from its next build, without asking (UX.md §41).
    var turnOff: (() -> Void)?
    /// Build Again with Shell Escape… or Turn On Shell Escape… (`AppModel.shellEscapeOffer`), under the errors (a build
    /// without errors never asks for it); disabled while the engine works.
    var offer: (title: String, enabled: Bool, run: () -> Void)?

    /// The engine and main file, "· shell escape" for a round built with it (UX.md §41), and the source the round came
    /// from, at the top of Details.
    static func about(_ paper: PaperInfo?, build: Build, source: String?) -> [String] {
        var out: [String] = []
        if let paper, let engine = paper.engine {
            out.append([engine, paper.main, build.shellEscape == true ? "shell escape" : nil].compactMap { $0 }.joined(separator: " · "))
        }
        if let source { out.append("Source: " + (source as NSString).lastPathComponent) }
        return out
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(about, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                if let again {
                    Button(again.title, action: again.run).buttonStyle(LinkStyle()).font(.callout)
                        .help("Build this round again with a corrected source folder, another main file or engine")
                }
                if let turnOff {
                    Button("Turn Off Shell Escape", action: turnOff).buttonStyle(LinkStyle()).font(.callout)
                }
                if !build.errors.isEmpty {
                    Text("Errors").font(.headline)
                    ForEach(build.errors, id: \.self) { e in
                        Text(errorLine(e)).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    }
                    offerButton
                }
                if !build.warnings.isEmpty {
                    Text("Warnings").font(.headline)
                    ForEach(Array(build.warnings.enumerated()), id: \.offset) { _, w in
                        Text(w).font(.callout).textSelection(.enabled)
                    }
                }
                if let tail = build.logTail, !tail.isEmpty {
                    Text("Log (last lines)").font(.headline)
                    Text(tail).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 560, height: 360)
    }

    @ViewBuilder private var offerButton: some View {
        if let offer {
            Button(offer.title, action: offer.run)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!offer.enabled)
        }
    }
}

func errorLine(_ e: BuildError) -> String {
    let loc = [e.file, e.line.map(String.init)].compactMap { $0 }.joined(separator: ":")
    return loc.isEmpty ? e.message : loc + ": " + e.message
}

struct FailedBuildView: View {
    let round: RoundInfo
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // the one "did not build" sign (the UI audit: the filled octagon was a third look for the same state), in
            // label2 (UI v4, BRIEF §8.4: its shape and words say it, so red means only an error)
            Label("Round \(round.n) did not build", systemImage: BuildSign.failed)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Ink.label2)
            if let file = missingFile(round.build) {
                Text("Missing file: \(file) — ask the student to resend it, or Retry with a corrected folder.")
                    .font(.headline)
                    .textSelection(.enabled)
            }
            Text("No PDF was produced, so nothing was compared or carried. Retry with another main file or engine, or with a corrected source folder.")
                .foregroundStyle(Ink.secondary)
                .frame(maxWidth: 620, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(round.build.errors, id: \.self) { e in
                Text(errorLine(e)).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            }
            Text("Log (last lines)").font(.headline)
            ScrollView {
                Text(round.build.logTail ?? "")
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            HStack {
                Button("Retry…") { model.openRetry() }
                    .controlSize(.large)
                    .disabled(round.closed || model.busy)
                // a package asks for shell escape (UX.md §41): the same sheet, its toggle on
                if round.build.needsShellEscape == true {
                    Button(ShellEscapeOffer.buildAgain.title) { model.takeShellEscapeOffer(.buildAgain) }
                        .controlSize(.large)
                        .disabled(round.closed || model.busy)
                }
                Spacer()
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The file a failed build could not find (``File `X' not found``, or LaTeX's ``File `X.tex' not found``), if any. Not
/// minted's own output (`_minted-main/…`), which only a build with shell escape writes (UX.md §41): no student sends it.
func missingFile(_ b: Build) -> String? {
    let texts = b.errors.map(\.message) + [b.logTail ?? ""]
    for t in texts {
        var rest = t[...]
        while let r = rest.range(of: #"File `([^']+)' not found"#, options: .regularExpression) {
            let file = String(rest[r].dropFirst("File `".count).prefix { $0 != "'" })
            if !file.hasPrefix("_minted") { return file }
            rest = rest[r.upperBound...]
        }
    }
    return nil
}

/// "Re-anchoring R1-03: select the text or ⌥-drag a box · [Place] [Cancel]" over the PDF (UX.md §8).
struct ReanchorBar: View {
    @ObservedObject var toolbar: ToolbarModel
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let id = toolbar.reanchor {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 10) {
                    Image(systemName: "scope")
                    Text("Re-anchoring \(id): select the text, or ⌥-drag a box").fontWeight(.medium)
                    Spacer()
                    Button("Place") { model.placeReanchor() }
                        .help("Move \(id) to the selection or the box (Return)")
                    Button("Cancel") { model.leaveReanchor() }
                        .help("Leave re-anchoring (Esc)")
                }
                if let e = toolbar.reanchorError {
                    Text(e).font(.callout).foregroundStyle(.white).padding(.horizontal, 4)
                        // a fixed #C42121, 5.9:1 under white (the system red was 3.6:1; Palette.danger is light in Dark Mode)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: NSColor(hex: 0xC42121))))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.accentColor)
        }
    }
}

/// The status line's Go to Page (design/pdf-reader/PLAN.md P1.4): "Page [4] of 12", the number selected so typing
/// replaces it; Return goes there, a number the PDF has not beeps.
struct GoToPageField: View {
    let count: Int
    let go: (Int) -> Void
    @State private var text: String
    @FocusState private var focused: Bool

    init(current: Int, count: Int, go: @escaping (Int) -> Void) {
        self.count = count
        self.go = go
        _text = State(initialValue: "\(current + 1)")
    }

    var body: some View {
        HStack(spacing: 6) {
            Text("Page")
            TextField("Page", text: $text)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 52)
                .focused($focused)
                .onSubmit {
                    if let i = Self.page(text, count: count) { go(i) } else { NSSound.beep() }
                }
            Text("of \(count)").monospacedDigit()
        }
        .font(.system(size: 12))
        .padding(10)
        .onAppear {
            // once the popover's window has the field: focused, the number selected, so typing replaces it
            DispatchQueue.main.async {
                focused = true
                DispatchQueue.main.async { NSApp.keyWindow?.firstResponder.flatMap { $0 as? NSTextView }?.selectAll(nil) }
            }
        }
    }

    /// The page typed, from 0, when the PDF has it: a number, or Jump's "p.12".
    static func page(_ text: String, count: Int) -> Int? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let n = Int(t) { return n >= 1 && n <= count ? n - 1 : nil }
        return Jump.page(t, count: count)
    }
}

/// "‹ Back to p.4 · 2.1 Data" in the status line, before the page, after a jump that recorded a step
/// (design/pdf-reader/PLAN.md §5.3; design/review-page/BRIEF.md E4, decision D3 (a)): a link, so nothing stays parked
/// on the paper. It goes after Back or Forward, a scroll of more than two views or the next jump. Narrow, the section's
/// name gives way first ("‹ Back to p.4"). It observes only the chip.
struct BackLink: View {
    @ObservedObject var chip: BackChip
    let back: () -> Void

    var body: some View {
        if let label = chip.label {
            let page = label.components(separatedBy: " · ").first ?? label
            ViewThatFits(in: .horizontal) {
                link(label)
                link(page)
            }
            .layoutPriority(-1)
            .accessibilityLabel("Back to " + Self.spoken(label))
        }
    }

    private func link(_ words: String) -> some View {
        Button(action: back) { Text("‹ Back to " + words).lineLimit(1) }
            .buttonStyle(LinkStyle())
            .help("Back (⌘[)")
            .fixedSize()
    }

    /// "page 1, Title and abstract" for "p.1 · Title and abstract".
    static func spoken(_ label: String) -> String {
        label.replacingOccurrences(of: #"^p\.(\d+)"#, with: "page $1", options: .regularExpression)
            .replacingOccurrences(of: " · ", with: ", ")
    }
}
