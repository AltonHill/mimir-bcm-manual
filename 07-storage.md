# 07 — Storage

> **Prerequisites:** 05 complete (k8s healthy).
>
> Two plans, pick one:
> - **Simple (7A):** one default NFS StorageClass on a single share.
>   Fastest path; fine when one pool serves everything.
> - **Advanced (7B):** separate data / scratch / models StorageClasses
>   plus static PVs for pre-existing project and software shares.
>   This is the client's full design — use it when workloads need
>   different reclaim policies per data type.

## Design reference (both plans)

Logical layout from the client storage architecture:

```text
AI Pod storage
|-- User home service (NFS-backed homes, mounted on head node)
|-- Pure Storage NFS
|   |-- /shared/data      (datasets, Retain)
|   |-- /shared/scratch   (ephemeral, Delete)
|   |-- /shared/sw        (software, static PV)
|   `-- /shared/models    (model cache, Retain)
`-- Existing project/archive platform
    `-- /shared/proj      (pre-existing data, static PV, ReadOnlyMany)
```

Keep logical paths consistent (e.g. `/shared/...`) so researchers can
move between HPC and AI environments without relearning paths. The exact
NFS export names may differ from the logical mount paths.

## 7.1 — Head-node NFS mount

```bash
mkdir -p $NFS_MOUNT
mount -t nfs ${NFS_SERVER}:${NFS_SHARE} $NFS_MOUNT
df -h $NFS_MOUNT

# Persist in /etc/fstab (back it up first):
cp -a /etc/fstab /etc/fstab.bak-$(date +%F)
printf '# Pure NFS\n%s:%s\t%s\tnfs\tdefaults,nfsvers=4.1,rsize=1048576,wsize=1048576,_netdev 0 0\n' \
  "$NFS_SERVER" "$NFS_SHARE" "$NFS_MOUNT" >> /etc/fstab
mount -a && df -h $NFS_MOUNT
```

## 7.2 — NFS CSI driver (both plans)

> **Automate it:** `scripts/runbook.py storage --plan 7a` (or `7b`)
> generates the StorageClass YAML from `$NFS_SERVER`/`$NFS_SHARE` and
> runs the driver install below. `--dry-run` prints everything first.

```bash
helm repo add csi-driver-nfs https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts
helm install csi-driver-nfs csi-driver-nfs/csi-driver-nfs \
  --namespace kube-system --version $NFS_CSI_VERSION \
  --set externalSnapshotter.enabled=true \
  --set controller.runOnControlPlane=true
```

Validate:

```bash
watch kubectl --namespace=kube-system get pods --selector="app.kubernetes.io/instance=csi-driver-nfs"
kubectl -n kube-system get pod -o wide -l app=csi-nfs-controller
```

Node-level NFS check first (from the advanced plan — do this before
creating classes):

```bash
showmount -e $NFS_SERVER
# from each worker: mount -t nfs ${NFS_SERVER}:${NFS_SHARE} /mnt/test && umount /mnt/test
```

---

## 7A — Simple plan: one default StorageClass

```yaml
# nfs-sc.yaml — adjust server/share per site
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-csi
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: nfs.csi.k8s.io
parameters:
  server: 10.10.12.250
  share: /data
reclaimPolicy: Retain
volumeBindingMode: Immediate
allowVolumeExpansion: true
mountOptions:
  - nfsvers=4.1
  - hard
```

```bash
kubectl apply -f nfs-sc.yaml
kubectl get storageclass
kubectl describe storageclass nfs-csi
```

Make it the default (replacing `local-path`):

```bash
kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
```

Validate end to end:

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-nfs-test
spec:
  accessModes: [ReadWriteMany]
  resources: { requests: { storage: 2Gi } }
  storageClassName: nfs-csi
EOF
kubectl get pvc pvc-nfs-test
# write/read/persistence test with a pod, then clean up:
kubectl delete pvc pvc-nfs-test
```

---

## 7B — Advanced plan: data / scratch / models + static PVs **[restored]**

> The client's full implementation. Use when scratch must auto-clean,
> data must never auto-delete, and pre-existing project/software shares
> need mounting.

```yaml
# nfs-data.yaml — Retain: conservative for authoritative data
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-data
provisioner: nfs.csi.k8s.io
parameters:
  server: 10.10.12.250
  share: /shared/data
reclaimPolicy: Retain
volumeBindingMode: Immediate
allowVolumeExpansion: true
mountOptions:
  - nfsvers=4.1
  - hard
---
# nfs-scratch.yaml — Delete: scratch auto-cleans (approve first)
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-scratch
provisioner: nfs.csi.k8s.io
parameters:
  server: 10.10.12.250
  share: /shared/scratch
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
mountOptions:
  - nfsvers=4.1
  - hard
---
# nfs-models.yaml — Retain: model cache
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-models
provisioner: nfs.csi.k8s.io
parameters:
  server: 10.10.12.250
  share: /shared/models
reclaimPolicy: Retain
volumeBindingMode: Immediate
allowVolumeExpansion: true
mountOptions:
  - nfsvers=4.1
  - hard
```

```bash
kubectl apply -f nfs-data.yaml -f nfs-scratch.yaml -f nfs-models.yaml
kubectl get storageclass
```

Static PV for pre-existing project data (no provisioning — it already exists):

```yaml
# project-static.yaml — adjust server/share/capacity per site
apiVersion: v1
kind: PersistentVolume
metadata:
  name: project-pv
spec:
  capacity:
    storage: 5Pi   # confirm actual capacity before applying
  accessModes:
    - ReadOnlyMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: project-static
  mountOptions:
    - nfsvers=4.1
    - hard
  csi:
    driver: nfs.csi.k8s.io
    volumeHandle: project-existing
    volumeAttributes:
      server: 10.10.12.250
      share: /shared/proj
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: project
  namespace: runai-ngs
spec:
  accessModes:
    - ReadOnlyMany
  resources:
    requests:
      storage: 5Pi
  storageClassName: project-static
  volumeName: project-pv
```

Same pattern for the software share (`/shared/sw`) — static PV/PVC,
`ReadOnlyMany`, `Retain`.

Cross-node validation (advanced plan):

```bash
# dynamic scratch PVC + pod test, then a pod on a second node
# mounting the same claim to prove cross-node visibility
kubectl get pvc -A
kubectl get pv
```

## Verification (both plans)

- [ ] `kubectl get storageclass` shows the intended classes (default as intended)
- [ ] Test PVC binds; a test pod writes, reads back, and survives pod restart
- [ ] `showmount -e $NFS_SERVER` reachable from worker nodes
- [ ] (7B) Static project/software PVs bound; `Retain` on data/models confirmed
