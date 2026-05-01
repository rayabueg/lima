#!/usr/bin/env bash
# lima/bootstrap-cluster.sh
#
# Bootstrap a single-node kubeadm cluster inside a Lima VM.
# Delegates the in-VM work to ../shared/bootstrap-cluster.sh.
#
# What it does:
#  - Ensures the Lima VM is running
#  - Runs shared/provision-kubeadm.sh inside the VM (idempotent)
#  - Runs shared/bootstrap-cluster.sh inside the VM (kubeadm + Cilium + ArgoCD)
#  - Exports a kubeconfig to the host rewritten for localhost tunnel access
#
# To use the exported kubeconfig from the host, start an SSH tunnel:
#   ssh -F ~/.lima/<VM_NAME>/ssh.config -N -L 6443:127.0.0.1:6443 lima-<VM_NAME>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED_DIR="${SCRIPT_DIR}/../shared"

VM_NAME="${VM_NAME:-k8s-lab}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
CILIUM_VERSION="${CILIUM_VERSION:-latest}"
INSTALL_ARGOCD="${INSTALL_ARGOCD:-true}"
APISERVER_CERT_EXTRA_SANS="${APISERVER_CERT_EXTRA_SANS:-127.0.0.1,localhost}"

DEFAULT_LOCAL_KUBECONFIG="$HOME/.kube/lima-${VM_NAME}"
LOCAL_KUBECONFIG="${LOCAL_KUBECONFIG:-$DEFAULT_LOCAL_KUBECONFIG}"
KUBECONFIG_SERVER="${KUBECONFIG_SERVER:-https://127.0.0.1:6443}"
START_TIMEOUT="${START_TIMEOUT:-20m}"

log() {
  printf '\n[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }
}

need_cmd limactl
need_cmd python3

log "Ensuring Lima instance is running: ${VM_NAME}"
limactl start -y --timeout="${START_TIMEOUT}" "${VM_NAME}" >/dev/null

log "Provisioning kubeadm prerequisites inside VM"
limactl shell "${VM_NAME}" sudo bash -s < "${SHARED_DIR}/provision-kubeadm.sh"

log "Bootstrapping Kubernetes inside VM (kubeadm + Cilium + ArgoCD)"
limactl shell "${VM_NAME}" \
  env POD_CIDR="${POD_CIDR}" \
      CILIUM_VERSION="${CILIUM_VERSION}" \
      INSTALL_ARGOCD="${INSTALL_ARGOCD}" \
      APISERVER_CERT_EXTRA_SANS="${APISERVER_CERT_EXTRA_SANS}" \
  bash -s < "${SHARED_DIR}/bootstrap-cluster.sh"

log "Exporting kubeconfig to host: ${LOCAL_KUBECONFIG}"
mkdir -p "$(dirname "${LOCAL_KUBECONFIG}")"
limactl shell "${VM_NAME}" bash -lc 'cat "$HOME/.kube/config"' > "${LOCAL_KUBECONFIG}"

python3 - "${LOCAL_KUBECONFIG}" "${KUBECONFIG_SERVER}" <<'PY'
from pathlib import Path
import re, sys
cfg = Path(sys.argv[1])
server = sys.argv[2]
text = cfg.read_text()
text = re.sub(r"server: https://[^\s:]+:6443", f"server: {server}", text)
cfg.write_text(text)
PY

chmod 600 "${LOCAL_KUBECONFIG}"

SSH_CONFIG="$HOME/.lima/${VM_NAME}/ssh.config"
SSH_HOST="lima-${VM_NAME}"
[[ -f "${SSH_CONFIG}" ]] && SSH_HOST="$(awk '$1=="Host" {print $2; exit}' "${SSH_CONFIG}" 2>/dev/null || echo "lima-${VM_NAME}")"

log "Done"
echo
printf 'Host kubeconfig: %s\n' "${LOCAL_KUBECONFIG}"
printf 'Use it:          export KUBECONFIG=%s\n' "${LOCAL_KUBECONFIG}"
echo
echo "Start the API tunnel in another terminal:"
if [[ -f "${SSH_CONFIG}" ]]; then
  echo "  ssh -F \"${SSH_CONFIG}\" -N -L 6443:127.0.0.1:6443 ${SSH_HOST}"
else
  echo "  (SSH config not found at ${SSH_CONFIG} — check: limactl list ${VM_NAME} --format json)"
fi
echo
echo "Then verify:"
echo "  export KUBECONFIG=${LOCAL_KUBECONFIG} && kubectl get nodes"
