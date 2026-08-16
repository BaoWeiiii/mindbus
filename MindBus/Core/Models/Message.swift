import Foundation

public enum MessageRole: String, Equatable, Hashable {
    case user
    case assistant
}

public struct Message: Identifiable, Equatable, Hashable {
    public let id: String
    public let role: MessageRole
    public let timestamp: Date
    public let blocks: [ContentBlock]

    public init(id: String, role: MessageRole, timestamp: Date, blocks: [ContentBlock]) {
        self.id = id
        self.role = role
        self.timestamp = timestamp
        self.blocks = blocks
    }

    /// 第一个 text block 的文本，用于列表预览
    public var firstTextBlock: String? {
        for block in blocks {
            if case .text(let t) = block, !t.isEmpty {
                return t
            }
        }
        return nil
    }
}

// MARK: - 索引路径减重

extension ContentBlock {
    /// 索引口径的文本上限截断:检索段有 4000 字软顶/200K 硬顶,超限 block 的
    /// 尾部对索引零边际,却让巨型会话 parse 峰值破 GB(真机 720MB rollout)。
    /// 图片 payload 直接置空占位——检索/实体/语料三个口径都排除图片内容。
    /// 详情路径不走这里,显示永远全量。
    func cappedForIndexing(_ cap: Int) -> ContentBlock {
        switch self {
        case .text(let t) where t.count > cap:
            return .text(String(t.prefix(cap)))
        case .code(let lang, let t) where t.count > cap:
            return .code(language: lang, text: String(t.prefix(cap)))
        case .toolUse(let n, let input) where input.count > cap:
            return .toolUse(name: n, input: String(input.prefix(cap)))
        case .toolResult(let t) where t.count > cap:
            return .toolResult(text: String(t.prefix(cap)))
        case .thinking(let t) where t.count > cap:
            return .thinking(String(t.prefix(cap)))
        case .image(let media, _):
            return .image(mediaType: media, source: .url(""))
        default:
            return self
        }
    }

    var indexingTextCount: Int {
        switch self {
        case .text(let t): return t.count
        case .code(_, let t): return t.count
        case .toolUse(_, let input): return input.count
        case .toolResult(let t): return t.count
        case .thinking(let t): return t.count
        case .image: return 0
        }
    }
}

extension Message {
    /// 索引路径的消息减重:单 block 截 `blockCap`;`textStripped` 时全部文本清空、
    /// 只留结构(角色/时间戳撑起计数与段切分)——「会话文本预算」耗尽后的形态,
    /// 与段级 hardTextCap 同一哲学:超长内容的尾部截断只影响尾部可搜性。
    func cappedForIndexing(blockCap: Int, textStripped: Bool) -> Message {
        let newBlocks: [ContentBlock] = blocks.map { block in
            if textStripped {
                switch block {
                case .image(let media, _): return .image(mediaType: media, source: .url(""))
                default: return block.cappedForIndexing(0)
                }
            }
            return block.cappedForIndexing(blockCap)
        }
        return Message(id: id, role: role, timestamp: timestamp, blocks: newBlocks)
    }

    var indexingTextCount: Int { blocks.reduce(0) { $0 + $1.indexingTextCount } }
}
