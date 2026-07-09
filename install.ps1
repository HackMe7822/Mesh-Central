#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Creations IT - MeshCentral One-Click Deployer
.DESCRIPTION
    Installs Node.js, MeshCentral (branded as "Creations IT"), configures it as a
    Windows service, sets up Windows Firewall, and wires up a fresh Cloudflare Tunnel.

    Default subdomain: remote.creationsit.com
    Override with -Domain for any other subdomain on creationsit.com.

    Run as Administrator in PowerShell on the target VM:
        $u=(iwr "https://api.github.com/repos/HackMe7822/Mesh-Central/contents/install.ps1" -UseBasicParsing|ConvertFrom-Json).download_url; iwr $u -OutFile "C:\deploy.ps1"; powershell -ExecutionPolicy Bypass -File "C:\deploy.ps1"

    With a custom subdomain:
        powershell -ExecutionPolicy Bypass -File "C:\deploy.ps1" -Domain "crm.creationsit.com" -TunnelName "crm"

    Re-run flags:
        -Domain             Subdomain to publish on (default: remote.creationsit.com)
        -TunnelName         Cloudflare tunnel name   (default: remote)
        -SkipCloudflare     Skip Cloudflare tunnel setup
        -SkipNodeInstall    Skip Node.js install
        -UpdateOnly         Only refresh config + branding, restart service
        -InstallDir         Override install path    (default: C:\MeshCentral)
#>

param(
    [string]$Domain     = "remote.creationsit.com",
    [string]$TunnelName = "creationsit-vm",
    [string]$InstallDir = "",
    [switch]$SkipCloudflare,
    [switch]$SkipNodeInstall,
    [switch]$UpdateOnly
)

$ErrorActionPreference = "Continue"

# --------------------------------------------------------------
#  CONFIGURATION
# --------------------------------------------------------------
$INSTALL_DIR   = if ($InstallDir) { $InstallDir } else { "C:\MeshCentral" }
$DATA_DIR      = "$INSTALL_DIR\meshcentral-data"
$PUBLIC_DIR    = "$DATA_DIR\public"
$CF_CONFIG_DIR = "C:\cloudflared"
$BRAND_NAME    = "Creations IT"
$LOGO_FILE     = "CreationsIT.ico"
$LOGO_RAW_URL  = "https://raw.githubusercontent.com/HackMe7822/Mesh-Central/main/CreationsIT.ico"
# --------------------------------------------------------------

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

# --------------------------------------------------------------
#  -UpdateOnly : refresh config + branding only, then exit
# --------------------------------------------------------------
if ($UpdateOnly) {
    Write-Host "  [UPDATE ONLY MODE]" -ForegroundColor Magenta

    Write-Step 1 "Refreshing branding logo"
    New-Item -ItemType Directory -Force -Path $PUBLIC_DIR | Out-Null
    $logoSrc = Join-Path $ScriptDir $LOGO_FILE
    if (Test-Path $logoSrc) {
        Copy-Item $logoSrc "$PUBLIC_DIR\$LOGO_FILE" -Force
        Copy-Item $logoSrc "$DATA_DIR\$LOGO_FILE"   -Force
        Write-OK "Copied $LOGO_FILE to public\ and data root"
    } else {
        Write-Info "Downloading $LOGO_FILE from GitHub..."
        Invoke-WebRequest -Uri $LOGO_RAW_URL -OutFile "$PUBLIC_DIR\$LOGO_FILE" -UseBasicParsing
        Copy-Item "$PUBLIC_DIR\$LOGO_FILE" "$DATA_DIR\$LOGO_FILE" -Force
        Write-OK "Downloaded $LOGO_FILE"
    }

    Write-Step 2 "Converting logo to PNG"
    try {
        Add-Type -AssemblyName PresentationCore
        $decoder = New-Object System.Windows.Media.Imaging.IconBitmapDecoder(
            (New-Object System.Uri("$DATA_DIR\$LOGO_FILE")),
            [System.Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
            [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        )
        $frame   = $decoder.Frames | Sort-Object { $_.PixelWidth } -Descending | Select-Object -First 1
        $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
        $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($frame))
        $stream  = New-Object System.IO.FileStream("$DATA_DIR\CreationsIT.png", [System.IO.FileMode]::Create)
        $encoder.Save($stream)
        $stream.Close()
        Write-OK "CreationsIT.png updated"
    } catch { Write-Info "PNG conversion skipped: $_" }

    Write-Step 3 "Refreshing config.json (preserving certhash)"
    $cfgPath = "$DATA_DIR\config.json"

    $existingCertHash = $null
    if (Test-Path $cfgPath) {
        try {
            $existingCfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
            # PS5: empty-string key needs PSObject.Properties
            $domainObj = $existingCfg.domains.PSObject.Properties | Where-Object { $_.Name -eq '' } | Select-Object -ExpandProperty Value
            if (-not $domainObj) { $domainObj = $existingCfg.domains.PSObject.Properties | Select-Object -First 1 -ExpandProperty Value }
            $existingCertHash = $domainObj.certhash
        } catch {}
    }
    if ($existingCertHash) { Write-Info "Preserving certhash: $existingCertHash" } else { Write-Info "No existing certhash found in config" }

    $domainBlock = [ordered]@{
        title        = "$BRAND_NAME Remote Support"
        title2       = "$BRAND_NAME"
        newAccounts  = $false
        agentInvite  = $true
        guestMode    = $true
        agentcustomization = [ordered]@{
            displayname = "$BRAND_NAME Remote Support"
            description = "$BRAND_NAME Remote Management Agent"
            companyname = "$BRAND_NAME"
            filename    = "CreationsIT-Agent"
            image       = "CreationsIT.png"
        }
        agentFileInfo = [ordered]@{
            icon            = "$LOGO_FILE"
            filedescription = "$BRAND_NAME Remote Agent"
            fileversion     = "1.0.0"
            internalname    = "CreationsITAgent"
            legalcopyright  = "Copyright 2024 $BRAND_NAME"
            originalfilename = "CreationsITAgent.exe"
            productname     = "$BRAND_NAME Remote Support"
            productversion  = "1.0.0"
        }
    }
    if ($existingCertHash) { $domainBlock['certhash'] = $existingCertHash }

    $cfg = [ordered]@{
        settings = [ordered]@{
            cert       = "$Domain"
            SQLite3    = $true
            port       = 443
            tlsOffload = "127.0.0.1"
        }
        domains = [ordered]@{ '' = $domainBlock }
    }
    $json = $cfg | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($cfgPath, $json, [System.Text.UTF8Encoding]::new($false))
    Write-OK "config.json updated (certhash $(if ($existingCertHash) { 'preserved' } else { 'not set' }))"

    Write-Step 4 "Restarting MeshCentral service"
    Restart-Service MeshCentral -Force -ErrorAction SilentlyContinue
    Start-Sleep 5
    $s = Get-Service MeshCentral -ErrorAction SilentlyContinue
    if ($s -and $s.Status -eq "Running") { Write-OK "MeshCentral restarted" }
    else { Write-Info "Check: sc query MeshCentral" }

    Write-Host ""
    Write-Host "  Update complete. Hard-refresh the browser (Ctrl+Shift+R) to see changes." -ForegroundColor Green
    Write-Host "  Agent branding applies to newly downloaded agents from https://$Domain" -ForegroundColor Green
    Write-Host ""
    exit 0
}

# --------------------------------------------------------------
#  STEP 1 : Node.js
# --------------------------------------------------------------
Write-Step 1 "Node.js LTS"

function Update-EnvPath {
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path","User")
}

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
    Write-Info "Fetching latest Node.js LTS version..."
    try {
        $indexJson = (Invoke-WebRequest -Uri "https://nodejs.org/dist/index.json" -UseBasicParsing).Content | ConvertFrom-Json
        $lts = $indexJson | Where-Object { $_.lts -ne $false } | Select-Object -First 1
        $nodeMsiVer = $lts.version
    } catch {
        $nodeMsiVer = "v20.19.2"
    }
    $nodeMsiUrl  = "https://nodejs.org/dist/$nodeMsiVer/node-$nodeMsiVer-x64.msi"
    $nodeMsiPath = "$env:TEMP\node-lts.msi"
    Write-Info "Downloading Node.js $nodeMsiVer ..."
    Invoke-WebRequest -Uri $nodeMsiUrl -OutFile $nodeMsiPath -UseBasicParsing
    Write-Info "Installing Node.js (silent)..."
    Start-Process msiexec.exe -Wait -ArgumentList "/i `"$nodeMsiPath`" /qn ADDLOCAL=ALL"
    Remove-Item $nodeMsiPath -Force -ErrorAction SilentlyContinue

    Update-EnvPath
    $nodeDir = "C:\Program Files\nodejs"
    if ((Test-Path $nodeDir) -and ($env:Path -notlike "*$nodeDir*")) {
        $env:Path = "$nodeDir;" + $env:Path
    }
    $nodeVer = (node --version 2>$null)
    if (-not $nodeVer) { Write-Fail "Node.js still not found - try rebooting then re-run with -SkipNodeInstall." }
    Write-OK "Node.js $nodeVer installed"
}

# --------------------------------------------------------------
#  STEP 2 : Directories
# --------------------------------------------------------------
Write-Step 2 "Creating directories"
New-Item -ItemType Directory -Force -Path $INSTALL_DIR | Out-Null
New-Item -ItemType Directory -Force -Path $DATA_DIR    | Out-Null
New-Item -ItemType Directory -Force -Path $PUBLIC_DIR  | Out-Null
Write-OK "Directories ready under $INSTALL_DIR"

# --------------------------------------------------------------
#  STEP 3 : Install MeshCentral
# --------------------------------------------------------------
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

# --------------------------------------------------------------
#  STEP 4 : Branding logo
# --------------------------------------------------------------
Write-Step 4 "Branding logo ($LOGO_FILE)"
$logoSrc = Join-Path $ScriptDir $LOGO_FILE
if (Test-Path $logoSrc) {
    Copy-Item $logoSrc "$PUBLIC_DIR\$LOGO_FILE" -Force
    Copy-Item $logoSrc "$DATA_DIR\$LOGO_FILE"   -Force
    Write-OK "Copied $LOGO_FILE to public\ and data root"
} else {
    Write-Info "Downloading $LOGO_FILE from GitHub..."
    Invoke-WebRequest -Uri $LOGO_RAW_URL -OutFile "$PUBLIC_DIR\$LOGO_FILE" -UseBasicParsing
    Copy-Item "$PUBLIC_DIR\$LOGO_FILE" "$DATA_DIR\$LOGO_FILE" -Force
    Write-OK "Downloaded $LOGO_FILE"
}

# Convert ICO to PNG using WPF WIC (handles PNG-compressed ICO frames correctly)
try {
    Add-Type -AssemblyName PresentationCore
    $decoder = New-Object System.Windows.Media.Imaging.IconBitmapDecoder(
        (New-Object System.Uri("$DATA_DIR\$LOGO_FILE")),
        [System.Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
        [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    )
    $frame   = $decoder.Frames | Sort-Object { $_.PixelWidth } -Descending | Select-Object -First 1
    $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($frame))
    $stream  = New-Object System.IO.FileStream("$DATA_DIR\CreationsIT.png", [System.IO.FileMode]::Create)
    $encoder.Save($stream)
    $stream.Close()
    Write-OK "Converted $LOGO_FILE -> CreationsIT.png (agent dialog image)"
} catch {
    Write-Info "PNG conversion skipped: $_"
}

# --------------------------------------------------------------
#  STEP 5 : config.json
# --------------------------------------------------------------
Write-Step 5 "Writing config.json"

$configJson = @"
{
  "settings": {
    "cert": "$Domain",
    "SQLite3": true,
    "port": 443,
    "tlsOffload": "127.0.0.1"
  },
  "domains": {
    "": {
      "title": "$BRAND_NAME Remote Support",
      "title2": "$BRAND_NAME",
      "newAccounts": false,
      "agentInvite": true,
      "guestMode": true,
      "agentcustomization": {
        "displayname": "$BRAND_NAME Remote Support",
        "description": "$BRAND_NAME Remote Management Agent",
        "companyname": "$BRAND_NAME",
        "filename": "CreationsIT-Agent",
        "image": "CreationsIT.png"
      },
      "agentFileInfo": {
        "icon": "$LOGO_FILE",
        "filedescription": "$BRAND_NAME Remote Agent",
        "fileversion": "1.0.0",
        "internalname": "CreationsITAgent",
        "legalcopyright": "Copyright 2024 $BRAND_NAME",
        "originalfilename": "CreationsITAgent.exe",
        "productname": "$BRAND_NAME Remote Support",
        "productversion": "1.0.0"
      }
    }
  }
}
"@
[System.IO.File]::WriteAllText("$DATA_DIR\config.json", $configJson, [System.Text.UTF8Encoding]::new($false))
Write-OK "config.json written to $DATA_DIR\config.json"

# --------------------------------------------------------------
#  STEP 6 : Windows service
# --------------------------------------------------------------
Write-Step 6 "Installing MeshCentral Windows service"
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
else { Write-Info "Service starting - check: sc query MeshCentral" }

# --------------------------------------------------------------
#  STEP 7 : Firewall
# --------------------------------------------------------------
Write-Step 7 "Windows Firewall"
netsh advfirewall firewall delete rule name="MeshCentral HTTPS" 2>$null | Out-Null
netsh advfirewall firewall delete rule name="MeshCentral HTTP"  2>$null | Out-Null
netsh advfirewall firewall add rule name="MeshCentral HTTPS" dir=in action=allow protocol=TCP localport=443 | Out-Null
netsh advfirewall firewall add rule name="MeshCentral HTTP"  dir=in action=allow protocol=TCP localport=80  | Out-Null
Write-OK "Firewall rules added (TCP 443 + 80)"

# --------------------------------------------------------------
#  STEPS 8-12 : Cloudflare Tunnel
# --------------------------------------------------------------
if (-not $SkipCloudflare) {

    Write-Step 8 "Installing cloudflared (always latest - no version warnings)"
    Write-Info "Downloading latest cloudflared MSI..."
    $cfMsiUrl  = "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.msi"
    $cfMsiPath = "$env:TEMP\cloudflared.msi"
    Invoke-WebRequest -Uri $cfMsiUrl -OutFile $cfMsiPath -UseBasicParsing
    Write-Info "Installing cloudflared..."
    Start-Process msiexec.exe -Wait -ArgumentList "/i `"$cfMsiPath`" /qn"
    Remove-Item $cfMsiPath -Force -ErrorAction SilentlyContinue
    Update-EnvPath
    foreach ($cfDir in @("C:\Program Files (x86)\cloudflare\cloudflared",
                         "C:\Program Files\cloudflare\cloudflared")) {
        if ((Test-Path $cfDir) -and ($env:Path -notlike "*$cfDir*")) {
            $env:Path = "$cfDir;" + $env:Path
        }
    }
    $cfCmd = Get-Command cloudflared -ErrorAction SilentlyContinue
    if (-not $cfCmd) { Write-Fail "cloudflared not found after install." }
    Write-OK "cloudflared installed"

    Write-Step 9 "Cloudflare authentication"
    # Check multiple possible cert locations - $env:USERPROFILE can differ in iex context
    $certPem = $null
    foreach ($p in @(
        "$env:USERPROFILE\.cloudflared\cert.pem",
        "C:\Users\$env:USERNAME\.cloudflared\cert.pem",
        "C:\Users\Administrator\.cloudflared\cert.pem"
    )) {
        if (Test-Path $p -ErrorAction SilentlyContinue) { $certPem = $p; break }
    }

    if ($certPem) {
        Write-OK "Already authenticated (found $certPem)"
    } else {
        Write-Info "A browser window will open. Log in and select creationsit.com"
        Read-Host "      Press ENTER to open the browser"
        cloudflared tunnel login 2>&1 | ForEach-Object { Write-Host "      $_" }
        # Re-check after login
        foreach ($p in @(
            "$env:USERPROFILE\.cloudflared\cert.pem",
            "C:\Users\$env:USERNAME\.cloudflared\cert.pem",
            "C:\Users\Administrator\.cloudflared\cert.pem"
        )) {
            if (Test-Path $p -ErrorAction SilentlyContinue) { $certPem = $p; break }
        }
        if (-not $certPem) { Write-Fail "Cloudflare login failed - cert.pem not found." }
        Write-OK "Authenticated"
    }

    Write-Step 10 "Cloudflare Tunnel ($TunnelName)"
    New-Item -ItemType Directory -Force -Path $CF_CONFIG_DIR | Out-Null

    # Check if tunnel already exists - reuse it to preserve other apps on this tunnel
    $tunnelId = ""
    $tunnelExists = $false
    $infoOut = (cmd /c "cloudflared tunnel info $TunnelName 2>&1") -join " "
    if ($LASTEXITCODE -eq 0 -and $infoOut -match "([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})") {
        $tunnelId = $Matches[1]
        $tunnelExists = $true
        Write-OK "Existing tunnel found: $TunnelName ($tunnelId) - reusing, other apps unaffected"
    } else {
        Write-Info "No existing tunnel found - creating $TunnelName..."
        $createOut = (cmd /c "cloudflared tunnel create $TunnelName 2>&1") -join " "
        if ($LASTEXITCODE -ne 0) { Write-Fail "tunnel create failed: $createOut" }
        if ($createOut -match "([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})") {
            $tunnelId = $Matches[1]
        }
        if (-not $tunnelId) { Write-Fail "Could not extract Tunnel ID from: $createOut" }
        Write-OK "Tunnel created: $TunnelName ($tunnelId)"
    }

    Write-Step 11 "DNS record ($Domain)"
    $dnsOut = (cmd /c "cloudflared tunnel route dns --overwrite-dns $TunnelName $Domain 2>&1") -join " "
    if ($LASTEXITCODE -ne 0) { Write-Fail "DNS record creation failed: $dnsOut" }
    Write-OK "DNS: $Domain -> $TunnelName"

    Write-Step 12 "Cloudflare tunnel config + service"
    $credFile = "C:\Users\Administrator\.cloudflared\$tunnelId.json"

    if ($tunnelExists -and (Test-Path "$CF_CONFIG_DIR\config.yml")) {
        # Tunnel already exists - only add our hostname if it is not already in the config
        $existingYml = Get-Content "$CF_CONFIG_DIR\config.yml" -Raw
        if ($existingYml -match "hostname:\s*$([regex]::Escape($Domain))") {
            Write-OK "$Domain already present in config.yml - no change needed"
        } else {
            Write-Info "Adding $Domain to existing config.yml..."
            $newRule = "  - hostname: $Domain`n    service: http://127.0.0.1:443"
            $updatedYml = $existingYml -replace "(\r?\n[ \t]*- service: http_status:\d+)", "`n$newRule`n`$1"
            if ($updatedYml -match "hostname:\s*$([regex]::Escape($Domain))") {
                [System.IO.File]::WriteAllText("$CF_CONFIG_DIR\config.yml", $updatedYml, [System.Text.UTF8Encoding]::new($false))
                Write-OK "Added $Domain to config.yml (all other rules untouched)"
            } else {
                # Regex did not match catch-all line - append manually before end of file
                Write-Info "Catch-all line not matched - appending $Domain rule manually..."
                $appended = $existingYml.TrimEnd() + "`n  - hostname: $Domain`n    service: http://127.0.0.1:443`n  - service: http_status:404`n"
                [System.IO.File]::WriteAllText("$CF_CONFIG_DIR\config.yml", $appended, [System.Text.UTF8Encoding]::new($false))
                Write-OK "Added $Domain to config.yml (appended at end)"
            }
        }
        # Restart service to pick up any config changes
        Write-Info "Restarting cloudflared service..."
        $nssmExe = (Get-Command nssm -ErrorAction SilentlyContinue).Source
        if ($nssmExe) {
            & $nssmExe restart cloudflared 2>&1 | Out-Null
        } else {
            cmd /c "sc stop cloudflared >nul 2>&1"
            Start-Sleep 5
            cmd /c "sc start cloudflared >nul 2>&1"
        }
        Start-Sleep 8
    } else {
        # New tunnel - write a fresh config and (re)create the Windows service
        $cfYml = @"
tunnel: $tunnelId
credentials-file: $credFile

ingress:
  - hostname: $Domain
    service: http://127.0.0.1:443
  # --- Add more apps below this line ---
  # - hostname: trading.creationsit.com
  #   service: http://localhost:3000
  # - hostname: files.creationsit.com
  #   service: http://localhost:8080
  # -------------------------------------
  - service: http_status:404
"@
        [System.IO.File]::WriteAllText("$CF_CONFIG_DIR\config.yml", $cfYml, [System.Text.UTF8Encoding]::new($false))
        Write-OK "Config written: $CF_CONFIG_DIR\config.yml"

        # Remove any existing cloudflared service
        $existingCf = Get-Service cloudflared -ErrorAction SilentlyContinue
        if ($existingCf) {
            Write-Info "Removing existing cloudflared service..."
            cmd /c "sc stop cloudflared >nul 2>&1"
            Start-Sleep 3
            cmd /c "taskkill /f /im cloudflared.exe >nul 2>&1"
            Start-Sleep 2
            cmd /c "sc delete cloudflared >nul 2>&1"
            Start-Sleep 5
        }

        $cfExe = (Get-Command cloudflared -ErrorAction SilentlyContinue).Source
        if (-not $cfExe) {
            foreach ($d in @("C:\Program Files (x86)\cloudflare\cloudflared",
                             "C:\Program Files\cloudflare\cloudflared")) {
                if (Test-Path "$d\cloudflared.exe") { $cfExe = "$d\cloudflared.exe"; break }
            }
        }
        if (-not $cfExe) { Write-Fail "cloudflared.exe not found - cannot create service." }

        $binPath = "`"$cfExe`" --config `"$CF_CONFIG_DIR\config.yml`" tunnel run"
        cmd /c "sc.exe create cloudflared binPath= `"$binPath`" start= auto obj= LocalSystem DisplayName= `"Cloudflare Tunnel`" >nul 2>&1"
        cmd /c "sc.exe description cloudflared `"Cloudflare Tunnel - Creations IT`" >nul 2>&1"
        if ($LASTEXITCODE -ne 0) { Write-Fail "cloudflared service creation failed." }

        cmd /c "sc.exe start cloudflared >nul 2>&1"
        Start-Sleep 8
    }

    $cfSvc = Get-Service cloudflared -ErrorAction SilentlyContinue
    if ($cfSvc -and $cfSvc.Status -eq "Running") {
        Write-OK "Cloudflare tunnel service RUNNING - https://$Domain is live"
    } else {
        Write-Fail "cloudflared service did not start. Run manually to see error:`n      cloudflared --config `"$CF_CONFIG_DIR\config.yml`" tunnel run"
    }

    # ------------------------------------------------------------------
    #  STEP 13 : Fetch Cloudflare TLS cert hash and bake into config.json
    #  Cloudflare terminates TLS at the edge; agents see Cloudflare's cert.
    #  MeshCentral must accept that cert hash or agents will be rejected.
    # ------------------------------------------------------------------
    Write-Step 13 "Fetching Cloudflare cert hash for agent validation"
    Write-Info "Waiting for tunnel to register with Cloudflare (up to 30s)..."
    $cfCertHash = $null
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        Start-Sleep 5
        try {
            $tcpClient = New-Object System.Net.Sockets.TcpClient($Domain, 443)
            $sslStream  = New-Object System.Net.Security.SslStream($tcpClient.GetStream(), $false, { $true })
            $sslStream.AuthenticateAsClient($Domain)
            $certDer    = $sslStream.RemoteCertificate.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
            $sha384     = [System.Security.Cryptography.SHA384]::Create()
            $cfCertHash = [BitConverter]::ToString($sha384.ComputeHash($certDer)).Replace("-","").ToLower()
            try { $sslStream.Close(); $tcpClient.Close() } catch {}
            break
        } catch { Write-Info "  attempt $attempt/6 - tunnel not ready yet..." }
    }

    if ($cfCertHash) {
        Write-OK "Cert hash: $cfCertHash"
        Write-Info "Updating config.json and restarting MeshCentral..."
        Set-Location $INSTALL_DIR
        node -e "var fs=require('fs');var c=JSON.parse(fs.readFileSync('meshcentral-data/config.json','utf8'));c.domains[''].certhash='$cfCertHash';fs.writeFileSync('meshcentral-data/config.json',JSON.stringify(c,null,2));console.log('ok');"
        Restart-Service MeshCentral -Force -ErrorAction SilentlyContinue
        Start-Sleep 8
        $svc2 = Get-Service MeshCentral -ErrorAction SilentlyContinue
        if ($svc2 -and $svc2.Status -eq "Running") { Write-OK "MeshCentral restarted - agents will connect through the tunnel" }
        else { Write-Info "MeshCentral restart slow - check: sc query MeshCentral" }
    } else {
        Write-Info "Could not reach $Domain after 30s - cert hash not set."
        Write-Info "Once the tunnel is stable, re-run: .\install.ps1 -UpdateOnly"
    }

} else {
    Write-Info "Skipping Cloudflare setup (-SkipCloudflare)"
}

# --------------------------------------------------------------
#  DONE
# --------------------------------------------------------------
Write-Host ""
Write-Host "  ============================================" -ForegroundColor Green
Write-Host "    DEPLOYMENT COMPLETE" -ForegroundColor Green
Write-Host "  ============================================" -ForegroundColor Green
Write-Host ""
Write-Host "    URL    : https://$Domain" -ForegroundColor Cyan
Write-Host "    Data   : $DATA_DIR" -ForegroundColor Gray
Write-Host ""
Write-Host "    Next steps:" -ForegroundColor Yellow
Write-Host "      1. Open https://$Domain - first visit shows Create Account page" -ForegroundColor White
Write-Host "      2. Create your admin account - first account is automatically site admin" -ForegroundColor White
Write-Host "      3. My Account > Two Factor Authentication" -ForegroundColor White
Write-Host "      4. Create device groups: Servers / Workstations / Clients" -ForegroundColor White
Write-Host "      5. Devices > Add Agent > Windows - verify agent shows Creations IT branding" -ForegroundColor White
Write-Host "      6. Back up $DATA_DIR regularly" -ForegroundColor White
Write-Host ""
Write-Host "    To update branding only (no reinstall):" -ForegroundColor Yellow
Write-Host "      .\install.ps1 -UpdateOnly" -ForegroundColor Gray
Write-Host ""
