#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail

# NanoPi R2S Arch Linux ARM image builder.
# Boot chain: mainline U-Boot TPL/SPL + TF-A BL31 + U-Boot proper.

BUILD_SCRIPT="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd "$(dirname "$BUILD_SCRIPT")" && pwd)"
SCRIPTS_DIR="$SCRIPT_DIR/scripts"
TEMPLATES_DIR="$SCRIPTS_DIR/templates"

source "$SCRIPTS_DIR/common.sh"
source "$SCRIPTS_DIR/chroot.sh"
source "$SCRIPTS_DIR/kernel.sh"
source "$SCRIPTS_DIR/trusted-firmware.sh"
source "$SCRIPTS_DIR/bootloader.sh"
source "$SCRIPTS_DIR/rootfs.sh"
source "$SCRIPTS_DIR/postprocess.sh"

run_build() {
    require_root
    setup_directories
    trap unmount_chroot_root EXIT
    check_dependencies
    build_trusted_firmware
    build_uboot
    verify_bootloader_artifacts
    create_image_file
    create_partition_table
    write_bootloader
    download_and_verify_rootfs
    extract_and_configure
    add_resize_service

    local img="$OUTPUT_DIR/$IMAGE_NAME"
    if [ "$SHOULD_SKIP_SHRINK" != "1" ]; then
        shrink_image "$img"
    fi
    inspect_image
    write_checksums "$img"
    print_build_summary
}

case "${1:-}" in
    --print-deps)
        printf '%s\n' "${PACMAN_DEPS[@]}"
        exit 0
        ;;
    --shrink-only)
        shift
        [ "${1:-}" ] || { echo "Error: --shrink-only requires image path" >&2; exit 1; }
        shrink_only "$1"
        exit 0
        ;;
    -h|--help)
        print_usage
        exit 0
        ;;
    "")
        run_build
        ;;
    *)
        echo "Unknown option: $1" >&2
        print_usage >&2
        exit 1
        ;;
esac
