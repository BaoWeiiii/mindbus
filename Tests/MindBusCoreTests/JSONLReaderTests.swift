import XCTest
@testable import MindBusCore

final class JSONLReaderTests: XCTestCase {
    private var path: String!
    override func setUp() { path = NSTemporaryDirectory() + "jsonl-\(UUID().uuidString).jsonl" }
    override func tearDown() { try? FileManager.default.removeItem(atPath: path) }

    private func write(_ s: String) throws {
        try s.write(toFile: path, atomically: true, encoding: .utf8)
    }
    private func lines(_ s: String) throws -> [String] {
        try write(s)
        var out: [String] = []
        try JSONLReader.forEachLine(fileURL: URL(fileURLWithPath: path)) { out.append($0) }
        return out
    }

    func testMultipleLines() throws {
        XCTAssertEqual(try lines("a\nb\nc\n"), ["a", "b", "c"])
    }
    func testNoTrailingNewline() throws {
        XCTAssertEqual(try lines("a\nb"), ["a", "b"])   // 最后一行无 \n 不丢
    }
    func testBlankLineInMiddlePreserved() throws {
        XCTAssertEqual(try lines("a\n\nb\n"), ["a", "", "b"])
    }
    func testEmptyFileNoCallback() throws {
        XCTAssertEqual(try lines(""), [])
    }
    func testLongLineBeyondChunk() throws {
        let big = String(repeating: "x", count: 600_000)   // > 256KB chunk
        XCTAssertEqual(try lines(big + "\n" + "tail"), [big, "tail"])
    }
    func testUTF8MultibyteAcrossChunkBoundary() throws {
        // 用中文把第一行撑到恰好跨过 256KB chunk 边界，验证不乱码
        let head = String(repeating: "好", count: 90_000)   // 90k 中文 ≈ 270KB UTF-8
        let got = try lines(head + "\n第二行")
        XCTAssertEqual(got, [head, "第二行"])
    }
    func testBodyErrorPropagates() throws {
        try write("a\nb\n")
        struct E: Error {}
        XCTAssertThrowsError(
            try JSONLReader.forEachLine(fileURL: URL(fileURLWithPath: path)) { _ in throw E() }
        )
    }

    // MARK: - maxLineBytes（跳过超大行：Codex compaction 巨行 / base64 截图）

    private func lines(_ s: String, maxLineBytes: Int) throws -> [String] {
        try write(s)
        var out: [String] = []
        try JSONLReader.forEachLine(fileURL: URL(fileURLWithPath: path), maxLineBytes: maxLineBytes) { out.append($0) }
        return out
    }

    func testOversizedLineSkippedNeighborsKept() throws {
        let big = String(repeating: "x", count: 2000)
        XCTAssertEqual(try lines("small\n" + big + "\ntail\n", maxLineBytes: 1000), ["small", "tail"])
    }
    func testOversizedLastLineSkipped() throws {
        let big = String(repeating: "x", count: 2000)
        XCTAssertEqual(try lines("a\n" + big, maxLineBytes: 1000), ["a"])
    }
    func testLineAtCapKept() throws {
        let exact = String(repeating: "x", count: 1000)   // == cap，保留（> cap 才丢）
        XCTAssertEqual(try lines(exact + "\ntail\n", maxLineBytes: 1000), [exact, "tail"])
    }
    func testTwoConsecutiveOversizedLinesSkipped() throws {
        let big = String(repeating: "y", count: 2000)
        XCTAssertEqual(try lines("a\n" + big + "\n" + big + "\nb\n", maxLineBytes: 1000), ["a", "b"])
    }
    func testOversizedLineAcrossChunksSkipped() throws {
        // 行跨多个 256KB chunk 且超过 cap → 跳过（验证 cap 在累积期触发，非仅单 chunk 内）
        let huge = String(repeating: "z", count: 600_000)   // > 256KB chunk, > cap
        XCTAssertEqual(try lines("head\n" + huge + "\ntail\n", maxLineBytes: 300_000), ["head", "tail"])
    }
}
