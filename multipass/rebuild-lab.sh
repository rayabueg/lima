#!/usr/bin/env bash
# multipass/rebuild-lab.sh
#
# Tear down and recreate an Ubuntu 24.04 Multipass VM, then provision kubeadm prerequisites.
# Run bootstrap-cluster.sh afterwards to initialise Kubernetes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED_DIR="${SCRIPT_DIR}/../shared"

VM_NAME="${VM_NAME:-k8s-lab}"
CPUS="${CPUS:-6}"
MEMORY="${MEMORY:-10G}"
DISK="${DISK:-60G}"
IMAGE="${IMAGE:-24.04}"

log() {
  printf '\n[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }
}

need_cmd multipass
need_cmd bash

log "Deleting existing Multipass instance (best effort): ${VM_NAME}"
multipass delete -p "${VM_NAME}" >/dev/null 2>&1 || true

log "Launching Multipass instance: ${VM_NAME} (Ubuntu ${IMAGE})"
multipass launch "${IMAGE}" \
  --name "${VM_NAME}" \
  --cpus "${CPUS}" \
  --memory "${MEMORY}" \
  --disk "${DISK}"

log "Installing containerd + kubeadm/kubelet/kubectl inside the VM"
multipass exec "${VM_NAME}" -- sudo bash -s < "${SHARED_DIR}/provision-kubeadm.sh"

log "Validating kubeadm"
multipass exec "${VM_NAME}" -- kubeadm version

log "Done"
echo
printf 'Instance: %s\n' "${VM_NAME}"
printf 'Shell:    multipass shell %s\n' "${VM_NAME}"
printf 'Next:     ./bootstrap-cluster.sh\n'
