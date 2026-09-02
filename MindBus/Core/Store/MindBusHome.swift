import Foundation

/// `~/.mindbus`——归档副本、minds.md、收藏/别名/删除记录等落盘根目录的权限守则。
///
/// Claude Code 把 `~/.claude/projects` 锁成 700；MindBus 此前按 umask 022 复制出的
/// 副本却是 755/644——同机其他账号可读，等于把源工具做的隔离降了级。这里统一：
/// 目录 700、文件 600。写盘点很多（vault / minds / 五个 Store），不逐个改写入代码，
/// 而是启动与每轮扫描收尾各跑一次 `tightenPermissions()` 兜底，热路径只在建目录与
/// 写归档时顺手设一次。
public enum MindBusHome {

    public static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mindbus", isDirectory: true)
    }

    public static let dirMode = 0o700
    public static let fileMode = 0o600

    /// 建目录（含中间目录）并设 700；已存在则只收紧权限。
    public static func ensureDirectory(_ url: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: dirMode])
        }
        restrict(url, isDirectory: true)
    }

    /// 单个文件/目录收紧到 600/700。失败静默——只影响权限，不影响功能。
    public static func restrict(_ url: URL, isDirectory: Bool = false) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: isDirectory ? dirMode : fileMode], ofItemAtPath: url.path)
    }

    /// 整个 `~/.mindbus` 一次性收紧。幂等：只改权限不对的条目，稳态一趟只是几千次 stat。
    public static func tightenPermissions(root: URL = root) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return }
        restrict(root, isDirectory: true)
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                    options: []) else { return }
        for case let u as URL in e {
            let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let want = isDir ? dirMode : fileMode
            let current = (try? fm.attributesOfItem(atPath: u.path)[.posixPermissions] as? Int) ?? -1
            if current != want { restrict(u, isDirectory: isDir) }
        }
    }
}
