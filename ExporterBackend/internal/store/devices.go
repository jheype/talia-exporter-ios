package store

import (
	"context"

	"github.com/google/uuid"
)

func (postgres *Postgres) RegisterDevice(
	ctx context.Context,
	userID uuid.UUID,
	platform string,
	token string,
) error {
	transaction, err := postgres.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = transaction.Rollback(ctx) }()

	_, err = transaction.Exec(ctx, `
		INSERT INTO exporter_devices (user_id, platform, token)
		VALUES ($1, $2, $3)
		ON CONFLICT (platform, token) DO UPDATE SET
			user_id = EXCLUDED.user_id,
			updated_at = NOW()`,
		userID, platform, token)
	if err != nil {
		return err
	}
	_, err = transaction.Exec(ctx, `
		DELETE FROM exporter_devices
		WHERE user_id = $1
		  AND (platform, token) NOT IN (
			SELECT platform, token
			FROM exporter_devices
			WHERE user_id = $1
			ORDER BY updated_at DESC
			LIMIT 5
		  )`, userID)
	if err != nil {
		return err
	}
	return transaction.Commit(ctx)
}

func (postgres *Postgres) DeviceTokens(ctx context.Context, userID uuid.UUID) ([]string, error) {
	rows, err := postgres.pool.Query(ctx, `
		SELECT token
		FROM exporter_devices
		WHERE user_id = $1 AND platform = 'ios'
		ORDER BY updated_at DESC
		LIMIT 5`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	tokens := make([]string, 0)
	for rows.Next() {
		var token string
		if err := rows.Scan(&token); err != nil {
			return nil, err
		}
		tokens = append(tokens, token)
	}
	return tokens, rows.Err()
}

func (postgres *Postgres) DeleteDeviceToken(ctx context.Context, userID uuid.UUID, token string) error {
	_, err := postgres.pool.Exec(ctx, `
		DELETE FROM exporter_devices WHERE user_id = $1 AND token = $2`, userID, token)
	return err
}

func (postgres *Postgres) DeleteDevices(ctx context.Context, userID uuid.UUID) error {
	_, err := postgres.pool.Exec(ctx, `DELETE FROM exporter_devices WHERE user_id = $1`, userID)
	return err
}
