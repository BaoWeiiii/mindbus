import XCTest
import SQLite3
@testable import MindBusCore

/// 探针（临时）：目标词 vs 平庸词，在 (tf, df, projects) 空间里的位置
final class ZProbe: XCTestCase {

    func corpus() throws -> [(text: String, cwd: String)] {
        let path = NSHomeDirectory() + "/Library/Application Support/MindBus/index.sqlite"
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw XCTSkip("no index")
        }
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT u.text, c.cwd FROM user_corpus u JOIN conversations c ON c.rowid=u.conv_rowid", -1, &st, nil)
        var out: [(String, String)] = []
        while sqlite3_step(st) == SQLITE_ROW {
            out.append((String(cString: sqlite3_column_text(st, 0)),
                        sqlite3_column_text(st, 1).map { String(cString: $0) } ?? ""))
        }
        sqlite3_finalize(st); sqlite3_close(db)
        return out
    }

    func skip_testProfile() throws {
        let rows = try corpus()
        let targets = ["用户旅程", "第一性原理", "AI 味", "乔布斯", "马斯克", "贝索斯",
                       "肖恩", "宫本茂", "体验", "原生", "护城河", "网络效应", "飞轮",
                       "选择", "节点", "仓库", "消息", "GitHub", "口头禅"]
        print("\nPROBE  词            tf    df  proj  tf/df  proj/df")
        for w in targets {
            var tf = 0, df = 0
            var projs = Set<String>()
            for (t, cwd) in rows {
                let n = t.lowercased().components(separatedBy: w.lowercased()).count - 1
                guard n > 0 else { continue }
                tf += n; df += 1
                if !cwd.isEmpty { projs.insert(cwd) }
            }
            guard tf > 0 else { print("PROBE  \(w) —— 语料里没有"); continue }
            print(String(format: "PROBE  %@ %5d %5d %5d %6.1f %8.2f",
                         w.padding(toLength: 12, withPad: " ", startingAt: 0),
                         tf, df, projs.count, Double(tf)/Double(df),
                         Double(projs.count)/Double(df)))
        }
    }

    /// 全语料 n-gram 枚举 + 新判据「df≥3 且 tf/df 低」，看落出什么
    func skip_testMentionTypeDiscriminator() throws {
        let rows = try corpus()
        func isCJK(_ c: Character) -> Bool {
            c.unicodeScalars.first.map { (0x4E00...0x9FFF).contains($0.value) } ?? false
        }
        var tf: [String: Int] = [:], df: [String: Int] = [:]
        var projs: [String: Set<String>] = [:]
        for (text, cwd) in rows {
            var seen = Set<String>()
            var run: [Character] = []
            func flush() {
                guard run.count >= 2 else { run = []; return }
                for n in 2...min(6, run.count) {
                    for i in 0...(run.count - n) {
                        let g = String(run[i..<i+n])
                        tf[g, default: 0] += 1
                        if seen.insert(g).inserted {
                            df[g, default: 0] += 1
                            if !cwd.isEmpty { projs[g, default: []].insert(cwd) }
                        }
                    }
                }
                run = []
            }
            for ch in text { if isCJK(ch) { run.append(ch) } else { flush() } }
            flush()
        }
        print("PROBE 候选 n-gram 总数 \(tf.count)")
        // 判据:出现在 ≥3 场;每场平均说 ≤5 遍(提及型);跨 ≥3 个项目
        let picked = tf.filter { g, c in
            let d = df[g] ?? 0
            return d >= 3 && Double(c) / Double(d) <= 5 && (projs[g]?.count ?? 0) >= 3
        }
        print("PROBE 过判据的 \(picked.count) 个")
        // 按「覆盖场数」降序看前 60
        let top = picked.keys.sorted {
            (df[$0] ?? 0, tf[$0] ?? 0) > (df[$1] ?? 0, tf[$1] ?? 0)
        }.prefix(60)
        print("PROBE 覆盖最广的 60 个:")
        print("PROBE   " + top.map { "\($0)(\(df[$0] ?? 0)场)" }.joined(separator: " "))
        for w in ["用户旅程", "乔布斯", "原生", "第一性原理", "体验"] {
            print("PROBE   \(w) 是否入选: \(picked[w] != nil)")
        }
    }

    /// 假设 A:重要的词集中出现在「你交代任务」的时刻(每场第一条消息),
    /// 而干活的词散在中段。
    /// 假设 B:重要的话跟在立场标记后面(我觉得/我希望/不要/必须/应该)。
    func skip_testPositionAndStance() throws {
        let path = NSHomeDirectory() + "/Library/Application Support/MindBus/index.sqlite"
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw XCTSkip("no index")
        }
        // user_corpus 每行是一场对话的全部 user 消息(以 \n 连接)
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT text FROM user_corpus", -1, &st, nil)
        var convs: [String] = []
        while sqlite3_step(st) == SQLITE_ROW { convs.append(String(cString: sqlite3_column_text(st, 0))) }
        sqlite3_finalize(st); sqiteClose(db)

        func sqiteClose(_ d: OpaquePointer?) { sqlite3_close(d) }

        let firsts = convs.compactMap { $0.split(separator: "\n").first.map(String.init) }
        let rest = convs.map { c -> String in
            let parts = c.split(separator: "\n").dropFirst()
            return parts.joined(separator: " ")
        }
        let firstChars = firsts.reduce(0) { $0 + $1.count }
        let restChars = rest.reduce(0) { $0 + $1.count }
        print("PROBE 首条消息合计 \(firstChars) 字 / 其余 \(restChars) 字 (占比 \(String(format: "%.1f", Double(firstChars)*100/Double(firstChars+restChars)))%)")

        let words = ["用户旅程", "乔布斯", "第一性原理", "体验", "原生", "护城河",
                     "选择", "节点", "仓库", "代码", "文件"]
        print("PROBE  词          首条中 每千字   其余中 每千字   富集倍数")
        for w in words {
            let a = firsts.reduce(0) { $0 + $1.components(separatedBy: w).count - 1 }
            let b = rest.reduce(0) { $0 + $1.components(separatedBy: w).count - 1 }
            let ra = Double(a) * 1000 / Double(max(firstChars, 1))
            let rb = Double(b) * 1000 / Double(max(restChars, 1))
            print(String(format: "PROBE  %@ %5d %7.3f %6d %7.3f %8.2fx",
                         w.padding(toLength: 10, withPad: " ", startingAt: 0),
                         a, ra, b, rb, rb > 0 ? ra/rb : -1))
        }
    }

    /// 假设 C:观点词富集在「立场句」——你反驳/纠正/表态的那些消息。
    /// 立场标记是汉语里表达主观判断的封闭词类,不是我挑的关键词。
    func testStanceEnrichment() throws {
        let path = NSHomeDirectory() + "/Library/Application Support/MindBus/index.sqlite"
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw XCTSkip("no index")
        }
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT text FROM user_corpus", -1, &st, nil)
        var msgs: [String] = []
        while sqlite3_step(st) == SQLITE_ROW {
            msgs.append(contentsOf: String(cString: sqlite3_column_text(st, 0))
                .split(separator: "\n").map(String.init))
        }
        sqlite3_finalize(st); sqlite3_close(db)

        // 立场标记:主观判断 / 否定纠正 / 祈使要求
        let stance = ["我觉得", "我认为", "我希望", "我想", "其实", "不是", "不要", "别",
                      "应该", "必须", "为什么", "能不能", "是不是", "而是", "但是", "不对"]
        var withS: [String] = [], without: [String] = []
        for m in msgs {
            if stance.contains(where: { m.contains($0) }) { withS.append(m) } else { without.append(m) }
        }
        let ca = withS.reduce(0) { $0 + $1.count }, cb = without.reduce(0) { $0 + $1.count }
        print("PROBE 立场句 \(withS.count) 条 / \(ca) 字   其余 \(without.count) 条 / \(cb) 字")
        print("PROBE  词          立场句每千字  其余每千字   富集")
        for w in ["用户旅程", "乔布斯", "马斯克", "第一性原理", "体验", "原生", "AI 味",
                  "护城河", "选择", "节点", "仓库", "代码", "文件", "测试"] {
            let a = withS.reduce(0) { $0 + $1.components(separatedBy: w).count - 1 }
            let b = without.reduce(0) { $0 + $1.components(separatedBy: w).count - 1 }
            let ra = Double(a) * 1000 / Double(max(ca, 1)), rb = Double(b) * 1000 / Double(max(cb, 1))
            print(String(format: "PROBE  %@ %10.3f %11.3f %7.2fx",
                         w.padding(toLength: 10, withPad: " ", startingAt: 0), ra, rb,
                         rb > 0 ? ra/rb : 99))
        }
    }
}
