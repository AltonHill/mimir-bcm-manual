# 99 — Role Mapping & Companyify Guide

## Identifier unification

Three naming dialects went into this template. This table is the Rosetta
Stone — every role's template name, and what it was called in each source.

| Template role | Template FQDN | Lab (txt) | Client (md) | Notes |
|---|---|---|---|---|
| `bcm-headnode` | `bcm-headnode.$DOMAIN` | `node-001` / `acl-bcm-hn01` | `node-005` / `madaib001` | 10.10.15.10 |
| `k8s-ctrl-1` | `k8s-ctrl-1.$DOMAIN` | `node-006` / `acl-k8s-ctrl1` | `node-006` / `madaik001` | 10.10.15.50 |
| `k8s-ctrl-2` | `k8s-ctrl-2.$DOMAIN` | `node-007` / `acl-k8s-ctrl2` | `node-007` / `madaik002` | 10.10.15.51 |
| `k8s-ctrl-3` | `k8s-ctrl-3.$DOMAIN` | `node-008` / `acl-k8s-ctrl3` | `node-008` / `madaik003` | 10.10.15.52 |
| `gpu-worker-1` | `gpu-worker-1.$DOMAIN` | `node-009` / `acl-k8s-wrk1` | `node-001` / `dc1aiw001` | 10.10.15.53 |
| `gpu-worker-2` | `gpu-worker-2.$DOMAIN` | `node-010` / `acl-k8s-wrk2` | `node-002` / `dc1aiw002` | 10.10.15.54 |
| `gpu-worker-3` | `gpu-worker-3.$DOMAIN` | `node-011` / `acl-k8s-wrk3` | `node-003` / `dc1aiw003` | 10.10.15.55 |
| `gpu-worker-4` | `gpu-worker-4.$DOMAIN` | `node-012` / `acl-k8s-wrk4` | — (client had 3) | lab only |
| `dgx-a100-1` | `dgx-a100-1.$DOMAIN` | `node-003` / `acl-dgxa100-1` | — | lab only, 10.10.13.200 |
| `dgx-h200-1` | `dgx-h200-1.$DOMAIN` | `node-005` / `acl-dgxh200-1` | — | lab only, 10.10.13.201 |
| `kgateway` | `kgateway.$DOMAIN` | `node-015` / `kgateway` | `node-004` | svc IP `$IP_KGATEWAY` |
| `runai` | `runai.$DOMAIN` | `node-017` / `runai` | `node-010` | svc IP `$IP_RUNAI` |
| `runai-inference` | `runai-inference.$DOMAIN` | `node-016` / `runai-inference` | `node-009` | svc IP `$IP_INFERENCE` |

> The lab numbered `node-001`–`node-017`; the client numbered
> `node-001`–`node-010` differently. Neither numbering survives here —
> roles are the identifiers now.

## Companyify guide (pass 2)

To instantiate this template for a real site:

1. Copy the template directory.
2. Fill `00-variables.sh`: `DOMAIN`, all IPs, node names (keep the
   role-based scheme or substitute the site's real hostnames —
   either works since every command references the variables).
3. Replace `example.internal` everywhere if not using `$DOMAIN`
   (it only appears in `00-variables.sh` defaults and prose).
4. Regenerate certificates (06.1, 06.3) — SANs embed FQDNs and IPs.
5. Delete this file (`99-role-mapping.md`) from the instantiated copy —
   it exists to document the merge, not the deployment.

To reverse (template → real names for an existing site): the mapping is
mechanical — replace each `role.$DOMAIN` with the site's FQDN. No
anonymize-map needed; the template never contained real identifiers.
