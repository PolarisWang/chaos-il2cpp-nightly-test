#!/usr/bin/env python3
"""Test suite for the unified Feishu notification system.

Covers: Notice contract, engine rendering, all three sources, level→color
mapping, dedup, and the fallback paths.

Run: python3 scripts/test_feishu_engine.py
"""

import json
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from feishu.notice import Notice, InfoLine, RED, YELLOW, INFO, RECOVERED
from feishu import engine
from feishu.sources import review as src_review
from feishu.sources import nightly as src_nightly
from feishu.sources import health as src_health

PASS = 0
FAIL = 0


def check(name, cond, detail=''):
    global PASS, FAIL
    if cond:
        PASS += 1
        print('  ✅ %s' % name)
    else:
        FAIL += 1
        print('  ❌ %s %s' % (name, detail))


def section(t):
    print('\n=== %s ===' % t)


def tmpjson(obj):
    p = tempfile.mktemp(suffix='.json')
    with open(p, 'w') as f:
        json.dump(obj, f, ensure_ascii=False)
    return p


# ─────────────────────────────────────────────────────────────
section('1. Notice contract')

n = Notice(channel='review', level=INFO, title='t')
check('constructs with defaults', n.channel == 'review' and n.level == INFO)
check('body defaults empty', n.body == [])
check('tags defaults empty', n.tags == {})

try:
    Notice(channel='review', level='BOGUS', title='t')
    check('rejects invalid level', False, '(did not raise)')
except ValueError:
    check('rejects invalid level', True)

try:
    Notice(channel='', level=INFO, title='t')
    check('rejects empty channel', False, '(did not raise)')
except ValueError:
    check('rejects empty channel', True)

try:
    Notice(channel='review', level=INFO, title='')
    check('rejects empty title', False, '(did not raise)')
except ValueError:
    check('rejects empty title', True)

check('InfoLine.is_plain()', InfoLine('', 'x').is_plain() and
      not InfoLine('L', 'x').is_plain())
check('plain_body flattens', 'L\nx' in Notice(
    channel='c', level=INFO, title='t',
    body=[InfoLine('L', 'x')]).plain_body())


# ─────────────────────────────────────────────────────────────
section('2. Level → color mapping (single source of truth)')

expected = {'RED': 'red', 'YELLOW': 'orange', 'INFO': 'green', 'RECOVERED': 'green'}
for lvl, want in expected.items():
    card = engine._plan_card(Notice(channel='review', level=lvl, title='t'))
    got = card['card']['header']['template']
    check('%s → %s' % (lvl, want), got == want, '(got %s)' % got)

check('all colors are valid', all(
    engine._plan_card(Notice(channel='review', level=l, title='t'))
    ['card']['header']['template'] in engine.VALID_COLORS
    for l in (RED, YELLOW, INFO, RECOVERED)))


# ─────────────────────────────────────────────────────────────
section('3. Card structure')

n = Notice(channel='review', level=RED, title='boom',
           body=[InfoLine('影响范围', 'x')],
           actions=[('Go', 'http://x')],
           footer_text='footer')
card = engine._plan_card(n)
check('msg_type interactive', card['msg_type'] == 'interactive')
check('has header title', 'boom' in card['card']['header']['title']['content'])
check('RED header has emoji', '🔴' in card['card']['header']['title']['content'])
check('RED header has tag', '需人工处理' in card['card']['header']['title']['content'])
check('body div present',
      any(e.get('tag') == 'div' for e in card['card']['elements']))
check('action button present',
      any(e.get('tag') == 'action' for e in card['card']['elements']))
check('note footer present',
      card['card']['elements'][-1]['tag'] == 'note')

# INFO has no tag
n_info = Notice(channel='review', level=INFO, title='ok')
c_info = engine._plan_card(n_info)
check('INFO has no tag text', '【】' not in c_info['card']['header']['title']['content'])

# empty body → no div
n_empty = Notice(channel='review', level=INFO, title='t')
c_empty = engine._plan_card(n_empty)
check('empty body omits div',
      not any(e.get('tag') == 'div' for e in c_empty['card']['elements']))


# ─────────────────────────────────────────────────────────────
section('4. review source')

# 4a: normal findings
p = tmpjson({
    'summary': {'严重': 1, '中': 2, '轻': 0, '建议': 0, 'total_findings': 3},
    'findings': [
        {'severity': '严重', 'file': 'a.cpp', 'line': 10, 'message': 'bad'},
        {'severity': '中', 'file': 'b.cpp', 'line': 20, 'message': 'meh'},
        {'severity': '中', 'file': 'c.cpp', 'line': 30, 'message': 'hmm'},
    ],
    'low_confidence': False, 'incomplete': False, 'docs_only': False,
    'coverage': {'total_files': 3, 'covered_files': 3,
                 'skipped_files': [], 'skipped_count': 0},
    'commits': [{'sha': 'abcdef1234567890', 'subject': 'feat: x'}],
    'meta': {'from': 'aaa', 'to': 'bbb'},
})
n = src_review.to_notice(p, build_url='http://b/1', date_tag='D', file_sha='SHA')
check('findings → INFO', n.level == INFO, '(got %s)' % n.level)
check('findings → 3 in title', '3' in n.title, n.title)
check('findings → has 问题列表',
      any(l.label == '问题列表' for l in n.body))
check('findings → has 风险概览', any(l.label == '风险概览' for l in n.body))
check('findings → has 覆盖情况', any(l.label == '覆盖情况' for l in n.body))
check('findings → has 提交', any(l.label == '提交' for l in n.body))
fl = [l for l in n.body if l.label == '问题列表'][0].content
check('finding line has severity', '[严重]' in fl)
check('finding line links to blob', 'blob/SHA/a.cpp#L10' in fl)
check('finding link is markdown', '](http' in fl)
check('all 3 findings rendered', fl.count('#') >= 3, fl[:200])

# 4b: zero findings + low_confidence → YELLOW
p2 = tmpjson({
    'summary': {'严重': 0, '中': 0, '轻': 0, '建议': 0, 'total_findings': 0},
    'findings': [], 'low_confidence': True, 'incomplete': False,
})
n2 = src_review.to_notice(p2, build_url='http://b/2', date_tag='D')
check('0 findings + low_conf → YELLOW', n2.level == YELLOW, '(got %s)' % n2.level)
check('low_conf body warns', '置信度低' in n2.body[0].content or
      '低' in n2.body[0].content)
c2 = engine._plan_card(n2)
check('low_conf card is orange', c2['card']['header']['template'] == 'orange')

# 4c: zero findings, not low_conf → INFO clean
p3 = tmpjson({
    'summary': {'严重': 0, '中': 0, '轻': 0, '建议': 0, 'total_findings': 0},
    'findings': [], 'low_confidence': False, 'incomplete': False,
})
n3 = src_review.to_notice(p3, build_url='http://b/3', date_tag='D')
check('0 findings clean → INFO', n3.level == INFO)
check('clean body says 未发现', '未发现' in n3.body[0].content)
check('clean card is green',
      engine._plan_card(n3)['card']['header']['template'] == 'green')

# 4d: missing file → RED
n4 = src_review.to_notice('/tmp/definitely-does-not-exist-xyz.json',
                          build_url='http://b/4', date_tag='D')
check('missing findings → RED', n4.level == RED, '(got %s)' % n4.level)
check('missing findings title', '未完成' in n4.title, n4.title)
check('missing findings card is red',
      engine._plan_card(n4)['card']['header']['template'] == 'red')

# 4e: incomplete coverage
p5 = tmpjson({
    'summary': {'严重': 0, '中': 1, '轻': 0, '建议': 0, 'total_findings': 1},
    'findings': [{'severity': '中', 'file': 'x.cpp', 'line': 1, 'message': 'm'}],
    'low_confidence': True, 'incomplete': True,
    'coverage': {'total_files': 10, 'covered_files': 7,
                 'skipped_files': ['a.cpp', 'b.cpp', 'c.cpp'], 'skipped_count': 3},
})
n5 = src_review.to_notice(p5, build_url='http://b/5', date_tag='D',
                          skipped_files='a.cpp,b.cpp,c.cpp')
check('incomplete → YELLOW', n5.level == YELLOW, '(got %s)' % n5.level)
cov = [l for l in n5.body if l.label == '覆盖情况'][0].content
check('coverage shows 7/10', '7/10' in cov, cov)
check('coverage names skipped', 'a.cpp' in cov, cov)
check('incomplete still shows findings',
      any(l.label == '问题列表' for l in n5.body))

# 4f: finding with no file
p6 = tmpjson({
    'summary': {'严重': 1, '中': 0, '轻': 0, '建议': 0, 'total_findings': 1},
    'findings': [{'severity': '严重', 'line': 43, 'message': 'no file here'}],
    'low_confidence': False, 'incomplete': False,
})
n6 = src_review.to_notice(p6, build_url='http://b/6', date_tag='D')
fl6 = [l for l in n6.body if l.label == '问题列表'][0].content
check('missing file flagged visibly', '未标注文件' in fl6, fl6)
check('missing file has no broken link', '](' not in fl6, fl6)

# 4g: ghost finding (empty message) dropped
p7 = tmpjson({
    'summary': {'严重': 0, '中': 0, '轻': 0, '建议': 0, 'total_findings': 0},
    'findings': [{'severity': '中', 'file': 'x', 'line': 1, 'message': '   '}],
    'low_confidence': False, 'incomplete': False,
})
n7 = src_review.to_notice(p7, date_tag='D')
check('ghost finding dropped', not any(l.label == '问题列表' for l in n7.body))


# ─────────────────────────────────────────────────────────────
section('5. nightly source')

payload = {
    'platforms': {}, 'missing_platforms': [],
    'verdict': {'level': 'yellow', 'word': '部分通过', 'reason': 'linux 9/45'},
    'trend': {}, 'body_lines': [
        '🟡 **部分通过** — linux 9/45',
        '**Linux**  ⚠️ 9/45  ↓2',
        '　linux 归因: `assert`×5',
    ],
}
pn = tmpjson(payload)
nn = src_nightly.to_notice(pn, build_num='285', date_tag='20260913',
                           run_tag='run1', build_url='http://b/285',
                           report_url='http://r/285')
check('nightly yellow → YELLOW', nn.level == YELLOW, '(got %s)' % nn.level)
check('nightly has 2 actions', len(nn.actions) == 2)
check('nightly title has build num', '285' in nn.title, nn.title)
check('nightly title has run label', '凌晨' in nn.title, nn.title)
check('nightly dedup key set', nn.dedup_key == 'nightly:20260913:run1',
      nn.dedup_key)
check('nightly Linux row is labelled',
      any(l.label == 'Linux' for l in nn.body))

# run2 label
nn2 = src_nightly.to_notice(pn, build_num='285', date_tag='D',
                            run_tag='run2', build_url='http://b')
check('run2 → 午后 label', '午后' in nn2.title, nn2.title)

# red verdict
pr = tmpjson({'verdict': {'level': 'red', 'word': '需要处理', 'reason': 'linux 全部失败'},
              'body_lines': ['🔴 **需要处理** — linux 全部失败'],
              'missing_platforms': [], 'platforms': {}, 'trend': {}})
nr = src_nightly.to_notice(pr, build_num='1', date_tag='D')
check('nightly red → RED', nr.level == RED)
check('nightly red card is red',
      engine._plan_card(nr)['card']['header']['template'] == 'red')

# green verdict
pg = tmpjson({'verdict': {'level': 'green', 'word': '正常', 'reason': ''},
              'body_lines': ['✅ **正常**'], 'missing_platforms': [],
              'platforms': {}, 'trend': {}})
ng = src_nightly.to_notice(pg, build_num='1', date_tag='D')
check('nightly green → INFO', ng.level == INFO)
check('nightly green card is green',
      engine._plan_card(ng)['card']['header']['template'] == 'green')

# missing platform
pm = tmpjson({'verdict': {'level': 'red', 'word': '需要处理', 'reason': '缺少平台'},
              'body_lines': [], 'missing_platforms': ['windows'],
              'platforms': {}, 'trend': {}})
nm = src_nightly.to_notice(pm, build_num='1', date_tag='D')
check('missing platform in body', any(l.label == '缺少平台' for l in nm.body))

# unparseable payload → RED
nb = src_nightly.to_notice('/tmp/no-such-payload.json', build_num='9', date_tag='D')
check('bad payload → RED', nb.level == RED, '(got %s)' % nb.level)


# ─────────────────────────────────────────────────────────────
section('6. health source')

h = src_health.notice_from_alert(
    event='new_failure', title='代码审查构建失败',
    impact='构建 #1 失败', cause='exit 129', action='看日志',
    build_link='http://b/1', date_tag='D')
check('new_failure → RED', h.level == RED)
check('health has 影响范围', any(l.label == '影响范围' for l in h.body))
check('health has 原因', any(l.label == '原因' for l in h.body))
check('health has 建议操作', any(l.label == '建议操作' for l in h.body))

hr = src_health.notice_from_alert(event='recovered', title='已恢复',
                                  impact='OK', date_tag='D')
check('recovered → RECOVERED', hr.level == RECOVERED)
check('recovered card is green',
      engine._plan_card(hr)['card']['header']['template'] == 'green')

hs = src_health.notice_from_alert(event='sustained_failure', title='持续失败',
                                  impact='x', date_tag='D')
check('sustained_failure → RED', hs.level == RED)

for ev, lvl in (('stuck_lock', RED), ('stalled', RED), ('system', INFO)):
    hn = src_health.notice_from_alert(event=ev, title='t', impact='x')
    check('%s → %s' % (ev, lvl), hn.level == lvl, '(got %s)' % hn.level)

# checks-based path
checks = {'cpu': {'level': 'CRIT', 'msg': 'load 40'},
          'disk': {'level': 'OK', 'msg': 'fine'}}
hc = src_health.to_notice(checks, event='new_failure')
check('CRIT checks → RED', hc.level == RED)
check('CRIT checks body lists msg', 'load 40' in hc.body[0].content)

hw = src_health.to_notice({'cpu': {'level': 'WARN', 'msg': 'load 18'}},
                          event='new_failure')
check('WARN checks → YELLOW', hw.level == YELLOW, '(got %s)' % hw.level)


# ─────────────────────────────────────────────────────────────
section('7. engine dedup')

state = {}
n_dedup = Notice(channel='review', level=INFO, title='t', dedup_key='k1')
# Can't actually send; verify dedup bookkeeping by simulating
state[n_dedup.dedup_key] = __import__('time').time()
r = engine.send(n_dedup, '', dedup_state=state)
check('no-webhook returns failed before dedup', r == 'failed')

# Direct dedup check
state2 = {'k2': __import__('time').time()}
n2d = Notice(channel='review', level=INFO, title='t', dedup_key='k2')
r2 = engine.send(n2d, 'http://127.0.0.1:1/none', dedup_state=state2)
check('within-window deduped', r2 == 'deduped', '(got %s)' % r2)

# Expired window
state3 = {'k3': __import__('time').time() - engine.DEDUP_WINDOW - 10}
n3d = Notice(channel='review', level=INFO, title='t', dedup_key='k3')
r3 = engine.send(n3d, '', dedup_state=state3)
check('expired window not deduped', r3 == 'failed', '(got %s)' % r3)

# No dedup_key → never deduped
n4d = Notice(channel='review', level=INFO, title='t')
r4 = engine.send(n4d, '', dedup_state={'': __import__('time').time()})
check('no dedup_key skips dedup', r4 == 'failed', '(got %s)' % r4)


# ─────────────────────────────────────────────────────────────
section('8. engine send failure handling')

ns = Notice(channel='review', level=INFO, title='t')
check('no webhook → failed', engine.send(ns, '') == 'failed')
check('unreachable host → failed',
      engine.send(ns, 'http://127.0.0.1:1/x', force=True) == 'failed')


# ─────────────────────────────────────────────────────────────
section('9. Sentinel writing')

sentinel = '/var/lib/report-server/daily/last-feishu-card.json'
had = os.path.exists(sentinel)
before = open(sentinel).read() if had else None
engine.send(Notice(channel='review', level=YELLOW, title='sentinel-test',
                   dedup_key=''), '', )
after = json.load(open(sentinel))
check('sentinel written', after.get('title') == 'sentinel-test', str(after))
check('sentinel has channel', after.get('channel') == 'review')
check('sentinel records failure', after.get('card_sent') is False)
if had and before is not None:
    with open(sentinel, 'w') as f:
        f.write(before)


# ─────────────────────────────────────────────────────────────
print('\n' + '=' * 60)
print('PASSED: %d   FAILED: %d' % (PASS, FAIL))
print('=' * 60)
sys.exit(1 if FAIL else 0)