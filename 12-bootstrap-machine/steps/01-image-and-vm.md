# 01 — Image and VM

Upload this qcow2 to Prism Central as an image, then create the VM from it:

https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img

The root filesystem is an **ext4 partition**. Cloud-init runs `growpart` and `resize2fs` so it fills
the disk you set in Prism. If you later use an LVM cloud image, the same script grows the physical
volume and the root logical volume instead.

| Prism field | Value |
|---|---|
| Name | `nkp-bootstrap` (same string as `hostname` in `cloud-init.yaml`) |
| vCPU | 4 |
| Memory | 8 GiB |
| Disk | 40 GiB or more |
| Image | the Ubuntu 24.04 amd64 cloud image above |

Cloud-init sets the **guest** hostname. The Prism inventory name is only the Name field in the wizard.
Use the same string in both places.

**Next:** [02 — cloud-init](02-cloud-init.md).
