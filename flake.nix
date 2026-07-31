{
  description = "Zig project flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    zig2nix.url = "github:cloudef/zig2nix";
    
    # Custom zig source from your branch
    zig-bsp.url = "git+https://git.toastyx.dev/toasty/zig-bsp-cherrypick.git?ref=bsp";
    zig-bsp.flake = false;

    # Use ZLS's own flake, pointed at the specific branch
    zls-overlay.url = "github:zigtools/zls/techatrix/build-runner-process";
    zls-overlay.inputs.nixpkgs.follows = "nixpkgs";

    z-wgpu-native.url = "git+https://git.toastyx.dev/toasty/z-wgpu-native.git";

    zigwin32gen.url = "github:marlersoft/zigwin32gen";
    zigwin32gen.flake = false;

    rickroll.url = "https://archive.org/download/Rick_Astley_Never_Gonna_Give_You_Up/Rick_Astley_Never_Gonna_Give_You_Up.mp4";
    rickroll.flake = false;
  };

  outputs = { self, flake-utils, zig2nix, z-wgpu-native, zigwin32gen, rickroll, zig-bsp, zls-overlay, ... }: 
    flake-utils.lib.eachDefaultSystem (system: let
      
      # Environment
      # Build custom zig from source (bsp branch)
      zig-bin = zig2nix.outputs.packages.${system}.zig-src-master.overrideAttrs (old: {
        version = "0.17.0-dev.bsp";
        src = zig-bsp;
        cmakeFlags = old.cmakeFlags ++ [ "-DZIG_VERSION=0.17.0-dev.bsp" ];
      });

      zig-0_15_2-bin = zig2nix.outputs.packages.${system}.zig-0_15_2;

      env = zig2nix.outputs.zig-env.${system} { zig = zig-bin; };
      env-0_15_2 = zig2nix.outputs.zig-env.${system} { zig = zig-0_15_2-bin; };
      
      hostPkgs = env.pkgs;
      inherit (hostPkgs) lib;

      # Universal patch script for Zig 0.17.0-dev compatibility
      zig017PatchScript = ''
        find . -name "*.zig" -exec sed -i -E \
          -e 's/(\boptimize\b|\bmode\b)\s*==\s*\.ReleaseSmall\b/\1 == .small/g' \
          -e 's/(\boptimize\b|\bmode\b)\s*==\s*\.ReleaseFast\b/\1 == .fast/g' \
          -e 's/(\boptimize\b|\bmode\b)\s*==\s*\.ReleaseSafe\b/\1 == .safe/g' \
          -e 's/(\boptimize\b|\bmode\b)\s*==\s*\.Debug\b/\1 == .debug/g' \
          -e 's/\.\s*optimize\s*=\s*\.ReleaseSmall\b/.optimize = .small/g' \
          -e 's/\.\s*optimize\s*=\s*\.ReleaseFast\b/.optimize = .fast/g' \
          -e 's/\.\s*optimize\s*=\s*\.ReleaseSafe\b/.optimize = .safe/g' \
          -e 's/\.\s*optimize\s*=\s*\.Debug\b/.optimize = .debug/g' \
          {} +
        
        find . -name "*.zig" -exec sed -i -E 's/cTypeBitSize\((\.[a-z_]+)\)(\.\?)?/cTypeBitSize(\1).?/g' {} +
      '';

      # Helper to patch any source directory with the universal script
      patchZigSrc = name: src: hostPkgs.runCommand name {} ''
        cp -r ${src} $out
        chmod -R u+w $out
        cd $out
        ${zig017PatchScript}
      '';

      z-wgpu-native-src = patchZigSrc "z-wgpu-native-patched" z-wgpu-native;

      # Override ZLS to use our custom zig-bin and apply the universal patches
      zls = zls-overlay.packages.${system}.zls.overrideAttrs (old: {
        # Force our custom zig into the build environment
        nativeBuildInputs = [ zig-bin ];
        
        # Skip the test suite because the bsp branch broke enum casing and LSP types
        doCheck = false;
        
        # Apply universal patches, plus bypass the ZLS version check
        postPatch = (old.postPatch or "") + zig017PatchScript + ''
          sed -i 's/0.17.0-dev.387+31f157d80/0.0.0/g' build.zig build.zig.zon
        '';
      });

      # Dependencies
      z-wgpu-native-pkg = z-wgpu-native.packages.${system}.default;
      depsBuildInputs = z-wgpu-native-pkg.buildInputs ++ [ hostPkgs.hwloc ];
      depsNativeBuildInputs = z-wgpu-native-pkg.nativeBuildInputs ++ [ hostPkgs.pkg-config ];

      zigwin32 = env-0_15_2.package {
        name = "zigwin32";
        src = zigwin32gen;
        nativeBuildInputs = with hostPkgs; [ cacert git curl ];
        zigBuildZonLock = ./vendor/zigwin32gen.zon2json-lock;
        
        outputHashMode = "recursive";
        outputHashAlgo = "sha256";
        outputHash = "sha256-Xfp5wRP1UoLqVLhH1bWRBteNrSjR1RDomED0a9/42Wk="; # We will replace this after the first failure
        
        buildPhase = ''
          runHook preBuild
          zig build install
          runHook postBuild
        '';
        installPhase = ''
          runHook preInstall
          mkdir -p $out
          cp -r zig-out/* $out/
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
            ln -sfn ${z-wgpu-native-src} .nix-deps/z_wgpu_native
            ln -sfn ${zigwin32} .nix-deps/zigwin32
            ln -sfn ${rickroll} .nix-deps/rickroll.mp4
          '';
        };

        default = foreign.override (attrs: {
          zigPreferMusl = false;
          zigWrapperBins = [];
          zigWrapperLibs = attrs.buildInputs or [];
        });
      };

      # Apps
      apps = {
        bundle = {
          type = "app";
          program = "${packages.foreign}/bin/default";
        };
        default = env.app [] "zig build run -- \"$@\"";
        build   = env.app [] "zig build \"$@\"";
        test    = env.app [] "zig build test -- \"$@\"";
        docs    = env.app [] "zig build docs -- \"$@\"";
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
            hwloc
          ] ++ packages.default.nativeBuildInputs
            ++ packages.default.zigWrapperBins
            ++ packages.default.zigWrapperLibs;

          shellHook = ''
            export ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-cache"
            mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
            #ln -sfn ${hostPkgs.callPackage ./build.zig.zon.nix { }} $ZIG_GLOBAL_CACHE_DIR/p

            mkdir -p .nix-deps

            ln -sfn ${z-wgpu-native-src} .nix-deps/z_wgpu_native
            ln -sfn ${zigwin32} .nix-deps/zigwin32
            ln -sfn ${rickroll} .nix-deps/rickroll.mp4
          '';
        };
      };

    in {
      inherit packages apps devShells;
    });
}
