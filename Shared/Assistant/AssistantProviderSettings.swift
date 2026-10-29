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

struct KeychainAssistantCredentialStore: AssistantCredentialStore {
    private var service: String {
        let base = "org.davidjensenius.FluxKlang.assistant"
        return AppPersistence.isTesting ? "\(base).\(AppPersistence.directory.lastPathComponent)" : base
    }

    func value(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func setValue(_ value: String, for account: String) throws {
        try removeValue(for: account)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(value.utf8)
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AssistantCredentialError.keychain(status)
        }
    }

    func removeValue(for account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AssistantCredentialError.keychain(status)
        }
    }
}

enum AssistantCredentialError: Error {
    case keychain(OSStatus)
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
        credentials: any AssistantCredentialStore = KeychainAssistantCredentialStore()
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
