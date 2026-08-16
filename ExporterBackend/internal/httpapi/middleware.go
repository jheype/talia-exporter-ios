package httpapi

import (
	"crypto/rand"
	"encoding/hex"
	"log/slog"
	"net/http"
	"runtime/debug"
	"strings"
	"time"
)

func commonMiddleware(logger *slog.Logger, next http.Handler) http.Handler {
	return http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		requestID := strings.TrimSpace(request.Header.Get("X-Request-ID"))
		if requestID == "" || len(requestID) > 128 {
			requestID = newRequestID()
		}
		writer.Header().Set("X-Request-ID", requestID)
		writer.Header().Set("X-Content-Type-Options", "nosniff")
		writer.Header().Set("Referrer-Policy", "no-referrer")
		writer.Header().Set("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")
		writer.Header().Set("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
		request.Header.Set("X-Request-ID", requestID)

		started := time.Now()
		defer func() {
			if recovered := recover(); recovered != nil {
				logger.Error(
					"panic while serving exporter request",
					"request_id", requestID,
					"panic", recovered,
					"stack", string(debug.Stack()),
				)
				writeJSON(writer, http.StatusInternalServerError, errorEnvelope{
					Detail: errorDetail{Code: "EXPORTER.INTERNAL", Message: "The exporter could not complete the request."},
				})
			}
			logger.Info(
				"exporter request",
				"request_id", requestID,
				"method", request.Method,
				"path", request.URL.Path,
				"duration_ms", time.Since(started).Milliseconds(),
			)
		}()

		next.ServeHTTP(writer, request)
	})
}

func requireClient(allowed string, next http.Handler) http.Handler {
	allowedClients := make(map[string]struct{})
	for _, value := range strings.Split(allowed, ",") {
		if value = strings.TrimSpace(value); value != "" {
			allowedClients[value] = struct{}{}
		}
	}
	return http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.Method == http.MethodGet || request.Method == http.MethodHead || request.Method == http.MethodOptions {
			next.ServeHTTP(writer, request)
			return
		}
		if _, valid := allowedClients[request.Header.Get("X-Talia-Client")]; !valid {
			writeJSON(writer, http.StatusForbidden, errorEnvelope{
				Detail: errorDetail{Code: "REQUEST.CLIENT_REQUIRED", Message: "This request is not permitted."},
			})
			return
		}
		next.ServeHTTP(writer, request)
	})
}

func limitBody(next http.Handler) http.Handler {
	return http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		request.Body = http.MaxBytesReader(writer, request.Body, 64<<10)
		next.ServeHTTP(writer, request)
	})
}

func newRequestID() string {
	random := make([]byte, 16)
	if _, err := rand.Read(random); err != nil {
		return time.Now().UTC().Format("20060102T150405.000000000")
	}
	return hex.EncodeToString(random)
}
