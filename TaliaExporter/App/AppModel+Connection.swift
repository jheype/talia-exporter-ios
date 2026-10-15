import Foundation

extension AppModel {
    func restoreConnectionSession(_ candidate: ExporterSession?) async throws {
        guard let userID = user?.id else { return }
        // An expired link still belongs to this account and may need an
        // explicit unlink before a replacement phone can be paired.
        let ownedSession = try candidate.map(validatedSession)
        if let ownedSession, ownedSession.isLinked {
            session = ownedSession
            route = .main
            await refreshDashboard(showErrors: false)
        } else {
            let generation = accountScopeGeneration
            await clearAccountOwnedState(for: userID)
            guard user?.id == userID, accountScopeGeneration == generation &+ 1 else { return }
            session = ownedSession
            workspace.setOwner(user?.id)
            resetConnectionFlow()
            route = .connection
        }
    }

    func advanceFromIntro() {
        connectionStage = .number
    }

    func goBackInConnectionFlow() {
        guard connectionStage != .intro else { return }
        stateReadRevision &+= 1
        if connectionStage == .pairing {
            pairingTask?.cancel()
            pairingCode = nil
            pairingExpiresAt = nil
        }
        connectionStage = connectionStage.previous
    }

    func requestPairingCode(phoneNumber: String) async {
        guard !isWorking else { return }
        stateReadRevision &+= 1
        isWorking = true
        defer { isWorking = false }

        do {
            let response = try await api.requestPairingCode(phoneNumber: phoneNumber)
            let pairingAlphabet = Set("123456789ABCDEFGHJKLMNPQRSTVWXYZ")
            let pairingCharacters = response.code
                .uppercased()
                .filter { !$0.isWhitespace && $0 != "-" }

            guard pairingCharacters.count == 8,
                  pairingCharacters.allSatisfy(pairingAlphabet.contains)
            else {
                throw APIError(
                    statusCode: nil,
                    code: "CLIENT.INVALID_PAIRING_CODE",
                    message: "The service returned an invalid pairing code."
                )
            }
            session = try validatedSession(response.session)
            pairingCode = pairingCharacters
            pairingExpiresAt = response.expiresAt
            connectionStage = .pairing
            startPairingStatusPoll()
        } catch {
            await handle(error, title: "Unable to generate code")
        }
    }

    func checkPairingStatusNow() async {
        await pollPairingStatus(showErrors: true)
    }

    func completeConnection() async {
        guard selectedGroupCount > 0, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        let selected = groups.filter(\.isSelected).map(\.id)
        do {
            // The backend atomically enables capture with the first non-empty
            // selection, then starts history only after that transaction commits.
            // A second capture request recreated the exact window in which early
            // history pages could be acknowledged but discarded.
            let responseSession = try await api.saveSelection(groupJIDs: selected)
            let startedSession = try validatedSession(responseSession)
            guard startedSession.captureEnabled else {
                throw APIError(
                    statusCode: nil,
                    code: "CLIENT.ATOMIC_CAPTURE_NOT_ENABLED",
                    message: "Exporter did not enable capture with the selected groups. Update the backend before using this app build."
                )
            }
            await finishConnection(with: startedSession)
        } catch {
            if let recovered = await recoverCaptureMutation(
                after: error,
                expectedEnabled: true,
                expectedGroupJIDs: Set(selected)
            ) {
                await finishConnection(with: recovered)
                return
            }
            if let apiError = error as? APIError,
               apiError.code == "WHATSAPP.GROUP_SELECTION_STALE" {
                if let serverGroups = try? await api.groups() {
                    groups = serverGroups
                }
                alert = AppAlert(
                    title: "Group list changed",
                    message: "Choose the group again from the refreshed list, then start capture."
                )
                return
            }
            await handle(error, title: "Unable to start capture")
        }
    }

    private func finishConnection(with startedSession: ExporterSession) async {
        session = startedSession
        route = .main
        selectedTab = .home
        pairingCode = nil
        pairingExpiresAt = nil
        await persistDashboard()
        await refreshDashboard(showErrors: false)
    }

    func resetConnectionFlow() {
        stateReadRevision &+= 1
        pairingTask?.cancel()
        connectionStage = .intro
        pairingCode = nil
        pairingExpiresAt = nil
    }

    private func startPairingStatusPoll() {
        pairingTask?.cancel()
        pairingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let expiry = self.pairingExpiresAt, expiry <= Date() {
                    self.alert = AppAlert(
                        title: "Pairing code expired",
                        message: "Generate a new code to continue."
                    )
                    self.connectionStage = .number
                    return
                }

                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self.pollPairingStatus(showErrors: false)
                if self.connectionStage == .groups { return }
            }
        }
    }

    private func pollPairingStatus(showErrors: Bool) async {
        guard !isWorking, !isUnlinkingWhatsApp, let userID = user?.id else { return }
        let generation = accountScopeGeneration
        let readRevision = stateReadRevision
        let stage = connectionStage
        do {
            let response = try await api.session()
            guard isCurrentPairingRead(userID: userID, generation: generation, revision: readRevision, stage: stage),
                  let currentSession = response else { return }
            let ownedSession = try validatedSession(currentSession)
            if currentSession.isLinked {
                let currentGroups = try await api.groups()
                guard isCurrentPairingRead(userID: userID, generation: generation, revision: readRevision, stage: stage) else { return }
                session = ownedSession
                groups = currentGroups
                connectionStage = .groups
                pairingTask?.cancel()
            } else {
                session = ownedSession
            }
        } catch {
            guard isCurrentPairingRead(userID: userID, generation: generation, revision: readRevision, stage: stage) else { return }
            if showErrors {
                await handle(error, title: "Unable to check link")
            }
        }
    }

    private func isCurrentPairingRead(userID: UUID, generation: UInt64, revision: UInt64, stage: ConnectionStage) -> Bool {
        !Task.isCancelled && !isWorking && !isUnlinkingWhatsApp
            && user?.id == userID && accountScopeGeneration == generation
            && stateReadRevision == revision && connectionStage == stage
    }
}

