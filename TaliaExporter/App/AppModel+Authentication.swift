import Foundation

extension AppModel {
    func signIn(email: String, password: String) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        do {
            let previousUserID = user?.id
            await clearAccountOwnedState(for: previousUserID)
            user = nil
            route = .signedOut

            let loginUser = try await api.signIn(
                email: email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                password: password
            )
            let confirmedUser = try await api.currentUser()
            guard confirmedUser.id == loginUser.id else {
                throw APIError(
                    statusCode: nil,
                    code: Self.accountScopeMismatchCode,
                    message: "The authenticated account did not match the login response."
                )
            }
            user = confirmedUser

            if let currentSession = try await api.session(), currentSession.isLinked {
                session = try validatedSession(currentSession)
                route = .main
                await refreshDashboard(showErrors: false)
            } else {
                await clearAccountOwnedState(for: confirmedUser.id)
                resetConnectionFlow()
                route = .connection
            }
            resumeWorkspaceURL()
        } catch {
            await handle(error, title: "Sign-in failed")
        }
    }

    func signOut() async {
        guard !isWorking else { return }
        isWorking = true
        pairingTask?.cancel()
        selectionTask?.cancel()
        defer { isWorking = false }

        pendingWorkspaceURL = nil
        await calendarSync.setEnabled(false)
        try? await api.unregisterDevices()
        do {
            try await api.signOut()
        } catch {
            // Local sign-out must still complete when the network is unavailable.
        }
        await resetAuthenticatedState()
    }
}
