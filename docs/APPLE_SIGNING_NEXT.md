# Signing the Mac and iPhone apps (next step)

Today `build-apple.yml` makes an unsigned Mac `.dmg` and an unsigned iPhone `.ipa`.
Neither can be handed out: macOS blocks an app that is not signed with a
Developer ID and notarised, and an iPhone only installs apps signed by Apple
(through TestFlight or the App Store). This page lists what has to happen once
Apple's "your membership is active" email for LoomNaru Labs Inc has arrived.

## 1. Owner steps (Account Holder, in a web browser, no Mac needed)

1. **API key.** In App Store Connect, open Users and Access, then Integrations,
   then App Store Connect API, Team Keys. Click +, name it `GitHub build`, choose
   the **Admin** role, and generate it.
   - Download the `.p8` file right away. Apple allows only one download.
   - Write down the **Key ID** (in the key's row) and the **Issuer ID** (at the
     top of that page).
   - Admin is needed because Xcode uses this key to create the iPhone
     distribution certificate and profile by itself; lower roles are refused.
2. **Team ID.** On developer.apple.com, Account, Membership details: copy the
   10-character Team ID.
3. **Developer ID Application certificate (Mac).** Only the Account Holder can
   create it. The engineer makes a certificate request file (`.certSigningRequest`)
   on the PC and hands it over. In Certificates, Identifiers & Profiles, click
   Certificates, then +, choose **Developer ID Application**, upload that file,
   and download the `.cer` file.
4. **iPhone app record.** In Identifiers, register the explicit App ID
   `com.loomnarulabs.emilliremote` (the engineer can also do this with the API
   key). Then in App Store Connect, Apps, +, New App: platform iOS, name
   "Emilli Remote" (if the name is taken, add a word), bundle ID
   `com.loomnarulabs.emilliremote`, any SKU such as `emilli-remote`.
   The API cannot create this record, so it is a browser step.

Put the `.p8` and `.cer` files and the three IDs in the private credentials
folder on the build PC. Never put them in this repository, an email or a chat.

The Mac app needs no App ID or profile: its entitlements are not restricted ones.

## 2. GitHub secrets (engineer, names only)

Set in this repository under Settings, Secrets and variables, Actions
(or with `gh secret set NAME -R LoomNaru-Labs/emilli-remote < file`):

| Secret | Value | Used by |
|---|---|---|
| `APPLE_TEAM_ID` | Team ID | iPhone |
| `APPLE_API_KEY_ID` | Key ID | Mac (notarise), iPhone |
| `APPLE_API_ISSUER_ID` | Issuer ID | Mac (notarise), iPhone |
| `APPLE_API_KEY_P8` | full text of the `.p8` file | Mac (notarise), iPhone |
| `MACOS_CERT_P12` | base64 of a `.p12` made from the `.cer` plus the private key of the request file | Mac |
| `MACOS_CERT_PASSWORD` | password chosen for that `.p12` | Mac |

Making the `.p12` on the PC (Git Bash), after the owner downloads the `.cer`:

```sh
openssl x509 -inform DER -in developerID_application.cer -out devid.pem
openssl pkcs12 -export -legacy -inkey devid.key -in devid.pem -out devid.p12   # asks for the password
base64 -w0 devid.p12 > devid.p12.b64
```

`devid.key` is the private key created together with the request file:
`openssl req -new -newkey rsa:2048 -nodes -keyout devid.key -out devid.certSigningRequest -subj "/emailAddress=<owner email>/CN=LoomNaru Labs Inc/C=US"`.

## 3. What the workflow then does

The signing steps in `build-apple.yml` are marked `[signing]` and are skipped
while any of their secrets is missing. Once all are set, each run also:

- **Mac:** imports the certificate into a temporary keychain, signs the app with
  the hardened runtime (upstream's `.github/scripts/sign-macos-app.sh`), builds a
  signed `.dmg`, sends it to Apple's notary service with the API key, staples the
  ticket, checks it with `spctl`, and uploads `emilli-remote-<version>-macos-arm64`
  as a workflow artifact. That file can go on the download page.
- **iPhone:** archives the app with automatic signing (Xcode creates or reuses the
  distribution certificate and profile through the API key), and uploads the build
  to App Store Connect. It then appears in TestFlight after Apple's processing.
  Each upload gets build number 1000 + the run number.

These steps have not run yet, so expect one round of fixes on the first signed run.

## 4. After the first signed run

- TestFlight: add testers. External testers (for example by email or a public
  link) need Apple's beta review of the first build; internal testers must be
  users of our App Store Connect team.
- App Store Connect asks about encryption for each build; RustDesk uses
  encryption, so answer it once and then record the answer in `Info.plist`
  (`ITSAppUsesNonExemptEncryption`) so later builds do not ask.
- Download page: Mac `.dmg` and iPhone TestFlight link, plus a link to this
  repository as the source (AGPL-3.0).
