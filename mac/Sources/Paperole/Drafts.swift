import CryptoKit
import Foundation

/// Unsent follow-up drafts (UX.md §8): text written in a card's follow-up field and not sent with ⌘↩. They live on
/// this Mac only, never in the ledger or the student's folder: one small JSON file per paper in
/// Application Support/Paperole/drafts (Paperole Dev's own folder in the dev app; AppVariant), by round and
/// comment id, written at every change so a crash or a forced quit loses nothing. A draft is deleted when it is sent or
/// discarded. Test runs use another folder (`--drafts`, or a temporary one with `--background`).
struct DraftStore {
    let directory: URL

    static var standard: URL { AppVariant.current.dataFolder.appendingPathComponent("drafts") }

    private struct File: Codable {
        var paper: String
        var rounds: [String: [String: String]]  // round → comment id → text
    }

    /// The paper's file: its folder path hashed, so any path makes a valid file name.
    func url(paper: String) -> URL {
        let hash = SHA256.hash(data: Data(paper.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash + ".json")
    }

    private func read(_ url: URL) -> File? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(File.self, from: data)
    }

    /// Round `round`'s drafts of the paper: comment id → text.
    func load(paper: String, round: Int) -> [String: String] { file(paper).rounds[String(round)] ?? [:] }

    /// Replaces round `round`'s drafts; empty texts are dropped, and a paper left without drafts has no file.
    func save(paper: String, round: Int, drafts: [String: String]) {
        var f = file(paper)
        let kept = drafts.filter { !$0.value.isEmpty }
        f.rounds[String(round)] = kept.isEmpty ? nil : kept
        write(f)
    }

    /// Drops the drafts of the paper's other rounds: once round `round` is open, an earlier round's drafts can no
    /// longer be sent (a round finished from the command line leaves them behind).
    func keepOnly(paper: String, round: Int) {
        var f = file(paper)
        guard f.rounds.keys.contains(where: { $0 != String(round) }) else { return }
        f.rounds = f.rounds.filter { $0.key == String(round) }
        write(f)
    }

    private func file(_ paper: String) -> File {
        read(url(paper: paper)).flatMap { $0.paper == paper ? $0 : nil } ?? File(paper: paper, rounds: [:])
    }

    private func write(_ f: File) {
        let u = url(paper: f.paper)
        do {
            if f.rounds.isEmpty {
                if FileManager.default.fileExists(atPath: u.path) { try FileManager.default.removeItem(at: u) }
                return
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try enc.encode(f).write(to: u, options: .atomic)
        } catch {
            NSLog("Paperole: could not save the drafts of %@: %@", f.paper, error.localizedDescription)
        }
    }

    /// The paper's drafts file as JSON (`{"paper", "rounds"}`), for an export; nil without drafts.
    func json(paper: String) -> Any? {
        guard read(url(paper: paper)).map({ $0.paper == paper }) == true, let data = try? Data(contentsOf: url(paper: paper)) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// Import (Transfer.swift): an imported paper's drafts file (an export's JSON), kept here under the paper's path
    /// now; a draft here is never replaced. The number kept.
    func merge(file data: Data, into paper: String) -> Int {
        guard let theirs = try? JSONDecoder().decode(File.self, from: data) else { return 0 }
        var f = file(paper), kept = 0
        for (r, ds) in theirs.rounds {
            for (id, text) in ds where !text.isEmpty && f.rounds[r]?[id]?.isEmpty != false {
                f.rounds[r, default: [:]][id] = text
                kept += 1
            }
        }
        if kept > 0 { write(f) }
        return kept
    }

    /// Import's Use This Copy of an older or other copy: the drafts typed against the replaced copy stay with it, under
    /// its new path, never over a draft there.
    func move(from paper: String, to other: String) {
        let mine = file(paper)
        guard !mine.rounds.isEmpty, let data = try? JSONEncoder().encode(mine) else { return }
        _ = merge(file: data, into: other)
        write(File(paper: paper, rounds: [:]))
    }

    /// Every unsent draft, for the question on quitting: (paper, round, comment id), sorted.
    func all() -> [(paper: String, round: Int, id: String)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var out: [(paper: String, round: Int, id: String)] = []
        for u in files where u.pathExtension == "json" {
            guard let f = read(u) else { continue }
            for (r, ds) in f.rounds {
                for (id, text) in ds where !text.isEmpty { out.append((f.paper, Int(r) ?? 0, id)) }
            }
        }
        return out.sorted { ($0.paper, $0.round, $0.id) < ($1.paper, $1.round, $1.id) }
    }
}
