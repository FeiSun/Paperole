import Foundation

/// A carried comment's answer this round as the app sends it (UX.md §8): the ledger's verdict (`verified` Resolve,
/// `reopened` Follow up, `wontfix` Keep as is, nil To check), its note, and the follow-up field's unsent draft.
struct Answer: Equatable {
    var verdict: String?
    var note = ""
    var draft = ""
}

/// The choices of the row that a bare V or W shows on a card with text (UX.md §8).
enum CloseChoice: Equatable {
    case withText  // Return: close with the text as the closing remark
    case withoutText  // ⌫: close without it (⌘Z brings it back)
    case cancel  // Esc
    case followUp  // ⌘↩: send it as a follow-up instead
}

/// What a verdict key or button does to a carried comment (design/ui-v2/PROPOSAL.md §1.4, §2). Pure, so it is
/// unit-tested.
enum VerdictPlan: Equatable {
    /// Send this answer to the engine. `focus`: the follow-up field takes focus afterwards.
    case send(Answer, focus: Bool)
    /// Show the choice row: close with `text` (an unsent draft, or the follow-up `sent` this round) or without it.
    case ask(verdict: String, text: String, sent: Bool)
    /// Put the cursor in the follow-up field.
    case focusField

    /// `verdict`: the key's (V verified, R reopened, W wontfix). `current` and `note`: the answer this round; `draft`:
    /// the field's unsent text, "" when it holds only white space. `button`: a click on the card's button, which with
    /// text in the field reads "Resolve + note", "Follow up" (the default) or "Keep as is + note" and acts at once.
    static func press(_ verdict: String, current: String?, note: String, draft: String, button: Bool = false) -> VerdictPlan {
        if verdict == current {
            // The same key again clears; the words return to the field as an unsent draft (R puts the cursor there).
            return .send(Answer(verdict: nil, draft: note.isEmpty ? draft : note), focus: verdict == "reopened")
        }
        if current == nil && button && !draft.isEmpty {
            return .send(Answer(verdict: verdict, note: draft), focus: false)
        }
        if verdict == "reopened" {
            return current == nil ? .focusField
                : .send(Answer(verdict: nil, draft: note.isEmpty ? draft : note), focus: true)  // R on a closed card
        }
        // V or W never turn text into a closing remark on their own.
        let text = current == nil ? draft : current == "reopened" ? note : ""
        if !text.isEmpty { return .ask(verdict: verdict, text: text, sent: current != nil) }
        // Resolved and Kept as is switch, keeping the closing remark.
        return .send(Answer(verdict: verdict, note: current == nil || current == "reopened" ? "" : note), focus: false)
    }

    /// ⌘↩ in the field or on the card, or Follow up with text: the field's text goes out as the follow-up.
    static func sendDraft(_ draft: String) -> VerdictPlan {
        .send(Answer(verdict: "reopened", note: draft), focus: false)
    }

    /// The choice row's answer; nil when nothing changes.
    static func choose(_ c: CloseChoice, verdict: String, text: String, sent: Bool) -> VerdictPlan? {
        switch c {
        case .withText: return .send(Answer(verdict: verdict, note: text), focus: false)
        case .withoutText: return .send(Answer(verdict: verdict), focus: false)
        case .cancel: return nil
        case .followUp: return sent ? nil : sendDraft(text)
        }
    }
}

/// After an answer moves on, the new card's answer buttons ignore clicks for 0.4 s (POLISH §6), so a double click
/// answers one card, not two: its second click lands on the card that took the answered card's place. Keys are not
/// guarded.
struct ClickGuard: Equatable {
    static let interval: TimeInterval = 0.4

    private(set) var id: String?
    private(set) var until: TimeInterval = 0

    /// `now`: seconds on a monotonic clock (ProcessInfo.systemUptime).
    mutating func arm(_ id: String, now: TimeInterval) {
        self.id = id
        until = now + Self.interval
    }

    func blocks(_ id: String, now: TimeInterval) -> Bool { id == self.id && now < until }
}

/// One answer given, for ⌘Z and ⇧⌘Z: undoing sends `before` to the engine again, redoing sends `after`. The engine
/// erases the note when the verdict is cleared (comments.py `set_verdict`), so the app keeps it here.
struct AnswerStep: Equatable {
    var id: String
    var before: Answer
    var after: Answer
}

/// A comment's mark: its colour and kind.
struct MarkStyle: Equatable {
    var color: MarkColor
    var kind: MarkKind
}

/// A mark recoloured or given another kind (the mark's toolbar, the card's colour dot, ⋯ › Colour or Kind, 1–6; UX.md
/// §8): undoing sends what `before` has that `after` changed, redoing the reverse.
struct StyleStep: Equatable {
    var id: String
    var before: MarkStyle
    var after: MarkStyle

    /// What the toast says the mark is now, in the parts the step changed: "yellow", "an underline", "a teal highlight".
    func words(_ now: MarkStyle) -> String {
        let colour = before.color != after.color, kind = before.kind != after.kind
        guard kind else { return now.color.rawValue }
        let w = (colour ? now.color.rawValue + " " : "") + now.kind.name.lowercased()
        return ("aeiou".contains(w.first ?? "x") ? "an " : "a ") + w
    }
}

/// One step for ⌘Z and ⇧⌘Z: an answer given, or a mark's style changed.
enum UndoStep: Equatable {
    case answer(AnswerStep)
    case style(StyleStep)

    var id: String {
        switch self {
        case .answer(let s): return s.id
        case .style(let s): return s.id
        }
    }
}

/// The answers given and the marks restyled in the open round, for undo and redo.
struct AnswerHistory {
    private(set) var undos: [UndoStep] = []
    private(set) var redos: [UndoStep] = []

    mutating func record(_ step: AnswerStep) {
        guard step.before != step.after else { return }
        push(.answer(step))
    }

    mutating func record(_ step: StyleStep) {
        guard step.before != step.after else { return }
        push(.style(step))
    }

    private mutating func push(_ step: UndoStep) {
        undos.append(step)
        redos = []
    }

    /// The step to undo (its `before` is then sent); it moves to the redo stack.
    mutating func undo() -> UndoStep? {
        guard let s = undos.popLast() else { return nil }
        redos.append(s)
        return s
    }

    mutating func redo() -> UndoStep? {
        guard let s = redos.popLast() else { return nil }
        undos.append(s)
        return s
    }

    /// The engine refused the undo or redo: the step goes back where it was.
    mutating func undoFailed() { if let s = redos.popLast() { undos.append(s) } }
    mutating func redoFailed() { if let s = undos.popLast() { redos.append(s) } }

    /// The comment's steps go: its record went (Undo Reopen, Delete), or, with `answersOnly`, its card's field was typed
    /// in, so neither undo nor redo puts an answer's draft over the typed text (its style steps touch no draft).
    mutating func forget(_ id: String, answersOnly: Bool = false) {
        let drop = { (s: UndoStep) in
            guard s.id == id else { return false }
            if case .style = s { return !answersOnly }
            return true
        }
        undos.removeAll(where: drop)
        redos.removeAll(where: drop)
    }
}
