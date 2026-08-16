package config

import (
	"errors"
	"fmt"
	"net/url"
	"os"
	"strings"
	"time"
)

type Config struct {
	Environment              string
	HTTPAddress              string
	DatabaseURL              string
	V14AuthMeURL             string
	AllowedClient            string
	LogLevel                 string
	AuthTimeout              time.Duration
	ShutdownTimeout          time.Duration
	SessionReconcileInterval time.Duration
	PairingCodeLifetime      time.Duration
	PendingHistoryRetention  time.Duration
	APNsEnvironment          string
	APNsKeyID                string
	APNsTeamID               string
	APNsBundleID             string
	APNsPrivateKeyPath       string
}

func Load() (Config, error) {
	authTimeout, err := duration("AUTH_TIMEOUT", 5*time.Second)
	if err != nil {
		return Config{}, err
	}
	shutdownTimeout, err := duration("SHUTDOWN_TIMEOUT", 20*time.Second)
	if err != nil {
		return Config{}, err
	}
	reconcileInterval, err := duration("SESSION_RECONCILE_INTERVAL", 15*time.Second)
	if err != nil {
		return Config{}, err
	}
	pairingLifetime, err := duration("PAIRING_CODE_LIFETIME", 150*time.Second)
	if err != nil {
		return Config{}, err
	}
	pendingHistoryRetention, err := duration("PENDING_HISTORY_RETENTION", 24*time.Hour)
	if err != nil {
		return Config{}, err
	}

	config := Config{
		Environment:              value("APP_ENV", "development"),
		HTTPAddress:              value("HTTP_ADDRESS", ":8080"),
		DatabaseURL:              strings.TrimSpace(os.Getenv("DATABASE_URL")),
		V14AuthMeURL:             strings.TrimSpace(os.Getenv("V14_AUTH_ME_URL")),
		AllowedClient:            value("ALLOWED_CLIENT", "ios"),
		LogLevel:                 value("LOG_LEVEL", "info"),
		AuthTimeout:              authTimeout,
		ShutdownTimeout:          shutdownTimeout,
		SessionReconcileInterval: reconcileInterval,
		PairingCodeLifetime:      pairingLifetime,
		PendingHistoryRetention:  pendingHistoryRetention,
		APNsEnvironment:          value("APNS_ENVIRONMENT", "production"),
		APNsKeyID:                strings.TrimSpace(os.Getenv("APNS_KEY_ID")),
		APNsTeamID:               strings.TrimSpace(os.Getenv("APNS_TEAM_ID")),
		APNsBundleID:             value("APNS_BUNDLE_ID", "com.talia.exporter"),
		APNsPrivateKeyPath:       strings.TrimSpace(os.Getenv("APNS_PRIVATE_KEY_PATH")),
	}

	var missing []string
	if config.DatabaseURL == "" {
		missing = append(missing, "DATABASE_URL")
	}
	if config.V14AuthMeURL == "" {
		missing = append(missing, "V14_AUTH_ME_URL")
	}
	if len(missing) > 0 {
		return Config{}, fmt.Errorf("missing required environment variables: %s", strings.Join(missing, ", "))
	}
	identityURL, err := url.Parse(config.V14AuthMeURL)
	if err != nil || identityURL.Host == "" || (identityURL.Scheme != "http" && identityURL.Scheme != "https") {
		return Config{}, errors.New("V14_AUTH_ME_URL must be an absolute HTTP or HTTPS URL")
	}
	if config.PairingCodeLifetime > 150*time.Second {
		return Config{}, errors.New("PAIRING_CODE_LIFETIME must not exceed 150s")
	}
	configuredAPNsValues := 0
	for _, candidate := range []string{
		config.APNsKeyID,
		config.APNsTeamID,
		config.APNsPrivateKeyPath,
	} {
		if candidate != "" {
			configuredAPNsValues++
		}
	}
	if configuredAPNsValues != 0 && configuredAPNsValues != 3 {
		return Config{}, errors.New("APNs requires APNS_KEY_ID, APNS_TEAM_ID, APNS_BUNDLE_ID and APNS_PRIVATE_KEY_PATH")
	}
	if config.APNsEnvironment != "production" && config.APNsEnvironment != "sandbox" {
		return Config{}, errors.New("APNS_ENVIRONMENT must be production or sandbox")
	}
	return config, nil
}

func (config Config) APNsEnabled() bool {
	return config.APNsKeyID != ""
}

func value(key, fallback string) string {
	if result := strings.TrimSpace(os.Getenv(key)); result != "" {
		return result
	}
	return fallback
}

func duration(key string, fallback time.Duration) (time.Duration, error) {
	raw := strings.TrimSpace(os.Getenv(key))
	if raw == "" {
		return fallback, nil
	}
	parsed, err := time.ParseDuration(raw)
	if err != nil {
		return 0, fmt.Errorf("%s must be a valid duration: %w", key, err)
	}
	if parsed <= 0 {
		return 0, fmt.Errorf("%s must be greater than zero", key)
	}
	return parsed, nil
}
