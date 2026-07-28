#!/usr/bin/env bash
# MeshCentral Linux Backup — folder snapshot + dbexport
# Usage: sudo bash backup.sh [--install-dir /opt/meshcentral] [--backup-dir /var/backups/meshcentral]
#        sudo bash backup.sh --folder-only
#        sudo bash backup.sh --export-only

[[ $EUID -ne 0 ]] && echo "[!!] Run as root: sudo bash backup.sh" && exit 1

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
print_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
print_info() { echo -e "${CYAN}[..]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WW]${NC} $1"; }

INSTALL_DIR="/opt/meshcentral"
BACKUP_DIR="/var/backups/meshcentral"
FOLDER_ONLY=false
EXPORT_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --install-dir) INSTALL_DIR="$2"; shift 2 ;;
        --backup-dir)  BACKUP_DIR="$2";  shift 2 ;;
        --folder-only) FOLDER_ONLY=true; shift ;;
        --export-only) EXPORT_ONLY=true; shift ;;
        *) echo "Unknown arg: $1"; shift ;;
    esac
done

DATA_DIR="$INSTALL_DIR/meshcentral-data"
DATE=$(date +"%Y-%m-%d_%H-%M")

[ ! -d "$DATA_DIR" ] && echo "[!!] meshcentral-data not found at $DATA_DIR" && exit 1
mkdir -p "$BACKUP_DIR"

# ── Method 1: Folder tar.gz snapshot ──────────────────────────────────────────
if [ "$EXPORT_ONLY" = false ]; then
    ZIP_PATH="$BACKUP_DIR/meshcentral-data-$DATE.tar.gz"
    print_info "Creating folder snapshot: $ZIP_PATH ..."
    tar -czf "$ZIP_PATH" -C "$(dirname $DATA_DIR)" "$(basename $DATA_DIR)" 2>/dev/null
    SIZE=$(du -sh "$ZIP_PATH" | cut -f1)
    print_ok "Folder snapshot saved: $ZIP_PATH  ($SIZE)"
fi

# ── Method 2: DB export JSON ──────────────────────────────────────────────────
if [ "$FOLDER_ONLY" = false ]; then
    EXPORT_PATH="$BACKUP_DIR/meshcentral-dbexport-$DATE.json"
    SVC_WAS_RUNNING=false

    if systemctl is-active --quiet meshcentral 2>/dev/null; then
        SVC_WAS_RUNNING=true
        print_info "Stopping MeshCentral for DB export..."
        systemctl stop meshcentral
        sleep 3
    fi

    print_info "Running DB export → $EXPORT_PATH ..."
    cd "$INSTALL_DIR"
    node node_modules/meshcentral --dbexport --dbexportfile "$EXPORT_PATH" 2>/dev/null || true

    if [ -f "$EXPORT_PATH" ]; then
        SIZE=$(du -sh "$EXPORT_PATH" | cut -f1)
        print_ok "DB export saved: $EXPORT_PATH  ($SIZE)"
    else
        print_warn "DB export ran but file not found — check meshcentral-data/ for meshcentral-backup.json"
    fi

    if [ "$SVC_WAS_RUNNING" = true ]; then
        print_info "Restarting MeshCentral..."
        systemctl start meshcentral
        sleep 2
        systemctl is-active --quiet meshcentral && print_ok "MeshCentral running" || print_warn "Check: systemctl status meshcentral"
    fi
fi

# ── Cleanup: keep last 14 days ────────────────────────────────────────────────
print_info "Removing backups older than 14 days..."
find "$BACKUP_DIR" -type f \( -name "*.tar.gz" -o -name "*.json" \) -mtime +14 -delete
print_ok "Cleanup done"

echo ""
print_ok "=== Backup Complete: $BACKUP_DIR ==="
ls -lh "$BACKUP_DIR" | tail -6
