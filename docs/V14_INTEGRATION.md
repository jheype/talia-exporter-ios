# Future v14 integration

The current implementation intentionally stops at the delivery outbox. This preserves the captured WhatsApp event before v14 parsing and lets the later integration retry without duplicating records.

## Recommended bridge

1. Claim pending rows and their `revision` from `exporter_delivery_outbox` with `FOR UPDATE SKIP LOCKED`.
2. Read the associated active `exporter_messages` row.
3. Convert it to a versioned v14 ingestion command.
4. Use a deterministic idempotency key such as `whatsapp:<session_id>:<group_jid>:<whatsapp_message_id>`.
5. Upsert by that key so later edits and revokes replace the same v14 record.
6. Commit the v14 record before marking the outbox row `delivered`; the final update must match the claimed `revision`.
7. On a transient failure, increase `attempt_count` and schedule `next_attempt_at` with capped exponential backoff.

Do not have the WhatsApp event handler write directly to v14 `raw_messages`. That would couple connection health to parser availability, remove the replay boundary and make duplicate prevention harder.

The future v14 page should read the Exporter message/event endpoints or a purpose-built read model. It should not query WhatsApp device-key tables.
