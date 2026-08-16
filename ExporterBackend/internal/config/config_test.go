package config

import (
	"strings"
	"testing"
)

func TestLoadAllowsAPNsToRemainDisabled(t *testing.T) {
	setRequiredEnvironment(t)

	settings, err := Load()
	if err != nil {
		t.Fatalf("load configuration: %v", err)
	}
	if settings.APNsEnabled() {
		t.Fatal("APNs should be disabled without signing credentials")
	}
	if settings.APNsBundleID != "com.talia.exporter" {
		t.Fatalf("bundle ID = %q", settings.APNsBundleID)
	}
}

func TestLoadRejectsPartialAPNsConfiguration(t *testing.T) {
	setRequiredEnvironment(t)
	t.Setenv("APNS_KEY_ID", "KEY123")

	_, err := Load()
	if err == nil || !strings.Contains(err.Error(), "APNs requires") {
		t.Fatalf("error = %v", err)
	}
}

func TestLoadEnablesCompleteAPNsConfiguration(t *testing.T) {
	setRequiredEnvironment(t)
	t.Setenv("APNS_KEY_ID", "KEY123")
	t.Setenv("APNS_TEAM_ID", "TEAM123")
	t.Setenv("APNS_PRIVATE_KEY_PATH", "/run/secrets/apns.p8")

	settings, err := Load()
	if err != nil {
		t.Fatalf("load configuration: %v", err)
	}
	if !settings.APNsEnabled() {
		t.Fatal("APNs should be enabled with complete signing credentials")
	}
}

func TestLoadRejectsInvalidDuration(t *testing.T) {
	setRequiredEnvironment(t)
	t.Setenv("AUTH_TIMEOUT", "eventually")

	_, err := Load()
	if err == nil || !strings.Contains(err.Error(), "AUTH_TIMEOUT") {
		t.Fatalf("error = %v", err)
	}
}

func setRequiredEnvironment(t *testing.T) {
	t.Helper()
	t.Setenv("DATABASE_URL", "postgres://talia:talia@postgres/talia")
	t.Setenv("V14_AUTH_ME_URL", "https://app.taliaai.com/api/auth/me")
	t.Setenv("AUTH_TIMEOUT", "")
	t.Setenv("SHUTDOWN_TIMEOUT", "")
	t.Setenv("SESSION_RECONCILE_INTERVAL", "")
	t.Setenv("PAIRING_CODE_LIFETIME", "")
	t.Setenv("PENDING_HISTORY_RETENTION", "")
	t.Setenv("APNS_ENVIRONMENT", "production")
	t.Setenv("APNS_KEY_ID", "")
	t.Setenv("APNS_TEAM_ID", "")
	t.Setenv("APNS_BUNDLE_ID", "")
	t.Setenv("APNS_PRIVATE_KEY_PATH", "")
}
