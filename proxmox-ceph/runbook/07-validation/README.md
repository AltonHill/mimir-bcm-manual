# 07 — Validation, failure drills, and acceptance sign-off

Acceptance gate for the whole build. Run on the fully built 3-node cluster
(cluster + network + Ceph + pools + HA + PBS, all complete).

Conventions: variables-first (source `../00-overview/variables.sh`). Copy-pasteable
code blocks. **DESTRUCTIVE steps are marked ⚠️ DESTRUCTIVE — read the whole drill
before starting, and answer the confirmation prompts honestly.**

> Docs this section leans on: the PVE cluster, HA (watchdog/fencing), and vzdump
> backup chapters plus the PBS client guide — see
> [../../docs/references.md](../../docs/references.md).

---

## 7.1 — Re-run the pre-build checks (00a, post-build)

The cluster is built; re-verify the physical layer didn't shift under you:

```bash
source ../00-overview/variables.sh

# per node: link speed still 200G, MTU 9000 intact, OSD devices still raw
for n in "$NODE1_HOSTNAME" "$NODE2_HOSTNAME" "$NODE3_HOSTNAME"; do
  ssh "root@$n" 'for i in $(ip -o link show | awk -F": " "{print $2}" | grep -v lo); do
    echo -n "$HOSTNAME $i: "; ethtool $i 2>/dev/null | grep -E "Speed|Link detected" | tr "\n" " "; echo; done'
done
bash ../../scripts/net-verify.sh   # end-to-end MTU + corosync UDP reachability
```

## 7.2 — Ceph deep health

All of these must be clean before any failure drill:

```bash
source ../00-overview/variables.sh

ceph -s                       # HEALTH_OK, 3 mons quorum, 6 OSDs up+in, no misplaced/degraded
ceph health detail            # must be empty (only expected warnings tolerated, logged below)
ceph osd df                   # all 6 OSDs, weight sane, reweight 1.0, util balanced
ceph osd pool ls detail       # size=3, min_size=2, pg_autoscale_mode=on on RBD pools
ceph mon stat                 # 3 mons, quorum 0,1,2
ceph mgr stat                 # active + standby present
ceph status --format json | python3 -c "import json,sys; d=json.load(sys.stdin); print('pgmap:', d['pgmap'])"

# rebalance must be COMPLETE: zero active recovery and no degraded objects
ceph status | grep -E "degraded|misplaced|recovering" || echo "no recovery activity"

# Tentacle auth-status check (CephX aes256k migration item from research)
pveceph auth status
```

Record any `HEALTH_WARN` that is expected (e.g. autoscaler warm-up) in the sign-off
table; everything else must be `HEALTH_OK`.

---

## 7.3 — Drill (a): OSD failure ⚠️ DESTRUCTIVE (data-plane, self-healing)

Simulates one dead NVMe. Expected: cluster goes degraded, re-replicates, returns to
HEALTH_OK. **Rollback:** re-weight the OSD back in (or replace the drive) and let
recovery finish.

```bash
source ../00-overview/variables.sh

# 1) Baseline
ceph osd df && ceph -s

# 2) Confirm before touching anything
read -rp "Take OSD.0 OUT of the cluster? This starts recovery I/O. [yes/NO] " ans
[ "$ans" = "yes" ] || { echo "Aborted."; exit 1; }

# 3) Kill one OSD (down then out)
ceph osd down 0
ceph osd out 0

# 4) EXPECTED RESULT: 'ceph -s' shows HEALTH_WARN (1/6 OSDs down), degraded objects
#    climbing then falling as re-replication runs; min_size=2 keeps I/O flowing.
watch -n 5 'ceph -s'
```

**EXPECTED RESULT (pass criteria):**

- Within minutes: `ceph -s` shows `1/6 osds down`, objects degraded, then
  `N% degraded` *decreasing* — recovery is active on the surviving 5 OSDs.
- Client I/O (a test VM doing fio, or `rados bench`) continues throughout — brief
  latency spike is acceptable, errors are not.
- After re-replication: no stuck PGs, `ceph -s` returns toward HEALTH_OK with
  the OSD still marked down/out.

**ROLLBACK:**

```bash
# Rejoin the OSD (or swap in a replacement drive and ceph-volume it, same OSD id flow)
ceph osd in 0
watch -n 5 'ceph -s'      # EXPECTED: recovery traffic, then HEALTH_OK
ceph osd df               # OSD.0 back up+in, weights normal
```

If the OSD does not come back, follow §03 OSD replacement steps (ceph-volume
zap + `pveceph osd create`) — do not proceed to drill (b) until `ceph -s` is
HEALTH_OK.

---

## 7.4 — Drill (b): node power loss ⚠️ DESTRUCTIVE (cluster-level, watchdog fence)

Simulates a full node loss. This is the HA fencing drill. **Expected: watchdog
self-fence on the dead node, HA restarts its VMs on survivors.**

> Proxmox HA has **no external fence agents** (no ipmilan/STONITH). Fencing here =
> the node's own watchdog timer expiring. The XCC web session may be used to
> *observe* the node only — never as a fence device.

**Prerequisites:** hardware watchdog configured (`ipmi_watchdog`,
`ipmitool mc watchdog get` shows a ~10 s countdown on every node); at least one HA
VM running on node-2; `ha-manager status` shows HA manager active on all 3 nodes.

```bash
source ../00-overview/variables.sh

# 1) Baseline: which VMs on node-2, HA state
ha-manager status
qm list | head -20

read -rp "Power OFF node-2 via XCC (it will NOT respond until powered back). Proceed? [yes/NO] " ans
[ "$ans" = "yes" ] || { echo "Aborted."; exit 1; }

# 2) Power off node-2 through the XCC web console (Power Actions -> Power Off)
#    or: ipmitool -I lanplus -H <node-2-XCC-IP> -U <user> chassis power off
```

**EXPECTED RESULT (pass criteria, approximate timings — verify on site):**

| Milestone | How to observe | Approx timing |
|---|---|---|
| corosync marks node-2 lost | `pvecm status` on node-1 shows node-2 offline | ~30–60 s after power off |
| watchdog fence completes on node-2 | node-2 fans stop / XCC shows powered-off (fenced state) | within ~2–5 min of corosync loss |
| HA manager decides failover | `journalctl -u pve-ha-crm -f` on a survivor | shortly after fence |
| node-2's VMs restart on node-1/node-3 | `ha-manager status`, `qm status <vmid>` | total from power-off: ~5–10 min typical |

- VMs come up on survivors per HA rules (`ha-manager rules` — node-affinity, not
  the deprecated `groupadd`).
- Ceph: 3 OSDs (node-2's pair) go down → HEALTH_WARN with degraded PGs;
  `min_size=2` keeps pools I/O-serving. Re-replication to survivors runs in the
  background.
- **No split-brain**: corosync quorum is 2 of 3; node-1 + node-3 hold quorum. If
  the dead node had been a quorum member loss *plus* another failure, quorum
  would be lost — that's why this drill is run with exactly one node down.

**ROLLBACK (rejoin node-2):**

```bash
# 1) Power node-2 back on via XCC (Power Actions -> Power On)
# 2) Watch it boot and rejoin corosync
watch -n 5 'pvecm status'      # node-2 returns to quorum: 3 votes online

# 3) HA: VMs that failed over STAY on survivors (HA does not migrate back
#    automatically unless rules say so). Migrate manually if the site policy
#    wants node-2 repopulated:
qm migrate <vmid> "$NODE2_HOSTNAME" --online

# 4) Ceph OSDs on node-2 come back automatically; watch rebalance finish
watch -n 10 'ceph -s'          # EXPECTED: recovery traffic, then HEALTH_OK
ceph osd df                    # all 6 OSDs up+in
```

Do not start drill (c) until corosync shows 3/3 and Ceph is HEALTH_OK.

---

## 7.5 — Drill (c): network partition — drop one fabric leg ⚠️ DESTRUCTIVE (network)

Simulates losing one SN5610 fabric path (or one 200G leg per node). **Expected:
I/O continues on the surviving path** — Ceph and corosync are dual-linked, no
failover storm.

**Prerequisites:** dual 200G links per node landed on *different* SN5610s (§02);
corosync link0 on 1GbE mgmt, link1 on the 200G fabric; a test VM doing steady
write I/O (e.g. `fio` sequential write) with visible throughput.

```bash
source ../00-overview/variables.sh

# 1) Baseline: which fabric link carries what (from §02 interface inventory)
#    Note which switch port = node-2's FIRST 200G leg.

read -rp "Administratively DOWN one fabric leg (node-2 leg A). I/O must continue. [yes/NO] " ans
[ "$ans" = "yes" ] || { echo "Aborted."; exit 1; }

# 2) Down the leg — pick ONE of:
#    a) on the switch: nv set interface <swpXsY> link state down && nv config apply
#    b) on the node:   ip link set <iface> down
#    c) physically:    pull the DAC (counts as the real-world case)
```

**EXPECTED RESULT (pass criteria):**

- Test-VM I/O **continues uninterrupted** — throughput may dip (half the fabric
  bandwidth) but no I/O errors, no VM stalls.
- `ceph -s` stays HEALTH_OK (or at most a brief WARN if a monitor flap occurs).
- corosync: `corosync-cfgtool -s` shows link1 down on node-2, link0 still up —
  **no quorum loss, no fencing**.
- `ip -s link show <surviving-iface>` shows traffic shifted to the survivor.

**ROLLBACK:**

```bash
# Bring the leg back up (reverse of step 2)
# EXPECTED: interface comes up, 200G renegotiates, traffic rebalances
sleep 30
corosync-cfgtool -s    # both links up on all nodes
ceph -s                # HEALTH_OK
```

If I/O *stopped*, the dual-link design is broken (both links share one switch or
bond config is wrong) — fix §02 before signing off.

---

## 7.6 — Drill (d): backup restore drill

Non-destructive to production **if** done on a scratch VM — treat it as
destructive to the *test* VM only. Restores a real backup from PBS and boots it.

```bash
source ../00-overview/variables.sh

# Guided path (confirmations at every step):
bash ../../scripts/backup-drill.sh

# Manual path (what the script does):
# 1) export PBS_REPOSITORY / PBS_FINGERPRINT / PBS_PASSWORD (§06.5)
# 2) proxmox-backup-client snapshot list vm/<test-vmid>
# 3) restore the disk image to a scratch path, qemu-img info to verify
# 4) qmrestore to a NEW vmid (never overwrite the source VM), attach to an
#    isolated bridge with no production VLAN, power on, log in via console
```

**EXPECTED RESULT (pass criteria):**

- Snapshot list returns the nightly backup(s) from the §06 job.
- Restored disk image verifies (`qemu-img info` sane, size matches).
- Restored VM boots to login prompt on the isolated bridge.
- **Timing recorded:** snapshot-list → booted-login. This is the site's RTO
  evidence — write it into the sign-off table.

---

## 7.7 — Acceptance sign-off checklist

Fill `Actual` during the run. Every row must be PASS before handover.

| # | Item | Expected | Actual | Pass |
|---|---|---|---|---|
| 1 | PVE cluster | 3/3 nodes, quorum, PVE 9.2.x | | |
| 2 | Pre/post-build physical checks | 200G links, MTU 9000 end-to-end, OSD drives raw | | |
| 3 | Ceph health | `HEALTH_OK`, 6 OSDs up+in, 3 mons quorum | | |
| 4 | Ceph pools | size=3/min_size=2, pg_autoscale=on | | |
| 5 | Corosync | dual links, quorum 3/3, UDP 5405–5412 open | | |
| 6 | HA rules | node-affinity rules active, watchdog ~10 s on all nodes | | |
| 7 | Drill (a) OSD failure | recovery completes, I/O uninterrupted, rollback to HEALTH_OK | | |
| 8 | Drill (b) node power loss | fence ≤ ~5 min, HA VM restart ≤ ~10 min total, rejoin clean | | |
| 9 | Drill (c) fabric leg loss | I/O continues on surviving leg, no quorum loss | | |
| 10 | Drill (d) restore | test VM restores from PBS and boots; RTO recorded: ____ | | |
| 11 | Backup job | nightly 02:00 job, prune `keep-daily=7,keep-weekly=4,keep-monthly=6` matching PBS `--keep-*` | | |
| 12 | Tentacle auth status | `pveceph auth status` reviewed, aes256k plan noted | | |
| 13 | Firmware baseline | XCC/UEFI/adapters at agreed baseline, 940-8i JBOD, no virtual drives | | |

**Signed off by:** ____________________ **Date:** ______________

Record the completed table (and any HEALTH_WARN exceptions from §7.2 with
justification) in the site handover pack.
