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

It also builds [MCUboot](https://docs.mcuboot.com/) v2.4.0 bootloaders for the
same chips, with A/B swapping and rollback. See [MCUboot](#mcuboot) below.

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

Each chip has one fixed flash size matching its board: `esp32c3` and
`esp32c6` are 4 MB, and `esp32s3` is 16 MB (the ESP32-S3-WROOM-1-N16R8). The
flash size is baked into the bootloader image header, so it is not a variant
dimension. For the N16R8:

```console
$ nix-build -A bootloader.esp32s3.with-rollback
$ nix-build -A flash.esp32s3.with-rollback
```

The PSRAM is initialised by the app, not the second-stage bootloader, so no
bootloader-side PSRAM setting is needed.

## Check

The `check` attribute rebuilds each bootloader from scratch and requires it to
be byte-identical to the stored one, proving the builds are reproducible
(`CONFIG_APP_REPRODUCIBLE_BUILD` removes date/time/path info from the image).
It also sanity-checks the image header: ESP magic byte `0xE9`, a non-empty
segment count, and a flash-size field matching the chip.

```console
$ nix-build -A check.esp32c3.with-rollback --no-out-link
```

## MCUboot

These are [MCUboot](https://docs.mcuboot.com/) v2.4.0 bootloaders built against
ESP-IDF v5.1.6, the exact version required by MCUboot's Espressif port. Each
chip has a single fixed target matching the board this project supports:
`mcuboot.esp32c3` and `mcuboot.esp32c6` use 4 MB flash, while
`mcuboot.esp32s3` uses 16 MB.

MCUboot reuses the project's nixpkgs and nixpkgs-esp-dev pins; `mcuboot.nix`
overrides ESP-IDF to v5.1.6 (and trims the tool list, since MCUboot does not
need GDB). `default.nix` only imports it, passing the package sets and the
shared flash-size table.

```console
$ nix-build -A mcuboot.esp32c3
$ ls result/
mcuboot.conf  mcuboot_esp32c3.bin  mcuboot_esp32c3.elf  mcuboot_esp32c3.map

$ nix-build -A mcubootCheck.esp32c3 --no-out-link
$ nix-build -A mcubootTarball.esp32c3
$ tar -tzf result
mcuboot_esp32c3.bin
mcuboot_esp32c3.elf
mcuboot_esp32c3.map
mcuboot.conf

$ nix-build -A mcubootFlash.esp32c3
$ ./result/bin/esp32c3-mcuboot-flash
```

The check rebuilds MCUboot from scratch and compares the `.bin`, `.elf`, and
`.map` byte-for-byte, then verifies the ESP image header (magic `0xE9`, segment
count, and flash-size nibble). It also greps for the `MCUboot` banner as a
sanity check that the Espressif port compiled; this is not a pin check, since
the version string is injected locally.

Slot layout:

| Region | ESP32-C3/C6 address | ESP32-S3 address | Size |
|--------|---------------------|------------------|------|
| Bootloader | `0x0` | `0x0` | `0xF000` |
| Primary app slot | `0x20000` | `0x20000` | `0x1C0000` (C3/C6), `0x150000` (S3) |
| Secondary app slot | `0x1E0000` | `0x170000` | same as primary |
| Scratch | `0x3E0000` | `0x3E0000` | `0x1F000` |

The slot size is the usable image area, not the next slot's address. These are
MCUboot's stock addresses for the Espressif port.

Defaults and caveats:

- **Partition tables.** MCUboot does not read the ESP-IDF partition table. Any
  partition table or other data you flash must stay outside the `0x0`-`0xF000`
  bootloader reservation and the MCUboot regions at `0x20000` and above. In
  particular, the ESP-IDF default partition table at `0x8000` conflicts with
  the MCUboot bootloader reservation and must be relocated (or omitted).
- **Unsigned by default.** The stock configuration does no signature
  verification; it only checks the image SHA-256, so it protects against
  corruption but not against an attacker who can write the flash. Because it
  ignores signatures, `imgtool sign --key ...` has no effect on whether the
  bootloader accepts an image until signature verification is enabled below.
  Sign app images with [`imgtool`](https://docs.mcuboot.com/imgtool.html)
  (use `0x1C0000` as the slot size for ESP32-C3/C6 and `0x150000` for
  ESP32-S3):

  ```console
  $ imgtool sign --key key.pem --pad --pad-sig --align 4 \
      --version 1.0.0+0 --header-size 32 --pad-header \
      --slot-size 0x1C0000 app.bin app-signed.bin
  ```

- **Enabling signature verification.** Set `mcubootExtraConfig` in
  `mcuboot.nix` to append configuration lines to every MCUboot target; later
  lines override the port's defaults. For example, for EC256:

  ```nix
  mcubootExtraConfig = ''
    CONFIG_ESP_SIGN_EC256=y
    CONFIG_ESP_USE_TINYCRYPT=y
    CONFIG_ESP_SIGN_KEY_FILE=${./my-key.pem}
  '';
  ```

  `${./my-key.pem}` copies the key into the Nix store, which is the only path
  visible inside the build sandbox; absolute host paths do not exist there.
  EC256 and ED25519 both require `CONFIG_ESP_USE_TINYCRYPT=y`. For RSA use
  `CONFIG_ESP_SIGN_RSA=y`, `CONFIG_ESP_USE_MBEDTLS=y`, and
  `CONFIG_ESP_SIGN_RSA_LEN=3072` (or `2048`) instead. The Espressif port
  embeds the matching public key in the bootloader; sign images with the
  corresponding private key.
- **The ESP32-S3 target's 16 MB setting only changes the header.**
  `mcuboot.esp32s3` sets `CONFIG_ESP_FLASH_SIZE=16MB`, which changes the ESP
  image flash-size field and the trailing image digest. The slot layout is
  unchanged.
- **Erase the secondary slot and scratch before first use.** MCUboot treats
  trailer sectors as state; garbage or unknown trailer data can be misread as
  valid state. Erase the secondary slot and scratch (a full chip erase is
  fine) before first use.
- **ESP32-C6 uses virtual eFuses in flash.** Upstream's stock C6 config sets
  `CONFIG_EFUSE_VIRTUAL=1` at `0x10000` with size `0x2000`, which uses real
  flash in the gap between the bootloader and the primary slot.
- **The flash script writes only the bootloader.** The application must be
  signed with `imgtool` and flashed separately as an MCUboot image at the
  primary slot address.

## Attributes

ESP-IDF bootloader attributes are nested `chip.variant`; MCUboot attributes
are keyed by chip. Start from the chip you have, then pick a variant or target
to try.

| Attribute | Notes |
|-----------|-------|
| `bootloader.<chip>.default` | Stock esp-idf bootloader (rollback off) |
| `bootloader.<chip>.with-rollback` | Bootloader with `CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE=y` |
| `check.<chip>.<variant>` | Reproducibility + header check for a variant |
| `tarball.<chip>.<variant>` | `.tar.gz` of a bootloader's artifacts |
| `flash.<chip>.<variant>` | Flash that bootloader via probe-rs |
| `mcuboot.<chip>` | MCUboot v2.4.0 bootloader (unsigned, swap-using-scratch) |
| `mcubootCheck.<chip>` | Reproducibility + header check for the MCUboot target |
| `mcubootTarball.<chip>` | `.tar.gz` of the MCUboot target's artifacts and effective config |
| `mcubootFlash.<chip>` | Flash an MCUboot bootloader via probe-rs |
| `checks` / `tarballs` | Link farms over all of the above, for CI/release |

Chips: `esp32c3`, `esp32c6` (RISC-V), `esp32s3` (Xtensa). Flash sizes are fixed
per chip: 4 MB for `esp32c3`/`esp32c6`, 16 MB for `esp32s3`. MCUboot targets:
`esp32c3` (4 MB), `esp32c6` (4 MB), `esp32s3` (16 MB).
