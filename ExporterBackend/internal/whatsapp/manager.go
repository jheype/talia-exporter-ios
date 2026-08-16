package whatsapp

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"

	"github.com/google/uuid"
	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/talia/exporter/internal/domain"
	"github.com/talia/exporter/internal/notify"
	"github.com/talia/exporter/internal/store"
	"go.mau.fi/whatsmeow"
	waStore "go.mau.fi/whatsmeow/store"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
)

const (
	leaseDuration        = 45 * time.Second
	eventQueueSize       = 512
	notificationCooldown = time.Hour
	historySyncTimeout   = time.Hour
)

type Manager struct {
	repository        store.Repository
	notifier          notify.Sender
	container         *sqlstore.Container
	database          *sql.DB
	logger            *slog.Logger
	workerID          string
	pairingLifetime   time.Duration
	pendingRetention  time.Duration
	reconcileInterval time.Duration

	ctx     context.Context
	cancel  context.CancelFunc
	mu      sync.RWMutex
	workers map[uuid.UUID]*worker
}

type worker struct {
	sessionID uuid.UUID
	client    *whatsmeow.Client
	queue     chan any
	ctx       context.Context
	cancel    context.CancelFunc
	stopping  atomic.Bool
}

func NewManager(
	parent context.Context,
	databaseURL string,
	repository store.Repository,
	notifier notify.Sender,
	pairingLifetime time.Duration,
	pendingRetention time.Duration,
	reconcileInterval time.Duration,
	logger *slog.Logger,
) (*Manager, error) {
	if notifier == nil {
		notifier = notify.NoopSender{}
	}
	database, err := sql.Open("pgx", databaseURL)
	if err != nil {
		return nil, fmt.Errorf("open WhatsApp device database: %w", err)
	}
	database.SetMaxOpenConns(12)
	database.SetMaxIdleConns(2)
	database.SetConnMaxLifetime(30 * time.Minute)

	container := sqlstore.NewWithDB(database, "postgres", nil)
	if err := container.Upgrade(parent); err != nil {
		_ = database.Close()
		return nil, fmt.Errorf("upgrade WhatsApp device store: %w", err)
	}

	ctx, cancel := context.WithCancel(parent)
	manager := &Manager{
		repository:        repository,
		notifier:          notifier,
		container:         container,
		database:          database,
		logger:            logger,
		workerID:          uuid.NewString(),
		pairingLifetime:   pairingLifetime,
		pendingRetention:  pendingRetention,
		reconcileInterval: reconcileInterval,
		ctx:               ctx,
		cancel:            cancel,
		workers:           make(map[uuid.UUID]*worker),
	}
	go manager.reconcileLoop()
	return manager, nil
}

func (manager *Manager) Pair(
	ctx context.Context,
	userID uuid.UUID,
	phoneNumber string,
) (domain.PairingCode, error) {
	if existing, err := manager.repository.SessionByUser(ctx, userID); err == nil {
		if existing.IsLinked() {
			return domain.PairingCode{}, fmt.Errorf("%w: unlink the current account first", domain.ErrConflict)
		}
		manager.mu.RLock()
		_, pairing := manager.workers[existing.ID]
		manager.mu.RUnlock()
		if pairing && existing.Status == domain.StatusPairing {
			return domain.PairingCode{}, domain.ErrPairingInProgress
		}
		if existing.PhoneNumber != nil && *existing.PhoneNumber != phoneNumber {
			if err := manager.clearStoredDevice(ctx, existing); err != nil {
				return domain.PairingCode{}, err
			}
			if err := manager.repository.ArchiveSession(ctx, userID); err != nil {
				return domain.PairingCode{}, err
			}
		} else if existing.DeviceJID != nil && existing.Status == domain.StatusLoggedOut {
			if err := manager.clearStoredDevice(ctx, existing); err != nil {
				return domain.PairingCode{}, err
			}
		}
	} else if !errors.Is(err, domain.ErrNotFound) {
		return domain.PairingCode{}, err
	}

	session, err := manager.repository.BeginPairing(ctx, userID, phoneNumber)
	if err != nil {
		return domain.PairingCode{}, err
	}

	device := manager.container.NewDevice()
	client := whatsmeow.NewClient(device, nil)
	createdWorker := manager.newWorker(session.ID, client)
	if err := manager.addWorker(createdWorker); err != nil {
		return domain.PairingCode{}, err
	}

	qrChannel, err := client.GetQRChannel(createdWorker.ctx)
	if err != nil {
		manager.removeWorker(session.ID, true)
		return domain.PairingCode{}, fmt.Errorf("prepare pairing channel: %w", err)
	}
	if err := client.Connect(); err != nil {
		manager.removeWorker(session.ID, true)
		return domain.PairingCode{}, fmt.Errorf("connect for pairing: %w", err)
	}

	select {
	case item, open := <-qrChannel:
		if !open {
			manager.removeWorker(session.ID, true)
			return domain.PairingCode{}, errors.New("pairing channel closed")
		}
		if item.Event == whatsmeow.QRChannelEventError || item.Error != nil {
			manager.removeWorker(session.ID, true)
			if item.Error != nil {
				return domain.PairingCode{}, fmt.Errorf("pairing channel: %w", item.Error)
			}
			return domain.PairingCode{}, errors.New("pairing channel failed")
		}
	case <-ctx.Done():
		manager.removeWorker(session.ID, true)
		return domain.PairingCode{}, ctx.Err()
	case <-time.After(20 * time.Second):
		manager.removeWorker(session.ID, true)
		return domain.PairingCode{}, errors.New("timed out while preparing pairing")
	}

	code, err := client.PairPhone(
		ctx,
		digitsOnly(phoneNumber),
		false,
		whatsmeow.PairClientChrome,
		"Chrome (macOS)",
	)
	if err != nil {
		manager.removeWorker(session.ID, true)
		return domain.PairingCode{}, fmt.Errorf("generate pairing code: %w", err)
	}

	expiresAt := time.Now().UTC().Add(manager.pairingLifetime)
	go manager.expirePairing(session.ID, expiresAt)
	return domain.PairingCode{Session: session, Code: code, ExpiresAt: expiresAt}, nil
}

func (manager *Manager) SynchroniseGroups(ctx context.Context, userID uuid.UUID) ([]domain.Group, error) {
	session, err := manager.repository.SessionByUser(ctx, userID)
	if err != nil {
		return nil, err
	}
	if !session.IsLinked() {
		return nil, domain.ErrNotLinked
	}
	createdWorker := manager.worker(session.ID)
	if createdWorker == nil {
		return manager.repository.Groups(ctx, session.ID)
	}
	return manager.synchroniseGroups(ctx, session.ID, createdWorker.client)
}

func (manager *Manager) Unlink(ctx context.Context, userID uuid.UUID) error {
	session, err := manager.repository.SessionByUser(ctx, userID)
	if err != nil {
		return err
	}

	createdWorker := manager.worker(session.ID)
	if createdWorker != nil {
		createdWorker.stopping.Store(true)
		if err := createdWorker.client.Logout(ctx); err != nil {
			manager.logger.Warn("WhatsApp logout request failed; clearing local device", "session_id", session.ID, "error", err)
			createdWorker.client.Disconnect()
			_ = createdWorker.client.Store.Delete(ctx)
		}
		manager.removeWorker(session.ID, false)
	} else if session.DeviceJID != nil {
		jid, parseErr := types.ParseJID(*session.DeviceJID)
		if parseErr == nil {
			device, getErr := manager.container.GetDevice(ctx, jid)
			if getErr == nil && device != nil {
				_ = device.Delete(ctx)
			}
		}
	}
	if err := manager.repository.ReleaseLease(ctx, session.ID, manager.workerID); err != nil {
		manager.logger.Warn("release WhatsApp lease", "session_id", session.ID, "error", err)
	}
	return manager.repository.ArchiveSession(ctx, userID)
}

func (manager *Manager) clearStoredDevice(ctx context.Context, session domain.Session) error {
	createdWorker := manager.worker(session.ID)
	if createdWorker != nil {
		manager.removeWorker(session.ID, true)
	}
	if session.DeviceJID == nil {
		return nil
	}
	jid, err := types.ParseJID(*session.DeviceJID)
	if err != nil {
		return nil
	}
	device, err := manager.container.GetDevice(ctx, jid)
	if err != nil || device == nil {
		return err
	}
	return device.Delete(ctx)
}

func (manager *Manager) Close(ctx context.Context) error {
	manager.cancel()

	manager.mu.Lock()
	workers := make([]*worker, 0, len(manager.workers))
	for _, createdWorker := range manager.workers {
		workers = append(workers, createdWorker)
	}
	manager.workers = make(map[uuid.UUID]*worker)
	manager.mu.Unlock()

	for _, createdWorker := range workers {
		createdWorker.stopping.Store(true)
		createdWorker.client.Disconnect()
		createdWorker.cancel()
		_ = manager.repository.ReleaseLease(ctx, createdWorker.sessionID, manager.workerID)
	}
	return manager.database.Close()
}

func (manager *Manager) newWorker(sessionID uuid.UUID, client *whatsmeow.Client) *worker {
	ctx, cancel := context.WithCancel(manager.ctx)
	createdWorker := &worker{
		sessionID: sessionID,
		client:    client,
		queue:     make(chan any, eventQueueSize),
		ctx:       ctx,
		cancel:    cancel,
	}
	client.AddEventHandler(func(event any) {
		select {
		case createdWorker.queue <- event:
		case <-createdWorker.ctx.Done():
		}
	})
	return createdWorker
}

func (manager *Manager) addWorker(createdWorker *worker) error {
	manager.mu.Lock()
	defer manager.mu.Unlock()
	if _, exists := manager.workers[createdWorker.sessionID]; exists {
		createdWorker.cancel()
		return domain.ErrPairingInProgress
	}
	manager.workers[createdWorker.sessionID] = createdWorker
	go manager.eventLoop(createdWorker)
	return nil
}

func (manager *Manager) removeWorker(sessionID uuid.UUID, disconnect bool) {
	manager.mu.Lock()
	createdWorker := manager.workers[sessionID]
	delete(manager.workers, sessionID)
	manager.mu.Unlock()
	if createdWorker == nil {
		return
	}
	createdWorker.stopping.Store(true)
	if disconnect {
		createdWorker.client.Disconnect()
	}
	createdWorker.cancel()
}

func (manager *Manager) worker(sessionID uuid.UUID) *worker {
	manager.mu.RLock()
	defer manager.mu.RUnlock()
	return manager.workers[sessionID]
}

func (manager *Manager) eventLoop(createdWorker *worker) {
	for {
		select {
		case <-createdWorker.ctx.Done():
			return
		case event := <-createdWorker.queue:
			manager.handleEvent(createdWorker, event)
		}
	}
}

func (manager *Manager) handleEvent(createdWorker *worker, raw any) {
	timeout := 2 * time.Minute
	if _, isHistorySync := raw.(*events.HistorySync); isHistorySync {
		timeout = historySyncTimeout
	}
	ctx, cancel := context.WithTimeout(createdWorker.ctx, timeout)
	defer cancel()

	switch event := raw.(type) {
	case *events.Connected:
		if createdWorker.client.Store.ID == nil {
			return
		}
		deviceJID := createdWorker.client.Store.ID.String()
		if err := manager.repository.MarkLinked(ctx, createdWorker.sessionID, deviceJID); err != nil {
			manager.logger.Error("mark WhatsApp session linked", "session_id", createdWorker.sessionID, "error", err)
			return
		}
		_, _ = manager.repository.AcquireLease(ctx, createdWorker.sessionID, manager.workerID, leaseDuration)
		if _, err := manager.synchroniseGroups(ctx, createdWorker.sessionID, createdWorker.client); err != nil {
			manager.logger.Warn("synchronise WhatsApp groups", "session_id", createdWorker.sessionID, "error", err)
		}

	case *events.Disconnected:
		if !createdWorker.stopping.Load() {
			message := "WhatsApp connection interrupted; reconnecting"
			_ = manager.repository.SetSessionStatus(ctx, createdWorker.sessionID, domain.StatusReconnecting, &message)
		}

	case *events.LoggedOut:
		message := event.PermanentDisconnectDescription()
		_ = manager.repository.SetSessionStatus(ctx, createdWorker.sessionID, domain.StatusLoggedOut, &message)
		if !createdWorker.stopping.Load() {
			manager.notifyInterruption(
				createdWorker.sessionID,
				"WhatsApp link expired",
				"Open Talia Exporter to link WhatsApp again.",
			)
		}
		go manager.removeWorker(createdWorker.sessionID, false)

	case events.PermanentDisconnect:
		message := event.PermanentDisconnectDescription()
		_ = manager.repository.SetSessionStatus(ctx, createdWorker.sessionID, domain.StatusInterrupted, &message)
		if !createdWorker.stopping.Load() {
			manager.notifyInterruption(
				createdWorker.sessionID,
				"Capture needs attention",
				"Open Talia Exporter to review the WhatsApp connection.",
			)
		}
		go manager.removeWorker(createdWorker.sessionID, false)

	case *events.Message:
		manager.persistMessage(ctx, createdWorker.sessionID, event, false)

	case *events.HistorySync:
		manager.persistHistory(ctx, createdWorker, event)

	case *events.JoinedGroup, *events.GroupInfo:
		if _, err := manager.synchroniseGroups(ctx, createdWorker.sessionID, createdWorker.client); err != nil {
			manager.logger.Warn("refresh WhatsApp groups", "session_id", createdWorker.sessionID, "error", err)
		}
	}
}

func (manager *Manager) notifyInterruption(sessionID uuid.UUID, title, body string) {
	go func() {
		ctx, cancel := context.WithTimeout(manager.ctx, 30*time.Second)
		defer cancel()

		userID, claimed, err := manager.repository.ClaimInterruptionNotification(
			ctx,
			sessionID,
			notificationCooldown,
		)
		if err != nil {
			manager.logger.Warn("claim interruption notification", "session_id", sessionID, "error", err)
			return
		}
		if !claimed {
			return
		}
		if err := manager.notifier.SendInterruption(ctx, userID, title, body); err != nil {
			manager.logger.Warn("send interruption notification", "session_id", sessionID, "error", err)
		}
	}()
}

func (manager *Manager) persistHistory(ctx context.Context, createdWorker *worker, history *events.HistorySync) {
	if history == nil || history.Data == nil {
		return
	}
	for _, conversation := range history.Data.GetConversations() {
		chatJID, err := types.ParseJID(conversation.GetID())
		if err != nil {
			continue
		}
		for _, historyMessage := range conversation.GetMessages() {
			parsed, err := createdWorker.client.ParseWebMessage(chatJID, historyMessage.GetMessage())
			if err != nil {
				manager.logger.Debug("parse WhatsApp history message", "session_id", createdWorker.sessionID, "error", err)
				continue
			}
			manager.persistMessage(ctx, createdWorker.sessionID, parsed, true)
		}
	}
}

func (manager *Manager) persistMessage(ctx context.Context, sessionID uuid.UUID, event *events.Message, history bool) {
	incoming, ok := normaliseMessage(sessionID, event, history)
	if !ok {
		return
	}
	if _, err := manager.repository.InsertMessage(ctx, incoming); err != nil && !errors.Is(err, context.Canceled) {
		manager.logger.Error(
			"persist WhatsApp message",
			"session_id", sessionID,
			"message_id", incoming.WhatsAppMessageID,
			"error", err,
		)
	}
}

func (manager *Manager) synchroniseGroups(
	ctx context.Context,
	sessionID uuid.UUID,
	client *whatsmeow.Client,
) ([]domain.Group, error) {
	whatsAppGroups, err := client.GetJoinedGroups(ctx)
	if err != nil {
		return nil, err
	}
	groups := make([]domain.Group, 0, len(whatsAppGroups))
	for _, whatsAppGroup := range whatsAppGroups {
		if whatsAppGroup == nil {
			continue
		}
		participantCount := whatsAppGroup.ParticipantCount
		if participantCount == 0 {
			participantCount = len(whatsAppGroup.Participants)
		}
		name := whatsAppGroup.Name
		if name == "" {
			name = whatsAppGroup.JID.String()
		}
		groups = append(groups, domain.Group{
			JID:              whatsAppGroup.JID.String(),
			Name:             name,
			ParticipantCount: participantCount,
		})
	}
	if err := manager.repository.UpsertGroups(ctx, sessionID, groups); err != nil {
		return nil, err
	}
	return manager.repository.Groups(ctx, sessionID)
}

func (manager *Manager) reconcileLoop() {
	manager.reconcile()
	ticker := time.NewTicker(manager.reconcileInterval)
	defer ticker.Stop()
	for {
		select {
		case <-manager.ctx.Done():
			return
		case <-ticker.C:
			manager.reconcile()
		}
	}
}

func (manager *Manager) reconcile() {
	ctx, cancel := context.WithTimeout(manager.ctx, manager.reconcileInterval)
	defer cancel()
	if err := manager.repository.PurgeExpiredPendingMessages(ctx, manager.pendingRetention); err != nil {
		manager.logger.Warn("purge expired pending WhatsApp history", "error", err)
	}

	sessions, err := manager.repository.SessionsForReconciliation(ctx)
	if err != nil {
		manager.logger.Error("list WhatsApp sessions for reconciliation", "error", err)
		return
	}
	for _, session := range sessions {
		if existing := manager.worker(session.ID); existing != nil {
			owned, err := manager.repository.RenewLease(ctx, session.ID, manager.workerID, leaseDuration)
			if err != nil || !owned {
				manager.removeWorker(session.ID, true)
			}
			continue
		}

		owned, err := manager.repository.AcquireLease(ctx, session.ID, manager.workerID, leaseDuration)
		if err != nil || !owned || session.DeviceJID == nil {
			continue
		}
		jid, err := types.ParseJID(*session.DeviceJID)
		if err != nil {
			message := "Stored WhatsApp device identity is invalid"
			_ = manager.repository.SetSessionStatus(ctx, session.ID, domain.StatusLoggedOut, &message)
			manager.notifyInterruption(session.ID, "WhatsApp link expired", "Open Talia Exporter to link WhatsApp again.")
			continue
		}
		device, err := manager.container.GetDevice(ctx, jid)
		if err != nil {
			manager.logger.Warn("load WhatsApp device credentials", "session_id", session.ID, "error", err)
			continue
		}
		if device == nil {
			message := "WhatsApp device credentials are unavailable"
			_ = manager.repository.SetSessionStatus(ctx, session.ID, domain.StatusLoggedOut, &message)
			manager.notifyInterruption(session.ID, "WhatsApp link expired", "Open Talia Exporter to link WhatsApp again.")
			continue
		}
		manager.attachExisting(session, device)
	}
}

func (manager *Manager) attachExisting(session domain.Session, device *waStore.Device) {
	client := whatsmeow.NewClient(device, nil)
	createdWorker := manager.newWorker(session.ID, client)
	if err := manager.addWorker(createdWorker); err != nil {
		return
	}
	if err := client.Connect(); err != nil {
		manager.removeWorker(session.ID, false)
		message := "Unable to reconnect WhatsApp"
		_ = manager.repository.SetSessionStatus(manager.ctx, session.ID, domain.StatusInterrupted, &message)
	}
}

func (manager *Manager) expirePairing(sessionID uuid.UUID, expiresAt time.Time) {
	timer := time.NewTimer(time.Until(expiresAt))
	defer timer.Stop()
	select {
	case <-manager.ctx.Done():
		return
	case <-timer.C:
	}

	createdWorker := manager.worker(sessionID)
	if createdWorker == nil || createdWorker.client.Store.ID != nil {
		return
	}
	message := "Pairing code expired"
	_ = manager.repository.SetSessionStatus(manager.ctx, sessionID, domain.StatusInterrupted, &message)
	manager.removeWorker(sessionID, true)
}

func digitsOnly(value string) string {
	result := make([]byte, 0, len(value))
	for index := 0; index < len(value); index++ {
		if value[index] >= '0' && value[index] <= '9' {
			result = append(result, value[index])
		}
	}
	return string(result)
}
