import Foundation

public enum ConversationSource: String, Equatable, Hashable, CaseIterable, Codable {
    case claudeCode
    case cursor
    case openclaw
    case vscodeCopilot
    case codex
    case claudeAgent
    case browser

    /// zh 展示名。工具专名（Claude Code / Cursor…）不译；
    /// 桌面客户端类来源按「产品名 + 形态」命名——用户认的是 ChatGPT / Claude 这两个
    /// 产品，不是 Codex / Agent 这种内部代号（用户定案 2026-08-03）。
    /// 形态后缀随语言变，英文见 displayName(isZh:)。
    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .cursor: return "Cursor"
        case .openclaw: return "OpenClaw"
        case .vscodeCopilot: return "VS Code Copilot"
        case .codex: return "ChatGPT 客户端"
        case .claudeAgent: return "Claude 客户端"
        case .browser: return "浏览器（Web AI）"
        }
    }

    /// UI 展示名（双语）。工具专名与语言无关，只有「客户端 / 浏览器」这类
    /// 形态词要切；Core 不依赖 UI 层 L10n，isZh 由视图层传入。
    public func displayName(isZh: Bool) -> String {
        guard !isZh else { return displayName }
        switch self {
        case .codex: return "ChatGPT Desktop"
        case .claudeAgent: return "Claude Desktop"
        case .browser: return "Browser (Web AI)"
        default: return displayName
        }
    }
}

public struct Conversation: Identifiable, Equatable, Hashable {
    public let id: String
    public let source: ConversationSource
    public let startAt: Date
    public let endAt: Date
    public let cwd: String
    public let gitBranch: String?
    /// 工具官方生成的会话标题（Claude Code 的 `ai-title` 行）。
    /// 有则列表/详情优先显示；Codex / browser 无此概念，恒 nil。
    public let title: String?
    public let messages: [Message]

    public init(
        id: String,
        source: ConversationSource,
        startAt: Date,
        endAt: Date,
        cwd: String,
        gitBranch: String?,
        title: String? = nil,
        messages: [Message]
    ) {
        self.id = id
        self.source = source
        self.startAt = startAt
        self.endAt = endAt
        self.cwd = cwd
        self.gitBranch = gitBranch
        self.title = title
        self.messages = messages
    }

    public var duration: TimeInterval {
        endAt.timeIntervalSince(startAt)
    }

    public var messageCount: Int {
        messages.count
    }

    /// 列表预览：最近一条有文字的消息内容（单行截断）——让列表一眼看出对话最新进展。
    public var preview: String {
        Self.cleanPreview(messages.last(where: { $0.firstTextBlock != nil })?.firstTextBlock)
    }

    /// preview 清洗口径(全量版与流式管线共用,防分叉):图片标记→[图片]、
    /// 换行压平、60 字截断;无文字统一哨兵值。
    public static func cleanPreview(_ text: String?) -> String {
        guard let text else { return "(无文字)" }
        let cleaned = text
            .replacingOccurrences(of: #"\[[Ii]mage: source:[^\]]*\]"#, with: "[图片]", options: .regularExpression)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return "(无文字)" }
        return cleaned.count > 60 ? String(cleaned.prefix(60)) + "…" : cleaned
    }

    /// 全文搜索用：所有 text/code/thinking/tool 内容拼接，不含图片 base64。
    ///
    /// 段级改造后本身已无生产调用方（切段/入索引走 `Segmenter.plainTextForSearch`），
    /// 只剩测试在断言这份口径——不能删（会破坏既有测试），但也不能自己再复刻一遍
    /// 过滤逻辑：复用 `Segmenter` 的实现，保证这里与实际写进索引的文字永远同源。
    /// （逐条消息拼接会在「消息只含图片」处比逐块 flatMap 多插入一个换行，但
    /// 调用方全是 `.contains(...)` 子串断言，不受影响。）
    public var searchableText: String {
        messages.map(Segmenter.plainTextForSearch(of:)).joined(separator: "\n")
    }
}

/// 列表用的轻量摘要，不持有 messages（特别是不持有 image base64）。
/// 选中后由 ConversationStore 按 `fileURL` 按需加载完整 Conversation。
public struct ConversationLite: Identifiable, Equatable, Hashable, Codable {
    public let id: String
    public let source: ConversationSource
    public let startAt: Date
    public let endAt: Date
    public let cwd: String
    public let gitBranch: String?
    /// 官方会话标题（见 Conversation.title）；Optional——旧索引行 / 无此字段的源为 nil。
    public let title: String?
    public let preview: String
    public let messageCount: Int
    public let fileURL: URL

    public init(
        id: String,
        source: ConversationSource,
        startAt: Date,
        endAt: Date,
        cwd: String,
        gitBranch: String?,
        title: String? = nil,
        preview: String,
        messageCount: Int,
        fileURL: URL
    ) {
        self.id = id
        self.source = source
        self.startAt = startAt
        self.endAt = endAt
        self.cwd = cwd
        self.gitBranch = gitBranch
        self.title = title
        self.preview = preview
        self.messageCount = messageCount
        self.fileURL = fileURL
    }

    public var duration: TimeInterval {
        endAt.timeIntervalSince(startAt)
    }

    /// 由完整 Conversation 提取摘要，丢弃 messages（释放图片 base64）。
    public static func from(_ conv: Conversation, fileURL: URL) -> ConversationLite {
        ConversationLite(
            id: conv.id,
            source: conv.source,
            startAt: conv.startAt,
            endAt: conv.endAt,
            cwd: conv.cwd,
            gitBranch: conv.gitBranch,
            title: conv.title,
            preview: conv.preview,
            messageCount: conv.messageCount,
            fileURL: fileURL
        )
    }
}

public extension Date {
    /// 相对时间（双语）。zh：刚刚 / X 秒前 / X 分钟前 / X 小时前 / X 天前 / M月d日（跨年补年份）；
    /// en：just now / Xs ago / X min ago / X h ago / yesterday / Xd ago / MMM d（跨年 MMM d, yyyy）。
    /// 数字与单位间留空格（对齐全 app「N 条」「X 分」的排版规则）；
    /// 兜底日期用 DayDivider 同族格式并固定 locale（zh_CN / en_US_POSIX），系统语言不漂。
    /// Core 不依赖 UI 层 L10n，isZh 由视图层传入。
    func relativeLabel(isZh: Bool) -> String {
        let s = Int(Date().timeIntervalSince(self))
        if isZh {
            if s < 1 { return "刚刚" }
            if s < 60 { return "\(s) 秒前" }
            if s < 3600 { return "\(s / 60) 分钟前" }
            if s < 86400 { return "\(s / 3600) 小时前" }
            if s < 2_592_000 { return "\(s / 86400) 天前" }
        } else {
            if s < 1 { return "just now" }
            if s < 60 { return "\(s)s ago" }
            if s < 3600 { return "\(s / 60) min ago" }
            if s < 86400 { return "\(s / 3600) h ago" }
            if s < 172_800 { return "yesterday" }
            if s < 2_592_000 { return "\(s / 86400)d ago" }
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: isZh ? "zh_CN" : "en_US_POSIX")
        let sameYear = Calendar.current.isDate(self, equalTo: Date(), toGranularity: .year)
        f.dateFormat = isZh ? (sameYear ? "M月d日" : "yyyy年M月d日")
                            : (sameYear ? "MMM d" : "MMM d, yyyy")
        return f.string(from: self)
    }
}
