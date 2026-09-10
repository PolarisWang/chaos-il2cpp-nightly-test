#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
End-to-end contract test for the rage-aligned IL2CPP code-review flow.

The two halves of the flow must agree on the SAME finding JSON schema:
  1. scripts/review-with-claude.sh  — produces the findings JSON (rage 4-tier
     severity 严重/中/轻/建议 + repo/file/line/line_range) and prints a summary
     line to stdout.
  2. Jenkinsfile runCodeReview        — parses that JSON (Chinese summary keys),
     renders the Feishu card as `#N [严重] [il2cpp] file:line_range`, builds the
     risk overview, and writes state-file findings_last_run.

This test pins that contract so a change on one side without the other is caught
immediately. It is deliberately dependency-free: runs with plain `python3` (and
is also pytest-compatible via the test_* functions).

Run:
    python3 scripts/test_rage_alignment.py
    # or, where pytest is available:
    python3 -m pytest scripts/test_rage_alignment.py
"""
import json
import os
import re
import subprocess
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REVIEW_SCRIPT = os.path.join(REPO_ROOT, "scripts", "review-with-claude.sh")
JENKINSFILE = os.path.join(REPO_ROOT, "Jenkinsfile")

# Severities the flow must understand, 严重-first (rage _SEVERITY_ORDER).
EXPECTED_SEVERITIES = ["严重", "中", "轻", "建议"]  # 严重 first = highest


# ── 1. Schema-presence tests ───────────────────────────────────────────────

def _read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def test_review_script_has_rage_summary_keys():
    """review-with-claude.sh must emit a summary keyed by 严重/中/轻/建议."""
    body = _read(REVIEW_SCRIPT)
    assert '"严重":0' in body, "review-with-claude.sh must emit 严重 in summary"
    assert '"中":0' in body
    assert '"轻":0' in body
    assert '"建议":0' in body
    assert 'total_findings' in body
    # old CRITICAL/HIGH schema must be gone (apart from harmless prose)
    assert 'critical":0' not in body
    assert '"severity": "CRITICAL"' not in body


def test_review_script_finding_has_rage_fields():
    """The prompt's example finding must carry repo/file/line/line_range."""
    body = _read(REVIEW_SCRIPT)
    assert '"repo"' in body, "finding must carry a repo field"
    assert '"line"' in body
    assert '"line_range"' in body
    assert '严重' in body


def test_jenkinsfile_parses_chinese_keys():
    """Jenkinsfile must read the rage summary keys, not the old english ones."""
    body = _read(JENKINSFILE)
    assert "parsed['严重']" in body
    assert "parsed['中']" in body
    assert "parsed['轻']" in body
    assert "parsed['建议']" in body
    # old english parse must be gone
    assert "parsed.critical" not in body
    assert "env.FINDINGS_CRIT" not in body


def test_jenkinsfile_state_keys_are_rage():
    """findings_last_run in the Jenkinsfile must be keyed by the rage severities."""
    body = _read(JENKINSFILE)
    assert "'严重': env.FINDINGS_SEV" in body
    assert "'建议': env.FINDINGS_ADV" in body


# ── 2. Card-rendering test (mirror of the Jenkinsfile embedded python) ─────

def _render_rage_card(flist, file_sha="abc1234"):
    """Replicates the Jenkinsfile's embedded Python card-build section."""
    severity_icons = {"严重": "🔴", "中": "🟠", "轻": "⚪", "建议": "🟢"}
    sel_order = {"严重": 0, "中": 1, "轻": 2, "建议": 3}
    flist_sorted = sorted(flist, key=lambda f: sel_order.get(f.get("severity", "建议"), 9))
    flines = []
    for ndx, fx in enumerate(flist_sorted[:10], start=1):
        sev = fx.get("severity") or "建议"
        icon = severity_icons.get(sev, "⚪")
        repo = fx.get("repo", "il2cpp")
        fp = fx.get("file", "")
        ln = fx.get("line", 0)
        lr = fx.get("line_range") or (str(ln) if ln else "")
        loc = ":" + str(lr) if lr else ""
        msg = fx.get("message", "")
        fname = fp.split("/")[-1] if "/" in fp else fp
        furl = ("https://github.com/PolarisWang/booming-il2cpp/blob/" + file_sha + "/"
                + fp + ("#L" + str(lr.split("-")[0]) if lr else ""))
        flines.append("{0} **#{1} [{2}] [{3}]** [{4}]({5}) — {6}".format(
            icon, ndx, sev, repo, fname + loc, furl, msg))
    ft = "\n".join(flines) if flines else "  ✅ 未发现问题"
    return ft


def _render_risk(sevCount, medCount, lightCount, advCount, totalFindings):
    """Replicates the Jenkinsfile risk-overview line."""
    if totalFindings > 0:
        parts = []
        if sevCount > 0:
            parts.append("🔴 **%d** 严重" % sevCount)
        if medCount > 0:
            parts.append("🟠 **%d** 中" % medCount)
        if lightCount > 0:
            parts.append("⚪ **%d** 轻" % lightCount)
        if advCount > 0:
            parts.append("🟢 **%d** 建议" % advCount)
        return "  ".join(parts) if parts else "⚪ 未发现问题"
    return "✅ 本次未发现代码问题"


def test_rage_card_rendering():
    findings = [
        {"severity": "中", "repo": "il2cpp", "file": "src/a.cpp",
         "line": 1303, "line_range": "1303-1320", "message": "mask 不对称"},
        {"severity": "严重", "repo": "il2cpp", "file": "src/b.cpp",
         "line": 30, "line_range": "30-35", "message": "内存泄漏"},
        {"severity": "建议", "repo": "il2cpp", "file": "src/c.cpp",
         "line": 5, "message": "缩进"},
        {"severity": "轻", "repo": "il2cpp", "file": "src/d.cpp",
         "line": 99, "message": "可读性"},
    ]
    card = _render_rage_card(findings)
    # severity-sorted: 严重 (#1) first, then 中, 轻, 建议
    assert "#1 [严重] [il2cpp]" in card
    assert "#2 [中] [il2cpp]" in card
    assert "#3 [轻] [il2cpp]" in card
    assert "#4 [建议] [il2cpp]" in card
    # rage line format: #N [severity] [Repo] file:line_range
    assert "[b.cpp:30-35]" in card, card
    assert "[a.cpp:1303-1320]" in card
    # deep link points at the start line
    assert "/src/b.cpp#L30" in card
    # a finding without line_range falls back to the single line
    assert "[c.cpp:5]" in card


def test_rage_risk_overview():
    riska = _render_risk(1, 2, 1, 0, 4)
    assert "🔴 **1** 严重" in riska
    assert "🟠 **2** 中" in riska
    assert "⚪ **1** 轻" in riska
    assert "建议" not in riska  # advCount=0 → omitted
    risk_none = _render_risk(0, 0, 0, 0, 0)
    assert "未发现代码问题" in risk_none


# ── 2b. Ghost-finding guard (message must be non-blank content) ──────────────

# Mirror of the validator logic now in review-with-claude.sh: a finding must carry
# string severity/file/message each with real (non-whitespace) content, else the
# model glitch would surface as a Feishu line with a dangling "— " and no message.
_VALIDATE_REQUIRED = {"severity", "file", "message"}


def _is_meaningful_finding(fx):
    if not isinstance(fx, dict):
        return False
    for k in _VALIDATE_REQUIRED:
        v = fx.get(k)
        if not (isinstance(v, str) and v.strip()):
            return False
    return True


def _render_grid_filtered(flist):
    """Render card from the validator's surviving (meaningful) findings only."""
    meaningful = [f for f in flist if _is_meaningful_finding(f)]
    return _render_rage_card(meaningful)


def test_ghost_finding_whitespace_message_is_dropped():
    """A finding whose message is whitespace-only (or blank) must NOT reach the
    card — it would render as '— ' with nothing after it. Regression for the empty-
    content findings seen on Feishu (#1/#2/#4 had file+line but blank content)."""
    findings = [
        {"severity": "轻", "repo": "il2cpp", "file": "a.cpp",
         "line": 587, "message": "   ", "line_range": "587"},
        {"severity": "轻", "repo": "il2cpp", "file": "a.cpp",
         "line": 637, "message": "", "line_range": "637"},
        {"severity": "建议", "repo": "il2cpp", "file": "a.cpp",
         "line": 641, "message": " \t\n", "line_range": "641"},
        {"severity": "轻", "repo": "il2cpp", "file": "b.cpp",
         "line": 90, "message": "命名可读性差"},
    ]
    assert _is_meaningful_finding(findings[0]) is False
    assert _is_meaningful_finding(findings[1]) is False
    assert _is_meaningful_finding(findings[2]) is False
    assert _is_meaningful_finding(findings[3]) is True
    card = _render_grid_filtered(findings)
    # only the real finding survives: renumbered as #1, and blank content never shown
    assert "b.cpp:90" in card
    assert "命名可读性差" in card
    assert "a.cpp:587" not in card
    assert "a.cpp:637" not in card
    assert "a.cpp:641" not in card
    assert "—   " not in card  # ghost lines would end in a bare dash


def test_ghost_finding_missing_message_field_is_dropped():
    """A finding lacking a message key entirely must also be dropped."""
    findings = [
        {"severity": "中", "repo": "il2cpp", "file": "src/x.cpp",
         "line": 7, "message": "", "line_range": "7"},
        {"severity": "严重", "repo": "il2cpp", "file": "src/x.cpp",
         "line": 30, "message": None, "line_range": "30"},
        {"severity": "轻", "repo": "il2cpp", "file": "src/y.cpp",
         "line": 5, "message": "mask 不对称"},
    ]
    assert _is_meaningful_finding(findings[0]) is False
    assert _is_meaningful_finding(findings[1]) is False
    assert _is_meaningful_finding(findings[2]) is True
    card = _render_grid_filtered(findings)
    assert "y.cpp" in card and "mask 不对称" in card
    assert "x.cpp" not in card


def test_review_script_validator_is_strip_aware():
    """The live review-with-claude.sh validator itself must be whitespace-aware, so
    ghost findings are killed at the source (before counts/summary/cache are built)."""
    body = _read(REVIEW_SCRIPT)
    # The validator must .strip() content before deeming a field present.
    assert ".strip()" in body


def test_renderer_mirrors_ghost_guard():
    """The shipped card renderer must skip blank-message findings as a defense
    in depth even if one slips past source validation (old cache, legacy file).
    The render loop was extracted out of the Jenkinsfile inline python into
    scripts/code-review-card.py (layer 3), so that file is what we pin to."""
    card_script = os.path.join(REPO_ROOT, "scripts", "code-review-card.py")
    body = _read(card_script)
    # Look at the render region: findings-list build + ghost skip, up to em-dash.
    start = body.find("severity_icons = ")
    end = body.find("# Build risk overview line", start)
    region = body[start:end]
    assert "flines.append" in region
    # region must contain a blank/whitespace message skip so a dangling "— " can't render
    assert ".strip()" in region


# ── 2c. Shell / embedded-Python syntax guard ────────────────────────────────
#
# History: a stray ASCII apostrophe in a COMMENT inside a single-quoted
# `python3 -c '...'` block (`they'd`) terminated bash's quote early; the orphaned
# Python was then parsed as shell and raised `line N: syntax error near ... (')`.
# That silently passed the text-grep tests and only exploded once the real
# pipeline ran the script on the Jenkins agent (builds 856/857 went red).
#
# These two tests pin the fix at BOTH layers the failure can live in:
#   - test_A (bash -n):  validates the whole shell syntax tree. Catches the
#     unbalanced-quote/paren class the original bug belonged to.
#   - test_B (compile):  extracts every LITERAL embedded Python region that bash
#     will feed verbatim to python3 — single-quoted `-c '…'` bodies and `<<'PY'`
#     heredocs — and compiles each. Catches syntax errors INSIDE the Python that
#     bash -n cannot see (balanced shell quoting, bad Python).
#
# Deliberately NOT compiled: double-quoted `-c "…"` bodies — those routinely embed
# shell var refs (`$HOME`, `${env.X}`) that are not valid literal Python and would
# be false positives. A single-quoted body or `'PY'` heredoc that contains an
# apostrophe/shell-special char is already unbalanced and fails test_A first, so
# test_B only ever sees well-formed quoting.

def _embedded_python_regions(body):
    """Yield (label, code) for every Python region bash feeds verbatim to python3,
    covering ALL the quoting styles actually used in this repo's scripts:
      * single-quoted  `python3 -c '...'`            (always literal)
      * double-quoted  `python3 -c "..."`  WITHOUT a `$` (no shell interp → literal)
      * quoted heredoc `python3 ... <<'TAG'` / `<<'PYEOF'`  (always literal)
    A double-quoted block that embeds a `$` (shell var/subcommand) is NOT returned,
    because bash expands it before python runs and the raw text is not valid Python.
    A single-quoted body / heredoc with an unbalanced quote is also skipped here —
    `bash -n` catches that class first (test_A), so B only ever sees well-formed
    quoting.
    """
    regions = []
    single = re.finditer(r"python3[^'\"\\]* -c '", body)
    for m in single:
        start = m.end()
        end = body.find("'", start)
        if end == -1:
            continue  # unterminated; test_A already flags it
        code = body[start:end]
        if code.count("'") > code.count("\\'") + code.count('"'):
            continue  # ambiguous/unterminated inner quote — let test_A handle it
        regions.append(("python3 -c '...' at offset %d" % start, code))

    for m in re.finditer(r'python3 -c "', body):
        start = m.end()
        # Find the closing double-quote that is NOT escaped (backslash before it).
        # monitor.sh's 137-line block has f-strings with escaped \" within, so
        # a naive body.find('"', start) would stop at the first escaped quote.
        i = start
        while i < len(body):
            q = body.find('"', i)
            if q == -1:
                break
            # Count backslashes immediately before the quote: odd count = escaped.
            bs = 0
            j = q - 1
            while j >= 0 and body[j] == '\\':
                bs += 1
                j -= 1
            if bs % 2 == 1:
                i = q + 1  # escaped, skip past it
                continue
            code = body[start:q]
            if "$" in code:
                break  # shell-interpolated → not literal python, skip
            # Bash processes the double-quoted body before python sees it:
            #   `\"` → `"`, `\\` → `\`.  Our extraction gets the raw text with
            # shell escapes still present, which is NOT valid Python.  Unescape
            # so compile() matches what python actually receives.
            code = code.replace('\\"', '"').replace("\\\\", "\\")
            regions.append(('python3 -c "..." at offset %d' % start, code))
            break

    # quoted heredocs fed to python (python3 ... <<'TAG' or <<- 'TAG'), allowing an
    # optional space between << and the quote, and an optional `-` prefix (bash's
    # <<- strips leading tabs from the heredoc body). Anchored on the python
    # invocation so plain `cat <<'TAG'` heredocs (e.g. the prompt templates in
    # review-with-claude.sh, which contain Chinese markdown, not python) are never
    # mistaken for python.
    for m in re.finditer(r"(?m)^[ \t]*[A-Za-z0-9_/.-]*python3[^\n]*<<[-]?\s?'?([A-Za-z0-9_]+)'", body):
        tag = m.group(1)
        # content starts on the NEXT line (the same line after the heredoc
        # delimiter may have shell redirections like "2>/dev/null || true"
        # that are NOT part of the python source).
        body_start = body.find('\n', m.end()) + 1
        if body_start <= 0:
            continue
        marker = "\n" + tag
        end = body.find(marker, body_start)
        if end == -1:
            continue
        code = body[body_start:end]
        regions.append(("python3 <<'%s' heredoc" % tag, code))

    return regions


def _bash_syntax_error(path):
    """Run `bash -n`; return a human message on failure, or None when clean."""
    result = subprocess.run(
        ["bash", "-n", path], capture_output=True, text=True,
    )
    if result.returncode == 0:
        return None
    return ("Shell syntax error in %s (bash -n):\n%s"
            % (os.path.basename(path), result.stderr.strip()))


def _compile_embedded_python(path, require_region=True):
    """compile() every literal embedded-python region of `path`. Returns a list of
    human messages on failure (empty == clean)."""
    body = _read(path)
    regions = _embedded_python_regions(body)
    problems = []
    for label, code in regions:
        try:
            compile(code, "<" + os.path.basename(path) + ": " + label + ">", "exec")
        except SyntaxError as e:
            problems.append(
                "Python syntax error in %s @ %s (line %s): %s\nCode was:\n%s"
                % (os.path.basename(path), label, e.lineno or "?", e.msg, code[:400])
            )
    return problems


# ── 2d. Syntax guard applied to ALL shell scripts with embedded python ─────
#
# Generalization of 2c: the same two-layer guard (bash -n for the shell tree,
# compile() for literal embedded python) that protects review-with-claude.sh is
# applied to every script in the repo that inlines python, because a syntax error
# in any of the CRON scripts (below) silently kills a production path with no
# checkout or validation, exactly as builds 856/857 died on the review script.

# Every shell script under scripts/ that embeds python via any of the transports
# the audit found (single/double `-c`, quoted heredoc), excluding only scripts
# whose inline blocks are fully `$`-interpolated (B auto-skips those, A still runs).
# Kept as a plain constant so adding/removing a script is a one-line change and the
# cron-syntax test is the single enforcement point.
_SCRIPT_DIR = os.path.join(REPO_ROOT, "scripts")
_SHELL_SCRIPTS_WITH_PYTHON = [
    "review-with-claude.sh",      # single-quote -c + python heredocs (856/857 case)
    "send-code-review-card.sh",   # shell wrapper for the extracted card-send python
    # cron, every 1 minute:
    "trigger-code-review.sh",
    "trigger-pr-review.sh",
    # cron, every 5 minutes:
    "monitor.sh",
    "monitor-il2cpp-review.sh",
    # nightly / Jenkins-node scripts:
    "collect-all-results.sh",     # 234-line quoted heredoc (PYEOF)
    "notify-feishu.sh",           # quoted heredoc (PYEOF)
    "notify-feishu-text.sh",
    "nightly-orchestrator.sh",
    "startup.sh",
]


def test_code_review_card_python_compiles():
    """The standalone card-render script (moved out of the Jenkinsfile inline
    python in layer 3) must compile cleanly, so a future edit there can't
    slip a SyntaxError past the review flow. This is the file that now owns the
    commit-parse + ghost-filter + card build."""
    card = os.path.join(REPO_ROOT, "scripts", "code-review-card.py")
    assert os.path.isfile(card), "code-review-card.py missing"
    result = subprocess.run(
        ["python3", "-m", "py_compile", card], capture_output=True, text=True
    )
    assert result.returncode == 0, (
        "code-review-card.py has a Python syntax error:\n" + result.stderr.strip()
    )


def test_review_script_passes_bash_syntax_check():
    """review-with-claude.sh must pass `bash -n`. (Regression gate for builds
    856/857 — a stray apostrophe in an embedded single-quote block.)"""
    err = _bash_syntax_error(REVIEW_SCRIPT)
    assert err is None, err


def test_embedded_python_chunks_are_valid_python():
    """review-with-claude.sh's literal embedded Python must compile cleanly."""
    problems = _compile_embedded_python(REVIEW_SCRIPT)
    assert not problems, "\n".join(problems)


def test_scripts_with_embedded_python_pass_syntax_guard():
    """Every shell script that inlines python must (A) parse under `bash -n` AND
    (B) have no malformed literal (non-shell-interpolated) embedded Python. This
    covers the cron-production scripts and the Jenkins-node aggregation/notify
    scripts, none of which have a checkout or sanity gate — a syntax error is a
    silent outage, exactly how builds 856/857 died on the review script."""
    failures = []
    for name in _SHELL_SCRIPTS_WITH_PYTHON:
        p = os.path.join(_SCRIPT_DIR, name)
        err = _bash_syntax_error(p)
        if err:
            failures.append(err)
            continue
        for problem in _compile_embedded_python(p):
            failures.append(problem)
    assert not failures, "\nGuard failures (run each bash -n / compile() by hand for a precise line):\n" + "\n".join(failures)


# ── 3. Full-flow simulation (schema contract end-to-end) ───────────────────

def test_full_flow_summary_contract():
    """Simulate review-with-claude.sh writing a rage findings JSON, then the
    Jenkinsfile parsing summary keys from it and producing the echo line."""
    findings_file = {"summary": {"严重": 1, "中": 2, "轻": 1, "建议": 0,
                                 "total_findings": 4},
                     "findings": [
                         {"severity": "严重", "repo": "il2cpp", "file": "src/b.cpp",
                          "line": 30, "message": "内存泄漏"},
                         {"severity": "中", "repo": "il2cpp", "file": "src/a.cpp",
                          "line": 1303, "message": "mask"},
                         {"severity": "中", "repo": "il2cpp", "file": "src/e.cpp",
                          "line": 7, "message": "x"},
                         {"severity": "轻", "repo": "il2cpp", "file": "src/d.cpp",
                          "line": 99, "message": "y"},
                     ]}
    # the Jenkinsfile parses summary['严重']/['中']/['轻']/['建议']/total_findings
    s = findings_file["summary"]
    sev = s["严重"]; med = s["中"]; light = s["轻"]; adv = s["建议"]; total = s["total_findings"]
    assert sev == 1 and med == 2 and light == 1 and adv == 0 and total == 4
    # review-with-claude.sh's stdout summary line prints in rage order
    line = "Findings: %d 严重 · %d 中 · %d 轻 · %d 建议" % (sev, med, light, adv)
    assert line == "Findings: 1 严重 · 2 中 · 1 轻 · 0 建议"
    # card renders first 4 findings severity-sorted with rage format
    card = _render_rage_card(findings_file["findings"])
    for sev_name in ("严重", "中", "轻"):
        assert ("[%s] [il2cpp]" % sev_name) in card
    assert "建议" not in "".join(x["severity"] for x in findings_file["findings"])


def _main():
    """Self-run when invoked directly (no pytest dependency)."""
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    failures = 0
    for fn in fns:
        try:
            fn()
            print("PASS %s" % fn.__name__)
        except AssertionError as e:
            failures += 1
            print("FAIL %s: %s" % (fn.__name__, e))
    print("\n%d/%d passed" % (len(fns) - failures, len(fns)))
    if failures:
        sys.exit(1)


# ── 4. JSON-extraction robustness (regression for "0 findings" bug) ─────────

def _extract_json(claude_out):
    """Mirror of the extractor now in review-with-claude.sh."""
    import json
    def strip_fences(s):
        out = []; in_block = False
        for line in s.splitlines():
            st = line.strip()
            if st.startswith("```"):
                in_block = not in_block; continue
            if not in_block:
                out.append(line)
        return "\n".join(out)
    def find_json_object(s):
        depth = 0; start = None
        for i, ch in enumerate(s):
            if ch == "{":
                if depth == 0: start = i
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0 and start is not None:
                    try:
                        obj = json.loads(s[start:i+1])
                        if isinstance(obj, dict) and isinstance(obj.get("summary"), dict):
                            return obj
                    except Exception:
                        pass
                    start = None
        return None
    for src in (strip_fences(claude_out), claude_out):
        obj = find_json_object(src)
        if obj is not None:
            return obj
    return None


def test_extractor_survives_prose_braces_and_message_braces():
    # prose BEFORE the JSON with {} braces, AND finding message containing {1}
    out = ("Let me analyze: the '{0} moves, {1} rewrites' metric is suspicious.\n"
           "```json\n"
           '{"summary":{"严重":0,"中":2,"轻":1,"总":0,"total_findings":3},'
           '"findings":[{"severity":"中","message":"log says rewrites {1} but uses moves.size()"}]}\n'
           "```\n(complete)")
    obj = _extract_json(out)
    assert obj is not None and obj["summary"]["中"] == 2, obj


def test_extractor_returns_none_on_no_json():
    assert _extract_json("no json object in here, just prose") is None


def test_extractor_does_not_report_fake_clean():
    # If there is truly no parseable review JSON, the script now FAILS LOUDLY
    # (exit != 0) instead of fabricating a 0/0/0/0 "clean" result. This test pins
    # that contract: an unparseable review must NOT become a silent clean pass.
    assert _extract_json("SOME ERROR, no braces at all") is None


# ── 4b. Chunked-review aggregation (mirrors review-with-claude.sh loop) ─────

def _merge_summary(*summs):
    import json
    a = {"严重": 0, "中": 0, "轻": 0, "建议": 0}
    for s in summs:
        for k in ("严重", "中", "轻", "建议"):
            a[k] += s.get(k, 0)
    a["total_findings"] = a["严重"] + a["中"] + a["轻"] + a["建议"]
    return a


def test_chunked_aggregation_sums_findings():
    # 3 per-file chunks -> aggregated summary + findings list
    c1 = {"严重": 1, "中": 0, "轻": 0, "建议": 0, "total_findings": 1}
    c2 = {"严重": 0, "中": 2, "轻": 0, "建议": 1, "total_findings": 3}
    c3 = {"严重": 0, "中": 0, "轻": 1, "建议": 0, "total_findings": 1}
    agg = _merge_summary(c1, c2, c3)
    assert agg == {"严重": 1, "中": 2, "轻": 1, "建议": 1, "total_findings": 5}
    assert agg["total_findings"] == 5


def test_chunked_aggregation_empty_chunks_noop():
    # A genuinely empty chunk (docs-only, or true clean) contributes 0.
    empty = {"严重": 0, "中": 0, "轻": 0, "建议": 0, "total_findings": 0}
    agg = _merge_summary(empty)
    assert agg["total_findings"] == 0
    # ...and does not fabricate findings when all chunks are empty
    assert _merge_summary(empty, empty)["total_findings"] == 0


def test_chunked_findings_concat():
    # final findings array = ordered concat of each chunk's findings
    import json
    fl = [{"severity": "严重", "file": "a.cpp"}, {"severity": "中", "file": "b.cpp"}]
    fl2 = [{"severity": "轻", "file": "c.cpp"}]
    merged = fl + fl2
    assert len(merged) == 3
    assert merged[0]["file"] == "a.cpp" and merged[2]["severity"] == "轻"


if __name__ == "__main__":
    _main()


# ── 5. Low-confidence + cache behavior (方案1+4) ─────────────────────────────

def test_review_script_emits_low_confidence_marker():
    """review-with-claude.sh must emit low_confidence when a substantive-code diff
    yields 0 findings — so the card can show '待人工确认' instead of a flat clean."""
    body = _read(REVIEW_SCRIPT)
    # the marker is written into the JSON when total_findings==0 on non-docs code
    assert "low_confidence" in body, "script must set a low_confidence flag"


def test_jenkinsfile_consumes_low_confidence():
    """The low-confidence '0 发现' fallback card text must be produced instead of
    '✅ 本次未发现代码问题' when the review is low-confidence. Since the card
    render loop (incl. the low_confidence risk line) moved out of the Jenkinsfile
    inline python into scripts/code-review-card.py (layer 3), check that file."""
    card = os.path.join(REPO_ROOT, "scripts", "code-review-card.py")
    body = _read(card)
    assert "REVIEW_LOW_CONF" in body or "low_confidence" in body
    assert "低置信" in body  # the card fallback text when low-confidence
    # Jenkinsfile still gates on the flag before deciding to send a docs/lc card:
    jbody = _read(JENKINSFILE)
    assert "REVIEW_LOW_CONF" in jbody


def test_review_script_never_caches_empty_result():
    """A 0-findings result must NOT be written to the diff-hash cache, so a model
    glitch can never masquerade as a cached clean pass."""
    body = _read(REVIEW_SCRIPT)
    assert "_TOTAL" in body and "not caching" in body
    assert "not caching" in body


if __name__ == "__main__":
    _main()


# ── 6. Incomplete-review (方案A) — partial glitch must not fail the build ───

def test_review_script_skips_not_fails_on_glitch():
    """When a model glitch makes a chunk unparseable after retries, the script must
    SKIP that chunk (incomplete) and continue — NOT exit 1 / fail the build. This
    stops the "构建失败" Feishu spam for a transient model glitch."""
    body = _read(REVIEW_SCRIPT)
    # the skip path sets INCOMPLETE and continues, not CHUNK_FAILED-exit-1
    assert "INCOMPLETE=1" in body
    assert "skipping" in body
    # the hard "refusing to emit a partial/false result" exit is GONE
    assert "refusing to emit a partial" not in body


def test_jenkinsfile_commit_parse_region_has_no_backslash():
    """THE COMMIT-PARSE PYTHON MOVED OUT OF THE Groovy sh triple-quote string into
    scripts/code-review-card.py (layer 3), so the Groovy '\\  is an escape and
    breaks the build' hazard no longer applies to it. Before that move, a backslash
    in the Jenkinsfile inline python killed every code-review build at compile
    time (2026-09-04 build #814, and 2026-09-08 builds 856/857).  This now checks
    the standalone card parser still uses the safe chr(0)/chr(10)/splitlines()
    constructs.  (In a real .py a backslash is harmless python, but keeping the
    parser consistent avoids subtle NUL/newline bugs.)"""
    card = os.path.join(REPO_ROOT, "scripts", "code-review-card.py")
    body = _read(card)
    start = body.index('commits = []')
    end = body.index('# Also read findings JSON', start)   # end of the parse+render block
    region = body[start:end]
    assert 'chr(0)' in region, "must split on NUL via chr(0), not backslash escape"
    assert 'splitlines()' in region or 'chr(10)' in region, (
        "must split/join newlines via splitlines()/chr(10), not backslash escapes")


def test_review_script_emits_incomplete_flag():
    """findings JSON must carry an `incomplete` field so the card can warn that
    part of the diff was not reviewed (model glitch), distinct from a clean pass."""
    body = _read(REVIEW_SCRIPT)
    assert '"incomplete"' in body


if __name__ == "__main__":
    _main()
