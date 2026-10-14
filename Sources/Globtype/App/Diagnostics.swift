import Foundation

/// 诊断模式的记录（任务 3.6）：只记录方式与结果，不记录任何文本内容。
@MainActor
final class DiagnosticsLog: ObservableObject {
    static let shared = DiagnosticsLog()

    struct Entry: Identifiable {
        let id = UUID()
        let time = Date()
        let app: String
        let bundleID: String
        let readMethod: String
        let scope: String
        let sourceLength: Int
        let caretAvailable: Bool
        let elementRectAvailable: Bool
        let replaceResult: String
        let manualAccessibility: Bool
    }

    @Published private(set) var entries: [Entry] = []

    func add(_ entry: Entry) {
        entries.insert(entry, at: 0)
        if entries.count > 200 { entries.removeLast() }
    }

    func clear() { entries.removeAll() }

    var markdownTable: String {
        var lines = [
            "| 时间 | App | Bundle ID | 读取方式 | 范围 | 字符数 | 光标坐标 | 元素坐标 | 启用辅助功能树 | 回填结果 |",
            "|---|---|---|---|---|---|---|---|---|---|",
        ]
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        for e in entries.reversed() {
            lines.append("| \(formatter.string(from: e.time)) | \(e.app) | \(e.bundleID) | \(e.readMethod) | \(e.scope) | \(e.sourceLength) | \(e.caretAvailable ? "✓" : "✗") | \(e.elementRectAvailable ? "✓" : "✗") | \(e.manualAccessibility ? "是" : "否") | \(e.replaceResult) |")
        }
        return lines.joined(separator: "\n")
    }
}
