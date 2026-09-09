# chaos-il2cpp Windows Nightly Agent — 工具链验证脚本
# 用法:  powershell -ExecutionPolicy Bypass -File verify-tools.ps1
# 全部 [OK] 表示工具链就绪, 可继续 agent 连接。

$ErrorActionPreference = 'Continue'

function Out($name, [bool]$ok) {
    $tag = if ($ok) { '[OK]  ' } else { '[FAIL]' }
    Write-Host "$tag $name" -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
}

# --- .NET ---
$dotnetSdks = if ((Get-Command dotnet -ErrorAction SilentlyContinue)) { dotnet --list-sdks 2>&1 } else { @() }
Out 'dotnet SDK 10.0'   ($dotnetSdks -match '10\.0')
Out 'dotnet SDK 8.0'    ($dotnetSdks -match '8\.0')

# --- Python ---
$pyOk = $false
if (Get-Command python -ErrorAction SilentlyContinue) {
    $pyVer = python --version 2>&1
    $pyOk = $pyVer -match 'Python 3\.(1[0-9]|9)'
}
Out 'python 3.10+' $pyOk

# --- CMake ---
Out 'cmake' ([bool](Get-Command cmake -ErrorAction SilentlyContinue))

# --- Git ---
Out 'git' ([bool](Get-Command git -ErrorAction SilentlyContinue))

# --- Java ---
Out 'java' ([bool](Get-Command java -ErrorAction SilentlyContinue))

# --- MSVC (VS Build Tools C++) ---
$vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
$hasCpp = $false
if (Test-Path $vswhere) {
    $path = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
    if ($path) { $hasCpp = $true }
}
Out 'MSVC C++ 工具链' $hasCpp

# --- agent.jar 存在 ---
Out 'D:\agent\agent.jar 存在' (Test-Path 'D:\agent\agent.jar')

Write-Host ''
$allOk = $dotnetSdks -match '10\.0' -and $dotnetSdks -match '8\.0' -and $pyOk -and $hasCpp
if ($allOk) {
    Write-Host '✔ 核心工具链就绪, 可进行 JNLP agent 连接。' -ForegroundColor Green
} else {
    Write-Host '! 仍有缺失, 请参照 install-agent-tools.ps1 / README 补齐后再继续。' -ForegroundColor Red
}
