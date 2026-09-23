# Step 09 — Troubleshooting

Always start with the store/ExternalSecret **status messages** and the ESO controller logs:

```bash
DS="kubectl --kubeconfig ~/ds-cluster01.conf"
$DS get clustersecretstore "${SECRETSTORE_NAME:-vault-backend}" -o jsonpath='{.status.conditions[*]}{"\n"}'
$DS -n "${NAMESPACE:-labs}" get externalsecret "${EXTERNAL_SECRET_NAME:-lab-app-credentials}" \
    -o jsonpath='{.status.conditions[*]}{"\n"}'
$DS -n external-secrets logs deploy/external-secrets --tail=100 | grep -iE 'error|vault|secretstore'
```

| Symptom | Likely cause | Fix |
|---|---|---|
| Store `Ready=False` → `cannot validate... x509: certificate signed by unknown authority` | `caBundle` is missing/wrong | `scripts/fetch-vault-ca.sh` to set `VAULT_CA_BUNDLE` to the **Root CA** that signed `vault.nkp.ntnxlab.local` (base64 PEM). |
| Store `Ready=False` → `permission denied` / `login failed` / `invalid audience` / `unauthorized` | the workload SA token is not accepted by Vault | You hit the **mgmt-bound** mount. Use the ds-cluster01-bound `VAULT_AUTH_MOUNT` (`kubernetes-ds-cluster01`) + role `eso` (step 02). |
| Store `Ready=False` → `service account ... not found` / TokenReview `403` | wrong SA name/namespace, or the reviewer lacks RBAC | `eso-vault` must exist in `external-secrets` **on the workload**; `vault-auth` needs `system:auth-delegator`. |
| Store `Ready=True` but ExternalSecret `SecretSynced=False` → `could not get secret data ... 404` | **KV path shape** | `provider.path` = the **mount** (`secret`) and `remoteRef.key` = the **item** (`app-credentials`). Do not write `key: secret/app-credentials`. |
| ExternalSecret `SecretSynced=False` → `permission denied` on the path | the policy doesn't cover the path | role `eso` must map to a policy allowing `secret/*` read/list. |
| Store never appears | the override isn't reaching the app | check `AppDeployment.spec.configOverrides.name` **and** `clusterConfigOverrides[].configMapName` = `${ESO_OVERRIDES_CM}`, and that the CM is in the **workspace** ns. |
| Override edit "does nothing" | a per-cluster override shadows the workspace one (or vice-versa) | point **both** fields at the same ConfigMap (as `velero` does). |
| `extraObjects` not rendered | the ESO chart value name/version differs | `$DS -n external-secrets get hr -o yaml \| grep -i extraObjects`; the chart is upstream `external-secrets@<ver>` and supports it. |
| Demo pod `CreateContainerConfigError` | the Secret isn't synced yet | wait for `ExternalSecret READY=True`; the pod should be a Deployment so it retries. |
| Workload cluster can't reach Vault | DNS / egress / LB | `$DS run --rm -it --image=busybox:1.36 -- wget -qO- --no-check-certificate https://vault.nkp.ntnxlab.local/v1/sys/health`; check the Traefik LB IP. |

## Useful one-liners

```bash
# Is Vault reachable at all from the workload?
$DS run --rm -it --image=busybox:1.36 --restart=Never -- \
  wget -qO- --no-check-certificate "${VAULT_SERVER:-https://vault.nkp.ntnxlab.local}/v1/sys/health"

# Is ESO even running on the workload?
$DS -n external-secrets get deploy

# The store's effective spec (what the override rendered)
$DS get clustersecretstore "${SECRETSTORE_NAME:-vault-backend}" -o yaml | sed -n '/spec:/,/status:/p'

# Vault: does the ds-cluster01 mount think it works?
$MG -n vault exec -i vault-0 -- env VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true \
  VAULT_TOKEN="$T" vault read auth/kubernetes-ds-cluster01/config
```

---

Next: [10 — cleanup](10-cleanup.md)
