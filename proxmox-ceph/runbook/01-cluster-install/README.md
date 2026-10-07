# 01 — Proxmox VE cluster install

**Goal:** Proxmox VE 9.2.x installed identically on all three nodes, formed into a
quorate 3-node cluster named `cerberus`.

**Prerequisite:** 00a acceptance checklist fully signed off.

```bash
set -u
source ../00-overview/variables.sh   # adjust path to your copy
```

Reference: [docs/references.md](../../docs/references.md) — Proxmox VE Admin Guide,
`pvecm(1)` man page, Cluster Manager chapter.

---

## 1. Pre-flight — finalize names and IPs

**Hostname and IP changes are not supported after cluster creation.** Before
touching the installer, lock these in `variables.sh` and get sign-off:

- `NODE*_HOSTNAME` = `node-1`, `node-2`, `node-3` (final — no renames later)
- `NODE*_MGMT_IP` on `MGMT_NET` with `MGMT_GW`, `DNS_SERVERS`
- `DOMAIN` for FQDNs

Verify no placeholders remain for what this section consumes:

```bash
cerberus_require_vars CLUSTER_NAME \
  NODE1_HOSTNAME NODE2_HOSTNAME NODE3_HOSTNAME \
  NODE1_MGMT_IP NODE2_MGMT_IP NODE3_MGMT_IP \
  MGMT_GW DOMAIN DNS_SERVERS
```

---

## 2. PVE 9.2 ISO install — MANUAL-ONLY (per node)

Boot the Proxmox VE 9.2 ISO on each node (XCC virtual media / USB — MANUAL-ONLY).

1. **Install target:** the volume presented by the B550i-2i (the 2x 960GB M.2 in
   HW RAID1). It appears as a single disk. Do **not** select either PM1743 —
   those are Ceph OSD drives (§03) and must remain untouched.
2. **Filesystem: ext4. NOT ZFS.** Why: ZFS on top of a hardware RAID1 gains
   nothing — the controller hides the individual disks, so ZFS checksums cannot
   self-heal (there is no redundancy ZFS can see), while ZFS still costs ARC RAM
   on these 1TB hosts and complicates booting. The OS volume holds no VM data
   (that lives on Ceph); `/etc/pve` is replicated cluster-wide by pmxcfs anyway.
   ext4 on HW RAID1 is the simple, supported, boringly reliable choice.
3. Set hostname (`node-1` …), management IP / netmask / gateway / DNS from
   `variables.sh` at the installer network screen.
4. Set the root password (MANUAL-ONLY — record in the site's password manager),
   and an admin email.
5. Complete the install and reboot. Repeat on node-2 and node-3 with their
   respective hostnames/IPs.

After first boot on each node, confirm you can reach it: `ping` the mgmt IP and
open `https://<mgmt-ip>:8006` (certificate warning is expected).

---

## 3. Post-install per node (before clustering)

Run on **each** node, in this order:

```bash
# 3a. /etc/hosts — all nodes resolvable by name (installer writes the local
#     entry; add the peers).
cat >> /etc/hosts <<EOF
${NODE1_MGMT_IP} ${NODE1_HOSTNAME}.${DOMAIN} ${NODE1_HOSTNAME}
${NODE2_MGMT_IP} ${NODE2_HOSTNAME}.${DOMAIN} ${NODE2_HOSTNAME}
${NODE3_MGMT_IP} ${NODE3_HOSTNAME}.${DOMAIN} ${NODE3_HOSTNAME}
EOF

# 3b. Package repositories: disable enterprise, enable no-subscription.
#     (PVE 9 / Debian 13 "trixie" uses deb822 .sources files.)
ls /etc/apt/sources.list.d/
mv /etc/apt/sources.list.d/pve-enterprise.sources \
   /etc/apt/sources.list.d/pve-enterprise.sources.disabled 2>/dev/null || true
cat > /etc/apt/sources.list.d/pve-no-subscription.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

# 3c. Full upgrade and reboot. Service-affecting for the node (nothing runs on
#     it yet — just slow). MANUAL-ONLY in the sense that you watch it finish.
apt update && apt full-upgrade -y
reboot
```

After the reboot, on each node:

```bash
# 3d. Version sanity: expect PVE 9.2.x.
pveversion

# 3e. Time sync — corosync and Ceph both punish clock skew.
timedatectl
chronyc tracking 2>/dev/null || systemctl status systemd-timesyncd --no-pager
# If NTP_SERVERS differs from the default, point chrony at it and restart.

# 3f. DNS resolution works.
getent hosts "${NODE1_HOSTNAME}.${DOMAIN}"
```

Do not proceed until all three nodes are on the same `pveversion` output and
clocks agree (offset < 1s).

---

## 4. Create the cluster on node-1

On **node-1 only**:

```bash
# link0 = corosync on the management network (physically separate 1GbE NIC).
pvecm create "${CLUSTER_NAME}" --link0 "address=${NODE1_MGMT_IP}"
```

Expected: cluster created, node-1 is the single quorate member. Verify:

```bash
pvecm status
# look for: Quorate: Yes, Total votes: 1, node-1 with 1 vote
```

Capture node-1's join fingerprint **now** (needed to verify node-2/3 joins):

```bash
openssl x509 -in /etc/pve/local/pve-ssl.pem -noout -fingerprint -sha256
# record the SHA256 fingerprint — you will compare it during each join
```

---

## 5. Join node-2 and node-3 — fingerprint-verified

On **node-2**:

```bash
pvecm add "${NODE1_MGMT_IP}" \
  --fingerprint '<paste node-1 SHA256 fingerprint here>' \
  --link0 "address=${NODE2_MGMT_IP}"
```

- You will be prompted for `root@pam`'s password on node-1 — MANUAL-ONLY (type it;
  it is never stored).
- The `--fingerprint` must match the value captured in §4. **If the join prompt
  shows a different fingerprint, abort** — you may be joining the wrong cluster
  (or a MITM). This is the whole point of the flag.
- `--link0 address=...` pins corosync link0 to this node's mgmt IP.

Repeat on **node-3** with `--link0 "address=${NODE3_MGMT_IP}"`.

---

## 6. Quorum verification

On any node:

```bash
pvecm status
# PASS: Cluster information
#         Name:             cerberus
#         Quorate:          Yes
#         Total votes:      3
#       Membership — all three nodes listed, each 1 vote:
#         0x... 1  <node-1-ip> node-1 (local or peer, depending on node)
#         0x... 1  <node-2-ip> node-2
#         0x... 1  <node-3-ip> node-3

pvecm nodes
corosync-cfgtool -s     # rings: expect "RING ID 0 ... id=<mgmt-ip> status=ring 0 active with no faults"
```

Also confirm pmxcfs is replicating: create a scratch file on node-1 under
`/etc/pve/` (e.g. `/etc/pve/.cluster-join-test`) and read it back on node-2/3,
then delete it. If it appears everywhere, the cluster filesystem is healthy.

---

## Node-4 callout

Joining a 4th node later uses the identical §5 procedure
(`pvecm add <node-1-ip> --fingerprint ... --link0 address=${NODE4_MGMT_IP}`).
Quorum notes for 4 nodes:

- 4 votes: the cluster still tolerates **one** node down (quorum needs 3 of 4).
  A 4th node adds capacity, not resilience.
- **Keep Ceph MONs at 3** (§03) — an even MON count gains nothing and complicates
  elections. MGRs may run on all nodes (active/standby is automatic).

## 01 acceptance checklist

- [ ] Hostnames/IPs final and recorded in `variables.sh` (§1)
- [ ] PVE 9.2.x installed on the M.2 RAID1 volume, **ext4**, on all 3 nodes (§2)
- [ ] Enterprise repo disabled; no-subscription enabled; `full-upgrade` done; same `pveversion` everywhere (§3)
- [ ] NTP in sync, DNS resolving on all nodes (§3)
- [ ] `pvecm create cerberus` on node-1 with link0 = mgmt IP (§4)
- [ ] node-2 and node-3 joined with **verified** fingerprints (§5)
- [ ] `pvecm status`: 3 votes, quorate; `corosync-cfgtool -s` shows no ring faults (§6)
