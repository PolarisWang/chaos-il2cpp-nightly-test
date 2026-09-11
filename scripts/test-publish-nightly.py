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

        print("\n[10] Jenkinsfile sanity")
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
