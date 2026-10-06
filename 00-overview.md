# B300 Deployment Runbook — Template

> **What this is:** a merged, executable deployment recipe for a BCM 11 +
> Kubernetes + NVIDIA Run:ai stack on DGX GPU nodes. It combines the
> Chaska lab's canonical step-by-step procedure (the prescription) with the
> fixes and additions discovered during the client deployment (the
> description). Every step is copy-pasteable and ordered; every section
> ends with a verification.
>
> **Hardware scope:** written for air-cooled DGX (A, H, and B series
> treated as interchangeable) — the bulk of deployments through next
> year. The same pattern covers HGX 8-GPU OEM nodes (Dell, HPE, Lenovo)
> and Cisco UCS GPU nodes: one BCM category + image per node type.
> NVL72 rack-scale (Vera Rubin, shipping since Sept 2026) is future
> scope — same provisioning pattern, but rack fabric and liquid cooling
> are their own design track. The client ran 2× Cisco UCS GPU nodes;
> the lab ran DGX A100 + DGX H200.
>
> **What this is not:** a copy of either source. Lab and client used
> different networks, hostnames, and IPs — all unified here under
> role-based names. See `99-role-mapping.md` for the translation tables.

## How to use this template

1. Fill in `00-variables.sh` for the site (the "companyify" step — it's the
   only file that changes per deployment).
2. `source 00-variables.sh` on the machine you're working from.
3. Work sections **01 → 15 in order**. Each section lists its
   prerequisites at the top. (13 is optional HA and runs before 05;
   14 is greenfield infrastructure and runs before 01.)
4. Every command block is copy-pasteable as written (variables already
   exported). **Verify** each section's checks before moving on.

## Execution order

| # | Section | What happens |
|---|---------|--------------|
| 01 | Environment & IP plan | Networks, DNS, host inventory — fill the blanks, get sign-off |
| 02 | BCM head node install | ISO install, licensing, OS upgrades, base config |
| 03 | Images, categories, nodes | Software images, BCM categories, node provisioning, IPMI |
| 04 | NVIDIA drivers | Driver install/repair inside images, container toolkit |
| 05 | Kubernetes | `cm-kubernetes-setup`, cluster bring-up, operator install |
| 06 | Run:ai | Certs, `cm-runai-setup`, ingress/inference, validation, backups |
| 07 | Storage | Head-node NFS mount + NFS CSI driver + StorageClasses |
| 08 | Validation | GPU, platform, and workload smoke tests |
| 09 | NIM Operator | NGC secrets, NIMCache, model validation |
| 10 | Decisions & issues | Deviation log — what differed from plan and why |
| 11 | Backup, recovery, handoff | What to back up, how to roll back, handoff checklist |
| 12 | Disk layouts | disklayout.xml selection, editing, by-path guidance |
| 13 | BCM HA (optional) | `cmha-setup` — only if doing head-node HA; runs **before** 05 |
| 14 | Greenfield infra | Jumpbox, DNS (Technitium/site), Chrony — before 01 goes live |
| 15 | User management | BCM users from CSV, sudoers drop-in, image push |

`scripts/generate-nodes.py` turns a CSV inventory into the `cmsh`
provisioning script for 03 — required at fleet scale (74+ nodes).
`scripts/generate-users.py` does the same for BCM accounts in 15
(including the sudoers drop-in via `--sudoers`).

`scripts/runbook.py` is the pass runner: composable sub-passes, one per
runbook job (`vars`, `images`, `nodes`, `users`). `--dry-run` is the
default — it prints exactly what would run; `--exec` asks for
confirmation first. New passes get added as the data supports them.
See `README.md` for the full usage picture.

`99-role-mapping.md` holds the lab→template and client→template identifier
translations, plus the companyify guide.

## Conventions

- `bash` blocks are run on the **BCM head node** unless labeled otherwise.
- `<PLACEHOLDER>` values must be replaced; UPPER_CASE names in code
  blocks are variables from `00-variables.sh`.
- **Field notes** (blockquote callouts) mark where the client deployment
  diverged from the lab procedure — read them, don't skip them.
- Sections 02–06 assume a fresh BCM 11 head node. For brownfield, start
  at the section matching your state and verify forward.

## Source map

- Lab procedure ("Chaska Runbook", 23 sections) → the prescriptive steps.
  All 23 are present; the 7 the client docs dropped are restored here and
  marked **[restored]**.
- Client deployment docs (Wayland-Complete, 18 sources) → fixes,
  additions, and working values. Marked **[client]** where they diverge.
- A prior completeness audit (`13 - Completeness and Source Mapping
  Report.md` in the client package) verified the client sources; this
  template builds on it rather than repeating it.
