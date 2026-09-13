"""Findings JSON → Notice.

Reads the output of review-with-claude.sh and decides what the card should
say. All presentation decisions (colors, icons, tags) belong to the engine;
this module only decides WHAT to report and at which action level.
"""

import json
import os
from typing import List

from ..notice import Notice, InfoLine, RED, YELLOW, INFO

SEVERITY_ORDER = {'严重': 0, '中': 1, '轻': 2, '建议': 3}
SEVERITY_ICONS = {'严重': '🔴', '中': '🟠', '轻': '⚪', '建议': '🟢'}
BLOB_BASE = 'https://github.com/PolarisWang/booming-il2cpp/blob/'


def _render_findings(findings: List[dict], file_sha: str) -> str:
    """Render the finding list in the rage 4-tier line format.

    Format: #N [严重] [repo] file:line_range — message
    """
    lines = []
    ordered = sorted(findings,
                     key=lambda f: SEVERITY_ORDER.get(f.get('severity', '建议'), 9))
    n = 0
    for f in ordered:
        if not isinstance(f, dict):
            continue
        msg = str(f.get('message') or '').strip()
        if not msg:
            continue   # ghost finding — nothing to show
        n += 1
        sev = f.get('severity') or '建议'
        icon = SEVERITY_ICONS.get(sev, '⚪')
        repo = f.get('repo', 'il2cpp')
        fp = str(f.get('file') or '').strip()
        lr = f.get('line_range')
        if lr is None or lr == '':
            lr = str(f.get('line') or '')
        else:
            lr = str(lr).strip()

        if fp:
            loc = (':%s' % lr) if lr else ''
            fname = fp.split('/')[-1] if '/' in fp else fp
            href = BLOB_BASE + file_sha + '/' + fp
            if lr:
                href += '#L' + lr.split('-')[0]
            label = '[%s](%s)' % (fname + loc, href)
        else:
            # No file: say so rather than render a meaningless ":43".
            label = '⚠️未标注文件' + ((':%s' % lr) if lr else '')

        lines.append('%s **#%d [%s] [%s]** %s — %s' % (icon, n, sev, repo, label, msg))
    return '\n'.join(lines)


def _risk_overview(summary: dict, total: int, low_conf: bool) -> str:
    if total <= 0:
        return '⚠️ **本次审查置信度低**（模型可能异常，结果不可信）' if low_conf \
               else '✅ 本次未发现代码问题'
    parts = []
    for key in ('严重', '中', '轻', '建议'):
        c = summary.get(key, 0)
        if c:
            parts.append('%s **%s** %s' % (SEVERITY_ICONS[key], c, key))
    return '  '.join(parts) if parts else '✅ 本次未发现代码问题'


def to_notice(findings_path: str, *, build_url: str = '', date_tag: str = '',
              file_sha: str = '', is_pr: bool = False, pr_number: str = '',
              coverage_done: str = '', coverage_total: str = '',
              skipped_files: str = '') -> Notice:
    """Build a Notice from a findings.json file."""
    try:
        with open(findings_path) as fh:
            raw = json.load(fh)
    except Exception:
        # Unreadable findings is itself a signal. The review produced NOTHING —
        # we cannot say the code is clean, and we cannot say what went wrong.
        # RED ("需人工处理"), matching REVIEW_SCRIPT_ERROR in the Jenkinsfile:
        # a missing/unparseable findings file means the review did not run.
        return Notice(
            channel='review',
            level=RED,
            title='代码审查未完成',
            body=[InfoLine('影响范围',
                           '本次未产出审查结果（findings.json 缺失或无法解析），'
                           '本次提交未被审查')],
            footer_text='chaos-il2cpp Code Review · %s' % date_tag,
            tags={'total_findings': 0, 'script_error': True},
        )

    summary = raw.get('summary') or {}
    total = int(summary.get('total_findings') or 0)
    findings = raw.get('findings') or []
    low_conf = bool(raw.get('low_confidence'))
    incomplete = bool(raw.get('incomplete'))
    docs_only = bool(raw.get('docs_only'))
    cov = raw.get('coverage') or {}
    commits = raw.get('commits') or []

    # ── Action level ──
    # Order matters: a low-confidence zero beats a plain zero, because the
    # former is a warning and the latter is a clean pass.
    if low_conf and total == 0:
        level = YELLOW
    elif incomplete:
        level = YELLOW
    else:
        level = INFO

    # ── Body ──
    body: List[InfoLine] = []
    body.append(InfoLine('风险概览', _risk_overview(summary, total, low_conf)))

    if cov:
        td = cov.get('total_files') or coverage_total or 0
        cd = cov.get('covered_files') if cov.get('covered_files') is not None else coverage_done
        n_skip = cov.get('skipped_count') or 0
        cov_line = '已审查 %s/%s 个文件' % (cd, td)
        if n_skip:
            names = skipped_files or ', '.join(cov.get('skipped_files') or [])
            cov_line += '，跳过 %d 个' % n_skip
            if names:
                shown = [x for x in names.replace(',', ' ').split() if x][:8]
                cov_line += '：\n' + '\n'.join('  • ' + x for x in shown)
        body.append(InfoLine('覆盖情况', cov_line))

    if total > 0:
        body.append(InfoLine('问题列表', _render_findings(findings, file_sha)))

    if commits:
        cl = []
        for c in commits[:5]:
            sha = str(c.get('sha', ''))[:7]
            subj = c.get('subject') or c.get('message') or ''
            cl.append('  • [[%s] %s](%s%s)' % (
                sha, subj, 'https://github.com/PolarisWang/booming-il2cpp/commit/',
                c.get('sha', '')))
        body.append(InfoLine('提交', '\n'.join(cl)))

    # ── Title ──
    if is_pr and pr_number:
        title = 'PR #%s 代码审查 — %s' % (pr_number,
                                        '%d 个问题' % total if total else '无问题')
    else:
        title = '代码审查 — %s' % ('%d 个问题' % total if total else '无问题')

    actions = [('🔧 查看完整报告', build_url)] if build_url else []

    return Notice(
        channel='review',
        level=level,
        title=title,
        body=body,
        actions=actions,
        footer_text='chaos-il2cpp Code Review · %s' % date_tag,
        dedup_key='review:%s:%s' % (raw.get('meta', {}).get('from', ''),
                                    raw.get('meta', {}).get('to', '')),
        tags={
            'total_findings': total,
            'low_confidence': low_conf,
            'incomplete': incomplete,
            'docs_only': docs_only,
        },
    )