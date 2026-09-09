#!/bin/bash
# ==============================================================
# chaos-il2cpp Windows Nightly Agent — Linux 侧一键部署与接管
#
# 用途: 在 Windows 用户已跑完 RUN_ME_FIRST.cmd (OpenSSH 已开) 后,
#       本脚本完成所有 Linux 侧操作:
#         1. 引擎源码 rsync 到 Windows
#         2. 检查 Windows agent 服务状态并启动
#         3. 触发首次 Jenkins 构建验证
#         4. 输出日常管理命令速查
#
# 用法:
#   bash deploy-linux-side.sh <windows-ip> [--ssh-user <user>] [--jenkins-secret <secret>]
#
# 参数说明:
#   windows-ip (必填): Windows agent 的 IP, 如 10.10.9.197
#   --ssh-user:        SSH 用户名 (默认 agent)
#   --ssh-pass:        SSH 密码 (若未提供则交互式输入)
#   --jenkins-secret:  Jenkins 节点 secret (若已从 Jenkins UI 获取)
#                      (若未提供则提示在 Jenkins 创建节点后手动更新)
# ==============================================================

set -euo pipefail

# ── 颜色 ──
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[${NC}${CYAN}✓${NC}${GREEN}]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; }

# ── 解析参数 ──
WIN_HOST="${1:-}"
SSH_USER="agent"
SSH_PASS=""
JENKINS_SECRET=""
JENKINS_URL="http://10.10.1.173:8080"
JENKINS_NODE="windows-x64"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BOOMING_DIR="/home/debian/agent/booming-il2cpp"

shift 2>/dev/null || true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ssh-user)    SSH_USER="$2"; shift 2 ;;
        --ssh-pass)    SSH_PASS="$2"; shift 2 ;;
        --jenkins-secret) JENKINS_SECRET="$2"; shift 2 ;;
        *) err "未知参数: $1"; exit 1 ;;
    esac
done

if [[ -z "$WIN_HOST" ]]; then
    echo "用法: bash $0 <windows-ip> [--ssh-user <user>] [--ssh-pass <pass>] [--jenkins-secret <secret>]"
    echo "  例: bash $0 192.168.1.50 --ssh-pass mypass --jenkins-secret abc123def"
    exit 1
fi

# ── 检查必需工具 ──
for cmd in ssh scp rsync; do
    command -v "$cmd" >/dev/null 2>&1 || { err "需要 $cmd 但未安装"; exit 1; }
done

# 安装 sshpass (如果需要)
if [[ -n "$SSH_PASS" && ! -f /usr/bin/sshpass ]]; then
    warn "sshpass 未安装, 尝试自动安装..."
    apt-get update -qq && apt-get install -y -qq sshpass 2>/dev/null || {
        err "无法自动安装 sshpass。请手动: apt-get install sshpass"
        err "或提供 SSH key 认证后重试"
        exit 1
    }
fi

SSH_CMD="ssh ${SSH_USER}@${WIN_HOST}"
SCP_CMD="scp"
if [[ -n "$SSH_PASS" ]]; then
    SSH_CMD="sshpass -p '${SSH_PASS}' ssh -o StrictHostKeyChecking=no ${SSH_USER}@${WIN_HOST}"
    SCP_CMD="sshpass -p '${SSH_PASS}' scp -o StrictHostKeyChecking=no"
else
    SSH_CMD="ssh -o StrictHostKeyChecking=no ${SSH_USER}@${WIN_HOST}"
    SCP_CMD="scp -o StrictHostKeyChecking=no"
fi

echo ""
echo "=============================================="
echo "  chaos-il2cpp Windows Agent — Linux 部署脚本"
echo "  目标: ${SSH_USER}@${WIN_HOST}"
echo "=============================================="
echo ""

# ════════════════════════════════════════════════════════════════
# 1. 检查 Windows SSH 连通性
# ════════════════════════════════════════════════════════════════
echo -e "${CYAN}[1/5]${NC} 检查 Windows SSH 连通性..."
if eval "$SSH_CMD exit" 2>/dev/null; then
    log "Windows SSH 已就绪 (${WIN_HOST})"
else
    err "无法 SSH 到 ${WIN_HOST}. 请确认:"
    err "  1. Windows 上已运行 RUN_ME_FIRST.cmd"
    err "  2. OpenSSH Server 已启动"
    err "  3. 防火墙放行了 22 端口"
    err "  4. 用户名密码正确"
    exit 1
fi

# ════════════════════════════════════════════════════════════════
# 2. 检查引擎源码目录
# ════════════════════════════════════════════════════════════════
echo -e "${CYAN}[2/5]${NC} 检查引擎源码..."
if [[ ! -d "$BOOMING_DIR" ]]; then
    warn "本地引擎源码目录不存在: $BOOMING_DIR"
    warn "将跳过源码同步, 仅部署 agent 配置。"
    SKIP_SYNC=true
else
    SKIP_SYNC=false
fi

# ════════════════════════════════════════════════════════════════
# 3. 同步引擎源码到 Windows
# ════════════════════════════════════════════════════════════════
if [[ "$SKIP_SYNC" == "false" ]]; then
    echo -e "${CYAN}[3/5]${NC} 同步引擎源码到 Windows..."
    WIN_PATH="D:/agent/workspace/booming-il2cpp"
    eval "$SSH_CMD cmd /c if not exist '${WIN_PATH}' mkdir '${WIN_PATH}'" 2>/dev/null

    # 有 sshpass 时用 rsync (更快)
    if [[ -n "$SSH_PASS" ]]; then
        export SSHPASS="$SSH_PASS"
        rsync -az --delete -O -e "sshpass -e ssh -o StrictHostKeyChecking=no" \
            --exclude='.git' --exclude='**/_dll/**' --exclude='**/artifacts/**' \
            --exclude='**/CMakeCache.txt' --exclude='**/CMakeFiles/**' \
            "${BOOMING_DIR}/" "${SSH_USER}@${WIN_HOST}:${WIN_PATH}/" 2>&1
    else
        # 退化为 scp
        echo "  [INFO] 用 scp 同步 (较慢, 仅首次同步, 约 5-15 分钟)..."
        eval "$SCP_CMD -r '${BOOMING_DIR}/testing/foundation-dll' '${SSH_USER}@${WIN_HOST}:${WIN_PATH}/testing/'"
    fi
    log "引擎源码同步完成"
else
    echo -e "${CYAN}[3/5]${NC} 跳过源码同步 (本地无引擎目录)"
fi

# ════════════════════════════════════════════════════════════════
# 4. 配置 Jenkins agent 服务
# ════════════════════════════════════════════════════════════════
echo -e "${CYAN}[4/5]${NC} 配置 Jenkins agent 服务..."

if [[ -n "$JENKINS_SECRET" ]]; then
    NSSM_EXE="D:\agent\nssm\nssm.exe"
    SERVICE_NAME="JenkinsAgent-${JENKINS_NODE}"

    # 更新 NSSM 服务参数 (填入 secret)
    eval "$SSH_CMD \"& '${NSSM_EXE}' set ${SERVICE_NAME} AppParameters '-jar D:\\agent\\agent.jar -url ${JENKINS_URL} -secret ${JENKINS_SECRET} -name ${JENKINS_NODE} -workDir D:\\agent\\workspace'\"" 2>&1
    eval "$SSH_CMD \"& '${NSSM_EXE}' start ${SERVICE_NAME}\"" 2>&1
    log "Jenkins agent 服务已启动 (secret 已设置)"
else
    warn "未提供 --jenkins-secret, 请手动更新:"
    warn "  ssh ${SSH_USER}@${WIN_HOST}"
    warn "  & 'D:\agent\nssm\nssm.exe' set JenkinsAgent-windows-x64 AppParameters \"-jar D:\agent\agent.jar -url http://10.10.1.173:8080 -secret <SECRET> -name windows-x64 -workDir D:\agent\workspace\""
    warn "  & 'D:\agent\nssm\nssm.exe' start JenkinsAgent-windows-x64"
fi

# ════════════════════════════════════════════════════════════════
# 5. 触发首次构建验证
# ════════════════════════════════════════════════════════════════
echo -e "${CYAN}[5/5]${NC} 触发 Jenkins 构建验证..."
JENKINS_CRED="${JENKINS_CRED:-}"
HTTP_CODE=$(curl -s -o /tmp/jenkins_trigger.log -w "%{http_code}" \
    -u "$JENKINS_CRED" \
    -X POST "${JENKINS_URL}/job/chaos-il2cpp-nightly/buildWithParameters" \
    --data-urlencode "BOOMING_REPO=D:/agent/workspace/booming-il2cpp" \
    --data-urlencode "BUILD_CONFIG=profile" 2>&1 || echo "000")

if [[ "$HTTP_CODE" == "201" || "$HTTP_CODE" == "200" ]]; then
    log "Jenkins 构建已触发 (HTTP $HTTP_CODE)"
    echo "  查看: ${JENKINS_URL}/job/chaos-il2cpp-nightly/"
else
    warn "触发构建失败 (HTTP $HTTP_CODE)"
    warn "  可能是凭证错误。手动触发:"
    warn "  curl -X POST '${JENKINS_URL}/job/chaos-il2cpp-nightly/buildWithParameters' --user qa004:<password>"
fi

# ════════════════════════════════════════════════════════════════
# 输出汇总
# ════════════════════════════════════════════════════════════════
echo ""
echo "=============================================="
echo "  Linux 侧部署完成!"
echo "=============================================="
echo ""
echo "  Windows agent: ${SSH_USER}@${WIN_HOST}"
echo ""
echo "  ── 日常管理命令 (在 Linux 上执行) ──"
echo ""
echo "  SSH 进 Windows:"
echo "    ssh ${SSH_USER}@${WIN_HOST}"
echo ""
echo "  同步引擎源码:"
echo "    bash ${SCRIPT_DIR}/sync-to-windows.sh ${WIN_HOST}"
echo ""
echo "  触发 nightly 构建:"
echo "    bash ${SCRIPT_DIR}/trigger-windows-build.sh"
echo ""
echo "  查看 Windows agent 日志:"
echo "    ssh ${SSH_USER}@${WIN_HOST} \"type C:\\agent\\agent-service.log\""
echo ""
echo "  重启 agent 服务:"
echo "    ssh ${SSH_USER}@${WIN_HOST} \"& 'C:\\agent\\nssm\\nssm.exe' restart JenkinsAgent-windows-x64\""
echo ""
echo "  拉取 Windows 构建产物:"
echo "    rsync -av -e ssh ${SSH_USER}@${WIN_HOST}:'D:/agent/workspace/artifacts/' /tmp/win-artifacts/"
echo ""