import AppKit
import ApplicationServices
import ServiceManagement

// 整个程序的生命周期：菜单栏图标常驻，壁纸窗口挂在桌面层，设置窗口按需打开。
// 对应 Windows 版的 HostContext。

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var pauseItem: NSMenuItem!, autoStartItem: NSMenuItem!, settingsItem: NSMenuItem!
    private var reloadItem: NSMenuItem!, exitItem: NSMenuItem!, permissionItem: NSMenuItem!
    private var wallpaper: WallpaperController?
    private var settingsWin: SettingsWindowController?
    private var lastShare: URL?
    private var showSettingsAtLaunch: Bool

    init(showSettings: Bool) {
        showSettingsAtLaunch = showSettings
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if launchedAsLoginItem() { showSettingsAtLaunch = false }
        Log.write("启动，页面目录：\(Paths.pageDir.path)" + (showSettingsAtLaunch ? "" : "（开机自动启动）"))
        Settings.shared.load()
        I18n.load(setting: Settings.shared.lang)
        buildStatusItem()

        // `Desktopia --exit` / `--settings`：通知正在运行的实例
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(remoteExit), name: Remote.exit, object: nil)
        dnc.addObserver(self, selector: #selector(remoteSettings), name: Remote.settings, object: nil)
        dnc.addObserver(self, selector: #selector(remoteShareTest(_:)), name: Remote.shareTest, object: nil)

        checkAccessibility(prompt: true)
        startWallpaper()
        if showSettingsAtLaunch { openSettings() }
    }

    /// 登录项启动时不弹设置窗口（SMAppService 启动时不能带参数，只能看启动事件）
    private func launchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    // 已经在运行时再次打开 App（Finder 双击 / `open`）：打开设置
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        Settings.shared.flush()
        wallpaper?.shutdown()
        Log.write("退出")
    }

    // MARK: - 菜单栏

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let img = NSImage(systemSymbolName: "beach.umbrella", accessibilityDescription: "Desktopia")
                ?? NSImage(systemSymbolName: "photo", accessibilityDescription: "Desktopia")
            img?.isTemplate = true
            button.image = img
            button.toolTip = "Desktopia"
        }
        let menu = NSMenu()
        menu.delegate = self
        permissionItem = NSMenuItem(title: "", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        permissionItem.target = self
        settingsItem = item(#selector(openSettingsAction), key: ",")
        pauseItem = item(#selector(togglePause))
        reloadItem = item(#selector(reloadPage), key: "r")
        autoStartItem = item(#selector(toggleAutoStart))
        exitItem = item(#selector(quit), key: "q")
        [permissionItem, settingsItem, pauseItem, reloadItem, autoStartItem, .separator(), exitItem].forEach { menu.addItem($0) }
        statusItem.menu = menu
        applyMenuTexts()
    }

    private func item(_ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: "", action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    private func applyMenuTexts() {
        settingsItem.title = I18n.t("traySettings")
        pauseItem.title = I18n.t("trayPause")
        reloadItem.title = I18n.t("trayReload")
        autoStartItem.title = I18n.t("trayAutostart")
        exitItem.title = I18n.t("trayExit")
        permissionItem.title = I18n.code == "zh-CN"
            ? "⚠︎ 需要“辅助功能”权限才能读取桌面图标…"
            : "⚠︎ Grant Accessibility access to read desktop icons…"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        autoStartItem.state = isAutoStart() ? .on : .off
        permissionItem.isHidden = AXIsProcessTrusted()
    }

    @objc private func openSettingsAction() { openSettings() }

    @objc private func togglePause() {
        let v = !(wallpaper?.manualPause ?? false)
        wallpaper?.manualPause = v
        pauseItem.state = v ? .on : .off
    }

    @objc private func reloadPage() { wallpaper?.reload() }

    @objc private func toggleAutoStart() { setAutoStart(!isAutoStart()) }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func remoteExit() { quit() }
    @objc private func remoteSettings() { openSettings() }

    /// 开发调试：`Desktopia --debug-share image|video` 不经过设置页直接触发分享，结果写进日志
    @objc private func remoteShareTest(_ n: Notification) {
        guard let w = wallpaper else { return }
        if (n.object as? String) == "video" {
            w.requestRecording { [weak self] mime, poster, video, err in self?.onShareVideo(mime, poster, video, err) }
        } else {
            w.requestSnapshot { [weak self] thumb, png, err in self?.onShareImage(thumb, png, err) }
        }
    }

    // MARK: - 辅助功能权限

    @discardableResult
    private func checkAccessibility(prompt: Bool) -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        let ok = AXIsProcessTrustedWithOptions(opts)
        if !ok { Log.write("没有辅助功能权限：读不到桌面图标，先显示一片海") }
        return ok
    }

    @objc private func openAccessibilitySettings() {
        checkAccessibility(prompt: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 壁纸

    private func startWallpaper() {
        let theme = Themes.allowed(Settings.shared.theme) ? Settings.shared.theme : "beach"
        if theme != Settings.shared.theme {
            Log.write("主题 \(Settings.shared.theme) 不可用，改用 beach")
            Settings.shared.theme = theme
        }
        guard let page = Themes.page(for: theme),
              Overlay.load("/" + page) != nil else {
            fail(I18n.t("errNoPage", ["path": Paths.pageDir.path]))
            return
        }
        let w = WallpaperController(page: page)
        w.settingsJson = { [weak self] in self?.settingsMessage() ?? "{}" }
        w.onIconsChanged = { [weak self] json in self?.settingsWin?.post(json) }
        w.onRecordProgress = { [weak self] p in self?.settingsWin?.post("{\"t\":\"recProgress\",\"p\":\(p)}") }
        w.start()
        wallpaper = w
    }

    private func settingsMessage() -> String {
        JSON.stringify(["t": "settings", "v": Settings.shared.params(for: Settings.shared.theme)])
    }

    private func fail(_ msg: String) {
        Log.write(msg)
        let alert = NSAlert()
        alert.messageText = "Desktopia"
        alert.informativeText = msg + "\n\n" + I18n.t("errSeeLog", ["path": Paths.logFile.path])
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        NSApp.terminate(nil)
    }

    // MARK: - 设置窗口

    func openSettings() {
        if settingsWin == nil {
            let s = SettingsWindowController()
            s.onMessage = { [weak self] m in self?.onSettingsMessage(m) }
            s.onClose = { [weak self] in self?.settingsWin = nil }
            settingsWin = s
        }
        settingsWin?.show()
    }

    /// 设置页发来的消息：hello / set / reset / theme / lang / autostart / share…（协议与 Windows 版相同）
    private func onSettingsMessage(_ s: String) {
        guard let m = JSON.parse(s) as? [String: Any], let win = settingsWin else { return }
        let settings = Settings.shared
        switch m["t"] as? String {
        case "hello":
            let px = wallpaper?.screenPixels ?? (w: 0, h: 0)
            win.post(JSON.stringify([
                "t": "init", "theme": settings.theme, "params": settings.params,
                "screen": ["w": px.w, "h": px.h], "autostart": isAutoStart(),
                "autostartWarn": false, "autostartSw": "",
                "lang": settings.lang, "langEff": I18n.code, "langSys": I18n.sys,
            ]))
            if let icons = wallpaper?.currentIcons, !icons.isEmpty { win.post(icons) }
        case "set":
            guard let theme = m["theme"] as? String, let key = m["key"] as? String else { return }
            let value = m["value"] ?? NSNull()
            var p = settings.params[theme] ?? [:]
            p[key] = value
            settings.params[theme] = p
            if theme == settings.theme { wallpaper?.post(JSON.stringify(["t": "settings", "v": [key: value]])) }
            settings.saveSoon()
        case "reset":
            guard let theme = m["theme"] as? String else { return }
            settings.params.removeValue(forKey: theme)
            if theme == settings.theme { wallpaper?.post("{\"t\":\"reset\"}") }
            settings.saveSoon()
            Log.write("恢复默认设置：\(theme)")
        case "theme":
            guard let id = m["id"] as? String, Themes.allowed(id) else {
                win.post(JSON.stringify(["t": "themeChanged", "id": settings.theme]))
                Log.write("拒绝未授权或未知主题切换：\(m["id"] as? String ?? "null")")
                return
            }
            guard let page = Themes.page(for: id), id != settings.theme else { return }
            settings.theme = id
            settings.saveSoon()
            wallpaper?.loadPage(page)
            Log.write("切换主题：\(id)")
        case "lang":
            guard let v = m["v"] as? String else { return }
            settings.lang = v
            settings.saveSoon()
            I18n.load(setting: v)
            applyMenuTexts()
            win.post(JSON.stringify(["t": "lang", "v": v, "eff": I18n.code, "sys": I18n.sys]))
        case "autostart":
            setAutoStart(m["v"] as? Bool ?? false)
            win.post(JSON.stringify(["t": "autostart", "v": isAutoStart()]))
        case "share":
            guard let w = wallpaper else { postShareResult(false, I18n.t("errNotReady")); return }
            w.requestSnapshot { [weak self] thumb, png, err in self?.onShareImage(thumb, png, err) }
        case "shareVideo":
            guard let w = wallpaper else { postShareResult(false, I18n.t("errNotReady")); return }
            w.requestRecording { [weak self] mime, poster, video, err in self?.onShareVideo(mime, poster, video, err) }
        case "openShare":
            if let f = lastShare, FileManager.default.fileExists(atPath: f.path) { NSWorkspace.shared.open(f) }
        case "revealShare":
            if let f = lastShare, FileManager.default.fileExists(atPath: f.path) { NSWorkspace.shared.activateFileViewerSelecting([f]) }
        case "openWebsite":
            NSWorkspace.shared.open(URL(string: "https://deskland.app/")!)
        default:
            break
        }
    }

    // MARK: - 分享：存到“图片/Desktopia”，放进剪贴板，把缩略图发回设置页

    private func decodeDataURL(_ s: String) -> Data? {
        let b64 = s.firstIndex(of: ",").map { String(s[s.index(after: $0)...]) } ?? s
        return Data(base64Encoded: b64, options: .ignoreUnknownCharacters)
    }

    private func shareFile(ext: String) throws -> URL {
        try FileManager.default.createDirectory(at: Paths.shareDir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmmss"
        return Paths.shareDir.appendingPathComponent("Desktopia \(f.string(from: Date())).\(ext)")
    }

    private func onShareImage(_ thumb: String?, _ png: String?, _ err: String?) {
        guard err == nil, let png, let bytes = decodeDataURL(png) else {
            postShareResult(false, err ?? I18n.t("errNoImage"))
            Log.write("生成分享图失败：\(err ?? "无数据")")
            return
        }
        do {
            let url = try shareFile(ext: "png")
            try bytes.write(to: url)
            lastShare = url
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setData(bytes, forType: .png)
            pb.writeObjects([url as NSURL])
            Log.write("已生成分享图：\(url.path)")
            settingsWin?.post(JSON.stringify(["t": "shareResult", "ok": true, "thumb": thumb ?? "", "path": url.path]))
        } catch {
            Log.write("保存分享图失败：\(error)")
            postShareResult(false, error.localizedDescription)
        }
    }

    private func onShareVideo(_ mime: String?, _ poster: String?, _ video: String?, _ err: String?) {
        guard err == nil, let video, let bytes = decodeDataURL(video) else {
            postShareResult(false, err ?? I18n.t("errNoVideo"))
            Log.write("录分享动画失败：\(err ?? "无数据")")
            return
        }
        do {
            let url = try shareFile(ext: mime == "video/webm" ? "webm" : "mp4")
            try bytes.write(to: url)
            lastShare = url
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([url as NSURL])
            Log.write("已录好分享动画：\(url.path)（\(bytes.count / 1024) KB）")
            let name = url.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
            settingsWin?.post(JSON.stringify(["t": "shareResult", "ok": true, "kind": "video", "thumb": poster ?? "",
                                              "path": url.path, "url": "\(LocalSchemeHandler.scheme)://share/\(name)"]))
        } catch {
            Log.write("保存分享动画失败：\(error)")
            postShareResult(false, error.localizedDescription)
        }
    }

    private func postShareResult(_ ok: Bool, _ msg: String) {
        settingsWin?.post(JSON.stringify(["t": "shareResult", "ok": ok, "path": NSNull(), "msg": msg]))
    }

    // MARK: - 开机自动启动（登录项）

    private func isAutoStart() -> Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }

    private func setAutoStart(_ on: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            Log.write("开机自动启动：\(on ? "打开" : "关闭")")
        } catch {
            Log.write("设置开机自动启动失败（需要从 .app 运行）：\(error.localizedDescription)")
        }
        autoStartItem.state = isAutoStart() ? .on : .off
    }
}

enum Remote {
    static let exit = Notification.Name("io.github.fancyecho.desktopia.exit")
    static let settings = Notification.Name("io.github.fancyecho.desktopia.settings")
    static let shareTest = Notification.Name("io.github.fancyecho.desktopia.share-test")
}
