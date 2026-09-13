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
# Jenkins writes <result>... randomly into build.xml at build start as a placeholder,
# and the build is never re-read after it finishes.  So we must check BOTH:
#   1. The build has a <result> tag (it has started)
#   2. The build has a non-zero <duration> (it has finished — Jenkins only writes
#      duration at completion) OR the log ends with "Finished: " (durable result).
# A build that just started has <result>SUCCESS</result> before it actually runs
# anything, so we can't trust it until we see the duration.
newest_completed() {
    sudo docker exec "$CONTAINER" bash -c "
        newest=''
        for f in \$(ls -t '$JOBS_DIR_CT' 2>/dev/null | grep -E '^[0-9]+\$'); do
            xml='$JOBS_DIR_CT'/\$f/build.xml
            if [ -f \"\$xml\" ] && grep -q '<result>' \"\$xml\"; then
                # Check duration > 0 = build completed.  duration=0 means still running
                # (it was written at start time).  Also check the log ends with
                # 'Finished: ' as a second signal.
                dur=\$(grep -oE '<duration>[0-9]+' \"\$xml\" | grep -oE '[0-9]+')
                log='$JOBS_DIR_CT'/\$f/log
                finished=''
                [ -f \"\$log\" ] && finished=\$(grep -c 'Finished:' \"\$log\" 2>/dev/null || echo 0)
                if [ \"\${dur:-0}\" -gt 0 ] || [ \"\${finished:-0}\" -gt 0 ]; then
                    newest=\$f; break
                fi
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

# alert <level> <title> <impact> <cause> <action>
# Routes through the unified incident-card template so every abnormal message
# reads the same way: action-level tag, impact, cause, suggested action.
#   level: RED | YELLOW | INFO | RECOVERED
# Falls back to the legacy plain notifier if incident-card.py is unavailable,
# so a broken template can never silence the monitor entirely.
INCIDENT_CARD="$DID/incident-card.py"
alert() {
    local level="$1" title="$2" impact="${3:-}" cause="${4:-}" action="${5:-}"
    if [ -z "${FEISHU_WEBHOOK_URL:-}" ]; then
        log "(FEISHU_WEBHOOK_URL unset; skipping alert) [$level] $title"
        return 0
    fi
    if [ -f "$INCIDENT_CARD" ]; then
        FEISHU_WEBHOOK_URL="$FEISHU_WEBHOOK_URL" python3 "$INCIDENT_CARD" \
            --level "$level" --title "$title" \
            --impact "$impact" --cause "$cause" --action "$action" \
            --build-link "$JENKINS_URL" --report-link "$JENKINS_URL" \
            >/dev/null 2>&1 \
            && log "alert sent: [$level] $title" \
            || log "alert FAILED to send: [$level] $title"
    else
        FEISHU_WEBHOOK_URL="$FEISHU_WEBHOOK_URL" bash "$NOTIFY" \
            --title "$title" --message "$impact" --color red --build-link "$JENKINS_URL" >/dev/null 2>&1 \
            && log "alert sent (legacy): $title" || log "alert FAILED (legacy): $title"
    fi
}

# failure_cause <raw-error-text> → human-readable cause string
failure_cause() {
    local t="$1"
    case "$t" in
        *"exit code 129"*)            echo "审查脚本参数错误（git 调用失败）—— 超大 diff 合并 chunk 时触发，脚本 bug，不会自愈" ;;
        *"Argument list too long"*|*ARG_MAX*) echo "文件列表过长超出系统限制（ARG_MAX）—— 大 diff 时触发，脚本 bug，不会自愈" ;;
        *"exit code 137"*)            echo "审查进程被系统终止（内存不足）" ;;
        *[Tt]imeout*)                 echo "审查超时（模型响应超过阈值）" ;;
        *"Failed in branch"*)         echo "构建分支失败（非审查环节）" ;;
        *)                            echo "审查流程异常，需查看构建日志定位" ;;
    esac
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
        tail -c 4000 '$JOBS_DIR_CT'/$B/log 2>/dev/null" 2>/dev/null \
        | grep -aoE 'ERROR: [A-Za-z0-9 _/.:-]{4,60}|Failed in branch [A-Za-z0-9/ _-]{2,40}' | tail -1)
fi
log "job latest completed build #${NUM} = ${RESULT:-?} (${WHEN}) ${broken:+[${broken}]}"

# ── Stuck-lock check (#16) ──
# Nothing else in the system watches cr-trigger.lock.  If it ages past the
# poller's LOCK_TIMEOUT, every subsequent review is silently blocked.  Alert
# (deduped via the same alert-state file) whenever the lock is overdue.
LOCK_FILE="/var/lib/report-server/daily/cr-trigger.lock"
LOCK_TIMEOUT="${LOCK_TIMEOUT:-1200}"
if [ -f "$LOCK_FILE" ]; then
    LOCK_AGE=$(( $(date +%s) - $(stat -c %Y "$LOCK_FILE" 2>/dev/null || echo 0) ))
    if [ "$LOCK_AGE" -gt "$((LOCK_TIMEOUT + 300))" ]; then
        log "WARNING: cr-trigger.lock is ${LOCK_AGE}s old (> timeout ${LOCK_TIMEOUT}s) — reviews are blocked"
        alert "RED" "代码审查已阻塞" \
"触发锁已持有 $(( LOCK_AGE/60 )) 分钟（阈值 $(( LOCK_TIMEOUT/60 )) 分钟）
后续所有提交都无法触发审查" \
"上一次审查未正常释放锁（可能构建中断 / 脚本异常退出）" \
"清除锁：rm -f ${LOCK_FILE}"
    fi
fi

# ── Silent-stoppage check (#15) ──
# The build-result monitor only sees FAILURE/SUCCESS; a review that stops being
# *triggered entirely* (poller dead, state wedged) looks like a healthy idle
# pipeline.  Alert if the state is behind HEAD **and stays behind** — a mere
# "state behind HEAD right now" is NORMAL: the state only advances after a
# review completes, so during an in-flight review it is always behind.
# Guard against false positives:
#   * a lock present means the poller just triggered / a review is running → OK
#   * a build started within the last BUILD_GRACE_S → OK
#   * require the state to have been behind for STALL_S since the last build
STATE_FILE_CR="/var/lib/report-server/daily/last-reviewed-commit.json"
BOOMING_DIR="${BOOMING_DIR:-/home/debian/agent/booming-il2cpp}"
STALL_S="${STALL_S:-3600}"          # 1h without any build while behind → stalled
BUILD_GRACE_S="${BUILD_GRACE_S:-600}"
if [ -f "$STATE_FILE_CR" ] && [ -d "$BOOMING_DIR/.git" ]; then
    LAST_REVIEWED=$(python3 -c "import json;print(json.load(open('$STATE_FILE_CR')).get('last_reviewed_commit',''))" 2>/dev/null || echo "")
    REPO_HEAD=$(git -C "$BOOMING_DIR" rev-parse HEAD 2>/dev/null || echo "")
    if [ -n "$LAST_REVIEWED" ] && [ -n "$REPO_HEAD" ] && [ "$LAST_REVIEWED" != "$REPO_HEAD" ]; then
        BEHIND=$(git -C "$BOOMING_DIR" rev-list --count "$LAST_REVIEWED".."$REPO_HEAD" 2>/dev/null || echo 0)
        RECENT_BUILD=0
        if [ -n "$TS" ] && [ "$(( $(date +%s) - TS ))" -lt "$BUILD_GRACE_S" ]; then
            RECENT_BUILD=1
        fi
        if [ -f "$LOCK_FILE" ]; then
            # A lock exists: poller is mid-cycle or a review is running.  Normal.
            log "state behind HEAD by ${BEHIND}, but lock present — review likely in flight (OK)"
        elif [ "$RECENT_BUILD" = "1" ]; then
            log "state behind HEAD by ${BEHIND}, but a build ran recently (${WHEN}) — OK"
        else
            NOW=$(date +%s)
            LAST_BUILD_AGE=$(( NOW - ${TS:-0} ))
            if [ "$LAST_BUILD_AGE" -gt "$STALL_S" ]; then
                log "WARNING: state behind HEAD by ${BEHIND}, no build for $(( LAST_BUILD_AGE/60 ))m — likely stalled"
                alert "RED" "代码审查可能已停止" \
"状态落后仓库 HEAD ${BEHIND} 个提交
已 $(( LAST_BUILD_AGE/60 )) 分钟没有新的审查构建（且无锁占用）" \
"触发轮询停止 / 状态文件损坏
last_reviewed: ${LAST_REVIEWED:0:10}
repo HEAD:     ${REPO_HEAD:0:10}
上次构建:      #${NUM} ${WHEN}" \
"检查 poller cron 是否仍在运行（trigger-code-review.sh）"
            else
                log "state behind HEAD by ${BEHIND}, last build ${WHEN} — within grace, OK"
            fi
        fi
    fi
fi

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
CAUSE="$(failure_cause "${broken:-}")"

if [ -n "$NEW_FAILURE" ]; then
    alert "RED" "代码审查构建失败" \
"构建 #${NUM} = ${RESULT}（${WHEN}）
本次提交未被审查，飞书无审查卡片" \
"${CAUSE}" \
"查看构建日志定位失败环节（Jenkins 构建 #${NUM}）"
elif [ -n "$RECOVERED" ]; then
    # Quantify the outage: how long it was broken and how much went unreviewed.
    OUTAGE_MIN=$(( (now - ${LAST_ALERT_TS:-$now}) / 60 ))
    alert "RECOVERED" "代码审查已恢复正常" \
"构建 #${NUM} = SUCCESS
中断时长约 ${OUTAGE_MIN} 分钟" \
"" \
"无需操作"
elif [ -n "$REALERT" ]; then
    # Cumulative impact, not a repeat of the first alert. The first alert said
    # "it broke"; this one must say "it is STILL broken and here is the cost".
    SUSTAINED_H=$(( (now - ${LAST_ALERT_TS:-$now}) / 3600 ))
    # Compute the unreviewed count here rather than reusing LAST_REVIEWED/
    # REPO_HEAD — those are only assigned inside the silent-stoppage guard
    # (which closes well above this block) and may be unset.
    UNREVIEWED=0
    _lr=$(python3 -c "import json;print(json.load(open('$STATE_FILE_CR')).get('last_reviewed_commit',''))" 2>/dev/null || echo "")
    _rh=$(git -C "$BOOMING_DIR" rev-parse HEAD 2>/dev/null || echo "")
    if [ -n "$_lr" ] && [ -n "$_rh" ]; then
        UNREVIEWED=$(git -C "$BOOMING_DIR" rev-list --count "$_lr".."$_rh" 2>/dev/null || echo 0)
    fi
    alert "RED" "代码审查持续失败" \
"最近完成构建 #${NUM} = ${RESULT}（${WHEN}）
已持续失败约 ${SUSTAINED_H} 小时
期间约 ${UNREVIEWED} 个提交未被审查" \
"根因与首次告警相同：${CAUSE}" \
"该问题不会自愈，需人工修复"
else
    log "no status transition (${PREV_STATUS} -> $STATUS)"
fi
exit 0
