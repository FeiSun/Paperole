import AppKit
import SwiftUI

/// One turn of a card's conversation (UX.md §3; design/ui-v2.2 CARD.md §3, option C): a round, who did what in it,
/// then what they said and the evidence. Built by `CardContent.turns` from the thread's sections, which keep deciding
/// what is a revision, what a section shows and what is underlined; a turn only splits and names them.
struct Turn: Equatable, Identifiable {
    enum Kind: Equatable {
        case first  // the advisor's first turn: the text commented on
        case quiet  // a round in which nothing happened (rounds in a row as one line)
        case student  // the student revised the paper (here or elsewhere), or answered with words only
        case engine  // the text not found, or found again
        case advisor  // an earlier round's follow-up, resolve or keep as is
        case answer  // the shown round's answer: its words are the card's own, edited in place
    }

    /// The dot on the rail (CARD §3.3): what kind of turn it was; who acted is in the label.
    enum Dot: Equatable {
        case you  // neutral grey, filled
        case change  // green, filled: the student changed the paper, here or elsewhere
        case hollow  // nothing changed: words only, found again, this round unchanged
        case small  // an earlier quiet line
        case notFound  // a red ring
    }

    /// Where a student's note is in the source, for its bubble's footer (CARD §3.5): "main.tex:103–104"; the full
    /// paths, one per place, for the help tag.
    struct Place: Equatable {
        var short: String
        var full: String

        init(short: String, full: String) {
            self.short = short
            self.full = full
        }

        /// From "sections/fig/plot.tex:12": "plot.tex:12", the path in the help tag.
        init(path: String) {
            self.init(short: (path as NSString).lastPathComponent, full: path)
        }
    }

    /// An earlier round's long words, cut to whole sentences (CARD §1.3): what shows, and how many sentences are not
    /// shown (0: the first sentence alone was cut at a word).
    struct Clamp: Equatable {
        var shown: String
        var more: Int
    }

    /// Words in a bubble: the student's note, with its place in the source, or the advisor's.
    struct Words: Equatable {
        var text: String
        var clamp: Clamp? = nil
        var place: Place? = nil
    }

    var id: String
    var kind: Kind
    var round: Int
    var through: Int? = nil  // a quiet line of rounds in a row: the last
    var who: String? = nil  // "you", the student's name; nil: a quiet line, the engine
    var verb: String  // "commented on", "replaced the image · moved to p.5", "unchanged since your follow-up"
    var count: String? = nil  // " · 1 edit", " · no edit", " · 1 edit on p.6"
    var reveal: String? = nil  // the change the shown round's count shows in the PDF: the count is a link
    var date: String? = nil  // on the right: "sent Oct 17", the day the round was finished
    var dot: Dot
    var now = false  // a quiet line of the shown round: in the label's own weight
    var section: String? = nil  // the thread section whose text or crop it shows
    var words: Words? = nil
    var bare: Place? = nil  // a bare `% R1-03`: no bubble, the note sign and its place
    var elsewhere: [String] = []  // the shown round's edits its note alone linked outside the commented text
    var uncertain = false  // it holds the shown round, whose place is a guess
    var verdict: String? = nil  // the advisor's turns
    var accessibility = ""

    /// "R3", "R2–R3"
    var rounds: String { "R\(round)" + (through.map { $0 != round ? "–R\($0)" : "" } ?? "") }

    /// "R4 · Ouyang Mingxuan replaced the image · 1 edit"
    var label: String { rounds + " · " + [who, verb].compactMap { $0 }.joined(separator: " ") + (count ?? "") }
}

/// The turns between the first and the last three of a long conversation, folded into one line that is a button
/// (CARD §3.8): `turns[start..<end]`, quiet lines included.
struct TurnFold: Equatable {
    var start: Int
    var end: Int
    var count: Int  // the turns it holds, quiet lines not counted
    var rounds: String  // "R2", "R2–R3"
    var words: String  // "Ouyang Mingxuan revised, you followed up"

    var label: String { rounds + " · " + words }
}

extension CardContent {
    /// Past this many turns (quiet lines not counted) the ones between the first and the last `keep` fold.
    static let foldAbove = 5, keep = 3
    /// An earlier round's bubble longer than `clampAbove` characters (a CJK one counts twice) shows the whole sentences
    /// within `clampTo` (CARD §1.3).
    static let clampAbove = 320, clampTo = 200
    /// While the conversation folds, the first turn's text shows `foldSide` characters each side of the mark.
    static let foldSide = 80

    /// One round of a comment as the turns read it: an earlier round (history) or the shown one.
    private struct Round {
        var round: Int
        var state: String
        var verdict: String?
        var note: String
        var page: Int?
        var changes: [String]
        var pages: [String: Int]
        var student: StudentNote?
        /// Reopened into this round from the round it was closed in (the advisor's Reopen; the engine's `revived`).
        var revived: Int? = nil
    }

    /// The turns of a card for round `n` (CARD §3.2): the advisor's first turn; for each later round the student's
    /// turn (a revision, an edit elsewhere, words only), the engine's (not found, found again) or a quiet line, then the
    /// advisor's answer of that round. `sections` is `thread(c, round: n, …)`, whose sections are the rounds the engine
    /// says changed the text; `student` the student's name as the paper's record has it ("the student" when empty);
    /// `emailed` the days the closed rounds were finished (their final.pdf sent).
    static func turns(_ c: Comment, sections: [ThreadSection], round n: Int, student: String = "",
                      emailed: [Int: String] = [:]) -> [Turn] {
        guard let first = sections.first else { return [] }
        let name = student.trimmingCharacters(in: .whitespacesAndNewlines)
        let who = name.isEmpty ? "the student" : name
        let rounds = c.history.map {
            Round(round: $0.round, state: $0.anchorState, verdict: $0.verdict, note: $0.verdictNote ?? "",
                  page: $0.context?.page ?? $0.page, changes: $0.changes ?? [], pages: $0.changePages ?? [:],
                  student: $0.studentNote, revived: $0.revived?.from)
        } + [Round(round: n, state: c.anchorState, verdict: c.verdict, note: c.verdictNote ?? "",
                   page: c.context?.page ?? c.page, changes: c.changes, pages: [:], student: c.studentNote,
                   revived: c.revived?.from)]
        let own = Dictionary(sections.map { ($0.round, $0) }, uniquingKeysWith: { a, _ in a })
        func pageWords(_ p: Int?) -> String { p.map { "p.\($0 + 1)" } ?? "" }
        func verdictVerb(_ v: String?) -> String {
            v == "reopened" ? "followed up" : v == "verified" ? "resolved it" : "kept it as is"
        }

        var out: [Turn] = []
        // the page it was written on, when it is on another page now, as the verb's object: "you commented on p.3"
        // (the UI audit: "you commented on · p.3" split the verb from its object)
        let moved = first.page != nil && first.page != c.page
        let firstVerb: String
        if c.carried {
            let empty = c.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            firstVerb = moved ? (empty ? "marked it on " : "commented on ") + pageWords(first.page)
                : empty ? "marked" : "commented on"
        } else {
            firstVerb = (["selected area": "selected an area", "note placed near this text": "placed a note near this text",
                          "note on an empty area": "placed a note on an empty area"][first.event] ?? first.event)
                + (moved ? " on " + pageWords(first.page) : "")
        }
        out.append(Turn(id: first.id, kind: .first, round: first.round, who: "you", verb: firstVerb, dot: .you, section: first.id))

        /// The student's turn of round `r`: a revision (`section`, the round's own), or, with no section, an edit a note
        /// linked elsewhere, an edit attached where the engine took the turn (not found, found again), or words only.
        func studentTurn(_ r: Round, previous: Round, section s: ThreadSection?) -> Turn {
            let note = r.student.flatMap { $0.isEmpty ? nil : $0 }
            let elsewhere = note?.elsewhere ?? []
            let own = r.changes.filter { !elsewhere.contains($0) }
            var verb: String
            var named = false  // the verb is the round's own edit ("deleted it", "moved it"): it is not counted again
            var changed = true  // the paper changed, here or elsewhere: a green dot
            switch s?.event {
            case nil:
                verb = !own.isEmpty ? "revised" : elsewhere.isEmpty ? "answered" : "edited elsewhere"
                changed = !own.isEmpty || !elsewhere.isEmpty
            case "new image file":
                verb = "replaced the image"
                if r.state == "moved", let p = r.page, p != previous.page { verb += " · moved to " + pageWords(p) }
            case "moved":
                let only = s?.onlyMoved == true  // no word changed: the Changes tab's "Moved", with a hollow dot
                verb = (only ? "moved it" : "moved and revised it")
                    + (r.page != nil && r.page != c.page ? " · " + pageWords(r.page) : "")
                if only {
                    named = true
                    changed = !elsewhere.isEmpty
                }
            case "deleted":
                verb = "deleted it"  // the deletion is the edit (CARD §3.3: no count)
                named = true
            case "restored": verb = "restored it"
            case let e?: verb = e  // "revised", "revised near the cut"
            }
            var t = Turn(id: "s\(r.round)", kind: .student, round: r.round, who: who, verb: verb,
                         dot: changed ? .change : .hollow, section: s?.id)
            let counted = (named ? [] : own) + elsewhere
            if s == nil && counted.isEmpty {
                t.count = " · no edit"
            } else if !counted.isEmpty {
                t.count = " · " + count(counted.count, "edit")
                if r.round == n {
                    t.reveal = counted.first
                } else if counted.allSatisfy(elsewhere.contains), let p = elsewhere.compactMap({ r.pages[$0] }).first {
                    t.count! += " on " + pageWords(p)  // an earlier round's edit is not in this PDF: where it was
                }
            }
            if let note {
                let words = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if words.isEmpty {
                    t.bare = notePlace(note) ?? Turn.Place(short: "", full: "")
                } else {
                    t.words = Turn.Words(text: words, clamp: r.round < n ? clamped(words) : nil, place: notePlace(note))
                }
            }
            if r.round == n { t.elsewhere = elsewhere }
            return t
        }

        for i in rounds.indices.dropFirst() {
            let r = rounds[i], previous = rounds[i - 1]
            let noted = r.student.map { !$0.isEmpty } ?? false
            if let s = own[r.round] {
                switch s.event {
                case "no text found":
                    out.append(Turn(id: "e\(r.round)", kind: .engine, round: r.round, verb: "text not found",
                                    dot: .notFound, section: s.id))
                    if noted { out.append(studentTurn(r, previous: previous, section: nil)) }
                case "found again":
                    out.append(Turn(id: "e\(r.round)", kind: .engine, round: r.round,
                                    verb: "found again" + (s.page != nil && s.page != c.page ? " · " + pageWords(s.page) : ""),
                                    dot: .hollow, section: s.id))
                    if noted { out.append(studentTurn(r, previous: previous, section: nil)) }
                default:
                    out.append(studentTurn(r, previous: previous, section: s))
                }
            } else if noted {
                out.append(studentTurn(r, previous: previous, section: nil))
            } else {
                let what: String
                switch r.state {
                case "moved": what = r.page != nil && r.page != c.page ? "moved to " + pageWords(r.page) : "moved"
                case "gone": what = "still deleted"
                case "orphan": what = "still not found"
                case "overall": what = "no note"  // on the whole paper: only a note answers it
                default: what = "unchanged"
                }
                // earlier rounds in a row with the same nothing are one line; the shown round's is a line of its own
                if r.round != n, let last = out.last, last.kind == .quiet, !last.now, last.verb == what,
                   (last.through ?? last.round) == previous.round {
                    out[out.count - 1].through = r.round
                } else {
                    out.append(Turn(id: "q\(r.round)", kind: .quiet, round: r.round, verb: what,
                                    dot: r.round != n ? .small : r.state == "orphan" ? .notFound : .hollow, now: r.round == n))
                }
            }
            // the advisor's Reopen (TAGS.md §9.3): "R4 · you reopened it", after what the round shows since it closed,
            // the cause before the act (the UI audit: before it, the student's edit read as made because of it)
            if r.revived != nil {
                out.append(Turn(id: "r\(r.round)", kind: .advisor, round: r.round, who: "you",
                                verb: "reopened it", dot: .you,
                                verdict: "revived"))
            }
            if r.round < n, let v = r.verdict {
                out.append(Turn(id: "a\(r.round)", kind: .advisor, round: r.round, who: "you", verb: verdictVerb(v),
                                date: emailed[r.round].map { "sent " + $0 }, dot: .you,
                                words: r.note.isEmpty ? nil : Turn.Words(text: r.note, clamp: clamped(r.note)), verdict: v))
            }
        }
        if c.carried, let v = c.verdict {
            let note = c.verdictNote ?? ""
            out.append(Turn(id: "now", kind: .answer, round: n, who: "you", verb: verdictVerb(v),
                            date: emailed[n].map { "sent " + $0 }, dot: .you,
                            words: note.isEmpty ? nil : Turn.Words(text: note), verdict: v))
        }
        // the shown round in which nothing happened is the news: said against what came before it (CARD §3.2)
        for i in out.indices.dropFirst() where out[i].kind == .quiet && out[i].now && out[i].verb == "unchanged" {
            let p = out[i - 1]
            let reopened = i + 1 < out.count && out[i + 1].verdict == "revived"  // reopened in this round, after it
            out[i].verb = reopened ? "unchanged since you closed it"
                : p.kind == .first ? (p.verb.hasPrefix("marked") ? "unchanged since you marked it"
                                                                 : "unchanged since you commented")
                : p.kind == .advisor && p.verdict == "reopened" ? "unchanged since your follow-up"
                : p.kind == .quiet && p.verb == "unchanged" ? "still unchanged" : "unchanged"  // not after "moved"
        }
        // "position uncertain" goes with the turn that holds the shown round
        if sections.last?.uncertain == true,
           let k = out.lastIndex(where: { [.first, .quiet, .student, .engine].contains($0.kind) }) {
            out[k].uncertain = true
        }
        let texts = Dictionary(sections.map { ($0.id, $0.kind == .text || $0.kind == .source ? $0.full.text : "") },
                               uniquingKeysWith: { a, _ in a })
        for i in out.indices { out[i].accessibility = spoken(out[i], text: out[i].section.flatMap { texts[$0] }) }
        return out
    }

    /// What VoiceOver reads for a turn (CARD §3.9), with no gendered pronoun: "Round 4, Ouyang Mingxuan replaced the
    /// image, 1 edit. Note: Re-plotted …, plot.tex line 12"; "Rounds 2 to 3, unchanged".
    static func spoken(_ t: Turn, text: String?) -> String {
        func say(_ s: String) -> String {
            s.replacingOccurrences(of: " · ", with: ", ").replacingOccurrences(of: "p.", with: "page ")
        }
        func place(_ p: Turn.Place) -> String {
            p.short.replacingOccurrences(of: ":", with: " line ").replacingOccurrences(of: "–", with: " to ")
        }
        var s = (t.through.map { $0 != t.round ? "Rounds \(t.round) to \($0)" : nil } ?? nil) ?? "Round \(t.round)"
        s += ", " + (t.who.map { $0 + " " } ?? "") + say(t.verb + (t.count ?? ""))
        if let d = t.date { s += ", " + d }
        if t.uncertain { s += ", position uncertain" }
        if let w = t.words {
            s += (t.kind == .student ? ". Note: " : ": ") + w.text
            if let p = w.place, !p.short.isEmpty { s += ", " + place(p) }
        }
        if let b = t.bare { s += ". A comment line points at the edit" + (b.short.isEmpty ? "" : ", " + place(b)) }
        if let text, !text.isEmpty { s += ". " + text }
        return s
    }

    /// The fold of a long conversation (CARD §3.8): past `foldAbove` turns, quiet lines not counted, the first turn
    /// and the last `keep` stay and the ones between (at least 2) fold into one line; nil when nothing folds.
    static func fold(_ turns: [Turn]) -> TurnFold? {
        let full = turns.indices.filter { turns[$0].kind != .quiet }
        guard full.count > foldAbove, let start = full.first.map({ $0 + 1 }) else { return nil }
        let end = full[full.count - keep]
        let middle = turns[start..<end]
        let folded = middle.filter { $0.kind != .quiet }
        guard folded.count >= 2 else { return nil }
        let from = middle.map(\.round).min() ?? 0, to = middle.map { $0.through ?? $0.round }.max() ?? from
        return TurnFold(start: start, end: end, count: folded.count, rounds: "R\(from)" + (to != from ? "–R\(to)" : ""),
                        words: folded.map { [$0.who, $0.verb].compactMap { $0 }.joined(separator: " ") }
                            .joined(separator: ", "))
    }

    // MARK: Words

    /// A character's weight in the length rules: a CJK one counts twice, as in the title's (`NoteTitle`).
    static func weight<S: Sequence>(_ s: S) -> Int where S.Element == Character {
        s.reduce(0) { $0 + (NoteTitle.isCJK($1) ? 2 : 1) }
    }

    /// An earlier round's bubble cut to length (CARD §1.3), or nil when it shows whole: up to `clampAbove` weighted
    /// characters show whole; past that, the whole sentences within `clampTo` (the title's sentence rule) and how many
    /// are left; a first sentence longer than that is cut at the last word (in CJK, character) within it, with "…".
    /// A pure rule on characters, so no view measures text for it.
    static func clamped(_ text: String) -> Turn.Clamp? {
        let chars = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard weight(chars) > clampAbove else { return nil }
        var ends: [Int] = [], i = 0
        while i < chars.count {
            let e = NoteTitle.sentenceEnd(chars, from: i)
            ends.append(e)
            i = e
            while i < chars.count, chars[i].isWhitespace { i += 1 }
        }
        var shown = 0, w = 0, k = 0, at = 0
        for e in ends {
            w += weight(chars[at..<e])
            guard w <= clampTo else { break }
            shown = e
            at = e
            k += 1
        }
        if k > 0 {
            return Turn.Clamp(shown: String(chars[..<shown]).trimmingCharacters(in: .whitespacesAndNewlines),
                              more: ends.count - k)
        }
        var cut = 0, total = 0, any = 0
        for (j, ch) in chars.enumerated() {
            total += NoteTitle.isCJK(ch) ? 2 : 1
            guard total <= clampTo else { break }
            any = j + 1
            if ch.isWhitespace { cut = j } else if NoteTitle.isCJK(ch) { cut = j + 1 }
        }
        let head = String(chars[..<(cut > 0 ? cut : any)])
        return Turn.Clamp(shown: head.trimmingCharacters(in: .whitespacesAndNewlines) + "…", more: 0)
    }

    /// Where a student's note is in the source (CARD §3.5; O32): the file's name and line, "main.tex:56"; lines in a
    /// row of one file as a range, "main.tex:103–104"; two places in one file, "main.tex:56, 60"; more, the first and
    /// how many others, "main.tex:56 +2". The full paths, one place a line, are for the help tag.
    static func notePlace(_ n: StudentNote) -> Turn.Place? {
        var lines = n.lines.compactMap { l in l.file.map { ($0, l.line) } }
        if lines.isEmpty, let f = n.file { lines = [(f, n.line)] }
        guard !lines.isEmpty else { return nil }
        var places: [(file: String, from: Int?, to: Int?)] = []
        for (f, l) in lines {
            if let last = places.last, last.file == f, let a = last.to, let b = l, b == a || b == a + 1 {
                places[places.count - 1].to = b
            } else {
                places.append((f, l, l))
            }
        }
        func numbers(_ p: (file: String, from: Int?, to: Int?)) -> String {
            guard let a = p.from else { return "" }
            return p.to.map { $0 != a ? "\(a)–\($0)" : "\(a)" } ?? "\(a)"
        }
        func at(_ p: (file: String, from: Int?, to: Int?), _ name: String) -> String {
            numbers(p).isEmpty ? name : name + ":" + numbers(p)
        }
        let name = (places[0].file as NSString).lastPathComponent
        let short: String
        if places.count == 1 {
            short = at(places[0], name)
        } else if places.count == 2, places[1].file == places[0].file, !numbers(places[1]).isEmpty {
            short = at(places[0], name) + ", " + numbers(places[1])
        } else {
            short = at(places[0], name) + " +\(places.count - 1)"
        }
        return Turn.Place(short: short, full: places.map { at($0, $0.file) }.joined(separator: "\n"))
    }

    /// While the conversation folds, the first turn's text cut to `foldSide` characters each side of its mark (UX.md §3
    /// Length's way), or nil when that cuts nothing. Without a mark, the usual window.
    static func foldTrim(_ t: BlockText) -> BlockText? {
        guard !(t.marks.isEmpty && t.carets.isEmpty) else { return trim(t) }
        guard let cut = trim(t, window: 0, side: foldSide), cut.text != t.text else { return nil }
        return cut
    }

    // MARK: Labels

    /// A turn's label (CARD §3.3), 11/16: the round Semibold in the label colour, who acted Semibold in the second
    /// label colour, the rest Medium in the secondary; an earlier quiet line Regular and fainter, its round Medium in
    /// the secondary. The shown round's count is a link ("edit:" and the change), which shows that edit in the PDF.
    static func label(_ t: Turn) -> AttributedString {
        let faint = t.kind == .quiet && !t.now
        let rest: Font.Weight = faint ? .regular : .medium
        var out = AttributedString()
        func run(_ s: String, _ weight: Font.Weight, _ colour: Color) {
            var a = AttributedString(s)
            a.font = .system(size: 11, weight: weight)
            a.foregroundColor = colour
            out += a
        }
        run(t.rounds, faint ? .medium : .semibold, faint ? Ink.secondary : Ink.label)
        run(" · ", rest, Ink.secondary)
        if let who = t.who {
            run(who, .semibold, Ink.label2)
            run(" ", rest, Ink.secondary)
        }
        run(t.verb, rest, Ink.secondary)
        if let c = t.count, c.hasPrefix(" · ") {
            // joined by no-break spaces, so a long label wraps before the verb's last word, never inside "· 1 edit"
            let nb = "\u{00A0}", words = String(c.dropFirst(3)).replacingOccurrences(of: " ", with: nb)
            run(nb + "·" + nb, rest, Ink.secondary)
            if let id = t.reveal {
                var a = AttributedString(words)
                a.font = .system(size: 11, weight: .medium)
                a.foregroundColor = Ink.link
                a.link = URL(string: "edit:" + id)
                out += a
            } else {
                run(words, rest, Ink.secondary)
            }
        } else if let c = t.count {
            run(c, rest, Ink.secondary)
        }
        return out
    }

    /// The fold's line: its rounds Semibold in the label colour, the turns it holds Regular in the secondary.
    static func label(_ f: TurnFold) -> AttributedString {
        var r = AttributedString(f.rounds)
        r.font = .system(size: 11, weight: .semibold)
        r.foregroundColor = Ink.label
        var w = AttributedString(" · " + f.words)
        w.font = .system(size: 11, weight: .regular)
        w.foregroundColor = Ink.secondary
        return r + w
    }
}
