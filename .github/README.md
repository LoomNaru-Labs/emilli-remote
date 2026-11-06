# Emilli Remote for Android: Google Play source (branch `android-play`)

This branch holds the exact source of the Android app "Emilli 원격"
(`net.emillis.remote`) that LoomNaru Labs Inc publishes on Google Play:
RustDesk 1.5.0 with a few changes so the app uses our server `rd.emillis.net`
out of the box. The list of changes is in [NOTICE](../NOTICE); each change is one
commit, so `git log` shows them in order.

## How the Play build is made

[`build-android/`](../build-android) is the recipe, run in Docker on Linux:

- `Dockerfile`: the toolchain image, with the same versions as upstream's CI at
  tag 1.5.0 (Rust 1.75, NDK r28c, Flutter 3.24.5, vcpkg pinned).
- `build.sh step play`: clones upstream tag 1.5.0, applies `patches/01` to `06`,
  copies `icons/res`, generates the Flutter-Rust bridge, builds the native library
  for arm64-v8a and armeabi-v7a, builds the app bundle and checks it.
- The container mounts this recipe at `/recipe` (read only), the signing key folder
  at `/keystore` (read only, never in this repository) and a work volume at `/work`.

The Play build never runs on GitHub. The one workflow here,
`.github/workflows/capture-android.yml`, takes screenshots for the Emilli Remote
manual: it builds an x86_64 APK of this source for the Android emulator
(`build-android/capture/`), signed with a throwaway key, keeps it only in its own
cache and keeps the screenshots for 3 days.

## Licence

RustDesk is licensed under the [GNU AGPL-3.0](../LICENCE), and so is this modified
version. This is not an official RustDesk build and is not supported by the
RustDesk developers. For the official apps, go to <https://rustdesk.com> or
<https://github.com/rustdesk/rustdesk>.
