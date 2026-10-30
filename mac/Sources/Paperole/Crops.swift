import AppKit
import PDFKit
import SwiftUI

/// How a crop is drawn (UX.md §4). A figure or a picture keeps its paper, as the PDF prints it. Display math, a table, an
/// algorithm or a box on words is drawn from the page's own vectors in the panel's ink, with no paper behind it: the
/// advisor's feedback of 2026-10-20, a formula or a table on a white box read as a screenshot of it. It is still the
/// round's PDF, so the paper's macros and fonts are exactly what was printed.
enum CropLook: String, Equatable, Hashable {
    case paper
    case ink

    /// The environments of a picture: a float of one, a drawing, and the boxes a figure's pictures sit in. A range in a
    /// table is in its `tabular`, so a `center` or `minipage` round an image display is a figure's.
    static let pictureEnvs: Set<String> = ["figure", "wrapfigure", "subfigure", "subfloat", "sidewaysfigure", "tikzpicture",
                                           "pgfpicture", "picture", "overpic", "center", "minipage"]

    /// A comment's crops, by the environment its anchor is in (`env`, without `*`): a picture's as printed, any other
    /// (display math, a table, an algorithm) in ink. Without one, a box on no words (a picture drawn at shipout, an
    /// area of the page) as printed, and a box on words in ink.
    static func comment(env: String?, kind: MarkKind, words: String?) -> CropLook {
        let e = env?.lowercased().replacingOccurrences(of: "*", with: "") ?? ""
        if !e.isEmpty { return pictureEnvs.contains(e) ? .paper : .ink }
        let blank = words?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        return kind == .box && blank ? .paper : .ink
    }

    /// A change's crops: a replaced picture file, an edit in a figure ("Figure 4"), an `\input` of one ("Figure 'plot'
    /// removed") or LaTeX that draws one, as printed; a table's ("Table 2") and any other (display math) in ink.
    static func change(_ ch: Change) -> CropLook {
        if ch.figure != nil { return .paper }
        if let f = ch.float?.lowercased(), !f.isEmpty { return f.hasPrefix("fig") ? .paper : .ink }
        if ch.about?.kind == "file", let t = ch.about?.text.lowercased() {
            if t.hasPrefix("figure") { return .paper }
            if t.hasPrefix("table") { return .ink }
        }
        let draws = ["\\includegraphics", "\\begin{tikzpicture}", "\\begin{figure", "\\begin{subfigure", "\\begin{wrapfigure"]
        return [ch.oldText, ch.newText].contains { s in draws.contains { s.contains($0) } } ? .paper : .ink
    }
}

/// The panel's ink for a crop drawn without its paper (`CropLook.ink`). The area is drawn on white, as printed, and
/// the paper is then taken out ("colour to alpha"): each pixel becomes the least coverage of an ink that, laid on white,
/// gives its colour. White is no ink, so a table's white cells or a white box behind a formula vanish too; black text
/// stays opaque black; a grey row is a faint black, a pink a fifth of red. In Light Mode that ink is the page's own. In
/// Dark Mode each ink's HSL lightness is turned round with its hue and chroma kept (every channel moved by
/// 1 − max − min): black ink becomes light, a red stays the same red, a dark blue a light blue, a grey row a faint light
/// band; then it is multiplied by the panel's label colour, so the page's black is the card's words'.
enum InkMap {
    /// `Palette.label` in Dark Mode (#E6EBE6).
    static let tone: (r: Float, g: Float, b: Float) = (230 / 255, 235 / 255, 230 / 255)

    /// A colour of the page on white (sRGB, 0…1) as an ink (not premultiplied) and its coverage.
    static func ink(_ r: Float, _ g: Float, _ b: Float) -> (r: Float, g: Float, b: Float, a: Float) {
        let a = 1 - min(r, g, b)
        guard a > 0.5 / 255 else { return (0, 0, 0, 0) }
        return ((r - 1 + a) / a, (g - 1 + a) / a, (b - 1 + a) / a, a)
    }

    /// One ink (sRGB, 0…1, not premultiplied) in Dark Mode.
    static func dark(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
        let shift = 1 - max(r, g, b) - min(r, g, b)
        return ((r + shift) * tone.r, (g + shift) * tone.g, (b + shift) * tone.b)
    }

    /// An RGBA8 bitmap of the page drawn on white (opaque), turned in place into its ink, premultiplied, for Light or
    /// Dark Mode.
    static func lift(_ p: UnsafeMutablePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int, dark onDark: Bool) {
        for y in 0..<height {
            let row = p + y * bytesPerRow
            for x in 0..<width {
                let o = row + x * 4
                if o[0] == 255 && o[1] == 255 && o[2] == 255 {  // paper: most of a crop
                    o[0] = 0; o[1] = 0; o[2] = 0; o[3] = 0
                    continue
                }
                let i = ink(Float(o[0]) / 255, Float(o[1]) / 255, Float(o[2]) / 255)
                let (r, g, b) = onDark ? dark(i.r, i.g, i.b) : (i.r, i.g, i.b)
                let m = i.a * 255
                o[0] = UInt8(min(max(r, 0) * m + 0.5, m + 0.5))
                o[1] = UInt8(min(max(g, 0) * m + 0.5, m + 0.5))
                o[2] = UInt8(min(max(b, 0) * m + 0.5, m + 0.5))
                o[3] = UInt8(m + 0.5)
            }
        }
    }
}

/// What a crop is drawn with: its look, the appearance it is drawn for (only an ink crop differs by it), its density
/// in pixels per point and the screen's (so a line is drawn as thick on screen whatever the crop's scale), and its
/// mark's colour as drawn there: an outline on paper, a tint under the ink on an ink crop.
struct CropStyle: Hashable {
    /// An sRGB colour, comparable, so it can key the cache (a comment's colour can change).
    struct RGBA: Hashable, CustomStringConvertible {
        var r, g, b, a: CGFloat
        var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
        var description: String { String(format: "%.3f,%.3f,%.3f,%.3f", r, g, b, a) }

        init(_ c: NSColor, dark: Bool) {
            var s = NSColor.black
            NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
                s = c.usingColorSpace(.sRGB) ?? .black
            }
            (r, g, b, a) = (s.redComponent, s.greenComponent, s.blueComponent, s.alphaComponent)
        }
    }

    var look: CropLook
    var dark: Bool
    var density: CGFloat
    /// The screen's pixels per point (1 or 2).
    var screen: CGFloat = 2
    var mark: RGBA
    var deletion: RGBA
    /// An ink crop's mark: the comment's tint (the marked words' on a card), drawn under the ink so it never crosses a
    /// glyph (the UI audit of 2026-10-21: an outline there read as a strike-through of the next line's words).
    var tint: RGBA

    /// `ink` is the mark's colour: on paper (and in Light Mode) as Aqua resolves it; on an ink crop in Dark Mode as
    /// Dark Aqua does (a card passes its ink for one and its lighter fill for the other). A deletion point is the
    /// changes' green, lighter in Dark Mode. `tint`: an ink crop's mark (the mark's own colour at a fifth when none).
    init(look: CropLook, dark: Bool, density: CGFloat, screen: CGFloat = 2, ink: NSColor, tint: NSColor? = nil) {
        let onDark = look == .ink && dark
        self.look = look
        self.dark = onDark
        self.density = density
        self.screen = max(screen, 1)
        mark = RGBA(ink, dark: onDark)
        deletion = RGBA(onDark ? Palette.changedWords : Palette.deletion, dark: onDark)
        var t = RGBA(tint ?? ink.withAlphaComponent(0.2), dark: onDark)
        if look == .paper { t = RGBA(.clear, dark: false) }  // a figure's mark is its outline
        self.tint = t
    }

    /// Everything but the density: an image drawn for another width of the same crop can stand in for it.
    func sameLook(_ o: CropStyle) -> Bool {
        look == o.look && dark == o.dark && mark == o.mark && deletion == o.deletion && tint == o.tint
    }

    /// A line `pt` points thick on screen, in the page's points of a crop drawn at this density (it is shown at
    /// density ÷ screen of its size: a 1.5 pt outline on a crop shown at half its size is 3 page points).
    func line(_ pt: CGFloat) -> CGFloat { density > 0 ? pt * screen / density : pt }

    /// The density a crop `width` points wide needs on a screen of `screen` pixels per point, for an area `area`
    /// points wide (it is drawn at the area's size and scaled to `width`): rounded up to half a pixel per point, so a
    /// small change of width draws nothing again; at least 1, at most 8, and at most 4096 pixels along its longer side.
    static func density(width: CGFloat, area: CGSize, screen: CGFloat) -> CGFloat {
        guard width > 0, area.width > 0, area.height > 0 else { return 0 }
        let need = width / area.width * max(screen, 1)
        return min(max((need * 2).rounded(.up) / 2, 1), 8, 4096 / max(area.width, area.height))
    }
}

/// Crops of the rounds' build PDFs for figure, table, formula and box cards (UX.md §4). Each PDF is opened read-only on a
/// background queue, drawn there into an image at the density it is shown at, and never written.
final class CropCache: @unchecked Sendable {
    static let shared = CropCache()
    private let cache = NSCache<NSString, NSImage>()
    /// The last image drawn for a crop and look at any density, shown at once while the one for the shown width is
    /// drawn (a card expanded again, a wider panel).
    private let latest = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "Paperole.crops", qos: .userInitiated)
    /// The round PDFs open, the last used last: at most `openLimit` (a paper's rounds; the session's other papers are
    /// dropped). Only touched on `queue`.
    private var docs: [(path: String, doc: PDFDocument)] = []
    static let openLimit = 4

    init() {
        cache.totalCostLimit = 96 << 20  // bytes of the bitmaps
        latest.totalCostLimit = 32 << 20
    }

    /// The paths of the PDFs open, the last used last (for the tests).
    var openPaths: [String] { queue.sync { docs.map(\.path) } }

    /// The crop area (contract coordinates): the rects' union + 6 pt, widened to the page's text extent. A tall area
    /// is drawn whole and scaled down to fit the card's 160 pt.
    static func area(_ req: CropRequest) -> CGRect? {
        if let c = req.clip, c.count == 4, c[2] > c[0], c[3] > c[1] {
            return CGRect(x: c[0], y: c[1], width: c[2] - c[0], height: c[3] - c[1])
        }
        let rs = req.rects.filter { $0.count == 4 }
        guard let f = rs.first else { return nil }
        var u = CGRect(x: f[0], y: f[1], width: f[2] - f[0], height: f[3] - f[1])
        for r in rs.dropFirst() { u = u.union(CGRect(x: r[0], y: r[1], width: r[2] - r[0], height: r[3] - r[1])) }
        u = u.insetBy(dx: -6, dy: -6)
        if let t = req.textX, t.count == 2, t[0] < t[1] {
            u = CGRect(x: min(u.minX, t[0] - 2), y: u.minY, width: max(u.maxX, t[1] + 2) - min(u.minX, t[0] - 2), height: u.height)
        }
        return u
    }

    /// Whether a tint on the request's rects picks out a part of its crop: they cover at most half of its area. A box
    /// drawn round a whole formula or table covers most of it (three quarters or more in the papers tried), and its
    /// tint there is only a backing of its own behind the ink (the advisor's feedback of 2026-10-21): the crop is the
    /// boxed area, so a card draws it bare. A box on a symbol or a few words still has its tint.
    static func picksOut(_ req: CropRequest) -> Bool {
        guard let a = area(req), a.width > 0, a.height > 0 else { return false }
        let covered = req.rects.filter { $0.count == 4 }.reduce(0.0) { sum, r in
            let c = CGRect(x: r[0], y: r[1], width: r[2] - r[0], height: r[3] - r[1]).intersection(a)
            return sum + (c.isNull ? 0 : c.width * c.height)
        }
        return covered <= a.width * a.height / 2
    }

    /// Width / height of the crop, known before it is drawn, so the placeholder has the final size.
    static func aspect(_ req: CropRequest) -> CGFloat {
        guard let a = area(req), a.height > 0 else { return 3 }
        return a.width / a.height
    }

    private static func base(_ req: CropRequest, _ st: CropStyle) -> String {
        "\(req.round)|\(req.pdf ?? "")|\(req.page)|\(req.rects)|\(req.clip ?? [])|\(req.textX ?? [])|\(req.deletion)|"
            + "\(req.faint)|\(st.look.rawValue)|\(st.dark)|\(st.mark)|\(st.deletion)|\(st.tint)"
    }

    private static func key(_ req: CropRequest, _ st: CropStyle) -> NSString { (base(req, st) + "|\(st.density)|\(st.screen)") as NSString }

    func cached(_ req: CropRequest, _ st: CropStyle) -> NSImage? { cache.object(forKey: Self.key(req, st)) }

    /// The last image drawn for the crop in this look and appearance, whatever its density.
    func any(_ req: CropRequest, _ st: CropStyle) -> NSImage? { latest.object(forKey: Self.base(req, st) as NSString) }

    /// A finished image, handed from the crop queue to the main thread and never changed after.
    struct Finished: @unchecked Sendable { let image: NSImage? }

    func image(_ req: CropRequest, _ st: CropStyle) async -> Finished {
        if let img = cached(req, st) { return Finished(image: img) }
        return await withCheckedContinuation { cont in
            queue.async {
                let img = self.render(req, st)
                if let img {
                    let cost = Int(img.size.width * st.density) * Int(img.size.height * st.density) * 4
                    self.cache.setObject(img, forKey: Self.key(req, st), cost: cost)
                    self.latest.setObject(img, forKey: Self.base(req, st) as NSString, cost: cost)
                }
                cont.resume(returning: Finished(image: img))
            }
        }
    }

    private func render(_ req: CropRequest, _ st: CropStyle) -> NSImage? {
        guard let path = req.pdf, let area = Self.area(req) else { return nil }
        let doc: PDFDocument
        if let i = docs.firstIndex(where: { $0.path == path }) {
            doc = docs.remove(at: i).doc
        } else {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), let d = PDFDocument(data: data) else { return nil }
            doc = d
        }
        docs.append((path, doc))
        if docs.count > Self.openLimit { docs.removeFirst(docs.count - Self.openLimit) }
        guard req.page >= 0, req.page < doc.pageCount, let page = doc.page(at: req.page),
              let cg = Self.draw(page, req, st) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: area.width, height: area.height))
    }

    /// The crop of `page` (`req`'s area) as `st` says: on white paper, or its ink alone on a transparent ground
    /// (`InkMap`), then the mark in its colour for that ground.
    static func draw(_ page: PDFPage, _ req: CropRequest, _ st: CropStyle) -> CGImage? {
        guard let area = area(req), st.density > 0 else { return nil }
        let cb = page.bounds(for: .cropBox)
        let s = st.density
        let w = Int(ceil(area.width * s)), h = Int(ceil(area.height * s))
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(NSColor.white.cgColor)  // the paper, as printed (an ink crop takes it out below)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: s, y: s)
        // Page space has y up; the area is in contract coordinates (y down from the top).
        ctx.translateBy(x: -(cb.minX + area.minX), y: -(cb.maxY - area.maxY))
        page.draw(with: .cropBox, to: ctx)
        if st.look == .ink, let data = ctx.data {
            ctx.flush()
            InkMap.lift(data.assumingMemoryBound(to: UInt8.self), width: w, height: h, bytesPerRow: ctx.bytesPerRow,
                        dark: st.dark)
        }
        // lines as thick on screen whatever the crop's scale (the UI audit: a 1.5 page-point outline was a hairline
        // on a table shown at half its size and a heavy frame on a formula shown larger)
        let lw = st.line(1.5)
        for r in req.rects where r.count == 4 {
            guard let pr = Geometry.pdfKitRect(r, cropBox: cb) else { continue }
            if req.deletion {
                // A deletion point (a row deleted from a table): a line across the crop under its line, and a caret,
                // in the PDF's deletion green; a small box there read as a comment on the number before it. The line
                // lies at the bottom of the line's box, between its descenders and the next row's capitals (rows of a
                // tight table overlap by a point), and the caret stands on it after the point, not on the next row.
                let u = st.line(1)
                let y = pr.minY - 0.3, x0 = cb.minX + area.minX + 2, x1 = cb.minX + area.maxX - 2
                ctx.setStrokeColor(st.deletion.cg)
                ctx.setLineWidth(u)
                ctx.setLineDash(phase: 0, lengths: [3 * u, 2 * u])
                ctx.strokeLineSegments(between: [CGPoint(x: x0, y: y), CGPoint(x: x1, y: y)])
                ctx.setLineDash(phase: 0, lengths: [])
                ctx.setFillColor(st.deletion.cg)
                ctx.move(to: CGPoint(x: pr.maxX + 0.5 * u, y: y + 4 * u))
                ctx.addLine(to: CGPoint(x: pr.maxX + 6.5 * u, y: y + 4 * u))
                ctx.addLine(to: CGPoint(x: pr.maxX + 3.5 * u, y: y))
                ctx.fillPath()
            } else if st.look == .ink {
                // under the ink, as a highlighter marks a page: it never crosses a glyph of the line next to it
                ctx.saveGState()
                ctx.setBlendMode(.destinationOver)
                ctx.setFillColor(st.tint.cg.copy(alpha: st.tint.a * (req.faint ? 0.45 : 1)) ?? st.tint.cg)
                ctx.fill(pr.insetBy(dx: -1, dy: -0.5))
                ctx.restoreGState()
            } else {
                ctx.setStrokeColor(st.mark.cg.copy(alpha: st.mark.a * (req.faint ? 0.4 : 1)) ?? st.mark.cg)  // solid on a thread's first crop only
                ctx.setLineWidth(lw)
                ctx.stroke(pr.insetBy(dx: -lw, dy: -lw))
            }
        }
        return ctx.makeImage()
    }
}

/// A crop from the leading edge of the panel, with a placeholder of the same size while it is drawn. A figure's
/// (`CropLook.paper`) is the page as printed, in a hairline frame, at most `height` tall and the panel's width. A
/// formula's or a table's (`.ink`) is the page's ink on the card, at its print size up to 1.25× (UI audit 2026-10-21:
/// a table squeezed into 64 or 112 pt was too small to read), as wide as the card lets it, at one scale for all the
/// ink crops of a card (`widest`: the widest of their areas, so a formula is the same size in each round); one taller
/// than 220 pt as printed shows its first 112 pt with Show all (`fold`). A click runs `onTap`, else shows the area at
/// 2× as the PDF prints it, on its paper (the original of an ink crop). `ink`: the mark's colour, as Aqua resolves it
/// on paper and Dark Aqua on an ink crop in Dark Mode; `tint`: an ink crop's mark, under its ink (clear for none: a
/// box on the whole area, `CropCache.picksOut`). An ink crop has no plate, fill, frame or shadow of its own.
struct CropView: View {
    let request: CropRequest
    let ink: NSColor
    var tint: NSColor? = nil
    var height: CGFloat = 160
    var widest: CGFloat? = nil
    /// A tall ink crop shown whole, and the switch.
    var fold: (whole: Bool, toggle: () -> Void)? = nil
    var onTap: (() -> Void)?
    @State private var width: CGFloat = 0
    @State private var zoomed = false

    /// An ink crop's most scale (of its print size) and the print height above which it folds.
    static let most: CGFloat = 1.25
    static let tall: CGFloat = 220
    static let folded: CGFloat = 112

    var body: some View {
        let aspect = CropCache.aspect(request)
        let area = CropCache.area(request)?.size ?? .zero
        Group {
            if request.look == .ink, area.width > 0 {
                let tall = area.height > Self.tall
                let whole = fold?.whole ?? true
                VStack(alignment: .leading, spacing: 2) {
                    InkCropLayout(area: area, widest: max(widest ?? 0, area.width), cap: tall && !whole ? Self.folded : nil) {
                        picture
                    }
                    .clipped()
                    if tall, let fold {
                        Button(fold.whole ? "Show less" : "Show all") { fold.toggle() }
                            .buttonStyle(LinkStyle()).font(CardType.label)
                            .help(fold.whole ? "Show its first lines only" : "Show all of it, at the same size")
                    }
                }
            } else {
                picture
                    .aspectRatio(aspect, contentMode: .fit)
                    .frame(maxWidth: height * aspect)  // so at most `height` tall, and never letterboxed
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(Color.black.opacity(0.22), lineWidth: 0.5) }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if let onTap { onTap() } else if request.pdf != nil { zoomed = true } }
        .help(onTap != nil || request.pdf == nil ? ""
              : request.look == .ink ? "Click to see it larger, as printed" : "Click to see it larger")
        .popover(isPresented: $zoomed) {
            let w = min(area.width * 2, 900)
            CropPicture(request: request, look: .paper, ink: ink, tint: tint, width: w)
                .frame(width: w, height: w / max(aspect, 0.01))
                .padding(8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var picture: some View {
        CropPicture(request: request, look: request.look, ink: ink, tint: tint, width: width)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
    }
}

/// An ink crop's size: its area at the card's one scale (at most `CropView.most` of its print size, else the width
/// offered over the widest ink area of the card), its first `cap` points only when folded (the view clips the rest).
struct InkCropLayout: Layout {
    var area: CGSize
    var widest: CGFloat
    var cap: CGFloat?

    /// The scale for a card `width` wide.
    static func scale(width: CGFloat, widest: CGFloat) -> CGFloat {
        guard width.isFinite, width > 0, widest > 0 else { return 1 }
        return min(CropView.most, width / widest)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let s = Self.scale(width: proposal.width ?? widest, widest: widest)
        let h = area.height * s
        return CGSize(width: area.width * s, height: cap.map { min($0, h) } ?? h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let s = area.width > 0 ? bounds.width / area.width : 1
        for v in subviews {
            v.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: area.height * s))
        }
    }
}

/// A crop drawn for the width it is shown at: the image for that width from the cache at once, else the last one drawn
/// for it in this look, while it is drawn off the main thread at the screen's density for that width (sharp on a wide
/// card and on a Retina screen; a few pixels of width draw nothing again). An image drawn for another crop (the comment
/// re-anchored, another appearance) never stands in for this one, and a crop that cannot be drawn says so.
struct CropPicture: View {
    let request: CropRequest
    let look: CropLook
    let ink: NSColor
    var tint: NSColor?
    let width: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var screen
    @State private var drawn: (job: Job, image: NSImage)?
    @State private var failed: Job?

    private struct Job: Hashable {
        var request: CropRequest
        var style: CropStyle
    }

    var body: some View {
        let size = CropCache.area(request)?.size ?? .zero
        let style = CropStyle(look: look, dark: scheme == .dark, density: CropStyle.density(width: width, area: size, screen: screen),
                              screen: screen, ink: ink, tint: tint)
        let job = Job(request: request, style: style)
        // the last image this view drew stands in only for the same crop in the same look
        let own = drawn.flatMap { $0.job.request == request && $0.job.style.sameLook(style) ? $0.image : nil }
        let shown = CropCache.shared.cached(request, style) ?? CropCache.shared.any(request, style) ?? own
        let broke = failed == job || request.pdf == nil
        Group {
            if let shown, !broke {
                Image(nsImage: shown).resizable().interpolation(.high)
            } else {
                // an ink crop being drawn holds its place bare, as it will be: no grey plate flashes behind it
                Rectangle().fill(look == .ink && !broke ? Color.clear : Color.primary.opacity(0.05))
                    .overlay {
                        if broke {
                            Text("R\(request.round) PDF not available").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
            }
        }
        .task(id: job) {
            guard style.density > 0 else { return }  // until its width is known
            let img = await CropCache.shared.image(request, style).image
            if let img { drawn = (job, img) }
            failed = img == nil ? job : nil
        }
    }
}
