import Foundation
import Security

enum DeepSeekConfigurationState: String {
    case pending
    case ready
}

struct DeepSeekConfiguration: Equatable, Sendable {
    let baseURL: String
    let model: String
}

protocol ProviderSecretStoring: Sendable {
    func save(_ data: Data, service: String, account: String) throws
    func read(service: String, account: String) throws -> Data
    func remove(service: String, account: String) throws
}

enum ProviderSecretStoreError: Error, Equatable, CustomStringConvertible {
    case unavailable
    case writeFailed
    case readFailed
    case deleteFailed

    var description: String {
        switch self {
        case .unavailable: return "provider credential unavailable"
        case .writeFailed: return "provider credential write failed"
        case .readFailed: return "provider credential read failed"
        case .deleteFailed: return "provider credential delete failed"
        }
    }
}

struct KeychainProviderSecretStore: ProviderSecretStoring, Sendable {
    func save(_ data: Data, service: String, account: String) throws {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(match as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw ProviderSecretStoreError.writeFailed
        }
        var add = match
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
            throw ProviderSecretStoreError.writeFailed
        }
    }

    func read(service: String, account: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { throw ProviderSecretStoreError.unavailable }
        guard status == errSecSuccess, let data = item as? Data else {
            throw ProviderSecretStoreError.readFailed
        }
        return data
    }

    func remove(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ProviderSecretStoreError.deleteFailed
        }
    }
}

struct KeychainProviderCredentialSource: ProviderCredentialSource, Sendable {
    private let store: any ProviderSecretStoring
    private let service: String
    private let account: String

    init(store: any ProviderSecretStoring, service: String, account: String) {
        self.store = store
        self.service = service
        self.account = account
    }

    func credential() throws -> ProviderCredential {
        let data = try store.read(service: service, account: account)
        guard data.count <= ProviderLimits.maximumCredentialBytes,
              let value = String(data: data, encoding: .utf8) else {
            throw ProviderConfigurationError.invalidCredential
        }
        return try ProviderCredential(value)
    }
}

final class DeepSeekSecureConfigurationStore: @unchecked Sendable {
    static let keychainService = "com.daaixz.wuji.provider.deepseek"
    static let keychainAccount = "api-key"

    private enum Key {
        static let state = "wuji.deepseek.configuration.state"
        static let baseURL = "wuji.deepseek.configuration.base-url"
        static let model = "wuji.deepseek.configuration.model"
    }

    private let defaults: UserDefaults
    private let secrets: any ProviderSecretStoring

    init(
        defaults: UserDefaults = .standard,
        secrets: any ProviderSecretStoring = KeychainProviderSecretStore()
    ) {
        self.defaults = defaults
        self.secrets = secrets
    }

    func save(baseURL: String, model: String, apiKey: String) throws {
        try DeepSeekConfigurationValidator.validate(baseURL: baseURL, model: model)
        let credential = try ProviderCredential(apiKey)
        let credentialData = try credential.withValue { value -> Data in
            guard let data = value.data(using: .utf8) else {
                throw ProviderConfigurationError.invalidCredential
            }
            return data
        }

        defaults.set(baseURL, forKey: Key.baseURL)
        defaults.set(model, forKey: Key.model)
        defaults.set(DeepSeekConfigurationState.pending.rawValue, forKey: Key.state)
        guard defaults.synchronize() else { throw ProviderSecretStoreError.writeFailed }

        try secrets.save(
            credentialData,
            service: Self.keychainService,
            account: Self.keychainAccount
        )
        defaults.set(DeepSeekConfigurationState.ready.rawValue, forKey: Key.state)
        guard defaults.synchronize() else {
            defaults.set(DeepSeekConfigurationState.pending.rawValue, forKey: Key.state)
            _ = defaults.synchronize()
            try? secrets.remove(
                service: Self.keychainService,
                account: Self.keychainAccount
            )
            throw ProviderSecretStoreError.writeFailed
        }
    }

    func load() throws -> DeepSeekConfiguration {
        guard defaults.string(forKey: Key.state) == DeepSeekConfigurationState.ready.rawValue,
              let baseURL = defaults.string(forKey: Key.baseURL),
              let model = defaults.string(forKey: Key.model) else {
            throw ProviderSecretStoreError.unavailable
        }
        try DeepSeekConfigurationValidator.validate(baseURL: baseURL, model: model)
        _ = try credentialSource().credential()
        return DeepSeekConfiguration(baseURL: baseURL, model: model)
    }

    func credentialSource() -> KeychainProviderCredentialSource {
        KeychainProviderCredentialSource(
            store: secrets,
            service: Self.keychainService,
            account: Self.keychainAccount
        )
    }

    func makeProvider(
        transport: any ProviderTransport,
        attemptStore: any ProviderAttemptRecording,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws -> DeepSeekProvider {
        let configuration = try load()
        return try DeepSeekProvider(
            baseURL: configuration.baseURL,
            model: configuration.model,
            credentialSource: credentialSource(),
            transport: transport,
            attemptStore: attemptStore,
            now: now
        )
    }
}
