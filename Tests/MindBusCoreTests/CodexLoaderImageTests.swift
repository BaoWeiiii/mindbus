import XCTest
@testable import MindBusCore

final class CodexLoaderImageTests: XCTestCase {
    /// 造一条 Codex response_item/message/user 行，可带文字 + input_image。
    private func userLine(text: String, imageURL: String?) -> String {
        var content: [[String: Any]] = [["type": "input_text", "text": text]]
        if let u = imageURL {
            content.append(["type": "input_image", "image_url": u, "detail": "high"])
        }
        let obj: [String: Any] = [
            "type": "response_item",
            "timestamp": "2026-04-28T01:00:00.000Z",
            "payload": ["type": "message", "role": "user", "content": content],
        ]
        return String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }

    private func imageBlocks(_ msg: Message?) -> [ContentBlock] {
        (msg?.blocks ?? []).filter { if case .image = $0 { return true } else { return false } }
    }

    func testUserAttachedImageKept() {
        let line = userLine(text: "# Files mentioned by the user:\n## a.png: /tmp/a.png",
                            imageURL: "data:image/png;base64,iVBORw0KGgo=")
        let msg = CodexLoader.parseLine(line)
        XCTAssertEqual(imageBlocks(msg).count, 1)
        if case .image(let mt, let src) = imageBlocks(msg).first {
            XCTAssertEqual(mt, "image/png")
            if case .base64(let b) = src { XCTAssertEqual(b, "iVBORw0KGgo=") } else { XCTFail("not base64") }
        } else { XCTFail("no image block") }
    }

    func testBrowserUseScreenshotDropped() {
        let line = userLine(text: "# In app browser:\n## My request for Codex: 改这里",
                            imageURL: "data:image/png;base64,iVBORw0KGgo=")
        let msg = CodexLoader.parseLine(line)
        XCTAssertEqual(imageBlocks(msg).count, 0)         // 截图丢
        XCTAssertNotNil(msg)                              // 但文字消息保留
    }

    func testNonDataURIImageIgnored() {
        let line = userLine(text: "# Files mentioned by the user:\n## a.png",
                            imageURL: "https://example.com/a.png")
        XCTAssertEqual(imageBlocks(CodexLoader.parseLine(line)).count, 0)
    }
}
