// Draws the 1200×630 social preview (Open Graph) image for the website.
// Usage: swift scripts/make_social_image.swift <icon.png> <screenshot.png> <output.jpg>
import AppKit

let args = CommandLine.arguments
guard args.count == 4, let icon = NSImage(contentsOfFile: args[1]), let shot = NSImage(contentsOfFile: args[2]) else {
    print("usage: make_social_image.swift <icon.png> <screenshot.png> <output.jpg>"); exit(1)
}
let W = 1200, H = 630
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let bounds = NSRect(x: 0, y: 0, width: W, height: H)

// Deep space with two nebula glows.
NSColor.black.setFill(); bounds.fill()
func glow(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ c: NSColor) {
    NSGradient(colors: [c, c.withAlphaComponent(0)])!.draw(fromCenter: NSPoint(x: x, y: y), radius: 0,
                                                             toCenter: NSPoint(x: x, y: y), radius: r, options: [])
}
glow(180, 520, 420, NSColor(red: 0.49, green: 0.23, blue: 0.93, alpha: 0.45))
glow(1050, 120, 420, NSColor(red: 0.13, green: 0.83, blue: 0.93, alpha: 0.28))

// Stars (fixed seed, so the image is reproducible).
var seed: UInt64 = 42
func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(UInt32.max) }
for _ in 0..<260 {
    let r = rnd() * 1.4 + 0.3
    NSColor(white: 1, alpha: 0.35 + rnd() * 0.6).setFill()
    NSBezierPath(ovalIn: NSRect(x: rnd() * CGFloat(W), y: rnd() * CGFloat(H), width: r, height: r)).fill()
}

// Screenshot on the right, in a rounded window with a soft violet glow.
let shotRect = NSRect(x: 560, y: 70, width: 700, height: 700 * shot.size.height / shot.size.width)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow(); shadow.shadowColor = NSColor(red: 0.49, green: 0.23, blue: 0.93, alpha: 0.55); shadow.shadowBlurRadius = 60
shadow.set()
NSBezierPath(roundedRect: shotRect, xRadius: 16, yRadius: 16).fill()
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.saveGraphicsState()
NSBezierPath(roundedRect: shotRect, xRadius: 16, yRadius: 16).addClip()
shot.draw(in: shotRect)
NSGraphicsContext.restoreGraphicsState()

// Icon, name and tagline on the left.
icon.draw(in: NSRect(x: 72, y: 430, width: 96, height: 96))
func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, _ y: CGFloat) {
    NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
        .draw(at: NSPoint(x: 72, y: y))
}
text("MyOpenCleaner", 58, .bold, .white, 330)
text("The free, open-source", 34, .semibold, NSColor(white: 0.85, alpha: 1), 270)
text("Mac cleaner.", 34, .semibold, NSColor(red: 0.65, green: 0.55, blue: 0.98, alpha: 1), 228)
text("Junk · Xcode & dev caches · Uninstaller · Undo", 21, .regular, NSColor(white: 0.62, alpha: 1), 150)
text("MIT license · No telemetry · macOS 14+", 21, .regular, NSColor(white: 0.62, alpha: 1), 116)
NSGraphicsContext.restoreGraphicsState()

let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.88])!
try! data.write(to: URL(fileURLWithPath: args[3]))
print("wrote \(args[3])")
