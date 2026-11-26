#!/usr/bin/env python3
"""Repository hygiene, documentation link, version-drift, and lab render tests."""

import os
import re
import shutil
import stat
import subprocess
import tempfile
import yaml

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def test_markdown_links():
    broken = []
    md_count = 0
    for root, dirs, files in os.walk(REPO):
        dirs[:] = [d for d in dirs if d != ".git"]
        for fn in sorted(files):
            if not fn.endswith(".md"):
                continue
            md_count += 1
            mf = os.path.join(root, fn)
            with open(mf, encoding="utf-8", errors="replace") as fh:
                txt = re.sub(r"```.*?```", "", fh.read(), flags=re.S)
            for m in re.finditer(r"\[[^\]]*\]\(([^)]+)\)", txt):
                target = m.group(1).strip()
                if target.startswith(("http://", "https://", "mailto:", "#")):
                    continue
                tp = target.split("#", 1)[0]
                if not tp:
                    continue
                resolved = os.path.normpath(os.path.join(os.path.dirname(mf), tp))
                if not os.path.exists(resolved):
                    broken.append((os.path.relpath(mf, REPO), target))
    assert not broken, f"Broken relative Markdown links: {broken}"
    print(f"[PASS] Markdown relative links ({md_count} files, 0 broken)")


def test_script_permissions_and_eol():
    non_exec = []
    crlf = []
    count = 0
    for root, dirs, files in os.walk(REPO):
        dirs[:] = [d for d in dirs if d != ".git"]
        for fn in sorted(files):
            if not fn.endswith((".sh", ".py")):
                continue
            count += 1
            p = os.path.join(root, fn)
            rel = os.path.relpath(p, REPO)
            if not (os.stat(p).st_mode & stat.S_IXUSR):
                non_exec.append(rel)
            if b"\r\n" in open(p, "rb").read():
                crlf.append(rel)
    assert not non_exec, f"Scripts missing executable bit (+x): {non_exec}"
    assert not crlf, f"Scripts with CRLF line endings: {crlf}"
    print(f"[PASS] Script hygiene ({count} .sh/.py scripts: all +x, 0 CRLF)")


def test_versions_single_source_of_truth():
    vfile = os.path.join(REPO, "12-bootstrap-machine", "versions.env")
    versions = {}
    with open(vfile, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            versions[k.strip()] = v.strip().strip('"')

    r = subprocess.run(
        ["bash", os.path.join(REPO, "12-bootstrap-machine", "scripts", "bootstrap-host.sh"), "--print-config"],
        capture_output=True, text=True, check=True,
    )
    cfg = {}
    for line in r.stdout.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            cfg[k.strip()] = v.strip().strip("'")

    for key in ("NKP_VERSION", "KUBECTL_VERSION", "HELM_VERSION", "FLUX_VERSION", "K9S_VERSION", "YQ_VERSION", "REGISTRY_IMAGE"):
        assert cfg.get(key) == versions[key], f"bootstrap-host.sh {key}={cfg.get(key)} != versions.env {versions[key]}"
    assert cfg.get("NKP_SHA256") == versions["NKP_SHA256_AMD64"], "NKP_SHA256 mismatch!"

    nkp_bare = versions["NKP_VERSION"].lstrip("v")
    k8s_bare = versions["KUBECTL_VERSION"].lstrip("v")

    for rel, needle in (
        ("12-bootstrap-machine/helm-charts/nkp-cluster/Chart.yaml", nkp_bare),
        ("12-bootstrap-machine/helm-charts/nkp-kommander/Chart.yaml", nkp_bare),
        ("12-bootstrap-machine/helm-charts/nkp-cluster/values.yaml", k8s_bare),
        (".github/workflows/offline-bundle.yml", versions["NKP_VERSION"]),
    ):
        txt = open(os.path.join(REPO, rel), encoding="utf-8").read()
        assert needle in txt, f"Version drift: expected '{needle}' in {rel}"
    print(f"[PASS] Version consistency ({versions['NKP_VERSION']} / k8s {versions['KUBECTL_VERSION']})")


def test_render_labs():
    env_example = os.path.join(REPO, "local.env.example")
    rendered_dir = os.path.join(REPO, "rendered")
    existed = os.path.exists(rendered_dir)
    keys = set()
    sanitized_lines = []
    for raw in open(env_example, encoding="utf-8"):
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", raw.rstrip("\n"))
        if m:
            k, v = m.group(1), m.group(2)
            keys.add(k)
            # Replace angle-bracket placeholders or empty defaults with valid test values
            v = re.sub(r"<[^>]+>", "ci-test-value", v)
            if not v.strip():
                v = "Y2ktdGVzdC12YWx1ZQ=="
            sanitized_lines.append(f"{k}={v}\n")
        else:
            sanitized_lines.append(raw)

    with tempfile.TemporaryDirectory() as tmp:
        tmp_env = os.path.join(tmp, "local.env")
        with open(tmp_env, "w", encoding="utf-8", newline="\n") as fh:
            fh.writelines(sanitized_lines)
        env = dict(os.environ, ENV_FILE=tmp_env)
        try:
            r = subprocess.run(
                ["bash", os.path.join(REPO, "scripts", "render.sh"), "all"],
                env=env, capture_output=True, text=True, check=True,
            )
            assert "rendered ->" in r.stdout
            assert not os.path.exists(os.path.join(rendered_dir, "12-bootstrap-machine")), "Lab 12 should be skipped by render.sh all"

            yaml_count = 0
            for root, _, files in os.walk(rendered_dir):
                for fn in sorted(files):
                    if not fn.endswith(".yaml"):
                        continue
                    yaml_count += 1
                    p = os.path.join(root, fn)
                    txt = open(p, encoding="utf-8").read()
                    for ph in re.findall(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", txt):
                        if ph in keys:
                            raise AssertionError(f"Unrendered placeholder ${{{ph}}} in {os.path.relpath(p, rendered_dir)}")
                    # Every rendered non-example YAML must parse as valid YAML
                    if not fn.endswith(".example.yaml"):
                        list(yaml.safe_load_all(txt))
            assert yaml_count >= 15, f"Expected >= 15 rendered YAML files, got {yaml_count}"
            print(f"[PASS] scripts/render.sh all ({yaml_count} YAML manifests rendered & parsed cleanly)")
        finally:
            if not existed and os.path.exists(rendered_dir):
                shutil.rmtree(rendered_dir)


def test_update_scripts_cli():
    # Verify --help and --status work cleanly on update-workspace.sh and update-bastion.sh
    upd_ws = os.path.join(REPO, "12-bootstrap-machine", "scripts", "update-workspace.sh")
    upd_bs = os.path.join(REPO, "12-bootstrap-machine", "scripts", "update-bastion.sh")
    subprocess.run(["bash", upd_ws, "--help"], check=True, stdout=subprocess.DEVNULL)
    subprocess.run(["bash", upd_bs, "--help"], check=True, stdout=subprocess.DEVNULL)
    with tempfile.TemporaryDirectory() as tmp:
        env = dict(os.environ, NKP_MODE="offline", NKP_WORKSPACE=tmp, NKP_BACKUP_DIR=os.path.join(tmp, "bk"))
        r = subprocess.run(["bash", upd_ws, "--status"], env=env, capture_output=True, text=True, check=True)
        assert "mode      : offline" in r.stdout
    print("[PASS] Auto-update script CLI checks (update-workspace.sh, update-bastion.sh)")


def main():
    test_markdown_links()
    test_script_permissions_and_eol()
    test_versions_single_source_of_truth()
    test_render_labs()
    test_update_scripts_cli()
    print("\nALL REPO HYGIENE TESTS PASSED!")


if __name__ == "__main__":
    main()
