#!/usr/bin/env bash
# shared/bootstrap-cluster.sh
#
# Bootstrap a single-node kubeadm cluster INSIDE a VM.
# Called by the VM-manager-specific bootstrap script via:
#
#   vm_exec bash -s < shared/bootstrap-cluster.sh
#
# The caller must set these env vars before invoking:
#   POD_CIDR              (default: 10.244.0.0/16)
#   CILIUM_VERSION        (default: latest)
#   INSTALL_ARGOCD        (default: true)
#   APISERVER_CERT_EXTRA_SANS (default: 127.0.0.1,localhost)
#
# This script runs entirely inside the Ubuntu VM guest.
set -euo pipefail

POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
CILIUM_VERSION="${CILIUM_VERSION:-latest}"
INSTALL_ARGOCD="${INSTALL_ARGOCD:-true}"
APISERVER_CERT_EXTRA_SANS="${APISERVER_CERT_EXTRA_SANS:-127.0.0.1,localhost}"

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
    CILIUM_URL="https://github.com/cilium/cilium-cli/releases/download/${CILIUM_VERSION}/cilium-linux-${CILIUM_ARCH}.tar.gz"
  fi

  curl -fsSL "$CILIUM_URL" -o /tmp/cilium.tar.gz
  tar -xzf /tmp/cilium.tar.gz -C /tmp
  sudo install -m 0755 /tmp/cilium /usr/local/bin/cilium
  rm -f /tmp/cilium /tmp/cilium.tar.gz
fi

log "Installing Cilium CNI"
if kubectl -n kube-system get daemonset cilium >/dev/null 2>&1; then
  log "Cilium already installed; ensuring cni-exclusive=false"
  if [[ "$(kubectl get configmap cilium-config -n kube-system -o jsonpath='{.data.cni-exclusive}' 2>/dev/null)" != "false" ]]; then
    kubectl patch configmap cilium-config -n kube-system --type merge -p '{"data":{"cni-exclusive":"false"}}'
    kubectl rollout restart daemonset/cilium -n kube-system
    kubectl rollout status daemonset/cilium -n kube-system --timeout=120s
  fi
else
  cilium install --set cni.exclusive=false
fi
cilium status --wait

if [[ "${INSTALL_ARGOCD}" == "true" ]]; then
  log "Installing ArgoCD"
  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply --server-side --force-conflicts -n argocd \
    -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
  kubectl rollout status deployment/argocd-server -n argocd --timeout=300s

  # Work around occasional CrashLoopBackOff in argocd-repo-server init container (copyutil)
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
