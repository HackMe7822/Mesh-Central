#Requires -RunAsAdministrator

# Self-elevate if not already Administrator
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

Write-Host ""
Write-Host "  ============================================" -ForegroundColor Blue
Write-Host "    Creations IT  -  Remote Support Deployer" -ForegroundColor Blue
Write-Host "  ============================================" -ForegroundColor Blue
Write-Host ""
Write-Host "  Downloading latest installer..." -ForegroundColor Cyan

# Try GitHub API first (cache-free), fall back to raw URL
try {
    $api = iwr "https://api.github.com/repos/HackMe7822/Mesh-Central/contents/install.ps1" -UseBasicParsing | ConvertFrom-Json
    iwr $api.download_url -OutFile "C:\deploy.ps1" -UseBasicParsing
} catch {
    iwr "https://raw.githubusercontent.com/HackMe7822/Mesh-Central/main/install.ps1" -OutFile "C:\deploy.ps1" -UseBasicParsing
}

Write-Host "  Running installer..." -ForegroundColor Cyan
powershell -ExecutionPolicy Bypass -File "C:\deploy.ps1"
