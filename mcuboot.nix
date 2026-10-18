# MCUboot's Espressif port requires an exact ESP-IDF HAL version: its
# top-level CMakeLists sets EXPECTED_IDF_HAL_VERSION to 5.1.6 and aborts on a
# mismatch.  Rather than carrying separate nixpkgs/nixpkgs-esp-dev pins, reuse
# the project's main pins and override only the ESP-IDF version and tool list.
# https://github.com/mcu-tools/mcuboot/blob/v2.4.0/boot/espressif/CMakeLists.txt
# https://docs.mcuboot.com/readme-espressif.html
{ pkgs
, espPkgs
, flashSizeNibbles
}:
let
  idf516Override = {
    rev = "v5.1.6";
    sha256 = "sha256-Zeew4Ekp6jW+kx7MOTnG3cvEqIDF1v+yOCf5uuQmUkM=";
    # IDF 5.1.6 still uses Python 3.11.
    python3 = pkgs.python311;
  };

  # The newer nixpkgs-esp-dev package cannot package IDF 5.1.6's GDB binaries
  # (they link missing libpython3.7m/libpython3.6m entries), so trim the tool
  # lists to what MCUboot needs.  MCUboot does not use GDB.
  idf516Riscv = espPkgs.esp-idf-riscv.override (idf516Override // {
    toolsToInclude = [ "riscv32-esp-elf" "esp-rom-elfs" ];
  });

  idf516Xtensa = espPkgs.esp-idf-xtensa.override (idf516Override // {
    toolsToInclude = [ "xtensa-esp32s3-elf" "esp-rom-elfs" ];
  });

  mcubootChips = {
    esp32c3 = idf516Riscv;
    esp32c6 = idf516Riscv;
    esp32s3 = idf516Xtensa;
  };

  mcubootSrc = pkgs.fetchgit {
    url = "https://github.com/mcu-tools/mcuboot";
    rev = "6d3b3d2c38ab20c242e5b9abb04d050086383eb2"; # v2.4.0
    sha256 = "sha256-oFucMiA12uxzPfxH4fi+PtAzyI8cKGzxrlHXOF+0wDo=";
    fetchSubmodules = true;
  };

  # Fixed flash sizes for the boards this project targets: picoprog's
  # ESP32-C3 and the ESP32-C6 are 4MB; the ESP32-S3-WROOM-1-N16R8 is 16MB.
  # One target per chip avoids a variant matrix while matching the hardware.
  #
  # MCUboot also supports classic esp32/esp32s2, but they are outside this
  # project's current target set.
  #
  # MCUboot's flash-size option only changes the ESP image header nibble (the
  # same field checked for the ESP-IDF bootloader).  Its stock 4 MB slot and
  # scratch addresses are deliberately left alone for the 16 MB target.
  mcubootTargets = {
    esp32c3 = { flashSize = "4MB"; };
    esp32c6 = { flashSize = "4MB"; };
    esp32s3 = { flashSize = "16MB"; };
  };

  # Extra lines appended to every MCUboot target's configuration.  Later
  # lines override the port's defaults, so this is where to enable signature
  # verification, for example:
  #
  #   mcubootExtraConfig = ''
  #     CONFIG_ESP_SIGN_EC256=y
  #     CONFIG_ESP_USE_TINYCRYPT=y
  #     CONFIG_ESP_SIGN_KEY_FILE=${./my-key.pem}
  #   '';
  #
  # `${./my-key.pem}` is copied into the Nix store, which is the only place
  # the key exists inside the build sandbox.  Empty by default, leaving the
  # bootloader unsigned (image signatures are ignored).
  mcubootExtraConfig = "";

  # Plain CMake/Ninja against ESP-IDF as a HAL; this port does not use idf.py.
  # Shared with the check so it rebuilds with exactly the same commands.
  # imgtool is on PATH so that enabling CONFIG_ESP_SIGN_* can embed the
  # public key derived from CONFIG_ESP_SIGN_KEY_FILE.
  mcubootBuild = chip: flashSize: idf: ''
    cp -r $src source
    chmod -R u+w source
    cd source

    # fetchgit has no .git, so `git describe --tags` produces an empty banner.
    # Pin the version string deterministically instead.
    substituteInPlace boot/espressif/CMakeLists.txt \
      --replace-fail 'COMMAND git describe --tags' \
                     'COMMAND sh -c "echo v2.4.0"'

    # MCUboot builds with -ggdb, and its assert messages embed __FILE__.
    # Map the MCUboot checkout, ESP-IDF, and build directory to stable virtual
    # paths so the image and linker map do not depend on the Nix store or the
    # build directory.  This is what makes the check reproducible.
    substituteInPlace boot/espressif/CMakeLists.txt \
      --replace-fail 'add_subdirectory(hal)' \
        'get_filename_component(_mcuboot_root "''${CMAKE_CURRENT_LIST_DIR}/../.." REALPATH)
    add_compile_options("-ffile-prefix-map=''${_mcuboot_root}=mcuboot" "-ffile-prefix-map=''${ESP_HAL_PATH}=esp-idf" "-fdebug-prefix-map=''${CMAKE_BINARY_DIR}=build")
    add_subdirectory(hal)'

    cat > variant.conf <<EOF
    CONFIG_ESP_FLASH_SIZE=${flashSize}
    ${mcubootExtraConfig}
    EOF

    cmake -G Ninja \
      -DCMAKE_TOOLCHAIN_FILE="$PWD/boot/espressif/tools/toolchain-${chip}.cmake" \
      -DMCUBOOT_TARGET=${chip} \
      -DESP_HAL_PATH=${idf} \
      -DMCUBOOT_CONFIG_FILE="$PWD/boot/espressif/port/${chip}/bootloader.conf;$PWD/variant.conf" \
      -B build \
      boot/espressif

    cmake --build build

    # The linker map records absolute object/toolchain paths.  Strip the build
    # directory and Nix store prefix so the map is reproducible and contains
    # no host-specific paths.  CMake prefixes object paths with
    # "CMakeFiles/...dir" followed by the absolute source path, so handle that
    # combination first; the remaining substitutions keep the trailing slash
    # so "$PWD/foo" becomes "mcuboot/foo" rather than "mcubootfoo".
    map_src_abs="$PWD"
    map_src_rel="''${PWD#/}"
    sed -i \
      -e "s|\.dir$map_src_abs|.dir/mcuboot|g" \
      -e "s|\.dir$map_src_rel|.dir/mcuboot|g" \
      -e "s|$map_src_abs/|mcuboot/|g" \
      -e "s|$map_src_abs$|mcuboot|g" \
      -e "s|$map_src_rel/|mcuboot/|g" \
      -e "s|$map_src_rel$|mcuboot|g" \
      -e 's|/nix/store/[a-z0-9]\+-|nix-store/|g' \
      build/mcuboot_${chip}.map
  '';

  mkMcuboot = chip: targetCfg:
    pkgs.stdenv.mkDerivation {
      name = "${chip}-mcuboot";
      src = mcubootSrc;
      nativeBuildInputs = [ pkgs.cmake pkgs.ninja pkgs.mcuboot-imgtool ];
      buildInputs = [ mcubootChips.${chip} ];
      phases = [ "buildPhase" "installPhase" ];

      buildPhase = ''
        runHook preBuild
        ${mcubootBuild chip targetCfg.flashSize mcubootChips.${chip}}
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        mkdir -p $out
        cp build/mcuboot_${chip}.bin $out/
        cp build/mcuboot_${chip}.elf $out/
        cp build/mcuboot_${chip}.map $out/

        # Record the effective configuration (port defaults plus our target
        # overrides) in the tarball.  Drop the port's flash-size line first so
        # mcuboot.conf has exactly one CONFIG_ESP_FLASH_SIZE entry.
        grep -v '^CONFIG_ESP_FLASH_SIZE=' boot/espressif/port/${chip}/bootloader.conf > $out/mcuboot.conf
        cat variant.conf >> $out/mcuboot.conf
        runHook postInstall
      '';
    };

  mcuboot = builtins.mapAttrs (chip: targetCfg:
    mkMcuboot chip targetCfg) mcubootTargets;

  # Rebuild from scratch with the same commands and require byte-identical
  # output.  Also sanity-check the ESP image header and the compiled version
  # banner.  The banner is not a pin check: the version string is injected
  # locally, so grep for `MCUboot` only proves the right code was built.
  mkMcubootCheck = chip: targetCfg:
    pkgs.stdenv.mkDerivation {
      name = "${chip}-mcuboot-check";
      src = mcubootSrc;
      nativeBuildInputs = [ pkgs.cmake pkgs.ninja pkgs.mcuboot-imgtool ];
      buildInputs = [ mcubootChips.${chip} ];
      phases = [ "buildPhase" ];

      buildPhase = ''
        ${mcubootBuild chip targetCfg.flashSize mcubootChips.${chip}}

        cmp build/mcuboot_${chip}.bin ${mcuboot.${chip}}/mcuboot_${chip}.bin \
          || { echo "FAIL: ${chip}-mcuboot MCUboot binary is not reproducible"; exit 1; }
        cmp build/mcuboot_${chip}.elf ${mcuboot.${chip}}/mcuboot_${chip}.elf \
          || { echo "FAIL: ${chip}-mcuboot MCUboot ELF is not reproducible"; exit 1; }
        cmp build/mcuboot_${chip}.map ${mcuboot.${chip}}/mcuboot_${chip}.map \
          || { echo "FAIL: ${chip}-mcuboot MCUboot map is not reproducible"; exit 1; }

        # All ESP images start with magic 0xE9, then the segment count.
        magic=$(head -c1 build/mcuboot_${chip}.bin | od -An -tx1 | tr -d ' ')
        [ "$magic" = "e9" ] || { echo "FAIL: bad image magic $magic"; exit 1; }

        segment_count=$(od -An -tu1 -j1 -N1 build/mcuboot_${chip}.bin | tr -d ' ')
        [ "$segment_count" -gt 0 ] || { echo "FAIL: no segments in image"; exit 1; }

        # Byte 3 packs spi_speed in the low nibble and spi_size in the high
        # nibble; this must match the flash on the board.
        size_byte=$(od -An -tu1 -j3 -N1 build/mcuboot_${chip}.bin | tr -d ' ')
        size_nibble=$((size_byte >> 4))
        [ "$size_nibble" -eq ${toString flashSizeNibbles.${targetCfg.flashSize}} ] \
          || { echo "FAIL: image says flash size nibble $size_nibble, expected ${targetCfg.flashSize}"; exit 1; }

        # The `v2.4.0` string is injected locally above, so these are sanity
        # checks that the Espressif port compiled, not pin checks.
        strings build/mcuboot_${chip}.bin | grep -q 'MCUboot' \
          || { echo "FAIL: MCUboot banner missing"; exit 1; }
        strings build/mcuboot_${chip}.bin | grep -q 'v2.4.0' \
          || { echo "FAIL: v2.4.0 version string missing"; exit 1; }

        touch $out
      '';
    };

  mcubootCheck = builtins.mapAttrs (chip: targetCfg:
    mkMcubootCheck chip targetCfg) mcubootTargets;

  mkMcubootTarball = chip: targetCfg: mcuboot:
    pkgs.runCommand "${chip}-mcuboot.tar.gz" {
      nativeBuildInputs = [ pkgs.gnutar ];
    } ''
      tar -czf "$out" -C "${mcuboot}" \
        mcuboot_${chip}.bin mcuboot_${chip}.elf mcuboot_${chip}.map mcuboot.conf
    '';

  mcubootTarball = builtins.mapAttrs (chip: targetCfg:
    mkMcubootTarball chip targetCfg mcuboot.${chip}) mcubootTargets;

  # MCUboot's Espressif bootloader lives at 0x0 on c3/c6/s3, like the ESP-IDF
  # second-stage bootloader.  This writes only the bootloader; apps are signed
  # MCUboot images and must be flashed separately.
  mkMcubootFlash = chip: targetCfg: mcuboot:
    pkgs.writeShellApplication {
      name = "${chip}-mcuboot-flash";
      runtimeInputs = [ pkgs.probe-rs-tools ];
      text = ''
        set -euo pipefail
        probe-rs download --chip ${chip} --restore-unwritten --verify \
          --binary-format bin --base-address 0x0 ${mcuboot}/mcuboot_${chip}.bin "$@"
        probe-rs reset --chip ${chip}
      '';
    };

  mcubootFlash = builtins.mapAttrs (chip: targetCfg:
    mkMcubootFlash chip targetCfg mcuboot.${chip}) mcubootTargets;
in
{
  inherit mcuboot mcubootCheck mcubootTarball mcubootFlash;
}
