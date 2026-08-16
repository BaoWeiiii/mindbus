import Foundation

/// Claude Desktop App — Local Agent Mode (cowork mode).
///
/// Claude Desktop's "Local Agent" runs Claude Code inside a per-session VM
/// sandbox. Each sandbox keeps its own `.claude/projects/<encoded>/<id>.jsonl`
/// just like a normal Claude Code install, so the on-disk transcript format
/// is identical to ClaudeCodeLoader's input — only the root directory differs.
///
/// Path:
/// `~/Library/Application Support/Claude/local-agent-mode-sessions/
///    <workspace>/<container>/local_<session>/.claude/projects/<encoded>/<cli-session-id>.jsonl`
///
/// We do not currently surface the metadata file
/// (`local_<session>.json` containing title / model / cliSessionId) — the
/// VM-internal jsonl is the source of truth for messages.
public enum ClaudeAgentLoader {

    public static func loadConversation(fileURL: URL) throws -> Conversation? {
        // Reuse ClaudeCodeLoader's parser, then re-tag the source so the UI
        // colors / filters match the Local Agent column.
        guard let conv = try ClaudeCodeLoader.loadConversation(fileURL: fileURL) else {
            return nil
        }
        return Conversation(
            id: conv.id,
            source: .claudeAgent,
            startAt: conv.startAt,
            endAt: conv.endAt,
            cwd: conv.cwd,
            gitBranch: conv.gitBranch,
            title: conv.title,   // VM 内同为 Claude Code 格式：有 ai-title 就带上，无则 nil
            messages: conv.messages
        )
    }

    public static func loadAll(rootDir: URL = ClaudeAgentLoader.defaultRootDir) -> [Conversation] {
        let urls = enumerateJsonl(in: rootDir)
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
                               rootDir: URL = ClaudeAgentLoader.defaultRootDir) {
        LoaderRuntime.index(urls: enumerateJsonl(in: rootDir), into: index, source: .claudeAgent) {
            try? loadConversation(fileURL: $0)
        }
    }

    /// Walks every `.claude/projects/<encoded>/*.jsonl` reachable below the
    /// local-agent-mode-sessions root. The directory is several levels deep
    /// (workspace → container → local_session → .claude → projects → encoded),
    /// so we enumerate recursively and filter by suffix.
    public static func enumerateJsonl(in dir: URL) -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return [] }
        // Don't skip hidden files: the path goes through `.claude/projects/`,
        // which `.skipsHiddenFiles` would otherwise prune.
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }
        var urls: [URL] = []
        for case let url as URL in enumerator
            where url.pathExtension == "jsonl"
            && url.path.contains("/.claude/projects/")
        {
            urls.append(url)
        }
        return urls
    }

    /// `~/Library/Application Support/Claude/local-agent-mode-sessions`
    public static var defaultRootDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Claude")
            .appendingPathComponent("local-agent-mode-sessions")
    }
}
