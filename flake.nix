{
  description = "Zig project flake";

  inputs = {
    zig2nix.url = "github:cloudef/zig2nix";
    zls-overlay.url = "github:zigtools/zls";
    
    z-wgpu-native.url = "git+https://git.toastyx.dev/toasty/z-wgpu-native.git";
    z-wgpu-native.inputs.zig2nix.follows = "zig2nix";

    zigwin32gen.url = "github:marlersoft/zigwin32gen";
    zigwin32gen.flake = false;
  };

  outputs = { zig2nix, zls-overlay, z-wgpu-native, zigwin32gen, ... }: let
    flake-utils = zig2nix.inputs.flake-utils;
  in (flake-utils.lib.eachDefaultSystem (system: let
      zig-env = zig2nix.outputs.zig-env.${system};
      env = zig-env { zig = zig2nix.outputs.packages.${system}.zig-master; };
      env-0_15_2 = zig-env { zig = zig2nix.outputs.packages.${system}.zig-0_15_2; };
      zls = zls-overlay.packages.x86_64-linux.zls;

      z-wgpu-native-pkg = z-wgpu-native.packages.${system}.default;

      zigwin32 = env-0_15_2.package {
        name = "zigwin32";
        src = zigwin32gen;
        nativeBuildInputs = with env-0_15_2.pkgs; [ git ];
        zigBuildZonLock = ./vendor/zigwin32gen.zon2json-lock;
        buildPhase = ''
          runHook preBuild
          zig build install # zig2nix puts flags here but for some reason this build.zig doesn't have any of it
          # no prefix out because we aren't going for the generator
          runHook postBuild
        '';
        installPhase = ''
          runHook preInstall
          mkdir -p $out
          cp -r zig-out/* $out/
          runHook postInstall
        '';
      };

      depsBuildInputs = z-wgpu-native-pkg.buildInputs or [];
      depsNativeBuildInputs = z-wgpu-native-pkg.nativeBuildInputs or [];
    in with builtins; with env.pkgs.lib; rec {
      packages.foreign = env.package { # Clean binaries for shipping outside nix
        src = cleanSource ./.;
        nativeBuildInputs = with env.pkgs; [] ++ depsNativeBuildInputs; # Packages for compiling
        buildInputs = with env.pkgs; [] ++ depsBuildInputs; # Packages for linking
        zigPreferMusl = true; # Smaller binaries, avoids shipping glibc
        preBuild = ''
          mkdir -p .nix-deps
          ln -sfn ${z-wgpu-native} .nix-deps/z_wgpu_native
          ln -sfn ${zigwin32} .nix-deps/zigwin32
        '';
      };

      packages.default = packages.foreign.override (attrs: { # nix build .
        zigPreferMusl = false; # Prefer nix friendly settings
        zigWrapperBins = with env.pkgs; []; # Executables for runtime PATH
        zigWrapperLibs = attrs.buildInputs or []; # Libraries for LD_LIBRARY_PATH
      });

      apps.bundle = { # For bundling with nix bundle
        type = "app";
        program = "${packages.foreign}/bin/default";
      };

      apps.default = env.app [] "zig build run -- \"$@\""; # nix run .
      apps.build = env.app [] "zig build \"$@\""; # nix run .#build
      apps.test = env.app [] "zig build test -- \"$@\""; # nix run .#test
      apps.docs = env.app [] "zig build docs -- \"$@\""; # nix run .#docs
      apps.zig2nix = env.app [] "zig2nix \"$@\""; # nix run .#zig2nix

      devShells.default = env.mkShell { # nix develop
        buildInputs = with env.pkgs; [ python314Packages.lizard gdb ] ++ [ zls ];
        nativeBuildInputs = with env.pkgs; []
          ++ packages.default.nativeBuildInputs
          ++ packages.default.buildInputs
          ++ packages.default.zigWrapperBins
          ++ packages.default.zigWrapperLibs;
        shellHook = ''
          export ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-cache"
          mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
          ln -s ${env.pkgs.callPackage ./build.zig.zon.nix { }} $ZIG_GLOBAL_CACHE_DIR/p

          mkdir -p .nix-deps
          ln -sfn ${z-wgpu-native} .nix-deps/z_wgpu_native
          ln -sfn ${zigwin32} .nix-deps/zigwin32
        '';
      };
    }));
}

