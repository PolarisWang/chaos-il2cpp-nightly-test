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
    suffix = "-win" if platform == "windows" else ""
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
        "present": True,
        "chunk_passed": passed if passed is not None else 0,
        "chunk_total": total if total is not None else 0,
        "chunk_pct": pct,
        "error_classes": s.get("error_classes", {}) or {},
        # engine_sha is the field that actually identifies what was built;
        # run_id's trailing hash is not trustworthy across platforms (see
        # publish-nightly-results.py).
        "engine_sha": prov.get("engine_sha", "") or "(unrecorded)",
        "data_dlls": s.get("data_dlls", 0),
        "total_dlls": data.get("total_dlls", 0),
    }


def build_payload(build_url: str, date_tag: str, run_tag: str,
                  local_linux: Path | None, auth: str,
                  expect: list[str]) -> dict:
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

    # Build the human-readable body.
    lines: list[str] = []
    for plat in PLATFORMS:
        info = per_platform[plat]
        label = "🪟 Windows" if plat == "windows" else "🐧 Linux"
        if not info["present"]:
            lines.append(f"**{label}:** ⚠️ 无数据（该平台本轮未产出报告）")
            continue
        lines.append(
            f"**{label}:** {info['chunk_passed']}/{info['chunk_total']} "
            f"({info['chunk_pct']}) · engine `{info['engine_sha']}`"
        )
        ec = info.get("error_classes") or {}
        if ec:
            top = "、".join(f"{k}×{v}" for k, v in
                            sorted(ec.items(), key=lambda kv: -kv[1])[:5])
            lines.append(f"　└ 失败归因: {top}")

    # Headline status: fail if the notified build failed OR any expected
    # platform produced nothing — an absent platform is a real problem, not a
    # detail to bury.
    return {
        "platforms": per_platform,
        "missing_platforms": missing,
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
    args = ap.parse_args()

    local = Path(args.local_linux_json) if args.local_linux_json else None
    payload = build_payload(args.build_url, args.date_tag, args.run_tag,
                            local, args.auth,
                            [p.strip() for p in args.expect.split(",") if p.strip()])

    Path(args.output).parent.mkdir(parents=True, exist_ok=True)
    Path(args.output).write_text(json.dumps(payload, indent=2, ensure_ascii=False),
                                 encoding="utf-8")
    print(f"  [feishu] payload written to {args.output}")
    for l in payload["body_lines"]:
        print(f"    {l}")
    if payload["missing_platforms"]:
        print(f"  [feishu] MISSING PLATFORMS: {', '.join(payload['missing_platforms'])}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
