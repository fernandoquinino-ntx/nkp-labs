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
| `nkp` v2.19.1 | https://downloads.d2iq.com/dkp/v2.19.1/nkp_v2.19.1_linux_amd64.tar.gz |
| `kubectl` v1.36.2 | https://dl.k8s.io/release/v1.36.2/bin/linux/amd64/kubectl |
| Helm 3 | https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 |
| Flux CLI | https://fluxcd.io/install.sh |
| k9s v0.51.0 | https://github.com/derailed/k9s/releases/download/v0.51.0/k9s_Linux_amd64.tar.gz |
| yq v4.47.1 | https://github.com/mikefarah/yq/releases/download/v4.47.1/yq_linux_amd64 |

It then clones https://github.com/fernandoquinino-ntx/nkp-labs.git and copies this lab to
`/home/ubuntu/nkp-workspace`.

## Latest scripts from git

The pasted cloud-init is only a loader. Each run of `nkp-bootstrap.service` downloads the latest
`scripts/bootstrap-host.sh`, `expand-root-disk.sh` and `update-workspace.sh` from `main` into
`/usr/local/lib/nkp-bootstrap/`, then refreshes `/home/ubuntu/nkp-workspace` from git. If GitHub cannot
be reached, it runs the last copy it downloaded. A fix pushed to the repo reaches the VM without a new
paste:

```bash
nkp-update            # pull the latest lab into ~/nkp-workspace (scripts, charts, docs)
nkp-update --rerun    # also run the bootstrap again. Finished steps are skipped
```

`nkp-update` never deletes `env`, `values.local.yaml`, `create-cluster.env`, kubeconfigs, `registry/`
or `airgap/`. Files tracked in git are overwritten, so put your edits in the gitignored copies, not in
`*.example`. Set `NKP_LABS_REF` in `/etc/default/nkp-bootstrap` to pin a branch or tag.

## Failures and restarts

Cloud-init only writes the files and starts `nkp-bootstrap.service`. The service does the install.

| Problem | What happens |
|---|---|
| No internet yet | waits up to 30 min (checks d2iq, GitHub, dl.k8s.io), then exits and systemd retries in 60 s |
| One download fails | `curl` retried 8 times, 10 s backoff doubling up to 5 min. apt uses `Acquire::Retries=5` and waits for the dpkg lock |
| `nkp` archive corrupt | sha256 check fails, archive deleted, step retried |
| VM stopped mid-run | the service is enabled. At boot it runs `dpkg --configure -a` and continues at the first step without a `.done` marker |
| Disk grown later in Prism | `expand-root-disk.sh` runs on every attempt. An already grown disk is not an error |
| GitHub down | loader runs the cached scripts. The workspace keeps its last copy. First boot without GitHub: systemd retries in 60 s |
| Re-run | the workspace copy never deletes `env`, `values.local.yaml`, `create-cluster.env`, kubeconfigs, `registry/` or `airgap/` |

```bash
nkp-bootstrap-status                       # steps done, services, last log lines
journalctl -u nkp-bootstrap -f
less /var/log/nkp-bootstrap.log            # full trace with timestamps and FAILED lines
sudo rm /var/lib/nkp-bootstrap/helm.done   # force one step again
sudo rm /var/lib/nkp-bootstrap/complete && sudo systemctl start nkp-bootstrap   # force a new run
```

Steps in order: `packages`, `docker`, `kubectl`, `helm`, `flux`, `k9s`, `yq`, `nkp`, `registry-image`.
The disk grow and the workspace refresh run on every attempt. Then `complete`, and the air-gap download starts ([06](06-airgap-registry.md)).

Log out and back in once so the `docker` group applies. `scripts/install-nkp.sh` checks `docker info`
and stops if this user still cannot talk to the daemon.

**Next:** [03 — install the cluster](03-install-cluster.md).
