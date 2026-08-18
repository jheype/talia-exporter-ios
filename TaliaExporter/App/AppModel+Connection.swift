import Foundation

extension AppModel {
    func advanceFromIntro() {
        connectionStage = .number
    }

    func goBackInConnectionFlow() {
        guard connectionStage != .intro else { return }
        if connectionStage == .pairing {
            pairingTask?.cancel()
            pairingCode = nil
            pairingExpiresAt = nil
        }
        connectionStage = connectionStage.previous
    }

    func requestPairingCode(phoneNumber: String) async {
        guard !isWorking else { return }
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
            session = response.session
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

        do {
            let selected = groups.filter(\.isSelected).map(\.id)
            // The backend atomically enables capture with the first non-empty
            // selection, then starts history only after that transaction commits.
            // A second capture request recreated the exact window in which early
            // history pages could be acknowledged but discarded.
            let startedSession = try await api.saveSelection(groupJIDs: selected)
            guard startedSession.captureEnabled else {
                throw APIError(
                    statusCode: nil,
                    code: "CLIENT.ATOMIC_CAPTURE_NOT_ENABLED",
                    message: "Exporter did not enable capture with the selected groups. Update the backend before using this app build."
                )
            }
            session = startedSession
            route = .main
            selectedTab = .home
            pairingCode = nil
            pairingExpiresAt = nil
            await refreshDashboard(showErrors: false)
        } catch {
            await handle(error, title: "Unable to start capture")
        }
    }

    func resetConnectionFlow() {
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

                try? await Task.sleep(for: .seconds(2))
                await self.pollPairingStatus(showErrors: false)
                if self.connectionStage == .groups { return }
            }
        }
    }

    private func pollPairingStatus(showErrors: Bool) async {
        do {
            guard let currentSession = try await api.session() else { return }
            session = currentSession
            if currentSession.isLinked {
                groups = try await api.groups()
                connectionStage = .groups
                pairingTask?.cancel()
            }
        } catch {
            if showErrors {
                await handle(error, title: "Unable to check link")
            }
        }
    }
}