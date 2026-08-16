package notify

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"
)

const (
	productionEndpoint = "https://api.push.apple.com"
	sandboxEndpoint    = "https://api.sandbox.push.apple.com"
	providerTokenTTL   = 45 * time.Minute
)

type APNsOptions struct {
	Environment    string
	KeyID          string
	TeamID         string
	BundleID       string
	PrivateKeyPath string
	Endpoint       string
	HTTPClient     *http.Client
}

type APNsSender struct {
	repository TokenRepository
	client     *http.Client
	endpoint   string
	keyID      string
	teamID     string
	bundleID   string
	privateKey *ecdsa.PrivateKey

	tokenMu        sync.Mutex
	providerToken  string
	tokenCreatedAt time.Time
}

type apnsResponse struct {
	Reason string `json:"reason"`
}

func NewAPNsSender(options APNsOptions, repository TokenRepository) (*APNsSender, error) {
	if repository == nil {
		return nil, errors.New("APNs token repository is required")
	}
	if strings.TrimSpace(options.KeyID) == "" ||
		strings.TrimSpace(options.TeamID) == "" ||
		strings.TrimSpace(options.BundleID) == "" {
		return nil, errors.New("APNs key ID, team ID and bundle ID are required")
	}
	privateKey, err := loadPrivateKey(options.PrivateKeyPath)
	if err != nil {
		return nil, err
	}
	endpoint := strings.TrimRight(options.Endpoint, "/")
	if endpoint == "" {
		endpoint = productionEndpoint
		if options.Environment == "sandbox" {
			endpoint = sandboxEndpoint
		}
	}
	parsedEndpoint, err := url.ParseRequestURI(endpoint)
	if err != nil {
		return nil, fmt.Errorf("invalid APNs endpoint: %w", err)
	}
	if parsedEndpoint.Scheme != "https" || parsedEndpoint.Host == "" {
		return nil, errors.New("APNs endpoint must be an absolute HTTPS URL")
	}

	client := options.HTTPClient
	if client == nil {
		transport := http.DefaultTransport.(*http.Transport).Clone()
		transport.ForceAttemptHTTP2 = true
		transport.TLSClientConfig = &tls.Config{MinVersion: tls.VersionTLS12}
		client = &http.Client{
			Transport: transport,
			Timeout:   15 * time.Second,
		}
	}
	return &APNsSender{
		repository: repository,
		client:     client,
		endpoint:   endpoint,
		keyID:      strings.TrimSpace(options.KeyID),
		teamID:     strings.TrimSpace(options.TeamID),
		bundleID:   strings.TrimSpace(options.BundleID),
		privateKey: privateKey,
	}, nil
}

func (sender *APNsSender) SendInterruption(
	ctx context.Context,
	userID uuid.UUID,
	title string,
	body string,
) error {
	tokens, err := sender.repository.DeviceTokens(ctx, userID)
	if err != nil {
		return fmt.Errorf("list APNs device tokens: %w", err)
	}
	if len(tokens) == 0 {
		return nil
	}

	payload, err := json.Marshal(map[string]any{
		"aps": map[string]any{
			"alert": map[string]string{
				"title": truncate(title, 80),
				"body":  truncate(body, 180),
			},
			"sound": "default",
		},
		"event": "whatsapp_session_interrupted",
	})
	if err != nil {
		return err
	}

	var failures []error
	for _, token := range tokens {
		if err := sender.send(ctx, userID, token, payload, true); err != nil {
			failures = append(failures, err)
		}
	}
	return errors.Join(failures...)
}

func (sender *APNsSender) send(
	ctx context.Context,
	userID uuid.UUID,
	deviceToken string,
	payload []byte,
	allowTokenRetry bool,
) error {
	providerToken, err := sender.currentProviderToken()
	if err != nil {
		return err
	}
	request, err := http.NewRequestWithContext(
		ctx,
		http.MethodPost,
		sender.endpoint+"/3/device/"+url.PathEscape(deviceToken),
		bytes.NewReader(payload),
	)
	if err != nil {
		return err
	}
	request.Header.Set("Authorization", "bearer "+providerToken)
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("apns-topic", sender.bundleID)
	request.Header.Set("apns-push-type", "alert")
	request.Header.Set("apns-priority", "10")
	request.Header.Set("apns-collapse-id", "talia-exporter-session")

	response, err := sender.client.Do(request)
	if err != nil {
		return fmt.Errorf("send APNs notification: %w", err)
	}
	defer response.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(response.Body, 8<<10))
	if response.StatusCode == http.StatusOK {
		return nil
	}

	var result apnsResponse
	_ = json.Unmarshal(body, &result)
	if response.StatusCode == http.StatusGone || result.Reason == "BadDeviceToken" || result.Reason == "Unregistered" {
		return sender.repository.DeleteDeviceToken(ctx, userID, deviceToken)
	}
	if allowTokenRetry && response.StatusCode == http.StatusForbidden && result.Reason == "ExpiredProviderToken" {
		sender.invalidateProviderToken()
		return sender.send(ctx, userID, deviceToken, payload, false)
	}
	return fmt.Errorf("APNs rejected notification: status=%d reason=%s", response.StatusCode, result.Reason)
}

func (sender *APNsSender) currentProviderToken() (string, error) {
	sender.tokenMu.Lock()
	defer sender.tokenMu.Unlock()
	if sender.providerToken != "" && time.Since(sender.tokenCreatedAt) < providerTokenTTL {
		return sender.providerToken, nil
	}

	now := time.Now().UTC()
	header, err := json.Marshal(map[string]string{"alg": "ES256", "kid": sender.keyID})
	if err != nil {
		return "", err
	}
	claims, err := json.Marshal(map[string]any{"iss": sender.teamID, "iat": now.Unix()})
	if err != nil {
		return "", err
	}
	unsigned := base64.RawURLEncoding.EncodeToString(header) + "." +
		base64.RawURLEncoding.EncodeToString(claims)
	digest := sha256.Sum256([]byte(unsigned))
	r, s, err := ecdsa.Sign(rand.Reader, sender.privateKey, digest[:])
	if err != nil {
		return "", fmt.Errorf("sign APNs provider token: %w", err)
	}
	signature := make([]byte, 64)
	r.FillBytes(signature[:32])
	s.FillBytes(signature[32:])

	sender.providerToken = unsigned + "." + base64.RawURLEncoding.EncodeToString(signature)
	sender.tokenCreatedAt = now
	return sender.providerToken, nil
}

func (sender *APNsSender) invalidateProviderToken() {
	sender.tokenMu.Lock()
	sender.providerToken = ""
	sender.tokenCreatedAt = time.Time{}
	sender.tokenMu.Unlock()
}

func loadPrivateKey(path string) (*ecdsa.PrivateKey, error) {
	contents, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read APNs private key: %w", err)
	}
	block, _ := pem.Decode(contents)
	if block == nil {
		return nil, errors.New("APNs private key is not valid PEM")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("parse APNs private key: %w", err)
	}
	privateKey, ok := parsed.(*ecdsa.PrivateKey)
	if !ok || privateKey.Curve != elliptic.P256() {
		return nil, errors.New("APNs private key must be an ES256 key")
	}
	return privateKey, nil
}

func truncate(value string, maximum int) string {
	if utf8.RuneCountInString(value) <= maximum {
		return value
	}
	runes := []rune(value)
	return string(runes[:maximum-1]) + "…"
}
