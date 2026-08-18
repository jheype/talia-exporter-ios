BEGIN;

ALTER TABLE exporter_groups
    ADD COLUMN IF NOT EXISTS history_sync_state TEXT NOT NULL DEFAULT 'idle',
    ADD COLUMN IF NOT EXISTS history_batch_count INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS history_request_count INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS history_sync_started_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS history_sync_updated_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS history_sync_completed_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS history_oldest_message_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS history_sync_last_error TEXT,
    ADD COLUMN IF NOT EXISTS history_anchor_message_id TEXT,
    ADD COLUMN IF NOT EXISTS history_anchor_timestamp TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS history_anchor_from_me BOOLEAN NOT NULL DEFAULT FALSE;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'exporter_groups_history_sync_state_check'
          AND conrelid = 'exporter_groups'::REGCLASS
    ) THEN
        ALTER TABLE exporter_groups
            ADD CONSTRAINT exporter_groups_history_sync_state_check
            CHECK (history_sync_state IN (
                'idle', 'queued', 'waiting_for_anchor', 'requesting', 'receiving',
                'complete', 'stalled', 'failed'
            ));
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'exporter_groups_history_batch_count_check'
          AND conrelid = 'exporter_groups'::REGCLASS
    ) THEN
        ALTER TABLE exporter_groups
            ADD CONSTRAINT exporter_groups_history_batch_count_check
            CHECK (history_batch_count >= 0);
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'exporter_groups_history_request_count_check'
          AND conrelid = 'exporter_groups'::REGCLASS
    ) THEN
        ALTER TABLE exporter_groups
            ADD CONSTRAINT exporter_groups_history_request_count_check
            CHECK (history_request_count >= 0);
    END IF;
END;
$$;

ALTER TABLE exporter_messages
    ADD COLUMN IF NOT EXISTS v14_ingestion_status TEXT NOT NULL DEFAULT 'available',
    ADD COLUMN IF NOT EXISTS v14_upload_session_id UUID,
    ADD COLUMN IF NOT EXISTS v14_ingestion_queued_at TIMESTAMPTZ;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'exporter_messages_v14_ingestion_status_check'
          AND conrelid = 'exporter_messages'::REGCLASS
    ) THEN
        ALTER TABLE exporter_messages
            ADD CONSTRAINT exporter_messages_v14_ingestion_status_check
            CHECK (v14_ingestion_status IN ('available', 'queued'));
    END IF;
END;
$$;

-- The Exporter is deliberately text-only. Existing media rows remain for
-- auditability, but new sessions and upgraded sessions no longer request or
-- retain media metadata.
UPDATE exporter_sessions
SET include_media = FALSE
WHERE include_media;

-- Ingestion is now an explicit human action on the Exporter Chats page. Clear
-- legacy undelivered intents so neither a future outbox worker nor a stale
-- processing lease can bypass that confirmation gate. Delivered rows remain as
-- audit history; this binary no longer creates or resets outbox rows.
DELETE FROM exporter_delivery_outbox
WHERE status IN ('pending', 'processing', 'failed');

-- Seed a resumable cursor for groups that already captured a partial bootstrap
-- history before this migration. The cursor itself contains no message body or
-- media data; it is only the WhatsApp protocol anchor required for the next
-- on-demand batch.
WITH oldest AS (
    SELECT DISTINCT ON (messages.session_id, messages.group_jid)
           messages.session_id,
           messages.group_jid,
           messages.whatsapp_message_id,
           messages.message_timestamp,
           messages.is_from_me
    FROM exporter_messages AS messages
    ORDER BY messages.session_id,
             messages.group_jid,
             messages.message_timestamp ASC,
             messages.whatsapp_message_id ASC
)
UPDATE exporter_groups AS groups
SET history_anchor_message_id = oldest.whatsapp_message_id,
    history_anchor_timestamp = oldest.message_timestamp,
    history_anchor_from_me = oldest.is_from_me,
    history_oldest_message_at = oldest.message_timestamp,
    history_sync_state = CASE
        WHEN groups.is_selected THEN 'queued'
        ELSE groups.history_sync_state
    END,
    history_sync_updated_at = CASE
        WHEN groups.is_selected THEN NOW()
        ELSE groups.history_sync_updated_at
    END
FROM oldest
WHERE groups.session_id = oldest.session_id
  AND groups.jid = oldest.group_jid
  AND groups.history_anchor_message_id IS NULL;

UPDATE exporter_groups
SET history_sync_state = 'queued',
    history_sync_updated_at = NOW()
WHERE is_selected
  AND history_sync_state = 'idle';

CREATE INDEX IF NOT EXISTS exporter_groups_history_sync_idx
    ON exporter_groups (session_id, history_sync_state, history_sync_updated_at)
    WHERE is_selected;

CREATE INDEX IF NOT EXISTS exporter_messages_v14_ingestion_idx
    ON exporter_messages (session_id, v14_ingestion_status, message_timestamp DESC)
    WHERE capture_state = 'active'
      AND message_type = 'text'
      AND NOT is_revoked;

COMMIT;
