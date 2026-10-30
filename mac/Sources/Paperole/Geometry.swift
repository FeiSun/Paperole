import CoreGraphics
import PDFKit

/// Contract rects are [x0, y0, x1, y1] in points with the origin at the page's top-left (CONTRACT §3).
/// PDFKit page space has its origin at the bottom-left. `cropBox` is `page.bounds(for: .cropBox)`.
enum Geometry {
    static func pdfKitRect(_ r: [Double], cropBox cb: CGRect) -> CGRect? {
        guard r.count == 4 else { return nil }
        return CGRect(x: cb.minX + r[0], y: cb.maxY - r[3], width: r[2] - r[0], height: r[3] - r[1])
    }

    static func contractRect(_ r: CGRect, cropBox cb: CGRect) -> [Double] {
        let v: [CGFloat] = [r.minX - cb.minX, cb.maxY - r.maxY, r.maxX - cb.minX, cb.maxY - r.minY]
        return v.map { (Double($0) * 100).rounded() / 100 }
    }

    /// x (PDFKit page space) moved to the nearer edge of the page's text extent `textX` ([x0, x1], contract x,
    /// round.build.text_x) when it lies more than `tolerance` left or right of it; nil when it stays as it is.
    static func clampedX(_ x: CGFloat, textX t: [Double]?, cropBox cb: CGRect, tolerance: CGFloat = 1) -> CGFloat? {
        guard let t, t.count == 2, t[0] <= t[1] else { return nil }
        let x0 = cb.minX + t[0], x1 = cb.minX + t[1]
        if x < x0 - tolerance { return x0 }
        if x > x1 + tolerance { return x1 }
        return nil
    }

    /// A drag point (PDFKit page space) kept on the text of its row, from the bounds of the page's text lines
    /// (`lines(on:textX:)`).
    /// - The row is the line nearest the point among those whose middle lies within 6 pt of its height: first a line
    ///   over the point's x, then one of the column nearest the point (a line's column is it and the lines within 30 pt
    ///   of the point's height that overlap it horizontally), then the least vertical distance. Lines that share at
    ///   least half its height belong to the row too (two columns, a table row, an equation number).
    /// - Left of the row's first glyph the point moves just inside that glyph, and right of its last glyph just inside
    ///   that one, level with the middle of that glyph's line; over the row it stays. A point inside text_x stays too
    ///   when the nearest text above or below it at its x does not overlap the row horizontally: it lies over another
    ///   column (or a figure), so the row's line is not the text it is beside.
    /// - Without a row it is moved onto text_x as `clampedX` does, and without text_x it stays.
    static func clampedPoint(_ p: CGPoint, lines: [CGRect], textX: [Double]?, cropBox: CGRect) -> CGPoint {
        let near = lines.filter { abs($0.midY - p.y) <= 30 }
        func column(_ r: CGRect) -> CGRect { near.filter { $0.maxX > r.minX && $0.minX < r.maxX }.reduce(r) { $0.union($1) } }
        func dx(_ r: CGRect) -> CGFloat { max(r.minX - p.x, p.x - r.maxX, 0) }
        func dy(_ r: CGRect) -> CGFloat { max(r.minY - p.y, p.y - r.maxY, 0) }
        func key(_ r: CGRect) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
            // Rounded to 0.01 pt: unions of the same column differ by ~1e-13, which would skip the dy tie-break.
            (dx(r) > 0 ? 1 : 0, (dx(column(r)) * 100).rounded() / 100, dy(r), abs(r.midY - p.y))
        }
        let candidates = near.filter { abs($0.midY - p.y) <= 6 }
        guard let best = candidates.min(by: { key($0) < key($1) }) else {
            guard let x = clampedX(p.x, textX: textX, cropBox: cropBox) else { return p }
            return CGPoint(x: x, y: p.y)
        }
        let row = candidates.filter { min($0.maxY, best.maxY) - max($0.minY, best.minY) >= min($0.height, best.height) / 2 }
        let first = row.min(by: { $0.minX < $1.minX }) ?? best, last = row.max(by: { $0.maxX < $1.maxX }) ?? best
        if p.x >= first.minX && p.x <= last.maxX { return p }
        if clampedX(p.x, textX: textX, cropBox: cropBox) == nil,
           let over = lines.filter({ dx($0) == 0 }).min(by: { dy($0) < dy($1) }),
           over.maxX <= first.minX || over.minX >= last.maxX { return p }
        return p.x < first.minX ? CGPoint(x: first.minX + min(0.5, first.width / 2), y: first.midY)
                                : CGPoint(x: last.maxX - min(0.5, last.width / 2), y: last.midY)
    }

    /// A drag between the two columns of a page as two runs of text (PDFKit page space; `gap` is the x between the
    /// columns, from round.build.columns): from the point in the left column down to the end of its column's text,
    /// and from the start of the right column's text down to the point there. A column's text runs on while the space
    /// between its rows is less than a row's height, so a float, a heading or a footnote ends it: a sentence that
    /// goes on at the top of the next column under a figure leaves the figure out (PDFKit selects in content order,
    /// floats included). nil unless the points lie on different sides of the gap, each level with a row of its column.
    static func columnRuns(_ a: CGPoint, _ b: CGPoint, lines: [CGRect], gap: CGFloat) -> [(CGPoint, CGPoint)]? {
        guard (a.x < gap) != (b.x < gap) else { return nil }
        let (l, r) = a.x < gap ? (a, b) : (b, a)
        func rows(_ ls: [CGRect]) -> [CGRect] {  // lines sharing half their height merged, top first
            var out: [CGRect] = []
            for line in ls.sorted(by: { $0.midY > $1.midY }) {
                if let last = out.last, min(last.maxY, line.maxY) - max(last.minY, line.minY) >= min(last.height, line.height) / 2 {
                    out[out.count - 1] = last.union(line)
                } else {
                    out.append(line)
                }
            }
            return out
        }
        let left = rows(lines.filter { $0.maxX <= gap + 2 }), right = rows(lines.filter { $0.minX >= gap - 2 })
        func row(_ rs: [CGRect], _ p: CGPoint) -> Int? {
            rs.indices.filter { abs(rs[$0].midY - p.y) <= 6 }.min(by: { abs(rs[$0].midY - p.y) < abs(rs[$1].midY - p.y) })
        }
        guard var k = row(left, l), var j = row(right, r) else { return nil }
        while k + 1 < left.count && left[k].minY - left[k + 1].maxY < left[k].height { k += 1 }
        while j > 0 && right[j - 1].minY - right[j].maxY < right[j].height { j -= 1 }
        return [(l, CGPoint(x: left[k].maxX - min(0.5, left[k].width / 2), y: left[k].midY)),
                (CGPoint(x: right[j].minX + min(0.5, right[j].width / 2), y: right[j].midY), r)]
    }

    /// The bounds of a page's text lines within text_x (PDFKit page space), so without margin line numbers.
    static func lines(on page: PDFPage, textX t: [Double]?) -> [CGRect] {
        guard let t, t.count == 2, t[0] <= t[1] else { return [] }
        let cb = page.bounds(for: .cropBox)
        return (page.selection(for: CGRect(x: cb.minX + t[0], y: cb.minY, width: t[1] - t[0], height: cb.height))?
            .selectionsByLine() ?? []).map { $0.bounds(for: page) }.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
    }

    /// Where an id label goes beside a mark whose first line is `first` (PDFKit page space; UX.md §6): in the page
    /// margin on the mark's side, level with that line, never over text, a margin ruler's numbers (`ruler`: the bounds
    /// of the page's words outside text_x on that side) or another label (`placed`). Tried in turn, at each of `sizes`
    /// (the normal size first, then smaller type: MarkAnnotation.labelFonts): outside all of the page's text (`text`),
    /// between the body text (`textX`) and the ruler, and past the ruler at the page's edge; then a line below or above
    /// (labels of marks on one line). A position is pushed outwards past the labels it would cover. When nothing
    /// fits (a ruler at the page's edge close to the text), the normal label between the text and the ruler. `size`:
    /// the index in `sizes` of the one used.
    static func labelPlace(sizes: [CGSize], first: CGRect, text: CGRect, textX t: [Double]?,
                           ruler: CGRect?, cropBox cb: CGRect, placed: [CGRect]) -> (rect: CGRect, size: Int) {
        let left = first.midX < text.midX
        let tx = t.flatMap { $0.count == 2 && $0[0] <= $0[1] ? (cb.minX + CGFloat($0[0]), cb.minX + CGFloat($0[1])) : nil }
        func push(_ r: CGRect) -> CGRect {
            var r = r
            while let hit = placed.first(where: { $0.insetBy(dx: -1, dy: 0).intersects(r) }) {
                r.origin.x = left ? hit.minX - 2 - r.width : hit.maxX + 2
            }
            return r
        }
        func free(_ r: CGRect) -> Bool {
            r.minX >= cb.minX + 1 && r.maxX <= cb.maxX - 1 && !(ruler?.insetBy(dx: -1, dy: -1).intersects(r) ?? false)
        }
        func xs(_ w: CGFloat) -> [CGFloat] {
            var out = [left ? text.minX - 5 - w : text.maxX + 5]
            if let tx { out.append(left ? tx.0 - 7 - w : tx.1 + 7) }  // 2 pt clear of a reading bar (Reading.bar)
            if let ruler { out.append(left ? ruler.minX - 2 - w : ruler.maxX + 2) }
            return out
        }
        for dy in [0, -1, 1] as [CGFloat] {
            for (i, size) in sizes.enumerated() {
                let y = first.midY - size.height / 2 + dy * (size.height + 1)
                for x in xs(size.width) {
                    let r = push(CGRect(x: x, y: y, width: size.width, height: size.height))
                    if free(r) { return (r, i) }
                }
            }
        }
        let normal = sizes[0]
        let w = normal.width, x = tx.map { left ? $0.0 - 7 - w : $0.1 + 7 } ?? (left ? text.minX - 5 - w : text.maxX + 5)
        return (push(CGRect(x: x, y: first.midY - normal.height / 2, width: w, height: normal.height)), 0)
    }

    /// `clampedPoint` with the text lines of the page (about 0.2 ms a page).
    static func clampedPoint(_ p: CGPoint, on page: PDFPage, textX: [Double]?) -> CGPoint {
        clampedPoint(p, lines: lines(on: page, textX: textX), textX: textX, cropBox: page.bounds(for: .cropBox))
    }
}
