// Renders the app icon PNG: swift make_icon.swift <out.png> <size>
import AppKit

let args = CommandLine.arguments
let out = args[1]
let size = CGFloat(Double(args[2]) ?? 1024)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let inset = size * 0.1
let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
NSGradient(colors: [NSColor(calibratedRed: 0.42, green: 0.27, blue: 0.86, alpha: 1),
                    NSColor(calibratedRed: 0.10, green: 0.68, blue: 0.70, alpha: 1)])!
    .draw(in: path, angle: -60)
let config = NSImage.SymbolConfiguration(pointSize: rect.width * 0.5, weight: .semibold)
    .applying(.init(paletteColors: [.white]))
if let sym = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
    let s = sym.size
    sym.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
