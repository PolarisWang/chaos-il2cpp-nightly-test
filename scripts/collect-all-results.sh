#!/bin/bash
# collect-all-results.sh — Aggregate all chunk results from all DLLs into a single nightly data JSON.
#
# Reads each DLL's chunks/*/results/{fact,benchmark,hotupdate,profile}.json
# and the aggregate stage output at _dll/reports/latest/
#
# Usage: collect-all-results.sh [--foundation-dir /path/to/foundation-dll]
#                               [--output-dir /path/to/output]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FOUNDATION_DIR=""
OUTPUT_DIR=""
DATE_TAG="$(date +%Y%m%d-%H%M%S)"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --foundation-dir) FOUNDATION_DIR="$2"; shift 2 ;;
        --output-dir)     OUTPUT_DIR="$2";     shift 2 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

# Auto-detect foundation-dll
if [[ -z "$FOUNDATION_DIR" ]]; then
    for candidate in \
        "${REPO_ROOT}/testing/foundation-dll" \
        "/booming-il2cpp/testing/foundation-dll"; do
        if [[ -d "$candidate" ]]; then
            FOUNDATION_DIR="$candidate"
            break
        fi
    done
fi

if [[ -z "$FOUNDATION_DIR" || ! -d "$FOUNDATION_DIR" ]]; then
    echo "ERROR: foundation-dll not found at ${FOUNDATION_DIR}"
    exit 1
fi

if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="${FOUNDATION_DIR}/output"
fi
mkdir -p "$OUTPUT_DIR"

echo "=== Collecting results from ${FOUNDATION_DIR} ==="

# Build JSON payload using python3 for robust JSON handling
python3 - "$FOUNDATION_DIR" "$OUTPUT_DIR" "$DATE_TAG" << 'PYEOF'
import json, os, sys, glob
from pathlib import Path

foundation_dir = Path(sys.argv[1])
output_dir = Path(sys.argv[2])
date_tag = sys.argv[3]

# Discover all DLLs
all_dlls = sorted(d.name for d in foundation_dir.iterdir() if (d / "chunks").is_dir())

report = {
    "date_tag": date_tag,
    "total_dlls": len(all_dlls),
    "dlls": {},
    "aggregate": {},
    "summary": {
        "fact_passed": 0,
        "fact_total": 0,
        "benchmark_methods": 0,
        "hotupdate_passed": 0,
        "hotupdate_total": 0,
        "memory_alloc_bytes": 0,
        "memory_gc_pause_ns": 0,
        "memory_fast_path_rate": 0.0,
        "memory_methods_profiled": 0,
    },
}

fact_counted = 0
benchmark_counted = 0
hotupdate_counted = 0
memory_counted = 0

for dll in all_dlls:
    dll_dir = foundation_dir / dll
    chunks_dir = dll_dir / "chunks"
    reports_dir = dll_dir / "_dll" / "reports" / "latest"

    chunk_slugs = sorted(d.name for d in chunks_dir.iterdir() if d.is_dir())
    dll_data = {
        "chunks": {},
        "aggregate": {},
    }

    for slug in chunk_slugs:
        results_dir = chunks_dir / slug / "results"
        chunk_data = {}

        # Fact
        fact_file = results_dir / "fact.json"
        if fact_file.exists():
            try:
                chunk_data["fact"] = json.loads(fact_file.read_text(encoding="utf-8"))
            except Exception as e:
                chunk_data["fact"] = {"error": str(e)}

        # Benchmark
        bench_file = results_dir / "benchmark.json"
        if bench_file.exists():
            try:
                chunk_data["benchmark"] = json.loads(bench_file.read_text(encoding="utf-8"))
            except Exception as e:
                chunk_data["benchmark"] = {"error": str(e)}

        # Profile (memory)
        profile_file = results_dir / "profile.json"
        if profile_file.exists():
            try:
                chunk_data["profile"] = json.loads(profile_file.read_text(encoding="utf-8"))
            except Exception as e:
                chunk_data["profile"] = {"error": str(e)}

        # HotUpdate
        hotupdate_file = results_dir / "hotupdate.json"
        if hotupdate_file.exists():
            try:
                chunk_data["hotupdate"] = json.loads(hotupdate_file.read_text(encoding="utf-8"))
            except Exception as e:
                chunk_data["hotupdate"] = {"error": str(e)}

        dll_data["chunks"][slug] = chunk_data

        # Compute summary
        fact = chunk_data.get("fact", {})
        if fact and "error" not in fact:
            report["summary"]["fact_passed"] += fact.get("passed", 0)
            report["summary"]["fact_total"] += fact.get("total", 0)

        bench = chunk_data.get("benchmark", {})
        if bench and "error" not in bench:
            report["summary"]["benchmark_methods"] += bench.get("methodCount", 0)

        hot = chunk_data.get("hotupdate", {})
        if hot and "error" not in hot:
            report["summary"]["hotupdate_passed"] += hot.get("passCount", 0)
            report["summary"]["hotupdate_total"] += hot.get("patchCount", 0)

        prof = chunk_data.get("profile", {})
        if prof and "error" not in prof:
            report["summary"]["memory_alloc_bytes"] += prof.get("totalNurseryAllocBytes", 0)
            report["summary"]["memory_gc_pause_ns"] += prof.get("totalGcPauseNs", 0)
            report["summary"]["memory_fast_path_rate"] = max(
                report["summary"]["memory_fast_path_rate"],
                prof.get("fastPathRate", 0)
            )
            report["summary"]["memory_methods_profiled"] += prof.get("methodCount", 0)

    # Aggregate report
    for ag_file in ["fact-summary.json", "benchmark-summary.json",
                    "profile-summary.json", "dashboard.json",
                    "comparison-summary.json"]:
        ap = reports_dir / ag_file
        if ap.exists():
            try:
                dll_data["aggregate"][ag_file.replace(".json", "")] = json.loads(ap.read_text(encoding="utf-8"))
            except Exception:
                pass

    report["dlls"][dll] = dll_data

# Write output
output_file = output_dir / f"nightly-data-{date_tag}.json"
output_file.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")

summary = report["summary"]
fact_pct = (summary["fact_passed"] / summary["fact_total"] * 100) if summary["fact_total"] > 0 else 0

print(f"Collected {len(all_dlls)} DLLs")
print(f"  Fact:     {summary['fact_passed']}/{summary['fact_total']} passed ({fact_pct:.1f}%)")
print(f"  BMK:      {summary['benchmark_methods']} methods")
print(f"  HotUp:    {summary['hotupdate_passed']}/{summary['hotupdate_total']} passed")
print(f"  Memory:   {summary['memory_methods_profiled']} methods profiled")
print(f"            {summary['memory_alloc_bytes'] / (1024*1024):.1f} MB nursery alloc")
print(f"            {summary['memory_gc_pause_ns'] / 1e9:.2f}s total GC pause")
print(f"  Output:   {output_file}")
PYEOF
