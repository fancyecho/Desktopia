import AppKit

// 壁纸窗口：无边框、不接收鼠标、放在桌面层（系统壁纸之上、桌面图标之下），在所有桌面空间都显示。
// 对应 Windows 版的 WallpaperForm：挂到壁纸层 + 每 400ms 读图标 + 每 500ms 检查要不要暂停 + 分享。

final class WallpaperController: NSObject {
    private let window: NSWindow
    private let web: WebHost
    private let reader = IconReader()
    private var iconTimer: Timer?
    private var pauseTimer: Timer?
    private var page: String
    private var screen: NSScreen
    private var lastIcons = ""
    private var lastPause: Bool?
    private var lastStatus: IconReader.Status?
    var manualPause = false { didSet { pollPause() } }

    var settingsJson: (() -> String)?
    var onIconsChanged: ((String) -> Void)?
    var onRecordProgress: ((String) -> Void)?
    var onStatusChanged: ((IconReader.Status) -> Void)?
    var currentIcons: String { lastIcons }

    init(page: String) {
        self.page = page
        self.screen = Self.primaryScreen()
        window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        web = WebHost(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init()

        // 桌面层 +1：在系统壁纸之上，在 Finder 的桌面图标层（kCGDesktopIconWindowLevel）之下
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.isOpaque = true
        window.backgroundColor = NSColor(srgbRed: 26 / 255, green: 163 / 255, blue: 196 / 255, alpha: 1)
        window.title = "DesktopiaWallpaper"
        web.webView.setValue(false, forKey: "drawsBackground")   // 页面还没画出来时露出窗口底色，不闪白
        window.contentView = web.webView

        web.onMessage = { [weak self] msg in self?.onPageMessage(msg) }
        web.onCrash = { [weak self] in self?.reload() }

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        nc.addObserver(self, selector: #selector(occlusionChanged), name: NSWindow.didChangeOcclusionStateNotification, object: window)
        let wnc = NSWorkspace.shared.notificationCenter
        wnc.addObserver(self, selector: #selector(spaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        wnc.addObserver(self, selector: #selector(sleepChanged), name: NSWorkspace.screensDidSleepNotification, object: nil)
        wnc.addObserver(self, selector: #selector(sleepChanged), name: NSWorkspace.screensDidWakeNotification, object: nil)
    }

    func start() {
        window.setFrame(screen.frame, display: false)
        window.orderFrontRegardless()
        web.load(page: page + "?wallpaper=1")
        iconTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in self?.pollIcons() }
        pauseTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.pollPause() }
        Log.write("壁纸窗口已挂到桌面层：\(Int(screen.frame.width))×\(Int(screen.frame.height)) pt，缩放 \(screen.backingScaleFactor)")
    }

    func shutdown() {
        iconTimer?.invalidate(); pauseTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        web.tearDown()
        window.orderOut(nil)
        window.close()
    }

    func reload() {
        lastIcons = ""; lastPause = nil
        web.webView.reload()
    }

    func loadPage(_ newPage: String) {
        page = newPage
        lastIcons = ""; lastPause = nil
        web.load(page: page + "?wallpaper=1")
    }

    func post(_ json: String) { web.post(json) }

    /// 屏幕的像素尺寸（主题页面按物理像素工作，和 Windows 版一致）
    var screenPixels: (w: Int, h: Int) {
        let k = screen.backingScaleFactor
        return (Int(screen.frame.width * k), Int(screen.frame.height * k))
    }

    // MARK: - 页面消息

    private func onPageMessage(_ msg: String) {
        if msg.hasPrefix("snapshot|") { onSnapshot(msg); return }
        if msg.hasPrefix("recprogress|") { onRecordProgress?(String(msg.dropFirst(12))); return }
        if msg.hasPrefix("record|") { onRecord(msg); return }
        // 其余的就是 "ready"：先发设置，再发图标和暂停状态（岸线要按设置里的离岸距离来算）
        if let s = settingsJson?() { web.post(s) }
        lastIcons = ""; lastPause = nil
        pollIcons(); pollPause()
    }

    // MARK: - 图标

    private func pollIcons() {
        var status = IconReader.Status.ok
        let result = reader.read(status: &status)
        if status != lastStatus {
            lastStatus = status
            Log.write("读取桌面图标：\(status)")
            onStatusChanged?(status)
        }
        guard let (rects, visible) = result else { return }
        // 全局坐标（点，主屏左上角为原点）→ 相对屏幕左上角的物理像素
        let k = screen.backingScaleFactor
        let main = NSScreen.screens.first?.frame ?? screen.frame
        let ox = screen.frame.minX - main.minX
        let oy = main.maxY - screen.frame.maxY
        var parts: [String] = []
        parts.reserveCapacity(rects.count)
        for r in rects {
            let l = Int(((r.left - ox) * k).rounded()), t = Int(((r.top - oy) * k).rounded())
            let rr = Int(((r.right - ox) * k).rounded()), b = Int(((r.bottom - oy) * k).rounded())
            parts.append("[\(l),\(t),\(rr),\(b)]")
        }
        let json = "{\"t\":\"icons\",\"vis\":\(visible),\"r\":[\(parts.joined(separator: ","))]}"
        if json == lastIcons { return }
        lastIcons = json
        onIconsChanged?(json)
        web.post(json)
        Log.write("图标变化：\(rects.count) 个，可见=\(visible)")
    }

    // MARK: - 暂停：有窗口铺满屏幕 / 全屏、壁纸被完全挡住、屏幕睡眠，或手动暂停

    private var screensAsleep = false

    @objc private func occlusionChanged() { pollPause() }
    @objc private func spaceChanged() { pollPause() }
    @objc private func sleepChanged(_ n: Notification) {
        screensAsleep = n.name == NSWorkspace.screensDidSleepNotification
        pollPause()
    }

    @objc private func screensChanged() {
        let s = Self.primaryScreen()
        // 激活状态切换等也会发这个通知：尺寸和缩放都没变就不用动
        if s.frame == window.frame && s.backingScaleFactor == screen.backingScaleFactor { screen = s; return }
        screen = s
        window.setFrame(s.frame, display: true)
        lastIcons = ""
        pollIcons()
        Log.write("屏幕变化：\(Int(s.frame.width))×\(Int(s.frame.height)) pt，缩放 \(s.backingScaleFactor)")
    }

    private func pollPause() {
        var pause = manualPause
        var reason = manualPause ? "手动暂停" : ""
        if !pause && screensAsleep { pause = true; reason = "屏幕睡眠" }
        if !pause && !window.occlusionState.contains(.visible) { pause = true; reason = "壁纸被完全挡住" }
        if !pause, let owner = coveringWindowOwner() { pause = true; reason = "窗口铺满屏幕：\(owner)" }
        if pause == lastPause { return }
        lastPause = pause
        web.post("{\"t\":\"pause\",\"v\":\(pause)}")
        Log.write(pause ? "暂停（\(reason)）" : "继续播放")
    }

    /// 当前桌面空间里，有没有普通窗口铺满了主屏的可用区域（相当于 Windows 的"最大化"）
    private func coveringWindowOwner() -> String? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let main = NSScreen.screens.first?.frame ?? screen.frame
        let vf = screen.visibleFrame
        // visibleFrame（左下原点）→ CG 坐标（左上原点）
        let target = CGRect(x: vf.minX, y: main.maxY - vf.maxY, width: vf.width, height: vf.height)
        let me = ProcessInfo.processInfo.processIdentifier
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? pid_t) != me,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.5,
                  let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: bd) else { continue }
            if b.insetBy(dx: -2, dy: -2).contains(target) {
                return w[kCGWindowOwnerName as String] as? String ?? "?"
            }
        }
        return nil
    }

    private static func primaryScreen() -> NSScreen {
        NSScreen.screens.first ?? NSScreen.main!
    }

    // MARK: - 一键分享：请页面画一张示例图（页面不截屏，只用图标位置）

    private var snapshotDone: ((String?, String?, String?) -> Void)?
    private var snapshotTimeout: DispatchWorkItem?

    func requestSnapshot(_ done: @escaping (_ thumb: String?, _ png: String?, _ err: String?) -> Void) {
        if snapshotDone != nil { done(nil, nil, I18n.t("errBusyImage")); return }
        snapshotDone = done
        let to = DispatchWorkItem { [weak self] in self?.finishSnapshot(nil, nil, I18n.t("errImageTimeout")) }
        snapshotTimeout = to
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: to)
        web.post("{\"t\":\"snapshot\"}")
    }

    private func onSnapshot(_ msg: String) {
        let p = msg.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        if p.count < 3 { finishSnapshot(nil, nil, I18n.t("errBadData")) }
        else if p[1] == "error" { finishSnapshot(nil, nil, p[2]) }
        else { finishSnapshot(p[1], p[2], nil) }
    }

    private func finishSnapshot(_ thumb: String?, _ png: String?, _ err: String?) {
        snapshotTimeout?.cancel(); snapshotTimeout = nil
        let done = snapshotDone
        snapshotDone = nil
        done?(thumb, png, err)
    }

    private var recordDone: ((String?, String?, String?, String?) -> Void)?
    private var recordTimeout: DispatchWorkItem?

    func requestRecording(_ done: @escaping (_ mime: String?, _ poster: String?, _ video: String?, _ err: String?) -> Void) {
        if recordDone != nil { done(nil, nil, nil, I18n.t("errBusyVideo")); return }
        recordDone = done
        let to = DispatchWorkItem { [weak self] in self?.finishRecord(nil, nil, nil, I18n.t("errVideoTimeout")) }
        recordTimeout = to
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: to)
        web.post("{\"t\":\"record\"}")
    }

    private func onRecord(_ msg: String) {
        let p = msg.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        if p.count >= 3 && p[1] == "error" { finishRecord(nil, nil, nil, String(msg.dropFirst(13))) }
        else if p.count < 4 { finishRecord(nil, nil, nil, I18n.t("errBadData")) }
        else { finishRecord(p[1], p[2], p[3], nil) }
    }

    private func finishRecord(_ mime: String?, _ poster: String?, _ video: String?, _ err: String?) {
        recordTimeout?.cancel(); recordTimeout = nil
        let done = recordDone
        recordDone = nil
        done?(mime, poster, video, err)
    }
}
