import GlobtypeCore
import SwiftUI

/// 闪卡复习窗口（需求 12.6、12.7）。
struct ReviewView: View {
    @ObservedObject var services: AppServices
    @State private var cards: [Card] = []
    @State private var index = 0
    @State private var flipped = false
    @State private var reviewedCount = 0

    private var current: Card? { index < cards.count ? cards[index] : nil }

    var body: some View {
        VStack(spacing: 16) {
            if let card = current {
                Text("第 \(index + 1) / \(cards.count) 张").font(.caption).foregroundStyle(.secondary)
                cardView(card)
                    .onTapGesture { flipped.toggle() }
                if flipped {
                    HStack(spacing: 12) {
                        answerButton("忘了", key: "1", answer: .forgot)
                        answerButton("记得", key: "2", answer: .remembered)
                        answerButton("太简单", key: "3", answer: .tooEasy)
                    }
                } else {
                    Button("翻面（空格）") { flipped = true }
                        .keyboardShortcut(.space, modifiers: [])
                }
            } else {
                Spacer()
                Image(systemName: "checkmark.circle").font(.system(size: 40)).foregroundStyle(.green)
                Text(reviewedCount > 0 ? "今天的复习完成了，共 \(reviewedCount) 张" : "今天没有需要复习的卡片")
                    .font(.title3)
                Spacer()
            }
        }
        .padding(24)
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: load)
    }

    private func cardView(_ card: Card) -> some View {
        VStack(spacing: 12) {
            Text(card.chinese).font(.title2).multilineTextAlignment(.center)
            if !card.contextZh.isEmpty {
                Text(card.contextZh.count > 160 ? String(card.contextZh.prefix(160)) + "…" : card.contextZh)
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if flipped {
                Divider()
                Text(card.english).font(.title.weight(.semibold))
                if let p = card.phonetic, !p.isEmpty { Text("/\(p)/").foregroundStyle(.secondary) }
                if !card.contextEn.isEmpty {
                    Text(ContextSnippet.sentence(containing: card.english, in: card.contextEn))
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 260)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
        .accessibilityElement(children: .combine)
        .accessibilityHint(flipped ? "" : "点击或按空格翻面")
    }

    private func answerButton(_ title: String, key: KeyEquivalent, answer: ReviewAnswer) -> some View {
        Button("\(title)（\(String(key.character))）") {
            guard let card = current else { return }
            services.review(cardID: card.id, answer: answer)
            // "忘了"的卡片当天重新到期，放回本轮末尾再考一次（需求 12.1）
            if answer == .forgot { cards.append(card) }
            reviewedCount += 1
            flipped = false
            index += 1
        }
        .keyboardShortcut(key, modifiers: [])
        .controlSize(.large)
    }

    private func load() {
        services.applySettings()
        cards = (try? services.learning?.dueCards(limit: 200)) ?? []
        index = 0
        flipped = false
    }
}
