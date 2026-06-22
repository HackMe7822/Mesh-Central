#Requires -RunAsAdministrator
# Run on the MeshCentral SERVER (VM) once.
# Patches all MeshAgent Windows binaries so "Open Source" registry path
# is replaced with "Win Runtime" — exam browsers stop detecting the agent,
# WDA is never set, MeshCentral sees screen without any client-side steps.

Write-Host "[*] Finding MeshCentral agent binaries..." -ForegroundColor Cyan

# Find MeshCentral installation root
$roots = @(
    "C:\MeshCentral",
    "C:\Program Files\MeshCentral",
    "C:\meshcentral"
)
$agentDirs = @()
foreach ($r in $roots) {
    if (Test-Path $r) {
        $found = Get-ChildItem -Path $r -Recurse -Filter "MeshAgent-Windows*.exe" -ErrorAction SilentlyContinue
        if ($found) { $agentDirs += $found }
    }
}

# Also search node_modules for any meshagent exe
$nodeSearch = Get-ChildItem -Path "C:\" -Recurse -Filter "MeshAgent*.exe" -Depth 8 -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notlike "*\meshcentral-data\*" }
$agentDirs += $nodeSearch

# Deduplicate
$allExes = ($agentDirs | Select-Object -ExpandProperty FullName | Sort-Object -Unique)

if (-not $allExes) {
    Write-Host "[!] No MeshAgent binaries found. Looking harder..." -ForegroundColor Yellow
    # Fallback: search anywhere under C:\ up to depth 10
    $allExes = Get-ChildItem -Path "C:\" -Recurse -Filter "*agent*.exe" -Depth 10 -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match "mesh" -or $_.FullName -match "SysDiag" } |
        Select-Object -ExpandProperty FullName | Sort-Object -Unique
}

if (-not $allExes) {
    Write-Host "[!] Still nothing found. Please run:" -ForegroundColor Red
    Write-Host '    Get-ChildItem C:\ -Recurse -Filter "*.exe" -Depth 8 | Where-Object { $_.Name -match "mesh|agent" }'
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
        $bak = "$path.bak"
        if (-not (Test-Path $bak)) { Copy-Item $path $bak -Force }
        [IO.File]::WriteAllBytes($path, $bytes)
        Write-Host "    [+] Patched $count occurrence(s) -> $([IO.Path]::GetFileName($path))" -ForegroundColor Green
        $patchedFiles++
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
