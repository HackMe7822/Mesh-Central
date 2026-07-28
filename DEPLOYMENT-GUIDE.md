# MeshCentral Deployment Guide
### Creations IT — All Platforms, Database Migration & Backup/Restore

---

## Table of Contents

1. [Current Setup — Windows + Cloudflare](#1-current-setup--windows--cloudflare)
2. [Linux / Oracle VPS — Direct Deploy](#2-linux--oracle-vps--direct-deploy)
3. [Non-Cloudflare — Any Domain Registrar](#3-non-cloudflare--any-domain-registrar)
4. [Backup & Restore — Commands to Run on Server](#4-backup--restore--commands-to-run-on-server)
5. [Database Migration — SQLite to SQL Server / Postgres / MariaDB](#5-database-migration--sqlite-to-sql-server--postgres--mariadb)
6. [certhash Warning — Read Before Migrating](#6-certhash-warning--read-before-migrating)

---

## 1. Current Setup — Windows + Cloudflare

**Architecture:**
```
Agents → remote.creationsit.com → Cloudflare → Cloudflare Tunnel → Windows VM → MeshCentral
```

**How TLS works here:**
- Cloudflare terminates TLS. Agents see Cloudflare's certificate.
- MeshCentral gets plain HTTP from Cloudflare (that's why `tlsOffload` is set).
- The `certhash` in config.json is the SHA-384 of Cloudflare's cert — not MeshCentral's.

**Config key settings:**
```json
"settings": {
  "cert": "remote.creationsit.com",
  "port": 443,
  "tlsOffload": "127.0.0.1"
}
```

**Use this when:** You don't have a public IP on your server, or you want Cloudflare DDoS protection and CDN.

---

## 2. Linux / Oracle VPS — Direct Deploy

Oracle Cloud free tier gives you a VM with a real public IP — no tunnel needed.

### Prerequisites

```bash
# Ubuntu/Debian
sudo apt update && sudo apt install -y nodejs npm ufw

# Oracle Linux / RHEL
sudo dnf install -y nodejs npm firewalld
```

> Node.js from apt is usually outdated. Install from NodeSource:
> ```bash
> curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
> sudo apt install -y nodejs
> ```

### Open Firewall — TWO layers on Oracle Cloud

Oracle Cloud blocks traffic at two levels. Both must be opened.

**Layer 1 — Oracle Security List (in OCI Console):**
- Go to: VCN → Subnet → Security List → Ingress Rules
- Add rule: TCP port 80 (for Let's Encrypt cert renewal)
- Add rule: TCP port 443 (for MeshCentral + agents)

**Layer 2 — VM firewall (run on the VM):**
```bash
# Ubuntu/Debian
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable

# Oracle Linux
sudo firewall-cmd --permanent --add-port=80/tcp
sudo firewall-cmd --permanent --add-port=443/tcp
sudo firewall-cmd --reload
```

### Install MeshCentral

```bash
mkdir ~/meshcentral && cd ~/meshcentral
npm install meshcentral
```

### config.json for Linux Direct (NO tlsOffload, NO Cloudflare)

Create `~/meshcentral/meshcentral-data/config.json`:

```json
{
  "settings": {
    "cert": "remote.creationsit.com",
    "port": 443
  },
  "domains": {
    "": {
      "title": "Creations IT Remote Support",
      "title2": "Creations IT",
      "newAccounts": false,
      "agentInvite": true,
      "guestMode": true,
      "agentcustomization": {
        "displayname": "Creations IT Remote Support",
        "description": "Creations IT Remote Management Agent",
        "companyname": "Creations IT",
        "filename": "CreationsIT-Agent"
      }
    }
  }
}
```

> **Note:** No `tlsOffload` key. MeshCentral handles its own TLS and auto-gets a Let's Encrypt cert on first run.
> After first start, get the new certhash from the admin panel: My Server → Certificate.

### Run as a systemd service

```bash
sudo nano /etc/systemd/system/meshcentral.service
```

Paste:
```ini
[Unit]
Description=MeshCentral
After=network.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/home/ubuntu/meshcentral
ExecStart=/usr/bin/node node_modules/meshcentral
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable meshcentral
sudo systemctl start meshcentral
sudo systemctl status meshcentral
```

### About Apache

**Don't proxy MeshCentral through Apache.** MeshCentral is its own web server and uses WebSockets heavily. Apache reverse proxy adds complexity (needs `mod_proxy_wstunnel`) and causes issues with agent binary downloads and real-time KVM.

If Apache is on the same VM for other sites, run them on different ports or subdomains and let MeshCentral own port 443 directly.

---

## 3. Non-Cloudflare — Any Domain Registrar

Works for GoDaddy, Namecheap, Porkbun, Route53, or any registrar.

### DNS Setup

In your registrar's DNS panel, add:
```
A record:  remote.creationsit.com  →  <your server public IP>
```
Wait for DNS to propagate (5-30 minutes).

### Config — same as Linux Direct above

Remove `"tlsOffload"` — MeshCentral auto-gets a Let's Encrypt cert using the domain name in `"cert"`.

Port 80 must be open for Let's Encrypt HTTP-01 challenge.

### After first start — update certhash

Since the TLS cert is now Let's Encrypt (not Cloudflare), the certhash is different:

1. Log into MeshCentral admin panel
2. Go to **My Server** → **Certificate**
3. Copy the SHA384 fingerprint shown there
4. Update `config.json` → `"certhash": "<new hash>"`
5. Restart MeshCentral
6. Re-deploy agents (old agents have the old Cloudflare certhash and won't connect)

> See [Section 6](#6-certhash-warning--read-before-migrating) for full certhash migration warning.

---

## 4. Backup & Restore — Commands to Run on Server

There are two methods. Use both for safety.

---

### Method A — Folder Backup (quick, no tool needed)

**What to back up:**
```
C:\MeshCentral\meshcentral-data\     (Windows)
~/meshcentral/meshcentral-data/      (Linux)
```

This folder contains: config.json, the SQLite database, TLS certs, uploaded files, logos, and all agent customizations.

**Windows — PowerShell:**
```powershell
# Run on the MeshCentral server as Administrator
$date = Get-Date -Format "yyyy-MM-dd"
$src  = "C:\MeshCentral\meshcentral-data"
$dest = "C:\MeshCentral-Backups\meshcentral-data-$date.zip"

New-Item -ItemType Directory -Force "C:\MeshCentral-Backups" | Out-Null
Compress-Archive -Path $src -DestinationPath $dest -Force
Write-Host "Backup saved: $dest"
```

**Linux — Bash:**
```bash
DATE=$(date +%Y-%m-%d)
tar -czf ~/meshcentral-backup-$DATE.tar.gz ~/meshcentral/meshcentral-data/
echo "Backup saved: ~/meshcentral-backup-$DATE.tar.gz"
```

---

### Method B — MeshCentral DB Export (for database migration or clean restore)

This exports all users, devices, groups, sessions, and settings to a single JSON file. Use this when migrating to a new database engine.

**Where to run:** On the MeshCentral server, in the MeshCentral install directory.

**Windows:**
```powershell
# 1. Stop the service first
Stop-Service MeshCentral

# 2. Go to install directory
Set-Location C:\MeshCentral

# 3. Export — creates meshcentral-backup.json in meshcentral-data\
node node_modules\meshcentral --dbexport

# Or export to a specific path:
node node_modules\meshcentral --dbexport --dbexportfile "C:\MeshCentral-Backups\mc-export-2026-07-28.json"

# 4. Restart
Start-Service MeshCentral
```

**Linux:**
```bash
# 1. Stop service
sudo systemctl stop meshcentral

# 2. Go to install directory
cd ~/meshcentral

# 3. Export
node node_modules/meshcentral --dbexport

# Or to specific path:
node node_modules/meshcentral --dbexport --dbexportfile ~/backups/mc-export-$(date +%Y-%m-%d).json

# 4. Restart
sudo systemctl start meshcentral
```

The export file is created in `meshcentral-data/` as `meshcentral-backup.json` unless you specify `--dbexportfile`.

---

### Restore from DB Export

**Windows:**
```powershell
Stop-Service MeshCentral
Set-Location C:\MeshCentral

# Restore from export file
node node_modules\meshcentral --dbimport "C:\MeshCentral-Backups\mc-export-2026-07-28.json"

Start-Service MeshCentral
```

**Linux:**
```bash
sudo systemctl stop meshcentral
cd ~/meshcentral
node node_modules/meshcentral --dbimport ~/backups/mc-export-2026-07-28.json
sudo systemctl start meshcentral
```

---

### Automated Daily Backup — Windows Task Scheduler

Run this once to set up a daily backup at 2 AM:

```powershell
$action  = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument '-NonInteractive -ExecutionPolicy Bypass -Command "Stop-Service MeshCentral; Set-Location C:\MeshCentral; node node_modules\meshcentral --dbexport --dbexportfile \"C:\MeshCentral-Backups\mc-$(Get-Date -Format yyyy-MM-dd).json\"; Start-Service MeshCentral"'
$trigger = New-ScheduledTaskTrigger -Daily -At "02:00"
Register-ScheduledTask -TaskName "MeshCentral DB Backup" -Action $action -Trigger $trigger -RunLevel Highest -Force
```

---

## 5. Database Migration — SQLite to SQL Server / Postgres / MariaDB

### When to migrate from SQLite

Stay on SQLite until you actually hit one of these:
- 300+ agents simultaneously connected
- DB file over 5 GB
- Need multiple MeshCentral servers (HA/clustering)
- Need proper enterprise backup tooling (SQL Server Agent jobs, etc.)

For exam machine monitoring with periodic connections, SQLite is fine for years.

---

### Option A — SQL Server Express (Windows, free)

**SQL Server Express limits:** Free, 10 GB database, 1.4 GB RAM buffer, 1 CPU socket.
Sufficient for hundreds of devices.

**Step 1 — Install SQL Server Express**

Download from Microsoft: SQL Server 2022 Express
During install, choose "Basic" install type.

**Step 2 — Create database and user**

Open SQL Server Management Studio (SSMS) or run `sqlcmd`:
```sql
CREATE DATABASE meshcentral;
GO
CREATE LOGIN meshuser WITH PASSWORD = 'StrongPassword123!';
GO
USE meshcentral;
CREATE USER meshuser FOR LOGIN meshuser;
ALTER ROLE db_owner ADD MEMBER meshuser;
GO
```

**Step 3 — Export from current SQLite**
```powershell
Stop-Service MeshCentral
Set-Location C:\MeshCentral
node node_modules\meshcentral --dbexport --dbexportfile "C:\mc-migration-export.json"
```

**Step 4 — Update config.json**

Replace:
```json
"SQLite3": true
```
With:
```json
"mssql": {
  "server": "localhost",
  "database": "meshcentral",
  "user": "meshuser",
  "password": "StrongPassword123!",
  "options": {
    "trustServerCertificate": true,
    "encrypt": false
  }
}
```

**Step 5 — Install mssql npm package**
```powershell
Set-Location C:\MeshCentral
npm install mssql
```

**Step 6 — Import data**
```powershell
node node_modules\meshcentral --dbimport "C:\mc-migration-export.json"
Start-Service MeshCentral
```

---

### Option B — PostgreSQL (Linux/Windows, recommended for Linux VPS)

**Step 1 — Install PostgreSQL**
```bash
# Ubuntu
sudo apt install -y postgresql postgresql-contrib

# Start and enable
sudo systemctl enable postgresql
sudo systemctl start postgresql
```

**Step 2 — Create database and user**
```bash
sudo -u postgres psql
```
```sql
CREATE DATABASE meshcentral;
CREATE USER meshuser WITH PASSWORD 'StrongPassword123!';
GRANT ALL PRIVILEGES ON DATABASE meshcentral TO meshuser;
\q
```

**Step 3 — Export from SQLite (same as above)**
```bash
sudo systemctl stop meshcentral
cd ~/meshcentral
node node_modules/meshcentral --dbexport --dbexportfile ~/mc-migration-export.json
```

**Step 4 — Update config.json**

Replace `"SQLite3": true` with:
```json
"postgres": {
  "host": "localhost",
  "port": 5432,
  "database": "meshcentral",
  "user": "meshuser",
  "password": "StrongPassword123!"
}
```

**Step 5 — Install pg npm package**
```bash
cd ~/meshcentral
npm install pg
```

**Step 6 — Import and restart**
```bash
node node_modules/meshcentral --dbimport ~/mc-migration-export.json
sudo systemctl start meshcentral
```

---

### Option C — MariaDB / MySQL

```json
"mysql": {
  "host": "localhost",
  "port": 3306,
  "database": "meshcentral",
  "user": "meshuser",
  "password": "StrongPassword123!"
}
```
Install npm package: `npm install mysql2`

---

### Verify Migration Worked

After restart:
1. Log into MeshCentral admin panel
2. Check **My Server** → **Database** — should show the new DB type
3. Verify device groups and agents are all present
4. Check **My Server** → **Statistics** for connected agent count

---

## 6. certhash Warning — Read Before Migrating

> **This is the most important thing to understand before any platform migration.**

The `certhash` in `config.json` is the SHA-384 fingerprint of the TLS certificate that agents verify when they connect. It is **baked into each deployed agent binary at install time**.

| Scenario | certhash source | What breaks if you change it |
|----------|----------------|------------------------------|
| Current (Cloudflare) | Cloudflare's cert for `remote.creationsit.com` | Nothing — Cloudflare cert stays same even if server moves |
| Direct / Let's Encrypt | MeshCentral's Let's Encrypt cert | All existing agents refuse to connect |
| New domain | New TLS cert | All existing agents refuse to connect |

### Safe migration path

If you need to move from Cloudflare to direct/Let's Encrypt:

1. Keep your domain pointed at Cloudflare proxy — **do not bypass Cloudflare**
2. Move the backend server to Linux/new VPS
3. Update Cloudflare tunnel to point to new server
4. The cert agents see is still Cloudflare's → certhash unchanged → agents keep working

If you **must** change the certhash (new domain, dropping Cloudflare):
1. Deploy new server with new certhash
2. Keep old server running in parallel
3. Use MeshCentral's remote script execution to push `manual-install.ps1` with new installer to all connected agents
4. Shut down old server once all agents migrated

### How to find the current certhash after any change

**In MeshCentral admin panel:**
My Server → Certificate → copy SHA384 fingerprint

**Via command line (Windows):**
```powershell
# Get cert hash from the running MeshCentral cert file
$cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
$cert.Import("C:\MeshCentral\meshcentral-data\webserver-cert-public.crt")
$hash = [System.BitConverter]::ToString($cert.GetCertHash([System.Security.Cryptography.HashAlgorithmName]::SHA384)).Replace("-","").ToLower()
Write-Host $hash
```

**Via command line (Linux):**
```bash
openssl x509 -in ~/meshcentral/meshcentral-data/webserver-cert-public.crt -fingerprint -sha384 -noout
```

---

## Quick Reference — Which DB Should I Use?

| Situation | Recommendation |
|-----------|---------------|
| Under 300 agents, single server | **SQLite** — no change needed |
| 300-1000 agents, Windows server | **SQL Server Express** — free, easy |
| 300-1000 agents, Linux server | **PostgreSQL** — best on Linux |
| 1000+ agents or HA needed | **SQL Server Standard** or **PostgreSQL** |
| Already on MySQL elsewhere | **MariaDB/MySQL** — reuse existing infra |

---

*Last updated: July 2026 — Creations IT*
