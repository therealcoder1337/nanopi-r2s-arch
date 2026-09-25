# SPDX-License-Identifier: GPL-2.0-or-later
# U-Boot build and mainline Rockchip boot image layout.

run_git_uboot() {
    git -C "$UBOOT_DIR" -c safe.directory="$UBOOT_DIR" "$@"
}

checkout_uboot_tag() {
    run_git_uboot fetch --force --depth 1 origin \
        "+refs/tags/${UBOOT_TAG}:refs/tags/${UBOOT_TAG}"
    run_git_uboot checkout --detach "$UBOOT_TAG" >/dev/null
    run_git_uboot reset --hard "$UBOOT_TAG" >/dev/null
    run_git_uboot clean -fdx >/dev/null
}

verify_uboot_release_tag() {
    local gpg_home gpg_wrapper keyring="$SCRIPT_DIR/vendor/u-boot-release.gpg"
    local has_gpg_error=0

    gpg_home=$(mktemp -d)
    gpg_wrapper=$(mktemp)
    chmod 700 "$gpg_home"

    if ! gpg --homedir "$gpg_home" --no-autostart --batch --import "$keyring" >/dev/null 2>&1; then
        echo "Error: could not load $keyring" >&2
        has_gpg_error=1
    else
        printf '#!/bin/sh\nexec gpg --homedir %s --no-autostart "$@"\n' "$gpg_home" >"$gpg_wrapper"
        chmod +x "$gpg_wrapper"
    fi

    if [ "$has_gpg_error" -eq 0 ] && ! run_git_uboot -c "gpg.program=$gpg_wrapper" tag -v "$UBOOT_TAG" >/dev/null 2>&1; then
        echo "Error: U-Boot tag $UBOOT_TAG signature check failed" >&2
        has_gpg_error=1
    fi

    rm -f "$gpg_wrapper"
    rm -rf "$gpg_home"

    return "$has_gpg_error"
}

fetch_uboot_tree() {
    local head tag_commit

    if [ -d "$UBOOT_DIR/.git" ]; then
        head=$(run_git_uboot rev-parse -q HEAD 2>/dev/null) || head=
        tag_commit=$(run_git_uboot rev-list -n1 "$UBOOT_TAG" 2>/dev/null) || tag_commit=

        if [ -z "$tag_commit" ] || [ "$head" != "$tag_commit" ]; then
            echo "    -> Updating U-Boot to $UBOOT_TAG..."
            checkout_uboot_tag
        else
            echo "    -> Using cached U-Boot: $UBOOT_DIR ($UBOOT_TAG @ ${head:0:12})"
            run_git_uboot reset --hard "$UBOOT_TAG" >/dev/null
            run_git_uboot clean -fdx >/dev/null
        fi
    else
        echo "    -> Cloning U-Boot $UBOOT_TAG..."
        git init -q "$UBOOT_DIR"
        run_git_uboot remote add origin "$UBOOT_GIT_URL"
        checkout_uboot_tag
    fi

    verify_uboot_release_tag

    head=$(run_git_uboot rev-parse -q HEAD)
    if [ "$head" != "$UBOOT_COMMIT" ]; then
        echo "Error: U-Boot HEAD ${head:0:12}, expected ${UBOOT_COMMIT:0:12} ($UBOOT_TAG)." >&2
        exit 1
    fi
}

get_uboot_build_tag() {
    {
        printf '%s\n' "$UBOOT_COMMIT"
        sha256sum "$TFA_BL31" "$SCRIPTS_DIR/bootloader.sh" \
            "$SCRIPT_DIR"/vendor/patches/u-boot/*.patch
    } | sha256sum | awk '{print $1}'
}

has_current_uboot_build() {
    local tag_file="$UBOOT_BUILD_DIR/.build-tag"
    [ -f "$UBOOT_ROCKCHIP_BIN" ] \
        && [ -x "$UBOOT_BUILD_DIR/tools/mkimage" ] \
        && [ -f "$tag_file" ] \
        && [ "$(cat "$tag_file")" = "$(get_uboot_build_tag)" ]
}

build_uboot() {
    echo "[3/10] U-Boot ($UBOOT_TAG)..."
    fetch_uboot_tree

    if [ ! -f "$TFA_BL31" ]; then
        echo "Error: missing TF-A BL31: $TFA_BL31" >&2
        exit 1
    fi

    if [ "$SHOULD_SKIP_UBOOT_REBUILD" = 1 ] && has_current_uboot_build; then
        echo "    -> Skipping U-Boot rebuild (SHOULD_SKIP_UBOOT_REBUILD=1)"
        return 0
    fi

    echo "    -> Applying U-Boot build compatibility patches..."
    run_git_uboot apply "$SCRIPT_DIR"/vendor/patches/u-boot/*.patch

    echo "    -> Building U-Boot..."
    rm -rf "$UBOOT_BUILD_DIR"
    make -C "$UBOOT_DIR" O="$UBOOT_BUILD_DIR" nanopi-r2s-rk3328_defconfig >/dev/null
    make -C "$UBOOT_DIR" O="$UBOOT_BUILD_DIR" -j"$BUILD_JOBS" \
        CROSS_COMPILE=aarch64-linux-gnu- BL31="$TFA_BL31"

    if [ ! -f "$UBOOT_ROCKCHIP_BIN" ]; then
        echo "Error: U-Boot did not produce $UBOOT_ROCKCHIP_BIN" >&2
        exit 1
    fi

    get_uboot_build_tag > "$UBOOT_BUILD_DIR/.build-tag"
}

verify_bootloader_artifacts() {
    local size artifact

    size=$(stat -c%s "$UBOOT_ROCKCHIP_BIN")
    echo "    -> Boot image: $(basename "$UBOOT_ROCKCHIP_BIN") ($size bytes)"

    if [ "$size" -le 0 ] || [ "$size" -gt "$MAX_BOOT_BYTES" ]; then
        echo "Error: u-boot-rockchip.bin is $size bytes; max before rootfs is $MAX_BOOT_BYTES bytes" >&2
        exit 1
    fi

    if [ ! -x "$UBOOT_BUILD_DIR/tools/mkimage" ]; then
        echo "Error: missing U-Boot mkimage: $UBOOT_BUILD_DIR/tools/mkimage" >&2
        exit 1
    fi

    for artifact in idbloader.img u-boot.itb spl/u-boot-spl.bin tpl/u-boot-tpl.bin; do
        if [ -f "$UBOOT_BUILD_DIR/$artifact" ]; then
            echo "       $artifact: $(stat -c%s "$UBOOT_BUILD_DIR/$artifact") bytes"
        fi
    done
}

create_image_file() {
    local img="$OUTPUT_DIR/$IMAGE_NAME"
    echo "[4/10] Creating image file ($IMAGE_SIZE)..."
    dd if=/dev/zero of="$img" bs=1 count=0 seek="$IMAGE_SIZE" status=none
}

create_partition_table() {
    local img="$OUTPUT_DIR/$IMAGE_NAME"
    echo "[5/10] Creating partition table..."
    parted -s "$img" mklabel msdos
    parted -s "$img" mkpart primary ext4 "$PARTITION_OFFSET" 100%
}

write_bootloader() {
    local img="$OUTPUT_DIR/$IMAGE_NAME"
    echo "[6/10] Writing bootloader..."
    dd if="$UBOOT_ROCKCHIP_BIN" of="$img" seek="$BOOT_SEEK_SECTORS" \
        conv=notrunc bs="$SECTOR_SIZE" status=none
}
