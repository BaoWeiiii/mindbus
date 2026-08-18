import Foundation
import NaturalLanguage

/// 个人词表：从用户自己的语料里统计出高频、凝固、边界自由的 2–6 字中文词
/// （spec §7.62；方法：Harris 1955 边界熵 + Church&Hanks 1990 PMI）。
///
/// 为什么值得存在：`库存经理` 这类只属于这个用户的领域词，通用词典与预训练模型里
/// 都没有，而固定宽度 trigram 会把它切成 `收益经`/`益经理` 碎片——词表切分后的
/// 第三路 FTS 才有它的词级倒排（中文查询 R@10 实测 +19pt）。零词典、零模型。
public enum PersonalLexicon {

    public struct Thresholds {
        /// 候选词最低出现次数。
        public var minFrequency: Int
        /// 凝固度门槛系数：cohesion ≥ 该值 × (词长 − 1)。
        public var cohesionPerExtraChar: Double
        /// 左右邻字熵的较小者不得低于此值。
        public var minBoundaryEntropy: Double

        public init(minFrequency: Int = 8,
                    cohesionPerExtraChar: Double = 60,
                    minBoundaryEntropy: Double = 1.2) {
            self.minFrequency = minFrequency
            self.cohesionPerExtraChar = cohesionPerExtraChar
            self.minBoundaryEntropy = minBoundaryEntropy
        }
    }

    private static func isCJK(_ ch: Character) -> Bool {
        ch.unicodeScalars.first.map { (0x4E00...0x9FFF).contains($0.value) } ?? false
    }

    /// 语料边界的占位词元（参与邻字分布——「总在句首出现」也算一种多样性）。
    private static let boundaryToken = "\u{0}"

    /// 构建词表。输入是段文本数组（`Segmenter.Segment.text` 直接喂进来即可）。
    ///
    /// 跑**两趟**同一套判据，区别只在「词元」是什么：
    /// - 中文喂**单字**序列——中文没有词边界，字是最小单位，词要靠算法发现；
    /// - 拉丁喂**单词**序列——空格已经把边界给出来了，要发现的是固定搭配
    ///   （user journey / machine learning）。
    ///
    /// 两趟的 run 互不穿插，中文侧因此逐字零回归（真机 4529 词，改造前后一致）。
    /// 注意拉丁词目前**只进词表、不进切分**：`segment` 仍旧只在中文 run 里查表，
    /// 英文原样透传给 unicode61。让英文短语参与 FTS 分词会直接改变检索排序，
    /// 那要跑评测管线才能证明没退化，不能顺手改。
    public static func build(corpus: [String], thresholds: Thresholds = Thresholds()) -> Set<String> {
        var cjkRuns: [[String]] = []
        var latinRuns: [[String]] = []
        for text in corpus {
            var cjk: [String] = []
            var latin: [String] = []
            var word = ""
            func flushCJK() { if !cjk.isEmpty { cjkRuns.append(cjk); cjk = [] } }
            func flushWord() { if !word.isEmpty { latin.append(word.lowercased()); word = "" } }
            func flushLatin() { flushWord(); if !latin.isEmpty { latinRuns.append(latin); latin = [] } }
            for ch in text {
                if isCJK(ch) {
                    flushLatin()
                    cjk.append(String(ch))
                } else if ch.isASCII && (ch.isLetter || ch.isNumber) {
                    flushCJK()
                    word.append(ch)
                } else if ch == " " {
                    // 空格是拉丁的词边界，但不打断这一段拉丁 run
                    flushCJK()
                    flushWord()
                } else {
                    flushCJK()
                    flushLatin()
                }
            }
            flushCJK()
            flushLatin()
        }
        return discover(runs: cjkRuns, join: { $0.joined() }, thresholds: thresholds)
            .union(discover(runs: latinRuns, join: { $0.joined(separator: " ") },
                            thresholds: thresholds, latinMode: true))
    }

    /// 一趟新词发现。判据三条，与词元是字还是单词无关：
    /// 频次够、凝固度够（不是偶然相邻）、左右邻的自由度够（不是更长串的碎片）。
    /// 一个拉丁词是不是虚词（冠词/介词/连词/助动词…），用于卡掉词的首尾
    /// ——同中文的「的 skill」不成词。
    ///
    /// 判据交给系统的词性标注器，不写停用词表：谁是虚词由语言本身决定。
    /// 也没有用频次——那要靠语料分布标定，而一份以中文和代码为主的语料里
    /// 「the」的占比被稀释到标不出来（2026-08-18 实测：阈值取 1% 仍漏掉
    /// the plan / is an / to review）。词性判据不依赖语料构成，换谁的库都成立。
    ///
    /// 中文趟不启用它：中文的对应问题由别处的判据管，这里一旦启用就会改变
    /// 已验证的中文词表（4529 个，逐字零回归是这次改造的前提）。
    static func isLatinFunctionWord(_ word: String) -> Bool {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = word
        tagger.setLanguage(.english, range: word.startIndex..<word.endIndex)
        guard let tag = tagger.tag(at: word.startIndex, unit: .word,
                                   scheme: .lexicalClass).0 else { return false }
        return latinFunctionWordClasses.contains(tag.rawValue)
    }

    /// 虚词的词类：只列**闭集**词类。
    ///
    /// 孤立的一个词没有上下文，标注器只有对闭集（冠词/介词/连词/代词/助词
    /// ——成员固定且有限）才可靠；开集词类一律不能信：实测 journey / cache /
    /// latency 被标成 Interjection（不认识的词都往那儿归），把 Interjection
    /// 算作虚词会连实词一起误杀，而实词恰恰是词表的正身。Verb 同理
    /// （这三个词换个跑法又会被标成动词），OtherWord 更是技术术语的聚集地。
    ///
    /// 代价是 be 动词漏网（is kept 这类会进来）。漏一点噪声好过丢掉真词。
    static let latinFunctionWordClasses: Set<String> = [
        "Determiner", "Preposition", "Conjunction", "Particle", "Pronoun",
    ]

    private static func discover(runs: [[String]], join: ([String]) -> String,
                                 thresholds: Thresholds,
                                 latinMode: Bool = false) -> Set<String> {
        var freq: [Int: [String: Int]] = [:]
        var totals: [Int: Double] = [:]
        var leftNeighbors: [String: [String: Int]] = [:]
        var rightNeighbors: [String: [String: Int]] = [:]
        /// n≥2 的 gram 拼回字符串后无法再切开（「用户体验」看不出词元边界），
        /// 算凝固度要按词元切，所以把词元序列留着。
        var gramTokens: [String: [String]] = [:]
        for n in 1...6 { freq[n] = [:] }

        for toks in runs {
            for n in 1...6 where toks.count >= n {
                for i in 0...(toks.count - n) {
                    let slice = Array(toks[i..<i + n])
                    let gram = join(slice)
                    freq[n]![gram, default: 0] += 1
                    if n >= 2 {
                        gramTokens[gram] = slice
                        let left = i > 0 ? toks[i - 1] : boundaryToken
                        let right = i + n < toks.count ? toks[i + n] : boundaryToken
                        leftNeighbors[gram, default: [:]][left, default: 0] += 1
                        rightNeighbors[gram, default: [:]][right, default: 0] += 1
                    }
                }
            }
        }
        for n in 1...6 { totals[n] = Double(freq[n]!.values.reduce(0, +)) }

        func probability(_ gram: String, _ n: Int) -> Double {
            guard let total = totals[n], total > 0 else { return 0 }
            return Double(freq[n]?[gram] ?? 0) / total
        }

        var stopCache: [String: Bool] = [:]
        func isEdgeStopword(_ t: String) -> Bool {
            guard latinMode else { return false }
            if let c = stopCache[t] { return c }
            let v = isLatinFunctionWord(t)
            stopCache[t] = v
            return v
        }

        func entropy(_ dist: [String: Int]?) -> Double {
            guard let dist, !dist.isEmpty else { return 0 }
            let total = Double(dist.values.reduce(0, +))
            return dist.values.reduce(0) { acc, c in
                let p = Double(c) / total
                return acc - p * log2(p)
            }
        }

        var lexicon = Set<String>()
        for n in 2...6 {
            for (gram, count) in freq[n]! where count >= thresholds.minFrequency {
                guard let toks = gramTokens[gram] else { continue }
                // 阿拉伯数字不构成词——「46 cities」「0 1px」是碎片不是概念。
                // 中文趟不受影响:那边的 gram 全是汉字。
                guard !gram.contains(where: { $0.isASCII && $0.isNumber }) else { continue }
                // 首尾不能是虚词(a / the / of),同中文的「的 skill」不成词
                if let f = toks.first, let l = toks.last,
                   isEdgeStopword(f) || isEdgeStopword(l) { continue }
                // 凝固度：整体概率 / 最优二分切法的概率积（取所有切法里最大的积 = 最保守——
                // 只要存在一种切法让左右两半各自都很常见，就说明这俩字/词大概率只是
                // 偶然相邻，不该被当成一个新词）。
                var maxSplitProduct = 0.0
                for cut in 1..<n {
                    let left = join(Array(toks[0..<cut])), right = join(Array(toks[cut...]))
                    maxSplitProduct = max(maxSplitProduct,
                                          probability(left, cut) * probability(right, n - cut))
                }
                guard maxSplitProduct > 0 else { continue }
                let cohesion = probability(gram, n) / maxSplitProduct
                // 门槛系数封顶在 3(=4 字词水平):5-6 字词的最长子串(4-5 字)在语料里
                // 与整词几乎同频出现,把「首字|余下」切法的积推高、凝固度天然上不去——
                // 线性门槛会让「第一性原理」这类真概念词永远够不到 240/300。
                // 长词本身已因长度而稀有,不需要凝固度再线性加码(2026-08-12 参数修订)。
                guard cohesion >= thresholds.cohesionPerExtraChar * Double(min(n - 1, 3)) else { continue }
                // 边界自由度：左右邻熵取较小者——只在固定上下文里出现的串
                // （熵≈0）大概率是更长短语的碎片，不是独立词。
                let boundaryEntropy = min(entropy(leftNeighbors[gram]), entropy(rightNeighbors[gram]))
                guard boundaryEntropy >= thresholds.minBoundaryEntropy else { continue }
                lexicon.insert(gram)
            }
        }
        return lexicon
    }

    /// 最长匹配切分：连续中文 run 内按词表 4→3→2 字贪心取词，未命中落单字；
    /// 切出的单元以空格连接。非中文字符原样透传（unicode61 自己会按它们分词）。
    ///
    /// 产出喂给 unicode61 tokenizer 的第三路 FTS——空格就是词边界，
    /// `库存经理` 从此是一个完整词元而不是三个 trigram 碎片。
    public static func segment(_ text: String, lexicon: Set<String>) -> String {
        guard !lexicon.isEmpty || text.contains(where: isCJK) else { return text }
        var out = ""
        var run: [Character] = []

        // 把当前中文 run 切分落盘；返回值表示这次调用是否真落了内容
        // （run 非空），供调用方判断「紧跟的下一个字符要不要补空格分界」。
        @discardableResult
        func flushRun() -> Bool {
            guard !run.isEmpty else { return false }
            var units: [String] = []
            var i = 0
            while i < run.count {
                var matched: String?
                for n in stride(from: 6, through: 2, by: -1) where i + n <= run.count {
                    let candidate = String(run[i..<i+n])
                    if lexicon.contains(candidate) { matched = candidate; break }
                }
                if let word = matched {
                    units.append(word)
                    i += word.count
                } else {
                    units.append(String(run[i]))
                    i += 1
                }
            }
            // 与前面已落的文字之间也要有空格分界，避免 `ping库存经理` 粘连回去
            if let last = out.last, last != " " { out.append(" ") }
            out += units.joined(separator: " ")
            run = []
            return true
        }

        for ch in text {
            if isCJK(ch) {
                run.append(ch)
            } else {
                // 中文 run 落盘后，若紧跟的字符非空白，先补一个空格分界；
                // 空白字符本身已经是天然分界，不用再补；若刚才没有 run 可落
                // （连续非中文字符），也不需要额外插空格——原样透传即可。
                if flushRun(), !ch.isWhitespace {
                    out.append(" ")
                }
                out.append(ch)
            }
        }
        flushRun()
        return out
    }
}
