import AppKit
import WebKit

/// `Lumen --selftest`: proves the blocker inside a real WKWebView, prints PASS/FAIL lines and
/// exits 0 when everything passes, 1 otherwise. Uses a throw-away data store, rule store and test
/// pages; never the user's profile.
/// 1. With the blocker: ad URLs fail, normal URLs load, ad slots are hidden.
/// 2. Without it (control): every URL loads, so a failure in 1 is the blocker, not the network.
/// 3. Skip click: a fake YouTube player shows a skip button. The real page script must report it,
///    the app must click it, and the page must see a trusted click while the ad is muted at 16x.
@MainActor
final class SelfTest: NSObject, WKNavigationDelegate {
    static var current: SelfTest?

    static func start() {
        let test = SelfTest()
        current = test
        Task { await test.run() }
    }

    static let shouldBlock = [
        "https://securepubads.g.doubleclick.net/tag/js/gpt.js",
        "https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js",
        "https://www.googleadservices.com/pagead/conversion.js",
        "https://c.amazon-adsystem.com/aax2/apstag.js",
        "https://www.youtube.com/pagead/viewthroughconversion/0/",
        "https://www.youtube.com/api/stats/ads?ver=2",
    ]
    static let shouldLoad = [
        "https://www.youtube.com/favicon.ico",
        "https://www.google.com/favicon.ico",
        "https://www.gstatic.com/generate_204",
        "https://i.ytimg.com/vi/dQw4w9WgXcQ/default.jpg",
    ]

    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                          styleMask: [.titled], backing: .buffered, defer: false)
    let appRelay = ScriptMessageRelay()
    let pageRelay = ScriptMessageRelay()
    var loaded: CheckedContinuation<Void, Error>?
    var appEvents: [AdBlock.Event] = []
    var pageReport: [String: Any]?
    var failures = 0

    func run() async {
        window.title = "Lumen self-test"
        window.center()
        window.makeKeyAndOrderFront(nil)
        appRelay.onMessage = { [weak self] in if let event = AdBlock.handle($0) { self?.appEvents.append(event) } }
        pageRelay.onMessage = { [weak self] in self?.pageReport = $0.body as? [String: Any] }
        do {
            let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("minibrowser-selftest-rules")
            guard let store = WKContentRuleListStore(url: storeURL) else { throw TestError("no rule store") }
            let rules = try await AdBlock.compileRules(store: store)
            check(rules != nil, "blocklist compiled (\(AdBlock.blocklistURL()?.path ?? "not found"))")
            try await blockingPhase(rules: rules)
            try await uBOPhase(rules: rules)
            try await skipPhase(rules: rules, hidden: false)
            // The usual case: YouTube plays in the background while another app is in front.
            try await skipPhase(rules: rules, hidden: true)
        } catch {
            check(false, "self-test stopped: \(error)")
        }
        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: Phases 1 and 2

    func blockingPhase(rules: WKContentRuleList?) async throws {
        let page = #"<html><body><ins class="adsbygoogle" style="display:block;width:10px;height:10px"></ins></body></html>"#
        let base = "https://selftest.invalid/"

        let control = makeWebView(blocker: false, rules: nil)
        try await load(page, base: base, in: control)
        let without = try await probe(control)

        let blocked = makeWebView(blocker: true, rules: rules)
        try await load(page, base: base, in: blocked)
        let with = try await probe(blocked)

        print("-- network (with blocker | without)")
        for url in Self.shouldBlock {
            check(with[url] == "failed" && without[url] == "loaded",
                  "blocked   \(url)  [\(with[url] ?? "-") | \(without[url] ?? "-")]")
        }
        for url in Self.shouldLoad {
            check(with[url] == "loaded" && without[url] == "loaded",
                  "allowed   \(url)  [\(with[url] ?? "-") | \(without[url] ?? "-")]")
        }
        print("-- page CSS")
        check(with["__slot"] == "none" && without["__slot"] != "none",
              "ad slot hidden  [\(with["__slot"] ?? "-") | \(without["__slot"] ?? "-")]")
    }

    func probe(_ view: WKWebView) async throws -> [String: String] {
        let js = """
            const out = {};
            await Promise.all(urls.map(async (u) => {
              const ctl = new AbortController();
              const timer = setTimeout(() => ctl.abort(), 15000);
              try { await fetch(u, { mode: 'no-cors', cache: 'no-store', signal: ctl.signal }); out[u] = 'loaded'; }
              catch (e) { out[u] = e.name === 'AbortError' ? 'timeout' : 'failed'; }
              clearTimeout(timer);
            }));
            out.__slot = getComputedStyle(document.querySelector('ins.adsbygoogle')).display;
            return out;
            """
        let result = try await view.callAsyncJavaScript(js, arguments: ["urls": Self.shouldBlock + Self.shouldLoad],
                                                        contentWorld: .page)
        return result as? [String: String] ?? [:]
    }

    // MARK: uBO Lite

    /// A fake YouTube watch page sets player data with ads in it, the way YouTube's own page does.
    /// uBO's scriptlets must take the ad fields out before the page reads them back.
    func uBOPhase(rules: WKContentRuleList?) async throws {
        let page = """
            <html><body><script>
              window.ytInitialPlayerResponse = { adPlacements: [1], playerAds: [1], adSlots: [1], videoDetails: { videoId: 'x' } };
              const r = window.ytInitialPlayerResponse || {};
              // uBO's set-constant leaves the keys but makes them undefined.
              window.__report = { adPlacements: r.adPlacements !== undefined, playerAds: r.playerAds !== undefined,
                                  adSlots: r.adSlots !== undefined, video: !!r.videoDetails };
            </script></body></html>
            """
        print("-- uBlock Origin Lite \(AdBlock.uBOVersion() ?? "missing")")
        check(AdBlock.uBOScripts().count == 2, "uBO scriptlets loaded for both worlds")
        let view = makeWebView(blocker: true, rules: rules)
        try await load(page, base: "https://www.youtube.com/watch?v=selftest", in: view)
        let report = try await view.callAsyncJavaScript("return window.__report;", contentWorld: .page) as? [String: Any]
        check(report?["adPlacements"] as? Bool == false && report?["playerAds"] as? Bool == false && report?["adSlots"] as? Bool == false,
              "ad fields removed from player data  \(report ?? [:])")
        check(report?["video"] as? Bool == true, "video data kept")
    }

    // MARK: Phase 3

    func skipPhase(rules: WKContentRuleList?, hidden: Bool) async throws {
        appEvents = []
        pageReport = nil
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
        let view = makeWebView(blocker: true, rules: rules)
        try await load(page, base: "https://www.youtube.com/selftest", in: view)
        for _ in 0..<80 where pageReport == nil { try await Task.sleep(for: .milliseconds(100)) }
        try await Task.sleep(for: .milliseconds(600)) // let the script undo mute and 16x
        let after = try await view.callAsyncJavaScript(
            "const v = document.querySelector('video'); return { muted: v.muted, rate: v.playbackRate };",
            contentWorld: .page) as? [String: Any]

        print(hidden ? "-- YouTube skip, app hidden" : "-- YouTube skip, window in front")
        check(appEvents.contains(.adStart), "app was told an ad started")
        check(appEvents.contains(.skipClicked), "app clicked the skip button")
        check(pageReport != nil, "skip button received the click")
        check(pageReport?["trusted"] as? Bool == true, "click was trusted (isTrusted = true)")
        check(pageReport?["muted"] as? Bool == true, "ad was muted during the ad")
        check((pageReport?["rate"] as? NSNumber)?.doubleValue == 16, "ad ran at 16x")
        check(after?["muted"] as? Bool == false && (after?["rate"] as? NSNumber)?.doubleValue == 1,
              "sound and speed restored after the ad  \(after ?? [:])")
    }

    // MARK: Helpers

    func makeWebView(blocker: Bool, rules: WKContentRuleList?) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = []
        if blocker { AdBlock.attach(to: config, rules: rules, handler: appRelay) }
        config.userContentController.add(pageRelay, contentWorld: .page, name: "selftest")
        let view = WKWebView(frame: window.contentLayoutRect, configuration: config)
        view.navigationDelegate = self
        window.contentView = view
        return view
    }

    func load(_ html: String, base: String, in view: WKWebView) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            loaded = done
            view.loadHTMLString(html, baseURL: URL(string: base))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.resume()
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(throwing: error)
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(throwing: error)
        loaded = nil
    }

    func check(_ ok: Bool, _ text: String) {
        print((ok ? "PASS  " : "FAIL  ") + text)
        if !ok { failures += 1 }
    }

    struct TestError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
