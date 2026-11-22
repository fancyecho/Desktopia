#!/usr/bin/env python3
"""把 prototype/ 和 themes-mac/ 合并成一个静态目录（themes.json、i18n 已合并），供浏览器预览。
用法：python3 scripts/stage-preview.py <输出目录>"""
import importlib.util, json, os, shutil, sys
here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('serve_merge', os.path.join(here, 'merge.py'))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
out = sys.argv[1]
os.makedirs(out, exist_ok=True)
for root in (m.BASE, m.EXTRA):
    shutil.copytree(root, out, dirs_exist_ok=True)
json.dump(m.merged_themes(), open(os.path.join(out, 'themes.json'), 'w', encoding='utf-8'), ensure_ascii=False)
for name in os.listdir(os.path.join(m.BASE, 'i18n')):
    json.dump(m.merged_i18n(name), open(os.path.join(out, 'i18n', name), 'w', encoding='utf-8'), ensure_ascii=False)
print('staged', out)
