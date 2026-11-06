#!/usr/bin/env bash
# Builds an x86_64 APK of this branch for the screenshots that .github/workflows/capture-android.yml
# takes on the Android emulator. This is not the Play build:
#   - one ABI only, x86_64, which is what the emulator on a GitHub runner runs;
#   - signed with a throwaway key made here and deleted right after the build, so no key of
#     ours is involved; the APK stays in the workflow's own cache and is never published.
# The code is this branch as committed (patches 01 to 06 are already commits here), built with
# the same toolchain image as the Play build (../Dockerfile) and the same build-environment
# tweaks as ../build.sh step_patch.
# Mounts: this branch at /work/rustdesk, ../ at /recipe (read only), a cache folder at
# /work/cache and an output folder at /work/out.
#   bash /recipe/capture/build-x86_64.sh all
set -euo pipefail

SRC=/work/rustdesk
OUT=/work/out
ABI=x86_64
TARGET=x86_64-linux-android
APK_NAME=emilli-remote-capture-x86_64.apk
mkdir -p "$OUT" /work/cache/vcpkg-archives /work/cache/vcpkg-downloads
export VCPKG_DEFAULT_BINARY_CACHE=/work/cache/vcpkg-archives
export VCPKG_DOWNLOADS=/work/cache/vcpkg-downloads
export CARGO_TARGET_DIR=/work/cache/target

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

step_prepare() {
  sed -i "s/org.gradle.jvmargs=-Xmx1024M/org.gradle.jvmargs=-Xmx2g/g" "$SRC/flutter/android/gradle.properties"
  local fdiff="$SRC/.github/patches/flutter_3.24.4_dropdown_menu_enableFilter.diff"
  if git -C "$FLUTTER_ROOT" apply --reverse --check "$fdiff" 2>/dev/null; then
    log "flutter sdk patch already applied"
  else
    git -C "$FLUTTER_ROOT" apply "$fdiff"
    log "flutter sdk patch applied"
  fi
  grep -n "^version:" "$SRC/flutter/pubspec.yaml"
}

step_bridge() {
  log "bridge (same step as the Play build)"
  bash /recipe/build.sh bridge
}

step_deps() {
  cd "$SRC"
  log "vcpkg deps for $ABI"
  ./flutter/build_android_deps.sh "$ABI"
}

step_lib() {
  cd "$SRC"
  log "cargo ndk build for $TARGET"
  ./flutter/ndk_x64.sh
  mkdir -p "flutter/android/app/src/main/jniLibs/$ABI"
  cp "$CARGO_TARGET_DIR/$TARGET/release/liblibrustdesk.so" "flutter/android/app/src/main/jniLibs/$ABI/librustdesk.so"
  cp "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/$TARGET/libc++_shared.so" \
     "flutter/android/app/src/main/jniLibs/$ABI/"
  ls -la "flutter/android/app/src/main/jniLibs/$ABI/"
}

step_apk() {
  cd "$SRC/flutter"
  local ks=/tmp/capture-throwaway.p12 pw
  pw="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 40)"
  keytool -genkeypair -keystore "$ks" -storetype PKCS12 -alias capture -keyalg RSA -keysize 2048 -validity 7 \
    -storepass "$pw" -keypass "$pw" -dname "CN=Emilli Remote screenshot build not for release" > /dev/null
  (umask 077; printf 'storeFile=%s\nkeyAlias=capture\nstorePassword=%s\nkeyPassword=%s\n' "$ks" "$pw" "$pw" > android/key.properties)
  unset pw
  trap 'rm -f "$SRC/flutter/android/key.properties" /tmp/capture-throwaway.p12' EXIT
  log "flutter build apk --release --target-platform android-x64"
  flutter build apk --release --target-platform android-x64
  rm -f android/key.properties "$ks"
  trap - EXIT
  cp build/app/outputs/flutter-apk/app-release.apk "$OUT/$APK_NAME"
  local bt
  bt="$(ls "$ANDROID_HOME/build-tools" | sort -V | tail -n 1)"
  "$ANDROID_HOME/build-tools/$bt/aapt2" dump badging "$OUT/$APK_NAME" | grep -E "^package:|^application-label:|^native-code|^targetSdkVersion"
  sha256sum "$OUT/$APK_NAME"
  stat -c '%s bytes' "$OUT/$APK_NAME"
}

case "${1:-all}" in
  prepare) step_prepare ;;
  bridge) step_bridge ;;
  deps) step_deps ;;
  lib) step_lib ;;
  apk) step_apk ;;
  all) step_prepare; step_bridge; step_deps; step_lib; step_apk ;;
  *) echo "unknown step $1" >&2; exit 2 ;;
esac
