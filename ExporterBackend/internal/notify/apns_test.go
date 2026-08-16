package notify

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/google/uuid"
)

type tokenRepositoryStub struct {
	mu      sync.Mutex
	tokens  []string
	deleted []string
}

func (repository *tokenRepositoryStub) DeviceTokens(context.Context, uuid.UUID) ([]string, error) {
	repository.mu.Lock()
	defer repository.mu.Unlock()
	return append([]string(nil), repository.tokens...), nil
}

func (repository *tokenRepositoryStub) DeleteDeviceToken(_ context.Context, _ uuid.UUID, token string) error {
	repository.mu.Lock()
	defer repository.mu.Unlock()
	repository.deleted = append(repository.deleted, token)
	return nil
}

func TestAPNsSenderSendsSignedAlert(t *testing.T) {
	t.Parallel()
	privateKey, keyPath := writeTestKey(t)
	token := strings.Repeat("ab", 32)
	repository := &tokenRepositoryStub{tokens: []string{token}}

	var received map[string]any
	server := httptest.NewTLSServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/3/device/"+token {
			t.Errorf("path = %q", request.URL.Path)
		}
		if request.Header.Get("apns-topic") != "com.talia.exporter" {
			t.Errorf("apns-topic = %q", request.Header.Get("apns-topic"))
		}
		authorisation := strings.TrimPrefix(request.Header.Get("Authorization"), "bearer ")
		verifyProviderToken(t, authorisation, privateKey)
		if err := json.NewDecoder(request.Body).Decode(&received); err != nil {
			t.Errorf("decode payload: %v", err)
		}
		writer.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(server.Close)

	sender, err := NewAPNsSender(APNsOptions{
		KeyID:          "KEY123",
		TeamID:         "TEAM123",
		BundleID:       "com.talia.exporter",
		PrivateKeyPath: keyPath,
		Endpoint:       server.URL,
		HTTPClient:     server.Client(),
	}, repository)
	if err != nil {
		t.Fatalf("create APNs sender: %v", err)
	}
	if err := sender.SendInterruption(context.Background(), uuid.New(), "Capture needs attention", "Open the app."); err != nil {
		t.Fatalf("send notification: %v", err)
	}

	aps, ok := received["aps"].(map[string]any)
	if !ok {
		t.Fatalf("aps payload = %#v", received["aps"])
	}
	alert, ok := aps["alert"].(map[string]any)
	if !ok || alert["title"] != "Capture needs attention" || alert["body"] != "Open the app." {
		t.Fatalf("alert payload = %#v", aps["alert"])
	}
	if received["event"] != "whatsapp_session_interrupted" {
		t.Fatalf("event = %#v", received["event"])
	}
}

func TestAPNsSenderRemovesUnregisteredToken(t *testing.T) {
	t.Parallel()
	_, keyPath := writeTestKey(t)
	token := strings.Repeat("cd", 32)
	repository := &tokenRepositoryStub{tokens: []string{token}}

	server := httptest.NewTLSServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		writer.WriteHeader(http.StatusGone)
		_, _ = writer.Write([]byte(`{"reason":"Unregistered"}`))
	}))
	t.Cleanup(server.Close)

	sender, err := NewAPNsSender(APNsOptions{
		KeyID:          "KEY123",
		TeamID:         "TEAM123",
		BundleID:       "com.talia.exporter",
		PrivateKeyPath: keyPath,
		Endpoint:       server.URL,
		HTTPClient:     server.Client(),
	}, repository)
	if err != nil {
		t.Fatalf("create APNs sender: %v", err)
	}
	if err := sender.SendInterruption(context.Background(), uuid.New(), "Title", "Body"); err != nil {
		t.Fatalf("send notification: %v", err)
	}
	if len(repository.deleted) != 1 || repository.deleted[0] != token {
		t.Fatalf("deleted tokens = %#v", repository.deleted)
	}
}

func TestAPNsSenderRetriesExpiredProviderTokenOnce(t *testing.T) {
	t.Parallel()
	_, keyPath := writeTestKey(t)
	repository := &tokenRepositoryStub{tokens: []string{strings.Repeat("ef", 32)}}

	var mu sync.Mutex
	requests := 0
	server := httptest.NewTLSServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		mu.Lock()
		requests++
		current := requests
		mu.Unlock()
		if current == 1 {
			writer.Header().Set("Content-Type", "application/json")
			writer.WriteHeader(http.StatusForbidden)
			_, _ = writer.Write([]byte(`{"reason":"ExpiredProviderToken"}`))
			return
		}
		writer.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(server.Close)

	sender, err := NewAPNsSender(APNsOptions{
		KeyID:          "KEY123",
		TeamID:         "TEAM123",
		BundleID:       "com.talia.exporter",
		PrivateKeyPath: keyPath,
		Endpoint:       server.URL,
		HTTPClient:     server.Client(),
	}, repository)
	if err != nil {
		t.Fatalf("create APNs sender: %v", err)
	}
	if err := sender.SendInterruption(context.Background(), uuid.New(), "Title", "Body"); err != nil {
		t.Fatalf("send notification: %v", err)
	}
	if requests != 2 {
		t.Fatalf("requests = %d, want 2", requests)
	}
}

func writeTestKey(t *testing.T) (*ecdsa.PrivateKey, string) {
	t.Helper()
	privateKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	encoded, err := x509.MarshalPKCS8PrivateKey(privateKey)
	if err != nil {
		t.Fatalf("encode key: %v", err)
	}
	path := filepath.Join(t.TempDir(), "AuthKey.p8")
	contents := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: encoded})
	if err := os.WriteFile(path, contents, 0o600); err != nil {
		t.Fatalf("write key: %v", err)
	}
	return privateKey, path
}

func verifyProviderToken(t *testing.T, token string, publicKey *ecdsa.PrivateKey) {
	t.Helper()
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		t.Fatalf("provider token has %d parts", len(parts))
	}
	signature, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil || len(signature) != 64 {
		t.Fatalf("invalid provider token signature")
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	r := new(big.Int).SetBytes(signature[:32])
	s := new(big.Int).SetBytes(signature[32:])
	if !ecdsa.Verify(&publicKey.PublicKey, digest[:], r, s) {
		t.Fatalf("provider token signature does not verify")
	}
}
