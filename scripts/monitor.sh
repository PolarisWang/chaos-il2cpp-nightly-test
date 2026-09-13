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
# Each writes to stdout: name<TAB>level<TAB>message[<TAB>diagnosis<TAB>advice]
# level is one of: OK, WARN, CRIT, INFO
#
# `diagnosis` and `advice` are OPTIONAL and must only be set when there is real
# evidence for them. A restated number is not a diagnosis ("swap is 27%" is the
# message, not an explanation of why). Checks that cannot tell WHY a value is
# what it is leave these empty and the card says so, rather than inventing
# plausible-sounding text that would train the reader to ignore it.
#
# Currently able to diagnose: cpu (knows whether a build is running),
# docker (knows which container died), http (knows which service and code).
# Everything else reports level+message only.

check_cpu() {
    local cores load level msg warn_thr crit_thr building diag advice
    cores=$(nproc 2>/dev/null || echo 1)
    load=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)
    warn_thr=$(echo "$cores * $CPU_WARN_THRESHOLD" | bc -l 2>/dev/null | awk '{printf "%.1f", $1}')
    crit_thr=$(echo "$cores * $CPU_CRIT_THRESHOLD" | bc -l 2>/dev/null | awk '{printf "%.1f", $1}')
    building=$(detect_running_builds)

    level="OK"; diag=""; advice=""
    if (echo "$load > $crit_thr" | bc -l 2>/dev/null | grep -q 1); then level="CRIT"
    elif (echo "$load > $warn_thr" | bc -l 2>/dev/null | grep -q 1); then level="WARN"
    fi

    # A running build EXPLAINS high load — it is the machine doing its job, not a
    # fault. Report it as INFO so it stays visible in the health report without
    # raising an incident. Only load that is high while the box is IDLE tells us
    # something is wrong (runaway process, leaked task).
    if [ "$level" != "OK" ] && [ "$building" = "1" ]; then
        msg="CPU load ${load}/${cores} cores (warn>${warn_thr} crit>${crit_thr})"
        diag="构建进行中 — 负载属于预期，不会自愈也不会恶化"
        advice="无需操作"
        level="INFO"
    else
        msg="CPU load ${load}/${cores} cores (warn>${warn_thr} crit>${crit_thr})"
        if [ "$level" != "OK" ]; then
            # No build running, yet load is high: the Python block will enrich
            # the diagnosis with process classification. Keep this short here
            # so the fallback text is meaningful even if Python is unavailable.
            diag="无构建运行但负载仍超阈值 — 归因分析在 Python 块中完成"
            advice="检查是否有残留的构建进程或失控任务"
        fi
    fi
    printf "cpu\t%s\t%s\t%s\t%s\n" "$level" "$msg" "$diag" "$advice"
}

check_memory() {
    local avail_pct level mem_info
    avail_pct=$(get_mem_avail_pct)
    mem_info=$(free -h | awk 'NR==2 {print "used " $3 " / " $2 "  (avail " $7 ")"}')
    level="OK"
    if [ "${avail_pct:-99}" -lt "$MEM_CRIT_THRESHOLD" ]; then level="CRIT"
    elif [ "${avail_pct:-99}" -lt "$MEM_WARN_THRESHOLD" ]; then level="WARN"
    fi
    printf "memory\t%s\t%s\t\t\n" \
        "$level" "$mem_info"
}

check_swap() {
    local swap_pct level swap_info
    swap_pct=$(get_swap_used_pct)
    swap_info=$(free -h | awk 'NR==3 {print "used " $3 " / " $2}')
    level="OK"
    if [ "${swap_pct:-0}" -gt "$SWAP_WARN_THRESHOLD" ]; then level="WARN"; fi
    # No diagnosis: a swap percentage alone does not say WHY memory is under
    # pressure (a leak, a one-off build peak, or ordinary caching all look the
    # same from here). The trend, not a guess, is what would make this
    # actionable — leave diagnosis empty rather than assert a cause.
    printf "swap\t%s\tSwap: %s (%s%% used, warn>%s%%)\t\t\n" \
        "$level" "$swap_info" "$swap_pct" "$SWAP_WARN_THRESHOLD"
}

check_disk() {
    local pct level global_level="OK" details="" over=""
    for mnt in "/" "/var/lib/docker"; do
        [ -d "$mnt" ] || continue
        pct=$(get_disk_used_pct "$mnt")
        level="OK"
        if [ "${pct:-0}" -ge "$DISK_CRIT_THRESHOLD" ]; then level="CRIT"
        elif [ "${pct:-0}" -ge "$DISK_WARN_THRESHOLD" ]; then level="WARN"
        fi
        [ "$level" != "OK" ] && global_level="$level"
        [ "$level" != "OK" ] && over="${over}${mnt} "
        details="${details} ${mnt}:${pct}%(${level})"
    done
    local diag="" advice=""
    if [ -n "$over" ]; then
        diag="挂载点 ${over}已超阈值 — 磁盘不会自行释放"
        advice="du -sh /var/lib/docker/* | sort -h | tail; 清理旧构建产物"
    fi
    printf "disk\t%s\tDisk:%s (warn>%s%% crit>%s%%)\t%s\t%s\n" \
        "$global_level" "$details" "$DISK_WARN_THRESHOLD" "$DISK_CRIT_THRESHOLD" \
        "$diag" "$advice"
}

check_docker_daemon() {
    if docker info &>/dev/null; then
        printf "docker_daemon\tOK\tDocker daemon running\t\t\n"
    else
        printf "docker_daemon\tCRIT\tDocker daemon NOT responding\t守护进程未响应 — 所有容器均已失联\tsystemctl status docker; docker ps 确认\n"
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
        printf "docker\tOK\tAll %d containers running\t\t\n" "${#EXPECTED_CONTAINERS[@]}"
    else
        # We know exactly which container is down — that IS the diagnosis.
        printf "docker\tCRIT\tDocker containers not running: %s\t容器已停止，其承载的服务不可用\tdocker start <容器名>；若反复退出查看 docker logs\n" "$unhealthy"
    fi
}

check_sshd() {
    if pgrep -x sshd &>/dev/null; then
        printf "sshd\tOK\tsshd is running\t\t\n"
    else
        printf "sshd\tCRIT\tsshd is NOT running\tSSH 服务未运行 — 可能导致无法远程登录\tsystemctl start sshd\n"
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
        printf "http\tOK\tAll HTTP services reachable\t\t\n"
    else
        # We know which service and which code — that is actionable as-is.
        printf "http\tCRIT\tServices unreachable: %s\t具体服务无响应或返回 5xx\t检查对应容器是否存活；HTTP 000 通常意味着端口未监听\n" "$down"
    fi
}

check_suspend() {
    local count
    count=$(journalctl -u systemd-suspend.service --since "600 seconds ago" 2>/dev/null | grep -c "Starting\|entered" || true)
    if [ "${count:-0}" -gt 0 ]; then
        printf "suspend\tWARN\tSystem suspended %dx in last 10 min (check power management)\t系统反复挂起 — 会中断正在运行的构建\t检查电源管理/休眠设置\n" "$count"
    else
        printf "suspend\tOK\tNo recent suspend events\t\t\n"
    fi
}

check_systemd_failed() {
    local failed details
    failed=$(systemctl list-units --state=failed --no-legend 2>/dev/null | wc -l) || failed=0
    if [ "${failed:-0}" -gt 0 ]; then
        details=$(systemctl list-units --state=failed --no-legend 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
        printf "systemd\tWARN\t%d failed units: %s\t有 systemd 单元处于 failed 状态\tsystemctl status <unit> 查看失败原因\n" "$failed" "$details"
    else
        printf "systemd\tOK\tAll systemd units healthy\t\t\n"
    fi
}

check_dns() {
    # Detects DNS resolution for NOTIFICATIONS. If DNS is broken, this check
    # itself will be the only failure nobody ever sees — the alert cannot be
    # delivered. Report it as INFO so it stays visible in the health report
    # without ever triggering a card (risk 5: causal loop).
    if host open.feishu.cn &>/dev/null || nslookup open.feishu.cn &>/dev/null; then
        printf "dns\tOK\tDNS resolution working\t\t\n"
    else
        printf "dns\tINFO\tCannot resolve open.feishu.cn — notifications may fail\tDNS 故障意味着本条告警无法送达\t检查 /etc/resolv.conf 和网络连通性\n"
    fi
}

check_uptime() {
    local sec
    sec=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)
    if [ "${sec:-0}" -lt 3600 ]; then
        local boot_msg
        boot_msg=$(journalctl --list-boots 2>/dev/null | tail -1 | awk '{print $3, $4, $5, $6}' || echo "unknown")
        printf "uptime\tINFO\tSystem booted %ds ago (last: %s)\t\t\n" "$sec" "$boot_msg"
    else
        local uptime_str
        uptime_str=$(awk '{printf "%d %d %dm", int($1/86400), int($1%86400/3600), int($1%3600/60)}' /proc/uptime)
        printf "uptime\tOK\tUptime: %s\t\t\n" "$uptime_str"
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

# Parse tab-separated check results.
# Format: name<TAB>level<TAB>message[<TAB>diagnosis<TAB>advice]
# diagnosis/advice are optional and often empty — a check that cannot explain
# WHY a value is what it is must leave them blank rather than invent a cause.
lines = sys.stdin.read().strip().split('\n')
checks = {}
for line in lines:
    if not line.strip():
        continue
    parts = line.split('\t', 4)
    if len(parts) < 3:
        continue
    name, level, msg = parts[0], parts[1], parts[2]
    diag = parts[3].strip() if len(parts) > 3 else ''
    advice = parts[4].strip() if len(parts) > 4 else ''
    if not level.strip():
        continue
    checks[name] = {'level': level.strip(), 'msg': msg.strip(),
                    'diagnosis': diag, 'advice': advice}

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

# Checks whose check_* function can supply a real diagnosis. Everything else
# reports only a number, and the card says so rather than inventing a cause.
# Keep in sync with the check_* functions that set a non-empty diagnosis.
DIAGNOSABLE = {'cpu', 'disk', 'docker', 'docker_daemon', 'sshd', 'http',
               'suspend', 'systemd', 'dns'}

# ── Sample persistence (trend baseline) ──
# The monitor logs only booleans (crit=/warn=/notify=), so no numeric history
# existed anywhere — a trend feature could never have been built from it. Write
# a small snapshot every run; hourly files, 7-day retention.
#
# Deliberately numeric-only and append-only: cheap to write, trivial to read
# back, and safe to lose (a missing sample degrades the trend, never the card).
SAMPLE_DIR = os.environ.get('MONITOR_SAMPLE_DIR',
                            '/var/lib/report-server/daily/samples')
SAMPLE_RETAIN_DAYS = int(os.environ.get('MONITOR_SAMPLE_RETAIN_DAYS', '7'))

def _num(txt):
    # First number in a string, or None. Used to pull values out of check
    # messages without the check functions having to emit structured data.
    import re as _re
    m = _re.search(r'(\d+(?:\.\d+)?)', str(txt or ''))
    return float(m.group(1)) if m else None

def write_sample():
    try:
        os.makedirs(SAMPLE_DIR, exist_ok=True)
        sample = {
            'ts': int(time.time()),
            'cpu': _num((checks.get('cpu') or {}).get('msg')),
            'cpu_level': (checks.get('cpu') or {}).get('level'),
            'mem_avail_pct': _num((checks.get('memory') or {}).get('msg')),
            'swap_pct': _num((checks.get('swap') or {}).get('msg')),
            'disk_pct': _num((checks.get('disk') or {}).get('msg')),
            'n_faults': len(faults),
            'n_pending': len(pending),
            'n_ok': len(ok_names),
        }
        hour = time.strftime('%Y-%m-%d-%H', time.localtime())
        with open(os.path.join(SAMPLE_DIR, hour + '.jsonl'), 'a') as f:
            f.write(json.dumps(sample) + '\n')
        # Retention: drop files older than SAMPLE_RETAIN_DAYS by mtime.
        cutoff = time.time() - SAMPLE_RETAIN_DAYS * 86400
        for fn in os.listdir(SAMPLE_DIR):
            if not fn.endswith('.jsonl'):
                continue
            fp = os.path.join(SAMPLE_DIR, fn)
            try:
                if os.path.getmtime(fp) < cutoff:
                    os.remove(fp)
            except OSError:
                pass
    except Exception as e:
        # Never let bookkeeping break the health check itself.
        print('WARNING: could not write sample: %s' % e)

def load_samples(max_age_h=48):
    out = []
    try:
        cutoff = time.time() - max_age_h * 3600
        for fn in sorted(os.listdir(SAMPLE_DIR)):
            if not fn.endswith('.jsonl'):
                continue
            with open(os.path.join(SAMPLE_DIR, fn)) as f:
                for line in f:
                    try:
                        s = json.loads(line)
                    except ValueError:
                        continue
                    if s.get('ts', 0) >= cutoff:
                        out.append(s)
    except Exception:
        pass
    return out

def build_trend():
    # Compare this hour's median against the same hour ~24h ago. Says nothing
    # at all until a full day of samples exists — a permanent 「首轮」 marker is
    # worse than silence, and claiming a direction without a baseline is a lie.
    samples = load_samples(72)
    if len(samples) < 12:
        return []
    now = time.time()
    recent = [s for s in samples if now - s['ts'] <= 3600]
    base = [s for s in samples if 20 * 3600 <= now - s['ts'] <= 28 * 3600]
    if not recent or not base:
        return []

    def med(vals):
        vals = sorted(v for v in vals if v is not None)
        return vals[len(vals) // 2] if vals else None

    parts = []
    for key, label in (('cpu', 'CPU'), ('mem_avail_pct', 'Mem可用'),
                       ('swap_pct', 'Swap'), ('disk_pct', 'Disk')):
        r = med([s.get(key) for s in recent])
        b = med([s.get(key) for s in base])
        if r is None or b is None:
            continue
        d = r - b
        if abs(d) < 1:
            parts.append('%s →' % label)
        else:
            parts.append('%s %s%.1f' % (label, '↑' if d > 0 else '↓', abs(d)))
    if not parts:
        return []
    return parts

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

# ── Group the checks for the card ──
# The old card listed every check as raw numbers, which gave a reader no way to
# tell 「needs me now」 from 「normal for a build machine」. Four groups, in the
# order a reader needs them:
#
#   faults   ❌  CRIT, or a WARN that has been held beyond WARN_ESCALATE_S
#   pending  ⚠️  WARN still inside the observation window
#   noise    ⏸  high resource use with a KNOWN benign cause (build running)
#   ok       ✅  everything else, folded to a single count line
#
# Escalation exists because merging WARNs silently would be worse than the old
# spam: a disk at 84% is a WARN that never becomes a CRIT until it is too late,
# so a WARN that will not go away must eventually ask for a human.
WARN_ESCALATE_S = int(os.environ.get('MONITOR_WARN_ESCALATE_S', '7200'))    # 2h
WARN_URGENT_S = int(os.environ.get('MONITOR_WARN_URGENT_S', '86400'))       # 24h

def held_seconds(name):
    # How long this check has been in its current bad level (0 if unknown).
    since = onset.get(name) or prev.get('_onset_' + name, '')
    if not since:
        return 0
    try:
        return time.time() - time.mktime(
            time.strptime(since, '%Y-%m-%d %H:%M:%S'))
    except (ValueError, TypeError):
        return 0

def fmt_dur(sec):
    if sec >= 86400:
        return '%d 天' % (sec // 86400)
    if sec >= 3600:
        return '%d 小时' % (sec // 3600)
    return '%d 分钟' % (sec // 60)

# ── Process attribution (for an idle-but-loaded CPU) ──
# When load is high and NO build is running, "CPU is high" is not actionable —
# the reader needs to know WHOSE cpu it is. Classify into stable categories
# and report the percentages only:
#
#   * Categories, not process names. "构建 85% / 未知 8%" survives a toolchain
#     change (cc1plus → clang, dotnet → dotnet8) without an edit here, and it
#     answers the actual question — is this ours, or is it a stranger?
#   * 未知 is the signal. Everything we recognise running is normal; the part
#     we cannot account for is what deserves a human.
#   * Process names go to the snapshot file, not the card. The card stays
#     scannable; the detail is one click away when someone actually digs in.
PROC_CATEGORIES = [
    ('构建', r'\b(cc1plus|cc1\b|collect2|as\b|ld\b|VBCSCompiler|msbuild|make|cmake|ninja)\b'),
    ('构建', r'dotnet\s+(build|run|msbuild|restore|publish|test)\b'),
    ('构建', r'python3.*verification\.(chunk_pipeline|nightly|cli|e2e)'),
    ('构建', r'/home/jenkins/workspace/'),
    ('AI审查', r'\b(claude|code-review)\b'),
    ('Jenkins', r'\b(java.*jenkins|sonar|slave\b)'),
    ('监控', r'\b(victoria|grafana|prometheus|node_exporter|alertmanager)'),
    ('系统', r'\b(systemd|journald|sshd|cron|rsyslog|dbus|polkit|udevd|'
             r'NetworkManager|containerd|dockerd|init\b|ntpd|chronyd|'
             r'feishu|postfix|nginx|redis)\b'),
]
PROC_ORDER = ['构建', 'AI审查', 'Jenkins', '监控', '系统', '未知']
# Only a category above this share is worth naming in the advice line.
UNKNOWN_ALERT_PCT = 5

SNAPSHOT_DIR = os.environ.get('MONITOR_SNAPSHOT_DIR',
                              '/var/lib/report-server/daily/cpu-snapshots')
SNAPSHOT_KEEP = 20

def classify_procs():
    # Returns (category_pct: dict, unknown_top: list[str], snapshot_path: str|None)
    import re as _re
    try:
        out = subprocess.run(
            ['ps', '-eo', 'pcpu,comm,args', '--no-headers', '--sort=-pcpu'],
            capture_output=True, text=True, timeout=15).stdout
    except Exception:
        return {}, [], None

    cat_cpu, unk_comm = {}, {}
    for line in out.splitlines()[:400]:
        parts = line.split(None, 2)
        if len(parts) < 3:
            continue
        try:
            cpu = float(parts[0])
        except ValueError:
            continue
        if cpu < 0.5:
            continue
        comm, args = parts[1], parts[2]
        cat = '未知'
        for name, pat in PROC_CATEGORIES:
            if _re.search(pat, args, _re.IGNORECASE):
                cat = name
                break
        cat_cpu[cat] = cat_cpu.get(cat, 0) + cpu
        if cat == '未知':
            unk_comm[comm] = unk_comm.get(comm, 0) + cpu

    total = sum(cat_cpu.values()) or 1
    pct = {k: v / total * 100 for k, v in cat_cpu.items()}
    top = [c for c, _ in sorted(unk_comm.items(), key=lambda kv: -kv[1])[:3]]
    return pct, top, write_snapshot(out)

def write_snapshot(ps_out):
    # Only written when we are about to alert, so this is a rare write.
    # The card carries categories; this file carries the names for follow-up.
    try:
        os.makedirs(SNAPSHOT_DIR, exist_ok=True)
        ts = time.strftime('%Y-%m-%d-%H%M%S', time.localtime())
        path = os.path.join(SNAPSHOT_DIR, ts + '.txt')
        with open(path, 'w') as f:
            f.write('# cpu snapshot %s\n' % timestamp)
            f.write('loadavg: %s\n\n' % open('/proc/loadavg').read().strip())
            f.write(ps_out)
        # Retention
        files = sorted(fn for fn in os.listdir(SNAPSHOT_DIR)
                       if fn.endswith('.txt'))
        for fn in files[:-SNAPSHOT_KEEP]:
            try:
                os.remove(os.path.join(SNAPSHOT_DIR, fn))
            except OSError:
                pass
        return path
    except Exception:
        return None

def build_attribution():
    # Compose the diagnosis/advice for an idle-but-loaded CPU.
    pct, top, snap = classify_procs()
    if not pct:
        return '', '', None
    lines = ['无构建运行但负载仍超阈值 — 归因分析:']
    for cat in PROC_ORDER:
        v = pct.get(cat, 0)
        if v < 1:
            continue
        suffix = ''
        if cat == '未知' and v > UNKNOWN_ALERT_PCT:
            suffix = '  ← 建议排查'
        lines.append('　　%-6s %3.0f%%%s' % (cat, v, suffix))
    diag = '\n'.join(lines)
    if pct.get('未知', 0) > UNKNOWN_ALERT_PCT:
        advice = '未知进程占比偏高，优先排查; 完整进程名见快照'
    else:
        advice = '均为已知类别, 检查构建是否未正常退出'
    if snap:
        advice += '\n📎 进程快照: %s' % os.path.basename(snap)
    return diag, advice, snap

faults, pending, noise, ok_names = [], [], [], []
for name, c in checks.items():
    if name.startswith('_'):
        continue
    lvl = c['level']
    if lvl == 'OK':
        ok_names.append(name)
        continue
    if lvl == 'INFO':
        # INFO never alerts. This is where the build-aware CPU downgrade lands,
        # and where a broken DNS check reports itself without looping.
        noise.append((name, c))
        continue
    held = held_seconds(name)
    if lvl == 'CRIT' or held >= WARN_ESCALATE_S:
        faults.append((name, c, held, lvl))
    else:
        pending.append((name, c, held))

escalated = [f for f in faults if f[3] == 'WARN']
any_fault = bool(faults)

# ── Enrich the CPU fault with process attribution ──
# Only for the case that is actually mysterious: load high, no build running.
# A build-running CPU is already explained and is INFO (never a fault), so
# this runs at most once and only when a human would otherwise be guessing.
for _i, (_name, _c, _held, _lvl) in enumerate(faults):
    if _name == 'cpu' and '无构建运行' in str(_c.get('diagnosis', '')):
        _diag, _advice, _snap = build_attribution()
        if _diag:
            faults[_i][1]['diagnosis'] = _diag
            faults[_i][1]['advice'] = _advice

# ── Build the structured card (hybrid layout) ──
# Layout, in reading order:
#   1. summary grid   — counts, so the shape of the situation is one glance
#   2. fault detail   — vertical, each with its diagnosis and fix command
#   3. pending detail — vertical, one level quieter
#   4. noise detail   — things we have already explained (build running)
#   5. ok line        — healthy checks folded into ONE row (not a grid: they
#                       only need to be confirmable, not scannable)
#   6. trend          — answers a different question ("is it getting worse")
#
# Faults deliberately do NOT go in a grid. A grid cell is too narrow for a
# diagnosis plus a fix command, and truncating those is what made the old card
# useless. Grid for counts, vertical for anything that needs explaining.
card_sections = []

card_sections.append({
    'type': 'summary',
    'items': [
        {'label': '❌ 故障', 'value': str(len(faults))},
        {'label': '⚠️ 待确认', 'value': str(len(pending))},
        {'label': '⏸ 噪音', 'value': str(len(noise))},
        {'label': '✅ 正常', 'value': str(len(ok_names))},
    ],
})

for name, c, held, lvl in faults:
    extra = ''
    if lvl == 'WARN':
        extra = '已持续 %s' % fmt_dur(held)
        if held >= WARN_URGENT_S:
            extra += '，建议立即处理'
    card_sections.append({
        'type': 'fault',
        'items': [{
            'icon': '🔴',
            'name': c['msg'],
            'extra': extra,
            'diagnosis': c.get('diagnosis', ''),
            'advice': c.get('advice', ''),
        }],
    })

for name, c, held in pending:
    diag = c.get('diagnosis', '')
    if not diag and name not in DIAGNOSABLE:
        # Say so explicitly. A blank would read as 「nothing to explain」;
        # this reads as 「we genuinely cannot tell you why」.
        diag = '无诊断信息（该指标需要历史对比才能判断）'
    detail = ('已持续 %s，超 2 小时将升级为故障' % fmt_dur(held)) if held else ''
    card_sections.append({
        'type': 'pending',
        'items': [{
            'icon': '🟡',
            'name': c['msg'],
            'detail': detail,
            'diagnosis': diag,
        }],
    })

for name, c in noise:
    card_sections.append({
        'type': 'pending',
        'items': [{
            'icon': '⏸',
            'name': c['msg'],
            'detail': '',
            'diagnosis': c.get('diagnosis', ''),
        }],
    })

if ok_names:
    short = []
    for name in ok_names:
        m = (checks.get(name) or {}).get('msg', name)
        # Keep the compact line genuinely compact: the first clause only.
        m = m.split('(')[0].strip()
        short.append(m)
    card_sections.append({'type': 'ok_line', 'items': short})

trend_items = build_trend()
if trend_items:
    card_sections.append({'type': 'trend', 'items': trend_items})

# Plain-text rendering for the dry-run / log, so the same information is
# visible without opening Feishu.
msg_lines = ['🕐 %s' % timestamp]
for sec in card_sections:
    items = sec.get('items') or []
    if sec['type'] == 'summary':
        msg_lines.append('  '.join('%s %s' % (i['label'], i['value']) for i in items))
    elif sec['type'] in ('fault', 'pending'):
        for it in items:
            msg_lines.append('%s %s %s' % (it.get('icon', ''), it.get('name', ''),
                                           it.get('extra', '') or it.get('detail', '')))
            if it.get('diagnosis'):
                msg_lines.append('    -> %s' % it['diagnosis'])
            if it.get('advice'):
                msg_lines.append('    fix: %s' % it['advice'])
    elif sec['type'] == 'ok_line':
        msg_lines.append('OK: ' + ' · '.join(items))
    elif sec['type'] == 'trend':
        msg_lines.append('趋势: ' + '  ·  '.join(items))

full_message = '\n'.join(msg_lines)
# JSON for the sender (shlex-quoted-safe single line)
card_sections_json = json.dumps(card_sections, ensure_ascii=False)

# ── Written the sample last so it includes the grouping above ──
write_sample()

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

# ── Written the sample last so it includes the grouping above ──
write_sample()

# Decide notification
notify = False
title = ''
color = 'green'
# The action level handed to the engine. Derived from the GROUPS rather than
# from raw check levels: a build-running CPU is INFO even though its check
# level is INFO too, but a WARN that has escalated to 故障 must read RED even
# though the underlying check is still WARN.
level_for_notice = 'INFO'
if faults:
    level_for_notice = 'RED'
elif pending:
    level_for_notice = 'YELLOW'

if new_issues:
    notify = True
    color = 'red' if has_crit else 'blue'
    title = f'{\"🚨\" if any_fault else \"⚠️\"} 系统异常 [{timestamp}]'
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
        print(full_message[:800])
    else:
        # Route through the unified feishu engine so the health card gets the
        # same structured layout (summary grid + fault detail + folded OK row)
        # as every other notification.
        feishu_dir = os.environ.get(
            'FEISHU_ENGINE_DIR',
            '/home/debian/agent/chaos-il2cpp-nightly-test/scripts')
        sent = False
        try:
            if feishu_dir not in sys.path:
                sys.path.insert(0, feishu_dir)
            from feishu import Notice, send as feishu_send
            n = Notice(
                channel='health',
                level=level_for_notice,
                title=title,
                raw_header=True,
                color_override=color,
                sections=card_sections,
                footer_text='chaos-il2cpp 系统监控 · ' + time.strftime('%Y%m%d'),
            )
            sent = feishu_send(n, webhook, force=True) in ('sent', 'deduped')
        except Exception as e:
            print('WARNING: feishu engine unavailable (%s), falling back' % e)
        if not sent:
            # Legacy fallback so a broken engine can never silence the monitor.
            notify_script = '/home/debian/agent/chaos-il2cpp-nightly-test/scripts/notify-feishu.sh'
            if os.path.exists(notify_script):
                subprocess.run(
                    ['bash', notify_script, '--title', title,
                     '--message', full_message, '--color', color],
                    capture_output=True, timeout=30)
            else:
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
