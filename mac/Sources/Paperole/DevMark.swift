import AppKit

/// Paperole Dev's mark on its icon, wherever the app shows one (the Dock, About, alerts; AppIconModel) and on the dev
/// bundle's own icon (Resources/AppIcons/paperole-dev.icns, made from this drawing by tools/dev_icon.sh, which compiles
/// this file alone): a small graphite capsule, "DEV" in white bold, a thin light outline, bottom right, about a quarter
/// of the icon wide, so it reads on the light icons and the dark ones. Not the Dock's red badge (a count), not amber
/// (the advisor's move), not red (broken).
enum DevMark {
    /// `icon` with the mark, drawn at whatever size it is drawn.
    static func marked(_ icon: NSImage) -> NSImage {
        NSImage(size: icon.size, flipped: false) { rect in
            icon.draw(in: rect)
            draw(in: rect)
            return true
        }
    }

    /// The mark in an icon's square, measured as the icon's 1024 (its body 824 wide at 100).
    static func draw(in rect: NSRect) {
        let k = rect.width / 1024
        let r = NSRect(x: rect.minX + 668 * k, y: rect.minY + 92 * k, width: 280 * k, height: 128 * k)
        let capsule = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        NSColor(srgbRed: 0.16, green: 0.17, blue: 0.19, alpha: 1).setFill()
        capsule.fill()
        NSColor(white: 1, alpha: 0.85).setStroke()
        capsule.lineWidth = 7 * k
        capsule.stroke()
        let text = NSAttributedString(string: "DEV", attributes: [
            .font: NSFont.systemFont(ofSize: 74 * k, weight: .bold),
            .foregroundColor: NSColor.white,
            .kern: 5 * k,
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: r.midX - size.width / 2 + 2.5 * k, y: r.midY - size.height / 2))
    }
}
