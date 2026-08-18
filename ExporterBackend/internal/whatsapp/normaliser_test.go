package whatsapp

import (
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/talia/exporter/internal/domain"
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

func TestNormaliserRejectsImageAndCaption(t *testing.T) {
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

	if _, ok := normaliseMessage(uuid.New(), event, false); ok {
		t.Fatal("images and their captions must not be captured")
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

func TestOlderAnchorOrdersByTimestampThenMessageID(t *testing.T) {
	t.Parallel()
	timestamp := time.Date(2026, time.August, 17, 20, 0, 0, 0, time.UTC)
	current := &domain.HistoryAnchor{
		WhatsAppMessageID: "MESSAGE-B",
		Timestamp:         timestamp,
	}

	if !olderAnchor(current, domain.HistoryAnchor{
		WhatsAppMessageID: "MESSAGE-Z",
		Timestamp:         timestamp.Add(-time.Second),
	}) {
		t.Fatal("an earlier timestamp must advance the history cursor")
	}
	if !olderAnchor(current, domain.HistoryAnchor{
		WhatsAppMessageID: "MESSAGE-A",
		Timestamp:         timestamp,
	}) {
		t.Fatal("message ID must break equal-timestamp ties deterministically")
	}
	if olderAnchor(current, domain.HistoryAnchor{
		WhatsAppMessageID: "MESSAGE-C",
		Timestamp:         timestamp,
	}) {
		t.Fatal("a later equal-timestamp message must not move the cursor forward")
	}
}

func TestShortHistoryBatchDoesNotMeanHistoryIsComplete(t *testing.T) {
	t.Parallel()
	batch := historyBatch{
		groupJID:     "120363001@g.us",
		messageCount: 22,
		oldest: &domain.HistoryAnchor{
			WhatsAppMessageID: "OLDER-MESSAGE",
			Timestamp:         time.Date(2026, time.August, 1, 12, 0, 0, 0, time.UTC),
		},
	}
	seen := map[string]struct{}{"NEWER-MESSAGE": {}}

	if got := classifyHistoryBatch(batch, seen); got != historyBatchContinue {
		t.Fatal("a short non-empty batch must continue from its oldest anchor")
	}
}

func TestHistoryBatchCompletesOnlyWhenWhatsAppReportsTheEnd(t *testing.T) {
	t.Parallel()
	if got := classifyHistoryBatch(
		historyBatch{groupJID: "120363001@g.us", endOfHistory: true},
		nil,
	); got != historyBatchComplete {
		t.Fatal("an explicit end-of-history response must finish the history walk")
	}
	if got := classifyHistoryBatch(
		historyBatch{groupJID: "120363001@g.us"},
		nil,
	); got != historyBatchStalled {
		t.Fatal("an ambiguous empty conversation must stall rather than falsely report completion")
	}
}

func TestEmptyOnDemandResponseIsCorrelatedAsExplicitEnd(t *testing.T) {
	t.Parallel()
	if got := classifyHistoryBatch(
		historyBatch{groupJID: "120363001@g.us", endOfHistory: true},
		nil,
	); got != historyBatchComplete {
		t.Fatal("the correlated empty ON_DEMAND response must finish the history walk")
	}
}

func TestHistoryBatchStallsOnRepeatedCursorOrUnavailableHistory(t *testing.T) {
	t.Parallel()
	anchor := &domain.HistoryAnchor{
		WhatsAppMessageID: "REPEATED-MESSAGE",
		Timestamp:         time.Date(2026, time.July, 1, 12, 0, 0, 0, time.UTC),
	}
	if got := classifyHistoryBatch(
		historyBatch{groupJID: "120363001@g.us", messageCount: 50, oldest: anchor},
		map[string]struct{}{anchor.WhatsAppMessageID: {}},
	); got != historyBatchStalled {
		t.Fatal("a repeated oldest cursor must be shown as stalled, not complete")
	}
	if got := classifyHistoryBatch(
		historyBatch{
			groupJID:      "120363001@g.us",
			messageCount:  22,
			oldest:        anchor,
			accessLimited: true,
		},
		nil,
	); got != historyBatchStalled {
		t.Fatal("history that remains on the phone but cannot be accessed must be shown as stalled")
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
