// Renders the Switchboard app icon: indigo→purple gradient squircle
// with the switch.2 SF Symbol in white. Run via scripts/make-icon.sh.
import AppKit

let size: CGFloat = 1024
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/icon_1024.png"

func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
    let img = image.copy() as! NSImage
    img.lockFocus()
    color.set()
    NSRect(origin: .zero, size: img.size).fill(using: .sourceAtop)
    img.unlockFocus()
    img.isTemplate = false
    return img
}

let canvas = NSImage(size: NSSize(width: size, height: size))
canvas.lockFocus()

// macOS-style margins: the squircle sits inset from the canvas edge.
let inset = size * 0.095
let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let radius = rect.width * 0.235
let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

NSGraphicsContext.current?.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = size * 0.02
shadow.shadowOffset = NSSize(width: 0, height: -size * 0.008)
shadow.set()
NSColor(calibratedRed: 0.30, green: 0.29, blue: 0.78, alpha: 1).setFill()
squircle.fill()
NSGraphicsContext.current?.restoreGraphicsState()

NSGraphicsContext.current?.saveGraphicsState()
squircle.addClip()
NSGradient(colors: [
    NSColor(calibratedRed: 0.27, green: 0.27, blue: 0.82, alpha: 1),
    NSColor(calibratedRed: 0.55, green: 0.31, blue: 0.92, alpha: 1),
])!.draw(in: rect, angle: -55)
NSGraphicsContext.current?.restoreGraphicsState()

if let symbol = NSImage(systemSymbolName: "switch.2", accessibilityDescription: nil) {
    let config = NSImage.SymbolConfiguration(pointSize: 400, weight: .medium)
    let glyph = tinted(symbol.withSymbolConfiguration(config) ?? symbol, .white)
    let glyphSize = glyph.size
    let target = size * 0.50
    let scale = target / max(glyphSize.width, glyphSize.height)
    let drawSize = NSSize(width: glyphSize.width * scale, height: glyphSize.height * scale)
    let drawRect = NSRect(
        x: (size - drawSize.width) / 2,
        y: (size - drawSize.height) / 2,
        width: drawSize.width,
        height: drawSize.height
    )
    glyph.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
}

canvas.unlockFocus()

guard let tiff = canvas.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
else {
    fputs("failed to render icon\n", stderr)
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
