#Requires -RunAsAdministrator
# Run on the MeshCentral SERVER (VM) once.
# Patches the MeshAgent binaries that MeshCentral DISTRIBUTES to client machines.
# These live in node_modules\meshcentral\agents\ — NOT the agent installed on this server.
# After patch: new agent downloads from your MeshCentral URL have "Win Runtime" registry
# path instead of "Open Source" — exam browsers don't detect them, never set WDA.

Write-Host "[*] Finding MeshCentral distribution agent binaries..." -ForegroundColor Cyan
Write-Host "    (Looking in node_modules, NOT the agent installed on this server)" -ForegroundColor Gray

# MeshCentral stores agent binaries it serves to clients inside its node_modules
$agentsDirs = @(
    "C:\MeshCentral\node_modules\meshcentral\agents",
    "C:\meshcentral\node_modules\meshcentral\agents",
    "C:\Program Files\MeshCentral\node_modules\meshcentral\agents"
)

$allExes = @()
foreach ($d in $agentsDirs) {
    if (Test-Path $d) {
        $found = Get-ChildItem -Path $d -Filter "*.exe" -ErrorAction SilentlyContinue
        if ($found) { $allExes += $found.FullName }
        Write-Host "    Found agents dir: $d ($($found.Count) files)" -ForegroundColor Green
    }
}

# Fallback: search node_modules anywhere
if (-not $allExes) {
    Write-Host "[!] Standard paths not found. Searching node_modules..." -ForegroundColor Yellow
    $allExes = Get-ChildItem "C:\" -Recurse -Depth 9 -Filter "*.exe" -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match "node_modules.+meshcentral.+agents" } |
        Select-Object -ExpandProperty FullName
}

if (-not $allExes) {
    Write-Host "[!] No distribution agent binaries found in node_modules." -ForegroundColor Yellow
}

# Also patch any locally installed agent on THIS machine (agent installed on server itself)
$localAgents = Get-WmiObject Win32_Service -ErrorAction SilentlyContinue |
    Where-Object { $_.PathName -and ($_.PathName -match "mesh|SysDiag|CreationsIT") } |
    ForEach-Object {
        if ($_.PathName -match '^"([^"]+)"') { $Matches[1] }
        else { ($_.PathName -split ' ')[0] }
    } | Where-Object { $_ -and (Test-Path $_) } | Sort-Object -Unique

if ($localAgents) {
    Write-Host "`n[*] Also patching locally installed agent(s) on this server:" -ForegroundColor Cyan
    $localAgents | ForEach-Object { Write-Host "    $_" }
    $allExes += $localAgents
}

$allExes = $allExes | Sort-Object -Unique

if (-not $allExes) {
    Write-Host "[!] Nothing to patch found anywhere." -ForegroundColor Red
    exit 1
}

Write-Host "[+] Found $($allExes.Count) binary/binaries:" -ForegroundColor Green
$allExes | ForEach-Object { Write-Host "    $_" }

$oldA = [Text.Encoding]::ASCII.GetBytes("Open Source")
$newA = [Text.Encoding]::ASCII.GetBytes("Win Runtime")
$oldW = [Text.Encoding]::Unicode.GetBytes("Open Source")
$newW = [Text.Encoding]::Unicode.GetBytes("Win Runtime")

$patchedFiles = 0

foreach ($path in $allExes) {
    Write-Host "`n[*] Processing: $path" -ForegroundColor Cyan
    $bytes = [IO.File]::ReadAllBytes($path)
    $count = 0

    foreach ($pair in @(($oldA,$newA),($oldW,$newW))) {
        $old = $pair[0]; $new = $pair[1]
        for ($i = 0; $i -le $bytes.Length - $old.Length; $i++) {
            $m = $true
            for ($j = 0; $j -lt $old.Length; $j++) {
                if ($bytes[$i+$j] -ne $old[$j]) { $m = $false; break }
            }
            if ($m) {
                for ($j = 0; $j -lt $new.Length; $j++) { $bytes[$i+$j] = $new[$j] }
                $count++
                $i += $old.Length - 1
            }
        }
    }

    if ($count -gt 0) {
        # Find and stop any service whose executable is this file
        $owningSvc = Get-WmiObject Win32_Service | Where-Object {
            $_.PathName -and $_.PathName -match [regex]::Escape([IO.Path]::GetFileName($path))
        } | Select-Object -First 1

        if ($owningSvc) {
            Write-Host "    [*] Stopping service '$($owningSvc.Name)'..."
            Stop-Service $owningSvc.Name -Force -ErrorAction SilentlyContinue
            Start-Sleep 2
        }

        $bak = "$path.bak"
        if (-not (Test-Path $bak)) { Copy-Item $path $bak -Force -ErrorAction SilentlyContinue }

        try {
            [IO.File]::WriteAllBytes($path, $bytes)
            Write-Host "    [+] Patched $count occurrence(s) -> $([IO.Path]::GetFileName($path))" -ForegroundColor Green
            $patchedFiles++
        } catch {
            Write-Host "    [!] Write failed: $_" -ForegroundColor Red
            Write-Host "    Try stopping the service manually and re-running." -ForegroundColor Yellow
        }

        if ($owningSvc) {
            Start-Service $owningSvc.Name -ErrorAction SilentlyContinue
        }
    } else {
        Write-Host "    [~] No 'Open Source' found (already patched or different binary)" -ForegroundColor Yellow
    }
}

Write-Host "`n[*] Restarting MeshCentral service..."
$svcName = Get-Service | Where-Object { $_.Name -match "mesh" -or $_.DisplayName -match "mesh" } | Select-Object -First 1 -ExpandProperty Name
if ($svcName) {
    Restart-Service $svcName -Force
    Start-Sleep 3
    $s = Get-Service $svcName
    Write-Host "    Service '$svcName' -> $($s.Status)" -ForegroundColor $(if($s.Status -eq 'Running'){'Green'}else{'Red'})
} else {
    Write-Host "    [!] MeshCentral service not found - restart it manually" -ForegroundColor Yellow
}

Write-Host "`n============================================"
Write-Host "  Patched $patchedFiles file(s)."
Write-Host "  New agent downloads from your MeshCentral URL are now"
Write-Host "  undetectable - users just install and it works."
Write-Host "  No scripts needed on exam machines."
Write-Host "============================================"
