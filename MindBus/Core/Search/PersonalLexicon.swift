import Foundation

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

    /// 语料边界/非中文邻字的占位符号（参与邻字分布——「总在句首出现」也算一种多样性）。
    private static let boundary: Character = "\u{0}"

    /// 构建词表。输入是段文本数组（`Segmenter.Segment.text` 直接喂进来即可）。
    public static func build(corpus: [String], thresholds: Thresholds = Thresholds()) -> Set<String> {
        // n-gram 频次表（n=1...6）与 2-6 gram 的左右邻字分布
        var freq: [Int: [String: Int]] = [1: [:], 2: [:], 3: [:], 4: [:], 5: [:], 6: [:]]
        var totals = [Int: Double]()
        var leftNeighbors: [String: [Character: Int]] = [:]
        var rightNeighbors: [String: [Character: Int]] = [:]

        for text in corpus {
            // 抽出连续中文 run；run 之间彼此独立（跨非中文字符不构成候选）。
            // 先转 [Character] 数组再切片：String 自身的 Index 下标是 O(n)，
            // 逐字符扫描一遍全语料若还伴随 O(n) 下标就退化成 O(n²)。
            var run: [Character] = []
            func flush() {
                guard !run.isEmpty else { return }
                let chars = run
                for n in 1...6 {
                    guard chars.count >= n else { break }
                    for i in 0...(chars.count - n) {
                        let gram = String(chars[i..<i+n])
                        freq[n]![gram, default: 0] += 1
                        if n >= 2 {
                            let left = i > 0 ? chars[i-1] : boundary
                            let right = i + n < chars.count ? chars[i+n] : boundary
                            leftNeighbors[gram, default: [:]][left, default: 0] += 1
                            rightNeighbors[gram, default: [:]][right, default: 0] += 1
                        }
                    }
                }
                run = []
            }
            for ch in text {
                if isCJK(ch) { run.append(ch) } else { flush() }
            }
            flush()
        }
        for n in 1...6 { totals[n] = Double(freq[n]!.values.reduce(0, +)) }

        func probability(_ gram: String) -> Double {
            let n = gram.count
            guard let total = totals[n], total > 0 else { return 0 }
            return Double(freq[n]?[gram] ?? 0) / total
        }

        func entropy(_ dist: [Character: Int]?) -> Double {
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
                // 凝固度：整体概率 / 最优二分切法的概率积（取所有切法里最大的积 = 最保守——
                // 只要存在一种切法让左右两半各自都很常见，就说明这俩字/词大概率只是
                // 偶然相邻，不该被当成一个新词）。
                let chars = Array(gram)
                var maxSplitProduct = 0.0
                for cut in 1..<n {
                    let left = String(chars[0..<cut]), right = String(chars[cut...])
                    maxSplitProduct = max(maxSplitProduct, probability(left) * probability(right))
                }
                guard maxSplitProduct > 0 else { continue }
                let cohesion = probability(gram) / maxSplitProduct
                // 门槛系数封顶在 3(=4 字词水平):5-6 字词的最长子串(4-5 字)在语料里
                // 与整词几乎同频出现,把「首字|余下」切法的积推高、凝固度天然上不去——
                // 线性门槛会让「第一性原理」这类真概念词永远够不到 240/300。
                // 长词本身已因长度而稀有,不需要凝固度再线性加码(2026-08-12 参数修订)。
                guard cohesion >= thresholds.cohesionPerExtraChar * Double(min(n - 1, 3)) else { continue }
                // 边界自由度：左右邻字熵取较小者——只在固定上下文里出现的串
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
