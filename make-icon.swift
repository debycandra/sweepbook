// Renders assets/icon.svg (the vector source, drawn on the standard 1024 macOS icon grid)
// into an .iconset, adding a soft shadow under the rounded square.
// Usage: swift make-icon.swift <out.iconset> [preview.png]
import AppKit

let args = CommandLine.arguments
let out = args.count > 1 ? args[1] : "AppIcon.iconset"
let preview = args.count > 2 ? args[2] : nil
guard let art = NSImage(contentsOfFile: "assets/icon.svg") else {
    fatalError("assets/icon.svg not found (run from the repo root)")
}
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    ctx.imageInterpolation = .high
    NSGraphicsContext.current = ctx
    let k = CGFloat(px) / 1024
    let body = NSRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * k, yRadius: 185 * k)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * k)
    shadow.shadowBlurRadius = 24 * k
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    art.draw(in: NSRect(x: 0, y: 0, width: CGFloat(px), height: CGFloat(px)))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try render(base * scale)?.write(to: URL(fileURLWithPath: out + "/" + name))
    }
}
if let preview { try render(512)?.write(to: URL(fileURLWithPath: preview)) }
