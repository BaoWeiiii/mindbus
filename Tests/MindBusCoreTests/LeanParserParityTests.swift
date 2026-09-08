import XCTest
@testable import MindBusCore

/// Lean 解码(JSONDecoder+Codable)与 JSONSerialization 路径的逐 fixture 等价。
/// 唯一豁免:tool_use input 字符串的 key 顺序(lean 按字典序,NSDictionary 枚举序
/// 不可复刻)——对它做语义比较(重新 parse 回对象比对)。
final class LeanParserParityTests: XCTestCase {

    private func legacyMessage(_ line: String) -> Message? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return ClaudeCodeLoader.parseObject(obj)
    }

    private func leanMessage(_ line: String) -> Message? {
        LeanLineParser.decodeCCLine(line).flatMap(LeanLineParser.ccMessage(from:))
    }

    private func assertMessagesEqual(_ line: String, _ note: String,
                                     file: StaticString = #filePath, testLine: UInt = #line) {
        let a = legacyMessage(line)
        let b = leanMessage(line)
        XCTAssertEqual(a == nil, b == nil, "nil 性:\(note)", file: file, line: testLine)
        guard let a, let b else { return }
        XCTAssertEqual(a.id, b.id, "id:\(note)", file: file, line: testLine)
        XCTAssertEqual(a.role, b.role, "role:\(note)", file: file, line: testLine)
        XCTAssertEqual(a.timestamp, b.timestamp, "ts:\(note)", file: file, line: testLine)
        XCTAssertEqual(a.blocks.count, b.blocks.count, "块数:\(note)", file: file, line: testLine)
        for (i, (ba, bb)) in zip(a.blocks, b.blocks).enumerated() {
            if case .toolUse(let na, let ia) = ba, case .toolUse(let nb, let ib) = bb {
                XCTAssertEqual(na, nb, "tool name:\(note)", file: file, line: testLine)
                // input 语义比较(key 序豁免)
                let oa = try? JSONSerialization.jsonObject(with: Data(ia.utf8)) as? NSDictionary
                let ob = try? JSONSerialization.jsonObject(with: Data(ib.utf8)) as? NSDictionary
                XCTAssertEqual(oa, ob, "tool input 语义:\(note)", file: file, line: testLine)
            } else {
                XCTAssertEqual(ba, bb, "块\(i):\(note)", file: file, line: testLine)
            }
        }
    }

    func testTextAndInjectionFiltering() {
        assertMessagesEqual(
            #"{"type":"user","uuid":"u1","timestamp":"2026-01-01T00:00:00Z","message":{"role":"user","content":"普通问题"}}"#,
            "字符串 content")
        assertMessagesEqual(
            #"{"type":"user","uuid":"u2","timestamp":"2026-01-01T00:00:00.500Z","message":{"role":"user","content":[{"type":"text","text":"<command-name>x</command-name>"}]}}"#,
            "注入过滤后整条丢")
        assertMessagesEqual(
            #"{"type":"user","uuid":"u3","timestamp":"2026-01-01T00:00:00Z","message":{"role":"user","content":[{"type":"text","text":"真话<system-reminder>注入</system-reminder>"}]}}"#,
            "system-reminder 剥离")
        assertMessagesEqual(
            #"{"type":"summary","summary":"元数据行"}"#,
            "非消息类型")
    }

    func testToolBlocksAndThinking() {
        assertMessagesEqual(
            #"{"type":"assistant","uuid":"a1","timestamp":"2026-01-01T00:00:01Z","message":{"role":"assistant","content":[{"type":"text","text":"回复"},{"type":"tool_use","name":"Bash","input":{"command":"ls -la","timeout":5000,"nested":{"b":true,"a":null}}},{"type":"thinking","thinking":"想一想"}]}}"#,
            "tool_use+thinking")
        assertMessagesEqual(
            #"{"type":"user","uuid":"u4","timestamp":"2026-01-01T00:00:02Z","message":{"role":"user","content":[{"type":"tool_result","content":"命令输出"},{"type":"text","text":"继续"}]}}"#,
            "user 的 toolResult 滤除")
        assertMessagesEqual(
            #"{"type":"assistant","uuid":"a2","timestamp":"2026-01-01T00:00:03Z","message":{"role":"assistant","content":[{"type":"tool_result","content":[{"type":"text","text":"第一段"},{"type":"text","text":"第二段"}]}]}}"#,
            "tool_result 数组形态")
    }

    func testImageBlocks() {
        assertMessagesEqual(
            #"{"type":"user","uuid":"u5","timestamp":"2026-01-01T00:00:04Z","message":{"role":"user","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"aGVsbG8="}},{"type":"text","text":"看这张图"}]}}"#,
            "base64 图")
        assertMessagesEqual(
            #"{"type":"user","uuid":"u6","timestamp":"2026-01-01T00:00:05Z","message":{"role":"user","content":[{"type":"image","source":{"type":"url","url":"https://x/y.png"}},{"type":"text","text":"链接图"}]}}"#,
            "url 图")
        assertMessagesEqual(
            #"{"type":"user","uuid":"u7","timestamp":"2026-01-01T00:00:06Z","message":{"role":"user","content":[{"type":"image"},{"type":"text","text":"无 source 图"}]}}"#,
            "缺 source 图")
    }

    func testMetadataFields() {
        let l = LeanLineParser.decodeCCLine(
            #"{"type":"user","isSidechain":true,"cwd":"/p/x","gitBranch":"main","sessionId":"s1","uuid":"u8","timestamp":"2026-01-01T00:00:07Z","message":{"role":"user","content":"x"}}"#)
        XCTAssertEqual(l?.isSidechain, true)
        XCTAssertEqual(l?.cwd, "/p/x")
        XCTAssertEqual(l?.gitBranch, "main")
        XCTAssertEqual(l?.sessionId, "s1")
        let t = LeanLineParser.decodeCCLine(#"{"type":"ai-title","aiTitle":"标题来了"}"#)
        XCTAssertEqual(t?.aiTitle, "标题来了")
    }
}
