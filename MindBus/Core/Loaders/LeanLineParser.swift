import Foundation

/// 流式路径的精简行解码(2026-08-15,malloc 池根治):`JSONDecoder`+Codable 值类型,
/// 字节直达 struct——不再为每行建 NSDictionary 全树(NSString/NSNumber 盒子是
/// 首建 malloc 池水位的根,vmmap 定性 6.5 万+小块、七轮删库实测峰值恒 1.2-2GB)。
/// 未声明字段被解码器流式跳过,近零分配。
///
/// 等价性纪律:每个分支镜像 `ContentBlockParser.parse` 与 `parseObject`/`parseLine`,
/// `LeanParserParityTests` 逐 fixture 锁死。唯一已知差异:tool_use input 的 JSON
/// 字符串化按 key 字典序(NSDictionary 枚举序不可复刻)——只影响该字符串的 key
/// 顺序,trigram 检索无感,测试对它做语义比较。
/// 仅流式路径(≥8MB 大文件)使用;全量路径(详情/小文件)保持 JSONSerialization。
enum LeanLineParser {

    // MARK: - 任意 JSON 子树(tool_use.input 承接)

    indirect enum JSONValue: Decodable {
        case string(String), number(Double), bool(Bool), null
        case array([JSONValue]), object([String: JSONValue])

        init(from decoder: Decoder) throws {
            if var arr = try? decoder.unkeyedContainer() {
                var out: [JSONValue] = []
                while !arr.isAtEnd { out.append(try arr.decode(JSONValue.self)) }
                self = .array(out)
                return
            }
            if let obj = try? decoder.container(keyedBy: RawKey.self) {
                var out: [String: JSONValue] = [:]
                for key in obj.allKeys {
                    out[key.stringValue] = try obj.decode(JSONValue.self, forKey: key)
                }
                self = .object(out)
                return
            }
            let single = try decoder.singleValueContainer()
            if single.decodeNil() { self = .null }
            else if let b = try? single.decode(Bool.self) { self = .bool(b) }
            else if let n = try? single.decode(Double.self) { self = .number(n) }
            else { self = .string(try single.decode(String.self)) }
        }

        /// compact JSON,object key 按字典序(见文件头注释的已知差异)。
        var compactJSON: String {
            switch self {
            case .string(let s):
                let esc = s.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                    .replacingOccurrences(of: "\n", with: "\\n")
                    .replacingOccurrences(of: "\r", with: "\\r")
                    .replacingOccurrences(of: "\t", with: "\\t")
                return "\"\(esc)\""
            case .number(let d):
                return d == d.rounded() && abs(d) < 1e15
                    ? String(Int64(d)) : String(d)
            case .bool(let b): return b ? "true" : "false"
            case .null: return "null"
            case .array(let a): return "[" + a.map(\.compactJSON).joined(separator: ",") + "]"
            case .object(let o):
                let inner = o.sorted { $0.key < $1.key }
                    .map { "\"\($0.key)\":\($0.value.compactJSON)" }
                    .joined(separator: ",")
                return "{" + inner + "}"
            }
        }
    }

    struct RawKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    // MARK: - Claude Code 行模型

    struct CCLine: Decodable {
        let type: String?
        let isSidechain: Bool?
        let cwd: String?
        let gitBranch: String?
        let sessionId: String?
        let aiTitle: String?
        let uuid: String?
        let timestamp: String?
        let message: CCMessage?
    }

    struct CCMessage: Decodable {
        let role: String?
        let content: CCContent?
    }

    enum CCContent: Decodable {
        case plain(String)
        case blocks([CCBlock])

        init(from decoder: Decoder) throws {
            let single = try? decoder.singleValueContainer()
            if let s = try? single?.decode(String.self) { self = .plain(s); return }
            if let b = try? single?.decode([CCBlock].self) { self = .blocks(b); return }
            self = .blocks([])   // 未知形态 = 无块(镜像 ContentBlockParser 的 guard 失败)
        }
    }

    struct CCBlock: Decodable {
        let type: String?
        let text: String?
        let thinking: String?
        let name: String?
        let input: JSONValue?
        let content: CCToolResultContent?
        let source: CCImageSource?
    }

    enum CCToolResultContent: Decodable {
        case plain(String)
        case parts([CCTextPart])
        case other

        init(from decoder: Decoder) throws {
            let single = try? decoder.singleValueContainer()
            if let s = try? single?.decode(String.self) { self = .plain(s); return }
            if let p = try? single?.decode([CCTextPart].self) { self = .parts(p); return }
            self = .other
        }
    }

    struct CCTextPart: Decodable { let text: String? }

    struct CCImageSource: Decodable {
        let type: String?
        let media_type: String?
        let data: String?
        let url: String?
    }

    // MARK: - 块转换(镜像 ContentBlockParser.parse 逐分支)

    static func blocks(from content: CCContent?) -> [ContentBlock] {
        switch content {
        case .plain(let s):
            return [.text(s)]
        case .blocks(let arr):
            var result: [ContentBlock] = []
            for block in arr {
                guard let type = block.type else { continue }
                switch type {
                case "text":
                    if let t = block.text { result.append(.text(t)) }
                case "tool_use":
                    let name = block.name ?? "unknown"
                    let inputJSON: String
                    if case .object = block.input {
                        inputJSON = block.input!.compactJSON
                    } else {
                        // 原版 input 非字典 → 空字典序列化 "{}"
                        inputJSON = "{}"
                    }
                    result.append(.toolUse(name: name, input: inputJSON))
                case "tool_result":
                    switch block.content {
                    case .plain(let t): result.append(.toolResult(text: t))
                    case .parts(let parts):
                        result.append(.toolResult(
                            text: parts.compactMap(\.text).joined(separator: "\n")))
                    case .other, nil: break
                    }
                case "thinking":
                    if let t = block.thinking ?? block.text { result.append(.thinking(t)) }
                case "image":
                    let mediaType = block.source?.media_type ?? "unknown"
                    let imageSource: ImageSource
                    switch block.source?.type {
                    case "base64": imageSource = block.source?.data.map { .base64($0) } ?? .unknown
                    case "url": imageSource = block.source?.url.map { .url($0) } ?? .unknown
                    default: imageSource = .unknown
                    }
                    result.append(.image(mediaType: mediaType, source: imageSource))
                default:
                    continue
                }
            }
            return result
        case nil:
            return []
        }
    }

    // MARK: - Claude Code 行 → Message(镜像 parseObject)

    static func decodeCCLine(_ line: String) -> CCLine? {
        try? JSONDecoder().decode(CCLine.self, from: Data(line.utf8))
    }

    static func ccMessage(from l: CCLine) -> Message? {
        guard let typeStr = l.type,
              let role: MessageRole = {
                  switch typeStr {
                  case "user": return .user
                  case "assistant": return .assistant
                  default:
                      FormatTelemetry.shared.note(source: "claudeCode", type: typeStr)
                      return nil
                  }
              }() else { return nil }
        guard let uuid = l.uuid, let tsStr = l.timestamp,
              let ts = ClaudeCodeLoader.parseTimestamp(tsStr) else { return nil }
        guard let message = l.message else { return nil }

        var blocks = Self.blocks(from: message.content)
        if role == .user {
            blocks = blocks.compactMap { block -> ContentBlock? in
                switch block {
                case .toolResult:
                    return nil
                case .text(let t):
                    if ClaudeCodeLoader.isInjectedUserText(t) { return nil }
                    let s = ClaudeCodeLoader.stripSystemReminders(t)
                    return s.isEmpty ? nil : .text(s)
                default:
                    return block
                }
            }
            guard !blocks.isEmpty else { return nil }
        }
        return Message(id: uuid, role: role, timestamp: ts, blocks: blocks)
    }

    // MARK: - Codex 行模型(镜像 CodexLoader.parseLine)

    struct CXLine: Decodable {
        let type: String?
        let timestamp: String?
        let payload: CXPayload?
    }

    struct CXPayload: Decodable {
        let type: String?
        let role: String?
        let id: String?
        let cwd: String?
        let parent_thread_id: String?
        let content: [CXContent]?
    }

    struct CXContent: Decodable {
        let type: String?
        let text: String?
        let image_url: String?
    }

    static func decodeCXLine(_ line: String) -> CXLine? {
        try? JSONDecoder().decode(CXLine.self, from: Data(line.utf8))
    }

    /// Codex 行 → Message(镜像 `CodexLoader.parseLine` 全分支:白名单遥测/角色/
    /// 注入过滤/用户附件图/时间戳拒缺/行序 id)。
    static func cxMessage(from l: CXLine, lineIndex: Int?) -> Message? {
        guard l.type == "response_item", let payload = l.payload else { return nil }
        guard payload.type == "message" else {
            FormatTelemetry.shared.note(source: "codex", type: payload.type ?? "?")
            return nil
        }
        guard let roleStr = payload.role else { return nil }
        let role: MessageRole
        switch roleStr {
        case "user": role = .user
        case "assistant": role = .assistant
        default: return nil
        }

        let content = payload.content ?? []
        var texts: [String] = []
        for c in content {
            let cType = c.type ?? ""
            if cType == "input_text" || cType == "output_text" || cType == "summary_text" {
                if let t = c.text, !t.isEmpty { texts.append(t) }
            }
        }
        if role == .user {
            texts = texts.filter { !CodexLoader.isAutoInjectedUserText($0) }
        }
        guard !texts.isEmpty else { return nil }
        let merged = texts.joined(separator: "\n")

        var blocks: [ContentBlock] = [.text(merged)]
        if role == .user && merged.contains("# Files mentioned by the user:") {
            for c in content where c.type == "input_image" {
                if let urlStr = c.image_url,
                   let img = CodexLoader.parseDataURIImage(urlStr) {
                    blocks.append(img)
                }
            }
        }

        let tsStr = l.timestamp ?? ""
        guard let ts = CodexLoader.parseTimestamp(tsStr) else { return nil }
        let id = lineIndex.map { "\(tsStr)-\(roleStr)-\($0)" } ?? "\(tsStr)-\(roleStr)"
        return Message(id: id, role: role, timestamp: ts, blocks: blocks)
    }
}
