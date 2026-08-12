#!/bin/bash
# trigger-pr-review.sh — Detect new/updated GitHub PRs on booming-il2cpp and trigger
# the chaos-il2cpp-code-review job to review base..head and post to Feishu.
#
# Why a poller instead of a webhook: this box has no public ingress, so GitHub
# cannot call INTO Jenkins. We instead poll GitHub's API for open PRs (outbound
# HTTPS works) and trigger Jenkins via the same crumb+buildWithParameters pattern
# the main-branch poller uses. Covers PRs against ANY base branch (not just main).
#
# Delay is bounded by cron cadence (1 min) + build time.
#
# Dedup: state file /var/lib/report-server/daily/pr-reviewed-head.json maps
#   { "<PR#>": "<head.sha already reviewed>" }.
# The 30-min lock (cr-pr-trigger.lock) prevents double-triggering the same PR
# while a review build is still running (head.sha isn't in state until Jenkins
# finishes and writes it).
#
# Env: none required (reads PAT from the booming repo's git remote).
# Run from host cron:
#   * * * * * .../trigger-pr-review.sh 2>&1 | logger -t cr-pr-trigger

set -euo pipefail

STATE_FILE="/var/lib/report-server/daily/pr-reviewed-head.json"
LOCK_FILE="/var/lib/report-server/daily/cr-pr-trigger.lock"
BOOMING_DIR="/home/debian/agent/booming-il2cpp"
JENKINS_URL="http://localhost:8080"
JOB_NAME="chaos-il2cpp-code-review"
LOCK_TIMEOUT=1800  # 30 minutes
REPO="PolarisWang/booming-il2cpp"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

retry() {
    local n=0
    until "$@"; do
        n=$((n+1))
        if [ "$n" -ge 3 ]; then return 1; fi
        sleep 2
    done
    return 0
}

# ── Step 1: ensure local booming repo is recent (so base commit is present) ──
cd "$BOOMING_DIR"
retry git fetch origin 2>/dev/null || log "git fetch origin failed (after retries); continuing anyway"

# ── Step 2: list open PRs via GitHub API ──
TOKEN=$(git remote get-url origin | sed -n 's#.*://\([^@]*\)@.*#\1#p' || true)
if [ -z "$TOKEN" ]; then
    log "no token found in booming origin URL; cannot query GitHub API"
    exit 0
fi

PRS_JSON=$(retry curl -s --max-time 30 -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$REPO/pulls?state=open&per_page=100") || {
    log "GitHub API PR list failed (after retries)"
    exit 0
}

# ── Step 3: load reviewed-state ──
declare -A REVIEWED
[ -f "$STATE_FILE" ] && eval "$(python3 -c "
import json,sys
try:
    d=json.load(open('$STATE_FILE'))
    for k,v in d.items():
        print('REVIEWED[%s]=%s' % (repr(k), repr(str(v))))
except Exception: pass
")"

# ── Step 4: pick the first PR whose head.sha hasn't been reviewed ──
CHOSEN=$(echo "$PRS_JSON" | python3 -c "
import json,sys
try:
    prs=json.load(sys.stdin)
    if not isinstance(prs,list):
        print(''); sys.exit(0)
    # oldest PR first (stable ordering), skip draft-unsupported heuristics
    for pr in sorted(prs, key=lambda p:p.get('number',0)):
        n=pr.get('number'); head=pr.get('head',{}).get('sha','')
        base=pr.get('base',{}).get('sha','')
        title=pr.get('title','')
        print('%s|%s|%s|%s' % (n, head, base, str(title).replace('|','/')))
        break  # caller evaluates; only expose the oldest candidate
except Exception:
    print('')
" 2>/dev/null)

if [ -z "$CHOSEN" ]; then
    log "no open PRs to review"
    exit 0
fi

PR_NUM="${CHOSEN%%|*}"; REST="${CHOSEN#*|}"
PR_HEAD="${REST%%|*}"; REST="${REST#*|}"
PR_BASE="${REST%%|*}"; PR_TITLE="${REST#*|}"

if [ -n "${REVIEWED[$PR_NUM]:-}" ] && [ "${REVIEWED[$PR_NUM]}" = "$PR_HEAD" ]; then
    log "PR #${PR_NUM} head ${PR_HEAD:0:8} already reviewed; skip"
    exit 0
fi

# ── Step 5: fetch the PR head into the local repo (so Jenkins can diff base..head) ──
log "PR #${PR_NUM} needs review: base ${PR_BASE:0:8}..head ${PR_HEAD:0:8}"
retry git fetch origin "refs/pull/${PR_NUM}/head:refs/remotes/origin/pr-${PR_NUM}" 2>/dev/null || {
    log "failed to fetch PR #${PR_NUM} head (after retries); skipping"
    exit 0
}

# ── Step 6: lock + trigger Jenkins (crumb+cookie, same as trigger-code-review) ──
if [ -f "$LOCK_FILE" ]; then
    LOCK_AGE=$(( $(date +%s) - $(stat -c %Y "$LOCK_FILE") ))
    if [ "$LOCK_AGE" -lt "$LOCK_TIMEOUT" ]; then
        log "lock active ($((LOCK_AGE/60))m old); skip trigger"
        exit 0
    fi
    log "lock stale ($((LOCK_AGE/60))m old); removing"
    rm -f "$LOCK_FILE"
fi
touch "$LOCK_FILE"

COOKIE_FILE=$(mktemp /tmp/jenkins-cookie.XXXXXX)
trap "rm -f '$COOKIE_FILE'" EXIT

CRUMB=$(curl -s -c "$COOKIE_FILE" "$JENKINS_URL/crumbIssuer/api/json" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['crumb'])" 2>/dev/null) || {
    log "failed to get Jenkins crumb"
    rm -f "$LOCK_FILE"
    exit 0
}

# URL-encode title for the form body
PR_TITLE_ENC=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$PR_TITLE" 2>/dev/null || echo "")

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -b "$COOKIE_FILE" \
    -H "Jenkins-Crumb: $CRUMB" \
    -X POST "$JENKINS_URL/job/$JOB_NAME/buildWithParameters" \
    --data-urlencode "BOOMING_REPO=/home/debian/agent/booming-il2cpp" \
    --data-urlencode "BUILD_CONFIG=profile" \
    --data-urlencode "REVIEW_BASE=$PR_BASE" \
    --data-urlencode "REVIEW_HEAD=$PR_HEAD" \
    --data-urlencode "REVIEW_PR_NUMBER=$PR_NUM" \
    --data-urlencode "REVIEW_PR_TITLE=$PR_TITLE" \
    2>/dev/null)

if [ "$HTTP_CODE" != "201" ]; then
    log "trigger failed: HTTP $HTTP_CODE"
    rm -f "$LOCK_FILE"
    exit 0
fi

log "jenkins triggered for PR #${PR_NUM}: HTTP $HTTP_CODE (lock=cr-pr-trigger.lock)"
