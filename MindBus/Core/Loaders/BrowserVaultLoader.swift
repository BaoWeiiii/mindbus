import Foundation

/// Reads conversations the browser extension pushed via Native Messaging.
/// Storage layout (written by NativeMessagingHandler.appendBrowserRecord):
///
///   ~/.mindbus/browser-vault/<source>/<YYYY-MM-DD>.jsonl
///
/// Each line is one captured turn (user + assistant) with shape:
///   { "captured_at": "2026-05-07T...Z",
///     "source": "browser-chatgpt",
///     "url": "...",
///     "messages": [{ "role": "user", "content": "..." }, ...] }
///
/// V1: each line surfaces as its own Conversation in the browser. The Mac
/// Conversation Browser groups by source / time naturally; we don't merge
/// turns into long sessions yet because the extension can't reliably tell
/// when a session starts/ends.
public enum BrowserVaultLoader {

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

    /// Parse a single JSONL line into a Conversation. Each line is its own
    /// short conversation containing the captured user/assistant turns.
    public static func parseLine(_ line: String, fileURL: URL, lineIndex: Int) -> Conversation? {
        guard !line.isEmpty, line.first == "{",
              let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // captured_at 解析不出就丢弃该行：兜底 Date()（=扫描那一刻）会让这条
        // 采集记录永远浮在列表顶端、且每轮全量重载都变一次时间，污染排序不如不要。
        let tsStr = (obj["captured_at"] as? String) ?? ""
        guard let baseTs = iso8601.date(from: tsStr)
            ?? iso8601NoFraction.date(from: tsStr) else { return nil }
        let sourceTag = (obj["source"] as? String) ?? "browser"
        let url = (obj["url"] as? String) ?? ""
        let raw = (obj["messages"] as? [[String: Any]]) ?? []

        var messages: [Message] = []
        for (i, m) in raw.enumerated() {
            guard let roleStr = m["role"] as? String,
                  let content = m["content"] as? String,
                  !content.isEmpty
            else { continue }
            let role: MessageRole
            switch roleStr {
            case "user": role = .user
            case "assistant": role = .assistant
            default: continue
            }
            let id = "\(tsStr)-\(i)"
            let ts = baseTs.addingTimeInterval(Double(i) / 1000.0)
            messages.append(Message(id: id, role: role, timestamp: ts, blocks: [.text(content)]))
        }

        guard !messages.isEmpty else { return nil }

        // source 子目录（browser-vault/<source>/<date>.jsonl）限定 id，
        // 否则同一天不同平台的 <date>.jsonl#<line> 会撞（多平台用户核心场景）。
        let sourceDir = fileURL.deletingLastPathComponent().lastPathComponent
        let id = "\(sourceDir)/\(fileURL.lastPathComponent)#\(lineIndex)"
        return Conversation(
            id: id,
            source: .browser,
            startAt: messages.first!.timestamp,
            endAt: messages.last!.timestamp,
            cwd: sourceTag,        // store browser-{platform} here for display
            gitBranch: url.isEmpty ? nil : url,
            messages: messages
        )
    }

    public static func loadConversation(fileURL: URL) throws -> [Conversation] {
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = content.components(separatedBy: "\n")
        var out: [Conversation] = []
        for (i, line) in lines.enumerated() {
            if let conv = parseLine(line, fileURL: fileURL, lineIndex: i) {
                out.append(conv)
            }
        }
        return out
    }

    /// 把索引行 id（`<source目录>/<文件名>#<行号>`，见 parseLine 的 id 生成）解析回
    /// vault 内的具体文件与行号。id 非法 / 试图越出 vault 目录时返回 nil。
    public static func resolve(id: String,
                               rootDir: URL = BrowserVaultLoader.defaultRootDir)
        -> (fileURL: URL, lineIndex: Int)? {
        guard let hash = id.lastIndex(of: "#"),
              let lineIndex = Int(id[id.index(after: hash)...]), lineIndex >= 0 else { return nil }
        let relPath = String(id[..<hash])
        guard !relPath.isEmpty, !relPath.contains(".."), !relPath.hasPrefix("/") else { return nil }
        return (rootDir.appendingPathComponent(relPath), lineIndex)
    }

    /// 按索引行 id 取回单条对话（详情面板用）。
    ///
    /// browser 行是「1 文件 N 对话」，索引里的 file_path 是伪路径（= conv.id），
    /// 走不了通用的「按文件整解析」详情链路——此前详情分支直接 return nil，
    /// 点开任何 browser 对话都显示「源文件已无法读取」。
    /// 行号定位与 loadConversation 同一套 `components(separatedBy: "\n")` 口径，
    /// 保证取回的行就是入库时的那一行；parseLine 会重新生成同一个 id。
    public static func loadSingle(id: String,
                                  rootDir: URL = BrowserVaultLoader.defaultRootDir) -> Conversation? {
        guard let (fileURL, lineIndex) = resolve(id: id, rootDir: rootDir),
              let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        let lines = content.components(separatedBy: "\n")
        guard lineIndex < lines.count else { return nil }
        return parseLine(lines[lineIndex], fileURL: fileURL, lineIndex: lineIndex)
    }

    public static func loadAll(rootDir: URL = BrowserVaultLoader.defaultRootDir) -> [Conversation] {
        let urls = enumerateJsonl(in: rootDir)
        var conversations: [Conversation] = []
        for url in urls {
            if let convs = try? loadConversation(fileURL: url) {
                conversations.append(contentsOf: convs)
            }
        }
        conversations.sort { $0.startAt > $1.startAt }
        return conversations
    }

    /// 写入索引：1 文件 N 对话，整段替换 source='browser'（全量重载）。
    public static func loadAll(into index: ConversationIndex,
                              rootDir: URL = BrowserVaultLoader.defaultRootDir) {
        index.replaceBrowserVault(loadAll(rootDir: rootDir))
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

    /// `~/.mindbus/browser-vault`
    public static var defaultRootDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mindbus")
            .appendingPathComponent("browser-vault")
    }
}
