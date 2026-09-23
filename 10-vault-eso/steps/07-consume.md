# Step 07 — Consume the synced Secret in a pod

The whole point of ESO is that your app just consumes a **normal Kubernetes Secret** — it never talks
to Vault.

The demo Deployment (rendered by the override, or the raw `app/deployment.yaml`) reads the Secret two
ways:

- **environment variables** (`secretKeyRef`) — resolved once, at container start; and
- a **mounted file** (`secret` volume) — updated in place when the Secret changes (projected volumes).

```bash
DS="kubectl --kubeconfig ~/ds-cluster01.conf"
NS="${NAMESPACE:-labs}"

$DS -n "$NS" get deploy,pods -l app=lab-eso-demo
$DS -n "$NS" logs deploy/lab-eso-demo
```

Expected:

```
== from ENV ==
SECRET_USERNAME=admin
SECRET_PASSWORD=CHANGE-ME
== from FILE /etc/eso ==
/etc/eso/password = CHANGE-ME
/etc/eso/username = admin
```

Prove it inside the pod:

```bash
$DS -n "$NS" exec deploy/lab-eso-demo -- sh -c 'echo "$SECRET_USERNAME / $SECRET_PASSWORD"; cat /etc/eso/username'
```

> **Rotation caveat (important):** a **mounted file** reflects a Secret update within ~a minute, but an
> **env var** does **not** — the kubelet only (re)reads `secretKeyRef` env at container start. Apps that
> must pick up rotations should read the mounted file, or be restarted. Step 08 shows both.

---

Next: [08 — change it and re-sync](08-rotate.md)
