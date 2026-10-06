// Renders AppIcon.iconset PNGs: usage `swift tools/make-icon.swift <out.iconset>`
import AppKit

let out = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)

    // Standard macOS icon grid: 824pt body on a 1024pt canvas.
    let inset = s * 100 / 1024
    let radius = s * 185 / 1024
    let body = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset),
                            xRadius: radius, yRadius: radius)
    NSGradient(starting: NSColor(srgbRed: 1, green: 0.2, blue: 0.2, alpha: 1),
               ending: NSColor(srgbRed: 0.75, green: 0, blue: 0.05, alpha: 1))!.draw(in: body, angle: -90)

    let c = s / 2
    let ringRadius = s * 0.24
    let ring = NSBezierPath(ovalIn: NSRect(x: c - ringRadius, y: c - ringRadius, width: 2 * ringRadius, height: 2 * ringRadius))
    ring.lineWidth = s * 0.035
    NSColor.white.setStroke()
    ring.stroke()

    let t = s * 0.11
    let play = NSBezierPath()
    play.move(to: NSPoint(x: c - t * 0.6, y: c - t))
    play.line(to: NSPoint(x: c - t * 0.6, y: c + t))
    play.line(to: NSPoint(x: c + t, y: c))
    play.close()
    NSColor.white.setFill()
    play.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base).png"))
    try render(base * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base)@2x.png"))
}
