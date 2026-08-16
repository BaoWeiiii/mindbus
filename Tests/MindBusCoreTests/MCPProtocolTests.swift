import XCTest
@testable import MindBusMCP
@testable import MindBusCore

/// MCP stdio 协议层。整个协议表面都在 `handleLine`（一行进一行出），
/// 因此这里能不起进程就把分支覆盖完——可执行文件只剩一个 while 循环。
final class MCPProtocolTests: XCTestCase {

    /// 一台索引永远打不开的服务器：协议层的行为不该依赖有没有库。
    private func serverWithoutIndex(tools: [MCPToolSpec] = []) -> MCPServer {
        MCPServer(openIndex: { .unavailable("no index in test") }, tools: tools)
    }

    private func json(_ line: String?) throws -> [String: Any] {
        let data = try XCTUnwrap(line?.data(using: .utf8))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: 握手

    /// 客户端报什么协议版本就回什么：tools/list 与 tools/call 的报文形状在
    /// 2024-11-05 ~ 2026-07-28 之间没变，回显是安全的，也让新宿主不必降级。
    func testInitializeEchoesClientProtocolVersion() throws {
        let out = serverWithoutIndex().handleLine(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2026-07-28"}}"#)
        let result = try XCTUnwrap(try json(out)["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2026-07-28")
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"])
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["name"] as? String, "mindbus")
        XCTAssertNotNil(result["instructions"], "instructions 是宿主唯一会读到的检索循环说明")
    }

    /// initialize 的 clientInfo.name 要写进 MCPRefLog.agentName——引用日志的
    /// agent 归属唯一来源（spec §2.2「被哪个 Agent 读取过」）。
    func testInitializeCapturesClientNameForRefLog() throws {
        let saved = MCPRefLog.agentName
        addTeardownBlock { MCPRefLog.agentName = saved }
        MCPRefLog.agentName = "unknown"
        _ = serverWithoutIndex().handleLine(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"claude-code","version":"2.0"}}}"#)
        XCTAssertEqual(MCPRefLog.agentName, "claude-code")
    }

    func testInitializeFallsBackWhenClientOmitsVersion() throws {
        let out = serverWithoutIndex().handleLine(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
        let result = try XCTUnwrap(try json(out)["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, MCPServer.fallbackProtocolVersion)
    }

    /// 2026-07-28 起规范转无状态、去掉 initialize 握手。不先握手就发 tools/list
    /// 必须照样работает，否则新宿主一上来就拿不到工具。
    func testToolsListWorksWithoutInitialize() throws {
        let spec = MCPToolSpec(name: "probe", description: "d", inputSchema: ["type": "object"],
                               run: { _, _ in MCPToolOutput("ok") })
        let out = serverWithoutIndex(tools: [spec]).handleLine(
            #"{"jsonrpc":"2.0","id":7,"method":"tools/list","params":{}}"#)
        let body = try json(out)
        XCTAssertEqual(body["id"] as? Int, 7)
        let tools = try XCTUnwrap((body["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.map { $0["name"] as? String }, ["probe"])
        XCTAssertNotNil(tools[0]["inputSchema"])
    }

    /// 通知（无 id）绝不能回应——回了就是往 stdout 写了客户端不认的帧。
    func testNotificationProducesNoResponse() {
        XCTAssertNil(serverWithoutIndex().handleLine(
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
    }

    func testPingReturnsEmptyResult() throws {
        let out = serverWithoutIndex().handleLine(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)
        let result = try XCTUnwrap(try json(out)["result"] as? [String: Any])
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: 错误路径

    func testMalformedJSONReturnsParseError() throws {
        let out = serverWithoutIndex().handleLine("{not json")
        let error = try XCTUnwrap(try json(out)["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32700)
        XCTAssertTrue(try json(out)["id"] is NSNull, "解析不出 id 时 id 必须是 null")
    }

    func testUnknownMethodReturnsMethodNotFound() throws {
        let out = serverWithoutIndex().handleLine(
            #"{"jsonrpc":"2.0","id":3,"method":"resources/list"}"#)
        let error = try XCTUnwrap(try json(out)["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32601)
    }

    func testBlankLineIsIgnored() {
        XCTAssertNil(serverWithoutIndex().handleLine("   "))
    }

    /// 顶层数组是合法 JSON——解析成功了，只是不是一个 Request 对象，该报 -32600
    /// （Invalid Request）而不是 -32700（Parse error）。MCP 已移除 JSON-RPC batching，
    /// 拒绝是对的，但消息要明确说"不支持批量"，宿主才能当场改成逐条发送而不是挂死等超时。
    func testTopLevelArrayIsInvalidRequestNotParseError() throws {
        let out = serverWithoutIndex().handleLine(
            #"[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","id":2,"method":"ping"}]"#)
        let body = try json(out)
        let error = try XCTUnwrap(body["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, JSONRPC.invalidRequest)
        let message = try XCTUnwrap(error["message"] as? String)
        XCTAssertTrue(message.lowercased().contains("batch"),
                      "顶层数组要明确说是批量请求不支持，而不是笼统的格式错误")
        XCTAssertTrue(body["id"] is NSNull)
    }

    /// 裸标量（字符串、数字）同样是"合法 JSON、非 Request 对象"，同一条 -32600 分支。
    func testTopLevelScalarIsInvalidRequestNotParseError() throws {
        for line in [#""hello""#, "42"] {
            let out = serverWithoutIndex().handleLine(line)
            let body = try json(out)
            let error = try XCTUnwrap(body["error"] as? [String: Any], "line=\(line)")
            XCTAssertEqual(error["code"] as? Int, JSONRPC.invalidRequest, "line=\(line)")
        }
    }

    // MARK: id 边界情况

    /// Int.max 本身必须原样回显——它没有越界，不该被误伤进退化路径。
    func testRequestIDHandlesIntMax() throws {
        let out = serverWithoutIndex().handleLine(
            #"{"jsonrpc":"2.0","id":9223372036854775807,"method":"ping"}"#)
        let body = try json(out)
        XCTAssertEqual(body["id"] as? Int, 9223372036854775807)
    }

    /// Int.max + 1：JSON 数字超出 Int64 表示范围，解析成 Double；`Int(Double)` 硬转在这个
    /// 输入上会直接 trap（SIGTRAP）崩掉整个进程。必须退化成字符串 id 而不是崩溃或吞掉请求。
    func testRequestIDDegradesToStringWhenDoubleExceedsIntRange() throws {
        let out = serverWithoutIndex().handleLine(
            #"{"jsonrpc":"2.0","id":9223372036854775808,"method":"ping"}"#)
        let body = try json(out)
        XCTAssertEqual(body["id"] as? String, "9223372036854775808",
                       "越界 id 退化为原样回显的字符串，而不是让进程崩溃或丢响应")
    }

    /// id 键存在但是数组/对象形态（规范只允许 String/Number/Null）：必须回 -32600，
    /// 不能落进「无 id=通知」被静默吞掉——那是 MCP 里最难诊断的失败（宿主只看到超时）。
    func testArrayFormIDIsInvalidRequestNotSilentDrop() throws {
        let out = serverWithoutIndex().handleLine(
            #"{"jsonrpc":"2.0","id":[1,2],"method":"ping"}"#)
        let body = try json(out)
        let error = try XCTUnwrap(body["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32600)
        // 对照：id 键**不存在**才是通知，仍然不回应
        XCTAssertNil(serverWithoutIndex().handleLine(
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
    }

    /// 1e19：同样越界，且是科学计数法字面量——退化字符串不能带 `e+19` 这种宿主大概率
    /// 认不出的形式，必须展开成十进制。
    func testRequestIDHandlesScientificNotationDouble() throws {
        let out = serverWithoutIndex().handleLine(#"{"jsonrpc":"2.0","id":1e19,"method":"ping"}"#)
        let body = try json(out)
        XCTAssertEqual(body["id"] as? String, "10000000000000000000")
    }

    /// (Int64.max, UInt64.max] 的整数 id：JSONSerialization 解析成 NSNumber(unsignedLongLong)，
    /// `as? Int` 与 `as? Double` 都桥接失败（SE-0170 要求精确表示，该区间只有 2048 的倍数
    /// 能被 Double 表示）——曾落进 default 被当通知吞掉、零输出。宿主用随机 u64 当 id 时
    /// **大半取值**都在这个区间，静默无应答比崩溃更难诊断（宿主只看到 timeout）。
    /// Int.max+1 恰好是 2048 的倍数、走的是 Double 退化路，锁不住这条缝，所以这里用
    /// Int.max+2 与一个随机 u64 主体取值。
    func testRequestIDHandlesUnsignedLongLongBeyondDoubleExactRange() throws {
        let out = serverWithoutIndex().handleLine(
            #"{"jsonrpc":"2.0","id":9223372036854775809,"method":"ping"}"#)
        XCTAssertEqual(try json(out)["id"] as? String, "9223372036854775809",
                       "u64 主体取值的 id 被当通知吞掉——宿主只能等超时")

        let random = serverWithoutIndex().handleLine(
            #"{"jsonrpc":"2.0","id":12157665459056928801,"method":"ping"}"#)
        XCTAssertEqual(try json(random)["id"] as? String, "12157665459056928801")
    }

    /// 负数越界同理。
    func testRequestIDHandlesNegativeScientificNotationDouble() throws {
        let out = serverWithoutIndex().handleLine(#"{"jsonrpc":"2.0","id":-1e19,"method":"ping"}"#)
        let body = try json(out)
        XCTAssertEqual(body["id"] as? String, "-10000000000000000000")
    }

    /// 1.5 不能被静默截断成 1——宿主发的是 1.5，回一个 1 它永远匹配不上，只能等超时。
    func testRequestIDPreservesFractionalDouble() throws {
        let out = serverWithoutIndex().handleLine(#"{"jsonrpc":"2.0","id":1.5,"method":"ping"}"#)
        let body = try json(out)
        XCTAssertEqual(body["id"] as? String, "1.5")
    }

    /// `RequestID.string` 分支从未经过 `handleLine` 走过：字符串 id 必须原样回显。
    func testRequestIDStringPassesThroughHandleLine() throws {
        let out = serverWithoutIndex().handleLine(#"{"jsonrpc":"2.0","id":"abc","method":"ping"}"#)
        let body = try json(out)
        XCTAssertEqual(body["id"] as? String, "abc")
    }

    /// 显式 `"id": null` 是请求（要回应，id 原样是 null），跟"没有 id 字段"（通知，不回应）
    /// 曾经被 `RequestID.from` 一起塌缩成 nil。这里锁住二者的对比行为。
    func testExplicitNullIdIsRequestAndRespondsWithNullId() throws {
        let out = serverWithoutIndex().handleLine(#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#)
        let body = try json(out)
        XCTAssertTrue(body["id"] is NSNull, "显式 null id 的请求必须回应，且 id 原样是 null")
        XCTAssertNotNil(body["result"])
    }

    func testMissingIdFieldIsNotificationAndProducesNoResponse() {
        XCTAssertNil(serverWithoutIndex().handleLine(#"{"jsonrpc":"2.0","method":"ping"}"#),
                    "没有 id 字段 = 通知，绝不能回应")
    }

    // MARK: 序列化失败兜底

    /// `inputSchema` 塞进不合法 JSON 值（如 `Double.infinity`）时，`tools/list` 必须回一条
    /// 带正确 id 的 error 帧，而不是让 `JSONSerialization.data(withJSONObject:)` 抛出的
    /// Objective-C 异常直接 abort 掉整个进程——`try?` 挡不住 ObjC 异常，这条兜底路径此前
    /// 是死代码，唯一外部可控入口正是工具的 `inputSchema`。
    func testToolsListReturnsErrorFrameInsteadOfCrashingOnUnserializableSchema() throws {
        let badSpec = MCPToolSpec(name: "broken", description: "d",
                                  inputSchema: ["type": "object", "maximum": Double.infinity],
                                  run: { _, _ in MCPToolOutput("unreachable") })
        let out = serverWithoutIndex(tools: [badSpec]).handleLine(
            #"{"jsonrpc":"2.0","id":42,"method":"tools/list"}"#)
        let body = try json(out)
        XCTAssertEqual(body["id"] as? Int, 42,
                       "序列化失败也不能把 id 丢成 null——宿主要能关联到这次 tools/list")
        let error = try XCTUnwrap(body["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, JSONRPC.internalError)
    }

    /// 工具执行错误必须走 `isError` 的工具结果，不是 JSON-RPC error——
    /// 协议级 error 会让宿主认为服务器坏了，而不是把内容交给模型自己处置。
    func testUnknownToolNameIsToolErrorNotProtocolError() throws {
        let out = serverWithoutIndex().handleLine(
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"nope","arguments":{}}}"#)
        let body = try json(out)
        XCTAssertNil(body["error"])
        let result = try XCTUnwrap(body["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "text")
    }

    /// `tools/call` 缺 `name` 参数时也要走工具错误（不是协议错误），且不该在索引不可用时
    /// 之前就崩——`params["name"] as? String` 那个 guard 此前没有测试直接覆盖过。
    func testToolCallMissingNameParameterIsToolError() throws {
        let out = serverWithoutIndex().handleLine(
            #"{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"arguments":{}}}"#)
        let body = try json(out)
        XCTAssertNil(body["error"])
        let result = try XCTUnwrap(body["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertTrue(text.contains("name"), "错误信息要点名是 name 参数缺失")
    }

    /// 索引打不开时，工具调用要返回"照着做就能修"的提示，而不是空结果或崩溃。
    func testToolCallWithUnavailableIndexReportsActionableMessage() throws {
        let spec = MCPToolSpec(name: "probe", description: "d", inputSchema: ["type": "object"],
                               run: { _, _ in MCPToolOutput("should not run") })
        let out = serverWithoutIndex(tools: [spec]).handleLine(
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"probe","arguments":{}}}"#)
        let result = try XCTUnwrap(try json(out)["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertTrue(text.contains("no index in test"))
        XCTAssertFalse(text.contains("should not run"), "索引不可用时不该执行工具体")
    }

    /// 索引可用时 run 拿到的就是那个索引，且 arguments 原样传入。
    func testToolCallPassesArgumentsAndIndex() throws {
        let path = NSTemporaryDirectory() + "mcp-\(UUID().uuidString).sqlite"
        addTeardownBlock {
            for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) }
        }
        _ = try ConversationIndex(path: path)
        let index = try ConversationIndex.openReadOnly(path: path)

        var seen: [String: Any] = [:]
        let spec = MCPToolSpec(name: "probe", description: "d", inputSchema: ["type": "object"],
                               run: { args, idx in
                                   seen = args
                                   return MCPToolOutput("count=\(idx.summary().count)")
                               })
        let server = MCPServer(openIndex: { .available(index) }, tools: [spec])
        let out = server.handleLine(
            #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"probe","arguments":{"q":"hi","n":3}}}"#)
        let result = try XCTUnwrap(try json(out)["result"] as? [String: Any])
        XCTAssertNil(result["isError"])
        XCTAssertEqual(seen["q"] as? String, "hi")
        XCTAssertEqual(seen["n"] as? Int, 3)
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertEqual(text, "count=0")
    }

    /// 不缓存连接：每次 `tools/call` 都要重新走一遍 `openIndex()`——`mindbus-mcp` 是宿主的
    /// 长驻子进程，缓存住的连接在 App 做数据政策迁移或损坏恢复之后会静默返回过期结果。
    func testToolCallReopensIndexEveryTime() throws {
        let path = NSTemporaryDirectory() + "mcp-\(UUID().uuidString).sqlite"
        addTeardownBlock {
            for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) }
        }
        _ = try ConversationIndex(path: path)
        var openCount = 0
        let spec = MCPToolSpec(name: "probe", description: "d", inputSchema: ["type": "object"],
                               run: { _, _ in MCPToolOutput("ok") })
        let server = MCPServer(openIndex: {
            openCount += 1
            return .available(try! ConversationIndex.openReadOnly(path: path))
        }, tools: [spec])

        for i in 1...3 {
            _ = server.handleLine(
                #"{"jsonrpc":"2.0","id":\#(i),"method":"tools/call","params":{"name":"probe","arguments":{}}}"#)
        }
        XCTAssertEqual(openCount, 3, "三次 tools/call 必须触发三次 open，不能被缓存吞掉")
    }

    /// 索引从不可用变为可用（用户在两次调用之间打开了一次 App、建好了库）：第二次调用
    /// 必须真的用上新连接，而不是钉在第一次失败的状态上——用户不该被要求重启宿主。
    func testToolCallRecoversWhenIndexBecomesAvailable() throws {
        let path = NSTemporaryDirectory() + "mcp-\(UUID().uuidString).sqlite"
        addTeardownBlock {
            for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) }
        }
        var attempt = 0
        let spec = MCPToolSpec(name: "probe", description: "d", inputSchema: ["type": "object"],
                               run: { _, idx in MCPToolOutput("count=\(idx.summary().count)") })
        let server = MCPServer(openIndex: {
            attempt += 1
            if attempt == 1 { return .unavailable("first attempt: no index yet") }
            _ = try? ConversationIndex(path: path)   // 模拟用户此刻打开了一次 App、建好了库
            guard let index = try? ConversationIndex.openReadOnly(path: path) else {
                return .unavailable("unexpected: still unavailable")
            }
            return .available(index)
        }, tools: [spec])

        let first = try json(server.handleLine(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"probe","arguments":{}}}"#))
        XCTAssertEqual((first["result"] as? [String: Any])?["isError"] as? Bool, true)

        let second = try json(server.handleLine(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"probe","arguments":{}}}"#))
        let result = try XCTUnwrap(second["result"] as? [String: Any])
        XCTAssertNil(result["isError"], "第二次必须真的用上新建好的索引，不能还卡在第一次的失败状态")
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertEqual(text, "count=0")
    }

    /// 响应必须是单行——stdio 帧就是换行分隔，正文里漏一个真换行整条连接就错位。
    func testResponseIsSingleLine() throws {
        let spec = MCPToolSpec(name: "probe", description: "d", inputSchema: ["type": "object"],
                               run: { _, _ in MCPToolOutput("line one\nline two") })
        let path = NSTemporaryDirectory() + "mcp-\(UUID().uuidString).sqlite"
        addTeardownBlock {
            for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) }
        }
        _ = try ConversationIndex(path: path)
        let index = try ConversationIndex.openReadOnly(path: path)
        let out = try XCTUnwrap(MCPServer(openIndex: { .available(index) }, tools: [spec]).handleLine(
            #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"probe","arguments":{}}}"#))
        XCTAssertFalse(out.contains("\n"), "响应里出现了真换行")
        let text = try XCTUnwrap((try XCTUnwrap(try json(out)["result"] as? [String: Any])["content"]
                                  as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertEqual(text, "line one\nline two", "换行必须被转义而不是丢弃")
    }

    // MARK: 索引不可用时的提示文案

    func testIndexAccessMessagesAreActionable() {
        let missing = MCPIndexAccess.message(
            for: ConversationIndex.ReadOnlyOpenError.indexMissing(path: "/tmp/x.sqlite"),
            path: "/tmp/x.sqlite")
        XCTAssertTrue(missing.contains("/tmp/x.sqlite"))
        XCTAssertTrue(missing.lowercased().contains("open the mindbus app"))

        let mismatch = MCPIndexAccess.message(
            for: ConversationIndex.ReadOnlyOpenError.policyMismatch(found: 11, expected: 12),
            path: "/tmp/x.sqlite")
        XCTAssertTrue(mismatch.contains("11") && mismatch.contains("12"),
                      "两个版本号都要说出来，否则用户不知道该升哪一头")

        let partial = MCPIndexAccess.message(
            for: ConversationIndex.ReadOnlyOpenError.incompleteSchema(missing: "entities"),
            path: "/tmp/x.sqlite")
        XCTAssertTrue(partial.contains("entities"))

        // 底层错误码不该原样递到模型面前——必须带上"打开一次 App 就能修"这句
        let unopenable = MCPIndexAccess.message(
            for: ConversationIndex.ReadOnlyOpenError.unopenable(detail: "step(14)"),
            path: "/tmp/x.sqlite")
        XCTAssertTrue(unopenable.lowercased().contains("open the mindbus app"))
        XCTAssertTrue(unopenable.contains("step(14)"), "诊断细节要留着，便于排查")
    }

    /// 环境变量能覆盖索引路径——真机烟测与本地调试都靠它，不然只能对着真实索引跑。
    func testIndexPathHonorsEnvironmentOverride() {
        setenv("MINDBUS_INDEX_PATH", "/tmp/override.sqlite", 1)
        addTeardownBlock { unsetenv("MINDBUS_INDEX_PATH") }
        XCTAssertEqual(MCPIndexAccess.defaultIndexPath(), "/tmp/override.sqlite")
    }

    /// `~` 必须展开——这个值多半来自宿主配置文件而非 shell，shell 的波浪号展开不会发生，
    /// 原样传给 FileManager 会被当成字面量目录名，永远命中 .indexMissing。
    func testIndexPathExpandsTilde() {
        setenv("MINDBUS_INDEX_PATH", "~/mindbus-mcp-tilde-test.sqlite", 1)
        addTeardownBlock { unsetenv("MINDBUS_INDEX_PATH") }
        let expanded = MCPIndexAccess.defaultIndexPath()
        XCTAssertFalse(expanded.hasPrefix("~"), "波浪号必须被展开：\(expanded)")
        XCTAssertTrue(expanded.hasSuffix("/mindbus-mcp-tilde-test.sqlite"))
    }

    /// 纯空白 override 等同于未设置——不 trim 会原样喂进提示文案，模型看到
    /// "No MindBus index at  ."（双空格、没路径）。测试进程里的回落路径见下一条测试的注释。
    func testIndexPathBlankOverrideFallsBackToDefault() {
        setenv("MINDBUS_INDEX_PATH", "   ", 1)
        addTeardownBlock { unsetenv("MINDBUS_INDEX_PATH") }
        XCTAssertEqual(MCPIndexAccess.defaultIndexPath(),
                       NSTemporaryDirectory() + "mindbus-test-index.sqlite")
    }

    /// 没有 override 时落到 `ConversationStore.defaultIndexPath(creatingDirectory: false)`。
    /// 测试进程里 `ConversationStore.isRunningTests()` 恒真，函数会在建目录那行之前就
    /// 提前返回临时路径——因此这里断言的是测试隔离下的事实（`NSTemporaryDirectory() +
    /// "mindbus-test-index.sqlite"`），不是真实的 Application Support 路径。
    func testIndexPathFallsBackToConversationStoreDefaultWhenUnset() {
        unsetenv("MINDBUS_INDEX_PATH")
        XCTAssertEqual(MCPIndexAccess.defaultIndexPath(),
                       NSTemporaryDirectory() + "mindbus-test-index.sqlite")
    }
}
