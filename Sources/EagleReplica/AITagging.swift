import AppKit
import Combine
import Foundation
import Security

struct AIModelConfiguration: Equatable {
    var endpoint: String
    var model: String
    var prompt: String
    var maximumTags: Int
}

struct AIImageAnalysis: Equatable {
    let tags: [String]
    let prompt: String
    let name: String
}

enum AITaggingError: LocalizedError {
    case missingAPIKey
    case invalidEndpoint
    case imageUnavailable
    case imageEncodingFailed
    case serverStatus(Int, String)
    case invalidResponse
    case noTags
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "请先在设置中填写 API Key"
        case .invalidEndpoint: "API 接口地址无效，请使用 HTTPS 地址"
        case .imageUnavailable: "找不到这张素材的原始图片"
        case .imageEncodingFailed: "图片压缩失败，无法发送给视觉模型"
        case .serverStatus(let code, let message): "AI 接口返回错误（HTTP \(code)）：\(message)"
        case .invalidResponse: "AI 返回内容无法解析"
        case .noTags: "AI 没有返回可用标签"
        case .keychain(let status): "API Key 无法写入钥匙串（\(status)）"
        }
    }
}

@MainActor
final class AISettingsStore: ObservableObject {
    static let shared = AISettingsStore()

    @Published private(set) var configuration: AIModelConfiguration
    @Published private(set) var hasAPIKey: Bool
    @Published private(set) var automaticTaggingEnabled: Bool

    private let defaults: UserDefaults
    private static let endpointKey = "EagleReplica.ai.endpoint"
    private static let modelKey = "EagleReplica.ai.model"
    private static let promptKey = "EagleReplica.ai.prompt"
    private static let maximumTagsKey = "EagleReplica.ai.maximumTags"
    private static let automaticTaggingKey = "EagleReplica.ai.automaticTagging"
    nonisolated private static let keychainService = "com.mooyumm.InspirationLibrary.ai"
    nonisolated private static let keychainAccount = "deepseek-api-key"
    static let defaultModel = "deepseek-v4-flash-vision-exp"

    static let defaultPrompt = "分析这张视觉素材，仅返回适合素材管理的中文标签。优先描述主体、风格、色彩、构图、媒介和使用场景；标签简短、具体、互不重复，不要写解释。"

    init(defaults: UserDefaults = .standard, readsKeychain: Bool = true) {
        self.defaults = defaults
        let maximum = defaults.integer(forKey: Self.maximumTagsKey)
        let savedModel = defaults.string(forKey: Self.modelKey)
        if savedModel == nil || savedModel == "deepseek-v4-flash-vision" {
            defaults.set(Self.defaultModel, forKey: Self.modelKey)
        }
        configuration = AIModelConfiguration(
            endpoint: defaults.string(forKey: Self.endpointKey) ?? "https://api.deepseek.com/chat/completions",
            model: defaults.string(forKey: Self.modelKey) ?? Self.defaultModel,
            prompt: defaults.string(forKey: Self.promptKey) ?? Self.defaultPrompt,
            maximumTags: maximum == 0 ? 8 : min(max(maximum, 3), 16)
        )
        hasAPIKey = false
        automaticTaggingEnabled = defaults.object(forKey: Self.automaticTaggingKey) == nil
            ? true
            : defaults.bool(forKey: Self.automaticTaggingKey)
        // 钥匙串读取会弹出系统授权框并阻塞调用线程。App 每次重新构建后签名都会变，
        // 系统会再问一次；如果同步读，主线程会在窗口出现之前就卡住，表现为“点了没反应”。
        // 因此放到后台线程读，窗口先出来，授权框由用户按需处理。
        guard readsKeychain, ProcessInfo.processInfo.environment["EAGLE_DISABLE_AUTOMATIC_AI"] != "1" else { return }
        Task.detached(priority: .utility) { [weak self] in
            let hasKey = Self.readAPIKey() != nil
            await MainActor.run { self?.hasAPIKey = hasKey }
        }
    }

    func apiKey() -> String { Self.readAPIKey() ?? "" }

    func save(configuration: AIModelConfiguration, apiKey: String, automaticTaggingEnabled: Bool) throws {
        let endpoint = configuration.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validEndpoint(endpoint), !model.isEmpty else { throw AITaggingError.invalidEndpoint }
        let resolved = AIModelConfiguration(
            endpoint: endpoint,
            model: model,
            prompt: configuration.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Self.defaultPrompt : configuration.prompt,
            maximumTags: min(max(configuration.maximumTags, 3), 16)
        )
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        try Self.writeAPIKey(key)
        defaults.set(resolved.endpoint, forKey: Self.endpointKey)
        defaults.set(resolved.model, forKey: Self.modelKey)
        defaults.set(resolved.prompt, forKey: Self.promptKey)
        defaults.set(resolved.maximumTags, forKey: Self.maximumTagsKey)
        defaults.set(automaticTaggingEnabled, forKey: Self.automaticTaggingKey)
        self.configuration = resolved
        hasAPIKey = !key.isEmpty
        self.automaticTaggingEnabled = automaticTaggingEnabled
        NotificationCenter.default.post(name: .aiSettingsDidChange, object: nil)
    }

    func testConnection(configuration: AIModelConfiguration, apiKey: String) async throws -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AITaggingError.missingAPIKey }
        guard let url = Self.modelsURL(from: configuration.endpoint) else { throw AITaggingError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AITaggingError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw AITaggingError.serverStatus(http.statusCode, Self.serverMessage(data))
        }
        let ids = Self.modelIDs(from: data)
        if ids.contains(configuration.model) { return "连接成功，已找到模型 \(configuration.model)" }
        return ids.isEmpty ? "连接成功" : "连接成功；当前模型列表未返回该视觉模型，请确认模型名"
    }

    static func validEndpoint(_ value: String) -> Bool {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(), url.host != nil else { return false }
        return scheme == "https" || (scheme == "http" && ["127.0.0.1", "localhost"].contains(url.host?.lowercased() ?? ""))
    }

    static func modelsURL(from endpoint: String) -> URL? {
        guard validEndpoint(endpoint), var url = URL(string: endpoint) else { return nil }
        if url.lastPathComponent == "completions" { url.deleteLastPathComponent() }
        if url.lastPathComponent == "chat" { url.deleteLastPathComponent() }
        return url.appendingPathComponent("models")
    }

    private static func modelIDs(from data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["data"] as? [[String: Any]] else { return [] }
        return models.compactMap { $0["id"] as? String }
    }

    fileprivate static func serverMessage(_ data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
        return String(data: data.prefix(300), encoding: .utf8) ?? "未知错误"
    }

    nonisolated private static func readAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func writeAPIKey(_ value: String) throws {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(identity as CFDictionary)
        guard !value.isEmpty else { return }
        var item = identity
        item[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw AITaggingError.keychain(status) }
    }
}

@MainActor
final class AITaggingService: ObservableObject {
    enum State: Equatable {
        case idle
        case running
        case success
        case failure(String)
    }

    enum ChatState: Equatable {
        case idle
        case running
        case failure(String)
    }

    static let shared = AITaggingService()
    @Published private(set) var states: [UUID: State] = [:]
    @Published private(set) var chatStates: [UUID: ChatState] = [:]
    @Published private(set) var automaticPendingCount = 0
    @Published private(set) var automaticIsRunning = false
    @Published private(set) var automaticPauseMessage: String?

    private var automaticQueue: [UUID] = []
    private var queuedIDs: Set<UUID> = []
    private var attemptedIDs: Set<UUID> = []
    private var automaticWorker: Task<Void, Never>?

    func state(for itemID: UUID) -> State { states[itemID] ?? .idle }
    func chatState(for itemID: UUID) -> ChatState { chatStates[itemID] ?? .idle }

    @discardableResult
    func tag(_ item: LibraryItem, in store: LibraryStore) async -> Bool {
        await analyze(item, in: store, overwriteTags: true, overwritePrompt: true)
    }

    @discardableResult
    func generatePrompt(_ item: LibraryItem, in store: LibraryStore) async -> Bool {
        await analyze(item, in: store, overwriteTags: false, overwritePrompt: true)
    }

    private func analyze(
        _ item: LibraryItem,
        in store: LibraryStore,
        overwriteTags: Bool,
        overwritePrompt: Bool
    ) async -> Bool {
        let settings = AISettingsStore.shared
        let key = settings.apiKey()
        guard !key.isEmpty else {
            states[item.id] = .failure(AITaggingError.missingAPIKey.localizedDescription)
            return false
        }
        guard let imageURL = store.imageURL(for: item) else {
            states[item.id] = .failure(AITaggingError.imageUnavailable.localizedDescription)
            return false
        }
        states[item.id] = .running
        do {
            let jpeg = try Self.compactJPEG(from: imageURL)
            let analysis = try await Self.requestAnalysis(
                imageJPEG: jpeg,
                configuration: settings.configuration,
                apiKey: key
            )
            store.updateAIAnalysis(
                item.id,
                tags: overwriteTags || item.aiTags == nil ? analysis.tags : nil,
                prompt: overwritePrompt || item.aiPrompt == nil ? analysis.prompt : nil,
                generatedName: item.aiGeneratedName == nil ? analysis.name : nil
            )
            states[item.id] = .success
            return true
        } catch {
            states[item.id] = .failure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            return false
        }
    }

    static func automaticCandidates(in items: [LibraryItem]) -> [LibraryItem] {
        items.filter { !$0.isTrashed && ($0.aiTags == nil || $0.aiPrompt == nil || $0.aiGeneratedName == nil) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func scheduleAutomaticTagging(in store: LibraryStore, retryFailures: Bool = false) {
        let settings = AISettingsStore.shared
        guard settings.hasAPIKey else {
            automaticPauseMessage = settings.hasAPIKey ? nil : "填写 API Key 后自动开始"
            return
        }
        if retryFailures {
            attemptedIDs.removeAll()
            automaticPauseMessage = nil
        }
        for item in Self.automaticCandidates(in: store.items)
            where item.aiGeneratedName == nil || settings.automaticTaggingEnabled {
            enqueue(item.id)
        }
        startWorkerIfNeeded(in: store)
    }

    func enqueueAutomatically(_ item: LibraryItem, in store: LibraryStore) {
        let settings = AISettingsStore.shared
        let needsMandatoryName = item.aiGeneratedName == nil
        let needsOptionalAnalysis = settings.automaticTaggingEnabled && (item.aiTags == nil || item.aiPrompt == nil)
        guard (needsMandatoryName || needsOptionalAnalysis), !item.isTrashed else { return }
        guard settings.hasAPIKey else { return }
        enqueue(item.id)
        startWorkerIfNeeded(in: store)
    }

    private func enqueue(_ itemID: UUID) {
        guard !queuedIDs.contains(itemID), !attemptedIDs.contains(itemID), state(for: itemID) != .running else { return }
        automaticQueue.append(itemID)
        queuedIDs.insert(itemID)
        automaticPendingCount = automaticQueue.count
    }

    private func startWorkerIfNeeded(in store: LibraryStore) {
        guard AISettingsStore.shared.hasAPIKey,
              automaticWorker == nil,
              !automaticQueue.isEmpty else { return }
        automaticWorker = Task { @MainActor [weak self, weak store] in
            guard let self, let store else { return }
            automaticIsRunning = true
            automaticPauseMessage = nil
            var consecutiveFailures = 0

            while !automaticQueue.isEmpty, AISettingsStore.shared.hasAPIKey {
                let itemID = automaticQueue.removeFirst()
                queuedIDs.remove(itemID)
                automaticPendingCount = automaticQueue.count
                guard let item = store.items.first(where: { $0.id == itemID }), !item.isTrashed else { continue }
                let needsMandatoryName = item.aiGeneratedName == nil
                let needsOptionalAnalysis = AISettingsStore.shared.automaticTaggingEnabled && (item.aiTags == nil || item.aiPrompt == nil)
                guard needsMandatoryName || needsOptionalAnalysis else { continue }
                attemptedIDs.insert(itemID)
                let succeeded = await analyze(
                    item,
                    in: store,
                    overwriteTags: item.aiTags == nil,
                    overwritePrompt: item.aiPrompt == nil
                )
                if succeeded {
                    consecutiveFailures = 0
                } else {
                    consecutiveFailures += 1
                    if consecutiveFailures >= 3 {
                        automaticPauseMessage = "连续失败 3 次，已暂停；保存 AI 设置后可重试"
                        automaticQueue.removeAll()
                        queuedIDs.removeAll()
                        automaticPendingCount = 0
                        break
                    }
                }
                if !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(350))
                }
            }
            automaticIsRunning = false
            automaticWorker = nil
            if AISettingsStore.shared.hasAPIKey, !automaticQueue.isEmpty {
                startWorkerIfNeeded(in: store)
            }
        }
    }

    func clearState(for itemID: UUID) { states[itemID] = .idle }

    @discardableResult
    func sendChat(_ text: String, about item: LibraryItem, in store: LibraryStore) async -> Bool {
        let messageText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !messageText.isEmpty, chatState(for: item.id) != .running else { return false }
        let settings = AISettingsStore.shared
        let key = settings.apiKey()
        guard !key.isEmpty else {
            chatStates[item.id] = .failure(AITaggingError.missingAPIKey.localizedDescription)
            return false
        }
        guard let imageURL = store.imageURL(for: item) else {
            chatStates[item.id] = .failure(AITaggingError.imageUnavailable.localizedDescription)
            return false
        }

        chatStates[item.id] = .running
        store.appendAIChatMessage(
            AIChatMessage(role: .user, content: String(messageText.prefix(8_000))),
            to: item.id
        )
        do {
            let jpeg = try Self.compactJPEG(from: imageURL)
            let history = store.items.first(where: { $0.id == item.id })?.chatMessages ?? []
            let reply = try await Self.requestChat(
                imageJPEG: jpeg,
                history: history,
                configuration: settings.configuration,
                apiKey: key
            )
            store.appendAIChatMessage(AIChatMessage(role: .assistant, content: reply), to: item.id)
            chatStates[item.id] = .idle
            return true
        } catch {
            chatStates[item.id] = .failure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            return false
        }
    }

    func clearChatState(for itemID: UUID) { chatStates[itemID] = .idle }

    static func makeChatRequest(
        imageJPEG: Data,
        history: [AIChatMessage],
        configuration: AIModelConfiguration,
        apiKey: String
    ) throws -> URLRequest {
        guard AISettingsStore.validEndpoint(configuration.endpoint), let url = URL(string: configuration.endpoint) else {
            throw AITaggingError.invalidEndpoint
        }
        var messages: [[String: Any]] = [[
            "role": "system",
            "content": "你是素材库中的视觉创意助手。请始终结合用户当前提供的图片回答，帮助分析画面、设计、风格、构图、文案和创作方向。回答清晰、具体，默认使用中文。"
        ], [
            "role": "user",
            "content": [
                ["type": "text", "text": "这是本次对话对应的素材图片。后续问题都请结合它回答。"],
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(imageJPEG.base64EncodedString())", "detail": "low"]]
            ]
        ]]
        messages.append(contentsOf: history.suffix(20).map { message in
            [
                "role": message.role.rawValue,
                "content": String(message.content.prefix(8_000))
            ]
        })
        let body: [String: Any] = [
            "model": configuration.model,
            "messages": messages,
            "thinking": ["type": "disabled"],
            "temperature": 0.5,
            "max_tokens": 1_200
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func parseChatReply(from data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let raw = message["content"] as? String else { throw AITaggingError.invalidResponse }
        let reply = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { throw AITaggingError.invalidResponse }
        return String(reply.prefix(12_000))
    }

    private static func requestChat(
        imageJPEG: Data,
        history: [AIChatMessage],
        configuration: AIModelConfiguration,
        apiKey: String
    ) async throws -> String {
        let request = try makeChatRequest(
            imageJPEG: imageJPEG,
            history: history,
            configuration: configuration,
            apiKey: apiKey
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AITaggingError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw AITaggingError.serverStatus(http.statusCode, AISettingsStore.serverMessage(data))
        }
        return try parseChatReply(from: data)
    }

    static func makeRequest(imageJPEG: Data, configuration: AIModelConfiguration, apiKey: String) throws -> URLRequest {
        guard AISettingsStore.validEndpoint(configuration.endpoint), let url = URL(string: configuration.endpoint) else {
            throw AITaggingError.invalidEndpoint
        }
        let instruction = """
        \(configuration.prompt) 最多返回 \(configuration.maximumTags) 个标签。
        同时生成一段可直接用于图像生成模型的中文提示词，用来复现这张图片。要求具体、可执行，按下面的顺序把画面信息串成一段：
        主体与关键细节（人物或物件的具体特征，例如服装、发型、材质、道具、纹理）→ 主体的动作或状态 → 环境与背景 → 构图与景别（全景/中景/特写、主体位置、留白）→ 镜头与视角（视角高度、焦段感、景深）→ 光线与色温（光源方向、软硬、时间）→ 色调与影调（主色、对比度、饱和度）→ 材质与质感 → 风格与媒介（摄影、插画、三维、拼贴等具体风格）→ 氛围与情绪 → 后期倾向。
        提示词长度 120–220 字，用逗号分隔的短语写成一整段，不要分点、不要换行、不要写分析过程，不要包含“这张图片”“画面中”等说明性前缀，也不要出现可识别的品牌名或版权角色名。
        另外为素材生成一个简洁、可检索的中文名称，建议 4–16 个字，不含扩展名，不使用“图片”“素材”等空泛词。
        严格返回 JSON：{"name":"素材名称","tags":["标签1","标签2"],"prompt":"图像生成提示词"}。
        """
        let body: [String: Any] = [
            "model": configuration.model,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": instruction],
                    ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(imageJPEG.base64EncodedString())", "detail": "low"]]
                ]
            ]],
            "thinking": ["type": "disabled"],
            "temperature": 0.2,
            "max_tokens": 1_200,
            "response_format": ["type": "json_object"]
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func parseTags(from data: Data, maximum: Int) throws -> [String] {
        let object = try responseObject(from: data)
        guard let rawTags = object["tags"] as? [String] else { throw AITaggingError.invalidResponse }
        var seen: Set<String> = []
        let tags = rawTags.compactMap { raw -> String? in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "#，,。"))
            guard !value.isEmpty, value.count <= 24, seen.insert(value.lowercased()).inserted else { return nil }
            return value
        }
        guard !tags.isEmpty else { throw AITaggingError.noTags }
        return Array(tags.prefix(min(max(maximum, 1), 16)))
    }

    static func parseAnalysis(from data: Data, maximum: Int) throws -> AIImageAnalysis {
        let object = try responseObject(from: data)
        let tags = try parseTags(from: data, maximum: maximum)
        guard let rawPrompt = object["prompt"] as? String else { throw AITaggingError.invalidResponse }
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw AITaggingError.invalidResponse }
        guard let rawName = object["name"] as? String else { throw AITaggingError.invalidResponse }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".。"))
        guard !name.isEmpty else { throw AITaggingError.invalidResponse }
        return AIImageAnalysis(tags: tags, prompt: String(prompt.prefix(4_000)), name: String(name.prefix(80)))
    }

    private static func responseObject(from data: Data) throws -> [String: Any] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              var content = message["content"] as? String else { throw AITaggingError.invalidResponse }
        content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if content.hasPrefix("```") {
            content = content.replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let payload = content.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw AITaggingError.invalidResponse
        }
        return object
    }

    private static func requestAnalysis(imageJPEG: Data, configuration: AIModelConfiguration, apiKey: String) async throws -> AIImageAnalysis {
        let request = try makeRequest(imageJPEG: imageJPEG, configuration: configuration, apiKey: apiKey)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AITaggingError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw AITaggingError.serverStatus(http.statusCode, AISettingsStore.serverMessage(data))
        }
        return try parseAnalysis(from: data, maximum: configuration.maximumTags)
    }

    private static func compactJPEG(from url: URL) throws -> Data {
        guard let source = NSImage(contentsOf: url), source.size.width > 0, source.size.height > 0 else {
            throw AITaggingError.imageUnavailable
        }
        let longest = max(source.size.width, source.size.height)
        let scale = min(1, 1280 / longest)
        let target = NSSize(width: max(1, source.size.width * scale), height: max(1, source.size.height * scale))
        let image = NSImage(size: target)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: target).fill()
        source.draw(in: NSRect(origin: .zero, size: target), from: .zero, operation: .sourceOver, fraction: 1)
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.78]) else {
            throw AITaggingError.imageEncodingFailed
        }
        return data
    }
}
