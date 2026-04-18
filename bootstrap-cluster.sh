#!/usr/bin/env bash
# Bootstrap a single-node kubeadm cluster inside a Lima VM.
#
# What it does:
#  - Runs kubeadm init (if not already initialized)
#  - Configures kubeconfig for the VM user
#  - Installs Cilium CLI (if missing) + deploys Cilium CNI (idempotent)
#  - Optionally installs Argo CD (server-side apply, idempotent)
#  - Exports a kubeconfig to the host and rewrites the API server to https://127.0.0.1:6443
#
# Note: To use the exported kubeconfig from the host, you must run an SSH tunnel
# from host localhost:6443 -> guest 127.0.0.1:6443 (command printed at the end).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

VM_NAME="${VM_NAME:-k8s-lab}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
CILIUM_VERSION="${CILIUM_VERSION:-latest}"
INSTALL_ARGOCD="${INSTALL_ARGOCD:-true}"

# Ensure the apiserver certificate is valid for localhost access when using the tunnel.
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

log "Bootstrapping Kubernetes inside VM (kubeadm + Cilium + ArgoCD)"
limactl shell "${VM_NAME}" \
  env POD_CIDR="${POD_CIDR}" \
      CILIUM_VERSION="${CILIUM_VERSION}" \
      INSTALL_ARGOCD="${INSTALL_ARGOCD}" \
      APISERVER_CERT_EXTRA_SANS="${APISERVER_CERT_EXTRA_SANS}" \
  bash -s <<'GUEST'
set -euo pipefail

POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
CILIUM_VERSION="${CILIUM_VERSION:-latest}"
INSTALL_ARGOCD="${INSTALL_ARGOCD:-true}"
APISERVER_CERT_EXTRA_SANS="${APISERVER_CERT_EXTRA_SANS:-}"

log() {
  printf '\n[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }
}

log "Validating required binaries"
need_cmd sudo
need_cmd kubeadm
need_cmd kubectl
need_cmd curl
need_cmd tar

if [[ ! -f /etc/kubernetes/admin.conf ]]; then
  log "Initializing Kubernetes control plane"
  KUBEADM_ARGS=(init --pod-network-cidr="${POD_CIDR}")
  if [[ -n "${APISERVER_CERT_EXTRA_SANS}" ]]; then
    KUBEADM_ARGS+=(--apiserver-cert-extra-sans="${APISERVER_CERT_EXTRA_SANS}")
  fi

  sudo kubeadm "${KUBEADM_ARGS[@]}"
else
  log "Kubernetes already initialized; skipping kubeadm init"
fi

log "Configuring kubeconfig for current user"
mkdir -p "$HOME/.kube"
sudo cp -f /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
chmod 600 "$HOME/.kube/config"

log "Allowing workloads on the control-plane node"
kubectl taint nodes --all node-role.kubernetes.io/control-plane- >/dev/null 2>&1 || true

if ! command -v cilium >/dev/null 2>&1; then
  log "Installing Cilium CLI"
  ARCH="$(dpkg --print-architecture)"
  case "$ARCH" in
    arm64) CILIUM_ARCH="arm64" ;;
    amd64) CILIUM_ARCH="amd64" ;;
    *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
  esac

  if [[ "${CILIUM_VERSION}" == "latest" ]]; then
    CILIUM_URL="https://github.com/cilium/cilium-cli/releases/latest/download/cilium-linux-${CILIUM_ARCH}.tar.gz"
  else
    # Expected format: vX.Y.Z (but we don't enforce; user controls the value)
    CILIUM_URL="https://github.com/cilium/cilium-cli/releases/download/${CILIUM_VERSION}/cilium-linux-${CILIUM_ARCH}.tar.gz"
  fi

  curl -fsSL "$CILIUM_URL" -o /tmp/cilium.tar.gz
  tar -xzf /tmp/cilium.tar.gz -C /tmp
  sudo install -m 0755 /tmp/cilium /usr/local/bin/cilium
  rm -f /tmp/cilium /tmp/cilium.tar.gz
fi

log "Installing Cilium CNI"
if kubectl -n kube-system get daemonset cilium >/dev/null 2>&1; then
  log "Cilium already installed; skipping install"
else
  cilium install
fi
cilium status --wait

if [[ "${INSTALL_ARGOCD}" == "true" ]]; then
  log "Installing ArgoCD"
  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply --server-side --force-conflicts -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
  kubectl rollout status deployment/argocd-server -n argocd --timeout=300s

  # Work around occasional CrashLoopBackOff in argocd-repo-server init container (copyutil)
  # when the cmp-server symlink already exists.
  kubectl -n argocd patch deployment argocd-repo-server --type='strategic' \
    -p '{"spec":{"template":{"spec":{"initContainers":[{"name":"copyutil","args":["/bin/cp --update=none /usr/local/bin/argocd /var/run/argocd/argocd && /bin/ln -sf /var/run/argocd/argocd /var/run/argocd/argocd-cmp-server"]}]}}}}' \
    >/dev/null 2>&1 || true
  kubectl -n argocd rollout restart deployment/argocd-repo-server >/dev/null 2>&1 || true
  kubectl -n argocd rollout status deployment/argocd-repo-server --timeout=300s >/dev/null 2>&1 || true

  log "ArgoCD initial admin password"
  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
  echo
fi

log "Cluster status"
kubectl get nodes -o wide
GUEST

log "Exporting kubeconfig to host: ${LOCAL_KUBECONFIG}"
mkdir -p "$(dirname "${LOCAL_KUBECONFIG}")"

# Grab the VM user's kubeconfig and rewrite the server line for localhost.
# NOTE: The host's home directory is mounted into the VM (e.g. /Users/<user> on macOS).
# Avoid expanding $HOME on the host, or we may accidentally export the host kubeconfig.
limactl shell "${VM_NAME}" bash -lc 'cat "$HOME/.kube/config"' > "${LOCAL_KUBECONFIG}"

python3 - "${LOCAL_KUBECONFIG}" "${KUBECONFIG_SERVER}" <<'PY'
from pathlib import Path
import re
import sys

cfg = Path(sys.argv[1])
server = sys.argv[2]

text = cfg.read_text()
text = re.sub(r"server: https://[^\s:]+:6443", f"server: {server}", text)
cfg.write_text(text)
PY

chmod 600 "${LOCAL_KUBECONFIG}"

SSH_CONFIG="$HOME/.lima/${VM_NAME}/ssh.config"
SSH_HOST="lima-${VM_NAME}"
if [[ -f "${SSH_CONFIG}" ]]; then
  SSH_HOST="$(awk '$1=="Host" {print $2; exit}' "${SSH_CONFIG}" 2>/dev/null || echo "lima-${VM_NAME}")"
fi
log "Done"
echo
printf 'Host kubeconfig: %s\n' "${LOCAL_KUBECONFIG}"
printf 'Use it:         export KUBECONFIG=%s\n' "${LOCAL_KUBECONFIG}"

echo
echo "To access the API server from the host, run this SSH tunnel in another terminal:"
if [[ -f "${SSH_CONFIG}" ]]; then
  echo "  ssh -F \"${SSH_CONFIG}\" -N -L 6443:127.0.0.1:6443 ${SSH_HOST}"
else
  echo "  (Expected SSH config not found at ${SSH_CONFIG})"
  echo "  You can find it via: limactl list ${VM_NAME} --format json"
fi

echo
echo "Then verify from the host:"
echo "  kubectl get nodes"
