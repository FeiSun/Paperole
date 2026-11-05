import AppKit
import SwiftUI

// Help (UI v4, mac/UX.md §40.7; design/ui-v4 BRIEF §8, mockup `help()`): the Help menu, the Paperole Help window with
// its topics, the system search field's Help Topics, the pages' "?" and the one-time tips. The captions, footnotes and
// keys that left the pages live here; each row's picture is drawn by the app's own views from static synthetic data.

/// A topic of the Help window, in the sidebar's order.
enum HelpTopic: String, CaseIterable, Identifiable {
    case gettingStarted = "Getting Started"
    case paperMap = "Reading the Paper Map"
    case following = "Following and Review"
    case studentPage = "The Student Page"
    case allStudents = "All Students and Your Move"
    case statusSigns = "Status Signs"
    case shortcuts = "Keyboard Shortcuts"

    var id: String { rawValue }
    var title: String { rawValue }

    /// The topic of the page in front (⌘?): the hierarchy's page, else the paper's level, else Getting Started.
    static func of(hub: HubPage?, level: Level?) -> HelpTopic {
        switch hub {
        case .allStudents?, .yourMove?: return .allStudents
        case .student?: return .studentPage
        case nil: break
        }
        switch level {
        case .overview?: return .paperMap
        case .review?: return .following
        case nil: return .gettingStarted
        }
    }

    /// `help <topic>`: its title, any case, or its case name.
    init?(argument a: String) {
        let t = a.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).lowercased()
        guard let topic = Self.allCases.first(where: { $0.rawValue.lowercased() == t || "\($0)".lowercased() == t }) else { return nil }
        self = topic
    }
}

/// A row of a topic's page: its picture, its name (h3) and one or two sentences. A row without a picture leaves the
/// picture column empty, so the words line up.
struct HelpSection: Identifiable {
    let title: String
    let text: String
    var picture: HelpPicture?
    var id: String { title }
}

/// A row's picture, drawn by `HelpPictureView`.
enum HelpPicture {
    case bySection, closing, turnaround, topics, wellDone, nextDraft, firstDrafts, response
    case mapKey(MapKeyRow), strip, miniMap, timeline, lanes, earlier
    /// The column beside the scroller, drawn from its own glyphs on a piece of white page (design/review-page/BRIEF.md
    /// E9): rings with ticks beside them and a capsule; a find's ticks and a run with its current match.
    case lane
    case glyph(StatusGlyph), notFound
    case keys([String])
}

/// What the Help window says, topic by topic.
enum HelpContent {
    static func lead(_ t: HelpTopic) -> String {
        switch t {
        case .gettingStarted:
            return "A student’s paper, round by round: you comment on the PDF, the student revises, and each comment is followed into the next draft."
        case .paperMap:
            return "One paper across its rounds, newest on top: each row is a round, and each cell a section, as long as the section is."
        case .following:
            return "Follow anything on the map to see it across rounds, and open Review to answer the round’s comments."
        case .studentPage:
            return "One student’s papers and rounds, never compared with other students. Each comment belongs to the round it was written in."
        case .allStudents:
            // the first sentence was Your Move's empty state's second (README §5, 07)
            return "A paper comes to Your Move when a student’s round comes in, until you finish it. All Students shows every paper by whose move it is."
        case .statusSigns:
            return "One sign for each state of a paper, drawn the same in the sidebar, the cards, the rows and the headers."
        case .shortcuts:
            return "Every action has a button or a menu item; these keys are the short way."
        }
    }

    /// The topic's rows; The Student Page's counting rules follow its seven charts (`counting`).
    static func sections(_ t: HelpTopic) -> [HelpSection] {
        switch t {
        case .gettingStarted: return gettingStarted
        case .paperMap: return paperMap
        case .following: return following
        case .studentPage: return studentPage + counting
        case .allStudents: return allStudents
        case .statusSigns: return statusSigns
        case .shortcuts: return shortcuts
        }
    }

    /// The Student Page's rows from `counting` on are its counting rules, under their own heading.
    static let countingHeading = "How the charts count"

    static let gettingStarted: [HelpSection] = [
        HelpSection(title: "Add a paper", text: "New Paper… in File or at the foot of the sidebar names the paper and its student. Import… lists review folders you have, or brings back an export or a backup.",
                    picture: .glyph(.noRounds)),
        HelpSection(title: "Start Round 1", text: "Start it with the student’s LaTeX folder or .zip: Paperole builds the PDF, and never writes into the student’s folder.",
                    picture: .glyph(.ring(0))),
        HelpSection(title: "Comment on the PDF", text: "Select words and choose Comment on the bar that appears, or ⌥-drag a box round a figure, table or equation. Each comment is tied to the LaTeX source, so it is found again in the next draft."),
        HelpSection(title: "Send it back", text: "Finish Round 1… writes the round’s final.pdf with your comments for the student. Nothing is sent: you send the PDF.",
                    picture: .glyph(.waiting)),
        HelpSection(title: "The next draft", text: "New Round…, or the student’s folder or .zip dropped on the paper or its row in the sidebar, brings in the next draft. The comments still open are carried into it, each waiting for your answer.",
                    picture: .glyph(.ring(0.4))),
        HelpSection(title: "Finish the paper", text: "Mark as Finished, in the paper’s menu in the sidebar, once nothing more will come. Its rounds and comments stay.",
                    picture: .glyph(.finished)),
    ]

    /// `MapKey.items` (the old Full Key) with the strip, less what Following and Review says.
    static var paperMap: [HelpSection] {
        let pictures: [Int: HelpPicture] = [0: .miniMap, 1: .mapKey(.shades), 2: .mapKey(.folded), 4: .mapKey(.toCheck),
                                            5: .mapKey(.unasked), 6: .mapKey(.band)]
        let items = MapKey.items.enumerated().filter { !MapKey.following.contains($0.offset) }
            .map { HelpSection(title: $0.element.0, text: $0.element.1, picture: pictures[$0.offset]) }
        return [items[0],
                HelpSection(title: "The pages", text: "Over the map, the pages of the round shown, each with its number and its comments to check. A page’s help tag gives its comments and edits; a click follows it. The key page has a bookmark. Rest the pointer on a round’s row of the map to see its pages; a click keeps them.",
                            picture: .strip)]
            + items.dropFirst()
    }

    static var following: [HelpSection] {
        [HelpSection(title: "Follow anything", text: OverviewTip.text)]
            + MapKey.following.map { HelpSection(title: MapKey.items[$0].0, text: MapKey.items[$0].1) }
            + [
                HelpSection(title: "Review", text: "Continue Round N in the toolbar, or a double click on the map, opens the round’s PDF with its comments beside it. Back returns to the map."),
                HelpSection(title: "Marks beside the scroller", text: "A ring marks a comment or an unasked edit still to check, a capsule several close together, and a short tick an edit; while you find, ticks and bars mark the matches. Rest the pointer on a mark to see what is there; click it, or a row, to go there.",
                            picture: .lane),
                HelpSection(title: "Answering", text: AnswerTip.text + " Follow up asks again in the round’s final.pdf; Resolve and Keep as is close the comment.",
                            picture: .glyph(.ring(0.4))),
                HelpSection(title: "Unasked edits", text: "The Changes tab lists the student’s edits that no comment asked for. Mark each one checked once you have looked at it, or comment on it.",
                            picture: .mapKey(.unasked)),
                HelpSection(title: "Finishing a round", text: "When nothing is left to check, Finish Round N… writes the round’s final.pdf for the student, with your follow-ups and new comments. Nothing is sent.",
                            picture: .glyph(.ready)),
                HelpSection(title: "Paragraphs to read", text: "With reading marks on in Settings › Reading, each changed paragraph is marked until you have read it.",
                            picture: .glyph(.ring(1))),
            ]
    }

    /// The mockup's seven rows, verbatim.
    static let studentPage: [HelpSection] = [
        HelpSection(title: "By section", text: "Comments by standard section, one row per paper, in the paper map’s shades. Headings are matched to Abstract, Intro, Methods, Results and Conclusion; Map Headings… in the context menu changes a match.",
                    picture: .bySection),
        HelpSection(title: "Closing", text: "Comments closed after one round, two, or three or more: resolved, or kept as is. The headline gives the closed comments out of all the student’s comments. To check waits for you; still open includes those you followed up. Show by Topic in the context menu splits them by topic.",
                    picture: .closing),
        HelpSection(title: "Turnaround", text: "One row per round: first your days from its arrival to its return, then the student’s days to the next round, waiting included. From the second trip on, the headline gives the medians; an open round counts so far.",
                    picture: .turnaround),
        HelpSection(title: "Topics", text: "Comments by tag, one bar per paper on a shared scale. A comment with two tags appears in both rows, so rows can add up to more than the total; Not tagged counts the rest.",
                    picture: .topics),
        HelpSection(title: "Well done", text: "Comments you tagged Well done, never counted as problems. The header gives their number; point at it for the latest in your words, click it for all of them.",
                    picture: .wellDone),
        HelpSection(title: "For the next draft", text: "Up to two topics with three or more comments still open, each with your line for it and one of the student’s sentences. Copy for the Email puts the English lines and sentences on the clipboard; nothing is sent.",
                    picture: .nextDraft),
        HelpSection(title: "First drafts", text: "Each first draft’s comments by topic, with its pages, once later rounds make it differ from Topics. Trend words start at the third first draft of similar length.",
                    picture: .firstDrafts),
    ]

    /// The tiles' old captions and footnotes (`HelpText.studentPage`), with the rules the v4 figures follow (plan D4–D6,
    /// §5 R3, R25), under `countingHeading`.
    static var counting: [HelpSection] {
        let extra: [String: String] = [
            "Closing": "To check is the open round’s comments still waiting for your answer; still open is every other open comment.",
            "Turnaround": "With an even number of trips the median is the mean of the middle two, rounded to whole days, its exact value in the help tag; under a day reads “<1 d”.",
            "Topics": "Well done is not a topic: a comment tagged only Well done counts in Not tagged.",
        ]
        return HelpText.studentPage.map { HelpSection(title: $0.topic, text: $0.text + (extra[$0.topic].map { " " + $0 } ?? "")) }
            + [HelpSection(title: "The response", text: "Under a waiting paper’s figure, what the student did with the comments carried into the round: revised, explained (a note, no edit) or unchanged. From Round 3, not asked counts those left open in the round before without an answer, so the student was not asked about them; they are not counted as unchanged.",
                           picture: .response)]
    }

    static var allStudents: [HelpSection] {
        let hub = Dictionary(HelpText.hub.map { ($0.topic, $0.text) }, uniquingKeysWith: { a, _ in a })
        return [
            HelpSection(title: "Board", text: "Three lanes: Your move, the papers that wait on you, oldest first; With students, the longest away first; Finished, the papers finished in the last eight weeks, newest first. Every paper is in one lane; one whose folder is missing is with the students’ papers, in the sidebar’s words.",
                        picture: .lanes),
            HelpSection(title: "Earlier", text: "The papers finished before that are under Earlier · N, at the foot of Finished. A click shows them in place, another hides them.",
                        picture: .earlier),
            HelpSection(title: "A paper’s card", text: "The student and, in the corner, the days since the round came in or was sent back; the title; its small map; and the figure for its state (Status Signs). Point at the corner for the date, at the title for its rounds and comments."),
            HelpSection(title: "Small maps", text: hub["Small maps"] ?? "", picture: .miniMap),
            HelpSection(title: "Rounds in the year", text: hub["Rounds in 2026"] ?? "", picture: .timeline),
            HelpSection(title: "Your Move", text: "One row per paper that waits on you, the oldest first, its Continue the one prominent button. Under them, With students lists the papers the students have, the longest away first, with the days since each was sent back. "
                        + (hub["Your Move"] ?? ""), picture: .glyph(.ring(0))),
            HelpSection(title: "Students", text: "Board | Students shows each student’s papers under the student’s name, rounds and comments; a click on the name opens the student’s page. Point at Board | Students for how many students, papers and rounds there are."),
        ]
    }

    static let statusSigns: [HelpSection] = [
        HelpSection(title: "To check", text: "The round waits on you: comments or edits to check, none answered yet.", picture: .glyph(.ring(0))),
        HelpSection(title: "Partly answered", text: "The ring fills clockwise as you answer; point at it for how many are answered so far.", picture: .glyph(.ring(0.4))),
        HelpSection(title: "Paragraphs to read", text: "Every comment answered; changed paragraphs still to read, with reading marks on.", picture: .glyph(.ring(1))),
        HelpSection(title: "First draft", text: "Round 1 came in and waits for your comments: the empty ring, with “First draft”.", picture: .glyph(.ring(0))),
        HelpSection(title: "Ready to finish", text: "Nothing is left to check in the round; finish it when you are ready. Only this sign is the Sage check.", picture: .glyph(.ready)),
        HelpSection(title: "Nothing waits", text: "Your Move with no paper waiting: the ring in grey. It is not the Sage check, which means Ready to finish.", picture: .glyph(.nothingWaits)),
        HelpSection(title: "With the student", text: "The round was sent back to the student; the days count from the day it was sent back.", picture: .glyph(.waiting)),
        HelpSection(title: "Finished", text: "The paper is finished; its rounds and comments stay.", picture: .glyph(.finished)),
        HelpSection(title: "Build failed", text: "The round’s LaTeX did not build; its words say which round.", picture: .glyph(.failed)),
        HelpSection(title: "No rounds yet", text: "The paper has no round; start Round 1.", picture: .glyph(.noRounds)),
        HelpSection(title: "Well done", text: "Comments you tagged Well done: the star and their number in the student’s header.", picture: .glyph(.wellDone)),
        HelpSection(title: "Not found", text: "Red is only for an error, always with its triangle: a comment whose text is gone, or a paper whose folder is missing.", picture: .notFound),
    ]

    /// mac/UX.md §9 and the menus' keys.
    static let shortcuts: [HelpSection] = [
        HelpSection(title: "Paperole Help", text: "Opens this window at the topic of the page in front.", picture: .keys(["⌘?"])),
        HelpSection(title: "Jump to…", text: "Find a paper, a round, a section or a command by its name.", picture: .keys(["⌘K"])),
        HelpSection(title: "Back and Forward", text: "Through the pages and papers you have opened, as in Finder.", picture: .keys(["⌘[", "⌘]"])),
        HelpSection(title: "New Paper…", text: "A new paper and its student.", picture: .keys(["⌘N"])),
        HelpSection(title: "Show or Hide the Sidebar", text: "Showing it again also ends Focus.", picture: .keys(["⌃⌘S"])),
        HelpSection(title: "On the map", text: "Once the map has the keys (a click on it), ← → move along a round and ↑ ↓ to the round above or below. Return opens Review there; Esc follows nothing.",
                    picture: .keys(["←", "→", "↑", "↓"])),
        HelpSection(title: "Next and previous card", text: "In Review’s list, skipping a folded group; on the Changes tab, the next or previous edit.", picture: .keys(["J", "K"])),
        HelpSection(title: "Resolve, Follow up, Keep as is", text: "On a comment to check; the same key again clears the answer. V on an edit marks it checked. An answer moves on to the next comment to check.",
                    picture: .keys(["V", "R", "W"])),
        HelpSection(title: "Comment", text: "On selected words or a box: the comment’s note. ⌘Return saves it, or sends a card’s follow-up.", picture: .keys(["Return"])),
        HelpSection(title: "Box and sticky note", text: "B, or ⌥-drag, draws a box round a figure, table or equation; ⌥-click puts a sticky note.", picture: .keys(["B", "⌥"])),
        HelpSection(title: "Colour and kind", text: "Of the selection’s mark or the card’s: 1–6 its colour, H, U or S a highlight, underline or strikeout.", picture: .keys(["1–6", "H"])),
        HelpSection(title: "Undo and Redo", text: "An answer, or a mark’s new colour or kind, in the open round.", picture: .keys(["⌘Z", "⇧⌘Z"])),
        HelpSection(title: "Focus", text: "The PDF and one card, without the sidebar.", picture: .keys(["F"])),
        HelpSection(title: "Find in the paper", text: "⌘G and ⇧⌘G go to the next and previous match.", picture: .keys(["⌘F", "⌘G"])),
        HelpSection(title: "Zoom", text: "In, out, actual size and fit width.", picture: .keys(["⌘+", "⌘−", "⌘0", "⌘9"])),
        HelpSection(title: "Reading", text: "With reading marks on in Settings › Reading: the next changed paragraph to read, mark it read, mark its section read.",
                    picture: .keys(["N", "C", "⇧C"])),
        HelpSection(title: "Leave", text: "Esc cancels the note, the find or re-anchoring, and clears the selection.", picture: .keys(["Esc"])),
    ]

    /// A search's hits, by section, titles first, then words; one hit per title.
    static func search(_ query: String) -> [HelpHit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let all = HelpTopic.allCases.flatMap { t in sections(t).map { HelpHit(topic: t, section: $0.title, text: $0.text) } }
        let titled = all.filter { $0.section.localizedCaseInsensitiveContains(q) || $0.topic.title.localizedCaseInsensitiveContains(q) }
        let worded = all.filter { $0.text.localizedCaseInsensitiveContains(q) }
        var seen = Set<String>(), out: [HelpHit] = []
        for h in titled + worded where seen.insert(h.section).inserted { out.append(h) }
        return out
    }
}

/// A section found by a search, in the system's Help menu or the window's field.
struct HelpHit: Hashable {
    let topic: HelpTopic
    let section: String
    var text = ""
}

/// The Help window's state: the topic shown and the section to bring into view.
@MainActor
final class HelpModel: ObservableObject {
    @Published var topic: HelpTopic = .gettingStarted
    /// The section brought into view (a search's pick, About This Chart), once.
    @Published var section: String?
    @Published var query = ""
    /// Opens the window (the main window's `openWindow`). Never called in a --background run (plan §5 R23): there Help
    /// opens only by the `help` debug item, behind every window.
    var opener: (() -> Void)?

    func show(_ t: HelpTopic, section s: String? = nil) {
        topic = t
        section = s
        query = ""
        if !LaunchOptions.background { opener?() }
    }
}

extension AppModel {
    /// The topic of the page in front.
    var helpTopic: HelpTopic { HelpTopic.of(hub: hub, level: hub == nil && selectedPath != nil ? level : nil) }

    func openHelp(_ t: HelpTopic? = nil, section: String? = nil) { help.show(t ?? helpTopic, section: section) }
}

// MARK: - The Help menu and the system's search field

/// The Help menu (BRIEF §8, 08): Paperole Help ⌘?, Keyboard Shortcuts, a separator, Show Tips Again. The system's
/// search field above them lists Help's sections under Help Topics (`HelpSearch`).
enum HelpMenu {
    enum Item: Equatable { case help, shortcuts, separator, tips }
    static let items: [Item] = [.help, .shortcuts, .separator, .tips]

    static func title(_ i: Item) -> String {
        switch i {
        case .help: return "Paperole Help"
        case .shortcuts: return "Keyboard Shortcuts"
        case .separator: return "-"
        case .tips: return "Show Tips Again"
        }
    }
}

struct HelpCommands: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ForEach(Array(HelpMenu.items.enumerated()), id: \.offset) { _, i in
            switch i {
            case .help:
                // ⌘? off in a test run, which never brings a window to the front (plan §5 R23)
                Button(HelpMenu.title(i)) { model.openHelp() }
                    .keyboardShortcut("?", modifiers: .command)
                    .disabled(LaunchOptions.background)
            case .shortcuts: Button(HelpMenu.title(i)) { model.openHelp(.shortcuts) }.disabled(LaunchOptions.background)
            case .separator: Divider()
            case .tips: Button(HelpMenu.title(i)) { model.actions.tips.showAgain() }
            }
        }
    }
}

/// The system's search field in the Help menu: Help's sections under Help Topics; a pick opens the section.
final class HelpSearch: NSObject, NSUserInterfaceItemSearching {
    static let shared = HelpSearch()

    func searchForItems(withSearch searchString: String, resultLimit: Int, matchedItemHandler handleMatchedItems: @escaping ([Any]) -> Void) {
        handleMatchedItems(Array(HelpContent.search(searchString).prefix(resultLimit)))
    }

    func localizedTitles(forItem item: Any) -> [String] { (item as? HelpHit).map { [$0.section] } ?? [] }

    func performAction(forItem item: Any) {
        guard let h = item as? HelpHit else { return }
        MainActor.assumeIsolated { AppModel.current?.openHelp(h.topic, section: h.section) }
    }
}

// MARK: - The Help window

/// The Help window (mockup `help()`): the topics in a sidebar under Search Help; the page an h2, a lead sentence, then
/// rows of a picture and an h3 with one or two sentences.
struct HelpView: View {
    @ObservedObject var help: HelpModel

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { help.query.isEmpty ? help.topic : nil },
                                    set: { if let t = $0 { help.topic = t; help.section = nil } })) {
                if help.query.isEmpty {
                    ForEach(HelpTopic.allCases) { t in Text(t.title).tag(t) }
                } else {
                    ForEach(HelpContent.search(help.query), id: \.self) { h in
                        Button { help.show(h.topic, section: h.section) } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(h.section).foregroundStyle(Ink.label)
                                Text(h.topic.title).font(TypeScale.small).foregroundStyle(Ink.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .searchable(text: $help.query, placement: .sidebar, prompt: "Search Help")
            .navigationSplitViewColumnWidth(220)
        } detail: {
            HelpPage(topic: help.topic, section: help.section)
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}

/// A topic's page.
struct HelpPage: View {
    let topic: HelpTopic
    var section: String?

    var body: some View {
        let rows = HelpContent.sections(topic)
        let counting = topic == .studentPage ? HelpContent.studentPage.count : nil
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(topic.title).font(TypeScale.title1)
                    Text(HelpContent.lead(topic)).font(TypeScale.body).foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 4).padding(.bottom, 24)
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, s in
                        if i == counting {
                            Text(HelpContent.countingHeading).font(TypeScale.callout.weight(.semibold)).foregroundStyle(Ink.secondary)
                                .padding(.top, 32).padding(.bottom, 8)
                        }
                        HelpRow(section: s).id(i)
                    }
                }
                .padding(EdgeInsets(top: 40, leading: 48, bottom: 32, trailing: 48))
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(-1)  // the page's top, its padding included
            }
            // a section by its first row of that name (the counting rules repeat the charts' names)
            .onAppear { if let i = rows.firstIndex(where: { $0.title == section }) { proxy.scrollTo(i, anchor: .top) } }
            .onChange(of: section) { _, s in
                if let i = rows.firstIndex(where: { $0.title == s }) { withAnimation { proxy.scrollTo(i, anchor: .top) } }
            }
            .onChange(of: topic) { _, _ in if section == nil { proxy.scrollTo(-1, anchor: .top) } }
        }
        .background(Color(nsColor: Palette.card))
        .foregroundStyle(Ink.label)
    }
}

/// A row (mockup `.hitem`): the picture in a 176 pt column, 32 apart, the h3 13 semibold and its words in label2, a
/// hairline above.
struct HelpRow: View {
    let section: HelpSection

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color(nsColor: Palette.rule)).frame(height: 1)
            HStack(alignment: .center, spacing: 32) {
                Group {
                    if let p = section.picture { HelpPictureView(picture: p) } else { Color.clear.frame(height: 1) }
                }
                .frame(width: 176, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.title).font(TypeScale.body.weight(.semibold))
                    Text(section.text).font(TypeScale.body).foregroundStyle(Ink.label2).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 16)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A row's picture (mockup `.hp-*`), in the data ink ramp and the app's own signs.
struct HelpPictureView: View {
    let picture: HelpPicture
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = MapInk(dark: scheme == .dark)
        switch picture {
        case .bySection:
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 3), count: 4), alignment: .leading, spacing: 3) {
                ForEach(Array([2, 4, 2, 6, 1, 3, 4, 6].enumerated()), id: \.offset) { _, v in
                    Text("\(v)").font(.system(size: 11, weight: .semibold)).foregroundStyle(ink.color(.label))
                        .frame(width: 32, height: 22)
                        .background(RoundedRectangle(cornerRadius: 4).fill(ink.color(.cell(v <= 2 ? 1 : v == 3 ? 2 : 3))))
                }
            }
            .frame(width: 140, alignment: .leading)
        case .closing:
            bar([(12, ink.color(.c1), false), (14, .clear, true), (4, .clear, false)], ink: ink, width: 150)
        case .turnaround:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    segment(.clear, width: 24, outlined: true, ink: ink)
                    Text("so far").font(TypeScale.small).foregroundStyle(Ink.secondary)
                }
                HStack(spacing: 2) {
                    segment(ink.color(.you), width: 24, ink: ink)
                    segment(ink.color(.stu), width: 144, ink: ink)
                }
            }
        case .topics:
            VStack(alignment: .leading, spacing: 6) {
                ForEach([9, 7, 5], id: \.self) { n in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(ink.color(.ink)).frame(width: CGFloat(n) * 12, height: 8)
                        Text("\(n)").font(TypeScale.small).foregroundStyle(Ink.label2)
                    }
                }
            }
        case .wellDone:
            VStack(alignment: .leading, spacing: 4) {
                Text("The ablation in Table 3 answers exactly the question a reviewer would ask.")
                    .font(.system(size: 12, design: .serif).italic()).foregroundStyle(Ink.label)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Curriculum Signals\nRound 1 · p.4").font(TypeScale.small).foregroundStyle(Ink.secondary)
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .frame(width: 176, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: Palette.float))
                .shadow(color: .black.opacity(0.1), radius: 2, y: 1))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: Palette.floatLine), lineWidth: 0.5))
        case .nextDraft:
            VStack(alignment: .leading, spacing: 6) {
                Text("Logic & claims").font(TypeScale.callout.weight(.semibold))
                Text("Because easy examples come first, the student model learns…").font(.system(size: 12, design: .serif))
                    .foregroundStyle(Ink.label2).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) { Rectangle().fill(Color(nsColor: Palette.rule)).frame(width: 2) }
            }
        case .firstDrafts:
            VStack(spacing: 0) {
                ForEach(Array([("", "8 pp", "9 pp"), ("Clarity", "3", "6"), ("Logic", "4", "3")].enumerated()), id: \.offset) { i, r in
                    HStack(spacing: 0) {
                        Text(r.0).frame(width: 72, alignment: .leading)
                        Text(r.1).frame(width: 32, alignment: .trailing)
                        Text(r.2).frame(width: 32, alignment: .trailing)
                    }
                    .font(TypeScale.small).foregroundStyle(i == 0 ? Ink.secondary : Ink.label2)
                    .frame(height: 20)
                    .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: Palette.rule)).frame(height: 0.5) }
                }
            }
        case .response:
            HStack(spacing: 2) {
                ForEach(Array([11, 1, 2, 1].enumerated()), id: \.offset) { i, n in
                    RoundedRectangle(cornerRadius: 2).fill(ink.color(ResponseBar.roles[i])).frame(width: CGFloat(n) * 10, height: 8)
                }
            }
        case .mapKey(let r):
            MapKeyPopover.picture(r, steps: [2, 3, 4], ink: ink)
        case .strip:
            HStack(spacing: 12) {
                ForEach([(1, 3), (2, 2), (3, 0)], id: \.0) { p, n in
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(ink.color(.thumb)).frame(width: 30, height: 40)
                            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color(nsColor: Palette.rule), lineWidth: 0.5))
                        HStack(spacing: 4) {
                            Text("\(p)").foregroundStyle(Ink.secondary)
                            if n > 0 {
                                StatusGlyphView(.ring(0), size: 10)
                                Text("\(n)").fontWeight(.semibold).foregroundStyle(Ink.label2)
                            }
                        }
                        .font(TypeScale.small)
                    }
                }
            }
        case .lane:
            Canvas { ctx, _ in
                func glyph(_ g: StripLayout.Glyph, at x: CGFloat, grown: Bool = false) {
                    let (r0, stroke) = StripLayout.box(g, grown: grown)
                    let r = r0.offsetBy(dx: x - StripLayout.axis, dy: 0)
                    let ink: NSColor = switch g.shape {
                    case .ring, .capsule: LaneInk.ring
                    case .tick, .unaskedTick: LaneInk.edit
                    case .findTick, .run: LaneInk.find
                    }
                    if stroke > 0 {
                        let p = r.insetBy(dx: stroke / 2, dy: stroke / 2)
                        ctx.stroke(Path(roundedRect: p, cornerRadius: p.width / 2), with: .color(Color(nsColor: ink)), lineWidth: stroke)
                    } else {
                        ctx.fill(Path(roundedRect: r, cornerRadius: min(r.width, r.height) / 2), with: .color(Color(nsColor: ink)))
                    }
                }
                func g(_ s: StripLayout.Shape, _ y: CGFloat, _ lo: CGFloat? = nil, _ hi: CGFloat? = nil) -> StripLayout.Glyph {
                    StripLayout.Glyph(shape: s, y: y, lo: lo ?? y - 1, hi: hi ?? y + 1, members: [], id: "")
                }
                for y: CGFloat in [12, 48] { glyph(g(.ring, y, y - 3.5, y + 3.5), at: 50); glyph(g(.tick, y), at: 50) }
                glyph(g(.capsule, 28, 22.5, 33.5), at: 50)
                glyph(g(.unaskedTick, 26), at: 50)
                glyph(g(.findTick, 12), at: 128)
                glyph(g(.run, 22, 22, 36), at: 128)
                let cur = StripLayout.currentBox(y: 30, grown: false).offsetBy(dx: 128 - StripLayout.axis, dy: 0)
                ctx.fill(Path(roundedRect: cur, cornerRadius: 1.5), with: .color(Color(nsColor: LaneInk.selected)))
                glyph(g(.findTick, 48), at: 128)
            }
            .frame(width: 168, height: 60)
            // a piece of the page, white in both appearances, as the column always lies on it
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: Palette.rule), lineWidth: 0.5))
        case .miniMap:
            MiniMapView(map: HelpPictureView.miniMap, width: 112, cell: 8, gap: 4)
        case .timeline:
            Canvas { ctx, size in
                let y = size.height / 2
                func line(_ a: CGFloat, _ b: CGFloat, _ c: Color, dotted: Bool = false) {
                    var p = Path()
                    p.move(to: CGPoint(x: a, y: y))
                    p.addLine(to: CGPoint(x: b, y: y))
                    ctx.stroke(p, with: .color(c), style: StrokeStyle(lineWidth: 2, lineCap: dotted ? .round : .butt, dash: dotted ? [0.1, 4] : []))
                }
                line(4, 44, ink.color(.ink))
                line(44, 110, ink.color(.ink), dotted: true)
                line(110, 160, ink.color(.attention))
                for x in [4.0, 110.0] { ctx.fill(Path(ellipseIn: CGRect(x: x - 4, y: y - 4, width: 8, height: 8)), with: .color(ink.color(.ink))) }
                ctx.fill(Path(ellipseIn: CGRect(x: 104, y: y - 6, width: 12, height: 12)), with: .color(Color(nsColor: Palette.card)))
                ctx.stroke(Path(ellipseIn: CGRect(x: 105, y: y - 5, width: 10, height: 10)), with: .color(ink.color(.attention)), lineWidth: 1.5)
                var today = Path()
                today.move(to: CGPoint(x: 164, y: 0))
                today.addLine(to: CGPoint(x: 164, y: size.height))
                ctx.stroke(today, with: .color(ink.color(.today)), lineWidth: 1)
            }
            .frame(width: 170, height: 20)
        case .lanes:
            VStack(alignment: .leading, spacing: 6) {
                lane(.ring(0), "Your move", 2)
                lane(.waiting, "With students", 1)
                lane(.finished, "Finished", 1)
            }
        case .earlier:
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                Text("Earlier · 3").font(TypeScale.callout)
            }
            .foregroundStyle(Ink.secondary)
        case .glyph(let g):
            StatusGlyphView(g, size: 17)
        case .notFound:
            Image(systemName: Status.notFound.icon).font(.system(size: 15)).foregroundStyle(Color(nsColor: Palette.danger))
        case .keys(let keys):
            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { k in
                    Text(k).font(TypeScale.callout.weight(.medium)).foregroundStyle(Ink.label2)
                        .padding(.horizontal, 6).frame(minWidth: 22, minHeight: 20)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: Palette.fill)))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: Palette.rule), lineWidth: 0.5))
                }
            }
        }
    }

    /// Two rounds of a short paper, the newer on top.
    static let miniMap = MiniMap(rows: [
        MiniMap.Row(n: 2, cells: [.init(start: 0, end: 1, level: 1), .init(start: 1, end: 3, level: 2), .init(start: 3, end: 6, level: 3),
                                  .init(start: 6, end: 8, level: 1)], pages: 8, count: 14),
        MiniMap.Row(n: 1, cells: [.init(start: 0, end: 1, level: 1), .init(start: 1, end: 3, level: 2), .init(start: 3, end: 5, level: 2),
                                  .init(start: 5, end: 7, level: 1)], pages: 7, count: 14),
    ], pages: 8)

    private func bar(_ parts: [(CGFloat, Color, Bool)], ink: MapInk, width: CGFloat) -> some View {
        let total = parts.map(\.0).reduce(0, +)
        return HStack(spacing: 2) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                segment(p.1, width: (width - 2 * CGFloat(parts.count - 1)) * p.0 / total, outlined: p.2, ink: ink)
            }
        }
        .background(RoundedRectangle(cornerRadius: 2).fill(ink.color(.track)))
    }

    private func segment(_ c: Color, width: CGFloat, outlined: Bool = false, ink: MapInk) -> some View {
        RoundedRectangle(cornerRadius: 2).fill(c).frame(width: width, height: 12)
            .overlay(outlined ? RoundedRectangle(cornerRadius: 2).strokeBorder(ink.color(.attention), lineWidth: 1.5) : nil)
    }

    private func lane(_ g: StatusGlyph, _ name: String, _ n: Int) -> some View {
        HStack(spacing: 6) {
            StatusGlyphView(g, text: 12)
            Text(name).font(TypeScale.callout.weight(.semibold))
            Text("\(n)").font(TypeScale.callout).foregroundStyle(Ink.secondary)
        }
    }
}

// MARK: - The pages' "?" and the tips

/// The standard round "?" at the bottom right of an overview page's content (BRIEF §2 Help entry; mockup `.hlrow`),
/// 24 below it, scrolling with it; it opens the page's topic.
struct PageHelpLink: View {
    let model: AppModel
    let topic: HelpTopic

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            HelpLink { model.openHelp(topic) }
                .help(topic.title)
        }
        .padding(.top, 24)
    }
}

/// A one-time tip in the layout (mockup `.itip`; BRIEF 03): a card with a 1 pt hairline, 8 pt corners, an arrow at the
/// top pointing at `arrow` (from its leading edge), the title 13 semibold over one sentence in secondary, and a
/// borderless Sage Got it. It pushes what is under it down.
struct InlineTip: View {
    let title: String
    let text: String
    var arrow: CGFloat?
    let gotIt: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 24) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(TypeScale.body.weight(.semibold)).foregroundStyle(Ink.label)
                Text(text).font(TypeScale.body).foregroundStyle(Ink.secondary)
            }
            // plain, so it is drawn in the Sage text colour (a borderless button draws its title in the label colour)
            Button("Got it", action: gotIt)
                .buttonStyle(.plain)
                .foregroundStyle(Ink.accentText)
                .fixedSize()
                .help("Do not show this tip again")
        }
        .padding(.vertical, 12).padding(.horizontal, 16)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: Palette.card)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: Palette.floatLine), lineWidth: 1))
        .overlay(alignment: .topLeading) {
            if let x = arrow {
                TipArrow().frame(width: 14, height: 8).offset(x: x - 7, y: -7)
            }
        }
        .padding(.top, arrow == nil ? 0 : 7)
        .accessibilityElement(children: .contain)
    }
}

/// The tip's arrow: the top half of a 10 pt square turned 45°, in the card's fill with the hairline on its two sides.
private struct TipArrow: View {
    var body: some View {
        Canvas { ctx, size in
            var edge = Path()
            edge.move(to: CGPoint(x: 0, y: size.height - 1))
            edge.addLine(to: CGPoint(x: size.width / 2, y: 0.5))
            edge.addLine(to: CGPoint(x: size.width, y: size.height - 1))
            var fill = edge
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            ctx.fill(fill, with: .color(Color(nsColor: Palette.card)))
            ctx.stroke(edge, with: .color(Color(nsColor: Palette.floatLine)), lineWidth: 1)
        }
    }
}

/// The paper page's first-use tip, Follow anything (BRIEF 03): under the map at the left, its arrow at the bottom row's
/// second cell; gone after Got it or the first follow.
struct OverviewTip: View {
    @ObservedObject var tips: Tips
    /// The map's first cell's x and the cell pointed at's mid x (nil as a table: no arrow).
    let x0: CGFloat
    let arrow: CGFloat?

    static let title = "Follow anything"
    static let text = "Click a section, round, page or comment to see it across rounds. Double-click opens Review."

    var body: some View {
        if tips.follow {
            InlineTip(title: Self.title, text: Self.text, arrow: arrow.map { $0 - x0 }) { tips.dismiss(.follow) }
                .padding(.leading, x0)
        }
    }

    /// Where the tip sits and points on a map: its left edge at the bottom row's first cell, the arrow at the second.
    static func place(_ scene: MapScene?) -> (x0: CGFloat, arrow: CGFloat?) {
        guard let row = scene?.rows.last, let first = row.cells.first else { return (0, nil) }
        return (first.rect.minX, (row.cells.count > 1 ? row.cells[1] : first).rect.midX)
    }
}
