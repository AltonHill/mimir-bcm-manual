# 05 — HA and fencing

Proxmox HA on the three nodes: hardware watchdog fencing FIRST, then HA rules (node-affinity — the 9.x replacement for deprecated groups), protected resources, maintenance procedures, and expected behavior on node loss.

> **READ THIS FIRST — the fencing model.** Proxmox HA has **no external fence agents**. There is no IPMI/STONITH/ipmilan integration in Proxmox, and there never has been (the old "Fencing" menu in the GUI is a display-only remnant). Fencing is **watchdog self-fencing**: if a node stops behaving, its own watchdog timer expires and the node power-cycles itself. Anyone expecting traditional external fencing must understand this up front — it changes what "fenced" means and how fast it happens. On Lenovo hardware the correct path is the **IPMI hardware watchdog**, configured below. The Lenovo XCC **cannot** be used as an external fence agent — no such configuration exists in Proxmox; the IPMI watchdog is the supported equivalent.

**Variables** — defined in [00-overview/variables.sh](../00-overview/variables.sh); **do not redefine them here**, source the file first:

```bash
source ../00-overview/variables.sh
# Expected names: HA_RULE_NAME (e.g. "production"),
#                 HA_PROTECTED_VMS (e.g. "vm:100,vm:101")
# Placeholders if variables.sh is not yet populated:
#   HA_RULE_NAME="production"
#   HA_PROTECTED_VMS="vm:100,vm:101"
```

Run all steps as `root`, on each node where noted.

---

## Prerequisites

- §01 cluster healthy, §04 pools in place (HA-protected VM disks should live on `vm-storage` — HA restarts a VM on another node; the disk must be reachable there, which means shared Ceph storage, not local-lvm).
- Every node can reach the XCC/BMC of its siblings (IPMI network up — §00a/§02).

---

## Step 1 — Hardware watchdog on Lenovo (do this FIRST, on each node)

By default Proxmox uses the Linux `softdog` software watchdog. On real server hardware, switch to the IPMI hardware watchdog **before** enabling HA — software watchdogs can't fence a truly hung kernel.

### 1a. Configure the watchdog module

On **each node**, in `/etc/default/pve-ha-manager`:

```ini
WATCHDOG_MODULE=ipmi_watchdog
```

and create `/etc/modprobe.d/ipmi_watchdog.conf`:

```ini
options ipmi_watchdog action=power_cycle
```

- `action=power_cycle` is the correct policy: when the watchdog fires, the BMC power-cycles the node (not a soft reboot, which a hung kernel may ignore).
- Regenerate the initramfs and reboot so the module loads early:

```bash
update-initramfs -u -k all
reboot
```

### 1b. Disable competing watchdogs

More than one watchdog fighting over the same timer is a classic source of phantom fences. On **each node**, disable:

- **NMI watchdog:** add `nmi_watchdog=0` to the kernel command line (`/etc/default/grub`, then `update-grub` + reboot), or `echo 0 > /proc/sys/kernel/nmi_watchdog` (runtime only, does not survive reboot).
- **Lenovo XCC auto-recovery / automatic server restart policies:** check XCC → Server Management / Recovery and turn off any OS-watchdog-equivalent auto-restart that would race the IPMI watchdog.
- Confirm no other watchdog module is loaded: `lsmod | grep -iE 'watchdog|softdog|iTCO|mei_wdt'` — expect only `ipmi_watchdog`.

### 1c. Verify the watchdog

On **each node**, after reboot:

```bash
ipmitool mc watchdog get
```

Proxmox expects to see a watchdog with a **~10 s countdown**. If the countdown reads something wildly different (or the watchdog is stopped), do not proceed — HA fencing timing depends on this. Then confirm the HA manager picked it up:

```bash
systemctl status pve-ha-lrm pve-ha-crm
journalctl -u pve-ha-lrm -u pve-ha-crm --since "10 min ago" | grep -i watchdog
```

---

## Step 2 — HA node-affinity rule

> **Do NOT use `ha-manager groupadd`.** Groups are deprecated in PVE 9.x in favor of HA rules. Old guides and forum posts still teach `groupadd` — this runbook does not. The replacement is `node-affinity`.

Create one rule covering the three nodes (run on **any one** node; HA config is cluster-wide):

```bash
ha-manager rules add node-affinity "${HA_RULE_NAME:-production}" \
  --nodes node-1,node-2,node-3 \
  --resources "${HA_PROTECTED_VMS:-vm:100,vm:101}"
```

- `--nodes node-1,node-2,node-3` — the VMs prefer these nodes in listed order; on failure they restart on the next available node in the list.
- `--resources vm:100,vm:101` — the protected VMIDs (comma-separated; containers are `ct:<id>`).
- Useful variants: add `--affinity negative` to *keep resources off* the listed nodes; add a `resource-affinity` rule with `--affinity negative` to keep two VMs on different nodes (e.g. a VM and its replica). List and remove with `ha-manager rules list` / `ha-manager rules remove <name>`.

> **node-4 callout:** adding the 4th node does not change MONs (they stay at 3, §03) but you **do** update HA rules: append `,node-4` to `--nodes` in each rule if the new node should host protected VMs, or leave rules untouched to keep the 4th node as compute/rebalance capacity only.

## Step 3 — Add resources to HA

For each protected VM (run on any node):

```bash
ha-manager add 100 --state started
ha-manager add 101 --state started
```

- `--state started` means HA actively keeps the VM running: it starts it if stopped and restarts it on another node if its host fails. Other states: `enabled`, `disabled`, `ignored`, `stopped` (see `man ha-manager`). Change later with `ha-manager set <vmid> --state <state>`.
- Verify:

```bash
ha-manager status
```

Expect each resource listed with its current node and state `started`. `--verbose` adds rule evaluation detail when something looks wrong.

---

## Step 4 — Maintenance procedures (PVE 9.2)

Planned maintenance must not look like a failure to the HA manager, or your rolling reboot will migrate half the cluster.

### Cluster-wide HA disarm (firmware days, whole-cluster work)

New in PVE 9.2 — disarm the entire cluster before disruptive maintenance, re-arm after:

```bash
ha-manager crm-command disarm-ha      # releases all watchdogs; resources keep running
# ... do the maintenance ...
ha-manager crm-command arm-ha         # re-arm afterwards
```

While disarmed, the HA manager stops reacting: VMs stay where they are, nobody gets restarted, no fences fire. **Forgetting to re-arm is the failure mode** — add "arm-ha" to the maintenance checklist as its own line item.

### Single-node maintenance

```bash
ha-manager crm-command node-maintenance enable node-2
# ... patch / reboot node-2 ...
ha-manager crm-command node-maintenance disable node-2
```

Enabling maintenance on a node gracefully migrates its HA resources to the other nodes first (new in 9.2). Do the work, disable maintenance, resources can be moved back.

---

## Step 5 — Expected behavior on node loss

What actually happens when node-2 dies uncleanly (power loss, kernel hang), with the config above:

1. **Detection:** the surviving nodes' corosync/CRM notices node-2 is gone (membership change, typically within tens of seconds).
2. **Fencing:** the dead node's **own watchdog** expires (~10 s countdown) and the BMC power-cycles it. This is the fence — it guarantees node-2 can't write to Ceph while its VMs are being restarted elsewhere. (If the node is truly dead — PSU failure — there's nothing to fence; the CRM proceeds on quorum.)
3. **Recovery:** the CRM restarts node-2's HA resources on node-1/node-3 per the node-affinity rule.

**Realistic timing expectations** (ballpark — §07 failure testing measures the real numbers on this hardware):

- Watchdog fence + BMC power cycle: ~2–4 minutes before the node is booting again.
- VM restart on a survivor: begins once the CRM confirms the node is gone and fenced, typically **~1–2 minutes** after failure detection; the VM then boots normally (add its own boot time).
- Total service interruption for a protected VM: roughly **2–5 minutes** end to end. Ceph I/O continues throughout on the surviving replicas (§04 size=3/min_size=2) — storage does not stall, only the VM's compute restarts.

What HA does **not** do: it does not live-migrate a dead node (that's impossible — the source is gone); it restarts. It does not protect VMs on local storage; it does not replace backups (§06).

---

## Verification checklist

- [ ] `/etc/default/pve-ha-manager` + `/etc/modprobe.d/ipmi_watchdog.conf` in place on all 3 nodes, `ipmi_watchdog` loaded, no competing watchdog modules
- [ ] `ipmitool mc watchdog get` shows ~10 s countdown on all 3 nodes
- [ ] `ha-manager rules list` shows the node-affinity rule with all 3 nodes
- [ ] `ha-manager status` shows each protected VM `started` on its node
- [ ] `disarm-ha` → `arm-ha` cycle tested once (confirm arm-ha re-arms; watch `ha-manager status` resume)

## References

Full link list lives in [docs/references.md](../../docs/references.md); the ones this section leans on:

- https://pve.proxmox.com/pve-docs/ha-manager.1.html — ha-manager(1): rules (node-affinity/resource-affinity), add/set, crm-command arm/disarm (notes groupadd deprecation).
- https://pve.proxmox.com/pve-docs/chapter-ha-manager.html — High Availability chapter: fencing model, hardware watchdog configuration.
