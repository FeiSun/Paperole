import AppKit
import Foundation

/// The hierarchy's data (OVERVIEW-v2 §3.1–3.2, UX.md §22): the engine's read-only `overview` of every listed paper
/// (without marks) with the advisor's Map Headings answers as `buckets`, and its `students`. Asked for when a page of
/// the hierarchy is shown and the papers, their answers or a paper's ledger may have changed since (`key`), or the app
/// became active again (a paper changed from the command line). Each page's scroll is kept for Back.
@MainActor
final class HubModel: ObservableObject {
    enum Status: Equatable { case idle, loading, loaded, failed(String) }

    @Published private(set) var data: [String: PaperOverview] = [:]
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var students: [StudentStats] = []
    @Published private(set) var status: Status = .idle
    /// A request is on its way: `status` stays `.loaded` meanwhile (the page keeps what it shows), so what decides
    /// from the data (Settings › Tags' Delete, Tag Comments…) waits for it (`AppModel.hubCurrent`).
    @Published private(set) var pending = false
    private var whenLoaded: [(Bool) -> Void] = []
    /// What the data was asked for with (papers, answers, the app's edits and activations): a new key asks again.
    private(set) var key: String?
    private var sequence = 0
    /// How long the last reply took, from the request to the data in the model (the debug hook `hub`).
    private(set) var loadMs: Double?
    private var begun: TimeInterval = 0
    /// The page's scroll view while it is shown (`HubScrollProbe`), each page's offset, and the one to put back.
    weak var scrollView: NSScrollView? { didSet { if scrollView !== oldValue { applyPendingScroll() } } }
    private(set) var scrolls: [HubPage: Double] = [:]
    private var pendingScroll: Double?
    /// The tag whose comments a student's page lists under Topics by round (UX.md §27), or nil.
    @Published var studentTag: StudentTagChoice?

    func begin(key: String) -> Int {
        sequence += 1
        self.key = key
        begun = ProcessInfo.processInfo.systemUptime
        if status != .loading && status != .loaded { status = .loading }
        if !pending { pending = true }
        return sequence
    }

    /// Runs once the request on its way has its reply (true) or failed (false).
    func afterLoad(_ f: @escaping (Bool) -> Void) { whenLoaded.append(f) }

    private func ran(_ ok: Bool) {
        pending = false
        let fs = whenLoaded
        whenLoaded = []
        for f in fs { f(ok) }
    }

    /// The reply to request `seq`; an older one is dropped. A failure keeps the data shown and says why.
    func finish(_ seq: Int, _ result: Result<OverviewReply, Error>) {
        guard seq == sequence else { return }
        switch result {
        case .success(let r):
            loadMs = ((ProcessInfo.processInfo.systemUptime - begun) * 10_000).rounded() / 10
            var d: [String: PaperOverview] = [:], e: [String: String] = [:]
            for p in r.papers {
                if let o = p.overview { d[p.path] = o } else if let m = p.error { e[p.path] = m }
            }
            if data != d { data = d }
            if errors != e { errors = e }
            let s = r.students ?? []
            if students != s { students = s }
            status = .loaded
            ran(true)
        case .failure(let err):
            key = nil  // asked again next time
            status = .failed(err.localizedDescription)
            ran(false)
        }
        applyPendingScroll()
    }

    /// The engine's numbers for a student's papers (the group with one of them).
    func stats(for paths: [String]) -> StudentStats? {
        students.first { s in s.papers.contains { paths.contains($0) } }
    }

    // MARK: Scrolling

    var liveScroll: Double? {
        guard let sv = scrollView, sv.window != nil else { return nil }
        return OverviewModel.offset(sv)
    }

    /// The page is left: its offset is kept for Back.
    func saveScroll(_ page: HubPage?) {
        guard let page, let y = liveScroll else { return }
        scrolls[page] = y
    }

    /// A page is shown: at the offset given (Back), else at its top.
    func show(scroll y: Double?) {
        pendingScroll = y ?? 0
        applyPendingScroll()
    }

    func applyPendingScroll(try n: Int = 0) {
        guard let y = pendingScroll, let sv = scrollView, sv.window != nil else { return }
        // the room under the toolbar too (its content insets): else an offset near the bottom waited 1.8 s
        if OverviewModel.room(sv) >= y || n >= 8 {
            OverviewModel.scroll(sv, to: y)
            pendingScroll = nil
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 * Double(n + 1)) { [weak self] in
            self?.applyPendingScroll(try: n + 1)
        }
    }
}
