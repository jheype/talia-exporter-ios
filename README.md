# Talia Exporter

Private iOS control application and server-side WhatsApp capture service for Talia.

## Repository layout

```text
TaliaExporter/       Native SwiftUI application
ExporterBackend/     Go API and long-running WhatsApp session workers
docs/                Architecture and v14 integration boundary
```

## iOS application

The app targets iOS 17 and later. It uses the existing v14 authentication endpoints, requests phone-number pairing, discovers groups, stores a minimal encrypted dashboard cache and controls capture through the Exporter API.

Open `TaliaExporter.xcodeproj`, select an iPhone simulator and press `Command + R`.

The default API URL is:

```text
https://api.talia.co.uk/api/v1/
```

For a Debug run, set `TALIA_API_BASE_URL` in the Xcode scheme environment to point to another deployment. The URL must include `/api/v1/`.

Before device distribution, configure the Apple team and enable these capabilities for the App ID and provisioning profile:

- Background Modes: Background fetch and Remote notifications
- Push Notifications

The checked-in `Info.plist` declares the background refresh identifier and required modes. The checked-in entitlements select the APNs development environment for Debug builds and production for Release builds.

## Exporter service

The service is in [ExporterBackend](ExporterBackend). It owns linked WhatsApp sessions and remains active independently of the iPhone application. It provides:

- v14-backed authentication without a duplicate user store;
- phone-number pairing;
- group discovery and transactional selection;
- real-time and available history capture for group conversations;
- typed metadata for supported media messages without persisting message bodies on the iPhone;
- edit and revoke handling against the original WhatsApp message identifier;
- deduplication using original WhatsApp message identifiers;
- PostgreSQL persistence and restart recovery;
- stable cursor APIs for messages and operational events;
- an idempotent delivery outbox for the later v14 page/ingestion bridge.

Run its checks with Go 1.25 or later:

```sh
cd ExporterBackend
make check
```

## Source architecture

- `App/` — dependency composition, root model and navigation state.
- `Domain/` — API/domain entities with no feature ownership.
- `Infrastructure/Networking/` — typed HTTP client and Exporter API boundary.
- `Infrastructure/Persistence/` — Keychain-backed encrypted cache.
- `Infrastructure/Background/` — iOS background refresh coordination.
- `Infrastructure/Notifications/` — notification permission and APNs registration boundary.
- `Features/` — independent SwiftUI feature views.
- `Preview/` — preview-only fixtures.
- `DesignSystem/` — Talia tokens and reusable native components.

The complete service design is documented in [Architecture](docs/ARCHITECTURE.md). The planned v14 bridge is documented in [Future v14 integration](docs/V14_INTEGRATION.md).

## Xcode project generation

The checked-in project already contains every source. `project.yml` is the reproducible XcodeGen definition:

```sh
brew install xcodegen
xcodegen generate
```

Keep production credentials, Apple signing material and local `.env` files out of the repository.
