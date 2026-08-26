import CryptoKit
import Foundation
import Security

struct CachedDashboard: Codable, Sendable {
    let session: ExporterSession
    let groups: [ExportGroup]
    let events: [CaptureEvent]
}

protocol DashboardCaching: Sendable {
    func load(for userID: UUID) async -> CachedDashboard?
    func save(_ dashboard: CachedDashboard, for userID: UUID) async
    func clear(for userID: UUID) async
}

actor SecureDashboardCache: DashboardCaching {
    private let directoryURL: URL
    private let legacyFileURL: URL
    private let service = "com.talia.exporter"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileManager: FileManager = .default) {
        let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "TaliaExporter", directoryHint: .isDirectory)
        try? fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        directoryURL = directory
        legacyFileURL = directory.appending(path: "dashboard.cache")

        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601
    }

    func load(for userID: UUID) async -> CachedDashboard? {
        let scopedStore = keyStore(for: userID)
        if let cached = decode(fileURL: fileURL(for: userID), keyStore: scopedStore) {
            guard cached.session.userID == userID else {
                await clear(for: userID)
                return nil
            }
            return cached
        }

        // One-time migration from builds that used one global cache. The
        // session owner is checked before any cached groups are exposed.
        let legacyStore = KeyStore(service: service, account: "dashboard-cache-key")
        guard let legacy = decode(fileURL: legacyFileURL, keyStore: legacyStore),
              legacy.session.userID == userID else {
            return nil
        }
        await save(legacy, for: userID)
        try? FileManager.default.removeItem(at: legacyFileURL)
        try? legacyStore.deleteKey()
        return legacy
    }

    func save(_ dashboard: CachedDashboard, for userID: UUID) async {
        guard dashboard.session.userID == userID else { return }
        let keyStore = keyStore(for: userID)
        guard let encoded = try? encoder.encode(dashboard),
              let keyData = try? keyStore.loadOrCreateKey(),
              let sealedBox = try? AES.GCM.seal(encoded, using: SymmetricKey(data: keyData)),
              let combined = sealedBox.combined else {
            return
        }
        try? combined.write(
            to: fileURL(for: userID),
            options: [.atomic, .completeFileProtection]
        )
    }

    func clear(for userID: UUID) async {
        try? FileManager.default.removeItem(at: fileURL(for: userID))
        try? keyStore(for: userID).deleteKey()
    }

    private func decode(fileURL: URL, keyStore: KeyStore) -> CachedDashboard? {
        guard let encrypted = try? Data(contentsOf: fileURL),
              let keyData = try? keyStore.loadOrCreateKey(),
              let sealedBox = try? AES.GCM.SealedBox(combined: encrypted),
              let decrypted = try? AES.GCM.open(sealedBox, using: SymmetricKey(data: keyData)) else {
            return nil
        }
        return try? decoder.decode(CachedDashboard.self, from: decrypted)
    }

    private func fileURL(for userID: UUID) -> URL {
        directoryURL.appending(path: "dashboard-\(cacheScope(for: userID)).cache")
    }

    private func keyStore(for userID: UUID) -> KeyStore {
        KeyStore(service: service, account: "dashboard-cache-key-\(cacheScope(for: userID))")
    }

    private func cacheScope(for userID: UUID) -> String {
        userID.uuidString.lowercased()
    }
}

actor InMemoryDashboardCache: DashboardCaching {
    private var values: [UUID: CachedDashboard] = [:]

    func load(for userID: UUID) async -> CachedDashboard? { values[userID] }
    func save(_ dashboard: CachedDashboard, for userID: UUID) async {
        guard dashboard.session.userID == userID else { return }
        values[userID] = dashboard
    }
    func clear(for userID: UUID) async { values[userID] = nil }
}

private struct KeyStore: Sendable {
    let service: String
    let account: String

    func loadOrCreateKey() throws -> Data {
        if let existing = try loadKey() {
            return existing
        }

        var data = Data(count: 32)
        let status = data.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, baseAddress)
        }
        guard status == errSecSuccess else {
            throw KeyStoreError.randomGenerationFailed
        }
        try saveKey(data)
        return data
    }

    func deleteKey() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeyStoreError.unexpectedStatus(status)
        }
    }

    private func loadKey() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeyStoreError.unexpectedStatus(status)
        }
        return data
    }

    private func saveKey(_ data: Data) throws {
        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeyStoreError.unexpectedStatus(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

private enum KeyStoreError: Error {
    case randomGenerationFailed
    case unexpectedStatus(OSStatus)
}
