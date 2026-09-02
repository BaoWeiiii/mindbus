import Foundation
import SQLite3

/// 对话索引层：系统 SQLite + FTS5(trigram)。
/// metadata 表常驻查询，全文进 FTS（contentless，不占内存）。
/// 线程安全：单实例内由串行队列保证；跨实例（多连接）由 WAL + busy_timeout 保证。
/// 线程安全由内部串行 queue 保证，故 @unchecked Sendable（可被 TaskGroup 子任务并发持有）。
public final class ConversationIndex: @unchecked Sendable {
    private let db: SQLiteDB
    private let queue = DispatchQueue(label: "ai.mindbus.index")

    /// 全 App 唯一实例。
    ///
    /// 此前启动预热与打开窗口各建一个连接，首次启动时并发跑两遍全量扫描、
    /// 两个连接同时写同一个库：deferred 事务在读转写之间被抢占会返回
    /// SQLITE_BUSY_SNAPSHOT（绕过 busy handler），或撞 UNIQUE(file_path)，
    /// 两种都会让整批 upsert 回滚且被上游 `try?` 吞掉 —— 那批对话的 mtime
    /// 从未写入，于是每次扫描重新解析、重新失败，永久缺失。
    /// 收敛到单实例后，内部串行队列天然排掉了这类竞争。
    public static let shared: ConversationIndex? = {
        openRecoveringCorruption(path: ConversationStore.defaultIndexPath())
    }()

    /// 打开索引；打不开（文件损坏）时把损坏文件挪到 `<path>.corrupt-<时间戳>` 后重建空库。
    /// 索引可从源 JSONL 完整重建——宁可丢缓存重扫一轮，也不静默空列表。
    public static func openRecoveringCorruption(path: String) -> ConversationIndex? {
        if let idx = try? ConversationIndex(path: path) { return idx }
        let fm = FileManager.default
        // 文件都不存在还打不开 = 目录不可写等环境问题，搬走也没用，别乱动
        guard fm.fileExists(atPath: path) else { return nil }
        // 历史的 .corrupt-* 永不清理会一直吃磁盘：索引可从源文件重建，旧损坏件没有用处，
        // 只留本次这一份供排障。
        let dir = (path as NSString).deletingLastPathComponent
        let corruptPrefix = (path as NSString).lastPathComponent + ".corrupt-"
        if let names = try? fm.contentsOfDirectory(atPath: dir) {
            for n in names where n.hasPrefix(corruptPrefix) {
                try? fm.removeItem(atPath: (dir as NSString).appendingPathComponent(n))
            }
        }
        let stamp = Int(Date().timeIntervalSince1970)
        for suffix in ["", "-wal", "-shm"] {
            let src = path + suffix
            guard fm.fileExists(atPath: src) else { continue }
            try? fm.moveItem(atPath: src, toPath: path + ".corrupt-\(stamp)" + suffix)
        }
        NSLog("[index] open failed — moved corrupt index to %@.corrupt-%d, rebuilding from source files",
              path, stamp)
        return try? ConversationIndex(path: path)
    }

    public init(path: String) throws {
        db = try SQLiteDB(path: path)
        try db.exec(Self.schemaSQL)
        try migrateDataPolicyIfNeeded()
    }

    /// 只读打开失败的四种原因，都要能变成用户照着做就能修的提示。
    public enum ReadOnlyOpenError: Error, Equatable {
        /// 索引文件不存在——用户从没打开过 App。
        case indexMissing(path: String)
        /// 文件在，但只读连接开不了或读不出来。
        ///
        /// 实测的主因：库处于 WAL 模式而 `-wal`、`-shm` 两个副文件**都不在**
        /// （只恢复了主库的备份、手工拷走了单个文件），此时纯只读连接无从建立
        /// 读事务，返回 SQLITE_CANTOPEN。次因是文件损坏或不是 SQLite 库。
        ///
        /// 两者的修复动作恰好相同：让 App 用读写连接打开一次——WAL 副文件会被重建，
        /// 真损坏则走 `openRecoveringCorruption` 挪走重扫。**只读进程自己不许做这件事**
        /// （退回读写打开会在 close 时 checkpoint、真的改写用户主库；挪文件更是越权）。
        case unopenable(detail: String)
        /// 盘上结构版本与本进程期望不符，双向都算。
        case policyMismatch(found: Int32, expected: Int32)
        /// 版本号对但表缺——首次建库中途被打断。
        case incompleteSchema(missing: String)
    }

    /// 只读打开一份**已经存在**的索引：不建表、不迁移、不写入。
    ///
    /// 与 `init(path:)` 的关键差别就是"什么都不改"。`init` 那条路径 exec schema 并跑
    /// 数据政策迁移，版本不符时 DROP 全部表、依赖调用方随后全量重扫补回来；MCP 进程
    /// 没有 loader，走那条路等于把用户的索引清空且无人重建。
    ///
    /// 版本要求**严格相等**：盘上比我新（用户装了更新的 App）或比我旧（MCP 二进制过期）
    /// 都拒绝服务。查一个结构未知的库，最好的结果是报错，最坏的结果是静默给出错误答案。
    ///
    /// ⚠️ 返回值是一个**功能完整**的 `ConversationIndex`：类型上不阻止调用方接着调
    /// `upsert` / `prune` / `markSkipped` / `replaceBrowserVault`。真正兜底的是底层
    /// 连接的 `SQLITE_OPEN_READONLY` 标志（写入在物理层被拒绝），但 `prune` /
    /// `markSkipped` / `replaceBrowserVault` 内部都用 `try? queue.sync` 吞掉错误——
    /// 在只读实例上调它们不会崩溃、也不会抛错，而是**静默无操作地"成功"返回**，调用方
    /// 很容易误以为写入生效了。只读门面（禁止在类型层面调这些方法）是后续任务的事，
    /// 这里先把这个陷阱写清楚。
    public static func openReadOnly(path: String) throws -> ConversationIndex {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ReadOnlyOpenError.indexMissing(path: path)
        }
        // 开库与第一次读都可能因「WAL 副文件缺失」或「文件损坏」失败，抛出的是底层
        // `SQLiteDB.DBError`（形如 `step(14)`）——那种错误码递到 MCP 输出里用户看不懂。
        // 在这里就翻成 `.unopenable`，好让上层给出「打开一次 App 即可修」这句话。
        let db: SQLiteDB
        var found: Int32 = 0
        do {
            db = try SQLiteDB(path: path, queryOnly: true)
            try db.query("PRAGMA user_version;", row: { found = sqlite3_column_int($0, 0) })
        } catch {
            throw ReadOnlyOpenError.unopenable(detail: String(describing: error))
        }
        guard found == dataPolicyVersion else {
            throw ReadOnlyOpenError.policyMismatch(found: found, expected: dataPolicyVersion)
        }
        // 版本号是最后一步才写的（见 migrateDataPolicyIfNeeded），所以版本对基本等于表全在；
        // 但"基本等于"不是"等于"——首次建库被 kill 掉就能留下这种库，逐张确认一次很便宜。
        // 7 张表，`schemaSQL` 建的表一张不落——此前漏了 `skipped_files`，只缺它的
        // 半成品库能混过校验，而公开的 `knownMtimes()` 会查这张表，届时才现场报错。
        // vocab_uni/vocab_lex（fts5vocab 虚表）同一批加进来：首建中途被打断的半成品库
        // 也可能恰好缺它们两个（`schemaSQL` 一条 exec 多条语句，某条失败就会少建出
        // 后续几张）——虽然是纯视图无数据，但查询期（`expansionTerms`）直接假设它们
        // 存在，缺了不是"结果为空"而是 SQL 报错，同样要在这道校验关卡挡住。
        for table in ["conversations", "segments", "segments_fts", "segments_fts_uni",
                      "entities", "conversation_entities", "skipped_files",
                      "segments_fts_lex", "lexicon", "lexicon_meta", "mcp_refs", "user_corpus",
                      "milestone_candidates", "decision_points",
                      "vocab_uni", "vocab_lex"] {
            var exists = false
            try db.query("SELECT 1 FROM sqlite_master WHERE name = ? LIMIT 1;",
                         bind: { SQLiteDB.bindText($0, 1, table) },
                         row: { _ in exists = true })
            guard exists else { throw ReadOnlyOpenError.incompleteSchema(missing: table) }
        }
        return ConversationIndex(adopting: db)
    }

    /// 接管一个已开好的连接，跳过建表与迁移。只给 `openReadOnly` 用。
    private init(adopting db: SQLiteDB) {
        self.db = db
    }

    /// 建表 SQL（init 与数据政策迁移共用，单一真相）。
    /// 全部 IF NOT EXISTS，可重复执行；但它对「已存在但缺列」的旧表什么都不做——
    /// 列变更（如 v5 的 title）依赖 migrateDataPolicyIfNeeded 的 DROP 重建焕新表结构。
    private static let schemaSQL = """
    CREATE TABLE IF NOT EXISTS conversations (
        rowid INTEGER PRIMARY KEY,
        id TEXT UNIQUE, source TEXT, start_at REAL, end_at REAL,
        cwd TEXT, git_branch TEXT, title TEXT, preview TEXT, message_count INTEGER,
        file_path TEXT UNIQUE, mtime REAL,
        -- 最后一条消息的角色（user/assistant/''）——「断点」信号：最后一条是 user
        -- = 你问了没人答（被打断/没继续），Minds 的 UNFINISHED THREADS 按它数
        last_role TEXT NOT NULL DEFAULT '',
        -- 悬而未决的另一半：**它**最后问了你一个问题、你再没回过。NULL = 没有。
        -- 「你问了没人答」天然稀有（AI 工具总会回复，真机 141 场只有 4 场），
        -- 反过来看才抓得住真正悬着的事。判据见 MindsMilestones.trailingQuestion。
        -- 新列一律加在表末尾：中间插列会打乱按列索引取值的读取路径。
        open_question TEXT
    );
    -- 段：检索的基本单位。text 要存（contentless FTS 没有原文可回显，命中片段与短词 LIKE 兜底都靠它）
    CREATE TABLE IF NOT EXISTS segments (
        rowid INTEGER PRIMARY KEY,
        conv_rowid INTEGER NOT NULL,
        first_msg INTEGER NOT NULL,
        last_msg INTEGER NOT NULL,
        text TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_segments_conv ON segments(conv_rowid);
    -- 三路分词各打各的强项（trigram 子串 / unicode61 英文词 / lex 个人词表词级），检索时 RRF 融合
    CREATE VIRTUAL TABLE IF NOT EXISTS segments_fts USING fts5(
        text, content='', contentless_delete=1, tokenize='trigram'
    );
    CREATE VIRTUAL TABLE IF NOT EXISTS segments_fts_uni USING fts5(
        text, content='', contentless_delete=1, tokenize="unicode61 remove_diacritics 2"
    );
    -- 第三路：个人词表切分后的词级索引（中文 R@10 实测 +19pt）。
    -- contentless；rowid 对齐 segments.rowid，与 _uni 完全同构。
    CREATE VIRTUAL TABLE IF NOT EXISTS segments_fts_lex USING fts5(
        text, content='', contentless_delete=1, tokenize="unicode61 remove_diacritics 2"
    );
    -- RM3 查询扩展算 df 用：'row' 模式给 (term, doc, cnt) 三列，
    -- doc 即该词元出现在几个段（segments 表行）里——正是 IDF 过滤要的文档频率。
    -- 纯视图、无自有数据（不占盘、不需要迁移），不 bump dataPolicyVersion。
    CREATE VIRTUAL TABLE IF NOT EXISTS vocab_uni USING fts5vocab(segments_fts_uni, 'row');
    CREATE VIRTUAL TABLE IF NOT EXISTS vocab_lex USING fts5vocab(segments_fts_lex, 'row');
    -- 个人词表本体与构建元数据（语料规模用于「涨 20% 才重建」判定）
    CREATE TABLE IF NOT EXISTS lexicon (word TEXT PRIMARY KEY);
    CREATE TABLE IF NOT EXISTS lexicon_meta (
        id INTEGER PRIMARY KEY CHECK(id = 1),
        corpus_chars INTEGER NOT NULL,
        built_at REAL NOT NULL
    );
    -- 用户语料（会话级，该会话全部 user 消息拼接）。「你的语言」与「对话的语言」
    -- 从此可分——词表/检索继续用全语料，Minds 的「你的概念地图」只按这份数频次
    -- （2026-08-12：用户实锤「高频词不像我给的」——因为全语料以 AI 输出为主）。
    CREATE TABLE IF NOT EXISTS user_corpus (
        conv_rowid INTEGER PRIMARY KEY,
        text TEXT NOT NULL
    );
    -- 「你点头的时刻」的原始素材:每条短 user 回应 + 它前面那条够长的 AI 汇报
    -- 首句(headline 为 NULL = 前面没有汇报)。刻意只存素材、不存结论——认可词表
    -- 要看过全部对话才学得出来,而判据以后还会改,改判据不该要求用户重建索引。
    CREATE TABLE IF NOT EXISTS milestone_candidates (
        conv_rowid INTEGER NOT NULL,
        approval TEXT NOT NULL,
        headline TEXT,
        at REAL NOT NULL,
        message_id TEXT NOT NULL DEFAULT ''
    );
    CREATE INDEX IF NOT EXISTS idx_milestone_conv ON milestone_candidates(conv_rowid);
    -- 「你拍板的时刻」的原始素材:AI 以问号收尾地征询之后,你说的那句原话。
    -- 同样只存素材——长度范围与「是不是疑问句」两个阈值最容易改,留给构建层。
    CREATE TABLE IF NOT EXISTS decision_points (
        conv_rowid INTEGER NOT NULL,
        statement TEXT NOT NULL,
        at REAL NOT NULL,
        message_id TEXT NOT NULL DEFAULT ''
    );
    CREATE INDEX IF NOT EXISTS idx_decision_conv ON decision_points(conv_rowid);
    -- MCP 引用回流聚合（Task 5 写入；只用于记录与展示，本轮绝不进排序公式）
    CREATE TABLE IF NOT EXISTS mcp_refs (
        conv_id TEXT PRIMARY KEY,
        ref_count INTEGER NOT NULL,
        last_ref REAL NOT NULL
    );
    -- 解析后确认「无产出」的文件（sidechain / 观察者日志 / 空文件 / 格式不符）。
    -- 不记的话它们永远进不了 conversations，于是 mtime 比对永远查不到、
    -- 永远被当成「变化了」而重新解析 —— 实测本机 5620 个 jsonl 里有 5248 个
    -- 属于这类，每次增量扫描都要把它们重解析一遍并再次失败。
    CREATE TABLE IF NOT EXISTS skipped_files (
        file_path TEXT PRIMARY KEY,
        mtime REAL NOT NULL
    );
    -- 实体：从段原文机械抽出的路径/标识符/URL/报错码。
    -- 独立成表而非塞进 conversations：同一实体跨会话复现正是「顺着找」的主力线索。
    CREATE TABLE IF NOT EXISTS entities (
        rowid INTEGER PRIMARY KEY,
        text TEXT NOT NULL,
        kind TEXT NOT NULL,
        UNIQUE(text, kind)
    );
    CREATE TABLE IF NOT EXISTS conversation_entities (
        conv_rowid INTEGER NOT NULL,
        entity_rowid INTEGER NOT NULL,
        PRIMARY KEY (conv_rowid, entity_rowid)
    );
    CREATE INDEX IF NOT EXISTS idx_conv_entities_entity ON conversation_entities(entity_rowid);
    """

    /// 数据政策版本。loader 的入库规则变化（哪些文件该跳过、哪些内容算注入）时 bump：
    /// 已按旧政策入库的行不会因 mtime 未变而被重扫修正——版本不匹配直接清空重建，
    /// 索引可从源文件完整重建，全量重扫仅数秒，比任何「精准迁移」都可靠。
    ///
    /// v2: Codex 多 agent 子会话（parent_thread_id）跳过 + 注入过滤扩充
    ///     （recommended_plugins / multi_agent_mode）——清掉旧政策留下的垃圾行。
    /// v3: 新增 search_text 平行原文表（短词全文搜索）——重建以填充。
    /// v4: Claude 系「API Error 残骸」过滤 + Codex 同线程快照收敛——清掉存量脏行
    ///     （残骸文件 mtime 不变、任何增量重扫都修不到它们）。
    /// v5: （已烧掉，勿复用）2026-08-02 数据链路审查期间的本机试验构建占用了此号——
    ///     只带 title 列 schema、无任何 loader 修复；创始人机器的库已停在 v5。
    /// v6: 壳会话过滤（单条 user、无回复、源文件已凉）清掉 318 条存量壳 +
    ///     conversations 新增 title 列（官方 ai-title）+ browser 行补 search_text。
    ///     自此版起迁移改为 DROP 重建（而非 DELETE 清空）：CREATE TABLE IF NOT EXISTS
    ///     不会给已存在的旧表加新列，DROP 后重跑 schemaSQL 让表结构随版本一起焕新
    ///     ——这也是必须跳过 v5 的原因：v4（正式）与 v5（试验残留）都要触发重建。
    /// v7: 幽灵条目清理。「活跃会话豁免」窗口入库的半成品随后补齐成被过滤残骸
    ///     （API Error stub）时，旧记录残留：列表可见、详情被同一过滤器拒掉，
    ///     误报「源文件已无法读取」。LoaderRuntime 已改为 barren 文件同步 prune
    ///     既有行；此 bump 清掉修复前积累的存量（残骸 mtime 不变，增量修不到）。
    /// v8: 新增 conversations_fts_uni（unicode61 第二路分词）。新表对存量行是空的，
    ///     不重建的话英文那一路永远查不到东西 —— 必须整体重扫填充。
    /// v9: 索引单位从会话级换成段级（conversations_fts/_uni + search_text 三表删除，
    ///     改为 segments + segments_fts/_uni）。旧行没有段，不重建则搜不到任何东西。
    /// v10: 新增 entities / conversation_entities（正则实体抽取）。旧行没有实体，
    ///      不重建则实体页与地图页永远是空的。
    /// v11: 实体抽取口径从「segments 检索文本」改成排除 `.toolUse` 的专用口径
    ///      （`Segmenter.entityText`）——真实语料 Top-30 里约 12 条是 Claude Code 的
    ///      工具调用参数名（file_path/old_string/new_string 等），复现率虚高纯粹是
    ///      日志格式所致。旧行按旧口径抽出的实体不会因 mtime 未变而被重扫修正，
    ///      必须整体重建才能让实体表换成新口径。
    /// v12: `EntityExtractor.extract` 入口新增超长连续无空白 run 净化
    ///      （`maxRunLength = 2048`）——超过此长度的片段（长 hex dump、base64url token
    ///      等，本质是压垮 path 正则平方复杂度的攻击面）在抽取前被整段挖成空格，不再
    ///      产出实体，顺带堵住「超长伪实体原样写进 entities 表」的脏数据口子。旧行按
    ///      旧口径可能抽出的这类超长实体不会因 mtime 未变而被重扫修正，必须整体重建才能清掉。
    /// v13: 个人词表第三路检索（segments_fts_lex + lexicon + lexicon_meta）与
    ///      MCP 引用聚合表（mcp_refs）。第三路对**全部存量段**都要有行（行数守恒），
    ///      增量扫描只会重写 mtime 变化的文件——必须整体重建让存量段进第三路。
    /// v14: 用户语料表（user_corpus）——「你说的话」与「对话全文」分开存，
    ///      Minds 概念地图从此按 user 消息数频次（检索词表仍用全语料）。
    ///      存量行没有这份数据，必须整体重建让全部会话补上。
    /// v15: user 语料剔除系统注入（hook 反馈/会话续传等以 user 角色进场的
    ///      非人话）+ last_role 改「最后一条非注入消息」口径——存量行按旧口径
    ///      写入，必须整体重建洗净（v14 从未发布，对外零成本）。
    /// v16: user 语料消息内部换行压平成空格——「\n=消息边界」承诺从此成立。
    ///      多行消息（粘贴代码/计划模板）的内部行曾伪装成独立短消息:口头禅真机
    ///      现场 Run:/import ×21、echo ×9、fi ×7 全是粘贴行。存量行内部换行
    ///      还在，必须整体重建压平（v15 同样从未发布，对外零成本）。
    /// v17: user 语料剥离 Codex 客户端文件引用头（「# Files mentioned by the
    ///      user:」——「## My request for Codex:」之后才是用户的话，无标记的整条
    ///      是文件清单）。真机 16 场被它把 /var/folders 临时路径灌进语料、创世句
    ///      被顶成 markdown 标题遭噪声正则误杀。存量行含着注入头，必须整体重建。
    public static let dataPolicyVersion: Int32 = 24

    private func migrateDataPolicyIfNeeded() throws {
        var current: Int32 = 0
        try db.query("PRAGMA user_version;", bind: { _ in }, row: { current = sqlite3_column_int($0, 0) })
        guard current != Self.dataPolicyVersion else { return }
        try db.exec("""
        DROP TABLE IF EXISTS conversations;
        DROP TABLE IF EXISTS conversations_fts;
        DROP TABLE IF EXISTS conversations_fts_uni;
        DROP TABLE IF EXISTS skipped_files;
        DROP TABLE IF EXISTS search_text;
        DROP TABLE IF EXISTS segments;
        DROP TABLE IF EXISTS segments_fts;
        DROP TABLE IF EXISTS segments_fts_uni;
        DROP TABLE IF EXISTS entities;
        DROP TABLE IF EXISTS conversation_entities;
        DROP TABLE IF EXISTS segments_fts_lex;
        DROP TABLE IF EXISTS lexicon;
        DROP TABLE IF EXISTS lexicon_meta;
        DROP TABLE IF EXISTS mcp_refs;
        DROP TABLE IF EXISTS user_corpus;
        DROP TABLE IF EXISTS milestone_candidates;
        DROP TABLE IF EXISTS decision_points;
        """)
        try db.exec(Self.schemaSQL)
        try db.exec("PRAGMA user_version = \(Self.dataPolicyVersion);")
        NSLog("[index] data policy %d -> %d — dropped & recreated tables, full rescan will rebuild",
              current, Self.dataPolicyVersion)
    }

    /// 查询侧词表缓存：连接生命周期内有效。App 进程在 `rebuildLexiconIfNeeded` 重建后
    /// 主动刷新；MCP 只读连接每次 tools/call 新开一个 `ConversationIndex` 实例，
    /// 天然拿到最新词表（见 `MCPServer` 的索引不缓存注释）。
    private var cachedLexicon: Set<String>?

    /// 当前词表（供 upsert/rankedHits 的查询侧切分、GUI 调试等用）。
    public func loadLexicon() -> Set<String> {
        // 注意：不能写 `try? queue.sync { ... }`——闭包本身不抛（`loadLexiconInsideQueue`
        // 内部已经 `try?` 吞掉了查库错误），`queue.sync` 会解析到非 throws 重载，
        // 外层再包 `try?` 是死代码（"no calls to throwing functions" 警告）。
        var words = Set<String>()
        queue.sync { words = loadLexiconInsideQueue() }
        return words
    }

    /// 同 `loadLexicon()`，但**必须已在 `queue` 上**——供 `rankedHits` 这类已经
    /// `queue.sync` 过的内部调用点使用，避免对串行队列重入自死锁（同 `liteRow` 的模式）。
    private func loadLexiconInsideQueue() -> Set<String> {
        if let cached = cachedLexicon { return cached }
        var words = Set<String>()
        try? db.query("SELECT word FROM lexicon;", row: { words.insert(SQLiteDB.text($0, 0)) })
        cachedLexicon = words
        return words
    }

    /// 批量取词表词在第三路索引里的文档频率（df）——供 `MindsBuilder` 的 VOCABULARY 节
    /// 按频次排序（spec 思脉底座 §2 第 4 节）。`lexicon` 表本身不存频次列，加一列是政策
    /// bump（DROP 重建全表），不值得为一个展示用途的排序付这个代价——现查 `vocab_lex`
    /// 是零 schema 变更的路径（同 `expansionTermsInsideQueue` 的 `SELECT doc FROM
    /// vocab_lex WHERE term = ?` 手法）。
    ///
    /// 一次 `queue.sync` 内循环点查，不是每个词各自 `queue.sync` 一次——词表 Top N 这个
    /// 调用量级下，重点是不让串行队列的排队开销摊到每一个词上（同 `upsert` 一批共用一次
    /// `queue.sync` 的理由）。
    ///
    /// `words` 逐个 `lowercased()` 后再查：`vocab_lex` 建在 `segments_fts_lex` 上，
    /// tokenizer 是 `unicode61 remove_diacritics 2`，默认做大小写折叠——查询侧不折叠，
    /// 纯英文词可能因大小写不一致而查不中（个人词表当前只从连续中文 run 抽词，这里对
    /// 中文是无害的 no-op，但函数签名不该预设"词表词只可能是中文"这条会变的假设）。
    ///
    /// 返回字典以**原始**（未小写化）的 `words` 元素为 key——调用方通常紧接着要把 df
    /// 关联回原词用于展示。查不到（df 为 0，理论上不该发生：词表词本就是从语料里数出来
    /// 的）的词不出现在返回字典里，调用方按"取不到当 0"处理。
    public func lexiconWordFrequencies(words: [String]) -> [String: Int] {
        var out: [String: Int] = [:]
        // 不能写 `try? queue.sync { ... }`——闭包内部已经用 `try?` 吞掉了每次查库的
        // 错误，闭包本身不抛，`queue.sync` 因此解析到非 throws 重载，外层再包 `try?`
        // 就是死代码（同 `loadLexicon()` 顶部注释踩过的同一个坑）。
        queue.sync {
            for word in words {
                var df = 0
                try? db.query("SELECT doc FROM vocab_lex WHERE term = ?;",
                              bind: { SQLiteDB.bindText($0, 1, word.lowercased()) },
                              row: { df = Int(sqlite3_column_int64($0, 0)) })
                if df > 0 { out[word] = df }
            }
        }
        return out
    }

    /// 「你点头的时刻」的全部原始素材。判据（学认可词、筛里程碑）在 Minds
    /// 构建层，这里只把素材原样取出来。
    public func milestoneCandidates() -> [MindsMilestones.Candidate] {
        var out: [MindsMilestones.Candidate] = []
        try? queue.sync {
            try db.query("SELECT approval, headline, at, message_id FROM milestone_candidates;",
                         bind: { _ in }, row: { st in
                let approval = String(cString: sqlite3_column_text(st, 0))
                let headline = sqlite3_column_text(st, 1).map { String(cString: $0) }
                out.append(.init(approval: approval, headline: headline,
                                 at: Date(timeIntervalSince1970: sqlite3_column_double(st, 2)),
                                 messageID: String(cString: sqlite3_column_text(st, 3))))
            })
        }
        return out
    }

    /// 里程碑素材 + 它属于哪场对话（跳回原文要用）。
    public func milestoneCandidatesWithConversation()
        -> [(candidate: MindsMilestones.Candidate, conversationID: String)] {
        var out: [(MindsMilestones.Candidate, String)] = []
        try? queue.sync {
            try db.query("""
                SELECT m.approval, m.headline, m.at, m.message_id, c.id
                FROM milestone_candidates m JOIN conversations c ON c.rowid = m.conv_rowid;
                """, bind: { _ in }, row: { st in
                let headline = sqlite3_column_text(st, 1).map { String(cString: $0) }
                out.append((.init(approval: String(cString: sqlite3_column_text(st, 0)),
                                  headline: headline,
                                  at: Date(timeIntervalSince1970: sqlite3_column_double(st, 2)),
                                  messageID: String(cString: sqlite3_column_text(st, 3))),
                            String(cString: sqlite3_column_text(st, 4))))
            })
        }
        return out.map { (candidate: $0.0, conversationID: $0.1) }
    }

    /// 「接着上次」:最近一场对话停在哪。
    ///
    /// 这是挖掘体系的**全覆盖底层**——十一条否定证明内容信号都有前提
    /// (跨项目/库龄/语言/习惯),而这一层只用结构不变量:任何一场对话
    /// 构造上必有最后一句和时间戳。于是整个体系成为全函数:
    /// 对任何 ≥1 场对话的库,挖掘非空;空库是唯一例外(没东西可挖,
    /// 返回 nil 而不是编造)。preview 存的本来就是最后一条消息的文字,
    /// open_question 是「它在等你什么」——三样拼起来就是接续点。
    public struct ResumePoint: Equatable, Sendable {
        public let id: String
        public let title: String
        public let preview: String
        public let cwd: String
        public let endAt: Date
        public let openQuestion: String?
        public init(id: String, title: String, preview: String, cwd: String,
                    endAt: Date, openQuestion: String?) {
            self.id = id; self.title = title; self.preview = preview
            self.cwd = cwd; self.endAt = endAt; self.openQuestion = openQuestion
        }
    }

    public func latestThread() -> ResumePoint? {
        var out: ResumePoint?
        try? queue.sync {
            try db.query("""
                SELECT id, COALESCE(title, ''), preview, cwd, end_at, open_question
                FROM conversations WHERE message_count > 0
                ORDER BY end_at DESC LIMIT 1;
                """, bind: { _ in }, row: { st in
                out = ResumePoint(
                    id: SQLiteDB.text(st, 0), title: SQLiteDB.text(st, 1),
                    preview: SQLiteDB.text(st, 2), cwd: SQLiteDB.text(st, 3),
                    endAt: Date(timeIntervalSince1970: sqlite3_column_double(st, 4)),
                    openQuestion: sqlite3_column_text(st, 5).map { String(cString: $0) })
            })
        }
        return out
    }

    /// 能力阶梯要的四个库统计。projects 数的是原始 cwd——各层的真实门槛
    /// (repeatedPhrases / contagion)数的就是它,阶梯必须与门槛同口径。
    public func libraryStats()
        -> (conversations: Int, projects: Int, daySpanDays: Int, longestConversation: Int) {
        var convs = 0, projects = 0, span = 0, longest = 0
        try? queue.sync {
            try db.query("""
                SELECT count(*), count(DISTINCT CASE WHEN cwd != '' THEN cwd END),
                       CAST((COALESCE(max(start_at),0) - COALESCE(min(start_at),0)) / 86400 AS INT),
                       COALESCE(max(message_count), 0)
                FROM conversations;
                """, bind: { _ in }, row: { st in
                convs = Int(sqlite3_column_int64(st, 0))
                projects = Int(sqlite3_column_int64(st, 1))
                span = Int(sqlite3_column_int64(st, 2))
                longest = Int(sqlite3_column_int64(st, 3))
            })
        }
        return (convs, projects, span, longest)
    }

    /// 词表词的文档频次（出现在多少场对话里）。判「这个词是不是库里到处都是」用。
    public func documentFrequencies() -> (df: [String: Int], total: Int) {
        var df: [String: Int] = [:]
        var total = 1
        try? queue.sync {
            try db.query("SELECT count(*) FROM conversations;", bind: { _ in },
                         row: { total = max(1, Int(sqlite3_column_int64($0, 0))) })
            try db.query("SELECT term, doc FROM vocab_lex;", bind: { _ in }, row: { st in
                df[String(cString: sqlite3_column_text(st, 0))] = Int(sqlite3_column_int64(st, 1))
            })
        }
        return (df, total)
    }

    /// 「你可能忘了的」：与当前这场相关、但已经久到你多半想不起来的旧对话。
    ///
    /// # 为什么是这个形状（第一性原理）
    ///
    /// 人会来翻自己的对话库，根本原因只有一个——**他想不起来了**。记得的
    /// 东西不需要查。所以
    ///
    ///     价值 = 「你想不起来」 × 「你现在需要它」
    ///
    /// 两项都能用算法逼近：前者用**时间**（久远 = 大概率忘了），后者用
    /// **相关性**（与你此刻在看的这场相关 = 大概率用得上）。
    ///
    /// 这也是它和这个库里其他挖掘的根本区别：那些都是**静态**的——把库统计
    /// 一遍摆出来，能不能撞上你需要的东西全看运气；这一层是**动态**的，
    /// query 来自你当下在看的对话。它因此不依赖任何交互习惯，
    /// 覆盖率不受「你说不说继续」的限制。
    ///
    /// 相关性直接用检索层（BM25 双路，已验证），不自己造相似度——
    /// 相似度判据在这个项目里失败过好几次，而检索是有评测背书的。
    public struct RelatedConversation: Equatable, Sendable {
        public let id: String
        public let title: String
        public let cwd: String
        public let daysAgo: Int
        public init(id: String, title: String, cwd: String, daysAgo: Int) {
            self.id = id; self.title = title; self.cwd = cwd; self.daysAgo = daysAgo
        }
    }

    /// 特征词取几个。太少了检索不稳，太多了会把这场对话的边缘话题也拉进来。
    static let relatedQueryTerms = 6

    /// 特征词的最高覆盖率。超过它说明这个词在库里到处都是，没有指向性。
    ///
    /// 定在 0.5 而不是更严：0.2 会把「评估方法」这类**中频但有指向**的词一起
    /// 砍掉，query 只剩「整个商圈或」这种长尾碎片，碎片在别的对话里根本不出现，
    /// 结果是零召回（2026-08-18 实测）。真正的把关交给下面的
    /// `relatedMinTermsHit`——宁可让通用词进 query，也不能让 query 只剩碎片。
    static let relatedMaxDF = 0.5

    /// 一条召回至少要命中几个特征词。命中一个词就推给你的话，
    /// 噪声比信号多——**宁可空着，也不要给不相关的**：这一层的前提是
    /// 「你想不起来的、但确实用得上的」，给错了就是在浪费你的注意力。
    static let relatedMinTermsHit = 2

    /// 每个特征词认几条命中。BM25 已经把最相关的排在前面，取前几条就等于
    /// 要求「这个词在那场对话里也重要」，而不只是出现过。
    static let relatedHitsPerTerm = 20


    public func forgottenRelated(to conversationID: String,
                                 olderThanDays: Int = 30,
                                 limit: Int = 3,
                                 now: Date = Date()) -> [RelatedConversation] {
        // ① 这场对话的特征词:用全局词表切出它说过的词,按 tf 取前几个。
        //    不在这里做 idf——BM25 自带 idf,通用词进了 query 也拿不到权重。
        var corpus = ""
        try? queue.sync {
            try db.query("""
                SELECT u.text FROM user_corpus u JOIN conversations c ON c.rowid = u.conv_rowid
                WHERE c.id = ?;
                """, bind: { SQLiteDB.bindText($0, 1, conversationID) },
                row: { corpus = String(cString: sqlite3_column_text($0, 0)) })
        }
        guard !corpus.isEmpty else { return [] }
        var tf: [String: Int] = [:]
        for w in loadLexicon() where w.count >= 2 {
            let n = corpus.components(separatedBy: w).count - 1
            if n > 0 { tf[w] = n }
        }
        // 词表还没建好时的回退:新装的库、刚导入的库都会走到这里,
        // 没有回退的话这个功能对新用户直接哑火。
        // 拉丁按空白切词,CJK 取二字组——够检索层用了。
        if tf.isEmpty {
            var latin = ""
            var cjk: [Character] = []
            func flushLatin() {
                if latin.count >= 3 { tf[latin.lowercased(), default: 0] += 1 }
                latin = ""
            }
            for ch in corpus {
                if ch.unicodeScalars.first.map({ (0x4E00...0x9FFF).contains($0.value) }) ?? false {
                    flushLatin()
                    cjk.append(ch)
                    if cjk.count >= 2 {
                        tf[String(cjk.suffix(2)), default: 0] += 1
                    }
                } else if ch.isLetter || ch.isNumber {
                    cjk = []
                    latin.append(ch)
                } else {
                    flushLatin(); cjk = []
                }
            }
            flushLatin()
        }
        // 选词必须按 **tf-idf**,不能只看 tf:高频词(项目/数据/方案)在每一场
        // 对话里 tf 都高,只看 tf 的话每场算出来的 query 几乎一样,召回自然
        // 也一样——真机现场就是所有对话都召回同样那几场超长旧对话。
        // 检索层的 idf 只影响排序,救不了选错的词。
        var df: [String: Int] = [:]
        var docTotal = 1
        try? queue.sync {
            try db.query("SELECT count(*) FROM conversations;", bind: { _ in },
                         row: { docTotal = max(1, Int(sqlite3_column_int64($0, 0))) })
            try db.query("SELECT term, doc FROM vocab_lex;", bind: { _ in }, row: { st in
                df[String(cString: sqlite3_column_text(st, 0))] = Int(sqlite3_column_int64(st, 1))
            })
        }
        let terms = tf.map { (w, n) -> (String, Double) in
            // 词表里没有的（回退切出来的）当作只在这一场出现过——它天然稀有
            let d = max(1, df[w] ?? 1)
            return (w, Double(n) * log(Double(docTotal) / Double(d)))
        }
        // 覆盖率超过这个比例的词直接不要:它在你库里到处都是,拿它当特征
        // 只会把「什么都沾一点」的对话捞上来（真机现场:「大概」「稍微」
        // 混进 query 之后,MacBook 迁移召回了三国游戏开发）。
        .filter { w, s in s > 0 && Double(df[w] ?? 1) / Double(docTotal) <= Self.relatedMaxDF }
        .sorted { $0.1 > $1.1 }
        .prefix(Self.relatedQueryTerms).map(\.0)
        guard !terms.isEmpty else { return [] }

        // ② 逐词检索再合并,按命中了几个词算相关度。
        //    不把词拼成一条 query:那是 AND 语义,只要有一个词在索引里不存在
        //    (回退切出来的碎片就会这样)整条查询就颗粒无收。
        //    每个词只认排名靠前的命中:超长对话几乎什么词都能匹配上,
        //    只数「有没有命中」的话它们会霸占所有召回位(真机现场:同一场
        //    116 天前的长对话同时出现在三个毫不相干项目的召回里)。
        //    取 top-K 相当于要求「这个词在这场对话里确实重要」,而不只是出现过。
        //    用倒数排名融合(RRF)而不是数命中个数:检索层已经把最相关的排在
        //    前面,只数「有没有命中」等于把这个信息扔掉——真机现场就是所有
        //    召回都塌成同样几场超长对话(它们什么词都能匹配上)。
        var score: [String: Double] = [:]
        var termsHit: [String: Int] = [:]
        for t in terms {
            for (rank, id) in search(t).prefix(Self.relatedHitsPerTerm).enumerated()
            where id != conversationID {
                score[id, default: 0] += 1.0 / (Self.rrfK + Double(rank))
                termsHit[id, default: 0] += 1
            }
        }
        let overlap = score.filter { (termsHit[$0.key] ?? 0) >= Self.relatedMinTermsHit }
        guard !overlap.isEmpty else { return [] }
        let cutoff = now.addingTimeInterval(-Double(olderThanDays) * 86400)
        let hits = Array(overlap.keys)
        var out: [RelatedConversation] = []
        try? queue.sync {
            for id in hits {
                try db.query("SELECT title, cwd, start_at FROM conversations WHERE id = ?;",
                             bind: { SQLiteDB.bindText($0, 1, id) },
                             row: { st in
                    let at = Date(timeIntervalSince1970: sqlite3_column_double(st, 2))
                    guard at < cutoff else { return }
                    out.append(RelatedConversation(
                        id: id,
                        title: sqlite3_column_text(st, 0).map { String(cString: $0) } ?? "",
                        cwd: sqlite3_column_text(st, 1).map { String(cString: $0) } ?? "",
                        daysAgo: max(0, Int(now.timeIntervalSince(at) / 86400))))
                })
            }
        }
        // 相关性主导排序，「久远」只作为**过滤**条件(≥olderThanDays)。
        // 反过来让久远主导的话,返回的永远是库里最老的那几场,跟你在看什么
        // 没关系了(第一版就是这个毛病)。最久远 ≠ 最该被想起。
        return Array(out.sorted {
            // 分数先量化再比:RRF 分数带着检索排名的细微差异,而那点差异
            // 常常是任意的(两场内容一样的对话谁排前谁排后取决于扫描顺序)。
            // 不量化的话「同样相关时更久远的优先」这条 tie-break 永远轮不到。
            let a = ((overlap[$0.id] ?? 0) * 100).rounded()
            let b = ((overlap[$1.id] ?? 0) * 100).rounded()
            return a != b ? a > b : $0.daysAgo > $1.daysAgo
        }.prefix(limit))
    }

    /// 某一场对话的目录素材：里程碑与拍板各自的（消息 id, 文本）。
    /// 判据照旧在调用方——认可词表要全局学，这里只按会话取素材。
    public func outlineMaterial(conversationID: String)
        -> (milestones: [(candidate: MindsMilestones.Candidate, messageID: String)],
            decisions: [(statement: String, messageID: String)]) {
        var stones: [(MindsMilestones.Candidate, String)] = []
        var calls: [(String, String)] = []
        try? queue.sync {
            try db.query("""
                SELECT m.approval, m.headline, m.at, m.message_id
                FROM milestone_candidates m JOIN conversations c ON c.rowid = m.conv_rowid
                WHERE c.id = ? AND m.headline IS NOT NULL AND m.message_id != '';
                """, bind: { SQLiteDB.bindText($0, 1, conversationID) },
                row: { st in
                stones.append((.init(approval: String(cString: sqlite3_column_text(st, 0)),
                                     headline: sqlite3_column_text(st, 1).map { String(cString: $0) },
                                     at: Date(timeIntervalSince1970: sqlite3_column_double(st, 2))),
                               String(cString: sqlite3_column_text(st, 3))))
            })
            try db.query("""
                SELECT d.statement, d.message_id
                FROM decision_points d JOIN conversations c ON c.rowid = d.conv_rowid
                WHERE c.id = ? AND d.message_id != '';
                """, bind: { SQLiteDB.bindText($0, 1, conversationID) },
                row: { st in
                calls.append((String(cString: sqlite3_column_text(st, 0)),
                              String(cString: sqlite3_column_text(st, 1))))
            })
        }
        return (stones.map { (candidate: $0.0, messageID: $0.1) },
                calls.map { (statement: $0.0, messageID: $0.1) })
    }

    /// 全库的里程碑素材（只为学认可词表用——判据要看过所有对话）。
    public func allMilestoneApprovals() -> Set<String> {
        MindsMilestones.learnApprovals(candidates: milestoneCandidates())
    }

    /// 里程碑素材 + 它属于哪个项目。返回素材而不是计数——认可词表要看过
    /// 全部对话才学得出来，判据只能在构建层做。
    public func milestoneCandidatesByProject()
        -> [(cwd: String, candidate: MindsMilestones.Candidate)] {
        var out: [(String, MindsMilestones.Candidate)] = []
        try? queue.sync {
            try db.query("""
                SELECT c.cwd, m.approval, m.headline, m.at
                FROM milestone_candidates m JOIN conversations c ON c.rowid = m.conv_rowid;
                """, bind: { _ in }, row: { st in
                let headline = sqlite3_column_text(st, 2).map { String(cString: $0) }
                out.append((sqlite3_column_text(st, 0).map { String(cString: $0) } ?? "",
                            .init(approval: String(cString: sqlite3_column_text(st, 1)),
                                  headline: headline,
                                  at: Date(timeIntervalSince1970: sqlite3_column_double(st, 3)))))
            })
        }
        return out.map { (cwd: $0.0, candidate: $0.1) }
    }

    /// 拍板素材 + 它属于哪场对话。
    public func decisionCandidatesWithConversation()
        -> [(candidate: MindsMilestones.DecisionCandidate, conversationID: String)] {
        var out: [(MindsMilestones.DecisionCandidate, String)] = []
        try? queue.sync {
            try db.query("""
                SELECT d.statement, d.at, d.message_id, c.id
                FROM decision_points d JOIN conversations c ON c.rowid = d.conv_rowid;
                """, bind: { _ in }, row: { st in
                out.append((.init(statement: String(cString: sqlite3_column_text(st, 0)),
                                  at: Date(timeIntervalSince1970: sqlite3_column_double(st, 1)),
                                  messageID: String(cString: sqlite3_column_text(st, 2))),
                            String(cString: sqlite3_column_text(st, 3))))
            })
        }
        return out.map { (candidate: $0.0, conversationID: $0.1) }
    }

    /// 「你拍板的时刻」的全部原始素材。
    public func decisionCandidates() -> [MindsMilestones.DecisionCandidate] {
        var out: [MindsMilestones.DecisionCandidate] = []
        try? queue.sync {
            try db.query("SELECT statement, at, message_id FROM decision_points;",
                         bind: { _ in }, row: { st in
                out.append(.init(statement: String(cString: sqlite3_column_text(st, 0)),
                                 at: Date(timeIntervalSince1970: sqlite3_column_double(st, 1)),
                                 messageID: String(cString: sqlite3_column_text(st, 2))))
            })
        }
        return out
    }

    /// 全部会话的用户语料（user_corpus.text，跳过空串）。供 Minds 概念地图按
    /// 「你说的话」数频次——检索词表继续用全语料（AI 输出也要能搜到），两个口径
    /// 各管各的，见 schemaSQL 里 user_corpus 的建表注释。
    /// 量级：user 文本通常只占全语料的个位数百分比（对话以 AI 输出为主），
    /// 千级会话拉进内存在 MB 量级，不做流式。
    public func userCorpusTexts() -> [String] {
        var out: [String] = []
        queue.sync {
            try? db.query("SELECT text FROM user_corpus WHERE text != '';",
                          bind: { _ in },
                          row: { stmt in
                if let c = sqlite3_column_text(stmt, 0) { out.append(String(cString: c)) }
            })
        }
        return out
    }

    /// 词在 `vocab_uni`/`vocab_lex` 两路第三方索引里的文档频率（df），取两表 **max**——
    /// 与 `expansionTermsInsideQueue` 内联查两表取 max 的口径完全一致（那里没有独立成
    /// 公开方法，是因为它紧跟着候选抽取与排序，抽出来反而要多传几个参数）；这里单独
    /// 提炼成公开方法，供 `BenchDataset`（设计说明 评测集分带：query 与答案会话全文
    /// 的低频词重叠数）复用同一 df 口径——评测「低频」的标准必须与生产代码判断「值不值得
    /// 当扩展词」的标准一致，否则分带数字与检索行为对不上号。
    ///
    /// 与 `lexiconWordFrequencies` 的区别：那个只查 `vocab_lex`（个人词表路，供词表展示
    /// 排序用）；这个两路都查，语义是「这个词元在索引里到底有多常见」，不预设它来自
    /// 中文词表还是英文 unicode61 切分——`expansionTermsInsideQueue` 处理 CJK 候选词时
    /// 正是因为「vocab_uni 对未切分的连续 CJK run 只给一个巨长 token」才必须两路都查
    /// 取 max（见该方法内的注释），这里原样复用同一理由。
    ///
    /// `terms` 逐个 `lowercased()` 后再查（同 `lexiconWordFrequencies`：两张 vocab 表的
    /// tokenizer 都做大小写折叠）；返回字典以**原始**（未小写化）的 `terms` 元素为 key。
    /// 查不到（df 为 0）的词不出现在返回字典里，调用方按"取不到当 0"处理。
    public func documentFrequencies(terms: [String]) -> [String: Int] {
        var out: [String: Int] = [:]
        queue.sync {
            for term in terms {
                let lower = term.lowercased()
                var dfUni = 0, dfLex = 0
                try? db.query("SELECT doc FROM vocab_uni WHERE term = ?;",
                              bind: { SQLiteDB.bindText($0, 1, lower) },
                              row: { dfUni = Int(sqlite3_column_int64($0, 0)) })
                try? db.query("SELECT doc FROM vocab_lex WHERE term = ?;",
                              bind: { SQLiteDB.bindText($0, 1, lower) },
                              row: { dfLex = Int(sqlite3_column_int64($0, 0)) })
                let df = max(dfUni, dfLex)
                if df > 0 { out[term] = df }
            }
        }
        return out
    }

    /// `segments_fts_lex` 的行数——测试与调试用（行数守恒是哨兵红线，见 `scripts/audit-index.sh`）。
    public func lexRouteRowCount() -> Int {
        var n = 0
        try? queue.sync {
            try db.query("SELECT COUNT(*) FROM segments_fts_lex;", row: { n = Int(sqlite3_column_int64($0, 0)) })
        }
        return n
    }

    /// `segments_fts_lex` 里 MATCH 到 `match` 的行数——测试用，直接锁「索引侧真的按
    /// 词表切分写入了」：整词 MATCH（如 `"库存经理"`）在 unicode61 tokenizer 下只有
    /// 索引侧真把该词切成独立词元才对得上；若写入的是未切分原文，长 CJK run 会被
    /// unicode61 粘成一个巨长词元，整词 MATCH 必为 0（同 `upsertOne` 里关于退化切分
    /// 的注释）。`match` 直接透传给 MATCH 子句，调用方负责加引号构造短语查询。
    public func lexRouteMatchCount(_ match: String) -> Int {
        var n = 0
        try? queue.sync {
            try db.query("SELECT COUNT(*) FROM segments_fts_lex WHERE segments_fts_lex MATCH ?;",
                         bind: { SQLiteDB.bindText($0, 1, match) },
                         row: { n = Int(sqlite3_column_int64($0, 0)) })
        }
        return n
    }

    /// 词表为空或语料字符数比上次构建时涨 >20% 时：重算词表并整体重灌第三路。
    /// 挂在扫描收尾（`LoaderRuntime.indexAllSources`），5000 段量级重灌是秒级。
    ///
    /// 「建过没有」用 `lexicon_meta` 是否有行判断，不能用 `lexicon` 表行数——纯英文语料
    /// 合法产出空词表（`PersonalLexicon.build` 只从连续中文 run 里找候选），空表与
    /// 「从未构建过」在行数上无法区分；若拿 `lexicon` 行数当判据，纯英文用户会在
    /// 语料完全没涨的情况下被每轮扫描都判成「没建过」，从而每次都重新做一遍全库统计 +
    /// 整表重灌。`lexicon_meta` 一旦写入就必然带着 `corpusChars > 0`（写入前有
    /// `guard corpusChars > 0` 守卫），所以下面 `lastChars == 0` 单独就能准确表示
    /// 「从未成功构建过」，不需要再查 `lexicon` 表存在性。
    @discardableResult
    public func rebuildLexiconIfNeeded() -> Bool {
        var rebuilt = false
        try? queue.sync {
            // 先用 SQL 聚合做**廉价预判**，确认要重建才物化全库文本——此前每轮扫描
            // 收尾都把 5000+ 段拷进内存（实测约 40MB 瞬时分配）只为算一个字符数。
            // SQLite 的 LENGTH 按 Unicode 码点数、Swift 的 .count 按 grapheme 数，
            // 两者对 emoji 有轻微偏差——预判只是「涨没涨 20%」的粗筛，写进 meta 的
            // 仍是物化后的真实 .count（口径与历史值一致），偏差不会累积。
            var approxChars = 0
            try db.query("SELECT COALESCE(SUM(LENGTH(text)), 0) FROM segments;",
                         row: { approxChars = Int(sqlite3_column_int64($0, 0)) })
            var lastChars = 0
            try db.query("SELECT corpus_chars FROM lexicon_meta WHERE id = 1;",
                         row: { lastChars = Int(sqlite3_column_int64($0, 0)) })
            let maybeGrown = lastChars == 0 || Double(approxChars) > Double(lastChars) * 1.2
            guard maybeGrown, approxChars > 0 else { return }

            var corpusChars = 0
            var segs: [(rowid: Int64, text: String)] = []
            try db.query("SELECT rowid, text FROM segments;", row: { st in
                let rowid = sqlite3_column_int64(st, 0)
                let t = SQLiteDB.text(st, 1)
                segs.append((rowid, t))
                corpusChars += t.count
            })
            // 码点/grapheme 口径差可能让预判假阳性——物化后按真实 .count 再确认一次
            let grown = lastChars == 0 || Double(corpusChars) > Double(lastChars) * 1.2
            guard grown, corpusChars > 0 else { return }

            let lexicon = PersonalLexicon.build(corpus: segs.map(\.text))
            try db.transaction {
                try db.exec("DELETE FROM lexicon;")
                for word in lexicon {
                    try db.run("INSERT INTO lexicon(word) VALUES (?);",
                               bind: { SQLiteDB.bindText($0, 1, word) })
                }
                try db.run("""
                INSERT INTO lexicon_meta(id, corpus_chars, built_at) VALUES (1, ?, ?)
                ON CONFLICT(id) DO UPDATE SET corpus_chars = excluded.corpus_chars,
                                              built_at = excluded.built_at;
                """, bind: { st in
                    sqlite3_bind_int64(st, 1, Int64(corpusChars))
                    sqlite3_bind_double(st, 2, Date().timeIntervalSince1970)
                })
                // 整表重灌：contentless 全删后按物化好的 (rowid, text) 数组逐行切分重插——
                // 不在遍历 SELECT 的 row 回调里嵌套 INSERT 同一连接（同连接遍历同时写在
                // WAL 下允许，但不是文档保证的稳定契约）；先把 segments 物化成数组，
                // 行为确定，不用赌 SQLite 实现细节（5000 段量级的数组是毫秒级、内存可忽略）。
                try db.exec("INSERT INTO segments_fts_lex(segments_fts_lex) VALUES('delete-all');")
                for (rowid, text) in segs {
                    let segmented = PersonalLexicon.segment(text, lexicon: lexicon)
                    try db.run("INSERT INTO segments_fts_lex(rowid, text) VALUES (?, ?);",
                               bind: { s2 in
                        sqlite3_bind_int64(s2, 1, rowid)
                        SQLiteDB.bindText(s2, 2, segmented)
                    })
                }
            }
            cachedLexicon = lexicon
            rebuilt = true
            NSLog("[lexicon] rebuilt: %d words from %d chars", lexicon.count, corpusChars)
        }
        return rebuilt
    }

    // MARK: - MCP 引用回流（第5步/§2.2）

    /// 汇入 `MCPRefLog` 写的 jsonl：读全文件按行聚合出 `[conv_id: (count, lastTs)]`，
    /// 事务里 `DELETE FROM mcp_refs` 后全量重插——不是增量累加。
    ///
    /// 为什么必须全量重算而不是增量累加：日志文件本身「不删不截断」（架构红线，
    /// 见 `MCPRefLog` 顶部注释），而这个方法每次扫描收尾都会被整个调用一次
    /// （`LoaderRuntime.indexAllSources`）——若按「新读到的行」增量累加计数，
    /// 同一批已经计过数的行会在下一次扫描时被重新数一遍，计数随扫描次数线性
    /// 虚增。全量重算（先清表再按当前文件从头聚合一遍）天然幂等：文件内容不变，
    /// 结果就不变，调用几次都一样。
    ///
    /// 坏行（半截 JSON、空行、缺字段、类型不对）逐行跳过，不让一行脏数据拖垮
    /// 整批聚合——引用记录是「丢一条无所谓」的统计数据，不是索引主数据。
    ///
    /// 文件不存在 → `counts` 保持空，仍会执行 `DELETE FROM mcp_refs`，结果是
    /// 表被清空而不是报错——约定「无日志＝无引用」（比如 MCP 从未被调用过，
    /// 或只调用过 `memory_search` 还没有 `memory_open` 记录）。
    ///
    /// 性能：整文件读进内存后按行 `split`（不是 `components(separatedBy:)`——
    /// 前者返回 `[Substring]`，是原字符串的视图，不逐行拷贝；后者返回 `[String]`，
    /// 每行都要一次新分配）。引用日志量级小（设计说明 估算：一人一天检索几十次，
    /// 十年 <10MB），整文件读入内存与逐行 `JSONSerialization` 都在毫秒级，
    /// 这个量级不需要为此做流式读取。
    public func ingestRefLog(from url: URL) {
        var counts: [String: (count: Int, lastTs: Double)] = [:]
        if let data = FileManager.default.contents(atPath: url.path) {
            // `String(decoding:as:)` 是**不可失败**的有损解码：坏字节退化成 U+FFFD、
            // 只让所在那一行的 JSON 解析失败被 continue 跳过。此前用可失败的
            // `String(data:encoding:)`——崩溃截断留下的**一个**非法 UTF-8 字节会让
            // 整个文件解码为 nil → counts 为空 → 下面照样 DELETE 重插 → 聚合表清空；
            // 而日志 append-only 永不修复，此后每轮 ingest 都再清一次，全部引用
            // 历史**永久**归零。「坏行跳过」的韧性必须建立在不可失败的解码上。
            let text = String(decoding: data, as: UTF8.self)
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                // NSNumber.doubleValue 而不是直接 `as? Double`：JSONSerialization
                // 把整数字面量（无小数点）解析成整型存储的 NSNumber，Swift 的
                // `as? Double` 动态转换在这种情况下并不总能命中；`.doubleValue`
                // 不管底层是整型还是浮点存储都能正确转换。
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let convID = obj["conv_id"] as? String,
                      let ts = (obj["ts"] as? NSNumber)?.doubleValue else { continue }
                var entry = counts[convID] ?? (count: 0, lastTs: 0)
                entry.count += 1
                entry.lastTs = max(entry.lastTs, ts)
                counts[convID] = entry
            }
        }
        try? queue.sync {
            try db.transaction {
                try db.exec("DELETE FROM mcp_refs;")
                for (id, agg) in counts {
                    try db.run("INSERT INTO mcp_refs(conv_id, ref_count, last_ref) VALUES (?, ?, ?);",
                               bind: { s in
                        SQLiteDB.bindText(s, 1, id)
                        sqlite3_bind_int64(s, 2, Int64(agg.count))
                        sqlite3_bind_double(s, 3, agg.lastTs)
                    })
                }
            }
        }
    }

    /// 该会话被 `memory_open` 读取过的次数与最近一次时间。**本轮只记录不进排序**
    /// （明言观察期，排序权重无实测支撑）——接口是给未来 GUI 徽章
    /// （「被 Claude Code 引用过 3 次」）与 §7.66 回声判定用的查询入口。
    public func refCount(forID id: String) -> (count: Int, last: Date)? {
        var out: (count: Int, last: Date)?
        try? queue.sync {
            try db.query("SELECT ref_count, last_ref FROM mcp_refs WHERE conv_id = ?;",
                         bind: { SQLiteDB.bindText($0, 1, id) },
                         row: { st in
                out = (count: Int(sqlite3_column_int64(st, 0)),
                       last: Date(timeIntervalSince1970: sqlite3_column_double(st, 1)))
            })
        }
        return out
    }

    /// 全部引用计数一次取回——GUI 列表几百行逐行点查太浪费,mcp_refs 全表本就极小。
    public func allRefCounts() -> [String: Int] {
        var out: [String: Int] = [:]
        try? queue.sync {
            try db.query("SELECT conv_id, ref_count FROM mcp_refs;", row: { st in
                out[SQLiteDB.text(st, 0)] = Int(sqlite3_column_int64(st, 1))
            })
        }
        return out
    }

    /// 被引用过的会话，按引用次数降序——供 `MindsBuilder` 的 AGENT USAGE 节（思脉底座
    /// 设计说明：总次数/Top 被引会话）。与 `refCount(forID:)` 同一张表
    /// （`mcp_refs`），那边是"给定一个会话 id 反查"，这里是"给整张表排个名"，两种查询
    /// 形状不同、没有代码好共用。
    ///
    /// 常规查询：单层 `queue.sync`，不嵌套（同 `topEntities`/`refCount` 的模式，
    /// 调用方不在已持锁的上下文里调这个方法）。`limit` 传 `Int.max` 表达"不限"时用
    /// `Int32(clamping:)` 钳到 `Int32.max`——同 `conversationIDs(for:limit:)`，裸
    /// `Int32(limit)` 转换在这个值上会运行时陷阱、整个进程 abort。
    ///
    /// 并列名次（相同 `ref_count`）按 `last_ref` 降序稳定排——最近还在被引用的排前面，
    /// 比任意顺序更有信息量，且让重复调用在数据不变时给出确定的顺序。
    public func topReferenced(limit: Int) -> [(id: String, count: Int, last: Date)] {
        var out: [(id: String, count: Int, last: Date)] = []
        try? queue.sync {
            try db.query("""
            SELECT conv_id, ref_count, last_ref FROM mcp_refs
            ORDER BY ref_count DESC, last_ref DESC LIMIT ?;
            """, bind: { sqlite3_bind_int($0, 1, Int32(clamping: max(0, limit))) },
                 row: { st in
                out.append((id: SQLiteDB.text(st, 0), count: Int(sqlite3_column_int64(st, 1)),
                            last: Date(timeIntervalSince1970: sqlite3_column_double(st, 2))))
            })
        }
        return out
    }

    /// 批量 upsert：(瘦身 lite, 段数组, mtime, 实体抽取专用文本)。按 file_path 去重；
    /// 一条对话对应多条 segments 行，fts rowid 对齐 segments.rowid
    /// （不再对齐 conversations.rowid——一会话多段之后不可能再 1:1）。
    /// 批内单条容错：同 id 不同 path（用户 cp 备份过 jsonl）预查重跳过；
    /// 其余单条失败用 SAVEPOINT 回滚该条，不拖垮整批（曾经 UNIQUE 冲突整批回滚 8 条陪葬）。
    ///
    /// `entityText`：调用方须传 `Segmenter.entityText(of: conv.messages)`，而不是拿
    /// `segments` 拼出来的检索文本兜底——两者口径故意不同（`entityText` 排除 `.toolUse`，
    /// 见 `Segmenter.entityText` 注释），这里单独接收一个字段就是为了不让调用方图省事
    /// 传错口径。segments 仍然要传，供写 segments/fts 表用，两者服务不同的表。
    ///
    /// 返回被「同 id 不同 path」跳过的 (path, mtime)：调用方（LoaderRuntime）应把它们
    /// markSkipped——否则副本文件的 mtime 永远不入库，每轮扫描都白解析一遍再跳过。
    /// 4 元重载：既有调用方（全部测试）不带 userText——转发传空串，
    /// user_corpus 仍写行（空串），行数守恒不因调用口径而破。
    /// 6 元重载：不带里程碑素材的调用方（既有测试）——转发传空数组。
    /// 素材缺失只让「你点头的时刻」这一项为空，不影响别的产物。
    @discardableResult
    public func upsert(_ rows: [(lite: ConversationLite, segments: [Segmenter.Segment], mtime: Double, entityText: String, userText: String, lastRole: String)]) throws
        -> [(path: String, mtime: Double)] {
        try upsert(rows.map { (lite: $0.lite, segments: $0.segments, mtime: $0.mtime,
                               entityText: $0.entityText, userText: $0.userText,
                               lastRole: $0.lastRole, harvest: .init()) })
    }

    @discardableResult
    public func upsert(_ rows: [(lite: ConversationLite, segments: [Segmenter.Segment], mtime: Double, entityText: String)]) throws
        -> [(path: String, mtime: Double)] {
        try upsert(rows.map { (lite: $0.lite, segments: $0.segments, mtime: $0.mtime,
                               entityText: $0.entityText, userText: "", lastRole: "",
                               harvest: .init()) })
    }

    @discardableResult
    public func upsert(_ rows: [(lite: ConversationLite, segments: [Segmenter.Segment], mtime: Double, entityText: String, userText: String, lastRole: String, harvest: MindsMilestones.Harvest)]) throws
        -> [(path: String, mtime: Double)] {
        var duplicates: [(path: String, mtime: Double)] = []
        try queue.sync {
            // 一批共用同一份词表快照——避免每段循环里各查一次库；批内不会有
            // rebuildLexiconIfNeeded 并发穿插（两者共用同一 queue，串行互斥）。
            let lexicon = loadLexiconInsideQueue()
            try db.transaction {
                for it in rows {
                    let l = it.lite
                    // id 已被另一个 file_path 占用（同一对话的副本文件）→ 跳过新文件，保留已索引那份
                    var existingPath: String?
                    try db.query("SELECT file_path FROM conversations WHERE id = ?;",
                                 bind: { SQLiteDB.bindText($0, 1, l.id) },
                                 row: { existingPath = SQLiteDB.text($0, 0) })
                    if let ep = existingPath, ep != l.fileURL.path {
                        NSLog("[index] skip duplicate conversation id=%@ at %@ (already indexed from %@)",
                              l.id, l.fileURL.lastPathComponent, (ep as NSString).lastPathComponent)
                        duplicates.append((l.fileURL.path, it.mtime))
                        continue
                    }
                    do {
                        try db.exec("SAVEPOINT upsert_one;")
                        try upsertOne(it, lexicon: lexicon)
                        try db.exec("RELEASE upsert_one;")
                    } catch {
                        try? db.exec("ROLLBACK TO upsert_one;")
                        try? db.exec("RELEASE upsert_one;")
                        NSLog("[index] upsert failed for %@: %@",
                              l.fileURL.lastPathComponent, String(describing: error))
                    }
                }
            }
        }
        return duplicates
    }

    /// 单条 upsert（调用方保证在 queue + transaction 内）。`lexicon`：本批共用的词表快照，
    /// 供第三路切分用（见 `upsert` 里 `loadLexiconInsideQueue()` 的注释）。
    private func upsertOne(_ it: (lite: ConversationLite, segments: [Segmenter.Segment], mtime: Double, entityText: String, userText: String, lastRole: String, harvest: MindsMilestones.Harvest),
                            lexicon: Set<String>) throws {
        let l = it.lite
        // 先删旧（含该会话的段与三路 fts），再插，保证幂等——否则重扫会让段随每次重扫翻倍
        var oldRowid: Int64?
        try db.query("SELECT rowid FROM conversations WHERE file_path = ?;",
                     bind: { SQLiteDB.bindText($0, 1, l.fileURL.path) },
                     row: { oldRowid = sqlite3_column_int64($0, 0) })
        if let rid = oldRowid {
            // contentless FTS 的删除写法是 DELETE FROM ... WHERE rowid = ?（或 IN 子查询），
            // 不是 'delete' 特殊命令——那是给外部 content 表用的，contentless 表上会直接报错。
            try db.run("DELETE FROM segments_fts WHERE rowid IN (SELECT rowid FROM segments WHERE conv_rowid = ?);",
                       bind: { sqlite3_bind_int64($0, 1, rid) })
            try db.run("DELETE FROM segments_fts_uni WHERE rowid IN (SELECT rowid FROM segments WHERE conv_rowid = ?);",
                       bind: { sqlite3_bind_int64($0, 1, rid) })
            try db.run("DELETE FROM segments_fts_lex WHERE rowid IN (SELECT rowid FROM segments WHERE conv_rowid = ?);",
                       bind: { sqlite3_bind_int64($0, 1, rid) })
            try db.run("DELETE FROM segments WHERE conv_rowid = ?;",
                       bind: { sqlite3_bind_int64($0, 1, rid) })
            // 实体关联也是子表，必须在删主行之前删掉——新行插入后拿到的 rowid
            // 不保证等于这个旧 rid（SQLite 复用的是全表当前最大 rowid+1，不是
            // 本会话原来的号），所以不能指望后面「按新 rowid 删一次」能连带清掉它。
            try db.run("DELETE FROM conversation_entities WHERE conv_rowid = ?;",
                       bind: { sqlite3_bind_int64($0, 1, rid) })
            try db.run("DELETE FROM milestone_candidates WHERE conv_rowid = ?;",
                       bind: { sqlite3_bind_int64($0, 1, rid) })
            try db.run("DELETE FROM decision_points WHERE conv_rowid = ?;",
                       bind: { sqlite3_bind_int64($0, 1, rid) })
            try db.run("DELETE FROM user_corpus WHERE conv_rowid = ?;",
                       bind: { sqlite3_bind_int64($0, 1, rid) })
            try db.run("DELETE FROM conversations WHERE rowid = ?;",
                       bind: { sqlite3_bind_int64($0, 1, rid) })
        }
        try db.run("""
        INSERT INTO conversations (id, source, start_at, end_at, cwd, git_branch, title, preview, message_count, file_path, mtime, last_role, open_question)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
        """, bind: { s in
            SQLiteDB.bindText(s, 1, l.id)
            SQLiteDB.bindText(s, 2, l.source.rawValue)
            sqlite3_bind_double(s, 3, l.startAt.timeIntervalSince1970)
            sqlite3_bind_double(s, 4, l.endAt.timeIntervalSince1970)
            SQLiteDB.bindText(s, 5, l.cwd)
            if let b = l.gitBranch { SQLiteDB.bindText(s, 6, b) } else { sqlite3_bind_null(s, 6) }
            if let t = l.title { SQLiteDB.bindText(s, 7, t) } else { sqlite3_bind_null(s, 7) }
            SQLiteDB.bindText(s, 8, l.preview)
            sqlite3_bind_int64(s, 9, Int64(l.messageCount))
            SQLiteDB.bindText(s, 10, l.fileURL.path)
            sqlite3_bind_double(s, 11, it.mtime)
            SQLiteDB.bindText(s, 12, it.lastRole)
            if let q = it.harvest.openQuestion, !q.isEmpty {
                // 尾句（问句在末尾）截断保留后 200 字：英文句子以 . 结尾不在句末标点集合里时，
                // trailingQuestion 会返回整段，取前缀就把问句本身切掉了
                SQLiteDB.bindText(s, 13, String(q.suffix(200)))
            } else { sqlite3_bind_null(s, 13) }
        })
        // 用 last_insert_rowid 取代「INSERT 完再 SELECT 查回来」，每条省一次查询
        let newRowid = db.lastInsertRowid
        // 用户语料：空串也写行（4 元重载转发就是空串）——行数守恒（user_corpus 行数
        // 恒等于 conversations 行数），哨兵与删除路径不必特判「有没有 user 文本」。
        try db.run("INSERT INTO user_corpus(conv_rowid, text) VALUES(?, ?);",
                   bind: { s in
            sqlite3_bind_int64(s, 1, newRowid)
            SQLiteDB.bindText(s, 2, it.userText)
        })
        for d in it.harvest.decisions {
            try db.run("""
                INSERT INTO decision_points(conv_rowid, statement, at, message_id)
                VALUES(?,?,?,?);
                """, bind: { s in
                sqlite3_bind_int64(s, 1, newRowid)
                SQLiteDB.bindText(s, 2, d.statement)
                sqlite3_bind_double(s, 3, d.at.timeIntervalSince1970)
                SQLiteDB.bindText(s, 4, d.messageID)
            })
        }
        for c in it.harvest.milestones {
            try db.run("""
                INSERT INTO milestone_candidates(conv_rowid, approval, headline, at, message_id)
                VALUES(?,?,?,?,?);
                """, bind: { s in
                sqlite3_bind_int64(s, 1, newRowid)
                SQLiteDB.bindText(s, 2, c.approval)
                if let h = c.headline {
                    SQLiteDB.bindText(s, 3, h)
                } else { sqlite3_bind_null(s, 3) }
                sqlite3_bind_double(s, 4, c.at.timeIntervalSince1970)
                SQLiteDB.bindText(s, 5, c.messageID)
            })
        }
        for seg in it.segments {
            try db.run("INSERT INTO segments(conv_rowid, first_msg, last_msg, text) VALUES(?,?,?,?);",
                       bind: { s in
                sqlite3_bind_int64(s, 1, newRowid)
                sqlite3_bind_int64(s, 2, Int64(seg.firstMessageIndex))
                sqlite3_bind_int64(s, 3, Int64(seg.lastMessageIndex))
                SQLiteDB.bindText(s, 4, seg.text)
            })
            let segRowid = db.lastInsertRowid
            try db.run("INSERT INTO segments_fts(rowid, text) VALUES(?, ?);",
                       bind: { s in
                sqlite3_bind_int64(s, 1, segRowid)
                SQLiteDB.bindText(s, 2, seg.text)
            })
            try db.run("INSERT INTO segments_fts_uni(rowid, text) VALUES(?, ?);",
                       bind: { s in
                sqlite3_bind_int64(s, 1, segRowid)
                SQLiteDB.bindText(s, 2, seg.text)
            })
            // 第三路：词表切分后入索引。词表为空时切分退化成按单字断词（unicode61
            // 遇到空格才断词，中文本身不含空格，不切分会让一整段中文粘成一个巨长
            // token，查询永远匹配不上）——检索上没有词级增益，但行数守恒，删除路径
            // 与哨兵不必为「词表是否已构建」特判。
            let lexSegmented = PersonalLexicon.segment(seg.text, lexicon: lexicon)
            try db.run("INSERT INTO segments_fts_lex(rowid, text) VALUES(?, ?);",
                       bind: { s in
                sqlite3_bind_int64(s, 1, segRowid)
                SQLiteDB.bindText(s, 2, lexSegmented)
            })
        }
        // 实体：每会话抽一次，不是每段一次——同一实体在会话内出现多次只该记一条关联，
        // 「出现在几个会话」才是导航要的计数口径。
        // 这里按新 rowid 再清一次纯属防御性兜底（正常情况下新 rowid 不会已有关联，
        // 除非 SQLite 复用了某个刚被删且未清理干净的旧 rowid）；真正的「换掉旧关联」
        // 靠上面 oldRowid 分支按旧 rid 删——这里删的是 newRowid，两者未必是同一个号。
        try db.run("DELETE FROM conversation_entities WHERE conv_rowid = ?;",
                   bind: { sqlite3_bind_int64($0, 1, newRowid) })
        // 用调用方传入的专用口径（排除 .toolUse），不是拿 segments 的检索文本兜底——
        // 见 upsert 与 Segmenter.entityText 的注释。
        for e in EntityExtractor.extract(from: it.entityText) {
            try db.run("INSERT OR IGNORE INTO entities(text, kind) VALUES(?, ?);", bind: { st in
                SQLiteDB.bindText(st, 1, e.text)
                SQLiteDB.bindText(st, 2, e.kind.rawValue)
            })
            try db.run("""
            INSERT OR IGNORE INTO conversation_entities(conv_rowid, entity_rowid)
            SELECT ?, rowid FROM entities WHERE text = ? AND kind = ?;
            """, bind: { st in
                sqlite3_bind_int64(st, 1, newRowid)
                SQLiteDB.bindText(st, 2, e.text)
                SQLiteDB.bindText(st, 3, e.kind.rawValue)
            })
        }
    }

    /// 段总数。供测试断言「重入库要换段、不要叠加」。
    public func segmentCount() -> Int {
        var n = 0
        try? queue.sync {
            try db.query("SELECT count(*) FROM segments;", row: { n = Int(sqlite3_column_int($0, 0)) })
        }
        return n
    }

    public func summary() -> (count: Int, sources: Int, latest: Date?) {
        var count = 0, sources = 0; var latest: Double?
        try? queue.sync {
            try db.query("SELECT COUNT(*), COUNT(DISTINCT source), MAX(end_at) FROM conversations;", row: { s in
                count = Int(sqlite3_column_int64(s, 0))
                sources = Int(sqlite3_column_int64(s, 1))
                if sqlite3_column_type(s, 2) != SQLITE_NULL { latest = sqlite3_column_double(s, 2) }
            })
        }
        return (count, sources, latest.map { Date(timeIntervalSince1970: $0) })
    }

    /// 索引内容指纹：Minds 重建的「零变化短路」依据——任何一项变了就重建，全同则跳过。
    /// 只用行数 / 最大 mtime / 消息总数这类聚合，不扫正文，稳态一次几毫秒。
    public func changeFingerprint() -> String {
        var parts: [String] = []
        try? queue.sync {
            try db.query("SELECT COUNT(*), COALESCE(MAX(mtime), 0), COALESCE(SUM(message_count), 0) FROM conversations;",
                         row: { s in
                parts.append("c\(sqlite3_column_int64(s, 0))")
                parts.append("m\(sqlite3_column_double(s, 1))")
                parts.append("n\(sqlite3_column_int64(s, 2))")
            })
            try db.query("SELECT COUNT(*), COALESCE(SUM(length(word)), 0) FROM lexicon;", row: { s in
                parts.append("l\(sqlite3_column_int64(s, 0))/\(sqlite3_column_int64(s, 1))")
            })
            for t in ["segments", "user_corpus", "milestone_candidates", "decision_points", "mcp_refs", "entities"] {
                try db.query("SELECT COUNT(*) FROM \(t);", row: { s in
                    parts.append("\(t)\(sqlite3_column_int64(s, 0))")
                })
            }
        }
        return parts.joined(separator: "|")
    }

    /// 从 `SELECT id, source, start_at, end_at, cwd, git_branch, title, preview, message_count, file_path`
    /// 的结果行造 `ConversationLite`。列序即上面那一串，改一处必改所有 SQL。
    private static let liteColumns =
        "id, source, start_at, end_at, cwd, git_branch, title, preview, message_count, file_path"

    private static func lite(from s: OpaquePointer?) -> ConversationLite {
        let gb = sqlite3_column_type(s, 5) == SQLITE_NULL ? nil : SQLiteDB.text(s, 5)
        let title = sqlite3_column_type(s, 6) == SQLITE_NULL ? nil : SQLiteDB.text(s, 6)
        return ConversationLite(
            id: SQLiteDB.text(s, 0),
            source: ConversationSource(rawValue: SQLiteDB.text(s, 1)) ?? .claudeCode,
            startAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 2)),
            endAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 3)),
            cwd: SQLiteDB.text(s, 4), gitBranch: gb, title: title,
            preview: SQLiteDB.text(s, 7),
            messageCount: Int(sqlite3_column_int64(s, 8)),
            fileURL: URL(fileURLWithPath: SQLiteDB.text(s, 9)))
    }

    public func allMetadata() -> [ConversationLite] {
        var out: [ConversationLite] = []
        try? queue.sync {
            try db.query("SELECT \(Self.liteColumns) FROM conversations ORDER BY end_at DESC;",
                         row: { out.append(Self.lite(from: $0)) })
        }
        return out
    }

    /// path → mtime，增量对比用。
    public func knownMtimes() -> [String: Double] {
        var out: [String: Double] = [:]
        try? queue.sync {
            // 两张表一起读：conversations 是「解析出了对话」的，
            // skipped_files 是「解析过但没产出」的。对增量跳过而言两者等价 ——
            // 只要文件没变，都不需要再解析一次。
            try db.query("SELECT file_path, mtime FROM conversations;", row: { s in
                out[SQLiteDB.text(s, 0)] = sqlite3_column_double(s, 1)
            })
            try db.query("SELECT file_path, mtime FROM skipped_files;", row: { s in
                out[SQLiteDB.text(s, 0)] = sqlite3_column_double(s, 1)
            })
        }
        return out
    }

    /// 真的解析出了对话的那些源路径（不含 `skipped_files`）。
    ///
    /// 与 `knownMtimes()` 的区别正是归档需要的那条线：增量跳过时「有对话」和
    /// 「解析过没产出」等价，但归档时不等价——子代理轨迹、壳会话、API Error 残骸
    /// 都躺在 skipped_files 里，App 永远不显示它们，没有理由占归档空间。
    /// 实测本机若不做这个区分，归档量会从约 100MiB 涨到 272MiB（约 65% 是废的）。
    public func conversationPaths() -> [String] {
        var out: [String] = []
        try? queue.sync {
            try db.query("SELECT file_path FROM conversations;", row: { s in
                out.append(SQLiteDB.text(s, 0))
            })
        }
        return out
    }

    /// 记下「解析过但没有产出」的文件，避免每次扫描重复解析。
    public func markSkipped(_ items: [(path: String, mtime: Double)]) {
        guard !items.isEmpty else { return }
        try? queue.sync {
            try db.transaction {
                for it in items {
                    try db.run("INSERT OR REPLACE INTO skipped_files(file_path, mtime) VALUES(?, ?);",
                               bind: {
                                   SQLiteDB.bindText($0, 1, it.path)
                                   sqlite3_bind_double($0, 2, it.mtime)
                               })
                }
            }
        }
    }

    /// 文件重新产出了对话时，把它从 skipped 里摘掉（否则会被永久跳过）。
    func unmarkSkipped(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        try? queue.sync {
            try db.transaction {
                for p in paths {
                    try db.run("DELETE FROM skipped_files WHERE file_path = ?;",
                               bind: { SQLiteDB.bindText($0, 1, p) })
                }
            }
        }
    }

    /// 删除这些文件路径对应的行（含该会话的段、三路 fts 与 skipped 标记）。
    public func prune(missingPaths: [String]) {
        guard !missingPaths.isEmpty else { return }
        unmarkSkipped(missingPaths)   // 文件已不在磁盘上，跳过标记也没有保留意义
        try? queue.sync {
            try db.transaction {
                for p in missingPaths {
                    var rid: Int64?
                    try db.query("SELECT rowid FROM conversations WHERE file_path = ?;",
                                 bind: { SQLiteDB.bindText($0, 1, p) },
                                 row: { rid = sqlite3_column_int64($0, 0) })
                    if let r = rid {
                        // 会话删掉时段必须连带清掉，否则搜索会命中已删会话的幽灵段落
                        try db.run("DELETE FROM segments_fts WHERE rowid IN (SELECT rowid FROM segments WHERE conv_rowid = ?);",
                                   bind: { sqlite3_bind_int64($0, 1, r) })
                        try db.run("DELETE FROM segments_fts_uni WHERE rowid IN (SELECT rowid FROM segments WHERE conv_rowid = ?);",
                                   bind: { sqlite3_bind_int64($0, 1, r) })
                        try db.run("DELETE FROM segments_fts_lex WHERE rowid IN (SELECT rowid FROM segments WHERE conv_rowid = ?);",
                                   bind: { sqlite3_bind_int64($0, 1, r) })
                        try db.run("DELETE FROM segments WHERE conv_rowid = ?;",
                                   bind: { sqlite3_bind_int64($0, 1, r) })
                        // 实体关联同属子表，必须在删主行之前删掉，否则实体页会指向已不存在的会话
                        try db.run("DELETE FROM conversation_entities WHERE conv_rowid = ?;",
                                   bind: { sqlite3_bind_int64($0, 1, r) })
                        try db.run("DELETE FROM milestone_candidates WHERE conv_rowid = ?;",
                                   bind: { sqlite3_bind_int64($0, 1, r) })
                        try db.run("DELETE FROM decision_points WHERE conv_rowid = ?;",
                                   bind: { sqlite3_bind_int64($0, 1, r) })
                        try db.run("DELETE FROM user_corpus WHERE conv_rowid = ?;",
                                   bind: { sqlite3_bind_int64($0, 1, r) })
                        try db.run("DELETE FROM conversations WHERE rowid = ?;",
                                   bind: { sqlite3_bind_int64($0, 1, r) })
                    }
                }
            }
        }
    }

    /// RRF（Reciprocal Rank Fusion）常数。60 是文献通用取值（Cormack et al. 2009），
    /// 作用是压平头部差距：名次靠前的贡献不会碾压另一路的中段结果。
    private static let rrfK = 60.0

    /// 情境先验倍率（实测 ×3 拿到硬过滤收益的 71% 且无不可恢复失败模式）。
    private static let contextPriorMultiplier = 3.0

    /// path 向上找最近的含 `.git` 的目录；找不到（或 path 不存在）返回标准化后的 path。
    /// 只在查询侧对 `contextPath` 调用一次——会话侧的 cwd 可能早已从磁盘消失，走不了，
    /// 用「cwd 以 root 为前缀」判定归属（/repo 的会话可能记在 /repo/sub，见
    /// `applyContextPrior`）。
    ///
    /// `fileExists(atPath:)` 故意不传 `isDirectory`——worktree 场景的 `.git` 是一个
    /// **文件**（内容形如 `gitdir: ../.git/worktrees/xxx`），不是目录；只探测存在性，
    /// 目录与文件两种形态都认。
    ///
    /// `standardizedFileURL` 不展开 `~`——调用方（MCP 工具）传入的应已是绝对路径；
    /// 若传入相对路径，按 URL 的一贯语义相对**进程当前工作目录**解析，不是任何
    /// "用户主目录"语义，调用方需自行保证传入绝对路径。
    public static func gitRoot(of path: String) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let fm = FileManager.default
        var probe = url
        while probe.path != "/" {
            if fm.fileExists(atPath: probe.appendingPathComponent(".git").path) {
                return probe.path
            }
            probe.deleteLastPathComponent()
        }
        return url.path
    }

    /// RM3 伪相关反馈查询扩展策略（实测低带 R@20 +14pt）：原查询 top-8 段
    /// 抽高 IDF 词 → 扩展查询重跑三路 RRF → 与原结果加权融合。
    /// `.off`：现状，不扩展（未标注 `expansion:` 的既有调用点全部走这条，逐位不变）。
    /// `.adaptive`：原查询命中段数 < `adaptiveExpansionThreshold` 才扩——GUI 用这个，
    /// 高重叠带（命中已经很多）零损失，只有低命中的查询才担扩展带来的 query drift 风险。
    /// `.always`：恒扩展——MCP 用这个，宿主模型自己会滤掉扩展带来的噪声，要的是召回。
    public enum ExpansionPolicy {
        case off, adaptive, always
    }

    /// `.adaptive` 的触发阈值：原查询命中的**段数**（`SegmentHit.segmentHitCount` 之和，
    /// 与 `includeText` 开关无关——两条 SQL 路径都会算这个数，见 `rankedSegmentHits`/
    /// `dedupByID`）低于此值才扩展。
    private static let adaptiveExpansionThreshold = 40
    /// 扩展路在二次 RRF 融合里的权重：`final = rrf_original + expansionWeight × rrf_expanded`。
    /// spec 实测取值，保证原查询在权重上稳居主导，扩展只补词汇鸿沟、不反客为主
    /// （`testOriginalRankingDominatesAfterFusion` 钉住这条；改大会让它变红）。
    private static let expansionWeight = 0.45
    /// 抽扩展词看的段数：原查询 top-N 段的预览文本做词源。
    private static let feedbackDepth = 8
    /// 最终进扩展查询的词数上限（按 df 升序/IDF 降序截断）。
    private static let maxExpansionTerms = 6
    /// 扩展词候选集上限：每个候选要点查两次 vocab（df），封顶让最坏情况
    /// （8 段 × 4000 字密集反馈）有硬上界。500 个候选 = 最多 1000 次索引点查，毫秒级。
    private static let maxExpansionCandidates = 500

    /// 把用户输入切成 FTS5 的 OR 查询。
    ///
    /// 此前是把整串包成**一个 phrase**，于是搜「窗口 层级」只能命中原文里
    /// 恰好连着出现「窗口 层级」的对话 —— 召回极低。改成按空白切词后 OR，
    /// 由 BM25 负责把「两个词都命中」的排到前面，比 phrase 硬过滤合理得多。
    /// 单词查询的行为与原来一致。
    private static func ftsQuery(_ q: String) -> String? {
        let terms = q.split(whereSeparator: { $0.isWhitespace })
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        return terms.isEmpty ? nil : terms.joined(separator: " OR ")
    }

    /// 第三路只在「切分真的产生了词级信息」时才发言：
    /// 切分产出含 ≥2 字的 CJK 词元（必然来自词表命中）才跑 lex 路。
    /// ①纯英文查询：_lex 与 _uni 索引内容相同，跑了等于把 unicode61 信号双计；
    /// ②词表外中文：全落单字，单字 OR 是纯噪声（「随便说说」会命中任何含「说」的段）。
    static func lexRouteHasSignal(segmentedQuery: String) -> Bool {
        segmentedQuery.split(whereSeparator: { $0.isWhitespace }).contains { token in
            token.count >= 2 && token.allSatisfy { ch in
                ch.unicodeScalars.first.map { (0x4E00...0x9FFF).contains($0.value) } ?? false
            }
        }
    }

    /// 单路 BM25 检索，段级：返回按相关度升序（FTS5 的 bm25 越负越相关）的
    /// (会话 id, 命中段原文, 段首条消息下标)。同一会话可能有多个段在这一路命中，
    /// 这里不去重——调用方 `dedupByID` 负责把同一会话的多次命中折叠成排名最高的
    /// 那个，同时数出这一路命中了几段。
    ///
    /// `includeText`：`search()` 每次按键都会走到这里（见 `ConversationStore.runSearch`
    /// 的 180ms 防抖），命中面广的查询（英文常见词、三字中文）能命中成百上千段——
    /// 若每次都把段原文（单段最长 `Segmenter.hardTextCap`=200,000 字符）物化进 Swift
    /// 数组，`search()` 转头又靠 `map(\.id)` 把它整体丢掉，是纯粹的按键级内存/CPU
    /// 抖动。为 false 时 SQL 直接给空串，省掉这份物化；`searchWithHits()` 要展示
    /// 命中预览，传 true。
    private func rankedSegmentHits(table: String, match: String, includeText: Bool) -> [(id: String, text: String, firstMsg: Int)] {
        var out: [(id: String, text: String, firstMsg: Int)] = []
        // 三个坑（前两个会话级 fts 时代就有，段级依然成立）：
        // ① bm25() 只认**真实表名**，写别名（bm25(f)）是 "no such column" parse error，
        //    而错误被 try? 吞掉后表现为「搜不到任何东西」，极难定位。
        // ② bm25 在 contentless 表上可用：归一化所需的 docsize 存在索引里，不需要原文；
        //    返回值为负，越负越相关，故 ORDER BY 升序即最相关在前。
        // ③ 即使 includeText，也用 substr 在 SQL 侧截到 4000——段的软上限
        //    （`Segmenter.maxCharsPerSegment`）本就是 4000，绝大多数段完整落在这个
        //    长度内；只有单条巨长消息撑出来的段会被截断，截的只是这里的命中预览，
        //    段原文仍完整存在 `segments` 表里（不动 `hardTextCap`）。这把最坏情况从
        //    200,000 × N 命中压到 4000 × N。
        let textExpr = includeText ? "substr(s.text, 1, 4000)" : "''"
        try? db.query("""
        SELECT c.id, \(textExpr), s.first_msg FROM \(table) f
        JOIN segments s ON s.rowid = f.rowid
        JOIN conversations c ON c.rowid = s.conv_rowid
        WHERE \(table) MATCH ? ORDER BY bm25(\(table));
        """, bind: { SQLiteDB.bindText($0, 1, match) },
             row: { out.append((SQLiteDB.text($0, 0), SQLiteDB.text($0, 1), Int(sqlite3_column_int64($0, 2)))) })
        return out
    }

    /// 同一会话可能有多个段命中同一路查询：只保留排名最高（首次出现）的那个代表这个
    /// 会话参与 RRF 融合（不去重会让会话因命中段数更多而被重复计分，排序被段数而非
    /// 相关度带偏——Task 2 修过一次这个 bug），同时把「这一路总共命中了几段」数出来，
    /// 供 `rankedHits` 汇总成 GUI 要的「命中 N 处」。
    private func dedupByID(_ hits: [(id: String, text: String, firstMsg: Int)])
        -> [(id: String, text: String, firstMsg: Int, segmentHitCount: Int)] {
        var order: [String] = []
        var winner: [String: (text: String, firstMsg: Int)] = [:]
        var count: [String: Int] = [:]
        for h in hits {
            if winner[h.id] == nil {
                order.append(h.id)
                winner[h.id] = (h.text, h.firstMsg)
            }
            count[h.id, default: 0] += 1
        }
        return order.map { id in
            let w = winner[id]!
            return (id: id, text: w.text, firstMsg: w.firstMsg, segmentHitCount: count[id]!)
        }
    }

    /// `search` 与 `searchWithHits` 共用的核心：≥3 字符走 FTS5 三路（trigram 管中文子串 /
    /// unicode61 管英文词法）BM25 各自排序后 RRF 融合；<3 字符走 segments 表 LIKE 兜底
    /// （trigram 索引够不着）。按会话去重，附带命中段的原文/位置/段数
    /// （供片段回显、结果定位、GUI「命中 N 处」展示用）。
    ///
    /// **返回值按相关度排序**（此前是无序 Set，UI 只能按时间展示 —— 实测 R@1 仅 5.2%）。
    /// firstMsg 为 nil 表示这条结果没有具体段可指（LIKE 兜底只命中 cwd 时，见下方分支注释）。
    ///
    /// `includeText`：是否把命中段原文取出来，见 `rankedSegmentHits` 同名参数的注释。
    /// `search()` 只要 id，传 false；`searchWithHits()` 要展示预览，传 true。
    /// id、顺序、firstMsg、segmentHitCount 都不依赖这个开关——FTS 路径的排序看
    /// bm25/RRF 名次，LIKE 路径的排序看 `ORDER BY 1`（id 本身），两者都与 text 列
    /// 无关，所以两条调用路径的会话集合与顺序保证一致
    /// （`SegmentIndexTests.testSearchAndSearchWithHitsAgreeOnIdsAndOrder` 钉住这个不变量）。
    ///
    /// `expansion`：RM3 伪相关反馈查询扩展策略，见 `rankedHitsInsideQueue`。
    /// `contextPath`：情境先验，见 `rankedHitsInsideQueue`/`applyContextPrior`。
    /// 默认 nil——未标注的既有调用点（`search()`）逐位不变，只有 `searchWithHits()`
    /// 会把调用方传入的路径接到这里。
    private func rankedHits(_ query: String, includeText: Bool, expansion: ExpansionPolicy, contextPath: String? = nil)
        -> [(id: String, text: String, firstMsg: Int?, segmentHitCount: Int)] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var out: [(id: String, text: String, firstMsg: Int?, segmentHitCount: Int)] = []
        // 闭包内只调非抛错的 inside-queue 辅助——没有 `try` 调用，`queue.sync` 解析到
        // 非抛错重载，不能再包 `try?`（同 `loadLexicon()` 注释：会变成死代码警告）。
        queue.sync {
            out = rankedHitsInsideQueue(q, includeText: includeText, expansion: expansion, contextPath: contextPath)
        }
        return out
    }

    /// **必须已在 `queue` 上**（同 `loadLexiconInsideQueue` 的重入铁律：不得自带
    /// `queue.sync`）。原查询三路 RRF →（视策略与命中量）判断是否要 RM3 扩展 →
    /// 扩展查询重跑三路 RRF → 与原结果加权 RRF 融合→ 情境先验加权
    /// （`applyContextPrior`）。
    ///
    /// 扩展只发生在 FTS 分支（`q.count >= 3`）——LIKE 兜底路径是布尔匹配，没有 bm25
    /// 名次可供二次 RRF 融合，相关度语义本身就与扩展不兼容。
    ///
    /// 情境先验则不看这个分支——四条 return（`.off`/短查询提前返回、命中已足量不扩展、
    /// 抽不出扩展词、扩展融合完成）全部经 `applyContextPrior` 出口，保证先验作用于
    /// **最终名次**（扩展融合之后），而不是只加在某一条分支上。
    private func rankedHitsInsideQueue(_ q: String, includeText: Bool, expansion: ExpansionPolicy, contextPath: String?)
        -> [(id: String, text: String, firstMsg: Int?, segmentHitCount: Int)] {
        let orig = rawRankedHits(q, includeText: includeText)
        guard expansion != .off, q.count >= 3 else {
            return applyContextPrior(orig, contextPath: contextPath)
        }

        let totalHits = orig.reduce(0) { $0 + $1.segmentHitCount }
        let shouldExpand = expansion == .always || totalHits < Self.adaptiveExpansionThreshold
        guard shouldExpand else { return applyContextPrior(orig, contextPath: contextPath) }

        // 抽词要看段文本；调用方若本来就不要文本（`search()` 的 includeText:false），
        // 这里单独按 includeText:true 补一次查询——只在真的要扩展这个较少见的分支里
        // 才付这个代价，`.adaptive` 的高重叠带（多数查询命中充足）根本走不到这一行。
        let withText = includeText ? orig : rawRankedHits(q, includeText: true)
        let baseTexts = Array(withText.prefix(Self.feedbackDepth)).map(\.text)
        let terms = expansionTermsInsideQueue(for: baseTexts, excludingQuery: q, limit: Self.maxExpansionTerms)
        guard !terms.isEmpty else {   // 抽不出合格词：与 .off 完全一致，不多跑一轮
            return applyContextPrior(orig, contextPath: contextPath)
        }

        // OR 语义天然容纳原词 + 扩展词——`ftsQuery` 已经把空白分隔的每个词包成独立的
        // 引号短语再 OR 起来，追加的扩展词不需要特殊连接符。
        let expandedQuery = q + " " + terms.joined(separator: " ")
        let expanded = rawRankedHits(expandedQuery, includeText: includeText)
        return applyContextPrior(fuseExpanded(orig: orig, expanded: expanded), contextPath: contextPath)
    }

    /// 情境先验：`rankedHitsInsideQueue` 融合出的最终分数之后、排序之前，
    /// 命中会话的 cwd 落在 `contextPath` 的 git root（或其子目录）下 → 总分 ×3。
    ///
    /// **软先验，绝不过滤**：不匹配的会话原样留在返回值里，只是可能排得靠后——
    /// 有无 `contextPath` 时结果**集合**必须相等，变的只有顺序
    /// （`ContextPriorTests.testForeignRepoHitsAreNeverDropped` 钉住这条）。
    ///
    /// 必须已在 `queue` 上（内部按 id 查 `conversations.cwd`，同 `liteRow` 的重入铁律：
    /// 不得自带 `queue.sync`）。`hits` 必须带真实分数（`rawRankedHits`/`fuseExpanded`
    /// 已经把 RRF 分带出来，不再是融合后丢分的排序列表）——不能用名次重新造分
    /// （`1/(rrfK+rank)`）去近似已有的真分数，那会在同分并列时悄悄改变 tie 语义；
    /// LIKE 兜底分支本来就没有真实相关度分，由 `rawRankedHits` 自己按名次造一个
    /// 单调递减的正数占位（乘 0 恒为 0，先验会失效），语义上与这里无关。
    ///
    /// 空串/纯空白 `contextPath` 视同未提供（nil）——GUI 不传（浏览器窗口没有情境），
    /// MCP 侧的模型偶尔可能传空字符串，两者都不该报错，只是不加权。
    private func applyContextPrior(
        _ hits: [(id: String, text: String, firstMsg: Int?, segmentHitCount: Int, score: Double)],
        contextPath: String?
    ) -> [(id: String, text: String, firstMsg: Int?, segmentHitCount: Int)] {
        guard let trimmed = contextPath?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return hits.map { (id: $0.id, text: $0.text, firstMsg: $0.firstMsg, segmentHitCount: $0.segmentHitCount) }
        }
        let root = Self.gitRoot(of: trimmed)
        // 命中集通常几十条——按需逐条查这些会话的 cwd，不扫全表；写法与 `liteRow`
        // 同款的按 id 查询（已在 queue 上，不能再 `queue.sync`，查询失败静默跳过——
        // 查不到就是不加权，不是报错，与索引层"失败不崩、不假装"的一贯风格一致）。
        var boosted: [(id: String, text: String, firstMsg: Int?, segmentHitCount: Int, score: Double)] = []
        boosted.reserveCapacity(hits.count)
        for hit in hits {
            var cwd: String?
            try? db.query("SELECT cwd FROM conversations WHERE id = ?;",
                          bind: { SQLiteDB.bindText($0, 1, hit.id) },
                          row: { cwd = SQLiteDB.text($0, 0) })
            // 前缀判定必须带 "/" 边界：/repo-other 不是 /repo 的子路径，只有
            // cwd 恰好等于 root、或以 "root/" 打头才算归属这个 git 仓库。
            if let cwd, cwd == root || cwd.hasPrefix(root + "/") {
                boosted.append((id: hit.id, text: hit.text, firstMsg: hit.firstMsg,
                                segmentHitCount: hit.segmentHitCount, score: hit.score * Self.contextPriorMultiplier))
            } else {
                boosted.append(hit)
            }
        }
        // 乘完重排：tie-break 沿用现有「分数相同按 id 升序」的稳定语义
        // （与 `rawRankedHits`/`fuseExpanded` 的排序规则一致）。
        return boosted.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id
        }.map { (id: $0.id, text: $0.text, firstMsg: $0.firstMsg, segmentHitCount: $0.segmentHitCount) }
    }

    /// **必须已在 `queue` 上**——单次查询串的三路 RRF 融合（FTS 分支）或 LIKE 兜底
    /// （短词分支），从旧版单参 `rankedHits` 原样搬来，逻辑未改一字。供
    /// `rankedHitsInsideQueue` 对原查询与扩展查询分别各调一次；两次调用共享同一次
    /// `queue.sync`（调用方已经在 queue 上），不会重入。
    private func rawRankedHits(_ q: String, includeText: Bool) -> [(id: String, text: String, firstMsg: Int?, segmentHitCount: Int, score: Double)] {
        var out: [(id: String, text: String, firstMsg: Int?, segmentHitCount: Int, score: Double)] = []
        if q.count >= 3, let match = Self.ftsQuery(q) {
            let lexicon = loadLexiconInsideQueue()
            let tri = dedupByID(rankedSegmentHits(table: "segments_fts", match: match, includeText: includeText))
            let uni = dedupByID(rankedSegmentHits(table: "segments_fts_uni", match: match, includeText: includeText))
            var lists = [tri, uni]
            // 第三路：查询侧必须用同一份词表、同一个 segment 函数切分查询串——
            // 索引侧怎么切、查询侧就怎么切，两侧不一致 = 第三路永远零命中。
            // 门控收紧（审查实锤两个反例，见 `lexRouteHasSignal`）：只在切分产出
            // 「≥2 字纯 CJK 词元」时才跑——那必然来自词表命中。否则要么是纯英文查询
            // （_lex 与 _uni 索引内容相同，跑了等于把 unicode61 信号双计），要么是
            // 词表外中文（全落单字，单字 OR 是纯噪声，「随便说说」会命中任何含
            // 「说」的段，trigram 路本来正确拒绝的噪声）。
            let segmented = PersonalLexicon.segment(q, lexicon: lexicon)
            if Self.lexRouteHasSignal(segmentedQuery: segmented),
               let lexMatch = Self.ftsQuery(segmented) {
                lists.append(dedupByID(rankedSegmentHits(table: "segments_fts_lex", match: lexMatch, includeText: includeText)))
            }
            // RRF：score(d) = Σ 1/(k + rank_i(d))，名次从 1 起。
            // 各路量纲不同（trigram 的 BM25 建立在 3-gram 上、unicode61/lex 在词上），
            // 直接加分数没有意义，融合名次才是对的。
            var score: [String: Double] = [:]
            var text: [String: String] = [:]
            var firstMsg: [String: Int] = [:]
            var segmentHitCount: [String: Int] = [:]
            for list in lists {
                for (i, hit) in list.enumerated() {
                    score[hit.id, default: 0] += 1.0 / (Self.rrfK + Double(i + 1))
                    // 段原文/位置/段数三者同源：都取「先命中那一路」的结果（tri > uni
                    // > lex 的遍历顺序）——各路是同一批物理段的不同分词视角，文字取
                    // 一路、段数取另一路的 max 会让「代表段」和「命中几段」对不上，
                    // 比如代表段来自 trigram 排名最高的那段，段数却是别的路数出来的。
                    if text[hit.id] == nil {
                        text[hit.id] = hit.text
                        firstMsg[hit.id] = hit.firstMsg
                        segmentHitCount[hit.id] = hit.segmentHitCount
                    }
                }
            }
            out = score.sorted {
                $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
            }.map {
                (id: $0.key, text: text[$0.key] ?? "",
                 firstMsg: firstMsg[$0.key], segmentHitCount: segmentHitCount[$0.key] ?? 1, score: $0.value)
            }
        } else {
            // LIKE 通配符转义（% _ 及转义符自身）+ ESCAPE：
            // 搜「100%」「_id」这类短词才按字面匹配，而不是被当成通配模式全量命中
            let escaped = q.lowercased()
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            // 短词（<3 字，trigram 索引够不着）LIKE 扫 segments 表原文——
            // 「你好」「接力」这类两字中文词是检索主力，必须覆盖消息全文
            //（曾只扫 preview+cwd：真实库上「接力」命中 0 条，形同虚设）。
            //
            // 不再对 s.text / cwd 套 LOWER：SQLite 的 LIKE 本身对 ASCII 字母就
            // 大小写不敏感（'A' LIKE 'a' 恒真，与哪一侧原本是什么大小写无关），
            // 对非 ASCII 字符两侧原本就都不折叠——SQLite 内建的 lower() 函数默认同样
            // 只认 ASCII（折非 ASCII 需要加载 ICU 扩展，这里没接），所以
            // LOWER(s.text) 相对不加 LOWER 不增加任何匹配能力，只换来每次短词查询
            // 把全库段文本复制一遍的开销。查询侧的 `q.lowercased()` 不受影响，
            // 留着无妨（只是几个字符，不是全库扫描）。
            // 短词路径没有相关度可言（LIKE 是布尔匹配），按 id 排序，
            // 与原逻辑一致；第二列 DESC 只是让「有段原文」优先于纯 cwd 命中，避免同 id
            // 落在两个分支时哪行胜出无定义（includeText=false 时该列恒为空串，
            // 退化成纯按 id 排序——不影响顺序，因为 id 本身就是排序主键）。
            //
            // 边角契约：这条路径不追求 FTS 那种精确多段计数（LIKE 是布尔匹配，
            // 没有 bm25 排名，犯不上为短词兜底再建一套聚合）。命中 cwd（第二个
            // UNION 分支，text/first_msg 用 ''/NULL 占位）时没有真实段可指，
            // bestSegmentFirstMessageIndex 给 nil、segmentHitCount 固定给 1；
            // 命中的是段原文时给出它真实的 first_msg，段数同样固定给 1——
            // 即便同一会话有不止一段命中这个短词，也只保证「至少命中 1 处」。
            // 这条 firstMsg 推断靠 t.isEmpty 判断落在哪个 UNION 分支，只有
            // includeText=true（searchWithHits）时 t 才是真实取值；search() 传
            // includeText=false 时 t 恒为空串、firstMsg 因此恒为 nil，但 search()
            // 只消费 id，不受影响。
            let textExpr = includeText ? "substr(s.text, 1, 4000)" : "''"
            var seen = Set<String>()
            try? db.query("""
            SELECT c.id, \(textExpr), s.first_msg FROM segments s
            JOIN conversations c ON c.rowid = s.conv_rowid
            WHERE s.text LIKE ?1 ESCAPE '\\'
            UNION
            SELECT id, '', NULL FROM conversations WHERE cwd LIKE ?1 ESCAPE '\\'
            ORDER BY 1, 2 DESC;
            """,
                         bind: { SQLiteDB.bindText($0, 1, "%\(escaped)%") },
                         row: { r in
                let id = SQLiteDB.text(r, 0)
                let t = SQLiteDB.text(r, 1)
                if seen.insert(id).inserted {
                    let firstMsg = t.isEmpty ? nil : Int(sqlite3_column_int64(r, 2))
                    // LIKE 兜底是布尔匹配，没有真实相关度分——用与 RRF 同构的名次→分数
                    // 映射（1/(k+rank)）造一个单调递减的正数，只是为了让 `applyContextPrior`
                    // 有「非零」的分可乘（乘 0 恒为 0，先验会失效）；不改变现有顺序
                    // （仍是 id 升序），也不参与跨路融合，纯粹是先验加权点要用的载体。
                    let score = 1.0 / (Self.rrfK + Double(out.count + 1))
                    out.append((id, t, firstMsg, 1, score))
                }
            })
        }
        return out
    }

    /// 原查询列表与扩展查询列表各自按名次（1-based）算 RRF 分再加权求和：
    /// `final = rrf_orig + expansionWeight × rrf_exp`，降序重排（同分按 id 升序，稳定
    /// 输出）。命中段数/代表段文本/位置优先取**原查询**那份（有的话）——原查询没
    /// 命中的 id（扩展独有的新会话）才落到扩展那份，与三路融合内部「先出现者为准」
    /// 是同一条规则。
    private func fuseExpanded(orig: [(id: String, text: String, firstMsg: Int?, segmentHitCount: Int, score: Double)],
                               expanded: [(id: String, text: String, firstMsg: Int?, segmentHitCount: Int, score: Double)])
        -> [(id: String, text: String, firstMsg: Int?, segmentHitCount: Int, score: Double)] {
        var score: [String: Double] = [:]
        var text: [String: String] = [:]
        var firstMsg: [String: Int] = [:]
        var segmentHitCount: [String: Int] = [:]
        for (i, hit) in orig.enumerated() {
            score[hit.id, default: 0] += 1.0 / (Self.rrfK + Double(i + 1))
            text[hit.id] = hit.text
            if let fm = hit.firstMsg { firstMsg[hit.id] = fm }
            segmentHitCount[hit.id] = hit.segmentHitCount
        }
        for (i, hit) in expanded.enumerated() {
            score[hit.id, default: 0] += Self.expansionWeight / (Self.rrfK + Double(i + 1))
            if text[hit.id] == nil {
                text[hit.id] = hit.text
                if let fm = hit.firstMsg { firstMsg[hit.id] = fm }
                segmentHitCount[hit.id] = hit.segmentHitCount
            }
        }
        return score.sorted {
            $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
        }.map {
            (id: $0.key, text: text[$0.key] ?? "",
             firstMsg: firstMsg[$0.key], segmentHitCount: segmentHitCount[$0.key] ?? 1, score: $0.value)
        }
    }

    /// `PersonalLexicon.segment` 先把中文按词表切好（未命中退化单字，天然空格分界），
    /// 再对整段结果按「连续字母/数字」抽取候选——这一步顺带把中文词间的空格与残留
    /// 标点（如「，appcast」的中文逗号）清掉，也把英文单词与标点断开。CJK 字符在
    /// Swift 里本身就是 `isLetter`，段内多字词元不会被这一步拆散（`segment` 已经在
    /// 词元之间插了空格，词元内部无分隔符）——合起来就是「先切中文再按非字母数字切
    /// 英文，合并词元」。
    ///
    /// internal（非 private）可见度：`BenchDataset`（评测集分带）需要与
    /// RM3 扩展词**同一条**切词管道来判定「query 与答案会话全文的低频词重叠数」——
    /// 分带用的「词」概念必须与生产代码判断「候选词」的概念是同一件事，否则评测数字
    /// 会静默漂移出它本该衡量的东西。同 `expansionTerms(for:excludingQuery:limit:)`
    /// 的先例：为可测性/可复用性放宽到 internal，不进公开 API。
    public static func candidateTokens(from text: String, lexicon: Set<String>) -> [String] {
        let segmented = PersonalLexicon.segment(text, lexicon: lexicon)
        var tokens: [String] = []
        var current = ""
        for ch in segmented {
            if ch.isLetter || ch.isNumber {
                current.append(ch)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// **必须已在 `queue` 上**。抽取 RM3 扩展词：top-N 段文本切词 → df 过滤（查
    /// `vocab_uni`/`vocab_lex` 取 max）→ 按 df 升序（IDF 最高优先）取前 `limit` 个。
    /// `baseTexts` 是调用方已经切好的 top-8（`feedbackDepth`）段预览文本
    /// （`SegmentHit.bestSegmentText` 精度，SQL 已截 4000 字，够抽词，不必为此另发查询）。
    ///
    /// 自查①（任务要求记录）：中文候选靠 `PersonalLexicon.segment` 切分——词表为空时
    /// （尚未 `rebuildLexiconIfNeeded`，或纯英文语料合法产出空词表）中文 run 会整段
    /// 退化成单字，逐个被下面「长度 < 2」的规则挡掉，中文扩展词此时是空集。这是
    /// **预期**的优雅退化，不是 bug：词表会在扫描收尾建起来，届时中文候选自然恢复。
    private func expansionTermsInsideQueue(for baseTexts: [String], excludingQuery query: String, limit: Int) -> [String] {
        let lexicon = loadLexiconInsideQueue()
        let queryLower = query.lowercased()

        // 候选集：合并全部 top-N 段的切词结果去重（同词多段出现只算一次候选，
        // df 本身已经是跨段/跨会话统计，不需要在候选阶段也去重计数）。
        var candidates: [String] = []
        var seen = Set<String>()
        for text in baseTexts {
            for token in Self.candidateTokens(from: text, lexicon: lexicon) {
                let lower = token.lowercased()
                guard token.count >= 2,                 // 长度 < 2 丢
                      !token.allSatisfy(\.isNumber),     // 纯数字丢
                      !queryLower.contains(lower)        // 原查询已含（大小写不敏感）丢
                else { continue }
                if seen.insert(lower).inserted { candidates.append(lower) }
                // 候选上限：8 段 × 4000 字的密集反馈段能切出上千候选，每个候选要点查
                // 两次 vocab——封顶让 df 查询次数有硬上界。检查放在**词**循环内
                // （此前在段循环末尾，单段就可能冲破上限一整段的词量）。
                // 先出现的段排名更靠前（伪相关反馈里越靠前的文档越可信），
                // 截断天然偏向保留它们的词。
                if candidates.count >= Self.maxExpansionCandidates { break }
            }
            if candidates.count >= Self.maxExpansionCandidates { break }
        }
        guard !candidates.isEmpty else { return [] }

        var totalSegments = 0
        try? db.query("SELECT COUNT(*) FROM segments;",
                      row: { totalSegments = Int(sqlite3_column_int64($0, 0)) })
        let ceiling = max(2, Int(0.05 * Double(totalSegments)))

        // df 从 fts5vocab 查：term 是分词后的小写词元，候选词已经 lowercased 过。
        // 两个 vocab 表取 max——CJK 候选词几乎只在 vocab_lex 里有干净的整词 df
        // （vocab_uni 对未切分的连续 CJK run 只会给出一个巨长 token，几乎不会等于
        // 候选词本身）；英文候选词的 df 在两表通常相等（unicode61 对非 CJK 部分的
        // 切分本就与词表切分无关），取 max 两种情况都对。
        var scored: [(term: String, df: Int)] = []
        for term in candidates {
            var dfUni = 0, dfLex = 0
            try? db.query("SELECT doc FROM vocab_uni WHERE term = ?;",
                          bind: { SQLiteDB.bindText($0, 1, term) },
                          row: { dfUni = Int(sqlite3_column_int64($0, 0)) })
            try? db.query("SELECT doc FROM vocab_lex WHERE term = ?;",
                          bind: { SQLiteDB.bindText($0, 1, term) },
                          row: { dfLex = Int(sqlite3_column_int64($0, 0)) })
            let df = max(dfUni, dfLex)
            guard df >= 2, df <= ceiling else { continue }   // df 过滤：2 ≤ df ≤ max(2, 5%×总段数)
            scored.append((term, df))
        }
        return scored
            .sorted { $0.df != $1.df ? $0.df < $1.df : $0.term < $1.term }   // df 升序 = IDF 降序
            .prefix(limit)
            .map(\.term)
    }

    /// 同 `expansionTermsInsideQueue`，自带 `queue.sync`（同 `lexRouteMatchCount` 的
    /// 模式：不重入的内部版本 + 自包装的直测入口）。internal 可见度，供
    /// `QueryExpansionTests` 直测，不进公开 API。
    func expansionTerms(for baseTexts: [String], excludingQuery query: String, limit: Int) -> [String] {
        var terms: [String] = []
        queue.sync { terms = expansionTermsInsideQueue(for: baseTexts, excludingQuery: query, limit: limit) }
        return terms
    }

    /// 搜索：调用方大多只需要会话 id（集合判断 / 列表跳转），语义见 `rankedHits`。
    /// 调用方若只需成员判断，取 Set(...) 即可；需要相关度就直接用这个顺序。
    ///
    /// 这是每次按键都会触发的热路径（`ConversationStore.runSearch`，180ms 防抖后调用），
    /// includeText: false 让底层 SQL 不取段原文——不然每次按键都要把命中段（可能成百
    /// 上千段）的原文物化进这个数组，转头又被下面的 `map(\.id)` 整体丢弃，白做功。
    ///
    /// `expansion`：RM3 查询扩展策略，默认 `.off`——**签名一次定型**，未标注的既有
    /// 调用点全部走这条，行为逐位不变。GUI（`ConversationStore.runSearch`）传
    /// `.adaptive`；MCP（`MemorySearchTool`）经 `searchWithHits` 传 `.always`。
    public func search(_ query: String, expansion: ExpansionPolicy = .off) -> [String] {
        rankedHits(query, includeText: false, expansion: expansion).map(\.id)
    }

    /// 段级搜索命中：会话 id + 命中的段原文 + 命中段数 + 最佳段的首条消息下标。
    /// 后两者供 GUI「命中 N 处」展示与「点击跳转到那条消息」使用。
    ///
    /// 消费方是 GUI 与 MCP，以下两点边界必须遵守，否则会出事故：
    public struct SegmentHit {
        public let id: String
        /// 命中段的**预览**，不是段的完整原文——长度受 SQL 侧 `substr(s.text, 1, 4000)`
        /// 限制（见 `rankedSegmentHits`），超出部分被截断。需要完整内容必须回源
        /// （按 `id` 重新读取会话详情），不能假设这里拿到的就是段的全文。
        public let bestSegmentText: String
        /// 该会话有几段命中查询词（FTS 路径精确统计；LIKE 兜底路径固定为 1，见 `rankedHits`）。
        public let segmentHitCount: Int
        /// 最佳段（`bestSegmentText` 所属段）的首条消息下标；LIKE 兜底命中 cwd 而非
        /// 段原文时没有段可指，为 nil。
        ///
        /// 这是**入库时那次 parse** 记录下来的下标，不是「此刻」的下标。源文件在
        /// 扫描之后可能又被追加或重写（活跃会话持续写入是常态），详情页据此重新
        /// parse 出的 `messages` 可能比索引时更短或结构已变——这个下标因此可能
        /// 超出详情页当前 `messages.count`。消费方必须按当前消息数 clamp 之后再用
        /// （例如 `min(idx, messages.count - 1)`），否则跳转会越界崩溃。
        public let bestSegmentFirstMessageIndex: Int?
    }

    /// 同 `search`，额外带上命中段的原文、段数与位置。
    ///
    /// `contextPath`（情境先验）：调用方当前工作目录。查询侧解析一次
    /// git root，命中会话的 cwd 落在这个 root（或其子目录）下 → 总分 ×3——软加权，
    /// 绝不从结果里剔除跨项目命中，只影响排序（见 `applyContextPrior`）。
    /// GUI 不传（浏览器窗口没有情境）；MCP 把宿主模型自己的 cwd 传进来
    /// （见 `MemorySearchTool`）。
    public func searchWithHits(_ query: String, expansion: ExpansionPolicy = .off, contextPath: String? = nil) -> [SegmentHit] {
        rankedHits(query, includeText: true, expansion: expansion, contextPath: contextPath).map {
            SegmentHit(id: $0.id, bestSegmentText: $0.text,
                       segmentHitCount: $0.segmentHitCount, bestSegmentFirstMessageIndex: $0.firstMsg)
        }
    }

    /// BrowserVault 专用：1 文件 N 对话，套不进 per-file 增量模型。
    /// 清掉所有 source='browser' 行（含段与三路 fts）后按 conv.id 作 file_path 重插。
    /// volume 小（扩展端 ≤200），全量重载可接受，且天然获得「对话被删」的清理。
    public func replaceBrowserVault(_ convs: [Conversation]) {
        try? queue.sync {
            let lexicon = loadLexiconInsideQueue()
            try db.transaction {
                // 先删段与三路 fts（按 rowid 子查询），再删会话行——反序会留下孤儿段/fts
                try db.exec("""
                DELETE FROM segments_fts WHERE rowid IN (
                    SELECT s.rowid FROM segments s
                    JOIN conversations c ON c.rowid = s.conv_rowid WHERE c.source = 'browser'
                );
                """)
                try db.exec("""
                DELETE FROM segments_fts_uni WHERE rowid IN (
                    SELECT s.rowid FROM segments s
                    JOIN conversations c ON c.rowid = s.conv_rowid WHERE c.source = 'browser'
                );
                """)
                try db.exec("""
                DELETE FROM segments_fts_lex WHERE rowid IN (
                    SELECT s.rowid FROM segments s
                    JOIN conversations c ON c.rowid = s.conv_rowid WHERE c.source = 'browser'
                );
                """)
                try db.exec("DELETE FROM segments WHERE conv_rowid IN (SELECT rowid FROM conversations WHERE source = 'browser');")
                // 实体关联同属子表，必须在删 conversations 主行之前删掉——
                // 道理与上面段/fts 的删除顺序一致，browser 源同样要接线（1 文件 N 对话，
                // 不能只改 upsertOne 就当作全库都覆盖到了）。
                try db.exec("DELETE FROM conversation_entities WHERE conv_rowid IN (SELECT rowid FROM conversations WHERE source = 'browser');")
                try db.exec("DELETE FROM user_corpus WHERE conv_rowid IN (SELECT rowid FROM conversations WHERE source = 'browser');")
                try db.exec("DELETE FROM conversations WHERE source = 'browser';")
                var seen = Set<String>()
                for conv in convs {
                    // 批内 id 去重：万一仍有重复 id，跳过而非让 UNIQUE 抛错回滚整批
                    guard seen.insert(conv.id).inserted else { continue }
                    try db.run("""
                    INSERT INTO conversations (id, source, start_at, end_at, cwd, git_branch, title, preview, message_count, file_path, mtime, last_role)
                    VALUES (?,?,?,?,?,?,?,?,?,?,0,?);
                    """, bind: { s in
                        SQLiteDB.bindText(s, 1, conv.id)
                        SQLiteDB.bindText(s, 2, conv.source.rawValue)
                        sqlite3_bind_double(s, 3, conv.startAt.timeIntervalSince1970)
                        sqlite3_bind_double(s, 4, conv.endAt.timeIntervalSince1970)
                        SQLiteDB.bindText(s, 5, conv.cwd)
                        if let b = conv.gitBranch { SQLiteDB.bindText(s, 6, b) } else { sqlite3_bind_null(s, 6) }
                        if let t = conv.title { SQLiteDB.bindText(s, 7, t) } else { sqlite3_bind_null(s, 7) }
                        SQLiteDB.bindText(s, 8, conv.preview)
                        sqlite3_bind_int64(s, 9, Int64(conv.messageCount))
                        SQLiteDB.bindText(s, 10, conv.id)   // file_path = conv.id（唯一）
                        SQLiteDB.bindText(s, 11, Segmenter.lastMeaningfulRole(of: conv.messages))
                    })
                    var rowid: Int64 = 0
                    try db.query("SELECT rowid FROM conversations WHERE id = ?;",
                                 bind: { SQLiteDB.bindText($0, 1, conv.id) },
                                 row: { rowid = sqlite3_column_int64($0, 0) })
                    // 用户语料：browser 路径持有完整消息，可直接现算（行数守恒同 upsertOne）
                    let userText = Segmenter.userText(of: conv.messages)
                    try db.run("INSERT INTO user_corpus(conv_rowid, text) VALUES(?, ?);",
                               bind: { s in
                        sqlite3_bind_int64(s, 1, rowid)
                        SQLiteDB.bindText(s, 2, userText)
                    })
                    // 段级索引：切段后逐段写三路 fts——此前漏写 search_text 导致 browser 对话的
                    // 短词（<3 字）搜索永远搜不到，段的 text 同样要存原文，道理不变。
                    let segs = Segmenter.segments(of: conv.messages)
                    for seg in segs {
                        try db.run("INSERT INTO segments(conv_rowid, first_msg, last_msg, text) VALUES(?,?,?,?);",
                                   bind: { s in
                            sqlite3_bind_int64(s, 1, rowid)
                            sqlite3_bind_int64(s, 2, Int64(seg.firstMessageIndex))
                            sqlite3_bind_int64(s, 3, Int64(seg.lastMessageIndex))
                            SQLiteDB.bindText(s, 4, seg.text)
                        })
                        let segRowid = db.lastInsertRowid
                        try db.run("INSERT INTO segments_fts(rowid, text) VALUES(?, ?);",
                                   bind: { s in
                            sqlite3_bind_int64(s, 1, segRowid)
                            SQLiteDB.bindText(s, 2, seg.text)
                        })
                        try db.run("INSERT INTO segments_fts_uni(rowid, text) VALUES(?, ?);",
                                   bind: { s in
                            sqlite3_bind_int64(s, 1, segRowid)
                            SQLiteDB.bindText(s, 2, seg.text)
                        })
                        let lexSegmented = PersonalLexicon.segment(seg.text, lexicon: lexicon)
                        try db.run("INSERT INTO segments_fts_lex(rowid, text) VALUES(?, ?);",
                                   bind: { s in
                            sqlite3_bind_int64(s, 1, segRowid)
                            SQLiteDB.bindText(s, 2, lexSegmented)
                        })
                    }
                    // 实体：口径与 upsertOne 一致——每会话抽一次，且用排除 .toolUse 的
                    // 专用口径（Segmenter.entityText），不是 segs 拼出来的检索文本
                    // （那份口径含 .toolUse，会把工具调用参数名当成实体，见该函数注释）。
                    // 旧关联已在上面的批量 DELETE FROM conversation_entities（source='browser'）
                    // 里连带清掉，这里只管写新的，不需要再按单条 rowid 清一次。
                    let entityText = Segmenter.entityText(of: conv.messages)
                    for e in EntityExtractor.extract(from: entityText) {
                        try db.run("INSERT OR IGNORE INTO entities(text, kind) VALUES(?, ?);", bind: { st in
                            SQLiteDB.bindText(st, 1, e.text)
                            SQLiteDB.bindText(st, 2, e.kind.rawValue)
                        })
                        try db.run("""
                        INSERT OR IGNORE INTO conversation_entities(conv_rowid, entity_rowid)
                        SELECT ?, rowid FROM entities WHERE text = ? AND kind = ?;
                        """, bind: { st in
                            sqlite3_bind_int64(st, 1, rowid)
                            SQLiteDB.bindText(st, 2, e.text)
                            SQLiteDB.bindText(st, 3, e.kind.rawValue)
                        })
                    }
                }
            }
        }
    }

    /// 文档频率上限：出现在超过这个比例的会话里的实体，不进导航推荐。
    /// 不是停用词表——那要人工维护且换个用户就失效；这是 IDF 的同一套原理：
    /// 一个几乎每场会话都出现的词区分度为零，作为过滤器点进去等于没筛。
    /// 这是**通用区分度兜底**，跟实体来源无关——任何实体只要 DF 过半，作为导航过滤器
    /// 点进去都等于没筛，不管它是不是「样板词」；对未来任何新出现的高频噪声都是零
    /// 维护成本的防线，这是它作为一条通用机制留在这里的理由。
    ///
    /// 样板词问题**不是靠这条阈值解决的**：实测 Claude Code 那批工具参数名
    /// （file_path/old_string 等）DF 最高只有 21%，压根够不到 50% 阈值——而真项目词
    /// 反而更高（NodeNext 29.5%、src/index.ts 27%），全局 DF 原理上区分不了两者，
    /// 这条阈值从原理上就压不住它们。真正治本的是抽取侧跳过 `.toolUse`（见
    /// `Segmenter.entityText`）：v11 之后这些参数名根本不会被抽出来，样板词已从
    /// Top-30 彻底消失，与这条阈值无关。
    /// 压制只发生在**查询层**，`entities` 表本身完整保留——将来想调阈值或换策略不必重建索引。
    ///
    /// HAVING 里额外 `+1` 会话的宽容量：会话总数很小时（个人库刚起步，或本文件的单元测试），
    /// 「出现在全部会话」是样本太少的必然结果、不代表它是样板——类比 Laplace 加一平滑，
    /// 是文档频率这类比例统计在小样本下的标准处理。真实语料（139 会话）里这一项几乎不
    /// 改变结果（阈值从 69.5 变 70.5，仅一会话之差），但能避免小库仅有的一两个实体因为
    /// 「恰好每场都提到」而被自己的 100% 复现率误杀成空列表。
    private static let documentFrequencyCeiling = 0.5

    public struct EntityStat {
        public let text: String
        public let kind: String
        public let conversationCount: Int
    }

    /// 全库实体按「出现会话数」降序，用于实体页与地图页。零引用实体（关联被删光）
    /// 自然排不进来——用 JOIN 而不是读 entities 表本身，就不必额外做孤儿实体清理。
    /// 样板实体（文档频率超过上限）被 HAVING 滤掉，见 `documentFrequencyCeiling`。
    public func topEntities(limit: Int) -> [EntityStat] {
        var out: [EntityStat] = []
        try? queue.sync {
            try db.query("""
            SELECT e.text, e.kind, COUNT(ce.conv_rowid) AS n FROM entities e
            JOIN conversation_entities ce ON ce.entity_rowid = e.rowid
            GROUP BY e.rowid
            HAVING n <= (SELECT COUNT(*) FROM conversations) * ? + 1
            ORDER BY n DESC, e.text LIMIT ?;
            """, bind: { st in
                sqlite3_bind_double(st, 1, Self.documentFrequencyCeiling)
                sqlite3_bind_int(st, 2, Int32(clamping: limit))
            }, row: { st in
                out.append(EntityStat(text: SQLiteDB.text(st, 0),
                                      kind: SQLiteDB.text(st, 1),
                                      conversationCount: Int(sqlite3_column_int(st, 2))))
            })
        }
        return out
    }

    // MARK: - Minds 惊喜区查询（信息价值 = 意外度：你自己都没意识到的模式才值钱）

    /// 「断点」：最后一条消息是 user = 你问了没人答（被打断/没继续）。
    public struct UnfinishedThread: Equatable {
        public let id: String
        public let title: String?
        public let preview: String
        public let cwd: String
        public let endAt: Date
        public init(id: String, title: String?, preview: String, cwd: String, endAt: Date) {
            self.id = id; self.title = title; self.preview = preview; self.cwd = cwd; self.endAt = endAt
        }
    }

    /// 悬而未决的会话。两类合并，都是纯结构信号——词面分类
    /// （「这句话像不像没说完」）已被评测否定，不做：
    ///
    /// ① 你问了没人答（`last_role = 'user'`）。真机 141 场里只有 4 场：
    ///    AI 工具总会回复，对话几乎必然以它收尾，所以这一类天然稀有。
    /// ② **它问了你、你没回**（`open_question`）。反过来看才抓得住真正
    ///    悬着的事，而且条条可执行——真机抽样：「要我把它归档提交、
    ///    还是继续调形态？」「…是这轮所有工作里最确定的收益。要我开始吗？」
    ///
    /// 覆盖率低（合计约 6%）不是缺陷：悬着的事本来就该少，5 件是一份
    /// 可行动的清单，50 件才说明有问题。
    public func unfinishedThreads(since: Date, limit: Int) -> [UnfinishedThread] {
        var out: [UnfinishedThread] = []
        try? queue.sync {
            try db.query("""
            SELECT id, title, COALESCE(open_question, preview), cwd, end_at FROM conversations
            WHERE (last_role = 'user' OR open_question IS NOT NULL) AND end_at >= ?
            ORDER BY end_at DESC LIMIT ?;
            """, bind: { st in
                sqlite3_bind_double(st, 1, since.timeIntervalSince1970)
                sqlite3_bind_int(st, 2, Int32(clamping: limit))
            }, row: { st in
                let title = sqlite3_column_type(st, 1) == SQLITE_NULL ? nil : SQLiteDB.text(st, 1)
                out.append(UnfinishedThread(id: SQLiteDB.text(st, 0), title: title,
                                            preview: SQLiteDB.text(st, 2), cwd: SQLiteDB.text(st, 3),
                                            endAt: Date(timeIntervalSince1970: sqlite3_column_double(st, 4))))
            })
        }
        return out
    }

    /// 「反复回来的问题」：一个实体隔着时间反复出现。
    public struct RecurringEntity: Equatable {
        public let text: String
        public let conversationCount: Int
        public let firstAt: Date
        public let lastAt: Date
    }

    /// 跨 ≥`minConversations` 个会话、首末 `start_at` 相隔 ≥`minSpanDays` 天的实体，
    /// 按最近一次出现降序（最近又回来的排前面——「又」字才是惊喜）。
    /// 排除全库 Top-`excludeTop` 实体：那些是你的主项目词（mindbus/swift 之类），
    /// 天天说不算「反复回来」；样板实体同样被 `documentFrequencyCeiling` 压掉。
    public func recurringEntities(minConversations: Int, minSpanDays: Int,
                                  excludeTop: Int, limit: Int) -> [RecurringEntity] {
        var out: [RecurringEntity] = []
        try? queue.sync {
            try db.query("""
            SELECT e.text, COUNT(ce.conv_rowid) AS n,
                   MIN(c.start_at) AS first_at, MAX(c.start_at) AS last_at
            FROM entities e
            JOIN conversation_entities ce ON ce.entity_rowid = e.rowid
            JOIN conversations c ON c.rowid = ce.conv_rowid
            WHERE e.rowid NOT IN (
                SELECT entity_rowid FROM conversation_entities
                GROUP BY entity_rowid ORDER BY COUNT(*) DESC LIMIT ?)
            GROUP BY e.rowid
            HAVING n >= ? AND n <= (SELECT COUNT(*) FROM conversations) * ? + 1
               AND last_at - first_at >= ?
            ORDER BY last_at DESC, e.text LIMIT ?;
            """, bind: { st in
                sqlite3_bind_int(st, 1, Int32(clamping: excludeTop))
                sqlite3_bind_int(st, 2, Int32(clamping: minConversations))
                sqlite3_bind_double(st, 3, Self.documentFrequencyCeiling)
                sqlite3_bind_double(st, 4, Double(minSpanDays) * 86_400)
                sqlite3_bind_int(st, 5, Int32(clamping: limit))
            }, row: { st in
                out.append(RecurringEntity(text: SQLiteDB.text(st, 0),
                                           conversationCount: Int(sqlite3_column_int(st, 1)),
                                           firstAt: Date(timeIntervalSince1970: sqlite3_column_double(st, 2)),
                                           lastAt: Date(timeIntervalSince1970: sqlite3_column_double(st, 3))))
            })
        }
        return out
    }

    /// 本期首次出现的实体（该实体全部会话的最早 `start_at` 落在 `since` 之后），
    /// 按会话数降序——「这个月你开始聊的新东西」。样板过滤同 `topEntities`。
    public func newEntities(since: Date, limit: Int) -> [EntityStat] {
        var out: [EntityStat] = []
        try? queue.sync {
            try db.query("""
            SELECT e.text, e.kind, COUNT(ce.conv_rowid) AS n
            FROM entities e
            JOIN conversation_entities ce ON ce.entity_rowid = e.rowid
            JOIN conversations c ON c.rowid = ce.conv_rowid
            GROUP BY e.rowid
            HAVING MIN(c.start_at) >= ?
               AND n <= (SELECT COUNT(*) FROM conversations) * ? + 1
            ORDER BY n DESC, e.text LIMIT ?;
            """, bind: { st in
                sqlite3_bind_double(st, 1, since.timeIntervalSince1970)
                sqlite3_bind_double(st, 2, Self.documentFrequencyCeiling)
                sqlite3_bind_int(st, 3, Int32(clamping: limit))
            }, row: { st in
                out.append(EntityStat(text: SQLiteDB.text(st, 0),
                                      kind: SQLiteDB.text(st, 1),
                                      conversationCount: Int(sqlite3_column_int(st, 2))))
            })
        }
        return out
    }

    /// 一天里开场对话的 6 个 4 小时段计数（本机时区，`[0-4, 4-8, …, 20-24)`）。
    /// 「你的作息指纹」——什么时段开工是用户自己给不出精确数字的画像。
    public func hourQuarterHistogram(from: Date = .distantPast, to: Date = .distantFuture) -> [Int] {
        var buckets = [Int](repeating: 0, count: 6)
        try? queue.sync {
            try db.query("""
            SELECT CAST(strftime('%H', start_at, 'unixepoch', 'localtime') AS INTEGER) / 4 AS q,
                   COUNT(*) FROM conversations
            WHERE start_at >= ? AND start_at < ? GROUP BY q;
            """, bind: { st in
                sqlite3_bind_double(st, 1, from.timeIntervalSince1970)
                sqlite3_bind_double(st, 2, to.timeIntervalSince1970)
            }, row: { st in
                let q = Int(sqlite3_column_int(st, 0))
                if (0..<6).contains(q) { buckets[q] = Int(sqlite3_column_int(st, 1)) }
            })
        }
        return buckets
    }

    /// 开场对话最多的一天（本机时区日期字符串 + 场数）。空库 nil。
    /// 会话数最多的一天。同时给出那天的消息总数——
    /// 只报场数会误导：真机上「最忙一天 58 场」里有 54 场是一下午的 1-6 条微会话，
    /// 那天 6027 条消息，比另一个只有 12 场的项目还少（2026-08-18 实测）。
    public func busiestDay(from: Date = .distantPast,
                           to: Date = .distantFuture) -> (day: String, count: Int, messages: Int)? {
        var out: (String, Int, Int)?
        try? queue.sync {
            try db.query("""
            SELECT date(start_at, 'unixepoch', 'localtime') AS d, COUNT(*) AS c,
                   COALESCE(SUM(message_count), 0) AS m
            FROM conversations WHERE start_at >= ? AND start_at < ?
            GROUP BY d ORDER BY c DESC, d LIMIT 1;
            """, bind: { st in
                sqlite3_bind_double(st, 1, from.timeIntervalSince1970)
                sqlite3_bind_double(st, 2, to.timeIntervalSince1970)
            }, row: { st in
                out = (SQLiteDB.text(st, 0), Int(sqlite3_column_int(st, 1)),
                       Int(sqlite3_column_int(st, 2)))
            })
        }
        return out
    }

    /// 单日项目并行度：每个活跃日 distinct cwd 数的均值与峰值（含峰值日期）。
    /// 独立开发者的上下文切换指纹。空库 avg=0、peak=nil。
    public func projectSwitching() -> (avgPerDay: Double, peak: (day: String, count: Int)?) {
        var avg = 0.0
        var peak: (String, Int)?
        try? queue.sync {
            try db.query("""
            SELECT AVG(n), MAX(n) FROM (
                SELECT date(start_at, 'unixepoch', 'localtime') AS d, COUNT(DISTINCT cwd) AS n
                FROM conversations WHERE cwd != '' GROUP BY d);
            """, bind: { _ in }, row: { st in
                avg = sqlite3_column_double(st, 0)
            })
            try db.query("""
            SELECT d, n FROM (
                SELECT date(start_at, 'unixepoch', 'localtime') AS d, COUNT(DISTINCT cwd) AS n
                FROM conversations WHERE cwd != '' GROUP BY d)
            ORDER BY n DESC, d LIMIT 1;
            """, bind: { _ in }, row: { st in
                peak = (SQLiteDB.text(st, 0), Int(sqlite3_column_int(st, 1)))
            })
        }
        return (avg, peak)
    }

    /// 语料体量：你打的字符总量（user_corpus）vs 对话全文字符总量（segments）。
    /// 「1 : N 杠杆率」——你的输入换回多少倍的工作量记录。
    public func corpusVolume(from: Date = .distantPast, to: Date = .distantFuture) -> (userChars: Int, totalChars: Int) {
        var user = 0, total = 0
        try? queue.sync {
            try db.query("""
            SELECT COALESCE(SUM(LENGTH(u.text)), 0) FROM user_corpus u
            JOIN conversations c ON c.rowid = u.conv_rowid
            WHERE c.start_at >= ? AND c.start_at < ?;
            """, bind: { st in
                sqlite3_bind_double(st, 1, from.timeIntervalSince1970)
                sqlite3_bind_double(st, 2, to.timeIntervalSince1970)
            }, row: { user = Int(sqlite3_column_int64($0, 0)) })
            try db.query("""
            SELECT COALESCE(SUM(LENGTH(s.text)), 0) FROM segments s
            JOIN conversations c ON c.rowid = s.conv_rowid
            WHERE c.start_at >= ? AND c.start_at < ?;
            """, bind: { st in
                sqlite3_bind_double(st, 1, from.timeIntervalSince1970)
                sqlite3_bind_double(st, 2, to.timeIntervalSince1970)
            }, row: { total = Int(sqlite3_column_int64($0, 0)) })
        }
        return (user, total)
    }

    /// 窗口内最早的一场对话——Wrapped「第一次对话考古」卡(两家官方都不敢引原文,
    /// 本地产品无此顾虑,这是空白点)。
    public func firstConversation(from: Date = .distantPast, to: Date = .distantFuture) -> UnfinishedThread? {
        var out: UnfinishedThread?
        try? queue.sync {
            try db.query("""
            SELECT id, title, preview, cwd, start_at FROM conversations
            WHERE start_at >= ? AND start_at < ?
            ORDER BY start_at LIMIT 1;
            """, bind: { st in
                sqlite3_bind_double(st, 1, from.timeIntervalSince1970)
                sqlite3_bind_double(st, 2, to.timeIntervalSince1970)
            }, row: { st in
                let title = sqlite3_column_type(st, 1) == SQLITE_NULL ? nil : SQLiteDB.text(st, 1)
                out = UnfinishedThread(id: SQLiteDB.text(st, 0), title: title,
                                       preview: SQLiteDB.text(st, 2), cwd: SQLiteDB.text(st, 3),
                                       endAt: Date(timeIntervalSince1970: sqlite3_column_double(st, 4)))
            })
        }
        return out
    }

    /// 马拉松对话：按消息数降序 top-N。`spanHours` 是首末时间差——被反复 resume 的
    /// 会话可能跨几十天，渲染侧按大小换算成「跨 N 天」。
    public struct Marathon: Equatable {
        public let id: String
        public let title: String?
        public let preview: String
        public let cwd: String
        public let messageCount: Int
        public let spanHours: Double
    }

    public func marathons(limit: Int) -> [Marathon] {
        var out: [Marathon] = []
        try? queue.sync {
            try db.query("""
            SELECT id, title, preview, cwd, message_count, (end_at - start_at) / 3600.0
            FROM conversations ORDER BY message_count DESC, id LIMIT ?;
            """, bind: { sqlite3_bind_int($0, 1, Int32(clamping: limit)) }, row: { st in
                let title = sqlite3_column_type(st, 1) == SQLITE_NULL ? nil : SQLiteDB.text(st, 1)
                out.append(Marathon(id: SQLiteDB.text(st, 0), title: title,
                                    preview: SQLiteDB.text(st, 2), cwd: SQLiteDB.text(st, 3),
                                    messageCount: Int(sqlite3_column_int(st, 4)),
                                    spanHours: sqlite3_column_double(st, 5)))
            })
        }
        return out
    }

    /// 全量用户语料三元组(text/convID/startAt)——build 收尾的唯一拉取口:
    /// 此前 catchphrases/fadedWords/repeatedBriefings 各拉一份全量语料,
    /// 峰值三倍叠加(2026-08-13 内存优化);消费者用 map 派生形状,String COW
    /// 只拷引用不拷字符。
    public func userCorpusRows() -> [(text: String, convID: String, cwd: String, startAt: Date)] {
        var out: [(String, String, String, Date)] = []
        try? queue.sync {
            try db.query("""
            SELECT u.text, c.id, c.cwd, c.start_at FROM user_corpus u
            JOIN conversations c ON c.rowid = u.conv_rowid
            WHERE u.text != '';
            """, bind: { _ in }, row: { st in
                out.append((SQLiteDB.text(st, 0), SQLiteDB.text(st, 1), SQLiteDB.text(st, 2),
                            Date(timeIntervalSince1970: sqlite3_column_double(st, 3))))
            })
        }
        return out
    }

    /// 全部会话的用户语料带会话 id(REPEATED BRIEFINGS 聚类需要跨会话归属)。跳过空串。
    public func userCorpusWithConvIDs() -> [(text: String, convID: String)] {
        var out: [(String, String)] = []
        try? queue.sync {
            try db.query("""
            SELECT u.text, c.id FROM user_corpus u
            JOIN conversations c ON c.rowid = u.conv_rowid
            WHERE u.text != '';
            """, bind: { _ in }, row: { st in
                out.append((SQLiteDB.text(st, 0), SQLiteDB.text(st, 1)))
            })
        }
        return out
    }

    /// 全部会话的用户语料带开场时间（FADED WORDS 需要词的时间分布）。跳过空串。
    public func userCorpusWithDates() -> [(text: String, startAt: Date)] {
        var out: [(String, Date)] = []
        try? queue.sync {
            try db.query("""
            SELECT u.text, c.start_at FROM user_corpus u
            JOIN conversations c ON c.rowid = u.conv_rowid
            WHERE u.text != '';
            """, bind: { _ in }, row: { st in
                out.append((SQLiteDB.text(st, 0),
                            Date(timeIntervalSince1970: sqlite3_column_double(st, 1))))
            })
        }
        return out
    }

    /// 近 `days` 天每日会话数（本机时区日期字符串,只含有会话的日子）——活跃热力图用。
    public func dailyCounts(days: Int, now: Date) -> [(day: String, count: Int)] {
        var out: [(String, Int)] = []
        let since = now.addingTimeInterval(-Double(days) * 86_400)
        try? queue.sync {
            try db.query("""
            SELECT date(start_at, 'unixepoch', 'localtime') AS d, COUNT(*) AS c
            FROM conversations WHERE start_at >= ? GROUP BY d ORDER BY d;
            """, bind: { sqlite3_bind_double($0, 1, since.timeIntervalSince1970) }, row: { st in
                out.append((SQLiteDB.text(st, 0), Int(sqlite3_column_int(st, 1))))
            })
        }
        return out
    }

    // MARK: - 可视化数据(2026-08-12 可视化方案:24 格节律 / 周几分布)

    /// 24 小时开场分布(本机时区)——节律条带图用(线性 24 格,调研否决了径向钟面)。
    public func hourHistogram24(from: Date = .distantPast, to: Date = .distantFuture) -> [Int] {
        var buckets = [Int](repeating: 0, count: 24)
        try? queue.sync {
            try db.query("""
            SELECT CAST(strftime('%H', start_at, 'unixepoch', 'localtime') AS INTEGER) AS h,
                   COUNT(*) FROM conversations
            WHERE start_at >= ? AND start_at < ? GROUP BY h;
            """, bind: { st in
                sqlite3_bind_double(st, 1, from.timeIntervalSince1970)
                sqlite3_bind_double(st, 2, to.timeIntervalSince1970)
            }, row: { st in
                let h = Int(sqlite3_column_int(st, 0))
                if (0..<24).contains(h) { buckets[h] = Int(sqlite3_column_int(st, 1)) }
            })
        }
        return buckets
    }

    /// 周几开场分布(周一=0 … 周日=6,本机时区)——周几 7 柱图用。
    public func weekdayHistogram() -> [Int] {
        var buckets = [Int](repeating: 0, count: 7)
        try? queue.sync {
            try db.query("""
            SELECT (CAST(strftime('%w', start_at, 'unixepoch', 'localtime') AS INTEGER) + 6) % 7 AS d,
                   COUNT(*) FROM conversations GROUP BY d;
            """, bind: { _ in }, row: { st in
                let d = Int(sqlite3_column_int(st, 0))
                if (0..<7).contains(d) { buckets[d] = Int(sqlite3_column_int(st, 1)) }
            })
        }
        return buckets
    }

    // MARK: - 第五批:守护状态(价值感调研 2026-08-12 落地——免于失去的实证)

    /// 保管所状态:总量/库龄/越线会话数/最近收录。
    /// 「越线」= claudeCode 会话已超过官方 30 天本地清理窗口、但仍在库——
    /// 「工具删它的,你的还在」从口号变成一个可数的数字。
    public struct SanctuaryStats: Equatable {
        public let conversationCount: Int
        public let earliest: Date?
        public let latestActivity: Date?
        public let outlivedClaudeCode: Int
        public init(conversationCount: Int, earliest: Date?, latestActivity: Date?, outlivedClaudeCode: Int) {
            self.conversationCount = conversationCount; self.earliest = earliest
            self.latestActivity = latestActivity; self.outlivedClaudeCode = outlivedClaudeCode
        }
    }

    public func sanctuaryStats(now: Date) -> SanctuaryStats {
        var count = 0
        var earliest: Date?
        var latest: Date?
        var outlived = 0
        try? queue.sync {
            try db.query("""
            SELECT COUNT(*), MIN(start_at), MAX(end_at),
                   SUM(CASE WHEN source = 'claudeCode' AND start_at < ? THEN 1 ELSE 0 END)
            FROM conversations;
            """, bind: { st in
                sqlite3_bind_double(st, 1, now.addingTimeInterval(-30 * 86_400).timeIntervalSince1970)
            }, row: { st in
                count = Int(sqlite3_column_int(st, 0))
                if count > 0 {
                    earliest = Date(timeIntervalSince1970: sqlite3_column_double(st, 1))
                    latest = Date(timeIntervalSince1970: sqlite3_column_double(st, 2))
                }
                outlived = Int(sqlite3_column_int(st, 3))
            })
        }
        return SanctuaryStats(conversationCount: count, earliest: earliest,
                              latestActivity: latest, outlivedClaudeCode: outlived)
    }

    // MARK: - 第四批惊喜区查询(结构维度:怎么交互;关系维度:项目之间)

    /// 协作形状:轮次分布(user 消息数 4 桶)+ 时长分布(4 桶)+ 每条 user 消息平均字数。
    /// 结构信号做 Reflect 用 LLM 做的事——「你不是问答用户,是共事用户」用形状可证。
    /// user 轮数 = user_corpus 的行数(userText 按 \n 连接,每行一条 user 消息)。
    public struct CollaborationShape: Equatable {
        public let turnBands: [Int]       // [1-2, 3-5, 6-15, 16+] 会话数
        public let durationBands: [Int]   // [<2min, 2-30min, 0.5-2h, 2h+] 会话数
        public let avgCharsPerMessage: Int
        public init(turnBands: [Int], durationBands: [Int], avgCharsPerMessage: Int) {
            self.turnBands = turnBands; self.durationBands = durationBands
            self.avgCharsPerMessage = avgCharsPerMessage
        }
    }

    public func collaborationShape() -> CollaborationShape {
        var turns = [0, 0, 0, 0]
        var durations = [0, 0, 0, 0]
        var totalChars = 0, totalMsgs = 0
        try? queue.sync {
            try db.query("""
            SELECT (LENGTH(u.text) - LENGTH(REPLACE(u.text, char(10), '')) + 1) AS t,
                   LENGTH(u.text) AS chars, c.end_at - c.start_at AS dur
            FROM user_corpus u JOIN conversations c ON c.rowid = u.conv_rowid
            WHERE u.text != '';
            """, bind: { _ in }, row: { st in
                let t = Int(sqlite3_column_int(st, 0))
                let chars = Int(sqlite3_column_int(st, 1))
                let dur = sqlite3_column_double(st, 2)
                switch t { case ...2: turns[0] += 1; case 3...5: turns[1] += 1
                           case 6...15: turns[2] += 1; default: turns[3] += 1 }
                switch dur { case ..<120: durations[0] += 1; case ..<1_800: durations[1] += 1
                             case ..<7_200: durations[2] += 1; default: durations[3] += 1 }
                totalChars += chars; totalMsgs += t
            })
        }
        return CollaborationShape(turnBands: turns, durationBands: durations,
                                  avgCharsPerMessage: totalMsgs > 0 ? totalChars / totalMsgs : 0)
    }

    /// 周末人格:周末(六/日)与工作日各自的项目分布(尾名,按会话数降序)。
    /// 真实库现场:工作日 9 个项目、周末只有 mindbus——「周末只属于你的 side project」。
    public func weekendSplit(minCount: Int) -> (weekday: [FacetCount], weekend: [FacetCount]) {
        var wd: [FacetCount] = []
        var we: [FacetCount] = []
        try? queue.sync {
            try db.query("""
            SELECT CASE WHEN strftime('%w', start_at, 'unixepoch', 'localtime') IN ('0','6')
                        THEN 1 ELSE 0 END AS wk, cwd, COUNT(*) AS c
            FROM conversations WHERE cwd != ''
            GROUP BY wk, cwd HAVING c >= ? ORDER BY c DESC;
            """, bind: { sqlite3_bind_int($0, 1, Int32(clamping: minCount)) }, row: { st in
                let cwd = SQLiteDB.text(st, 1)
                // 家目录/工具缓存不是项目——政策在 MindsBuilder,这里只照着问。
                // 漏了这道过滤会出现「项目节奏里没有家目录、周末人格里却有 home」
                guard MindsBuilder.isRealProject(cwd) else { return }
                let tail = MindsBuilder.friendlyProjectTail((cwd as NSString).lastPathComponent)
                let fc = FacetCount(key: tail, count: Int(sqlite3_column_int(st, 2)))
                if sqlite3_column_int(st, 0) == 1 { we.append(fc) } else { wd.append(fc) }
            })
        }
        return (weekday: wd, weekend: we)
    }

    /// 项目级杠杆率:每个项目(≥minConversations 场)你打的字 vs 对话总量。
    /// 真实库现场:项目间差 20 倍(1:2 到 1:45)——「哪个项目最省你的话」。
    public struct ProjectLeverage: Equatable {
        public let name: String
        public let userChars: Int
        public let totalChars: Int
        public let conversationCount: Int
        public var ratio: Int { userChars > 0 ? totalChars / userChars : 0 }
        public init(name: String, userChars: Int, totalChars: Int, conversationCount: Int) {
            self.name = name; self.userChars = userChars
            self.totalChars = totalChars; self.conversationCount = conversationCount
        }
    }

    public func projectLeverage(minConversations: Int, limit: Int) -> [ProjectLeverage] {
        var out: [ProjectLeverage] = []
        try? queue.sync {
            try db.query("""
            SELECT c.cwd, SUM(LENGTH(u.text)) AS ut,
                   (SELECT COALESCE(SUM(LENGTH(s.text)), 0) FROM segments s
                    JOIN conversations c2 ON c2.rowid = s.conv_rowid WHERE c2.cwd = c.cwd) AS tt,
                   COUNT(*) AS n
            FROM user_corpus u JOIN conversations c ON c.rowid = u.conv_rowid
            WHERE c.cwd != ''
            GROUP BY c.cwd HAVING n >= ? AND ut > 0
            ORDER BY n DESC LIMIT ?;
            """, bind: { st in
                sqlite3_bind_int(st, 1, Int32(clamping: minConversations))
                sqlite3_bind_int(st, 2, Int32(clamping: limit))
            }, row: { st in
                let cwd = SQLiteDB.text(st, 0)
                guard MindsBuilder.isRealProject(cwd) else { return }
                out.append(ProjectLeverage(
                    name: MindsBuilder.friendlyProjectTail((cwd as NSString).lastPathComponent),
                    userChars: Int(sqlite3_column_int64(st, 1)),
                    totalChars: Int(sqlite3_column_int64(st, 2)),
                    conversationCount: Int(sqlite3_column_int(st, 3))))
            })
        }
        return out
    }

    /// 跨项目的标识符实体（技术名词候选）。
    ///
    /// 存在理由：个人词表只挖中文——`PersonalLexicon` 遇到非 CJK 字符就断开 run，
    /// 真机上「含拉丁字母的词」恒为 0 个。于是 GitHub 这类词在「常用词」里
    /// 永远不会出现，哪怕用户自己说了 160 次、覆盖 33 场对话。
    ///
    /// 判据沿用 Minds 一直在用的那条：**跨项目才是「跟着你走的词」**。
    /// 真机对照：GitHub 跨 28 个项目，而 NodeNext 说了 48 次却只跨 2 个项目
    /// （那是某个项目内部的配置值，不是这个人的口头词）。
    public func crossProjectIdentifiers(minProjects: Int, limit: Int) -> [(text: String, projects: Int)] {
        var out: [(String, Int)] = []
        try? queue.sync {
            try db.query("""
            SELECT e.text, COUNT(DISTINCT c.cwd) AS p
            FROM entities e
            JOIN conversation_entities ce ON ce.entity_rowid = e.rowid
            JOIN conversations c ON c.rowid = ce.conv_rowid
            WHERE e.kind = 'identifier' AND c.cwd != ''
            GROUP BY e.rowid HAVING p >= ? ORDER BY p DESC LIMIT ?;
            """, bind: { st in
                sqlite3_bind_int(st, 1, Int32(clamping: minProjects))
                sqlite3_bind_int(st, 2, Int32(clamping: limit))
            }, row: { st in
                out.append((SQLiteDB.text(st, 0), Int(sqlite3_column_int(st, 1))))
            })
        }
        return out
    }

    /// 知识流动:共享实体最多的项目对。你的项目不是孤岛——
    /// 真实库现场:ResearchKit↔mindbus 共享 87 个概念。
    public struct KnowledgeFlow: Equatable {
        public let projectA: String
        public let projectB: String
        public let sharedEntities: Int
        /// 首现时序:共享实体里「先出现在 A」与「先出现在 B」的个数——
        /// 「知识从哪流向哪」的机械口径(同刻首现两边都不计)。
        public let bornInAFirst: Int
        public let bornInBFirst: Int
        public init(projectA: String, projectB: String, sharedEntities: Int,
                    bornInAFirst: Int = 0, bornInBFirst: Int = 0) {
            self.projectA = projectA; self.projectB = projectB; self.sharedEntities = sharedEntities
            self.bornInAFirst = bornInAFirst; self.bornInBFirst = bornInBFirst
        }
    }

    public func knowledgeFlows(minShared: Int, limit: Int) -> [KnowledgeFlow] {
        var out: [KnowledgeFlow] = []
        try? queue.sync {
            // firsts:每个(实体,项目)的首现时间——方向 = 首现孰早(补全原「无向共享」)
            try db.query("""
            WITH firsts AS (
                SELECT ce.entity_rowid AS e, c.cwd AS cwd, MIN(c.start_at) AS fa
                FROM conversation_entities ce
                JOIN conversations c ON c.rowid = ce.conv_rowid
                WHERE c.cwd != ''
                GROUP BY ce.entity_rowid, c.cwd
            )
            SELECT a.cwd, b.cwd, COUNT(*) AS shared,
                   SUM(CASE WHEN a.fa < b.fa THEN 1 ELSE 0 END) AS ab,
                   SUM(CASE WHEN b.fa < a.fa THEN 1 ELSE 0 END) AS ba
            FROM firsts a JOIN firsts b ON a.e = b.e AND a.cwd < b.cwd
            GROUP BY a.cwd, b.cwd HAVING shared >= ?
            ORDER BY shared DESC LIMIT ?;
            """, bind: { st in
                sqlite3_bind_int(st, 1, Int32(clamping: minShared))
                sqlite3_bind_int(st, 2, Int32(clamping: limit))
            }, row: { st in
                out.append(KnowledgeFlow(
                    projectA: MindsBuilder.friendlyProjectTail((SQLiteDB.text(st, 0) as NSString).lastPathComponent),
                    projectB: MindsBuilder.friendlyProjectTail((SQLiteDB.text(st, 1) as NSString).lastPathComponent),
                    sharedEntities: Int(sqlite3_column_int(st, 2)),
                    bornInAFirst: Int(sqlite3_column_int(st, 3)),
                    bornInBFirst: Int(sqlite3_column_int(st, 4))))
            })
        }
        return out
    }

    /// 项目出生句:每个项目最早会话的 user 语料(供取「第一句话」)。
    /// 「mindbus 出生于:『目前的项目状态是什么』」——每个项目的创世句是
    /// 叙事锚点(数据+具体时刻+身份叙事),且真实到无法编造。
    public func projectFirstCorpus(limit: Int) -> [(tail: String, text: String, convID: String, startAt: Date)] {
        var out: [(String, String, String, Date)] = []
        try? queue.sync {
            try db.query("""
            WITH firsts AS (
                SELECT cwd, MIN(start_at) AS fa FROM conversations
                WHERE cwd != '' AND cwd NOT LIKE '%/.claude/%'
                GROUP BY cwd
                ORDER BY (SELECT COUNT(*) FROM conversations c2 WHERE c2.cwd = conversations.cwd) DESC
                LIMIT ?
            )
            SELECT c.cwd, COALESCE(u.text, ''), c.id, c.start_at
            FROM firsts f
            JOIN conversations c ON c.cwd = f.cwd AND c.start_at = f.fa
            LEFT JOIN user_corpus u ON u.conv_rowid = c.rowid;
            """, bind: { sqlite3_bind_int($0, 1, Int32(clamping: limit)) }, row: { st in
                out.append(((SQLiteDB.text(st, 0) as NSString).lastPathComponent,
                            SQLiteDB.text(st, 1), SQLiteDB.text(st, 2),
                            Date(timeIntervalSince1970: sqlite3_column_double(st, 3))))
            })
        }
        return out
    }

    /// 按自然周(本机时区,ISO 周一起始)聚合的会话数,升序。个人史百分位用——
    /// 「本周对话量在你自己历史的第几分位」(Savant 滑条工艺,分布只用自己的历史)。
    public func weeklyCounts() -> [(week: String, count: Int)] {
        var out: [(String, Int)] = []
        try? queue.sync {
            try db.query("""
            SELECT strftime('%Y-%W', start_at, 'unixepoch', 'localtime') AS w, COUNT(*)
            FROM conversations GROUP BY w ORDER BY w;
            """, bind: { _ in }, row: { st in
                out.append((SQLiteDB.text(st, 0), Int(sqlite3_column_int(st, 1))))
            })
        }
        return out
    }

    /// 某月(本机时区,`yyyy-MM`)的会话总数——同比对比用(去年同月)。
    public func monthTotal(yearMonth: String) -> Int {
        var n = 0
        try? queue.sync {
            try db.query("""
            SELECT COUNT(*) FROM conversations
            WHERE strftime('%Y-%m', start_at, 'unixepoch', 'localtime') = ?;
            """, bind: { SQLiteDB.bindText($0, 1, yearMonth) },
                 row: { n = Int(sqlite3_column_int($0, 0)) })
        }
        return n
    }

    /// 某个本机时区日期(`yyyy-MM-dd`)开场的全部会话——热力图格子点击下钻用
    /// (「统计是入口不是装饰」:每个数字都能点到原始对话)。
    public func conversationsOn(day: String, limit: Int = 20) -> [UnfinishedThread] {
        var out: [UnfinishedThread] = []
        try? queue.sync {
            try db.query("""
            SELECT id, title, preview, cwd, start_at FROM conversations
            WHERE date(start_at, 'unixepoch', 'localtime') = ?
            ORDER BY start_at LIMIT ?;
            """, bind: { st in
                SQLiteDB.bindText(st, 1, day)
                sqlite3_bind_int(st, 2, Int32(clamping: limit))
            }, row: { st in
                let title = sqlite3_column_type(st, 1) == SQLITE_NULL ? nil : SQLiteDB.text(st, 1)
                out.append(UnfinishedThread(id: SQLiteDB.text(st, 0), title: title,
                                            preview: SQLiteDB.text(st, 2), cwd: SQLiteDB.text(st, 3),
                                            endAt: Date(timeIntervalSince1970: sqlite3_column_double(st, 4))))
            })
        }
        return out
    }

    /// 往月今日：历史上**同日号**开场的会话（排除近 `minAgeDays` 天——「今天的今天」
    /// 不算重逢）。Day One / Apple 照片验证过的机制：今天的日期给旧对话一个被重看的理由。
    /// 用日号而非「同月同日」：跨年匹配对只有几个月历史的库永远为空（2026-08-12 真实
    /// 数据现场:4 个月历史 0 命中）,「三个月前的今天」的重逢感同样成立且立即可用;
    /// 等库满几年,最早的年份自然浮上来——语义随数据量平滑升级,不用改口径。
    public func onThisDay(monthDay: String, minAgeDays: Int, now: Date, limit: Int) -> [UnfinishedThread] {
        var out: [UnfinishedThread] = []
        let cutoff = now.addingTimeInterval(-Double(minAgeDays) * 86_400)
        let dayOfMonth = monthDay.contains("-") ? String(monthDay.split(separator: "-").last ?? "") : monthDay
        try? queue.sync {
            try db.query("""
            SELECT id, title, preview, cwd, start_at FROM conversations
            WHERE strftime('%d', start_at, 'unixepoch', 'localtime') = ?
              AND start_at < ?
            ORDER BY start_at DESC LIMIT ?;
            """, bind: { st in
                SQLiteDB.bindText(st, 1, dayOfMonth)
                sqlite3_bind_double(st, 2, cutoff.timeIntervalSince1970)
                sqlite3_bind_int(st, 3, Int32(clamping: limit))
            }, row: { st in
                let title = sqlite3_column_type(st, 1) == SQLITE_NULL ? nil : SQLiteDB.text(st, 1)
                out.append(UnfinishedThread(id: SQLiteDB.text(st, 0), title: title,
                                            preview: SQLiteDB.text(st, 2), cwd: SQLiteDB.text(st, 3),
                                            endAt: Date(timeIntervalSince1970: sqlite3_column_double(st, 4))))
            })
        }
        return out
    }

    /// 深夜（0-6 点开场）里时刻最晚的一场——「X 月 X 日凌晨 3:47 你还开了一场对话」。
    /// 微信读书「年度最晚阅读时间」的对话版：精确到分钟的个人史证据。
    public func latestNightConversation() -> (thread: UnfinishedThread, clock: String)? {
        var out: (UnfinishedThread, String)?
        try? queue.sync {
            try db.query("""
            SELECT id, title, preview, cwd, start_at,
                   strftime('%H:%M', start_at, 'unixepoch', 'localtime') AS hm
            FROM conversations
            WHERE CAST(strftime('%H', start_at, 'unixepoch', 'localtime') AS INTEGER) < 6
            ORDER BY hm DESC LIMIT 1;
            """, bind: { _ in }, row: { st in
                let title = sqlite3_column_type(st, 1) == SQLITE_NULL ? nil : SQLiteDB.text(st, 1)
                out = (UnfinishedThread(id: SQLiteDB.text(st, 0), title: title,
                                        preview: SQLiteDB.text(st, 2), cwd: SQLiteDB.text(st, 3),
                                        endAt: Date(timeIntervalSince1970: sqlite3_column_double(st, 4))),
                       SQLiteDB.text(st, 5))
            })
        }
        return out
    }

    /// 一次性话题：只出现在**一个**会话里、且那场会话已是 `minAgeDays` 天前的实体。
    /// 「你只问过一次、再没回来的问题」——独特性指标（PS 最稀有奖杯的对话版），
    /// 样板压制不需要（df=1 天然不是样板）。按会话时间降序取样。
    public func oneOffTopics(minAgeDays: Int, now: Date, limit: Int) -> [(text: String, at: Date)] {
        var out: [(String, Date)] = []
        let cutoff = now.addingTimeInterval(-Double(minAgeDays) * 86_400)
        try? queue.sync {
            try db.query("""
            SELECT e.text, MAX(c.start_at) AS at FROM entities e
            JOIN conversation_entities ce ON ce.entity_rowid = e.rowid
            JOIN conversations c ON c.rowid = ce.conv_rowid
            GROUP BY e.rowid
            HAVING COUNT(ce.conv_rowid) = 1 AND at < ?
            ORDER BY at DESC LIMIT ?;
            """, bind: { st in
                sqlite3_bind_double(st, 1, cutoff.timeIntervalSince1970)
                sqlite3_bind_int(st, 2, Int32(clamping: limit))
            }, row: { st in
                out.append((SQLiteDB.text(st, 0),
                            Date(timeIntervalSince1970: sqlite3_column_double(st, 1))))
            })
        }
        return out
    }

    /// 时间窗内按工具的会话数（`start_at ∈ [from, to)`），降序——月度工具份额对比用。
    public func sourceCounts(from: Date, to: Date) -> [FacetCount] {
        var out: [FacetCount] = []
        try? queue.sync {
            try db.query("""
            SELECT source, COUNT(*) AS n FROM conversations
            WHERE start_at >= ? AND start_at < ?
            GROUP BY source ORDER BY n DESC, source;
            """, bind: { st in
                sqlite3_bind_double(st, 1, from.timeIntervalSince1970)
                sqlite3_bind_double(st, 2, to.timeIntervalSince1970)
            }, row: { st in
                out.append(FacetCount(key: SQLiteDB.text(st, 0), count: Int(sqlite3_column_int(st, 1))))
            })
        }
        return out
    }

    /// 提到该实体的会话 id，按最近活跃降序。**不加文档频率限制**——用户已经主动点了
    /// 这个实体，压制只影响「推荐哪些实体值得点」，不该影响点了之后给不给结果。
    public func conversations(withEntity text: String) -> [String] {
        var out: [String] = []
        try? queue.sync {
            try db.query("""
            SELECT c.id FROM conversations c
            JOIN conversation_entities ce ON ce.conv_rowid = c.rowid
            JOIN entities e ON e.rowid = ce.entity_rowid
            WHERE e.text = ? ORDER BY c.end_at DESC;
            """, bind: { SQLiteDB.bindText($0, 1, text) },
                 row: { out.append(SQLiteDB.text($0, 0)) })
        }
        return out
    }

    /// 与该实体在同一会话里共同出现过的其他实体，按共现会话数降序。
    /// 共现走 self-join 而非物化表：一张 N² 的共现计数表在实体量上万时膨胀极快，
    /// 而这里的查询就是一次 self-join，代价远低于维护一张随每次 upsert 更新的表。
    /// HAVING 复用了与 `topEntities` 同一条阈值表达式，但压的量不是一回事：这里的
    /// n 是「与 e1 共现的会话数」，不是 e2 的全局文档频率——n ≤ min(DF(e1), DF(e2))，
    /// 是比直接卡 DF(e2) 更弱的上界（e2 本身再高频，只要它和 e1 凑一块儿的次数不多，
    /// 一样能通过）。这里不是 `topEntities` 那种精确的样板实体过滤，只是同一套阈值
    /// 表达式顺带压掉了共现计数本身过于泛滥的结果；真正治样板实体的是抽取侧
    /// 跳过 `.toolUse`（见 `Segmenter.entityText`），这里不必再改 SQL 语义。
    public func coOccurring(with text: String, limit: Int) -> [EntityStat] {
        var out: [EntityStat] = []
        try? queue.sync {
            try db.query("""
            SELECT e2.text, e2.kind, COUNT(*) AS n
            FROM entities e1
            JOIN conversation_entities a ON a.entity_rowid = e1.rowid
            JOIN conversation_entities b ON b.conv_rowid = a.conv_rowid
            JOIN entities e2 ON e2.rowid = b.entity_rowid
            WHERE e1.text = ? AND e2.rowid != e1.rowid
            GROUP BY e2.rowid
            HAVING n <= (SELECT COUNT(*) FROM conversations) * ? + 1
            ORDER BY n DESC, e2.text LIMIT ?;
            """, bind: { st in
                SQLiteDB.bindText(st, 1, text)
                sqlite3_bind_double(st, 2, Self.documentFrequencyCeiling)
                sqlite3_bind_int(st, 3, Int32(clamping: limit))
            }, row: { st in
                out.append(EntityStat(text: SQLiteDB.text(st, 0),
                                      kind: SQLiteDB.text(st, 1),
                                      conversationCount: Int(sqlite3_column_int(st, 2))))
            })
        }
        return out
    }

    /// 一场会话关联的实体，按**全库文档频率升序**（最稀有 = 最有辨识度的在前）——
    /// 与 `topEntities`/`coOccurring`「复现越多越重要」正相反：`memory_digest` 要给宿主
    /// 模型的是「一眼认出这是哪场对话」的线索，出现在几乎所有会话里的样板词
    /// （如 `file_path` 这类工具参数名）反而是噪音，理应排到最后甚至被压制掉。
    ///
    /// `conversationCount` 字段填的是该实体的**全库** DF（与 `topEntities`/`coOccurring`
    /// 同一口径），不是「在这场会话里出现几次」——contentless 索引本就不记后者，
    /// 且 `conversation_entities` 的复合主键保证同一会话同一实体只有一行。
    ///
    /// SQL 与 `topEntities`/`coOccurring` 同款样板压制（`documentFrequencyCeiling`），
    /// 但不能照抄那两处「HAVING 引用聚合别名」的写法直接搬到 WHERE 上——SQLite 的
    /// WHERE 子句不能引用同一 SELECT 里的输出列别名（`df`，此处 WHERE 求值先于
    /// 输出列表求值）。改用 GROUP BY e.rowid 让阈值判断挪进 HAVING（HAVING 在输出列
    /// 之后求值，可以引用别名，与 `topEntities`/`coOccurring` 同一手法）；GROUP BY 不
    /// 改变结果集——`conversations.id` UNIQUE 保证 `c.id = ?` 最多命中一行，
    /// `conversation_entities` 的复合主键保证每个 `entity_rowid` 在该会话下最多出现
    /// 一次，所以每个分组天然只有一行，不存在「同组多行、SQLite 任选一行」的歧义。
    ///
    /// 未知 id 自然返回空数组（`WHERE c.id = ?` 零命中，不需要单独判空）。
    public func entities(forConversationID id: String, limit: Int) -> [EntityStat] {
        var out: [EntityStat] = []
        try? queue.sync {
            try db.query("""
            SELECT e.text, e.kind,
                   (SELECT COUNT(*) FROM conversation_entities x WHERE x.entity_rowid = e.rowid) AS df
            FROM conversations c
            JOIN conversation_entities ce ON ce.conv_rowid = c.rowid
            JOIN entities e ON e.rowid = ce.entity_rowid
            WHERE c.id = ?
            GROUP BY e.rowid
            HAVING df <= (SELECT COUNT(*) FROM conversations) * ? + 1
            ORDER BY df ASC, e.text LIMIT ?;
            """, bind: { st in
                SQLiteDB.bindText(st, 1, id)
                sqlite3_bind_double(st, 2, Self.documentFrequencyCeiling)
                sqlite3_bind_int(st, 3, Int32(clamping: limit))
            }, row: { st in
                out.append(EntityStat(text: SQLiteDB.text(st, 0),
                                      kind: SQLiteDB.text(st, 1),
                                      conversationCount: Int(sqlite3_column_int(st, 2))))
            })
        }
        return out
    }

    /// 一个切面维度上的一个取值 + 会话数，如「claudeCode → 812」「2026-08 → 63」。
    public struct FacetCount: Equatable {
        public let key: String      // 源名 / 项目路径 / "2026-08"
        public let count: Int
        public init(key: String, count: Int) { self.key = key; self.count = count }
    }

    /// L0 地图的全部数据：会话总数、时间跨度、按工具/项目/月份三个正交切面、Top 实体。
    /// 全是 group-by + count 的直接结果，不建物化表——几千行的 conversations 表上是毫秒级
    /// 查询，物化表要在每次 upsert/prune 时维护，多一条会漂移的真相。
    public struct MapOverview {
        public let conversationCount: Int
        public let earliest: Date?
        public let latest: Date?
        public let bySource: [FacetCount]     // 按工具，降序
        public let byProject: [FacetCount]    // 按 cwd，降序，取前 20
        public let byMonth: [FacetCount]      // 按月，时间升序
        public let topEntities: [EntityStat]  // 取前 20
    }

    /// 月份分桶表达式。地图与切面页共用，改一处两处同时变。
    ///
    /// start_at 存的是 Unix 时间戳（REAL），转月份必须带 'unixepoch' 修饰符；
    /// 还要再带 'localtime'——不带的话 strftime 按 UTC 切月，跨月边界附近的会话
    /// （比如本地时间 8 月 1 日凌晨、UTC 仍是 7 月 31 日）会被错误地并入上个月，
    /// 「这个月聊了什么」这类月度切面本该按用户感知的本地日历月分桶。
    ///
    /// 按**开始**时间而非结束时间分桶：一场对话属于它开始的那个月（跨月续聊的会话
    /// 归到动手那个月更符合「我几月在忙这个」的直觉）。地图与切面页共用这一个常量，
    /// 两处各写一遍就会在跨月会话上给出打架的计数。
    private static let monthBucketSQL = "strftime('%Y-%m', start_at, 'unixepoch', 'localtime')"

    /// L0 地图的全部数据：会话总数、时间跨度、按工具/项目/月份三个正交切面、Top 实体。
    /// 全部来自 group-by 与 count，零模型参与——这正是「机器递原料、判断交给读的那个模型」。
    public func mapOverview() -> MapOverview {
        var count = 0
        var earliest: Date?
        var latest: Date?
        var bySource: [FacetCount] = []
        var byProject: [FacetCount] = []
        var byMonth: [FacetCount] = []
        try? queue.sync {
            try db.query("SELECT COUNT(*), MIN(start_at), MAX(end_at) FROM conversations;",
                         bind: { _ in }, row: { st in
                count = Int(sqlite3_column_int(st, 0))
                // 空库时 MIN/MAX 是 NULL，不能直接当 0 读成 1970 年
                if sqlite3_column_type(st, 1) != SQLITE_NULL {
                    earliest = Date(timeIntervalSince1970: sqlite3_column_double(st, 1))
                    latest = Date(timeIntervalSince1970: sqlite3_column_double(st, 2))
                }
            })
            try db.query("SELECT source, COUNT(*) AS n FROM conversations GROUP BY source ORDER BY n DESC;",
                         bind: { _ in }, row: { st in
                bySource.append(FacetCount(key: SQLiteDB.text(st, 0), count: Int(sqlite3_column_int(st, 1))))
            })
            try db.query("""
            SELECT cwd, COUNT(*) AS n FROM conversations
            WHERE cwd != '' AND cwd NOT LIKE '%/.claude/%'
            GROUP BY cwd ORDER BY n DESC LIMIT 20;
            """, bind: { _ in }, row: { st in
                byProject.append(FacetCount(key: SQLiteDB.text(st, 0), count: Int(sqlite3_column_int(st, 1))))
            })
            try db.query("""
            SELECT \(Self.monthBucketSQL) AS m, COUNT(*) AS n
            FROM conversations GROUP BY m ORDER BY m;
            """, bind: { _ in }, row: { st in
                byMonth.append(FacetCount(key: SQLiteDB.text(st, 0), count: Int(sqlite3_column_int(st, 1))))
            })
        }
        // topEntities 内部自己会 queue.sync，必须在上面那个 queue.sync 块之外调用——
        // 在串行队列里再 sync 同一个队列是死锁。
        return MapOverview(conversationCount: count, earliest: earliest, latest: latest,
                           bySource: bySource, byProject: byProject, byMonth: byMonth,
                           topEntities: topEntities(limit: 20))
    }

    /// 一个切面取值。`month` 是 `"YYYY-MM"`，`project` 是会话的 `cwd` 原样全等匹配。
    public enum Facet: Equatable {
        case source(ConversationSource)
        case project(String)
        case month(String)
        case entity(String)
    }

    /// 该切面下的会话 id，按最近活跃降序，最多 `limit` 条。
    ///
    /// 月份用的 strftime 表达式与 `mapOverview().byMonth` 逐字一致（`Self.monthBucketSQL`），
    /// 保证地图上的计数点进去能列出同样多条——两处各写一遍就会在时区边界上打架。
    public func conversationIDs(for facet: Facet, limit: Int) -> [String] {
        if case .entity(let text) = facet {
            return Array(conversations(withEntity: text).prefix(max(0, limit)))
        }
        var out: [String] = []
        let (clause, value) = Self.clause(for: facet)
        try? queue.sync {
            try db.query("""
            SELECT id FROM conversations WHERE \(clause) ORDER BY end_at DESC LIMIT ?;
            """, bind: { st in
                SQLiteDB.bindText(st, 1, value)
                // Int32(...) 在 limit 传 Int.max 时会运行时陷阱、整个进程 abort——
                // MCP 层表达"不限"最自然的写法就是 Int.max（本仓库 JSONLReader 已是这个
                // 模式），必须用 clamping 把超出 Int32 范围的值夹到 Int32.max 而不是崩溃。
                sqlite3_bind_int(st, 2, Int32(clamping: max(0, limit)))
            }, row: { out.append(SQLiteDB.text($0, 0)) })
        }
        return out
    }

    /// 该切面下的会话总数（不受 `limit` 影响）——切面页表头要说"共 100 场，列出 20 场"。
    public func conversationCount(for facet: Facet) -> Int {
        if case .entity(let text) = facet {
            // 直接 COUNT(*)，不借道 `conversations(withEntity:).count`——后者要把
            // 上千条会话 id 全部拉进 Swift 数组只为取一个数字，纯粹浪费。JOIN 结构
            // 照抄 `conversations(withEntity:)`，只是去掉不影响计数的 ORDER BY。
            //
            // 这里必须自己开一个新的 `queue.sync`，不能直接调用
            // `conversations(withEntity:)`——那个方法内部也会 `queue.sync`，在已经
            // 处于 sync 块里的地方再 sync 同一个串行队列是重入，直接自死锁。
            var n = 0
            try? queue.sync {
                try db.query("""
                SELECT COUNT(*) FROM conversations c
                JOIN conversation_entities ce ON ce.conv_rowid = c.rowid
                JOIN entities e ON e.rowid = ce.entity_rowid
                WHERE e.text = ?;
                """, bind: { SQLiteDB.bindText($0, 1, text) },
                     row: { n = Int(sqlite3_column_int64($0, 0)) })
            }
            return n
        }
        var n = 0
        let (clause, value) = Self.clause(for: facet)
        try? queue.sync {
            try db.query("SELECT COUNT(*) FROM conversations WHERE \(clause);",
                         bind: { SQLiteDB.bindText($0, 1, value) },
                         row: { n = Int(sqlite3_column_int64($0, 0)) })
        }
        return n
    }

    /// `.entity` 不走这里（它要 JOIN 实体表），调用方必须先分流。
    private static func clause(for facet: Facet) -> (String, String) {
        switch facet {
        case .source(let s):    return ("source = ?", s.rawValue)
        case .project(let cwd): return ("cwd = ?", cwd)
        case .month(let ym):    return ("\(monthBucketSQL) = ?", ym)
        case .entity:           preconditionFailure("entity 切面不走 clause，调用方要先分流")
        }
    }

    /// 按会话 id 取元数据。
    public func metadata(forID id: String) -> ConversationLite? {
        var out: ConversationLite?
        try? queue.sync { out = try liteRow(id: id) }
        return out
    }

    /// 按一组 id 批量取，**保持传入顺序**（那通常是相关度顺序），查不到的静默跳过。
    public func metadata(forIDs ids: [String]) -> [ConversationLite] {
        var out: [ConversationLite] = []
        try? queue.sync {
            for id in ids { if let l = try liteRow(id: id) { out.append(l) } }
        }
        return out
    }

    /// **必须已在 `queue` 上**——公开入口自己 `queue.sync` 过一次，
    /// 这里再 sync 就是对串行队列的重入，直接自死锁。
    private func liteRow(id: String) throws -> ConversationLite? {
        var out: ConversationLite?
        try db.query("SELECT \(Self.liteColumns) FROM conversations WHERE id = ? LIMIT 1;",
                     bind: { SQLiteDB.bindText($0, 1, id) },
                     row: { out = Self.lite(from: $0) })
        return out
    }
}
