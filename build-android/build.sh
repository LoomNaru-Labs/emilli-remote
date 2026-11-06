#!/usr/bin/env bash
# Builds the Emilli RustDesk Android APK, and the app bundle (AAB) for Google Play, inside the
# toolchain image (see Dockerfile).
# Mirrors upstream CI at the same tag (bridge.yml + flutter-build.yml job build-rustdesk-android),
# plus our patches in ./patches. Run from the host with run-build.sh, or by hand:
#   docker exec rustdesk-android-build bash /recipe/build.sh <step>
# Steps: clone | patch | bridge | deps <abi> | lib <abi> | apk | verify | aab | verify-aab | all | play
#   all:  every step up to the APK and its checks
#   play: every step up to the AAB for Google Play and its checks
# Run "deps <abi>" and "lib <abi>" back to back for one ABI before the next ABI: vcpkg manifest mode
# removes the other ABI's packages from the shared install root (upstream CI uses one runner per ABI).
# Mounts expected: /recipe (this folder, read-only), /keystore (keystore folder, read-only), /work (volume).
# The keystore password is read from /keystore/store.pass into a temporary key.properties that is
# deleted right after the Gradle build; it is never printed. The same key signs the APK and, as the
# Google Play upload key, the AAB.
set -euo pipefail

RD_TAG="${RD_TAG:-1.5.0}"
ABIS="${ABIS:-arm64-v8a armeabi-v7a}"
SRC=/work/rustdesk
OUT=/work/out
KEYSTORE=/keystore/emilli-rustdesk-release.p12
KEY_ALIAS=emilli-rustdesk
BUNDLETOOL_VERSION=1.18.3
BUNDLETOOL_SHA256=a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29
BUNDLETOOL=/work/cache/bundletool-all-${BUNDLETOOL_VERSION}.jar
mkdir -p "$OUT" /work/cache/vcpkg-archives /work/cache/vcpkg-downloads
export VCPKG_DEFAULT_BINARY_CACHE=/work/cache/vcpkg-archives
export VCPKG_DOWNLOADS=/work/cache/vcpkg-downloads

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

abi_target() {
  case "$1" in
    arm64-v8a) echo aarch64-linux-android ;;
    armeabi-v7a) echo armv7-linux-androideabi ;;
    *) echo "unsupported abi $1" >&2; exit 2 ;;
  esac
}
abi_ndk_script() {
  case "$1" in
    arm64-v8a) echo ./flutter/ndk_arm64.sh ;;
    armeabi-v7a) echo ./flutter/ndk_arm.sh ;;
  esac
}
abi_libcxx_dir() {
  case "$1" in
    arm64-v8a) echo aarch64-linux-android ;;
    armeabi-v7a) echo arm-linux-androideabi ;;
  esac
}
abi_flutter_platform() {
  case "$1" in
    arm64-v8a) echo android-arm64 ;;
    armeabi-v7a) echo android-arm ;;
  esac
}

step_clone() {
  if [ ! -d "$SRC/.git" ]; then
    log "clone rustdesk $RD_TAG with submodules"
    git clone --depth 1 --branch "$RD_TAG" --recurse-submodules --shallow-submodules \
      https://github.com/rustdesk/rustdesk "$SRC"
  fi
  git -C "$SRC" describe --tags --exact-match
  git -C "$SRC" rev-parse HEAD
  git -C "$SRC" submodule status
}

# Puts the tracked source back to the upstream tag, then applies every patch in order, so a re-run
# always gives the same tree (later patches change lines that earlier ones touch, such as the
# version line). Untracked build outputs (bridge files, jniLibs, target/) are kept.
step_patch() {
  git -C "$SRC" checkout -- .
  git -C "$SRC/libs/hbb_common" checkout -- .
  git -C "$SRC/libs/hbb_common" apply /recipe/patches/01-hbb_common-builtin-server.patch
  log "applied: 01-hbb_common-builtin-server.patch"
  local p
  for p in 02-android-app-id-and-label 03-api-server-default 04-play-no-update-check \
           05-android-accessibility-disclosure 06-emilli-icon-vc71; do
    git -C "$SRC" apply "/recipe/patches/$p.patch"
    log "applied: $p.patch"
  done
  # Emilli launcher and notification icons (drawn by icons/make_icons.py) replace RustDesk's.
  cp -r /recipe/icons/res/. "$SRC/flutter/android/app/src/main/res/"
  log "Emilli icons copied: $(find /recipe/icons/res -name '*.png' | wc -l) files"
  # Build-environment tweak copied from upstream CI (Gradle heap), not a code change.
  sed -i "s/org.gradle.jvmargs=-Xmx1024M/org.gradle.jvmargs=-Xmx2g/g" "$SRC/flutter/android/gradle.properties"
  # Upstream CI patches the Flutter SDK itself (not the app) for 3.24.x.
  local fdiff="$SRC/.github/patches/flutter_3.24.4_dropdown_menu_enableFilter.diff"
  if git -C "$FLUTTER_ROOT" apply --reverse --check "$fdiff" 2>/dev/null; then
    log "flutter sdk patch already applied"
  else
    git -C "$FLUTTER_ROOT" apply "$fdiff"
    log "flutter sdk patch applied"
  fi
  git -C "$SRC" diff --stat
  git -C "$SRC/libs/hbb_common" diff --stat
}

step_bridge() {
  # Same as upstream bridge.yml with Flutter 3.22.3: temporary pubspec downgrade only for codegen.
  cd "$SRC"
  cp flutter/pubspec.yaml /tmp/pubspec.yaml.orig
  if [ -f flutter/pubspec.lock ]; then cp flutter/pubspec.lock /tmp/pubspec.lock.orig; fi
  sed -i -e 's/extended_text: 14.0.0/extended_text: 13.0.0/g' flutter/pubspec.yaml
  (
    export PATH="/opt/flutter-3.22.3/bin:$PATH"
    export FLUTTER_ROOT=/opt/flutter-3.22.3
    unset VCPKG_ROOT
    cd flutter && flutter pub get
    cd ..
    flutter_rust_bridge_codegen --rust-input ./src/flutter_ffi.rs \
      --dart-output ./flutter/lib/generated_bridge.dart \
      --c-output ./flutter/macos/Runner/bridge_generated.h
    cp ./flutter/macos/Runner/bridge_generated.h ./flutter/ios/Runner/bridge_generated.h
  )
  cp /tmp/pubspec.yaml.orig flutter/pubspec.yaml
  if [ -f /tmp/pubspec.lock.orig ]; then cp /tmp/pubspec.lock.orig flutter/pubspec.lock; fi
  rm -rf flutter/.dart_tool flutter/build
  ls -la src/bridge_generated.rs src/bridge_generated.io.rs flutter/lib/generated_bridge.dart flutter/lib/generated_bridge.freezed.dart
}

step_deps() {
  local abi="$1"
  cd "$SRC"
  log "vcpkg deps for $abi"
  ./flutter/build_android_deps.sh "$abi"
}

step_lib() {
  local abi="$1" target
  target="$(abi_target "$abi")"
  cd "$SRC"
  log "cargo ndk build for $target"
  "$(abi_ndk_script "$abi")"
  mkdir -p "./flutter/android/app/src/main/jniLibs/$abi"
  cp "./target/$target/release/liblibrustdesk.so" "./flutter/android/app/src/main/jniLibs/$abi/librustdesk.so"
  cp "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/$(abi_libcxx_dir "$abi")/libc++_shared.so" \
     "./flutter/android/app/src/main/jniLibs/$abi/"
  ls -la "./flutter/android/app/src/main/jniLibs/$abi/"
}

target_platforms() {
  local platforms="" abi
  for abi in $ABIS; do
    test -f "$SRC/flutter/android/app/src/main/jniLibs/$abi/librustdesk.so" || { echo "missing lib for $abi" >&2; exit 3; }
    platforms="${platforms:+$platforms,}$(abi_flutter_platform "$abi")"
  done
  echo "$platforms"
}

# Runs one flutter build with our release key. Signing goes through upstream's own key.properties
# hook in android/app/build.gradle; the file exists only for the length of the build.
flutter_build_signed() {
  cd "$SRC/flutter"
  local pw
  pw="$(tr -d '\r\n' < /keystore/store.pass)"
  umask 077
  printf 'storeFile=%s\nkeyAlias=%s\nstorePassword=%s\nkeyPassword=%s\n' "$KEYSTORE" "$KEY_ALIAS" "$pw" "$pw" > android/key.properties
  unset pw
  trap 'rm -f "$SRC/flutter/android/key.properties"' EXIT
  log "flutter build $*"
  flutter build "$@"
  rm -f android/key.properties
  trap - EXIT
}

version_code() {
  sed -n 's/^version: .*+\([0-9]*\)$/\1/p' "$SRC/flutter/pubspec.yaml"
}

step_apk() {
  local platforms
  platforms="$(target_platforms)"
  flutter_build_signed apk --release --target-platform "$platforms"
  local name="emilli-remote-rustdesk-${RD_TAG}-android-universal.apk"
  cp build/app/outputs/flutter-apk/app-release.apk "$OUT/$name"
  ls -la "$OUT/$name"
}

# App bundle for Google Play, signed with our key as the upload key.
step_aab() {
  local platforms
  platforms="$(target_platforms)"
  flutter_build_signed appbundle --release --target-platform "$platforms"
  local name="emilli-remote-rustdesk-${RD_TAG}-vc$(version_code)-play.aab"
  cp build/app/outputs/bundle/release/app-release.aab "$OUT/$name"
  ls -la "$OUT/$name"
}

step_verify() {
  local apk
  apk="$(ls -t "$OUT"/*.apk | head -n 1)"
  local bt
  bt="$(ls "$ANDROID_HOME/build-tools" | sort -V | tail -n 1)"
  log "apksigner verify ($bt) $apk"
  "$ANDROID_HOME/build-tools/$bt/apksigner" verify --verbose --print-certs "$apk"
  log "aapt2 badging"
  "$ANDROID_HOME/build-tools/$bt/aapt2" dump badging "$apk" | grep -E "^package:|^application-label|^native-code|^sdkVersion|^targetSdkVersion"
  log "built-in server and key inside the native library"
  local abi
  for abi in $ABIS; do
    local s
    for s in rd.emillis.net EbM3IT7TgSkeeyQpDqmXbo1wvrVz8GG4inwI332DS0A= rs-ny.rustdesk.com OeVuKk5nlHiXp+APNn0Y3pC1Iwpwn44JGqrQCsWqmBw=; do
      echo "lib/$abi/librustdesk.so contains '$s': $(unzip -p "$apk" "lib/$abi/librustdesk.so" | grep -a -F -c "$s" || true) line(s)"
    done
  done
  sha256sum "$apk"
  stat -c '%s bytes' "$apk"
}

bundletool() {
  if [ ! -f "$BUNDLETOOL" ]; then
    curl -fsSL -o "$BUNDLETOOL.tmp" \
      "https://github.com/google/bundletool/releases/download/${BUNDLETOOL_VERSION}/bundletool-all-${BUNDLETOOL_VERSION}.jar"
    echo "$BUNDLETOOL_SHA256  $BUNDLETOOL.tmp" | sha256sum -c - > /dev/null
    mv "$BUNDLETOOL.tmp" "$BUNDLETOOL"
  fi
  echo "$BUNDLETOOL_SHA256  $BUNDLETOOL" | sha256sum -c - > /dev/null
  java -jar "$BUNDLETOOL" "$@"
}

step_verify_aab() {
  local aab bt tmp
  aab="$(ls -t "$OUT"/*.aab | head -n 1)"
  bt="$(ls "$ANDROID_HOME/build-tools" | sort -V | tail -n 1)"
  tmp="$(mktemp -d)"
  log "bundletool $BUNDLETOOL_VERSION: manifest of $aab"
  bundletool dump manifest --bundle "$aab" > "$tmp/manifest.xml"
  grep -o -E 'package="[^"]*"|android:versionCode="[^"]*"|android:versionName="[^"]*"|android:minSdkVersion="[^"]*"|android:targetSdkVersion="[^"]*"' "$tmp/manifest.xml"
  grep -o -E '<uses-permission[^>]*android:name="[^"]*"' "$tmp/manifest.xml" | sed 's/.*android:name=/permission /'
  log "signature of the bundle (JAR signing, as Play reads the upload key)"
  jarsigner -verify "$aab" | tail -n 1
  keytool -printcert -jarfile "$aab" | grep -E 'Owner:|SHA256:'
  log "universal APK made from the bundle, signed with the same key: aapt2 and apksigner"
  bundletool build-apks --bundle "$aab" --output "$tmp/universal.apks" --mode universal \
    --ks "$KEYSTORE" --ks-key-alias "$KEY_ALIAS" --ks-pass "file:/keystore/store.pass" --key-pass "file:/keystore/store.pass"
  unzip -q -o "$tmp/universal.apks" universal.apk -d "$tmp"
  "$ANDROID_HOME/build-tools/$bt/aapt2" dump badging "$tmp/universal.apk" | grep -E "^package:|^application-label:|^native-code|^sdkVersion|^targetSdkVersion"
  "$ANDROID_HOME/build-tools/$bt/apksigner" verify --print-certs "$tmp/universal.apk" | grep -E "certificate SHA-256|certificate DN"
  log "launcher icon background colour and icon files in the bundle"
  bundletool dump resources --bundle "$aab" --values | grep -A 2 "ic_launcher_background" | grep -i -E "ic_launcher_background|#" | head -n 3
  unzip -l "$aab" | grep -E "base/res/mipmap-[a-z]+(-v4)?/(ic_launcher|ic_launcher_round|ic_launcher_foreground|ic_stat_logo)\.png" | wc -l
  log "16 KB memory pages for 64-bit native libraries"
  python3 /recipe/check_elf_align.py "$aab"
  log "built-in server and key, no RustDesk public server"
  local abi s
  for abi in $ABIS; do
    for s in rd.emillis.net EbM3IT7TgSkeeyQpDqmXbo1wvrVz8GG4inwI332DS0A= rs-ny.rustdesk.com OeVuKk5nlHiXp+APNn0Y3pC1Iwpwn44JGqrQCsWqmBw=; do
      echo "base/lib/$abi/librustdesk.so contains '$s': $(unzip -p "$aab" "base/lib/$abi/librustdesk.so" | grep -a -F -c "$s" || true) line(s)"
    done
  done
  log "update check off in the source that was built"
  grep -n -A 4 "pub fn check_software_update" "$SRC/src/common.rs"
  rm -rf "$tmp"
  sha256sum "$aab"
  stat -c '%s bytes' "$aab"
}

case "${1:-all}" in
  clone) step_clone ;;
  patch) step_patch ;;
  bridge) step_bridge ;;
  deps) step_deps "$2" ;;
  lib) step_lib "$2" ;;
  apk) step_apk ;;
  verify) step_verify ;;
  aab) step_aab ;;
  verify-aab) step_verify_aab ;;
  all)
    step_clone; step_patch; step_bridge
    for abi in $ABIS; do step_deps "$abi"; step_lib "$abi"; done
    step_apk; step_verify ;;
  play)
    step_clone; step_patch; step_bridge
    for abi in $ABIS; do step_deps "$abi"; step_lib "$abi"; done
    step_aab; step_verify_aab ;;
  *) echo "unknown step $1" >&2; exit 2 ;;
esac
