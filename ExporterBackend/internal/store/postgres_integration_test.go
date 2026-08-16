package store

import (
	"context"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/talia/exporter/internal/domain"
	"github.com/talia/exporter/migrations"
)

func TestPostgresCaptureLifecycle(t *testing.T) {
	databaseURL := os.Getenv("TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("TEST_DATABASE_URL is not configured")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	repository, err := NewPostgres(ctx, databaseURL)
	if err != nil {
		t.Fatalf("open PostgreSQL: %v", err)
	}
	defer repository.Close()
	if err := repository.Migrate(ctx, migrations.Initial); err != nil {
		t.Fatalf("migrate PostgreSQL: %v", err)
	}
	if _, err := repository.pool.Exec(ctx, `
		TRUNCATE exporter_delivery_outbox, exporter_events, exporter_messages,
			exporter_groups, exporter_sessions, exporter_devices CASCADE`); err != nil {
		t.Fatalf("clean integration tables: %v", err)
	}

	userID := uuid.New()
	session, err := repository.BeginPairing(ctx, userID, "+447700900123")
	if err != nil {
		t.Fatalf("begin pairing: %v", err)
	}
	if session.Status != domain.StatusPairing {
		t.Fatalf("status = %q, want pairing", session.Status)
	}
	if err := repository.MarkLinked(ctx, session.ID, "447700900123:1@s.whatsapp.net"); err != nil {
		t.Fatalf("mark linked: %v", err)
	}
	notificationUserID, claimed, err := repository.ClaimInterruptionNotification(ctx, session.ID, time.Hour)
	if err != nil || !claimed || notificationUserID != userID {
		t.Fatalf("claim interruption notification: user=%s claimed=%v error=%v", notificationUserID, claimed, err)
	}
	if _, claimed, err := repository.ClaimInterruptionNotification(ctx, session.ID, time.Hour); err != nil || claimed {
		t.Fatalf("duplicate interruption notification: claimed=%v error=%v", claimed, err)
	}
	if err := repository.UpsertGroups(ctx, session.ID, []domain.Group{
		{JID: "120363001@g.us", Name: "Project Phoenix", ParticipantCount: 28},
		{JID: "120363002@g.us", Name: "Logistics", ParticipantCount: 12},
	}); err != nil {
		t.Fatalf("upsert groups: %v", err)
	}
	if _, err := repository.SaveSelection(ctx, userID, []string{"120363001@g.us"}); err != nil {
		t.Fatalf("save selection: %v", err)
	}
	if _, err := repository.SetCaptureEnabled(ctx, userID, true); err != nil {
		t.Fatalf("enable capture: %v", err)
	}

	timestamp := time.Now().UTC().Truncate(time.Millisecond)
	incoming := domain.IncomingMessage{
		SessionID:         session.ID,
		WhatsAppMessageID: "MSG-1",
		GroupJID:          "120363001@g.us",
		SenderJID:         "447700900124@s.whatsapp.net",
		SenderName:        "James",
		Body:              "Available for £26,800",
		Type:              domain.MessageText,
		Timestamp:         timestamp,
		RawMetadata:       map[string]any{"history_sync": false},
	}
	captured, err := repository.InsertMessage(ctx, incoming)
	if err != nil || !captured {
		t.Fatalf("insert message: captured=%v error=%v", captured, err)
	}
	captured, err = repository.InsertMessage(ctx, incoming)
	if err != nil || captured {
		t.Fatalf("deduplicate message: captured=%v error=%v", captured, err)
	}
	if _, err := repository.pool.Exec(ctx, `
		UPDATE exporter_delivery_outbox
		SET status = 'delivered', delivered_at = NOW()
		WHERE message_id = (
			SELECT id FROM exporter_messages WHERE whatsapp_message_id = 'MSG-1'
		)`); err != nil {
		t.Fatalf("mark outbox delivered: %v", err)
	}
	edited := incoming
	edited.Body = "Available for £26,500"
	edited.IsEdit = true
	if captured, err := repository.InsertMessage(ctx, edited); err != nil || captured {
		t.Fatalf("edit message: captured=%v error=%v", captured, err)
	}
	if captured, err := repository.InsertMessage(ctx, edited); err != nil || captured {
		t.Fatalf("deduplicate edit: captured=%v error=%v", captured, err)
	}
	var outboxStatus string
	var outboxRevision int
	if err := repository.pool.QueryRow(ctx, `
		SELECT o.status, o.revision
		FROM exporter_delivery_outbox o
		JOIN exporter_messages m ON m.id = o.message_id
		WHERE m.whatsapp_message_id = 'MSG-1'`).Scan(&outboxStatus, &outboxRevision); err != nil {
		t.Fatalf("load edited outbox: %v", err)
	}
	if outboxStatus != "pending" || outboxRevision != 2 {
		t.Fatalf("edited outbox status=%q revision=%d, want pending revision 2", outboxStatus, outboxRevision)
	}
	if _, err := repository.SetCaptureEnabled(ctx, userID, false); err != nil {
		t.Fatalf("pause capture: %v", err)
	}
	pausedEdit := edited
	pausedEdit.Body = "Available for £26,400"
	if captured, err := repository.InsertMessage(ctx, pausedEdit); err != nil || captured {
		t.Fatalf("edit stored message while paused: captured=%v error=%v", captured, err)
	}
	if _, err := repository.SetCaptureEnabled(ctx, userID, true); err != nil {
		t.Fatalf("resume capture: %v", err)
	}

	image := incoming
	image.WhatsAppMessageID = "MSG-2"
	image.Body = "Vehicle exterior"
	image.Type = domain.MessageImage
	image.HasMedia = true
	image.MediaMetadata = domain.MediaMetadata{
		MIMEType:      "image/jpeg",
		FileSizeBytes: 128_000,
		Width:         1200,
		Height:        800,
	}
	if captured, err := repository.InsertMessage(ctx, image); err != nil || !captured {
		t.Fatalf("insert image: captured=%v error=%v", captured, err)
	}

	dashboard, err := repository.Dashboard(ctx, userID)
	if err != nil {
		t.Fatalf("load dashboard: %v", err)
	}
	if dashboard.Session.CapturedMessageCount != 2 || len(dashboard.Messages) != 2 {
		t.Fatalf(
			"captured count=%d messages=%d, want two",
			dashboard.Session.CapturedMessageCount,
			len(dashboard.Messages),
		)
	}
	var imageMessage *domain.CapturedMessage
	for index := range dashboard.Messages {
		if dashboard.Messages[index].WhatsAppMessageID == "MSG-2" {
			imageMessage = &dashboard.Messages[index]
			break
		}
	}
	if imageMessage == nil || imageMessage.MediaMetadata == nil || imageMessage.MediaMetadata.MIMEType != "image/jpeg" {
		t.Fatalf("image message = %#v", imageMessage)
	}
	if len(dashboard.Events) != 2 {
		t.Fatalf("events=%d, want selection and capture events", len(dashboard.Events))
	}
	if _, err := repository.SaveSelection(ctx, userID, nil); err != nil {
		t.Fatalf("clear selection before revoke: %v", err)
	}

	revoked := incoming
	revoked.Body = ""
	revoked.Type = domain.MessageSystem
	revoked.IsRevoke = true
	if captured, err := repository.InsertMessage(ctx, revoked); err != nil || captured {
		t.Fatalf("revoke message: captured=%v error=%v", captured, err)
	}
	if captured, err := repository.InsertMessage(ctx, revoked); err != nil || captured {
		t.Fatalf("deduplicate revoke: captured=%v error=%v", captured, err)
	}
	dashboard, err = repository.Dashboard(ctx, userID)
	if err != nil {
		t.Fatalf("load dashboard after revoke: %v", err)
	}
	var revokedMessage *domain.CapturedMessage
	for index := range dashboard.Messages {
		if dashboard.Messages[index].WhatsAppMessageID == "MSG-1" {
			revokedMessage = &dashboard.Messages[index]
			break
		}
	}
	if revokedMessage == nil || !revokedMessage.IsRevoked || revokedMessage.Body != "" || revokedMessage.Revision != 4 {
		t.Fatalf("revoked message = %#v", revokedMessage)
	}

	if err := repository.ArchiveSession(ctx, userID); err != nil {
		t.Fatalf("archive session: %v", err)
	}
	if _, err := repository.SessionByUser(ctx, userID); !errors.Is(err, domain.ErrNotFound) {
		t.Fatalf("active session after archive: %v", err)
	}
}
