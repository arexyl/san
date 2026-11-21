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

      ndkRoot = "${android.androidsdk}/libexec/android-sdk/ndk/${ndkVersion}";

      # Both commands take San's root from the working directory: a flake cannot name its checkout.
      requireRoot = ''
        if [ ! -f build.zig.zon ]; then
          echo "Run this command in San's root." >&2
          exit 2
        fi
      '';

      # Spells the path flags of an invocation, so that a call names only its options and steps.
      sanBuild = pkgs.writeShellApplication {
        name = "san-build";
        runtimeInputs = [ pkgs.zig_0_17 ];

        text = ''
          ${requireRoot}
          root=$PWD
          abi=
          mode=

          for argument in "$@"; do
            case $argument in
              -Dabi=*) abi=''${argument#-Dabi=} ;;
              -Doptimize=*) mode=''${argument#-Doptimize=} ;;
            esac
          done

          # Only an Android step installs, so every other invocation shares one prefix.
          if [ -n "$abi" ] && [ -n "$mode" ]; then
            prefix=$abi-$mode
          else
            prefix=host
          fi

          ZIG_GLOBAL_CACHE_DIR=$root/build/cache/zig-global exec zig build \
            --build-file "$root/build.zig" \
            --pkg-dir "$root/build/cache/packages" \
            --system "$root/build/cache/packages" \
            --cache-dir "$root/build/cache/zig" \
            --prefix "$root/build/work/$prefix" \
            -Dndk=${pkgs.lib.escapeShellArg ndkRoot} "$@"
        '';
      };

      # Runs the staged device harnesses of both modes on the attached device.
      # adb comes from the shell that booted the device: a second adb version would restart its server.
      sanDevice = pkgs.writeShellApplication {
        name = "san-device";

        text = ''
          ${requireRoot}
          if ! command -v adb >/dev/null; then
            echo "adb is not on PATH." >&2
            exit 2
          fi

          # The reader corpus lies outside this repository, so the caller names it.
          if [ "$#" -ne 1 ] || [ ! -f "$1/manifest.json" ] || [ ! -d "$1/journey" ]; then
            echo "usage: san-device <corpus>, the directory of the reader corpus with its manifest.json and journey/" >&2
            exit 2
          fi

          corpus=$1
          remote=/data/local/tmp/san
          failed=0

          trap 'adb shell "rm -rf $remote" </dev/null' EXIT

          level=$(adb shell getprop ro.build.version.sdk </dev/null)
          abi=$(adb shell getprop ro.product.cpu.abi </dev/null)
          page=$(adb shell getconf PAGE_SIZE </dev/null)
          echo "API $level, ABI $abi, page size $page"

          names=(
            libsan_png_test.so
            san-png-harness
            libsan_abi_test.so
            san-abi-harness
            libsan.so
            san-jni-harness
            libsan_canary_test.so
            san-canary-harness
          )

          runs=(
            "san-png-harness generated"
            "san-png-harness inject"
            "san-png-harness cancel"
            "san-png-harness stress"
            "san-abi-harness corpus"
            "san-jni-harness"
            "san-canary-harness control"
          )

          for mode in debug safe; do
            staged=build/work/$abi-$mode
            files=()

            for name in "''${names[@]}"; do
              if [ ! -f "$staged/$name" ]; then
                echo "$staged holds no staged $name." >&2
                exit 2
              fi

              files+=("$staged/$name")
            done

            adb shell "rm -rf $remote && mkdir -p $remote/corpus" </dev/null

            # adb reports the progress of a push on the error stream.
            if ! pushed=$(adb push "''${files[@]}" "$remote/" 2>&1); then
              echo "$pushed" >&2
              exit 1
            fi

            if ! pushed=$(adb push "$corpus/manifest.json" "$corpus/journey" "$remote/corpus/" 2>&1); then
              echo "$pushed" >&2
              exit 1
            fi

            for run in "''${runs[@]}"; do
              status=0
              output=$(adb shell "cd $remote && LD_LIBRARY_PATH=. ./$run" </dev/null 2>&1) || status=$?
              summary=''${output##*$'\n'}

              if [ "$status" -eq 0 ] && [[ $summary == *failed=0 ]]; then
                echo "$mode $run: $summary"
              else
                echo "$mode $run: failed, exit status $status"
                echo "$output"
                failed=1
              fi
            done

            # The overflow run passes only when the stack protector ends the process.
            # adb reports a death by a signal as 128 plus the signal: 5 is SIGTRAP, and 6 is SIGABRT.
            adb logcat -b crash -c </dev/null
            status=0
            output=$(adb shell "cd $remote && LD_LIBRARY_PATH=. ./san-canary-harness overflow" </dev/null 2>&1) || status=$?

            case $status in
              133) echo "$mode san-canary-harness overflow: ended by SIGTRAP" ;;
              134) echo "$mode san-canary-harness overflow: ended by SIGABRT" ;;
              *)
                echo "$mode san-canary-harness overflow: failed, exit status $status"
                echo "$output"
                failed=1
                ;;
            esac

            # The system writes the crash log after the process ends. Its lines show what a tombstone of the failure holds.
            sleep 2
            adb logcat -b crash -d </dev/null | grep -E 'signal [0-9]|Abort message|#0[0-3] pc' || true
          done

          exit "$failed"
        '';
      };
    in
    {
      devShells.${system}.default = pkgs.mkShellNoCC {
        packages = [
          pkgs.zig_0_17
          pkgs.llvmPackages_23.clang-tools
          sanBuild
          sanDevice
        ];

        # build.zig takes the NDK root only through -Dndk, so the shell names the root for that flag.
        ANDROID_NDK_ROOT = ndkRoot;
      };

      formatter.${system} = pkgs.nixfmt-tree;
    };
}
