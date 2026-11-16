{
  description = "Zig project flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    zig2nix.url = "github:cloudef/zig2nix";

    # ZLS master now ships the build system protocol client (src/bsp.zig) and
    # targets zig 0.18.0-dev, so no custom branch/patches are needed anymore.
    zls-overlay.url = "github:zigtools/zls";
    zls-overlay.inputs.nixpkgs.follows = "nixpkgs";

    # TODO: switch back to git+https://git.toastyx.dev/toasty/z-wgpu-native.git
    # (with ?ref=...) once the zig-0.18 migration branch is pushed/merged.
    z-wgpu-native.url = "git+file:///home/toasty/z-wgpu-native?ref=migrate/zig-0.18";

    zigwin32gen.url = "github:marlersoft/zigwin32gen";
    zigwin32gen.flake = false;

    rickroll.url = "https://archive.org/download/Rick_Astley_Never_Gonna_Give_You_Up/Rick_Astley_Never_Gonna_Give_You_Up.mp4";
    rickroll.flake = false;
  };

  outputs = { self, flake-utils, zig2nix, z-wgpu-native, zigwin32gen, rickroll, zls-overlay, ... }:
    flake-utils.lib.eachDefaultSystem (system: let

      # Environment
      # Prebuilt nightly zig tracked by zig2nix (currently 0.18.0-dev.*).
      # We used to build a custom fork from source; upstream master now has the
      # build system protocol, so the plain nightly is what we want.
      zig-bin = zig2nix.outputs.packages.${system}.zig-master;

      # zigwin32gen still emits Zig 0.15-era code, so generate with 0.15.2.
      zig-0_15_2-bin = zig2nix.outputs.packages.${system}.zig-0_15_2;

      env = zig2nix.outputs.zig-env.${system} { zig = zig-bin; };
      env-0_15_2 = zig2nix.outputs.zig-env.${system} { zig = zig-0_15_2-bin; };

      hostPkgs = env.pkgs;
      inherit (hostPkgs) lib;

      zls = zls-overlay.packages.${system}.zls;

      # Dependencies
      z-wgpu-native-pkg = z-wgpu-native.packages.${system}.default;
      depsBuildInputs = z-wgpu-native-pkg.buildInputs ++ [ hostPkgs.hwloc hostPkgs.cpu_features ];

      # `cpu_features` ships no pkg-config file and zig's build system resolves
      # `linkSystemLibrary` through pkg-config, so synthesise one.
      cpuFeaturesPc = hostPkgs.runCommand "cpu_features-pkgconfig" {} ''
        mkdir -p $out/lib/pkgconfig
        cat > $out/lib/pkgconfig/cpu_features.pc <<'EOF'
        prefix=@prefix@
        includedir=@includedir@
        libdir=@libdir@

        Name: cpu_features
        Description: cpu_features
        Version: @version@
        Cflags: -I''${includedir}
        Libs: -L''${libdir} -lcpu_features
        EOF
        substituteInPlace $out/lib/pkgconfig/cpu_features.pc \
          --replace-fail @prefix@ "${hostPkgs.cpu_features}" \
          --replace-fail @includedir@ "${hostPkgs.cpu_features.dev}/include" \
          --replace-fail @libdir@ "${hostPkgs.cpu_features}/lib" \
          --replace-fail @version@ "${hostPkgs.cpu_features.version}"
      '';

      # NB: don't inherit z-wgpu-native's nativeBuildInputs here: that drags in
      # rust/cargo hooks which run against this pure-Zig derivation and fail at
      # unpack with an unset cargoDeps.
      depsNativeBuildInputs = [ hostPkgs.pkg-config cpuFeaturesPc ];

      zigwin32Pkg = env-0_15_2.package {
        name = "zigwin32";
        src = zigwin32gen;
        nativeBuildInputs = with hostPkgs; [ cacert git curl ];
        zigBuildZonLock = ./vendor/zigwin32gen.zon2json-lock;

        # Fetches win32metadata from the network, hence fixed-output.
        outputHashMode = "recursive";
        outputHashAlgo = "sha256";
        outputHash = "sha256-PGdU1nUOGu1QNSEqKOCstUDuMxj4c8FwYk4R16YKJY8=";

        # Only the emitted flag-struct spelling can be patched here (this file
        # runs under zig 0.15.2); the rest is retargeted in installPhase.
        postPatch = ''
          sed -i 's/packed struct/bitpack struct/g' src/genzig.zig
        '';

        buildPhase = ''
          runHook preBuild
          zig build install
          runHook postBuild
        '';
        installPhase = ''
          runHook preInstall
          mkdir -p $out
          cp -r zig-out/* $out/
          # Retarget the generated bindings at zig 0.18:
          #  - `packed` was renamed to `bitpack`
          #  - ambiguous operator precedence is an error
          find $out -name '*.zig' -exec sed -i \
            -e 's/packed struct/bitpack struct/g' \
            -e 's/\.@"packed"/.@"bitpack"/g' {} +
          sed -i 's|return @as(u8, @intCast(hexVal(hex\[0\]))) << 4 | return (@as(u8, @intCast(hexVal(hex[0]))) << 4) | ' $out/win32/zig.zig
          runHook postInstall
        '';
      };

      # Packages
      packages = rec {
        foreign = env.package {
          src = lib.cleanSource ./.;
          nativeBuildInputs = depsNativeBuildInputs;
          buildInputs = depsBuildInputs;
          zigPreferMusl = true;
          preBuild = ''
            mkdir -p .nix-deps
            ln -sfn ${z-wgpu-native} .nix-deps/z_wgpu_native
            ln -sfn ${zigwin32Pkg} .nix-deps/zigwin32
            ln -sfn ${rickroll} .nix-deps/rickroll.mp4
          '';
        };

        zigwin32 = zigwin32Pkg;

        default = foreign.override (attrs: {
          zigPreferMusl = false;
          # Pin the host glibc version, otherwise zig targets plain "gnu" and
          # rejects the nixpkgs-built shared libraries newer symbol versions.
          zigTarget = "${system}-gnu.${hostPkgs.stdenv.cc.libc.version}";
          zigWrapperBins = [];
          zigWrapperLibs = attrs.buildInputs or [];
        });
      };

      # Apps
      # NB: pass the dependencies so `shell-runtime` exports PKG_CONFIG_PATH etc.;
      # otherwise `nix run`/`nix build` can't resolve hwloc/cpu_features.
      appDeps = depsBuildInputs ++ depsNativeBuildInputs;

      apps = {
        bundle = {
          type = "app";
          program = "${packages.foreign}/bin/default";
        };
        default = env.app appDeps "zig build run -- \"$@\"";
        build   = env.app appDeps "zig build \"$@\"";
        test    = env.app appDeps "zig build test -- \"$@\"";
        docs    = env.app appDeps "zig build docs -- \"$@\"";
        zig2nix = env.app [] "zig2nix \"$@\"";
      };

      # DevShells
      devShells = {
        default = env.mkShell {
          buildInputs = packages.default.buildInputs;
          nativeBuildInputs = with hostPkgs; [
            python314Packages.lizard
            gdb
            zls
            zig-bin
            pkg-config
            cpuFeaturesPc
            hwloc
            cpu_features
          ] ++ packages.default.nativeBuildInputs
            ++ packages.default.zigWrapperBins
            ++ packages.default.zigWrapperLibs;

          shellHook = ''
            export ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-cache"
            mkdir -p "$ZIG_GLOBAL_CACHE_DIR"

            mkdir -p .nix-deps

            ln -sfn ${z-wgpu-native} .nix-deps/z_wgpu_native
            ln -sfn ${zigwin32Pkg} .nix-deps/zigwin32
            ln -sfn ${rickroll} .nix-deps/rickroll.mp4
          '';
        };
      };

    in {
      inherit packages apps devShells;
    });
}
