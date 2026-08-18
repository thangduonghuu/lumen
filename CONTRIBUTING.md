# Contributing to Lumen

Thanks for taking the time to contribute! This guide walks through
everything needed to get a dev environment running, make a change, and
submit it — no prior familiarity with the repo assumed.

## Project layout

Lumen is two pieces that work together (see the [README](README.md#what-it-is)
for the full picture):

| Path | What it is |
| --- | --- |
| [`shell/zsh/`](shell/zsh/) | The Zsh plugin — a single shell script, this is the active suggestion engine. |
| [`Lumen/`](Lumen/) | The SwiftUI menu bar app that draws the floating panel. |
| [`daemon/src/`](daemon/src/) | A parked Rust daemon/client for AI-generated suggestions, not wired into the live path. Only touch this if your change is specifically about it. |

Most contributions will touch either the Zsh plugin or the Swift app, not
both.

## Getting set up

### Requirements

- macOS 13+ with Zsh (the plugin and app only run on macOS)
- Swift 5.9+ / Xcode command line tools (`xcode-select --install`) to
  build the menu bar app
- Rust (stable, via [rustup](https://rustup.rs/)) — only needed if you're
  touching `daemon/src/`

### 1. Fork and clone

```sh
git clone git@github.com:<your-username>/lumen.git
cd lumen
```

### 2. Point your shell at your working copy

```sh
echo 'source '"$(pwd)"'/shell/zsh/lumen.plugin.zsh' >> ~/.zshrc
source ~/.zshrc
```

### 3. Build the menu bar app

```sh
cd Lumen
./build.sh
open Lumen.app
```

Full step-by-step details (including granting Accessibility permission,
which the app needs to position the floating panel) are in the README's
[Setup](README.md#setup) section — follow that if anything
above doesn't work as expected.

## Making a change

### Editing the Zsh plugin

`shell/zsh/lumen.plugin.zsh` is a single file with
no build step. Edit it, then reload it in any open terminal:

```sh
source ~/.zshrc
```

Try the buffer shapes your change affects (e.g. typing `docker ` or
`git checkout ` if you touched those tables) and confirm the right
candidates show up.

### Editing the menu bar app

Source lives in `Lumen/Sources/Lumen/`. After editing:

```sh
cd Lumen
./build.sh
open Lumen.app
```

Re-grant Accessibility permission after every rebuild — the app's ad-hoc
code signature changes each build, which invalidates the previous grant.
See the README's [Setup](README.md#setup) section for why.

For a fully clean rebuild:

```sh
rm -rf .build Lumen.app
./build.sh
```

### Editing the Rust daemon (parked)

```sh
cd daemon
cargo build
```

This code isn't called from the live suggestion path, so changes here
won't be visible in the shell or the app — verify with `cargo build`
(and `cargo check`) only.

## Testing your change

There's no automated test suite yet — verification is manual:

- **Zsh plugin changes**: reload (`source ~/.zshrc`) and exercise the
  specific buffer shapes you changed (a tool's subcommands/flags, `cd`
  completion, or git branch completion) in a real terminal.
- **Swift app changes**: rebuild and relaunch `Lumen.app`, then confirm
  the panel still renders and positions correctly against a real
  terminal cursor.
- If you're changing something covered by the README (a keybinding, an
  environment variable, tool coverage), double check the docs still
  match the behavior.

If you're adding a new capability that's meaningfully complex, tests are
welcome, but don't feel blocked from contributing without them.

## Commit messages

This repo prefixes commit subjects with the kind of change, e.g.:

```
feature: enhance behavior of close the popup
fix: adjust the wrong showing up
chore: add readme and license
```

Common prefixes: `feature:`, `fix:`, `chore:`, `docs:`. Keep the subject
line short and in the imperative mood.

## Submitting a pull request

1. Create a branch off `main` named for what it does, e.g.
   `fix/docker-flag-table` or `feature/fish-shell-support`.
2. Make your change, following the surrounding code's existing style
   rather than reformatting unrelated lines.
3. Update the README if your change affects documented behavior (a new
   tool's coverage, a new keybinding, a new environment variable, etc).
4. Push your branch and open a PR against `main`. Describe what changed
   and how you tested it (see [Testing your change](#testing-your-change)
   above).
5. A maintainer will review and may ask for changes before merging.

## Reporting bugs / requesting features

Use [GitHub Issues](https://github.com/thangduonghuu/lumen/issues).
For bugs, include your macOS version, the terminal app you're using, and
(if the panel isn't rendering) the relevant lines from
`/tmp/lumen-overlay-debug.log` — see the README's
[Troubleshooting](README.md#troubleshooting) section.
