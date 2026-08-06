#!/bin/bash
# monitor-il2cpp-review.sh — Alert when the chaos-il2cpp-code-review Jenkins job fails.
#
# Why: the review job previously ran red for dozens of builds (474–481) with nobody
# noticing — there was no monitor on the job's result. monitor.sh checks docker/HTTP,
# ops/healthcheck.sh checks the Feishu *event bot*, neither watches this job's builds.
#
# Reads the job's last completed build.xml directly from the Jenkins controller
# filesystem (no Jenkins auth/CSRF dependency), so it works even if the API or
# anonymous read is locked down.
#
# Alert policy (deduped so a red job doesn't spam the group every 5 min):
#   - New failure : last completed build went SUCCESS -> FAILURE     → alert now
#   - Sustained   : job FAILURE for > FAILURE_SILENCE_H (silence window)
#                   → re-alert after the silence window elapses (reminder)
#   - Recovery    : FAILURE -> SUCCESS                               → "已恢复"
#
# Run from host cron every 5 minutes. Env:
#   FEISHU_WEBHOOK_URL (required; passed to notify-feishu.sh)
#   STATE_FILE         (default /var/lib/report-server/daily/il2cpp-review-monitor-state.json)
#   MOUNTED_MASTER     (bind path to the jenkins controller jobs dir, default via docker exec)
#   FAILURE_SILENCE_H  (default 4)
#
# Usage: scripts/monitor-il2cpp-review.sh

set -u
DID=$(cd "$(dirname "$0")" && pwd)                      # scripts/ dir
CONTAINER="${CONTAINER:-chaos-master}"
JOBS_DIR_CT="${JOBS_DIR_CT:-/var/jenkins_home/jobs/chaos-il2cpp-code-review/builds}"
STATE_FILE="${STATE_FILE:-/var/lib/report-server/daily/il2cpp-review-monitor-state.json}"
FAILURE_SILENCE_H="${FAILURE_SILENCE_H:-4}"
NOTIFY="$DID/notify-feishu.sh"
JENKINS_URL="${JENKINS_URL:-http://localhost:8080/job/chaos-il2cpp-code-review}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# Find the newest build with a terminal result (skip the running/in-progress one).
# Jenkins writes <result> only when a build finishes; a still-running build has none.
newest_completed() {
    sudo docker exec "$CONTAINER" bash -c "
        newest=''
        for f in \$(ls -t '$JOBS_DIR_CT' 2>/dev/null | grep -E '^[0-9]+\$'); do
            if grep -q '<result>' '$JOBS_DIR_CT'/\$f/build.xml 2>/dev/null; then
                newest=\$f; break
            fi
        done
        echo \"\$newest\"
    " 2>/dev/null
}

read_field() {
    local build="$1" field="$2"
    sudo docker exec "$CONTAINER" bash -c "
        grep -oE '<$field>[^<]+' '$JOBS_DIR_CT'/$build/build.xml 2>/dev/null | head -1 | grep -oE '[^>]+$'
    " 2>/dev/null
}

alert() {
    local title="$1" body="$2"
    if [ -n "${FEISHU_WEBHOOK_URL:-}" ]; then
        FEISHU_WEBHOOK_URL="$FEISHU_WEBHOOK_URL" bash "$NOTIFY" \
            --title "$title" --message "$body" --color red --build-link "$JENKINS_URL" >/dev/null 2>&1 \
            && log "alert sent: $title" || log "alert FAILED to send: $title"
    else
        log "(FEISHU_WEBHOOK_URL unset; skipping alert) $title"
    fi
}

# ── Load previous state ──
prev='{}'
[ -f "$STATE_FILE" ] && prev="$(cat "$STATE_FILE")"
PREV_STATUS=$(echo "$prev" | python3 -c "import sys,json;
try: print(json.load(sys.stdin).get('status',''))
except Exception: print('')" 2>/dev/null)
LAST_ALERT_TS=$(echo "$prev" | python3 -c "import sys,json;
try: print(json.load(sys.stdin).get('last_alert_ts',''))
except Exception: print('')" 2>/dev/null)

# ── Read latest completed build ──
B=$(newest_completed)
if [ -z "$B" ]; then
    log "no completed build found under $JOBS_DIR_CT — cannot check"
    exit 0
fi
RESULT=$(read_field "$B" result)
NUM=$(read_field "$B" number); NUM="${NUM:-$B}"   # build.xml may omit <number>; fall back to dir name
TS=$(read_field "$B" timestamp)
TS=${TS:0:10}
WHEN=$(date -d "@$TS" '+%m-%d %H:%M' 2>/dev/null || echo "$TS")

STATUS='OK'
if [ "$RESULT" != "SUCCESS" ]; then
    STATUS='FAIL'
    # Show which stage failed if the log marks it (best-effort, non-fatal).
    broken=$(sudo docker exec "$CONTAINER" bash -c "
        tail -c 4000 '$JOBS_DIR_CT'/\$B/log 2>/dev/null" 2>/dev/null \
        | grep -aoE 'ERROR: [A-Za-z0-9 _/.:-]{4,60}|Failed in branch [A-Za-z0-9/ _-]{2,40}' | tail -1)
fi
log "job latest completed build #${NUM} = ${RESULT:-?} (${WHEN}) ${broken:+[${broken}]}"

now=$(date +%s)
NEW_FAILURE=''
RECOVERED=''
REALERT=''

if [ "$STATUS" = "FAIL" ] && [ "$PREV_STATUS" != "FAIL" ]; then
    NEW_FAILURE=1
elif [ "$STATUS" = "FAIL" ] && [ "$PREV_STATUS" = "FAIL" ] \
     && [ -n "$LAST_ALERT_TS" ] && [ $(( now - LAST_ALERT_TS )) -ge $((FAILURE_SILENCE_H*3600)) ]; then
    REALERT=1
elif [ "$STATUS" = "OK" ] && [ "$PREV_STATUS" = "FAIL" ]; then
    RECOVERED=1
fi

# ── Persist state ──
mkdir -p "$(dirname "$STATE_FILE")"
cat >"$STATE_FILE" <<JSON
{"status":"$STATUS","build_num":"$NUM","result":"$RESULT","last_alert_ts":$([[ -n "$NEW_FAILURE$REALERT" ]] && echo "$now" || echo "${LAST_ALERT_TS:-0}")}
JSON

# ── Notify on transitions ──
if [ -n "$NEW_FAILURE" ]; then
    alert "⚠️ IL2CPP Code Review 构建失败" \
"job chaos-il2cpp-code-review 最近完成构建 #${NUM} = ${RESULT}（${WHEN}）。
${broken:+失败环节：${broken}\n}
打开 Jenkins: ${JENKINS_URL}"
elif [ -n "$RECOVERED" ]; then
    alert "✅ IL2CPP Code Review 已恢复" \
"job 最近完成构建 #${NUM} = SUCCESS。\n${JENKINS_URL}"
elif [ -n "$REALERT" ]; then
    alert "⚠️ IL2CPP Code Review 持续失败" \
"job 从 ${PREV_STATUS} 起持续失败，最近完成构建 #${NUM} = ${RESULT}（${WHEN}）。
${broken:+失败环节：${broken}\n}
打开 Jenkins: ${JENKINS_URL}"
else
    log "no status transition (${PREV_STATUS} -> $STATUS)"
fi
exit 0
