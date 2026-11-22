import AppKit
import ApplicationServices

// 读取桌面图标的位置。
// Windows 版是跨进程读资源管理器的 SysListView32；macOS 上用辅助功能 API 读 Finder：
//   Finder (AXApplication) → AXScrollArea "desktop" → AXGroup → 每个图标一个 AXImage（叠放组也是一个 AXImage）。
// AX 只给图标图片本身的矩形（全局坐标，点，原点在主屏左上角），不含文字标签；
// 标签按 Finder 桌面的显示设置（图标大小、字号、标签位置）推算，让结果和 Windows 版一样是"图标 + 文字"的整体范围。

struct IconRect: Equatable {
    var left, top, right, bottom: CGFloat
}

final class IconReader {
    enum Status: Equatable {
        case ok
        case noPermission      // 没有辅助功能权限
        case noFinder          // Finder 没在运行或没画桌面
    }

    private var desktopGroup: AXUIElement?
    private var finderPid: pid_t = 0
    private var labelStyle = LabelStyle.read()
    private var styleReadAt = Date()

    /// 返回 nil 表示这次没读到（保持上一次的结果）；visible=false 表示桌面图标被隐藏
    func read(status: inout Status) -> (rects: [IconRect], visible: Bool)? {
        guard AXIsProcessTrusted() else { status = .noPermission; return nil }
        if Date().timeIntervalSince(styleReadAt) > 5 {          // Finder 的显示设置偶尔才变，5 秒读一次
            labelStyle = LabelStyle.read()
            styleReadAt = Date()
        }
        if !labelStyle.desktopShown { status = .ok; return ([], false) }
        guard let group = findDesktopGroup() else { status = .noFinder; return ([], false) }
        status = .ok
        var children: AnyObject?
        let err = AXUIElementCopyAttributeValue(group, kAXChildrenAttribute as CFString, &children)
        guard err == .success, let items = children as? [AXUIElement] else {
            desktopGroup = nil                                     // Finder 重启过：下次重新找
            return nil
        }
        var rects: [IconRect] = []
        rects.reserveCapacity(items.count)
        for item in items {
            guard let frame = Self.frame(of: item), frame.width > 0, frame.height > 0 else { continue }
            let title = Self.string(item, kAXTitleAttribute) ?? Self.string(item, kAXFilenameAttribute) ?? ""
            rects.append(labelStyle.rect(icon: frame, title: title))
        }
        return (rects, true)
    }

    private func findDesktopGroup() -> AXUIElement? {
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            desktopGroup = nil
            return nil
        }
        if let g = desktopGroup, finder.processIdentifier == finderPid { return g }
        finderPid = finder.processIdentifier
        let app = AXUIElementCreateApplication(finderPid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var children: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &children) == .success,
              let kids = children as? [AXUIElement] else { return nil }
        for k in kids where Self.string(k, kAXRoleAttribute) == kAXScrollAreaRole as String {
            var inner: AnyObject?
            guard AXUIElementCopyAttributeValue(k, kAXChildrenAttribute as CFString, &inner) == .success,
                  let groups = inner as? [AXUIElement] else { continue }
            if let g = groups.first(where: { Self.string($0, kAXRoleAttribute) == kAXGroupRole as String }) {
                desktopGroup = g
                Log.write("找到 Finder 桌面（pid \(finderPid)）")
                return g
            }
        }
        return nil
    }

    private static func string(_ e: AXUIElement, _ attr: String) -> String? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success ? v as? String : nil
    }

    private static func frame(of e: AXUIElement) -> CGRect? {
        var v: AnyObject?
        guard AXUIElementCopyAttributeValue(e, "AXFrame" as CFString, &v) == .success, let value = v,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var r = CGRect.zero
        return AXValueGetValue(value as! AXValue, .cgRect, &r) ? r : nil
    }
}

/// Finder 桌面的显示设置（显示 → 查看显示选项）
private struct LabelStyle {
    var iconSize: CGFloat = 64
    var textSize: CGFloat = 12
    var gridSpacing: CGFloat = 54
    var labelOnBottom = true
    var desktopShown = true

    static func read() -> LabelStyle {
        var s = LabelStyle()
        let finder = UserDefaults(suiteName: "com.apple.finder")
        if let create = finder?.object(forKey: "CreateDesktop") as? Bool { s.desktopShown = create }
        if let v = finder?.dictionary(forKey: "DesktopViewSettings")?["IconViewSettings"] as? [String: Any] {
            if let n = v["iconSize"] as? NSNumber { s.iconSize = CGFloat(n.doubleValue) }
            if let n = v["textSize"] as? NSNumber { s.textSize = CGFloat(n.doubleValue) }
            if let n = v["gridSpacing"] as? NSNumber { s.gridSpacing = CGFloat(n.doubleValue) }
            if let n = v["labelOnBottom"] as? NSNumber { s.labelOnBottom = n.boolValue }
        }
        // 台前调度里"显示桌面项目"关掉时，图标也不画
        if let wm = UserDefaults(suiteName: "com.apple.WindowManager"),
           wm.object(forKey: "StandardHideDesktopIcons") as? Bool == true {
            s.desktopShown = false
        }
        return s
    }

    /// 图标矩形 + 推算的文字标签 → 整体矩形
    func rect(icon: CGRect, title: String) -> IconRect {
        let font = NSFont.systemFont(ofSize: textSize)
        let lineH = ceil(font.ascender - font.descender + font.leading) + 1
        let textW = ceil((title as NSString).size(withAttributes: [.font: font]).width) + 8
        if labelOnBottom {
            // 标签最宽约为一个网格单元，超出就折成两行
            let maxW = max(icon.width + gridSpacing, icon.width + 24)
            let w = min(textW, maxW)
            let lines: CGFloat = textW > maxW ? 2 : 1
            let labelTop = icon.maxY + 3
            let half = max(icon.width, w) / 2
            return IconRect(left: icon.midX - half, top: icon.minY,
                            right: icon.midX + half, bottom: labelTop + lines * lineH)
        } else {
            let maxW: CGFloat = 160
            let w = min(textW, maxW)
            let lines: CGFloat = textW > maxW ? 2 : 1
            let h = max(icon.height, lines * lineH)
            return IconRect(left: icon.minX, top: icon.midY - h / 2,
                            right: icon.maxX + 4 + w, bottom: icon.midY + h / 2)
        }
    }
}
