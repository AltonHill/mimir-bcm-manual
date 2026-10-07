# 3-Node Hyperconverged Ceph Runbook — Starting Point

_Drafted 2026-10-07. Customer-anonymized throughout (role-based names only). Full step-by-step runbook is parked until the open questions are answered. This is a reusable template — built customer-agnostic from day one (lab reuse intended)._

## 1. Locked-in design decisions

- **Hyperconverged architecture** — compute and storage on the same nodes. Proxmox VE hypervisor + Ceph on each of the 3 nodes; no separate storage tier.
- **3 nodes** (4th possible, still being decided) — the minimum for a self-healing Ceph quorum (3 MONs, one per node; the cluster tolerates one node down).
- **Internal NVMe OSDs** — Ceph runs on drives physically inside the nodes; no external storage appliance in the data path.
- **Synchronous replication** — writes replicate synchronously across nodes (target size=3/min_size=2, to be confirmed in the full runbook); no async or external tiering.
- **DDN off-limits** — DDN storage is excluded from the design; not to be spec'd, quoted, or plumbed in.
- **Proxmox Backup Server planned** — PBS is part of the design from the start for backup/restore, not an afterthought (dedicated host vs. VM, datastore sizing TBD).

## Hardware (from BOM, 2026-10-07)

Per node — ThinkSystem SR650 V4:
- 2x Intel Xeon 6527P (24C, 3.0GHz, 255W) → 48C/96T per node
- 16x 64GB DDR5-6400 → 1TB RAM per node
- 2x 3.84TB Samsung PM1743 U.3 NVMe PCIe 5.0, read-intensive (1 DWPD / 7008 TBW) → 7.68TB raw/node
- 2x 960GB M.2 NVMe (boot pair, B550i-2i HW RAID1) — OS dedicated, OSD drives dedicated
- 1x NVIDIA BlueField-3 B3220, 2x 200G QSFP112 VPI (run in Ethernet NIC mode)
- 1x Broadcom 5719 4x 1GbE OCP (management)
- 1x RAID 940-8i 4GB tri-mode (SAS/SATA/NVMe U.3 x1, JBOD-capable)
- 2x 1300W Titanium PSU (N+N), 3yr Premier NBD warranty

Cluster (3 nodes): 144C/288T, 3TB RAM, 23.04TB raw NVMe → ~7.68TB usable at size=3; plan ~5TB usable with headroom. Storage is the binding constraint; SR650 V4 has up to 24 SFF bays (2 populated) — expansion wide open.

## 2. Open questions — need answers before the full runbook

**Answered by the BOM:**
- NVMe count per node → 2x 3.84TB PM1743 per node.
- Dedicated vs. OS-shared drives → dedicated. OS lives on the M.2 RAID1 pair; the U.3 NVMe are OSD-only.
- Per-node RAM/CPU headroom → 1TB RAM + 96 threads per node vs. a few GB per OSD: no contention. Compute-heavy relative to storage.

**Still open:**
1. **Backplane cabling** — are the U.3 NVMe wired direct-to-CPU (x4), or behind the 940-8i (x1 ≈ 2GB/s per drive vs ~14GB/s direct)? Must verify; JBOD, never HW RAID.
2. **200G cabling (call-out, Loki says cables are covered)** — per node 2× 200G into the SN5610s via OSFP-800G → 4× QSFP112-200G breakout DACs (in-rack; 2 DACs cover 3 nodes, exactly 2 cover 4 nodes); land each node's two links on different SN5610s. Cross-rack → breakout AOCs or SM optics. Plus 2–4× Cat6 per node for OCP 1GbE → SN2201 (BOM ships 1/server).
3. **3 vs 4 nodes** — now purely quorum/capacity (network is a non-issue with the SN5610 fabric). 3 is the quorum sweet spot; 4th adds capacity, no quorum benefit (MONs stay at 3).
4. **Network topology** — which 2 of the 3 SN5610s carry the Proxmox storage fabric (3rd = AI fabric or spare?); corosync placement (1GbE OCP vs VLAN on the 200G fabric); bonding/MLAG design.
5. **Ceph cluster network separation** — dedicated replication/cluster network, or shared with client/frontend traffic? (2× 200G/node gives room either way.)
6. **Jumbo frames** — MTU 9000 on the Ceph cluster network (feasible — Cumulus on SN5610; still needs the decision).
7. **Workload profile** — write-heavy? Decides whether read-intensive PM1743s are fine or mixed-use drives are warranted.
8. **PBS placement** — dedicated host vs. VM, datastore sizing and retention.

**Resolved by the revised BOM (2026-10-07):** the high-speed fabric exists — 3× NVIDIA SN5610 800GbE (Cumulus); the Proxmox cluster lives on Ethernet there. The Q3400-RA 144-port Quantum XDR InfiniBand switch is marked SPARE (AI/GPU side, not Proxmox — no IPoIB for Ceph). 7× SN2201 1GbE switches cover management. **No EveryScale** — Lenovo is not doing integration; CDW builds baremetal, so the runbook owns the full physical bring-up verification (new outline section 00a).

## 3. Full runbook section outline (step-by-step comes later)

- **00 — Overview and variables** — role-based node names, network plan, placeholder inventory.
- **00a — Physical bring-up verification** — rack/power check, cabling audit (breakout DAC legs → correct switch ports), link state and negotiated speeds on all 200G + 1GbE links, switch baseline config (Cumulus), end-to-end MTU 9000 check. (No EveryScale — CDW builds baremetal, so the runbook owns this.)
- **01 — Proxmox VE cluster install** — install on all 3 nodes, cluster join, quorum verification.
- **02 — Network configuration** — bonds, bridges, VLANs, MTU, cluster network.
- **03 — Ceph setup** — MON/MGR deployment, OSD creation, CRUSH layout.
- **04 — Pools** — VM/data pools, size/min_size, pg autoscaling.
- **05 — HA** — Proxmox HA groups, fencing, expected behavior on node loss.
- **06 — Proxmox Backup Server** — install, datastores, backup jobs, retention policy.
- **07 — Validation and failure testing** — OSD failure, node power loss, network partition, backup-restore drill, acceptance sign-off.
