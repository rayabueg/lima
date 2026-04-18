#!/usr/bin/env bash
# Runs INSIDE the Lima VM as root (invoked via sudo from the host).
# Installs containerd + kubeadm/kubelet/kubectl and applies standard kubeadm prerequisites.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

log() {
  printf '\n[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*"
}

log "Disabling swap (required by kubeadm)"
swapoff -a || true
sed -i.bak '/\sswap\s/s/^/#/' /etc/fstab || true

log "Installing base packages"
apt-get update
apt-get install -y --no-install-recommends \
  apt-transport-https \
  ca-certificates \
  conntrack \
  containerd \
  curl \
  gpg \
  socat

log "Configuring kernel modules + sysctl for Kubernetes"
cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF

cat >/etc/sysctl.d/99-kubernetes-cri.conf <<'EOF'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF

modprobe overlay || true
modprobe br_netfilter || true
sysctl --system

log "Configuring containerd (SystemdCgroup=true)"
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable --now containerd
systemctl restart containerd

if command -v kubeadm >/dev/null 2>&1 && command -v kubelet >/dev/null 2>&1 && command -v kubectl >/dev/null 2>&1; then
  log "kubeadm/kubelet/kubectl already installed; skipping"
else
  log "Adding Kubernetes apt repo (pkgs.k8s.io stable v1.30)"
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key \
    | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /" \
    > /etc/apt/sources.list.d/kubernetes.list

  apt-get update
  apt-get install -y kubelet kubeadm kubectl
  apt-mark hold kubelet kubeadm kubectl
fi

log "Installed versions"
kubeadm version
kubectl version --client=true || true
