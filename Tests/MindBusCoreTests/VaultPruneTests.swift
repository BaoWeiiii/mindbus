import XCTest
@testable import MindBusCore

final class VaultPruneTests: XCTestCase {

    private func makeIndex() throws -> ConversationIndex {
        let path = NSTemporaryDirectory() + "vp-\(UUID().uuidString).sqlite"
        addTeardownBlock {
            for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) }
        }
        return try ConversationIndex(path: path)
    }

    private func lite(_ id: String, _ url: URL) -> ConversationLite {
        ConversationLite(id: id, source: .claudeCode, startAt: Date(), endAt: Date(),
                         cwd: "/tmp", gitBranch: nil, preview: "p", messageCount: 1, fileURL: url)
    }

    /// 本计划的核心行为：源文件被工具删了，但我们有副本 —— 索引行必须留下。
    /// 在此之前 pruneMissing 会把它删掉，于是「工具删除」直接传染成「MindBus 也没了」。
    func testKeepsRowWhenSourceGoneButArchived() throws {
        let index = try makeIndex()
        let gone = URL(fileURLWithPath: NSTemporaryDirectory() + "vp-gone-\(UUID().uuidString).jsonl")
        try index.upsert([(lite("archived", gone), [Segmenter.Segment(firstMessageIndex: 0, lastMessageIndex: 0, text: "t")], 1, "t")])

        LoaderRuntime.pruneMissing(from: index,
                                   isExcluded: { _ in false },
                                   hasArchive: { $0 == gone.path })

        XCTAssertEqual(index.summary().count, 1, "有副本却被删了——vault 白存")
    }

    /// 没有副本的失踪行仍然要删（否则列表里留下点开就报错的幽灵条目）。
    func testStillPrunesRowWhenNoArchive() throws {
        let index = try makeIndex()
        let gone = URL(fileURLWithPath: NSTemporaryDirectory() + "vp-nogone-\(UUID().uuidString).jsonl")
        try index.upsert([(lite("orphan", gone), [Segmenter.Segment(firstMessageIndex: 0, lastMessageIndex: 0, text: "t")], 1, "t")])

        LoaderRuntime.pruneMissing(from: index,
                                   isExcluded: { _ in false },
                                   hasArchive: { _ in false })

        XCTAssertEqual(index.summary().count, 0)
    }

    /// 被数据政策排除的行照删不误——即使它（因历史原因）有归档。
    /// 政策排除是「这内容不该在库里」，与「源文件还在不在」是两件事。
    func testPrunesExcludedEvenIfArchived() throws {
        let index = try makeIndex()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vp-ex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let present = dir.appendingPathComponent("observer.jsonl")
        try Data("{}\n".utf8).write(to: present)
        try index.upsert([(lite("excluded", present), [Segmenter.Segment(firstMessageIndex: 0, lastMessageIndex: 0, text: "t")], 1, "t")])

        LoaderRuntime.pruneMissing(from: index,
                                   isExcluded: { $0 == present.path },
                                   hasArchive: { _ in true })

        XCTAssertEqual(index.summary().count, 0)
    }
}
