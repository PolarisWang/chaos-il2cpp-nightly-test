#!/bin/bash
# notify-feishu.sh — Send build notification to Feishu/Lark via webhook
# Usage: notify-feishu.sh --title "..." --message "..." --link "..." [--color green|red|blue]

set -euo pipefail

WEBHOOK_URL="${FEISHU_WEBHOOK_URL:-}"
TITLE="Build Notification"
MESSAGE=""
LINK=""
COLOR="green"  # green, red, blue

while [[ $# -gt 0 ]]; do
    case "$1" in
        --title)   TITLE="$2";   shift 2 ;;
        --message) MESSAGE="$2"; shift 2 ;;
        --link)    LINK="$2";    shift 2 ;;
        --color)   COLOR="$2";   shift 2 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

if [[ -z "$WEBHOOK_URL" ]]; then
    echo "WARNING: FEISHU_WEBHOOK_URL not set. Skipping notification."
    echo "Would send: title='${TITLE}', color=${COLOR}, link=${LINK}"
    exit 0
fi

# Map color to Feishu card template color
case "$COLOR" in
    red)   FEISHU_COLOR="red" ;;
    blue)  FEISHU_COLOR="blue" ;;
    green) FEISHU_COLOR="green" ;;
    *)     FEISHU_COLOR="green" ;;
esac

TIMESTAMP=$(date +%s)

# Build JSON payload for Feishu interactive card
PAYLOAD=$(cat << PAYLOADEOF || true
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
            {
                "tag": "hr"
            },
            {
                "tag": "note",
                "elements": [
                    {
                        "tag": "plain_text",
                        "content": "chaos-il2cpp CI · $(date '+%Y-%m-%d %H:%M:%S')"
                    }
                ]
            }
        ]
    }
}
PAYLOADEOF

if [[ -n "$LINK" ]]; then
    # Add a button link at the end
    PAYLOAD=$(echo "$PAYLOAD" | python3 -c "
import json, sys
data = json.load(sys.stdin)
data['card']['elements'].insert(-1, {
    'tag': 'action',
    'actions': [{
        'tag': 'button',
        'text': {'tag': 'plain_text', 'content': '查看详情'},
        'url': '${LINK}',
        'type': 'default'
    }]
})
json.dump(data, sys.stdout, ensure_ascii=False)
")
fi

# Send to Feishu
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "$WEBHOOK_URL" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" 2>/dev/null)

if [[ "$HTTP_CODE" -ge 200 && "$HTTP_CODE" -lt 300 ]]; then
    echo "Feishu notification sent (HTTP ${HTTP_CODE})"
else
    echo "WARNING: Feishu webhook returned HTTP ${HTTP_CODE}"
fi
