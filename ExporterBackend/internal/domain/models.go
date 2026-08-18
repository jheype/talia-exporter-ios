package domain

import (
	"errors"
	"time"

	"github.com/google/uuid"
)

var (
	ErrNotFound          = errors.New("resource not found")
	ErrConflict          = errors.New("resource conflict")
	ErrInvalidInput      = errors.New("invalid input")
	ErrNotLinked         = errors.New("WhatsApp session is not linked")
	ErrPairingInProgress = errors.New("pairing is already in progress")
)

type User struct {
	ID      uuid.UUID `json:"id"`
	Email   string    `json:"email"`
	Role    string    `json:"role"`
	IsOwner bool      `json:"is_owner"`
}

type SessionStatus string

const (
	StatusUnlinked     SessionStatus = "unlinked"
	StatusPairing      SessionStatus = "pairing"
	StatusConnecting   SessionStatus = "connecting"
	StatusConnected    SessionStatus = "connected"
	StatusReconnecting SessionStatus = "reconnecting"
	StatusPaused       SessionStatus = "paused"
	StatusInterrupted  SessionStatus = "interrupted"
	StatusLoggedOut    SessionStatus = "logged_out"
)

type Session struct {
	ID                   uuid.UUID     `json:"id"`
	UserID               uuid.UUID     `json:"user_id"`
	PhoneNumber          *string       `json:"phone_number"`
	Status               SessionStatus `json:"status"`
	CaptureEnabled       bool          `json:"capture_enabled"`
	IncludeMedia         bool          `json:"include_media"`
	LinkedAt             *time.Time    `json:"linked_at"`
	LastConnectedAt      *time.Time    `json:"last_connected_at"`
	LastMessageAt        *time.Time    `json:"last_message_at"`
	LastSynchronisedAt   *time.Time    `json:"last_synchronised_at"`
	LastError            *string       `json:"last_error"`
	SelectedGroupCount   int           `json:"selected_group_count"`
	CapturedMessageCount int64         `json:"captured_message_count"`

	DeviceJID            *string    `json:"-"`
	SelectionFinalisedAt *time.Time `json:"-"`
}

func (session Session) IsLinked() bool {
	return session.LinkedAt != nil && session.DeviceJID != nil && session.Status != StatusLoggedOut
}

type PairingCode struct {
	Session   Session   `json:"session"`
	Code      string    `json:"code"`
	ExpiresAt time.Time `json:"expires_at"`
}

type Group struct {
	JID                     string           `json:"jid"`
	Name                    string           `json:"name"`
	ParticipantCount        int              `json:"participant_count"`
	IsSelected              bool             `json:"is_selected"`
	LastMessageAt           *time.Time       `json:"last_message_at"`
	HistorySyncState        HistorySyncState `json:"history_sync_state"`
	HistoryTextMessageCount int64            `json:"history_text_message_count"`
	HistoryBatchCount       int              `json:"history_batch_count"`
	HistoryRequestCount     int              `json:"history_request_count"`
	HistorySyncStartedAt    *time.Time       `json:"history_sync_started_at"`
	HistorySyncUpdatedAt    *time.Time       `json:"history_sync_updated_at"`
	HistorySyncCompletedAt  *time.Time       `json:"history_sync_completed_at"`
	HistoryOldestMessageAt  *time.Time       `json:"history_oldest_message_at"`
	HistorySyncLastError    *string          `json:"history_sync_last_error"`
}

type HistorySyncState string

const (
	HistorySyncIdle             HistorySyncState = "idle"
	HistorySyncQueued           HistorySyncState = "queued"
	HistorySyncWaitingForAnchor HistorySyncState = "waiting_for_anchor"
	HistorySyncRequesting       HistorySyncState = "requesting"
	HistorySyncReceiving        HistorySyncState = "receiving"
	HistorySyncComplete         HistorySyncState = "complete"
	HistorySyncStalled          HistorySyncState = "stalled"
	HistorySyncFailed           HistorySyncState = "failed"
)

type HistoryAnchor struct {
	GroupJID          string
	WhatsAppMessageID string
	Timestamp         time.Time
	IsFromMe          bool
}

type MessageType string

const (
	MessageText     MessageType = "text"
	MessageImage    MessageType = "image"
	MessageVideo    MessageType = "video"
	MessageAudio    MessageType = "audio"
	MessageDocument MessageType = "document"
	MessageSticker  MessageType = "sticker"
	MessageContact  MessageType = "contact"
	MessageLocation MessageType = "location"
	MessagePoll     MessageType = "poll"
	MessageReaction MessageType = "reaction"
	MessageSystem   MessageType = "system"
	MessageUnknown  MessageType = "unknown"
)

type CapturedMessage struct {
	ID                uuid.UUID      `json:"id"`
	WhatsAppMessageID string         `json:"whatsapp_message_id"`
	GroupJID          string         `json:"group_jid"`
	GroupName         string         `json:"group_name"`
	SenderJID         string         `json:"sender_jid"`
	Sender            string         `json:"sender"`
	Body              string         `json:"body"`
	Type              MessageType    `json:"type"`
	Timestamp         time.Time      `json:"timestamp"`
	IsFromMe          bool           `json:"is_from_me"`
	HasMedia          bool           `json:"has_media"`
	IsEdited          bool           `json:"is_edited"`
	IsRevoked         bool           `json:"is_revoked"`
	Revision          int            `json:"revision"`
	MediaMetadata     *MediaMetadata `json:"media_metadata"`
	IngestionStatus   string         `json:"ingestion_status"`
	UploadSessionID   *uuid.UUID     `json:"upload_session_id"`
	IngestionQueuedAt *time.Time     `json:"ingestion_queued_at"`
}

type MediaMetadata struct {
	MIMEType        string `json:"mime_type,omitempty"`
	FileName        string `json:"file_name,omitempty"`
	FileSizeBytes   int64  `json:"file_size_bytes,omitempty"`
	Width           int    `json:"width,omitempty"`
	Height          int    `json:"height,omitempty"`
	DurationSeconds int    `json:"duration_seconds,omitempty"`
	PageCount       int    `json:"page_count,omitempty"`
	IsAnimated      bool   `json:"is_animated,omitempty"`
	IsVoiceMessage  bool   `json:"is_voice_message,omitempty"`
}

func (metadata MediaMetadata) IsEmpty() bool {
	return metadata == (MediaMetadata{})
}

type EventKind string

const (
	EventCaptured     EventKind = "Captured"
	EventSynchronised EventKind = "Synchronised"
	EventWarning      EventKind = "Needs attention"
)

type CaptureEvent struct {
	ID        uuid.UUID `json:"id"`
	GroupName string    `json:"group_name"`
	Detail    string    `json:"detail"`
	CreatedAt time.Time `json:"created_at"`
	Kind      EventKind `json:"kind"`
}

type Dashboard struct {
	Session  Session           `json:"session"`
	Groups   []Group           `json:"groups"`
	Events   []CaptureEvent    `json:"events"`
	Messages []CapturedMessage `json:"messages"`
}

type CursorPage[T any] struct {
	Items      []T     `json:"items"`
	NextCursor *string `json:"next_cursor"`
}

type IncomingMessage struct {
	SessionID         uuid.UUID
	WhatsAppMessageID string
	GroupJID          string
	SenderJID         string
	SenderName        string
	Body              string
	Type              MessageType
	Timestamp         time.Time
	IsFromMe          bool
	HasMedia          bool
	IsEdit            bool
	IsRevoke          bool
	MediaMetadata     MediaMetadata
	RawMetadata       map[string]any
}
