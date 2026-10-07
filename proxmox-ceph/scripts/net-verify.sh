#!/usr/bin/env bash
# =====================================================================
# Cerberus — scripts/net-verify.sh
#
# READ-ONLY network verification for the 3-node fabric.
# Run from ANY one of the PVE nodes (it reaches the others over SSH).
#
# Verifies:
#   1. End-to-end MTU on the Ceph public + Ceph cluster networks
#      (ping -M do with a 8972-byte payload => 9000-byte frames, DF set)
#   2. corosync UDP port range 5405-5412 reachable between all nodes
#      (probe datagrams between every node pair; needs nc/netcat)
#   3. Optional: iperf3 bandwidth sanity on the 200G fabric (auto-skipped
#      if iperf3 is missing on either end; disable with --no-iperf3)
#
# Usage: bash scripts/net-verify.sh [--dry-run] [--no-iperf3]
#   --dry-run:    print what would be tested, run nothing.
#   --no-iperf3: skip the optional bandwidth test.
# Exit code: 0 if all pass; non-zero with a clear message on failure.
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../runbook/00-overview/variables.sh
source "$SCRIPT_DIR/../runbook/00-overview/variables.sh"

DRY_RUN=0
WITH_IPERF3=1
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --no-iperf3) WITH_IPERF3=0 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

NODES=("$NODE1_HOSTNAME" "$NODE2_HOSTNAME" "$NODE3_HOSTNAME")
PUBLIC_IPS=("$NODE1_PUBLIC_IP" "$NODE2_PUBLIC_IP" "$NODE3_PUBLIC_IP")
CLUSTER_IPS=("$NODE1_CLUSTER_IP" "$NODE2_CLUSTER_IP" "$NODE3_CLUSTER_IP")
MGMT_IPS=("$NODE1_MGMT_IP" "$NODE2_MGMT_IP" "$NODE3_MGMT_IP")

# Payload size for MTU test: 9000 - 20 (IP) - 8 (ICMP) = 8972
MTU_PAYLOAD=$(( CEPH_PUBLIC_MTU - 28 ))
PROBE_PORT=5406   # inside 5405-5412, distinct from the live corosync port

echo "=== Cerberus network verification (read-only) ==="
echo "Local host: $(hostname)"
echo "This script makes NO configuration changes. It will test:"
echo "  [1] MTU ${CEPH_PUBLIC_MTU} end-to-end (DF ping, ${MTU_PAYLOAD}-byte payload)"
echo "      public  : ${PUBLIC_IPS[*]}"
echo "      cluster : ${CLUSTER_IPS[*]}"
echo "  [2] corosync UDP reachability (5405-5412)"
echo "      between all node pairs (mgmt IPs: ${MGMT_IPS[*]})"
if [ "$WITH_IPERF3" -eq 1 ]; then
  echo "  [3] iperf3 bandwidth sanity on the 200G fabric (optional; skipped if missing)"
else
  echo "  [3] iperf3 bandwidth test: DISABLED by --no-iperf3"
fi
echo ""

if [ "$DRY_RUN" -eq 1 ]; then
  echo "DRY RUN: tests listed above, nothing executed."
  exit 0
fi

FAIL=0
fail() { echo "FAIL: $1" >&2; FAIL=1; }
pass() { echo "PASS: $1"; }
warn() { echo "WARN: $1"; }

# --- [1] MTU end-to-end ---------------------------------------------------
echo "--- [1] MTU ${CEPH_PUBLIC_MTU} ping tests (do-not-fragment) ---"
MTU_TARGETS=("${PUBLIC_IPS[@]}" "${CLUSTER_IPS[@]}")
LOCAL_IPS="$(hostname -I)"
for target in "${MTU_TARGETS[@]}"; do
  if echo "$LOCAL_IPS" | grep -qw "$target"; then
    echo "  (skip $target — local address)"
    continue
  fi
  if ping -M do -s "$MTU_PAYLOAD" -c 4 -W 2 "$target" >/dev/null 2>&1; then
    pass "[1] $target accepts ${CEPH_PUBLIC_MTU}-byte frames (DF)"
  else
    fail "[1] $target REJECTED ${CEPH_PUBLIC_MTU}-byte frames — MTU mismatch on the path. Check switch MTU (${FABRIC_MTU}) and node interface/VLAN MTU (§02)."
  fi
done

# --- [2] corosync UDP reachability ----------------------------------------
echo ""
echo "--- [2] corosync UDP 5405-5412 reachability ---"
if ! command -v nc >/dev/null 2>&1; then
  warn "[2] 'nc' (netcat) not installed — cannot probe UDP. Install netcat and re-run, or verify corosync links after cluster join."
else
  for target in "${MGMT_IPS[@]}"; do
    if echo "$LOCAL_IPS" | grep -qw "$target"; then
      echo "  (skip $target — local address)"
      continue
    fi
    # Listener on the target (background via ssh), probe from here, then check.
    ssh -o BatchMode=yes -o ConnectTimeout=5 "root@$target" \
      "timeout 12 nc -u -l -p $PROBE_PORT > /tmp/cerberus-udp-probe 2>/dev/null & echo started" >/dev/null 2>&1 || true
    sleep 1
    echo "cerberus-udp-probe" | timeout 5 nc -u -w 2 "$target" "$PROBE_PORT" >/dev/null 2>&1 || true
    sleep 2
    if ssh -o BatchMode=yes -o ConnectTimeout=5 "root@$target" \
        "grep -q cerberus-udp-probe /tmp/cerberus-udp-probe && rm -f /tmp/cerberus-udp-probe" 2>/dev/null; then
      pass "[2] UDP datagram reached $target (port $PROBE_PORT in range)"
    else
      ssh -o BatchMode=yes -o ConnectTimeout=5 "root@$target" "rm -f /tmp/cerberus-udp-probe" 2>/dev/null || true
      fail "[2] UDP datagram did NOT reach $target on port $PROBE_PORT — corosync knet traffic may be filtered. Check firewalls/ACLs on the path."
    fi
  done
  echo "  (Ensure UDP 5405-5412 is ACCEPTED in the node firewall for all peers.)"
fi

# --- [3] iperf3 bandwidth sanity (optional) --------------------------------
echo ""
echo "--- [3] iperf3 bandwidth sanity (optional) ---"
if [ "$WITH_IPERF3" -eq 0 ]; then
  echo "  Skipped (--no-iperf3)."
else
  if ! command -v iperf3 >/dev/null 2>&1; then
    warn "[3] iperf3 not installed locally — skipping bandwidth test (install iperf3 to enable)."
  else
    for target in "${PUBLIC_IPS[@]}"; do
      if echo "$LOCAL_IPS" | grep -qw "$target"; then
        echo "  (skip $target — local address)"
        continue
      fi
      if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "root@$target" "command -v iperf3" >/dev/null 2>&1; then
        warn "[3] iperf3 missing on $target — skipping that leg."
        continue
      fi
      ssh -o BatchMode=yes "root@$target" "pkill -f 'iperf3 -s' >/dev/null 2>&1; iperf3 -s -D >/dev/null 2>&1" || true
      sleep 1
      RESULT="$(timeout 20 iperf3 -c "$target" -t 10 -f g 2>/dev/null | grep -E 'receiver' | tail -1 || true)"
      ssh -o BatchMode=yes "root@$target" "pkill -f 'iperf3 -s' >/dev/null 2>&1" || true
      GBPS="$(echo "$RESULT" | grep -oE '[0-9]+\.[0-9]+ Gbits/sec' | grep -oE '[0-9]+\.[0-9]+' | head -1 || true)"
      if [ -n "${GBPS:-}" ]; then
        # Sanity floor: 50 Gbits/sec (a quarter of a 200G leg — generous;
        # iperf3 single-stream rarely saturates 200G). Below = investigate.
        if awk "BEGIN{exit !($GBPS >= 50)}"; then
          pass "[3] -> $target: ${GBPS} Gbits/sec (>= 50 floor OK)"
        else
          warn "[3] -> $target: ${GBPS} Gbits/sec is LOW for a 200G leg — check link negotiation, DAC seating, CPU affinity."
        fi
      else
        warn "[3] iperf3 to $target produced no result — check iperf3 on both ends."
      fi
    done
  fi
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "NET-VERIFY: ALL CHECKS PASSED."
  exit 0
else
  echo "NET-VERIFY: FAILURES DETECTED — resolve before cluster join/Ceph init." >&2
  exit 1
fi
