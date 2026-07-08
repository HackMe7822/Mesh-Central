#Requires -RunAsAdministrator
# Force-removes the old Mesh Agent and CreationsCapture driver completely.
# Run this on the exam machine before installing the new agent.

Write-Host "[*] Stopping and removing Mesh Agent service..." -ForegroundColor Cyan
Stop-Service "Mesh Agent" -Force -ErrorAction SilentlyContinue
Start-Sleep 2
sc.exe delete "Mesh Agent" | Out-Null

Write-Host "[*] Stopping and removing capture driver service..." -ForegroundColor Cyan
sc.exe stop  CreationsCapture | Out-Null
sc.exe delete CreationsCapture | Out-Null

Write-Host "[*] Removing registry entries..." -ForegroundColor Cyan
$regPaths = @(
    "HKLM:\SYSTEM\CurrentControlSet\Services\Mesh Agent",
    "HKLM:\SYSTEM\CurrentControlSet\Services\CreationsCapture",
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Mesh Agent"
)
foreach ($p in $regPaths) {
    if (Test-Path $p) {
        Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  Removed: $p" -ForegroundColor Green
    }
}

Write-Host "[*] Removing firewall rules..." -ForegroundColor Cyan
Remove-NetFirewallRule -DisplayName "*Mesh*" -ErrorAction SilentlyContinue
Remove-NetFirewallRule -DisplayName "*CreationsIT*" -ErrorAction SilentlyContinue

Write-Host "[*] Removing files..." -ForegroundColor Cyan
$paths = @(
    "C:\Program Files\Creations IT",
    "C:\Program Files\Mesh Agent",
    "C:\Windows\System32\drivers\capturedrv.sys"
)
foreach ($p in $paths) {
    if (Test-Path $p) {
        Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  Removed: $p" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "[DONE] Machine is clean. You can now run the new installer." -ForegroundColor Green
