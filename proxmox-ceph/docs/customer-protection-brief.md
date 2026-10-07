# Customer Protection Brief — "You Are Protected"

Customer-facing high points for a hyperconverged Proxmox VE + Ceph deployment.
Anonymized and template-ready — adapt the numbers (node count, drive count, warranty
terms) per site. This is the *what it means for you* companion to the runbook's
*how we build it*.

## Every write, three copies

Every VM disk write is stored on **all three physical servers** before it is
acknowledged. One server can fail completely — power loss, dead board, anything —
with **zero data loss**.

## Automatic recovery

Proxmox HA watches the cluster and restarts affected VMs on the surviving nodes
automatically, within minutes. No human intervention, no 3am phone call to start
the recovery.

## Self-healing storage

Ceph detects a failed drive or a failed node and re-replicates the affected data
onto the healthy hardware on its own, while the cluster keeps serving I/O the
whole time. Degraded is a state the cluster passes through, not a state it gets
stuck in.

## Backups beyond hardware failure

Proxmox Backup Server with retention policy and tested restores. Hardware
resilience covers dead servers; backups cover ransomware, human error, and data
corruption — the failures replication can't fix.

## No single points of failure

- N+N redundant power supplies per node
- Mirrored boot drives per node
- Dual high-speed fabric links per node, spread across two switches
- 3-node quorum: the cluster keeps making decisions with any one node down

## Enterprise hardware, enterprise support

Server-class hardware with next-business-day on-site warranty — when something
does fail, parts and hands arrive fast, and the cluster has already absorbed the
failure meanwhile.
