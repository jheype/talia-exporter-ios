import CryptoKit
import Foundation
import Security

struct CachedDashboard: Codable, Sendable {
    let session: ExporterSession
    let groups: [ExportGroup]
    let events: [CaptureEvent]
}

protocol DashboardCaching: Sendable {
    func load() async -> CachedDashboard?
    func save(_ dashboard: CachedDashboard) async
    func clear() async
}

actor SecureDashboardCache: DashboardCaching {
    private let fileURL: URL
    private let keyStore: KeyStore
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
        fileURL = directory.appending(path: "dashboard.cache")
        keyStore = KeyStore(service: "com.talia.exporter", account: "dashboard-cache-key")

        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601
    }

    func load() async -> CachedDashboard? {
        guard let encrypted = try? Data(contentsOf: fileURL),
              let keyData = try? keyStore.loadOrCreateKey(),
              let sealedBox = try? AES.GCM.SealedBox(combined: encrypted),
              let decrypted = try? AES.GCM.open(sealedBox, using: SymmetricKey(data: keyData)) else {
            return nil
        }
        return try? decoder.decode(CachedDashboard.self, from: decrypted)
    }

    func save(_ dashboard: CachedDashboard) async {
        guard let encoded = try? encoder.encode(dashboard),
              let keyData = try? keyStore.loadOrCreateKey(),
              let sealedBox = try? AES.GCM.seal(encoded, using: SymmetricKey(data: keyData)),
              let combined = sealedBox.combined else {
            return
        }
        try? combined.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }

    func clear() async {
        try? FileManager.default.removeItem(at: fileURL)
        try? keyStore.deleteKey()
    }
}

actor InMemoryDashboardCache: DashboardCaching {
    private var value: CachedDashboard?

    func load() async -> CachedDashboard? { value }
    func save(_ dashboard: CachedDashboard) async { value = dashboard }
    func clear() async { value = nil }
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
