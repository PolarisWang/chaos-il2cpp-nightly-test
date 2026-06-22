#!/bin/bash
# notify-feishu.sh — Send build notification to Feishu/Lark via webhook
#
# Usage:
#   notify-feishu.sh --title "..." --message "..." \
#       [--report-link "http://..."] [--build-link "http://..."] \
#       [--color green|red|blue]
#
# Environment:
#   FEISHU_WEBHOOK_URL  (required)

set -euo pipefail

WEBHOOK_URL="${FEISHU_WEBHOOK_URL:-}"
TITLE=""
MESSAGE=""
REPORT_LINK=""
BUILD_LINK=""
COLOR="green"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --title)       TITLE="$2";       shift 2 ;;
        --message)     MESSAGE="$2";     shift 2 ;;
        --message-file) MESSAGE=$(cat "$2"); shift 2 ;;
        --report-link) REPORT_LINK="$2"; shift 2 ;;
        --build-link)  BUILD_LINK="$2";  shift 2 ;;
        --color)       COLOR="$2";       shift 2 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

if [[ -z "$WEBHOOK_URL" ]]; then
    echo "WARNING: FEISHU_WEBHOOK_URL not set. Skipping notification."
    echo "Would send: title='${TITLE}', color=${COLOR}"
    exit 0
fi

if [[ -z "$TITLE" || -z "$MESSAGE" ]]; then
    echo "ERROR: --title and --message are required"
    exit 1
fi

case "$COLOR" in
    red)   FEISHU_COLOR="red"   ;;
    blue)  FEISHU_COLOR="blue"  ;;
    green) FEISHU_COLOR="green" ;;
    *)     FEISHU_COLOR="green" ;;
esac

TIMESTAMP=$(date +%s)

# Write payload via heredoc into a temp file, then use Python to add buttons
_TMPFILE=$(mktemp)
cat > "$_TMPFILE" << PAYLOADEOF
{
    "msg_type": "interactive",
    "card": {
        "header": {
            "title": {"tag": "plain_text", "content": "${TITLE}"},
            "template": "${FEISHU_COLOR}"
        },
        "elements": [
            {
                "tag": "div",
                "text": {"tag": "lark_md", "content": "${MESSAGE}"}
            },
            {"tag": "hr"}
        ]
    }
}
PAYLOADEOF

# Inject action buttons via Python
python3 > /dev/null 2>&1 << PYEOF
import json

with open("$_TMPFILE", "r") as f:
    data = json.load(f)

elements = data["card"]["elements"]
actions = []

if "$REPORT_LINK":
    actions.append({
        "tag": "button",
        "text": {"tag": "plain_text", "content": "📊 查看报告"},
        "url": "$REPORT_LINK",
        "type": "default"
    })

if "$BUILD_LINK":
    actions.append({
        "tag": "button",
        "text": {"tag": "plain_text", "content": "🔧 Jenkins Build"},
        "url": "$BUILD_LINK",
        "type": "default"
    })

if actions:
    elements.append({
        "tag": "action",
        "actions": actions
    })
    elements.append({"tag": "hr"})

# Footer timestamp
elements.append({
    "tag": "note",
    "elements": [
        {"tag": "plain_text", "content": "chaos-il2cpp CI · $(date '+%Y-%m-%d %H:%M:%S')"}
    ]
})

with open("$_TMPFILE", "w") as f:
    json.dump(data, f, ensure_ascii=False)
PYEOF

PAYLOAD=$(cat "$_TMPFILE")
rm -f "$_TMPFILE"

# Send to Feishu
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "$WEBHOOK_URL" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" 2>/dev/null) || HTTP_CODE=000

if [[ "$HTTP_CODE" -ge 200 && "$HTTP_CODE" -lt 300 ]]; then
    echo "Feishu notification sent (HTTP ${HTTP_CODE})"
else
    echo "WARNING: Feishu webhook returned HTTP ${HTTP_CODE}"
fi
