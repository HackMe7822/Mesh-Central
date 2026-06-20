#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Creations IT - MeshCentral One-Click Deployer
.DESCRIPTION
    Installs Node.js, MeshCentral (branded as "Creations IT"), configures it as a
    Windows service, sets up Windows Firewall, and wires up a fresh Cloudflare Tunnel
    to mesh.creationsit.com.

    Run as Administrator in PowerShell:
        iwr -useb https://raw.githubusercontent.com/HackMe7822/Mesh-Central/main/install.ps1 | iex

    Or to skip Cloudflare setup (re-run after it is already configured):
        .\install.ps1 -SkipCloudflare
#>

param(
    [string]$AdminUser  = "",
    [string]$AdminEmail = "",
    [switch]$SkipCloudflare,
    [switch]$SkipNodeInstall
)

$ErrorActionPreference = "Stop"

# ──────────────────────────────────────────────────────────────
#  CONFIGURATION  (edit these if you fork for a different client)
# ──────────────────────────────────────────────────────────────
$INSTALL_DIR   = "C:\MeshCentral"
$DATA_DIR      = "$INSTALL_DIR\meshcentral-data"
$PUBLIC_DIR    = "$DATA_DIR\public"
$CF_CONFIG_DIR = "C:\cloudflared"
$TUNNEL_NAME   = "meshcentral"
$DOMAIN        = "mesh.creationsit.com"
$BRAND_NAME    = "Creations IT"
$BRAND_TITLE2  = "Remote Support"
# ──────────────────────────────────────────────────────────────

function Write-Banner {
    Write-Host ""
    Write-Host "  ============================================" -ForegroundColor Blue
    Write-Host "    Creations IT  -  MeshCentral Deployer" -ForegroundColor Blue
    Write-Host "    Target : $DOMAIN" -ForegroundColor Blue
    Write-Host "  ============================================" -ForegroundColor Blue
    Write-Host ""
}

function Write-Step([int]$n, [string]$text) {
    Write-Host ""
    Write-Host "  [$n] $text" -ForegroundColor Cyan
}

function Write-OK([string]$text)   { Write-Host "      OK  $text" -ForegroundColor Green }
function Write-Info([string]$text) { Write-Host "      --> $text" -ForegroundColor Yellow }
function Write-Fail([string]$text) { Write-Host "      ERR $text" -ForegroundColor Red; exit 1 }

# ──────────────────────────────────────────────────────────────
#  PRE-FLIGHT
# ──────────────────────────────────────────────────────────────
Write-Banner

$isPrincipal = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $isPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Fail "Must run as Administrator. Right-click PowerShell > Run as administrator."
}

# Resolve script directory - works both when run from a file and when piped via iex
if ($PSScriptRoot) {
    $ScriptDir = $PSScriptRoot
} else {
    $ScriptDir = $PWD.Path
}

# ──────────────────────────────────────────────────────────────
#  STEP 1 : Node.js
# ──────────────────────────────────────────────────────────────
Write-Step 1 "Node.js LTS"

$nodeOk = $false
try {
    $nodeVer = (node --version 2>$null)
    if ($nodeVer -match "^v(\d+)") {
        if ([int]$Matches[1] -ge 18) { $nodeOk = $true }
    }
} catch {}

if ($nodeOk) {
    Write-OK "Node.js $nodeVer already installed"
} elseif ($SkipNodeInstall) {
    Write-Fail "Node.js 18+ not found and -SkipNodeInstall was set."
} else {
    Write-Info "Installing Node.js LTS via winget..."
    winget install OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements --silent
    if ($LASTEXITCODE -ne 0) { Write-Fail "winget Node.js install failed. Install manually from nodejs.org" }

    # Refresh PATH for this session
    $machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath    = [System.Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path    = "$machinePath;$userPath"

    $nodeVer = (node --version 2>$null)
    Write-OK "Node.js $nodeVer installed"
}

# ──────────────────────────────────────────────────────────────
#  STEP 2 : Create directories
# ──────────────────────────────────────────────────────────────
Write-Step 2 "Creating directories"
New-Item -ItemType Directory -Force -Path $INSTALL_DIR | Out-Null
New-Item -ItemType Directory -Force -Path $DATA_DIR    | Out-Null
New-Item -ItemType Directory -Force -Path $PUBLIC_DIR  | Out-Null
Write-OK "Directories ready under $INSTALL_DIR"

# ──────────────────────────────────────────────────────────────
#  STEP 3 : Install MeshCentral
# ──────────────────────────────────────────────────────────────
Write-Step 3 "Installing MeshCentral (npm install meshcentral)"
Set-Location $INSTALL_DIR

if (Test-Path "$INSTALL_DIR\node_modules\meshcentral") {
    Write-OK "MeshCentral already installed, skipping npm install"
} else {
    Write-Info "This takes 1-3 minutes..."
    npm install meshcentral
    if ($LASTEXITCODE -ne 0) { Write-Fail "npm install meshcentral failed." }
    Write-OK "MeshCentral installed"
}

# ──────────────────────────────────────────────────────────────
#  STEP 4 : Write config.json (with Creations IT branding)
# ──────────────────────────────────────────────────────────────
Write-Step 4 "Writing MeshCentral config.json"

# NOTE: agentCustomization changes the agent installer window title and icon.
#       titlePicture references logo.png placed in meshcentral-data\public\
$configJson = @"
{
  "settings": {
    "cert": "$DOMAIN",
    "minify": true,
    "port": 443,
    "redirPort": 80
  },
  "domains": {
    "": {
      "title": "$BRAND_NAME",
      "title2": "$BRAND_TITLE2",
      "titlePicture": "logo.png",
      "footer": "$BRAND_NAME - Remote Support",
      "newAccounts": false,
      "agentCustomization": {
        "displayName": "$BRAND_NAME Remote Support",
        "description": "$BRAND_NAME Remote Management Agent",
        "companyName": "$BRAND_NAME",
        "iconFile": "logo.ico"
      }
    }
  }
}
"@

$configJson | Out-File -FilePath "$DATA_DIR\config.json" -Encoding utf8
Write-OK "Config written to $DATA_DIR\config.json"

# ──────────────────────────────────────────────────────────────
#  STEP 5 : Copy branding assets (logo.png / logo.ico)
# ──────────────────────────────────────────────────────────────
Write-Step 5 "Branding assets"

$logoCopied = $false
foreach ($ext in @("png", "ico")) {
    $src = Join-Path $ScriptDir "logo.$ext"
    if (Test-Path $src) {
        Copy-Item $src "$PUBLIC_DIR\logo.$ext" -Force
        Write-OK "Copied logo.$ext  ->  $PUBLIC_DIR\logo.$ext"
        $logoCopied = $true
    } else {
        Write-Info "logo.$ext not found next to install.ps1 - add it manually:"
        Write-Info "  Copy logo.$ext to  $PUBLIC_DIR\logo.$ext"
    }
}

if (-not $logoCopied) {
    Write-Info "No logos copied. MeshCentral will use its default graphics until you add them."
}

# ──────────────────────────────────────────────────────────────
#  STEP 6 : Create admin account
# ──────────────────────────────────────────────────────────────
Write-Step 6 "Creating MeshCentral admin account"

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
#  STEP 7 : Install & start Windows service
# ──────────────────────────────────────────────────────────────
Write-Step 7 "Installing MeshCentral Windows service"
Set-Location $INSTALL_DIR

# Stop any existing instance first
$existingSvc = Get-Service MeshCentral -ErrorAction SilentlyContinue
if ($existingSvc) {
    Write-Info "Stopping existing MeshCentral service..."
    node node_modules\meshcentral --stop  2>&1 | Out-Null
    Start-Sleep 3
    node node_modules\meshcentral --uninstall 2>&1 | Out-Null
    Start-Sleep 2
}

node node_modules\meshcentral --install
Start-Sleep 2
node node_modules\meshcentral --start
Start-Sleep 8

$svc = Get-Service MeshCentral -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq "Running") {
    Write-OK "MeshCentral service is RUNNING"
} else {
    Write-Info "Service may still be initialising. To check: sc query MeshCentral"
}

# ──────────────────────────────────────────────────────────────
#  STEP 8 : Windows Firewall
# ──────────────────────────────────────────────────────────────
Write-Step 8 "Configuring Windows Firewall"

# Remove old rules silently, then re-add
netsh advfirewall firewall delete rule name="MeshCentral HTTPS" 2>$null | Out-Null
netsh advfirewall firewall delete rule name="MeshCentral HTTP"  2>$null | Out-Null
netsh advfirewall firewall add rule name="MeshCentral HTTPS" dir=in action=allow protocol=TCP localport=443 | Out-Null
netsh advfirewall firewall add rule name="MeshCentral HTTP"  dir=in action=allow protocol=TCP localport=80  | Out-Null
Write-OK "Firewall rules added for TCP 443 and 80"

# ──────────────────────────────────────────────────────────────
#  STEPS 9-13 : Cloudflare Tunnel
# ──────────────────────────────────────────────────────────────
if (-not $SkipCloudflare) {

    # ── 9: Install cloudflared ────────────────────────────────
    Write-Step 9 "Installing cloudflared"
    $cfCmd = Get-Command cloudflared -ErrorAction SilentlyContinue
    if (-not $cfCmd) {
        Write-Info "Installing cloudflared via winget..."
        winget install Cloudflare.cloudflared --accept-source-agreements --accept-package-agreements --silent
        if ($LASTEXITCODE -ne 0) { Write-Fail "winget cloudflared install failed." }
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    }
    $cfVer = (cloudflared --version 2>&1 | Select-Object -First 1)
    Write-OK "cloudflared ready  ($cfVer)"

    # ── 10: Cloudflare login ──────────────────────────────────
    Write-Step 10 "Cloudflare authentication"
    Write-Info "A browser window will open. Log in with your Cloudflare account and"
    Write-Info "select  creationsit.com  to authorise the tunnel."
    Write-Host ""
    Read-Host "      Press ENTER when ready to open the browser"
    cloudflared tunnel login
    if ($LASTEXITCODE -ne 0) { Write-Fail "Cloudflare login failed." }
    Write-OK "Authenticated with Cloudflare"

    # ── 11: Create (or reuse) tunnel ──────────────────────────
    Write-Step 11 "Cloudflare Tunnel  ($TUNNEL_NAME)"

    New-Item -ItemType Directory -Force -Path $CF_CONFIG_DIR | Out-Null

    # If an old tunnel with this name exists, delete it so DNS can be re-pointed
    $existingTunnel = cloudflared tunnel info $TUNNEL_NAME 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Info "Old tunnel '$TUNNEL_NAME' found - deleting so we can create a fresh one..."
        cloudflared tunnel delete $TUNNEL_NAME --force 2>&1 | Out-Null
        Start-Sleep 2
    }

    $createOut = (cloudflared tunnel create $TUNNEL_NAME 2>&1) -join " "
    if ($LASTEXITCODE -ne 0) { Write-Fail "cloudflared tunnel create failed: $createOut" }

    # Extract UUID from output  e.g. "Created tunnel meshcentral with id abc123..."
    $tunnelId = ""
    if ($createOut -match "([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})") {
        $tunnelId = $Matches[1]
    }
    if (-not $tunnelId) { Write-Fail "Could not extract Tunnel ID from: $createOut" }
    Write-OK "Tunnel created: $TUNNEL_NAME  (ID: $tunnelId)"

    # ── 12: DNS record ────────────────────────────────────────
    Write-Step 12 "DNS record  ($DOMAIN)"
    cloudflared tunnel route dns $TUNNEL_NAME $DOMAIN
    if ($LASTEXITCODE -ne 0) { Write-Fail "Failed to create DNS record. Check Cloudflare dashboard." }
    Write-OK "DNS record created  $DOMAIN  ->  $TUNNEL_NAME"

    # ── 13: Write config.yml ──────────────────────────────────
    Write-Step 13 "Cloudflare tunnel config.yml"

    # Credentials file is written by cloudflared to the current user's profile
    $credFile = "$env:USERPROFILE\.cloudflared\$tunnelId.json"

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
    Write-OK "Config written to $CF_CONFIG_DIR\config.yml"

    # ── 13b: Install cloudflared as a Windows service ─────────
    Write-Info "Installing cloudflared as Windows service (auto-starts on reboot)..."
    cloudflared --config "$CF_CONFIG_DIR\config.yml" service install
    if ($LASTEXITCODE -ne 0) { Write-Fail "cloudflared service install failed." }

    Start-Service cloudflared -ErrorAction SilentlyContinue
    Start-Sleep 3

    $cfSvc = Get-Service cloudflared -ErrorAction SilentlyContinue
    if ($cfSvc -and $cfSvc.Status -eq "Running") {
        Write-OK "Cloudflare tunnel service is RUNNING"
    } else {
        Write-Info "Tunnel service may still be starting.  sc query cloudflared  to check."
    }

} else {
    Write-Info "Skipping Cloudflare setup (-SkipCloudflare flag set)"
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
Write-Host "      1. Open https://$DOMAIN and confirm the login page loads" -ForegroundColor White
Write-Host "      2. Log in, go to My Account > Two Factor Authentication" -ForegroundColor White
Write-Host "      3. Create device groups: Servers / Workstations / Clients" -ForegroundColor White
Write-Host "      4. Add agents via Devices > Add Agent > Windows" -ForegroundColor White
Write-Host "      5. Drop logo.png + logo.ico into $PUBLIC_DIR\ if not done yet" -ForegroundColor White
Write-Host "      6. Back up $DATA_DIR regularly" -ForegroundColor White
Write-Host ""
Write-Host "    Services to verify:" -ForegroundColor Yellow
Write-Host "      sc query MeshCentral" -ForegroundColor Gray
Write-Host "      sc query cloudflared" -ForegroundColor Gray
Write-Host ""
