import Foundation

/// 流式 HTTP 响应：状态码 + 按行读取的正文。
public struct StreamingResponse: Sendable {
    public var status: Int
    public var lines: AsyncThrowingStream<String, Error>

    public init(status: Int, lines: AsyncThrowingStream<String, Error>) {
        self.status = status
        self.lines = lines
    }

    /// 读取全部正文（用于错误信息）。
    public func collectBody(limit: Int = 4096) async -> String {
        var body = ""
        do {
            for try await line in lines {
                body += line + "\n"
                if body.count > limit { break }
            }
        } catch {}
        return body
    }
}

/// 抽象 HTTP 传输，便于在测试中替换为假实现。
public protocol HTTPTransport: Sendable {
    func stream(_ request: URLRequest) async throws -> StreamingResponse
}

public struct URLSessionTransport: HTTPTransport {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func stream(_ request: URLRequest) async throws -> StreamingResponse {
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let lines = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return StreamingResponse(status: status, lines: lines)
    }
}

/// 解析 SSE 行：只关心 `data:` 行。
public enum SSELine: Equatable, Sendable {
    case data(String)
    case done
    case ignore

    public init(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else {
            self = .ignore
            return
        }
        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        self = payload == "[DONE]" ? .done : .data(payload)
    }
}

/// 请求超时：URLSession 的 timeoutInterval 是"两次收到数据之间"的最长等待时间，
/// 设为 30 秒即满足"30 秒内未收到任何响应则中止"（需求 4.8）。
public let providerRequestTimeout: TimeInterval = 30
