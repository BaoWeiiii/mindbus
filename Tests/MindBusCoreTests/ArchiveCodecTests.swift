import XCTest
@testable import MindBusCore

final class ArchiveCodecTests: XCTestCase {
    /// 归档的唯一硬要求：压回来必须逐字节等于原文（保真是整个 vault 的前提）。
    func testRoundTripPreservesBytesExactly() throws {
        let original = Data((0..<50_000).map { _ in UInt8.random(in: 0...255) })
        let packed = try XCTUnwrap(ArchiveCodec.compress(original))
        let restored = try XCTUnwrap(ArchiveCodec.decompress(packed))
        XCTAssertEqual(restored, original)
    }

    /// jsonl 是高度重复的结构化文本，压缩比必须显著——否则不值得多存一份。
    /// 实测本机真实会话 6.41×；这里用合成 jsonl 断言一个保守下界。
    func testCompressesRepetitiveJSONLSubstantially() throws {
        let line = #"{"type":"user","uuid":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","message":{"role":"user","content":"hello"}}"#
        let jsonl = Data(Array(repeating: line, count: 2_000).joined(separator: "\n").utf8)
        let packed = try XCTUnwrap(ArchiveCodec.compress(jsonl))
        XCTAssertLessThan(Double(packed.count) / Double(jsonl.count), 0.25,
                          "压缩比不足 4×，归档不划算")
    }

    /// 空文件与非 LZMA 垃圾都不能崩，只能返回 nil。
    func testDecompressRejectsGarbage() {
        XCTAssertNil(ArchiveCodec.decompress(Data([0x00, 0x01, 0x02, 0x03])))
    }
}

// MARK: - 流式文件级编解码(2026-08-15)

extension ArchiveCodecTests {
    private func tempFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codec-\(UUID().uuidString).bin")
        try data.write(to: url)
        return url
    }

    /// 新流式压缩的产物必须能被旧 NSData 路径解开(存量归档的反向:旧压新解)。
    /// 算法同为 COMPRESSION_LZMA,字节级兼容是归档不迁移的前提。
    func testStreamCompressInteropWithLegacyDecompress() throws {
        let original = Data(String(repeating: "MindBus 流式归档兼容性样本。", count: 5000).utf8)
        let src = try tempFile(original)
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("codec-out-\(UUID().uuidString).lzma")
        defer { try? FileManager.default.removeItem(at: src)
                try? FileManager.default.removeItem(at: dst) }

        XCTAssertTrue(ArchiveCodec.compressFile(source: src, to: dst))
        let packed = try Data(contentsOf: dst)
        XCTAssertEqual(ArchiveCodec.decompress(packed), original, "流式压 → 旧解")
    }

    func testLegacyCompressInteropWithStreamDecompress() throws {
        let original = Data(String(repeating: "存量归档必须继续可读。", count: 5000).utf8)
        let packed = try XCTUnwrap(ArchiveCodec.compress(original))
        let src = try tempFile(packed)
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("codec-restore-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: src)
                try? FileManager.default.removeItem(at: dst) }

        XCTAssertTrue(ArchiveCodec.decompressFile(source: src, to: dst))
        XCTAssertEqual(try Data(contentsOf: dst), original, "旧压 → 流式解")
    }

    func testStreamRoundTripMultiChunk() throws {
        // 跨多个 256KB chunk 的往返(1.5MB 随机性文本)
        var text = ""
        for i in 0..<30_000 { text += "行 \(i) 内容 \(i * 7919 % 100_000)\n" }
        let original = Data(text.utf8)
        let src = try tempFile(original)
        let mid = FileManager.default.temporaryDirectory
            .appendingPathComponent("codec-mid-\(UUID().uuidString).lzma")
        let back = FileManager.default.temporaryDirectory
            .appendingPathComponent("codec-back-\(UUID().uuidString).bin")
        defer { for u in [src, mid, back] { try? FileManager.default.removeItem(at: u) } }

        XCTAssertTrue(ArchiveCodec.compressFile(source: src, to: mid))
        XCTAssertTrue(ArchiveCodec.decompressFile(source: mid, to: back))
        XCTAssertEqual(try Data(contentsOf: back), original)
    }

    func testStreamCompressRejectsEmptyFile() throws {
        let src = try tempFile(Data())
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("codec-empty-\(UUID().uuidString).lzma")
        defer { try? FileManager.default.removeItem(at: src)
                try? FileManager.default.removeItem(at: dst) }
        XCTAssertFalse(ArchiveCodec.compressFile(source: src, to: dst), "空源无归档价值,口径同 compress")
    }
}
