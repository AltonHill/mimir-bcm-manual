#!/bin/bash
# =====================================================================
# 00-variables.sh — Site-specific values for the B300 runbook template
# ---------------------------------------------------------------------
# This is the ONLY file you customize per deployment. Every command in
# sections 01-11 references these variables. Fill it in, `source` it,
# and the rest of the runbook runs top to bottom.
#
# "Companyify" step: replacing these values (and DOMAIN) with the real
# site's values is the entire site-customization process.
# =====================================================================

# --- Identity ---
export DOMAIN="example.internal"          # DNS domain for the cluster
export CLUSTER_NAME="bcm-cluster"         # BCM cluster name
export CLIENT_ORG="Wayland Megacorp"      # Organization (docs/license)

# --- Networks (CIDR + gateway). Segmented layout is the default;
#     the Chaska lab validated on a flat 10.10.13.0/24 layout instead. ---
export NET_PROVISION="10.10.15.0/24"      # BCM internalnet (provisioning)
export GW_PROVISION="10.10.15.1"
export NET_STORAGE="10.10.12.0/24"        # Storagenet (Pure NFS)
export NET_USER="10.10.13.0/24"           # Usernet (services, user access)
export GW_USER="10.10.13.1"
export NET_OOB="10.10.16.0/24"            # OOB / hardware management
export GW_OOB="10.10.16.1"
export NET_DNS1="10.10.11.53"
export NET_DNS2="10.10.11.54"
export DNS_IP="$NET_DNS1"                  # DNS server under test (14); override per site

# --- Kubernetes networks (from cm-kubernetes-setup) ---
export K8S_SERVICE_NET="10.10.11.0"
export K8S_SERVICE_MASK="16"
export K8S_POD_NET="10.10.18.0"
export K8S_POD_MASK="16"

# --- Node roles (short names; FQDN = <name>.${DOMAIN}) ---
export BCM_HEADNODE="bcm-headnode"         # head node short name
export BCM_HEADNODE_IP="10.10.15.10"       # head node IP
export K8S_CTRL="k8s-ctrl-1 k8s-ctrl-2 k8s-ctrl-3"   # 10.10.15.50-52
export K8S_CTRL_IPS="10.10.15.50 10.10.15.51 10.10.15.52"
# --- GPU workers ---
# Hardware families: DGX A/H/B series are treated as interchangeable here
# (A100, H100/H200, B200/B300) — one category+image per node TYPE.
# HGX 8-GPU OEM nodes (Dell, HPE, Lenovo) and Cisco UCS GPU nodes follow
# the exact same pattern: add a category+image per type (see 03).
# NVL72 rack-scale systems (Vera Rubin platform) are shipping as of
# Sept 2026 — same per-type pattern for provisioning, but the rack
# fabric and liquid cooling are their own design.
# The client ran 2× Cisco UCS GPU nodes; the lab ran DGX A100 + DGX H200.
export GPU_WORKERS="gpu-worker-1 gpu-worker-2 gpu-worker-3"
export GPU_WORKER_IPS="10.10.15.53 10.10.15.54 10.10.15.55"
export GPU_NODE_TYPE="dgx-b300"            # e.g. dgx-b300, dgx-h200, hgx-dell, ucs
export IMG_GPU="runai-dgx-image"           # per-type images: runai-<type>-image
export CAT_GPU="runai-dgx-cat"             # per-type categories: runai-<type>-cat

# --- Service IPs (Usernet; MetalLB / gateway addresses) ---
export IP_KGATEWAY="10.10.13.200"          # Kubernetes gateway (Kgateway)
export IP_RUNAI="10.10.13.201"             # Run:ai control-plane ingress
export IP_INFERENCE="10.10.13.202"         # Run:ai inference (Kourier)
export FQDN_KGATEWAY="kgateway.${DOMAIN}"
export FQDN_RUNAI="runai.${DOMAIN}"
export FQDN_INFERENCE="runai-inference.${DOMAIN}"

# --- BCM software images and categories ---
export IMG_CP="runai-cp-image"
export IMG_WRK="runai-wrk-image"
export CAT_CP="runai-cp-cat"
export CAT_WRK="runai-wrk-cat"
# (GPU image/category vars are defined with the GPU workers above.)
export KERNEL_VER="6.8.0-142-generic"      # validate with uname -r on image

# --- Storage ---
export NFS_SERVER="10.10.12.250"           # Pure NFS server (Storagenet)
export NFS_SHARE="/data"
export NFS_MOUNT="/mnt/data"

# --- Credentials (fill per deployment; never commit real values) ---
export BCM_PRODUCT_KEY="<BCM-PRODUCT-KEY>" # from ui.licensing.nvidia.com
export NGC_API_KEY="<NGC-API-KEY>"         # from org.ngc.nvidia.com/account/api-key
export BMC_USER="dgxadmin"
export BMC_PASSWORD="<BMC-PASSWORD>"
export RUNAI_ADMIN_USER="admin@${DOMAIN}"
export RUNAI_ADMIN_PASSWORD="<RUNAI-ADMIN-PASSWORD>"
export PG_PASSWORD="<POSTGRES-PASSWORD>"

# --- Versions (known-working baseline; see 12-baseline.md) ---
export BCM_VERSION="11"
export K8S_VERSION="1.34"
export RUNAI_VERSION="2.26.x"
export GPU_OPERATOR_VERSION="v26.3.1"
export NET_OPERATOR_VERSION="26.1.1"
export NFS_CSI_VERSION="4.13.4"
