// Renders logo.svg into app icons. Usage:
//   swift make-icon.swift mac <logo.svg> <out.iconset>   (macos/build.sh then runs iconutil)
//   swift make-icon.swift ios <logo.svg> <out.png>       (one 1024 px icon for the asset catalog)
// Mac: icons leave a margin; on Apple's 1024 px grid the rounded square is 824 px, centred, so the logo
// (already a rounded square) is drawn at that size to match other icons in the Dock.
// iOS: the system rounds the corners itself, so the icon is the logo's background edge to edge
// (its rounded corners removed) and fully opaque.
import AppKit

let args = CommandLine.arguments
guard args.count == 4, ["mac", "ios"].contains(args[1]), var svg = try? String(contentsOfFile: args[2], encoding: .utf8) else {
    FileHandle.standardError.write("usage: swift make-icon.swift mac|ios <logo.svg> <out>\n".data(using: .utf8)!)
    exit(1)
}
let ios = args[1] == "ios"
if ios { svg = svg.replacingOccurrences(of: #" rx="112""#, with: "") }
guard let logo = NSImage(data: Data(svg.utf8)) else { exit(1) }
let out = URL(fileURLWithPath: args[3])

func render(pixels: Int, margin: Bool) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let body = margin ? Double(pixels) * 824 / 1024 : Double(pixels)
    let inset = (Double(pixels) - body) / 2
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    logo.draw(in: NSRect(x: inset, y: inset, width: body, height: body))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

if ios {
    try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
    try render(pixels: 1024, margin: false).representation(using: .png, properties: [:])!.write(to: out)
} else {
    try? FileManager.default.removeItem(at: out)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
            try render(pixels: points * scale, margin: true).representation(using: .png, properties: [:])!
                .write(to: out.appendingPathComponent(name))
        }
    }
}
