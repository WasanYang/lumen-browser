// Renders shared/Assets/logo.svg into a macOS .iconset (build.sh then runs iconutil).
// macOS icons leave a margin: on Apple's 1024 px grid the rounded square is 824 px, centred, so the
// logo (already a rounded square) is drawn at that size to match other icons in the Dock.
// Usage: swift make-icon.swift <logo.svg> <out.iconset>
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let logo = NSImage(contentsOf: URL(fileURLWithPath: args[1])) else {
    FileHandle.standardError.write("usage: swift make-icon.swift <logo.svg> <out.iconset>\n".data(using: .utf8)!)
    exit(1)
}
let out = URL(fileURLWithPath: args[2])
try? FileManager.default.removeItem(at: out)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
        let body = Double(pixels) * 824 / 1024
        let inset = (Double(pixels) - body) / 2
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        logo.draw(in: NSRect(x: inset, y: inset, width: body, height: body))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
    }
}
