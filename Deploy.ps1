$ErrorActionPreference = "Stop"

# Self-elevate to Administrator
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $path = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
    Start-Process powershell -ArgumentList "-NoExit -ExecutionPolicy Bypass -File `"$path`"" -Verb RunAs
    exit
}

Write-Host ""
Write-Host "  ============================================" -ForegroundColor Blue
Write-Host "    Creations IT  -  Remote Support Deployer" -ForegroundColor Blue
Write-Host "  ============================================" -ForegroundColor Blue
Write-Host ""

try {
    Write-Host "  Downloading latest installer from GitHub..." -ForegroundColor Cyan
    $api = Invoke-WebRequest "https://api.github.com/repos/HackMe7822/Mesh-Central/contents/install.ps1" -UseBasicParsing | ConvertFrom-Json
    Invoke-WebRequest $api.download_url -OutFile "C:\deploy.ps1" -UseBasicParsing
    Write-Host "  Download complete. Starting installer..." -ForegroundColor Green
    powershell -ExecutionPolicy Bypass -File "C:\deploy.ps1"
} catch {
    Write-Host ""
    Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Read-Host "  Press Enter to close"
}
