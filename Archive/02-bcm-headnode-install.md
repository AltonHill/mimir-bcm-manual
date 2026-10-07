# 02 — BCM Head Node Installation

> **Prerequisites:** 01 complete (IP plan approved). Physical/VM head node
> with the BCM 11 ISO attached.

## 2.1 — Install from ISO

1. Get entitlements: `https://ui.licensing.nvidia.com/`
   → Entitlements → Base Command Manager → Actions → View Key.
2. Download the ISO: `https://customer.brightcomputing.com/download-iso`
   - Product key: `$BCM_PRODUCT_KEY`
   - Version: BCM `$BCM_VERSION`, Arch x86_64/amd64, Linux Ubuntu 24.04,
     Hardware NVIDIA DGX.
3. Boot the head node from the ISO and complete the installer with the
   IP plan from 01 (provisioning interface on `$NET_PROVISION`).

## 2.2 — License the head node

```bash
request-license
```

Provide when prompted:

```
Product Key     $BCM_PRODUCT_KEY
Country         <COUNTRY>
State           <STATE>
Locality        <LOCALITY>
Organization    $CLIENT_ORG
Org Unit        <ORG-UNIT>
Cluster Name    $CLUSTER_NAME
```

Answer yes to the remaining prompts to generate and install the license.

## 2.3 — OS upgrades

```bash
# Run update twice to consolidate repos, then upgrade
apt update && apt update && apt upgrade -y
reboot
```

```bash
# Validate the new kernel (record it — images pin to it in 03)
uname -r
```

## 2.4 — Base configuration

Convenience aliases (append to `~/.bashrc`):

```bash
cat >> ~/.bashrc <<'EOF'
# BCM aliases
alias catlist='cmsh -c "category list"'
alias devlist='cmsh -c "device list"'
alias imglist='cmsh -c "softwareimage list"'
alias netlist='cmsh -c "network list"'
alias userlist='cmsh -c "user list"'
alias reboot-watch='while true; do devlist; sleep 5; clear; done'
# Kubernetes aliases
alias k='kubectl'
alias taintlist='kubectl get nodes -o jsonpath={range\ .items[*]}{.metadata.name}{"\t"}{.spec.taints}{"\n"}{end}'
# Run:ai aliases
alias validate-runai='kubectl get pods -n runai-backend && kubectl get pods -n runai && kubectl get pods -n gpu-operator'
alias get-clusterlogs='curl -s https://raw.githubusercontent.com/runai-professional-services/utilities/refs/heads/main/runai_log_collector/start.sh | bash'
alias get-gpulogs='curl -s https://raw.githubusercontent.com/runai-professional-services/utilities/refs/heads/main/gpu_operator_log_dump/start.sh | bash'
EOF
source ~/.bashrc
```

> **Field note:** the lab's alias set also included per-category reboot
> aliases (`reboot-cp`, `reboot-dgx`, `reboot-all`) and NIM helpers —
> add them if you want; they aren't required.

Allow MAC-based device resolution, then restart the daemon:

```bash
# In /cm/local/apps/cmd/etc/cmd.conf, after the advanced-config comment:
#   AdvancedConfig = { "DeviceResolveAnyMAC=1" }
grep AdvancedConfig /cm/local/apps/cmd/etc/cmd.conf
systemctl restart cmd
```

## Verification

- [ ] `cmsh -c "device list"` shows the head node healthy
- [ ] `uname -r` matches `$KERNEL_VER` (or record the actual version and
      update `00-variables.sh` — 03 pins images to it)
