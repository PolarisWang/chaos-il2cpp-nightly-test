#!/usr/bin/env python3
"""
generate-nightly-report.py — Generate comprehensive HTML daily report.

Reads the aggregated nightly-data-<date>.json and produces a self-contained
HTML page with:

  - Summary cards: Build / Fact / Benchmark / Memory / HotUpdate
  - Per-DLL detail table (expandable)
  - Benchmark cross-DLL comparison bar chart (inline SVG)
  - Memory profile summary
  - HotUpdate pass/fail matrix

Usage:
    python3 generate-nightly-report.py --data nightly-data-<date>.json
                                       [--output nightly-report-<date>.html]
                                       [--build-number 123]
"""

import argparse
import json
import os
import sys
from datetime import datetime
from pathlib import Path


def load_data(path: Path) -> dict:
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def fmt_pct(passed, total) -> str:
    if total == 0:
        return "N/A"
    return f"{passed / total * 100:.1f}%"


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


def generate_report(data: dict, build_number: str = "", output_path: Path | None = None) -> str:
    summary = data.get("summary", {})
    dlls = data.get("dlls", {})
    date_tag = data.get("date_tag", datetime.now().strftime("%Y%m%d-%H%M%S"))

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
    mem_methods = summary.get("memory_methods_profiled", 0)

    total_dlls = data.get("total_dlls", 0)
    passed_dlls = sum(
        1 for v in dlls.values()
        if v.get("chunks") and any(
            c.get("fact", {}).get("passed", 0) > 0
            for c in v["chunks"].values()
        )
    )
    failed_dlls = total_dlls - passed_dlls

    # Build per-DLL rows
    dll_rows = []
    for dll_name in sorted(dlls.keys()):
        dll = dlls[dll_name]
        chunks = dll.get("chunks", {})

        # Aggregate fact
        dll_fact_passed = sum(
            c.get("fact", {}).get("passed", 0)
            for c in chunks.values() if "fact" in c
        )
        dll_fact_total = sum(
            c.get("fact", {}).get("total", 0)
            for c in chunks.values() if "fact" in c
        )
        dll_fact = fmt_pct(dll_fact_passed, dll_fact_total)

        # Aggregate benchmark
        dll_bmk_methods = sum(
            c.get("benchmark", {}).get("methodCount", 0)
            for c in chunks.values() if "benchmark" in c
        )
        dll_bmk = str(dll_bmk_methods) if dll_bmk_methods > 0 else "-"

        # Aggregate hotupdate
        dll_hot_passed = sum(
            c.get("hotupdate", {}).get("passCount", 0)
            for c in chunks.values() if "hotupdate" in c
        )
        dll_hot_total = sum(
            c.get("hotupdate", {}).get("patchCount", 0)
            for c in chunks.values() if "hotupdate" in c
        )
        dll_hot = f"{dll_hot_passed}/{dll_hot_total}" if dll_hot_total > 0 else "-"

        # Aggregate memory
        dll_mem_alloc = sum(
            c.get("profile", {}).get("totalNurseryAllocBytes", 0)
            for c in chunks.values() if "profile" in c
        )
        dll_mem_gc = sum(
            c.get("profile", {}).get("totalGcPauseNs", 0)
            for c in chunks.values() if "profile" in c
        )
        dll_mem_count = sum(
            c.get("profile", {}).get("methodCount", 0)
            for c in chunks.values() if "profile" in c
        )

        dll_mem_alloc_str = fmt_bytes(dll_mem_alloc) if dll_mem_alloc > 0 else "-"
        dll_mem_gc_str = fmt_ns_to_ms(dll_mem_gc) if dll_mem_gc > 0 else "-"

        overall = "PASS" if dll_fact_passed == dll_fact_total else "FAIL"

        # Chunk detail (expandable)
        chunk_details = ""
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

        dll_rows.append((dll_name, dll_fact, dll_bmk, dll_hot, dll_mem_alloc_str,
                         dll_mem_gc_str, overall, chunk_details))

    # ── HTML Template ──
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
.pass {{ color:#10b981; }}
.fail {{ color:#ef4444; }}
.warn {{ color:#f59e0b; }}
table {{ width:100%; border-collapse:collapse; font-size:.82rem; }}
th,td {{ padding:8px 10px; text-align:left; border-bottom:1px solid #e5e7eb; }}
th {{ background:#f9fafb; font-weight:600; color:#666; position:sticky; top:0; }}
tr:hover td {{ background:#f0f7ff; }}
tr.fail td {{ background:#fef2f2; }}
.detail-row {{ display:none; }}
.detail-row td {{ padding:0; }}
.detail-row table {{ margin:0; }}
.detail-row table td {{ padding:4px 10px; font-size:.75rem; }}
.expand-btn {{ cursor:pointer; color:#4361ee; font-weight:600; }}
.expand-btn:hover {{ text-decoration:underline; }}
.error {{ color:#ef4444; }}
.footer {{ text-align:center; color:#999; font-size:.75rem; margin-top:20px; }}
</style>
</head>
<body>
<div class="header">
  <h1>chaos-il2cpp Nightly Report — {date_tag}</h1>
  <div class="meta">Build #{build_number} · {total_dlls} assemblies · {datetime.now().strftime('%Y-%m-%d %H:%M')}</div>
</div>

<div class="grid">
  <div class="card">
    <h2>构建</h2>
    <div class="value {'pass' if failed_dlls == 0 else 'fail'}">{passed_dlls}/{total_dlls}</div>
    <div class="sub">assemblies passed</div>
  </div>
  <div class="card">
    <h2>正确性</h2>
    <div class="value {'pass' if fact_passed == fact_total else 'fail'}">{fact_pct_val}</div>
    <div class="sub">{fact_passed}/{fact_total} facts</div>
  </div>
  <div class="card">
    <h2>性能</h2>
    <div class="value warn">{bmk_methods}</div>
    <div class="sub">benchmarked methods</div>
  </div>
  <div class="card">
    <h2>热更新</h2>
    <div class="value {'pass' if hot_passed == hot_total else 'warn'}">{hot_pct_val}</div>
    <div class="sub">{hot_passed}/{hot_total} patches</div>
  </div>
  <div class="card">
    <h2>内存</h2>
    <div class="value">{fmt_bytes(mem_alloc)}</div>
    <div class="sub">{fmt_ns_to_ms(mem_gc_pause)} GC · {mem_fast_path:.1f}% fast path</div>
  </div>
</div>

<table>
<thead><tr><th>Assembly</th><th>Fact</th><th>Benchmark</th><th>HotUpdate</th><th>Memory</th><th>GC Pause</th><th>Status</th><th></th></tr></thead>
<tbody>
"""
    for name, fact, bmk, hot, mem, gc, status, details in dll_rows:
        status_cls = "pass" if status == "PASS" else "fail"
        expand_id = f"d{hash(name) % 100000}"
        caret = "▶" if details else ""
        html += f"""<tr class='{status_cls}'>
  <td>{name}</td><td>{fact}</td><td>{bmk}</td><td>{hot}</td><td>{mem}</td><td>{gc}</td>
  <td><span class='{status_cls}'>{'✅' if status == 'PASS' else '❌'}</span></td>
  <td class='expand-btn' onclick="toggleDetail('{expand_id}')">{caret}</td>
</tr>
<tr id='{expand_id}' class='detail-row'><td colspan=8>
<table>"""
        if details:
            html += f"<tr><th>Chunk</th><th>Fact</th><th>%</th><th>Susp.</th><th>Bench</th></tr>{details}"
        html += """</table></td></tr>"""

    html += """
</tbody>
</table>

<div class="footer">
<p>chaos-il2cpp Nightly Pipeline · Jenkins + Allure + SonarQube</p>
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
    parser = argparse.ArgumentParser(description="Generate nightly HTML report")
    parser.add_argument("--data", required=True, help="nightly-data-<date>.json path")
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
        date_tag = data_path.stem.split("-", 2)[-1] if "nightly-data-" in data_path.name else datetime.now().strftime("%Y%m%d-%H%M%S")
        output_path = data_path.parent / f"nightly-report-{date_tag}.html"

    data = load_data(data_path)
    html = generate_report(data, build_number=args.build_number)
    output_path.write_text(html, encoding="utf-8")

    print(f"Report generated: {output_path}")
    print(f"  Size: {len(html)} bytes")


if __name__ == "__main__":
    main()
