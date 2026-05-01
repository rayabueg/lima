# Multipass (Ubuntu/Linux) — k8s-lab bootstrap

Uses **Multipass** to run an Ubuntu 24.04 VM on Ubuntu/Linux (or macOS), then provisions kubeadm + a single-node Kubernetes cluster.

> If you are on macOS and prefer Lima, use `../lima/` instead.

## Prereqs

Install Multipass:

```bash
# Ubuntu/Debian
sudo snap install multipass

# macOS (alternative to Lima)
brew install multipass
```

## Scripts

| Script | Purpose |
|---|---|
| `rebuild-lab.sh` | Delete + re-create the Multipass VM and run `shared/provision-kubeadm.sh` |
| `bootstrap-cluster.sh` | Run `kubeadm init` + Cilium + ArgoCD inside the VM, export kubeconfig |
| `../shared/provision-kubeadm.sh` | Installs containerd, kubelet, kubeadm, kubectl (runs inside VM as root) |
| `../shared/bootstrap-cluster.sh` | Guest-side cluster init logic (shared with lima) |

## Quickstart

```bash
# 1. Create (or rebuild) the VM
./rebuild-lab.sh

# 2. Initialise Kubernetes + Cilium + ArgoCD
./bootstrap-cluster.sh
```

Override defaults via env:

```bash
VM_NAME=k8s-lab CPUS=4 MEMORY=8G DISK=40G ./rebuild-lab.sh
```

## Daily use

```bash
# Start VM (if stopped)
multipass start k8s-lab

# Get the VM's IP
VM_IP=$(multipass info k8s-lab --format json | python3 -c \
  "import json,sys; print(json.load(sys.stdin)['info']['k8s-lab']['ipv4'][0])")

# Open SSH tunnel to API server (keep running in a separate terminal)
ssh -N -L 6443:127.0.0.1:6443 ubuntu@$VM_IP
```

Then use kubectl:

```bash
export KUBECONFIG=~/.kube/multipass-k8s-lab
kubectl get nodes
```

## ArgoCD admin password

```bash
export KUBECONFIG="$HOME/.kube/multipass-k8s-lab"
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 --decode && echo
```

## Apply GitOps root apps (first time)

Update `spec.source.repoURL` in each file if using a fork, then:

```bash
export KUBECONFIG="$HOME/.kube/multipass-k8s-lab"
kubectl apply -f ../cluster-addons/bootstrap/argocd/root-app.yaml
kubectl apply -f ../cluster-applications/bootstrap/argocd/root-app.yaml
kubectl -n argocd get applications
```

## Syntax check

```bash
bash -n rebuild-lab.sh bootstrap-cluster.sh \
     ../shared/provision-kubeadm.sh ../shared/bootstrap-cluster.sh
```
