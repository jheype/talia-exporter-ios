package store

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

type Postgres struct {
	pool *pgxpool.Pool
}

func NewPostgres(ctx context.Context, databaseURL string) (*Postgres, error) {
	config, err := pgxpool.ParseConfig(databaseURL)
	if err != nil {
		return nil, fmt.Errorf("parse database URL: %w", err)
	}
	config.MaxConns = 20
	config.MinConns = 2
	config.MaxConnIdleTime = 5 * time.Minute
	config.MaxConnLifetime = 30 * time.Minute

	pool, err := pgxpool.NewWithConfig(ctx, config)
	if err != nil {
		return nil, fmt.Errorf("open database pool: %w", err)
	}
	return &Postgres{pool: pool}, nil
}

func (postgres *Postgres) Ping(ctx context.Context) error {
	return postgres.pool.Ping(ctx)
}

func (postgres *Postgres) Close() {
	postgres.pool.Close()
}

func (postgres *Postgres) Migrate(ctx context.Context, migration string) error {
	const lockID int64 = 84172953
	connection, err := postgres.pool.Acquire(ctx)
	if err != nil {
		return err
	}
	defer connection.Release()

	if _, err := connection.Exec(ctx, `SELECT pg_advisory_lock($1)`, lockID); err != nil {
		return fmt.Errorf("acquire migration lock: %w", err)
	}
	defer func() { _, _ = connection.Exec(context.Background(), `SELECT pg_advisory_unlock($1)`, lockID) }()

	if _, err := connection.Exec(ctx, migration); err != nil {
		return fmt.Errorf("apply exporter migration: %w", err)
	}
	return nil
}
