#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
BUILD_DIR="$HERE/build"
VERSION="$(cat "$REPO_ROOT/VERSION")"

APPLIANCE_ARCH="${APPLIANCE_ARCH:-amd64}"
case "$APPLIANCE_ARCH" in
    amd64)
        GO_ARCH=amd64
        ALPINE_ARCH=x86_64
        GRUB_TARGET=x86_64-efi
        EFI_BINARY=BOOTX64.EFI
        ;;
    arm64)
        GO_ARCH=arm64
        ALPINE_ARCH=aarch64
        GRUB_TARGET=arm64-efi
        EFI_BINARY=BOOTAA64.EFI
        ;;
    *)
        echo "ERROR: APPLIANCE_ARCH must be 'amd64' or 'arm64' (got: $APPLIANCE_ARCH)"
        exit 1
        ;;
esac

IMAGE_NAME="bootimus-appliance-${VERSION}-${APPLIANCE_ARCH}.img"
IMAGE_SIZE_BYTES="${IMAGE_SIZE_BYTES:-2147483648}"
ALPINE_BRANCH="${ALPINE_BRANCH:-v3.20}"
ALPINE_MIRROR="${ALPINE_MIRROR:-http://dl-cdn.alpinelinux.org/alpine}"

mkdir -p "$BUILD_DIR"

HOST_ARCH=$(uname -m)
case "$HOST_ARCH:$APPLIANCE_ARCH" in
    x86_64:amd64|aarch64:arm64)
        ;; # native
    *)
        if ! [ -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ] && [ "$APPLIANCE_ARCH" = "arm64" ]; then
            echo "ERROR: cross-building arm64 on $HOST_ARCH needs qemu-user-static + binfmt_misc on the host."
            echo "       On Arch:   sudo pacman -S qemu-user-static qemu-user-static-binfmt"
            echo "       On Debian: sudo apt install qemu-user-static binfmt-support"
            echo "       Or build on an actual arm64 machine."
            exit 1
        fi
        if ! [ -f /proc/sys/fs/binfmt_misc/qemu-x86_64 ] && [ "$APPLIANCE_ARCH" = "amd64" ]; then
            echo "ERROR: cross-building amd64 on $HOST_ARCH needs qemu-user-static + binfmt_misc on the host."
            exit 1
        fi
        ;;
esac

PREBUILT="$REPO_ROOT/bootimus-linux-${GO_ARCH}"
if [ -x "$PREBUILT" ]; then
    echo ">> [1/3] Reusing existing $PREBUILT…"
    cp "$PREBUILT" "$BUILD_DIR/bootimus"
else
    echo ">> [1/3] Cross-compiling bootimus $VERSION for linux/$GO_ARCH…"
    (
        cd "$REPO_ROOT"
        CGO_ENABLED=0 GOOS=linux GOARCH="$GO_ARCH" \
            go build -ldflags="-w -s -X bootimus/internal/server.Version=${VERSION}" \
            -o "$BUILD_DIR/bootimus" .
    )
fi
echo "   $(du -h "$BUILD_DIR/bootimus" | cut -f1) — $APPLIANCE_ARCH $VERSION"

STAGE="$BUILD_DIR/stage"
rm -rf "$STAGE"
mkdir -p "$STAGE/usr/local/bin"
cp -a "$HERE/overlay/." "$STAGE/"
cp "$BUILD_DIR/bootimus" "$STAGE/usr/local/bin/bootimus"

echo ">> [2/3] Building Alpine image for $APPLIANCE_ARCH ($ALPINE_ARCH) in Docker…"
docker run --rm --privileged \
    -v /dev:/dev \
    -v "$BUILD_DIR:/out" \
    -v "$STAGE:/stage:ro" \
    -v "$HERE/setup.sh:/setup.sh:ro" \
    -e ALPINE_BRANCH="$ALPINE_BRANCH" \
    -e ALPINE_MIRROR="$ALPINE_MIRROR" \
    -e ALPINE_ARCH="$ALPINE_ARCH" \
    -e IMAGE_SIZE_BYTES="$IMAGE_SIZE_BYTES" \
    -e IMAGE_NAME="$IMAGE_NAME" \
    -e GRUB_TARGET="$GRUB_TARGET" \
    -e EFI_BINARY="$EFI_BINARY" \
    alpine:${ALPINE_BRANCH#v} sh -euxc '
        apk add --no-cache \
            apk-tools bash coreutils e2fsprogs dosfstools mtools \
            parted util-linux grub grub-efi

        IMG=/out/"$IMAGE_NAME"
        rm -f "$IMG"
        truncate -s "$IMAGE_SIZE_BYTES" "$IMG"

        parted -s "$IMG" mklabel gpt
        parted -s "$IMG" mkpart ESP fat32 1MiB 257MiB
        parted -s "$IMG" set 1 esp on
        parted -s "$IMG" mkpart root ext4 257MiB 100%

        LOOP=$(losetup -f --show -P "$IMG")
        trap "umount -R /mnt/rootfs 2>/dev/null || true; losetup -d $LOOP 2>/dev/null || true" EXIT

        mkfs.vfat -F 32 -n BOOTIMUS "${LOOP}p1"
        mkfs.ext4 -F -L bootimus "${LOOP}p2"

        mkdir -p /mnt/rootfs
        mount "${LOOP}p2" /mnt/rootfs
        mkdir -p /mnt/rootfs/boot/efi
        mount "${LOOP}p1" /mnt/rootfs/boot/efi

        REPO="$ALPINE_MIRROR/$ALPINE_BRANCH/main"
        COMMUNITY="$ALPINE_MIRROR/$ALPINE_BRANCH/community"

        apk --root=/mnt/rootfs --initdb --arch="$ALPINE_ARCH" \
            -X "$REPO" -X "$COMMUNITY" \
            --allow-untrusted \
            add alpine-base linux-lts openrc busybox-openrc \
                ca-certificates curl dhcpcd e2fsprogs iproute2 iptables \
                openssh-server samba samba-common-tools dnsmasq \
                bash mkinitfs nano htop tzdata grub grub-efi efibootmgr

        mkdir -p /mnt/rootfs/etc/apk
        echo "$REPO" >  /mnt/rootfs/etc/apk/repositories
        echo "$COMMUNITY" >> /mnt/rootfs/etc/apk/repositories
        echo "$ALPINE_ARCH" > /mnt/rootfs/etc/apk/arch

        cp -a /stage/. /mnt/rootfs/
        cp /etc/resolv.conf /mnt/rootfs/etc/resolv.conf 2>/dev/null || true

        for d in proc sys dev dev/pts; do
            mkdir -p /mnt/rootfs/$d
            mount --bind /$d /mnt/rootfs/$d
        done

        cp /setup.sh /mnt/rootfs/setup.sh
        chmod +x /mnt/rootfs/setup.sh
        chroot /mnt/rootfs /setup.sh
        rm /mnt/rootfs/setup.sh

        ROOT_UUID=$(blkid -s UUID -o value "${LOOP}p2")
        mkdir -p /mnt/rootfs/boot/grub
        cat > /mnt/rootfs/boot/grub/grub.cfg <<CFG
set timeout=3
set default=0
menuentry "Bootimus Appliance" {
    linux /boot/vmlinuz-lts root=UUID=$ROOT_UUID rw quiet modules=sd-mod,usb-storage,ext4
    initrd /boot/initramfs-lts
}
CFG

        chroot /mnt/rootfs mkinitfs $(ls /mnt/rootfs/lib/modules/ | head -1)

        chroot /mnt/rootfs grub-install \
            --target="$GRUB_TARGET" \
            --efi-directory=/boot/efi \
            --boot-directory=/boot \
            --removable \
            --no-nvram

        sync
        for d in dev/pts dev sys proc; do
            umount /mnt/rootfs/$d
        done
        umount /mnt/rootfs/boot/efi
        umount /mnt/rootfs
        losetup -d "$LOOP"
        trap - EXIT

        echo "Built $IMG ($(du -h "$IMG" | cut -f1))"
    '

RAW_SIZE=$(du -b "$BUILD_DIR/$IMAGE_NAME" | cut -f1)
if [ "$RAW_SIZE" -lt 100000000 ]; then
    echo "ERROR: built image is only $(du -h "$BUILD_DIR/$IMAGE_NAME" | cut -f1) — build failed silently."
    rm -f "$BUILD_DIR/$IMAGE_NAME"
    exit 1
fi

echo ""
echo "   Image: $BUILD_DIR/$IMAGE_NAME ($(du -h "$BUILD_DIR/$IMAGE_NAME" | cut -f1))"
echo ""
echo "Flash with Etcher, Rufus, or:"
echo "   sudo dd if=$BUILD_DIR/$IMAGE_NAME of=/dev/sdX bs=4M conv=fsync status=progress"
