#Requires -RunAsAdministrator
<#
.SYNOPSIS
  MeshCentral restore — from folder ZIP snapshot or DB export JSON.

.PARAMETER BackupFile
  Path to either:
    - A folder snapshot ZIP:   meshcentral-data-2026-07-28_02-00.zip
    - A DB export JSON:        meshcentral-dbexport-2026-07-28_02-00.json
  If not provided, lists available backups from BackupDir and prompts.

.PARAMETER InstallDir
  MeshCentral install directory. Default: C:\MeshCentral

.PARAMETER BackupDir
  Where to look for backups when no -BackupFile given. Default: C:\MeshCentral-Backups

.PARAMETER Force
  Skip confirmation prompt.

.EXAMPLE
  .\restore.ps1
  .\restore.ps1 -BackupFile "C:\MeshCentral-Backups\meshcentral-dbexport-2026-07-28_02-00.json"
  .\restore.ps1 -BackupFile "C:\MeshCentral-Backups\meshcentral-data-2026-07-28_02-00.zip"
  .\restore.ps1 -Force
#>
param(
    [string]$BackupFile  = "",
    [string]$InstallDir  = "C:\MeshCentral",
    [string]$BackupDir   = "C:\MeshCentral-Backups",
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$dataDir = Join-Path $InstallDir "meshcentral-data"

function Write-OK   { param($m) Write-Host "[OK] $m"   -ForegroundColor Green  }
function Write-Info { param($m) Write-Host "[..] $m"   -ForegroundColor Cyan   }
function Write-Fail { param($m) Write-Host "[!!] $m"   -ForegroundColor Red; exit 1 }
function Write-Warn { param($m) Write-Host "[WW] $m"   -ForegroundColor Yellow }

# ── Pick backup file ──────────────────────────────────────────────────────────
if (-not $BackupFile) {
    if (-not (Test-Path $BackupDir)) {
        Write-Fail "No -BackupFile provided and backup dir not found: $BackupDir"
    }
    $files = Get-ChildItem $BackupDir -File |
        Where-Object { $_.Extension -in ".zip", ".json" } |
        Sort-Object LastWriteTime -Descending

    if ($files.Count -eq 0) {
        Write-Fail "No backup files found in: $BackupDir"
    }

    Write-Host ""
    Write-Host "Available backups:" -ForegroundColor Cyan
    for ($i = 0; $i -lt [Math]::Min($files.Count, 10); $i++) {
        $f = $files[$i]
        Write-Host "  [$($i+1)] $($f.Name)  ($([math]::Round($f.Length/1MB,1)) MB)  $($f.LastWriteTime)"
    }
    Write-Host ""
    $choice = Read-Host "Enter number to restore (or Q to quit)"
    if ($choice -eq "Q" -or $choice -eq "q") { exit 0 }
    $idx = [int]$choice - 1
    if ($idx -lt 0 -or $idx -ge $files.Count) { Write-Fail "Invalid selection" }
    $BackupFile = $files[$idx].FullName
}

if (-not (Test-Path $BackupFile)) {
    Write-Fail "Backup file not found: $BackupFile"
}

$ext  = [System.IO.Path]::GetExtension($BackupFile).ToLower()
$name = [System.IO.Path]::GetFileName($BackupFile)
$sizeMB = [math]::Round((Get-Item $BackupFile).Length / 1MB, 1)

Write-Host ""
Write-Host "=== MeshCentral Restore ===" -ForegroundColor Yellow
Write-Host "File:       $name  ($sizeMB MB)"
Write-Host "Type:       $(if ($ext -eq '.zip') { 'Folder Snapshot (ZIP)' } else { 'DB Export (JSON)' })"
Write-Host "InstallDir: $InstallDir"
Write-Host ""

if (-not $Force) {
    $confirm = Read-Host "This will OVERWRITE current MeshCentral data. Type YES to continue"
    if ($confirm -ne "YES") { Write-Host "Cancelled."; exit 0 }
}

# ── Stop service ──────────────────────────────────────────────────────────────
$svcRunning = $false
$svc = Get-Service "MeshCentral" -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq "Running") {
    $svcRunning = $true
    Write-Info "Stopping MeshCentral service..."
    Stop-Service MeshCentral -Force
    Start-Sleep 3
}

# ── Restore ───────────────────────────────────────────────────────────────────
$restoreOk = $false

if ($ext -eq ".zip") {
    # ── ZIP: replace meshcentral-data folder ──────────────────────────────────
    Write-Info "Extracting folder snapshot..."

    $stagingDir = Join-Path $env:TEMP "mc-restore-staging"
    if (Test-Path $stagingDir) { Remove-Item $stagingDir -Recurse -Force }
    New-Item -ItemType Directory $stagingDir | Out-Null

    Expand-Archive -Path $BackupFile -DestinationPath $stagingDir -Force

    # Backup file may contain meshcentral-data as root or as subfolder
    $extractedData = Join-Path $stagingDir "meshcentral-data"
    if (-not (Test-Path $extractedData)) {
        # Try one level deeper
        $extractedData = Get-ChildItem $stagingDir -Directory |
            Where-Object { $_.Name -eq "meshcentral-data" } |
            Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $extractedData -or -not (Test-Path $extractedData)) {
        Write-Fail "Could not find meshcentral-data inside the ZIP. Check archive structure."
    }

    # Move existing data aside
    if (Test-Path $dataDir) {
        $oldName = "$dataDir-OLD-$(Get-Date -Format 'HHmmss')"
        Write-Info "Moving existing data to: $oldName"
        Rename-Item $dataDir $oldName
    }

    Write-Info "Copying restored data to: $dataDir"
    Copy-Item $extractedData $dataDir -Recurse -Force
    Remove-Item $stagingDir -Recurse -Force
    Write-OK "Folder snapshot restored."
    $restoreOk = $true

} elseif ($ext -eq ".json") {
    # ── JSON: DB import ────────────────────────────────────────────────────────
    Write-Info "Running DB import from: $BackupFile ..."
    Push-Location $InstallDir
    try {
        node node_modules\meshcentral --dbimport $BackupFile
        Write-OK "DB import complete."
        $restoreOk = $true
    } catch {
        Write-Warn "DB import error: $_"
    } finally {
        Pop-Location
    }
} else {
    Write-Fail "Unsupported file type: $ext  (must be .zip or .json)"
}

# ── Restart service ───────────────────────────────────────────────────────────
if ($svcRunning) {
    Write-Info "Starting MeshCentral service..."
    Start-Service MeshCentral -ErrorAction SilentlyContinue
    Start-Sleep 5
    $status = (Get-Service MeshCentral -EA 0).Status
    if ($status -eq "Running") {
        Write-OK "MeshCentral is Running."
    } else {
        Write-Warn "MeshCentral status: $status — check manually: cd $InstallDir && node node_modules\meshcentral"
    }
}

if ($restoreOk) {
    Write-Host ""
    Write-Host "=== Restore Complete ===" -ForegroundColor Green
    Write-Host "Open https://remote.creationsit.com and verify data." -ForegroundColor White
}
