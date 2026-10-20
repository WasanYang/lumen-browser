// swift-tools-version:5.10
import PackageDescription

// Builds with the Command Line Tools alone (no Xcode). build.sh wraps the binary into Lumen.app.
let package = Package(
    name: "Lumen",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Lumen",
            path: "Sources/Lumen",
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("WebKit")]
        )
    ]
)
