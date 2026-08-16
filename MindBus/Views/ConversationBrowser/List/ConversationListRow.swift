import SwiftUI
import MindBusCore

struct ConversationListRow: View {
    let conversation: ConversationLite
    var isSelected: Bool = false
    /// 非空 = 搜索态：标题与 preview 里的命中词金色标注。
    /// 取 store.highlightQuery（与召回同拍），不是逐字符的 searchQuery。
    var highlightQuery: String = ""
    /// 行底 0.5px 细分隔线（末行由列表侧传 false——行与行**之间**才有线）。
    /// 系统 listRowSeparator 保持 hidden，这里自绘避免系统分隔线样式。
    var showsSeparator: Bool = true
    /// 活跃色分配表(store.folderColorAssignments)——活跃项目的无冲突色;
    /// 表里没有的键行内走裸哈希回落。
    var folderColors: [String: Int] = [:]
    /// 标签别名改动后的刷新回调(列表侧让 store 重算活跃分配并重绘)。
    var onFolderRenamed: () -> Void = {}
    /// 被 agent 经 MCP 读取的次数(0 = 不显示徽章)。
    /// 「被 AI 引用过」是中枢价值的可见化——你的历史真的在被用,不只是存着。
    var refCount: Int = 0
    /// 已救回:源文件被工具清理,仅存于 MindBus 副本——产品价值最强证明,金盾常显。
    var rescued: Bool = false
    /// 右键删除回调(列表侧弹统一确认)。
    var onDelete: () -> Void = {}
    @ObservedObject private var l10n = L10n.shared
    @State private var hovering = false

    /// 「最新活跃」：end_at 距参考时刻 ≤10 分钟（进行中 / 刚结束的会话）。
    /// 参考时刻由 TimelineView 提供——超时后到点自动灭,不再等下一次列表重绘。
    private func isRecentlyActive(at date: Date) -> Bool {
        date.timeIntervalSince(conversation.endAt) <= 600
    }

    /// 分隔线左缩进 = 行内边距 8 + 徽章 28 + 列间距 10——与标题左缘对齐
    /// (活跃点已缀去相对时间前,左侧固定槽随之回收)。
    private static let separatorInset: CGFloat = 46

    var body: some View {
        // 左列 28px 圆底来源徽章跨两行；右侧双行元信息：上行「相对时间」（12px t3）
        // 对标题行，下行「N 条 · 时长」（11px t4）对预览行——右对齐两级递降，
        // 一眼先读「多新」再读「多大」。
        // 两个 meta 都 fixedSize：长标题/长预览挤压时只截左列，右列信息永远完整。
        HStack(alignment: .center, spacing: 10) {
            ToolSourceBadge(source: conversation.source)

            VStack(alignment: .leading, spacing: 3) {
                // 文件夹标签行(2026-08-11 参考稿)：彩色项目标签 + 右侧相对时间。
                // 同文件夹恒定同色由 FolderTagPalette 的确定性哈希保证。
                HStack(spacing: 6) {
                    folderTag
                    Spacer(minLength: 4)
                    // 「最新活跃」金色呼吸点直接缀在相对时间前(2026-08-14 用户定案:
                    // 点和时间是同一个信息——「多新」,不拆在行两端)。TimelineView
                    // 每 30s 重估:点到期自动灭,相对时间文字同步自动刷新。
                    // 只有活跃边缘内的行才挂 TimelineView(660s=10min+30s 缓冲):
                    // 冷行只会更冷(变活跃必经新消息→store 刷新→行重建),静态 Text
                    // 足够——大库首屏几十行不再人手一个调度器。
                    if Date().timeIntervalSince(conversation.endAt) <= 660 {
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            HStack(spacing: 5) {
                                if isRecentlyActive(at: context.date) {
                                    ActiveDot()
                                }
                                Text(relativeTime(conversation.endAt))
                                    .font(.system(size: 12))
                                    .foregroundStyle(DSLight.t3)
                            }
                        }
                        .fixedSize()
                    } else {
                        Text(relativeTime(conversation.endAt))
                            .font(.system(size: 12))
                            .foregroundStyle(DSLight.t3)
                            .fixedSize()
                    }
                }

                // 标题行：ai-title 优先,无则回落项目名(与标签重复是参考稿认可的形态)。
                HighlightedLine(text: projectFolder, query: highlightQuery,
                                font: .system(size: 13, weight: .medium), color: DSLight.t1)
                    .equatable()
                    .lineLimit(1)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // 预览锁死单行：两行会让该行比邻居高一截，整列扫读节奏就散了。
                    // 完整内容在右侧详情看，列表只负责「快速定位」。
                    HighlightedLine(text: displayPreview,   // 最近一条对话内容
                                    query: highlightQuery,
                                    font: .system(size: 12), color: DSLight.t3)
                        .equatable()
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if rescued {
                        Image(systemName: "shield.checkered")
                            .font(.system(size: 9))
                            .foregroundStyle(DSLight.gold)
                            .help(l10n.s.rescuedBadgeHelp)
                            .fixedSize()
                    }
                    if refCount > 0 {
                        // 金色 sparkles + 次数:贵重但安静,hover 有完整解释
                        HStack(spacing: 2) {
                            Image(systemName: "sparkles").font(.system(size: 9))
                            Text("\(refCount)").font(BrandFont.mono(10))
                        }
                        .foregroundStyle(DSLight.gold)
                        .help(l10n.s.refBadgeHelp(refCount))
                        .fixedSize()
                    }
                    Text(metaTrail)                           // 条数 + 累计时长
                        // 不用 monospaced：这串含中文（条/小时），等宽会把汉字字距撑开显松垮。
                        // 设计系统「label 用 mono」指的是纯英数标注。
                        .font(.system(size: 11))
                        .foregroundStyle(DSLight.t4)
                        .fixedSize()
                }
            }
        }
        // vertical 6→8：行间呼吸感放松一档（行高 +4pt ≈ 单屏行数 -7%，在可接受损耗内）。
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .rowStateBackground(selected: isSelected, hovering: hovering)
        .overlay(alignment: .bottom) {
            // 行间 0.5px 细线（左端对齐标题、右到行尾），设计系统「次要分隔」档。
            if showsSeparator {
                Rectangle().fill(DSLight.rule)
                    .frame(height: 0.5)
                    .padding(.leading, Self.separatorInset)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        // 逃生出口：解析出错、内容显示不全、或想自己写脚本处理时，
        // 用户得能到达源文件。此前 fileURL 明明在手，却只用来 stat 文件大小。
        .contextMenu {
            Button(l10n.s.revealInFinder) {
                NSWorkspace.shared.activateFileViewerSelecting([conversation.fileURL])
            }
            Button(l10n.s.copyFilePath) {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(conversation.fileURL.path, forType: .string)
            }
            Divider()
            Button(l10n.s.copyProjectPath) {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(conversation.cwd, forType: .string)
            }
            Divider()
            Button(role: .destructive) { onDelete() } label: {
                Label(l10n.s.deleteConvMenu, systemImage: "trash")
            }
        }
    }

    /// 行内紧凑 meta：条数恒显；时长智能缩短（小时级→「X 小时」，分钟级→「X 分」，1 分内不显）。
    /// 数字与单位间空格是全 app 排版规则；时长源取模型既有的 `duration`。
    private var metaTrail: String {
        let s = Int(conversation.duration)
        let msgs = l10n.s.msgsCount(conversation.messageCount)
        if s >= 3600 { return "\(msgs) · \(l10n.s.durationHours(s / 3600))" }
        if s >= 60 { return "\(msgs) · \(l10n.s.durationMinutes(s / 60))" }
        return msgs
    }

    /// preview 是扫描期算好存进索引的（含「(无文字)」「[图片]」中文哨兵值），
    /// 语言切换不会重扫——所以哨兵在显示层映射，旧索引照样双语。
    private var displayPreview: String {
        if l10n.isZh { return conversation.preview }
        return conversation.preview
            .replacingOccurrences(of: "(无文字)", with: l10n.s.previewNoText)
            .replacingOccurrences(of: "[图片]", with: l10n.s.imagePlaceholder)
    }

    /// 标签上的项目名：cwd 尾目录,browser 等无 cwd 会话用来源名。
    /// 不含 ai-title——标签表达「属于哪个文件夹」,标题才表达「这场聊了什么」。
    /// 原始色键(未过别名):别名编辑的操作对象。
    private var rawFolderKey: String {
        FolderColorAssigner.colorKey(cwd: conversation.cwd,
                                     sourceRawValue: conversation.source.rawValue)
    }

    /// 解析后的键 = 色键 = 显示基名。磁盘上改名过的项目,历史会话 cwd 还是旧路径——
    /// 别名让新旧两批会话合流到同名同色(右键改一次,存 ~/.mindbus 可带走)。
    private var resolvedFolderKey: String {
        FolderAliasStore.shared.resolve(rawFolderKey)
    }

    /// 标签显示名:解析键;source: 前缀(browser 等无 cwd)换双语来源名。
    private var folderTagName: String {
        let key = resolvedFolderKey
        if key.hasPrefix("source:") {
            return conversation.source.displayName(isZh: l10n.isZh)
        }
        return key
    }

    @State private var renamingFolder = false
    @State private var folderNameDraft = ""

    /// 彩色文件夹标签：folder 图标 + 项目名;右键可重命名(别名)。
    private var folderTag: some View {
        let pair = FolderTagPalette.pair(for: resolvedFolderKey, assignments: folderColors)
        return HStack(spacing: 3) {
            Image(systemName: "folder.fill").font(.system(size: 8))
            Text(folderTagName).font(.system(size: 11, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(pair.text)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(pair.bg, in: RoundedRectangle(cornerRadius: 5))
        .contextMenu {
            Button(l10n.s.folderRenameMenu) {
                folderNameDraft = resolvedFolderKey
                renamingFolder = true
            }
        }
        .alert(l10n.s.folderRenameTitle, isPresented: $renamingFolder) {
            TextField("", text: $folderNameDraft)
            Button(l10n.s.folderRenameSave) {
                FolderAliasStore.shared.set(alias: folderNameDraft, for: rawFolderKey)
                onFolderRenamed()
            }
            Button(l10n.s.cancel, role: .cancel) {}
        } message: {
            Text(l10n.s.folderRenameMessage(rawFolderKey))
        }
    }

    /// 行标题：官方 ai-title 优先（与详情 header 同一优先级），
    /// 无则回落项目文件夹名（cwd 末段），再无用来源名兜底。
    private var projectFolder: String {
        if let t = conversation.title, !t.isEmpty { return t }
        let cwd = conversation.cwd
        let fallback = conversation.source.displayName(isZh: l10n.isZh)
        guard !cwd.isEmpty else { return fallback }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? fallback : name
    }

    private func relativeTime(_ date: Date) -> String {
        date.relativeLabel(isZh: l10n.isZh)
    }
}

/// 「最新活跃」金色呼吸点:内点 opacity 脉动传达「正在进行」,外环扩散淡出加一层
/// 生命感——克制版:环最大 2 倍(12px)即收,不抢列表的安静。行滚出重用后
/// @State 重置、onAppear 重启动画,无残留。ImageRenderer 只出初始帧,动效真机看。
private struct ActiveDot: View {
    @State private var breathing = false
    @State private var rippling = false

    var body: some View {
        ZStack {
            Circle().stroke(DSLight.gold.opacity(0.55), lineWidth: 1)
                .frame(width: 6, height: 6)
                .scaleEffect(rippling ? 2.0 : 1.0)
                .opacity(rippling ? 0 : 0.55)
            Circle().fill(DSLight.gold)
                .frame(width: 6, height: 6)
                .opacity(breathing ? 1.0 : 0.45)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                breathing = true
            }
            withAnimation(.easeOut(duration: 2.4).repeatForever(autoreverses: false)) {
                rippling = true
            }
        }
    }
}
