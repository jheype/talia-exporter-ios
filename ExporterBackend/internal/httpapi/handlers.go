package httpapi

import (
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"unicode"

	"github.com/talia/exporter/internal/auth"
	"github.com/talia/exporter/internal/domain"
	"github.com/talia/exporter/internal/store"
	"github.com/talia/exporter/internal/whatsapp"
)

type handlers struct {
	repository store.Repository
	whatsapp   whatsapp.Service
	logger     *slog.Logger
}

func (handler *handlers) session(writer http.ResponseWriter, request *http.Request) {
	user, _ := auth.UserFromContext(request.Context())
	session, err := handler.repository.SessionByUser(request.Context(), user.ID)
	if err != nil {
		writeAPIError(writer, handler.logger, err)
		return
	}
	writeJSON(writer, http.StatusOK, session)
}

func (handler *handlers) dashboard(writer http.ResponseWriter, request *http.Request) {
	user, _ := auth.UserFromContext(request.Context())
	dashboard, err := handler.repository.Dashboard(request.Context(), user.ID)
	if err != nil {
		writeAPIError(writer, handler.logger, err)
		return
	}
	writeJSON(writer, http.StatusOK, dashboard)
}

func (handler *handlers) pair(writer http.ResponseWriter, request *http.Request) {
	var input struct {
		PhoneNumber string `json:"phone_number"`
	}
	if err := decodeJSON(request, &input); err != nil {
		writeInvalidJSON(writer)
		return
	}
	phoneNumber, err := normalisePhone(input.PhoneNumber)
	if err != nil {
		writeAPIError(writer, handler.logger, err)
		return
	}

	user, _ := auth.UserFromContext(request.Context())
	pairingCode, err := handler.whatsapp.Pair(request.Context(), user.ID, phoneNumber)
	if err != nil {
		writeAPIError(writer, handler.logger, err)
		return
	}
	writeJSON(writer, http.StatusCreated, pairingCode)
}

func (handler *handlers) groups(writer http.ResponseWriter, request *http.Request) {
	user, _ := auth.UserFromContext(request.Context())
	groups, err := handler.whatsapp.SynchroniseGroups(request.Context(), user.ID)
	if err != nil {
		writeAPIError(writer, handler.logger, err)
		return
	}
	writeJSON(writer, http.StatusOK, groups)
}

func (handler *handlers) saveSelection(writer http.ResponseWriter, request *http.Request) {
	var input struct {
		GroupJIDs []string `json:"group_jids"`
	}
	if err := decodeJSON(request, &input); err != nil {
		writeInvalidJSON(writer)
		return
	}
	if len(input.GroupJIDs) > 2_000 {
		writeAPIError(writer, handler.logger, domain.ErrInvalidInput)
		return
	}

	user, _ := auth.UserFromContext(request.Context())
	session, err := handler.repository.SaveSelection(request.Context(), user.ID, input.GroupJIDs)
	if err != nil {
		writeAPIError(writer, handler.logger, err)
		return
	}
	writeJSON(writer, http.StatusOK, session)
}

func (handler *handlers) setCapture(writer http.ResponseWriter, request *http.Request) {
	var input struct {
		Enabled *bool `json:"enabled"`
	}
	if err := decodeJSON(request, &input); err != nil || input.Enabled == nil {
		writeInvalidJSON(writer)
		return
	}
	user, _ := auth.UserFromContext(request.Context())
	session, err := handler.repository.SetCaptureEnabled(request.Context(), user.ID, *input.Enabled)
	if err != nil {
		writeAPIError(writer, handler.logger, err)
		return
	}
	writeJSON(writer, http.StatusOK, session)
}

func (handler *handlers) setPreferences(writer http.ResponseWriter, request *http.Request) {
	var input struct {
		IncludeMedia *bool `json:"include_media"`
	}
	if err := decodeJSON(request, &input); err != nil || input.IncludeMedia == nil {
		writeInvalidJSON(writer)
		return
	}
	user, _ := auth.UserFromContext(request.Context())
	session, err := handler.repository.SetIncludeMedia(request.Context(), user.ID, *input.IncludeMedia)
	if err != nil {
		writeAPIError(writer, handler.logger, err)
		return
	}
	writeJSON(writer, http.StatusOK, session)
}

func (handler *handlers) unlink(writer http.ResponseWriter, request *http.Request) {
	user, _ := auth.UserFromContext(request.Context())
	if err := handler.whatsapp.Unlink(request.Context(), user.ID); err != nil {
		writeAPIError(writer, handler.logger, err)
		return
	}
	writer.WriteHeader(http.StatusNoContent)
}

func (handler *handlers) messages(writer http.ResponseWriter, request *http.Request) {
	user, _ := auth.UserFromContext(request.Context())
	session, err := handler.repository.SessionByUser(request.Context(), user.ID)
	if err != nil {
		writeAPIError(writer, handler.logger, err)
		return
	}
	page, err := handler.repository.Messages(
		request.Context(),
		session.ID,
		queryLimit(request),
		queryCursor(request),
	)
	if err != nil {
		writeAPIError(writer, handler.logger, err)
		return
	}
	writeJSON(writer, http.StatusOK, page)
}

func (handler *handlers) events(writer http.ResponseWriter, request *http.Request) {
	user, _ := auth.UserFromContext(request.Context())
	session, err := handler.repository.SessionByUser(request.Context(), user.ID)
	if err != nil {
		writeAPIError(writer, handler.logger, err)
		return
	}
	page, err := handler.repository.Events(
		request.Context(),
		session.ID,
		queryLimit(request),
		queryCursor(request),
	)
	if err != nil {
		writeAPIError(writer, handler.logger, err)
		return
	}
	writeJSON(writer, http.StatusOK, page)
}

func (handler *handlers) registerDevice(writer http.ResponseWriter, request *http.Request) {
	var input struct {
		Token    string `json:"token"`
		Platform string `json:"platform"`
	}
	if err := decodeJSON(request, &input); err != nil {
		writeInvalidJSON(writer)
		return
	}
	input.Token = strings.ToLower(strings.TrimSpace(input.Token))
	if input.Platform != "ios" || len(input.Token) != 64 {
		writeAPIError(writer, handler.logger, domain.ErrInvalidInput)
		return
	}
	if _, err := hex.DecodeString(input.Token); err != nil {
		writeAPIError(writer, handler.logger, domain.ErrInvalidInput)
		return
	}

	user, _ := auth.UserFromContext(request.Context())
	if err := handler.repository.RegisterDevice(request.Context(), user.ID, input.Platform, input.Token); err != nil {
		writeAPIError(writer, handler.logger, err)
		return
	}
	writer.WriteHeader(http.StatusNoContent)
}

func (handler *handlers) deleteDevices(writer http.ResponseWriter, request *http.Request) {
	user, _ := auth.UserFromContext(request.Context())
	if err := handler.repository.DeleteDevices(request.Context(), user.ID); err != nil {
		writeAPIError(writer, handler.logger, err)
		return
	}
	writer.WriteHeader(http.StatusNoContent)
}

func decodeJSON(request *http.Request, destination any) error {
	if mediaType := request.Header.Get("Content-Type"); !strings.HasPrefix(mediaType, "application/json") {
		return errors.New("Content-Type must be application/json")
	}
	decoder := json.NewDecoder(request.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(destination); err != nil {
		return err
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return errors.New("request must contain one JSON value")
	}
	return nil
}

func writeInvalidJSON(writer http.ResponseWriter) {
	writeJSON(writer, http.StatusBadRequest, errorEnvelope{
		Detail: errorDetail{Code: "REQUEST.INVALID_JSON", Message: "The request body is invalid."},
	})
}

func normalisePhone(value string) (string, error) {
	digits := strings.Builder{}
	for _, character := range value {
		switch {
		case unicode.IsDigit(character):
			digits.WriteRune(character)
		case unicode.IsSpace(character), character == '+', character == '-', character == '(', character == ')':
			continue
		default:
			return "", fmt.Errorf("%w: invalid phone number", domain.ErrInvalidInput)
		}
	}
	result := digits.String()
	if len(result) < 8 || len(result) > 15 || result[0] == '0' {
		return "", fmt.Errorf("%w: phone number must use international format", domain.ErrInvalidInput)
	}
	return "+" + result, nil
}

func queryLimit(request *http.Request) int {
	value, err := strconv.Atoi(request.URL.Query().Get("limit"))
	if err != nil {
		return 50
	}
	return value
}

func queryCursor(request *http.Request) *string {
	value := strings.TrimSpace(request.URL.Query().Get("cursor"))
	if value == "" {
		return nil
	}
	return &value
}
