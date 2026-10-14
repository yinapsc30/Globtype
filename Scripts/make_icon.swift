// 生成应用图标 Sources/Globtype/Resources/AppIcon.icns（需求 15.8）。
// 用法（swift 解释执行不会链接 AppKit，需先编译）：
//   swiftc -O -framework AppKit Scripts/make_icon.swift -o /tmp/make-icon && /tmp/make-icon
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let output = root.appendingPathComponent("Sources/Globtype/Resources/AppIcon.icns")
let work = FileManager.default.temporaryDirectory.appendingPathComponent("globtype-icon-\(UUID().uuidString)")
let iconset = work.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    // macOS 图标网格：824×824 圆角矩形居中
    let rect = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = NSBezierPath(roundedRect: rect, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.shadowBlurRadius = 20 * s
    shadow.set()
    NSColor.white.setFill()
    path.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    NSGradient(colors: [NSColor(calibratedRed: 0.16, green: 0.45, blue: 0.98, alpha: 1),
                        NSColor(calibratedRed: 0.10, green: 0.74, blue: 0.70, alpha: 1)])!
        .draw(in: path, angle: -60)

    // 左上"文"、右下"A"，中间箭头：中文写，英文出
    func draw(_ text: String, font: NSFont, color: NSColor, center: NSPoint) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let str = NSAttributedString(string: text, attributes: attrs)
        let b = str.size()
        str.draw(at: NSPoint(x: center.x - b.width / 2, y: center.y - b.height / 2))
    }
    draw("文", font: .systemFont(ofSize: 330 * s, weight: .bold), color: .white, center: NSPoint(x: 380 * s, y: 610 * s))
    draw("A", font: .systemFont(ofSize: 360 * s, weight: .heavy), color: NSColor.white.withAlphaComponent(0.92),
         center: NSPoint(x: 660 * s, y: 380 * s))
    let arrow = NSBezierPath()
    arrow.lineWidth = 34 * s
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 300 * s, y: 330 * s))
    arrow.curve(to: NSPoint(x: 470 * s, y: 250 * s), controlPoint1: NSPoint(x: 320 * s, y: 260 * s),
                controlPoint2: NSPoint(x: 400 * s, y: 240 * s))
    arrow.move(to: NSPoint(x: 420 * s, y: 300 * s))
    arrow.line(to: NSPoint(x: 470 * s, y: 250 * s))
    arrow.line(to: NSPoint(x: 410 * s, y: 215 * s))
    NSColor.white.withAlphaComponent(0.85).setStroke()
    arrow.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try render(size: px).write(to: iconset.appendingPathComponent(name))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: work)
guard task.terminationStatus == 0 else { fatalError("iconutil 失败") }
print("✓ \(output.path)")
