#!/bin/bash
# ==============================================================
# 从 Linux 远程触发 Jenkins nightly 构建 (带 Windows 阶段)
#
# 用法:
#   bash trigger-windows-build.sh [<jenkins-host>]
#   # 可选覆盖环境变量:
#   #   JENKINS_URL   http://10.10.1.173:8080
#   #   JENKINS_USER  qa004
#   #   JENKINS_PASS  <密码>     (或用 JENKINS_TOKEN 用 API token)
#   #   BOOMING_REPO  传参默认 C:\agent\booming-il2cpp
# ==============================================================

set -euo pipefail

JENKINS_URL="${JENKINS_URL:-http://10.10.1.173:8080}"
JENKINS_USER="${JENKINS_USER:-qa004}"
JENKINS_PASS="${JENKINS_PASS:-}"
JENKINS_TOKEN="${JENKINS_TOKEN:-}"
BOOMING_REPO="${BOOMING_REPO:-C:/agent/booming-il2cpp}"
BUILD_CONFIG="${BUILD_CONFIG:-profile}"
JOB="${JOB:-chaos-il2cpp-nightly}"

if [[ -z "$JENKINS_PASS" && -z "$JENKINS_TOKEN" ]]; then
    echo "错误: 需要凭证。设 JENKINS_PASS 或 JENKINS_TOKEN。" >&2
    echo "  例: JENKINS_PASS='...' bash trigger-windows-build.sh" >&2
    exit 1
fi

AUTH="${JENKINS_USER}:${JENKINS_PASS:-$JENKINS_TOKEN}"

echo "=== 触发 Jenkins build ==="
echo "  Job     : $JOB"
echo "  URL     : $JENKINS_URL"
echo "  BOOMING : $BOOMING_REPO"
echo "  CONFIG  : $BUILD_CONFIG"

# 触发 (buildWithParameters 允许传参). 返回 201 = 已触发; 200 = 已在队列.
http_code=$(
    curl -s -o /dev/null -w "%{http_code}" -u "$AUTH" \
        -X POST "${JENKINS_URL}/job/${JOB}/buildWithParameters" \
        --data-urlencode "BOOMING_REPO=$BOOMING_REPO" \
        --data-urlencode "BUILD_CONFIG=$BUILD_CONFIG"
)

if [[ "$http_code" == "201" || "$http_code" == "200" ]]; then
    echo "✓ 已触发 (HTTP $http_code). 查看: ${JENKINS_URL}/job/${JOB}/"
else
    echo "✗ 触发失败 (HTTP $http_code). 检查凭证与 job 名。" >&2
    exit 1
fi
