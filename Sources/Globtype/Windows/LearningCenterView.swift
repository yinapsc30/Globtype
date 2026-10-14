import GlobtypeCore
import SwiftUI

/// 学习中心的页面状态，菜单栏和各页面通过它切换页面、跳转记录（需求 15.2）。
@MainActor
final class LearningCenterState: ObservableObject {
    enum Section: String, Hashable, CaseIterable {
        case overview, review, library, expressions
    }

    @Published var section: Section? = .overview
    @Published var librarySelection: Int64?
    @Published var expressionSelection: Int64?
    /// 每次从外部进入复习页时递增，让复习页重新加载到期卡片
    @Published var reviewSession = 0

    func open(_ section: Section) {
        if section == .review { reviewSession += 1 }
        self.section = section
    }

    func openRecord(_ id: Int64) {
        librarySelection = id
        section = .library
    }

    func openExpression(_ id: Int64) {
        expressionSelection = id
        section = .expressions
    }
}

/// 学习中心主窗口（需求 15）。
struct LearningCenterView: View {
    @ObservedObject var state: LearningCenterState
    @ObservedObject var services: AppServices
    @State private var dueCount = 0

    var body: some View {
        NavigationSplitView {
            List(selection: $state.section) {
                Label("概览", systemImage: "chart.bar.xaxis").tag(LearningCenterState.Section.overview)
                Label("复习", systemImage: "rectangle.stack")
                    .badge(dueCount)
                    .tag(LearningCenterState.Section.review)
                Label("表达库", systemImage: "books.vertical").tag(LearningCenterState.Section.library)
                Label("我的表达", systemImage: "text.book.closed").tag(LearningCenterState.Section.expressions)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            .safeAreaInset(edge: .bottom) {
                Button {
                    WindowManager.shared.showSettings()
                } label: {
                    Label("设置…", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .padding(12)
            }
        } detail: {
            Group {
                switch state.section ?? .overview {
                case .overview:
                    OverviewView(state: state, services: services)
                case .review:
                    ReviewView(services: services).id(state.reviewSession)
                case .library:
                    LibraryView(services: services, state: state)
                case .expressions:
                    ExpressionsView(services: services, state: state)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 880, minHeight: 560)
        .onAppear(perform: refresh)
        .onChange(of: services.revision) { _, _ in refresh() }
    }

    private func refresh() {
        dueCount = services.dueCount()
    }
}
