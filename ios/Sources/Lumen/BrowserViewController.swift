import LumenCore
import UIKit
import WebKit

/// YouTube full screen with a Safari-style floating bar (FloatingBar): back, the site name and a ⋯ menu
/// with forward, reload, home, the uBO update and the ad counter. The ⋯ button shows a green dot when
/// GitHub has a newer uBO Lite. iPhone gets m.youtube.com; iPad asks for the desktop site like Safari on iPad.
final class BrowserViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    static let homeURL = URL(string: "https://www.youtube.com")!

    var webView: WKWebView?
    let relay = ScriptMessageRelay()
    let bar = FloatingBar()
    var adsSeen = 0
    var observations: [NSKeyValueObservation] = []
    /// Scroll distance in one direction since it last changed, for collapsing the bar like Safari.
    private var lastOffset: CGFloat = 0
    private var travel: CGFloat = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .black
        setUpBar()
        relay.onMessage = { [weak self] in self?.handle($0) }
        Task {
            let rules = try? await AdBlock.compileRules()
            makeWebView(rules: rules)
            await checkForUBOUpdate()
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task {
                await self?.disarmResume()
                await self?.checkForUBOUpdate()
            }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { await self?.rememberPlaying() }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { await self?.resumeInBackground() }
        }
    }

    // MARK: Background play

    /// WebKit itself pauses a playing <video> when the app goes to the background or the screen locks
    /// (measured in the simulator: no pause() call from the page, only the pause event). With the
    /// playback audio session the app may play on, so the video is started again:
    /// 1. at once, by backgroundPlayScript, which the app arms from the moment it stops being active
    ///    until 3 s after it is in the background (waiting 0.3 s first left a short gap in the sound
    ///    that the owner heard; now about 0.05 s in the simulator). The two moments can be seconds
    ///    apart, e.g. in the app switcher;
    /// 2. as a fallback, from resumeInBackground below.
    private var wasPlaying = false

    private func disarmResume() async {
        _ = try? await webView?.callAsyncJavaScript("window.__lumenLeavingUntil = 0;", contentWorld: .page)
    }

    private func rememberPlaying() async {
        let playing = try? await webView?.callAsyncJavaScript("""
            const v = document.querySelector('video');
            const playing = !!v && !v.paused && !v.ended;
            if (playing) window.__lumenLeavingUntil = Number.MAX_SAFE_INTEGER;
            return playing;
            """, contentWorld: .page)
        wasPlaying = playing as? Bool ?? false
    }

    private func resumeInBackground() async {
        guard wasPlaying, let webView else { return }
        _ = try? await webView.callAsyncJavaScript("window.__lumenLeavingUntil = Date.now() + 3000;", contentWorld: .page)
        for delay in [0.3, 1.0, 2.0] {
            try? await Task.sleep(for: .seconds(delay))
            let playing = try? await webView.callAsyncJavaScript("""
                const v = document.querySelector('video');
                if (!v) return false;
                if (v.paused) { try { await v.play(); } catch (e) {} }
                return !v.paused;
                """, contentWorld: .page)
            if playing as? Bool == true { return }
        }
    }

    private func makeWebView(rules: WKContentRuleList?) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default() // keeps logins across restarts
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = true
        // So Google sign-in sees Safari. iPad gets the desktop site, so it says desktop Safari.
        config.applicationNameForUserAgent = traitCollection.userInterfaceIdiom == .pad
            ? "Version/26.0 Safari/605.1.15" : "Version/26.0 Mobile/15E148 Safari/604.1"
        AdBlock.attach(to: config, rules: rules, handler: relay)
        config.userContentController.addUserScript(WKUserScript(source: Self.backgroundPlayScript,
                                                                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isInspectable = true // Safari on the Mac → Develop menu
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(webView, belowSubview: bar)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bar.topAnchor),
        ])
        observations = [
            webView.observe(\.canGoBack, options: .initial) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.bar.backButton.isEnabled = view.canGoBack }
            },
            webView.observe(\.url, options: .initial) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.bar.titleLabel.text = Self.siteName(view.url) }
            },
            webView.scrollView.observe(\.contentOffset) { [weak self] scrollView, _ in
                MainActor.assumeIsolated { self?.scrolled(scrollView) }
            },
        ]
        self.webView = webView
        webView.load(URLRequest(url: Self.homeURL))
    }

    /// YouTube pauses a video when the page says it is hidden (screen locked, another app in front), so
    /// the page stays "visible" on YouTube. And while the app is leaving the screen (armed by
    /// rememberPlaying), a pause that no page script asked for is WebKit's own background pause: play on
    /// at once. A pause from the lock screen button goes through YouTube's script, so it is respected,
    /// and outside those 3 s (a call, another music app) nothing is resumed.
    static let backgroundPlayScript = """
        (() => {
          if (!/(^|\\.)youtube\\.com$/.test(location.hostname)) return;
          let scriptPauseAt = 0;
          const pause = HTMLMediaElement.prototype.pause;
          HTMLMediaElement.prototype.pause = function () { scriptPauseAt = Date.now(); return pause.apply(this, arguments); };
          document.addEventListener('pause', (e) => {
            const media = e.target;
            if (!(media instanceof HTMLMediaElement)) return;
            if (Date.now() > (window.__lumenLeavingUntil || 0) || Date.now() - scriptPauseAt < 500) return;
            media.play().catch(() => {});
          }, true);
          for (const [name, value] of [['hidden', false], ['webkitHidden', false],
                                       ['visibilityState', 'visible'], ['webkitVisibilityState', 'visible']]) {
            Object.defineProperty(Document.prototype, name, { get: () => value, configurable: true });
          }
          for (const type of ['visibilitychange', 'webkitvisibilitychange']) {
            window.addEventListener(type, (e) => e.stopImmediatePropagation(), true);
            document.addEventListener(type, (e) => e.stopImmediatePropagation(), true);
          }
        })();
        """

    // MARK: Floating bar

    private func setUpBar() {
        bar.backButton.addTarget(self, action: #selector(back), for: .touchUpInside)
        // Built when opened, so it shows the current forward state, uBO status and ad count.
        bar.moreButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            done(self?.menuItems() ?? [])
        }])
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        refreshUBOButton()
    }

    private func menuItems() -> [UIMenuElement] {
        let forward = UIAction(title: "Forward", image: UIImage(systemName: "chevron.forward"),
                               attributes: webView?.canGoForward == true ? [] : .disabled) { [weak self] _ in self?.webView?.goForward() }
        let reload = UIAction(title: "Reload", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in self?.webView?.reload() }
        let home = UIAction(title: "Home", image: UIImage(systemName: "house")) { [weak self] _ in
            self?.webView?.load(URLRequest(url: Self.homeURL))
        }
        let update: UIAction
        switch UBOLiteUpdater.status() {
        case let .available(version):
            update = UIAction(title: "Update uBO", subtitle: "New: \(version)",
                              image: UIImage(systemName: "arrow.down.circle.fill")?.withTintColor(.systemGreen, renderingMode: .alwaysOriginal)) { [weak self] _ in
                self?.updateUBlock()
            }
        case let .downloaded(version):
            update = UIAction(title: "uBO ready", subtitle: "Reopen Lumen to use \(version)",
                              image: UIImage(systemName: "checkmark.circle")) { [weak self] _ in self?.updateUBlock() }
        case .current:
            update = UIAction(title: "Check uBO", subtitle: AdBlock.uBOCopy?.version ?? "-",
                              image: UIImage(systemName: "shield.lefthalf.filled")) { [weak self] _ in self?.updateUBlock() }
        }
        let ads = UIAction(title: "Ads missed: \(adsSeen)", image: UIImage(systemName: "eye.slash"),
                           attributes: .disabled) { _ in }
        return [UIMenu(options: .displayInline, children: [forward, reload, home]),
                UIMenu(options: .displayInline, children: [update, ads])]
    }

    /// Like Safari: shrink while the reader scrolls down, come back on scrolling up or at the top.
    private func scrolled(_ scrollView: UIScrollView) {
        let offset = scrollView.contentOffset.y
        defer { lastOffset = offset }
        guard scrollView.isDragging || scrollView.isDecelerating else { return }
        if offset <= 0 { return bar.setCollapsed(false) }
        let delta = offset - lastOffset
        travel = (delta > 0) == (travel > 0) ? travel + delta : delta
        if travel > 30 { bar.setCollapsed(true) } else if travel < -30 { bar.setCollapsed(false) }
    }

    /// "youtube.com" for www.youtube.com and m.youtube.com, like Safari's address bar.
    static func siteName(_ url: URL?) -> String {
        guard var host = url?.host else { return "" }
        for prefix in ["www.", "m."] where host.hasPrefix(prefix) { host.removeFirst(prefix.count) }
        return host
    }

    @objc func back() { webView?.goBack() }

    // MARK: Ads

    /// iOS has no way to send a real tap into the page, so only the ad counter (in the ⋯ menu) reacts
    /// here: the page script still mutes an ad that gets past uBO and runs it at 16x.
    private func handle(_ message: WKScriptMessage) {
        if AdBlock.handle(message) == .adStart { adsSeen += 1 }
    }

    // MARK: uBO Lite update

    private func checkForUBOUpdate() async {
        if await UBOLiteUpdater.checkIfDue() { refreshUBOButton() }
    }

    func refreshUBOButton() {
        if case .available = UBOLiteUpdater.status() { bar.dot.isHidden = false } else { bar.dot.isHidden = true }
    }

    /// Download a newer version if there is one. iOS apps cannot restart themselves, so the owner closes
    /// and reopens Lumen to start using it.
    func updateUBlock() {
        if case let .downloaded(version) = UBOLiteUpdater.status() { return showReopen(version) }
        bar.moreButton.isEnabled = false
        Task {
            let outcome = await UBOLiteUpdater.update()
            bar.moreButton.isEnabled = true
            refreshUBOButton()
            switch outcome {
            case let .downloaded(version):
                showReopen(version)
            case let .upToDate(version) where version != AdBlock.uBOCopy?.version:
                showReopen(version) // downloaded earlier, not in use yet
            case let .upToDate(version):
                showAlert("uBO is up to date", version)
            case let .failed(message):
                showAlert("uBO update failed", message)
            }
        }
    }

    private func showReopen(_ version: String) {
        showAlert("uBO \(version) downloaded", "Close and reopen Lumen to use it.")
    }

    private func showAlert(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    // MARK: WKUIDelegate

    /// Pop-ups the user did not tap (typical ad pop-unders) are dropped; tapped links that ask for a
    /// new window open here.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.navigationType == .linkActivated { webView.load(action.request) }
        return nil
    }
}
