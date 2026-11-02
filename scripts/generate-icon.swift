import AppKit
import Foundation

// Deterministic, original artwork. No external image assets or user screenshots.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("assets")
let iconset = root.appendingPathComponent(".local/AppIcon.iconset")
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
}

func render(_ pixels: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 196, yRadius: 196)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowBlurRadius = 22
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    color(0.06, 0.22, 0.63).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0.16, 0.43, 0.98), ending: color(0.08, 0.20, 0.61))!.draw(in: tile, angle: -65)

    // Crop corners surround the bilingual cards.
    let corners = NSBezierPath()
    corners.lineWidth = 19
    corners.lineCapStyle = .round
    corners.lineJoinStyle = .round
    for (x, y, dx, dy) in [(214.0, 804.0, 100.0, -100.0), (810.0, 804.0, -100.0, -100.0),
                            (214.0, 220.0, 100.0, 100.0), (810.0, 220.0, -100.0, 100.0)] {
        corners.move(to: NSPoint(x: x, y: y + dy))
        corners.line(to: NSPoint(x: x, y: y))
        corners.line(to: NSPoint(x: x + dx, y: y))
    }
    NSColor.white.withAlphaComponent(0.65).setStroke()
    corners.stroke()

    func card(_ rect: NSRect, fill: NSColor, text: String, ink: NSColor, fontSize: CGFloat) {
        let shape = NSBezierPath(roundedRect: rect, xRadius: 54, yRadius: 54)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = color(0.02, 0.10, 0.32).withAlphaComponent(0.30)
        shadow.shadowBlurRadius = 22
        shadow.shadowOffset = NSSize(width: 0, height: -14)
        shadow.set()
        fill.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2 + 6), withAttributes: attributes)
    }
    card(NSRect(x: 256, y: 428, width: 330, height: 320), fill: color(0.94, 0.98, 1),
         text: "A", ink: color(0.13, 0.30, 0.72), fontSize: 220)
    card(NSRect(x: 440, y: 280, width: 330, height: 320), fill: color(0.56, 0.96, 0.85),
         text: "가", ink: color(0.04, 0.23, 0.35), fontSize: 202)
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

try render(1024).write(to: assets.appendingPathComponent("AppIcon.png"))
for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", assets.appendingPathComponent("AppIcon.icns").path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Generated assets/AppIcon.png and assets/AppIcon.icns")
