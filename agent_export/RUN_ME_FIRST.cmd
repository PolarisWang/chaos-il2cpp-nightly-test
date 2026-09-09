@echo off
REM ================================================================
REM  chaos-il2cpp Windows Nightly Agent — 一键部署入口
REM  用途: 双击运行本文件, 自动以管理员权限安装全套工具链
REM        + 启用 OpenSSH Server + 启动 Jenkins agent 服务
REM
REM  操作步骤:
REM    1. 右键 → "以管理员身份运行" (或用普通双击, 会弹 UAC 提权)
REM    2. 按提示输入 agent 用户密码 (用于后续 Linux 远程 SSH 管理)
REM    3. 等待约 10-30 分钟 (取决于网络下载速度)
REM    4. 看到 "=== 部署完成 ===" 即表示成功
REM    5. 把此目录复制到 \\booming.com\dev\home\haochuan.wang\agent_export\
REM       (或通知管理员: "Windows agent 已就绪, IP = <本机IP>")
REM ================================================================

title chaos-il2cpp Windows Agent 一键部署
cd /d "%~dp0"

REM 自动提权到管理员 (如果当前不是)
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo [INFO] 请求管理员权限...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

echo ========================================
echo  chaos-il2cpp Windows Agent 一键部署
echo ========================================
echo.
echo [STEP] 正在启动 PowerShell 安装脚本...
echo.

powershell -ExecutionPolicy Bypass -File "%~dp0setup-windows.ps1"
if %errorLevel% equ 0 (
    echo.
    echo ========================================
    echo  部署完成!
    echo ========================================
    echo.
    echo    Windows Agent IP: <本机IP>
    echo    用户: agent
    echo    密码: 你刚才输入的密码
    echo.
    echo    下一步: 通知管理员或把此目录复制到
    echo    \\booming.com\dev\home\haochuan.wang\agent_export\
    echo.
    echo    从 Linux 管理: ssh agent@<本机IP>
    echo.
    pause
) else (
    echo.
    echo [ERROR] 部署失败, 请查看上方错误信息。
    echo         可在 PowerShell(管理员) 中手动执行:
    echo   powershell -ExecutionPolicy Bypass -File setup-windows.ps1
    echo.
    pause
)