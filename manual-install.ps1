#Requires -RunAsAdministrator
param([string]$Installer = "")

if (-not $Installer -or -not (Test-Path $Installer)) {
    Write-Host "Usage: .\manual-install.ps1 -Installer 'C:\path\to\CreationsIT-Agent64-Arries.exe'" -ForegroundColor Red
    exit 1
}

$InstDir  = "C:\Program Files (x86)\Creations IT\Mesh Agent"
$ExeName  = "CreationsIT-Agent.exe"
$SvcName  = "Mesh Agent"
$ExePath  = "$InstDir\$ExeName"

Write-Host "[1] Killing processes..." -ForegroundColor Cyan
Get-Process | Where-Object { $_.Path -like "*Creations IT*" -or $_.Name -like "*MeshAgent*" } | Stop-Process -Force -EA 0
Start-Sleep 2

Write-Host "[2] Removing old service..." -ForegroundColor Cyan
sc.exe stop  $SvcName        | Out-Null
sc.exe delete $SvcName       | Out-Null
sc.exe stop  "CreationsCapture" | Out-Null
sc.exe delete "CreationsCapture" | Out-Null
Start-Sleep 2

Write-Host "[3] Removing registry and files..." -ForegroundColor Cyan
Remove-Item "HKLM:\SYSTEM\CurrentControlSet\Services\$SvcName"   -Recurse -Force -EA 0
Remove-Item "HKLM:\SYSTEM\CurrentControlSet\Services\CreationsCapture" -Recurse -Force -EA 0
Remove-Item "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$SvcName" -Recurse -Force -EA 0
Remove-Item "C:\Program Files (x86)\Creations IT" -Recurse -Force -EA 0
Remove-Item "C:\Program Files\Creations IT"       -Recurse -Force -EA 0
Remove-Item "C:\Windows\System32\drivers\capturedrv.sys" -Force -EA 0

Write-Host "[4] Creating install directory..." -ForegroundColor Cyan
New-Item -ItemType Directory -Path $InstDir -Force | Out-Null

Write-Host "[5] Copying agent binary (no installer script runs)..." -ForegroundColor Cyan
Copy-Item $Installer $ExePath -Force
Write-Host "    Copied: $($Installer) -> $ExePath" -ForegroundColor Green

Write-Host "[6] Registering service..." -ForegroundColor Cyan
sc.exe create $SvcName binpath= "`"$ExePath`"" start= auto DisplayName= "Mesh Agent Service" | Out-Null
sc.exe description $SvcName "Mesh Agent" | Out-Null

Write-Host "[7] Firewall rule..." -ForegroundColor Cyan
Remove-NetFirewallRule -DisplayName "*Mesh*" -EA 0
New-NetFirewallRule -DisplayName "Mesh Agent" -Direction Inbound -Program $ExePath -Action Allow -EA 0 | Out-Null

Write-Host "[8] Starting service..." -ForegroundColor Cyan
Start-Service $SvcName -EA 0
Start-Sleep 3
$status = (Get-Service $SvcName -EA 0).Status
if ($status -eq "Running") {
    Write-Host "[DONE] Mesh Agent is Running. No driver installed. No installer script ran." -ForegroundColor Green
} else {
    Write-Host "[WARN] Service status: $status" -ForegroundColor Yellow
}
