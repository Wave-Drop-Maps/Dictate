import AppKit
// Draws the SpeakFn icon: a deep indigo→violet rounded square with a white voice waveform and a red "live" dot.
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
// macOS icon grid: artwork inset ~10%, corner radius ~22.5% of the artwork.
let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: size - 2*inset, height: size - 2*inset)
let radius = rect.width * 0.225
// soft drop shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
let bg = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
NSColor.black.setFill(); bg.fill()
ctx.restoreGState()
// gradient fill
bg.addClip()
let grad = NSGradient(colors: [NSColor(red: 0.13, green: 0.10, blue: 0.36, alpha: 1),
                               NSColor(red: 0.36, green: 0.20, blue: 0.86, alpha: 1),
                               NSColor(red: 0.62, green: 0.36, blue: 0.98, alpha: 1)],
                      atLocations: [0, 0.6, 1], colorSpace: .sRGB)!
grad.draw(in: rect, angle: 65)
// subtle top highlight
let hi = NSGradient(colors: [NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0)])!
hi.draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height/2), angle: -90)
// waveform bars
let heights: [CGFloat] = [0.22, 0.42, 0.68, 0.92, 0.62, 0.80, 0.46, 0.28]
let barW: CGFloat = 58, gap: CGFloat = 30
let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
var x = (size - total) / 2
let maxH: CGFloat = 470
let cy = size / 2 - 10
NSColor.white.setFill()
for h in heights {
    let bh = maxH * h
    NSBezierPath(roundedRect: NSRect(x: x, y: cy - bh/2, width: barW, height: bh), xRadius: barW/2, yRadius: barW/2).fill()
    x += barW + gap
}
// red live dot, top-right
let dot = NSRect(x: rect.maxX - 190, y: rect.maxY - 190, width: 92, height: 92)
NSColor.white.withAlphaComponent(0.95).setFill()
NSBezierPath(ovalIn: dot.insetBy(dx: -10, dy: -10)).fill()
NSColor(red: 1.0, green: 0.27, blue: 0.30, alpha: 1).setFill()
NSBezierPath(ovalIn: dot).fill()
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
