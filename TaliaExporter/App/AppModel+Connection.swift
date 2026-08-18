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
            let response = try await api.requestPairingCode(
                phoneNumber: phoneNumber
            )

            let digits = response.code.filter(\.isNumber)

            guard digits.count == 8 else {
                throw APIError(
                    statusCode: nil,
                    code: "CLIENT.INVALID_PAIRING_CODE",
                    message: "The service returned an invalid pairing code."
                )
            }

            session = response.session
            pairingCode = digits
            pairingExpiresAt = response.expiresAt
            connectionStage = .pairing
            startPairingStatusPoll()
        } catch {
            await handle(
                error,
                title: "Unable to generate code"
            )
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
            session = try await api.saveSelection(groupJIDs: selected)
            session = try await api.setCaptureEnabled(true)
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
