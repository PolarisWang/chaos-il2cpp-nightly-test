"""
database.py — SQLite schema and operations for nightly report index.

Stores per-run summary, per-DLL metrics, per-method benchmark data,
coverage audit, and cross-technology benchmark comparisons so the API
can serve trend lines, deep comparisons, exports, and searches.
"""

import sqlite3
from pathlib import Path

DB_PATH = Path("/var/lib/report-server/db/report.db")


def get_db() -> sqlite3.Connection:
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(DB_PATH))
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


def init_db():
    conn = get_db()
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS reports (
            date_tag       TEXT PRIMARY KEY,
            build_number   TEXT DEFAULT '',
            total_dlls     INTEGER DEFAULT 0,
            data_dlls      INTEGER DEFAULT 0,
            fact_passed    INTEGER DEFAULT 0,
            fact_total     INTEGER DEFAULT 0,
            benchmark_methods   INTEGER DEFAULT 0,
            hotupdate_passed    INTEGER DEFAULT 0,
            hotupdate_total     INTEGER DEFAULT 0,
            memory_alloc_bytes  INTEGER DEFAULT 0,
            memory_gc_pause_ns  INTEGER DEFAULT 0,
            memory_fast_path_rate REAL DEFAULT 0.0,
            created_at     TEXT DEFAULT (datetime('now'))
        );

        CREATE TABLE IF NOT EXISTS dll_results (
            id             INTEGER PRIMARY KEY AUTOINCREMENT,
            report_date    TEXT NOT NULL,
            dll_name       TEXT NOT NULL,
            fact_passed    INTEGER DEFAULT 0,
            fact_total     INTEGER DEFAULT 0,
            benchmark_methods   INTEGER DEFAULT 0,
            hotupdate_passed    INTEGER DEFAULT 0,
            hotupdate_total     INTEGER DEFAULT 0,
            memory_alloc_bytes  INTEGER DEFAULT 0,
            memory_gc_pause_ns  INTEGER DEFAULT 0,
            FOREIGN KEY (report_date) REFERENCES reports(date_tag)
        );

        CREATE TABLE IF NOT EXISTS benchmark_methods (
            id             INTEGER PRIMARY KEY AUTOINCREMENT,
            date_tag       TEXT NOT NULL,
            dll_name       TEXT NOT NULL,
            chunk_name     TEXT NOT NULL,
            method_name    TEXT NOT NULL,
            type_name      TEXT DEFAULT '',
            elapsed_ms     REAL,
            ops_per_sec    REAL,
            memory_bytes   INTEGER,
            UNIQUE(date_tag, dll_name, chunk_name, method_name)
        );

        CREATE TABLE IF NOT EXISTS coverage_audit (
            id                  INTEGER PRIMARY KEY AUTOINCREMENT,
            date_tag            TEXT NOT NULL,
            dll_name            TEXT NOT NULL,
            total_instructions  INTEGER,
            covered_instructions INTEGER,
            coverage_pct        REAL,
            UNIQUE(date_tag, dll_name)
        );

        CREATE TABLE IF NOT EXISTS benchmark_comparison (
            id             INTEGER PRIMARY KEY AUTOINCREMENT,
            date_tag       TEXT NOT NULL,
            dll_name       TEXT NOT NULL,
            method_name    TEXT NOT NULL,
            chaos_aot_ms   REAL,
            dotnet_8_ms    REAL,
            dotnet_10_ms   REAL,
            speedup_vs_8   REAL,
            speedup_vs_10  REAL,
            UNIQUE(date_tag, dll_name, method_name)
        );

        CREATE INDEX IF NOT EXISTS idx_dll_report_date ON dll_results(report_date);
        CREATE INDEX IF NOT EXISTS idx_dll_name ON dll_results(dll_name);
        CREATE INDEX IF NOT EXISTS idx_bm_date_dll ON benchmark_methods(date_tag, dll_name);
        CREATE INDEX IF NOT EXISTS idx_bm_method ON benchmark_methods(method_name);
        CREATE INDEX IF NOT EXISTS idx_cov_date ON coverage_audit(date_tag);
        CREATE INDEX IF NOT EXISTS idx_bc_date_dll ON benchmark_comparison(date_tag, dll_name);

        CREATE TABLE IF NOT EXISTS chunk_summaries (
            id             INTEGER PRIMARY KEY AUTOINCREMENT,
            date_tag       TEXT NOT NULL,
            dll_name       TEXT NOT NULL,
            chunk_name     TEXT NOT NULL,
            bm_method_count    INTEGER DEFAULT 0,
            bm_mean_duration_ms REAL,
            bm_mean_ops_per_sec REAL,
            bm_min_duration_ms  REAL,
            bm_max_duration_ms  REAL,
            bm_total_duration_ms REAL,
            bm_total_allocated_bytes REAL,
            bm_mean_cv          REAL,
            hu_passed       INTEGER DEFAULT 0,
            hu_failed       INTEGER DEFAULT 0,
            hu_all_semantic INTEGER DEFAULT 0,
            hu_all_revert   INTEGER DEFAULT 0,
            hu_patch_failed INTEGER DEFAULT 0,
            mem_methods_profiled   INTEGER DEFAULT 0,
            mem_total_nursery_alloc_bytes INTEGER DEFAULT 0,
            mem_total_gc_pause_ns   INTEGER DEFAULT 0,
            mem_fast_path_rate     REAL DEFAULT 0.0,
            mem_total_alloc_bytes  INTEGER DEFAULT 0,
            created_at     TEXT DEFAULT (datetime('now')),
            UNIQUE(date_tag, dll_name, chunk_name)
        );

        CREATE TABLE IF NOT EXISTS hotupdate_methods (
            id             INTEGER PRIMARY KEY AUTOINCREMENT,
            date_tag       TEXT NOT NULL,
            dll_name       TEXT NOT NULL,
            chunk_name     TEXT NOT NULL,
            subject_index  INTEGER NOT NULL,
            method_name    TEXT NOT NULL,
            type_name      TEXT DEFAULT '',
            assembly_name  TEXT DEFAULT '',
            baseline_passed INTEGER,
            patched_passed  INTEGER,
            reverted_passed INTEGER,
            UNIQUE(date_tag, dll_name, chunk_name, subject_index)
        );

        CREATE INDEX IF NOT EXISTS idx_cs_date_dll ON chunk_summaries(date_tag, dll_name);
        CREATE INDEX IF NOT EXISTS idx_cs_date ON chunk_summaries(date_tag);
        CREATE INDEX IF NOT EXISTS idx_hu_date_dll ON hotupdate_methods(date_tag, dll_name);
        CREATE INDEX IF NOT EXISTS idx_hu_method ON hotupdate_methods(method_name);
    """)
    conn.commit()
    conn.close()


def upsert_report(summary: dict) -> None:
    """Insert or replace a nightly summary row."""
    conn = get_db()
    conn.execute("""
        INSERT OR REPLACE INTO reports
            (date_tag, build_number, total_dlls, data_dlls,
             fact_passed, fact_total, benchmark_methods,
             hotupdate_passed, hotupdate_total,
             memory_alloc_bytes, memory_gc_pause_ns, memory_fast_path_rate)
        VALUES (?,?,?,?, ?,?,?, ?,?,?, ?,?)
    """, (
        summary["date_tag"],
        summary.get("build_number", ""),
        summary.get("total_dlls", 0),
        summary.get("data_dlls", 0),
        summary.get("fact_passed", 0),
        summary.get("fact_total", 0),
        summary.get("benchmark_methods", 0),
        summary.get("hotupdate_passed", 0),
        summary.get("hotupdate_total", 0),
        summary.get("memory_alloc_bytes", 0),
        summary.get("memory_gc_pause_ns", 0),
        summary.get("memory_fast_path_rate", 0.0),
    ))
    conn.commit()
    conn.close()


def upsert_dll_results(date_tag: str, dll_name: str, metrics: dict) -> None:
    """Insert per-DLL metrics for a given report date."""
    conn = get_db()
    conn.execute("""
        INSERT OR REPLACE INTO dll_results
            (report_date, dll_name,
             fact_passed, fact_total, benchmark_methods,
             hotupdate_passed, hotupdate_total,
             memory_alloc_bytes, memory_gc_pause_ns)
        VALUES (?,?, ?,?,?, ?,?, ?,?)
    """, (
        date_tag, dll_name,
        metrics.get("fact_passed", 0),
        metrics.get("fact_total", 0),
        metrics.get("benchmark_methods", 0),
        metrics.get("hotupdate_passed", 0),
        metrics.get("hotupdate_total", 0),
        metrics.get("mem_alloc_bytes", 0),
        metrics.get("mem_gc_pause_ns", 0),
    ))
    conn.commit()
    conn.close()


def upsert_benchmark_methods(date_tag: str, dll_name: str, methods: list) -> None:
    """Batch insert per-method benchmark results.

    Each dict in *methods* should have keys:
        chunk_name, method_name, elapsed_ms, ops_per_sec, memory_bytes
    """
    conn = get_db()
    conn.executemany("""
        INSERT OR REPLACE INTO benchmark_methods
            (date_tag, dll_name, chunk_name, entry_index, method_name, type_name, elapsed_ms, ops_per_sec, memory_bytes)
        VALUES (?,?,?,?, ?,?,?,?,?)
    """, [
        (date_tag, dll_name, m.get("chunk_name", ""),
         m.get("entry_index", -1),
         m["method_name"], m.get("type_name", ""),
         m.get("elapsed_ms"),
         m.get("ops_per_sec"), m.get("memory_bytes"))
        for m in methods
    ])
    conn.commit()
    conn.close()


def upsert_coverage(date_tag: str, dll_name: str, data: dict) -> None:
    """Upsert coverage audit for a DLL.

    Handles the actual coverage-audit.json format:
        totalDeclaredMethods, totalChunks, chunksWithResults
    """
    conn = get_db()
    conn.execute("""
        INSERT OR REPLACE INTO coverage_audit
            (date_tag, dll_name, total_instructions, covered_instructions, coverage_pct)
        VALUES (?,?,?,?,?)
    """, (
        date_tag, dll_name,
        data.get("totalDeclaredMethods", 0),
        data.get("chunksWithResults", 0),
        round(data.get("chunksWithResults", 0) / max(data.get("totalChunks", 1), 1) * 100, 2),
    ))
    conn.commit()
    conn.close()


def upsert_chunk_summary(date_tag: str, dll_name: str, chunk_name: str, metrics: dict) -> None:
    """Insert or update per-chunk aggregate metrics from benchmark-summary."""
    conn = get_db()
    conn.execute("""
        INSERT OR REPLACE INTO chunk_summaries
            (date_tag, dll_name, chunk_name,
             bm_method_count, bm_mean_duration_ms, bm_mean_ops_per_sec,
             bm_min_duration_ms, bm_max_duration_ms,
             bm_total_duration_ms, bm_total_allocated_bytes, bm_mean_cv,
             hu_passed, hu_failed, hu_all_semantic, hu_all_revert, hu_patch_failed,
             mem_methods_profiled, mem_total_nursery_alloc_bytes,
             mem_total_gc_pause_ns, mem_fast_path_rate, mem_total_alloc_bytes)
        VALUES (?,?,?,
                ?,?,?,
                ?,?,
                ?,?,?,
                ?,?,?,?,?,
                ?,?,
                ?,?,?)
    """, (
        date_tag, dll_name, chunk_name,
        metrics.get("methodCount", 0),
        metrics.get("meanDurationMs"),
        metrics.get("meanOpsPerSec"),
        metrics.get("minDurationMs"),
        metrics.get("maxDurationMs"),
        metrics.get("totalDurationMs"),
        metrics.get("totalAllocatedBytes"),
        metrics.get("meanCv"),
        metrics.get("hu_passed", 0),
        metrics.get("hu_failed", 0),
        metrics.get("hu_all_semantic", 0),
        metrics.get("hu_all_revert", 0),
        metrics.get("hu_patch_failed", 0),
        metrics.get("mem_methods_profiled", 0),
        metrics.get("mem_total_nursery_alloc_bytes", 0),
        metrics.get("mem_total_gc_pause_ns", 0),
        metrics.get("mem_fast_path_rate", 0.0),
        metrics.get("mem_total_alloc_bytes", 0),
    ))
    conn.commit()
    conn.close()


def get_chunk_summaries(date_tag: str, dll_name: str) -> list[dict]:
    """Return per-chunk summaries for a DLL on a given date."""
    conn = get_db()
    rows = conn.execute("""
        SELECT * FROM chunk_summaries
        WHERE date_tag = ? AND dll_name = ?
        ORDER BY chunk_name
    """, (date_tag, dll_name)).fetchall()
    conn.close()
    return [dict(r) for r in rows]


def upsert_hotupdate_methods(date_tag: str, dll_name: str, chunk_name: str,
                              methods: list, entry_map: dict | None = None) -> None:
    """Batch insert per-method hotupdate results.

    Each dict in *methods* should have keys:
        si, method_name, type_name, assembly_name,
        baseline_passed, patched_passed, reverted_passed
    """
    conn = get_db()
    conn.executemany("""
        INSERT OR REPLACE INTO hotupdate_methods
            (date_tag, dll_name, chunk_name, subject_index,
             method_name, type_name, assembly_name,
             baseline_passed, patched_passed, reverted_passed)
        VALUES (?,?,?,?,
                ?,?,?,
                ?,?,?)
    """, [
        (date_tag, dll_name, chunk_name, m.get("si", 0),
         m.get("method_name", ""),
         m.get("type_name", ""),
         m.get("assembly_name", ""),
         m.get("baseline_passed"),
         m.get("patched_passed"),
         m.get("reverted_passed"))
        for m in methods
    ])
    conn.commit()
    conn.close()


def get_hotupdate_methods(date_tag: str, dll_name: str, chunk_name: str | None = None) -> list[dict]:
    """Return per-method hotupdate results for a DLL, optionally filtered by chunk."""
    conn = get_db()
    if chunk_name:
        rows = conn.execute("""
            SELECT * FROM hotupdate_methods
            WHERE date_tag = ? AND dll_name = ? AND chunk_name = ?
            ORDER BY subject_index
        """, (date_tag, dll_name, chunk_name)).fetchall()
    else:
        rows = conn.execute("""
            SELECT * FROM hotupdate_methods
            WHERE date_tag = ? AND dll_name = ?
            ORDER BY chunk_name, subject_index
        """, (date_tag, dll_name)).fetchall()
    conn.close()
    return [dict(r) for r in rows]


def get_dll_benchmark_summary(date_tag: str) -> list[dict]:
    """Return per-DLL benchmark summary aggregated from chunk_summaries."""
    conn = get_db()
    rows = conn.execute("""
        SELECT
            dll_name,
            SUM(bm_method_count) AS total_methods,
            AVG(bm_mean_duration_ms) AS avg_duration_ms,
            SUM(bm_total_duration_ms) AS total_duration_ms,
            SUM(bm_total_allocated_bytes) AS total_allocated_bytes
        FROM chunk_summaries
        WHERE date_tag = ? AND bm_method_count > 0
        GROUP BY dll_name
        ORDER BY total_methods DESC
    """, (date_tag,)).fetchall()
    conn.close()
    return [dict(r) for r in rows]


def get_dll_hotupdate_summary(date_tag: str) -> list[dict]:
    """Return per-DLL hotupdate summary aggregated from chunk_summaries."""
    conn = get_db()
    rows = conn.execute("""
        SELECT
            dll_name,
            SUM(hu_passed) AS total_passed,
            SUM(hu_passed + hu_failed) AS total_tests,
            SUM(hu_all_semantic) AS all_semantic,
            SUM(hu_all_revert) AS all_revert
        FROM chunk_summaries
        WHERE date_tag = ? AND (hu_passed + hu_failed) > 0
        GROUP BY dll_name
        ORDER BY total_passed DESC
    """, (date_tag,)).fetchall()
    conn.close()
    return [dict(r) for r in rows]


def get_dll_memory_summary(date_tag: str) -> list[dict]:
    """Return per-DLL memory summary aggregated from chunk_summaries."""
    conn = get_db()
    rows = conn.execute("""
        SELECT
            dll_name,
            SUM(mem_methods_profiled) AS total_methods,
            SUM(mem_total_nursery_alloc_bytes) AS total_nursery_alloc,
            SUM(mem_total_gc_pause_ns) AS total_gc_pause_ns,
            AVG(mem_fast_path_rate) AS avg_fast_path_rate,
            SUM(mem_total_alloc_bytes) AS total_alloc_bytes
        FROM chunk_summaries
        WHERE date_tag = ? AND mem_methods_profiled > 0
        GROUP BY dll_name
        ORDER BY total_methods DESC
    """, (date_tag,)).fetchall()
    conn.close()
    return [dict(r) for r in rows]


def upsert_benchmark_comparison(date_tag: str, dll_name: str, comparisons: list) -> None:
    """Batch insert per-method cross-technology benchmark comparison.

    Each dict in *comparisons* should have keys:
        method_name, chaos_aot_ms, dotnet_8_ms, dotnet_10_ms, speedup_vs_8, speedup_vs_10
    """
    conn = get_db()
    conn.executemany("""
        INSERT OR REPLACE INTO benchmark_comparison
            (date_tag, dll_name, method_name, chaos_aot_ms, dotnet_8_ms, dotnet_10_ms, speedup_vs_8, speedup_vs_10)
        VALUES (?,?,?,?, ?,?,?,?)
    """, [
        (date_tag, dll_name, c["method_name"],
         c.get("chaos_aot_ms"), c.get("dotnet_8_ms"), c.get("dotnet_10_ms"),
         c.get("speedup_vs_8"), c.get("speedup_vs_10"))
        for c in comparisons
    ])
    conn.commit()
    conn.close()


def get_all_reports(limit: int = 90) -> list[dict]:
    """Return most recent report summaries."""
    conn = get_db()
    rows = conn.execute(
        "SELECT * FROM reports ORDER BY date_tag DESC LIMIT ?", (limit,)
    ).fetchall()
    conn.close()
    return [dict(r) for r in rows]


def get_report(date_tag: str) -> dict | None:
    """Return a single report summary."""
    conn = get_db()
    row = conn.execute(
        "SELECT * FROM reports WHERE date_tag = ?", (date_tag,)
    ).fetchone()
    conn.close()
    return dict(row) if row else None


def get_dll_trends(dll_name: str, limit: int = 30) -> list[dict]:
    """Return historical metrics for a specific DLL."""
    conn = get_db()
    rows = conn.execute("""
        SELECT r.date_tag, d.*
        FROM dll_results d
        JOIN reports r ON r.date_tag = d.report_date
        WHERE d.dll_name = ?
        ORDER BY r.date_tag DESC
        LIMIT ?
    """, (dll_name, limit)).fetchall()
    conn.close()
    return [dict(r) for r in rows]


def get_aggregate_trends(limit: int = 90) -> list[dict]:
    """Return high-level trend data for charting."""
    conn = get_db()
    rows = conn.execute("""
        SELECT date_tag, fact_passed, fact_total, benchmark_methods,
               hotupdate_passed, hotupdate_total,
               memory_alloc_bytes, memory_gc_pause_ns, memory_fast_path_rate,
               total_dlls, data_dlls
        FROM reports
        ORDER BY date_tag ASC
        LIMIT ?
    """, (limit,)).fetchall()
    conn.close()
    return [dict(r) for r in rows]


def search_dlls(query: str) -> list[dict]:
    """Search DLL results across all reports."""
    conn = get_db()
    pattern = f"%{query}%"
    rows = conn.execute("""
        SELECT r.date_tag, d.*
        FROM dll_results d
        JOIN reports r ON r.date_tag = d.report_date
        WHERE d.dll_name LIKE ?
        ORDER BY r.date_tag DESC
        LIMIT 50
    """, (pattern,)).fetchall()
    conn.close()
    return [dict(r) for r in rows]


def compare_dates(date_a: str, date_b: str) -> dict | None:
    """Return side-by-side comparison of two dates."""
    ra = get_report(date_a)
    rb = get_report(date_b)
    if not ra or not rb:
        return None
    conn = get_db()
    dlls_a = {
        r["dll_name"]: dict(r)
        for r in conn.execute(
            "SELECT * FROM dll_results WHERE report_date = ?", (date_a,)
        ).fetchall()
    }
    dlls_b = {
        r["dll_name"]: dict(r)
        for r in conn.execute(
            "SELECT * FROM dll_results WHERE report_date = ?", (date_b,)
        ).fetchall()
    }
    conn.close()
    return {"report_a": ra, "report_b": rb, "dlls_a": dlls_a, "dlls_b": dlls_b}


# ── New Accessors for Expanded Schema ──────────────────────────────

def get_benchmark_methods(dll_name: str, date_tag: str | None = None,
                          limit: int = 50, offset: int = 0) -> list[dict]:
    """Return per-method benchmark data for a DLL, optionally filtered by date."""
    conn = get_db()
    if date_tag:
        rows = conn.execute("""
            SELECT * FROM benchmark_methods
            WHERE dll_name = ? AND date_tag = ?
            ORDER BY elapsed_ms DESC
            LIMIT ? OFFSET ?
        """, (dll_name, date_tag, limit, offset)).fetchall()
    else:
        rows = conn.execute("""
            SELECT * FROM benchmark_methods
            WHERE dll_name = ?
            ORDER BY date_tag DESC, elapsed_ms DESC
            LIMIT ? OFFSET ?
        """, (dll_name, limit, offset)).fetchall()
    conn.close()
    return [dict(r) for r in rows]


def get_benchmark_comparison(date_tag: str, dll_name: str) -> list[dict]:
    """Return per-method comparison data for a DLL on a given date."""
    conn = get_db()
    rows = conn.execute("""
        SELECT * FROM benchmark_comparison
        WHERE date_tag = ? AND dll_name = ?
        ORDER BY method_name
    """, (date_tag, dll_name)).fetchall()
    conn.close()
    return [dict(r) for r in rows]


def search_benchmark_methods(query: str, limit: int = 50) -> list[dict]:
    """Search benchmark methods by name across all DLLs and dates."""
    conn = get_db()
    pattern = f"%{query}%"
    rows = conn.execute("""
        SELECT bm.*, r.build_number
        FROM benchmark_methods bm
        JOIN reports r ON r.date_tag = bm.date_tag
        WHERE bm.method_name LIKE ?
        ORDER BY bm.date_tag DESC, bm.elapsed_ms DESC
        LIMIT ?
    """, (pattern, limit)).fetchall()
    conn.close()
    return [dict(r) for r in rows]


def get_covered_instructions(date_tag: str | None = None) -> list[dict]:
    """Return coverage data, optionally filtered by date."""
    conn = get_db()
    if date_tag:
        rows = conn.execute("""
            SELECT * FROM coverage_audit
            WHERE date_tag = ?
            ORDER BY dll_name
        """, (date_tag,)).fetchall()
    else:
        rows = conn.execute("""
            SELECT ca.*, r.build_number
            FROM coverage_audit ca
            JOIN reports r ON r.date_tag = ca.date_tag
            ORDER BY ca.date_tag DESC, ca.dll_name
        """).fetchall()
    conn.close()
    return [dict(r) for r in rows]


def get_coverage_aggregate(date_tag: str) -> dict | None:
    """Return aggregate coverage across all DLLs for a given date."""
    conn = get_db()
    row = conn.execute("""
        SELECT
            SUM(total_instructions) AS total_instructions,
            SUM(covered_instructions) AS covered_instructions,
            CASE WHEN SUM(total_instructions) > 0
                THEN ROUND(CAST(SUM(covered_instructions) AS REAL) / SUM(total_instructions) * 100, 2)
                ELSE 0
            END AS coverage_pct
        FROM coverage_audit
        WHERE date_tag = ?
    """, (date_tag,)).fetchone()
    conn.close()
    return dict(row) if row else None


def compare_benchmark_methods_deep(date_a: str, date_b: str, dll_name: str | None = None) -> dict:
    """Deep comparison of per-method benchmark data between two dates."""
    conn = get_db()
    query = """
        SELECT date_tag, dll_name, chunk_name, method_name, elapsed_ms, ops_per_sec
        FROM benchmark_methods
        WHERE date_tag IN (?, ?)
    """
    params: list = [date_a, date_b]
    if dll_name:
        query += " AND dll_name = ?"
        params.append(dll_name)
    query += " ORDER BY method_name, date_tag"
    rows = conn.execute(query, params).fetchall()
    conn.close()

    # Group by method name
    methods: dict = {}
    for r in rows:
        d = dict(r)
        key = (d["dll_name"], d["chunk_name"], d["method_name"])
        if key not in methods:
            methods[key] = {}
        methods[key][d["date_tag"]] = d

    # Diff
    diffs = []
    for key, dates in methods.items():
        a_data = dates.get(date_a)
        b_data = dates.get(date_b)
        if a_data and b_data:
            elapsed_diff = (b_data["elapsed_ms"] - a_data["elapsed_ms"]) if (a_data["elapsed_ms"] is not None and b_data["elapsed_ms"] is not None) else None
            pct_change = (elapsed_diff / a_data["elapsed_ms"] * 100) if (elapsed_diff is not None and a_data["elapsed_ms"] and a_data["elapsed_ms"] > 0) else None
            diffs.append({
                "dll_name": key[0],
                "chunk_name": key[1],
                "method_name": key[2],
                f"{date_a}_elapsed_ms": a_data["elapsed_ms"],
                f"{date_b}_elapsed_ms": b_data["elapsed_ms"],
                "diff_ms": round(elapsed_diff, 3) if elapsed_diff is not None else None,
                "pct_change": round(pct_change, 2) if pct_change is not None else None,
                "regression": pct_change > 5 if pct_change is not None else None,
            })

    return {
        "date_a": date_a,
        "date_b": date_b,
        "total_methods": len(methods),
        "compared": len(diffs),
        "regressions": sum(1 for d in diffs if d.get("regression")),
        "improvements": sum(1 for d in diffs if d.get("pct_change") is not None and d["pct_change"] < -5),
        "diffs": diffs,
    }
