import Foundation

/// Cursor agent transcripts 没有 timestamp / uuid / cwd。
/// 我们用文件 mtime 作为 startAt（每条消息按行号 +1ms 错开），
/// 文件路径中的 workspace ID 作为 cwd 占位。
public enum CursorLoader {

    public static func parseLine(_ line: String, fileTimestamp: Date, lineIndex: Int) -> Message? {
        guard !line.isEmpty, line.first == "{" else { return nil }
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let roleStr = obj["role"] as? String else { return nil }
        let role: MessageRole
        switch roleStr {
        case "user": role = .user
        case "assistant": role = .assistant
        default: return nil
        }
        guard let inner = obj["message"] as? [String: Any] else { return nil }

        let blocks = ContentBlockParser.parse(inner["content"])
        guard !blocks.isEmpty else { return nil }

        let ts = fileTimestamp.addingTimeInterval(Double(lineIndex) / 1000.0)
        let id = "\(fileTimestamp.timeIntervalSince1970)-\(lineIndex)"
        return Message(id: id, role: role, timestamp: ts, blocks: blocks)
    }

    public static func loadConversation(fileURL: URL) throws -> Conversation? {
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileMTime = (attrs[.modificationDate] as? Date) ?? Date()
        var messages: [Message] = []
        var idx = 0
        try JSONLReader.forEachLine(fileURL: fileURL) { line in
            if let msg = parseLine(line, fileTimestamp: fileMTime, lineIndex: idx) {
                messages.append(msg)
            }
            idx += 1
        }

        guard !messages.isEmpty else { return nil }

        let workspaceId = fileURL
            .deletingLastPathComponent()           // /agent-transcripts/<chat>
            .deletingLastPathComponent()           // /agent-transcripts
            .deletingLastPathComponent()           // /<workspace>
            .lastPathComponent
        let id = fileURL.deletingPathExtension().lastPathComponent

        return Conversation(
            id: id,
            source: .cursor,
            startAt: messages.first!.timestamp,
            endAt: messages.last!.timestamp,
            cwd: workspaceId,
            gitBranch: nil,
            messages: messages
        )
    }

    public static func loadAll(projectsDir: URL = CursorLoader.defaultProjectsDir) -> [Conversation] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: projectsDir.path) else { return [] }

        var conversations: [Conversation] = []
        guard let enumerator = fm.enumerator(
            at: projectsDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
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
                               projectsDir: URL = CursorLoader.defaultProjectsDir) {
        LoaderRuntime.index(urls: enumerateJsonl(in: projectsDir), into: index, source: .cursor) {
            try? loadConversation(fileURL: $0)
        }
    }

    public static func enumerateJsonl(in dir: URL) -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return [] }
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var urls: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            urls.append(url)
        }
        return urls
    }

    /// 默认目录：~/.cursor/projects
    public static var defaultProjectsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor")
            .appendingPathComponent("projects")
    }
}
