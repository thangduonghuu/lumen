# ai-suggest

On-demand AI command suggestions for the terminal, Kiro-CLI style, embedded
into your existing Zsh shell via a ZLE plugin — not a separate terminal
emulator. Nothing happens while you type; press a trigger key when you want
a suggestion, pick one from the list, done.

## Architecture

```
Zsh (ZLE)  --keystroke (debounced) or Ctrl-Space-->  ai-suggest-client  --unix socket-->  ai-suggest-daemon
   ^                                                                                           |
   |                                                                                           v
   +------------------------ POSTDISPLAY ghost text + zle -M list -----------------  AI provider (Ollama / Anthropic)
```

- **ai-suggest-daemon**: long-running background process, listens on
  `~/.cache/ai-suggest/daemon.sock`. Collects context (cwd, git branch/dirty
  count, detected project type, recent history) and asks the configured AI
  provider for up to `max_suggestions` command completions. Each connection
  is handled independently (no shared mutable state), so it's safe for the
  plugin to fire concurrent/overlapping requests.
- **ai-suggest-client**: thin, short-lived binary the Zsh plugin shells out
  to. Auto-spawns the daemon if it isn't running yet.
- **shell/zsh/ai-suggest.plugin.zsh**: ZLE integration, Kiro-CLI style. By
  default, every buffer-editing keystroke schedules a debounced background
  request (see `AI_SUGGEST_DEBOUNCE_MS`); the top suggestion renders as
  inline ghost text once it arrives, with the rest reachable via Up/Down.
  Ctrl-Space still asks immediately and synchronously, bypassing the
  debounce, for when you don't want to wait. Set `AI_SUGGEST_AUTO=0` to
  disable automatic triggering entirely and fall back to Ctrl-Space-only.

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

## Build & install

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

## Config

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

## Usage / keybindings

Suggestions appear automatically: pause briefly after typing (default 250ms,
see `AI_SUGGEST_DEBOUNCE_MS`) and the top candidate shows up as inline ghost
text. No automatic message is shown for this — it just quietly updates, like
Kiro's inline suggestions.

| Key | Action |
|---|---|
| Ctrl-Space (`$AI_SUGGEST_KEY`) | Ask AI immediately, bypassing the debounce |
| Up / Down | Cycle through candidates (falls back to normal history search when no suggestion is shown) |
| Tab / Right arrow (at end of line) | Accept the shown suggestion |
| Ctrl-G | Dismiss the current suggestion (keeps what you typed) |

The manual Ctrl-Space path shows status/progress via the message line
(`zle -M`) below the prompt: "đang hỏi AI..." while waiting, then either the
suggestion count + key hints, or an error if the daemon/client couldn't be
reached.

To disable automatic as-you-type suggestions and go back to Ctrl-Space-only,
set `export AI_SUGGEST_AUTO=0` before sourcing the plugin.

Debugging: set `AI_SUGGEST_DEBUG=1` before sourcing the plugin to log every
request (buffer, cwd, lines received — both manual and automatic) to
`/tmp/ai-suggest-debug.log`.

### How the async as-you-type path works

An earlier version attempted this via an async `zle -F` fd handler that
branched on a `"read"` marker in its second argument to detect success —
but zsh only ever passes a second argument (`"hup"`) on error/hangup, never
a success marker, so that branch was dead code and suggestions never
rendered. The current handler avoids that failure mode entirely: it never
branches on the fd-handler's arguments, and instead unconditionally drains
the fd the instant it's called (safe because `ai-suggest-client` isn't
streaming — it prints everything right before exiting, so the fd is at or
near EOF by the time it's reported readable). Whether a result is usable is
decided afterward, from content (empty or not) and staleness (does the
buffer that was sent still match the current buffer) — never from the
handler's arguments.

Debouncing kills and respawns a background job that sleeps before calling
the client, so cancelling mid-sleep (the common case while actively typing)
means the expensive client call never runs at all. That job is a real `&`
job, not a `<(...)` process substitution — process substitution does not
reliably populate `$!` in zsh (verified empirically), so it can't be killed
by PID. The job writes into a fifo that's already open for reading before
the job starts, so EOF propagates correctly whether the job finishes
normally or gets killed mid-flight.

## Known MVP limitations / next steps

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
- Bash and Fish support (phase 2 in the original goal doc) are not started.
