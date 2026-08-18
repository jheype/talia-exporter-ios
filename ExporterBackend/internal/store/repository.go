package store

import (
	"context"
	"time"

	"github.com/google/uuid"
	"github.com/talia/exporter/internal/domain"
)

type Repository interface {
	Ping(context.Context) error
	Close()
	Migrate(context.Context, string) error

	SessionByUser(context.Context, uuid.UUID) (domain.Session, error)
	SessionByID(context.Context, uuid.UUID) (domain.Session, error)
	BeginPairing(context.Context, uuid.UUID, string) (domain.Session, error)
	MarkLinked(context.Context, uuid.UUID, string) error
	SetSessionStatus(context.Context, uuid.UUID, domain.SessionStatus, *string) error
	ClaimInterruptionNotification(context.Context, uuid.UUID, time.Duration) (uuid.UUID, bool, error)
	SetCaptureEnabled(context.Context, uuid.UUID, bool) (domain.Session, error)
	SetIncludeMedia(context.Context, uuid.UUID, bool) (domain.Session, error)
	ArchiveSession(context.Context, uuid.UUID) error
	SessionsForReconciliation(context.Context) ([]domain.Session, error)
	AcquireLease(context.Context, uuid.UUID, string, time.Duration) (bool, error)
	RenewLease(context.Context, uuid.UUID, string, time.Duration) (bool, error)
	ReleaseLease(context.Context, uuid.UUID, string) error

	UpsertGroups(context.Context, uuid.UUID, []domain.Group) error
	Groups(context.Context, uuid.UUID) ([]domain.Group, error)
	SaveSelection(context.Context, uuid.UUID, []string) (domain.Session, error)
	QueueHistorySync(context.Context, uuid.UUID, []string) ([]domain.Group, error)
	HistoryAnchor(context.Context, uuid.UUID, string) (domain.HistoryAnchor, error)
	RecordHistoryAnchor(context.Context, uuid.UUID, domain.HistoryAnchor) error
	MarkHistorySyncRequest(context.Context, uuid.UUID, string) error
	RecordHistoryBatch(context.Context, uuid.UUID, string, int, *domain.HistoryAnchor) error
	SetHistorySyncState(context.Context, uuid.UUID, string, domain.HistorySyncState, *string) error

	InsertMessage(context.Context, domain.IncomingMessage) (bool, error)
	PurgeExpiredPendingMessages(context.Context, time.Duration) error
	Messages(context.Context, uuid.UUID, int, *string) (domain.CursorPage[domain.CapturedMessage], error)
	MarkMessagesQueuedForIngestion(context.Context, uuid.UUID, []uuid.UUID, uuid.UUID) error
	Events(context.Context, uuid.UUID, int, *string) (domain.CursorPage[domain.CaptureEvent], error)
	Dashboard(context.Context, uuid.UUID) (domain.Dashboard, error)
	RegisterDevice(context.Context, uuid.UUID, string, string) error
	DeviceTokens(context.Context, uuid.UUID) ([]string, error)
	DeleteDeviceToken(context.Context, uuid.UUID, string) error
	DeleteDevices(context.Context, uuid.UUID) error
}
