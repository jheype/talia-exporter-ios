package store

import (
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/talia/exporter/internal/domain"
)

func (postgres *Postgres) InsertMessage(ctx context.Context, incoming domain.IncomingMessage) (bool, error) {
	if !incoming.IsRevoke && (incoming.Type != domain.MessageText || strings.TrimSpace(incoming.Body) == "") {
		return false, nil
	}
	incoming.HasMedia = false
	incoming.MediaMetadata = domain.MediaMetadata{}

	rawMetadata, err := json.Marshal(incoming.RawMetadata)
	if err != nil {
		return false, fmt.Errorf("marshal message metadata: %w", err)
	}
	mediaMetadata, err := json.Marshal(incoming.MediaMetadata)
	if err != nil {
		return false, fmt.Errorf("marshal media metadata: %w", err)
	}

	transaction, err := postgres.pool.Begin(ctx)
	if err != nil {
		return false, err
	}
	defer func() { _ = transaction.Rollback(ctx) }()

	_, err = transaction.Exec(ctx, `
		INSERT INTO exporter_groups (session_id, jid, name, participant_count)
		VALUES ($1, $2, $2, 0)
		ON CONFLICT (session_id, jid) DO NOTHING`, incoming.SessionID, incoming.GroupJID)
	if err != nil {
		return false, err
	}

	var selectionFinalised sql.NullTime
	var captureEnabled bool
	var selected bool
	err = transaction.QueryRow(ctx, `
		SELECT s.selection_finalised_at, s.capture_enabled, g.is_selected
		FROM exporter_sessions s
		JOIN exporter_groups g ON g.session_id = s.id AND g.jid = $2
		WHERE s.id = $1
		FOR UPDATE OF s`, incoming.SessionID, incoming.GroupJID).Scan(
		&selectionFinalised,
		&captureEnabled,
		&selected,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, domain.ErrNotFound
	}
	if err != nil {
		return false, err
	}
	if selectionFinalised.Valid && (!selected || !captureEnabled) {
		if incoming.IsEdit || incoming.IsRevoke {
			if _, err := applyMessageMutation(
				ctx,
				transaction,
				incoming,
				mediaMetadata,
				rawMetadata,
			); err != nil {
				return false, err
			}
		}
		return false, transaction.Commit(ctx)
	}

	captureState := "pending"
	if selectionFinalised.Valid && selected {
		captureState = "active"
	}

	messageID := uuid.New()
	err = transaction.QueryRow(ctx, `
		INSERT INTO exporter_messages (
			id, session_id, group_jid, whatsapp_message_id, sender_jid, sender_name,
			body, message_type, message_timestamp, is_from_me, has_media, is_edited,
			is_revoked, capture_state, media_metadata, raw_metadata
		) VALUES (
			$1, $2, $3, $4, $5, $6, $7, $8,
			$9, $10, $11, $12, $13, $14, $15, $16
		)
		ON CONFLICT (session_id, group_jid, whatsapp_message_id) DO NOTHING
		RETURNING id`,
		messageID,
		incoming.SessionID,
		incoming.GroupJID,
		incoming.WhatsAppMessageID,
		incoming.SenderJID,
		incoming.SenderName,
		incoming.Body,
		incoming.Type,
		incoming.Timestamp,
		incoming.IsFromMe,
		incoming.HasMedia,
		incoming.IsEdit,
		incoming.IsRevoke,
		captureState,
		mediaMetadata,
		rawMetadata,
	).Scan(&messageID)
	if errors.Is(err, pgx.ErrNoRows) {
		if incoming.IsEdit || incoming.IsRevoke {
			if _, err := applyMessageMutation(
				ctx,
				transaction,
				incoming,
				mediaMetadata,
				rawMetadata,
			); err != nil {
				return false, err
			}
		}
		return false, transaction.Commit(ctx)
	}
	if err != nil {
		return false, err
	}

	_, err = transaction.Exec(ctx, `
		UPDATE exporter_groups
		SET last_message_at = GREATEST(COALESCE(last_message_at, $3), $3)
		WHERE session_id = $1 AND jid = $2`, incoming.SessionID, incoming.GroupJID, incoming.Timestamp)
	if err != nil {
		return false, err
	}
	_, err = transaction.Exec(ctx, `
		UPDATE exporter_sessions
		SET last_message_at = GREATEST(COALESCE(last_message_at, $2), $2),
			last_synchronised_at = NOW()
		WHERE id = $1`, incoming.SessionID, incoming.Timestamp)
	if err != nil {
		return false, err
	}

	if captureState == "active" {
		_, err = transaction.Exec(ctx, `
			INSERT INTO exporter_events (
				session_id, kind, group_jid, group_name, detail, metadata, event_bucket
			)
			SELECT $1, 'Captured', g.jid, g.name, '1 message captured',
				jsonb_build_object('message_count', 1), date_trunc('minute', NOW())
			FROM exporter_groups g
			WHERE g.session_id = $1 AND g.jid = $2
			ON CONFLICT (session_id, group_jid, kind, event_bucket)
			WHERE kind = 'Captured'
			DO UPDATE SET
				metadata = jsonb_build_object(
					'message_count', COALESCE((exporter_events.metadata->>'message_count')::INTEGER, 0) + 1
				),
				detail = (COALESCE((exporter_events.metadata->>'message_count')::INTEGER, 0) + 1)::TEXT
					|| ' messages captured'`, incoming.SessionID, incoming.GroupJID)
		if err != nil {
			return false, err
		}
	}

	if err := transaction.Commit(ctx); err != nil {
		return false, err
	}
	return captureState == "active", nil
}

func applyMessageMutation(
	ctx context.Context,
	transaction pgx.Tx,
	incoming domain.IncomingMessage,
	mediaMetadata []byte,
	rawMetadata []byte,
) (bool, error) {
	var messageID uuid.UUID
	err := transaction.QueryRow(ctx, `
		UPDATE exporter_messages
		SET body = CASE WHEN is_revoked OR $7 THEN '' ELSE $4 END,
			message_type = CASE WHEN is_revoked OR $7 THEN 'system' ELSE $5 END,
			is_edited = is_edited OR $6,
			is_revoked = is_revoked OR $7,
			revision = revision + 1,
			has_media = CASE WHEN is_revoked OR $7 THEN FALSE ELSE $8 END,
			media_metadata = CASE WHEN is_revoked OR $7 THEN '{}'::JSONB ELSE $9 END,
			raw_metadata = $10,
			v14_ingestion_status = 'available',
			v14_upload_session_id = NULL,
			v14_ingestion_queued_at = NULL
		WHERE session_id = $1
		  AND group_jid = $2
		  AND whatsapp_message_id = $3
		  AND (
			($7 AND NOT is_revoked)
			OR (
				$6 AND NOT is_revoked AND (
					NOT is_edited
					OR body IS DISTINCT FROM $4
					OR message_type IS DISTINCT FROM $5
					OR has_media IS DISTINCT FROM $8
					OR media_metadata IS DISTINCT FROM $9
				)
			)
		  )
		RETURNING id`,
		incoming.SessionID,
		incoming.GroupJID,
		incoming.WhatsAppMessageID,
		incoming.Body,
		incoming.Type,
		incoming.IsEdit,
		incoming.IsRevoke,
		incoming.HasMedia,
		mediaMetadata,
		rawMetadata,
	).Scan(&messageID)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return true, nil
}

func (postgres *Postgres) PurgeExpiredPendingMessages(ctx context.Context, retention time.Duration) error {
	_, err := postgres.pool.Exec(ctx, `
		DELETE FROM exporter_messages m
		USING exporter_sessions s
		WHERE m.session_id = s.id
		  AND m.capture_state = 'pending'
		  AND s.selection_finalised_at IS NULL
		  AND COALESCE(s.linked_at, s.created_at) < NOW() - $1::INTERVAL`, interval(retention))
	return err
}

func (postgres *Postgres) Messages(
	ctx context.Context,
	sessionID uuid.UUID,
	limit int,
	cursor *string,
) (domain.CursorPage[domain.CapturedMessage], error) {
	limit = boundedLimit(limit)
	cursorTime, cursorID, err := decodeCursor(cursor)
	if err != nil {
		return domain.CursorPage[domain.CapturedMessage]{}, domain.ErrInvalidInput
	}
	rows, err := postgres.pool.Query(ctx, `
		SELECT m.id, m.whatsapp_message_id, m.group_jid, g.name, m.sender_jid,
			m.sender_name, m.body, m.message_type, m.message_timestamp,
			m.is_from_me, m.has_media, m.is_edited, m.is_revoked, m.revision, m.media_metadata,
			m.v14_ingestion_status, m.v14_upload_session_id, m.v14_ingestion_queued_at
		FROM exporter_messages m
		JOIN exporter_groups g ON g.session_id = m.session_id AND g.jid = m.group_jid
		WHERE m.session_id = $1
		  AND m.capture_state = 'active'
		  AND m.message_type = 'text'
		  AND NOT m.is_revoked
		  AND BTRIM(m.body) <> ''
		  AND ($2::TIMESTAMPTZ IS NULL OR (m.message_timestamp, m.id) < ($2, $3))
		ORDER BY m.message_timestamp DESC, m.id DESC
		LIMIT $4`, sessionID, cursorTime, cursorID, limit+1)
	if err != nil {
		return domain.CursorPage[domain.CapturedMessage]{}, err
	}
	defer rows.Close()

	items := make([]domain.CapturedMessage, 0, limit+1)
	for rows.Next() {
		var message domain.CapturedMessage
		var encodedMediaMetadata []byte
		var uploadSessionID uuid.NullUUID
		var ingestionQueuedAt sql.NullTime
		if err := rows.Scan(
			&message.ID,
			&message.WhatsAppMessageID,
			&message.GroupJID,
			&message.GroupName,
			&message.SenderJID,
			&message.Sender,
			&message.Body,
			&message.Type,
			&message.Timestamp,
			&message.IsFromMe,
			&message.HasMedia,
			&message.IsEdited,
			&message.IsRevoked,
			&message.Revision,
			&encodedMediaMetadata,
			&message.IngestionStatus,
			&uploadSessionID,
			&ingestionQueuedAt,
		); err != nil {
			return domain.CursorPage[domain.CapturedMessage]{}, err
		}
		var mediaMetadata domain.MediaMetadata
		if err := json.Unmarshal(encodedMediaMetadata, &mediaMetadata); err != nil {
			return domain.CursorPage[domain.CapturedMessage]{}, fmt.Errorf("decode media metadata: %w", err)
		}
		if !mediaMetadata.IsEmpty() {
			message.MediaMetadata = &mediaMetadata
		}
		if uploadSessionID.Valid {
			message.UploadSessionID = &uploadSessionID.UUID
		}
		message.IngestionQueuedAt = nullableTime(ingestionQueuedAt)
		items = append(items, message)
	}
	if err := rows.Err(); err != nil {
		return domain.CursorPage[domain.CapturedMessage]{}, err
	}

	var next *string
	if len(items) > limit {
		items = items[:limit]
		value := encodeCursor(items[len(items)-1].Timestamp, items[len(items)-1].ID)
		next = &value
	}
	return domain.CursorPage[domain.CapturedMessage]{Items: items, NextCursor: next}, nil
}

func (postgres *Postgres) MarkMessagesQueuedForIngestion(
	ctx context.Context,
	userID uuid.UUID,
	messageIDs []uuid.UUID,
	uploadSessionID uuid.UUID,
) error {
	messageIDs = uniqueUUIDs(messageIDs)
	if len(messageIDs) == 0 || uploadSessionID == uuid.Nil {
		return domain.ErrInvalidInput
	}

	transaction, err := postgres.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = transaction.Rollback(ctx) }()

	command, err := transaction.Exec(ctx, `
		UPDATE exporter_messages AS messages
		SET v14_ingestion_status = 'queued',
			v14_upload_session_id = $3,
			v14_ingestion_queued_at = NOW()
		FROM exporter_sessions AS sessions
		WHERE messages.session_id = sessions.id
		  AND sessions.user_id = $1
		  AND sessions.archived_at IS NULL
		  AND messages.id = ANY($2::UUID[])
		  AND messages.capture_state = 'active'
		  AND messages.message_type = 'text'
		  AND NOT messages.is_revoked
		  AND BTRIM(messages.body) <> ''
		  AND (
			messages.v14_ingestion_status = 'available'
			OR (
				messages.v14_ingestion_status = 'queued'
				AND messages.v14_upload_session_id = $3
			)
		  )`, userID, messageIDs, uploadSessionID)
	if err != nil {
		return err
	}
	if command.RowsAffected() != int64(len(messageIDs)) {
		return fmt.Errorf("%w: one or more messages are unavailable", domain.ErrInvalidInput)
	}
	return transaction.Commit(ctx)
}

func uniqueUUIDs(values []uuid.UUID) []uuid.UUID {
	seen := make(map[uuid.UUID]struct{}, len(values))
	result := make([]uuid.UUID, 0, len(values))
	for _, value := range values {
		if value == uuid.Nil {
			continue
		}
		if _, exists := seen[value]; exists {
			continue
		}
		seen[value] = struct{}{}
		result = append(result, value)
	}
	return result
}

func (postgres *Postgres) Events(
	ctx context.Context,
	sessionID uuid.UUID,
	limit int,
	cursor *string,
) (domain.CursorPage[domain.CaptureEvent], error) {
	limit = boundedLimit(limit)
	cursorTime, cursorID, err := decodeCursor(cursor)
	if err != nil {
		return domain.CursorPage[domain.CaptureEvent]{}, domain.ErrInvalidInput
	}
	rows, err := postgres.pool.Query(ctx, `
		SELECT id, group_name, detail, created_at, kind
		FROM exporter_events
		WHERE session_id = $1
		  AND ($2::TIMESTAMPTZ IS NULL OR (created_at, id) < ($2, $3))
		ORDER BY created_at DESC, id DESC
		LIMIT $4`, sessionID, cursorTime, cursorID, limit+1)
	if err != nil {
		return domain.CursorPage[domain.CaptureEvent]{}, err
	}
	defer rows.Close()

	items := make([]domain.CaptureEvent, 0, limit+1)
	for rows.Next() {
		var event domain.CaptureEvent
		if err := rows.Scan(&event.ID, &event.GroupName, &event.Detail, &event.CreatedAt, &event.Kind); err != nil {
			return domain.CursorPage[domain.CaptureEvent]{}, err
		}
		items = append(items, event)
	}
	if err := rows.Err(); err != nil {
		return domain.CursorPage[domain.CaptureEvent]{}, err
	}

	var next *string
	if len(items) > limit {
		items = items[:limit]
		value := encodeCursor(items[len(items)-1].CreatedAt, items[len(items)-1].ID)
		next = &value
	}
	return domain.CursorPage[domain.CaptureEvent]{Items: items, NextCursor: next}, nil
}

func (postgres *Postgres) Dashboard(ctx context.Context, userID uuid.UUID) (domain.Dashboard, error) {
	session, err := postgres.SessionByUser(ctx, userID)
	if err != nil {
		return domain.Dashboard{}, err
	}
	groups, err := postgres.Groups(ctx, session.ID)
	if err != nil {
		return domain.Dashboard{}, err
	}
	events, err := postgres.Events(ctx, session.ID, 20, nil)
	if err != nil {
		return domain.Dashboard{}, err
	}
	messages, err := postgres.Messages(ctx, session.ID, 30, nil)
	if err != nil {
		return domain.Dashboard{}, err
	}
	return domain.Dashboard{
		Session:  session,
		Groups:   groups,
		Events:   events.Items,
		Messages: messages.Items,
	}, nil
}

func boundedLimit(limit int) int {
	if limit < 1 {
		return 50
	}
	if limit > 200 {
		return 200
	}
	return limit
}

func encodeCursor(timestamp time.Time, id uuid.UUID) string {
	value := timestamp.UTC().Format(time.RFC3339Nano) + "|" + id.String()
	return base64.RawURLEncoding.EncodeToString([]byte(value))
}

func decodeCursor(cursor *string) (*time.Time, uuid.UUID, error) {
	if cursor == nil || strings.TrimSpace(*cursor) == "" {
		return nil, uuid.Nil, nil
	}
	decoded, err := base64.RawURLEncoding.DecodeString(*cursor)
	if err != nil {
		return nil, uuid.Nil, err
	}
	parts := strings.SplitN(string(decoded), "|", 2)
	if len(parts) != 2 {
		return nil, uuid.Nil, domain.ErrInvalidInput
	}
	timestamp, err := time.Parse(time.RFC3339Nano, parts[0])
	if err != nil {
		return nil, uuid.Nil, err
	}
	id, err := uuid.Parse(parts[1])
	if err != nil {
		return nil, uuid.Nil, err
	}
	return &timestamp, id, nil
}
