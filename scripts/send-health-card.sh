#!/bin/bash
# send-health-card.sh — Health/monitor alert → Notice → Feishu card
#
# Routes system health alerts through the unified feishu/ engine.
# Called by monitor.sh and monitor-il2cpp-review.sh.
#
# The caller supplies the alert's narrative directly (impact / cause / action)
# because those strings are already computed at the call site with knowledge
# this script does not have (lock age, outage duration, unreviewed count).
# The source module decides the LEVEL and the title decorator.
#
# Usage:
#   send-health-card.sh \
#       --event new_failure|recovered|sustained_failure|stuck_lock|stalled|system \
#       --title "代码审查构建失败" \
#       --impact "..." --cause "..." --action "..." \
#       [--build-link URL] [--report-link URL] [--date-tag TAG]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

EVENT="system"
TITLE=""
IMPACT=""
CAUSE=""
ACTION=""
BUILD_LINK=""
REPORT_LINK=""
DATE_TAG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --event)       EVENT="$2";       shift 2 ;;
        --title)       TITLE="$2";       shift 2 ;;
        --impact)      IMPACT="$2";      shift 2 ;;
        --cause)       CAUSE="$2";       shift 2 ;;
        --action)      ACTION="$2";      shift 2 ;;
        --build-link)  BUILD_LINK="$2";  shift 2 ;;
        --report-link) REPORT_LINK="$2"; shift 2 ;;
        --date-tag)    DATE_TAG="$2";    shift 2 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

exec python3 - "$EVENT" "$TITLE" "$IMPACT" "$CAUSE" "$ACTION" \
                "$BUILD_LINK" "$REPORT_LINK" "$DATE_TAG" "$SCRIPT_DIR" <<'PYEOF' 2>&1
import sys, os
sys.path.insert(0, sys.argv[9])

from feishu.engine import send
from feishu.sources.health import notice_from_alert

event, title, impact, cause, action = sys.argv[1:6]
build_link, report_link, date_tag = sys.argv[6:9]

n = notice_from_alert(
    event=event, title=title, impact=impact, cause=cause, action=action,
    build_link=build_link, report_link=report_link, date_tag=date_tag,
)
result = send(n, os.environ.get('FEISHU_WEBHOOK_URL', ''), force=True)
sys.exit(0 if result in ('sent', 'deduped') else 1)
PYEOF