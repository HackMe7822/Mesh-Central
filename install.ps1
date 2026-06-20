#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Creations IT - MeshCentral One-Click Deployer
.DESCRIPTION
    Installs Node.js, MeshCentral (branded as "Creations IT"), configures it as a
    Windows service, sets up Windows Firewall, and wires up a fresh Cloudflare Tunnel
    to mesh.creationsit.com.

    Run as Administrator in PowerShell on the target VM:
        iwr -useb https://raw.githubusercontent.com/HackMe7822/Mesh-Central/main/install.ps1 | iex

    Re-run flags:
        -SkipCloudflare     Skip Cloudflare tunnel setup (already configured)
        -SkipNodeInstall    Skip Node.js install (already installed)
        -UpdateOnly         Only refresh config.json + branding, restart service — no reinstall
        -InstallDir         Override install path (default: C:\MeshCentral)
                            Example for existing installs:
                            .\install.ps1 -UpdateOnly -InstallDir "C:\Program Files\Open Source\MeshCentral"
#>

param(
    [string]$AdminUser  = "",
    [string]$AdminEmail = "",
    [string]$InstallDir = "",
    [switch]$SkipCloudflare,
    [switch]$SkipNodeInstall,
    [switch]$UpdateOnly
)

$ErrorActionPreference = "Stop"

# ──────────────────────────────────────────────────────────────
#  CONFIGURATION
# ──────────────────────────────────────────────────────────────
$INSTALL_DIR   = if ($InstallDir) { $InstallDir } else { "C:\MeshCentral" }
$DATA_DIR      = "$INSTALL_DIR\meshcentral-data"
$PUBLIC_DIR    = "$DATA_DIR\public"
$CF_CONFIG_DIR = "C:\cloudflared"
$TUNNEL_NAME   = "meshcentral"
$DOMAIN        = "mesh.creationsit.com"
$BRAND_NAME    = "Creations IT"
$BRAND_TITLE2  = "Remote Support"
$LOGO_FILE     = "CreationsIT.ico"
$LOGO_RAW_URL  = "https://raw.githubusercontent.com/HackMe7822/Mesh-Central/main/CreationsIT.ico"
# ──────────────────────────────────────────────────────────────

function Write-Banner {
    Write-Host ""
    Write-Host "  ============================================" -ForegroundColor Blue
    Write-Host "    Creations IT  -  MeshCentral Deployer" -ForegroundColor Blue
    Write-Host "    Target : $DOMAIN" -ForegroundColor Blue
    Write-Host "  ============================================" -ForegroundColor Blue
    Write-Host ""
}
function Write-Step([int]$n, [string]$text) { Write-Host "`n  [$n] $text" -ForegroundColor Cyan }
function Write-OK([string]$t)   { Write-Host "      OK  $t" -ForegroundColor Green }
function Write-Info([string]$t) { Write-Host "      --> $t" -ForegroundColor Yellow }
function Write-Fail([string]$t) { Write-Host "      ERR $t" -ForegroundColor Red; exit 1 }

Write-Banner

$isPrincipal = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $isPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Fail "Must run as Administrator."
}

# Resolve script directory (works both from file and from iex pipe)
if ($PSScriptRoot) { $ScriptDir = $PSScriptRoot } else { $ScriptDir = $PWD.Path }

# ──────────────────────────────────────────────────────────────
#  -UpdateOnly : refresh config + branding only, then exit
# ──────────────────────────────────────────────────────────────
if ($UpdateOnly) {
    Write-Host "  [UPDATE ONLY MODE]" -ForegroundColor Magenta

    Write-Step 1 "Refreshing branding logo"
    New-Item -ItemType Directory -Force -Path $PUBLIC_DIR | Out-Null
    $logoSrc = Join-Path $ScriptDir $LOGO_FILE
    if (Test-Path $logoSrc) {
        Copy-Item $logoSrc "$PUBLIC_DIR\$LOGO_FILE" -Force
        Write-OK "Copied $LOGO_FILE from script directory"
    } else {
        Write-Info "Downloading $LOGO_FILE from GitHub..."
        Invoke-WebRequest -Uri $LOGO_RAW_URL -OutFile "$PUBLIC_DIR\$LOGO_FILE" -UseBasicParsing
        Write-OK "Downloaded $LOGO_FILE"
    }

    Write-Step 2 "Refreshing config.json"
    # (config written below — fall through to write block, then restart)
    $iconFilePath = ($DATA_DIR + "\public\" + $LOGO_FILE) -replace '\\', '\\\\'
    $configJson = @"
{
  "settings": {
    "cert": "$DOMAIN",
    "minify": true,
    "port": 443,
    "redirPort": 80,
    "agentCustomization": {
      "displayName": "$BRAND_NAME Remote Support",
      "description": "$BRAND_NAME Remote Management Agent",
      "companyName": "$BRAND_NAME",
      "fileName": "CreationsIT-Agent",
      "iconFile": "$iconFilePath"
    }
  },
  "domains": {
    "": {
      "title": "$BRAND_NAME",
      "title2": "$BRAND_TITLE2",
      "titlePicture": "$LOGO_FILE",
      "footer": "$BRAND_NAME - Remote Support",
      "newAccounts": false
    }
  }
}
"@
    $configJson | Out-File -FilePath "$DATA_DIR\config.json" -Encoding utf8
    Write-OK "config.json updated"

    Write-Step 3 "Restarting MeshCentral service"
    Restart-Service MeshCentral -Force -ErrorAction SilentlyContinue
    Start-Sleep 5
    $s = Get-Service MeshCentral -ErrorAction SilentlyContinue
    if ($s -and $s.Status -eq "Running") { Write-OK "MeshCentral restarted" }
    else { Write-Info "Check: sc query MeshCentral" }

    Write-Host ""
    Write-Host "  Update complete. Hard-refresh the browser (Ctrl+Shift+R) to see changes." -ForegroundColor Green
    Write-Host "  Agent branding applies to newly downloaded agents from https://$DOMAIN" -ForegroundColor Green
    Write-Host ""
    exit 0
}

# ──────────────────────────────────────────────────────────────
#  STEP 1 : Node.js
# ──────────────────────────────────────────────────────────────
Write-Step 1 "Node.js LTS"

$nodeOk = $false
try {
    $nodeVer = (node --version 2>$null)
    if ($nodeVer -match "^v(\d+)") { if ([int]$Matches[1] -ge 18) { $nodeOk = $true } }
} catch {}

if ($nodeOk) {
    Write-OK "Node.js $nodeVer already installed"
} elseif ($SkipNodeInstall) {
    Write-Fail "Node.js 18+ not found and -SkipNodeInstall was set."
} else {
    Write-Info "Installing Node.js LTS via winget..."
    winget install OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements --silent
    if ($LASTEXITCODE -ne 0) { Write-Fail "winget Node.js install failed." }
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    $nodeVer = (node --version 2>$null)
    Write-OK "Node.js $nodeVer installed"
}

# ──────────────────────────────────────────────────────────────
#  STEP 2 : Directories
# ──────────────────────────────────────────────────────────────
Write-Step 2 "Creating directories"
New-Item -ItemType Directory -Force -Path $INSTALL_DIR | Out-Null
New-Item -ItemType Directory -Force -Path $DATA_DIR    | Out-Null
New-Item -ItemType Directory -Force -Path $PUBLIC_DIR  | Out-Null
Write-OK "Directories ready under $INSTALL_DIR"

# ──────────────────────────────────────────────────────────────
#  STEP 3 : Install MeshCentral
# ──────────────────────────────────────────────────────────────
Write-Step 3 "Installing MeshCentral"
Set-Location $INSTALL_DIR
if (Test-Path "$INSTALL_DIR\node_modules\meshcentral") {
    Write-OK "MeshCentral already installed"
} else {
    Write-Info "Running npm install meshcentral (1-3 min)..."
    npm install meshcentral
    if ($LASTEXITCODE -ne 0) { Write-Fail "npm install meshcentral failed." }
    Write-OK "MeshCentral installed"
}

# ──────────────────────────────────────────────────────────────
#  STEP 4 : Branding logo
# ──────────────────────────────────────────────────────────────
Write-Step 4 "Branding logo ($LOGO_FILE)"
$logoSrc = Join-Path $ScriptDir $LOGO_FILE
if (Test-Path $logoSrc) {
    Copy-Item $logoSrc "$PUBLIC_DIR\$LOGO_FILE" -Force
    Write-OK "Copied $LOGO_FILE from script directory"
} else {
    Write-Info "Downloading $LOGO_FILE from GitHub..."
    Invoke-WebRequest -Uri $LOGO_RAW_URL -OutFile "$PUBLIC_DIR\$LOGO_FILE" -UseBasicParsing
    Write-OK "Downloaded $LOGO_FILE to $PUBLIC_DIR\"
}

# ──────────────────────────────────────────────────────────────
#  STEP 5 : config.json
#
#  IMPORTANT: agentCustomization MUST live in "settings" (not "domains")
#  for MeshCentral to patch the agent binary with the custom icon + title.
# ──────────────────────────────────────────────────────────────
Write-Step 5 "Writing config.json"
$iconFilePath = ($DATA_DIR + "\public\" + $LOGO_FILE) -replace '\\', '\\\\'

$configJson = @"
{
  "settings": {
    "cert": "$DOMAIN",
    "minify": true,
    "port": 443,
    "redirPort": 80,
    "agentCustomization": {
      "displayName": "$BRAND_NAME Remote Support",
      "description": "$BRAND_NAME Remote Management Agent",
      "companyName": "$BRAND_NAME",
      "fileName": "CreationsIT-Agent",
      "iconFile": "$iconFilePath"
    }
  },
  "domains": {
    "": {
      "title": "$BRAND_NAME",
      "title2": "$BRAND_TITLE2",
      "titlePicture": "$LOGO_FILE",
      "footer": "$BRAND_NAME - Remote Support",
      "newAccounts": false
    }
  }
}
"@
$configJson | Out-File -FilePath "$DATA_DIR\config.json" -Encoding utf8
Write-OK "config.json written to $DATA_DIR\config.json"

# ──────────────────────────────────────────────────────────────
#  STEP 6 : Admin account
# ──────────────────────────────────────────────────────────────
Write-Step 6 "Creating admin account"
if (-not $AdminUser)  { $AdminUser  = Read-Host "      Enter admin username" }
if (-not $AdminEmail) { $AdminEmail = Read-Host "      Enter admin email" }
$AdminPassSS = Read-Host "      Enter admin password" -AsSecureString
$bstr        = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($AdminPassSS)
$AdminPass   = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

Set-Location $INSTALL_DIR
node node_modules\meshcentral --createaccount $AdminUser --pass $AdminPass --email $AdminEmail --adminaccount true 2>&1 | Out-Null
Write-OK "Admin account '$AdminUser' created"

# ──────────────────────────────────────────────────────────────
#  STEP 7 : Windows service
# ──────────────────────────────────────────────────────────────
Write-Step 7 "Installing MeshCentral Windows service"
Set-Location $INSTALL_DIR

$existingSvc = Get-Service MeshCentral -ErrorAction SilentlyContinue
if ($existingSvc) {
    Write-Info "Removing existing service..."
    node node_modules\meshcentral --stop      2>&1 | Out-Null; Start-Sleep 3
    node node_modules\meshcentral --uninstall 2>&1 | Out-Null; Start-Sleep 2
}

node node_modules\meshcentral --install
Start-Sleep 2
node node_modules\meshcentral --start
Start-Sleep 8

$svc = Get-Service MeshCentral -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq "Running") { Write-OK "MeshCentral service is RUNNING" }
else { Write-Info "Service starting — check: sc query MeshCentral" }

# ──────────────────────────────────────────────────────────────
#  STEP 8 : Firewall
# ──────────────────────────────────────────────────────────────
Write-Step 8 "Windows Firewall"
netsh advfirewall firewall delete rule name="MeshCentral HTTPS" 2>$null | Out-Null
netsh advfirewall firewall delete rule name="MeshCentral HTTP"  2>$null | Out-Null
netsh advfirewall firewall add rule name="MeshCentral HTTPS" dir=in action=allow protocol=TCP localport=443 | Out-Null
netsh advfirewall firewall add rule name="MeshCentral HTTP"  dir=in action=allow protocol=TCP localport=80  | Out-Null
Write-OK "Firewall rules added (TCP 443 + 80)"

# ──────────────────────────────────────────────────────────────
#  STEPS 9-13 : Cloudflare Tunnel
# ──────────────────────────────────────────────────────────────
if (-not $SkipCloudflare) {

    Write-Step 9 "Installing cloudflared"
    $cfCmd = Get-Command cloudflared -ErrorAction SilentlyContinue
    if (-not $cfCmd) {
        Write-Info "Installing cloudflared via winget..."
        winget install Cloudflare.cloudflared --accept-source-agreements --accept-package-agreements --silent
        if ($LASTEXITCODE -ne 0) { Write-Fail "winget cloudflared install failed." }
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    }
    Write-OK "cloudflared ready  ($( (cloudflared --version 2>&1 | Select-Object -First 1) ))"

    Write-Step 10 "Cloudflare authentication"
    Write-Info "A browser window will open. Log in and select creationsit.com"
    Read-Host "      Press ENTER to open the browser"
    cloudflared tunnel login
    if ($LASTEXITCODE -ne 0) { Write-Fail "Cloudflare login failed." }
    Write-OK "Authenticated"

    Write-Step 11 "Cloudflare Tunnel ($TUNNEL_NAME)"
    New-Item -ItemType Directory -Force -Path $CF_CONFIG_DIR | Out-Null

    cloudflared tunnel info $TUNNEL_NAME 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Info "Deleting old tunnel '$TUNNEL_NAME'..."
        cloudflared tunnel delete $TUNNEL_NAME --force 2>&1 | Out-Null
        Start-Sleep 2
    }

    $createOut = (cloudflared tunnel create $TUNNEL_NAME 2>&1) -join " "
    if ($LASTEXITCODE -ne 0) { Write-Fail "tunnel create failed: $createOut" }

    $tunnelId = ""
    if ($createOut -match "([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})") {
        $tunnelId = $Matches[1]
    }
    if (-not $tunnelId) { Write-Fail "Could not extract Tunnel ID from: $createOut" }
    Write-OK "Tunnel created: $TUNNEL_NAME  ($tunnelId)"

    Write-Step 12 "DNS record ($DOMAIN)"
    cloudflared tunnel route dns $TUNNEL_NAME $DOMAIN
    if ($LASTEXITCODE -ne 0) { Write-Fail "DNS record creation failed." }
    Write-OK "DNS: $DOMAIN -> $TUNNEL_NAME"

    Write-Step 13 "Cloudflare tunnel config + service"
    $credFile = ($env:USERPROFILE + "\.cloudflared\" + $tunnelId + ".json") -replace '\\', '\\'
    $cfYml = @"
tunnel: $tunnelId
credentials-file: $credFile

ingress:
  - hostname: $DOMAIN
    service: https://localhost:443
    originRequest:
      noTLSVerify: true
  - service: http_status:404
"@
    $cfYml | Out-File -FilePath "$CF_CONFIG_DIR\config.yml" -Encoding utf8

    cloudflared --config "$CF_CONFIG_DIR\config.yml" service install
    if ($LASTEXITCODE -ne 0) { Write-Fail "cloudflared service install failed." }
    Start-Service cloudflared -ErrorAction SilentlyContinue
    Start-Sleep 3

    $cfSvc = Get-Service cloudflared -ErrorAction SilentlyContinue
    if ($cfSvc -and $cfSvc.Status -eq "Running") { Write-OK "Cloudflare tunnel service RUNNING" }
    else { Write-Info "Check: sc query cloudflared" }

} else {
    Write-Info "Skipping Cloudflare setup (-SkipCloudflare)"
}

# ──────────────────────────────────────────────────────────────
#  DONE
# ──────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  ============================================" -ForegroundColor Green
Write-Host "    DEPLOYMENT COMPLETE" -ForegroundColor Green
Write-Host "  ============================================" -ForegroundColor Green
Write-Host ""
Write-Host "    URL    : https://$DOMAIN" -ForegroundColor Cyan
Write-Host "    Admin  : $AdminUser" -ForegroundColor Cyan
Write-Host "    Data   : $DATA_DIR" -ForegroundColor Gray
Write-Host ""
Write-Host "    Next steps:" -ForegroundColor Yellow
Write-Host "      1. Open https://$DOMAIN and confirm Creations IT login page" -ForegroundColor White
Write-Host "      2. My Account > Two Factor Authentication" -ForegroundColor White
Write-Host "      3. Create device groups: Servers / Workstations / Clients" -ForegroundColor White
Write-Host "      4. Devices > Add Agent > Windows — verify agent shows Creations IT branding" -ForegroundColor White
Write-Host "      5. Back up $DATA_DIR regularly" -ForegroundColor White
Write-Host ""
Write-Host "    To update branding only (no reinstall):" -ForegroundColor Yellow
Write-Host "      .\install.ps1 -UpdateOnly" -ForegroundColor Gray
Write-Host ""
