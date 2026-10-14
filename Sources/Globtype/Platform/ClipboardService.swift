import AppKit

/// 剪贴板备份与恢复（需求 3.5、6.4）。
@MainActor
enum ClipboardService {
    struct Backup {
        let items: [[NSPasteboard.PasteboardType: Data]]
        let changeCount: Int
    }

    static let transientTypes: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
    ]

    static var pasteboard: NSPasteboard { .general }

    static func backup() -> Backup {
        let items = (pasteboard.pasteboardItems ?? []).map { item -> [NSPasteboard.PasteboardType: Data] in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { dict[type] = data }
            }
            return dict
        }
        return Backup(items: items, changeCount: pasteboard.changeCount)
    }

    /// 恢复备份。`expectedChangeCount` 为我们自己最后一次写入后的计数；
    /// 如果期间用户自己复制了新内容（计数变化），则不覆盖。
    static func restore(_ backup: Backup, ifUnchangedSince expectedChangeCount: Int) {
        guard pasteboard.changeCount == expectedChangeCount else { return }
        pasteboard.clearContents()
        let items = backup.items.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in dict { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    /// 临时写入文本，带上让剪贴板管理器忽略的标记类型。返回写入后的 changeCount。
    @discardableResult
    static func writeTransient(_ text: String) -> Int {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        for type in transientTypes { item.setData(Data(), forType: type) }
        pasteboard.writeObjects([item])
        return pasteboard.changeCount
    }

    /// 普通写入（回填失败时留给用户手动粘贴）。
    static func writePersistent(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// 等待剪贴板内容变化，最多等待 timeout 秒。
    static func waitForChange(from changeCount: Int, timeout: TimeInterval = 0.35) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pasteboard.changeCount != changeCount { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return pasteboard.changeCount != changeCount
    }
}
