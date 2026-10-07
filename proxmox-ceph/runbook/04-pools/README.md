# 04 — RBD pools

Create the VM-storage RBD pool (the pool VMs and LXC volumes live on), with replication, PG autoscaling, and capacity guidance. Optional second-pool guidance for bulk/scratch data.

**Design targets:** `vm-storage`, size=3 / min_size=2, PG autoscale **on** (the default is `warn` — always override it), RBD application, registered as Proxmox storage.

**Variables** — defined in [00-overview/variables.sh](../00-overview/variables.sh); **do not redefine them here**, source the file first:

```bash
source ../00-overview/variables.sh
# Expected names: POOL_VM_NAME (default "vm-storage"),
#                 POOL_VM_TARGET_SIZE (e.g. "5T" — see capacity math below)
# Placeholders if variables.sh is not yet populated:
#   POOL_VM_NAME="vm-storage"
#   POOL_VM_TARGET_SIZE="5T"
```

Run pool commands on any node (they execute against the cluster).

---

## Prerequisites

- §03 complete: 6 OSDs up, `HEALTH_OK`, CRUSH `host` failure domain verified.

---

## Step 1 — Create the vm-storage pool

```bash
pveceph pool create "${POOL_VM_NAME:-vm-storage}" \
  --size 3 --min_size 2 \
  --pg_num 128 \
  --pg_autoscale_mode on \
  --target_size "${POOL_VM_TARGET_SIZE:-5T}" \
  --application rbd \
  --add_storages
```

Flag-by-flag:

- `--size 3` — three copies of every object. One replica lands on each node (see §03 CRUSH rule).
- `--min_size 2` — writes proceed as long as **two** replicas are writable. This is the pair that makes the cluster survivable: lose one node, one replica goes dark, but the remaining two keep serving I/O and quorum holds. `min_size=1` would risk split-brain writes; `min_size=3` would stall I/O on any single OSD failure. 3/2 is the correct setting for a 3-node cluster — do not change it without redesigning the topology.
- `--pg_num 128` — starting PG count for this pool (PGs × OSDs ≈ 768, well within the ~100–200 PGs-per-OSD sweet spot: 128 PGs × 3 replicas ÷ 6 OSDs = 64 PGs per OSD). Autoscale adjusts from here as data grows.
- `--pg_autoscale_mode on` — **mandatory, not optional.** `pveceph pool create` defaults this to `warn` (it nags instead of scaling). With `on`, Ceph grows/shrinks PG counts automatically as the pool fills. A stale PG count is how clusters end up with hot OSDs years later — set it now, at creation.
- `--target_size 5T` — tells the autoscaler how big the pool is *expected* to get, so it picks sane PG counts before the data exists. Estimate conservatively (see capacity math); overshooting here only affects PG count, not allocation.
- `--application rbd` — tags the pool for RBD use (enables RBD-specific health checks).
- `--add_storages` — registers the pool as Proxmox storage (Datacenter → Storage) so VM disks can be provisioned on it directly.

Verify:

```bash
ceph osd pool autoscale-status
```

Expect `vm-storage` with `AUTOSCALE on`. Also:

```bash
ceph osd pool get vm-storage size        # 3
ceph osd pool get vm-storage min_size    # 2
ceph df                                  # pool visible, capacity math below
```

---

## Capacity math — why "plan ~5TB of ~7.68TB theoretical"

Raw: 6 × 3.84 TB = **23.04 TB**. At size=3, theoretical usable = 23.04 ÷ 3 = **7.68 TB**.

**Do not plan to fill 7.68 TB.** The ~5 TB target is the *node-failure headroom*, and it falls out of the failure arithmetic:

1. Lose one node → 4 OSDs survive → 15.36 TB raw → 15.36 ÷ 3 = **5.12 TB usable**.
2. If the pool held 7 TB, the surviving cluster would be at ~137% of its post-failure capacity — Ceph hits `full_ratio` (default 0.95 of *raw*), stops writes, and you have a full-cluster outage precisely when you can least afford one.
3. Targeting **~5 TB** (≈ 65% of theoretical) keeps the cluster writable through a node loss and leaves headroom for recovery backfill after the node returns.

Rule of thumb to carry forward: **plan usable ≤ ~2/3 of theoretical usable at size=3.** That is the whole budget: VM disks, LXC volumes, and snapshots all draw from it. Track actual fill in §07 acceptance (alert thresholds are a §02/§07 concern, not a pool-creation one).

## Step 2 (optional) — A second pool for bulk/scratch data

Add a second pool only when there is a genuine two-tier need — e.g. a scratch/archive dataset where capacity matters more than surviving a node loss:

```bash
# DESTRUCTIVE-CAPABLE: pool deletion is irreversible. Create is safe; deletion is not.
pveceph pool create bulk-scratch \
  --size 2 --min_size 1 \
  --pg_num 64 \
  --pg_autoscale_mode on \
  --target_size "<estimate>" \
  --application rbd \
  --add_storages
```

- `size=2 / min_size=1` buys ~11.5 TB theoretical usable from the same 6 OSDs — but a node loss leaves some objects with a single copy and I/O stalls for any object whose replicas were both on dead hardware. This pool is for data you can afford to lose or can rebuild (build artifacts, staging copies, non-critical bulk). **Never put production VM disks on it.**
- If a second pool shares the same OSDs (it does, here), it competes for the same capacity budget — subtract its target_size from the ~5 TB vm-storage budget, or you will over-commit the cluster.
- When you would *not* add one: if the workload is all production VMs. One pool, full budget, simpler operations.

---

## Verification checklist

- [ ] `ceph osd pool autoscale-status`: `vm-storage` shows `on`
- [ ] `ceph osd lspools`: pool(s) listed with `application rbd`
- [ ] `pvesm status`: `vm-storage` appears as Proxmox storage, enabled on all nodes
- [ ] `ceph df`: pool capacity math sane; cluster at ≤ 65% of theoretical usable

## References

Full link list lives in [docs/references.md](../../docs/references.md); the ones this section leans on:

- https://pve.proxmox.com/pve-docs/pveceph.1.html — pveceph(1): pool create flags.
- https://docs.ceph.com/en/tentacle/rados/operations/placement-groups/ — Placement groups & pg_autoscale_mode semantics.
