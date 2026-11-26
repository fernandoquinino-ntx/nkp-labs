# Security Policy

## Public Repository Secret Hygiene

This repository is **public**. Never commit customer-specific or environment-specific secrets, including:

- Prism Central / Kubernetes / Vault / Splunk / Okta passwords, tokens, or API keys
- Rendered manifests (`rendered/`) or local override files (`local.env`, `12-bootstrap-machine/env`, `12-bootstrap-machine/values.local.yaml`, `12-bootstrap-machine/create-cluster.env`)
- Private TLS keys, kubeconfigs, SSH private keys, or internal client IPs / hostnames

All template examples (`*.example*`) must contain only non-sensitive placeholder values. Every push and pull request runs automated secret scanning via **gitleaks** in [`.github/workflows/ci.yml`](.github/workflows/ci.yml).

## Release & Auto-Update Integrity

- Every asset published under the [`offline-bundle`](https://github.com/fernandoquinino-ntx/nkp-labs/releases/tag/offline-bundle) release ships with a matching `.sha256` file and is indexed in `MANIFEST.json`.
- Both [`create-prism-role.ps1`](12-bootstrap-machine/scripts/create-prism-role.ps1) (`-SelfUpdate`) and [`create-prism-role.py`](12-bootstrap-machine/scripts/create-prism-role.py) (`--self-update`) verify the downloaded SHA-256 digest and validate syntax before replacing the local script (saving a `.bak` copy first).
- [`update-bastion.sh`](12-bootstrap-machine/scripts/update-bastion.sh) and [`update-bastion.ps1`](12-bootstrap-machine/scripts/update-bastion.ps1) verify the `nkp-labs-update.tar.gz.sha256` checksum before transferring to an air-gapped bastion, and preserve all local `.env`, `values.local.yaml`, kubeconfigs, TLS certs, and air-gapped bundles.
- [`create-prism-role.ps1`](12-bootstrap-machine/scripts/create-prism-role.ps1) and [`create-prism-role.py`](12-bootstrap-machine/scripts/create-prism-role.py) never print or persist Prism Central admin or NKP user passwords.

## Reporting a Vulnerability or Accidental Secret Exposure

If you discover a security issue or accidental credential exposure in this repository:

1. **Rotate/revoke the credential immediately** if any real secret was ever committed.
2. Open a GitHub Security Advisory (or contact the repository maintainer privately) rather than posting sensitive details in a public issue.
