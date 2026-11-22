"""themes-mac/ 叠加到 prototype/ 的合并规则（serve.py、stage-preview.py 共用；App 里 Swift 端用同样的规则）"""
import json, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASE, EXTRA = os.path.join(ROOT, 'prototype'), os.path.join(ROOT, 'themes-mac')

def merged_themes():
    base = json.load(open(os.path.join(BASE, 'themes.json'), encoding='utf-8'))
    extra = json.load(open(os.path.join(EXTRA, 'themes.json'), encoding='utf-8'))
    for t in extra['themes']:
        t = dict(t); after = t.pop('after', None)
        ids = [x['id'] for x in base['themes']]
        base['themes'] = [x for x in base['themes'] if x['id'] != t['id']]
        i = ids.index(after) + 1 if after in ids else len(base['themes'])
        base['themes'].insert(i, t)
    return base

def merged_i18n(name):
    base = json.load(open(os.path.join(BASE, 'i18n', name), encoding='utf-8'))
    p = os.path.join(EXTRA, 'i18n', name)
    if os.path.exists(p):
        for sec, vals in json.load(open(p, encoding='utf-8')).items():
            base.setdefault(sec, {}).update(vals)
    return base

