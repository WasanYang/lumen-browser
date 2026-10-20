import AppKit
import LumenCore
import WebKit

/// One window, one page (tabs come after the prototype). Top bar: address field, ad counter and the
/// uBO update button, which shows a green dot when GitHub has a newer uBO Lite.
@MainActor
final class BrowserWindowController: NSWindowController, WKNavigationDelegate, WKUIDelegate {
    static let homeURL = URL(string: "https://www.youtube.com")!
    /// Appended to WebKit's own user agent so sites (Google sign-in in particular) see Safari.
    static let safariSuffix = "Version/26.0 Safari/605.1.15"

    let webView: WKWebView
    let addressField = NSTextField()
    let counterLabel = NSTextField(labelWithString: "")
    let uBOButton = NSButton(title: BrowserWindowController.uBOTitle, target: nil, action: #selector(updateUBlock(_:)))
    let uBODot = NSView()
    static let uBOTitle = "↻ uBO"
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
        counterLabel.toolTip = "โฆษณาวิดีโอที่หลุดมาถึงเครื่องเล่น YouTube และจำนวนครั้งที่กดปุ่มข้ามให้"
        counterLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        uBOButton.target = self
        uBOButton.isBordered = false
        uBOButton.contentTintColor = .secondaryLabelColor
        uBOButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        uBODot.wantsLayer = true
        uBODot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        uBODot.layer?.cornerRadius = 4
        refreshUBOButton()

        let bar = NSStackView(views: [addressField, counterLabel, uBOButton])
        bar.orientation = .horizontal
        bar.spacing = 10
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 10)

        let content = NSView()
        for view in [bar, webView, uBODot] as [NSView] {
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
            uBODot.widthAnchor.constraint(equalToConstant: 8),
            uBODot.heightAnchor.constraint(equalToConstant: 8),
            uBODot.topAnchor.constraint(equalTo: uBOButton.topAnchor, constant: -3),
            uBODot.leadingAnchor.constraint(equalTo: uBOButton.trailingAnchor, constant: 1),
        ])
        window.contentView = content
    }

    private func handle(_ message: WKScriptMessage) {
        switch AdBlock.handle(message) {
        case .adStart:
            adsSeen += 1
        case let .skip(x, y):
            guard let view = message.webView, PageClick.realClick(in: view, x: x, y: y) else { return }
            skipClicks += 1
        case nil:
            return
        }
        updateCounter()
    }

    private func updateCounter() {
        counterLabel.stringValue = "โฆษณา \(adsSeen) · กดข้าม \(skipClicks)"
    }

    // MARK: uBO Lite update

    /// Green dot when GitHub has a newer version than the device; the tooltip says what a press does.
    func refreshUBOButton() {
        let running = AdBlock.uBOCopy?.version ?? "-"
        let status = UBOLiteUpdater.status()
        uBODot.isHidden = { if case .available = status { return false } else { return true } }()
        switch status {
        case .current:
            uBOButton.toolTip = "uBlock Origin Lite \(running)\nกดเพื่อเช็ครุ่นใหม่"
        case let .available(version):
            uBOButton.toolTip = "มี uBlock Origin Lite รุ่นใหม่ \(version) (ตอนนี้ใช้ \(running))\nกดเพื่ออัปเดต"
        case let .downloaded(version):
            uBOButton.toolTip = "ดาวน์โหลดรุ่น \(version) แล้ว (ตอนนี้ใช้ \(running))\nกดเพื่อเปิด Lumen ใหม่และเริ่มใช้"
        }
    }

    /// The button and the Lumen menu item: download a newer version if there is one, then offer a restart.
    @objc func updateUBlock(_ sender: Any?) {
        if case let .downloaded(version) = UBOLiteUpdater.status() { return offerRelaunch(version) }
        uBOButton.isEnabled = false
        uBOButton.title = "กำลังอัปเดต…"
        Task {
            let outcome = await UBOLiteUpdater.update()
            uBOButton.title = Self.uBOTitle
            uBOButton.isEnabled = true
            refreshUBOButton()
            switch outcome {
            case let .downloaded(version):
                offerRelaunch(version)
            case let .upToDate(version) where version != AdBlock.uBOCopy?.version:
                offerRelaunch(version) // downloaded earlier, not in use yet
            case let .upToDate(version):
                showAlert("uBlock Origin Lite เป็นรุ่นล่าสุดแล้ว", "รุ่น \(version)")
            case let .failed(message):
                showAlert("อัปเดต uBlock Origin Lite ไม่สำเร็จ", message, style: .warning)
            }
        }
    }

    private func offerRelaunch(_ version: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "ดาวน์โหลด uBlock Origin Lite รุ่น \(version) แล้ว"
        alert.informativeText = "เปิด Lumen ใหม่เพื่อเริ่มใช้ เพลงที่เล่นอยู่จะหยุด"
        alert.addButton(withTitle: "เปิดใหม่ตอนนี้")
        alert.addButton(withTitle: "ไว้ทีหลัง")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { Self.relaunch() }
        }
    }

    private func showAlert(_ title: String, _ text: String, style: NSAlert.Style = .informational) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = text
        alert.beginSheetModal(for: window)
    }

    /// Starts a new copy of the app a moment after this one quits.
    static func relaunch() {
        let reopen = Process()
        reopen.executableURL = URL(fileURLWithPath: "/bin/sh")
        reopen.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? reopen.run()
        NSApp.terminate(nil)
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
