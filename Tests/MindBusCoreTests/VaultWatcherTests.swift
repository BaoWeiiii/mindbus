import XCTest
@testable import MindBusCore

final class VaultWatcherTests: XCTestCase {
    /// 端到端：目录内写入文件后，监听器必须收到通知。
    /// 这条挂了意味着新对话不会自动出现在列表里。
    func testWatcherFires() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mb-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let exp = expectation(description: "watcher fired")
        var firedAt: Date?
        let w = VaultWatcher { if firedAt == nil { firedAt = Date(); exp.fulfill() } }
        w.start(paths: [dir.path])
        defer { w.stop() }

        Thread.sleep(forTimeInterval: 0.5)   // 让 stream 就绪
        try "{\"type\":\"user\"}\n".write(to: dir.appendingPathComponent("a.jsonl"),
                                          atomically: true, encoding: .utf8)
        wait(for: [exp], timeout: 10)
    }
}
