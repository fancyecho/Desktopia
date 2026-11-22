import AppKit
import UniformTypeIdentifiers
import WebKit

// 主题页面和宿主之间的桥。
// 页面里写的是 WebView2 的接口：window.chrome.webview.postMessage / addEventListener('message')。
// 这里在页面加载前注入一段兼容代码，把它接到 WKWebView 的 messageHandlers 上，所以 prototype/ 下的页面一行都不用改。

private let shimSource = """
(function () {
  if (window.chrome && window.chrome.webview) return;
  const listeners = [];
  window.chrome = window.chrome || {};
  window.chrome.webview = {
    postMessage(m) {
      window.webkit.messageHandlers.host.postMessage(typeof m === 'string' ? m : JSON.stringify(m));
    },
    addEventListener(type, fn) { if (type === 'message' && typeof fn === 'function') listeners.push(fn); },
    removeEventListener(type, fn) { const i = listeners.indexOf(fn); if (i >= 0) listeners.splice(i, 1); },
  };
  window.__desktopiaDeliver = function (data) {
    for (const fn of listeners.slice()) {
      try { fn({ data: data }); } catch (e) { console.error(e); }
    }
  };
})();
"""

/// desktopia://app/... → prototype 目录；desktopia://share/... → 分享图片目录。
/// 相当于 Windows 版的 SetVirtualHostNameToFolderMapping("app.local" / "share.local")。
final class LocalSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "desktopia"

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { task.didFailWithError(URLError(.badURL)); return }
        let rel = url.path.removingPercentEncoding ?? url.path
        guard let (data, file) = load(host: url.host, rel: rel) else {
            let resp = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!
            task.didReceive(resp); task.didReceive(Data()); task.didFinish()
            return
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        var headers = ["Content-Type": mime, "Cache-Control": "no-cache", "Accept-Ranges": "bytes",
                       "Access-Control-Allow-Origin": "*"]
        var body = data
        var status = 200
        // <video> 播放分享动画时会按字节范围请求
        if let range = task.request.value(forHTTPHeaderField: "Range"), let r = parseRange(range, count: data.count) {
            body = data.subdata(in: r)
            status = 206
            headers["Content-Range"] = "bytes \(r.lowerBound)-\(r.upperBound - 1)/\(data.count)"
        }
        headers["Content-Length"] = String(body.count)
        let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(resp)
        task.didReceive(body)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private func load(host: String?, rel: String) -> (Data, URL)? {
        switch host {
        case "app":
            return Overlay.load(rel).map { ($0.data, $0.file) }
        case "share":
            let root = Paths.shareDir.standardizedFileURL
            let file = root.appendingPathComponent(rel).standardizedFileURL
            guard file.path.hasPrefix(root.path + "/"), let d = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
            return (d, file)
        default:
            return nil
        }
    }

    private func parseRange(_ header: String, count: Int) -> Range<Int>? {
        guard header.hasPrefix("bytes="), count > 0 else { return nil }
        let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty, let suffix = Int(parts[1]) {
            return max(0, count - suffix)..<count
        }
        guard let start = Int(parts[0]), start < count else { return nil }
        let end = Int(parts[1]).map { min($0, count - 1) } ?? count - 1
        return end >= start ? start..<(end + 1) : nil
    }
}

/// 一个装着 WKWebView 的宿主：负责注入兼容代码、收消息、发消息
final class WebHost: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    var onMessage: ((String) -> Void)?
    var onCrash: (() -> Void)?

    init(frame: NSRect) {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(LocalSchemeHandler(), forURLScheme: LocalSchemeHandler.scheme)
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let ucc = WKUserContentController()
        // 只注入主框架：设置页里的预览 iframe 走的是 window.parent.postMessage，不能被当成壁纸页
        ucc.addUserScript(WKUserScript(source: shimSource, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController = ucc
        webView = WKWebView(frame: frame, configuration: config)
        super.init()
        ucc.add(WeakMessageHandler(self), name: "host")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.autoresizingMask = [.width, .height]
        if #available(macOS 13.3, *) { webView.isInspectable = true }
    }

    func load(page: String) {
        guard let url = URL(string: "\(LocalSchemeHandler.scheme)://app/\(page)") else { return }
        webView.load(URLRequest(url: url))
    }

    func post(_ json: String) {
        webView.evaluateJavaScript("window.__desktopiaDeliver && window.__desktopiaDeliver(\(JSON.literal(json)))", completionHandler: nil)
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let s = message.body as? String else { return }
        onMessage?(s)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Log.write("网页进程退出，重新载入")
        onCrash?()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Log.write("页面加载失败：\(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Log.write("页面加载失败：\(error.localizedDescription)")
    }

    // 页面里的外部链接（帮助、官网）交给系统浏览器
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = action.request.url, let scheme = url.scheme, scheme == "http" || scheme == "https" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { NSWorkspace.shared.open(url) }
        return nil
    }

    func tearDown() {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "host")
        webView.stopLoading()
        webView.removeFromSuperview()
    }
}

/// WKUserContentController 会强引用 handler，用一层弱引用避免循环引用
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(ucc, didReceive: message)
    }
}
