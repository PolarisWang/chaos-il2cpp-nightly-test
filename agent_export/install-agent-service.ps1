# chaos-il2cpp Windows Nightly Agent — 用 NSSM 注册为 Windows 服务（开机自启）
# 用法:  .\install-agent-service.ps1 -Secret <SECRET> [-JenkinsUrl http://10.10.1.173:8080]
# 说明:
#   1. 下载 NSSM (Non-Sucking Service Manager)
#   2. 用 NSSM 注册 Jenkins agent 为 "JenkinsAgent-windows-x64" 服务
#   3. 设置自动重启 (Restart=always)
#   4. 启动该服务
param(
    [Parameter(Mandatory=$true)] [string]$Secret,
    [string]$JenkinsUrl = 'http://10.10.1.173:8080',
    [string]$WorkDir     = 'C:\agent\workspace',
    [string]$JavaExe     = 'java'
)

$ErrorActionPreference = 'Stop'
$agentJar  = 'C:\agent\agent.jar'
$nssmDir   = 'C:\agent\nssm'
$nssmExe   = "$nssmDir\nssm.exe"
$serviceName = 'JenkinsAgent-windows-x64'

# 1. 确保 Java
if (-not (Get-Command $JavaExe -ErrorAction SilentlyContinue)) {
    throw "找不到 java。请先安装 JDK 17。"
}

# 2. 确保 agent.jar
New-Item -ItemType Directory -Path C:\agent -Force | Out-Null
if (-not (Test-Path $agentJar)) {
    Write-Host "[INFO] 下载 agent.jar $JenkinsUrl ..."
    Invoke-WebRequest -Uri "$JenkinsUrl/jnlpJars/agent.jar" -OutFile $agentJar
}

# 3. 下载 NSSM
if (-not (Test-Path $nssmExe)) {
    $nssmZip = "$env:TEMP\nssm.zip"
    New-Item -ItemType Directory -Path $nssmDir -Force | Out-Null
    Write-Host "[INFO] 下载 NSSM ..."
    Invoke-WebRequest -Uri 'https://nssm.cc/release/nssm-2.24-101-g897c7ad.zip' -OutFile $nssmZip
    Expand-Archive -Path $nssmZip -DestinationPath $env:TEMP -Force
    Copy-Item "$env:TEMP\nssm-2.24-101-g897c7ad\win64\nssm.exe" $nssmExe
    Remove-Item $nssmZip -Force
    Remove-Item "$env:TEMP\nssm-2.24-101-g897c7ad" -Recurse -Force
    Write-Host "[OK] NSSM 已下载到 $nssmExe"
}

# 4. 注册服务
Write-Host "[INFO] 注册服务 $serviceName ..."
$javaFull = (Get-Command $JavaExe).Source
$agentArgs = @(
    '-jar', $agentJar,
    '-url', $JenkinsUrl,
    '-secret', $Secret,
    '-name', 'windows-x64',
    '-workDir', $WorkDir
)

# 移除旧服务（如果存在）
& $nssmExe stop $serviceName 2>$null
& $nssmExe remove $serviceName confirm 2>$null

# 新建服务
& $nssmExe install $serviceName $javaFull
& $nssmExe set $serviceName AppParameters ($agentArgs -join ' ')
& $nssmExe set $serviceName AppDirectory C:\agent
& $nssmExe set $serviceName AppStdout C:\agent\agent-service.log
& $nssmExe set $serviceName AppStderr C:\agent\agent-service.err.log
& $nssmExe set $serviceName AppRestartDelay 5000          # 5秒后自动重启
& $nssmExe set $serviceName Start SERVICE_AUTO_START      # 开机自启
& $nssmExe set $serviceName ObjectName LocalSystem         # 管理员身份运行

# 5. 启动服务
Write-Host "[INFO] 启动服务 $serviceName ..."
& $nssmExe start $serviceName

Write-Host "[OK] 服务 $serviceName 已启动 (开机自启)"
Write-Host "    查看状态:  sc query $serviceName"
Write-Host "    查看日志:  C:\agent\agent-service.log"
Write-Host "    停止服务:  nssm stop $serviceName"
Write-Host "    卸载服务:  nssm remove $serviceName confirm"