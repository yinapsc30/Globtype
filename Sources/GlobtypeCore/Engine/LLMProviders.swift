import Foundation

/// 回调：记录一次请求的 token 用量（需求 7.8）。
public typealias UsageRecorder = @Sendable (_ providerID: String, _ promptTokens: Int, _ completionTokens: Int) -> Void

/// OpenAI Chat Completions 兼容协议与 Anthropic Messages 协议的公共流程。
public struct LLMProvider: TranslationProvider {
    public let config: ProviderConfig
    public let apiKey: String?
    public let transport: HTTPTransport
    public let recordUsage: UsageRecorder?

    public var displayName: String { config.name }
    public var capabilities: ProviderCapabilities { .full }

    public init(config: ProviderConfig, apiKey: String?, transport: HTTPTransport = URLSessionTransport(),
                recordUsage: UsageRecorder? = nil) {
        self.config = config
        self.apiKey = apiKey
        self.transport = transport
        self.recordUsage = recordUsage
    }

    // MARK: - 公开接口

    public func translate(_ request: TranslateRequest) -> AsyncThrowingStream<TranslateEvent, Error> {
        let messages = Prompts.translateMessages(request)
        let temperature = Prompts.temperature(for: request)
        let sourceLength = request.sourceText.count
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var parser = StreamParser()
                    var usage: (Int, Int)?
                    var outputLength = 0
                    try await streamText(messages: messages, temperature: temperature, maxTokens: 4096) { event in
                        switch event {
                        case .text(let chunk):
                            outputLength += chunk.count
                            let delta = parser.feed(chunk)
                            if !delta.isEmpty { continuation.yield(.translationDelta(delta)) }
                        case .usage(let p, let c):
                            usage = (p, c)
                        }
                    }
                    let result = parser.finish()
                    guard !result.translation.isEmpty else { throw ProviderError.emptyResponse }
                    continuation.yield(.translationDone(result.translation))
                    continuation.yield(.expressions(result.expressions))
                    // 服务商不返回用量时按"字符数 / 2"粗略估算
                    let (p, c) = usage ?? ((messages.map(\.content.count).reduce(0, +) + sourceLength) / 2, outputLength / 2)
                    continuation.yield(.usage(promptTokens: p, completionTokens: c))
                    recordUsage?(config.presetID, p, c)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.normalize(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func explain(_ request: ExplainRequest) -> AsyncThrowingStream<String, Error> {
        let messages = Prompts.explainMessages(request)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var usage: (Int, Int)?
                    var outputLength = 0
                    try await streamText(messages: messages, temperature: 0.3, maxTokens: 1024) { event in
                        switch event {
                        case .text(let chunk):
                            outputLength += chunk.count
                            continuation.yield(chunk)
                        case .usage(let p, let c):
                            usage = (p, c)
                        }
                    }
                    let (p, c) = usage ?? (messages.map(\.content.count).reduce(0, +) / 2, outputLength / 2)
                    recordUsage?(config.presetID, p, c)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.normalize(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func testConnection() async throws {
        let messages = [ChatMessage(role: .user, content: "Reply with OK.")]
        var received = false
        do {
            try await streamText(messages: messages, temperature: 0, maxTokens: 8) { event in
                if case .text(let t) = event, !t.isEmpty { received = true }
            }
        } catch {
            throw Self.normalize(error)
        }
        if !received { throw ProviderError.emptyResponse }
    }

    // MARK: - 流式请求

    enum StreamEvent {
        case text(String)
        case usage(Int, Int)
    }

    func buildRequest(messages: [ChatMessage], temperature: Double, maxTokens: Int) throws -> URLRequest {
        if config.requiresKey && (apiKey ?? "").isEmpty { throw ProviderError.missingAPIKey }
        var body: [String: Any]
        var request: URLRequest
        switch config.protocol {
        case .openAICompatible:
            request = URLRequest(url: try config.endpoint(path: "/chat/completions"))
            body = [
                "model": config.model,
                "stream": true,
                "temperature": temperature,
                "max_tokens": maxTokens,
                "stream_options": ["include_usage": true],
                "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            ]
            if let key = apiKey, !key.isEmpty {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        case .anthropic:
            request = URLRequest(url: try config.endpoint(path: "/v1/messages"))
            let system = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
            body = [
                "model": config.model,
                "stream": true,
                "temperature": temperature,
                "max_tokens": maxTokens,
                "messages": messages.filter { $0.role != .system }.map { ["role": $0.role.rawValue, "content": $0.content] },
            ]
            if !system.isEmpty { body["system"] = system }
            request.setValue(apiKey ?? "", forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        request.httpMethod = "POST"
        request.timeoutInterval = providerRequestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func streamText(messages: [ChatMessage], temperature: Double, maxTokens: Int,
                    onEvent: (StreamEvent) -> Void) async throws {
        let request = try buildRequest(messages: messages, temperature: temperature, maxTokens: maxTokens)
        let response = try await transport.stream(request)
        guard (200..<300).contains(response.status) else {
            let body = await response.collectBody()
            throw ProviderError.from(status: response.status, body: body)
        }
        // Anthropic 的输入 token 在 message_start 中给出，输出 token 在 message_delta 中给出
        var anthropicInputTokens = 0
        for try await line in response.lines {
            try Task.checkCancellation()
            switch SSELine(line) {
            case .ignore: continue
            case .done: return
            case .data(let payload):
                guard let data = payload.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                switch config.protocol {
                case .openAICompatible: try Self.handleOpenAIChunk(json, onEvent: onEvent)
                case .anthropic:
                    if try Self.handleAnthropicChunk(json, inputTokens: &anthropicInputTokens, onEvent: onEvent) { return }
                }
            }
        }
    }

    static func handleOpenAIChunk(_ json: [String: Any], onEvent: (StreamEvent) -> Void) throws {
        if let error = json["error"] as? [String: Any] {
            let message = (error["message"] as? String) ?? ""
            let code = (error["code"] as? Int) ?? 400
            throw ProviderError.from(status: code, body: message)
        }
        if let choices = json["choices"] as? [[String: Any]] {
            for choice in choices {
                if let delta = choice["delta"] as? [String: Any], let content = delta["content"] as? String, !content.isEmpty {
                    onEvent(.text(content))
                }
            }
        }
        if let usage = json["usage"] as? [String: Any],
           let p = usage["prompt_tokens"] as? Int, let c = usage["completion_tokens"] as? Int {
            onEvent(.usage(p, c))
        }
    }

    /// 返回 true 表示消息结束。
    static func handleAnthropicChunk(_ json: [String: Any], inputTokens: inout Int,
                                     onEvent: (StreamEvent) -> Void) throws -> Bool {
        switch json["type"] as? String {
        case "content_block_delta":
            if let delta = json["delta"] as? [String: Any], let text = delta["text"] as? String {
                onEvent(.text(text))
            }
        case "message_start":
            if let message = json["message"] as? [String: Any], let usage = message["usage"] as? [String: Any],
               let p = usage["input_tokens"] as? Int {
                inputTokens = p
                onEvent(.usage(p, (usage["output_tokens"] as? Int) ?? 0))
            }
        case "message_delta":
            if let usage = json["usage"] as? [String: Any], let c = usage["output_tokens"] as? Int {
                onEvent(.usage(inputTokens, c))
            }
        case "message_stop":
            return true
        case "error":
            let error = json["error"] as? [String: Any]
            let type = (error?["type"] as? String) ?? ""
            let message = (error?["message"] as? String) ?? ""
            let status: Int
            switch type {
            case "authentication_error", "permission_error": status = 401
            case "rate_limit_error": status = 429
            case "not_found_error": status = 404
            case "overloaded_error", "api_error": status = 503
            default: status = 400
            }
            throw ProviderError.from(status: status, body: message)
        default:
            break
        }
        return false
    }

    static func normalize(_ error: Error) -> Error {
        if error is ProviderError { return error }
        if error is CancellationError { return error }
        return ProviderError.from(urlError: error)
    }
}
