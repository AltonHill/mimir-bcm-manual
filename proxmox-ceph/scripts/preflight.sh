#!/usr/bin/env bash
# =====================================================================
# Cerberus — scripts/preflight.sh
#
# READ-ONLY pre-flight check. Run LOCALLY on each node (node-1/2/3)
# before installing PVE / initializing Ceph.
#
# Verifies:
#   1. PVE 9.x installed (pve-manager major version)
#   2. DNS resolves the peer node hostnames
#   3. NTP synchronized
#   4. >=2 interfaces at 200G link speed present (BlueField-3 ports)
#   5. MTU 9000 on the 200G interfaces (WARN only at this stage —
#      §02 sets final MTU on bond0/VLANs; net-verify.sh tests it for real)
#   6. >=2 NVMe devices visible via /dev/disk/by-id (the OSD drives)
#   7. storcli: NO virtual drives on the 940-8i (JBOD/raw, never HW RAID)
#   8. Ceph NOT yet initialized (this is pre-build)
#
# Usage: bash scripts/preflight.sh [--dry-run]
#   --dry-run: print what would be checked, run nothing.
# Exit code: 0 if all pass, non-zero with a clear message on failure.
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

NODES=("$NODE1_HOSTNAME" "$NODE2_HOSTNAME" "$NODE3_HOSTNAME")

echo "=== Cerberus preflight (read-only) on $(hostname) ==="
echo "This script makes NO changes. It will check:"
echo "  [1] PVE version is 9.x"
echo "  [2] DNS resolves peer nodes: ${NODES[*]}"
echo "  [3] System clock is NTP-synchronized"
echo "  [4] At least 2 interfaces at 200G link speed (BlueField-3 ports)"
echo "  [5] MTU ${CEPH_PUBLIC_MTU} on the 200G interfaces (WARN if not yet set)"
echo "  [6] At least 2 NVMe devices in /dev/disk/by-id (the OSD drives)"
echo "  [7] storcli: no virtual drives (JBOD only)"
echo "  [8] Ceph is NOT initialized on this host"
echo ""

if [ "$DRY_RUN" -eq 1 ]; then
  echo "DRY RUN: checks listed above, nothing executed."
  exit 0
fi

FAIL=0
fail() { echo "FAIL: $1" >&2; FAIL=1; }
pass() { echo "PASS: $1"; }
warn() { echo "WARN: $1"; }

# --- [1] PVE version ---------------------------------------------------
if command -v pveversion >/dev/null 2>&1; then
  PVE_MAJOR="$(pveversion | grep -oE 'pve-manager/[0-9]+' | head -1 | cut -d/ -f2 || true)"
  if [ "$PVE_MAJOR" = "9" ]; then
    pass "[1] PVE major version 9 ($(pveversion | head -1))"
  else
    fail "[1] pve-manager major version '$PVE_MAJOR' is not 9 — reinstall/upgrade before proceeding."
  fi
else
  fail "[1] 'pveversion' not found — Proxmox VE does not appear to be installed on this host."
fi

# --- [2] DNS -----------------------------------------------------------
for n in "${NODES[@]}"; do
  if getent hosts "$n" >/dev/null 2>&1; then
    pass "[2] DNS resolves $n -> $(getent hosts "$n" | awk '{print $1}')"
  else
    fail "[2] DNS does not resolve '$n' — fix DNS/hosts before cluster join (hostnames are final after pvecm create)."
  fi
done

# --- [3] NTP -----------------------------------------------------------
if timedatectl show 2>/dev/null | grep -q 'NTPSynchronized=yes'; then
  pass "[3] Clock is NTP-synchronized"
else
  fail "[3] Clock is NOT NTP-synchronized (NTPSynchronized != yes) — fix time sync before corosync."
fi

# --- [4] 200G interfaces (BlueField-3 ports) ------------------------------
FAST_IFACES=()
for iface in /sys/class/net/*; do
  name="$(basename "$iface")"
  [ "$name" = "lo" ] && continue
  speed_file="$iface/speed"
  if [ -r "$speed_file" ]; then
    speed="$(cat "$speed_file" 2>/dev/null || echo 0)"
    if [ "$speed" -ge 200000 ]; then
      FAST_IFACES+=("$name")
    fi
  fi
done

if [ "${#FAST_IFACES[@]}" -ge 2 ]; then
  pass "[4] Found ${#FAST_IFACES[@]} interface(s) at 200G: ${FAST_IFACES[*]}"
else
  fail "[4] Expected >=2 interfaces at 200G, found: ${FAST_IFACES[*]:-<none>} — check BlueField-3 NIC mode (mlxconfig LINK_TYPE_P1/P2=2, NIC mode) and DAC seating."
fi

# --- [5] MTU on 200G interfaces (advisory at preflight stage) -------------
for iface in "${FAST_IFACES[@]}"; do
  mtu="$(cat "/sys/class/net/$iface/mtu")"
  if [ "$mtu" -eq "$CEPH_PUBLIC_MTU" ]; then
    pass "[5] $iface MTU=$mtu"
  else
    warn "[5] $iface MTU=$mtu (design wants $CEPH_PUBLIC_MTU) — §02 sets final MTU on bond0/VLANs; scripts/net-verify.sh will test it end-to-end."
  fi
done

# --- [6] NVMe OSD drives -------------------------------------------------
NVME_COUNT="$(ls /dev/disk/by-id/ 2>/dev/null | grep -c '^nvme-' || true)"
if [ "$NVME_COUNT" -ge 2 ]; then
  pass "[6] Found $NVME_COUNT NVMe device(s) in /dev/disk/by-id (BOM: 2 OSD drives/node):"
  ls /dev/disk/by-id/ | grep '^nvme-' | sed 's/^/        /'
else
  fail "[6] Expected >=2 NVMe devices in /dev/disk/by-id, found $NVME_COUNT — check backplane cabling (direct-to-CPU x4, NOT behind the 940-8i)."
fi

# --- [7] storcli: no virtual drives --------------------------------------
if command -v storcli >/dev/null 2>&1; then
  VDRIVES="$(storcli /c0/vall show 2>/dev/null | grep -cE '^[[:space:]]*[0-9]+/' || true)"
  if [ "$VDRIVES" -eq 0 ]; then
    pass "[7] storcli /c0/vall: no virtual drives (JBOD/raw OK)"
  else
    fail "[7] storcli shows $VDRIVES virtual drive(s) on /c0 — OSD drives must be JBOD, NEVER hardware RAID. Delete virtual drives before Ceph."
  fi
  echo "      (Verify the PM1743s do NOT appear under 'storcli /c0/pall show' — they must be direct-to-CPU, not behind the 940-8i.)"
else
  fail "[7] 'storcli' not installed — cannot verify JBOD state of the 940-8i. Install StorCLI before proceeding (see docs/references.md)."
fi

# --- [8] Ceph not initialized --------------------------------------------
if [ -f /etc/ceph/ceph.conf ]; then
  fail "[8] /etc/ceph/ceph.conf exists — Ceph appears initialized. Preflight is for pre-build hosts."
elif ceph -s >/dev/null 2>&1; then
  fail "[8] 'ceph -s' succeeded — Ceph appears initialized. Preflight is for pre-build hosts."
else
  pass "[8] Ceph not initialized (expected pre-build)"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "PREFLIGHT: ALL CHECKS PASSED on $(hostname)."
  exit 0
else
  echo "PREFLIGHT: FAILURES DETECTED on $(hostname) — resolve before proceeding." >&2
  exit 1
fi
