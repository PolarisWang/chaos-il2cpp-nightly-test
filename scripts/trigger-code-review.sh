#!/bin/bash
# trigger-code-review.sh — Sync booming-il2cpp and trigger Jenkins code review if new commits
#
# Runs every minute via host crontab. Does three things:
#   1. git fetch + update-ref to sync local booming-il2cpp with GitHub
#   2. Compare HEAD with last-reviewed-commit in state file
#   3. If different, trigger Jenkins code-review job via API
#
# This eliminates the Jenkins cron trigger entirely — Jenkins only runs on
# actual new commits, producing zero noise when nothing has changed.

set -euo pipefail

STATE_FILE="/var/lib/report-server/daily/last-reviewed-commit.json"
BOOMING_DIR="/home/debian/agent/booming-il2cpp"
JENKINS_URL="http://localhost:8080"
JOB_NAME="chaos-il2cpp-code-review"

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

echo "New commits detected: ${LAST_REVIEWED:-none} -> $CURRENT_HEAD"

# ── Step 3: Check if Jenkins already has a build queued or running ──
COOKIE_FILE=$(mktemp /tmp/jenkins-cookie.XXXXXX)
trap "rm -f '$COOKIE_FILE'" EXIT

# Get crumb for authenticated API calls
CRUMB=$(curl -s -c "$COOKIE_FILE" "$JENKINS_URL/crumbIssuer/api/json" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['crumb'])" 2>/dev/null) || {
    echo "Failed to get Jenkins crumb"
    exit 0
}

# Check if last build is still running (result = null means running)
LAST_RESULT=$(curl -s -b "$COOKIE_FILE" -H "Jenkins-Crumb: $CRUMB" \
    "$JENKINS_URL/job/$JOB_NAME/lastBuild/api/json" 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('result') or 'RUNNING')" 2>/dev/null || echo "UNKNOWN")

if [ "$LAST_RESULT" = "RUNNING" ]; then
    echo "Last build still running, skipping trigger"
    exit 0
fi

# Check queue for pending code-review items
QUEUE_COUNT=$(curl -s -b "$COOKIE_FILE" -H "Jenkins-Crumb: $CRUMB" \
    "$JENKINS_URL/queue/api/json?tree=items[task[name]]" 2>/dev/null \
    | python3 -c "
import sys,json
d=json.load(sys.stdin)
cr=[i for i in d.get('items',[]) if '$JOB_NAME' in str(i)]
print(len(cr))
" 2>/dev/null || echo "0")

if [ "$QUEUE_COUNT" -gt 0 ]; then
    echo "Build already queued ($QUEUE_COUNT pending), skipping trigger"
    exit 0
fi

# ── Step 4: Trigger Jenkins build ──
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -b "$COOKIE_FILE" \
    -H "Jenkins-Crumb: $CRUMB" \
    -X POST "$JENKINS_URL/job/$JOB_NAME/buildWithParameters" \
    -d "BOOMING_REPO=/booming-il2cpp&BUILD_CONFIG=profile" \
    2>/dev/null)

echo "Jenkins triggered: HTTP $HTTP_CODE ($(date '+%Y-%m-%d %H:%M:%S'))"
