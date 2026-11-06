import Foundation

// The state JSON the engine returns with every RPC result (CONTRACT.md §8).

struct EngineState: Decodable, Equatable {
    var schema: Int
    var paper: PaperInfo
    var rounds: [RoundSummary]
    var round: RoundInfo?
    var comments: [Comment]
    var changes: [Change]
    var summary: PaperSummary? = nil  // the paper's next step, whichever round is shown; nil in older fixtures
    var reading: ReadingInfo? = nil  // the shown round's paragraphs and read state; null until they are found (UX.md §18)
    /// The student's notes in the shown round that were not used, with file:line (CONTRACT amendment "Student notes");
    /// nil in a state from before notes.
    var noteWarnings: [NoteWarning]? = nil
    /// The names the ledger keeps for the advisor's own tags (`tag_names`); nil from an engine before them.
    var tagNames: [String: String]? = nil

    static func decode(_ data: Data) throws -> EngineState {
        try makeDecoder().decode(EngineState.self, from: data)
    }
}

/// The shown round's paragraphs to read in the PDF, the blocks of those that are read, and the headings (CONTRACT
/// amendment "Reading in the PDF view").
struct ReadingInfo: Decodable, Equatable {
    var read: [Int]
    var count: Int
    var unread: Int
    var paragraphs: [Paragraph] = []
    var headings: [Heading] = []

    private enum Keys: String, CodingKey { case read, count, unread, paragraphs, headings }

    init(read: [Int], count: Int, unread: Int, paragraphs: [Paragraph] = [], headings: [Heading] = []) {
        self.read = read
        self.count = count
        self.unread = unread
        self.paragraphs = paragraphs
        self.headings = headings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        read = try c.decode([Int].self, forKey: .read)
        count = try c.decode(Int.self, forKey: .count)
        unread = try c.decode(Int.self, forKey: .unread)
        paragraphs = try c.decodeIfPresent([Paragraph].self, forKey: .paragraphs) ?? []
        headings = try c.decodeIfPresent([Heading].self, forKey: .headings) ?? []
    }
}

/// Every RPC result contains the state; `comment` also returns the new id.
struct Reply: Decodable {
    var state: EngineState
    var id: String?
}

/// The papers list's next steps (`summaries`): one per paper folder, or the error that folder gave.
struct SummariesReply: Decodable {
    struct Entry: Decodable {
        /// The paper's title and student as its ledger has them (CONTRACT amendment "App, hierarchy"): the sidebar
        /// groups the papers by student without asking for each one's state. nil from an older engine.
        struct Paper: Decodable, Equatable {
            var title: String?
            var student: String?
            /// The ledger's id and Finished day (CONTRACT amendment "Data foundations"); nil from an older engine.
            var id: String?
            var finished: String?
        }

        var path: String
        var summary: PaperSummary?
        var paper: Paper?
    }
    var papers: [Entry]
}

/// A paper's next step in the papers list (CONTRACT amendment "Earlier rounds and next steps"): its latest round and,
/// when that round is open, the carried comments to check (no answer yet) and the unrequested changes left to check.
struct PaperSummary: Decodable, Equatable {
    var round: Int?
    var closed: Bool
    var status: String?
    var toJudge: Int
    var toCheck: Int
    /// The open round's changed paragraphs still to read, which the engine's summary does not count: set by the app for
    /// the paper it shows, from its reading (nil otherwise). With nothing to check, the round is not ready to finish
    /// while some are left (interaction review 2026-10-18: the subtitle said "ready to finish" over "6 to read").
    var unread: Int?
    /// When the latest round was finished (nil while it is open), and whether Resume Round N can open it again: it is
    /// finished (CONTRACT amendment "Resume a finished round"). nil from an engine before Resume.
    var closedAt: String? = nil
    var resumable: Bool? = nil
    /// Whether ingest may replace the latest draft; includes review notes on automatic checks.
    var replaceable: Bool? = nil
    /// What is done in the open round (CONTRACT amendment "UI v4 data"): carried comments with a verdict, and unrequested
    /// changes no longer to check. nil from an engine before them (the official app's frozen one).
    var answered: Int? = nil
    var handled: Int? = nil

    /// The status ring's fill (UI v4): the share of the open round's carried comments and unrequested changes that is
    /// done. nil (an empty ring, never a guess) without answered and handled, or with nothing to answer or check.
    var fill: Double? {
        guard let answered, let handled else { return nil }
        let total = answered + handled + toJudge + toCheck
        return total > 0 ? Double(answered + handled) / Double(total) : nil
    }

    enum Step: Equatable { case noRounds, buildFailed, waiting, toCheck(Int), toRead(Int), open, allChecked }

    var step: Step {
        guard let n = round else { return .noRounds }
        if closed { return .waiting }
        if status == "failed" { return .buildFailed }
        if toJudge + toCheck > 0 { return .toCheck(toJudge + toCheck) }
        if n > 1, let u = unread, u > 0 { return .toRead(u) }
        return n == 1 ? .open : .allChecked
    }

    /// The papers list's line under the title, before the student's name (design/ui-v2/PROPOSAL.md §3): whose move it
    /// is, the count of what is to check in a badge beside the title (`badge`).
    var text: String {
        switch step {
        case .noRounds: return "No rounds yet"
        case .buildFailed: return "Build failed"
        case .waiting: return "Waiting for student"
        case .toCheck: return "To check"
        case .toRead: return "Paragraphs to read"
        case .open: return "Round \(round ?? 1) in progress"
        case .allChecked: return "Ready to finish"
        }
    }

    /// The badge beside the title: the comments and edits to check, or nil.
    var badge: Int? {
        if case .toCheck(let m) = step { return m }
        return nil
    }

    /// What the badge counts, for the help tag.
    var detail: String {
        guard case .toCheck = step else { return text }
        return [toJudge > 0 ? count(toJudge, "comment") + " to check" : nil,
                toCheck > 0 ? count(toCheck, "other edit") + " to check" : nil].compactMap { $0 }
            .joined(separator: " · ")
    }

    /// The window subtitle after the student's name (PROPOSAL §6, addition 10): "7 comments and 2 edits to check", the
    /// numbers of the panel's two tabs (`comments` and `edits`: the shown open round's own, which change before the
    /// engine replies; the summary's otherwise). The round is named only in the toolbar's round menu.
    func subtitle(comments: Int? = nil, edits: Int? = nil) -> String {
        switch step {
        case .toCheck, .toRead, .allChecked:
            let c = comments ?? toJudge, e = edits ?? toCheck
            let parts = [c > 0 ? count(c, "comment") : nil, e > 0 ? count(e, "edit") : nil].compactMap { $0 }
            if !parts.isEmpty { return parts.joined(separator: " and ") + " to check" }
            if let u = unread, u > 0, (round ?? 0) > 1 { return count(u, "changed paragraph") + " to read" }
            return "ready to finish"
        case .open: return "in progress"
        case .noRounds, .buildFailed, .waiting: return text.lowercased()
        }
    }
}

func makeDecoder() -> JSONDecoder {
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    return d
}

struct PaperInfo: Decodable, Equatable {
    var path: String
    var title: String
    var student: String
    var main: String?
    var engine: String?
    /// The paper's id (CONTRACT amendment "Data foundations"); nil from an older engine.
    var id: String?
    /// The advisor's choice: the paper's next builds run with shell escape (CONTRACT amendment "Shell escape per paper";
    /// UX.md §41). nil from an engine before it (the official app's frozen one), read as off.
    var shellEscape: Bool? = nil
}

struct RoundSummary: Decodable, Equatable {
    var n: Int
    var created: String?
    var source: String?
    var closed: Bool
    var closedAt: String?
    var status: String?
    var pdf: String?  // the round's build PDF, absolute (UX.md §15.4); the app crops figures from it
}

struct RoundInfo: Decodable, Equatable {
    var n: Int
    var closed: Bool
    var created: String?
    var closedAt: String?
    var build: Build
    var finalPdf: String?
    var email: String?
    /// How many automatic checks went out with the round once finished (CONTRACT amendment "Checks to the student");
    /// nil while open and from an engine before it.
    var checksSent: Int? = nil
    /// How many were closed as fixed in it (no longer found), once finished.
    var checksFixed: Int? = nil
    /// The paper's latest round, finished: Resume Round N can open it again (CONTRACT amendment "Resume a finished
    /// round"). False for an earlier round shown, nil from an engine before Resume.
    var resumable: Bool? = nil
    /// Its earlier finishes, whose files Resume kept in rN/earlier/, oldest first ([] for a round never resumed).
    var finishes: [Finish]? = nil

    /// An earlier finish: when it was finished and resumed, and its kept final.pdf and email (absolute; nil when not
    /// there).
    struct Finish: Decodable, Equatable {
        var at: String?
        var resumed: String?
        var final: String?
        var email: String?
    }
}

struct Build: Decodable, Equatable {
    var status: String  // ok | errors | failed
    var pdf: String?
    var pages: Int?
    var textX: [[Double]?]?  // per page, [x0, x1] of the text without margin line numbers, or null (CONTRACT amendments)
    var columns: [[Double]?]?  // per page, [x between two text columns, half the page height], or null (one column)
    var rulers: [[[Double]?]?]?  // per page with text_x, [left, right]: the bounds of its margin line numbers on each side, or null
    var warnings: [String]
    var errors: [BuildError]
    var logTail: String?
    /// Built with shell escape, and whether a package asks for it in a build made without it (minted's "You must invoke
    /// LaTeX with the -shell-escape flag", epstopdf, svg…; CONTRACT amendment "Shell escape per paper"). nil from an
    /// engine before them: nothing is offered.
    var shellEscape: Bool? = nil
    var needsShellEscape: Bool? = nil
}

struct BuildError: Decodable, Equatable, Hashable {
    var file: String?
    var line: Int?
    var message: String
}

struct Comment: Decodable, Equatable, Identifiable {
    var id: String
    var kind: String  // highlight | underline | strikeout | note | box
    var color: String?  // yellow | teal | blue | pink | purple | orange; missing means yellow (UX.md §15.1)
    var note: String
    var source: String
    var createdRound: Int
    var carried: Bool
    var verdict: String?  // nil | verified | reopened | wontfix
    var verdictNote: String?
    var anchorState: String  // new | unchanged | changed | moved | gone | orphan
    var confidence: Double
    var method: String
    var page: Int?
    var rects: [[Double]]
    var text: String?
    var oldQuote: String?
    var newQuote: String?
    var file: String?
    var line: Int?
    var changes: [String]
    var history: [HistoryEntry]
    var context: AnchorContext?  // this round's printed sentence(s) around the anchor; null when orphan
    var paragraph: Int? = nil  // the block this round's anchor is in (the Contents count it in that section)
    /// The student's note on it in the shown round, a `% R1-03 …` line in the .tex (CONTRACT amendment "Student notes");
    /// `note` is the advisor's.
    var studentNote: StudentNote? = nil
    /// The advisor's writing tags on it, in the order put on (CONTRACT amendment "Tags, key page and Reopen"); nil from
    /// an engine before tags, [] for none.
    var tags: [String]? = nil
    /// The environment its creation anchor is in ("figure", "equation", "thebibliography"…), for the suggestions by
    /// place; nil when not known.
    var env: String? = nil
    /// Reopened into the shown round (the engine's `revived`: the round it was closed in), or nil.
    var revived: Revived? = nil
    /// It can be reopened into the paper's open round now (closed in an earlier round, the open round built).
    var revivable: Bool? = nil

    var tagIDs: [String] { tags ?? [] }

    /// Below 0.75, except for a note placed by a click: its line is a guess by design and stays at 0.5 (it still counts
    /// when it is gone or not found). The card says "position uncertain" (UX.md §3).
    var lowConfidence: Bool { confidence < 0.75 && !(markKind == .note && anchorState != "gone") }
    var markColor: MarkColor { MarkColor(name: color ?? "") ?? .yellow }
    var markKind: MarkKind { MarkKind(rawValue: kind) ?? .highlight }
    /// On the whole paper (engine/CONTRACT.md amendment "Comments on places, step 1"): no page or mark in any round.
    var isOverall: Bool { kind == Self.overall }
    static let overall = "overall"
}

struct HistoryEntry: Decodable, Equatable {
    var round: Int
    var anchorState: String
    var verdict: String?
    var verdictNote: String?
    var page: Int? = nil
    var context: AnchorContext? = nil
    var changes: [String]? = nil  // the changes attached in that round (CONTRACT amendment "Thread cards"); nil before
    var figures: [String]? = nil  // those of them that replaced a picture file; nil from an engine before notes' fixes
    var changePages: [String: Int]? = nil  // the page each of them is on in that round's PDF (0-based); nil before
    var studentNote: StudentNote? = nil  // the student's note in that round
    var revived: Revived? = nil  // reopened into that round (CONTRACT amendment "Tags, key page and Reopen")
}

/// A record's `revived`: the advisor reopened the comment into that round from the round it was closed in.
struct Revived: Decodable, Equatable {
    var from: Int
    var at: String? = nil
}

/// A student's note on a comment in one round (CONTRACT amendment "Student notes"): the text of its `% R1-03 …` lines
/// (empty for a bare `% R1-03`, which only points at the change next to it), where its first line is, the changes it
/// attached to the comment, those of them outside the comment's sentence (`elsewhere`: attached by the note alone, not
/// a revision of the commented text), and each line with the changes next to it.
struct StudentNote: Decodable, Equatable {
    var text: String
    var file: String? = nil
    var line: Int? = nil
    var changes: [String] = []
    var elsewhere: [String] = []
    var lines: [Line] = []

    /// One `% R1-03 …` line of the note and the changes next to it.
    struct Line: Decodable, Equatable {
        var file: String? = nil
        var line: Int? = nil
        var changes: [String] = []

        init(file: String? = nil, line: Int? = nil, changes: [String] = []) {
            self.file = file
            self.line = line
            self.changes = changes
        }

        private enum Keys: String, CodingKey { case file, line, changes }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            file = try c.decodeIfPresent(String.self, forKey: .file)
            line = try c.decodeIfPresent(Int.self, forKey: .line)
            changes = try c.decodeIfPresent([String].self, forKey: .changes) ?? []
        }
    }

    init(text: String, file: String? = nil, line: Int? = nil, changes: [String] = [], elsewhere: [String] = [],
         lines: [Line] = []) {
        self.text = text
        self.file = file
        self.line = line
        self.changes = changes
        self.elsewhere = elsewhere
        self.lines = lines
    }

    private enum Keys: String, CodingKey { case text, file, line, changes, elsewhere, lines }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        file = try c.decodeIfPresent(String.self, forKey: .file)
        line = try c.decodeIfPresent(Int.self, forKey: .line)
        changes = try c.decodeIfPresent([String].self, forKey: .changes) ?? []
        elsewhere = try c.decodeIfPresent([String].self, forKey: .elsewhere) ?? []
        lines = try c.decodeIfPresent([Line].self, forKey: .lines) ?? []
    }

    /// Words, or at least a change it points at: a bare `% R1-03` with no change next to it says nothing.
    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && changes.isEmpty }

    /// "main.tex:42"
    var place: String? { file.map { $0 + (line.map { ":\($0)" } ?? "") } }

    /// Where the line next to a change is: the note's line that linked it, else its first line.
    func place(for change: String) -> String? {
        guard let l = lines.first(where: { $0.changes.contains(change) }), let f = l.file else { return place }
        return f + (l.line.map { ":\($0)" } ?? "")
    }
}

/// A student's note the engine did not use (CONTRACT amendment "Student notes"): `unknown`, `closed`, `malformed`,
/// `unread`, `not_tex` or `error`, the IDs it names, the comment line as written and the engine's sentence.
struct NoteWarning: Decodable, Equatable, Hashable {
    var kind: String
    var ids: [String] = []
    var file: String? = nil
    var line: Int? = nil
    var text: String? = nil
    var message: String

    init(kind: String, ids: [String] = [], file: String? = nil, line: Int? = nil, text: String? = nil, message: String) {
        self.kind = kind
        self.ids = ids
        self.file = file
        self.line = line
        self.text = text
        self.message = message
    }

    private enum Keys: String, CodingKey { case kind, ids, file, line, text, message }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        ids = try c.decodeIfPresent([String].self, forKey: .ids) ?? []
        file = try c.decodeIfPresent(String.self, forKey: .file)
        line = try c.decodeIfPresent(Int.self, forKey: .line)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
    }

    /// "main.tex:42", or nil (an `error`).
    var place: String? { file.map { $0 + (line.map { ":\($0)" } ?? "") } }
}

/// The whole sentence(s) that hold an anchor, as one round's PDF prints them (UX.md §15.3). Offsets count Unicode
/// scalars (Python str indices), end exclusive.
struct AnchorContext: Decodable, Equatable {
    var text: String
    var sel: [[Int]] = []  // the anchor's words in text
    var cut: Int? = nil  // gone: the deletion point in text
    var display: String = "text"  // text | image
    var page: Int? = nil
    var rects: [[Double]] = []
    var clip: [Double]? = nil  // image: the area of the page to show, [x0, y0, x1, y1]

    var isImage: Bool { display == "image" }

    init(text: String, sel: [[Int]] = [], cut: Int? = nil, display: String = "text", page: Int? = nil,
         rects: [[Double]] = [], clip: [Double]? = nil) {
        self.text = text
        self.sel = sel
        self.cut = cut
        self.display = display
        self.page = page
        self.rects = rects
        self.clip = clip
    }

    private enum Keys: String, CodingKey { case text, sel, cut, display, page, rects, clip }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        sel = try c.decodeIfPresent([[Int]].self, forKey: .sel) ?? []
        cut = try c.decodeIfPresent(Int.self, forKey: .cut)
        display = try c.decodeIfPresent(String.self, forKey: .display) ?? "text"
        page = try c.decodeIfPresent(Int.self, forKey: .page)
        rects = try c.decodeIfPresent([[Double]].self, forKey: .rects) ?? []
        clip = try c.decodeIfPresent([Double].self, forKey: .clip)
    }
}

struct Change: Decodable, Equatable, Identifiable {
    var id: String
    var kind: String  // insert | delete | replace | move
    var file: String?
    var line: Int?
    var oldText: String
    var newText: String
    var page: Int?
    var rects: [[Double]]
    var attachedTo: [String]
    var unrequested: Bool
    var figure: String? = nil  // a graphics file replaced under the same name (its \includegraphics is unchanged)
    var section: String? = nil  // the heading it is under, as printed
    var checked: Bool? = nil  // the advisor marked it checked in this round (UX.md §16)
    var commentedBy: [String]? = nil  // comments written this round on it (their marks overlap it)
    var context: ChangeContext? = nil
    var blocks: [Int]? = nil  // the blocks it touches (UX.md §18)
    var read: Bool? = nil  // not a move, and every paragraph it touches is read
    var float: String? = nil  // the table or figure it is in, as printed: "Table 2"
    var about: ChangeAbout? = nil  // what it is in words, when its words would be LaTeX (UX.md §16)
    var studentNotes: [String]? = nil  // the comments whose student's note this round attached it (CONTRACT "Student notes")
    /// The comments closed before this round whose sentence it edits, and not in this round (the Changes tab's hint
    /// for Reopen; CONTRACT amendment "Tags, key page and Reopen").
    var nearClosed: [NearClosed]? = nil
}

/// A comment closed in an earlier round near a change: its id, the round it was closed in, how, and whether it can be
/// reopened now.
struct NearClosed: Decodable, Equatable {
    var id: String
    var round: Int
    var verdict: String?
    var revivable: Bool? = nil
}

/// A change in words (CONTRACT amendment "Readable changes"): an \input line ("file": "Figure 'plot' removed") or an
/// edit that prints no other text ("formatting": "Formatting only: no printed text changed in §4.1").
struct ChangeAbout: Decodable, Equatable {
    var kind: String
    var text: String
}

/// A change's sentence(s) as the previous round's PDF and this round's print them (UX.md §16): `sel` holds the
/// change's own words, `cut` an insertion point (before) or deletion point (now). A side is nil when it prints nothing.
struct ChangeContext: Decodable, Equatable {
    var before: AnchorContext?
    var now: AnchorContext?
}
