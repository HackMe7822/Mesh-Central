param(
    [string]$Domain     = "remote.creationsit.com",
    [string]$InstallDir = "C:\MeshCentral"
)

function Write-Step($n, $msg) { Write-Host "`n[$n] $msg" -ForegroundColor Cyan }
function Write-OK($msg)       { Write-Host "  OK  $msg" -ForegroundColor Green }
function Write-Info($msg)     { Write-Host "  ..  $msg" -ForegroundColor Gray }
function Write-Fail($msg)     { Write-Host "  !!  $msg" -ForegroundColor Red }

Write-Host ""
Write-Host "Creations IT - Cert Hash Refresh" -ForegroundColor White
Write-Host "=================================" -ForegroundColor White

# ── Step 1: Fetch live cert hash from Cloudflare edge ──────────────────────
Write-Step 1 "Fetching current Cloudflare cert hash for $Domain"

$cfCertHash = $null
try {
    $tcpClient = New-Object System.Net.Sockets.TcpClient($Domain, 443)
    $sslStream  = New-Object System.Net.Security.SslStream($tcpClient.GetStream(), $false, { $true })
    $sslStream.AuthenticateAsClient($Domain)
    $certDer    = $sslStream.RemoteCertificate.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
    $sha384     = [System.Security.Cryptography.SHA384]::Create()
    $cfCertHash = [BitConverter]::ToString($sha384.ComputeHash($certDer)).Replace("-","").ToLower()
    try { $sslStream.Close(); $tcpClient.Close() } catch {}
    Write-OK "Hash: $cfCertHash"
} catch {
    Write-Fail "Could not connect to ${Domain}: $_"
    Write-Info "Make sure the cloudflared tunnel is running:  sc query cloudflared"
    Write-Info "And that the tunnel is active in the Cloudflare dashboard."
    pause
    exit 1
}

# ── Step 2: Read existing config, check if hash actually changed ───────────
Write-Step 2 "Checking config.json"

$configPath = "$InstallDir\meshcentral-data\config.json"
if (-not (Test-Path $configPath)) {
    Write-Fail "config.json not found at $configPath"
    pause
    exit 1
}

$currentHash = node -e "try{var c=JSON.parse(require('fs').readFileSync('$($configPath.Replace('\','\\'))','utf8'));console.log(c.domains[''].certhash||'')}catch(e){console.log('')}" 2>$null
if ($currentHash -eq $cfCertHash) {
    Write-OK "Hash is already up to date - no change needed"
    Write-Host ""
    Write-Host "All good. Agents should be connecting normally." -ForegroundColor Green
    pause
    exit 0
}

Write-Info "Old hash: $currentHash"
Write-Info "New hash: $cfCertHash"

# ── Step 3: Update config.json via Node.js (no BOM risk) ──────────────────
Write-Step 3 "Updating config.json"

Set-Location $InstallDir
$result = node -e "var fs=require('fs');var p='meshcentral-data/config.json';var c=JSON.parse(fs.readFileSync(p,'utf8'));c.domains[''].certhash='$cfCertHash';fs.writeFileSync(p,JSON.stringify(c,null,2));console.log('done');" 2>&1
if ($result -eq "done") {
    Write-OK "config.json updated"
} else {
    Write-Fail "Node.js update failed: $result"
    pause
    exit 1
}

# ── Step 4: Restart MeshCentral ───────────────────────────────────────────
Write-Step 4 "Restarting MeshCentral service"

Restart-Service MeshCentral -Force -ErrorAction SilentlyContinue
Start-Sleep 10

$svc = Get-Service MeshCentral -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq "Running") {
    Write-OK "MeshCentral is running - agents will reconnect within a minute"
} else {
    Write-Fail "MeshCentral may not have started cleanly"
    Write-Info "Check with:  sc query MeshCentral"
    Write-Info "Or run:      cd C:\MeshCentral && node node_modules\meshcentral"
}

Write-Host ""
Write-Host "Cert hash refresh complete." -ForegroundColor Green
Write-Host ""
pause
