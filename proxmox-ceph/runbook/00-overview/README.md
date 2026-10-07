# 00 — Overview

## Purpose

Project Cerberus is a **reusable, customer-agnostic runbook template** for building a
3-node hyperconverged Proxmox VE + Ceph cluster on Lenovo ThinkSystem SR650 V4 hardware
over an NVIDIA SN5610 800GbE (Cumulus) fabric. It is built customer-agnostic from day
one: role-based node names (`node-1/2/3`), every site value behind a variable, and no
customer-identifying information anywhere in the repo.

The runbook covers the **full build**: physical bring-up verification, Proxmox VE
cluster install, host networking, Ceph deployment, pools, HA, Proxmox Backup Server,
and validation/failure testing with acceptance sign-off.

## Scope

In scope:

- Rack/power/cabling verification of 3x SR650 V4 + 2x SN5610 + SN2201 mgmt (00a)
- Firmware baseline (XCC/BMC, UEFI, adapters) via XCC and OneCLI (00a)
- Proxmox VE 9.2.x install and 3-node cluster formation (01)
- Host networking: bonds, bridges, VLANs, MTU, corosync links (02)
- Ceph Tentacle deployment: MON/MGR/OSD, CRUSH (03)
- RBD pools with size=3/min_size=2 and pg autoscaling (04)
- Proxmox HA with hardware watchdog fencing (05)
- Proxmox Backup Server on a dedicated host: datastores, jobs, retention (06)
- Validation: OSD failure, node loss, network partition, restore drill (07)

## Assumptions (locked design decisions and limitations)

Read all of these before starting. Anything here that does not match the site means
the runbook needs adaptation first.

1. **3 nodes** (`node-1`, `node-2`, `node-3`). A 4th node is optional; short
   "node-4" callouts mark where behavior differs. 2-node and 5+-node layouts are
   not covered.
2. **Proxmox VE 9.2.x**, installed from ISO, using the **no-subscription** package
   repositories. (Substitute the enterprise repo if the site holds subscriptions —
   the repo file is the only change.)
3. **Ceph Tentacle** (20.2.x). Do not install Squid on greenfield builds (EOL
   ~Sept/Oct 2026 — re-check https://docs.ceph.com/en/latest/releases/ at deploy time).
4. **Synchronous replication, size=3/min_size=2** on all pools. No erasure coding,
   no cache tiering, no async/external tiering.
5. **Dedicated OSD drives**: the 2x 3.84TB Samsung PM1743 U.3 NVMe per node are
   Ceph-only. The OS lives on the 2x 960GB M.2 HW RAID1 pair (B550i-2i).
6. **NVMe must be direct-to-CPU x4** — NOT behind the RAID 940-8i (whose NVMe U.3
   support is x1 ≈ 2 GB/s vs ~14 GB/s direct). The 940-8i runs **JBOD only**, never
   HW RAID. Section 00a verifies both; wrong cabling is a STOP-and-recable event.
7. **BlueField-3 B3220 in Ethernet NIC mode** (2x 200G). DPU/ECPF mode is out of
   scope. No InfiniBand for the Proxmox fabric: the Q3400 XDR IB switch is SPARE
   (AI/GPU side) — **no IPoIB for Ceph**, Ethernet only.
8. **Dedicated PBS host** (separate physical machine, reachable on the mgmt
   network). Proxmox docs explicitly caution against installing PBS on the
   hypervisor nodes themselves.
9. **No DDN storage** anywhere in the design — not spec'd, not quoted, not plumbed.
10. **No vendor integration kit** (no EveryScale): the builder racks and cables
    baremetal, so this runbook owns the full physical bring-up verification (00a).
11. **Corosync link0 on the 1GbE management network** (physically separate NIC from
    the 200G fabric). Optional link1 on the Ceph public VLAN.
12. **Fencing = watchdog self-fencing only.** Proxmox HA has no external IPMI/STONITH
    fence agents; the supported equivalent on this hardware is the IPMI hardware
    watchdog configured inside each host (05).
13. **Customer-anonymized throughout.** Role-based names only; site values live in
    `variables.sh`, never hardcoded in steps.
14. **Built for lab reuse** as well as customer builds.

### Explicitly NOT covered

- Application/VM workload migration or sizing (beyond the storage headroom plan).
- Ceph or Proxmox **major-version upgrades** (fresh-build runbook only).
- Stretch clusters / multi-site, IPv6, encryption-at-rest configuration.
- LACP/MLAG on the SN5610 pair (documented as the higher-bandwidth *alternative*
  to the recommended active-backup bond, not configured here).
- Warranty/RMA handling, site power/cooling design beyond the rack check.
- The spare (3rd) SN5610 and the Q3400 IB switch (AI fabric — separate runbook).

## Network plan

| Network | VLAN | CIDR (placeholder) | MTU | Physical path | Purpose |
|---|---|---|---|---|---|
| mgmt | untagged | `10.10.10.0/24` | 1500 | OCP 1GbE → SN2201 | Proxmox mgmt, corosync link0, XCC/BMC, PBS |
| ceph-public | 100 | `10.20.20.0/24` | 9000 | bond0 (active-backup, 2×200G BF3) → SN5610-A/B | Ceph client traffic + VM/guest traffic |
| ceph-cluster | 200 | `10.20.30.0/24` | 9000 | same bond0 (VLAN sub-if) → SN5610-A/B | OSD replication / recovery / backfill / heartbeat |
| fabric underlay | — | — | 9216 | OSFP-800G → 4×200G breakout DACs | switch-side jumbo headroom (Cumulus default) |

Per-node IP plan (placeholders — resolve in `variables.sh`):

| Node | mgmt | ceph-public (.100) | ceph-cluster (.200) | XCC |
|---|---|---|---|---|
| node-1 | 10.10.10.11 | 10.20.20.11 | 10.20.30.11 | 10.10.10.21 |
| node-2 | 10.10.10.12 | 10.20.20.12 | 10.20.30.12 | 10.10.10.22 |
| node-3 | 10.10.10.13 | 10.20.20.13 | 10.20.30.13 | 10.10.10.23 |
| node-4 (opt) | 10.10.10.14 | 10.20.20.14 | 10.20.30.14 | 10.10.10.24 |

Switch naming: `sn5610-a` / `sn5610-b` carry the fabric (see
[docs/diagrams/cable-diagram.svg](../../docs/diagrams/cable-diagram.svg) for the
DAC leg → port mapping); `sn2201-mgmt` is the 1GbE management switch. The 3rd
SN5610 is spare.

## Variables

**`variables.sh`** (this directory) is the single source of truth for every site
value. All later sections source it:

```bash
set -u
source ./variables.sh
```

Conventions:

- Every value has a `PLACEHOLDER` default (or is intentionally empty for
  host-resolved values like the BlueField-3 kernel interface names).
- `cerberus_require_vars VAR...` fails fast if a variable is still a placeholder.
- `cerberus_audit_placeholders` lists everything still needing a site value.
- Host-specific values (`BF3_P1`, `BF3_P2`, `MGMT_IF`) are resolved per node in
  02-network §1 and exported before sourcing.

Resolve the placeholders for the site **before** starting 00a. The physical
bring-up steps need real XCC IPs; the install steps need final hostnames and IPs
(hostname/IP changes after clustering are not supported).

## Section map

| Section | Title | What it produces |
|---|---|---|
| 00a | Physical bring-up verification | Rack/power/cabling/firmware proven good, or STOP |
| 01 | Cluster install | PVE 9.2 on 3 nodes, `cerberus` cluster, quorum |
| 02 | Network configuration | bonds/bridges/VLANs/MTU live on all nodes |
| 03 | Ceph setup | MONs/MGRs/OSDs up, Tentacle healthy |
| 04 | Pools | RBD pools, size=3/min_size=2, autoscale on |
| 05 | HA | HA rules, hardware watchdog fencing |
| 06 | PBS | Dedicated backup host, datastores, jobs, retention |
| 07 | Validation | Failure drills passed, acceptance sign-off |

Reference: [docs/references.md](../../docs/references.md) — the official-doc link
index each section leans on. Design background:
[docs/runbook-starting-point.md](../../docs/runbook-starting-point.md).
