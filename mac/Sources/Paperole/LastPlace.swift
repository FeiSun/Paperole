import AppKit
import Combine
import Foundation

// Opening where you left off (design/tags/TAGS.md §8; Settings › General "When Paperole opens"; UX.md §24): the
// window's place, kept in the app's defaults as `lastPlace` (a small JSON) a second after it changes and when the app
// quits, and opened again at launch. A test run (--background, a fixture, `swift test`) and a run with --paper or
// --hub never read it, and nothing is written for a paper given on the command line (the critique's fix).

/// The place as kept: the hierarchy's page, or a paper at its level, with the overview's place and Review's.
struct LastPlace: Codable, Equatable {
    var hub: String?
    var paper: String?
    var level: String?
    /// Review's round: nil when it was the latest (a newer one since is shown then).
    var round: Int?
    var comment: String?
    var change: String?
    var tab: String?
    /// The PDF's page in Review when no comment or change was selected (0-based).
    var page: Int?
    var follow: String?
    var strip: Int?
    var unfold = false
    var shownParts: [String] = []
    var overviewScroll: Double = 0
    var hubScroll: Double = 0

    static let key = "lastPlace"

    func json() -> String? { (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } }
    static func parse(_ s: String?) -> LastPlace? { s.flatMap { try? JSONDecoder().decode(LastPlace.self, from: Data($0.utf8)) } }
}

extension HubPage {
    /// The page as `--hub` names it: "all", "move", "student:<key>".
    var token: String {
        switch self {
        case .allStudents: return "all"
        case .yourMove: return "move"
        case .student(let k): return "student:" + k
        }
    }
}

extension OverviewItem {
    /// "section:<key>@<n>", "round:<n>", "page:<p>@<n>" (0-based), "comment:<id>", "tag:<id>".
    var token: String {
        switch self {
        case .section(let k, let n): return "section:\(k)@\(n)"
        case .round(let n): return "round:\(n)"
        case .page(let n, let p): return "page:\(p)@\(n)"
        case .comment(let id): return "comment:" + id
        case .tag(let id): return "tag:" + id
        }
    }

    init?(token t: String) {
        guard let colon = t.firstIndex(of: ":") else { return nil }
        let kind = t[..<colon], rest = String(t[t.index(after: colon)...])
        func at(_ s: String) -> (String, Int)? {
            guard let a = s.lastIndex(of: "@"), let n = Int(s[s.index(after: a)...]) else { return nil }
            return (String(s[..<a]), n)
        }
        switch kind {
        case "section": guard let (k, n) = at(rest) else { return nil }; self = .section(k, round: n)
        case "round": guard let n = Int(rest) else { return nil }; self = .round(n)
        case "page": guard let (p, n) = at(rest), let pp = Int(p) else { return nil }; self = .page(round: n, page: pp)
        case "comment": self = .comment(rest)
        case "tag": self = .tag(rest)
        default: return nil
        }
    }
}

extension AppModel {
    /// Whether this run keeps and opens the last place: the real app, not a test run (`LaunchOptions.isTestRun`: a
    /// --no-list run wrote Dev's own), without a paper or page given at launch.
    var remembersPlace: Bool {
        !options.isTestRun && options.paper == nil && options.hub == nil && options.script == nil && options.scrollPerf == nil
    }

    /// The window's place now, as kept; nil for no paper and no page, or a paper given on the command line.
    var lastPlace: LastPlace? {
        if let h = hub {
            return LastPlace(hub: h.token, hubScroll: hubModel.liveScroll ?? hubModel.scrolls[h] ?? 0)
        }
        guard let path = selectedPath, papers.contains(where: { $0.path == path }), !isTransient(path) else { return nil }
        let r = reviewPlace, o = overview.place
        return LastPlace(paper: path, level: level.rawValue, round: viewingEarlierRound ? r.round : nil, comment: r.comment,
                         change: r.change, tab: r.tab.rawValue, page: r.comment == nil && r.change == nil ? pdf.shownPage : nil,
                         follow: o.selection?.token, strip: o.strip, unfold: o.unfold, shownParts: o.shownParts.map(\.rawValue).sorted(),
                         overviewScroll: o.scroll)
    }

    /// Keeps the place, when this run remembers it and the advisor wants it (Settings › General).
    func saveLastPlace() {
        guard remembersPlace, openAtLaunch == .lastPlace, let p = lastPlace, let s = p.json() else { return }
        if UserDefaults.standard.string(forKey: LastPlace.key) != s { UserDefaults.standard.set(s, forKey: LastPlace.key) }
    }

    /// Keeps the place a second after the window last changed (a paper, a level, a round, what is followed, a card),
    /// and when the app quits.
    func watchPlace() -> [AnyCancellable] {
        guard remembersPlace else { return [] }
        let changes = Publishers.Merge3(objectWillChange, overview.objectWillChange, panel.objectWillChange)
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.saveLastPlace() }
        let quit = NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.saveLastPlace() } }
        return [changes, quit]
    }

    /// At launch: the place kept, when the advisor wants it and it is still there; else nothing (All Students, as
    /// before). A paper no longer listed, or whose folder is gone, opens All Students; a round no longer there, the
    /// latest; what was followed or selected, when it is still there once the data comes.
    @discardableResult
    func openLastPlace(_ p: LastPlace?) -> Bool {
        guard let p else { return false }
        if let h = p.hub, let page = HubPage(argument: h) {
            if case .student(let k) = page, !studentGroups.contains(where: { $0.key == k }) { return false }
            setHub(page)
            hubModel.show(scroll: p.hubScroll)
            loadHub()
            return true
        }
        guard let path = p.paper, papers.contains(where: { $0.path == path }),
              FileManager.default.fileExists(atPath: path + "/ledger.json") else { return false }
        let review = p.level == Level.review.rawValue
        if review { setLevel(.review) }
        selectPaper(path)
        var place = OverviewPlace(selection: p.follow.flatMap(OverviewItem.init(token:)), strip: p.strip, unfold: p.unfold,
                                  shownParts: Set(p.shownParts.compactMap(FoldKind.init(rawValue:))), scroll: p.overviewScroll)
        if review { place.scroll = p.overviewScroll }
        overview.restore(place)
        setLevel(review ? .review : .overview)
        if review {
            if p.tab == PanelTab.changes.rawValue { tab = .changes }
            if p.tab == PanelTab.checks.rawValue && checksOn { tab = .checks }
            reveal(ReviewTarget(round: p.round, comment: p.comment, change: p.change, page: p.page))
        }
        return true
    }
}
