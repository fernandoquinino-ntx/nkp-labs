# 05 — `nkp create cluster` (the other path)

`scripts/install-nkp.sh` is the Helm path: kind bootstrap, then the `nkp-cluster` chart, then the pivot.

This step is the traditional path from
`nkp-deployer/install/management-cluster/traditional/nkp-installer.sh`. One command creates the
self-managed cluster. NKP builds the kind bootstrap, the `NKPCluster`, and the pivot itself.

```bash
cd /home/ubuntu/nkp-workspace
cp create-cluster.env.example create-cluster.env
# Prism password, PE name, subnet, image name, VIP, SSH public key file
./scripts/create-cluster.sh
```

Preview the manifest without creating VMs:

```bash
DRY_RUN=true ./scripts/create-cluster.sh
```

The script exports `NUTANIX_USER` and `NUTANIX_PASSWORD`, then runs:

```text
nkp create cluster nutanix \
  --cluster-name ... --endpoint https://<pc>:9440 --insecure \
  --self-managed --verbose 10 \
  --control-plane-* --worker-* \
  --csi-storage-container ... \
  --ssh-public-key-file ... --ssh-username konvoy
```

Memory and disk flags are the numbers the installer uses (`16`, `80`), not `16Gi`.
`--cluster-hostname` is added when `CLUSTER_HOSTNAME` is set.
`--bootstrap-cluster-image` is added when `BOOTSTRAP_CLUSTER_IMAGE_PATH` points at a kind image tarball.

Use one path for a cluster. Do not run `install-nkp.sh` and `create-cluster.sh` against the same name.

**Back:** [03 — Helm path](03-install-cluster.md).
