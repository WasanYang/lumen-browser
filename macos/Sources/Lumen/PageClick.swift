import AppKit
import WebKit

/// The Mac half of LumenCore's skip fallback: YouTube ignores script clicks on its skip button but
/// accepts real mouse events, and NSEvents handed to the WKWebView arrive as trusted clicks
/// (also while the app is hidden). iOS has no equivalent.
enum PageClick {
    /// Clicks at a point the page reported (CSS pixels from the viewport's top-left).
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
}
