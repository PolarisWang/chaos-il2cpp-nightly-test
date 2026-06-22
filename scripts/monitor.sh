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

# Return integer (0-100) for disk used percent
get_disk_used_pct() {
    df --output=pcent "$1" 2>/dev/null | tail -1 | tr -d ' %' || echo 0
}

# ── Check Functions ─────────────────────────────────────────────────
# Each writes to stdout: name<TAB>level<TAB>message
# level is one of: OK, WARN, CRIT, INFO

check_cpu() {
    local cores load level msg warn_thr crit_thr
    cores=$(nproc 2>/dev/null || echo 1)
    load=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)
    warn_thr=$(echo "$cores * $CPU_WARN_THRESHOLD" | bc -l 2>/dev/null | awk '{printf "%.1f", $1}')
    crit_thr=$(echo "$cores * $CPU_CRIT_THRESHOLD" | bc -l 2>/dev/null | awk '{printf "%.1f", $1}')
    msg="CPU load ${load}/${cores} cores (warn>${warn_thr} crit>${crit_thr})"
    level="OK"
    if (echo "$load > $crit_thr" | bc -l 2>/dev/null | grep -q 1); then level="CRIT"
    elif (echo "$load > $warn_thr" | bc -l 2>/dev/null | grep -q 1); then level="WARN"
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
new_issues = []    # OK → WARN/CRIT
recovered = []     # WARN/CRIT → OK
ongoing = []       # WARN/CRIT still WARN/CRIT
summary_issues = []
summary_ok = []

for name, c in checks.items():
    if name.startswith('_'):
        continue
    prev_level = prev.get(name, {}).get('level', 'OK')
    cur_level = c['level']

    if cur_level in ('WARN', 'CRIT'):
        summary_issues.append(f'  • [{cur_level}] {c[\"msg\"]}')
        if prev_level == 'OK':
            new_issues.append(f'{name}({cur_level})')
        else:
            ongoing.append(f'{name}({cur_level})')
    else:
        summary_ok.append(f'  • {c[\"msg\"]}')
        if prev_level in ('WARN', 'CRIT'):
            recovered.append(f'{name}({prev_level}→OK)')

# Determine overall status levels
has_crit = any(c['level'] == 'CRIT' for c in checks.values())
has_warn = any(c['level'] == 'WARN' for c in checks.values())
has_info = any(c['level'] == 'INFO' for c in checks.values())

timestamp = time.strftime('%Y-%m-%d %H:%M:%S')

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
elif has_crit and not new_issues and not recovered and not ongoing:
    # Ongoing critical without any change — still alert periodically
    # Only if last notification was > 30 min ago (handled via state's _last_alerted)
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
print(f'crit={has_crit} warn={has_warn} info={has_info} notify={notify}')
print(f'new=[{new_str}] recovered=[{rec_str}]')
" <<< "$raw"

    log "Done."
}

main "$@"
