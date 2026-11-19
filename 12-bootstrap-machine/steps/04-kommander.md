# 04 — Kommander

Leave this off for the first cluster bring-up. Turn it on in `env` when the management kubeconfig
already works:

```bash
INSTALL_KOMMANDER=true
```

```bash
./scripts/install-nkp.sh
```

That run:

1. `helm upgrade --install` of `helm-charts/nkp-kommander` (`--wait`).
2. Waits until the `kommander-bootstrap` Job succeeds. The CLI refuses to install while that Job is still running.
3. `nkp install kommander --installer-config kommander.yaml --wait`.
4. If secret `dockerhub-auth` exists, points each Docker Hub `OCIRepository` at it.

`dockerhub-auth` is rendered only when `registry.username` and `registry.password` are set in
`values.local.yaml`. Empty registry credentials leave Flux pulling `docker.io` anonymously, which hits
the Docker Hub rate limit.

Register DNS for `<clusterName>.<clusterDomain>` at the ingress address before Kommander, or Dex fails
with `no such host`.

NKP installs its own Flux (the Kommander git-operator) on the cluster. The Flux CLI on the jump host
is the v2.10.0 binary that cloud-init installs from the flux2 GitHub release.
