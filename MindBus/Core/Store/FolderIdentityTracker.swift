import Foundation

/// 文件夹身份追踪:用 inode 自动发现「项目目录改名」。
///
/// 原理:目录在同一文件系统内改名,路径变而 (device, inode) 不变。每轮扫描收尾
/// 对索引里全部不同 cwd 各做一次 stat(百级目录,毫秒量级),把「身份 → 最后已知
/// 路径」记进 `~/.mindbus/folder-identity.json`;当某身份的现路径与上次记录不同,
/// 就是一次改名——自动写入 FolderAliasStore(旧尾名 → 新尾名),历史会话的标签
/// 随之合流到新名。
///
/// 与人工别名的关系:**人工优先**——某旧名已有别名记录时自动机制不碰它;
/// 自动写入的条目用户随时可右键改掉。
/// 局限(如实):只能治「开始记录之后」的改名——更早发生的改名没有 inode 对照,
/// 仍走右键人工别名。
public enum FolderIdentityTracker {

    public static var defaultStoreURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mindbus", isDirectory: true)
            .appendingPathComponent("folder-identity.json")
    }

    /// 一轮追踪:记录现存目录身份、发现改名、写自动别名。
    /// 返回本轮发现的改名对(旧尾名 → 新尾名),供日志/测试。
    @discardableResult
    public static func track(cwds: [String],
                             storeURL: URL = defaultStoreURL,
                             aliasStore: FolderAliasStore = .shared) -> [(old: String, new: String)] {
        var identity: [String: String] = [:]   // "dev:ino" → 最后已知路径
        if let data = FileManager.default.contents(atPath: storeURL.path),
           let loaded = try? JSONDecoder().decode([String: String].self, from: data) {
            identity = loaded
        }

        var renames: [(old: String, new: String)] = []
        for cwd in Set(cwds) where cwd.hasPrefix("/") {
            guard let id = identityKey(of: cwd) else { continue }   // 目录已不存在:无从 stat
            if let lastKnown = identity[id], lastKnown != cwd {
                // 同一身份换了路径 = 改名(或移动)。按尾名建别名——标签以尾名为键。
                let oldName = (lastKnown as NSString).lastPathComponent
                let newName = (cwd as NSString).lastPathComponent
                if oldName != newName, !oldName.isEmpty, !newName.isEmpty,
                   aliasStore.alias(for: oldName) == nil {   // 人工设过的不碰
                    aliasStore.set(alias: newName, for: oldName)
                    renames.append((oldName, newName))
                }
            }
            identity[id] = cwd
        }

        if let data = try? JSONEncoder().encode(identity) {
            try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: storeURL, options: .atomic)
        }
        return renames
    }

    /// 目录身份:"设备号:inode"。目录不存在返回 nil。
    static func identityKey(of path: String) -> String? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return "\(st.st_dev):\(st.st_ino)"
    }
}
