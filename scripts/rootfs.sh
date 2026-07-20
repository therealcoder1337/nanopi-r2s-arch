# SPDX-License-Identifier: GPL-2.0-or-later
# Arch Linux ARM rootfs download, configuration, and first-boot resize.

get_arch_rootfs_md5() {
    if [ -n "${ARCH_ROOTFS_MD5:-}" ]; then
        echo "$ARCH_ROOTFS_MD5"
        return 0
    fi
    wget -qO- "$ARCH_MD5_URL" | awk '{print $1}'
}

verify_arch_rootfs_md5() {
    local tarball="$1" expected="$2" actual

    actual=$(md5sum "$tarball" | awk '{print $1}')
    if [ "$actual" != "$expected" ]; then
        echo "Error: tarball MD5 mismatch (expected $expected, got $actual)" >&2
        exit 1
    fi

    echo "    MD5 valid ($expected)"
}

has_matching_rootfs_tarball_md5() {
    local tarball="$1" expected="$2" actual

    [ -f "$tarball" ] || return 1

    actual=$(md5sum "$tarball" | awk '{print $1}')
    [ "$actual" = "$expected" ]
}

download_and_verify_rootfs() {
    echo "[7/10] Downloading Arch Linux ARM rootfs..."
    local tarball="$ROOTFS_CACHE/${ARCH_IMAGE}.tar.gz" expected
    local sig="$ROOTFS_CACHE/${ARCH_IMAGE}.tar.gz.sig"
    local keyring="$SCRIPT_DIR/vendor/alarmsigning.gpg"

    [ -f "$keyring" ] || {
        echo "Error: missing $keyring" >&2
        exit 1
    }

    expected=$(get_arch_rootfs_md5)
    if ! [[ "$expected" =~ ^[[:xdigit:]]{32}$ ]]; then
        echo "Error: invalid Arch rootfs MD5 from $ARCH_MD5_URL: $expected" >&2
        exit 1
    fi
    expected="${expected,,}"

    if [ -f "$tarball" ] && [ -f "$sig" ] && has_matching_rootfs_tarball_md5 "$tarball" "$expected"; then
        echo "    → Using cached rootfs tarball ($(basename "$tarball"), MD5 $expected)"
    else
        echo "    → Fetching tarball and signature..."
        wget --progress=dot:giga -O "$tarball" "$ARCH_ROOTFS_URL"
        wget --progress=dot:giga -O "$sig" "$ARCH_ROOTFS_SIG_URL"
    fi

    echo "    → Verifying signature ($ARCH_SIGNING_KEY_FPR)..."
    if gpgv --keyring "$keyring" "$sig" "$tarball" >/dev/null 2>&1; then
        echo "    Signature valid"
    else
        echo "    Signature verification FAILED" >&2
        exit 1
    fi

    echo "    → Verifying MD5 against $ARCH_MD5_URL..."
    verify_arch_rootfs_md5 "$tarball" "$expected"
}

slim_rootfs() {
    if [ "$SHOULD_SKIP_SLIM" = "1" ]; then
        echo "    → Skipping firmware slim (SHOULD_SKIP_SLIM=1)"
        return 0
    fi

    echo "    → Slimming firmware packages..."
    local -a fw_pkgs=(linux-firmware-whence linux-firmware-realtek)
    local has_slimmed_firmware=0

    set_chroot_resolver

    if ! run_chroot_pacman -Sy; then
        echo "       Warning: pacman -Sy failed; leaving full linux-firmware"
        return 0
    fi

    if ! run_chroot_pacman -Sw "${fw_pkgs[@]}"; then
        echo "       Warning: prefetch failed; leaving full linux-firmware"
        return 0
    fi

    if ! run_chroot_pacman_no_hooks -Rns linux-firmware; then
        echo "       Warning: could not remove linux-firmware meta"
        return 0
    fi

    if run_chroot_pacman_no_hooks -S "${fw_pkgs[@]}"; then
        has_slimmed_firmware=1
    else
        echo "       Warning: slim install failed; restoring linux-firmware"
        run_chroot_pacman_no_hooks -S linux-firmware || true
    fi

    run_chroot_mkinitcpio
    run_chroot_pacman -Scc 2>/dev/null || run_chroot_pacman -Sc

    if [ "$has_slimmed_firmware" -eq 1 ]; then
        sed -i "/^\[options\]$/a # Keep heavy GPU/WiFi firmware splits off this router image.\nIgnorePkg = linux-firmware linux-firmware-nvidia linux-firmware-amdgpu linux-firmware-radeon linux-firmware-intel linux-firmware-mediatek linux-firmware-broadcom linux-firmware-atheros linux-firmware-cirrus" mnt/etc/pacman.conf
        echo "       firmware slim OK (realtek + whence)"
    fi
}

verify_boot_files() {
    echo "    → Verifying boot files..."

    local missing=()
    local f

    for f in boot/Image boot/initramfs-linux.img boot/uInitrd boot/boot.scr \
             "boot/dtbs/$BOOT_DTB"; do
        [ -f "mnt/$f" ] || missing+=("$f")
    done

    if [ -d mnt/boot/extlinux ]; then
        echo "Error: mnt/boot/extlinux must not exist" >&2
        exit 1
    fi

    if [ "${#missing[@]}" -gt 0 ]; then
        echo "Error: missing boot files: ${missing[*]}" >&2
        exit 1
    fi

    echo "       boot files OK"
}

install_led_service() {
    echo "    → Installing GPIO LED service..."
    install -D -m 0755 "$TEMPLATES_DIR/nanopi-r2s-leds.sh" \
        mnt/usr/local/sbin/nanopi-r2s-leds.sh
    install -D -m 0644 "$TEMPLATES_DIR/nanopi-r2s-leds.service" \
        mnt/etc/systemd/system/nanopi-r2s-leds.service

    mkdir -p mnt/etc/systemd/system/multi-user.target.wants
    ln -sf /etc/systemd/system/nanopi-r2s-leds.service \
        mnt/etc/systemd/system/multi-user.target.wants/nanopi-r2s-leds.service
}

extract_and_configure() {
    local tarball="$ROOTFS_CACHE/${ARCH_IMAGE}.tar.gz"
    local boot_cmd="$TEMPLATES_DIR/boot.cmd"

    if [ ! -f "$boot_cmd" ]; then
        echo "Error: missing template: $boot_cmd" >&2
        exit 1
    fi

    echo "[8/10] Extracting and configuring rootfs..."

    if mountpoint -q mnt 2>/dev/null; then
        unmount_chroot_root
    fi
    rm -rf mnt
    mkdir -p mnt

    echo "    → Extracting rootfs..."
    bsdtar -xpf "$tarball" -C mnt

    mount_chroot_root
    ensure_cross_chroot_binfmt

    echo "$ROOTFS_HOSTNAME" > mnt/etc/hostname

    if [ -f mnt/etc/hosts ]; then
        sed -i '/^127\.0\.1\.1[[:space:]]/d' mnt/etc/hosts
        printf '127.0.1.1\t%s.localdomain\t%s\n' "$ROOTFS_HOSTNAME" "$ROOTFS_HOSTNAME" >> mnt/etc/hosts
    fi

    run_arch_chroot pacman-key --init
    run_arch_chroot pacman-key --populate archlinuxarm

    configure_kernel_variant
    prepare_mkinitcpio_chroot

    if [ "$KERNEL_VARIANT" = "minimal" ]; then
        run_chroot_mkinitcpio
    fi

    slim_rootfs

    echo "    → Wrapping initramfs as uInitrd..."
    "$UBOOT_BUILD_DIR/tools/mkimage" -A arm64 -O linux -T ramdisk -C none \
        -n "Arch Linux ARM initramfs" -d mnt/boot/initramfs-linux.img mnt/boot/uInitrd

    echo "    → Installing boot.scr..."
    install -D -m 0644 "$boot_cmd" mnt/boot/boot.cmd
    "$UBOOT_BUILD_DIR/tools/mkimage" -C none -A arm -T script \
        -d mnt/boot/boot.cmd mnt/boot/boot.scr

    rm -rf mnt/boot/extlinux

    install_led_service
    verify_boot_files
}

add_resize_service() {
    local img="$OUTPUT_DIR/$IMAGE_NAME"

    if [ "$SHOULD_ENABLE_RESIZE" = "1" ]; then
        echo "[9/10] Adding first-boot resize service..."
        install -D -m 0755 "$TEMPLATES_DIR/resize-rootfs.sh" mnt/usr/local/sbin/resize-rootfs.sh
        install -D -m 0644 "$TEMPLATES_DIR/resize-rootfs.service" \
            mnt/etc/systemd/system/resize-rootfs.service

        mkdir -p mnt/etc/systemd/system/multi-user.target.wants
        ln -sf /etc/systemd/system/resize-rootfs.service \
            mnt/etc/systemd/system/multi-user.target.wants/resize-rootfs.service

        echo "    → Installing cloud-utils in image (growpart for first boot)..."
        set_chroot_resolver
        run_chroot_pacman -Sy

        if ! run_chroot_pacman -S cloud-utils; then
            echo "Error: cloud-utils install failed (required for first-boot growpart)" >&2
            exit 1
        fi
    else
        echo "[9/10] Skipping resize service"
    fi

    # Build-time copy only; do not ship the CI/host resolver config on the SD image.
    finalize_image_resolver

    unmount_chroot_root
    write_dir_to_image_partition "$img" mnt
    rm -rf mnt
}
