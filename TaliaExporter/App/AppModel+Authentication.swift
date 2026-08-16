import Foundation

extension AppModel {
    func signIn(email: String, password: String) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        do {
            user = try await api.signIn(
                email: email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                password: password
            )

            if let currentSession = try await api.session(), currentSession.isLinked {
                session = currentSession
                route = .main
                await refreshDashboard(showErrors: false)
            } else {
                resetConnectionFlow()
                route = .connection
            }
        } catch {
            present(error, title: "Sign-in failed")
        }
    }

    func signOut() async {
        guard !isWorking else { return }
        isWorking = true
        pairingTask?.cancel()
        selectionTask?.cancel()
        defer { isWorking = false }

        try? await api.unregisterDevices()
        do {
            try await api.signOut()
        } catch {
            // Local sign-out must still complete when the network is unavailable.
        }
        await resetAuthenticatedState()
    }
}
