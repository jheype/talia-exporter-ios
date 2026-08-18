# Manual v14 integration

Captured WhatsApp text is staging data. It must never enter the watch-ingestion pipeline merely because capture succeeded.

## Operator flow

1. Open **Exporter Chats** in the authenticated v14 workspace.
2. Inspect per-group history state, batch count, oldest captured timestamp and any stall reason.
3. Filter and select only the messages that should be ingested.
4. Press **Review ingestion**.
5. Verify the selected message/group/date summary and source market.
6. Press **Confirm and ingest into v14**.

The final button is the only ingestion trigger. It creates text-only, WhatsApp-format files grouped by chat and posts them to the canonical `POST /api/v2/upload/` endpoint. From there, S3 storage, queueing, parsing, extraction, duplicate protection, Upload History and human review are the same as for a normal file upload.

After v14 accepts the upload, the page records the returned upload-session UUID against the selected `exporter_messages` rows. This provenance marker prevents those rows from being offered again. A later WhatsApp edit resets the changed message to `available`, requiring another deliberate review.

## Safety boundaries

- The WhatsApp event handler writes only to Exporter tables.
- It does not write to v14 `raw_messages`, call `/api/v2/upload/` or enqueue a delivery outbox row.
- Images, image captions and media metadata are discarded before persistence.
- Only authenticated users can read their Exporter session. Mutations also require `X-Talia-Client: v14-web` (or `ios` from the native app).
- v14's byte-identical upload guard remains authoritative and rejects accidental duplicate uploads.
- If v14 accepts an upload but the provenance acknowledgement fails, the UI reports the accepted session ID and tells the operator not to upload again; acknowledgement is retried three times first.
