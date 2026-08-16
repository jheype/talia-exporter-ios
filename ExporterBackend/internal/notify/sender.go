package notify

import (
	"context"

	"github.com/google/uuid"
)

type Sender interface {
	SendInterruption(context.Context, uuid.UUID, string, string) error
}

type NoopSender struct{}

func (NoopSender) SendInterruption(context.Context, uuid.UUID, string, string) error {
	return nil
}

type TokenRepository interface {
	DeviceTokens(context.Context, uuid.UUID) ([]string, error)
	DeleteDeviceToken(context.Context, uuid.UUID, string) error
}
