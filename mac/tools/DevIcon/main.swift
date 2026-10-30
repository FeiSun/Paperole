// An .icns with Paperole Dev's mark, as an .iconset (Sources/Paperole/DevMark.swift, the drawing the
// running dev app puts on its Dock icon): every size from 16 to 1024, each drawn from the icon's own drawing for that
// size, in sRGB. tools/dev_icon.sh builds and runs it.
//   dev_icon <in.icns> <out.iconset>
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let icon = NSImage(contentsOf: URL(fileURLWithPath: args[1])) else {
    FileHandle.standardError.write(Data("usage: dev_icon <in.icns> <out.iconset>\n".utf8))
    exit(2)
}
let out = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let marked = DevMark.marked(icon)
for side in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = side * scale
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        marked.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = ctx.makeImage().flatMap({ NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) })
        else { exit(1) }
        try png.write(to: out.appendingPathComponent("icon_\(side)x\(side)\(scale == 2 ? "@2x" : "").png"))
    }
}
