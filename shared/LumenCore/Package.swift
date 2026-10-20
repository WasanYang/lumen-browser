// swift-tools-version:5.10
import PackageDescription

// Ad blocking shared by the Mac app (macos/) and the iPhone/iPad app (ios/). No AppKit or UIKit here:
// what needs one (the real click on YouTube's skip button) stays in each app.
let package = Package(
    name: "LumenCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "LumenCore", targets: ["LumenCore"])],
    targets: [
        .target(name: "LumenCore", path: "Sources/LumenCore", linkerSettings: [.linkedFramework("WebKit")])
    ]
)
