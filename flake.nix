{
  description = "Development shell for San, the native image engine of Hakusan";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      system = "aarch64-darwin";

      # The NDK is unfree, and its package evaluates only with the license accepted.
      pkgs = import nixpkgs {
        inherit system;

        config = {
          allowUnfree = true;
          android_sdk.accept_license = true;
        };
      };

      ndkVersion = "30.0.16248370";

      android = pkgs.androidenv.composeAndroidPackages {
        inherit ndkVersion;

        includeNDK = true;
        includeCmake = false;
        platformVersions = [ ];
        buildToolsVersions = [ ];
      };
    in
    {
      devShells.${system}.default = pkgs.mkShellNoCC {
        packages = [
          pkgs.zig_0_17
          pkgs.llvmPackages_23.clang-tools
        ];

        # build.zig takes the NDK root only through -Dndk, so the shell names the root for that flag.
        ANDROID_NDK_ROOT = "${android.androidsdk}/libexec/android-sdk/ndk/${ndkVersion}";
      };

      formatter.${system} = pkgs.nixfmt-tree;
    };
}
