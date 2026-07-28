#!/usr/bin/env bash
# MeshCentral Linux Restore — from tar.gz snapshot or dbexport JSON
# Usage: sudo bash restore.sh [--file /var/backups/meshcentral/file.tar.gz]
#        sudo bash restore.sh  (interactive picker)

[[ $EUID -ne 0 ]] && echo "[!!] Run as root: sudo bash restore.sh" && exit 1

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
print_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
print_info() { echo -e "${CYAN}[..]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WW]${NC} $1"; }
print_fail() { echo -e "${RED}[!!]${NC} $1"; exit 1; }

INSTALL_DIR="/opt/meshcentral"
BACKUP_DIR="/var/backups/meshcentral"
BACKUP_FILE=""
FORCE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --install-dir) INSTALL_DIR="$2"; shift 2 ;;
        --backup-dir)  BACKUP_DIR="$2";  shift 2 ;;
        --file)        BACKUP_FILE="$2"; shift 2 ;;
        --force)       FORCE=true; shift ;;
        *) echo "Unknown arg: $1"; shift ;;
    esac
done

DATA_DIR="$INSTALL_DIR/meshcentral-data"

# ── Pick backup file if not specified ─────────────────────────────────────────
if [ -z "$BACKUP_FILE" ]; then
    [ ! -d "$BACKUP_DIR" ] && print_fail "No --file provided and backup dir not found: $BACKUP_DIR"

    mapfile -t FILES < <(find "$BACKUP_DIR" -maxdepth 1 -type f \( -name "*.tar.gz" -o -name "*.json" \) | sort -r | head -10)
    [ ${#FILES[@]} -eq 0 ] && print_fail "No backup files found in: $BACKUP_DIR"

    echo ""
    echo -e "${CYAN}Available backups:${NC}"
    for i in "${!FILES[@]}"; do
        SIZE=$(du -sh "${FILES[$i]}" | cut -f1)
        MTIME=$(stat -c "%y" "${FILES[$i]}" | cut -d'.' -f1)
        printf "  [%d] %s  (%s)  %s\n" $((i+1)) "$(basename ${FILES[$i]})" "$SIZE" "$MTIME"
    done
    echo ""
    read -rp "Enter number to restore (or q to quit): " CHOICE
    [[ "$CHOICE" == "q" || "$CHOICE" == "Q" ]] && exit 0
    IDX=$((CHOICE-1))
    [[ $IDX -lt 0 || $IDX -ge ${#FILES[@]} ]] && print_fail "Invalid selection"
    BACKUP_FILE="${FILES[$IDX]}"
fi

[ ! -f "$BACKUP_FILE" ] && print_fail "File not found: $BACKUP_FILE"

EXT="${BACKUP_FILE##*.}"
NAME=$(basename "$BACKUP_FILE")
SIZE=$(du -sh "$BACKUP_FILE" | cut -f1)

echo ""
echo -e "${YELLOW}=== MeshCentral Restore ===${NC}"
echo "  File:    $NAME  ($SIZE)"
echo "  Type:    $([ "$EXT" = "gz" ] && echo 'Folder Snapshot (tar.gz)' || echo 'DB Export (JSON)')"
echo "  Target:  $INSTALL_DIR"
echo ""

if [ "$FORCE" = false ]; then
    read -rp "  This OVERWRITES current data. Type YES to continue: " CONFIRM
    [[ "$CONFIRM" != "YES" ]] && echo "Cancelled." && exit 0
fi

# ── Stop service ──────────────────────────────────────────────────────────────
SVC_WAS_RUNNING=false
if systemctl is-active --quiet meshcentral 2>/dev/null; then
    SVC_WAS_RUNNING=true
    print_info "Stopping MeshCentral..."
    systemctl stop meshcentral
    sleep 3
fi

# ── Restore ───────────────────────────────────────────────────────────────────
if [[ "$BACKUP_FILE" == *.tar.gz ]]; then
    # Folder snapshot restore
    print_info "Extracting folder snapshot..."

    STAGING=$(mktemp -d)
    tar -xzf "$BACKUP_FILE" -C "$STAGING"

    # Find meshcentral-data in extracted contents
    EXTRACTED=$(find "$STAGING" -maxdepth 2 -type d -name "meshcentral-data" | head -1)
    [ -z "$EXTRACTED" ] && rm -rf "$STAGING" && print_fail "meshcentral-data not found inside archive"

    # Move existing data aside
    if [ -d "$DATA_DIR" ]; then
        OLD="${DATA_DIR}-OLD-$(date +%H%M%S)"
        print_info "Moving existing data to: $OLD"
        mv "$DATA_DIR" "$OLD"
    fi

    cp -r "$EXTRACTED" "$DATA_DIR"
    rm -rf "$STAGING"
    print_ok "Folder snapshot restored to: $DATA_DIR"

elif [[ "$BACKUP_FILE" == *.json ]]; then
    # DB export restore
    print_info "Running DB import from: $BACKUP_FILE ..."
    cd "$INSTALL_DIR"
    node node_modules/meshcentral --dbimport "$BACKUP_FILE"
    print_ok "DB import complete"

else
    print_fail "Unknown file type: .$EXT  (must be .tar.gz or .json)"
fi

# ── Restart service ───────────────────────────────────────────────────────────
if [ "$SVC_WAS_RUNNING" = true ]; then
    print_info "Starting MeshCentral..."
    systemctl start meshcentral
    sleep 5
    if systemctl is-active --quiet meshcentral; then
        print_ok "MeshCentral is running"
    else
        print_warn "Check status: systemctl status meshcentral"
    fi
fi

echo ""
print_ok "=== Restore Complete ==="
echo "  Open https://your-domain and verify all data is present."
