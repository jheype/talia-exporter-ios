package auth

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestVerifierForwardsSessionAndAddsUserToContext(t *testing.T) {
	t.Parallel()
	var calls atomic.Int32
	identity := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		calls.Add(1)
		if got := request.Header.Get("Cookie"); got != "access_token=secure-cookie" {
			t.Errorf("forwarded Cookie = %q", got)
		}
		writer.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(writer, `{
			"id":"b46ae31b-7c41-4682-86eb-557f373d0636",
			"email":"employee@taliaai.com",
			"role":"team_member",
			"is_owner":false,
			"security_console_available":false
		}`)
	}))
	defer identity.Close()

	verifier := NewVerifier(identity.URL, time.Second, slog.New(slog.NewTextHandler(io.Discard, nil)))
	next := http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		user, ok := UserFromContext(request.Context())
		if !ok {
			t.Fatal("authenticated user missing from context")
		}
		if user.ID != uuid.MustParse("b46ae31b-7c41-4682-86eb-557f373d0636") {
			t.Fatalf("user ID = %v", user.ID)
		}
		writer.WriteHeader(http.StatusNoContent)
	})

	request := httptest.NewRequest(http.MethodGet, "/api/v1/exporter/session", nil)
	request.Header.Set("Cookie", "access_token=secure-cookie")
	response := httptest.NewRecorder()
	verifier.Middleware(next).ServeHTTP(response, request)

	if response.Code != http.StatusNoContent {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusNoContent)
	}
	if calls.Load() != 1 {
		t.Fatalf("identity calls = %d, want 1", calls.Load())
	}
}

func TestVerifierRejectsExpiredSession(t *testing.T) {
	t.Parallel()
	identity := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		writer.WriteHeader(http.StatusUnauthorized)
	}))
	defer identity.Close()

	verifier := NewVerifier(identity.URL, time.Second, slog.New(slog.NewTextHandler(io.Discard, nil)))
	request := httptest.NewRequest(http.MethodGet, "/api/v1/exporter/session", nil)
	response := httptest.NewRecorder()
	verifier.Middleware(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		t.Fatal("next handler must not be called")
	})).ServeHTTP(response, request)

	if response.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusUnauthorized)
	}
}
