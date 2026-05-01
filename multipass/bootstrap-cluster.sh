#!/usr/bin/env bash
# multipass/bootstrap-cluster.sh
#
# Bootstrap a single-node kubeadm cluster inside a Multipass VM.
# Delegates the in-VM work to ../shared/bootstrap-cluster.sh.
#
# What it does:
#  - Ensures the Multipass VM is running
#  - Runs shared/bootstrap-cluster.sh inside the VM (kubeadm + Cilium + ArgoCD)
#  - Exports a kubeconfig to the host rewritten for localhost tunnel access
#
# To use the exported kubeconfig from the host, start an SSH tunnel:
#   ssh -N -L 6443:127.0.0.1:6443 ubuntu@<VM_IP>
# (VM IP is printed at the end; default SSH key is ~/.ssh/id_rsa)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED_DIR="${SCRIPT_DIR}/../shared"

VM_NAME="${VM_NAME:-k8s-lab}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
CILIUM_VERSION="${CILIUM_VERSION:-latest}"
INSTALL_ARGOCD="${INSTALL_ARGOCD:-true}"
APISERVER_CERT_EXTRA_SANS="${APISERVER_CERT_EXTRA_SANS:-127.0.0.1,localhost}"

DEFAULT_LOCAL_KUBECONFIG="$HOME/.kube/multipass-${VM_NAME}"
LOCAL_KUBECONFIG="${LOCAL_KUBECONFIG:-$DEFAULT_LOCAL_KUBECONFIG}"
KUBECONFIG_SERVER="${KUBECONFIG_SERVER:-https://127.0.0.1:6443}"

log() {
  printf '\n[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }
}

need_cmd multipass
need_cmd python3

log "Ensuring Multipass instance is running: ${VM_NAME}"
multipass start "${VM_NAME}" >/dev/null 2>&1 || true
multipass info "${VM_NAME}" >/dev/null

log "Bootstrapping Kubernetes inside VM (kubeadm + Cilium + ArgoCD)"
multipass exec "${VM_NAME}" -- \
  env POD_CIDR="${POD_CIDR}" \
      CILIUM_VERSION="${CILIUM_VERSION}" \
      INSTALL_ARGOCD="${INSTALL_ARGOCD}" \
      APISERVER_CERT_EXTRA_SANS="${APISERVER_CERT_EXTRA_SANS}" \
  bash -s < "${SHARED_DIR}/bootstrap-cluster.sh"

log "Exporting kubeconfig to host: ${LOCAL_KUBECONFIG}"
mkdir -p "$(dirname "${LOCAL_KUBECONFIG}")"
multipass exec "${VM_NAME}" -- bash -lc 'cat "$HOME/.kube/config"' > "${LOCAL_KUBECONFIG}"

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

# Resolve the VM's IPv4 address for the SSH tunnel command.
VM_IP="$(multipass info "${VM_NAME}" --format json 2>/dev/null \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['info']['${VM_NAME}']['ipv4'][0])" 2>/dev/null \
  || echo "<VM_IP>")"

log "Done"
echo
printf 'Host kubeconfig: %s\n' "${LOCAL_KUBECONFIG}"
printf 'Use it:          export KUBECONFIG=%s\n' "${LOCAL_KUBECONFIG}"
echo
echo "Start the API tunnel in another terminal:"
echo "  ssh -N -L 6443:127.0.0.1:6443 ubuntu@${VM_IP}"
echo
echo "Then verify:"
echo "  export KUBECONFIG=${LOCAL_KUBECONFIG} && kubectl get nodes"
