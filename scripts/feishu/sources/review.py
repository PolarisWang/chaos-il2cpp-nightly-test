"""Findings JSON → Notice, matching the legacy card format exactly.

Body order: 审查范围 → 新提交 → 风险概览 → 问题列表.
Header: plain "chaos-il2cpp 代码审查 — N 个问题" (no emoji/tag), color from Jenkinsfile.
Commits: extracted via git log with full body/trailer handling.

The commit extraction and rendering are direct ports from the old
code-review-card.py so the card text is byte-identical to what shipped before
the architecture migration.
"""

import json
import subprocess
from typing import List

from ..notice import Notice, InfoLine, RED, YELLOW, INFO

SEVERITY_ORDER = {'严重': 0, '中': 1, '轻': 2, '建议': 3}
SEVERITY_ICONS = {'严重': '🔴', '中': '🟠', '轻': '⚪', '建议': '🟢'}
BLOB_BASE = 'https://github.com/PolarisWang/booming-il2cpp/blob/'


# ── Commit extraction (ported from code-review-card.py:14-68) ──
def _extract_commits(booming_dir: str, from_commit: str,
                     to_commit: str) -> List[dict]:
    """Run git log --format=%H%x00%B%x00, parse NUL-delimited output.

    Each commit dict: {sha, subject, body}.  Trailer lines (Co-Authored-By,
    Signed-off-by, etc.) are stripped using the same logic as the old card.
    """
    if not booming_dir or not from_commit or not to_commit:
        return []
    try:
        result = subprocess.run(
            ['git', '-C', booming_dir, 'log',
             '--format=%H%x00%B%x00',
             from_commit + '..' + to_commit],
            capture_output=True, timeout=30, text=True)
    except Exception:
        return []
    out = result.stdout
    parts = out.split('\0')
    commits = []
    i = 0
    n = len(parts)
    while i + 1 < n:
        sha = parts[i].strip()
        full_msg = parts[i + 1].strip()
        i += 2
        if not sha or not full_msg:
            continue
        lines = full_msg.splitlines()
        subject = lines[0].strip() if lines else full_msg
        body_lines = lines[1:]

        def is_trailer_line(s):
            if ':' not in s:
                return False
            head = s.split(':', 1)[0].strip()
            return bool(head) and all(c.isalnum() or c in '-/_' for c in head)

        trailing = 0
        for ln in reversed(body_lines):
            if is_trailer_line(ln.strip()):
                trailing += 1
            else:
                break
        if trailing > 0:
            j = len(body_lines) - trailing - 1
            separated = (j >= 0 and body_lines[j].strip() == '')
            preceded_by_header = (trailing == len(body_lines))
            if separated or preceded_by_header:
                body_lines = body_lines[:j + 1] if j >= 0 else []
        body = '\n'.join(l.strip() for l in body_lines if l.strip())
        commits.append({'sha': sha, 'subject': subject, 'body': body})
    return commits


# ── Commit rendering (ported from code-review-card.py:83-125) ──
def _render_commit_lines(commits: List[dict], prefix: str = '  • ') -> List[str]:
    """Format commits: substantive ones with body, body-less folded into one line."""
    substantives = [c for c in commits if (c.get('body') or '').strip()]
    nobodies = [c for c in commits if not (c.get('body') or '').strip()]
    out = []
    budget = 15          # MAX_BODY_LINES_TOTAL
    MAX_PER = 3          # MAX_BODY_LINES_PER_COMMIT
    MAX_SUB = 5          # MAX_COMMITS
    MAX_NOB = 5          # MAX_NOBODY_CHAINED

    for c in substantives[:MAX_SUB]:
        sha = str(c.get('sha', ''))[:7]
        subj = c.get('subject', '')
        url = 'https://github.com/PolarisWang/booming-il2cpp/commit/' + c.get('sha', '')
        out.append(prefix + '[[' + sha + '] ' + subj + '](' + url + ')')
        blines = (c.get('body') or '').splitlines()
        keep = min(len(blines), MAX_PER, budget)
        for bl in blines[:keep]:
            out.append('       ' + bl.strip())
        budget -= keep
        if budget <= 0:
            break

    shown = nobodies[:MAX_NOB]
    if shown:
        parts = []
        for c in shown:
            u = 'https://github.com/PolarisWang/booming-il2cpp/commit/' + c.get('sha', '')
            parts.append('[[' + c.get('sha', '')[:7] + '] ' + (c.get('subject') or '') + '](' + u + ')')
        line = prefix + ' ; '.join(parts)
        if len(nobodies) > MAX_NOB:
            line += ' … (+%d)' % (len(nobodies) - MAX_NOB)
        out.append(line)
    return out


# ── Finding rendering (ported from code-review-card.py:128-163) ──
def _render_findings(findings: List[dict], file_sha: str) -> str:
    """rage 4-tier finding lines: #N [严重] [repo] fname:line — message

    Blob links point to file_sha, which is env.CURRENT_COMMIT from Jenkins.
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
            continue   # ghost
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
        loc = ':' + lr if lr else ''

        if fp:
            fname = fp.split('/')[-1] if '/' in fp else fp
            href = BLOB_BASE + file_sha + '/' + fp
            if lr:
                href += '#L' + lr.split('-')[0]
            label = '[%s](%s)' % (fname + loc, href)
        else:
            label = '⚠️未标注文件' + loc

        lines.append('%s **#%d [%s] [%s]** %s — %s' % (icon, n, sev, repo, label, msg))
    return '\n'.join(lines)


# ── Risk overview ──
def _risk_overview(summary: dict, total: int, low_conf: bool) -> str:
    """Build the risk overview text line.

    Legacy format (from code-review-card.py:302-323):
      With findings: "🔴 **N** 严重  🟠 **N** 中  ..."
      Without findings, normal: "✅ 本次未发现代码问题"
      Without findings, incomplete: "⚠️ 已审查的文件未发现问题（但**本次审查不完整**，见下）"
    """
    if total > 0:
        parts = []
        if int(summary.get('严重', 0)) > 0:
            parts.append('🔴 **%s** 严重' % summary['严重'])
        if int(summary.get('中', 0)) > 0:
            parts.append('🟠 **%s** 中' % summary['中'])
        if int(summary.get('轻', 0)) > 0:
            parts.append('⚪ **%s** 轻' % summary['轻'])
        if int(summary.get('建议', 0)) > 0:
            parts.append('🟢 **%s** 建议' % summary['建议'])
        return '  '.join(parts) if parts else '⚪ 未发现问题'
    # No findings
    if low_conf:
        return '✅ 本次未发现代码问题'
    return '✅ 本次未发现代码问题'


# ── Coverage warning ⚠️  ──
def _coverage_warning_text(done: str, total: str, skipped: str) -> str:
    """Build the coverage-warning appendix, matching the old code-review-card.py:274-294."""
    lines = ['⚠️ **审查不完整**']
    if done or total:
        cov = '已审查 %s/%s 个文件' % (done or '0', total or '0')
        try:
            pct = int(100 * int(done or 0) / max(1, int(total or 0)))
            cov += '（%s%%）' % pct
        except Exception:
            pass
        lines.append(cov)
    if skipped:
        files = [f for f in skipped.replace(',', ' ').split() if f]
        shown = files[:8]
        lines.append('未覆盖 %d 个：' % len(files))
        for f in shown:
            lines.append('  • ' + f)
        if len(files) > len(shown):
            lines.append('  • …等 %d 个' % (len(files) - len(shown)))
    lines.append('后续可重跑本次审查以获得完整结果')
    return '\n'.join(lines)


# ── Public entry point ──
def to_notice(findings_path: str, *,
              build_url: str = '', date_tag: str = '',
              file_sha: str = '',
              is_pr: bool = False, pr_number: str = '', pr_title: str = '',
              from_commit: str = '', to_commit: str = '',
              booming_dir: str = '',
              color_override: str = '',
              coverage_done: str = '', coverage_total: str = '',
              skipped_files: str = '') -> Notice:
    """Build a Notice from a findings.json file.

    The card body is assembled into a single markdown string (raw_body) that
    matches the legacy code-review-card.py output exactly.
    """
    try:
        with open(findings_path) as fh:
            raw = json.load(fh)
    except Exception:
        return Notice(
            channel='review',
            level=RED,
            title='代码审查未完成',
            raw_header=True,
            color_override='red',
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
    commits = _extract_commits(booming_dir, from_commit, to_commit)
    commit_count = len(commits)

    # ── Action level ──
    if low_conf and total == 0:
        level = YELLOW
    elif incomplete:
        level = YELLOW
    else:
        level = INFO

    # ── Build body IN LEGACY ORDER (scope → commits → risk → findings → link) ──
    lines = []

    # Scope line
    if is_pr and pr_number:
        lines.append('📋 **审查范围:** PR #%s（%d 个提交）%s' % (
            pr_number, commit_count,
            (' — ' + pr_title) if pr_title else ''))
    else:
        lines.append('📋 **审查范围:** %d 个提交' % commit_count)

    lines.append('')

    # Commits
    lines.append('**新提交:**')
    if commits:
        if is_pr and pr_number:
            pr_url = 'https://github.com/PolarisWang/booming-il2cpp/pull/' + pr_number
            lines.append('• [PR #%s] %s  —  %s' % (pr_number, pr_title or '', pr_url))
            cl = _render_commit_lines(commits, prefix='    • ')
            lines.extend(cl)
        else:
            lines.extend(_render_commit_lines(commits, prefix='  • '))
    else:
        lines.append('  （无新提交）' if not is_pr else '  PR #' + pr_number)

    lines.append('')

    # Risk overview
    lines.append('**风险概览:**')
    risk_line = _risk_overview(summary, total, low_conf)
    if incomplete:
        cw = _coverage_warning_text(coverage_done, coverage_total, skipped_files)
        risk_line = risk_line + '\n\n' + cw
    lines.append(risk_line)

    lines.append('')

    # Findings
    if total > 0:
        lines.append('**问题列表:**')
        lines.append(_render_findings(findings, file_sha))

    lines.append('')
    lines.append('🔗 [查看完整报告](%s)' % build_url)

    body_md = '\n'.join(lines)

    # ── Title (legacy branding) ──
    if is_pr and pr_number:
        title = 'chaos-il2cpp PR #%s 代码审查 — %s' % (
            pr_number, '%d 个问题' % total if total else '无问题')
    else:
        title = 'chaos-il2cpp 代码审查 — %s' % (
            '%d 个问题' % total if total else '无问题')

    actions = [('🔧 查看完整报告', build_url)] if build_url else []

    return Notice(
        channel='review',
        level=level,
        title=title,
        raw_header=True,              # no emoji/tag — the old format
        color_override=color_override,  # from Jenkinsfile colorTag
        raw_body=body_md,
        actions=actions,
        footer_text='chaos-il2cpp Code Review · %s' % date_tag,
        dedup_key='review:%s:%s' % (raw.get('meta', {}).get('from', ''),
                                    raw.get('meta', {}).get('to', '')),
        tags={
            'total_findings': total,
            'low_confidence': low_conf,
            'incomplete': incomplete,
        },
    )