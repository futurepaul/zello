{
  description = "Zello - Immediate-mode UI toolkit in Zig";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, zig }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        inherit (pkgs) lib stdenv;
        zigPkg = zig.packages.${system}."0.15.1";
        devInputs = with pkgs; [
          zigPkg
          rustc
          cargo
          pkg-config
          git
        ] ++ lib.optionals stdenv.isLinux [
          gcc
        ] ++ lib.optionals stdenv.isDarwin [
          clang
        ];
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = devInputs;
          shellHook = ''
            export ZIG_GLOBAL_CACHE_DIR=$(pwd)/.zig-cache
            export ZIG_LOCAL_CACHE_DIR=$ZIG_GLOBAL_CACHE_DIR
            export PATH="${zigPkg}/bin:$PATH"
            if [ -n "''${NIX_CFLAGS_COMPILE-}" ]; then
              filtered_flags=""
              for flag in $NIX_CFLAGS_COMPILE; do
                case "$flag" in
                  -fmacro-prefix-map=*) ;;
                  *) filtered_flags="$filtered_flags $flag" ;;
                esac
              done
              NIX_CFLAGS_COMPILE="''${filtered_flags# }"
              export NIX_CFLAGS_COMPILE
            fi
            ${lib.optionalString stdenv.isDarwin ''
              # Allow Zig to find macOS/iOS system frameworks
              export NIX_ENFORCE_PURITY=0

              # For iOS SDK access, we need to use system Xcode instead of Nix apple-sdk
              # Save original DEVELOPER_DIR
              export NIX_DEVELOPER_DIR="$DEVELOPER_DIR"

              # Helper function to use system Xcode (for iOS SDK access)
              use-system-xcode() {
                export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
              }

              # Helper function to switch to iOS SDK
              # Usage: use-ios-sdk
              use-ios-sdk() {
                use-system-xcode
                export SDKROOT=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || echo "")
                if [ -z "$SDKROOT" ]; then
                  echo "Error: iOS SDK not found. Make sure Xcode is installed."
                  return 1
                fi
                echo "Switched to iOS SDK: $SDKROOT"
              }

              # Helper function to switch to iOS Simulator SDK
              # Usage: use-ios-sim-sdk
              use-ios-sim-sdk() {
                use-system-xcode
                export SDKROOT=$(xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null || echo "")
                if [ -z "$SDKROOT" ]; then
                  echo "Error: iOS Simulator SDK not found. Make sure Xcode is installed."
                  return 1
                fi
                echo "Switched to iOS Simulator SDK: $SDKROOT"
              }

              # Helper function to switch back to macOS SDK
              # Usage: use-macos-sdk
              use-macos-sdk() {
                export DEVELOPER_DIR="$NIX_DEVELOPER_DIR"
                export SDKROOT=$(xcrun --show-sdk-path 2>/dev/null || echo "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk")
                echo "Switched to macOS SDK: $SDKROOT"
              }

              # Default to macOS SDK
              if [ -z "''${SDKROOT:-}" ]; then
                export SDKROOT=$(xcrun --show-sdk-path 2>/dev/null || echo "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk")
              fi
            ''}
            echo "Zello development environment"
            echo "Zig ${zigPkg.version}"
            echo "Rust $(rustc --version)"
          '';
        };
      }
    );
}
