package store

import (
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestCursorRoundTrip(t *testing.T) {
	t.Parallel()
	timestamp := time.Date(2026, time.August, 16, 18, 30, 15, 123456789, time.UTC)
	id := uuid.MustParse("5eb3e5a6-2832-4f35-a1f8-45814593eb6d")

	encoded := encodeCursor(timestamp, id)
	decodedTime, decodedID, err := decodeCursor(&encoded)
	if err != nil {
		t.Fatalf("decode cursor: %v", err)
	}
	if decodedTime == nil || !decodedTime.Equal(timestamp) {
		t.Fatalf("decoded time = %v, want %v", decodedTime, timestamp)
	}
	if decodedID != id {
		t.Fatalf("decoded ID = %v, want %v", decodedID, id)
	}
}

func TestInvalidCursor(t *testing.T) {
	t.Parallel()
	value := "not-a-cursor"
	if _, _, err := decodeCursor(&value); err == nil {
		t.Fatal("expected invalid cursor error")
	}
}
