# setup.ps1 — Register a Windows machine as a Jenkins agent
# Run this on the Windows build machine to connect to Jenkins master
# Usage: .\setup.ps1 -MasterUrl "http://..." -AgentName "windows-x64"

param(
    [string]$MasterUrl = "http://chaos-master:8080",
    [string]$AgentName = "windows-x64",
    [string]$AgentSecret = "",
    [string]$WorkDir = "$env:USERPROFILE\jenkins-agent",
    [string[]]$Labels = @("windows", "x64", "native")
)

Write-Host "=== Setting up Windows Jenkins Agent ===" -ForegroundColor Cyan
Write-Host "Master: $MasterUrl"
Write-Host "Agent:  $AgentName"

# Create working directory
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

# Download agent.jar if not present
$AgentJar = "$WorkDir\agent.jar"
if (-not (Test-Path $AgentJar)) {
    $AgentUrl = "$MasterUrl/jnlpJars/agent.jar"
    Write-Host "Downloading agent.jar from $AgentUrl"
    Invoke-WebRequest -Uri $AgentUrl -OutFile $AgentJar
}

# Create launch script
$LaunchScript = "$WorkDir\launch-agent.ps1"
$LabelsStr = $Labels -join " "
$ScriptContent = @"
# Launch Jenkins agent
`$env:JENKINS_URL = "$MasterUrl"
cd "$WorkDir"
java -jar agent.jar `
    -url "$MasterUrl" `
    -name "$AgentName" `
    -secret "$AgentSecret" `
    -workDir "$WorkDir" `
    -labels "$LabelsStr"
"@
Set-Content -Path $LaunchScript -Value $ScriptContent

Write-Host ""
Write-Host "=== Setup Complete ===" -ForegroundColor Green
Write-Host "To start the agent manually:"
Write-Host "  powershell -File $LaunchScript"
Write-Host ""
Write-Host "To register as a Windows Service (auto-start on boot):"
Write-Host "  sc.exe create JenkinsAgent binPath= 'cmd.exe /c powershell -File $LaunchScript' start= auto"
Write-Host ""
Write-Host "NOTE: Set AgentSecret from Jenkins Master → Manage Nodes → $AgentName"
