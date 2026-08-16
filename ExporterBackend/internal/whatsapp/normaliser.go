package whatsapp

import (
	"fmt"
	"math"
	"strings"

	"github.com/google/uuid"
	"github.com/talia/exporter/internal/domain"
	waE2E "go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/types/events"
)

func normaliseMessage(sessionID uuid.UUID, event *events.Message, history bool) (domain.IncomingMessage, bool) {
	if event == nil || event.Message == nil || !event.Info.IsGroup {
		return domain.IncomingMessage{}, false
	}
	if event.Info.ID == "" || event.Info.Chat.IsEmpty() {
		return domain.IncomingMessage{}, false
	}

	messageType, body, hasMedia, mediaMetadata := content(event)
	messageID := string(event.Info.ID)
	isRevoke := false
	if protocolMessage := event.Message.GetProtocolMessage(); protocolMessage != nil && protocolMessage.GetType() == waE2E.ProtocolMessage_REVOKE {
		if targetID := strings.TrimSpace(protocolMessage.GetKey().GetID()); targetID != "" {
			messageID = targetID
			isRevoke = true
			body = ""
			messageType = domain.MessageSystem
			hasMedia = false
			mediaMetadata = domain.MediaMetadata{}
		}
	}
	senderName := strings.TrimSpace(event.Info.PushName)
	if senderName == "" {
		senderName = event.Info.Sender.User
	}

	timestamp := event.Info.Timestamp
	if timestamp.IsZero() {
		return domain.IncomingMessage{}, false
	}

	return domain.IncomingMessage{
		SessionID:         sessionID,
		WhatsAppMessageID: messageID,
		GroupJID:          event.Info.Chat.String(),
		SenderJID:         event.Info.Sender.String(),
		SenderName:        senderName,
		Body:              body,
		Type:              messageType,
		Timestamp:         timestamp,
		IsFromMe:          event.Info.IsFromMe,
		HasMedia:          hasMedia,
		IsEdit:            event.IsEdit,
		IsRevoke:          isRevoke,
		MediaMetadata:     mediaMetadata,
		RawMetadata: map[string]any{
			"whatsapp_type": event.Info.Type,
			"media_type":    event.Info.MediaType,
			"category":      event.Info.Category,
			"history_sync":  history,
			"ephemeral":     event.IsEphemeral,
			"view_once":     event.IsViewOnce,
		},
	}, true
}

func content(event *events.Message) (domain.MessageType, string, bool, domain.MediaMetadata) {
	message := event.Message
	if text := strings.TrimSpace(message.GetConversation()); text != "" {
		return domain.MessageText, text, false, domain.MediaMetadata{}
	}
	if extended := message.GetExtendedTextMessage(); extended != nil {
		return domain.MessageText, extended.GetText(), false, domain.MediaMetadata{}
	}
	if image := message.GetImageMessage(); image != nil {
		return domain.MessageImage, image.GetCaption(), true, domain.MediaMetadata{
			MIMEType:      image.GetMimetype(),
			FileSizeBytes: fileSize(image.GetFileLength()),
			Width:         int(image.GetWidth()),
			Height:        int(image.GetHeight()),
		}
	}
	if video := message.GetVideoMessage(); video != nil {
		return domain.MessageVideo, video.GetCaption(), true, domain.MediaMetadata{
			MIMEType:        video.GetMimetype(),
			FileSizeBytes:   fileSize(video.GetFileLength()),
			Width:           int(video.GetWidth()),
			Height:          int(video.GetHeight()),
			DurationSeconds: int(video.GetSeconds()),
			IsAnimated:      video.GetGifPlayback(),
		}
	}
	if audio := message.GetAudioMessage(); audio != nil {
		return domain.MessageAudio, "", true, domain.MediaMetadata{
			MIMEType:        audio.GetMimetype(),
			FileSizeBytes:   fileSize(audio.GetFileLength()),
			DurationSeconds: int(audio.GetSeconds()),
			IsVoiceMessage:  audio.GetPTT(),
		}
	}
	if document := message.GetDocumentMessage(); document != nil {
		body := strings.TrimSpace(document.GetCaption())
		if body == "" {
			body = document.GetFileName()
		}
		return domain.MessageDocument, body, true, domain.MediaMetadata{
			MIMEType:      document.GetMimetype(),
			FileName:      document.GetFileName(),
			FileSizeBytes: fileSize(document.GetFileLength()),
			PageCount:     int(document.GetPageCount()),
		}
	}
	if sticker := message.GetStickerMessage(); sticker != nil {
		return domain.MessageSticker, "", true, domain.MediaMetadata{
			MIMEType:      sticker.GetMimetype(),
			FileSizeBytes: fileSize(sticker.GetFileLength()),
			Width:         int(sticker.GetWidth()),
			Height:        int(sticker.GetHeight()),
			IsAnimated:    sticker.GetIsAnimated(),
		}
	}
	if contact := message.GetContactMessage(); contact != nil {
		return domain.MessageContact, contact.GetDisplayName(), false, domain.MediaMetadata{}
	}
	if location := message.GetLocationMessage(); location != nil {
		body := strings.TrimSpace(location.GetName())
		if body == "" {
			body = fmt.Sprintf("%.6f, %.6f", location.GetDegreesLatitude(), location.GetDegreesLongitude())
		}
		return domain.MessageLocation, body, false, domain.MediaMetadata{}
	}
	if poll := message.GetPollCreationMessage(); poll != nil {
		return domain.MessagePoll, poll.GetName(), false, domain.MediaMetadata{}
	}
	if message.GetPollUpdateMessage() != nil {
		return domain.MessagePoll, "", false, domain.MediaMetadata{}
	}
	if reaction := message.GetReactionMessage(); reaction != nil {
		return domain.MessageReaction, reaction.GetText(), false, domain.MediaMetadata{}
	}
	if message.GetProtocolMessage() != nil {
		return domain.MessageSystem, "", false, domain.MediaMetadata{}
	}
	return domain.MessageUnknown, "", false, domain.MediaMetadata{}
}

func fileSize(value uint64) int64 {
	if value > math.MaxInt64 {
		return math.MaxInt64
	}
	return int64(value)
}
