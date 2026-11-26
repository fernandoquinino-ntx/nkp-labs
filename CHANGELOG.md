# Changelog

All notable changes to `nkp-labs` are documented in this file.

## Unreleased

### Added
- **CI quality & test pipeline** (`.github/workflows/ci.yml`): ShellCheck, PowerShell AST + PSScriptAnalyzer, 7-scenario HTTPS mock test suite (`12-bootstrap-machine/tests/test_prism_role.py`), repo hygiene & render/Helm validation (`12-bootstrap-machine/tests/test_repo_hygiene.py`), and `gitleaks` secret scanning.
- **Single source of truth for Lab 12 versions** (`12-bootstrap-machine/versions.env`), sourced automatically by `bootstrap-host.sh` and verified by CI.
- **Auto-Update v2**:
  - `nkp-update` (`update-workspace.sh`): `--status`, `--check`, `--from-tarball <tar.gz>`, `--rollback`, `.nkp-labs-version` tracking, rollback backup (`/var/backups/nkp-workspace/prev`), and `chmod +x` on both `*.sh` and `*.py`.
  - `update-bastion.sh` & `update-bastion.ps1`: single SHA-256 verified tarball transfer (`nkp-labs-update.tar.gz`), `--dry-run`/`-DryRun`, `--rollback`/`-Rollback`, `/usr/local/lib/nkp-bootstrap/` refresh, and `chmod +x` on `*.sh` and `*.py`.
  - `create-prism-role.ps1` (`-CheckUpdate`, `-SelfUpdate`) and `create-prism-role.py` (`--check-update`, `--self-update`) with `MANIFEST.json` / `.sha256` verification, syntax check, and `.bak` backup.
- **Zero-downtime `offline-bundle` releases**: uses `gh release upload --clobber` instead of deleting/recreating the release, adds `actions/cache` for downloads, and publishes per-asset `.sha256` files, `create-prism-role.py`, and `MANIFEST.json`.
- Repository hygiene files: `.gitattributes`, `.editorconfig`, `SECURITY.md`, and `CHANGELOG.md`.

### Changed
- `scripts/render.sh`: cross-platform Python 3 placeholder substitution reading dynamic keys from `local.env`, skipping `12-bootstrap-machine` during `render.sh all`.
- Fixed missing executable (`+x`) permissions on 12 scripts in Labs 09, 10, and 11.
- Streamlined root `README.md` Lab 12 section and expanded `12-bootstrap-machine/README.md` with full workflow diagram and auto-update documentation.

## 2026-04 — Lab 12 Prism Central IAM v4 Master Role & Docs

### Added
- [`12-bootstrap-machine/steps/08-prism-central-role.md`](12-bootstrap-machine/steps/08-prism-central-role.md) end-to-end guide for Windows PowerShell (`create-prism-role.ps1`) and Linux/macOS (`create-prism-role.py`).
- Complete 294-operation NKP 2.19 master role matrix covering Management Cluster deploy/self-upgrade, Managed Cluster deploy/lifecycle, CAREN, CAPX v1.10, CCM, IPAM, CSI 3.9 (Volumes + Files RWX), NIB, VM Affinity Policies, Flow/FNS, Metro/DR, and Objects read-only.
- Automatic correlated-`View` safeguard, recursive `relatedOperationList` resolution with `GET /authz/operations/{extId}` detail fallback, idempotent in-place Role & Authorization Policy updates (`ETag`/`If-Match` + HTTP 412 retry), and optional 8-endpoint live verification as the NKP user.
- Windows PowerShell 5.1 TLS 1.2 + self-signed certificate compatibility.
