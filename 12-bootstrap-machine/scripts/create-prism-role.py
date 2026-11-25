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
import uuid
import urllib.error
import urllib.parse
import urllib.request

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


class Prism:
    def __init__(self, endpoint, user, password, insecure):
        self.endpoint = endpoint.rstrip("/")
        context = ssl._create_unverified_context() if insecure else ssl.create_default_context()
        password_mgr = urllib.request.HTTPPasswordMgrWithPriorAuth()
        password_mgr.add_password(None, self.endpoint, user, password, is_authenticated=True)
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPSHandler(context=context),
            urllib.request.HTTPBasicAuthHandler(password_mgr),
        )

    def call(self, method, path, body=None, etag=None):
        data = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request(self.endpoint + path, data=data, method=method)
        request.add_header("Content-Type", "application/json")
        request.add_header("Accept", "application/json")
        request.add_header("Ntnx-Request-Id", str(uuid.uuid4()))
        if etag:
            request.add_header("If-Match", etag)
        try:
            with self.opener.open(request) as response:
                raw = response.read().decode()
                return response.status, dict(response.headers), json.loads(raw) if raw else {}
        except urllib.error.HTTPError as error:
            raw = error.read().decode()
            try:
                parsed = json.loads(raw) if raw else {}
            except json.JSONDecodeError:
                parsed = {"raw": raw}
            return error.code, dict(error.headers), parsed


def pages(prism, path):
    page = 0
    while True:
        join = "&" if "?" in path else "?"
        status, _, payload = prism.call("GET", f"{path}{join}$page={page}&$limit=100")
        if status != 200:
            raise SystemExit(f"GET {path} failed ({status}): {json.dumps(payload)[:800]}")
        rows = payload.get("data") or []
        yield from rows
        total = (payload.get("metadata") or {}).get("totalAvailableResults", 0)
        page += 1
        if page * 100 >= total or not rows:
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


def find_role(prism, display_name):
    for role in pages(prism, "/api/iam/v4.0/authz/roles"):
        if role.get("displayName") == display_name:
            return role
    return None


def main():
    print_only = "--print" in sys.argv
    endpoint = os.environ.get("PRISM_ENDPOINT", "")
    user = os.environ.get("PRISM_USER", "")
    password = os.environ.get("PRISM_PASSWORD", "")
    nkp_user = os.environ.get("NKP_PC_USER", "")
    role_name = os.environ.get("NKP_ROLE_NAME", "NKP Cluster Create")
    policy_name = os.environ.get("NKP_POLICY_NAME", role_name + " policy")
    insecure = os.environ.get("PRISM_INSECURE", "true").lower() != "false"
    if not endpoint or not user or not password:
        raise SystemExit("Set PRISM_ENDPOINT, PRISM_USER, and PRISM_PASSWORD.")
    if not print_only and not nkp_user:
        raise SystemExit("Set NKP_PC_USER to the existing Prism Central user.")

    prism = Prism(endpoint, user, password, insecure)
    operations = list(pages(prism, "/api/iam/v4.0/authz/operations"))
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
    role = find_role(prism, role_name)
    body = {
        "displayName": role_name,
        "description": "Permissions for nkp create cluster. NKP 2.19 Prism Central role plus CAPX VM and category operations.",
        "operations": operation_ids,
    }
    if role is None:
        status, _, payload = prism.call("POST", "/api/iam/v4.0/authz/roles", body)
        if status not in (200, 201, 202):
            raise SystemExit(f"create role failed ({status}): {json.dumps(payload)[:800]}")
        role = (payload.get("data") or payload)
        print(f"created role {role_name}")
    else:
        status, headers, current = prism.call("GET", f"/api/iam/v4.0/authz/roles/{role['extId']}")
        etag = headers.get("Etag") or headers.get("ETag")
        status, _, payload = prism.call(
            "PUT", f"/api/iam/v4.0/authz/roles/{role['extId']}", body, etag
        )
        if status not in (200, 202):
            raise SystemExit(f"update role failed ({status}): {json.dumps(payload)[:800]}")
        print(f"updated role {role_name}")
        role = (payload.get("data") or role)

    pc_user = None
    quoted = urllib.parse.quote(nkp_user)
    status, _, payload = prism.call(
        "GET", f"/api/iam/v4.0/authn/users?$filter=username%20eq%20'{quoted}'"
    )
    if status == 200:
        for row in payload.get("data") or []:
            if row.get("username") == nkp_user:
                pc_user = row
                break
    if pc_user is None:
        for row in pages(prism, "/api/iam/v4.0/authn/users"):
            if row.get("username") == nkp_user:
                pc_user = row
                break
    if pc_user is None:
        raise SystemExit(f"Prism Central user {nkp_user} does not exist. Create the user first.")

    for policy in pages(prism, "/api/iam/v4.0/authz/authorization-policies"):
        if policy.get("displayName") == policy_name:
            print(f"policy {policy_name} already exists")
            return

    policy_body = {
        "displayName": policy_name,
        "description": f"Assign {role_name} to {nkp_user} for all entities.",
        "role": role["extId"],
        "identities": [
            {"$reserved": {"user": {"uuid": {"anyof": [pc_user["extId"]]}}}}
        ],
        "entities": [
            {"$reserved": {"*": {"*": {"eq": "*"}}}}
        ],
    }
    status, _, payload = prism.call(
        "POST", "/api/iam/v4.0/authz/authorization-policies", policy_body
    )
    if status not in (200, 201, 202):
        raise SystemExit(f"create policy failed ({status}): {json.dumps(payload)[:800]}")
    print(f"assigned {role_name} to {nkp_user}")


if __name__ == "__main__":
    main()
