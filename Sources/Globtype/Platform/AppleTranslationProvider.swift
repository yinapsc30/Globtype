import Foundation
import GlobtypeCore
import SwiftUI
import Translation
// SwiftPM 命令行构建不会自动加载跨模块 overlay，需显式导入才能使用 .translationTask
import _Translation_SwiftUI

/// Apple 翻译框架（需求 7.5~7.7）。
///
/// macOS 15 的 TranslationSession 只能通过 SwiftUI 的 `.translationTask` 获得，
/// 因此由悬浮面板中一个不可见的宿主视图（AppleTranslationHost）执行实际翻译。
@MainActor
final class AppleTranslationBridge: ObservableObject {
    static let shared = AppleTranslationBridge()

    static let source = Locale.Language(identifier: "zh-Hans")
    static let target = Locale.Language(identifier: "en")

    @Published var configuration: TranslationSession.Configuration?

    private var pendingText: String?
    private var continuation: CheckedContinuation<String, Error>?

    func translate(_ text: String) async throws -> String {
        continuation?.resume(throwing: CancellationError())
        return try await withCheckedThrowingContinuation { c in
            continuation = c
            pendingText = text
            if configuration == nil {
                configuration = TranslationSession.Configuration(source: Self.source, target: Self.target)
            } else {
                configuration?.invalidate()
            }
        }
    }

    func cancel() {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
        pendingText = nil
    }

    /// 由宿主视图在 translationTask 中调用。
    func perform(with session: TranslationSession) async {
        guard let text = pendingText, let c = continuation else { return }
        pendingText = nil
        continuation = nil
        do {
            let status = await LanguageAvailability().status(from: Self.source, to: Self.target)
            switch status {
            case .unsupported:
                throw ProviderError.unsupported("Apple 翻译不支持中文到英文")
            case .supported:
                // 语言包未下载：请求下载（需求 7.7）
                do {
                    try await session.prepareTranslation()
                } catch {
                    throw ProviderError.unsupported("请在 系统设置 → 通用 → 语言与地区 → 翻译语言 中下载“中文（简体）”和“英语”")
                }
            case .installed:
                break
            @unknown default:
                break
            }
            let response = try await session.translate(text)
            c.resume(returning: response.targetText)
        } catch let error as ProviderError {
            c.resume(throwing: error)
        } catch {
            c.resume(throwing: ProviderError.unsupported("Apple 翻译失败：\(error.localizedDescription)"))
        }
    }
}

/// 放在悬浮面板里的零尺寸视图。
struct AppleTranslationHost: View {
    @ObservedObject var bridge = AppleTranslationBridge.shared

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask(bridge.configuration) { session in
                await bridge.perform(with: session)
            }
    }
}

/// 未配置服务商时使用（需求 7.5、7.6）。
struct AppleTranslationProvider: TranslationProvider {
    var displayName: String { "Apple 翻译" }
    var capabilities: ProviderCapabilities { .translationOnly }

    func translate(_ request: TranslateRequest) -> AsyncThrowingStream<TranslateEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    guard request.mode == .translate else {
                        throw ProviderError.unsupported("润色需要配置 API Key")
                    }
                    let text = try await AppleTranslationBridge.shared.translate(request.sourceText)
                    continuation.yield(.translationDone(text))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { @MainActor in AppleTranslationBridge.shared.cancel() }
            }
        }
    }

    func explain(_ request: ExplainRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish(throwing: ProviderError.unsupported("讲解需要配置 API Key")) }
    }

    func testConnection() async throws {}
}
