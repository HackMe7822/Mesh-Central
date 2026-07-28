#Requires -RunAsAdministrator
<#
.SYNOPSIS
  MeshCentral backup — folder snapshot + database export.

.PARAMETER InstallDir
  MeshCentral install directory. Default: C:\MeshCentral

.PARAMETER BackupDir
  Where to save backups. Default: C:\MeshCentral-Backups

.PARAMETER FolderOnly
  Only do the zip snapshot, skip the dbexport (faster, no service stop needed).

.PARAMETER ExportOnly
  Only do the dbexport JSON, skip the zip snapshot.

.EXAMPLE
  .\backup.ps1
  .\backup.ps1 -BackupDir "D:\Backups"
  .\backup.ps1 -FolderOnly
  .\backup.ps1 -ExportOnly
#>
param(
    [string]$InstallDir  = "C:\MeshCentral",
    [string]$BackupDir   = "C:\MeshCentral-Backups",
    [switch]$FolderOnly,
    [switch]$ExportOnly
)

$ErrorActionPreference = "Stop"
$date    = Get-Date -Format "yyyy-MM-dd_HH-mm"
$dataDir = Join-Path $InstallDir "meshcentral-data"

function Write-OK   { param($m) Write-Host "[OK] $m"   -ForegroundColor Green  }
function Write-Info { param($m) Write-Host "[..] $m"   -ForegroundColor Cyan   }
function Write-Fail { param($m) Write-Host "[!!] $m"   -ForegroundColor Red; exit 1 }
function Write-Warn { param($m) Write-Host "[WW] $m"   -ForegroundColor Yellow }

# ── Validate paths ────────────────────────────────────────────────────────────
if (-not (Test-Path $dataDir)) {
    Write-Fail "meshcentral-data not found at: $dataDir  (check -InstallDir)"
}
New-Item -ItemType Directory -Force $BackupDir | Out-Null
Write-Info "Backup destination: $BackupDir"

# ── Method 1: Folder ZIP snapshot ─────────────────────────────────────────────
if (-not $ExportOnly) {
    $zipPath = Join-Path $BackupDir "meshcentral-data-$date.zip"
    Write-Info "Creating folder snapshot: $zipPath ..."
    try {
        Compress-Archive -Path $dataDir -DestinationPath $zipPath -Force
        $sizeMB = [math]::Round((Get-Item $zipPath).Length / 1MB, 1)
        Write-OK "Folder snapshot saved: $zipPath  ($sizeMB MB)"
    } catch {
        Write-Warn "Folder snapshot failed: $_"
    }
}

# ── Method 2: MeshCentral DB export (JSON) ────────────────────────────────────
if (-not $FolderOnly) {
    $exportPath = Join-Path $BackupDir "meshcentral-dbexport-$date.json"
    $svcRunning = $false

    $svc = Get-Service "MeshCentral" -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") {
        $svcRunning = $true
        Write-Info "Stopping MeshCentral service for DB export..."
        Stop-Service MeshCentral -Force
        Start-Sleep 3
    }

    try {
        Write-Info "Running DB export → $exportPath ..."
        Push-Location $InstallDir
        $env:NODE_PATH = Join-Path $InstallDir "node_modules"
        node node_modules\meshcentral --dbexport --dbexportfile $exportPath
        Pop-Location

        if (Test-Path $exportPath) {
            $sizeMB = [math]::Round((Get-Item $exportPath).Length / 1MB, 1)
            Write-OK "DB export saved: $exportPath  ($sizeMB MB)"
        } else {
            Write-Warn "DB export ran but output file not found at: $exportPath"
        }
    } catch {
        Write-Warn "DB export failed: $_"
    } finally {
        if ($svcRunning) {
            Write-Info "Restarting MeshCentral service..."
            Start-Service MeshCentral -ErrorAction SilentlyContinue
            Start-Sleep 3
            $status = (Get-Service MeshCentral -EA 0).Status
            Write-OK "MeshCentral: $status"
        }
    }
}

# ── Cleanup old backups (keep last 14 days) ───────────────────────────────────
Write-Info "Removing backups older than 14 days..."
$cutoff = (Get-Date).AddDays(-14)
$removed = 0
Get-ChildItem $BackupDir -File | Where-Object { $_.LastWriteTime -lt $cutoff } | ForEach-Object {
    Remove-Item $_.FullName -Force -EA 0
    $removed++
}
if ($removed -gt 0) { Write-OK "Removed $removed old backup file(s)" }

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== Backup Complete ===" -ForegroundColor Cyan
Write-Host "Location: $BackupDir" -ForegroundColor White
Get-ChildItem $BackupDir -File | Sort-Object LastWriteTime -Descending |
    Select-Object -First 5 |
    ForEach-Object { Write-Host "  $($_.Name)  ($([math]::Round($_.Length/1MB,1)) MB)" }
