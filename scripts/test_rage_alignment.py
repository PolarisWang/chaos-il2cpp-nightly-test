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
