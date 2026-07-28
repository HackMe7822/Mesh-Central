#!/usr/bin/env bash
# =============================================================================
#  MeshCentral Linux Installer — Creations IT
#  Supports: Ubuntu 20/22/24, Oracle Linux 8/9, RHEL 8/9, Debian 11/12
#  URL methods: Cloudflare Tunnel | Own Domain (Let's Encrypt) | DuckDNS
# =============================================================================
set -uo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; WHITE='\033[1;37m'; BOLD='\033[1m'; NC='\033[0m'

print_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
print_info() { echo -e "${CYAN}[..]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WW]${NC} $1"; }
print_step() { echo -e "\n${BOLD}${WHITE}━━━  $1  ━━━${NC}"; }
print_fail() { echo -e "${RED}[!!] $1${NC}"; exit 1; }
ask()        { echo -e "${CYAN}[?]${NC} $1"; }

# ── Root check ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && print_fail "Run as root: sudo bash install.sh"

# ── Banner ────────────────────────────────────────────────────────────────────
clear
echo -e "${BOLD}${CYAN}"
echo "  ╔══════════════════════════════════════════════╗"
echo "  ║   MeshCentral Linux Installer                ║"
echo "  ║   Creations IT — Remote Support Platform     ║"
echo "  ╚══════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Detect distro ─────────────────────────────────────────────────────────────
detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO_ID="${ID:-unknown}"
        DISTRO_LIKE="${ID_LIKE:-}"
    else
        DISTRO_ID="unknown"
        DISTRO_LIKE=""
    fi

    if [[ "$DISTRO_ID" == "ubuntu" || "$DISTRO_ID" == "debian" || "$DISTRO_LIKE" == *"debian"* ]]; then
        PKG_MGR="apt"
    elif [[ "$DISTRO_ID" == "ol" || "$DISTRO_ID" == "rhel" || "$DISTRO_ID" == "centos" || \
            "$DISTRO_ID" == "fedora" || "$DISTRO_LIKE" == *"rhel"* || "$DISTRO_LIKE" == *"fedora"* ]]; then
        PKG_MGR="dnf"
    else
        print_warn "Unknown distro '$DISTRO_ID' — assuming apt"
        PKG_MGR="apt"
    fi

    # Firewall
    if command -v ufw &>/dev/null; then
        FIREWALL="ufw"
    elif command -v firewall-cmd &>/dev/null; then
        FIREWALL="firewalld"
    else
        FIREWALL="none"
    fi

    print_ok "Distro: $DISTRO_ID | Package manager: $PKG_MGR | Firewall: $FIREWALL"
}

# ── Get public IP ─────────────────────────────────────────────────────────────
get_public_ip() {
    PUBLIC_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || \
                curl -s --max-time 5 https://checkip.amazonaws.com 2>/dev/null || \
                echo "UNKNOWN")
    PUBLIC_IP="${PUBLIC_IP// /}"
    print_ok "Server public IP: $PUBLIC_IP"
}

# =============================================================================
#  STEP 1 — GATHER INPUT
# =============================================================================
gather_input() {
    print_step "STEP 1 — Configuration"

    # Company / brand name
    ask "Company/brand name for the portal? [default: Creations IT]"
    read -r _input; COMPANY_NAME="${_input:-Creations IT}"

    # Short name used for file names (no spaces)
    COMPANY_SLUG=$(echo "$COMPANY_NAME" | tr ' ' '-' | tr '[:upper:]' '[:lower:]')

    # Install directory
    ask "Install directory? [default: /opt/meshcentral]"
    read -r _input; INSTALL_DIR="${_input:-/opt/meshcentral}"

    # Admin credentials
    ask "Admin username? [default: admin]"
    read -r _input; ADMIN_USER="${_input:-admin}"

    while true; do
        ask "Admin password? (min 8 chars)"
        read -rs ADMIN_PASS; echo
        [[ ${#ADMIN_PASS} -ge 8 ]] && break
        print_warn "Password too short — minimum 8 characters."
    done

    ask "Admin email?"
    read -r ADMIN_EMAIL

    echo ""
    print_ok "Company:    $COMPANY_NAME"
    print_ok "Install:    $INSTALL_DIR"
    print_ok "Admin user: $ADMIN_USER"
    print_ok "Admin email: $ADMIN_EMAIL"
}

# =============================================================================
#  STEP 2 — CHOOSE URL / DOMAIN METHOD
# =============================================================================
choose_url_method() {
    print_step "STEP 2 — URL / Domain Method"

    echo ""
    echo -e "  ${BOLD}[1]${NC} Cloudflare Tunnel        — use your domain via Cloudflare (e.g. remote.creationsit.com)"
    echo -e "       Same setup as Windows. Agents keep working if migrating from Windows."
    echo ""
    echo -e "  ${BOLD}[2]${NC} Own Domain — Direct       — point any domain A record to this server"
    echo -e "       MeshCentral auto-gets a free Let's Encrypt SSL cert."
    echo ""
    echo -e "  ${BOLD}[3]${NC} DuckDNS (free subdomain)  — yourname.duckdns.org, free SSL, no domain needed"
    echo -e "       Sign up free at duckdns.org. Good for new deployments."
    echo ""

    while true; do
        ask "Choose [1/2/3]:"
        read -r URL_METHOD
        [[ "$URL_METHOD" =~ ^[123]$ ]] && break
        print_warn "Enter 1, 2, or 3."
    done

    case "$URL_METHOD" in
    1)  # Cloudflare Tunnel
        ask "Domain name for MeshCentral? [default: remote.creationsit.com]"
        read -r _input; DOMAIN="${_input:-remote.creationsit.com}"

        ask "Cloudflare Tunnel name? [default: ${COMPANY_SLUG}-vm]"
        read -r _input; TUNNEL_NAME="${_input:-${COMPANY_SLUG}-vm}"

        CF_API_TOKEN=""
        echo ""
        echo -e "  ${YELLOW}Option A${NC}: Provide a Cloudflare API token → script creates DNS automatically."
        echo -e "  ${YELLOW}Option B${NC}: Skip token → script prints manual DNS steps at the end."
        ask "Cloudflare API token? (press Enter to skip and do DNS manually)"
        read -r CF_API_TOKEN

        # tlsOffload because Cloudflare terminates TLS
        USE_TLS_OFFLOAD=true
        ;;
    2)  # Own domain direct
        ask "Your domain name (e.g. mesh.yourcompany.com):"
        read -r DOMAIN
        [[ -z "$DOMAIN" ]] && print_fail "Domain cannot be empty for this option."
        TUNNEL_NAME=""
        CF_API_TOKEN=""
        USE_TLS_OFFLOAD=false
        ;;
    3)  # DuckDNS
        ask "DuckDNS subdomain name (just the part before .duckdns.org):"
        read -r DUCKDNS_SUBDOMAIN
        [[ -z "$DUCKDNS_SUBDOMAIN" ]] && print_fail "Subdomain cannot be empty."

        ask "DuckDNS API token (from duckdns.org after login):"
        read -r DUCKDNS_TOKEN
        [[ -z "$DUCKDNS_TOKEN" ]] && print_fail "DuckDNS token cannot be empty."

        DOMAIN="${DUCKDNS_SUBDOMAIN}.duckdns.org"
        TUNNEL_NAME=""
        CF_API_TOKEN=""
        USE_TLS_OFFLOAD=false
        ;;
    esac

    echo ""
    print_ok "Domain/URL:  https://$DOMAIN"
    print_ok "Method:      $([ "$URL_METHOD" = "1" ] && echo 'Cloudflare Tunnel' || [ "$URL_METHOD" = "2" ] && echo 'Direct / Let'\''s Encrypt' || echo 'DuckDNS')"
}

# =============================================================================
#  STEP 3 — INSTALL NODE.JS
# =============================================================================
install_nodejs() {
    print_step "STEP 3 — Node.js LTS"

    if command -v node &>/dev/null; then
        NODE_VER=$(node --version)
        print_ok "Node.js already installed: $NODE_VER"
        return
    fi

    if [[ "$PKG_MGR" == "apt" ]]; then
        print_info "Installing Node.js LTS via NodeSource (apt)..."
        curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
        apt-get install -y nodejs
    else
        print_info "Installing Node.js LTS via NodeSource (dnf)..."
        curl -fsSL https://rpm.nodesource.com/setup_lts.x | bash -
        dnf install -y nodejs
    fi

    print_ok "Node.js installed: $(node --version)"
    print_ok "npm: $(npm --version)"
}

# =============================================================================
#  STEP 4 — INSTALL MESHCENTRAL
# =============================================================================
install_meshcentral() {
    print_step "STEP 4 — MeshCentral"

    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"

    if [ -d "$INSTALL_DIR/node_modules/meshcentral" ]; then
        print_ok "MeshCentral already installed — skipping npm install"
    else
        print_info "Running npm install meshcentral (1-3 min)..."
        npm install meshcentral
        print_ok "MeshCentral installed"
    fi

    # Create data dir
    mkdir -p "$INSTALL_DIR/meshcentral-data/public"
}

# =============================================================================
#  STEP 5 — WRITE CONFIG.JSON
# =============================================================================
write_config() {
    print_step "STEP 5 — config.json"

    local cfg_path="$INSTALL_DIR/meshcentral-data/config.json"

    # Preserve existing certhash if config already exists
    EXISTING_CERTHASH=""
    if [ -f "$cfg_path" ]; then
        EXISTING_CERTHASH=$(grep -oP '"certhash"\s*:\s*"\K[a-fA-F0-9]+' "$cfg_path" 2>/dev/null || echo "")
        if [ -n "$EXISTING_CERTHASH" ]; then
            print_info "Preserving existing certhash from config"
        fi
    fi

    # Build settings block
    if [ "$USE_TLS_OFFLOAD" = true ]; then
        SETTINGS_BLOCK='"cert": "'"$DOMAIN"'", "port": 443, "tlsOffload": "127.0.0.1"'
    else
        SETTINGS_BLOCK='"cert": "'"$DOMAIN"'", "port": 443'
    fi

    # Build certhash line
    if [ -n "$EXISTING_CERTHASH" ]; then
        CERTHASH_LINE='"certhash": "'"$EXISTING_CERTHASH"'",'
    else
        CERTHASH_LINE=""
    fi

    cat > "$cfg_path" << EOF
{
  "settings": {
    $SETTINGS_BLOCK,
    "SQLite3": true
  },
  "domains": {
    "": {
      "title": "$COMPANY_NAME Remote Support",
      "title2": "$COMPANY_NAME",
      "newAccounts": false,
      "agentInvite": true,
      "guestMode": true,
      $CERTHASH_LINE
      "agentcustomization": {
        "displayname": "$COMPANY_NAME Remote Support",
        "description": "$COMPANY_NAME Remote Management Agent",
        "companyname": "$COMPANY_NAME",
        "filename": "${COMPANY_SLUG}-Agent"
      },
      "agentFileInfo": {
        "filedescription": "$COMPANY_NAME Remote Agent",
        "fileversion": "1.0.0",
        "productname": "$COMPANY_NAME Remote Support",
        "productversion": "1.0.0"
      }
    }
  }
}
EOF

    print_ok "config.json written: $cfg_path"
}

# =============================================================================
#  STEP 6 — BRANDING LOGO
# =============================================================================
download_logo() {
    print_step "STEP 6 — Branding"

    local pub_dir="$INSTALL_DIR/meshcentral-data/public"
    mkdir -p "$pub_dir"

    # Try to download Creations IT logo from the deploy repo
    if curl -fsSL -o "$pub_dir/CreationsIT.png" \
        "https://raw.githubusercontent.com/HackMe7822/Mesh-Central/main/CreationsIT.ico" 2>/dev/null; then
        print_ok "Logo downloaded"
    else
        print_warn "Logo download skipped — upload manually to: $pub_dir/"
    fi
}

# =============================================================================
#  STEP 7 — CREATE ADMIN ACCOUNT
# =============================================================================
create_admin() {
    print_step "STEP 7 — Admin Account"

    cd "$INSTALL_DIR"

    print_info "Creating admin account: $ADMIN_USER ..."
    node node_modules/meshcentral --createaccount "$ADMIN_USER" \
        --pass "$ADMIN_PASS" --email "$ADMIN_EMAIL" 2>/dev/null || true

    print_info "Granting admin rights..."
    node node_modules/meshcentral --adminaccount "$ADMIN_USER" 2>/dev/null || true

    print_ok "Admin account ready: $ADMIN_USER"
}

# =============================================================================
#  STEP 8 — SYSTEMD SERVICE
# =============================================================================
create_service() {
    print_step "STEP 8 — systemd Service"

    cat > /etc/systemd/system/meshcentral.service << EOF
[Unit]
Description=MeshCentral Remote Management
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=/usr/bin/node node_modules/meshcentral
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable meshcentral
    systemctl start meshcentral
    sleep 3

    if systemctl is-active --quiet meshcentral; then
        print_ok "MeshCentral service running"
    else
        print_warn "MeshCentral may still be starting — check: systemctl status meshcentral"
    fi
}

# =============================================================================
#  STEP 9 — FIREWALL
# =============================================================================
open_firewall() {
    print_step "STEP 9 — Firewall"

    if [[ "$FIREWALL" == "ufw" ]]; then
        ufw allow 80/tcp  comment "MeshCentral / Let's Encrypt" 2>/dev/null || true
        ufw allow 443/tcp comment "MeshCentral HTTPS" 2>/dev/null || true
        ufw --force enable 2>/dev/null || true
        print_ok "ufw: ports 80 and 443 opened"

    elif [[ "$FIREWALL" == "firewalld" ]]; then
        systemctl start firewalld 2>/dev/null || true
        firewall-cmd --permanent --add-port=80/tcp  2>/dev/null || true
        firewall-cmd --permanent --add-port=443/tcp 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
        print_ok "firewalld: ports 80 and 443 opened"

    else
        print_warn "No firewall detected — open ports 80 and 443 manually"
    fi

    # iptables fallback (Oracle Linux often needs this too)
    if command -v iptables &>/dev/null; then
        iptables -I INPUT -p tcp --dport 80  -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
        print_ok "iptables rules added"
    fi
}

# =============================================================================
#  STEP 10A — CLOUDFLARE TUNNEL SETUP
# =============================================================================
setup_cloudflare() {
    print_step "STEP 10 — Cloudflare Tunnel"

    # Install cloudflared
    print_info "Downloading cloudflared..."
    if [[ "$PKG_MGR" == "apt" ]]; then
        curl -fsSL -o /tmp/cloudflared.deb \
            "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb"
        dpkg -i /tmp/cloudflared.deb
        rm -f /tmp/cloudflared.deb
    else
        curl -fsSL -o /tmp/cloudflared.rpm \
            "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.rpm"
        rpm -ivh /tmp/cloudflared.rpm 2>/dev/null || dnf localinstall -y /tmp/cloudflared.rpm
        rm -f /tmp/cloudflared.rpm
    fi
    print_ok "cloudflared installed: $(cloudflared --version)"

    # Authenticate
    echo ""
    echo -e "${YELLOW}━━━  Cloudflare Authentication  ━━━${NC}"
    echo ""
    echo "  cloudflared will now print a URL."
    echo "  Open that URL in your browser on your local machine to log in."
    echo "  After login the script continues automatically."
    echo ""
    read -rp "  Press Enter when ready..."
    cloudflared tunnel login

    # Create tunnel
    print_info "Creating tunnel: $TUNNEL_NAME ..."
    TUNNEL_OUTPUT=$(cloudflared tunnel create "$TUNNEL_NAME" 2>&1)
    echo "$TUNNEL_OUTPUT"
    TUNNEL_ID=$(echo "$TUNNEL_OUTPUT" | grep -oP 'tunnel\s+id\s*\K[a-f0-9-]{36}' 2>/dev/null || \
                cloudflared tunnel list 2>/dev/null | grep "$TUNNEL_NAME" | awk '{print $1}' || echo "")

    if [ -z "$TUNNEL_ID" ]; then
        print_warn "Could not auto-detect tunnel ID — check 'cloudflared tunnel list' after install"
        TUNNEL_ID="PASTE-TUNNEL-ID-HERE"
    else
        print_ok "Tunnel ID: $TUNNEL_ID"
    fi

    # Write cloudflared config
    mkdir -p /etc/cloudflared
    CREDS_FILE=$(ls /root/.cloudflared/${TUNNEL_ID}.json 2>/dev/null || echo "/root/.cloudflared/${TUNNEL_ID}.json")

    cat > /etc/cloudflared/config.yml << EOF
tunnel: $TUNNEL_ID
credentials-file: $CREDS_FILE
ingress:
  - hostname: $DOMAIN
    service: https://localhost:443
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
    print_ok "cloudflared config written: /etc/cloudflared/config.yml"

    # Route DNS automatically if API token provided
    if [ -n "$CF_API_TOKEN" ]; then
        print_info "Creating Cloudflare DNS CNAME via API..."
        CF_ZONE=$(echo "$DOMAIN" | awk -F'.' '{print $(NF-1)"."$NF}')
        ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$CF_ZONE" \
            -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" | \
            grep -oP '"id"\s*:\s*"\K[a-z0-9]+' | head -1)

        if [ -n "$ZONE_ID" ]; then
            cloudflared tunnel route dns "$TUNNEL_NAME" "$DOMAIN"
            print_ok "DNS CNAME created automatically"
        else
            print_warn "Could not find zone for $DOMAIN via API — add DNS record manually (see steps at end)"
        fi
    else
        print_info "No API token — DNS must be added manually (steps printed at end)"
    fi

    # Install as system service
    cloudflared service install
    systemctl enable cloudflared
    systemctl start cloudflared
    sleep 3

    if systemctl is-active --quiet cloudflared; then
        print_ok "cloudflared service running"
    else
        print_warn "cloudflared may still be starting — check: systemctl status cloudflared"
    fi

    TUNNEL_ID_SAVED="$TUNNEL_ID"
}

# =============================================================================
#  STEP 10B — DUCKDNS SETUP
# =============================================================================
setup_duckdns() {
    print_step "STEP 10 — DuckDNS"

    print_info "Updating DuckDNS IP to $PUBLIC_IP ..."
    RESULT=$(curl -s "https://www.duckdns.org/update?domains=${DUCKDNS_SUBDOMAIN}&token=${DUCKDNS_TOKEN}&ip=${PUBLIC_IP}")

    if [[ "$RESULT" == "OK" ]]; then
        print_ok "DuckDNS updated: $DOMAIN → $PUBLIC_IP"
    else
        print_warn "DuckDNS update returned: $RESULT — check token and subdomain"
    fi

    # Add cron job for IP auto-update every 5 minutes
    CRON_CMD="*/5 * * * * curl -s 'https://www.duckdns.org/update?domains=${DUCKDNS_SUBDOMAIN}&token=${DUCKDNS_TOKEN}&ip=' > /dev/null 2>&1"
    (crontab -l 2>/dev/null | grep -v "duckdns.org"; echo "$CRON_CMD") | crontab -
    print_ok "Cron job added: DuckDNS IP update every 5 minutes"
}

# =============================================================================
#  GET CERTHASH
# =============================================================================
get_certhash() {
    CERTHASH=""
    local cert_file="$INSTALL_DIR/meshcentral-data/webserver-cert-public.crt"

    # Wait up to 15s for cert to be generated
    for i in $(seq 1 15); do
        if [ -f "$cert_file" ]; then
            CERTHASH=$(openssl x509 -in "$cert_file" -fingerprint -sha384 -noout 2>/dev/null | \
                       sed 's/SHA384 Fingerprint=//' | tr -d ':' | tr '[:upper:]' '[:lower:]')
            break
        fi
        sleep 1
    done

    if [ -z "$CERTHASH" ]; then
        CERTHASH="(not yet generated — MeshCentral generates this on first start; check admin panel: My Server → Certificate)"
    fi
}

# =============================================================================
#  PRINT MANUAL STEPS SUMMARY
# =============================================================================
print_manual_steps() {
    get_certhash

    echo ""
    echo -e "${BOLD}${GREEN}"
    echo "  ╔══════════════════════════════════════════════════════════════╗"
    echo "  ║             INSTALLATION COMPLETE                           ║"
    echo "  ╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    echo -e "${BOLD}${WHITE}  Server Info${NC}"
    echo "  ──────────────────────────────────────────"
    echo "  Public IP:    $PUBLIC_IP"
    echo "  URL:          https://$DOMAIN"
    echo "  Install dir:  $INSTALL_DIR"
    echo "  Admin user:   $ADMIN_USER"
    echo "  certhash:     $CERTHASH"
    echo ""

    # ── Method-specific manual steps ──────────────────────────────────────────
    if [[ "$URL_METHOD" == "1" ]]; then
        echo -e "${BOLD}${YELLOW}  Manual Steps — Cloudflare DNS${NC}"
        echo "  ──────────────────────────────────────────"
        if [ -z "$CF_API_TOKEN" ]; then
            echo ""
            echo "  DNS was NOT created automatically (no API token provided)."
            echo "  Add this DNS record in your Cloudflare dashboard:"
            echo ""
            echo "    Cloudflare Dashboard → yourdomain.com → DNS → Add Record"
            echo "    Type:    CNAME"
            echo "    Name:    $(echo $DOMAIN | cut -d'.' -f1)"
            echo "    Target:  ${TUNNEL_ID_SAVED:-<tunnel-id>}.cfargotunnel.com"
            echo "    Proxy:   ON (orange cloud)"
            echo ""
            echo "  OR run this on the server:"
            echo "    cloudflared tunnel route dns $TUNNEL_NAME $DOMAIN"
            echo ""
        else
            echo "  DNS CNAME was created automatically via API."
            echo ""
        fi
        echo "  Verify tunnel is running:"
        echo "    systemctl status cloudflared"
        echo ""
        echo "  View tunnel logs:"
        echo "    journalctl -u cloudflared -f"
        echo ""
        echo -e "  ${YELLOW}NOTE: certhash is Cloudflare's cert (not MeshCentral's).${NC}"
        echo "  Get it from admin panel after login: My Server → Certificate"

    elif [[ "$URL_METHOD" == "2" ]]; then
        echo -e "${BOLD}${YELLOW}  Manual Steps — DNS A Record${NC}"
        echo "  ──────────────────────────────────────────"
        echo ""
        echo "  Add this DNS record at your domain registrar (GoDaddy, Namecheap, etc.):"
        echo ""
        echo "    Type:  A"
        echo "    Name:  $(echo $DOMAIN | cut -d'.' -f1)   (or @ if it's the root domain)"
        echo "    Value: $PUBLIC_IP"
        echo "    TTL:   300 (or Auto)"
        echo ""
        echo "  DNS propagation: usually 5-30 minutes, up to 48h max."
        echo ""
        echo "  Check propagation:   dig $DOMAIN +short"
        echo "                  or:  nslookup $DOMAIN"
        echo ""
        echo "  SSL cert: MeshCentral auto-gets Let's Encrypt cert on first connect."
        echo "  Port 80 must be open for the Let's Encrypt challenge to work."
        echo ""
        echo -e "  ${YELLOW}IMPORTANT — After DNS propagates:${NC}"
        echo "  1. Open https://$DOMAIN in browser"
        echo "  2. Log in as $ADMIN_USER"
        echo "  3. Go to My Server → Certificate"
        echo "  4. Copy SHA384 fingerprint → update certhash in config.json"
        echo "  5. Restart: systemctl restart meshcentral"

    elif [[ "$URL_METHOD" == "3" ]]; then
        echo -e "${BOLD}${YELLOW}  Manual Steps — DuckDNS${NC}"
        echo "  ──────────────────────────────────────────"
        echo ""
        echo "  DuckDNS was updated automatically to: $PUBLIC_IP"
        echo ""
        echo "  If you haven't created the subdomain yet:"
        echo "    1. Go to https://www.duckdns.org"
        echo "    2. Sign in (Google or GitHub)"
        echo "    3. Create subdomain: $DUCKDNS_SUBDOMAIN"
        echo "    4. Your token: $DUCKDNS_TOKEN"
        echo ""
        echo "  Verify DNS:  dig $DOMAIN +short"
        echo ""
        echo "  SSL cert: MeshCentral auto-gets Let's Encrypt cert on first connect."
        echo "  Port 80 must be open for the Let's Encrypt challenge."
        echo ""
        echo "  Auto IP update: cron job set — runs every 5 minutes."
    fi

    echo ""
    echo -e "${BOLD}${YELLOW}  Oracle Cloud — IMPORTANT EXTRA STEP${NC}"
    echo "  ──────────────────────────────────────────"
    echo "  Oracle Cloud blocks traffic in BOTH the VM firewall AND the cloud Security List."
    echo "  The script opened the VM firewall. You MUST also open ports in OCI Console:"
    echo ""
    echo "    OCI Console → Networking → Virtual Cloud Networks → your VCN"
    echo "    → Subnets → your subnet → Security Lists → Default Security List"
    echo "    → Add Ingress Rule:"
    echo ""
    echo "      Source CIDR:  0.0.0.0/0"
    echo "      IP Protocol:  TCP"
    echo "      Dest Port:    80"
    echo ""
    echo "      Source CIDR:  0.0.0.0/0"
    echo "      IP Protocol:  TCP"
    echo "      Dest Port:    443"
    echo ""
    echo "  Without this, agents CANNOT connect even if the VM firewall is open."

    echo ""
    echo -e "${BOLD}${WHITE}  Next Steps Checklist${NC}"
    echo "  ──────────────────────────────────────────"
    echo "  [ ] Open https://$DOMAIN — confirm login page loads"
    echo "  [ ] Log in as $ADMIN_USER"
    echo "  [ ] Go to My Account → Two Factor Auth (Google/Microsoft Authenticator)"
    echo "  [ ] Get certhash: My Server → Certificate → copy SHA384"
    echo "  [ ] Update config.json with certhash: $INSTALL_DIR/meshcentral-data/config.json"
    echo "  [ ] Restart after certhash update: systemctl restart meshcentral"
    echo "  [ ] Create device groups: Devices → Add Group"
    echo "  [ ] Download agent installer: Devices → Add Device → Windows"
    echo "  [ ] (Optional) Oracle Cloud: open ports 80 + 443 in OCI Security Lists"
    echo ""
    echo -e "${BOLD}${WHITE}  Useful Commands${NC}"
    echo "  ──────────────────────────────────────────"
    echo "  Status:   systemctl status meshcentral"
    echo "  Logs:     journalctl -u meshcentral -f"
    echo "  Restart:  systemctl restart meshcentral"
    echo "  Config:   $INSTALL_DIR/meshcentral-data/config.json"
    echo "  Backups:  See backup.sh (run: bash backup.sh)"
    echo ""
}

# =============================================================================
#  MAIN
# =============================================================================
main() {
    detect_distro
    get_public_ip
    gather_input
    choose_url_method

    echo ""
    echo -e "${BOLD}Starting installation...${NC}"
    echo ""

    install_nodejs
    install_meshcentral
    write_config
    download_logo
    create_admin
    create_service
    open_firewall

    # URL-method-specific setup
    case "$URL_METHOD" in
        1) setup_cloudflare ;;
        3) setup_duckdns ;;
        2) print_info "Direct mode — Let's Encrypt cert will be obtained on first browser visit" ;;
    esac

    print_manual_steps
}

main "$@"
