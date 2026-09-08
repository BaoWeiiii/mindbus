import Foundation

/// 文件夹标签别名:磁盘上改名过的项目,历史会话的 cwd 还是旧路径——
/// 「旧名 → 新名」的映射信息在旧路径里不存在,只能由用户告诉我们一次。
///
/// 存 `~/.mindbus/folder-aliases.json`(与 vault/minds 并列,能整体带走);
/// 应用点在色键/显示名的最后一步:同别名 → 同键 → 同色,新旧两批会话自动合流。
public final class FolderAliasStore {

    public static let shared = FolderAliasStore()

    /// 别名表:原始色键(旧尾名) → 用户改的新名。链式别名不展开(A→B、B→C 时
    /// A 只解析到 B)——用户想合到 C 直接把 A 改成 C,规则简单可预期。
    private var aliases: [String: String]

    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mindbus", isDirectory: true)
            .appendingPathComponent("folder-aliases.json")
        if let data = FileManager.default.contents(atPath: self.fileURL.path),
           let loaded = try? JSONDecoder().decode([String: String].self, from: data) {
            aliases = loaded
        } else {
            aliases = [:]
        }
    }

    /// 解析:有别名给新名,没有原样返回。
    public func resolve(_ key: String) -> String {
        aliases[key] ?? key
    }

    /// 设置别名并落盘。新名与原名相同(或空白)= 撤销别名。
    public func set(alias newName: String, for key: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == key {
            aliases.removeValue(forKey: key)
        } else {
            aliases[key] = trimmed
        }
        persist()
    }

    public func alias(for key: String) -> String? { aliases[key] }

    private func persist() {
        guard let data = try? JSONEncoder().encode(aliases) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
