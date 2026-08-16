package httpapi

import (
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"

	"github.com/talia/exporter/internal/domain"
)

type errorDetail struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type errorEnvelope struct {
	Detail errorDetail `json:"detail"`
}

func writeJSON(writer http.ResponseWriter, status int, value any) {
	writer.Header().Set("Content-Type", "application/json; charset=utf-8")
	writer.Header().Set("Cache-Control", "no-store")
	writer.WriteHeader(status)
	if value != nil {
		_ = json.NewEncoder(writer).Encode(value)
	}
}

func writeAPIError(writer http.ResponseWriter, logger *slog.Logger, err error) {
	status := http.StatusInternalServerError
	code := "EXPORTER.INTERNAL"
	message := "The exporter could not complete the request."

	switch {
	case errors.Is(err, domain.ErrNotFound):
		status = http.StatusNotFound
		code = "EXPORTER.NOT_FOUND"
		message = "The exporter session was not found."
	case errors.Is(err, domain.ErrNotLinked):
		status = http.StatusConflict
		code = "WHATSAPP.NOT_LINKED"
		message = "Link a WhatsApp account first."
	case errors.Is(err, domain.ErrPairingInProgress):
		status = http.StatusConflict
		code = "WHATSAPP.PAIRING_IN_PROGRESS"
		message = "A pairing request is already in progress."
	case errors.Is(err, domain.ErrConflict):
		status = http.StatusConflict
		code = "EXPORTER.CONFLICT"
		message = "Unlink the current WhatsApp account before linking another one."
	case errors.Is(err, domain.ErrInvalidInput):
		status = http.StatusUnprocessableEntity
		code = "REQUEST.INVALID"
		message = "Check the supplied values and try again."
	}

	if status >= 500 {
		logger.Error("exporter request failed", "error", err)
	}
	writeJSON(writer, status, errorEnvelope{Detail: errorDetail{Code: code, Message: message}})
}
