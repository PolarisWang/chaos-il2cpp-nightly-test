#!/bin/bash
# trigger-code-review.sh — Sync booming-il2cpp and trigger Jenkins code review if new commits
#
# Runs every minute via host crontab. Does:
#   1. git fetch + update-ref to sync local repo with GitHub
#   2. Compare HEAD with last-reviewed-commit in state file
#   3. If different (and no active lock), create lock and trigger Jenkins
#
# Lock mechanism: /var/lib/report-server/daily/cr-trigger.lock
#   - Created before triggering Jenkins
#   - Deleted by Jenkins after review completes (Update State stage)
#   - Automatically expires after 30 minutes (prevents stuck state)
# This ensures zero duplicate builds and zero noise.

set -euo pipefail

STATE_FILE="/var/lib/report-server/daily/last-reviewed-commit.json"
LOCK_FILE="/var/lib/report-server/daily/cr-trigger.lock"
BOOMING_DIR="/home/debian/agent/booming-il2cpp"
JENKINS_URL="http://localhost:8080"
JOB_NAME="chaos-il2cpp-code-review"
LOCK_TIMEOUT=1800  # 30 minutes — lock expires after this

# ── Step 1: Sync local repo with GitHub ──
cd "$BOOMING_DIR"
git fetch origin 2>/dev/null || { echo "git fetch failed"; exit 0; }
git update-ref refs/heads/main origin/main 2>/dev/null || true

# ── Step 2: Compare HEAD with last reviewed commit ──
LAST_REVIEWED=$(python3 -c "
import json, sys
try:
    with open('$STATE_FILE') as f:
        print(json.load(f)['last_reviewed_commit'])
except Exception:
    sys.stdout.write('')
" 2>/dev/null) || LAST_REVIEWED=""

CURRENT_HEAD=$(git rev-parse HEAD 2>/dev/null) || CURRENT_HEAD=""

if [ -z "$CURRENT_HEAD" ]; then
    echo "Cannot read HEAD"
    exit 0
fi

if [ -n "$LAST_REVIEWED" ] && [ "$CURRENT_HEAD" = "$LAST_REVIEWED" ]; then
    echo "No new commits (HEAD=$CURRENT_HEAD)"
    exit 0
fi

# ── Step 3: Check lock file (prevents duplicate triggers) ──
if [ -f "$LOCK_FILE" ]; then
    LOCK_AGE=$(( $(date +%s) - $(stat -c %Y "$LOCK_FILE") ))
    if [ "$LOCK_AGE" -lt "$LOCK_TIMEOUT" ]; then
        echo "Lock active ($((LOCK_AGE/60))m old), skipping trigger"
        exit 0
    fi
    echo "Lock stale ($((LOCK_AGE/60))m old), removing"
    rm -f "$LOCK_FILE"
fi

echo "New commits detected: ${LAST_REVIEWED:-none} -> $CURRENT_HEAD"

# ── Step 4: Create lock and trigger Jenkins ──
touch "$LOCK_FILE"

COOKIE_FILE=$(mktemp /tmp/jenkins-cookie.XXXXXX)
trap "rm -f '$COOKIE_FILE'" EXIT

CRUMB=$(curl -s -c "$COOKIE_FILE" "$JENKINS_URL/crumbIssuer/api/json" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['crumb'])" 2>/dev/null) || {
    echo "Failed to get Jenkins crumb"
    rm -f "$LOCK_FILE"
    exit 0
}

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -b "$COOKIE_FILE" \
    -H "Jenkins-Crumb: $CRUMB" \
    -X POST "$JENKINS_URL/job/$JOB_NAME/buildWithParameters" \
    -d "BOOMING_REPO=/home/debian/agent/booming-il2cpp&BUILD_CONFIG=profile" \
    2>/dev/null)

if [ "$HTTP_CODE" != "201" ]; then
    echo "Trigger failed: HTTP $HTTP_CODE"
    rm -f "$LOCK_FILE"
    exit 0
fi

echo "Jenkins triggered: HTTP $HTTP_CODE lock=cr-trigger.lock ($(date '+%Y-%m-%d %H:%M:%S'))"