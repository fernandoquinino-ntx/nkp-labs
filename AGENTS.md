# AGENTS.md — Repository Standards & Engineering Guidelines

This file defines the mandatory project standards for human contributors and AI coding agents working on `nkp-labs`.

---

## 1. Language Policy (Mandatory — English Only)

- **Everything committed to this repository MUST be written in English — always.**
- This rule applies without exception to:
  - Markdown documentation (`README.md`, `AGENTS.md`, `SECURITY.md`, `CHANGELOG.md`, `docs/`, `steps/`, lab READMEs)
  - Source code, shell scripts (`*.sh`), Python scripts (`*.py`), PowerShell scripts (`*.ps1`), Helm templates, and YAML comments
  - CLI prompts, log lines, help banners, error messages, and test assertions
  - Git commit messages, PR titles/descriptions, and GitHub release notes
- Automated enforcement: [`12-bootstrap-machine/tests/test_repo_hygiene.py`](12-bootstrap-machine/tests/test_repo_hygiene.py) scans tracked text files in CI and fails if non-English (Portuguese) words or diacritics are introduced.

---

## 2. Repository Folder Structure

```text
nkp-labs/
├── AGENTS.md                        # Project standards & agent instructions (this file)
├── README.md                        # Repository overview and lab index
├── SECURITY.md                      # Public secret hygiene & release integrity policy
├── CHANGELOG.md                     # Release history
├── local.env.example                # Shared placeholder values for Labs 00–11
├── .editorconfig                    # Formatting defaults (LF, UTF-8, 2/4-space indent)
├── .gitattributes                   # Enforced LF line endings on scripts/YAML/MD/PS1
├── .gitignore                       # Ignores secrets, local.env, rendered/, dist/, *.bak
├── .gitleaksignore                  # Explicitly documented gitleaks false positives only
├── .github/workflows/
│   ├── ci.yml                       # Quality, lint, mock tests, hygiene & gitleaks CI
│   └── offline-bundle.yml           # Builds, verifies offline, and publishes release assets
├── scripts/                         # Shared helpers for Labs 00–11 (render/apply/cleanup/dns)
├── docs/                            # Cross-lab standalone procedures
├── 00-prereqs/ … 11-vault-eso/      # Cluster-scoped Kubernetes labs (${PLACEHOLDER} templates)
└── 12-bootstrap-machine/            # Jump host + Prism Central + NKP 2.19 installer lab
    ├── versions.env                 # Single source of truth for LAB_VERSION & toolchain versions
    ├── README.md                    # Lab 12 overview, workflow diagram, and Auto-Update v2 guide
    ├── cloud-init.yaml              # Online cloud-init loader
    ├── cloud-init-offline.yaml      # Generated offline cloud-init (make-offline-cloud-init.sh)
    ├── *.example*                   # Sanitized example configs (never real secrets)
    ├── steps/                       # Step-by-step guides (01 … 08)
    ├── scripts/                     # Bastion, client, Prism IAM, registry, and auto-update scripts
    ├── helm-charts/                 # nkp-cluster and nkp-kommander Helm charts
    └── tests/                       # Automated mock & hygiene test suites run by CI
```

### Folder & Path Stability Rules
- **Cluster labs (`00`–`11`)**: follow `<NN>-<short-name>/` with `README.md`, YAML templates using `${PLACEHOLDERS}` declared in `local.env.example`, and optional `scripts/` or `steps/`. `scripts/render.sh all` renders Labs `00`–`11` and intentionally skips `12-bootstrap-machine`.
- **Lab 12 (`12-bootstrap-machine/scripts/`)**: **do not move or rename existing script paths** without keeping backward-compatible wrappers, because users, cloud-init units, and release URLs reference these exact paths.
- **Generated files**: `cloud-init-offline.yaml` MUST stay in sync with `cloud-init.yaml` via `bash 12-bootstrap-machine/scripts/make-offline-cloud-init.sh`.

---

## 3. Versioning & 3-Version Backward-Compatibility Policy (Mandatory)

### Single Source of Truth
- [`12-bootstrap-machine/versions.env`](12-bootstrap-machine/versions.env) is the single source of truth for:
  - `LAB_VERSION` (`MAJOR.MINOR.PATCH`, e.g., `1.3.0`)
  - `LAB_COMPAT_WINDOW` (fixed at `3`)
  - `LAB_MIN_COMPAT_VERSION` (oldest guaranteed compatible version, e.g., `1.0.0`)
  - Toolchain versions (`NKP_VERSION`, `KUBECTL_VERSION`, `HELM_VERSION`, `FLUX_VERSION`, `K9S_VERSION`, `YQ_VERSION`, `REGISTRY_IMAGE`, `NKP_SHA256_AMD64`)
- `SCRIPT_VERSION` in [`create-prism-role.py`](12-bootstrap-machine/scripts/create-prism-role.py) and `$SCRIPT_VERSION` in [`create-prism-role.ps1`](12-bootstrap-machine/scripts/create-prism-role.ps1) MUST always match `LAB_VERSION` in `versions.env` (verified in CI).
- `MANIFEST.json` published to the `offline-bundle` release embeds `lab_version`, `compat_window`, `min_compatible_version`, and `compatible_previous_versions`.

### Auto-Update Compatibility Contract (Up to 3 Previous Versions)
Every update command (`nkp-update` / `update-workspace.sh`, `update-bastion.sh`, `update-bastion.ps1`, `create-prism-role.ps1 -CheckUpdate/-SelfUpdate`, `create-prism-role.py --check-update/--self-update`) MUST obey these rules:

1. **Always check the currently installed version first** (from `.nkp-labs-version`, `versions.env`, `SCRIPT_VERSION`, or legacy feature-based inference for pre-versioning installs).
2. **Always report compatibility explicitly** before modifying any file:
   - Print installed version, target version, how many versions behind it is, and whether it is **`BACKWARD-COMPATIBLE`** or **`NOT BACKWARD-COMPATIBLE`**.
3. **Allow automatic updates up to 3 previous versions behind** (`installed_major == target_major` and `0 <= target_minor - installed_minor <= 3`):
   - Example: when `LAB_VERSION` is `1.3.0`, automatic updates from `1.2.0` (1 behind), `1.1.0` (2 behind), and `1.0.0` (3 behind) are guaranteed backward-compatible and proceed automatically.
4. **Block incompatible jumps (>3 versions behind, major mismatch, or downgrade)**:
   - Refuse automatic update with a clear non-zero exit message unless the operator explicitly passes `--force` (Bash/Python) or `-Force` (PowerShell).
   - SHA-256 checksum verification and syntax validation can **never** be bypassed, even with `--force` / `-Force`.
5. **Preserve user state and enable rollback**:
   - Never overwrite local `env`, `values.local.yaml`, `create-cluster.env`, `kommander.yaml`, `registry/`, `airgap/`, or `*.kubeconfig`.
   - Always save a pre-update backup (`.bak` for standalone scripts; `prev/` snapshot for workspace updates).

### How to Bump `LAB_VERSION`
- Increment `MINOR` (e.g., `1.3.0` -> `1.4.0`) on every feature or schema release, keep backward compatibility with the 3 immediately preceding minor versions, update `LAB_MIN_COMPAT_VERSION` (`max(0, minor - 3)`), update `SCRIPT_VERSION` in both `create-prism-role.{ps1,py}`, and record the change in `CHANGELOG.md`.
- Increment `MAJOR` only for breaking changes that cannot preserve 3-version backward compatibility.

---

## 4. Coding, Security & Cross-Platform Standards

- **Shell scripts (`*.sh`)**:
  - Must be executable (`chmod +x`), LF line endings, `set -euo pipefail` (or `set -Eeuo pipefail`), and pass `bash -n` and `shellcheck -S error`.
- **PowerShell scripts (`*.ps1`)**:
  - Must remain 100% compatible with **Windows PowerShell 5.1** and **PowerShell 7+**.
  - **Must be pure ASCII only** (no UTF-8 em-dashes, curly quotes, or non-ASCII bytes), because Windows PowerShell 5.1 decodes BOM-less UTF-8 files as Windows-1252 where `—` (`0xE2 0x80 0x94`) turns byte `0x94` into a closing quote `"` and causes a syntax error. Enforced in CI by `test_repo_hygiene.py`.
  - Handle TLS 1.2 on PS 5.1 and decode `byte[]` `Invoke-WebRequest` responses as UTF-8 (GitHub Releases often serve `.json`/`.sha256` as `application/octet-stream`).
  - Must pass PowerShell AST parsing and `PSScriptAnalyzer -Severity Error`.
- **Python scripts (`*.py`)**:
  - Must be executable (`chmod +x`), LF line endings, standard library only for runtime scripts (no `pip install` on customer hosts), and pass `python3 -m py_compile`.
- **Prism Central Role Parity**:
  - `create-prism-role.ps1` and `create-prism-role.py` MUST maintain exact 1:1 parity in their permission list (`PERMISSIONS`), correlated-`View` safeguard, recursive `relatedOperationList` resolution, and self-update compatibility logic.
- **Public Repository Security**:
  - **Never** commit customer IPs, hostnames, usernames, passwords, tokens, kubeconfigs, or TLS private keys.
  - All `*.example*` files must contain non-sensitive placeholders only and pass `gitleaks`.

---

## 5. Mandatory Verification Before Pushing

Run these checks locally before pushing to `main`:

```bash
# 1. Repo hygiene (links, +x/LF, English-only, versions.env sync, render.sh, nkp-update compat tests)
python3 12-bootstrap-machine/tests/test_repo_hygiene.py

# 2. Prism Central role 9-scenario HTTPS mock suite (PS1 + Python, 3-ver compat, IncompleteRead/gzip, PTY)
python3 12-bootstrap-machine/tests/test_prism_role.py

# 3. Shell syntax, ShellCheck, and cloud-init sync
for f in $(find . -name '*.sh' -not -path './.git/*'); do bash -n "$f"; done
shellcheck -S error $(find . -name '*.sh' -not -path './.git/*')
bash 12-bootstrap-machine/scripts/make-offline-cloud-init.sh --check
```

After pushing to `main`, confirm both GitHub Actions workflows complete with `success`:
- `.github/workflows/ci.yml`: Linux (`lint-shell`, `lint-powershell`, `test-prism-role-linux`, `test-labs-and-hygiene`, `security-scan`), **real Windows (`windows-latest` with Windows PowerShell 5.1 + PowerShell 7)**, and **real macOS (`macos-latest` with Python 3 + PTY + `render.sh`)**.
- `.github/workflows/offline-bundle.yml`: gated by `gate-linux` and `gate-windows-ps51` before building or publishing any release asset.
