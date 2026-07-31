<p align="center">
  <img src="assets/logo.svg" width="96" alt="Lumen logo">
</p>

<h1 align="center">Lumen</h1>

<p align="center"><strong>Deterministic command suggestions for Zsh — inline, on demand, no AI round-trip required.</strong></p>

<p align="center">
  <img alt="platform" src="https://img.shields.io/badge/platform-macOS-lightgrey">
  <img alt="shell" src="https://img.shields.io/badge/shell-zsh-89e051">
  <img alt="swift" src="https://img.shields.io/badge/swift-5.9%2B-f05138">
</p>

<p align="center">
  <a href="#features">Features</a> ·
  <a href="#architecture">Architecture</a> ·
  <a href="#installation">Installation</a> ·
  <a href="#usage--keybindings">Usage</a> ·
  <a href="#menu-bar-toggle">Menu bar toggle</a> ·
  <a href="#known-limitations">Known limitations</a>
</p>

---

## Overview

Lumen embeds Fig/Kiro-CLI-style command completion directly into an
existing Zsh session — not a separate terminal emulator, and not an
always-on background process. As you type (or on Ctrl-Space), the Zsh
plugin matches the current buffer against known, hand-picked data — a
tool's subcommands, directories under `cd`, or your repo's own git
branches — and renders the result as a real floating panel via a
companion macOS menu bar app.

There's no AI provider, no daemon, and no network round-trip anywhere in
this path: every suggestion resolves synchronously from local data (a
static table, a directory glob, or `git for-each-ref`), so it's instant
and never wrong about what a tool's own subcommands or your own
branches/directories actually are.

This is a repo with two pieces working together, documented below in one
place: the Zsh plugin (shell/zsh/) and the menu bar overlay (Swift).

## Features

- **Inline, non-intrusive suggestions** — candidates render as a small
  floating card positioned against your terminal cursor; nothing appears
  unless you're actively typing or ask for it.
- **Two trigger modes** — automatic as-you-type suggestions, or Ctrl-Space
  to ask immediately for the current buffer.
- **Known-tool subcommands** — git, docker, kubectl, and npm resolve their
  subcommands from a static table (e.g. typing `git ` lists `status`,
  `add`, `commit`, ...).
- **Directory completion after `cd`** — typing `cd Doc` suggests
  `Documents/`; accepting drills into that directory so you can keep
  Tab-ing deeper without the panel immediately popping the next level on
  top of you.
- **Git branch suggestions** — once you've typed `git checkout`, `switch`,
  `merge`, `rebase`, or `branch`, the next word suggests your repo's local
  branches (via `git for-each-ref`, read fresh every time).
- **Menu bar control** — toggle automatic suggestions on/off from the menu
  bar; the state syncs to every open shell. Manual Ctrl-Space always works
  regardless of the toggle.

## Architecture

```
Zsh (ZLE)  --keystroke or Ctrl-Space-->  deterministic matchers (git/docker/kubectl/npm tables, cd glob, git branches)
                                                          |
                                                          v
                                          Unix socket (~/.cache/ai-suggest/overlay.sock)
                                                          |
                                                          v
                                          ai-suggest-menubar (native floating panel)

ai-suggest-menubar  --shared state file (~/.cache/ai-suggest/enabled)-->  Zsh plugin
```

- **shell/zsh/ai-suggest.plugin.zsh**: ZLE integration and the only place
  suggestions are computed. Every buffer-editing keystroke re-evaluates the
  matchers (`AI_SUGGEST_AUTO=1`, the default); Ctrl-Space asks immediately
  regardless. Matches are sent fire-and-forget over a Unix socket to the
  overlay app — this shell side never draws anything itself and has no
  idea whether the panel actually renders.
- **ai-suggest-menubar**: SwiftUI menu bar app. Owns the floating panel
  (positioned against the terminal's actual on-screen location via the
  Accessibility API — see `TerminalPositioner.swift`) and the automatic-
  suggestions on/off toggle.

## Repository structure

| Path | Description |
| --- | --- |
| [`ai-shell-suggest/shell/zsh/`](ai-shell-suggest/shell/zsh/) | The Zsh plugin — this is the active suggestion engine. |
| [`ai-suggest-menubar/`](ai-suggest-menubar/) | SwiftUI menu bar app that draws the floating panel and toggles automatic suggestions. |
| [`ai-shell-suggest/src/`](ai-shell-suggest/src/) | A Rust daemon/client for AI-generated suggestions (Ollama/Anthropic). Not wired into the live path — see [Parked: the Rust daemon](#parked-the-rust-daemon). |
| [`assets/`](assets/) | Shared repo assets (logo). |

## Requirements

- macOS with Zsh
- Swift 5.9+ / Xcode command line tools, to build the menu bar app

## Installation

Add to `~/.zshrc`:

```sh
source /path/to/ai-shell-suggest/shell/zsh/ai-suggest.plugin.zsh
```

Then build and run the menu bar app so suggestions actually have somewhere
to render — see [Menu bar toggle](#menu-bar-toggle) below. Without it
running, the plugin still matches your buffer correctly, it just has no
panel to draw the result in (fails silently, never blocks typing).

## Usage / keybindings

Suggestions appear automatically as you type (`AI_SUGGEST_AUTO=1`, the
default) whenever the buffer matches a known shape: a tool with a static
subcommand table, `cd <partial>`, or a git branch-taking subcommand.

| Key | Action |
|---|---|
| Ctrl-Space (`$AI_SUGGEST_KEY`) | Ask immediately for the current buffer |
| Up / Down | Cycle through candidates (falls back to normal history search when no suggestion is shown) |
| Tab / Right arrow (at end of line) | Accept the shown suggestion |
| Ctrl-G | Dismiss the current suggestion (keeps what you typed) |

Other environment variables (set before sourcing the plugin):

| Variable | Default | Purpose |
|---|---|---|
| `AI_SUGGEST_AUTO` | `1` | `0` disables automatic as-you-type suggestions, Ctrl-Space-only |
| `AI_SUGGEST_KEY` | `^@` (Ctrl-Space) | Manual trigger keybinding |
| `AI_SUGGEST_OVERLAY` | `1` | `0` disables the floating panel entirely (no other rendering path exists) |

## Menu bar toggle

`ai-suggest-menubar` is a small SwiftUI app that owns the floating
suggestion panel and toggles **automatic** (as-you-type) suggestions on or
off without touching the terminal. The icon shows ✨ when on, ⏸ when
paused.

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
ai-suggest**).

**How it syncs with the shell:** this app and the Zsh plugin are separate,
unrelated processes with no shared memory — the only things connecting
them are a state file and a socket, both under `~/.cache/ai-suggest/`.
Toggling the switch writes `1` or `0` to `enabled`; the Zsh plugin reads it
before firing an *automatic* suggestion. A missing file means enabled by
default, so the shell plugin works normally even if this app has never
been run. Manual suggestions (Ctrl-Space) are **not** gated by this toggle
on purpose — pausing automatic suggestions never blocks an explicit ask.

## Parked: the Rust daemon

An earlier version of this project (see `goal-ai-shell-suggest.md`) routed
suggestions through a Rust daemon/client (`ai-shell-suggest/src/`) that
called out to Ollama or Anthropic for AI-generated completions. That path
is no longer wired into the Zsh plugin — the deterministic matchers above
cover the common cases (tool subcommands, paths, branches) instantly and
without ever needing to guess. The Rust source is still in the repo,
unused, in case AI-backed suggestions are worth revisiting later; it isn't
built or run by anything documented here.

## Known limitations

- Suggestion sources are deterministic and hand-picked (git/docker/kubectl/
  npm subcommands, `cd` targets, git branches) — there's no free-form or
  AI-generated suggestion for commands outside those tables.
- The floating panel requires `ai-suggest-menubar` to be running and
  granted Accessibility permission; without it, matching still happens but
  nothing renders.
- Bash and Fish shells are not supported.
