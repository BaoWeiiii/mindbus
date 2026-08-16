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

You run Claude Code in the terminal, switch to Claude Desktop's local agent mode, then spend an afternoon in Codex. Three tools, three transcript formats, three directories buried somewhere under `~/`.

Finding that decision you made last week means digging through all of them.

MindBus is a macOS menu bar app that reads those transcripts into one window so you can **search, read, copy, star, and relay** across them.

On top of that, it turns your accumulated conversations into something you can see:

- **Sanctuary** — every conversation keeps a compressed local copy. Claude Code only retains 30 days; here they stay forever, and the app shows you how many have already outlived that window.
- **Minds** — a mechanical self-portrait counted from your own conversations: what you most often ask AI to do (delegation verbs), the shape of your questions, each project's first words, unfinished threads, recurring questions, your catchphrases, knowledge flowing between projects, an activity heatmap… 26 sections, every line counted, not generated (zero LLM involved).
- **Your Report** — 1/3/12-month stat cards on demand: cross-tool split, busiest day, leverage ratio, your archetype. Redacted export available.
- **Deletion you control** — delete conversations or single messages; after confirmation they vanish completely from MindBus (list, search, Minds, archived copy) and never come back on rescan — while the original files in your tool directories are **never touched**.

And it *can't* send your data anywhere — not because we promise not to, but because there is no networking code in the source.

## Screenshots

The conversation browser — sidebar per tool, project-tagged list, searchable detail with starring and relay:

<img src="assets/screenshots/browser.png" alt="Browser" width="840" />

Minds — your mechanical self-portrait, surprise sections first (Sanctuary / On This Day / Unfinished Threads…):

<img src="assets/screenshots/minds.png" alt="Minds" width="700" />

Your report & activity map:

<p>
<img src="assets/screenshots/wrapped.png" alt="Report" width="420" />
</p>
<img src="assets/screenshots/heatmap.png" alt="Heatmap" width="700" />

> All screenshots use built-in demo data (Chinese UI shown; the app ships bilingual).

## Supported sources

The app reads these three locations, read-only, without modifying the originals:

| Source | Path |
| --- | --- |
| Claude Code | `~/.claude/projects/**/*.jsonl` |
| Claude Desktop (local agent mode) | `~/Library/Application Support/Claude/local-agent-mode-sessions/` |
| Codex | `~/.codex/sessions/**/*.jsonl` |

Parsers for Cursor, OpenClaw and GitHub Copilot exist in the codebase but aren't wired into the scan yet — their format handling needs validation against more real-world samples first.

## For your AI: MCP Server

The app ships with a read-only MCP server. To hook it up, just tell your AI:

> Register `/Applications/MindBus.app/Contents/MacOS/mindbus-mcp` as an MCP server named mindbus

It will configure itself. Then add one line to your `CLAUDE.md` (or `AGENTS.md`) so the habit sticks:

> When past decisions, project history, or "previously / last time" come up, search the original conversations with mindbus's memory_search first; before starting a new task, read my preferences with minds_read.

Your AI can then search and read all your past conversations, plus your Minds profile. Everything is read-only except profile enrichment (each entry source-traced, awaiting your confirmation) — the index is opened read-only and cannot be modified.

## Privacy

This is the whole point of the project. Rather than asking you to trust a promise, verify it yourself — clone the repo and run:

```bash
grep -rn "URLSession\|URLRequest" MindBus/
```

**No output.** This app has no ability to make network requests:

- **The only external dependency is [Sparkle](https://github.com/sparkle-project/Sparkle)** (the auto-update framework, see below). No crash reporting SDK, no analytics.
- **No accounts.** Nothing to register, nothing to sign into.
- **Conversations never leave your machine.** Parsing and indexing happen locally; the index is a SQLite file on your own disk.
- **Read-only.** The app never modifies the transcript files your AI tools produce.

**The only network feature is the update check** (Sparkle → GitHub Releases): on by default, one toggle in Settings to turn off, every update EdDSA-signature-verified. New versions never interrupt you — they light up a banner at the top of Settings. Turned off, the app is fully offline — and the `grep` above still returns nothing (the networking code lives in the Sparkle framework, not in this repo's sources).

## Installation

### Download the DMG

Grab `MindBus-x.y.z.dmg` from [Releases](https://github.com/BaoWeiiii/mindbus/releases/latest) (Universal — Apple Silicon & Intel), open it, and drag MindBus into Applications.

The DMG is signed with an Apple Developer ID and notarized — it opens with a double-click.

### Build from source

```bash
git clone https://github.com/BaoWeiiii/mindbus.git
cd mindbus
swift build -c release
./scripts/build-release.sh        # produces MindBus.app (add --dmg for a DMG)
```

Requires Xcode 15+ / Swift 5.9+ and macOS 13.0 or later. Apps you build yourself carry no quarantine flag, so Gatekeeper won't block them.

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
