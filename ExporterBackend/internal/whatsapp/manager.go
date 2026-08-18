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
	waHistorySync "go.mau.fi/whatsmeow/proto/waHistorySync"
	waStore "go.mau.fi/whatsmeow/store"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
)

const (
	leaseDuration             = 45 * time.Second
	eventQueueSize            = 512
	notificationCooldown      = time.Hour
	historyEventTimeout       = time.Hour
	historyBatchSize          = 50
	historyBatchesPerPass     = 20
	historyRequestTimeout     = 45 * time.Second
	historyBatchResponseLimit = 90 * time.Second
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
	sessionID           uuid.UUID
	client              *whatsmeow.Client
	queue               chan any
	historyBatches      chan historyBatch
	ctx                 context.Context
	cancel              context.CancelFunc
	stopping            atomic.Bool
	historySyncing      atomic.Bool
	historyRequestMu    sync.RWMutex
	historyRequestGroup string
}

type historyBatch struct {
	groupJID      string
	messageCount  int
	oldest        *domain.HistoryAnchor
	endOfHistory  bool
	accessLimited bool
}

type historyBatchResult int

const (
	historyBatchContinue historyBatchResult = iota
	historyBatchComplete
	historyBatchStalled
)

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
	// Reconciliation renews the database lease. Keep a three-tick safety
	// margin so a healthy worker cannot repeatedly lose ownership and open a
	// second WhatsApp client for the same device.
	if reconcileInterval <= 0 || reconcileInterval*3 > leaseDuration {
		return nil, fmt.Errorf(
			"SESSION_RECONCILE_INTERVAL (%s) must be at most a third of the %s session lease",
			reconcileInterval,
			leaseDuration,
		)
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

func (manager *Manager) StartHistorySync(ctx context.Context, userID uuid.UUID) error {
	session, err := manager.repository.SessionByUser(ctx, userID)
	if err != nil {
		return err
	}
	if !session.IsLinked() {
		return domain.ErrNotLinked
	}
	if createdWorker := manager.worker(session.ID); createdWorker != nil {
		manager.ensureHistorySync(createdWorker)
	}
	return nil
}

func (manager *Manager) RetryHistorySync(
	ctx context.Context,
	userID uuid.UUID,
	groupJIDs []string,
) ([]domain.Group, error) {
	groups, err := manager.repository.QueueHistorySync(ctx, userID, groupJIDs)
	if err != nil {
		return nil, err
	}
	if err := manager.StartHistorySync(ctx, userID); err != nil {
		return nil, err
	}
	return groups, nil
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
		sessionID:      sessionID,
		client:         client,
		queue:          make(chan any, eventQueueSize),
		historyBatches: make(chan historyBatch, eventQueueSize),
		ctx:            ctx,
		cancel:         cancel,
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
		timeout = historyEventTimeout
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
		owned, err := manager.repository.AcquireLease(
			ctx,
			createdWorker.sessionID,
			manager.workerID,
			leaseDuration,
		)
		if err != nil || !owned {
			manager.logger.Warn(
				"WhatsApp session lease not held on connect; releasing worker",
				"session_id", createdWorker.sessionID,
				"error", err,
			)
			go manager.removeWorker(createdWorker.sessionID, true)
			return
		}
		if _, err := manager.synchroniseGroups(ctx, createdWorker.sessionID, createdWorker.client); err != nil {
			manager.logger.Warn("synchronise WhatsApp groups", "session_id", createdWorker.sessionID, "error", err)
		}
		manager.ensureHistorySync(createdWorker)

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
		manager.recordMessageAnchor(ctx, createdWorker.sessionID, event)
		manager.persistMessage(ctx, createdWorker.sessionID, event, false)
		manager.ensureHistorySync(createdWorker)

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
	conversationCount := 0
	for _, conversation := range history.Data.GetConversations() {
		chatJID, err := types.ParseJID(conversation.GetID())
		if err != nil || chatJID.Server != types.GroupServer {
			continue
		}
		conversationCount++
		batch := historyBatch{
			groupJID:     chatJID.String(),
			messageCount: len(conversation.GetMessages()),
			endOfHistory: conversation.GetEndOfHistoryTransfer(),
		}
		if conversation.EndOfHistoryTransferType != nil {
			switch conversation.GetEndOfHistoryTransferType() {
			case waHistorySync.Conversation_COMPLETE_AND_NO_MORE_MESSAGE_REMAIN_ON_PRIMARY:
				batch.endOfHistory = true
			case waHistorySync.Conversation_COMPLETE_ON_DEMAND_SYNC_WITH_MORE_MSG_ON_PRIMARY_BUT_NO_ACCESS:
				batch.accessLimited = true
			}
		}
		for _, historyMessage := range conversation.GetMessages() {
			parsed, err := createdWorker.client.ParseWebMessage(chatJID, historyMessage.GetMessage())
			if err != nil {
				manager.logger.Debug("parse WhatsApp history message", "session_id", createdWorker.sessionID, "error", err)
				continue
			}
			if anchor, ok := historyAnchor(parsed); ok && olderAnchor(batch.oldest, anchor) {
				anchorCopy := anchor
				batch.oldest = &anchorCopy
			}
			manager.persistMessage(ctx, createdWorker.sessionID, parsed, true)
		}
		if err := manager.repository.RecordHistoryBatch(
			ctx,
			createdWorker.sessionID,
			batch.groupJID,
			batch.messageCount,
			batch.oldest,
		); err != nil {
			manager.logger.Warn(
				"record WhatsApp history batch",
				"session_id", createdWorker.sessionID,
				"group_jid", batch.groupJID,
				"error", err,
			)
		}
		manager.publishHistoryBatch(createdWorker, batch)
	}

	// An on-demand request can legitimately return an empty HistorySync (no
	// conversations at all) when the primary phone has no older messages to
	// provide. There is no conversation JID in that response, so correlate it
	// with the single in-flight request. Without this signal the worker would
	// wait for 90 seconds and incorrectly label a completed sync as stalled.
	if conversationCount == 0 && history.Data.GetSyncType() == waHistorySync.HistorySync_ON_DEMAND {
		groupJID := createdWorker.currentHistoryRequestGroup()
		if groupJID == "" {
			return
		}
		batch := historyBatch{groupJID: groupJID, endOfHistory: true}
		if err := manager.repository.RecordHistoryBatch(
			ctx,
			createdWorker.sessionID,
			groupJID,
			0,
			nil,
		); err != nil {
			manager.logger.Warn(
				"record empty WhatsApp history batch",
				"session_id", createdWorker.sessionID,
				"group_jid", groupJID,
				"error", err,
			)
		}
		manager.publishHistoryBatch(createdWorker, batch)
	}
}

func (manager *Manager) publishHistoryBatch(createdWorker *worker, batch historyBatch) {
	select {
	case createdWorker.historyBatches <- batch:
	case <-createdWorker.ctx.Done():
	default:
		manager.logger.Debug(
			"history response queue is full",
			"session_id", createdWorker.sessionID,
			"group_jid", batch.groupJID,
		)
	}
}

func (createdWorker *worker) setHistoryRequestGroup(groupJID string) {
	createdWorker.historyRequestMu.Lock()
	createdWorker.historyRequestGroup = groupJID
	createdWorker.historyRequestMu.Unlock()
}

func (createdWorker *worker) clearHistoryRequestGroup(groupJID string) {
	createdWorker.historyRequestMu.Lock()
	if createdWorker.historyRequestGroup == groupJID {
		createdWorker.historyRequestGroup = ""
	}
	createdWorker.historyRequestMu.Unlock()
}

func (createdWorker *worker) currentHistoryRequestGroup() string {
	createdWorker.historyRequestMu.RLock()
	defer createdWorker.historyRequestMu.RUnlock()
	return createdWorker.historyRequestGroup
}

func (manager *Manager) recordMessageAnchor(
	ctx context.Context,
	sessionID uuid.UUID,
	event *events.Message,
) {
	anchor, ok := historyAnchor(event)
	if !ok {
		return
	}
	if err := manager.repository.RecordHistoryAnchor(ctx, sessionID, anchor); err != nil &&
		!errors.Is(err, context.Canceled) {
		manager.logger.Debug(
			"record WhatsApp history anchor",
			"session_id", sessionID,
			"group_jid", anchor.GroupJID,
			"error", err,
		)
	}
}

func historyAnchor(event *events.Message) (domain.HistoryAnchor, bool) {
	if event == nil || !event.Info.IsGroup || event.Info.Chat.IsEmpty() ||
		event.Info.ID == "" || event.Info.Timestamp.IsZero() {
		return domain.HistoryAnchor{}, false
	}
	return domain.HistoryAnchor{
		GroupJID:          event.Info.Chat.String(),
		WhatsAppMessageID: string(event.Info.ID),
		Timestamp:         event.Info.Timestamp,
		IsFromMe:          event.Info.IsFromMe,
	}, true
}

func olderAnchor(current *domain.HistoryAnchor, candidate domain.HistoryAnchor) bool {
	if current == nil {
		return true
	}
	if candidate.Timestamp.Before(current.Timestamp) {
		return true
	}
	return candidate.Timestamp.Equal(current.Timestamp) &&
		candidate.WhatsAppMessageID < current.WhatsAppMessageID
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

func (manager *Manager) ensureHistorySync(createdWorker *worker) {
	if createdWorker == nil || createdWorker.stopping.Load() ||
		!createdWorker.historySyncing.CompareAndSwap(false, true) {
		return
	}
	go manager.syncSelectedHistory(createdWorker)
}

func (manager *Manager) syncSelectedHistory(createdWorker *worker) {
	defer createdWorker.historySyncing.Store(false)

	ctx, cancel := context.WithTimeout(createdWorker.ctx, 30*time.Minute)
	defer cancel()
	groups, err := manager.repository.Groups(ctx, createdWorker.sessionID)
	if err != nil {
		manager.logger.Warn("load groups for history sync", "session_id", createdWorker.sessionID, "error", err)
		return
	}

	for _, group := range groups {
		if !group.IsSelected {
			continue
		}
		switch group.HistorySyncState {
		case domain.HistorySyncComplete, domain.HistorySyncStalled, domain.HistorySyncFailed:
			continue
		}
		manager.syncGroupHistory(ctx, createdWorker, group)
	}
}

func (manager *Manager) syncGroupHistory(
	ctx context.Context,
	createdWorker *worker,
	group domain.Group,
) {
	anchor, err := manager.repository.HistoryAnchor(ctx, createdWorker.sessionID, group.JID)
	if errors.Is(err, domain.ErrNotFound) {
		message := "Waiting for a recent group message before older WhatsApp history can be requested"
		_ = manager.repository.SetHistorySyncState(
			ctx,
			createdWorker.sessionID,
			group.JID,
			domain.HistorySyncWaitingForAnchor,
			&message,
		)
		return
	}
	if err != nil {
		message := "Unable to load the saved history cursor"
		_ = manager.repository.SetHistorySyncState(
			ctx,
			createdWorker.sessionID,
			group.JID,
			domain.HistorySyncFailed,
			&message,
		)
		return
	}

	seenAnchors := map[string]struct{}{anchor.WhatsAppMessageID: struct{}{}}
	for batchIndex := 0; batchIndex < historyBatchesPerPass; batchIndex++ {
		if err := ctx.Err(); err != nil {
			return
		}
		manager.drainHistoryBatches(createdWorker)
		if err := manager.repository.MarkHistorySyncRequest(ctx, createdWorker.sessionID, group.JID); err != nil {
			manager.logger.Warn("mark history request", "session_id", createdWorker.sessionID, "group_jid", group.JID, "error", err)
			return
		}

		chatJID, err := types.ParseJID(anchor.GroupJID)
		if err != nil {
			message := "The saved WhatsApp group identifier is invalid"
			_ = manager.repository.SetHistorySyncState(ctx, createdWorker.sessionID, group.JID, domain.HistorySyncFailed, &message)
			return
		}
		messageInfo := &types.MessageInfo{
			MessageSource: types.MessageSource{
				Chat:     chatJID,
				IsGroup:  true,
				IsFromMe: anchor.IsFromMe,
			},
			ID:        types.MessageID(anchor.WhatsAppMessageID),
			Timestamp: anchor.Timestamp,
		}

		requestContext, requestCancel := context.WithTimeout(ctx, historyRequestTimeout)
		createdWorker.setHistoryRequestGroup(group.JID)
		_, sendErr := createdWorker.client.SendPeerMessage(
			requestContext,
			createdWorker.client.BuildHistorySyncRequest(messageInfo, historyBatchSize),
		)
		requestCancel()
		if sendErr != nil {
			createdWorker.clearHistoryRequestGroup(group.JID)
			message := "WhatsApp did not accept the history request; keep the primary phone online and retry"
			_ = manager.repository.SetHistorySyncState(ctx, createdWorker.sessionID, group.JID, domain.HistorySyncStalled, &message)
			return
		}

		batch, ok := manager.waitForHistoryBatch(ctx, createdWorker, group.JID)
		createdWorker.clearHistoryRequestGroup(group.JID)
		if !ok {
			message := "WhatsApp did not return the requested history batch; keep the primary phone online and retry"
			_ = manager.repository.SetHistorySyncState(ctx, createdWorker.sessionID, group.JID, domain.HistorySyncStalled, &message)
			return
		}
		switch classifyHistoryBatch(batch, seenAnchors) {
		case historyBatchComplete:
			_ = manager.repository.SetHistorySyncState(ctx, createdWorker.sessionID, group.JID, domain.HistorySyncComplete, nil)
			return
		case historyBatchStalled:
			message := "WhatsApp did not advance the history cursor; keep the primary phone online and retry"
			if batch.accessLimited {
				message = "WhatsApp reports older messages on the primary phone but did not grant access; keep it online and retry"
			} else if batch.oldest == nil && batch.messageCount > 0 {
				message = "WhatsApp returned a history batch that could not be decoded; retry the group history"
			}
			_ = manager.repository.SetHistorySyncState(
				ctx,
				createdWorker.sessionID,
				group.JID,
				domain.HistorySyncStalled,
				&message,
			)
			return
		}
		seenAnchors[batch.oldest.WhatsAppMessageID] = struct{}{}
		anchor = *batch.oldest
		// A short batch is not proof that history is exhausted. The primary
		// phone may return fewer than the requested 50 messages while older
		// messages still exist, so keep walking backwards from the new cursor.
	}

	_ = manager.repository.SetHistorySyncState(
		ctx,
		createdWorker.sessionID,
		group.JID,
		domain.HistorySyncQueued,
		nil,
	)
}

func classifyHistoryBatch(
	batch historyBatch,
	seenAnchors map[string]struct{},
) historyBatchResult {
	if batch.accessLimited {
		return historyBatchStalled
	}
	if batch.endOfHistory {
		return historyBatchComplete
	}
	// An empty conversation without either the legacy end-of-transfer flag or
	// the explicit no-more-messages enum is ambiguous. Never claim completion
	// in that case: expose a retryable stall instead. A wholly empty ON_DEMAND
	// response is correlated separately and marked endOfHistory by
	// persistHistory.
	if batch.messageCount == 0 {
		return historyBatchStalled
	}
	if batch.oldest == nil {
		return historyBatchStalled
	}
	_, repeated := seenAnchors[batch.oldest.WhatsAppMessageID]
	if repeated {
		return historyBatchStalled
	}
	return historyBatchContinue
}

func (manager *Manager) drainHistoryBatches(createdWorker *worker) {
	for {
		select {
		case <-createdWorker.historyBatches:
			continue
		default:
			return
		}
	}
}

func (manager *Manager) waitForHistoryBatch(
	ctx context.Context,
	createdWorker *worker,
	groupJID string,
) (historyBatch, bool) {
	timer := time.NewTimer(historyBatchResponseLimit)
	defer timer.Stop()
	for {
		select {
		case <-ctx.Done():
			return historyBatch{}, false
		case <-timer.C:
			return historyBatch{}, false
		case batch := <-createdWorker.historyBatches:
			if batch.groupJID == groupJID {
				return batch, true
			}
		}
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
			} else {
				manager.ensureHistorySync(existing)
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
