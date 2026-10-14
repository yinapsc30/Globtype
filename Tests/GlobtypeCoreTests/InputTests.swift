import Foundation
import Testing
@testable import GlobtypeCore

@Suite struct DoubleShiftDetectorTests {
    func run(_ inputs: [KeyInput]) -> [Bool] {
        var d = DoubleShiftDetector()
        return inputs.map { d.feed($0) }
    }

    @Test func triggersOnQuickDoubleTap() {
        let r = run([.shiftDown(timestamp: 0), .shiftUp(timestamp: 0.05), .shiftDown(timestamp: 0.15), .shiftUp(timestamp: 0.2)])
        #expect(r == [false, false, false, true])
    }

    @Test func doesNotTriggerWhenTooSlow() {
        let r = run([.shiftDown(timestamp: 0), .shiftUp(timestamp: 0.05), .shiftDown(timestamp: 0.3), .shiftUp(timestamp: 0.45)])
        #expect(!r.contains(true))
    }

    @Test func slowSecondTapStartsNewSequence() {
        let r = run([.shiftDown(timestamp: 0), .shiftUp(timestamp: 0.05),
                     .shiftDown(timestamp: 1.0), .shiftUp(timestamp: 1.05),
                     .shiftDown(timestamp: 1.2), .shiftUp(timestamp: 1.25)])
        #expect(r.last == true)
    }

    @Test func otherKeyResets() {
        let r = run([.shiftDown(timestamp: 0), .shiftUp(timestamp: 0.05), .otherKey, .shiftDown(timestamp: 0.1), .shiftUp(timestamp: 0.15)])
        #expect(!r.contains(true))
    }

    @Test func shiftWithLetterIsNotATap() {
        // 按住 Shift 输入大写字母：down → 字母 → up
        let r = run([.shiftDown(timestamp: 0), .otherKey, .shiftUp(timestamp: 0.1), .shiftDown(timestamp: 0.15), .shiftUp(timestamp: 0.2)])
        #expect(!r.contains(true))
    }

    @Test func longHoldIsNotATap() {
        let r = run([.shiftDown(timestamp: 0), .shiftUp(timestamp: 0.5), .shiftDown(timestamp: 0.6), .shiftUp(timestamp: 0.65)])
        #expect(!r.contains(true))
    }

    /// 正确性属性 1：随机序列中，触发时刻必然是"无干扰的两次单击且在阈值内"。
    @Test func randomSequencesOnlyTriggerOnValidPattern() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<2000 {
            var detector = DoubleShiftDetector()
            var t: TimeInterval = 0
            var history: [KeyInput] = []
            for _ in 0..<12 {
                t += Double.random(in: 0.01...0.3, using: &rng)
                let input: KeyInput
                switch Int.random(in: 0..<5, using: &rng) {
                case 0: input = .otherKey
                case 1, 2: input = .shiftDown(timestamp: t)
                default: input = .shiftUp(timestamp: t)
                }
                history.append(input)
                if detector.feed(input) {
                    let last4 = Array(history.suffix(4))
                    #expect(last4.count == 4)
                    guard case .shiftDown(let a) = last4[0], case .shiftUp = last4[1],
                          case .shiftDown = last4[2], case .shiftUp(let d) = last4[3] else {
                        Issue.record("触发时的序列不是 down-up-down-up：\(last4)")
                        continue
                    }
                    #expect(d - a <= 0.4 + 1e-9)
                }
            }
        }
    }
}

@Suite struct ModeDetectorTests {
    @Test(arguments: [
        ("这个需求我们下周再对一下", TranslationMode.translate),
        ("这个 feature 下周 sync 一下", .translate),
        ("we can discuss it next week again", .polish),
        ("Please check https://example.com/这是链接 thanks", .polish),
        ("看一下 `let x = foo()` 这个写法", .translate),
        ("https://example.com", .translate),
        ("@张三 please review", .polish),
    ])
    func detect(text: String, expected: TranslationMode) {
        #expect(ModeDetector.detect(text) == expected)
    }
}

@Suite struct UTF16RangeTests {
    /// 正确性属性 8
    @Test func substringWithEmojiAndChinese() {
        let text = "你好👋🏽 world 😀！"
        let ns = text as NSString
        for loc in 0...ns.length {
            for len in 0...(ns.length - loc) {
                let range = NSRange(location: loc, length: len)
                if let sub = UTF16Range.substring(of: text, range: range) {
                    #expect(sub == ns.substring(with: range))
                }
            }
        }
        // 切在代理对中间的范围无效
        #expect(UTF16Range.substring(of: text, range: NSRange(location: 0, length: 3)) == nil)
        #expect(UTF16Range.substring(of: text, range: NSRange(location: 100, length: 1)) == nil)
    }

    @Test func replacingKeepsSurroundings() {
        let text = "前😀后"
        let range = NSRange(location: 1, length: 2) // 😀 占 2 个 UTF-16 单元
        #expect(UTF16Range.substring(of: text, range: range) == "😀")
        #expect(UTF16Range.replacing(in: text, range: range, with: "X") == "前X后")
        #expect(UTF16Range.length(of: text) == 4)
    }
}
