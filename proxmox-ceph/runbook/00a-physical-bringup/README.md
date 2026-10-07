# 00a — Physical bring-up verification

**Goal:** prove the baremetal is built correctly *before* any software goes on.
No vendor integration kit exists for this build (no EveryScale) — the builder racks
and cables everything, so this section owns the full physical verification.

**Ordering:** complete all of 00a on all three nodes (plus switches) before starting
01-cluster-install. Several steps are **MANUAL-ONLY** (firmware flashes, physical
cabling) — they cannot be scripted and must be done by a person at the rack or in
the XCC web UI.

**Conventions:** `MANUAL-ONLY` = a human does this step by hand. `DESTRUCTIVE` =
data loss is possible; double-check the target first. `STOP` = halt the build,
do not proceed until resolved.

Source the site variables first:

```bash
set -u
source ../00-overview/variables.sh   # adjust path to your copy
```

Reference: [docs/references.md](../../docs/references.md) — Lenovo (XCC2, OneCLI,
SR650 V4 product guide), NVIDIA (NVUE, BlueField modes), StorCLI notes.

---

## 1. Rack & power check — MANUAL-ONLY

1. Verify each node is racked with both 1300W PSUs seated, and **both power cords
   connected to independent feeds** (N+N redundancy is a design assumption).
2. Confirm airflow: front intake / rear exhaust unobstructed; blanking panels in
   empty RU above/below.
3. Connect the XCC management port on each node to the mgmt network (SN2201).
   Set the XCC IPs from `variables.sh` (`NODE*_XCC_IP`) in the XCC web UI or via
   BIOS setup — MANUAL-ONLY.
4. Power on. Verify via XCC that both PSUs report healthy and no critical
   hardware events are logged (XCC → Events).

**Node-4 callout:** repeat this whole section for the 4th node if/when it is added.

---

## 2. XCC/BMC firmware baseline — MANUAL-ONLY

**Rule: update XCC/BMC firmware FIRST, then UEFI.** Wrong order causes incorrect
behavior (Lenovo XCC2 documented ordering).

### 2a. Web flow (XCC2)

Per node, in the XCC web UI (https://`<NODE*_XCC_IP>`):

1. BMC → Firmware Update → **System Firmware** | **Adapter Firmware** | **PSU Firmware** |
   **Update from Repository**.
2. Click **Update Firmware** → **Browse** (select the update bundle file) → **Next**
   (upload + verify) → select the target device → **Update** → **Finish**.
3. Do the XCC/BMC bundle first, let it complete, then UEFI, then adapters/PSU.

Notes:

- **Update-from-Repository** (CIFS/NFS/HTTPS staging) and onboard firmware history
  require an **XCC Platinum license**. Without it, use the Browse/upload flow or
  OneCLI below.
- Record the final firmware levels per node (XCC, UEFI, BF3, 940-8i, PSU) in the
  build log — they are the baseline for all future maintenance.

### 2b. OneCLI flow (CLI alternative)

OneCLI (`onecli` on Linux) can flash in-band (run on the host OS) or out-of-band
(toward the XCC). Download the UXSP bundle for the SR650 V4 machine type first.

```bash
# Inventory first — know what you have before flashing anything.
onecli inventory getinfor

# Compare installed vs. latest in a local package dir (out-of-band example).
onecli update compare --scope latest --bmc USERID:PASSW0RD@<xcc-ip> \
  --dir ./packages --output ./output

# Flash a bundle out-of-band toward the XCC (needs an SFTP server for payload
# delivery — pass --sftp <server>). MANUAL-ONLY: flashing firmware.
onecli update flash --bundle --dir <folder-with-bundles> \
  --bmc USERID:PASSW0RD@<xcc-ip>

# In-band alternative (run on the host OS itself, no --bmc needed):
onecli update flash --bundle --dir <folder>

# Staged update across a maintenance window:
onecli update flash --bundle --dir <folder> --bmc USERID:PASSW0RD@<xcc-ip> \
  --applytime OnStartUpdateRequest
onecli update checktask --bmc USERID:PASSW0RD@<xcc-ip>
onecli update startstaged --bmc USERID:PASSW0RD@<xcc-ip>
onecli update canceltask --taskid <id> --bmc USERID:PASSW0RD@<xcc-ip>

# Fleet flash across all nodes from one JSON task file:
onecli multiupdate flash --configfile multi_task.json
```

Replace `USERID`/`PASSW0RD` with the site's XCC credentials (change the factory
defaults — MANUAL-ONLY, first boot). Reference: Lenovo pubs
`onecli_r_flash_command`, `xcc2/updating_firmware_*` (see docs/references.md).

---

## 3. RAID 940-8i — JBOD verification

The 940-8i must expose drives raw. **No virtual drives may exist** — Ceph's hard
requirement is raw disks with no virtual-drive layer and no controller caching in
the path. (JBOD ≠ HBA: JBOD still passes through controller firmware, which is
fine for Ceph.)

> The 2x 960GB M.2 OS drives sit behind the **B550i-2i**, a different controller.
> StorCLI against `/c0` (the 940-8i) does not touch them — do not go looking for
> them here.

```bash
storcli /c0 show          # controller info — confirm you are talking to the 940-8i
storcli /c0/pall show     # physical drives
storcli /c0/vall show     # virtual drives — MUST BE EMPTY on a Ceph node
```

- If `/c0/vall show` lists any virtual drive: **DESTRUCTIVE / MANUAL-ONLY** —
  delete it/them (confirm with the builder that nothing on them matters; these are
  fresh Ceph nodes, so normally nothing does) and re-run until empty.
- Enable JBOD mode (a reboot may be required for it to take effect):

```bash
storcli /c0 set jbod=on
# verify: drives should show state "JBOD" in the next command
storcli /c0/pall show
```

- If the controller rejects `set jbod=on`: STOP. The fallback is the HBA
  personality (`storcli /c0 set personality=hba`) **where supported** — whether the
  940-8i exposes that switch is unverified (Broadcom StorCLI reference is behind a
  support login); confirm on first boot with on-box `storcli /c0 help` before
  improvising.

---

## 4. CRITICAL — NVMe direct-to-CPU verification (STOP if wrong)

The 2x 3.84TB Samsung PM1743 U.3 NVMe per node **must be wired direct-to-CPU at
x4**, NOT behind the 940-8i (whose NVMe U.3 support is x1 ≈ 2 GB/s per drive vs
~14 GB/s direct). This is the single highest-risk physical step: NVMe behind the
controller is a silent x1 link with controller firmware in the I/O path.

Prove it two independent ways on **every** node:

```bash
# 1) PCIe link width/speed — expect 32GT/s and x4 for each PM1743.
for addr in $(lspci -nn | grep -i nvme | awk '{print $1}'); do
  echo "== $addr =="
  lspci -vv -s "$addr" | grep -E 'LnkCap|LnkSta'
done
# PASS: LnkSta: Speed 32GT/s, Width x4   (per drive)
# FAIL: Width x1  -> the drive is behind a controller. STOP, recable.

# 2) The PM1743s must NOT appear in StorCLI at all.
storcli /c0/pall show
# PASS: no NVMe/PM1743 entries (only SAS/SATA/backplane devices, if any)
# FAIL: PM1743s listed -> they are behind the 940-8i. STOP, recable.
```

**STOP condition:** if either check fails, halt the build and have the builder
recable the U.3 backplane to the direct-to-CPU (x4) path. Do not "accept" x1 —
Ceph performance and the entire storage design assume x4.

While here, record the stable device IDs for OSD creation in §03:

```bash
ls -l /dev/disk/by-id/ | grep -i nvme
# record the /dev/disk/by-id/nvme-<...> entries for the two PM1743s per node
```

---

## 5. BlueField-3 B3220 — Ethernet + NIC mode

The B3220 ships from the factory in **DPU mode**. For a plain Proxmox/Ceph host
there is no benefit to DPU mode (Arm cores active, host-trusted services) — put
the card in **NIC mode** so it behaves exactly like a ConnectX adapter, with both
ports forced to Ethernet.

On each node (needs `mst` from the Mellanox/NVIDIA firmware tools):

```bash
sudo mst start
mst status   # note the device, e.g. /dev/mst/mt4125_pciconf0
DEV=/dev/mst/mt4125_pciconf0   # adjust to your device

# 1) Read current mode (read-only — safe).
mlxconfig -d "$DEV" q INTERNAL_CPU_OFFLOAD_ENGINE
#   DISABLED(1) = NIC mode   |   ENABLED(0) = DPU mode

# 2) Set both ports to Ethernet (1=InfiniBand, 2=Ethernet). MANUAL-ONLY.
mlxconfig -d "$DEV" set LINK_TYPE_P1=2 LINK_TYPE_P2=2

# 3) Switch the card to NIC mode (Arm cores off). MANUAL-ONLY.
mlxconfig -d "$DEV" s \
  INTERNAL_CPU_MODEL=1 \
  INTERNAL_CPU_PAGE_SUPPLIER=1 \
  INTERNAL_CPU_ESWITCH_MANAGER=1 \
  INTERNAL_CPU_IB_VPORT0=1 \
  INTERNAL_CPU_OFFLOAD_ENGINE=1

# 4) Reset firmware, then POWER-CYCLE the host to be safe. MANUAL-ONLY.
mlxfwreset -d "$DEV" r
# -> full AC power cycle via XCC / rack PDU
```

Verify after the power cycle:

```bash
mlxconfig -d "$DEV" q LINK_TYPE_P1        # expect ETH(2)
mlxconfig -d "$DEV" q INTERNAL_CPU_OFFLOAD_ENGINE   # expect DISABLED(1) = NIC mode
# Per-port link state (interface names resolved in 02-network §1):
ethtool <BF3_P1> | grep -E 'Speed|Link detected'
# PASS: Speed: 200000Mb/s, Link detected: yes  (once DACs are cabled to the SN5610s)
```

Reference: NVIDIA DOCA "BlueField modes of operation" (see docs/references.md).

---

## 6. Cabling audit — MANUAL-ONLY

Audit every cable against
[docs/diagrams/cable-diagram.svg](../../docs/diagrams/cable-diagram.svg).
Fill and sign off this table per site (example rows — use the diagram's actual
DAC/port/leg numbering):

| DAC | Switch | OSFP port | Breakout leg | Node | BF3 port |
|---|---|---|---|---|---|
| DAC-1 | sn5610-a | port 1 | leg 1 (`swp1s0`) | node-1 | P1 |
| DAC-1 | sn5610-a | port 1 | leg 2 (`swp1s1`) | node-1 | — |
| DAC-2 | sn5610-b | port 1 | leg 1 (`swp1s0`) | node-1 | P2 |
| … | … | … | … | … | … |

Rules to enforce:

- **Each node's two 200G links land on DIFFERENT switches** (P1 → sn5610-a,
  P2 → sn5610-b). This is what makes the active-backup bond in §02 survive a
  switch failure.
- 2–4x Cat6 per node from the OCP 1GbE ports → SN2201 mgmt switch (BOM ships
  1/server; add per site policy).
- XCC ports → SN2201 (done in §1).
- Label both ends of every DAC leg and Cat6 run. A mislabeled breakout leg is a
  future outage.

**Node-4 callout:** the second OSFP breakout DAC pair covers a 4th node exactly
(2 DACs = 8 legs = 4 nodes × 2 links); audit its legs the same way.

---

## 7. Switch baseline (Cumulus 5.x, NVUE)

Do this during bring-up only — changing breakout/MTU reloads `switchd` and resets
ports. Never on a live fabric.

### 7a. SN5610-A and SN5610-B (800GbE fabric)

```bash
# On each SN5610 (SSH/console):
# 1) Confirm which ports are 800G-capable on THIS switch — do not assume.
cat /etc/cumulus/ports.conf

# 2) Break out the OSFP port(s) carrying the Proxmox DACs: 1x800G -> 4x200G.
#    New-format value is "4x" (not "4x200G").
nv set interface swp1 link breakout 4x
nv set interface swp1s0-3 link state up

# 3) Force 200G only if autonegotiation misbehaves:
nv set interface swp1s0-3 link speed 200G

# 4) MTU: Cumulus default is already 9216 — VERIFY rather than blindly set.
#    It must never be below 9000 (hosts run 9000 on the Ceph VLANs).
nv set interface swp1s0-3 link mtu 9216

# 5) Apply (auto-save is ON by default -> persists to /etc/nvue.d/startup.yaml)
nv config apply
nv config save     # explicit save in case the site template disabled auto-save

# 6) Verify
nv show interface
```

Repeat for the second DAC port if the 4th node (or a second DAC pair) is in use.
NVUE supports `?`, `-h` and tab completion (`nv sh int` works).

> The 3rd (spare) SN5610 is out of scope: leave it unconfigured/powered per site
> policy and document its state.

### 7b. SN2201 (1GbE management)

Baseline only — bring up the ports facing the nodes' OCP/XCC links:

```bash
nv set interface swp<mgmt-port-range> link state up
nv config apply
nv show interface
```

MTU stays at the 1500 default on the mgmt switch (mgmt network is MTU 1500).

Reference: NVIDIA Cumulus "Switch Port Attributes" and "NVUE CLI" docs
(see docs/references.md).

---

## 8. Link-speed and end-to-end MTU verification

From each node (after §5–§7 and after the §02 interfaces are live; for a
bring-up-only check you may assign temporary IPs to the physical ports):

```bash
# 200G negotiation on both BF3 ports:
ethtool <BF3_P1> | grep -E 'Speed|Link detected|Duplex'
ethtool <BF3_P2> | grep -E 'Speed|Link detected|Duplex'
# PASS on each: Speed: 200000Mb/s, Duplex: Full, Link detected: yes

# 1GbE mgmt port:
ethtool <MGMT_IF> | grep -E 'Speed|Link detected'
# PASS: Speed: 1000Mb/s, Link detected: yes

# End-to-end MTU 9000 across the fabric (8972 = 9000 - 20 IP - 8 ICMP):
ping -M do -s 8972 -c 4 <peer-node-cluster-ip>
# PASS: 0% packet loss, no fragmentation warnings
```

Run the MTU ping node-to-node across all pairs on the ceph-cluster VLAN (and the
ceph-public VLAN). Any failure here is a cabling/MTU misconfiguration — fix
before §03.

---

## 00a acceptance checklist

- [ ] Rack, N+N power, XCC reachable on all nodes (§1)
- [ ] XCC/BMC firmware flashed first, then UEFI/adapters; levels recorded (§2)
- [ ] `storcli /c0/vall show` empty; `set jbod=on` applied and verified (§3)
- [ ] PM1743s at PCIe x4/32GT/s **and** absent from StorCLI on every node (§4)
- [ ] BF3 in NIC mode, both ports Ethernet, 200G links up (§5)
- [ ] Cabling audit table filled and signed off against cable-diagram.svg (§6)
- [ ] SN5610-A/B breakout + MTU 9216 applied and verified; SN2201 mgmt ports up (§7)
- [ ] 200000Mb/s on all BF3 ports, 1000Mb/s on mgmt, MTU-9000 ping clean node-to-node (§8)
