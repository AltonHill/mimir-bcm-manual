#!/usr/bin/env bash
# ============================================================================
# Cerberus — site variables (single source of truth for all runbook sections)
# ============================================================================
#
# HOW TO USE
#   1. Copy this file per site/deployment and replace every PLACEHOLDER value
#      with the site's real values. Keep this file out of version control if
#      it contains sensitive site data (or keep placeholders and inject at
#      deploy time — pick one and be consistent).
#   2. Later sections source it:
#         set -u
#         source /path/to/variables.sh
#   3. Anything still set to PLACEHOLDER (or empty, for host-resolved values)
#      MUST be resolved before running the steps that consume it.
#
# CONVENTIONS
#   - Node names are customer-anonymized role names: node-1 / node-2 / node-3.
#     The optional 4th node reuses the same scheme (node-4, .14 suffixes).
#   - ${VAR:-default} form everywhere, so `set -u` sourcing never trips on
#     an unset variable. Export overrides from the environment win.
#   - Networks below are PLACEHOLDER defaults from the design doc; change the
#     CIDR and every derived IP moves with it.
#
# Reference: docs/references.md (official docs index).

set -u

# ------------------------------------------------------------------ cluster
CLUSTER_NAME="${CLUSTER_NAME:-cerberus}"
CEPH_RELEASE="${CEPH_RELEASE:-tentacle}"   # PVE 9.2 default. Do NOT use Squid (EOL ~Sept/Oct 2026 — re-check docs.ceph.com at deploy time).
DOMAIN="${DOMAIN:-PLACEHOLDER}"            # e.g. lab.example.com — used for FQDNs in /etc/hosts

# ------------------------------------------------------------------ nodes
# Hostnames must be FINAL before `pvecm create` — Proxmox does not support
# renaming/re-IPing a node after it joins a cluster.
NODE1_HOSTNAME="${NODE1_HOSTNAME:-node-1}"
NODE2_HOSTNAME="${NODE2_HOSTNAME:-node-2}"
NODE3_HOSTNAME="${NODE3_HOSTNAME:-node-3}"
NODE4_HOSTNAME="${NODE4_HOSTNAME:-node-4}"   # optional 4th node

# ------------------------------------------------- management network (1GbE)
# Physical path: Broadcom 5719 OCP 4x1GbE -> SN2201 mgmt switch(es).
# Carries: Proxmox management, corosync link0, XCC/BMC, PBS traffic.
MGMT_NET="${MGMT_NET:-10.10.10.0/24}"      # PLACEHOLDER
MGMT_GW="${MGMT_GW:-10.10.10.1}"           # PLACEHOLDER
MGMT_MTU="${MGMT_MTU:-1500}"
NODE1_MGMT_IP="${NODE1_MGMT_IP:-10.10.10.11}"
NODE2_MGMT_IP="${NODE2_MGMT_IP:-10.10.10.12}"
NODE3_MGMT_IP="${NODE3_MGMT_IP:-10.10.10.13}"
NODE4_MGMT_IP="${NODE4_MGMT_IP:-10.10.10.14}"   # optional

# XCC/BMC interfaces (same L2 as MGMT_NET; set in XCC, see 00a-physical-bringup)
NODE1_XCC_IP="${NODE1_XCC_IP:-10.10.10.21}"
NODE2_XCC_IP="${NODE2_XCC_IP:-10.10.10.22}"
NODE3_XCC_IP="${NODE3_XCC_IP:-10.10.10.23}"

# ------------------------------------------- Ceph public network (client)
# Physical path: bond0 (active-backup over 2x 200G BlueField-3) tagged VLAN 100
# -> SN5610-A / SN5610-B breakout legs. MTU 9000 end to end.
# Carries: Ceph client traffic (MON/MGR/OSD client ports) + VM/guest traffic.
CEPH_PUBLIC_NET="${CEPH_PUBLIC_NET:-10.20.20.0/24}"   # PLACEHOLDER
CEPH_PUBLIC_VLAN="${CEPH_PUBLIC_VLAN:-100}"
CEPH_PUBLIC_MTU="${CEPH_PUBLIC_MTU:-9000}"
NODE1_PUBLIC_IP="${NODE1_PUBLIC_IP:-10.20.20.11}"
NODE2_PUBLIC_IP="${NODE2_PUBLIC_IP:-10.20.20.12}"
NODE3_PUBLIC_IP="${NODE3_PUBLIC_IP:-10.20.20.13}"
NODE4_PUBLIC_IP="${NODE4_PUBLIC_IP:-10.20.20.14}"     # optional

# -------------------------------------- Ceph cluster network (replication)
# Physical path: same bond0, tagged VLAN 200 -> SN5610-A / SN5610-B.
# Carries: OSD replication, recovery, backfill, heartbeat. No gateway.
CEPH_CLUSTER_NET="${CEPH_CLUSTER_NET:-10.20.30.0/24}" # PLACEHOLDER
CEPH_CLUSTER_VLAN="${CEPH_CLUSTER_VLAN:-200}"
CEPH_CLUSTER_MTU="${CEPH_CLUSTER_MTU:-9000}"
NODE1_CLUSTER_IP="${NODE1_CLUSTER_IP:-10.20.30.11}"
NODE2_CLUSTER_IP="${NODE2_CLUSTER_IP:-10.20.30.12}"
NODE3_CLUSTER_IP="${NODE3_CLUSTER_IP:-10.20.30.13}"
NODE4_CLUSTER_IP="${NODE4_CLUSTER_IP:-10.20.30.14}"   # optional

# ------------------------------------------------------- fabric switches
# Two NVIDIA SN5610 800GbE (Cumulus 5.x) carry the Proxmox storage fabric.
# A third SN5610 exists as SPARE (AI side) — out of scope for this runbook.
FABRIC_SWITCH_A="${FABRIC_SWITCH_A:-sn5610-a}"
FABRIC_SWITCH_B="${FABRIC_SWITCH_B:-sn5610-b}"
FABRIC_MTU="${FABRIC_MTU:-9216}"   # Cumulus default; verify, never set below 9000
# 800G OSFP ports on each switch that take the OSFP-800G -> 4x QSFP112-200G
# breakout DACs. VERIFY against each switch's own /etc/cumulus/ports.conf —
# SN5610 800G-capable port numbers are per-switch, do not assume.
SWITCH_A_DAC_PORT="${SWITCH_A_DAC_PORT:-swp1}"
SWITCH_B_DAC_PORT="${SWITCH_B_DAC_PORT:-swp1}"
# 1GbE management switch(es)
MGMT_SWITCH="${MGMT_SWITCH:-sn2201-mgmt}"

# --------------------------------- host interface names (resolve per node)
# Kernel interface names for the BlueField-3 200G ports and the OCP 1GbE port
# are host-specific. Resolve them in runbook/02-network §1 (PCI -> kernel
# mapping + physical port identification), then export BEFORE sourcing:
#     export BF3_P1=enp134s0f0np0 BF3_P2=enp134s0f1np0 MGMT_IF=enp1s0f0
# Left empty on purpose: the runbook refuses to generate network config until
# these are set (see the guard in 02-network).
BF3_P1="${BF3_P1:-}"
BF3_P2="${BF3_P2:-}"
MGMT_IF="${MGMT_IF:-}"

# ------------------------------------------------------------- core services
DNS_SERVERS="${DNS_SERVERS:-10.10.10.2}"       # PLACEHOLDER, space-separated if several
NTP_SERVERS="${NTP_SERVERS:-pool.ntp.org}"     # PLACEHOLDER — prefer site NTP
MAILTO="${MAILTO:-ops@example.com}"           # PLACEHOLDER — backup/alert mail target

# ------------------------------------------------- Proxmox Backup Server
# Dedicated physical host (NOT one of the cluster nodes). Reachable on MGMT_NET.
PBS_HOST_IP="${PBS_HOST_IP:-10.10.10.100}"    # PLACEHOLDER
PBS_DATASTORE="${PBS_DATASTORE:-ceph-backups}"

# --------------------------------------------- Ceph pool defaults (see 04)
CEPH_POOL_SIZE="${CEPH_POOL_SIZE:-3}"
CEPH_POOL_MIN_SIZE="${CEPH_POOL_MIN_SIZE:-2}"
POOL_VM_NAME="${POOL_VM_NAME:-vm-storage}"            # primary RBD pool for VM disks
POOL_VM_TARGET_SIZE="${POOL_VM_TARGET_SIZE:-5T}"      # PLACEHOLDER — pg_autoscale target (planned usable)

# ------------------------------------------------- Proxmox HA defaults (see 05)
HA_RULE_NAME="${HA_RULE_NAME:-ha-prefer-any}"         # node-affinity rule name
HA_PROTECTED_VMS="${HA_PROTECTED_VMS:-}"              # PLACEHOLDER — space-separated vmids, e.g. "100 101"

# ------------------------------------------------------------------ helpers
# Fail fast if any consumed variable is still a placeholder or empty.
# Usage: cerberus_require_vars NODE1_MGMT_IP BF3_P1 ...
cerberus_require_vars() {
    local missing=0 v val
    for v in "$@"; do
        val="${!v:-}"
        if [ -z "$val" ] || [ "$val" = "PLACEHOLDER" ]; then
            echo "FATAL: variable $v is unset or still PLACEHOLDER — resolve it in variables.sh" >&2
            missing=1
        fi
    done
    [ "$missing" -eq 0 ]
}

# Print every variable still holding a PLACEHOLDER or empty default.
cerberus_audit_placeholders() {
    echo "--- variables still needing site values ---"
    compgen -v | grep -E '^(NODE|MGMT|CEPH|FABRIC|SWITCH|PBS|DNS|NTP|MAILTO|DOMAIN|CLUSTER|POOL|HA)' | sort | while read -r v; do
        val="${!v:-}"
        case "$val" in
            ""|PLACEHOLDER) printf '%-22s %s\n' "$v" "${val:-(empty)}" ;;
        esac
    done
    echo "--- host-resolved (must be exported per node) ---"
    printf '%-22s %s\n' "BF3_P1" "${BF3_P1:-(empty — see 02-network §1)}"
    printf '%-22s %s\n' "BF3_P2" "${BF3_P2:-(empty — see 02-network §1)}"
    printf '%-22s %s\n' "MGMT_IF" "${MGMT_IF:-(empty — see 02-network §1)}"
}
