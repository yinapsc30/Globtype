import GlobtypeCore
import SwiftUI

/// 悬浮面板内容（设计：面板布局）。
struct PanelView: View {
    @ObservedObject var model: PanelModel
    @State private var textHeight: CGFloat = 0
    static let width: CGFloat = 440

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            if model.explanationState != .hidden {
                Divider()
                explanation
            }
            if let hint = model.frequentHint {
                Divider()
                Label(hint, systemImage: "lightbulb")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
            if let card = model.reviewCard {
                Divider()
                ReviewRow(card: card, expanded: $model.reviewExpanded) { model.onReview?($0) }
            }
            if let notice = model.notice {
                Divider()
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }
            Divider()
            footer
            AppleTranslationHost()
        }
        .frame(width: Self.width)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(model.mode.displayName)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            Text(model.providerName)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if model.isReady {
                Text("⌥↵ 替换但不记录")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.mode == .translate ? "正在翻译…" : "正在润色…").foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("正在生成")
        case .streaming, .ready:
            ScrollView {
                Text(model.translation)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: ContentHeightKey.self, value: g.size.height)
                    })
            }
            // 按内容高度显示，最多 360pt，超出部分滚动（需求 5 面板布局）
            .frame(height: min(max(textHeight, 44), 360))
            .onPreferenceChange(ContentHeightKey.self) { textHeight = $0 }
            .contentShape(Rectangle())
            .onTapGesture { if model.isReady { model.onAccept?() } }
            .help("点击或按 Enter 替换原文")
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("按 Enter 替换原文")
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                if model.capabilities.regenerate || model.providerName == "Apple 翻译" {
                    Text("按 R 重试").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .confirmSourceChanged:
            VStack(alignment: .leading, spacing: 8) {
                Label("原文已变化", systemImage: "exclamationmark.circle").font(.headline)
                Text("生成期间输入框内容被修改。按 Enter 仍然替换，按 Esc 取消。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("仍然替换") { model.onAccept?() }
                    Button("取消") { model.onDismiss?() }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var explanation: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("讲解").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            switch model.explanationState {
            case .loading where model.explanation.isEmpty:
                ProgressView().controlSize(.small)
            case .failed(let message):
                Text(message).foregroundStyle(.red).font(.callout)
            default:
                Text(markdown(model.explanation))
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            hint("↵", "替换", enabled: model.isReady || model.phase == .confirmSourceChanged)
            if model.capabilities.regenerate { hint("R", "换个说法", enabled: model.phase != .loading) }
            if model.capabilities.explanation { hint("Tab", "讲解", enabled: model.isReady) }
            hint("⌘C", "复制", enabled: model.isReady)
            Spacer()
            hint("Esc", "关闭", enabled: true)
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private func hint(_ key: String, _ label: String, enabled: Bool) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.caption.monospaced())
                .padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15)))
            Text(label)
        }
        .foregroundStyle(enabled ? .secondary : .quaternary)
    }
}

/// 面板底部的复习卡片（需求 12.2~12.4）：只响应鼠标，不占用键盘。
struct ReviewRow: View {
    let card: Card
    @Binding var expanded: Bool
    let onAnswer: (ReviewAnswer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("复习").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(card.chinese).font(.callout).lineLimit(1)
                Spacer()
                if !expanded {
                    Button("查看") { expanded = true }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            if expanded {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(card.english).font(.body.weight(.semibold))
                    if let p = card.phonetic, !p.isEmpty { Text("/\(p)/").font(.caption).foregroundStyle(.secondary) }
                }
                if !card.contextEn.isEmpty {
                    Text(ContextSnippet.sentence(containing: card.english, in: card.contextEn))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("忘了") { onAnswer(.forgot) }
                    Button("记得") { onAnswer(.remembered) }
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
