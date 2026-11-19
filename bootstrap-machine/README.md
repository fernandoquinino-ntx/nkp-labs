# Bootstrap machine

Cloud-init to paste into **Prism Central** guest customization for an NKP 2.19 jump host.

## What Prism sets, and what this file sets

| In Prism Central | In `cloud-init.yaml` |
|---|---|
| VM **Name** (inventory) | guest **hostname** `nkp-bootstrap` |
| vCPU, RAM, disk size, NIC, image | root disk **grow** after boot |
| Guest Customization → Cloud-init | this YAML, pasted raw |

Cloud-init cannot rename the VM in Prism. Type `nkp-bootstrap` in the wizard Name field and leave the same hostname in the file (or change both).

## Edit before you paste

At the top of `cloud-init.yaml`:

- `hostname` / `fqdn` — guest name. Default `nkp-bootstrap.ntnxlab.local`.
- `chpasswd` — user `ubuntu`, password `ChangeMe-NKP-Bootstrap`.
- `ssh_authorized_keys` — replace the placeholder key, or delete that list and use the password.

`ssh_pwauth: true` turns on SSH password login. The script enables `ssh` (Ubuntu) or `sshd` (Rocky).

## Prism steps (Ubuntu first)

1. Download the Ubuntu 24.04 cloud image qcow2 and upload it as a Prism image:
   `https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img`
2. Use an **LVM** qcow2. Ubuntu: `noble-server-cloudimg-amd64-lvm.img`. Rocky: GenericCloud-LVM. Create a VM from that image. Suggested size: **4 vCPU, 8 GiB RAM, 40 GiB disk**. The script grows the physical volume and the root logical volume up to that Prism disk.
3. Guest Customization → **Cloud-init**. Paste the whole `cloud-init.yaml`, starting at `#cloud-config`. Do not base64-encode it.
4. After boot, SSH as `ubuntu`. Log out and back in once so the `docker` group applies.
5. First boot downloads Docker and the NKP 2.19 CLI (~180 MB). Watch `/var/log/cloud-init-output.log`.

The public NKP 2.19 archive is **linux amd64** only (`nkp_v2.19.0_linux_amd64.tar.gz`, sha256 `38c1198a4226cdfb99afe601b1bedfe4459df478c4a4bac59a461c1926032fe4`). Use an amd64 cloud image on AHV.

## Rocky

The same script detects `dnf`, installs `cloud-utils-growpart`, and extends an LVM root (`pvresize` + `lvextend -r`) the way the Rocky bastion cloud-init does. Docker is installed from the CentOS Docker CE repo. The login user is still `ubuntu` (created by this file).

## Toolchain (NKP 2.19)

| Tool | Version |
|---|---|
| `nkp` | v2.19.0 from `https://downloads.d2iq.com/dkp` |
| `kubectl` | v1.36.2 (NKP 2.19 default; 1.35.x still supported) |
| Helm 3, Flux CLI, k9s v0.51.0, yq v4.47.1 | |
| Docker Engine + compose/buildx | |
| jq, git, sshpass, conntrack, socat | installer / kind helpers |

Cloud-init clones `https://github.com/fernandoquinino-ntx/nkp-labs.git` into `/home/ubuntu/nkp-workspace` (Helm charts `nkp-cluster` and `nkp-kommander`, plus `install-nkp.sh`). That keeps this paste small.

```bash
cp env.example env
cp values.example.yaml values.local.yaml
# edit Prism endpoint, password, SSH key, VIPs, and the NKP node image name
./install-nkp.sh
```

`install-nkp.sh` runs `nkp create bootstrap`, `helm upgrade --install` of the nkp-cluster chart, waits for the machines, writes the kubeconfig, then pivots. Set `INSTALL_KOMMANDER=true` in `env` to continue with the Kommander chart. Flux on this host is the CLI. NKP installs its own Flux (Kommander git-operator) on the cluster.

Re-run later with:

```bash
sudo /usr/local/sbin/install-nkp-bootstrap-tools.sh
```

Workspace: `/home/ubuntu/nkp-workspace`.
