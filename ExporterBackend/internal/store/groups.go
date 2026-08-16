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
		SELECT jid, name, participant_count, is_selected, last_message_at
		FROM exporter_groups
		WHERE session_id = $1 AND is_available
		ORDER BY is_selected DESC, LOWER(name), jid`, sessionID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	groups := make([]domain.Group, 0)
	for rows.Next() {
		var group domain.Group
		var lastMessage sql.NullTime
		if err := rows.Scan(
			&group.JID,
			&group.Name,
			&group.ParticipantCount,
			&group.IsSelected,
			&lastMessage,
		); err != nil {
			return nil, err
		}
		group.LastMessageAt = nullableTime(lastMessage)
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
		UPDATE exporter_groups SET is_selected = FALSE WHERE session_id = $1`, sessionID); err != nil {
		return domain.Session{}, err
	}
	if len(groupJIDs) > 0 {
		if _, err := transaction.Exec(ctx, `
			UPDATE exporter_groups SET is_selected = TRUE
			WHERE session_id = $1 AND jid = ANY($2)`, sessionID, groupJIDs); err != nil {
			return domain.Session{}, err
		}
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
	if _, err := transaction.Exec(ctx, `
		INSERT INTO exporter_delivery_outbox (message_id, revision)
		SELECT id, revision FROM exporter_messages
		WHERE session_id = $1 AND capture_state = 'active'
		ON CONFLICT (message_id) DO NOTHING`, sessionID); err != nil {
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
