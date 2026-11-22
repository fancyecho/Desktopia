import Foundation

// Desktopia 自己加的主题放在 themes-mac/（和 prototype/ 同级），prototype/ 保持与上游一致。
// 页面读文件时：先找 themes-mac/，再找 prototype/；themes.json 和 i18n/*.json 两边合并。
// 合并规则与 scripts/merge.py 相同（浏览器预览用的是那份）。
enum Overlay {
    static let extraDir = Paths.pageDir.deletingLastPathComponent().appendingPathComponent("themes-mac", isDirectory: true)

    /// rel 形如 "/woodland.html"；返回内容和实际文件（用来判断 MIME）
    static func load(_ rel: String) -> (data: Data, file: URL)? {
        if rel == "/themes.json", let d = try? JSONSerialization.data(withJSONObject: mergedThemes()) {
            return (d, Paths.pageDir.appendingPathComponent("themes.json"))
        }
        if rel.hasPrefix("/i18n/"), rel.hasSuffix(".json") {
            let code = String(rel.dropFirst(6).dropLast(5))
            if let root = mergedI18n(code), let d = try? JSONSerialization.data(withJSONObject: root) {
                return (d, Paths.pageDir.appendingPathComponent(String(rel.dropFirst())))
            }
        }
        for root in [extraDir, Paths.pageDir] {
            let file = root.appendingPathComponent(rel).standardizedFileURL
            guard file.path.hasPrefix(root.standardizedFileURL.path + "/") else { continue }   // 不允许跳出目录
            if var d = try? Data(contentsOf: file, options: .mappedIfSafe) {
                if rel == "/settings.html" { d = rebrand(d) }
                return (d, file)
            }
        }
        return nil
    }

    /// 设置页里写死的产品名（标题、顶栏、下载文件名）换成 Desktopia；上游文件本身不改
    private static func rebrand(_ data: Data) -> Data {
        var s = String(decoding: data, as: UTF8.self)
        for (a, b) in [("<title>Deskland Preview</title>", "<title>Desktopia</title>"),
                       ("<div class=\"brand\">Deskland Preview</div>", "<div class=\"brand\">Desktopia</div>"),
                       ("download=\"Deskland.png\"", "download=\"Desktopia.png\""),
                       ("'Deskland.' + (video", "'Desktopia.' + (video")] {
            s = s.replacingOccurrences(of: a, with: b)
        }
        return Data(s.utf8)
    }

    static func mergedThemes() -> [String: Any] {
        guard var base = readJSON(Paths.pageDir.appendingPathComponent("themes.json")),
              var list = base["themes"] as? [[String: Any]] else { return [:] }
        let extra = readJSON(extraDir.appendingPathComponent("themes.json"))?["themes"] as? [[String: Any]] ?? []
        for var t in extra {
            let after = t.removeValue(forKey: "after") as? String
            guard let id = t["id"] as? String else { continue }
            list.removeAll { ($0["id"] as? String) == id }
            let i = list.firstIndex { ($0["id"] as? String) == after }.map { $0 + 1 } ?? list.count
            list.insert(t, at: i)
        }
        base["themes"] = list
        return base
    }

    static func mergedI18n(_ code: String) -> [String: Any]? {
        guard var root = readJSON(Paths.pageDir.appendingPathComponent("i18n/\(code).json")) else { return nil }
        if let extra = readJSON(extraDir.appendingPathComponent("i18n/\(code).json")) {
            merge(&root, extra)
        }
        if let mac = MacText.overrides[code] { merge(&root, mac) }
        return root
    }

    /// 每一段（ui / host / themes）里按 key 覆盖
    private static func merge(_ root: inout [String: Any], _ extra: [String: Any]) {
        for (section, vals) in extra {
            guard let vals = vals as? [String: Any] else { continue }
            var sec = root[section] as? [String: Any] ?? [:]
            for (k, v) in vals { sec[k] = v }
            root[section] = sec
        }
    }

    private static func readJSON(_ url: URL) -> [String: Any]? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }
}
