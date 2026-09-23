# Step 04 — Teardown

> ⚠️ Deleting the Vault PVC destroys **all** data (secrets, PKI, auth). Make sure that's what you want.

```bash
NS="${VAULT_NAMESPACE:-vault}"; R="${VAULT_RELEASE:-vault}"

# Helm path (options A/B/C):
helm uninstall "$R" -n "$NS"
kubectl -n "$NS" delete pvc -l app.kubernetes.io/instance="$R"     # removes the data
kubectl delete ns "$NS"                                            # only if the lab created it

# NKP catalog path (option D): remove the app, not Helm
MG="kubectl --kubeconfig ~/dc1-nkp-cl01.conf"
$MG -n kommander delete appdeployment vault
```
Also remove the init secret when you're done (it holds your root token + unseal keys):
`kubectl -n "$NS" delete secret vault-init`.

**Don't forget** to tear down the consumers too (lab 11: `11-vault-eso/scripts/uninstall.sh`).
