# Creations IT — MeshCentral Deploy

One-click deployer for the Creations IT remote support platform (MeshCentral) on a Windows VM.
Publishes to **mesh.creationsit.com** via a Cloudflare Tunnel.

---

## One-Line Install

Run **as Administrator** in PowerShell on the target VM:

```powershell
iwr -useb https://raw.githubusercontent.com/HackMe7822/Mesh-Central/main/install.ps1 | iex
```

Or to skip Cloudflare setup (e.g. re-running after it is already configured):

```powershell
iwr -useb https://raw.githubusercontent.com/HackMe7822/Mesh-Central/main/install.ps1 -OutFile install.ps1
.\install.ps1 -SkipCloudflare
```

---

## What the Script Does

| Step | Action |
|------|--------|
| 1 | Installs Node.js LTS (via winget) |
| 2 | Creates `C:\MeshCentral` directory tree |
| 3 | Runs `npm install meshcentral` |
| 4 | Writes `config.json` — branded as **Creations IT** |
| 5 | Copies `logo.png` / `logo.ico` from the script folder |
| 6 | Creates the admin account (interactive prompt) |
| 7 | Installs MeshCentral as a Windows service (auto-start) |
| 8 | Opens firewall ports 443 and 80 |
| 9 | Installs `cloudflared` (via winget) |
| 10 | Opens browser for Cloudflare auth |
| 11 | Creates a fresh Cloudflare Tunnel named `meshcentral` |
| 12 | Creates DNS CNAME `mesh.creationsit.com` → tunnel |
| 13 | Installs `cloudflared` as a Windows service (auto-start) |

---

## Adding Your Logo (Required for Full Branding)

The agent installer and web UI both use your logo. After cloning:

1. Place `logo.png` (web UI header — recommended 200×60 px, transparent PNG) in the **repo root**
2. Place `logo.ico` (agent installer icon — 256×256 multi-size ICO) in the **repo root**
3. Commit and push

The script automatically copies them to `C:\MeshCentral\meshcentral-data\public\` during install.

If you run the install script before adding logos, copy them manually:

```
C:\MeshCentral\meshcentral-data\public\logo.png
C:\MeshCentral\meshcentral-data\public\logo.ico
```

Then restart the service: `sc stop MeshCentral` then `sc start MeshCentral`

---

## VM Requirements

| Spec | Minimum |
|------|---------|
| OS | Windows 11 Pro or Windows Server 2022 |
| CPU | 2 vCPU |
| RAM | 4 GB |
| Disk | 40 GB |
| Network | Bridged adapter (internet access required) |
| winget | Must be available (built into Win 11; install App Installer on Server 2022) |

---

## Architecture

```
Internet
    │
    ▼
mesh.creationsit.com  (Cloudflare DNS — CNAME to tunnel)
    │
    ▼
Cloudflare Tunnel     (cloudflared service on VM)
    │
    ▼
localhost:443         (MeshCentral Windows service)
    │
    ▼
Managed Devices       (MeshCentral agents)
```

> **Important:** If the VM is OFF, the entire service is OFF. Cloudflare Tunnel only provides secure
> public access — it does not host or keep MeshCentral alive on its own.

---

## Post-Install Checklist

- [ ] Open https://mesh.creationsit.com — confirm **Creations IT** login page
- [ ] Log in and go to **My Account → Two Factor Authentication** (use Microsoft or Google Authenticator)
- [ ] Create device groups: **Servers**, **Workstations**, **Clients**
- [ ] Deploy agents: **Devices → Add Agent → Windows**
- [ ] Schedule regular backup of `C:\MeshCentral\meshcentral-data\`
- [ ] Verify both services survive a reboot: `sc query MeshCentral` and `sc query cloudflared`

---

## Troubleshooting

**MeshCentral service won't start**
```cmd
sc query MeshCentral
cd C:\MeshCentral
node node_modules\meshcentral
```
Run interactively to see startup errors.

**Port 443 already in use**
```cmd
netstat -ano | findstr :443
```
Check if IIS or another service holds the port and stop it.

**Cloudflare tunnel not connecting**
```cmd
sc query cloudflared
cloudflared --config "C:\cloudflared\config.yml" tunnel run meshcentral
```
Run interactively to see the error.

**Web UI shows MeshCentral branding instead of Creations IT**
- Confirm `config.json` is correct: `type C:\MeshCentral\meshcentral-data\config.json`
- Confirm `logo.png` exists: `dir C:\MeshCentral\meshcentral-data\public\`
- Restart the service and hard-refresh the browser (Ctrl+Shift+R)

---

## Backup

Back up this folder regularly — it contains all users, device groups, agents, and configuration:

```
C:\MeshCentral\meshcentral-data\
```

---

## Re-deploying on a New VM

The script handles a fresh Cloudflare Tunnel each time (deletes the old tunnel name and recreates it,
then updates DNS). You will need to re-authenticate with Cloudflare in the browser during setup.
