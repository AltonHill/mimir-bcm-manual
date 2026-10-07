# 03 — Ceph cluster deployment

Deploy Ceph Tentacle on the three hyperconverged nodes: install, initialize, MON/MGR placement, and OSD creation on the PM1743 NVMe pair per node.

**Design targets:** PVE 9.2.x + Ceph Tentacle 20.2.4. Three MONs (one per node), colocated MGRs, 6 OSDs (2 per node), default replicated CRUSH rule against the `host` failure domain.

**Variables** — defined in [00-overview/variables.sh](../00-overview/variables.sh); **do not redefine them here**, source the file first:

```bash
source ../00-overview/variables.sh
# Expected names: CEPH_PUBLIC_NET, CEPH_CLUSTER_NET
# Placeholders if variables.sh is not yet populated:
#   CEPH_PUBLIC_NET="<ceph-public-CIDR, e.g. 10.20.30.0/24>"
#   CEPH_CLUSTER_NET="<ceph-cluster-CIDR, e.g. 10.20.31.0/24>"
```

All `pveceph` steps below run as `root`. Steps marked "each node" must be executed on every node (node-1, node-2, node-3).

---

## Prerequisites

- §01 cluster join and §02 network are complete: the Ceph public and cluster networks are up on every node, MTU 9000 verified end-to-end.
- §00a physical bring-up has **confirmed the PM1743s are wired direct-to-CPU (x4)** and do NOT appear in `storcli /c0/pall`. If any NVMe shows up under StorCLI, stop — recable before continuing.

---

## Step 1 — Install Ceph Tentacle (each node)

```bash
pveceph install --version tentacle --repository no-subscription
```

- `tentacle` is explicit on purpose: **Squid is EOL — never pin Squid on a greenfield build.** (Verify at deploy time on the [Ceph active-releases table](https://docs.ceph.com/en/latest/releases/).)
- `--repository no-subscription` pulls from the public `download.proxmox.com` Ceph repo. For licensed builds use `--repository enterprise` (requires a Proxmox VE Ceph subscription key). Do not use `test` for production.
- Verify on each node afterwards: `ceph --version` — expect `20.2.x` Tentacle on all three. All nodes must run the same major release.

## Step 2 — Initialize the Ceph cluster (node-1 only)

```bash
pveceph init --network "${CEPH_PUBLIC_NET}" --cluster-network "${CEPH_CLUSTER_NET}"
```

- `--network` = Ceph public (client/VM I/O) network; `--cluster-network` = replication/recovery heartbeat network.
- Defaults baked into `pveceph init` already match this design: `size=3`, `min_size=2`. The flags `--size`/`--min_size` exist if a variant build ever needs different values.
- This writes `/etc/ceph/ceph.conf` and keyrings on node-1; they are distributed via `/etc/pve` (pmxcfs) to the other nodes automatically.

## Step 3 — Create the monitors (node-1, node-2, node-3)

On **node-1** first (the first MON auto-creates a manager):

```bash
pveceph mon create
```

Then on **node-2** and **node-3**:

```bash
pveceph mon create
```

- Defaults: `monid` = node name, address auto-detected on the public network. Override with `--monid`/`--mon-address` only if the node has multiple addresses on the public network.
- Verify quorum before continuing:

```bash
ceph -s        # look for: mon: 3 daemons, quorum node-1,node-2,node-3
ceph quorum_status
```

> **node-4 callout:** a fourth node gets **no new MON**. Three MONs is the quorum sweet spot; a fourth MON adds failure *risk* to quorum math with zero benefit. The optional 4th node runs OSDs and compute only.

## Step 4 — Create managers (node-2, node-3)

node-1 already has a manager from Step 3. On node-2 and node-3:

```bash
pveceph mgr create
```

Verify:

```bash
ceph -s | grep mgr   # expect: mgr: 3 daemons active
```

## Step 5 — Create the OSDs (on each node, for its own drives)

> **DESTRUCTIVE — this wipes the target device.** Only ever run against the `/dev/disk/by-id/` names of the two PM1743 NVMe drives on that node. Double-check each ID before pressing enter.

On **node-1** (its two PM1743s):

```bash
pveceph osd create /dev/disk/by-id/<nvme-id-for-node-1-disk-1>
pveceph osd create /dev/disk/by-id/<nvme-id-for-node-1-disk-2>
```

Repeat on **node-2** and **node-3** for their own drives (six OSDs total).

- **Why whole-disk, and why no flags here:** `pveceph osd create` defaults to whole-disk `ceph-volume` provisioning with block, DB, and WAL all colocated on the same NVMe. That is exactly right for this hardware:
  - `--osds-per-device 2` splits one NVMe into two OSDs — it buys nothing on a PM1743 (Gen5, plenty of queue depth per device; splitting doubles per-OSD overhead and fragments placement) and is **mutually exclusive** with `--db_dev`/`--wal_dev`.
  - `--db_dev`/`--wal_dev` exist to put metadata/WAL on a *faster* device than a slow spinner — irrelevant here; block+db+wal all live on the same fast NVMe.
- Verify:

```bash
ceph osd tree
```

Expected shape — CRUSH host failure domain, 2 OSDs per host:

```
ID  CLASS  WEIGHT   TYPE NAME        STATUS  REWEIGHT  PRI-AFF
-1         21.00000  root default
-3          7.00000      host node-1
 0   nvme   3.50000          osd.0      up   1.00000  1.00000
 1   nvme   3.50000          osd.1      up   1.00000  1.00000
-5          7.00000      host node-2
 2   nvme   3.50000          osd.2      up   1.00000  1.00000
 3   nvme   3.50000          osd.3      up   1.00000  1.00000
-7          7.00000      host node-3
 4   nvme   3.50000          osd.4      up   1.00000  1.00000
 5   nvme   3.50000          osd.5      up   1.00000  1.00000
```

- All 6 OSDs `up`, class `nvme`, correct host mapping. If an OSD landed on the wrong host or is missing, fix before pools — misplacement here corrupts the failure domain for everything above.

## Step 6 — CephX auth check (aes256k rollout item)

Tentacle 20.2.4 (2026-08-19) fixed several CVEs including the CephX auth bypass (CVE-2025-30156) and introduced the new CephX key cipher **`aes256k`**. Run this during bring-up — it is a checklist item, not a patch you can defer:

```bash
pveceph auth status
```

- Confirm the cluster's keys report the new cipher. **Client keys are NOT auto-rotated** — per-client migration is manual if any legacy keys remain in use.
- PVE 9.2 ships kernel 7.0, which satisfies the kernel ≥ 7.0 requirement for AES256 key support on Ceph clients (relevant if Ceph-CSI clients are ever attached).

## Step 7 — CRUSH rule review

```bash
ceph osd crush rule dump replicated_rule
```

- The default `replicated_rule` is **correct for this topology and needs no changes.** It takes from `host` (failure-domain `host`), so the three replicas of every object land on three different *hosts* — one per node, spread across that node's two OSDs by the placement algorithm.
- Why that matters: with replicas spread host-wise, losing an entire node degrades the pool to 2/3 replicas (still ≥ `min_size=2`) instead of losing data. A per-OSD rule would risk placing two replicas on the same dead node.
- Revisit only when hardware changes (e.g. a 4th node — still host-spread; expansion bays — still per-host). Device-class rules are unnecessary: all OSDs are `nvme`.

## Verification checklist

- [ ] `ceph -s`: `mon: 3 daemons, quorum …`, `mgr: 3 daemons active`, `osd: 6 osds: 6 up, 6 in`, `health: HEALTH_OK`
- [ ] `ceph osd tree`: 2 OSDs under each of node-1/2/3, all class `nvme`
- [ ] `pveceph auth status`: aes256k cipher reported, no stale keys
- [ ] `ceph health detail` returns nothing (no warnings)

## References

Full link list lives in [docs/references.md](../../docs/references.md); the ones this section leans on:

- https://pve.proxmox.com/pve-docs/pveceph.1.html — pveceph(1) man page: install/mon/mgr/osd/pool flags.
- https://docs.ceph.com/en/tentacle/ — Ceph Tentacle documentation home.
- https://docs.ceph.com/en/latest/releases/ — Active-releases table: Tentacle vs Squid EOL check at deploy time.
