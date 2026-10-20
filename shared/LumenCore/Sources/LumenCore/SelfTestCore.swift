import Foundation
import WebKit

/// The self-test checks every platform runs inside a real WKWebView (each app adds its own, e.g. the
/// Mac's real skip click). Uses a throw-away data store, rule store, uBO folder and defaults, and test
/// pages; never the user's profile. Prints PASS/FAIL lines.
/// 1. With the blocker: ad URLs fail, normal URLs load, ad slots are hidden.
/// 2. Without it (control): every URL loads, so a failure in 1 is the blocker, not the network.
/// 3. uBO Lite: its scriptlets take the ad fields out of a fake YouTube page's player data.
/// 4. uBO update: the newest version downloads from GitHub into a temporary folder, complete.
@MainActor
public final class SelfTestCore: NSObject, WKNavigationDelegate {
    public private(set) var failures = 0
    /// Receives the page script's messages (ad start, skip) in the app's own handler.
    public let appRelay = ScriptMessageRelay()
    /// What a test page posts to `window.webkit.messageHandlers.selftest`.
    public var pageReport: [String: Any]?
    let pageRelay = ScriptMessageRelay()
    let frame: CGRect
    let place: (WKWebView) -> Void
    var loaded: CheckedContinuation<Void, Error>?

    /// `place` puts each test web view on screen (some WebKit work only runs in a window).
    public init(frame: CGRect, place: @escaping (WKWebView) -> Void) {
        self.frame = frame
        self.place = place
        super.init()
        pageRelay.onMessage = { [weak self] in self?.pageReport = $0.body as? [String: Any] }
    }

    public func check(_ ok: Bool, _ text: String) {
        print((ok ? "PASS  " : "FAIL  ") + text)
        if !ok { failures += 1 }
    }

    /// Runs phases 1–4 and returns the compiled rules for the app's own phases.
    public func runShared() async -> WKContentRuleList? {
        do {
            let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-selftest-rules")
            guard let store = WKContentRuleListStore(url: storeURL) else { throw TestError("no rule store") }
            let rules = try await AdBlock.compileRules(store: store)
            check(rules != nil, "blocklist compiled (\(AdBlock.blocklistURL()?.path ?? "not found"))")
            try await blockingPhase(rules: rules)
            try await uBOPhase(rules: rules)
            await updatePhase()
            return rules
        } catch {
            check(false, "self-test stopped: \(error)")
            return nil
        }
    }

    // MARK: Phases 1 and 2

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

    // MARK: Phase 3

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
        print("-- uBlock Origin Lite \(AdBlock.uBOCopy?.version ?? "missing")  \(AdBlock.uBOCopy?.folder.path ?? "")")
        check(AdBlock.uBOCopy.map { AdBlock.scripts(from: $0).count } == 2, "uBO scriptlets loaded for both worlds")
        let view = makeWebView(blocker: true, rules: rules)
        try await load(page, base: "https://www.youtube.com/watch?v=selftest", in: view)
        let report = try await view.callAsyncJavaScript("return window.__report;", contentWorld: .page) as? [String: Any]
        check(report?["adPlacements"] as? Bool == false && report?["playerAds"] as? Bool == false && report?["adSlots"] as? Bool == false,
              "ad fields removed from player data  \(report ?? [:])")
        check(report?["video"] as? Bool == true, "video data kept")
    }

    // MARK: Phase 4

    /// Downloads into a temporary store as if nothing were on the device, then checks the copy is
    /// complete, usable, and that a second check reports it as up to date.
    func updatePhase() async {
        print("-- uBlock Origin Lite update from GitHub")
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-selftest-ubol", isDirectory: true)
        try? FileManager.default.removeItem(at: store)
        defer { try? FileManager.default.removeItem(at: store) }
        // Its own defaults, so the test never changes what the app's update button shows.
        let defaults = UserDefaults(suiteName: "lumen-selftest")!
        defer { defaults.removePersistentDomain(forName: "lumen-selftest") }
        let first = await UBOLiteUpdater.update(store: store, have: nil, defaults: defaults)
        guard case let .downloaded(version) = first else { return check(false, "download newest version  \(first)") }
        check(true, "downloaded \(version)")
        let copy = UBOLite.copy(at: store.appendingPathComponent(version))
        check(copy?.version == version, "downloaded copy is complete  \(copy?.folder.path ?? "missing")")
        check(copy.map { AdBlock.scripts(from: $0).count } == 2, "downloaded scriptlets build scripts for both worlds")
        let second = await UBOLiteUpdater.update(store: store, have: version, defaults: defaults)
        check(second == .upToDate(version), "second check is up to date  \(second)")
    }

    // MARK: Helpers for every phase, also the app's own

    public func makeWebView(blocker: Bool, rules: WKContentRuleList?) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = []
        if blocker { AdBlock.attach(to: config, rules: rules, handler: appRelay) }
        config.userContentController.add(pageRelay, contentWorld: .page, name: "selftest")
        let view = WKWebView(frame: frame, configuration: config)
        view.navigationDelegate = self
        place(view)
        return view
    }

    public func load(_ html: String, base: String, in view: WKWebView) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            loaded = done
            view.loadHTMLString(html, baseURL: URL(string: base))
        }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.resume()
        loaded = nil
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(throwing: error)
        loaded = nil
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(throwing: error)
        loaded = nil
    }

    struct TestError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
