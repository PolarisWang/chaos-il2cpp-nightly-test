#!/bin/bash
# ==============================================================
# 同步引擎源码到 Windows agent (从 Linux 执行)
#
# 模型说明:
#   Windows 只"干活"(跑构建)。所有控制/调试/修改都在 Linux 侧完成。
#   引擎源码的"单一事实源"= Linux 服务器 (/home/debian/agent/booming-il2cpp)。
#   本脚本把 Linux 侧新代码推送/同步到 Windows agent。
#
# 用法:
#   bash sync-to-windows.sh [<windows-host>]
#
# 参数(可选覆盖):
#   WIN_HOST   Windows agent 的 IP / 主机
#   WIN_USER   SSH 用户名 (默认 agent; 由镜像内 provision 脚本创建)
#   WIN_PATH   Windows 上的引擎源码路径 (默认 D:\agent\workspace\booming-il2cpp)
# ==============================================================

set -euo pipefail

WIN_HOST="${1:-${WIN_HOST:-}}"
WIN_USER="${WIN_USER:-agent}"
WIN_PATH="${WIN_PATH:-D:/agent/workspace/booming-il2cpp}"
LOCAL_DIR="${LOCAL_DIR:-/home/debian/agent/booming-il2cpp}"

if [[ -z "$WIN_HOST" ]]; then
    echo "用法: bash sync-to-windows.sh <windows-host>"
    echo "  (或设环境变量 WIN_HOST)" >&2
    exit 1
fi

if [[ ! -d "$LOCAL_DIR/.git" ]]; then
    echo "错误: 本地引擎目录不存在: $LOCAL_DIR" >&2
    exit 1
fi

echo "=== 同步引擎源码 → Windows agent ==="
echo "  Linux : $LOCAL_DIR"
echo "  Windows: $WIN_USER@$WIN_HOST:$WIN_PATH"

# 1. 确保远端目录存在 (Windows 端用 cmd 建, 接受正斜杠)
ssh "${WIN_USER}@${WIN_HOST}" "cmd /c if not exist \"${WIN_PATH}\" mkdir \"${WIN_PATH}\""

# 2. rsync 同步 (需 Windows OpenSSH 支持; 若 rsync 不可用, 退化为 scp -r)
if ssh "${WIN_USER}@${WIN_HOST}" "where rsync" >/dev/null 2>&1; then
    rsync -az --delete -e ssh -O \
        --exclude='.git' \
        --exclude='**/_dll/**' \
        --exclude='**/artifacts/**' \
        --exclude='**/CMakeCache.txt' \
        --exclude='**/CMakeFiles/**' \
        "${LOCAL_DIR}/" "${WIN_USER}@${WIN_HOST}:${WIN_PATH}/"
else
    echo "[!] Windows 上未找到 rsync, 改用 scp (较慢, 且不删除远端多余文件)"
    scp -r "${LOCAL_DIR}/testing/foundation-dll" "${WIN_USER}@${WIN_HOST}:${WIN_PATH}/testing/"
fi

echo
echo "=== 完成: 源码已同步到 Windows agent ==="
echo "接下来可远程触发构建:  bash trigger-windows-build.sh $WIN_HOST"
