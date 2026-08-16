package domain

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestSessionJSONContract(t *testing.T) {
	t.Parallel()
	linkedAt := time.Date(2026, time.August, 16, 20, 0, 0, 0, time.UTC)
	session := Session{
		ID:                   uuid.MustParse("71109c1f-5c5c-4500-879f-69c392727b44"),
		UserID:               uuid.MustParse("665fcf6b-22ba-4ad8-be96-a9621c014040"),
		Status:               StatusConnected,
		CaptureEnabled:       true,
		IncludeMedia:         true,
		LinkedAt:             &linkedAt,
		SelectedGroupCount:   3,
		CapturedMessageCount: 42,
	}

	encoded, err := json.Marshal(session)
	if err != nil {
		t.Fatalf("marshal session: %v", err)
	}
	var object map[string]any
	if err := json.Unmarshal(encoded, &object); err != nil {
		t.Fatalf("unmarshal session: %v", err)
	}
	for _, key := range []string{
		"id", "user_id", "phone_number", "status", "capture_enabled", "include_media",
		"linked_at", "last_connected_at", "last_message_at", "last_synchronised_at",
		"last_error", "selected_group_count", "captured_message_count",
	} {
		if _, present := object[key]; !present {
			t.Errorf("session JSON missing %q", key)
		}
	}
	if _, leaked := object["DeviceJID"]; leaked {
		t.Fatal("internal WhatsApp device identity leaked into session JSON")
	}
}

func TestCapturedMessageJSONContract(t *testing.T) {
	t.Parallel()
	message := CapturedMessage{
		ID:                uuid.New(),
		WhatsAppMessageID: "MSG-1",
		GroupJID:          "120363001@g.us",
		GroupName:         "Project Phoenix",
		SenderJID:         "447700900123@s.whatsapp.net",
		Sender:            "James",
		Body:              "Vehicle exterior",
		Type:              MessageImage,
		Timestamp:         time.Now().UTC(),
		HasMedia:          true,
		IsEdited:          true,
		Revision:          2,
		MediaMetadata: &MediaMetadata{
			MIMEType:      "image/jpeg",
			FileSizeBytes: 128_000,
		},
	}

	encoded, err := json.Marshal(message)
	if err != nil {
		t.Fatalf("marshal message: %v", err)
	}
	var object map[string]any
	if err := json.Unmarshal(encoded, &object); err != nil {
		t.Fatalf("unmarshal message: %v", err)
	}
	for _, key := range []string{
		"id", "whatsapp_message_id", "group_jid", "group_name", "sender_jid",
		"sender", "body", "type", "timestamp", "is_from_me", "has_media",
		"is_edited", "is_revoked", "revision", "media_metadata",
	} {
		if _, present := object[key]; !present {
			t.Errorf("message JSON missing %q", key)
		}
	}
	media, ok := object["media_metadata"].(map[string]any)
	if !ok || media["mime_type"] != "image/jpeg" {
		t.Fatalf("media metadata = %#v", object["media_metadata"])
	}
}
