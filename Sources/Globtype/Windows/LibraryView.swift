import AppKit
import GlobtypeCore
import SwiftUI

/// 表达库（需求 9.5、9.6、10.11），嵌入学习中心。
struct LibraryView: View {
    @ObservedObject var services: AppServices
    @ObservedObject var state: LearningCenterState

    enum TimeFilter: String, CaseIterable, Identifiable {
        case all = "全部时间", today = "今天", week = "最近 7 天", month = "最近 30 天"
        var id: String { rawValue }

        var from: Date? {
            let cal = Calendar.current
            switch self {
            case .all: return nil
            case .today: return cal.startOfDay(for: Date())
            case .week: return cal.date(byAdding: .day, value: -7, to: Date())
            case .month: return cal.date(byAdding: .day, value: -30, to: Date())
            }
        }
    }

    @State private var keyword = ""
    @State private var appFilter: String?
    @State private var timeFilter = TimeFilter.all
    @State private var records: [RecordSummary] = []
    @State private var apps: [(bundleID: String, name: String)] = []
    @State private var confirmDelete = false

    var body: some View {
        HSplitView {
            VStack(spacing: 8) {
                TextField("搜索中文或英文", text: $keyword)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Picker("App", selection: $appFilter) {
                        Text("全部 App").tag(String?.none)
                        ForEach(apps, id: \.bundleID) { Text($0.name).tag(Optional($0.bundleID)) }
                    }
                    .labelsHidden()
                    Picker("时间", selection: $timeFilter) {
                        ForEach(TimeFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                }
                List(records, selection: $state.librarySelection) { record in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(record.sourceText).lineLimit(2)
                        Text(record.translation).lineLimit(1).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Text(record.appName)
                            Text(record.updatedAt, style: .date)
                            if record.useCount > 1 { Text("×\(record.useCount)") }
                        }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                    .tag(record.id)
                }
                .overlay {
                    if records.isEmpty {
                        Text(keyword.isEmpty ? "还没有记录。翻译并按 Enter 替换后会自动保存在这里。" : "没有匹配的记录")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding()
                    }
                }
                Text("\(records.count) 条记录").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .frame(minWidth: 300, idealWidth: 340, maxWidth: 460)

            Group {
                if let selection = state.librarySelection, let detail = try? services.learning?.detail(recordID: selection) {
                    RecordDetailView(detail: detail, services: services) { confirmDelete = true }
                        .id(selection)
                } else {
                    Text("选择一条记录查看详情").foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear(perform: reload)
        .onChange(of: keyword) { _, _ in reload() }
        .onChange(of: appFilter) { _, _ in reload() }
        .onChange(of: timeFilter) { _, _ in reload() }
        .onChange(of: services.revision) { _, _ in reload() }
        .confirmationDialog("删除这条记录？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) {
                if let selection = state.librarySelection { try? services.learning?.deleteRecord(id: selection) }
                state.librarySelection = nil
                services.notifyChanged()
            }
        }
    }

    private func reload() {
        guard let learning = services.learning else { return }
        let query = RecordQuery(keyword: keyword, appBundleID: appFilter, from: timeFilter.from)
        records = (try? learning.search(query)) ?? []
        apps = (try? learning.apps()) ?? []
    }
}

struct RecordDetailView: View {
    let detail: RecordDetail
    @ObservedObject var services: AppServices
    let onDelete: () -> Void

    @State private var manualText = ""
    @State private var manualMeaning = ""
    @State private var addedMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section("原文") { Text(detail.summary.sourceText).textSelection(.enabled) }
                section(detail.summary.mode == .translate ? "译文" : "润色后") {
                    SelectableText(text: detail.summary.translation, selection: $manualText)
                }
                if let explanation = detail.explanation, !explanation.isEmpty {
                    section("讲解") {
                        Text((try? AttributedString(markdown: explanation, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(explanation))
                            .textSelection(.enabled)
                    }
                }
                section("学习表达") {
                    if detail.expressions.isEmpty {
                        Text("本条没有提取到表达").foregroundStyle(.secondary)
                    }
                    ForEach(detail.expressions) { e in
                        HStack {
                            Text(e.english).fontWeight(.medium)
                            Text(e.chinese).foregroundStyle(.secondary)
                            Spacer()
                            Text(statusText(e.cardStatus)).font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
                section("加入复习") {
                    Text("在上面的译文中选中想学的部分会自动填入，也可以直接输入。手动加入不受每日上限限制。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("英文表达", text: $manualText)
                        TextField("中文释义（可选）", text: $manualMeaning)
                        Button("加入复习") {
                            try? services.learning?.addManualCard(recordID: detail.summary.id, english: manualText, chinese: manualMeaning)
                            addedMessage = "已加入：\(manualText)"
                            manualText = ""
                            manualMeaning = ""
                            services.notifyChanged()
                        }
                        .disabled(manualText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if let addedMessage { Text(addedMessage).font(.caption).foregroundStyle(.secondary) }
                }
                HStack {
                    Text("\(detail.summary.appName) · 使用 \(detail.summary.useCount) 次 · \(detail.summary.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("删除记录", role: .destructive, action: onDelete)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }

    private func statusText(_ status: String?) -> String {
        switch status {
        case "active": return "复习中"
        case "pending": return "排队中"
        case "blocked": return "太简单"
        default: return ""
        }
    }
}
