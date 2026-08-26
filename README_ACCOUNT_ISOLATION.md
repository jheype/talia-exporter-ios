# Talia Exporter iOS — account/session isolation fix

## What this fixes

The iOS app must never show one Talia user's WhatsApp session or group list to
another Talia user. This patch adds defence in depth on the native client:

- clears any previous `access_token` and `refresh_token` cookies before login;
- confirms the login identity with `GET /auth/me` before loading Exporter data;
- accepts an `ExporterSession` only when its `user_id` equals the authenticated
  Talia user's `id`;
- partitions the encrypted dashboard cache by Talia `user_id`;
- migrates the old global cache only when its embedded session belongs to the
  currently authenticated user;
- clears session, groups, activity, pairing state and message state on account
  changes and logout;
- fails closed, removes local authentication and shows no groups when the
  backend returns cross-account session data.

The app continues to use the v14 `httpOnly` cookie contract. The access and
refresh tokens are deliberately not copied into `UserDefaults` or Keychain.

## Backend dependency

Deploy the Exporter account-isolation backend patch before releasing this app.
The required behaviour is:

- `GET /exporter/session` resolves by authenticated `user_id` only;
- `GET /exporter/dashboard` returns that same user's session/groups;
- `GET /exporter/groups` and `POST /exporter/groups/history-sync` are scoped to
  that user's WhatsApp session;
- there is no fallback to another user's active session;
- the Exporter auth proxy does not forward a stale cookie together with an
  explicit Bearer credential.

Without that backend deployment the iOS build will intentionally block a
cross-account session instead of showing it.

## Files changed

- `TaliaExporter/Infrastructure/Networking/APIClient.swift`
- `TaliaExporter/Infrastructure/Networking/ExporterAPI.swift`
- `TaliaExporter/Infrastructure/Persistence/SecureCache.swift`
- `TaliaExporter/App/AppModel.swift`
- `TaliaExporter/App/AppModel+Authentication.swift`
- `TaliaExporter/App/AppModel+Connection.swift`
- `TaliaExporter/App/AppModel+Capture.swift`

Tests added:

- `TaliaExporterTests/AccountIsolationTests.swift`
- `TaliaExporterTests/APIClientAuthenticationTests.swift`

## Xcode integration

The supplied ZIP did not contain an `.xcodeproj` or `.xcworkspace`. Replace the
matching source files in the existing Xcode project. Add both files under
`TaliaExporterTests/` to the existing unit-test target; do not add them to the
application target.

Then run:

```bash
xcodebuild \
  -scheme TaliaExporter \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  clean test
```

If the simulator name differs, list installed devices with:

```bash
xcrun simctl list devices available
```

## Manual acceptance check

1. Deploy the backend account-isolation patch.
2. Install the updated app and sign in as João.
3. Confirm João's own WhatsApp link/groups.
4. Sign out from Settings.
5. Sign in as Lucas.
6. Confirm João's session/groups never flash on screen.
7. If Lucas has no linked WhatsApp, confirm the connection intro is shown with
   an empty group list.
8. Link Lucas's WhatsApp and confirm only Lucas's groups appear.
9. Relaunch the app and confirm the correct account-scoped cache is restored.
10. Revoke/expire the login and confirm local session/group data is cleared.

