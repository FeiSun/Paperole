import Foundation

// UI v4's figures (design/ui-v4/IMPLEMENTATION.md §2, D4–D11; mac/UX.md §40.2): pure values from the data the
// hierarchy already has (each paper's overview and summary, the engine's `students`), so every number v4 shows is a
// tested value before a view draws it. Days are calendar days in the calendar's time zone (`HubText.dayCount`).

/// The response bar (D4; BRIEF §3): what the student did with the comments carried into the round that came in.
struct Response: Equatable {
    var revised: Int
    var explained: Int
    var unchanged: Int
    /// Left open in the round before without an answer, so the student was not asked (Round 3 on; plan §5 R3): a
    /// fourth segment, shown only when not 0. Not folded into unchanged, which is another fact.
    var notAsked: Int

    /// The round's comments `edited`, `note_only`, `untouched` and `waiting`, which add up to `carried`; nil for a round
    /// with nothing carried (Round 1).
    static func make(_ r: PaperOverview.Round?) -> Response? {
        guard let c = r?.comments, c.carried > 0 else { return nil }
        return Response(revised: c.edited, explained: c.noteOnly, unchanged: c.untouched, notAsked: c.waiting)
    }

    var carried: Int { revised + explained + unchanged + notAsked }

    /// The segments in order, as drawn and labelled: "not asked" only when there are some.
    var segments: [(count: Int, word: String)] {
        [(revised, "revised"), (explained, "explained"), (unchanged, "unchanged")] + (notAsked > 0 ? [(notAsked, "not asked")] : [])
    }

    /// "11 revised · 1 explained · 2 unchanged".
    var words: String { segments.map { "\($0.count) \($0.word)" }.joined(separator: " · ") }
}

/// Closing's last two parts (D5; BRIEF §0.3): of the student's open comments, those that came in and wait for your
/// check (the carried comments to check in each paper's open, built round), and those still open after it.
struct Closing: Equatable {
    var toCheck: Int
    var stillOpen: Int

    static func split(_ stats: StudentStats?, _ data: [String: PaperOverview]) -> Closing? {
        guard let stats, let open = stats.closed?.total.open else { return nil }
        let toCheck = stats.papers.compactMap { data[$0]?.latest }.filter { !$0.isClosed && !$0.failed }
            .map { $0.comments?.toCheck ?? 0 }.reduce(0, +)
        return Closing(toCheck: toCheck, stillOpen: max(0, open - toCheck))
    }
}

/// Turnaround's numbers (D6, D7).
enum Turnaround {
    /// A median of days: the whole days shown (half up), the exact value for the hover.
    struct Median: Equatable {
        var exact: Double

        var days: Int { Int((exact + 0.5).rounded(.down)) }
        /// "11 d"; "<1 d" for 0.
        var text: String { days == 0 ? "<1 d" : "\(days) d" }
        /// "10.5 d" for an even count's middle, else as `text`.
        var exactText: String { exact == exact.rounded() ? text : String(format: "%.1f d", exact) }
    }

    /// The medians of your days (every trip that closed, a closed last round included, the open one not) and the
    /// student's (the trips whose next round came in); each only from its second trip.
    static func medians(_ trips: [StudentStats.Trip]) -> (you: Median?, student: Median?) {
        (median(trips.filter { !$0.open }.compactMap(\.you)),
         median(trips.filter { !$0.open && $0.next != nil }.compactMap(\.student)))
    }

    /// The trips as Turnaround shows them (D2): a closed last round's days so far dropped for a paper the app marks
    /// finished, which the ledger has not adopted yet (the engine drops them once it has).
    static func trips(_ trips: [StudentStats.Trip], finished: Set<String>) -> [StudentStats.Trip] {
        trips.map { t in
            var t = t
            if t.last == true, finished.contains(t.path) { t.student = nil }
            return t
        }
    }

    static func median(_ xs: [Int]) -> Median? {
        guard xs.count >= 2 else { return nil }
        let s = xs.sorted(), m = s.count / 2
        return Median(exact: s.count % 2 == 1 ? Double(s[m]) : Double(s[m - 1] + s[m]) / 2)
    }

    /// A trip's hover, its dates (README §7, plan §5 R6): "Curriculum Signals · Round 1 Sep 8 · back Sep 11 · Round 2
    /// Sep 21", with "· files Sep 20" when the student's files changed on another day than the round came in.
    static func dates(_ t: StudentStats.Trip, _ d: PaperOverview?, calendar: Calendar = .current) -> String {
        let tz = calendar.timeZone
        func day(_ iso: String?) -> String? { Hierarchy.date(iso).map { HubText.format($0, "MMM d", tz) } }
        var parts = [ShortTitle.of(d?.paper?.title ?? "")].filter { !$0.isEmpty }
        let r = d?.round(t.round)
        parts.append("Round \(t.round)" + (day(r?.created).map { " " + $0 } ?? ""))
        if !t.open, let back = day(r?.closedAt) { parts.append("back " + back) }
        if let n = t.next, let next = d?.round(n) {
            let came = day(next.created)
            parts.append("Round \(n)" + (came.map { " " + $0 } ?? ""))
            if let files = day(next.received), files != came { parts.append("files " + files) }
        }
        return parts.joined(separator: " · ")
    }
}

/// A paper's short name (D10), for the sidebar and the timeline's lanes only (the full title in their hover and
/// accessibility label): the text before ":" if any; else the first word when it is hyphenated; else the first two
/// words.
enum ShortTitle {
    static func of(_ title: String) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let colon = t.firstIndex(of: ":") {
            let head = t[..<colon].trimmingCharacters(in: .whitespaces)
            if !head.isEmpty { return head }
        }
        let words = t.split(whereSeparator: \.isWhitespace)
        if let first = words.first, first.contains("-") { return String(first) }
        return words.prefix(2).joined(separator: " ")
    }
}

/// A paper's figures in its state (D11; BRIEF §1.4, README §9.3): while a round waits on you, the to-check figure and
/// the response bar (and from Round 3 on a closed count that is not 0); with the student or finished, comments,
/// closed and open. A figure that is always 0 in a state is nil.
struct PaperFigures: Equatable {
    struct Count: Equatable {
        var comments: Int
        var edits: Int
    }

    struct Totals: Equatable {
        var comments: Int
        /// Closed as resolved and kept as is (the closed figure's hover); nil in Round 1 (nothing can have closed;
        /// open is then every comment).
        var resolved: Int?
        var kept: Int?
        var open: Int?

        var closed: Int? { resolved.map { $0 + (kept ?? 0) } }
    }

    var glyph: StatusGlyph
    /// The ring's fill when it is not empty (`PaperSummary.fill`; 1 with paragraphs to read); nil otherwise.
    var fill: Double?
    /// To check: the carried comments without an answer and the unasked edits.
    var toCheck: Count?
    /// Changed paragraphs to read (the ring full).
    var toRead: Int?
    var response: Response?
    /// Closed so far, after the to-check figure: from Round 3 on, when not 0.
    var closed: Int?
    /// With the student or finished.
    var totals: Totals?
    /// The card corner's time: "2 d" since the round came in (your move) or went back (with the student), "today";
    /// the day it was finished ("Sep 23").
    var dayCounter: String?
    /// The other form of that time: "Came in Wed, Oct 28", "Round 1 sent back Sat, Oct 24", "Finished Sep 23".
    var hover: String?
    /// "6 of 16 answered so far", once something in the round is answered.
    var answered: String?

    static func make(_ status: PaperStatus?, _ summary: PaperSummary?, _ data: PaperOverview?, today: Date,
                     calendar: Calendar = .current) -> PaperFigures? {
        guard let status else { return nil }
        let latest = data?.latest
        var f = PaperFigures(glyph: StatusGlyph.of(status, fill: summary?.fill))
        if case .ring(let x) = f.glyph, x > 0 { f.fill = x }
        let t = data?.threads
        let closed = (t?.resolved ?? 0) + (t?.kept ?? 0)
        let created = Hierarchy.date(latest?.created)
        switch status {
        case .toCheck(let c, let e):
            f.toCheck = Count(comments: c, edits: e)
            if let s = summary, let a = s.answered, let h = s.handled, a + h > 0 {
                f.answered = HubText.answeredSoFar(a + h, of: a + h + s.toJudge + s.toCheck)
            }
        case .toRead(let n): f.toRead = n
        case .waiting, .finished:
            if let t, let n = t.comments {
                let later = (latest?.n ?? 1) > 1
                f.totals = Totals(comments: n, resolved: later ? t.resolved ?? 0 : nil, kept: later ? t.kept ?? 0 : nil,
                                  open: later ? t.open ?? 0 : nil)
            }
        case .firstDraft, .ready, .failed, .noRounds: break
        }
        if status.yourMove {
            if status != .failed { f.response = Response.make(latest) }
            if (latest?.n ?? 0) >= 3, closed > 0, status != .failed { f.closed = closed }
            if let c = created {
                f.dayCounter = HubText.dayCounter(c, today: today, calendar: calendar)
                f.hover = HubText.hoverCameIn(c, calendar: calendar)
            }
        } else if status == .waiting, let back = Hierarchy.date(latest?.closedAt) {
            f.dayCounter = HubText.dayCounter(back, today: today, calendar: calendar)
            f.hover = HubText.hoverSentBack(back, round: latest?.n, calendar: calendar)
        } else if case .finished(let d) = status, let day = HubText.day(d) {
            f.dayCounter = day
            f.hover = "Finished " + day
        }
        return f
    }
}

/// The paper page's header figure (UI v4 step 4; BRIEF §4 03, plan §5 R7): what the paper's state calls for, at the
/// right of its title. Its other numbers (the first sentence and the facts) are the header's help tag.
struct PaperHeader: Equatable {
    enum Figure: Equatable {
        /// "○ 14 comments + 2 edits to check", the response bar under it.
        case toCheck(PaperFigures.Count)
        case ready
        /// The ring full, "6 paragraphs to read".
        case toRead(Int)
        case firstDraft
        case failed
        /// With the student or finished: comments, closed and open.
        case totals(PaperFigures.Totals, finished: Bool)
    }

    var figure: Figure
    var glyph: StatusGlyph
    var response: Response?
    /// From Round 3 on, closed so far when not 0, after the to-check figure.
    var closed: Int?
    /// The closed figure's help tag: "11 resolved · 1 kept as is".
    var closedHelp: String?
    /// To check: "6 of 16 answered so far" (the number behind the ring's fill), in the to-check figure's help.
    var answered: String?

    static func make(_ status: PaperStatus?, _ summary: PaperSummary?, _ data: PaperOverview?) -> PaperHeader? {
        guard let status, let f = PaperFigures.make(status, summary, data, today: Date()) else { return nil }
        let figure: Figure
        switch status {
        case .toCheck(let c, let e): figure = .toCheck(PaperFigures.Count(comments: c, edits: e))
        case .ready: figure = .ready
        case .toRead(let n): figure = .toRead(n)
        case .firstDraft: figure = .firstDraft
        case .failed: figure = .failed
        case .waiting, .finished:
            guard let t = f.totals else { return nil }
            figure = .totals(t, finished: status.isFinished)
        case .noRounds: return nil
        }
        let t = data?.threads, checking: Bool = { if case .toCheck = figure { return true } else { return false } }()
        let help = t.map { "\($0.resolved ?? 0) resolved · \($0.kept ?? 0) kept as is" }
        // the response and closed go with the to-check figure only (the other states' signs and words stand alone)
        let closed = checking ? f.closed : nil
        return PaperHeader(figure: figure, glyph: f.glyph, response: checking ? f.response : nil, closed: closed,
                           closedHelp: closed != nil || f.totals?.closed != nil ? help : nil, answered: checking ? f.answered : nil)
    }

    /// The figure in words (the debug hook `ovtext` and VoiceOver): "14 comments + 2 edits to check", "16 comments ·
    /// 12 closed · 4 left open".
    var words: String {
        switch figure {
        case .toCheck(let c):
            return HubText.figure(c.comments, c.edits) + " to check" + (closed.map { " · \($0) closed" } ?? "")
        case .ready: return "Ready to finish"
        case .toRead(let n): return count(n, "paragraph") + " to read"
        case .firstDraft: return "First draft"
        case .failed: return "Build failed"
        case .totals(let t, let finished):
            return columns(t, finished: finished).map { "\($0.value) \($0.label)" }.joined(separator: " · ")
        }
    }

    /// The totals as figure columns: comments, then closed and open once a round has gone back after Round 1.
    func columns(_ t: PaperFigures.Totals, finished: Bool) -> [(value: String, label: String, help: String?)] {
        var out: [(value: String, label: String, help: String?)] = [("\(t.comments)", t.comments == 1 ? "comment" : "comments", nil)]
        if let c = t.closed { out.append(("\(c)", "closed", closedHelp)) }
        if let o = t.open { out.append(("\(o)", finished ? "left open" : "open", nil)) }
        return out
    }
}
