#!/bin/bash -e

IMG_FILE="${STAGE_WORK_DIR}/${IMG_FILENAME}${IMG_SUFFIX}.img"
NOOBS_DIR="${STAGE_WORK_DIR}/${IMG_DATE}-${IMG_NAME}${IMG_SUFFIX}"
unmount_image "${IMG_FILE}"

mkdir -p "${STAGE_WORK_DIR}"
cp "${WORK_DIR}/export-image/${IMG_FILENAME}${IMG_SUFFIX}.img" "${STAGE_WORK_DIR}/"

rm -rf "${NOOBS_DIR}"

PARTED_OUT=$(parted -sm "${IMG_FILE}" unit b print)
BOOT_OFFSET=$(echo "$PARTED_OUT" | grep -e '^1:' | cut -d':' -f 2 | tr -d B)
BOOT_LENGTH=$(echo "$PARTED_OUT" | grep -e '^1:' | cut -d':' -f 4 | tr -d B)

ROOT_OFFSET=$(echo "$PARTED_OUT" | grep -e '^2:' | cut -d':' -f 2 | tr -d B)
ROOT_LENGTH=$(echo "$PARTED_OUT" | grep -e '^2:' | cut -d':' -f 4 | tr -d B)

ensure_next_loopdev() {
    local loopdev
    loopdev="$(losetup -f)"
    loopmaj="$(echo "$loopdev" | sed -E 's/.*[^0-9]*?([0-9]+)$/\1/')"
    [[ -b "$loopdev" ]] || mknod "$loopdev" b 7 "$loopmaj"
}

echo "Mounting BOOT_DEV..."
cnt=0
until ensure_next_loopdev && BOOT_DEV=$(losetup --show -f -o "${BOOT_OFFSET}" --sizelimit "${BOOT_LENGTH}" "${IMG_FILE}"); do
	if [ $cnt -lt 5 ]; then
		cnt=$((cnt + 1))
		echo "Error in losetup for BOOT_DEV.  Retrying..."
		sleep 5
	else
		echo "ERROR: losetup for BOOT_DEV failed; exiting"
		exit 1
	fi
done

echo "Mounting ROOT_DEV..."
cnt=0
until ensure_next_loopdev && ROOT_DEV=$(losetup --show -f -o "${ROOT_OFFSET}" --sizelimit "${ROOT_LENGTH}" "${IMG_FILE}"); do
	if [ $cnt -lt 5 ]; then
		cnt=$((cnt + 1))
		echo "Error in losetup for ROOT_DEV.  Retrying..."
		sleep 5
	else
		echo "ERROR: losetup for ROOT_DEV failed; exiting"
		exit 1
	fi
done

echo "/boot: offset $BOOT_OFFSET, length $BOOT_LENGTH"
echo "/:     offset $ROOT_OFFSET, length $ROOT_LENGTH"

mkdir -p "${STAGE_WORK_DIR}/rootfs"
mkdir -p "${NOOBS_DIR}"

mount "$ROOT_DEV" "${STAGE_WORK_DIR}/rootfs"
mount "$BOOT_DEV" "${STAGE_WORK_DIR}/rootfs/boot"

ln -sv "/lib/systemd/system/apply_noobs_os_config.service" "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants/apply_noobs_os_config.service"

KERNEL_VER="$(zgrep -oPm 1 "Linux version \K(.*)$" "${STAGE_WORK_DIR}/rootfs/usr/share/doc/raspberrypi-kernel/changelog.Debian.gz" | cut -f-2 -d.)"
echo "$KERNEL_VER" > "${STAGE_WORK_DIR}/kernel_version"

bsdtar --numeric-owner --format gnutar -C "${STAGE_WORK_DIR}/rootfs/boot" -cpf - . | xz -T${XZ_THREADS:-0} --memlimit ${XZ_MEMLIMIT:-0} > "${NOOBS_DIR}/boot.tar.xz"
umount "${STAGE_WORK_DIR}/rootfs/boot"
bsdtar --numeric-owner --format gnutar -C "${STAGE_WORK_DIR}/rootfs" --one-file-system -cpf - . | xz -T${XZ_THREADS:-0} --memlimit ${XZ_MEMLIMIT:-0} > "${NOOBS_DIR}/root.tar.xz"

unmount_image "${IMG_FILE}"
