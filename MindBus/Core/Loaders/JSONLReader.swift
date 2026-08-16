import Foundation

/// 流式逐行读 UTF-8 JSONL。FileHandle 分块读 → 按 \n(0x0A) 切 → 完整行回调。
/// 一次只持有「一个 chunk + 当前行缓冲」，不把整文件读进内存（巨型 rollout 文件的内存关键）。
///
/// `maxLineBytes`：单行字节上限（默认 nil = 不限）。超过上限的行被流式跳过——不解码、
/// 不回调、不在缓冲里累积超过上限。用于 Codex：上下文压缩的 `compacted` 行内嵌整会话
/// 累积的 base64 截图，单行可达 155MB。设上限即在读取层斩断。
///
/// 每行 `body` 调用包一层 `autoreleasepool`：loader 在 body 里用 `JSONSerialization.jsonObject`
/// 解析每行，返回的是 **autoreleased** 对象。若不在此 drain，一个文件所有行的 JSON 临时对象
/// 会堆到整个文件解析完才释放（481MB Codex 文件 = 9.5 万行 → 堆积 ~GB）——这才是首次建库
/// 内存峰值真因（实测：retained 文本仅 0.1+3.1MB，峰值却 1.2GB；parseGate 1/2 无差）。
public enum JSONLReader {
    /// - Parameter lineFilter: 字节级预筛，在**构造 String 之前**判断这一行要不要。
    ///   返回 false 的行既不解码也不回调。动机：Codex rollout 里超过九成的行
    ///   （event_msg / token_count / function_call…）解析完必被丢弃，却都要先付一次
    ///   String 构造 —— 大行内嵌 base64，单行可达数 MB。在字节层拦掉最划算。
    /// - Parameter fromOffset: 从该字节位置开始读（默认 0 = 整个文件）。
    ///   用于活跃会话的增量解析：AI 工具是纯追加写的，已解析过的前缀没有必要重读。
    ///   调用方必须保证该偏移落在行边界上（上一次读完最后一个 \n 的位置）。
    public static func forEachLine(
        fileURL: URL,
        maxLineBytes: Int? = nil,
        lineFilter: ((UnsafeRawBufferPointer) -> Bool)? = nil,
        fromOffset: UInt64 = 0,
        _ body: (String) throws -> Void
    ) throws {
        @inline(__always)
        func emit(_ buf: [UInt8]) throws {
            if let f = lineFilter, !buf.withUnsafeBytes({ f($0) }) { return }
            try autoreleasepool { try body(String(decoding: buf, as: UTF8.self)) }
        }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        if fromOffset > 0 { try handle.seek(toOffset: fromOffset) }
        let newline: UInt8 = 0x0A
        let chunkSize = 256 * 1024
        let cap = maxLineBytes ?? Int.max
        var line = [UInt8]()      // 当前未完成行的字节
        var overflow = false      // 当前行已超 cap → 整行丢弃
        var bytesSinceRelief = 0  // 距上次归还 malloc 池的处理量
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            // 取消检查点（每 256KB chunk 一次）：详情解析任务被切走/取消时快速退出，
            // 不再把几十 MB 级文件白解析到底。无 Task 环境（GCD 扫描路径）恒不抛，行为不变。
            try Task.checkCancellation()
            // 巨型文件的池水位周期压平(2026-08-14):行级 JSON 反序列化的释放对象
            // 堆在 malloc 空闲池里不还 OS,720MB 文件能把 footprint 推破 GB——
            // 每 64MB 归还一次(720MB 文件 ~11 次、每次几十 ms),峰值水位≈单窗口
            // 分配量;小文件(<64MB)恒不触发,零成本。
            bytesSinceRelief += chunk.count
            if bytesSinceRelief >= 64 * 1024 * 1024 {
                bytesSinceRelief = 0
                malloc_zone_pressure_relief(nil, 0)
            }
            // 用 memchr 找换行，而不是 `for k in 0..<count where bytes[k] == 0x0A`：
            // 后者是逐字节的 Swift 循环、拿不到 SIMD，还要先把 Data 复制成 [UInt8]。
            // 实测巨型 rollout 文件的扫描吞吐只有约 10 MB/s，瓶颈根本不在磁盘
            // （SSD 顺序读是 GB/s 级），而在这里。
            try chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress else { return }
                let count = raw.count
                var segStart = 0
                while segStart < count {
                    guard let hit = memchr(base + segStart, Int32(newline), count - segStart) else { break }
                    let k = UnsafeRawPointer(hit) - base
                    if !overflow {
                        if line.count + (k - segStart) > cap {
                            // 整行超限 → 丢弃，不解码不回调
                        } else {
                            line.append(contentsOf: UnsafeRawBufferPointer(start: base + segStart, count: k - segStart))
                            try emit(line)
                        }
                    }
                    line.removeAll(keepingCapacity: true)
                    overflow = false
                    segStart = k + 1
                }
                // chunk 尾部（尚无换行）→ 续到当前行，除非本行已注定丢弃
                if !overflow && segStart < count {
                    if line.count + (count - segStart) > cap {
                        overflow = true
                        line.removeAll(keepingCapacity: false)   // 释放，本行注定丢弃
                    } else {
                        line.append(contentsOf: UnsafeRawBufferPointer(start: base + segStart, count: count - segStart))
                    }
                }
            }
        }
        if !overflow && !line.isEmpty {   // 无尾换行的最后一行
            try emit(line)
        }
    }
}
