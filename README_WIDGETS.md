# Talia iOS widgets

The application ships three WidgetKit widgets:

- **Talia Tasks** for task totals and progress;
- **Talia Messages** for selected Task and Log group messages; and
- **UK Chats Coverage** for captured messages, active Exporter Mention groups
  and discarded messages over 24 hours, 7 days or 30 days.

Users configure all widget filters and privacy choices in **Settings →
Configure iOS widgets**. The host app writes an account-bound, sanitised
snapshot to the shared App Group and reloads WidgetKit timelines. The snapshot
is removed on unlink, sign-out, account mismatch or account change.

## Apple signing configuration

Before archiving, create or enable the App Group
`group.com.talia.exporter.shared` for both App IDs:

- `com.talia.exporter`
- `com.talia.exporter.widgets`

Regenerate the two provisioning profiles after adding the capability. Keep
the same App Group value in both entitlements files. The widget target is
embedded by the `TaliaExporter` target and must use the same Apple Developer
team.

## Build check

Open `TaliaExporter.xcodeproj`, select the `TaliaExporter` scheme and an iOS
17+ simulator, then run:

```sh
xcodebuild -project TaliaExporter.xcodeproj \
  -scheme TaliaExporter \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  CODE_SIGNING_ALLOWED=NO build
```

For TestFlight, increment `CURRENT_PROJECT_VERSION` for the host application
and widget extension together, archive the `TaliaExporter` scheme and validate
the archive before distribution.
