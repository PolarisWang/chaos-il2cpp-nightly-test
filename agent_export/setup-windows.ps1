# chaos-il2cpp Windows Nightly Agent — 一键部署脚本 (全自动)
# 用途: 由 RUN_ME_FIRST.cmd 自动调用, 完成所有 Windows 侧配置
# 运行: 不必手动执行, 双击 RUN_ME_FIRST.cmd 即可
# 注意: 部分安装步骤 (VS Build Tools, JDK) 需联网下载, 约 10-30 分钟

param(
    [string]$AgentUser = 'agent',
    [string]$AgentRoot = 'D:\agent',
    [string]$JenkinsUrl = 'http://10.10.1.173:8080',
    [string]$JenkinsNodeName = 'windows-x64'
)

$ErrorActionPreference = 'Continue'
$script:allOk = $true

# ════════════════════════════════════════════════════════════════════
# 辅助函数
# ════════════════════════════════════════════════════════════════════
function Write-Step ($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Write-Ok ($m)  { Write-Host "  [OK] $m" -ForegroundColor Green }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:allOk = $false }
function Test-Command($exe) { [bool](Get-Command $exe -ErrorAction SilentlyContinue) }

# ════════════════════════════════════════════════════════════════════
# 0. 前置: 管理员权限检查
# ════════════════════════════════════════════════════════════════════
Write-Step "检查管理员权限"
if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')) {
    Write-Fail "请以管理员身份运行! (右键 RUN_ME_FIRST.cmd → 以管理员身份运行)"
    exit 1
}
Write-Ok "管理员权限确认"

# ════════════════════════════════════════════════════════════════════
# 1. 提示输入 agent 用户密码
# ════════════════════════════════════════════════════════════════════
Write-Step "获取 agent 用户密码"
$AgentPwd = $null
while (-not $AgentPwd -or $AgentPwd.Length -lt 8) {
    $secure = Read-Host -AsSecureString "请输入 agent 用户密码 (≥8 位, 用于 Linux ssh 远程管理)"
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
    $confirm = Read-Host -AsSecureString "确认密码"
    $confirmPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($confirm))
    if ($plain -eq $confirmPlain) { $AgentPwd = $plain }
    else { Write-Host "  [WARN] 密码不匹配, 请重试" -ForegroundColor Yellow }
}
Write-Ok "密码已设置"

# ════════════════════════════════════════════════════════════════════
# 2. 安装 winget (如果缺失)
# ════════════════════════════════════════════════════════════════════
Write-Step "检查 winget"
if (-not (Test-Command winget)) {
    Write-Host "  [INFO] winget 不可用, 尝试从商店安装 App Installer..."
    try {
        Add-AppxPackage -Path (Invoke-WebRequest -Uri 'https://aka.ms/getwinget' -UseBasicParsing).Content -ErrorAction SilentlyContinue
    } catch { $null }
    if (-not (Test-Command winget)) {
        Write-Host "  [WARN] winget 仍不可用, 将改用 choco/手动安装。"
    }
} else { Write-Ok "winget 可用" }

# ════════════════════════════════════════════════════════════════════
# 3. 安装前置工具 (均有 Try-Catch 防崩溃)
# ════════════════════════════════════════════════════════════════════
Write-Step "安装 Python 3.13"
if (-not (Test-Command python)) {
    Write-Host "  [INFO] 安装 Python 3.13..."
    if (Test-Command winget) {
        winget install --id Python.Python.3.13 --accept-package-agreements --accept-source-agreements --silent 2>$null
        refreshenv 2>$null
    }
    if (-not (Test-Command python)) {
        Write-Host "  [WARN] 自动安装 Python 失败, 请手动装: https://www.python.org/downloads/"
        Write-Fail "Python 缺失"
    } else { Write-Ok "Python 已安装" }
} else { Write-Ok "Python 已存在" }

Write-Step "安装 CMake"
if (-not (Test-Command cmake)) {
    if (Test-Command winget) {
        winget install --id Kitware.CMake --accept-package-agreements --accept-source-agreements --silent 2>$null
        refreshenv 2>$null
    }
    if (-not (Test-Command cmake)) {
        Write-Host "  [WARN] CMake 自动安装失败, 请手动装: https://cmake.org/download/"
        Write-Fail "CMake 缺失"
    } else { Write-Ok "CMake 已安装" }
} else { Write-Ok "CMake 已存在" }

Write-Step "安装 Git"
if (-not (Test-Command git)) {
    if (Test-Command winget) {
        winget install --id Git.Git --accept-package-agreements --accept-source-agreements --silent 2>$null
        refreshenv 2>$null
    }
    if (-not (Test-Command git)) {
        Write-Host "  [WARN] Git 自动安装失败, 请手动装: https://git-scm.com/download/win"
        Write-Fail "Git 缺失"
    } else { Write-Ok "Git 已安装" }
} else { Write-Ok "Git 已存在" }

Write-Step "安装 Java (JDK 17)"
if (-not (Test-Command java)) {
    if (Test-Command winget) {
        winget install --id EclipseAdoptium.Temurin.17.JRE --accept-package-agreements --accept-source-agreements --silent 2>$null
        $env:Path = "$env:Path;C:\Program Files\Eclipse Adoptium\jdk-17.0.12.7-hotspot\bin"
        [Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path','Machine') + ";C:\Program Files\Eclipse Adoptium\jdk-17.0.12.7-hotspot\bin", 'Machine')
    }
    refreshenv 2>$null
    if (-not (Test-Command java)) {
        Write-Host "  [WARN] JDK 17 自动安装失败, 请手动装: https://adoptium.net/temurin/releases/?version=17"
        Write-Fail "JDK 缺失"
    } else { Write-Ok "JDK 已安装" }
} else { Write-Ok "JDK 已存在" }

Write-Step "安装 .NET SDK 10.0 + Runtime 8.0"
$dotnetOk = $false
try {
    $sdks = if (Test-Command dotnet) { dotnet --list-sdks 2>&1 } else { @() }
    if ($sdks -match '10\.0' -and $sdks -match '8\.0') {
        Write-Ok ".NET SDK 10 + 8 已存在"
        $dotnetOk = $true
    } else {
        Write-Host "  [INFO] 安装 .NET SDK 10.0..."
        Invoke-WebRequest -Uri 'https://dot.net/v1/dotnet-install.ps1' -OutFile "$env:TEMP\dotnet-install.ps1" 2>$null
        & "$env:TEMP\dotnet-install.ps1" -Channel 10.0 -InstallDir "$env:ProgramFiles\dotnet" 2>&1 | Out-Null
        & "$env:TEMP\dotnet-install.ps1" -Channel 8.0 -Runtime dotnet -InstallDir "$env:ProgramFiles\dotnet" 2>&1 | Out-Null
        $env:Path = "$env:Path;$env:ProgramFiles\dotnet"
        [Environment]::SetEnvironmentVariable('Path', "$env:Path;$env:ProgramFiles\dotnet", 'Machine')
        if (Test-Command dotnet) { $dotnetOk = $true; Write-Ok ".NET 已安装" }
        else { Write-Fail ".NET 安装失败, 请手动: https://dotnet.microsoft.com/en-us/download/dotnet/10.0" }
    }
} catch { Write-Fail ".NET 安装异常: $_" }

Write-Step "安装 VS Build Tools (C++ 工具链)"
$vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
$hasCpp = $false
if (Test-Path $vswhere) {
    $path = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
    if ($path) { $hasCpp = $true; Write-Ok "MSVC C++ 工具链已安装" }
}
if (-not $hasCpp) {
    Write-Host "  [INFO] 下载 VS Build Tools 安装程序..."
    $vsSetup = "$env:TEMP\vs_BuildTools.exe"
    try {
        Invoke-WebRequest -Uri 'https://aka.ms/vs/17/release/vs_BuildTools.exe' -OutFile $vsSetup -UseBasicParsing 2>$null
        Write-Host "  [INFO] 静默安装 VS Build Tools (C++ 桌面包)... 约 5-10 分钟, 请耐心等待"
        $proc = Start-Process -FilePath $vsSetup -ArgumentList '--quiet --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended' -NoNewWindow -PassThru -Wait
        if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) {
            Write-Ok "VS Build Tools 安装完成 (exit=$($proc.ExitCode), 3010=需重启)"
        } else {
            Write-Fail "VS Build Tools 安装失败 (exit=$($proc.ExitCode))"
            Write-Host "  [INFO] 可手动安装: https://aka.ms/vs/17/release/vs_BuildTools.exe"
            Write-Host "         勾选「使用 C++ 的桌面开发」"
        }
    } catch {
        Write-Fail "VS Build Tools 下载/安装异常: $_"
    }
}

# ════════════════════════════════════════════════════════════════════
# 4. 启用 OpenSSH Server + 创建 agent 用户 + 防火墙
# ════════════════════════════════════════════════════════════════════
Write-Step "启用 OpenSSH Server"
try {
    $ssh = Get-WindowsCapability -Online -Name OpenSSH.Server 2>$null
    if ($ssh -and $ssh.State -ne 'Installed') {
        Add-WindowsCapability -Online -Name OpenSSH.Server 2>$null | Out-Null
    }
    if (Test-Path 'C:\Program Files\OpenSSH\sshd.exe') {
        Start-Service sshd -ErrorAction SilentlyContinue
        Set-Service -Name sshd -StartupType Automatic
        if (-not (Get-NetFirewallRule -DisplayGroup 'OpenSSH Server' -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -Name 'OpenSSH-Server' -DisplayName 'OpenSSH Server (sshd)' -Enabled True `
                -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
        }
        Write-Ok "OpenSSH Server 已启动, 22 端口已放行"
    } else {
        Write-Fail "OpenSSH Server 安装失败"
    }
} catch { Write-Fail "OpenSSH 配置异常: $_" }

Write-Step "创建 agent 用户"
try {
    if (-not (Get-LocalUser -Name $AgentUser -ErrorAction SilentlyContinue)) {
        $secPw = ConvertTo-SecureString $AgentPwd -AsPlainText -Force
        New-LocalUser -Name $AgentUser -Password $secPw -FullName 'Jenkins agent' -PasswordNeverExpires `
            -Description 'chaos-il2cpp nightly build agent' | Out-Null
        Add-LocalGroupMember -Group 'Administrators' -Member $AgentUser 2>$null
        Write-Ok "已创建用户 $AgentUser (管理员)"
    } else {
        Write-Ok "用户 $AgentUser 已存在, 跳过"
    }
} catch { Write-Fail "创建用户失败: $_" }

Write-Step "配置 git core.autocrlf=false"
try {
    & git config --global core.autocrlf false 2>$null
    Write-Ok "git autocrlf=false 已配置"
} catch { Write-Fail "git 配置失败" }

# ════════════════════════════════════════════════════════════════════
# 5. 建目录结构
# ════════════════════════════════════════════════════════════════════
Write-Step "建目录结构 $AgentRoot"
$dirs = @('', 'workspace', 'booming-il2cpp', 'logs', 'nssm')
foreach ($d in $dirs) {
    New-Item -ItemType Directory -Path (Join-Path $AgentRoot $d) -Force | Out-Null
}
Write-Ok "$AgentRoot\{,workspace,booming-il2cpp,logs,nssm} 已建"

# ════════════════════════════════════════════════════════════════════
# 6. 下载 Jenkins agent.jar + NSSM + 注册服务
# ════════════════════════════════════════════════════════════════════
Write-Step "下载 Jenkins agent.jar"
try {
    Invoke-WebRequest -Uri "$JenkinsUrl/jnlpJars/agent.jar" -OutFile "$AgentRoot\agent.jar" -UseBasicParsing 2>$null
    if (Test-Path "$AgentRoot\agent.jar") { Write-Ok "agent.jar 已下载" } else { Write-Fail "agent.jar 下载失败" }
} catch { Write-Fail "agent.jar 下载异常: $_" }

Write-Step "下载 NSSM"
$nssmExe = "$AgentRoot\nssm\nssm.exe"
if (-not (Test-Path $nssmExe)) {
    try {
        $nssmZip = "$env:TEMP\nssm.zip"
        Invoke-WebRequest -Uri 'https://nssm.cc/release/nssm-2.24-101-g897c7ad.zip' -OutFile $nssmZip -UseBasicParsing 2>$null
        Expand-Archive -Path $nssmZip -DestinationPath $env:TEMP -Force 2>$null
        Copy-Item "$env:TEMP\nssm-2.24-101-g897c7ad\win64\nssm.exe" $nssmExe -Force
        Remove-Item $nssmZip -Force -ErrorAction SilentlyContinue
        Remove-Item "$env:TEMP\nssm-2.24-101-g897c7ad" -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path $nssmExe) { Write-Ok "NSSM 已下载" } else { Write-Fail "NSSM 下载失败" }
    } catch { Write-Fail "NSSM 异常: $_" }
} else { Write-Ok "NSSM 已存在" }

Write-Step "注册 Jenkins agent 服务"
$serviceName = "JenkinsAgent-$JenkinsNodeName"
try {
    $javaExe = (Get-Command java -ErrorAction SilentlyContinue).Source
    if (-not $javaExe) { $javaExe = "java.exe" }
    $agentArgs = "-jar `"$AgentRoot\agent.jar`" -url $JenkinsUrl -secret **** -name $JenkinsNodeName -workDir `"$AgentRoot\workspace`""
    & $nssmExe stop $serviceName 2>$null; & $nssmExe remove $serviceName confirm 2>$null
    & $nssmExe install $serviceName $javaExe
    & $nssmExe set $serviceName AppParameters "-jar `"$AgentRoot\agent.jar`" -url $JenkinsUrl -secret NEEDS_UPDATE -name $JenkinsNodeName -workDir `"$AgentRoot\workspace`""
    & $nssmExe set $serviceName AppDirectory $AgentRoot
    & $nssmExe set $serviceName AppStdout "$AgentRoot\agent-service.log"
    & $nssmExe set $serviceName AppStderr "$AgentRoot\agent-service.err.log"
    & $nssmExe set $serviceName AppRestartDelay 5000
    & $nssmExe set $serviceName Start SERVICE_AUTO_START
    & $nssmExe set $serviceName ObjectName LocalSystem
    Write-Host "  [INFO] 服务已注册, 但请在 Jenkins 建好节点后, 用以下命令更新 secret 并启动:"
    Write-Host "         & `"$nssmExe`" set $serviceName AppParameters `"-jar $AgentRoot\agent.jar ... -secret <实际secret> ...`""
    Write-Host "         & `"$nssmExe`" start $serviceName"
    Write-Ok "Jenkins agent 服务已注册 (服务名: $serviceName)"
} catch { Write-Fail "NSSM 注册服务失败: $_" }

# ════════════════════════════════════════════════════════════════════
# 7. 输出结果
# ════════════════════════════════════════════════════════════════════
Write-Step "部署完成"

$myIp = (Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias 'Ethernet*' -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notmatch '^169\.254|^127\.' } | Select-Object -First 1).IPAddress
if (-not $myIp) { $myIp = '<请填本机IP>' }

Write-Host "==============================================" -ForegroundColor Green
Write-Host "  Windows Agent 部署完成" -ForegroundColor Green
Write-Host "==============================================" -ForegroundColor Green
Write-Host ""
Write-Host "  本机 IP:   $myIp"
Write-Host "  用户:      $AgentUser"
Write-Host "  密码:      (你刚才设置的)"
Write-Host "  目录:      $AgentRoot"
Write-Host ""
Write-Host "  Jenkins 节点: $JenkinsNodeName"
Write-Host "  Jenkins URL:  $JenkinsUrl"
Write-Host ""
Write-Host "  ├─ 下一步: 在 Jenkins 创建节点 $JenkinsNodeName"
Write-Host "  │    (JNLP 方式, 标签 windows-x64, 根目录 D:\agent\workspace)"
Write-Host "  │    记下 secret, 然后:"
Write-Host "  │"
Write-Host "  │  & `"$nssmExe`" set $serviceName AppParameters ^"
Write-Host '     "-jar D:\agent\agent.jar -url http://10.10.1.173:8080 ^'
Write-Host '       -secret <SECRET> -name windows-x64 ^'
Write-Host '       -workDir D:\agent\workspace"'
Write-Host "  │  & `"$nssmExe`" start $serviceName"
Write-Host "  │"
Write-Host "  ├─ 从 Linux 远程管理:"
Write-Host "  │    ssh $AgentUser@$myIp"
Write-Host "  │"
Write-Host "  └─ 通知管理员: 本机已就绪, IP = $myIp"
Write-Host ""

if ($script:allOk) {
    Write-Host "  ✅ 所有步骤成功。请按上述指引完成 Jenkins 节点配置。" -ForegroundColor Green
} else {
    Write-Host "  ⚠️ 部分步骤失败, 请根据上方 [FAIL] 信息手动修复。" -ForegroundColor Yellow
}
Write-Host ""

Read-Host "按 Enter 退出"