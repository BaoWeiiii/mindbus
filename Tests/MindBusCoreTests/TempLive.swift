import XCTest
@testable import MindBusCore

final class TempLive: XCTestCase {
    /// 当前活跃会话（Claude Code 正在写的那个）的解析成本
    func testActiveSessionCost() throws {
        guard ProcessInfo.processInfo.environment["MINDBUS_BENCH"] == "1" else { return }
        let dir = ClaudeCodeLoader.defaultProjectsDir
        let urls = ClaudeCodeLoader.enumerateJsonl(in: dir)
        // 最近修改的那个 = 正在进行的会话
        let newest = urls.compactMap { u -> (URL, Date, Int)? in
            guard let a = try? FileManager.default.attributesOfItem(atPath: u.path),
                  let m = a[.modificationDate] as? Date, let s = a[.size] as? Int else { return nil }
            return (u, m, s)
        }.max { $0.1 < $1.1 }
        guard let (url, _, size) = newest else { return }

        var dts: [TimeInterval] = []
        var count = 0
        for _ in 0..<3 {
            let t0 = Date()
            let c = try? ClaudeCodeLoader.loadConversation(fileURL: url)
            dts.append(Date().timeIntervalSince(t0))
            count = c?.messages.count ?? -1
        }
        print(String(format: "BENCH 活跃会话 %.1f MB / %d 条 → 解析 %.0f ms (每次刷新都要重来)",
                     Double(size)/1048576, count, dts.min()! * 1000))
    }
}
