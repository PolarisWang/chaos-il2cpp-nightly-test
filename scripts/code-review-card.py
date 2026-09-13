import json, os, urllib.request, subprocess, time


# Extract commits from git log (not findings JSON — Claude may omit them)
booming_dir = os.environ.get('CARD_BOOMING_DIR', '/home/debian/agent/booming-il2cpp')
from_commit = os.environ.get('REVIEW_FROM', '')
to_commit = os.environ.get('REVIEW_TO', '')
is_pr = os.environ.get('CARD_IS_PR', 'false') == 'true'
pr_number = os.environ.get('REVIEW_PR_NUMBER', '')
pr_title = os.environ.get('REVIEW_PR_TITLE', '')
# Blob links should point at the PR head's code, not main's CURRENT_COMMIT.
file_sha = os.environ.get('CARD_FILE_SHA', '')
commits = []
try:
    # Capture the FULL commit message (subject + body), not just %s title.
    # Emit each commit as <sha40> NUL <full-message> NUL (NUL = ASCII 0x00). Splitting
    # on NUL is safe because git forbids NUL bytes inside messages, and %B strips the
    # trailing newline, so parts come out [sha1, msg1, sha2, msg2, ...]. NOTE: this block
    # lives inside a Groovy sh triple-quote string, so NO literal backslash may appear
    # here (Groovy would turn it into an escape and break the build). We use chr(0) /
    # chr(10) / splitlines() instead of backslash escapes on purpose — stable + safe.
    result = subprocess.run(
        ['git', '-C', booming_dir, 'log',
         '--format=%H%x00%B%x00',
         from_commit + '..' + to_commit],
        capture_output=True, timeout=30
    )
    out = result.stdout.decode('utf-8', errors='replace')
    parts = out.split(chr(0))
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
        # Strip a git TRALER block (Co-Authored-By / Signed-off-by / Reviewed-by, ...).
        # Real git trailers are a trailing run of `Key: value` lines that git parses ONLY
        # because they are separated from the message prose by a blank line. We mirror git:
        #   * walk body_lines from the END;
        #   * collect the contiguous trailing run of `Key: value` lines;
        #   * if that run is empty, or it is NOT preceded by a blank separator, keep everything.
        # This avoids dropping ordinary prose that merely ends in `foo: bar` with no blank above.
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
            separated = (j >= 0 and body_lines[j].strip() == '')   # blank right before the run
            preceded_by_header = (trailing == len(body_lines))      # subject-only + trailers
            if separated or preceded_by_header:
                body_lines = body_lines[:j + 1] if j >= 0 else []
        body = chr(10).join(l.strip() for l in body_lines if l.strip())
        commits.append({'sha': sha, 'subject': subject, 'body': body})
except Exception:
    pass

# Also read findings JSON for finding details
try:
    with open(os.environ.get('CARD_FINDINGS', '')) as f:
        d = json.load(f)
except Exception:
    d = {}
flist = d.get('findings', [])

# ── Render commit list (shared between PR mode and main-branch mode) ──
# Priorities substantive commits (those with a body worth explaining); pure
# changelog/chore commits that carry no body are NOT given their own slot (they'd
# crowd out real changes) but are folded into a compact single trailing line. This
# keeps the card readable while making every commit discoverable via its link.
MAX_COMMITS = 5            # max individually-rendered substantive commits
MAX_BODY_LINES_PER_COMMIT = 3
MAX_BODY_LINES_TOTAL = 15
MAX_NOBODY_CHAINED = 5     # up to 5 body-less commits shown on the fold line
def render_commit_lines(commits, prefix='  • '):
    substantives = [c for c in commits if (c.get('body') or '').strip()]
    nobodies     = [c for c in commits if not (c.get('body') or '').strip()]
    out = []
    budget = MAX_BODY_LINES_TOTAL
    # Render substantive commits first, each with up to 3 body lines within the budget.
    for c in substantives[:MAX_COMMITS]:
        sha = c.get('sha', '')[:7]
        subj = c.get('subject', '')
        url = 'https://github.com/PolarisWang/booming-il2cpp/commit/' + c.get('sha', '')
        out.append(prefix + u'[[' + sha + u'] ' + subj + u'](' + url + u')')
        blines = (c.get('body') or '').splitlines()
        keep = min(len(blines), MAX_BODY_LINES_PER_COMMIT, budget)
        for bl in blines[:keep]:
            out.append('       ' + bl.strip())
        budget -= keep
        if budget <= 0:
            break
    # Fold body-less commits into one compact line (they have no prose to show).
    shown_nobodies = nobodies[:MAX_NOBODY_CHAINED]
    if shown_nobodies:
        parts = []
        for c in shown_nobodies:
            u = 'https://github.com/PolarisWang/booming-il2cpp/commit/' + c.get('sha', '')
            parts.append(u'[[' + c.get('sha', '')[:7] + u'] ' + (c.get('subject') or '') + u'](' + u + u')')
        line = u'  • ' + u' ; '.join(parts)
        if len(nobodies) > MAX_NOBODY_CHAINED:
            line = u'  • ' + ' ; '.join(parts) + u' … (+%d)' % (len(nobodies) - MAX_NOBODY_CHAINED)
        out.append(line)
    return out

# PR mode: show the PR header + individual commits with full messages.
if is_pr and pr_number:
    pr_url = 'https://github.com/PolarisWang/booming-il2cpp/pull/' + pr_number
    pr_header = u'• [PR #' + pr_number + u'] ' + (pr_title or '') + u'  —  ' + pr_url
    cl = [pr_header] + render_commit_lines(commits, prefix='    • ')
else:
    cl = render_commit_lines(commits, prefix='  • ')
ct = chr(10).join(cl) if cl else ('  （无新提交）' if not is_pr else '  PR #' + pr_number)

# Build findings list — rage-standard 4-tier lines: #N [严重] [Repo] file:line_range
severity_icons = {'严重': '🔴', '中': '🟠', '轻': '⚪', '建议': '🟢'}
sel_order = {'严重': 0, '中': 1, '轻': 2, '建议': 3}
# severity-sort (严重 first), stable
flist_sorted = sorted(flist, key=lambda f: sel_order.get(f.get('severity', '建议'), 9))
# Defense in depth: drop ghost findings whose message carries no real content
# (blank / whitespace-only). The generator now drops these at the source, but a
# poisoned cache entry or a legacy findings.json could still carry one — never
# render a "file:line — " line with a dangling dash and nothing after it.
meaningful = []
for f in flist_sorted:
    _m = f.get('message')
    if isinstance(_m, str) and _m.strip():
        meaningful.append(f)
flist_sorted = meaningful
flines = []
for ndx, fx in enumerate(flist_sorted, start=1):
    sev = fx.get('severity') or '建议'
    icon = severity_icons.get(sev, '⚪')
    repo = fx.get('repo', 'il2cpp')
    fp = fx.get('file', '')
    ln = fx.get('line', 0)
    lr = fx.get('line_range')
    # Model may emit line_range as a bare number; normalize to a string so the
    # .split('-') below never raises AttributeError and takes the whole card down.
    if lr is None or lr == '':
        lr = str(ln) if ln else ''
    else:
        lr = str(lr).strip()
    loc = ':' + lr if lr else ''
    msg = fx.get('message', '')
    # A finding with no `file` renders as "fname:43" = ":43" and its blob link
    # points at the repo root — the reader cannot tell which file to open. The
    # generator now salvages the name from the message and the prompt requires it,
    # but a finding can still arrive bare. Make the gap VISIBLE rather than
    # silently emitting a meaningless ":43", so nobody mistakes it for a real
    # location. Do not fabricate a name — we do not know it.
    if not fp.strip():
        fname = '⚠️未标注文件'
        furl = ''
    else:
        fname = fp.split('/')[-1] if '/' in fp else fp
        furl = 'https://github.com/PolarisWang/booming-il2cpp/blob/' + file_sha + '/' + fp + ('#L' + str(lr.split('-')[0]) if lr else '')
    # rage line: #N [严重] [il2cpp] fname:line_range — filename is the Feishu link
    if furl:
        flines.append('{0} **#{1} [{2}] [{3}]** [{4}]({5}) — {6}'.format(
            icon, ndx, sev, repo, fname + loc, furl, msg))
    else:
        flines.append('{0} **#{1} [{2}] [{3}]** {4} — {5}'.format(
            icon, ndx, sev, repo, fname + loc, msg))
ft = chr(10).join(flines) if flines else '  ✅ 未发现问题'

bu = os.environ.get('JENKINS_EXT_URL', '') + '/job/' + os.environ.get('JOB_NAME','') + '/' + os.environ.get('BUILD_NUMBER','') + '/'

# ── Abnormal-case handling via the unified incident-card template ──
# Load it once; fall back to inline rendering if unavailable so a broken
# incident-card.py can never take the whole card down.
_INCIDENT = None
try:
    import importlib.util as _ilu
    _ipath = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'incident-card.py')
    _spec = _ilu.spec_from_file_location('incident_card', _ipath)
    _mod = _ilu.module_from_spec(_spec)
    _spec.loader.exec_module(_mod)
    _INCIDENT = _mod
except Exception as _e:
    print('WARNING: could not load incident-card.py: ' + str(_e))


def _render_incident(level, title, impact='', cause='', action='',
                     extra_pairs=None, minimal=False):
    """Render an abnormal card via the shared template, then send it.

    Returns True if a card was sent (caller should then SKIP the normal card),
    False if the template was unavailable (caller falls back to the normal path).
    """
    if _INCIDENT is None:
        return False
    card = _INCIDENT.build_card(
        level=level, title=title, impact=impact, cause=cause, action=action,
        build_link=bu,
        report_link=bu,
        extra_pairs=extra_pairs or [],
        minimal=minimal,
        date_tag=os.environ.get('DATE_TAG', ''),
    )
    webhook = os.environ.get('FEISHU_WEBHOOK_URL', '').strip()
    if not webhook:
        print('WARNING: FEISHU_WEBHOOK_URL not set; printing card instead')
        print(json.dumps(card, ensure_ascii=False))
        return True   # handler owns this case; do not fall through
    _INCIDENT.send_card(card, webhook)
    return True


# Decision: is this an abnormal case that must use the incident template?
# Order matters — script errors and coverage gaps outrank a plain clean pass.
# Deferred until the commit/finding counts are known (below), so the handler
# can quote real numbers instead of placeholders.
_script_error = os.environ.get('REVIEW_SCRIPT_ERROR', '0') == '1'
_cov_done  = os.environ.get('REVIEW_COVERAGE_DONE', '')
_cov_total = os.environ.get('REVIEW_COVERAGE_TOTAL', '')
_skipped   = os.environ.get('REVIEW_SKIPPED_FILES', '')
_error_detail = os.environ.get('REVIEW_ERROR_DETAIL', '')
_docs_only = os.environ.get('REVIEW_DOCS_ONLY', '0') == '1'
_incomplete = os.environ.get('REVIEW_INCOMPLETE', '0') == '1'
_low_conf = os.environ.get('REVIEW_LOW_CONF', '0') == '1'

# 🔴 Script-level error: the review produced NOTHING. Never render this as
# "0 findings" — that is precisely the false-clean failure mode this guards.
if _script_error:
    _impact = ''
    if _cov_done or _cov_total:
        _impact = '本次 ' + str(_cov_done or 0) + '/' + str(_cov_total or 0) + ' 个文件被审查\n'
    else:
        _impact = '本次未产出审查结果\n'
    _impact += '未产出审查结果，本次提交未被审查'
    _cause = ''
    if _error_detail:
        _cause = (_INCIDENT.error_code_to_cause(_error_detail)
                  if _INCIDENT else _error_detail)
    _action = ('检查 review-with-claude.sh 的 chunk 合并逻辑\n'
               '（历史同类问题：git 参数不兼容 / ARG_MAX）'
               if _cause else '请查看构建日志定位失败环节')
    if _render_incident(
        level='RED',
        title='代码审查未完成',
        impact=_impact,
        cause=_cause,
        action=_action,
        extra_pairs=[('技术细节', _error_detail)] if _error_detail else None,
    ):
        raise SystemExit(0)

# ⚪ docs_only: normal behaviour, not an incident. Minimal one-line card.
if _docs_only and not _incomplete and not _low_conf:
    if _render_incident(
        level='INFO',
        title='代码审查 · ' + str(len(commits)) + ' 个提交（纯文档）',
        minimal=True,
    ):
        raise SystemExit(0)

# 🟡 Incomplete coverage: some files were never reviewed. Do NOT short-circuit
# into an incident-only card — that would hide the findings that DID come back,
# which is the whole point of the review. Instead remember the coverage gap and
# render it as a warning INSIDE the normal findings card (see risk_line below).
_coverage_warning = ''
if _incomplete:
    _cov = ''
    if _cov_done or _cov_total:
        _cov = '已审查 ' + str(_cov_done) + '/' + str(_cov_total) + ' 个文件'
        try:
            _pct = int(100 * int(_cov_done) / max(1, int(_cov_total)))
            _cov += '（' + str(_pct) + '%）'
        except Exception:
            pass
    _skip_md = ''
    if _skipped:
        _files = [f for f in _skipped.replace(',', ' ').split() if f]
        _shown = _files[:8]
        _skip_md = ('\n未覆盖 ' + str(len(_files)) + ' 个：\n'
                    + '\n'.join('  • ' + f for f in _shown))
        if len(_files) > len(_shown):
            _skip_md += '\n  • …等 ' + str(len(_files) - len(_shown)) + ' 个'
    _coverage_warning = ('⚠️ **审查不完整** — ' + (_cov or '部分文件未被审查')
                         + _skip_md
                         + '\n后续可重跑本次审查以获得完整结果')

# 🟡 Low confidence: the review came back with no findings on substantive code —
# suspicious, because the model has produced false-clean results before.
#
# CRITICAL: only intercept when there are genuinely ZERO findings. review-with-
# claude.sh also sets low_confidence=true when chunks were skipped, which is
# normal on a large diff and happens WHILE findings exist. Short-circuiting in
# that case swallowed the entire findings list and rendered a generic warning
# instead — build 3941 returned 10 findings and none of them reached the card.
# With findings present, fall through and render them.
if _low_conf and int(os.environ.get('CARD_TOTAL', '0') or 0) == 0:
    if _render_incident(
        level='YELLOW',
        title='本次审查 0 发现 — 置信度低',
        impact='审查了 ' + str(len(commits)) + ' 个提交，未得到任何 finding',
        cause=('该变更量级通常应有 finding，模型可能异常。\n'
               '历史上出现过"假 clean"（提交 82089d6）。'),
        action='查看变更内容人工判断，或稍后重跑本次审查',
    ):
        raise SystemExit(0)

# Build risk overview line with emoji icons (rage 4-tier: 严重 中 轻 建议)
risk_line = ''
total = int(os.environ.get('CARD_TOTAL', '0') or 0)
if total > 0:
    parts = []
    if int(os.environ.get('CARD_SEV','0')) > 0:
        parts.append('🔴 **' + os.environ.get('CARD_SEV','0') + '** 严重')
    if int(os.environ.get('CARD_MED','0')) > 0:
        parts.append('🟠 **' + os.environ.get('CARD_MED','0') + '** 中')
    if int(os.environ.get('CARD_LIGHT','0')) > 0:
        parts.append('⚪ **' + os.environ.get('CARD_LIGHT','0') + '** 轻')
    if int(os.environ.get('CARD_ADV','0')) > 0:
        parts.append('🟢 **' + os.environ.get('CARD_ADV','0') + '** 建议')
    risk_line = '  '.join(parts) if parts else '⚪ 未发现问题'
else:
    # No findings. docs_only / low-confidence already took the incident-card
    # path above, so reaching here means a genuine clean pass — unless the
    # coverage check flagged missing files, which downgrades "clean" to
    # "clean over the files we actually saw".
    if _coverage_warning:
        risk_line = '⚠️ 已审查的文件未发现问题（但**本次审查不完整**，见下）'
    else:
        risk_line = '✅ 本次未发现代码问题'

# Coverage gap (if any) goes UNDER the risk line so the findings above stay
# the first thing the reader sees, but the incompleteness is impossible to miss.
if _coverage_warning:
    risk_line = risk_line + '\n\n' + _coverage_warning

commit_count = len(commits)
if is_pr and pr_number:
    scope_line = '📋 **审查范围:** PR #' + pr_number + '（' + str(commit_count) + ' 个提交）' + (' — ' + pr_title if pr_title else '')
else:
    scope_line = '📋 **审查范围:** ' + str(commit_count) + ' 个提交'
lines = [
    scope_line,
    '',
    '**新提交:**',
    ct,
    '',
    '**风险概览:**',
    risk_line,
    '',
]
if flines:
    lines.append('**问题列表:**')
    lines.append(ft)
lines.append('')
lines.append('🔗 [查看完整报告](' + bu + ')')

msg = chr(10).join(lines)

# ── Written by build AND used as a delivery-sentinel for monitoring.
#    Writes to a stable host path so monitor-il2cpp-review.sh can check whether
#    a completed review actually delivered a card, independent of the (cleanWs'd)
#    agent workspace. Path: ${WORKSPACE} may not survive, so use the report dir.
_card_outdir = os.environ.get('CARD_OUTDIR', '/var/lib/report-server/daily')
try:
    os.makedirs(_card_outdir, exist_ok=True)
    with open(os.path.join(_card_outdir, 'feishu_card_msg.txt'), 'w') as f:
        f.write(msg)
except Exception:
    pass

# Build and send Feishu card directly from Python
webhook = os.environ.get('FEISHU_WEBHOOK_URL', '').strip()
card_color = os.environ.get('CARD_COLOR', 'blue')

card = {
    'msg_type': 'interactive',
    'card': {
        'header': {
            'title': {'tag': 'plain_text', 'content': os.environ.get('CARD_TITLE', 'chaos-il2cpp 代码审查')},
            'template': card_color
        },
        'elements': [
            {'tag': 'div', 'text': {'tag': 'lark_md', 'content': msg}},
            {'tag': 'hr'},
            {
                'tag': 'action',
                'actions': [
                    {
                        'tag': 'button',
                        'text': {'tag': 'plain_text', 'content': '🔧 查看完整报告'},
                        'url': os.environ.get('JENKINS_EXT_URL', '') + '/job/' + os.environ.get('JOB_NAME','') + '/' + os.environ.get('BUILD_NUMBER','') + '/',
                        'type': 'default'
                    }
                ]
            },
            {'tag': 'hr'},
            {
                'tag': 'note',
                'elements': [
                    {'tag': 'plain_text', 'content': 'chaos-il2cpp Code Review · ' + os.environ.get('DATE_TAG', '')}
                ]
            }
        ]
    }
}

payload = json.dumps(card, ensure_ascii=False).encode('utf-8')
if webhook:
    req = urllib.request.Request(
        webhook, data=payload,
        headers={'Content-Type': 'application/json'},
        method='POST')
    try:
        resp = urllib.request.urlopen(req, timeout=30)
        print('Feishu card sent (HTTP ' + str(resp.status) + ')')
        _card_ok = True
    except Exception as e:
        print('WARNING: Feishu webhook failed: ' + str(e))
        _card_ok = False
else:
    print('WARNING: FEISHU_WEBHOOK_URL not set')
    _card_ok = False

# ── Card-delivery sentinel (layer 2): write a compact status file so
#    monitor-il2cpp-review.sh can cross-check review findings vs card delivery.
_card_outdir = os.environ.get('CARD_OUTDIR', '/var/lib/report-server/daily')
try:
    os.makedirs(_card_outdir, exist_ok=True)
    _sentinel = {
        'build_num': os.environ.get('BUILD_NUMBER', ''),
        'timestamp': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
        'card_sent': _card_ok,
        'findings_count': len(flist),
    }
    with open(os.path.join(_card_outdir, 'last-card-result.json'), 'w') as f:
        json.dump(_sentinel, f, ensure_ascii=False)
    print('card sentinel written to ' + _card_outdir + '/last-card-result.json')
except Exception as _e:
    print('WARNING: could not write card sentinel: ' + str(_e))

print('ok')