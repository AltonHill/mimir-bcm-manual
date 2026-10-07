# Cerberus — Official Reference Links

Curated official links only. One line per link: what it covers + which runbook section uses it. Verified 2026-10-07.

## Proxmox VE

- https://pve.proxmox.com/pve-docs/ — Proxmox VE Administration Guide (home; all install/cluster/storage sections).
- https://pve.proxmox.com/pve-docs/pveceph.1.html — pveceph(1) man page: install/mon/mgr/osd/pool commands, exact flags — used by § Ceph deployment.
- https://pve.proxmox.com/pve-docs/pvecm.1.html — pvecm(1) man page: create/add/link syntax, corosync requirements — used by § Cluster bring-up.
- https://pve.proxmox.com/pve-docs/chapter-pvecm.html — Cluster Manager chapter: corosync redundancy/second link, network requirements — used by § Cluster bring-up.
- https://pve.proxmox.com/pve-docs/ha-manager.1.html — ha-manager(1) man page: HA rules (node-affinity/resource-affinity), add/set, arm/disarm — used by § HA configuration (note: groupadd is deprecated here).
- https://pve.proxmox.com/pve-docs/chapter-ha-manager.html — High Availability chapter: fencing model, hardware watchdog configuration — used by § HA/fencing.
- https://pve.proxmox.com/pve-docs/chapter-vzdump.html — Backup chapter (vzdump): backup job options, --prune-backups retention — used by § Backup jobs.
- https://pve.proxmox.com/wiki/Roadmap — PVE roadmap/release notes — used to confirm current 9.x version at deploy time.

## Ceph

- https://docs.ceph.com/en/latest/releases/ — Ceph active-releases table (GA/EOL dates) — check at deploy time; Squid EOL vs Tentacle current.
- https://docs.ceph.com/en/tentacle/ — Ceph Tentacle (20.x) documentation home — used by § Ceph deployment.
- https://docs.ceph.com/en/tentacle/rados/operations/placement-groups/ — Placement groups & pg_autoscale_mode — used by § pool creation.

## Hardware (Lenovo)

- https://lenovopress.lenovo.com/lp2127.pdf — ThinkSystem SR650 V4 Product Guide — hardware baseline, slot/backplane/bay options for § physical bring-up.
- https://lenovopress.lenovo.com/datasheet/en-us/ds0194-lenovo-thinksystem-sr650-v4 — SR650 V4 datasheet (spec summary).
- https://lenovopress.lenovo.com/lp1991-thinksystem-v3-v4-server-firmware-and-drivers-best-practices-advanced-guide — V3/V4 firmware & driver update best practices — used by § firmware baseline.
- https://pubs.lenovo.com/lxce-onecli/onecli_r_flash_command — OneCLI `update flash` command reference — used by § firmware via CLI.
- https://pubs.lenovo.com/xcc2/updating_firmware_overview — XCC2 firmware update overview (XCC-first-then-UEFI ordering rule) — used by § firmware via XCC web.
- https://pubs.lenovo.com/xcc2/updating_firmware_procedure — XCC2 system/adapter/PSU firmware update steps — used by § firmware via XCC web.
- https://pubs.lenovo.com/xcc2/updating_firmware_repository — XCC2 Update from Repository (bundles; Platinum-license note) — used by § firmware via XCC web.
- StorCLI reference (MegaRAID 940-8i): no public official URL located (Broadcom docs behind support login) — use `storcli /c0 help` / on-box help; CLI property set (`set jbod=on`) matches the StorCLI codebase documented in Dell's PERC CLI reference. Marked unverified in research-findings.
- Samsung PM1743: no official enterprise.samsung.com datasheet URL obtainable via search — reference the vendor BOM/part data sheet shipped with the hardware instead.

## Network (NVIDIA)

- https://docs.nvidia.com/networking-ethernet-software/cumulus-linux-510/Layer-1-and-Switch-Ports/Interface-Configuration-and-Management/Switch-Port-Attributes/ — Switch port attributes: breakout (`nv set interface swpN link breakout 4x`), MTU (default 9216), speed — used by § fabric bring-up (SN5610 + SN2201).
- https://docs.nvidia.com/networking-ethernet-software/nvue-reference/Set-and-Unset-Commands/Interface/ — NVUE `nv set interface` reference (mtu/speed/state/breakout) — used by § fabric bring-up.
- https://docs.nvidia.com/networking-ethernet-software/cumulus-linux/System-Configuration/NVIDIA-User-Experience-NVUE/NVUE-CLI/ — NVUE CLI guide: `nv config apply`/`save`, auto-save, `?`/`-h` help — used by § fabric bring-up.
- https://networking-docs.nvidia.com/doca/archive/3-5-0/bluefield-modes-of-operation — BlueField modes of operation: NIC vs DPU mode, `mlxconfig` identification/switching commands — used by § BlueField-3 provisioning.

## Backup

- https://pbs.proxmox.com/docs/ — Proxmox Backup Server documentation home — used by § backup.
- https://pbs.proxmox.com/docs/proxmox-backup-manager/man1.html — proxmox-backup-manager command syntax: datastore create/update, users, tokens, ACLs — used by § PBS datastore setup.
- https://pbs.proxmox.com/docs/backup-client.html — Proxmox Backup Client guide: backup/restore command shapes — used by § restore procedures.
- https://pbs.proxmox.com/wiki/Roadmap — PBS roadmap/release notes — used to confirm current 4.x version at deploy time.
