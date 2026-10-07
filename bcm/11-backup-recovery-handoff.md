# 11 — Backup, Recovery & Handoff

## 11.1 — What to back up (and when)

| Artifact | Command | When |
|---|---|---|
| Run:ai cluster config | `kubectl get runaiconfig runai -n runai -o jsonpath='{.spec}' > runai_config_backup.yaml` | Post-install, pre-change |
| Run:ai Helm values | `helm get values runai-backend -n runai-backend > runai_control_plane_values.yaml` | Post-install, pre-change |
| PostgreSQL dump | Safe pattern in 06.5 | Pre-upgrade, weekly |
| BCM config | `cmsh` → backup via BCM procedures | Pre-change |
| `00-variables.sh` + `/root/cm-*-setup.conf` | Copy off-host | After every section |

Store backups off the head node, mode `0600`. Never commit secrets.

## 11.2 — Rollback notes

- **Before 05:** BCM-level rollback — reinstall head node from ISO (02),
  re-run sections in order.
- **05–06:** `cm-kubernetes-setup` / `cm-runai-setup` are not cleanly
  reversible; snapshot/back up first (11.1). Documented client rollback
  detail lives in the client `11 - Backup Recovery Rollback and
  Operational Handoff.md`.
- **NIM / storage:** `kubectl delete` the created resources; StorageClasses
  are non-destructive to switch (07.3).

## 11.3 — Operational handoff checklist

- [ ] 01 IP plan signed off; DNS forward+reverse verified (08.2)
- [ ] All 02–09 verification boxes checked
- [ ] Backups in 11.1 exist and are restorable (test-restore the DB dump)
- [ ] Credentials in `00-variables.sh` rotated from install-time values;
      real values in the site's vault, not in docs
- [ ] Administration endpoints documented (below)
- [ ] 10 deviation log reviewed for open items

## 11.4 — Administration endpoints **[restored]**

| Service | URL |
|---|---|
| BCM head node | `https://$BCM_HEADNODE.$DOMAIN:8081/base-view/` |
| Run:ai | `https://$FQDN_RUNAI/` |
| Run:ai inference | `https://$FQDN_INFERENCE/` |
| DGX BMCs | `https://<bmc-ip>/` (per 01 inventory) |
| vCenter (if applicable) | `https://<vcenter>/` |
