#!/bin/bash
# notify-feishu-text.sh — Send plain text message to Feishu/Lark webhook
#
# Non-card format — for code review alerts and simple notifications.
#
# Usage:
#   notify-feishu-text.sh --title "Review Alert" --message "Findings text..." \
#       [--webhook "https://open.feishu.cn/open-apis/bot/v2/hook/..."]
#
# Environment:
#   FEISHU_WEBHOOK_URL  (used as fallback if --webhook not given)

set -euo pipefail

WEBHOOK_URL="${FEISHU_WEBHOOK_URL:-}"
TITLE=""
MESSAGE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --title)   TITLE="$2";   shift 2 ;;
        --message) MESSAGE="$2"; shift 2 ;;
        --webhook) WEBHOOK_URL="$2"; shift 2 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

if [[ -z "$WEBHOOK_URL" ]]; then
    echo "WARNING: FEISHU_WEBHOOK_URL not set. Skipping notification."
    echo "Would send: title='${TITLE}'"
    exit 0
fi

if [[ -z "$MESSAGE" ]]; then
    echo "ERROR: --message is required"
    exit 1
fi

# Build JSON payload via Python (safe from shell injection)
PAYLOAD=$(python3 -c "
import json, sys

title = sys.argv[1] if len(sys.argv) > 1 else ''
message = sys.argv[2] if len(sys.argv) > 2 else ''

text = title + '\n' + message if title else message

# Feishu text message limit is 4096 bytes
text_bytes = text.encode('utf-8')
if len(text_bytes) > 4096:
    text = text_bytes[:4080].decode('utf-8', errors='replace') + '\n... [truncated]'

payload = {'msg_type': 'text', 'content': {'text': text}}
json.dump(payload, sys.stdout, ensure_ascii=False)
" "$TITLE" "$MESSAGE")

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "$WEBHOOK_URL" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" 2>/dev/null) || HTTP_CODE=000

if [[ "$HTTP_CODE" -ge 200 && "$HTTP_CODE" -lt 300 ]]; then
    echo "Feishu text notification sent (HTTP ${HTTP_CODE})"
else
    echo "WARNING: Feishu webhook returned HTTP ${HTTP_CODE}"
fi
