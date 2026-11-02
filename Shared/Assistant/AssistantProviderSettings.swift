import Foundation
import Observation
import Security

enum AssistantProvider: String, CaseIterable, Identifiable, Sendable {
    case appleIntelligence
    case githubCopilot
    case deterministic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .appleIntelligence: "Apple Intelligence"
        case .githubCopilot: "GitHub Copilot"
        case .deterministic: "Deterministic local"
        }
    }
}

struct CopilotAssistantConfiguration: Sendable {
    var token: String
    var model: String
}

protocol AssistantCredentialStore: Sendable {
    func value(for account: String) -> String?
    func setValue(_ value: String, for account: String) throws
    func removeValue(for account: String) throws
}

enum AssistantCredentialStores {
    /// A fresh store per default settings instance; shared fixtures must be injected explicitly.
    static var current: any AssistantCredentialStore {
        select(isTesting: AppPersistence.isTesting, production: makeProduction())
    }

    /// Direct production requests still obey process-selected isolation; the mirror is observation only.
    static func makeProduction(mirroring mirror: ProductionAccessAudit? = nil) -> any AssistantCredentialStore {
        ProductionAccessAudit.shared.record(.attempted, for: .credentialStore, mirroring: mirror)
        guard !AppPersistence.isTesting else {
            ProductionAccessAudit.shared.record(.denied, for: .credentialStore, mirroring: mirror)
            return MemoryAssistantCredentialStore()
        }
        ProductionAccessAudit.shared.record(.factoryEvaluated, for: .credentialStore, mirroring: mirror)
        return KeychainAssistantCredentialStore(mirroring: mirror)
    }

    /// Test selection never constructs or accesses the production credential store.
    static func select(
        isTesting: Bool,
        production: @autoclosure () -> any AssistantCredentialStore
    ) -> any AssistantCredentialStore {
        isTesting ? MemoryAssistantCredentialStore() : production()
    }
}

final class MemoryAssistantCredentialStore: AssistantCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    // All mutable state is protected by lock, including reads.
    private var values: [String: String] = [:]

    func value(for account: String) -> String? {
        lock.withLock { values[account] }
    }

    func setValue(_ value: String, for account: String) {
        lock.withLock { values[account] = value }
    }

    func removeValue(for account: String) {
        lock.withLock { values[account] = nil }
    }
}

struct KeychainAssistantCredentialStore: AssistantCredentialStore {
    private let mirror: ProductionAccessAudit?

    init(mirroring mirror: ProductionAccessAudit? = nil) {
        self.mirror = mirror
        ProductionAccessAudit.shared.record(.passiveConstruction, for: .credentialStore, mirroring: mirror)
    }

    private var service: String {
        let base = "org.davidjensenius.FluxKlang.assistant"
        return AppPersistence.isTesting ? "\(base).\(AppPersistence.directory.lastPathComponent)" : base
    }

    func value(for account: String) -> String? {
        ProductionAccessAudit.shared.record(.attempted, for: .credentialStore, mirroring: mirror)
        guard !AppPersistence.isTesting else {
            ProductionAccessAudit.shared.record(.denied, for: .credentialStore, mirroring: mirror)
            // Unavailable under isolation, not evidence that no saved credential exists.
            return nil
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        var result: CFTypeRef?
        ProductionAccessAudit.shared.record(.apiEntered, for: .credentialStore, mirroring: mirror)
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func setValue(_ value: String, for account: String) throws {
        ProductionAccessAudit.shared.record(.attempted, for: .credentialStore, mirroring: mirror)
        guard !AppPersistence.isTesting else {
            ProductionAccessAudit.shared.record(.denied, for: .credentialStore, mirroring: mirror)
            throw AssistantCredentialError.isolationDenied
        }
        try removeValue(for: account)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(value.utf8)
        ]
        ProductionAccessAudit.shared.record(.apiEntered, for: .credentialStore, mirroring: mirror)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AssistantCredentialError.keychain(status)
        }
    }

    func removeValue(for account: String) throws {
        ProductionAccessAudit.shared.record(.attempted, for: .credentialStore, mirroring: mirror)
        guard !AppPersistence.isTesting else {
            ProductionAccessAudit.shared.record(.denied, for: .credentialStore, mirroring: mirror)
            throw AssistantCredentialError.isolationDenied
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        ProductionAccessAudit.shared.record(.apiEntered, for: .credentialStore, mirroring: mirror)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AssistantCredentialError.keychain(status)
        }
    }
}

enum AssistantCredentialError: Error, Equatable, Sendable {
    case keychain(OSStatus)
    case isolationDenied
}

@MainActor
@Observable
final class AssistantProviderSettings {
    private static let providerKey = "assistant.provider"
    private static let modelKey = "assistant.copilot.model"
    private static let tokenAccount = "github-copilot-token"
    private static let defaultModel = "gpt-4o"

    var provider: AssistantProvider {
        didSet { defaults.set(provider.rawValue, forKey: Self.providerKey) }
    }
    var copilotModel: String {
        didSet { defaults.set(copilotModel, forKey: Self.modelKey) }
    }
    private(set) var hasCopilotToken: Bool
    private(set) var credentialError: String?

    private let defaults: UserDefaults
    private let credentials: any AssistantCredentialStore

    init(
        defaults: UserDefaults = AppPersistence.defaults,
        credentials: any AssistantCredentialStore = AssistantCredentialStores.current
    ) {
        self.defaults = defaults
        self.credentials = credentials
        provider = defaults.string(forKey: Self.providerKey)
            .flatMap(AssistantProvider.init(rawValue:)) ?? .appleIntelligence
        copilotModel = defaults.string(forKey: Self.modelKey) ?? Self.defaultModel
        hasCopilotToken = credentials.value(for: Self.tokenAccount) != nil
    }

    func saveCopilotToken(_ token: String) {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        do {
            try credentials.setValue(token, for: Self.tokenAccount)
            hasCopilotToken = true
            credentialError = nil
        } catch {
            credentialError = error.localizedDescription
        }
    }

    func removeCopilotToken() {
        do {
            try credentials.removeValue(for: Self.tokenAccount)
            hasCopilotToken = false
            credentialError = nil
        } catch {
            credentialError = error.localizedDescription
        }
    }

    func copilotConfiguration() -> CopilotAssistantConfiguration? {
        guard let token = credentials.value(for: Self.tokenAccount) else { return nil }
        let model = copilotModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return CopilotAssistantConfiguration(
            token: token,
            model: model.isEmpty ? Self.defaultModel : model
        )
    }
}
