# Step 08 — Change it and watch it re-sync

There are **two levels** you can change, and both are worth trying.

## A) Change a Vault VALUE → the Kubernetes Secret re-syncs

```bash
MG="kubectl --kubeconfig ~/dc1-nkp-cl01.conf"
T=$($MG -n vault get secret vault-init -o jsonpath='{.data.root_token}' | base64 -d)
V() { $MG -n vault exec -i vault-0 -- env VAULT_ADDR=https://127.0.0.1:8200 \
        VAULT_SKIP_VERIFY=true VAULT_TOKEN="$T" vault "$@"; }

V kv put secret/app-credentials username=admin password='ROTATED-42'
```

The ExternalSecret reconciles every `refreshInterval` (1h here). To see it now, force a sync:

```bash
DS="kubectl --kubeconfig ~/ds-cluster01.conf"
$DS -n "${NAMESPACE:-labs}" annotate externalsecret "${EXTERNAL_SECRET_NAME:-lab-app-credentials}" \
    force-sync="$(date +%s)" --overwrite
$DS -n "${NAMESPACE:-labs}" get secret "${EXTERNAL_SECRET_NAME:-lab-app-credentials}" \
    -o jsonpath='{.data.password}' | base64 -d; echo     # -> ROTATED-42
```

The **mounted file** updates on its own within ~1 min; the **env var** only changes after a restart:

```bash
$DS -n "${NAMESPACE:-labs}" exec deploy/lab-eso-demo -- cat /etc/eso/password     # new value
$DS -n "${NAMESPACE:-labs}" exec deploy/lab-eso-demo -- printenv SECRET_PASSWORD  # old value
$DS -n "${NAMESPACE:-labs}" rollout restart deploy/lab-eso-demo
$DS -n "${NAMESPACE:-labs}" exec deploy/lab-eso-demo -- printenv SECRET_PASSWORD  # new value
```

## B) Change the STORE in the UI → ESO reconfigures

This is the AppDeployment-override payoff. In the Kommander UI:
**Management Cluster Workspace ▸ Applications ▸ External Secrets Operator ▸ ⋯ ▸ Edit**, and change
e.g. `remoteRef.key` or `refreshInterval` in the `extraObjects` values. Save.

The same edit from the CLI:

```bash
$MG -n "${WORKSPACE_NS:-datascience-xmfnz}" edit configmap "${ESO_OVERRIDES_CM:-external-secrets-overrides}"
```

The Kommander controller re-merges the values → the ESO `HelmRelease` upgrades → the
`ClusterSecretStore`/`ExternalSecret` on `ds-cluster01` change accordingly. Confirm:

```bash
$DS -n "${NAMESPACE:-labs}" get externalsecret -o yaml | sed -n '/spec:/,/status:/p' | head -20
```

> Because the store/secret are **Helm-owned** by the ESO release, a change in the override is a normal
> Helm upgrade — no `kubectl edit` on the CRs (which would drift and be reconciled back).

---

Next: [09 — troubleshooting](09-troubleshooting.md)
