#!/usr/bin/env python3
"""End-to-end automated test suite for create-prism-role.ps1 and create-prism-role.py.

Runs 7 offline HTTPS mock scenarios covering:
  0. Static parity (exact op list & MinPc), 0 duplicates, py_compile, PS1 AST parse
  1. PC pc.7.5.1.8 strict correlated-dependency enforcement + 3-hop relatedOperationList
     cycle + INTERNAL/SYSTEM_DEFINED_ONLY filtering + auto correlated-View safeguard +
     8-endpoint live NKP user verification (PS1 + Python)
  2. In-place Role & Authorization Policy UPDATE with ETag If-Match + 412 race retry
  3. Hidden relatedOperationList detail-endpoint fallback (GET /authz/operations/{extId})
  4. Legacy PC pc.2024.3 (v3 op names + IAM v4.0.b1 auto-fallback)
  5. -PrintOnly / --print dry-run (0 mutations)
  6. -CheckUpdate / -SelfUpdate and --check-update / --self-update (SHA256 verification,
     bad-checksum rejection, atomic replace, and .bak backup)
"""

import ast
import base64
import hashlib
import http.server
import json
import os
import re
import shutil
import ssl
import subprocess
import tempfile
import threading
import uuid

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
PS1 = os.path.join(REPO, "12-bootstrap-machine", "scripts", "create-prism-role.ps1")
PY = os.path.join(REPO, "12-bootstrap-machine", "scripts", "create-prism-role.py")
PWSH = os.environ.get("PWSH_BIN") or shutil.which("pwsh")
if not PWSH:
    raise SystemExit("pwsh not found on PATH (set PWSH_BIN to PowerShell binary)")

ROLE_DESC_RE = re.compile(r'^[^<>;\'()&+%\\/\"`]*$')

CORRELATED_RULES = {
    "Create New Virtual Machine": [
        "View Existing Virtual Machine", "View Cluster", "View Host", "View Cluster Host",
        "View Subnet", "View Image", "View Container", "View Project", "View Category", "View Task",
    ],
    "Delete Existing Virtual Machine": ["View Existing Virtual Machine", "View Task"],
    "Update Virtual Machine": ["View Existing Virtual Machine", "View Task"],
    "Power On Virtual Machine": ["View Existing Virtual Machine", "View Task"],
    "Create Virtual Machine Disk": ["View Virtual Machine Disk", "View Existing Virtual Machine", "View Container"],
    "Create Virtual Machine NIC": ["View Virtual Machine NIC", "View Existing Virtual Machine", "View Subnet"],
    "Create Category": ["View Category"],
    "Create Image": ["View Image", "View Cluster", "View Task"],
    "Create Volume Group": ["View Volume Group", "View Volume Group Details", "View Cluster", "View Container", "View Task"],
    "Create Volume Group Disk": ["View Volume Group Disks", "View Volume Group Details", "View Container", "Update Container Disks"],
    "Attach Volume Group To AHV VM": ["View Volume Group VM Attachments", "View Volume Group Details", "View Existing Virtual Machine"],
    "Create File Server Share": ["View File Server", "View File Server Share", "View Task"],
    "Create File Server Share Snapshot": ["View File Server", "View File Server Share", "View Snapshot File Server Share"],
    "Create Recovery Point": ["View Recovery Point", "View Existing Virtual Machine", "View Volume Group", "View Task"],
    "Create Entity Group": ["View Entity Group", "View Category", "View VPC", "View Subnet"],
    "Create Flow Policy": ["View Flow Policy", "View Rules Flow Policy", "View Entity Group", "View Address Group", "View Service Group"],
    "Create VM Anti Affinity Policy": ["View VM Anti Affinity Policy", "View Category", "View Existing Virtual Machine"],
    "Create VM Host Affinity Policy": ["View VM Host Affinity Policy", "View Category", "View Host", "View Cluster Host"],
    "Create Protection Policy": ["View Protection Policy", "View Availability Zone", "View Cluster"],
    "Create Recovery Plan": ["View Recovery Plan", "View Recovery Plan Config", "View Recovery Plan Settings", "View Recovery Plan Stage"],
    "Create Floating Ip": ["View Floating Ip", "View External Subnet", "View VPC"],
    "Update VPC": ["View VPC", "View Subnet", "View VPC Route Table", "View Vpc Virtual Switch Mapping"],
}


def make_self_signed_cert(tmpdir):
    cert = os.path.join(tmpdir, "cert.pem")
    key = os.path.join(tmpdir, "key.pem")
    subprocess.run(
        [
            "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", key, "-out", cert, "-days", "1", "-subj", "/CN=127.0.0.1",
        ],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return cert, key


def start_pc_mock(ps1_ops, cert, key, mode="pc75_strict"):
    ops = []
    op_by_name = {}
    op_by_id = {}
    hidden_related = {}

    hop1_id = str(uuid.uuid4())
    hop2_id = str(uuid.uuid4())
    hop3_id = str(uuid.uuid4())
    internal_id = str(uuid.uuid4())
    sysonly_id = str(uuid.uuid4())
    auto_view_id = str(uuid.uuid4())

    if mode == "pc2024_3":
        legacy_names = [
            "View User", "View Prism Central", "View Task",
            "Create Virtual Machine", "Delete Virtual Machine", "View Virtual Machine",
            "Update Virtual Machine", "Power On Virtual Machine", "Power Off Virtual Machine",
            "Create Virtual Machine Disk", "Delete Virtual Machine Disk", "View Virtual Machine Disk",
            "Create Or Update Name Category", "Create Or Update Value Category",
            "Delete Name Category", "Delete Value Category", "View Name Category", "View Value Category",
            "View Cluster", "View Host", "View Storage Container", "View Project", "View Image",
            "View Subnet", "Detach Volume Group From AHV VM",
        ]
        for n in legacy_names:
            oid = str(uuid.uuid4())
            r = {"extId": oid, "displayName": n, "name": n.replace(" ", "_"), "operationType": "EXTERNAL", "relatedOperationList": []}
            ops.append(r)
            op_by_name[n] = oid
            op_by_id[oid] = r
        op_by_id[op_by_name["Create Virtual Machine"]]["relatedOperationList"] = [hop1_id]
        r_h1 = {"extId": hop1_id, "displayName": "Legacy Predecessor Op", "operationType": "EXTERNAL", "relatedOperationList": []}
        ops.append(r_h1)
        op_by_id[hop1_id] = r_h1
    else:
        for name, _ in ps1_ops:
            oid = str(uuid.uuid4())
            r = {"extId": oid, "displayName": name, "name": name.replace(" ", "_"), "operationType": "EXTERNAL", "relatedOperationList": []}
            ops.append(r)
            op_by_name[name] = oid
            op_by_id[oid] = r

        r_av = {"extId": auto_view_id, "displayName": "View Virtual Machine Basic Config", "operationType": "EXTERNAL", "relatedOperationList": []}
        ops.append(r_av)
        op_by_name["View Virtual Machine Basic Config"] = auto_view_id
        op_by_id[auto_view_id] = r_av

        cvm_id = op_by_name["Create New Virtual Machine"]
        r_h1 = {"extId": hop1_id, "displayName": "Predecessor Hop 1", "operationType": "EXTERNAL", "relatedOperationList": [hop2_id, internal_id]}
        r_h2 = {"extId": hop2_id, "displayName": "Predecessor Hop 2", "operationType": "EXTERNAL", "relatedOperationList": [hop3_id, sysonly_id]}
        r_h3 = {"extId": hop3_id, "displayName": "Predecessor Hop 3", "operationType": "EXTERNAL", "relatedOperationList": [cvm_id]}
        r_int = {"extId": internal_id, "displayName": "Internal Only Op", "operationType": "INTERNAL", "relatedOperationList": []}
        r_sys = {"extId": sysonly_id, "displayName": "System Defined Only Op", "operationType": "SYSTEM_DEFINED_ONLY", "relatedOperationList": []}
        for r in (r_h1, r_h2, r_h3, r_int, r_sys):
            ops.append(r)
            op_by_id[r["extId"]] = r

        if mode == "pc75_omit_list_related":
            hidden_related[cvm_id] = [hop1_id]
            hidden_related[hop1_id] = [hop2_id, internal_id]
            hidden_related[hop2_id] = [hop3_id, sysonly_id]
            hidden_related[hop3_id] = [cvm_id]
            for r in ops:
                r.pop("relatedOperationList", None)
        else:
            op_by_id[cvm_id]["relatedOperationList"] = [hop1_id]

    iam_ver = "v4.0.b1" if mode == "pc2024_3" else "v4.0"
    pc_version = "pc.2024.3.1" if mode == "pc2024_3" else "pc.7.5.1.8"
    state = {
        "roles": {}, "policies": {}, "user_id": str(uuid.uuid4()),
        "role_puts": 0, "policy_puts": 0, "posts": 0, "detail_gets": 0,
        "fail_first_put_412": (mode == "pc75_412_retry"),
        "ids": {"hop1": hop1_id, "hop2": hop2_id, "hop3": hop3_id, "internal": internal_id, "sysonly": sysonly_id, "auto_view": auto_view_id},
    }

    if mode == "pc75_412_retry":
        rid, pid = str(uuid.uuid4()), str(uuid.uuid4())
        state["roles"][rid] = {
            "extId": rid, "displayName": "NKP Master Role", "description": "stale",
            "operations": [op_by_name["View Cluster"]], "$reserved": {"ETag": "etag-r-initial"},
        }
        state["policies"][pid] = {
            "extId": pid, "displayName": "NKP Master Role policy", "description": "stale",
            "role": rid, "$reserved": {"ETag": "etag-p-initial"},
        }

    def validate_role_body(body):
        desc = body.get("description", "")
        if not ROLE_DESC_RE.match(desc):
            return f"Invalid Role.description regex: {desc}"
        op_set = set(body.get("operations", []))
        if internal_id in op_set or sysonly_id in op_set:
            return "Non-EXTERNAL operation submitted!"
        if mode != "pc2024_3":
            for act, reqs in CORRELATED_RULES.items():
                if op_by_name[act] in op_set:
                    for req in reqs:
                        if op_by_name[req] not in op_set:
                            return f"Correlated dependency missing: '{act}' requires '{req}'!"
        return None

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _send(self, code, body, headers=None):
            raw = json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            for k, v in (headers or {}).items():
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(raw)

        def _user(self):
            a = self.headers.get("Authorization", "")
            return base64.b64decode(a[6:]).decode().split(":", 1)[0] if a.startswith("Basic ") else ""

        def do_GET(self):
            path = self.path.split("?", 1)[0]
            qs = self.path.split("?", 1)[1] if "?" in self.path else ""
            if path == "/api/prism/v4.0/config/domain-managers":
                return self._send(200, {"data": [{"config": {"buildInfo": {"version": pc_version}}}]})
            prefix = f"/api/iam/{iam_ver}"
            if path == f"{prefix}/authz/operations":
                mp, ml = re.search(r'\$page=(\d+)', qs), re.search(r'\$limit=(\d+)', qs)
                page = int(mp.group(1)) if mp else 0
                limit = int(ml.group(1)) if ml else 100
                chunk = ops[page * limit:(page + 1) * limit]
                return self._send(200, {"data": chunk, "metadata": {"totalAvailableResults": len(ops)}})
            if path.startswith(f"{prefix}/authz/operations/"):
                oid = path.rsplit("/", 1)[-1]
                state["detail_gets"] += 1
                row = op_by_id.get(oid)
                if not row:
                    return self._send(404, {"message": "not found"})
                out = dict(row)
                if oid in hidden_related:
                    out["relatedOperationList"] = hidden_related[oid]
                return self._send(200, {"data": out})
            if path == f"{prefix}/authz/roles":
                return self._send(200, {"data": list(state["roles"].values()), "metadata": {"totalAvailableResults": len(state["roles"])}})
            if path.startswith(f"{prefix}/authz/roles/"):
                r = state["roles"].get(path.rsplit("/", 1)[-1])
                return self._send(200, {"data": r}, {"ETag": r["$reserved"]["ETag"]}) if r else self._send(404, {"message": "404"})
            if path == f"{prefix}/authz/authorization-policies":
                return self._send(200, {"data": list(state["policies"].values()), "metadata": {"totalAvailableResults": len(state["policies"])}})
            if path.startswith(f"{prefix}/authz/authorization-policies/"):
                p = state["policies"].get(path.rsplit("/", 1)[-1])
                return self._send(200, {"data": p}, {"ETag": p["$reserved"]["ETag"]}) if p else self._send(404, {"message": "404"})
            if path == f"{prefix}/authn/users":
                return self._send(200, {"data": [{"extId": state["user_id"], "username": "nkp-svc", "userType": "LOCAL", "status": "ACTIVE"}], "metadata": {"totalAvailableResults": 1}})
            if self._user() == "nkp-svc" and path in (
                "/api/clustermgmt/v4.0/config/clusters", "/api/clustermgmt/v4.0/config/storage-containers",
                "/api/vmm/v4.0/content/images", "/api/networking/v4.0/config/subnets",
                "/api/vmm/v4.0/ahv/config/vms", "/api/prism/v4.0/config/categories",
            ):
                return self._send(200, {"data": []})
            return self._send(404, {"message": f"Unhandled GET {self.path}"})

        def do_POST(self):
            state["posts"] += 1
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))).decode())
            path = self.path.split("?", 1)[0]
            prefix = f"/api/iam/{iam_ver}"
            if path == f"{prefix}/authz/roles":
                err = validate_role_body(body)
                if err:
                    return self._send(400, {"data": {"error": [{"message": err}]}})
                rid = str(uuid.uuid4())
                rec = dict(body, extId=rid, **{"$reserved": {"ETag": f"etag-r-{uuid.uuid4().hex[:6]}"}})
                state["roles"][rid] = rec
                return self._send(201, {"data": rec})
            if path == f"{prefix}/authz/authorization-policies":
                pid = str(uuid.uuid4())
                rec = dict(body, extId=pid, **{"$reserved": {"ETag": f"etag-p-{uuid.uuid4().hex[:6]}"}})
                state["policies"][pid] = rec
                return self._send(201, {"data": rec})
            return self._send(404, {"message": f"Unhandled POST {self.path}"})

        def do_PUT(self):
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))).decode())
            path = self.path.split("?", 1)[0]
            prefix = f"/api/iam/{iam_ver}"
            if_match = (self.headers.get("If-Match") or "").strip('"')
            if path.startswith(f"{prefix}/authz/roles/"):
                rid = path.rsplit("/", 1)[-1]
                cur = state["roles"].get(rid)
                if state["fail_first_put_412"]:
                    state["fail_first_put_412"] = False
                    cur["$reserved"]["ETag"] = "etag-r-rotated"
                    return self._send(412, {"data": {"error": [{"message": "Simulated 412 race"}]}})
                if not cur or if_match != cur["$reserved"]["ETag"]:
                    return self._send(412, {"message": "ETag mismatch"})
                err = validate_role_body(body)
                if err:
                    return self._send(400, {"data": {"error": [{"message": err}]}})
                rec = dict(body, extId=rid, **{"$reserved": {"ETag": f"etag-r-{uuid.uuid4().hex[:6]}"}})
                state["roles"][rid] = rec
                state["role_puts"] += 1
                return self._send(200, {"data": rec})
            if path.startswith(f"{prefix}/authz/authorization-policies/"):
                pid = path.rsplit("/", 1)[-1]
                cur = state["policies"].get(pid)
                if not cur or if_match != cur["$reserved"]["ETag"]:
                    return self._send(412, {"message": "ETag mismatch"})
                rec = dict(body, extId=pid, **{"$reserved": {"ETag": f"etag-p-{uuid.uuid4().hex[:6]}"}})
                state["policies"][pid] = rec
                state["policy_puts"] += 1
                return self._send(200, {"data": rec})
            return self._send(404, {"message": f"Unhandled PUT {self.path}"})

    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, f"https://127.0.0.1:{srv.server_address[1]}", state


def test_self_update(cert, key, tmpdir):
    # Copy scripts into a temp folder and serve modified valid copies via mock HTTPS release
    ps1_copy = os.path.join(tmpdir, "create-prism-role.ps1")
    py_copy = os.path.join(tmpdir, "create-prism-role.py")
    shutil.copy2(PS1, ps1_copy)
    shutil.copy2(PY, py_copy)

    new_ps1 = open(PS1, "rb").read() + b"\n# updated-ps1-marker\n"
    new_py = open(PY, "rb").read() + b"\n# updated-py-marker\n"
    h_ps1 = hashlib.sha256(new_ps1).hexdigest()
    h_py = hashlib.sha256(new_py).hexdigest()

    files = {
        "/MANIFEST.json": json.dumps({
            "git_sha": "abcdef123456",
            "assets": {
                "create-prism-role.ps1": {"sha256": h_ps1, "size": len(new_ps1)},
                "create-prism-role.py": {"sha256": h_py, "size": len(new_py)},
            },
        }).encode(),
        "/create-prism-role.ps1": new_ps1,
        "/create-prism-role.py": new_py,
    }
    tamper = {"enabled": False}

    class RelHandler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_GET(self):
            data = files.get(self.path)
            if data is None:
                self.send_response(404)
                self.end_headers()
                return
            if tamper["enabled"] and self.path in ("/create-prism-role.ps1", "/create-prism-role.py"):
                data = data + b"\n# tampered\n"
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), RelHandler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    rel_url = f"https://127.0.0.1:{srv.server_address[1]}"
    env = dict(os.environ, NKP_LABS_RELEASE_BASE=rel_url)

    # 1. CheckUpdate reports update available without modifying file
    r = subprocess.run([PWSH, "-NoProfile", "-File", ps1_copy, "-CheckUpdate"], env=env, capture_output=True, text=True)
    assert r.returncode == 0 and "Update available" in r.stdout, r.stdout + r.stderr
    assert b"# updated-ps1-marker" not in open(ps1_copy, "rb").read()

    # 2. Tampered payload MUST be rejected on SHA256 mismatch
    tamper["enabled"] = True
    r_bad_ps = subprocess.run([PWSH, "-NoProfile", "-File", ps1_copy, "-SelfUpdate"], env=env, capture_output=True, text=True)
    assert r_bad_ps.returncode != 0, "PS1 self-update should reject tampered sha256!"
    r_bad_py = subprocess.run(["python3", py_copy, "--self-update"], env=env, capture_output=True, text=True)
    assert r_bad_py.returncode != 0, "Python self-update should reject tampered sha256!"
    tamper["enabled"] = False

    # 3. Valid SelfUpdate replaces atomically and creates .bak
    r_ok_ps = subprocess.run([PWSH, "-NoProfile", "-File", ps1_copy, "-SelfUpdate"], env=env, capture_output=True, text=True)
    assert r_ok_ps.returncode == 0 and "Updated" in r_ok_ps.stdout, r_ok_ps.stdout + r_ok_ps.stderr
    assert b"# updated-ps1-marker" in open(ps1_copy, "rb").read()
    assert os.path.exists(ps1_copy + ".bak")

    r_ok_py = subprocess.run(["python3", py_copy, "--self-update"], env=env, capture_output=True, text=True)
    assert r_ok_py.returncode == 0 and "Updated" in r_ok_py.stdout, r_ok_py.stdout + r_ok_py.stderr
    assert b"# updated-py-marker" in open(py_copy, "rb").read()
    assert os.path.exists(py_copy + ".bak")

    # 4. Subsequent CheckUpdate reports up-to-date
    r_up_ps = subprocess.run([PWSH, "-NoProfile", "-File", ps1_copy, "-CheckUpdate"], env=env, capture_output=True, text=True)
    assert r_up_ps.returncode == 0 and "up-to-date" in r_up_ps.stdout, r_up_ps.stdout + r_up_ps.stderr
    r_up_py = subprocess.run(["python3", py_copy, "--check-update"], env=env, capture_output=True, text=True)
    assert r_up_py.returncode == 0 and "up-to-date" in r_up_py.stdout, r_up_py.stdout + r_up_py.stderr

    srv.shutdown()


def main():
    with open(PS1, encoding="utf-8") as f:
        ps1_text = f.read()
    ps1_ops = re.findall(r'@\{\s*Name\s*=\s*"([^"]+)";\s*MinPc\s*=\s*"([^"]*)"\s*\}', ps1_text)
    with open(PY, encoding="utf-8") as f:
        py_text = f.read()
    tree = ast.parse(py_text)
    py_ops = next(
        ast.literal_eval(n.value) for n in tree.body
        if isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "PERMISSIONS" for t in n.targets)
    )
    assert ps1_ops == py_ops, f"PS1 ({len(ps1_ops)}) != PY ({len(py_ops)})"
    seen = {}
    for name, _ in ps1_ops:
        k = re.sub(r"\s+", " ", re.sub(r"[_-]", " ", name)).strip().lower()
        assert k not in seen, f"Duplicate op: {seen[k]} vs {name}"
        seen[k] = name
    subprocess.run(["python3", "-m", "py_compile", PY], check=True)
    ast_chk = subprocess.run(
        [
            PWSH, "-NoProfile", "-Command",
            f'$t=$null;$e=$null;$null=[System.Management.Automation.Language.Parser]::ParseFile("{PS1}",[ref]$t,[ref]$e);if($e.Count){{$e|ForEach-Object{{Write-Error $_}};exit 1}}',
        ],
        capture_output=True,
        text=True,
    )
    assert ast_chk.returncode == 0, f"PS1 AST error: {ast_chk.stderr}"
    print(f"[PASS 0] Parity ({len(ps1_ops)} ops, 0 dups), Python py_compile, PS1 AST parse")

    with tempfile.TemporaryDirectory() as tmpdir:
        cert, key = make_self_signed_cert(tmpdir)

        def run_ps1(url, extra=None):
            cmd = [
                PWSH, "-NoProfile", "-File", PS1, "-PrismIp", url, "-RoleName", "NKP Master Role",
                "-NkpUser", "nkp-svc", "-AdminUser", "admin", "-AdminPassword", "secret",
            ] + (extra or [])
            r = subprocess.run(cmd, capture_output=True, text=True)
            assert r.returncode == 0, f"PS1 failed:\n{r.stdout}\n{r.stderr}"
            return r.stdout

        def run_py(url, extra_env=None, args=None):
            env = dict(
                os.environ, PRISM_ENDPOINT=url, PRISM_USER="admin", PRISM_PASSWORD="secret",
                NKP_PC_USER="nkp-svc", NKP_ROLE_NAME="NKP Master Role",
            )
            env.update(extra_env or {})
            r = subprocess.run(["python3", PY] + (args or []), env=env, capture_output=True, text=True)
            assert r.returncode == 0, f"PY failed:\n{r.stdout}\n{r.stderr}"
            return r.stdout

        # Scenario 1
        srv, url, st = start_pc_mock(ps1_ops, cert, key, "pc75_strict")
        out_ps1 = run_ps1(url, ["-NkpPassword", "nkpsecret"])
        op_set = set(next(iter(st["roles"].values()))["operations"])
        assert st["ids"]["hop1"] in op_set and st["ids"]["hop2"] in op_set and st["ids"]["hop3"] in op_set
        assert st["ids"]["internal"] not in op_set and st["ids"]["sysonly"] not in op_set
        assert st["ids"]["auto_view"] in op_set
        assert len(op_set) == len(ps1_ops) + 4
        assert "All 8 NKP API permission checks passed" in out_ps1
        out_py = run_py(url, {"NKP_PC_PASSWORD": "nkpsecret"})
        assert "All 8 NKP API permission checks passed" in out_py
        assert st["role_puts"] == 1 and st["policy_puts"] == 1
        srv.shutdown()
        print(f"[PASS 1] PC 7.5.1.8 strict correlated-deps + 3-hop cycle + auto-View + 8-endpoint verify ({len(op_set)} ops)")

        # Scenario 2
        srv, url, st = start_pc_mock(ps1_ops, cert, key, "pc75_412_retry")
        run_ps1(url)
        assert st["role_puts"] == 1 and st["policy_puts"] == 1
        st["fail_first_put_412"] = True
        run_py(url)
        assert st["role_puts"] == 2 and st["policy_puts"] == 2
        srv.shutdown()
        print("[PASS 2] In-place Role + Policy UPDATE with 412 ETag retry (PS1 + Python)")

        # Scenario 3
        srv, url, st = start_pc_mock(ps1_ops, cert, key, "pc75_omit_list_related")
        run_ps1(url)
        assert st["detail_gets"] > 0 and st["ids"]["hop3"] in set(next(iter(st["roles"].values()))["operations"])
        st["detail_gets"] = 0
        run_py(url)
        assert st["detail_gets"] > 0 and st["ids"]["hop3"] in set(next(iter(st["roles"].values()))["operations"])
        srv.shutdown()
        print(f"[PASS 3] Hidden relatedOperationList detail-endpoint fallback ({st['detail_gets']} detail GETs)")

        # Scenario 4
        srv, url, st = start_pc_mock(ps1_ops, cert, key, "pc2024_3")
        out_ps1 = run_ps1(url)
        assert "IAM v4.0.b1" in out_ps1 and "pc.2024.3.1" in out_ps1
        assert st["ids"]["hop1"] in set(next(iter(st["roles"].values()))["operations"])
        out_py = run_py(url)
        assert "IAM v4.0.b1" in out_py
        srv.shutdown()
        print("[PASS 4] Legacy PC 2024.3 (v3 op names + IAM v4.0.b1 fallback)")

        # Scenario 5
        srv, url, st = start_pc_mock(ps1_ops, cert, key, "pc75_strict")
        out_ps1 = run_ps1(url, ["-PrintOnly"])
        out_py = run_py(url, args=["--print"])
        assert st["posts"] == 0 and st["role_puts"] == 0 and st["policy_puts"] == 0
        assert "View Virtual Machine Basic Config" in out_ps1 and "Predecessor Hop 3" in out_ps1
        assert "View Virtual Machine Basic Config" in out_py and "Predecessor Hop 3" in out_py
        srv.shutdown()
        print("[PASS 5] -PrintOnly / --print dry-run (0 mutations)")

        # Scenario 6
        test_self_update(cert, key, tmpdir)
        print("[PASS 6] -CheckUpdate / -SelfUpdate & --check-update / --self-update (SHA256 + tamper rejection + .bak)")

    print("\nALL 7 PRISM ROLE TEST SUITES PASSED!")


if __name__ == "__main__":
    main()
