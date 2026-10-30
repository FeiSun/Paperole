import CoreGraphics
import Foundation

/// A comment's clickable areas on one page (PDFKit page space), for a click without a drag (UX.md §6).
struct MarkShape: Equatable {
    enum Group: Int, Comparable {
        case label = 0, text = 1, box = 2
        static func < (a: Group, b: Group) -> Bool { a.rawValue < b.rawValue }
    }

    var id: String
    var group: Group
    var areas: [CGRect]
    var order: Int  // the comment's place in the state (document order)

    /// A text mark: each line rect + 2 pt. A note at a point: 12×12. A deletion caret: 10×14. A box: + 3 pt.
    /// A label: + 2 pt.
    static func label(_ id: String, _ r: CGRect, order: Int) -> MarkShape {
        MarkShape(id: id, group: .label, areas: [r.insetBy(dx: -2, dy: -2)], order: order)
    }

    static func text(_ id: String, _ rects: [CGRect], order: Int) -> MarkShape {
        MarkShape(id: id, group: .text, areas: rects.map { $0.insetBy(dx: -2, dy: -2) }, order: order)
    }

    static func point(_ id: String, _ p: CGPoint, order: Int) -> MarkShape {
        MarkShape(id: id, group: .text, areas: [CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)], order: order)
    }

    static func caret(_ id: String, _ r: CGRect, order: Int) -> MarkShape {
        MarkShape(id: id, group: .text, areas: [CGRect(x: r.midX - 5, y: r.midY - 7, width: 10, height: 14)], order: order)
    }

    static func box(_ id: String, _ rects: [CGRect], order: Int) -> MarkShape {
        MarkShape(id: id, group: .box, areas: rects.map { $0.insetBy(dx: -3, dy: -3) }, order: order)
    }
}

enum MarkHit {
    /// The ids of the comments under a point, best first: labels, then text marks, notes and carets, then boxes;
    /// within a group the smaller area first, then document order. Each area is at least `minSize` square (8 view
    /// points in page units).
    static func hits(at p: CGPoint, shapes: [MarkShape], minSize: CGFloat) -> [String] {
        func grown(_ r: CGRect) -> CGRect {
            r.insetBy(dx: -max(0, (minSize - r.width) / 2), dy: -max(0, (minSize - r.height) / 2))
        }
        let hit = shapes.filter { s in s.areas.contains { grown($0).contains(p) } }
        let sorted = hit.sorted { a, b in
            let aa = a.areas.reduce(0) { $0 + $1.width * $1.height }, ba = b.areas.reduce(0) { $0 + $1.width * $1.height }
            return (a.group, aa, a.order) < (b.group, ba, b.order)
        }
        var seen = Set<String>()
        return sorted.map(\.id).filter { seen.insert($0).inserted }
    }

    /// Repeated clicks cycle: when the selected comment is among the hits, the next one (wrapping) is picked.
    static func pick(_ hits: [String], selected: String?) -> String? {
        guard let sel = selected, let i = hits.firstIndex(of: sel) else { return hits.first }
        return hits[(i + 1) % hits.count]
    }

    /// A change band (minY−4…minY+1 under each rect) or a deletion's × (±5 pt) under a point. `whole` (the Changes
    /// tab): the changed words' lines too, each + 2 pt and the band, at least `minSize` square.
    static func changeHit(at p: CGPoint, rects: [CGRect], isDelete: Bool, whole: Bool = false,
                          minSize: CGFloat = 0) -> Bool {
        rects.contains { r in
            let a = isDelete ? CGRect(x: r.midX - 5, y: r.midY - 5, width: 10, height: 10)
                : whole ? CGRect(x: r.minX - 2, y: r.minY - 4, width: r.width + 4, height: r.height + 6)
                : CGRect(x: r.minX, y: r.minY - 4, width: r.width, height: 5)
            return a.insetBy(dx: -max(0, (minSize - a.width) / 2), dy: -max(0, (minSize - a.height) / 2)).contains(p)
        }
    }

    /// Where a click on a paragraph's bar counts (POLISH §6), in page space: the bar widened to `minSize` (8 view
    /// points), 1 pt above and below, but at most 2.5 pt towards the text, which is 3 pt away (`textRight`: the bar is
    /// left of the text), so a click on the text stays a click on the text.
    static func barArea(_ r: CGRect, textRight: Bool, minSize: CGFloat) -> CGRect {
        let grow = max(0, (minSize - r.width) / 2)
        let x0 = r.minX - (textRight ? grow : min(grow, 2.5)), x1 = r.maxX + (textRight ? min(grow, 2.5) : grow)
        return CGRect(x: x0, y: r.minY - 1, width: x1 - x0, height: r.height + 2)
    }
}

/// How the comment panel scrolls to the expanded card (UX.md §6 Panel scroll).
enum ScrollMode: Equatable {
    case centre  // J/K, a click on a mark, --select, a new comment
    case minimal  // a click on a row: the least movement, top first
    /// An answer moved on to the next card to check (POLISH §6): the new card takes the answered card's place on screen
    /// (PanelTable.setExpanded), then the least movement that shows it whole, as `minimal`.
    case slot
    /// R, Return or Follow up with the field empty: the cursor goes into the card's follow-up field, at the card's end
    /// above its answer row. A card taller than the panel whose end is out of view, below or above, gets its end 16 pt
    /// above the bottom; another, as `minimal`.
    case end
}

struct ScrollDecision: Equatable {
    var delta: CGFloat  // how far the content moves up (the offset grows)
    var animated: Bool

    static let margin: CGFloat = 16

    /// `minY`/`maxY` are the card's edges relative to the top of the visible area (below the pinned header), and
    /// `viewport` that area's height. nil when the card is already fully visible with 16 pt margins.
    static func decide(minY: CGFloat, maxY: CGFloat, viewport v: CGFloat, mode: ScrollMode,
                       reduceMotion: Bool = false) -> ScrollDecision? {
        let h = maxY - minY, m = margin
        let tall = h > v - 2 * m
        if tall && mode == .end {
            guard maxY > v - m + 0.5 || maxY < m - 0.5 else { return nil }  // its end is in view
            let delta = maxY - (v - m)
            return ScrollDecision(delta: delta, animated: !reduceMotion && abs(delta) <= 2 * v)
        }
        if tall ? abs(minY - m) < 0.5 : (minY >= m - 0.5 && maxY <= v - m + 0.5) { return nil }
        let target: CGFloat
        if tall {
            target = m
        } else if mode == .centre {
            target = (v - h) / 2
        } else {
            target = minY < m ? m : v - m - h
        }
        let delta = minY - target
        guard abs(delta) >= 0.5 else { return nil }
        return ScrollDecision(delta: delta, animated: !reduceMotion && abs(delta) <= 2 * v)
    }
}

/// The keyboard map (UX.md §9), as a pure function of what is on screen.
enum KeyAction: Equatable {
    case next, previous
    case verdict(String)  // V, R, W: the ledger's verified, reopened, wontfix (VerdictPlan decides what they do)
    case openEditor  // comment on the selection or the pending box
    case pendingColor(MarkColor), pendingKind(MarkKind)
    case clearSelection
    case place, leaveReanchor
    case editNote
    case focusField  // Return on a card to check: the cursor into its follow-up field
    case editRemark  // Return on an answered card: edit this round's follow-up or closing remark
    case sendDraft  // ⌘↩ on a card with an unsent draft: send it as the follow-up
    case choose(CloseChoice)  // the choice row after a bare V or W on text
    case undo, redo  // ⌘Z, ⇧⌘Z: the answers given this round
    case recolor(MarkColor)
    case delete
    case armBox
    case check  // mark the selected change checked, or clear it (UX.md §16)
    case commentOnChange  // Return on a selected change: comment on it (UX.md §16)
    case nextUnread  // N: the next changed paragraph still unread (UX.md §18)
    case markRead  // C: the paragraph gone to with N, or under the selection
    case markSectionRead  // Shift-C: its whole section
    case toggleFocus  // F: Focus on or off (POLISH §3 row 5)
    case hideMarkBar  // Esc while a new comment's mark shows its toolbar (UX.md §8)
}

struct KeyState: Equatable {
    enum Card: Equatable { case new, carried(answered: Bool) }

    var roundOpen = false
    var reanchoring = false
    var textSelection = false
    var pendingBox = false
    var boxArmed = false
    var card: Card?  // the selected comment, on the Comments tab
    var draft = false  // the selected card's follow-up field holds an unsent draft
    var choice = false  // the selected card shows the choice row
    var changeSelected = false  // a change is selected, on the Changes tab
    var reading = true  // reading marks on (Settings, UX.md §18): off, N, C and Shift-C are not keys of the app
    var markBar = false  // the selected comment's mark shows its toolbar (UX.md §8)
}

enum KeyRoute {
    /// `key` is j k v r w b h u s 1-6 n c shift-c f return esc delete, or cmd-return cmd-z cmd-shift-z. nil: not
    /// handled here.
    static func action(_ key: String, _ s: KeyState) -> KeyAction? {
        if s.boxArmed && key == "esc" { return .armBox }  // Esc disarms box mode
        if s.markBar && key == "esc" { return .hideMarkBar }  // as the selection's toolbar goes on Esc
        // only its own keys, and J/K (which leave the card); never in a round that is not open, nor while a PDF
        // selection, a box or re-anchoring has Return and Esc
        if s.choice && s.roundOpen && !s.reanchoring && !s.textSelection && !s.pendingBox {
            switch key {
            case "return": return .choose(.withText)
            case "delete": return .choose(.withoutText)
            case "esc": return .choose(.cancel)
            case "cmd-return": return .choose(.followUp)
            case "j": return .next
            case "k": return .previous
            default: return nil
            }
        }
        if s.reanchoring {
            switch key {
            case "return": return .place
            case "esc": return .leaveReanchor
            default: break
            }
        }
        if s.roundOpen && (s.textSelection || s.pendingBox) {
            switch key {
            case "return": return .openEditor
            case "esc": return .clearSelection
            case "h", "u", "s":
                if s.pendingBox { return nil }
                return MarkKind.textKinds.first { $0.key == key }.map { .pendingKind($0) }
            default:
                if let n = Int(key), let c = MarkColor.forKey(n) { return .pendingColor(c) }
            }
        }
        switch key {  // always (with reading marks on): where they cannot act (round 1, a closed round) they say why
        case "n": if s.reading { return .nextUnread }
        case "c": if s.reading { return .markRead }
        case "shift-c": if s.reading { return .markSectionRead }
        case "f": return .toggleFocus
        default: break
        }
        if !s.reanchoring {
            switch key {
            case "j": return .next
            case "k": return .previous
            case "cmd-z": if s.roundOpen { return .undo }
            case "cmd-shift-z": if s.roundOpen { return .redo }
            default: break
            }
        }
        if s.roundOpen && s.changeSelected && !s.reanchoring {
            switch key {
            case "v": return .check
            case "return": return .commentOnChange
            default: break
            }
        }
        if s.roundOpen, let card = s.card, !s.reanchoring {
            switch key {
            case "v": if case .carried = card { return .verdict("verified") }
            case "r": if case .carried = card { return .verdict("reopened") }
            case "w": if case .carried = card { return .verdict("wontfix") }
            case "return":
                switch card {
                case .new: return .editNote
                case .carried(answered: false): return .focusField
                case .carried(answered: true): return .editRemark
                }
            case "cmd-return": if card == .carried(answered: false) && s.draft { return .sendDraft }
            case "delete": if card == .new { return .delete }
            default:
                if let n = Int(key), let c = MarkColor.forKey(n) { return .recolor(c) }
            }
        }
        if s.roundOpen && !s.reanchoring && key == "b" { return .armBox }
        return nil
    }
}
