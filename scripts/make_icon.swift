// Draws the app icon (a sparkle on a purple-teal plate) and writes an .iconset folder.
// Usage: swift scripts/make_icon.swift <output.iconset>
import AppKit

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    let plate = NSBezierPath(roundedRect: NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s),
                             xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(red: 0.55, green: 0.25, blue: 0.95, alpha: 1),
                        NSColor(red: 0.10, green: 0.70, blue: 0.75, alpha: 1)])!.draw(in: plate, angle: -60)
    func star(cx: CGFloat, cy: CGFloat, r: CGFloat) {
        let p = NSBezierPath()
        for i in 0..<8 {
            let a = CGFloat(i) * .pi / 4 + .pi / 2
            let rr = i % 2 == 0 ? r : r * 0.28
            let pt = NSPoint(x: cx + cos(a) * rr, y: cy + sin(a) * rr)
            if i == 0 { p.move(to: pt) } else { p.line(to: pt) }
        }
        p.close()
        NSColor.white.setFill()
        p.fill()
    }
    star(cx: 470 * s, cy: 470 * s, r: 260 * s)
    star(cx: 720 * s, cy: 720 * s, r: 110 * s)
    star(cx: 730 * s, cy: 300 * s, r: 70 * s)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try draw(size: px).representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
    }
}
