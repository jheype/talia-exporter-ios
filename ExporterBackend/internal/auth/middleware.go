package auth

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/talia/exporter/internal/domain"
)

type contextKey struct{}

type Verifier struct {
	authMeURL string
	client    *http.Client
	logger    *slog.Logger
}

func NewVerifier(authMeURL string, timeout time.Duration, logger *slog.Logger) *Verifier {
	return &Verifier{
		authMeURL: authMeURL,
		client: &http.Client{
			Timeout: timeout,
			CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
				return http.ErrUseLastResponse
			},
		},
		logger: logger,
	}
}

func (verifier *Verifier) Middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		user, err := verifier.verify(request)
		if err != nil {
			status := http.StatusUnauthorized
			code := "AUTH.UNAUTHENTICATED"
			message := "Your session has expired. Please sign in again."
			if errors.Is(err, errIdentityUnavailable) {
				status = http.StatusServiceUnavailable
				code = "AUTH.UNAVAILABLE"
				message = "Authentication is temporarily unavailable."
			}
			writeError(writer, status, code, message)
			return
		}

		ctx := context.WithValue(request.Context(), contextKey{}, user)
		next.ServeHTTP(writer, request.WithContext(ctx))
	})
}

func UserFromContext(ctx context.Context) (domain.User, bool) {
	user, ok := ctx.Value(contextKey{}).(domain.User)
	return user, ok
}

var errIdentityUnavailable = errors.New("identity service unavailable")

func (verifier *Verifier) verify(request *http.Request) (domain.User, error) {
	upstream, err := http.NewRequestWithContext(request.Context(), http.MethodGet, verifier.authMeURL, nil)
	if err != nil {
		return domain.User{}, errIdentityUnavailable
	}
	if cookie := request.Header.Get("Cookie"); cookie != "" {
		upstream.Header.Set("Cookie", cookie)
	}
	if authorization := request.Header.Get("Authorization"); authorization != "" {
		upstream.Header.Set("Authorization", authorization)
	}
	upstream.Header.Set("Accept", "application/json")
	upstream.Header.Set("X-Talia-Internal-Request", "exporter")
	if requestID := request.Header.Get("X-Request-ID"); requestID != "" {
		upstream.Header.Set("X-Request-ID", requestID)
	}

	response, err := verifier.client.Do(upstream)
	if err != nil {
		verifier.logger.Error("v14 identity request failed", "error", err)
		return domain.User{}, errIdentityUnavailable
	}
	defer response.Body.Close()

	if response.StatusCode == http.StatusUnauthorized || response.StatusCode == http.StatusForbidden {
		return domain.User{}, errors.New("unauthenticated")
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		verifier.logger.Error("v14 identity returned unexpected status", "status", response.StatusCode)
		return domain.User{}, errIdentityUnavailable
	}

	var payload struct {
		ID      uuid.UUID `json:"id"`
		Email   string    `json:"email"`
		Role    string    `json:"role"`
		IsOwner bool      `json:"is_owner"`
		User    *struct {
			ID      uuid.UUID `json:"id"`
			Email   string    `json:"email"`
			Role    string    `json:"role"`
			IsOwner bool      `json:"is_owner"`
		} `json:"user"`
	}
	decoder := json.NewDecoder(io.LimitReader(response.Body, 1<<20))
	if err := decoder.Decode(&payload); err != nil {
		verifier.logger.Error("v14 identity returned invalid JSON", "error", err)
		return domain.User{}, errIdentityUnavailable
	}
	if payload.User != nil {
		payload.ID = payload.User.ID
		payload.Email = payload.User.Email
		payload.Role = payload.User.Role
		payload.IsOwner = payload.User.IsOwner
	}
	if payload.ID == uuid.Nil || strings.TrimSpace(payload.Email) == "" {
		return domain.User{}, errIdentityUnavailable
	}
	return domain.User{
		ID:      payload.ID,
		Email:   payload.Email,
		Role:    payload.Role,
		IsOwner: payload.IsOwner,
	}, nil
}

func writeError(writer http.ResponseWriter, status int, code, message string) {
	writer.Header().Set("Content-Type", "application/json; charset=utf-8")
	writer.Header().Set("Cache-Control", "no-store")
	writer.WriteHeader(status)
	_ = json.NewEncoder(writer).Encode(map[string]any{
		"detail": map[string]string{
			"code":    code,
			"message": message,
		},
	})
}
