// Draws the app icon from the design (a teal rounded square with white
// waves) into an .iconset folder. Run by bundle.sh; needs no assets.
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)

func draw(size: Int) -> Data? {
    let pixels = CGFloat(size)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: the shape fills about 80% of the canvas.
    let inset = pixels * 0.1
    let shape = NSRect(x: inset, y: inset, width: pixels - 2 * inset, height: pixels - 2 * inset)
    NSColor(red: 0x0E / 255, green: 0x5E / 255, blue: 0x6F / 255, alpha: 1).setFill()
    NSBezierPath(roundedRect: shape, xRadius: shape.width * 0.225, yRadius: shape.width * 0.225).fill()

    let configuration = NSImage.SymbolConfiguration(pointSize: shape.width * 0.5, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let waves = NSImage(systemSymbolName: "water.waves", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) {
        let box = waves.size
        waves.draw(in: NSRect(x: shape.midX - box.width / 2, y: shape.midY - box.height / 2,
                              width: box.width, height: box.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try draw(size: base * scale)?.write(to: URL(fileURLWithPath: "\(output)/\(name)"))
    }
}
