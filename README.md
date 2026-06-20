# Creations IT - MeshCentral Deploy

One-click deployer for the Creations IT remote support platform on a Windows VM.
Publishes to **remote.creationsit.com** via a Cloudflare Tunnel (one tunnel, multiple apps).

---

## One-Line Install

Run **as Administrator** in PowerShell on the target VM:

```powershell
iwr "https://raw.githubusercontent.com/HackMe7822/Mesh-Central/main/install.ps1" -OutFile "C:\deploy.ps1"
powershell -ExecutionPolicy Bypass -File "C:\deploy.ps1"
```

> **Do NOT pipe through iex** - always download first, then run with -File.

---

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-Domain` | `remote.creationsit.com` | Public hostname for MeshCentral |
| `-TunnelName` | `creationsit-vm` | Cloudflare Tunnel name (shared by all apps on this VM) |
| `-AdminUser` | (prompted) | MeshCentral admin username |
| `-AdminEmail` | (prompted) | MeshCentral admin email |
| `-InstallDir` | `C:\MeshCentral` | Where MeshCentral is installed |
| `-SkipCloudflare` | off | Skip Cloudflare tunnel setup |
| `-SkipNodeInstall` | off | Skip Node.js install |
| `-UpdateOnly` | off | Rewrite config + logo, restart service only |

Example with custom params:
```powershell
powershell -ExecutionPolicy Bypass -File "C:\deploy.ps1" -Domain "remote.creationsit.com" -TunnelName "creationsit-vm"
```

---

## What the Script Does

| Step | Action |
|------|--------|
| 1 | Installs Node.js LTS (MSI from nodejs.org) |
| 2 | Creates C:\MeshCentral directory tree |
| 3 | Runs npm install meshcentral |
| 4 | Writes config.json - branded as Creations IT |
| 5 | Downloads CreationsIT.ico from this repo |
| 6 | Creates the admin account (prompted) |
| 7 | Installs MeshCentral as a Windows service (auto-start, no visible window) |
| 8 | Opens firewall ports 443 and 80 |
| 9 | Installs latest cloudflared MSI |
| 10 | Opens browser for Cloudflare auth |
| 11 | Creates Cloudflare Tunnel named creationsit-vm |
| 12 | Creates DNS CNAME remote.creationsit.com to tunnel |
| 13 | Installs cloudflared as a Windows service (auto-start, no visible window) |

---

## Architecture

```
Internet
    |
    v
remote.creationsit.com  (Cloudflare DNS -- CNAME to tunnel)
crm.creationsit.com     (future app, same tunnel)
files.creationsit.com   (future app, same tunnel)
    |
    v
Cloudflare Tunnel: creationsit-vm  (one tunnel for all apps)
    |
    v
cloudflared Windows service (C:\cloudflared\config.yml)
    |
    +-- remote.creationsit.com --> https://localhost:443 (MeshCentral)
    +-- crm.creationsit.com    --> http://localhost:3000  (future CRM)
    +-- files.creationsit.com  --> http://localhost:8080  (future files)
    |
    v
MeshCentral Windows service (C:\MeshCentral)
    |
    v
Managed Devices (MeshCentral agents)
```

> **One tunnel, multiple apps.** Add new apps by editing C:\cloudflared\config.yml
> and running: cloudflared tunnel route dns creationsit-vm newapp.creationsit.com

---

## Adding a New App to the Tunnel

1. Deploy the new app on any local port (e.g. CRM on port 3000)
2. Edit `C:\cloudflared\config.yml` - add before the final `service: http_status:404` line:
   ```yaml
   - hostname: crm.creationsit.com
     service: http://localhost:3000
   ```
3. Create the DNS record:
   ```cmd
   cloudflared tunnel route dns creationsit-vm crm.creationsit.com
   ```
4. Restart the tunnel service:
   ```cmd
   Restart-Service cloudflared
   ```

---

## Post-Install Checklist

- [ ] Open https://remote.creationsit.com -- confirm Creations IT login page loads
- [ ] Log in and go to My Account > Two Factor Authentication (use Microsoft or Google Authenticator)
- [ ] Create device groups: Servers, Workstations, Clients
- [ ] Deploy agents: Devices > Add Agent > Windows
- [ ] Schedule regular backup of C:\MeshCentral\meshcentral-data\
- [ ] Verify both services survive a reboot:
      sc query MeshCentral
      sc query cloudflared

---

## Troubleshooting

**MeshCentral service won't start**
```cmd
sc query MeshCentral
cd C:\MeshCentral
node node_modules\meshcentral
```

**Port 443 already in use**
```cmd
netstat -ano | findstr :443
```

**Cloudflare tunnel not connecting**
```cmd
sc query cloudflared
cloudflared --config "C:\cloudflared\config.yml" tunnel run creationsit-vm
```

**Web UI shows wrong branding**
- Check config: type C:\MeshCentral\meshcentral-data\config.json
- Check logo: dir C:\MeshCentral\meshcentral-data\public\
- Restart service and hard-refresh browser (Ctrl+Shift+R)

**Re-run after partial failure**
```powershell
iwr "https://raw.githubusercontent.com/HackMe7822/Mesh-Central/main/install.ps1" -OutFile "C:\deploy.ps1"
powershell -ExecutionPolicy Bypass -File "C:\deploy.ps1"
```
The script always deletes and recreates the tunnel, so it is safe to re-run.

---

## Backup

Back up this folder regularly (users, device groups, agents, config):
```
C:\MeshCentral\meshcentral-data\
```

---

## VM Requirements

| Spec | Minimum |
|------|---------|
| OS | Windows Server 2019/2022 or Windows 11 Pro |
| CPU | 2 vCPU |
| RAM | 4 GB |
| Disk | 40 GB |
| Network | Internet access required |
