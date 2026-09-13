#!/bin/bash
# monitor.sh — System health monitor with Feishu alerting
#
# Runs via crontab every 5 minutes. Checks system resources, Docker containers,
# critical services, and recent anomalies. Sends Feishu notification on
# state changes (issue detected → alert, issue cleared → recovery).
#
# State is tracked in MONITOR_STATE_FILE to suppress duplicate alerts.
#
# Environment:
#   FEISHU_WEBHOOK_URL  (required; falls back to docker-compose value)
#   MONITOR_STATE_FILE  (default: /var/lib/report-server/daily/monitor-state.json)
#   MONITOR_DRY_RUN     (set to "1" to print instead of sending)

set -euo pipefail

# ── Config ──────────────────────────────────────────────────────────
readonly PROGNAME="monitor"
FEISHU_WEBHOOK_URL="${FEISHU_WEBHOOK_URL:-https://open.feishu.cn/open-apis/bot/v2/hook/9ba5e264-6486-4ba6-abd3-094bb4d923ff}"
MONITOR_STATE_FILE="${MONITOR_STATE_FILE:-/var/lib/report-server/daily/monitor-state.json}"
readonly LOCK_FILE="/tmp/${PROGNAME}.lock"
readonly NOTIFY_SCRIPT="/home/debian/agent/chaos-il2cpp-nightly-test/scripts/notify-feishu.sh"

# Thresholds
# NOTE: these are RATIOS of nproc, not absolute load values. They assume an IDLE
# machine, which this box is not: it runs nightly builds that intentionally drive
# load to 1-2x core count for hours. A plain ratio threshold therefore fires on
# normal operation — historically 100% of all alerts (7 days: 59/59 were CPU).
# check_cpu() compensates by downgrading to INFO whenever a build is running; the
# thresholds below only decide "is this high for an IDLE machine".
readonly CPU_WARN_THRESHOLD=0.9
readonly CPU_CRIT_THRESHOLD=2.0
readonly MEM_WARN_THRESHOLD=20
readonly MEM_CRIT_THRESHOLD=10
readonly DISK_WARN_THRESHOLD=85
readonly DISK_CRIT_THRESHOLD=92
readonly SWAP_WARN_THRESHOLD=50

# Expected Docker containers
readonly EXPECTED_CONTAINERS=(
    chaos-master chaos-agent-x64 chaos-agent-arm64
    chaos-agent-android chaos-agent-cr
    chaos-report-server chaos-report-api
    chaos-minio chaos-sonarqube chaos-sonar-db
)

# Key HTTP services (name:url)
readonly HTTP_CHECKS=(
    "Jenkins:http://localhost:8080/login"
    "SonarQube:http://localhost:9000"
    "Report Server:http://localhost:8081"
    "MinIO:http://localhost:9002/minio/health/live"
)

# ── Helpers ─────────────────────────────────────────────────────────
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
err()  { log "ERROR: $*"; }

# Return integer (0-100) for memory available percent
get_mem_avail_pct() {
    free | awk 'NR==2 {total=$2; avail=$7; if (total+0>0) printf "%d", avail/total*100; else print 99}'
}

# Return integer (0-100) for swap used percent
get_swap_used_pct() {
    free | awk 'NR==3 {total=$2; used=$3; if (total+0>0) printf "%d", used/total*100; else print 0}'
}

# Return 1 if any Jenkins job is currently building, 0 otherwise.
# Scans the most recent 5 builds of each relevant job; beyond 5 proves stale.
detect_running_builds() {
    sudo docker exec chaos-master bash -c '
        for job in chaos-il2cpp-code-review chaos-il2cpp-nightly chaos-il2cpp-pr-review; do
            d="/var/jenkins_home/jobs/$job/builds"
            [ -d "$d" ] || continue
            for b in $(ls -t "$d" 2>/dev/null | grep -E "^[0-9]+$" | head -5); do
                f="$d/$b/build.xml"
                [ -f "$f" ] || continue
                grep -q "<building>true</building>" "$f" && echo 1 && exit 0
            done
        done
        echo 0
    ' 2>/dev/null || echo 0
}

# Return integer (0-100) for disk used percent
get_disk_used_pct() {
    df --output=pcent "$1" 2>/dev/null | tail -1 | tr -d ' %' || echo 0
}

# ── Check Functions ─────────────────────────────────────────────────
# Each writes to stdout: name<TAB>level<TAB>message
# level is one of: OK, WARN, CRIT, INFO

check_cpu() {
    local cores load level msg warn_thr crit_thr building
    cores=$(nproc 2>/dev/null || echo 1)
    load=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)
    warn_thr=$(echo "$cores * $CPU_WARN_THRESHOLD" | bc -l 2>/dev/null | awk '{printf "%.1f", $1}')
    crit_thr=$(echo "$cores * $CPU_CRIT_THRESHOLD" | bc -l 2>/dev/null | awk '{printf "%.1f", $1}')
    building=$(detect_running_builds)

    level="OK"
    if (echo "$load > $crit_thr" | bc -l 2>/dev/null | grep -q 1); then level="CRIT"
    elif (echo "$load > $warn_thr" | bc -l 2>/dev/null | grep -q 1); then level="WARN"
    fi

    # A running build EXPLAINS high load — it is the machine doing its job, not a
    # fault. Report it as INFO so it stays visible in the health report without
    # raising an incident. Only load that is high while the box is IDLE tells us
    # something is wrong (runaway process, leaked task).
    if [ "$level" != "OK" ] && [ "$building" = "1" ]; then
        msg="CPU load ${load}/${cores} cores — build in progress (expected, thresholds ${warn_thr}/${crit_thr} do not apply)"
        level="INFO"
    else
        msg="CPU load ${load}/${cores} cores (warn>${warn_thr} crit>${crit_thr})"
    fi
    printf "cpu\t%s\t%s\n" "$level" "$msg"
}

check_memory() {
    local avail_pct level mem_info
    avail_pct=$(get_mem_avail_pct)
    mem_info=$(free -h | awk 'NR==2 {print "used " $3 " / " $2 "  (avail " $7 ")"}')
    level="OK"
    if [ "${avail_pct:-99}" -lt "$MEM_CRIT_THRESHOLD" ]; then level="CRIT"
    elif [ "${avail_pct:-99}" -lt "$MEM_WARN_THRESHOLD" ]; then level="WARN"
    fi
    printf "memory\t%s\tMemory: %s (%s%% avail, warn<%s%% crit<%s%%)\n" \
        "$level" "$mem_info" "$avail_pct" "$MEM_WARN_THRESHOLD" "$MEM_CRIT_THRESHOLD"
}

check_swap() {
    local swap_pct level swap_info
    swap_pct=$(get_swap_used_pct)
    swap_info=$(free -h | awk 'NR==3 {print "used " $3 " / " $2}')
    level="OK"
    if [ "${swap_pct:-0}" -gt "$SWAP_WARN_THRESHOLD" ]; then level="WARN"; fi
    printf "swap\t%s\tSwap: %s (%s%% used, warn>%s%%)\n" \
        "$level" "$swap_info" "$swap_pct" "$SWAP_WARN_THRESHOLD"
}

check_disk() {
    local pct level global_level="OK" details=""
    for mnt in "/" "/var/lib/docker"; do
        [ -d "$mnt" ] || continue
        pct=$(get_disk_used_pct "$mnt")
        level="OK"
        if [ "${pct:-0}" -ge "$DISK_CRIT_THRESHOLD" ]; then level="CRIT"
        elif [ "${pct:-0}" -ge "$DISK_WARN_THRESHOLD" ]; then level="WARN"
        fi
        [ "$level" != "OK" ] && global_level="$level"
        details="${details} ${mnt}:${pct}%(${level})"
    done
    printf "disk\t%s\tDisk:%s (warn>%s%% crit>%s%%)\n" \
        "$global_level" "$details" "$DISK_WARN_THRESHOLD" "$DISK_CRIT_THRESHOLD"
}

check_docker_daemon() {
    if docker info &>/dev/null; then
        printf "docker_daemon\tOK\tDocker daemon running\n"
    else
        printf "docker_daemon\tCRIT\tDocker daemon NOT responding\n"
    fi
}

check_docker_containers() {
    local level="OK" unhealthy="" status
    for container in "${EXPECTED_CONTAINERS[@]}"; do
        status=$(docker inspect "$container" --format '{{.State.Status}}' 2>/dev/null || echo "missing")
        if [ "$status" != "running" ]; then
            level="CRIT"
            unhealthy="${unhealthy}${container}:${status} "
        fi
    done
    if [ "$level" = "OK" ]; then
        printf "docker\tOK\tAll %d containers running\n" "${#EXPECTED_CONTAINERS[@]}"
    else
        printf "docker\tCRIT\tDocker containers not running: %s\n" "$unhealthy"
    fi
}

check_sshd() {
    if pgrep -x sshd &>/dev/null; then
        printf "sshd\tOK\tsshd is running\n"
    else
        printf "sshd\tCRIT\tsshd is NOT running\n"
    fi
}

check_http_services() {
    local level="OK" down="" name url code
    for entry in "${HTTP_CHECKS[@]}"; do
        name="${entry%%:*}"
        url="${entry#*:}"
        code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "$url" 2>/dev/null || echo "000")
        if [ "$code" = "000" ] || [ "${code:-200}" -ge 500 ]; then
            level="CRIT"
            down="${down}${name}(HTTP ${code}) "
        fi
    done
    if [ "$level" = "OK" ]; then
        printf "http\tOK\tAll HTTP services reachable\n"
    else
        printf "http\tCRIT\tServices unreachable: %s\n" "$down"
    fi
}

check_suspend() {
    local count
    count=$(journalctl -u systemd-suspend.service --since "600 seconds ago" 2>/dev/null | grep -c "Starting\|entered" || true)
    if [ "${count:-0}" -gt 0 ]; then
        printf "suspend\tWARN\tSystem suspended %dx in last 10 min (check power management)\n" "$count"
    else
        printf "suspend\tOK\tNo recent suspend events\n"
    fi
}

check_systemd_failed() {
    local failed details
    failed=$(systemctl list-units --state=failed --no-legend 2>/dev/null | wc -l) || failed=0
    if [ "${failed:-0}" -gt 0 ]; then
        details=$(systemctl list-units --state=failed --no-legend 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
        printf "systemd\tWARN\t%d failed units: %s\n" "$failed" "$details"
    else
        printf "systemd\tOK\tAll systemd units healthy\n"
    fi
}

check_dns() {
    if host open.feishu.cn &>/dev/null || nslookup open.feishu.cn &>/dev/null; then
        printf "dns\tOK\tDNS resolution working\n"
    else
        printf "dns\tWARN\tCannot resolve open.feishu.cn — notifications may fail\n"
    fi
}

check_uptime() {
    local sec
    sec=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)
    if [ "${sec:-0}" -lt 3600 ]; then
        local boot_msg
        boot_msg=$(journalctl --list-boots 2>/dev/null | tail -1 | awk '{print $3, $4, $5, $6}' || echo "unknown")
        printf "uptime\tINFO\tSystem booted %ds ago (last: %s)\n" "$sec" "$boot_msg"
    else
        local uptime_str
        uptime_str=$(awk '{printf "%dd %dh %dm", int($1/86400), int($1%86400/3600), int($1%3600/60)}' /proc/uptime)
        printf "uptime\tOK\tUptime: %s\n" "$uptime_str"
    fi
}

# ── Core Logic ──────────────────────────────────────────────────────
# All heavy processing is delegated to Python to avoid shell parsing bugs.

run_checks() {
    check_docker_daemon
    check_cpu
    check_memory
    check_swap
    check_disk
    check_docker_containers
    check_sshd
    check_http_services
    check_suspend
    check_systemd_failed
    check_dns
    check_uptime
}

main() {
    # Lock
    if command -v flock &>/dev/null; then
        exec 200>"$LOCK_FILE" || true
        flock -n 200 || { log "Another instance running, skipping"; exit 0; }
    fi

    log "Starting health check..."

    # Run checks → tab-separated output
    local raw
    raw=$(run_checks)

    # Delegate all state management & notification logic to Python
    local state_dir
    state_dir=$(dirname "$MONITOR_STATE_FILE")
    [ -d "$state_dir" ] || mkdir -p "$state_dir"

    python3 -c "
import json, os, subprocess, sys, time

state_file = os.environ.get('MONITOR_STATE_FILE', '/var/lib/report-server/daily/monitor-state.json')
webhook = os.environ.get('FEISHU_WEBHOOK_URL', '')
dry_run = os.environ.get('MONITOR_DRY_RUN', '0') == '1'

# Hysteresis: how many consecutive checks must agree before a transition is
# considered real. CPU crosses its threshold line momentarily all the time (a
# compile spike, a GC pause); without this, one 5-min sample flips the state and
# emits BOTH 「异常告警」 and 「已恢复」 within minutes of each other. Observed
# 2026-09-13 03:25-03:50: 5 messages in 25 minutes, all CPU flapping.
# 2 checks = 10 minutes of agreement.
DEBOUNCE_CHECKS = int(os.environ.get('MONITOR_DEBOUNCE_CHECKS', '2'))

# A recovery notice is only worth sending if there was a real outage to recover
# FROM. Flapping up and down for 10 minutes is noise, not an incident. Emit the
# recovery only when the issue was actually held for this long.
RECOVERY_MIN_HOLD_S = int(os.environ.get('MONITOR_RECOVERY_MIN_HOLD_S', '1800'))

# Checks that are subject to debounce. Others (docker down, disk full, sshd
# dead) are unambiguous and must alert immediately — debouncing those would
# delay a real outage by 10 minutes for no benefit.
DEBOUNCED = {'cpu'}

# Parse tab-separated check results
lines = sys.stdin.read().strip().split('\n')
checks = {}
for line in lines:
    if not line.strip():
        continue
    parts = line.split('\t', 2)
    if len(parts) < 3:
        continue
    name, level, msg = parts
    checks[name] = {'level': level, 'msg': msg.strip()}

# Load previous state
prev = {}
if os.path.exists(state_file):
    try:
        with open(state_file) as f:
            prev = json.load(f)
    except (json.JSONDecodeError, IOError):
        prev = {}

# Detect changes
new_issues = []    # OK → WARN/CRIT (confirmed by debounce where applicable)
recovered = []     # WARN/CRIT → OK
ongoing = []       # WARN/CRIT still WARN/CRIT
summary_issues = []
summary_ok = []

# Debounce bookkeeping, persisted in state across runs.
#   _streak_<name>_<level> = consecutive checks seen at that level

timestamp = time.strftime('%Y-%m-%d %H:%M:%S')
streaks = {}
effective = {}
for k, v in prev.items():
    if k.startswith('_streak_'):
        try:
            streaks[k] = int(v)
        except (TypeError, ValueError):
            streaks[k] = 0

# When did each check first enter its CURRENT bad level? Used to decide whether a
# recovery notice is warranted. Keyed by check name.
onset = {}
for k, v in prev.items():
    if k.startswith('_onset_'):
        onset[k[len('_onset_'):]] = v

def bump(name, level):
    # Increment the consecutive-check counter for (name, level) and return it.
    key = '_streak_%s_%s' % (name, level)
    streaks[key] = streaks.get(key, 0) + 1
    return streaks[key]

def reset_streaks(name):
    # Clear counters for a check — call when it returns to OK.
    for k in list(streaks):
        if k.startswith('_streak_%s_' % name):
            del streaks[k]

for name, c in checks.items():
    if name.startswith('_'):
        continue
    prev_level = prev.get(name, {}).get('level', 'OK')
    # What the PREVIOUS run actually told the user. Differs from prev_level on the
    # first sample of a debounced check: we write WARN into the state (so the
    # health report shows it) while telling the user NOTHING. Recovery must be
    # measured against what was announced — otherwise a check that was never
    # alerted can never be 「recovered」 from, and the OK-streak counter is wiped
    # by the WARN branch forever (a real bug found by simulation).
    prev_effective = prev.get('_effective_' + name, prev_level)
    cur_level = c['level']

    if cur_level in ('WARN', 'CRIT'):
        summary_issues.append(f'  • [{cur_level}] {c[\"msg\"]}')

        reset_streaks(name + '__ok')
        if prev_effective in ('WARN', 'CRIT'):
            # User already knows. Stay quiet, just keep the onset time.
            ongoing.append(f'{name}({cur_level})')
            onset.setdefault(name, prev.get('_onset_' + name, timestamp))
        else:
            # Not yet announced to the user — require sustained agreement.
            n = bump(name, cur_level)
            if name in DEBOUNCED and n < DEBOUNCE_CHECKS:
                ongoing.append(f'{name}({cur_level}?{n})')   # candidate, silent
            else:
                new_issues.append(f'{name}({cur_level})')
                onset[name] = timestamp
    else:
        summary_ok.append(f'  • {c[\"msg\"]}')
        if prev_effective in ('WARN', 'CRIT'):
            # Was announced bad; confirm the recovery before saying so.
            n = bump(name + '__ok', 'OK')
            if name in DEBOUNCED and n < DEBOUNCE_CHECKS:
                ongoing.append(f'{name}({cur_level}?recovering)')  # not yet
            else:
                since = onset.get(name, prev.get('_onset_' + name, ''))
                held = 0
                if since:
                    try:
                        t0 = time.mktime(time.strptime(since, '%Y-%m-%d %H:%M:%S'))
                        held = time.time() - t0
                    except (ValueError, TypeError):
                        held = 0
                if name in DEBOUNCED and held < RECOVERY_MIN_HOLD_S:
                    pass   # flap, not an outage — no recovery card
                else:
                    recovered.append(f'{name}({prev_effective}→OK)')
                reset_streaks(name)
                reset_streaks(name + '__ok')
                onset.pop(name, None)
        else:
            reset_streaks(name + '__ok')

    # Record what the user will now believe about this check: the announced level
    # for confirmed states, or the previous effective level while still pending.
    if cur_level in ('WARN', 'CRIT'):
        announced = (cur_level if f'{name}({cur_level})' in new_issues
                     else prev_effective)
    else:
        if any(x.startswith(name + '(') for x in recovered):
            announced = 'OK'
        elif any(x.startswith(name + '(') for x in ongoing):
            announced = prev_effective   # pending recovery — still believed bad
        else:
            announced = 'OK'
    effective[name] = announced

# Determine overall status levels (derived from the raw check levels, BEFORE the
# debounce filter — a persistent problem must still be visible in the report
# during its debounce window, it just should not page anyone yet).
has_crit = any(c['level'] == 'CRIT' for c in checks.values())
has_warn = any(c['level'] == 'WARN' for c in checks.values())
has_info = any(c['level'] == 'INFO' for c in checks.values())

# ── Sustained CRIT re-alert ──
# When every known issue is ongoing (not new, not recovered), the user got their
# first alert when it BECAME new. They still need a periodic reminder that it is
# still broken. The original code had 'and not ongoing' here, which made the
# branch mathematically UNREACHABLE: if has_crit and not new_issues and not
# recovered, then every issue is ongoing, so 'not ongoing' is always False.
# Net effect: a CRIT that persisted past detection went permanently silent.
sustained_crit = (has_crit and not new_issues and not recovered and ongoing)

# Build message
msg_lines = ['📋 **系统健康检查报告**', f'🕐 {timestamp}', '───', '']
if summary_issues:
    msg_lines.append('**异常项**')
    msg_lines.extend(summary_issues)
    msg_lines.append('')
if summary_ok:
    msg_lines.append('**正常项**')
    msg_lines.extend(summary_ok)

full_message = '\n'.join(msg_lines)

# Decide notification
notify = False
title = ''
color = 'green'

if new_issues:
    notify = True
    color = 'red' if has_crit else 'blue'
    title = f'{\"🚨\" if has_crit else \"⚠️\"} 系统异常告警 [{timestamp}]'
elif recovered and not ongoing:
    notify = True
    color = 'green'
    title = f'✅ 系统已恢复 [{timestamp}]'
elif recovered and ongoing:
    notify = True
    color = 'blue'
    title = f'🔄 系统状态变化 [{timestamp}]'
elif sustained_crit and has_crit:
    # Everything is ongoing and at least one is CRIT — remind periodically.
    # Guarded by _last_alerted so a permanently-broken box does not spam; the
    # 30-min cadence matches the original intent, it just never actually ran.
    last_alerted = prev.get('_last_alerted', 0)
    if time.time() - last_alerted > 1800:
        notify = True
        color = 'red'
        title = f'🚨 系统异常持续 [{timestamp}]'

# Save current state (always)
state_out = {k: v for k, v in checks.items()}
state_out['_last_check'] = timestamp
if notify:
    state_out['_last_alerted'] = time.time()
# Persist debounce streaks so they survive across cron runs (every 5 min).
for k, v in streaks.items():
    state_out[k] = v
for name, ts in onset.items():
    state_out['_onset_' + name] = ts
# Persist the level the user currently BELIEVES, so recovery is detected against
# what was announced rather than against the raw (possibly still-pending) level.
for name, lv in effective.items():
    state_out['_effective_' + name] = lv
with open(state_file, 'w') as f:
    json.dump(state_out, f, ensure_ascii=False)

# Send notification
if notify:
    if dry_run:
        print(f'[DRY-RUN] title={title} color={color}')
        print(full_message[:500])
    else:
        # Use notify-feishu.sh
        notify_script = '/home/debian/agent/chaos-il2cpp-nightly-test/scripts/notify-feishu.sh'
        if os.path.exists(notify_script):
            subprocess.run(
                ['bash', notify_script, '--title', title, '--message', full_message, '--color', color],
                capture_output=True, timeout=30
            )
        else:
            # Fallback: direct curl
            import urllib.request
            payload = json.dumps({
                'msg_type': 'text',
                'content': {'text': f'{title}\\n\\n{full_message}'}
            }).encode()
            req = urllib.request.Request(webhook, data=payload,
                headers={'Content-Type': 'application/json'})
            try:
                urllib.request.urlopen(req, timeout=15)
            except Exception:
                pass

# Print summary to log
new_str = ','.join(new_issues) if new_issues else '-'
rec_str = ','.join(recovered) if recovered else '-'
ongoing_str = ','.join(ongoing) if ongoing else '-'
print(f'crit={has_crit} warn={has_warn} info={has_info} notify={notify}')
print(f'new=[{new_str}] recovered=[{rec_str}] ongoing=[{ongoing_str}]')
" <<< "$raw"

    log "Done."
}

main "$@"
