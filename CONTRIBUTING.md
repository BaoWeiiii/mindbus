# 参与贡献 / Contributing

[中文](#中文) · [English](#english)

---

## 中文

感谢你愿意花时间。MindBus 是一个 Swift 原生 macOS App，仓库不大，规矩也不多，但下面几条是硬的。

### 环境要求

- macOS 13.0 或更高（运行 App）；开发机建议 macOS 14+。
- Xcode 15+ / Swift 5.9+（`swift --version` 确认）。
- 不需要 Xcode 工程文件：整个项目是一个 SwiftPM 包，`swift build` / `swift test` 就够了。
- 可选：`brew install create-dmg`，只有打 DMG 时才用到。

### 第一步：安装提交防护

```bash
git clone https://github.com/<你的账号>/mindbus.git
cd mindbus
scripts/setup-hooks.sh
```

`setup-hooks.sh` 把 `core.hooksPath` 指到仓库自带的 `.githooks/`：pre-commit 与 pre-push 用确定性规则拦下密钥、`.jsonl` / `.sqlite` 数据文件、本机绝对路径（带用户名的 `/Users/...`）、以及一组不该出现在公开仓的词。它不限制你推到哪个远程，fork 照常工作。被误拦时用 `--no-verify` 绕过，并在提交信息里说明原因。

### 构建与测试

```bash
swift build            # 调试构建
swift test             # 900+ 个测试，全绿是合并的硬门槛
./scripts/install.sh   # 构建并装到 /Applications（覆盖 Releases 签名版前会先问你）
```

测试进程强制使用临时索引与临时目录，不会碰你自己的 `~/.mindbus` 与真实索引。

### 新增对话来源

最受欢迎的贡献。一个来源 = 一个 Loader + 一组测试：

1. 在 `MindBus/Core/Loaders/` 新建 `XxxLoader.swift`，参考 [`CodexLoader.swift`](MindBus/Core/Loaders/CodexLoader.swift)：枚举固定根目录、逐行解析、产出 `Conversation` / `Message` / `ContentBlock`。只读源文件，绝不写入源目录。
2. 在 `Tests/MindBusCoreTests/` 加 `XxxLoaderTests.swift`：正常文件、空文件、坏行、超长行、多行 JSON 等边界各至少一条。
3. `MindBus/Core/Models/Conversation.swift` 的 `ConversationSource` 加一个 case 与显示名；`LoaderRuntime.indexAllSources` 挂上 loader；`SourceDetection.detectAvailable` 补探测。
4. 用户可见的来源名进双语表（见下一节）。

样本格式不确定时，先开一个「新来源采样」Issue，贴脱敏后的结构示例。

### 文案：全部进双语表

所有用户可见文案必须写进 `MindBus/Config/L10n.swift` 的 `Strings` 表，`zh` 与 `en` 两份都要有；视图里通过 `L10n.shared.s.<字段>` 取值，不要在 View 里写死中文或英文。设置里可以即时切换语言，两份缺一就会显示空白。

### 测试夹具与样本数据：禁止真实数据

夹具、样本、注释、Preview 数据**一律不得使用真实对话、真实项目名、真实路径、真实会话 UUID 或 git 哈希**。用明显虚构的内容（`ProjectA`、`/Users/dev/ProjectA`、`lorem ipsum`、`abc1234`），并把数字打乱——数字对得上就能反推真实语料。guard hook 会拦下一部分，但拦不住全部，请自觉。

### 提交信息

`type(scope): 一句话说清做了什么`，例如：

- `feat(loader): 接入 Cursor 会话`
- `fix(search): 短词 LIKE 转义`
- `docs(readme): 卸载路径补全`

`type` 取 feat / fix / docs / refactor / test / perf / chore；`scope` 取模块名（loader / index / search / minds / mcp / ui / scripts / ci）。中英皆可。

### PR 前自查

- [ ] `swift test` 本地全绿（不只靠 CI）
- [ ] 改了解析器（`Core/Loaders/`）或索引口径 → 附测试与脱敏夹具
- [ ] 新增文案 → 已进 `Strings` 双语表，中英都有
- [ ] 不含个人路径 / 真实数据 / 密钥（hook 通过）
- [ ] 未引入新的外部依赖（要引入请先开 Issue；Sparkle 是唯一例外）
- [ ] UI 改动附截图（打码），并说明在哪个 macOS 版本上验证过

---

## English

Thanks for taking the time. MindBus is a native Swift macOS app; the repo is small and the rules are few, but the ones below are firm.

### Requirements

- macOS 13.0 or later to run the app; macOS 14+ recommended for development.
- Xcode 15+ / Swift 5.9+ (check with `swift --version`).
- No Xcode project needed: the whole thing is a SwiftPM package — `swift build` / `swift test` is all you need.
- Optional: `brew install create-dmg`, only needed to build a DMG.

### Step one: install the commit guard

```bash
git clone https://github.com/<you>/mindbus.git
cd mindbus
scripts/setup-hooks.sh
```

`setup-hooks.sh` points `core.hooksPath` at the repo's own `.githooks/`: pre-commit and pre-push use deterministic rules to block secrets, `.jsonl` / `.sqlite` data files, absolute local paths (`/Users/...` with a username), and a set of words that must not appear in a public repo. It does not restrict which remote you push to — forks work as usual. If it blocks a false positive, use `--no-verify` and say why in the commit message.

### Build and test

```bash
swift build            # debug build
swift test             # 900+ tests — all green is the hard bar for merging
./scripts/install.sh   # build and install to /Applications (asks before overwriting a signed Releases build)
```

The test process is forced onto a temporary index and temporary directories; it never touches your own `~/.mindbus` or real index.

### Adding a conversation source

The most wanted contribution. One source = one Loader + one test suite:

1. Create `XxxLoader.swift` in `MindBus/Core/Loaders/`, modelled on [`CodexLoader.swift`](MindBus/Core/Loaders/CodexLoader.swift): enumerate a fixed root directory, parse line by line, emit `Conversation` / `Message` / `ContentBlock`. Read source files only — never write into the source directory.
2. Add `XxxLoaderTests.swift` under `Tests/MindBusCoreTests/`: at least one case each for a normal file, an empty file, a malformed line, an oversized line, multi-line JSON, and similar edges.
3. Add a case and display name to `ConversationSource` in `MindBus/Core/Models/Conversation.swift`; register the loader in `LoaderRuntime.indexAllSources`; add detection in `SourceDetection.detectAvailable`.
4. Put the user-visible source name in the bilingual strings table (next section).

Not sure about the file format? Open a "New source sample" Issue first with a redacted structural sample.

### Strings: everything goes in the bilingual table

Every user-visible string must live in the `Strings` table in `MindBus/Config/L10n.swift`, with both `zh` and `en` entries; views read them via `L10n.shared.s.<field>`. Never hard-code Chinese or English in a View. The language can be switched live in Settings, and a missing entry shows up as a blank.

### Test fixtures and sample data: no real data

Fixtures, samples, comments, and preview data **must never use real conversations, real project names, real paths, real session UUIDs, or real git hashes**. Use obviously fictional content (`ProjectA`, `/Users/dev/ProjectA`, `lorem ipsum`, `abc1234`) and scramble the numbers — matching numbers are enough to trace back to a real corpus. The guard hook catches some of this, not all of it.

### Commit messages

`type(scope): one line saying what changed`, for example:

- `feat(loader): add Cursor sessions`
- `fix(search): escape short-word LIKE patterns`
- `docs(readme): complete the uninstall paths`

`type` is one of feat / fix / docs / refactor / test / perf / chore; `scope` is the module (loader / index / search / minds / mcp / ui / scripts / ci). English or Chinese are both fine.

### Before opening a PR

- [ ] `swift test` is green locally (not just on CI)
- [ ] Parser (`Core/Loaders/`) or index changes come with tests and redacted fixtures
- [ ] New strings are in the `Strings` table, in both languages
- [ ] No personal paths / real data / secrets (the hook passes)
- [ ] No new external dependency (open an Issue first; Sparkle is the sole exception)
- [ ] UI changes include a (redacted) screenshot and the macOS version you verified on
