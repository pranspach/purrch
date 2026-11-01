// Regenerates Resources/AppIcon.icns: swift scripts/make-icon.swift
import AppKit

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Purrch.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data {
    let side = CGFloat(pixels)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

    let inset = side * 0.1
    let rect = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    NSColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1).setFill()
    NSBezierPath(roundedRect: rect, xRadius: side * 0.18, yRadius: side * 0.18).fill()

    let config = NSImage.SymbolConfiguration(pointSize: side * 0.46, weight: .regular)
        .applying(.init(paletteColors: [NSColor(red: 1, green: 0.62, blue: 0.04, alpha: 1)]))
    let paw = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
    paw.draw(in: NSRect(x: (side - paw.size.width) / 2, y: (side - paw.size.height) / 2, width: paw.size.width, height: paw.size.height))

    NSGraphicsContext.current = nil
    return bitmap.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    try render(points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try process.run()
process.waitUntilExit()
print(process.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
