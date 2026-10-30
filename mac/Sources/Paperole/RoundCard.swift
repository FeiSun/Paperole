import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The round card (design/stats-card, the "Ledger" card; request of 2026-10-26): what a round's comments came to, a
// card that feels like work done and exports as an image. Its numbers are RoundStats (RoundStats.swift). Shown
// compactly in the Finish sheet while the round is open, then whole in the Summary sheet: right after Finish Round, and
// later for any finished round (the round menu, the overview's More, Jump).

// MARK: Tokens

/// The card's colours (design/stats-card, the spec's table): a warm paper and page; the brand's vermilion only for
/// the advisor's marks, the ring, ¶ and ★ (never for words); the words in the palette's label colours. The paper is a
/// brand surface, apart from the app's surfaces of almost no hue (DesignPaletteTests).
enum CardPalette {
    static let paper = NSColor(light: 0xF7F3EA, dark: 0x1D1E1C)
    static let page = NSColor(light: 0xFFFDF8, dark: 0x282926)
    static let vermilion = NSColor(light: 0xC04734, dark: 0xDB6A50)
    /// The ink at 14%, 9% and 12% (white at 10%, 7.5% and 11% in Dark Mode): a page's hairline, the lines of text
    /// drawn as texture on the pages, the rule under the header.
    static let pageLine = ink(0.14, 0.10)
    static let texture = ink(0.09, 0.075)
    static let rule = ink(0.12, 0.11)

    private static func ink(_ light: CGFloat, _ dark: CGFloat) -> NSColor {
        Palette.pair(NSColor(hex: 0x1F2621).withAlphaComponent(light), NSColor(white: 1, alpha: dark))
    }
}

/// The tokens resolved for one appearance, so the card is drawn the same in the sheet and in the image ImageRenderer
/// makes of it, whatever appearance the renderer has.
struct CardTheme {
    let paper, page, pageLine, texture, rule, red, ink, ink2, secondary: Color

    init(dark: Bool) {
        func c(_ n: NSColor) -> Color {
            var out = n
            NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
                out = n.usingColorSpace(.sRGB) ?? n
            }
            return Color(nsColor: out)
        }
        paper = c(CardPalette.paper)
        page = c(CardPalette.page)
        pageLine = c(CardPalette.pageLine)
        texture = c(CardPalette.texture)
        rule = c(CardPalette.rule)
        red = c(CardPalette.vermilion)
        ink = c(Palette.label)
        ink2 = c(Palette.label2)
        secondary = c(Palette.secondary)
    }
}

// MARK: The ring

/// The brand's brushed ring (design/logo/final/round-mark.svg: one polygon of M and Z commands, viewBox 216 214 612
/// 572), the icon's round, with the round's numeral inside on the card.
struct RoundRing: Shape {
    static let viewBox = CGRect(x: 216, y: 214, width: 612, height: 572)
    /// Height over width.
    static let aspect = viewBox.height / viewBox.width

    private static let outlines: [[CGPoint]] = {
        var out: [[CGPoint]] = []
        for part in path.split(separator: "M") {
            let nums = part.replacingOccurrences(of: "Z", with: " ").split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
            let points = stride(from: 0, to: nums.count - 1, by: 2).map { CGPoint(x: nums[$0], y: nums[$0 + 1]) }
            if points.count > 2 { out.append(points) }
        }
        return out
    }()

    func path(in rect: CGRect) -> Path {
        let vb = Self.viewBox
        let s = min(rect.width / vb.width, rect.height / vb.height)
        var p = Path()
        for poly in Self.outlines {
            p.addLines(poly.map { CGPoint(x: rect.minX + ($0.x - vb.minX) * s, y: rect.minY + ($0.y - vb.minY) * s) })
            p.closeSubpath()
        }
        return p
    }

    private static let path = """
        M507 750.8 490.2 750.9 488 750.6 481 750.6 474.5 750.1 471.5 750.1 465.2 749.4 462.2 749.3 443.5 747.3 425.5
        744.4 416 742.5 411.5 741.3 405.8 740 389.5 735.4 379.2 732 370.2 728.4 357 722.7 344 715.9 332 708.9 319.8
        700.8 315.2 697.3 303.5 687.9 296.1 681.2 289.2 674.6 284 669.1 274.5 658.3 265 646.2 256.8 633.9 251.2 624.8
        247.9 618.8 239.8 602.2 237.5 596.8 232.3 582 229.3 571.8 225.6 556.8 224.7 552.2 223.2 541.8 221.9 527.5 221.4
        514.2 221.6 511.8 221.6 504 221.9 499.2 222.9 489.2 225.2 474 227.1 464.8 231.1 449.2 235.8 435 241.1 421.5
        246.9 409 251.7 399.5 261.7 382.5 267.8 373.3 276.2 361.5 287.4 347.5 299.8 334.1 308.4 325.5 320.5 315 333
        304.9 344.1 297 357 288.5 372.5 279.6 385.2 273.2 389.5 270.8 402.5 265.1 419.2 258.3 428.8 254.8 436.8 252.1
        446.2 249.2 464 244.3 477.8 241.3 487.5 239.5 501.5 237.5 505.2 237.4 511.8 236.6 514.8 236.6 521.8 236.1 533.5
        236.1 540.5 236.6 547.8 236.6 550 236.9 553 236.9 559.5 237.9 564 238.9 568 240.1 576.5 243.6 580.2 245.7 585.2
        249.2 589.5 253.4 593 257.5 595.7 261.8 596.3 263 598.3 268.8 598.6 270.2 598.4 277.2 598.1 279.5 598.1 283.5
        597.7 287.2 596.5 289.8 589.4 303 583.4 309.5 579.3 313 574.2 317 565.8 322.4 561.5 324.7 558 326.3 551.5 328.5
        547.2 329.8 541 331.2 539.5 331.4 535 331.4 533.2 331.1 528.5 331.1 526.8 330.9 522 330.9 519.8 330.6 506.5
        330.6 504.2 330.9 499.5 330.9 497.8 331.1 493 331.1 488 331.8 485.5 332 473 333.9 461.2 336.7 453.5 339.2 447.5
        341.4 441.1 344 428.5 350.3 423 353.5 414.7 358.8 406.5 364.5 400 369.8 392.5 376.1 384.6 383.8 379.8 388.9
        373.7 395.8 366.2 405.2 358.6 416 355.1 422 350.3 430.8 348.3 434.8 345.1 442.2 341.3 452 339.2 459 336.6 469
        335.2 476.5 334.5 481 333.4 489.5 332.9 498.8 332.9 510.5 334.2 525 334.7 529 336.7 539.8 339.7 550.5 342.8
        559.5 346.1 567.2 349.3 573.8 353.7 581.2 356.7 586 367 599.5 373 606.1 375.8 608.6 378.1 611.2 387 619 398.8
        628.3 410.4 636.2 419.5 642 434.1 650 447.5 656 459.5 660.5 467 663 482.5 667.1 492.5 669.1 506.5 671.1 517.2
        671.9 522.2 671.9 524.5 672.1 543.2 672.1 557.5 671.1 562.2 670.4 564.5 670.3 571.8 669.3 579.8 667.8 593.5
        664.8 609.2 660 623.2 654.7 626.1 653.5 637.2 648.2 644.2 644.4 650.5 640.8 660.9 634 666.8 629.8 679.5 619.1
        682.5 616.4 690.4 608.2 696.8 600.8 699.5 597.2 706.2 587.9 710.8 580.8 715.2 572.8 717.7 568 721.9 557.5 725.1
        548.8 727 542 728.5 535.5 730.3 524.5 730.9 518.2 730.9 504 730.3 497.8 728.4 485.8 727 479.8 724.4 470.5 722.8
        466.5 721.9 463.5 720.4 460 717.4 453.2 713.7 445.8 708.3 436.5 706.2 433.7 704 430 699.1 423.2 693.8 416.5
        691.4 414 685 406.6 673.4 395.2 652.9 377.2 650.4 374.8 650.2 374.2 650.3 373.8 650.8 373.6 651.8 373.8 654
        374.8 657.2 376.6 663.7 380.8 669.2 384.9 680.1 394 688.6 402.5 693.4 407.5 702.2 418 709.5 427.8 712.6 432.5
        717 439.5 720.1 444.8 722.5 449.5 725.2 454.2 726.8 458.7 728.2 460.9 728 459.6 727.2 457.4 725.6 454.2 724.8
        451.5 723.8 449.2 718.5 438.9 716 435 714.4 432 710.2 425.8 704.2 417.7 693 404.4 684 395.1 678 389.6 669.8
        382.8 661.5 376.2 651 368.8 646.2 365.8 642.3 363 636.7 359.5 627.8 353.5 617.6 345.8 613.1 341.2 612.4 340.2
        612.6 339.2 615.4 333.5 616.2 332.9 619 332.9 624.2 333.7 635.1 337.2 639.8 339.1 646.5 342.3 652.5 345.7 661.3
        351.2 671 357.8 677 362.2 689.2 371.9 698 379.4 702.4 383.8 707.9 388.8 716.6 398 726.8 410 733.2 418.2 735.5
        422 737.2 424.2 737.4 424 737.3 423.5 736.5 422 734.1 418.8 732.2 415.6 726.2 407.3 720 399.1 713.8 392.2 712.5
        390.6 708.4 386 708.5 385.9 708.8 386 709.2 386.4 711.6 389 718.1 395.2 722.9 401 726.2 404.7 737.9 420 740
        423.3 741.5 425.1 741.3 424.2 740.2 422.5 735 414.1 722.3 397.2 714.8 388.9 708.6 382.5 704.4 378.2 698.2 372.6
        685.2 361.9 680 357.9 672.7 352.8 655.5 341.5 648.5 337.2 635 329.7 626.5 324.5 625.5 323.8 625.5 323.2 626
        323.2 627.5 323.7 633 325.8 647.6 333 654.5 337.2 662.2 341.5 673.2 348.8 682.7 355.5 699.5 368.8 708.1 376.2
        717.4 385.2 723.1 391.2 736.5 406.9 744.1 417.2 749 424.7 749.5 425.4 749.8 425.5 749.8 425.4 748.2 422.4 742.4
        412.8 733.2 400 730.3 396.5 724.6 389.8 719.2 383.9 708.8 373.4 701.2 366.8 697.3 363 697.5 362.8 697.9 363 705
        368.1 705.2 368 705 367.8 703.8 366.3 699.5 362.5 692 356.4 679.4 346.8 669.1 339.8 657.8 332.5 649.8 327.8 640
        321.5 635.8 319.1 629.2 314.7 626.7 312.5 626.1 311.8 626 311.2 626.2 310.5 626.8 310 627.2 309.9 631.2 310.6
        637.5 312.6 647.2 316.6 650.8 318.4 655.5 320.6 670.2 329 677.1 333.2 691.2 342.9 699.2 348.9 712 359.2 728
        373.9 737.8 384.2 746.6 394.8 752 401.7 759.8 413 766.5 424 769.4 429.5 776.9 444.8 782.1 458.5 783.7 463.2 786
        471.5 788.3 481.2 790.8 497.2 791.9 513.5 791.9 520.8 791.1 534 788.8 548.8 786.9 557.5 783.2 571 780.2 579.6
        774.7 593.5 772.4 598.2 767 609.1 762.1 617.8 754.5 629.7 745.5 642 742.6 645.8 732.5 657.4 722.2 667.9 718.6
        671 715 674.6 707.8 680.8 698 688.5 690.2 694 678.5 701.8 669.5 707.3 659 712.9 650 717.4 635.8 723.9 630.2
        726.2 616.8 731.2 596.8 737.5 587 740.1 569.2 744.1 552 747 538 748.8 535 748.9 528.8 749.6 526 749.6 519.8
        750.4Z M697.2 362.9 697.2 362.7 697.4 362.8Z
        """
}

/// The ring in vermilion, `size` wide, with the round's numeral in the ink (none for the footer's).
private struct RingMark: View {
    var n: Int?
    let size: CGFloat
    var numeral: CGFloat = 0
    let t: CardTheme

    var body: some View {
        ZStack {
            RoundRing().fill(t.red)
            if let n {
                Text("\(n)").font(.system(size: numeral, design: .serif)).foregroundStyle(t.ink)
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .frame(width: size * 0.5)
                    .padding(.top, numeral * 0.06)
            }
        }
        .frame(width: size, height: size * RoundRing.aspect)
        .accessibilityHidden(true)  // the brand's sign; the round is in the title beside it
    }
}

// MARK: Parts

/// A section's name and its quieter words: "What they were about · new comments, by your tags".
private struct CardSection: View {
    let title: String
    let sub: String
    let t: CardTheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(t.ink2)
            Text(sub).font(.system(size: 11)).foregroundStyle(t.secondary)
        }
        .lineLimit(1)
        .padding(.bottom, 9)
    }
}

/// The numbers beside the word count, two to a row: "16 New", "12 of 12 Pages with a mark".
private struct FigureGrid: View {
    let figures: [RoundStats.Figure]
    let size: CGFloat
    let spacing: (h: CGFloat, v: CGFloat)
    let t: CardTheme

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: spacing.h, verticalSpacing: spacing.v) {
            ForEach(0..<(figures.count + 1) / 2, id: \.self) { row in
                GridRow {
                    cell(figures[row * 2])
                    if row * 2 + 1 < figures.count { cell(figures[row * 2 + 1]) }
                }
            }
        }
    }

    private func cell(_ f: RoundStats.Figure) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(RoundStats.grouped(f.value)).font(.system(size: size, design: .serif)).foregroundStyle(t.ink)
                + Text(f.of.map { " of \($0)" } ?? "").font(.system(size: size * 0.55, design: .serif)).foregroundStyle(t.secondary)
            Text(f.label).font(.system(size: 11)).foregroundStyle(t.secondary).lineLimit(1)
        }
        .fixedSize()
    }
}

/// A row of vermilion squares, one per comment.
private struct Squares: Shape {
    let count: Int
    let size: CGFloat
    let gap: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        for i in 0..<count {
            p.addRoundedRect(in: CGRect(x: CGFloat(i) * (size + gap), y: (rect.height - size) / 2, width: size, height: size),
                             cornerSize: CGSize(width: size / 6, height: size / 6))
        }
        return p
    }
}

/// What the new comments were about: per tag its name, a square per comment and the count; one square size for the
/// table (smaller, down to 3 pt, so the largest count fits); then the tags folded into one line and the praise.
private struct TagTable: View {
    let stats: RoundStats
    let rows: [RoundStats.TagRow]
    /// The line under the rows, longest first: the tags folded by name, then by how many (the first that fits).
    let also: [String]
    var help: String? = nil
    let width: CGFloat
    let square: CGFloat
    let rowHeight: CGFloat
    let nameWidth: CGFloat
    let t: CardTheme

    /// The squares' size and gap: `square`, or smaller so the largest count fits beside the names.
    static func squares(most: Int, width: CGFloat, nameWidth: CGFloat, square: CGFloat) -> (size: CGFloat, gap: CGFloat) {
        let avail = width - nameWidth - 30
        let gap = max(1.5, square / 3)
        let size = min(square, max(3, (avail + gap) / CGFloat(max(most, 1)) - gap))
        return (size, max(1.5, size / 3))
    }

    var body: some View {
        let sq = Self.squares(most: rows.map(\.count).max() ?? 1, width: width, nameWidth: nameWidth, square: square)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows, id: \.id) { r in
                HStack(spacing: 0) {
                    Text(r.name).font(.system(size: 12)).foregroundStyle(t.ink).lineLimit(1)
                        .frame(width: nameWidth, alignment: .leading)
                    Squares(count: r.count, size: sq.size, gap: sq.gap).fill(t.red)
                        .frame(width: CGFloat(r.count) * (sq.size + sq.gap) - sq.gap, height: rowHeight)
                    Text("\(r.count)").font(.system(size: 13, design: .serif)).foregroundStyle(t.secondary)
                        .padding(.leading, sq.gap + 4)
                }
                .frame(height: rowHeight)
                .accessibilityElement(children: .combine)  // "Clarity, 5": the squares are the count drawn
            }
            if !also.isEmpty || stats.praise > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    ViewThatFits(in: .horizontal) {
                        ForEach(also, id: \.self) { Text($0).fixedSize() }
                        Text(also.last ?? "").lineLimit(1)
                    }
                    .foregroundStyle(t.secondary)
                    .help(help ?? "")
                    Spacer(minLength: 0)
                    if stats.praise > 0 {
                        (Text("★").foregroundStyle(t.red) + Text(" \(stats.praise) done well").foregroundStyle(t.ink2)).fixedSize()
                    }
                }
                .font(.system(size: 11))
                .padding(.top, 6)
            }
        }
        .frame(width: width, alignment: .leading)
    }
}

/// Where the pen went: a small page for each page of the round's PDF, in its shape, with a vermilion stroke where each
/// comment written or followed up this round starts (a frame for a box, a dot for a note), at its height and in its
/// column. `lines`: two columns of faint lines as texture, never the paper's text.
struct PageStrip: View {
    let stats: RoundStats
    let width: CGFloat
    let perRow: Int
    let gap: CGFloat
    let lines: Bool
    /// The widest a small page usually gets, so a short paper's pages do not take the room of the card's other parts.
    let maxPage: CGFloat
    /// The widest a small page grows to when the card has room to spare (a sparse round's card at its least height):
    /// the strip takes that room, a bigger proof sheet, before any is left under it. None: the strip never grows.
    var roomyPage: CGFloat? = nil
    let t: CardTheme

    /// Each small page's size, the rows, and their gap; given `room`, the strip's height, the pages as large as fit
    /// in it (at least their usual size, at most `roomyPage` or the row's width).
    func layout(room: CGFloat? = nil) -> (page: CGSize, perRow: Int, rows: Int, rowGap: CGFloat) {
        let n = max(stats.pages, 1)
        let per = max(1, min(perRow, n))
        let rows = (n + per - 1) / per, rowGap = gap * 1.4
        let aspect = CGFloat(min(max(stats.aspect, 0.5), 2))
        let fit = (width - gap * CGFloat(per - 1)) / CGFloat(per)
        var pw = min(maxPage, fit)
        if let room, let roomy = roomyPage {
            pw = max(pw, min(roomy, fit, (room - CGFloat(rows - 1) * rowGap) / CGFloat(rows) / aspect))
        }
        return (CGSize(width: pw, height: pw * aspect), per, rows, rowGap)
    }

    /// The strip's height: its usual one, or with the pages at their largest (`roomy`).
    func height(roomy: Bool = false) -> CGFloat {
        let l = layout(room: roomy ? .infinity : nil)
        return CGFloat(l.rows) * l.page.height + CGFloat(l.rows - 1) * l.rowGap
    }

    var body: some View {
        Canvas { ctx, size in
            let l = layout(room: size.height)
            let (pw, ph) = (l.page.width, l.page.height)
            for p in 0..<max(stats.pages, 1) {
                let origin = CGPoint(x: CGFloat(p % l.perRow) * (pw + gap), y: CGFloat(p / l.perRow) * (ph + l.rowGap))
                let frame = CGRect(origin: origin, size: l.page)
                let page = Path(roundedRect: frame, cornerRadius: 1.5)
                ctx.fill(page, with: .color(t.page))
                ctx.stroke(page, with: .color(t.pageLine), lineWidth: 0.6)
                if lines { ctx.fill(texture(frame, first: p == 0), with: .color(t.texture)) }
                for m in stats.marks where m.page == p { draw(m, in: frame, ctx: ctx) }
            }
        }
        .frame(width: width)
        .frame(minHeight: height(), maxHeight: height(roomy: true), alignment: .topLeading)
        .accessibilityElement()
        .accessibilityLabel(Self.spoken(stats))
    }

    /// What VoiceOver reads for the drawn pages: "A mark on 12 of 14 pages".
    nonisolated static func spoken(_ s: RoundStats) -> String {
        "A mark on \(Set(s.marks.map(\.page)).count) of " + RoundStats.count(s.pages, "page")
    }

    /// Two columns of faint lines, the title's line first on page 1.
    private func texture(_ f: CGRect, first: Bool) -> Path {
        var path = Path()
        let step = max(0.035, 3.2 / f.height), h = max(0.6, f.height / 160)
        var y = 0.09
        if first {
            path.addRect(CGRect(x: f.minX + 0.24 * f.width, y: f.minY + 0.07 * f.height, width: 0.52 * f.width,
                                height: max(1, f.height * 0.03)))
            y = 0.19
        }
        while y < 0.93 {
            for c in 0...1 {
                path.addRect(CGRect(x: f.minX + (0.08 + Double(c) * 0.46) * f.width, y: f.minY + y * f.height,
                                    width: 0.38 * f.width, height: h))
            }
            y += step
        }
        return path
    }

    private func draw(_ m: RoundStats.Mark, in f: CGRect, ctx: GraphicsContext) {
        let x0 = f.minX + (0.08 + Double(m.column) * 0.46) * f.width
        let hh = max(2.2, f.height * 0.03)
        switch m.kind {
        case .frame:
            let r = CGRect(x: x0 + 0.04 * f.width, y: f.minY + min(m.y, 0.84) * f.height, width: 0.30 * f.width,
                           height: 0.14 * f.height)
            ctx.stroke(Path(roundedRect: r, cornerRadius: 1), with: .color(t.red), lineWidth: max(1, f.width / 45))
        case .dot:
            let d = max(2.6, hh * 1.3)
            let y = f.minY + min(m.y * f.height, f.height - d - 1)
            ctx.fill(Path(ellipseIn: CGRect(x: x0 + 0.04 * f.width, y: y, width: d, height: d)), with: .color(t.red))
        case .stroke:
            let y = f.minY + min(m.y * f.height, f.height - hh - 1)
            let r = CGRect(x: x0, y: y, width: (m.followUp ? 0.22 : 0.32) * f.width, height: hh)
            ctx.fill(Path(roundedRect: r, cornerRadius: hh / 2), with: .color(t.red))
        }
    }
}

/// The facts, each after a vermilion ¶, in italic New York.
private struct FactList: View {
    let facts: [String]
    let size: CGFloat
    let t: CardTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(facts, id: \.self) { f in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("¶").font(.system(size: size, design: .serif)).foregroundStyle(t.red)
                    Text(f).font(.system(size: size, design: .serif).italic()).foregroundStyle(t.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// A view as tall as it would be, in whole points, within `range`, and laid out at that height: a shorter one's
/// flexible parts take the room (the card's pages and gaps), a taller one gives way (the card's facts).
private struct ClampedHeight: Layout, ViewModifier {
    let range: ClosedRange<CGFloat>

    func body(content: Content) -> some View { self { content } }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let v = subviews.first else { return .zero }
        let ideal = v.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: ideal.width, height: min(max(ideal.height.rounded(.up), range.lowerBound), range.upperBound))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

// MARK: The card

/// The whole card, 540 pt wide and as tall as what it holds, from a square (540 pt) to 4:5 (675 pt); 1080 px wide as
/// an image at 2×. The ring and the round, the words written, the answers, the tags, the pages, the student, the facts
/// that fit. `showTitle`, `showStudent`: the paper's title and the student's name, only when the advisor ticks them.
struct RoundCardView: View {
    let stats: RoundStats
    var showTitle = false
    var showStudent = false
    let dark: Bool

    static let width: CGFloat = 540
    /// The card's heights (request of 2026-10-26: a sparse round left the lower half of a 4:5 card empty). A square at
    /// the least, where a sparse round's pages grow into the room; 4:5 at the most, where the facts give way. Both
    /// are the shapes a feed shows whole, and the image is the card the sheet shows.
    static let heights: ClosedRange<CGFloat> = 540...675
    private static let inner: CGFloat = 460

    /// The card's size with these ticks: its content's height within `heights`.
    @MainActor static func size(_ stats: RoundStats, showTitle: Bool = false, showStudent: Bool = false) -> CGSize {
        NSHostingView(rootView: RoundCardView(stats: stats, showTitle: showTitle, showStudent: showStudent, dark: false)).fittingSize
    }

    var body: some View {
        let t = CardTheme(dark: dark)
        // the facts give way when the card is full: two, then one, then none
        ViewThatFits(in: .vertical) {
            content(t, facts: 2)
            content(t, facts: 1)
            content(t, facts: 0)
        }
        .modifier(ClampedHeight(range: Self.heights))
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 6) {
                RingMark(size: 14, t: t)
                Text("Paperole").font(.system(size: 10.5, weight: .medium)).foregroundStyle(t.secondary)
            }
            .padding(.leading, 40)
            .padding(.bottom, 26)
        }
        .background(t.paper)
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    /// The card but its footer, with the first `facts` facts. A card taller than what it holds (a sparse round's, a
    /// square) gives the room to its pages first, as large as `roomyPage`, then to the gaps between its parts, evenly:
    /// never one stretch of empty paper.
    private func content(_ t: CardTheme, facts: Int) -> some View {
        let table = stats.tagTable(maxRows: 7)
        // with no tag section the pages take its room, as a proof sheet. The gaps are the mockup's less what SwiftUI's
        // taller lines of text add (a CSS line of 12 px at line-height 1 is about 14 pt here)
        let big = !stats.tagsShown
        let strip = PageStrip(stats: stats, width: Self.inner, perRow: big ? max(8, (stats.pages + 2) / 3) : max(16, (stats.pages + 1) / 2),
                              gap: big ? 10 : 6, lines: true, maxPage: big ? 54 : 34, roomyPage: big ? 96 : 54, t: t)
        return VStack(alignment: .leading, spacing: 0) {
            header(t)
            Rectangle().fill(t.rule).frame(height: 1).padding(.top, 22)
            Spacer(minLength: 20)
            lead(t)
            if stats.tagsShown {
                Spacer(minLength: 24)
                CardSection(title: "What they were about", sub: "· new comments, by your tags", t: t)
                TagTable(stats: stats, rows: table.rows,
                         also: [true, false].compactMap { stats.alsoLine(table.folded, names: $0) }
                            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } },
                         width: Self.inner, square: 9, rowHeight: 19, nameWidth: 150, t: t)
            }
            Spacer(minLength: big ? 26 : 20)
            CardSection(title: "Where your pen went", sub: "· \(RoundStats.count(stats.pages, "page")), a mark for each comment", t: t)
            strip.layoutPriority(1)  // offered the room before the gaps
            if let s = stats.studentLine(named: showStudent) {
                (Text(s.lead).font(.system(size: 12, weight: .medium)).foregroundStyle(t.ink2)
                    + Text(" · " + s.rest).font(.system(size: 12)).foregroundStyle(t.secondary))
                    .lineLimit(1)
                    .padding(.top, 16)
            }
            FactList(facts: Array(stats.facts.prefix(facts)), size: 13.5, t: t).padding(.top, 10)
            Spacer(minLength: 0)
        }
        .padding(.top, 38)
        .padding(.horizontal, 40)
        .padding(.bottom, 52)  // 12 pt above the footer
        .frame(width: Self.width, alignment: .topLeading)
    }

    private func header(_ t: CardTheme) -> some View {
        HStack(alignment: .center, spacing: 14) {
            RingMark(n: stats.round, size: 58, numeral: 30, t: t)
            VStack(alignment: .leading, spacing: 0) {
                Text("Round \(stats.round)").font(.system(size: 25, weight: .semibold, design: .serif)).foregroundStyle(t.ink)
                Text(stats.dateLine).font(.system(size: 11.5)).foregroundStyle(t.secondary).padding(.top, 4)
                if let who = who(t) {
                    who.lineLimit(1).truncationMode(.tail).padding(.top, 5)
                }
            }
        }
    }

    /// The opt-in line: the student's name, then the paper's title in italic New York, cut at the end (a long title
    /// is cut, the name never).
    private func who(_ t: CardTheme) -> Text? {
        var parts: [Text] = []
        if showStudent && !stats.student.isEmpty {
            parts.append(Text(stats.student).font(.system(size: 11.5, weight: .medium)).foregroundStyle(t.ink2))
        }
        if showTitle && !stats.title.isEmpty {
            parts.append(Text(stats.title).font(.system(size: 13.5, design: .serif).italic()).foregroundStyle(t.ink2))
        }
        guard let first = parts.first else { return nil }
        return parts.dropFirst().reduce(first) { $0 + Text(" · ").font(.system(size: 11.5)).foregroundStyle(t.secondary) + $1 }
    }

    /// The word count large, what it was written in, and the grid on the right.
    private func lead(_ t: CardTheme) -> some View {
        HStack(alignment: .bottom, spacing: 20) {
            VStack(alignment: .leading, spacing: 0) {
                // the line New York sets is about 1.2 em: trimmed to the mockup's 0.9 em, most of it under the digits
                Text(RoundStats.grouped(stats.words)).font(.system(size: 92, design: .serif)).foregroundStyle(t.ink)
                    .padding(.top, -9).padding(.bottom, -14)
                Text(stats.words == 1 ? "word of comments" : "words of comments").font(.system(size: 13, weight: .medium))
                    .foregroundStyle(t.ink2).padding(.top, 12)
                if let w = stats.wroteLine {
                    Text(w).font(.system(size: 11.5)).foregroundStyle(t.secondary).lineLimit(1).padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            FigureGrid(figures: stats.figures, size: 30, spacing: (26, 14), t: t).padding(.bottom, 4)
        }
    }
}

/// The Finish sheet's card (under "This round · your card when you finish"): the same content, smaller and live,
/// asked again with every engine reply: "Round 2 so far", the number at 50 pt, at most six tag rows (the rest "Also
/// 3 more tags", their names in the help tag), the pages without lines, the first fact.
struct CompactRoundCard: View {
    let stats: RoundStats
    let dark: Bool

    static let inner: CGFloat = 386

    var body: some View {
        let t = CardTheme(dark: dark)
        let table = stats.tagTable(maxRows: 6)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                RingMark(n: stats.round, size: 30, numeral: 16, t: t)
                VStack(alignment: .leading, spacing: 2) {
                    Text(stats.closed ? "Round \(stats.round)" : "Round \(stats.round) so far")
                        .font(.system(size: 16, weight: .semibold, design: .serif)).foregroundStyle(t.ink)
                    Text(stats.closed ? stats.dateLine : stats.soFarLine).font(.system(size: 11)).foregroundStyle(t.secondary)
                }
            }
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(RoundStats.grouped(stats.words)).font(.system(size: 50, design: .serif)).foregroundStyle(t.ink)
                        .padding(.top, -5).padding(.bottom, -7)
                    Text(stats.words == 1 ? "word of comments" : "words of comments").font(.system(size: 12, weight: .medium))
                        .foregroundStyle(t.ink2).padding(.top, 6)
                }
                Spacer(minLength: 0)
                FigureGrid(figures: stats.figures, size: 22, spacing: (18, 8), t: t)
            }
            .padding(.top, 14)
            if stats.tagsShown {
                CardSection(title: "What they were about", sub: "· new comments, by your tags", t: t).padding(.top, 16)
                TagTable(stats: stats, rows: table.rows, also: stats.alsoLine(table.folded, names: false).map { [$0] } ?? [],
                         help: table.folded.isEmpty ? nil : table.folded.map { "\($0.name) \($0.count)" }.joined(separator: " · "),
                         width: Self.inner, square: 7.5, rowHeight: 17, nameWidth: 140, t: t)
            }
            PageStrip(stats: stats, width: Self.inner, perRow: max(14, (stats.pages + 1) / 2), gap: 4, lines: false,
                      maxPage: 30, t: t)
                .padding(.top, 14)
            if !stats.facts.isEmpty {
                FactList(facts: Array(stats.facts.prefix(1)), size: 12.5, t: t).padding(.top, 9)
            }
        }
        .frame(width: Self.inner, alignment: .leading)
        .padding(.top, 18)
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .background(RoundedRectangle(cornerRadius: 10).fill(t.paper))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: Palette.rule), lineWidth: 0.5))
    }
}

// MARK: The image

@MainActor
enum RoundCardImage {
    /// The card as a PNG at 2×, in the given appearance: 1080 px wide, 1080 to 1350 px tall (the card's height).
    static func png(_ stats: RoundStats, showTitle: Bool, showStudent: Bool, dark: Bool) -> Data? {
        let r = ImageRenderer(content: RoundCardView(stats: stats, showTitle: showTitle, showStudent: showStudent, dark: dark))
        r.scale = 2
        r.proposedSize = ProposedViewSize(width: RoundCardView.width, height: nil)
        guard let cg = r.cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = CGSize(width: cg.width / 2, height: cg.height / 2)  // 144 dpi: the image's points are the card's
        return rep.representation(using: .png, properties: [:])
    }

    /// Copy Image: the card on the clipboard as PNG and TIFF (a test run's own pasteboard, never the user's).
    static func copy(_ png: Data) {
        let pb = AppModel.clipboard
        pb.declareTypes([.png, .tiff], owner: nil)
        pb.setData(png, forType: .png)
        if let tiff = NSImage(data: png)?.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
    }

    /// The image's name in the save panel: "Round 2.png", the paper's title first when it is on the card.
    static func fileName(_ stats: RoundStats, showTitle: Bool) -> String {
        let title = TransferText.short(stats.title).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return (showTitle && !stats.title.isEmpty ? "\(title) – " : "") + "Round \(stats.round).png"
    }
}

// MARK: The Summary sheet

/// A round's card in a sheet: right after Finish Round (the Finish sheet turns into it), or later for a finished round.
struct RoundCardAsk: Identifiable {
    let id = UUID()
    var stats: RoundStats
    /// Right after Finish Round: its final.pdf, with Show in Finder and Open.
    var justFinished = false
    var finalPdf: String? = nil
}

/// "Round 2 is finished · final.pdf is ready · Show in Finder · Open" (or "Round 2 Summary · Finished Oct 24, 2026"),
/// the card, "Show on the card: [ ] Paper’s title [ ] Student’s name" (both off each time: the card leaves out who
/// and what unless asked), then Copy Image, Export Image… and Done.
struct RoundSummaryView: View {
    let ask: RoundCardAsk
    let done: () -> Void
    @State private var showTitle = false
    @State private var showStudent = false
    @State private var copied = false
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject private var model: AppModel

    /// The sheet's height: the card's (as tall as its content) at full size when the window has the room, else
    /// smaller. A sheet hangs from the window's toolbar, so its room is the window's below it, not the screen's (880
    /// reached past a 900 pt window).
    private func height(_ card: CGSize) -> CGFloat {
        let room = model.pdf.view?.window?.contentLayoutRect.height ?? (NSScreen.main?.visibleFrame.height ?? 900) - 92
        return min(card.height + 205, room - 8)
    }

    var body: some View {
        let s = ask.stats
        let card = RoundCardView.size(s, showTitle: showTitle, showStudent: showStudent)
        let height = height(card)
        let scale = min(1, (height - 205) / card.height)
        VStack(alignment: .leading, spacing: 0) {
            Text(ask.justFinished ? "Round \(s.round) is finished" : "Round \(s.round) Summary").font(.title2.bold())
            subtitle.font(.system(size: 12.5)).lineLimit(1).padding(.top, 4)
            RoundCardView(stats: s, showTitle: showTitle, showStudent: showStudent, dark: scheme == .dark)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: Palette.rule), lineWidth: 0.5))
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: card.width * scale, height: card.height * scale, alignment: .topLeading)
                .shadow(color: .black.opacity(scheme == .dark ? 0.3 : 0.10), radius: 12, y: 6)
                .frame(maxWidth: .infinity)
                .padding(.top, 16)
            HStack(spacing: 16) {
                Text("Show on the card:").foregroundStyle(Ink.secondary)
                Toggle("Paper’s title", isOn: $showTitle).disabled(s.title.isEmpty)
                Toggle("Student’s name", isOn: $showStudent).disabled(s.student.isEmpty)
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 12.5))
            .fixedSize()  // one line under a card made smaller for a short window ("Student’s name" wrapped)
            .frame(width: card.width * scale, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
            Spacer(minLength: 12)
            HStack(spacing: 10) {
                Button(copied ? "Copied" : "Copy Image") { copied = copy() }
                    .help("Copy the card as an image")
                Button("Export Image…") { export() }
                    // verbatim: a LocalizedStringKey would write "1,080 × 1,174"
                    .help(Text(verbatim: "Save the card as a PNG image, \(Int(card.width * 2)) × \(Int(card.height * 2)) pixels"))
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .foregroundStyle(Ink.label)
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 18)
        .frame(width: 640, height: height)
        .background(Color(nsColor: Palette.sheet))
        .onExitCommand(perform: done)
        .onChange(of: showTitle) { copied = false }
        .onChange(of: showStudent) { copied = false }
    }

    @ViewBuilder private var subtitle: some View {
        if ask.justFinished {
            HStack(spacing: 0) {
                Text(ask.finalPdf == nil ? "final.pdf is not there" : "final.pdf is ready").foregroundStyle(Ink.secondary)
                if let p = ask.finalPdf {
                    Text(" · ").foregroundStyle(Ink.secondary)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
                        .buttonStyle(LinkStyle())
                        .help("Show final.pdf in the Finder")
                    Text(" · ").foregroundStyle(Ink.secondary)
                    Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
                        .buttonStyle(LinkStyle())
                        .help("Open final.pdf, as the student gets it")
                }
            }
        } else {
            // verbatim: a LocalizedStringKey would write the year as "2,026"
            Text(verbatim: ask.stats.end.map { "Finished \($0.short), \($0.year)" } ?? "Finished").foregroundStyle(Ink.secondary)
        }
    }

    private func image() -> Data? {
        RoundCardImage.png(ask.stats, showTitle: showTitle, showStudent: showStudent, dark: scheme == .dark)
    }

    private func copy() -> Bool {
        guard let png = image() else { return false }
        RoundCardImage.copy(png)
        return true
    }

    /// Export Image…: a PNG where the advisor saves it. Never in a test run (--background), which has no panel.
    private func export() {
        guard !LaunchOptions.background, let png = image() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = RoundCardImage.fileName(ask.stats, showTitle: showTitle)
        panel.canCreateDirectories = true
        let save = { (r: NSApplication.ModalResponse) in
            if r == .OK, let url = panel.url { try? png.write(to: url, options: .atomic) }
        }
        if let w = NSApp.keyWindow { panel.beginSheetModal(for: w, completionHandler: save) } else { save(panel.runModal()) }
    }
}

// MARK: The model's part

extension AppModel {
    /// A round's numbers for its card, from its state and its PDF's page sizes.
    func roundStats(_ st: EngineState) -> RoundStats {
        RoundStats(state: st, pageSizes: RoundStats.pageSizes(resolve(st.round?.build.pdf)), catalog: tags.catalog)
    }

    /// Round N Summary… (the round menu, the overview's More, Jump): the card of a finished round, from the state
    /// shown when it is that round's, else from the engine's state of that round (read only, never shown in Review).
    func openRoundSummary(_ n: Int? = nil) {
        guard let path = selectedPath else { return }
        if let st = state, let r = st.round, r.closed, n == nil || n == r.n {
            roundCard = RoundCardAsk(stats: roundStats(st))
            return
        }
        guard let n else { return }
        guard fixtureURL == nil, let json = try? JSONSerialization.data(withJSONObject: ["paper": path, "round": n] as [String: Any])
        else { return toast("Fixture mode: the engine is not running, so Round \(n) cannot be read.") }
        let id = engine.send("state", params: json)
        Task {
            do {
                let reply = try makeDecoder().decode(Reply.self, from: try await engine.result(id))
                guard selectedPath == path else { return }
                guard reply.state.round?.n == n, reply.state.round?.closed == true else {
                    return toast("Round \(n) is not finished yet.")
                }
                roundCard = RoundCardAsk(stats: roundStats(reply.state))
            } catch {
                alertMessage = describe(error)
            }
        }
    }

    /// The Summary's Done after Finish Round: the sheet closes, and the window's line says where final.pdf is.
    func closeFinishSummary() {
        let done = finishPreview.done
        showFinish = false
        finishPreview.done = nil
        if let d = done { finishedNotice(d.stats.round, final: d.finalPdf) }
    }

    /// "Round 2 is finished · final.pdf is ready" with Show in Finder and Open, at the bottom of the window.
    func finishedNotice(_ n: Int, final: String?) {
        guard let p = final else { return showNotice(WindowNotice(text: "Round \(n) is finished.")) }
        let url = URL(fileURLWithPath: p)
        showNotice(WindowNotice(text: "Round \(n) is finished · final.pdf is ready", action: "Show in Finder", second: "Open"),
                   second: { NSWorkspace.shared.open(url) }, action: { NSWorkspace.shared.activateFileViewerSelecting([url]) })
    }

    /// The final.pdf menu's Copy Email Text (a closed round): the email.txt the engine still writes, for the rare
    /// case it is wanted.
    func copyEmailText() {
        guard let r = round, r.closed, let text = r.email, !text.isEmpty else { return }
        Self.clipboard.clearContents()
        Self.clipboard.setString(text, forType: .string)
        toast("Round \(r.n)’s email text is copied")
    }
}
