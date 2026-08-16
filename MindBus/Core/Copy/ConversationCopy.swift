import Foundation

/// 复制偏好。默认 =「接力」：整段对话、剥离代码块、带接力 header。
/// 高级配置藏在设置里；主「复制接力」按钮始终用当前偏好。
public struct CopyPreferences: Codable, Equatable {
    public enum Scope: String, CaseIterable, Codable {
        case all        // 全部消息
        case userOnly   // 仅我的提问
        case recent     // 最近 N 轮
    }
    public var scope: Scope
    public var stripCode: Bool       // 剥离 ``` 代码块（新模型读当前文件即可）
    public var includeHeader: Bool   // 加接力开头
    public var recentTurns: Int

    public init(scope: Scope = .all, stripCode: Bool = true,
                includeHeader: Bool = true, recentTurns: Int = 20) {
        self.scope = scope
        self.stripCode = stripCode
        self.includeHeader = includeHeader
        self.recentTurns = max(1, recentTurns)
    }
}

/// 把一段对话渲染成可粘进新模型的文本。纯本地、确定性，不做 AI 总结。
public enum ConversationCopy {

    /// isZh：接力头 / 代码占位的语言（剪贴板内容要粘给下一个 AI，必须跟界面语言走）。
    /// Core 不依赖 UI 层 L10n，由视图层传入；默认 zh 兼容既有调用与测试。
    /// onlyMessageIds：非 nil = 用户手选消息集（CopyScope.selected）——手选覆盖
    /// prefs.scope 的 userOnly/recent 过滤（用户明确点了哪几条，就复制哪几条），
    /// 消息顺序保持会话时间序，与选择先后无关。
    public static func render(_ conv: Conversation, prefs: CopyPreferences,
                              isZh: Bool = true,
                              onlyMessageIds: Set<String>? = nil) -> String {
        var msgs = conv.messages
        if let only = onlyMessageIds {
            msgs = msgs.filter { only.contains($0.id) }
        } else {
            switch prefs.scope {
            case .all:      break
            case .userOnly: msgs = msgs.filter { $0.role == .user }
            case .recent:   msgs = Array(msgs.suffix(prefs.recentTurns))
            }
        }

        var parts: [String] = []
        if prefs.includeHeader {
            let proj = projectName(conv.cwd)
            let tool = conv.source.displayName(isZh: isZh)
            var head: String
            if isZh {
                let where_ = proj.isEmpty ? "" : "「\(proj)」"
                head = "这是我之前在\(where_)用 \(tool) 讨论的项目历史，现在请你接手继续。"
            } else {
                let where_ = proj.isEmpty ? "" : " in “\(proj)”"
                head = "This is the history of a project I discussed\(where_) using \(tool). Please pick it up from here."
            }
            let root = conv.cwd.hasSuffix("/") ? String(conv.cwd.dropLast()) : conv.cwd
            if !root.isEmpty {
                head += isZh
                    ? "\n项目根目录：\(root)（若你能访问本地文件，可直接到此目录读取代码；不能也没关系，下面的决策脉络已足够接手）。"
                    : "\nProject root: \(root) (if you can access local files, read the code there directly; if not, the decision trail below is enough to take over)."
            }
            head += isZh
                ? "\n以下只给你决策脉络（已省略代码与工具输出）："
                : "\nBelow is the decision trail only (code and tool output omitted):"
            parts.append(head)
        }

        for m in msgs {
            // 只留对话价值：thinking/toolUse/toolResult/image 是接力噪音（可重获或零接手价值），无条件丢；
            // 代码受 stripCode 控制（新模型读文件即可）；text 保留。
            let kept = m.blocks.compactMap { block -> String? in
                switch block {
                case .text(let t):    return t
                case .code(_, let t): return prefs.stripCode ? nil : t
                case .toolUse, .toolResult, .thinking, .image: return nil
                }
            }
            var text = kept.joined(separator: "\n\n")
            if prefs.stripCode { text = stripCodeBlocks(text, isZh: isZh) }   // 处理 text 内嵌的 ``` 围栏
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let role = m.role == .user ? "User:" : "Assistant:"
            parts.append("\(role)\n\(text)")
        }
        return parts.joined(separator: "\n\n---\n\n")
    }

    /// 粗略 token 估算：CJK 字 ≈ 1 token，其余 ≈ 4 字符 / token。
    public static func estimateTokens(_ s: String) -> Int {
        var cjk = 0, other = 0
        for u in s.unicodeScalars {
            if (0x4E00...0x9FFF).contains(u.value) || (0x3040...0x30FF).contains(u.value) {
                cjk += 1
            } else {
                other += 1
            }
        }
        return cjk + other / 4
    }

    // MARK: - 内部

    /// 把每个 ``` 围栏代码块整体替换成一行占位，丢弃块内代码。
    static func stripCodeBlocks(_ text: String, isZh: Bool = true) -> String {
        var out: [String] = []
        var inFence = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("```") {
                if inFence {
                    inFence = false
                } else {
                    inFence = true
                    out.append(isZh ? "[代码已省略，见文件]" : "[code omitted — see files]")
                }
                continue
            }
            if inFence { continue }
            out.append(String(line))
        }
        return out.joined(separator: "\n")
    }

    private static func projectName(_ cwd: String) -> String {
        let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        return trimmed.split(separator: "/").last.map(String.init) ?? ""
    }
}
