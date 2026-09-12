#!/usr/bin/env python3
"""test-publish-nightly.py — self-test for the nightly publish chain.

Covers the v4 fixes:
  - read_nightly_summary()      primary source + both report_dir layouts
  - parse_legacy_summary_md()   old markdown fallback
  - merge_nightly_summary()     error_classes / data_dlls / by_assembly
  - build_chunk_status()        per-assembly rollup incl. unreached assemblies
  - end-to-end publish → HTML   error-class card renders

Usage: python3 scripts/test-publish-nightly.py [-v]
Exit code 0 = all passed.
"""

import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
PUB = HERE / "publish-nightly-results.py"
GEN = HERE / "generate-nightly-report.py"
# The engine tree is only used for the end-to-end section, which SKIPs when it
# is absent.  Overridable so CI can point at a real checkout without hardcoding
# a developer's home directory.
ENGINE = Path(os.environ.get("CHAOS_ENGINE_DIR", "/home/debian/agent/booming-il2cpp"))
TRANSLATION = ENGINE / "tests/e2e/translation"

VERBOSE = "-v" in sys.argv
_fails: list[str] = []
_skips: list[str] = []
_passes = 0


def check(name: str, cond: bool, detail: str = "") -> None:
    global _passes
    if cond:
        _passes += 1
        print(f"  PASS  {name}")
    else:
        _fails.append(name)
        print(f"  FAIL  {name}" + (f"  -- {detail}" if detail else ""))


def skip(name: str, reason: str = "") -> None:
    """Record a skipped section.

    Skips must be LOUD: a silent skip makes the suite report success while the
    coverage it was supposed to provide is simply gone.  This is printed with
    the same prominence as a failure and summarised at the end.
    """
    _skips.append(name)
    print(f"  SKIP  {name}" + (f"  -- {reason}" if reason else ""))


def load_module():
    spec = importlib.util.spec_from_file_location("pubmod", PUB)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def load_generator():
    spec = importlib.util.spec_from_file_location("genmod", GEN)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def write_json(path: Path, obj) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, indent=2), encoding="utf-8")


# ── Fixture: a realistic nightly-result.json (build 262 shape) ──
SUMMARY = {
    "total": 45, "passed": 20, "failed": 25, "stalled": 0,
    "byErrorClass": {"native-linker-error": 5, "csharp-error": 8,
                     "atg-combined-cs": 7, "unknown": 5},
    "byAssembly": {
        "System.Collections.Immutable": {"passed": 1, "failed": 0, "total": 1},
        "System.Private.CoreLib": {"passed": 15, "failed": 9, "total": 24},
        "System.Linq": {"passed": 0, "failed": 1, "total": 1},
        "System.Dead.Weight": {"passed": 0, "failed": 0, "total": 0},
    },
    "translationDefectFails": ["System.Linq__global-ns"],
    "infraFails": ["System.Private.CoreLib__io"],
    "codeDefectFails": ["System.Private.CoreLib__numerics"],
    "timestamp": 1757000000.0,
    "runId": "20260911_053000-2250e18",
    "nativeConfig": "profile",
}


def main() -> int:
    m = load_module()
    tmp = Path(tempfile.mkdtemp(prefix="nightly-selftest-"))
    try:
        print("\n[1] read_nightly_summary — both report_dir layouts")
        # Layout A: report_dir IS the summary dir (what the Jenkinsfile passes)
        a = tmp / "layoutA"
        write_json(a / "nightly-result.json", SUMMARY)
        sa = m.read_nightly_summary(a)
        check("layout A (report_dir == summary dir)", sa.get("passed") == 20 and sa.get("total") == 45,
              f"got {sa.get('passed')}/{sa.get('total')}")

        # Layout B: report_dir is the PARENT (canonical per aggregate.py)
        b = tmp / "layoutB"
        write_json(b / "summary" / "nightly-result.json", SUMMARY)
        sb = m.read_nightly_summary(b)
        check("layout B (report_dir is parent)", sb.get("passed") == 20 and sb.get("total") == 45,
              f"got {sb.get('passed')}/{sb.get('total')}")

        # Missing dir / absent file -> {} not raise
        check("missing dir returns {}", m.read_nightly_summary(tmp / "nope") == {})
        empty = tmp / "empty"
        empty.mkdir()
        check("empty dir returns {}", m.read_nightly_summary(empty) == {})

        # Corrupt JSON -> {} not raise
        bad = tmp / "bad"
        bad.mkdir()
        (bad / "nightly-result.json").write_text("{not json", encoding="utf-8")
        check("corrupt json returns {} (no raise)", m.read_nightly_summary(bad) == {})

        print("\n[2] parse_legacy_summary_md — old markdown fallback")
        legacy = tmp / "legacy"
        legacy.mkdir()
        (legacy / "nightly-summary.md").write_text(
            "### Overall\n\n"
            "| Metric | Value |\n|--------|-------|\n"
            "| Assemblies | 28 |\n"
            "| Chunks | 54 / 71 verified |\n\n"
            "### Stage Detail\n\n"
            "#### Build Failures ❌ (2)\n\n"
            "- System.Net.Sockets/global-ns (not_run)\n"
            "- System.Xml.ReaderWriter/xml (failed)\n",
            encoding="utf-8",
        )
        lg = m.parse_legacy_summary_md(legacy)
        check("legacy md: chunks parsed", lg.get("passed") == 54 and lg.get("total") == 71,
              str(lg))
        check("legacy md: failed derived", lg.get("failed") == 17, str(lg.get("failed")))
        check("legacy md: assemblies", lg.get("totalAssemblies") == 28)
        check("legacy md: failing chunk keys",
              lg.get("failingChunks") == ["System.Net.Sockets/global-ns",
                                          "System.Xml.ReaderWriter/xml"],
              str(lg.get("failingChunks")))
        check("legacy md: absent -> {}", m.parse_legacy_summary_md(tmp / "nope") == {})

        print("\n[3] merge_nightly_summary — derived + authoritative")
        merged = m.merge_nightly_summary(m.compute_summary({}), SUMMARY)
        check("chunk_passed/total", merged.get("chunk_passed") == 20 and merged.get("chunk_total") == 45)
        check("chunk_failed", merged.get("chunk_failed") == 25)
        check("error_classes present", merged.get("error_classes") ==
              {"atg-combined-cs": 7, "csharp-error": 8,
               "native-linker-error": 5, "unknown": 5},
              str(merged.get("error_classes")))
        check("error_classes sorted by key",
              list(merged.get("error_classes", {})) == sorted(merged.get("error_classes", {})))
        # 3 of 4 assemblies RAN (total>0); System.Dead.Weight has total=0.
        # System.Linq passed=0 but total=1 must still count — an all-failed
        # assembly is precisely what an operator needs to see.
        check("data_dlls counts assemblies that RAN, not only those that passed",
              merged.get("data_dlls") == 3, str(merged.get("data_dlls")))
        check("by_assembly present", isinstance(merged.get("by_assembly"), dict))
        # Regression guard: an assembly whose every chunk failed must still be
        # counted as "has data" (it ran), else it silently vanishes from coverage.
        only_failed = {"byAssembly": {"A": {"passed": 0, "failed": 3, "total": 3}},
                       "byErrorClass": {"unknown": 3}}
        check("all-failed assembly still counts toward data_dlls",
              m.merge_nightly_summary({}, only_failed).get("data_dlls") == 1)
        check("failing_chunks buckets",
              merged.get("failing_chunks", {}).get("translation_defect") == ["System.Linq__global-ns"]
              and merged.get("failing_chunks", {}).get("infra") == ["System.Private.CoreLib__io"],
              str(merged.get("failing_chunks")))
        check("summary_source set", merged.get("summary_source") == "nightly-result.json")

        # Empty summary must not crash and must be flagged
        empty_merge = m.merge_nightly_summary(m.compute_summary({}), {})
        check("empty summary -> no chunk keys", "chunk_passed" not in empty_merge)
        check("empty summary flagged as derived",
              empty_merge.get("summary_source") == "derived-from-per-chunk")

        # Legacy summary must not emit a bogus by_assembly
        legacy_merge = m.merge_nightly_summary(m.compute_summary({}), lg)
        check("legacy merge: no data_dlls claim", "data_dlls" not in legacy_merge)

        print("\n[4] build_chunk_status — per-assembly rollup")
        cs = m.build_chunk_status(SUMMARY, ["System.Collections.Immutable", "System.Xml.ReaderWriter"])
        check("known asm rollup", cs["System.Collections.Immutable"] ==
              {"chunk_passed": 1, "chunk_failed": 0, "chunk_total": 1}, str(cs.get("System.Collections.Immutable")))
        check("unreached asm shown as 0/N (not dropped)",
              cs["System.Xml.ReaderWriter"] ==
              {"chunk_passed": 0, "chunk_failed": 0, "chunk_total": 0})
        check("no byAssembly -> {}", m.build_chunk_status({}, ["A"]) == {})

        print("\n[5] end-to-end publish → HTML")
        if not TRANSLATION.is_dir():
            skip("end-to-end publish → HTML",
                 f"engine translation dir not found ({TRANSLATION}); "
                 f"set CHAOS_ENGINE_DIR to enable")
        else:
            for label, rdir in (("primary", a), ("legacy", legacy)):
                out = tmp / f"out-{label}"
                r = subprocess.run(
                    [sys.executable, str(PUB),
                     "--report-dir", str(rdir),
                     "--foundation-dir", str(TRANSLATION),
                     "--output-dir", str(out),
                     "--date-tag", "20260911", "--run-tag", "run1",
                     "--build-number", "265",
                     "--skip-ingest", "--skip-minio"],
                    capture_output=True, text=True, timeout=300,
                )
                check(f"publish({label}) exit 0", r.returncode == 0, r.stderr[-400:])
                data_files = list(out.glob("nightly-data-*.json"))
                check(f"publish({label}) wrote data json", len(data_files) == 1,
                      f"found {[f.name for f in data_files]}")
                if not data_files:
                    continue
                data = json.loads(data_files[0].read_text(encoding="utf-8"))
                summ = data["summary"]
                if label == "primary":
                    check("e2e: chunk_passed==20", summ.get("chunk_passed") == 20, str(summ.get("chunk_passed")))
                    check("e2e: error_classes carried",
                          summ.get("error_classes", {}).get("csharp-error") == 8)
                    check("e2e: build_number in summary (Report API reads it)",
                          summ.get("build_number") == "265")
                    check("e2e: provenance present",
                          data.get("provenance", {}).get("run_id") == "20260911_053000-2250e18")
                    check("e2e: summary_source", data.get("summary_source") == "nightly-result.json")
                else:
                    check("e2e(legacy): chunks carried", summ.get("chunk_passed") == 54,
                          str(summ.get("chunk_passed")))
                    check("e2e(legacy): source flagged",
                          data.get("summary_source") == "legacy nightly-summary.md")

                # HTML generation renders the new sections
                html = out / "r.html"
                g = subprocess.run(
                    [sys.executable, str(GEN), "--data", str(data_files[0]),
                     "--output", str(html), "--build-number", "265"],
                    capture_output=True, text=True, timeout=120,
                )
                check(f"html({label}) exit 0", g.returncode == 0, g.stderr[-400:])
                if html.exists():
                    doc = html.read_text(encoding="utf-8")
                    check(f"html({label}) valid document",
                          doc.lstrip().startswith("<!DOCTYPE html>") and doc.rstrip().endswith("</html>"))
                    if label == "primary":
                        check("html: chunk card rendered", "Chunk 构建" in doc)
                        check("html: error-class card rendered",
                              "失败归因" in doc)
                        check("html: error classes listed",
                              all(c in doc for c in
                                  ("native-linker-error", "csharp-error", "atg-combined-cs")))
                        check("html: failing-chunk list rendered", "System.Linq__global-ns" in doc)

        print("\n[6] no-data case must warn, not silently pass")
        nd = tmp / "nodata"
        nd.mkdir()
        out = tmp / "out-nodata"
        r = subprocess.run(
            [sys.executable, str(PUB),
             "--report-dir", str(nd),
             "--foundation-dir", str(TRANSLATION if TRANSLATION.is_dir() else nd),
             "--output-dir", str(out), "--date-tag", "20260911", "--run-tag", "run1",
             "--skip-ingest", "--skip-minio"],
            capture_output=True, text=True, timeout=300,
        )
        check("no-data run exits 0", r.returncode == 0, r.stderr[-300:])
        check("no-data run emits WARNING", "WARNING" in r.stdout + r.stderr)
        check("no-data run flags source NONE",
              "NONE" in r.stdout or "nothing to publish" in r.stdout)

        print("\n[7] chunk metric key paths (verified against real engine output)")
        # profile.json nests metrics under "summary"; hotupdate.json uses
        # passed/failed (NOT passCount/patchCount).  Both were read wrong before,
        # which is why the Memory and HotUpdate columns were permanently empty.
        gen = load_generator()
        chunk = {
            "profile": {"summary": {"totalNurseryAllocBytes": 71136,
                                    "totalGcPauseNs": 500, "fastPathRate": 0.5,
                                    "methodCount": 100}},
            "hotupdate": {"passed": 30, "failed": 2},
            "fact": {"passed": 9, "total": 10},
            "benchmark": {"methodCount": 7},
        }
        gm = gen.compute_dll_metrics({"chunks": {"c": chunk}})
        check("profile metrics read from profile.summary",
              gm["mem_alloc_bytes"] == 71136 and gm["mem_gc_pause_ns"] == 500,
              str((gm["mem_alloc_bytes"], gm["mem_gc_pause_ns"])))
        check("hotupdate read from passed/failed",
              gm["hotupdate_passed"] == 30 and gm["hotupdate_total"] == 32,
              str((gm["hotupdate_passed"], gm["hotupdate_total"])))
        # A flat profile block (older payload) must still render.
        flat = gen.compute_dll_metrics(
            {"chunks": {"c": {"profile": {"totalNurseryAllocBytes": 1234}}}})
        check("flat profile block tolerated", flat["mem_alloc_bytes"] == 1234)

        print("\n[8] fast_path_rate is a weighted mean, not a max")
        ch = {
            "a": {"profile": {"summary": {"fastPathRate": 1.0, "methodCount": 100}}},
            "b": {"profile": {"summary": {"fastPathRate": 0.0, "methodCount": 300}}},
        }
        s8 = m.compute_summary({"X": ch})
        # weighted = (1.0*100 + 0.0*300) / 400 = 0.25 ; max() would give 1.0
        check("weighted mean (0.25), not max (1.0)",
              abs(s8["memory_fast_path_rate"] - 0.25) < 1e-9,
              str(s8["memory_fast_path_rate"]))
        check("internal _fp_weighted not leaked into summary",
              "_fp_weighted" not in s8)
        check("no profile data -> rate stays 0.0",
              m.compute_summary({})["memory_fast_path_rate"] == 0.0)

        print("\n[9] report-server: error-class ingestion")
        dbp = HERE.parent / "report-server/api/database.py"
        if not dbp.exists():
            skip("report-server error-class ingestion", f"{dbp} not found")
        else:
            dbspec = importlib.util.spec_from_file_location("dbmod", dbp)
            dmod = importlib.util.module_from_spec(dbspec)
            dspec_path = tmp / "test-report.db"
            dmod.DB_PATH = dspec_path
            dbspec.loader.exec_module(dmod)
            dmod.DB_PATH = dspec_path
            dmod.init_db()
            check("init_db creates error_classes table", True)
            dmod.upsert_error_classes("20260911-run1",
                                      {"native-linker-error": 5, "csharp-error": 8},
                                      platform="linux")
            rows = dmod.get_error_classes(platform="linux")
            check("linux rows stored", len(rows) == 2, str(rows))
            dmod.upsert_error_classes("20260911-win-run1",
                                      {"native-linker-error": 5}, platform="windows")
            check("platform isolation (linux != windows)",
                  len(dmod.get_error_classes(platform="windows")) == 1)
            check("no cross-talk", len(dmod.get_error_classes(platform="linux")) == 2)
            # Re-ingest with fewer classes must not leave stale rows behind.
            dmod.upsert_error_classes("20260911-run1", {"csharp-error": 3}, platform="linux")
            rows = dmod.get_error_classes(date_tag="20260911-run1")
            check("re-ingest removes stale error-class rows",
                  len(rows) == 1 and rows[0]["error_class"] == "csharp-error", str(rows))
            check("empty/None input is a no-op",
                  dmod.upsert_error_classes("x", None) is None)
            # The reports table must record the chunk outcome; without these
            # columns the ingest computed them and they had nowhere to land, so
            # no trend or health query could be answered from the index.
            rcols = {r[1] for r in dmod.get_db().execute(
                "PRAGMA table_info(reports)").fetchall()}
            for col in ("chunk_passed", "chunk_total", "platform", "engine_sha"):
                check(f"reports table has {col}", col in rcols, str(sorted(rcols)))
            # init_db must be safe to re-run (it runs on every API restart).
            dmod.init_db()
            check("init_db is idempotent", True)

        print("\n[10] --skip-report-server (Windows must not write a Linux path)")
        if TRANSLATION.is_dir():
            out = tmp / "out-srs"
            # A Windows-style default (a Linux absolute path) must not be
            # created on whatever drive is current. Point --report-server-dir at
            # a path under tmp and assert the flag suppresses the copy entirely.
            rs = tmp / "fake-report-server"
            r = subprocess.run(
                [sys.executable, str(PUB),
                 "--report-dir", str(a),
                 "--foundation-dir", str(TRANSLATION),
                 "--output-dir", str(out),
                 "--date-tag", "20260911", "--run-tag", "run1",
                 "--report-server-dir", str(rs),
                 "--skip-ingest", "--skip-minio", "--skip-report-server"],
                capture_output=True, text=True, timeout=300,
            )
            check("--skip-report-server accepted", r.returncode == 0, r.stderr[-300:])
            check("--skip-report-server suppressed Phase 5",
                  "Phase 5" not in r.stdout, r.stdout[-300:])
            check("--skip-report-server created no directory", not rs.exists())
            # Without the flag the copy still happens (regression guard).
            rs2 = tmp / "real-report-server"
            r2 = subprocess.run(
                [sys.executable, str(PUB),
                 "--report-dir", str(a),
                 "--foundation-dir", str(TRANSLATION),
                 "--output-dir", str(tmp / "out-srs2"),
                 "--date-tag", "20260911", "--run-tag", "run1",
                 "--report-server-dir", str(rs2),
                 "--skip-ingest", "--skip-minio"],
                capture_output=True, text=True, timeout=300,
            )
            check("without the flag Phase 5 still runs",
                  r2.returncode == 0 and "Phase 5" in r2.stdout and rs2.exists())
        else:
            skip("--skip-report-server checks", "engine tree not available")

        print("\n[10] provenance: engine_sha + platform must be explicit")
        if TRANSLATION.is_dir():
            out = tmp / "prov"
            r = subprocess.run(
                [sys.executable, str(PUB),
                 "--report-dir", str(a),
                 "--foundation-dir", str(TRANSLATION),
                 "--output-dir", str(out),
                 "--date-tag", "20260911", "--run-tag", "run1",
                 "--build-number", "267",
                 "--engine-sha", "e3992ccc5", "--platform", "windows",
                 "--skip-ingest", "--skip-minio", "--skip-html"],
                capture_output=True, text=True, timeout=300,
            )
            check("publish accepts --engine-sha/--platform", r.returncode == 0, r.stderr[-300:])
            dfs = list(out.glob("nightly-data-*.json"))
            if dfs:
                prov = json.loads(dfs[0].read_text(encoding="utf-8")).get("provenance", {})
                check("provenance.engine_sha recorded", prov.get("engine_sha") == "e3992ccc5", str(prov))
                check("provenance.platform recorded", prov.get("platform") == "windows", str(prov))
                check("raw run_id kept for traceability", "run_id" in prov)
        else:
            skip("provenance checks", "engine tree not available")

        print("\n[11] per-platform Feishu payload")
        FEISHU = HERE / "build-feishu-payload.py"
        if not FEISHU.exists():
            skip("feishu payload checks", f"{FEISHU} not found")
        else:
            fspec = importlib.util.spec_from_file_location("fmod", FEISHU)
            fm = importlib.util.module_from_spec(fspec)
            fspec.loader.exec_module(fm)

            # Both platforms carry an explicit suffix (decision 3b): bare names
            # for linux made "the linux file" indistinguishable from "the
            # default file" and already caused the wrong payload to be read.
            check("artifact name: linux carries -linux",
                  fm.artifact_name("20260911", "run2", "linux") == "nightly-data-20260911-linux-run2.json")
            check("artifact name: windows is -win suffixed",
                  fm.artifact_name("20260911", "run2", "windows") == "nightly-data-20260911-win-run2.json")
            # ── Z: absolute-only health verdict ──
            def P(**kw):
                base = {"present": True, "chunk_passed": 20, "chunk_total": 45}
                base.update(kw)
                return base

            v = fm.verdict({"linux": P(), "windows": P()}, [], ["linux", "windows"])
            check("Z: all healthy -> green", v["level"] == "green", str(v))

            v = fm.verdict({"linux": P(chunk_passed=0), "windows": P()}, [],
                           ["linux", "windows"])
            check("Z: a platform passing 0 -> red", v["level"] == "red", str(v))
            check("Z: names the dead platform", "linux" in v.get("reason", ""), str(v))

            v = fm.verdict({"linux": P(), "windows": {"present": False}}, ["windows"],
                           ["linux", "windows"])
            check("Z: missing platform -> red", v["level"] == "red", str(v))

            v = fm.verdict({"linux": P(), "windows": P()}, [], ["linux", "windows"],
                           jenkins_result="FAILURE")
            check("Z: jenkins FAILURE -> red regardless", v["level"] == "red", str(v))

            # Decision 1c: NO percentage threshold. A low-but-nonzero pass rate
            # must NOT raise the alarm — a threshold picked out of the air goes
            # off every night once a build settles below it.
            v = fm.verdict({"linux": P(chunk_passed=1), "windows": P(chunk_passed=1)}, [],
                           ["linux", "windows"])
            check("Z: 1/45 is NOT flagged (absolute-only, no threshold)",
                  v["level"] == "green", str(v))

            # A platform with no chunks at all is not "dead", it's empty.
            v = fm.verdict({"linux": P(chunk_total=0, chunk_passed=0), "windows": P()}, [],
                           ["linux", "windows"])
            check("Z: zero-total platform is not treated as dead",
                  v["level"] == "green", str(v))

            # ── Y: trend vs previous ──
            cur = {"linux": P(chunk_passed=20), "windows": P(chunk_passed=25)}
            prev = {"linux": {"present": True, "chunk_passed": 15, "chunk_total": 45},
                    "windows": {"present": True, "chunk_passed": 25, "chunk_total": 45}}
            t = fm.compare_previous(cur, prev)
            check("Y: delta computed", t["linux"]["delta"] == 5, str(t["linux"]))
            check("Y: unchanged platform gives 0", t["windows"]["delta"] == 0)
            check("Y: same_total marked comparable", t["linux"]["same_total"] is True)

            # A different total means the worklist moved — not a like-for-like
            # comparison, so it must not be rendered as a delta.
            prev_diff_total = {"linux": {"present": True, "chunk_passed": 15, "chunk_total": 40}}
            t = fm.compare_previous(cur, prev_diff_total)
            check("Y: total change -> not a like-for-like delta",
                  t["linux"]["same_total"] is False, str(t["linux"]))

            # No baseline must read as "首轮", never as "no change".
            t = fm.compare_previous(cur, None)
            check("Y: no previous -> marked not comparable",
                  t["linux"]["comparable"] is False, str(t["linux"]))

            # ── 5b: unknown is folded, and the body leads with the verdict ──
            local_only = tmp / "only_linux.json"
            write_json(local_only, {
                "summary": {"chunk_passed": 0, "chunk_total": 45, "data_dlls": 26,
                            "error_classes": {"unknown": 43, "atg-combined-cs": 2}},
                "total_dlls": 25, "provenance": {"engine_sha": "abc"}})
            pay5 = fm.build_payload("http://127.0.0.1:1/job/x/1", "20260911", "run2",
                                    local_only, "", ["linux"], previous=None)
            body5 = "\n".join(pay5["body_lines"])
            check("body leads with the verdict",
                  body5.lstrip().startswith(("🔴", "✅", "⚪")), body5[:60])
            check("actionable class shown as a lead",
                  "atg-combined-cs" in body5, body5)
            check("unknown folded into its own subdued line",
                  "另有 43 个未分类" in body5, body5)
            check("unknown not listed among the named leads",
                  "`unknown`" not in body5, body5)

            s = fm.summarise({"summary": {"chunk_passed": 20, "chunk_total": 45,
                                          "error_classes": {"csharp-error": 8},
                                          "data_dlls": 3},
                              "total_dlls": 25,
                              "provenance": {"engine_sha": "e3992ccc5"}})
            check("summarise: counts + pct", s["chunk_passed"] == 20 and s["chunk_pct"] == "44.4%", str(s))
            check("summarise: engine_sha surfaced", s["engine_sha"] == "e3992ccc5")
            check("summarise: absent payload marked not present",
                  fm.summarise(None) == {"present": False})
            # engine_sha unrecorded must be visible, not an empty string.
            check("summarise: missing engine_sha is explicit",
                  fm.summarise({"summary": {}})["engine_sha"] == "(unrecorded)")

            # A missing platform is the whole point: it must be surfaced.
            import tempfile as _tf
            with _tf.TemporaryDirectory() as td:
                lp = Path(td) / "lin.json"
                write_json(lp, {"summary": {"chunk_passed": 1, "chunk_total": 2},
                                "total_dlls": 2, "provenance": {"engine_sha": "abc"}})
                pay = fm.build_payload("http://127.0.0.1:1/job/x/1", "20260911", "run2",
                                       lp, "", ["linux", "windows"])
                check("missing windows flagged when expected",
                      pay["missing_platforms"] == ["windows"], str(pay["missing_platforms"]))
                check("linux still reported from the local file",
                      pay["platforms"]["linux"]["present"] is True)
                body = "\n".join(pay["body_lines"])
                check("body names the absent platform explicitly", "Windows" in body)
                # With only linux expected, no alarm must be raised.
                pay2 = fm.build_payload("http://127.0.0.1:1/job/x/1", "20260911", "run2",
                                        lp, "", ["linux"])
                check("no false alarm when windows not expected",
                      pay2["missing_platforms"] == [], str(pay2["missing_platforms"]))

        print("\n[12] Jenkinsfile sanity")
        # In CI (Jenkins Init) only scripts/ is downloaded into the workspace —
        # there is no checkout, so no Jenkinsfile.  Skip loudly rather than
        # raising FileNotFoundError and failing the whole suite.
        jf_path = HERE.parent / "Jenkinsfile"
        if not jf_path.exists():
            skip("Jenkinsfile assertions", f"{jf_path} not found (CI has no checkout)")
            jf = None
        else:
            jf = jf_path.read_text(encoding="utf-8")
        if jf is not None:
            check("baseline date format fixed (%Y%m%d present)",
                  "date -d '${DATE_TAG} 1 day ago' +%Y%m%d" in jf)
            # The bug string may legitimately appear inside the explanatory
            # comment, so assert on the executable date command, not a bare grep.
            check("no executable %Y%mdd date command",
                  "+%Y%mdd" not in jf.replace(
                      "// NOTE the format is %Y%m%d — it was %Y%mdd, which emits", ""))
            check("windows publish wired", "publish-nightly-results.py" in jf)
            check("windows artifact tag isolated", "-win" in jf)
            check("windows archiveArtifacts on windows node",
                  jf.count("archiveArtifacts") >= 2, str(jf.count("archiveArtifacts")))
            check("python interpolation not leaked in bat",
                  "%BUILD_NUMBER%" in jf and "%GIT_COMMIT%" in jf)
            check("self-test wired into CI download list",
                  "test-publish-nightly.py" in jf)
            check("self-test gate stage present",
                  "Publish-Chain Self-Test" in jf)
            # Bug seen on the real Windows agent: only the publisher was
            # downloaded, so the HTML step warned "generate-nightly-report.py
            # not found" and produced JSON only.
            check("windows downloads BOTH publish scripts",
                  jf.count("generate-nightly-report.py") >= 2,
                  f"count={jf.count('generate-nightly-report.py')}")
            # Bug seen on the real Windows agent: `set "PUBRC=%ERRORLEVEL%"`
            # inside a parenthesised block expanded at parse time, so the exit
            # code came back empty and failures were invisible. Delayed
            # expansion must be enabled at SCRIPT level — a mid-script
            # setlocal does not survive the endlocal&set idiom (verified on the
            # agent: that form still captured nothing).
            check("windows enables delayed expansion",
                  "EnableDelayedExpansion" in jf)
            check("windows reads exit code with !ERRORLEVEL!",
                  "!ERRORLEVEL!" in jf)
            # Assert on CODE, not comments: the broken idiom is described in a
            # REM (and the fix's rationale references it), so a bare substring
            # test would fail on its own documentation.
            bat_code = "\n".join(
                l for l in re.findall(r'bat """(.*?)"""', jf, re.S)[0].splitlines()
                if not l.strip().upper().startswith("REM")
            )
            check("no broken endlocal&set idiom in bat code",
                  "endlocal & set" not in bat_code)
            check("delayed expansion enabled in bat code",
                  "setlocal EnableDelayedExpansion" in bat_code)
            check("windows forwards --skip-report-server",
                  "--skip-report-server" in jf)
            # No CDN 'main' fallback anywhere: /main was measured serving the
            # PREVIOUS revision after a push (even with a cache-buster) while the
            # SHA-pinned path was current, so a fallback silently mixes old and
            # new scripts.
            check("no raw.githubusercontent /main path anywhere",
                  "nightly-test/main" not in jf)
            check("all RAWT assignments are SHA-pinned",
                  all("NIGHTLY_SHA" in l or "%GIT_COMMIT%" in l
                      for l in jf.splitlines() if l.strip().startswith("RAWT=")),
                  str([l.strip() for l in jf.splitlines()
                       if l.strip().startswith("RAWT=")]))
            # Both download sites that must have a real SHA now check out this
            # commit first. GIT_COMMIT comes from a checkout, NOT from being a
            # CpsScmFlowDefinition — Init originally had no checkout, so
            # GIT_COMMIT was empty on every build (build 264's console shows
            # "NIGHTLY_SHA=" with the `main` fallback doing the work), and
            # removing that fallback without adding the checkout stopped the
            # whole pipeline dead in 12 seconds (build 265).
            check("linux Init checks out before the pinned download",
                  "checkout scm" in jf)
            # On this Jenkins the checkout succeeds but does NOT export
            # GIT_COMMIT to the environment: build 266 checked out a36f217 and
            # still echoed "@ null", so the pin stayed empty and the guard fired.
            # The revision must come from checkout's return value (or rev-parse).
            check("revision captured from checkout return value, not env only",
                  "def scmInfo = checkout scm" in jf and "scmInfo?.GIT_COMMIT" in jf)
            check("fallback to git rev-parse when checkout gives no SHA",
                  "rev-parse HEAD" in jf)
            check("fails loudly if the revision cannot be resolved",
                  "could not resolve this repo's revision" in jf)
            check("linux init guards against an unset GIT_COMMIT",
                  "GIT_COMMIT is unset" in jf)
            check("code-review checks out before the pinned download",
                  jf.count("checkout scm") >= 2, f"count={jf.count('checkout scm')}")
            check("code-review guards against an unset GIT_COMMIT",
                  "GIT_COMMIT is unset (the checkout scm did not run?)" in jf)
            # The windows stage runs on a DIFFERENT agent than Init's checkout,
            # so it must not depend on cross-node env propagation: it resolves
            # a pin independently and SKIPS (rather than failing the branch)
            # when no usable pin can be found.
            check("windows resolves a pin without relying on cross-node GIT_COMMIT",
                  'set "PIN=%GIT_COMMIT%"' in jf and "GIT_PREVIOUS_COMMIT" in jf)
            check("windows skips publish (not fails) when the pin is unusable",
                  "skipping publish" in jf.lower())
            # The nightly CLI's run_id hash is derived from git in its CWD, which on
            # the Linux branch is a git-archive tree with no .git — so git walks up
            # and reports the CI repo's hash, not the engine's. Build 267 showed the
            # two branches emitting hashes from different namespaces under the same
            # field (linux 6e2049c = CI repo, windows e3992ccc5 = engine). Both
            # branches must therefore pass the engine revision explicitly.
            check("linux passes --engine-sha", "--engine-sha" in jf)
            check("linux passes --platform", '--platform "linux"' in jf)
            check("windows passes --engine-sha", jf.count("--engine-sha") >= 2,
                  f"count={jf.count('--engine-sha')}")
            check("windows passes --platform", '--platform "windows"' in jf)
            # A pipeline-scoped env.* value set during Init (which runs on the
            # LINUX agent) propagates to every other node. Setting
            # env.DOTNET_ROOT=/usr/share/dotnet there therefore put a LINUX path
            # on the windows agent, and the old `if not defined DOTNET_ROOT`
            # guard saw it as already set and kept it — every windows chunk then
            # failed "DLL not found for <Assembly>" (45/45, classed "unknown").
            # The windows guard must OVERWRITE, not merely default.
            check("windows DOTNET_ROOT guard overwrites a leaked value",
                  "if not defined DOTNET_ROOT if exist" not in jf)
            check("windows sets DOTNET_ROOT from a Windows path",
                  'set "DOTNET_ROOT=C:\\\\Program Files\\\\dotnet"' in jf)
            check("windows echoes the resolved DOTNET_ROOT for diagnosis",
                  "DOTNET_ROOT=%DOTNET_ROOT%" in jf)
            # Windows must NOT use every core: all chunks rebuild the same shared
            # C# projects, and the engine's `dotnet build-server shutdown` is not
            # a lock, so parallel rebuilds race and VBCSCompiler holds the DLL
            # open -> CS2012 file-in-use (9+ chunks in build 268, run left 0/45).
            check("windows does NOT use all cores for workers",
                  "max-workers %NUMBER_OF_PROCESSORS%" not in jf)
            # The engine's build.py locates the runtime DLLs via DOTNET_ROOT.
            # It is unset on the linux agent, so every chunk failed with the
            # opaque class "unknown" (43 of them, build 272) and linux went
            # 20/45 -> 0/45. The windows branch had guarded this all along; the
            # linux branch never did, because a developer shell exports it.
            check("linux sets DOTNET_ROOT for the engine",
                  "env.DOTNET_ROOT" in jf)
            # /usr/local/bin/dotnet is a SYMLINK to /usr/share/dotnet/dotnet, so
            # a bare dirname gives /usr/local/bin, which has no shared/.
            check("dotnet probe resolves symlinks",
                  "readlink -f" in jf and 'dirname "$(readlink -f' in jf)
            check("dotnet root is validated to contain shared/",
                  'test -d "${DOTNET_ROOT}/shared"' in jf)
            check("windows worker count is capped",
                  "NIGHTLY_WORKERS=4" in jf or 'set "NIGHTLY_WORKERS=' in jf)
            # Groovy does NOT interpolate %name%; that is cmd syntax. Writing a
            # Groovy variable as %winArtifacts% passes the literal text through
            # to cmd, which then finds no such BAT variable and expands it to
            # EMPTY. That silently sent the windows publish to `--output-dir`
            # "." and `--foundation-dir "\tests\e2e\translation"` in build 271,
            # and also wrote the helper to "D:\publish-nightly-results.py".
            # Each Groovy variable used inside the bat body must be ${...}.
            bat_body = re.findall(r'bat """(.*?)"""', jf, re.S)[0]
            groovy_vars = ("winArtifacts", "winBoomin")
            bad_refs = [
                f"%{v}%" for v in groovy_vars if f"%{v}%" in bat_body
            ]
            check("no Groovy variable written with cmd %var% syntax",
                  not bad_refs, f"found {bad_refs}")
            check("windows publish paths use ${...} interpolation",
                  "${winArtifacts}" in bat_body and "${winBoomin}" in bat_body)
            # so a comment like \var\lib breaks the whole Jenkinsfile (this cost
            # a parse error once already). Only single backslashes are hazards;
            # doubled ones are the correct escaping.
            # Groovy parses backslash escapes even inside triple-quoted strings,
            # so a single backslash anywhere in a `bat """..."""` body — including
            # a REM comment — can break the whole Jenkinsfile. A bare \u is
            # treated as a unicode escape ("Did not find four digit hex character
            # code") and a bare \a/\v etc. is an invalid escape. This has now
            # cost three separate parse failures. Only DOUBLED backslashes are
            # safe; scan the raw text of every bat block, comments included.
            bad_escapes = []
            for blk in re.findall(r'bat """(.*?)"""', jf, re.S):
                for n, line in enumerate(blk.splitlines(), 1):
                    for m in re.finditer(r'(?<!\\)\\', line):
                        # allow \\ (escaped) and \" (escaped quote)
                        nxt = line[m.end():m.end() + 1]
                        if nxt in ('\\', '"'):
                            continue
                        bad_escapes.append(f"line {n}: ...{line[max(0,m.start()-18):m.start()+18]}...")
                        break
            check("no single backslash escapes in any bat block",
                  not bad_escapes, f"found {bad_escapes[:3]}")

    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    total = _passes + len(_fails)
    print(f"\n{'='*60}")
    print(f"  {_passes}/{total} checks passed")
    if _skips:
        # Never let a skip read as a pass: the suite would otherwise be green
        # while the coverage it exists to provide is silently absent.
        print(f"  SKIPPED ({len(_skips)}): {', '.join(_skips)}")
    if _fails:
        print(f"  FAILED: {', '.join(_fails)}")
    print(f"{'='*60}")

    # --require-e2e: CI uses this to guarantee the engine-backed path really ran
    # rather than being silently skipped on a machine without the engine tree.
    if "--require-e2e" in sys.argv and any("end-to-end" in s for s in _skips):
        print("ERROR: --require-e2e set but end-to-end section was skipped")
        return 2
    return 1 if _fails else 0


if __name__ == "__main__":
    raise SystemExit(main())
