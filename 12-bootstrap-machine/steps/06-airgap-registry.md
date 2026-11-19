# 06 — Air-gapped bundle and a local registry

When the toolchain is complete, `nkp-bootstrap.service` starts `nkp-airgap-download.service`. The
bundle does not fit on a 40 GiB disk. Give the VM about **200 GiB**.

The download resumes from the last byte. Within one run curl tries up to 30 times, backing off from
30 s to 10 min. A transfer slower than 10 KiB/s for 5 min is dropped and retried. If a run fails,
systemd starts it again after 5 min, and again after each VM restart. A finished file must match the
server's Content-Length, then the script writes
`airgap/nkp-air-gapped-bundle_v2.19.1_linux_amd64.tar.gz.complete` and later runs exit at once.
Set `AIRGAP_SHA256` to also check a checksum.

| Exit | Meaning | systemd |
|---|---|---|
| 0 | complete | stops |
| 1 | network, server, or short file | retries in 5 min |
| 3 | disk too small or checksum mismatch | stops. Fix it, then `sudo systemctl start nkp-airgap-download` |

```bash
nkp-bootstrap-status
journalctl -u nkp-airgap-download -f
grep '\[airgap\]' /var/log/nkp-bootstrap.log
```

Set `NKP_SKIP_AIRGAP=true` in `/etc/default/nkp-bootstrap` (top of `cloud-init.yaml`) only when you
will copy the tarball onto the VM yourself.

`registry:2` is pulled during the bootstrap, so `setup-local-registry.sh` works after the host loses
internet.

## Bundle

| | |
|---|---|
| URL | https://downloads.d2iq.com/dkp/v2.19.1/nkp-air-gapped-bundle_v2.19.1_linux_amd64.tar.gz |
| Size | 35856981169 bytes (~33 GiB) |
| Published | 2026-11-06 |

```bash
cd /home/ubuntu/nkp-workspace
./scripts/fetch-airgap-bundle.sh
tar -xzf airgap/nkp-air-gapped-bundle_v2.19.1_linux_amd64.tar.gz -C airgap
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

`REGISTRY_IP` defaults to the first address of `hostname -I`. It goes into the certificate SAN.
As root, the script copies the CA to `/etc/docker/certs.d/<host>:<port>/ca.crt` and adds
`REGISTRY_IP registry.nkp.local` to `/etc/hosts` when the name does not resolve. Add the same record
to a resolver the cluster nodes use.

Run it again at any time. It keeps the CA, the certificate, and the password in
`registry/credentials.env`, so the Secret already in the cluster stays valid.

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
