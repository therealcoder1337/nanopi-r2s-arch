# SPDX-License-Identifier: GPL-2.0-or-later
# Shared config and helpers (sourced by build-image.sh).

: "${SCRIPT_DIR:?SCRIPT_DIR must be set before sourcing common.sh}"
: "${SCRIPTS_DIR:?SCRIPTS_DIR must be set before sourcing common.sh}"
: "${TEMPLATES_DIR:?TEMPLATES_DIR must be set before sourcing common.sh}"

CACHE_DIR="${CACHE_DIR:-$SCRIPT_DIR/cache}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/output}"
TFA_DIR="${TFA_DIR:-$CACHE_DIR/arm-trusted-firmware}"
TFA_OUTPUT_DIR="${TFA_OUTPUT_DIR:-$CACHE_DIR/trusted-firmware}"
UBOOT_DIR="${UBOOT_DIR:-$CACHE_DIR/u-boot}"
UBOOT_BUILD_DIR="${UBOOT_BUILD_DIR:-$CACHE_DIR/u-boot-build}"
ROOTFS_CACHE="${ROOTFS_CACHE:-$CACHE_DIR/rootfs}"
TFA_GIT_URL="${TFA_GIT_URL:-https://github.com/ARM-software/arm-trusted-firmware.git}"
TFA_REF="${TFA_REF:-v2.15.0}"
TFA_COMMIT="${TFA_COMMIT:-da738d5eae93af342fdc4995dd3c05acb4c9d757}"
TFA_BUILD_TYPE="${TFA_BUILD_TYPE:-release}"
UBOOT_GIT_URL="${UBOOT_GIT_URL:-https://source.denx.de/u-boot/u-boot.git}"
UBOOT_TAG="${UBOOT_TAG:-v2026.07}"
UBOOT_COMMIT="${UBOOT_COMMIT:-ece349ade2973e220f524ce59e59711cc919263f}"

KERNEL_VARIANT="${KERNEL_VARIANT:-stock}"
case "$KERNEL_VARIANT" in
    stock) IMAGE_PREFIX="nanopi-r2s-arch" ;;
    minimal) IMAGE_PREFIX="nanopi-r2s-arch-minimal-kernel" ;;
    *)
        echo "Error: KERNEL_VARIANT must be stock or minimal" >&2
        exit 1
        ;;
esac
IMAGE_NAME="${IMAGE_NAME:-${IMAGE_PREFIX}-$(date +%Y-%m-%d).img}"
# GitHub release assets must be < 2^31 bytes; 2G is exactly at the limit and upload fails.
IMAGE_SIZE="${IMAGE_SIZE:-1900M}"
# Not HOSTNAME — Docker/GHA set that to the container id (breaks /etc/hostname).
ROOTFS_HOSTNAME="${ROOTFS_HOSTNAME:-nanopi-r2s}"
unset HOSTNAME
PARTITION_OFFSET="${PARTITION_OFFSET:-16MiB}"
BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"

BOOT_SEEK_SECTORS=64
ROOTFS_SEEK_SECTORS=32768
SECTOR_SIZE=512
MAX_BOOT_BYTES=$(((ROOTFS_SEEK_SECTORS - BOOT_SEEK_SECTORS) * SECTOR_SIZE))
BOOT_DTB="rockchip/rk3328-nanopi-r2s.dtb"
TFA_BL31="$TFA_OUTPUT_DIR/bl31-nanopi-r2s.elf"
UBOOT_ROCKCHIP_BIN="$UBOOT_BUILD_DIR/u-boot-rockchip.bin"

SHOULD_ENABLE_RESIZE="${SHOULD_ENABLE_RESIZE:-1}"
SHOULD_SKIP_SLIM="${SHOULD_SKIP_SLIM:-0}"
SHOULD_SKIP_SHRINK="${SHOULD_SKIP_SHRINK:-0}"
SHOULD_SKIP_TFA_REBUILD="${SHOULD_SKIP_TFA_REBUILD:-0}"
SHOULD_SKIP_UBOOT_REBUILD="${SHOULD_SKIP_UBOOT_REBUILD:-0}"

# Arch Linux ARM rootfs (os.archlinuxarm.org). HTTP only; HTTPS fails cert hostname check.
ARCH_IMAGE="ArchLinuxARM-aarch64-latest"
ARCH_OS_BASE="http://os.archlinuxarm.org/os"
ARCH_MD5_URL="${ARCH_OS_BASE}/${ARCH_IMAGE}.tar.gz.md5"
ARCH_ROOTFS_URL="${ARCH_OS_BASE}/${ARCH_IMAGE}.tar.gz"
ARCH_ROOTFS_SIG_URL="${ARCH_OS_BASE}/${ARCH_IMAGE}.tar.gz.sig"
ARCH_SIGNING_KEY_FPR="68B3537F39A313B3E574D06777193F152BDBE6A6"

# Pacman packages required on the Arch build host (also used by CI workflow).
PACMAN_DEPS=(
    aarch64-linux-gnu-gcc
    arch-install-scripts
    base-devel
    dtc
    e2fsprogs
    git
    gnupg
    libarchive
    parted
    python
    python-pyelftools
    python-setuptools
    swig
    util-linux
    wget
)

print_usage() {
    cat <<EOF
Usage: $(basename "${BUILD_SCRIPT:-build-image.sh}") [OPTIONS]

Build a NanoPi R2S Arch Linux ARM SD card image.

Options:
  --print-deps       Print required pacman packages (one per line) and exit
  --shrink-only IMG  Shrink an existing image and write SHA256SUMS
  -h, --help         Show this help

Environment:
  KERNEL_VARIANT          Default: stock (stock|minimal)
  IMAGE_SIZE             Default: 1900M
  ROOTFS_HOSTNAME        Default: nanopi-r2s (image /etc/hostname)
  R2S_KERNEL_REPO_URL     Minimal-kernel pacman repo URL
  R2S_KERNEL_PKGVER       Optional minimal-kernel package version pin

Run as root: sudo $(basename "${BUILD_SCRIPT:-build-image.sh}")
EOF
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "Error: run as root (sudo $(basename "${BUILD_SCRIPT:-build-image.sh}"))" >&2
        exit 1
    fi
}

check_dependencies() {
    echo "[1/10] Checking dependencies..."

    local missing=()
    local pkg

    for pkg in "${PACMAN_DEPS[@]}"; do
        if ! pacman -Q "$pkg" >/dev/null 2>&1; then
            missing+=("$pkg")
        fi
    done

    if [ "${#missing[@]}" -gt 0 ]; then
        echo "Error: missing pacman packages: ${missing[*]}" >&2
        echo "Install: sudo pacman -S ${PACMAN_DEPS[*]}" >&2
        exit 1
    fi

    echo "All dependencies OK."
}

setup_directories() {
    mkdir -p "$CACHE_DIR" "$OUTPUT_DIR" "$ROOTFS_CACHE" "$TFA_DIR" "$TFA_OUTPUT_DIR" "$UBOOT_DIR" "$UBOOT_BUILD_DIR"
    CACHE_DIR="$(cd "$CACHE_DIR" && pwd)"
    OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
    ROOTFS_CACHE="$(cd "$ROOTFS_CACHE" && pwd)"
    TFA_DIR="$(cd "$TFA_DIR" && pwd)"
    TFA_OUTPUT_DIR="$(cd "$TFA_OUTPUT_DIR" && pwd)"
    UBOOT_DIR="$(cd "$UBOOT_DIR" && pwd)"
    UBOOT_BUILD_DIR="$(cd "$UBOOT_BUILD_DIR" && pwd)"

    TFA_BL31="$TFA_OUTPUT_DIR/bl31-nanopi-r2s.elf"
    UBOOT_ROCKCHIP_BIN="$UBOOT_BUILD_DIR/u-boot-rockchip.bin"

    cd "$SCRIPT_DIR"
}

# Partition helpers — loop-free (Docker/act often lacks working /dev/loop*).
get_image_partition_start_bytes() {
    local img="$1"
    parted -s "$img" unit B print | awk '/^ 1 / {print $2}' | tr -d 'B'
}

get_image_partition_size_bytes() {
    local img="$1"
    parted -s "$img" unit B print | awk '/^ 1 / {print $4}' | tr -d 'B'
}

get_image_partition_start_sectors() {
    local img="$1"
    parted -s "$img" unit s print | awk '/^ 1 / {print $2}' | tr -d 's'
}

write_dir_to_image_partition() {
    local img="$1" src="$2"
    local offset size tmp bs seek

    offset=$(get_image_partition_start_bytes "$img")
    size=$(get_image_partition_size_bytes "$img")
    bs=$((4 * 1024 * 1024))

    if [ $((offset % bs)) -ne 0 ]; then
        echo "Error: partition offset ${offset}B is not ${bs}B-aligned" >&2
        exit 1
    fi

    seek=$((offset / bs))
    tmp=$(mktemp -p "$OUTPUT_DIR" .rootfs-ext4.XXXXXXXXXX)
    truncate -s "$size" "$tmp"

    echo "    → Writing ext4 rootfs into image (mke2fs -d, single-threaded — may take 10–30 min)..."
    mke2fs -t ext4 -L rootfs -d "$src" -F "$tmp"

    echo "    → Copying ext4 into disk image (dd bs=4M)..."
    dd if="$tmp" of="$img" bs="$bs" seek="$seek" conv=notrunc status=progress

    rm -f "$tmp"
}

print_build_summary() {
    local img="$OUTPUT_DIR/$IMAGE_NAME"
    echo ""
    echo "Image: $img ($(stat -c%s "$img" | numfmt --to=iec-i --suffix=B 2>/dev/null || stat -c%s "$img"))"
    echo ""
    echo "Flash (confirm device — override with FLASH_DEV=...):"
    echo "  sudo dd if=$img of=\${FLASH_DEV:-/dev/sdX} bs=4M status=progress conv=fsync"
    echo ""
    echo "Serial: ttyS2 @ 1500000 baud"
    echo "Boot: mainline U-Boot TPL/SPL + TF-A $TFA_REF BL31 + U-Boot $UBOOT_TAG"
}
