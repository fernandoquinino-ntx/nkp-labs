# Step 06 — Inspect the store, the ExternalSecret and the resulting Secret

```bash
DS="kubectl --kubeconfig ~/ds-cluster01.conf"

# 1) the credential store: is ESO able to authenticate + read?
$DS get clustersecretstore "${SECRETSTORE_NAME:-vault-backend}" -o wide
$DS get clustersecretstore "${SECRETSTORE_NAME:-vault-backend}" \
    -o jsonpath='{.status.conditions[*].message}{"\n"}'
#   -> "store validated"        (Ready=True)

# 2) the pull request
$DS -n "${NAMESPACE:-labs}" get externalsecret "${EXTERNAL_SECRET_NAME:-lab-app-credentials}" -o wide
#   -> STATUS SecretSynced, READY True, LAST SYNC a moment ago

# 3) the Kubernetes Secret ESO created/owns
$DS -n "${NAMESPACE:-labs}" get secret "${EXTERNAL_SECRET_NAME:-lab-app-credentials}"
$DS -n "${NAMESPACE:-labs}" get secret "${EXTERNAL_SECRET_NAME:-lab-app-credentials}" \
    -o jsonpath='{.data.username}' | base64 -d; echo
$DS -n "${NAMESPACE:-labs}" get secret "${EXTERNAL_SECRET_NAME:-lab-app-credentials}" \
    -o jsonpath='{.data.password}' | base64 -d; echo
#   -> admin / CHANGE-ME   (whatever you seeded in step 03)
```

What each object tells you:

| Field | Meaning |
|---|---|
| `ClusterSecretStore … READY=True` + `"store validated"` | ESO logged in to Vault **and** read the mount — auth + CA + path are all correct |
| `ExternalSecret … STATUS=SecretSynced` | the requested keys exist and the target Secret is up to date |
| `metadata.ownerReferences` on the Secret | the Secret is owned by the ExternalSecret (`creationPolicy: Owner`) |

## Path B — the raw manifests (for comparison)

If you want to see the objects without the AppDeployment override:

```bash
$DS apply -f rendered/10-vault-eso/eso/clustersecretstore.example.yaml   # (rendered)
$DS apply -f rendered/10-vault-eso/eso/externalsecret.example.yaml
```

> Don't do both paths at once (same object names → they fight). Namespace-scoped `SecretStore` instead
> of the cluster-scoped `ClusterSecretStore` is also valid — the cluster-scoped form can be referenced
> from every namespace, which is why the lab uses it.

---

Next: [07 — consume the secret in a pod](07-consume.md)
