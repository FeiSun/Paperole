import AppKit
import SwiftUI

/// Colours of changes in the PDF (CONTRACT §10) and of the cards.
enum Palette {
    /// Changes no comment asked for: a quiet slate teal, apart from the six mark colours and the status colours, and
    /// at least 4.5:1 as text in either mode (UX.md §16). It replaces M1's purple.
    static let unrequested = NSColor(light: 0x355F6C, dark: 0x9CC3CF)
    /// Its band in the PDF, whose pages are white in either mode.
    static let unrequestedBand = NSColor(hex: 0x355F6C)
    static let attachedChange = NSColor(hex: 0x86EFAC)
    static let deletion = NSColor(hex: 0x15803D)
    /// Changed words in a card's Now block: the change bands' green, lighter in Dark Mode (UX.md §3).
    static let changedWords = NSColor(light: 0x16A34A, dark: 0x4ADE80)
    /// Paragraphs to read (UX.md §18): a calm olive, apart from the six mark colours, the status colours, the change
    /// greens and the slate teal. The bar on the page (white in either mode) is 4.5:1 on white; in the app's own
    /// views (the Contents, the status line, the toast) it is lighter in Dark Mode (7.3:1 on a dark background).
    static let readingBar = NSColor(hex: 0x6E7D2A)
    static let reading = NSColor(light: 0x6E7D2A, dark: 0xA3B356)
    /// The matches of a find in the paper (Find.swift): a neutral grey of almost no hue, no mark's colour, on the
    /// page (white in either mode); the current match has the accent's outline too.
    static let find = NSColor(srgbRed: 0x8C / 255, green: 0x91 / 255, blue: 0x8D / 255, alpha: 0.4)

    // UI v2 (design/ui-v2/PROPOSAL.md §3): one colour means one thing.
    /// Only "your move": the To check chip, position uncertain, an unsent draft.
    static let toCheck = NSColor(light: 0xB45309, dark: 0xF59E0B)
    /// Only an error: Not found, a failed build. #C42121 (POLISH §6, 13): #DC2626 was 4.46:1 on the panel.
    static let danger = NSColor(light: 0xC42121, dark: 0xF98B8B)
    /// Every decided status (Follow-up, Resolved, Kept as is, New), told apart by its sign.
    static let neutral = NSColor(light: 0x6B7280, dark: 0xA8ADB7)
    /// The dot of a thread section whose text changed (UX.md §3).
    static let change = NSColor(light: 0x15803D, dark: 0x22C55E)
    /// A chip's fill; the fill of what the advisor said (a bubble); the rail and the bar beside the paper's text.
    static let chipFill = pair(NSColor(white: 0, alpha: 0.065), NSColor(white: 1, alpha: 0.09))
    static let bubble = pair(NSColor(white: 0, alpha: 0.045), NSColor(white: 1, alpha: 0.065))
    static let rule = pair(NSColor(white: 0, alpha: 0.10), NSColor(white: 1, alpha: 0.11))
    /// The paper's words on a card that are neither marked nor changed.
    static let paperText = pair(NSColor(white: 0, alpha: 0.68), NSColor(white: 1, alpha: 0.72))

    // UI v2.1 (design/ui-v2.1/POLISH.md §2.2, palette A, Sage; chosen by the test build of 2026-10-18, UX.md §19): the
    // app's accent is its AccentColor (Resources/Assets.xcassets, `sage`), so `controlAccentColor` and
    // `Color.accentColor` are Sage unless the user picked an accent colour in System Settings. What the app draws (the
    // PDF's backdrop, the panel, the cards) is a grey of almost no hue (LCH chroma ≤ 2); the sidebar, toolbar and sheets
    // are the system's.
    /// The AccentColor asset's values (PaletteTests checks the asset against them).
    static let sage = (light: 0x566B58, dark: 0x5D7A61)
    /// Accent-coloured words and links ("1 edit", Details…, Re-anchor…): 4.5:1 on the card and the panel in either mode,
    /// which the accent itself is not in Dark Mode.
    static let accentText = NSColor(light: 0x4D6150, dark: 0xA5BFA7)
    /// Links in words ("· 1 edit", Details…, Show all, Edit, Re-anchor…; `LinkStyle`): the system's link colour, a blue
    /// that no word of the panel has, so a link reads as one (BACKLOG O32: in `accentText`, a grey-green as quiet as the
    /// secondary words, they read as plain words). 4.9:1 on the panel and 5.3:1 on the card in Light Mode, 6.0:1 and
    /// 5.0:1 in Dark; it follows Increase Contrast.
    static let link = NSColor.linkColor
    /// Behind the PDF's pages.
    static let pdfBackdrop = NSColor(light: 0xE2E3E0, dark: 0x151615)
    /// The comment panel's ground, darker in Dark Mode so the selected card stands out from it.
    static let panel = NSColor(light: 0xF6F6F4, dark: 0x1C1D1C)
    /// The selected card, one step above the panel: white with a soft shadow, or lighter with a hairline in Dark Mode.
    static let card = NSColor(light: 0xFFFFFF, dark: 0x2A2C2A)
    static let cardLine = pair(.clear, NSColor(white: 1, alpha: 0.075))
    /// The panel's text: titles, notes and rows; group headers; secondary words (5.2:1 on the panel, 6.9:1 in Dark Mode;
    /// every date too); tertiary only for placeholders (POLISH §2.2).
    static let label = NSColor(light: 0x1F2621, dark: 0xE6EBE6)
    static let label2 = NSColor(light: 0x3D473F, dark: 0xC5CDC6)
    static let secondary = NSColor(light: 0x5F6A61, dark: 0x9EA89F)
    static let tertiary = NSColor(light: 0x98A199, dark: 0x6C756D)
    /// A row under the pointer.
    static let hover = pair(NSColor(white: 0, alpha: 0.045), NSColor(white: 1, alpha: 0.05))
    /// The sidebar's row of the paper Review shows (`OpenPaperFill`): as the sidebar's own selection looks while the list
    /// does not have the keys (the system's, measured: #D8D8D8 on the sidebar's #ECEBEB, #545252 on #3A3838; a row's
    /// background is drawn lighter in Light Mode and brighter in Dark Mode than its colour says, hence one alpha).
    static let openPaper = pair(NSColor(white: 0, alpha: 0.11), NSColor(white: 1, alpha: 0.11))
    /// The panel's toast after an answer: dark in Light Mode, light in Dark Mode; opaque, as every float (POLISH §2.4).
    static let toast = pair(NSColor(srgbRed: 30 / 255, green: 30 / 255, blue: 32 / 255, alpha: 1),
                            NSColor(srgbRed: 242 / 255, green: 242 / 255, blue: 244 / 255, alpha: 1))
    static let toastText = pair(.white, NSColor(hex: 0x1C1C1E))
    /// The Finish sheet: its ground, darker in Dark Mode so its grouped boxes stand out, and those boxes (POLISH §2.2,
    /// Sage: almost no hue, the boxes the card's colour).
    static let sheet = NSColor(light: 0xF6F6F3, dark: 0x1E1F1E)
    static let group = NSColor(light: 0xFFFFFF, dark: 0x2A2C2A)
    /// A quiet accent fill behind the one first-run tip (POLISH §3 row 14): the accent at 13% (28% in Dark Mode).
    static let accentTint = pair(NSColor(hex: sage.light).withAlphaComponent(0.13), NSColor(hex: sage.dark).withAlphaComponent(0.28))
    /// The Jump panel, which floats over the window (POLISH §2.4–2.5, §3 row 12): opaque with a hairline, no blur over
    /// the PDF.
    static let float = NSColor(light: 0xFBFBFA, dark: 0x2B2E2C)
    static let floatLine = pair(NSColor(white: 0, alpha: 0.12), NSColor(white: 1, alpha: 0.12))

    /// A colour for each appearance.
    static func pair(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { a in a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }
}

/// The palette's text colours as SwiftUI colours, for the panel and the cards (POLISH §2.2). SwiftUI's `.secondary`
/// is the system's lighter grey, and a Text's own `.secondary` does not follow a hierarchical style set above it, so
/// the panel names these.
/// One sign per state (the UI audit: ⚠ meant four things, and "did not build" had three looks): the octagon for a
/// round that did not build, wherever it shows; the triangle only for a build with errors and a comment not found; a
/// question mark for a mark whose place is uncertain (amber, with its words).
enum BuildSign {
    static let failed = "xmark.octagon"
    static let errors = "exclamationmark.triangle"
    static let uncertain = "questionmark.circle"
}

/// One page title for the hierarchy's three levels (the UI audit: 30, 28 and 20 pt): All Students, a student, a
/// paper; the paper's title in New York, as the paper's own words, at the same size.
enum PageType {
    static let title = Font.system(size: 24, weight: .bold)
    static let paperTitle = Font.system(size: 24, weight: .semibold, design: .serif)
}

enum Ink {
    static let label = Color(nsColor: Palette.label)
    static let label2 = Color(nsColor: Palette.label2)
    static let secondary = Color(nsColor: Palette.secondary)
    static let tertiary = Color(nsColor: Palette.tertiary)
    static let accentText = Color(nsColor: Palette.accentText)
    static let link = Color(nsColor: Palette.link)
}

/// A mark colour the advisor picks per comment (UX.md §5). Fills are drawn at alpha 0.35, inks at full opacity. Green
/// is kept for changes and "resolved", so the second colour is teal; an M2a ledger's "green" reads as teal.
enum MarkColor: String, CaseIterable, Identifiable {
    case yellow, teal, blue, pink, purple, orange

    init?(name: String) { self.init(rawValue: name == "green" ? "teal" : name) }

    var id: String { rawValue }
    var name: String { rawValue.capitalized }
    var key: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }

    var fill: NSColor {
        switch self {
        case .yellow: return NSColor(hex: 0xEAB308)
        case .teal: return NSColor(hex: 0x2DD4BF)
        case .blue: return NSColor(hex: 0x60A5FA)
        case .pink: return NSColor(hex: 0xF472B6)
        case .purple: return NSColor(hex: 0xA78BFA)
        case .orange: return NSColor(hex: 0xFB923C)
        }
    }

    var ink: NSColor {
        switch self {
        case .yellow: return NSColor(hex: 0xA16207)
        case .teal: return NSColor(hex: 0x0F766E)
        case .blue: return NSColor(hex: 0x1D4ED8)
        case .pink: return NSColor(hex: 0xBE185D)
        case .purple: return NSColor(hex: 0x6D28D9)
        case .orange: return NSColor(hex: 0xC2410C)
        }
    }

    /// The marked words on a card, as a tint whatever the kind (UX.md §3): in the thread's first section 36% (30% in
    /// Dark Mode; 40% before POLISH §6, 12), and faintly where the mark sits in later ones, 14% (16%).
    func tint(strong: Bool) -> NSColor {
        Palette.pair(fill.withAlphaComponent(strong ? 0.36 : 0.14), fill.withAlphaComponent(strong ? 0.30 : 0.16))
    }

    static func forKey(_ n: Int) -> MarkColor? { n >= 1 && n <= allCases.count ? allCases[n - 1] : nil }
}

/// highlight, underline and strikeout mark selected text; a note sits at a point (or, from M1, on text); a box is
/// drawn around a figure, table or equation.
enum MarkKind: String, CaseIterable, Identifiable {
    case highlight, underline, strikeout, note, box

    var id: String { rawValue }
    static let textKinds: [MarkKind] = [.highlight, .underline, .strikeout]

    var name: String {
        switch self {
        case .highlight: return "Highlight"
        case .underline: return "Underline"
        case .strikeout: return "Strikeout"
        case .note: return "Note"
        case .box: return "Box"
        }
    }

    var symbol: String {
        switch self {
        case .highlight: return "highlighter"
        case .underline: return "underline"
        case .strikeout: return "strikethrough"
        case .note: return "note.text"
        case .box: return "rectangle.dashed"
        }
    }

    /// H/U/S on a text selection.
    var key: String? {
        switch self {
        case .highlight: return "h"
        case .underline: return "u"
        case .strikeout: return "s"
        default: return nil
        }
    }
}

/// A comment's status in the open round, shown on its chip and PDF label as colour plus icon (UX.md §2). The words are
/// v2's (design/ui-v2/PROPOSAL.md §1.4); the ledger keeps `verified`, `reopened` and `wontfix`.
enum Status: Equatable {
    case new, toCheck, notFound, followUp, resolved, keptAsIs

    init(_ c: Comment) {
        guard c.carried else { self = .new; return }
        self = Status(verdict: c.verdict)
        if self == .toCheck && c.anchorState == "orphan" { self = .notFound }
    }

    init(verdict v: String?) {
        switch v {
        case "verified": self = .resolved
        case "reopened": self = .followUp
        case "wontfix": self = .keptAsIs
        default: self = .toCheck
        }
    }

    /// Amber only for your move (To check), red only for an error (Not found); a decided status is neutral, told apart
    /// by its icon (design/ui-v2/PROPOSAL.md §3).
    var color: NSColor {
        switch self {
        case .toCheck: return Palette.toCheck
        case .notFound: return Palette.danger
        case .new, .followUp, .resolved, .keptAsIs: return Palette.neutral
        }
    }

    /// Only To check and Not found have a coloured chip: To check's is outlined in amber (POLISH §2.2: amber is near
    /// the yellow and orange marks, so it is told apart by its shape), Not found's tinted red.
    var tinted: Bool { self == .toCheck || self == .notFound }

    var icon: String {
        switch self {
        case .new: return "plus"
        case .toCheck: return "circle"
        case .notFound: return "exclamationmark.triangle"
        case .followUp: return "arrow.uturn.backward"
        case .resolved: return "checkmark"
        case .keptAsIs: return "minus"
        }
    }

    /// The status on the PDF's id label, before the id.
    var glyph: String {
        switch self {
        case .new: return "+"
        case .toCheck: return "○"
        case .notFound: return "⚠"
        case .followUp: return "↩"
        case .resolved: return "✓"
        case .keptAsIs: return "–"
        }
    }

    var word: String {
        switch self {
        case .new: return "New"
        case .toCheck: return "To check"
        case .notFound: return "Not found"
        case .followUp: return "Follow-up"
        case .resolved: return "Resolved"
        case .keptAsIs: return "Kept as is"
        }
    }

    /// The word in the shown round (UX.md §2): in a closed or earlier round a comment without an answer is "Left open",
    /// as its group says; "To check" would ask for an answer that can no longer be given.
    func word(open: Bool) -> String { !open && self == .toCheck ? "Left open" : word }

    /// Resolved and kept as is close a comment this round: its mark fades.
    var closed: Bool { self == .resolved || self == .keptAsIs }
}

extension NSColor {
    convenience init(hex: Int) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// The two colours are made once: the provider runs at every use (the panel's text colours, POLISH §2.2).
    convenience init(light: Int, dark: Int) {
        let (l, d) = (NSColor(hex: light), NSColor(hex: dark))
        self.init(name: nil) { a in a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? d : l }
    }
}
