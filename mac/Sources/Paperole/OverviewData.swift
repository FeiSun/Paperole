import CoreGraphics
import Foundation

/// The engine's read-only `overview` (design/overview/FEATURES.md §5.1 with the fields of OVERVIEW-v2 §5.2):
/// `{"papers": [{"path", "overview"} | {"path", "error"}]}`. Every field is optional here, so an engine that gives more
/// or fewer fields still decodes; the rows of `spans`, `match`, `edits`, `heat` and `path` are JSON arrays (tuples),
/// read by position.
struct OverviewReply: Decodable, Equatable {
    var papers: [OverviewEntry]
    /// The papers grouped by student, for the Student page (CONTRACT amendment "Overview"); nil from an engine or a
    /// fixture without it.
    var students: [StudentStats]?
}

struct OverviewEntry: Decodable, Equatable {
    var path: String
    var overview: PaperOverview?
    var error: String?
}

struct PaperOverview: Decodable, Equatable {
    struct Paper: Decodable, Equatable {
        var title: String?
        var student: String?
        var created: String?
        /// The ledger's id and three facts (CONTRACT amendment "Data foundations"; the app's while the ledger lacks
        /// one): Map Headings' answers (null: the heading's own column) and the key page. nil from an older engine.
        var id: String?
        var finished: String?
        var buckets: [String: String?]?
        var keyPage: KeyPageChoice?
    }

    /// A first-level section of the paper, over all rounds; `comments`: its comments, each counted once; `name`: the
    /// title without its number; `first`/`last`: the rounds it is in; `written`: the comments written in it.
    struct Section: Decodable, Equatable {
        var key: String
        var title: String?
        var name: String?
        var suggestedBucket: String?
        var first: Int?
        var last: Int?
        var gone: Bool?
        var comments: Int?
        var written: Int?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decodeIfPresent(FlexibleID.self, forKey: .key)?.value ?? ""
            title = try c.decodeIfPresent(String.self, forKey: .title)
            name = try c.decodeIfPresent(String.self, forKey: .name)
            suggestedBucket = try c.decodeIfPresent(String.self, forKey: .suggestedBucket)
            first = try c.decodeIfPresent(Int.self, forKey: .first)
            last = try c.decodeIfPresent(Int.self, forKey: .last)
            gone = try c.decodeIfPresent(Bool.self, forKey: .gone)
            comments = try c.decodeIfPresent(Int.self, forKey: .comments)
            written = try c.decodeIfPresent(Int.self, forKey: .written)
        }

        init(key: String, title: String?, comments: Int? = nil) {
            self.key = key
            self.title = title
            self.comments = comments
        }

        enum CodingKeys: String, CodingKey { case key, title, name, suggestedBucket, first, last, gone, comments, written }
    }

    struct Round: Decodable, Equatable {
        struct BuildInfo: Decodable, Equatable {
            var status: String?
            var pages: Int?
        }

        /// The round's comments (FEATURES §5.1): edited + note_only + untouched + waiting = carried.
        struct Comments: Decodable, Equatable {
            var new = 0, carried = 0, edited = 0, noteOnly = 0, untouched = 0, movedOnly = 0, waiting = 0, notFound = 0
            var resolved = 0, followUp = 0, kept = 0, leftOpen = 0, toCheck = 0, openAfter = 0

            init() {}

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                func n(_ k: CodingKeys) throws -> Int { try c.decodeIfPresent(Int.self, forKey: k) ?? 0 }
                new = try n(.new); carried = try n(.carried); edited = try n(.edited); noteOnly = try n(.noteOnly)
                untouched = try n(.untouched); movedOnly = try n(.movedOnly); waiting = try n(.waiting)
                notFound = try n(.notFound); resolved = try n(.resolved); followUp = try n(.followUp); kept = try n(.kept)
                leftOpen = try n(.leftOpen); toCheck = try n(.toCheck); openAfter = try n(.openAfter)
            }

            enum CodingKeys: String, CodingKey {
                case new, carried, edited, noteOnly, untouched, movedOnly, waiting, notFound, resolved, followUp, kept, leftOpen
                case toCheck, openAfter
            }

            /// The comments in the round: written in it and carried into it (the readout's Comments).
            var present: Int { new + carried }
        }

        struct Changes: Decodable, Equatable {
            var total = 0, requested = 0, unrequested = 0, toCheck = 0

            init() {}

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                total = try c.decodeIfPresent(Int.self, forKey: .total) ?? 0
                requested = try c.decodeIfPresent(Int.self, forKey: .requested) ?? 0
                unrequested = try c.decodeIfPresent(Int.self, forKey: .unrequested) ?? 0
                toCheck = try c.decodeIfPresent(Int.self, forKey: .toCheck) ?? 0
            }

            enum CodingKeys: String, CodingKey { case total, requested, unrequested, toCheck }
        }

        /// Printed words (prose.json's word diff); nil while the round's prose is pending.
        struct Words: Decodable, Equatable {
            var body: Int?
            var added: Int?
            var deleted: Int?
        }

        struct Page: Decodable, Equatable {
            var page: Int
            var comments: Int?
            var changes: Int?
        }

        var n: Int
        var created: String?
        /// When the student's files were last changed (rounds ingested since `round.received`); the app's dates are
        /// `created`'s, this one only in the round's help tag.
        var received: String?
        var closed: Bool?
        var closedAt: String?
        var build: BuildInfo?
        var pdf: String?
        var finalPdf: String?
        var email: String?
        var comments: Comments?
        var changes: Changes?
        var words: Words?
        var heat: [Heat]?
        var pages: [Page]?
        /// OVERVIEW-v2 §5.2: "ok", "pending" or "unavailable" (§5.5: the row is drawn with pages only).
        var prose: String?
        var spans: [Span]?
        var match: [Match]?
        var edits: [Edit]?
        /// The comments the round could not place (orphans, no page): in its count, in no cell (§5.4, "+n unplaced").
        var unplaced: Int?
        /// An edit's first printed words (change id → at most 60 characters), for its help tag.
        var excerpts: [String: String]?
        /// The marks on its pages (only when asked with `marks: true`), for the thumbnails.
        var marks: [Mark]?

        var isClosed: Bool { closed ?? false }
        var failed: Bool { build?.status == "failed" }
        /// The sections are known: the row can be drawn with its cells (§5.5).
        var hasSections: Bool { (prose ?? "ok") == "ok" && !(spans ?? []).isEmpty }
    }

    /// `marks` row: [page, "comment" | "change", x0, y0, x1, y1, id], a rect in points from the page's top left; the id
    /// names the comment or change (an engine before 2026-10-19 sent none).
    struct Mark: Decodable, Equatable {
        var page: Int
        var kind: String
        var rect: CGRect
        var id: String?

        init(page: Int, kind: String, rect: CGRect, id: String?) {
            self.page = page
            self.kind = kind
            self.rect = rect
            self.id = id
        }

        init(from decoder: Decoder) throws {
            var t = try TupleReader(decoder)
            page = try t.int() ?? 0
            kind = try t.string() ?? "comment"
            let x0 = try t.double() ?? 0, y0 = try t.double() ?? 0, x1 = try t.double() ?? x0, y1 = try t.double() ?? y0
            rect = CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
            id = try t.id()
        }
    }

    /// `heat` row: [section, new, open_before, to_check, changes, added, deleted].
    struct Heat: Decodable, Equatable {
        var section: String
        var new: Int
        var openBefore: Int
        var toCheck: Int
        var changes: Int
        var added: Int?
        var deleted: Int?

        init(from decoder: Decoder) throws {
            var t = try TupleReader(decoder)
            section = try t.id() ?? ""
            new = try t.int() ?? 0
            openBefore = try t.int() ?? 0
            toCheck = try t.int() ?? 0
            changes = try t.int() ?? 0
            added = try t.int()
            deleted = try t.int()
        }

        /// The comments on the section in the round: written in it and open from before (the map's number, §4.2).
        var present: Int { new + openBefore }
    }

    /// `spans` row: [section_id, title, start, end, part?], in pages (pos = page index + fraction down the page, §5.4);
    /// `part`, when the engine sends it (VISUAL v3 §5.1): "front", "body", "references" or "appendix" (nil: the app
    /// works it out, `MapFold.parts`).
    struct Span: Decodable, Equatable {
        var section: String
        var title: String
        var start: Double
        var end: Double
        var part: String?

        init(section: String, title: String, start: Double, end: Double, part: String? = nil) {
            self.section = section
            self.title = title
            self.start = start
            self.end = end
            self.part = part
        }

        init(from decoder: Decoder) throws {
            var t = try TupleReader(decoder)
            section = try t.id() ?? ""
            title = try t.string() ?? ""
            start = try t.double() ?? 0
            end = try t.double() ?? start
            part = try? t.string()
        }
    }

    /// `match` row: [from, to, kind, kept, of] (§5.3): the previous round's section `from` sits in this round's `to`;
    /// kind same / renamed / merged / split / moved; `kept` of its `of` paragraphs.
    struct Match: Decodable, Equatable {
        var from: String?
        var to: String?
        var kind: String
        var kept: Int?
        var of: Int?

        init(from decoder: Decoder) throws {
            var t = try TupleReader(decoder)
            from = try t.id()
            to = try t.id()
            kind = try t.string() ?? "same"
            kept = try t.int()
            of = try t.int()
        }
    }

    /// `edits` row: [change_id, page, pos, section, attached_to, unrequested, to_check, move, added_words, deleted_words].
    struct Edit: Decodable, Equatable {
        var id: String
        var page: Int?
        var pos: Double?
        var section: String?
        var attachedTo: [String]
        var unrequested: Bool
        var toCheck: Bool
        var move: Bool
        var added: Int?
        var deleted: Int?

        init(from decoder: Decoder) throws {
            var t = try TupleReader(decoder)
            id = try t.id() ?? ""
            page = try t.int()
            pos = try t.double()
            section = try t.id()
            attachedTo = try t.strings() ?? []
            unrequested = try t.bool() ?? attachedTo.isEmpty
            toCheck = try t.bool() ?? false
            move = try t.bool() ?? false
            added = try t.int()
            deleted = try t.int()
        }
    }

    /// A comment's way through the rounds (`comments[].path`).
    struct Comment: Decodable, Equatable {
        /// [round, state, page, pos, section, response, answer]; state placed / gone / unplaced.
        struct Step: Decodable, Equatable {
            var round: Int
            var state: String
            var page: Int?
            var pos: Double?
            var section: String?
            var response: String?
            var answer: String?

            init(from decoder: Decoder) throws {
                var t = try TupleReader(decoder)
                round = try t.int() ?? 0
                state = try t.string() ?? "placed"
                page = try t.int()
                pos = try t.double()
                section = try t.id()
                response = try t.string()
                answer = try t.string()
            }
        }

        /// A round it was reopened into, and the round it had been closed in (CONTRACT amendment "Tags, key page and
        /// Reopen": `revived`).
        struct Revive: Decodable, Equatable {
            var round: Int
            var from: Int?
        }

        var id: String
        var createdRound: Int?
        /// highlight, underline, strikeout, note or box; its mark colour (nil: yellow); what the advisor wrote.
        var kind: String?
        var color: String?
        var note: String?
        var path: [Step]
        /// The advisor's writing tags on it, in the order put on ([] for none or from an engine before tags).
        var tags: [String] = []
        /// The rounds it was reopened into ([] when never), and whether it can be reopened into the open round now.
        var revived: [Revive] = []
        var revivable = false

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            createdRound = try c.decodeIfPresent(Int.self, forKey: .createdRound)
            kind = try c.decodeIfPresent(String.self, forKey: .kind)
            color = try c.decodeIfPresent(String.self, forKey: .color)
            note = try c.decodeIfPresent(String.self, forKey: .note)
            path = try c.decodeIfPresent([Step].self, forKey: .path) ?? []
            tags = (try? c.decodeIfPresent([String].self, forKey: .tags)) ?? []
            revived = (try? c.decodeIfPresent([Revive].self, forKey: .revived)) ?? []
            revivable = (try? c.decodeIfPresent(Bool.self, forKey: .revivable)) ?? false
        }

        enum CodingKeys: String, CodingKey { case id, createdRound, kind, color, note, path, tags, revived, revivable }

        func step(in round: Int) -> Step? { path.first { $0.round == round } }

        /// The round the overview shows it in (the strip's, Review's): the strip's round when it is there, else the
        /// last round it has a page in (placed, or its passage deleted there), else its last.
        func shownRound(strip: Int?) -> Int? {
            if let n = strip, step(in: n) != nil { return n }
            return path.last { $0.page != nil && $0.state != "unplaced" }?.round ?? path.last?.round
        }
    }

    /// The paper's comments over all rounds; `closedAfter`: how many rounds they took to close ("1", "2", "3+").
    struct Threads: Decodable, Equatable {
        var comments: Int?
        var resolved: Int?
        var kept: Int?
        var open: Int?
        var followedUp: Int?
        var untouchedAfterFollowUp: Int?
        var closedAfter: [String: Int]?
    }

    /// The paper's key page (CONTRACT amendment "Tags, key page and Reopen"): in its latest built round, the page the
    /// advisor chose (followed through the rounds) or the busiest one.
    struct KeyPage: Decodable, Equatable {
        var round: Int
        var page: Int
        var chosen: Bool?
        var followed: String?
    }

    var paper: Paper?
    var summary: PaperSummary?
    var sections: [Section]
    var rounds: [Round]
    var comments: [Comment]
    var threads: Threads?
    var pending: [Int]
    /// The writing tags' numbers (`tags.paper_tags`); nil from an engine before tags.
    var tags: PaperTags?
    var keyPage: KeyPage?
    /// The names the ledger keeps for the advisor's own tags (`tag_names`): a tag the catalogue lacks still has a name.
    var tagNames: [String: String] = [:]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        paper = try c.decodeIfPresent(Paper.self, forKey: .paper)
        summary = try c.decodeIfPresent(PaperSummary.self, forKey: .summary)
        sections = try c.decodeIfPresent([Section].self, forKey: .sections) ?? []
        rounds = (try c.decodeIfPresent([Round].self, forKey: .rounds) ?? []).sorted { $0.n < $1.n }
        comments = try c.decodeIfPresent([Comment].self, forKey: .comments) ?? []
        threads = try c.decodeIfPresent(Threads.self, forKey: .threads)
        pending = try c.decodeIfPresent([Int].self, forKey: .pending) ?? []
        tags = try? c.decodeIfPresent(PaperTags.self, forKey: .tags)
        keyPage = try? c.decodeIfPresent(KeyPage.self, forKey: .keyPage)
        tagNames = (try? c.decodeIfPresent([String: String].self, forKey: .tagNames)) ?? [:]
    }

    enum CodingKeys: String, CodingKey { case paper, summary, sections, rounds, comments, threads, pending, tags, keyPage, tagNames }

    func round(_ n: Int) -> Round? { rounds.first { $0.n == n } }
    var latest: Round? { rounds.last }
    func comment(_ id: String) -> Comment? { comments.first { $0.id == id } }

    /// A section's title without its number: the engine's name for it when the title is that name after a number ("A
    /// Extra": a lone appendix's letter, which `Outline.numbers` cannot tell from a word in one title), else
    /// `MapScene.shortName` ("Limitations" from "5 Limitations", "Abstract" for the front matter).
    func shortTitle(_ key: String, _ title: String) -> String {
        if let name = sections.first(where: { $0.key == key })?.name, !name.isEmpty, title != name, title.hasSuffix(" " + name) {
            return name
        }
        return MapScene.shortName(title)
    }

    /// A section's title in a round (its span), or the paper's sections list, or nil.
    func sectionTitle(_ id: String, round n: Int? = nil) -> String? {
        if let n, let s = round(n)?.spans?.first(where: { $0.section == id }) { return s.title }
        for r in rounds.reversed() { if let s = r.spans?.first(where: { $0.section == id }) { return s.title } }
        return sections.first { $0.key == id }?.title
    }

    static func decodeReply(_ data: Data) throws -> OverviewReply {
        try makeDecoder().decode(OverviewReply.self, from: data)
    }
}

/// An id that the engine may send as a number (a heading's block) or a string; nil for null.
struct FlexibleID: Decodable, Equatable {
    var value: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { value = nil }
        else if let i = try? c.decode(Int.self) { value = String(i) }
        else if let d = try? c.decode(Double.self) { value = d == d.rounded() ? String(Int(d)) : String(d) }
        else { value = try c.decode(String.self) }
    }
}

/// Reads a JSON array by position; a missing or null item reads as nil.
struct TupleReader {
    private var c: UnkeyedDecodingContainer

    init(_ decoder: Decoder) throws { c = try decoder.unkeyedContainer() }

    private mutating func next<T: Decodable>(_ t: T.Type) throws -> T? {
        guard !c.isAtEnd else { return nil }
        if try c.decodeNil() { return nil }
        return try c.decode(T.self)
    }

    mutating func int() throws -> Int? {
        guard let d = try next(Double.self) else { return nil }
        return Int(d.rounded())
    }

    mutating func double() throws -> Double? { try next(Double.self) }
    mutating func string() throws -> String? { try next(String.self) }
    /// true / false, or a number (0 is false)
    mutating func bool() throws -> Bool? {
        guard !c.isAtEnd else { return nil }
        if try c.decodeNil() { return nil }
        if let b = try? c.decode(Bool.self) { return b }
        return try c.decode(Double.self) != 0
    }
    mutating func id() throws -> String? { try next(FlexibleID.self)?.value }
    mutating func strings() throws -> [String]? { try next([FlexibleID].self)?.compactMap(\.value) }
}
