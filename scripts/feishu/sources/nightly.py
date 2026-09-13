"""platform-payload.json → Notice for nightly build reports.

Matches the legacy Jenkinsfile inline-Python card format exactly:

  title  : f'{icon} chaos-il2cpp Nightly #{n} — {date} ({run_label})'
  colour : verdict-driven (red / orange / green), falling back to the Jenkins
           status colour with a ⚠️ icon when no verdict is available
  body   : platform lines → optional metrics → missing-platform warning →
           failure detail
  footer : "chaos-il2cpp CI"

The verdict logic itself lives in build-feishu-payload.py; this module only
renders.
"""

import json
from typing import List

from ..notice import Notice, InfoLine, RED, YELLOW, INFO

VERDICT_MAP = {'red': RED, 'yellow': YELLOW, 'green': INFO}
VERDICT_COLOR = {'red': 'red', 'yellow': 'orange', 'green': 'green'}
VERDICT_ICON = {'red': '🔴', 'yellow': '🟡', 'green': '✅'}


def _metric_lines(data: dict) -> List[str]:
    """Only render metrics that carry a value.

    The engine's Route-3 CLI never populates fact/benchmark/hotupdate/memory,
    so rendering them unconditionally produced four lines of "0/0 (N/A)" that
    buried the one line that mattered. Kept from the legacy card.
    """
    out = []
    if (data.get('fact_total') or 0) > 0:
        out.append('正确率 %s/%s' % (data.get('fact_passed', 0),
                                     data.get('fact_total', 0)))
    if (data.get('bmk_methods') or 0) > 0:
        out.append('基准测试 %s 方法' % data.get('bmk_methods'))
    if (data.get('hot_total') or 0) > 0:
        out.append('热更新 %s/%s' % (data.get('hot_passed', 0),
                                     data.get('hot_total', 0)))
    if (data.get('mem_methods') or 0) > 0:
        out.append('内存Profile %s 方法' % data.get('mem_methods'))
    return out


def _build_body(data: dict) -> str:
    """Assemble the card body exactly as the legacy inline Python did."""
    parts = []

    body_lines = data.get('platform_lines') or []
    if body_lines:
        # body_lines[0] is the verdict line produced by build-feishu-payload.py.
        parts.extend(body_lines)
    else:
        # Payload builder unavailable — degrade to the raw Jenkins status
        # rather than render an empty card, and say so.
        parts.append('⚠️ **无法获取平台数据** — 请查看 Jenkins 构建')
        parts.append('status: ' + str(data.get('status', '')))

    metrics = _metric_lines(data)
    if metrics:
        parts.append('')
        parts.append('　' + ' · '.join(metrics))

    missing = data.get('missing_platforms') or []
    if missing:
        parts.append('')
        parts.append('⚠️ **缺少平台报告:** ' + '、'.join(missing)
                     + ' — 该平台本轮未产出数据，请检查该分支是否失败')

    # Fail detail. fail_lines is a "||"-joined blob (or the __MANY__ sentinel);
    # it was built that way to survive being embedded in a Jenkins @NonCPS
    # string, so it is unpacked here rather than upstream.
    fail_lines = data.get('fail_lines') or ''
    if fail_lines:
        parts.append('')
        if str(fail_lines).startswith('__MANY__'):
            n = str(fail_lines)[len('__MANY__'):]
            parts.append('**失败详情:** %s 个 DLL 有失败 chunk' % n)
        else:
            parts.append('**失败详情:**')
            parts.extend(str(fail_lines).split('||'))

    return '\n'.join(parts)


def to_notice(payload_path: str, *,
              build_num: str = '', date_tag: str = '', run_tag: str = 'run1',
              status: str = '', jenkins_color: str = 'green',
              build_url: str = '', report_url: str = '',
              data: dict = None) -> Notice:
    """Build a Notice from a build-feishu-payload.py output file.

    Args:
        payload_path: JSON produced by build-feishu-payload.py.
        build_num / date_tag / run_tag: title components.
        status: Jenkins result, used only in the no-payload degradation line.
        jenkins_color: the Groovy-computed colour, used when no verdict exists.
        build_url / report_url: button targets.
        data: extra fields for metrics/fail_lines (fact_*, bmk_methods, ...).

    Returns a Notice in the legacy nightly card format.
    """
    data = dict(data or {})
    data.setdefault('status', status)

    try:
        with open(payload_path) as f:
            payload = json.load(f)
    except Exception:
        payload = {}

    verdict = payload.get('verdict') or {}
    # The payload file is authoritative for platform_lines / missing / verdict.
    if payload.get('body_lines') is not None:
        data['platform_lines'] = payload.get('body_lines')
    if payload.get('missing_platforms') is not None:
        data['missing_platforms'] = payload.get('missing_platforms')

    vlevel = verdict.get('level', '')
    if vlevel in VERDICT_COLOR:
        color = VERDICT_COLOR[vlevel]
        icon = VERDICT_ICON[vlevel]
    else:
        # No verdict available (payload builder failed) — fall back to the
        # Jenkins status but mark it as unverified rather than asserting health.
        color = jenkins_color or 'green'
        icon = '⚠️'

    run_label = '午后' if run_tag == 'run2' else '凌晨'
    title = '%s chaos-il2cpp Nightly #%s — %s (%s)' % (
        icon, build_num, date_tag, run_label)

    actions = []
    if report_url:
        actions.append(('📊 查看报告', report_url))
    if build_url:
        actions.append(('🔧 Jenkins Build', build_url))

    return Notice(
        channel='nightly',
        level=VERDICT_MAP.get(vlevel, INFO),
        title=title,
        raw_header=True,          # icon is already in the title
        color_override=color,     # verdict-driven, exactly as before
        raw_body=_build_body(data),
        actions=actions,
        footer_text='chaos-il2cpp CI',
        dedup_key='nightly:%s:%s' % (date_tag, run_tag),
        tags={
            'verdict': vlevel,
            'verdict_reason': verdict.get('reason', ''),
        },
    )
