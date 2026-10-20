import LumenCore
import SwiftUI
import UIKit

/// `--selftest` (ios/build.sh sim --selftest): LumenCore's shared checks inside the simulator's real
/// WKWebView, printed to the console; the app then quits with 0 when everything passed.
struct SelfTestView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> SelfTestController { SelfTestController() }
    func updateUIViewController(_ controller: SelfTestController, context: Context) {}
}

final class SelfTestController: UIViewController {
    var core: SelfTestCore?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard core == nil else { return }
        let core = SelfTestCore(frame: view.bounds) { [weak self] webView in
            self?.view.subviews.forEach { $0.removeFromSuperview() }
            self?.view.addSubview(webView)
        }
        self.core = core
        Task {
            _ = await core.runShared()
            print(core.failures == 0 ? "ALL PASSED" : "\(core.failures) FAILED")
            exit(core.failures == 0 ? 0 : 1)
        }
    }
}
