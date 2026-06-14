#!/bin/bash
# ==============================================================
# startup.sh — chaos-il2cpp 全平台 CI/CD 一键启动脚本
#
# 功能：
#   - 初始化目录结构
#   - 构建并启动所有 Docker 服务
#   - 等待各服务就绪
#   - 打印访问入口汇总
#
# 用法：
#   bash scripts/startup.sh [选项]
#
# 选项：
#   --build         启动前重新构建所有镜像
#   --stop          停止所有服务
#   --restart       重启所有服务
#   --status        查看各服务状态
#   --init          仅初始化目录和配置，不启动
#   --sonar-only    仅启动 SonarQube 栈
#   --jenkins-only  仅启动 Jenkins 栈
#   --report-only   仅启动 Report Server 栈
#   --help          显示帮助信息
# ==============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${REPO_ROOT}/docker-compose.yml"
SONAR_COMPOSE_FILE="${REPO_ROOT}/sonarqube/docker-compose.yml"

# ── 颜色输出 ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${BLUE}[STEP]${NC}  $1"; }


# ── 目录结构 ──
DIRS=(
    "/var/lib/report-server/daily"
    "/var/lib/report-server/db"
    "/var/lib/report-server/archive"
)

init_directories() {
    log_step "初始化数据目录..."
    for d in "${DIRS[@]}"; do
        mkdir -p "$d"
        log_info "  创建: $d"
    done
}

NETWORK_NAME="chaos-il2cpp-nightly-test_jenkins"

ensure_network() {
    if ! docker network ls --format '{{.Name}}' | grep -q "^${NETWORK_NAME}$"; then
        log_step "创建 Docker 网络: ${NETWORK_NAME}"
        docker network create "$NETWORK_NAME" 2>/dev/null
        log_info "  Docker 网络已创建"
    else
        log_info "  Docker 网络 ${NETWORK_NAME} 已存在"
    fi
}


# ── 环境变量 ──
init_env() {
    log_step "检查环境变量..."
    if [[ ! -f "${REPO_ROOT}/.env" ]]; then
        if [[ -f "${REPO_ROOT}/.env.example" ]]; then
            cp "${REPO_ROOT}/.env.example" "${REPO_ROOT}/.env"
            log_warn "  .env 文件不存在，已从 .env.example 复制"
            log_warn "  请编辑 ${REPO_ROOT}/.env 填入实际值"
        else
            log_warn "  .env 和 .env.example 都不存在，跳过"
        fi
    else
        log_info "  .env 已存在"
    fi

    # 导出环境变量
    set -a; source "${REPO_ROOT}/.env" 2>/dev/null || true; set +a
}


# ── Docker Compose 操作 ──
start_services() {
    local compose_file="$1"
    local profile="$2"
    local extra_args="${3:-}"

    log_step "启动 ${profile} 服务..."
    if [[ "$extra_args" == *"--build"* ]]; then
        log_info "  重新构建镜像..."
        docker compose -f "$compose_file" up -d --build
    else
        docker compose -f "$compose_file" up -d
    fi
    log_info "  ${profile} 服务已启动"
}

stop_services() {
    local compose_file="$1"
    local profile="$2"

    log_step "停止 ${profile} 服务..."
    docker compose -f "$compose_file" down
    log_info "  ${profile} 服务已停止"
}

status_services() {
    log_step "服务运行状态"
    echo ""
    printf "  %-25s %-15s %s\n" "服务" "状态" "端口"
    printf "  %-25s %-15s %s\n" "----" "----" "----"

    declare -A SERVICES
    SERVICES["Jenkins Master"]="chaos-master:8080"
    SERVICES["Agent linux-x64"]="chaos-agent-x64:-"
    SERVICES["Agent linux-arm64"]="chaos-agent-arm64:-"
    SERVICES["Agent android-arm64"]="chaos-agent-android:-"
    SERVICES["SonarQube"]="chaos-sonarqube:9000"
    SERVICES["PostgreSQL"]="chaos-sonar-db:5432"
    SERVICES["Report Server"]="chaos-report-server:80"
    SERVICES["Report API"]="chaos-report-api:8000"

    for name in "${!SERVICES[@]}"; do
        local info="${SERVICES[$name]}"
        local container="${info%%:*}"
        local port="${info##*:}"
        if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
            local container_port=""
            if [[ "$port" != "-" ]]; then
                container_port=$(docker port "$container" "$port" 2>/dev/null | head -1 | sed 's/.*://' || echo "$port")
            fi
            local status_str="运行中"
            if [[ -n "$container_port" && "$container_port" != "$port" ]]; then
                printf "  %-25s ${GREEN}%-15s${NC} %s\n" "$name" "$status_str" ":$container_port"
            else
                printf "  %-25s ${GREEN}%-15s${NC} %s\n" "$name" "$status_str" "内部端口 $port"
            fi
        else
            printf "  %-25s ${RED}%-15s${NC} %s\n" "$name" "未运行" "-"
        fi
    done
}


# ── 健康检查 ──
wait_for_healthy() {
    local container="$1"
    local service="$2"
    local max_retries="${3:-30}"
    local retry=0

    log_step "等待 ${service} 就绪..."
    while [[ $retry -lt $max_retries ]]; do
        if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
            # Check container health
            local health=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "none")
            if [[ "$health" == "healthy" ]] || [[ "$health" == "none" ]]; then
                log_info "  ${service} 就绪"
                return 0
            fi
        fi
        retry=$((retry + 1))
        sleep 2
    done
    log_warn "  ${service} 未完全就绪（超时）"
    return 1
}

health_checks() {
    log_step "运行健康检查..."

    # Jenkins
    if docker ps --format '{{.Names}}' | grep -q "^chaos-master$"; then
        local jenkins_status
        jenkins_status=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/login 2>/dev/null || echo "000")
        if [[ "$jenkins_status" == "200" || "$jenkins_status" == "403" ]]; then
            log_info "  Jenkins: OK (HTTP ${jenkins_status})"
        else
            log_warn "  Jenkins: HTTP ${jenkins_status}"
        fi
    fi

    # SonarQube
    if docker ps --format '{{.Names}}' | grep -q "^chaos-sonarqube$"; then
        local sq_status
        sq_status=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:9000 2>/dev/null || echo "000")
        if [[ "$sq_status" == "200" ]]; then
            log_info "  SonarQube: OK"
        else
            log_warn "  SonarQube: HTTP ${sq_status}"
        fi
    fi

    # Report API
    if docker ps --format '{{.Names}}' | grep -q "^chaos-report-api$"; then
        local api_status
        api_status=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8081/api/health 2>/dev/null || echo "000")
        if [[ "$api_status" == "200" ]]; then
            log_info "  Report API: OK"
        else
            log_warn "  Report API: HTTP ${api_status}（可能是 Nginx proxy 未就绪）"
        fi
    fi

    # Report Server
    if docker ps --format '{{.Names}}' | grep -q "^chaos-report-server$"; then
        local rs_status
        rs_status=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8081/ 2>/dev/null || echo "000")
        if [[ "$rs_status" == "200" ]]; then
            log_info "  Report Server: OK"
        else
            log_warn "  Report Server: HTTP ${rs_status}"
        fi

        # MinIO
        local minio_status
        minio_status=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:9002/minio/health/live 2>/dev/null || echo "000")
        if [[ "$minio_status" == "200" ]]; then
            log_info "  MinIO: OK (HTTP ${minio_status})"
        else
            log_warn "  MinIO: HTTP ${minio_status}"
        fi
    fi
}


# ── 打印汇总信息 ──
print_summary() {
    echo ""
    echo "============================================"
    echo "  chaos-il2cpp CI/CD 启动完成"
    echo "============================================"
    echo ""
    echo "  访问入口:"
    echo ""
    echo "  Jenkins        http://localhost:8080"
    echo "   用户:       admin / abcd@1234"
    echo ""
    echo "  SonarQube      http://localhost:9000"
    echo "   用户:       admin / admin"
    echo ""
    echo "  Report Server  http://localhost:8081"
    echo "   最新报告     http://localhost:8081/latest"
    echo "   历史浏览     http://localhost:8081/daily/"
    echo "   API 列表     http://localhost:8081/api/reports"
    echo "   趋势图       http://localhost:8081/"
    echo ""
    echo "  MinIO Console  http://localhost:9003"
    echo "   用户:       minioadmin / minioadmin"
    echo "   API          http://localhost:9002"
    echo ""
    echo "  数据目录:"
    echo "   报告文件     /var/lib/report-server/daily/"
    echo "   趋势数据库   /var/lib/report-server/db/"
    echo ""
    echo "  Nightly 定时: Jenkins 内置 cron — 每日 03:00"
    echo ""
    echo "  查看日志:"
    echo "   全部服务     docker compose logs -f"
    echo "   单独服务     docker compose logs <service-name>"
    echo ""
    echo "============================================"
}


# ── 清空旧数据 (慎用) ──
clean_all() {
    log_warn "正在停止并清理所有服务..."
    docker compose -f "$COMPOSE_FILE" down -v 2>/dev/null || true
    docker compose -f "$SONAR_COMPOSE_FILE" down -v 2>/dev/null || true
    log_info "  服务已停止，数据卷已删除"
}


# ── 主流程 ──
MODE="start"
BUILD=false

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --build)       BUILD=true; MODE="start" ;;
            --stop)        MODE="stop" ;;
            --restart)     MODE="restart" ;;
            --status)      MODE="status" ;;
            --init)        MODE="init" ;;
            --sonar-only)  MODE="sonar-only" ;;
            --jenkins-only) MODE="jenkins-only" ;;
            --report-only) MODE="report-only" ;;
            --clean)       MODE="clean" ;;
            --help|-h)
                echo "用法: bash scripts/startup.sh [选项]"
                echo ""
                grep -E '^#   --' "$0" | sed 's/#   / /'
                exit 0 ;;
            *) log_error "未知选项: $1"; exit 1 ;;
        esac
        shift
    done
}

main() {
    parse_args "$@"

    case "$MODE" in
        init)
            init_directories
            init_env
            log_info "初始化完成"
            ;;

        start)
            init_directories
            init_env
            ensure_network

            local extra_args=""
            $BUILD && extra_args="--build"

            # 启动顺序: PostgreSQL → SonarQube → Jenkins → Agents → Report
            start_services "$SONAR_COMPOSE_FILE" "SonarQube" "$extra_args"
            wait_for_healthy "chaos-sonar-db" "PostgreSQL" 30
            wait_for_healthy "chaos-sonarqube" "SonarQube" 60

            start_services "$COMPOSE_FILE" "Jenkins + Report" "$extra_args"

            # 等待关键服务就绪
            wait_for_healthy "chaos-master" "Jenkins" 120
            wait_for_healthy "chaos-report-api" "Report API" 30
            wait_for_healthy "chaos-report-server" "Report Server" 30

            health_checks
            print_summary
            ;;

        stop)
            stop_services "$COMPOSE_FILE" "Jenkins + Report"
            stop_services "$SONAR_COMPOSE_FILE" "SonarQube"
            log_info "所有服务已停止"
            ;;

        restart)
            stop_services "$COMPOSE_FILE" "Jenkins + Report"
            stop_services "$SONAR_COMPOSE_FILE" "SonarQube"
            MODE="start"
            BUILD="$BUILD"
            main
            ;;

        status)
            status_services
            ;;

        sonar-only)
            init_directories
            ensure_network
            local extra_args=""
            $BUILD && extra_args="--build"
            start_services "$SONAR_COMPOSE_FILE" "SonarQube" "$extra_args"
            wait_for_healthy "chaos-sonar-db" "PostgreSQL" 30
            wait_for_healthy "chaos-sonarqube" "SonarQube" 60
            ;;

        jenkins-only)
            init_directories
            ensure_network
            local extra_args=""
            $BUILD && extra_args="--build"
            start_services "$COMPOSE_FILE" "Jenkins + Report" "$extra_args"
            wait_for_healthy "chaos-master" "Jenkins" 120
            ;;

        report-only)
            init_directories
            local extra_args=""
            $BUILD && extra_args="--build"
            log_step "启动 Report 服务..."
            docker compose -f "$COMPOSE_FILE" up -d --build report-server report-api 2>/dev/null || \
            docker compose -f "$COMPOSE_FILE" up -d report-server report-api
            wait_for_healthy "chaos-report-api" "Report API" 30
            wait_for_healthy "chaos-report-server" "Report Server" 30
            ;;

        clean)
            clean_all
            ;;

        *)
            log_error "未知模式: $MODE"
            exit 1 ;;
    esac
}

main "$@"
