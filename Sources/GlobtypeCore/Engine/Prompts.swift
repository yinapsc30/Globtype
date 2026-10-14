import Foundation

/// 发送给模型的消息。
public struct ChatMessage: Equatable, Sendable {
    public enum Role: String, Sendable { case system, user, assistant }
    public var role: Role
    public var content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

/// 全部 Prompt 模板。请求中只包含用户文本，不附带 App 名称、窗口标题等上下文（需求 14.4）。
public enum Prompts {
    static let formatRules = """
    Formatting rules (must follow):
    - Keep the paragraph structure exactly: line breaks, blank lines, list markers and numbering.
    - Keep URLs, email addresses, @mentions, #hashtags, emoji and anything inside backticks exactly as they are.
    - Keep English proper nouns, product names and technical terms that already appear in the text unchanged.
    - Output only the result text. No quotes, no notes, no explanations, no Markdown code fences.
    """

    static let expressionRules = """
    After the result, output a line containing exactly \(StreamParser.separator)
    Then output a JSON array with 0 to 3 English expressions from your result that are worth learning for a Chinese native speaker.
    Prefer phrases, collocations and idiomatic expressions over single common words. Skip anything basic.
    Each item: {"en": "<expression as used>", "zh": "<short Chinese meaning>", "type": "phrase" or "word"}
    If nothing is worth learning, output [].
    """

    public static func translateMessages(_ request: TranslateRequest, includeExpressions: Bool = true) -> [ChatMessage] {
        let task: String
        switch request.mode {
        case .translate:
            task = """
            You are a professional translator for Chinese native speakers writing in English.
            Translate the user's text (Chinese, or mixed Chinese and English) into natural, idiomatic English
            that a native speaker would write in the same situation. Preserve the meaning and the tone.
            """
        case .polish:
            task = """
            You are an English writing assistant for Chinese native speakers.
            The user's text is English that may contain grammar mistakes or Chinglish.
            Rewrite it into correct, natural, idiomatic English. Preserve the meaning, tone and length as much as possible.
            If it is already natural, return it with only the necessary fixes.
            """
        }
        var system = task + "\n\n" + formatRules
        if includeExpressions { system += "\n\n" + expressionRules }

        var user = request.sourceText
        if let previous = request.previousTranslation, !previous.isEmpty {
            user = """
            \(request.sourceText)

            ---
            A previous version was:
            \(previous)
            Give a different phrasing this time. Do not repeat the previous version.
            """
        }
        return [ChatMessage(role: .system, content: system), ChatMessage(role: .user, content: user)]
    }

    public static func explainMessages(_ request: ExplainRequest) -> [ChatMessage] {
        let focus: String
        switch request.mode {
        case .translate:
            focus = "说明关键表达为什么这样翻译，指出中文直译容易出错的地方。"
        case .polish:
            focus = "逐条标出原文与修改后版本的差异，说明其中的语法问题或中式英语表达，以及为什么修改后更地道。"
        }
        let system = """
        你是面向中文母语者的英语写作老师。用简体中文回答。
        \(focus)
        输出 2 到 4 条要点，使用 Markdown 无序列表，每条不超过 60 个汉字，英文表达用 **加粗**。
        不要输出标题、开场白或总结。
        """
        let user = """
        原文：
        \(request.sourceText)

        译文：
        \(request.translation)
        """
        return [ChatMessage(role: .system, content: system), ChatMessage(role: .user, content: user)]
    }

    /// 重新生成时提高多样性。
    public static func temperature(for request: TranslateRequest) -> Double {
        request.previousTranslation == nil ? 0.3 : 0.9
    }
}
