<#
.SYNOPSIS
    Safe MeshCentral install/update with automatic rollback.
    Creations IT -- installs/upgrades to HackMe7822/MeshCentral-Original fork.

.DESCRIPTION
    Works for both fresh installs and in-place upgrades.

    Fresh install (no prior MeshCentral):
      1. npm-installs the fork
      2. Copies audiostream plugin to meshcentral-data\plugins\
      3. Creates a starter config.json with the plugin enabled
      (You still need to set hostname/cert/domain in config.json before first run.)

    Upgrade (existing MeshCentral):
      1. Backs up current node_modules\meshcentral and meshcentral-data
      2. Stops MeshCentral
      3. npm-installs updated fork
      4. Copies audiostream plugin to meshcentral-data\plugins\
      5. Patches config.json to enable the plugin
      6. Restarts MeshCentral
      7. Monitors for 5 min and auto-rollbacks if MeshCentral crashes

.PARAMETER InstallDir
    MeshCentral install directory. Default: C:\MeshCentral

.PARAMETER Force
    Skip confirmation prompt.

.EXAMPLE
    .\update-meshcentral.ps1                          # upgrade existing
    .\update-meshcentral.ps1 -Force                   # upgrade, no prompt
    .\update-meshcentral.ps1 -InstallDir D:\MC -Force # fresh install to D:\MC
#>
param(
    [string]$InstallDir = 'C:\MeshCentral',
    [switch]$Force
)

function ok    { param($m) Write-Host "[OK]  $m" }
function info  { param($m) Write-Host "[..]  $m" }
function warn  { param($m) Write-Host "[WW]  $m" }
function abort { param($m) Write-Host "[!!]  $m"; exit 1 }

# --- Detect fresh vs upgrade ---
$isFresh = -not (Test-Path "$InstallDir\node_modules\meshcentral")

Write-Host ""
if ($isFresh) {
    Write-Host "=== MeshCentral Fresh Install -- Creations IT ==="
} else {
    Write-Host "=== MeshCentral Safe Update -- Creations IT ==="
}
Write-Host "  Install dir : $InstallDir"
Write-Host "  Fork        : github.com/HackMe7822/MeshCentral-Original"
Write-Host "  Mode        : $(if ($isFresh) { 'FRESH INSTALL' } else { 'UPGRADE' })"
Write-Host ""

if (-not $Force) {
    $confirm = Read-Host "  Continue? (y/N)"
    if ($confirm -ne 'y' -and $confirm -ne 'Y') { Write-Host "Cancelled."; exit 0 }
}

# Ensure install dir exists
New-Item -ItemType Directory -Force $InstallDir | Out-Null

# --- Detect how MeshCentral is running (upgrade only) ---
$svc        = Get-Service -Name "MeshCentral" -ErrorAction SilentlyContinue
$useService = ($null -ne $svc)
$nodePid    = $null
$wasRunning = $false

if (-not $isFresh) {
    if (-not $useService) {
        $nodeProcs = Get-WmiObject Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue
        foreach ($p in $nodeProcs) {
            if ($p.CommandLine -like "*meshcentral*") { $nodePid = $p.ProcessId; break }
        }
        if ($nodePid) {
            info "MeshCentral running as node process PID $nodePid (no Windows service)"
        } else {
            info "MeshCentral not currently running"
        }
    }
}

# --- Step 1: Backup (upgrade only) ---
$backupOk = $false
$pkgBackup = $null

if (-not $isFresh) {
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
        $backupOk = $true
    } catch {
        warn "Package backup failed (non-fatal): $_"
    }

    info "Backing up meshcentral-data..."
    try {
        $dataPath = Join-Path $InstallDir "meshcentral-data"
        if (Test-Path $dataPath) {
            Compress-Archive -Path $dataPath -DestinationPath $dataBackup -CompressionLevel Fastest
            ok "Data backup: $dataBackup"
        }
    } catch {
        warn "Data backup failed (non-fatal): $_"
    }
}

# --- Step 2: Stop MeshCentral (upgrade only) ---
if (-not $isFresh) {
    if ($useService -and $svc.Status -eq 'Running') {
        $wasRunning = $true
        info "Stopping MeshCentral service..."
        Stop-Service -Name "MeshCentral" -Force
        Start-Sleep -Seconds 4
        ok "Service stopped"
    } elseif ($nodePid) {
        $wasRunning = $true
        info "Stopping MeshCentral node process (PID $nodePid)..."
        Stop-Process -Id $nodePid -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
        ok "Node process stopped"
    }
}

# --- Step 3: npm install from fork ---
info "Installing fork from GitHub..."
Set-Location $InstallDir

$npmOut  = & npm install "git+https://github.com/HackMe7822/MeshCentral-Original.git" 2>&1
$npmExit = $LASTEXITCODE

if ($npmExit -ne 0) {
    Write-Host $npmOut
    warn "npm install failed (exit $npmExit)"
    if (-not $isFresh -and $backupOk -and (Test-Path $pkgBackup)) {
        warn "Rolling back..."
        Remove-Item "$InstallDir\node_modules\meshcentral" -Recurse -Force -ErrorAction SilentlyContinue
        Expand-Archive -Path $pkgBackup -DestinationPath "$InstallDir\node_modules" -Force
        ok "Rollback complete"
        if ($wasRunning -and $useService) { Start-Service -Name "MeshCentral" -ErrorAction SilentlyContinue }
    }
    abort "Install aborted"
}
ok "npm install succeeded"

# --- Step 4: Deploy audiostream plugin ---
$pluginSrc  = Join-Path $InstallDir "node_modules\meshcentral\plugins\audiostream"
$pluginDest = Join-Path $InstallDir "meshcentral-data\plugins\audiostream"

if (Test-Path $pluginSrc) {
    info "Deploying audiostream plugin..."
    New-Item -ItemType Directory -Force (Split-Path $pluginDest) | Out-Null
    if (Test-Path $pluginDest) { Remove-Item $pluginDest -Recurse -Force }
    Copy-Item -Path $pluginSrc -Destination $pluginDest -Recurse
    ok "Plugin deployed to: $pluginDest"
} else {
    warn "audiostream plugin not found in npm package -- skipping"
}

# --- Step 5: Enable plugin in config.json ---
$configPath = Join-Path $InstallDir "meshcentral-data\config.json"

if (Test-Path $configPath) {
    # --- Patch existing config ---
    info "Enabling audiostream plugin in config.json..."
    try {
        $rawJson = Get-Content $configPath -Raw -Encoding UTF8
        $cfg     = $rawJson | ConvertFrom-Json

        if ($null -eq $cfg.settings.plugins) {
            $pluginsObj = New-Object PSObject -Property @{ enabled = $true; list = @('audiostream') }
            $cfg.settings | Add-Member -NotePropertyName 'plugins' -NotePropertyValue $pluginsObj -Force
        } else {
            $cfg.settings.plugins | Add-Member -NotePropertyName 'enabled' -NotePropertyValue $true -Force
            if ($null -eq $cfg.settings.plugins.list) {
                $cfg.settings.plugins | Add-Member -NotePropertyName 'list' -NotePropertyValue @('audiostream') -Force
            } else {
                $list = [System.Collections.ArrayList]@($cfg.settings.plugins.list)
                if ($list -notcontains 'audiostream') { [void]$list.Add('audiostream') }
                $cfg.settings.plugins.list = $list.ToArray()
            }
        }

        $cfg | ConvertTo-Json -Depth 10 | Out-File $configPath -Encoding UTF8
        ok "config.json updated -- audiostream enabled"
    } catch {
        warn "Could not patch config.json: $_"
        warn 'Manual step: add "plugins": { "enabled": true, "list": ["audiostream"] } under settings'
    }
} else {
    # --- Create starter config for fresh install ---
    info "Creating starter config.json with plugin enabled..."
    New-Item -ItemType Directory -Force (Split-Path $configPath) | Out-Null
    $starterConfig = @'
{
  "$schema": "http://info.meshcentral.com/downloads/meshcentral-config-schema.json",
  "settings": {
    "plugins": {
      "enabled": true,
      "list": ["audiostream"]
    }
  },
  "domains": {
    "": {
      "title": "Creations IT",
      "title2": "Remote Management"
    }
  }
}
'@
    $starterConfig | Out-File $configPath -Encoding UTF8
    ok "Starter config.json created at: $configPath"
    warn "ACTION REQUIRED: Edit config.json to set hostname, TLS cert, and other settings before starting MeshCentral."
}

# --- Step 6: Start MeshCentral ---
if ($isFresh) {
    Write-Host ""
    ok "=== FRESH INSTALL COMPLETE ==="
    Write-Host ""
    Write-Host "  Next steps:"
    Write-Host "  1. Edit config.json to set your hostname and other settings:"
    Write-Host "       $configPath"
    Write-Host "  2. Install as a Windows service:"
    Write-Host "       cd $InstallDir"
    Write-Host "       node node_modules\meshcentral --install"
    Write-Host "  3. Or start manually:"
    Write-Host "       cd $InstallDir"
    Write-Host "       node node_modules\meshcentral"
    Write-Host ""
    Write-Host "  The audiostream (audio monitoring) plugin is pre-configured."
    exit 0
}

if ($wasRunning) {
    if ($useService) {
        info "Starting MeshCentral service..."
        try { Start-Service -Name "MeshCentral" } catch { warn "Start-Service error: $_" }
    } else {
        info "Starting MeshCentral via node..."
        $nodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
        if ($nodeExe) {
            $newProc = Start-Process -FilePath $nodeExe `
                                     -ArgumentList "node_modules\meshcentral" `
                                     -WorkingDirectory $InstallDir `
                                     -WindowStyle Minimized -PassThru
            $nodePid = $newProc.Id
            info "Started node PID: $nodePid"
        } else {
            warn "node.exe not found -- start manually: cd $InstallDir && node node_modules\meshcentral"
        }
    }
} else {
    ok "MeshCentral was not running -- files updated, start manually when ready"
    Write-Host ""
    Write-Host "=== UPDATE COMPLETE (not started) ==="
    Write-Host "  Backup: $pkgBackup"
    exit 0
}

# --- Step 7: Monitor for 5 minutes (upgrade only) ---
info "Monitoring for 5 minutes -- will auto-rollback if MeshCentral crashes..."
$deadline   = (Get-Date).AddMinutes(5)
$stableAt   = $null
$rolledBack = $false

while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 10

    $running = $false
    if ($useService) {
        $chk     = Get-Service -Name "MeshCentral" -ErrorAction SilentlyContinue
        $running = ($chk -and $chk.Status -eq 'Running')
    } elseif ($nodePid) {
        $chk     = Get-Process -Id $nodePid -ErrorAction SilentlyContinue
        $running = ($null -ne $chk)
    } else {
        $running = $true
    }

    $remaining = [int]($deadline - (Get-Date)).TotalSeconds
    if ($running) {
        Write-Host "  [$(Get-Date -Format HH:mm:ss)] Running OK  (${remaining}s left)"
        if ($null -eq $stableAt) { $stableAt = Get-Date }
        if (((Get-Date) - $stableAt).TotalSeconds -ge 60) { break }
    } else {
        Write-Host "  [$(Get-Date -Format HH:mm:ss)] STOPPED -- rolling back!"
        $rolledBack = $true

        if ($useService) { Stop-Service "MeshCentral" -Force -ErrorAction SilentlyContinue }

        if ($backupOk -and (Test-Path $pkgBackup)) {
            info "Restoring package from backup..."
            Remove-Item "$InstallDir\node_modules\meshcentral" -Recurse -Force -ErrorAction SilentlyContinue
            Expand-Archive -Path $pkgBackup -DestinationPath "$InstallDir\node_modules" -Force
            ok "Package restored"
        }

        try {
            $cfg = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($cfg.settings.plugins -and $cfg.settings.plugins.list) {
                $list = [System.Collections.ArrayList]@($cfg.settings.plugins.list)
                [void]$list.Remove('audiostream')
                $cfg.settings.plugins.list = $list.ToArray()
                $cfg | ConvertTo-Json -Depth 10 | Out-File $configPath -Encoding UTF8
            }
        } catch {}

        Start-Sleep -Seconds 3
        if ($useService) {
            try { Start-Service "MeshCentral" } catch {}
            Start-Sleep -Seconds 6
            $final = Get-Service "MeshCentral" -ErrorAction SilentlyContinue
            if ($final -and $final.Status -eq 'Running') {
                ok "ROLLBACK COMPLETE -- original MeshCentral is running"
            } else {
                warn "ROLLBACK COMPLETE -- service may need manual start: Start-Service MeshCentral"
            }
        } else {
            ok "ROLLBACK COMPLETE -- restart manually: cd $InstallDir && node node_modules\meshcentral"
        }
        break
    }
}

if (-not $rolledBack) {
    Write-Host ""
    ok "=== UPDATE COMPLETE -- MeshCentral is running ==="
    Write-Host "  Backup at: $pkgBackup"
    Write-Host ""
    Write-Host "  Manual rollback if needed:"
    if ($useService) {
        Write-Host "    Stop-Service MeshCentral"
        Write-Host "    Remove-Item $InstallDir\node_modules\meshcentral -Recurse -Force"
        Write-Host "    Expand-Archive '$pkgBackup' -DestinationPath '$InstallDir\node_modules'"
        Write-Host "    Start-Service MeshCentral"
    } else {
        Write-Host "    Stop the node process"
        Write-Host "    Remove-Item $InstallDir\node_modules\meshcentral -Recurse -Force"
        Write-Host "    Expand-Archive '$pkgBackup' -DestinationPath '$InstallDir\node_modules'"
        Write-Host "    cd $InstallDir && node node_modules\meshcentral"
    }
}
