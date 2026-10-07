# 02 — Network configuration (Proxmox side)

**Goal:** identical, verified host networking on all three nodes: an active-backup
bond across the two 200G BlueField-3 ports carrying the Ceph public (VLAN 100)
and Ceph cluster (VLAN 200) networks at MTU 9000, plus the 1GbE management bridge
at MTU 1500.

**Prerequisite:** 01 acceptance checklist signed off (cluster quorate).

```bash
set -u
source ../00-overview/variables.sh   # adjust path to your copy
```

Reference: [docs/references.md](../../docs/references.md) — Proxmox VE Admin Guide
(network chapter), Cluster Manager chapter (corosync redundancy/second link).

> `/etc/network/interfaces` is **node-local** (not replicated by pmxcfs). Every
> step below runs per node, with that node's IP set.

---

## 1. Interface discovery — resolve `<BF3_P1>` / `<BF3_P2>` / `<MGMT_IF>`

Kernel interface names are host-specific. Map PCI address → kernel name → driver
on **each** node:

```bash
for f in /sys/class/net/*; do
  i=${f##*/}; [ "$i" = lo ] && continue
  drv=$(basename "$(readlink "$f/device/driver")" 2>/dev/null || echo '?')
  pci=$(basename "$(readlink -f "$f/device")" 2>/dev/null || echo '?')
  printf '%-18s %-14s %s\n' "$i" "$drv" "$pci"
done
```

- The two BlueField-3 200G ports show driver `mlx5_core`. Record their kernel
  names (e.g. `enp134s0f0np0`, `enp134s0f1np0`).
- The Broadcom 5719 OCP 1GbE ports show `tg3` (or `bnx2x`). Pick one for
  management and record its kernel name.

Then identify **which physical port is which** — MANUAL-ONLY, one node at a time:

```bash
ethtool -p <candidate-iface> 30   # blinks the port LEDs for 30s — confirm at the rack
```

Record per node (example):

```bash
# node-1:
export BF3_P1=enp134s0f0np0   # -> SN5610-A (DAC leg, per cable audit in 00a §6)
export BF3_P2=enp134s0f1np0   # -> SN5610-B
export MGMT_IF=enp1s0f0       # -> SN2201
```

Convention: **P1 → sn5610-a, P2 → sn5610-b** on every node (matches the cabling
audit rule in 00a §6). Export these before sourcing `variables.sh` in the steps
below — the config generator refuses to run until they are set.

---

## 2. Bond design decision

**Recommendation: `bond0`, mode `active-backup`, slaves `<BF3_P1>` (primary) +
`<BF3_P2>`, miimon 100.**

Justification:

- **Simplicity and switch-failure survival.** One bond, no MLAG/peer-link config
  on the SN5610 pair, no LACP negotiation to debug. If a switch, DAC, or BF3 port
  dies, traffic fails over to the surviving path. With 2 OSDs per node, a single
  200G path is far more bandwidth than Ceph can saturate here.
- **Matches the cabling rule** (P1→switch A, P2→switch B from 00a §6): the two
  slaves are on physically independent switches, so active-backup genuinely
  survives a switch failure.
- **Corosync safety:** corosync link0 stays on the independent 1GbE management
  NIC (01 §4/§5) — never on this bond. (Proxmox docs warn that a single corosync
  link on top of a bond is fragile in some failure modes; we sidestep it.)

Trade-off (accepted): a single flow is capped at 200G — no 400G aggregation.

**Alternative (not configured here): LACP + MLAG.** If a future workload needs
>200G per node, configure 802.3ad LACP on the bond with an MLAG peer-link between
the two SN5610s. That buys ~400G aggregate and flow-level distribution at the
cost of MLAG config, peer-link fate-sharing, and harder troubleshooting. Revisit
only with measured demand.

---

## 3. VLAN and bridge layout

| Bridge | Ports | VLAN | Node IP (example) | MTU | Purpose |
|---|---|---|---|---|---|
| `vmbr0` | `<MGMT_IF>` | untagged | 10.10.10.11/24, gw 10.10.10.1 | 1500 | Proxmox mgmt, corosync link0, SSH |
| `vmbr1` | `bond0.100` | 100 (tagged) | 10.20.20.11/24, no gw | 9000 | Ceph public + VM/guest traffic |
| `vmbr2` | `bond0.200` | 200 (tagged) | 10.20.30.11/24, no gw | 9000 | Ceph cluster (replication/recovery) |

- `vmbr1` is **VLAN-aware** so VMs can use tagged VLANs on the same bridge;
  the host's own Ceph-public IP rides untagged inside the bridge and egresses
  tagged 100 via `bond0.100`.
- `vmbr2` is not VLAN-aware (Ceph cluster traffic only).
- **Switch side:** the SN5610 breakout legs facing the nodes must trunk VLANs
  100 and 200 (tagged). Add that to the 00a §7 NVUE baseline on first build and
  verify with `nv show interface` — exact NVUE bridge/VLAN syntax follows the
  switch's shipped Cumulus 5.x; confirm against on-box `nv set interface <leg>
  bridge ?` before scripting.

---

## 4. Generate and apply `/etc/network/interfaces` (per node)

Run on **each** node with its `NODE_NUM` (1, 2, 3) and the §1 exports in place.
The script below sources `variables.sh`, so all IPs/MTUs/VLANs come from the
single source of truth.

```bash
set -u
source ../00-overview/variables.sh
: "${NODE_NUM:?set NODE_NUM=1|2|3 for this node}"
cerberus_require_vars BF3_P1 BF3_P2 MGMT_IF \
  NODE1_MGMT_IP NODE2_MGMT_IP NODE3_MGMT_IP MGMT_GW \
  CEPH_PUBLIC_VLAN CEPH_CLUSTER_VLAN \
  NODE1_PUBLIC_IP NODE2_PUBLIC_IP NODE3_PUBLIC_IP \
  NODE1_CLUSTER_IP NODE2_CLUSTER_IP NODE3_CLUSTER_IP

eval MGMT_IP="\$NODE${NODE_NUM}_MGMT_IP"
eval PUBLIC_IP="\$NODE${NODE_NUM}_PUBLIC_IP"
eval CLUSTER_IP="\$NODE${NODE_NUM}_CLUSTER_IP"

# Safety: back up the working config before replacing it.
cp -a /etc/network/interfaces "/root/interfaces.bak.$(date +%F-%H%M%S)"

cat > /etc/network/interfaces <<EOF
# Cerberus node-${NODE_NUM} — generated from variables.sh. Do not hand-edit;
# re-run the generator in runbook/02-network instead.
auto lo
iface lo inet loopback

# --- 1GbE management (OCP) ---
auto ${MGMT_IF}
iface ${MGMT_IF} inet manual
    mtu ${MGMT_MTU}

# --- 200G fabric ports (BlueField-3, NIC mode) ---
auto ${BF3_P1}
iface ${BF3_P1} inet manual
    mtu ${CEPH_PUBLIC_MTU}

auto ${BF3_P2}
iface ${BF3_P2} inet manual
    mtu ${CEPH_PUBLIC_MTU}

# --- bond0: active-backup across the two 200G ports ---
auto bond0
iface bond0 inet manual
    bond-slaves ${BF3_P1} ${BF3_P2}
    bond-miimon 100
    bond-mode active-backup
    bond-primary ${BF3_P1}
    mtu ${CEPH_PUBLIC_MTU}

# --- VLAN sub-interfaces on the bond ---
auto bond0.${CEPH_PUBLIC_VLAN}
iface bond0.${CEPH_PUBLIC_VLAN} inet manual
    mtu ${CEPH_PUBLIC_MTU}

auto bond0.${CEPH_CLUSTER_VLAN}
iface bond0.${CEPH_CLUSTER_VLAN} inet manual
    mtu ${CEPH_CLUSTER_MTU}

# --- bridges ---
auto vmbr0
iface vmbr0 inet static
    address ${MGMT_IP}/24
    gateway ${MGMT_GW}
    bridge-ports ${MGMT_IF}
    bridge-stp off
    bridge-fd 0
    mtu ${MGMT_MTU}

auto vmbr1
iface vmbr1 inet static
    address ${PUBLIC_IP}/24
    bridge-ports bond0.${CEPH_PUBLIC_VLAN}
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    mtu ${CEPH_PUBLIC_MTU}

auto vmbr2
iface vmbr2 inet static
    address ${CLUSTER_IP}/24
    bridge-ports bond0.${CEPH_CLUSTER_VLAN}
    bridge-stp off
    bridge-fd 0
    mtu ${CEPH_CLUSTER_MTU}
EOF

echo "--- generated /etc/network/interfaces for node-${NODE_NUM} ---"
grep -E '^(auto|iface|    address|    gateway|    bridge-ports|    bond-)' /etc/network/interfaces
```

Apply:

```bash
ifreload -a
```

> **MANUAL-ONLY caution:** `ifreload -a` rewrites the management path you are
> SSH'd over. If the generated `vmbr0` stanza differs from the running config
> (it shouldn't — same IP — but verify the diff first), apply from the XCC
> virtual console instead of SSH. Keep the `/root/interfaces.bak.*` copy until
> §5 verification passes.

---

## 5. Verification (per node, then cross-node)

```bash
# Local: links, addresses, bond state
ip -br link
ip -br addr
cat /proc/net/bonding/bond0
# PASS: "Bonding Mode: fault-tolerance (active-backup)", "MII Status: up",
#       "Currently Active Slave: <BF3_P1>"

# Negotiated speeds
ethtool "${BF3_P1}" | grep -E 'Speed|Link detected'   # 200000Mb/s
ethtool "${BF3_P2}" | grep -E 'Speed|Link detected'   # 200000Mb/s
ethtool "${MGMT_IF}"  | grep -E 'Speed|Link detected' # 1000Mb/s

# MTUs
ip link show bond0 vmbr1 vmbr2 | grep -o 'mtu [0-9]*'   # 9000
ip link show vmbr0 | grep -o 'mtu [0-9]*'              # 1500

# Cross-node reachability on all three networks (run from each node)
ping -c 3 <other-node-mgmt-ip>
ping -c 3 <other-node-public-ip>
ping -c 3 <other-node-cluster-ip>

# End-to-end MTU 9000, no fragmentation (8972 = 9000 - 20 IP - 8 ICMP)
ping -M do -s 8972 -c 4 <other-node-public-ip>
ping -M do -s 8972 -c 4 <other-node-cluster-ip>
# PASS: 0% loss on every pair, both VLANs

# Corosync still healthy after the network rework
corosync-cfgtool -s
pvecm status   # still 3 votes, quorate
```

**Failover drill (do it now, while the build is young):**

```bash
# MANUAL-ONLY: pull (or administratively down) the active 200G leg / switch-A DAC.
# Expect: bond fails over to BF3_P2 (<30s with miimon 100, typically ~1-3s),
# pings on vmbr1/vmbr2 resume, corosync unaffected (separate NIC).
ip link set "${BF3_P1}" down   # software equivalent of pulling the cable
cat /proc/net/bonding/bond0    # Currently Active Slave should now be BF3_P2
ping -c 10 <other-node-cluster-ip>
ip link set "${BF3_P1}" up
```

---

## 6. Corosync link1 (optional)

link0 already runs on the mgmt network (01 §4/§5). A second corosync link adds
redundancy against mgmt-switch failure. Recommended placement: the Ceph public
VLAN (vmbr1).

Caveat (be honest about it): link1 rides the **same physical bond** as Ceph
traffic, VLAN-separated — it protects against mgmt-switch/NIC failure, not
against a fabric-wide event. That is still a strict improvement over one link.

Add via GUI (Datacenter → Cluster → Edit, add ring 1 with the node's public IP)
or by editing `/etc/pve/corosync.conf` (replicated automatically):

```
# per-node nodelist entry gains:
ring1_addr: <NODE*_PUBLIC_IP>
```

then on any node:

```bash
corosync-cfgtool -s
# PASS: two rings listed, both "active with no faults"
```

---

## 7. Firewall note

If the Proxmox datacenter/host firewall is enabled, allow between the nodes:

- **UDP 5405–5412** on the mgmt network (corosync; both links if link1 added)
- **TCP 6789** (Ceph MON) and **TCP 6800–7300** (Ceph OSD/MGR) on the Ceph
  public and Ceph cluster networks

Default Proxmox firewall policy with no rules can blackhole cluster traffic —
either leave the firewall off until §07 validation, or add the allows above first
(GUI: Datacenter → Firewall, or per-node Host → Firewall).

---

## Node-4 callout

Repeat §1 (discover its interface names) and §4 with `NODE_NUM=4`
(`.14` addresses from `variables.sh`). Its P1/P2 follow the same
switch-A/switch-B rule; the §5 failover drill applies unchanged.

## 02 acceptance checklist

- [ ] `<BF3_P1>`/`<BF3_P2>`/`<MGMT_IF>` resolved and recorded per node (§1)
- [ ] SN5610 breakout legs trunk VLANs 100+200 tagged (§3)
- [ ] `/etc/network/interfaces` generated from `variables.sh` on all nodes; backup kept (§4)
- [ ] `ifreload -a` applied; bond0 active-backup up, active slave = P1 (§5)
- [ ] 200000Mb/s on both BF3 ports, 1000Mb/s mgmt, MTUs 9000/9000/1500 (§5)
- [ ] Cross-node ping clean on mgmt/public/cluster; MTU-9000 ping clean on both VLANs (§5)
- [ ] Failover drill: P1 down → traffic on P2, corosync unaffected (§5)
- [ ] Optional corosync link1 added and both rings fault-free (§6)
- [ ] Firewall allows in place if firewall is enabled (§7)
