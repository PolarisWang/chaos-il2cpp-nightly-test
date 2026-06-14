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

# Extract per-method benchmark, coverage, and comparison data for expanded ingestion
benchmark_methods_all = {}
coverage_all = {}
comparison_all = {}

for dll_name, dll_data in report["dlls"].items():
    # Per-method benchmark data
    methods_list = []
    for slug, chunk in dll_data.get("chunks", {}).items():
        bench = chunk.get("benchmark", {})
        if bench and "error" not in bench and "results" in bench:
            for result in bench["results"]:
                methods_list.append({
                    "chunk_name": slug,
                    "method_name": result.get("methodName", result.get("name", "unknown")),
                    "elapsed_ms": result.get("elapsedMilliseconds") or result.get("elapsedMs"),
                    "ops_per_sec": result.get("opsPerSecond"),
                    "memory_bytes": result.get("memoryBytes"),
                })
    if methods_list:
        methods_list.sort(key=lambda x: x.get("elapsed_ms") or 0, reverse=True)
        benchmark_methods_all[dll_name] = methods_list[:100]

    # Coverage data
    agg = dll_data.get("aggregate", {})
    cov = agg.get("coverage-audit")
    if cov:
        coverage_all[dll_name] = cov

    # Comparison data
    comp = agg.get("comparison-summary")
    if comp:
        results_list = comp.get("results", comp.get("methods", []))
        comparisons = []
        for method in results_list:
            comparisons.append({
                "method_name": method.get("name", method.get("methodName", "unknown")),
                "chaos_aot_ms": method.get("chaosAotMs") or method.get("chaos_aot_ms"),
                "dotnet_8_ms": method.get("dotnet8Ms") or method.get("dotnet_8_ms"),
                "dotnet_10_ms": method.get("dotnet10Ms") or method.get("dotnet_10_ms"),
                "speedup_vs_8": method.get("speedupVs8") or method.get("speedup_vs_8"),
                "speedup_vs_10": method.get("speedupVs10") or method.get("speedup_vs_10"),
            })
        if comparisons:
            comparison_all[dll_name] = comparisons

# Attach expanded data to report
report["benchmark_methods"] = benchmark_methods_all
report["coverage"] = coverage_all
report["comparison"] = comparison_all

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

# ── Ingest into Report API (SQLite trends) ──
API_URL="${REPORT_API_URL:-http://report-api:8000}"
DATE_TAG_CLEAN="${DATE_TAG%%-*}"
echo ""
echo "=== Ingesting into Report API ==="
if curl -sf -X POST "${API_URL}/api/ingest?date_tag=${DATE_TAG_CLEAN}" 2>/dev/null; then
    echo "  Ingestion successful"
else
    echo "  WARNING: API ingestion failed (API may not be running yet)"
    echo "  You can manually ingest later:"
    echo "    curl -X POST '${API_URL}/api/ingest?date_tag=${DATE_TAG_CLEAN}'"
fi

# ── Upload to MinIO ───────────────────────────────────────────
echo ""
echo "=== Uploading raw artifacts to MinIO ==="
if command -v mc &>/dev/null; then
    MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://chaos-minio:9000}"
    MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY:-minioadmin}"
    MINIO_SECRET_KEY="${MINIO_SECRET_KEY:-minioadmin}"

    # Configure mc alias
    mc alias set local "${MINIO_ENDPOINT}" "${MINIO_ACCESS_KEY}" "${MINIO_SECRET_KEY}" 2>/dev/null || {
        echo "  WARNING: Failed to configure MinIO client (mc)"
        echo "  Skipping MinIO upload"
        exit 0
    }

    UPLOAD_COUNT=0
    for dll_dir in "${FOUNDATION_DIR}"/_dll/reports/latest; do
        for dll_name in "${FOUNDATION_DIR}"/*/; do
            dll=$(basename "$dll_name")
            reports_dir="${FOUNDATION_DIR}/${dll}/_dll/reports/latest"
            [[ -d "$reports_dir" ]] || continue

            for artifact in comparison-summary.json benchmark-summary.json benchmark-full-report.json coverage-audit.json dashboard.json; do
                artifact_path="${reports_dir}/${artifact}"
                if [[ -f "$artifact_path" ]]; then
                    target="local/nightly-raw/${DATE_TAG_CLEAN}/${dll}/${artifact}"
                    if mc cp "$artifact_path" "$target" 2>/dev/null; then
                        UPLOAD_COUNT=$((UPLOAD_COUNT + 1))
                    fi
                fi
            done
        done
        break  # only process once (the _dll path pattern)
    done

    # Also upload the aggregated nightly data JSON
    OUTPUT_FILE="${OUTPUT_DIR}/nightly-data-${DATE_TAG}.json"
    if [[ -f "$OUTPUT_FILE" ]]; then
        if mc cp "$OUTPUT_FILE" "local/nightly-raw/${DATE_TAG_CLEAN}/_aggregated/nightly-data.json" 2>/dev/null; then
            UPLOAD_COUNT=$((UPLOAD_COUNT + 1))
        fi
    fi

    echo "  Uploaded ${UPLOAD_COUNT} artifacts to MinIO"
else
    echo "  WARNING: mc (MinIO client) not found — install it to enable artifact uploads"
    echo "  Install: curl -fsSL https://dl.min.io/client/mc/release/linux-amd64/mc -o /usr/local/bin/mc && chmod +x /usr/local/bin/mc"
fi
