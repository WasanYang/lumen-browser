import AppKit
import LumenCore
import WebKit

/// `Lumen --selftest`: LumenCore's shared checks (blocking, uBO pruning, uBO download), then the Mac's
/// own: a fake YouTube player shows a skip button, the real page script must report it, the app must
/// click it, and the page must see a trusted click while the ad is muted at 16x — with the window in
/// front and with the app hidden. Prints PASS/FAIL lines and exits 0 when everything passes, 1 otherwise.
@MainActor
enum SelfTest {
    static var core: SelfTestCore?

    static func start() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Lumen self-test"
        window.center()
        window.makeKeyAndOrderFront(nil)
        let core = SelfTestCore(frame: window.contentLayoutRect) { window.contentView = $0 }
        self.core = core
        var appEvents: [String] = []
        core.appRelay.onMessage = { message in
            switch AdBlock.handle(message) {
            case .adStart:
                appEvents.append("ad-start")
            case let .skip(x, y):
                guard let view = message.webView else { return }
                appEvents.append(PageClick.realClick(in: view, x: x, y: y) ? "clicked" : "missed")
            case nil:
                break
            }
        }
        Task {
            let rules = await core.runShared()
            for hidden in [false, true] { // hidden: YouTube plays while another app is in front
                appEvents = []
                do {
                    try await skipPhase(core, rules: rules, hidden: hidden) { appEvents }
                } catch {
                    core.check(false, "skip phase stopped: \(error)")
                }
            }
            print(core.failures == 0 ? "ALL PASSED" : "\(core.failures) FAILED")
            exit(core.failures == 0 ? 0 : 1)
        }
    }

    static func skipPhase(_ core: SelfTestCore, rules: WKContentRuleList?, hidden: Bool,
                          events: () -> [String]) async throws {
        core.pageReport = nil
        if hidden { NSApp.hide(nil) }
        defer { if hidden { NSApp.unhide(nil) } }
        let page = """
            <html><body style="margin:0;background:#111">
            <div id="movie_player" class="ad-showing" style="position:relative;width:640px;height:360px;background:#000">
              <video></video>
              <button class="ytp-skip-ad-button" style="position:absolute;left:420px;top:290px;width:160px;height:44px">Skip</button>
            </div>
            <script>
              const v = document.querySelector('video');
              document.querySelector('.ytp-skip-ad-button').addEventListener('click', (e) => {
                window.webkit.messageHandlers.selftest.postMessage({ trusted: e.isTrusted, muted: v.muted, rate: v.playbackRate });
                document.getElementById('movie_player').classList.remove('ad-showing');
              });
            </script>
            </body></html>
            """
        let view = core.makeWebView(blocker: true, rules: rules)
        try await core.load(page, base: "https://www.youtube.com/selftest", in: view)
        for _ in 0..<80 where core.pageReport == nil { try await Task.sleep(for: .milliseconds(100)) }
        try await Task.sleep(for: .milliseconds(600)) // let the script undo mute and 16x
        let after = try await view.callAsyncJavaScript(
            "const v = document.querySelector('video'); return { muted: v.muted, rate: v.playbackRate };",
            contentWorld: .page) as? [String: Any]

        let report = core.pageReport
        print(hidden ? "-- YouTube skip, app hidden" : "-- YouTube skip, window in front")
        core.check(events().contains("ad-start"), "app was told an ad started")
        core.check(events().contains("clicked"), "app clicked the skip button")
        core.check(report != nil, "skip button received the click")
        core.check(report?["trusted"] as? Bool == true, "click was trusted (isTrusted = true)")
        core.check(report?["muted"] as? Bool == true, "ad was muted during the ad")
        core.check((report?["rate"] as? NSNumber)?.doubleValue == 16, "ad ran at 16x")
        core.check(after?["muted"] as? Bool == false && (after?["rate"] as? NSNumber)?.doubleValue == 1,
                   "sound and speed restored after the ad  \(after ?? [:])")
    }
}
