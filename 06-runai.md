# 06 — NVIDIA Run:ai Deployment

> **Prerequisites:** 05 complete (healthy k8s + GPU Operator). DNS and TLS
> decisions from 01 finalized.

## 6.1 — Stage credentials and certificates

```bash
install -d -m 0700 /cm/images/runai
cd /cm/images/runai
```

Self-signed CA for the Run:ai ingress (prefer site PKI when available):

```bash
openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
  -keyout private.key -out ca.crt \
  -subj "/CN=${FQDN_RUNAI}" \
  -addext "subjectAltName=DNS:${FQDN_RUNAI},DNS:*.${FQDN_RUNAI},IP:${IP_RUNAI}"
chmod 0600 private.key
```

> **Field note:** the lab concatenated cert+key into `full-chain.pem`
> and the wizard accepted it — keep the private key separate
> (`chmod 0600`) and only merge if the wizard requires it.

NGC API key (from `https://org.ngc.nvidia.com/account/api-key`):

```bash
# Paste the key into ngc-api.key (mode 0600). Never commit the value.
vi /cm/images/runai/ngc-api.key
chmod 0600 /cm/images/runai/ngc-api.key
export NGC_API_KEY="$(cat /cm/images/runai/ngc-api.key)"
```

Expected layout:

```text
/cm/images/runai/ca.crt
/cm/images/runai/private.key
/cm/images/runai/ngc-api.key
```

## 6.2 — Run the installer

```bash
cm-runai-setup
```

| Prompt | Selection |
|---|---|
| Action | Deploy |
| Mode | Run:ai self-hosted |
| NGC API key | `/cm/images/runai/ngc-api.key` |
| FQDN | `$FQDN_RUNAI` |
| `.crt` / `.key` | `/cm/images/runai/ca.crt`, `/cm/images/runai/private.key` |
| Username | `$RUNAI_ADMIN_USER` |
| Password | `$RUNAI_ADMIN_PASSWORD` (enter securely) |
| Deploy cluster | Yes |
| Control-plane category | `$CAT_CP` |
| Version | `$RUNAI_VERSION` |
| Run:ai gateway IP | `$IP_RUNAI` |
| Kourier (inference) IP | `$IP_INFERENCE` |
| Save file | `/root/cm-runai-setup.conf` (default) |

Both DNS checks in the wizard must pass.

```bash
cm-runai-setup -c /root/cm-runai-setup.conf
```

Monitor (second session):

```bash
watch kubectl get pods -n runai-backend   # wait for Running/Completed
watch kubectl get pods -n runai
```

## 6.3 — Inference TLS **[restored + corrected]**

> The lab's inference-secret command had cert/key swapped
> (`--cert` pointed at the merged PEM, `--key` at the CRT). Corrected
> below — the client docs confirm this mapping.

```bash
cd /cm/images/runai
openssl req -x509 -newkey rsa:4096 -sha256 -days 365 -nodes \
  -keyout inference.key -out inference.crt \
  -subj "/CN=${FQDN_INFERENCE}" \
  -addext "subjectAltName=DNS:${FQDN_INFERENCE},DNS:*.${FQDN_INFERENCE},IP:${IP_INFERENCE}"
chmod 0600 inference.key
kubectl create secret tls runai-cluster-inference-tls-secret -n runai \
  --cert=/cm/images/runai/inference.crt \
  --key=/cm/images/runai/inference.key
```

## 6.4 — Gateway listeners (kgateway) **[restored]**

> Run:ai on kgateway ships **without** the `https-workloads` listener —
> `*.runai.<domain>` (workspaces, applications) won't resolve until you
> add it. Same story for `*.runai-inference.<domain>` on the
> Knative/Kourier side. This was a real deployment fix.

Websocket upgrades for the gateway:

```yaml
# http-listener-policy.yaml
apiVersion: gateway.kgateway.dev/v1alpha1
kind: HTTPListenerPolicy
metadata:
  name: runai-gateway-websocket
  namespace: runai-backend
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: runai-gateway
  upgradeConfig:
    enabledUpgrades:
    - websocket
```

```bash
kubectl apply -f http-listener-policy.yaml
```

> **Version note:** `HTTPListenerPolicy` was correct for the kgateway
> in this deployment, but kgateway **v2.5 removed the CRD** — newer
> versions use `ListenerPolicy` with the websocket config under
> `spec.default.httpSettings`. Check your installed kgateway version
> (`kubectl get crd | grep kgateway`) and use the matching API. The
> migration is mechanical (same fields, new parent).

Add the missing workloads listener:

```yaml
# runai-gateway-workload-listener-patch.yaml
spec:
  listeners:
  - name: https
    protocol: HTTPS
    port: 443
    hostname: runai.$DOMAIN
    tls:
      mode: Terminate
      certificateRefs:
      - kind: Secret
        name: runai-backend-tls
  - name: https-workloads
    protocol: HTTPS
    port: 443
    hostname: "*.runai.$DOMAIN"
    tls:
      mode: Terminate
      certificateRefs:
      - kind: Secret
        name: runai-backend-tls
```

```bash
kubectl apply -f runai-gateway-workload-listener-patch.yaml
```

For `*.runai-inference.$DOMAIN`: check what Knative/Kourier created
first — don't just attach it to `runai-gateway`:

```bash
kubectl get svc -n knative-serving -o wide
kubectl get routes.serving.knative.dev -A
kubectl get gateways -A
kubectl get httproutes -A
kubectl get secret runai-cluster-inference-tls-secret -n runai
```

The inference wildcard must resolve to the Kourier/Knative external
entry point with a certificate covering both the base inference
hostname and its wildcard (see 6.3). Create the missing Gateway +
HTTPRoute there if absent, referencing the inference TLS secret.

## 6.5 — Backend placement (NATS + gateway) **[restored]**

Pin the Run:ai backend's stateful services to the control plane so a
worker reboot can't take down NATS:

```bash
export RELEASE=runai-backend RELEASE_NS=runai-backend
# snapshot before changing anything:
helm history $RELEASE -n $RELEASE_NS > helm-history-before.txt
helm get values $RELEASE -n $RELEASE_NS -a > values-before.yaml
```

```yaml
# runai-backend-system-placement.yaml
global:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: node-role.kubernetes.io/runai-system
                operator: Exists
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule
nats:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: node-role.kubernetes.io/runai-system
                operator: Exists
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule
```

```bash
helm upgrade $RELEASE runai-backend/control-plane -n $RELEASE_NS \
  --version $RUNAI_VERSION --reuse-values \
  -f runai-backend-system-placement.yaml --dry-run --debug > backend-dryrun.txt
# review, then:
helm upgrade $RELEASE runai-backend/control-plane -n $RELEASE_NS \
  --version $RUNAI_VERSION --reuse-values \
  -f runai-backend-system-placement.yaml --atomic --wait --timeout 15m
kubectl rollout restart statefulset/runai-backend-nats -n runai-backend
kubectl rollout status statefulset/runai-backend-nats -n runai-backend --timeout=15m
# Never delete all NATS members simultaneously.
```

Keep the kgateway Deployment off the workers:

```bash
for n in $GPU_WORKERS; do
  kubectl label node "$n" node.kubernetes.io/exclude-from-external-load-balancers=true --overwrite
done
kubectl rollout restart deployment/runai-gateway -n runai-backend
# validate the gateway pods land on the control-plane nodes
```

Rollback: remove the labels, `helm rollback $RELEASE <GOOD_REVISION> -n $RELEASE_NS --wait --timeout 15m`.

## 6.6 — Validate

```bash
curl -vk https://$FQDN_RUNAI/
kubectl get runaiconfig -A
kubectl get pods -n runai-backend
kubectl get pods -n runai
nslookup $FQDN_RUNAI
```

- [ ] `https://$FQDN_RUNAI/` loads the Run:ai UI
- [ ] All `runai` / `runai-backend` pods Running
- [ ] DNS resolves `$FQDN_RUNAI` → `$IP_RUNAI`

## 6.7 — Back up the control plane

```bash
install -d -m 0700 /root/runai-backup && cd /root/runai-backup
set +x   # no tracing while secrets are in play

# Discover the live names first, then fill in the four values:
kubectl -n runai-backend get pods      # -> PG_POD
kubectl -n runai-backend get secrets    # -> PG_SECRET
PG_POD="<postgresql-pod>"
PG_SECRET="<postgresql-secret>"
PG_USER="<db-user>"
PG_DB="<db-name>"

kubectl get runaiconfig runai -n runai -o jsonpath='{.spec}' > runai_config_backup.yaml
helm get values runai-backend -n runai-backend > runai_control_plane_values.yaml
POSTGRES_PASSWORD=$(kubectl -n runai-backend get secret "$PG_SECRET" \
  -o jsonpath='{.data.postgres-password}' | base64 -d)
kubectl -n runai-backend exec "$PG_POD" -- \
  env PGPASSWORD="$POSTGRES_PASSWORD" pg_dump -U "$PG_USER" "$PG_DB" > runai_db_backup.sql
unset POSTGRES_PASSWORD
chmod 0600 runai_config_backup.yaml runai_control_plane_values.yaml runai_db_backup.sql
test -s runai_config_backup.yaml && test -s runai_db_backup.sql && echo "backups OK"
```

> The four `PG_*` values come from the live cluster (names are
> Helm-generated, so they're discovered, not templated). Never store
> dumps or decoded secrets in the docs.
