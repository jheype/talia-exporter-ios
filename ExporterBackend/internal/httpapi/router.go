package httpapi

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"time"

	"github.com/talia/exporter/internal/auth"
	"github.com/talia/exporter/internal/store"
	"github.com/talia/exporter/internal/whatsapp"
)

func NewRouter(
	repository store.Repository,
	whatsApp whatsapp.Service,
	authVerifier *auth.Verifier,
	allowedClient string,
	logger *slog.Logger,
) http.Handler {
	handler := &handlers{repository: repository, whatsapp: whatsApp, logger: logger}

	api := http.NewServeMux()
	api.HandleFunc("GET /api/v1/exporter/dashboard", handler.dashboard)
	api.HandleFunc("GET /api/v1/exporter/session", handler.session)
	api.HandleFunc("POST /api/v1/exporter/session/pair", handler.pair)
	api.HandleFunc("PUT /api/v1/exporter/session/capture", handler.setCapture)
	api.HandleFunc("PUT /api/v1/exporter/session/preferences", handler.setPreferences)
	api.HandleFunc("DELETE /api/v1/exporter/session", handler.unlink)
	api.HandleFunc("GET /api/v1/exporter/groups", handler.groups)
	api.HandleFunc("PUT /api/v1/exporter/groups/selection", handler.saveSelection)
	api.HandleFunc("GET /api/v1/exporter/messages", handler.messages)
	api.HandleFunc("GET /api/v1/exporter/events", handler.events)
	api.HandleFunc("POST /api/v1/exporter/devices", handler.registerDevice)
	api.HandleFunc("DELETE /api/v1/exporter/devices", handler.deleteDevices)

	protected := authVerifier.Middleware(requireClient(allowedClient, limitBody(api)))
	root := http.NewServeMux()
	root.Handle("/api/v1/exporter/", protected)
	root.HandleFunc("GET /health/live", func(writer http.ResponseWriter, _ *http.Request) {
		writeJSON(writer, http.StatusOK, map[string]string{"status": "ok"})
	})
	root.HandleFunc("GET /health/ready", func(writer http.ResponseWriter, request *http.Request) {
		ctx, cancel := requestContext(request, 2*time.Second)
		defer cancel()
		if err := repository.Ping(ctx); err != nil {
			writeJSON(writer, http.StatusServiceUnavailable, map[string]string{"status": "unavailable"})
			return
		}
		writeJSON(writer, http.StatusOK, map[string]string{"status": "ready"})
	})
	root.HandleFunc("/", func(writer http.ResponseWriter, _ *http.Request) {
		writer.Header().Set("Content-Type", "application/json; charset=utf-8")
		writer.WriteHeader(http.StatusNotFound)
		_ = json.NewEncoder(writer).Encode(errorEnvelope{
			Detail: errorDetail{Code: "HTTP.NOT_FOUND", Message: "The requested endpoint was not found."},
		})
	})
	return commonMiddleware(logger, root)
}

func requestContext(request *http.Request, timeout time.Duration) (context.Context, context.CancelFunc) {
	return context.WithTimeout(request.Context(), timeout)
}
