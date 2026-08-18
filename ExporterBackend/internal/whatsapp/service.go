package whatsapp

import (
	"context"

	"github.com/google/uuid"
	"github.com/talia/exporter/internal/domain"
)

type Service interface {
	Pair(context.Context, uuid.UUID, string) (domain.PairingCode, error)
	SynchroniseGroups(context.Context, uuid.UUID) ([]domain.Group, error)
	StartHistorySync(context.Context, uuid.UUID) error
	RetryHistorySync(context.Context, uuid.UUID, []string) ([]domain.Group, error)
	Unlink(context.Context, uuid.UUID) error
}
