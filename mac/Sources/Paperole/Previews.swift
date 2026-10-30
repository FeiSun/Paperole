import AppKit
import PDFKit
import SwiftUI

/// A round's link table (`rN/links.json`, the engine's read-only `links`; CONTRACT amendment "Reference previews"): the
/// links of its build PDF, hyperref's and those the engine found in the source ("??" too), and what each points to.
/// Pages are 0-based into the round's build PDF, rects contract coordinates (top-left).
struct LinkTable: Decodable, Equatable {
    struct Link: Decodable, Equatable {
        var page: Int
        var rects: [[Double]]
        var text: String
        var kind: String
        /// Indices into `targets`, the clicked one first (a `\cite{a,b,c}`'s others after it).
        var targets: [Int]
        var via: String

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            page = try c.decode(Int.self, forKey: .page)
            rects = (try c.decodeIfPresent([[Double]].self, forKey: .rects) ?? []).filter { $0.count == 4 }
            text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
            kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "other"
            targets = try c.decodeIfPresent([Int].self, forKey: .targets) ?? []
            via = try c.decodeIfPresent(String.self, forKey: .via) ?? "pdf"
        }

        private enum CodingKeys: String, CodingKey { case page, rects, text, kind, targets, via }
    }

    struct Target: Decodable, Equatable {
        var kind: String
        var label: String
        var key: String?
        var page: Int?
        var box: [Double]?
        var parts: [PageRect]
        var url: String?
        var note: String?
        /// The pages of the links that cite it, sorted, and their number.
        var cited: [Int]
        var count: Int

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "other"
            label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
            key = try c.decodeIfPresent(String.self, forKey: .key)
            page = try c.decodeIfPresent(Int.self, forKey: .page)
            box = try c.decodeIfPresent([Double].self, forKey: .box)
            parts = (try c.decodeIfPresent([PageRect].self, forKey: .parts) ?? []).filter(\.valid)
            url = try c.decodeIfPresent(String.self, forKey: .url)
            note = try c.decodeIfPresent(String.self, forKey: .note)
            cited = try c.decodeIfPresent([Int].self, forKey: .cited) ?? []
            count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 0
        }

        private enum CodingKeys: String, CodingKey { case kind, label, key, page, box, parts, url, note, cited, count }

        /// Where it is printed: its first part (a table across pages has more); nil for a URL or a missing target.
        var place: PageRect? {
            guard let page, page >= 0, let b = box, b.count == 4, b[2] > b[0], b[3] > b[1] else { return nil }
            return PageRect(page: page, rect: b)
        }

        /// The preview's title: "Figure 3 · p.7"; a URL's "Link" (its address is under it).
        var title: String { kind == "url" ? "Link" : place.map { "\(label) · p.\($0.page + 1)" } ?? label }

        /// A URL's address when it is one the app opens (the engine keeps only these; checked again here).
        var openable: URL? { url.flatMap(URL.init(string:)).flatMap { LinkTable.opens($0) ? $0 : nil } }
    }

    /// Whether the app opens a URL: http, https and mailto only (a PDF's link to a file or an app is not).
    static func opens(_ u: URL) -> Bool { ["http", "https", "mailto"].contains(u.scheme?.lowercased() ?? "") }

    var round: Int
    var hyperref: Bool
    var links: [Link]
    var targets: [Target]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        round = try c.decode(Int.self, forKey: .round)
        hyperref = try c.decodeIfPresent(Bool.self, forKey: .hyperref) ?? false
        targets = try c.decode([Target].self, forKey: .targets)
        // a link pointing at no target is left out; sorted by page for `onPage` (the engine sorts them so already)
        let n = targets.count
        links = try c.decode([Link].self, forKey: .links)
            .filter { !$0.rects.isEmpty && !$0.targets.isEmpty && $0.targets.allSatisfy { $0 >= 0 && $0 < n } }
            .enumerated().sorted { ($0.element.page, $0.offset) < ($1.element.page, $1.offset) }.map(\.element)
    }

    private enum CodingKeys: String, CodingKey { case round, hyperref, links, targets }

    /// The links of a page, as indices.
    func onPage(_ page: Int) -> Range<Int> {
        var lo = 0, hi = links.count
        while lo < hi { let m = (lo + hi) / 2; if links[m].page < page { lo = m + 1 } else { hi = m } }
        var end = lo
        while end < links.count && links[end].page == page { end += 1 }
        return lo..<end
    }

    /// The link whose words hold a point of a page (contract coordinates), 1 pt round them.
    func link(page: Int, x: Double, y: Double) -> Int? {
        onPage(page).first { i in
            links[i].rects.contains { $0[0] - 1 <= x && x <= $0[2] + 1 && $0[1] - 1 <= y && y <= $0[3] + 1 }
        }
    }

    /// The links of a page that cite a target, as the engine counts them: a hyperref link its own target, one the
    /// engine found in the source each of its keys.
    func citing(_ target: Int, on page: Int) -> [Int] {
        onPage(page).filter { i in links[i].via == "pdf" ? links[i].targets.first == target : links[i].targets.contains(target) }
    }

    /// Whether a click on the link previews it: one whose target has a place, a missing one, and a URL the app opens
    /// (the PDF's own or one the engine found in the source: its address first, the browser on a second click). Any
    /// other goes there as without the table.
    func previews(_ i: Int) -> Bool {
        let t = targets[links[i].targets[0]]
        switch t.kind {
        case "url": return t.openable != nil
        case "missing": return true
        default: return t.place != nil
        }
    }
}

/// The engine's `links` reply (no state).
struct LinksReply: Decodable {
    var table: LinkTable?
}

/// What a reference preview shows (design/pdf-reader/PLAN.md §4.2), made by `PDFController.makePreview`.
struct LinkPreview: Equatable {
    /// A target as printed: its crop of the round's build PDF on white paper, with no mark drawn.
    struct Entry: Equatable, Identifiable {
        var id: Int  // the target's index
        var label: String
        var request: CropRequest
        var area: CGSize  // on the page, in points
        var size: CGSize = .zero  // as shown (`PreviewLayout.scale`)
    }

    var link: Int?
    var target: Int
    var kind: String
    var title: String
    /// The clicked target, then a citation's other entries.
    var entries: [Entry]
    /// The page of the target's next part (a table across pages).
    var continues: Int?
    var cited: [Int]
    var count: Int
    var note: String?
    var address: String?
    var url: URL?
    /// The clicked entry's words, for Copy Reference.
    var reference: String?
    var canComment = false

    var canGo: Bool { !entries.isEmpty }
    /// Copy Reference only for words found in the entry's box: an empty copy would wipe the clipboard.
    var canCopy: Bool { !(reference ?? "").isEmpty }

    /// The kinds whose preview says where they are cited (a figure's pages, a formula's).
    static let citedOn: Set<String> = ["figure", "table", "algorithm", "equation"]

    /// The words under the footer's line, for the debug items and the tests.
    var footer: String {
        switch kind {
        case "cite": return [cited.isEmpty ? nil : "Cited \(count)×: " + pages, canCopy ? "Copy Reference" : nil]
            .compactMap { $0 }.joined(separator: " · ")
        case "url": return (address ?? "") + " · Open in Browser · Copy Link"
        case "missing": return (note ?? "") + (canComment ? " · Comment…" : "")
        default: return Self.citedOn.contains(kind) && !cited.isEmpty ? "Cited on " + pages : ""
        }
    }

    private var pages: String { cited.map { "p.\($0 + 1)" }.joined(separator: " · ") }
}

/// Where a preview goes and how large its pictures are (PLAN §4.2): above or below the link, never over its line; the
/// page's scale up to 1.5×, within 90% of the PDF view's width and 70% of the window's height (and the room on that
/// side), a larger target scaled to fit. Its words are kept within that width too (`AtMost`); their height is measured
/// (`PDFController.layout`).
enum PreviewLayout {
    static let most: CGFloat = 1.5
    static let gap: CGFloat = 6  // between the link's line and the preview
    static let margin: CGFloat = 8  // kept inside the PDF view
    static let spacing: CGFloat = 6  // between the pictures (the preview's VStack)
    static let padding: CGFloat = 10  // round the preview's content
    static let minWidth: CGFloat = 220
    /// The preview's widest: 90% of the PDF view's width.
    static func maxWidth(view: CGFloat) -> CGFloat { max(0.9 * view, minWidth) }

    /// The pictures' one scale: the page's, at most 1.5×, smaller when the widest or all of them stacked would not fit
    /// `width` × `height`.
    static func scale(_ areas: [CGSize], page: CGFloat, width: CGFloat, height: CGFloat) -> CGFloat {
        let w = areas.map(\.width).max() ?? 0, h = areas.map(\.height).reduce(0, +)
        var s = min(max(page, 0.1), most)
        if w > 0 { s = min(s, width / w) }
        if h > 0 { s = min(s, (height - spacing * CGFloat(max(areas.count - 1, 0))) / h) }
        return max(s, 0.05)
    }

    /// The room above and below the link's line (view coordinates, y up) in a view of `bounds`.
    static func room(line: CGRect, bounds: CGRect) -> (above: CGFloat, below: CGFloat) {
        (bounds.maxY - margin - (line.maxY + gap), line.minY - gap - (bounds.minY + margin))
    }

    /// Above when a preview `height` tall fits there, else below when it fits there, else the side with more room.
    static func above(height: CGFloat, line: CGRect, bounds: CGRect) -> Bool {
        let r = room(line: line, bounds: bounds)
        return r.above >= height || (r.below < height && r.above >= r.below)
    }

    /// The preview's origin: `gap` above or below the line, centred on it and kept `margin` inside the view across.
    static func origin(size: CGSize, line: CGRect, bounds: CGRect, above: Bool) -> CGPoint {
        let x = min(max(line.midX - size.width / 2, bounds.minX + margin), bounds.maxX - margin - size.width)
        return CGPoint(x: max(x, bounds.minX), y: above ? line.maxY + gap : line.minY - gap - size.height)
    }
}

/// What the preview's buttons do (`PDFController`).
@MainActor
struct PreviewActions {
    weak var controller: PDFController?
    func go(_ target: Int) { controller?.goToTarget(target) }
    func pin() { controller?.pinPreview() }
    func cited(_ page: Int) { controller?.goCited(page) }
    func copyReference() { controller?.copyReference() }
    func open() { controller?.openPreviewURL() }
    func copyLink() { controller?.copyPreviewURL() }
    func comment() { controller?.commentOnPreviewLink() }
    func drag(_ t: CGSize, ended: Bool) { controller?.dragPreview(t, ended: ended) }
}

/// The reference preview over the PDF (PLAN §4.2): its title, the pin and Go to ›, the target as printed, and what
/// its kind says under it. A click on a picture goes there; dragging the title row away keeps it open (§4.3).
struct LinkPreviewView: View {
    let preview: LinkPreview
    let actions: PreviewActions
    /// `PreviewLayout.maxWidth`: a long title is cut short and a long "Cited" row wraps within it.
    let maxWidth: CGFloat

    var body: some View {
        AtMost(width: maxWidth - 2 * PreviewLayout.padding) { content }
            .padding(PreviewLayout.padding)
            .frame(minWidth: PreviewLayout.minWidth, alignment: .leading)
            .fixedSize()
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: PreviewLayout.spacing) {
            HStack(spacing: 10) {
                Text(preview.title).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 12)
                if preview.canGo {
                    Button { actions.pin() } label: { Image(systemName: "pin").font(.system(size: 11)) }
                        .buttonStyle(.borderless).help("Keep Open in a small window")
                    Button("Go to ›") { actions.go(preview.target) }.buttonStyle(LinkStyle()).font(CardType.label)
                        .help("Go to \(preview.entries.first?.label ?? "it") (a click on the picture too)")
                }
            }
            .frame(height: 18)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { actions.drag($0.translation, ended: false) }
                .onEnded { actions.drag($0.translation, ended: true) })
            ForEach(preview.entries) { e in
                PreviewPicture(entry: e).onTapGesture { actions.go(e.id) }.help("Go to \(e.label)")
            }
            if let c = preview.continues { Text("continues on p.\(c + 1)").font(.system(size: 11)).foregroundStyle(.secondary) }
            footer.font(.system(size: 11))
        }
    }

    @ViewBuilder private var footer: some View {
        switch preview.kind {
        case "cite":
            HStack(alignment: .top, spacing: 4) {
                if !preview.cited.isEmpty {
                    Text("Cited \(preview.count)×:").foregroundStyle(.secondary)
                    pages
                }
                Spacer(minLength: 12)
                if preview.canCopy { Button("Copy Reference") { actions.copyReference() }.buttonStyle(LinkStyle()) }
            }
        case "url":
            VStack(alignment: .leading, spacing: 4) {
                Text(preview.address ?? "").lineLimit(1).truncationMode(.middle).frame(maxWidth: 360, alignment: .leading)
                    .textSelection(.enabled)
                if preview.url != nil {
                    HStack(spacing: 12) {
                        Button("Open in Browser") { actions.open() }.buttonStyle(LinkStyle())
                        Button("Copy Link") { actions.copyLink() }.buttonStyle(LinkStyle())
                    }
                }
            }
        case "missing":
            VStack(alignment: .leading, spacing: 4) {
                Text(preview.note ?? "").foregroundStyle(.secondary)
                if preview.canComment { Button("Comment…") { actions.comment() }.buttonStyle(LinkStyle()) }
            }
        default:
            if LinkPreview.citedOn.contains(preview.kind), !preview.cited.isEmpty {
                HStack(alignment: .top, spacing: 4) {
                    Text("Cited on").foregroundStyle(.secondary)
                    pages
                }
            }
        }
    }

    /// Each page a link that goes there (a step of Back), in rows that fit the preview's width beside the row's words.
    private var pages: some View {
        let per = max(Int((maxWidth - 2 * PreviewLayout.padding - 190) / 40), 1), all = preview.cited
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(stride(from: 0, to: all.count, by: per)), id: \.self) { start in
                HStack(spacing: 4) {
                    ForEach(start..<min(start + per, all.count), id: \.self) { i in
                        if i > start { Text("·").foregroundStyle(.tertiary) }
                        Button("p.\(all[i] + 1)") { actions.cited(all[i]) }.buttonStyle(LinkStyle())
                            .help("Go to its citation on p.\(all[i] + 1)")
                    }
                }
            }
        }
    }
}

/// Its content at its own size, or `width` wide when that is wider (a long title then cut short, words wrapped): a
/// width SwiftUI's frame(maxWidth:) gives only when the view is placed, not when its size is measured.
struct AtMost: Layout {
    var width: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let s = subviews.first else { return .zero }
        let own = s.sizeThatFits(.unspecified)
        return own.width <= width ? own : s.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// A target as printed, on white paper in a hairline frame, at its size.
private struct PreviewPicture: View {
    let entry: LinkPreview.Entry

    var body: some View {
        CropPicture(request: entry.request, look: .paper, ink: .clear, width: entry.size.width)
            .frame(width: entry.size.width, height: entry.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .overlay { RoundedRectangle(cornerRadius: 2).strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5) }
            .contentShape(Rectangle())
    }
}

/// A preview kept open (PLAN §4.3): a small resizable window of the picture, scaled to fit, and Go to ›. It closes
/// with the paper or round and is never saved.
struct PinnedPreviewView: View {
    let entry: LinkPreview.Entry
    let go: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { g in
                let aspect = entry.area.width / max(entry.area.height, 1)
                let w = max(min(g.size.width, g.size.height * aspect), 1)
                CropPicture(request: entry.request, look: .paper, ink: .clear, width: w)
                    .frame(width: w, height: w / aspect)
                    .overlay { Rectangle().strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5) }
                    .contentShape(Rectangle())
                    .onTapGesture(perform: go)
                    .help("Go to \(entry.label)")
                    .frame(width: g.size.width, height: g.size.height)
            }
            HStack {
                Spacer()
                Button("Go to ›", action: go).buttonStyle(LinkStyle()).font(CardType.label)
            }
        }
        .padding(8)
    }

    /// The window's content size for a picture shown at `size`.
    static func content(_ size: CGSize) -> CGSize { CGSize(width: size.width + 16, height: size.height + 16 + 6 + 16) }
}
