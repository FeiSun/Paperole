import AppKit

/// The PDF's right-click menu's words and items (PDFController.menu; design/pdf-reader/PLAN.md §3).
@MainActor
enum PDFMenus {
    /// Text as one line: its runs of white space (line breaks too) one space each, trimmed.
    nonisolated static func collapsed(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    /// Words in an item's title: at most 24 characters, cut at a word with "…".
    nonisolated static func short(_ s: String, max n: Int = 24) -> String {
        guard s.count > n else { return s }
        let cut = s.prefix(n)
        let whole = s[s.index(s.startIndex, offsetBy: n)].isWhitespace  // the cut falls between two words
        let word = whole ? cut : cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return word.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)) + "…"
    }

    /// The one word of a selection, without the punctuation round it, for Look Up; nil for more than one word.
    nonisolated static func oneWord(_ s: String) -> String? {
        let w = s.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return w.isEmpty || w.contains(where: \.isWhitespace) ? nil : w
    }

    /// Replace With…'s note: the new words, "Replace with “were”." (decision 4); none, no note.
    nonisolated static func replaceNote(_ words: String) -> String {
        let w = collapsed(words)
        return w.isEmpty ? "" : "Replace with “\(w)”."
    }

    /// A row of Other Comments Here: its id and the start of its note.
    nonisolated static func otherTitle(_ c: Comment) -> String {
        let note = collapsed(c.note)
        return note.isEmpty ? c.id : c.id + " · " + short(note, max: 32)
    }

    /// The items of a menu built for the card (`CardMenus.more`) that can act, taken out of it, in its groups (between
    /// its separators): a greyed item, and a submenu with none that can act, are left out (the card's own menu keeps
    /// them greyed).
    static func actionable(_ m: NSMenu) -> [[NSMenuItem]] {
        var groups: [[NSMenuItem]] = [[]]
        for item in m.items {
            m.removeItem(item)
            if item.isSeparatorItem {
                groups.append([])
            } else if let sub = item.submenu {
                if sub.items.contains(where: { $0.isEnabled && $0.action != nil }) { groups[groups.count - 1].append(item) }
            } else if item.isEnabled && item.action != nil {
                groups[groups.count - 1].append(item)
            }
        }
        return groups.filter { !$0.isEmpty }
    }
}

/// The PDF's zoom (PLAN §3.6): Fit Width (nil) by default, refitted with the window; else a scale, 1 for Actual Size.
enum ZoomRules {
    /// Zoom In and Out step through these, and through Fit Width's scale where it falls between them.
    static let steps: [CGFloat] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4]
    /// The status line's menu, under Fit Width.
    static let menu: [CGFloat] = [1, 1.25, 1.5, 1.75, 2]
    /// Focus shows the page 1.3 times as large as Review (POLISH §4.3).
    static let focus: CGFloat = 1.3

    static func clamped(_ z: CGFloat) -> CGFloat { min(max(z, steps[0]), steps[steps.count - 1]) }

    /// Zoom In (`up`) or Out from the scale `now`, the page fitting the width at `fit`: the next step or Fit Width,
    /// whichever comes first; at either end, the end. nil: Fit Width.
    static func step(from now: CGFloat, fit: CGFloat, up: Bool) -> CGFloat? {
        let stops = (steps + [fit]).sorted()
        let next = up ? stops.first { $0 > now * 1.01 } : stops.last { $0 < now / 1.01 }
        let z = next ?? (up ? stops[stops.count - 1] : stops[0])
        return abs(z - fit) <= fit * 0.01 ? nil : z
    }

    /// "125%".
    static func label(_ z: CGFloat) -> String { "\(Int((z * 100).rounded()))%" }
}
