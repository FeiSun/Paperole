import AppKit
import PDFKit
import SwiftUI

/// The Finish sheet's preview of final.pdf (design/summary-page): the document Finish would write, at the box's width,
/// scrolling through the summary and the paper. On a summary page, the row under the pointer is tinted, and a click on
/// it shows that comment (the sheet closes); elsewhere a click acts as in any PDF (a page of the strip goes there).
struct FinalPreviewView: NSViewRepresentable {
    let document: PDFDocument
    /// The comment ids a click may show (the round's).
    let ids: Set<String>
    let pick: (String) -> Void

    func makeNSView(context: Context) -> PreviewPDFView {
        let v = PreviewPDFView()
        v.displayMode = .singlePageContinuous
        v.displaysPageBreaks = true
        v.pageShadowsEnabled = false
        v.backgroundColor = .white  // the pages are white in both appearances, as final.pdf is
        v.document = document
        v.ids = ids
        v.pick = pick
        return v
    }

    func updateNSView(_ v: PreviewPDFView, context: Context) {
        v.ids = ids
        v.pick = pick
        if v.document !== document {
            // a newer preview keeps the place read: its page's index, taken before the old document goes
            let at = v.currentDestination
            let index = at?.page.flatMap { v.document?.index(for: $0) }
            v.document = document
            v.fitWidth()
            if let at, let index, index < document.pageCount, let same = document.page(at: index) {
                v.go(to: PDFDestination(page: same, at: at.point))
            }
        }
    }
}

final class PreviewPDFView: PDFView {
    var ids: Set<String> = []
    var pick: ((String) -> Void)?
    /// The ids each summary page shows and where (its index → [(id, bounds)]), found once per document.
    private var chips: [Int: [(id: String, rect: CGRect)]] = [:]
    override var document: PDFDocument? { didSet { chips = [:] } }
    /// Whether a page is a summary page: final.pdf labels them "Summary" (or "Summary 2", …).
    var isSummary: (PDFPage) -> Bool = { ($0.label ?? "").hasPrefix("Summary") }
    private var hover: NSTrackingArea?

    /// No size of its own: the box's (PDFView's would be its document's, and SwiftUI would lay it out wider than the
    /// box, the page centred off its middle).
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    /// The pages at the box's width (PDFView's own autoScales fits a whole page in, too small to read), again when the
    /// box's width changes.
    override func layout() {
        super.layout()
        fitWidth()
    }

    /// The summary page at the box's width; the paper's pages are wider (their review margin) and PDFKit centres every
    /// page in the widest one's width, so the summary is then scrolled to the box's left edge. The paper's pages
    /// scroll sideways.
    func fitWidth() {
        guard let page = document?.page(at: 0), bounds.width > 40 else { return }
        let want = (bounds.width - 16) / page.bounds(for: displayBox).width
        autoScales = false
        guard abs(scaleFactor - want) > 0.005 else { return }
        scaleFactor = want
        layoutDocumentView()
        if let doc = documentView {
            let r = doc.convert(convert(page.bounds(for: displayBox), from: page), from: self)
            doc.scroll(NSPoint(x: max(0, r.minX - 8), y: doc.visibleRect.minY))
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hover { removeTrackingArea(hover) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        hover = t
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let hit = row(at: convert(event.locationInWindow, from: nil))
        highlightedSelections = hit.map { [$0.line] }
        if hit != nil { NSCursor.pointingHand.set() }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        highlightedSelections = nil
    }

    override func mouseDown(with event: NSEvent) {
        if let hit = row(at: convert(event.locationInWindow, from: nil)) {
            pick?(hit.id)
            return
        }
        super.mouseDown(with: event)
    }

    /// The debug script's click at a point of page `index` (PDF points from the page's top left): the page is scrolled
    /// there, and the click acts as the mouse's would. The id it showed, or nil.
    func click(page index: Int, x: CGFloat, y: CGFloat) -> String? {
        guard let page = document?.page(at: index) else { return nil }
        let box = page.bounds(for: displayBox)
        let at = CGPoint(x: box.minX + x, y: box.maxY - y)
        go(to: PDFDestination(page: page, at: CGPoint(x: 0, y: min(box.maxY, at.y + 120))))
        layoutDocumentView()
        guard let hit = row(at: convert(at, from: page)) else { return nil }
        pick?(hit.id)
        return hit.id
    }

    /// The comment a point of a summary page names: the id under it (a chip), else the id a row starts with. The
    /// reply rule's example ("% R1-03 your note") names none.
    private func row(at point: NSPoint) -> (id: String, line: PDFSelection)? {
        guard let page = page(for: point, nearest: false), isSummary(page), let doc = document else { return nil }
        let p = convert(point, to: page)
        guard let line = page.selectionForLine(at: p), let text = line.string,
              line.bounds(for: page).insetBy(dx: -2, dy: -3).contains(p), !text.contains("your note") else { return nil }
        let i = doc.index(for: page)
        if chips[i] == nil { chips[i] = Self.chips(on: page, of: doc) }
        if let hit = chips[i]?.first(where: { ids.contains($0.id) && $0.rect.insetBy(dx: -3, dy: -3).contains(p) }) {
            return (hit.id, tinted(line))
        }
        let lead = text.trimmingCharacters(in: CharacterSet(charactersIn: "+–- \u{00a0}"))
        guard let first = Self.ids(in: lead).first, lead.hasPrefix(first), ids.contains(first) else { return nil }
        return (first, tinted(line))
    }

    /// Where a page shows each id: each found once, searched from the document's start onwards until past this page
    /// (the summary pages come first, so a search stops early; PDFKit's own words break at the hyphen).
    static func chips(on page: PDFPage, of doc: PDFDocument) -> [(id: String, rect: CGRect)] {
        let here = doc.index(for: page)
        var out: [(id: String, rect: CGRect)] = []
        for id in Set(ids(in: page.string ?? "")) {
            var from: PDFSelection?
            while let found = doc.findString(id, fromSelection: from, withOptions: []),
                  let p = found.pages.first, doc.index(for: p) <= here {
                if p == page { out.append((id, found.bounds(for: page))) }
                from = found
            }
        }
        return out
    }

    private func tinted(_ s: PDFSelection) -> PDFSelection {
        s.color = NSColor(hex: Palette.sage.light).withAlphaComponent(0.22)  // the page is white in both appearances
        return s
    }

    /// A comment id, as the ledger writes it (ledger.new_id: "R1-05", "R12-104").
    static let pattern = try! NSRegularExpression(pattern: #"\bR\d+-\d{2,}\b"#)

    /// The comment ids in a text ("R1-05"), in order.
    static func ids(in text: String) -> [String] {
        pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }
}
