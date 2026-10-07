# 14 — Greenfield Support Infrastructure

> Jumpbox, DNS, and time sync for a fresh site — before 01's IP plan
> goes live. These are the boxes the cluster depends on but that aren't
> part of the cluster itself.

## 14.1 — Jumpbox (admin host)

A hardened Ubuntu 24.04 host on the management network. All BCM/k8s
admin work happens here — never from a laptop over VPN if you can avoid it.

```bash
# Fresh Ubuntu 24.04 Server install, then:
apt update && apt update && apt upgrade -y

# SSH: key-only, no root password login
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
systemctl reload sshd

# Firewall: SSH from the admin network only
ufw default deny incoming
ufw default allow outgoing
ufw allow from <ADMIN-NET> to any port 22
ufw --force enable

# Essentials
apt install -y nvim git curl wget jq dnsutils chrony

# kubectl + helm (match the cluster versions from 00-variables.sh)
curl -LO "https://dl.k8s.io/release/v${K8S_VERSION}.0/bin/linux/amd64/kubectl"
install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

- [ ] Only key-based SSH works; `ufw status` shows the admin-net rule
- [ ] `kubectl version --client`, `helm version` match the plan

## 14.2 — DNS (Technitium or site DNS)

The cluster needs forward **and** reverse DNS for every node and
service FQDN from 01 (the Run:ai and `cm-*-setup` wizards check both).
For greenfield, run Technitium DNS Server on the jumpbox or a small
dedicated VM; brownfield can use the site's existing DNS (SuperDNS).

```bash
# Technitium DNS Server (self-hosted authoritative + recursive):
curl -sSL https://download.technitium.com/dns/install.sh | sudo bash
# Admin console: http://<dns-ip>:5380  (default admin / admin — change it)
```

In the console (or via its HTTP API):

1. Add a primary zone for `$DOMAIN`.
2. A records for every node in 01 (`bcm-headnode`, `k8s-ctrl-1..3`,
   `gpu-worker-*`) and every service (`kgateway`, `runai`,
   `runai-inference`, plus `*.runai` and `*.runai-inference` wildcards).
3. Reverse zones for each network in 01; PTR records for every A record.
4. Set the cluster nodes and headnode to use this DNS (BCM: set on the
   networks in 01, or via DHCP).

Verify from the jumpbox:

```bash
for h in bcm-headnode.$DOMAIN k8s-ctrl-1.$DOMAIN $FQDN_RUNAI $FQDN_INFERENCE; do
  dig +short $h @$DNS_IP
done
dig +short -x $IP_RUNAI @$DNS_IP
```

- [ ] Every FQDN resolves forward; every IP resolves back (PTR)
- [ ] Wildcards `*.runai.$DOMAIN` / `*.runai-inference.$DOMAIN` resolve

## 14.3 — Time sync (Chrony)

Kerberos, TLS, and etcd all hate clock skew. Chrony runs on the
jumpbox/DNS host syncing upstream; the BCM headnode syncs from it and
serves the cluster.

On the time source (jumpbox or dedicated host):

```bash
apt install -y chrony
cat > /etc/chrony/conf.d/site.conf <<'EOF'
# Upstream NTP — replace with the site's approved sources
pool pool.ntp.org iburst
# Serve time to the cluster networks
allow 10.10.15.0/24
allow 10.10.12.0/24
allow 10.10.13.0/24
allow 10.10.16.0/24
EOF
systemctl enable --now chrony
chronyc sources
```

On the BCM headnode, point Chrony at the time source instead of the
public pools, then let BCM distribute time to the nodes (BCM manages
node NTP from the headnode by default — verify with `cmsh` time settings
per the BCM 11 docs if the site needs custom sources).

```bash
chronyc tracking   # Leap status normal, Stratum <= 4
chronyc sources -v # the site source is reachable and selected
```

- [ ] `chronyc tracking` shows synchronized, offset < 50ms
- [ ] Headnode serves NTP to all four cluster networks
- [ ] Spot-check a GPU node: `chronyc tracking` agrees within a second
