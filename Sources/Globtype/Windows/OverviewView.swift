import Charts
import GlobtypeCore
import SwiftUI

/// 学习概览（需求 16）。
struct OverviewView: View {
    @ObservedObject var state: LearningCenterState
    @ObservedObject var services: AppServices

    @State private var stats: LearningStats?
    @State private var activity: [DayActivity] = []
    @State private var top: [ExpressionSummary] = []
    @State private var recent: [RecordSummary] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("概览").font(.largeTitle.weight(.semibold))
                if services.learning == nil {
                    Label(services.storageError ?? "本地数据库不可用", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
                statCards
                if (stats?.records ?? 0) == 0 {
                    GettingStartedView(settings: services.settings)
                } else {
                    GroupBox("最近 14 天") { activityChart.padding(8) }
                    HStack(alignment: .top, spacing: 16) {
                        GroupBox("最常用的表达") { topList.padding(8) }
                        GroupBox("最近翻译") { recentList.padding(8) }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 960, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear(perform: reload)
        .onChange(of: services.revision) { _, _ in reload() }
    }

    // MARK: - 统计卡

    private var statCards: some View {
        let s = stats
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
            StatCard(title: "今日待复习", value: s?.dueToday ?? 0, systemImage: "rectangle.stack", tint: .orange,
                     subtitle: (s?.reviewedToday ?? 0) > 0 ? "今天已复习 \(s!.reviewedToday) 次" : nil) {
                Button("开始复习") { state.open(.review) }
                    .disabled((s?.dueToday ?? 0) == 0)
                    .controlSize(.small)
            }
            StatCard(title: "连续学习", value: s?.streakDays ?? 0, unit: "天", systemImage: "flame", tint: .red,
                     subtitle: "有翻译或复习就算一天") { EmptyView() }
            StatCard(title: "已掌握", value: s?.mastered ?? 0, systemImage: "checkmark.seal", tint: .green,
                     subtitle: "复习间隔达到 21 天") { EmptyView() }
            StatCard(title: "累计表达", value: s?.totalExpressions ?? 0, systemImage: "text.book.closed", tint: .blue,
                     subtitle: s.map { "复习中 \($0.active - $0.mastered) · 排队 \($0.pending)" }) {
                Button("查看") { state.open(.expressions) }
                    .controlSize(.small)
            }
        }
    }

    // MARK: - 图表

    private struct ChartPoint: Identifiable {
        let date: Date
        let kind: String
        let count: Int
        var id: String { "\(date.timeIntervalSince1970)-\(kind)" }
    }

    private var chartPoints: [ChartPoint] {
        activity.flatMap { a -> [ChartPoint] in
            let date = a.day.date()
            return [ChartPoint(date: date, kind: "翻译", count: a.translations),
                    ChartPoint(date: date, kind: "复习", count: a.reviews)]
        }
    }

    private var activityChart: some View {
        Chart(chartPoints) { p in
            BarMark(x: .value("日期", p.date, unit: .day), y: .value("次数", p.count))
                .foregroundStyle(by: .value("类型", p.kind))
                .position(by: .value("类型", p.kind))
        }
        .chartForegroundStyleScale(["翻译": Color.accentColor, "复习": Color.orange])
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
            }
        }
        .frame(height: 180)
        .accessibilityLabel("最近 14 天的翻译与复习次数")
    }

    // MARK: - 列表

    @ViewBuilder
    private var topList: some View {
        if top.isEmpty {
            Text("还没有提取到表达").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(top) { e in
                    Button { state.openExpression(e.id) } label: {
                        HStack {
                            Text(e.english).fontWeight(.medium)
                            Text(e.chinese).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Text("×\(e.useCount)").font(.caption).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(recent) { r in
                Button { state.openRecord(r.id) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.sourceText).lineLimit(1)
                        Text(r.translation).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text("\(r.appName) · \(r.updatedAt.formatted(.relative(presentation: .named)))")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func reload() {
        guard let learning = services.learning else { return }
        services.applySettings()
        stats = try? learning.stats()
        activity = (try? learning.dailyActivity(days: 14)) ?? []
        top = ((try? learning.expressions(ExpressionQuery(sort: .mostUsed, limit: 5))) ?? []).filter { $0.useCount > 0 }
        recent = (try? learning.search(RecordQuery(limit: 5))) ?? []
    }
}

struct StatCard<Accessory: View>: View {
    let title: String
    let value: Int
    var unit: String?
    let systemImage: String
    let tint: Color
    var subtitle: String?
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.callout)
                .foregroundStyle(tint)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(value)").font(.system(size: 30, weight: .semibold, design: .rounded))
                if let unit { Text(unit).foregroundStyle(.secondary) }
            }
            Text(subtitle ?? " ").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            accessory()
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
        .accessibilityElement(children: .combine)
    }
}

/// 没有任何记录时的上手说明（需求 16.6）。
struct GettingStartedView: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("开始使用").font(.headline)
                Text("1. 在任意 App 的输入框里用中文写一段话")
                Text("2. \(settings.useDoubleShift ? "双击 Shift" : "按 \(settings.customHotkey?.display ?? "自定义快捷键")") 唤出翻译面板")
                Text("3. 按 Enter 替换原文，翻译会自动保存到这里，并挑出值得学的表达进入复习")
                Divider()
                Text("面板快捷键：Enter 替换 · ⌥Enter 替换但不记录 · R 换个说法 · Tab 讲解 · ⌘C 复制 · Esc 关闭")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }
}
