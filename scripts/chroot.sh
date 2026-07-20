# SPDX-License-Identifier: GPL-2.0-or-later
# Chroot helpers for rootfs configuration.

# x86_64 build hosts need binfmt for aarch64 ELFs in arch-chroot. Pacman hooks skip
# systemd-binfmt when the root is not booted (typical Docker/GHA job containers).
ensure_cross_chroot_binfmt() {
    case "$(uname -m)" in
        aarch64) return 0 ;;
    esac

    if [ ! -x /usr/bin/qemu-aarch64-static ]; then
        echo "Error: install qemu-user-static and qemu-user-static-binfmt on the build host" >&2
        return 1
    fi

    if [ ! -f /proc/sys/fs/binfmt_misc/register ]; then
        mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || {
            echo "Error: cannot mount binfmt_misc (container needs --privileged)" >&2
            return 1
        }
    fi

    if [ ! -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
        if [ -x /usr/lib/systemd/systemd-binfmt ]; then
            /usr/lib/systemd/systemd-binfmt
        fi
    fi

    if [ ! -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
        echo "Error: qemu-aarch64 binfmt not registered after systemd-binfmt" >&2
        ls -la /proc/sys/fs/binfmt_misc/ >&2 || true
        return 1
    fi
}

# arch-chroot and pacman require the rootfs directory to be a mountpoint.
mount_chroot_root() {
    mkdir -p mnt/var/cache/pacman/pkg

    if mountpoint -q mnt 2>/dev/null; then
        return 0
    fi

    mount --bind mnt mnt
}

unmount_chroot_root() {
    if ! mountpoint -q mnt 2>/dev/null; then
        return 0
    fi
    umount -R mnt 2>/dev/null || umount -l -R mnt 2>/dev/null || true
}

set_chroot_resolver() {
    rm -f mnt/etc/resolv.conf

    if [ -f /etc/resolv.conf ] && [ ! -L /etc/resolv.conf ]; then
        cp /etc/resolv.conf mnt/etc/resolv.conf
    elif [ -L /etc/resolv.conf ] && [ -f "$(readlink -f /etc/resolv.conf)" ]; then
        cp "$(readlink -f /etc/resolv.conf)" mnt/etc/resolv.conf
    else
        printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > mnt/etc/resolv.conf
    fi
}

finalize_image_resolver() {
    rm -f mnt/etc/resolv.conf

    if [ -e mnt/usr/lib/systemd/resolv.conf ]; then
        ln -sf ../run/systemd/resolve/stub-resolv.conf mnt/etc/resolv.conf
    else
        printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > mnt/etc/resolv.conf
    fi
}

run_arch_chroot() {
    arch-chroot mnt env \
        MAKEFLAGS="-j${BUILD_JOBS}" \
        XZ_THREADS="${BUILD_JOBS}" \
        ZSTD_NBTHREADS="${BUILD_JOBS}" \
        "$@"
}

run_chroot_pacman() {
    run_arch_chroot pacman --disable-sandbox --noconfirm "$@"
}

run_chroot_pacman_no_hooks() {
    local status=0

    disable_chroot_pacman_hooks
    run_chroot_pacman "$@" || status=$?
    enable_chroot_pacman_hooks

    return "$status"
}

disable_chroot_pacman_hooks() {
    run_arch_chroot sh -c '
        for d in /usr/share/libalpm/hooks /etc/pacman.d/hooks; do
            [ -d "$d" ] && [ ! -d "${d}.disabled" ] && mv "$d" "${d}.disabled"
        done
    ' 2>/dev/null || true
}

enable_chroot_pacman_hooks() {
    run_arch_chroot sh -c '
        for d in /usr/share/libalpm/hooks /etc/pacman.d/hooks; do
            [ -d "${d}.disabled" ] && mv "${d}.disabled" "$d"
        done
    ' 2>/dev/null || true
}

prepare_mkinitcpio_chroot() {
    local preset

    for preset in mnt/etc/mkinitcpio.d/*.preset; do
        [ -f "$preset" ] || continue

        if ! grep -q 'nanopi-r2s: no fallback' "$preset" 2>/dev/null; then
            sed -i "s/^PRESETS=.*/PRESETS=('default')  # nanopi-r2s: no fallback (autodetect breaks in cross-chroot)/" \
                "$preset"
        fi
    done
}

get_chroot_latest_kver() {
    ls mnt/usr/lib/modules 2>/dev/null | sort -V | tail -1
}

can_run_chroot_aarch64() {
    run_arch_chroot sh -c '/usr/bin/true' >/dev/null 2>&1
}

run_chroot_mkinitcpio() {
    local kver
    local -a config=()

    kver=$(get_chroot_latest_kver)
    if [ -z "$kver" ]; then
        echo "Error: no kernel modules in chroot" >&2
        return 1
    fi

    if ! can_run_chroot_aarch64; then
        echo "    Warning: aarch64 not runnable in chroot (install qemu-user-static qemu-user-static-binfmt)"
        echo "             keeping initramfs from rootfs tarball"
        return 0
    fi

    echo "    → Regenerating initramfs for ${kver}..."
    run_arch_chroot depmod -a "$kver"

    case "$kver" in
        *-nanopi-r2s-minimal)
            if [ -f mnt/etc/mkinitcpio.linux-nanopi-r2s-minimal.conf ]; then
                config=(-c /etc/mkinitcpio.linux-nanopi-r2s-minimal.conf)
            fi
            ;;
    esac

    if ! run_arch_chroot mkinitcpio -k "$kver" "${config[@]}" -g /boot/initramfs-linux.img; then
        echo "Error: mkinitcpio failed for ${kver}" >&2
        return 1
    fi
}
