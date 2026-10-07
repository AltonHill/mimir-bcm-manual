# 03 — Software Images, Categories, Nodes & IPMI

> **Prerequisites:** 02 complete (licensed, upgraded head node).
>
> **At scale (10+ nodes):** don't hand-write the commands below — use
> `scripts/generate-nodes.py` with a CSV inventory (see 3.0), or the
> `images` / `nodes` passes of `scripts/runbook.py` (see README). The
> manual commands in 3.1–3.4 remain the reference for what the tooling
> generates.

## 3.0 — Node provisioning from inventory (recommended at scale)

```bash
# 1. Emit a skeleton CSV (example: 3 ctrl + 4 workers + 74 GPUs):
scripts/generate-nodes.py --skeleton --ctrl 3 --workers 4 --gpus 74 > inventory.csv

# 2. Fill in real hostnames, IPs, MACs, BMC IPs in your spreadsheet,
#    export as CSV. Columns in order:
#    hostname,ip,mac,role,category,interface,bmc_ip
#    role is ctrl | worker | gpu ; bmc_ip empty for non-GPU nodes.

# 3. Validate (catches duplicate hostname/IP/MAC, bad fields):
scripts/generate-nodes.py --check inventory.csv

# 4. Generate the provisioning script, review, then run on the head node:
scripts/generate-nodes.py inventory.csv > provision-nodes.sh
bash -n provision-nodes.sh
less provision-nodes.sh   # review every command before running
```

## 3.1 — Create categories

One category per node type. DGX A/H/B families are interchangeable in
this pattern — one category covers all DGX nodes of the same image. Add
a category per HGX OEM type or UCS as needed.

```bash
cmsh -c "category; add $CAT_CP ; commit"    # Run:ai control plane
cmsh -c "category; add $CAT_WRK ; commit"   # workers (VM or CPU)
cmsh -c "category; add $CAT_GPU ; commit"   # GPU workers (e.g. runai-dgx-cat)
# Additional GPU types, same pattern:
# cmsh -c "category; add runai-hgx-dell-cat ; commit"
# cmsh -c "category; add runai-ucs-cat ; commit"
```

> **Field note:** the lab used four categories (`runai-cp-cat`,
> `runai-wrk-cat`, plus one per GPU type) — one per GPU type is the
> pattern to keep. The client ran its 2 GPU nodes on Cisco UCS hardware;
> DGX vs HGX-8GPU (Dell/HPE/Lenovo) vs UCS differ only in category, image,
> and interface names — the steps are identical.

## 3.2 — Clone software images

One image per GPU node type (DGX families share one; HGX/UCS get their own):

```bash
cmsh -c "softwareimage; clone default-image $IMG_CP ; commit"
cmsh -c "softwareimage; clone default-image $IMG_WRK ; commit"
cmsh -c "softwareimage; clone dgx-image $IMG_GPU ; commit"
# HGX/UCS types: clone from the matching base image instead of dgx-image
# cmsh -c "softwareimage; clone default-image runai-hgx-dell-image ; commit"
```

Wait for each clone's ramdisk to generate (watch in `cmsh` — look for
"Initial ramdisk ... was generated successfully") before continuing.

Assign images to categories:

```bash
cmsh -c "category; use $CAT_CP ; set softwareimage $IMG_CP ; commit"
cmsh -c "category; use $CAT_WRK ; set softwareimage $IMG_WRK ; commit"
cmsh -c "category; use $CAT_GPU ; set softwareimage $IMG_GPU ; commit"
```

## 3.3 — Update images

For each image, chroot in and update:

```bash
cm-chroot-sw-img /cm/images/$IMG_CP
apt update && apt update && apt upgrade -y
exit
# repeat for $IMG_WRK and $IMG_GPU
```

On GPU images only, enable the NVIDIA stack:

```bash
cm-chroot-sw-img /cm/images/$IMG_GPU
systemctl enable nvidia-fabricmanager nvidia-persistenced nvidia-dcgm
apt install -y nvidia-container-toolkit
nvidia-ctk runtime configure --runtime=containerd
exit
```

> **Field note:** the lab notes also list enabling the NVIDIA DGX apt
> repo (`repo.download.nvidia.com/.../dgx-repo-files.tgz`) — commented
> out in the lab run. Uncomment if the image needs DGX-specific packages.

## 3.4 — Provision nodes

Add each node — add, provisioning interface, and category in one shot
(repeat per node; interface name per hardware):

```bash
# Control plane (example)
cmsh -c "device ; add physicalnode k8s-ctrl-1 10.10.15.50 ens33 ; set provisioninginterface ens33 ; set category $CAT_CP ; commit"
# GPU worker (example — DGX interface names differ, e.g. enp225s0f0np0)
cmsh -c "device ; add physicalnode gpu-worker-1 10.10.15.53 enp225s0f0np0 ; set provisioninginterface enp225s0f0np0 ; set category $CAT_GPU ; commit"
```

Set interfaces to DHCP and record MACs:

```bash
cmsh -c "device ; use k8s-ctrl-1 ; interfaces ; use ens33 ; set dhcp yes ; commit"
cmsh -c "device ; use k8s-ctrl-1 ; set mac <MAC> ; commit"
```

DGX nodes with dual provisioning NICs — add the second interface and
drop the boot flag from the first:

```bash
cmsh -c "device ; use gpu-worker-1 ; interfaces ; add physical <IFACE2> ; commit"
cmsh -c "device ; use gpu-worker-1 ; interfaces ; use <IFACE2> ; set mac <MAC2> ; commit"
cmsh -c "device ; use gpu-worker-1 ; interfaces ; remove bootif ; commit"
```

Pin the kernel per image, add the Mellanox module on GPU images:

```bash
cmsh -c "softwareimage ; use $IMG_CP ; set kernelversion $KERNEL_VER ; commit"
cmsh -c "softwareimage ; use $IMG_GPU ; set kernelversion $KERNEL_VER ; commit"
cmsh -c "softwareimage; use $IMG_GPU; kernelmodules; add mlx5_core; commit"
```

Set the disk layout per category:

```bash
cmsh -c "category ; use $CAT_CP ; set disksetup x86_64-slave-one-big-partition-xfs.xml ; commit"
cmsh -c "category ; use $CAT_WRK ; set disksetup x86_64-slave-one-big-partition-xfs.xml ; commit"
cmsh -c "category ; use $CAT_GPU ; set disksetup x86_64-slave-raid0-8-cache-drives.xml ; commit"
```

## 3.5 — IPMI / BMC networking **[restored]**

> This section existed only in the lab runbook — the client docs dropped
> it. It is required for DGX power control via BCM.

```bash
# Management network for BMCs, on the OOB network from 01.
# (The lab split this into mgmtnet 10.10.15.0/24 + ipminet 10.10.12.0/24
# and its "Create Mgmt Network" section then configured the wrong object
# — ipminet instead of mgmtnet. The template consolidates BMCs onto the
# single OOB network from the 01 plan.)
cmsh -c "network; add mgmtnet $NET_OOB ; commit"
cmsh -c "network; use mgmtnet ; set network $NET_OOB ; commit"
cmsh -c "network; use mgmtnet ; set gateway $GW_OOB ; commit"
cmsh -c "network; use mgmtnet ; set managementallowed yes ; commit"

# BMC interfaces — repeat per GPU node, BMC IPs from the 01 inventory
BMC_IP="<bmc-ip-for-this-node>"
cmsh -c "device ; use gpu-worker-1 ; interfaces ; add bmc ipmi0 $BMC_IP mgmtnet ; commit"

# BMC credentials (values from 00-variables.sh — never commit real ones)
# NOTE: BCM 11 docs show `set password` prompting interactively
# (enter/retype). If the one-liner below prompts instead of accepting
# the value, run the bmcsettings block in an interactive cmsh session.
cmsh -c "partition ; use base ; bmcsettings ; set username $BMC_USER ; set password $BMC_PASSWORD ; commit"
# inspect effective settings without entering the submode:
# cmsh -c "partition ; use base ; bmcsettings --show"
```

> **B300 note:** `bmcsettings` supports `set firmwaremanagemode` with
> values including `b200`, `b300`, `gb200`, `h100` — use it for DGX B300
> firmware management via BCM.

Validate (BMC IPs from your 01 inventory):

```bash
cmsh -c "device ; use gpu-worker-1 ; power status"
ipmitool -I lanplus -H "$BMC_IP" -U $BMC_USER -P "$BMC_PASSWORD" chassis power status
```

> `power status` can report failure for the head node's *own* BMC (the
> head node can't always reach its own BMC over the network) — that does
> not mean power control is broken for the rest of the cluster.

## Verification

- [ ] `cmsh -c "softwareimage list"` shows all images on `$KERNEL_VER`
- [ ] `cmsh -c "device list"` shows every node with category, MAC, and IP
- [ ] `cmsh -c "device ; use <gpu-node> ; power status"` responds via BMC
