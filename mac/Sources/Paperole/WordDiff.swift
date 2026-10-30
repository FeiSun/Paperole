import Foundation

/// Word-level diff of two texts for the comment cards: longest common subsequence on words, with punctuation and
/// symbols at a word's edges split off first, so `policy.` and `$x$.` are several tokens (UX.md §3).
enum DiffPart: Equatable {
    case same(String)
    case deleted(String)
    case inserted(String)
}

enum WordDiff {
    struct Token: Equatable {
        let text: String
        let range: Range<Int>  // Unicode scalar offsets in the text
    }

    /// What a scalar is to the tokenizer: a space between words, punctuation or a symbol split off a word's edge, or
    /// a letter of a word.
    private enum Class: UInt8 { case space, edge, word }

    private static let spaces = CharacterSet.whitespacesAndNewlines
    private static let edges = CharacterSet.punctuationCharacters.union(.symbols)
    /// The ASCII scalars' classes, from the same sets: most of a paper's text never asks a CharacterSet.
    private static let ascii: [Class] = (0..<128).map { v in
        let u = Unicode.Scalar(UInt8(v))
        return spaces.contains(u) ? .space : edges.contains(u) ? .edge : .word
    }

    private static func classify(_ u: Unicode.Scalar) -> Class {
        if u.value < 128 { return ascii[Int(u.value)] }
        return spaces.contains(u) ? .space : edges.contains(u) ? .edge : .word
    }

    /// Every card and change diffs its texts again on each reply (UX.md §10.3), so each scalar is classed once.
    static func tokens(_ s: String) -> [Token] {
        let scalars = Array(s.unicodeScalars)
        let kinds = scalars.map(classify)
        var out: [Token] = []
        func add(_ a: Int, _ b: Int) {
            out.append(Token(text: String(String.UnicodeScalarView(scalars[a..<b])), range: a..<b))
        }
        var i = 0
        while i < scalars.count {
            if kinds[i] == .space { i += 1; continue }
            var j = i
            while j < scalars.count && kinds[j] != .space { j += 1 }
            var a = i, b = j
            var head: [Int] = [], tail: [Int] = []
            while a < b && kinds[a] == .edge { head.append(a); a += 1 }
            while b > a && kinds[b - 1] == .edge { b -= 1; tail.insert(b, at: 0) }
            head.forEach { add($0, $0 + 1) }
            if a < b { add(a, b) }
            tail.forEach { add($0, $0 + 1) }
            i = j
        }
        return out
    }

    /// The LCS alignment of two token lists: for each step, (old index or nil, new index or nil).
    static func align(_ a: [Token], _ b: [Token]) -> [(Int?, Int?)] {
        let n = a.count, m = b.count
        if n * m > 250_000 { return (0..<n).map { ($0, nil) } + (0..<m).map { (nil, $0) } }
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = a[i].text == b[j].text ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var out: [(Int?, Int?)] = []
        var i = 0, j = 0
        while i < n && j < m {
            if a[i].text == b[j].text {
                out.append((i, j)); i += 1; j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                out.append((i, nil)); i += 1
            } else {
                out.append((nil, j)); j += 1
            }
        }
        out += (i..<n).map { ($0, nil) }
        out += (j..<m).map { (nil, $0) }
        return out
    }

    /// Where `new` differs from `old`, in `new`'s scalar offsets: runs of inserted words (to underline, one range per
    /// run) and the points where words were only deleted (to mark with a caret, after the word before them).
    /// `oldFocus` and `newFocus` (a thread's sections, UX.md §3: each side's marked words) keep out the words that only
    /// one side shows before the first word they share or after the last one, unless they are marked on their side:
    /// the sentences shown around a mark vary from round to round. A side without focus (nil) counts whole.
    static func changes(from old: String, to new: String, oldFocus: [Range<Int>]? = nil,
                        newFocus: [Range<Int>]? = nil) -> (changed: [Range<Int>], carets: [Int]) {
        let a = tokens(old), b = tokens(new)
        let steps = align(a, b)
        let first = steps.firstIndex { $0.0 != nil && $0.1 != nil } ?? steps.count
        let last = steps.lastIndex { $0.0 != nil && $0.1 != nil } ?? -1
        func counts(_ k: Int, _ r: Range<Int>, _ focus: [Range<Int>]?) -> Bool {
            k > first && k < last || (focus.map { $0.contains { $0.overlaps(r) } } ?? true)
        }
        var changed: [Range<Int>] = [], carets: [Int] = []
        var lastNew: Int?  // end of the last new token passed
        var run: Range<Int>?, deletedRun = false, insertedRun = false
        func close() {
            if let r = run { changed.append(r) }
            if deletedRun && !insertedRun { carets.append(lastNew ?? 0) }
            run = nil; deletedRun = false; insertedRun = false
        }
        for (k, step) in steps.enumerated() {
            switch step {
            case (_?, let j?):
                close()
                lastNew = b[j].range.upperBound
            case (let i?, nil):
                if counts(k, a[i].range, oldFocus) { deletedRun = true }
            case (nil, let j?):
                if counts(k, b[j].range, newFocus) {
                    insertedRun = true
                    run = run.map { $0.lowerBound..<b[j].range.upperBound } ?? b[j].range
                } else {
                    close()
                }
                lastNew = b[j].range.upperBound
            default: break
            }
        }
        close()
        return (changed, carets)
    }

    /// Ranges of `old` carried over to `new` through the alignment of their tokens: the runs of `new`'s tokens that
    /// are aligned with tokens inside `ranges` (a change's own words, found in a card's text).
    static func carried(_ ranges: [Range<Int>], from old: String, to new: String) -> [Range<Int>] {
        let a = tokens(old), b = tokens(new)
        var out: [Range<Int>] = [], run: Range<Int>?
        for step in align(a, b) {
            if case let (i?, j?) = step, ranges.contains(where: { $0.overlaps(a[i].range) }) {
                run = run.map { $0.lowerBound..<b[j].range.upperBound } ?? b[j].range
            } else if let r = run {
                out.append(r)
                run = nil
            }
        }
        if let r = run { out.append(r) }
        return out
    }

    /// A run of tokens that differ between two texts: its steps of the alignment, and its scalar range on each side.
    /// A side with no token of the run has an empty range at the point after the token before it.
    struct Hunk: Equatable {
        var steps: Range<Int>
        var old: Range<Int>
        var new: Range<Int>
    }

    /// The alignment of two texts' tokens and the runs where they differ.
    static func hunks(_ old: String, _ new: String) -> (a: [Token], b: [Token], steps: [(Int?, Int?)], hunks: [Hunk]) {
        let a = tokens(old), b = tokens(new)
        let steps = align(a, b)
        var out: [Hunk] = []
        var lastOld = 0, lastNew = 0  // ends of the last tokens passed
        var start: Int?, o: Range<Int>?, n: Range<Int>?
        func close(_ end: Int) {
            if let s = start {
                out.append(Hunk(steps: s..<end, old: o ?? lastOld..<lastOld, new: n ?? lastNew..<lastNew))
            }
            start = nil; o = nil; n = nil
        }
        for (k, step) in steps.enumerated() {
            switch step {
            case let (i?, j?):
                close(k)
                lastOld = a[i].range.upperBound
                lastNew = b[j].range.upperBound
            case let (i?, nil):
                if start == nil { start = k }
                o = (o?.lowerBound ?? a[i].range.lowerBound)..<a[i].range.upperBound
            case let (nil, j?):
                if start == nil { start = k }
                n = (n?.lowerBound ?? b[j].range.lowerBound)..<b[j].range.upperBound
            default: break
            }
        }
        close(steps.count)
        return (a, b, steps, out)
    }
}
