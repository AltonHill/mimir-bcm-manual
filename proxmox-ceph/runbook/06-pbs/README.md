# 06 — Proxmox Backup Server (dedicated host)

PBS 4.2. Backs up the cluster's VMs/containers. **PBS runs on a dedicated physical
host — never on the hypervisor nodes themselves** (official Proxmox caution).

Conventions for this section: variables-first (all values come from
[../00-overview/variables.sh](../00-overview/variables.sh) — never hard-code per-site
values in commands). Replace the EXAMPLE IPs below with your site's values.

> **Docs this section leans on:** PBS docs home, `proxmox-backup-manager` man page,
> and the backup-client guide — see [../../docs/references.md](../../docs/references.md)
> (Backup section). Also see research note: **S3-compatible object storage backend is
> GA in PBS 4.2** — usable as an alternative/secondary datastore backend if the
> customer has S3 capacity; see "S3 backend option" at the end.

---

## 6.1 — Install PBS on the dedicated host (recommended: ISO)

1. Download the PBS 4.2 ISO from the Proxmox download page; install bare-metal on
   the dedicated host (graphical or serial installer; management interface on the
   MGMT network).
2. After first boot, verify the version and join it to the same tailnet/site DNS
   so the PVE nodes can reach it by name:

```bash
proxmox-backup-manager version        # expect 4.2.x
ping -c3 node-1   # reachability both ways
```

### Alternative: Debian 13 minimal + pbs-no-subscription repo

Only if an ISO install is not possible. The repo source in **deb822** format:

```bash
wget https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg \
  -O /usr/share/keyrings/proxmox-archive-keyring.gpg

cat > /etc/apt/sources.list.d/proxmox.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pbs
Suites: trixie
Components: pbs-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

apt update && apt install -y proxmox-backup-server
```

## 6.2 — Fingerprint capture (do this once, keep it safe)

The PVE nodes pin the PBS server's TLS fingerprint. Capture it now and store it in
the site inventory (it goes into `pvesm add pbs` and into
`scripts/backup-drill.sh`'s environment later).

```bash
proxmox-backup-manager cert info | grep -i fingerprint
# -> save the SHA256 line verbatim as PBS_FINGERPRINT
```

## 6.3 — Datastore creation + retention policy

Create one datastore on the backup host's local (or SAN-attached) storage path.
Retention here uses **`--keep-*` flags** — these are correct on the PBS side.

> ⚠️ **The #1 copy-paste error:** PBS datastore commands use `--keep-daily` etc.
> PVE backup **jobs** do NOT have `--keep-*` — they use
> `--prune-backups "keep-daily=7,..."` (§6.6 below). Swap them and the command
> fails (or silently misbehaves). Watch for this in every community guide you read.

```bash
# All variables from ../00-overview/variables.sh
source ../00-overview/variables.sh

proxmox-backup-manager datastore create "$PBS_DATASTORE" /mnt/backup-cerberus \
  --comment "Cerberus cluster backup datastore" \
  --keep-daily 7 --keep-weekly 4 --keep-monthly 6 \
  --gc-schedule daily \
  --prune-schedule daily \
  --verify-new 1 \
  --notify "gc=always,prune=always,sync=always,verify=always" \
  --notify-user admin@pbs

proxmox-backup-manager datastore list
```

| Setting | Value | Why |
|---|---|---|
| `--keep-daily 7` | 7 daily snapshots | matches the PVE job prune below |
| `--keep-weekly 4` | 4 weekly snapshots | matches |
| `--keep-monthly 6` | 6 monthly snapshots | matches |
| `--gc-schedule daily` | garbage collection daily | reclaims chunks freed by prune |
| `--prune-schedule daily` | pruning daily | enforces retention server-side (belt & braces with the job-level prune) |
| `--verify-new 1` | verify new backups | each new snapshot is verify-checked once after creation |
| `--notify ...=always` | email on every run | swap to `failure` if the customer finds daily mail noisy |

Adjust with `datastore update` (same flags):

```bash
proxmox-backup-manager datastore update "$PBS_DATASTORE" \
  --gc-schedule daily --prune-schedule daily \
  --keep-daily 7 --keep-weekly 4 --keep-monthly 6
```

## 6.4 — Datastore sizing guidance

Size the datastore against the **retention depth × live data × change rate**, not
just against the Ceph pool's usable capacity. The protected pool holds ~5 TB live,
but 17 retained snapshots accumulate changed chunks.

**Formula:**

```
datastore_capacity ≈ Σ(protected VM disk sizes) × (1 + daily_change_rate × Σ(retained days))
```

Where `Σ(retained days)` = 7 (daily) + 28 (4 weekly) + 180 (6 monthly) = 215, but
weekly/monthly snapshots mostly share chunks with the dailies — use the *change
window* of ~31 days for the incremental tail.

**Worked example against the ~5 TB usable Ceph pool:**

- Protected VM disks (live): **4 TB** (out of ~5 TB usable)
- Daily change rate: **5 %** (typical for mixed server VMs; measure real with `proxmox-backup-client` stats)
- Incremental tail: 0.05 × 4 TB × 31 days = **6.2 TB**
- Base full (one full snapshot's chunks, deduped/compressed): ~4 TB × ~0.6 (zstd + chunk dedup on OS disks) ≈ **2.4 TB**
- Total ≈ 2.4 + 6.2 = **8.6 TB**

→ **Provision ≥ 12 TB for the datastore** (≈ 1.4× headroom for growth and GC
lag). If the workload is write-heavy (>10 % daily churn), re-run the formula with
the measured rate — a 20 % churn workload needs ~24 TB. Dedup in PBS is excellent
for OS disks and poor for already-compressed/encrypted data; assume worst-case
compression ratios in the estimate.

## 6.5 — Backup user, token, and ACL

Least-privilege: one dedicated user per cluster, one token, scoped to the datastore.

```bash
source ../00-overview/variables.sh

# Section-local defaults (not in variables.sh — the site names these at §06.5):
PBS_BACKUP_USER="${PBS_BACKUP_USER:-pve-backup@pbs}"
PBS_TOKEN_NAME="${PBS_TOKEN_NAME:-pve-token}"

proxmox-backup-manager user create "$PBS_BACKUP_USER" \
  --comment "PVE backup user for Cerberus cluster"

# Generates and PRINTS the token value — copy it once, store it securely
# (site secrets vault). It cannot be displayed again.
proxmox-backup-manager user generate-token "$PBS_BACKUP_USER" "$PBS_TOKEN_NAME"

# Scope the token to the datastore (DatastoreAdmin lets the job prune + upload)
proxmox-backup-manager acl update "/datastore/$PBS_DATASTORE" DatastoreAdmin \
  --auth-id "$PBS_BACKUP_USER!$PBS_TOKEN_NAME"
```

Save: `PBS_FINGERPRINT`, and `PBS_PASSWORD` = the token value printed above.

## 6.6 — PVE side: register PBS storage + create the backup job

Run on any PVE node (commands replicate across the cluster).

```bash
source ../00-overview/variables.sh

# 1) Register PBS as a PVE storage target
pvesm add pbs pbs-cerberus \
  --server "$PBS_HOST_IP" \
  --datastore "$PBS_DATASTORE" \
  --username "$PBS_BACKUP_USER!$PBS_TOKEN_NAME" \
  --password "$PBS_PASSWORD" \
  --fingerprint "$PBS_FINGERPRINT"

# 2) Create the nightly backup job.
#    NOTE: retention uses --prune-backups, NOT --keep-*. There is NO --keep-* on
#    pvesh/vzdump. (Repeating because this is the most common copy-paste error.)
pvesh create /cluster/backup \
  --schedule "02:00" \
  --storage pbs-cerberus \
  --mode snapshot \
  --all 1 \
  --compress zstd \
  --mailto "$MAILTO" \
  --mailnotification failure \
  --prune-backups "keep-daily=7,keep-weekly=4,keep-monthly=6" \
  --comment "Nightly cluster backup to dedicated PBS host"

# 3) Inspect and manage
pvesh get /cluster/backup
pvesh delete /cluster/backup/<job-id>   # if re-creating
```

Retention table (both sides must agree):

| Level | PVE job (`--prune-backups`) | PBS datastore (`--keep-*`) | Verify | GC |
|---|---|---|---|---|
| daily | `keep-daily=7` | `--keep-daily 7` | `--verify-new 1` | `--gc-schedule daily` |
| weekly | `keep-weekly=4` | `--keep-weekly 4` | — | — |
| monthly | `keep-monthly=6` | `--keep-monthly 6` | — | — |
| prune run | client-side at job end | `--prune-schedule daily` | — | — |

## 6.7 — Restore drill procedure (run once after first successful backup, then per §07)

Restores are done with `proxmox-backup-client` from any host with the repo env set.
**Never restore over a production VM's disk during the drill** — restore to a
scratch path and verify, or restore a *test* VM and boot it (the guided
[scripts](../../scripts/backup-drill.sh) wraps this flow).

```bash
source ../00-overview/variables.sh
: "${PBS_BACKUP_USER:=pve-backup@pbs}" "${PBS_TOKEN_NAME:=pve-token}"
: "${PBS_FINGERPRINT:?set from §6.2}" "${PBS_PASSWORD:?token value from §6.5}"

export PBS_REPOSITORY="$PBS_BACKUP_USER@$PBS_HOST_IP:$PBS_DATASTORE"
export PBS_FINGERPRINT="<sha256 from §6.2>"
export PBS_PASSWORD="<token value from §6.5>"

# 1) List available snapshots for the test VM
proxmox-backup-client snapshot list vm/<vmid>     # add --ns <namespace> if used

# 2) Inspect what the snapshot contains
proxmox-backup-client snapshot files vm/<vmid>/<timestamp>

# 3) Restore a disk image to a SCRATCH path (not onto live storage)
proxmox-backup-client restore "vm/<vmid>/<timestamp>" drive-scsi0.img \
  "/srv/restore/<vmid>-disk.img"

# 4) Verify the restored image
qemu-img info "/srv/restore/<vmid>-disk.img"
ls -lh "/srv/restore/<vmid>-disk.img"

# 5) Optional: full VM restore from the PVE GUI or qmrestore, then boot the VM
#    on an isolated bridge to prove it actually works (see §07 drill d).
```

For a booted restore test, see [07-validation](../07-validation/README.md) §7.5(d).

## 6.8 — S3 backend option (PBS 4.2 GA)

PBS 4.2 supports S3-compatible object storage as a datastore backend (GA). If the
customer wants off-site/immutable copies instead of (or in addition to) the local
datastore, use a second datastore with the S3 backend — the local datastore path
then acts as cache:

```bash
proxmox-backup-manager datastore create s3-offsite /mnt/pbs-s3-cache \
  --backend "type=s3,client=<endpoint>,bucket=<bucket>" \
  --keep-weekly 4 --keep-monthly 12 \
  --gc-schedule weekly --prune-schedule weekly
```

Verify bucket credentials, region/endpoint, and multipart upload permissions
before pointing backup jobs at it; treat the first week as a pilot.

---

**Checkpoint before moving on:** datastore created with matching `--keep-*` retention,
user+token+ACL in place, PVE storage `pbs-cerberus` registered, nightly job created,
and **one manual backup + restore drill (§6.7) completed successfully**.
