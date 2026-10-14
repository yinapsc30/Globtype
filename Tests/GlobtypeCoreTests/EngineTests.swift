import Foundation
import Testing
@testable import GlobtypeCore

@Suite struct StreamParserTests {
    static let sample = """
    Let's sync on this requirement next week.

    - Item one
    \(StreamParser.separator)
    [{"en":"sync on","zh":"就某事对齐","type":"phrase"},{"en":"requirement","zh":"需求"}]
    """

    func parse(chunks: [String]) -> (display: String, translation: String, expressions: [ExtractedExpression]) {
        var parser = StreamParser()
        var display = ""
        for c in chunks { display += parser.feed(c) }
        let result = parser.finish()
        return (display, result.translation, result.expressions)
    }

    @Test func wholeInput() {
        let r = parse(chunks: [Self.sample])
        #expect(r.translation == "Let's sync on this requirement next week.\n\n- Item one")
        #expect(r.expressions.count == 2)
        #expect(r.expressions[1].type == .word)
        #expect(!r.display.contains("<<<"))
    }

    /// 正确性属性 2：任意切分结果一致，且显示内容不含分隔符。
    @Test func randomSplitsAreConsistent() {
        let reference = parse(chunks: [Self.sample])
        let chars = Array(Self.sample)
        for _ in 0..<500 {
            var chunks: [String] = []
            var i = 0
            while i < chars.count {
                let n = Int.random(in: 1...8)
                chunks.append(String(chars[i..<min(chars.count, i + n)]))
                i += n
            }
            let r = parse(chunks: chunks)
            #expect(r.translation == reference.translation)
            #expect(r.expressions == reference.expressions)
            #expect(!r.display.contains(StreamParser.separator))
            #expect(r.display.trimmingCharacters(in: .whitespacesAndNewlines) == reference.translation)
        }
    }

    @Test func missingSeparator() {
        let r = parse(chunks: ["Hello ", "world"])
        #expect(r.translation == "Hello world")
        #expect(r.expressions.isEmpty)
    }

    @Test func brokenJSONYieldsNoExpressions() {
        let r = parse(chunks: ["Hi\n\(StreamParser.separator)\n[{\"en\": \"x\""])
        #expect(r.translation == "Hi")
        #expect(r.expressions.isEmpty)
    }

    @Test func codeFenceIsStripped() {
        let r = parse(chunks: ["```\n", "Hello there\n```\n", StreamParser.separator, "\n```json\n[]\n```"])
        #expect(r.translation == "Hello there")
        #expect(r.display.hasPrefix("Hello"))
    }
}

@Suite struct PromptTests {
    @Test func requestContainsOnlyUserText() {
        let req = TranslateRequest(sourceText: "你好", mode: .translate)
        let messages = Prompts.translateMessages(req)
        #expect(messages.count == 2)
        #expect(messages[1].content == "你好")
        #expect(messages[0].content.contains(StreamParser.separator))
    }

    @Test func regenerateIncludesPrevious() {
        let req = TranslateRequest(sourceText: "你好", mode: .translate, previousTranslation: "Hello")
        #expect(Prompts.translateMessages(req)[1].content.contains("Hello"))
        #expect(Prompts.temperature(for: req) == 0.9)
    }

    @Test func polishPromptDiffers() {
        let a = Prompts.translateMessages(TranslateRequest(sourceText: "x", mode: .translate))[0].content
        let b = Prompts.translateMessages(TranslateRequest(sourceText: "x", mode: .polish))[0].content
        #expect(a != b)
    }
}

/// 假传输：返回预设的状态码和行。
struct FakeTransport: HTTPTransport {
    var status: Int
    var lines: [String]
    var error: Error?
    let captured = Captured()

    final class Captured: @unchecked Sendable { var request: URLRequest? }

    func stream(_ request: URLRequest) async throws -> StreamingResponse {
        captured.request = request
        if let error { throw error }
        let lines = self.lines
        return StreamingResponse(status: status, lines: AsyncThrowingStream { c in
            for l in lines { c.yield(l) }
            c.finish()
        })
    }
}

@Suite struct ProviderTests {
    let openAI = ProviderConfig(presetID: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com/",
                                model: "m", protocol: .openAICompatible, requiresKey: true)
    let anthropic = ProviderConfig(presetID: "claude", name: "Claude", baseURL: "https://api.anthropic.com",
                                   model: "m", protocol: .anthropic, requiresKey: true)

    func sse(_ obj: [String: Any]) -> String {
        "data: " + String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }

    func openAIDelta(_ s: String) -> String { sse(["choices": [["delta": ["content": s]]]]) }

    func collect(_ provider: LLMProvider, _ text: String = "你好") async throws -> [TranslateEvent] {
        var events: [TranslateEvent] = []
        for try await e in provider.translate(TranslateRequest(sourceText: text, mode: .translate)) { events.append(e) }
        return events
    }

    @Test func openAIStreamAndUsage() async throws {
        let recorded = Captured()
        let transport = FakeTransport(status: 200, lines: [
            openAIDelta("Hel"), "", openAIDelta("lo\n\(StreamParser.separator)\n[]"),
            sse(["choices": [], "usage": ["prompt_tokens": 10, "completion_tokens": 5]]), "data: [DONE]",
        ])
        let provider = LLMProvider(config: openAI, apiKey: "sk", transport: transport) { id, p, c in
            recorded.value = (id, p, c)
        }
        let events = try await collect(provider)
        #expect(events.contains(.translationDone("Hello")))
        #expect(events.contains(.usage(promptTokens: 10, completionTokens: 5)))
        #expect(recorded.value?.0 == "deepseek")
        let req = transport.captured.request!
        #expect(req.url?.absoluteString == "https://api.deepseek.com/chat/completions")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk")
        #expect(req.timeoutInterval == 30)
    }

    final class Captured: @unchecked Sendable { var value: (String, Int, Int)? }

    @Test(arguments: [
        (401, "", ProviderError.invalidKey),
        (402, "", .insufficientBalance),
        (400, "{\"error\":\"Insufficient Balance\"}", .insufficientBalance),
        (429, "", .rateLimited),
        (404, "", .notFound),
        (503, "", .serverUnavailable(503)),
    ])
    func httpErrors(status: Int, body: String, expected: ProviderError) async {
        let provider = LLMProvider(config: openAI, apiKey: "sk", transport: FakeTransport(status: status, lines: [body]))
        do {
            _ = try await collect(provider)
            Issue.record("应当抛出错误")
        } catch {
            #expect(error as? ProviderError == expected)
        }
    }

    @Test func networkAndTimeoutErrors() async {
        for (err, expected) in [(URLError(.timedOut), ProviderError.timeout), (URLError(.notConnectedToInternet), .network)] {
            let provider = LLMProvider(config: openAI, apiKey: "sk", transport: FakeTransport(status: 0, lines: [], error: err))
            do {
                _ = try await collect(provider)
                Issue.record("应当抛出错误")
            } catch {
                #expect(error as? ProviderError == expected)
            }
        }
    }

    @Test func missingKey() async {
        let provider = LLMProvider(config: openAI, apiKey: nil, transport: FakeTransport(status: 200, lines: []))
        await #expect(throws: ProviderError.missingAPIKey) { _ = try await collect(provider) }
    }

    @Test func localModelWithoutKey() async throws {
        var config = openAI
        config.requiresKey = false
        let transport = FakeTransport(status: 200, lines: [openAIDelta("Hi"), "data: [DONE]"])
        let events = try await collect(LLMProvider(config: config, apiKey: nil, transport: transport))
        #expect(events.contains(.translationDone("Hi")))
        #expect(transport.captured.request?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func emptyResponseIsError() async {
        let provider = LLMProvider(config: openAI, apiKey: "sk", transport: FakeTransport(status: 200, lines: ["data: [DONE]"]))
        await #expect(throws: ProviderError.emptyResponse) { _ = try await collect(provider) }
    }

    @Test func anthropicStream() async throws {
        let transport = FakeTransport(status: 200, lines: [
            "event: message_start",
            sse(["type": "message_start", "message": ["usage": ["input_tokens": 12, "output_tokens": 1]]]),
            sse(["type": "content_block_delta", "delta": ["type": "text_delta", "text": "Good "]]),
            sse(["type": "content_block_delta", "delta": ["type": "text_delta", "text": "morning"]]),
            sse(["type": "message_delta", "usage": ["output_tokens": 7]]),
            sse(["type": "message_stop"]),
        ])
        let events = try await collect(LLMProvider(config: anthropic, apiKey: "k", transport: transport))
        #expect(events.contains(.translationDone("Good morning")))
        #expect(events.contains(.usage(promptTokens: 12, completionTokens: 7)))
        let req = transport.captured.request!
        #expect(req.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(req.value(forHTTPHeaderField: "x-api-key") == "k")
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        #expect(body["system"] is String)
        #expect((body["messages"] as! [[String: Any]]).count == 1)
    }

    @Test func anthropicErrorEvent() async {
        let transport = FakeTransport(status: 200, lines: [sse(["type": "error", "error": ["type": "overloaded_error", "message": "x"]])])
        let provider = LLMProvider(config: anthropic, apiKey: "k", transport: transport)
        await #expect(throws: ProviderError.serverUnavailable(503)) { _ = try await collect(provider) }
    }

    @Test func explainStreams() async throws {
        let transport = FakeTransport(status: 200, lines: [openAIDelta("- 要点一"), openAIDelta("\n- 要点二"), "data: [DONE]"])
        let provider = LLMProvider(config: openAI, apiKey: "sk", transport: transport)
        var text = ""
        for try await t in provider.explain(ExplainRequest(sourceText: "a", translation: "b", mode: .polish)) { text += t }
        #expect(text == "- 要点一\n- 要点二")
    }

    @Test func invalidBaseURL() async {
        var config = openAI
        config.baseURL = "not a url"
        let provider = LLMProvider(config: config, apiKey: "sk", transport: FakeTransport(status: 200, lines: []))
        await #expect(throws: ProviderError.invalidConfiguration("接口地址无效")) { _ = try await collect(provider) }
    }

    @Test func presetsFileDecodes() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Globtype/Resources/providers.json")
        let presets = try ProviderPreset.load(from: Data(contentsOf: url))
        let ids = Set(presets.map(\.id))
        for id in ["deepseek", "qwen", "kimi", "zhipu", "siliconflow", "openai", "claude", "gemini", "ollama", "lmstudio", "custom"] {
            #expect(ids.contains(id), "缺少预设 \(id)")
        }
    }
}
