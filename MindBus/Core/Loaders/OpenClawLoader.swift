import Foundation

public enum OpenClawLoader {

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601NoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// 解析单行 JSONL。仅当 type == "message" 且 role 是 user/assistant 时返回 Message；
    /// session/model_change/thinking_level_change 等元数据行返回 nil。
    public static func parseLine(_ line: String) -> Message? {
        guard !line.isEmpty, line.first == "{" else { return nil }
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard (obj["type"] as? String) == "message" else { return nil }
        guard let id = obj["id"] as? String,
              let tsStr = obj["timestamp"] as? String,
              let ts = iso8601.date(from: tsStr) ?? iso8601NoFraction.date(from: tsStr) else {
            return nil
        }
        guard let inner = obj["message"] as? [String: Any],
              let roleStr = inner["role"] as? String else {
            return nil
        }
        let role: MessageRole
        switch roleStr {
        case "user": role = .user
        case "assistant": role = .assistant
        default: return nil
        }

        let blocks = ContentBlockParser.parse(inner["content"])
        return Message(id: id, role: role, timestamp: ts, blocks: blocks)
    }

    public static func loadConversation(fileURL: URL) throws -> Conversation? {
        var messages: [Message] = []
        var cwd: String = ""
        var sessionId: String? = nil

        try JSONLReader.forEachLine(fileURL: fileURL) { line in
            guard !line.isEmpty, line.first == "{" else { return }

            if cwd.isEmpty || sessionId == nil {
                if let data = line.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   (obj["type"] as? String) == "session" {
                    if let c = obj["cwd"] as? String { cwd = c }
                    if let s = obj["id"] as? String { sessionId = s }
                }
            }

            if let msg = parseLine(line) {
                messages.append(msg)
            }
        }

        guard !messages.isEmpty else { return nil }
        messages.sort { $0.timestamp < $1.timestamp }

        let id = sessionId ?? fileURL.deletingPathExtension().lastPathComponent
        return Conversation(
            id: id,
            source: .openclaw,
            startAt: messages.first!.timestamp,
            endAt: messages.last!.timestamp,
            cwd: cwd,
            gitBranch: nil,
            messages: messages
        )
    }

    public static func loadAll(rootDir: URL = OpenClawLoader.defaultRootDir) -> [Conversation] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: rootDir.path) else { return [] }

        var conversations: [Conversation] = []
        guard let enumerator = fm.enumerator(
            at: rootDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for case let fileURL as URL in enumerator {
            // 仅扫 agents/<agent>/sessions/*.jsonl
            guard fileURL.pathExtension == "jsonl",
                  fileURL.deletingLastPathComponent().lastPathComponent == "sessions" else {
                continue
            }
            do {
                if let conv = try loadConversation(fileURL: fileURL) {
                    conversations.append(conv)
                }
            } catch {
                continue
            }
        }

        conversations.sort { $0.startAt > $1.startAt }
        return conversations
    }

    /// 写入索引（增量）。
    public static func loadAll(into index: ConversationIndex,
                               rootDir: URL = OpenClawLoader.defaultRootDir) {
        LoaderRuntime.index(urls: enumerateSessionJsonl(in: rootDir), into: index, source: .openclaw) {
            try? loadConversation(fileURL: $0)
        }
    }

    public static func enumerateSessionJsonl(in dir: URL) -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return [] }
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var urls: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  url.deletingLastPathComponent().lastPathComponent == "sessions" else {
                continue
            }
            urls.append(url)
        }
        return urls
    }

    /// 默认根目录：~/.openclaw/agents
    public static var defaultRootDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclaw")
            .appendingPathComponent("agents")
    }
}
