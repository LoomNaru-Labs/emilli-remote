# Emilli Remote

A configured build of [RustDesk](https://github.com/rustdesk/rustdesk) 1.5.0 for
our own RustDesk server, `rd.emillis.net`. It is made by LoomNaru Labs Inc for the
people who use that server, so they can install the app without typing any server
settings.

What differs from official RustDesk (details in [NOTICE](../NOTICE) and the git
history):

- The app uses `rd.emillis.net` and that server's public key out of the box, and
  `https://rd.emillis.net` for account login.
- On Mac and iPhone the bundle id is `com.loomnarulabs.emilliremote` and the
  displayed name is "Emilli Remote".
- On Mac the app is `Emilli Remote.app`, so it installs next to an official
  RustDesk instead of replacing it, with its own settings, its own device ID and its
  own background service. Direct IP access is always off, the app never updates
  itself from official RustDesk, and its update and download actions only say that
  your administrator sends new versions. The icon is still RustDesk's.
- The only build here is [`build-apple.yml`](workflows/build-apple.yml), which builds
  the Mac app (Apple Silicon) and the iPhone app on GitHub's macOS runners. Our
  Android app is built elsewhere from the same RustDesk 1.5.0 source with the same
  server changes plus a few Android-only ones.

The apps are not signed yet, so they are not ready to hand out. Signing and
TestFlight are described in [docs/APPLE_SIGNING_NEXT.md](../docs/APPLE_SIGNING_NEXT.md).

The upstream README is kept unchanged at [README.md](../README.md).

## Licence

RustDesk is licensed under the [GNU AGPL-3.0](../LICENCE), and so is this modified
version. This repository is public so that anyone who receives one of these apps
can get the exact source it was built from.

This is not an official RustDesk build and is not supported by the RustDesk
developers. For the official apps, go to <https://rustdesk.com> or
<https://github.com/rustdesk/rustdesk>.
