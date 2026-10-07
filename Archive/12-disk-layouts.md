# 12 — Disk Layouts

> **Prerequisites:** 03 (categories exist). Do this before first
> provisioning — changing disksetup on an already-provisioned node
> requires reprovisioning.
>
> **The headline rule:** never use kernel device paths (`/dev/nvme0n1`,
> `/dev/sda`) in a disklayout XML. They reorder across reboots — the
> field saw a 1-in-3 chance of a DGX coming up with the wrong mapping,
> and every mismatch makes BCM wipe and reprovision the node from
> scratch. During `cm-kubernetes-setup` (which reboots nodes), that
> timeout loop can cost days.
>
> **Automate it:** `scripts/runbook.py disklayouts` applies
> `disk-layouts/<GPU_NODE_TYPE>-by-path.xml` at category level. If the
> XML isn't there yet, the pass stops and prints the collection
> procedure below — the XML can only be built from live hardware.

## 12.1 — by-path, not by-id, not kernel names

| Scheme | Stable across reboots? | Survives drive replacement? |
|---|---|---|
| `/dev/nvme0n1`, `/dev/sda` (kernel) | **No** — enumeration order varies | N/A |
| `/dev/disk/by-id/nvme-SAMSUNG_...` | Yes | **No** — the ID names the drive, not the slot |
| `/dev/disk/by-path/pci-0000:23:00.0-nvme-1` | Yes | **Yes** — the path names the PCI slot |

Use **by-path**: it's tied to the slot, so a replacement drive in the
same slot keeps working with zero XML changes.

Collect the mapping per DGX model (do this once per hardware type):

```bash
# on one node of each DGX type:
ls -la /dev/disk/by-path/ | grep nvme
```

Record the by-path → slot → purpose map, e.g. DGX A100:

```text
# slot/purpose map (example — build from YOUR ls output)
/dev/disk/by-path/pci-0000:23:00.0-nvme-1  ->  2TB boot drive 1
/dev/disk/by-path/pci-0000:52:00.0-nvme-1  ->  2TB boot drive 2
/dev/disk/by-path/pci-0000:09:00.0-nvme-1  ->  4TB cache 1
/dev/disk/by-path/pci-0000:22:00.0-nvme-1  ->  4TB cache 2
/dev/disk/by-path/pci-0000:8a:00.0-nvme-1  ->  4TB cache 3
/dev/disk/by-path/pci-0000:ca:00.0-nvme-1  ->  4TB cache 4
```

## 12.2 — Build per-model XMLs

Copy BCM's default template, swap every kernel path for its by-path
equivalent. Naming: `<model>-raid0-<n>-cache-drives-by-path.xml`.

Structure (DGX A100 pattern — 2 boot + 4 cache):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<diskSetup>
  <device>
    <blockdev>/dev/disk/by-path/pci-0000:23:00.0-nvme-1</blockdev>
    <partition id="efi" partitiontype="esp">
      <size>100M</size><type>linux</type><filesystem>fat</filesystem>
      <mountPoint>/boot/efi</mountPoint>
    </partition>
    <partition id="boot1"><size>4G</size><type>linux raid</type></partition>
    <partition id="slash1"><size>max</size><type>linux raid</type></partition>
  </device>
  <!-- ... second boot drive, then one <device> per cache drive
       with a single max-size "linux raid" partition each ... -->
  <raid id="boot">
    <member>boot1</member><member>boot2</member>
    <level>1</level><filesystem>ext2</filesystem><mountPoint>/boot</mountPoint>
  </raid>
  <raid id="slash">
    <member>slash1</member><member>slash2</member>
    <level>1</level><filesystem>ext4</filesystem><mountPoint>/</mountPoint>
  </raid>
  <raid id="raid">
    <member>raid1</member><member>raid2</member>
    <member>raid3</member><member>raid4</member>
    <level>0</level><filesystem>ext4</filesystem><mountPoint>/raid</mountPoint>
  </raid>
</diskSetup>
```

Apply at the category:

```bash
cmsh -c "category ; use $CAT_GPU ; set disksetup /root/dgx-b300-raid0-8-cache-drives-by-path.xml ; commit"
```

> **Field note:** the stock BCM templates use kernel paths. The
> standing recommendation is to never use them: maintain your own
> by-path XML per DGX model in the runbook and set it on the category.

## 12.3 — Layout selection reference

| Node type | Pattern |
|---|---|
| Control plane / CPU workers | One big XFS partition |
| DGX (per model) | 2 boot drives RAID1 (`/boot`, `/`) + cache drives RAID0 (`/raid`) |

Disk layouts live in the **CMDaemon database**; the XML files under
`/cm/local/apps/cmd/etc/htdocs/disk-setup/` are default templates:

```bash
cmsh -c "disksetup list"
cmsh -c "disksetup ; use <layout>.xml ; show"
# per-node override / revert to category:
cmsh -c "device ; use <node> ; set disksetup <layout>.xml ; commit"
cmsh -c "device ; use <node> ; clear disksetup ; commit"
```

Changing `disksetup` flags the node restart-required.

- [ ] Every custom layout uses by-path; no kernel device names
- [ ] Layout validated on one node of each type before rolling to the fleet
