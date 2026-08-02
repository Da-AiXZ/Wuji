import Foundation
import XCTest
@testable import Wuji

final class WujiStageASecureConfigurationTests: XCTestCase {
    func testRealKeychainRoundTripUsesDataItemAndDeletesIt() throws {
        let store = KeychainProviderSecretStore()
        let service = "com.daaixz.wuji.tests." + UUID().uuidString
        let account = "credential"
        let value = Data((UUID().uuidString + UUID().uuidString).utf8)
        defer { try? store.remove(service: service, account: account) }

        try store.save(value, service: service, account: account)
        XCTAssertEqual(try store.read(service: service, account: account), value)
        try store.remove(service: service, account: account)
        XCTAssertThrowsError(try store.read(service: service, account: account)) {
            XCTAssertEqual($0 as? ProviderSecretStoreError, .unavailable)
        }
    }

    func testConfigurationReachesReplaceableProviderWithoutPersistingSecret() throws {
        let suite = "WujiStageAConfigurationTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = MemoryProviderSecretStore()
        let store = DeepSeekSecureConfigurationStore(defaults: defaults, secrets: secrets)
        let apiKey = UUID().uuidString + UUID().uuidString

        try store.save(
            baseURL: "https://api.deepseek.com/v1",
            model: "deepseek-chat",
            apiKey: apiKey
        )
        let persisted = try JSONSerialization.data(
            withJSONObject: defaults.dictionaryRepresentation(),
            options: [.sortedKeys]
        )
        XCTAssertFalse(String(decoding: persisted, as: UTF8.self).contains(apiKey))
        XCTAssertFalse(CommandLine.arguments.contains { $0.contains(apiKey) })
        let credential = try store.credentialSource().credential()
        XCTAssertEqual(try credential.withValue { $0 }, apiKey)

        let provider = try store.makeProvider(
            transport: NeverStageATransport(),
            attemptStore: StageAAttemptStore()
        )
        XCTAssertEqual(provider.providerID, "deepseek")
        XCTAssertEqual(try store.load().model, "deepseek-chat")
    }

    func testFailedKeychainWriteLeavesConfigurationPendingAndUnavailable() throws {
        let suite = "WujiStageAPendingTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DeepSeekSecureConfigurationStore(
            defaults: defaults,
            secrets: FailingProviderSecretStore()
        )
        XCTAssertThrowsError(try store.save(
            baseURL: "https://api.deepseek.com/v1",
            model: "deepseek-chat",
            apiKey: UUID().uuidString
        ))
        XCTAssertThrowsError(try store.load()) {
            XCTAssertEqual($0 as? ProviderSecretStoreError, .unavailable)
        }

        let categories: [(KeychainOperationFailure, KeychainStatusCategory)] = [
            (KeychainOperationFailure(operation: .update, status: -34018), .missingEntitlement),
            (KeychainOperationFailure(operation: .add, status: -25291), .notAvailable),
            (KeychainOperationFailure(operation: .copyMatching, status: -25308), .interactionNotAllowed),
            (KeychainOperationFailure(operation: .delete, status: -50), .invalidParameter),
            (KeychainOperationFailure(operation: .update, status: -25293), .authenticationFailed),
            (KeychainOperationFailure(operation: .add, status: -25243), .noAccess)
        ]
        for (failure, expectedCategory) in categories {
            XCTAssertEqual(failure.category, expectedCategory)
        }
        for operation in KeychainOperation.allCases {
            let failure = KeychainOperationFailure(operation: operation, status: -50)
            XCTAssertEqual(failure.operation, operation)
            XCTAssertEqual(failure.status, -50)
            XCTAssertEqual(failure.category, .invalidParameter)
        }
        let unknown = KeychainOperationFailure(operation: .copyMatching, status: -12345)
        XCTAssertEqual(unknown.status, -12345)
        XCTAssertEqual(unknown.category, .unknown)
        XCTAssertEqual(unknown.description, "operation=copy_matching status=-12345 category=unknown")
    }

    func testInvalidBaseURLAndModelRejectBeforeSecretPersistence() throws {
        let suite = "WujiStageAValidationTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = MemoryProviderSecretStore()
        let store = DeepSeekSecureConfigurationStore(defaults: defaults, secrets: secrets)

        XCTAssertThrowsError(try store.save(
            baseURL: "http://api.deepseek.com/v1",
            model: "deepseek-chat",
            apiKey: UUID().uuidString
        )) { XCTAssertEqual($0 as? ProviderConfigurationError, .invalidBaseURL) }
        XCTAssertThrowsError(try store.save(
            baseURL: "https://api.deepseek.com/v1",
            model: "deepseek-chat\n",
            apiKey: UUID().uuidString
        )) { XCTAssertEqual($0 as? ProviderConfigurationError, .invalidModel) }
        XCTAssertThrowsError(try store.credentialSource().credential()) {
            XCTAssertEqual($0 as? ProviderSecretStoreError, .unavailable)
        }
    }

    func testExactNegativeScanSentinelUsesKeychainAndLeavesNoPersistentSecret() throws {
        let suite = "WujiStageAExactNegativeScan." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = KeychainProviderSecretStore()
        let store = DeepSeekSecureConfigurationStore(defaults: defaults, secrets: secrets)
        let apiKey = ProviderDigest.sha256Hex("stage-a-keychain-negative-scan-sentinel")
        let diagnostic = KeychainOperationFailure(operation: .delete, status: -34018)
        XCTAssertEqual(
            diagnostic.description,
            "operation=delete status=-34018 category=missing_entitlement"
        )
        for forbidden in [
            apiKey,
            DeepSeekSecureConfigurationStore.keychainService,
            DeepSeekSecureConfigurationStore.keychainAccount,
            "service",
            "account",
            "access_group",
            "query",
            "data"
        ] {
            XCTAssertFalse(diagnostic.description.contains(forbidden))
        }
        defer {
            try? secrets.remove(
                service: DeepSeekSecureConfigurationStore.keychainService,
                account: DeepSeekSecureConfigurationStore.keychainAccount
            )
        }

        try store.save(
            baseURL: "https://api.deepseek.com/v1",
            model: "deepseek-chat",
            apiKey: apiKey
        )
        _ = try store.load()
        let persisted = try JSONSerialization.data(
            withJSONObject: defaults.dictionaryRepresentation(),
            options: [.sortedKeys]
        )
        XCTAssertFalse(String(decoding: persisted, as: UTF8.self).contains(apiKey))
        XCTAssertFalse(CommandLine.arguments.contains { $0.contains(apiKey) })
        try secrets.remove(
            service: DeepSeekSecureConfigurationStore.keychainService,
            account: DeepSeekSecureConfigurationStore.keychainAccount
        )
        XCTAssertThrowsError(try secrets.read(
            service: DeepSeekSecureConfigurationStore.keychainService,
            account: DeepSeekSecureConfigurationStore.keychainAccount
        ))
    }
}

private final class MemoryProviderSecretStore: ProviderSecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func save(_ data: Data, service: String, account: String) throws {
        lock.lock()
        values[service + "\u{0}" + account] = data
        lock.unlock()
    }

    func read(service: String, account: String) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard let data = values[service + "\u{0}" + account] else {
            throw ProviderSecretStoreError.unavailable
        }
        return data
    }

    func remove(service: String, account: String) throws {
        lock.lock()
        values.removeValue(forKey: service + "\u{0}" + account)
        lock.unlock()
    }
}

private struct FailingProviderSecretStore: ProviderSecretStoring {
    func save(_ data: Data, service: String, account: String) throws {
        throw ProviderSecretStoreError.writeFailed
    }

    func read(service: String, account: String) throws -> Data {
        throw ProviderSecretStoreError.unavailable
    }

    func remove(service: String, account: String) throws {}
}

private actor NeverStageATransport: ProviderTransport {
    func send(_ request: ProviderHTTPRequest) async throws -> ProviderHTTPResponse {
        XCTFail("Stage A configuration must not perform network I/O")
        throw ProviderTransportError.network
    }
}

private actor StageAAttemptStore: ProviderAttemptRecording {
    func record(_ evidence: ProviderAttemptEvidence) async throws {}
}
