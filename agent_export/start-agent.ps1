# chaos-il2cpp Windows Nightly Agent — agent 启动脚本 (JNLP)
# 用法:  .\start-agent.ps1 -Secret <SECRET> [-JenkinsUrl http://10.10.1.173:8080] [-Foreground]
# 说明:
#   默认以后台方式启动 java agent.jar 并立即返回。
#   加 -Foreground 则在前台运行 (便于首次排错看日志)。
param(
    [Parameter(Mandatory=$true)] [string]$Secret,
    [string]$JenkinsUrl = 'http://10.10.1.173:8080',
    [string]$WorkDir     = 'D:\agent\workspace',
    [string]$JavaExe     = 'java',
    [switch]$Foreground
)

$ErrorActionPreference = 'Stop'
$agentJar = 'D:\agent\agent.jar'

# 1. 确保 workDir
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

# 2. 确保 agent.jar 存在
if (-not (Test-Path $agentJar)) {
    Write-Host "[INFO] 下载 agent.jar 从 $JenkinsUrl ..."
    Invoke-WebRequest -Uri "$JenkinsUrl/jnlpJars/agent.jar" -OutFile $agentJar
}

# 3. 校验 Java
if (-not (Get-Command $JavaExe -ErrorAction SilentlyContinue)) {
    throw "找不到 java。请安装 JDK 17 并加入 PATH，或提供 -JavaExe <完整路径>。"
}

$argsList = @(
    '-jar', $agentJar,
    '-url', $JenkinsUrl,
    '-secret', $Secret,
    '-name', 'windows-x64',
    '-workDir', $WorkDir
)

if ($Foreground) {
    Write-Host "[INFO] 前台运行 agent (Ctrl+C 停止)..."
    & $JavaExe @argsList
} else {
    Write-Host "[INFO] 后台启动 agent... 日志: D:\agent\agent.log"
    try {
        Start-Process -FilePath $JavaExe -ArgumentList $argsList -WindowStyle Hidden `
            -RedirectStandardOutput D:\agent\agent.log -RedirectStandardError D:\agent\agent.err.log
        Write-Host "[OK] agent 已后台启动。查看日志: D:\agent\agent.log"
    } catch {
        Write-Host "[FAIL] 后台启动失败: $_`n      请尝试 -Foreground 前台运行查看报错。"
    }
}
