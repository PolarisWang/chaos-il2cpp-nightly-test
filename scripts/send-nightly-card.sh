#!/bin/bash
# send-nightly-card.sh — platform-payload.json → Notice → Feishu card
#
# Routes the nightly build notification through the unified feishu/ engine.
# Replaces the inline Python in Jenkinsfile's sendNightlyNotification.
#
# Usage:
#   send-nightly-card.sh \
#       --payload     <path>  \
#       --build-num   <num>   \
#       --date-tag    <tag>   \
#       --run-tag     <tag>   \
#       --build-url   <url>   \
#       --report-url  <url>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PAYLOAD=""
BUILD_NUM=""
DATE_TAG=""
RUN_TAG="run1"
BUILD_URL=""
REPORT_URL=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --payload)     PAYLOAD="$2";    shift 2 ;;
        --build-num)   BUILD_NUM="$2";  shift 2 ;;
        --date-tag)    DATE_TAG="$2";   shift 2 ;;
        --run-tag)     RUN_TAG="$2";    shift 2 ;;
        --build-url)   BUILD_URL="$2";  shift 2 ;;
        --report-url)  REPORT_URL="$2"; shift 2 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

exec python3 -c "
import sys, os
sys.path.insert(0, '${SCRIPT_DIR}')

from feishu.sources.nightly import to_notice
from feishu.engine import send

n = to_notice(
    '${PAYLOAD}',
    build_num='${BUILD_NUM}',
    date_tag='${DATE_TAG}',
    run_tag='${RUN_TAG}',
    build_url='${BUILD_URL}',
    report_url='${REPORT_URL}',
)
result = send(n, os.environ.get('FEISHU_WEBHOOK_URL', ''), force=True)
sys.exit(0 if result in ('sent', 'deduped') else 1)
" 2>&1