# 03 — Helm path

This is one of the two install paths. The other is [`nkp create cluster`](05-create-cluster.md).

On the jump host:

```bash
cd /home/ubuntu/nkp-workspace
cp env.example env
cp values.example.yaml values.local.yaml
```

Edit `values.local.yaml` before you run anything:

| Key | What it must be |
|---|---|
| `prism.endpoint` / `prism.username` / `prism.password` | Prism Central |
| `prism.prismElement` / `prism.subnet` | the PE cluster and the VM subnet, by name |
| `sshPublicKey` | public key installed on the NKP nodes. Empty is rejected |
| `image` | an NKP node image that **already exists in Prism Central** |
| `controlPlaneEndpointIp` | kube-vip address |
| `serviceLoadBalancer.rangeStart` / `rangeEnd` | MetalLB range |
| `kubernetesVersion` / `nkpVersion` | `v1.36.2` / `v2.19.0` unless you are staying on 1.35.x |

`env` sets `CLUSTER_NAME` and `EXPECTED` (control-plane replicas + worker replicas). The chart
defaults are 3 + 2, so `EXPECTED=5`.

```bash
./scripts/install-nkp.sh
```

The script follows the infra-repo order:

1. `nkp create bootstrap` (kind). No Helm `--wait` on this chart. Ready is the machine loop, not the Helm release.
2. `helm upgrade --install` of `helm-charts/nkp-cluster`.
3. Wait until `EXPECTED` CAPI machines are Ready.
4. `nkp get kubeconfig` → `<CLUSTER_NAME>.kubeconfig`.
5. Pivot: `nkp create capi-components`, `nkp move capi-resources`, `nkp delete bootstrap`.

Set `SKIP_PIVOT=true` in `env` to stop after the kubeconfig.

The node image name is checked by NKP against Prism Central. A name that is not an image in PC fails
the `NKPCluster` create. Build or upload that image before this step.

**Next:** [04 — Kommander](04-kommander.md).
