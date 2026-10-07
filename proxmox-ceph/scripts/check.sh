#!/usr/bin/env bash
# Cerberus — scripts/check.sh
# Validation gate for the proxmox-ceph track.
#   1. bash -n syntax check on every script
#   2. python compile check on render.py
#   3. render smoke test (renders to a temp dir, verifies substitution)
set -euo pipefail
TRACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0

echo "== bash syntax =="
for s in "$TRACK_DIR"/scripts/*.sh "$TRACK_DIR"/runbook/00-overview/variables.sh; do
    if bash -n "$s"; then echo "OK   $s"; else echo "FAIL $s"; fail=1; fi
done

echo "== python compile =="
if python3 -m py_compile "$TRACK_DIR/scripts/render.py"; then
    echo "OK   scripts/render.py"
else
    echo "FAIL scripts/render.py"; fail=1
fi

echo "== render smoke test =="
TMP="$(mktemp -d)"
if "$TRACK_DIR/scripts/render.py" --out "$TMP/out" >/dev/null; then
    # every section must have rendered
    for d in "$TRACK_DIR"/runbook/*/; do
        sec="$(basename "$d")"
        [ -f "$TMP/out/runbook/$sec/README.md" ] || { echo "FAIL missing $sec"; fail=1; }
    done
    # a defined variable must not survive unsubstituted (excluding shell ${V:-} forms)
    if grep -rhoE '\$\{?(CEPH_PUBLIC_VLAN|MGMT_NET|CLUSTER_NAME)\}?' "$TMP/out" | grep -qv ':-'; then
        echo "FAIL leftover defined variables in rendered output"; fail=1
    else
        echo "OK   render smoke test"
    fi
else
    echo "FAIL render.py"; fail=1
fi
rm -rf "$TMP"

if [ "$fail" -eq 0 ]; then echo "ALL CHECKS PASSED"; else echo "CHECKS FAILED"; exit 1; fi
