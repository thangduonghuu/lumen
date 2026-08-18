<p align="center">
  <img src="assets/logo.png" width="96" alt="Lumen logo">
</p>

<h1 align="center">Lumen</h1>

<p align="center"><strong>Deterministic command suggestions for Zsh — inline, on demand, no AI round-trip required.</strong></p>

<p align="center">
  <img alt="platform" src="https://img.shields.io/badge/platform-macOS-lightgrey">
  <img alt="shell" src="https://img.shields.io/badge/shell-zsh-89e051">
  <img alt="swift" src="https://img.shields.io/badge/swift-5.9%2B-f05138">
  <a href="LICENSE"><img alt="license" src="https://img.shields.io/badge/license-MIT-blue"></a>
</p>

<p align="center">
  <img src="assets/demo.gif" width="600" alt="Lumen suggesting a git branch after git checkout">
</p>

## What it is

- Matches your Zsh buffer against known local data as you type (or on
  Ctrl-Space) — a tool's subcommands/flags, `cd` targets, your repo's git
  branches, and common deletable files/folders for `rm` commands — and shows 
  it in a floating panel.
- No AI, no daemon, no network round-trip: every suggestion resolves
  instantly from a static table or a local command (`git for-each-ref`,
  a directory glob, `docker ps`, ...).
- Two pieces, both need to be running: the **Zsh plugin** (`shell/zsh/`)
  computes suggestions; the **`Lumen` menu bar app** (`Lumen/`, Swift)
  draws them.

## Setup

```sh
git clone https://github.com/thangduonghuu/lumen.git ~/lumen

# 1. Zsh plugin (computes suggestions)
echo 'source ~/lumen/shell/zsh/lumen.plugin.zsh' >> ~/.zshrc && source ~/.zshrc

# 2. Menu bar app (draws them) — needs Swift 5.9+ / Xcode CLT
cd ~/lumen/Lumen && ./build.sh && open Lumen.app
```

Grant Accessibility permission when macOS prompts (first launch), then
type `git che`, `docker ex`, `kubectl get`... Every rebuild (`./build.sh`)
invalidates that grant — re-grant it in **System Settings → Privacy &
Security → Accessibility** after rebuilding.

Doesn't auto-start on login by default — add it under **System Settings
→ General → Login Items** if you want that.

## Troubleshooting

Panel not showing up:
1. Is `Lumen.app` running? (menu bar icon)
2. Is Accessibility permission granted? Most common cause, especially
   right after a rebuild (see Setup).
3. Check the log: `tail -f /tmp/lumen-overlay-debug.log` — watch for
   `AXIsProcessTrusted=false` (permission) or `no focused window/element`
   (that app doesn't expose enough via Accessibility for precise
   positioning).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)
