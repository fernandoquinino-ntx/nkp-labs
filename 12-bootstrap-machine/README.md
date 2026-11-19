# Lab 12 — Ubuntu bootstrap machine and NKP 2.19 install

**Learn:** how to paste a Prism Central cloud-init that builds an Ubuntu jump host, and how to install a
**self-managed NKP 2.19** cluster by either path from `nkp-deployer`.

```mermaid
flowchart LR
  A["cloud-init copies this lab"] --> B["Helm path<br/>scripts/install-nkp.sh"]
  A --> C["CLI path<br/>scripts/create-cluster.sh"]
```

Cloud-init clones this repository and copies **this folder** to `/home/ubuntu/nkp-workspace` on the VM.
Both scripts are in that copy.

## Quick run

Helm path (kind bootstrap, chart, pivot), from `nkp-infra-tf`:

```bash
cd /home/ubuntu/nkp-workspace
cp env.example env
cp values.example.yaml values.local.yaml
./scripts/install-nkp.sh
```

CLI path (`nkp create cluster nutanix --self-managed`), from
`nkp-deployer/install/management-cluster/traditional/nkp-installer.sh`:

```bash
cd /home/ubuntu/nkp-workspace
cp create-cluster.env.example create-cluster.env
./scripts/create-cluster.sh
```

Use one path for a given cluster name.

## Steps

| # | Step | What you do |
|---|---|---|
| 01 | [Image and VM](steps/01-image-and-vm.md) | download the Ubuntu qcow2, size the VM, set the Prism name |
| 02 | [Cloud-init](steps/02-cloud-init.md) | paste `cloud-init.yaml`, set the password and SSH key |
| 03 | [Helm path](steps/03-install-cluster.md) | fill `values.local.yaml` and run `scripts/install-nkp.sh` |
| 04 | [Kommander](steps/04-kommander.md) | turn on `INSTALL_KOMMANDER` and the Docker Hub secret |
| 05 | [`nkp create cluster`](steps/05-create-cluster.md) | fill `create-cluster.env` and run `scripts/create-cluster.sh` |
| 06 | [Air gap and registry](steps/06-airgap-registry.md) | download the offline bundle and run a TLS registry the cluster trusts |

## Files

| File | What |
|---|---|
| `cloud-init.yaml` | Prism guest customization. Grows the disk, installs the toolchain, clones this lab |
| `env.example` | installer knobs (`CLUSTER_NAME`, `EXPECTED`, `INSTALL_KOMMANDER`). Copy to `env` |
| `values.example.yaml` | NKP cluster values. Copy to `values.local.yaml` (gitignored) |
| `scripts/install-nkp.sh` | Helm path: `nkp create bootstrap`, chart, kubeconfig, pivot, optional Kommander |
| `create-cluster.env.example` | CLI path values. Copy to `create-cluster.env` (gitignored) |
| `scripts/create-cluster.sh` | CLI path: `nkp create cluster nutanix --self-managed` |
| `scripts/fetch-airgap-bundle.sh` | download the 2.19 air-gapped bundle (~35 GiB, resumable) |
| `scripts/setup-local-registry.sh` | self-signed CA, registry certificate, `registry:2` on this host |
| `scripts/trust-registry.sh` | Opaque Secret `username` / `password` / `ca.crt` for CAREN |
| `helm-charts/nkp-cluster/` | `NKPCluster` plus Prism secrets |
| `helm-charts/nkp-kommander/` | Kommander installer ConfigMap and the Docker Hub secret |

## Variables (`env`)

| Variable | Meaning | Example |
|---|---|---|
| `CLUSTER_NAME` | management cluster name | `nkp-mgmt` |
| `NAMESPACE` | NKP namespace | `kommander` |
| `EXPECTED` | control-plane replicas + worker replicas | `5` |
| `BOOTSTRAP_TIMEOUT` | `nkp create bootstrap` timeout | `20m` |
| `SKIP_PIVOT` | stop after the kubeconfig | `false` |
| `INSTALL_KOMMANDER` | continue with the Kommander chart | `false` |
| `INSTALL_TIMEOUT` | `nkp install kommander` wait | `1h` |

`values.local.yaml` holds Prism, the node SSH key, CIDRs, VIPs, and the NKP node image name. An empty
`sshPublicKey` stops the script before it creates the kind bootstrap cluster.

## URLs

| What | URL |
|---|---|
| This lab | https://github.com/fernandoquinino-ntx/nkp-labs/tree/main/12-bootstrap-machine |
| Cloud-init (raw, paste into Prism) | https://raw.githubusercontent.com/fernandoquinino-ntx/nkp-labs/main/12-bootstrap-machine/cloud-init.yaml |
| Ubuntu 24.04 amd64 cloud image | https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img |
| NKP 2.19.0 CLI (linux amd64) | https://downloads.d2iq.com/dkp/v2.19.0/nkp_v2.19.0_linux_amd64.tar.gz |
| kubectl v1.36.2 (linux amd64) | https://dl.k8s.io/release/v1.36.2/bin/linux/amd64/kubectl |
| Helm 3 install script | https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 |
| Flux CLI install script | https://fluxcd.io/install.sh |
| k9s v0.51.0 (linux amd64) | https://github.com/derailed/k9s/releases/download/v0.51.0/k9s_Linux_amd64.tar.gz |
| yq v4.47.1 (linux amd64) | https://github.com/mikefarah/yq/releases/download/v4.47.1/yq_linux_amd64 |
| Docker Engine (Ubuntu) | https://download.docker.com/linux/ubuntu |
| NKP 2.19 release note | https://next.nutanix.com/product-updates/nutanix-kubernetes-platform-nkp-2-19-45966 |
| NKP 2.19 air-gapped bundle | https://downloads.d2iq.com/dkp/v2.19.0/nkp-air-gapped-bundle_v2.19.0_linux_amd64.tar.gz |

NKP 2.19 defaults to Kubernetes **1.36.2** (1.35.x is still supported). The public CLI archive is
**linux amd64** only. sha256 of `nkp_v2.19.0_linux_amd64.tar.gz`:
`38c1198a4226cdfb99afe601b1bedfe4459df478c4a4bac59a461c1926032fe4`.

**Next:** [01 — image and VM](steps/01-image-and-vm.md).
