import AVFoundation
import SwiftUI

@main
struct LumenApp: App {
    init() {
        // With UIBackgroundModes audio, this keeps music playing when the screen locks or another app
        // is in front, and puts it on the lock screen controls.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
    }

    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("--selftest") {
                SelfTestView().ignoresSafeArea()
            } else {
                BrowserView().ignoresSafeArea(.container, edges: .bottom)
            }
        }
    }
}

struct BrowserView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> BrowserViewController { BrowserViewController() }
    func updateUIViewController(_ controller: BrowserViewController, context: Context) {}
}
