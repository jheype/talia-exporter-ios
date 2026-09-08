# Talia Exporter iOS 0.3

Native SwiftUI Exporter with the approved graphite and warm-white design, five tabs, and the v14 Tasks workspace. Minimum iOS 17. No web view or second login.

## Included

- Home: capture state, pause/resume, group selection, task overview and latest messages.
- Groups: search, selected/all views, routing to UK Chats, Tasks, operations logs or personal notes; history progress and retry in group settings.
- Tasks: status board, search, assignee/priority/date/project filters, cursor pagination, task creation and details, checklist, assignment, due dates, progress, messages, notes and attributed history.
- Ideas: shared boards and General, creation, editing, image upload, move/resize/colour controls, zoom, connections, image nodes and removal.
- Inbox: attach unassigned messages to a task in the same group.
- Operations log: severity/search filters and cursor pagination.
- My Notes: private creation, editing, completion, deadlines with date/time, and deletion.
- Activity: capture timeline, date/type/search filters and live feed.
- Settings: account, capture, interruption alerts, system/light/dark appearance and widget preferences.
- Widgets: Tasks (small/medium/large), Messages (medium/large), UK Chats coverage (small/medium), app links and immediate privacy masking.

## Open and run

1. Open `TaliaExporter.xcodeproj` in Xcode 16.4 or newer.
2. Select the **TaliaExporter** scheme and an iPhone simulator; run.
3. For a physical iPhone, select your signing team for the app and widget targets. Both targets use `group.com.talia.exporter.shared`; enable that App Group for both identifiers in your Apple developer account.
4. Sign in with your existing Talia account. WhatsApp pairing remains optional for using the shared Tasks workspace and private notes.

The default API is `https://api.talia.co.uk/api/v1/`, configured in `TaliaExporter/Resources/Info.plist`. The existing cookie session and token refresh are shared across capture and workspace APIs. This is source code, not a signed IPA or TestFlight release.

`project.yml` is the source for regenerating the checked-in project with XcodeGen:

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project TaliaExporter.xcodeproj -scheme TaliaExporter \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  CODE_SIGNING_ALLOWED=NO test
```

Choose an installed simulator name if it differs. For iPhone 17 simulation, use an Xcode installation that includes that device runtime.

## Validation

GitHub Actions builds the app and widget extension on macOS and runs the regression suite covering authentication, account isolation, capture recovery, workspace API payloads, pagination, conflicts, private data reset and widget sanitisation. It also renders all five tabs in light and dark with isolated test fixtures, exporting the screenshots and test result bundle as `ios-validation`.

Production screens load API data. Fixtures are used by previews and tests. Rendering checks do not exercise live WhatsApp pairing, APNs delivery, production uploads or installation on a physical iPhone; those require an authenticated device and configured backend services.

## Backend compatibility

Contracts were checked against v14 revision `c38011c79b79a147f2b129c1c6392e679906d79c`. The app calls existing `exporter/tasks`, `task-messages`, `personal-notes`, `logs`, `idea-boards`, `idea-nodes`, `idea-connections`, and authorised image-access endpoints. This change adds no database migration or backend deployment.

Edits send expected versions. Conflicts load the latest server state and require review before retrying. Account changes discard late reads and cancel in-flight workspace writes. Non-idempotent writes are not automatically retried after ambiguous failures. Photos are resized to JPEG before upload; downloaded thumbnails stay in memory and use a cookie-free session with an 8 MiB limit.

Coverage shows the selected **rolling period**, not an inferred calendar-day count. The Inbox endpoint returns at most 200 messages per request; attaching messages and refreshing reveals the remaining items. Creating a task requires a group currently routed to Tasks on a linked, selected capture session. WhatsApp replies depend on the existing server delivery configuration.

Previous capture recovery notes are preserved in `docs/capture-recovery-history.md`.

## Apple Calendar

In **Settings → Apple Calendar**, enable synchronisation, allow full Calendar access and choose a writable calendar. Include Tasks, My Notes or both. The task assignee picker can limit the shared board to one responsible person; **All tasks** is explicit and does not infer a person's identity from their email.

Upcoming open deadlines are five-minute events with an alarm at the deadline. Completing, deleting, removing a deadline or changing the inclusion filters removes the corresponding exported event. Past deadlines are not newly exported and their events are retired on the next sync. Edits in Calendar do not change Talia; edit the source task or note. Personal-note first lines are visible in the chosen calendar and its alerts, so choose a private calendar for private notes.

The app refreshes at most once per minute while open, immediately after workspace changes, and during iOS background refresh opportunities. Previously saved Calendar alarms do not require Talia to remain open. iOS determines background scheduling and notification delivery, so changes made elsewhere are **not guaranteed to reach a closed app immediately**. Calendar notifications and Focus settings control whether an alert is shown.

This uses [EventKit full access](https://developer.apple.com/documentation/eventkit/accessing-calendar-using-eventkit-and-eventkitui) because events must be updated and removed. Only events matching Talia's deterministic links are modified. The recovery ledger stores identities and dates, without task titles or note text. Turning sync off or signing out removes saved Talia events when permission remains available; if access was revoked, restore it or remove those events in Calendar. No Apple credentials or personal calendar data are sent to Talia.

Deploy the companion v14 Exporter API change **before** enabling this feature: `GET exporter/calendar/deadlines`, `GET exporter/personal-notes/{id}`, and explicit nullable `due_at` with optional `expected_updated_at` on note writes. The existing `due_at` column and index are reused; no new migration is needed. The native client refuses partial or differently owned snapshots, preserving existing reminders on fetch failures. This endpoint avoids the board's pagination and the normal notes list's 500-row cap; a snapshot over 5,000 upcoming items is explicitly incomplete and requires a narrower selection.

Calendar permissions and notification delivery still need acceptance on a signed physical-device build.
