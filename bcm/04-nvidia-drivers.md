# 04 — NVIDIA Drivers

> **Prerequisites:** 03 complete (GPU image exists).

## 4.1 — Install / reinstall the driver stack (inside the GPU image)

```bash
cm-chroot-sw-img /cm/images/$IMG_GPU
apt update
apt install --reinstall -y \
  nvidia-driver-580-server \
  nvidia-utils-580-server \
  cm-nvidia-container-toolkit
```

> Do not mix the 580-server branch with 580 non-server or 610 packages.
> Record package versions before removing anything.

Configure the container toolkit for Kubernetes, enable persistence:

```bash
nvidia-ctk runtime configure --runtime=containerd
systemctl enable nvidia-fabricmanager nvidia-persistenced nvidia-dcgm
exit
```

## 4.2 — Repair: EGL overwrite conflict **[client]**

The client hit this during install:

```text
libnvidia-gl-580-server tried to overwrite
/usr/lib/x86_64-linux-gnu/libnvidia-egl-gbm.so.1.1.3
owned by libnvidia-egl-gbm1
```

Inspect first, then remove only the conflicting standalone EGL packages:

```bash
cm-chroot-sw-img /cm/images/$IMG_GPU
dpkg -S /usr/lib/x86_64-linux-gnu/libnvidia-egl-gbm.so.1.1.3
dpkg --audit
dpkg --remove --force-depends \
  libnvidia-egl-gbm1:amd64 \
  libnvidia-egl-xcb1:amd64 \
  libnvidia-egl-xlib1:amd64
apt-get --fix-broken install --no-install-recommends
dpkg --configure -a
apt-get check && dpkg --audit
exit
```

Do **not** use `dpkg --force-overwrite` as the normal repair — it leaves
two packages claiming the same files.

## 4.3 — Verify package consistency

```bash
cm-chroot-sw-img /cm/images/$IMG_GPU
dpkg -l | grep -E 'nvidia-driver|nvidia-dkms|nvidia-kernel|nvidia-firmware|libnvidia-(common|compute|gl|egl)|fabricmanager|cm-nvidia'
# every package should be on the chosen branch (580-server here)
dpkg -l 'linux-image-*' | awk '$1 == "ii" {print $2, $3}'
exit
```

Pin the image to the installed kernel **only after confirming it exists**:

```bash
cmsh -c "softwareimage; use $IMG_GPU; set kernelversion $KERNEL_VER; commit"
cmsh -c "softwareimage list"
```

## 4.4 — Push the image and validate on hardware

```bash
cmsh
# device
# imageupdate -n <gpu-worker-1> -w     (one node at a time)
```

> If a node-local repair must be retained, `grabimage` the node back
> into the image — only after reviewing exactly what will be captured.

On the GPU node itself:

```bash
nvidia-smi
# Expect: driver 580.95.05, CUDA 13.0 (record actuals for the B300 stack)
nvcc --version
nvidia-container-cli info
```

- [ ] `nvidia-smi` shows all GPUs, driver/CUDA versions match the plan
- [ ] `nvidia-container-cli info` reports the expected GPU model
- [ ] No `rc` (residual-config) nvidia packages remain: `dpkg -l | awk '$1=="rc" && $2~/nvidia/'`
