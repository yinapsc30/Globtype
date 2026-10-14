import GlobtypeCore
import SwiftUI

/// 我的表达（需求 17）。
struct ExpressionsView: View {
    @ObservedObject var services: AppServices
    @ObservedObject var state: LearningCenterState

    @State private var keyword = ""
    @State private var status: ExpressionStatus?
    @State private var items: [ExpressionSummary] = []

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                TextField("搜索英文或中文", text: $keyword)
                    .textFieldStyle(.roundedBorder)
                Picker("状态", selection: $status) {
                    Text("全部").tag(ExpressionStatus?.none)
                    ForEach(ExpressionStatus.allCases, id: \.self) { Text($0.displayName).tag(Optional($0)) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                List(items, selection: $state.expressionSelection) { e in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.english).fontWeight(.medium)
                            Text(e.chinese).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if let s = e.status { StatusTag(status: s) }
                        if e.useCount > 1 { Text("×\(e.useCount)").font(.caption).foregroundStyle(.secondary) }
                    }
                    .padding(.vertical, 2)
                    .tag(e.id)
                }
                .overlay {
                    if items.isEmpty {
                        Text(keyword.isEmpty && status == nil ? "还没有表达。翻译并按 Enter 替换后，值得学的表达会出现在这里。" : "没有匹配的表达")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                    }
                }
                Text("\(items.count) 个表达").font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(minWidth: 300, idealWidth: 340, maxWidth: 460)

            Group {
                if let id = state.expressionSelection, let e = items.first(where: { $0.id == id }) {
                    ExpressionDetailView(expression: e, services: services, state: state, onChange: reload)
                        .id(e.id)
                } else {
                    Text("选择一个表达查看详情").foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear(perform: reload)
        .onChange(of: keyword) { _, _ in reload() }
        .onChange(of: status) { _, _ in reload() }
        .onChange(of: services.revision) { _, _ in reload() }
    }

    private func reload() {
        items = (try? services.learning?.expressions(ExpressionQuery(keyword: keyword, status: status))) ?? []
    }
}

struct StatusTag: View {
    let status: ExpressionStatus

    var body: some View {
        Text(status.displayName)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case .reviewing: return .blue
        case .pending: return .gray
        case .mastered: return .green
        case .blocked: return .secondary
        }
    }
}

struct ExpressionDetailView: View {
    let expression: ExpressionSummary
    @ObservedObject var services: AppServices
    @ObservedObject var state: LearningCenterState
    let onChange: () -> Void

    @State private var contexts: [ExpressionContext] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(expression.english).font(.title.weight(.semibold)).textSelection(.enabled)
                    if let p = expression.phonetic { Text("/\(p)/").foregroundStyle(.secondary) }
                }
                Text(expression.chinese).font(.title3).textSelection(.enabled)
                HStack(spacing: 12) {
                    if let s = expression.status { StatusTag(status: s) }
                    Text("使用 \(expression.useCount) 次")
                    if let due = expression.due, expression.status == .reviewing || expression.status == .mastered {
                        Text("下次复习 \(due.date().formatted(date: .abbreviated, time: .omitted))")
                        Text("间隔 \(expression.intervalDays) 天")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                actionButton
                Divider()
                Text("出现过的句子").font(.headline)
                if contexts.isEmpty {
                    Text("没有关联的记录").foregroundStyle(.secondary)
                }
                ForEach(contexts) { c in
                    Button { state.openRecord(c.recordID) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(ContextSnippet.sentence(containing: expression.english, in: c.english))
                            Text(c.chinese.count > 160 ? String(c.chinese.prefix(160)) + "…" : c.chinese)
                                .foregroundStyle(.secondary)
                            Text("\(c.appName) · \(c.date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("在表达库中查看这条记录")
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            contexts = (try? services.learning?.contexts(expressionID: expression.id)) ?? []
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch expression.status {
        case .blocked?, nil:
            Button("恢复复习") {
                try? services.learning?.restoreReview(expressionID: expression.id)
                done()
            }
            .help("移出屏蔽列表，今天就会出现在复习中")
        case .reviewing?, .pending?, .mastered?:
            Button("不再复习") {
                try? services.learning?.stopReviewing(expressionID: expression.id)
                done()
            }
            .help("等同于复习时选择“太简单”，以后不会再加入复习")
        }
    }

    private func done() {
        services.notifyChanged()
        onChange()
    }
}
