import Foundation
import UIKit
import UserNotifications

struct SAPushTestResult: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

@MainActor
final class SuperAdminPortalStore: ObservableObject {
    enum Phase: Equatable { case signedOut, loading, challenge, enrolment, ready }
    @Published var phase: Phase = .signedOut
    @Published var selectedSection: SuperAdminSection = .overview
    @Published var selectedTab = 0
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published var busy = false
    @Published var enrolment: SAValue = .null
    @Published var pushStatus = "Alerts are off on this phone"
    @Published var pushEnabled = false
    @Published var minimumSeverity = "high"
    @Published var alertToOpen: String?
    @Published var sessionRevision = UUID()
    private(set) var ownerID: UUID?
    private(set) var api: SuperAdminAPI?
    private var challenge = ""
    private var challengeRoute = "auth/mfa-login"
    private var deviceToken: String?
    private var resuming = false
    var email: String { api?.credentials?.email ?? "" }

    func setOwner(_ owner: UUID?) {
        guard ownerID != owner else { return }
        api?.retire()
        ownerID = owner; sessionRevision = UUID(); phase = .signedOut; busy = false; resuming = false
        challenge = ""; enrolment = .null; errorMessage = nil; notice = nil; alertToOpen = nil
        pushEnabled = false; pushStatus = "Alerts are off on this phone"; selectedSection = .overview; selectedTab = 0
        api = owner.map { SuperAdminAPI(owner: $0) }
        api?.onAccessLost = { [weak self] message in
            self?.sessionRevision = UUID(); self?.phase = .signedOut; self?.errorMessage = message
            self?.resuming = false; self?.busy = false; self?.pushEnabled = false
        }
    }
    func start() { Task { await resume() } }
    func dismissTransientUI() {}
    func resume() async {
        guard let api, api.credentials != nil, phase != .enrolment, !resuming else { return }
        let scope = sessionRevision; resuming = true
        if phase != .ready { phase = .loading }
        defer { if scope == sessionRevision { resuming = false } }
        do {
            _ = try await api.request("admin/session")
            guard scope == sessionRevision else { return }
            phase = .ready; pushEnabled = api.credentials?.wantsPush ?? false
            minimumSeverity = api.credentials?.minimumSeverity ?? "high"
            if pushEnabled {
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                if settings.authorizationStatus == .denied { pushStatus = "Enable notifications in iPhone Settings" }
                else { UIApplication.shared.registerForRemoteNotifications() }
            }
        } catch {
            guard scope == sessionRevision else { return }
            phase = .signedOut; errorMessage = error.localizedDescription
        }
    }
    func signIn(email: String, password: String) async {
        guard let api, !busy else { return }
        let scope = sessionRevision; busy = true; errorMessage = nil
        defer { if scope == sessionRevision { busy = false } }
        do {
            let result = try await api.request("auth/login", method: "POST", body: ["email": .string(email.trimmingCharacters(in: .whitespacesAndNewlines)), "password": .string(password)], authenticated: false)
            guard scope == sessionRevision else { return }
            if result["requires_mfa"].flag || result["requires_email_2fa"].flag {
                challenge = result["challenge_token"].text
                challengeRoute = result["requires_mfa"].flag ? "auth/mfa-login" : "auth/email-otp-login"
                phase = .challenge
            } else { try await completeSignIn(result) }
        } catch { if scope == sessionRevision { errorMessage = error.localizedDescription } }
    }
    var challengePrompt: String { challengeRoute == "auth/mfa-login" ? "Enter the six-digit code from your authenticator." : "Enter the verification code sent to your email." }
    func verify(code: String) async {
        guard let api, !busy else { return }
        let scope = sessionRevision; busy = true; errorMessage = nil
        defer { if scope == sessionRevision { busy = false } }
        do {
            let result = try await api.request(challengeRoute, method: "POST", body: ["challenge_token": .string(challenge), "code": .string(code)], authenticated: false)
            guard scope == sessionRevision else { return }; try await completeSignIn(result)
        } catch { if scope == sessionRevision { errorMessage = error.localizedDescription } }
    }
    private func completeSignIn(_ result: SAValue) async throws {
        guard let api else { throw CancellationError() }
        try api.acceptLogin(result); challenge = ""
        if result["mfa_enrollment_required"].flag { phase = .enrolment }
        else {
            _ = try await api.request("admin/session"); phase = .ready
            notice = nil; pushEnabled = api.credentials?.wantsPush ?? false
            if pushEnabled { UIApplication.shared.registerForRemoteNotifications() }
        }
    }
    func enrol(password: String) async {
        await perform {
            guard let api = self.api else { throw CancellationError() }
            let value = try await api.request("auth/mfa/enroll", method: "POST", body: ["password": .string(password)])
            self.enrolment = value
        }
    }
    func verifyEnrolment(code: String) async {
        await perform {
            guard let api = self.api else { throw CancellationError() }
            _ = try await api.request("auth/mfa/verify-enroll", method: "POST", body: ["code": .string(code)])
            try await api.signOut(); self.enrolment = .null; self.phase = .signedOut
            self.notice = "Authenticator enabled. Sign in again and enter a fresh code."
        }
    }
    func signOut() async {
        await perform {
            try await self.api?.signOut()
            self.phase = .signedOut; self.enrolment = .null; self.challenge = ""; self.pushEnabled = false
            self.alertToOpen = nil; self.sessionRevision = UUID(); self.busy = false
        }
    }
    func perform(_ operation: () async throws -> Void) async {
        guard !busy else { return }; busy = true; errorMessage = nil
        let scope = sessionRevision
        defer { if scope == sessionRevision { busy = false } }
        do { try await operation() } catch { if scope == sessionRevision { errorMessage = error.localizedDescription } }
    }
    func enablePush() async {
        await perform {
            guard let api = self.api, var saved = api.credentials, self.phase == .ready else { return }
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            guard granted else { self.pushStatus = "Enable notifications in iPhone Settings"; return }
            saved.wantsPush = true; saved.minimumSeverity = self.minimumSeverity; try api.save(saved)
            self.pushEnabled = true; self.pushStatus = "Registering this phone…"
            UIApplication.shared.registerForRemoteNotifications()
            if let token = self.deviceToken { await self.receiveDeviceToken(token) }
        }
    }
    func receiveDeviceToken(_ token: String) async {
        deviceToken = token
        guard let api, let saved = api.credentials, saved.wantsPush, phase == .ready else { return }
        let scope = sessionRevision
        do {
            let environment = Bundle.main.object(forInfoDictionaryKey: "TaliaPushEnvironment") as? String ?? "development"
            let result = try await api.request("admin/mobile/devices/\(saved.deviceID)", method: "PUT", body: ["token": .string(token), "environment": .string(environment == "production" ? "production" : "sandbox"), "minimum_severity": .string(saved.minimumSeverity)])
            guard scope == sessionRevision else { return }
            pushStatus = result["push_configured"].flag ? "This phone is registered for security alerts" : "Phone registered. Apple push setup is required on the CRM server."
        } catch { if scope == sessionRevision { pushStatus = "Registration failed: \(error.localizedDescription)" } }
    }
    func pushRegistrationFailed(_ message: String) { if pushEnabled { pushStatus = "Apple registration failed: \(message)" } }
    func disablePush() async {
        await perform {
            guard let api = self.api, var saved = api.credentials else { return }
            _ = try await api.request("admin/mobile/devices/\(saved.deviceID)", method: "DELETE")
            saved.wantsPush = false; try api.save(saved); self.pushEnabled = false; self.pushStatus = "Alerts are off on this phone"
        }
    }
    func testPush() async -> SAPushTestResult {
        guard !busy else {
            return SAPushTestResult(title: "Test not started", message: "Another operation is still running. Wait for it to finish, then try again.")
        }
        notice = nil; errorMessage = nil
        guard let api, let saved = api.credentials, phase == .ready else {
            let message = "Sign in to SA Portal again before sending a test notification."
            errorMessage = message
            return SAPushTestResult(title: "Test not sent", message: message)
        }
        let scope = sessionRevision
        let configuredEnvironment = Bundle.main.object(forInfoDictionaryKey: "TaliaPushEnvironment") as? String ?? "development"
        let environment = configuredEnvironment == "production" ? "Production" : "Sandbox"
        let bundleID = Bundle.main.bundleIdentifier ?? "Unknown"
        let context = "App: \(bundleID)\nAPNs environment: \(environment)"
        busy = true
        defer { if scope == sessionRevision { busy = false } }
        do {
            let result = try await api.request("admin/mobile/devices/\(saved.deviceID)/test", method: "POST", body: [:])
            guard scope == sessionRevision else { throw CancellationError() }
            guard result["accepted"].flag else {
                let reason = result["message"].text
                throw SARequestError(status: 502, code: "PUSH_NOT_ACCEPTED", message: reason.isEmpty ? "The server did not confirm that Apple accepted this test." : reason)
            }
            let message = "Apple accepted the test push. Check this iPhone's notifications. Acceptance does not confirm delivery to the phone."
            notice = message
            return SAPushTestResult(title: "Test accepted by Apple", message: "\(message)\n\n\(context)")
        } catch {
            let message = error.localizedDescription
            if scope == sessionRevision { errorMessage = message }
            return SAPushTestResult(title: "Test failed", message: "\(message)\n\n\(context)")
        }
    }
    func openAlert(_ id: String) { guard UUID(uuidString: id) != nil else { return }; selectedTab = 1; alertToOpen = id }
}

@MainActor
final class SANotificationRouter: ObservableObject {
    static let shared = SANotificationRouter()
    @Published var pendingAlertID: String?
    func receive(_ info: [AnyHashable: Any]) {
        guard info["kind"] as? String == "sa-security", let id = info["alert_id"] as? String, UUID(uuidString: id) != nil else { return }
        pendingAlertID = id
    }
}
