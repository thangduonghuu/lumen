# Ubuntu Support — Plan

This document reviews Lumen's current (macOS-only) architecture and lays
out what it would take to support Ubuntu.

## 1. Current architecture (macOS-only, every layer)

```
Zsh (ZLE) --keystroke/Ctrl-Space--> deterministic matchers (in-plugin)
                                              |
                                   Unix socket (~/.cache/ai-suggest/overlay.sock)
                                              |
                                   Lumen.app (NSPanel overlay, positioned via
                                   macOS Accessibility API / AXUIElement)
```

Key fact that shapes this whole plan: the Rust daemon
(`ai-shell-suggest/src/`) is **parked** — it is not wired into the live
path (see README, "Parked: the Rust daemon"). All suggestion logic lives
in the 2,864-line zsh plugin itself (`ai-suggest.plugin.zsh`), built on
`zle`/`bindkey` (31/11 uses respectively). That plugin, not the Rust code,
is the real "brain" of the product.

## 2. Where Ubuntu differs, per component

Unlike Windows, several layers need **no rewrite at all** — Ubuntu is a
POSIX/Unix system, so the parts of Lumen that are already POSIX-shaped
just work.

| Component | macOS-specific dependency | Ubuntu story |
| --- | --- | --- |
| Shell integration | zsh's `zle` line-editor widgets, `bindkey` | **No change needed.** Zsh and ZLE are identical on Linux — the 2,864-line plugin runs as-is. |
| IPC | Unix domain socket (`~/.cache/ai-suggest/overlay.sock`) | **No change needed.** AF_UNIX sockets are native POSIX on Linux; the wire protocol (JSON over the socket) is already OS-agnostic. Only the Swift *server* side (see below) needs a rebuild for Linux, not a redesign. |
| Context collection (`collector.rs`) | None — pure Rust, shells out to `git` | **No change needed.** Already portable. |
| Overlay app process itself | `AppKit` / `SwiftUI` (`NSPanel`, `MenuBarExtra`, `.regularMaterial`) | **Rewrite.** AppKit/SwiftUI don't exist on Linux. Swift itself runs fine on Linux, but the UI layer needs a Linux toolkit — GTK4 is the natural choice on Ubuntu/GNOME (via `gtk-rs` if rewritten in Rust, or a Swift GTK binding if staying in Swift). |
| Cursor positioning | `ApplicationServices` / `AXUIElement*` (Accessibility API) in `TerminalPositioner.swift` | **Rewrite.** Linux analogue is AT-SPI2 (accessibility-over-D-Bus), which GTK terminals (GNOME Terminal, etc.) expose reasonably well but coverage varies by terminal emulator, same class of problem the README already documents for macOS AX support. |
| Floating panel positioning (window server) | AppKit window leveling or arbitrary absolute positioning | **Depends on display server.** Under X11, absolute window positioning works like macOS. Under Wayland, most compositors (including GNOME's default) deliberately restrict apps from placing their own windows at arbitrary screen coordinates — this is the single biggest new risk, not present on macOS at all. |
| Menu bar / tray icon | `MenuBarExtra`, `NSApplication.accessory` policy | **Rewrite.** Linux equivalent is a StatusNotifierItem tray icon (via `libappindicator` or the GTK equivalent); GNOME requires a shell extension for tray icons to show at all — an Ubuntu-specific wrinkle worth flagging to users. |
| Auto-start on login | LaunchAgent / Login Items | **Rewrite, but simple.** Linux equivalent is a `systemd --user` unit or an XDG autostart `.desktop` file — more standardized than macOS's, not a hard problem. |

**Net:** this is a much smaller lift than a Windows port. The shell
plugin, IPC layer, and context collection are already portable — the work
is almost entirely confined to rewriting the native overlay app in a
Linux UI toolkit and re-solving cursor positioning + window placement for
X11/Wayland.

## 3. Biggest open risk: Wayland

Ubuntu defaults to GNOME on Wayland since 22.04. Wayland's security model
intentionally prevents client windows from positioning themselves at
arbitrary screen coordinates (no equivalent to macOS's "put this panel at
this exact pixel"). Some compositors expose a workaround via the
`wlr-layer-shell` protocol, but GNOME's Mutter does not support it for
regular applications. Practically:

- **X11 session:** positioning works close to how it does on macOS.
- **Wayland session (Ubuntu's default):** precise overlay placement next
  to the terminal cursor may not be achievable at all without compositor
  cooperation, independent of how good the AT-SPI cursor lookup is.

This should be validated **before** investing in the rest of the port —
it could cap what's achievable on Ubuntu's default desktop regardless of
effort spent elsewhere.

## 4. Headless and remote (SSH) session detection

Not every Linux install of Lumen will have a local GUI at all — servers
accessed only via SSH are a first-class case to design for, not an edge
case to patch later. Two distinct situations fall under this, and they
need different detection logic.

### Case 1: No display server at all (typical headless server)

- No `$DISPLAY` and no `$WAYLAND_DISPLAY`.
- The zsh plugin and matching still work fully — no GUI needed for that
  part.
- The overlay app has nothing to render into; suggestions get computed
  and fire-and-forget sent to a socket with no working recipient on the
  other end.
- **Current behavior would silently do nothing** — this is the same
  failure mode the README already documents for macOS when `Lumen.app`
  isn't running ("matching still happens, nothing renders"), just
  triggered by environment instead of the app not being launched.
- **Fix:** at plugin load, detect the absence of both display env vars
  and print a one-time warning, then skip attempting to spawn/connect to
  the overlay entirely (avoids a wasted socket attempt on every
  keystroke).

### Case 2: SSH session, even with X11 forwarding enabled

- A subtler variant worth calling out explicitly: even when `$DISPLAY`
  **is** set (because the user connected with `ssh -X`/`-Y`), the
  overlay still can't correctly position itself.
- Reason: the terminal window the user is actually looking at and typing
  into is a **local app on their client machine** (iTerm2, GNOME
  Terminal, Windows Terminal — whatever they SSH'd from) — it is not
  part of the forwarded X11 session at all. AT-SPI/accessibility queries
  against the forwarded display would only ever see X11-forwarded apps,
  never the actual terminal the person is using.
- So `$DISPLAY` being set is **not sufficient evidence** that positioning
  will work — using it as the only check would be actively misleading.
- **Fix:** also check `$SSH_TTY` / `$SSH_CONNECTION`. If either is set,
  treat the overlay as unavailable regardless of `$DISPLAY`, with the
  same one-time warning as Case 1.

### Design principle

Both cases should degrade the same way the macOS app already does when
not running: fail silently *after* one clear warning, never block
installation, and never spam a warning on every keystroke. Add an env
var alongside the existing `AI_SUGGEST_OVERLAY` (e.g.
`AI_SUGGEST_OVERLAY_WARN=0`) so a user who knows their setup can suppress
the warning.

## 5. Recommendation

1. **Spike the Wayland question first.** Confirm whether a floating,
   precisely-positioned, always-on-top window is achievable on stock
   Ubuntu/GNOME/Wayland at all. If not, decide whether X11-only support
   (users can still log into an X11 session) is an acceptable initial
   scope.
2. **Reuse the zsh plugin and Unix-socket protocol unchanged** — this is
   the part of the macOS design that already generalizes to Linux.
3. **Rewrite the overlay app in GTK4** (Ubuntu's native toolkit), covering:
   tray icon (StatusNotifierItem), floating panel rendering, and AT-SPI2
   based cursor positioning as the `TerminalPositioner.swift` replacement.
4. **Swap login-time integration** to a systemd user unit / XDG autostart
   `.desktop` file.
5. **Add headless/SSH detection** (Section 4) to the plugin's startup
   path so server installs degrade gracefully with one clear warning
   instead of silently doing nothing.

## 6. Open questions / next steps

- [ ] Spike: can a GTK window be positioned at exact screen coordinates
      under Ubuntu's default Wayland session? (Blocks everything else.)
- [ ] Decide implementation language for the new overlay app: Swift
      (keep language parity with macOS, less mature Linux GTK bindings)
      vs. Rust (`gtk-rs`, and could reuse/un-park parts of the existing
      Rust codebase for the daemon side).
- [ ] Check AT-SPI2 coverage across common Ubuntu terminal emulators
      (GNOME Terminal, Konsole, Alacritty, kitty) the same way the README
      documents inconsistent AX coverage across macOS terminals.
- [ ] Confirm whether any legitimate workflow actually benefits from
      overlay-over-X11-forwarding before hard-excluding the SSH case
      (Section 4, Case 2) — if none, treat it as always-warn.
- [ ] Break the GTK rewrite into milestones with effort estimates before
      starting implementation.
