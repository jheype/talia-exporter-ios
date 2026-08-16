# Architecture

## Components

### iOS application

The SwiftUI application handles v14 sign-in, pairing initiation, group selection, capture controls and operational views. It stores only an encrypted dashboard cache. WhatsApp device credentials and captured message bodies are not persisted locally.

### Exporter API and worker

The Go service exposes the iOS contract and owns the linked WhatsApp clients. A session manager restores clients after a restart, renews database leases and serialises protocol events per session.

Permanent connection failures are sent through an isolated APNs adapter. APNs signing material remains server-side; invalid device tokens are removed automatically.

### PostgreSQL

`exporter_sessions` is the aggregate root. Groups, messages, events, APNs devices and delivery outbox records are scoped to it. `whatsmeow` uses its own tables in the same PostgreSQL cluster for device identity and encryption state.

### v14

v14 remains responsible for users, passwords, token rotation, revocation and future message ingestion. The Exporter verifies identity through v14 instead of decoding or issuing v14 tokens itself.

## Capture lifecycle

1. The iOS app signs in through v14 and receives secure, HTTP-only cookies.
2. It asks the Exporter for a pairing code using an international phone number.
3. The Exporter opens a pre-login WhatsApp client and returns the short-lived code.
4. Once WhatsApp confirms the link, device keys are persisted server-side and groups are discovered.
5. History arriving before group selection is held with `capture_state = pending`.
6. Saving the group selection promotes messages from chosen groups and removes pending records from unchosen groups in one transaction.
7. New messages are accepted only when capture is enabled and their group is selected. Edits and revokes still update an already captured record so stored state does not become stale after a pause or selection change.
8. Each active message gets exactly one delivery-outbox record for the later v14 bridge.
9. An edit or revoke updates the original record and resets that outbox item to `pending` so the future bridge can deliver the new revision.

Pending history is retained for 24 hours by default and then purged if group selection was never completed.

## Consistency and recovery

- `(session_id, group_jid, whatsapp_message_id)` is unique.
- Cursor pagination uses `(timestamp, UUID)` to remain stable when timestamps match.
- Session leases prevent two service replicas from opening the same WhatsApp device identity.
- Device credentials and capture records survive app closure, phone network loss and service restarts.
- iOS refresh tasks update presentation state only; they are not part of the capture guarantee.
- Media type, MIME type, dimensions, duration and file information are retained when enabled. Binary attachments are not downloaded in this phase.

## Security decisions

- Mutation requests require the non-simple `X-Talia-Client` header in addition to v14 authentication.
- The Exporter forwards only `Cookie`, `Authorization`, request ID and fixed internal headers to v14.
- Request bodies and headers are bounded; JSON rejects unknown fields.
- Passwords and tokens never enter Exporter storage or logs.
- APNs provider keys are loaded from a mounted secret and never included in the image or repository.
- API error responses are stable and do not expose internal failures.
