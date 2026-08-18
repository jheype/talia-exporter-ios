BEGIN;

CREATE TABLE IF NOT EXISTS exporter_sessions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL,
    phone_number TEXT,
    whatsapp_device_jid TEXT UNIQUE,
    status TEXT NOT NULL DEFAULT 'unlinked' CHECK (status IN (
        'unlinked', 'pairing', 'connecting', 'connected', 'reconnecting',
        'paused', 'interrupted', 'logged_out'
    )),
    capture_enabled BOOLEAN NOT NULL DEFAULT FALSE,
    include_media BOOLEAN NOT NULL DEFAULT FALSE,
    selection_finalised_at TIMESTAMPTZ,
    linked_at TIMESTAMPTZ,
    last_connected_at TIMESTAMPTZ,
    last_message_at TIMESTAMPTZ,
    last_synchronised_at TIMESTAMPTZ,
    last_error_code TEXT,
    last_error_message TEXT,
    last_interruption_notified_at TIMESTAMPTZ,
    worker_id TEXT,
    lease_expires_at TIMESTAMPTZ,
    archived_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE exporter_sessions
    ADD COLUMN IF NOT EXISTS last_interruption_notified_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS exporter_sessions_reconcile_idx
    ON exporter_sessions (status, lease_expires_at)
    WHERE whatsapp_device_jid IS NOT NULL AND archived_at IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS exporter_sessions_one_active_user_idx
    ON exporter_sessions (user_id)
    WHERE archived_at IS NULL;

CREATE TABLE IF NOT EXISTS exporter_groups (
    session_id UUID NOT NULL REFERENCES exporter_sessions(id) ON DELETE CASCADE,
    jid TEXT NOT NULL,
    name TEXT NOT NULL,
    participant_count INTEGER NOT NULL DEFAULT 0 CHECK (participant_count >= 0),
    is_selected BOOLEAN NOT NULL DEFAULT FALSE,
    is_available BOOLEAN NOT NULL DEFAULT TRUE,
    last_message_at TIMESTAMPTZ,
    history_sync_state TEXT NOT NULL DEFAULT 'idle' CHECK (history_sync_state IN (
        'idle', 'queued', 'waiting_for_anchor', 'requesting', 'receiving',
        'complete', 'stalled', 'failed'
    )),
    history_batch_count INTEGER NOT NULL DEFAULT 0 CHECK (history_batch_count >= 0),
    history_request_count INTEGER NOT NULL DEFAULT 0 CHECK (history_request_count >= 0),
    history_sync_started_at TIMESTAMPTZ,
    history_sync_updated_at TIMESTAMPTZ,
    history_sync_completed_at TIMESTAMPTZ,
    history_oldest_message_at TIMESTAMPTZ,
    history_sync_last_error TEXT,
    history_anchor_message_id TEXT,
    history_anchor_timestamp TIMESTAMPTZ,
    history_anchor_from_me BOOLEAN NOT NULL DEFAULT FALSE,
    discovered_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (session_id, jid)
);

CREATE INDEX IF NOT EXISTS exporter_groups_selected_idx
    ON exporter_groups (session_id, is_selected, name);

CREATE TABLE IF NOT EXISTS exporter_messages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id UUID NOT NULL REFERENCES exporter_sessions(id) ON DELETE CASCADE,
    group_jid TEXT NOT NULL,
    whatsapp_message_id TEXT NOT NULL,
    sender_jid TEXT NOT NULL,
    sender_name TEXT NOT NULL DEFAULT '',
    body TEXT NOT NULL DEFAULT '',
    message_type TEXT NOT NULL DEFAULT 'unknown' CHECK (message_type IN (
        'text', 'image', 'video', 'audio', 'document', 'sticker', 'contact',
        'location', 'poll', 'reaction', 'system', 'unknown'
    )),
    message_timestamp TIMESTAMPTZ NOT NULL,
    is_from_me BOOLEAN NOT NULL DEFAULT FALSE,
    has_media BOOLEAN NOT NULL DEFAULT FALSE,
    is_edited BOOLEAN NOT NULL DEFAULT FALSE,
    is_revoked BOOLEAN NOT NULL DEFAULT FALSE,
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision > 0),
    capture_state TEXT NOT NULL CHECK (capture_state IN ('pending', 'active')),
    media_metadata JSONB NOT NULL DEFAULT '{}'::JSONB,
    raw_metadata JSONB NOT NULL DEFAULT '{}'::JSONB,
    v14_ingestion_status TEXT NOT NULL DEFAULT 'available' CHECK (
        v14_ingestion_status IN ('available', 'queued')
    ),
    v14_upload_session_id UUID,
    v14_ingestion_queued_at TIMESTAMPTZ,
    received_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (session_id, group_jid, whatsapp_message_id)
);

CREATE INDEX IF NOT EXISTS exporter_messages_feed_idx
    ON exporter_messages (session_id, message_timestamp DESC, id DESC)
    WHERE capture_state = 'active';

CREATE INDEX IF NOT EXISTS exporter_messages_group_idx
    ON exporter_messages (session_id, group_jid, message_timestamp DESC)
    WHERE capture_state = 'active';

CREATE INDEX IF NOT EXISTS exporter_messages_pending_idx
    ON exporter_messages (session_id, received_at)
    WHERE capture_state = 'pending';

CREATE TABLE IF NOT EXISTS exporter_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id UUID NOT NULL REFERENCES exporter_sessions(id) ON DELETE CASCADE,
    kind TEXT NOT NULL CHECK (kind IN ('Captured', 'Synchronised', 'Needs attention')),
    group_jid TEXT,
    group_name TEXT NOT NULL DEFAULT 'Talia Exporter',
    detail TEXT NOT NULL,
    metadata JSONB NOT NULL DEFAULT '{}'::JSONB,
    event_bucket TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS exporter_events_feed_idx
    ON exporter_events (session_id, created_at DESC, id DESC);

CREATE UNIQUE INDEX IF NOT EXISTS exporter_events_capture_bucket_idx
    ON exporter_events (session_id, group_jid, kind, event_bucket)
    WHERE kind = 'Captured';

CREATE TABLE IF NOT EXISTS exporter_devices (
    user_id UUID NOT NULL,
    platform TEXT NOT NULL CHECK (platform = 'ios'),
    token TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, platform, token)
);

-- APNs tokens identify an app installation, not a Talia account. If the same
-- installation signs in as another employee, ownership moves to that account.
DELETE FROM exporter_devices older
USING exporter_devices newer
WHERE older.platform = newer.platform
  AND older.token = newer.token
  AND older.user_id <> newer.user_id
  AND (
      older.updated_at < newer.updated_at
      OR (older.updated_at = newer.updated_at AND older.user_id::TEXT < newer.user_id::TEXT)
  );

CREATE UNIQUE INDEX IF NOT EXISTS exporter_devices_platform_token_idx
    ON exporter_devices (platform, token);

CREATE TABLE IF NOT EXISTS exporter_delivery_outbox (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    message_id UUID NOT NULL UNIQUE REFERENCES exporter_messages(id) ON DELETE CASCADE,
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision > 0),
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'processing', 'delivered', 'failed')),
    attempt_count INTEGER NOT NULL DEFAULT 0,
    next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    locked_at TIMESTAMPTZ,
    locked_by TEXT,
    delivered_at TIMESTAMPTZ,
    last_error TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE exporter_messages
    ADD COLUMN IF NOT EXISTS revision INTEGER NOT NULL DEFAULT 1;

ALTER TABLE exporter_delivery_outbox
    ADD COLUMN IF NOT EXISTS revision INTEGER NOT NULL DEFAULT 1;

CREATE INDEX IF NOT EXISTS exporter_delivery_outbox_pending_idx
    ON exporter_delivery_outbox (next_attempt_at, created_at)
    WHERE status IN ('pending', 'failed');

CREATE OR REPLACE FUNCTION exporter_touch_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS exporter_sessions_touch_updated_at ON exporter_sessions;
CREATE TRIGGER exporter_sessions_touch_updated_at
BEFORE UPDATE ON exporter_sessions
FOR EACH ROW EXECUTE FUNCTION exporter_touch_updated_at();

DROP TRIGGER IF EXISTS exporter_groups_touch_updated_at ON exporter_groups;
CREATE TRIGGER exporter_groups_touch_updated_at
BEFORE UPDATE ON exporter_groups
FOR EACH ROW EXECUTE FUNCTION exporter_touch_updated_at();

DROP TRIGGER IF EXISTS exporter_messages_touch_updated_at ON exporter_messages;
CREATE TRIGGER exporter_messages_touch_updated_at
BEFORE UPDATE ON exporter_messages
FOR EACH ROW EXECUTE FUNCTION exporter_touch_updated_at();

DROP TRIGGER IF EXISTS exporter_devices_touch_updated_at ON exporter_devices;
CREATE TRIGGER exporter_devices_touch_updated_at
BEFORE UPDATE ON exporter_devices
FOR EACH ROW EXECUTE FUNCTION exporter_touch_updated_at();

DROP TRIGGER IF EXISTS exporter_delivery_outbox_touch_updated_at ON exporter_delivery_outbox;
CREATE TRIGGER exporter_delivery_outbox_touch_updated_at
BEFORE UPDATE ON exporter_delivery_outbox
FOR EACH ROW EXECUTE FUNCTION exporter_touch_updated_at();

COMMIT;
