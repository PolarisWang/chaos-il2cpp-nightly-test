#!/usr/bin/env python3
"""build-feishu-payload.py — assemble the nightly notification payload for BOTH platforms.

Why this exists
---------------
The Feishu card used to be built inline in the Jenkinsfile from a single
`nightly-data-<date>-<run>.json` sitting in the linux-x64 workspace. The
windows-x64 branch runs on a different agent and writes into its OWN
workspace, so its results could never appear in the card — the group saw
Linux only, with no indication that a second platform existed.

Each platform archives its payload to the controller (archiveArtifacts), so
this script fetches both over the Jenkins REST API regardless of which node
it runs on, and emits one card payload describing both.

Usage:
    build-feishu-payload.py --build-url http://jenkins:8080/job/x/42 \
        --date-tag 20260911 --run-tag run2 [--local-linux-json PATH] \
        --output /path/to/feishu-data.json [--expect windows,linux]

Exit code is 0 even when a platform is missing: a missing platform is
reported IN the card rather than failing the notification, because "windows
produced nothing" is exactly the thing the group needs to see.
"""

import argparse
import json
import sys
import urllib.error
import urllib.request
from pathlib import Path

# Which artifact name each platform publishes. The windows branch deliberately
# uses a "-win" date suffix so the two platforms never collide.
PLATFORMS = ("linux", "windows")


def artifact_name(date_tag: str, run_tag: str, platform: str) -> str:
    """Artifact filename for one platform.

    Both platforms carry an explicit suffix so the namespace is symmetric.
    Linux used to be bare (`nightly-data-<date>-<run>.json`) while Windows was
    `-win`, which made "the linux file" indistinguishable from "the default
    file" and left the two platforms in different naming shapes — an ambiguity
    that already caused the wrong payload to be read once.
    """
    suffix = "-win" if platform == "windows" else "-linux"
    return f"nightly-data-{date_tag}{suffix}-{run_tag}.json"


def fetch_json(url: str, auth: str = "") -> dict | None:
    """GET a JSON document. Returns None on any failure (reported by caller)."""
    req = urllib.request.Request(url)
    if auth:
        import base64
        req.add_header("Authorization", "Basic " + base64.b64encode(auth.encode()).decode())
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, urllib.error.HTTPError, OSError, ValueError) as e:
        print(f"  [feishu] could not fetch {url}: {e}", file=sys.stderr)
        return None


def count_platform_diffs(platforms: dict) -> int | None:
    """How many chunks diverge between the two platforms, or None if unknown.

    Mirrors the grouping in scripts/build-platform-diff.py: only chunks present
    on BOTH sides with a usable real-assertion denominator, and a gap wide
    enough to be a portability defect rather than noise.

    Returns None (not 0) when the inputs cannot answer the question — both
    sides lacking metrics, or the two reports not being from the same revision.
    A "0" would read as "no platform problems", which is a different claim from
    "we could not tell", and only one of those is true for old payloads.
    """
    l_metrics = (platforms.get("linux") or {}).get("chunk_metrics") or {}
    w_metrics = (platforms.get("windows") or {}).get("chunk_metrics") or {}
    if not l_metrics or not w_metrics:
        return None
    if engine_sha_match(platforms) is False:
        return None

    n = 0
    for key in set(l_metrics) & set(w_metrics):
        lm, wm = l_metrics[key], w_metrics[key]
        lt, wt = lm.get("realTotal"), wm.get("realTotal")
        lp, wp = lm.get("realPassed"), wm.get("realPassed")
        if not lt or not wt or lp is None or wp is None:
            continue
        if min(lt, wt) < 30:          # sample too small to rank on
            continue
        if abs((wp / wt) - (lp / lt)) * 100.0 > 25.0:
            n += 1
    return n


def engine_sha_match(platforms: dict) -> bool | None:
    """Whether both platforms report the same engine revision.

    None means "cannot tell" — a missing or unrecorded SHA on either side. That
    is NOT the same as False: False asserts the reports are from different
    revisions, which invalidates a comparison; None only means unproven.

    Older payloads stored engine_sha under provenance with the placeholder
    "(unrecorded)"; treat that and "" alike.
    """
    def sha(plat: str) -> str:
        v = str((platforms.get(plat) or {}).get("engine_sha") or "").strip()
        return "" if v in ("", "(unrecorded)") else v

    l_sha, w_sha = sha("linux"), sha("windows")
    if not l_sha or not w_sha:
        return None
    return l_sha == w_sha


def verdict(platforms: dict, missing: list, expect: list,
            jenkins_result: str = "") -> dict:
    """Single source of truth for "does this run need attention?".

    Deliberately ABSOLUTE-ONLY (decision Z): it fires on conditions that cannot
    be a false alarm, and says nothing about percentages. An earlier draft used a
    50%-pass threshold, which was rejected: a threshold picked out of the air
    goes off every night once a build settles below it, and a card that cries
    wolf stops being read. Threshold/trend-based judgement belongs in the
    follow-up work once there is enough history to define a baseline — this
    function is the place to add it, because the card AND the web report both
    read from here.

    Returns {level: red|yellow|green, word, reason}. `level` drives colour
    everywhere, so the card and the page can never disagree about whether a run
    is healthy.

    Three levels, not two. A two-level (dead/alive) verdict reads a platform
    that passes SOME chunks as fully healthy: windows at 18/45 scored "正常"
    while the same page showed 27 failures under a red "失败归因" heading. The
    card and the web report are rendered from this one function, so the
    contradiction was visible in a single glance at either one. "Some chunks
    fail" is its own state — not健康, and not the total outage that red means.
    """
    if jenkins_result.upper() in ("FAILURE", "ABORTED"):
        return {"level": "red", "word": "构建失败",
                "reason": f"Jenkins {jenkins_result.upper()}"}

    if missing:
        return {"level": "red", "word": "需要处理",
                "reason": "缺少平台报告: " + "、".join(missing)}

    # A platform whose artifact exists but holds no results. The file is
    # present, so the old `missing` check passed and the card rendered a green
    # "✅ 0/0" — a tick against a platform that produced nothing. That is how
    # build 288's interrupted windows run presented: no chunk_total at all.
    empty = [
        p for p in expect
        if platforms.get(p, {}).get("present")
        and not platforms[p].get("has_data", False)
    ]
    if empty:
        return {"level": "red", "word": "需要处理",
                "reason": "、".join(empty) + " 未产出数据（可能被中断）"}

    # A run recovered from run-state after an interruption. Its numbers are
    # real but INCOMPLETE — the denominator is only the chunks that finished,
    # so a recovered 15/24 must never be read as "62% passed" when the worklist
    # was 45. Red, because the run did not complete and nobody should treat the
    # rate as this night's result.
    incomplete = [
        p for p in expect
        if platforms.get(p, {}).get("present") and platforms[p].get("partial")
    ]
    if incomplete:
        return {"level": "red", "word": "需要处理",
                "reason": "、".join(incomplete) + " 结果不完整（运行被中断，仅部分 chunk 完成）"}

    # A platform that produced a report but passed NOTHING is unambiguously
    # broken — that is the shape both the linux and windows outages took.
    dead = [
        p for p in expect
        if platforms.get(p, {}).get("present")
        and platforms[p].get("chunk_total", 0) > 0
        and platforms[p].get("chunk_passed", 0) == 0
    ]
    if dead:
        return {"level": "red", "word": "需要处理",
                "reason": "、".join(dead) + " 全部失败"}

    # Partial: chunks are failing, but not everything. Deliberately a WARNING
    # and not a failure — there is no pass-rate threshold here (see decision Z
    # below), only the absolute fact that some chunks did not pass.
    # Both platforms reported, and the run is not otherwise broken — but they
    # were built from DIFFERENT engine revisions.  Nothing on the card is then
    # comparable across platforms: every per-platform difference measures the
    # commits in between, not the platform.  Yellow, not red: the build itself
    # succeeded, and the numbers are individually valid; what is lost is the
    # comparison.  Placed after the red conditions so a genuine outage still
    # outranks it.
    if engine_sha_match(platforms) is False:
        return {"level": "yellow", "word": "两平台非同源",
                "reason": "Linux 与 Windows 构建自不同 commit，跨平台差异不可比"}

    partial = [
        (p, platforms[p].get("chunk_passed", 0), platforms[p].get("chunk_total", 0))
        for p in expect
        if platforms.get(p, {}).get("present")
        and platforms[p].get("chunk_total", 0) > 0
        and platforms[p].get("chunk_passed", 0) < platforms[p].get("chunk_total", 0)
    ]
    if partial:
        detail = "、".join(f"{p} {a}/{b}" for p, a, b in partial)
        return {"level": "yellow", "word": "部分通过", "reason": detail}

    return {"level": "green", "word": "正常", "reason": ""}


def compare_previous(cur: dict, prev: dict | None) -> dict:
    """Per-platform delta against the previous run (decision Y).

    Reports a delta only when the previous value is genuinely comparable: same
    engine revision is NOT required, but the previous run must have produced a
    number for the same platform. When there is nothing to compare against we
    say so explicitly rather than showing "±0", which would read as "no change"
    when the truth is "no baseline".
    """
    out = {}
    for plat, info in (cur or {}).items():
        # Only compare runs that actually produced numbers on BOTH sides. A
        # platform with an empty artifact would otherwise show a delta against
        # its zero-valued placeholders, which reads as a real regression.
        if not info.get("present") or not info.get("has_data"):
            continue
        prev_info = (prev or {}).get(plat) or {}
        if not prev_info.get("present") or not prev_info.get("has_data"):
            out[plat] = {"comparable": False}
            continue
        delta = info.get("chunk_passed", 0) - prev_info.get("chunk_passed", 0)
        out[plat] = {
            "comparable": True,
            "delta": delta,
            "prev_passed": prev_info.get("chunk_passed"),
            "prev_total": prev_info.get("chunk_total"),
            # A total change means the worklist itself moved, so the delta is
            # not a like-for-like comparison and must not be shown as one.
            "same_total": info.get("chunk_total") == prev_info.get("chunk_total"),
        }
    return out


def summarise(data: dict | None) -> dict:
    """Reduce a nightly-data payload to the fields the card shows."""
    if not data:
        return {"present": False}
    s = data.get("summary", {}) or {}
    prov = data.get("provenance", {}) or {}
    total = s.get("chunk_total")
    passed = s.get("chunk_passed")
    pct = f"{passed / total * 100:.1f}%" if total else "N/A"
    return {
        # `present` means "the artifact was found"; it does NOT mean it carries
        # results. An interrupted run publishes a payload whose chunk_total is
        # None — the file exists, so present=True, but there is nothing in it.
        # Collapsing those two states to 0 made the card render "✅ 0/0", a
        # tick against a platform that produced no data at all (build 288).
        # `has_data` distinguishes them so callers can say 无数据 instead.
        "present": True,
        "has_data": total is not None and passed is not None,
        "chunk_passed": passed if passed is not None else 0,
        "chunk_total": total if total is not None else 0,
        "chunk_pct": pct,
        # Recovered from run-state after an interruption: the numbers are real
        # but cover only the chunks that finished, so `chunk_total` is not the
        # worklist size. Rendered as "partial" so the rate is never read as a
        # complete run (see summary_from_run_state in publish-nightly-results).
        "partial": bool(s.get("partial")),
        "incomplete": s.get("incomplete_chunks", 0),
        "error_classes": s.get("error_classes", {}) or {},
        # engine_sha is the field that actually identifies what was built;
        # run_id's trailing hash is not trustworthy across platforms (see
        # publish-nightly-results.py).
        "engine_sha": prov.get("engine_sha", "") or "(unrecorded)",
        # Per-chunk real-assertion metrics, used to compute W/L divergence for
        # the card's platform-diff line.  Empty for payloads published before
        # the field existed, in which case the card simply omits the line.
        "chunk_metrics": data.get("chunk_metrics", {}) or {},
        "data_dlls": s.get("data_dlls", 0),
        "total_dlls": data.get("total_dlls", 0),
    }


def build_payload(build_url: str, date_tag: str, run_tag: str,
                  local_linux: Path | None, auth: str,
                  expect: list[str], jenkins_result: str = "",
                  previous: dict | None = None,
                  platform: str = "") -> dict:
    """Assemble the notification payload.

    `platform` selects which archived artifact this run produced (its own). The
    OTHER platform's payload is fetched from the same build; both are needed
    because the card reports on the whole nightly, not just this branch.
    """
    base = build_url.rstrip("/")
    per_platform: dict[str, dict] = {}

    for plat in PLATFORMS:
        name = artifact_name(date_tag, run_tag, plat)
        data = None
        # The linux payload is usually also present locally; prefer the local
        # copy so a controller hiccup cannot blank the main platform.
        if plat == "linux" and local_linux and local_linux.exists():
            try:
                data = json.loads(local_linux.read_text(encoding="utf-8"))
                print(f"  [feishu] {plat}: read local {local_linux}")
            except (OSError, ValueError) as e:
                print(f"  [feishu] {plat}: local read failed ({e}); falling back to HTTP",
                      file=sys.stderr)
        if data is None:
            data = fetch_json(f"{base}/artifact/artifacts/{name}", auth)
            if data is not None:
                print(f"  [feishu] {plat}: fetched {name}")
        per_platform[plat] = summarise(data)

    missing = [p for p in expect if not per_platform.get(p, {}).get("present")]
    v = verdict(per_platform, missing, expect, jenkins_result)
    trend = compare_previous(per_platform, previous)

    # ── Body (decision A: the card answers "do I need to act?" first) ──
    # Order is deliberate: verdict, then the per-platform numbers people
    # actually scan, then the actionable failure reasons, then housekeeping.
    # Anything with nothing to say is omitted entirely rather than rendered as
    # a zero — the old card spent four lines on "0 方法"/"0/0 (N/A)" fields
    # that the Route-3 CLI never populates, which buried the one line that
    # mattered.
    lines: list[str] = []

    icons = {"red": "🔴", "yellow": "🟡", "green": "✅"}
    lines.append(f"{icons.get(v['level'], '⚪')} **{v['word']}**"
                 + (f" — {v['reason']}" if v["reason"] else ""))

    # Which revision both platforms were built from.  Shown only when the two
    # agree (or when only one platform reported), because a mismatch is already
    # stated in the verdict line — repeating it as a header would be noise.
    sha_match = engine_sha_match(per_platform)
    if sha_match is True:
        lines.append(f"engine `{per_platform['linux'].get('engine_sha', '')}`")
    elif sha_match is None and any(
        (per_platform.get(p) or {}).get("has_data") for p in PLATFORMS
    ):
        lines.append("engine `(未记录)`")

    # Cross-platform divergence count.  Only the COUNT — the chunk names belong
    # in the platform-diff artifact, not on a card that is already long.  When
    # the inputs cannot answer the question the line is omitted rather than
    # rendered as 0, which would claim "no platform problems".
    diff_count = count_platform_diffs(per_platform)
    if diff_count:
        lines.append(f"🔀 跨平台差异 {diff_count} 个 chunk（详见 platform-diff 报告）")

    for plat in PLATFORMS:
        info = per_platform.get(plat) or {"present": False}
        label = "Windows" if plat == "windows" else "Linux"
        if not info.get("present"):
            lines.append(f"**{label}**  ⚠️ 无报告")
            continue
        if not info.get("has_data"):
            # Artifact exists but carries no results — an interrupted run
            # publishes exactly this shape. A tick here would claim a healthy
            # platform on a night it produced nothing.
            lines.append(f"**{label}**  ⚠️ 无数据（本轮可能被中断）")
            continue
        passed, total = info["chunk_passed"], info["chunk_total"]
        mark = "❌" if (total and passed == 0) else ("✅" if passed == total else "⚠️")
        row = f"**{label}**  {mark} {passed}/{total}"
        if info.get("partial"):
            # Recovered after an interruption: the denominator is only the
            # chunks that finished, so this is not a comparable pass rate.
            extra = info.get("incomplete") or 0
            row += f"  ⏸ 部分结果（{extra} 个未跑完）" if extra else "  ⏸ 部分结果"
        tt = trend.get(plat) or {}
        if tt.get("comparable") and tt.get("same_total"):
            d = tt["delta"]
            row += "  " + ("↑%d" % d if d > 0 else "↓%d" % -d if d < 0 else "—")
        elif tt and not tt.get("comparable"):
            row += "  (首轮)"
        lines.append(row)

    # Failure reasons, actionable first. "unknown" is a bucket, not a lead —
    # it tells a reader nothing to do — so it is folded into a subdued tail
    # line instead of occupying the same visual weight as a named class.
    for plat in PLATFORMS:
        info = per_platform.get(plat) or {}
        ec = dict(info.get("error_classes") or {})
        if not ec or not info.get("present"):
            continue
        unknown_n = ec.pop("unknown", 0)
        if ec:
            top = "、".join(f"`{k}`×{v}" for k, v in
                            sorted(ec.items(), key=lambda kv: -kv[1])[:4])
            lines.append(f"　{plat} 归因: {top}")
        if unknown_n:
            lines.append(f"　另有 {unknown_n} 个未分类")

    # Provenance one-liner: only if at least one platform reported it.
    shas = {i.get("engine_sha") for i in per_platform.values()
            if i.get("present") and i.get("engine_sha")}
    if len(shas) == 1:
        lines.append(f"　engine `{shas.pop()}`")

    return {
        "platforms": per_platform,
        "missing_platforms": missing,
        "verdict": v,
        "trend": trend,
        "body_lines": lines,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--build-url", required=True)
    ap.add_argument("--date-tag", required=True)
    ap.add_argument("--run-tag", default="run1")
    ap.add_argument("--local-linux-json", default="")
    ap.add_argument("--output", required=True)
    ap.add_argument("--auth", default="", help="user:password for a secured controller")
    ap.add_argument("--expect", default="linux,windows",
                    help="platforms that must be present for a healthy run")
    ap.add_argument("--jenkins-result", default="",
                    help="Jenkins build result; FAILURE/ABORTED forces the red "
                         "verdict regardless of what the payloads say")
    ap.add_argument("--previous-json", default="",
                    help="A previous platform-payload.json for the trend delta "
                         "(decision Y). Absent/absent-platform -> reported as "
                         "'首轮' rather than a misleading 'no change'.")
    args = ap.parse_args()

    local = Path(args.local_linux_json) if args.local_linux_json else None
    previous = None
    if args.previous_json and Path(args.previous_json).exists():
        try:
            previous = json.loads(Path(args.previous_json).read_text(encoding="utf-8"))
        except (OSError, ValueError) as e:
            print(f"  [feishu] previous payload unreadable ({e}); trend disabled",
                  file=sys.stderr)

    payload = build_payload(args.build_url, args.date_tag, args.run_tag,
                            local, args.auth,
                            [p.strip() for p in args.expect.split(",") if p.strip()],
                            jenkins_result=args.jenkins_result,
                            previous=previous)

    Path(args.output).parent.mkdir(parents=True, exist_ok=True)
    Path(args.output).write_text(json.dumps(payload, indent=2, ensure_ascii=False),
                                 encoding="utf-8")
    print(f"  [feishu] payload written to {args.output}")
    for l in payload["body_lines"]:
        print(f"    {l}")
    print(f"  [feishu] verdict: {payload['verdict']['level']} "
          f"{payload['verdict']['word']}")
    if payload["missing_platforms"]:
        print(f"  [feishu] MISSING PLATFORMS: {', '.join(payload['missing_platforms'])}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
