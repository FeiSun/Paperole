import Foundation

/// The second, read-only engine process (FEATURES E1b; CONTRACT amendment "Overview": `prose` with `state: false`):
/// it finds the paragraphs of a paper's closed rounds that the overview reports `pending` (a folder from before, or
/// after the engine's PARSER changed), one round at a time, oldest first, so the paper map and the hierarchy get their
/// sections. The review's own engine never waits for it; the open round is found at ingest or by Review. A round that
/// fails is not asked again in this run (the engine also notes it, and the overview then says `unavailable`). The
/// process starts with the first round to fill and ends with the app (its input closes).
@MainActor
final class Backfill {
    struct Job: Equatable {
        var paper: String
        var round: Int
        var key: String { paper + "|" + String(round) }
    }

    private lazy var engine = EngineClient()
    private(set) var queue: [Job] = []
    private(set) var running: Job?
    private var tried: Set<String> = []
    /// A round of this paper is filled in: its overview (and the hierarchy's) is asked for again.
    var filled: ((_ paper: String, _ more: Bool) -> Void)?
    /// How many rounds were filled in this run (debug hooks).
    private(set) var done = 0

    /// The closed rounds an overview reports pending that have a build PDF, oldest first (section keys are inherited
    /// round by round, so they settle when rounds are filled in that order).
    nonisolated static func rounds(_ d: PaperOverview) -> [Int] {
        d.rounds.filter { d.pending.contains($0.n) && $0.isClosed && !$0.failed && $0.pdf != nil }.map(\.n).sorted()
    }

    /// Queues the paper's pending closed rounds not asked for yet in this run.
    func want(_ paper: String, _ d: PaperOverview) {
        for n in Self.rounds(d) {
            let job = Job(paper: paper, round: n)
            guard !tried.contains(job.key), running != job, !queue.contains(job) else { continue }
            queue.append(job)
        }
        next()
    }

    /// A paper left the list: its rounds are not filled in.
    func drop(_ paper: String) { queue.removeAll { $0.paper == paper } }

    private func next() {
        guard running == nil, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        running = job
        tried.insert(job.key)
        guard let json = try? JSONSerialization.data(withJSONObject: ["paper": job.paper, "round": job.round, "state": false] as [String: Any])
        else { return finished(job) }
        let id = engine.send("prose", params: json)
        Task {
            _ = try? await engine.result(id)  // a failure is noted by the engine (rN/prose.failed): unavailable
            finished(job)
        }
    }

    private func finished(_ job: Job) {
        running = nil
        done += 1
        filled?(job.paper, queue.contains { $0.paper == job.paper })
        next()
    }
}
