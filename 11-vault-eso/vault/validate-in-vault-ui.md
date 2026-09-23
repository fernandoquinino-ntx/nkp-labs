# Validate it yourself (Vault UI + the secret)

Everything below runs **on jump-01** (`10.161.195.110`). `MG="kubectl --kubeconfig ~/dc1-nkp-cl01.conf"`.

## 1. Get a Vault token

```bash
MG="kubectl --kubeconfig ~/dc1-nkp-cl01.conf"
$MG -n vault get secret vault-init -o jsonpath='{.data.root_token}' | base64 -d; echo
# -> hvs.XXXX...   (this is the ROOT token — treat as a secret)
```

## 2. Open the Vault UI

Two ways:

| Way | URL | Notes |
|---|---|---|
| Ingress (recommended) | `https://vault.nkp.ntnxlab.local/ui` | the lab Root CA signs it; your browser may warn unless the CA is trusted |
| Port-forward | `$MG -n vault port-forward svc/vault 8200:8200` then `http://localhost:8200/ui` | no cert warning |

Sign in with **Token** → paste the token from step 1.

## 3. See what secrets you have

In the UI: **Secrets** → the **`secret/`** engine → you'll see `app-credentials`.

From the CLI (no UI):

```bash
T=$($MG -n vault get secret vault-init -o jsonpath='{.data.root_token}' | base64 -d)
V() { $MG -n vault exec vault-0 -- env VAULT_ADDR=https://127.0.0.1:8200 \
        VAULT_SKIP_VERIFY=true VAULT_TOKEN="$T" vault "$@" </dev/null; }

V secrets list          # engines: secret/ (KV v2), pki/, ...
V kv list secret/       # -> app-credentials
```

## 4. "Claim" (read) this secret

```bash
V kv get secret/app-credentials          # prints username + password
V kv get -field=username secret/app-credentials
V kv get -field=password secret/app-credentials
```

Expected (`secret/data/app-credentials`):

```
username    admin
password    SuperSecretPassword123
```

In the UI: **secret → app-credentials →** the values are shown (click the eye to reveal).

## 5. Confirm it reached Kubernetes (the ESO side)

```bash
$MG -n labs get clustersecretstore vault-backend-lab10     # READY True, "store validated"
$MG -n labs get externalsecret lab-app-credentials         # SecretSynced True
$MG -n labs get secret lab-app-credentials -o jsonpath='{.data.password}' | base64 -d; echo
$MG -n labs logs deploy/lab-eso-demo
#   SECRET_USERNAME=admin
#   SECRET_PASSWORD=SuperSecretPassword123
```

## 6. Where the "credential store" is configured (the UI-visible override)

```bash
$MG -n kommander get configmap external-secrets-overrides -o yaml
$MG -n kommander get hr external-secrets -o jsonpath='{.spec.valuesFrom}'; echo
# -> [{"name":"external-secrets-2.3.0-config-defaults"},
#     {"name":"external-secrets-overrides","optional":true}]
```

The Kommander UI exposes this same ConfigMap: **Management Cluster Workspace ▸ Applications ▸
External Secrets Operator ▸ ⋯ ▸ Edit**.

To have the override **referenced in the AppDeployment** (so the UI shows it on that object), set
`spec.configOverrides.name` + `spec.clusterConfigOverrides[].configMapName`:

```bash
$MG -n kommander get appdeployment external-secrets \
  -o jsonpath='configOverrides={.spec.configOverrides}{"\n"}cluster={.spec.clusterConfigOverrides[0].configMapName}{"\n"}'
#   configOverrides={"name":"external-secrets-overrides"}
#   cluster=external-secrets-overrides
```
(An empty `configOverrides` here is normal for a platform-managed app — the CM is still applied via
the HelmRelease `valuesFrom`; see `../steps/05-override-store.md`.)

## Rotate it (see the sync work)

```bash
V kv put secret/app-credentials username=admin password='NEW-VALUE'
$MG -n labs annotate externalsecret lab-app-credentials force-sync="$(date +%s)" --overwrite
$MG -n labs get secret lab-app-credentials -o jsonpath='{.data.password}' | base64 -d; echo   # NEW-VALUE
$MG -n labs exec deploy/lab-eso-demo -- cat /etc/eso/password                                  # NEW-VALUE (file)
$MG -n labs exec deploy/lab-eso-demo -- printenv SECRET_PASSWORD                               # old value (env)
$MG -n labs rollout restart deploy/lab-eso-demo                                               # env refreshes
```

## Remove this validation demo (it lives on the MANAGEMENT cluster)

```bash
$MG -n kommander delete configmap external-secrets-overrides      # ESO release drops the extra objects
$MG delete ns labs
$MG delete clustersecretstore vault-backend-lab10
```
