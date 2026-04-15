{
  description = "Android emulator + Flutter environment for Talawa mobile";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-darwin" "x86_64-darwin" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config = {
              android_sdk.accept_license = true;
              allowUnfree = true;
            };
          };

          isLinux = pkgs.stdenv.isLinux;
          isDarwin = pkgs.stdenv.isDarwin;
          abiVersion = if pkgs.stdenv.hostPlatform.isAarch64 then "arm64-v8a" else "x86_64";

          # Full SDK with emulator and system images (~10 GB)
          androidCompositionFull = pkgs.androidenv.composeAndroidPackages {
            cmdLineToolsVersion = "13.0";
            platformToolsVersion = "35.0.2";
            buildToolsVersions = [ "35.0.0" ];
            includeEmulator = true;
            platformVersions = [ "35" "36" ];
            includeSystemImages = true;
            systemImageTypes = [ "google_apis" ];
            abiVersions = [ abiVersion ];
            useGoogleAPIs = true;
            includeNDK = true;
            ndkVersions = [ "27.0.12077973" ];
            cmakeVersions = [ "3.22.1" ];
          };

          # Lean SDK for physical devices only (~6 GB)
          androidCompositionPhysical = pkgs.androidenv.composeAndroidPackages {
            cmdLineToolsVersion = "13.0";
            platformToolsVersion = "35.0.2";
            buildToolsVersions = [ "35.0.0" ];
            includeEmulator = false;
            platformVersions = [ "36" ];
            includeSystemImages = false;
            includeNDK = true;
            ndkVersions = [ "27.0.12077973" ];
            cmakeVersions = [ "3.22.1" ];
          };

          # Flutter 3.35.x — matches the version required by talawa mobile
          # Patch: the nixpkgs derivation omits the `version` file that Flutter
          # tooling expects to find at $FLUTTER_ROOT/version.  We add it back
          # so that `flutter pub get`, `flutter build`, etc. don't crash.
          flutter = pkgs.flutter335.overrideAttrs (old: {
            postInstall = (old.postInstall or "") + ''
              echo "${pkgs.flutter335.version}" > "$out/version"
              touch "$out/bin/cache/engine.realm"
            '';
          });

          # Shared shell builder to avoid duplication
          mkTalawaShell = { androidSdk, includesEmulator }: pkgs.mkShell {
            buildInputs = [
              androidSdk
              flutter
              pkgs.jdk17
            ] ++ pkgs.lib.optionals isLinux [
              pkgs.vulkan-loader
              pkgs.libGL
            ] ++ pkgs.lib.optionals isDarwin [
              pkgs.cocoapods
            ];

            shellHook = ''
              export ANDROID_HOME="${androidSdk}/libexec/android-sdk"
              export ANDROID_SDK_ROOT="$ANDROID_HOME"
              export JAVA_HOME="${pkgs.jdk17}"
              export PATH="$ANDROID_HOME/emulator:$ANDROID_HOME/cmdline-tools/13.0/bin:$ANDROID_HOME/platform-tools:$PATH"
              ${if isLinux then ''export LD_LIBRARY_PATH="${pkgs.vulkan-loader}/lib:${pkgs.libGL}/lib:''${LD_LIBRARY_PATH:-}"'' else ""}

              # Point Flutter at the Nix-provided Android SDK
              flutter config --android-sdk "$ANDROID_HOME" 2>/dev/null

              echo ""
              echo "══════════════════════════════════════════════════════"
              echo "  Talawa Mobile Development Environment"
              echo "══════════════════════════════════════════════════════"
              echo ""
              echo "  Flutter:     $(flutter --version --machine 2>/dev/null | head -1 || echo 'available')"
              echo "  Android SDK: $ANDROID_HOME"
              echo "  Java:        $JAVA_HOME"
              echo ""
              ${if includesEmulator then ''
              echo "  ── Emulator setup (first time) ──"
              echo "  avdmanager create avd --name phone --package 'system-images;android-35;google_apis;${abiVersion}'"
              echo "  emulator -avd phone -skin 720x1280 -noaudio -no-snapshot-load -no-snapshot"
              '' else ''
              echo "  ── Physical device mode (no emulator) ──"
              echo "  Connect your device via USB and enable USB debugging."
              echo "  Verify with: adb devices"
              ''}
              echo ""
              echo "  ── Run the Talawa mobile app ──"
              echo "  cd ../talawa"
              echo "  flutter pub get"
              echo "  flutter run"
              echo ""
              echo "  ── API URL ──"
              ${if includesEmulator then ''
              echo "  Emulator:        http://10.0.2.2:4000/graphql"
              '' else ""}
              echo "  Physical device:  http://<YOUR_LAN_IP>:4000/graphql"
              echo ""
            '';
          };
        in
        {
          # nix develop          — full environment with emulator (~10 GB)
          default = mkTalawaShell {
            androidSdk = androidCompositionFull.androidsdk;
            includesEmulator = true;
          };

          # nix develop .#physical  — lean environment for physical devices (~6 GB)
          physical = mkTalawaShell {
            androidSdk = androidCompositionPhysical.androidsdk;
            includesEmulator = false;
          };
        }
      );
    };
}
