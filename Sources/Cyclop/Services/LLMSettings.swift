import Foundation
import Security

/// Where the converter's language model lives.
///
/// Two families, by the shape of their API. Claude goes through Anthropic's
/// own SDK. Everything else speaks the OpenAI shape — OpenAI itself, Gemini,
/// OpenRouter and the local servers alike — so one SDK covers them all and
/// "Other" is just an address.
enum LLMProvider: String, CaseIterable, Identifiable {
    case anthropic, openai, gemini, openrouter, ollama, lmstudio, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .anthropic: return "Anthropic (Claude)"
        case .openai: return "OpenAI"
        case .gemini: return "Google Gemini"
        case .openrouter: return "OpenRouter"
        case .ollama: return "Ollama"
        case .lmstudio: return "LM Studio"
        case .custom: return localized("Other (OpenAI-compatible)")
        }
    }

    /// Which SDK the bridge uses — see `bridge.py`.
    var kind: String { self == .anthropic ? "anthropic" : "openai" }

    var defaultBaseURL: String {
        switch self {
        case .anthropic: return "https://api.anthropic.com"
        case .openai: return "https://api.openai.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai/"
        case .openrouter: return "https://openrouter.ai/api/v1"
        case .ollama: return "http://localhost:11434/v1"
        case .lmstudio: return "http://localhost:1234/v1"
        case .custom: return ""
        }
    }

    /// Only Claude gets a model filled in: the rest change their line-ups too
    /// often for a name written here to stay right, and the list button asks
    /// the provider itself.
    var defaultModel: String { self == .anthropic ? "claude-opus-5-5" : "" }

    /// Runs on this Mac: no key, no bill, and nothing leaves the machine.
    var isLocal: Bool { self == .ollama || self == .lmstudio }

    /// Local servers take any key, and a custom address may or may not want
    /// one — only the clouds refuse to work without it.
    var needsKey: Bool { !isLocal && self != .custom }
}

/// The converter's language-model settings, as the Settings tab edits them.
///
/// Off unless switched on, and the switch wins over everything else: a key
/// that has been typed in does not turn processing on by being there. With
/// it off the bridge is started without a single model variable in its
/// environment, so markitdown has nothing to call.
@MainActor
final class LLMSettings: ObservableObject {
    @Published var enabled: Bool { didSet { scheduleSave() } }
    @Published var provider: LLMProvider {
        didSet { if provider != oldValue { switchProvider() } }
    }
    @Published var model: String { didSet { scheduleSave() } }
    /// Empty means the provider's own address, shown as the placeholder.
    @Published var baseURL: String { didSet { scheduleSave() } }
    @Published var apiKey: String { didSet { scheduleSave() } }

    /// What the provider offered the last time it was asked.
    @Published private(set) var models: [String] = []
    @Published private(set) var isLoadingModels = false
    @Published private(set) var modelsError: String?

    /// Set while the fields are being filled from storage, so the observers
    /// above do not write back what was just read.
    private var loading = false
    /// The Keychain is asked only when the key is actually needed: a rebuilt
    /// ad-hoc binary is a stranger to it, and an unprompted dialog at launch
    /// for a feature that is off would be the worst moment to meet one.
    private var keyLoaded = false
    private let writes = DebouncedWrite(after: 0.6)

    init() {
        let ai = ConfigStore.shared.ai
        let provider = LLMProvider(rawValue: ai.provider) ?? .anthropic
        let endpoint = ai.endpoints[provider.rawValue]
        enabled = ai.enabled
        self.provider = provider
        model = endpoint?.model ?? provider.defaultModel
        baseURL = endpoint?.baseURL ?? ""
        apiKey = ""
    }

    // MARK: - State

    var effectiveBaseURL: String {
        let typed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? provider.defaultBaseURL : typed
    }

    private var trimmedModel: String { model.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Why processing will not happen even though it is switched on — said
    /// next to the switch rather than discovered on the next conversion.
    /// Read after `loadKey`: until then an empty field says nothing about
    /// what is stored.
    var problem: String? {
        guard enabled else { return nil }
        if effectiveBaseURL.isEmpty { return localized("Enter the API address") }
        if provider.needsKey, trimmedKey.isEmpty { return localized("Add an API key") }
        if trimmedModel.isEmpty { return localized("Choose a model") }
        return nil
    }

    var isReady: Bool { enabled && problem == nil }

    /// The variables `bridge.py` reads. Nil when processing is off or not
    /// configured, and then the bridge runs exactly as it does without AI.
    var environment: [String: String]? {
        guard isReady else { return nil }
        return [
            "CYCLOP_LLM_KIND": provider.kind,
            "CYCLOP_LLM_BASE_URL": effectiveBaseURL,
            "CYCLOP_LLM_MODEL": trimmedModel,
            "CYCLOP_LLM_API_KEY": trimmedKey,
        ]
    }

    /// The same, minus the model: listing is how one picks it.
    private var listingEnvironment: [String: String] {
        loadKey()
        return [
            "CYCLOP_LLM_KIND": provider.kind,
            "CYCLOP_LLM_BASE_URL": effectiveBaseURL,
            "CYCLOP_LLM_API_KEY": trimmedKey,
        ]
    }

    // MARK: - Actions

    func loadKey() {
        guard !keyLoaded else { return }
        keyLoaded = true
        loading = true
        apiKey = Keychain.read(account: provider.rawValue) ?? ""
        loading = false
    }

    func loadModels() {
        guard !isLoadingModels else { return }
        isLoadingModels = true
        modelsError = nil
        let environment = listingEnvironment
        Task {
            let result = await MarkdownStore.listModels(environment: environment)
            isLoadingModels = false
            switch result {
            case .success(let list):
                models = list
                if list.isEmpty { modelsError = localized("The provider returned no models") }
            case .failure(let failure):
                models = []
                modelsError = failure.localizedDescription
            }
        }
    }

    /// Anything still waiting for the debounce, written now — the app is
    /// quitting.
    func flush() { writes.flush() }

    // MARK: - Storage

    private func switchProvider() {
        // Whatever was typed for the provider being left is saved under its
        // name first; the key goes to its own Keychain entry the same way.
        writes.flush()
        let endpoint = ConfigStore.shared.ai.endpoints[provider.rawValue]
        loading = true
        model = endpoint?.model ?? provider.defaultModel
        baseURL = endpoint?.baseURL ?? ""
        apiKey = Keychain.read(account: provider.rawValue) ?? ""
        keyLoaded = true
        models = []
        modelsError = nil
        loading = false
        scheduleSave()
    }

    private func scheduleSave() {
        guard !loading else { return }
        let snapshot = (enabled, provider, model, baseURL, apiKey, keyLoaded)
        writes.schedule {
            let (enabled, provider, model, baseURL, apiKey, keyLoaded) = snapshot
            var ai = ConfigStore.shared.ai
            ai.enabled = enabled
            ai.provider = provider.rawValue
            ai.endpoints[provider.rawValue] = .init(model: model, baseURL: baseURL)
            if ai != ConfigStore.shared.ai { ConfigStore.shared.ai = ai }
            // A key never read cannot have been edited — writing the empty
            // field back would erase the stored one.
            guard keyLoaded else { return }
            let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty {
                Keychain.delete(account: provider.rawValue)
            } else if Keychain.read(account: provider.rawValue) != key {
                Keychain.write(key, account: provider.rawValue)
            }
        }
    }
}

/// API keys, one generic password per provider.
///
/// The Keychain rather than `config.json`: that file is meant to be opened,
/// edited and copied to another Mac (#67), which is exactly what must not
/// happen to a key that spends somebody's money.
enum Keychain {
    private static let service = "com.cyclop.app.llm"

    static func read(account: String) -> String? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, account: String) {
        let data = Data(value.utf8)
        let status = SecItemUpdate(base(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = base(account)
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Cyclop — \(account) API key"
            let added = SecItemAdd(item as CFDictionary, nil)
            if added != errSecSuccess { NSLog("Cyclop: keychain add failed: \(added)") }
        } else if status != errSecSuccess {
            NSLog("Cyclop: keychain update failed: \(status)")
        }
    }

    static func delete(account: String) {
        SecItemDelete(base(account) as CFDictionary)
    }

    private static func base(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
