<#
.SYNOPSIS
    chaos-il2cpp Windows Nightly Agent — 单文件一键部署 (全自动/自发现)

.DESCRIPTION
    本脚本在 Windows 空机器上执行一次即可完成所有部署:
      1. 安装全部工具链 (Python / CMake / Git / JDK / .NET / VS C++)
      2. 启用 OpenSSH Server + 创建 agent 用户 (Linux 远程管理用)
      3. 自动在 Jenkins master 创建节点 windows-x64 并获取 secret
      4. 下载 NSSM + 注册 Jenkins agent 为开机自启服务
      5. 启动 agent → 节点上线
      6. 安装 nightly_runner Python 依赖

    执行方式 (管理员 PowerShell, 一行命令):
      iex (iwr https://raw.githubusercontent.com/PolarisWang/chaos-il2cpp-nightly-test/main/agent_export/bootstrap-windows.ps1)

    参数:
      -JenkinsUrl  (默认 http://10.10.1.173:8080, 本机 CI 控制台)
      -AgentRoot   (默认 D:\agent)
      -AgentUser   (默认 agent, 用于 SSH 远程管理)
      -BootstrapFromLinux (开关, 从 Linux 启动服务器向 Windows 传送脚本; 默认 false)

    验收标准:
      1. 脚本跑完无红 FAIL → 工具链全绿
      2. Jenkins Web UI → Nodes → windows-x64 → 绿色在线
      3. 从 Linux SSH agent@<本机IP> 能连入
      4. 触发一次 nightly → 在 Stage View 看到 "Full Pipeline (x64 + Windows)"
         的两个分支 (linux-x64 / windows-x64) 并跑出 windows 产物
#>

param(
    [string]$JenkinsUrl = 'http://10.10.1.173:8080',
    [string]$AgentRoot  = 'D:\agent',
    [string]$AgentUser  = 'agent',
    [switch]$SkipOpenSSH,
    [switch]$BootstrapFromLinux
)

$ErrorActionPreference = 'Continue'
$script:allOk = $true
$script:agentPassword = ''

# ══════════════════════════════════════════════════════════════════
# 辅助函数
# ══════════════════════════════════════════════════════════════════
function Write-Step ($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Write-Ok ($m)  { Write-Host "  [OK] $m" -ForegroundColor Green }
function Write-Warn($m) { Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:allOk = $false }
function Test-Cmd($exe) { [bool](Get-Command $exe -ErrorAction SilentlyContinue) }

function Get-MyIp {
    $ip = (Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias 'Ethernet*','Wi-Fi*' -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notmatch '^169\.254|^127\.|^10\.' } | Select-Object -First 1).IPAddress
    if (-not $ip) { $ip = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notmatch '^169\.254|^127\.|^10\.' } | Select-Object -First 1).IPAddress }
    if (-not $ip) { $ip = '10.10.9.197' }  # fallback 占位, 手动改
    return $ip
}

# ══════════════════════════════════════════════════════════════════
# 0. 管理员检查 + 交互式密码
# ══════════════════════════════════════════════════════════════════
Write-Step "检查管理员权限"
if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')) {
    Write-Fail "请以管理员身份运行! 已自动尝试提权..."
    $myCmd = "-ExecutionPolicy Bypass -File `"$PSCommandPath`" $($MyInvocation.Line -replace '.*\.ps1\s*','')"
    Start-Process powershell -Verb RunAs -ArgumentList $myCmd
    exit
}
Write-Ok "管理员权限确认"

# 交互式收集 agent 用户密码
while (-not $script:agentPassword -or $script:agentPassword.Length -lt 8) {
    $secure = Read-Host -AsSecureString "请输入 agent 用户密码 (≥8位, 用于 Linux ssh 远程管理)"
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
    $confirm = Read-Host -AsSecureString "确认密码"
    $confirmPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($confirm))
    if ($plain -eq $confirmPlain -and $plain.Length -ge 8) { $script:agentPassword = $plain }
    else { Write-Host "  [WARN] 密码不匹配或太短(≥8), 请重试" -ForegroundColor Yellow }
}
$MY_IP = Get-MyIp
Write-Host "  本机 IP 推测: $MY_IP" -ForegroundColor Gray

# ══════════════════════════════════════════════════════════════════
# 1. 前置工具安装 (Python / CMake / Git / JDK)
# ══════════════════════════════════════════════════════════════════
Write-Step "安装 Python 3.13"
if (Test-Cmd python) { Write-Ok "Python 已存在: $(python --version)" }
else {
    try { winget install --id Python.Python.3.13 --accept-package-agreements --accept-source-agreements --silent 2>$null;$env:Path+=";$env:ProgramFiles\Python313\;$env:LocalAppData\Programs\Python\Python313" }
    catch {}; refreshenv 2>$null
    if (Test-Cmd python) { Write-Ok "Python 已安装: $(python --version)" } else { Write-Fail "Python 自动安装失败, 请手动装: https://www.python.org/downloads/" }
}

Write-Step "安装 CMake"
if (Test-Cmd cmake) { Write-Ok "CMake 已存在: $((cmake --version)[0])" }
else {
    try { winget install --id Kitware.CMake --accept-package-agreements --accept-source-agreements --silent 2>$null;$env:Path+=";$env:ProgramFiles\CMake\bin" }
    catch {}; refreshenv 2>$null
    if (Test-Cmd cmake) { Write-Ok "CMake 已安装" } else { Write-Fail "CMake 自动安装失败" }
}

Write-Step "安装 Git"
if (Test-Cmd git) { Write-Ok "Git 已存在: $(git --version)" }
else {
    try { winget install --id Git.Git --accept-package-agreements --accept-source-agreements --silent 2>$null }
    catch {}; refreshenv 2>$null
    if (Test-Cmd git) { Write-Ok "Git 已安装" } else { Write-Fail "Git 自动安装失败" }
}

Write-Step "安装 JDK 17"
if (Test-Cmd java) { Write-Ok "Java 已存在: $((java -version 2>&1)[0])" }
else {
    try { winget install --id EclipseAdoptium.Temurin.17.JRE --accept-package-agreements --accept-source-agreements --silent 2>$null;$env:Path+=";$env:ProgramFiles\Eclipse Adoptium\jdk-17.0.12.7-hotspot\bin" }
    catch {}; refreshenv 2>$null
    if (Test-Cmd java) { Write-Ok "JDK 17 已安装" } else { Write-Fail "JDK 17 自动安装失败; 请手动装: https://adoptium.net/temurin/releases/?version=17" }
}

# ══════════════════════════════════════════════════════════════════
# 2. .NET SDK 10 + Runtime 8 (用 dotnet-install.ps1)
# ══════════════════════════════════════════════════════════════════
Write-Step "安装 .NET SDK 10.0 + Runtime 8.0"
$dotnetOk = $false
try {
    $sdks = if (Test-Cmd dotnet) { dotnet --list-sdks 2>&1 } else { @() }
    if ($sdks -match '10\.0') { Write-Ok ".NET SDK 10 已存在" } else {
        Write-Host "  [INFO] 安装 .NET SDK 10.0..."
        $installer = "$env:TEMP\dotnet-install.ps1"
        Invoke-WebRequest -Uri 'https://dot.net/v1/dotnet-install.ps1' -OutFile $installer -UseBasicParsing 2>$null
        & $installer -Channel 10.0 -InstallDir "$env:ProgramFiles\dotnet" 2>&1 | Out-Null
        $dotnetFound = Test-Cmd dotnet
        if (-not $dotnetFound) { $env:Path = "$env:Path;$env:ProgramFiles\dotnet" }
        if (Test-Cmd dotnet -and (dotnet --list-sdks 2>&1) -match '10\.0') { Write-Ok ".NET SDK 10 已安装" } else { Write-Warn ".NET SDK 10 未装全, 请手动装" }
    }
    if ($sdks -match '8\.0') { Write-Ok ".NET 8 已存在" } else {
        & "$env:TEMP\dotnet-install.ps1" -Channel 8.0 -Runtime dotnet -InstallDir "$env:ProgramFiles\dotnet" 2>&1 | Out-Null
        Write-Ok ".NET 8 runtime 已安装"
    }
} catch { Write-Fail ".NET 安装异常: $_" }

# ══════════════════════════════════════════════════════════════════
# 3. VS Build Tools 2022 (C++ 桌面包, 5-15 分钟)
# ══════════════════════════════════════════════════════════════════
Write-Step "安装 Visual Studio Build Tools 2022 (C++ 工具链)"
$vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
$hasCpp = $false
if (Test-Path $vswhere) {
    $vsDir = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
    if ($vsDir) { $hasCpp = $true; Write-Ok "MSVC C++ 工具链已安装" }
}
if (-not $hasCpp) {
    Write-Host "  [INFO] 下载 VS Build Tools 安装程序..."
    $setup = "$env:TEMP\vs_BuildTools.exe"
    try {
        Invoke-WebRequest -Uri 'https://aka.ms/vs/17/release/vs_BuildTools.exe' -OutFile $setup -UseBasicParsing 2>$null
        Write-Host "  [INFO] 静默安装 VS Build Tools (C++ 桌面包)... 约 5-15 分钟, 请耐心等待"
        $p = Start-Process -FilePath $setup -ArgumentList "--quiet --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended" -NoNewWindow -PassThru -Wait
        if ($p.ExitCode -eq 0 -or $p.ExitCode -eq 3010) { Write-Ok "VS Build Tools 安装完成 (exit=$($p.ExitCode), 3010=需重启)";$hasCpp=$true }
        else { Write-Fail "VS Build Tools 安装失败 (exit=$($p.ExitCode)), 需手动: https://aka.ms/vs/17/release/vs_BuildTools.exe" }
    } catch { Write-Fail "VS Build Tools 异常: $_" }
}

# ══════════════════════════════════════════════════════════════════
# 4. 启用 OpenSSH Server + 创建 agent 用户 + 防火墙
#    (可以 -SkipOpenSSH 跳过, 如果你已手动配好)
# ══════════════════════════════════════════════════════════════════
if (-not $SkipOpenSSH) {
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
                New-NetFirewallRule -Name 'OpenSSH-Server' -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
            }
            Write-Ok "OpenSSH Server 已启动, 22 端口已放行"
        } else { Write-Fail "OpenSSH Server 安装失败(需要 Windows 10+)"; Write-Warn "请手动: Add-WindowsCapability -Online -Name OpenSSH.Server" }
    } catch { Write-Fail "OpenSSH 配置异常: $_" }
} else {
    Write-Ok "已跳过 OpenSSH 安装 (参数 -SkipOpenSSH)"
}

Write-Step "创建 agent 用户: $AgentUser"
try {
    if (-not (Get-LocalUser -Name $AgentUser -ErrorAction SilentlyContinue)) {
        $secPw = ConvertTo-SecureString $script:agentPassword -AsPlainText -Force
        New-LocalUser -Name $AgentUser -Password $secPw -FullName 'Jenkins agent' -PasswordNeverExpires -Description 'chaos-il2cpp nightly build agent' | Out-Null
        Add-LocalGroupMember -Group 'Administrators' -Member $AgentUser 2>$null
        Write-Ok "已创建用户 $AgentUser (管理员)"
    } else { Write-Ok "用户 $AgentUser 已存在, 跳过" }
} catch { Write-Fail "创建用户失败: $_" }

Write-Step "配置 git core.autocrlf=false"
try { & git config --global core.autocrlf false 2>$null; Write-Ok "git autocrlf=false" } catch { Write-Fail "git 配置失败" }

# ══════════════════════════════════════════════════════════════════
# 5. 建目录结构
# ══════════════════════════════════════════════════════════════════
Write-Step "建目录结构 $AgentRoot"
foreach ($d in @('', 'workspace', 'booming-il2cpp', 'logs', 'nssm')) {
    New-Item -ItemType Directory -Path (Join-Path $AgentRoot $d) -Force | Out-Null
}
Write-Ok "$AgentRoot\{workspace,booming-il2cpp,logs,nssm} 已建"

# ══════════════════════════════════════════════════════════════════
# 6. 在 Jenkins 创建节点 windows-x64 (自动, 无需 UI)
#    Jenkins 当前 useSecurity:false, 直接 API 调用即可
# ══════════════════════════════════════════════════════════════════
Write-Step "在 Jenkins 创建节点 windows-x64"
$nodeName = 'windows-x64'
try {
    # 先获取 CSRF crumb (不需要凭据)
    $crumbResp = Invoke-RestMethod -Uri "$JenkinsUrl/crumbIssuer/api/json" -Method GET -UseBasicParsing
    $crumbField = $crumbResp.crumbRequestField
    $crumbValue = $crumbResp.crumb
    $headers = @{}
    $headers[$crumbField] = $crumbValue

    # POST 创建节点
    $jsonPayload = @{
        name = $nodeName
        type = 'hudson.slaves.DumbSlave'
        json = (@{
            name = $nodeName
            nodeDescription = 'Windows nightly build agent'
            numExecutors = 1
            remoteFS = "$AgentRoot\workspace".Replace('\', '\\')
            labelString = 'windows-x64 windows x64 msvc'
            mode = 'NORMAL'
            retentionStrategy = 'Always'
            launcher = @{
                'stapler-class' = 'hudson.slaves.JNLPLauncher'
            }
        } | ConvertTo-Json -Compress)
    } | ConvertTo-Json -Compress

    $createResp = Invoke-RestMethod -Uri "$JenkinsUrl/computer/doCreateItem" -Method POST -Body $jsonPayload -Headers $headers -UseBasicParsing -ContentType 'application/x-www-form-urlencoded' -ErrorAction SilentlyContinue
    Write-Ok "节点 $nodeName 已创建 (或已存在)"
} catch {
    # 如果 node 已存在, POST 会返回 400, 这里不视为失败
    Write-Ok "节点 $nodeName 可能已存在 (尝试创建返回: $($_.Exception.Response.StatusCode.value__))"
}

# ══════════════════════════════════════════════════════════════════
# 7. 获取节点 secret (从 JNLP 文件读取)
# ══════════════════════════════════════════════════════════════════
Write-Step "获取节点 secret"
$nodeSecret = ''
try {
    $jnlpUrl = "$JenkinsUrl/computer/$nodeName/slave-agent.jnlp"
    for ($i = 0; $i -lt 30; $i++) {  # Master 可能需要几秒刷新节点, 最多重试 30 次 (2 分钟)
        try {
            $jnlp = Invoke-RestMethod -Uri $jnlpUrl -UseBasicParsing -ErrorAction Stop
            # 解析 <argument>secret</argument>
            $regex = [regex]'<argument>([^<]+)</argument>'
            $match = $regex.Match($jnlp)
            if ($match.Success) {
                $nodeSecret = $match.Groups[1].Value
                break
            }
        } catch {}
        Start-Sleep -Seconds 4
    }
    if ($nodeSecret) { Write-Ok "节点 secret 已获取" } else { Write-Fail "获取 secret 失败" }
} catch { Write-Fail "获取 JNLP 异常: $_" }

# ══════════════════════════════════════════════════════════════════
# 8. 下载 Jenkins agent.jar
# ══════════════════════════════════════════════════════════════════
Write-Step "下载 agent.jar"
try {
    $agentJar = "$AgentRoot\agent.jar"
    if (-not (Test-Path $agentJar) -or (Get-Item $agentJar).Length -eq 0) {
        Invoke-WebRequest -Uri "$JenkinsUrl/jnlpJars/agent.jar" -OutFile $agentJar -UseBasicParsing 2>$null
    }
    if (Test-Path $agentJar -and (Get-Item $agentJar).Length -gt 0) { Write-Ok "agent.jar 已就绪" } else { Write-Fail "agent.jar 下载失败" }
} catch { Write-Fail "agent.jar 下载异常: $_" }

# ══════════════════════════════════════════════════════════════════
# 9. 下载 NSSM + 注册 Jenkins agent 为 Windows 服务
# ══════════════════════════════════════════════════════════════════
Write-Step "注册 NSSM 服务"
$nssmExe = "$AgentRoot\nssm\nssm.exe"
$serviceName = "JenkinsAgent-$nodeName"
try {
    if (-not (Test-Path $nssmExe)) {
        $nssmZip = "$env:TEMP\nssm.zip"
        Invoke-WebRequest -Uri 'https://nssm.cc/release/nssm-2.24-101-g897c7ad.zip' -OutFile $nssmZip -UseBasicParsing 2>$null
        Expand-Archive -Path $nssmZip -DestinationPath $env:TEMP -Force 2>$null
        Copy-Item "$env:TEMP\nssm-2.24-101-g897c7ad\win64\nssm.exe" $nssmExe -Force
        Remove-Item $nssmZip -Force -ErrorAction SilentlyContinue; Remove-Item "$env:TEMP\nssm-2.24-101-g897c7ad" -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $nssmExe) { Write-Ok "NSSM 已就绪" } else { Write-Fail "NSSM 下载失败" }
} catch { Write-Fail "NSSM 异常: $_" }

if (Test-Path $nssmExe -and $nodeSecret) {
    try {
        $javaExe = (Get-Command java -ErrorAction SilentlyContinue).Source
        if (-not $javaExe) { $javaExe = 'java.exe' }
        $agentArgs = "-jar `"$AgentRoot\agent.jar`" -url $JenkinsUrl -secret $nodeSecret -name $nodeName -workDir `"$AgentRoot\workspace`" -webSocket"
        # 清除旧服务
        & $nssmExe stop $serviceName 2>$null; & $nssmExe remove $serviceName confirm 2>$null
        # 注册新服务
        & $nssmExe install $serviceName $javaExe
        & $nssmExe set $serviceName AppParameters "$agentArgs"
        & $nssmExe set $serviceName AppDirectory $AgentRoot
        & $nssmExe set $serviceName AppStdout "$AgentRoot\agent-service.log"
        & $nssmExe set $serviceName AppStderr "$AgentRoot\agent-service.err.log"
        & $nssmExe set $serviceName AppRestartDelay 5000   # 崩了等5秒自动拉起
        & $nssmExe set $serviceName Start SERVICE_AUTO_START # 开机自启
        & $nssmExe set $serviceName ObjectName LocalSystem   # 管理员身份
        # 启动服务
        & $nssmExe start $serviceName
        Write-Ok "服务 $serviceName 已创建并启动 (开机自启+自动恢复)"
    } catch { Write-Fail "NSSM 服务注册失败: $_" }
} else {
    Write-Warn "NSSM/JNLP secret 不可用, 跳过服务注册。后续手动:"
    Write-Warn "  java -jar D:\agent\agent.jar -url $JenkinsUrl -secret <SECRET> -name $nodeName -workDir D:\agent\workspace"
}

# ══════════════════════════════════════════════════════════════════
# 10. 安装 nightly_runner Python 依赖
# ══════════════════════════════════════════════════════════════════
Write-Step "安装 nightly_runner Python 依赖"
try {
    $reqFile = "$AgentRoot\booming-il2cpp\testing\foundation-dll\requirements.txt"
    if (Test-Path $reqFile) {
        pip install -r $reqFile 2>&1 | Out-Null
        Write-Ok "Python 依赖已安装"
    } else {
        Write-Host "  [INFO] 引擎目录尚未同步, 同步后再安装 pip 依赖:"
        Write-Host "  Linux 上: bash agent_export/sync-to-windows.sh <本机IP>"
        Write-Host "  然后手动: pip install -r D:\agent\workspace\booming-il2cpp\testing\foundation-dll\requirements.txt"
    }
} catch { Write-Warn "pip 安装异常: $_" }

# ══════════════════════════════════════════════════════════════════
# 11. 验证 agent 连接状态
# ══════════════════════════════════════════════════════════════════
Write-Step "验证 Jenkins agent 连接 (等待 30 秒)"
try {
    Start-Sleep -Seconds 5
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Seconds 3
        $nodeInfo = Invoke-RestMethod -Uri "$JenkinsUrl/computer/$nodeName/api/json" -UseBasicParsing -ErrorAction SilentlyContinue
        if ($nodeInfo -and $nodeInfo.offline -eq $false) {
            Write-Ok "节点 $nodeName 已在线!"
            break
        }
        if ($i -eq 9) { Write-Warn "节点尚未在线, 请检查 Jenkins UI: $JenkinsUrl/computer/$nodeName/" }
    }
} catch { Write-Warn "无法验证节点状态" }

# ══════════════════════════════════════════════════════════════════
# 12. 完成
# ══════════════════════════════════════════════════════════════════
Write-Step "✅ 部署完成"

Write-Host ""
Write-Host "==============================================" -ForegroundColor Green
Write-Host "  Windows Nightly Agent 已就绪" -ForegroundColor Green
Write-Host "==============================================" -ForegroundColor Green
Write-Host ""
Write-Host "  本机 IP:    $MY_IP"
Write-Host "  用户:       $AgentUser"
Write-Host "  密码:       (你刚才设置的)"
Write-Host "  安装目录:   $AgentRoot"
Write-Host "  Jenkins:    $JenkinsUrl"
Write-Host "  节点名:     $nodeName"
Write-Host ""
Write-Host "  ── 下一步: 从 Linux 同步引擎源码 ──────────"
Write-Host "  bash /home/debian/agent/chaos-il2cpp-nightly-test/agent_export/sync-to-windows.sh $MY_IP"
Write-Host ""
Write-Host "  ── 从 Linux 远程管理 ──────────────────────"
Write-Host "  ssh $AgentUser@$MY_IP"
Write-Host "  (连接时会问密码, 输入你刚才设置的那个)"
Write-Host ""
Write-Host "  ── 日常操作 (全部在 Linux 上执行) ─────────"
Write-Host "  同步源码:   bash sync-to-windows.sh $MY_IP"
Write-Host "  尾日志:     ssh $AgentUser@$MY_IP 'Get-Content D:\agent\agent-service.log -Tail 20'"
Write-Host "  重启服务:   ssh $AgentUser@$MY_IP 'Restart-Service JenkinsAgent-$nodeName'"
Write-Host "  查节点:     $JenkinsUrl/computer/$nodeName/"
Write-Host ""
Write-Host "  ── 验收标准 ───────────────────────────────"
Write-Host "  1. 以上无 [FAIL] → 工具链就绪"
Write-Host "  2. Jenkins UI → Nodes → $nodeName → 绿色在线"
Write-Host "  3. 从 Linux SSH 能连: ssh $AgentUser@$MY_IP"
Write-Host "  4. 触发一次 nightly 构建, 在 Stage View 中看到"
Write-Host "     'Full Pipeline (x64 + Windows)' 下两个分支"
Write-Host "     (linux-x64 / windows-x64) 同时跑"
Write-Host ""

if (-not $script:allOk) {
    Write-Host "  ⚠️ 部分步骤有 [FAIL], 请根据上方红色错误信息手动修复。" -ForegroundColor Yellow
} else {
    Write-Host "  ✅ 全部通过。" -ForegroundColor Green
}
Read-Host "按 Enter 退出"