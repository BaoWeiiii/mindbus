import Foundation
import CryptoKit

/// 自有存储（收藏层）：把源 jsonl 原样拷一份进 MindBus 自己的目录。
///
/// 为什么必须有这一层：在此之前 App 是「别人文件的只读视图」——索引是 contentless（不存原文）、
/// 详情按需回源解析、源文件消失则下次扫描把索引行一起删掉。而 Claude Code 默认
/// `cleanupPeriodDays=30` 会静默删掉会话文件（官方仓 157 条 issue，且有「改了设置也照删」的报告）。
/// 结果就是本机 2026-06-30 之前的对话已经永久灭失。
///
/// 分源两策：
/// - **Claude 系走整拷**（方案 A）：不解析、不过滤，位级保真——未来任何解析器/数据政策
///   升级都能拿原始字节重放。实测压后仅约 93MiB。
/// - **Codex 走过滤拷**（方案 B，见 `CodexArchiveFilter`）：其主会话 2.99GiB 里 62.7% 是
///   agent 截图、22.2% 是遥测，整拷要多占 1.2GiB，而丢掉的正是图片政策早已判定
///   「永不展示」的字节。
///
/// **Codex 侧的取舍是有损的，与 Claude 侧的位级保真承诺并不对等**：过滤会把
/// `event_msg`、`turn_context`、加密 `reasoning`、以及解析不出来的行永久丢弃——
/// 一旦源文件本身消失，这些字节在归档里也找不回来了，打破了「未来任何解析器都能
/// 拿原始字节重放」这一属性。这是为省 1.2GiB 而有意接受的取舍，不是疏忽。
public enum VaultArchive {

    /// 归档根目录。与浏览器采集的 `~/.mindbus/browser-vault/` 并列，
    /// 放在用户看得见、好备份、好整体带走的位置（而非 Application Support 深处）。
    public static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".mindbus", isDirectory: true)
        .appendingPathComponent("vault", isDirectory: true)

    /// 归档覆盖的源。
    /// Claude 系被 30 天清理吞，是最紧迫的；Codex 源目录自身虽无清理策略，
    /// 但「跨工具都保住」是产品承诺，故一并纳入（走过滤拷，见 `needsFilter`）。
    /// browser 源本身就已经是我们自己写的 vault，无需再归档。
    public static func shouldArchive(_ source: ConversationSource) -> Bool {
        source == .claudeCode || source == .claudeAgent || source == .codex
    }

    /// 该路径归档前是否要先过滤。
    ///
    /// Claude 系整拷（位级保真，压后仅约 93MiB）；Codex 必须过滤——其主会话 2.99GiB 里
    /// 62.7% 是 agent 截图、22.2% 是遥测，整拷要多占 1.2GiB，详见 `CodexArchiveFilter`。
    ///
    /// 标为 `public` 是因为它现在也是 `archive(needsFilter:)` 的默认参数值——
    /// Swift 要求默认值表达式的可见性不低于所在函数（`archive` 是 public）。
    public static func needsFilter(_ path: String) -> Bool {
        path.hasPrefix(CodexLoader.defaultSessionsDir.path + "/")
    }

    /// 归档文件路径 = 源路径的 SHA256 十六进制，前 2 位做目录扇出。
    ///
    /// 用散列而不是镜像原目录结构：各 source 的根不同、路径里含中文与特殊字符，
    /// 镜像容易踩文件系统限制；散列确定、定长、天然避免单目录堆几万文件
    /// （扇出布局照 Git LFS 的做法）。源路径本身已存在索引的 file_path 列，
    /// 所以不需要额外的映射表就能反查回来。
    public static func archiveURL(forSourcePath path: String, root: URL = defaultRoot) -> URL {
        let hex = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return root
            .appendingPathComponent(String(hex.prefix(2)), isDirectory: true)
            .appendingPathComponent(hex + ".jsonl.lzma")
    }

    public static func hasArchive(sourcePath: String, root: URL = defaultRoot) -> Bool {
        FileManager.default.fileExists(atPath: archiveURL(forSourcePath: sourcePath, root: root).path)
    }

    /// 删除归档副本(用户删除对话时调用)。删除语义=「从 MindBus 抹除」:
    /// 索引行 + 墓碑 + 这份副本;源文件永远不动。
    public static func removeArchive(sourcePath: String, root: URL = defaultRoot) {
        try? FileManager.default.removeItem(at: archiveURL(forSourcePath: sourcePath, root: root))
    }

    /// 归档单个源文件：整份覆盖写入，不做增量合并。
    /// 这个函数本身不判断「要不要重新归档」——那是调用方 `sweep` 的职责
    /// （源 mtime 新于既有归档时才会再喊它一次）；这里只管把当前整份内容落盘。
    /// 返回是否成功写出。
    ///
    /// `needsFilter` 形参遮蔽同名静态方法、默认值就是那个静态方法——与本文件
    /// `root: URL = defaultRoot` 的注入惯例一致。测试借此绕开「源路径必须真的在
    /// `~/.codex/sessions` 下」的前缀判定，用临时目录文件也能走到过滤分支。
    @discardableResult
    public static func archive(sourcePath: String,
                              root: URL = defaultRoot,
                              needsFilter: (String) -> Bool = VaultArchive.needsFilter) -> Bool {
        // Codex 先流式过滤到临时文件再压：整读一个几百 MB 的 rollout 进内存正是
        // 当初首次建库 1.2GB 峰值的成因，而其中 85% 还是要被丢掉的截图与遥测。
        var bytesSource = URL(fileURLWithPath: sourcePath)
        var scratch: URL?
        defer { if let s = scratch { try? FileManager.default.removeItem(at: s) } }
        if needsFilter(sourcePath) {
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("mindbus-filtered-\(UUID().uuidString).jsonl")
            // 先登记再写，否则 filter 抛错时 defer 兜不住——CodexArchiveFilter.filter
            // 第一行就 createFile 落盘，中途读写错/磁盘满会让半成品文件留在临时目录；
            // 且 archive 返回 false 后 sweep 每轮都判定「源比归档新」重试，不清理
            // 就是每次失败再泄漏一个。
            scratch = tmp
            do {
                try CodexArchiveFilter.filter(source: bytesSource, to: tmp)
            } catch {
                NSLog("[vault] codex filter failed for %@: %@", sourcePath, String(describing: error))
                return false
            }
            bytesSource = tmp
        }
        // 流式压缩(2026-08-15):整读+整压曾要「源文件+压缩产物」同时在内存——
        // 归档 sweep 对 38MB 级一批 Claude 文件逐个整读,与解析并发叠加,是八轮
        // 删库实测「解析侧怎么优化峰值都恒 1.9GB」的真身。现在峰值 O(256KB chunk)。
        // 原子性改为「压到临时文件 → rename」:与 .atomic 写等价,半个归档不会骗过 hasArchive。
        let dest = archiveURL(forSourcePath: sourcePath, root: root)
        let tmpDest = dest.appendingPathExtension("tmp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDest) }
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                   withIntermediateDirectories: true)
            guard ArchiveCodec.compressFile(source: bytesSource, to: tmpDest) else { return false }
            if FileManager.default.fileExists(atPath: dest.path) {
                _ = try FileManager.default.replaceItemAt(dest, withItemAt: tmpDest)
            } else {
                try FileManager.default.moveItem(at: tmpDest, to: dest)
            }
            return true
        } catch {
            NSLog("[vault] archive failed for %@: %@", sourcePath, String(describing: error))
            return false
        }
    }

    /// 把归档解压到一个临时文件，交给闭包使用，用完即删。
    ///
    /// 既有的各 loader 都是 file-based（`loadConversation(fileURL:)`），
    /// 走临时文件就不必为「从内存字节解析」再改一遍所有解析器。
    public static func withRestoredCopy<T>(sourcePath: String,
                                           root: URL = defaultRoot,
                                           _ body: (URL) -> T?) -> T? {
        let src = archiveURL(forSourcePath: sourcePath, root: root)
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mindbus-restored-\(UUID().uuidString).jsonl")
        // 流式解压:720MB 级归档 restore 整读+整解曾同样是 GB 级瞬时
        guard ArchiveCodec.decompressFile(source: src, to: tmp) else {
            try? FileManager.default.removeItem(at: tmp)
            return nil
        }
        defer { try? FileManager.default.removeItem(at: tmp) }
        return body(tmp)
    }

    // MARK: - 归档扫尾

    /// 活跃会话豁免窗口：mtime 在此之内的文件这轮不归档。
    /// 正在被追加写的会话每次扫描都会变化，立刻归档等于反复全量重压同一个文件。
    public static let activeGrace: TimeInterval = 600

    /// 把给定源路径里「该归档而未归档，或归档已经旧于源」的补齐，返回本轮新归档数量。
    ///
    /// 为什么独立于解析流水线：`LoaderRuntime.index` 只处理 mtime 变化的文件，
    /// 一个会话变冷后再不会出现在 stale 列表里。若只在流水线里归档，
    /// ①本功能上线前已入库的存量、②写完就再没动过的会话，两类都永远漏归档。
    /// 扫尾按索引里的全部路径走一遍，稳态下每条最多两次 stat（源 mtime + 归档 mtime），代价可忽略。
    ///
    /// 归档不是「有就够」：会话可能先变冷被归档，数小时后用户 `--resume` 续聊、
    /// 向同一个 jsonl 追加了消息，此后 30 天不再触碰、源文件被工具清理——
    /// 这种源文件比归档新的情况必须重新压一份，否则续聊的尾部消息会随源文件
    /// 一起永久消失，且界面毫无提示（比整条会话丢失更隐蔽）。
    @discardableResult
    public static func sweep(paths: [String], root: URL = defaultRoot, now: Date = Date()) -> Int {
        let fm = FileManager.default
        var count = 0
        for path in paths {
            guard let mtime = (try? fm.attributesOfItem(atPath: path)[.modificationDate]) as? Date
            else { continue }   // 源已消失：要么早归档过，要么已无从挽救，跳过
            guard now.timeIntervalSince(mtime) >= activeGrace else { continue }
            // 已有归档且不比源旧 → 跳过；源被续聊追加过（源 mtime 新于归档 mtime）时
            // 落到下面重新整份压一遍，覆盖式写入天然带来最新全量。
            if let archivedAt = archiveModificationDate(sourcePath: path, root: root),
               archivedAt >= mtime {
                continue
            }
            if archive(sourcePath: path, root: root) { count += 1 }
            // 每个文件后归还 malloc 池(2026-08-15):sweep 跑在扫描收尾的归还点
            // 之后,压缩/过滤的分配会把池重新推高且无人再还;8 文件粒度实测摁不住
            // 单个巨型 rollout(filter 内部的行分配把尾段推回 1870MB)——每文件一次,
            // 归还本身几十 ms、总开销秒级,换池不跨文件积累。
            malloc_zone_pressure_relief(nil, 0)
        }
        return count
    }

    /// 既有归档文件的 mtime；无归档时返回 nil。
    /// 仅供 `sweep` 判断「源是否比归档新」，故设为私有——外部只需要 `hasArchive` 这一问一答。
    private static func archiveModificationDate(sourcePath path: String, root: URL) -> Date? {
        let url = archiveURL(forSourcePath: path, root: root)
        return (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    /// 该路径是否属于「要归档的源」：在三个受支持的源目录之下、且未被数据政策排除。
    /// 排除项（observer 会话等）不该占归档空间；browser 行的 file_path 是相对伪路径，
    /// 前缀判断天然把它挡掉。
    public static func isArchivableSourcePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.hasSuffix(".jsonl") else { return false }
        guard !ClaudeCodeLoader.isExcludedPath(path) else { return false }
        let roots = [ClaudeCodeLoader.defaultProjectsDir.path,
                     ClaudeAgentLoader.defaultRootDir.path,
                     CodexLoader.defaultSessionsDir.path]
        return roots.contains { path.hasPrefix($0 + "/") }
    }
}
