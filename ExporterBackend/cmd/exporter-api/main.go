package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/talia/exporter/internal/auth"
	"github.com/talia/exporter/internal/config"
	"github.com/talia/exporter/internal/httpapi"
	"github.com/talia/exporter/internal/notify"
	"github.com/talia/exporter/internal/store"
	"github.com/talia/exporter/internal/whatsapp"
	"github.com/talia/exporter/migrations"
)

func main() {
	settings, err := config.Load()
	if err != nil {
		slog.Error("load configuration", "error", err)
		os.Exit(1)
	}
	logger := newLogger(settings.LogLevel)
	slog.SetDefault(logger)

	rootContext, stopSignals := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stopSignals()

	repository, err := store.NewPostgres(rootContext, settings.DatabaseURL)
	if err != nil {
		logger.Error("open exporter database", "error", err)
		os.Exit(1)
	}
	defer repository.Close()
	if err := repository.Ping(rootContext); err != nil {
		logger.Error("connect to exporter database", "error", err)
		os.Exit(1)
	}
	if err := repository.Migrate(rootContext, migrations.All()); err != nil {
		logger.Error("migrate exporter database", "error", err)
		os.Exit(1)
	}

	var interruptionNotifier notify.Sender = notify.NoopSender{}
	if settings.APNsEnabled() {
		interruptionNotifier, err = notify.NewAPNsSender(notify.APNsOptions{
			Environment:    settings.APNsEnvironment,
			KeyID:          settings.APNsKeyID,
			TeamID:         settings.APNsTeamID,
			BundleID:       settings.APNsBundleID,
			PrivateKeyPath: settings.APNsPrivateKeyPath,
		}, repository)
		if err != nil {
			logger.Error("configure APNs notifications", "error", err)
			os.Exit(1)
		}
	}

	whatsAppManager, err := whatsapp.NewManager(
		rootContext,
		settings.DatabaseURL,
		repository,
		interruptionNotifier,
		settings.PairingCodeLifetime,
		settings.PendingHistoryRetention,
		settings.SessionReconcileInterval,
		logger,
	)
	if err != nil {
		logger.Error("start WhatsApp session manager", "error", err)
		os.Exit(1)
	}

	authVerifier := auth.NewVerifier(settings.V14AuthMeURL, settings.AuthTimeout, logger)
	router := httpapi.NewRouter(repository, whatsAppManager, authVerifier, settings.AllowedClient, logger)
	server := &http.Server{
		Addr:              settings.HTTPAddress,
		Handler:           router,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      3 * time.Minute,
		IdleTimeout:       90 * time.Second,
		MaxHeaderBytes:    32 << 10,
	}

	serverErrors := make(chan error, 1)
	go func() {
		logger.Info("Talia Exporter API started", "address", settings.HTTPAddress, "environment", settings.Environment)
		serverErrors <- server.ListenAndServe()
	}()

	select {
	case <-rootContext.Done():
		logger.Info("shutting down Talia Exporter API")
	case err := <-serverErrors:
		if !errors.Is(err, http.ErrServerClosed) {
			logger.Error("Talia Exporter API stopped unexpectedly", "error", err)
		}
		stopSignals()
	}

	shutdownContext, cancel := context.WithTimeout(context.Background(), settings.ShutdownTimeout)
	defer cancel()
	if err := server.Shutdown(shutdownContext); err != nil {
		logger.Error("shut down HTTP server", "error", err)
	}
	if err := whatsAppManager.Close(shutdownContext); err != nil {
		logger.Error("shut down WhatsApp manager", "error", err)
	}
}

func newLogger(level string) *slog.Logger {
	var parsed slog.Level
	switch strings.ToLower(level) {
	case "debug":
		parsed = slog.LevelDebug
	case "warn", "warning":
		parsed = slog.LevelWarn
	case "error":
		parsed = slog.LevelError
	default:
		parsed = slog.LevelInfo
	}
	return slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: parsed}))
}
