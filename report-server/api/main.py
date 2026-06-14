"""
main.py — FastAPI application for nightly report server.

Endpoints:
    GET  /api/health
    GET  /api/reports                   — list all report summaries
    GET  /api/reports/{date_tag}        — single report with DLL breakdown
    GET  /api/trends                    — aggregate trends for charts
    GET  /api/compare?dates=a,b         — compare two dates side-by-side
    GET  /api/search?q=xxx              — search DLLs by name
    GET  /api/dll/{name}/trends         — single DLL history
    POST /api/ingest                    — ingest a data file into SQLite
    GET  /api/benchmark/{dll_name}/methods  — per-method benchmark data
    GET  /api/benchmark/methods/search      — search benchmark methods
    GET  /api/compare/deep              — deep comparison with per-method diff
    GET  /api/coverage                  — coverage audit data
    GET  /api/coverage/{date_tag}       — single-date coverage breakdown
    GET  /api/export/csv                — export data as CSV
    GET  /api/artifacts                 — list MinIO artifacts
    GET  /api/artifacts/{date_tag}/{dll_name}/{type} — serve raw artifact
"""

import csv
import io
import json
import math
import os
from datetime import datetime
from pathlib import Path

from fastapi import FastAPI, Query, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse, Response

import database as db

app = FastAPI(
    title="chaos-il2cpp Report API",
    version="1.0.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

REPORT_DATA_DIR = Path("/reports/daily")

# ── MinIO client (lazy init) ──────────────────────────────────────
_minio_client = None


def get_minio():
    global _minio_client
    if _minio_client is None:
        from minio import Minio
        endpoint = os.environ.get("MINIO_ENDPOINT", "http://chaos-minio:9000")
        access_key = os.environ.get("MINIO_ACCESS_KEY", "minioadmin")
        secret_key = os.environ.get("MINIO_SECRET_KEY", "minioadmin")
        # Strip http:// or https:// for minio client
        host = endpoint.replace("http://", "").replace("https://", "")
        _minio_client = Minio(
            host,
            access_key=access_key,
            secret_key=secret_key,
            secure=endpoint.startswith("https"),
        )
    return _minio_client


# ── Startup ──────────────────────────────────────────────────────
@app.on_event("startup")
def startup():
    db.init_db()


# ── Health ───────────────────────────────────────────────────────
@app.get("/api/health")
def health():
    return {"status": "ok", "time": datetime.now().isoformat()}


# ── List Reports ─────────────────────────────────────────────────
@app.get("/api/reports")
def list_reports(limit: int = Query(90, ge=1, le=365)):
    reports = db.get_all_reports(limit=limit)
    return {"reports": reports, "total": len(reports)}


# ── Single Report ────────────────────────────────────────────────
@app.get("/api/reports/{date_tag}")
def get_report(date_tag: str):
    summary = db.get_report(date_tag)
    if not summary:
        raise HTTPException(404, f"Report {date_tag} not found")

    # Also try to serve the raw data JSON
    data_file = REPORT_DATA_DIR / f"nightly-data-{date_tag}.json"
    data = {}
    if data_file.exists():
        data = json.loads(data_file.read_text(encoding="utf-8"))

    return {"summary": summary, "data": data}


# ── Aggregate Trends ─────────────────────────────────────────────
@app.get("/api/trends")
def get_trends(days: int = Query(90, ge=7, le=365)):
    rows = db.get_aggregate_trends(limit=days)
    for r in rows:
        t = r.get("fact_total", 0) or 1
        r["fact_pct"] = round(r["fact_passed"] / t * 100, 1)
        r["hotupdate_pct"] = (
            round(r["hotupdate_passed"] / r["hotupdate_total"] * 100, 1)
            if r.get("hotupdate_total", 0) > 0
            else None
        )
    return {"trends": rows}


# ── Compare Two Dates ────────────────────────────────────────────
@app.get("/api/compare")
def compare_dates(
    a: str = Query(..., description="First date tag e.g. 20260613"),
    b: str = Query(..., description="Second date tag e.g. 20260614"),
):
    result = db.compare_dates(a, b)
    if result is None:
        raise HTTPException(404, f"One or both dates not found: {a}, {b}")
    return result


# ── Search DLLs ──────────────────────────────────────────────────
@app.get("/api/search")
def search_dlls(q: str = Query("", min_length=1)):
    results = db.search_dlls(q)
    # Group by DLL name
    grouped: dict = {}
    for r in results:
        name = r["dll_name"]
        if name not in grouped:
            grouped[name] = []
        grouped[name].append({
            "date_tag": r["report_date"],
            "fact_passed": r["fact_passed"],
            "fact_total": r["fact_total"],
            "benchmark_methods": r["benchmark_methods"],
        })
    return {"query": q, "results": grouped}


# ── Single DLL Trend ─────────────────────────────────────────────
@app.get("/api/dll/{name}/trends")
def dll_trends(name: str, days: int = Query(30, ge=1, le=365)):
    rows = db.get_dll_trends(name, limit=days)
    for r in rows:
        t = r.get("fact_total", 0) or 1
        r["fact_pct"] = round(r["fact_passed"] / t * 100, 1)
    return {"dll_name": name, "trends": rows}


# ── Serve raw JSON data files ────────────────────────────────────
@app.get("/api/data/{date_tag}")
def serve_raw_data(date_tag: str):
    data_file = REPORT_DATA_DIR / f"nightly-data-{date_tag}.json"
    if not data_file.exists():
        raise HTTPException(404, f"Data file not found for {date_tag}")
    return FileResponse(str(data_file), media_type="application/json")


# ── Ingest Data File into SQLite ─────────────────────────────────
@app.post("/api/ingest")
def ingest_data(date_tag: str = Query(..., description="Date tag e.g. 20260614")):
    """Parse a nightly-data-<date_tag>.json and upsert into SQLite."""
    data_file = REPORT_DATA_DIR / f"nightly-data-{date_tag}.json"
    if not data_file.exists():
        raise HTTPException(404, f"Data file not found: {data_file}")

    try:
        data = json.loads(data_file.read_text(encoding="utf-8"))
    except Exception as e:
        raise HTTPException(400, f"Failed to parse data file: {e}")

    summary = data.get("summary", {})
    dlls = data.get("dlls", {})
    entry_maps = data.get("entry_maps", {})
    date_tag_val = data.get("date_tag", date_tag)

    # Build summary row
    has_data = sum(
        1 for v in dlls.values()
        if any(c.get("fact", {}).get("total", 0) > 0
               for c in v.get("chunks", {}).values())
    )

    db.upsert_report({
        "date_tag": date_tag_val,
        "build_number": str(summary.get("build_number", "")),
        "total_dlls": len(dlls),
        "data_dlls": has_data,
        "fact_passed": summary.get("fact_passed", 0),
        "fact_total": summary.get("fact_total", 0),
        "benchmark_methods": summary.get("benchmark_methods", 0),
        "hotupdate_passed": summary.get("hotupdate_passed", 0),
        "hotupdate_total": summary.get("hotupdate_total", 0),
        "memory_alloc_bytes": summary.get("memory_alloc_bytes", 0),
        "memory_gc_pause_ns": summary.get("memory_gc_pause_ns", 0),
        "memory_fast_path_rate": summary.get("memory_fast_path_rate", 0.0),
    })

    # Per-DLL rows
    for dll_name, dll_data in dlls.items():
        fact_p = sum(
            c.get("fact", {}).get("passed", 0)
            for c in dll_data.get("chunks", {}).values()
            if "fact" in c
        )
        fact_t = sum(
            c.get("fact", {}).get("total", 0)
            for c in dll_data.get("chunks", {}).values()
            if "fact" in c
        )
        bmk = sum(
            c.get("benchmark", {}).get("methodCount", 0)
            for c in dll_data.get("chunks", {}).values()
            if "benchmark" in c
        )
        hot_p = sum(
            c.get("hotupdate", {}).get("passCount", 0)
            for c in dll_data.get("chunks", {}).values()
            if "hotupdate" in c
        )
        hot_t = sum(
            c.get("hotupdate", {}).get("patchCount", 0)
            for c in dll_data.get("chunks", {}).values()
            if "hotupdate" in c
        )
        mem_alloc = sum(
            c.get("profile", {}).get("totalNurseryAllocBytes", 0)
            for c in dll_data.get("chunks", {}).values()
            if "profile" in c
        )
        mem_gc = sum(
            c.get("profile", {}).get("totalGcPauseNs", 0)
            for c in dll_data.get("chunks", {}).values()
            if "profile" in c
        )

        db.upsert_dll_results(date_tag_val, dll_name, {
            "fact_passed": fact_p,
            "fact_total": fact_t,
            "benchmark_methods": bmk,
            "hotupdate_passed": hot_p,
            "hotupdate_total": hot_t,
            "mem_alloc_bytes": mem_alloc,
            "mem_gc_pause_ns": mem_gc,
        })

        # Per-method benchmark data with entry_map name resolution
        dll_entry_map = entry_maps.get(dll_name, {})
        bm_methods = []
        for slug, chunk in dll_data.get("chunks", {}).items():
            bench = chunk.get("benchmark", {})
            if bench and "error" not in bench and "results" in bench:
                chunk_entry_map = dll_entry_map.get(slug, {})
                for result in bench["results"]:
                    entry_idx = result.get("entryIndex")
                    resolved = chunk_entry_map.get(str(entry_idx), {}) if entry_idx is not None else {}
                    bm_methods.append({
                        "chunk_name": slug,
                        "entry_index": entry_idx,
                        "method_name": resolved.get("method_name")
                            or result.get("methodName")
                            or result.get("name")
                            or f"entry_{entry_idx}",
                        "type_name": resolved.get("type_name", ""),
                        "elapsed_ms": result.get("elapsedMilliseconds") or result.get("elapsedMs"),
                        "ops_per_sec": result.get("opsPerSecond"),
                        "memory_bytes": result.get("allocatedBytes") or result.get("memoryBytes"),
                    })
        if bm_methods:
            bm_methods.sort(key=lambda x: x.get("elapsed_ms") or 0, reverse=True)
            db.upsert_benchmark_methods(date_tag_val, dll_name, bm_methods)

        # Chunk summaries from benchmark-summary.json aggregate
        agg = dll_data.get("aggregate", {})
        bench_summary = agg.get("benchmark-summary")
        if bench_summary and "chunkSummaries" in bench_summary:
            for cs in bench_summary["chunkSummaries"]:
                chunk_slug = cs.get("slug", "")
                bm = cs.get("benchmark", {}) or {}
                db.upsert_chunk_summary(date_tag_val, dll_name, chunk_slug, {
                    "methodCount": bm.get("methodCount", 0),
                    "meanDurationMs": bm.get("meanDurationMs"),
                    "meanOpsPerSec": bm.get("meanOpsPerSecond"),
                    "minDurationMs": bm.get("minDurationMs"),
                    "maxDurationMs": bm.get("maxDurationMs"),
                    "totalDurationMs": bm.get("totalDurationMs"),
                    "totalAllocatedBytes": bm.get("totalAllocatedBytes"),
                    "meanCv": bm.get("meanCv"),
                })

        # HotUpdate per-method data
        for slug, chunk in dll_data.get("chunks", {}).items():
            hot = chunk.get("hotupdate", {})
            if hot and "error" not in hot and "details" in hot:
                details = hot["details"]
                chunk_entry_map = dll_entry_map.get(slug, {})
                hu_methods = []
                # Collect all subject indices from baseline, patched, reverted
                seen_sis = set()
                for phase_key in ("baselineFact", "patchedFact", "revertedFact"):
                    phase_data = details.get(phase_key, [])
                    for entry in phase_data:
                        si = entry.get("si") or entry.get("subjectIndex")
                        if si is None:
                            continue
                        seen_sis.add(si)

                for si in sorted(seen_sis):
                    resolved = chunk_entry_map.get(str(si), {})

                    def find_phase(pk):
                        for e in details.get(pk, []):
                            if (e.get("si") or e.get("subjectIndex")) == si:
                                return e.get("passed")
                        return None

                    hu_methods.append({
                        "si": si,
                        "method_name": resolved.get("method_name", f"subject_{si}"),
                        "type_name": resolved.get("type_name", ""),
                        "assembly_name": resolved.get("assembly_name", ""),
                        "baseline_passed": find_phase("baselineFact"),
                        "patched_passed": find_phase("patchedFact"),
                        "reverted_passed": find_phase("revertedFact"),
                    })
                if hu_methods:
                    db.upsert_hotupdate_methods(date_tag_val, dll_name, slug, hu_methods)

        # Coverage data from aggregate (actual format: totalDeclaredMethods, totalChunks, chunksWithResults)
        coverage = agg.get("coverage-audit")
        if coverage:
            db.upsert_coverage(date_tag_val, dll_name, coverage)

        # Comparison data from aggregate (actual format: perChunk[].methods[].methodSubjectId)
        comparison_summary = agg.get("comparison-summary")
        if comparison_summary:
            comparisons = []
            for chunk_entry in comparison_summary.get("perChunk", []):
                for method in chunk_entry.get("methods", []):
                    comparisons.append({
                        "method_name": method.get("methodSubjectId", "unknown"),
                        "chaos_aot_ms": method.get("chaosAotMs"),
                        "dotnet_8_ms": method.get("net8Ms") or method.get("dotnet_8_ms"),
                        "dotnet_10_ms": method.get("net10Ms") or method.get("dotnet_10_ms"),
                        "speedup_vs_8": method.get("net10VsNet8Pct") or method.get("speedup_vs_8"),
                        "speedup_vs_10": method.get("speedup_vs_10"),
                    })
            if comparisons:
                db.upsert_benchmark_comparison(date_tag_val, dll_name, comparisons)

    return {
        "status": "ok",
        "date_tag": date_tag_val,
        "total_dlls": len(dlls),
        "data_dlls": has_data,
    }


# ═══════════════════════════════════════════════════════════════════
# NEW ENDPOINTS — Option C 全量数据湖
# ═══════════════════════════════════════════════════════════════════

# ── Per-Method Benchmark Data ─────────────────────────────────────
@app.get("/api/benchmark/{dll_name}/methods")
def get_benchmark_methods(
    dll_name: str,
    date_tag: str | None = Query(None, description="Filter by date tag"),
    limit: int = Query(50, ge=1, le=500),
    offset: int = Query(0, ge=0),
):
    rows = db.get_benchmark_methods(dll_name, date_tag, limit=limit, offset=offset)
    return {"dll_name": dll_name, "methods": rows, "total": len(rows)}


# ── Benchmark Drill-Down: Level 1 — DLL Summary ──────────────────
@app.get("/api/benchmark/dll-summary")
def benchmark_dll_summary(
    date_tag: str = Query(..., description="Date tag e.g. 20260614"),
):
    rows = db.get_dll_benchmark_summary(date_tag)
    return {"date_tag": date_tag, "dlls": rows, "total": len(rows)}


# ── Benchmark Drill-Down: Level 2 — Chunk Details ────────────────
@app.get("/api/benchmark/{dll}/chunks")
def benchmark_chunks(
    dll: str,
    date_tag: str = Query(..., description="Date tag e.g. 20260614"),
):
    rows = db.get_chunk_summaries(date_tag, dll)
    return {"date_tag": date_tag, "dll_name": dll, "chunks": rows, "total": len(rows)}


# ── Benchmark Drill-Down: Level 3 — Per-Method List ──────────────
@app.get("/api/benchmark/{dll}/{chunk}/methods")
def benchmark_chunk_methods(
    dll: str,
    chunk: str,
    date_tag: str | None = Query(None, description="Date tag e.g. 20260614"),
    limit: int = Query(100, ge=1, le=500),
    offset: int = Query(0, ge=0),
):
    rows = db.get_benchmark_methods(dll, date_tag, limit=limit, offset=offset)
    # Filter to only methods from this chunk
    chunk_rows = [r for r in rows if r.get("chunk_name") == chunk]
    return {"dll_name": dll, "chunk_name": chunk, "methods": chunk_rows, "total": len(chunk_rows)}


# ── HotUpdate Drill-Down: Level 1 — DLL Summary ──────────────────
@app.get("/api/hotupdate/dll-summary")
def hotupdate_dll_summary(
    date_tag: str = Query(..., description="Date tag e.g. 20260614"),
):
    rows = db.get_dll_hotupdate_summary(date_tag)
    return {"date_tag": date_tag, "dlls": rows, "total": len(rows)}


# ── HotUpdate Drill-Down: Level 2 — Chunk Details ────────────────
@app.get("/api/hotupdate/{dll}/chunks")
def hotupdate_chunks(
    dll: str,
    date_tag: str = Query(..., description="Date tag e.g. 20260614"),
):
    rows = db.get_chunk_summaries(date_tag, dll)
    hu_rows = [r for r in rows if (r.get("hu_passed", 0) + r.get("hu_failed", 0)) > 0]
    return {"date_tag": date_tag, "dll_name": dll, "chunks": hu_rows, "total": len(hu_rows)}


# ── HotUpdate Drill-Down: Level 3 — Per-Method Detail ────────────
@app.get("/api/hotupdate/{dll}/{chunk}/methods")
def hotupdate_chunk_methods(
    dll: str,
    chunk: str,
    date_tag: str = Query(..., description="Date tag e.g. 20260614"),
):
    rows = db.get_hotupdate_methods(date_tag, dll, chunk)
    return {"dll_name": dll, "chunk_name": chunk, "methods": rows, "total": len(rows)}


# ── Memory Drill-Down: Level 1 — DLL Summary ─────────────────────
@app.get("/api/memory/dll-summary")
def memory_dll_summary(
    date_tag: str = Query(..., description="Date tag e.g. 20260614"),
):
    rows = db.get_dll_memory_summary(date_tag)
    return {"date_tag": date_tag, "dlls": rows, "total": len(rows)}


# ── Search Benchmark Methods ──────────────────────────────────────
@app.get("/api/benchmark/methods/search")
def search_benchmark_methods(
    q: str = Query(..., min_length=1, description="Method name search"),
):
    results = db.search_benchmark_methods(q)
    return {"query": q, "results": results, "total": len(results)}


# ── Deep Comparison ───────────────────────────────────────────────
@app.get("/api/compare/deep")
def deep_compare(
    a: str = Query(..., description="First date tag e.g. 20260613"),
    b: str = Query(..., description="Second date tag e.g. 20260614"),
    dll: str | None = Query(None, description="Optional DLL name filter"),
):
    return db.compare_benchmark_methods_deep(a, b, dll_name=dll)


# ── Coverage Data ─────────────────────────────────────────────────
@app.get("/api/coverage")
def list_coverage():
    """Return coverage data across all dates."""
    rows = db.get_covered_instructions()
    return {"coverage": rows, "total": len(rows)}


@app.get("/api/coverage/{date_tag}")
def get_coverage(date_tag: str):
    """Return coverage breakdown for a specific date."""
    per_dll = db.get_covered_instructions(date_tag)
    aggregate = db.get_coverage_aggregate(date_tag)
    if not per_dll:
        raise HTTPException(404, f"No coverage data for {date_tag}")
    return {"date_tag": date_tag, "aggregate": aggregate, "per_dll": per_dll}


# ── CSV Export ────────────────────────────────────────────────────
@app.get("/api/export/csv")
def export_csv(
    type: str = Query(..., description="Data type: benchmark, coverage, compare"),
    date_tag: str | None = Query(None, description="Date filter"),
    dll: str | None = Query(None, description="DLL name filter"),
    a: str | None = Query(None, description="First date for compare export"),
    b: str | None = Query(None, description="Second date for compare export"),
):
    output = io.StringIO()
    writer = csv.writer(output)
    filename = f"{type}-export.csv"

    if type == "benchmark":
        writer.writerow(["date_tag", "dll_name", "chunk_name", "method_name",
                          "elapsed_ms", "ops_per_sec", "memory_bytes"])
        if dll:
            rows = db.get_benchmark_methods(dll, date_tag, limit=5000)
            for r in rows:
                writer.writerow([r["date_tag"], r["dll_name"], r["chunk_name"],
                                 r["method_name"], r["elapsed_ms"],
                                 r["ops_per_sec"], r["memory_bytes"]])
        else:
            # No DLL filter: search all (uses a broad wildcard)
            results = db.search_benchmark_methods("%", limit=5000)
            for r in results:
                writer.writerow([r["date_tag"], r["dll_name"], r["chunk_name"],
                                 r["method_name"], r["elapsed_ms"],
                                 r["ops_per_sec"], r["memory_bytes"]])

    elif type == "coverage":
        writer.writerow(["date_tag", "dll_name", "total_instructions",
                          "covered_instructions", "coverage_pct"])
        rows = db.get_covered_instructions(date_tag)
        for r in rows:
            writer.writerow([r["date_tag"], r["dll_name"],
                             r["total_instructions"], r["covered_instructions"],
                             r["coverage_pct"]])

    elif type == "compare" and a and b:
        writer.writerow(["dll_name", "chunk_name", "method_name",
                          f"{a}_elapsed_ms", f"{b}_elapsed_ms",
                          "diff_ms", "pct_change", "regression"])
        result = db.compare_benchmark_methods_deep(a, b, dll_name=dll)
        for d in result.get("diffs", []):
            writer.writerow([d["dll_name"], d["chunk_name"], d["method_name"],
                             d.get(f"{a}_elapsed_ms"), d.get(f"{b}_elapsed_ms"),
                             d["diff_ms"], d["pct_change"], d["regression"]])

    else:
        raise HTTPException(400, f"Invalid export type or missing parameters: {type}")

    return Response(
        content=output.getvalue(),
        media_type="text/csv",
        headers={"Content-Disposition": f"attachment; filename={filename}"},
    )


# ── MinIO Artifact Listing ───────────────────────────────────────
@app.get("/api/artifacts")
def list_artifacts(date_tag: str = Query(..., description="Date tag e.g. 20260614")):
    """List raw artifacts in MinIO for a given date."""
    try:
        client = get_minio()
    except Exception as e:
        raise HTTPException(503, f"MinIO not available: {e}")

    try:
        objects = client.list_objects("nightly-raw", prefix=f"{date_tag}/", recursive=True)
        artifacts = []
        for obj in objects:
            artifacts.append({
                "key": obj.object_name,
                "size": obj.size,
                "last_modified": obj.last_modified.isoformat() if obj.last_modified else None,
            })
        return {"date_tag": date_tag, "artifacts": artifacts, "total": len(artifacts)}
    except Exception as e:
        raise HTTPException(404, f"No artifacts found for {date_tag}: {e}")


# ── Serve Raw Artifact from MinIO ─────────────────────────────────
@app.get("/api/artifacts/{date_tag}/{dll_name}/{type}")
def serve_artifact(date_tag: str, dll_name: str, type: str):
    """Serve a raw artifact JSON from MinIO: comparison-summary, benchmark-summary, benchmark-full-report, coverage-audit, dashboard."""
    allowed_types = {
        "comparison-summary", "benchmark-summary",
        "benchmark-full-report", "coverage-audit", "dashboard",
    }
    if type not in allowed_types:
        raise HTTPException(400, f"Invalid type. Allowed: {', '.join(sorted(allowed_types))}")

    key = f"{date_tag}/{dll_name}/{type}.json"

    try:
        client = get_minio()
        response = client.get_object("nightly-raw", key)
        content = response.read()
        response.close()
        return JSONResponse(content=json.loads(content))
    except Exception as e:
        raise HTTPException(404, f"Artifact not found: {key} — {e}")
