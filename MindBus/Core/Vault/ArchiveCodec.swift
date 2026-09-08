import Foundation
import Compression

/// 归档编解码：LZMA。
///
/// 选型（2026-08-09 本机实测，24.6MiB 真实 Claude Code 会话）：
/// LZMA **6.41×** / zlib 4.33×；命令行 zstd -19 是 5.65×。
/// 即 Foundation 自带的 LZMA 比引一个 zstd 依赖压得更小 —— App 是零外部依赖包，
/// 为压缩引 C 库不划算。压 25MiB 约 2.3s，而归档是每个文件一次性的动作，可接受。
/// 注：6.41× 取自文本型样本；图片密集的会话约 3.3×（实测 72.1MiB 会话 → 21.9MiB，8.12s），
/// 全库聚合预期约 3.4×。
public enum ArchiveCodec {

    public static func compress(_ data: Data) -> Data? {
        // 空数据 compressed() 会抛错；空源文件也没有归档价值，直接判无效
        guard !data.isEmpty else { return nil }
        return try? (data as NSData).compressed(using: .lzma) as Data
    }

    public static func decompress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        return try? (data as NSData).decompressed(using: .lzma) as Data
    }

    // MARK: - 流式文件级编解码(2026-08-15 首建峰值真凶手术)

    /// 文件→文件流式压缩,峰值 O(chunk)。`NSData.compressed` 要整文件+压缩产物
    /// 同时在内存——归档 sweep 对 38MB 级一批 Claude 文件逐个整读,与解析并发叠加,
    /// 就是八轮删库实测「解析侧怎么优化峰值都恒 1.9GB」的真身(峰值根本不在解析)。
    /// 算法仍 COMPRESSION_LZMA:与 `NSData.compressed(using: .lzma)` 字节兼容,
    /// 存量归档照常可解(ArchiveCodecTests 锁死互解)。
    public static func compressFile(source: URL, to dest: URL) -> Bool {
        streamFile(operation: COMPRESSION_STREAM_ENCODE, source: source, to: dest)
    }

    public static func decompressFile(source: URL, to dest: URL) -> Bool {
        streamFile(operation: COMPRESSION_STREAM_DECODE, source: source, to: dest)
    }

    private static func streamFile(operation: compression_stream_operation,
                                   source: URL, to dest: URL) -> Bool {
        guard let srcSize = (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int),
              srcSize > 0 else { return false }   // 空源无归档价值(口径同 compress)
        guard let inFH = try? FileHandle(forReadingFrom: source) else { return false }
        defer { try? inFH.close() }
        inFH.markStreamingRead()
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        guard let outFH = try? FileHandle(forWritingTo: dest) else { return false }
        defer { try? outFH.close() }

        let streamPtr = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPtr.deallocate() }
        guard compression_stream_init(streamPtr, operation, COMPRESSION_LZMA)
            == COMPRESSION_STATUS_OK else { return false }
        defer { compression_stream_destroy(streamPtr) }

        let bufSize = 256 * 1024
        let dstBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { dstBuf.deallocate() }

        var status = COMPRESSION_STATUS_OK
        var eof = false
        while status == COMPRESSION_STATUS_OK {
            let chunk = eof ? Data() : ((try? inFH.read(upToCount: bufSize)) ?? Data())
            if chunk.isEmpty { eof = true }
            let flags = eof ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            var writeFailed = false
            if chunk.isEmpty {
                // eof 收尾:无输入,持续 drain 直到 END
                streamPtr.pointee.src_size = 0
                repeat {
                    streamPtr.pointee.dst_ptr = dstBuf
                    streamPtr.pointee.dst_size = bufSize
                    status = compression_stream_process(streamPtr, flags)
                    let produced = bufSize - streamPtr.pointee.dst_size
                    if produced > 0 {
                        do { try outFH.write(contentsOf: Data(bytes: dstBuf, count: produced)) }
                        catch { writeFailed = true; break }
                    }
                } while status == COMPRESSION_STATUS_OK
            } else {
                chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    streamPtr.pointee.src_ptr = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    streamPtr.pointee.src_size = chunk.count
                    repeat {
                        streamPtr.pointee.dst_ptr = dstBuf
                        streamPtr.pointee.dst_size = bufSize
                        status = compression_stream_process(streamPtr, flags)
                        let produced = bufSize - streamPtr.pointee.dst_size
                        if produced > 0 {
                            do { try outFH.write(contentsOf: Data(bytes: dstBuf, count: produced)) }
                            catch { writeFailed = true; break }
                        }
                    } while status == COMPRESSION_STATUS_OK && streamPtr.pointee.src_size > 0
                }
            }
            if writeFailed { return false }
        }
        return status == COMPRESSION_STATUS_END
    }
}
