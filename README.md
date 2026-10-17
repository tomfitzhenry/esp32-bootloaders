# esp32-bootloaders

ESP32 second-stage bootloader binaries, built with Nix.

## Why

The ESP32 bootloader can be built with app rollback support
(`CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE`): when an OTA'd app fails to boot,
the bootloader rolls back to the previous working app instead of bricking
the device.

This repo builds that bootloader reproducibly with Nix, reusing
[nixpkgs-esp-dev](https://github.com/mirrexagon/nixpkgs-esp-dev) for esp-idf
and the toolchains.

Pre-built bootloader tarballs are published to GitHub
[releases](https://github.com/tomfitzhenry/esp32-bootloaders/releases).

## Build

```console
$ nix-build -A bootloader.esp32c3.with-rollback
$ ls result/
bootloader.bin  bootloader.elf  bootloader.map  sdkconfig  sdkconfig.h
```

The bootloader image is flashed at offset `0x0` with probe-rs (over the
chip's built-in USB Serial/JTAG), then the chip is reset:

```console
$ nix-build -A flash.esp32c3.with-rollback
$ ./result/bin/esp32c3-bootloader-with-rollback-flash
```

For an ESP32-S3-WROOM-1-N16R8 (16 MB flash, 8 MB PSRAM), use a `-16mb`
variant. The bootloader advertises the flash size in its image header, so the
4 MB variants are not suitable for that board:

```console
$ nix-build -A bootloader.esp32s3.with-rollback-16mb
$ nix-build -A flash.esp32s3.with-rollback-16mb
```

The PSRAM is initialised by the app, not the second-stage bootloader, so no
bootloader-side PSRAM setting is needed.

## Check

The `check` attribute rebuilds each bootloader from scratch and requires it to
be byte-identical to the stored one, proving the builds are reproducible
(`CONFIG_APP_REPRODUCIBLE_BUILD` removes date/time/path info from the image).
It also sanity-checks the image header: ESP magic byte `0xE9`, a non-empty
segment count, and a flash-size field matching the variant.

```console
$ nix-build -A check.esp32c3.with-rollback --no-out-link
```

## Attributes

Attributes are nested `chip.variant`. Start from the chip you have, then pick
a bootloader variant to try.

| Attribute | Notes |
|-----------|-------|
| `bootloader.<chip>.default` | Stock esp-idf bootloader (rollback off, 4 MB flash) |
| `bootloader.<chip>.with-rollback` | Bootloader with `CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE=y` (4 MB flash) |
| `bootloader.<chip>.default-16mb` | Stock esp-idf bootloader (rollback off, 16 MB flash) |
| `bootloader.<chip>.with-rollback-16mb` | Rollback bootloader for 16 MB flash (e.g. ESP32-S3 N16R8) |
| `check.<chip>.<variant>` | Reproducibility + header check for a variant |
| `tarball.<chip>.<variant>` | `.tar.gz` of a bootloader's artifacts |
| `flash.<chip>.<variant>` | Flash that bootloader via probe-rs |
| `checks` / `tarballs` | Link farms over all of the above, for CI/release |

Chips: `esp32c3`, `esp32c6` (RISC-V), `esp32s3` (Xtensa).
