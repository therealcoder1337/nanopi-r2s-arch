# SPDX-License-Identifier: GPL-2.0-or-later
# Post-build shrink, checksum, and image inspection.

read_image_bytes_at() {
    local img="$1" offset="$2" length="$3"

    dd if="$img" bs=1 skip="$offset" count="$length" status=none 2>/dev/null
}

read_image_hex_at() {
    read_image_bytes_at "$1" "$2" "$3" | od -An -tx1 | tr -d ' \n'
}

inspect_bootloader_region() {
    local img="$1"
    local has_failure=0
    local off size src_hash img_hash strings_out

    off=$((BOOT_SEEK_SECTORS * SECTOR_SIZE))

    if [ ! -f "$UBOOT_ROCKCHIP_BIN" ]; then
        echo "       u-boot-rockchip.bin payload: FAIL (missing source artifact)"
        has_failure=1
    else
        size=$(stat -c%s "$UBOOT_ROCKCHIP_BIN")
        src_hash=$(sha256sum "$UBOOT_ROCKCHIP_BIN" | awk '{print $1}')
        img_hash=$(dd if="$img" bs=4M iflag=skip_bytes,count_bytes \
            skip="$off" count="$size" status=none 2>/dev/null | sha256sum | awk '{print $1}')

        if [ "$src_hash" = "$img_hash" ]; then
            echo "       u-boot-rockchip.bin payload: OK"
        else
            echo "       u-boot-rockchip.bin payload: FAIL"
            has_failure=1
        fi
    fi

    strings_out=$(dd if="$img" bs="$SECTOR_SIZE" skip="$BOOT_SEEK_SECTORS" \
        count="$((ROOTFS_SEEK_SECTORS - BOOT_SEEK_SECTORS))" status=none 2>/dev/null | strings)

    if printf '%s\n' "$strings_out" | grep -q 'U-Boot SPL'; then
        echo "       U-Boot SPL marker: OK"
    else
        echo "       U-Boot SPL marker: not found (non-fatal)"
    fi

    if printf '%s\n' "$strings_out" | grep -q 'TFA BL31'; then
        echo "       TF-A BL31 marker: OK"
    else
        echo "       TF-A BL31 marker: not found (non-fatal)"
    fi

    return "$has_failure"
}

shrink_image() {
    local img="$1"
    echo "Shrinking $img..."

    local offset size tmp part_start fs_sectors margin part_end new_bytes
    offset=$(get_image_partition_start_bytes "$img")
    size=$(get_image_partition_size_bytes "$img")
    part_start=$(get_image_partition_start_sectors "$img")
    tmp=$(mktemp -p "${OUTPUT_DIR:-.}" .shrink-ext4.XXXXXXXXXX)

    echo "    → Extracting rootfs partition..."
    dd if="$img" of="$tmp" bs=4M iflag=skip_bytes,count_bytes skip="$offset" count="$size" status=progress
    e2fsck -f -y "$tmp" >/dev/null

    if ! resize2fs -P "$tmp" >/dev/null 2>&1; then
        echo "Error: could not estimate minimum filesystem size" >&2
        rm -f "$tmp"
        exit 1
    fi
    resize2fs -M "$tmp" >/dev/null

    local blocks block_size device_sectors max_end
    blocks=$(tune2fs -l "$tmp" | awk '/Block count:/ {print $3; exit}')
    block_size=$(tune2fs -l "$tmp" | awk '/Block size:/ {print $3; exit}')

    if [ -z "$blocks" ] || [ -z "$block_size" ]; then
        echo "Error: could not read ext4 size from $tmp" >&2
        rm -f "$tmp"
        exit 1
    fi

    fs_sectors=$(( (blocks * block_size + 511) / 512 ))
    margin=8192
    part_end=$((part_start + fs_sectors + margin))
    device_sectors=$(( $(stat -c%s "$img") / 512 ))
    max_end=$((device_sectors - 1))

    if [ "$part_end" -ge "$max_end" ]; then
        echo "    → Filesystem still fills the partition; keeping ${device_sectors}s image (no shrink)"
        rm -f "$tmp"
        return 0
    fi

    printf 'Yes\n' | parted ---pretend-input-tty "$img" unit s resizepart 1 "${part_end}s"

    echo "    → Writing shrunk rootfs back..."
    dd if="$tmp" of="$img" bs=4M oflag=seek_bytes conv=notrunc seek="$offset" status=progress
    rm -f "$tmp"

    new_bytes=$(( (part_end + 1) * 512 ))
    truncate -s "$new_bytes" "$img"
    echo "    shrunk to $(numfmt --to=iec-i --suffix=B "$new_bytes" 2>/dev/null || echo "${new_bytes} bytes")"
}

write_checksums() {
    local img="$1"
    local sums="$OUTPUT_DIR/SHA256SUMS"

    (cd "$OUTPUT_DIR" && sha256sum "$(basename "$img")") > "$sums"

    echo "    SHA256SUMS written to $sums"
    cat "$sums"
}

inspect_image() {
    local img="$OUTPUT_DIR/$IMAGE_NAME"
    echo "[10/10] Inspecting image..."
    local has_failure=0
    local part_offset
    local sig

    part_offset=$(get_image_partition_start_bytes "$img")

    sig=$(read_image_hex_at "$img" 510 2)
    if [ "$sig" = "55aa" ]; then
        echo "       MBR signature: OK"
    else
        echo "       MBR signature: FAIL"
        has_failure=1
    fi

    if ! inspect_bootloader_region "$img"; then
        has_failure=1
    fi

    local img_path="${img}?offset=${part_offset}"

    if debugfs -R "ls /boot" "$img_path" 2>/dev/null | grep -q boot.scr; then
        echo "       /boot/boot.scr: OK"
    else
        echo "       /boot/boot.scr: FAIL"
        has_failure=1
    fi

    if debugfs -R "stat /boot/dtbs/$BOOT_DTB" "$img_path" 2>/dev/null | grep -q "Inode:"; then
        echo "       /boot/dtbs/$BOOT_DTB: OK"
    else
        echo "       /boot/dtbs/$BOOT_DTB: FAIL"
        has_failure=1
    fi

    if [ "$has_failure" -eq 0 ]; then
        echo "    Image inspection PASSED"
    else
        echo "    Image inspection FAILED" >&2
        exit 1
    fi
}

shrink_only() {
    local img="$1"

    require_root

    if [ ! -f "$img" ]; then
        echo "Error: image not found: $img" >&2
        exit 1
    fi

    setup_directories
    shrink_image "$img"
    write_checksums "$img"
}
