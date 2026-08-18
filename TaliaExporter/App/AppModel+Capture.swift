import Foundation

extension AppModel {
    func refreshDashboard(showErrors: Bool = true) async {
        guard route == .main, !isRefreshingDashboard else { return }
        isRefreshingDashboard = true
        defer { isRefreshingDashboard = false }
        stateReadRevision &+= 1
        let requestedStateReadRevision = stateReadRevision
        let requestedSelectionRevision = selectionRevision
        let selectionWasStable = selectionTask == nil

        do {
            let snapshot = try await api.dashboard()
            apply(
                snapshot,
                requestedStateReadRevision: requestedStateReadRevision,
                requestedSelectionRevision: requestedSelectionRevision,
                selectionWasStable: selectionWasStable
            )
            _ = await refreshMessageChanges(showErrors: false)
            await persistDashboard()
        } catch {
            if showErrors {
                await handle(error, title: "Refresh failed")
            }
        }
    }

    func refreshMessages() async {
        _ = await refreshMessageChanges(showErrors: true)
    }

    @discardableResult
    func refreshMessageChanges(showErrors: Bool, pageBudget: Int = 20) async -> Bool {
        guard !isRefreshingMessages else { return true }
        isRefreshingMessages = true
        defer { isRefreshingMessages = false }

        let budget = max(1, pageBudget)
        var cursor = messageCatchupCursor
        let target = messageCatchupCursor == nil ? messageChangeWatermark : messageCatchupTarget
        var head = messageCatchupCursor == nil ? nil : messageCatchupHead
        var seenCursors = Set<String>()
        if let cursor { seenCursors.insert(cursor) }

        do {
            for _ in 0..<budget {
                let page = try await api.messagesPage(limit: 100, cursor: cursor)
                if head == nil, let first = page.items.first {
                    head = first.changeWatermark
                }
                mergeMessages(page.items)

                let reachedTarget: Bool
                if let target {
                    reachedTarget = page.items.contains { $0.changeWatermark.isAtOrBefore(target) }
                } else {
                    // The first successful page establishes the initial
                    // watermark without downloading the entire archive.
                    reachedTarget = true
                }

                if reachedTarget || page.nextCursor == nil {
                    if let head { messageChangeWatermark = head }
                    messageCatchupCursor = nil
                    messageCatchupTarget = nil
                    messageCatchupHead = nil
                    return true
                }

                guard let nextCursor = page.nextCursor,
                      seenCursors.insert(nextCursor).inserted
                else {
                    throw APIError(
                        statusCode: nil,
                        code: "CLIENT.INVALID_MESSAGE_CURSOR",
                        message: "Exporter returned a repeated message cursor."
                    )
                }
                cursor = nextCursor
                messageCatchupCursor = nextCursor
                messageCatchupTarget = target
                messageCatchupHead = head
            }
            return true
        } catch {
            if showErrors {
                await handle(error, title: "Unable to load messages")
            }
            return false
        }
    }

    func refreshEvents() async {
        do {
            events = try await api.events(limit: 100)
        } catch {
            await handle(error, title: "Unable to load activity")
        }
    }

    func refreshGroups(showErrors: Bool = true) async {
        guard selectionTask == nil else { return }
        stateReadRevision &+= 1
        let requestedStateReadRevision = stateReadRevision
        let requestedSelectionRevision = selectionRevision
        do {
            let refreshed = try await api.groups()
            guard selectionTask == nil,
                  requestedStateReadRevision == stateReadRevision,
                  requestedSelectionRevision == selectionRevision
            else { return }
            groups = refreshed
            await persistDashboard()
        } catch {
            if showErrors {
                await handle(error, title: "Unable to load groups")
            }
        }
    }

    func retryHistorySync(for group: ExportGroup) async {
        guard group.isSelected, !historyRetryingGroupIDs.contains(group.id) else { return }
        historyRetryingGroupIDs.insert(group.id)
        defer { historyRetryingGroupIDs.remove(group.id) }
        stateReadRevision &+= 1
        let requestedStateReadRevision = stateReadRevision

        do {
            let refreshed = try await api.retryHistorySync(groupJIDs: [group.id])
            guard requestedStateReadRevision == stateReadRevision else { return }
            mergeHistoryProgress(refreshed)
            await persistDashboard()
        } catch {
            await handle(error, title: "Unable to retry message history")
        }
    }

    func toggleGroup(_ group: ExportGroup) {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[index].isSelected.toggle()
        scheduleSelectionSyncIfNeeded()
    }

    func selectAllGroups() {
        groups = groups.map { group in
            var group = group
            group.isSelected = true
            return group
        }
        scheduleSelectionSyncIfNeeded()
    }

    func clearGroupSelection() {
        groups = groups.map { group in
            var group = group
            group.isSelected = false
            return group
        }
        scheduleSelectionSyncIfNeeded()
    }

    func setCaptureEnabled(_ enabled: Bool) async {
        guard session?.captureEnabled != enabled else { return }
        stateReadRevision &+= 1
        do {
            let updated = try await api.setCaptureEnabled(enabled)
            stateReadRevision &+= 1
            session = updated
            await persistDashboard()
        } catch {
            await handle(error, title: enabled ? "Unable to resume capture" : "Unable to pause capture")
        }
    }

    func setIncludeMedia(_ enabled: Bool) async {
        guard session?.includeMedia != enabled else { return }
        stateReadRevision &+= 1
        do {
            let updated = try await api.setPreferences(CapturePreferences(includeMedia: enabled))
            stateReadRevision &+= 1
            session = updated
            await persistDashboard()
        } catch {
            await handle(error, title: "Unable to update preferences")
        }
    }

    func unlinkWhatsApp() async {
        guard !isWorking else { return }
        isWorking = true
        selectionTask?.cancel()
        selectionTask = nil
        selectionTaskID = nil
        selectionRevision &+= 1
        stateReadRevision &+= 1
        messageChangeWatermark = nil
        messageCatchupCursor = nil
        messageCatchupTarget = nil
        messageCatchupHead = nil
        latestMessageChanges = [:]
        defer { isWorking = false }

        do {
            try await api.unlinkSession()
            session = nil
            groups = []
            events = []
            messages = []
            await cache.clear()
            resetConnectionFlow()
            route = .connection
        } catch {
            await handle(error, title: "Unable to unlink WhatsApp")
        }
    }

    private func scheduleSelectionSyncIfNeeded() {
        guard route == .main else { return }
        selectionRevision &+= 1
        stateReadRevision &+= 1
        guard selectionTask == nil else { return }
        let taskID = UUID()
        selectionTaskID = taskID
        selectionTask = Task { [weak self] in
            guard let self else { return }
            await self.runSelectionSyncLoop(taskID: taskID)
        }
    }

    private func runSelectionSyncLoop(taskID: UUID) async {
        defer {
            if selectionTaskID == taskID {
                selectionTask = nil
                selectionTaskID = nil
            }
        }
        while !Task.isCancelled, selectionTaskID == taskID {
            let revision = selectionRevision
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            guard !Task.isCancelled, selectionTaskID == taskID else { return }
            if revision != selectionRevision { continue }

            let selected = groups.filter(\.isSelected).map(\.id)
            await synchroniseSelection(groupJIDs: selected, revision: revision)
            if revision == selectionRevision { return }
        }
    }

    private func synchroniseSelection(groupJIDs: [String], revision: UInt64) async {
        do {
            let refreshedSession = try await api.saveSelection(groupJIDs: groupJIDs)
            guard !Task.isCancelled, revision == selectionRevision else { return }
            stateReadRevision &+= 1
            session = refreshedSession
            await persistDashboard()
        } catch {
            guard !Task.isCancelled, revision == selectionRevision else { return }
            if let serverGroups = try? await api.groups(),
               !Task.isCancelled,
               revision == selectionRevision {
                groups = serverGroups
            }
            await handle(error, title: "Group selection not saved")
        }
    }

    private func mergeHistoryProgress(_ refreshed: [ExportGroup]) {
        let localSelection = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.isSelected) })
        groups = refreshed.map { serverGroup in
            var group = serverGroup
            group.isSelected = localSelection[group.id] ?? group.isSelected
            return group
        }
    }
}