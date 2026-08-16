import Foundation

/// 「用户用过哪些工具」的探测：数据根目录里能找到至少一个会话文件。
///
/// 判据取「用过」而非「装了」——装了但从没用过的工具，列表必然是空的，
/// 出现在引导和界面里只制造困惑（用户定案：没有的产品就不显示）。
/// 惰性枚举、首个命中即返回：冷目录毫秒级，探测可以随每次刷新重跑，
/// 用户中途开始用新工具，下一轮刷新它就出现。
public enum SourceDetection {

    public static func detectAvailable() -> Set<ConversationSource> {
        var found: Set<ConversationSource> = []
        // Claude Code：排除内置标记目录（observer 元日志）与用户 ignore 目录——
        // 只剩被排除数据的机器不该亮出这个工具
        if hasSessionFile(under: ClaudeCodeLoader.defaultProjectsDir,
                          excluding: ClaudeCodeLoader.isExcludedPath) {
            found.insert(.claudeCode)
        }
        if hasSessionFile(under: ClaudeAgentLoader.defaultRootDir) {
            found.insert(.claudeAgent)
        }
        if hasSessionFile(under: CodexLoader.defaultSessionsDir) {
            found.insert(.codex)
        }
        return found
    }

    /// 目录下（含子目录，不跳隐藏——Claude Desktop 的会话在 `.claude` 下）
    /// 是否存在至少一个 .jsonl。
    static func hasSessionFile(under dir: URL,
                               excluding: (String) -> Bool = { _ in false }) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path),
              let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return false
        }
        for case let u as URL in e
            where u.pathExtension == "jsonl" && !excluding(u.path) {
            return true
        }
        return false
    }
}
