import Foundation

/// 把 `mindbus-mcp` 写进宿主工具的 MCP 配置——纯文本 / JSON 变换，不做 IO，便于测试。
///
/// - Claude Code：`~/.claude.json` 顶层 `mcpServers.mindbus`，形状与 `claude mcp add --scope user`
///   写出的一致（`{"type":"stdio","command":…,"args":[],"env":{}}`），文件其余内容原样保留。
/// - Codex：`~/.codex/config.toml` 的 `[mcp_servers.mindbus]` 段；不解析 TOML，只按行找段头、
///   到下一个段头为止，其余文本一字不动。
public enum MCPHostConfig {

    public static let serverName = "mindbus"

    public enum ConfigError: Error, Equatable {
        case invalidJSON
    }

    // MARK: - Claude Code（~/.claude.json）

    public static func claudeCodeHas(json: Data?) -> Bool {
        guard let dict = parse(json) else { return false }
        return (dict["mcpServers"] as? [String: Any])?[serverName] != nil
    }

    /// 文件不存在 / 为空 → 从 `{}` 起步；存在但不是合法 JSON → 抛错，绝不覆盖用户的文件。
    public static func claudeCodeAdd(json: Data?, serverPath: String) throws -> Data {
        var dict: [String: Any]
        if let json, !json.isEmpty {
            guard let parsed = parse(json) else { throw ConfigError.invalidJSON }
            dict = parsed
        } else {
            dict = [:]
        }
        var servers = dict["mcpServers"] as? [String: Any] ?? [:]
        servers[serverName] = [
            "type": "stdio",
            "command": serverPath,
            "args": [String](),
            "env": [String: String](),
        ]
        dict["mcpServers"] = servers
        return try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
    }

    public static func claudeCodeRemove(json: Data) throws -> Data {
        guard var dict = parse(json) else { throw ConfigError.invalidJSON }
        guard var servers = dict["mcpServers"] as? [String: Any], servers[serverName] != nil else { return json }
        servers.removeValue(forKey: serverName)
        dict["mcpServers"] = servers
        return try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
    }

    private static func parse(_ data: Data?) -> [String: Any]? {
        guard let data, !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - Codex（~/.codex/config.toml）

    static let codexHeader = "[mcp_servers.\(serverName)]"

    public static func codexHas(toml: String) -> Bool {
        sectionBounds(in: toml.components(separatedBy: "\n")) != nil
    }

    /// 已有同名段先移除再追加，保证只有一份。
    public static func codexAdd(toml: String, serverPath: String) -> String {
        var out = codexRemove(toml: toml)
        if !out.isEmpty {
            if !out.hasSuffix("\n") { out += "\n" }
            if !out.hasSuffix("\n\n") { out += "\n" }
        }
        out += "\(codexHeader)\ncommand = \"\(tomlEscape(serverPath))\"\n"
        return out
    }

    public static func codexRemove(toml: String) -> String {
        let lines = toml.components(separatedBy: "\n")
        guard let (start, end) = sectionBounds(in: lines) else { return toml }
        var out = (Array(lines[..<start]) + Array(lines[end...])).joined(separator: "\n")
        while out.contains("\n\n\n") {
            out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return out
    }

    /// 段范围 [start, end)：段头那一行到下一个 `[` 开头的段头（或文件尾）。
    private static func sectionBounds(in lines: [String]) -> (Int, Int)? {
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == codexHeader
        }) else { return nil }
        var end = start + 1
        while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("[") {
            end += 1
        }
        return (start, end)
    }

    static func tomlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
