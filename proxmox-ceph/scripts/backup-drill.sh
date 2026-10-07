#!/usr/bin/env bash
# =====================================================================
# Cerberus — scripts/backup-drill.sh
#
# GUIDED PBS restore drill. Implements runbook §07 drill (d).
#
# Flow (with a confirmation prompt at EVERY consequential step):
#   1. Resolve PBS connection details (env or interactive; the token is
#      read without echo and never printed).
#   2. List snapshots for a chosen VMID.
#   3. Restore ONE chosen disk archive to a SCRATCH path — never onto
#      live storage.
#   4. Verify the restored image with qemu-img info.
#   5. Optional: qmrestore to a NEW vmid on this PVE node and boot it on
#      an isolated bridge (only if qm is available and confirmed).
#   6. Print a summary report (timing = RTO evidence for the §07
#      sign-off table).
#
# Destructive surface: restoring to a scratch path is safe; qmrestore
# creates a NEW VM only after explicit confirmation. The script will
# NEVER overwrite an existing VM or restore path.
#
# Usage: bash scripts/backup-drill.sh [--dry-run]
#   --dry-run: print the plan and the exact commands that WOULD run,
#              execute nothing.
# Env (or prompted): PBS_REPOSITORY, PBS_FINGERPRINT, PBS_PASSWORD.
#   PBS_REPOSITORY defaults to the §06 backup user against $PBS_DATASTORE.
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../runbook/00-overview/variables.sh
source "$SCRIPT_DIR/../runbook/00-overview/variables.sh"

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# §06 backup-user/token names (defaults; override via env if the site used
# different names when creating them in §06.5).
PBS_BACKUP_USER="${PBS_BACKUP_USER:-pve-backup@pbs}"
PBS_TOKEN_NAME="${PBS_TOKEN_NAME:-pve-token}"

confirm() {
  # confirm "prompt text" -> returns 0 only on literal 'yes'
  local ans
  read -rp "$1 [yes/NO] " ans
  [ "$ans" = "yes" ]
}

echo "=== Cerberus PBS restore drill (guided) ==="
echo "This drill restores a backup to a SCRATCH location — never onto live"
echo "storage — and reports timing for the §07 sign-off table."
echo ""

# --- Step 0: connection details ------------------------------------------
: "${PBS_REPOSITORY:=$PBS_BACKUP_USER@$PBS_HOST_IP:$PBS_DATASTORE}"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "DRY RUN — the commands that WOULD run:"
  echo "  export PBS_REPOSITORY='$PBS_REPOSITORY'"
  echo "  export PBS_FINGERPRINT='<sha256>'; export PBS_PASSWORD='<hidden>'"
  echo "  proxmox-backup-client snapshot list vm/<vmid>"
  echo "  proxmox-backup-client snapshot files vm/<vmid>/<timestamp>"
  echo "  proxmox-backup-client restore vm/<vmid>/<timestamp> <archive> /srv/restore/<vmid>-disk.img"
  echo "  qemu-img info /srv/restore/<vmid>-disk.img"
  echo "  qmrestore <archive> <new-vmid>   # only with explicit confirmation"
  echo "DRY RUN: nothing executed."
  exit 0
fi

if [ -z "${PBS_FINGERPRINT:-}" ]; then
  read -rp "PBS server fingerprint (SHA256, from §06.2): " PBS_FINGERPRINT
fi
if [ -z "${PBS_PASSWORD:-}" ]; then
  read -rsp "PBS token value for '$PBS_BACKUP_USER!$PBS_TOKEN_NAME' (not echoed): " PBS_PASSWORD
  echo ""
fi
if [ -z "$PBS_FINGERPRINT" ] || [ -z "$PBS_PASSWORD" ]; then
  echo "Fingerprint and token are both required. Aborting." >&2
  exit 1
fi

echo ""
echo "Plan:"
echo "  1. Export PBS_REPOSITORY='$PBS_REPOSITORY' (+ fingerprint, hidden token)"
echo "  2. List snapshots for a test VMID (you choose)"
echo "  3. Restore one disk archive to a scratch path (you choose)"
echo "  4. Verify with qemu-img info"
echo "  5. Optionally qmrestore to a NEW vmid and boot on an isolated bridge"
echo ""

export PBS_REPOSITORY
export PBS_FINGERPRINT
export PBS_PASSWORD

command -v proxmox-backup-client >/dev/null 2>&1 \
  || { echo "'proxmox-backup-client' not found. Run this on a PVE node." >&2; exit 1; }

# --- Step 1: choose VMID --------------------------------------------------
read -rp "VMID whose backup you want to restore (a TEST VM, not production): " VMID
[ -n "$VMID" ] || { echo "VMID required. Aborting." >&2; exit 1; }

echo ""
echo "--- Step 1: listing snapshots for vm/$VMID ---"
SNAP_LIST="$(proxmox-backup-client snapshot list "vm/$VMID" 2>&1)" || {
  echo "Failed to list snapshots:"; echo "$SNAP_LIST"; exit 1;
}
echo "$SNAP_LIST"
TIMESTAMPS="$(echo "$SNAP_LIST" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' | sort -u)"
[ -n "$TIMESTAMPS" ] || { echo "No snapshots found for vm/$VMID. Aborting." >&2; exit 1; }
echo ""
echo "Available snapshots:"; echo "$TIMESTAMPS" | nl
read -rp "Pick a snapshot (number, or paste the timestamp): " SNAP_CHOICE
if [[ "$SNAP_CHOICE" =~ ^[0-9]+$ ]]; then
  SNAP_TS="$(echo "$TIMESTAMPS" | sed -n "${SNAP_CHOICE}p")"
else
  SNAP_TS="$SNAP_CHOICE"
fi
[ -n "$SNAP_TS" ] || { echo "Invalid selection. Aborting." >&2; exit 1; }
SNAPSHOT="vm/$VMID/$SNAP_TS"
echo "Selected snapshot: $SNAPSHOT"

# --- Step 2: list archives, choose one ------------------------------------
echo ""
echo "--- Step 2: archives in $SNAPSHOT ---"
proxmox-backup-client snapshot files "$SNAPSHOT"
read -rp "Archive to restore (e.g. drive-scsi0.img): " ARCHIVE
[ -n "$ARCHIVE" ] || { echo "Archive required. Aborting." >&2; exit 1; }

# --- Step 3: restore to scratch path --------------------------------------
read -rp "Scratch restore path [/srv/restore/$VMID-disk.img]: " SCRATCH
SCRATCH="${SCRATCH:-/srv/restore/$VMID-disk.img}"
if [ -e "$SCRATCH" ]; then
  echo "ERROR: '$SCRATCH' already exists — refusing to overwrite. Choose another path." >&2
  exit 1
fi

echo ""
echo "About to restore:"
echo "  repository: $PBS_REPOSITORY"
echo "  snapshot  : $SNAPSHOT"
echo "  archive   : $ARCHIVE"
echo "  target    : $SCRATCH   (scratch only — NOT live storage)"
confirm "Start the restore?" || { echo "Aborted."; exit 1; }

mkdir -p "$(dirname "$SCRATCH")"
T_START="$(date +%s)"
proxmox-backup-client restore "$SNAPSHOT" "$ARCHIVE" "$SCRATCH"
T_RESTORE="$(date +%s)"

# --- Step 4: verify --------------------------------------------------------
echo ""
echo "--- Step 3: verifying restored image ---"
qemu-img info "$SCRATCH"
ls -lh "$SCRATCH"

# --- Step 5: optional full boot test ---------------------------------------
echo ""
echo "--- Step 4 (optional): qmrestore to a NEW vmid and boot ---"
BOOT_OK="skipped"; T_BOOT="$T_RESTORE"
if command -v qm >/dev/null 2>&1; then
  read -rp "New VMID for the restored VM (must NOT exist; empty to skip): " NEW_VMID
  if [ -n "$NEW_VMID" ] && ! qm status "$NEW_VMID" >/dev/null 2>&1; then
    echo "This will create VM $NEW_VMID from the restored image."
    echo "Attach it to an ISOLATED bridge (no production VLAN) before booting."
    if confirm "Run qmrestore -> VM $NEW_VMID?"; then
      if qmrestore --storage local-lvm "$SCRATCH" "$NEW_VMID" 2>/dev/null; then
        echo "Restored. Next: in the PVE GUI, set the VM's network to the isolated bridge, then start it and log in via console."
        read -rp "Press Enter once the restored VM has booted to a login (or type 'skip'): " BOOT_OK
        T_BOOT="$(date +%s)"
      else
        echo "NOTE: qmrestore from a raw image needs the backup archive — use the PVE GUI (Backup -> restore to a new VMID) if this fails."
      fi
    else
      echo "Skipped qmrestore."
    fi
  else
    echo "Skipped (no valid unused VMID given)."
  fi
else
  echo "'qm' not available on this host — the boot test must be done from a PVE node."
  BOOT_OK="n/a"
fi

# --- Step 6: report ---------------------------------------------------------
echo ""
echo "================ RESTORE DRILL REPORT ================"
echo "Date            : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "Source VM       : $VMID"
echo "Snapshot        : $SNAPSHOT"
echo "Archive         : $ARCHIVE"
echo "Scratch target  : $SCRATCH"
echo "Restore duration: $(( T_RESTORE - T_START ))s"
echo "Boot test       : $BOOT_OK"
if [ "$BOOT_OK" != "skipped" ] && [ "$BOOT_OK" != "n/a" ] && [ "$BOOT_OK" != "skip" ]; then
  echo "RTO (list->boot): $(( T_BOOT - T_START ))s"
fi
echo "======================================================"
echo "Copy the RTO line into the §07 sign-off table (item 10)."
echo "Scratch image left at $SCRATCH — delete it when the drill is signed off:"
echo "  rm -f '$SCRATCH'"
