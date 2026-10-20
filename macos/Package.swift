// swift-tools-version:5.10
import PackageDescription

// Builds with the Command Line Tools alone (no Xcode). build.sh wraps the binary into Lumen.app.
// Ad blocking lives in ../shared/LumenCore, shared with the iPhone/iPad app.
let package = Package(
    name: "Lumen",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../shared/LumenCore")],
    targets: [
        .executableTarget(
            name: "Lumen",
            dependencies: [.product(name: "LumenCore", package: "LumenCore")],
            path: "Sources/Lumen",
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("WebKit")]
        )
    ]
)
