# Step 01 — Install Vault

Pick one option. For all of them: `NS="${VAULT_NAMESPACE:-vault}"`, `R="${VAULT_RELEASE:-vault}"`.

## Option A — dev mode (quickest, throwaway)

Auto-initialized + unsealed, **in-memory** (no persistence), root token = `root`.

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com && helm repo update
helm install "$R" hashicorp/vault -n "$NS" --create-namespace \
  --set "server.dev.enabled=true"
kubectl -n "$NS" get pod "$R-0"
kubectl -n "$NS" port-forward "svc/$R" 8200:8200    # http://localhost:8200/ui , token = root
```
> Great for a 5-minute look. **Do not** use it for lab 11 (no persistence, no TLS).

## Option B — standalone (simplest *real* install) ⭐

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com && helm repo update
# render values.example.yaml with your local.env first, or write values.yaml by hand:
helm install "$R" hashicorp/vault -n "$NS" --create-namespace -f values.yaml
kubectl -n "$NS" get pod "$R-0" -w        # wait for Running (NOT Ready — it is Sealed until step 02)
```
Helper (renders `values.example.yaml` and runs the install):
```bash
./10-vault-install/scripts/install-vault.sh            # dry-run
./10-vault-install/scripts/install-vault.sh --apply
```

## Option C — HA (Raft, 3 replicas)

```bash
helm install "$R" hashicorp/vault -n "$NS" --create-namespace \
  --set server.ha.enabled=true --set server.ha.raft.enabled=true --set server.ha.replicas=3 \
  --set server.dataStorage.size=10Gi --set ui.enabled=true
kubectl -n "$NS" get pods -l app.kubernetes.io/name=vault     # vault-0, vault-1, vault-2
```
Unseal **each** pod in step 02.

## Option D — NKP catalog app

This lab environment already runs Vault as the NKP catalog app (the same `AppDeployment` model as ESO):

```bash
MG="kubectl --kubeconfig ~/dc1-nkp-cl01.conf"
$MG get app | grep -i vault                       # -> App/vault-0.34.1
$MG -n kommander get appdeployment vault -o yaml  # the AppDeployment (kind: App, name: vault-<ver>)
$MG -n kommander get cm vault-config-defaults -o jsonpath='{.data.values\.yaml}' | head -40
```
The starting values live in `ConfigMap/vault-config-defaults` (server.standalone|ha, dataStorage,
ui, ingress, injector). In the UI: **Management Cluster Workspace ▸ Applications ▸ Vault**.

**Verify:** the Vault pod is `Running` (it will show `0/1` — it's *sealed* until step 02).

Next: [02 — initialize + unseal](02-init-unseal.md)
