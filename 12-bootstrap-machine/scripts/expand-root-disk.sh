#!/bin/bash
# noble-server-cloudimg-amd64.img: GPT, root is an ext4 partition (growpart + resize2fs).
# An LVM qcow2 (Ubuntu *-lvm.img or Rocky GenericCloud-LVM) grows the PV and the root LV.
# Safe to run again: an already grown disk is not an error.
set -euxo pipefail
export PATH="$PATH:/usr/sbin:/sbin:/usr/bin:/bin"
echo "=== disk expansion ==="
for dev in /sys/class/scsi_disk/*/device/rescan /sys/class/block/sd*/device/rescan /sys/class/block/vd*/device/rescan; do
  [ -e "$dev" ] && echo 1 > "$dev" || true
done
udevadm settle || true
ROOT_SRC="$(findmnt -n -o SOURCE /)"
FSTYPE="$(findmnt -n -o FSTYPE /)"
echo "root=${ROOT_SRC} fstype=${FSTYPE}"
grow_disk() {
  local src="$1" pk part out rc=0
  pk="$(lsblk -no PKNAME "$src" 2>/dev/null | awk 'NF{print $1; exit}')"
  part="$(lsblk -no PARTN "$src" 2>/dev/null | awk 'NF{print $1; exit}')"
  [ -n "$pk" ] && [ -n "$part" ] || return 0
  sgdisk -e "/dev/${pk}" || true
  out="$(growpart "/dev/${pk}" "$part" 2>&1)" || rc=$?
  echo "$out"
  if [ "$rc" -ne 0 ] && ! echo "$out" | grep -q NOCHANGE; then
    return "$rc"
  fi
  partprobe "/dev/${pk}" || true
}
case "$ROOT_SRC" in
  /dev/mapper/*|/dev/dm-*)
    PV="$(pvs --noheadings -o pv_name | awk 'NF{print $1; exit}')"
    [ -n "${PV:-}" ] || { echo "no LVM physical volume found" >&2; exit 1; }
    grow_disk "$PV"
    pvresize "$PV"
    VG="$(lvs --noheadings -o vg_name "$ROOT_SRC" | awk 'NF{print $1; exit}')"
    FREE="$(vgs --noheadings -o vg_free_count "$VG" | awk 'NF{print $1; exit}')"
    if [ "${FREE:-0}" -gt 0 ]; then
      lvextend -l +100%FREE -r "$ROOT_SRC"
    else
      echo "volume group ${VG} has no free extents. Root LV already uses the disk."
    fi
    ;;
  *)
    grow_disk "$ROOT_SRC"
    case "$FSTYPE" in
      ext4|ext3) resize2fs "$ROOT_SRC" ;;
      xfs) xfs_growfs / ;;
      *) echo "unsupported root filesystem ${FSTYPE} on ${ROOT_SRC}" >&2; exit 1 ;;
    esac
    ;;
esac
df -h /
echo "=== disk expansion done ==="
