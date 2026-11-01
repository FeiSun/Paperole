import Foundation

// Shell escape per paper (UX.md §41; engine/CONTRACT.md amendment "Shell escape per paper, 2026-11-01"): a package that
// runs a program while LaTeX builds (minted's pygmentize, epstopdf, svg…) needs \write18, which lets the student's
// source run any command as the advisor. So it is off by default, per paper, never global and never brought in from a
// file; the app offers it from the build that asks for it, only for the paper's latest round.

/// What the build's Details offer while a package asks for shell escape in the latest round's build.
enum ShellEscapeOffer: Equatable {
    /// Build Again with Shell Escape…: the round can still be built again (`AppModel.canBuildAgain`), so the sheet
    /// that builds it opens with its toggle on.
    case buildAgain
    /// Turn On Shell Escape…: for the next round (comments or answers in this one, or it is closed), asked first; the
    /// round stays as built.
    case turnOn

    var title: String { self == .buildAgain ? "Build Again with Shell Escape…" : "Turn On Shell Escape…" }

    /// Only for the latest round shown while its build asks for it (`needs_shell_escape`; an engine before it sends
    /// none: nothing is offered); Turn On only until the paper has it.
    static func of(needs: Bool, latest: Bool, canBuildAgain: Bool, paperOn: Bool) -> ShellEscapeOffer? {
        guard needs, latest else { return nil }
        if canBuildAgain { return .buildAgain }
        return paperOn ? nil : .turnOn
    }
}

/// Turn On Shell Escape…'s confirmation, an alert on the window: the paper it asks about (as `ResumeAsk`, so Turn On
/// never goes to a paper chosen meanwhile) and its latest round, which stays as built.
struct ShellEscapeAsk: Equatable {
    var paper: String
    var round: Int

    var title: String { "Turn on shell escape for this paper?" }
    var message: String {
        "Round \(round + 1) and later will build with it; Round \(round) stays as built. It lets this paper’s LaTeX run "
            + "commands on your Mac, so use it only for a source you trust."
    }
}

extension AppModel {
    /// The build's offer for the round shown (`ShellEscapeOffer.of`).
    var shellEscapeOffer: ShellEscapeOffer? {
        ShellEscapeOffer.of(needs: round?.build.needsShellEscape == true, latest: round != nil && round?.n == latestRound?.n,
                            canBuildAgain: canBuildAgain, paperOn: state?.paper.shellEscape == true)
    }

    /// The offer's button (and the failed build's Build Again with Shell Escape…): the Details close, then the sheet
    /// with its toggle on, or the confirmation.
    func takeShellEscapeOffer(_ offer: ShellEscapeOffer) {
        showBuildDetails = false
        switch offer {
        case .buildAgain: openRetry(shellEscape: true)
        case .turnOn:
            guard let paper = selectedPath, let n = round?.n else { return }
            confirmShellEscape = ShellEscapeAsk(paper: paper, round: n)
        }
    }

    /// The paper's choice, in its ledger (`edit_paper`), for its next builds: the confirmation's Turn On, for the paper
    /// it asked about (`paper`), and Turn Off Shell Escape, for the paper shown, without asking. The round shown stays
    /// as built.
    func setShellEscape(_ on: Bool, paper: String? = nil) {
        confirmShellEscape = nil
        guard let paper = paper ?? selectedPath else { return }
        call("edit_paper", ["paper": paper, "shell_escape": on])
    }
}
