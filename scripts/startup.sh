#!/bin/bash
# ==============================================================
# startup.sh — chaos-il2cpp 全平台 CI/CD 一键启动/停止/状态脚本
#
# 集成功能:
#   - 前置检查 (Docker, booming-il2cpp, 环境变量)
#   - crontab 注册 (code review 触发器)
#   - Docker 网络、数据目录初始化
#   - 按依赖顺序启动所有服务
#   - 等待 Agent 连接 Jenkins
#   - 健康检查 + 访问入口汇总
#
# 用法:
#   bash scripts/startup.sh [选项]
#
# 选项:
#   --build         启动前重新构建所有镜像
#   --stop          停止所有服务
#   --restart       重启所有服务
#   --status        查看各服务详细状态
#   --init          仅初始化目录、crontab 和环境配置，不启动 Docker
#   --sonar-only    仅启动 SonarQube 栈
#   --jenkins-only  仅启动 Jenkins + Agents + Report 栈
#   --report-only   仅启动 Report Server 栈
#   --setup-cron    仅安装/更新 code review crontab
#   --clean         停止服务并清理数据卷
#   --help|-h       显示帮助信息
# ==============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${REPO_ROOT}/docker-compose.yml"
SONAR_COMPOSE_FILE="${REPO_ROOT}/sonarqube/docker-compose.yml"
TRIGGER_SCRIPT="${SCRIPT_DIR}/trigger-code-review.sh"
BOOMING_DIR="/home/debian/agent/booming-il2cpp"
REPORT_DATA_DIR="/var/lib/report-server"
STATE_FILE="${REPORT_DATA_DIR}/daily/last-reviewed-commit.json"

# ── 颜色输出 ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${BLUE}[STEP]${NC}  $1"; }
log_ok()    { echo -e "  ${GREEN}✓${NC} $1"; }
log_fail()  { echo -e "  ${RED}✗${NC} $1"; }


# ════════════════════════════════════════════════════════════════
# 检测 docker compose 命令
# ════════════════════════════════════════════════════════════════
detect_docker_compose() {
    if docker compose version &>/dev/null; then
        DOCKER_COMPOSE="docker compose"
        log_info "  使用 docker compose (v2)"
    elif docker-compose --version &>/dev/null; then
        DOCKER_COMPOSE="docker-compose"
        log_info "  使用 docker-compose (v1)"
    else
        log_error "未找到 docker compose 或 docker-compose 命令"
        exit 1
    fi
}


# ════════════════════════════════════════════════════════════════
# 前置检查
# ════════════════════════════════════════════════════════════════
NETWORK_NAME="chaos-il2cpp-nightly-test_jenkins"

preflight_checks() {
    local errors=0

    log_step "前置检查..."

    # Docker 是否可用
    if ! docker info &>/dev/null; then
        log_fail "Docker 未运行或当前用户无权限"
        errors=$((errors + 1))
    else
        log_ok "Docker 运行正常 ($(docker --version))"
    fi

    # docker compose 命令
    detect_docker_compose

    # booming-il2cpp 源码目录
    if [[ -d "$BOOMING_DIR/.git" ]]; then
        log_ok "booming-il2cpp 源码目录存在 ($BOOMING_DIR)"
    else
        log_warn "booming-il2cpp 源码目录不存在或无 .git，Nightly Build 会失败"
        log_warn "  请先克隆仓库: git clone <repo> $BOOMING_DIR"
        errors=$((errors + 1))
    fi

    # 报告数据目录权限
    for d in daily db archive; do
        local p="${REPORT_DATA_DIR}/${d}"
        if mkdir -p "$p" 2>/dev/null; then
            :  # ok
        else
            log_warn "无法创建目录 $p（可能是权限不足，尝试 sudo）"
            errors=$((errors + 1))
        fi
    done

    if [[ $errors -gt 0 ]]; then
        log_error "前置检查未通过 ($errors 个问题)，请修复后重试"
        exit 1
    fi
}


# ════════════════════════════════════════════════════════════════
# 目录初始化
# ════════════════════════════════════════════════════════════════
init_directories() {
    log_step "初始化数据目录..."
    for d in daily db archive; do
        mkdir -p "${REPORT_DATA_DIR}/${d}"
        log_ok "${REPORT_DATA_DIR}/${d}"
    done

    # 初始化 last-reviewed-commit.json（如果不存在）
    if [[ ! -f "$STATE_FILE" ]]; then
        echo '{"last_reviewed_commit":"","last_review_time":"","last_result":"not_started"}' > "$STATE_FILE"
        log_ok "初始化审查状态文件: $STATE_FILE"
    fi
}


# ════════════════════════════════════════════════════════════════
# 环境变量配置
# ════════════════════════════════════════════════════════════════
init_env() {
    log_step "检查环境变量..."
    local env_ok=true

    if [[ ! -f "${REPO_ROOT}/.env" ]]; then
        if [[ -f "${REPO_ROOT}/.env.example" ]]; then
            cp "${REPO_ROOT}/.env.example" "${REPO_ROOT}/.env"
            log_warn ".env 不存在，已从 .env.example 复制模板"
            log_warn "请编辑 ${REPO_ROOT}/.env 填入实际值"
            env_ok=false
        else
            log_warn ".env 和 .env.example 都不存在"
            env_ok=false
        fi
    fi

    # 导出环境变量
    set -a; source "${REPO_ROOT}/.env" 2>/dev/null || true; set +a

    # 验证关键变量
    if [[ -z "${SONAR_TOKEN:-}" || "${SONAR_TOKEN:-}" == "your_sonar_token_here" ]]; then
        log_warn "SONAR_TOKEN 未配置，SonarQube 分析将失败"
        env_ok=false
    else
        log_ok "SONAR_TOKEN 已配置"
    fi

    if [[ -z "${FEISHU_WEBHOOK_URL:-}" || "${FEISHU_WEBHOOK_URL:-}" == *"your_webhook_id"* ]]; then
        log_warn "FEISHU_WEBHOOK_URL 未配置，飞书通知将跳过"
    else
        log_ok "FEISHU_WEBHOOK_URL 已配置"
    fi

    if [[ -n "${JENKINS_ADMIN_ID:-}" && -n "${JENKINS_ADMIN_PASSWORD:-}" ]]; then
        log_ok "Jenkins 凭证: ${JENKINS_ADMIN_ID} / ${JENKINS_ADMIN_PASSWORD}"
    fi

    $env_ok || log_warn "部分环境变量缺失，请编辑 ${REPO_ROOT}/.env"
}


# ════════════════════════════════════════════════════════════════
# Docker 网络
# ════════════════════════════════════════════════════════════════
ensure_network() {
    if ! docker network ls --format '{{.Name}}' | grep -q "^${NETWORK_NAME}$"; then
        log_step "创建 Docker 网络: ${NETWORK_NAME}"
        docker network create "$NETWORK_NAME" 2>/dev/null
        log_ok "Docker 网络已创建"
    else
        log_ok "Docker 网络 ${NETWORK_NAME} 已存在"
    fi
}


# ════════════════════════════════════════════════════════════════
# Crontab 管理 (code review 触发器)
# ════════════════════════════════════════════════════════════════
CRON_LABEL="chaos-il2cpp-code-review-trigger"
CRON_LINE="* * * * * ${TRIGGER_SCRIPT} 2>&1 | logger -t cr-trigger"

setup_crontab() {
    log_step "配置 code review crontab..."

    if [[ ! -x "$TRIGGER_SCRIPT" ]]; then
        chmod +x "$TRIGGER_SCRIPT"
    fi

    local existing
    existing=$(crontab -l 2>/dev/null || true)

    # 检查是否已存在相同的定时任务（通过脚本路径匹配，而非标签）
    if echo "$existing" | grep -qF "$TRIGGER_SCRIPT"; then
        # 检查是否需要添加标签，或路径是否有变化
        if echo "$existing" | grep -q "${CRON_LABEL}"; then
            log_ok "crontab 已存在，无需更新"
        else
            # 已有脚本但无标签，追加标签行
            local new_cron
            new_cron=$(echo "$existing" | sed "s|${TRIGGER_SCRIPT}.*|${CRON_LINE}|")
            echo "$new_cron" | crontab -
            log_ok "crontab 已更新（添加标签）"
        fi
    else
        # 完全不存在，追加
        (echo "$existing"; echo "${CRON_LINE}  # ${CRON_LABEL}") | crontab -
        log_ok "crontab 已添加 (每分钟检测新提交触发 code review)"
    fi
}

remove_crontab() {
    log_step "移除 code review crontab..."
    local existing
    existing=$(crontab -l 2>/dev/null || true)
    local new_cron
    new_cron=$(echo "$existing" | grep -v "${CRON_LABEL}" || true)
    if [[ "$new_cron" != "$existing" ]]; then
        echo "$new_cron" | crontab -
        log_ok "crontab 已移除"
    else
        log_info "crontab 不存在，无需移除"
    fi
}


# ════════════════════════════════════════════════════════════════
# Docker Compose 操作
# ════════════════════════════════════════════════════════════════
start_services() {
    local compose_file="$1"
    local profile="$2"
    local services="${3:-}"

    log_step "启动 ${profile}..."
    if [[ -n "$services" ]]; then
        if $DOCKER_COMPOSE -f "$compose_file" up -d $services; then
            log_ok "${profile} 已启动"
        else
            log_error "${profile} 启动失败"
            return 1
        fi
    else
        if $DOCKER_COMPOSE -f "$compose_file" up -d; then
            log_ok "${profile} 已启动"
        else
            log_error "${profile} 启动失败"
            return 1
        fi
    fi
}

start_services_build() {
    local compose_file="$1"
    local profile="$2"
    local services="${3:-}"

    log_step "构建并启动 ${profile}..."
    if [[ -n "$services" ]]; then
        $DOCKER_COMPOSE -f "$compose_file" up -d --build $services
    else
        $DOCKER_COMPOSE -f "$compose_file" up -d --build
    fi
    log_ok "${profile} 构建并启动完成"
}

stop_services() {
    local compose_file="$1"
    local profile="$2"
    log_step "停止 ${profile}..."
    $DOCKER_COMPOSE -f "$compose_file" down
    log_ok "${profile} 已停止"
}


# ════════════════════════════════════════════════════════════════
# 等待容器健康
# ════════════════════════════════════════════════════════════════
wait_for_container() {
    local container="$1"
    local service="$2"
    local max_retries="${3:-30}"
    local retry=0

    log_step "等待 ${service} (${container}) 就绪..."
    while [[ $retry -lt $max_retries ]]; do
        if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
            local health
            health=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "none")
            if [[ "$health" == "healthy" ]]; then
                log_ok "${service} 健康就绪"
                return 0
            fi
            if [[ "$health" == "none" ]]; then
                # 无 health check 的容器，确认进程运行即可
                log_ok "${service} 已运行 (无 health check)"
                return 0
            fi
        fi
        retry=$((retry + 1))
        sleep 2
    done
    log_warn "${service} 未完全就绪（超时 ${max_retries}s）"
    return 1
}

wait_for_jenkins_http() {
    local max_retries="${1:-60}"
    local retry=0

    log_step "等待 Jenkins HTTP 就绪..."
    while [[ $retry -lt $max_retries ]]; do
        local code
        code=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/login 2>/dev/null || echo "000")
        if [[ "$code" == "200" || "$code" == "403" ]]; then
            log_ok "Jenkins HTTP 就绪 (${code})"
            return 0
        fi
        retry=$((retry + 1))
        sleep 5
    done
    log_warn "Jenkins HTTP 未就绪（超时）"
    return 1
}

wait_for_jenkins_init() {
    # 等待 init.groovy 完成（Agent 注册 + 凭证创建）
    local max_retries="${1:-60}"
    local retry=0

    log_step "等待 Jenkins 初始化脚本执行完成..."
    while [[ $retry -lt $max_retries ]]; do
        local agent_count
        agent_count=$(curl -s -u "${JENKINS_ADMIN_ID}:${JENKINS_ADMIN_PASSWORD}" \
            "http://localhost:8080/computer/api/json" 2>/dev/null \
            | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('computer',[]))-1)" 2>/dev/null || echo "0")
        if [[ "$agent_count" -ge 3 ]]; then
            log_ok "Jenkins 初始化完成 (${agent_count} Agent 节点已注册)"
            return 0
        fi
        retry=$((retry + 1))
        sleep 5
    done
    log_warn "Jenkins 初始化可能未完成"
    return 1
}


# ════════════════════════════════════════════════════════════════
# 等待 Agent 连接
# ════════════════════════════════════════════════════════════════
wait_for_agents() {
    local max_retries="${1:-60}"
    local retry=0
    local admin="${JENKINS_ADMIN_ID:-qa004}"
    local pass="${JENKINS_ADMIN_PASSWORD:-abcd@1234}"

    log_step "等待 Agent 节点连接 Jenkins..."
    while [[ $retry -lt $max_retries ]]; do
        local online=0
        local total=0
        local agents_json
        agents_json=$(curl -s -u "${admin}:${pass}" \
            "http://localhost:8080/computer/api/json" 2>/dev/null || echo '{}')

        # 解析各 agent 在线状态（排除 Built-In Node）
        while IFS= read -r line; do
            local name status
            name=$(echo "$line" | cut -d'|' -f1)
            status=$(echo "$line" | cut -d'|' -f2)
            if [[ "$name" != "Built-In Node" && "$name" != "master" ]]; then
                total=$((total + 1))
                if [[ "$status" == "false" ]]; then  # offline=false 表示在线
                    online=$((online + 1))
                fi
            fi
        done < <(echo "$agents_json" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    for c in d.get('computer', []):
        print(f\"{c['displayName']}|{c['offline']}\")
except: pass" 2>/dev/null || true)

        if [[ $total -ge 1 ]]; then
            log_info "  Agents: ${online}/${total} 在线"
            if [[ $online -eq $total ]]; then
                log_ok "所有 Agent 节点已就绪"
                return 0
            fi
        fi
        retry=$((retry + 1))
        sleep 5
    done
    log_warn "部分 Agent 未连接 (${online}/${total} 在线)"
    return 1
}


# ════════════════════════════════════════════════════════════════
# 健康检查
# ════════════════════════════════════════════════════════════════
health_checks() {
    local all_ok=true
    log_step "运行服务健康检查..."

    # Jenkins
    local jk
    jk=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/login 2>/dev/null || echo "000")
    if [[ "$jk" == "200" || "$jk" == "403" ]]; then
        log_ok "Jenkins (localhost:8080) — HTTP ${jk}"
    else
        log_fail "Jenkins (localhost:8080) — HTTP ${jk}"; all_ok=false
    fi

    # SonarQube
    local sq
    sq=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:9000 2>/dev/null || echo "000")
    if [[ "$sq" == "200" ]]; then
        log_ok "SonarQube (localhost:9000) — HTTP ${sq}"
    else
        log_fail "SonarQube (localhost:9000) — HTTP ${sq}"; all_ok=false
    fi

    # Report API
    local api
    api=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8081/api/health 2>/dev/null || echo "000")
    if [[ "$api" == "200" ]]; then
        log_ok "Report API (localhost:8081/api) — HTTP ${api}"
    else
        log_fail "Report API (localhost:8081/api) — HTTP ${api}"; all_ok=false
    fi

    # Report Server
    local rs
    rs=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8081/ 2>/dev/null || echo "000")
    if [[ "$rs" == "200" ]]; then
        log_ok "Report Server (localhost:8081) — HTTP ${rs}"
    else
        log_fail "Report Server (localhost:8081) — HTTP ${rs}"; all_ok=false
    fi

    # MinIO
    local mi
    mi=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:9002/minio/health/live 2>/dev/null || echo "000")
    if [[ "$mi" == "200" ]]; then
        log_ok "MinIO (localhost:9002) — HTTP ${mi}"
    else
        log_fail "MinIO (localhost:9002) — HTTP ${mi}"; all_ok=false
    fi

    echo ""
    if $all_ok; then
        log_info "所有服务健康检查通过"
    else
        log_warn "部分服务异常，请检查日志: $DOCKER_COMPOSE logs <service>"
    fi
    return 0
}


# ════════════════════════════════════════════════════════════════
# Jenkins 任务状态检查
# ════════════════════════════════════════════════════════════════
check_jenkins_jobs() {
    local admin="${JENKINS_ADMIN_ID:-qa004}"
    local pass="${JENKINS_ADMIN_PASSWORD:-abcd@1234}"

    log_step "检查 Jenkins 任务状态..."
    local jobs_json
    jobs_json=$(curl -s -u "${admin}:${pass}" --get \
        --data-urlencode 'tree=jobs[name,lastBuild[result,number],color]' \
        'http://localhost:8080/api/json' 2>/dev/null) || true

    if [[ -z "$jobs_json" ]]; then
        log_warn "无法获取 Jenkins 任务列表（API 未就绪或凭证错误）"
        return 1
    fi

    echo "$jobs_json" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    for job in d.get('jobs', []):
        name = job['name']
        color = job.get('color', 'unknown')
        lb = job.get('lastBuild') or {}
        result = lb.get('result', '-') if lb else '-'
        num = lb.get('number', '-') if lb else '-'
        status = '✓' if result == 'SUCCESS' else ('✗' if result in ('FAILURE','ABORTED') else '○')
        print(f'  {status} {name}  (last #{num}: {result})')
except Exception as e:
    print(f'  Failed to parse: {e}')
" 2>/dev/null || log_warn "无法获取任务状态"
}


# ════════════════════════════════════════════════════════════════
# 状态查看
# ════════════════════════════════════════════════════════════════
status_services() {
    local all_containers_running=true

    echo ""
    log_step "服务运行状态"
    echo ""

    # 定义所有容器
    declare -A CONTAINERS
    CONTAINERS["Jenkins Master"]="chaos-master:8080->8080"
    CONTAINERS["Agent linux-x64 (构建)"]="chaos-agent-x64:-"
    CONTAINERS["Agent linux-arm64 (ARM)"]="chaos-agent-arm64:-"
    CONTAINERS["Agent android-arm64 (NDK)"]="chaos-agent-android:-"
    CONTAINERS["Agent linux-x64-cr (审查)"]="chaos-agent-cr:-"
    CONTAINERS["SonarQube"]="chaos-sonarqube:9000->9000"
    CONTAINERS["PostgreSQL (Sonar)"]="chaos-sonar-db:-"
    CONTAINERS["Report Server (Nginx)"]="chaos-report-server:80->8081"
    CONTAINERS["Report API (FastAPI)"]="chaos-report-api:-"
    CONTAINERS["MinIO (S3 存储)"]="chaos-minio:9000->9002"

    printf "  %-32s %-12s %s\n" "容器" "状态" "端口映射"
    printf "  %-32s %-12s %s\n" "----" "----" "--------"

    for name in "${!CONTAINERS[@]}"; do
        local info="${CONTAINERS[$name]}"
        local container="${info%%:*}"
        local port_info="${info#*:}"
        local host_port="${port_info#*->}"
        local cont_port="${port_info%->*}"

        if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
            local status_str
            local health
            health=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null) || true
            if [[ "$health" == "" ]]; then health="none"; fi
            if [[ "$health" == "healthy" ]]; then
                status_str="${GREEN}健康${NC}"
            elif [[ "$health" == "none" ]]; then
                status_str="${GREEN}运行中${NC}"
            else
                status_str="${YELLOW}${health}${NC}"
            fi

            if [[ "$port_info" == "-" ]]; then
                printf "  %-32s %b %s\n" "$name" "$status_str" "(内部)"
            elif [[ "$port_info" == *"->"* ]]; then
                printf "  %-32s %b :%s\\n" "$name" "$status_str" "$host_port"
            else
                printf "  %-32s %b :%s\n" "$name" "$status_str" ":$port_info"
            fi
        else
            printf "  %-32s ${RED}已停止${NC}\n" "$name"
            all_containers_running=false
        fi
    done

    echo ""

    if $all_containers_running; then
        # 如果 Jenkins 在运行，额外显示任务状态
        if docker ps --format '{{.Names}}' | grep -q "^chaos-master$"; then
            check_jenkins_jobs
            echo ""
        fi
        log_info "所有容器运行正常"
    else
        log_warn "部分容器未运行，请执行 $(basename "$0") 启动"
    fi
}


# ════════════════════════════════════════════════════════════════
# 打印汇总
# ════════════════════════════════════════════════════════════════
print_summary() {
    echo ""
    echo "============================================================"
    echo "  chaos-il2cpp CI/CD   启动完成"
    echo "============================================================"
    echo ""
    echo "  访问入口:"
    echo ""
    echo "  Jenkins        ${CYAN}http://localhost:8080${NC}"
    echo "   用户:        ${JENKINS_ADMIN_ID:-qa004} / ${JENKINS_ADMIN_PASSWORD:-abcd@1234}"
    echo ""
    echo "  SonarQube      ${CYAN}http://localhost:9000${NC}"
    echo "   用户:        admin / admin"
    echo ""
    echo "  Report Server  ${CYAN}http://localhost:8081${NC}"
    echo "   最新报告     ${CYAN}http://localhost:8081/latest${NC}"
    echo "   历史浏览     ${CYAN}http://localhost:8081/daily/${NC}"
    echo "   API 列表     ${CYAN}http://localhost:8081/api/reports${NC}"
    echo "   趋势图       ${CYAN}http://localhost:8081/${NC}"
    echo ""
    echo "  MinIO Console  ${CYAN}http://localhost:9003${NC}"
    echo "   用户:        minioadmin / minioadmin"
    echo ""
    echo "  Scheduled Jobs:"
    echo "    Nightly Build   每日 03:00 / 12:15 (Jenkins cron)"
    echo "    Code Review     每分钟检测新提交 (host crontab)"
    echo ""
    echo "  数据目录:"
    echo "    报告文件     ${REPORT_DATA_DIR}/daily/"
    echo "    趋势数据库   ${REPORT_DATA_DIR}/db/"
    echo "    归档         ${REPORT_DATA_DIR}/archive/"
    echo ""
    echo "  查看日志:"
    echo "    全部服务     $DOCKER_COMPOSE -f ${COMPOSE_FILE##*/} logs -f"
    echo "    单独服务     $DOCKER_COMPOSE logs -f <service-name>"
    echo ""
    echo "============================================================"
}


# ════════════════════════════════════════════════════════════════
# 完全清理
# ════════════════════════════════════════════════════════════════
clean_all() {
    log_warn "正在停止并清理所有服务和数据卷..."
    $DOCKER_COMPOSE -f "$COMPOSE_FILE" down -v 2>/dev/null || true
    $DOCKER_COMPOSE -f "$SONAR_COMPOSE_FILE" down -v 2>/dev/null || true
    log_ok "所有服务已停止，数据卷已删除"

    # 询问是否移除 crontab
    if crontab -l 2>/dev/null | grep -q "${CRON_LABEL}"; then
        echo ""
        log_warn "检测到 code review crontab 仍存在"
        read -rp "  是否同时移除 crontab？(y/N): " confirm
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            remove_crontab
        fi
    fi
}


# ════════════════════════════════════════════════════════════════
# 主流程
# ════════════════════════════════════════════════════════════════
MODE="start"
BUILD=false

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --build)        BUILD=true; MODE="start" ;;
            --stop)         MODE="stop" ;;
            --restart)      MODE="restart" ;;
            --status)       MODE="status" ;;
            --init)         MODE="init" ;;
            --sonar-only)   MODE="sonar-only" ;;
            --jenkins-only) MODE="jenkins-only" ;;
            --report-only)  MODE="report-only" ;;
            --setup-cron)   MODE="setup-cron" ;;
            --clean)        MODE="clean" ;;
            --help|-h)
                echo "用法: bash scripts/startup.sh [选项]"
                echo ""
                echo "选项:"
                grep -E '^#   --' "$0" | sed 's/#   / /' | head -12
                exit 0 ;;
            *) log_error "未知选项: $1"; exit 1 ;;
        esac
        shift
    done
}

main() {
    parse_args "$@"

    case "$MODE" in

        # ──────────────────────────── 初始化环境 ────────────────────────────
        init)
            preflight_checks
            init_directories
            init_env
            setup_crontab
            log_info "初始化完成"
            ;;

        # ──────────────────────────── 完整启动 ────────────────────────────
        start)
            echo ""
            echo "=================================="
            echo "  chaos-il2cpp CI/CD 启动"
            echo "=================================="
            echo ""

            preflight_checks
            init_directories
            init_env
            ensure_network
            setup_crontab

            local extra_args=""
            $BUILD && extra_args="--build"

            # 1. 启动 SonarQube (先 PostgreSQL)
            log_step "开始启动依次: SonarQube → Jenkins+Agents → Report..."
            echo ""
            if $BUILD; then
                start_services_build "$SONAR_COMPOSE_FILE" "SonarQube"
            else
                start_services "$SONAR_COMPOSE_FILE" "SonarQube"
            fi
            wait_for_container "chaos-sonar-db" "PostgreSQL" 30
            wait_for_container "chaos-sonarqube" "SonarQube" 90

            # 2. 启动 Jenkins + Agents + Report + MinIO
            echo ""
            if $BUILD; then
                start_services_build "$COMPOSE_FILE" "Jenkins + Agents + Report"
            else
                start_services "$COMPOSE_FILE" "Jenkins + Agents + Report"
            fi

            # 3. 等待关键服务
            wait_for_container "chaos-minio" "MinIO" 30
            wait_for_container "chaos-report-api" "Report API" 30
            wait_for_container "chaos-report-server" "Report Server" 30
            wait_for_jenkins_http 90

            # 4. 等待 Jenkins init.groovy 执行完成 (Agent 注册)
            wait_for_jenkins_init 60

            # 5. 等待 Agent 连接
            wait_for_agents 90

            # 6. 健康检查
            echo ""
            health_checks
            echo ""

            # 7. 任务状态
            check_jenkins_jobs

            # 8. 汇总
            print_summary
            ;;

        # ──────────────────────────── 停止 ────────────────────────────
        stop)
            detect_docker_compose
            stop_services "$COMPOSE_FILE" "Jenkins + Report"
            stop_services "$SONAR_COMPOSE_FILE" "SonarQube"
            log_info "所有服务已停止"
            echo ""
            log_info "code review crontab 仍保留，不会继续触发"
            log_info "如需完全停止审查: bash $(basename "$0") --clean"
            ;;

        # ──────────────────────────── 重启 ────────────────────────────
        restart)
            detect_docker_compose
            stop_services "$COMPOSE_FILE" "Jenkins + Report"
            stop_services "$SONAR_COMPOSE_FILE" "SonarQube"
            echo ""
            MODE="start"
            main
            ;;

        # ──────────────────────────── 状态 ────────────────────────────
        status)
            detect_docker_compose
            init_env &>/dev/null || true  # 加载 .env 供 Jenkins API 使用
            status_services
            ;;

        # ──────────────────────────── SonarQube 单独 ────────────────────────────
        sonar-only)
            preflight_checks
            init_directories
            ensure_network
            if $BUILD; then
                start_services_build "$SONAR_COMPOSE_FILE" "SonarQube"
            else
                start_services "$SONAR_COMPOSE_FILE" "SonarQube"
            fi
            wait_for_container "chaos-sonar-db" "PostgreSQL" 30
            wait_for_container "chaos-sonarqube" "SonarQube" 90
            ;;

        # ──────────────────────────── Jenkins 单独 ────────────────────────────
        jenkins-only)
            preflight_checks
            init_directories
            ensure_network
            if $BUILD; then
                start_services_build "$COMPOSE_FILE" "Jenkins + Agents + Report"
            else
                start_services "$COMPOSE_FILE" "Jenkins + Agents + Report"
            fi
            wait_for_jenkins_http 120
            wait_for_jenkins_init 60
            wait_for_agents 90
            ;;

        # ──────────────────────────── Report 单独 ────────────────────────────
        report-only)
            preflight_checks
            init_directories
            if $BUILD; then
                $DOCKER_COMPOSE -f "$COMPOSE_FILE" up -d --build report-server report-api 2>/dev/null
            else
                $DOCKER_COMPOSE -f "$COMPOSE_FILE" up -d report-server report-api 2>/dev/null
            fi
            wait_for_container "chaos-report-api" "Report API" 30
            wait_for_container "chaos-report-server" "Report Server" 30
            ;;

        # ──────────────────────────── Crontab 单独 ────────────────────────────
        setup-cron)
            setup_crontab
            ;;

        # ──────────────────────────── 清理 ────────────────────────────
        clean)
            detect_docker_compose
            clean_all
            ;;

        *)
            log_error "未知模式: $MODE"
            exit 1 ;;
    esac
}

detect_docker_compose
main "$@"
