#!/usr/bin/env python3
"""Repository hygiene, English-only policy, AGENTS.md, version-drift, render, and 3-version compatibility tests."""

import os
import re
import shutil
import stat
import subprocess
import tarfile
import tempfile
import yaml

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def test_agents_and_english_only():
    agents_md = os.path.join(REPO, "AGENTS.md")
    assert os.path.isfile(agents_md), "Missing AGENTS.md at repository root"
    agents_txt = open(agents_md, encoding="utf-8").read()
    assert "English" in agents_txt, "AGENTS.md must document the English-only policy"
    assert "3 previous versions" in agents_txt, "AGENTS.md must document the 3-previous-versions policy"

    # Guard against accidental Portuguese diacritics in committed text files
    diacritic_re = re.compile(
        r"[\u00e3\u00f5\u00e7\u00ea\u00e1\u00e9\u00ed\u00f3\u00fa\u00e0\u00e2\u00f4"
        r"\u00c3\u00d5\u00c7\u00ca\u00c1\u00c9\u00cd\u00d3\u00da\u00c0\u00c2\u00d4]"
    )
    violations = []
    checked = 0
    for root, dirs, files in os.walk(REPO):
        dirs[:] = [d for d in dirs if d not in (".git", "rendered", "__pycache__")]
        for fn in sorted(files):
            if not fn.endswith((".md", ".sh", ".py", ".ps1", ".yaml", ".yml", ".env")):
                continue
            p = os.path.join(root, fn)
            checked += 1
            txt = open(p, encoding="utf-8", errors="replace").read()
            for lineno, line in enumerate(txt.splitlines(), 1):
                if diacritic_re.search(line):
                    violations.append((os.path.relpath(p, REPO), lineno, line.strip()[:80]))
    assert not violations, f"Non-English text detected (repo must be English-only): {violations[:5]}"
    print(f"[PASS] AGENTS.md & English-only policy ({checked} files verified, 0 violations)")


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
    ps1_non_ascii = []
    count = 0
    ps1_count = 0
    for root, dirs, files in os.walk(REPO):
        dirs[:] = [d for d in dirs if d != ".git"]
        for fn in sorted(files):
            p = os.path.join(root, fn)
            rel = os.path.relpath(p, REPO)
            if fn.endswith(".ps1"):
                ps1_count += 1
                raw = open(p, "rb").read()
                if b"\r\n" in raw:
                    crlf.append(rel)
                if any(b > 127 for b in raw):
                    ps1_non_ascii.append(rel)
                continue
            if not fn.endswith((".sh", ".py")):
                continue
            count += 1
            if not (os.stat(p).st_mode & stat.S_IXUSR):
                non_exec.append(rel)
            if b"\r\n" in open(p, "rb").read():
                crlf.append(rel)
    assert not non_exec, f"Scripts missing executable bit (+x): {non_exec}"
    assert not crlf, f"Scripts with CRLF line endings: {crlf}"
    assert not ps1_non_ascii, (
        f"PowerShell scripts contain non-ASCII bytes (breaks Windows PowerShell 5.1 without BOM): {ps1_non_ascii}"
    )
    print(f"[PASS] Script hygiene ({count} .sh/.py +x/LF, {ps1_count} .ps1 pure-ASCII/LF)")


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

    assert versions.get("LAB_COMPAT_WINDOW") == "3", "LAB_COMPAT_WINDOW must be 3"
    lab_ver = versions["LAB_VERSION"]

    r = subprocess.run(
        ["bash", os.path.join(REPO, "12-bootstrap-machine", "scripts", "bootstrap-host.sh"), "--print-config"],
        capture_output=True, text=True, check=True,
    )
    cfg = {}
    for line in r.stdout.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            cfg[k.strip()] = v.strip().strip("'")

    for key in (
        "LAB_VERSION", "LAB_COMPAT_WINDOW", "LAB_MIN_COMPAT_VERSION",
        "NKP_VERSION", "KUBECTL_VERSION", "HELM_VERSION", "FLUX_VERSION",
        "K9S_VERSION", "YQ_VERSION", "REGISTRY_IMAGE",
    ):
        assert cfg.get(key) == versions[key], f"bootstrap-host.sh {key}={cfg.get(key)} != versions.env {versions[key]}"
    assert cfg.get("NKP_SHA256") == versions["NKP_SHA256_AMD64"], "NKP_SHA256 mismatch!"

    # Standalone role scripts must match LAB_VERSION
    py_txt = open(os.path.join(REPO, "12-bootstrap-machine", "scripts", "create-prism-role.py"), encoding="utf-8").read()
    ps1_txt = open(os.path.join(REPO, "12-bootstrap-machine", "scripts", "create-prism-role.ps1"), encoding="utf-8").read()
    assert f'SCRIPT_VERSION = "{lab_ver}"' in py_txt, f"create-prism-role.py SCRIPT_VERSION != {lab_ver}"
    assert f"$SCRIPT_VERSION = '{lab_ver}'" in ps1_txt, f"create-prism-role.ps1 $SCRIPT_VERSION != {lab_ver}"

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
    print(f"[PASS] Version consistency (lab {lab_ver}, compat=3, {versions['NKP_VERSION']} / k8s {versions['KUBECTL_VERSION']})")


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
                    if not fn.endswith(".example.yaml"):
                        list(yaml.safe_load_all(txt))
            assert yaml_count >= 15, f"Expected >= 15 rendered YAML files, got {yaml_count}"
            print(f"[PASS] scripts/render.sh all ({yaml_count} YAML manifests rendered & parsed cleanly)")
        finally:
            if not existed and os.path.exists(rendered_dir):
                shutil.rmtree(rendered_dir)


def _make_update_tarball(tmpdir, version, marker):
    stage = os.path.join(tmpdir, f"stage-{version}")
    lab = os.path.join(stage, "12-bootstrap-machine")
    os.makedirs(os.path.join(lab, "scripts"), exist_ok=True)
    with open(os.path.join(lab, "versions.env"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write(f'LAB_VERSION="{version}"\nLAB_COMPAT_WINDOW="3"\n')
    with open(os.path.join(lab, "scripts", "dummy.sh"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write(f"#!/usr/bin/env bash\necho {marker}\n")
    tb = os.path.join(tmpdir, f"update-{version}.tar.gz")
    with tarfile.open(tb, "w:gz") as tf:
        tf.add(lab, arcname="12-bootstrap-machine")
    return tb


def test_update_scripts_and_3version_compat():
    upd_ws = os.path.join(REPO, "12-bootstrap-machine", "scripts", "update-workspace.sh")
    upd_bs = os.path.join(REPO, "12-bootstrap-machine", "scripts", "update-bastion.sh")
    subprocess.run(["bash", upd_ws, "--help"], check=True, stdout=subprocess.DEVNULL)
    subprocess.run(["bash", upd_bs, "--help"], check=True, stdout=subprocess.DEVNULL)

    with tempfile.TemporaryDirectory() as tmp:
        ws = os.path.join(tmp, "ws")
        bk = os.path.join(tmp, "bk")
        os.makedirs(os.path.join(ws, "scripts"), exist_ok=True)
        with open(os.path.join(ws, ".nkp-labs-version"), "w", encoding="utf-8") as fh:
            fh.write("lab_version=1.0.0\ncommit=old000\n")
        with open(os.path.join(ws, "env"), "w", encoding="utf-8") as fh:
            fh.write("CLUSTER_NAME=keep-me\n")

        env = dict(
            os.environ,
            NKP_MODE="offline",
            NKP_NO_SUDO="true",
            NKP_WORKSPACE=ws,
            NKP_BACKUP_DIR=bk,
            NKP_LOG=os.path.join(tmp, "upd.log"),
        )

        # --status reports installed lab_version & compat_window
        r_st = subprocess.run(["bash", upd_ws, "--status"], env=env, capture_output=True, text=True, check=True)
        assert "lab_version   : 1.0.0" in r_st.stdout and "up to 3 previous versions" in r_st.stdout, r_st.stdout

        # 1.0.0 -> 1.4.0 (4 versions behind): MUST be blocked (exit 20)
        tb_140 = _make_update_tarball(tmp, "1.4.0", "v140")
        r_blk = subprocess.run(["bash", upd_ws, "--from-tarball", tb_140], env=env, capture_output=True, text=True)
        assert r_blk.returncode == 20 and "NOT BACKWARD-COMPATIBLE" in r_blk.stdout, r_blk.stdout + r_blk.stderr
        assert not os.path.exists(os.path.join(ws, "scripts", "dummy.sh")), "Workspace must stay untouched when blocked"

        # 1.0.0 -> 1.3.0 (3 versions behind): MUST be allowed (BACKWARD-COMPATIBLE)
        tb_130 = _make_update_tarball(tmp, "1.3.0", "v130")
        r_ok = subprocess.run(["bash", upd_ws, "--from-tarball", tb_130], env=env, capture_output=True, text=True, check=True)
        assert "BACKWARD-COMPATIBLE" in r_ok.stdout and "3 version(s) behind" in r_ok.stdout, r_ok.stdout
        assert "v130" in open(os.path.join(ws, "scripts", "dummy.sh"), encoding="utf-8").read()
        assert "CLUSTER_NAME=keep-me" in open(os.path.join(ws, "env"), encoding="utf-8").read()

        # 1.3.0 -> 1.2.0 (downgrade): MUST be blocked (exit 20)
        tb_120 = _make_update_tarball(tmp, "1.2.0", "v120")
        r_dn = subprocess.run(["bash", upd_ws, "--from-tarball", tb_120], env=env, capture_output=True, text=True)
        assert r_dn.returncode == 20 and "NOT BACKWARD-COMPATIBLE" in r_dn.stdout, r_dn.stdout + r_dn.stderr

        # Rollback restores 1.0.0
        r_rb = subprocess.run(["bash", upd_ws, "--rollback"], env=env, capture_output=True, text=True, check=True)
        assert "rolled back" in r_rb.stdout
        assert "lab_version=1.0.0" in open(os.path.join(ws, ".nkp-labs-version"), encoding="utf-8").read()

        # 1.0.0 -> 1.4.0 with --force: MUST override and succeed
        r_frc = subprocess.run(["bash", upd_ws, "--from-tarball", tb_140, "--force"], env=env, capture_output=True, text=True, check=True)
        assert "NOT BACKWARD-COMPATIBLE" in r_frc.stdout and "--force" in r_frc.stdout, r_frc.stdout
        assert "v140" in open(os.path.join(ws, "scripts", "dummy.sh"), encoding="utf-8").read()

    print("[PASS] Auto-update CLI & 3-previous-versions backward-compatibility checks (nkp-update)")


def test_pulse_airgap_scripts():
    vfile = os.path.join(REPO, "12-bootstrap-machine", "versions.env")
    versions = {}
    for line in open(vfile, encoding="utf-8"):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            versions[k.strip()] = v.strip().strip('"')

    pulse_yaml = os.path.join(REPO, "12-bootstrap-machine", "pulse-images.yaml")
    pdata = yaml.safe_load(open(pulse_yaml, encoding="utf-8"))
    imgs = (pdata.get("docker.io") or {}).get("images") or {}
    assert versions["KUBECTL_VERSION"] in imgs.get("mesosphere/kubectl", []), "pulse-images.yaml kubectl mismatch"
    assert versions["NKP_PULSE_VERSION"] in imgs.get("mesosphere/nkp-pulse-management", []), "pulse-images.yaml management mismatch"
    assert versions["NKP_PULSE_VERSION"] in imgs.get("mesosphere/nkp-pulse-workspace", []), "pulse-images.yaml workspace mismatch"

    build_sh = os.path.join(REPO, "12-bootstrap-machine", "scripts", "build-pulse-bundle.sh")
    fix_sh = os.path.join(REPO, "12-bootstrap-machine", "scripts", "fix-pulse-airgap.sh")
    subprocess.run(["bash", build_sh, "--help"], check=True, stdout=subprocess.DEVNULL)
    subprocess.run(["bash", fix_sh, "--help"], check=True, stdout=subprocess.DEVNULL)

    sample_jobs = [
        (
            "nkp-pulse-management-apply-crds",
            "docker.io/mesosphere/kubectl:v1.36.2",
            "registry.nkp.local:5000/mesosphere/kubectl:v1.36.2",
        ),
        (
            "nkp-pulse-management-cm-postdelete",
            "docker.io/mesosphere/nkp-pulse-management:0.5.1",
            "registry.nkp.local:5000/mesosphere/nkp-pulse-management:0.5.1",
        ),
    ]
    with tempfile.TemporaryDirectory() as tmp:
        for job_name, old_img, expected_img in sample_jobs:
            job_doc = {
                "apiVersion": "batch/v1",
                "kind": "Job",
                "metadata": {
                    "name": job_name,
                    "namespace": "kommander",
                    "uid": "00000000-0000-0000-0000-000000000001",
                    "resourceVersion": "272929",
                    "generation": 1,
                    "creationTimestamp": "2026-11-27T21:34:10Z",
                    "annotations": {"helm.sh/hook": "pre-install, pre-upgrade"},
                    "labels": {
                        "batch.kubernetes.io/controller-uid": "cd27e110-d324-4edd-b358-337bd608b895",
                        "controller-uid": "cd27e110-d324-4edd-b358-337bd608b895",
                        "job-name": job_name,
                        "app.kubernetes.io/name": "nkp-pulse-management",
                    },
                },
                "spec": {
                    "selector": {"matchLabels": {"batch.kubernetes.io/controller-uid": "cd27e110"}},
                    "template": {
                        "metadata": {
                            "labels": {
                                "batch.kubernetes.io/controller-uid": "cd27e110-d324-4edd-b358-337bd608b895",
                                "controller-uid": "cd27e110-d324-4edd-b358-337bd608b895",
                                "job-name": job_name,
                            }
                        },
                        "spec": {
                            "restartPolicy": "OnFailure",
                            "serviceAccountName": job_name,
                            "containers": [{"name": "run", "image": old_img}],
                        },
                    },
                },
                "status": {"active": 1},
            }
            in_yaml = os.path.join(tmp, f"{job_name}.yaml")
            with open(in_yaml, "w", encoding="utf-8") as fh:
                yaml.safe_dump(job_doc, fh, sort_keys=False)
            r = subprocess.run(
                [
                    "bash", fix_sh,
                    "--fix-manifest-file", in_yaml,
                    "--image-registry", "registry.nkp.local:5000",
                    "--image-pull-secret", "nkp-registry-pull",
                ],
                capture_output=True, text=True, check=True,
            )
            fixed = yaml.safe_load(r.stdout)
            assert fixed["spec"]["template"]["spec"]["containers"][0]["image"] == expected_img
            assert "status" not in fixed
            assert "selector" not in fixed["spec"]
            assert "uid" not in fixed["metadata"] and "resourceVersion" not in fixed["metadata"]
            assert "controller-uid" not in (fixed["spec"]["template"]["metadata"].get("labels") or {})
            assert fixed["spec"]["template"]["spec"]["imagePullSecrets"] == [{"name": "nkp-registry-pull"}]
            assert fixed["metadata"]["annotations"]["helm.sh/hook"] == "pre-install, pre-upgrade"

    print("[PASS] NKP Pulse air-gap bundle config & Job manifest rewrite tests")


def main():
    test_agents_and_english_only()
    test_markdown_links()
    test_script_permissions_and_eol()
    test_versions_single_source_of_truth()
    test_render_labs()
    test_update_scripts_and_3version_compat()
    test_pulse_airgap_scripts()
    print("\nALL REPO HYGIENE TESTS PASSED!")


if __name__ == "__main__":
    main()
