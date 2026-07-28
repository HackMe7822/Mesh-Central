# Oracle Cloud Free VPS — Complete Setup Guide
### Creations IT — MeshCentral on Oracle Always Free Tier

---

## What You Get for Free (Forever)

| Resource | Always Free Spec |
|---|---|
| **ARM VM** (recommended) | 4 OCPU + 24 GB RAM total (across up to 4 VMs) |
| **AMD VM** | 2 × VM.Standard.E2.1.Micro (1 GB RAM each) |
| Storage | 200 GB block volume total |
| Bandwidth | 10 TB outbound/month |
| Public IP | 2 reserved IPs free |

> **Recommendation: Use ARM (Ampere A1).** It's far more powerful — 4 OCPU and 24 GB RAM is plenty for MeshCentral.

---

## PART 1 — Create Oracle Cloud Account

> ⚠️ Cannot be automated — requires email, phone, and credit card verification.

### Step 1 — Sign Up

1. Go to: **https://www.oracle.com/cloud/free/**
2. Click **"Start for free"**
3. Fill in:
   - Country (choose yours)
   - First and Last name
   - Email address (use a real one — you'll get a verification email)
4. Click **"Verify my email"**
5. Check your inbox — click the verification link

### Step 2 — Fill Account Details

After email verification:
- **Account Name**: anything (e.g. `CreationsIT`)
- **Home Region**: ⚠️ **CHOOSE CAREFULLY — THIS CANNOT BE CHANGED EVER**
  
  Recommended regions by location:
  | Location | Best Region |
  |---|---|
  | USA | US East (Ashburn) — most ARM availability |
  | Canada | Canada Southeast (Montreal) |
  | UK/Europe | UK South (London) or Germany Central (Frankfurt) |
  | India | India West (Mumbai) |
  | Australia | Australia East (Sydney) |

- **Password**: set a strong password

### Step 3 — Add Payment Method

- Oracle requires a credit/debit card for identity verification
- **You will NOT be charged** as long as you only use Always Free resources
- They may do a $1 authorization hold that reverses in a few days
- Accepted: Visa, Mastercard, Amex

### Step 4 — Phone Verification

- Enter your phone number
- Receive SMS code → enter it

### Step 5 — Account Activation

- After submitting, you'll see "Thank you! Your account is being provisioned"
- This takes **5 minutes to 4 hours** (usually ~10 minutes)
- You'll get an email when ready: "Your Oracle Cloud account is fully provisioned"

### Step 6 — First Login

1. Go to **https://cloud.oracle.com**
2. Enter your **Cloud Account Name** (what you set in Step 2)
3. Click "Next" → enter email/password
4. You're in the OCI Console

---

## PART 2 — Create SSH Key Pair

You need this to connect to your VM. Do this on your local machine.

**Windows (PowerShell):**
```powershell
# Generate SSH key pair
ssh-keygen -t ed25519 -C "meshcentral-oracle" -f "$env:USERPROFILE\.ssh\oracle_key"

# This creates:
#   ~/.ssh/oracle_key       (private key — keep secret)
#   ~/.ssh/oracle_key.pub   (public key — upload to Oracle)

# Show the public key (you'll need this later)
Get-Content "$env:USERPROFILE\.ssh\oracle_key.pub"
```

**Linux/Mac:**
```bash
ssh-keygen -t ed25519 -C "meshcentral-oracle" -f ~/.ssh/oracle_key
cat ~/.ssh/oracle_key.pub
```

Copy the `.pub` content — it looks like:
```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... meshcentral-oracle
```

---

## PART 3 — Option A: Create VM via OCI Console (Manual, No CLI Needed)

If you don't want to install the OCI CLI, create the VM through the web console.

### Step 1 — Open Compute Instances

OCI Console → Hamburger menu (top-left) → **Compute** → **Instances** → **Create Instance**

### Step 2 — Configure VM

| Setting | Value |
|---|---|
| **Name** | `meshcentral-vm` |
| **Compartment** | your root compartment |
| **Availability Domain** | any (try AD-1 first for ARM) |
| **Image** | Click "Change Image" → **Canonical Ubuntu** → **22.04** |
| **Shape** | Click "Change Shape" → **Ampere** → **VM.Standard.A1.Flex** |
| **OCPU** | 2 (or 4 — both free) |
| **Memory** | 12 GB (or 24 GB — both free) |
| **VCN** | Create new VCN (let Oracle create defaults) |
| **Subnet** | Create new public subnet |
| **Public IP** | Yes — Assign public IPv4 |
| **SSH Keys** | Paste your `.pub` key content |

### Step 3 — Create

Click **Create** → VM provisions in 2-4 minutes → status goes **Running**

Copy the **Public IP Address** from the instance details page.

### Step 4 — Open Firewall Ports in OCI Console

The VM has a Security List that blocks all ports except 22 (SSH) by default.

OCI Console → **Networking** → **Virtual Cloud Networks** → your VCN
→ **Subnets** → your subnet → **Security Lists** → **Default Security List**
→ **Add Ingress Rules**

Add each rule:
```
Rule 1:
  Source Type:    CIDR
  Source CIDR:    0.0.0.0/0
  IP Protocol:    TCP
  Dest Port:      80

Rule 2:
  Source Type:    CIDR
  Source CIDR:    0.0.0.0/0
  IP Protocol:    TCP
  Dest Port:      443
```

Click **Add Ingress Rules**.

### Step 5 — Connect via SSH

```powershell
# Windows
ssh -i "$env:USERPROFILE\.ssh\oracle_key" ubuntu@<YOUR-PUBLIC-IP>
```
```bash
# Linux/Mac
ssh -i ~/.ssh/oracle_key ubuntu@<YOUR-PUBLIC-IP>
```

---

## PART 4 — Option B: Auto-Provision via Script (After Account Exists)

Once your Oracle Cloud account is active, our `oracle-provision.sh` script creates everything automatically:
- VCN, subnet, internet gateway, route table
- Security list with ports 22/80/443
- ARM VM (Ubuntu 22.04)
- Reserved public IP

### Install OCI CLI

**Windows:**
```powershell
# Run in PowerShell as Administrator
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
(New-Object System.Net.WebClient).DownloadFile("https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.ps1", "$env:TEMP\install-oci.ps1")
powershell -ExecutionPolicy Bypass -File "$env:TEMP\install-oci.ps1" --accept-all-defaults
```

**Linux/Mac:**
```bash
bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)"
```

### Configure OCI CLI

```bash
oci setup config
```
It asks for:
- **User OCID**: OCI Console → top-right avatar → User Settings → copy OCID
- **Tenancy OCID**: OCI Console → top-right avatar → Tenancy → copy OCID  
- **Region**: your home region (e.g. `us-ashburn-1`)
- **Generate new API key**: Yes → saves to `~/.oci/oci_api_key.pem`

### Upload API Key to Oracle

After `oci setup config`, it shows the public key fingerprint and path.

OCI Console → top-right avatar → **User Settings** → **API Keys** → **Add API Key**
→ Paste contents of `~/.oci/oci_api_key_public.pem` → **Add**

### Test CLI works

```bash
oci iam region list --output table
```
Should list all Oracle Cloud regions.

### Run Provisioning Script

```bash
# Download
curl -fsSL https://raw.githubusercontent.com/HackMe7822/Mesh-Central/main/oracle-provision.sh -o oracle-provision.sh

# Run
bash oracle-provision.sh
```

The script asks:
- VM name
- SSH public key path
- Number of OCPUs (1-4, all free)
- RAM in GB (1-24, all free)

At the end it prints your **public IP** and the exact **SSH command** to connect.

---

## PART 5 — After VM is Running

### Run MeshCentral Installer

SSH into the VM, then:

```bash
curl -fsSL https://raw.githubusercontent.com/HackMe7822/Mesh-Central/main/install.sh -o install.sh
sudo bash install.sh
```

The installer handles Node.js, MeshCentral, firewall, and your chosen URL method.

### Reserve Your Public IP (So It Never Changes)

By default Oracle assigns a temporary public IP that could change if you stop the VM.

OCI Console → **Compute** → **Instances** → your VM → **Attached VNICs**
→ your VNIC → **IPv4 Addresses** → the IP → **Edit**
→ Change **Ephemeral** to **Reserved** → **Update**

Now your IP is permanent. Useful for DuckDNS and direct domain setups.

---

## Quick Reference — SSH Commands After Setup

```bash
# Connect
ssh -i ~/.ssh/oracle_key ubuntu@<YOUR-IP>

# Run MeshCentral installer
sudo bash install.sh

# Check MeshCentral status
sudo systemctl status meshcentral

# View logs
sudo journalctl -u meshcentral -f

# Run backup
sudo bash backup.sh
```

---

## Common Issues

| Problem | Fix |
|---|---|
| SSH: Permission denied | Check key path, use `ubuntu@IP` not `root@IP` |
| Can't reach port 443 | OCI Security List — add ingress rule for 443 (often forgotten) |
| ARM instance unavailable | Try different Availability Domain (AD-1, AD-2, AD-3) |
| Account not activating | Check spam folder, wait up to 4 hours |
| "Out of capacity" for ARM | Try again later or try a different AD |

---

*Last updated: July 2026 — Creations IT*
