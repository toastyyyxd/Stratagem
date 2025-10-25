{
  description = "Zig project flake";

  inputs = {
    zig2nix.url = "github:cloudef/zig2nix";
    
    zls-overlay.url = "github:zigtools/zls";
  };

  outputs = { zig2nix, zls-overlay, ... }: let
    flake-utils = zig2nix.inputs.flake-utils;
  in (flake-utils.lib.eachDefaultSystem (system: let
      env = zig2nix.outputs.zig-env.${system} { zig = zig2nix.outputs.packages.${system}.zig-latest; };
      zls = zls-overlay.packages.x86_64-linux.zls;
    in with builtins; with env.pkgs.lib; rec {
      packages.foreign = env.package { # Clean binaries for shipping outside nix
        src = cleanSource ./.;
        nativeBuildInputs = with env.pkgs; [
          xorg.libX11
          xorg.libXcursor
          xorg.libXext
          xorg.libXi
          xorg.libXinerama
          xorg.libXrandr
          xorg.libXrender
          libGL
          wayland
          libxkbcommon
          egl-wayland
        ]; # Packages for compiling
        buildInputs = with env.pkgs; []; # Packages for linking
        zigPreferMusl = true; # Smaller binaries, avoids shipping glibc
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
        buildInputs = [ zls ];
        nativeBuildInputs = [
          env.pkgs.wayland-scanner
          env.pkgs.xorg.libX11
          env.pkgs.xorg.libXcursor
          env.pkgs.xorg.libXext
          env.pkgs.xorg.libXi
          env.pkgs.xorg.libXinerama
          env.pkgs.xorg.libXrandr
          env.pkgs.xorg.libXrender
          env.pkgs.libGL
          env.pkgs.wayland
          env.pkgs.libxkbcommon
          env.pkgs.egl-wayland
        ] # Packages for compiling, linking and runtime
          ++ packages.default.nativeBuildInputs
          ++ packages.default.buildInputs
          ++ packages.default.zigWrapperBins
          ++ packages.default.zigWrapperLibs;
        postPatch = ''
          ln -s ${env.pkgs.callPackage ./build.zig.zon.nix { }} $ZIG_GLOBAL_CACHE_DIR/p
        '';
      };
    }));
}

