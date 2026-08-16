# Talia Exporter service

The service is the long-running capture component behind the iOS app. The iPhone is a control surface; linked WhatsApp sessions, group discovery, message deduplication and persistence run here.

## Runtime boundaries

- v14 remains the identity authority. Every Exporter request is authenticated by forwarding the existing cookie or bearer credential to v14 `/api/v1/auth/me`.
- The public API should remain on the v14 origin. Route `/api/v1/exporter/*` to this service and all other `/api/v1/*` routes to v14.
- WhatsApp device keys are persisted by `whatsmeow` in PostgreSQL. They never reach the iPhone or API responses.
- Captured records use separate `exporter_*` tables. `exporter_delivery_outbox` is the idempotent boundary for the later v14 ingestion worker.

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
- Back up PostgreSQL, including the WhatsApp device tables and `exporter_*` tables.
- For interruption alerts, mount the Apple `.p8` signing key outside the image and set
  `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_PRIVATE_KEY_PATH`, `APNS_BUNDLE_ID` and
  `APNS_ENVIRONMENT`. Leaving the signing values empty disables APNs cleanly.

Initial WhatsApp history is supplied by the linked phone and can vary by account/device state. Real-time group messages are captured after the linked session is established; all inserts are deduplicated by the original WhatsApp message identifier.
