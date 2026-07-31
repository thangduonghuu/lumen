<p align="center">
  <img src="assets/logo.svg" width="96" alt="Lumen logo">
</p>

<h1 align="center">Lumen</h1>

<p align="center"><strong>AI command suggestions for Zsh — inline, on demand, no separate terminal required.</strong></p>

<p align="center">
  <img alt="platform" src="https://img.shields.io/badge/platform-macOS-lightgrey">
  <img alt="shell" src="https://img.shields.io/badge/shell-zsh-89e051">
  <img alt="rust" src="https://img.shields.io/badge/rust-stable-orange">
  <img alt="swift" src="https://img.shields.io/badge/swift-5.9%2B-f05138">
</p>

<p align="center">
  <a href="#features">Features</a> ·
  <a href="#architecture">Architecture</a> ·
  <a href="#installation">Installation</a> ·
  <a href="#configuration">Configuration</a> ·
  <a href="#usage--keybindings">Usage</a> ·
  <a href="#menu-bar-toggle">Menu bar toggle</a> ·
  <a href="#known-limitations">Known limitations</a>
</p>

---

## Overview

Lumen embeds AI-assisted command completion directly into an existing Zsh
session — not a separate terminal emulator, and not an always-on background
process. Nothing happens while you type; a debounced background request
(or an immediate Ctrl-Space) asks a long-running Rust daemon for
completions, which render inline below the prompt. An optional macOS menu
bar app lets you pause or resume automatic suggestions without touching the
terminal.

This is a single repo with three pieces working together, documented below
in one place: the daemon/client (Rust), the Zsh plugin (shell/zsh/), and
the menu bar toggle (Swift).

## Features

- **Inline, non-intrusive suggestions** — candidates render as a small card
  below the prompt; nothing appears unless you're actively typing or ask
  for it.
- **Two trigger modes** — a short debounce fires suggestions automatically
  as you type, or Ctrl-Space asks immediately, bypassing the debounce.
- **Local-first inference** — the default provider is
  [Ollama](https://ollama.com) (`qwen2.5-coder`), so suggestions work fully
  offline once the model is pulled.
- **Cloud fallback** — an Anthropic (Claude) backend is available, and
  automatically falls back to the local provider on network or API failure.
- **Known-command fast path** — common tools (git, docker, kubectl, npm)
  resolve their subcommands from a static table instead of an AI call, so
  the obvious cases are instant and don't cost a model round-trip.
- **Menu bar control** — toggle automatic suggestions on/off from the menu
  bar; the state syncs to every open shell. Manual Ctrl-Space always works
  regardless of the toggle.
- **No lingering background process** — the daemon is killed when the
  shell that started it exits, and auto-spawns fresh on the next request
  from any other open shell.

## Architecture

```
Zsh (ZLE)  --keystroke (debounced) or Ctrl-Space-->  ai-suggest-client  --unix socket-->  ai-suggest-daemon
   ^                                                                                           |
   |                                                                                           v
   +------------------------ POSTDISPLAY ghost text + zle -M list -----------------  AI provider (Ollama / Anthropic)

ai-suggest-menubar  --shared state file (~/.cache/ai-suggest/enabled)-->  Zsh plugin
```

- **ai-suggest-daemon**: long-running background process, listens on
  `~/.cache/ai-suggest/daemon.sock`. Collects context (cwd, git branch/dirty
  count, detected project type, recent history) and asks the configured AI
  provider for up to `max_suggestions` command completions. Each connection
  is handled independently (no shared mutable state), so it's safe for the
  plugin to fire concurrent/overlapping requests.
- **ai-suggest-client**: thin, short-lived binary the Zsh plugin shells out
  to. Auto-spawns the daemon if it isn't running yet.
- **shell/zsh/ai-suggest.plugin.zsh**: ZLE integration. By default, every
  buffer-editing keystroke schedules a debounced background request (see
  `AI_SUGGEST_DEBOUNCE_MS`); the top suggestion renders as inline ghost
  text once it arrives, with the rest reachable via Up/Down. Ctrl-Space
  still asks immediately and synchronously, bypassing the debounce.
- **ai-suggest-menubar**: SwiftUI menu bar app that toggles automatic
  suggestions on/off via a shared state file (see
  [Menu bar toggle](#menu-bar-toggle) below).

## Repository structure

| Path | Description |
| --- | --- |
| [`ai-shell-suggest/`](ai-shell-suggest/) | Rust workspace: the daemon, client, and Zsh plugin. |
| [`ai-suggest-menubar/`](ai-suggest-menubar/) | SwiftUI menu bar app for toggling automatic suggestions. |
| [`assets/`](assets/) | Shared repo assets (logo). |

## Requirements

- macOS with Zsh
- [Rust](https://www.rust-lang.org/tools/install) (stable toolchain) to build the daemon/client
- [Ollama](https://ollama.com) for local inference, and/or an `ANTHROPIC_API_KEY` for the cloud provider
- Swift 5.9+ / Xcode command line tools, only if building the menu bar app

## Installation

Build and install the daemon and client:

```sh
cd ai-shell-suggest
cargo build --release
cp target/release/ai-suggest-daemon target/release/ai-suggest-client /opt/homebrew/bin/
```

Add to `~/.zshrc`:

```sh
source /path/to/ai-shell-suggest/shell/zsh/ai-suggest.plugin.zsh
```

The daemon does not need to be started manually — the first trigger press
will auto-spawn it if `~/.cache/ai-suggest/daemon.sock` isn't reachable.

By default, the daemon is killed when a shell that sourced this plugin
exits (`zshexit` hook), so it doesn't linger in the background after you
close your terminal. If another ai-suggest-enabled shell is still open, it
just auto-spawns a fresh daemon on its next request. Set
`AI_SUGGEST_KILL_DAEMON_ON_EXIT=0` before sourcing the plugin to keep the
daemon running across shell sessions instead.

## Providers

- **Local (default)**: [Ollama](https://ollama.com), model `qwen2.5-coder`
  by default. Runs fully offline once the model is pulled:
  ```sh
  ollama pull qwen2.5-coder
  ollama serve   # if not already running
  ```
- **Cloud**: Anthropic (Claude), OpenAI, or Gemini vendor selectable in
  config. API keys are never stored on disk — set one of
  `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` / `GEMINI_API_KEY` in your shell
  environment. If `provider = "cloud"` fails (no network, bad key), the
  daemon automatically falls back to the local provider when
  `fallback_to_local_on_cloud_error = true`.

  Note: only the Anthropic backend is currently implemented; OpenAI/Gemini
  are recognized in config but not yet wired to a provider.

## Configuration

`~/.config/ai-suggest/config.toml` is created with defaults on first run:

```toml
provider = "local"                       # "local" or "cloud"
fallback_to_local_on_cloud_error = true
max_suggestions = 5
debounce_ms = 250                        # unused by the on-demand plugin; kept for future async mode

[local]
host = "http://localhost:11434"
model = "qwen2.5-coder"                  # must match a tag you've pulled,
                                          # e.g. "qwen2.5-coder:14b"

[cloud]
vendor = "anthropic"                     # "anthropic" | "openai" | "gemini"
model = "claude-sonnet-5"
```

Shell-side behavior is configured via environment variables set before
sourcing the plugin — see [Usage / keybindings](#usage--keybindings) below.

## Usage / keybindings

Suggestions appear automatically: pause briefly after typing (default
250ms, see `AI_SUGGEST_DEBOUNCE_MS`) and the top candidate shows up as
inline ghost text.

| Key | Action |
|---|---|
| Ctrl-Space (`$AI_SUGGEST_KEY`) | Ask AI immediately, bypassing the debounce |
| Up / Down | Cycle through candidates (falls back to normal history search when no suggestion is shown) |
| Tab / Right arrow (at end of line) | Accept the shown suggestion |
| Ctrl-G | Dismiss the current suggestion (keeps what you typed) |

Other environment variables (set before sourcing the plugin):

| Variable | Default | Purpose |
|---|---|---|
| `AI_SUGGEST_CLIENT_BIN` | `ai-suggest-client` (resolved via `$PATH`) | Path to the client binary |
| `AI_SUGGEST_HISTORY_COUNT` | `5` | How many recent history lines to send as context |
| `AI_SUGGEST_AUTO` | `1` | `0` disables automatic as-you-type suggestions, Ctrl-Space-only |
| `AI_SUGGEST_DEBOUNCE_MS` | `250` | Debounce window for automatic suggestions |
| `AI_SUGGEST_KILL_DAEMON_ON_EXIT` | `1` | `0` keeps the daemon running across shell sessions instead of killing it on shell exit |
| `AI_SUGGEST_DEBUG` | `0` | `1` logs every request to `$AI_SUGGEST_DEBUG_LOG` (default `/tmp/ai-suggest-debug.log`) |

## Menu bar toggle

`ai-suggest-menubar` is a small SwiftUI app that toggles **automatic**
(as-you-type) suggestions on or off without touching the terminal. The
icon shows ✨ when on, ⏸ when paused.

Build and run:

```sh
cd ai-suggest-menubar
swift build -c release
.build/release/ai-suggest-menubar &
```

It runs as a menu-bar-only accessory (no Dock icon, no app-switcher entry)
and does not auto-start on login — launch it manually, or set it up as a
[LaunchAgent](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html)
if you want it running every session. Quit it from its menu (**Quit
ai-suggest**) — this only stops the toggle app itself, not the
`ai-suggest-daemon` background process, which the shell plugin manages
independently.

**How it syncs with the shell:** this app and the Zsh plugin are separate,
unrelated processes with no shared memory — the only thing connecting them
is a single state file, `~/.cache/ai-suggest/enabled`. Toggling the switch
writes `1` or `0` to that file; the Zsh plugin reads it before firing an
*automatic* suggestion. A missing file means enabled by default, so the
shell plugin works normally even if this app has never been run. Manual
suggestions (Ctrl-Space) are **not** gated by this toggle on purpose —
pausing automatic suggestions never blocks an explicit ask.

## Known limitations

- Suggestions render as inline ghost text (single line, cycled via
  Up/Down), not a separate multi-row popup box — this is simpler and more
  robust in plain ZLE than hand-drawing a floating dropdown, at the cost of
  only showing one candidate at a time.
- A keystroke that arrives while a request is already mid-flight (past the
  debounce, waiting on the AI provider) doesn't force-kill that request —
  its result is just discarded on arrival if it's gone stale. With a slow
  local model this means a burst of typing without pauses can fire more
  provider calls than strictly necessary; only their *display* is
  debounced/deduplicated, not the network calls themselves.
- OpenAI and Gemini cloud vendors are configured but not implemented yet.
- Bash and Fish shells are not supported yet.
