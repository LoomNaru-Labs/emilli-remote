#!/usr/bin/env bash
# CI build of the Android app "Emilli 원격" from this branch as committed (no patch step: the
# patches are commits here), run by .github/workflows/build-android-emilli.yml inside the
# toolchain image (../Dockerfile). Same steps and toolchain as the Play recipe (../build.sh) for
# the bridge, the vcpkg packages and the native libraries.
#
# The result is UNSIGNED: no key of ours is on GitHub and none is made here. Gradle's release
# signing line is removed for this build only, so the bundle and the universal APK made from it
# carry no signature; the lead signs them on the build PC with the existing key (commands in
# .github/README.md). No debug key is made either (checked at the end).
#
# Mounts: this branch at /work/rustdesk, ../ at /recipe (read only), a cache folder at
# /work/cache and an output folder at /work/out.
#   bash /recipe/ci/build-ci.sh all
set -euo pipefail

SRC=/work/rustdesk
OUT=/work/out
ABIS="arm64-v8a armeabi-v7a"
BUNDLETOOL_VERSION=1.18.3
BUNDLETOOL_SHA256=a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29
BUNDLETOOL=/work/cache/bundletool-all-${BUNDLETOOL_VERSION}.jar
mkdir -p "$OUT" /work/cache

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

version_name() { sed -n 's/^version: \([0-9.]*\)+[0-9]*$/\1/p' "$SRC/flutter/pubspec.yaml"; }
version_code() { sed -n 's/^version: .*+\([0-9]*\)$/\1/p' "$SRC/flutter/pubspec.yaml"; }
base_name() { echo "emilli-remote-$(version_name)-vc$(version_code)"; }

step_prepare() {
  # Build-environment tweaks copied from upstream CI (Gradle heap, Flutter SDK patch), as ../build.sh.
  sed -i "s/org.gradle.jvmargs=-Xmx1024M/org.gradle.jvmargs=-Xmx2g/g" "$SRC/flutter/android/gradle.properties"
  local fdiff="$SRC/.github/patches/flutter_3.24.4_dropdown_menu_enableFilter.diff"
  if git -C "$FLUTTER_ROOT" apply --reverse --check "$fdiff" 2>/dev/null; then
    log "flutter sdk patch already applied"
  else
    git -C "$FLUTTER_ROOT" apply "$fdiff"
    log "flutter sdk patch applied"
  fi
  # Unsigned release build: drop the release signing line (this build only, not committed).
  sed -i '/signingConfig signingConfigs.release/d' "$SRC/flutter/android/app/build.gradle"
  log "release signing lines left in build.gradle: $(grep -c 'signingConfig signingConfigs' "$SRC/flutter/android/app/build.gradle" || true)"
  grep -n "^version:" "$SRC/flutter/pubspec.yaml"
}

step_libs() {
  bash /recipe/build.sh bridge
  local abi
  for abi in $ABIS; do
    bash /recipe/build.sh deps "$abi"
    bash /recipe/build.sh lib "$abi"
  done
}

step_aab() {
  cd "$SRC/flutter"
  log "flutter build appbundle --release (unsigned)"
  flutter build appbundle --release --target-platform android-arm64,android-arm
  cp build/app/outputs/bundle/release/app-release.aab "$OUT/$(base_name)-unsigned.aab"
  ls -la "$OUT"
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

step_apk() {
  # The universal APK (both ABIs) made from the bundle, as bundletool does for Play; unsigned
  # because no key is given and no debug key exists.
  local aab tmp
  aab="$OUT/$(base_name)-unsigned.aab"
  tmp="$(mktemp -d)"
  test ! -e "$HOME/.android/debug.keystore" || { echo "a debug key exists; refusing to sign with it" >&2; exit 4; }
  bundletool build-apks --bundle "$aab" --output "$tmp/universal.apks" --mode universal
  unzip -q -o "$tmp/universal.apks" universal.apk -d "$tmp"
  cp "$tmp/universal.apk" "$OUT/$(base_name)-universal-unsigned.apk"
  rm -rf "$tmp"
  ls -la "$OUT"
}

# Each check prints PASS or FAIL; the build fails on any FAIL. Results also go to checks.txt.
step_verify() {
  local aab apk bt tmp fails=0
  aab="$OUT/$(base_name)-unsigned.aab"
  apk="$OUT/$(base_name)-universal-unsigned.apk"
  bt="$(ls "$ANDROID_HOME/build-tools" | sort -V | tail -n 1)"
  tmp="$(mktemp -d)"
  check() { if [ "$2" = ok ]; then echo "PASS $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
  yes_if() { if eval "$1"; then echo ok; else echo no; fi; }
  {
    log "bundle manifest (bundletool $BUNDLETOOL_VERSION)"
    bundletool dump manifest --bundle "$aab" > "$tmp/manifest.xml"
    grep -o -E 'package="[^"]*"|android:versionCode="[^"]*"|android:versionName="[^"]*"|android:minSdkVersion="[^"]*"|android:targetSdkVersion="[^"]*"' "$tmp/manifest.xml"
    grep -o -E '<uses-permission[^>]*android:name="[^"]*"' "$tmp/manifest.xml" | sed 's/.*android:name=/permission /'
    check "package net.emillis.remote" "$(yes_if "grep -q 'package=\"net.emillis.remote\"' $tmp/manifest.xml")"
    check "versionCode $(version_code), versionName $(version_name)" "$(yes_if "grep -q 'android:versionCode=\"$(version_code)\"' $tmp/manifest.xml && grep -q 'android:versionName=\"$(version_name)\"' $tmp/manifest.xml")"
    check "targetSdkVersion 36" "$(yes_if "grep -q 'android:targetSdkVersion=\"36\"' $tmp/manifest.xml")"
    check "no storage permission" "$(yes_if "! grep -q -E 'READ_EXTERNAL_STORAGE|WRITE_EXTERNAL_STORAGE|MANAGE_EXTERNAL_STORAGE' $tmp/manifest.xml")"
    check "Accessibility service named 'Emilli 원격 입력'" "$(yes_if "grep -q 'Emilli 원격 입력' $tmp/manifest.xml")"
    log "signature state (unsigned on purpose)"
    jarsigner -verify "$aab" | tail -n 1 || true
    check "bundle is unsigned" "$(yes_if "jarsigner -verify '$aab' | grep -q 'jar is unsigned'")"
    check "universal APK is unsigned" "$(yes_if "! '$ANDROID_HOME/build-tools/$bt/apksigner' verify '$apk' > /dev/null 2>&1")"
    check "no debug key was made" "$(yes_if "test ! -e '$HOME/.android/debug.keystore'")"
    log "universal APK badging (aapt2 $bt)"
    "$ANDROID_HOME/build-tools/$bt/aapt2" dump badging "$apk" > "$tmp/badging.txt"
    grep -E "^package:|^application-label:|^native-code|^sdkVersion|^targetSdkVersion" "$tmp/badging.txt"
    check "label 'Emilli 원격'" "$(yes_if "grep -q \"application-label:'Emilli 원격'\" $tmp/badging.txt")"
    check "native code arm64-v8a and armeabi-v7a" "$(yes_if "grep -q \"native-code: 'arm64-v8a' 'armeabi-v7a'\" $tmp/badging.txt")"
    log "launcher icon background colour and icon files"
    bundletool dump resources --bundle "$aab" --values > "$tmp/res.txt"
    grep -A 2 "ic_launcher_background" "$tmp/res.txt" | head -n 3
    check "icon background #faf7f2" "$(yes_if "grep -A 2 ic_launcher_background $tmp/res.txt | grep -qi faf7f2")"
    check "15 launcher and notification icon files" "$(yes_if "[ \"\$(unzip -l '$aab' | grep -c -E 'base/res/mipmap-[a-z]+(-v4)?/(ic_launcher|ic_launcher_foreground|ic_stat_logo)\.png')\" = 15 ]")"
    log "16 KB memory pages for 64-bit native libraries"
    local align=no
    if python3 /recipe/check_elf_align.py "$aab" > "$tmp/align.txt"; then align=ok; fi
    cat "$tmp/align.txt"
    check "16 KB pages for every 64-bit library" "$align"
    log "built-in server and key, no RustDesk public server"
    local abi s n
    for abi in $ABIS; do
      unzip -p "$aab" "base/lib/$abi/librustdesk.so" > "$tmp/lib.so"
      for s in rd.emillis.net EbM3IT7TgSkeeyQpDqmXbo1wvrVz8GG4inwI332DS0A= rs-ny.rustdesk.com OeVuKk5nlHiXp+APNn0Y3pC1Iwpwn44JGqrQCsWqmBw= emilli_codec_title emilli_install_for_system_prompts; do
        n="$(grep -a -F -c "$s" "$tmp/lib.so" || true)"
        echo "base/lib/$abi/librustdesk.so contains '$s': $n line(s)"
      done
      check "$abi: our server and key built in" "$(yes_if "grep -a -q -F rd.emillis.net $tmp/lib.so && grep -a -q -F EbM3IT7TgSkeeyQpDqmXbo1wvrVz8GG4inwI332DS0A= $tmp/lib.so")"
      check "$abi: no RustDesk public server or key" "$(yes_if "! grep -a -q -F rs-ny.rustdesk.com $tmp/lib.so && ! grep -a -q -F OeVuKk5nlHiXp+APNn0Y3pC1Iwpwn44JGqrQCsWqmBw= $tmp/lib.so")"
      check "$abi: codec title and hints in the strings" "$(yes_if "grep -a -q -F 'emilli_codec_hint_av1' $tmp/lib.so && grep -a -q -F '가장 또렷합니다' $tmp/lib.so")"
      unzip -p "$aab" "base/lib/$abi/libapp.so" > "$tmp/app.so"
      check "$abi: the app uses the codec title, hints and the main-page codec entry" "$(yes_if "grep -a -q -F emilli_codec_title $tmp/app.so && grep -a -q -F emilli_codec_hint_ $tmp/app.so")"
    done
    log "update check off in the source that was built"
    grep -n -A 5 "^pub fn check_software_update" "$SRC/src/common.rs"
    check "update check returns at once" "$(yes_if "grep -A 5 '^pub fn check_software_update' $SRC/src/common.rs | grep -q 'return;'")"
    log "files"
    (cd "$OUT" && sha256sum ./*.aab ./*.apk && stat -c '%n %s bytes' ./*.aab ./*.apk)
    echo "checks failed: $fails"
  } 2>&1 | tee "$OUT/checks.txt"
  rm -rf "$tmp"
  grep -q '^checks failed: 0$' "$OUT/checks.txt"
}

case "${1:-all}" in
  prepare) step_prepare ;;
  libs) step_libs ;;
  aab) step_aab ;;
  apk) step_apk ;;
  verify) step_verify ;;
  all) step_prepare; step_libs; step_aab; step_apk; step_verify ;;
  *) echo "unknown step $1" >&2; exit 2 ;;
esac
