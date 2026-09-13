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
        --foundation-dir /home/debian/agent/booming-il2cpp/testing/foundation-dll \\
        --output-dir /workspace/artifacts \\
        --date-tag 20260622 \\
        [--run-tag run1] \\
        [--build-number 123] \\
        [--api-url http://report-api:8000] \\
        [--minio-endpoint http://chaos-minio:9000] \\
        [--report-server-dir /var/lib/report-server/daily] \\
        [--skip-ingest] [--skip-minio] [--skip-html] [--skip-report-server]
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


def latest_run_id(report_dir: Path) -> str:
    """Newest run id found under <report_dir>/run-state/.

    The CLI creates one run-state directory per invocation, named exactly
    `<run_id>`, so the newest one is this run. Used when --run-id is not given
    so the per-run summary can still be preferred over the shared file.

    Returns "" when there is no run-state tree (an older payload laid out
    differently, or a clean checkout); callers then fall back to the shared
    summary exactly as before.
    """
    for base in (report_dir, report_dir.parent):
        d = base / "run-state"
        if not d.is_dir():
            continue
        subdirs = [p for p in d.iterdir() if p.is_dir()]
        if not subdirs:
            continue
        # Run ids are "YYYYMMDD_HHMMSS-<sha>", so the name sorts chronologically.
        return max(subdirs, key=lambda p: p.name).name
    return ""


def read_nightly_summary(report_dir: Path, run_id: str = "") -> dict:
    """Read the Route-3 nightly CLI's authoritative summary JSON.

    `verification.nightly.aggregate.aggregate_reports()` writes ONLY
    `<report_dir>/summary/nightly-result.json` (+ nightly-summary.md).  It does
    NOT create `per-chunk/` or `reports/` — those were products of the legacy
    `nightly_runner.ReportCollector`, and this script was left reading them
    after that runner was removed.  Result: every metric below came out 0 while
    `total_dlls` looked correct (it is discovered from the foundation dir, not
    from this report), so the pipeline published a well-formed but EMPTY
    report.  This reader is now the primary source of truth.

    There is a second, older `summary/nightly-summary.md` schema
    (full-run/YYYYMMDD_HHMMSS-<sha>/summary/) emitted by the legacy reporting
    stack; it carries a different shape and a nightly-delta.json sibling.  It
    is handled by `parse_legacy_summary_md()` as a fallback.

    Path ambiguity: `aggregate_reports()` writes to `<config.report_dir>/summary/`,
    so the canonical `--report-dir` is the PARENT.  But the Jenkinsfile passes
    `.../nightly-build-report/summary` directly, which would double-append.  We
    accept either by checking both locations.

    PER-RUN PREFERENCE: `nightly-result.json` is a single shared file that every
    run overwrites on an agent that accumulates many of them, so reading it can
    return a DIFFERENT run's numbers. That is not hypothetical — build 277
    published 0/45 while its own run-state recorded 21 chunks passed, because
    another run had replaced the file. When the caller knows the run id we look
    for `run-<run_id>.json` first and only fall back to the shared name, so an
    old-style payload still publishes.
    """
    names: list[str] = []
    if run_id:
        names.append(f"run-{run_id}.json")
    names.append("nightly-result.json")
    candidates = [base / n for base in (report_dir, report_dir / "summary")
                  for n in names]
    result_file = next((c for c in candidates if c.exists()), None)
    if result_file is None:
        return {}
    per_run = bool(run_id) and result_file.name == f"run-{run_id}.json"
    try:
        data = json.loads(result_file.read_text(encoding="utf-8"))
    except Exception as e:
        print(f"  [publish] WARNING: failed to parse {result_file}: {e}")
        return {}
    if not isinstance(data, dict):
        print(f"  [publish] WARNING: {result_file} is not a JSON object")
        return {}

    # Refuse to publish a summary that belongs to a different run.
    #
    # The shared nightly-result.json is overwritten by whichever run aggregates
    # last, so reading it is only safe if its runId matches ours. Build 283 is
    # what makes this concrete: the windows run 20260913_035640-a9fa0def7 built
    # 22 chunks successfully, but a Ctrl-C killed it before it aggregated, so no
    # per-run summary existed. The publisher fell back to the shared file, which
    # held run 20260912_091611's result — and published 0/45 for a run that had
    # passed 22. It even printed a warning about it, then used the numbers
    # anyway.
    #
    # A wrong number that looks authoritative is worse than an admitted gap: it
    # is indistinguishable from a real 0/45, and it silently discards a
    # successful build. So on mismatch we return {} and let the caller report
    # "no data", which is the truth.
    if run_id and not per_run:
        theirs = data.get("runId", "")
        if theirs and theirs != run_id:
            print(f"  [publish] REFUSING {result_file.name}: it belongs to run "
                  f"{theirs}, not {run_id} — no per-run summary was written "
                  f"(the run may have been interrupted before aggregating). "
                  f"Reporting no data rather than another run's numbers.",
                  file=sys.stderr)
            return {}
        # Same run or no runId recorded: the shared file IS ours.
        print(f"  [publish] NOTE: no per-run summary file, but {result_file.name} "
              f"carries this run's id ({run_id}) — using it", file=sys.stderr)
    return data


def parse_legacy_summary_md(report_dir: Path) -> dict:
    """Best-effort parse of the LEGACY `nightly-summary.md` (old reporting stack).

    Shape (see full-run/<run-id>/summary/nightly-summary.md):
        | Assemblies | 28 |
        | Chunks | 54 / 71 verified |
        | Fact pass rate | 97.8%  |
        | Benchmark methods | 18291 |
        ### Build Failures ❌ (10)
        - System.Net.Sockets/global-ns (not_run)

    Only used when nightly-result.json is absent.  Returns a partial summary in
    the same key space as read_nightly_summary() so downstream code needs no
    branch; any field we cannot parse is simply left out.
    """
    md_file = next((c for c in (
        report_dir / "nightly-summary.md",
        report_dir / "summary" / "nightly-summary.md",
    ) if c.exists()), None)
    if md_file is None:
        return {}
    try:
        text = md_file.read_text(encoding="utf-8", errors="replace")
    except OSError as e:
        print(f"  [publish] WARNING: failed to read {md_file}: {e}")
        return {}

    def _metric(label: str):
        m = re.search(rf"^\|\s*{re.escape(label)}\s*\|\s*([^|]+?)\s*\|", text, re.M)
        return m.group(1).strip() if m else None

    out: dict[str, Any] = {"_source": "legacy-nightly-summary.md"}

    chunks_raw = _metric("Chunks")
    if chunks_raw:
        m = re.match(r"(\d+)\s*/\s*(\d+)", chunks_raw)
        if m:
            out["passed"] = int(m.group(1))
            out["total"] = int(m.group(2))
            out["failed"] = max(0, int(m.group(2)) - int(m.group(1)))

    if (asm_raw := _metric("Assemblies")):
        try:
            out["totalAssemblies"] = int(asm_raw)
        except ValueError:
            pass

    # Build-failure keys: "#### Build Failures ❌ (N)" then (usually after a
    # blank line) "- asm/chunk (reason)".  The list is terminated by the next
    # heading or a blank line followed by non-list content, so match the block
    # lazily and filter for "-" lines rather than assuming adjacency.
    m = re.search(r"^#+\s*Build Failures[^\n]*\n(.*?)(?=\n#|\Z)", text, re.M | re.S)
    if m:
        keys = []
        for line in m.group(1).splitlines():
            line = line.strip()
            if not line.startswith("-"):
                continue
            item = line.lstrip("-").strip()
            key = item.split(" (")[0].strip()
            if key:
                keys.append(key)
        if keys:
            out["failingChunks"] = keys
            out["byErrorClass"] = {"unknown": len(keys)}

    return out


def read_chunk_results(report_dir: Path, assemblies: list[str]) -> dict:
    """Read per-chunk results from ReportCollector's per-chunk/ directory.

    OPTIONAL ENRICHMENT: the Route-3 nightly CLI does not produce this tree, so
    an empty result is normal and no longer means "the run failed".  Kept so a
    future ReportCollector (or an externally-supplied results dir) still lights
    up the per-method benchmark tables.

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
            # Profile (memory).  Note the metrics live under profile.summary
            # (verified against real engine profile.json), and the aggregate
            # block is keyed by technology — see the fallback below.
            prof = chunk_data.get("profile", {})
            if prof and "error" not in prof:
                ps = prof.get("summary", prof)
                summary["memory_alloc_bytes"] += ps.get("totalNurseryAllocBytes", 0)
                summary["memory_gc_pause_ns"] += ps.get("totalGcPauseNs", 0)
                # Weighted mean, not max(): a max() reports the single best
                # chunk's rate and hides a regression in every other chunk.
                _mc = ps.get("methodCount", 0)
                _rate = ps.get("fastPathRate", 0)
                if _mc:
                    summary["_fp_weighted"] = summary.get("_fp_weighted", 0.0) + _rate * _mc
                summary["memory_methods_profiled"] += _mc

    _prof_total = summary.get("memory_methods_profiled", 0)
    if _prof_total:
        summary["memory_fast_path_rate"] = summary.pop("_fp_weighted", 0.0) / _prof_total
    summary.pop("_fp_weighted", None)
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

def merge_nightly_summary(summary: dict, nightly_summary: dict) -> dict:
    """Overlay the authoritative CLI summary onto the derived one.

    The CLI summary is chunk-level truth (how many chunks passed/failed and
    why).  The derived summary is method-level detail from per-chunk JSON, which
    is usually absent.  We keep both: chunk counts come from the CLI, and any
    method-level metric the CLI cannot know (benchmark methods, nursery bytes)
    survives from the derived value when it is non-zero.

    Also normalises the CLI's camelCase payload into the snake_case key space
    the rest of this script, the HTML generator, and the Report API all use.
    """
    if not nightly_summary:
        summary["summary_source"] = "derived-from-per-chunk"
        return summary

    total = nightly_summary.get("total")
    passed = nightly_summary.get("passed")
    if isinstance(total, int):
        summary["chunk_total"] = total
    if isinstance(passed, int):
        summary["chunk_passed"] = passed
    if isinstance(nightly_summary.get("failed"), int):
        summary["chunk_failed"] = nightly_summary["failed"]
    if isinstance(nightly_summary.get("stalled"), int):
        summary["chunk_stalled"] = nightly_summary["stalled"]

    # Error-class breakdown — the analysis dimension the old payload lacked
    # entirely (the "39 native-linker-error" figures in the handoff docs were
    # produced by hand-grepping logs).
    by_class = nightly_summary.get("byErrorClass")
    if isinstance(by_class, dict) and by_class:
        summary["error_classes"] = dict(sorted(by_class.items()))
        # Flatten the failure buckets into one lookup used by the HTML report.
        failing: dict[str, list[str]] = {}
        failing.setdefault("translation_defect", []).extend(
            nightly_summary.get("translationDefectFails", []) or [])
        failing.setdefault("infra", []).extend(
            nightly_summary.get("infraFails", []) or [])
        failing.setdefault("code_defect", []).extend(
            nightly_summary.get("codeDefectFails", []) or [])
        summary["failing_chunks"] = {k: v for k, v in failing.items() if v}

    if isinstance(nightly_summary.get("failingChunks"), list):
        summary.setdefault("failing_chunks", {})["unknown"] = \
            nightly_summary["failingChunks"]

    # data_dlls: how many assemblies actually produced data.  This was previously
    # absent from the payload while Jenkins and the Report API each recomputed it
    # — the Feishu card read the missing key and displayed "0/N" unconditionally.
    #
    # Semantics match the other two consumers (report-server/api/main.py and
    # generate-nightly-report.py): an assembly counts when it RAN (total > 0),
    # not when it passed.  Using `passed > 0` here would hide an assembly whose
    # every chunk failed — exactly the case an operator most needs to see.
    by_asm = nightly_summary.get("byAssembly")
    if isinstance(by_asm, dict) and by_asm:
        summary["by_assembly"] = by_asm
        summary["data_dlls"] = sum(
            1 for v in by_asm.values()
            if isinstance(v, dict) and v.get("total", 0) > 0
        )

    summary["summary_source"] = "nightly-result.json"
    return summary


def build_chunk_status(nightly_summary: dict, assemblies: list[str]) -> dict:
    """Per-assembly chunk rollup from the CLI summary, for the HTML table.

    `byAssembly` is {asm: {passed, failed, total}}; we convert it to the
    pass/total shape the report generator's fact column expects.
    """
    by_asm = (nightly_summary or {}).get("byAssembly")
    if not isinstance(by_asm, dict):
        return {}
    status: dict[str, Any] = {}
    for asm, v in by_asm.items():
        if not isinstance(v, dict):
            continue
        status[asm] = {
            "chunk_passed": v.get("passed", 0),
            "chunk_failed": v.get("failed", 0),
            "chunk_total": v.get("total", 0),
        }
    # Surface assemblies the foundation dir knows about but the run never
    # reached (e.g. filtered or crashed before scheduling) — otherwise they are
    # invisible in the report rather than shown as 0/N.
    for asm in assemblies:
        status.setdefault(asm, {"chunk_passed": 0, "chunk_failed": 0, "chunk_total": 0})
    return status


def build_nightly_data(
    foundation_dir: Path,
    report_dir: Path,
    date_tag: str,
    run_tag: str,
    build_number: str = "",
    engine_sha: str = "",
    platform: str = "",
    run_id: str = "",
) -> dict:
    """Build the nightly-data-*.json payload (backward-compatible format)."""
    assemblies = discover_assemblies(foundation_dir)
    print(f"  [publish] Discovered {len(assemblies)} assemblies")

    # ── PRIMARY SOURCE: the nightly CLI's own summary ──
    # Written by verification.nightly.aggregate.aggregate_reports() to
    # <report_dir>/summary/nightly-result.json.  Fall back to the legacy
    # markdown schema when it is absent (or empty, which the CLI can leave
    # behind when it dies before aggregation).
    # Resolve the run id: explicit flag wins, else discover it from run-state so
    # the per-run summary is preferred automatically. Without this the caller
    # would have to know a value that is only recorded inside the summary —
    # a chicken-and-egg that would leave the shared-file race in place.
    if not run_id:
        run_id = latest_run_id(report_dir)
        if run_id:
            print(f"  [publish] run id (from run-state): {run_id}")
    nightly_summary = read_nightly_summary(report_dir, run_id=run_id)
    summary_source = "nightly-result.json"
    if not nightly_summary:
        nightly_summary = parse_legacy_summary_md(report_dir)
        summary_source = ("legacy nightly-summary.md" if nightly_summary
                          else "NONE — metrics unavailable")
    print(f"  [publish] Summary source: {summary_source}")
    if nightly_summary:
        print(f"  [publish]   {nightly_summary.get('passed', 0)}/"
              f"{nightly_summary.get('total', 0)} chunks passed, "
              f"error classes: {nightly_summary.get('byErrorClass', {})}")

    # Read chunk results from ReportCollector's per-chunk/ copies.
    # NOTE: optional enrichment — the Route-3 CLI does not create this tree, so
    # an empty dict here is EXPECTED and is not a failure signal.
    chunks = read_chunk_results(report_dir, assemblies)
    if chunks:
        print(f"  [publish] Read chunk results for {len(chunks)} assemblies")
    else:
        print("  [publish] No per-chunk/ tree (expected for verification.nightly.cli)")

    # Read aggregate reports from ReportCollector's reports/ copies (also optional)
    aggregates = read_aggregate_reports(report_dir, assemblies)
    if aggregates:
        print(f"  [publish] Read aggregate reports for {len(aggregates)} assemblies")

    # Parse entry.cpp for method resolution
    entry_maps = parse_entry_maps(foundation_dir, assemblies)

    # Compute summary from the per-chunk tree (may be all zeros when absent) ...
    summary = compute_summary(chunks)
    # ... then let the authoritative CLI summary override it.
    summary = merge_nightly_summary(summary, nightly_summary)
    # The Report API reads build_number from summary (main.py upsert_report) but
    # nothing ever wrote it, so the DB column was always empty.
    summary["build_number"] = build_number

    # Extract expanded data
    benchmark_methods = extract_benchmark_methods(chunks, entry_maps)
    coverage = extract_coverage(aggregates)
    comparison = extract_comparison(aggregates)

    # Chunk-level pass/fail derived from the CLI summary (the only source of
    # truth available under the Route-3 CLI).  Consumed by the HTML report's
    # per-assembly table and by the error-class breakdown card.
    chunk_status = build_chunk_status(nightly_summary, assemblies)

    report: dict[str, Any] = {
        "date_tag": f"{date_tag}-{run_tag}",
        "total_dlls": len(assemblies),
        "dlls": {},
        "aggregate": {},
        "summary": summary,
        "chunk_status": chunk_status,
        "entry_maps": entry_maps,
        "benchmark_methods": benchmark_methods,
        "coverage": coverage,
        "comparison": comparison,
        "summary_source": summary_source,
    }

    # Provenance: which engine revision and platform produced this payload.
    # Without it, "20/45" cannot be tied to a commit, which is the first
    # question asked when a regression appears.
    #
    # The run_id's trailing hash is NOT reliably the engine revision: the
    # nightly CLI derives it from `git rev-parse --short HEAD` in the process
    # CWD. On the Linux branch that CWD is a `git archive` tree with no .git,
    # so git walks up and finds whatever repo happens to enclose the Jenkins
    # workspace — observed in build 267, where the Linux run_id carried the
    # NIGHTLY-TEST repo's hash (6e2049c) while the Windows one carried a real
    # engine commit (e3992ccc5). The two platforms therefore reported hashes
    # from different namespaces under the same field name, which defeats
    # cross-platform comparison.
    #
    # `engine_sha` is passed in explicitly by the caller (which knows the
    # engine tree) so the field means the same thing on both platforms; the
    # raw run_id is kept verbatim for traceability.
    report["provenance"] = {
        # Prefer the id we actually resolved (from run-state) over the one in
        # the payload: if we fell back to the shared file, its runId belongs to
        # whichever run wrote it last, and recording that would misattribute
        # this result.
        "run_id": run_id or nightly_summary.get("runId", ""),
        "engine_sha": engine_sha or "",
        "platform": platform,
        "native_config": nightly_summary.get("nativeConfig", ""),
        "timestamp": nightly_summary.get("timestamp"),
        "build_number": build_number,
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
    parser.add_argument("--engine-sha", default="",
                        help="The ENGINE revision this run built (not the CI repo "
                             "revision). Passed explicitly because the nightly CLI's "
                             "run_id hash is derived from git in its CWD, which is not "
                             "the engine on every platform.")
    parser.add_argument("--run-id", default="",
                        help="This run's nightly id (from the CLI's run_id / the "
                             "payload's provenance). Used to prefer the per-run "
                             "summary run-<id>.json over the shared "
                             "nightly-result.json, which any concurrent run can "
                             "overwrite.")
    parser.add_argument("--platform", default="",
                        help="linux | windows — recorded in provenance so the two "
                             "branches of the same night can be told apart.")
    parser.add_argument("--api-url", default=os.environ.get("REPORT_API_URL", "http://report-api:8000"),
                        help="Report API base URL")
    parser.add_argument("--minio-endpoint", default=os.environ.get("MINIO_ENDPOINT", "http://chaos-minio:9000"),
                        help="MinIO S3 endpoint")
    parser.add_argument("--report-server-dir",
                        default="/var/lib/report-server/daily",
                        help="Report server daily directory for nginx")
    parser.add_argument("--skip-report-server", action="store_true",
                        help="Skip copying into --report-server-dir. Use on any "
                             "platform that is not the report server: the default "
                             "is a Linux path, so on Windows this step creates a "
                             "bogus \\var\\lib\\... tree on the current drive and "
                             "still reports success.")
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
    # NOTE: the absence of per-chunk/ is NOT a problem under the Route-3 CLI —
    # it never creates that tree.  Only complain when we also have no summary,
    # i.e. when there is genuinely nothing to publish.
    if not (report_dir / "per-chunk").exists() and not read_nightly_summary(report_dir, run_id=args.run_id) \
            and not parse_legacy_summary_md(report_dir):
        print(f"WARNING: no per-chunk/ tree and no nightly-result.json under {report_dir} "
              f"— nothing to publish")

    # Step 1: Build nightly-data JSON
    print(f"\n  Phase 1: Building nightly-data...")
    nightly_data = build_nightly_data(foundation_dir, report_dir, args.date_tag,
                                     run_tag, args.build_number,
                                     engine_sha=args.engine_sha,
                                     platform=args.platform,
                                     run_id=args.run_id)

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
    if "chunk_passed" in summary:
        print(f"  [publish] Chunks: {summary['chunk_passed']}/{summary.get('chunk_total', 0)} passed, "
              f"{summary.get('chunk_failed', 0)} failed")
        if summary.get("error_classes"):
            classes = ", ".join(f"{k}={v}" for k, v in summary["error_classes"].items())
            print(f"  [publish] Error classes: {classes}")
    if summary.get("summary_source") == "derived-from-per-chunk":
        print("  [publish] WARNING: no nightly-result.json found — chunk metrics are "
              "derived from per-chunk data only and may be empty")

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
    if args.report_server_dir and not args.skip_report_server:
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
