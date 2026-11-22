import AppKit

// Desktopia：基于 Deskland Preview（GPL-3.0）修改的 macOS 版，非官方，与 Deskland 原作者无关。
// 主题页面（prototype/）与 Windows 版共用；这里只负责把页面挂到桌面层、读 Finder 的桌面图标、菜单栏和设置窗口。
//
//   Desktopia                启动壁纸并打开设置；已在运行时打开设置
//   Desktopia   --autostart  后台启动，不弹设置（登录项启动时用）
//   Desktopia   --settings   让正在运行的实例打开设置
//   Desktopia   --exit       让正在运行的实例退出（桌面恢复系统壁纸）

let args = CommandLine.arguments.dropFirst()
let dnc = DistributedNotificationCenter.default()
if args.contains("--exit") {
    dnc.postNotificationName(Remote.exit, object: nil, userInfo: nil, deliverImmediately: true)
    exit(0)
}
if let i = args.firstIndex(of: "--debug-share") {
    let kind = args.index(after: i) < args.endIndex ? args[args.index(after: i)] : "image"
    dnc.postNotificationName(Remote.shareTest, object: kind, userInfo: nil, deliverImmediately: true)
    exit(0)
}

// 单实例：已经有一个在跑就让它打开设置
let me = ProcessInfo.processInfo.processIdentifier
let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
    .filter { $0.processIdentifier != me }
let lockFile = Paths.dataDir.appendingPathComponent("instance.lock")
try? FileManager.default.createDirectory(at: Paths.dataDir, withIntermediateDirectories: true)
let lockFd = open(lockFile.path, O_CREAT | O_RDWR, 0o644)
if !others.isEmpty || (lockFd >= 0 && flock(lockFd, LOCK_EX | LOCK_NB) != 0) {
    if !args.contains("--autostart") {
        dnc.postNotificationName(Remote.settings, object: nil, userInfo: nil, deliverImmediately: true)
    }
    exit(0)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)                 // 只在菜单栏常驻，不占 Dock
let delegate = AppDelegate(showSettings: !args.contains("--autostart"))
app.delegate = delegate
app.run()
