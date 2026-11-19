# 06 — Air-gapped bundle and a local registry

Cloud-init installs the CLIs while the jump host can still reach the internet. Download the offline
bundle **after** that, before you remove the route. The bundle does not fit on a 40 GiB disk. Give
the VM about **200 GiB** if the tarball stays on the bastion.

## Bundle

| | |
|---|---|
| URL | https://downloads.d2iq.com/dkp/v2.19.0/nkp-air-gapped-bundle_v2.19.0_linux_amd64.tar.gz |
| Size | 37171316708 bytes (~35 GiB) |
| Published | 2026-10-16 |

```bash
cd /home/ubuntu/nkp-workspace
./scripts/fetch-airgap-bundle.sh
tar -xzf airgap/nkp-air-gapped-bundle_v2.19.0_linux_amd64.tar.gz -C airgap
```

`nkp create image` does not use the CLI tarball for OS packages. Point it at the extracted
`image-artifacts` directory (`--artifacts-directory`), the same recipe as
`nkp-deployer/plans/nkp-lab-runbook.md`. `packages.d2iq.com` returns 403 without that bundle.

Push a bundle into the local registry (after step “Registry” below). The deployer module is
`nkp push bundle --bundle <tar> --to-registry <url>`. Do not pass `--to-registry-insecure-skip-tls-verify`
once this host trusts the CA.

## Registry on the bastion

```bash
export REGISTRY_HOST=registry.nkp.local
export REGISTRY_IP=<this-vm-ip>
./scripts/setup-local-registry.sh
```

The script writes:

| Path | What |
|---|---|
| `registry/certs/ca.crt` | self-signed CA |
| `registry/certs/registry.crt` | server certificate signed by that CA |
| `registry/credentials.env` | user, password, URL (mode 600) |
| `registry/docker-certs.d/<host>:<port>/ca.crt` | file Docker on this host should trust |

Add `REGISTRY_IP registry.nkp.local` to `/etc/hosts` on the bastion and on a resolver the cluster nodes use.
As root, the script also copies the CA to `/etc/docker/certs.d/<host>:<port>/ca.crt`.

## Trust on the NKP cluster

CAREN reads an **Opaque** Secret (`username`, `password`, `ca.crt`) and writes the CA into
`/etc/containerd/certs.d` on the nodes. A `docker-registry` Secret does not do that.

```bash
export KUBECONFIG=/home/ubuntu/nkp-workspace/<cluster>.kubeconfig
export CLUSTER_NAMESPACE=kommander
./scripts/trust-registry.sh
```

Then set `clusterConfig.imageRegistries` and `globalImageRegistryMirror` to
`https://registry.nkp.local:5000` with `secretRef: nkp-registry-credentials`. The script prints that
fragment. Applying it rolls nodes. This is the same shape as
`nkp-deployer/configure/registry/runbooks/01-registry-not-set.md`.

**Back:** [05 — nkp create cluster](05-create-cluster.md).
