# chaos-il2cpp Windows Nightly Agent — 启用远程管理 (在 Windows 上一次性执行)
# 用途: 开启 OpenSSH Server, 创建 agent 用户, 建 C:\agent 目录结构, 配置 git autocrlf
# 运行: 管理员 PowerShell:
#   powershell -ExecutionPolicy Bypass -File enable-remoting.ps1
# 说明: 这是"从 Linux 无头管理 Windows"的关键一步。跑完本机后, 日常只需 ssh agent@<ip>。

param(
    [string]$AgentUser = 'agent',
    [string]$AgentPwd  = '<请改为强密码>',   # : 修改为你的强密码后再运行!
    [string]$AgentRoot = 'C:\agent'
)

$ErrorActionPreference = 'Stop'

function Step($m){ Write-Host "`n[STEP] $m" -ForegroundColor Cyan }
function Ok($m){ Write-Host "  [OK] $m" -ForegroundColor Green }
function Fail($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red }

# ── 1. 安装/启用 OpenSSH Server (Windows 可选功能) ─────────────────
Step "安装/启用 OpenSSH Server"
$sshService = Get-WindowsCapability -Online -Name OpenSSH.Server 2>$null
if ($sshService -and $sshService.State -ne 'Installed') {
    Add-WindowsCapability -Online -Name OpenSSH.Server 2>$null | Out-Null
}
if (-not (Test-Path 'C:\Program Files\OpenSSH\sshd.exe')) {
    Fail "OpenSSH server 未安装。请: Add-WindowsCapability -Online -Name OpenSSH.Server 或参照微软文档手动装。"
} else {
    # 确保服务启动 + 开机自启 + 防火墙放行
    Start-Service sshd
    Set-Service -Name sshd -StartupType Automatic
    if (-not (Get-NetFirewallRule -DisplayGroup 'OpenSSH Server' -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name 'OpenSSH-Server' -DisplayName 'OpenSSH Server (sshd)' -Enabled True `
            -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
    }
    Ok "OpenSSH Server 已启动并放行 22 端口"
}

# ── 2. 创建 agent 用户 ──────────────────────────────────────────────
Step "创建/准备用户 $AgentUser"
if (Get-LocalUser -Name $AgentUser -ErrorAction SilentlyContinue) {
    Write-Host "  用户 $AgentUser 已存在, 跳过创建 (如需改密码: net user $AgentUser 新密码)"
} else {
    if ($AgentPwd -eq '<请改为强密码>') {
        Fail "请先修改脚本顶部 #AgentPwd 的默认密码再运行!"
        exit 1
    }
    $secPw = ConvertTo-SecureString $AgentPwd -AsPlainText -Force
    New-LocalUser -Name $AgentUser -Password $secPw -FullName 'Jenkins agent' -Description 'chaos-il2cpp build agent' | Out-Null
    Add-LocalGroupMember -Group 'Administrators' -Member $AgentUser   # agent 需要管理员跑 VS 工具链
    Ok "已创建用户 $AgentUser (管理员)"
}

# ── 3. 建目录结构 ───────────────────────────────────────────────────
Step "建目录结构 $AgentRoot"
foreach ($d in @('', 'workspace', 'booming-il2cpp', 'logs')) {
    New-Item -ItemType Directory -Path (Join-Path $AgentRoot $d) -Force | Out-Null
}
Ok "C:\agent\{,workspace,booming-il2cpp,logs} 已建"

# ── 4. 配置 agent 用户的 git autocrlf=false ─────────────────────────
Step "配置 git core.autocrlf=false (引擎源码同步前提)"
try {
    & git config --system core.autocrlf false 2>$null
    Ok "已写 system git config core.autocrlf=false"
} catch {
    Fail "git 未找到或配置失败, 请确认已装 Git for Windows"
}

# ── 5. 提示 ──────────────────────────────────────────────────────────
Step "说明"
Write-Host "  SSH 默认 shell 为 cmd (够用)。如需 PowerShell 可用 ssh 内敲 pwsh 切换。"

Write-Host ""
Write-Host "============================================="
Write-Host "  远程管理已就绪"
Write-Host "  从 Linux 连接:   ssh $AgentUser@<本机IP>"
Write-Host "  目录:            $AgentRoot"
Write-Host "============================================="
Write-Host ""
Write-Host "  · 引擎源码将由 Linux 侧同步到 $AgentRoot\booming-il2cpp"
Write-Host "    (Linux 上跑: bash sync-to-windows.sh <host>)"
Write-Host "  · 别忘了在 Jenkins 建节点 windows-x64, 并用 install-agent-service.ps1 启动 agent。"
