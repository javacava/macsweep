// Draws the background of the disk image window: the app on the left, Applications on the right
// and an arrow that says "drag me across". Writes a 1x and a 2x PNG; make_dmg.sh joins them.
// Usage: swift scripts/make_dmg_background.swift <out.png> <out@2x.png>
//
// The layout numbers below must match the icon positions in make_dmg.sh.
import AppKit

let args = CommandLine.arguments
guard args.count == 3 else { print("usage: make_dmg_background.swift <out.png> <out@2x.png>"); exit(1) }

let W: CGFloat = 640, H: CGFloat = 400
let appX: CGFloat = 170, appsX: CGFloat = 470, iconY: CGFloat = 196   // icon centres, measured from the top
let labelY: CGFloat = iconY + 76                                     // centre of the Finder label under each icon

func render(scale: CGFloat, to path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)   // points, so the image carries its DPI
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.imageInterpolation = .high
    func top(_ y: CGFloat) -> CGFloat { H - y }   // AppKit counts from the bottom

    // Deep space with a violet glow behind the app and a cyan one behind Applications.
    NSGradient(starting: NSColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1),
               ending: NSColor(red: 0.01, green: 0.01, blue: 0.02, alpha: 1))!
        .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)
    func glow(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ c: NSColor) {
        NSGradient(colors: [c, c.withAlphaComponent(0)])!.draw(fromCenter: NSPoint(x: x, y: top(y)), radius: 0,
                                                                 toCenter: NSPoint(x: x, y: top(y)), radius: r, options: [])
    }
    glow(appX, iconY, 230, NSColor(red: 0.49, green: 0.23, blue: 0.93, alpha: 0.42))
    glow(appsX, iconY, 230, NSColor(red: 0.13, green: 0.83, blue: 0.93, alpha: 0.24))

    // Stars, fixed seed so every build draws the same sky. None near the arrow or the labels.
    var seed: UInt64 = 7
    func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(UInt32.max) }
    for _ in 0..<140 {
        let x = rnd() * W, y = rnd() * H, r = rnd() * 1.3 + 0.4, a = 0.25 + rnd() * 0.55
        if y > 110 && y < 320 { continue }
        NSColor(white: 1, alpha: a).setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: top(y), width: r, height: r)).fill()
    }

    func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, centerY: CGFloat) {
        let str = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                             .foregroundColor: color, .kern: size > 16 ? -0.3 : 0])
        let sz = str.size()
        str.draw(at: NSPoint(x: (W - sz.width) / 2, y: top(centerY) - sz.height / 2))
    }
    text("Drag MyOpenCleaner to Applications", size: 21, weight: .semibold, color: NSColor(white: 0.97, alpha: 1), centerY: 52)
    // The app is not notarized, so the first launch needs one click on Open Anyway. Say so up front.
    text("First launch: System Settings → Privacy & Security → Open Anyway", size: 13, weight: .regular,
         color: NSColor(white: 0.7, alpha: 1), centerY: 82)

    // The arrow: a soft arc from the app to Applications, violet into cyan.
    let start = NSPoint(x: appX + 84, y: top(iconY)), end = NSPoint(x: appsX - 92, y: top(iconY))
    let arc = NSBezierPath()
    arc.move(to: start)
    arc.curve(to: end, controlPoint1: NSPoint(x: start.x + 40, y: start.y + 26), controlPoint2: NSPoint(x: end.x - 40, y: end.y + 26))
    arc.lineWidth = 5; arc.lineCapStyle = .round
    let head = NSBezierPath()
    head.move(to: NSPoint(x: end.x - 15, y: end.y + 13))
    head.line(to: NSPoint(x: end.x + 3, y: end.y - 1))
    head.line(to: NSPoint(x: end.x - 19, y: end.y - 7))
    head.lineWidth = 5; head.lineCapStyle = .round; head.lineJoinStyle = .round
    let outline = CGMutablePath()
    outline.addPath(arc.cgPath.copy(strokingWithWidth: 5, lineCap: .round, lineJoin: .round, miterLimit: 10))
    outline.addPath(head.cgPath.copy(strokingWithWidth: 5, lineCap: .round, lineJoin: .round, miterLimit: 10))
    let arrowShape = NSBezierPath(cgPath: outline)
    arrowShape.windingRule = .nonZero

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(red: 0.55, green: 0.45, blue: 1, alpha: 0.8); shadow.shadowBlurRadius = 14
    shadow.set()
    NSColor(red: 0.6, green: 0.5, blue: 0.98, alpha: 1).setFill()
    arrowShape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    arrowShape.addClip()
    NSGradient(starting: NSColor(red: 0.65, green: 0.55, blue: 0.98, alpha: 1),
               ending: NSColor(red: 0.13, green: 0.83, blue: 0.93, alpha: 1))!
        .draw(in: NSRect(x: start.x - 4, y: start.y - 30, width: end.x - start.x + 12, height: 70), angle: 0)
    NSGraphicsContext.restoreGraphicsState()

    // Frosted plates under the Finder labels: on a background picture Finder writes the labels in
    // black, even in dark mode, so they need something light behind them.
    for x in [appX, appsX] {
        let plate = NSBezierPath(roundedRect: NSRect(x: x - 62, y: top(labelY) - 11, width: 124, height: 22), xRadius: 11, yRadius: 11)
        NSGraphicsContext.saveGraphicsState()
        let s = NSShadow(); s.shadowColor = NSColor(white: 0, alpha: 0.5); s.shadowBlurRadius = 8; s.shadowOffset = NSSize(width: 0, height: -2)
        s.set()
        NSColor(red: 0.9, green: 0.9, blue: 0.94, alpha: 0.92).setFill(); plate.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    text("Free and open source  ·  MIT license  ·  No telemetry", size: 11, weight: .regular,
         color: NSColor(white: 0.45, alpha: 1), centerY: 368)

    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

render(scale: 1, to: args[1])
render(scale: 2, to: args[2])
print("wrote \(args[1]) and \(args[2])")
