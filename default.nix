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
  # the right toolchain.
  chips = {
    esp32c3 = {
      idf = espPkgs.esp-idf-riscv;
    };
    esp32c6 = {
      idf = espPkgs.esp-idf-riscv;
    };
    esp32s3 = {
      idf = espPkgs.esp-idf-xtensa;
    };
  };

  # Bootloader variants.  `default` is the stock esp-idf bootloader (rollback
  # off); `with-rollback` enables CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE.
  #
  # CONFIG_APP_REPRODUCIBLE_BUILD eliminates date/time/path info from the
  # image (it also turns off CONFIG_BOOTLOADER_COMPILE_TIME_DATE), so the same
  # source builds byte-identically at any time.
  variants = {
    default = {
      sdkconfigDefaults = ''
        CONFIG_APP_REPRODUCIBLE_BUILD=y
        # CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE is not set
      '';
    };
    with-rollback = {
      sdkconfigDefaults = ''
        CONFIG_APP_REPRODUCIBLE_BUILD=y
        CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE=y
      '';
    };
  };

  # The idf.py commands that build the bootloader into ./build.  Shared by the
  # bootloader derivation and the reproducibility check.
  idfBuild = chip: variantCfg: ''
    cat > sdkconfig.defaults <<EOF
    ${variantCfg.sdkconfigDefaults}
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

        ${idfBuild chip variantCfg}

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

        ${idfBuild chip variantCfg}

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

        touch $out
      '';
    };

  check = builtins.mapAttrs (chip: chipCfg:
    builtins.mapAttrs (variant: variantCfg:
      mkCheck chip variant variantCfg chipCfg) variants) chips;

  # Flash a built bootloader to its chip at offset 0x0.
  mkFlash = chip: variant: bootloader: idf:
    nativePkgs.writeShellApplication {
      name = "${chip}-bootloader-${variant}-flash";
      runtimeInputs = [ idf ];
      text = ''
        set -euo pipefail
        exec ${idf}/python-env/bin/python3 -m esptool \
          --chip ${chip} -b 460800 --before default_reset --after hard_reset \
          write_flash 0x0 ${bootloader}/bootloader.bin "$@"
      '';
    };

  flash = builtins.mapAttrs (chip: chipCfg:
    builtins.mapAttrs (variant: _:
      mkFlash chip variant bootloader.${chip}.${variant} chipCfg.idf) variants) chips;

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
