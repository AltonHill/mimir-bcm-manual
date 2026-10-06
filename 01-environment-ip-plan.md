# 01 — Environment & IP Plan

> **Prerequisites:** `00-variables.sh` filled in and sourced.
> **Gate:** do not proceed until the values below are approved — they feed
> certificates, installer configs, and DNS.

## Networks

| BCM name | CIDR (variable) | Network domain | Gateway | Purpose |
|---|---|---|---|---|
| `internalnet` | `$NET_PROVISION` | `eth.cluster` | `$GW_PROVISION` | BCM provisioning, cluster mgmt |
| `storagenet` | `$NET_STORAGE` | `stor.cluster` | — | Pure NFS storage |
| `usernet` | `$NET_USER` | `user.cluster` | `$GW_USER` | User/service access (MetalLB, ingress) |
| `mgmtnet` | `$NET_OOB` | `oobnet.cluster` | `$GW_OOB` | Hardware/BMC management |

> **Field note [client]:** the client ran segmented as above. The Chaska lab
> ran flat — everything on `10.10.13.0/24` (`internalnet`), with mgmt on
> `.15` and IPMI on `.12`. Either works; segmented is the template default.
>
> **Automate it:** once the table above is approved,
> `scripts/runbook.py networks` creates/aligns the networks
> (`--dry-run` first, always). The pass is data-driven: copy
> `scripts/networks-template.csv` to `networks.csv` and add rows for
> extra fabrics (GPU east-west Ethernet/InfiniBand, IPMI, ...) — no code
> changes needed. Without `--networks`, the pass uses the stock
> 4-network plan from `00-variables.sh`.

```bash
cp scripts/networks-template.csv networks.csv
# edit networks.csv: uncomment/add rows per site
scripts/runbook.py networks --networks networks.csv --dry-run
```

## DNS

| Setting | Value |
|---|---|
| Domain | `$DOMAIN` |
| DNS 1 / DNS 2 | `$NET_DNS1` / `$NET_DNS2` |

Required forward + reverse records (generate from your plan):

```bash
# Example — adjust to the site's IP plan, then hand to DNS admin
# <fqdn>                    <ip>
# bcm-headnode.example.internal      10.10.15.10
# k8s-ctrl-1.example.internal        10.10.15.50
# ...
# kgateway.example.internal          10.10.13.200
# runai.example.internal             10.10.13.201
# *.runai.example.internal           10.10.13.201
# runai-inference.example.internal   10.10.13.202
# *.runai-inference.example.internal 10.10.13.202
```

## Node inventory (fill per site)

| Role (template name) | IP | MAC / BMC | Notes |
|---|---|---|---|
| `bcm-headnode` | `$BCM_HEADNODE_IP` | — | BCM 11 head node |
| `k8s-ctrl-1` | `10.10.15.50` | | Control plane |
| `k8s-ctrl-2` | `10.10.15.51` | | Control plane |
| `k8s-ctrl-3` | `10.10.15.52` | | Control plane |
| `gpu-worker-1..N` | `10.10.15.53+` | BMC on `$NET_OOB` | DGX nodes (B300) |

> **Field note [client]:** the client used 3× H200 workers
> (`10.10.15.53-55`). The lab used 4 VM workers +
> 1× DGX A100 + 1× DGX H200 (see `99-role-mapping.md` for the historical
> hostnames). Size `$GPU_WORKERS`/`$GPU_WORKER_IPS` to the
> site — for the B300 rollout this table grows to 74 nodes.

## Service IPs (Usernet)

| Service | FQDN | IP |
|---|---|---|
| Kubernetes gateway (Kgateway) | `$FQDN_KGATEWAY` | `$IP_KGATEWAY` |
| Run:ai ingress | `$FQDN_RUNAI` (+ wildcard) | `$IP_RUNAI` |
| Run:ai inference (Kourier) | `$FQDN_INFERENCE` (+ wildcard) | `$IP_INFERENCE` |

> **Field note [client]:** these moved during the client deployment from
> `.33`/`.34`/`.35` to `.200`/`.201`/`.202` ("moved to Usernet"). The
> template uses the working values. If you change them, regenerate
> certificates (06) — the SANs embed the IPs.

## DHCP

Reserve static addresses **outside** the DHCP pool, or explicitly exclude
them. The client plan had statics (`.50–.55`) overlapping the pool
(`.50–.150`) — don't repeat that.

## Preflight verification

```bash
for dns in $NET_DNS1 $NET_DNS2; do
  dig @$dns $BCM_HEADNODE.$DOMAIN
  dig @$dns $FQDN_KGATEWAY
  dig @$dns $FQDN_RUNAI
done
```

- [ ] Forward + reverse DNS resolves for every node and service FQDN
- [ ] DHCP scope excludes all static IPs
- [ ] Service subnet approved; MetalLB segment matches it
- [ ] Firewall allows the required paths (BCM, k8s API, ingress)
