import AppKit
import WebKit

/// Layers, in the order they act:
/// 1. Network: shared/blocklist.txt is compiled into a WKContentRuleList, so WebKit drops matching
///    requests itself and nothing reaches Swift.
/// 2. uBlock Origin Lite's YouTube scriptlets (the files the Windows build loads as an extension).
///    They take the ads out of YouTube's player data, so most ads never start.
/// 3. Cosmetic: CSS that hides ad slots which still render.
/// 4. Fallback for an ad that gets through: mute it, run it at 16x and press skip with a real click.
/// Our page script runs in its own content world: YouTube's scripts share the DOM with it but can
/// neither see nor call the message handler that triggers real clicks.
/// Not ported: ForceH264 (Apple Silicon decodes VP9 in hardware).
enum AdBlock {
    static let world = WKContentWorld.world(name: "Lumen")
    static let uBOIsolatedWorld = WKContentWorld.world(name: "uBOLite")
    static let handlerName = "miniBrowser"

    // MARK: Layer 1 — network rules

    /// blocklist.txt inside the app bundle; for `swift run` from macos/, ../shared/blocklist.txt.
    static func blocklistURL() -> URL? {
        if let path = ProcessInfo.processInfo.environment["MINIBROWSER_BLOCKLIST"] { return URL(fileURLWithPath: path) }
        if let bundled = Bundle.main.url(forResource: "blocklist", withExtension: "txt") { return bundled }
        let dev = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("../shared/blocklist.txt").standardized
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    /// One block rule per line. Same format as Windows: a bare domain blocks it and all subdomains;
    /// a line containing * or / is a URL pattern where * matches anything.
    static func rules(from text: String) -> [[String: Any]] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { return nil }
            return ["trigger": ["url-filter": urlFilter(for: line)], "action": ["type": "block"]]
        }
    }

    /// WebKit's url-filter is a small regex dialect (no `|`, no `{n}`), matched against the whole URL.
    static func urlFilter(for line: String) -> String {
        if !line.contains("*") && !line.contains("/") {
            return "^[^:]+://+([^:/]+\\.)?" + escape(line) + "[:/]"
        }
        var body = Substring(line)
        var regex = "^"
        if body.hasPrefix("*://") { regex = "^[^:]+://"; body = body.dropFirst(4) }
        regex += body.split(separator: "*", omittingEmptySubsequences: false)
            .map { escape(String($0)) }
            .joined(separator: ".*")
        if !line.hasSuffix("*") { regex += "$" }
        return regex
    }

    static func escape(_ text: String) -> String {
        var out = ""
        for c in text {
            if "\\.+?()[]{}^$|".contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }

    /// The compiled rule list, or nil when there is no blocklist or it has no rules.
    @MainActor
    static func compileRules(store: WKContentRuleListStore? = nil) async throws -> WKContentRuleList? {
        guard let url = blocklistURL() else { return nil }
        let rules = rules(from: try String(contentsOf: url, encoding: .utf8))
        if rules.isEmpty { return nil }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: rules), as: UTF8.self)
        return try await (store ?? .default()).compileContentRuleList(forIdentifier: "blocklist", encodedContentRuleList: json)
    }

    // MARK: Layer 2 — uBlock Origin Lite scriptlets

    /// uBO Lite's folder: inside the app bundle, or for `swift run` from macos/, the Windows copy.
    static func uBOFolder() -> URL? {
        if let bundled = Bundle.main.url(forResource: "uBOLite", withExtension: nil) { return bundled }
        let dev = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("../windows/Extensions/uBOLite").standardized
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    static func uBOVersion() -> String? {
        guard let manifest = uBOFolder()?.appendingPathComponent("manifest.json"),
              let data = try? Data(contentsOf: manifest),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["version"] as? String
    }

    /// The rulesets that hold uBO's YouTube rules. Each world gets scriptlet-begin + these +
    /// scriptlet-end in one script, the way uBO Lite registers them; the files need no extension API.
    static let uBORulesets = ["ublock-filters", "ublock-experimental"]

    /// One script per world (main = the page's own, isolated = uBO's DOM-only scriptlets), or none
    /// when uBO Lite is missing. Wrapped so they only run on YouTube, not on sign-in or other pages.
    static func uBOScripts() -> [(source: String, world: WKContentWorld)] {
        guard let folder = uBOFolder() else { return [] }
        var out: [(String, WKContentWorld)] = []
        for (name, world) in [("main", WKContentWorld.page), ("isolated", uBOIsolatedWorld)] {
            let dir = folder.appendingPathComponent("rulesets/scripting/scriptlet/\(name)")
            let files = ["scriptlet-begin"] + uBORulesets + ["scriptlet-end"]
            let parts = files.compactMap { try? String(contentsOf: dir.appendingPathComponent("\($0).js"), encoding: .utf8) }
            guard parts.count == files.count else { continue }
            out.append(("if (/(^|\\.)youtube\\.com$/.test(location.hostname)) {\n" + parts.joined(separator: "\n") + "\n}", world))
        }
        return out
    }

    // MARK: Layers 3 and 4 — our page script

    /// Adds every layer to a configuration, before the WKWebView is created from it.
    @MainActor
    static func attach(to config: WKWebViewConfiguration, rules: WKContentRuleList?, handler: WKScriptMessageHandler) {
        let content = config.userContentController
        if let rules { content.add(rules) }
        for (source, world) in uBOScripts() {
            content.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart,
                                               forMainFrameOnly: false, in: world))
        }
        content.addUserScript(WKUserScript(source: pageScript, injectionTime: .atDocumentStart,
                                           forMainFrameOnly: true, in: world))
        content.add(handler, contentWorld: world, name: handlerName)
    }

    enum Event { case adStart, skipClicked, skipMissed }

    /// Acts on a message from the page script. Only YouTube's top frame is listened to.
    @MainActor
    static func handle(_ message: WKScriptMessage) -> Event? {
        let host = message.frameInfo.securityOrigin.host
        guard message.frameInfo.isMainFrame, host == "youtube.com" || host.hasSuffix(".youtube.com"),
              let webView = message.webView,
              let body = message.body as? [String: Any], let type = body["type"] as? String else { return nil }
        switch type {
        case "ad-start":
            return .adStart
        case "skip-ad":
            guard let x = (body["x"] as? NSNumber)?.doubleValue, let y = (body["y"] as? NSNumber)?.doubleValue else { return nil }
            return realClick(in: webView, x: x, y: y) ? .skipClicked : .skipMissed
        default:
            return nil
        }
    }

    /// Clicks at a point the page reported (CSS pixels from the viewport's top-left) with real mouse
    /// events. YouTube ignores script clicks on the skip button but accepts these.
    @MainActor
    static func realClick(in webView: WKWebView, x: Double, y: Double) -> Bool {
        let scale = webView.pageZoom * webView.magnification
        var point = NSPoint(x: x * scale, y: y * scale)
        if !webView.isFlipped { point.y = webView.bounds.height - point.y }
        guard webView.bounds.contains(point), let window = webView.window else { return false }
        let inWindow = webView.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: inWindow, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            ) else { return false }
            if type == .leftMouseDown { webView.mouseDown(with: event) } else { webView.mouseUp(with: event) }
        }
        return true
    }

    static let pageScript = """
        (() => {
          // ---- Layer 3: hide ad slots ----
          const css = `
            ins.adsbygoogle, [id^="google_ads_iframe"], [id^="div-gpt-ad"], .adsbox,
            ytd-ad-slot-renderer, ytd-in-feed-ad-layout-renderer, ytd-display-ad-renderer,
            ytd-promoted-sparkles-web-renderer, ytd-promoted-video-renderer,
            ytd-banner-promo-renderer, ytd-action-companion-ad-renderer,
            ytd-companion-slot-renderer, ytd-player-legacy-desktop-watch-ads-renderer,
            ytd-rich-item-renderer:has(> #content > ytd-ad-slot-renderer),
            ytd-rich-section-renderer:has(ytd-statement-banner-renderer),
            #masthead-ad, #player-ads, .ytp-ad-overlay-container, .ytp-ad-image-overlay,
            ytm-promoted-sparkles-web-renderer, ad-slot-renderer
            { display: none !important; }`;
          const addCss = () => {
            if (!document.documentElement) return false;
            const style = document.createElement('style');
            style.textContent = css;
            document.documentElement.appendChild(style);
            return true;
          };
          if (!addCss()) {
            const mo = new MutationObserver(() => { if (addCss()) mo.disconnect(); });
            mo.observe(document, { childList: true });
          }

          if (!/(^|\\.)youtube\\.com$/.test(location.hostname)) return;

          // ---- Layer 4: if an ad still plays, mute it, run it at 16x and press skip ----
          // YouTube ignores script clicks on the skip button, so the app clicks it for real.
          const post = (msg) => window.webkit?.messageHandlers?.miniBrowser?.postMessage(msg);
          let inAd = false, mutedByUs = false, savedRate = null, skipSentAt = 0;
          setInterval(() => {
            const player = document.getElementById('movie_player');
            const video = player?.querySelector('video');
            if (!video) return;
            if (player.classList.contains('ad-showing')) {
              if (!inAd) { inAd = true; post({ type: 'ad-start' }); }
              const skip = document.querySelector('.ytp-skip-ad-button, .ytp-ad-skip-button, .ytp-ad-skip-button-modern');
              if (skip?.offsetParent && Date.now() - skipSentAt > 1000) {
                const r = skip.getBoundingClientRect();
                post({ type: 'skip-ad', x: r.left + r.width / 2, y: r.top + r.height / 2 });
                skipSentAt = Date.now();
              }
              if (!video.muted) { video.muted = true; mutedByUs = true; }
              if (savedRate === null) savedRate = video.playbackRate;
              if (video.playbackRate !== 16) video.playbackRate = 16;
              const atEnd = video.ended || video.currentTime >= video.duration - 0.5;
              if (video.paused && !atEnd && video.readyState > 0) video.play().catch(() => {});
            } else {
              inAd = false;
              if (mutedByUs) { video.muted = false; mutedByUs = false; }
              // Only undo our 16x; leave any speed YouTube applied to the real video.
              if (savedRate !== null) { if (video.playbackRate === 16) video.playbackRate = savedRate; savedRate = null; }
            }
          }, 250);
        })();
        """
}

/// Lets a configuration hold a message handler before the object that handles it exists, and
/// without the configuration keeping that object alive.
@MainActor
final class ScriptMessageRelay: NSObject, WKScriptMessageHandler {
    var onMessage: ((WKScriptMessage) -> Void)?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        onMessage?(message)
    }
}
