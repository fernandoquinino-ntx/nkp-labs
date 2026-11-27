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

## NKP Pulse Air-Gapped Images & Stuck Hook Jobs

In air-gapped NKP 2.19 environments, the `nkp-pulse-management` Helm hook Jobs
(`nkp-pulse-management-apply-crds` and `nkp-pulse-management-cm-postdelete`) may attempt to pull
`docker.io/mesosphere/kubectl:v1.36.2` and `docker.io/mesosphere/nkp-pulse-management:0.5.1` from
the internet.

A ready-to-use `nkp push bundle`-compatible OCI image bundle (`nkp-pulse-image-bundle-v2.19.1.tar`,
containing `mesosphere/kubectl:v1.36.2`, `mesosphere/nkp-pulse-management:0.5.1`, and
`mesosphere/nkp-pulse-workspace:0.5.1`) is published automatically on the public
[`offline-bundle`](https://github.com/fernandoquinino-ntx/nkp-labs/releases/tag/offline-bundle)
release — or can be built on any internet-connected host with `./scripts/build-pulse-bundle.sh`.

1. **Download on an internet-connected workstation and copy to the bastion:**

   ```bash
   curl -fsSL https://github.com/fernandoquinino-ntx/nkp-labs/releases/download/offline-bundle/nkp-pulse-image-bundle-v2.19.1.tar \
     -o nkp-pulse-image-bundle-v2.19.1.tar
   curl -fsSL https://github.com/fernandoquinino-ntx/nkp-labs/releases/download/offline-bundle/nkp-pulse-image-bundle-v2.19.1.tar.sha256 \
     -o nkp-pulse-image-bundle-v2.19.1.tar.sha256
   scp nkp-pulse-image-bundle-v2.19.1.tar* ubuntu@<bastion-ip>:~/nkp-workspace/airgap/
   ```

2. **Push the bundle with `nkp push bundle` and fix the stuck Job manifests on the bastion:**

   ```bash
   cd /home/ubuntu/nkp-workspace
   # Preview patched Job manifests first (no cluster changes):
   ./scripts/fix-pulse-airgap.sh --dry-run

   # Push bundle to local registry, verify HTTP 200, back up originals, and recreate fixed Jobs:
   ./scripts/fix-pulse-airgap.sh --reconcile
   ```

   Pass `--image-registry <host:port>` if the cluster nodes reach your registry at a different
   hostname/IP than the bastion push URL, or `--image-pull-secret <secret>` if private auth is
   required on the recreated Jobs.

**Next:** [07 — offline bootstrap](07-offline-bootstrap.md).
