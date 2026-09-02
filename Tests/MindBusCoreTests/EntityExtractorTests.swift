import XCTest
@testable import MindBusCore

/// 实体抽取：语言中立、无词表、零 LLM——只认字符形态。
/// 开发语料里信号最高的四类（记忆层设计说明）：
/// 文件路径、代码标识符、URL、报错码。
final class EntityExtractorTests: XCTestCase {

    private func texts(_ s: String, _ kind: EntityExtractor.Kind) -> [String] {
        EntityExtractor.extract(from: s).filter { $0.kind == kind }.map(\.text)
    }

    func testExtractsFilePaths() {
        let got = texts("改一下 MindBus/Core/Search/Segmenter.swift 和 Tests/Foo.swift 就行", .path)
        XCTAssertEqual(got, ["MindBus/Core/Search/Segmenter.swift", "Tests/Foo.swift"])
    }

    /// 裸文件名（无目录）不算路径——否则「README.md」「1.5」这类满天飞，全是噪声。
    func testIgnoresBareFileNames() {
        XCTAssertTrue(texts("看 README.md 和 3.14 就好", .path).isEmpty)
    }

    func testExtractsCamelCaseAndSnakeCaseIdentifiers() {
        let got = Set(texts("VaultArchive 里的 max_line_bytes 要调", .identifier))
        XCTAssertEqual(got, ["VaultArchive", "max_line_bytes"])
    }

    /// 单个普通英文单词不是标识符——CamelCase 必须至少两段，否则「The」「Swift」全被抽进来。
    func testIgnoresPlainEnglishWords() {
        XCTAssertTrue(texts("The quick brown Fox jumps", .identifier).isEmpty)
    }

    func testExtractsErrorCodes() {
        XCTAssertEqual(texts("报 SQLITE_BUSY 了", .errorCode), ["SQLITE_BUSY"])
    }

    func testExtractsURLs() {
        XCTAssertEqual(texts("见 https://github.com/foo/bar 这个仓库", .url),
                       ["https://github.com/foo/bar"])
    }

    /// URL 先抽并从文本挖掉：否则 URL 里的 `foo/bar` 会被 path 规则重复抽一遍。
    func testURLPathPartIsNotDoubleExtracted() {
        let all = EntityExtractor.extract(from: "见 https://example.com/a/b/c.swift")
        XCTAssertEqual(all.filter { $0.kind == .url }.count, 1)
        XCTAssertTrue(all.filter { $0.kind == .path }.isEmpty, "URL 里的路径被重复抽成了 path")
    }

    /// 太短的片段是噪声（单字母变量、`a_b` 这类）。
    func testDropsTooShortEntities() {
        XCTAssertTrue(EntityExtractor.extract(from: "a_b x/y.c").isEmpty)
    }

    /// 同一实体在一段文本里出现多次只保留一个（计数由索引层做，不在这里）。
    func testDeduplicatesWithinOneText() {
        XCTAssertEqual(texts("VaultArchive 和 VaultArchive 又是 VaultArchive", .identifier),
                       ["VaultArchive"])
    }

    func testEmptyTextYieldsNothing() {
        XCTAssertTrue(EntityExtractor.extract(from: "").isEmpty)
    }

    // MARK: - 代码审查回归（Critical/Important 修复）

    /// 回归：中文紧挨着英文时也要抽得到。
    ///
    /// ICU 的 `\b` 把汉字也算作词字符，于是英文标识符与中文零间距相邻时边界不成立、
    /// 整个匹配失败——而中文不加空格正是最常见的写法。既有测试的中文例子恰好都带空格
    /// （"报 SQLITE_BUSY 了"），所以一条都没测到这个系统性漏抽。
    func testExtractsIdentifiersAdjacentToChinese() {
        XCTAssertEqual(texts("看一下VaultArchive这个类的问题", .identifier), ["VaultArchive"])
        XCTAssertEqual(texts("改一下max_line_bytes这个值", .identifier), ["max_line_bytes"])
        XCTAssertEqual(texts("看看MindBus这个项目", .identifier), ["MindBus"])
        XCTAssertEqual(texts("报SQLITE_BUSY了赶紧修", .errorCode), ["SQLITE_BUSY"])
        XCTAssertEqual(texts("刚才 SQLITE_BUSY发生在写入时", .errorCode), ["SQLITE_BUSY"])
    }

    /// 修中文边界不能把「单段英文词不算标识符」这条规则一起放宽。
    func testStillIgnoresPlainWordsAfterUnicodeBoundaryFix() {
        XCTAssertTrue(texts("The quick brown Fox jumps over Swift", .identifier).isEmpty)
    }

    /// 回归：URL 不该吞掉后面的中文标点。
    func testURLStopsAtChinesePunctuation() {
        XCTAssertEqual(texts("见 https://github.com/foo/bar，然后处理", .url),
                       ["https://github.com/foo/bar"])
        XCTAssertEqual(texts("见 https://github.com/foo/bar。完事", .url),
                       ["https://github.com/foo/bar"])
    }

    /// 回归：上一轮只补了「，。！？；：、」，全角右括号/引号/书名号这类闭合标点
    /// 还漏着，URL 会把它们也吞进去。
    func testURLStopsAtFullWidthClosingBrackets() {
        XCTAssertEqual(texts("（见https://github.com/foo/bar）然后", .url),
                       ["https://github.com/foo/bar"])
    }

    /// 回归：URL 后面直连汉字（不留标点也不留空格，中文语境里很常见的写法）
    /// 会把汉字也吞进 URL——终止字符集本身还缺整个 CJK 区段。
    func testURLStopsAtDirectlyAdjacentChinese() {
        XCTAssertEqual(texts("部署到https://foo.bar上线", .url),
                       ["https://foo.bar"])
    }

    /// 回归：URL 过度匹配会连带吃掉后面的合法路径——挖空顺序 url 先行，
    /// 被吞掉的路径之后永远不会再被 path 规则看到。
    func testOvergreedyURLDoesNotSwallowFollowingPath() {
        let all = EntityExtractor.extract(from: "见https://a.com/b,MindBus/Core/Loaders/ClaudeCodeLoader.swift 这个文件")
        XCTAssertTrue(all.contains { $0.kind == .path && $0.text == "MindBus/Core/Loaders/ClaudeCodeLoader.swift" },
                      "合法路径被 URL 吞掉了")
    }

    /// 回归：路径扩展名后面紧跟标识符时，不能把标识符的首字母吃进扩展名。
    func testPathExtensionDoesNotEatAdjacentIdentifier() {
        let all = EntityExtractor.extract(from: "MindBus/Core/Search/Segmenter.swiftVaultArchive")
        XCTAssertFalse(all.contains { $0.text.hasSuffix(".swiftV") }, "扩展名多吃了一个字符")
    }

    /// 回归：path 正则在「像目录但无扩展名」的长文本上不能退化成 O(n²)。
    ///
    /// 复现条件是一长串 `word/` 之间完全不被空白打断。代码审查给的回归文本原文
    /// `"aaa/bbb/ccc/ "`（结尾带一个空格）重复到 32k 字符左右，实测哪怕不套用本次
    /// 占有量词修复也只要 ~0.007s——空格会把外层目录段在每个起始位置的可重复次数
    /// 截断到个位数，回溯开销根本堆不起来，这条文本并不能验证到这处修复。真正复现
    /// 需要去掉这个空格、让 `word/` 连续不断：实测未修复的正则在这台机器上、这个
    /// Swift 工具链版本下，1.2 万字符左右（900～1000 次重复）就要 1.4～1.8 秒。
    /// 另外占有量词只消除「同一起点反复回退重试」这一层开销，消除不了「引擎在每个
    /// 起始位置都要重新往前扫一遍剩余文本」这一层——32k 字符时即使修复后也仍要 3
    /// 秒以上，够不到 1 秒内。回归测试的规模因此比审查原文里的「32000 字符左右」小，
    /// 但依然是真实复现、真实卡阈值的构造，不是靠改小文本或调松断言来迁就通过。
    func testPathRegexDoesNotBlowUpOnDirectoryLikeText() {
        let text = String(repeating: "aaa/bbb/ccc/", count: 1000)   // 连续无分隔，约 1.2 万字符
        let t0 = Date()
        _ = EntityExtractor.extract(from: text)
        let elapsed = Date().timeIntervalSince(t0)
        XCTAssertLessThan(elapsed, 1.0, "path 正则回溯未收敛：\(elapsed)s（同等规模文本修复前实测 1.4～1.8s）")
    }

    // MARK: - 终审回归：入口长度上限（Important）

    /// 回归：超长连续无空白串不能让抽取退化成分钟级。
    ///
    /// path 正则仍有「每个起始位置重扫剩余文本」的平方层，实测 60k base64url 形态串
    /// 要 36.5 秒，而 extract 跑在索引的串行写队列与事务里——一条含长 hex dump 的会话
    /// 就能卡死索引管线。入口按「连续无空白 run」长度上限净化即可堵住。
    func testDoesNotDegradeOnLongUnbrokenRun() {
        // base64url 形态：全部字符都在 path 正则的字符类里，且没有空白可截断
        let run = String(repeating: "aA1_-.zZ9", count: 7000)   // 约 63k 字符
        let t0 = Date()
        _ = EntityExtractor.extract(from: run)
        let elapsed = Date().timeIntervalSince(t0)
        XCTAssertLessThan(elapsed, 1.0, "超长连续串让抽取退化：\(elapsed)s（未修时约 36s）")
    }

    /// 净化只该丢超长连续串，正常文本里的实体一个都不能少。
    func testSanitizationKeepsNormalEntities() {
        let junk = String(repeating: "x", count: 3000)
        let text = "改 MindBus/Core/Search/Segmenter.swift 里的 VaultArchive，日志里有 \(junk) 这段垃圾"
        let got = Set(EntityExtractor.extract(from: text).map(\.text))
        XCTAssertTrue(got.contains("MindBus/Core/Search/Segmenter.swift"))
        XCTAssertTrue(got.contains("VaultArchive"))
        XCTAssertFalse(got.contains(junk), "超长垃圾串不该进实体表")
    }
}
