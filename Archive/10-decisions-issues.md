# 10 — Decisions & Issues (deviation log)

> Append here whenever reality diverges from the plan. Each entry:
> date, what changed, why, and what to do differently next time.

## Known deviations (lab → client)

| Date | Deviation | Cause | Next time |
|---|---|---|---|
| 2026-09 | Service IPs moved `.33/.34/.35` → `.200/.201/.202` (Usernet) | Gateway/ingress needed routed user access, not provisioning net | Decide the service subnet in 01 and freeze it before generating certs |
| 2026-09 | k8s 1.35 (lab dialog) vs 1.34 (client baseline) | Version drift between runs | Pin `$K8S_VERSION` in `00-variables.sh` and treat any drift as a decision |
| 2026-09 | Client used segmented networks (`.15` prov / `.12` storage / `.13` user / `.16` OOB); lab ran flat on `.13` | Production hardening | Default new deployments to segmented (this template) |
| 2026-09 | Static IPs `.50–.55` overlapped the DHCP pool (`.50–.150`) | Plan error | Reserve statics outside the pool or exclude them explicitly |
| 2026-09 | EGL package conflict (`libnvidia-egl-gbm1` vs `-gl-580-server`) | Mixed package branches in image | 04.2 documents the repair; keep image packages on one branch |

## Lab runbook bugs fixed in this template

- `set softwareimage runai-dgxg200-image` → `runai-dgxh200-image` (typo)
- `runai-dgxh200-image2` referenced but never created — removed
- "Create Mgmt Network" configured `ipminet` instead of `mgmtnet` — fixed
- Inference TLS secret had `--cert`/`--key` swapped — fixed (06.3)
- BMC validation pinged `.80`; BMCs live on the IPMI network — use 01 IPs
- Control-plane hostname typo (`...-ctrN` vs `...-ctrlN`) — normalized to `k8s-ctrl-N`
