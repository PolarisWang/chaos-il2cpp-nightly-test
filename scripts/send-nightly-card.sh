#!/bin/bash
# send-nightly-card.sh — platform-payload.json → Notice → Feishu card
#
# Routes the nightly build notification through the unified feishu/ engine.
# Replaces the inline Python in Jenkinsfile's sendNightlyNotification.
#
# Usage:
#   send-nightly-card.sh \
#       --payload       <path>  \
#       --build-num     <num>   \
#       --date-tag      <tag>   \
#       --run-tag       <tag>   \
#       --build-url     <url>   \
#       --report-url    <url>   \
#       [--status SUCCESS] [--jenkins-color green] \
#       [--data-json '<json>']
#
# --data-json carries the metric/fail fields the card renders but which do not
# live in platform-payload.json (fact_*, bmk_methods, hot_*, mem_*, fail_lines).
# The Jenkinsfile assembles it from the nightly-data JSON.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PAYLOAD=""
BUILD_NUM=""
DATE_TAG=""
RUN_TAG="run1"
BUILD_URL=""
REPORT_URL=""
STATUS=""
JENKINS_COLOR="green"
DATA_JSON="{}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --payload)       PAYLOAD="$2";       shift 2 ;;
        --build-num)     BUILD_NUM="$2";     shift 2 ;;
        --date-tag)      DATE_TAG="$2";      shift 2 ;;
        --run-tag)       RUN_TAG="$2";       shift 2 ;;
        --build-url)     BUILD_URL="$2";     shift 2 ;;
        --report-url)    REPORT_URL="$2";    shift 2 ;;
        --status)        STATUS="$2";        shift 2 ;;
        --jenkins-color) JENKINS_COLOR="$2"; shift 2 ;;
        --data-json)     DATA_JSON="$2";     shift 2 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

export NIGHTLY_PAYLOAD="$PAYLOAD"
export NIGHTLY_BUILD_NUM="$BUILD_NUM"
export NIGHTLY_DATE_TAG="$DATE_TAG"
export NIGHTLY_RUN_TAG="$RUN_TAG"
export NIGHTLY_BUILD_URL="$BUILD_URL"
export NIGHTLY_REPORT_URL="$REPORT_URL"
export NIGHTLY_STATUS="$STATUS"
export NIGHTLY_JENKINS_COLOR="$JENKINS_COLOR"
export NIGHTLY_DATA_JSON="$DATA_JSON"

exec python3 - "${SCRIPT_DIR}" <<'PYEOF' 2>&1
import sys, os, json
sys.path.insert(0, sys.argv[1])

from feishu.sources.nightly import to_notice
from feishu.engine import send

try:
    extra = json.loads(os.environ.get('NIGHTLY_DATA_JSON') or '{}')
except Exception:
    extra = {}
if not isinstance(extra, dict):
    extra = {}

n = to_notice(
    os.environ.get('NIGHTLY_PAYLOAD', ''),
    build_num=os.environ.get('NIGHTLY_BUILD_NUM', ''),
    date_tag=os.environ.get('NIGHTLY_DATE_TAG', ''),
    run_tag=os.environ.get('NIGHTLY_RUN_TAG', 'run1'),
    status=os.environ.get('NIGHTLY_STATUS', ''),
    jenkins_color=os.environ.get('NIGHTLY_JENKINS_COLOR', 'green'),
    build_url=os.environ.get('NIGHTLY_BUILD_URL', ''),
    report_url=os.environ.get('NIGHTLY_REPORT_URL', ''),
    data=extra,
)
result = send(n, os.environ.get('FEISHU_WEBHOOK_URL', ''), force=True)
sys.exit(0 if result in ('sent', 'deduped') else 1)
PYEOF