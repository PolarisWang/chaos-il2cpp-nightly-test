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

# Build the payload and send in PYTHON, which escapes the message/title/link values
# correctly. The previous implementation interpolated ${MESSAGE} raw into a JSON
# heredoc, so any multi-line message produced invalid JSON -> python json.load fail ->
# under `set -e` the whole script quietly exits 1 and NOTHING is sent (the monitor's
# failure alerts, which embed newlines, never arrived). Value fields (which can be
# multi-line / contain secrets) are passed as env vars, NOT exported globally.
# FEISHU_WEBHOOK_URL is the only pre-existing env var and is required.
MSG_VALUE="$MESSAGE" TITLE_VALUE="$TITLE" COLOR_VALUE="$FEISHU_COLOR" \
REPORT_VALUE="$REPORT_LINK" BUILD_VALUE="$BUILD_LINK" \
python3 <<'PYEOF'
import json, os, subprocess, sys, datetime

data = {
    "msg_type": "interactive",
    "card": {
        "header": {
            "title": {"tag": "plain_text", "content": os.environ["TITLE_VALUE"]},
            "template": os.environ["COLOR_VALUE"],
        },
        "elements": [
            {"tag": "div", "text": {"tag": "lark_md", "content": os.environ["MSG_VALUE"]}},
            {"tag": "hr"},
        ],
    },
}
els = data["card"]["elements"]
actions = []
for value, text in ((os.environ.get("REPORT_VALUE", ""), "📊 查看报告"),
                    (os.environ.get("BUILD_VALUE", ""), "🔧 Jenkins Build")):
    if value:
        actions.append({"tag": "button", "text": {"tag": "plain_text", "content": text},
                        "url": value, "type": "default"})
if actions:
    els.append({"tag": "action", "actions": actions})
    els.append({"tag": "hr"})
els.append({"tag": "note", "elements": [
    {"tag": "plain_text", "content": "chaos-il2cpp CI · " + datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")}
]})

payload = json.dumps(data, ensure_ascii=False)
webhook = os.environ["FEISHU_WEBHOOK_URL"]
r = subprocess.run(["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                    "-X", "POST", webhook, "-H", "Content-Type: application/json",
                    "-d", payload], capture_output=True, text=True)
code = r.stdout.strip()
print("Feishu notification sent (HTTP %s)" % code if code.startswith(("2", "3"))
      else "WARNING: Feishu webhook returned HTTP %s" % code)
sys.exit(0 if code.startswith(("2", "3")) else 1)
PYEOF
# propagate the send result; on failure surface it to stderr too
RC=$?
if [ "$RC" -ne 0 ]; then
    echo "WARNING: Feishu send failed (rc=$RC)" >&2
fi
exit "$RC"
