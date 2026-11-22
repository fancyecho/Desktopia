import Foundation

// 主题页面的文字表（prototype/i18n/*.json）里有些话是写给 Windows 的（"开机自动启动"、托盘、Windows 设置）。
// prototype/ 保持与上游一致，方便同步；这里在提供 i18n 文件时把 Mac 版的说法覆盖进去。
enum MacText {
    static let overrides: [String: [String: Any]] = [
        "en": [
            "ui": [
                "autostart": "Open at login",
                "autostartTitle": "Run Desktopia automatically when you log in",
                "autostartBlocked": "Open at login may have been blocked",
                "autostartWarnGeneric": "Desktopia didn't open at login this time. Check System Settings → General → Login Items & Extensions and make sure Desktopia is allowed.",
                "helpWallpaperQ": "The scenery ignores my desktop icons. How do I fix it?",
                "helpWallpaperA": "Desktopia reads icon positions from Finder through macOS Accessibility. Without that permission it can only draw open sea.",
                "helpWallpaperStep1": "Open System Settings → Privacy & Security → Accessibility.",
                "helpWallpaperStep2": "Turn on Desktopia. If it isn't listed, click + and add it from Applications.",
                "helpWallpaperStep3": "Quit Desktopia from the menu bar icon and open it again.",
                "purchaseMessage": "This theme is part of the official Deskland Wallpaper edition for Windows by the original authors. Desktopia is an unofficial macOS version and can't unlock it.",
            ],
            "host": [
                "trayAutostart": "Open at Login",
                "trayExit": "Quit (restore wallpaper)",
                "errRebuilt": "The wallpaper window kept closing, so Desktopia has stopped.",
                "welcomeTitle": "Desktopia is running",
            ],
        ],
        "zh-CN": [
            "ui": [
                "autostart": "登录时打开",
                "autostartTitle": "登录 Mac 后自动运行 Desktopia",
                "autostartBlocked": "登录时打开可能被拦截了",
                "autostartWarnGeneric": "这次登录时 Desktopia 没有自动打开。请在 系统设置 → 通用 → 登录项与扩展 里确认 Desktopia 已允许。",
                "helpWallpaperQ": "风景没有避开桌面图标，怎么办？",
                "helpWallpaperA": "Desktopia 通过 macOS 的“辅助功能”从 Finder 读取图标位置。没有这个权限时只能画一片海。",
                "helpWallpaperStep1": "打开 系统设置 → 隐私与安全性 → 辅助功能。",
                "helpWallpaperStep2": "打开 Desktopia 的开关；列表里没有的话，点 + 从“应用程序”里添加。",
                "helpWallpaperStep3": "从菜单栏图标退出 Desktopia，再重新打开。",
                "purchaseMessage": "这个主题属于 Deskland 原作者的 Windows 壁纸版。Desktopia 是非官方的 macOS 版，无法解锁它。",
            ],
            "host": [
                "trayAutostart": "登录时打开",
                "trayExit": "退出（恢复原壁纸）",
                "errRebuilt": "壁纸窗口反复被关闭，Desktopia 已停止。",
                "welcomeTitle": "Desktopia 已在运行",
            ],
        ],
    ]
}
