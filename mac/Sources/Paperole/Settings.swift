import AppKit
import SwiftUI

/// Where Paperole opens (Settings › General; design/tags/TAGS.md §8): the last place, or All Students.
enum OpenAtLaunch: String, CaseIterable, Identifiable {
    case lastPlace, allStudents

    var id: String { rawValue }
    var title: String { self == .lastPlace ? "Where you left off" : "All Students" }
}

/// The Settings window (⌘,; design/overview/v3/VISUAL.md §7 with the critique's fixes): the system's Settings window,
/// five tabs in its toolbar, each a grouped form, only what the advisor asked for and what already exists. General:
/// where Paperole opens, and the app icon's style (AppIcons.swift; UX.md §26, §34: the Appearance tab, which chose
/// among three icons, went with them, 2026-10-27). Overview: folding a
/// long appendix (and a long References list), the paper map as a map or a table. Reading: the reading marks, off by
/// default (the advisor's decision, 2026-10-18), and the Checks, off by default (2026-10-30). Tags: the writing tags (design/tags/TAGS.md §4). Data & Storage: where
/// things are, imports, exports, backup and restore (DataSettings.swift; UX.md §28). Every setting is the model's (the
/// icon's style is AppIconModel's, the review folders' default DataModel's), kept in the app's defaults; a test run
/// never saves one.
struct SettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general, overview, reading, tags, data

        var id: String { rawValue }
        var title: String { self == .data ? "Data & Storage" : rawValue.capitalized }
        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .overview: return "map"
            case .reading: return "book"
            case .tags: return "tag"
            case .data: return "externaldrive"
            }
        }
    }

    @ObservedObject var model: AppModel
    @State private var tab: Tab

    init(model: AppModel, tab: Tab = .general) {
        self.model = model
        _tab = State(initialValue: tab)
    }

    static let title = "Mark changed paragraphs to read"
    static let detail = "A bar beside each paragraph changed since the last round, until you mark it read. "
        + "The Changes tab lists every edit either way."
    static let checksTitle = "Checks"
    static let checksDetail = "Check each round’s PDF for slips every draft should avoid, in a Checks tab beside the comments. "
        + "What is found goes to the student with your comments, unless you mark it OK."
    static let width: CGFloat = 560

    var body: some View {
        TabView(selection: $tab) {
            ForEach(Tab.allCases) { t in
                Self.content(t, model: model)
                    .tabItem { Label(t.title, systemImage: t.symbol) }
                    .tag(t)
            }
        }
        .frame(width: Self.width)
    }

    /// A tab's form, as the window shows it (also for the debug hook's window, `settings <tab>`).
    @ViewBuilder
    static func content(_ t: Tab, model: AppModel) -> some View {
        switch t {
        case .general: GeneralSettings(model: model, icons: .shared)
        case .overview: OverviewSettings(model: model)
        case .reading: ReadingSettings(model: model)
        case .tags: TagsSettings(model: model)
        case .data: DataSettings(model: model)
        }
    }
}

/// Settings › General: where Paperole opens, as Finder's "New Finder windows show" (a pop-up), and the app icon's
/// style, Automatic, Light or Dark (segmented). In Paperole Dev a quiet footnote says which app this is (AppVariant).
struct GeneralSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var icons: AppIconModel

    var body: some View {
        Form {
            if AppVariant.current.isDev {
                Section {
                    opens
                    icon
                } footer: {
                    Text(AppVariant.devNote).font(.system(size: 11)).foregroundStyle(Ink.secondary)
                }
            } else {
                Section {
                    opens
                    icon
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: SettingsView.width, height: AppVariant.current.isDev ? 200 : 170)
    }

    private var icon: some View {
        LabeledContent {
            Picker(AppIconModel.title, selection: $icons.style) {
                ForEach(AppIconStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        } label: {
            Text(AppIconModel.title)
            Text(AppIconModel.detail)
        }
    }

    private var opens: some View {
        Picker(selection: $model.openAtLaunch) {
            ForEach(OpenAtLaunch.allCases) { Text($0.title).tag($0) }
        } label: {
            Text("When \(AppVariant.current.name) opens")
            Text("Where you left off: the same page, paper, round, comment and scroll position. If that paper is gone, All Students.")
        }
        .pickerStyle(.menu)
    }
}

/// Settings › Overview: folding (one switch for the appendix and a long References list, the critique's fix) with two
/// small rows that show what it does, and the paper map as a map or a table (the legend's switch is the same setting).
struct OverviewSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var overview: OverviewModel

    init(model: AppModel) {
        self.model = model
        overview = model.overview
    }

    static let foldTitle = "Fold the appendix and long reference lists"
    static let foldDetail = "An appendix over three pages, or References over four, becomes one block about two pages wide "
        + "with its total. Click it to show its sections at their real length; the paper opens folded again next time."

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: $model.foldParts) {
                        Text(Self.foldTitle)
                        Text(Self.foldDetail)
                    }
                    FoldSample()
                        .opacity(model.foldParts ? 1 : 0.45)
                        .padding(.leading, 2)
                }
                LabeledContent("Show the paper map as") {
                    Picker("Show the paper map as", selection: Binding(get: { overview.asTable }, set: { model.setMapAsTable($0) })) {
                        Text("Map").tag(false)
                        Text("Table").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            } header: {
                Text("Paper map")
            } footer: {
                Text("The small maps on All Students and a student’s page fold the same way.")
                    .font(.system(size: 11)).foregroundStyle(Ink.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: SettingsView.width, height: 272)
    }
}

/// Two small rows of a paper's map, folded and shown, in the small maps' colours.
struct FoldSample: View {
    @Environment(\.colorScheme) private var scheme

    /// (pages, level) of a fictional paper: a body, References, then an appendix of five sections.
    static let parts: [(Double, Int)] = [(0.6, 1), (1.6, 2), (2.6, 3), (1.0, 1), (0.9, 0), (1.3, 0)]
    static let appendix: [(Double, Int)] = [(1.2, 0), (0.8, 1), (1.4, 0), (0.9, 0), (0.7, 0)]

    var body: some View {
        let ink = MapInk(dark: scheme == .dark)
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
            GridRow {
                Text("Folded")
                Canvas { ctx, size in draw(&ctx, size: size, folded: true, ink: ink) }.frame(width: 300, height: 14).sampleGround()
            }
            GridRow {
                Text("Shown")
                Canvas { ctx, size in draw(&ctx, size: size, folded: false, ink: ink) }.frame(width: 300, height: 14).sampleGround()
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(Ink.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Folded, the appendix is one block at the end of each row; shown, its five sections at their real length.")
    }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, folded: Bool, ink: MapInk) {
        let parts = Self.parts + (folded ? [(2.0, -1)] : Self.appendix)
        let all = Self.parts + Self.appendix
        let k = size.width / CGFloat(all.reduce(0) { $0 + $1.0 })
        var x: CGFloat = 0
        for (pages, level) in parts {
            let w = CGFloat(pages) * k
            let r = CGRect(x: x + 1, y: 0, width: max(1, w - 2), height: size.height)
            ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(ink.color(.mini(level < 0 ? 1 : level))))
            if level < 0 {  // in label2, as a name on s1 (7.10:1, 6.31:1 dark; the secondary colour was under 4.5:1)
                MapCanvas.chevron(at: CGPoint(x: r.minX + 7, y: r.midY), down: false, in: &ctx, color: ink.color(.label2))
                ctx.draw(Text("A–E").font(.system(size: 11, weight: .medium)).foregroundColor(ink.color(.label2)),
                         at: CGPoint(x: r.minX + 14, y: r.midY), anchor: .leading)
            }
            x += w
        }
    }
}

/// Settings › Reading: the reading marks (UX.md §18 "Optional") and the Checks (§39).
struct ReadingSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $model.readingMarksOn) {
                    Text(SettingsView.title)
                    Text(SettingsView.detail)
                }
                Toggle(isOn: $model.checksOn) {
                    Text(SettingsView.checksTitle)
                    Text(SettingsView.checksDetail)
                }
                HStack(spacing: 8) {
                    ForEach(ChecksModel.groups, id: \.id) { g in
                        Toggle(g.title, isOn: Binding(get: { model.checkKinds.contains(g.id) },
                                                      set: { on in
                                                          if on { model.checkKinds.insert(g.id) } else { model.checkKinds.remove(g.id) }
                                                      }))
                        .toggleStyle(.checkbox)
                        .fixedSize()
                    }
                }
                .disabled(!model.checksOn)
            }
            Section("Writing checks") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(ChecksModel.writingRules, id: \.code) { rule in
                        Toggle(rule.title, isOn: Binding(get: { !model.disabledCheckCodes.contains(rule.code) },
                                                         set: { on in
                                                             if on { model.disabledCheckCodes.remove(rule.code) }
                                                             else { model.disabledCheckCodes.insert(rule.code) }
                                                         }))
                        .toggleStyle(.checkbox)
                        .help(rule.help)
                        .disabled(!model.checkKinds.contains(rule.group))
                    }
                }
            }
            .disabled(!model.checksOn)
            Section("Look up the references") {
                ForEach(RefSource.allCases, id: \.rawValue) { s in
                    Toggle(isOn: Binding(get: { model.lookUp.contains(s) },
                                         set: { on in if on { model.lookUp.insert(s) } else { model.lookUp.remove(s) } })) {
                        Text(s.name)
                        Text(s == .semanticScholar ? "Sends each cited title. Finds published versions and works with no record."
                             : "Sends each cited title, one a minute. Adds its citation counts.")
                    }
                }
            }
            .disabled(!model.checksOn)
        }
        .formStyle(.grouped)
        .frame(width: SettingsView.width, height: 540)
    }
}

private extension View {
    /// The small maps' colours are made for a card: the sample sits on one, whatever the form's own ground.
    func sampleGround() -> some View {
        padding(.horizontal, 6).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: Palette.card)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: Palette.floatLine), lineWidth: 0.5))
    }
}
