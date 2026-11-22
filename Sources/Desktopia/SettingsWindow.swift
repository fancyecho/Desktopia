import AppKit

// 设置窗口：普通窗口，里面显示 prototype/settings.html（和 Windows 版共用同一个页面）
final class SettingsWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let web: WebHost
    var onMessage: ((String) -> Void)?
    var onClose: (() -> Void)?

    override init() {
        let size = NSSize(width: 1120, height: 800)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        web = WebHost(frame: NSRect(origin: .zero, size: size))
        super.init()
        window.title = "Desktopia"
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 940, height: 680)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.backgroundColor = NSColor(name: nil) { ap in
            ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0x17 / 255.0, alpha: 1) : .white
        }
        web.webView.setValue(false, forKey: "drawsBackground")
        window.contentView = web.webView
        window.center()
        window.setFrameAutosaveName("DesktopiaSettings")
        web.onMessage = { [weak self] m in self?.onMessage?(m) }
        web.onCrash = { [weak self] in self?.web.webView.reload() }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        web.load(page: "settings.html?v=\(version)")
        Log.write("打开设置窗口")
    }

    func show() {
        NSApp.setActivationPolicy(.regular)             // 设置窗口开着时出现在 Dock 和 ⌘Tab 里
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func post(_ json: String) { web.post(json) }

    func close() { window.close() }

    func windowWillClose(_ notification: Notification) {
        web.tearDown()
        NSApp.setActivationPolicy(.accessory)           // 关掉后回到只在菜单栏常驻
        onClose?()
    }
}
