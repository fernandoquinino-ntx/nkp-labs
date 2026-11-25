#!/usr/bin/env python3
"""Create the Prism Central role NKP needs, and assign it to an existing user.

The permission set is the NKP 2.19 minimum from
https://portal.nutanix.com/page/documents/details?targetId=Nutanix-Kubernetes-Platform-v2_19:top-prism-central-role-permissions-r.html
plus the CAPX operations cluster create actually calls (power on, VM disks,
category mapping). Documented for PC 7.3 and later:
https://opendocs.nutanix.com/capx/v1.9.x/user_requirements/

The public write-up of that same NKP table is
https://itcs.lu/blog/nkp-introduction-part-2

Does not create the user and does not print the password.

  PRISM_ENDPOINT=https://10.0.0.1:9440 \
  PRISM_USER=admin \
  PRISM_PASSWORD='...' \
  NKP_PC_USER=nkp-user \
  ./scripts/create-prism-role.py

  ./scripts/create-prism-role.py --print
"""

import json
import os
import ssl
import sys
import time
import uuid
import urllib.error
import urllib.parse
import urllib.request

IAM_VERSIONS = ["v4.0", "v4.1", "v4.1.b3", "v4.1.b2", "v4.1.b1", "v4.0.b1"]

# (accepted display names, required). The first name is the one NKP documents.
PERMISSIONS = [
    (["Create Virtual Machine", "Create New Virtual Machine"], True),
    (["Delete Virtual Machine"], True),
    (["View Virtual Machine"], True),
    (["View Virtual Machine Disk"], True),
    (["Update Virtual Machine"], True),
    (["Power On Virtual Machine"], True),
    (["Create Virtual Machine Disk"], True),
    (["Delete Virtual Machine Disk"], True),
    (["Create Or Update Name Category"], True),
    (["Create Or Update Value Category"], True),
    (["Delete Name Category"], True),
    (["Delete Value Category"], True),
    (["View Name Category"], True),
    (["View Value Category"], True),
    (["Create Category Mapping"], True),
    (["Delete Category Mapping"], True),
    (["Update Category Mapping"], True),
    (["View Category Mapping"], True),
    (["View Cluster"], True),
    (["View Host"], True),
    (["View Image"], True),
    (["View Prism Central"], True),
    (["View Project"], True),
    (["View Subnet"], True),
    (["Detach Volume Group From AHV VM"], True),
    (["View VPC"], False),
    (["View Overlay Subnet"], False),
    (["View Cluster Pgpu Profiles"], False),
    (["View Cluster Vgpu Profiles"], False),
    (["Update Virtual Machine Custom Attributes"], False),
    (["Create Image"], False),
    (["Delete Image"], False),
    (["Create Volume Group"], False),
    (["View Volume Group"], False),
    (["Delete Volume Group"], False),
    (["Update Volume Group"], False),
    (["Attach Volume Group To AHV VM"], False),
    (["View Storage Container"], False),
]


def norm(value):
    return " ".join(value.replace("_", " ").replace("-", " ").lower().split())


def format_error(payload):
    if not payload:
        return "(empty response)"
    if isinstance(payload, dict):
        data = payload.get("data")
        if isinstance(data, dict) and isinstance(data.get("error"), list):
            msgs = [e.get("message") or e.get("code") for e in data["error"] if isinstance(e, dict)]
            msgs = [m for m in msgs if m]
            if msgs:
                return "; ".join(msgs)
        if isinstance(payload.get("messageList"), list):
            msgs = [m.get("message") for m in payload["messageList"] if isinstance(m, dict) and m.get("message")]
            if msgs:
                return "; ".join(msgs)
    return json.dumps(payload)[:800]


def extract_etag(headers, payload):
    for k, v in (headers or {}).items():
        if k.lower() == "etag" and v:
            return v
    if isinstance(payload, dict):
        for node in (payload, payload.get("data")):
            if isinstance(node, dict) and isinstance(node.get("$reserved"), dict):
                for k, v in node["$reserved"].items():
                    if k.lower() == "etag" and v:
                        return v
    return None


class Prism:
    def __init__(self, endpoint, user, password, insecure):
        ep = endpoint.strip().rstrip("/")
        if not ep.startswith(("http://", "https://")):
            ep = f"https://{ep}" if ":" in ep else f"https://{ep}:9440"
        self.endpoint = ep
        context = ssl._create_unverified_context() if insecure else ssl.create_default_context()
        password_mgr = urllib.request.HTTPPasswordMgrWithPriorAuth()
        password_mgr.add_password(None, self.endpoint, user, password, is_authenticated=True)
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPSHandler(context=context),
            urllib.request.HTTPBasicAuthHandler(password_mgr),
        )

    def call(self, method, path, body=None, etag=None):
        data = None if body is None else json.dumps(body).encode()
        req_id = str(uuid.uuid4())
        max_attempts = 3
        for attempt in range(1, max_attempts + 1):
            if method == "GET" and attempt > 1:
                req_id = str(uuid.uuid4())
            request = urllib.request.Request(self.endpoint + path, data=data, method=method)
            if data is not None:
                request.add_header("Content-Type", "application/json")
            request.add_header("Accept", "application/json")
            request.add_header("Ntnx-Request-Id", req_id)
            if etag:
                request.add_header("If-Match", etag)
            try:
                with self.opener.open(request) as response:
                    raw = response.read().decode()
                    status, headers, parsed = (
                        response.status,
                        dict(response.headers),
                        json.loads(raw) if raw else {},
                    )
            except urllib.error.HTTPError as error:
                raw = error.read().decode()
                try:
                    parsed = json.loads(raw) if raw else {}
                except json.JSONDecodeError:
                    parsed = {"raw": raw}
                status, headers = error.code, dict(error.headers)
            if status in (429, 502, 503, 504) and attempt < max_attempts:
                time.sleep(attempt)
                continue
            return status, headers, parsed


def detect_iam_version(prism, preferred=""):
    candidates = []
    if preferred:
        candidates.append(preferred.strip())
    for v in IAM_VERSIONS:
        if v not in candidates:
            candidates.append(v)
    tried = []
    for ver in candidates:
        status, _, payload = prism.call("GET", f"/api/iam/{ver}/authz/operations?$page=0&$limit=1")
        if status == 200:
            return ver
        if status in (401, 403):
            raise SystemExit(
                f"Authentication/authorization failed ({status}) on {prism.endpoint} using IAM {ver}: {format_error(payload)}"
            )
        tried.append(f"{ver}({status})")
        if status not in (404, 405, 410, 501):
            raise SystemExit(f"Probing IAM {ver} failed ({status}): {format_error(payload)}")
    status, _, _ = prism.call("GET", "/api/iam/v4.0.a1/authz/operations?$page=0&$limit=1")
    if status == 200:
        raise SystemExit(
            f"Prism Central at {prism.endpoint} only exposes IAM v4.0.a1, which does not support "
            "/authz/authorization-policies. Upgrade Prism Central (pc.2024.2+ / 7.x) or assign the role in the UI."
        )
    raise SystemExit(
        f"No compatible Prism Central IAM v4 API found at {prism.endpoint} (tried: {', '.join(tried)})."
    )


def pages(prism, path):
    page = 0
    while True:
        join = "&" if "?" in path else "?"
        status, _, payload = prism.call("GET", f"{path}{join}$page={page}&$limit=100")
        if status != 200:
            raise SystemExit(f"GET {path} failed ({status}): {format_error(payload)}")
        rows = payload.get("data") or []
        if not isinstance(rows, list):
            rows = [rows]
        yield from rows
        total = (payload.get("metadata") or {}).get("totalAvailableResults")
        page += 1
        if not rows or len(rows) < 100 or (total is not None and page * 100 >= total):
            return


def operation_name(row):
    return row.get("displayName") or row.get("name") or ""


def select_operations(operations):
    by_name = {norm(operation_name(row)): row for row in operations}
    chosen = []
    missing_required = []
    missing_optional = []
    for names, required in PERMISSIONS:
        match = next((by_name[norm(name)] for name in names if norm(name) in by_name), None)
        if match:
            chosen.append(match)
        elif required:
            missing_required.append(names[0])
        else:
            missing_optional.append(names[0])
    return chosen, missing_required, missing_optional


def find_role(prism, iam_base, display_name):
    for role in pages(prism, f"{iam_base}/authz/roles"):
        if role.get("displayName") == display_name:
            return role
    return None


def update_role(prism, iam_base, role_id, body):
    for attempt in range(1, 3):
        status, headers, current = prism.call("GET", f"{iam_base}/authz/roles/{role_id}")
        if status != 200:
            raise SystemExit(f"GET role {role_id} failed ({status}): {format_error(current)}")
        etag = extract_etag(headers, current)
        if not etag:
            raise SystemExit(f"GET role {role_id} returned no ETag header or $reserved.Etag.")
        status, _, payload = prism.call("PUT", f"{iam_base}/authz/roles/{role_id}", body, etag)
        if status in (200, 202):
            return
        if status == 412 and attempt < 2:
            continue
        raise SystemExit(f"update role failed ({status}): {format_error(payload)}")


def main():
    print_only = "--print" in sys.argv
    endpoint = os.environ.get("PRISM_ENDPOINT", "")
    user = os.environ.get("PRISM_USER", "")
    password = os.environ.get("PRISM_PASSWORD", "")
    nkp_user = os.environ.get("NKP_PC_USER", "")
    role_name = os.environ.get("NKP_ROLE_NAME", "NKP Cluster Create")
    policy_name = os.environ.get("NKP_POLICY_NAME", role_name + " policy")
    iam_pref = os.environ.get("PRISM_IAM_VERSION", "")
    insecure = os.environ.get("PRISM_INSECURE", "true").lower() != "false"
    if not endpoint or not user or not password:
        raise SystemExit("Set PRISM_ENDPOINT, PRISM_USER, and PRISM_PASSWORD.")
    if not print_only and not nkp_user:
        raise SystemExit("Set NKP_PC_USER to the existing Prism Central user.")

    prism = Prism(endpoint, user, password, insecure)
    iam_version = detect_iam_version(prism, iam_pref)
    iam_base = f"/api/iam/{iam_version}"
    print(f"Using Prism Central IAM {iam_version} at {prism.endpoint}")
    operations = list(pages(prism, f"{iam_base}/authz/operations"))
    chosen, missing_required, missing_optional = select_operations(operations)
    print(f"matched {len(chosen)} permissions")
    for row in chosen:
        print(f"  {operation_name(row)}")
    if missing_optional:
        print("not on this Prism Central (optional): " + ", ".join(missing_optional))
    if missing_required:
        raise SystemExit("missing required permissions: " + ", ".join(missing_required))
    if print_only:
        return

    operation_ids = [row["extId"] for row in chosen]
    role = find_role(prism, iam_base, role_name)
    body = {
        "displayName": role_name,
        "description": "Permissions for nkp create cluster. NKP 2.19 Prism Central role plus CAPX VM and category operations.",
        "operations": operation_ids,
    }
    if role is None:
        status, _, payload = prism.call("POST", f"{iam_base}/authz/roles", body)
        if status in (200, 201, 202):
            role = payload.get("data") or payload
            print(f"created role {role_name}")
        elif status == 409:
            role = find_role(prism, iam_base, role_name)
            if role is None:
                raise SystemExit(
                    f"create role returned 409 conflict, but role {role_name} was not found: {format_error(payload)}"
                )
            update_role(prism, iam_base, role["extId"], body)
            print(f"updated role {role_name} (recovered from 409 conflict)")
        else:
            raise SystemExit(f"create role failed ({status}): {format_error(payload)}")
    else:
        update_role(prism, iam_base, role["extId"], body)
        # PUT returns a message, not the role. Keep the extId from the GET.
        print(f"updated role {role_name}")

    pc_user = None
    quoted = urllib.parse.quote(nkp_user.replace("'", "''"))
    status, _, payload = prism.call(
        "GET", f"{iam_base}/authn/users?$filter=username%20eq%20'{quoted}'"
    )
    if status == 200:
        for row in payload.get("data") or []:
            if row.get("username") == nkp_user:
                pc_user = row
                break
    if pc_user is None:
        for row in pages(prism, f"{iam_base}/authn/users"):
            if row.get("username") == nkp_user:
                pc_user = row
                break
    if pc_user is None:
        raise SystemExit(f"Prism Central user {nkp_user} does not exist. Create the user first.")

    for policy in pages(prism, f"{iam_base}/authz/authorization-policies"):
        if policy.get("displayName") == policy_name:
            if policy.get("role") and policy.get("role") != role["extId"]:
                print(
                    f"WARNING: policy {policy_name} already exists but points to role "
                    f"{policy.get('role')} instead of {role['extId']}",
                    file=sys.stderr,
                )
            else:
                print(f"policy {policy_name} already exists")
            return

    policy_body = {
        "displayName": policy_name,
        "description": f"Assign {role_name} to {nkp_user} for all entities.",
        "authorizationPolicyType": "USER_DEFINED",
        "role": role["extId"],
        "identities": [
            {"$reserved": {"user": {"uuid": {"anyof": [pc_user["extId"]]}}}}
        ],
        "entities": [
            {"$reserved": {"*": {"*": {"eq": "*"}}}}
        ],
    }
    status, _, payload = prism.call(
        "POST", f"{iam_base}/authz/authorization-policies", policy_body
    )
    if status in (200, 201, 202):
        print(f"assigned {role_name} to {nkp_user}")
    elif status == 409:
        print(f"policy {policy_name} already exists (409)")
    else:
        raise SystemExit(f"create policy failed ({status}): {format_error(payload)}")


if __name__ == "__main__":
    main()
