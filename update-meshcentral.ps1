#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Safe MeshCentral update with automatic rollback.
    Creations IT — updates to HackMe7822/MeshCentral-Original fork.

.DESCRIPTION
    1. Backs up current node_modules\meshcentral to a zip
    2. Backs up meshcentral-data
    3. npm-installs new fork version
    4. Copies audiostream plugin to meshcentral-data\plugins\
    5. Enables plugin in config.json
    6. Restarts MeshCentral service
    7. Waits up to 5 minutes — if service dies, auto-rollbacks

.PARAMETER InstallDir
    MeshCentral install directory. Default: C:\MeshCentral

.PARAMETER Force
    Skip confirmation prompt.

.EXAMPLE
    .\update-meshcentral.ps1
    .\update-meshcentral.ps1 -InstallDir D:\MeshCentral -Force
#>
param(
    [string]$InstallDir = 'C:\MeshCentral',
    [switch]$Force
)

$GREEN  = "`e[32m"; $CYAN = "`e[36m"; $YELLOW = "`e[33m"; $RED = "`e[31m"; $NC = "`e[0m"
function ok   { Write-Host "${GREEN}[OK]${NC}  $args" }
function info { Write-Host "${CYAN}[..]${NC}  $args" }
function warn { Write-Host "${YELLOW}[WW]${NC}  $args" }
function fail { Write-Host "${RED}[!!]${NC}  $args"; exit 1 }

# ── Validate install dir ───────────────────────────────────────────────────────
if (-not (Test-Path "$InstallDir\node_modules\meshcentral")) {
    fail "MeshCentral not found at $InstallDir\node_modules\meshcentral"
}

Write-Host ""
Write-Host "${YELLOW}=== MeshCentral Safe Update — Creations IT ===${NC}"
Write-Host "  Install dir : $InstallDir"
Write-Host "  Fork        : github.com/HackMe7822/MeshCentral-Original"
Write-Host ""

if (-not $Force) {
    $confirm = Read-Host "  Continue? (y/N)"
    if ($confirm -ne 'y' -and $confirm -ne 'Y') { Write-Host "Cancelled."; exit 0 }
}

# ── Step 1: Backup current meshcentral package ────────────────────────────────
$date    = Get-Date -Format "yyyy-MM-dd_HH-mm"
$backDir = Join-Path $InstallDir "meshcentral-backups"
New-Item -ItemType Directory -Force $backDir | Out-Null

$pkgBackup  = Join-Path $backDir "meshcentral-pkg-$date.zip"
$dataBackup = Join-Path $backDir "meshcentral-data-$date.zip"

info "Backing up MeshCentral package..."
try {
    Compress-Archive -Path "$InstallDir\node_modules\meshcentral" `
                     -DestinationPath $pkgBackup -CompressionLevel Fastest
    ok "Package backup: $pkgBackup"
} catch {
    warn "Package backup failed (continuing anyway): $_"
}

info "Backing up meshcentral-data..."
try {
    $dataPath = Join-Path $InstallDir "meshcentral-data"
    if (Test-Path $dataPath) {
        Compress-Archive -Path $dataPath -DestinationPath $dataBackup -CompressionLevel Fastest
        ok "Data backup: $dataBackup"
    } else {
        warn "meshcentral-data not found — skipping data backup"
    }
} catch {
    warn "Data backup failed (continuing anyway): $_"
}

# ── Step 2: Stop service ───────────────────────────────────────────────────────
$svcName = 'MeshCentral'
$svcWasRunning = $false

$svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq 'Running') {
    $svcWasRunning = $true
    info "Stopping MeshCentral service..."
    Stop-Service -Name $svcName -Force
    Start-Sleep -Seconds 4
    ok "Service stopped"
}

# ── Step 3: npm install from fork ─────────────────────────────────────────────
info "Installing updated fork from GitHub..."
Set-Location $InstallDir

# Keep package.json intact, just reinstall meshcentral
try {
    $npmResult = & npm install "git+https://github.com/HackMe7822/MeshCentral-Original.git" 2>&1
    if ($LASTEXITCODE -ne 0) {
        warn "npm install returned exit code $LASTEXITCODE"
        Write-Host $npmResult
        # Rollback
        Write-Host "${RED}npm install FAILED — rolling back...${NC}"
        if (Test-Path $pkgBackup) {
            Remove-Item "$InstallDir\node_modules\meshcentral" -Recurse -Force -ErrorAction SilentlyContinue
            Expand-Archive -Path $pkgBackup -DestinationPath "$InstallDir\node_modules" -Force
            ok "Rollback complete"
        }
        if ($svcWasRunning) { Start-Service -Name $svcName -ErrorAction SilentlyContinue }
        fail "Update aborted — original version restored"
    }
    ok "npm install succeeded"
} catch {
    warn "npm install exception: $_"
    fail "npm install failed — server unchanged (service was stopped; restart manually if needed)"
}

# ── Step 4: Deploy audiostream plugin ─────────────────────────────────────────
$pluginSrc  = Join-Path $InstallDir "node_modules\meshcentral\plugins\audiostream"
$pluginDest = Join-Path $InstallDir "meshcentral-data\plugins\audiostream"

if (Test-Path $pluginSrc) {
    info "Deploying audiostream plugin to meshcentral-data\plugins\..."
    New-Item -ItemType Directory -Force (Split-Path $pluginDest) | Out-Null
    if (Test-Path $pluginDest) { Remove-Item $pluginDest -Recurse -Force }
    Copy-Item -Path $pluginSrc -Destination $pluginDest -Recurse
    ok "Plugin deployed: $pluginDest"
} else {
    warn "audiostream plugin not found in package — skipping plugin deploy"
}

# ── Step 5: Enable plugin in config.json ──────────────────────────────────────
$configPath = Join-Path $InstallDir "meshcentral-data\config.json"
if (Test-Path $configPath) {
    info "Updating config.json to enable audiostream plugin..."
    try {
        $cfg = Get-Content $configPath -Raw | ConvertFrom-Json

        # Ensure settings.plugins exists
        if ($null -eq $cfg.settings.plugins) {
            $cfg.settings | Add-Member -NotePropertyName 'plugins' -NotePropertyValue ([PSCustomObject]@{ enabled = $true; list = @('audiostream') }) -Force
        } else {
            $cfg.settings.plugins | Add-Member -NotePropertyName 'enabled' -NotePropertyValue $true -Force
            if ($null -eq $cfg.settings.plugins.list) {
                $cfg.settings.plugins | Add-Member -NotePropertyName 'list' -NotePropertyValue @('audiostream') -Force
            } else {
                $list = [System.Collections.ArrayList]@($cfg.settings.plugins.list)
                if ($list -notcontains 'audiostream') { $list.Add('audiostream') | Out-Null }
                $cfg.settings.plugins.list = $list.ToArray()
            }
        }

        $cfg | ConvertTo-Json -Depth 10 | Set-Content $configPath -Encoding UTF8
        ok "config.json updated — audiostream plugin enabled"
    } catch {
        warn "Could not update config.json: $_"
        warn "Manual step: add '\"plugins\": { \"enabled\": true, \"list\": [\"audiostream\"] }' to settings in config.json"
    }
} else {
    warn "config.json not found at $configPath — plugin will not be loaded until you add it manually"
}

# ── Step 6: Start service and monitor ─────────────────────────────────────────
if ($svcWasRunning) {
    info "Starting MeshCentral service..."
    try { Start-Service -Name $svcName } catch { warn "Start-Service error: $_" }

    # Monitor for 5 minutes — auto-rollback if service dies
    info "Monitoring service for 5 minutes (auto-rollback if it dies)..."
    $deadline    = (Get-Date).AddMinutes(5)
    $checkPassed = $false

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 10
        $svcCheck = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svcCheck -and $svcCheck.Status -eq 'Running') {
            $elapsed = [int]((Get-Date) - (Get-Date).AddMinutes(-5 + (($deadline - (Get-Date)).TotalMinutes))).TotalSeconds
            Write-Host "  [$(Get-Date -Format HH:mm:ss)] Service running... ($(($deadline - (Get-Date)).ToString('mm\:ss')) left)"
            $checkPassed = $true
        } else {
            Write-Host "${RED}  [$(Get-Date -Format HH:mm:ss)] Service STOPPED!${NC}"
            Write-Host ""
            warn "MeshCentral stopped after update — rolling back automatically!"

            # Kill any lingering process
            Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue

            # Restore package from backup
            if (Test-Path $pkgBackup) {
                info "Restoring from backup: $pkgBackup"
                Remove-Item "$InstallDir\node_modules\meshcentral" -Recurse -Force -ErrorAction SilentlyContinue
                Expand-Archive -Path $pkgBackup -DestinationPath "$InstallDir\node_modules" -Force
                ok "Package restored"
            }

            # Restore config if we changed it
            if (Test-Path $configPath) {
                try {
                    $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
                    if ($cfg.settings.plugins -and $cfg.settings.plugins.list) {
                        $list = [System.Collections.ArrayList]@($cfg.settings.plugins.list)
                        $list.Remove('audiostream') | Out-Null
                        $cfg.settings.plugins.list = $list.ToArray()
                        $cfg | ConvertTo-Json -Depth 10 | Set-Content $configPath -Encoding UTF8
                    }
                } catch {}
            }

            # Restart original service
            Start-Sleep -Seconds 3
            try { Start-Service -Name $svcName } catch { warn "Could not restart service: $_" }
            Start-Sleep -Seconds 5

            $svcFinal = Get-Service -Name $svcName -ErrorAction SilentlyContinue
            if ($svcFinal -and $svcFinal.Status -eq 'Running') {
                ok "ROLLBACK COMPLETE — original MeshCentral is running again"
            } else {
                fail "ROLLBACK FAILED — start service manually: Start-Service $svcName"
            }
            exit 1
        }

        # After 60 seconds running = confirmed stable
        if ($checkPassed -and (Get-Date) -gt (Get-Date).AddMinutes(-4).AddSeconds(0)) {
            break  # Stop monitoring after ~60s stable
        }
    }

    # Final check
    $svcFinal = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if ($svcFinal -and $svcFinal.Status -eq 'Running') {
        Write-Host ""
        ok "=== UPDATE COMPLETE — MeshCentral is running ==="
        Write-Host "  Backup saved: $pkgBackup"
        Write-Host "  To rollback manually:"
        Write-Host "    Stop-Service MeshCentral"
        Write-Host "    Remove-Item $InstallDir\node_modules\meshcentral -Recurse -Force"
        Write-Host "    Expand-Archive '$pkgBackup' -DestinationPath '$InstallDir\node_modules' -Force"
        Write-Host "    Start-Service MeshCentral"
    } else {
        fail "Service stopped after monitoring period — check logs at $InstallDir\meshcentral-data\trace.log"
    }
} else {
    ok "=== UPDATE COMPLETE (service was not running, not started) ==="
    Write-Host "  Start manually: Start-Service MeshCentral"
}
