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
