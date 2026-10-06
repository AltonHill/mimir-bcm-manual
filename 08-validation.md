# 08 — Validation

> **Prerequisites:** 05–07 complete.

## 8.1 — Node and GPU health

On each GPU worker (or via BCM):

```bash
nvidia-smi
nvidia-smi -q            # ECC errors, retired pages, clocks
nvidia-smi topo -m       # NVLink/NVSwitch topology — compare against the BOM
nvidia-container-cli info
lspci -nn | grep -i -E 'nvidia|ethernet'
ip -br link
ip -br addr
```

```bash
cmsh -c "device list"                       # all nodes [OK]
kubectl get nodes -o wide                   # all Ready
```

Expected `nvidia-smi`: all GPUs visible, driver/CUDA matching the 04
baseline. Record actuals for the site.

- [ ] All expected GPU devices visible; no critical ECC/retired-page alerts
- [ ] NVLink/NVL topology matches the BOM
- [ ] Container runtime sees the GPUs (`nvidia-container-cli info`)

## 8.2 — DNS and service endpoints **[restored]**

```bash
nslookup $FQDN_RUNAI          # → $IP_RUNAI
nslookup $FQDN_KGATEWAY       # → $IP_KGATEWAY
nslookup $FQDN_INFERENCE      # → $IP_INFERENCE
curl -vk https://$FQDN_RUNAI/ | head -5
```

## 8.3 — Workload smoke test

```bash
kubectl get pods -n runai-backend
kubectl get pods -n runai
kubectl get pods -n gpu-operator
kubectl get storageclass
```

> **Field note [client]:** the client's platform validation (08) and
> known-working baseline (12) are the reference for "healthy" — BCM 11,
> k8s 1.34, Run:ai 2.26.x, GPU Operator v26.3.1, NFS CSI 4.13.4. Any
> deviation from these versions is a deliberate decision; log it in 10.

## 8.4 — Node roles **[restored]**

Label nodes for workload scheduling:

```bash
kubectl get nodes
kubectl label nodes <node-name> node-role.kubernetes.io/worker=true
```

- [ ] Every node labeled per its role; GPU nodes carry NVIDIA capacity
      labels (`nvidia.com/gpu.count` etc.)

## 8.5 — GPU burn-in

Run every GPU hot before handing the cluster over. The burn is a
PyTorch matmul loop (no dataset, no network) — if a GPU can't sustain
it, you want to know now, not mid-training.

Label the GPU nodes first (one label, used by the Job below):

```bash
kubectl label nodes $GPU_WORKERS burnin/gpu=true
```

```yaml
# gpu-burnin.yaml — ConfigMap (the script) + Job (one pod per GPU node)
apiVersion: v1
kind: ConfigMap
metadata:
  name: gpu-burnin-script
data:
  burn.py: |
    import os, time, torch
    size = int(os.environ.get("BURN_SIZE", "8192"))
    dur = int(os.environ.get("BURN_SECS", "1800"))  # 30 min default
    devs = [f"cuda:{i}" for i in range(torch.cuda.device_count())]
    print(f"burn: {len(devs)} GPUs, {size}x{size} matmul, {dur}s", flush=True)
    ts = [torch.randn(size, size, device=d) for d in devs]
    torch.cuda.synchronize()
    end, it = time.time() + dur, 0
    while time.time() < end:
        for t in ts:
            t @ t
        torch.cuda.synchronize()
        it += 1
        if it % 20 == 0:
            print(f"iter {it}", flush=True)
    print(f"done: {it} iterations", flush=True)
---
apiVersion: batch/v1
kind: Job
metadata:
  name: gpu-burnin
spec:
  parallelism: 3     # = number of GPU nodes; one pod per node
  completions: 3
  template:
    metadata:
      labels:
        app: gpu-burnin
    spec:
      restartPolicy: Never
      nodeSelector:
        burnin/gpu: "true"
      containers:
      - name: burn
        image: nvcr.io/nvidia/pytorch:24.10-py3   # needs NGC pull secret (see 09)
        command: ["python", "-u", "/burn/burn.py"]
        env:
        - name: BURN_SECS
          value: "1800"
        resources:
          limits:
            nvidia.com/gpu: 8     # adjust to the node's GPU count
        volumeMounts:
        - name: burn-script
          mountPath: /burn
      volumes:
      - name: burn-script
        configMap:
          name: gpu-burnin-script
```

```bash
kubectl apply -f gpu-burnin.yaml
kubectl get jobs -w                        # wait for Complete
kubectl logs -l app=gpu-burnin --tail=5    # iter counts + "done"
```

While it runs, watch thermals/power on a couple of nodes:

```bash
nvidia-smi dmon -s pucvmet   # power, util, clocks, temp per GPU
dmesg | grep -i xid          # expect: nothing
```

- [ ] All pods `Complete`; iteration counts consistent across nodes
      (an outlier node is suspect — investigate before handoff)
- [ ] No Xid errors; temps stabilize below throttling

### Via Run:ai

**GUI:** Workloads → New Training workload → name `gpu-burnin`,
project, image `nvcr.io/nvidia/pytorch:24.10-py3`, 8 GPUs, command
`python -u /burn/burn.py` (mount the script via a ConfigMap-backed
volume, or paste the compact form into the command field). Same
`BURN_SECS` env.

**CLI (v2):** submit from a manifest —
`runai workload submit --file workload.yaml --project <project>`
(see `runai workload submit --help` and the CLI reference at
run-ai-docs.nvidia.com — flags move between releases, so verify
against the installed CLI). The Job YAML above is the source of truth
for image, command, and GPU count.
