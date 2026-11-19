# 02 — Cloud-init

In the VM wizard open **Guest Customization → Cloud-init** and paste
[`cloud-init.yaml`](../cloud-init.yaml). Paste the YAML. Do not base64-encode it. Prism encodes it
when it saves the VM.

Raw URL, if you want to download it on another machine:

https://raw.githubusercontent.com/fernandoquinino-ntx/nkp-labs/main/12-bootstrap-machine/cloud-init.yaml

## Edit before you paste

| Field | Default |
|---|---|
| `hostname` / `fqdn` | `nkp-bootstrap` / `nkp-bootstrap.ntnxlab.local` |
| `chpasswd` user `ubuntu` | `ChangeMe-NKP-Bootstrap` |
| `ssh_authorized_keys` | replace the placeholder, or delete the list and use the password |

`ssh_pwauth: true` turns on SSH password login. The script starts `ssh` on Ubuntu and `sshd` on Rocky.

## What the first boot installs

| Tool | From |
|---|---|
| Docker Engine, compose, buildx | https://download.docker.com/linux/ubuntu |
| `nkp` v2.19.0 | https://downloads.d2iq.com/dkp/v2.19.0/nkp_v2.19.0_linux_amd64.tar.gz |
| `kubectl` v1.36.2 | https://dl.k8s.io/release/v1.36.2/bin/linux/amd64/kubectl |
| Helm 3 | https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 |
| Flux CLI | https://fluxcd.io/install.sh |
| k9s v0.51.0 | https://github.com/derailed/k9s/releases/download/v0.51.0/k9s_Linux_amd64.tar.gz |
| yq v4.47.1 | https://github.com/mikefarah/yq/releases/download/v4.47.1/yq_linux_amd64 |

It then clones https://github.com/fernandoquinino-ntx/nkp-labs.git and copies this lab to
`/home/ubuntu/nkp-workspace`. Watch `/var/log/cloud-init-output.log`.

Log out and back in once so the `docker` group applies. `scripts/install-nkp.sh` checks `docker info`
and stops if this user still cannot talk to the daemon.

**Next:** [03 — install the cluster](03-install-cluster.md).
