import Foundation

// The engine's numbers for the writing tags (CONTRACT amendment "Tags, key page and Reopen": `overview`'s paper `tags`
// and `students[].tags`). Every field decodes as optional, so an engine with more or fewer fields still decodes and a
// student's page never loses its other numbers to a field it does not know. Dictionary keys are tag ids (no
// underscores, so the decoder's snake-case conversion leaves them alone); the per-paper counts keyed by path (a path
// may hold one) are read through `TagRow.count(in:)`, which looks a path up as the decoder gives keys.

/// One tag's row (or the Not tagged row): its comments each once, how many are open, how they closed (after 1, 2 or
/// 3+ rounds the advisor answered in), followed up, reopened, the sections they were written in (most first), and per
/// paper its comments in it (a student's row; UI v4's Topics per paper).
struct TagRow: Decodable, Equatable {
    var comments = 0
    var open = 0
    var followedUp = 0
    var revived = 0
    var closedAfter: [String: Int] = [:]
    var writtenIn: [(key: String, count: Int)] = []
    /// Keyed by path as the decoder gives keys: read with `count(in:)`.
    var papers: [String: Int] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        comments = (try? c.decodeIfPresent(Int.self, forKey: .comments)) ?? 0
        open = (try? c.decodeIfPresent(Int.self, forKey: .open)) ?? 0
        followedUp = (try? c.decodeIfPresent(Int.self, forKey: .followedUp)) ?? 0
        revived = (try? c.decodeIfPresent(Int.self, forKey: .revived)) ?? 0
        closedAfter = (try? c.decodeIfPresent([String: Int].self, forKey: .closedAfter)) ?? [:]
        writtenIn = ((try? c.decodeIfPresent([Pair].self, forKey: .writtenIn)) ?? []).map { ($0.key, $0.count) }
        papers = (try? c.decodeIfPresent([String: Int].self, forKey: .papers)) ?? [:]
    }

    private enum Keys: String, CodingKey { case comments, open, followedUp, revived, closedAfter, writtenIn, papers }

    /// The row's comments in the paper at `path`: looked up as given and as the app's decoder turns that key (a
    /// Foundation that applies the snake-case conversion to dictionary keys makes "my_paper" "myPaper").
    func count(in path: String) -> Int {
        papers[path] ?? papers[Self.decoded(path)] ?? 0
    }

    /// The decoder's form of a path key, worked out once per path (Topics asks for each tag and paper as it draws).
    private static let keys = NSCache<NSString, NSString>()

    private static func decoded(_ path: String) -> String {
        if let k = keys.object(forKey: path as NSString) { return k as String }
        let json = try? JSONSerialization.data(withJSONObject: [path: 0])
        let key = json.flatMap { try? makeDecoder().decode([String: Int].self, from: $0).keys.first } ?? path
        keys.setObject(key as NSString, forKey: path as NSString)
        return key
    }

    /// A `[key, k]` pair.
    private struct Pair: Decodable {
        var key: String
        var count: Int
        init(from decoder: Decoder) throws {
            var t = try TupleReader(decoder)
            key = try t.id() ?? ""
            count = try t.int() ?? 0
        }
    }

    static func == (a: TagRow, b: TagRow) -> Bool {
        a.comments == b.comments && a.open == b.open && a.followedUp == b.followedUp && a.revived == b.revived
            && a.closedAfter == b.closedAfter && a.writtenIn.map(\.key) == b.writtenIn.map(\.key)
            && a.writtenIn.map(\.count) == b.writtenIn.map(\.count) && a.papers == b.papers
    }

    /// Closed after 1, 2 and 3+ answered rounds.
    var one: Int { closedAfter["1"] ?? 0 }
    var two: Int { closedAfter["2"] ?? 0 }
    var three: Int { closedAfter["3+"] ?? 0 }
}

/// A paper's `tags`: per round the new comments by tag (each comment in the round it was written), per tag its row,
/// the Not tagged row; `comments`, `tagged` and `open` count each comment once.
struct PaperTags: Decodable, Equatable {
    struct Round: Decodable, Equatable {
        var n: Int
        var new = 0
        var untagged = 0
        var byTag: [String: Int] = [:]

        init(n: Int, new: Int = 0, untagged: Int = 0, byTag: [String: Int] = [:]) {
            self.n = n
            self.new = new
            self.untagged = untagged
            self.byTag = byTag
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            n = (try? c.decodeIfPresent(Int.self, forKey: .n)) ?? 0
            new = (try? c.decodeIfPresent(Int.self, forKey: .new)) ?? 0
            untagged = (try? c.decodeIfPresent(Int.self, forKey: .untagged)) ?? 0
            byTag = (try? c.decodeIfPresent([String: Int].self, forKey: .byTag)) ?? [:]
        }

        private enum Keys: String, CodingKey { case n, new, untagged, byTag }
    }

    var comments = 0
    var tagged = 0
    var open = 0
    var rounds: [Round] = []
    var byTag: [String: TagRow] = [:]
    var untagged = TagRow()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        comments = (try? c.decodeIfPresent(Int.self, forKey: .comments)) ?? 0
        tagged = (try? c.decodeIfPresent(Int.self, forKey: .tagged)) ?? 0
        open = (try? c.decodeIfPresent(Int.self, forKey: .open)) ?? 0
        rounds = ((try? c.decodeIfPresent([Round].self, forKey: .rounds)) ?? []).sorted { $0.n < $1.n }
        byTag = (try? c.decodeIfPresent([String: TagRow].self, forKey: .byTag)) ?? [:]
        untagged = (try? c.decodeIfPresent(TagRow.self, forKey: .untagged)) ?? TagRow()
    }

    private enum Keys: String, CodingKey { case comments, tagged, open, rounds, byTag, untagged }
}

/// A student's `tags`, the writing profile across papers: every built round in time order, the rows, the first
/// drafts' trend words, at most two single facts, For the next draft and Well done.
struct StudentTags: Decodable, Equatable {
    struct Round: Decodable, Equatable {
        var path: String
        var n: Int
        var date: String?
        var pages: Int?
        var first = false
        var closed = false
        var added: Int?
        var new = 0
        var untagged = 0
        var byTag: [String: Int] = [:]

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            path = (try? c.decodeIfPresent(String.self, forKey: .path)) ?? ""
            n = (try? c.decodeIfPresent(Int.self, forKey: .n)) ?? 0
            date = try? c.decodeIfPresent(String.self, forKey: .date)
            pages = try? c.decodeIfPresent(Int.self, forKey: .pages)
            first = (try? c.decodeIfPresent(Bool.self, forKey: .first)) ?? (n == 1)
            closed = (try? c.decodeIfPresent(Bool.self, forKey: .closed)) ?? false
            added = try? c.decodeIfPresent(Int.self, forKey: .added)
            new = (try? c.decodeIfPresent(Int.self, forKey: .new)) ?? 0
            untagged = (try? c.decodeIfPresent(Int.self, forKey: .untagged)) ?? 0
            byTag = (try? c.decodeIfPresent([String: Int].self, forKey: .byTag)) ?? [:]
        }

        private enum Keys: String, CodingKey { case path, n, date, pages, first, closed, added, new, untagged, byTag }
    }

    struct Trend: Decodable, Equatable {
        /// fewer, more, same, mixed, or nil with `why`: two_points, small, untagged, lengths_differ.
        var word: String?
        var why: String?
        var counts: [Int] = []

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            word = try? c.decodeIfPresent(String.self, forKey: .word)
            why = try? c.decodeIfPresent(String.self, forKey: .why)
            counts = (try? c.decodeIfPresent([Int].self, forKey: .counts)) ?? []
        }

        private enum Keys: String, CodingKey { case word, why, counts }
    }

    struct Skipped: Decodable, Equatable {
        var path: String
        var why: String
    }

    struct FirstDrafts: Decodable, Equatable {
        var points: [String] = []
        var skipped: [Skipped] = []
        var trend: [String: Trend] = [:]

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            points = (try? c.decodeIfPresent([String].self, forKey: .points)) ?? []
            skipped = (try? c.decodeIfPresent([Skipped].self, forKey: .skipped)) ?? []
            trend = (try? c.decodeIfPresent([String: Trend].self, forKey: .trend)) ?? [:]
        }

        private enum Keys: String, CodingKey { case points, skipped, trend }
    }

    /// A single fact: none_since (path, round), slow (n of `of`), new_words (path, round, n, words).
    struct Fact: Decodable, Equatable {
        var tag: String
        var kind: String
        var path: String?
        var round: Int?
        var n: Int?
        var of: Int?
        var words: Int?
    }

    struct Example: Decodable, Equatable {
        var path: String?
        var id: String?
        var round: Int?
        var page: Int?
        var text: String?
        var note: String?
    }

    struct Focus: Decodable, Equatable {
        var tag: String
        var comments: Int?
        var open: Int?
        var followedUp: Int?
        var score: Int?
        var example: Example?
    }

    struct Praise: Decodable, Equatable {
        var comments: Int?
        var latest: Example?
    }

    var comments = 0
    var tagged = 0
    var rounds: [Round] = []
    var byTag: [String: TagRow] = [:]
    var untagged = TagRow()
    var firstDrafts = FirstDrafts()
    var facts: [Fact] = []
    var focus: [Focus] = []
    var praise: Praise?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        comments = (try? c.decodeIfPresent(Int.self, forKey: .comments)) ?? 0
        tagged = (try? c.decodeIfPresent(Int.self, forKey: .tagged)) ?? 0
        rounds = (try? c.decodeIfPresent([Round].self, forKey: .rounds)) ?? []
        byTag = (try? c.decodeIfPresent([String: TagRow].self, forKey: .byTag)) ?? [:]
        untagged = (try? c.decodeIfPresent(TagRow.self, forKey: .untagged)) ?? TagRow()
        firstDrafts = (try? c.decodeIfPresent(FirstDrafts.self, forKey: .firstDrafts)) ?? FirstDrafts()
        facts = (try? c.decodeIfPresent([Fact].self, forKey: .facts)) ?? []
        focus = (try? c.decodeIfPresent([Focus].self, forKey: .focus)) ?? []
        praise = try? c.decodeIfPresent(Praise.self, forKey: .praise)
    }

    private enum Keys: String, CodingKey { case comments, tagged, rounds, byTag, untagged, firstDrafts, facts, focus, praise }
}
