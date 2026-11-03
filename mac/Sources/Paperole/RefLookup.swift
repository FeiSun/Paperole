import AppKit
import Foundation
import WebKit

// Looking the references up online (design/pdf-reader/PLAN.md P1.3; engine/CONTRACT.md amendment "References"): the
// engine gives a round's cited entries (`references`), the app asks Semantic Scholar and Google Scholar about them, one
// at a time and slowly, and gives the engine what it found (`ref_results`), which turns it into checks. Each source has
// its setting, off by default; nothing is sent while it is off. Only a cited work's title, arXiv id or DOI leaves the
// Mac. Nothing is disguised: Semantic Scholar's public API at its pace, Google Scholar in a WebKit view of the app's
// own, at most one search a minute and a few dozen a day, stopping at a CAPTCHA until the advisor answers it.

/// A cited entry, as the engine's `references` gives it (lenient).
struct RefEntry: Decodable, Equatable {
    var key: String
    var label: String?
    var title: String?
    var authors: [String]
    var year: String?
    var venue: String?
    var arxiv: String?
    var doi: String?
    var preprint: Bool

    init(key: String, label: String? = nil, title: String?, authors: [String] = [], year: String? = nil,
         venue: String? = nil, arxiv: String? = nil, doi: String? = nil, preprint: Bool = false) {
        self.key = key
        self.label = label
        self.title = title
        self.authors = authors
        self.year = year
        self.venue = venue
        self.arxiv = arxiv
        self.doi = doi
        self.preprint = preprint
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? nil
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil
        authors = ((try? c.decodeIfPresent([String].self, forKey: .authors)) ?? nil) ?? []
        if let y = (try? c.decodeIfPresent(String.self, forKey: .year)) ?? nil { year = y }
        else { year = ((try? c.decodeIfPresent(Int.self, forKey: .year)) ?? nil).map(String.init) }
        venue = (try? c.decodeIfPresent(String.self, forKey: .venue)) ?? nil
        arxiv = (try? c.decodeIfPresent(String.self, forKey: .arxiv)) ?? nil
        doi = (try? c.decodeIfPresent(String.self, forKey: .doi)) ?? nil
        preprint = ((try? c.decodeIfPresent(Bool.self, forKey: .preprint)) ?? nil) ?? false
    }

    private enum CodingKeys: String, CodingKey { case key, label, title, authors, year, venue, arxiv, doi, preprint }

    /// What the global cache knows it by: its arXiv id, else its DOI, else its folded title.
    var lookupKey: String? {
        if let a = arxiv, !a.isEmpty { return "arxiv:" + a.lowercased() }
        if let d = doi, !d.isEmpty { return "doi:" + d.lowercased() }
        let t = RefText.fold(title ?? "")
        return t.isEmpty ? nil : "title:" + t
    }
}

/// What a source found for an entry (engine/CONTRACT.md "References" Result), and when.
struct RefResult: Codable, Equatable {
    struct Closest: Codable, Equatable {
        var title: String?
        var year: Int?
        var authors: [String]?
    }

    var found: Bool
    var title: String?
    var year: Int?
    var venue: String?
    var authors: [String]?
    var citations: Int?
    var url: String?
    var doi: String?
    var arxiv: String?
    var record: String?
    var published: String?
    var closest: Closest?
    /// When it was looked up (the app's cache; not sent).
    var at: Date?

    /// The engine's form: every field but `at`.
    var json: [String: Any] {
        var d: [String: Any] = ["found": found]
        func put(_ k: String, _ v: Any?) { if let v { d[k] = v } }
        put("title", title); put("year", year); put("venue", venue); put("authors", authors); put("citations", citations)
        put("url", url); put("doi", doi); put("arxiv", arxiv); put("record", record); put("published", published)
        if let c = closest {
            var cd: [String: Any] = [:]
            if let t = c.title { cd["title"] = t }
            if let y = c.year { cd["year"] = y }
            if let a = c.authors { cd["authors"] = a }
            d["closest"] = cd
        }
        return d
    }
}

/// The engine's `references` reply.
struct ReferencesReply: Decodable {
    var round: Int?
    var entries: [RefEntry]?
    var results: [String: [String: RefResult]]?
    var attempts: [String: [String: RefAttempt]]?
}

/// A settled lookup attempt, separate from a bibliographic result: failure never means "no record".
struct RefAttempt: Codable, Equatable {
    var status: String
    var at: String

    init(_ status: String, at: String = ISO8601DateFormatter().string(from: Date())) {
        self.status = status
        self.at = at
    }

    var json: [String: String] { ["status": status, "at": at] }
}

enum RefSource: String, CaseIterable {
    case semanticScholar = "semantic_scholar"
    case googleScholar = "google_scholar"

    var name: String { self == .semanticScholar ? "Semantic Scholar" : "Google Scholar" }
}

/// Titles compared as the engine compares them: case, TeX, accents and punctuation folded.
enum RefText {
    static func fold(_ s: String) -> String {
        let plain = s.replacingOccurrences(of: #"\\[a-zA-Z]+"#, with: " ", options: .regularExpression)
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
        return plain.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }.joined()
            .split(separator: " ").joined(separator: " ")
    }

    /// The share of words two titles have in common (0…1).
    static func likeness(_ a: String, _ b: String) -> Double {
        let x = Set(fold(a).split(separator: " ")), y = Set(fold(b).split(separator: " "))
        guard !x.isEmpty || !y.isEmpty else { return 0 }
        return Double(x.intersection(y).count) / Double(x.union(y).count)
    }

    /// The same work by its title: equal once folded, or nearly (a subtitle, a word changed).
    static func same(_ a: String, _ b: String) -> Bool { fold(a) == fold(b) || likeness(a, b) >= 0.8 }
}

/// What a citation's preview shows of the look-ups (UX.md §37 "Look-ups"): per source on, its count, nothing found, or
/// not yet; the published venue of a cited preprint; no record anywhere, with the closest match.
struct RefShown: Equatable {
    enum Count: Equatable {
        case pending
        case none
        case cited(Int?, URL?)
    }

    var counts: [(source: RefSource, count: Count)]
    var published: (venue: String, url: URL?)?
    var noRecord = false
    var closest: String?

    static func == (a: RefShown, b: RefShown) -> Bool {
        a.counts.map(\.source) == b.counts.map(\.source) && a.counts.map(\.count) == b.counts.map(\.count)
            && a.published?.venue == b.published?.venue && a.published?.url == b.published?.url
            && a.noRecord == b.noRecord && a.closest == b.closest
    }

    /// From an entry and its results by source; `on`: the sources whose setting is on.
    init(entry: RefEntry, results: [RefSource: RefResult], on: [RefSource]) {
        counts = on.map { s in
            guard let r = results[s] else { return (s, .pending) }
            return (s, r.found ? .cited(r.citations, r.url.flatMap(URL.init(string:))) : .none)
        }
        if entry.preprint, let r = results[.semanticScholar], r.found, let v = r.published, !v.isEmpty {
            published = (v, r.doi.flatMap { URL(string: "https://doi.org/" + $0) } ?? r.url.flatMap(URL.init(string:)))
        }
        let looked = on.filter { results[$0] != nil }
        noRecord = !looked.isEmpty && looked.count == on.count && looked.allSatisfy { results[$0]?.found == false }
        if noRecord, let c = looked.compactMap({ results[$0]?.closest }).first, let t = c.title {
            closest = ([t] + [c.year.map(String.init), c.authors?.first].compactMap { $0 }).joined(separator: " · ")
        }
    }
}

/// The look-ups' queues, cache and progress (one for the app): `RefLookup.shared` in the app; a test makes its own
/// with no fetchers.
@MainActor
final class RefLookup: ObservableObject {
    /// One entry to look up for a paper's round, by a source.
    struct Job: Equatable {
        var paper: String
        var round: Int
        var entry: RefEntry
        var source: RefSource
    }

    /// How a source answers (the network in the app; a stand-in in tests): nil when it could not be reached.
    typealias Fetch = (RefEntry) async -> RefResult?

    /// Seconds between two requests: Semantic Scholar's keyless pool is shared, so a few seconds; Google Scholar at most
    /// once a minute, a search the advisor could have made.
    static let pace: [RefSource: Double] = [.semanticScholar: 3, .googleScholar: 60]
    /// Google Scholar's searches a day, at most (the clicked previews' included).
    static let scholarDay = 60
    /// A result older than this is asked again: counts move slowly; a preprint not yet published more often.
    static let fresh: TimeInterval = 30 * 86400
    /// How long a source rests when it keeps refusing ("too many requests"), its entry kept in the queue.
    static let rest: TimeInterval = 120
    static let freshPreprint: TimeInterval = 7 * 86400

    @Published private(set) var queued: [RefSource: [Job]] = [:]
    /// Per paper|round and source: how many were asked and how many are done (the Checks tab's line).
    @Published private(set) var progress: [String: [RefSource: (done: Int, of: Int)]] = [:]
    /// Google Scholar asked for a CAPTCHA: no request until the advisor answers it in its window.
    @Published private(set) var blocked = false
    /// A source resting after it kept refusing, until when.
    @Published private(set) var resting: [RefSource: Date] = [:]
    @Published private(set) var attempts: [String: [RefSource: [String: RefAttempt]]] = [:]
    /// The results by lookup key and source (the app's cache, kept across papers and rounds).
    private(set) var cache: [String: [String: RefResult]] = [:]
    private let cacheURL: URL?
    private var fetchers: [RefSource: Fetch]
    private var running: Set<RefSource> = []
    private var last: [RefSource: Date] = [:]
    /// Results not yet given to the engine, by paper|round and source.
    private var unsent: [String: [RefSource: [String: RefResult]]] = [:]
    private var unsentAttempts: [String: [RefSource: [String: RefAttempt]]] = [:]
    /// The round’s results and settled attempts to persist in the engine together.
    var store: ((String, Int, RefSource, [String: RefResult], [String: RefAttempt]) -> Void)?
    /// A paper|round’s look-ups all ended (also observed by queue tests).
    var finished: ((String, Int) -> Void)?
    /// A result came for an entry (paper, round, key, source): the shown round's results and an open preview of it
    /// show it at once (the engine gets it with its source's batch).
    var arrived: ((String, Int, String, RefSource, RefResult) -> Void)?

    init(cacheURL: URL?, fetchers: [RefSource: Fetch]) {
        self.cacheURL = cacheURL
        self.fetchers = fetchers
        if let u = cacheURL, let d = try? Data(contentsOf: u) {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            cache = (try? dec.decode([String: [String: RefResult]].self, from: d)) ?? [:]
        }
    }

    /// The app's: its cache in the app's caches folder (none in a test run), the two sources on the network.
    static let shared: RefLookup = {
        let url: URL? = LaunchOptions.isTestRun ? nil
            : AppVariant.current.cachesFolder.appendingPathComponent("references.json")
        return RefLookup(cacheURL: url, fetchers: [.semanticScholar: SemanticScholar.fetch, .googleScholar: GoogleScholar.shared.fetch])
    }()

    static func roundKey(_ paper: String, _ round: Int) -> String { paper + "|" + String(round) }

    /// A cached result still fresh enough for this entry.
    func cached(_ e: RefEntry, _ s: RefSource, now: Date = Date()) -> RefResult? {
        guard let k = e.lookupKey, let r = cache[k]?[s.rawValue] else { return nil }
        let age = now.timeIntervalSince(r.at ?? .distantPast)
        let preprintOpen = e.preprint && s == .semanticScholar && r.published == nil
        return age < (preprintOpen ? Self.freshPreprint : Self.fresh) ? r : nil
    }

    /// A round's entries to look up by the sources on: those the engine has a result for are left; a fresh cached
    /// result is given to the engine at once; the others are queued (after what is queued already). Google Scholar
    /// only searches titles.
    func start(paper: String, round: Int, entries: [RefEntry], stored: [String: [String: RefResult]], sources: [RefSource],
               recorded: [String: [String: RefAttempt]] = [:]) {
        let rk = Self.roundKey(paper, round)
        for (source, records) in recorded {
            guard let s = RefSource(rawValue: source) else { continue }
            for (key, attempt) in records where attempts[rk]?[s]?[key] == nil {
                attempts[rk, default: [:]][s, default: [:]][key] = attempt
            }
        }
        for s in sources {
            on.insert(s)
            for e in entries {
                let titled = (e.title ?? "").count > 3
                guard titled || (s == .semanticScholar && (e.arxiv != nil || e.doi != nil)) else {
                    record(paper, round, s, e.key, "skipped")
                    continue
                }
                if stored[s.rawValue]?[e.key] != nil { continue }
                if queued[s, default: []].contains(where: { $0.paper == paper && $0.round == round && $0.entry.key == e.key }) { continue }
                if let r = cached(e, s) {
                    unsent[rk, default: [:]][s, default: [:]][e.key] = r
                    record(paper, round, s, e.key, r.found ? "matched" : "not_found",
                           at: r.at.map { ISO8601DateFormatter().string(from: $0) })
                    arrived?(paper, round, e.key, s, r)
                    count(rk, s, done: 1, of: 1)
                    continue
                }
                queued[s, default: []].append(Job(paper: paper, round: round, entry: e, source: s))
                count(rk, s, done: 0, of: 1)
            }
        }
        flush(rk, paper: paper, round: round)
        for s in sources { run(s) }
        checkFinished(rk, paper: paper, round: round)
    }

    /// A citation's preview opened: its entry goes first in Google Scholar's queue (the others keep their order).
    func prefer(paper: String, round: Int, key: String) {
        guard var q = queued[.googleScholar], let i = q.firstIndex(where: { $0.paper == paper && $0.round == round && $0.entry.key == key }),
              i > 0 else { return }
        let j = q.remove(at: i)
        q.insert(j, at: 0)
        queued[.googleScholar] = q
    }

    /// A source turned off (or Checks): its queue is dropped and nothing more is sent; what it found so far still goes
    /// to the engine; its rounds end without the toast.
    func stop(_ s: RefSource, reason: String = "stopped") {
        on.remove(s)
        let jobs = queued[s] ?? []
        queued[s] = []
        if s == .googleScholar && blocked {
            blocked = false
            GoogleScholar.shared.dismissCaptcha()
        }
        var rounds: [(String, String, Int)] = []
        for j in jobs {
            record(j.paper, j.round, s, j.entry.key, reason)
            let rk = Self.roundKey(j.paper, j.round)
            count(rk, s, done: 1, of: 0)
            if !rounds.contains(where: { $0.0 == rk }) { rounds.append((rk, j.paper, j.round)) }
        }
        for (rk, paper, round) in rounds {
            flush(rk, paper: paper, round: round)
            checkFinished(rk, paper: paper, round: round, quiet: true)
        }
    }

    /// The Checks tab's line for a paper's round: "Looking up references · Semantic Scholar 12 of 34 · Google Scholar
    /// 3 of 34, about 31 min"; nil when nothing is left.
    func line(paper: String, round: Int) -> String? {
        guard let p = progress[Self.roundKey(paper, round)] else { return nil }
        var parts: [String] = []
        for s in RefSource.allCases {
            guard let c = p[s], c.done < c.of else { continue }
            var t = "\(s.name) \(c.done) of \(c.of)"
            if s == .googleScholar {
                let left = queued[.googleScholar]?.count ?? 0
                t += blocked ? ", waiting for you to answer its check" : left > 1 ? ", about \(left) min" : ""
            } else if resting[s] != nil {
                t += ", waiting for its limit"
            }
            parts.append(t)
        }
        return parts.isEmpty ? nil : "Looking up references · " + parts.joined(separator: " · ")
    }

    // MARK: Running

    /// The sources on (`start` turns one on, `stop` off): a request that comes back for a source turned off meanwhile
    /// is dropped.
    private var on: Set<RefSource> = []
    /// Per paper|round, how many results the sources gave (none: no toast).
    private var got: [String: Int] = [:]

    private func count(_ rk: String, _ s: RefSource, done: Int, of: Int) {
        var p = progress[rk, default: [:]][s] ?? (0, 0)
        p.done += done
        p.of += of
        progress[rk, default: [:]][s] = p
    }

    /// Takes a job out of its queue by itself (a preview may have moved another first meanwhile); false when it is
    /// gone (its source turned off).
    private func take(_ job: Job) -> Bool {
        guard let i = queued[job.source]?.firstIndex(of: job) else { return false }
        queued[job.source]?.remove(at: i)
        return true
    }

    private func run(_ s: RefSource) {
        guard !running.contains(s), let fetch = fetchers[s], !(queued[s] ?? []).isEmpty else { return }
        if s == .googleScholar && blocked { return }
        running.insert(s)
        Task { @MainActor in
            while let job = queued[s]?.first {
                if s == .googleScholar && blocked { break }
                if s == .googleScholar && !GoogleScholar.underCap() {
                    capped = true  // the day's searches are spent: the rest waits for the round to be opened another day
                    stop(.googleScholar, reason: "limited")
                    break
                }
                let wait = (Self.pace[s] ?? 3) - Date().timeIntervalSince(last[s] ?? .distantPast)
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
                guard queued[s]?.first == job else { continue }  // preferred or dropped meanwhile
                var r = cached(job.entry, s)  // found meanwhile for another round or paper
                if r == nil {
                    last[s] = Date()
                    if s == .googleScholar { GoogleScholar.counted() }
                    r = await fetch(job.entry)
                }
                guard on.contains(s), queued[s]?.contains(job) == true else { continue }  // turned off meanwhile
                if r == nil && s == .semanticScholar && SemanticScholar.limited {
                    // its pool keeps refusing: the entry stays first, the queue rests and asks again
                    resting[s] = Date().addingTimeInterval(Self.rest)
                    try? await Task.sleep(nanoseconds: UInt64(Self.rest * 1e9))
                    resting[s] = nil
                    continue
                }
                if s == .googleScholar && GoogleScholar.shared.captcha {
                    blocked = true
                    break
                }
                guard take(job) else { continue }
                let rk = Self.roundKey(job.paper, job.round)
                count(rk, s, done: 1, of: 0)
                record(job.paper, job.round, s, job.entry.key,
                       r.map { $0.found ? "matched" : "not_found" } ?? "unavailable")
                if r != nil {
                    if r?.at == nil { r?.at = Date() }
                    if let k = job.entry.lookupKey, let r { cache[k, default: [:]][s.rawValue] = r }
                    unsent[rk, default: [:]][s, default: [:]][job.entry.key] = r
                    got[rk, default: 0] += 1
                    saveCache()
                    if let r { arrived?(job.paper, job.round, job.entry.key, s, r) }
                }
                // the engine gets a source's results when its queue for the round ends: one build of the checks
                if !(queued[s]?.contains { $0.paper == job.paper && $0.round == job.round } ?? false) {
                    flush(rk, paper: job.paper, round: job.round)
                }
                checkFinished(rk, paper: job.paper, round: job.round)
            }
            running.remove(s)
        }
    }

    /// Google Scholar's day was spent: its rows say so until another day.
    @Published private(set) var capped = false

    private func unblock() {
        blocked = false
        run(.googleScholar)
    }

    /// Verification is opened by the reader from the activity panel, never over their reading automatically.
    func verify() {
        guard blocked else { return }
        GoogleScholar.shared.showCaptcha(then: { [weak self] in self?.unblock() },
                                         closed: { [weak self] in self?.stop(.googleScholar) })
    }

    private func record(_ paper: String, _ round: Int, _ source: RefSource, _ key: String, _ status: String, at: String? = nil) {
        let rk = Self.roundKey(paper, round)
        let value = RefAttempt(status, at: at ?? ISO8601DateFormatter().string(from: Date()))
        attempts[rk, default: [:]][source, default: [:]][key] = value
        unsentAttempts[rk, default: [:]][source, default: [:]][key] = value
    }

    /// Gives the engine what is not given yet for a paper's round.
    private func flush(_ rk: String, paper: String, round: Int) {
        let by = unsent[rk] ?? [:]
        let records = unsentAttempts[rk] ?? [:]
        unsent[rk] = nil
        unsentAttempts[rk] = nil
        for s in RefSource.allCases where !(by[s] ?? [:]).isEmpty || !(records[s] ?? [:]).isEmpty {
            store?(paper, round, s, by[s] ?? [:], records[s] ?? [:])
        }
    }

    /// A round’s look-ups all ended: notify the observer when results arrived and the queue was not stopped.
    private func checkFinished(_ rk: String, paper: String, round: Int, quiet: Bool = false) {
        guard let p = progress[rk], p.values.allSatisfy({ $0.done >= $0.of }) else { return }
        progress[rk] = nil
        let found = got.removeValue(forKey: rk) ?? 0
        if !quiet && found > 0 { finished?(paper, round) }
    }

    private func saveCache() {
        guard let u = cacheURL else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let d = try? enc.encode(cache) else { return }
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: u, options: .atomic)
    }

    // MARK: Tests

    /// A result as if a source had answered (tests): cached, and given to the engine's hook.
    func deliver(_ job: Job, _ r: RefResult) {
        var r = r
        if r.at == nil { r.at = Date() }
        let rk = Self.roundKey(job.paper, job.round)
        if let k = job.entry.lookupKey { cache[k, default: [:]][job.source.rawValue] = r }
        unsent[rk, default: [:]][job.source, default: [:]][job.entry.key] = r
        record(job.paper, job.round, job.source, job.entry.key, r.found ? "matched" : "not_found")
        queued[job.source]?.removeAll { $0 == job }
        count(rk, job.source, done: 1, of: 0)
        got[rk, default: 0] += 1
        flush(rk, paper: job.paper, round: job.round)
        arrived?(job.paper, job.round, job.entry.key, job.source, r)
        checkFinished(rk, paper: job.paper, round: job.round)
    }
}

// MARK: Semantic Scholar

/// Semantic Scholar's public API (keyless): a cited work by its arXiv id or DOI, else by its title (`search/match`);
/// a preprint whose record has no venue is searched once more by title, for a published record of its own.
enum SemanticScholar {
    static let fields = "title,year,venue,publicationVenue,authors,citationCount,externalIds,url"

    static func fetch(_ e: RefEntry) async -> RefResult? {
        var r: RefResult?
        if let a = e.arxiv, !a.isEmpty { r = await paper("arXiv:" + a) }
        if r == nil || r?.found == false, let d = e.doi, !d.isEmpty { r = await paper("DOI:" + d) }
        if r == nil || r?.found == false || (e.preprint && r?.published == nil), let t = e.title, !t.isEmpty {
            if let m = await match(t) {
                // the work found by its title alone (or its closest match), or a published record of its own
                if r?.found != true || (m.found && m.published != nil && m.record != r?.record) { r = m }
            } else if r == nil {
                return nil
            }
        }
        return r
    }

    private static func paper(_ id: String) async -> RefResult? {
        let path = "https://api.semanticscholar.org/graph/v1/paper/" + (id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)
        guard let url = URL(string: path + "?fields=" + fields) else { return nil }
        switch await get(url) {
        case .some(.found(let j)): return result(j)
        case .some(.missing): return RefResult(found: false)
        case .none: return nil
        }
    }

    private static func match(_ title: String) async -> RefResult? {
        var c = URLComponents(string: "https://api.semanticscholar.org/graph/v1/paper/search/match")!
        c.queryItems = [URLQueryItem(name: "query", value: title), URLQueryItem(name: "fields", value: fields)]
        guard let url = c.url else { return nil }
        switch await get(url) {
        case .some(.found(let j)):
            guard let first = (j["data"] as? [[String: Any]])?.first else { return RefResult(found: false) }
            var r = result(first)
            if !RefText.same(r.title ?? "", title) {  // the best match is another work: no record, this the closest
                r = RefResult(found: false, closest: .init(title: r.title, year: r.year, authors: r.authors))
            }
            return r
        case .some(.missing): return RefResult(found: false)
        case .none: return nil
        }
    }

    /// A paper's JSON as a result: its venue's short name when it is not a preprint's (no year: Semantic Scholar's is
    /// often the arXiv version's, "ICLR 2014" for a paper of ICLR 2015).
    static func result(_ j: [String: Any]) -> RefResult {
        let ids = j["externalIds"] as? [String: Any] ?? [:]
        let pv = j["publicationVenue"] as? [String: Any]
        let venue = (pv?["name"] as? String) ?? (j["venue"] as? String)
        let alt = (pv?["alternate_names"] as? [String] ?? []).filter { $0.count <= 8 && $0 == $0.uppercased() && $0.contains(where: \.isLetter) }
        let year = j["year"] as? Int
        let preprint = (venue ?? "").isEmpty || ["arxiv", "corr", "biorxiv", "medrxiv", "chemrxiv", "openreview"]
            .contains { (venue ?? "").lowercased().contains($0) }
        let short = alt.min { $0.count < $1.count } ?? venue
        return RefResult(found: true, title: j["title"] as? String, year: year, venue: venue,
                         authors: (j["authors"] as? [[String: Any]])?.compactMap { $0["name"] as? String },
                         citations: j["citationCount"] as? Int, url: j["url"] as? String, doi: ids["DOI"] as? String,
                         arxiv: ids["ArXiv"] as? String, record: j["paperId"] as? String,
                         published: preprint ? nil : short)
    }

    enum Answer { case found([String: Any]), missing }

    /// Its keyless pool refused five times running: the queue rests (`RefLookup.rest`) and asks again.
    nonisolated(unsafe) static var limited = false

    /// One GET, waiting as the service asks after "too many requests" (Retry-After, else 4 s doubling, five tries):
    /// nil when it cannot be reached, with `limited` set when it kept refusing.
    private static func get(_ url: URL) async -> Answer? {
        var delay: Double = 4
        limited = false
        for _ in 0..<5 {
            var req = URLRequest(url: url, timeoutInterval: 20)
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            guard let (data, resp) = try? await URLSession.shared.data(for: req), let http = resp as? HTTPURLResponse else { return nil }
            switch http.statusCode {
            case 200: return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).map { .found($0) } ?? nil
            case 404: return .missing
            case 429, 500...599:
                let after = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init) ?? delay
                try? await Task.sleep(nanoseconds: UInt64(min(after, 60) * 1e9))
                delay = min(delay * 2, 60)
            default: return nil
            }
        }
        limited = true
        return nil
    }
}

// MARK: Google Scholar

/// Google Scholar's results page in a WebKit view of the app's own (its own cookies; a test run's kept in memory;
/// nothing disguised): the first result's title and "Cited by" count. A page that does not load, or is not a results
/// page, gives no result ("—", never "No record"). A CAPTCHA pauses requests; Verify in the check log opens its
/// window for the advisor to answer; once a results page loads there, the look-ups go on; closing it drops the queue.
@MainActor
final class GoogleScholar: NSObject, WKNavigationDelegate, NSWindowDelegate {
    static let shared = GoogleScholar()

    private var web: WKWebView?
    /// The page being loaded: resumed once, with whether it loaded.
    private var loaded: CheckedContinuation<Bool, Never>?
    private var window: NSWindow?
    private var answered: (() -> Void)?
    private var closed: (() -> Void)?
    /// The last page asked for a CAPTCHA.
    private(set) var captcha = false

    static let dayKey = "scholarDay"
    nonisolated(unsafe) private static var memoryDay: (day: String, n: Int) = ("", 0)

    private static var today: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    /// Under the day's cap of searches (kept in the app's defaults; a test run's in memory).
    static func underCap() -> Bool {
        let (day, n) = stored()
        return day != today || n < RefLookup.scholarDay
    }

    static func counted() {
        let (day, n) = stored()
        let next = (today, day == today ? n + 1 : 1)
        if LaunchOptions.isTestRun { memoryDay = next } else { UserDefaults.standard.set([next.0, String(next.1)], forKey: dayKey) }
    }

    private static func stored() -> (String, Int) {
        if LaunchOptions.isTestRun { return memoryDay }
        let a = UserDefaults.standard.stringArray(forKey: dayKey) ?? []
        return a.count == 2 ? (a[0], Int(a[1]) ?? 0) : ("", 0)
    }

    static func searchURL(_ e: RefEntry) -> URL? {
        var c = URLComponents(string: "https://scholar.google.com/scholar")!
        c.queryItems = [URLQueryItem(name: "hl", value: "en"), URLQueryItem(name: "q", value: "\"" + (e.title ?? "") + "\"")]
        return c.url
    }

    static let read = """
    (() => {
      const text = document.body ? document.body.innerText : '';
      if (document.querySelector('#gs_captcha_ccl, #captcha-form, form#captcha, #recaptcha') ||
          /unusual traffic|not a robot/i.test(text)) return {captcha: true};
      if (!document.querySelector('#gs_res_ccl')) return {page: false};
      const r = document.querySelector('#gs_res_ccl_mid .gs_r .gs_ri');
      if (!r) return {found: false};
      const t = r.querySelector('.gs_rt');
      const title = t ? t.innerText.replace(/^\\[[^\\]]+\\]\\s*/, '') : '';
      const cited = Array.from(r.querySelectorAll('.gs_fl a')).map(a => a.innerText).find(s => /^Cited by \\d+/.test(s));
      const meta = r.querySelector('.gs_a') ? r.querySelector('.gs_a').innerText : '';
      return {title: title, cited: cited ? parseInt(cited.replace(/\\D/g, '')) : 0, meta: meta};
    })()
    """

    func fetch(_ e: RefEntry) async -> RefResult? {
        guard (e.title ?? "").count > 3, let url = Self.searchURL(e) else { return nil }
        let w = web ?? makeWeb()
        captcha = false
        let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            loaded = c
            w.load(URLRequest(url: url, timeoutInterval: 30))
            // a page that never finishes (a stalled subresource, a dead web process) ends here
            DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in MainActor.assumeIsolated { self?.finished(false) } }
        }
        guard ok, let got = try? await w.evaluateJavaScript(Self.read) as? [String: Any] else { return nil }
        if got["captcha"] as? Bool == true {
            captcha = true
            return nil
        }
        if got["page"] as? Bool == false { return nil }  // a consent page or another: not a results page
        guard let title = got["title"] as? String, !title.isEmpty, RefText.same(title, e.title ?? "") else {
            let t = got["title"] as? String
            return RefResult(found: false, url: url.absoluteString,
                             closest: (t ?? "").isEmpty ? nil : .init(title: t, year: Self.year(got["meta"] as? String), authors: nil))
        }
        return RefResult(found: true, title: title, year: Self.year(got["meta"] as? String),
                         citations: got["cited"] as? Int, url: url.absoluteString)
    }

    private static func year(_ meta: String?) -> Int? {
        guard let m = meta, let r = m.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression) else { return nil }
        return Int(m[r])
    }

    private func makeWeb() -> WKWebView {
        let config = WKWebViewConfiguration()
        if LaunchOptions.isTestRun { config.websiteDataStore = .nonPersistent() }  // a test run leaves no cookies
        let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: config)
        w.navigationDelegate = self
        web = w
        return w
    }

    /// The CAPTCHA's page in a small window, put in front without taking the keyboard (never in a test run): `then`
    /// once a page without one loads there, `closed` when the advisor closes it instead.
    func showCaptcha(then: @escaping () -> Void, closed: @escaping () -> Void) {
        answered = then
        self.closed = closed
        guard !LaunchOptions.background, let w = web else { return }
        let win = window ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                                     styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        win.title = "Google Scholar · answer its check to go on"
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.contentView = w
        win.center()
        win.orderFront(nil)
        window = win
    }

    /// The look-ups stopped while the window shows: it goes, nothing is called.
    func dismissCaptcha() {
        answered = nil
        closed = nil
        window?.orderOut(nil)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            answered = nil
            let c = closed
            closed = nil
            c?()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { finished(true) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finished(false) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finished(false) }
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated { finished(false) }
    }

    private func finished(_ ok: Bool) {
        if let c = loaded {
            loaded = nil
            c.resume(returning: ok)
            return
        }
        // a page loaded in the CAPTCHA's window: once it is a results page, the look-ups go on
        guard ok, let then = answered, let w = web else { return }
        Task { @MainActor in
            let got = try? await w.evaluateJavaScript(Self.read) as? [String: Any]
            guard got?["captcha"] as? Bool != true, got?["page"] as? Bool != false else { return }
            captcha = false
            answered = nil
            closed = nil
            window?.orderOut(nil)
            then()
        }
    }
}
