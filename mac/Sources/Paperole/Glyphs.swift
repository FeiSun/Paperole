import AppKit
import SwiftUI

/// UI v4's status signs (design/ui-v4/BRIEF.md §3, §8.4; mockup `ring()`, `ready()`, `glass()`, `done()`,
/// `failed()`, `tray()`, `star()`): drawn on a 20-unit box, close to the SF Symbols, one set wherever a paper's state
/// shows. The ring is the one vermilion sign: a paper that waits on you, filling clockwise as you answer.
enum StatusGlyph: Equatable {
    /// Waits on you; `fill` the share answered (0 an empty ring, 1 a solid one).
    case ring(Double)
    case ready, waiting, finished, failed, noRounds, wellDone
    /// Nothing waits on you: the ring in the secondary ink (not Ready's Sage check; BRIEF §7).
    case nothingWaits

    /// A paper's sign: a first draft is an empty ring, paragraphs to read a full one; `fill` nil (an engine without the
    /// counts) is an empty ring, never a guess.
    static func of(_ s: PaperStatus, fill: Double? = nil) -> StatusGlyph {
        switch s {
        case .toCheck: return .ring(fill ?? 0)
        case .firstDraft: return .ring(0)
        case .toRead: return .ring(1)
        case .ready: return .ready
        case .failed: return .failed
        case .waiting: return .waiting
        case .finished: return .finished
        case .noRounds: return .noRounds
        }
    }

    var color: NSColor {
        switch self {
        case .ring: return Palette.toCheck
        case .ready, .wellDone: return Palette.accent
        case .failed: return Palette.label2
        case .waiting, .finished, .noRounds, .nothingWaits: return Palette.secondary
        }
    }

    /// The sign's side beside text of a size (the mockup's `RING_AT`).
    static func size(text: CGFloat) -> CGFloat {
        switch text {
        case ..<12.5: return 10
        case ..<14: return 11
        case ..<16: return 13
        case ..<19.5: return 14
        case ..<24: return 17
        default: return 21
        }
    }
}

/// The ring's measures in the 20-unit box for a side of `px` points: the stroke at least 1.8 units (thicker when drawn
/// small), the wedge 1 pt inside it.
struct RingGeometry {
    let px: CGFloat
    var stroke: CGFloat { max(1.8, 26 / px) }
    var radius: CGFloat { 10 - stroke / 2 - 0.3 }
    var inner: CGFloat { radius - stroke / 2 - 20 / px }

    /// The wedge for `fill`, clockwise from 12 o'clock, in the 20-unit box: nil when empty, the full disc at 1.
    func wedge(_ fill: Double) -> Path? {
        guard fill > 0 else { return nil }
        let c = CGPoint(x: 10, y: 10)
        guard fill < 1 else { return Path(ellipseIn: CGRect(x: 10 - inner, y: 10 - inner, width: 2 * inner, height: 2 * inner)) }
        var p = Path()
        p.move(to: c)
        p.addLine(to: CGPoint(x: 10, y: 10 - inner))
        // y grows downward, so a clockwise sweep on screen is `clockwise: false` here
        p.addArc(center: c, radius: inner, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * fill), clockwise: false)
        p.closeSubpath()
        return p
    }
}

/// The ring that fills as the advisor answers: the ring and its wedge, one shape.
struct StatusRing: View {
    var fill: Double
    var color: Color

    var body: some View { RingShape(fill: fill).fill(color) }
}

struct RingShape: Shape {
    var fill: Double

    func path(in rect: CGRect) -> Path {
        let px = min(rect.width, rect.height), k = px / 20, geo = RingGeometry(px: px)
        let t = CGAffineTransform(translationX: rect.midX - px / 2, y: rect.midY - px / 2).scaledBy(x: k, y: k)
        let r = geo.radius
        var p = Path(ellipseIn: CGRect(x: 10 - r, y: 10 - r, width: 2 * r, height: 2 * r))
            .strokedPath(StrokeStyle(lineWidth: geo.stroke)).applying(t)
        if let w = geo.wedge(fill) { p.addPath(w.applying(t)) }
        return p
    }
}

/// A status sign of `size` points, its middle on the cap height of text of `text` points in a baseline-aligned stack.
struct StatusGlyphView: View {
    let glyph: StatusGlyph
    var size: CGFloat
    var text: CGFloat

    init(_ glyph: StatusGlyph, size: CGFloat? = nil, text: CGFloat = 13) {
        self.glyph = glyph
        self.size = size ?? StatusGlyph.size(text: text)
        self.text = text
    }

    var body: some View {
        let k = size / 20, color = Color(nsColor: glyph.color)
        let t = CGAffineTransform(scaleX: k, y: k)
        Group {
            switch glyph {
            case .ring(let f): StatusRing(fill: f, color: color)
            case .nothingWaits: StatusRing(fill: 0, color: color)
            case .ready:
                ZStack {
                    Circle().fill(color).padding(0.8 * k)
                    Glyphs.check(ready: true).applying(t).stroke(.white, style: line(size < 10 ? 2.6 : 2))
                }
            case .waiting:
                ZStack {
                    Glyphs.hourglass.applying(t).stroke(color, style: line(1.7))
                    Glyphs.sand.applying(t).stroke(color, style: line(2.2))
                }
            case .finished: Glyphs.check(ready: false).applying(t).stroke(color, style: line(2.1))
            case .failed: Glyphs.octagon.applying(t).stroke(color, style: line(1.7))
            case .noRounds: Glyphs.tray.applying(t).stroke(color, style: line(1.6))
            case .wellDone:
                ZStack {
                    Glyphs.star.applying(t).fill(color)
                    Glyphs.star.applying(t).stroke(color, style: line(1.2))
                }
            }
        }
        .frame(width: size, height: size)
        .alignmentGuide(.firstTextBaseline) { d in d.height / 2 + 0.35 * text }
        .alignmentGuide(.lastTextBaseline) { d in d.height / 2 + 0.35 * text }
    }

    /// A stroke of `w` units, rounded.
    private func line(_ w: CGFloat) -> StrokeStyle { StrokeStyle(lineWidth: w * size / 20, lineCap: .round, lineJoin: .round) }
}

/// The signs' paths in the 20-unit box, from the mockup's SVG.
enum Glyphs {
    static func check(ready: Bool) -> Path {
        var p = Path()
        if ready {
            p.move(to: CGPoint(x: 5.9, y: 10.3)); p.addLine(to: CGPoint(x: 8.7, y: 13.1)); p.addLine(to: CGPoint(x: 14.2, y: 7))
        } else {
            p.move(to: CGPoint(x: 3.8, y: 10.6)); p.addLine(to: CGPoint(x: 7.8, y: 14.6)); p.addLine(to: CGPoint(x: 16.4, y: 5.4))
        }
        return p
    }

    static let hourglass: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 4.8, y: 2.2)); p.addLine(to: CGPoint(x: 15.2, y: 2.2))
        p.move(to: CGPoint(x: 4.8, y: 17.8)); p.addLine(to: CGPoint(x: 15.2, y: 17.8))
        for (x, d) in [(6.4, 1.0), (13.6, -1.0)] {
            p.move(to: CGPoint(x: x, y: 2.2))
            p.addCurve(to: CGPoint(x: 10, y: 10), control1: CGPoint(x: x, y: 6), control2: CGPoint(x: 10, y: 6.9))
            p.addCurve(to: CGPoint(x: x, y: 17.8), control1: CGPoint(x: 10, y: 13.1), control2: CGPoint(x: 10 - 3.6 * d, y: 14))
        }
        return p
    }()

    /// The sand in the hourglass's foot.
    static let sand: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 8, y: 16.3)); p.addLine(to: CGPoint(x: 12, y: 16.3))
        return p
    }()

    static let octagon: Path = {
        var p = Path()
        p.addLines((0..<8).map { k in
            let a = Double.pi / 8 + Double(k) * Double.pi / 4
            return CGPoint(x: 10 + 8.6 * cos(a), y: 10 + 8.6 * sin(a))
        })
        p.closeSubpath()
        p.move(to: CGPoint(x: 7.3, y: 7.3)); p.addLine(to: CGPoint(x: 12.7, y: 12.7))
        p.move(to: CGPoint(x: 12.7, y: 7.3)); p.addLine(to: CGPoint(x: 7.3, y: 12.7))
        return p
    }()

    static let tray: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 2.8, y: 11.6))
        p.addLine(to: CGPoint(x: 5.1, y: 5.2))
        p.addCurve(to: CGPoint(x: 6.5, y: 4.2), control1: CGPoint(x: 5.3, y: 4.6), control2: CGPoint(x: 5.9, y: 4.2))
        p.addLine(to: CGPoint(x: 13.5, y: 4.2))
        p.addCurve(to: CGPoint(x: 14.9, y: 5.2), control1: CGPoint(x: 14.1, y: 4.2), control2: CGPoint(x: 14.7, y: 4.6))
        p.addLine(to: CGPoint(x: 17.2, y: 11.6))
        p.addLine(to: CGPoint(x: 17.2, y: 15.5))
        p.addCurve(to: CGPoint(x: 15.7, y: 17), control1: CGPoint(x: 17.2, y: 16.3), control2: CGPoint(x: 16.5, y: 17))
        p.addLine(to: CGPoint(x: 4.3, y: 17))
        p.addCurve(to: CGPoint(x: 2.8, y: 15.5), control1: CGPoint(x: 3.5, y: 17), control2: CGPoint(x: 2.8, y: 16.3))
        p.closeSubpath()
        p.move(to: CGPoint(x: 2.8, y: 11.6))
        p.addLines([CGPoint(x: 7.2, y: 11.6), CGPoint(x: 8.2, y: 13.6), CGPoint(x: 11.8, y: 13.6), CGPoint(x: 12.8, y: 11.6),
                    CGPoint(x: 17.2, y: 11.6)])
        return p
    }()

    static let star: Path = {
        var p = Path()
        p.addLines((0..<10).map { k in
            let a = -Double.pi / 2 + Double(k) * Double.pi / 5, r = k % 2 == 1 ? 4.1 : 9.4
            return CGPoint(x: 10 + r * cos(a), y: 10.6 + r * sin(a))
        })
        p.closeSubpath()
        return p
    }()
}
