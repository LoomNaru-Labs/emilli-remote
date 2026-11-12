# Emilli Remote for Android (branch `android-153`)

This branch holds the exact source of the Android app "Emilli 원격"
(`net.emillis.remote`) that LoomNaru Labs Inc builds: RustDesk 1.5.3 with a few
changes so the app uses our server `rd.emillis.net` out of the box, plus a
findable codec choice. The list of changes is in [NOTICE](../NOTICE); each
change is one commit, so `git log` shows them in order.

## How it is built

[`build-android-emilli.yml`](workflows/build-android-emilli.yml) builds it on a
GitHub runner in the toolchain image of [`build-android/`](../build-android)
(`Dockerfile`, same versions as upstream's CI at 1.5.3: Rust 1.75, NDK r28c,
Flutter 3.24.5, vcpkg pinned) with `build-android/ci/build-ci.sh`: bridge,
native libraries for arm64-v8a and armeabi-v7a, the app bundle and a universal
APK made from it, and the checks. Both files are **unsigned**: no signing key is
on GitHub. To sign them on the build PC with the existing key (alias
`emilli-rustdesk`):

```sh
# Google Play upload (the key is the upload key)
jarsigner -keystore emilli-rustdesk-release.p12 -storetype PKCS12 \
  -digestalg SHA-256 -sigalg SHA256withRSA app-unsigned.aab emilli-rustdesk
# APK for direct installs
zipalign -p -f 4 app-universal-unsigned.apk app-aligned.apk
apksigner sign --ks emilli-rustdesk-release.p12 --ks-key-alias emilli-rustdesk \
  --out app-universal.apk app-aligned.apk
```

Nothing is released from this branch.

## Licence

RustDesk is licensed under the [GNU AGPL-3.0](../LICENCE), and so is this modified
version. This is not an official RustDesk build and is not supported by the
RustDesk developers. For the official apps, go to <https://rustdesk.com> or
<https://github.com/rustdesk/rustdesk>.
