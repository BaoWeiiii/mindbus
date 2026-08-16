import Foundation

/// 用户级采集排除规则：`~/.mindbus/ignore`，每行一个**绝对目录路径**
///（`#` 注释、空行忽略）。命中目录里的会话不进对话库。
///
/// 为「定时任务 / 无头自动化在某目录跑 Claude」这类非人肉会话准备的机制
///（AutoCron 幽灵案的产品化答案）：LaunchAgent 每天在固定目录 `claude -p`
/// 跑批，产生的会话不是用户对话，不该出现在库里。
///
/// 匹配两式：
/// - 文件路径直接以规则目录为前缀（会话文件就放在该目录下的源）；
/// - Claude Code 项目目录名 = cwd 的 `/`→`-` 编码
///  （`/Users/a/dev/X` → `-Users-a-dev-X`），按父目录名精确或子目录前缀匹配。
///
/// 已入库的存量无需政策 bump：枚举层缺席 → LoaderRuntime 的 missing prune
/// 自动清除；把规则从文件里删掉，下轮扫描会话自然回库（源文件一直都在）。
public enum IgnoreRules {

    public static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mindbus")
            .appendingPathComponent("ignore")
    }

    private static let lock = NSLock()
    private static var cached: (mtime: Date?, rules: [String])?

    /// 读规则（mtime 缓存：文件未变不重读；不存在 = 无规则）。
    public static func rules() -> [String] {
        let url = fileURL
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        lock.lock(); defer { lock.unlock() }
        if let c = cached, c.mtime == mtime { return c.rules }
        let parsed = parse((try? String(contentsOf: url, encoding: .utf8)) ?? "")
        cached = (mtime, parsed)
        return parsed
    }

    /// 行解析：trim、去注释与空行、去尾部斜杠（规范化前缀匹配）。
    static func parse(_ text: String) -> [String] {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
    }

    /// Claude Code 项目目录名编码：`/Users/a/dev/X` → `-Users-a-dev-X`。
    static func claudeProjectDirName(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-")
    }

    /// 纯函数判定（测试打这里）：jsonl 路径是否命中任一规则。
    static func matches(jsonlPath: String, rules: [String]) -> Bool {
        guard !rules.isEmpty else { return false }
        let parentDir = URL(fileURLWithPath: jsonlPath)
            .deletingLastPathComponent().lastPathComponent
        for r in rules {
            if jsonlPath.hasPrefix(r + "/") { return true }
            let enc = claudeProjectDirName(r)
            if parentDir == enc || parentDir.hasPrefix(enc + "-") { return true }
        }
        return false
    }

    /// 便捷入口：按当前用户规则判定。
    public static func matches(path: String) -> Bool {
        matches(jsonlPath: path, rules: rules())
    }
}
