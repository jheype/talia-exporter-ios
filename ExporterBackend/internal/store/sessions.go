package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/talia/exporter/internal/domain"
)

const sessionProjection = `
    s.id,
    s.user_id,
    s.phone_number,
    s.whatsapp_device_jid,
    s.status,
    s.capture_enabled,
    s.include_media,
    s.selection_finalised_at,
    s.linked_at,
    s.last_connected_at,
    s.last_message_at,
    s.last_synchronised_at,
    s.last_error_message,
    (SELECT COUNT(*)::INTEGER FROM exporter_groups g WHERE g.session_id = s.id AND g.is_selected),
    (SELECT COUNT(*)::BIGINT FROM exporter_messages m WHERE m.session_id = s.id AND m.capture_state = 'active')`

func (postgres *Postgres) SessionByUser(ctx context.Context, userID uuid.UUID) (domain.Session, error) {
	query := `SELECT ` + sessionProjection + ` FROM exporter_sessions s WHERE s.user_id = $1 AND s.archived_at IS NULL`
	return scanSession(postgres.pool.QueryRow(ctx, query, userID))
}

func (postgres *Postgres) SessionByID(ctx context.Context, sessionID uuid.UUID) (domain.Session, error) {
	query := `SELECT ` + sessionProjection + ` FROM exporter_sessions s WHERE s.id = $1`
	return scanSession(postgres.pool.QueryRow(ctx, query, sessionID))
}

func (postgres *Postgres) BeginPairing(ctx context.Context, userID uuid.UUID, phoneNumber string) (domain.Session, error) {
	_, err := postgres.pool.Exec(ctx, `
		INSERT INTO exporter_sessions (
			user_id, phone_number, status, capture_enabled, whatsapp_device_jid,
			selection_finalised_at, linked_at, last_error_code, last_error_message,
			worker_id, lease_expires_at
		) VALUES ($1, $2, 'pairing', FALSE, NULL, NULL, NULL, NULL, NULL, NULL, NULL)
		ON CONFLICT (user_id) WHERE archived_at IS NULL DO UPDATE SET
			phone_number = EXCLUDED.phone_number,
			status = 'pairing',
			capture_enabled = FALSE,
			whatsapp_device_jid = NULL,
			selection_finalised_at = NULL,
			linked_at = NULL,
			last_connected_at = NULL,
			last_message_at = NULL,
			last_synchronised_at = NULL,
			last_error_code = NULL,
			last_error_message = NULL,
			last_interruption_notified_at = NULL,
			worker_id = NULL,
			lease_expires_at = NULL`,
		userID,
		phoneNumber,
	)
	if err != nil {
		return domain.Session{}, fmt.Errorf("begin pairing: %w", err)
	}
	return postgres.SessionByUser(ctx, userID)
}

func (postgres *Postgres) MarkLinked(ctx context.Context, sessionID uuid.UUID, deviceJID string) error {
	result, err := postgres.pool.Exec(ctx, `
		UPDATE exporter_sessions
		SET whatsapp_device_jid = $2,
			status = CASE WHEN capture_enabled THEN 'connected' ELSE 'paused' END,
			linked_at = COALESCE(linked_at, NOW()),
			last_connected_at = NOW(),
			last_synchronised_at = NOW(),
			last_error_code = NULL,
			last_error_message = NULL
		WHERE id = $1`, sessionID, deviceJID)
	if err != nil {
		return fmt.Errorf("mark session linked: %w", err)
	}
	if result.RowsAffected() == 0 {
		return domain.ErrNotFound
	}
	return nil
}

func (postgres *Postgres) SetSessionStatus(
	ctx context.Context,
	sessionID uuid.UUID,
	status domain.SessionStatus,
	message *string,
) error {
	result, err := postgres.pool.Exec(ctx, `
		UPDATE exporter_sessions
		SET status = $2,
			last_connected_at = CASE WHEN $2 = 'connected' THEN NOW() ELSE last_connected_at END,
			last_synchronised_at = CASE WHEN $2 = 'connected' THEN NOW() ELSE last_synchronised_at END,
			last_error_message = $3,
			last_error_code = CASE WHEN $3::TEXT IS NULL THEN NULL ELSE 'WHATSAPP.CONNECTION' END
		WHERE id = $1`, sessionID, status, message)
	if err != nil {
		return fmt.Errorf("set session status: %w", err)
	}
	if result.RowsAffected() == 0 {
		return domain.ErrNotFound
	}
	return nil
}

func (postgres *Postgres) ClaimInterruptionNotification(
	ctx context.Context,
	sessionID uuid.UUID,
	cooldown time.Duration,
) (uuid.UUID, bool, error) {
	var userID uuid.UUID
	err := postgres.pool.QueryRow(ctx, `
		UPDATE exporter_sessions
		SET last_interruption_notified_at = NOW()
		WHERE id = $1
		  AND (
			last_interruption_notified_at IS NULL
			OR last_interruption_notified_at < NOW() - $2::INTERVAL
		  )
		RETURNING user_id`, sessionID, interval(cooldown)).Scan(&userID)
	if errors.Is(err, pgx.ErrNoRows) {
		return uuid.Nil, false, nil
	}
	if err != nil {
		return uuid.Nil, false, err
	}
	return userID, true, nil
}

func (postgres *Postgres) SetCaptureEnabled(ctx context.Context, userID uuid.UUID, enabled bool) (domain.Session, error) {
	transaction, err := postgres.pool.Begin(ctx)
	if err != nil {
		return domain.Session{}, err
	}
	defer func() { _ = transaction.Rollback(ctx) }()

	var selected int
	var linkedAt sql.NullTime
	var deviceJID sql.NullString
	var currentStatus domain.SessionStatus
	err = transaction.QueryRow(ctx, `
		SELECT COUNT(g.jid)::INTEGER, s.linked_at, s.whatsapp_device_jid, s.status
		FROM exporter_sessions s
		LEFT JOIN exporter_groups g ON g.session_id = s.id AND g.is_selected
		WHERE s.user_id = $1 AND s.archived_at IS NULL
		GROUP BY s.id`, userID).Scan(&selected, &linkedAt, &deviceJID, &currentStatus)
	if errors.Is(err, pgx.ErrNoRows) {
		return domain.Session{}, domain.ErrNotFound
	}
	if err != nil {
		return domain.Session{}, err
	}
	if !linkedAt.Valid || !deviceJID.Valid || currentStatus == domain.StatusLoggedOut {
		return domain.Session{}, domain.ErrNotLinked
	}
	if enabled && selected == 0 {
		return domain.Session{}, fmt.Errorf("%w: select at least one group", domain.ErrInvalidInput)
	}

	_, err = transaction.Exec(ctx, `
		UPDATE exporter_sessions
		SET capture_enabled = $2,
			status = CASE
				WHEN NOT $2 THEN 'paused'
				WHEN status IN ('connecting', 'reconnecting', 'interrupted') THEN status
				ELSE 'connected'
			END
		WHERE user_id = $1 AND archived_at IS NULL`, userID, enabled)
	if err != nil {
		return domain.Session{}, err
	}
	if err := transaction.Commit(ctx); err != nil {
		return domain.Session{}, err
	}
	return postgres.SessionByUser(ctx, userID)
}

func (postgres *Postgres) SetIncludeMedia(ctx context.Context, userID uuid.UUID, enabled bool) (domain.Session, error) {
	result, err := postgres.pool.Exec(ctx, `
		UPDATE exporter_sessions SET include_media = $2 WHERE user_id = $1 AND archived_at IS NULL`, userID, enabled)
	if err != nil {
		return domain.Session{}, err
	}
	if result.RowsAffected() == 0 {
		return domain.Session{}, domain.ErrNotFound
	}
	return postgres.SessionByUser(ctx, userID)
}

func (postgres *Postgres) ArchiveSession(ctx context.Context, userID uuid.UUID) error {
	result, err := postgres.pool.Exec(ctx, `
		UPDATE exporter_sessions
		SET archived_at = NOW(),
			status = 'unlinked',
			capture_enabled = FALSE,
			whatsapp_device_jid = NULL,
			worker_id = NULL,
			lease_expires_at = NULL
		WHERE user_id = $1 AND archived_at IS NULL`, userID)
	if err != nil {
		return err
	}
	if result.RowsAffected() == 0 {
		return domain.ErrNotFound
	}
	return nil
}

func (postgres *Postgres) SessionsForReconciliation(ctx context.Context) ([]domain.Session, error) {
	query := `SELECT ` + sessionProjection + `
		FROM exporter_sessions s
		WHERE s.whatsapp_device_jid IS NOT NULL
		  AND s.archived_at IS NULL
		  AND s.status NOT IN ('unlinked', 'logged_out')
		ORDER BY s.updated_at`
	rows, err := postgres.pool.Query(ctx, query)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	sessions := make([]domain.Session, 0)
	for rows.Next() {
		session, err := scanSession(rows)
		if err != nil {
			return nil, err
		}
		sessions = append(sessions, session)
	}
	return sessions, rows.Err()
}

func (postgres *Postgres) AcquireLease(
	ctx context.Context,
	sessionID uuid.UUID,
	workerID string,
	ttl time.Duration,
) (bool, error) {
	result, err := postgres.pool.Exec(ctx, `
		UPDATE exporter_sessions
		SET worker_id = $2, lease_expires_at = NOW() + $3::INTERVAL
		WHERE id = $1
		  AND (lease_expires_at IS NULL OR lease_expires_at < NOW() OR worker_id = $2)`,
		sessionID, workerID, interval(ttl))
	return result.RowsAffected() == 1, err
}

func (postgres *Postgres) RenewLease(
	ctx context.Context,
	sessionID uuid.UUID,
	workerID string,
	ttl time.Duration,
) (bool, error) {
	result, err := postgres.pool.Exec(ctx, `
		UPDATE exporter_sessions
		SET lease_expires_at = NOW() + $3::INTERVAL
		WHERE id = $1 AND worker_id = $2`, sessionID, workerID, interval(ttl))
	return result.RowsAffected() == 1, err
}

func (postgres *Postgres) ReleaseLease(ctx context.Context, sessionID uuid.UUID, workerID string) error {
	_, err := postgres.pool.Exec(ctx, `
		UPDATE exporter_sessions
		SET worker_id = NULL, lease_expires_at = NULL
		WHERE id = $1 AND worker_id = $2`, sessionID, workerID)
	return err
}

func scanSession(row pgx.Row) (domain.Session, error) {
	var session domain.Session
	var phoneNumber sql.NullString
	var deviceJID sql.NullString
	var selectionFinalised sql.NullTime
	var linkedAt sql.NullTime
	var lastConnected sql.NullTime
	var lastMessage sql.NullTime
	var lastSynchronised sql.NullTime
	var lastError sql.NullString

	err := row.Scan(
		&session.ID,
		&session.UserID,
		&phoneNumber,
		&deviceJID,
		&session.Status,
		&session.CaptureEnabled,
		&session.IncludeMedia,
		&selectionFinalised,
		&linkedAt,
		&lastConnected,
		&lastMessage,
		&lastSynchronised,
		&lastError,
		&session.SelectedGroupCount,
		&session.CapturedMessageCount,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return domain.Session{}, domain.ErrNotFound
	}
	if err != nil {
		return domain.Session{}, err
	}

	session.PhoneNumber = nullableString(phoneNumber)
	session.DeviceJID = nullableString(deviceJID)
	session.SelectionFinalisedAt = nullableTime(selectionFinalised)
	session.LinkedAt = nullableTime(linkedAt)
	session.LastConnectedAt = nullableTime(lastConnected)
	session.LastMessageAt = nullableTime(lastMessage)
	session.LastSynchronisedAt = nullableTime(lastSynchronised)
	session.LastError = nullableString(lastError)
	return session, nil
}

func nullableString(value sql.NullString) *string {
	if !value.Valid {
		return nil
	}
	return &value.String
}

func nullableTime(value sql.NullTime) *time.Time {
	if !value.Valid {
		return nil
	}
	return &value.Time
}

func interval(value time.Duration) string {
	return fmt.Sprintf("%f seconds", value.Seconds())
}
