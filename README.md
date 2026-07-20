# NanoPi R2S Arch Linux ARM

**Unofficial / community-maintained** Arch Linux ARM SD card images for **FriendlyElec NanoPi R2S** (RK3328).

You can choose between a stock ALARM kernel image and a smaller image using [`linux-nanopi-r2s-minimal`](https://github.com/therealcoder1337/nanopi-r2s-kernel-arch).

The image uses a mainline boot stack with source-built Trusted Firmware-A BL31, mainline U-Boot, the official aarch64 rootfs, and small NanoPi R2S adjustments. Earlier Arch-on-R2S attempts often still relied on Armbian boot pieces or kernels; for example [larsch's gist](https://gist.github.com/larsch/a8f13faa2163984bb945d02efb897e6d) and [sakapoko/archlinux_r2s](https://github.com/sakapoko/archlinux_r2s).

Current builds use mainline U-Boot `v2026.07` and TF-A `v2.15.0`, support stock and minimal-kernel images, verify upstream downloads, and configure the rear GPIO LAN/WAN LEDs at boot.

This is not an official Arch Linux ARM project. For OS-level defaults such as users, passwords, and package management, use the [Arch Linux ARM documentation](https://archlinuxarm.org/).

**Disclaimer:** Images are provided as-is, without warranty of fitness or successful operation on your hardware. Builds follow rolling Arch Linux ARM and upstream updates; behavior may change between releases.

## AI disclosure

Much of this repository was written with AI assistance and refined through iterative review, builds, and hardware testing.

## Images

| Image | Kernel |
|-------|--------|
| `nanopi-r2s-arch-YYYY-MM-DD.img.xz` | Stock Arch Linux ARM `linux-aarch64` |
| `nanopi-r2s-arch-minimal-kernel-YYYY-MM-DD.img.xz` | `linux-nanopi-r2s-minimal` from [`nanopi-r2s-kernel-arch`](https://github.com/therealcoder1337/nanopi-r2s-kernel-arch) |

Both variants use the same bootloader/rootfs process. The minimal-kernel image adds the public pacman repo, trusts the verified repo key, removes the stock kernel, and keeps the repo configured for future kernel updates.

Serial console: `ttyS2` at `1500000` baud. On first boot, the root partition expands to fill the SD card. A small systemd service maps the rear GPIO LAN/WAN LEDs to the detected `r8152` and `rk_gmac-dwmac` network devices; RJ45 jack LEDs are controlled separately by the NIC/PHY drivers.

## Flash

Verify the compressed image:

```bash
sha256sum -c SHA256SUMS
```

Flash one explicit image file:

```bash
xzcat IMAGE.img.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

Replace `/dev/sdX` with the SD card device from `lsblk`.

## Build Locally

Use an Arch Linux host, or an Arch container with enough privileges for `arch-chroot`. Loop devices are not required; the rootfs is staged in a directory and written with `mke2fs -d`.

Install dependencies:

```bash
sudo pacman -S --needed $(./build-image.sh --print-deps)
```

On x86_64 hosts, also install binfmt support so `arch-chroot` can run aarch64 binaries:

```bash
sudo pacman -S --needed qemu-user-static qemu-user-static-binfmt
```

Build the stock image:

```bash
sudo ./build-image.sh
```

Build the minimal-kernel image:

```bash
sudo KERNEL_VARIANT=minimal ./build-image.sh
```

Output is written to `output/`.

Useful environment variables:

| Variable | Default |
|----------|---------|
| `KERNEL_VARIANT` | `stock`; use `minimal` for `linux-nanopi-r2s-minimal` |
| `R2S_KERNEL_REPO_URL` | public `nanopi-r2s-kernel-arch` pacman repo |
| `R2S_KERNEL_PKGVER` | latest repo version |
| `IMAGE_SIZE` | `1900M` |
| `ROOTFS_HOSTNAME` | `nanopi-r2s` |

Shrink an existing image:

```bash
sudo ./build-image.sh --shrink-only output/IMAGE.img
```

## CI

- `build-image.yml` builds both stock and minimal-kernel images from workflow dispatch.
- `check-arch.yml` checks the Arch Linux ARM rootfs MD5 and triggers a build of both images when it changes.
- Release artifacts include image `.xz` file(s), `SHA256SUMS`, `LICENSE`, `LICENSE_GPL-2.0-or-later.txt`, `NOTICE`, `LICENSE_TFA.txt`, `SOURCE_INFO_TFA.txt`, `SOURCE_OFFER_U_BOOT.txt`, and `SOURCE_INFO_R2S_KERNEL.txt`.

CI caches TF-A, U-Boot, and the rootfs tarball. Scheduled builds publish both stock and minimal-kernel images. Manual branch builds publish test prereleases. Release/artifact files must stay below GitHub's 2 GiB per-file limit, so the raw image defaults to `1900M`.

For local workflow testing with [act](https://github.com/nektos/act):

```bash
./scripts/act-build.sh
```

The wrapper uses `act --bind` so gitignored `cache/` persists between runs. Plain `act workflow_dispatch` re-downloads everything.

## Layout

```
build-image.sh
scripts/
  common.sh             # config, deps, image helpers
  trusted-firmware.sh   # TF-A BL31 build
  bootloader.sh         # U-Boot build, bootloader writes
  chroot.sh             # arch-chroot helpers
  kernel.sh             # optional minimal-kernel variant
  rootfs.sh             # rootfs download/configuration
  postprocess.sh        # inspect, shrink, checksums
```

## Contributing

Issues and pull requests are welcome. Please keep changes focused, test image-building changes locally with `./scripts/act-build.sh` when practical, and mention whether hardware testing was done.

## Credits

The image uses Trusted Firmware-A, U-Boot, Arch Linux ARM packages, and optionally `linux-nanopi-r2s-minimal`; see [NOTICE](NOTICE), [LICENSE_TFA.txt](LICENSE_TFA.txt), [SOURCE_INFO_TFA.txt](SOURCE_INFO_TFA.txt), and [SOURCE_OFFER_U_BOOT.txt](SOURCE_OFFER_U_BOOT.txt).

## License

Builder scripts: GPL-2.0-or-later; see [LICENSE](LICENSE) and the full text in `LICENSE_GPL-2.0-or-later.txt`. Released images are combined works; see [NOTICE](NOTICE).
