import AppKit
import WebKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var browser: BrowserWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        NSApp.activate(ignoringOtherApps: true)
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.start()
            return
        }
        let start = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("-") }
            .flatMap(BrowserWindowController.url(from:)) ?? BrowserWindowController.homeURL
        Task {
            var rules: WKContentRuleList?
            do {
                rules = try await AdBlock.compileRules()
            } catch {
                let alert = NSAlert()
                alert.messageText = "โหลดรายการบล็อกไม่สำเร็จ"
                alert.informativeText = "\(error.localizedDescription)\nจะเปิดต่อโดยไม่บล็อกตามรายการ"
                alert.runModal()
            }
            let browser = BrowserWindowController(rules: rules, url: start)
            browser.showWindow(nil)
            self.browser = browser
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        func item(_ title: String, _ action: Selector, _ key: String,
                  _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let holder = NSMenuItem()
            holder.submenu = menu
            main.addItem(holder)
        }
        submenu("Lumen", [item("ออกจาก Lumen", #selector(NSApplication.terminate(_:)), "q")])
        // Without an Edit menu, ⌘C/⌘V do nothing in the address bar or on pages.
        submenu("แก้ไข", [
            item("เลิกทำ", Selector(("undo:")), "z"),
            item("ทำซ้ำ", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("ตัด", #selector(NSText.cut(_:)), "x"),
            item("คัดลอก", #selector(NSText.copy(_:)), "c"),
            item("วาง", #selector(NSText.paste(_:)), "v"),
            item("เลือกทั้งหมด", #selector(NSText.selectAll(_:)), "a"),
        ])
        submenu("มุมมอง", [
            item("ไปที่แถบ URL", #selector(BrowserWindowController.focusAddressBar(_:)), "l"),
            item("โหลดใหม่", #selector(BrowserWindowController.reloadPage(_:)), "r"),
            item("ย้อนกลับ", #selector(BrowserWindowController.back(_:)), "["),
            item("ไปข้างหน้า", #selector(BrowserWindowController.forward(_:)), "]"),
            .separator(),
            item("เต็มจอ", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        submenu("หน้าต่าง", [
            item("ย่อ", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("ปิด", #selector(NSWindow.performClose(_:)), "w"),
        ])
        return main
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
