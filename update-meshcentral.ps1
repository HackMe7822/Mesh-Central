<#
.SYNOPSIS
    Safe MeshCentral update with automatic rollback.
    Creations IT -- updates to HackMe7822/MeshCentral-Original fork.

.DESCRIPTION
    1. Backs up current node_modules\meshcentral to a zip
    2. Backs up meshcentral-data
    3. npm-installs new fork version
    4. Copies audiostream plugin to meshcentral-data\plugins\
    5. Enables plugin in config.json
    6. Restarts MeshCentral (service or node process)
    7. Monitors for 5 min -- auto-rollbacks if MeshCentral dies

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

function ok   { param($m) Write-Host "[OK]  $m" }
function info { param($m) Write-Host "[..]  $m" }
function warn { param($m) Write-Host "[WW]  $m" }
function abort { param($m) Write-Host "[!!]  $m"; exit 1 }

# --- Validate install dir ---
if (-not (Test-Path "$InstallDir\node_modules\meshcentral")) {
    abort "MeshCentral not found at $InstallDir\node_modules\meshcentral"
}

Write-Host ""
Write-Host "=== MeshCentral Safe Update -- Creations IT ==="
Write-Host "  Install dir : $InstallDir"
Write-Host "  Fork        : github.com/HackMe7822/MeshCentral-Original"
Write-Host ""

if (-not $Force) {
    $confirm = Read-Host "  Continue? (y/N)"
    if ($confirm -ne 'y' -and $confirm -ne 'Y') { Write-Host "Cancelled."; exit 0 }
}

# --- Detect how MeshCentral is running ---
$svc = Get-Service -Name "MeshCentral" -ErrorAction SilentlyContinue
$useService = ($svc -ne $null)
$nodePid = $null

if (-not $useService) {
    # Find the node.exe process running meshcentral
    $nodeProcs = Get-WmiObject Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue
    foreach ($p in $nodeProcs) {
        if ($p.CommandLine -like "*meshcentral*") {
            $nodePid = $p.ProcessId
            break
        }
    }
    if ($nodePid) {
        info "MeshCentral running as node process PID $nodePid (no Windows service)"
    } else {
        info "MeshCentral not currently running (will just update files)"
    }
}

# --- Step 1: Backup ---
$date = Get-Date -Format "yyyy-MM-dd_HH-mm"
$backDir = Join-Path $InstallDir "meshcentral-backups"
New-Item -ItemType Directory -Force $backDir | Out-Null

$pkgBackup  = Join-Path $backDir "meshcentral-pkg-$date.zip"
$dataBackup = Join-Path $backDir "meshcentral-data-$date.zip"

info "Backing up MeshCentral package..."
$backupOk = $false
try {
    Compress-Archive -Path "$InstallDir\node_modules\meshcentral" `
                     -DestinationPath $pkgBackup -CompressionLevel Fastest
    ok "Package backup: $pkgBackup"
    $backupOk = $true
} catch {
    warn "Package backup failed: $_"
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

# --- Step 2: Stop MeshCentral ---
$wasRunning = $false

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

# --- Step 3: npm install from fork ---
info "Installing updated fork from GitHub..."
Set-Location $InstallDir

$npmOut = & npm install "git+https://github.com/HackMe7822/MeshCentral-Original.git" 2>&1
$npmExit = $LASTEXITCODE

if ($npmExit -ne 0) {
    Write-Host $npmOut
    warn "npm install failed (exit $npmExit) -- rolling back..."
    if ($backupOk -and (Test-Path $pkgBackup)) {
        Remove-Item "$InstallDir\node_modules\meshcentral" -Recurse -Force -ErrorAction SilentlyContinue
        Expand-Archive -Path $pkgBackup -DestinationPath "$InstallDir\node_modules" -Force
        ok "Rollback complete"
    }
    if ($wasRunning) {
        if ($useService) {
            Start-Service -Name "MeshCentral" -ErrorAction SilentlyContinue
        }
    }
    abort "Update aborted -- original version restored"
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
    warn "audiostream plugin not found in package -- skipping"
}

# --- Step 5: Enable plugin in config.json ---
$configPath = Join-Path $InstallDir "meshcentral-data\config.json"
if (Test-Path $configPath) {
    info "Enabling audiostream plugin in config.json..."
    try {
        $rawJson = Get-Content $configPath -Raw -Encoding UTF8
        $cfg = $rawJson | ConvertFrom-Json

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
        warn "Could not update config.json: $_"
        warn "Manual step: add `"plugins`": { `"enabled`": true, `"list`": [`"audiostream`"] } under settings in config.json"
    }
} else {
    warn "config.json not found at $configPath"
}

# --- Step 6: Start MeshCentral ---
if ($wasRunning) {
    if ($useService) {
        info "Starting MeshCentral service..."
        try { Start-Service -Name "MeshCentral" } catch { warn "Start-Service error: $_" }
    } else {
        info "Starting MeshCentral via node..."
        $nodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
        if ($nodeExe) {
            $startArgs = @{
                FilePath         = $nodeExe
                ArgumentList     = "node_modules\meshcentral"
                WorkingDirectory = $InstallDir
                WindowStyle      = 'Minimized'
                PassThru         = $true
            }
            $newProc = Start-Process @startArgs
            $nodePid = $newProc.Id
            info "Started node PID: $nodePid"
        } else {
            warn "node.exe not found in PATH -- start MeshCentral manually: node node_modules\meshcentral"
        }
    }
} else {
    ok "MeshCentral was not running -- files updated, start it manually when ready"
    Write-Host ""
    Write-Host "=== UPDATE COMPLETE (not started) ==="
    Write-Host "  Backup: $pkgBackup"
    exit 0
}

# --- Step 7: Monitor for 5 minutes ---
info "Monitoring for 5 minutes -- will auto-rollback if MeshCentral crashes..."
$deadline   = (Get-Date).AddMinutes(5)
$stableAt   = $null
$rolledBack = $false

while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 10

    $running = $false
    if ($useService) {
        $chk = Get-Service -Name "MeshCentral" -ErrorAction SilentlyContinue
        $running = ($chk -and $chk.Status -eq 'Running')
    } elseif ($nodePid) {
        $chk = Get-Process -Id $nodePid -ErrorAction SilentlyContinue
        $running = ($chk -ne $null)
    } else {
        $running = $true  # Can't check, assume OK
    }

    $remaining = [int]($deadline - (Get-Date)).TotalSeconds
    if ($running) {
        Write-Host "  [$(Get-Date -Format HH:mm:ss)] Running OK  (${remaining}s left)"
        if ($null -eq $stableAt) { $stableAt = Get-Date }
        # 60 seconds stable = done monitoring
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

        # Remove plugin from config
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
            ok "ROLLBACK COMPLETE -- restart MeshCentral manually: cd $InstallDir && node node_modules\meshcentral"
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
