import Foundation

extension AppModel {
    func refreshDashboard(showErrors: Bool = true) async {
        guard route == .main, !isRefreshingDashboard else { return }
        isRefreshingDashboard = true
        defer { isRefreshingDashboard = false }

        do {
            let snapshot = try await api.dashboard()
            apply(snapshot)
            await persistDashboard()
        } catch {
            if showErrors {
                await handle(error, title: "Refresh failed")
            }
        }
    }

    func refreshMessages() async {
        do {
            messages = try await api.messages(limit: 100)
        } catch {
            await handle(error, title: "Unable to load messages")
        }
    }

    func refreshEvents() async {
        do {
            events = try await api.events(limit: 100)
        } catch {
            await handle(error, title: "Unable to load activity")
        }
    }

    func refreshGroups() async {
        do {
            groups = try await api.groups()
            await persistDashboard()
        } catch {
            await handle(error, title: "Unable to load groups")
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
        do {
            session = try await api.setCaptureEnabled(enabled)
            await persistDashboard()
        } catch {
            await handle(error, title: enabled ? "Unable to resume capture" : "Unable to pause capture")
        }
    }

    func setIncludeMedia(_ enabled: Bool) async {
        guard session?.includeMedia != enabled else { return }
        do {
            session = try await api.setPreferences(CapturePreferences(includeMedia: enabled))
            await persistDashboard()
        } catch {
            await handle(error, title: "Unable to update preferences")
        }
    }

    func unlinkWhatsApp() async {
        guard !isWorking else { return }
        isWorking = true
        selectionTask?.cancel()
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
        selectionTask?.cancel()
        selectionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            await self.synchroniseSelection()
        }
    }

    private func synchroniseSelection() async {
        let selected = groups.filter(\.isSelected).map(\.id)
        do {
            session = try await api.saveSelection(groupJIDs: selected)
            await persistDashboard()
        } catch {
            if let serverGroups = try? await api.groups() {
                groups = serverGroups
            }
            await handle(error, title: "Group selection not saved")
        }
    }
}
