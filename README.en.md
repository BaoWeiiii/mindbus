<div align="center">

<img src="assets/logo.png" alt="MindBus" width="112" />

# MindBus

**Every conversation you have with AI, collected on one machine.**

The models are rented; the conversations are yours.

Fully offline · No account · Not a single line of networking code

[![License](https://img.shields.io/badge/license-MIT-1a1a1a?style=flat-square)](LICENSE)
[![Platform](https://img.shields.io/badge/macOS-13.0+-1a1a1a?style=flat-square)](#installation)
[![Swift](https://img.shields.io/badge/Swift-5.9-1a1a1a?style=flat-square)](Package.swift)
[![Dependencies](https://img.shields.io/badge/dependencies-1_(Sparkle)-1a1a1a?style=flat-square)](Package.swift)
[![CI](https://github.com/BaoWeiiii/mindbus/actions/workflows/ci.yml/badge.svg)](https://github.com/BaoWeiiii/mindbus/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/BaoWeiiii/mindbus?style=flat-square&color=1a1a1a)](https://github.com/BaoWeiiii/mindbus/releases/latest)

[![English](https://img.shields.io/badge/English-current-A68450?style=flat-square)](#)
[![简体中文](https://img.shields.io/badge/简体中文-switch-DDB992?style=flat-square&logo=googletranslate&logoColor=white)](README.md)

[Installation](#installation) · [Sources](#supported-sources) · [Privacy](#privacy) · [Development](#development)

</div>

---

## What it is

**A memory box for your AI tools.**

Browse and star your history anytime — and let any AI tool tap into it, retrieving past context at minimal token cost.

<img src="assets/screenshots/browser.png" alt="Conversation browser" width="840" />

One box, two customers: **you**, and **your AI**. Every pain it cures is a concrete one —

### For you

**① "Gone before I even noticed."**
Claude Code silently deletes all history after 30 days — official policy, with reports of deletion even after changing the setting. Everyone who lasts 30 days will one day find their records gone, unrecoverably.
→ **Kept for good**: every conversation gets a compressed local copy. The tool deletes its own; yours stays. The app shows how many conversations have outlived those 30 days — and how many were rescued by that copy.

**② "I know we talked about it. I just can't find it."**
Three tools, three formats, three directories buried under `~/`. Finding last week's decision means digging one by one.
→ **One window for everything**: search in Chinese or English straight to the message, filter by tool / project / time.

**③ "I dare not close this window — let alone start a new chat."**
This session holds a whole afternoon of context. Close it and it might be lost; start fresh and you re-explain everything. So the window stays open, forever, untouchable.
→ **Close it freely**: conversations live in the box for good — browse back anytime, star what matters, or **relay** any selection into a new chat. Context follows you, not the window.

**④ "I have no idea how many times I've said the same thing."**
You have your own go-to phrases — they roll off your tongue; your briefings to AI repeat themselves too. These patterns are invisible to yourself.
→ **Minds makes them visible**: counted from your own conversations — the verbs you delegate with, your catchphrases, the exact briefings you keep repeating (how many times, across how many sessions). That sentence you keep saying? Time to make it a template.

<img src="assets/screenshots/minds.png" alt="Minds" width="700" />

### For your AI

**⑤ "Every session is a first encounter."**
Each new chat starts from zero: decisions made, dead ends explored, preferences agreed — all gone, and you explain again.
→ **Built-in read-only MCP**: any connected AI can search this full history and read your profile — picking up where you left off instead of meeting you for the first time, every time.

**⑥ "One touch of history, a pile of tokens."**
To give AI your history today, you either inject whole conversations (hundreds of thousands of tokens) or gamble on keyword search and pay for the misses.
→ **The [Memory Transit Protocol](docs/MEMORY-TRANSIT.md)**: hand the AI a 1.5K-token map first, let it decide whether and where, then drill down layer by layer — ~4K tokens end to end, any conversation reachable within three transfers. No direct route promised; arrival guaranteed.

All of this happens on your machine — the app **cannot** send data anywhere. Not "we promise not to"; it simply cannot reach the network.

## Supported AI tools

The app reads exactly these three locations, read-only, never modifying originals:

| Source | Path |
| --- | --- |
| Claude Code | `~/.claude/projects/**/*.jsonl` |
| Claude desktop (local Agent mode) | `~/Library/Application Support/Claude/local-agent-mode-sessions/` |
| Codex | `~/.codex/sessions/**/*.jsonl` |

> Note: you need to have used at least one of these — MindBus collects conversations you already have. No history, empty box.

Parsers for Cursor, OpenClaw, and GitHub Copilot are in the repo but not yet enabled — they need more real-world samples to validate. Contributions welcome.

## Under the hood

Three technical baselines, one for each word of the positioning:

**"Your" — data never leaves your machine.** The app cannot make a network request. Verify it yourself:

```bash
grep -rn "URLSession\|URLRequest" MindBus/
```

**No output.** No accounts, no crash reporting, no analytics. Parsing and indexing happen locally; the index is a SQLite file on your disk. The only network feature is the update check (Sparkle → GitHub Releases, one-click off; the networking lives inside Sparkle, not in this repo).

**"Browse anytime" — a local full-text engine.** BM25 with dual tokenizers (Chinese and English each get their own), a personal lexicon learned from your own corpus, query expansion, and project-context weighting. Minds is zero-LLM throughout — every line traces back to counts, dates, conversations.

**"Minimal token cost" — the [Memory Transit Protocol](docs/MEMORY-TRANSIT.md).** A five-step disclosure ladder (map → line → search → digest → original), token bill published; the structural path is capped at three hops, 100% reachable, independent of retrieval luck.

## How to use

### As a person

Open the app; it scans automatically and the list is ready in seconds:

- **Search**: Chinese or English keywords, highlighted hits, click to jump to the message.
- **Browse**: filter by tool / project / time; project color tags; a gold breathing dot marks active conversations.
- **Star & relay**: star key messages; "relay copy" carries selected content into any new chat.
- **Minds**: your own portrait — phrases you repeat, verbs you delegate with, catchphrases, activity heatmaps.

### As an AI

Two sentences. First, tell your AI:

> Register `/Applications/MindBus.app/Contents/MacOS/mindbus-mcp` as an MCP server named mindbus

It configures itself. Second, add to your `CLAUDE.md` (or `AGENTS.md`):

> When past decisions, project history, or "previously / last time" come up, search the original conversations with mindbus's memory_search first; before starting a new task, read my preferences with minds_read.

Everything is read-only except profile enrichment (source-traced, awaiting your confirmation) — the index opens read-only and cannot be modified.

## Install

Download `MindBus-x.y.z.dmg` from [Releases](https://github.com/BaoWeiiii/mindbus/releases/latest) (universal for Apple Silicon and Intel), drag into Applications. The DMG is signed with an Apple Developer ID and notarized — it opens with a double-click.

Or build from source:

```bash
git clone https://github.com/BaoWeiiii/mindbus.git
cd mindbus
swift build -c release
./scripts/build-release.sh        # packages MindBus.app (add --dmg for a DMG)
```

Requires Xcode 15+ / Swift 5.9+, macOS 13.0 or later.

## Development

```
MindBus/
├── Core/          # MindBusCore — parsing and indexing, pure logic, independently testable
│   ├── Loaders/   # per-tool JSONL parsers
│   ├── DB/        # incremental SQLite index
│   ├── Markdown/  # body segmentation and code block detection
│   └── Models/    # Conversation / Message / ContentBlock
├── Views/         # SwiftUI interface (menu bar panel / browser / settings)
└── Config/        # design tokens and native messaging (local IPC, not network)
```

All parsing lives in the `MindBusCore` library target, which doesn't depend on SwiftUI and can be tested without the UI:

```bash
swift test          # 800+ tests — all green is the bar for merging
```

Adding a new source is usually one Loader plus a test suite — see [`CodexLoader.swift`](MindBus/Core/Loaders/CodexLoader.swift) for reference.

## FAQ

**The app is empty?**
MindBus collects conversations you already have. No network, no cloud — use Claude Code / Claude desktop / Codex at least once first.

**Does deleting a conversation touch the original file?**
Never. Deletion only removes it from MindBus (list, search, Minds, archived copy). Every deletion test asserts the source file is still on disk.

**Is Minds AI-generated?**
No. Every line is counted from your own conversations — zero LLM. The only AI touchpoint is MCP's `minds_enrich`, where a host model may suggest profile entries: each one is source-traced and awaits your confirmation.

## Contributing

Issues and PRs welcome, in English or Chinese:

- **All tests green is the bar** — run `swift test` before submitting; parser or index changes need accompanying tests.
- **New conversation sources** are the most wanted contribution: one Loader + tests plugs into the whole pipeline. See [`CodexLoader.swift`](MindBus/Core/Loaders/CodexLoader.swift).
- **Zero external dependencies** is a project invariant (Sparkle is the sole exception) — open an Issue before introducing any.

## Uninstall

Data sovereignty includes leaving cleanly. MindBus touches exactly two places on your disk:

```bash
rm -rf /Applications/MindBus.app
rm -rf ~/Library/Application\ Support/MindBus     # local index (rebuildable from source files anytime)
```

The login item deactivates automatically once the app is gone. Your original transcripts (`~/.claude` etc.) were never modified — uninstalling doesn't affect them.

## License

[MIT](LICENSE)
