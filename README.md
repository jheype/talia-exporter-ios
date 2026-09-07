# Talia Exporter iOS 0.2

Native SwiftUI Exporter with the approved graphite and warm-white design, five tabs, and the v14 Tasks workspace. Minimum iOS 17. No web view or second login.

## Included

- Home: capture state, pause/resume, group selection, task overview and latest messages.
- Groups: search, selected/all views, routing to UK Chats, Tasks, operations logs or personal notes; history progress and retry in group settings.
- Tasks: status board, search, assignee/priority/date/project filters, cursor pagination, task creation and details, checklist, assignment, due dates, progress, messages, notes and attributed history.
- Ideas: shared boards and General, creation, editing, image upload, move/resize/colour controls, zoom, connections, image nodes and removal.
- Inbox: attach unassigned messages to a task in the same group.
- Operations log: severity/search filters and cursor pagination.
- My Notes: private creation, editing, completion and deletion.
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

GitHub Actions builds the app and widget extension on macOS and runs 21 tests covering authentication, account isolation, capture recovery, workspace API payloads, pagination, conflicts, private data reset and widget sanitisation. It also renders all five tabs in light and dark with isolated test fixtures, exporting the screenshots and test result bundle as `ios-validation`.

Production screens load API data. Fixtures are used by previews and tests. Rendering checks do not exercise live WhatsApp pairing, APNs delivery, production uploads or installation on a physical iPhone; those require an authenticated device and configured backend services.

## Backend compatibility

Contracts were checked against v14 revision `c38011c79b79a147f2b129c1c6392e679906d79c`. The app calls existing `exporter/tasks`, `task-messages`, `personal-notes`, `logs`, `idea-boards`, `idea-nodes`, `idea-connections`, and authorised image-access endpoints. This change adds no database migration or backend deployment.

Edits send expected versions. Conflicts load the latest server state and require review before retrying. Account changes discard late reads and cancel in-flight workspace writes. Non-idempotent writes are not automatically retried after ambiguous failures. Photos are resized to JPEG before upload; downloaded thumbnails stay in memory and use a cookie-free session with an 8 MiB limit.

Coverage shows the selected **rolling period**, not an inferred calendar-day count. The Inbox endpoint returns at most 200 messages per request; attaching messages and refreshing reveals the remaining items. Creating a task requires a group currently routed to Tasks on a linked, selected capture session. WhatsApp replies depend on the existing server delivery configuration.

Previous capture recovery notes are preserved in `docs/capture-recovery-history.md`.
