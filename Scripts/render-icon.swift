#!/usr/bin/env swift
// Development/build tooling only. The shipped app loads the PDF directly.
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let fm = FileManager.default
let arguments = CommandLine.arguments.dropFirst()
let output = arguments.first(where: { $0 != "--preview" }).map { URL(fileURLWithPath: $0) }
    ?? root.appendingPathComponent(".build/AppIcon.icns")
guard let glyph = NSImage(contentsOf: root.appendingPathComponent("Sources/SuperTrackpad/Resources/Toolbelt.pdf")) else {
    fatalError("Missing Toolbelt.pdf")
}
let graphite = NSColor(srgbRed: 48/255, green: 47/255, blue: 43/255, alpha: 1)
let ivory = NSColor(srgbRed: 250/255, green: 248/255, blue: 243/255, alpha: 1)
func bitmap(width: Int, height: Int, draw: () -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
func drawGlyph(in rect: NSRect, color: NSColor) {
    // Tint a transparent PDF offscreen so source-in cannot affect the tile beneath.
    let tinted = NSImage(size: rect.size)
    tinted.lockFocus()
    glyph.draw(in: NSRect(origin: .zero, size: rect.size))
    color.setFill()
    NSRect(origin: .zero, size: rect.size).fill(using: .sourceIn)
    tinted.unlockFocus()
    tinted.draw(in: rect)
}
func drawAppIcon(size: CGFloat, origin: NSPoint = .zero) {
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by: origin.x, yBy: origin.y)
    transform.scale(by: size / 1024)
    transform.concat()
    graphite.setFill()
    NSBezierPath(roundedRect: NSRect(x: 70, y: 70, width: 884, height: 884), xRadius: 196, yRadius: 196).fill()
    // Matches the approved pouch composition: a 24-unit glyph in a 180-unit tile.
    drawGlyph(in: NSRect(x: 276.27, y: 276.27, width: 471.46, height: 471.46), color: ivory)
    NSGraphicsContext.restoreGraphicsState()
}
let iconset = root.appendingPathComponent(".build/AppIcon.iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        try bitmap(width: pixels, height: pixels) { drawAppIcon(size: CGFloat(pixels)) }
            .write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"))
    }
}
try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try task.run(); task.waitUntilExit()
guard task.terminationStatus == 0 else { exit(task.terminationStatus) }
if arguments.contains("--preview") {
    let preview = root.appendingPathComponent(".build/AppIcon-preview.png")
    try fm.createDirectory(at: preview.deletingLastPathComponent(), withIntermediateDirectories: true)
    try bitmap(width: 900, height: 360) {
        ivory.setFill(); NSRect(x: 0, y: 0, width: 900, height: 360).fill()
        drawAppIcon(size: 300, origin: NSPoint(x: 10, y: 30))
        for (y, background, foreground, title) in [
            (CGFloat(205), ivory, graphite, "Light menu bar"),
            (CGFloat(85), graphite, ivory, "Dark menu bar")
        ] {
            background.setFill(); NSRect(x: 355, y: y, width: 500, height: 70).fill()
            for (x, size) in [(CGFloat(390), CGFloat(18)), (CGFloat(450), CGFloat(24))] {
                drawGlyph(in: NSRect(x: x, y: y + (70-size)/2, width: size, height: size), color: foreground)
            }
            (title as NSString).draw(at: NSPoint(x: 525, y: y+24), withAttributes: [.font: NSFont.systemFont(ofSize: 17), .foregroundColor: foreground])
        }
    }.write(to: preview)
}
print("Rendered \(output.path)")
