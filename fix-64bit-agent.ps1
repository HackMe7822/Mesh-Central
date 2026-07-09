#Requires -RunAsAdministrator
# Removes the broken custom 64-bit agent binary from the server's agents directory
# so MeshCentral re-downloads the official clean binary on next restart.

$agentsDir = $null
foreach ($d in @(
    "C:\MeshCentral\node_modules\meshcentral\agents",
    "C:\meshcentral\node_modules\meshcentral\agents"
)) { if (Test-Path $d) { $agentsDir = $d; break } }

if (-not $agentsDir) {
    $agentsDir = Get-ChildItem "C:\" -Recurse -Depth 9 -Directory -EA 0 |
        Where-Object { $_.FullName -match "node_modules.meshcentral.agents$" } |
        Select-Object -First 1 -ExpandProperty FullName
}

if (-not $agentsDir) { Write-Host "ERROR: agents directory not found" -ForegroundColor Red; exit 1 }
Write-Host "Agents dir: $agentsDir" -ForegroundColor Cyan

Write-Host "Current 64-bit files:" -ForegroundColor Yellow
Get-ChildItem $agentsDir | Where-Object { $_.Name -match "64" } | Format-Table Name, Length -AutoSize

Write-Host "Stopping MeshCentral..." -ForegroundColor Cyan
Stop-Service MeshCentral -Force -EA 0
Start-Sleep 3

Write-Host "Removing custom 64-bit binaries (MeshCentral will re-download official ones)..." -ForegroundColor Cyan
Get-ChildItem $agentsDir | Where-Object { $_.Name -match "64" } | ForEach-Object {
    Remove-Item $_.FullName -Force -EA 0
    Write-Host "  Deleted: $($_.Name)" -ForegroundColor Green
}

Write-Host "Starting MeshCentral (will download fresh 64-bit agents from internet)..." -ForegroundColor Cyan
Start-Service MeshCentral -EA 0
Start-Sleep 15

Write-Host "New 64-bit files downloaded:" -ForegroundColor Yellow
Get-ChildItem $agentsDir | Where-Object { $_.Name -match "64" } | Format-Table Name, Length -AutoSize

$status = (Get-Service MeshCentral -EA 0).Status
Write-Host "MeshCentral: $status" -ForegroundColor $(if ($status -eq "Running") { "Green" } else { "Red" })
Write-Host "Done. Download a fresh 64-bit installer from the admin panel." -ForegroundColor Green
