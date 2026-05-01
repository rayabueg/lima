#!/usr/bin/env bash
# lima/rebuild-lab.sh
#
# Tear down and recreate an Ubuntu 24.04 Lima VM, then provision kubeadm prerequisites.
# Run bootstrap-cluster.sh afterwards to initialise Kubernetes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED_DIR="${SCRIPT_DIR}/../shared"

VM_NAME="${VM_NAME:-k8s-lab}"
TEMPLATE="${TEMPLATE:-template:ubuntu-24.04}"
CPUS="${CPUS:-6}"
MEMORY="${MEMORY:-10}" # GiB
DISK="${DISK:-60}"     # GiB
START_TIMEOUT="${START_TIMEOUT:-20m}"

log() {
  printf '\n[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }
}

need_cmd limactl
need_cmd bash

log "Deleting existing Lima instance (best effort): ${VM_NAME}"
limactl delete -y -f "${VM_NAME}" >/dev/null 2>&1 || true

log "Starting Lima instance: ${VM_NAME} (${TEMPLATE})"
limactl start -y \
  --name="${VM_NAME}" \
  --cpus="${CPUS}" \
  --memory="${MEMORY}" \
  --disk="${DISK}" \
  --containerd=none \
  --timeout="${START_TIMEOUT}" \
  --progress \
  "${TEMPLATE}"

log "Installing containerd + kubeadm/kubelet/kubectl inside the VM"
limactl shell "${VM_NAME}" sudo bash -s < "${SHARED_DIR}/provision-kubeadm.sh"

log "Validating kubeadm"
limactl shell "${VM_NAME}" kubeadm version

log "Done"
echo
printf 'Instance: %s\n' "${VM_NAME}"
printf 'Shell:    limactl shell %s\n' "${VM_NAME}"
