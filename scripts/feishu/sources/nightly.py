"""platform-payload.json → Notice for nightly build reports.

Reads the output of build-feishu-payload.py and decides what the nightly
card should say. The verdict logic stays in build-feishu-payload.py; this
module only translates its structured output into a Notice.
"""

import json
from pathlib import Path
from typing import List

from ..notice import Notice, InfoLine, RED, YELLOW, INFO

PLATFORM_LABELS = {'linux': 'Linux', 'windows': 'Windows'}

VERDICT_MAP = {
    'red': RED,
    'yellow': YELLOW,
    'green': INFO,
}


def _parse_body_lines(payload: dict) -> List[InfoLine]:
    """Turn the platform_lines from build-feishu-payload.py into InfoLines.

    Body lines are structured into labelled InfoLines where possible:
      "Linux  ✅ 9/45" → label="Linux", content="✅ 9/45"
      "⚠️ 缺少平台报告: windows" → plain (no label)
    """
    import re
    lines = []
    for raw in payload.get('body_lines') or []:
        m = re.match(r'\*\*(.+?)\*\*(.*)', raw)
        if m:
            lines.append(InfoLine(m.group(1), m.group(2).strip()))
        else:
            lines.append(InfoLine('', raw))
    return lines


def _build_title(build_num: str, date_tag: str, run_tag: str,
                 verdict: dict) -> str:
    """Nightly card title: icon + description."""
    vlevel = verdict.get('level', '')
    icons = {'red': '🔴', 'yellow': '🟡', 'green': '✅'}
    icon = icons.get(vlevel, '⚠️')
    run_label = '午后' if run_tag == 'run2' else '凌晨'
    return '%s chaos-il2cpp Nightly #%s — %s (%s)' % (
        icon, build_num, date_tag, run_label)


def to_notice(payload_path: str, *,
              build_num: str = '', date_tag: str = '', run_tag: str = 'run1',
              build_url: str = '', report_url: str = '') -> Notice:
    """Build a Notice from a build-feishu-payload.py output file.

    Args:
        payload_path: Path to the JSON file produced by build-feishu-payload.py.
        build_num: Build number (for title).
        date_tag: Date string (for title).
        run_tag: 'run1' or 'run2' (for title).
        build_url: Jenkins build URL (for button).
        report_url: Web report URL (for button).

    Returns a Notice with level, title, body set appropriately.
    """
    try:
        with open(payload_path) as f:
            payload = json.load(f)
    except Exception:
        return Notice(
            channel='nightly',
            level=RED,
            title='Nightly #%s — %s (无法获取报告)' % (build_num, date_tag),
            body=[InfoLine('', '⚠️ platform-payload.json 缺失或无法解析')],
        )

    verdict = payload.get('verdict') or {}
    level = VERDICT_MAP.get(verdict.get('level', ''), INFO)
    title = _build_title(build_num, date_tag, run_tag, verdict)

    body = _parse_body_lines(payload)

    # Missing platforms
    missing = payload.get('missing_platforms') or []
    if missing:
        body.append(InfoLine('缺少平台', '、'.join(missing)
                             + ' — 该平台本轮未产出数据'))

    actions = []
    if report_url:
        actions.append(('📊 查看报告', report_url))
    if build_url:
        actions.append(('🔧 Jenkins Build', build_url))

    return Notice(
        channel='nightly',
        level=level,
        title=title,
        body=body,
        actions=actions,
        dedup_key='nightly:%s:%s' % (date_tag, run_tag),
        tags={
            'verdict': verdict.get('level', ''),
            'verdict_reason': verdict.get('reason', ''),
        },
    )