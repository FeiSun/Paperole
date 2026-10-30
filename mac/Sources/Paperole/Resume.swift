import AppKit

/// Resume Round N (UX.md §31; CONTRACT amendment "Resume a finished round"): the paper's latest round, finished, open
/// again as it was, to add and change comments and finish it again, until the student's next version starts the next
/// round. The paper, the round and the day it was finished, for the confirmation.
struct ResumeAsk: Equatable, Identifiable {
    var paper: String
    var round: Int
    var closedAt: String?
    var id: String { paper }

    var title: String { "Resume Round \(round)?" }

    /// "… The final.pdf and email from Oct 21 stay in the round’s folder." (without the day when it is not known).
    var message: String {
        "You can add and change comments, then finish the round again. The final.pdf and email"
            + (shortDate(closedAt).map { " from " + $0 } ?? "") + " stay in the round’s folder."
    }
}

extension AppModel {
    /// The paper's latest round when it can be resumed (the engine's `summary.resumable`: finished, and so no later
    /// round), with the day it was finished; nil otherwise, from an engine before Resume, and in a fixture without the
    /// flag. The paper shown from its state, another from the papers list's summary. For the round menu, the
    /// overview's More menu and the paper's context menu.
    func resumable(_ path: String? = nil) -> ResumeAsk? {
        guard let path = path ?? selectedPath else { return nil }
        let s = path == selectedPath && state != nil ? state?.summary : summaries[path]
        guard let s, s.resumable == true, s.closed, let n = s.round else { return nil }
        return ResumeAsk(paper: path, round: n, closedAt: s.closedAt)
    }

    /// The read-only box's Resume Round N: the round shown is the latest, finished (`round.resumable`), never an
    /// earlier round.
    var canResumeShown: Bool {
        guard let r = round, r.closed, r.resumable == true, !viewingEarlierRound else { return false }
        return resumable()?.round == r.n
    }

    /// Resume Round N from the read-only box or a menu: the confirmation first (`confirmResume`). Not while the engine
    /// works (a Resume sent already, the next round being built): a beep, as when there is nothing to resume.
    func askResume(_ path: String? = nil) {
        guard let a = resumable(path), !busy else { return NSSound.beep() }
        confirmResume = a
    }

    /// The confirmation's Resume: the engine's `resume_round`, which moves the round's final.pdf, email and checksums
    /// into rN/earlier/ and opens the round as it was; then Review shows the round, on the Comments tab, and the PDF's
    /// toast says so. All Students, Your Move and the sidebar follow its summary (`ledgerEdits`, the state, and the
    /// papers list's summaries asked again, for a paper Review could not open: a new comment's note being written in
    /// another). A refusal is the window's alert, and nothing changes.
    func resumeRound(_ a: ResumeAsk) {
        confirmResume = nil
        call("resume_round", ["paper": a.paper], then: { [weak self] _ in
            guard let self else { return }
            self.refreshSummaries()
            if self.selectedPath == a.paper {
                self.openReview(ReviewTarget(round: a.round))
            } else {
                self.openPaper(a.paper, level: .review)
            }
            guard self.selectedPath == a.paper else { return }
            if self.tab != .comments { self.tab = .comments }
            self.toast("Round \(a.round) is open again · finish it again when you are done")
        })
    }
}
