import AppKit

// 数据目录、日志、设置、界面语言、主题清单。对应 Windows 版 DesktopHost.cs 里的 Log / Settings / I18n / Themes。

enum Paths {
    static let dataDir: URL = {
        if let custom = ProcessInfo.processInfo.environment["DESKLAND_PROFILE_DIR"], custom.hasPrefix("/") {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Desktopia", isDirectory: true)
        // 改名前（DesklandMac）的设置和日志搬过来，只搬一次
        let old = base.appendingPathComponent("DesklandMac", isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: old.path) { try? fm.moveItem(at: old, to: dir) }
        return dir
    }()
    static let logFile = dataDir.appendingPathComponent("host.log")
    static let settingsFile = dataDir.appendingPathComponent("settings.json")
    static let shareDir: URL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Desktopia", isDirectory: true)

    /// 主题页面目录：.app 里是 Resources/prototype；直接 `swift run` 时用工程里的 prototype/
    static let pageDir: URL = {
        if let arg = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) {
            return URL(fileURLWithPath: arg, isDirectory: true)
        }
        if let res = Bundle.main.resourceURL?.appendingPathComponent("prototype", isDirectory: true),
           FileManager.default.fileExists(atPath: res.appendingPathComponent("themes.json").path) {
            return res
        }
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("prototype", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("themes.json").path) { return candidate }
            dir.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("prototype", isDirectory: true)
    }()
}

enum Log {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss "
        return f
    }()

    static func write(_ msg: String) {
        let line = formatter.string(from: Date()) + msg + "\n"
        try? FileManager.default.createDirectory(at: Paths.dataDir, withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: Paths.logFile) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            try? h.close()
        } else {
            try? line.write(to: Paths.logFile, atomically: true, encoding: .utf8)
        }
        #if DEBUG
        FileHandle.standardError.write(line.data(using: .utf8)!)
        #endif
    }
}

enum JSON {
    static func parse(_ s: String) -> Any? {
        guard let d = s.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])
    }

    static func stringify(_ o: Any) -> String {
        guard JSONSerialization.isValidJSONObject(o),
              let d = try? JSONSerialization.data(withJSONObject: o, options: [.withoutEscapingSlashes]) else { return "null" }
        return String(decoding: d, as: UTF8.self)
    }

    /// 把任意字符串变成 JS 字符串字面量（带引号），用于 evaluateJavaScript
    static func literal(_ s: String) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed]) else { return "\"\"" }
        // U+2028 / U+2029 在旧 JS 引擎里不能出现在字符串字面量中
        return String(decoding: d, as: UTF8.self)
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}

/// 用户设置：当前主题 + 每个主题改过的参数，存在 settings.json（格式与 Windows 版相同）
final class Settings {
    static let shared = Settings()
    var theme = "beach"
    var lang = "auto"
    var params: [String: [String: Any]] = [:]
    private var saveWork: DispatchWorkItem?

    func load() {
        guard let data = try? Data(contentsOf: Paths.settingsFile),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let t = root["theme"] as? String { theme = t }
        if let l = root["lang"] as? String { lang = l }
        if let p = root["params"] as? [String: Any] {
            for (k, v) in p { if let d = v as? [String: Any] { params[k] = d } }
        }
        Log.write("已读取设置：主题 \(theme)")
    }

    func save() {
        saveWork?.cancel(); saveWork = nil
        do {
            try FileManager.default.createDirectory(at: Paths.dataDir, withIntermediateDirectories: true)
            let root: [String: Any] = ["version": 1, "theme": theme, "lang": lang, "params": params]
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: Paths.settingsFile, options: .atomic)
        } catch {
            Log.write("保存设置失败：\(error.localizedDescription)")
        }
    }

    /// 600ms 内的连续修改合并成一次写盘（拖滑块时不会狂写文件）
    func saveSoon() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func flush() { if saveWork != nil { save() } }

    func params(for theme: String) -> [String: Any] { params[theme] ?? [:] }
}

/// 界面语言：文字表在 prototype/i18n/<语言>.json 的 "host" 段
enum I18n {
    static let supported = ["zh-CN", "en"]
    private(set) static var code = "zh-CN"
    private(set) static var sys = "en"
    private static var cur: [String: Any] = [:], en: [String: Any] = [:], zh: [String: Any] = [:]

    static func systemLanguage() -> String {
        let pref = (Locale.preferredLanguages.first ?? "en").lowercased()
        return pref.hasPrefix("zh") ? "zh-CN" : "en"
    }

    static func load(setting: String) {
        sys = systemLanguage()
        code = supported.contains(setting) ? setting : sys
        zh = read("zh-CN"); en = read("en")
        cur = code == "zh-CN" ? zh : en
        Log.write("界面语言：\(code)（设置：\(setting)，系统：\(sys)）")
    }

    private static func read(_ c: String) -> [String: Any] {
        Overlay.mergedI18n(c)?["host"] as? [String: Any] ?? [:]
    }

    static func t(_ key: String, _ vars: [String: String] = [:]) -> String {
        var s = (cur[key] ?? en[key] ?? zh[key]) as? String ?? key
        for (k, v) in vars { s = s.replacingOccurrences(of: "{\(k)}", with: v) }
        return s
    }
}

/// 主题清单 prototype/themes.json：只有 status=ready 且 product=free 的主题能用
enum Themes {
    private static func find(_ id: String) -> [String: Any]? {
        guard let list = Overlay.mergedThemes()["themes"] as? [[String: Any]] else {
            Log.write("读取 themes.json 失败")
            return nil
        }
        return list.first { ($0["id"] as? String) == id && ($0["status"] as? String) == "ready" }
    }

    static func page(for id: String) -> String? { find(id)?["page"] as? String }

    static func allowed(_ id: String) -> Bool {
        guard let theme = find(id), theme["page"] is String else { return false }
        return (theme["product"] as? String) == "free"
    }
}
