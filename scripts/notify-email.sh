#!/bin/bash
# notify-email.sh — Send HTML email report via sendmail
# Usage: notify-email.sh --to <addr> --subject "..." --body "..."
# Falls back to mailx if sendmail not available

set -euo pipefail

TO=""
SUBJECT="[chaos-ci] Build Report"
BODY=""
FROM="chaos-ci@example.com"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --to)      TO="$2";      shift 2 ;;
        --subject) SUBJECT="$2"; shift 2 ;;
        --body)    BODY="$2";    shift 2 ;;
        --from)    FROM="$2";    shift 2 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

if [[ -z "$TO" ]]; then
    echo "WARNING: No recipient. Skipping email."
    echo "Subject: ${SUBJECT}"
    exit 0
fi

# Try sendmail first, fall back to mailx
if command -v sendmail &>/dev/null; then
    (
        echo "From: ${FROM}"
        echo "To: ${TO}"
        echo "Subject: ${SUBJECT}"
        echo "MIME-Version: 1.0"
        echo "Content-Type: text/html; charset=UTF-8"
        echo ""
        echo "$BODY"
    ) | sendmail -t
    echo "Email sent via sendmail to ${TO}"
elif command -v mail &>/dev/null; then
    echo "$BODY" | mail -a "Content-Type: text/html; charset=UTF-8" \
        -s "$SUBJECT" \
        -r "$FROM" \
        "$TO"
    echo "Email sent via mail to ${TO}"
else
    echo "WARNING: No MTA (sendmail/mailx) available. Email not sent."
    echo "To: ${TO}"
    echo "Subject: ${SUBJECT}"
fi
