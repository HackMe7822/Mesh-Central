#Requires -RunAsAdministrator
# WDA Capture Fix — downloads capturedrv.sys + wdaclear.exe from GitHub,
# installs the kernel driver (enables testsigning if needed), sets wdaclear
# to autostart. Run once on each exam machine via MeshCentral terminal.

$BASE = "https://raw.githubusercontent.com/HackMe7822/Mesh-Central/main/drivers"
$DEST = "C:\WdaFix"

New-Item -ItemType Directory -Path $DEST -Force | Out-Null

Write-Host "[*] Downloading files..."
Invoke-WebRequest "$BASE/capturedrv.sys" -OutFile "$DEST\capturedrv.sys" -UseBasicParsing
Invoke-WebRequest "$BASE/capturedrv.cer" -OutFile "$DEST\capturedrv.cer" -UseBasicParsing
Invoke-WebRequest "$BASE/capturedrv.inf" -OutFile "$DEST\capturedrv.inf" -UseBasicParsing
Invoke-WebRequest "$BASE/wdaclear.exe"   -OutFile "$DEST\wdaclear.exe"   -UseBasicParsing
Write-Host "[+] Downloaded"

Write-Host "[*] Installing certificate..."
certutil -addstore -f "Root"            "$DEST\capturedrv.cer" | Out-Null
certutil -addstore -f "TrustedPublisher" "$DEST\capturedrv.cer" | Out-Null

Write-Host "[*] Enabling test signing..."
$before = (bcdedit /enum "{current}" | Select-String "testsigning").ToString()
bcdedit /set testsigning on | Out-Null

Write-Host "[*] Installing driver..."
Copy-Item "$DEST\capturedrv.sys" "$env:SystemRoot\System32\drivers\capturedrv.sys" -Force
sc.exe stop  capturedrv 2>$null
sc.exe delete capturedrv 2>$null
Start-Sleep 2
sc.exe create capturedrv binPath= "$env:SystemRoot\System32\drivers\capturedrv.sys" type= kernel start= auto error= normal DisplayName= "WDA Capture Driver" | Out-Null

sc.exe start capturedrv
if ($LASTEXITCODE -ne 0) {
    Write-Host "[!] Driver failed to start — testsigning may need a reboot first." -ForegroundColor Yellow
    Write-Host "[!] REBOOTING in 10 seconds to apply testsigning..." -ForegroundColor Yellow
    Start-Sleep 10
    Restart-Computer -Force
    exit
}
Write-Host "[+] Driver running"

Write-Host "[*] Setting wdaclear.exe autostart..."
Copy-Item "$DEST\wdaclear.exe" "$DEST\wdaclear.exe" -Force
Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" -Name "WdaClear" -Value "$DEST\wdaclear.exe" -Force
Get-Process wdaclear -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Process "$DEST\wdaclear.exe"
Start-Sleep 1

if (Get-Process wdaclear -ErrorAction SilentlyContinue) {
    Write-Host "[+] wdaclear.exe running — WDA cleared every 100ms on all desktops" -ForegroundColor Green
} else {
    Write-Host "[!] wdaclear.exe not running — check $DEST manually" -ForegroundColor Red
}

Write-Host ""
Write-Host "=== DONE === Connect via MeshCentral and open exam app — no black screen." -ForegroundColor Green
