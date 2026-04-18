# Lima-based Ubuntu 24.04 + kubeadm VM

This folder is an alternative to the `multipass/` flow. It uses **Lima** to run an **Ubuntu 24.04** VM and installs **containerd + kubelet/kubeadm/kubectl** so the VM can run `kubeadm`.

## Prereqs

Install Lima:

```bash
brew install lima
```

## Create (or rebuild) the VM

From the repo root:

```bash
chmod +x rebuild-lab.sh
./rebuild-lab.sh
```

## Bootstrap the cluster (kubeadm + Cilium + ArgoCD)

This initializes the control-plane, installs Cilium CNI, optionally installs ArgoCD, and exports a host kubeconfig.

```bash
chmod +x bootstrap-cluster.sh
./bootstrap-cluster.sh
```

Defaults (override via env vars):

- `VM_NAME` (default: `k8s-lab`)
- `CPUS` (default: `6`)
- `MEMORY` in GiB (default: `10`)
- `DISK` in GiB (default: `60`)
- `TEMPLATE` (default: `template:ubuntu-24.04`)

Example:

```bash
VM_NAME=k8s-lab CPUS=4 MEMORY=8 DISK=40 ./rebuild-lab.sh
```

## Validate kubeadm inside the VM

```bash
limactl shell k8s-lab kubeadm version
```

## Host kubectl (after bootstrap)

The bootstrap script writes a kubeconfig to `~/.kube/lima-k8s-lab` that expects the API server at `https://127.0.0.1:6443`.

Start the tunnel in another terminal:

```bash
ssh -F "$HOME/.lima/k8s-lab/ssh.config" -N -L 6443:127.0.0.1:6443 lima-k8s-lab
```

Then use kubectl:

```bash
export KUBECONFIG=~/.kube/lima-k8s-lab
kubectl get nodes
```

## Startup procedure (daily use)

1. Ensure the VM is running:

```bash
limactl start k8s-lab
```

2. Start (or keep running) the API tunnel in a separate terminal:

```bash
ssh -F "$HOME/.lima/k8s-lab/ssh.config" -N -L 6443:127.0.0.1:6443 lima-k8s-lab
```

3. In another terminal, use `kubectl` from your Mac:

```bash
export KUBECONFIG="$HOME/.kube/lima-k8s-lab"
kubectl get nodes
```

4. (Optional) Port-forward the Argo CD UI in another terminal:

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

Then open `https://localhost:8080`.

### Argo CD admin login

Username is `admin`.

To print the initial admin password:

```bash
export KUBECONFIG="$HOME/.kube/lima-k8s-lab"
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 --decode

echo
```

If that secret doesn’t exist, the initial password has likely been rotated/removed after first login. In that case, you’ll need to reset the admin password (or use whatever password you previously set).

Stop the tunnel / port-forward with Ctrl-C.

## Using this with the GitOps repo (Argo CD)

This `lima/` folder is meant to be shared as a **bootstrap repo** (VM + kubeadm + CNI + Argo CD).
Your GitOps state (Argo CD `Application`s, addons, gateway resources, etc.) should stay in a **separate repo** (like `gitops-lab`).

Typical flow:

1. Bootstrap the cluster + Argo CD:

```bash
./bootstrap-cluster.sh
```

2. Clone your GitOps repo (example):

```bash
git clone https://github.com/<you>/gitops-lab.git
cd gitops-lab
```

3. Point Argo CD at that repo by setting `spec.source.repoURL` in `bootstrap/argocd/root-app.yaml`, then apply it:

```bash
export KUBECONFIG="$HOME/.kube/lima-k8s-lab"
kubectl apply -f bootstrap/argocd/root-app.yaml
kubectl -n argocd get applications
```
