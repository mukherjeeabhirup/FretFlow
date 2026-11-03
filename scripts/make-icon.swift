import AppKit
import Foundation

// Use the exact native symbol and purple tint already shown in FretFlow's sidebar.
// Render at each icon resolution from the vector symbol, without scaling a screenshot.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let output = root.appendingPathComponent(".build/FretFlow.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let purple = NSColor(srgbRed: 0.43, green: 0.35, blue: 0.88, alpha: 1)
let background = NSColor(srgbRed: 0.12, green: 0.12, blue: 0.12, alpha: 1)
guard let original = NSImage(systemSymbolName: "guitars.fill", accessibilityDescription: "FretFlow guitars") else {
    fatalError("The FretFlow guitar symbol is unavailable.")
}
let configuration = NSImage.SymbolConfiguration(pointSize: 700, weight: .regular)
    .applying(NSImage.SymbolConfiguration(paletteColors: [purple]))
let symbol = original.withSymbolConfiguration(configuration)!
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot render icon") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let factor = CGFloat(pixels) / 1024
        context.cgContext.scaleBy(x: factor, y: factor)
        background.setFill()
        NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 200, yRadius: 200).fill()
        let ratio = symbol.size.width / symbol.size.height
        let width: CGFloat = 650
        let height = width / ratio
        symbol.draw(in: NSRect(x: (1024-width)/2, y: (1024-height)/2, width: width, height: height),
            from: .zero, operation: .sourceOver, fraction: 1)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let data = bitmap.representation(using: .png, properties: [:])!
        try data.write(to: output.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
