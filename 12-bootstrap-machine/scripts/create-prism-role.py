#!/usr/bin/env python3
"""Create (or update) the Prism Central role NKP 2.19 needs, and assign it to an existing user.

Source-code-verified coverage for NKP 2.19 (CAREN preflight + CAPX v1.10 + CCM + IPAM +
Nutanix CSI 3.9) across Prism Central 2024.x, pc.7.3, pc.7.5, and pc.7.6+:
  - Auto-detects the Prism Central version (or honours PRISM_PC_VERSION).
  - Matches BOTH legacy v3 and v4/pc.7.3+ renamed operation names whenever present on PC
    (including View User for CAREN ValidateCredentials, View Domain Manager / Product,
    View Container + View Storage Container, View Resource Group, View Cluster Host,
    VM Profiles, GPU Profiles, Virtual Machine NIC/Disk/Categories, and CSI 3.9 ops).
  - Recursively resolves relatedOperationList (predecessor/dependent operations)
    just like the Prism Central UI does when saving a custom role.
  - Updates the existing Authorization Policy in-place so role, user, and scope stay in sync.
  - Optional live verification as the NKP user when NKP_PC_PASSWORD is set.

Does not create the user and does not print passwords.

  PRISM_ENDPOINT=https://10.0.0.1:9440 \
  PRISM_USER=admin \
  PRISM_PASSWORD='...' \
  NKP_PC_USER=nkp-user \
  ./scripts/create-prism-role.py

  ./scripts/create-prism-role.py --print
"""

from collections import deque
import json
import os
import re
import ssl
import sys
import time
import uuid
import urllib.error
import urllib.parse
import urllib.request

IAM_VERSIONS = ["v4.0", "v4.1", "v4.1.b3", "v4.1.b2", "v4.1.b1", "v4.0.b1"]

# (operation display name, min_pc_required: "" | "all" | "7.3" | "7.5")
PERMISSIONS = [
    # --- CAREN Preflight, IAM (read-only), Multidomain, Tasks, Batches, Monitoring & Licensing ---
    ("View User", "7.5"),
    ("View User Group", ""),
    ("View Role", ""),
    ("View Entity", ""),
    ("View Operation", ""),
    ("View Domain Manager", "7.5"),
    ("View Domain Manager Product", ""),
    ("View Domain Manager Registration", ""),
    ("View Prism Central", ""),
    ("View Domain", ""),
    ("View Local Domain", ""),
    ("View Location", ""),
    ("View Task", "7.3"),
    ("Cancel Task", ""),
    ("Fetch Task Response", ""),
    ("Read Batches", ""),
    ("Submit Batch", ""),
    ("View Availability Zone", ""),
    ("View Alert", ""),
    ("View Event", ""),
    ("View Licenses", ""),
    ("View License Entitlements", ""),
    ("View License Features", ""),
    # --- AHV VM, VM Profiles, NIB / Upgrades, OVA, Templates & Affinity Policies ---
    ("Create New Virtual Machine", "7.3"),
    ("Create Virtual Machine", ""),
    ("Clone Existing Virtual Machine", ""),
    ("Delete Existing Virtual Machine", "7.3"),
    ("Delete Virtual Machine", ""),
    ("View Existing Virtual Machine", "7.3"),
    ("View Virtual Machine", ""),
    ("View Virtual Machine Stats", ""),
    ("View Virtual Machine NGT", ""),
    ("Update Virtual Machine", ""),
    ("Update Virtual Machine Basic Config", ""),
    ("Update Virtual Machine Custom Attributes", ""),
    ("Update Virtual Machine Project", ""),
    ("Revert Existing Virtual Machine", ""),
    ("Customise Virtual Machine Guest", ""),
    ("Assign Virtual Machine Owner", ""),
    ("Generate VM Console Token", ""),
    ("Power On Virtual Machine", "all"),
    ("Power Off Virtual Machine", ""),
    ("Power Cycle Virtual Machine", ""),
    ("Reset Virtual Machine", ""),
    ("ACPI Shutdown Virtual Machine", ""),
    ("ACPI Reboot Virtual Machine", ""),
    ("Guest Shutdown Virtual Machine", ""),
    ("Guest Reboot Virtual Machine", ""),
    ("Create Virtual Machine Disk", "all"),
    ("Delete Virtual Machine Disk", "all"),
    ("Update Virtual Machine Disk", ""),
    ("Update Virtual Machine Disk List", ""),
    ("Update Virtual Machine Disk Custom Attributes", ""),
    ("View Virtual Machine Disk", "all"),
    ("View Virtual Machine Disk Stats", ""),
    ("Create Virtual Machine NIC", "7.5"),
    ("Update Virtual Machine NIC", "7.5"),
    ("Delete Virtual Machine NIC", ""),
    ("View Virtual Machine NIC", "7.5"),
    ("View Virtual Machine NIC Stats", ""),
    ("Assign Virtual Machine NIC IP", ""),
    ("Release Virtual Machine NIC IP", ""),
    ("Associate Virtual Machine Categories", ""),
    ("Disassociate Virtual Machine Categories", ""),
    ("Create Virtual Machine CD ROM", ""),
    ("Delete Virtual Machine CD ROM", ""),
    ("Eject Virtual Machine CD ROM", ""),
    ("Insert Virtual Machine CD ROM", ""),
    ("View Virtual Machine CD ROM", ""),
    ("Create Virtual Machine GPU", ""),
    ("Delete Virtual Machine GPU", ""),
    ("View Virtual Machine GPU", ""),
    ("Create Virtual Machine PCIe Device", ""),
    ("Delete Virtual Machine PCIe Device", ""),
    ("View Virtual Machine PCIe Device", ""),
    ("Create Virtual Machine Serial Port", ""),
    ("Delete Virtual Machine Serial Port", ""),
    ("Update Virtual Machine Serial Port", ""),
    ("View Virtual Machine Serial Port", ""),
    ("View Virtual Machine Profile", ""),
    ("Deploy Virtual Machine From VM Profile", ""),
    ("View Ova", ""),
    ("Create Ova", ""),
    ("Delete Ova", ""),
    ("Deploy Ova", ""),
    ("Download Ova", ""),
    ("View VM Templates", ""),
    ("Create VM Templates", ""),
    ("Deploy VM Templates", ""),
    ("View VM Anti Affinity Policy", ""),
    ("Create VM Anti Affinity Policy", ""),
    ("Update VM Anti Affinity Policy", ""),
    ("Delete VM Anti Affinity Policy", ""),
    ("View VM Anti Affinity Policy VM Compliance States", ""),
    ("View VM Host Affinity Policy", ""),
    ("Create VM Host Affinity Policy", ""),
    ("Update VM Host Affinity Policy", ""),
    ("Delete VM Host Affinity Policy", ""),
    ("View VM Host Affinity Policy VM Compliance States", ""),
    # --- Categories (v4 for PC 7.3/7.5+ AND legacy v3) ---
    ("Create Category", "7.3"),
    ("Delete Category", "7.3"),
    ("Update Category", ""),
    ("View Category", "7.3"),
    ("Share Category", ""),
    ("Unshare Category", ""),
    ("Create Or Update Name Category", ""),
    ("Create Or Update Value Category", ""),
    ("Delete Name Category", ""),
    ("Delete Value Category", ""),
    ("View Name Category", ""),
    ("View Value Category", ""),
    ("Create Category Mapping", ""),
    ("Delete Category Mapping", ""),
    ("Update Category Mapping", ""),
    ("View Category Mapping", ""),
    # --- Cluster, Host, GPU/PCIe Profiles, Storage Container, Project, Resource Group, Image ---
    ("View Cluster", "all"),
    ("View Cluster Stats", ""),
    ("View Cluster Profile", ""),
    ("View Host", "all"),
    ("View Host Stats", ""),
    ("View Host Nic", ""),
    ("View Cluster Host", "7.5"),
    ("View Cluster Host Nic", ""),
    ("View Cluster Pgpu Profiles", ""),
    ("View Cluster Vgpu Profiles", ""),
    ("View Physical Gpu Profile", ""),
    ("View Virtual Gpu Profile", ""),
    ("View Pcie Device", ""),
    ("View Cluster Storage Config", ""),
    ("View Disk", ""),
    ("View Disk Stats", ""),
    ("Get Cluster Network Segment", ""),
    ("View Container", ""),
    ("View Container Stats", ""),
    ("View Container Datastore", ""),
    ("Update Container Disks", ""),
    ("View Storage Container", ""),
    ("View Storage Container Stats", ""),
    ("View Storage Container Datastore", ""),
    ("View Storage Policy", ""),
    ("View Project", "all"),
    ("View Resource Group", ""),
    ("View Resource Groups", ""),
    ("View Image", "all"),
    ("Create Image", ""),
    ("Delete Image", ""),
    ("Update Image", ""),
    ("Download Image", ""),
    ("Migrate Image", ""),
    ("View Image Placement Policy", ""),
    ("View Content Repository", ""),
    ("View Content Repository Item", ""),
    # --- Networking, IPAM, Flow Virtual Networking & Flow CNI (NKP 2.19+) ---
    ("View Subnet", "all"),
    ("Update Subnet", ""),
    ("View Subnet Vnic", ""),
    ("View Overlay Subnet", ""),
    ("View External Subnet", ""),
    ("View Overlay External Subnet", ""),
    ("View Remote Subnet", ""),
    ("View VPC", ""),
    ("Update VPC", ""),
    ("View VPC Route Table", ""),
    ("View Route Table Route", ""),
    ("View Virtual Switch", ""),
    ("View Nic Profile", ""),
    ("View Cluster Networking Capabilities", ""),
    ("View Network Controller", ""),
    ("View Network Gateway", ""),
    ("View Load Balancer Session", ""),
    ("View Routing Policy", ""),
    ("View Floating Ip", ""),
    ("Create Floating Ip", ""),
    ("Update Floating Ip", ""),
    ("Delete Floating Ip", ""),
    ("Reserve Subnet Ip", ""),
    ("Unreserve Subnet Ip", ""),
    ("View Subnet Reserved Ip", ""),
    # --- Flow Network Security / FNS for Kubernetes (microseg) ---
    ("View Entity Group", ""),
    ("Create Entity Group", ""),
    ("Update Entity Group", ""),
    ("Delete Entity Group", ""),
    ("View Flow Policy", ""),
    ("View Rules Flow Policy", ""),
    ("Create Flow Policy", ""),
    ("Update Flow Policy", ""),
    ("Delete Flow Policy", ""),
    ("View Address Group", ""),
    ("Create Address Group", ""),
    ("Update Address Group", ""),
    ("Delete Address Group", ""),
    ("View Service Group", ""),
    ("Create Service Group", ""),
    ("Update Service Group", ""),
    ("Delete Service Group", ""),
    # --- Volume Groups & CSI 3.7 / 3.9 Block Storage ---
    ("Create Volume Group", ""),
    ("Delete Volume Group", ""),
    ("Update Volume Group", ""),
    ("Update Volume Group Details", ""),
    ("Revert Volume Group", ""),
    ("View Volume Group", ""),
    ("View Volume Group Details", ""),
    ("View Volume Group Metadata", ""),
    ("View Volume Group Stats", ""),
    ("Create Volume Group Disk", ""),
    ("Delete Volume Group Disk", ""),
    ("Update Volume Group Disk", ""),
    ("Update Volume Group Virtual Disks", ""),
    ("View Volume Group Disks", ""),
    ("View Volume Group Disk Stats", ""),
    ("Attach Volume Group To AHV VM", ""),
    ("Detach Volume Group From AHV VM", "all"),
    ("View Volume Group VM Attachments", ""),
    ("Attach Volume Group To External ISCSI Client", ""),
    ("Detach Volume Group From External ISCSI Client", ""),
    ("Attach Volume Group To External NVMF Client", ""),
    ("Detach Volume Group From External NVMF Client", ""),
    ("View External ISCSI Client", ""),
    ("Update External ISCSI Client", ""),
    ("View External NVMF Clients", ""),
    ("View Volume Group ISCSI Attachments", ""),
    ("Associate Volume Group Categories", ""),
    ("Disassociate Volume Group Categories", ""),
    ("Update Volume Group Categories", ""),
    ("View Volume Group Category Associations", ""),
    # --- Nutanix Files Storage / CSI 3.9 RWX Dynamic NFS Shares (CSI System role) ---
    ("View File Server", ""),
    ("View File Server Stats", ""),
    ("View File Server Share", ""),
    ("View File Server Share Stats", ""),
    ("Create File Server Share", ""),
    ("Update File Server Share", ""),
    ("Delete File Server Share", ""),
    ("Clone File Server Share", ""),
    ("View Snapshot File Server Share", ""),
    ("Create File Server Share Snapshot", ""),
    ("Delete Snapshot File Server Share", ""),
    ("Restore File Server Share", ""),
    # --- Data Protection / Recovery Points (CSI snapshots & clones, NDK) ---
    ("Create Recovery Point", ""),
    ("Delete Recovery Point", ""),
    ("View Recovery Point", ""),
    ("Restore Recovery Point", ""),
    ("Replicate Recovery Point", ""),
    ("Set Expiration Time Recovery Point", ""),
    ("Discover Cluster Recovery Point", ""),
    ("View Data Protection Cluster Capabilities", ""),
    ("View Recovery Point Store", ""),
    ("View Virtual Machine Recovery Point", ""),
    ("Compute Changed Regions Virtual Machine Recovery Point", ""),
    ("Compute Changed Regions Volume Group Recovery Point", ""),
    ("Create AHV VM Recovery Point", ""),
    ("Delete AHV VM Recovery Point", ""),
    ("Restore AHV VM Recovery Point", ""),
    ("View AHV VM Recovery Point", ""),
    ("View Protected Resource", ""),
    ("Promote Protected Resource", ""),
    ("Restore Protected Resource", ""),
    # --- Metro / Disaster Recovery (CAPX NutanixMetro / vHA / NDK DR) ---
    ("View Protection Policy", ""),
    ("Create Protection Policy", ""),
    ("Update Protection Policy", ""),
    ("Delete Protection Policy", ""),
    ("View Protection Policy Consistency Rule", ""),
    ("View Entity Sync Policy", ""),
    ("Sync Entity Sync Policy", ""),
    ("View Recovery Plan", ""),
    ("Create Recovery Plan", ""),
    ("Update Recovery Plan", ""),
    ("Delete Recovery Plan", ""),
    ("View Recovery Plan Config", ""),
    ("Create Recovery Plan Config", ""),
    ("Update Recovery Plan Config", ""),
    ("Delete Recovery Plan Config", ""),
    ("View Recovery Plan Job Config", ""),
    ("View Recovery Plan Job Execution Steps", ""),
    ("View Recovery Plan Job Validation Errors", ""),
    ("Validate Recovery Plan Config", ""),
    ("Planned Failover Recovery Plan Config", ""),
    ("Unplanned Failover Recovery Plan Config", ""),
    ("Test Failover Recovery Plan Config", ""),
    ("Resume Protection Recovery Plan Config", ""),
    ("Cleanup Resources Recovery Plan Config", ""),
    # --- Nutanix Objects / COSI (read-only visibility) ---
    ("View Object Store", ""),
    ("View Buckets Object Store", ""),
    ("View Endpoint Object Store", ""),
    ("View Object Store Certificate", ""),
    ("View Object Store Stats", ""),
    ("View Multicluster Object Store", ""),
]


def norm(value):
    return " ".join(value.replace("_", " ").replace("-", " ").lower().split())


def is_assignable_operation(row):
    op_type = (row or {}).get("operationType")
    if not op_type:
        return True
    return str(op_type).upper() == "EXTERNAL"


def parse_pc_version(raw):
    if not raw:
        return None
    m = re.search(r"(\d+)\.(\d+)(?:\.(\d+))?", raw.strip())
    if not m:
        return None
    maj, minor, pat = int(m.group(1)), int(m.group(2)), int(m.group(3) or 0)
    is_73 = maj >= 7 and maj < 2000 and (maj > 7 or minor >= 3)
    is_75 = maj >= 7 and maj < 2000 and (maj > 7 or minor >= 5)
    return {
        "raw": raw.strip(),
        "major": maj,
        "minor": minor,
        "patch": pat,
        "is_pc73_plus": is_73,
        "is_pc75_plus": is_75,
    }


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


def detect_pc_version(prism, override=""):
    if override and override.strip().lower() != "auto":
        return parse_pc_version(override)
    for path in (
        "/api/clustermgmt/v4.0/config/clusters?$limit=50",
        "/api/prism/v4.0/config/domain-managers?$limit=10",
    ):
        try:
            status, _, payload = prism.call("GET", path)
            if status == 200 and isinstance(payload, dict):
                for item in payload.get("data") or []:
                    cfg = item.get("config") or {}
                    funcs = cfg.get("clusterFunction") or []
                    ver = (cfg.get("buildInfo") or {}).get("version")
                    if ver and ("domain-managers" in path or "PRISM_CENTRAL" in funcs):
                        return parse_pc_version(str(ver))
        except Exception:
            pass
    try:
        status, _, payload = prism.call("POST", "/api/nutanix/v3/clusters/list", {"kind": "cluster", "length": 50})
        if status == 200 and isinstance(payload, dict):
            for ent in payload.get("entities") or []:
                cfg = ((ent.get("status") or {}).get("resources") or {}).get("config") or {}
                if "PRISM_CENTRAL" in (cfg.get("service_list") or []):
                    ver = (cfg.get("build") or {}).get("version")
                    if ver:
                        return parse_pc_version(str(ver))
    except Exception:
        pass
    return None


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
    seen = 0
    while True:
        join = "&" if "?" in path else "?"
        status, _, payload = prism.call("GET", f"{path}{join}$page={page}&$limit=100")
        if status != 200:
            raise SystemExit(f"GET {path} failed ({status}): {format_error(payload)}")
        rows = payload.get("data") or []
        if not isinstance(rows, list):
            rows = [rows]
        yield from rows
        seen += len(rows)
        total = (payload.get("metadata") or {}).get("totalAvailableResults")
        page += 1
        if not rows:
            return
        if total is not None:
            if seen >= total:
                return
        elif len(rows) < 100:
            return


def operation_name(row):
    return row.get("displayName") or row.get("name") or row.get("extId") or ""


def is_required(min_pc, pc_ver):
    if min_pc == "all":
        return True
    if not pc_ver:
        return False
    if min_pc == "7.3":
        return pc_ver["is_pc73_plus"]
    if min_pc == "7.5":
        return pc_ver["is_pc75_plus"]
    return False


def select_operations(prism, iam_base, operations, pc_ver):
    by_name = {}
    by_id = {}
    for row in operations:
        oid = row.get("extId")
        if oid:
            by_id[oid] = row
        if not is_assignable_operation(row):
            continue
        for field in ("displayName", "name"):
            label = row.get(field)
            if label:
                bucket = by_name.setdefault(norm(label), [])
                if row not in bucket:
                    bucket.append(row)

    selected_by_id = {}
    direct = []
    missing_required = []
    missing_optional = []

    for name, min_pc in PERMISSIONS:
        key = norm(name)
        if key in by_name:
            for row in by_name[key]:
                oid = row.get("extId")
                if oid and oid not in selected_by_id:
                    selected_by_id[oid] = row
                    direct.append(row)
        elif is_required(min_pc, pc_ver):
            missing_required.append(name)
        else:
            missing_optional.append(name)

    for grp_name, alts in (
        ("Create Virtual Machine", ("Create New Virtual Machine", "Create Virtual Machine")),
        ("Delete Virtual Machine", ("Delete Existing Virtual Machine", "Delete Virtual Machine")),
        ("View Virtual Machine", ("View Existing Virtual Machine", "View Virtual Machine")),
        ("View Storage Container", ("View Container", "View Storage Container")),
    ):
        if not any(norm(a) in by_name for a in alts) and grp_name not in missing_required:
            missing_required.append(grp_name)

    # Recursively expand relatedOperationList (predecessor/dependent operations)
    queue = deque(direct)
    related = []
    while queue:
        cur = queue.popleft()
        for rel_id in cur.get("relatedOperationList") or []:
            if not rel_id or rel_id in selected_by_id:
                continue
            rel_row = None
            if rel_id in by_id:
                rel_row = by_id[rel_id]
            else:
                st, _, payload = prism.call("GET", f"{iam_base}/authz/operations/{rel_id}")
                if st == 200 and isinstance(payload, dict) and isinstance(payload.get("data"), dict):
                    rel_row = payload["data"]
            if rel_row is not None:
                if not is_assignable_operation(rel_row):
                    continue
                selected_by_id[rel_id] = rel_row
                related.append(rel_row)
                queue.append(rel_row)
            else:
                fallback = {"extId": rel_id, "displayName": rel_id}
                selected_by_id[rel_id] = fallback
                related.append(fallback)

    return selected_by_id, direct, related, missing_required, missing_optional


def find_by_name(prism, url_path, display_name):
    for item in pages(prism, url_path):
        if item.get("displayName") == display_name:
            return item
    return None


def update_resource(prism, url_path, label, body):
    for attempt in range(1, 3):
        status, headers, current = prism.call("GET", url_path)
        if status != 200:
            raise SystemExit(f"GET {label} failed ({status}): {format_error(current)}")
        etag = extract_etag(headers, current)
        if not etag:
            raise SystemExit(f"GET {label} returned no ETag header or $reserved.Etag.")
        status, _, payload = prism.call("PUT", url_path, body, etag)
        if status in (200, 202):
            return
        if status == 412 and attempt < 2:
            continue
        raise SystemExit(f"update {label} failed ({status}): {format_error(payload)}")


def main():
    print_only = "--print" in sys.argv
    endpoint = os.environ.get("PRISM_ENDPOINT", "")
    user = os.environ.get("PRISM_USER", "")
    password = os.environ.get("PRISM_PASSWORD", "")
    nkp_user = os.environ.get("NKP_PC_USER", "")
    nkp_password = os.environ.get("NKP_PC_PASSWORD", "")
    role_name = os.environ.get("NKP_ROLE_NAME", "NKP Cluster Create")
    policy_name = os.environ.get("NKP_POLICY_NAME", role_name + " policy")
    iam_pref = os.environ.get("PRISM_IAM_VERSION", "")
    pc_ver_pref = os.environ.get("PRISM_PC_VERSION", "")
    insecure = os.environ.get("PRISM_INSECURE", "true").lower() != "false"
    if not endpoint or not user or not password:
        raise SystemExit("Set PRISM_ENDPOINT, PRISM_USER, and PRISM_PASSWORD.")
    if not print_only and not nkp_user:
        raise SystemExit("Set NKP_PC_USER to the existing Prism Central user.")

    prism = Prism(endpoint, user, password, insecure)
    iam_version = detect_iam_version(prism, iam_pref)
    iam_base = f"/api/iam/{iam_version}"
    pc_ver = detect_pc_version(prism, pc_ver_pref)
    if pc_ver:
        print(f"Detected Prism Central version: {pc_ver['raw']} (IAM {iam_version} at {prism.endpoint})")
    else:
        print(f"Using Prism Central IAM {iam_version} at {prism.endpoint}")

    operations = list(pages(prism, f"{iam_base}/authz/operations"))
    selected_by_id, direct, related, missing_required, missing_optional = select_operations(
        prism, iam_base, operations, pc_ver
    )
    print(
        f"matched {len(direct)} direct permissions + {len(related)} predecessor/related operations "
        f"(total {len(selected_by_id)} from {len(operations)} PC operations)"
    )
    if missing_optional:
        if print_only or len(missing_optional) <= 12:
            print(f"not on this Prism Central (optional, {len(missing_optional)}): " + ", ".join(missing_optional))
        else:
            print(
                f"skipped {len(missing_optional)} optional/service-specific operations not enabled on this Prism Central "
                "(use --print to list all)"
            )
    if missing_required:
        raise SystemExit("missing required permissions: " + ", ".join(missing_required))
    if print_only:
        print(f"--- Direct permissions ({len(direct)}) ---")
        for row in direct:
            print(f"  {operation_name(row)}")
        if related:
            print(f"--- Auto-resolved predecessor/related operations ({len(related)}) ---")
            for row in related:
                print(f"  + {operation_name(row)}")
        return

    operation_ids = list(selected_by_id.keys())
    role = find_by_name(prism, f"{iam_base}/authz/roles", role_name)
    pc_tag = f"PC {pc_ver['raw']}" if pc_ver else "PC v4"
    # Note: Prism Central IAM v4 Role.description forbids ()+&%<>;"'`/\ characters
    role_desc = (
        f"NKP 2.19 master role for CAPX, CCM, CAREN, IPAM, CSI, Files, NIB, Flow, and DR on {pc_tag} "
        "with auto-resolved related operations."
    )
    body = {
        "displayName": role_name,
        "description": role_desc,
        "operations": operation_ids,
    }
    if role is None:
        status, _, payload = prism.call("POST", f"{iam_base}/authz/roles", body)
        if status in (200, 201, 202):
            role = payload.get("data") or payload
            print(f"created role {role_name} ({len(operation_ids)} operations)")
        elif status == 409:
            role = find_by_name(prism, f"{iam_base}/authz/roles", role_name)
            if role is None:
                raise SystemExit(
                    f"create role returned 409 conflict, but role {role_name} was not found: {format_error(payload)}"
                )
            update_resource(prism, f"{iam_base}/authz/roles/{role['extId']}", f"role {role_name}", body)
            print(f"updated role {role_name} ({len(operation_ids)} operations, recovered from 409 conflict)")
        else:
            raise SystemExit(f"create role failed ({status}): {format_error(payload)}")
    else:
        update_resource(prism, f"{iam_base}/authz/roles/{role['extId']}", f"role {role_name}", body)
        print(f"updated role {role_name} ({len(operation_ids)} operations)")

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

    user_type = pc_user.get("userType") or "unknown"
    user_status = pc_user.get("status") or "unknown"
    print(f"Target user: {nkp_user} (type={user_type}, status={user_status}, extId={pc_user['extId']})")
    if user_status != "unknown" and str(user_status).upper() != "ACTIVE":
        print(f"WARNING: User {nkp_user} status is {user_status} (expected ACTIVE).", file=sys.stderr)

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

    existing_policy = find_by_name(prism, f"{iam_base}/authz/authorization-policies", policy_name)
    if existing_policy is not None:
        update_resource(
            prism,
            f"{iam_base}/authz/authorization-policies/{existing_policy['extId']}",
            f"policy {policy_name}",
            policy_body,
        )
        print(f"updated policy {policy_name} (role={role_name}, user={nkp_user}, scope=all entities)")
    else:
        status, _, payload = prism.call(
            "POST", f"{iam_base}/authz/authorization-policies", policy_body
        )
        if status in (200, 201, 202):
            print(f"assigned {role_name} to {nkp_user} (policy={policy_name}, scope=all entities)")
        elif status == 409:
            existing_policy = find_by_name(prism, f"{iam_base}/authz/authorization-policies", policy_name)
            if existing_policy is not None:
                update_resource(
                    prism,
                    f"{iam_base}/authz/authorization-policies/{existing_policy['extId']}",
                    f"policy {policy_name}",
                    policy_body,
                )
                print(f"updated policy {policy_name} (recovered from 409 conflict)")
            else:
                print(f"policy {policy_name} already exists (409)")
        else:
            raise SystemExit(f"create policy failed ({status}): {format_error(payload)}")

    if nkp_password:
        print(f"\nVerifying NKP API access as {nkp_user} ...")
        nkp_prism = Prism(endpoint, nkp_user, nkp_password, insecure)
        checks = [
            ("CAREN ValidateCredentials (View User)", f"{iam_base}/authn/users?$limit=1"),
            ("CAREN/CAPX/CCM Version (View Domain Manager)", "/api/prism/v4.0/config/domain-managers"),
            ("Clusters (View Cluster)", "/api/clustermgmt/v4.0/config/clusters?$limit=1"),
            ("Storage Containers (View Container)", "/api/clustermgmt/v4.0/config/storage-containers?$limit=1"),
            ("Images (View Image)", "/api/vmm/v4.0/content/images?$limit=1"),
            ("Subnets (View Subnet)", "/api/networking/v4.0/config/subnets?$limit=1"),
            ("AHV VMs (View Existing Virtual Machine)", "/api/vmm/v4.0/ahv/config/vms?$limit=1"),
            ("Categories (View Category)", "/api/prism/v4.0/config/categories?$limit=1"),
        ]
        failed = 0
        for label, path in checks:
            st, _, pl = nkp_prism.call("GET", path)
            if st == 200:
                print(f"  [PASS 200] {label}")
            else:
                failed += 1
                print(f"  [FAIL {st}] {label} -> {format_error(pl)}", file=sys.stderr)
        if failed:
            raise SystemExit(f"Verification failed for {failed} NKP API check(s) as {nkp_user}.")
        print(f"All {len(checks)} NKP API permission checks passed as {nkp_user}.")


if __name__ == "__main__":
    main()
