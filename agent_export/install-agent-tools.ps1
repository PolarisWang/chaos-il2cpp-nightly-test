# chaos-il2cpp Windows Nightly Agent — 依赖一键安装脚本
# 用途: 安装 Python / CMake / Git / .NET SDK, 并给出 VS Build Tools 与 JDK 指引
# 运行: 管理员 PowerShell  ->  powershell -ExecutionPolicy Bypass -File install-agent-tools.ps1
# 注意: VS Build Tools (C++) 与 JDK 17 体积较大, 脚本检测到缺失时会输出手动指引.

$ErrorActionPreference = 'Continue'

function Write-Step($msg) { Write-Host "`n[STEP] $msg" -ForegroundColor Cyan }
function Write-Ok($msg)    { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Fail($msg)  { Write-Host "  [FAIL] $msg" -ForegroundColor Red }

# ── 1. 前置: winget 可用? ────────────────────────────────────────────
Write-Step "检查 winget..."
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Fail "未检测到 winget。请先安装 App Installer (Microsoft Store) 或改用手动安装。"
    Write-Host "继续尝试检测已有软件，但不会自动安装新项。"
    $winget = $null
} else {
    Write-Ok "winget 可用"
    $winget = 'winget'
}

# ── 2. Python 3 ───────────────────────────────────────────────────────
Write-Step "Python 3"
if (Get-Command python -ErrorAction SilentlyContinue) {
    $pver = (python --version 2>&1)
    if ($pver -match 'Python 3\.(1[0-9]|9|8)') { Write-Ok "Python 已装: $pver" }
    else { Write-Fail "Python 版本过低: $pver (需 3.10+)，将尝试更新" }
} elseif ($winget) {
    winget install --id Python.Python.3.13 --accept-package-agreements --accept-source-agreements --silent
    Write-Ok "已安装 Python 3.13"
}

# ── 3. CMake ──────────────────────────────────────────────────────────
Write-Step "CMake"
if (Get-Command cmake -ErrorAction SilentlyContinue) {
    Write-Ok "CMake 已装: $((cmake --version) -split "`n")[0]"
} elseif ($winget) {
    winget install --id Kitware.CMake --accept-package-agreements --accept-source-agreements --silent
    Write-Ok "已安装 CMake"
}

# ── 4. Git ────────────────────────────────────────────────────────────
Write-Step "Git"
if (Get-Command git -ErrorAction SilentlyContinue) {
    Write-Ok "Git 已装: $(git --version)"
} elseif ($winget) {
    winget install --id Git.Git --accept-package-agreements --accept-source-agreements --silent
    Write-Ok "已安装 Git"
}

# ── 5. .NET SDK 10.0 (winget 若无则给官网链接) ─────────────────────────
Write-Step ".NET SDK 10.0 + Runtime 8.0"
$sdks = @()
if (Get-Command dotnet -ErrorAction SilentlyContinue) { $sdks = (dotnet --list-sdks 2>&1) }
if ($sdks -match '10\.0') { Write-Ok "dotnet SDK 10 已装" }
else {
    Write-Host "  尝试通过 winget 安装 SDK 10..."
    try {
        winget install --id Microsoft.DotNet.SDK.10 --accept-package-agreements --accept-source-agreements --silent -e
        $script:dotnetJustInstalled = $true
    } catch { $script:dotnetJustInstalled = $false }
    if (-not $script:dotnetJustInstalled) {
        Write-Fail "winget 未装成 SDK 10（可能 winget 源无此 id）。"
        Write-Host "  手动安装 SDK 10.0:  https://dotnet.microsoft.com/en-us/download/dotnet/10.0"
    }
}
# Runtime 8.0 (TPG net8.0 target 需要)
if (-not ($sdks -match '8\.0')) {
    Write-Host "  尝试安装 .NET 8.0 Runtime..."
    try {
        winget install --id Microsoft.DotNet.Runtime.8 --accept-package-agreements --accept-source-agreements --silent -e
    } catch { Write-Fail "Runtime 8 未装成，改用手动: https://dotnet.microsoft.com/en-us/download/dotnet/8.0" }
} else { Write-Ok "dotnet SDK 8 已装 (含 runtime)" }

# ── 6. JDK 17 (提示) ──────────────────────────────────────────────────
Write-Step "JDK 17"
if (Get-Command java -ErrorAction SilentlyContinue) {
    Write-Ok "Java 已装: $((java -version 2>&1)[0])"
} elseif ($winget) {
    winget install --id EclipseAdoptium.Temurin.17.JRE --accept-package-agreements --accept-source-agreements --silent
    Write-Ok "已安装 Temurin JRE 17"
}

# ── 7. VS Build Tools C++ (提示, 体积大不自动装) ───────────────────────
Write-Step "Visual Studio Build Tools 2022 (C++)"
$vswhere = "C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe"
$hasCpp = $false
if (Test-Path $vswhere) {
    $compiler = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
    if ($compiler) { $hasCpp = $true; Write-Ok "检测到 C++ 工具链: $compiler" }
}
if (-not $hasCpp) {
    Write-Fail "未检测到 MSVC C++ 编译器。这是构建 entry.exe 的必需项！"
    Write-Host ""
    Write-Host "  请手动安装 VS Build Tools 2022，勾选工作负载:"
    Write-Host "    https://aka.ms/vs/17/release/vs_BuildTools.exe"
    Write-Host "    勾选「使用 C++ 的桌面开发」(Desktop development with C++)"
    Write-Host "    完成后验证: vcvars64.bat && cl"
}

# ── 8. OpenSSH Server (Linux 远程管理的关键) ───────────────────────
Write-Step "OpenSSH Server"
$ssh = Get-WindowsCapability -Online -Name OpenSSH.Server 2>$null
if ($ssh -and $ssh.State -eq 'Installed') {
    if ((Get-Service sshd -ErrorAction SilentlyContinue).Status -eq 'Running') {
        Write-Ok "OpenSSH Server 已运行"
    } else {
        Start-Service sshd; Set-Service sshd -StartupType Automatic
        Write-Ok "OpenSSH Server 已启动并设为自动"
    }
} else {
    Add-WindowsCapability -Online -Name OpenSSH.Server 2>$null
    if (-not (Test-Path 'C:\Program Files\OpenSSH\sshd.exe')) {
        Write-Fail "OpenSSH server 安装失败。请手动: Add-WindowsCapability -Online -Name OpenSSH.Server"
    } else {
        Start-Service sshd; Set-Service sshd -StartupType Automatic
        Write-Ok "已安装并启动 OpenSSH Server"
    }
}

Write-Step "完成"
Write-Host ""
Write-Host "  下一步: 运行 enable-remoting.ps1 创建 agent 用户 + 目录结构。" -ForegroundColor Yellow
