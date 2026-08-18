# Architecture

## Components

### iOS application

The SwiftUI application handles v14 sign-in, pairing initiation, group selection, capture controls and operational views. It stores only an encrypted dashboard cache. WhatsApp device credentials and captured message bodies are not persisted locally.

### Exporter API and worker

The Go service exposes the iOS contract and owns the linked WhatsApp clients. A session manager restores clients after a restart, renews database leases and serialises protocol events per session.

Permanent connection failures are sent through an isolated APNs adapter. APNs signing material remains server-side; invalid device tokens are removed automatically.

### PostgreSQL

`exporter_sessions` is the aggregate root. Groups, text messages, operational events and APNs devices are scoped to it. `whatsmeow` uses its own tables in the same PostgreSQL cluster for device identity and encryption state. The legacy delivery-outbox table is retained only for schema compatibility and is not populated by capture.

### v14

v14 remains responsible for users, passwords, token rotation, revocation and future message ingestion. The Exporter verifies identity through v14 instead of decoding or issuing v14 tokens itself.

## Capture lifecycle

1. The iOS app signs in through v14 and receives secure, HTTP-only cookies.
2. It asks the Exporter for a pairing code using an international phone number.
3. The Exporter opens a pre-login WhatsApp client and returns the short-lived code.
4. Once WhatsApp confirms the link, device keys are persisted server-side and groups are discovered.
5. History arriving before group selection is held with `capture_state = pending`.
6. Saving the group selection promotes text from chosen groups, removes pending records from unchosen groups and queues a resumable on-demand history pass.
7. The worker requests older messages in bounded batches, persists its per-group cursor and repeats until WhatsApp explicitly reports that no older available batch remains. A short batch is never treated as completion. A missing anchor, timeout, repeated cursor, decode failure or protocol response saying older messages exist but are inaccessible is visible and retryable instead of being mistaken for completion.
8. New text messages are accepted only when capture is enabled and their group is selected. Images, image captions and media metadata are discarded. Edits and revokes still update an already captured record so stored state does not become stale after a pause or selection change.
9. Captured text remains staged. On the v14 Exporter Chats page, a person selects messages, reviews a confirmation dialog and presses **Confirm and ingest into v14**. Only then are WhatsApp-format text files submitted to `/api/v2/upload/`.

Pending history is retained for 24 hours by default and then purged if group selection was never completed.

## Consistency and recovery

- `(session_id, group_jid, whatsapp_message_id)` is unique.
- Cursor pagination uses `(timestamp, UUID)` to remain stable when timestamps match.
- Session leases prevent two service replicas from opening the same WhatsApp device identity.
- Device credentials and capture records survive app closure, phone network loss and service restarts.
- iOS refresh tasks update presentation state only; they are not part of the capture guarantee.
- Capture progress is durable per group (state, batches, requests, oldest timestamp and last error), so app closure or pod restart does not erase operational visibility.
- The history total is unknowable in advance because WhatsApp supplies batches from the primary phone. Active progress is therefore indeterminate; `complete` means WhatsApp explicitly exhausted the history available to the linked client. If the protocol says older messages remain but cannot be accessed, the group is `stalled` with that reason rather than shown as complete.
- No automatic path exists from capture to v14 ingestion.

## Security decisions

- Mutation requests require the non-simple `X-Talia-Client` header in addition to v14 authentication.
- The Exporter forwards only `Cookie`, `Authorization`, request ID and fixed internal headers to v14.
- Request bodies and headers are bounded; JSON rejects unknown fields.
- Passwords and tokens never enter Exporter storage or logs.
- APNs provider keys are loaded from a mounted secret and never included in the image or repository.
- API error responses are stable and do not expose internal failures.
