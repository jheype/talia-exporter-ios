package whatsapp

import (
	"testing"
	"time"

	"github.com/google/uuid"
	"go.mau.fi/whatsmeow/proto/waCommon"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	"google.golang.org/protobuf/proto"
)

func TestNormaliseGroupTextMessage(t *testing.T) {
	t.Parallel()
	group, err := types.ParseJID("120363001@g.us")
	if err != nil {
		t.Fatal(err)
	}
	sender, err := types.ParseJID("447700900123@s.whatsapp.net")
	if err != nil {
		t.Fatal(err)
	}
	timestamp := time.Date(2026, time.August, 16, 20, 0, 0, 0, time.UTC)
	event := &events.Message{
		Info: types.MessageInfo{
			MessageSource: types.MessageSource{
				Chat:    group,
				Sender:  sender,
				IsGroup: true,
			},
			ID:        "3EB0ABC123",
			PushName:  "James",
			Timestamp: timestamp,
		},
		Message: &waE2E.Message{Conversation: proto.String("Available for £26,800")},
	}

	message, ok := normaliseMessage(uuid.New(), event, false)
	if !ok {
		t.Fatal("expected message to be accepted")
	}
	if message.GroupJID != group.String() || message.SenderJID != sender.String() {
		t.Fatalf("unexpected source: group=%q sender=%q", message.GroupJID, message.SenderJID)
	}
	if message.Body != "Available for £26,800" || message.Type != "text" {
		t.Fatalf("unexpected content: body=%q type=%q", message.Body, message.Type)
	}
	if message.Timestamp != timestamp || message.HasMedia {
		t.Fatalf("unexpected metadata: timestamp=%v has_media=%v", message.Timestamp, message.HasMedia)
	}
}

func TestNormaliserRejectsDirectMessages(t *testing.T) {
	t.Parallel()
	event := &events.Message{
		Info:    types.MessageInfo{ID: "DIRECT", Timestamp: time.Now()},
		Message: &waE2E.Message{Conversation: proto.String("private")},
	}
	if _, ok := normaliseMessage(uuid.New(), event, false); ok {
		t.Fatal("direct message must not be captured")
	}
}

func TestNormaliseImageMetadata(t *testing.T) {
	t.Parallel()
	event := groupEvent(t, "IMAGE-1", &waE2E.Message{
		ImageMessage: &waE2E.ImageMessage{
			Mimetype:   proto.String("image/jpeg"),
			FileLength: proto.Uint64(128_000),
			Width:      proto.Uint32(1200),
			Height:     proto.Uint32(800),
			Caption:    proto.String("Vehicle exterior"),
		},
	})

	message, ok := normaliseMessage(uuid.New(), event, false)
	if !ok {
		t.Fatal("expected image to be accepted")
	}
	if message.Type != "image" || !message.HasMedia || message.Body != "Vehicle exterior" {
		t.Fatalf("unexpected image content: %#v", message)
	}
	if message.MediaMetadata.MIMEType != "image/jpeg" ||
		message.MediaMetadata.FileSizeBytes != 128_000 ||
		message.MediaMetadata.Width != 1200 || message.MediaMetadata.Height != 800 {
		t.Fatalf("unexpected image metadata: %#v", message.MediaMetadata)
	}
}

func TestNormaliseRevokeTargetsOriginalMessage(t *testing.T) {
	t.Parallel()
	event := groupEvent(t, "REVOKE-EVENT", &waE2E.Message{
		ProtocolMessage: &waE2E.ProtocolMessage{
			Type: waE2E.ProtocolMessage_REVOKE.Enum(),
			Key:  &waCommon.MessageKey{ID: proto.String("ORIGINAL-MESSAGE")},
		},
	})

	message, ok := normaliseMessage(uuid.New(), event, false)
	if !ok {
		t.Fatal("expected revoke to be accepted")
	}
	if !message.IsRevoke || message.WhatsAppMessageID != "ORIGINAL-MESSAGE" {
		t.Fatalf("unexpected revoke target: %#v", message)
	}
	if message.Body != "" || message.HasMedia || message.Type != "system" {
		t.Fatalf("unexpected revoke content: %#v", message)
	}
}

func groupEvent(t *testing.T, messageID string, message *waE2E.Message) *events.Message {
	t.Helper()
	group, err := types.ParseJID("120363001@g.us")
	if err != nil {
		t.Fatal(err)
	}
	sender, err := types.ParseJID("447700900123@s.whatsapp.net")
	if err != nil {
		t.Fatal(err)
	}
	return &events.Message{
		Info: types.MessageInfo{
			MessageSource: types.MessageSource{Chat: group, Sender: sender, IsGroup: true},
			ID:            types.MessageID(messageID),
			Timestamp:     time.Now().UTC(),
		},
		Message: message,
	}
}
