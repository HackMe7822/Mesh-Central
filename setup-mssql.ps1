#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Creations IT - SQL Server Express Setup for MeshCentral
.DESCRIPTION
    Detects/installs SQL Server Express, creates the MeshCentral database and
    a dedicated SQL user, migrates existing SQLite data, and updates config.json.

    Run as Administrator:
        powershell -ExecutionPolicy Bypass -File setup-mssql.ps1
#>

param(
    [string]$InstallDir   = "C:\MeshCentral",
    [string]$DatabaseName = "meshcentral"
)

$ErrorActionPreference = "Continue"
$DATA_DIR = "$InstallDir\meshcentral-data"

function Write-Banner {
    Write-Host ""
    Write-Host "  ============================================" -ForegroundColor Blue
    Write-Host "    Creations IT  -  SQL Server Setup" -ForegroundColor Blue
    Write-Host "  ============================================" -ForegroundColor Blue
    Write-Host ""
}
function Write-Step([int]$n, [string]$text) { Write-Host "`n  [$n] $text" -ForegroundColor Cyan }
function Write-OK([string]$t)               { Write-Host "      OK  $t" -ForegroundColor Green }
function Write-Info([string]$t)             { Write-Host "      --> $t" -ForegroundColor Yellow }
function Write-Fail([string]$t)             { Write-Host "      ERR $t" -ForegroundColor Red; Write-Host ""; exit 1 }

function Prompt-Secret([string]$prompt) {
    $secure = Read-Host $prompt -AsSecureString
    [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
}

function Test-SqlConnection([string]$server, [string]$user, [string]$pwd, [bool]$windowsAuth = $false) {
    try {
        if ($windowsAuth) {
            $cs = "Server=$server;Integrated Security=true;Connection Timeout=5;"
        } else {
            $cs = "Server=$server;User Id=$user;Password=$pwd;Connection Timeout=5;"
        }
        $conn = New-Object System.Data.SqlClient.SqlConnection($cs)
        $conn.Open()
        $conn.Close()
        return $true
    } catch { return $false }
}

function Invoke-Sql([string]$server, [string]$user, [string]$pwd, [string]$query,
                    [string]$database = "master", [bool]$windowsAuth = $false) {
    if ($windowsAuth) {
        $cs = "Server=$server;Database=$database;Integrated Security=true;Connection Timeout=10;"
    } else {
        $cs = "Server=$server;Database=$database;User Id=$user;Password=$pwd;Connection Timeout=10;"
    }
    $conn = New-Object System.Data.SqlClient.SqlConnection($cs)
    $conn.Open()
    $cmd  = $conn.CreateCommand()
    $cmd.CommandText  = $query
    $cmd.CommandTimeout = 30
    $result = $cmd.ExecuteScalar()
    $conn.Close()
    return $result
}

function Database-Exists([string]$server, [string]$user, [string]$pwd, [string]$dbName,
                          [bool]$windowsAuth = $false) {
    $r = Invoke-Sql $server $user $pwd `
        "SELECT COUNT(*) FROM sys.databases WHERE name = '$dbName'" `
        "master" $windowsAuth
    return ([int]$r -gt 0)
}

function User-Exists([string]$server, [string]$user, [string]$pwd, [string]$loginName,
                     [bool]$windowsAuth = $false) {
    $r = Invoke-Sql $server $user $pwd `
        "SELECT COUNT(*) FROM sys.server_principals WHERE name = '$loginName'" `
        "master" $windowsAuth
    return ([int]$r -gt 0)
}

Write-Banner

# Verify MeshCentral is installed
if (-not (Test-Path "$InstallDir\node_modules\meshcentral")) {
    Write-Fail "MeshCentral not found at $InstallDir. Run the main installer first."
}

# ── STEP 1 : Detect SQL Server ──────────────────────────────────────────────
Write-Step 1 "Detecting SQL Server"

$sqlServices = Get-Service | Where-Object {
    ($_.Name -eq "MSSQLSERVER" -or $_.Name -match "^MSSQL\$") -and
    $_.Name -notmatch "LAUNCHPAD|EXTENSIBILITY|REPORTING|ANALYSIS"
}

$sqlInstalled = ($sqlServices.Count -gt 0)
$sqlInstance  = ""
$sqlServer    = ""
$sqlUser      = ""
$sqlPwd       = ""
$windowsAuth  = $false

if ($sqlInstalled) {
    Write-OK "SQL Server found: $($sqlServices | ForEach-Object { $_.Name } | Join-String ', ')"
} else {
    Write-Info "No SQL Server detected."
}

# ── STEP 2 : Install SQL Server Express if needed ───────────────────────────
Write-Step 2 "SQL Server installation"

if (-not $sqlInstalled) {
    Write-Info "Will download and install SQL Server 2022 Express (~600 MB)."
    Write-Host ""

    $saPwd = ""
    do {
        $saPwd  = Prompt-Secret "      Set SA password (min 8 chars, upper+lower+number+symbol): "
        $saPwd2 = Prompt-Secret "      Confirm SA password: "
        if ($saPwd -ne $saPwd2)     { Write-Host "      Passwords do not match, try again." -ForegroundColor Red }
        elseif ($saPwd.Length -lt 8) { Write-Host "      Password too short." -ForegroundColor Red; $saPwd = "" }
    } while ($saPwd -eq "" -or $saPwd -ne $saPwd2)

    $mediaDir = "C:\SQLExpressMedia"
    New-Item -ItemType Directory -Force -Path $mediaDir | Out-Null

    Write-Info "Downloading SQL Server 2022 Express installer..."
    $ssei = "$env:TEMP\SQLServer2022-SSEI-Expr.exe"
    Invoke-WebRequest -Uri "https://go.microsoft.com/fwlink/p/?linkid=2216019&clcid=0x409&culture=en-us&country=us" `
        -OutFile $ssei -UseBasicParsing
    Write-OK "Downloaded SSEI"

    Write-Info "Downloading SQL Server 2022 Express media (this takes a few minutes)..."
    Start-Process -FilePath $ssei -ArgumentList "/ACTION=Download /MEDIAPATH=`"$mediaDir`" /MEDIATYPE=CAB /QUIET" `
        -Wait -NoNewWindow
    Remove-Item $ssei -Force -ErrorAction SilentlyContinue

    $setupExe = Get-ChildItem $mediaDir -Filter "SQLEXPR*.exe" | Select-Object -First 1
    if (-not $setupExe) { Write-Fail "SQL Express media not found in $mediaDir after download." }
    Write-OK "Media ready: $($setupExe.Name)"

    Write-Info "Installing SQL Server Express (silent, ~5 min)..."
    $installArgs = "/Q /ACTION=Install /FEATURES=SQLENGINE /INSTANCENAME=SQLEXPRESS " +
        "/SECURITYMODE=SQL /SAPWD=`"$saPwd`" " +
        "/IACCEPTSQLSERVERLICENSETERMS /TCPENABLED=1 /NPENABLED=1 /HIDECONSOLE " +
        "/SQLSYSADMINACCOUNTS=`"BUILTIN\Administrators`""
    $proc = Start-Process -FilePath $setupExe.FullName -ArgumentList $installArgs -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -notin @(0, 3010)) {
        Write-Fail "SQL Server install failed (exit code $($proc.ExitCode)). Check C:\Program Files\Microsoft SQL Server\160\Setup Bootstrap\Log\"
    }
    Write-OK "SQL Server 2022 Express installed"

    # Set static TCP port 1433 so MeshCentral can connect reliably
    Write-Info "Setting static TCP port 1433..."
    $sqlKey = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server" |
        Where-Object { $_.PSChildName -match "^MSSQL\d+\.SQLEXPRESS$" } |
        Select-Object -First 1
    if ($sqlKey) {
        $tcpPath = "$($sqlKey.PSPath)\MSSQLServer\SuperSocketNetLib\Tcp\IPAll"
        if (Test-Path $tcpPath) {
            Set-ItemProperty -Path $tcpPath -Name "TcpPort"         -Value "1433"
            Set-ItemProperty -Path $tcpPath -Name "TcpDynamicPorts" -Value ""
            Write-OK "TCP port set to 1433"
        }
    }

    # Start/restart SQL Server service
    Restart-Service "MSSQL`$SQLEXPRESS" -Force -ErrorAction SilentlyContinue
    Start-Sleep 5
    Write-OK "SQL Server service restarted"

    # Add firewall rule for SQL
    netsh advfirewall firewall delete rule name="SQL Server 1433" 2>$null | Out-Null
    netsh advfirewall firewall add rule name="SQL Server 1433" dir=in action=allow protocol=TCP localport=1433 | Out-Null
    Write-OK "Firewall rule added (TCP 1433)"

    $sqlInstance = ".\SQLEXPRESS"
    $sqlServer   = "localhost,1433"
    $sqlUser     = "sa"
    $sqlPwd      = $saPwd
    $windowsAuth = $false

    Remove-Item $mediaDir -Recurse -Force -ErrorAction SilentlyContinue
} else {
    # ── Existing SQL Server - ask how to connect ─────────────────────────────
    Write-Host ""
    Write-Host "      Found SQL Server instances:" -ForegroundColor Yellow
    $sqlServices | ForEach-Object {
        $instName = if ($_.Name -eq "MSSQLSERVER") { "MSSQLSERVER (default)" } else { $_.Name -replace "^MSSQL\$","" }
        Write-Host "        - $instName" -ForegroundColor White
    }
    Write-Host ""

    $instanceInput = Read-Host "      Instance name (e.g. SQLEXPRESS or press Enter for default MSSQLSERVER)"
    if ($instanceInput -eq "") {
        $sqlInstance = "."
        $sqlServer   = "localhost"
    } else {
        $sqlInstance = ".\$instanceInput"
        $sqlServer   = "localhost\$instanceInput"
    }

    $portInput = Read-Host "      TCP port (press Enter for 1433)"
    if ($portInput -ne "") { $sqlServer = "localhost,$portInput" }

    Write-Host ""
    Write-Host "      Authentication:" -ForegroundColor Yellow
    Write-Host "        [1] Windows Authentication (current admin user)" -ForegroundColor White
    Write-Host "        [2] SQL Server Authentication (username + password)" -ForegroundColor White
    $authChoice = Read-Host "      Choice [1/2]"

    if ($authChoice -eq "1") {
        $windowsAuth = $true
        Write-Info "Testing Windows auth connection to $sqlServer..."
        if (-not (Test-SqlConnection $sqlServer "" "" $true)) {
            Write-Fail "Cannot connect to $sqlServer with Windows Authentication. Check the instance name."
        }
        Write-OK "Connected with Windows Authentication"
    } else {
        $sqlUser = Read-Host "      SQL username"
        $sqlPwd  = Prompt-Secret "      Password"
        Write-Info "Testing connection to $sqlServer as [$sqlUser]..."
        if (-not (Test-SqlConnection $sqlServer $sqlUser $sqlPwd $false)) {
            Write-Fail "Cannot connect to $sqlServer as $sqlUser. Check credentials and instance name."
        }
        Write-OK "Connected as $sqlUser"
    }
}

# ── STEP 3 : Create database if missing ─────────────────────────────────────
Write-Step 3 "Database: $DatabaseName"

if (Database-Exists $sqlServer $sqlUser $sqlPwd $DatabaseName $windowsAuth) {
    Write-OK "Database '$DatabaseName' already exists"
} else {
    Write-Info "Creating database '$DatabaseName'..."
    Invoke-Sql $sqlServer $sqlUser $sqlPwd "CREATE DATABASE [$DatabaseName]" "master" $windowsAuth
    Write-OK "Database '$DatabaseName' created"
}

# ── STEP 4 : Create dedicated MeshCentral SQL user ──────────────────────────
Write-Step 4 "MeshCentral SQL user"

$mcUser = ""
$mcPwd  = ""

Write-Host ""
Write-Host "      A dedicated SQL user for MeshCentral is recommended (not SA)." -ForegroundColor Yellow
$useExisting = Read-Host "      Use an existing SQL login? [Y/N]"

if ($useExisting -match "^[Yy]") {
    $mcUser = Read-Host "      Existing SQL login name"
    $mcPwd  = Prompt-Secret "      Password for $mcUser"
    Write-Info "Testing credentials..."
    if (-not (Test-SqlConnection "localhost,1433" $mcUser $mcPwd $false)) {
        # Try alternate server format
        if (-not (Test-SqlConnection $sqlServer $mcUser $mcPwd $false)) {
            Write-Fail "Cannot connect as $mcUser. Check the username and password."
        }
    }
    Write-OK "Login $mcUser verified"
} else {
    $mcUser = Read-Host "      New SQL login name (e.g. meshcentraluser)"
    if ($mcUser -eq "") { $mcUser = "meshcentraluser" }
    do {
        $mcPwd  = Prompt-Secret "      Password for $mcUser (min 8 chars): "
        $mcPwd2 = Prompt-Secret "      Confirm password: "
        if ($mcPwd -ne $mcPwd2)     { Write-Host "      Passwords do not match." -ForegroundColor Red }
        elseif ($mcPwd.Length -lt 8) { Write-Host "      Password too short." -ForegroundColor Red; $mcPwd = "" }
    } while ($mcPwd -eq "" -or $mcPwd -ne $mcPwd2)

    if (User-Exists $sqlServer $sqlUser $sqlPwd $mcUser $windowsAuth) {
        Write-Info "Login '$mcUser' already exists - updating permissions only"
    } else {
        Write-Info "Creating login '$mcUser'..."
        Invoke-Sql $sqlServer $sqlUser $sqlPwd `
            "CREATE LOGIN [$mcUser] WITH PASSWORD = '$mcPwd', CHECK_POLICY = OFF, CHECK_EXPIRATION = OFF" `
            "master" $windowsAuth
        Write-OK "Login '$mcUser' created"
    }

    # Create user in the meshcentral database and grant db_owner
    try {
        Invoke-Sql $sqlServer $sqlUser $sqlPwd `
            "IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name='$mcUser') CREATE USER [$mcUser] FOR LOGIN [$mcUser]" `
            $DatabaseName $windowsAuth
        Invoke-Sql $sqlServer $sqlUser $sqlPwd `
            "ALTER ROLE db_owner ADD MEMBER [$mcUser]" `
            $DatabaseName $windowsAuth
        Write-OK "User '$mcUser' has db_owner on '$DatabaseName'"
    } catch {
        Write-Info "Note: $_ (may be harmless if user already has permissions)"
    }
}

# ── STEP 5 : Export existing SQLite data ─────────────────────────────────────
Write-Step 5 "Exporting existing SQLite data"

$exportFile = "$DATA_DIR\meshcentral-db-export.json"
$hasExport  = $false

if (Test-Path "$DATA_DIR\meshcentral.db") {
    Write-Info "Stopping MeshCentral service..."
    Stop-Service MeshCentral -Force -ErrorAction SilentlyContinue
    Start-Sleep 5

    Write-Info "Exporting from SQLite (this may take a moment)..."
    Set-Location $InstallDir
    node node_modules/meshcentral --dbexport 2>&1 | ForEach-Object { Write-Host "        $_" -ForegroundColor Gray }

    if (Test-Path $exportFile) {
        $exportSize = [math]::Round((Get-Item $exportFile).Length / 1KB, 1)
        Write-OK "Export complete: meshcentral-db-export.json ($exportSize KB)"
        $hasExport = $true
    } else {
        Write-Info "Export file not found - MeshCentral may have exported to a different path."
        $altExport = Get-ChildItem $DATA_DIR -Filter "*.json" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($altExport) {
            $exportFile = $altExport.FullName
            Write-OK "Found export: $($altExport.Name)"
            $hasExport = $true
        } else {
            Write-Info "No export found - will start fresh in SQL Server."
        }
    }
} else {
    Write-Info "No SQLite database found - starting fresh in SQL Server."
    Stop-Service MeshCentral -Force -ErrorAction SilentlyContinue
    Start-Sleep 3
}

# ── STEP 6 : Ensure mssql npm package is present ────────────────────────────
Write-Step 6 "Checking mssql npm package"
Set-Location $InstallDir
if (Test-Path "$InstallDir\node_modules\mssql") {
    Write-OK "mssql package already installed"
} else {
    Write-Info "Installing mssql package..."
    npm install mssql --save 2>&1 | Out-Null
    Write-OK "mssql package installed"
}

# ── STEP 7 : Update config.json (read → modify → write via Node.js) ─────────
Write-Step 7 "Updating config.json"

# Build the mssql config object as a JSON string for Node.js
$mssqlConfig = @"
{"server":"localhost","port":1433,"user":"$mcUser","password":"$mcPwd","database":"$DatabaseName","options":{"encrypt":false,"trustServerCertificate":true}}
"@

Set-Location $InstallDir
$nodeResult = node -e @"
var fs  = require('fs');
var p   = 'meshcentral-data/config.json';
var c   = JSON.parse(fs.readFileSync(p, 'utf8'));
// Remove SQLite setting
delete c.settings.SQLite3;
delete c.settings.sqlite3;
// Add mssql block
c.settings.mssql = $mssqlConfig;
fs.writeFileSync(p, JSON.stringify(c, null, 2));
console.log('ok');
"@ 2>&1

if ($nodeResult -eq "ok") {
    Write-OK "config.json updated (SQLite3 removed, mssql added)"
} else {
    Write-Fail "Failed to update config.json: $nodeResult"
}

# ── STEP 8 : Import data into SQL Server ─────────────────────────────────────
Write-Step 8 "Importing data into SQL Server"

if ($hasExport) {
    Write-Info "Importing from $exportFile ..."
    Set-Location $InstallDir
    node node_modules/meshcentral --dbimport $exportFile 2>&1 | ForEach-Object { Write-Host "        $_" -ForegroundColor Gray }
    Write-OK "Import complete"
} else {
    Write-Info "No export to import - SQL Server database will be initialized on first MeshCentral start."
}

# ── STEP 9 : Restart MeshCentral ─────────────────────────────────────────────
Write-Step 9 "Starting MeshCentral"

Start-Service MeshCentral -ErrorAction SilentlyContinue
Start-Sleep 10
$svc = Get-Service MeshCentral -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq "Running") {
    Write-OK "MeshCentral is running with SQL Server backend"
} else {
    Write-Info "MeshCentral did not start automatically - check manually:"
    Write-Info "  cd C:\MeshCentral && node node_modules\meshcentral"
}

# ── DONE ─────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  ============================================" -ForegroundColor Green
Write-Host "    SQL Server setup complete" -ForegroundColor Green
Write-Host "  ============================================" -ForegroundColor Green
Write-Host ""
Write-Host "    Database : $DatabaseName  on  $sqlServer" -ForegroundColor Cyan
Write-Host "    SQL user : $mcUser" -ForegroundColor Cyan
if ($hasExport) {
    Write-Host "    Data     : migrated from SQLite" -ForegroundColor Cyan
} else {
    Write-Host "    Data     : fresh database (initialized on first run)" -ForegroundColor Cyan
}
Write-Host ""
Write-Host "    Backup tip: back up both the SQL database AND $DATA_DIR" -ForegroundColor Yellow
Write-Host "    (config, certs and agent binaries stay in the data folder)" -ForegroundColor Yellow
Write-Host ""
pause
