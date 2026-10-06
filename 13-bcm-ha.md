# 13 — BCM Head-Node High Availability (optional)

> **Prerequisites:** 02–03 complete (licensed head node, nodes provisioned).
> Run this **before** 05 (Kubernetes) — HA setup requires all cluster
> nodes powered off.
>
> The tool is `cmha-setup` (no dash). Reference:
> https://docs.nvidia.com/dgx-basepod/deployment-guide-dgx-basepod/latest/bcm-ha.html

## 13.1 — Prerequisites

- Second head-node hardware, cabled (dedicated failover interfaces, or
  reuse internalnet/managementnet — decide now).
- License covers both head nodes: `request-license` asks "Will this
  cluster use a high-availability setup with 2 head nodes?" — provide
  **both** head-node MACs. Use a LOM-port MAC on a non-removable NIC
  (BMC MACs do not work).
- External Virtual IP from the site survey — this VIP is how you reach
  the *active* head node after HA is up.
- `cmha-setup` can also place `/cm/shared` and `/home` on external
  shared storage (NAS/DAS/DRBD) — decide before starting.

## 13.2 — Procedure

```bash
# 1. Verify head-node power control over the cluster nodes:
cmsh -c "device ; power -c <gpu-category> status"

# 2. Power OFF all cluster nodes (required before HA config):
cmsh -c "device ; power -c <gpu-category> off"
# repeat for each node category

# 3. On the primary head node as root:
cmha-setup
# -> Setup -> Configure
# -> verify license info / MACs -> CONTINUE
# -> enter the external VIP -> NEXT
# -> enter the secondary head-node name -> NEXT
# -> failover network: configure dedicated interfaces,
#    or skip to reuse internalnet
# -> enter the secondary head node's IPs -> review summary -> Yes
# -> enter BCM root password
# Wizard clones the head node, updates shared internal/external
# interfaces, updates the failover object, restarts cmdaemon.
```

```bash
# 4. PXE-boot the secondary head node, select RESCUE in GRUB.
#    In the rescue environment on the secondary:
#    /cm/cm-clone-install --failover
#    -> YES -> specify the inband interface
#    -> press 'c' to save the disk layout -> 'y' to reboot
#    Then set the secondary to boot from hard drive
#    (disable PXE via BMC/BIOS).
```

```bash
# 5. Back on the primary — finalize:
cmha-setup
# -> Finalize -> NEXT -> CONTINUE -> root password
# Clones the MySQL/cmdaemon databases to the secondary.
# -> select REBOOT, wait for the secondary to return.
```

## 13.3 — Verify

```bash
cmsh -c "device list -f"
# both head nodes show [ UP ]
```

- [ ] VIP reaches the active head node
- [ ] Failover tested (planned failover, not just config)
