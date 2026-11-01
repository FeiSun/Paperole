import AppKit
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Page thumbnails of the rounds' PDFs (OVERVIEW-v2 §3.3, FEATURES OV-3): the overview's page strip and a paper's key
/// page (`MapRules.keyPage`). Each is drawn once, off the main thread, from the round's build PDF with CoreGraphics
/// (read only: the engine is the only writer of PDFs), and kept as a PNG under a folder named by a hash of the paper's
/// path, so Remove from List clears it (`clear(paper:)`); a file's name has a hash of its PDF's path, size and date, so
/// a PDF built again is drawn again. The app's caches folder (AppVariant: Paperole Dev's own in the dev app), or for a
/// test run (--background, a fixture) a temporary folder of its own unless --cache names one.
@MainActor
final class ThumbnailStore: ObservableObject {
    let root: URL
    /// Bumped when a thumbnail arrives, so the views that showed a frame for it ask again.
    @Published private(set) var arrived = 0
    private var images: [String: NSImage] = [:]
    private var asked: Set<String> = []
    private var stamps: [String: String] = [:]
    private var firsts: [String: CGSize] = [:]
    private var sizes: [String: [Int: CGSize]] = [:]
    private let queue = DispatchQueue(label: "Paperole.thumbnails", qos: .utility)
    /// The images kept in memory: past it they all go, and are read from the folder again when shown.
    let capacity: Int
    /// The images in memory now.
    var count: Int { images.count }

    init(root: URL, capacity: Int = 600) {
        self.root = root
        self.capacity = capacity
    }

    static var standardRoot: URL { AppVariant.current.cachesFolder.appendingPathComponent("Thumbnails") }

    /// The pixel heights drawn: one for the strip (72 pt at 2×, a little more), one for a key page.
    static func pixels(for height: CGFloat) -> Int { height <= 80 ? 160 : 400 }

    nonisolated static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    func folder(paper: String) -> URL { root.appendingPathComponent(Self.hash(paper), isDirectory: true) }

    /// The PDF's path, size and modification date: a PDF built again gets new thumbnails.
    private func stamp(_ pdf: String) -> String? {
        if let s = stamps[pdf] { return s }
        guard let a = try? FileManager.default.attributesOfItem(atPath: pdf) else { return nil }
        let date = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let s = Self.hash("\(pdf)|\(a[.size] as? Int ?? 0)|\(date)")
        stamps[pdf] = s
        return s
    }

    /// New data for the overview: the PDFs are looked at again (a round may have been built again).
    func refresh() {
        stamps = [:]
        firsts = [:]
        sizes = [:]
    }

    /// A page's width over its height (its crop box, turned as it is shown); 8.5 × 11 when it cannot be read.
    func aspect(pdf: String?) -> CGFloat {
        let s = firstPage(pdf: pdf)
        return s.width / s.height
    }

    /// The first page's size in points (its crop box, turned as it is shown); US Letter when it cannot be read.
    func firstPage(pdf: String?) -> CGSize {
        guard let pdf else { return StripGeometry.letter }
        if let s = firsts[pdf] { return s }
        var s = StripGeometry.letter
        if let doc = CGPDFDocument(URL(fileURLWithPath: pdf) as CFURL), let page = doc.page(at: 1) {
            let b = page.getBoxRect(.cropBox), turned = page.rotationAngle % 180 != 0
            if b.width > 0, b.height > 0 { s = turned ? CGSize(width: b.height, height: b.width) : b.size }
        }
        firsts[pdf] = s
        return s
    }

    /// The strip's thumbnail size for the round's PDF (`StripGeometry.thumbSize` of its first page).
    func thumbSize(pdf: String?) -> CGSize { StripGeometry.thumbSize(page: firstPage(pdf: pdf)) }

    /// A page's crop box size in points (the marks' space), as the thumbnail shows it.
    func pageSize(pdf: String?, page: Int) -> CGSize? {
        guard let pdf else { return nil }
        if let s = sizes[pdf]?[page] { return s }
        guard let doc = CGPDFDocument(URL(fileURLWithPath: pdf) as CFURL) else { return nil }
        var all: [Int: CGSize] = [:]
        for i in 0..<doc.numberOfPages {
            guard let p = doc.page(at: i + 1) else { continue }
            let b = p.getBoxRect(.cropBox)
            all[i] = p.rotationAngle % 180 != 0 ? CGSize(width: b.height, height: b.width) : b.size
        }
        sizes[pdf] = all
        return all[page]
    }

    /// The thumbnail of page `page` (0-based) of `pdf`, if it is drawn; else nil, and it is drawn (or read from the
    /// folder) off the main thread, and `arrived` changes when it is there.
    func image(paper: String, pdf: String?, page: Int, height: CGFloat) -> NSImage? {
        guard let pdf, let stamp = stamp(pdf) else { return nil }
        let px = Self.pixels(for: height)
        let key = "\(stamp)-p\(page)-\(px)"
        if let im = images[key] { return im }
        guard !asked.contains(key) else { return nil }
        asked.insert(key)
        let file = folder(paper: paper).appendingPathComponent(key + ".png")
        queue.async { [weak self] in
            let image = Self.load(file) ?? Self.render(pdf: pdf, page: page, pixels: px).map { im -> CGImage in
                Self.save(im, to: file)
                return im
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if let image {
                    self.images[key] = NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2))
                    if self.images.count > self.capacity {
                        // no longer asked for either, or a page shown before stayed blank until relaunch (the code audit)
                        self.asked.subtract(self.images.keys)
                        self.images.removeAll()
                    }
                }
                self.arrived += 1
            }
        }
        return nil
    }

    /// Remove from List: the paper's thumbnails go (memory and folder).
    func clear(paper: String) {
        images.removeAll()
        asked.removeAll()
        let dir = folder(paper: paper)
        queue.async { try? FileManager.default.removeItem(at: dir) }
    }

    /// Settings › Data & Storage › Clear: every thumbnail goes (memory and folder), after those being drawn are
    /// written; the views shown ask again and draw theirs anew.
    func clearAll(done: @escaping () -> Void) {
        images.removeAll()
        asked.removeAll()
        refresh()
        let root = self.root
        queue.async {
            try? FileManager.default.removeItem(at: root)
            DispatchQueue.main.async { [weak self] in
                self?.images.removeAll()
                self?.asked.removeAll()
                self?.arrived += 1
                done()
            }
        }
    }

    /// Waits until the thumbnails asked for so far are written (tests).
    func flush() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in queue.async { c.resume() } }
    }

    nonisolated private static func load(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    nonisolated private static func save(_ image: CGImage, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).png")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        if CGImageDestinationFinalize(dest) {
            _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
        }
        try? FileManager.default.removeItem(at: tmp)
    }

    /// Draws a page `pixels` high on white (pages are white in either appearance).
    nonisolated static func render(pdf: String, page: Int, pixels: Int) -> CGImage? {
        guard let doc = CGPDFDocument(URL(fileURLWithPath: pdf) as CFURL), let p = doc.page(at: page + 1) else { return nil }
        let box = p.getBoxRect(.cropBox), turned = p.rotationAngle % 180 != 0
        let size = turned ? CGSize(width: box.height, height: box.width) : box.size
        guard size.width > 0, size.height > 0 else { return nil }
        let h = pixels, w = max(1, Int((CGFloat(pixels) * size.width / size.height).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(rect)
        ctx.interpolationQuality = .high
        ctx.concatenate(p.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(p)
        return ctx.makeImage()
    }
}
