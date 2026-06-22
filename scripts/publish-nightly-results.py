#!/usr/bin/env python3
"""
publish-nightly-results.py — Publish nightly build results to CI infrastructure.

Reads from nightly_runner's ReportCollector output directory (and the original
foundation-dll chunks/ for entry.cpp), builds the backward-compatible
nightly-data-YYYYMMDD.json format, ingests into Report API, uploads artifacts
to MinIO, generates HTML report, and copies to report server.

This script replaces collect-all-results.sh as the aggregation layer
(Phase 2 of the nightly_runner migration).

Usage:
    python3 publish-nightly-results.py \\
        --report-dir /workspace/artifacts/nightly-run/latest \\
        --foundation-dir /booming-il2cpp/testing/foundation-dll \\
        --output-dir /workspace/artifacts \\
        --date-tag 20260622 \\
        [--run-tag run1] \\
        [--build-number 123] \\
        [--api-url http://report-api:8000] \\
        [--minio-endpoint http://chaos-minio:9000] \\
        [--report-server-dir /var/lib/report-server/daily] \\
        [--skip-ingest] [--skip-minio] [--skip-html]
"""

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from typing import Any

# ── entry.cpp regex (same pattern as collect-all-results.sh) ──────────
ENTRY_PATTERN = re.compile(
    r'\{\s*(\d+),\s*"((?:[^"\\]|\\.)*)",\s*"((?:[^"\\]|\\.)*)",\s*"((?:[^"\\]|\\.)*)",'
    r'\s*"((?:[^"\\]|\\.)*)",\s*(True|False),\s*"([^"]*)"\s*\}'
)


# ── Data models ──────────────────────────────────────────────────────

def discover_assemblies(foundation_dir: Path) -> list[str]:
    """Discover assemblies that have chunks/ directories."""
    return sorted(
        d.name for d in foundation_dir.iterdir()
        if d.is_dir() and (d / "chunks").is_dir()
    )


def discover_chunks(assembly: str, foundation_dir: Path) -> list[str]:
    """Discover chunk slugs for an assembly."""
    chunks_dir = foundation_dir / assembly / "chunks"
    if not chunks_dir.exists():
        return []
    return sorted(d.name for d in chunks_dir.iterdir() if d.is_dir())


def parse_entry_maps(foundation_dir: Path, assemblies: list[str]) -> dict:
    """Parse entry.cpp files for method name resolution (entry_maps)."""
    entry_maps: dict[str, dict[str, dict[int, dict]]] = {}
    for dll_name in assemblies:
        chunks_dir = foundation_dir / dll_name / "chunks"
        dll_entry_maps: dict[str, dict[int, dict]] = {}
        for slug_dir in sorted(chunks_dir.iterdir()):
            if not slug_dir.is_dir():
                continue
            slug = slug_dir.name
            entry_cpp_files = sorted(slug_dir.rglob("entry.cpp"))
            if not entry_cpp_files:
                entry_cpp_files = sorted(slug_dir.rglob("runtime-entry.cpp"))
            if not entry_cpp_files:
                continue
            for ecf in entry_cpp_files:
                if not ecf.exists():
                    continue
                try:
                    text = ecf.read_text(encoding="utf-8", errors="replace")
                    entries: dict[int, dict] = {}
                    for match in ENTRY_PATTERN.finditer(text):
                        idx = int(match.group(1))
                        entries[idx] = {
                            "subject_id": match.group(2),
                            "assembly_name": match.group(3),
                            "type_name": match.group(4),
                            "method_name": match.group(5),
                            "is_static": match.group(6) == "True",
                            "kind": match.group(7),
                        }
                    if entries:
                        dll_entry_maps[slug] = entries
                        print(f"  [publish] Parsed {len(entries)} entries from {dll_name}/{slug}")
                except Exception as e:
                    print(f"  [publish] WARNING: Failed to parse entry.cpp for {dll_name}/{slug}: {e}")
        if dll_entry_maps:
            entry_maps[dll_name] = dll_entry_maps
    return entry_maps


def read_chunk_results(report_dir: Path, assemblies: list[str]) -> dict:
    """Read per-chunk results from ReportCollector's per-chunk/ directory.

    ReportCollector copies chunks/<slug>/results/* → per-chunk/<asm>/<slug>/*
    (files directly under slug dir, no nested results/ subdirectory).
    """
    chunks = {}
    for asm in assemblies:
        per_chunk_asm = report_dir / "per-chunk" / asm
        if not per_chunk_asm.exists():
            continue
        for slug_dir in sorted(per_chunk_asm.iterdir()):
            if not slug_dir.is_dir():
                continue
            slug = slug_dir.name
            chunk_data = {}
            for fname in ("fact.json", "benchmark.json", "profile.json", "hotupdate.json", "comparison.json"):
                fp = slug_dir / fname
                if fp.exists():
                    try:
                        chunk_data[fname.replace(".json", "")] = json.loads(fp.read_text(encoding="utf-8"))
                    except Exception as e:
                        chunk_data[fname.replace(".json", "")] = {"error": str(e)}
            if chunk_data:
                if asm not in chunks:
                    chunks[asm] = {}
                chunks[asm][slug] = chunk_data
    return chunks


def read_aggregate_reports(report_dir: Path, assemblies: list[str]) -> dict:
    """Read per-assembly aggregate reports from ReportCollector's reports/ directory."""
    aggregates = {}
    for asm in assemblies:
        reports_asm = report_dir / "reports" / asm
        if not reports_asm.exists():
            continue
        agg = {}
        for fname in ("fact-summary.json", "benchmark-summary.json", "dashboard.json",
                       "comparison-summary.json", "coverage-audit.json", "profile-summary.json"):
            fp = reports_asm / fname
            if fp.exists():
                try:
                    agg[fname.replace(".json", "")] = json.loads(fp.read_text(encoding="utf-8"))
                except Exception:
                    pass
        if agg:
            aggregates[asm] = agg
    return aggregates


def compute_summary(chunks: dict) -> dict:
    """Compute cross-DLL summary metrics (same logic as collect-all-results.sh)."""
    summary: dict[str, Any] = {
        "fact_passed": 0, "fact_total": 0,
        "benchmark_methods": 0,
        "hotupdate_passed": 0, "hotupdate_total": 0,
        "memory_alloc_bytes": 0, "memory_gc_pause_ns": 0,
        "memory_fast_path_rate": 0.0, "memory_methods_profiled": 0,
    }
    for asm, slugs in chunks.items():
        for slug, chunk_data in slugs.items():
            # Fact
            fact = chunk_data.get("fact", {})
            if fact and "error" not in fact:
                summary["fact_passed"] += fact.get("passed", 0)
                summary["fact_total"] += fact.get("total", 0)
            # Benchmark
            bench = chunk_data.get("benchmark", {})
            if bench and "error" not in bench:
                summary["benchmark_methods"] += bench.get("methodCount", 0)
            # Hotupdate
            hot = chunk_data.get("hotupdate", {})
            if hot and "error" not in hot:
                summary["hotupdate_passed"] += hot.get("passed", 0)
                summary["hotupdate_total"] += hot.get("passed", 0) + hot.get("failed", 0)
            # Profile (memory)
            prof = chunk_data.get("profile", {})
            if prof and "error" not in prof:
                ps = prof.get("summary", {})
                summary["memory_alloc_bytes"] += ps.get("totalNurseryAllocBytes", 0)
                summary["memory_gc_pause_ns"] += ps.get("totalGcPauseNs", 0)
                summary["memory_fast_path_rate"] = max(
                    summary["memory_fast_path_rate"], ps.get("fastPathRate", 0)
                )
                summary["memory_methods_profiled"] += ps.get("methodCount", 0)
    return summary


def extract_benchmark_methods(chunks: dict, entry_maps: dict) -> dict:
    """Extract per-method benchmark data with name resolution."""
    benchmark_methods: dict[str, list] = {}
    for dll_name, slugs in chunks.items():
        dll_entry_map = entry_maps.get(dll_name, {})
        methods_list = []
        for slug, chunk_data in slugs.items():
            bench = chunk_data.get("benchmark", {})
            if bench and "error" not in bench and "results" in bench:
                chunk_entry_map = dll_entry_map.get(slug, {})
                for result in bench["results"]:
                    entry_idx = result.get("entryIndex")
                    resolved = chunk_entry_map.get(entry_idx, {})
                    methods_list.append({
                        "chunk_name": slug,
                        "method_name": resolved.get("method_name")
                                      or result.get("methodName")
                                      or result.get("name")
                                      or f"entry_{entry_idx}",
                        "type_name": resolved.get("type_name", ""),
                        "elapsed_ms": result.get("elapsedMilliseconds")
                                      or result.get("elapsedMs"),
                        "ops_per_sec": result.get("opsPerSecond"),
                        "memory_bytes": result.get("allocatedBytes")
                                        or result.get("memoryBytes"),
                    })
        if methods_list:
            methods_list.sort(key=lambda x: x.get("elapsed_ms") or 0, reverse=True)
            benchmark_methods[dll_name] = methods_list
    return benchmark_methods


def extract_coverage(aggregates: dict) -> dict:
    """Extract coverage audit data from aggregate reports."""
    coverage: dict[str, Any] = {}
    for dll_name, agg in aggregates.items():
        cov = agg.get("coverage-audit")
        if cov:
            coverage[dll_name] = cov
    return coverage


def extract_comparison(aggregates: dict) -> dict:
    """Extract benchmark comparison data from aggregate reports.

    comparison-summary.json structure:
      perChunk[].methods[].methodSubjectId, chaosAotMs, net8Ms, net10Ms,
      chaosAotVsNet8Pct, net10VsNet8Pct
    """
    comparison: dict[str, list] = {}
    for dll_name, agg in aggregates.items():
        comp = agg.get("comparison-summary")
        if comp:
            per_chunk = comp.get("perChunk", [])
            comparisons = []
            for chunk_entry in per_chunk:
                if not isinstance(chunk_entry, dict):
                    continue
                for method in chunk_entry.get("methods", []):
                    if not isinstance(method, dict):
                        continue
                    comparisons.append({
                        "method_name": method.get("methodSubjectId", "unknown"),
                        "chaos_aot_ms": method.get("chaosAotMs"),
                        "chaos_jit_ms": method.get("chaosJitMs"),
                        "dotnet_8_ms": method.get("net8Ms"),
                        "dotnet_10_ms": method.get("net10Ms"),
                        "chaos_aot_vs_net8_pct": method.get("chaosAotVsNet8Pct"),
                        "net10_vs_net8_pct": method.get("net10VsNet8Pct"),
                        "status": method.get("status", ""),
                        "bottleneck": method.get("bottleneck", ""),
                    })
            if comparisons:
                comparison[dll_name] = comparisons
    return comparison


# ── I/O ─────────────────────────────────────────────────────────────

def build_nightly_data(
    foundation_dir: Path,
    report_dir: Path,
    date_tag: str,
    run_tag: str,
) -> dict:
    """Build the nightly-data-*.json payload (backward-compatible format)."""
    assemblies = discover_assemblies(foundation_dir)
    print(f"  [publish] Discovered {len(assemblies)} assemblies")

    # Read chunk results from ReportCollector's per-chunk/ copies
    chunks = read_chunk_results(report_dir, assemblies)
    print(f"  [publish] Read chunk results for {len(chunks)} assemblies")

    # Read aggregate reports from ReportCollector's reports/ copies
    aggregates = read_aggregate_reports(report_dir, assemblies)
    print(f"  [publish] Read aggregate reports for {len(aggregates)} assemblies")

    # Parse entry.cpp for method resolution
    entry_maps = parse_entry_maps(foundation_dir, assemblies)

    # Compute summary
    summary = compute_summary(chunks)

    # Extract expanded data
    benchmark_methods = extract_benchmark_methods(chunks, entry_maps)
    coverage = extract_coverage(aggregates)
    comparison = extract_comparison(aggregates)

    # Build report in nightly-data-*.json format
    report: dict[str, Any] = {
        "date_tag": f"{date_tag}-{run_tag}",
        "total_dlls": len(assemblies),
        "dlls": {},
        "aggregate": {},
        "summary": summary,
        "entry_maps": entry_maps,
        "benchmark_methods": benchmark_methods,
        "coverage": coverage,
        "comparison": comparison,
    }

    for asm in assemblies:
        dll_data = {
            "chunks": chunks.get(asm, {}),
            "aggregate": aggregates.get(asm, {}),
        }
        report["dlls"][asm] = dll_data

    return report


def ingest_report_api(api_url: str, date_tag: str) -> bool:
    """POST /api/ingest to Report API."""
    ingest_url = f"{api_url.rstrip('/')}/api/ingest?date_tag={date_tag}"
    try:
        result = subprocess.run(
            ["curl", "-sf", "-X", "POST", ingest_url],
            capture_output=True, text=True, timeout=30,
        )
        if result.returncode == 0:
            print(f"  [publish] Report API ingest successful ({date_tag})")
            return True
        else:
            print(f"  [publish] WARNING: API ingest failed: {result.stderr.strip()}")
            return False
    except Exception as e:
        print(f"  [publish] WARNING: API ingest error: {e}")
        return False


def upload_to_minio(
    foundation_dir: Path,
    date_tag: str,
    minio_endpoint: str,
    nightly_data_path: Path,
) -> bool:
    """Upload artifacts to MinIO (nightly-raw bucket)."""
    mc_cmd = "mc" if os.name != "nt" else "mc.exe"
    try:
        subprocess.run(
            [mc_cmd, "alias", "set", "local", minio_endpoint,
             os.environ.get("MINIO_ACCESS_KEY", "minioadmin"),
             os.environ.get("MINIO_SECRET_KEY", "minioadmin")],
            capture_output=True, timeout=15,
        )
    except Exception:
        print("  [publish] WARNING: mc not available or MinIO unreachable, skipping upload")
        return False

    upload_count = 0
    # Upload per-assembly aggregate artifacts
    for dll_dir in sorted(foundation_dir.iterdir()):
        if not dll_dir.is_dir():
            continue
        dll = dll_dir.name
        reports_dir = dll_dir / "_dll" / "reports" / "latest"
        if not reports_dir.exists():
            continue
        for artifact in ["comparison-summary.json", "benchmark-summary.json",
                         "benchmark-full-report.json", "coverage-audit.json", "dashboard.json"]:
            ap = reports_dir / artifact
            if ap.exists():
                target = f"local/nightly-raw/{date_tag}/{dll}/{artifact}"
                try:
                    subprocess.run(
                        [mc_cmd, "cp", str(ap), target],
                        capture_output=True, timeout=30,
                    )
                    upload_count += 1
                except Exception:
                    pass

    # Upload aggregated nightly data
    if nightly_data_path.exists():
        target = f"local/nightly-raw/{date_tag}/_aggregated/nightly-data.json"
        try:
            subprocess.run(
                [mc_cmd, "cp", str(nightly_data_path), target],
                capture_output=True, timeout=30,
            )
            upload_count += 1
        except Exception:
            pass

    print(f"  [publish] Uploaded {upload_count} artifacts to MinIO")
    return True


def generate_html_report(
    data_path: Path,
    output_path: Path,
    build_number: str = "",
    baseline_path: Path | None = None,
) -> bool:
    """Call generate-nightly-report.py to produce HTML."""
    script = Path(__file__).parent / "generate-nightly-report.py"
    if not script.exists():
        print(f"  [publish] WARNING: {script} not found, skipping HTML generation")
        return False

    cmd = [sys.executable, str(script), "--data", str(data_path),
           "--output", str(output_path)]
    if build_number:
        cmd.extend(["--build-number", build_number])
    if baseline_path and baseline_path.exists():
        cmd.extend(["--baseline", str(baseline_path)])

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        if result.returncode == 0:
            print(f"  [publish] HTML report generated: {output_path}")
            return True
        else:
            print(f"  [publish] WARNING: HTML generation failed: {result.stderr.strip()[:200]}")
            return False
    except Exception as e:
        print(f"  [publish] WARNING: HTML generation error: {e}")
        return False


# ── Main ────────────────────────────────────────────────────────────

def main() -> int:
    parser = argparse.ArgumentParser(
        description="Publish nightly build results to CI infrastructure",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("--report-dir", required=True,
                        help="Path to ReportCollector output (e.g. artifacts/nightly-run/latest)")
    parser.add_argument("--foundation-dir", required=True,
                        help="Path to testing/foundation-dll/ (for entry.cpp)")
    parser.add_argument("--output-dir", required=True,
                        help="Output directory for nightly-data-*.json and HTML report")
    parser.add_argument("--date-tag", default=datetime.now().strftime("%Y%m%d"),
                        help="Date tag (YYYYMMDD)")
    parser.add_argument("--run-tag", default="",
                        help="Run tag (run1/run2), auto-detected from hour if empty")
    parser.add_argument("--build-number", default="",
                        help="Jenkins build number")
    parser.add_argument("--api-url", default=os.environ.get("REPORT_API_URL", "http://report-api:8000"),
                        help="Report API base URL")
    parser.add_argument("--minio-endpoint", default=os.environ.get("MINIO_ENDPOINT", "http://chaos-minio:9000"),
                        help="MinIO S3 endpoint")
    parser.add_argument("--report-server-dir",
                        default="/var/lib/report-server/daily",
                        help="Report server daily directory for nginx")
    parser.add_argument("--skip-ingest", action="store_true",
                        help="Skip Report API ingestion")
    parser.add_argument("--skip-minio", action="store_true",
                        help="Skip MinIO upload")
    parser.add_argument("--skip-html", action="store_true",
                        help="Skip HTML report generation")
    parser.add_argument("--baseline", default=None,
                        help="Path to previous nightly-data-*.json for baseline comparison")
    parser.add_argument("--verbose", "-v", action="store_true",
                        help="Verbose output")
    args = parser.parse_args()

    foundation_dir = Path(args.foundation_dir)
    report_dir = Path(args.report_dir)
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    # Auto-detect run tag
    run_tag = args.run_tag
    if not run_tag:
        current_hour = datetime.now().hour
        run_tag = "run1" if current_hour < 8 else "run2"

    date_tag_full = f"{args.date_tag}-{run_tag}"
    date_tag_clean = args.date_tag

    print(f"{'='*60}")
    print(f"  publish-nightly-results.py")
    print(f"{'='*60}")
    print(f"  Report dir:     {report_dir}")
    print(f"  Foundation dir: {foundation_dir}")
    print(f"  Output dir:     {output_dir}")
    print(f"  Date tag:       {date_tag_full}")
    print(f"  Build number:   {args.build_number or '(none)'}")

    # Verify report dir exists
    if not report_dir.exists():
        print(f"ERROR: Report directory not found: {report_dir}")
        return 1
    if not (report_dir / "per-chunk").exists():
        print(f"WARNING: {report_dir}/per-chunk/ not found — no chunk results?")

    # Step 1: Build nightly-data JSON
    print(f"\n  Phase 1: Building nightly-data...")
    nightly_data = build_nightly_data(foundation_dir, report_dir, args.date_tag, run_tag)

    data_path = output_dir / f"nightly-data-{date_tag_full}.json"
    data_path.write_text(
        json.dumps(nightly_data, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )
    summary = nightly_data["summary"]
    fact_pct = (summary["fact_passed"] / summary["fact_total"] * 100) if summary["fact_total"] > 0 else 0
    print(f"  [publish] Written: {data_path}")
    print(f"  [publish] {len(nightly_data['dlls'])} DLLs, "
          f"Fact: {summary['fact_passed']}/{summary['fact_total']} ({fact_pct:.1f}%), "
          f"BMK: {summary['benchmark_methods']} methods")

    # Step 2: Ingest into Report API
    if not args.skip_ingest:
        print(f"\n  Phase 2: Ingesting into Report API...")
        ingest_report_api(args.api_url, date_tag_clean)

    # Step 3: Upload to MinIO
    if not args.skip_minio:
        print(f"\n  Phase 3: Uploading to MinIO...")
        upload_to_minio(foundation_dir, date_tag_clean, args.minio_endpoint, data_path)

    # Step 4: Generate HTML report
    html_path = None
    if not args.skip_html:
        print(f"\n  Phase 4: Generating HTML report...")
        html_path = output_dir / f"nightly-report-{date_tag_full}.html"
        baseline = Path(args.baseline) if args.baseline else None
        generate_html_report(data_path, html_path, args.build_number, baseline)

    # Step 5: Copy to report server
    if args.report_server_dir:
        print(f"\n  Phase 5: Copying to report server...")
        report_server = Path(args.report_server_dir)
        report_server.mkdir(parents=True, exist_ok=True)
        try:
            # Copy nightly data JSON
            dest_data = report_server / f"nightly-data-{date_tag_clean}.json"
            import shutil
            shutil.copy2(str(data_path), str(dest_data))
            print(f"  [publish] Copied data → {dest_data}")

            # Copy HTML report
            if html_path and html_path.exists():
                dest_html = report_server / f"nightly-report-{date_tag_full}.html"
                shutil.copy2(str(html_path), str(dest_html))
                # Update latest symlink
                latest_link = report_server / "nightly-latest.html"
                if latest_link.exists() or latest_link.is_symlink():
                    latest_link.unlink()
                shutil.copy2(str(html_path), str(latest_link))
                print(f"  [publish] Copied report → {dest_html}")
                print(f"  [publish] Updated nightly-latest.html")
        except Exception as e:
            print(f"  [publish] WARNING: Copy to report server failed: {e}")

    print(f"\n{'='*60}")
    print(f"  Publish complete: {data_path}")
    print(f"{'='*60}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
