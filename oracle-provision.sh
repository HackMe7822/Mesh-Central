#!/usr/bin/env bash
# =============================================================================
#  Oracle Cloud Free Tier — Auto Provisioner
#  Creates: VCN + subnet + internet gateway + security list + ARM Ubuntu VM
#  Requires: OCI CLI installed and configured (oci setup config)
#  Usage: bash oracle-provision.sh
# =============================================================================
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; WHITE='\033[1;37m'; NC='\033[0m'

print_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
print_info() { echo -e "${CYAN}[..]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WW]${NC} $1"; }
print_step() { echo -e "\n${BOLD}${WHITE}━━━  $1  ━━━${NC}"; }
print_fail() { echo -e "${RED}[!!] $1${NC}"; exit 1; }

clear
echo -e "${BOLD}${CYAN}"
echo "  ╔══════════════════════════════════════════════╗"
echo "  ║   Oracle Cloud Free VM Provisioner           ║"
echo "  ║   Creations IT — MeshCentral Platform        ║"
echo "  ╚══════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Check OCI CLI ─────────────────────────────────────────────────────────────
command -v oci &>/dev/null || print_fail "OCI CLI not found. Install it first: https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm"

print_step "Checking OCI CLI configuration"
if ! oci iam region list &>/dev/null 2>&1; then
    print_fail "OCI CLI not configured or API key not uploaded to Oracle.\nRun: oci setup config\nThen upload the public key to OCI Console → User Settings → API Keys"
fi
print_ok "OCI CLI is working"

# ── Get tenancy and region ─────────────────────────────────────────────────────
TENANCY_OCID=$(oci iam region-subscription list --query 'data[0]."region-name"' --raw-output 2>/dev/null || true)
TENANCY_OCID=$(oci iam compartment list --compartment-id-in-subtree true --access-level ACCESSIBLE \
    --query 'data[0]."compartment-id"' --raw-output 2>/dev/null || true)

# Simpler: get from config file
OCI_CONFIG="${HOME}/.oci/config"
if [ -f "$OCI_CONFIG" ]; then
    TENANCY_OCID=$(grep -m1 "^tenancy=" "$OCI_CONFIG" | cut -d'=' -f2 | tr -d ' \r')
    REGION=$(grep -m1 "^region=" "$OCI_CONFIG" | cut -d'=' -f2 | tr -d ' \r')
else
    print_fail "OCI config not found at ~/.oci/config — run: oci setup config"
fi

print_ok "Tenancy: $TENANCY_OCID"
print_ok "Region:  $REGION"

# Use root compartment
COMPARTMENT_ID="$TENANCY_OCID"

# ── Gather input ──────────────────────────────────────────────────────────────
print_step "Configuration"

echo -e "${CYAN}[?]${NC} VM name? [default: meshcentral-vm]"
read -r _in; VM_NAME="${_in:-meshcentral-vm}"

echo -e "${CYAN}[?]${NC} Path to SSH public key? [default: ~/.ssh/oracle_key.pub]"
read -r _in; SSH_KEY_PATH="${_in:-$HOME/.ssh/oracle_key.pub}"

if [ ! -f "$SSH_KEY_PATH" ]; then
    print_warn "Key not found at $SSH_KEY_PATH"
    echo -e "${CYAN}[?]${NC} Generate a new key pair now? (y/n) [default: y]"
    read -r _in
    if [[ "${_in:-y}" =~ ^[Yy] ]]; then
        KEY_BASE="${SSH_KEY_PATH%.pub}"
        ssh-keygen -t ed25519 -C "meshcentral-oracle" -f "$KEY_BASE" -N ""
        SSH_KEY_PATH="${KEY_BASE}.pub"
        print_ok "SSH key generated: $KEY_BASE"
        echo ""
        echo -e "${YELLOW}  SAVE THIS PRIVATE KEY PATH:${NC}  $KEY_BASE"
        echo -e "${YELLOW}  SSH command will be:${NC}  ssh -i $KEY_BASE ubuntu@<IP>"
        echo ""
    else
        print_fail "No SSH public key available."
    fi
fi

SSH_PUBLIC_KEY=$(cat "$SSH_KEY_PATH")
SSH_PRIVATE_KEY="${SSH_KEY_PATH%.pub}"

echo -e "${CYAN}[?]${NC} Number of OCPUs? (1-4, all free on ARM) [default: 2]"
read -r _in; OCPUS="${_in:-2}"

echo -e "${CYAN}[?]${NC} RAM in GB? (1-24, all free on ARM) [default: 12]"
read -r _in; MEMORY_GB="${_in:-12}"

echo ""
print_ok "VM Name:  $VM_NAME"
print_ok "Shape:    VM.Standard.A1.Flex (ARM — Always Free)"
print_ok "OCPUs:    $OCPUS"
print_ok "Memory:   ${MEMORY_GB} GB"
print_ok "Image:    Ubuntu 22.04 LTS"
echo ""
echo -e "${CYAN}[?]${NC} Confirm — press Enter to start provisioning (Ctrl+C to cancel)..."
read -r

# ── Get availability domain ────────────────────────────────────────────────────
print_step "Finding Availability Domain"

AD_LIST=$(oci iam availability-domain list --compartment-id "$COMPARTMENT_ID" \
    --query 'data[*].name' --raw-output 2>/dev/null || echo "")

if [ -z "$AD_LIST" ]; then
    print_fail "Could not list availability domains. Check your OCI CLI permissions."
fi

# Try each AD (ARM instances may not be available in all ADs)
AD_NAME=$(oci iam availability-domain list --compartment-id "$COMPARTMENT_ID" \
    --query 'data[0].name' --raw-output 2>/dev/null)

print_ok "Availability Domain: $AD_NAME"

# ── Find Ubuntu 22.04 ARM image ───────────────────────────────────────────────
print_step "Finding Ubuntu 22.04 ARM Image"

print_info "Searching for latest Ubuntu 22.04 ARM image..."
IMAGE_OCID=$(oci compute image list \
    --compartment-id "$COMPARTMENT_ID" \
    --operating-system "Canonical Ubuntu" \
    --operating-system-version "22.04" \
    --shape "VM.Standard.A1.Flex" \
    --query 'data[0].id' --raw-output 2>/dev/null || echo "")

# Fallback: search without shape filter
if [ -z "$IMAGE_OCID" ] || [ "$IMAGE_OCID" = "null" ]; then
    print_info "Trying broader image search..."
    IMAGE_OCID=$(oci compute image list \
        --compartment-id "$COMPARTMENT_ID" \
        --operating-system "Canonical Ubuntu" \
        --operating-system-version "22.04" \
        --sort-by TIMECREATED --sort-order DESC \
        --query 'data[0].id' --raw-output 2>/dev/null || echo "")
fi

[ -z "$IMAGE_OCID" ] || [ "$IMAGE_OCID" = "null" ] && \
    print_fail "Could not find Ubuntu 22.04 image. Try running: oci compute image list --compartment-id $COMPARTMENT_ID --operating-system 'Canonical Ubuntu'"

print_ok "Image OCID: $IMAGE_OCID"

# ── Create VCN ────────────────────────────────────────────────────────────────
print_step "Creating VCN"

VCN_NAME="${VM_NAME}-vcn"
print_info "Creating VCN: $VCN_NAME ..."
VCN_OCID=$(oci network vcn create \
    --compartment-id "$COMPARTMENT_ID" \
    --display-name "$VCN_NAME" \
    --cidr-block "10.0.0.0/16" \
    --dns-label "meshvcn" \
    --wait-for-state AVAILABLE \
    --query 'data.id' --raw-output 2>/dev/null)

[ -z "$VCN_OCID" ] && print_fail "Failed to create VCN"
print_ok "VCN created: $VCN_OCID"

# ── Create Internet Gateway ───────────────────────────────────────────────────
print_step "Creating Internet Gateway"

IGW_OCID=$(oci network internet-gateway create \
    --compartment-id "$COMPARTMENT_ID" \
    --vcn-id "$VCN_OCID" \
    --display-name "${VM_NAME}-igw" \
    --is-enabled true \
    --wait-for-state AVAILABLE \
    --query 'data.id' --raw-output 2>/dev/null)

[ -z "$IGW_OCID" ] && print_fail "Failed to create Internet Gateway"
print_ok "Internet Gateway created: $IGW_OCID"

# ── Update Route Table ────────────────────────────────────────────────────────
print_step "Configuring Route Table"

# Get default route table
RT_OCID=$(oci network route-table list \
    --compartment-id "$COMPARTMENT_ID" \
    --vcn-id "$VCN_OCID" \
    --query 'data[0].id' --raw-output 2>/dev/null)

oci network route-table update \
    --rt-id "$RT_OCID" \
    --route-rules "[{\"cidrBlock\":\"0.0.0.0/0\",\"networkEntityId\":\"$IGW_OCID\"}]" \
    --force \
    --wait-for-state AVAILABLE &>/dev/null

print_ok "Route Table updated — default route via Internet Gateway"

# ── Update Security List — open ports 22, 80, 443 ────────────────────────────
print_step "Configuring Security List (Firewall)"

SL_OCID=$(oci network security-list list \
    --compartment-id "$COMPARTMENT_ID" \
    --vcn-id "$VCN_OCID" \
    --query 'data[0].id' --raw-output 2>/dev/null)

INGRESS_RULES='[
  {"source":"0.0.0.0/0","protocol":"6","isStateless":false,"tcpOptions":{"destinationPortRange":{"min":22,"max":22}}},
  {"source":"0.0.0.0/0","protocol":"6","isStateless":false,"tcpOptions":{"destinationPortRange":{"min":80,"max":80}}},
  {"source":"0.0.0.0/0","protocol":"6","isStateless":false,"tcpOptions":{"destinationPortRange":{"min":443,"max":443}}},
  {"source":"0.0.0.0/0","protocol":"1","isStateless":false,"icmpOptions":{"type":3,"code":4}}
]'

oci network security-list update \
    --security-list-id "$SL_OCID" \
    --ingress-security-rules "$INGRESS_RULES" \
    --force \
    --wait-for-state AVAILABLE &>/dev/null

print_ok "Security List updated — ports 22 (SSH), 80 (HTTP), 443 (HTTPS) open"

# ── Create Subnet ─────────────────────────────────────────────────────────────
print_step "Creating Subnet"

SUBNET_OCID=$(oci network subnet create \
    --compartment-id "$COMPARTMENT_ID" \
    --vcn-id "$VCN_OCID" \
    --display-name "${VM_NAME}-subnet" \
    --cidr-block "10.0.0.0/24" \
    --availability-domain "$AD_NAME" \
    --dns-label "meshsubnet" \
    --wait-for-state AVAILABLE \
    --query 'data.id' --raw-output 2>/dev/null)

[ -z "$SUBNET_OCID" ] && print_fail "Failed to create subnet"
print_ok "Subnet created: $SUBNET_OCID"

# ── Create VM ─────────────────────────────────────────────────────────────────
print_step "Creating VM Instance (this takes 2-4 minutes)"

print_info "Launching $VM_NAME with $OCPUS OCPU / ${MEMORY_GB}GB ARM..."

INSTANCE_OCID=$(oci compute instance launch \
    --compartment-id "$COMPARTMENT_ID" \
    --availability-domain "$AD_NAME" \
    --display-name "$VM_NAME" \
    --image-id "$IMAGE_OCID" \
    --shape "VM.Standard.A1.Flex" \
    --shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEMORY_GB}" \
    --subnet-id "$SUBNET_OCID" \
    --assign-public-ip true \
    --ssh-authorized-keys-file "$SSH_KEY_PATH" \
    --wait-for-state RUNNING \
    --query 'data.id' --raw-output 2>/dev/null)

if [ -z "$INSTANCE_OCID" ] || [ "$INSTANCE_OCID" = "null" ]; then
    echo ""
    print_warn "ARM launch may have failed — 'Out of capacity' is common."
    echo ""
    echo "  Options:"
    echo "  1. Try again (capacity frees up throughout the day)"

    # Get all ADs and suggest others
    echo "  2. Try a different Availability Domain:"
    oci iam availability-domain list --compartment-id "$COMPARTMENT_ID" \
        --query 'data[*].name' --raw-output 2>/dev/null | tr ',' '\n' | \
        awk '{print "     "$0}'

    echo "  3. Try fewer OCPUs/RAM"
    echo ""
    print_fail "Instance creation failed. See suggestions above."
fi

print_ok "Instance created: $INSTANCE_OCID"
print_info "Waiting for instance to reach RUNNING state..."

# ── Get public IP ─────────────────────────────────────────────────────────────
print_step "Getting Public IP"

sleep 10  # Give time for VNIC attachment

PUBLIC_IP=$(oci compute instance list-vnics \
    --instance-id "$INSTANCE_OCID" \
    --query 'data[0]."public-ip"' --raw-output 2>/dev/null || echo "")

# Retry up to 30 seconds
for i in $(seq 1 6); do
    if [ -n "$PUBLIC_IP" ] && [ "$PUBLIC_IP" != "null" ]; then
        break
    fi
    sleep 5
    PUBLIC_IP=$(oci compute instance list-vnics \
        --instance-id "$INSTANCE_OCID" \
        --query 'data[0]."public-ip"' --raw-output 2>/dev/null || echo "")
done

if [ -z "$PUBLIC_IP" ] || [ "$PUBLIC_IP" = "null" ]; then
    PUBLIC_IP="(check OCI Console — Compute → Instances → $VM_NAME)"
fi

# ── Reserve the public IP so it never changes ─────────────────────────────────
print_step "Reserving Public IP (permanent)"

VNIC_OCID=$(oci compute instance list-vnics \
    --instance-id "$INSTANCE_OCID" \
    --query 'data[0].id' --raw-output 2>/dev/null || echo "")

if [ -n "$VNIC_OCID" ] && [ "$VNIC_OCID" != "null" ]; then
    PRIV_IP_OCID=$(oci network private-ip list \
        --vnic-id "$VNIC_OCID" \
        --query 'data[0].id' --raw-output 2>/dev/null || echo "")

    if [ -n "$PRIV_IP_OCID" ] && [ "$PRIV_IP_OCID" != "null" ]; then
        oci network public-ip create \
            --compartment-id "$COMPARTMENT_ID" \
            --lifetime RESERVED \
            --private-ip-id "$PRIV_IP_OCID" &>/dev/null && \
            print_ok "Public IP reserved — will never change" || \
            print_warn "Could not reserve IP automatically — do it in OCI Console"
    fi
fi

# ── Save connection details ───────────────────────────────────────────────────
CONN_FILE="${HOME}/meshcentral-oracle-${VM_NAME}.txt"
cat > "$CONN_FILE" << EOF
MeshCentral Oracle VM — $VM_NAME
Created: $(date)
Region:  $REGION
AD:      $AD_NAME

Instance OCID:  $INSTANCE_OCID
VCN OCID:       $VCN_OCID
Public IP:      $PUBLIC_IP

SSH Command:
  ssh -i $SSH_PRIVATE_KEY ubuntu@$PUBLIC_IP

Next step — install MeshCentral:
  ssh -i $SSH_PRIVATE_KEY ubuntu@$PUBLIC_IP
  curl -fsSL https://raw.githubusercontent.com/HackMe7822/Mesh-Central/main/install.sh -o install.sh
  sudo bash install.sh
EOF

print_ok "Connection details saved: $CONN_FILE"

# ── Final summary ─────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}"
echo "  ╔══════════════════════════════════════════════════════════╗"
echo "  ║             VM PROVISIONING COMPLETE                    ║"
echo "  ╚══════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  ${BOLD}Public IP:${NC}    $PUBLIC_IP"
echo -e "  ${BOLD}Shape:${NC}        VM.Standard.A1.Flex (ARM, $OCPUS OCPU / ${MEMORY_GB} GB)"
echo -e "  ${BOLD}OS:${NC}           Ubuntu 22.04 LTS"
echo -e "  ${BOLD}Region:${NC}       $REGION"
echo ""
echo -e "  ${BOLD}${WHITE}Connect via SSH:${NC}"
echo "    ssh -i $SSH_PRIVATE_KEY ubuntu@$PUBLIC_IP"
echo ""
echo -e "  ${BOLD}${WHITE}Install MeshCentral (run after SSH):${NC}"
echo "    curl -fsSL https://raw.githubusercontent.com/HackMe7822/Mesh-Central/main/install.sh -o install.sh"
echo "    sudo bash install.sh"
echo ""
echo -e "  ${BOLD}${WHITE}One-liner (SSH + install in one command):${NC}"
echo "    ssh -i $SSH_PRIVATE_KEY ubuntu@$PUBLIC_IP 'curl -fsSL https://raw.githubusercontent.com/HackMe7822/Mesh-Central/main/install.sh | sudo bash'"
echo ""
echo -e "  ${YELLOW}NOTE: Wait 2-3 minutes before SSHing — Ubuntu needs time to finish boot.${NC}"
echo ""
echo -e "  ${BOLD}Details saved to:${NC} $CONN_FILE"
echo ""
