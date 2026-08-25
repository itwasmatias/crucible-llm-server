import Foundation
import Security

enum APIKeyStoreError: LocalizedError {
    case invalidKey
    case storageFailure

    var errorDescription: String? {
        switch self {
        case .invalidKey:
            return "API key must contain 16 through 256 printable ASCII characters without spaces"
        case .storageFailure:
            return "Secure API key storage failed"
        }
    }
}

final class APIKeyStore {
    private let service = "com.crucible.llmserver.missionaryx"
    private let account = "api-bearer-key-v0.1"

    func save(_ key: String) throws {
        let value = try validatedData(for: key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updateAttributes: [String: Any] = [
            kSecValueData as String: value,
        ]

        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            updateAttributes as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw APIKeyStoreError.storageFailure
        }

        var addQuery = query
        addQuery[kSecValueData as String] = value
        addQuery[kSecAttrAccessible as String] =
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess else {
            throw APIKeyStoreError.storageFailure
        }
    }

    func load() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw APIKeyStoreError.storageFailure
        }
        _ = try validatedData(for: key)
        return key
    }

    func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw APIKeyStoreError.storageFailure
        }
    }

    private func validatedData(for key: String) throws -> Data {
        let keyBytes = Array(key.utf8)
        guard keyBytes.count >= MissionaryXLimits.minimumCredentialBytes,
              keyBytes.count <= MissionaryXLimits.maximumCredentialBytes,
              keyBytes.allSatisfy({ $0 >= 0x21 && $0 <= 0x7e }) else {
            throw APIKeyStoreError.invalidKey
        }
        return Data(keyBytes)
    }
}
