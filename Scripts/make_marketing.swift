// Builds README / social images from app screenshots.
// Usage: swift Scripts/make_marketing.swift hero <screenshot.png> <out.png>
//        swift Scripts/make_marketing.swift social <screenshot.png> <icon.png> <out.png>
//        swift Scripts/make_marketing.swift frame <screenshot.png> <out.png>
import AppKit

let purple = NSColor(calibratedRed: 0.42, green: 0.27, blue: 0.86, alpha: 1)
let teal = NSColor(calibratedRed: 0.10, green: 0.68, blue: 0.70, alpha: 1)
let night = NSColor(calibratedRed: 0.07, green: 0.06, blue: 0.13, alpha: 1)

func canvas(_ w: Int, _ h: Int, _ draw: (NSRect) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    draw(NSRect(x: 0, y: 0, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func background(_ r: NSRect) {
    NSGradient(colors: [night, NSColor(calibratedRed: 0.13, green: 0.09, blue: 0.27, alpha: 1), night])!.draw(in: r, angle: -90)
    // soft glows
    for (c, x, y, rad) in [(purple, 0.2, 0.85, 0.55), (teal, 0.85, 0.2, 0.5)] {
        let center = NSPoint(x: r.width * x, y: r.height * y)
        let g = NSGradient(colors: [c.withAlphaComponent(0.45), c.withAlphaComponent(0)])!
        g.draw(fromCenter: center, radius: 0, toCenter: center, radius: max(r.width, r.height) * rad, options: [])
    }
}

func drawShot(_ img: NSImage, in rect: NSRect, radius: CGFloat) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
    shadow.shadowBlurRadius = rect.width * 0.03
    shadow.shadowOffset = NSSize(width: 0, height: -rect.width * 0.012)
    shadow.set()
    NSColor.black.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
    img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.withAlphaComponent(0.12).setStroke()
    let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
    border.lineWidth = 1.5
    border.stroke()
}

func fit(_ size: NSSize, width: CGFloat) -> NSSize {
    NSSize(width: width, height: width * size.height / size.width)
}

func save(_ rep: NSBitmapImageRep, _ path: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, at p: NSPoint) {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let rounded = font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? font
    NSAttributedString(string: s, attributes: [.font: rounded, .foregroundColor: color]).draw(at: p)
}

let a = CommandLine.arguments
switch a[1] {
case "hero":
    let shot = NSImage(contentsOfFile: a[2])!
    let w = 2400, pad: CGFloat = 150
    let s = fit(shot.size, width: CGFloat(w) - pad * 2)
    let h = Int(s.height + pad * 2)
    save(canvas(w, h) { r in
        background(r)
        drawShot(shot, in: NSRect(x: pad, y: pad, width: s.width, height: s.height), radius: 26)
    }, a[3])
case "frame":
    let shot = NSImage(contentsOfFile: a[2])!
    let pad: CGFloat = 70
    let s = fit(shot.size, width: 1600)
    save(canvas(Int(s.width + pad * 2), Int(s.height + pad * 2)) { r in
        background(r)
        drawShot(shot, in: NSRect(x: pad, y: pad, width: s.width, height: s.height), radius: 18)
    }, a[3])
case "social":
    let shot = NSImage(contentsOfFile: a[2])!
    let icon = NSImage(contentsOfFile: a[3])!
    save(canvas(1280, 640) { r in
        background(r)
        icon.draw(in: NSRect(x: 60, y: 380, width: 150, height: 150))
        text("FlashMac", size: 76, weight: .bold, color: .white, at: NSPoint(x: 72, y: 270))
        text("Give Your Mac Room to Fly", size: 30, weight: .medium, color: NSColor.white.withAlphaComponent(0.8), at: NSPoint(x: 76, y: 220))
        text("Free · Native · Clean, Uninstall, Optimize", size: 22, weight: .regular, color: NSColor.white.withAlphaComponent(0.55), at: NSPoint(x: 76, y: 178))
        let s = fit(shot.size, width: 700)
        drawShot(shot, in: NSRect(x: 640, y: (640 - s.height) / 2 - 10, width: s.width, height: s.height), radius: 14)
    }, a[4])
default:
    fatalError("unknown mode")
}
