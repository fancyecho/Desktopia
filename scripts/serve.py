#!/usr/bin/env python3
"""本地预览：把 themes-mac/ 叠在 prototype/ 上（和 App 里一样），themes.json 与 i18n 合并。
用法：python3 scripts/serve.py [端口]，然后打开 http://localhost:5179/settings.html 或 /woodland.html"""
import http.server, json, os, sys, urllib.parse

import importlib.util
_spec = importlib.util.spec_from_file_location('merge', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'merge.py'))
_m = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(_m)
BASE, EXTRA, merged_themes, merged_i18n = _m.BASE, _m.EXTRA, _m.merged_themes, _m.merged_i18n

class H(http.server.SimpleHTTPRequestHandler):
    def send_json(self, obj):
        b = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(200); self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Cache-Control', 'no-cache'); self.send_header('Content-Length', str(len(b))); self.end_headers()
        self.wfile.write(b)
    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path == '/themes.json': return self.send_json(merged_themes())
        if path.startswith('/i18n/') and path.endswith('.json'): return self.send_json(merged_i18n(os.path.basename(path)))
        return super().do_GET()
    def translate_path(self, path):
        rel = urllib.parse.unquote(urllib.parse.urlparse(path).path).lstrip('/')
        for root in (EXTRA, BASE):
            p = os.path.normpath(os.path.join(root, rel))
            if p.startswith(root) and os.path.exists(p): return p
        return os.path.join(BASE, rel)
    def end_headers(self):
        self.send_header('Cache-Control', 'no-cache'); super().end_headers()

port = int(sys.argv[1]) if len(sys.argv) > 1 else 5179
http.server.ThreadingHTTPServer(('127.0.0.1', port), H).serve_forever()
