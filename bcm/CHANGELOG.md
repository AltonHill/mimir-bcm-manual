# Changelog

All notable changes to the template. Dates in America/Chicago.

## Unreleased

## 0.9.0 — 2026-10-06

- New `render` pass: builds the site-specific MD guide — copies every
  doc to `--out` (default `site-docs/`) with variables substituted
  (nested refs expanded, `99-role-mapping.md` skipped, unfilled
  placeholders warned). Serves all three workflows: client
  copy/paste walkthrough, team review-then-automate, and run-then-
  document. The template docs are never modified.

## 0.8.0 — 2026-10-06

- `networks` pass is now data-driven: `--networks networks.csv`
  (copy `scripts/networks-template.csv`); extra fabrics (GPU east-west
  Ethernet/IB, IPMI) are new CSV rows, no code changes. Falls back to
  the stock 4-network plan from `00-variables.sh` without `--networks`.
- New section 16: InfiniBand / GPU fabric at host level (OFED, subnet
  manager, IPoIB, `ib_write_bw` check). Not in the source guides —
  standard DGX/BCM practice, marked as such.
- New 8.5: GPU burn-in — PyTorch matmul Job (fleet-wide via
  parallelism), watch commands, plus Run:ai GUI and CLI paths.

## 0.7.0 — 2026-10-06

- Pass framework grows to 7: new `networks` (01), `storage` (07,
  `--plan 7a|7b`), and `disklayouts` (12) passes. The disklayouts pass
  is honest about its gap: without `disk-layouts/<type>-by-path.xml`
  (built from live hardware) it stops and prints the collection
  procedure.
- README rewritten: quickstart, ASCII pass-pipeline diagram, full pass
  table, "writing a new pass" guide, anonymizer pack section.
- Fixed the 01/03 `oobnet` vs `mgmtnet` naming inconsistency (docs now
  match the executable commands); added `GW_*` vars to the `vars`
  pass requirements.

## 0.6.0 — 2026-10-06

- Added `scripts/check.sh`: one-command validation (bash -n, YAML
  parse, py_compile, template-variable sanity, identifier leak scan,
  pass smoke tests). It caught 10 undefined variables (added `DNS_IP`;
  the rest were local assignments) and an argparse flag-ordering bug.
- Added `.gitignore` (site CSVs, generated scripts, logs stay
  uncommitted) and `CHANGELOG.md`.
- Fixed 00-overview inconsistencies (section order, disk-layout row,
  scripts paragraph); runbook.py now accepts `--dry-run`/`--exec`
  before or after the pass name.

## 0.5.0 — 2026-10-05

- Rewrote section 15 around the minimal `cmsh` user form
  (`user; add <name>; set password <TEMP>; commit`); extra switches
  cause OpenLDAP weirdness. `generate-users.py` simplified to
  `username,sudo` CSV + `--sudoers` mode; added
  `scripts/accounts-template.csv`.

## 0.4.0 — 2026-10-05

- Added `README.md` and `scripts/runbook.py` pass framework
  (`vars`, `images`, `nodes`, `users` passes; `--dry-run` default).
- Python 3.12 stdlib-only note (stock on Ubuntu 24.04 / DGX OS).

## 0.3.0 — 2026-10-05

- Merged the second source bundle: gateway listener fixes (websocket +
  `https-workloads` for `*.runai.<domain>`; Kourier inference path),
  NATS/backend placement, by-path disk layouts (rewrote 12), anonymized
  user/sudoers guide, kgateway v2.5 `ListenerPolicy` migration note.

## 0.2.0 — 2026-10-05

- First official-document validation sweep; restored the 7 Chaska-only
  gaps; 14-operator Kubernetes baseline; 7A/7B storage plans;
  `generate-nodes.py` inventory tooling.

## 0.1.0 — 2026-10-04

- Initial merge of the Chaska lab runbook with client field corrections.
