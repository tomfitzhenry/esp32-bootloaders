let
  # Pin nixpkgs to the revision nixpkgs-esp-dev's flake.lock uses.  esp-idf's
  # tooling still needs python310, which newer nixpkgs dropped.
  #
  # nixpkgs-esp-dev PR #126 ("tools: python3 only") removes the python310
  # requirement; once it lands we can unpin this to current nixpkgs.
  # https://github.com/mirrexagon/nixpkgs-esp-dev/pull/126
  nixpkgs = builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/d351d0653aeb7877273920cd3e823994e7579b0b.tar.gz";
    sha256 = "sha256-r4GVX+FToWVE2My8VVZH4V0pTIpnu2ZE8/Z4uxGEMBE=";
  };

  nativePkgs = import nixpkgs {
    # The Python library ecdsa is marked insecure, but esptool needs it.
    # See https://github.com/mirrexagon/nixpkgs-esp-dev/issues/109
    config.permittedInsecurePackages = [
      "python3.13-ecdsa-0.19.1"
    ];
  };

  # nixpkgs-esp-dev provides esp-idf and the toolchains.
  espDev = nativePkgs.fetchFromGitHub {
    owner = "mirrexagon";
    repo = "nixpkgs-esp-dev";
    rev = "5287d6e1ca9e15ebd5113c41b9590c468e1e001b";
    sha256 = "sha256-QWF1rZYd+HvNzLIeRS+OEBX7HF0EhWCGeLbMkgtbsIo=";
  };

  espPkgs = import "${espDev}/default.nix" { pkgs = nativePkgs; };

  # The ESP-IDF project that builds just the second-stage bootloader.
  project = ./bootloader-project;

  # Chips we build bootloaders for.  Each carries the esp-idf package with
  # the right toolchain and its board's flash size.
  #
  # The flash size is baked into the bootloader image header, so it must match
  # the board: picoprog's ESP32-C3 and the ESP32-C6 have 4 MB, and the
  # ESP32-S3-WROOM-1-N16R8 has 16 MB.  ESP-IDF defaults to 2 MB, which would
  # mismatch every supported board and its app images.
  #
  # PSRAM (the R8 on an N16R8) is initialised by the app, not this
  # second-stage bootloader, so it needs no bootloader-side configuration.
  chips = {
    esp32c3 = {
      idf = espPkgs.esp-idf-riscv;
      flashSize = "4MB";
    };
    esp32c6 = {
      idf = espPkgs.esp-idf-riscv;
      flashSize = "4MB";
    };
    esp32s3 = {
      idf = espPkgs.esp-idf-xtensa;
      flashSize = "16MB";
    };
  };

  # Bootloader variants.  `default` is the stock esp-idf bootloader (rollback
  # off); `with-rollback` enables CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE.
  #
  # CONFIG_APP_REPRODUCIBLE_BUILD eliminates date/time/path info from the
  # image (it also turns off CONFIG_BOOTLOADER_COMPILE_TIME_DATE), so the same
  # source builds byte-identically at any time.
  mkVariant = rollback: {
    inherit rollback;
  };

  # esp_image_flash_size_t values, as encoded in the bootloader image header.
  # https://github.com/espressif/esp-idf/blob/v5.5.2/components/bootloader_support/include/esp_app_format.h
  flashSizeNibbles = {
    "1MB" = 0;
    "2MB" = 1;
    "4MB" = 2;
    "8MB" = 3;
    "16MB" = 4;
    "32MB" = 5;
    "64MB" = 6;
    "128MB" = 7;
  };

  variants = {
    default = mkVariant false;
    with-rollback = mkVariant true;
  };

  # The idf.py commands that build the bootloader into ./build.  Shared by the
  # bootloader derivation and the reproducibility check.
  idfBuild = chip: variantCfg: chipCfg: ''
    cat > sdkconfig.defaults <<EOF
    CONFIG_APP_REPRODUCIBLE_BUILD=y
    CONFIG_ESPTOOLPY_FLASHSIZE_${chipCfg.flashSize}=y
    CONFIG_ESPTOOLPY_FLASHSIZE="${chipCfg.flashSize}"
    ${
      if variantCfg.rollback
      then "CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE=y"
      else "# CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE is not set"
    }
    EOF

    # The build wants a writable cache dir under $HOME.
    mkdir temp-home
    export HOME=$(readlink -f temp-home)

    # idf-component-manager wants network access; disable it.
    export IDF_COMPONENT_MANAGER=0

    idf.py --preview set-target ${chip}
    export NINJAFLAGS=-v
    idf.py bootloader
  '';

  # Build the bootloader for a chip with the given sdkconfig.defaults.
  #
  # `idf.py bootloader` builds only the bootloader subproject; no app is
  # needed.  The bootloader reads the same sdkconfig as the (empty) app
  # project, so Kconfig options like CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE
  # are applied.
  mkBootloader = chip: variant: variantCfg: chipCfg:
    nativePkgs.stdenv.mkDerivation {
      name = "${chip}-bootloader-${variant}";
      src = project;
      buildInputs = [ chipCfg.idf ];
      phases = [ "buildPhase" ];

      buildPhase = ''
        cp -r $src/* .
        chmod -R +w .

        ${idfBuild chip variantCfg chipCfg}

        mkdir -p $out
        cp build/bootloader/bootloader.bin $out/
        cp build/bootloader/bootloader.elf $out/
        cp build/bootloader/bootloader.map $out/
        cp build/bootloader/config/sdkconfig.h $out/sdkconfig.h
        cp sdkconfig $out/sdkconfig
      '';
    };

  # Nested attrset: chips.<chip>.<variant> -> derivation.
  bootloader = builtins.mapAttrs (chip: chipCfg:
    builtins.mapAttrs (variant: variantCfg: mkBootloader chip variant variantCfg chipCfg) variants) chips;

  mkTarball = name: bootloader:
    nativePkgs.runCommand "${name}.tar.gz" {
      nativeBuildInputs = [ nativePkgs.gnutar ];
    } ''
      tar -czf "$out" -C "${bootloader}" \
        bootloader.bin bootloader.elf bootloader.map sdkconfig sdkconfig.h
    '';

  tarball = builtins.mapAttrs (chip: _:
    builtins.mapAttrs (variant: _: mkTarball "${chip}-bootloader-${variant}" bootloader.${chip}.${variant}) variants) chips;

  # Rebuild the bootloader now, and require it to be byte-identical to the
  # previously-built one in the store.  With CONFIG_APP_REPRODUCIBLE_BUILD the
  # image has no date/time/path info, so this must hold.
  mkCheck = chip: variant: variantCfg: chipCfg:
    nativePkgs.stdenv.mkDerivation {
      name = "${chip}-bootloader-${variant}-check";
      src = project;
      buildInputs = [ chipCfg.idf ];
      phases = [ "buildPhase" ];

      buildPhase = ''
        cp -r $src/* .
        chmod -R +w .

        ${idfBuild chip variantCfg chipCfg}

        cmp build/bootloader/bootloader.bin ${bootloader.${chip}.${variant}}/bootloader.bin \
          || { echo "FAIL: ${chip}-${variant} bootloader is not reproducible"; exit 1; }
        cmp build/bootloader/bootloader.elf ${bootloader.${chip}.${variant}}/bootloader.elf \
          || { echo "FAIL: ${chip}-${variant} bootloader ELF is not reproducible"; exit 1; }

        # Sanity-check the image header.  All esp-idf images start with the
        # magic byte 0xE9, then the segment count.
        magic=$(head -c1 build/bootloader/bootloader.bin | od -An -tx1 | tr -d ' ')
        [ "$magic" = "e9" ] || { echo "FAIL: bad image magic $magic"; exit 1; }

        segment_count=$(od -An -tu1 -j1 -N1 build/bootloader/bootloader.bin | tr -d ' ')
        [ "$segment_count" -gt 0 ] || { echo "FAIL: no segments in image"; exit 1; }

        # Byte 3 packs spi_speed in the low nibble and spi_size in the high
        # nibble; this must match the flash on the board.
        size_byte=$(od -An -tu1 -j3 -N1 build/bootloader/bootloader.bin | tr -d ' ')
        size_nibble=$((size_byte >> 4))
        [ "$size_nibble" -eq ${toString flashSizeNibbles.${chipCfg.flashSize}} ] \
          || { echo "FAIL: image says flash size nibble $size_nibble, expected ${chipCfg.flashSize}"; exit 1; }

        touch $out
      '';
    };

  check = builtins.mapAttrs (chip: chipCfg:
    builtins.mapAttrs (variant: variantCfg:
      mkCheck chip variant variantCfg chipCfg) variants) chips;

  # Flash a built bootloader to its chip at offset 0x0 with probe-rs, then
  # reset the chip so it boots the new bootloader.
  #
  # probe-rs talks to the chip over its built-in USB Serial/JTAG (the probe-rs
  # udev rules cover the ESP device).
  #
  # `--restore-unwritten` matters: the ESP32-C3 flashloader uses 64 KiB
  # sectors, so the bootloader (0x0) and a partition table (0x8000) share one
  # sector, and a plain sector erase would wipe the partition table.
  # `--verify` reads the flash back after writing.
  mkFlash = chip: variant: bootloader:
    nativePkgs.writeShellApplication {
      name = "${chip}-bootloader-${variant}-flash";
      runtimeInputs = [ nativePkgs.probe-rs-tools ];
      text = ''
        set -euo pipefail
        probe-rs download --chip ${chip} --restore-unwritten --verify \
          --binary-format bin --base-address 0x0 ${bootloader}/bootloader.bin "$@"
        probe-rs reset --chip ${chip}
      '';
    };

  flash = builtins.mapAttrs (chip: chipCfg:
    builtins.mapAttrs (variant: _:
      mkFlash chip variant bootloader.${chip}.${variant}) variants) chips;

  # Flatten a nested attrset of derivations into a linkFarm.
  linkFarmOf = name: nested:
    let
      flatten = attrs:
        builtins.concatLists (builtins.attrValues (builtins.mapAttrs (k: v:
          if builtins.isAttrs v && (v ? type) && v.type == "derivation"
          then [ { name = v.name; path = v; } ]
          else flatten v) attrs));
    in nativePkgs.linkFarm name (flatten nested);
in
{
  inherit bootloader check flash tarball;

  tarballs = linkFarmOf "tarballs" tarball;
  checks = linkFarmOf "checks" check;
}
