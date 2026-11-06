# Emilli Remote for Windows (branch `windows-emilli`)

This branch holds the exact source of the Windows program that Emilli Remote
Setup installs: RustDesk 1.5.0 with the Emilli Remote icon, no update check
against RustDesk's servers and "Emilli Remote" as the shown name. The list of
changes is in [NOTICE](../NOTICE); each change is one commit.

[`build-windows-emilli.yml`](workflows/build-windows-emilli.yml) builds it on a
GitHub Windows runner with the same tool versions and steps as upstream's
Windows job at tag 1.5.0, and keeps the unsigned self-extracting
`rustdesk-1.5.0-x86_64.exe` as an artifact. No release is published from
this branch.

## Licence

RustDesk is licensed under the [GNU AGPL-3.0](../LICENCE), and so is this
modified version. This is not an official RustDesk build and is not supported
by the RustDesk developers. For the official apps, go to <https://rustdesk.com>
or <https://github.com/rustdesk/rustdesk>.
