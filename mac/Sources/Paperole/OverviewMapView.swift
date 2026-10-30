import AppKit
import SwiftUI

/// The map's colours for an appearance (VISUAL v3 §3.2–3.3, with the critique's values): every cell fill a little
/// further from the panel than the bands, so cells and bands never join into one mesh; the three steps half the
/// lightness range of before (light L* 85 → 74, dark 23 → 34), their number always the label colour.
struct MapInk {
    var dark: Bool

    /// Each role's colour, as an sRGB hex and an alpha (over the panel or the card it is drawn on).
    func rgba(_ r: MapRole) -> (hex: Int, alpha: Double) {
        let ink = dark ? 0xFFFFFF : 0x1F2621
        switch r {
        // light: the same lightness steps as before, at the dark steps' low chroma (LCh C 2.6–3.9, hue about 100, the
        // panel's grey-green family), not a sand ramp beside the amber chips (the UI audit)
        case .track: return (dark ? 0x2D2E2C : 0xE2E1DC, 1)
        case .s1: return (dark ? 0x383632 : 0xD5D3CE, 1)
        case .s2: return (dark ? 0x44413C : 0xC7C5BE, 1)
        case .s3: return (dark ? 0x54504A : 0xB8B5AE, 1)
        case .number, .label: return (dark ? 0xE6EBE6 : 0x1F2621, 1)
        case .name, .label2: return (dark ? 0xC5CDC6 : 0x3D473F, 1)
        case .band: return (ink, dark ? 0.035 : 0.055)
        case .bandSelected: return dark ? (0x7CA080, 0.26) : (0x566B58, 0.22)
        case .fan: return (ink, dark ? 0.065 : 0.065)
        case .wedge: return (ink, dark ? 0.03 : 0.04)
        case .railDot: return (dark ? 0x9EA89F : 0x5F6A61, 0.7)
        case .miniTrack: return (dark ? 0x363735 : 0xECEBE7, 1)
        case .mini1: return (dark ? 0x45433F : 0xDDDCD6, 1)
        case .mini2: return (dark ? 0x57534D : 0xC8C6BF, 1)
        case .mini3: return (dark ? 0x6B6660 : 0xB0AEA5, 1)
        case .chartYou: return (dark ? 0x8F988F : 0x7D857E, 1)
        case .chartStudent: return (dark ? 0x3E423E : 0xD5D8D3, 1)
        case .words: return (dark ? 0x4ADE80 : 0x16A34A, 1)
        case .other: return (dark ? 0x9CC3CF : 0x355F6C, 1)
        case .attention: return (dark ? 0xF59E0B : 0xB45309, 1)
        case .danger: return (dark ? 0xF98B8B : 0xC42121, 1)
        case .accent: return (dark ? 0x5D7A61 : 0x566B58, 1)
        case .accentText: return (dark ? 0xA5BFA7 : 0x4D6150, 1)
        case .accentTint: return dark ? (0x7CA080, 0.24) : (0x566B58, 0.16)
        case .rule: return (ink, dark ? 0.09 : 0.10)
        case .secondary: return (dark ? 0x9EA89F : 0x5F6A61, 1)
        case .tertiary: return (dark ? 0x6C756D : 0x98A199, 1)
        case .dimText: return (dark ? 0x9EA89F : 0x566057, 1)
        case .link: return (dark ? 0x419CFF : 0x0068DA, 1)  // NSColor.linkColor
        case .content: return (dark ? 0x1C1D1C : 0xF6F6F4, 1)
        case .card: return (dark ? 0x2A2C2A : 0xFFFFFF, 1)
        case .neutral: return (dark ? 0xA8ADB7 : 0x6B7280, 1)
        case .path: return (dark ? 0x8DB091 : 0x566B58, 1)
        }
    }

    /// The role's colour; `scale` its alpha times that (a legend's swatch, drawn small).
    func color(_ r: MapRole, scale: Double = 1) -> Color {
        let (hex, a) = rgba(r)
        return Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                     blue: Double(hex & 0xFF) / 255, opacity: min(1, a * scale))
    }

    /// The colour as it shows over `ground` (the panel, a card): for the contrast tests.
    func over(_ r: MapRole, _ ground: MapRole = .content) -> NSColor {
        let (hex, a) = rgba(r), (g, _) = rgba(ground)
        func ch(_ h: Int, _ s: Int) -> CGFloat { CGFloat((h >> s) & 0xFF) / 255 }
        func mix(_ s: Int) -> CGFloat { CGFloat(a) * ch(hex, s) + CGFloat(1 - a) * ch(g, s) }
        return NSColor(srgbRed: mix(16), green: mix(8), blue: mix(0), alpha: 1)
    }

    /// The opacity of what steps back while something is followed.
    var dim: Double { dark ? 0.40 : 0.32 }
    /// The edits' ticks (VISUAL §4.3): green and slate teal, a little under full.
    static let tickOpacity = 0.85
}

extension MapFont {
    var swiftUI: Font {
        let w: Font.Weight = weight == .semibold ? .semibold : weight == .regular ? .regular : .medium
        let f = Font.system(size: size, weight: w)
        return self == .number || self == .body || self == .bodyBold ? f.monospacedDigit() : f
    }
}

/// How long the paper map took, for the debug items `ovclick` and `ovkey` (UX.md §21): the last scene's build and the
/// last Canvas draw, in ms, and when that draw ended (`ProcessInfo.systemUptime`).
enum MapTiming {
    private(set) static var build: Double = 0
    private(set) static var draw: Double = 0
    private(set) static var drawnAt: TimeInterval = 0

    static func ms(since t0: TimeInterval) -> Double { ((ProcessInfo.processInfo.systemUptime - t0) * 10_000).rounded() / 10 }
    static func built(since t0: TimeInterval) { build = ms(since: t0) }
    static func drawn(since t0: TimeInterval) {
        draw = ms(since: t0)
        drawnAt = ProcessInfo.processInfo.systemUptime
    }
}

/// Draws a `MapScene` (OVERVIEW-v2 §4) in one Canvas, in the mockup's order: the lens, the bands, the rows (rail,
/// readout, cells, chips, ticks), the fold, the paths, then the numbers on top of everything inside the rows, the
/// structure labels and the page axis.
struct MapCanvas: View, Equatable {
    let scene: MapScene
    @Environment(\.colorScheme) private var scheme

    static func == (a: MapCanvas, b: MapCanvas) -> Bool { a.scene.stamp == b.scene.stamp }

    var body: some View {
        Canvas { ctx, _ in
            let t0 = ProcessInfo.processInfo.systemUptime
            Self.draw(scene, in: &ctx, ink: MapInk(dark: scheme == .dark))
            MapTiming.drawn(since: t0)
        }
        .frame(width: scene.geometry.width, height: scene.height)
    }

    /// A text. Its opacity multiplies the context's (the UI audit: it replaced it, so a dimmed cell's name drew at full
    /// strength while its number faded to 1.9:1); `dimmed` (what steps back while something is followed) draws it in
    /// the dimmed words' colour at its own opacity, so it stays readable.
    static func text(_ t: MapText, in ctx: inout GraphicsContext, ink: MapInk, opacity: Double = 1, dimmed: Bool = false) {
        let role: MapRole = dimmed && t.ink != .tertiary ? .dimText : t.ink
        let r = ctx.resolve(Text(t.text).font(t.font.swiftUI).foregroundColor(ink.color(role)))
        let size = r.measure(in: CGSize(width: 4000, height: 200))
        let b = r.firstBaseline(in: size)
        let x0 = t.anchor == .start ? t.x : t.anchor == .middle ? t.x - size.width / 2 : t.x - size.width
        let rect = CGRect(x: x0, y: t.baseline - b, width: size.width, height: size.height)
        var c = ctx
        if dimmed { c.opacity = t.opacity * opacity } else { c.opacity *= t.opacity * opacity }
        if let halo = t.halo {
            let h = c.resolve(Text(t.text).font(t.font.swiftUI).foregroundColor(ink.color(halo)))
            for (dx, dy) in [(-1.6, 0.0), (1.6, 0), (0, -1.6), (0, 1.6), (-1.1, -1.1), (1.1, -1.1), (-1.1, 1.1), (1.1, 1.1)] {
                c.draw(h, in: rect.offsetBy(dx: dx, dy: dy))
            }
        }
        c.draw(r, in: rect)
    }

    private static func polygon(_ pts: [CGPoint]) -> Path {
        var p = Path()
        p.addLines(pts)
        p.closeSubpath()
        return p
    }

    static func curve(_ pts: [CGPoint]) -> Path {
        var p = Path()
        guard let first = pts.first else { return p }
        p.move(to: first)
        for j in 1..<max(1, pts.count) where j < pts.count {
            let a = pts[j - 1], b = pts[j], m = (a.y + b.y) / 2
            p.addCurve(to: b, control1: CGPoint(x: a.x, y: m), control2: CGPoint(x: b.x, y: m))
        }
        return p
    }

    /// A chevron, as the map draws its folds: "›" pointing right (folded), or down (shown).
    static func chevron(at c: CGPoint, down: Bool, in ctx: inout GraphicsContext, color: Color) {
        var p = Path()
        if down {
            p.move(to: CGPoint(x: c.x - 3.2, y: c.y - 1.6)); p.addLine(to: CGPoint(x: c.x, y: c.y + 1.6)); p.addLine(to: CGPoint(x: c.x + 3.2, y: c.y - 1.6))
        } else {
            p.move(to: CGPoint(x: c.x - 1.6, y: c.y - 3.2)); p.addLine(to: CGPoint(x: c.x + 1.6, y: c.y)); p.addLine(to: CGPoint(x: c.x - 1.6, y: c.y + 3.2))
        }
        ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    static func draw(_ s: MapScene, in ctx: inout GraphicsContext, ink: MapInk) {
        let g = s.geometry, cellH = MapGeometry.cell, rug = MapGeometry.rug
        // the lens: hairlines and the wedges of folded parts; Sage only for what is followed
        for w in s.wedges { ctx.fill(polygon(w), with: .color(ink.color(.wedge))) }
        for f in s.fans {
            var p = Path(); p.addLines(f)
            ctx.stroke(p, with: .color(ink.color(.fan)), lineWidth: 0.75)
        }
        if let sel = s.lensSelected { ctx.fill(polygon(sel), with: .color(ink.color(.accentTint))) }
        for t in s.captions { text(t, in: &ctx, ink: ink) }
        if let t = s.sageCaption {
            ctx.fill(Path(roundedRect: CGRect(x: g.readoutX, y: t.baseline - 6, width: 6, height: 6), cornerRadius: 1.5),
                     with: .color(ink.color(.accent)))
            text(t, in: &ctx, ink: ink)
        }
        // the bands: one quiet tone, no edge; Sage for what is followed
        for b in s.bands {
            var c = ctx
            if b.dim { c.opacity = 0.3 }
            let p = polygon(b.points)
            if b.hollow {
                c.stroke(p, with: .color(ink.color(.accent)), lineWidth: 1)
            } else {
                c.fill(p, with: .color(ink.color(b.selected ? .bandSelected : .band)))
            }
        }
        for (r, t) in s.carriedPills {
            let p = Path(roundedRect: r, cornerRadius: r.height / 2)
            ctx.fill(p, with: .color(ink.color(.card)))
            ctx.stroke(p, with: .color(ink.color(.accent)), lineWidth: 1)
            text(t, in: &ctx, ink: ink)
        }
        // the rows
        for row in s.rows {
            let cy = row.y + cellH / 2
            if let (a, b) = row.line {
                var p = Path(); p.move(to: CGPoint(x: 10, y: a)); p.addLine(to: CGPoint(x: 10, y: b))
                ctx.stroke(p, with: .color(ink.color(.rule)), lineWidth: 1)
            }
            var rc = ctx
            if row.dim { rc.opacity = 0.38 }
            if let pill = row.pill {
                let p = Path(roundedRect: pill, cornerRadius: 6)
                rc.fill(p, with: .color(ink.color(row.pillSelected ? .accentTint : .track)))
                if row.pillSelected { rc.stroke(p, with: .color(ink.color(.accent)), lineWidth: 1.5) }
            }
            switch row.node {
            case .dot:
                rc.fill(Path(ellipseIn: CGRect(x: 7, y: cy - 3, width: 6, height: 6)), with: .color(ink.color(.railDot)))
            case .toCheck, .failed:
                let p = Path(ellipseIn: CGRect(x: 5.5, y: cy - 4.5, width: 9, height: 9))
                rc.fill(p, with: .color(ink.color(.content)))
                rc.stroke(p, with: .color(ink.color(row.node == .failed ? .danger : .attention)), lineWidth: 1.8)
            }
            text(row.title, in: &rc, ink: ink, dimmed: row.dim)
            text(row.dates, in: &rc, ink: ink, dimmed: row.dim)
            if let t = row.carried {
                let my = t.baseline - 4
                var p = Path()
                p.move(to: CGPoint(x: 7, y: my + 1.5)); p.addLine(to: CGPoint(x: 10, y: my - 1.8)); p.addLine(to: CGPoint(x: 13, y: my + 1.5))
                ctx.stroke(p, with: .color(ink.color(.secondary).opacity(t.opacity)),
                           style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                text(t, in: &ctx, ink: ink)
            }
            for t in row.readout { text(t, in: &rc, ink: ink, dimmed: row.dim) }
            if let t = row.sage {
                rc.fill(Path(roundedRect: CGRect(x: g.readoutX, y: t.baseline - 6, width: 6, height: 6), cornerRadius: 1.5),
                        with: .color(ink.color(.accent)))
                text(t, in: &rc, ink: ink, dimmed: row.dim)
            }
            if let f = row.failed {
                rc.stroke(Path(roundedRect: f, cornerRadius: 4), with: .color(ink.color(.danger)),
                          style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                if let t = row.failedText { signed(t, in: &rc, ink: ink, dimmed: row.dim) }
                continue
            }
            if let box = row.pages {
                rc.fill(Path(roundedRect: box, cornerRadius: 4), with: .color(ink.color(.track)))
                for x in row.pageLines {  // the gaps between its pages, in the panel's colour
                    rc.fill(Path(CGRect(x: x - 0.6, y: row.y, width: 1.2, height: cellH)), with: .color(ink.color(.content)))
                }
                for d in row.dots {
                    rc.fill(Path(ellipseIn: CGRect(x: d.x - 2.3, y: d.y - 2.3, width: 4.6, height: 4.6)), with: .color(ink.color(.secondary)))
                }
                if let t = row.caption { text(t, in: &rc, ink: ink, dimmed: row.dim) }
            }
            for q in row.quiet {
                rc.fill(Path(roundedRect: q.rect, cornerRadius: 4), with: .color(ink.color(.track)))
                if let t = q.name {
                    var qc = rc
                    if q.dim { qc.opacity *= ink.dim }
                    text(t, in: &qc, ink: ink, dimmed: q.dim || row.dim)
                }
            }
            for c in row.cells {
                var cc = rc
                if c.dim { cc.opacity *= ink.dim }
                if !c.quiet { cc.fill(Path(roundedRect: c.rect, cornerRadius: 4), with: .color(ink.color(.cell(c.level)))) }
                if c.fold != nil, c.rect.width >= 16 {
                    chevron(at: CGPoint(x: c.rect.minX + 9, y: c.rect.midY), down: false, in: &cc, color: ink.color(.secondary))
                }
                if let t = c.name { text(t, in: &cc, ink: ink, dimmed: c.dim || row.dim) }
                if c.selected {
                    rc.stroke(Path(roundedRect: c.rect.insetBy(dx: -2.5, dy: -2.5), cornerRadius: 6), with: .color(ink.color(.accent)),
                              lineWidth: 2)
                }
            }
            for c in row.chips {
                var cc = rc
                if c.dim { cc.opacity *= ink.dim }
                let p = Path(roundedRect: c.rect, cornerRadius: c.rect.height / 2)
                cc.fill(p, with: .color(ink.color(.card)))
                cc.stroke(p, with: .color(ink.color(.attention)), lineWidth: 1)
                cc.stroke(Path(ellipseIn: CGRect(x: c.ring.x - 3.1, y: c.ring.y - 3.1, width: 6.2, height: 6.2)),
                          with: .color(ink.color(.attention)), lineWidth: 1.4)
                text(c.text, in: &cc, ink: ink, dimmed: c.dim || row.dim)
            }
            if let xe = row.endcap {
                var l = Path(); l.move(to: CGPoint(x: xe, y: row.y + 2)); l.addLine(to: CGPoint(x: xe, y: row.y + cellH - 2))
                rc.stroke(l, with: .color(ink.color(.tertiary)), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                if let t = row.endText { text(t, in: &rc, ink: ink, dimmed: row.dim) }
            }
            if let u = row.unplaced {
                rc.fill(Path(roundedRect: u, cornerRadius: 4), with: .color(ink.color(.cell(row.unplacedLevel))))
                if let t = row.unplacedText { text(t, in: &rc, ink: ink, dimmed: row.dim) }
                if let t = row.unplacedCaption { text(t, in: &rc, ink: ink, dimmed: row.dim) }
            }
            for t in row.ticks {
                var tc = rc
                tc.opacity *= t.dim ? 0.25 : MapInk.tickOpacity
                if t.unrequested {
                    tc.fill(Path(roundedRect: CGRect(x: t.x - 0.75, y: t.top + 2, width: 1.5, height: 2.6), cornerRadius: 0.6),
                            with: .color(ink.color(.other)))
                    tc.fill(Path(ellipseIn: CGRect(x: t.x - 1.5, y: t.top + 5, width: 3, height: 3)), with: .color(ink.color(.other)))
                } else {
                    tc.fill(Path(roundedRect: CGRect(x: t.x - 0.75, y: t.top + 2, width: 1.5, height: 5), cornerRadius: 0.6),
                            with: .color(ink.color(.words)))
                }
                if t.toCheck {
                    rc.stroke(Path(ellipseIn: CGRect(x: t.x - 4, y: t.top + 0.5, width: 8, height: 8)),
                              with: .color(ink.color(.attention)), lineWidth: 1.3)
                }
            }
        }
        // folded older rounds
        if let f = s.fold {
            ctx.fill(Path(ellipseIn: CGRect(x: f.node.x - 3, y: f.node.y - 3, width: 6, height: 6)), with: .color(ink.color(.railDot)))
            text(f.title, in: &ctx, ink: ink)
            ctx.fill(Path(roundedRect: f.rect, cornerRadius: 4), with: .color(ink.color(.track)))
            text(f.text, in: &ctx, ink: ink)
            text(f.link, in: &ctx, ink: ink)
        }
        if let pb = s.pageBand {
            let p = Path(roundedRect: pb, cornerRadius: 5)
            ctx.fill(p, with: .color(ink.color(.accentTint).opacity(0.5)))
            ctx.stroke(p, with: .color(ink.color(.accent)), lineWidth: 1.5)
        }
        // the paths of what is followed
        for path in s.paths {
            ctx.stroke(curve(path.points.map(\.at)), with: .color(ink.color(.path)),
                       style: StrokeStyle(lineWidth: path.thin ? 1.6 : 2.2, lineCap: .round))
            for p in path.points { point(p, in: &ctx, ink: ink) }
        }
        // the numbers, over everything inside the rows; the edits made for the comment followed
        for row in s.rows {
            var rc = ctx
            if row.dim { rc.opacity = 0.38 }
            for t in row.ticks where t.strong {
                let r = CGRect(x: t.x - 1.3, y: t.top + 1.5, width: 2.6, height: rug - 1)
                rc.stroke(Path(roundedRect: r, cornerRadius: 0.8), with: .color(ink.color(.content)), lineWidth: 0.8)
                rc.fill(Path(roundedRect: r, cornerRadius: 0.8), with: .color(ink.color(.words)))
            }
            for c in row.cells {
                if let t = c.number { text(t, in: &rc, ink: ink, dimmed: c.dim || row.dim) }
            }
        }
        for l in s.labels {
            if let (a, b) = l.leader {
                var p = Path(); p.move(to: a); p.addLine(to: b)
                ctx.stroke(p, with: .color(ink.color(.secondary).opacity(l.text.opacity * 0.7)), lineWidth: 0.75)
            }
            text(l.text, in: &ctx, ink: ink)
        }
        for t in s.axis { text(t, in: &ctx, ink: ink) }
        for a in s.axisParts {
            if a.bracket.count == 3 {
                let (x0, x1, y) = (a.bracket[0], a.bracket[1], a.bracket[2])
                var p = Path()
                p.move(to: CGPoint(x: x0, y: y - 3)); p.addLine(to: CGPoint(x: x0, y: y)); p.addLine(to: CGPoint(x: x1, y: y)); p.addLine(to: CGPoint(x: x1, y: y - 3))
                ctx.stroke(p, with: .color(ink.color(.rule)), lineWidth: 1)
                let r = CGRect(x: a.chevron.map { $0.x - 6 } ?? a.text.x, y: y - 6, width: a.link.rect.maxX - (a.chevron.map { $0.x - 6 } ?? a.text.x) + 6, height: 12)
                ctx.fill(Path(r), with: .color(ink.color(.content)))  // the bracket's line stops at its words
            }
            if let c = a.chevron { chevron(at: c, down: true, in: &ctx, color: ink.color(.secondary)) }
            text(a.text, in: &ctx, ink: ink)
            text(a.link, in: &ctx, ink: ink)
        }
        if let t = s.foldLink { text(t, in: &ctx, ink: ink) }
    }

    /// A failed build's words: its sign in red, the words in the label colour (VISUAL §4.7: red only for what is
    /// broken). The words start with ⚠ where the sign goes; it is drawn as the one "did not build" sign, the octagon
    /// (`BuildSign.failed`; the UI audit: the same state was ⚠, ⊗ and a filled octagon).
    static func signed(_ t: MapText, in ctx: inout GraphicsContext, ink: MapInk, dimmed: Bool = false) {
        guard t.text.hasPrefix("⚠") else { return text(t, in: &ctx, ink: ink, dimmed: dimmed) }
        let rest = String(t.text.dropFirst())
        let sign = Text(Image(systemName: BuildSign.failed)).foregroundColor(ink.color(.danger))
        var c = ctx
        if dimmed { c.opacity = 1 }
        let r = c.resolve((sign + Text(rest).foregroundColor(ink.color(dimmed ? .dimText : t.ink))).font(t.font.swiftUI))
        let size = r.measure(in: CGSize(width: 4000, height: 200))
        c.draw(r, in: CGRect(x: t.x, y: t.baseline - r.firstBaseline(in: size), width: size.width, height: size.height))
    }

    /// A path's point (§4.5): ○ written, ● carried, an amber ring to check, ✓ or – closed, ⊗ its passage deleted, □ not
    /// placed in the round, a faint dot on the folded rounds.
    static func point(_ p: MapScene.PathPoint, in ctx: inout GraphicsContext, ink: MapInk) {
        let k: CGFloat = p.small ? 0.75 : 1, x = p.at.x, y = p.at.y
        func circle(_ r: CGFloat) -> Path { Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)) }
        switch p.glyph {
        case .folded:
            ctx.fill(Path(roundedRect: CGRect(x: x - 4, y: y - 4, width: 8, height: 8), cornerRadius: 4), with: .color(ink.color(.path).opacity(0.6)))
        case .unplaced:
            let r = Path(roundedRect: CGRect(x: x - 4.5, y: y - 4.5, width: 9, height: 9), cornerRadius: 1.5)
            ctx.fill(r, with: .color(ink.color(.content)))
            ctx.stroke(r, with: .color(ink.color(.path)), lineWidth: 1.8)
        case .gone:
            ctx.fill(circle(6 * k), with: .color(ink.color(.content)))
            ctx.stroke(circle(6 * k), with: .color(ink.color(.neutral)), lineWidth: 1.6)
            var c = Path()
            c.move(to: CGPoint(x: x - 2.6, y: y - 2.6)); c.addLine(to: CGPoint(x: x + 2.6, y: y + 2.6))
            c.move(to: CGPoint(x: x + 2.6, y: y - 2.6)); c.addLine(to: CGPoint(x: x - 2.6, y: y + 2.6))
            ctx.stroke(c, with: .color(ink.color(.neutral)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        case .resolved, .kept:
            ctx.fill(circle(6.5 * k), with: .color(ink.color(.neutral)))
            ctx.stroke(circle(6.5 * k), with: .color(ink.color(.content)), lineWidth: 1.5)
            var gl = Path()
            if p.glyph == .resolved {
                gl.move(to: CGPoint(x: x - 2.8, y: y + 0.2)); gl.addLine(to: CGPoint(x: x - 0.8, y: y + 2.2)); gl.addLine(to: CGPoint(x: x + 2.8, y: y - 1.8))
            } else {
                gl.move(to: CGPoint(x: x - 2.6, y: y - 1.4)); gl.addLine(to: CGPoint(x: x + 2.6, y: y - 1.4))
                gl.move(to: CGPoint(x: x - 2.6, y: y + 1.6)); gl.addLine(to: CGPoint(x: x + 2.6, y: y + 1.6))
            }
            ctx.stroke(gl, with: .color(.white), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        case .toCheck:
            ctx.stroke(circle(8.5 * k), with: .color(ink.color(.attention)), lineWidth: 1.8)
            ctx.fill(circle(4.8 * k), with: .color(ink.color(.path)))
            ctx.stroke(circle(4.8 * k), with: .color(ink.color(.content)), lineWidth: 1.5)
        case .written:
            ctx.fill(circle(5 * k), with: .color(ink.color(.content)))
            ctx.stroke(circle(5 * k), with: .color(ink.color(.path)), lineWidth: 2)
        case .carried:
            ctx.fill(circle(4.6 * k), with: .color(ink.color(.path)))
            ctx.stroke(circle(4.6 * k), with: .color(ink.color(.content)), lineWidth: 1.5)
        }
    }
}

/// The hover layer over the map (OVERVIEW-v2 §5.1 "悬停"): a dashed ring round the cell under the pointer, the row's
/// section names above it, and the path of a comment hovered anywhere (on the map, in the panel, in the strip) previewed
/// dashed, unless it is already drawn; drawn apart from the map, so the map is not drawn again while the pointer moves.
struct MapHoverLayer: View {
    let scene: MapScene
    let data: PaperOverview
    @ObservedObject var hover: OverviewHover
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { ctx, _ in
            let ink = MapInk(dark: scheme == .dark)
            if let id = hover.comment, !scene.paths.contains(where: { $0.comment == id }), let c = data.comment(id) {
                Self.preview(scene.previewPoints(c), in: &ctx, ink: ink)
            }
            guard let target = hover.target else { return }
            var round: Int?
            func ring(_ r: CGRect) {
                ctx.stroke(Path(roundedRect: r.insetBy(dx: -2, dy: -2), cornerRadius: 6), with: .color(ink.color(.secondary)),
                           style: StrokeStyle(lineWidth: 1.2, dash: [3, 2.5]))
            }
            switch target {
            case .cell(let k, let n):
                round = n
                // a quiet segment: the ring round all of it (its sections are named in the tag)
                if let q = scene.quiet(k, round: n) { ring(q.rect) }
                else if let c = scene.rows.first(where: { $0.n == n })?.cells.first(where: { $0.section == k }), !c.selected { ring(c.rect) }
            case .block(let kind, let n):
                round = n
                if let c = scene.rows.first(where: { $0.n == n })?.cells.first(where: { $0.fold == kind }) { ring(c.rect) }
            case .round(let n), .edit(_, let n), .unplaced(let n): round = n
            default: break
            }
            // the row's section names, above it, clear of its chips and the gap's labels and pills
            guard let n = round else { return }
            for t in scene.hoverNames(n, data) { MapCanvas.text(t, in: &ctx, ink: ink) }
        }
        .frame(width: scene.geometry.width, height: scene.height)
        .allowsHitTesting(false)
    }

    /// A previewed path (the mockup's `.path.prev`): dashed, a little thinner, a small dot at each round.
    static func preview(_ pts: [CGPoint], in ctx: inout GraphicsContext, ink: MapInk) {
        guard !pts.isEmpty else { return }
        var c = ctx
        c.opacity = 0.9
        if pts.count > 1 {
            c.stroke(MapCanvas.curve(pts), with: .color(ink.color(.path)), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, dash: [4, 3]))
        }
        for p in pts {
            let r = Path(ellipseIn: CGRect(x: p.x - 3.6, y: p.y - 3.6, width: 7.2, height: 7.2))
            c.fill(r, with: .color(ink.color(.path)))
            c.stroke(r, with: .color(ink.color(.content)), lineWidth: 1.5)
        }
    }
}

/// The help tags of the map (OVERVIEW-v2 §5.1: a cell, a band, a round, a pending row, an unplaced cap, an edit, a path
/// point, the fold): a title and a few lines. The map draws its own (an NSView help tag waits a second and cannot point
/// at a part of a Canvas).
enum MapHelp {
    static func lines(_ t: MapTarget, _ d: PaperOverview, student: String) -> [String] {
        func pages(_ a: Double, _ b: Double) -> String {
            let p0 = Int(a.rounded(.down)) + 1, p1 = max(p0, Int(b.rounded(.up)))
            return p0 == p1 ? "p.\(p0)" : "pp. \(p0)–\(p1)"
        }
        switch t {
        case .cell(let k, let n):
            guard let r = d.round(n), let sp = r.spans?.first(where: { $0.section == k }) else { return [] }
            let h = r.heat?.first { $0.section == k }
            var out = [sp.title + " · Round \(n)", pages(sp.start, sp.end) + " · " + String(format: "%.1f", sp.end - sp.start) + " pages long"]
            if let prev = d.round(n - 1), prev.hasSections, let match = r.match {
                let into = match.filter { $0.to == k && $0.from != nil }
                if into.isEmpty {
                    out.append("New in Round \(n): no section of Round \(prev.n) became it")
                } else if into.count > 1 {
                    out.append("Round \(prev.n): " + into.compactMap { m in d.sectionTitle(m.from!, round: prev.n) }.joined(separator: " + ") + ", merged")
                } else if let m = into.first, let a = prev.spans?.first(where: { $0.section == m.from }) {
                    out.append("Round \(prev.n): \(a.title), \(pages(a.start, a.end))" + (m.kind == "renamed" ? " (renamed)" : ""))
                }
            }
            let present = h?.present ?? 0
            let each = d.sections.first { $0.key == k }?.comments
            out.append("\(count(present, "comment")) this round" + (present > 0 ? ": \(h?.new ?? 0) new, \(h?.openBefore ?? 0) carried" : "")
                       + (each.map { " · \($0) over all rounds, each once" } ?? ""))
            let steps = d.comments.compactMap { $0.step(in: n) }.filter { $0.section == k && $0.state != "unplaced" && $0.response != "new" }
            if !steps.isEmpty {
                let resp = ["edited", "note_only", "untouched", "waiting"].compactMap { w -> String? in
                    let c = steps.filter { $0.response == w }.count
                    return c > 0 ? "\(c) \(Scope.responses[w] ?? w)" : nil
                }
                out.append((student.isEmpty ? "Student" : student) + ": " + resp.joined(separator: ", "))
            }
            if let h, h.changes > 0 {
                out.append((h.added.map { "+\($0) −\(h.deleted ?? 0) words · " } ?? "") + count(h.changes, "edit"))
            }
            if !r.isClosed, let h, h.openBefore > 0 {
                out.append(h.toCheck > 0 ? "○ \(h.toCheck) to check" : "nothing to check")
            }
            out.append("Click to follow it across rounds · double-click opens Round \(n) here")
            return out
        case .band(let f, let t, let n):
            guard let r = d.round(n) else { return [] }
            if let m = r.match?.first(where: { $0.from == f && $0.to == t }), let from = m.from {
                let od = n - 1
                let a = d.round(od)?.spans?.first { $0.section == from }, b = m.to.flatMap { to in r.spans?.first { $0.section == to } }
                let title = (a?.title ?? from) + (b.map { $0.title != a?.title ? " → " + $0.title : "" } ?? "") + " · Round \(od) → \(n)"
                guard let b, let to = m.to else {
                    return [title, "Removed: none of its paragraphs are in Round \(n)."]
                }
                let evidence = m.kept.flatMap { kept in m.of.map { "\(kept) of its \($0) paragraphs" } } ?? "most of its paragraphs"
                let how: String
                if m.kept == 0, let of = m.of, of > 0, m.kind == "same" || m.kind == "renamed" || m.kind == "moved" {
                    // no paragraph of it is left: it continues by its heading only (the engine's rule), said so
                    how = "Followed by its heading: none of its \(count(of, "paragraph")) are left" + (m.kind == "renamed" ? ", renamed" : "")
                } else {
                    switch m.kind {
                    case "merged": how = "Merged: \(evidence) now sit in \(b.title)"
                    case "renamed": how = "Renamed: the same paragraphs under a new heading, “\(b.title)”"
                    case "moved": how = "Moved: it changed place against the other sections"
                    case "split": how = "Split: \(evidence) now sit in \(b.title)"
                    default: how = "Matched by its paragraphs" + (m.kept.flatMap { k in m.of.map { ": \(k) of \($0) kept" } } ?? "")
                    }
                }
                let carried = MapScene.carriedOn(d, od, n, from, to)
                return [title, how, "\(count(carried, "comment")) carried · " + String(format: "%.1f → %.1f pages", (a?.end ?? 0) - (a?.start ?? 0), b.end - b.start)]
            }
            return []
        case .round(let n):
            guard let r = d.round(n) else { return [] }
            let first = n == d.rounds.first?.n
            var out = ["Round \(n) · " + OverviewText.dates(r.created, r.isClosed ? r.closedAt : nil)]
            // the dates are the import's everywhere; the student's files, when they were last changed another day
            if let f = OverviewText.filesChanged(r) { out.append(f) }
            if r.failed {
                out.append("Build failed · " + MapScene.waitWords(MapScene.waiting(d, n)))
            } else {
                let c = r.comments ?? .init()
                out.append("\(count(c.present, "comment"))" + (r.build?.pages.map { " · " + count($0, "page") } ?? ""))
                if !first {
                    out.append((student.isEmpty ? "Student" : student) + ": " + [c.edited > 0 ? "\(c.edited) edited" : nil,
                        c.noteOnly > 0 ? "\(c.noteOnly) note only" : nil, c.untouched > 0 ? "\(c.untouched) untouched" : nil,
                        c.waiting > 0 ? "\(c.waiting) waiting" : nil].compactMap { $0 }.joined(separator: ", "))
                }
                if let w = r.words {
                    if first { w.body.map { out.append(OverviewText.grouped($0) + " words") } }
                    else if let a = w.added { out.append("+\(a) −\(w.deleted ?? 0) words · " + count(r.edits?.count ?? 0, "edit")) }
                }
                if !r.hasSections {
                    out.append(r.prose == "pending" || r.prose == nil
                               ? "Sections not known yet: the engine is reading this round’s LaTeX. Pages, comments and edits are already right."
                               : "Sections unavailable for this round: its paragraphs could not be read.")
                }
            }
            out.append("Click to show this round’s pages and comments")
            return out
        case .unplaced(let n):
            let ids = d.comments.filter { $0.step(in: n)?.state == "unplaced" }.map(\.id)
            return ["Round \(n) · \(count(ids.count, "comment")) not placed",
                    ids.joined(separator: ", ") + ": the passage was not found in this round. Counted in the row, not in a section."]
        case .edit(let id, let n):
            guard let r = d.round(n), let e = r.edits?.first(where: { $0.id == id }) else { return [] }
            let kind = e.move ? "Move" : e.unrequested ? "Edit nobody asked for" : "Edit"
            var out = [kind + " · Round \(n)" + (e.page.map { " · p.\($0 + 1)" } ?? "")]
            var line = e.section.flatMap { d.sectionTitle($0, round: n) } ?? ""
            if !e.attachedTo.isEmpty { line += (line.isEmpty ? "" : " · ") + "for " + e.attachedTo.joined(separator: ", ") }
            if (e.added ?? 0) + (e.deleted ?? 0) > 0 { line += (line.isEmpty ? "" : " · ") + "+\(e.added ?? 0) −\(e.deleted ?? 0) words" }
            else if e.move { line += (line.isEmpty ? "" : " · ") + "moves print no words" }
            if !line.isEmpty { out.append(line) }
            if let x = r.excerpts?[id], !x.isEmpty { out.append("“" + x + "”") }
            if e.toCheck { out.append("○ to check") }
            return out
        case .comment(let id, let n):
            guard let c = d.comment(id), let st = c.step(in: n) else { return [] }
            let sec = st.section.flatMap { d.sectionTitle($0, round: n) } ?? "no section"
            var out = ["\(id) · \(sec) · " + (st.page.map { "p.\($0 + 1)" } ?? "no page")]
            if let note = c.note, !note.isEmpty { out.append("“" + note + "”") }
            if c.createdRound == n {
                out.append("Written in Round \(n)")
            } else {
                let what = st.state == "unplaced" ? "not placed (passage not found)" : st.state == "gone" ? "passage deleted"
                    : st.response.flatMap { Scope.responses[$0] } ?? ""
                out.append("Round \(n): " + what + (st.answer.flatMap { Scope.answers[$0] }.map { "; " + $0 } ?? ""))
            }
            return out
        case .unfold:
            return ["Older rounds folded", "They do not fit in the window. Click to show every round; the page scrolls."]
        case .fold:
            return ["Fold the older rounds", "Back to what fits in the window."]
        case .block(let kind, let n):
            guard let r = d.round(n), let range = MapFold.range(kind, r) else { return [] }
            let spans = (r.spans ?? [])[range.spans]
            let heat = Dictionary((r.heat ?? []).map { ($0.section, $0) }, uniquingKeysWith: { a, _ in a })
            let total = spans.reduce(0) { $0 + (heat[$1.section]?.present ?? 0) }
            let toCheck = r.isClosed ? 0 : spans.reduce(0) { $0 + (heat[$1.section]?.toCheck ?? 0) }
            var out = [MapFold.label(kind, spans, short: false) + " · Round \(n) · " + MapFold.pages(range),
                       String(format: "%.1f pages, folded", range.length)]
            let checking = spans.filter { (heat[$0.section]?.toCheck ?? 0) > 0 && !r.isClosed }.map(\.title)
            out.append(count(total, "comment") + " this round" + (toCheck > 0 ? ", \(toCheck) to check: " + checking.joined(separator: ", ") : ""))
            if spans.count > 1 || total > 0 {
                out.append(spans.map { "\($0.title) \(heat[$0.section]?.present ?? 0)" }.joined(separator: " · "))
            }
            out.append("Click to show its sections")
            return out
        case .showPart(let kind):
            return ["Show " + kind.name, "Its sections at their real length; Fold puts it back in one block."]
        case .foldPart(let kind):
            return ["Fold " + kind.name, "Back to one block, so the rest of the paper has the room."]
        }
    }

    /// A quiet segment's tag (VISUAL §6.1): its round and pages, each section's name (the one under the pointer in
    /// bold), and what a click does.
    static func quiet(_ q: MapScene.Quiet, under key: String, round n: Int, _ d: PaperOverview) -> [String] {
        guard let r = d.round(n) else { return [] }
        let spans = (r.spans ?? []).filter { q.sections.contains($0.section) }
        guard let a = spans.first, let b = spans.last else { return [] }
        let p0 = Int(a.start.rounded(.down)) + 1, p1 = max(p0, Int(b.end.rounded(.up)))
        let under = spans.first { $0.section == key }.map { d.shortTitle($0.section, $0.title) } ?? ""
        var out = ["Round \(n) · " + (p0 == p1 ? "p.\(p0)" : "pp. \(p0)–\(p1)") + " · no comments",
                   spans.map { s in let t = d.shortTitle(s.section, s.title); return s.section == key ? "**" + t + "**" : t }.joined(separator: " · ")]
        // an edit in it that waits for you is said (the critique: "no comments" alone hid it)
        if !r.isClosed {
            for s in spans {
                let waiting = (r.edits ?? []).filter { $0.section == s.section && $0.toCheck }.count
                if waiting > 0 { out.append(d.shortTitle(s.section, s.title) + ": ○ " + count(waiting, "edit") + " to check") }
            }
        }
        out.append("A click follows \(under) (under the pointer)")
        return out
    }
}

/// The paper map (OVERVIEW-v2 §4): the scene drawn, the hover layer, and a click or a double click on what is under
/// the pointer (§5.1). The pointer's target, the comment it previews and the help tag are the overview's
/// (`OverviewHover`, drawn by `OverviewTipLayer` over the scroll view, so a tag is never cut by it). VoiceOver reads each
/// row as a group: its rail in one sentence, then each cell in one (§7).
struct PaperMapView: View {
    let model: AppModel
    @ObservedObject var overview: OverviewModel
    let hover: OverviewHover
    let scene: MapScene
    let data: PaperOverview
    let student: String
    @State private var last: (target: MapTarget?, time: TimeInterval)?

    var body: some View {
        ZStack(alignment: .topLeading) {
            // a new Canvas for a new scene: in one background run of six the old one kept its last frame though it
            // had drawn the new scene (visual review 2026-10-19)
            MapCanvas(scene: scene).equatable().id(scene.stamp)
            MapHoverLayer(scene: scene, data: data, hover: hover)
            accessibilityRows
            accessibilityControls
        }
        .frame(width: scene.geometry.width, height: scene.height, alignment: .topLeading)
        .background(GeometryReader { g in
            let o = g.frame(in: .named(OverviewLayout.viewport)).origin
            Color.clear
                .onAppear { hover.mapOrigin = o }
                .onChange(of: o) { _, v in hover.mapOrigin = v }
        })
        .contentShape(Rectangle())
        .onTapGesture(count: 1, coordinateSpace: .local) { p in click(at: p) }
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let p): Self.hover(at: p, scene: scene, data: data, student: student, hover: hover)
            case .ended: hover.leave()
            }
        }
        .onAppear {
            overview.folded = scene.folded
            overview.foldedParts = scene.plan.folded
            hover.scene = scene
        }
        .onChange(of: scene.stamp) { _, _ in
            overview.folded = scene.folded
            overview.foldedParts = scene.plan.folded
            hover.scene = scene
        }
    }

    /// The pointer at `p` on the map: what it is over and that thing's help tag (`MapHelp`); no comment to preview (a
    /// path dot is only drawn for a comment whose path is drawn already). `force`: the debug script's `ovhover`, at
    /// once, whether the app is active or not.
    static func hover(at p: CGPoint, scene: MapScene, data: PaperOverview, student: String, hover: OverviewHover, force: Bool = false) {
        let t = scene.target(at: p)
        let at = CGPoint(x: p.x + hover.mapOrigin.x, y: p.y + hover.mapOrigin.y)
        hover.point(at: at, key: t.map { "map:" + String(describing: $0) }, target: t, comment: nil, force: force) {
            if case .cell(let k, let n)? = t, let q = scene.quiet(k, round: n) { return MapHelp.quiet(q, under: k, round: n, data) }
            return t.map { MapHelp.lines($0, data, student: student) } ?? []
        }
    }

    /// A click acts at once; a second one on the same thing within the double-click interval opens Review there. A
    /// folded block shows its part at the first click, so the second lands on what is drawn there now: it counts as
    /// the block's (VISUAL §5.1 "双击"), which opens Review at the part's first section in that round.
    private func click(at p: CGPoint) {
        var t = scene.target(at: p)
        let now = ProcessInfo.processInfo.systemUptime
        if case .block? = last?.target, let l = last, now - l.time <= NSEvent.doubleClickInterval { t = l.target }
        let double = last.map { $0.target == t && now - $0.time <= NSEvent.doubleClickInterval } ?? false
        last = double ? nil : (t, now)
        hover.dismissTip()
        act(t, double: double)
    }

    /// What a click on `t` does (and a VoiceOver button's action).
    private func act(_ t: MapTarget?, double: Bool) {
        switch t {
        case .block(let kind, let n)?:
            if double, let r = data.round(n), let range = MapFold.range(kind, r), let first = r.spans?[range.spans.lowerBound] {
                model.overviewClicked(.section(first.section, round: n), double: true)
            } else {
                model.showPart(kind)
            }
        case .showPart(let kind)?: model.showPart(kind)
        case .foldPart(let kind)?: model.foldPart(kind)
        case .unfold?:
            overview.unfold = true
            overview.takeKeys()
        case .fold?:
            overview.unfold = false
            overview.takeKeys()
        case .edit(let id, let n)?:
            let sec = data.round(n)?.edits?.first { $0.id == id }?.section
            model.overviewClicked(sec.map { .section($0, round: n) }, double: double)
        case let t?: model.overviewClicked(t.item, double: double)
        case nil: model.overviewClicked(nil)
        }
    }

    /// One group a row (its round's name): the rail's sentence first, a button that follows the round, then each cell,
    /// a button that follows its section; each with "Open in Review" as a second action.
    private var accessibilityRows: some View {
        ForEach(scene.rows, id: \.n) { row in
            ZStack(alignment: .topLeading) {
                Color.clear
                    .frame(width: MapGeometry.mapX - 10, height: MapGeometry.cell + 6)
                    .accessibilityElement()
                    .accessibilityLabel(data.round(row.n).map { MapSpeech.row(data, $0, student: student) } ?? "Round \(row.n)")
                    .accessibilityAddTraits(row.pillSelected ? [.isButton, .isSelected] : [.isButton])
                    .accessibilityAction { model.overviewClicked(.round(row.n)) }
                    .accessibilityAction(named: "Open Round \(row.n) in Review") { model.overviewClicked(.round(row.n), double: true) }
                    .padding(.top, max(0, row.y - 3))
                ForEach(row.cells, id: \.section) { c in
                    if let kind = c.fold {
                        // a folded part: one element, whose action shows its sections (VISUAL §5.1)
                        Color.clear
                            .frame(width: max(c.rect.width, 4), height: c.rect.height)
                            .accessibilityElement()
                            .accessibilityLabel(MapSpeech.block(data, kind, row.n))
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { model.showPart(kind) }
                            .accessibilityAction(named: "Open in Review") { model.overviewClicked(.section(c.section, round: row.n), double: true) }
                            .padding(.leading, c.rect.minX)
                            .padding(.top, c.rect.minY)
                    } else {
                        Color.clear
                            .frame(width: max(c.rect.width, 4), height: c.rect.height)
                            .accessibilityElement()
                            .accessibilityLabel(MapSpeech.cell(data, c.section, row.n))
                            .accessibilityAddTraits(c.selected ? [.isButton, .isSelected] : [.isButton])
                            .accessibilityAction { model.overviewClicked(.section(c.section, round: row.n)) }
                            .accessibilityAction(named: "Open in Review") { model.overviewClicked(.section(c.section, round: row.n), double: true) }
                            .padding(.leading, c.rect.minX)
                            .padding(.top, c.rect.minY)
                    }
                }
            }
            .frame(width: scene.geometry.width, height: scene.height, alignment: .topLeading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Round \(row.n)")
            .allowsHitTesting(false)
        }
    }

    /// The older rounds folded, their Fold, and the page axis's Show and Fold (`MapSpeech.controls`): a button each,
    /// whose action is a click there.
    private var accessibilityControls: some View {
        ZStack(alignment: .topLeading) {
            ForEach(MapSpeech.controls(scene), id: \.target) { c in
                Color.clear
                    .frame(width: c.rect.width, height: c.rect.height)
                    .accessibilityElement()
                    .accessibilityLabel(c.label)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { act(c.target, double: false) }
                    .padding(.leading, max(0, c.rect.minX))
                    .padding(.top, max(0, c.rect.minY))
            }
        }
        .frame(width: scene.geometry.width, height: scene.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

/// The map's help tag: opaque, with a hairline, as the app's other floats (POLISH §2.4).
struct MapTip: View {
    let lines: [String]
    @Environment(\.colorScheme) private var scheme

    /// As wide as its longest line, at most 340 pt; longer lines wrap.
    static func width(_ lines: [String]) -> CGFloat {
        let w = lines.enumerated().map { i, l in
            (l as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: i == 0 ? .semibold : .regular)]).width
        }.max() ?? 0
        return min(340, ceil(w) + 2)
    }

    /// A line with the student's added words ("+120") in the edits' green, the one place green says words (the
    /// mockup's tag), and ○ amber.
    static func words(_ line: String, ink: MapInk) -> Text {
        var out = Text("")
        var bold = false  // between ** and **: the name under the pointer in a quiet segment's tag
        for (i, word) in line.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
            var w = Substring(word)
            if w.hasPrefix("**") { bold = true; w = w.dropFirst(2) }
            let ends = w.hasSuffix("**")
            if ends { w = w.dropLast(2) }
            let added = w.count > 1 && w.first == "+" && w.dropFirst().allSatisfy(\.isNumber)
            var t = added ? Text(w).foregroundColor(ink.color(.words)) : w == "○" ? Text(w).foregroundColor(ink.color(.attention)) : Text(w)
            if bold { t = t.fontWeight(.semibold).foregroundColor(ink.color(.label)) }
            out = out + Text(i == 0 ? "" : " ") + t
            if ends { bold = false }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                (i == 0 ? Text(l) : Self.words(l, ink: MapInk(dark: scheme == .dark)))
                    .font(.system(size: 12, weight: i == 0 ? .semibold : .regular))
                    .foregroundStyle(i == 0 ? Ink.label : i == lines.count - 1 && l.hasPrefix("Click") ? Ink.secondary : Ink.label2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: Self.width(lines), alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: Palette.float)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: Palette.floatLine), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
    }
}

/// The legend under the map, one line that wraps (OVERVIEW-v2 §3.3, §4.2; VISUAL v3 §4.8): this paper's three steps,
/// each a swatch and its range, the ○ chip, the two edit ticks, a band, a folded block while one is folded, and Full
/// key; at the right, Map or Table (the table has no ticks, bands or blocks).
struct MapLegend: View {
    let steps: [Int]
    var table = false
    var folded = false
    var setTable: (Bool) -> Void = { _ in }
    @Environment(\.colorScheme) private var scheme
    @State private var showKey = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            items
            Spacer(minLength: 0)
            Toggle(isOn: Binding(get: { table }, set: { setTable($0) })) {
                Image(systemName: "tablecells")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .fixedSize()
            .help(table ? "Show the paper map as a map" : "Show the paper map as a table")
            .accessibilityLabel("Show as a table")
        }
    }

    private var items: some View {
        let ink = MapInk(dark: scheme == .dark), labels = MapShade.labels(steps)
        return WrapLayout(spacing: 18) {
            HStack(spacing: 7) {
                HStack(spacing: 9) {
                    ForEach(0..<3, id: \.self) { i in
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 3).fill(ink.color(.cell(i + 1))).frame(width: 12, height: 12)
                            Text(labels[i]).monospacedDigit().foregroundStyle(Ink.label2)
                        }
                    }
                }
                Text("comments on a section, this round")
            }
            HStack(spacing: 7) {
                HStack(spacing: 3) {
                    Circle().strokeBorder(ink.color(.attention), lineWidth: 1.4).frame(width: 7, height: 7)
                    Text("2").font(.system(size: 11, weight: .semibold)).foregroundStyle(ink.color(.attention))
                }
                .padding(.horizontal, 6).frame(height: 16)
                .background(Capsule().fill(ink.color(.card)))
                .overlay(Capsule().strokeBorder(ink.color(.attention), lineWidth: 1))
                Text("to check")
            }
            if !table { ticksAndBand(ink) }
            if !table && folded {
                HStack(spacing: 7) {
                    Canvas { ctx, size in
                        ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 3), with: .color(ink.color(.track)))
                        MapCanvas.chevron(at: CGPoint(x: 8, y: size.height / 2), down: false, in: &ctx, color: ink.color(.secondary))
                    }
                    .frame(width: 22, height: 14)
                    Text("folded: click to show")
                }
            }
            Button("Full Key") { showKey.toggle() }
                .buttonStyle(LinkStyle())  // a link, as every link in words (the UI audit: it read as a label)
                .font(.system(size: 12, weight: .medium))
                .popover(isPresented: $showKey, arrowEdge: .bottom) { MapKey() }
        }
        .font(.system(size: 12))
        .foregroundStyle(Ink.secondary)
    }

    @ViewBuilder
    private func ticksAndBand(_ ink: MapInk) -> some View {
        HStack(spacing: 7) {
            Canvas { ctx, _ in
                var c = ctx
                c.opacity = MapInk.tickOpacity
                for x in [3.0, 8.0] { c.fill(Path(roundedRect: CGRect(x: x, y: 3, width: 1.5, height: 5), cornerRadius: 0.6), with: .color(ink.color(.words))) }
                c.fill(Path(roundedRect: CGRect(x: 15.25, y: 3, width: 1.5, height: 2.6), cornerRadius: 0.6), with: .color(ink.color(.other)))
                c.fill(Path(ellipseIn: CGRect(x: 14.5, y: 6, width: 3, height: 3)), with: .color(ink.color(.other)))
            }
            .frame(width: 22, height: 12)
            (Text("edits: asked for · ") + Text("nobody asked").foregroundColor(ink.color(.other)))
        }
        HStack(spacing: 7) {
            Canvas { ctx, _ in
                var p = Path()
                p.addLines([CGPoint(x: 3, y: 1), CGPoint(x: 19, y: 1), CGPoint(x: 27, y: 15), CGPoint(x: 11, y: 15)])
                p.closeSubpath()
                // on the legend's ground the band is drawn a little stronger than on the map, to be seen at this size
                ctx.fill(p, with: .color(ink.color(.band, scale: 1.6)))
            }
            .frame(width: 30, height: 16)
            Text("same section a round apart")
        }
    }
}

/// The map's full key (the mockup's encoding section), in words.
struct MapKey: View {
    static let items: [(String, String)] = [
        ("Rows are rounds; cells sit where the sections are",
         "Each row is the paper in one round, newest on top, at one page scale for every row: a shorter round ends with a cap and its page count. A cell is as wide as its section is long, but a short section is drawn wider, so its name and count fit, and the longer ones give it the room; its name sits at the left when it fits, whole or in a short form. References count like any other section."),
        ("Number and shade say one thing",
         "Comments on that section in that round: written then plus still open from before. The shade repeats the count in three steps chosen for this paper (thirds of its own counts), printed in the legend. Neither changes when you follow something."),
        ("A long appendix folds into one block",
         "An appendix longer than three pages (and a References list longer than four) is one block about two pages wide, with its pages under the axis and its comments in one count, shaded as a cell. A click shows its sections at their real length; Fold under the axis folds it again. Following anything inside it shows it first. Settings › Overview turns folding off."),
        ("Quiet segments",
         "Neighbouring sections with no comments, each too narrow for a cell of its own, are drawn as one quiet stretch of track. The pointer names them, and a click or the arrow keys still go section by section."),
        ("To check has its own mark",
         "Only in the open round: an amber ○ chip over the cell says how many of that cell’s comments still wait for your answer. The chips add up to the comments to check."),
        ("Ticks are the student’s edits",
         "One tick per edit, where it was made: a bar when a comment asked for it, a short bar with a dot when nobody did, an amber ring while it still waits for you. When you follow a comment, the edits made for it stand out."),
        ("Bands follow each section by its paragraphs",
         "A band joins a section to itself one round apart; sections are matched by their paragraphs, not their headings. A slanted band moved; two bands into one cell merged; one into two split; a band wider at one end changed length; moved, merged, split and renamed are also said beside it. A cell with no band below was added; a band ending in a point was removed."),
        ("Following something",
         "Click a cell, a band, a round, a page or a comment to follow it: what it touches stays, the rest steps back, and a Sage line under each round’s numbers says what it is in that round. Esc or the token’s × shows the whole paper again; a double click opens Review there."),
        ("Following a comment",
         "Its path shows where it sat in each round: ○ written, ● carried, an amber ring to check, ✓ or – closed, ⊗ its passage was deleted, □ the round could not place it."),
        ("When something is missing",
         "A round whose sections are not known yet shows its pages, comment dots and edits only. Comments a round could not place count in an “unplaced” cap after the row. Older rounds fold when they do not fit the window."),
        ("The readout never changes",
         "Beside each row: the round’s comments and your answers (with the student’s responses in a wide window). What you follow adds one Sage line under it, so a number in a place keeps one meaning."),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Self.items, id: \.0) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.0).font(.system(size: 13, weight: .semibold))
                        Text(item.1).font(.system(size: 12)).foregroundStyle(Ink.label2).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(16)
        }
        .frame(width: 440, height: 460)
    }
}
