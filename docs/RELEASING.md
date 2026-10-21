# Releasing to TestFlight

Once the API key below is in place, a release is one command:

```bash
./tools/release_testflight.sh --bump
```

That bumps the build number, archives, and uploads to App Store Connect. Apple
emails when processing finishes; the build then appears under
**TestFlight → iOS builds**.

Use `--dry-run` to archive and export an IPA without uploading. It also asserts
the IPA is *distribution* signed, which is worth knowing before a release rather
than after a rejection.

## One-time setup: an App Store Connect API key

Uploading needs to authenticate. An API key is preferable to an Apple ID
password because it carries no interactive login, it can be scoped and revoked
on its own, and nothing has to be typed into a prompt at release time.

1. In [App Store Connect](https://appstoreconnect.apple.com/), go to
   **Users and Access → Integrations → App Store Connect API**.
2. Create a key with the **App Manager** role (the least privilege that can
   still upload builds).
3. Download the `AuthKey_<KEY_ID>.p8`. **Apple allows this download once.** If
   it is lost, revoke the key and issue a new one.
4. Put it in place and lock the permissions down:

   ```bash
   mkdir -p ~/.appstoreconnect/private_keys
   chmod 700 ~/.appstoreconnect ~/.appstoreconnect/private_keys
   mv ~/Downloads/AuthKey_*.p8 ~/.appstoreconnect/private_keys/
   chmod 600 ~/.appstoreconnect/private_keys/*.p8
   ```

5. Record the key's identifiers — the **Key ID** is on the key's row, the
   **Issuer ID** is at the top of the same page:

   ```bash
   cat > ~/.appstoreconnect/talia.env <<'ENV'
   ASC_KEY_ID=XXXXXXXXXX
   ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
   ENV
   chmod 600 ~/.appstoreconnect/talia.env
   ```

The key and that file live outside the repository and are covered by
`.gitignore` (`*.p8`, `*.env`) as a second line of defence. Never commit either.

## What the release script checks so you don't have to

- **Distribution signing.** An `Apple Development` certificate produces a
  perfectly valid archive that App Store Connect then refuses. On `--dry-run`
  the script reads the IPA's signing authority and fails if it is not
  `Apple Distribution`.
- **The build number in all three places.** It lives in `project.yml` (the
  XcodeGen source) *and* in both the Debug and Release configs of the committed
  `project.pbxproj`. Miss one and `xcodegen generate` quietly reverts the
  release. `--bump` updates all three.

## Things that will stop a build reaching testers

- **No app icon.** `AppIcon.appiconset` must contain a 1024×1024 PNG with **no
  alpha channel**, and `ASSETCATALOG_COMPILER_APPICON_NAME` must be set —
  without that setting `actool` ignores the catalogue and ships an iconless
  build that is rejected on upload. Regenerate the icon with
  `python3 tools/make_app_icon.py`.
- **Missing Compliance.** `ITSAppUsesNonExemptEncryption` is declared `false` in
  `Info.plist` because the app uses only standard HTTPS/TLS. Without that key
  every build stalls in TestFlight until somebody answers the prompt by hand.
- **A repeated build number.** App Store Connect refuses a build number it has
  already seen. The version stays `0.1.0`; the build number climbs.
