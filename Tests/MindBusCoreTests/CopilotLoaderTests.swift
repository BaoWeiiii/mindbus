import XCTest
@testable import MindBusCore

final class CopilotLoaderTests: XCTestCase {

    // MARK: - messagesFrom(request:)

    func testMessagesFromRequestWithUserAndAssistant() {
        let req: [String: Any] = [
            "requestId": "r1",
            "timestamp": 1_700_000_000_000.0,
            "message": ["text": "你是谁"],
            "response": [["value": "我是 Copilot"]],
        ]
        let msgs = CopilotLoader.messagesFrom(request: req)
        XCTAssertEqual(msgs.count, 2)
        XCTAssertEqual(msgs[0].role, .user)
        XCTAssertEqual(msgs[1].role, .assistant)
        if case .text(let t) = msgs[0].blocks.first { XCTAssertEqual(t, "你是谁") }
        if case .text(let t) = msgs[1].blocks.first { XCTAssertEqual(t, "我是 Copilot") }
    }

    func testMessagesFromRequestSkipsEmptyText() {
        let req: [String: Any] = [
            "requestId": "r2",
            "timestamp": 1_700_000_000_000.0,
            "message": ["text": ""],
            "response": [],
        ]
        XCTAssertTrue(CopilotLoader.messagesFrom(request: req).isEmpty)
    }

    func testMessagesFromRequestUnwrapsContentArray() {
        let req: [String: Any] = [
            "requestId": "r3",
            "timestamp": 1_700_000_000_000.0,
            "message": ["text": "hi"],
            "response": [
                [
                    "value": [
                        "content": [
                            ["value": "line A"],
                            ["value": "line B"],
                        ],
                    ],
                ],
            ],
        ]
        let msgs = CopilotLoader.messagesFrom(request: req)
        XCTAssertEqual(msgs.count, 2)
        if case .text(let t) = msgs[1].blocks.first {
            XCTAssertEqual(t, "line A\nline B")
        } else {
            XCTFail("expected text block")
        }
    }

    // MARK: - reconstructRequests(from:)

    func testReconstructFromKind0Snapshot() {
        let snapshot: [String: Any] = [
            "kind": 0,
            "v": [
                "requests": [
                    [
                        "requestId": "r1",
                        "timestamp": 1_000.0,
                        "message": ["text": "hi"],
                        "response": [["value": "hello"]],
                    ]
                ]
            ],
        ]
        let line = String(data: try! JSONSerialization.data(withJSONObject: snapshot), encoding: .utf8)!
        let result = CopilotLoader.reconstructRequests(from: [line])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0]["requestId"] as? String, "r1")
    }

    func testReconstructAppliesKind2RequestsReplacement() {
        let initial: [String: Any] = ["kind": 0, "v": ["requests": []]]
        let replace: [String: Any] = [
            "kind": 2,
            "k": ["requests"],
            "v": [
                ["requestId": "r1", "timestamp": 1_000.0,
                 "message": ["text": "q1"], "response": [["value": "a1"]]],
                ["requestId": "r2", "timestamp": 2_000.0,
                 "message": ["text": "q2"], "response": [["value": "a2"]]],
            ],
        ]
        let lines = [initial, replace].map {
            String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)!
        }
        let result = CopilotLoader.reconstructRequests(from: lines)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[1]["requestId"] as? String, "r2")
    }

    func testReconstructIgnoresKind1FieldPatches() {
        let initial: [String: Any] = ["kind": 0, "v": ["requests": [["requestId": "r1", "timestamp": 1.0]]]]
        let patch: [String: Any] = ["kind": 1, "k": ["inputState", "inputText"], "v": "typing..."]
        let lines = [initial, patch].map {
            String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)!
        }
        let result = CopilotLoader.reconstructRequests(from: lines)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0]["requestId"] as? String, "r1")
    }

    func testReconstructHandlesMalformedLines() {
        let result = CopilotLoader.reconstructRequests(from: ["", "garbage", "{not json"])
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - loadConversation end-to-end

    func testLoadConversationFromTempFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("copilot-test-\(UUID().uuidString)")
        let workspaceDir = dir.appendingPathComponent("emptyWindowChatSessions")
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionId = "abcd-1234"
        let file = workspaceDir.appendingPathComponent("\(sessionId).jsonl")

        let snapshot: [String: Any] = [
            "kind": 0,
            "v": [
                "sessionId": sessionId,
                "creationDate": 1_700_000_000_000,
                "requests": [
                    ["requestId": "r1", "timestamp": 1_700_000_000_000.0,
                     "message": ["text": "first"], "response": [["value": "answer1"]]],
                    ["requestId": "r2", "timestamp": 1_700_000_001_000.0,
                     "message": ["text": "second"], "response": [["value": "answer2"]]],
                ],
            ],
        ]
        let line = String(data: try JSONSerialization.data(withJSONObject: snapshot), encoding: .utf8)!
        try line.write(to: file, atomically: true, encoding: .utf8)

        let conv = try CopilotLoader.loadConversation(fileURL: file)
        XCTAssertNotNil(conv)
        XCTAssertEqual(conv?.source, .vscodeCopilot)
        XCTAssertEqual(conv?.id, sessionId)
        XCTAssertEqual(conv?.cwd, "global")
        XCTAssertEqual(conv?.messages.count, 4) // 2 user + 2 assistant
        XCTAssertEqual(conv?.startAt, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testLoadConversationReturnsNilForEmptyFile() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-\(UUID().uuidString).jsonl")
        try "".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let conv = try CopilotLoader.loadConversation(fileURL: tmp)
        XCTAssertNil(conv)
    }
}
