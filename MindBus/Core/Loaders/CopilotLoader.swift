import Foundation

/// VS Code Copilot Chat sessions are stored as JSONL "operation logs":
/// - kind=0  initial snapshot, with full `requests` array
/// - kind=1  field patch  (k=path, v=new value)
/// - kind=2  array replace (k=path, v=new array). The `requests` array is
///           rewritten this way after every turn.
///
/// To reconstruct a session, fold every line that touches `["requests"]`
/// and read the final state.
public enum CopilotLoader {

    /// Parse a single request entry into ordered Messages (user + assistant).
    public static func messagesFrom(request: [String: Any]) -> [Message] {
        var msgs: [Message] = []
        let tsMs = (request["timestamp"] as? Double) ?? 0
        let baseTs = Date(timeIntervalSince1970: tsMs / 1000.0)
        let reqId = (request["requestId"] as? String) ?? UUID().uuidString

        if let messageObj = request["message"] as? [String: Any],
           let text = messageObj["text"] as? String,
           !text.isEmpty {
            msgs.append(
                Message(
                    id: "\(reqId)-u",
                    role: .user,
                    timestamp: baseTs,
                    blocks: [.text(text)]
                )
            )
        }

        if let response = request["response"] as? [[String: Any]] {
            let parts: [String] = response.compactMap { part -> String? in
                if let s = part["value"] as? String { return s }
                if let dict = part["value"] as? [String: Any],
                   let content = dict["content"] as? [[String: Any]] {
                    return content.compactMap { $0["value"] as? String }
                        .joined(separator: "\n")
                }
                return nil
            }
            let joined = parts.joined(separator: "\n")
            if !joined.isEmpty {
                msgs.append(
                    Message(
                        id: "\(reqId)-a",
                        role: .assistant,
                        timestamp: baseTs.addingTimeInterval(0.001),
                        blocks: [.text(joined)]
                    )
                )
            }
        }
        return msgs
    }

    /// Fold operation-log lines and return the final `requests` array.
    public static func reconstructRequests(from lines: [String]) -> [[String: Any]] {
        var requests: [[String: Any]] = []
        for line in lines {
            guard !line.isEmpty, line.first == "{",
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let kind = obj["kind"] as? Int ?? -1
            switch kind {
            case 0:
                if let v = obj["v"] as? [String: Any],
                   let r = v["requests"] as? [[String: Any]] {
                    requests = r
                }
            case 2:
                if let key = obj["k"] as? [String], key == ["requests"],
                   let v = obj["v"] as? [[String: Any]] {
                    requests = v
                }
            default:
                continue
            }
        }
        return requests
    }

    public static func loadConversation(fileURL: URL) throws -> Conversation? {
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileMTime = (attrs[.modificationDate] as? Date) ?? Date()
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = content.components(separatedBy: "\n")

        let requests = reconstructRequests(from: lines)
        var messages: [Message] = []
        for req in requests {
            messages.append(contentsOf: messagesFrom(request: req))
        }

        guard !messages.isEmpty else { return nil }

        let id = fileURL.deletingPathExtension().lastPathComponent
        // Use parent storage dir as cwd hint (workspace id or "global")
        let cwd: String
        let parent = fileURL.deletingLastPathComponent().lastPathComponent
        if parent == "emptyWindowChatSessions" {
            cwd = "global"
        } else {
            cwd = parent
        }

        let startAt = messages.first?.timestamp ?? fileMTime
        let endAt = messages.last?.timestamp ?? fileMTime

        return Conversation(
            id: id,
            source: .vscodeCopilot,
            startAt: startAt,
            endAt: endAt,
            cwd: cwd,
            gitBranch: nil,
            messages: messages
        )
    }

    public static func loadAll(globalStorageDir: URL = CopilotLoader.defaultGlobalStorageDir)
        -> [Conversation]
    {
        let urls = enumerateJsonl(in: globalStorageDir)
        var conversations: [Conversation] = []
        for url in urls {
            if let conv = try? loadConversation(fileURL: url) {
                conversations.append(conv)
            }
        }
        conversations.sort { $0.startAt > $1.startAt }
        return conversations
    }

    /// 写入索引（增量）。
    public static func loadAll(into index: ConversationIndex,
                               globalStorageDir: URL = CopilotLoader.defaultGlobalStorageDir) {
        LoaderRuntime.index(urls: enumerateJsonl(in: globalStorageDir), into: index, source: .vscodeCopilot) {
            try? loadConversation(fileURL: $0)
        }
    }

    /// Walk both `emptyWindowChatSessions` (global panel) and any
    /// `workspaceStorage/<wsid>/chatSessions` directories under User/.
    public static func enumerateJsonl(in globalStorageDir: URL) -> [URL] {
        let fm = FileManager.default
        var urls: [URL] = []

        let emptyDir = globalStorageDir.appendingPathComponent("emptyWindowChatSessions")
        if fm.fileExists(atPath: emptyDir.path),
           let enumerator = fm.enumerator(
               at: emptyDir,
               includingPropertiesForKeys: [.isRegularFileKey],
               options: [.skipsHiddenFiles]
           )
        {
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                urls.append(url)
            }
        }

        let userDir = globalStorageDir.deletingLastPathComponent()
        let workspaceStorage = userDir.appendingPathComponent("workspaceStorage")
        if fm.fileExists(atPath: workspaceStorage.path),
           let enumerator = fm.enumerator(
               at: workspaceStorage,
               includingPropertiesForKeys: [.isRegularFileKey],
               options: [.skipsHiddenFiles]
           )
        {
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let path = url.path
                if path.contains("chatSessions") || path.contains("ChatSessions") {
                    urls.append(url)
                }
            }
        }
        return urls
    }

    /// Default: ~/Library/Application Support/Code/User/globalStorage
    public static var defaultGlobalStorageDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Code")
            .appendingPathComponent("User")
            .appendingPathComponent("globalStorage")
    }
}
