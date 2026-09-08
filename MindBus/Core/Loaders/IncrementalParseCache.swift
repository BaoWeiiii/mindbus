import Foundation

/// 活跃会话的增量解析缓存。
///
/// 问题：AI 工具正在写的那个会话，每次刷新都要从头重解析。实测本机当前会话
/// 14.3 MB / 1128 条 → 404 ms，而这个数字随对话增长**线性上升**。
/// FSEvents 接上之后刷新变频繁了，这项成本就更显眼。
///
/// 解法：JSONL 是纯追加的，记住上次解析到的字节位置和当时的消息，
/// 下次只解析新增的那几 KB 再拼上去。
///
/// 安全性：只在「文件变大 且 前缀未被改写」时走增量。用 (size, mtime) 之外再记一个
/// 前缀指纹（首 4KB 的 FNV-1a）—— 有些工具会重写整个文件而非追加，那种情况
/// 指纹会变，自动退回全量解析。
///
/// 缓存只在内存、且限量：App 重启后第一次照常全量，不追求跨进程持久化 ——
/// 那需要把消息落盘，得不偿失。
final class IncrementalParseCache: @unchecked Sendable {
    static let shared = IncrementalParseCache()

    struct Entry {
        let offset: UInt64        // 已解析到的字节位置（行边界）
        let fingerprint: UInt64   // 文件头指纹，用于识别「被重写」
        let conv: Conversation    // 含元数据（cwd/id/branch）与已解析的消息
    }

    private var store: [String: Entry] = [:]
    private var order: [String] = []
    // 只留 2 个：一条 1000+ 消息的会话对象连着全文有几十 MB，
    // 而同时被写入的会话通常就一两个（你不会并行在五个项目里聊）。
    private let cap = 2
    private let lock = NSLock()

    /// 取可用于增量的基线。返回 nil 表示必须全量解析。
    func baseline(for path: String, currentSize: UInt64) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        guard let e = store[path] else { return nil }
        // 用 >= 而不是 >：文件一个字节没新增时（currentSize == offset）同样该命中缓存，
        // 增量段为空、直接复用已解析结果。写成 > 会让「无变化」退回全量解析 ——
        // 恰恰把最该省的那次给漏了。小于则说明被截断或重写，增量不再安全。
        guard currentSize >= e.offset else { return nil }
        guard Self.fingerprint(of: path, upTo: e.offset) == e.fingerprint else { return nil }
        return e
    }

    func put(path: String, offset: UInt64, conv: Conversation) {
        lock.lock(); defer { lock.unlock() }
        if store[path] == nil {
            order.append(path)
            while order.count > cap, let oldest = order.first {
                store.removeValue(forKey: oldest)
                order.removeFirst()
            }
        }
        store[path] = Entry(offset: offset,
                            fingerprint: Self.fingerprint(of: path, upTo: offset),
                            conv: conv)
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        store.removeAll(); order.removeAll()
    }

    /// 已解析前缀的 FNV-1a（最多取头 4KB）。只为识别「整体被重写」，不需要密码学强度。
    ///
    /// 上限必须夹在 `offset` 之内：追加写不会改动 [0, offset)，但会改动「文件头 4KB」
    /// 本身的内容 —— 小文件尤其明显（几百字节的文件追加后，前 4KB 完全是另一批字节）。
    /// 拿固定 4KB 做指纹会让所有小文件永远判定为「被重写」，增量彻底失效。
    static func fingerprint(of path: String, upTo offset: UInt64) -> UInt64 {
        guard offset > 0, let h = FileHandle(forReadingAtPath: path) else { return 0 }
        defer { try? h.close() }
        let n = min(4096, Int(offset))
        guard let d = try? h.read(upToCount: n), !d.isEmpty else { return 0 }
        var hash: UInt64 = 0xcbf29ce484222325
        for b in d {
            hash ^= UInt64(b)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    /// 最后一个换行符的位置 +1 —— 即「完整行的结束处」。
    /// 增量必须从行边界续读，否则半行会被当成完整行解析。
    static func lastLineBoundary(of path: String) -> UInt64? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd(), size > 0 else { return nil }
        let window = 64 * 1024
        var pos = size
        while pos > 0 {
            let chunk = UInt64(min(window, Int(pos)))
            pos -= chunk
            guard (try? h.seek(toOffset: pos)) != nil,
                  let d = try? h.read(upToCount: Int(chunk)), !d.isEmpty else { return nil }
            if let idx = d.lastIndex(of: 0x0A) {
                return pos + UInt64(d.distance(from: d.startIndex, to: idx)) + 1
            }
        }
        return nil   // 整个文件没有换行 → 没有完整行
    }
}
