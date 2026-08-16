import Foundation

/// 从对话文本里机械抽「实体」：文件路径、代码标识符、URL、报错码。
///
/// 为什么用正则而不是模型：开发语料里信号最高的这四类**词汇精确、几乎无歧义**，
/// 正则就能抽干净，而且语言中立（中英文混排一视同仁）、零成本、可解释。
/// 这与索引层「机器只做机械加工，理解留给读的模型」是同一条原则。
///
/// 抽取顺序固定 url → path → errorCode → identifier，每抽完一类就把命中区间
/// 从待扫文本里挖成空格：URL 里天然含 `a/b/c.swift` 这样的路径片段，不挖掉就会
/// 被 path 规则重复抽一遍，同一段字符产出两个实体。
public enum EntityExtractor {

    public enum Kind: String, Equatable {
        case path
        case identifier
        case url
        case errorCode
    }

    public struct Entity: Equatable, Hashable {
        public let text: String
        public let kind: Kind
        public init(text: String, kind: Kind) {
            self.text = text
            self.kind = kind
        }
    }

    /// 短于此长度的片段一律丢弃：单字母变量、`a_b` 这类只会稀释信号。
    public static let minLength = 4

    /// 单个「连续无空白片段」的长度上限。超过它的片段在抽取前被整段挖成空格。
    ///
    /// 为什么需要：path 正则消掉「同一起点反复回退」之后，仍剩「每个起始位置重扫一遍
    /// 剩余文本」这层平方复杂度。实测 30k 连续 hex 串要 9.1s、60k base64url 串要 36.5s，
    /// 而 extract 跑在索引的串行写队列与事务里——一条含长 hex dump 或 base64url token 的
    /// 会话（.toolResult 里的真实形态）就能把索引管线卡住半分钟以上。
    /// 为什么可以直接丢：超长连续串本身就是「不含合法导航实体」的证据——没人靠一个
    /// 几万字符的「路径」找回对话。顺带堵住「超长伪实体原样写进 entities 表」这个脏数据口子。
    static let maxRunLength = 2048

    /// 匹配「连续无空白片段」，供 `sanitizeLongRuns` 定位超长 run。用正则而非手写扫描
    /// 判断空白，是为了让 ICU 正确处理代理对等 Unicode 细节，同时天然产出与四条正则
    /// 一致的 NSRange，替换时不必再自己折算 UTF-16 位置。
    private static let nonWhitespaceRun = try! NSRegularExpression(pattern: #"\S+"#)

    /// 入口净化：把超过 `maxRunLength` 的连续无空白片段整段替换成等长空格，其余字符
    /// 原样保留——单趟扫描，发生在喂给四条正则之前，不改动那四条正则本身。
    /// 等长替换是为了不改变字符串长度，不牵动任何后续位置计算。
    private static func sanitizeLongRuns(_ text: String) -> String {
        let ns = text as NSString
        // 全文都够不到上限，其中任何子串更不可能——扫都不用扫，这是最常见的情形。
        guard ns.length > maxRunLength else { return text }
        var longRuns: [NSRange] = []
        nonWhitespaceRun.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let r = m?.range, r.length > maxRunLength else { return }
            longRuns.append(r)
        }
        guard !longRuns.isEmpty else { return text }
        let mutable = NSMutableString(string: text)
        for r in longRuns.reversed() {
            mutable.replaceCharacters(in: r, with: String(repeating: " ", count: r.length))
        }
        return mutable as String
    }

    public static func extract(from text: String) -> [Entity] {
        guard !text.isEmpty else { return [] }
        var scratch = sanitizeLongRuns(text)
        var out: [Entity] = []
        var seen = Set<String>()

        for (kind, regex) in patterns {
            var consumed: [NSRange] = []
            let ns = scratch as NSString
            regex.enumerateMatches(in: scratch, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                guard let m else { return }
                let s = ns.substring(with: m.range)
                consumed.append(m.range)
                // 按字母数字字符计数，不把 `/` `.` `_` 这类结构分隔符算进长度——
                // 否则 "x/y.c" 这种每段只有一个字母、纯靠分隔符撑长度到 5 的
                // 退化路径会绕过 minLength 过滤，而它跟单字母变量一样是噪声。
                let meaningfulLength = s.reduce(into: 0) { count, ch in
                    if ch.isLetter || ch.isNumber { count += 1 }
                }
                guard meaningfulLength >= minLength, !seen.contains(s) else { return }
                seen.insert(s)
                out.append(Entity(text: s, kind: kind))
            }
            // 命中区间挖成空格再交给下一类，避免同一段字符被重复抽取
            if !consumed.isEmpty {
                let mutable = NSMutableString(string: scratch)
                for r in consumed.reversed() {
                    mutable.replaceCharacters(in: r, with: String(repeating: " ", count: r.length))
                }
                scratch = mutable as String
            }
        }
        return out
    }

    /// 顺序即优先级，见类型注释。
    ///
    /// 下面三处收紧都是代码审查用独立探针脚本实测出的缺陷修复（非理论推测），
    /// 详见每条正则上方注释。
    private static let patterns: [(Kind, NSRegularExpression)] = [
        // 终止字符集补中文全角标点与逗号：不补的话贪婪匹配会把「见 https://x.com，然后」
        // 里的中文标点、甚至标点后面一整段中文都吞进 URL——中文语境里 URL 后面几乎不留
        // 空格，这才是最常见的写法。更严重的是挖空顺序 url 先行，一旦吞过头连带盖住
        // 后面的合法路径，那段字符就再也不会被 path 规则看到（挖空不可逆）。
        //
        // 上一轮只补了「，。！？；：、」，全角右括号/右引号/书名号（）」』】》）与汉字
        // 本身都还漏着：「（见https://x.com/a）然后」会把 `）` 也吞进 URL，
        // 「部署到https://x.com上线」会把「上线」也吞进 URL（中文语境里 URL 后面
        // 直接接汉字、完全不留标点或空格同样是常见写法）。补全角闭合标点
        // `）」』】》` 与整个 CJK 统一表意文字区段 U+4E00–U+9FFF（写成 `一-鿿`：
        // 这段正则字面量是 Swift raw string `#"..."#`，Swift 自己不解释其中的反斜杠转义，
        // 原样把这几个字符交给 ICU 正则引擎；ICU 认的十六进制转义是 `\uhhhh`（四位，
        // 不带花括号）或 `\x{h...h}`，不是 Swift 字符串字面量的 `\u{h...h}`——若写成
        // 后者，ICU 会把 `一` 后面多出的一对花括号当成两个独立的字面量字符，
        // 而不是我们要的区间写法）。
        (.url, try! NSRegularExpression(pattern: #"https?://[^\s"'<>)\]，。！？；：、,）」』】》一-鿿]+"#)),

        // 外层目录段重复由 `+` 改占有量词 `++`：原写法在「一长串 word/ 但找不到合法
        // 扩展名」的输入上，要为每种可能的重复次数分别回溯一遍，真实文本一旦出现大段
        // 「像目录但没扩展名」的内容（贴的目录树、find/tree 输出）就会让这条正则显著
        // 变慢。`++` 让「消费完所有目录段后找不到扩展名」直接判失败、不再回退重试——
        // 目录字符集本就不含 `/`，每段在固定起点只有唯一的贪婪切法，占有化不改变
        // 匹配到的字符串集合，纯粹是去掉「不可能成功」的重试。末尾加 `(?![A-Za-z0-9])`
        // 边界，防止扩展名贪婪多吃相邻标识符的首字符（`Foo.swiftBar` 不该把 `B` 也
        // 算进扩展名）。如实描述这条边界的净效果——它**不能**让 `Bar` 被抽出来：
        // `Bar` 前面紧贴的是 `swift` 的末字母 `t`，identifier 规则的零宽断言
        // `(?<![A-Za-z0-9_])` 照样挡在那里，新旧写法在这个例子上都抽不到 `Bar`
        // （贴死无分隔的输入本身就有歧义，不是这条边界能解决的问题）。真正的净效果
        // 是两点：不再产出 `.swiftV`（多吃一个字符）这类脏扩展名实体；也不再因为
        // 扩展名多吃一截而把挖空范围过度扩大，连带盖掉前面本该留给别的规则去看的
        // 目录名标识符。
        (.path, try! NSRegularExpression(pattern: #"(?:[A-Za-z0-9_.~-]+/)++[A-Za-z0-9_.-]+\.[A-Za-z0-9]{1,6}(?![A-Za-z0-9])"#)),

        // 收尾 \b 改用零宽断言：ICU 默认的 \b 把汉字也计入「词字符」，于是英文标识符
        // 与中文零间距相邻（"看一下VaultArchive这个类"——前后不留空格才是中文最常见的
        // 写法）时边界判定失败、整个匹配落空，等于对中文场景系统性漏抽，与文件顶部
        // 「语言中立」的设计初衷矛盾。
        //
        // 第一次尝试的修法是 `options: [.useUnicodeWordBoundaries]`（对应 ICU 的
        // UAX #29 分词规则），中文相邻的目标用例全部修复，但在真实语料闸门上实测
        // 引入了一个更大的新回归：UAX #29 把字母/数字与紧邻的一个点号也判成同一个
        // 「词」（这是为了让 "3.14"「e.g.」这类自然语言习惯写法不被点号拆开），
        // 于是 `p.write_text`、`c.start_date`、`ConversationIndex.swift` 这类代码里
        // 极常见的「单字母变量.属性」「标识符.扩展名」写法，点号两侧的边界反而判定不
        // 成立，导致整个标识符匹配落空——实测丢了 787 个不同标识符、共 6283 次命中，
        // 远超中文相邻这个目标场景本身修到的 10 个。改用零宽断言 `(?<![A-Za-z0-9_])`
        // …`(?![A-Za-z0-9_])`：判定依据仍是纯 ASCII 的「是不是字母/数字/下划线」，
        // 点号从来不在这个集合里，不管点号另一侧是汉字、字母还是别的什么，边界永远
        // 成立——在同一份真实语料上复测：中文相邻的 10 个目标用例照常修复，丢失数
        // 归零。两种写法在纯 ASCII 场景（"The quick brown Fox"）行为一致。
        (.errorCode, try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])[A-Z][A-Z0-9]{2,}(?:_[A-Z0-9]+)+(?![A-Za-z0-9_])"#)),
        (.identifier, try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])[A-Z][a-z0-9]+(?:[A-Z][a-z0-9]+)+(?![A-Za-z0-9_])|(?<![A-Za-z0-9_])[a-z][a-z0-9]*(?:_[a-z0-9]+)+(?![A-Za-z0-9_])"#)),
    ]
}
