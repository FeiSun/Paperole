import Foundation
import PDFKit

// The round card's numbers (design/stats-card, the "Ledger" card; request of 2026-10-26): every one from the shown
// round's state (`state {paper, round: n}`), so the engine needs nothing new. Pure, so each rule is tested
// (RoundCardTests); the views are in RoundCard.swift.

/// The engine's word rule (overview.WORD): the tokens of `[㐀-鿿豈-﫿]|[^\s㐀-鿿豈-﫿]+`
/// that hold a letter or a digit. One Chinese character is one word, as Word counts them: "多余，删掉。" is 4 words,
/// "Fig. 3 很好" 4, punctuation alone 0. Counted over Unicode scalars, as Python counts code points.
enum CardWords {
    static func count(_ text: String) -> Int {
        var n = 0
        var run = false, runHasWord = false
        func close() {
            if run && runHasWord { n += 1 }
            run = false
            runHasWord = false
        }
        for s in text.unicodeScalars {
            if isCJK(s) {
                close()
                if isWordScalar(s) { n += 1 }
            } else if s.properties.isWhitespace {
                close()
            } else {
                run = true
                if isWordScalar(s) { runHasWord = true }
            }
        }
        close()
        return n
    }

    static func isCJK(_ s: Unicode.Scalar) -> Bool {
        (0x3400...0x9FFF).contains(s.value) || (0xF900...0xFAFF).contains(s.value)
    }

    /// Python's `str.isalnum` for one code point: a letter (Lu, Ll, Lt, Lm, Lo) or a number.
    static func isWordScalar(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return s.properties.numericType != nil
        }
    }
}

/// A calendar day as an engine time writes it ("2026-10-21T09:12:00+08:00" is Oct 21, in its own offset), as the
/// overview's `_days` reads it.
struct CardDay: Equatable, Comparable {
    var year: Int
    var month: Int
    var day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init?(iso: String?) {
        guard let iso, iso.count >= 10 else { return nil }
        let p = iso.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard p.count == 3, (1...12).contains(p[1]), (1...31).contains(p[2]) else { return nil }
        self.init(year: p[0], month: p[1], day: p[2])
    }

    /// This Mac's date of `date`.
    init(_ date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    private static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private var date: Date? { Self.utc.date(from: DateComponents(year: year, month: month, day: day)) }

    /// Calendar days from this day to `other`.
    func days(to other: CardDay) -> Int {
        guard let a = date, let b = other.date else { return 0 }
        return Self.utc.dateComponents([.day], from: a, to: b).day ?? 0
    }

    static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    /// "Oct 21"
    var short: String { Self.months[month - 1] + " \(day)" }

    static func < (a: CardDay, b: CardDay) -> Bool { (a.year, a.month, a.day) < (b.year, b.month, b.day) }
}

struct RoundStats: Equatable {
    /// A tag's row: its id, its name, how many of the round's new comments have it.
    struct TagRow: Equatable {
        var id: String
        var name: String
        var count: Int
    }

    /// Where a comment written or followed up this round starts on its page: the top of its first rect as a share of
    /// the page's height, its column (0 left, 1 right), and how it is drawn (a box a frame, a note a dot, any other
    /// mark a stroke; a follow-up's stroke shorter).
    struct Mark: Equatable {
        enum Kind: String { case stroke, dot, frame }
        var page: Int
        var y: Double
        var column: Int
        var kind: Kind
        var followUp = false
    }

    /// A number of the grid beside the word count: "16 New", "12 of 12 Pages with a mark".
    struct Figure: Equatable {
        var value: Int
        var of: Int? = nil
        var label: String
    }

    var round: Int
    var closed: Bool
    var start: CardDay?
    /// The day the round was finished, or today while it is open.
    var end: CardDay?
    var days: Int?
    var pages: Int
    /// The first page's height over its width (the strip's small pages).
    var aspect: Double
    var words: Int
    /// What the words were written in, the kinds present: "notes", "follow-ups", "closing remarks" (singular for one).
    var wrote: [String]
    var new: Int
    var carried: Int
    var resolved: Int
    var followedUp: Int
    var kept: Int
    var leftOpen: Int
    /// The new comments' tags but praise, in the catalogue's order, each with its count.
    var tags: [TagRow]
    var praise: Int
    var untagged: Int
    var marks: [Mark]
    var edits: Int
    var own: Int
    var studentNotes: Int
    var facts: [String]
    /// The automatic checks that went out with the round (or go out, while it is open), and those fixed since the
    /// round before (open rounds only): the card's Paperole line.
    var checksSent: Int?
    var checksFixed = 0
    var title: String
    var student: String

    /// `pageSizes`: each page's size in points (the round PDF's crop box; 612 × 792 when not known); `today`: for an
    /// open round's days.
    init(state st: EngineState, pageSizes: [CGSize] = [], catalog: TagCatalog = TagCatalog.current, today: Date = Date()) {
        let r = st.round
        let n = r?.n ?? 0
        round = n
        closed = r?.closed ?? false
        title = st.paper.title
        student = st.paper.student
        start = CardDay(iso: r?.created)
        end = closed ? CardDay(iso: r?.closedAt) : CardDay(today)
        if let s = start, let e = end { days = max(0, s.days(to: e)) } else { days = nil }

        let fresh = st.comments.filter { $0.createdRound == n }
        let older = st.comments.filter { $0.createdRound < n }
        new = fresh.count
        carried = older.count
        resolved = older.filter { $0.verdict == "verified" }.count
        followedUp = older.filter { $0.verdict == "reopened" }.count
        kept = older.filter { $0.verdict == "wontfix" }.count
        leftOpen = older.filter { $0.verdict == nil }.count

        // the words: each new comment's note, each answered carried one's follow-up or closing remark
        var texts: [(id: String, words: Int)] = fresh.map { ($0.id, CardWords.count($0.note)) }
        let answers = older.filter { $0.verdict != nil }.map { (id: $0.id, verdict: $0.verdict, words: CardWords.count($0.verdictNote ?? "")) }
        texts += answers.map { ($0.id, $0.words) }
        words = texts.reduce(0) { $0 + $1.words }
        let notes = fresh.filter { CardWords.count($0.note) > 0 }.count
        let followUps = answers.filter { $0.verdict == "reopened" && $0.words > 0 }.count
        let remarks = answers.filter { $0.verdict != "reopened" && $0.words > 0 }.count
        wrote = [(notes, "note", "notes"), (followUps, "follow-up", "follow-ups"), (remarks, "closing remark", "closing remarks")]
            .filter { $0.0 > 0 }.map { $0.0 == 1 ? $0.1 : $0.2 }

        // the tags of the new comments: a comment with two counts in both; praise apart
        var counts: [String: Int] = [:]
        for c in fresh { for id in Set(c.tagIDs) { counts[id, default: 0] += 1 } }
        praise = counts["praise"] ?? 0
        untagged = fresh.filter { $0.tagIDs.isEmpty }.count
        tags = catalog.sorted(Array(counts.keys).sorted()).filter { $0 != "praise" }
            .map { TagRow(id: $0, name: catalog.name($0, backup: st.tagNames ?? [:]), count: counts[$0] ?? 0) }

        // the marks: the new comments and the follow-ups, where each starts on its page
        let columns = r?.build.columns ?? []
        var marks: [Mark] = []
        for c in fresh + older.filter({ $0.verdict == "reopened" }) {
            guard let p = c.page, p >= 0 else { continue }
            let size = p < pageSizes.count ? pageSizes[p] : CGSize(width: 612, height: 792)
            let rect: [Double]? = c.rects.first.flatMap { $0.count >= 2 ? $0 : nil }
            let y: Double = rect.map { size.height > 0 ? $0[1] / Double(size.height) : 0.5 } ?? 0.5
            let x0: Double = rect?[0] ?? 0
            let split: Double = (p < columns.count ? columns[p]?.first : nil) ?? Double(size.width) / 2
            let kind: Mark.Kind = c.markKind == .box ? .frame : c.markKind == .note ? .dot : .stroke
            marks.append(Mark(page: p, y: min(max(y, 0), 0.97), column: x0 >= split ? 1 : 0, kind: kind,
                              followUp: c.createdRound < n))
        }
        self.marks = marks.sorted { ($0.page, $0.y) < ($1.page, $1.y) }
        pages = max(r?.build.pages ?? pageSizes.count, (marks.map(\.page).max() ?? -1) + 1)
        aspect = pageSizes.first.map { $0.width > 0 ? Double($0.height / $0.width) : 792 / 612 } ?? 792 / 612

        edits = st.changes.count
        own = st.changes.filter(\.unrequested).count
        studentNotes = st.comments.filter { !($0.studentNote?.isEmpty ?? true) }.count
        checksSent = r?.checksSent
        checksFixed = r?.checksFixed ?? 0

        // the facts, the first two that hold (only facts: no better or worse, no earlier round, no "most" for a tag)
        var facts: [String] = []
        // the oldest comment resolved now, open since two rounds or more (the first by id on a tie)
        let late = older.filter { $0.verdict == "verified" && n - $0.createdRound >= 2 }.sorted {
            $0.createdRound != $1.createdRound ? $0.createdRound < $1.createdRound
                : $0.id.localizedStandardCompare($1.id) == .orderedAscending
        }.first
        if let c = late { facts.append("\(c.id) is resolved after \(Self.spelled(n - c.createdRound)) rounds.") }
        if carried > 0 && leftOpen == 0 {
            let all = carried == 1 ? "The one earlier comment" : carried == 2 ? "Both earlier comments"
                : "All \(Self.spelled(carried)) earlier comments"
            let noted = followedUp > 0 && answers.filter { $0.verdict == "reopened" }.allSatisfy { $0.words > 0 }
            facts.append(all + " answered" + (noted ? (followedUp == 1 ? ", the follow-up with a note" : ", every follow-up with a note") : "") + ".")
        }
        var perPage: [Int: Int] = [:]
        for m in marks { perPage[m.page, default: 0] += 1 }
        if let busy = perPage.max(by: { ($0.value, -$0.key) < ($1.value, -$1.key) }), busy.value >= 3 {
            facts.append("Busiest page: p.\(busy.key + 1), with \(Self.spelled(busy.value)) of your comments.")
        }
        var long: (id: String, words: Int)?  // the longest text, the first of the longest
        for t in texts where t.words > (long?.words ?? 0) { long = t }
        if let long, long.words >= 40 { facts.append("Longest note: \(Self.spelled(long.words)) words, on \(long.id).") }
        if closed && days == 0 { facts.append("Finished the day it came in.") }
        self.facts = Array(facts.prefix(2))
    }

    /// One to nine in words, other numbers in digits ("five", "14", "1,146").
    static func spelled(_ k: Int) -> String {
        let w = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
        return (1...9).contains(k) ? w[k - 1] : grouped(k)
    }

    /// "1,146"
    static func grouped(_ k: Int) -> String {
        let s = String(abs(k))
        var out = ""
        for (i, ch) in s.enumerated() {
            if i > 0 && (s.count - i) % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return (k < 0 ? "-" : "") + out
    }

    static func count(_ k: Int, _ one: String, _ many: String? = nil) -> String {
        "\(grouped(k)) " + (k == 1 ? one : many ?? one + "s")
    }

    // MARK: Words of the card

    /// "Oct 21 – Oct 24, 2026 · 3 days · 14 pages"; "Nov 9, 2026 · the same day · 15 pages".
    var dateLine: String {
        var parts: [String] = []
        if let s = start, let e = end {
            if s == e {
                parts.append("\(e.short), \(e.year)")
            } else {
                parts.append((s.year == e.year ? s.short : "\(s.short), \(s.year)") + " – \(e.short), \(e.year)")
            }
        }
        if let d = days { parts.append(d == 0 ? "the same day" : Self.count(d, "day")) }
        parts.append(Self.count(pages, "page"))
        return parts.joined(separator: " · ")
    }

    /// The compact card's, while the round is open: "Oct 21 – today · 3 days" ("Oct 25 · today").
    var soFarLine: String {
        guard let s = start else { return Self.count(pages, "page") }
        guard let d = days, d > 0 else { return "\(s.short) · today" }
        return "\(s.short) – today · " + Self.count(d, "day")
    }

    /// "in your notes, follow-ups and closing remarks", naming only the kinds present; nil for none.
    var wroteLine: String? {
        wrote.isEmpty ? nil : "in your " + TransferText.list(wrote)
    }

    /// The grid beside the word count. Round 1: New, Pages with a mark and Well done (when some); later: New,
    /// Resolved, Followed up and Kept as is, and with no new comment the three answers and Left open (when some).
    var figures: [Figure] {
        if round <= 1 {
            return [Figure(value: new, label: "New"), Figure(value: Set(marks.map(\.page)).count, of: pages, label: "Pages with a mark")]
                + (praise > 0 ? [Figure(value: praise, label: "Well done")] : [])
        }
        let answers = [Figure(value: resolved, label: "Resolved"), Figure(value: followedUp, label: "Followed up"),
                       Figure(value: kept, label: "Kept as is")]
        if new > 0 { return [Figure(value: new, label: "New")] + answers }
        return answers + (leftOpen > 0 ? [Figure(value: leftOpen, label: "Left open")] : [])
    }

    /// The tag section shows when a new comment has a tag other than praise.
    var tagsShown: Bool { !tags.isEmpty }

    /// The table's rows in the catalogue's order and the tags folded into one line: past `maxRows` rows the smallest
    /// counts fold (the later tag on a tie), so the table keeps `maxRows - 1` rows and the line.
    func tagTable(maxRows: Int) -> (rows: [TagRow], folded: [TagRow]) {
        guard tags.count > maxRows else { return (tags, []) }
        let keep = Set(tags.indices.sorted { (-tags[$0].count, $0) < (-tags[$1].count, $1) }.prefix(maxRows - 1))
        return (tags.indices.filter(keep.contains).map { tags[$0] }, tags.indices.filter { !keep.contains($0) }.map { tags[$0] })
    }

    /// The line under the table: "Also Structure 1 · Math & notation 1 · 1 not tagged" (`names`), or "Also 3 more tags
    /// · 1 not tagged" (the compact card's); nil when there is nothing to say.
    func alsoLine(_ folded: [TagRow], names: Bool) -> String? {
        var parts: [String] = []
        if !folded.isEmpty {
            parts.append("Also " + (names ? folded.map { "\($0.name) \($0.count)" }.joined(separator: " · ")
                                    : Self.count(folded.count, "more tag")))
        }
        if untagged > 0 { parts.append("\(untagged) not tagged") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "The student · 27 edits, 6 of their own · 5 notes on your comments" (the name instead when `named`); nil in
    /// round 1, and when the student made no edit and wrote no note.
    func studentLine(named: Bool) -> (lead: String, rest: String)? {
        guard round > 1, edits > 0 || studentNotes > 0 else { return nil }
        var parts: [String] = []
        if edits > 0 { parts.append(Self.count(edits, "edit") + (own > 0 ? ", \(Self.grouped(own)) of their own" : "")) }
        if studentNotes > 0 { parts.append(Self.count(studentNotes, "note") + " on your comments") }
        return (named && !student.isEmpty ? student : "The student", parts.joined(separator: " · "))
    }

    /// "Paperole · 7 automatic checks · 4 fixed": what Paperole sent with the round; nil when it sent none and none
    /// were fixed (Checks off, or an engine before it).
    var checksLine: (lead: String, rest: String)? {
        let n = checksSent ?? 0
        guard n > 0 || checksFixed > 0 else { return nil }
        var parts = [Self.count(n, "automatic check")]
        if checksFixed > 0 { parts.append("\(Self.grouped(checksFixed)) fixed") }
        return ("Paperole", parts.joined(separator: " · "))
    }

    // MARK: Page sizes

    nonisolated(unsafe) private static var sizes: [String: (date: Date?, sizes: [CGSize])] = [:]

    /// Each page's size in points (its crop box, turned as shown) of a round PDF, read once per file version; [] when
    /// it cannot be read. Read only: PDFKit never saves here.
    static func pageSizes(_ path: String?) -> [CGSize] {
        guard let path else { return [] }
        let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if let hit = sizes[path], hit.date == date { return hit.sizes }
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else { return [] }
        let out: [CGSize] = (0..<doc.pageCount).map { i in
            guard let p = doc.page(at: i) else { return CGSize(width: 612, height: 792) }
            let b = p.bounds(for: .cropBox).size
            return p.rotation % 180 == 0 ? b : CGSize(width: b.height, height: b.width)
        }
        sizes[path] = (date, out)
        return out
    }
}
