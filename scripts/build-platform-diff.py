#!/usr/bin/env python3
"""build-platform-diff.py — compare two platforms' nightly runs CHUNK BY CHUNK.

Why this exists
---------------
Linux and Windows each publish their own nightly-data JSON.  Nothing compared
them, so "Windows passes, Linux fails" could only be established by hand — and
doing it by hand produced a wrong answer twice on 2026-09-22: two reports taken
nine days apart (the windows one predated a change that altered ATG behaviour)
were read as a platform difference, and the wrong denominator was used so the
gap looked like 4x when the real figure was 0 for most chunks.

This tool encodes the three things the manual comparison got wrong:

  1. Same revision, or the diff is meaningless.  Each report carries the engine
     SHA it was built from.  A mismatch is an ERROR (the numbers measure the
     commits in between), and a missing SHA on either side is reported as
     UNVERIFIABLE rather than silently compared.

  2. Compare ratios, not totals.  The ATG emits a different number of subjects
     per host, so `realTotal` legitimately differs between platforms
     (observed: xml 411 vs 746).  Only `realPassed / realTotal` is comparable.

  3. Separate "platform differs" from "both platforms are weak".  A chunk that
     executes few assertions on BOTH sides is not a portability defect, and
     putting it in the same list as a genuine divergence buries the signal.

Output: a JSON file for machines and a Markdown file for humans, both grouping
chunks into platform-diff / shared-low / consistent.

Usage:
    build-platform-diff.py --linux  l.json --windows w.json --output diff
    build-platform-diff.py --linux l.json --windows w.json --output diff --allow-mismatch
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

# A gap this large is treated as a portability defect, not noise.  Chosen from
# real data: on 2026-09-22 the two genuine divergences measured 56 and 91 points
# while every other comparable chunk sat under 12.
PLATFORM_DIFF_THRESHOLD = 25.0
# Below this, both sides are simply under-covered; the gap between them is not
# the story.  Reported separately so it never masks a real divergence.
SHARED_LOW_THRESHOLD = 20.0
CONSISTENT_THRESHOLD = 10.0
# A side with fewer real assertions than this is too small to rank on.
MIN_SAMPLE = 30

GROUPS = ("platform-diff", "shared-low", "consistent", "insufficient")


class DiffError(Exception):
    """A condition that makes the comparison invalid (not merely noisy)."""


def load_report(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except OSError as e:
        raise DiffError(f"cannot read {path}: {e}") from e
    except ValueError as e:
        raise DiffError(f"{path} is not valid JSON: {e}") from e


def engine_sha(report: dict) -> str:
    return str(report.get("engineSha") or "").strip()


def real_ratio(metrics: dict) -> float | None:
    """realPassed / realTotal as a percentage, or None when not computable."""
    passed = metrics.get("realPassed")
    total = metrics.get("realTotal")
    if passed is None or total is None or total <= 0:
        return None
    return 100.0 * passed / total


def classify(w_ratio: float, l_ratio: float, w_total: int, l_total: int) -> tuple[str, float]:
    """Group one chunk and return (group, gap-in-percentage-points)."""
    gap = w_ratio - l_ratio
    if min(w_total, l_total) < MIN_SAMPLE:
        return "insufficient", gap
    if abs(gap) > PLATFORM_DIFF_THRESHOLD:
        return "platform-diff", gap
    if w_ratio < SHARED_LOW_THRESHOLD and l_ratio < SHARED_LOW_THRESHOLD and abs(gap) <= CONSISTENT_THRESHOLD:
        return "shared-low", gap
    return "consistent", gap


def build_diff(linux: dict, windows: dict, allow_mismatch: bool = False) -> dict:
    l_sha, w_sha = engine_sha(linux), engine_sha(windows)

    warnings: list[str] = []
    if not l_sha or not w_sha:
        missing = "linux" if not l_sha else "windows"
        warnings.append(
            f"engineSha missing on {missing} — the two reports cannot be proven to "
            "come from the same revision; treat every row as indicative only."
        )
    elif l_sha != w_sha:
        msg = (
            f"engineSha differs (linux={l_sha} windows={w_sha}) — this diff measures "
            "the commits between those revisions, not a platform difference."
        )
        if not allow_mismatch:
            raise DiffError(msg + " Pass --allow-mismatch to compare anyway.")
        warnings.append(msg)

    l_metrics = linux.get("chunkMetrics") or {}
    w_metrics = windows.get("chunkMetrics") or {}

    rows = []
    only_linux, only_windows = [], []
    for key in sorted(set(l_metrics) | set(w_metrics)):
        if key not in w_metrics:
            only_linux.append(key)
            continue
        if key not in l_metrics:
            only_windows.append(key)
            continue
        lm, wm = l_metrics[key], w_metrics[key]
        lr, wr = real_ratio(lm), real_ratio(wm)
        if lr is None or wr is None:
            only_linux.append(key) if lr is None else only_windows.append(key)
            continue
        group, gap = classify(wr, lr, int(wm.get("realTotal") or 0), int(lm.get("realTotal") or 0))
        rows.append({
            "chunk": key,
            "group": group,
            "linuxRealPct": round(lr, 1),
            "windowsRealPct": round(wr, 1),
            "gapPp": round(gap, 1),
            "linuxRealPassed": lm.get("realPassed"),
            "linuxRealTotal": lm.get("realTotal"),
            "windowsRealPassed": wm.get("realPassed"),
            "windowsRealTotal": wm.get("realTotal"),
            "linuxStubGap": lm.get("stubGap"),
            "windowsStubGap": wm.get("stubGap"),
        })

    rows.sort(key=lambda r: abs(r["gapPp"]), reverse=True)

    if only_linux:
        warnings.append(f"{len(only_linux)} chunk(s) present only on linux: " + ", ".join(only_linux[:5]))
    if only_windows:
        warnings.append(f"{len(only_windows)} chunk(s) present only on windows: " + ", ".join(only_windows[:5]))

    counts = {g: sum(1 for r in rows if r["group"] == g) for g in GROUPS}
    return {
        "linuxEngineSha": l_sha,
        "windowsEngineSha": w_sha,
        "comparable": bool(l_sha and w_sha and l_sha == w_sha),
        "warnings": warnings,
        "counts": counts,
        "rows": rows,
        "platformDiffChunks": [r["chunk"] for r in rows if r["group"] == "platform-diff"],
    }


def render_markdown(diff: dict) -> str:
    lines = ["# Platform diff — Windows vs Linux", ""]
    lines.append(f"- linux engine:   `{diff['linuxEngineSha'] or '(missing)'}`")
    lines.append(f"- windows engine: `{diff['windowsEngineSha'] or '(missing)'}`")
    lines.append(f"- comparable: **{'yes' if diff['comparable'] else 'NO'}**")
    lines.append("")
    for w in diff["warnings"]:
        lines.append(f"> ⚠️ {w}")
    if diff["warnings"]:
        lines.append("")

    c = diff["counts"]
    lines.append(
        f"Totals: {c['platform-diff']} platform-diff · {c['shared-low']} shared-low · "
        f"{c['consistent']} consistent · {c['insufficient']} insufficient-sample"
    )
    lines.append("")

    titles = {
        "platform-diff": "🔴 Platform diff — the portability backlog",
        "shared-low": "⚪ Shared low coverage — NOT a portability issue",
        "consistent": "✅ Consistent",
        "insufficient": "❔ Insufficient sample",
    }
    for group in GROUPS:
        rows = [r for r in diff["rows"] if r["group"] == group]
        if not rows:
            continue
        lines.append(f"## {titles[group]} ({len(rows)})")
        lines.append("")
        if group == "consistent":
            lines.append("| chunk | win% | linux% | Δ |")
            lines.append("|---|---:|---:|---:|")
            for r in rows:
                lines.append(f"| `{r['chunk']}` | {r['windowsRealPct']} | {r['linuxRealPct']} | {r['gapPp']:+.1f} |")
        else:
            lines.append("| chunk | win% | linux% | Δ | win real | linux real | win stubGap | linux stubGap |")
            lines.append("|---|---:|---:|---:|---:|---:|---:|---:|")
            for r in rows:
                lines.append(
                    f"| `{r['chunk']}` | {r['windowsRealPct']} | {r['linuxRealPct']} | {r['gapPp']:+.1f} | "
                    f"{r['windowsRealPassed']}/{r['windowsRealTotal']} | "
                    f"{r['linuxRealPassed']}/{r['linuxRealTotal']} | "
                    f"{r['windowsStubGap']} | {r['linuxStubGap']} |"
                )
        lines.append("")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--linux", required=True, type=Path)
    ap.add_argument("--windows", required=True, type=Path)
    ap.add_argument("--output", required=True, help="output prefix; .json and .md are appended")
    ap.add_argument("--allow-mismatch", action="store_true",
                    help="compare even when the engine SHAs differ (result is indicative only)")
    args = ap.parse_args(argv)

    try:
        diff = build_diff(load_report(args.linux), load_report(args.windows), args.allow_mismatch)
    except DiffError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2

    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    (out.with_suffix(".json")).write_text(json.dumps(diff, indent=2), encoding="utf-8")
    (out.with_suffix(".md")).write_text(render_markdown(diff), encoding="utf-8")

    c = diff["counts"]
    print(f"  platform-diff: {c['platform-diff']}  shared-low: {c['shared-low']}  "
          f"consistent: {c['consistent']}  insufficient: {c['insufficient']}")
    for w in diff["warnings"]:
        print(f"  WARNING: {w}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
