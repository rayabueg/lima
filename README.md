# bootstrap

VM management and cluster bootstrap scripts, organised by VM manager.

Pick the subfolder that matches your workstation OS:

| Folder | VM manager | Host OS |
|---|---|---|
| [`lima/`](lima/) | [Lima](https://lima-vm.io) | macOS |
| [`multipass/`](multipass/) | [Multipass](https://multipass.run) | Ubuntu / Linux (also macOS) |

## Shared scripts

[`shared/`](shared/) contains scripts that run **inside the VM** and are identical regardless of which VM manager you use:

| Script | Purpose |
|---|---|
| `shared/provision-kubeadm.sh` | Install containerd, kubelet, kubeadm, kubectl (run as root in the VM) |
| `shared/bootstrap-cluster.sh` | `kubeadm init` + Cilium CNI + ArgoCD (run as the normal user in the VM) |

These are called automatically by the `rebuild-lab.sh` and `bootstrap-cluster.sh` scripts in each subdirectory — you do not run them directly.

## Quickstart

```bash
# macOS
cd lima && ./rebuild-lab.sh && ./bootstrap-cluster.sh

# Ubuntu / Linux
cd multipass && ./rebuild-lab.sh && ./bootstrap-cluster.sh
```

After bootstrapping, apply the GitOps root apps from the repo root:

```bash
kubectl apply -f cluster-addons/bootstrap/argocd/root-app.yaml
kubectl apply -f cluster-applications/bootstrap/argocd/root-app.yaml
```

See each subfolder's README for full details (daily use, SSH tunnels, port-forwards, ArgoCD password, etc.).
