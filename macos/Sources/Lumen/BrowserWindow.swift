import AppKit
import WebKit

/// One window, one page (tabs come after the prototype). Top bar: address field and an ad counter.
@MainActor
final class BrowserWindowController: NSWindowController, WKNavigationDelegate, WKUIDelegate {
    static let homeURL = URL(string: "https://www.youtube.com")!
    /// Appended to WebKit's own user agent so sites (Google sign-in in particular) see Safari.
    static let safariSuffix = "Version/26.0 Safari/605.1.15"

    let webView: WKWebView
    let addressField = NSTextField()
    let counterLabel = NSTextField(labelWithString: "")
    let relay = ScriptMessageRelay()
    var adsSeen = 0
    var skipClicks = 0
    var observations: [NSKeyValueObservation] = []

    init(rules: WKContentRuleList?, url: URL) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default() // keeps logins across restarts
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = true
        config.applicationNameForUserAgent = Self.safariSuffix
        AdBlock.attach(to: config, rules: rules, handler: relay)
        webView = WKWebView(frame: .zero, configuration: config)
        webView.isInspectable = true // Safari → Develop menu

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.title = "Lumen"
        window.setFrameAutosaveName("MiniBrowserMain") // old name kept: it holds the saved window frame
        window.center()
        super.init(window: window)

        relay.onMessage = { [weak self] in self?.handle($0) }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        layout(in: window)
        observations = [
            webView.observe(\.title) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.window?.title = view.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Lumen" }
            },
            webView.observe(\.url) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    guard let self, self.addressField.currentEditor() == nil else { return }
                    self.addressField.stringValue = view.url?.absoluteString ?? ""
                }
            },
        ]
        updateCounter()
        webView.load(URLRequest(url: url))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func layout(in window: NSWindow) {
        addressField.placeholderString = "พิมพ์ URL หรือคำค้น (⌘L)"
        addressField.target = self
        addressField.action = #selector(go)
        addressField.lineBreakMode = .byTruncatingTail
        counterLabel.textColor = .secondaryLabelColor
        counterLabel.toolTip = "โฆษณาวิดีโอที่หลุดมาถึงเครื่องเล่น YouTube และจำนวนครั้งที่กดปุ่มข้ามให้\n" +
            "uBlock Origin Lite \(AdBlock.uBOVersion() ?? "ไม่พบ")"
        counterLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let bar = NSStackView(views: [addressField, counterLabel])
        bar.orientation = .horizontal
        bar.spacing = 10
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 10)

        let content = NSView()
        for view in [bar, webView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webView.topAnchor.constraint(equalTo: bar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
    }

    private func handle(_ message: WKScriptMessage) {
        switch AdBlock.handle(message) {
        case .adStart: adsSeen += 1
        case .skipClicked: skipClicks += 1
        case .skipMissed, nil: return
        }
        updateCounter()
    }

    private func updateCounter() {
        counterLabel.stringValue = "โฆษณา \(adsSeen) · กดข้าม \(skipClicks)"
    }

    // MARK: Address bar and menu actions

    static func url(from text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("localhost") || text.hasPrefix("127.0.0.1") { return URL(string: "http://" + text) }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
           ["http", "https", "file", "about"].contains(scheme) { return url }
        if !text.contains(" ") && text.contains(".") { return URL(string: "https://" + text) }
        var search = URLComponents(string: "https://www.google.com/search")!
        search.queryItems = [URLQueryItem(name: "q", value: text)]
        return search.url
    }

    @objc func go() {
        guard !addressField.stringValue.isEmpty, let url = Self.url(from: addressField.stringValue) else { return }
        webView.load(URLRequest(url: url))
        window?.makeFirstResponder(webView)
    }

    @objc func focusAddressBar(_ sender: Any?) { window?.makeFirstResponder(addressField) }
    @objc func reloadPage(_ sender: Any?) { webView.reload() }
    @objc func back(_ sender: Any?) { webView.goBack() }
    @objc func forward(_ sender: Any?) { webView.goForward() }

    // MARK: WKUIDelegate

    /// Pop-ups the user did not click (typical ad pop-unders) are dropped. Clicked links that ask for
    /// a new window open here until tabs exist.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.navigationType == .linkActivated { webView.load(action.request) }
        return nil
    }
}
