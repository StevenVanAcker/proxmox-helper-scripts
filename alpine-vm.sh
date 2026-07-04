#!/usr/bin/env bash
set -e

# Usage: alpine-vm.sh <version>
# Example: alpine-vm.sh 3.20
# Use "latest" for the latest stable release
if [[ "$(id -u)" -ne 0 ]]; then
  echo "Error: run as root." >&2; exit 1
fi

VERSION="${1:?Usage: $(basename "$0") <version>  (e.g. 3.20, or 'latest')}"

if [ "$VERSION" = "latest" ]; then
  RELEASE_DIR="latest-stable"
else
  RELEASE_DIR="v${VERSION}"
fi

CLOUD_URL="https://dl-cdn.alpinelinux.org/alpine/${RELEASE_DIR}/releases/cloud/"
echo "Resolving Alpine ${VERSION} image..."
LISTING=$(curl -fsSL "$CLOUD_URL") || { echo "Error: unknown Alpine version '$VERSION'." >&2; exit 1; }
# Generic + UEFI + cloud-init: matches this script's -bios ovmf and -ide2 cloudinit setup.
FILE=$(echo "$LISTING" | grep -oE 'generic_alpine-[0-9]+\.[0-9]+\.[0-9]+-x86_64-uefi-cloudinit-r[0-9]+\.qcow2' | sort -V | tail -1)
if [ -z "$FILE" ]; then
  echo "Error: no generic cloud-init UEFI image found for Alpine ${VERSION}." >&2; exit 1
fi
echo "  -> ${FILE}"

# Defaults — override via environment variables
VMID="${VMID:-$(pvesh get /cluster/nextid)}"
HN="${HN:-alpine-$VERSION}"
CORE_COUNT="${CORE_COUNT:-1}"
RAM_SIZE="${RAM_SIZE:-512}"
DISK_SIZE="${DISK_SIZE:-1G}"
BRG="${BRG:-vmbr0}"
MAC="${MAC:-02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/\(..\)/\1:/g; s/.$//')}"
VLAN="${VLAN:-}"
MTU="${MTU:-}"
STORAGE="${STORAGE:-}"
START_VM="${START_VM:-no}"
MAKE_TEMPLATE="${MAKE_TEMPLATE:-yes}"

URL="${CLOUD_URL}${FILE}"

TEMP_DIR=$(mktemp -d)
pushd "$TEMP_DIR" >/dev/null
trap 'popd >/dev/null; rm -rf "$TEMP_DIR"' EXIT

# Auto-detect storage if not set
if [ -z "$STORAGE" ]; then
  echo "Auto-detecting storage..."
  STORAGE_COUNT=$(pvesm status -content images | awk 'NR>1' | wc -l)
  if [ "$STORAGE_COUNT" -eq 0 ]; then
    echo "Error: no valid storage found." >&2; exit 1
  elif [ "$STORAGE_COUNT" -eq 1 ]; then
    STORAGE=$(pvesm status -content images | awk 'NR>1 {print $1}')
    echo "  -> ${STORAGE}"
  else
    echo "Error: multiple storage pools found — set STORAGE env var." >&2; exit 1
  fi
fi

echo "Downloading cloud image..."
curl -fL --progress-bar -o "$FILE" "$URL"

STORAGE_TYPE=$(pvesm status -storage "$STORAGE" | awk 'NR>1 {print $2}')
FORMAT=",efitype=4m"
THIN="discard=on,ssd=1,"
case $STORAGE_TYPE in
  nfs | dir | cifs)
    DISK_EXT=".qcow2"; DISK_REF="$VMID/"; DISK_IMPORT="-format qcow2"; THIN="" ;;
  btrfs)
    DISK_EXT=".raw";   DISK_REF="$VMID/"; DISK_IMPORT="-format raw";   THIN="" ;;
  *)
    DISK_EXT="";       DISK_REF="";        DISK_IMPORT="-format raw" ;;
esac

DISK0="vm-${VMID}-disk-0${DISK_EXT}"
DISK1="vm-${VMID}-disk-1${DISK_EXT}"
DISK0_REF="${STORAGE}:${DISK_REF}${DISK0}"
DISK1_REF="${STORAGE}:${DISK_REF}${DISK1}"

NET="virtio,bridge=${BRG},macaddr=${MAC}"
[ -n "$VLAN" ] && NET="${NET},tag=${VLAN}"
[ -n "$MTU"  ] && NET="${NET},mtu=${MTU}"

echo "Creating VM ${VMID} (${HN})..."
qm create "$VMID" -agent 1 -tablet 0 -localtime 1 -bios ovmf \
  -cores "$CORE_COUNT" -memory "$RAM_SIZE" \
  -name "$HN" -tags community-script \
  -net0 "$NET" -onboot 1 -ostype l26 -scsihw virtio-scsi-pci

echo "Allocating EFI disk..."
pvesm alloc "$STORAGE" "$VMID" "$DISK0" 4M >/dev/null
echo "Importing cloud image to storage..."
qm importdisk "$VMID" "$FILE" "$STORAGE" $DISK_IMPORT >/dev/null
echo "Configuring VM disks..."
qm set "$VMID" \
  -efidisk0 "${DISK0_REF}${FORMAT}" \
  -scsi0    "${DISK1_REF},${THIN}size=${DISK_SIZE}" \
  -ide2     "${STORAGE}:cloudinit" \
  -boot     order=scsi0 \
  -serial0  socket >/dev/null
echo "Resizing disk to ${DISK_SIZE}..."
qm resize "$VMID" scsi0 "${DISK_SIZE}" >/dev/null

if [ "$MAKE_TEMPLATE" = "yes" ]; then
  echo "Converting to template..."
  qm template "$VMID"
fi

[ "$START_VM" = "yes" ] && qm start "$VMID"

echo "Created Alpine ${VERSION} VM: id=${VMID} name=${HN} storage=${STORAGE}"
echo "Configure Cloud-Init before starting: https://github.com/community-scripts/ProxmoxVE/discussions/272"
