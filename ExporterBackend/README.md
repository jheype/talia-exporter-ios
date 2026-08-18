# Talia Exporter service

The service is the long-running capture component behind the iOS app. The iPhone is a control surface; linked WhatsApp sessions, group discovery, message deduplication and persistence run here.

## Runtime boundaries

- v14 remains the identity authority. Every Exporter request is authenticated by forwarding the existing cookie or bearer credential to v14 `/api/v1/auth/me`.
- The public API should remain on the v14 origin. Route `/api/v1/exporter/*` to this service and all other `/api/v1/*` routes to v14.
- WhatsApp device keys are persisted by `whatsmeow` in PostgreSQL. They never reach the iPhone or API responses.
- Captured records use separate `exporter_*` tables and remain staging data until a person confirms ingestion on the v14 **Exporter Chats** page.
- Capture never writes directly to v14 and never creates an automatic delivery intent. The confirmation action turns selected text into ordinary WhatsApp export files and submits those files through v14's existing upload endpoint.

## Local start

Requirements: Go 1.25+, PostgreSQL 15+ and a running v14 API.

```sh
cp .env.example .env
set -a
. ./.env
set +a
go run ./cmd/exporter-api
```

The application applies its idempotent schema migration while holding a PostgreSQL advisory lock. `whatsmeow` applies its own SQL-store migrations through the same database.

Health endpoints:

- `GET /health/live`
- `GET /health/ready`

## Verification

```sh
make check
```

The API contract is in `contracts/exporter-api.yaml`.

## Deployment requirements

- Provide `DATABASE_URL` and internal `V14_AUTH_ME_URL` as secrets/configuration.
- Keep `V14_AUTH_ME_URL` on the private service network.
- Route TLS at the load balancer and do not expose the service directly.
- Start with one replica. Database leases already protect a session from concurrent ownership when replicas are added.
- Configure `ALLOWED_CLIENT=ios,v14-web`; the web value permits only authenticated v14 mutation requests that also carry the required client header.
- Back up PostgreSQL, including the WhatsApp device tables and `exporter_*` tables.
- For interruption alerts, mount the Apple `.p8` signing key outside the image and set
  `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_PRIVATE_KEY_PATH`, `APNS_BUNDLE_ID` and
  `APNS_ENVIRONMENT`. Leaving the signing values empty disables APNs cleanly.

The service repeatedly requests older batches until WhatsApp explicitly reports no more available history. It does not treat a batch smaller than the requested 50 messages as completion. Initial history is supplied by the linked primary phone and can still vary by account/device state; a group without any available anchor remains visibly in `waiting_for_anchor` until a recent message establishes one. If WhatsApp says older messages remain but does not grant access, the group becomes visibly `stalled` and retryable rather than falsely complete. Real-time group text is captured continuously after linking, and every insert is deduplicated by the original WhatsApp message identifier. Images, image captions and media metadata are not retained.
