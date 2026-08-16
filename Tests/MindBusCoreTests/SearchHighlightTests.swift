import XCTest
@testable import MindBusCore

final class SearchHighlightTests: XCTestCase {

    // MARK: - ranges（高亮标注的字面区间）

    func testRangesCaseInsensitiveLiteral() {
        let text = "SwiftUI 与 swiftui 还有 SWIFTUI"
        let rs = SearchHighlight.ranges(of: "swiftui", in: text)
        XCTAssertEqual(rs.count, 3)
        XCTAssertEqual(String(text[rs[0]]), "SwiftUI")
        XCTAssertEqual(String(text[rs[1]]), "swiftui")
        XCTAssertEqual(String(text[rs[2]]), "SWIFTUI")
    }

    func testRangesChineseAdjacentNonOverlapping() {
        // 相邻命中不重叠、从前到后
        let text = "重构重构方案里再谈重构"
        let rs = SearchHighlight.ranges(of: "重构", in: text)
        XCTAssertEqual(rs.count, 3)
        XCTAssertTrue(rs[0].upperBound <= rs[1].lowerBound)
        XCTAssertTrue(rs[1].upperBound <= rs[2].lowerBound)
    }

    func testRangesEmptyQueryOrTextOrNoHit() {
        XCTAssertTrue(SearchHighlight.ranges(of: "", in: "abc").isEmpty)
        XCTAssertTrue(SearchHighlight.ranges(of: "   ", in: "abc").isEmpty)   // 纯空白词
        XCTAssertTrue(SearchHighlight.ranges(of: "xyz", in: "abc").isEmpty)
        XCTAssertTrue(SearchHighlight.ranges(of: "a", in: "").isEmpty)
    }

    func testRangesTrimsQueryWhitespace() {
        // searchQuery 原词可能带首尾空格，标注按 trim 后的词
        let rs = SearchHighlight.ranges(of: " redis ", in: "迁移 Redis 集群")
        XCTAssertEqual(rs.count, 1)
    }

    // MARK: - messageMatches（消息级定位）

    private func msg(_ blocks: [ContentBlock]) -> Message {
        Message(id: "m", role: .assistant, timestamp: Date(), blocks: blocks)
    }

    func testMessageMatchesScansAllTextualBlocks() {
        let m = msg([
            .text("正文无关"),
            .code(language: "swift", text: "let leakCheck = self"),
            .thinking("这里讨论内存泄漏"),
        ])
        XCTAssertTrue(SearchHighlight.messageMatches(m, query: "内存泄漏"))   // thinking 命中
        XCTAssertTrue(SearchHighlight.messageMatches(m, query: "LEAKCHECK")) // code 命中，大小写不敏感
        XCTAssertFalse(SearchHighlight.messageMatches(m, query: "不存在的词"))
        XCTAssertFalse(SearchHighlight.messageMatches(m, query: ""))
        XCTAssertFalse(SearchHighlight.messageMatches(m, query: "  "))
    }

    func testMessageMatchesIgnoresImageBlocks() {
        // image 的 plainText 是 "[image: png]" 元信息，不构成语义命中
        let m = msg([.image(mediaType: "image/png", source: .unknown)])
        XCTAssertFalse(SearchHighlight.messageMatches(m, query: "image"))
        XCTAssertFalse(SearchHighlight.messageMatches(m, query: "png"))
    }

    // MARK: - store.highlightQuery 与召回同拍

    @MainActor
    func testHighlightQuerySyncsWithRunSearch() async {
        let path = NSTemporaryDirectory() + "hl-\(UUID().uuidString).sqlite"
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } }
        let store = ConversationStore(indexPath: path)

        XCTAssertEqual(store.highlightQuery, "")
        store.searchQuery = "  Redis 迁移  "
        await store.runSearch()
        XCTAssertEqual(store.highlightQuery, "Redis 迁移")   // trim 后与召回口径一致

        store.searchQuery = ""
        await store.runSearch()
        XCTAssertEqual(store.highlightQuery, "")             // 清词 → 高亮/定位失效
    }
}
