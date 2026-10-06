#!/usr/bin/env python3
"""runbook.py — subroutine passes for the B300 deployment runbook.

Each pass performs one runbook job, driven by 00-variables.sh (and CSV
inventories). Passes are small, reviewable, and re-runnable — the end
goal is one pass per runbook section, all driven by data files.

Usage:
    scripts/runbook.py vars [--vars 00-variables.sh]
    scripts/runbook.py images [--vars 00-variables.sh] [--dry-run|--exec]
    scripts/runbook.py nodes --inventory inventory.csv [--dry-run|--exec]
    scripts/runbook.py users --accounts accounts.csv [--dry-run|--exec]

--dry-run (default) prints exactly what would run. --exec asks for
confirmation, then runs it. cmsh passes must run on the BCM head node
as root.

Python 3.12 stock on Ubuntu 24.04 / DGX OS — stdlib only.
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

REQUIRED_VARS = [
    "DOMAIN", "CLUSTER_NAME",
    "NET_PROVISION", "NET_STORAGE", "NET_USER", "NET_OOB",
    "GW_PROVISION", "GW_USER", "GW_OOB",
    "BCM_HEADNODE", "K8S_CTRL", "GPU_WORKERS",
    "IP_KGATEWAY", "IP_RUNAI", "IP_INFERENCE",
    "IMG_CP", "IMG_WRK", "IMG_GPU",
    "CAT_CP", "CAT_WRK", "CAT_GPU",
    "KERNEL_VER", "NFS_SERVER", "NFS_SHARE", "NFS_MOUNT",
]


def load_vars(path):
    """Parse `export KEY="value"` lines from a variables.sh file.

    Quote-aware: a trailing `# comment` is stripped only when it is
    outside the quoted value.
    """
    vars_ = {}
    with open(path) as f:
        for line in f:
            m = re.match(r'\s*export\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$', line)
            if not m:
                continue
            key, rest = m.group(1), m.group(2).strip()
            if rest.startswith('"'):
                end = rest.find('"', 1)
                val = rest[1:end] if end != -1 else rest[1:]
            elif rest.startswith("'"):
                end = rest.find("'", 1)
                val = rest[1:end] if end != -1 else rest[1:]
            else:
                val = rest.split("#", 1)[0].strip()
            vars_[key] = val
    return vars_


def load_script_module(filename):
    """Import a hyphenated script filename (generate-nodes.py) as a module."""
    import importlib.util
    path = os.path.join(HERE, filename)
    spec = importlib.util.spec_from_file_location(
        filename.replace("-", "_").replace(".py", ""), path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def confirm(n, what):
    ans = input(f"About to {what} ({n} commands). Type YES to proceed: ")
    if ans.strip() != "YES":
        print("aborted.")
        sys.exit(1)


def run_commands(cmds, dry_run, what):
    if dry_run:
        for c in cmds:
            print(c)
        print(f"# dry-run: {len(cmds)} commands (use --exec to run)", file=sys.stderr)
        return
    confirm(len(cmds), what)
    for c in cmds:
        print(f"+ {c}", flush=True)
        r = subprocess.run(c, shell=True)
        if r.returncode != 0:
            print(f"FAILED (rc={r.returncode}): {c}", file=sys.stderr)
            sys.exit(1)
    print("pass complete.")


# ---------------------------------------------------------------- passes

def pass_vars(vars_, args):
    missing = [k for k in REQUIRED_VARS if not vars_.get(k)]
    placeholders = {k: v for k, v in vars_.items() if "<" in v and ">" in v}
    if missing:
        print("missing variables:", ", ".join(missing))
    if placeholders:
        print("unfilled placeholders:")
        for k, v in placeholders.items():
            print(f"  {k}={v}")
    if missing or placeholders:
        sys.exit(1)
    print(f"OK: {len(vars_)} variables loaded, {len(REQUIRED_VARS)} required all set.")


def pass_networks(vars_, args):
    """Runbook 01: create/align the four BCM networks from the IP plan.

    internalnet is created by the BCM installer; the pass aligns it to
    the plan. storagenet/usernet/mgmtnet are created. Run once — `add`
    fails if the network already exists.
    """
    p, gp = vars_["NET_PROVISION"], vars_["GW_PROVISION"]
    s = vars_["NET_STORAGE"]
    u, gu = vars_["NET_USER"], vars_["GW_USER"]
    o, go = vars_["NET_OOB"], vars_["GW_OOB"]
    cmds = [
        f'cmsh -c "network; use internalnet ; set network {p} ; set gateway {gp} ; commit"',
        f'cmsh -c "network; add storagenet {s} ; commit"',
        f'cmsh -c "network; use storagenet ; set network {s} ; commit"',
        f'cmsh -c "network; add usernet {u} ; commit"',
        f'cmsh -c "network; use usernet ; set network {u} ; set gateway {gu} ; commit"',
        f'cmsh -c "network; add mgmtnet {o} ; commit"',
        f'cmsh -c "network; use mgmtnet ; set network {o} ; set gateway {go} ; set managementallowed yes ; commit"',
        'cmsh -c "network; list"',
    ]
    run_commands(cmds, args.dry_run, "create/align the BCM networks")


def pass_images(vars_, args):
    cp, wrk, gpu = vars_["CAT_CP"], vars_["CAT_WRK"], vars_["CAT_GPU"]
    icp, iwrk, igpu = vars_["IMG_CP"], vars_["IMG_WRK"], vars_["IMG_GPU"]
    # DGX node types clone the dgx base image; HGX/UCS/OEM clone default
    gpu_base = "dgx-image" if vars_.get("GPU_NODE_TYPE", "").startswith("dgx") else "default-image"
    cmds = [
        f'cmsh -c "category; add {cp} ; commit"',
        f'cmsh -c "category; add {wrk} ; commit"',
        f'cmsh -c "category; add {gpu} ; commit"',
        f'cmsh -c "softwareimage; clone default-image {icp} ; commit"',
        f'cmsh -c "softwareimage; clone default-image {iwrk} ; commit"',
        f'cmsh -c "softwareimage; clone {gpu_base} {igpu} ; commit"',
        f'cmsh -c "category; use {cp} ; set softwareimage {icp} ; commit"',
        f'cmsh -c "category; use {wrk} ; set softwareimage {iwrk} ; commit"',
        f'cmsh -c "category; use {gpu} ; set softwareimage {igpu} ; commit"',
    ]
    print(f"# images pass: GPU base image = {gpu_base} (GPU_NODE_TYPE={vars_.get('GPU_NODE_TYPE')})",
          file=sys.stderr)
    run_commands(cmds, args.dry_run, "create categories and images")


def _storage_yaml_7a(server, share):
    return f"""apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-csi
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: nfs.csi.k8s.io
parameters:
  server: {server}
  share: {share}
reclaimPolicy: Retain
volumeBindingMode: Immediate
allowVolumeExpansion: true
mountOptions:
  - nfsvers=4.1
  - hard
"""


def _storage_yaml_7b(server, share):
    docs = []
    for name, sub, reclaim in (("nfs-data", "data", "Retain"),
                               ("nfs-scratch", "scratch", "Delete"),
                               ("nfs-models", "models", "Retain")):
        docs.append(f"""apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: {name}
provisioner: nfs.csi.k8s.io
parameters:
  server: {server}
  share: {share}/{sub}
reclaimPolicy: {reclaim}
volumeBindingMode: Immediate
allowVolumeExpansion: true
mountOptions:
  - nfsvers=4.1
  - hard
""")
    return "---\n".join(docs)


def pass_storage(vars_, args):
    """Runbook 07: NFS CSI driver + StorageClasses.

    --plan 7a (default): one default StorageClass (nfs-csi).
    --plan 7b: data (Retain) / scratch (Delete) / models (Retain).
    Shares are derived from $NFS_SHARE. The CSI driver install is
    run-once; re-running needs `helm upgrade`.
    """
    server, share = vars_["NFS_SERVER"], vars_["NFS_SHARE"]
    csi_ver = vars_["NFS_CSI_VERSION"]
    plan = args.plan
    yaml_text = _storage_yaml_7a(server, share) if plan == "7a" \
        else _storage_yaml_7b(server, share)
    fname = f"nfs-storage-{plan}.yaml"
    helm_cmds = [
        "helm repo add csi-driver-nfs "
        "https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts",
        f"helm install csi-driver-nfs csi-driver-nfs/csi-driver-nfs "
        f"--namespace kube-system --version {csi_ver} "
        f"--set externalSnapshotter.enabled=true "
        f"--set controller.runOnControlPlane=true",
    ]
    if args.dry_run:
        print(f"# storage pass (plan {plan}): files + commands", file=sys.stderr)
        print(f"# --- file: {fname} ---")
        print(yaml_text, end="")
        for c in helm_cmds:
            print(c)
        print(f"kubectl apply -f {fname}")
        print(f"kubectl get storageclass")
        print(f"# dry-run: review the YAML above (use --exec to run)",
              file=sys.stderr)
        return
    confirm(3, f"install the NFS CSI driver and apply plan {plan}")
    for c in helm_cmds:
        print(f"+ {c}", flush=True)
        r = subprocess.run(c, shell=True)
        if r.returncode != 0:
            print(f"FAILED (rc={r.returncode}): {c}", file=sys.stderr)
            sys.exit(1)
    with open(fname, "w") as f:
        f.write(yaml_text)
    print(f"wrote {fname}")
    r = subprocess.run(["kubectl", "apply", "-f", fname])
    sys.exit(r.returncode)


def pass_disklayouts(vars_, args):
    """Runbook 12: disk-layout framework.

    Looks for disk-layouts/<GPU_NODE_TYPE>-by-path.xml. If it is not
    there, the pass stops and prints the collection procedure — the XML
    can only be built from live hardware of that exact type. If it is
    there, the pass applies it at category level.

    Validate on ONE node of the type before fleet rollout.
    """
    ntype = vars_.get("GPU_NODE_TYPE", "")
    cat = vars_["CAT_GPU"]
    layout = os.path.join("disk-layouts", f"{ntype}-by-path.xml")
    if not os.path.exists(layout):
        print(f"# disklayouts pass: no layout for node type '{ntype}'",
              file=sys.stderr)
        print(f"# expected: {layout}", file=sys.stderr)
        print("#", file=sys.stderr)
        print("# The XML can only be built from live hardware. On one node",
              file=sys.stderr)
        print("# of this exact type, collect the stable slot paths:",
              file=sys.stderr)
        print("#   ls -la /dev/disk/by-path/ | grep nvme", file=sys.stderr)
        print("# then copy the BCM template XML from", file=sys.stderr)
        print("# /cm/local/apps/cmd/etc/htdocs/disk-setup/ and substitute",
              file=sys.stderr)
        print("# the by-path device paths (never /dev/nvmeXnY).", file=sys.stderr)
        print("# Full procedure: section 12.", file=sys.stderr)
        sys.exit(1)
    print("# disklayouts pass: TEST ON ONE NODE FIRST, then fleet rollout",
          file=sys.stderr)
    print(f"# single-node test: cmsh -c \"device ; use <node> ; "
          f"set disksetup {os.path.abspath(layout)} ; commit\"",
          file=sys.stderr)
    cmds = [
        f'cmsh -c "category ; use {cat} ; set disksetup {os.path.abspath(layout)} ; commit"',
        'cmsh -c "disksetup list"',
    ]
    run_commands(cmds, args.dry_run, f"apply the {ntype} disk layout")


def pass_nodes(vars_, args):
    gn = load_script_module("generate-nodes.py")
    rows = gn.load(args.inventory)
    errors = gn.check(rows)
    if errors:
        print(f"{len(errors)} problem(s):", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        sys.exit(1)
    print(f"# nodes pass: {len(rows)} nodes validated", file=sys.stderr)
    script = gn.generate(rows)
    if args.dry_run:
        print(script)
        return
    confirm(len(rows), f"provision {len(rows)} nodes")
    with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as t:
        t.write(script)
        tname = t.name
    r = subprocess.run(["bash", tname])
    os.unlink(tname)
    sys.exit(r.returncode)


def pass_users(vars_, args):
    gu = load_script_module("generate-users.py")
    rows = gu.load(args.accounts)
    errors = gu.check(rows)
    if errors:
        print(f"{len(errors)} problem(s):", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        sys.exit(1)
    if args.dry_run:
        r = subprocess.run([sys.executable, os.path.join(HERE, "generate-users.py"),
                            args.accounts])
        sys.exit(r.returncode)
    confirm(len(rows), f"create {len(rows)} BCM users")
    with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as t:
        tname = t.name
    subprocess.run([sys.executable, os.path.join(HERE, "generate-users.py"),
                    args.accounts], stdout=open(tname, "w"), check=True)
    print("Fill in <TEMP-*> passwords in", tname, "then run: bash", tname)


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description="B300 runbook subroutine passes.")
    ap.add_argument("--vars", default="00-variables.sh",
                    help="variables file (default: 00-variables.sh)")
    ap.add_argument("--dry-run", dest="dry_run", action="store_true", default=True,
                    help="print what would run (default)")
    ap.add_argument("--exec", dest="dry_run", action="store_false",
                    help="actually execute (asks for confirmation)")
    # also accept --dry-run/--exec after the subcommand name
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--dry-run", dest="dry_run", action="store_true", default=True)
    common.add_argument("--exec", dest="dry_run", action="store_false")
    sub = ap.add_subparsers(dest="pass_", required=True)

    sub.add_parser("vars", parents=[common], help="validate the variables file")
    sub.add_parser("networks", parents=[common],
                   help="runbook 01: create/align the BCM networks")
    sub.add_parser("images", parents=[common],
                   help="runbook 03: categories + software images")
    p = sub.add_parser("nodes", parents=[common],
                       help="runbook 03: provision nodes from CSV")
    p.add_argument("--inventory", required=True)
    sub.add_parser("disklayouts", parents=[common],
                   help="runbook 12: disk-layout framework (needs live hardware XML)")
    p = sub.add_parser("storage", parents=[common],
                       help="runbook 07: NFS CSI driver + StorageClasses")
    p.add_argument("--plan", choices=["7a", "7b"], default="7a",
                   help="7a: one default class; 7b: data/scratch/models")
    p = sub.add_parser("users", parents=[common],
                       help="runbook 15: create BCM users from CSV")
    p.add_argument("--accounts", required=True)

    args = ap.parse_args()
    if not os.path.exists(args.vars):
        # allow running from the scripts/ dir
        alt = os.path.join(os.path.dirname(HERE), os.path.basename(args.vars))
        alt2 = os.path.join(HERE, "..", "00-variables.sh")
        for cand in (alt, alt2):
            if os.path.exists(cand):
                args.vars = cand
                break
    vars_ = load_vars(args.vars)
    {"vars": pass_vars, "networks": pass_networks, "images": pass_images,
     "nodes": pass_nodes, "disklayouts": pass_disklayouts,
     "storage": pass_storage, "users": pass_users}[args.pass_](vars_, args)


if __name__ == "__main__":
    main()
