import XCTest
@testable import MindBusCore

/// 词汇的传染方向：哪些词是**它先说、你后来接过来**的。
///
/// 这是只有跨工具对话库才做得到的观察——单个 AI 工具看不到你在别的项目、
/// 别的工具里的用词演变。真机实例：「用户旅程」是 17 天前它先说的，
/// 你后来带着它走了 4 个项目。
final class VocabularyContagionTests: XCTestCase {

    private func conv(_ cwd: String, _ items: [(MessageRole, String, Int)]) -> (messages: [Message], cwd: String) {
        (items.enumerated().map { i, it in
            Message(id: "\(cwd)-\(i)", role: it.0,
                    timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(it.2) * 86400),
                    blocks: [.text(it.1)])
        }, cwd)
    }

    /// 背景对话不能省:库大到能算覆盖率时,「出现在几成对话里」这道闸才生效,
    /// 而三场对话里任何词都是 33% 起步。真实的库不长那样。
    private func background(_ n: Int) -> [(messages: [Message], cwd: String)] {
        (0..<n).map { i in conv("/bg/\(i % 7)", [(.user, "把仓库里的日志归档一下", 5)]) }
    }

    func testDetectsWordsYouPickedUp() {
        var convs = [
            conv("/w/a", [(.assistant, "我们从视觉语言这一层看", 0)]),
            conv("/w/b", [(.user, "按视觉语言重新梳理一遍", 40)]),
            conv("/w/c", [(.user, "视觉语言要统一", 60)]),
        ]
        convs += background(40)
        let out = MindsBuilder.vocabularyContagion(conversations: convs,
                                                   lexicon: ["视觉语言"], limit: 5)
        XCTAssertEqual(out.map(\.word), ["视觉语言"])
        XCTAssertEqual(out.first?.gapDays, 40)
        XCTAssertEqual(out.first?.projects, 2, "你要真的带着它走过多个项目")
    }

    /// 你先说的不算——那本来就是你的词
    func testYourOwnWordIsNotContagion() {
        let convs = [
            conv("/w/a", [(.user, "第一性原理来看", 0)]),
            conv("/w/b", [(.assistant, "从第一性原理出发", 10)]),
            conv("/w/c", [(.user, "还是第一性原理", 20)]),
        ]
        XCTAssertTrue(MindsBuilder.vocabularyContagion(conversations: convs,
                                                       lexicon: ["第一性原理"], limit: 5).isEmpty)
    }

    /// 同一天不算：那多半只是你在同一场对话里顺着它的话复述
    func testSameDayIsNotContagion() {
        let convs = [
            conv("/w/a", [(.assistant, "叫它冷启动", 0), (.user, "冷启动怎么做", 0)]),
            conv("/w/b", [(.user, "冷启动方案", 5)]),
        ]
        XCTAssertTrue(MindsBuilder.vocabularyContagion(conversations: convs,
                                                       lexicon: ["冷启动"], limit: 5).isEmpty)
    }

    /// 只在一个项目里用过不算接过来——可能只是当场跟着说了一句
    func testSingleProjectIsNotEnough() {
        let convs = [
            conv("/w/a", [(.assistant, "这叫供给质量", 0)]),
            conv("/w/a", [(.user, "供给质量怎么算", 30)]),
        ]
        XCTAssertTrue(MindsBuilder.vocabularyContagion(conversations: convs,
                                                       lexicon: ["供给质量"], limit: 5).isEmpty)
    }
}

// MARK: - 展开成两句原话 + 英文盲区

extension VocabularyContagionTests {

    /// 词是压缩的，句子才完整：「视觉语言 33d/4projects」看不出发生了什么，
    /// 「它当时说…你后来说…」才是这次传染的故事。零新判据——
    /// 首次出现本来就在算，顺手把那两句留下来。
    func testCarriesFirstSentences() {
        var convs = [
            conv("/w/a", [(.assistant, "配色要成体系，我们从视觉语言这一层看", 0)]),
            conv("/w/b", [(.user, "按视觉语言重新梳理一遍这套界面", 40)]),
            conv("/w/c", [(.user, "视觉语言要统一", 60)]),
        ]
        convs += background(40)
        let out = MindsBuilder.vocabularyContagion(conversations: convs,
                                                   lexicon: ["视觉语言"], limit: 5)
        XCTAssertEqual(out.first?.itSaid, "配色要成体系，我们从视觉语言这一层看")
        XCTAssertEqual(out.first?.youSaid, "按视觉语言重新梳理一遍这套界面")
    }

    /// 英文词表词也要能命中——字符 n-gram 窗口 3..8 会把
    /// 「visual language」（15 字符）整个排除，英文用户的这一层恒空。
    func testLatinLexiconWordsAreDetected() {
        var convs = [
            conv("/w/a", [(.assistant, "let us fix the visual language of this app", 0)]),
            conv("/w/b", [(.user, "apply the visual language rules here", 30)]),
            conv("/w/c", [(.user, "visual language needs work", 50)]),
        ]
        convs += background(40)
        let out = MindsBuilder.vocabularyContagion(conversations: convs,
                                                   lexicon: ["visual language"], limit: 5)
        XCTAssertEqual(out.map(\.word), ["visual language"], "英文词表词此前恒不命中")
    }
}

extension VocabularyContagionTests {

    /// 「你说的」必须走 user_corpus 同一套剥离口径——textBlocksOnly 只剥图片
    /// 标记，Codex 文件引用头原样保留，真机上「公众号 you:」取到了
    /// 「## 微信公众号.png: /Users/<name>/…」这行注入，带家目录路径，
    /// 还会写进 minds.md 被 CLAUDE.md 注入（2026-08-20 现场）。
    func testUserSideUsesStrippedCorpusReading() {
        var convs = [
            conv("/w/a", [(.assistant, "封面放公众号的话要注意尺寸规范", 0)]),
            conv("/w/b", [(.user, "# Files mentioned by the user:\n## 公众号.png: /Users/somebody/LOGO/公众号.png\n## My request for Codex: 公众号封面怎么排版好", 30)]),
            conv("/w/c", [(.user, "公众号那篇也同步一下", 50)]),
        ]
        convs += background(40)
        let out = MindsBuilder.vocabularyContagion(conversations: convs,
                                                   lexicon: ["公众号"], limit: 5)
        XCTAssertEqual(out.first?.youSaid, "公众号封面怎么排版好",
                       "注入头要剥掉，路径不能进 minds.md: \(out.first?.youSaid ?? "nil")")
    }
}
