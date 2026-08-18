package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/talia/exporter/internal/domain"
)

func (postgres *Postgres) UpsertGroups(ctx context.Context, sessionID uuid.UUID, groups []domain.Group) error {
	transaction, err := postgres.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = transaction.Rollback(ctx) }()
	if _, err := transaction.Exec(ctx, `
		UPDATE exporter_groups
		SET is_available = FALSE
		WHERE session_id = $1`, sessionID); err != nil {
		return err
	}

	for _, group := range groups {
		_, err = transaction.Exec(ctx, `
			INSERT INTO exporter_groups (session_id, jid, name, participant_count, is_available)
			VALUES ($1, $2, $3, $4, TRUE)
			ON CONFLICT (session_id, jid) DO UPDATE SET
				name = EXCLUDED.name,
				participant_count = EXCLUDED.participant_count,
				is_available = TRUE`,
			sessionID, group.JID, group.Name, group.ParticipantCount)
		if err != nil {
			return err
		}
	}
	if _, err := transaction.Exec(ctx, `
		UPDATE exporter_groups
		SET is_selected = FALSE
		WHERE session_id = $1 AND NOT is_available`, sessionID); err != nil {
		return err
	}
	return transaction.Commit(ctx)
}

func (postgres *Postgres) Groups(ctx context.Context, sessionID uuid.UUID) ([]domain.Group, error) {
	rows, err := postgres.pool.Query(ctx, `
		SELECT g.jid, g.name, g.participant_count, g.is_selected, g.last_message_at,
			g.history_sync_state,
			COALESCE(message_counts.text_message_count, 0),
			g.history_batch_count,
			g.history_request_count,
			g.history_sync_started_at,
			g.history_sync_updated_at,
			g.history_sync_completed_at,
			g.history_oldest_message_at,
			g.history_sync_last_error
		FROM exporter_groups g
		LEFT JOIN LATERAL (
			SELECT COUNT(*)::BIGINT AS text_message_count
			FROM exporter_messages m
			WHERE m.session_id = g.session_id
			  AND m.group_jid = g.jid
			  AND m.capture_state = 'active'
			  AND m.message_type = 'text'
			  AND NOT m.is_revoked
			  AND BTRIM(m.body) <> ''
		) message_counts ON TRUE
		WHERE g.session_id = $1 AND g.is_available
		ORDER BY g.is_selected DESC, LOWER(g.name), g.jid`, sessionID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	groups := make([]domain.Group, 0)
	for rows.Next() {
		var group domain.Group
		var lastMessage sql.NullTime
		var startedAt sql.NullTime
		var updatedAt sql.NullTime
		var completedAt sql.NullTime
		var oldestMessageAt sql.NullTime
		var lastError sql.NullString
		if err := rows.Scan(
			&group.JID,
			&group.Name,
			&group.ParticipantCount,
			&group.IsSelected,
			&lastMessage,
			&group.HistorySyncState,
			&group.HistoryTextMessageCount,
			&group.HistoryBatchCount,
			&group.HistoryRequestCount,
			&startedAt,
			&updatedAt,
			&completedAt,
			&oldestMessageAt,
			&lastError,
		); err != nil {
			return nil, err
		}
		group.LastMessageAt = nullableTime(lastMessage)
		group.HistorySyncStartedAt = nullableTime(startedAt)
		group.HistorySyncUpdatedAt = nullableTime(updatedAt)
		group.HistorySyncCompletedAt = nullableTime(completedAt)
		group.HistoryOldestMessageAt = nullableTime(oldestMessageAt)
		if lastError.Valid {
			group.HistorySyncLastError = &lastError.String
		}
		groups = append(groups, group)
	}
	return groups, rows.Err()
}

func (postgres *Postgres) SaveSelection(
	ctx context.Context,
	userID uuid.UUID,
	groupJIDs []string,
) (domain.Session, error) {
	groupJIDs = uniqueStrings(groupJIDs)
	transaction, err := postgres.pool.Begin(ctx)
	if err != nil {
		return domain.Session{}, err
	}
	defer func() { _ = transaction.Rollback(ctx) }()

	var sessionID uuid.UUID
	var linkedAt sql.NullTime
	err = transaction.QueryRow(ctx, `
		SELECT id, linked_at FROM exporter_sessions WHERE user_id = $1 AND archived_at IS NULL FOR UPDATE`, userID).Scan(&sessionID, &linkedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return domain.Session{}, domain.ErrNotFound
	}
	if err != nil {
		return domain.Session{}, err
	}
	if !linkedAt.Valid {
		return domain.Session{}, domain.ErrNotLinked
	}

	if len(groupJIDs) > 0 {
		var found int
		if err := transaction.QueryRow(ctx, `
			SELECT COUNT(*)::INTEGER
			FROM exporter_groups
			WHERE session_id = $1 AND is_available AND jid = ANY($2)`, sessionID, groupJIDs).Scan(&found); err != nil {
			return domain.Session{}, err
		}
		if found != len(groupJIDs) {
			return domain.Session{}, fmt.Errorf("%w: one or more groups are unknown", domain.ErrInvalidInput)
		}
	}

	if _, err := transaction.Exec(ctx, `
		UPDATE exporter_groups
		SET is_selected = jid = ANY($2::TEXT[]),
			history_sync_state = CASE
				WHEN jid = ANY($2::TEXT[]) AND history_sync_state IN (
					'idle', 'waiting_for_anchor', 'stalled', 'failed'
				) THEN 'queued'
				WHEN NOT (jid = ANY($2::TEXT[])) AND history_sync_state IN (
					'queued', 'requesting', 'receiving', 'waiting_for_anchor'
				) THEN 'idle'
				ELSE history_sync_state
			END,
			history_sync_last_error = CASE
				WHEN jid = ANY($2::TEXT[]) THEN NULL
				ELSE history_sync_last_error
			END,
			history_sync_updated_at = CASE
				WHEN jid = ANY($2::TEXT[]) THEN NOW()
				ELSE history_sync_updated_at
			END
		WHERE session_id = $1`, sessionID, groupJIDs); err != nil {
		return domain.Session{}, err
	}

	if _, err := transaction.Exec(ctx, `
		UPDATE exporter_messages m
		SET capture_state = 'active'
		FROM exporter_groups g
		WHERE m.session_id = $1
		  AND m.session_id = g.session_id
		  AND m.group_jid = g.jid
		  AND m.capture_state = 'pending'
		  AND g.is_selected`, sessionID); err != nil {
		return domain.Session{}, err
	}
	if _, err := transaction.Exec(ctx, `
		DELETE FROM exporter_messages m
		USING exporter_groups g
		WHERE m.session_id = $1
		  AND m.session_id = g.session_id
		  AND m.group_jid = g.jid
		  AND m.capture_state = 'pending'
		  AND NOT g.is_selected`, sessionID); err != nil {
		return domain.Session{}, err
	}
	_, err = transaction.Exec(ctx, `
		UPDATE exporter_sessions
		SET selection_finalised_at = COALESCE(selection_finalised_at, NOW()),
			last_synchronised_at = NOW(),
			capture_enabled = CASE WHEN cardinality($2::TEXT[]) = 0 THEN FALSE ELSE capture_enabled END,
			status = CASE WHEN cardinality($2::TEXT[]) = 0 THEN 'paused' ELSE status END
		WHERE id = $1`, sessionID, groupJIDs)
	if err != nil {
		return domain.Session{}, err
	}
	_, err = transaction.Exec(ctx, `
		INSERT INTO exporter_events (session_id, kind, detail)
		VALUES ($1, 'Synchronised', 'Group selection synchronised')`, sessionID)
	if err != nil {
		return domain.Session{}, err
	}
	if err := transaction.Commit(ctx); err != nil {
		return domain.Session{}, err
	}
	return postgres.SessionByUser(ctx, userID)
}

func (postgres *Postgres) QueueHistorySync(
	ctx context.Context,
	userID uuid.UUID,
	groupJIDs []string,
) ([]domain.Group, error) {
	groupJIDs = uniqueStrings(groupJIDs)
	if len(groupJIDs) == 0 {
		return nil, fmt.Errorf("%w: at least one group is required", domain.ErrInvalidInput)
	}

	var sessionID uuid.UUID
	if err := postgres.pool.QueryRow(ctx, `
		SELECT id
		FROM exporter_sessions
		WHERE user_id = $1 AND archived_at IS NULL`, userID).Scan(&sessionID); errors.Is(err, pgx.ErrNoRows) {
		return nil, domain.ErrNotFound
	} else if err != nil {
		return nil, err
	}

	command, err := postgres.pool.Exec(ctx, `
		UPDATE exporter_groups
		SET history_sync_state = 'queued',
			history_sync_started_at = NULL,
			history_sync_completed_at = NULL,
			history_sync_last_error = NULL,
			history_sync_updated_at = NOW()
		WHERE session_id = $1
		  AND is_available
		  AND is_selected
		  AND jid = ANY($2::TEXT[])`, sessionID, groupJIDs)
	if err != nil {
		return nil, err
	}
	if command.RowsAffected() != int64(len(groupJIDs)) {
		return nil, fmt.Errorf("%w: one or more groups are unavailable or not selected", domain.ErrInvalidInput)
	}
	return postgres.Groups(ctx, sessionID)
}

func (postgres *Postgres) HistoryAnchor(
	ctx context.Context,
	sessionID uuid.UUID,
	groupJID string,
) (domain.HistoryAnchor, error) {
	var anchor domain.HistoryAnchor
	anchor.GroupJID = groupJID
	err := postgres.pool.QueryRow(ctx, `
		SELECT history_anchor_message_id, history_anchor_timestamp, history_anchor_from_me
		FROM exporter_groups
		WHERE session_id = $1
		  AND jid = $2
		  AND history_anchor_message_id IS NOT NULL
		  AND history_anchor_timestamp IS NOT NULL`, sessionID, groupJID).Scan(
		&anchor.WhatsAppMessageID,
		&anchor.Timestamp,
		&anchor.IsFromMe,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return domain.HistoryAnchor{}, domain.ErrNotFound
	}
	return anchor, err
}

func (postgres *Postgres) RecordHistoryAnchor(
	ctx context.Context,
	sessionID uuid.UUID,
	anchor domain.HistoryAnchor,
) error {
	if anchor.GroupJID == "" || anchor.WhatsAppMessageID == "" || anchor.Timestamp.IsZero() {
		return domain.ErrInvalidInput
	}
	_, err := postgres.pool.Exec(ctx, `
		UPDATE exporter_groups
		SET history_anchor_message_id = $3,
			history_anchor_timestamp = $4,
			history_anchor_from_me = $5,
			history_oldest_message_at = LEAST(
				COALESCE(history_oldest_message_at, $4),
				$4
			),
			history_sync_updated_at = NOW()
		WHERE session_id = $1
		  AND jid = $2
		  AND (
			history_anchor_timestamp IS NULL
			OR ($4, $3) < (history_anchor_timestamp, history_anchor_message_id)
		  )`, sessionID, anchor.GroupJID, anchor.WhatsAppMessageID, anchor.Timestamp, anchor.IsFromMe)
	return err
}

func (postgres *Postgres) MarkHistorySyncRequest(
	ctx context.Context,
	sessionID uuid.UUID,
	groupJID string,
) error {
	_, err := postgres.pool.Exec(ctx, `
		UPDATE exporter_groups
		SET history_sync_state = 'requesting',
			history_request_count = history_request_count + 1,
			history_sync_started_at = COALESCE(history_sync_started_at, NOW()),
			history_sync_updated_at = NOW(),
			history_sync_last_error = NULL
		WHERE session_id = $1 AND jid = $2 AND is_selected`, sessionID, groupJID)
	return err
}

func (postgres *Postgres) RecordHistoryBatch(
	ctx context.Context,
	sessionID uuid.UUID,
	groupJID string,
	messageCount int,
	oldest *domain.HistoryAnchor,
) error {
	transaction, err := postgres.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = transaction.Rollback(ctx) }()

	if oldest != nil {
		if _, err := transaction.Exec(ctx, `
			UPDATE exporter_groups
			SET history_anchor_message_id = $3,
				history_anchor_timestamp = $4,
				history_anchor_from_me = $5,
				history_oldest_message_at = LEAST(
					COALESCE(history_oldest_message_at, $4),
					$4
				)
			WHERE session_id = $1
			  AND jid = $2
			  AND (
				history_anchor_timestamp IS NULL
				OR ($4, $3) < (history_anchor_timestamp, history_anchor_message_id)
			  )`, sessionID, groupJID, oldest.WhatsAppMessageID, oldest.Timestamp, oldest.IsFromMe); err != nil {
			return err
		}
	}
	if _, err := transaction.Exec(ctx, `
		UPDATE exporter_groups
		SET history_batch_count = history_batch_count + 1,
			history_sync_state = CASE
				WHEN is_selected AND history_sync_state IN ('queued', 'requesting', 'receiving')
					THEN 'receiving'
				ELSE history_sync_state
			END,
			history_sync_updated_at = NOW()
		WHERE session_id = $1 AND jid = $2`, sessionID, groupJID); err != nil {
		return err
	}
	return transaction.Commit(ctx)
}

func (postgres *Postgres) SetHistorySyncState(
	ctx context.Context,
	sessionID uuid.UUID,
	groupJID string,
	state domain.HistorySyncState,
	lastError *string,
) error {
	_, err := postgres.pool.Exec(ctx, `
		UPDATE exporter_groups
		SET history_sync_state = $3,
			history_sync_started_at = CASE
				WHEN $3 IN ('requesting', 'receiving') THEN COALESCE(history_sync_started_at, NOW())
				ELSE history_sync_started_at
			END,
			history_sync_completed_at = CASE
				WHEN $3 = 'complete' THEN NOW()
				WHEN $3 = 'queued' THEN NULL
				ELSE history_sync_completed_at
			END,
			history_sync_last_error = $4,
			history_sync_updated_at = NOW()
		WHERE session_id = $1 AND jid = $2`, sessionID, groupJID, state, lastError)
	return err
}

func uniqueStrings(values []string) []string {
	seen := make(map[string]struct{}, len(values))
	result := make([]string, 0, len(values))
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value == "" {
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
