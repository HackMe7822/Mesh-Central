<#
.SYNOPSIS
    Install MeshCentral UAT environment — Creations IT fork.

.DESCRIPTION
    Sets up a UAT (test) instance of MeshCentral on the same Windows server as production.
    Uses a different port and service name so both can run simultaneously.

    What it does:
      1. npm-installs the fork (dev branch by default) into UATDir
      2. Copies audiostream plugin from the npm package
      3. Creates a UAT config.json (port 4443, mpsport 0, red-banner title)
      4. Optionally copies production DB so you start with real users/devices
      5. Starts node once (90 seconds) to generate TLS certificates
      6. Installs a Windows service via NSSM (MeshCentralUAT)
      7. Optionally adds a Cloudflare tunnel ingress entry

    After install:
      - UAT runs at https://<UATHostname>  (port 4443 behind Cloudflare or direct)
      - Update UAT: .\update-meshcentral.ps1 -InstallDir <UATDir> -Branch dev
      - Deploy to production: copy changed files from UATDir\node_modules\meshcentral\
        to the production MeshCentral directory, then restart production service

.PARAMETER UATDir
    Install directory for UAT. Default: C:\MeshCentral-UAT

.PARAMETER UATHostname
    Public hostname for the UAT server (used in TLS cert + config). Default: remote-uat.creationsit.com

.PARAMETER UATPort
    HTTP(S) port for UAT. Default: 4443

.PARAMETER ProdDir
    Production MeshCentral directory. Used to copy DB. Default: C:\MeshCentral

.PARAMETER ServiceName
    Windows service name for UAT. Default: MeshCentralUAT

.PARAMETER Branch
    Git branch of HackMe7822/MeshCentral-Original to install. Default: dev

.PARAMETER NssmPath
    Path to nssm.exe. Default: C:\windows\nssm.exe

.PARAMETER SkipDB
    Skip copying production DB (start with empty database).

.PARAMETER SkipCloudflareTunnel
    Skip adding Cloudflare tunnel ingress entry.

.PARAMETER CloudflareConfigPath
    Path to cloudflared config.yml. Default: C:\cloudflared\config.yml

.PARAMETER Force
    Skip confirmation prompt.

.EXAMPLE
    .\install-uat.ps1
    .\install-uat.ps1 -Force -SkipDB
    .\install-uat.ps1 -UATDir D:\MC-UAT -UATHostname uat.example.com -Force
#>
param(
    [string]$UATDir               = 'C:\MeshCentral-UAT',
    [string]$UATHostname          = 'remote-uat.creationsit.com',
    [int]   $UATPort              = 4443,
    [int]   $UATAliasPort         = 443,
    [string]$ProdDir              = 'C:\MeshCentral',
    [string]$ServiceName          = 'MeshCentralUAT',
    [string]$Branch               = 'dev',
    [string]$NssmPath             = 'C:\windows\nssm.exe',
    [switch]$SkipDB,
    [switch]$SkipCloudflareTunnel,
    [string]$CloudflareConfigPath = 'C:\cloudflared\config.yml',
    [switch]$Force
)

function ok    { param($m) Write-Host "[OK]  $m" -ForegroundColor Green }
function info  { param($m) Write-Host "[..]  $m" }
function warn  { param($m) Write-Host "[WW]  $m" -ForegroundColor Yellow }
function abort { param($m) Write-Host "[!!]  $m" -ForegroundColor Red; exit 1 }

# ─── Resolve 8.3 short path (avoids NSSM space-in-path truncation issue) ──────
function Get-ShortPath {
    param([string]$Path)
    $fso = New-Object -ComObject Scripting.FileSystemObject
    try { return $fso.GetFile($Path).ShortPath } catch { return $Path }
}

# ─── Banner ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== MeshCentral UAT Install -- Creations IT ===" -ForegroundColor Cyan
Write-Host "  UAT dir      : $UATDir"
Write-Host "  Hostname     : $UATHostname"
Write-Host "  Port         : $UATPort"
Write-Host "  Service name : $ServiceName"
Write-Host "  Fork branch  : $Branch  (github.com/HackMe7822/MeshCentral-Original)"
Write-Host "  Copy prod DB : $(if ($SkipDB) { 'No' } else { $ProdDir })"
Write-Host ""

if (-not $Force) {
    $confirm = Read-Host "  Continue? (y/N)"
    if ($confirm -ne 'y' -and $confirm -ne 'Y') { Write-Host "Cancelled."; exit 0 }
}

# ─── Check: already installed? ────────────────────────────────────────────────
if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
    abort "$ServiceName service already exists. Run 'nssm remove $ServiceName confirm' first if you want to reinstall."
}

# ─── Check: node.js ───────────────────────────────────────────────────────────
$nodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $nodeExe) { abort "node.exe not found. Install Node.js first." }
ok "node.js found: $nodeExe"

# ─── Check: NSSM ──────────────────────────────────────────────────────────────
if (-not (Test-Path $NssmPath)) { abort "nssm.exe not found at $NssmPath. Download from nssm.cc or change -NssmPath." }
ok "NSSM found: $NssmPath"

# ─── Step 1: Create UAT directory ─────────────────────────────────────────────
info "Creating UAT directory..."
New-Item -ItemType Directory -Force $UATDir | Out-Null
ok "Directory ready: $UATDir"

# ─── Step 2: npm install fork (dev branch) ────────────────────────────────────
info "Installing fork branch '$Branch' from GitHub (this may take a few minutes)..."
Push-Location $UATDir
$npmOut  = & npm install "git+https://github.com/HackMe7822/MeshCentral-Original.git#$Branch" 2>&1
$npmExit = $LASTEXITCODE
Pop-Location

if ($npmExit -ne 0) {
    Write-Host ($npmOut | Out-String)
    abort "npm install failed (exit $npmExit)"
}
ok "npm install succeeded"

# ─── Step 3: Deploy audiostream plugin ────────────────────────────────────────
$pluginSrc  = Join-Path $UATDir "node_modules\meshcentral\plugins\audiostream"
$pluginDest = Join-Path $UATDir "meshcentral-data\plugins\audiostream"

if (Test-Path $pluginSrc) {
    info "Deploying audiostream plugin..."
    New-Item -ItemType Directory -Force (Split-Path $pluginDest) | Out-Null
    if (Test-Path $pluginDest) { Remove-Item $pluginDest -Recurse -Force }
    Copy-Item -Path $pluginSrc -Destination $pluginDest -Recurse
    ok "Plugin deployed: $pluginDest"
} else {
    warn "audiostream not in npm package — trying to copy from production..."
    $prodPlugin = Join-Path $ProdDir "meshcentral-data\plugins\audiostream"
    if (Test-Path $prodPlugin) {
        New-Item -ItemType Directory -Force (Split-Path $pluginDest) | Out-Null
        Copy-Item -Recurse -Force $prodPlugin $pluginDest
        ok "Plugin copied from production: $pluginDest"
    } else {
        warn "Could not find audiostream plugin — audio buttons will be missing."
    }
}

# ─── Step 4: Copy production DB (optional) ────────────────────────────────────
$uatDataDir = Join-Path $UATDir "meshcentral-data"
New-Item -ItemType Directory -Force $uatDataDir | Out-Null

if (-not $SkipDB) {
    $prodDbPath = Join-Path $ProdDir "meshcentral-data\meshcentral.db"
    $uatDbPath  = Join-Path $uatDataDir "meshcentral.db"
    if (Test-Path $prodDbPath) {
        info "Copying production database to UAT..."
        Copy-Item -Force $prodDbPath $uatDbPath
        ok "Database copied (users + devices from production)"
    } else {
        warn "Production DB not found at $prodDbPath — UAT will start with empty database."
    }
} else {
    info "Skipping DB copy (-SkipDB set) — UAT will have empty database"
}

# ─── Step 5: Create UAT config.json ───────────────────────────────────────────
$configPath = Join-Path $uatDataDir "config.json"

if (Test-Path $configPath) {
    warn "config.json already exists at $configPath — skipping creation (will use existing)"
} else {
    info "Creating UAT config.json..."

    # Read production managealldevicegroups list to carry over
    $prodConfig = Join-Path $ProdDir "meshcentral-data\config.json"
    $madgLine = ''
    if (Test-Path $prodConfig) {
        $prodText = Get-Content $prodConfig -Raw
        if ($prodText -match '"managealldevicegroups"\s*:\s*(\[[^\]]*\])') {
            $madgLine = "`n    `"managealldevicegroups`": $($matches[1]),"
        }
    }

    $uatConfig = @"
{
  "`$schema": "http://info.meshcentral.com/downloads/meshcentral-config-schema.json",
  "settings": {
    "cert": "$UATHostname",
    "SQLite3": true,
    "port": $UATPort,
    "aliasPort": $UATAliasPort,
    "mpsport": 0,
    "tlsOffload": "127.0.0.1",$madgLine
    "plugins": {
      "enabled": true,
      "list": ["audiostream"]
    }
  },
  "domains": {
    "": {
      "sitestyle": 3,
      "title": "Creations IT UAT",
      "title2": "Creations IT [UAT]",
      "certUrl": "https://$UATHostname/",
      "agentcustomization": {
        "displayname": "Creations IT Remote Support [UAT]",
        "description": "Creations IT UAT Remote Management Agent",
        "companyname": "Creations IT UAT",
        "servicename": "MeshAgentUAT",
        "filename": "CreationsIT-UAT-Agent",
        "image": "CreationsIT.png"
      }
    }
  }
}
"@
    [System.IO.File]::WriteAllText($configPath, $uatConfig, (New-Object System.Text.UTF8Encoding($false)))
    ok "UAT config.json created"
    warn "Review $configPath — add any extra settings from production (SMTP, agents, etc.)"
}

# ─── Step 6: First run to generate TLS certs ──────────────────────────────────
info "Running MeshCentral once (90 seconds) to generate TLS certificates..."
info "  You will see log output below — this is normal."
$nodeExeFull = (Get-Command node).Source
$firstRunProc = Start-Process -FilePath $nodeExeFull `
    -ArgumentList "node_modules\meshcentral" `
    -WorkingDirectory $UATDir `
    -PassThru -NoNewWindow
Start-Sleep -Seconds 90
if (-not $firstRunProc.HasExited) {
    $firstRunProc.Kill()
    ok "Cert generation complete — process stopped"
} else {
    warn "Process exited on its own (may have errored — check above for errors)"
}

# Check certs were created
$certDir = Join-Path $uatDataDir "meshcentral-cert-verify"
$tlsCert = Join-Path $uatDataDir "webserver-cert-public.crt"
if ((Test-Path $tlsCert) -or (Test-Path $certDir)) {
    ok "TLS certificates found"
} else {
    warn "TLS certs not found at expected path — check $uatDataDir for cert files"
    warn "If missing, run manually: cd $UATDir && node node_modules\meshcentral"
}

# ─── Step 7: Install NSSM service ─────────────────────────────────────────────
info "Installing Windows service '$ServiceName' via NSSM..."

# Use 8.3 short path to avoid space-in-path truncation (known NSSM issue)
$nodeShort = Get-ShortPath $nodeExeFull

& $NssmPath install $ServiceName $nodeShort "node_modules\meshcentral" 2>&1 | Out-Null
& $NssmPath set $ServiceName AppDirectory $UATDir 2>&1 | Out-Null
& $NssmPath set $ServiceName DisplayName "MeshCentral UAT" 2>&1 | Out-Null
& $NssmPath set $ServiceName Description "MeshCentral UAT — Creations IT fork (port $UATPort)" 2>&1 | Out-Null
& $NssmPath set $ServiceName Start SERVICE_AUTO_START 2>&1 | Out-Null
& $NssmPath set $ServiceName AppRestartDelay 5000 2>&1 | Out-Null

$svcCheck = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svcCheck) {
    ok "Service '$ServiceName' installed"
} else {
    abort "NSSM service install failed — check NSSM output above"
}

# ─── Step 8: Start the service ────────────────────────────────────────────────
info "Starting $ServiceName service..."
try {
    Start-Process powershell -Verb RunAs -ArgumentList "-Command Start-Service $ServiceName" -Wait
    Start-Sleep -Seconds 5
    $svcStatus = (Get-Service $ServiceName -ErrorAction SilentlyContinue).Status
    if ($svcStatus -eq 'Running') {
        ok "Service is Running"
    } else {
        warn "Service status: $svcStatus — may need a moment to start, or check logs in $UATDir"
    }
} catch {
    warn "Could not start service automatically (needs elevation). Run: Start-Service $ServiceName"
}

# ─── Step 9: Cloudflare tunnel ingress (optional) ─────────────────────────────
if (-not $SkipCloudflareTunnel -and (Test-Path $CloudflareConfigPath)) {
    $tunnelCfg = Get-Content $CloudflareConfigPath -Raw
    if ($tunnelCfg -match [regex]::Escape($UATHostname)) {
        ok "Cloudflare tunnel already has entry for $UATHostname"
    } else {
        info "Adding Cloudflare tunnel ingress for $UATHostname..."
        # Insert before the catch-all line
        $newIngress = "  - hostname: $UATHostname`n    service: http://127.0.0.1:$UATPort`n"
        $tunnelCfg  = $tunnelCfg -replace '(ingress:\s*\n)', "`$1$newIngress"
        [System.IO.File]::WriteAllText($CloudflareConfigPath, $tunnelCfg, (New-Object System.Text.UTF8Encoding($false)))
        ok "Cloudflare config updated: $CloudflareConfigPath"
        warn "Restart cloudflared to apply: Restart-Service cloudflared  (or restart tunnel)"
    }
} elseif (-not $SkipCloudflareTunnel) {
    warn "Cloudflare config not found at $CloudflareConfigPath"
    warn "Add manually to your tunnel config:"
    warn "  - hostname: $UATHostname"
    warn "    service: http://127.0.0.1:$UATPort"
}

# ─── Done ──────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== UAT INSTALL COMPLETE ===" -ForegroundColor Green
Write-Host ""
Write-Host "  UAT URL         : https://$UATHostname"
Write-Host "  UAT config      : $configPath"
Write-Host "  UAT service     : $ServiceName"
Write-Host "  UAT data        : $uatDataDir"
Write-Host ""
Write-Host "  Workflow:" -ForegroundColor Cyan
Write-Host "    Edit files in : $UATDir\node_modules\meshcentral\"
Write-Host "    Restart UAT   : Start-Process powershell -Verb RunAs -ArgumentList '-Command Restart-Service $ServiceName'"
Write-Host "    Update code   : .\update-meshcentral.ps1 -InstallDir $UATDir -Branch $Branch"
Write-Host "    Deploy to prod: copy changed files to $ProdDir\node_modules\meshcentral\ then restart prod service"
Write-Host ""
Write-Host "  NOTE: UAT header/sidebar will be RED (visual indicator)." -ForegroundColor Yellow
Write-Host "  When deploying to production, strip the UAT red-banner CSS from default3.handlebars." -ForegroundColor Yellow
Write-Host ""
