# Step 01 — Prerequisites

## You need two `kubectl` contexts

All commands in this lab run **on jump-01** (`10.161.195.110`), which holds both kubeconfigs:

| Purpose | Kubeconfig | Cluster |
|---|---|---|
| Vault lives here (management) | `~/dc1-nkp-cl01.conf` | `dc1-nkp-cl01` |
| ESO + the store + your app (workload) | `~/ds-cluster01.conf` | `ds-cluster01` |

Handy aliases:

```bash
MG="kubectl --kubeconfig ~/dc1-nkp-cl01.conf"     # management
DS="kubectl --kubeconfig ~/ds-cluster01.conf"     # workload
```

## Confirm the pieces exist

```bash
# 1) Vault is up and unsealed
$MG -n vault get pod vault-0
#   -> vault-0   1/1   Running

# 2) the ESO platform app is available (a ClusterApp), note the exact name/version
$MG get clusterapp | grep external-secrets
#   -> external-secrets-2.3.0   external-secrets   2.3.0   management

# 3) the workload's WORKSPACE namespace (holds the AppDeployment + override ConfigMap)
$MG get workspaces
#   -> datascience   ...   datascience-xmfnz

# 4) is ESO ALREADY enabled on the workload cluster? (probably not — that's step 04)
$DS get ns external-secrets 2>/dev/null || echo "ESO not enabled on the workload yet"
```

## Vault is reachable from the workload cluster

```bash
$DS run -it --rm net --image=busybox:1.36 --restart=Never -- \
  wget -qO- --no-check-certificate https://vault.nkp.ntnxlab.local/v1/sys/health
#   -> JSON with "initialized":true, "sealed":false
```

If DNS/egress is the problem, check the Traefik LB IP for `vault.nkp.ntnxlab.local`
(`kubectl -n kommander get svc kommander-traefik`).

## Fill `local.env`

Copy the example and set the Lab 11 block (see the README variables table). Then populate the CA
bundle automatically:

```bash
./11-vault-eso/scripts/fetch-vault-ca.sh
# writes VAULT_CA_BUNDLE=<base64 of the Root CA> into local.env (or prints it)
```

**Verify:** `grep '^VAULT_CA_BUNDLE=' local.env` shows a long base64 string.

---

Next: [02 — teach Vault to trust ds-cluster01](02-vault-remote-auth.md)
