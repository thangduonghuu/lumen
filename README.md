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
  <a href="#known-tool-subcommand-coverage">Tool coverage</a> ·
  <a href="#the-lumen-menu-bar-app">Menu bar app</a> ·
  <a href="#troubleshooting">Troubleshooting</a> ·
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
companion macOS menu bar app, also called **Lumen**.

There's no AI provider, no daemon, and no network round-trip anywhere in
this path: every suggestion resolves synchronously from local data (a
static table, a directory glob, or `git for-each-ref`), so it's instant
and never wrong about what a tool's own subcommands or your own
branches/directories actually are.

This is a repo with two pieces working together, documented below in one
place: the Zsh plugin (`ai-shell-suggest/shell/zsh/`) and the menu bar
overlay app (`Lumen/`, Swift).

## Features

- **Inline, non-intrusive suggestions** — candidates render as a small
  floating card positioned against your terminal cursor; nothing appears
  unless you're actively typing or ask for it.
- **Two trigger modes** — automatic as-you-type suggestions, or Ctrl-Space
  to ask immediately for the current buffer.
- **Broad tool coverage** — git, docker, kubectl, npm, yarn, pnpm, aws,
  gcloud, az, terraform, helm, gh, glab, the Kafka CLI scripts, and
  rabbitmqctl all resolve their subcommands from static tables. See
  [Known-tool subcommand coverage](#known-tool-subcommand-coverage) for
  the full list.
- **Real per-tool brand icons** — each suggestion row shows the actual
  logo of the tool it belongs to (official brand SVGs, not a generic
  glyph), plus dedicated icons for directory (`cd`) and git-branch rows.
- **Nested subcommands and flags** — for tools whose subcommand is itself a
  management command, the next word resolves too (e.g. `docker image `
  lists `ls`, `build`, `rm`, ...; `git stash ` lists `push`, `pop`, `list`,
  ...), and once you start a flag (`-`) — or even just finish a leaf
  subcommand and hit space — the flags for that specific (possibly nested)
  subcommand show up (e.g. `docker ps -` lists `-a`, `-q`, `--filter`, ...).
- **Generic flag fallback** — typing `-` anywhere a tool/subcommand doesn't
  have its own hand-picked flag table falls back to common CLI conventions
  (`-h`/`--help`, `--version`, `-v`/`--verbose`, `-q`/`--quiet`, `--debug`,
  `-y`/`--yes`, `-f`/`--force`, `--dry-run`, `-o`/`--output`, `--no-color`,
  `--json`, `--config`) instead of showing nothing.
- **Case-insensitive directory completion after `cd`** — typing `cd p`
  suggests `projects/`, `Pictures/`, and `Personal/` regardless of case;
  accepting drills into that directory so you can keep Tab-ing deeper
  without the panel immediately popping the next level on top of you.
- **Git branch suggestions** — once you've typed `git checkout`, `switch`,
  `merge`, `rebase`, or `branch`, the next word suggests your repo's local
  branches (via `git for-each-ref`, read fresh every time).
- **Suggestion chaining** — accepting a suggestion immediately shows what
  typically comes next (e.g. picking `git add ` immediately offers file
  paths), instead of going silent until your next keystroke.
- **Menu bar control** — toggle automatic suggestions on/off from the menu
  bar; the state syncs to every open shell. Manual Ctrl-Space always works
  regardless of the toggle.

## Architecture

```
Zsh (ZLE)  --keystroke or Ctrl-Space-->  deterministic matchers (per-tool subcommand/flag tables, cd glob, git branches)
                                                          |
                                                          v
                                          Unix socket (~/.cache/ai-suggest/overlay.sock)
                                                          |
                                                          v
                                          Lumen.app (native floating panel)

Lumen.app  --shared state file (~/.cache/ai-suggest/enabled)-->  Zsh plugin
```

- **`ai-shell-suggest/shell/zsh/ai-suggest.plugin.zsh`**: ZLE integration
  and the only place suggestions are computed. Every buffer-editing
  keystroke re-evaluates the matchers (`AI_SUGGEST_AUTO=1`, the default);
  Ctrl-Space asks immediately regardless. Matches are sent fire-and-forget
  over a Unix socket to the overlay app — this shell side never draws
  anything itself and has no idea whether the panel actually renders.
- **`Lumen/`**: SwiftUI menu bar app. Owns the floating panel (positioned
  against the terminal's actual on-screen location via the Accessibility
  API — see `TerminalPositioner.swift`) and the automatic-suggestions
  on/off toggle.

## Repository structure

| Path | Description |
| --- | --- |
| [`ai-shell-suggest/shell/zsh/`](ai-shell-suggest/shell/zsh/) | The Zsh plugin — this is the active suggestion engine. |
| [`Lumen/`](Lumen/) | SwiftUI menu bar app that draws the floating panel and toggles automatic suggestions. Builds to `Lumen.app`. |
| [`ai-shell-suggest/src/`](ai-shell-suggest/src/) | A Rust daemon/client for AI-generated suggestions (Ollama/Anthropic). Not wired into the live path — see [Parked: the Rust daemon](#parked-the-rust-daemon). |
| [`assets/`](assets/) | Shared repo assets (logo, used as the basis for `Lumen.app`'s icon too). |

## Requirements

- macOS 13+ with Zsh
- Swift 5.9+ / Xcode command line tools, to build the menu bar app
- Accessibility permission granted to `Lumen.app` (see step 4 below) — the
  floating panel can't position itself against your terminal without it

## Installation

### 1. Add the Zsh plugin to your shell

```sh
echo 'source /path/to/Lumen/ai-shell-suggest/shell/zsh/ai-suggest.plugin.zsh' >> ~/.zshrc
```

Open a new terminal tab (or `source ~/.zshrc`) to pick it up. At this
point suggestions are already being *computed* correctly — you just have
nowhere to see them yet, since that's the menu bar app's job.

### 2. Build the menu bar app

**a. Confirm the Swift toolchain is available:**

```sh
swift --version
xcode-select -p
```

The first should print Swift 5.9 or newer; the second should print a path
(e.g. `/Library/Developer/CommandLineTools` or an Xcode path). If either
command fails, install the Xcode Command Line Tools first:

```sh
xcode-select --install
```

**b. Build and package the app:**

```sh
cd /path/to/Lumen/Lumen
./build.sh
```

This one script does everything needed to produce a working, launchable
app — nothing else to run by hand:

1. `swift build -c release` — compiles the executable
2. Packages it as a real `.app` bundle at `Lumen/Lumen.app` (`Contents/MacOS/Lumen`)
3. Generates `Contents/Info.plist` from scratch every run (bundle
   identifier, `LSUIElement` so it's menu-bar-only, icon reference — not
   hand-maintained separately, so the bundle is fully reproducible from
   this script alone)
4. Copies the app icon (`Contents/Resources/Lumen.icns`) and the bundled
   per-tool brand SVGs (the nested `Lumen_Lumen.bundle/` SwiftPM generates)
   into the bundle
5. Re-signs the whole bundle with an ad-hoc code signature (`codesign
   --force --deep --sign -` — no paid Apple Developer ID needed for local
   use)

**c. Verify it built successfully:**

```sh
ls -la Lumen.app/Contents/MacOS/Lumen   # the executable should exist
codesign -dv Lumen.app                  # should print "Signature=adhoc" with no errors
```

You should see `Built Lumen.app — run it with: open "Lumen.app"` as the
script's last line of output. If `swift build` fails instead, the error
will be from the Swift compiler itself — check the Swift version from
step (a) matches what `Package.swift` expects (5.9+).

**Rebuilding after changing the Swift source:** just run `./build.sh`
again — it's safe to re-run any time. For a fully clean rebuild (e.g. if
something seems stale), remove the build cache first:

```sh
rm -rf .build Lumen.app
./build.sh
```

Remember: every rebuild invalidates Accessibility permission (see [step 4](#4-grant-accessibility-permission)
below and [The Lumen menu bar app](#the-lumen-menu-bar-app)) — re-grant it
after each rebuild, not just the first one.

### 3. Launch it

```sh
open Lumen.app
```

`Lumen.app` is menu-bar-only (`LSUIElement`) — no Dock icon, no
app-switcher entry. Look for the ✨ (or ⏸ if paused) icon in your menu bar.

### 4. Grant Accessibility permission

The very first launch triggers macOS's native permission prompt
automatically. If you miss it or dismiss it:

1. Open **System Settings → Privacy & Security → Accessibility**
2. Find **Lumen** in the list and enable it (or click **+** and add
   `Lumen.app` if it isn't listed)
3. Quit and relaunch `Lumen.app`

Without this, the plugin still matches your buffer correctly — it just
has nowhere to draw the result (fails silently, never blocks typing). See
[Troubleshooting](#troubleshooting) if it still doesn't show up.

### 5. (Optional) Auto-start on login

`Lumen.app` doesn't auto-launch on login by default. Either add it to
**System Settings → General → Login Items**, or set it up as a
[LaunchAgent](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html)
if you want more control (restart-on-crash, logging, etc).

## Usage / keybindings

Suggestions appear automatically as you type (`AI_SUGGEST_AUTO=1`, the
default) whenever the buffer matches a known shape: a tool with a static
subcommand/flag table, `cd <partial>`, or a git branch-taking subcommand.

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

## Known-tool subcommand coverage

All of this comes from static, hand-picked tables in
`ai-suggest.plugin.zsh` — not exhaustive (e.g. git has 40+ porcelain
commands, aws/gcloud have hundreds of subcommands per service), just the
common-case fast path for each tool. Table lookup is by naming convention
from the words you've actually typed, so adding coverage for a new
subcommand/flag is a matter of adding a table, not touching the matching
logic. Anywhere a specific flag table doesn't exist yet, typing `-` falls
back to the generic set described in [Features](#features) instead of
showing nothing.

| Tool | Top-level subcommands | Nested subcommands / flags |
|---|---|---|
| **git** | `status`, `add`, `commit`, `push`, `pull`, `fetch`, `branch`, `checkout`, `switch`, `merge`, `rebase`, `log`, `diff`, `stash`, `reset`, `tag`, `clone`, `init`, `remote`, `cherry-pick`, `revert`, `blame`, `show`, `rm`, `mv`, `clean`, `restore` | `stash` → push/pop/apply/list/show/drop/clear; `remote` → add/remove/rename/set-url/show/prune/-v; flags for log/branch/checkout/diff |
| **docker** | `ps`, `images`, `run`, `build`, `exec`, `logs`, `stop`, `start`, `rm`, `rmi`, `pull`, `push`, `compose`, `network`, `volume`, `inspect`, `tag`, `system`, `container`, `image` | `image`/`container`/`network`/`volume`/`system`/`compose` all have their own sub-subcommand tables; flags for ps/images/run/exec/logs |
| **kubectl** (also `k`) | `get`, `describe`, `logs`, `apply`, `exec`, `delete`, `create`, `edit`, `rollout`, `scale`, `port-forward`, `config`, `top`, `cp`, `label`, `run`, `expose` | `config` → get-contexts/use-context/current-context/set-context/view/delete-context; `rollout` → status/undo/restart/history/pause/resume; flags for get/exec |
| **npm** | `run`, `install`, `start`, `test`, `uninstall`, `update`, `init`, `publish`, `list`, `outdated`, `audit`, `ci`, `link`, `cache`, `version`, `exec` | `cache` → clean/verify/add/ls; flags for install |
| **yarn** | `add`, `remove`, `install`, `run`, `dev`, `build`, `start`, `test`, `upgrade`, `list`, `why`, `outdated`, `cache`, `init`, `workspaces`, `dlx` | — |
| **pnpm** | `add`, `remove`, `install`, `run`, `dev`, `build`, `start`, `test`, `update`, `list`, `why`, `outdated`, `exec`, `dlx`, `init` | — |
| **aws** | `s3`, `ec2`, `lambda`, `iam`, `logs`, `sts`, `cloudformation`, `ecr`, `ecs`, `eks`, `ssm`, `dynamodb`, `rds`, `secretsmanager`, `cloudwatch`, `sns`, `sqs`, `route53`, `configure`, `sso` | `s3`/`ec2`/`lambda`/`iam`/`logs`/`sts`/`cloudformation`/`ecr`/`ecs`/`eks`/`ssm` each have their own operation tables |
| **gcloud** | `compute`, `container`, `run`, `functions`, `storage`, `iam`, `projects`, `auth`, `config`, `sql`, `app`, `builds`, `logging`, `pubsub`, `secrets` | `compute` → instances/ssh/scp/networks/firewall-rules/disks; `container` → clusters/images/node-pools |
| **az** | `vm`, `aks`, `group`, `storage`, `webapp`, `functionapp`, `acr`, `login`, `account`, `keyvault`, `network`, `sql`, `monitor` | — |
| **terraform** (also `tf`) | `init`, `plan`, `apply`, `destroy`, `validate`, `fmt`, `show`, `output`, `state`, `import`, `workspace`, `providers`, `graph`, `taint`, `untaint`, `refresh`, `console`, `get`, `version`, `login`, `force-unlock` | `state` → list/show/mv/rm/pull/push/replace-provider; `workspace` → list/new/select/delete/show |
| **helm** | `install`, `upgrade`, `uninstall`, `list`, `status`, `rollback`, `repo`, `search`, `template`, `get`, `history`, `pull`, `create`, `lint`, `show`, `dependency` | `repo` → add/update/list/remove |
| **gh** (GitHub CLI) | `pr`, `issue`, `repo`, `run`, `workflow`, `release`, `gist`, `auth`, `browse`, `api`, `status`, `search` | `pr`/`issue`/`repo`/`run` each have their own subcommand tables |
| **glab** (GitLab CLI) | `mr`, `issue`, `repo`, `ci`, `pipeline`, `release`, `auth`, `label`, `variable`, `api` | `mr`/`ci` have their own subcommand tables |
| **kafka-topics**, **kafka-console-producer**, **kafka-console-consumer**, **kafka-consumer-groups** | Flag-first (e.g. `--list`, `--bootstrap-server`) rather than subcommand-first | — |
| **rabbitmqctl** | `status`, `cluster_status`, `list_queues`, `list_exchanges`, `list_bindings`, `list_connections`, `list_channels`, `list_vhosts`, `list_users`, `add_user`, `delete_user`, `set_permissions`, `list_permissions`, `add_vhost`, `delete_vhost`, `set_user_tags`, `stop_app`, `start_app`, `purge_queue` | — |

Directory completion after `cd` and local git branch completion (for
`checkout`/`switch`/`merge`/`rebase`/`branch`) work independently of these
tables — see [Features](#features).

## The Lumen menu bar app

<p align="center">
  <img src="assets/app-icon.png" width="96" alt="Lumen.app icon">
</p>

`Lumen.app` is a small SwiftUI app that owns the floating suggestion panel
and toggles **automatic** (as-you-type) suggestions on or off without
touching the terminal. The menu bar icon shows ✨ when on, ⏸ when paused.
The app icon itself (Finder, Dock-less but still visible in the
Accessibility permission list, etc.) is built from the same spark mark as
the project logo above, set against a dark backdrop with a small
terminal-prompt chevron — see `Lumen/build.sh` for how it's generated.

It runs as a menu-bar-only accessory (no Dock icon, no app-switcher entry)
and does not auto-start on login by default — see [step 5 of
Installation](#5-optional-auto-start-on-login). Quit it from its own menu
(**Quit Lumen**).

**How it syncs with the shell:** this app and the Zsh plugin are separate,
unrelated processes with no shared memory — the only things connecting
them are a state file and a socket, both under `~/.cache/ai-suggest/`.
Toggling the switch writes `1` or `0` to `enabled`; the Zsh plugin reads it
before firing an *automatic* suggestion. A missing file means enabled by
default, so the shell plugin works normally even if this app has never
been run. Manual suggestions (Ctrl-Space) are **not** gated by this toggle
on purpose — pausing automatic suggestions never blocks an explicit ask.

**Rebuilding:** every `./build.sh` run re-signs the bundle with a fresh
ad-hoc code signature (there's no paid Apple Developer ID here). macOS's
Accessibility permission grant is tied to that exact signature, so **every
rebuild silently invalidates the previous grant** — if positioning stops
working right after you rebuild, that's why. Re-grant it following [step 4
of Installation](#4-grant-accessibility-permission).

## Troubleshooting

**The panel doesn't show up in any app:**
1. Check `Lumen.app` is actually running: look for its icon in the menu
   bar.
2. Check Accessibility permission is granted — see [step 4 of
   Installation](#4-grant-accessibility-permission). This is the single
   most common cause, especially right after a rebuild (see above).
3. Check the debug log for what's actually failing:
   ```sh
   tail -f /tmp/ai-suggest-overlay-debug.log
   ```
   Type something in a matching shape (e.g. `docker`) and watch for lines
   like `AXIsProcessTrusted=false` (permission not granted) or `no focused
   window/element for <App>` (permission granted, but that specific app
   isn't exposing what's needed — see below).

**It works in some apps but not others:** the panel positions itself two
ways — asking the focused element directly where its text cursor renders
(most reliable, but only works for apps with a real accessibility text
bridge), or falling back to computing it from the window frame ÷ terminal
columns/lines (an approximation, calibrated per-app via
`~/.config/ai-suggest/overlay_position.json`, see
`PositionerConfig` in `TerminalPositioner.swift`). Some terminal apps
render their content in ways that don't expose either path fully — check
the debug log to see which path is being tried and why it's failing for a
specific app.

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

- Suggestion sources are deterministic and hand-picked (see [Known-tool
  subcommand coverage](#known-tool-subcommand-coverage)) — there's no
  free-form or AI-generated suggestion for commands outside those tables.
- The floating panel requires `Lumen.app` to be running and granted
  Accessibility permission; without it, matching still happens but nothing
  renders. That grant is invalidated by every rebuild (see [The Lumen menu
  bar app](#the-lumen-menu-bar-app)).
- Positioning accuracy depends on how much of its content an app exposes
  via the Accessibility API — some terminal apps work better than others
  (see [Troubleshooting](#troubleshooting)).
- Bash and Fish shells are not supported.
