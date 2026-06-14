#!/usr/bin/env python3
"""
generate-nightly-report.py — Generate comprehensive HTML nightly report.

Reads the aggregated nightly-data-<date>.json and optionally a previous
night's baseline to show benchmark regression/improvement deltas.

Usage:
    python3 generate-nightly-report.py --data nightly-data-<date>.json
                                       [--baseline nightly-data-<prev-date>.json]
                                       [--output nightly-report-<date>.html]
                                       [--build-number 123]
"""

import argparse
import json
import math
import sys
from datetime import datetime
from pathlib import Path


def load_data(path: Path) -> dict:
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def fmt_pct(passed: int, total: int) -> str:
    if total == 0:
        return "N/A"
    return f"{passed / total * 100:.1f}%"


def fmt_delta(val: float, suffix: str = "%") -> str:
    """Format a delta value with sign and color class."""
    if val is None or math.isnan(val):
        return '<span class="delta-none">—</span>'
    cls = "delta-pos" if val > 0 else ("delta-neg" if val < 0 else "delta-zero")
    sign = "+" if val > 0 else ""
    return f'<span class="{cls}">{sign}{val:.1f}{suffix}</span>'


def fmt_bytes(n: int) -> str:
    if n < 1024:
        return f"{n} B"
    elif n < 1024 * 1024:
        return f"{n / 1024:.1f} KB"
    elif n < 1024 * 1024 * 1024:
        return f"{n / (1024*1024):.1f} MB"
    return f"{n / (1024*1024*1024):.2f} GB"


def fmt_ns_to_ms(ns: int) -> str:
    return f"{ns / 1e6:.1f} ms"


def compute_dll_metrics(dll_data: dict) -> dict:
    """Extract aggregated metrics from a single DLL's data."""
    chunks = dll_data.get("chunks", {})

    fact_p = sum(c.get("fact", {}).get("passed", 0) for c in chunks.values() if "fact" in c)
    fact_t = sum(c.get("fact", {}).get("total", 0) for c in chunks.values() if "fact" in c)

    bmk = sum(c.get("benchmark", {}).get("methodCount", 0) for c in chunks.values() if "benchmark" in c)

    hot_p = sum(c.get("hotupdate", {}).get("passCount", 0) for c in chunks.values() if "hotupdate" in c)
    hot_t = sum(c.get("hotupdate", {}).get("patchCount", 0) for c in chunks.values() if "hotupdate" in c)

    mem_alloc = sum(c.get("profile", {}).get("totalNurseryAllocBytes", 0) for c in chunks.values() if "profile" in c)
    mem_gc = sum(c.get("profile", {}).get("totalGcPauseNs", 0) for c in chunks.values() if "profile" in c)

    return {
        "fact_passed": fact_p, "fact_total": fact_t,
        "benchmark_methods": bmk,
        "hotupdate_passed": hot_p, "hotupdate_total": hot_t,
        "mem_alloc_bytes": mem_alloc, "mem_gc_pause_ns": mem_gc,
    }


def css_color_class(fact_pct: float) -> str:
    if fact_pct >= 100:
        return "pass"
    elif fact_pct >= 90:
        return "warn"
    else:
        return "fail"


def bmk_delta_str(current: int, baseline: int | None) -> str:
    if baseline is None or baseline == 0:
        return ""
    if current == baseline:
        return " ±0"
    pct = (current - baseline) / baseline * 100
    return fmt_delta(pct)


def generate_report(data: dict, build_number: str = "",
                    baseline_data: dict | None = None) -> str:
    summary = data.get("summary", {})
    dlls = data.get("dlls", {})
    date_tag = data.get("date_tag", datetime.now().strftime("%Y%m%d-%H%M%S"))

    baseline_dlls = baseline_data.get("dlls", {}) if baseline_data else {}

    # ── Summary cards ──
    fact_passed = summary.get("fact_passed", 0)
    fact_total = summary.get("fact_total", 0)
    fact_pct_val = fmt_pct(fact_passed, fact_total)
    fact_pct_num = (fact_passed / fact_total * 100) if fact_total > 0 else 0

    bmk_methods = summary.get("benchmark_methods", 0)

    hot_passed = summary.get("hotupdate_passed", 0)
    hot_total = summary.get("hotupdate_total", 0)
    hot_pct_val = fmt_pct(hot_passed, hot_total)

    mem_alloc = summary.get("memory_alloc_bytes", 0)
    mem_gc_pause = summary.get("memory_gc_pause_ns", 0)
    mem_fast_path = summary.get("memory_fast_path_rate", 0) * 100

    total_dlls = len(dlls)
    has_data_count = sum(1 for v in dlls.values()
                         if any(c.get("fact", {}).get("total", 0) > 0
                                for c in v.get("chunks", {}).values()))
    no_data_count = total_dlls - has_data_count

    # ── Build per-DLL rows ──
    dll_rows = []
    regressed_dlls = []
    improved_dlls = []
    baseline_bmk_total = 0

    for dll_name in sorted(dlls.keys()):
        m = compute_dll_metrics(dlls[dll_name])
        bm = compute_dll_metrics(baseline_dlls.get(dll_name, {})) if baseline_dlls else {}

        dll_fact = fmt_pct(m["fact_passed"], m["fact_total"])
        fact_cls = css_color_class((m["fact_passed"] / m["fact_total"] * 100)
                                    if m["fact_total"] > 0 else 0)

        dll_bmk = str(m["benchmark_methods"]) if m["benchmark_methods"] > 0 else "-"
        baseline_bmk = bm.get("benchmark_methods", 0)
        baseline_bmk_total += baseline_bmk

        # Benchmark delta vs baseline
        bmk_delta = ""
        bmk_delta_cls = ""
        if baseline_bmk > 0 and m["benchmark_methods"] > 0:
            diff = m["benchmark_methods"] - baseline_bmk
            pct = diff / baseline_bmk * 100
            bmk_delta = f'{"+" if diff > 0 else ""}{diff} ({pct:+.1f}%)'
            bmk_delta_cls = "delta-pos" if diff > 0 else ("delta-neg" if diff < 0 else "delta-zero")
            if diff < 0:
                regressed_dlls.append(dll_name)
            elif diff > 0:
                improved_dlls.append(dll_name)

        # HotUpdate
        dll_hot = f"{m['hotupdate_passed']}/{m['hotupdate_total']}" if m["hotupdate_total"] > 0 else "-"

        # Memory
        dll_mem_alloc_str = fmt_bytes(m["mem_alloc_bytes"]) if m["mem_alloc_bytes"] > 0 else "-"
        dll_mem_gc_str = fmt_ns_to_ms(m["mem_gc_pause_ns"]) if m["mem_gc_pause_ns"] > 0 else "-"

        overall = "PASS" if m["fact_passed"] == m["fact_total"] else "FAIL"
        overall_cls = "pass" if overall == "PASS" else "fail"

        # Chunk detail expandable rows
        chunk_details = ""
        chunks = dlls[dll_name].get("chunks", {})
        for slug in sorted(chunks.keys()):
            c = chunks[slug]
            c_fact = c.get("fact", {})
            if "error" in c_fact:
                chunk_details += f"<tr><td>{slug}</td><td colspan=4 class=error>ERR: {c_fact['error']}</td></tr>"
                continue
            if not c_fact:
                continue
            c_p = c_fact.get("passed", 0)
            c_t = c_fact.get("total", 0)
            c_pct = fmt_pct(c_p, c_t)
            c_sus = "⚠️" if c_fact.get("valueSuspicious") else ""
            c_status = "pass" if c_p == c_t else "fail"
            chunk_details += f"<tr class='{c_status}'><td>{slug}</td><td>{c_p}/{c_t}</td><td>{c_pct}</td><td>{c_sus}</td><td>...</td></tr>"

        dll_rows.append((dll_name, dll_fact, fact_cls, dll_bmk, bmk_delta, bmk_delta_cls,
                         dll_hot, dll_mem_alloc_str, dll_mem_gc_str, overall_cls, chunk_details))

    # ── HTML ──
    fact_color = css_color_class(fact_pct_num)
    hot_color = "pass" if hot_passed == hot_total else ("warn" if hot_pct_val != "N/A" else "pass")

    regression_section = ""
    if regressed_dlls:
        regression_section = f"""
<div class="card regression-warn">
  <h2>⚠️ Benchmark Regression</h2>
  <p><strong>{len(regressed_dlls)}</strong> DLL(s) lost benchmark methods:</p>
  <ul>{"".join(f'<li>{d}</li>' for d in regressed_dlls)}</ul>
</div>"""
    if improved_dlls:
        regression_section += f"""
<div class="card regression-pass">
  <h2>✅ Benchmark Improvement</h2>
  <p><strong>{len(improved_dlls)}</strong> DLL(s) gained benchmark methods:</p>
  <ul>{"".join(f'<li>{d}</li>' for d in improved_dlls)}</ul>
</div>"""

    no_data_warn = ""
    if no_data_count > 0:
        no_data_warn = f'<div class="no-data-warn">⚠️ {no_data_count} assemblies have no test data — possibly new or skipped</div>'

    baseline_cols = ""
    if baseline_data:
        baseline_cols = '<th>BMK Δ</th>'

    html = f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>chaos-il2cpp Nightly Report — {date_tag}</title>
<style>
* {{ margin:0; padding:0; box-sizing:border-box; }}
body {{ font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;
       background:#f0f2f5; color:#333; padding:16px; }}
.header {{ background:linear-gradient(135deg,#1a1a2e,#16213e); color:#fff;
          padding:24px; border-radius:8px; margin-bottom:16px; }}
.header h1 {{ font-size:1.3rem; }}
.header .meta {{ opacity:.7; font-size:.85rem; margin-top:4px; }}
.grid {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(180px,1fr));
         gap:12px; margin-bottom:16px; }}
.card {{ background:#fff; border-radius:8px; padding:16px; box-shadow:0 1px 3px rgba(0,0,0,.1); }}
.card h2 {{ font-size:.8rem; color:#666; text-transform:uppercase; letter-spacing:.5px; margin-bottom:8px; }}
.card .value {{ font-size:1.8rem; font-weight:700; }}
.card .sub {{ font-size:.75rem; color:#999; margin-top:2px; }}
.regression-warn {{ border-left:4px solid #ef4444; }}
.regression-pass {{ border-left:4px solid #10b981; }}
.regression-warn ul, .regression-pass ul {{ margin:8px 0 0 16px; font-size:.85rem; }}
.regression-warn li, .regression-pass li {{ margin:2px 0; }}
.pass {{ color:#10b981; }}
.fail {{ color:#ef4444; }}
.warn {{ color:#f59e0b; }}
.delta-pos {{ color:#10b981; font-weight:600; }}
.delta-neg {{ color:#ef4444; font-weight:600; }}
.delta-zero {{ color:#999; }}
.delta-none {{ color:#ccc; }}
table {{ width:100%; border-collapse:collapse; font-size:.82rem; }}
th,td {{ padding:8px 10px; text-align:left; border-bottom:1px solid #e5e7eb; }}
th {{ background:#f9fafb; font-weight:600; color:#666; position:sticky; top:0; white-space:nowrap; }}
tr:hover td {{ background:#f0f7ff; }}
tr.fail td {{ background:#fef2f2; }}
.detail-row {{ display:none; }}
.detail-row td {{ padding:0; }}
.detail-row table {{ margin:0; }}
.detail-row table td {{ padding:4px 10px; font-size:.75rem; }}
.expand-btn {{ cursor:pointer; color:#4361ee; font-weight:600; }}
.expand-btn:hover {{ text-decoration:underline; }}
.error {{ color:#ef4444; }}
.no-data-warn {{ background:#fffbeb; border:1px solid #fde68a; border-radius:6px;
                padding:10px 16px; margin-bottom:12px; font-size:.85rem; color:#92400e; }}
.footer {{ text-align:center; color:#999; font-size:.75rem; margin-top:20px; padding:20px; }}
</style>
</head>
<body>
<div class="header">
  <h1>chaos-il2cpp Nightly Report — {date_tag}</h1>
  <div class="meta">Build #{build_number} · {total_dlls} assemblies · {datetime.now().strftime('%Y-%m-%d %H:%M')}</div>
</div>

{no_data_warn}

<div class="grid">
  <div class="card">
    <h2>构建</h2>
    <div class="value {'pass' if has_data_count == total_dlls else 'warn'}">{has_data_count}/{total_dlls}</div>
    <div class="sub">assemblies with data</div>
  </div>
  <div class="card">
    <h2>正确性</h2>
    <div class="value {fact_color}">{fact_pct_val}</div>
    <div class="sub">{fact_passed}/{fact_total} facts</div>
  </div>
  <div class="card">
    <h2>性能</h2>
    <div class="value warn">{bmk_methods}</div>
    <div class="sub">benchmarked methods</div>
  </div>
  <div class="card">
    <h2>热更新</h2>
    <div class="value {hot_color}">{hot_pct_val}</div>
    <div class="sub">{hot_passed}/{hot_total} patches</div>
  </div>
  <div class="card">
    <h2>内存</h2>
    <div class="value">{fmt_bytes(mem_alloc)}</div>
    <div class="sub">{fmt_ns_to_ms(mem_gc_pause)} GC · {mem_fast_path:.1f}% fast path</div>
  </div>
</div>

{regression_section}

<table>
<thead><tr>
  <th>Assembly</th><th>Fact</th><th>Benchmark</th>{baseline_cols}<th>HotUpdate</th><th>Memory</th><th>GC Pause</th><th>Status</th><th></th>
</tr></thead>
<tbody>
"""
    for row in dll_rows:
        name, fact, fact_cls, bmk, bmk_delta, bmk_cls, hot, mem, gc, overall_cls, details = row
        expand_id = f"d{hash(name) % 100000}"
        caret = "▶" if details else ""
        bmk_delta_cell = f'<td class="{bmk_cls}">{bmk_delta}</td>' if bmk_delta else ""
        html += f"""<tr class='{overall_cls}'>
  <td>{name}</td><td class="{fact_cls}">{fact}</td><td>{bmk}</td>{bmk_delta_cell}<td>{hot}</td><td>{mem}</td><td>{gc}</td>
  <td><span class='{overall_cls}'>{'✅' if overall_cls == 'pass' else '❌'}</span></td>
  <td class='expand-btn' onclick="toggleDetail('{expand_id}')">{caret}</td>
</tr>
<tr id='{expand_id}' class='detail-row'><td colspan=9>
<table>"""
        if details:
            html += f"<tr><th>Chunk</th><th>Fact</th><th>%</th><th>Susp.</th><th>Bench</th></tr>{details}"
        html += "</table></td></tr>"

    html += """
</tbody>
</table>

<div class="footer">
<p>chaos-il2cpp Nightly Pipeline · Jenkins + Allure + SonarQube</p>
<p>Generated by build #""" + build_number + """ · """ + datetime.now().strftime('%Y-%m-%d %H:%M:%S') + """</p>
</div>

<script>
function toggleDetail(id) {
  var el = document.getElementById(id);
  if (el) el.style.display = el.style.display === 'table-row' ? 'none' : 'table-row';
}
</script>
</body>
</html>
"""
    return html


def main():
    parser = argparse.ArgumentParser(description="Generate nightly HTML report with regression comparison")
    parser.add_argument("--data", required=True, help="Current nightly-data-<date>.json path")
    parser.add_argument("--baseline", default=None, help="Previous nightly-data-<prev-date>.json for comparison")
    parser.add_argument("--output", default=None, help="Output HTML path")
    parser.add_argument("--build-number", default="", help="Jenkins build number")
    args = parser.parse_args()

    data_path = Path(args.data)
    if not data_path.exists():
        print(f"ERROR: Data file not found: {data_path}")
        sys.exit(1)

    if args.output:
        output_path = Path(args.output)
    else:
        date_tag = (data_path.stem.split("-", 2)[-1]
                    if "nightly-data-" in data_path.name
                    else datetime.now().strftime("%Y%m%d-%H%M%S"))
        output_path = data_path.parent / f"nightly-report-{date_tag}.html"

    data = load_data(data_path)

    baseline_data = None
    if args.baseline:
        bl_path = Path(args.baseline)
        if bl_path.exists():
            baseline_data = load_data(bl_path)
            print(f"Baseline: {bl_path}")
        else:
            print(f"WARNING: Baseline not found, skipping comparison: {bl_path}")

    html = generate_report(data, build_number=args.build_number, baseline_data=baseline_data)
    output_path.write_text(html, encoding="utf-8")

    print(f"Report generated: {output_path}")
    print(f"  Size: {len(html)} bytes")
    if baseline_data:
        print(f"  Regression comparison: enabled")


if __name__ == "__main__":
    main()
