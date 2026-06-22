#Requires -RunAsAdministrator
# Run on the MeshCentral SERVER after copying MeshService64.exe to C:\temp\MeshService64.exe
# Replaces the agent binary MeshCentral distributes to client machines, then restarts the service.

param(
    [string]$NewAgent = "C:\temp\MeshService64.exe"
)

if (-not (Test-Path $NewAgent)) {
    Write-Host "[!] New agent binary not found at: $NewAgent" -ForegroundColor Red
    Write-Host "    Copy MeshService64.exe from your build machine to C:\temp\MeshService64.exe first." -ForegroundColor Yellow
    exit 1
}
Write-Host "[+] New agent: $NewAgent ($([math]::Round((Get-Item $NewAgent).Length/1KB)) KB)" -ForegroundColor Green

# ── Locate MeshCentral agents directory ───────────────────────────────────────
$agentsDirs = @(
    "C:\MeshCentral\node_modules\meshcentral\agents",
    "C:\meshcentral\node_modules\meshcentral\agents",
    "C:\Program Files\MeshCentral\node_modules\meshcentral\agents"
)

$agentsDir = $null
foreach ($d in $agentsDirs) {
    if (Test-Path $d) { $agentsDir = $d; break }
}

if (-not $agentsDir) {
    Write-Host "[!] MeshCentral agents directory not found. Searching..." -ForegroundColor Yellow
    $agentsDir = Get-ChildItem "C:\" -Recurse -Depth 9 -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match "node_modules.+meshcentral.+agents$" } |
        Select-Object -First 1 -ExpandProperty FullName
}

if (-not $agentsDir) {
    Write-Host "[!] Cannot locate agents directory. Aborting." -ForegroundColor Red
    exit 1
}
Write-Host "[*] Agents directory: $agentsDir" -ForegroundColor Cyan

# ── List all exe files in agents dir ─────────────────────────────────────────
$allAgents = Get-ChildItem $agentsDir -Filter "*.exe" -ErrorAction SilentlyContinue
Write-Host "[*] Agent files found ($($allAgents.Count)):" -ForegroundColor Cyan
$allAgents | ForEach-Object { Write-Host "    $($_.Name)  ($([math]::Round($_.Length/1KB)) KB)" }

# Pick 64-bit Windows agents to replace (any exe with "64" in name, or all if none have "64")
$targets = @($allAgents | Where-Object { $_.Name -match "64" })
if (-not $targets) { $targets = @($allAgents) }

Write-Host "`n[*] Will replace $($targets.Count) file(s):" -ForegroundColor Cyan
$targets | ForEach-Object { Write-Host "    $($_.FullName)" }

# ── Stop MeshCentral ──────────────────────────────────────────────────────────
$svcName = Get-Service | Where-Object { $_.Name -match "mesh" -or $_.DisplayName -match "mesh" } |
    Select-Object -First 1 -ExpandProperty Name
if ($svcName) {
    Write-Host "`n[*] Stopping service '$svcName'..." -ForegroundColor Cyan
    Stop-Service $svcName -Force -ErrorAction SilentlyContinue
    Start-Sleep 3
} else {
    Write-Host "[~] MeshCentral service not found — continuing anyway" -ForegroundColor Yellow
}

# ── Replace binaries ──────────────────────────────────────────────────────────
$replaced = 0
foreach ($t in $targets) {
    $bak = "$($t.FullName).bak"
    if (-not (Test-Path $bak)) {
        Copy-Item $t.FullName $bak -Force
        Write-Host "    [bak] $bak" -ForegroundColor Gray
    }
    try {
        Copy-Item $NewAgent $t.FullName -Force
        Write-Host "    [+] Replaced: $($t.Name)" -ForegroundColor Green
        $replaced++
    } catch {
        Write-Host "    [!] Failed to replace $($t.Name): $_" -ForegroundColor Red
    }
}

# ── Apply "Open Source" -> "Win Runtime" string patch ────────────────────────
Write-Host "`n[*] Applying string patch (Open Source -> Win Runtime)..." -ForegroundColor Cyan
$oldA = [Text.Encoding]::ASCII.GetBytes("Open Source")
$newA = [Text.Encoding]::ASCII.GetBytes("Win Runtime")
$oldW = [Text.Encoding]::Unicode.GetBytes("Open Source")
$newW = [Text.Encoding]::Unicode.GetBytes("Win Runtime")

foreach ($t in $targets) {
    $bytes = [IO.File]::ReadAllBytes($t.FullName)
    $count = 0
    foreach ($pair in @(,@($oldA,$newA),@($oldW,$newW))) {
        $old = $pair[0]; $new = $pair[1]
        for ($i = 0; $i -le $bytes.Length - $old.Length; $i++) {
            $m = $true
            for ($j = 0; $j -lt $old.Length; $j++) {
                if ($bytes[$i+$j] -ne $old[$j]) { $m = $false; break }
            }
            if ($m) {
                for ($j = 0; $j -lt $new.Length; $j++) { $bytes[$i+$j] = $new[$j] }
                $count++; $i += $old.Length - 1
            }
        }
    }
    if ($count -gt 0) {
        [IO.File]::WriteAllBytes($t.FullName, $bytes)
        Write-Host "    [+] Patched $count string(s) in $($t.Name)" -ForegroundColor Green
    } else {
        Write-Host "    [~] No 'Open Source' found in $($t.Name)" -ForegroundColor Yellow
    }
}

# ── Restart MeshCentral ───────────────────────────────────────────────────────
if ($svcName) {
    Write-Host "`n[*] Starting '$svcName'..." -ForegroundColor Cyan
    Start-Service $svcName -ErrorAction SilentlyContinue
    Start-Sleep 3
    $s = Get-Service $svcName -ErrorAction SilentlyContinue
    $color = if ($s.Status -eq 'Running') { 'Green' } else { 'Red' }
    Write-Host "    Service status: $($s.Status)" -ForegroundColor $color
}

Write-Host "`n============================================"
Write-Host "  Replaced $replaced agent binary/binaries."
Write-Host "  Agents directory: $agentsDir"
Write-Host ""
Write-Host "  Next steps on exam machine:"
Write-Host "  1. Install fresh agent from MeshCentral"
Write-Host "  2. Reboot once (activates test signing for capturedrv.sys)"
Write-Host "  3. Open exam browser — screen capture should work"
Write-Host "============================================"
