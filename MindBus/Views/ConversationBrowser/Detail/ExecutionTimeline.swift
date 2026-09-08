import SwiftUI
import MindBusCore

// MARK: - 执行流时间线（agent 会话的步骤化渲染）
//
// assistant 消息里的 thinking / toolUse / toolResult 渲染为「步骤节点卡片行」：
// 白一级底（DSLight.sf）圆角 8、与正文卡同宽，行内 = 折叠箭头 + 类型图标 +
// 标签 + 摘要 + 相对时间 + 淡化状态勾圈；点击整行展开原始内容（卡片内部下方）。
// 正文 text 块是同宽的白底圆角 10 卡片。卡片行间距 8。
//
// 数据事实（决定了结构）：Claude Code/Agent 每条 JSONL 记录只含 1-2 个块，
// 一次执行流是**一串相邻的 assistant 消息**——run（连续 assistant 消息段，
// 同日内）仍是行级信息的计算单位：时间显隐按 run 去重。早期版本以竖线轴
// 贯通 run，卡片化后轴已移除（独立卡片行之间轴失去意义）。
// Codex 只有 text 块，永不触发时间线。

// MARK: 行级信息（DetailView 按 run 一次算好，随行传入）

/// nil = 该行不参与时间线（user 行 / 纯聊天 assistant 行），走现状气泡。
struct TimelineRowInfo: Equatable {
    /// run 内更早处还有节点。旧竖线轴语义；卡片化后不再驱动视觉，
    /// 字段保留维持布局 API / 判等稳定。
    var axisTop: Bool
    /// run 内更新处还有节点（同上，仅数据不驱动视觉）。
    var axisBottom: Bool
    /// 本行显示相对时间（与上一显示时间同分钟则省略——密度控制）
    var showTime: Bool
    /// 本行含全会话最后一个步骤节点。卡片化后每个节点行统一淡化勾圈，
    /// 终点不再单独放大绿勾；字段保留（布局算法与判等不变）。
    var terminal: Bool
}

enum TimelineLayout {

    static func hasStepBlocks(_ msg: Message) -> Bool {
        msg.blocks.contains { block in
            switch block {
            case .thinking, .toolUse, .toolResult: return true
            default: return false
            }
        }
    }

    /// rev：视觉底→顶（最新→最旧），与 DetailView.messageScroll 的 rev 同序。
    /// 返回与 rev 对齐的数组。纯枚举 tag 扫描，O(总块数)，无正则/全文扫描。
    static func rowInfos(rev: [Message]) -> [TimelineRowInfo?] {
        var infos = [TimelineRowInfo?](repeating: nil, count: rev.count)
        guard !rev.isEmpty else { return infos }
        let cal = Calendar.current

        var terminalAssigned = false
        var i = 0
        while i < rev.count {
            guard rev[i].role == .assistant else { i += 1; continue }
            // run 边界：连续 assistant 且相邻同日（跨日插 DayDivider，轴不桥接）
            var j = i
            while j + 1 < rev.count,
                  rev[j + 1].role == .assistant,
                  cal.isDate(rev[j].timestamp, inSameDayAs: rev[j + 1].timestamp) {
                j += 1
            }
            // run = rev[i...j]；i 端最新（视觉下），j 端最旧（视觉上）
            let steps = (i...j).map { hasStepBlocks(rev[$0]) }
            if steps.contains(true) {
                // olderHas[k-i] = run 内比 k 旧的行是否有步骤；newerHas 同理
                let n = j - i + 1
                var olderHas = [Bool](repeating: false, count: n)
                var acc = false
                for t in stride(from: n - 1, through: 0, by: -1) {   // 旧→新
                    olderHas[t] = acc
                    if steps[t] { acc = true }
                }
                var newerHas = [Bool](repeating: false, count: n)
                acc = false
                for t in 0..<n {                                     // 新→旧
                    newerHas[t] = acc
                    if steps[t] { acc = true }
                }
                // 时间显隐：旧→新扫，与上一次「已显示」的时间同分钟则省略
                var lastShown: Date? = nil
                for k in stride(from: j, through: i, by: -1) {
                    let t = k - i
                    let ts = rev[k].timestamp
                    let show: Bool
                    if let last = lastShown,
                       cal.isDate(last, equalTo: ts, toGranularity: .minute) {
                        show = false
                    } else {
                        show = true
                        lastShown = ts
                    }
                    let axisTop: Bool
                    let axisBottom: Bool
                    if steps[t] {
                        axisTop = olderHas[t]
                        axisBottom = newerHas[t]
                    } else {
                        // 气泡行：只在「夹在节点之间」时轴穿过；run 首尾气泡只缩进不带轴
                        let between = olderHas[t] && newerHas[t]
                        axisTop = between
                        axisBottom = between
                    }
                    infos[k] = TimelineRowInfo(axisTop: axisTop, axisBottom: axisBottom,
                                               showTime: show, terminal: false)
                }
                // 全会话唯一绿勾：最新的含步骤行（run 按 i 升序枚举，首个活跃 run 即最新）
                if !terminalAssigned {
                    for k in i...j where steps[k - i] {
                        infos[k]?.terminal = true
                        terminalAssigned = true
                        break
                    }
                }
            }
            i = j + 1
        }
        return infos
    }
}

// MARK: - 消息级条目模型（分类 / 摘要一次构建，NSCache 缓存）

/// 父视图 hover 每次翻转都会重建子视图值，NSCache 命中让 init 退化为 O(1) 查表——
/// 与 MessageBlocksView 的 Equatable 短路同级的缓存策略。
final class TimelineModel {

    enum Item {
        case node(Node)
        case bubble([Int])   // message.blocks 下标（连续的 text/code/image 段）
    }

    /// 节点语义类别。文案不进 Model（NSCache 缓存与语言无关），
    /// 由视图层按当前语言映射主标签：zh「思考中」+ 小字 / en "Thinking" 单词条。
    enum NodeKind {
        case thinking, result, bash, read, edit, generic
    }

    struct Node {
        let blockIndex: Int
        let icon: String       // SF Symbol
        let kind: NodeKind     // 语义类别（视图层映射双语标签）
        let toolName: String?  // toolUse 的工具名（超长已截断）；thinking/result 为 nil
        let summary: String    // 一句摘要（首行截断）
        let pathStyle: Bool    // true → 视觉中间截断（保尾部文件名）
        /// nil = 无内容可展开（如 redacted thinking 的空文本）：不显示箭头、不可点。
        let expansion: Expansion?
    }

    enum Expansion {
        case thinking(String)
        case code(language: String, text: String)
        /// command 有值 → 展示命令本身（bash）；否则懒 pretty-print 输入 JSON
        case toolInput(raw: String, command: String?)
    }

    let items: [Item]
    let lastNodeBlockIndex: Int?

    private static let cache = NSCache<NSString, TimelineModel>()

    static func model(for message: Message) -> TimelineModel {
        // 会话内 id 与内容一一对应；活跃会话增量追加时 blocks.count 变化会换 key
        let key = "\(message.id)#\(message.blocks.count)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let m = TimelineModel(message: message)
        cache.setObject(m, forKey: key)
        return m
    }

    private init(message: Message) {
        var items: [Item] = []
        var pending: [Int] = []
        var lastNode: Int? = nil
        for (idx, block) in message.blocks.enumerated() {
            if let node = Self.makeNode(block, at: idx) {
                if !pending.isEmpty { items.append(.bubble(pending)); pending = [] }
                items.append(.node(node))
                lastNode = idx
            } else {
                pending.append(idx)
            }
        }
        if !pending.isEmpty { items.append(.bubble(pending)) }
        self.items = items
        self.lastNodeBlockIndex = lastNode
    }

    var hasNodes: Bool { lastNodeBlockIndex != nil }

    // MARK: 分类

    private static func makeNode(_ block: ContentBlock, at idx: Int) -> Node? {
        switch block {
        case .thinking(let t):
            // Claude 的 redacted/signature-only thinking 块文本为空——
            // 空内容不支持展开（用户定案：点开一片空白毫无意义）
            let empty = t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return Node(blockIndex: idx, icon: "bubble.left",
                        kind: .thinking, toolName: nil,
                        summary: firstLine(of: t), pathStyle: false,
                        expansion: empty ? nil : .thinking(t))
        case .toolResult(let t):
            // 当前三个浏览源的 toolResult 都在 user 行且被 loader 丢弃，此分支为
            // 防御性支持（数据格式一旦携带也能正确成节点）。
            let emptyResult = t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return Node(blockIndex: idx, icon: "arrow.turn.down.right",
                        kind: .result, toolName: nil,
                        summary: firstLine(of: t), pathStyle: false,
                        expansion: emptyResult ? nil : .code(language: "", text: t))
        case .toolUse(let name, let input):
            return classify(name: name, input: input, at: idx)
        default:
            return nil
        }
    }

    private static let bashNames: Set<String> = [
        "bash", "shell", "terminal", "exec", "run_command", "execute_command",
        "run_terminal_cmd", "run_shell_command",
    ]
    private static let readNames: Set<String> = [
        "read", "read_file", "readfile", "cat", "view_file", "open_file",
    ]
    private static let editNames: Set<String> = [
        "edit", "write", "multiedit", "notebookedit", "apply_patch", "applypatch",
        "str_replace", "str_replace_editor", "create_file", "write_file", "edit_file",
    ]

    private static func classify(name: String, input: String, at idx: Int) -> Node {
        let fields = toolFields(input)
        let lower = name.lowercased()
        let command = fields["command"]
        let path = fields["file_path"] ?? fields["path"]
            ?? fields["notebook_path"] ?? fields["filePath"]
        // 名字过长（MCP 工具全名）截到 28，防挤掉摘要
        let en = name.count > 28 ? String(name.prefix(28)) + "…" : name

        if bashNames.contains(lower) {
            return Node(blockIndex: idx, icon: "terminal",
                        kind: .bash, toolName: en,
                        summary: firstLine(of: command ?? input), pathStyle: false,
                        expansion: .toolInput(raw: input, command: command))
        }
        if readNames.contains(lower) {
            return Node(blockIndex: idx, icon: "doc.text",
                        kind: .read, toolName: en,
                        summary: path ?? firstLine(of: input), pathStyle: path != nil,
                        expansion: .toolInput(raw: input, command: nil))
        }
        if editNames.contains(lower) {
            return Node(blockIndex: idx, icon: "pencil.line",
                        kind: .edit, toolName: en,
                        summary: path ?? firstLine(of: input), pathStyle: path != nil,
                        expansion: .toolInput(raw: input, command: nil))
        }
        // 其他工具：挑最有信息量的字段做摘要（Grep 的 pattern、WebFetch 的 url…）
        let generic = command ?? path
            ?? fields["pattern"] ?? fields["query"] ?? fields["url"]
            ?? fields["description"] ?? fields["prompt"] ?? fields["skill"]
        return Node(blockIndex: idx, icon: "wrench.adjustable",
                    kind: .generic, toolName: en,
                    summary: generic.map { firstLine(of: $0) } ?? firstLine(of: input),
                    pathStyle: generic != nil && generic == path,
                    expansion: .toolInput(raw: input, command: command))
    }

    /// toolUse 的 input 是 loader 从字典序列化的 JSON 字符串（键序不定），
    /// 只有正经解析才能稳拿 command/file_path。构建仅一次（NSCache），
    /// 超大输入（Write 大文件）设 2MB 上限直接放弃提取。
    private static func toolFields(_ input: String) -> [String: String] {
        guard input.utf8.count <= 2_000_000,
              let data = input.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var out: [String: String] = [:]
        for (k, v) in obj {
            if let s = v as? String { out[k] = s }
            else if let n = v as? NSNumber { out[k] = n.stringValue }
        }
        return out
    }

    /// 首个非空行，截 160 字符。只扫前 1000 字符，不做全文扫描。
    private static func firstLine(of text: String, limit: Int = 160) -> String {
        let head = text.prefix(1000)
        for line in head.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return String(t.prefix(limit)) }
        }
        return ""
    }
}

// MARK: - 时间线消息视图（一条 assistant 消息 = 节点行 + 正文气泡，共用左轴）

/// Equatable 短路与 MessageBlocksView 同级：message 未变（id+块数）且行级信息
/// 未变时整个子树跳过重算；节点展开/hover 是内部 @State，命中缓存后重渲染极轻。
struct TimelineMessageView: View, Equatable {
    let message: Message
    let info: TimelineRowInfo
    /// 非空 = 搜索态：节点摘要与气泡正文里的命中词金色标注。
    let highlightQuery: String
    /// 当前界面语言（由 MessageBubbleView 传入并纳入判等——切语言时行必须重算）。
    let isZh: Bool

    /// 搜索词纳入判等：词变了要重算高亮，hover/展开等内部 @State 不经过这里。
    static func == (l: Self, r: Self) -> Bool {
        l.message.id == r.message.id
            && l.message.blocks.count == r.message.blocks.count
            && l.info == r.info
            && l.highlightQuery == r.highlightQuery
            && l.isZh == r.isZh
    }

    @State private var expanded: Set<Int>           // 展开的节点（blockIndex），默认全收起
    @State private var hoveredNode: Int? = nil
    @State private var nodeHeights: [Int: CGFloat] = [:]   // 节点卡实高（滚动补偿用）
    @State private var pendingComp: [Int: CGFloat] = [:]    // 点击瞬间记录的旧高——高度落定帧同步补偿
    @StateObject private var scrollHolder = EnclosingScrollHolder()

    /// previewExpanded 仅供离屏渲染自检展开态（正常调用默认全收起）。
    init(message: Message, info: TimelineRowInfo, highlightQuery: String = "",
         isZh: Bool = true, previewExpanded: Set<Int> = []) {
        self.message = message
        self.info = info
        self.highlightQuery = highlightQuery
        self.isZh = isZh
        _expanded = State(initialValue: previewExpanded)
    }

    private static let nodeRowH: CGFloat = 22       // 节点行单行高
    private static let itemGap: CGFloat = 8         // 卡片行间距（概念稿定值）

    var body: some View {
        let model = TimelineModel.model(for: message)   // NSCache 命中 O(1)
        VStack(alignment: .leading, spacing: Self.itemGap) {
            ForEach(Array(model.items.enumerated()), id: \.offset) { _, item in
                switch item {
                case .node(let node):
                    nodeItem(node)
                case .bubble(let idxs):
                    bubbleItem(idxs)
                }
            }
        }
        .background(EnclosingScrollProbe(holder: scrollHolder))
    }

    // MARK: 节点条目（独立卡片行：白一级底 + 圆角 8 + 水平铺满）

    private func nodeItem(_ node: TimelineModel.Node) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            nodeRow(node)
            if let exp = node.expansion, expanded.contains(node.blockIndex) {
                expansionView(exp)   // 展开内容在卡片内部下方
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)   // 与正文卡同宽（铺满消息列）
        .background(hoveredNode == node.blockIndex ? DSLight.sf2 : DSLight.sf,
                    in: RoundedRectangle(cornerRadius: 8))
        .background {
            // 记录节点卡实高；展开/收起后新高度落定的**同一帧**做滚动补偿——
            // 节点行钉在原位、内容向下展开（聊天 app 惯例方向）
            GeometryReader { g in
                Color.clear
                    .onAppear { nodeHeights[node.blockIndex] = g.size.height }
                    .onChange(of: g.size.height) { newH in
                        let idx = node.blockIndex
                        nodeHeights[idx] = newH
                        guard let h0 = pendingComp.removeValue(forKey: idx) else { return }
                        let d = newH - h0
                        guard abs(d) > 0.5, let sv = scrollHolder.scrollView else { return }
                        let cv = sv.contentView
                        var o = cv.bounds.origin
                        let before = o.y   // DIAGTEMP
                        o.y += d
                        cv.scroll(to: o)
                        sv.reflectScrolledClipView(cv)
                    }
            }
        }
    }

    /// 节点主标签：kind → 当前语言文案（Strings 静态实例按 isZh 取，不依赖 MainActor）。
    private func nodeLabel(_ kind: TimelineModel.NodeKind) -> String {
        let s: Strings = isZh ? .zh : .en
        switch kind {
        case .thinking: return s.nodeThinking
        case .result: return s.nodeResult
        case .bash: return s.nodeRunCommand
        case .read: return s.nodeReadFile
        case .edit: return s.nodeEditFile
        case .generic: return s.nodeToolCall
        }
    }

    /// 低对比等宽小字。zh 保持「中文 + 英文小字」双词条（思考中 thinking / 执行命令 Bash）；
    /// en 主标签本身已是英文，只有工具名还有信息量（Run command · Bash），
    /// thinking/result 不再重复出小字（避免 "Thinking thinking"）。
    private func nodeDetail(_ node: TimelineModel.Node) -> String? {
        if let tool = node.toolName { return tool }
        guard isZh else { return nil }
        switch node.kind {
        case .thinking: return "thinking"
        case .result: return "result"
        default: return nil
        }
    }

    /// 节点行：折叠箭头 + 类型图标 + 主标签 + 等宽小字 + 摘要 + 相对时间 + 状态勾圈。
    /// 整行可点展开。摘要不在概念行内清单里，但它是信息载荷（命令/路径预览）
    /// 且承载搜索高亮，保留在标签与 Spacer 之间。
    private func nodeRow(_ node: TimelineModel.Node) -> some View {
        let isExpanded = expanded.contains(node.blockIndex)
        let expandable = node.expansion != nil
        return Button {
            guard expandable else { return }   // 无内容可展开:整行点击 no-op
            // 瞬时切换（不做高度动画）：详情列表是「最新贴底」的翻转结构，
            // 行高增长视觉上向上扩。点击只记录旧高；补偿在 GeometryReader
            // 高度落定的同一布局事务里做（晚一拍的 async 补偿会先上屏一帧
            // 「弹到上面」的画面再跳回——闪烁）。
            pendingComp[node.blockIndex] = nodeHeights[node.blockIndex] ?? 0
            if isExpanded {
                expanded.remove(node.blockIndex)
            } else {
                expanded.insert(node.blockIndex)
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundStyle(DSLight.t3)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 10)
                    .opacity(expandable ? 1 : 0)   // 占位隐形:图标列对齐不乱
                Image(systemName: node.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(DSLight.t3)
                    .frame(width: 13)
                Text(nodeLabel(node.kind))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DSLight.t2)
                    .fixedSize()
                if let detail = nodeDetail(node) {
                    Text(detail)
                        .font(BrandFont.mono(10))
                        .foregroundStyle(DSLight.t4)
                        .lineLimit(1)
                }
                if !node.summary.isEmpty {
                    // HighlightedLine（Equatable）：节点 hover 翻转重算 body 时，
                    // 摘要 text/query 未变则短路——高亮扫描不进 hover 热路径。
                    HighlightedLine(text: node.summary, query: highlightQuery,
                                    font: .system(size: 12), color: DSLight.t3)
                        .equatable()
                        .lineLimit(1)
                        // 文件路径中间截断保尾部文件名；命令/思考尾截断
                        .truncationMode(node.pathStyle ? .middle : .tail)
                }
                Spacer(minLength: 8)
                if info.showTime {
                    Text(message.timestamp.relativeLabel(isZh: isZh))
                        .font(.system(size: 11))
                        .foregroundStyle(DSLight.t4)
                        .fixedSize()
                }
                // 概念稿每行尾部有绿色状态勾圈；历史会话皆完成态，勾无信息量
                // 纯属噪音，已整体移除（用户定案 2026-08-03）。
            }
            .frame(minHeight: Self.nodeRowH)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(.easeOut(duration: 0.12)) {
                if h {
                    hoveredNode = node.blockIndex
                } else if hoveredNode == node.blockIndex {
                    hoveredNode = nil
                }
            }
        }
    }

    @ViewBuilder
    private func expansionView(_ e: TimelineModel.Expansion) -> some View {
        switch e {
        case .thinking(let t):
            Text(t)
                .font(.system(size: 12))
                .lineSpacing(4)   // 次级阅读面行距（沿用原 thinking 折叠排版）
                .foregroundStyle(DSLight.t3)
                .textSelection(.enabled)
                .customContextMenuOnly()
                .padding(.leading, 35)   // 与标签文字对齐（箭头 10 + 间距 6 + 图标列 13 + 间距 6）
                .padding(.vertical, 4)
        case .code(let lang, let text):
            CodeBlockView(language: lang, code: text)   // 宽块不缩进，卡片内边距即左界
                .padding(.vertical, 4)
        case .toolInput(let raw, let command):
            Group {
                if let command {
                    CodeBlockView(language: "bash", code: command)
                } else {
                    ToolInputCodeView(raw: raw)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: 气泡条目（正文 text 块 = 白底圆角 10 卡片，与节点卡同宽）

    private func bubbleItem(_ idxs: [Int]) -> some View {
        // 右下角相对时间叠放（不用 Spacer——会把内容贪婪撑满）；
        // 有节点的行时间已在节点上，不重复。
        ZStack(alignment: .bottomTrailing) {
            let showsTime = info.showTime && !TimelineModel.model(for: message).hasNodes
            VStack(alignment: .leading, spacing: 6) {
                ForEach(idxs, id: \.self) { i in
                    blockView(message.blocks[i])
                }
            }
            .padding(.bottom, showsTime ? 16 : 0)
            if showsTime {
                Text(message.timestamp.relativeLabel(isZh: isZh))
                    .font(.system(size: 10))
                    .foregroundStyle(DSLight.t4)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DSLight.sf, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func blockView(_ block: ContentBlock) -> some View {
        switch block {
        case .text(let t):
            TextSegmentsView(text: t, highlightQuery: highlightQuery, isZh: isZh)
        case .code(let lang, let code):
            CodeBlockView(language: lang, code: code)
        case .image(let mediaType, let source):
            InlineImageView(mediaType: mediaType, source: source)
        default:
            EmptyView()   // 步骤块不会进气泡条目
        }
    }
}

// MARK: - text 块分段渲染（气泡与时间线气泡条目共用）

/// prose markdown + fenced code 的分段渲染。重活（分段/正则/AttributedString）
/// 由上层 Equatable 视图（MessageBlocksView / TimelineMessageView）短路。
struct TextSegmentsView: View {
    let text: String
    /// 非空 = 搜索态：prose 段命中词金色标注（代码块不标——高亮与语法着色互相打架，
    /// 且代码命中多为变量名碎片，收益低噪音高）。
    var highlightQuery: String = ""
    /// 「[图片]」占位替换的语言（由持有 L10n 的上层传入）。
    var isZh: Bool = true

    var body: some View {
        ForEach(Array(MarkdownSegmenter.split(MessageBubbleView.hideImageRefs(text, isZh: isZh)).enumerated()),
                id: \.offset) { _, seg in
            switch seg {
            case .prose(let p):
                // 图片引用清洗后可能只剩空白（正文只有 [Image #N] 占位）——空段不渲染
                if !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(Self.renderProse(p, highlightQuery: highlightQuery))
                        .lineSpacing(6)   // 中文行高 ≥1.85（设计系统 CJK 规则）
                        .textSelection(.enabled)
                        .customContextMenuOnly()
                }
            case .code(let lang, let body):
                CodeBlockView(language: lang, code: body)
            }
        }
    }

    /// markdown 渲染后在**可见文本**上标注命中（语法符号已被渲染消费，
    /// range 直接对应用户看到的字符流；空词零成本原样返回）。
    static func renderProse(_ text: String, highlightQuery: String) -> AttributedString {
        var attr = renderMarkdown(text)
        SearchHighlighter.annotate(&attr, query: highlightQuery)
        return attr
    }

    static func renderMarkdown(_ text: String) -> AttributedString {
        // 保留原始换行/空格/缩进（默认 .full 会折叠重排），仍渲染行内粗体/代码。
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        var attr = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        styleInlineCode(&attr)
        return attr
    }

    /// 行内 code（`code` span，多为路径/标识符/命令碎片）：深金前景 + 品牌等宽——
    /// 概念稿路径用 accent 色 mono（稿中蓝紫；现行 accent=金，色调切换时跟 token 走）。
    /// 解析器已把 code span 标成 inlinePresentationIntent.code，这里只叠前景/字体。
    /// 先收集 range 再赋值：属性写入不改字符流，索引稳定（与 SearchHighlighter 同一模式）。
    private static func styleInlineCode(_ attr: inout AttributedString) {
        let codeRanges: [Range<AttributedString.Index>] = attr.runs.compactMap { run in
            guard let intent = run.inlinePresentationIntent, intent.contains(.code) else { return nil }
            return run.range
        }
        for r in codeRanges {
            attr[r].foregroundColor = DSLight.gold
            attr[r].font = BrandFont.mono(12)   // 正文默认 13，等宽 12 视觉等高
        }
    }
}

/// 工具输入 JSON 的懒 pretty-print（展开才算，后台线程；未就绪一帧先出紧凑原文）。
private struct ToolInputCodeView: View {
    let raw: String
    @State private var pretty: String? = nil

    var body: some View {
        CodeBlockView(language: "json", code: pretty ?? raw)
            .task {
                let r = raw
                pretty = await Task.detached(priority: .userInitiated) {
                    Self.prettyJSON(r)
                }.value
            }
    }

    nonisolated private static func prettyJSON(_ s: String) -> String {
        guard let d = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d),
              let out = try? JSONSerialization.data(withJSONObject: obj,
                                                    options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: out, encoding: .utf8) else { return s }
        return str
    }
}

// MARK: - 宿主 NSScrollView 探针（展开节点的滚动补偿用）

/// 弱持有时间线所在的 NSScrollView。
@MainActor
final class EnclosingScrollHolder: ObservableObject {
    weak var scrollView: NSScrollView?
}

/// 零尺寸探针：挂进视图树后向上找 enclosingScrollView。
/// 每条消息各挂一个，命中的都是详情列表同一个 NSScrollView，无副作用。
private struct EnclosingScrollProbe: NSViewRepresentable {
    let holder: EnclosingScrollHolder

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        Task { @MainActor [weak v] in
            holder.scrollView = v?.enclosingScrollView
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        Task { @MainActor [weak nsView] in
            if holder.scrollView == nil {
                holder.scrollView = nsView?.enclosingScrollView
            }
        }
    }
}
