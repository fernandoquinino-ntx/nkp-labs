# Step 02 — Create the Okta OIDC application

`[◀ Step 01](01-prereqs.md)` · `[README](../README.md)` · `[Step 03 ▶](03-enable-traefik-plugin.md)`

## Goal
Register a **Web** application in Okta that Traefik will authenticate against, and collect
its **issuer URL**, **Client ID** and **Client Secret**.

## Why it matters
OIDC is a *contract*: the redirect URI and the issuer must match **exactly** on both sides.
Most "it redirects but fails" problems are a mismatched URI or issuer.

## 1) Create the app
In the Okta Admin Console: **Applications → Applications → Create App Integration**.

| Field | Value |
|---|---|
| Sign-in method | **OIDC — OpenID Connect** |
| Application type | **Web Application** |
| App name | e.g. `traefik-oidc-lab` |

**Sign-in redirect URIs** — one entry, exactly:
```
https://${OIDC_HOST}.${DOMAIN}/oauth2/callback
```
e.g. `https://whoami.apps.example.com/oauth2/callback`

**Sign-out redirect URIs** (optional): `https://${OIDC_HOST}.${DOMAIN}/`

**Grant types**: ✅ Authorization Code, ✅ Refresh Token. (No Implicit, no client credentials.)

**Assignments**: assign the app to the people/groups that should log in.

Save. Copy the **Client ID** and **Client Secret** into `local.env`:
```ini
OKTA_CLIENT_ID=<client id>
OKTA_CLIENT_SECRET=<client secret>
```

## 2) Issuer URL
- **Org Authorization Server** (simplest — right for a single app): `https://<your-org>.okta.com`
  ```ini
  OKTA_ISSUER=https://<your-org>.okta.com
  ```
- **Custom Authorization Server** (if you need it): `https://<your-org>.okta.com/oauth2/<authServerId>`.

Verify discovery works from your laptop **and** from the cluster:
```bash
curl -s "${OKTA_ISSUER}/.well-known/openid-configuration" | head
```

## 3) (Optional) a `groups` claim — only if you will use `allowedRolesAndGroups`
Okta does **not** put groups in the ID token by default. To enable group-based authorization:

1. Okta app → **Sign On** tab → **OpenID Connect ID Token** → **Edit** →
   **Groups claim type: Filter**, **Groups claim name: `groups`**, filter e.g. `Matches regex .*`.
2. Traefik must **request** the `groups` scope — uncomment `scopes: [groups]` in
   `oidc/middleware.yaml` (step 06).
3. Put an allowed group in `local.env`:
   ```ini
   OIDC_ALLOWED_GROUPS=My-App-Users
   ```

## Expected output
`curl .../.well-known/openid-configuration` returns JSON containing `"issuer"`,
`"authorization_endpoint"`, `"token_endpoint"`, `"jwks_uri"`.

## Gotchas
- **Redirect URI must match byte-for-byte** — scheme, host, path. A trailing slash difference
  is the classic failure.
- Use the **same value** for `OKTA_ISSUER` and the token `iss` (no trailing slash).
- Full federation to **AD/LDAP** is an Okta-side concern (Okta → Directory); this lab only
  cares that Okta can authenticate the user.

## ✅ Checkpoint
- [ ] Okta Web app exists with the exact redirect URI.
- [ ] `OKTA_ISSUER`, `OKTA_CLIENT_ID`, `OKTA_CLIENT_SECRET` are in `local.env`.
- [ ] Discovery JSON is reachable.

Next: **[Step 03 — Enable the Traefik plugin ▶](03-enable-traefik-plugin.md)**
