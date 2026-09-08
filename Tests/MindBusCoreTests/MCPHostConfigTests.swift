import XCTest
@testable import MindBusCore

/// 一键接入：往宿主配置里加 / 删 mindbus，其余内容一字不动。
final class MCPHostConfigTests: XCTestCase {

    private let path = "/Applications/MindBus.app/Contents/MacOS/mindbus-mcp"

    // MARK: Claude Code

    func testClaudeCodeAddFromNothing() throws {
        let data = try MCPHostConfig.claudeCodeAdd(json: nil, serverPath: path)
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let servers = try XCTUnwrap(dict["mcpServers"] as? [String: Any])
        let entry = try XCTUnwrap(servers["mindbus"] as? [String: Any])
        XCTAssertEqual(entry["type"] as? String, "stdio")
        XCTAssertEqual(entry["command"] as? String, path)
        XCTAssertEqual((entry["args"] as? [String])?.count, 0)
        XCTAssertTrue(MCPHostConfig.claudeCodeHas(json: data))
    }

    func testClaudeCodeAddPreservesOtherKeysAndServers() throws {
        let original = """
        {"numStartups": 42, "theme": "dark", "mcpServers": {"reddit": {"type": "stdio", "command": "npx", "args": ["-y", "x"]}}}
        """
        let data = try MCPHostConfig.claudeCodeAdd(json: Data(original.utf8), serverPath: path)
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(dict["numStartups"] as? Int, 42)
        XCTAssertEqual(dict["theme"] as? String, "dark")
        let servers = try XCTUnwrap(dict["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["reddit"], "别人的 server 原样保留")
        XCTAssertNotNil(servers["mindbus"])
    }

    func testClaudeCodeRemoveLeavesOthers() throws {
        let added = try MCPHostConfig.claudeCodeAdd(
            json: Data(#"{"mcpServers": {"reddit": {"type": "stdio", "command": "npx"}}}"#.utf8), serverPath: path)
        let removed = try MCPHostConfig.claudeCodeRemove(json: added)
        XCTAssertFalse(MCPHostConfig.claudeCodeHas(json: removed))
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: removed) as? [String: Any])
        XCTAssertNotNil((dict["mcpServers"] as? [String: Any])?["reddit"])
    }

    func testClaudeCodeInvalidJSONIsNotClobbered() {
        XCTAssertThrowsError(try MCPHostConfig.claudeCodeAdd(json: Data("not json".utf8), serverPath: path))
        XCTAssertFalse(MCPHostConfig.claudeCodeHas(json: Data("not json".utf8)))
    }

    // MARK: Codex

    func testCodexAddAppendsSectionAndPreservesFile() {
        let original = """
        model = "gpt-5"

        [mcp_servers.context7]
        command = "npx"
        args = ["-y", "@upstash/context7-mcp"]
        """
        let out = MCPHostConfig.codexAdd(toml: original, serverPath: path)
        XCTAssertTrue(out.hasPrefix("model = \"gpt-5\""))
        XCTAssertTrue(out.contains("[mcp_servers.context7]"))
        XCTAssertTrue(out.hasSuffix("[mcp_servers.mindbus]\ncommand = \"\(path)\"\n"))
        XCTAssertTrue(MCPHostConfig.codexHas(toml: out))
        XCTAssertFalse(MCPHostConfig.codexHas(toml: original))
    }

    func testCodexAddIsIdempotent() {
        let once = MCPHostConfig.codexAdd(toml: "", serverPath: path)
        let twice = MCPHostConfig.codexAdd(toml: once, serverPath: path)
        XCTAssertEqual(once, twice)
        XCTAssertEqual(twice.components(separatedBy: "[mcp_servers.mindbus]").count, 2, "只有一份")
    }

    func testCodexRemoveOnlyOurSection() {
        let toml = """
        [mcp_servers.mindbus]
        command = "/old/path"
        startup_timeout_sec = 20.0

        [mcp_servers.playwright]
        command = "npx"
        """
        let out = MCPHostConfig.codexRemove(toml: toml)
        XCTAssertFalse(out.contains("mindbus"))
        XCTAssertFalse(out.contains("/old/path"))
        XCTAssertTrue(out.contains("[mcp_servers.playwright]\ncommand = \"npx\""))
        XCTAssertEqual(MCPHostConfig.codexRemove(toml: "a = 1\n"), "a = 1\n", "没有段时原样返回")
    }

    func testCodexPathEscaping() {
        let out = MCPHostConfig.codexAdd(toml: "", serverPath: "/Users/x/My \"Apps\"/mindbus-mcp")
        XCTAssertTrue(out.contains(#"command = "/Users/x/My \"Apps\"/mindbus-mcp""#))
    }
}
