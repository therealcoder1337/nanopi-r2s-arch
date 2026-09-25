#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Run the GitHub Actions workflow locally with act.
#
# Plain act copies only git-tracked files; cache/ is gitignored and is discarded
# each run. --bind mounts the host repo (including gitignored cache/) into the job.
#
# Optional tmpfs (ACT_RAM_MB, default 8192): bind-mounts RAM over mnt/ and output/
# on the host before act — same build-image.sh CI uses, faster I/O. Set ACT_RAM_MB=0
# to disable. Does not change workflow or build scripts.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

mkdir -p cache/arm-trusted-firmware cache/trusted-firmware cache/u-boot cache/u-boot-build cache/rootfs output mnt

EVENT="${ACT_EVENT:-$ROOT/.github/workflows/test-event.json}"
ACT_RAM_MB="${ACT_RAM_MB:-8192}"
RAMDISK="$ROOT/.act-ramdisk"

unmount_lazy() {
    local path="$1"

    if mountpoint -q "$path" 2>/dev/null; then
        sudo umount "$path" 2>/dev/null || sudo umount -l "$path" 2>/dev/null || true
    fi
}

# Idempotent: clear stale binds/tmpfs from a crashed or interrupted prior act run.
prepare_mounts() {
    unmount_lazy "$ROOT/mnt"
    unmount_lazy "$ROOT/output"
    unmount_lazy "$RAMDISK"
}

sync_output_from_ramdisk() {
    if [ ! -d "$RAMDISK/output" ]; then
        return 0
    fi

    mkdir -p "$ROOT/output"

    if [ -n "$(ls -A "$RAMDISK/output" 2>/dev/null)" ]; then
        echo "Syncing build artifacts from tmpfs to output/..."

        if command -v rsync >/dev/null 2>&1; then
            rsync -a "$RAMDISK/output/" "$ROOT/output/"
        else
            cp -a "$RAMDISK/output/." "$ROOT/output/"
        fi
    fi
}

clean_up() {
    unmount_lazy "$ROOT/mnt"
    unmount_lazy "$ROOT/output"

    if mountpoint -q "$RAMDISK" 2>/dev/null; then
        sync_output_from_ramdisk
        unmount_lazy "$RAMDISK"
    fi
}
trap clean_up EXIT

prepare_mounts

if [ "$ACT_RAM_MB" != "0" ]; then
    mkdir -p "$RAMDISK"

    if ! mountpoint -q "$RAMDISK" 2>/dev/null; then
        echo "Mounting ${ACT_RAM_MB} MiB tmpfs at $RAMDISK..."
        sudo mount -t tmpfs -o "size=${ACT_RAM_MB}m" tmpfs "$RAMDISK"
    else
        echo "Reusing existing tmpfs at $RAMDISK"
    fi

    # Subdirs must exist *on the mounted tmpfs*, not before mount (those paths are hidden).
    sudo mkdir -p "$RAMDISK/mnt" "$RAMDISK/output"
    echo "Binding tmpfs over mnt/ and output/ (local act only)..."
    sudo mount --bind "$RAMDISK/mnt" "$ROOT/mnt"
    sudo mount --bind "$RAMDISK/output" "$ROOT/output"
else
    echo "ACT_RAM_MB=0 — repo bind mounts only (slow mke2fs/shrink in act)"
fi

if [ -f cache/rootfs/ArchLinuxARM-aarch64-latest.tar.gz ]; then
    echo "Host cache: rootfs tarball present ($(du -h cache/rootfs/ArchLinuxARM-aarch64-latest.tar.gz | cut -f1))"
else
    echo "Host cache: no rootfs tarball yet (first run will download ~940 MB)"
fi
[ -d cache/arm-trusted-firmware/.git ] && echo "Host cache: TF-A present"
[ -d cache/u-boot/.git ] && echo "Host cache: u-boot present"

act workflow_dispatch \
  -e "$EVENT" \
  --bind \
  --container-options "--privileged -v ${ROOT}/cache:${ROOT}/cache -v ${ROOT}/output:${ROOT}/output" \
  "$@"
