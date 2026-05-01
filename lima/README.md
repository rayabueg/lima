# Lima (macOS) — k8s-lab bootstrap

Uses **Lima** to run an Ubuntu 24.04 VM on macOS, then provisions kubeadm + a single-node Kubernetes cluster.

> If you are on Ubuntu/Linux, use `../multipass/` instead.

## Prereqs

```bash
brew install lima
```

## Scripts

| Script | Purpose |
|---|---|
| `rebuild-lab.sh` | Delete + re-create the Lima VM and run `shared/provision-kubeadm.sh` |
| `bootstrap-cluster.sh` | Run `kubeadm init` + Cilium + ArgoCD inside the VM, export kubeconfig |
| `../shared/provision-kubeadm.sh` | Installs containerd, kubelet, kubeadm, kubectl (runs inside VM as root) |
| `../shared/bootstrap-cluster.sh` | Guest-side cluster init logic (shared with multipass) |

## Quickstart

```bash
# 1. Create (or rebuild) the VM
./rebuild-lab.sh

# 2. Initialise Kubernetes + Cilium + ArgoCD
./bootstrap-cluster.sh
```

Override defaults via env:

```bash
VM_NAME=k8s-lab CPUS=4 MEMORY=8 DISK=40 ./rebuild-lab.sh
```

## Daily use

```bash
# Start VM
limactl start k8s-lab

# Open SSH tunnel to API server (keep running in a separate terminal)
ssh -F "$HOME/.lima/k8s-lab/ssh.config" -N -L 6443:127.0.0.1:6443 lima-k8s-lab
```

Then use kubectl from your Mac:

```bash
export KUBECONFIG=~/.kube/lima-k8s-lab
kubectl get nodes
```

## ArgoCD admin password

```bash
export KUBECONFIG="$HOME/.kube/lima-k8s-lab"
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 --decode && echo
```

## Apply GitOps root apps (first time)

Update `spec.source.repoURL` in each file if using a fork, then:

```bash
export KUBECONFIG="$HOME/.kube/lima-k8s-lab"
kubectl apply -f ../cluster-addons/bootstrap/argocd/root-app.yaml
kubectl apply -f ../cluster-applications/bootstrap/argocd/root-app.yaml
kubectl -n argocd get applications
```

## Syntax check

```bash
bash -n rebuild-lab.sh bootstrap-cluster.sh \
     ../shared/provision-kubeadm.sh ../shared/bootstrap-cluster.sh
```
